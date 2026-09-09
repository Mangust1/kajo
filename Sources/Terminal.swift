import AppKit
import SwiftTerm

// MARK: - Terminal window (quake-style drop-down, pinned to one Space)
//
// Why this exists: Ghostty/kitty quick terminals lose their Space every time they hide,
// because they `orderOut` the window and macOS re-places a re-shown window on the
// *current* Space. Kajo never orders the window out: "hidden" = alpha 0 + ignore mouse +
// focus handed back. A window that stays ordered-in keeps its Space, and making it key
// again makes macOS switch to that Space (on whichever display it lives), so the terminal
// is effectively pinned wherever you first summoned it — that is `"pinToSpace": true`.
// Default (false) = follow mode: it auto-hides when you click elsewhere and re-appears on
// whatever Space/screen you summon it from. `kajo://terminal/repin` re-places it explicitly.
//
// Config (optional) ~/.config/kajo/terminal.json:
//   { "command": ["/bin/zsh", "-lc", "~/.config/kajo/terminal.sh"],
//     "width": 0.8, "height": 0.5, "topGap": 40, "font": "Iosevka NFM", "fontSize": 11 }
// Default command: ~/.config/kajo/terminal.sh if it exists (see config-examples/), else a
// login zsh. The example script attaches a persistent tmux session, so the shell/Claude
// sessions survive Kajo restarts.

/// Debug trail for the terminal window → ~/.config/kajo/terminal.log (tiny, append-only).
func tlog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    let path = kajoConfigDir + "/terminal.log"
    if let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int, size > 200_000 {
        try? FileManager.default.removeItem(atPath: path)          // keep it tiny
    }
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

struct TerminalConfig {
    var command: [String]
    var widthPct: CGFloat = 0.8
    var heightPct: CGFloat = 0.5
    var topGap: CGFloat = 40          // clear SketchyBar (32px) — same gap the kitty quake used
    var fontName = "Iosevka NFM"
    var fontSize: CGFloat = 11
    var borderWidth: CGFloat = 2       // 0 disables the frame (e.g. if JankyBorders draws one)
    var pinToSpace = false             // true = stay on the Space it was first opened on (summon jumps there)

    static func load() -> TerminalConfig {
        let script = kajoConfigDir + "/terminal.sh"
        let defaultCommand = FileManager.default.isExecutableFile(atPath: script)
            ? ["/bin/zsh", "-lc", script]
            : ["/bin/zsh", "-l"]
        var c = TerminalConfig(command: defaultCommand)
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: kajoConfigDir + "/terminal.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return c }
        if let cmd = j["command"] as? [String], !cmd.isEmpty { c.command = cmd.map { ($0 as NSString).expandingTildeInPath } }
        if let v = j["width"]    as? Double { c.widthPct  = CGFloat(min(max(v, 0.2), 1)) }
        if let v = j["height"]   as? Double { c.heightPct = CGFloat(min(max(v, 0.2), 1)) }
        if let v = j["topGap"]   as? Double { c.topGap    = CGFloat(max(v, 0)) }
        if let v = j["font"]     as? String { c.fontName  = v }
        if let v = j["fontSize"] as? Double { c.fontSize  = CGFloat(v) }
        if let v = j["borderWidth"] as? Double { c.borderWidth = CGFloat(max(v, 0)) }
        if let v = j["pinToSpace"] as? Bool { c.pinToSpace = v }
        return c
    }
}

final class TerminalWindow: NSWindow {
    weak var terminalView: KajoTerminalView?   // set by the controller; the view sits inside the frame view
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    // Let the frame land exactly where we put it (no clamping under the menu-bar area).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    // Editing chords (⌥/⌘ + arrows/backspace) are translated before SwiftTerm sees them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let t = terminalView, t.handleEditingChord(event) { return }
        super.sendEvent(event)
    }
}

/// SwiftTerm view + two quality-of-life bits for Claude Code:
///  • Cmd+V with an *image* on the clipboard (no text) forwards Ctrl+V to the process —
///    Claude Code then reads the clipboard image itself and attaches it, exactly as it does
///    in kitty/Ghostty when you press Ctrl+V.
///  • Dropping files (screenshots, PDFs…) onto the window types their shell-quoted paths.
final class KajoTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func paste(_ sender: Any) {
        let pb = NSPasteboard.general
        let hasText = (pb.string(forType: .string) ?? "").isEmpty == false
        let hasImage = pb.canReadObject(forClasses: [NSImage.self], options: nil)
        if !hasText && hasImage {
            send([0x16])            // Ctrl+V → Claude Code grabs the clipboard image
            return
        }
        super.paste(sender)
    }

    /// macOS-style editing chords → readline/Claude-Code sequences, so Option stays a
    /// character key (Nordic { } [ ] | \ @ $) yet Option/Cmd+arrows still move by word/line.
    ///   ⇧↩ = ESC CR (newline) · ⌥←/⌥→ = ESC b / ESC f · ⌥⌫ = Ctrl+W · ⌘←/⌘→ = Home / End · ⌘⌫ = Ctrl+U
    /// ⌘+ / ⌘= bigger, ⌘- smaller, ⌘0 back to the configured size.
    var baseFontSize: CGFloat = 11
    private func zoom(_ delta: CGFloat?) {
        let size = delta.map { min(max(font.pointSize + $0, 6), 40) } ?? baseFontSize
        font = NSFont(name: font.fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Called from TerminalWindow.sendEvent (SwiftTerm's keyDown is not `open`). Returns true if consumed.
    func handleEditingChord(_ event: NSEvent) -> Bool {
        // Arrow keys carry .function AND .numericPad; ignore those (and Caps Lock) when matching.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])
        let chars = event.charactersIgnoringModifiers ?? ""
        let key = chars.unicodeScalars.first.map { Int($0.value) } ?? -1
        let isBackspace = key == 0x7f || key == 0x08 || event.keyCode == 51
        // ⇧↩ → newline in Claude Code (sent as Option+Enter = ESC CR, understood everywhere, tmux-safe)
        if flags == [.shift] && (key == 13 || key == 3 || event.keyCode == 36 || event.keyCode == 76) {
            send([0x1b, 0x0d]); return true
        }
        if flags == [.option] {
            switch key {
            case NSLeftArrowFunctionKey:  send([0x1b, 0x62]); return true       // ESC b
            case NSRightArrowFunctionKey: send([0x1b, 0x66]); return true       // ESC f
            default: if isBackspace { send([0x17]); return true }               // Ctrl+W
            }
        }
        if flags == [.command] {
            switch chars {
            case "+", "=": zoom(+1); return true
            case "-":      zoom(-1); return true
            case "0":      zoom(nil); return true
            default: break
            }
            switch key {
            case NSLeftArrowFunctionKey:  send([0x1b, 0x5b, 0x48]); return true   // Home (ESC [ H)
            case NSRightArrowFunctionKey: send([0x1b, 0x5b, 0x46]); return true   // End  (ESC [ F)
            default: if isBackspace { send([0x15]); return true }               // Ctrl+U
            }
        }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL],
              !urls.isEmpty else { return false }
        let quoted = urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        send(txt: quoted.joined(separator: " ") + " ")
        return true
    }
}

final class TerminalWindowController: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalWindowController()

    private var window: TerminalWindow?
    private var term: KajoTerminalView?
    private var borderLayer: CALayer?
    private var config = TerminalConfig.load()
    private(set) var isShown = false
    private var processAlive = false
    private var previousApp: NSRunningApplication?
    private var lastShownAt = Date.distantPast

    // MARK: public entry points (kajo://terminal, kajo://terminal/repin)

    func toggle() {
        if window == nil { build(on: activeScreen()) }
        // Visible but on another Space (you switched away, it stayed put) → summoning means
        // "take me there", not "hide it behind my back".
        if config.pinToSpace, isShown, let w = window, !w.isOnActiveSpace { show(); return }
        // Visible but not focused (e.g. you clicked an app on the other screen) → bring focus back.
        if isShown, let w = window, !w.isKeyWindow { show(); return }
        isShown ? hide() : show()
    }

    /// Re-place the window on the *current* Space and screen (this is the one deliberate
    /// use of orderOut: it drops the old Space assignment so orderFront picks up the new one).
    func repin() {
        guard let w = window else { toggle(); return }
        // Borrow .moveToActiveSpace for one show, then restore the pinned behaviour.
        let previous = w.collectionBehavior
        w.collectionBehavior = previous.union(.moveToActiveSpace)
        w.setFrame(targetFrame(on: activeScreen()), display: false)
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { w.collectionBehavior = previous }
    }

    /// kajo://terminal/send?text=…[&enter=1][&show=1] and kajo://terminal/paste — inject text into the
    /// running program (e.g. a Claude prompt) without necessarily showing the window.
    func send(text: String, enter: Bool, show: Bool) {
        if window == nil { build(on: activeScreen()) }
        guard let t = term else { return }
        if !processAlive { spawn() }
        t.send(txt: text)
        if enter { t.send([0x0d]) }
        if show, !isShown { self.show() }
        tlog("send: \(text.count) chars enter=\(enter) show=\(show)")
    }

    // MARK: window lifecycle

    private func build(on screen: NSScreen) {
        config = TerminalConfig.load()
        let w = TerminalWindow(contentRect: targetFrame(on: screen),
                               styleMask: [.borderless, .fullSizeContentView],
                               backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = .normal                // behaves like a regular window: other windows can come over it
        w.hasShadow = true
        w.appearance = NSAppearance(named: .darkAqua)
        // Follow mode: .moveToActiveSpace makes macOS carry the window to the current Space whenever
        // it is ordered front/made key (orderOut + orderFront alone does NOT re-place it — the
        // old Space assignment sticks and activating the app jumps back there). Pinned mode omits it.
        // fullScreenAuxiliary lets it appear over a full-screen app.
        w.collectionBehavior = config.pinToSpace ? [.fullScreenAuxiliary] : [.fullScreenAuxiliary, .moveToActiveSpace]
        w.isMovableByWindowBackground = false

        var opts = TerminalOptions.default
        opts.enableSixelReported = true            // img2sixel & co. can draw inline (kitty graphics is built in)
        opts.scrollback = 10_000
        // Frame drawn by Kajo itself (no JankyBorders needed): orange when focused, dim otherwise.
        let bw = config.borderWidth
        let frameView = NSView(frame: NSRect(origin: .zero, size: w.frame.size))
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = Gruv.termBg.cgColor
        frameView.layer?.borderWidth = bw
        frameView.layer?.borderColor = Gruv.borderIdle.cgColor
        frameView.layer?.cornerRadius = bw > 0 ? 10 : 0
        frameView.layer?.masksToBounds = true
        w.backgroundColor = .clear
        w.isOpaque = false

        let t = KajoTerminalView(frame: frameView.bounds.insetBy(dx: bw, dy: bw), options: opts)
        t.autoresizingMask = [.width, .height]
        t.processDelegate = self
        style(t)
        frameView.addSubview(t)
        w.contentView = frameView
        w.terminalView = t
        borderLayer = frameView.layer
        window = w
        term = t
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [weak self] _ in
            self?.borderLayer?.borderColor = Gruv.borderActive.cgColor
        }
        nc.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.borderLayer?.borderColor = Gruv.borderIdle.cgColor
            // Quake semantics: focusing something else on the SAME screen dismisses it. Focus moving to
            // another display (mouse is over there) leaves the terminal up — you're still looking at it.
            guard self.isShown, let w = self.window else { return }
            // A Space switch fires a stale resign a moment later; if we just showed, keep it up.
            if Date().timeIntervalSince(self.lastShownAt) < 0.7 {
                tlog("resign ignored (grace period)"); w.makeKeyAndOrderFront(nil); return
            }
            let mouseScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            if mouseScreen == nil || mouseScreen == w.screen { self.hide() }
        }
        spawn()
        // Dock/undock or resolution change → refit right away, not only on the next summon.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self, let w = self.window else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refit(w) }   // let macOS settle
        }
    }

    private func spawn() {
        guard let t = term, !processAlive else { return }
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Kajo"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        let cmd = config.command
        processAlive = true
        t.startProcess(executable: cmd[0], args: Array(cmd.dropFirst()),
                       environment: env.map { "\($0.key)=\($0.value)" },
                       execName: nil, currentDirectory: NSHomeDirectory())
    }

    private func show() {
        guard let w = window, let t = term else { return }
        tlog("show: isShown=\(isShown) key=\(w.isKeyWindow) onActiveSpace=\(w.isOnActiveSpace) pin=\(config.pinToSpace) frame=\(NSStringFromRect(w.frame)) screen=\(w.screen?.localizedName ?? "nil")")
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        if !processAlive { spawn() }
        let screen = (!config.pinToSpace && !w.isOnActiveSpace) ? activeScreen()
                   : (w.screen ?? NSScreen.screens.first { $0.frame.intersects(w.frame) } ?? activeScreen())
        let target = targetFrame(on: screen)      // also re-fits after dock/undock
        // Slide in from above the screen edge (quake feel), like the panel does.
        w.setFrame(target.offsetBy(dx: 0, dy: target.height + 20), display: false)
        w.ignoresMouseEvents = false
        w.alphaValue = 1
        w.makeKeyAndOrderFront(nil)     // follow mode: .moveToActiveSpace carries it here
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(target, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeFirstResponder(t)
        isShown = true
        lastShownAt = Date()
    }

    private func hide() {
        guard let w = window else { return }
        tlog("hide: key=\(w.isKeyWindow) onActiveSpace=\(w.isOnActiveSpace) appActive=\(NSApp.isActive)")
        isShown = false
        w.ignoresMouseEvents = true
        let up = w.frame.offsetBy(dx: 0, dy: w.frame.height + 20)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().setFrame(up, display: true)
        }, completionHandler: {
            w.alphaValue = 0            // stays ordered-in → keeps its Space
        })
        if NSApp.isActive { previousApp?.activate() }   // hand focus back, like the panel does
    }

    // MARK: geometry

    /// Size/position the window for the screen it currently lives on (or the active one if
    /// its screen is gone). Changing the frame does not change the Space, so pinning survives.
    private func refit(_ w: NSWindow) {
        let screen = w.screen ?? NSScreen.screens.first { $0.frame.intersects(w.frame) } ?? activeScreen()
        let target = targetFrame(on: screen)
        if w.frame != target { w.setFrame(target, display: true) }
    }

    private func targetFrame(on screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame                   // excludes menu bar / dock
        let width  = floor(vf.width  * config.widthPct)
        let height = floor(vf.height * config.heightPct)
        let x = vf.minX + floor((vf.width - width) / 2)
        let top = vf.maxY - config.topGap
        return NSRect(x: x, y: top - height, width: width, height: height)
    }

    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: look

    private func style(_ t: KajoTerminalView) {
        t.font = NSFont(name: config.fontName, size: config.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)
        t.baseFontSize = config.fontSize
        t.nativeBackgroundColor = Gruv.termBg
        t.nativeForegroundColor = NSColor(hex: 0xebdbb2)
        t.caretColor = NSColor(hex: 0xbdae93)
        t.caretTextColor = Gruv.termBg
        t.selectedTextBackgroundColor = NSColor(hex: 0xd65d0e)
        t.installColors(Gruv.terminalPalette)
        // Nordic layout: Option is needed for { } [ ] | \ @ $ — so Option stays Option.
        // (tmux Alt-bindings are not used in the quake session; prefix keys still work.)
        t.optionAsMetaKey = false
        t.allowMouseReporting = true    // tmux `mouse on`
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        processAlive = false
        // The shell/tmux attach ended (detach, exit). Respawn so the next summon shows a
        // live prompt instead of a dead screen; if it's visible right now, respawn at once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if self.isShown { self.spawn() }
        }
    }
}

// MARK: - gruvbox for the terminal (kitty "Gruvbox Dark" palette on bg0_hard)

extension Gruv {
    static let termBg = NSColor(hex: 0x1d2021)
    static let borderActive = NSColor(hex: 0xd65d0e)   // gruvbox orange, same as the old JankyBorders frame
    static let borderIdle = NSColor(hex: 0x3c3836)     // bg1
    static let terminalPalette: [SwiftTerm.Color] = [
        0x3c3836, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,   // normal
        0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xfbf1c7,   // bright
    ].map { SwiftTerm.Color(hex: $0) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension SwiftTerm.Color {
    // SwiftTerm colours are 16-bit per channel.
    convenience init(hex: UInt32) {
        self.init(red:   UInt16((hex >> 16) & 0xff) * 257,
                  green: UInt16((hex >> 8) & 0xff) * 257,
                  blue:  UInt16(hex & 0xff) * 257)
    }
}

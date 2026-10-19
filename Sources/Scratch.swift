import AppKit
import SwiftUI

// Scratch notepad: a small always-on-top plain-text window, toggled by kajo://scratch or the
// peek row. It drops out of the notch like the island (borderless, top edge on the island top).
// Text lives in <kajoConfigDir>/scratch.txt, saved 0.5 s after the last edit, on hide and on quit.
// (ponytail: one file, one text view, no versioning — upgrade path would be dated backups.)

/// ⌘W hides: agent apps have no File menu, so the key equivalent never reaches performClose.
/// A borderless window has no close button (performClose would beep), so Scratch sets onClose.
private final class ScratchWindow: NSWindow {
    var onClose: (() -> Void)?
    var onReset: (() -> Void)?
    override var canBecomeKey: Bool { true }   // borderless windows refuse key by default: typing needs it
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { onClose?() }   // Esc: the text view forwards it up the responder chain

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers {
            case "w":
                if let c = onClose { c() } else { performClose(nil) }
                return true
            case "0" where onReset != nil:
                onReset?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shared look for Scratch and the file viewer: floating, solid gruvbox bg0, monospaced plain text.
/// `borderless`: Scratch's notch drop-down (no title bar; the caller wraps the content and clips it).
func makeNotepadWindow(title: String, size: NSSize, floating: Bool = true, borderless: Bool = false, fontSize: CGFloat = 13) -> (NSWindow, NSTextView) {
    let w = ScratchWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: borderless ? [.borderless, .resizable] : [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
    w.title = title
    if !borderless { w.titlebarAppearsTransparent = true }
    w.isReleasedWhenClosed = false
    w.hidesOnDeactivate = false
    w.appearance = NSAppearance(named: .darkAqua)
    if floating { w.level = .floating }
    // Solid gruvbox bg0, same as the Hours window (no blur).
    w.isOpaque = true
    w.backgroundColor = NSColor(Gruv.bg0)

    let scroll = NSTextView.scrollableTextView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    let tv = scroll.documentView as! NSTextView
    tv.isRichText = false
    tv.allowsUndo = true
    tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    tv.textColor = NSColor(Gruv.fg1)
    tv.insertionPointColor = NSColor(Gruv.fg1)
    tv.drawsBackground = false
    tv.textContainerInset = NSSize(width: 6, height: 6)
    tv.isAutomaticQuoteSubstitutionEnabled = false
    tv.isAutomaticDashSubstitutionEnabled = false
    tv.isAutomaticTextReplacementEnabled = false
    tv.isAutomaticSpellingCorrectionEnabled = false
    w.contentView = scroll
    return (w, tv)
}

/// Faint bottom-right "reset size" button; brightens on hover.
private struct ScratchIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18, height: 18)
                .foregroundStyle(hovering ? Gruv.fg1 : Gruv.fg4.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Grab handle next to the reset button: press and drag moves the whole window.
private final class ScratchDragHandle: NSImageView {
    var onDrag: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        image = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: "Move")
        symbolConfiguration = .init(pointSize: 11, weight: .medium)
        contentTintColor = NSColor(Gruv.fg4).withAlphaComponent(0.7)
        toolTip = "Drag to move (reset pins it back to the notch)"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) {
        onDrag?()
        window?.performDrag(with: event)
    }
    // Cursor rects flickered against the text view's I-beam; a tracking area with cursorUpdate is reliable.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}

final class ScratchWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let shared = ScratchWindowController()
    private var window: NSWindow?
    private var textView: NSTextView?
    private var band: NSView?                  // neck band at the top, black over a real notch
    private var geo: NotchGeometry?            // notch of the screen Scratch last dropped on
    private var screen: NSScreen?
    private var frameLayer: CALayer?
    private static let toolStrip: CGFloat = 30 // bottom strip for the grab handle + reset, outside the text view
    private var pinned = true                  // false: unpinned from the notch, drag the band to move it
    private var unpinnedFrame: NSRect?         // full frame at hide time; w.frame is the 2 pt sliver by the next show
    private var animGen = 0                    // drops completions of interrupted animations
    private var animating = false
    private var pendingSave: DispatchWorkItem?
    private let url = URL(fileURLWithPath: kajoConfigDir + "/scratch.txt")

    private static let sizeKey = "ScratchSize"
    private static var defaultSize: NSSize { scratchSize }   // config.json "scratchSize", default 1300×660 (Magnus's hand size 2026-10-13); clamped to the screen in frame()
    private static let minSize = NSSize(width: 240, height: 120)

    func toggle() {
        if let w = window, w.isVisible, w.isKeyWindow {
            hide()
            NSApp.deactivate()    // hand focus back to the app we were summoned from
            return
        }
        show()
    }

    /// Same rule as PanelController.screenUnderMouse(): the display the user is looking at.
    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private var savedSize: NSSize {
        guard let s = UserDefaults.standard.string(forKey: Self.sizeKey) else { return Self.defaultSize }
        let size = NSSizeFromString(s)
        return size.width > 0 && size.height > 0 ? size : Self.defaultSize
    }

    /// Top edge on the island top (true screen top on a real notch), centred on the notch.
    private func frame(size: NSSize, _ g: NotchGeometry) -> NSRect {
        let w = max(size.width, Self.minSize.width, g.notchRect.width + 80)
        var h = max(size.height, Self.minSize.height)
        // Never hang below the screen (a MacBook is shorter than the default): leave 60pt for the Dock.
        // ponytail: screen height, not visibleFrame maths — the coordinate version clamped to a strip.
        if let s = screen { h = min(h, s.frame.height - 60) }
        return NSRect(x: g.notchRect.midX - w / 2, y: g.notchRect.minY - h, width: w, height: h)   // hangs from the bottom of the bar/notch, no neck band (Magnus: a 1300 pt black bar was pointless)
    }

    /// The same rect collapsed to the neck band, top edge fixed.
    private func sliver(_ r: NSRect, _ g: NotchGeometry) -> NSRect {
        NSRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2)
    }

    private func animate(_ w: NSWindow, to r: NSRect, done: (() -> Void)? = nil) {
        animGen += 1
        let gen = animGen
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().setFrame(r, display: true)
        }, completionHandler: { [weak self] in
            guard let me = self, me.animGen == gen else { return }
            me.animating = false
            done?()
        })
    }

    private func show() {
        if window == nil { build() }
        guard let w = window, let s = screenUnderMouse() else { return }
        let g = NotchGeometry(screen: s)
        let moved = geo.map { $0.notchRect != g.notchRect } ?? true
        geo = g; screen = s
        layoutBody()
        var target = pinned ? frame(size: savedSize, g) : (unpinnedFrame ?? w.frame)   // unpinned: drop where it was left
        if target.height <= Self.minSize.height { target = frame(size: savedSize, g) }   // never reopen as a strip
        if !w.isVisible || moved { w.setFrame(sliver(target, g), display: false) }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.makeFirstResponder(textView)
        animate(w, to: target)
    }

    /// Back up into the notch, then out of the window list. Saved right away, not in the
    /// completion, so an interrupted animation can't skip the write.
    private func hide() {
        guard let w = window, w.isVisible, let g = geo else { return }
        save()
        if !animating { unpinnedFrame = w.frame }   // mid-show frame would be half-way
        animate(w, to: sliver(w.frame, g)) { w.orderOut(nil) }
    }

    /// Dragging the handle unpins: the next show drops the window where it was left. Reset pins it back.
    private func detach() { pinned = false }

    /// Default size, pinned back on the notch; forgets the user's size.
    private func resetSize() {
        guard let w = window, let g = geo else { return }
        pinned = true
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
        animate(w, to: frame(size: Self.defaultSize, g))
    }

    private func build() {
        let (w, tv) = makeNotepadWindow(title: "Scratch", size: Self.defaultSize, borderless: true, fontSize: scratchFontSize)
        guard let sw = w as? ScratchWindow, let scroll = w.contentView else { return }
        // Above SketchyBar (it would cover the neck band at .floating), just under the island (+8).
        w.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 7)
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.minSize = Self.minSize
        w.hasShadow = false                    // a shadow would halo the notch
        // Clear window + solid bg0 layer, so the rounded bottom corners are see-through.
        w.isOpaque = false
        w.backgroundColor = .clear
        sw.onClose = { ScratchWindowController.shared.hide() }
        sw.onReset = { ScratchWindowController.shared.resetSize() }

        // Content: neck band on top, the text below, reset button bottom-right (AppKit stack,
        // autoresizing; NSTextView in SwiftUI would need a representable for no gain).
        let container = NSView(frame: NSRect(origin: .zero, size: Self.defaultSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(Gruv.bg0).cgColor
        container.layer?.cornerRadius = 18
        container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]   // bottom corners only
        container.layer?.masksToBounds = true

        let b = NSView(frame: NSRect(x: 0, y: Self.defaultSize.height, width: Self.defaultSize.width, height: 0))
        b.wantsLayer = true
        b.autoresizingMask = [.width, .minYMargin]   // height set by layoutBody() once the screen is known
        band = b

        scroll.removeFromSuperview()
        scroll.autoresizingMask = [.width, .height]
        container.addSubview(scroll)
        container.addSubview(b)

        let reset = NSHostingView(rootView: ScratchIconButton(symbol: "arrow.counterclockwise", help: "Reset size and pin to the notch (⌘0)") { ScratchWindowController.shared.resetSize() })
        reset.frame = NSRect(x: Self.defaultSize.width - 26, y: 6, width: 20, height: 20)
        reset.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(reset)
        let grip = ScratchDragHandle(frame: NSRect(x: Self.defaultSize.width - 50, y: 6, width: 20, height: 20))
        grip.onDrag = { ScratchWindowController.shared.detach() }
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        container.addSubview(grip)
        // Soppi-style frame around the body (below the band): orange while key, dimmed orange idle, 2pt,
        // bottom corners rounded.
        let f = CALayer()
        f.borderWidth = 2
        f.cornerRadius = 18
        f.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        f.borderColor = Self.frameIdle
        container.layer?.addSublayer(f)
        frameLayer = f
        w.contentView = container

        w.delegate = self
        tv.string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        tv.delegate = self
        textView = tv
        window = w
        w.setFrame(NSRect(origin: .zero, size: Self.defaultSize), display: false)

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            ScratchWindowController.shared.save()
        }
    }

    /// The scroll view sits under the band: re-fit it whenever the window (or band) changes size.
    func windowDidResize(_ notification: Notification) { layoutBody() }

    private func layoutBody() {
        guard let c = window?.contentView, let b = band, let scroll = textView?.enclosingScrollView else { return }
        let neck: CGFloat = 0   // band kept at zero height: the window starts below the bar
        b.frame = NSRect(x: 0, y: c.bounds.height - neck, width: c.bounds.width, height: neck)
        // The text stops above a 30pt strip that holds the buttons: overlapping the text view made it
        // reset the cursor on every mouse move, so the grab handle's hand kept flickering back.
        scroll.frame = NSRect(x: 0, y: Self.toolStrip, width: c.bounds.width, height: max(0, c.bounds.height - neck - Self.toolStrip))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        frameLayer?.frame = NSRect(x: 0, y: 0, width: c.bounds.width, height: max(0, c.bounds.height - neck))   // body only: the top line sits under the band
        CATransaction.commit()
    }

    private static let frameActive = NSColor(Color(hex: 0xd65d0e)).cgColor   // Soppi Gruv.borderActive
    private static let frameIdle = NSColor(Color(hex: 0xd65d0e)).withAlphaComponent(0.4).cgColor   // same orange, dimmed
    func windowDidBecomeKey(_ notification: Notification) { frameLayer?.borderColor = Self.frameActive }
    func windowDidResignKey(_ notification: Notification) { frameLayer?.borderColor = Self.frameIdle }

    /// Only the size is remembered; the position is recomputed from the notch on every show.
    func windowDidEndLiveResize(_ notification: Notification) {
        // 2026-10-13: the installed app once stored 1300×120 — the sliver (clamped to minSize) was
        // reported as a finished resize. Never save while the drop animation runs or at the sliver size.
        guard let w = window, !animating, w.frame.height > Self.minSize.height + 1 else { return }
        UserDefaults.standard.set(NSStringFromSize(w.frame.size), forKey: Self.sizeKey)
    }

    /// Any close path (⌘W, the system) slides back into the notch instead of closing.
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    func textDidChange(_ notification: Notification) {
        pendingSave?.cancel()
        let item = DispatchWorkItem { ScratchWindowController.shared.save() }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    func windowWillClose(_ notification: Notification) { save() }

    /// Only writes once the window has been built (i.e. the file was loaded), so an
    /// untouched session can never overwrite scratch.txt with an empty string.
    private func save() {
        pendingSave?.cancel(); pendingSave = nil
        guard let text = textView?.string else { return }
        try? FileManager.default.createDirectory(atPath: kajoConfigDir, withIntermediateDirectories: true)
        try? writePrivate(Data(text.utf8), to: url)
    }
}

// Text file viewer, shipped as its own bundle "Kajo Viewer.app" (Info-Viewer.plist, built by the
// Makefile from the same binary; main.swift branches on the bundle id). A separate regular app so
// Cmd+Tab and AltTab list it while Kajo itself stays hidden — AltTab blacklists per bundle id.
// Each file gets its own Scratch-looking window; editable for trimming/annotating,
// but never saved anywhere. (ponytail: whole file read into memory, no size cap — upgrade path
// would be a size check + truncation notice for huge logs.)
final class TextViewerWindowController: NSObject, NSWindowDelegate {
    private static var live: [TextViewerWindowController] = []
    private let window: NSWindow

    private init(window: NSWindow) { self.window = window }

    static func open(_ url: URL) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        // CSI sequences (colours, cursor moves), then any stray ESC left over.
        let text = raw
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}", with: "")

        // Normal level: Cmd+Tab / AltTab list it like any document window.
        let (w, tv) = makeNotepadWindow(title: url.lastPathComponent, size: NSSize(width: 700, height: 500), floating: false)
        tv.string = text
        // Frame name shared by every viewer window: size is remembered, new ones stack on top.
        if !w.setFrameUsingName("TextViewer") { w.center() }
        w.setFrameAutosaveName("TextViewer")
        let c = TextViewerWindowController(window: w)
        w.delegate = c
        live.append(c)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        DispatchQueue.main.async { tv.scrollToBeginningOfDocument(nil) }   // after first layout, else it lands at the end
    }

    func windowWillClose(_ notification: Notification) {
        Self.live.removeAll { $0 === self }
    }
}

final class ViewerAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL { TextViewerWindowController.open(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Entry point of Kajo Viewer.app (see main.swift). Never returns.
func runViewerApp() -> Never {
    let app = NSApplication.shared
    let delegate = ViewerAppDelegate()   // run() never returns, so this local keeps the weak NSApp.delegate alive
    app.delegate = delegate
    installMainMenu(quit: true)
    app.run()
    exit(0)
}

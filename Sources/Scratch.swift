import AppKit
import SwiftUI

// Scratch notepad: a small always-on-top plain-text window, toggled by kajo://scratch.
// Text lives in <kajoConfigDir>/scratch.txt, saved 0.5 s after the last edit, on hide and on quit.
// (ponytail: one file, one text view, no versioning — upgrade path would be dated backups.)

/// ⌘W hides: agent apps have no File menu, so the key equivalent never reaches performClose.
private final class ScratchWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shared look for Scratch and the file viewer: floating, solid gruvbox bg0, monospaced plain text.
func makeNotepadWindow(title: String, size: NSSize) -> (NSWindow, NSTextView) {
    let w = ScratchWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    w.title = title
    w.titlebarAppearsTransparent = true
    w.isReleasedWhenClosed = false
    w.hidesOnDeactivate = false
    w.appearance = NSAppearance(named: .darkAqua)
    w.level = .floating
    // Solid gruvbox bg0, same as the Hours window (no blur).
    w.isOpaque = true
    w.backgroundColor = NSColor(Gruv.bg0)

    let scroll = NSTextView.scrollableTextView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    let tv = scroll.documentView as! NSTextView
    tv.isRichText = false
    tv.allowsUndo = true
    tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
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

final class ScratchWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static let shared = ScratchWindowController()
    private var window: NSWindow?
    private var textView: NSTextView?
    private var pendingSave: DispatchWorkItem?
    private let url = URL(fileURLWithPath: kajoConfigDir + "/scratch.txt")

    func toggle() {
        if let w = window, w.isVisible, w.isKeyWindow {
            w.performClose(nil)   // → windowWillClose saves; close == orderOut (not released)
            NSApp.deactivate()    // hand focus back to the app we were summoned from
            return
        }
        show()
    }

    private func show() {
        if window == nil { build() }
        guard let w = window else { return }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        w.makeFirstResponder(textView)
    }

    private func build() {
        let (w, tv) = makeNotepadWindow(title: "Scratch", size: NSSize(width: 380, height: 260))
        w.delegate = self
        tv.string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        tv.delegate = self
        textView = tv

        // Restores the saved frame if there is one; centre only on first ever show.
        if !w.setFrameUsingName("Scratch") { w.center() }
        w.setFrameAutosaveName("Scratch")
        window = w

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            ScratchWindowController.shared.save()
        }
    }

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

// Text file viewer: Kajo is an "Open with…" target for plain text (CFBundleDocumentTypes in
// Info.plist). Each file gets its own Scratch-looking window; editable for trimming/annotating,
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

        let (w, tv) = makeNotepadWindow(title: url.lastPathComponent, size: NSSize(width: 700, height: 500))
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

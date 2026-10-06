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
        let w = ScratchWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Scratch"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.level = .floating
        // Solid gruvbox bg0, same as the Hours window (no blur).
        w.isOpaque = true
        w.backgroundColor = NSColor(Gruv.bg0)
        w.delegate = self

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
        tv.string = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        tv.delegate = self
        w.contentView = scroll
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

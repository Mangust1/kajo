import AppKit
import SwiftUI
import Combine
import CoreAudio
import CoreBluetooth
import IOBluetooth
import IOKit
import IOKit.ps
import CoreWLAN
import CoreLocation
import EventKit
import UniformTypeIdentifiers
import ApplicationServices   // Accessibility API (AXUIElement) for quake window control
import QuartzCore            // CADisplayLink — vsync-synced panel animation

// MARK: - Shared state

final class PanelState: ObservableObject {
    @Published var tab: Tab = Tab.allCases.first { enabledModules.contains($0) } ?? .calendar
}

// MARK: - SwiftUI content

struct PanelView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var weather: WeatherModel
    @ObservedObject var events: EventsModel
    @ObservedObject var timer: TimerModel
    @ObservedObject var nowPlaying: NowPlayingModel
    @ObservedObject var sound: SoundModel
    @ObservedObject var bluetooth: BluetoothModel
    @ObservedObject var power: PowerModel
    @ObservedObject var network: NetworkModel
    @ObservedObject var unifi: UniFiModel
    @ObservedObject var vpn: VPNModel
    @ObservedObject var ha: HAModel
    @ObservedObject var pi: PiModel
    @ObservedObject var ai: AIModel
    @ObservedObject var system: SystemModel
    @ObservedObject var memes: MemeLibrary
    @ObservedObject var clipboard: ClipboardModel
    @ObservedObject var currency: CurrencyModel

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Gruv.bg3.opacity(0.4)).frame(width: 1)
            content
        }
        .frame(width: 430, height: 660)
        .background(Gruv.bg0.opacity(0.72))
    }

    private var rail: some View {
        VStack(spacing: 1) {                       // tightened from 3 to fit 14 tabs
            ForEach(Tab.allCases.filter { enabledModules.contains($0) }) { t in
                RailIcon(tab: t, isActive: state.tab == t) { state.tab = t }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .frame(width: 60)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.tab.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Gruv.fg1)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Group {
                switch state.tab {
                case .calendar: CalendarTab(weather: weather, events: events)
                case .timer:    TimerView(model: timer)
                case .music:    MusicTab(model: nowPlaying)
                case .sound:    SoundTab(model: sound, bt: bluetooth)
                case .power:    PowerTab(model: power)
                case .network:  NetworkTab(model: network)
                case .unifi:    UniFiTab(model: unifi)
                case .vpn:      VPNTab(model: vpn)
                case .home:     HATab(model: ha)
                case .pi:       PiTab(model: pi)
                case .ai:       AITab(model: ai)
                case .system:   SystemTab(model: system)
                case .memes:    MemesTab(model: memes)
                case .clipboard: ClipboardTab(model: clipboard)
                case .currency: CurrencyTab(model: currency)
                }
            }
            .padding(.horizontal, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rail icon with hover state

struct RailIcon: View {
    let tab: Tab
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(fill)
                )
                .foregroundStyle(isActive ? Gruv.aqua : Gruv.fg4)
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var fill: Color {
        if isActive { return Gruv.aqua.opacity(0.20) }
        if hovering { return Gruv.fg4.opacity(0.14) }
        return .clear
    }
}

// MARK: - Floating panel that can become key (for Esc / focus dismissal)

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Allow positioning off-screen (above the top edge) so the slide-down
    // animation can start fully hidden instead of being clamped on-screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Panel controller

final class PanelController {
    let state = PanelState()
    let weather = WeatherModel()
    let events = EventsModel()
    let timer = TimerModel()
    let nowPlaying = NowPlayingModel()
    let sound = SoundModel()
    let bluetooth = BluetoothModel()
    let power = PowerModel()
    let network = NetworkModel()
    let unifi = UniFiModel()
    let vpn = VPNModel()
    let ha = HAModel()
    let pi = PiModel()
    let ai = AIModel()
    let system = SystemModel()
    let memes = MemeLibrary()
    let clipboard = ClipboardModel()
    let currency = CurrencyModel()
    private let panel: FloatingPanel
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?   // app that had focus before we showed
    private var cancellables = Set<AnyCancellable>()
    private let size = NSSize(width: 430, height: 660)

    init() {
        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.appearance = NSAppearance(named: .darkAqua)
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 16
        visual.layer?.masksToBounds = true
        visual.frame = NSRect(origin: .zero, size: size)

        let hosting = NSHostingView(rootView: PanelView(state: state, weather: weather, events: events, timer: timer, nowPlaying: nowPlaying, sound: sound, bluetooth: bluetooth, power: power, network: network, unifi: unifi, vpn: vpn, ha: ha, pi: pi, ai: ai, system: system, memes: memes, clipboard: clipboard, currency: currency))
        hosting.frame = visual.bounds
        hosting.autoresizingMask = [.width, .height]
        visual.addSubview(hosting)

        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = visual
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        NotificationCenter.default.addObserver(forName: .kajoDismiss, object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        }

        // Track the last externally-active app so hide() can hand focus back to it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier { self?.previousApp = app }
        }

        // Poll now-playing only while the Music tab is open.
        state.$tab
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in self?.updatePolling(forTab: tab) }
            .store(in: &cancellables)

        if enabledModules.contains(.clipboard) { clipboard.startMonitoring() }   // app-lifetime monitor, only if enabled
    }

    private func updatePolling(forTab tab: Tab) {
        if panel.isVisible && tab == .calendar { weather.refresh(); events.refresh() }
        if panel.isVisible && tab == .music { nowPlaying.startPolling() }
        else { nowPlaying.stopPolling() }
        if panel.isVisible && tab == .sound { sound.refresh(); bluetooth.refresh() }
        if panel.isVisible && tab == .power { power.startPolling() } else { power.stopPolling() }
        if panel.isVisible && tab == .network { network.refresh(); network.scan() }
        if panel.isVisible && tab == .unifi { unifi.startPolling() } else { unifi.stopPolling() }
        if panel.isVisible && tab == .vpn { vpn.startPolling() } else { vpn.stopPolling() }
        if panel.isVisible && tab == .home { ha.startPolling() } else { ha.stopPolling() }
        if panel.isVisible && tab == .pi { pi.startPolling() } else { pi.stopPolling() }
        if panel.isVisible && tab == .ai { ai.startPolling() } else { ai.stopPolling() }
        if panel.isVisible && tab == .memes { memes.search = ""; memes.load(); NSApp.activate(ignoringOtherApps: true) }
        if panel.isVisible && tab == .clipboard { clipboard.search = ""; NSApp.activate(ignoringOtherApps: true) }
    }

    func toggle(tab: Tab) {
        if panel.isVisible && state.tab == tab {
            hide()
        } else {
            state.tab = tab
            show()
        }
    }

    // CADisplayLink-driven animation state (vsync-synced; time-based so it's
    // smooth at any refresh rate — 60/100/120 Hz alike).
    private var animLink: CADisplayLink?
    private var animFrom: NSPoint = .zero
    private var animTo: NSPoint = .zero
    private var animStartT: CFTimeInterval = 0
    private var animDur: Double = 0.001
    private var animCurve: ((Double) -> Double)?
    private var animDone: (() -> Void)?

    // Bounce: drops past the resting spot, then settles back up.
    private static func easeOutBack(_ p: Double) -> Double {
        let s = 1.5
        let q = p - 1
        return 1 + (s + 1) * (q * q * q) + s * (q * q)
    }
    private static func easeInQuad(_ p: Double) -> Double { p * p }

    // Vsync-synced animation: a CADisplayLink bound to the panel's screen drives
    // frames at the display's native rate; progress is time-based so duration is
    // honored regardless of refresh rate.
    private func animateOrigin(to target: NSPoint, duration: Double,
                               curve: @escaping (Double) -> Double, then: (() -> Void)? = nil) {
        animLink?.invalidate()
        animFrom = panel.frame.origin
        animTo = target
        animDur = max(0.001, duration)
        animStartT = CACurrentMediaTime()
        animCurve = curve
        animDone = then
        let view = panel.contentView ?? NSView()
        let link = view.displayLink(target: self, selector: #selector(stepAnim))
        link.add(to: .main, forMode: .common)   // keep firing during event tracking
        animLink = link
    }

    @objc private func stepAnim() {
        let p = min(1.0, (CACurrentMediaTime() - animStartT) / animDur)
        let e = animCurve?(p) ?? p
        panel.setFrameOrigin(NSPoint(x: animFrom.x + (animTo.x - animFrom.x) * e,
                                     y: animFrom.y + (animTo.y - animFrom.y) * e))
        if p >= 1.0 {
            animLink?.invalidate(); animLink = nil
            let done = animDone; animDone = nil
            done?()
        }
    }

    private func show() {
        let final = topRightOrigin()
        panel.alphaValue = 1
        panel.setFrameOrigin(NSPoint(x: final.x, y: final.y + size.height))   // start fully above
        panel.makeKeyAndOrderFront(nil)
        if state.tab == .memes || state.tab == .clipboard { NSApp.activate(ignoringOtherApps: true) }   // text fields need the app active for keyboard focus
        animateOrigin(to: final, duration: 0.34, curve: Self.easeOutBack)
        installMonitors()
        updatePolling(forTab: state.tab)
    }

    private func hide() {
        removeMonitors()
        stopAllPolling()
        if NSApp.isActive { previousApp?.activate() }   // hand focus back to the app you came from
        let final = topRightOrigin()
        animateOrigin(to: NSPoint(x: final.x, y: final.y + size.height),
                      duration: 0.16, curve: Self.easeInQuad) { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.setFrameOrigin(final)   // reset for next open
        }
    }

    private func stopAllPolling() {
        nowPlaying.stopPolling()
        power.stopPolling()
        unifi.stopPolling()
        vpn.stopPolling()
        ha.stopPolling()
        pi.stopPolling()
    }

    private func topRightOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let gap: CGFloat = 8
        return NSPoint(x: vf.midX - size.width / 2,
                       y: vf.maxY - size.height - gap)
    }

    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {                                            // Esc
                if self.state.tab == .memes, self.memes.editingMeme != nil { self.memes.editingMeme = nil; return nil }
                self.hide(); return nil
            }
            if self.state.tab == .memes, self.memes.editingMeme == nil,
               event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v",
               self.memes.clipboardHasImage {
                self.memes.addFromClipboard(); return nil                       // ⌘V adds the clipboard image as a meme
            }
            if self.state.tab == .clipboard {                                   // ↑/↓ move the clipboard selection
                if event.keyCode == 126 { self.clipboard.move(-1); return nil }
                if event.keyCode == 125 { self.clipboard.move(1);  return nil }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor   { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Quake terminal controller (replaces Hammerspoon's Ctrl+' toggle)
//
// Toggles a drop-down kitty window titled "quake-terminal" via the Accessibility
// API. The quake kitty runs as its OWN process (kitty --instance-group quake), so
// hiding "its" app doesn't disturb the main kitty. Triggered by kajo://quake.

final class QuakeController {
    static let shared = QuakeController()

    private let quakeTitle = "quake-terminal"
    private let launcher = NSHomeDirectory() + "/.config/kitty/kitty-quake"
    private let topGap: CGFloat = 40          // clear SketchyBar so it stays visible
    private var refocusWork: [DispatchWorkItem] = []
    private var quakePID: pid_t?              // the one kitty process we manage (stable for its lifetime)
    private var isShown = false               // OUR authoritative state — we're the sole controller

    func toggle() {
        guard ensureTrusted() else { qlog("NOT TRUSTED"); return }  // first run prompts for Accessibility
        guard let app = quakeApp() else {
            qlog("branch=LAUNCH (no live quake process)"); isShown = true; launch(); discoverPIDThenShow(); return
        }
        if isShown {
            qlog("branch=HIDE (pid \(app.processIdentifier))")
            app.hide(); isShown = false
        } else {
            qlog("branch=SHOW (pid \(app.processIdentifier))")
            if let win = quakeWindow(of: app) {
                show(app: app, win: win)
            } else {
                launch(); discoverPIDThenShow()   // window was closed; recreate
            }
            isShown = true
        }
    }

    // Resolve the kitty process we manage, by tracked PID; rediscover via the
    // /tmp/mykitty-quake-<PID> socket the launcher creates if our PID is stale.
    private func quakeApp() -> NSRunningApplication? {
        if let pid = quakePID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            return app
        }
        if let pid = discoverQuakePID(), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            quakePID = pid; return app
        }
        quakePID = nil; return nil
    }

    private func discoverQuakePID() -> pid_t? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") else { return nil }
        for f in files where f.hasPrefix("mykitty-quake-") {
            if let pid = pid_t(f.dropFirst("mykitty-quake-".count)),
               let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
                return pid
            }
        }
        return nil
    }

    private func discoverPIDThenShow() {
        for delay in [0.5, 1.0, 1.5, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let app = self.quakeApp(), let win = self.quakeWindow(of: app) else { return }
                self.show(app: app, win: win); self.isShown = true
            }
        }
    }

    private func qlog(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/kajo-quake.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else { try? line.write(toFile: "/tmp/kajo-quake.log", atomically: true, encoding: .utf8) }
    }

    // MARK: trust
    @discardableResult
    private func ensureTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: discovery — the kitty *process* that owns the quake window
    private func quakeWindow(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { axString($0, kAXTitleAttribute) == quakeTitle }
    }

    // MARK: show / position / focus
    private func show(app: NSRunningApplication, win: AXUIElement) {
        if app.isHidden { app.unhide() }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        position(win)
        app.activate()
        raiseFocus(win)
        armRefocusGuard(app: app, win: win)
    }

    private func position(_ win: AXUIElement) {
        let screen = activeScreen()
        let vf = screen.visibleFrame                       // excludes menu bar / dock
        let width = vf.width * 0.8
        let height = vf.height * 0.5
        let x = vf.minX + (vf.width - width) / 2
        let cocoaTop = vf.maxY - topGap                    // window top edge (Cocoa, bottom-left origin)
        // AX uses a top-left global origin anchored on the primary display → flip Y.
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen).frame.height
        var pos = CGPoint(x: x, y: primaryHeight - cocoaTop)
        var size = CGSize(width: width, height: height)
        if let p = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        }
    }

    private func raiseFocus(_ win: AXUIElement) {
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    // Port of Hammerspoon's focus-guard: macOS Tahoe hands focus back to a "main"
    // kitty window 0.06–1.5s after toggle-on, so re-assert focus across that window.
    private func armRefocusGuard(app: NSRunningApplication, win: AXUIElement) {
        refocusWork.forEach { $0.cancel() }; refocusWork.removeAll()
        for delay in [0.06, 0.15, 0.30, 0.6, 1.0, 1.5] {
            let work = DispatchWorkItem { [weak self] in
                app.activate()
                self?.raiseFocus(win)
            }
            refocusWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: launch (cold start / warm relaunch handled by the script), then show
    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", launcher]
        try? p.run()
    }

    // MARK: AX helpers
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }
    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}

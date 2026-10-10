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
    @ObservedObject var hours: HoursModel
    @ObservedObject var severa: SeveraModel

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Gruv.bg3.opacity(0.4)).frame(width: 1)
            content
        }
        .frame(width: 430, height: 660)
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
                case .hours:    HoursTab(model: hours, severa: severa)
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

// MARK: - Notch geometry

/// Where the hardware notch sits on a screen, in global screen coordinates. A notchless screen
/// gets a virtual 160pt-wide, zero-height notch at the top centre (the island grows from the edge).
struct NotchGeometry {
    let notchRect: NSRect
    var hasNotch: Bool { notchRect.height > 0 }
    var neck: CGFloat { notchRect.height }

    init(screen: NSScreen) {
        let f = screen.frame
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            let h = screen.safeAreaInsets.top
            notchRect = NSRect(x: f.minX + l.width, y: f.maxY - h, width: f.width - l.width - r.width, height: h)
        } else {
            notchRect = NSRect(x: f.midX - 80, y: f.maxY, width: 160, height: 0)
        }
    }

    /// The collapsed window = the hover target: the notch itself, or a 10pt strip on a notchless screen.
    var collapsedRect: NSRect {
        hasNotch ? notchRect : NSRect(x: notchRect.minX, y: notchRect.maxY - 10, width: notchRect.width, height: 10)
    }
}

// MARK: - Notch model (what the SwiftUI shape animates between)

enum NotchPhase { case collapsed, peek, expanded }

final class NotchModel: ObservableObject {
    @Published var phase: NotchPhase = .collapsed
    @Published var notchWidth: CGFloat = 160
    @Published var neck: CGFloat = 0
    @Published var hoverStrip = false             // notchless + hover on: faint fill so the strip catches the mouse

    static let panelSize = CGSize(width: 430, height: 660)
    static let margin: CGFloat = 48               // room around the shape for its SwiftUI shadow
    static let peekCell: CGFloat = 32             // RailIcon at 0.8 scale, so 14+ tabs fit a peek row
    let peekTabs = Tab.allCases.filter { enabledModules.contains($0) }

    var flared: Bool { neck > 0 }                 // concave top corners only when fusing with a real notch

    func topRadius(_ p: NotchPhase) -> CGFloat {
        switch p {
        case .collapsed: return 0
        case .peek:      return flared ? 8 : 12
        case .expanded:  return flared ? 10 : 18
        }
    }
    func bottomRadius(_ p: NotchPhase) -> CGFloat {
        switch p { case .collapsed: return 8; case .peek: return 12; case .expanded: return 18 }
    }
    /// Full shape size; with a flare the shape is 2×topRadius wider than its body.
    func shapeSize(_ p: NotchPhase) -> CGSize {
        let flare = flared ? 2 * topRadius(p) : 0
        switch p {
        case .collapsed: return CGSize(width: notchWidth, height: neck)
        case .peek:
            let row = CGFloat(peekTabs.count) * Self.peekCell + 24
            return CGSize(width: max(notchWidth + 2 * 112, row + flare), height: neck + 44)
        case .expanded:  return CGSize(width: Self.panelSize.width + flare, height: neck + Self.panelSize.height)
        }
    }
    /// The open window: big enough for the widest state plus the shadow margin.
    var openWindowSize: CGSize {
        CGSize(width: max(shapeSize(.expanded).width, shapeSize(.peek).width) + 2 * Self.margin,
               height: neck + Self.panelSize.height + Self.margin)
    }
}

// MARK: - Notch shape

/// Notch outline: with `flared`, the top corners curve outward (concave) like the real notch meeting
/// the menu bar, so the black neck fuses with the hardware; otherwise plain rounded top corners.
struct NotchShape: Shape {
    var flared: Bool
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = max(r.height, 0)
        guard w > 0, h > 0 else { return p }
        var t = min(topRadius, w / 4), b = min(bottomRadius, w / 4)
        if t + b > h { let k = h / (t + b); t *= k; b *= k }      // tiny heights (collapsed): scale radii down
        if flared {
            p.move(to: CGPoint(x: 0, y: 0))
            p.addQuadCurve(to: CGPoint(x: t, y: t), control: CGPoint(x: t, y: 0))
            p.addLine(to: CGPoint(x: t, y: h - b))
            p.addQuadCurve(to: CGPoint(x: t + b, y: h), control: CGPoint(x: t, y: h))
            p.addLine(to: CGPoint(x: w - t - b, y: h))
            p.addQuadCurve(to: CGPoint(x: w - t, y: h - b), control: CGPoint(x: w - t, y: h))
            p.addLine(to: CGPoint(x: w - t, y: t))
            p.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - t, y: 0))
        } else {
            p.move(to: CGPoint(x: 0, y: t))
            p.addQuadCurve(to: CGPoint(x: t, y: 0), control: .zero)
            p.addLine(to: CGPoint(x: w - t, y: 0))
            p.addQuadCurve(to: CGPoint(x: w, y: t), control: CGPoint(x: w, y: 0))
            p.addLine(to: CGPoint(x: w, y: h - b))
            p.addQuadCurve(to: CGPoint(x: w - b, y: h), control: CGPoint(x: w, y: h))
            p.addLine(to: CGPoint(x: b, y: h))
            p.addQuadCurve(to: CGPoint(x: 0, y: h - b), control: CGPoint(x: 0, y: h))
        }
        p.closeSubpath()
        return p.offsetBy(dx: r.minX, dy: r.minY)
    }
}

/// Behind-window blur for the island body (was the panel's NSVisualEffectView content view).
struct NotchBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Notch root view

/// The whole window's content: a top-centred island whose frame springs between the three phases
/// while PanelView / the peek row sit at full size inside it and just fade.
struct NotchRoot: View {
    @ObservedObject var notch: NotchModel
    let panel: PanelView
    let pick: (Tab) -> Void

    var body: some View {
        let phase = notch.phase
        let size = notch.shapeSize(phase)
        let shape = NotchShape(flared: notch.flared, topRadius: notch.topRadius(phase), bottomRadius: notch.bottomRadius(phase))
        ZStack(alignment: .top) {
            NotchBlur()
            Gruv.bg0.opacity(0.72)
            Color.black.frame(height: notch.neck)                     // neck band: fuses with the hardware notch
            VStack(spacing: 0) {
                Color.clear.frame(height: notch.neck)
                ZStack(alignment: .top) {
                    peekRow
                        .opacity(phase == .peek ? 1 : 0)
                        .allowsHitTesting(phase == .peek)
                        .animation(phase == .peek ? .easeOut(duration: 0.18).delay(0.1) : .easeOut(duration: 0.1), value: phase)
                    panel
                        .opacity(phase == .expanded ? 1 : 0)
                        .allowsHitTesting(phase == .expanded)
                        .animation(phase == .expanded ? .easeOut(duration: 0.18).delay(0.1) : .easeOut(duration: 0.1), value: phase)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .overlay(
            shape.stroke(Gruv.bg3.opacity(0.35), lineWidth: 1)
                .mask(VStack(spacing: 0) { Color.clear.frame(height: notch.neck); Color.white })   // body only, not the neck
        )
        .shadow(color: .black.opacity(phase == .collapsed ? 0 : 0.55), radius: 22, y: 10)   // drawn here: a window shadow would halo the collapsed notch
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(notch.hoverStrip && phase == .collapsed ? 0.01 : 0))  // fully clear pixels don't receive the mouse
        .ignoresSafeArea()                                            // the window covers the notch: no safe-area push-down
    }

    /// Mini launcher shown on hover: the enabled tabs' rail icons, centred under the neck.
    private var peekRow: some View {
        HStack(spacing: 0) {
            ForEach(notch.peekTabs) { t in
                RailIcon(tab: t, isActive: false) { pick(t) }
                    .scaleEffect(NotchModel.peekCell / 40)
                    .frame(width: NotchModel.peekCell, height: NotchModel.peekCell)
            }
        }
        .frame(height: 44)
    }
}

// MARK: - Floating panel that can become key (for Esc / focus dismissal)

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Allow frames over the menu bar and the notch (AppKit would push them below it).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Tracking-area owner (any object can own one): hover into the collapsed notch → peek.
final class HoverTracker: NSResponder {
    var onEnter: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { onEnter?() }
}

// MARK: - Panel controller

final class PanelController {
    static weak var shared: PanelController?
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
    let hours = HoursModel()
    let severa = MainActor.assumeIsolated { SeveraModel() }   // app-lifetime: token + project cache survive tab switches
    let notch = NotchModel()
    private let panel: FloatingPanel
    private let tracker = HoverTracker()
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?   // app that had focus before we showed
    private var cancellables = Set<AnyCancellable>()
    private var screen: NSScreen?                    // screen the window is on right now
    private var geo: NotchGeometry?                  // that screen's notch
    private var animGen = 0                          // drops completions of interrupted animations
    private var peekWatch: Timer?

    private var isOpen: Bool { notch.phase == .expanded }

    init() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 10),
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        PanelController.shared = self
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)   // above SketchyBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false                      // NotchRoot draws the shadow
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = NotchRoot(notch: notch,
                             panel: PanelView(state: state, weather: weather, events: events, timer: timer, nowPlaying: nowPlaying, sound: sound, bluetooth: bluetooth, power: power, network: network, unifi: unifi, vpn: vpn, ha: ha, pi: pi, ai: ai, system: system, memes: memes, clipboard: clipboard, currency: currency, hours: hours, severa: severa),
                             pick: { [weak self] in self?.expand(tab: $0) })
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []                   // the controller owns the window size, not SwiftUI
        let container = NSView()                     // plain container so the tracking area isn't SwiftUI's to manage
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        tracker.onEnter = { [weak self] in self?.peek() }
        container.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                 owner: tracker, userInfo: nil))
        panel.contentView = container

        NotificationCenter.default.addObserver(forName: .kajoDismiss, object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        }
        // Lid closed, monitor plugged: the notch screen may have changed.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rehome()
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
        DispatchQueue.main.async { [weak self] in self?.rehome() }   // park collapsed in the notch once the app is running
    }

    private func updatePolling(forTab tab: Tab) {
        let open = isOpen
        if open && tab == .calendar { weather.refresh(); events.refresh() }
        if open && tab == .music { nowPlaying.startPolling() }
        else { nowPlaying.stopPolling() }
        if open && tab == .sound { sound.refresh(); bluetooth.refresh() }
        if open && tab == .power { power.startPolling() } else { power.stopPolling() }
        if open && tab == .network { network.refresh(); network.scan() }
        if open && tab == .unifi { unifi.startPolling() } else { unifi.stopPolling() }
        if open && tab == .vpn { vpn.startPolling() } else { vpn.stopPolling() }
        if open && tab == .home { ha.startPolling() } else { ha.stopPolling() }
        if open && tab == .pi { pi.startPolling() } else { pi.stopPolling() }
        if open && tab == .ai { ai.startPolling() } else { ai.stopPolling() }
        if open && tab == .memes { memes.search = ""; memes.load(); NSApp.activate(ignoringOtherApps: true) }
        if open && tab == .clipboard { clipboard.search = ""; NSApp.activate(ignoringOtherApps: true) }
        // Hours: put the caret in the task field so you can just type — but never while a
        // timer runs (that card has no field, and stealing focus mid-work is rude).
        if open && tab == .hours && hours.running == nil {
            NSApp.activate(ignoringOtherApps: true)          // non-activating panel: needed for keyboard focus
            hours.focusDraft += 1
        }
    }

    func toggle(tab: Tab) {
        if isOpen {
            if state.tab == tab { hide() } else { state.tab = tab }   // already open: just switch, don't replay the drop
        } else {
            state.tab = tab
            show()
        }
    }

    /// Open on `tab` (from the peek row); just switches if already open.
    func expand(tab: Tab) {
        state.tab = tab
        if !isOpen { show() }
    }

    /// Back into the notch from either open state.
    func collapse() {
        if isOpen { hide(); return }
        guard notch.phase == .peek else { return }
        animate(to: .collapsed, .spring(response: 0.3, dampingFraction: 0.85)) { $0.settleCollapsed() }
    }

    func closePanel() { hide() }

    // MARK: geometry

    /// Collapsed home: the first screen with a notch, else the main screen.
    private func homeScreen() -> NSScreen? {
        NSScreen.screens.first { NotchGeometry(screen: $0).hasNotch } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Screen under the mouse = the SketchyBar you clicked. NSScreen.main is the screen of
    /// the focused app's window, which sent the panel to the other display.
    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Point the model at `s`'s notch (instant, no animation — only called while collapsed or before opening).
    private func use(_ s: NSScreen) {
        let g = NotchGeometry(screen: s)
        screen = s; geo = g
        notch.neck = g.neck
        notch.notchWidth = g.notchRect.width
        notch.hoverStrip = notchHover && !g.hasNotch
    }

    /// Open frame: centred on the notch, flush with the TRUE top of the screen (over the menu bar).
    private func openFrame() -> NSRect {
        guard let s = screen, let g = geo else { return panel.frame }
        let size = notch.openWindowSize
        return NSRect(x: g.notchRect.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    private func rehome() {
        guard notch.phase == .collapsed, let s = homeScreen() else { return }   // an open panel re-homes when it closes
        use(s)
        panel.setFrame(geo?.collapsedRect ?? panel.frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: phases

    /// Spring the island to `phase`; `settled` runs once the animation is fully done, unless
    /// another phase change came in meanwhile.
    private func animate(to phase: NotchPhase, _ anim: Animation, settled: ((PanelController) -> Void)? = nil) {
        animGen += 1
        let gen = animGen
        withAnimation(anim, completionCriteria: .removed) {
            notch.phase = phase
        } completion: { [weak self] in
            guard let me = self, me.animGen == gen else { return }
            settled?(me)
        }
    }

    /// Hover into the collapsed notch → mini launcher.
    private func peek() {
        guard notchHover, notch.phase == .collapsed, let g = geo,
              g.collapsedRect.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) else { return }   // not the big window mid-close
        grow { me in
            me.animate(to: .peek, .spring(response: 0.3, dampingFraction: 0.85))
            me.watchPeek()
        }
    }

    /// Window big first, the shape springs on the NEXT run-loop turn: resizing the window in the same
    /// layout pass as the spring made SwiftUI interpolate the shape's position from its spot in the
    /// small window, so the panel looked like it opened from the top-left.
    private func grow(then: @escaping (PanelController) -> Void) {
        panel.setFrame(openFrame(), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in if let me = self { then(me) } }
    }

    /// Collapse the peek once the mouse has been outside it for 0.25 s. Polled (only while peeking)
    /// because the window is much bigger than the peek shape, so window exit events come too late.
    private func watchPeek() {
        peekWatch?.invalidate()
        var outsideSince: CFTimeInterval?
        peekWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let me = self, me.notch.phase == .peek, let s = me.screen, let g = me.geo else { t.invalidate(); return }
            let size = me.notch.shapeSize(.peek)
            let rect = NSRect(x: g.notchRect.midX - size.width / 2, y: s.frame.maxY - size.height,
                              width: size.width, height: size.height).insetBy(dx: -6, dy: -6)
            if rect.contains(NSEvent.mouseLocation) { outsideSince = nil; return }
            let now = CACurrentMediaTime()
            if let since = outsideSince { if now - since >= 0.25 { t.invalidate(); me.collapse() } }
            else { outsideSince = now }
        }
    }

    private func show() {
        if let s = screenUnderMouse() { use(s) }
        grow { me in me.animate(to: .expanded, .spring(response: 0.42, dampingFraction: 0.78)) }
        panel.makeKeyAndOrderFront(nil)
        if state.tab == .memes || state.tab == .clipboard { NSApp.activate(ignoringOtherApps: true) }   // text fields need the app active for keyboard focus
        installMonitors()
        updatePolling(forTab: state.tab)
    }

    private func hide() {
        guard isOpen else { collapse(); return }     // kajoDismiss also fires while collapsed/peeking
        removeMonitors()
        stopAllPolling()
        if NSApp.isActive { previousApp?.activate() }   // hand focus back to the app you came from
        animate(to: .collapsed, .spring(response: 0.32, dampingFraction: 1.0)) { $0.settleCollapsed() }
    }

    /// Closed for good: shrink the window back to the home notch. Never orderOut for long — the
    /// collapsed window is the hover target; the orderOut/orderFront pair just drops key status
    /// so a collapsed panel can't swallow keystrokes.
    private func settleCollapsed() {
        guard let s = homeScreen() else { return }
        use(s)
        panel.orderOut(nil)
        panel.setFrame(geo?.collapsedRect ?? panel.frame, display: true)
        panel.orderFrontRegardless()
    }

    private func stopAllPolling() {
        nowPlaying.stopPolling()
        power.stopPolling()
        unifi.stopPolling()
        vpn.stopPolling()
        ha.stopPolling()
        pi.stopPolling()
        ai.stopPolling()
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

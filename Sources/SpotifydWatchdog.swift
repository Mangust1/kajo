import AppKit
import Network

// spotifyd watchdog ("musicSource": "spotifyd" + "spotifydLaunchLabel"). After a network change
// librespot can hang mid-login (DNS errors, then a stuck login5 request) and never re-register,
// so the process lives on at 0 % CPU while /me/player/devices lacks `spotifyDevice`. Triggers:
// wake (+15 s), the network path becoming satisfied again (+10 s), and any "device not found".
// Check: device missing → look again 10 s later → still missing → `launchctl kickstart -k` the
// user LaunchAgent (no sudo; its KeepAlive would start a dead spotifyd anyway, so no process check).
// ponytail: at most one kick per 2 min and 5 per hour; a spotifyd that stays broken beyond that
// is left to the user. Upgrade path: back off exponentially and surface a persistent warning.
final class SpotifydWatchdog {
    private let label: String
    private weak var web: SpotifyWeb?
    /// Device listed again after a kick (volume already being restored).
    var onRecovered: (() -> Void)?

    private var monitor: NWPathMonitor?
    private var lastStatus: NWPath.Status?
    private var pending: DispatchWorkItem?
    private var checking = false
    private var kicks: [Date] = []
    private var wakeObserver: NSObjectProtocol?

    init(label: String, web: SpotifyWeb) {
        self.label = label
        self.web = web
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.schedule(after: 15) }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let was = self.lastStatus
                self.lastStatus = path.status
                if path.status == .satisfied, was != nil, was != .satisfied { self.schedule(after: 10) }
            }
        }
        m.start(queue: .global(qos: .utility))
        monitor = m
    }

    deinit {
        monitor?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    /// Run a check after `delay` seconds; a newer trigger replaces a pending one.
    func schedule(after delay: Double) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.check() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func check() {
        guard !checking, let web, web.hasToken else { return }
        checking = true
        web.deviceListed { [weak self] listed in
            guard let self else { return }
            guard listed == false else { self.checking = false; return }   // listed, or the read failed (offline): leave it
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                self.web?.deviceListed { listed in
                    guard listed == false else { self.checking = false; return }
                    self.kick()
                }
            }
        }
    }

    private func kick() {
        let now = Date()
        kicks = kicks.filter { now.timeIntervalSince($0) < 3600 }
        guard let web, kicks.count < 5, kicks.last.map({ now.timeIntervalSince($0) >= 120 }) ?? true else { checking = false; return }
        kicks.append(now)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "-k", "gui/\(getuid())/\(label)"]
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async {
                guard let self, let web = self.web else { return }
                guard status == 0 else {
                    web.caption = "spotifyd restart failed (launchctl exit \(status))"; self.checking = false; return
                }
                web.caption = "Restarted spotifyd (it lost its connection)"
                web.waitForDevice(named: web.deviceName, tries: 15) { d in
                    self.checking = false
                    guard d != nil else { return }
                    if let v = NowPlayingModel.lastVolume { web.restoreVolume(v) }
                    self.onRecovered?()
                }
            }
        }
        do { try p.run() } catch { web.caption = "spotifyd restart failed: \(error.localizedDescription)"; checking = false }
    }
}

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

// MARK: - Pi (home-server health via the kajo-health container)

struct PiContainer: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var state: String          // running, exited, restarting, …
    var health: String?        // healthy, unhealthy, starting, or nil
}

struct PiStatus: Codable, Equatable {
    var reachable = false
    var source = ""            // "lan" (live) or "cloud" (S3 snapshot via CloudFront)
    var tsEpoch = 0            // payload "ts" — snapshot age for staleness
    var hostname = ""
    var uptimeSec = 0
    var cpuPercent = 0.0
    var cpuCount = 0
    var memUsedMB = 0
    var memTotalMB = 0
    var memPercent = 0.0
    var diskUsedGB = 0.0
    var diskTotalGB = 0.0
    var diskPercent = 0.0
    var tempC: Double? = nil
    var load: [Double] = []
    var containers: [PiContainer] = []
}

final class PiModel: ObservableObject {
    @Published var status = PiStatus()
    @Published var loading = false
    @Published private(set) var everLoaded = false
    @Published var configured = false

    private var local = "", remote = "", remoteHeader = "X-Kajo-Token", remoteToken = ""
    private var session: URLSession!
    private var timer: Timer?
    private var inFlight = false
    // A cloud snapshot older than this means the Pi stopped pushing → it's down.
    static let staleAfter: TimeInterval = 150

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        session = URLSession(configuration: cfg)
        loadConfig()
        if let data = UserDefaults.standard.data(forKey: "pi.cache"),
           let cached = try? JSONDecoder().decode(PiStatus.self, from: data) {
            status = cached
        }
    }

    private func loadConfig() {
        let j = loadConfigJSON("pi.json")
        guard !j.isEmpty else { configured = false; return }
        // `local` (LAN) with `url` accepted as a legacy alias; `remote` (CloudFront) optional.
        local = (j["local"] as? String ?? j["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        remote = (j["remote"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        remoteHeader = (j["remoteHeader"] as? String ?? "X-Kajo-Token")
        remoteToken = (j["remoteToken"] as? String ?? "")
        configured = !local.isEmpty || !remote.isEmpty
    }

    func startPolling() {
        guard configured else { return }
        stopPolling(); refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard configured, !inFlight else { return }   // LAN timeout + cloud timeout can exceed the 5 s tick
        loading = true; inFlight = true
        // LAN first (live, fast). Fall back to the CloudFront snapshot when away.
        fetch(local, timeoutOverride: 2.5) { [weak self] lan in
            guard let self else { return }
            if var s = lan { s.source = "lan"; self.apply(s); return }
            // A malformed `remote` in pi.json is a config error, not a reason to crash every 5 s.
            guard !self.remote.isEmpty, let remoteURL = URL(string: self.remote) else { self.markUnreachable(); return }
            var req = URLRequest(url: remoteURL)
            if !self.remoteToken.isEmpty { req.setValue(self.remoteToken, forHTTPHeaderField: self.remoteHeader) }
            self.fetch(req) { cloud in
                if var s = cloud { s.source = "cloud"; self.apply(s) }
                else { self.markUnreachable() }
            }
        }
    }

    private func apply(_ incoming: PiStatus) {
        var s = incoming
        // A stale cloud snapshot = the Pi stopped pushing = it's down.
        if s.source == "cloud", s.tsEpoch > 0,
           Date().timeIntervalSince1970 - Double(s.tsEpoch) > Self.staleAfter {
            s.reachable = false
        }
        DispatchQueue.main.async {
            self.loading = false; self.inFlight = false
            self.everLoaded = true
            self.status = s
            if let enc = try? JSONEncoder().encode(s) {
                UserDefaults.standard.set(enc, forKey: "pi.cache")   // keep last view for instant open
            }
        }
    }

    private func markUnreachable() {
        DispatchQueue.main.async {
            self.loading = false; self.inFlight = false
            self.everLoaded = true
            self.status.reachable = false       // keep cached metrics, just flag offline
            self.status.source = ""
        }
    }

    private func fetch(_ urlString: String, timeoutOverride: TimeInterval,
                       completion: @escaping (PiStatus?) -> Void) {
        guard let url = URL(string: urlString) else { completion(nil); return }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeoutOverride
        fetch(req, completion: completion)
    }

    private func fetch(_ req: URLRequest, completion: @escaping (PiStatus?) -> Void) {
        session.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let host = j["host"] as? [String: Any] else { completion(nil); return }
            var s = PiStatus()
            s.reachable = true
            s.tsEpoch = j["ts"] as? Int ?? 0
            s.hostname = host["hostname"] as? String ?? ""
            s.uptimeSec = host["uptime_sec"] as? Int ?? 0
            s.cpuPercent = host["cpu_percent"] as? Double ?? 0
            s.cpuCount = host["cpu_count"] as? Int ?? 0
            s.tempC = host["temp_c"] as? Double
            s.load = (host["load"] as? [Double]) ?? []
            if let m = host["mem"] as? [String: Any] {
                s.memUsedMB = m["used_mb"] as? Int ?? 0
                s.memTotalMB = m["total_mb"] as? Int ?? 0
                s.memPercent = m["percent"] as? Double ?? 0
            }
            if let d = host["disk"] as? [String: Any] {
                s.diskUsedGB = d["used_gb"] as? Double ?? 0
                s.diskTotalGB = d["total_gb"] as? Double ?? 0
                s.diskPercent = d["percent"] as? Double ?? 0
            }
            if let cs = j["containers"] as? [[String: Any]] {
                s.containers = cs.map {
                    PiContainer(name: $0["name"] as? String ?? "?",
                                state: $0["state"] as? String ?? "",
                                health: $0["health"] as? String)
                }
            }
            completion(s)
        }.resume()
    }
}

struct PiTab: View {
    @ObservedObject var model: PiModel

    var body: some View {
        let s = model.status
        if !model.configured {
            hint("No Pi config", "Add ~/.config/kajo/pi.json")
        } else if !s.reachable && !model.everLoaded && s.hostname.isEmpty {
            hint("Connecting…", "Reaching the Pi")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    header(s)
                    if !s.reachable {
                        offlineBanner
                    }
                    metrics(s)
                    if !s.containers.isEmpty { containerList(s) }
                }
                .padding(.bottom, 8)
                .opacity(s.reachable ? 1 : 0.55)      // dim stale data when offline
            }
        }
    }

    private func header(_ s: PiStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .font(.system(size: 22))
                .foregroundStyle(s.reachable ? Gruv.green : Gruv.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.hostname.isEmpty ? "Raspberry Pi" : s.hostname)
                    .font(.headline).foregroundStyle(Gruv.fg0)
                Text(s.reachable ? "Online · up \(uptime(s.uptimeSec))" : "Offline")
                    .font(.caption).foregroundStyle(s.reachable ? Gruv.green : Gruv.red)
            }
            Spacer()
            if s.reachable, !s.source.isEmpty {
                sourceBadge(s.source)
            } else if model.loading && !model.everLoaded {
                Text("updating…").font(.caption2).foregroundStyle(Gruv.gray)
            }
        }
    }

    // Where the data came from: LAN = live, cloud = S3 snapshot via CloudFront.
    private func sourceBadge(_ source: String) -> some View {
        let lan = source == "lan"
        return HStack(spacing: 4) {
            Image(systemName: lan ? "wifi" : "cloud.fill").font(.system(size: 9))
            Text(lan ? "LAN" : "cloud")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(lan ? Gruv.green : Gruv.blue)
        .padding(.vertical, 3).padding(.horizontal, 7)
        .background(Capsule().fill((lan ? Gruv.green : Gruv.blue).opacity(0.15)))
    }

    private var offlineBanner: some View {
        let ts = model.status.tsEpoch
        let msg = ts > 0
            ? "Pi stopped reporting — last seen \(lastSeen(ts))"
            : "Health endpoint unreachable — Pi may be down"
        return HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Gruv.red)
            Text(msg).font(.caption).foregroundStyle(Gruv.fg2)
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.red.opacity(0.12)))
    }

    private func lastSeen(_ tsEpoch: Int) -> String {
        let secs = max(0, Int(Date().timeIntervalSince1970) - tsEpoch)
        if secs < 90 { return "\(secs)s ago" }
        let m = secs / 60
        if m < 60 { return "\(m)m ago" }
        let h = m / 60
        return h < 24 ? "\(h)h ago" : "\(h / 24)d ago"
    }

    private func metrics(_ s: PiStatus) -> some View {
        VStack(spacing: 9) {
            bar("CPU", s.cpuPercent, "\(Int(s.cpuPercent))%")
            bar("RAM", s.memPercent, "\(gb(s.memUsedMB)) / \(gb(s.memTotalMB))")
            bar("Disk", s.diskPercent, String(format: "%.0f / %.0f GB", s.diskUsedGB, s.diskTotalGB))
            HStack(spacing: 14) {
                if let t = s.tempC {
                    pill("thermometer.medium", String(format: "%.0f°C", t), tempColor(t))
                }
                if !s.load.isEmpty {
                    pill("gauge.with.dots.needle.50percent",
                         s.load.map { String(format: "%.2f", $0) }.joined(separator: " "), Gruv.fg2)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func bar(_ label: String, _ percent: Double, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(Gruv.fg4)
                Spacer()
                Text(value).font(.caption).foregroundStyle(Gruv.fg1).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Gruv.bg3.opacity(0.5))
                    Capsule().fill(loadColor(percent))
                        .frame(width: geo.size.width * min(1, max(0, percent / 100)))
                }
            }
            .frame(height: 5)
        }
    }

    private func pill(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption).monospacedDigit()
        }
        .foregroundStyle(color)
        .padding(.vertical, 4).padding(.horizontal, 9)
        .background(Capsule().fill(Gruv.bg1.opacity(0.6)))
    }

    private func containerList(_ s: PiStatus) -> some View {
        let running = s.containers.filter { $0.state == "running" }.count
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Containers").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
                Spacer()
                Text("\(running)/\(s.containers.count) up").font(.caption2).foregroundStyle(Gruv.gray)
            }
            ForEach(s.containers) { c in
                HStack(spacing: 9) {
                    Circle().fill(dotColor(c)).frame(width: 7, height: 7)
                    Text(c.name).foregroundStyle(c.state == "running" ? Gruv.fg1 : Gruv.fg4).lineLimit(1)
                    Spacer()
                    Text(label(c)).font(.caption).foregroundStyle(dotColor(c))
                }
                .font(.callout)
                .padding(.vertical, 3)
            }
        }
        .padding(.top, 2)
    }

    private func label(_ c: PiContainer) -> String {
        if let h = c.health { return h }
        return c.state
    }

    private func dotColor(_ c: PiContainer) -> Color {
        if c.state != "running" { return Gruv.red }
        switch c.health {
        case "healthy": return Gruv.green
        case "unhealthy": return Gruv.red
        case "starting": return Gruv.yellow
        default: return Gruv.green       // running, no healthcheck defined
        }
    }

    private func loadColor(_ p: Double) -> Color {
        switch p { case ..<60: return Gruv.green; case ..<85: return Gruv.yellow; default: return Gruv.red }
    }
    private func tempColor(_ t: Double) -> Color {
        switch t { case ..<60: return Gruv.green; case ..<75: return Gruv.yellow; default: return Gruv.red }
    }

    private func gb(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1fG", Double(mb) / 1024) : "\(mb)M"
    }
    private func uptime(_ s: Int) -> String {
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

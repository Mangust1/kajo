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

// MARK: - UniFi (controller stats via local account)

struct WANLink: Identifiable, Codable {
    var id: String { name }
    var name: String
    var availability: Double
    var latency: Int
    var active: Bool
}

struct UniFiStatus: Codable {
    var reachable = false
    var wanStatus = ""
    var wanIP = ""
    var gateway = ""
    var isp = ""
    var rxRate = 0          // bytes/s
    var txRate = 0
    var latencyMs = -1
    var uptimeSec = 0
    var clients = 0
    var guests = 0
    var links: [WANLink] = []
}

final class UniFiModel: NSObject, ObservableObject, URLSessionDelegate {
    @Published var status = UniFiStatus()
    @Published var loading = false
    @Published private(set) var everLoaded = false
    @Published var configured = false

    private var session: URLSession!
    private var host = "", username = "", password = "", site = "default"
    private var timer: Timer?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        loadConfig()
        // Show last-known data instantly on launch.
        if let data = UserDefaults.standard.data(forKey: "unifi.cache"),
           let cached = try? JSONDecoder().decode(UniFiStatus.self, from: data) {
            status = cached
        }
    }

    private func loadConfig() {
        let path = kajoConfigDir + "/unifi.json"
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            configured = false; return
        }
        host = (j["host"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        username = j["username"] as? String ?? ""
        password = j["password"] as? String ?? ""
        site = j["site"] as? String ?? "default"
        configured = !host.isEmpty && !username.isEmpty
    }

    func startPolling() {
        guard configured else { return }
        stopPolling()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        guard configured else { return }
        loading = true
        Task { [weak self] in
            guard let self else { return }
            // Reuse the session cookie; only (re)login if the request fails.
            var health = await self.getJSON("/proxy/network/api/s/\(self.site)/stat/health")
            if health == nil, await self.login() {
                health = await self.getJSON("/proxy/network/api/s/\(self.site)/stat/health")
            }
            var s = UniFiStatus()
            if let health, let arr = health["data"] as? [[String: Any]] {
                s.reachable = true
                for sub in arr {
                    switch sub["subsystem"] as? String {
                    case "wan":
                        s.wanStatus = sub["status"] as? String ?? ""
                        s.wanIP = sub["wan_ip"] as? String ?? ""
                        s.gateway = sub["gw_name"] as? String ?? ""
                        s.isp = sub["isp_name"] as? String ?? ""
                        s.rxRate = sub["rx_bytes-r"] as? Int ?? 0
                        s.txRate = sub["tx_bytes-r"] as? Int ?? 0
                        if let us = sub["uptime_stats"] as? [String: Any] {
                            s.links = us.compactMap { name, v in
                                guard let d = v as? [String: Any] else { return nil }
                                return WANLink(name: name,
                                               availability: d["availability"] as? Double ?? 0,
                                               latency: d["latency_average"] as? Int ?? -1,
                                               active: false)
                            }.sorted { $0.name < $1.name }
                        }
                    case "www":
                        s.latencyMs = sub["latency"] as? Int ?? -1
                        s.uptimeSec = sub["uptime"] as? Int ?? 0
                    case "wlan":
                        s.clients = sub["num_user"] as? Int ?? s.clients
                        s.guests = sub["num_guest"] as? Int ?? s.guests
                    default: break
                    }
                }
                // Active WAN ≈ the link whose latency matches the live www latency.
                if s.latencyMs >= 0, let i = s.links.indices.min(by: {
                    abs(s.links[$0].latency - s.latencyMs) < abs(s.links[$1].latency - s.latencyMs)
                }) {
                    s.links[i].active = true
                }
            }
            await MainActor.run {
                self.loading = false
                self.everLoaded = true
                if s.reachable {                       // only update on success; keep cache on failure
                    self.status = s
                    if let data = try? JSONEncoder().encode(s) {
                        UserDefaults.standard.set(data, forKey: "unifi.cache")
                    }
                }
            }
        }
    }

    private func login() async -> Bool {
        guard let url = URL(string: host + "/api/auth/login") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        guard let (_, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return true
    }

    private func getJSON(_ path: String) async -> [String: Any]? {
        guard let url = URL(string: host + path),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return j
    }

    // Accept the controller's self-signed cert (LAN home gateway).
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

struct UniFiTab: View {
    @ObservedObject var model: UniFiModel

    var body: some View {
        let s = model.status
        VStack(alignment: .leading, spacing: 14) {
            if !model.configured {
                hint("No UniFi config", "Add ~/.config/kajo/unifi.json")
            } else if !s.reachable {
                hint("Controller unreachable", model.loading ? "Connecting…" : "On home network or Twingate?")
            } else {
                header(s)
                VStack(spacing: 0) {
                    if !s.isp.isEmpty { row("ISP", s.isp) }
                    CopyableIPRow(label: "WAN IP", value: s.wanIP.isEmpty ? "—" : s.wanIP)
                    if s.latencyMs >= 0 { row("Latency", "\(s.latencyMs) ms") }
                    row("Throughput", "↓ \(rate(s.rxRate))   ↑ \(rate(s.txRate))")
                    row("Clients", "\(s.clients)" + (s.guests > 0 ? " (+\(s.guests) guest)" : ""))
                    if s.uptimeSec > 0 { row("Uptime", uptime(s.uptimeSec)) }
                }
                if !s.links.isEmpty { uplinks(s) }
            }
            Spacer()
            openUIButton
        }
    }

    // Opens UniFi's global remote portal — works from anywhere, not just the LAN.
    private var openUIButton: some View {
        Button { AppLauncher.openURL("https://unifi.ui.com") } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 14))
                Text("Open UniFi UI")
                Spacer()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Gruv.aqua)
            .padding(.vertical, 9)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Gruv.aqua.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }

    private func uplinks(_ s: UniFiStatus) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Uplinks").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
            ForEach(s.links) { link in
                HStack(spacing: 8) {
                    Circle().fill(link.active ? Gruv.green : Gruv.fg4.opacity(0.5))
                        .frame(width: 7, height: 7)
                    Text(link.name).foregroundStyle(link.active ? Gruv.fg0 : Gruv.fg2)
                    if link.active { Text("active").font(.caption2).foregroundStyle(Gruv.green) }
                    Spacer()
                    Text("\(Int(link.availability))%  ·  \(link.latency)ms")
                        .font(.caption).foregroundStyle(Gruv.gray).monospacedDigit()
                }
                .font(.callout)
                .padding(.vertical, 4)
            }
        }
        .padding(.top, 4)
    }

    private func rate(_ bps: Int) -> String {
        let b = Double(bps)
        if b >= 1_000_000 { return String(format: "%.1f MB/s", b / 1_000_000) }
        if b >= 1000 { return String(format: "%.0f KB/s", b / 1000) }
        return "\(bps) B/s"
    }

    private func header(_ s: UniFiStatus) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 22)).foregroundStyle(ok(s.wanStatus))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.gateway.isEmpty ? "UniFi" : s.gateway)
                    .font(.headline).foregroundStyle(Gruv.fg0)
                Text(s.wanStatus == "ok" ? "WAN up" : "WAN \(s.wanStatus)")
                    .font(.caption).foregroundStyle(ok(s.wanStatus))
            }
            Spacer()
            if model.loading && !model.everLoaded {
                Text("updating…").font(.caption2).foregroundStyle(Gruv.gray)
            }
        }
        .padding(.bottom, 4)
    }

    private func row(_ label: String, _ value: String, color: Color = Gruv.fg1) -> some View {
        HStack {
            Text(label).foregroundStyle(Gruv.fg4)
            Spacer()
            Text(value).foregroundStyle(color)
        }
        .font(.callout)
        .padding(.vertical, 9)
        .overlay(Rectangle().fill(Gruv.bg3.opacity(0.3)).frame(height: 1), alignment: .bottom)
    }

    private func hint(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Gruv.fg2)
            Text(sub).font(.callout).foregroundStyle(Gruv.gray)
        }
        .padding(.top, 8)
    }

    private func ok(_ status: String) -> Color { status == "ok" ? Gruv.green : (status.isEmpty ? Gruv.fg4 : Gruv.red) }
    private func uptime(_ s: Int) -> String {
        let d = s / 86400, h = (s % 86400) / 3600
        return d > 0 ? "\(d)d \(h)h" : "\(h)h \((s % 3600) / 60)m"
    }
}

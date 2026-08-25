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

// MARK: - Network (Wi-Fi toggle, current network, service priority)

enum SpeedEngine: String { case builtin, ookla }

struct WiFiNetwork: Identifiable, Equatable, Codable {
    let id: String
    let ssid: String
    let rssi: Int
    let secure: Bool
}

final class NetworkModel: ObservableObject {
    private struct NetCache: Codable {
        var ssid = "—"; var ip = "—"; var publicIP = "…"; var wifiFirst = true
        var activeService = ""; var networks: [WiFiNetwork] = []
    }
    private var lastScan = Date.distantPast

    init() {
        if let data = UserDefaults.standard.data(forKey: "net.cache"),
           let c = try? JSONDecoder().decode(NetCache.self, from: data) {
            ssid = c.ssid; ip = c.ip; publicIP = c.publicIP; wifiFirst = c.wifiFirst
            activeService = c.activeService; networks = c.networks
        }
    }

    private func saveCache() {
        let c = NetCache(ssid: ssid, ip: ip, publicIP: publicIP, wifiFirst: wifiFirst,
                         activeService: activeService, networks: networks)
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "net.cache") }
    }

    @Published var wifiOn = true
    @Published var ssid = "—"
    @Published var ip = "—"
    @Published var publicIP = "…"
    @Published var activeService = ""   // interface actually carrying the default route now
    @Published var wifiFirst = true
    @Published var working = false
    @Published var networks: [WiFiNetwork] = []
    @Published var scanning = false
    @Published var connecting = ""    // ssid currently being joined
    @Published var speedtesting = false
    @Published var speedPhase = ""    // "Downloading…" / "Uploading…"
    @Published var speedEngine = SpeedEngine(rawValue: UserDefaults.standard.string(forKey: "net.speedEngine") ?? "") ?? .builtin {
        didSet { UserDefaults.standard.set(speedEngine.rawValue, forKey: "net.speedEngine") }
    }
    // Ookla's official CLI streams live speeds; nil if not installed.
    let ooklaPath: String? = ["/opt/homebrew/bin/speedtest", "/usr/local/bin/speedtest"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    @Published var speedDown = ""     // "123 Mbps"
    @Published var speedUp = ""
    @Published var speedPing = ""     // "22 ms"

    // Labeled multi-line summary for the clipboard.
    var speedSummary: String {
        let engine = speedEngine == .ookla ? "Ookla speed test" : "Apple speed test"
        func v(_ s: String) -> String { s.isEmpty ? "—" : s }
        return "\(engine)\ndown: \(v(speedDown))  up: \(v(speedUp))  ping: \(v(speedPing))"
    }

    private let dev = "en0"           // Wi-Fi interface on this Mac
    private let wifiService = "Wi-Fi" // service name in the order list
    private var order: [String] = []

    func scan(force: Bool = false) {
        guard !scanning else { return }
        // Cached and fresh → skip the slow re-scan, keep showing what we have.
        if !force, !networks.isEmpty, Date().timeIntervalSince(lastScan) < 25 { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [WiFiNetwork] = []
            if let iface = CWWiFiClient.shared().interface() {
                // Only networks you've set up (preferred / known profiles).
                let profiles = iface.configuration()?.networkProfiles.array as? [CWNetworkProfile]
                let known = Set(profiles?.compactMap { $0.ssid } ?? [])
                if let set = try? iface.scanForNetworks(withSSID: nil) {
                    var seen = Set<String>()
                    for n in set {
                        guard let s = n.ssid, !s.isEmpty, known.contains(s), !seen.contains(s) else { continue }
                        seen.insert(s)
                        found.append(WiFiNetwork(id: s, ssid: s, rssi: n.rssiValue,
                                                 secure: !n.supportsSecurity(.none)))
                    }
                }
            }
            found.sort { $0.rssi > $1.rssi }
            DispatchQueue.main.async {
                self?.scanning = false
                if !found.isEmpty {                    // don't wipe the cache on a failed/empty scan
                    self?.networks = found
                    self?.lastScan = Date()
                    self?.saveCache()
                }
            }
        }
    }

    func connect(ssid: String, password: String) {
        connecting = ssid
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if let iface = CWWiFiClient.shared().interface(),
               let set = try? iface.scanForNetworks(withSSID: ssid.data(using: .utf8)),
               let net = set.first(where: { $0.ssid == ssid }) {
                try? iface.associate(to: net, password: password.isEmpty ? nil : password)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.connecting = ""
                self.refresh()
            }
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let on = (self.sh("/usr/sbin/networksetup", ["-getairportpower", self.dev]) ?? "").contains(": On")
            let ssid = self.currentSSID()
            let ip = (self.sh("/usr/sbin/ipconfig", ["getifaddr", self.dev]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ord = self.readOrder()
            let active = self.primaryService()
            DispatchQueue.main.async {
                self.wifiOn = on
                self.ssid = on ? (ssid.isEmpty ? "Not connected" : ssid) : "Off"
                self.ip = ip.isEmpty ? "—" : ip
                self.order = ord
                self.wifiFirst = ord.first == self.wifiService
                self.activeService = active
                self.saveCache()
            }
        }
        fetchPublicIP()
    }

    // Interface actually carrying the default route right now, mapped to its
    // service name (e.g. "Wi-Fi", "Thunderbolt Ethernet Slot 1"). This is the
    // *real* primary — it can differ from the Wi-Fi first/last preference.
    private func primaryService() -> String {
        let out = sh("/sbin/route", ["-n", "get", "default"]) ?? ""
        var iface = ""
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                iface = String(t.dropFirst("interface:".count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }
        guard !iface.isEmpty else { return "" }
        let order = sh("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) ?? ""
        for line in order.split(separator: "\n") where line.contains("Device: \(iface))") {
            if let r = line.range(of: "Hardware Port: "),
               let c = line.range(of: ", Device:", range: r.upperBound..<line.endIndex) {
                return String(line[r.upperBound..<c.lowerBound])
            }
        }
        return iface
    }

    private func fetchPublicIP() {
        guard let url = URL(string: "https://api.ipify.org") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let ip = data.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                self?.publicIP = (ip?.isEmpty == false) ? ip! : "unavailable"
                self?.saveCache()
            }
        }.resume()
    }

    func speedtest() {
        guard !speedtesting else { return }
        speedtesting = true; speedDown = ""; speedUp = ""; speedPing = ""; speedPhase = ""
        if speedEngine == .ookla, ooklaPath != nil { runOokla() } else { runBuiltin() }
    }

    // macOS built-in throughput test (Monterey+). Two phases so each result
    // lands as soon as it's measured (piped output only emits at phase end).
    private func runBuiltin() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            func run(_ args: [String]) -> [String: Any]? {
                let out = self.sh("/usr/bin/networkQuality", ["-c"] + args) ?? ""
                return out.data(using: .utf8).flatMap {
                    try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                }
            }
            func mbps(_ json: [String: Any]?, _ key: String) -> String {
                guard let bps = json?[key] as? Double else { return "—" }
                return String(format: "%.0f Mbps", bps / 1_000_000)
            }
            DispatchQueue.main.async { self.speedPhase = "Downloading…" }
            let dlJson = run(["-u"])                  // -u: skip upload
            let dl = mbps(dlJson, "dl_throughput")
            let ping = (dlJson?["base_rtt"] as? Double).map { String(format: "%.0f ms", $0) } ?? "—"
            DispatchQueue.main.async { self.speedDown = dl; self.speedPing = ping; self.speedPhase = "Uploading…" }
            let ul = mbps(run(["-d"]), "ul_throughput")   // -d: skip download
            DispatchQueue.main.async {
                self.speedUp = ul; self.speedPhase = ""; self.speedtesting = false
            }
        }
    }

    // Ookla CLI: parse the jsonl stream line-by-line for live Mbps (bytes/sec → *8).
    private func runOokla() {
        guard let path = ooklaPath else { runBuiltin(); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-f", "jsonl", "-p", "no", "--accept-license", "--accept-gdpr"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        let h = pipe.fileHandleForReading
        var buf = Data()
        h.readabilityHandler = { [weak self] fh in
            buf.append(fh.availableData)
            while let nl = buf.firstIndex(of: 0x0a) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                self?.handleOoklaLine(line)
            }
        }
        p.terminationHandler = { [weak self] _ in
            h.readabilityHandler = nil
            DispatchQueue.main.async { self?.speedPhase = ""; self?.speedtesting = false }
        }
        do { try p.run() } catch { runBuiltin() }
    }

    private func handleOoklaLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        func mbps(_ key: String) -> String? {
            guard let d = obj[key] as? [String: Any], let bw = d["bandwidth"] as? Double else { return nil }
            return String(format: "%.0f Mbps", bw * 8 / 1_000_000)
        }
        func ping() -> String? {
            guard let d = obj["ping"] as? [String: Any], let lat = d["latency"] as? Double else { return nil }
            return String(format: "%.0f ms", lat)
        }
        DispatchQueue.main.async {
            switch type {
            case "ping":     self.speedPhase = "Latency…";     ping().map { self.speedPing = $0 }
            case "download": self.speedPhase = "Downloading…"; mbps("download").map { self.speedDown = $0 }
            case "upload":   self.speedPhase = "Uploading…";   mbps("upload").map { self.speedUp = $0 }
            case "result":   mbps("download").map { self.speedDown = $0 }; mbps("upload").map { self.speedUp = $0 }; ping().map { self.speedPing = $0 }
            default: break
            }
        }
    }

    func toggleWiFi() {
        let target = wifiOn ? "off" : "on"
        wifiOn.toggle()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = self.sh("/usr/sbin/networksetup", ["-setairportpower", self.dev, target])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refresh() }
        }
    }

    func setWiFiPriority(first: Bool) {
        guard !order.isEmpty else { return }
        var names = order.filter { $0 != wifiService }
        if first { names.insert(wifiService, at: 0) } else { names.append(wifiService) }
        working = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Passwordless via a scoped /etc/sudoers.d rule — no prompt.
            _ = self.sh("/usr/bin/sudo", ["-n", "/usr/sbin/networksetup", "-ordernetworkservices"] + names)
            DispatchQueue.main.async { self.working = false; self.refresh() }
        }
    }

    private func currentSSID() -> String {
        // Prefer CoreWLAN (same source the scan uses, so SSIDs match exactly).
        if let s = CWWiFiClient.shared().interface()?.ssid(), !s.isEmpty { return s }
        let out = sh("/usr/sbin/ipconfig", ["getsummary", dev]) ?? ""
        for sub in out.split(separator: "\n") {
            let t = sub.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("SSID ") || t.hasPrefix("SSID:") else { continue }
            if let r = t.range(of: ":") {
                return String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    private func readOrder() -> [String] {
        let out = sh("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) ?? ""
        var result: [String] = []
        for sub in out.split(separator: "\n") {
            let s = String(sub)
            if let r = s.range(of: #"^\([*0-9]+\)\s+"#, options: .regularExpression) {
                result.append(String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return result
    }

    private func sh(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(data: d, encoding: .utf8)
    }
}

struct NetworkTab: View {
    @ObservedObject var model: NetworkModel
    @State private var selected = ""     // ssid awaiting password
    @State private var password = ""
    @State private var speedCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 11) {
                        Image(systemName: model.wifiOn ? "wifi" : "wifi.slash")
                            .font(.system(size: 18))
                            .foregroundStyle(model.wifiOn ? Gruv.aqua : Gruv.fg4)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Wi-Fi").foregroundStyle(Gruv.fg1)
                            Text(model.ssid).font(.caption).foregroundStyle(Gruv.gray).lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { model.wifiOn }, set: { _ in model.toggleWiFi() }))
                            .labelsHidden().toggleStyle(.switch).tint(Gruv.green)
                    }

                    CopyableIPRow(label: "Wi-Fi IP", value: model.ip)
                    CopyableIPRow(label: "Public IP", value: model.publicIP)

                    priority
                    if model.wifiOn { networksList }
                }
                .padding(.bottom, 8)
            }

            Divider().overlay(Gruv.bg3)
            speedtest
        }
    }

    private var speedtest: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speed").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
                // reserve the phase slot so nothing shifts when it fills in
                Text(model.speedtesting ? model.speedPhase : " ")
                    .font(.caption2).foregroundStyle(Gruv.gray)
                Spacer()
                if model.ooklaPath != nil { engineToggle }
            }
            HStack {
                speedStat("arrow.down", model.speedDown.isEmpty ? "—" : model.speedDown, Gruv.green)
                speedStat("arrow.up", model.speedUp.isEmpty ? "—" : model.speedUp, Gruv.aqua)
                if !model.speedDown.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.speedSummary, forType: .string)
                        speedCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { speedCopied = false }
                    } label: {
                        Image(systemName: speedCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption).foregroundStyle(speedCopied ? Gruv.green : Gruv.fg4)
                    }
                    .buttonStyle(.plain).help("Copy results")
                }
                Spacer()
                Button { model.speedtest() } label: {
                    HStack(spacing: 5) {
                        if model.speedtesting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "gauge.with.dots.needle.67percent") }
                        Text(model.speedtesting ? "Testing…" : "Run test")
                    }
                    .font(.callout.weight(.medium)).foregroundStyle(Gruv.aqua)
                }
                .buttonStyle(.plain).disabled(model.speedtesting)
            }
        }
    }

    private var engineToggle: some View {
        HStack(spacing: 0) {
            enginePill("Built-in", .builtin)
            enginePill("Ookla", .ookla)
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(Gruv.bg1.opacity(0.7)))
        .opacity(model.speedtesting ? 0.5 : 1)
        .disabled(model.speedtesting)
    }

    private func enginePill(_ label: String, _ engine: SpeedEngine) -> some View {
        let active = model.speedEngine == engine
        return Button { model.speedEngine = engine } label: {
            Text(label)
                .font(.caption2.weight(.medium))
                .padding(.vertical, 3).padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Gruv.aqua.opacity(0.22) : .clear))
                .foregroundStyle(active ? Gruv.aqua : Gruv.fg4)
        }
        .buttonStyle(.plain)
    }

    private func speedStat(_ icon: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(value).font(.callout).foregroundStyle(Gruv.fg1)
        }
    }

    private var priority: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Priority").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
            if !model.activeService.isEmpty {
                let wifiActive = model.activeService == "Wi-Fi"
                let matches = model.wifiFirst == wifiActive   // actual vs. wished
                HStack(spacing: 5) {
                    Image(systemName: matches ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text("Active now: \(model.activeService)").font(.caption).lineLimit(1)
                }
                .foregroundStyle(matches ? Gruv.green : Gruv.yellow)
            }
            Text(model.wifiFirst ? "Wi-Fi preferred over Ethernet"
                                 : "Ethernet preferred over Wi-Fi")
                .font(.caption).foregroundStyle(Gruv.gray)
            HStack(spacing: 8) {
                priorityButton("Wi-Fi First", active: model.wifiFirst) { model.setWiFiPriority(first: true) }
                priorityButton("Wi-Fi Last", active: !model.wifiFirst) { model.setWiFiPriority(first: false) }
            }
            .disabled(model.working)
            .opacity(model.working ? 0.5 : 1)
        }
    }

    private var networksList: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Networks").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
                if model.scanning { Text("updating…").font(.caption2).foregroundStyle(Gruv.gray) }
                Spacer()
                Button { model.scan(force: true) } label: {
                    Image(systemName: "arrow.clockwise").font(.caption).foregroundStyle(Gruv.fg4)
                }.buttonStyle(.plain).disabled(model.scanning)
            }
            ForEach(model.networks) { net in
                networkRow(net)
            }
        }
    }

    @ViewBuilder
    private func networkRow(_ net: WiFiNetwork) -> some View {
        let isCurrent = net.ssid == model.ssid
        Button {
            if isCurrent { return }
            if net.secure { selected = (selected == net.ssid) ? "" : net.ssid; password = "" }
            else { model.connect(ssid: net.ssid, password: "") }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: signalIcon(net.rssi)).frame(width: 18).foregroundStyle(Gruv.fg4)
                Text(net.ssid).foregroundStyle(isCurrent ? Gruv.aqua : Gruv.fg1).lineLimit(1)
                if net.secure { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Gruv.fg4) }
                Spacer()
                if model.connecting == net.ssid { ProgressView().controlSize(.small) }
                else if isCurrent { Image(systemName: "checkmark").foregroundStyle(Gruv.green) }
            }
            .font(.callout)
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isCurrent ? Gruv.bg1.opacity(0.6) : .clear))
        }
        .buttonStyle(.plain)

        if selected == net.ssid {
            HStack(spacing: 8) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                Button("Join") {
                    model.connect(ssid: net.ssid, password: password)
                    selected = ""; password = ""
                }
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(Gruv.aqua)
            }
            .padding(.leading, 27).padding(.bottom, 4)
        }
    }

    private func signalIcon(_ rssi: Int) -> String {
        switch rssi {
        case (-60)...:   return "wifi"
        case (-72)..<(-60): return "wifi"
        default:          return "wifi"   // SF Symbols has no graded wifi; keep uniform
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Gruv.fg4)
            Spacer()
            Text(value).foregroundStyle(Gruv.fg1)
        }
        .font(.callout)
        .padding(.vertical, 9)
        .overlay(Rectangle().fill(Gruv.bg3.opacity(0.3)).frame(height: 1), alignment: .bottom)
    }

    private func priorityButton(_ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 9)
                    .fill(active ? Gruv.aqua.opacity(0.22) : Gruv.bg1.opacity(0.7)))
                .foregroundStyle(active ? Gruv.aqua : Gruv.fg2)
        }
        .buttonStyle(.plain)
    }
}

// IP row with a click-to-copy button (checkmark flashes on copy).
struct CopyableIPRow: View {
    let label: String
    let value: String
    @State private var copied = false

    var body: some View {
        HStack {
            Text(label).foregroundStyle(Gruv.fg4)
            Spacer()
            Text(value).foregroundStyle(Gruv.fg1)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? Gruv.green : Gruv.fg4)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(value == "—" || value == "…" || value.isEmpty)
        }
        .font(.callout)
        .padding(.vertical, 9)
        .overlay(Rectangle().fill(Gruv.bg3.opacity(0.3)).frame(height: 1), alignment: .bottom)
    }
}

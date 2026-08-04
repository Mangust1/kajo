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

struct WiFiNetwork: Identifiable, Equatable, Codable {
    let id: String
    let ssid: String
    let rssi: Int
    let secure: Bool
}

final class NetworkModel: ObservableObject {
    private struct NetCache: Codable {
        var ssid = "—"; var ip = "—"; var publicIP = "…"; var wifiFirst = true; var networks: [WiFiNetwork] = []
    }
    private var lastScan = Date.distantPast

    init() {
        if let data = UserDefaults.standard.data(forKey: "net.cache"),
           let c = try? JSONDecoder().decode(NetCache.self, from: data) {
            ssid = c.ssid; ip = c.ip; publicIP = c.publicIP; wifiFirst = c.wifiFirst; networks = c.networks
        }
    }

    private func saveCache() {
        let c = NetCache(ssid: ssid, ip: ip, publicIP: publicIP, wifiFirst: wifiFirst, networks: networks)
        if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "net.cache") }
    }

    @Published var wifiOn = true
    @Published var ssid = "—"
    @Published var ip = "—"
    @Published var publicIP = "…"
    @Published var wifiFirst = true
    @Published var working = false
    @Published var networks: [WiFiNetwork] = []
    @Published var scanning = false
    @Published var connecting = ""    // ssid currently being joined

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
            DispatchQueue.main.async {
                self.wifiOn = on
                self.ssid = on ? (ssid.isEmpty ? "Not connected" : ssid) : "Off"
                self.ip = ip.isEmpty ? "—" : ip
                self.order = ord
                self.wifiFirst = ord.first == self.wifiService
                self.saveCache()
            }
        }
        fetchPublicIP()
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

    var body: some View {
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

                row("Local IP", model.ip)
                row("Public IP", model.publicIP)

                priority
                if model.wifiOn { networksList }
            }
            .padding(.bottom, 8)
        }
    }

    private var priority: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Priority").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
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

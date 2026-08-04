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

// MARK: - VPN (Twingate / OpenVPN / NordVPN — detect via utun + process)

struct VPNEntry: Identifiable {
    let id: String
    let name: String
    let app: String
    var active: Bool
    var ip: String
}

final class VPNModel: ObservableObject {
    @Published var twingate = VPNEntry(id: "tg", name: "Twingate", app: "Twingate", active: false, ip: "")
    @Published var openvpn  = VPNEntry(id: "ov", name: "OpenVPN", app: "OpenVPN Connect", active: false, ip: "")
    @Published var nordvpn  = VPNEntry(id: "nd", name: "NordVPN", app: "NordVPN", active: false, ip: "")
    // Tailscale is *controllable* (connect/disconnect via its CLI), unlike the
    // launch-only VPNs above. Its IP is also 100.64/10, so we detect it via the
    // CLI and exclude its address from the Twingate heuristic.
    @Published var tailscaleUp = false
    @Published var tailscaleIP = ""
    @Published var tailscaleBusy = false

    private static let tsBin = "/opt/homebrew/bin/tailscale"
    private var timer: Timer?
    var entries: [VPNEntry] { [twingate, openvpn, nordvpn] }
    var anyActive: Bool { twingate.active || openvpn.active || nordvpn.active || tailscaleUp }

    func startPolling() {
        stopPolling(); refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Up/down is authoritative via BackendState. `tailscale ip -4` reports
            // the node's assigned IP even when STOPPED, so it can't gauge up/down.
            var tsUp = false
            if let d = Self.runTS(["status", "--json"]).data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                tsUp = (o["BackendState"] as? String) == "Running"
            }
            let tsip = tsUp ? (Self.runTS(["ip", "-4"]).split(separator: "\n").first.map(String.init) ?? "") : ""
            var tg = false, ov = false, nd = false, tgip = "", ovip = "", ndip = ""
            for ip in self.utunIPv4s() {
                if ip == tsip { continue }                                          // Tailscale's own utun — handled above
                if ip.hasPrefix("10.15.10.") || ip.hasPrefix("169.254.") { continue }  // Sidecar / link-local
                let o = ip.split(separator: ".").compactMap { Int($0) }
                if o.count == 4 && o[0] == 100 && o[1] >= 64 && o[1] <= 127 { tg = true; tgip = ip }   // CGNAT 100.64/10
                else if ip.hasPrefix("10.5.0.") { nd = true; ndip = ip }                              // NordLynx
                else { ov = true; ovip = ip }                                                         // OpenVPN
            }
            if tg && !self.processRunning("Twingate") { tg = false; tgip = "" }
            if ov && !self.processRunning("ovpnagent") { ov = false; ovip = "" }
            DispatchQueue.main.async {
                if !self.tailscaleBusy { self.tailscaleUp = tsUp; self.tailscaleIP = tsip }
                self.twingate.active = tg; self.twingate.ip = tgip
                self.openvpn.active = ov;  self.openvpn.ip = ovip
                self.nordvpn.active = nd;  self.nordvpn.ip = ndip
            }
        }
    }

    private func utunIPv4s() -> [String] {
        var ips: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return ips }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            if name.hasPrefix("utun"), let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    ips.append(String(cString: host))
                }
            }
            ptr = cur.pointee.ifa_next
        }
        return ips
    }

    private func processRunning(_ name: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", name]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // Run the tailscale CLI, return trimmed stdout ("" on failure).
    private static func runTS(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tsBin)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func toggleTailscale() {
        tailscaleBusy = true
        let goingUp = !tailscaleUp
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // --accept-dns=false: never let Tailscale hijack DNS via MagicDNS
            // (100.100.100.100), which broke Google/Anthropic resolution.
            _ = Self.runTS(goingUp ? ["up", "--accept-dns=false"] : ["down"])
            Thread.sleep(forTimeInterval: 0.6)                 // let the interface settle
            DispatchQueue.main.async { self?.tailscaleBusy = false; self?.refresh() }
        }
    }
}

struct VPNTab: View {
    @ObservedObject var model: VPNModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tailscale — connect/disconnect right here (CLI-controlled).
            HStack(spacing: 11) {
                Image(systemName: model.tailscaleUp ? "lock.fill" : "lock.open")
                    .font(.system(size: 16)).frame(width: 22)
                    .foregroundStyle(model.tailscaleUp ? Gruv.green : Gruv.fg4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tailscale").foregroundStyle(Gruv.fg1)
                    Text(model.tailscaleUp ? "Connected · \(model.tailscaleIP)" : "Off")
                        .font(.caption)
                        .foregroundStyle(model.tailscaleUp ? Gruv.green : Gruv.gray)
                }
                Spacer()
                if model.tailscaleBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle("", isOn: Binding(get: { model.tailscaleUp }, set: { _ in model.toggleTailscale() }))
                        .labelsHidden().toggleStyle(.switch).tint(Gruv.green)
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(model.tailscaleUp ? Gruv.green.opacity(0.12) : Gruv.bg1.opacity(0.5)))

            ForEach(model.entries) { vpn in
                Button { AppLauncher.openApp(named: vpn.app) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: vpn.active ? "lock.fill" : "lock.open")
                            .font(.system(size: 16)).frame(width: 22)
                            .foregroundStyle(vpn.active ? Gruv.green : Gruv.fg4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(vpn.name).foregroundStyle(Gruv.fg1)
                            Text(vpn.active ? "Connected · \(vpn.ip)" : "Off")
                                .font(.caption)
                                .foregroundStyle(vpn.active ? Gruv.green : Gruv.gray)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.forward.app").font(.caption).foregroundStyle(Gruv.fg4)
                    }
                    .padding(.vertical, 9).padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(vpn.active ? Gruv.green.opacity(0.12) : Gruv.bg1.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

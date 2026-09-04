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

// MARK: - Home Assistant (lights + cottage entities)

struct HAEntity: Identifiable {
    var id: String { entityId }
    let entityId: String
    let domain: String
    let name: String
    var state: String
    var unit: String
    var targetTemp: Double?   // climate setpoint (attr "temperature"), not the measured temp
}

// TLS is validated normally: HA sits behind a real (Let's Encrypt) certificate, and
// this session carries the bearer token that can unlock the front door.
final class HAModel: ObservableObject {
    @Published var lights: [HAEntity] = []
    @Published var sensors: [HAEntity] = []
    @Published var configured = false
    @Published var reachable = false
    @Published var busy: Set<String> = []

    private var url = "", token = ""
    private var wanted: [String] = []
    private let session: URLSession
    private var timer: Timer?
    private var inFlight = false

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        session = URLSession(configuration: cfg)
        loadConfig()
    }

    private func loadConfig() {
        let j = loadConfigJSON("ha.json")
        guard !j.isEmpty else { configured = false; return }
        url = (j["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        token = j["token"] as? String ?? ""
        wanted = j["entities"] as? [String] ?? []
        configured = !url.isEmpty && !token.isEmpty && !wanted.isEmpty
    }

    func startPolling() {
        guard configured else { return }
        stopPolling(); refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    // One request at a time: a slow host must not stack up overlapping polls.
    func refresh() {
        guard configured, !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            guard let self else { return }
            await self.load()
            await MainActor.run { self.inFlight = false }
        }
    }

    func toggle(_ e: HAEntity) {
        let service: String
        if e.domain == "lock" {
            service = (e.state == "locked") ? "unlock" : "lock"
        } else if e.domain == "light" || e.domain == "switch" {
            service = "toggle"
        } else { return }
        busy.insert(e.entityId)
        Task { [weak self] in
            guard let self else { return }
            await self.callService(domain: e.domain, service: service, entity: e.entityId)
            try? await Task.sleep(nanoseconds: 400_000_000)
            await self.load()
            await MainActor.run { _ = self.busy.remove(e.entityId) }
        }
    }

    private func load() async {
        guard let states = await getStates() else {
            await MainActor.run { self.reachable = false }; return
        }
        var byId: [String: [String: Any]] = [:]
        for s in states { if let id = s["entity_id"] as? String { byId[id] = s } }
        var lts: [HAEntity] = [], sns: [HAEntity] = []
        for id in wanted {
            guard let s = byId[id] else { continue }
            let domain = String(id.prefix { $0 != "." })
            let attrs = s["attributes"] as? [String: Any] ?? [:]
            let e = HAEntity(entityId: id, domain: domain,
                             name: attrs["friendly_name"] as? String ?? id,
                             state: s["state"] as? String ?? "",
                             unit: attrs["unit_of_measurement"] as? String ?? "",
                             targetTemp: attrs["temperature"] as? Double)
            if e.domain == "light" || e.domain == "switch" || e.domain == "lock" { lts.append(e) } else { sns.append(e) }
        }
        await MainActor.run { [lts, sns] in self.lights = lts; self.sensors = sns; self.reachable = true }
    }

    private func getStates() async -> [[String: Any]]? {
        guard let u = URL(string: url + "/api/states") else { return nil }
        var req = URLRequest(url: u)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr
    }

    private func callService(domain: String, service: String, entity: String) async {
        guard let u = URL(string: url + "/api/services/\(domain)/\(service)") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["entity_id": entity])
        _ = try? await session.data(for: req)
    }
}

/// Front-door lock row. Locking is a single tap (no risk); UNLOCKING requires a
/// press-and-hold that fills a capsule over ~1.1s, so it can't fire from a stray tap.
struct LockRow: View {
    @ObservedObject var model: HAModel
    let entity: HAEntity
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var work: DispatchWorkItem?

    private let pillW: CGFloat = 124
    private let pillH: CGFloat = 26
    private let holdDuration = 1.1

    var body: some View {
        let locked = entity.state == "locked"
        let off = entity.state == "unavailable" || entity.state == "unknown"
        let busy = model.busy.contains(entity.entityId)
        return HStack(spacing: 10) {
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .frame(width: 20)
                .foregroundStyle(off ? Gruv.fg4 : (locked ? Gruv.green : Gruv.red))
            Text(entity.name).foregroundStyle(off ? Gruv.fg4 : Gruv.fg1).lineLimit(1)
            Spacer()
            if busy {
                ProgressView().controlSize(.small).frame(width: pillW, alignment: .trailing)
            } else if off {
                Text("unavailable").font(.caption2).foregroundStyle(Gruv.gray)
            } else if locked {
                holdToUnlock
            } else {
                lockButton
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
    }

    private var holdToUnlock: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Gruv.bg1)
            Capsule().fill(Gruv.yellow).frame(width: progress * pillW)
            HStack(spacing: 5) {
                Image(systemName: "lock.open.fill").font(.caption2)
                Text(holding ? "Keep holding…" : "Hold to unlock")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(progress > 0.45 ? Gruv.bg0 : Gruv.fg2)
            .frame(width: pillW, height: pillH)
        }
        .frame(width: pillW, height: pillH)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Gruv.bg3, lineWidth: 1))
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in beginHold() }
                .onEnded { _ in cancelHold() }
        )
    }

    private var lockButton: some View {
        Button { model.toggle(entity) } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.fill").font(.caption2)
                Text("Lock").font(.caption2.weight(.semibold))
            }
            .foregroundStyle(Gruv.bg0)
            .frame(width: pillW, height: pillH)
            .background(Capsule().fill(Gruv.green))
        }
        .buttonStyle(.plain)
    }

    private func beginHold() {
        guard !holding else { return }   // onChanged repeats; only arm once per press
        holding = true
        withAnimation(.linear(duration: holdDuration)) { progress = 1 }
        let w = DispatchWorkItem {
            model.toggle(entity)   // state is "locked" here → sends unlock
            holding = false
            progress = 0
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: w)
    }

    private func cancelHold() {
        work?.cancel(); work = nil
        holding = false
        withAnimation(.easeOut(duration: 0.18)) { progress = 0 }
    }
}

struct HATab: View {
    @ObservedObject var model: HAModel

    var body: some View {
        if !model.configured {
            hint("No HA config", "Add ~/.config/kajo/ha.json")
        } else if !model.reachable && model.lights.isEmpty && model.sensors.isEmpty {
            hint("Home Assistant unreachable", "On home network or Twingate?")
        } else {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.lights.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Home").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
                            ForEach(model.lights) { e in
                                if e.domain == "lock" { LockRow(model: model, entity: e) } else { lightRow(e) }
                            }
                        }
                    }
                    if !model.sensors.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Mökki").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
                            ForEach(model.sensors) { sensorRow($0) }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func lightRow(_ e: HAEntity) -> some View {
        let on = e.state == "on"
        let off = e.state == "unavailable"
        return HStack(spacing: 10) {
            Image(systemName: on ? "lightbulb.fill" : "lightbulb")
                .frame(width: 20)
                .foregroundStyle(on ? Gruv.yellow : Gruv.fg4)
            Text(e.name).foregroundStyle(off ? Gruv.fg4 : Gruv.fg1).lineLimit(1)
            Spacer()
            if model.busy.contains(e.entityId) {
                ProgressView().controlSize(.small)
            } else if off {
                Text("unavailable").font(.caption2).foregroundStyle(Gruv.gray)
            } else {
                Toggle("", isOn: Binding(get: { on }, set: { _ in model.toggle(e) }))
                    .labelsHidden().toggleStyle(.switch).tint(Gruv.green)
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
    }

    private func sensorRow(_ e: HAEntity) -> some View {
        HStack {
            Image(systemName: icon(e)).frame(width: 20).foregroundStyle(Gruv.aqua)
            Text(e.name).foregroundStyle(Gruv.fg1).lineLimit(1)
            Spacer()
            Text(value(e)).foregroundStyle(Gruv.fg0).monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 6)
        .overlay(Rectangle().fill(Gruv.bg3.opacity(0.25)).frame(height: 1), alignment: .bottom)
    }

    private func icon(_ e: HAEntity) -> String {
        if e.domain == "climate" { return "thermometer.medium" }
        let n = e.name.lowercased()
        if n.contains("temperature") { return "thermometer" }
        if n.contains("energy") { return "bolt" }
        return "sensor"
    }

    private func value(_ e: HAEntity) -> String {
        if e.domain == "climate" {
            let t = e.targetTemp.map { String(format: "%.0f°", $0) } ?? ""
            return "\(e.state.capitalized) \(t)".trimmingCharacters(in: .whitespaces)
        }
        let u = e.unit.isEmpty ? "" : " \(e.unit)"
        return e.state + u
    }
}

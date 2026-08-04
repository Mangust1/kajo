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

// MARK: - AI (oMLX status + Claude usage)

final class AIModel: ObservableObject {
    @Published var omlxRunning = false
    @Published var omlxModels: [String] = []
    @Published var tokensToday = 0
    @Published var messagesToday = 0
    @Published var localTokensToday = 0
    @Published var localRequestsToday = 0

    private var omlxKey = ""
    private let omlxBase: String
    private var timer: Timer?
    private var lastClaude = Date.distantPast

    init() {
        // ai.json (optional): { "omlxURL": "http://host:port" }
        let cfg = (try? Data(contentsOf: URL(fileURLWithPath: kajoConfigDir + "/ai.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        omlxBase = (cfg["omlxURL"] as? String) ?? "http://127.0.0.1:8000"
        if let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.omlx/settings.json"),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let auth = j["auth"] as? [String: Any] {
            omlxKey = auth["api_key"] as? String ?? ""
        }
    }

    func startPolling() {
        stopPolling()
        refreshOMLX()
        readLocalStats()
        computeClaude()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            self?.refreshOMLX()
            self?.readLocalStats()
            self?.computeClaude()
        }
    }
    func stopPolling() { timer?.invalidate(); timer = nil }

    func openDashboard() { AppLauncher.openURL(omlxBase + "/admin") }

    private func refreshOMLX() {
        guard let url = URL(string: omlxBase + "/v1/models") else { return }
        var req = URLRequest(url: url, timeoutInterval: 3)
        if !omlxKey.isEmpty { req.setValue("Bearer \(omlxKey)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            var models: [String] = []
            if ok, let data,
               let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = j["data"] as? [[String: Any]] {
                models = arr.compactMap { $0["id"] as? String }
            }
            DispatchQueue.main.async { self?.omlxRunning = ok; self?.omlxModels = models }
        }.resume()
    }

    // oMLX writes a *lifetime* token counter to ~/.omlx/stats.json. We keep a
    // per-day baseline in UserDefaults and show the delta, so the figure reads
    // as "today" like the Claude block. Rebases on a new day or if oMLX resets
    // the counter (current < baseline).
    private func readLocalStats() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = NSHomeDirectory() + "/.omlx/stats.json"
            guard let data = FileManager.default.contents(atPath: path),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let totalTokens = (j["total_prompt_tokens"] as? Int ?? 0) + (j["total_completion_tokens"] as? Int ?? 0)
            let totalReqs = j["total_requests"] as? Int ?? 0

            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let today = df.string(from: Date())
            let ud = UserDefaults.standard
            var baseTokens = ud.integer(forKey: "omlx.base.tokens")
            var baseReqs = ud.integer(forKey: "omlx.base.requests")
            if ud.string(forKey: "omlx.base.date") != today || totalTokens < baseTokens || totalReqs < baseReqs {
                ud.set(today, forKey: "omlx.base.date")
                ud.set(totalTokens, forKey: "omlx.base.tokens")
                ud.set(totalReqs, forKey: "omlx.base.requests")
                baseTokens = totalTokens; baseReqs = totalReqs
            }
            let todTokens = max(0, totalTokens - baseTokens)
            let todReqs = max(0, totalReqs - baseReqs)
            DispatchQueue.main.async { self?.localTokensToday = todTokens; self?.localRequestsToday = todReqs }
        }
    }

    // Sum today's Claude Code usage from the live transcripts (throttled).
    private func computeClaude() {
        guard Date().timeIntervalSince(lastClaude) > 25 else { return }
        lastClaude = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let base = NSHomeDirectory() + "/.claude/projects"
            let fm = FileManager.default
            let cal = Calendar.current
            var tokens = 0, msgs = 0
            if let projects = try? fm.contentsOfDirectory(atPath: base) {
                for proj in projects {
                    let dir = base + "/" + proj
                    guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                    for f in files where f.hasSuffix(".jsonl") {
                        let path = dir + "/" + f
                        guard let attrs = try? fm.attributesOfItem(atPath: path),
                              let mod = attrs[.modificationDate] as? Date, cal.isDateInToday(mod),
                              let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                        for line in content.split(separator: "\n") where line.contains("output_tokens") {
                            guard let d = line.data(using: .utf8),
                                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                                  let msg = obj["message"] as? [String: Any],
                                  let usage = msg["usage"] as? [String: Any] else { continue }
                            tokens += (usage["output_tokens"] as? Int ?? 0) + (usage["input_tokens"] as? Int ?? 0)
                            msgs += 1
                        }
                    }
                }
            }
            DispatchQueue.main.async { self?.tokensToday = tokens; self?.messagesToday = msgs }
        }
    }
}

struct AITab: View {
    @ObservedObject var model: AIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { model.openDashboard() } label: {
                HStack(spacing: 10) {
                    Circle().fill(model.omlxRunning ? Gruv.green : Gruv.red).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("oMLX").foregroundStyle(Gruv.fg1)
                        Text(model.omlxRunning
                             ? "Running · \(model.omlxModels.count) model\(model.omlxModels.count == 1 ? "" : "s")"
                             : "Stopped")
                            .font(.caption).foregroundStyle(model.omlxRunning ? Gruv.green : Gruv.gray)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").font(.caption).foregroundStyle(Gruv.fg4)
                }
                .padding(.vertical, 9).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Gruv.bg1.opacity(0.5)))
            }
            .buttonStyle(.plain)

            if !model.omlxModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Loaded").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
                    ForEach(model.omlxModels, id: \.self) { m in
                        HStack(spacing: 8) {
                            Image(systemName: "cpu").font(.caption).foregroundStyle(Gruv.aqua).frame(width: 16)
                            Text(m).font(.callout).foregroundStyle(Gruv.fg2).lineLimit(1)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("oMLX · today").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
                    .padding(.bottom, 4)
                statRow("Tokens", model.localTokensToday > 0 ? fmt(model.localTokensToday) : "—")
                statRow("Requests", "\(model.localRequestsToday)")
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Claude Code · today").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
                    .padding(.bottom, 4)
                statRow("Tokens", model.tokensToday > 0 ? fmt(model.tokensToday) : "—")
                statRow("Messages", "\(model.messagesToday)")
            }
            Spacer()
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Gruv.fg4)
            Spacer()
            Text(value).foregroundStyle(Gruv.fg1).monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 8)
        .overlay(Rectangle().fill(Gruv.bg3.opacity(0.25)).frame(height: 1), alignment: .bottom)
    }

    private func fmt(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
                       : (n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)")
    }
}

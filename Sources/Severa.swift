import Foundation

// MARK: - Severa (Visma) REST — "my projects" for the Hours tab
//
// Config (~/.config/kajo/severa.json, off-repo):
//   { "url": "https://api.severa.visma.com/rest-api",
//     "clientId": "...", "clientSecret": "...", "userGuid": "...",
//     "roundUpMinutes": 30, "timeZone": "Europe/Helsinki" }
//
// The API's query-param filters (?userGuids=, ?projectGuids=) are silently
// ignored, but the path sub-resource GET /users/{guid}/workhours *is* scoped to
// the user — so "my projects" = the distinct project→phase pairs I've logged
// hours to recently. That's also exactly what Severa lets me post hours to.
// ponytail: seed from usage, don't crawl the 300-project company tree.

struct SeveraPhase: Codable, Identifiable, Hashable {
    let guid: String
    let name: String
    var workTypeGuid: String?     // the work type I've used on this phase (from usage)
    var workTypeName: String?
    var id: String { guid }
}
struct SeveraProject: Codable, Identifiable, Hashable {
    let guid: String
    let name: String
    var phases: [SeveraPhase]
    var id: String { guid }
}

// eventDate is a calendar day in the timesheet's timezone (see hoursTZ), not the Mac's.
private let severaDateFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = hoursTZ; return f
}()

@MainActor
final class SeveraModel: ObservableObject {
    @Published private(set) var projects: [SeveraProject] = []
    @Published private(set) var configured = false
    @Published private(set) var status = ""
    @Published private(set) var lastError: String?     // why the last sync failed (HTTP code + body), for the UI
    @Published private(set) var roundUpMinutes = 30   // upload rounds each bucket up to this; 0 = off

    private var base = "", clientId = "", clientSecret = "", userGuid = ""
    private var token: String?
    private var tokenExpiry = Date.distantPast
    private var lastLoad = Date.distantPast
    private let cacheKey = "severa.projects.v1"

    init() { loadConfig(); loadCache() }

    private func loadConfig() {
        let j = loadConfigJSON("severa.json")
        guard !j.isEmpty else {
            configured = false; status = "No severa.json — add it to enable the project picker"; return
        }
        var u = (j["url"] as? String ?? "https://api.severa.visma.com/rest-api").trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        base = u
        clientId = j["clientId"] as? String ?? ""
        clientSecret = j["clientSecret"] as? String ?? ""
        userGuid = j["userGuid"] as? String ?? ""
        roundUpMinutes = (j["roundUpMinutes"] as? NSNumber)?.intValue ?? 30
        configured = !clientId.isEmpty && !clientSecret.isEmpty && !userGuid.isEmpty
        status = configured ? "" : "severa.json missing clientId / clientSecret / userGuid"
    }

    private func loadCache() {
        guard let d = UserDefaults.standard.data(forKey: cacheKey),
              let p = try? JSONDecoder().decode([SeveraProject].self, from: d) else { return }
        projects = p
    }
    private func saveCache(_ p: [SeveraProject]) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: cacheKey) }
    }

    /// Refresh in the background; the cached list stays on screen meanwhile.
    /// Throttled: the tab calls this on every appearance, and the picker's contents
    /// (which phases I've logged to lately) don't change by the minute.
    func refresh(force: Bool = false) {
        guard configured, force || Date().timeIntervalSince(lastLoad) > 600 else { return }
        lastLoad = Date()
        Task { await load() }
    }

    private func token(_ session: URLSession) async throws -> String {
        if let t = token, tokenExpiry > Date() { return t }
        var req = URLRequest(url: URL(string: "\(base)/v1.0/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_Id": clientId, "client_Secret": clientSecret,
            "scope": "projects:read hours:read hours:write",
        ])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.userAuthenticationRequired)
        }
        // Severa's field casing has drifted across versions — accept any of them.
        let t = (j["access_Token"] ?? j["accessToken"] ?? j["access_token"] ?? j["token"]) as? String
        guard let tok = t else { throw URLError(.userAuthenticationRequired) }
        token = tok
        tokenExpiry = Date().addingTimeInterval(55 * 60)   // Severa tokens live 1 h
        return tok
    }

    private func session(timeout: TimeInterval) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        return URLSession(configuration: cfg)
    }

    /// Send with a bearer token; on 401 drop the cached token and retry once (a revoked
    /// or re-scoped token used to fail every call for the rest of its 55-min cache).
    private func send(_ req: URLRequest, _ session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var r = req
        r.setValue("Bearer \(try await token(session))", forHTTPHeaderField: "Authorization")
        var (data, resp) = try await session.data(for: r)
        if (resp as? HTTPURLResponse)?.statusCode == 401 {
            token = nil
            r.setValue("Bearer \(try await token(session))", forHTTPHeaderField: "Authorization")
            (data, resp) = try await session.data(for: r)
        }
        return (data, resp as? HTTPURLResponse ?? HTTPURLResponse())
    }

    // "HTTP 403: {…first 120 bytes…}" — enough to tell bad credentials from a missing scope.
    private static func describe(_ resp: HTTPURLResponse, _ data: Data) -> String {
        let body = String(data: data.prefix(120), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "HTTP \(resp.statusCode)" + (body.isEmpty ? "" : ": \(body)")
    }

    private func load() async {
        let session = session(timeout: 12)
        do {
            let end = Date()
            let start = hoursCal.date(byAdding: .day, value: -180, to: end) ?? end
            var comps = URLComponents(string: "\(base)/v1.0/users/\(userGuid)/workhours")!
            comps.queryItems = [
                .init(name: "startDate", value: severaDateFmt.string(from: start)),
                .init(name: "endDate", value: severaDateFmt.string(from: end)),
                .init(name: "rowCount", value: "1000"),
            ]
            let (data, resp) = try await send(URLRequest(url: comps.url!), session)
            guard resp.statusCode == 200 else { status = "Severa: \(Self.describe(resp, data))"; return }
            let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
            projects = Self.build(from: rows)
            status = projects.isEmpty ? "No projects logged in the last 180 days" : ""
            saveCache(projects)
        } catch {
            status = "Severa unreachable — \(error.localizedDescription)"   // keep the cached list on screen
            lastLoad = .distantPast                                          // let the next appearance retry
        }
    }

    /// Sync one aggregated work-hour: PATCH the existing Severa row if we've posted
    /// this bucket before, else POST a new one. Never deletes — Kajo only touches rows
    /// it created, and only to bring them up to date. Returns the workhour guid ("" if
    /// Severa returned none), nil on failure — with `lastError` saying why.
    func sync(_ p: WorkHourPost) async -> String? {
        guard configured else { return nil }
        lastError = nil
        let session = session(timeout: 15)
        do {
            if let guid = p.existingGuid {
                // RFC-6902 JSON Patch — update just the fields that can change.
                var req = URLRequest(url: URL(string: "\(base)/v1.0/workhours/\(guid)")!)
                req.httpMethod = "PATCH"
                req.setValue("application/json-patch+json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    ["op": "replace", "path": "/quantity", "value": p.hours],
                    ["op": "replace", "path": "/description", "value": p.description],
                ])
                let (data, resp) = try await send(req, session)
                guard (200...204).contains(resp.statusCode) else { lastError = Self.describe(resp, data); return nil }
                return guid
            } else {
                var req = URLRequest(url: URL(string: "\(base)/v1.0/workhours")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: [
                    "eventDate": severaDateFmt.string(from: p.eventDate),
                    "quantity": p.hours,
                    "description": p.description,
                    "phase": ["guid": p.phaseGuid],
                    "user": ["guid": userGuid],
                    "workType": ["guid": p.workTypeGuid],
                ])
                let (data, resp) = try await send(req, session)
                guard (200...201).contains(resp.statusCode) else { lastError = Self.describe(resp, data); return nil }
                let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                // guid from the body, else the Location header; "" = created but unknown id
                // (recorded so it's never re-POSTed, but it can't be PATCHed later either).
                return (j?["guid"] as? String)
                    ?? (resp.value(forHTTPHeaderField: "Location") as NSString?)?.lastPathComponent
                    ?? ""
            }
        } catch { lastError = error.localizedDescription; return nil }
    }

    // Generic words that don't identify a customer/project — dropped before matching.
    private static let stopwords: Set<String> = [
        "the", "and", "of", "for", "consultancy", "development", "internal", "work",
        "package", "unit", "support", "updates", "fixes", "bug", "bugs", "service",
        "center", "project", "sivuston", "jatkokehitys",
    ]
    static func keywords(_ name: String) -> [String] {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { $0.count >= 3 && !stopwords.contains($0) && !$0.allSatisfy(\.isNumber) }
    }

    /// Best project·phase for a free-text task, by matching a distinctive word of a
    /// project name (e.g. "acme", "globex") against the text.
    /// nil if nothing matches. Used to auto-fill the project when a task is created.
    func match(_ task: String) -> (project: SeveraProject, phase: SeveraPhase)? {
        let t = task.lowercased()
        guard t.count >= 2, !projects.isEmpty else { return nil }
        var best: (SeveraProject, SeveraPhase, Int)?
        for p in projects {
            guard let hit = Self.keywords(p.name).filter({ t.contains($0) }).max(by: { $0.count < $1.count })
            else { continue }
            // Prefer a phase whose own distinctive word is in the text; else its only/first phase.
            let phase = p.phases.first { ph in Self.keywords(ph.name).contains { $0 != hit && t.contains($0) } }
                ?? p.phases.first
            guard let ph = phase else { continue }
            if best == nil || hit.count > best!.2 { best = (p, ph, hit.count) }
        }
        return best.map { ($0.0, $0.1) }
    }

    // Distinct project→phase pairs (each phase carries the work type I last used on
    // it), name-ordered A–Z.
    static func build(from rows: [[String: Any]]) -> [SeveraProject] {
        var name: [String: String] = [:]
        var phases: [String: [String: SeveraPhase]] = [:]   // projGuid -> phaseGuid -> phase
        for r in rows {
            guard let pj = r["project"] as? [String: Any], let pg = pj["guid"] as? String else { continue }
            name[pg] = pj["name"] as? String ?? "—"
            if let ph = r["phase"] as? [String: Any], let hg = ph["guid"] as? String {
                let wt = r["workType"] as? [String: Any]
                phases[pg, default: [:]][hg] = SeveraPhase(
                    guid: hg, name: ph["name"] as? String ?? "—",
                    workTypeGuid: wt?["guid"] as? String, workTypeName: wt?["name"] as? String)
            }
        }
        return name.map { pg, pn in
            SeveraProject(guid: pg, name: pn,
                          phases: (phases[pg] ?? [:]).values.sorted { $0.name < $1.name })
        }.sorted { $0.name < $1.name }
    }
}

#if DEBUG
// ponytail: one runnable check — the usage→project grouping is the only real logic.
// Runs from main.swift's top level (main actor) in -DDEBUG builds: `make check` / `make dev`.
@MainActor func _severaBuildSelfCheck() {
    let rows: [[String: Any]] = [
        ["project": ["guid": "P1", "name": "Project Beta"], "phase": ["guid": "H1", "name": "Phase One"]],
        ["project": ["guid": "P1", "name": "Project Beta"], "phase": ["guid": "H1", "name": "Phase One"]],
        ["project": ["guid": "P2", "name": "Project Alpha"], "phase": ["guid": "H2", "name": "Phase A"]],
        ["project": ["guid": "P2", "name": "Project Alpha"], "phase": ["guid": "H3", "name": "Phase B"]],
    ]
    let p = SeveraModel.build(from: rows)
    assert(p.count == 2, "two distinct projects")
    assert(p[0].name == "Project Alpha", "sorted A–Z")
    assert(p[0].phases.count == 2, "two phases for Alpha")
    assert(p[1].phases.count == 1, "one phase for Beta (dupe collapsed)")
    // keyword extraction drops generic words + numbers, keeps the distinctive token
    assert(SeveraModel.keywords("Acme Consultancy 2026") == ["acme"], "customer token survives")
    assert(SeveraModel.keywords("Globex - Development 1.10.2025-30.9.2026") == ["globex"], "dates/dev dropped")
}
#endif

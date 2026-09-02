import AppKit
import SwiftUI

// MARK: - Work-hour tracking: stopwatch + logged entries + monthly Severa export

struct TimeEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var task: String
    var start: Date
    var end: Date?                    // nil = currently running
    // Optional Severa association (absent in old entries — Codable stays compatible).
    var projectGuid: String?
    var projectName: String?
    var phaseGuid: String?
    var phaseName: String?
    var workTypeGuid: String?
    var workTypeName: String?
    var seconds: TimeInterval { max(0, (end ?? Date()).timeIntervalSince(start)) }
    // "Project · Phase" for display, or nil if unassigned.
    var severaLabel: String? {
        guard let ph = phaseName else { return projectName }
        if let pj = projectName, pj != ph { return "\(pj) · \(ph)" }
        return ph
    }
}

// One aggregated Severa work-hour to sync: a day × phase × workType bucket.
struct WorkHourPost: Identifiable {
    let id = UUID()
    let key: String             // stable bucket key (day|phase|workType)
    let eventDate: Date
    let phaseGuid: String
    let phaseName: String
    let workTypeGuid: String
    let hours: Double           // rounded UP to next 0.5 h
    let description: String
    let sourceIDs: [UUID]       // Kajo entries folded into this post
    let existingGuid: String?   // nil = POST new; set = PATCH this Severa workhour
}

// What we last pushed for a bucket — lets re-upload PATCH instead of duplicate.
struct UploadRecord: Codable { var guid: String; var hours: Double; var desc: String }

// Same-task sessions within one day, collapsed into a single row (expandable).
struct TaskGroup: Identifiable {
    let day: Date
    let task: String
    let items: [TimeEntry]           // sessions, newest first
    var id: String { "\(day.timeIntervalSinceReferenceDate)|\(task)" }
    var seconds: TimeInterval { items.reduce(0) { $0 + $1.seconds } }
}

private let hoursDayFmt: DateFormatter    = { let f = DateFormatter(); f.dateFormat = "d.M."; return f }()
private let hoursDayHdrFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d.M."; f.locale = Locale(identifier: "en_US"); return f }()
private let hoursMonthFmt: DateFormatter  = { let f = DateFormatter(); f.dateFormat = "LLLL yyyy"; f.locale = Locale(identifier: "en_US"); return f }()
private let hoursTimeFmt: DateFormatter   = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

// Round decimal hours UP to the next `minutes`-step (Severa bills in fixed steps).
// minutes <= 0 disables rounding (raw, to 0.01 h). Epsilon so an exact boundary
// (e.g. 1.5 h at 30-min steps) doesn't float up a step; any real work is ≥ one step.
func ceilToMinutes(_ hours: Double, _ minutes: Int) -> Double {
    guard minutes > 0 else { return (hours * 100).rounded() / 100 }
    let step = Double(minutes) / 60
    let v = max(step, ceil((hours - 1e-9) / step) * step)
    return (v * 10000).rounded() / 10000
}

private func decimalHours(_ s: TimeInterval) -> String {
    let h = (s / 3600 * 100).rounded() / 100
    var str = String(format: "%.2f", h)
    while str.hasSuffix("0") { str.removeLast() }
    if str.hasSuffix(".") { str.removeLast() }
    return str.isEmpty ? "0" : str
}
private func durText(_ s: TimeInterval, seconds: Bool = false) -> String {
    let t = Int(s), h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    if h > 0 { return seconds ? "\(h)h \(m)m \(sec)s" : "\(h)h \(m)m" }
    if m > 0 { return seconds ? "\(m)m \(sec)s" : "\(m)m" }
    return "\(sec)s"
}

final class HoursModel: ObservableObject {
    @Published var entries: [TimeEntry] = []
    @Published var draft = ""
    @Published var draftProject: SeveraProject?             // sticky Severa selection for the next start
    @Published var draftPhase: SeveraPhase?
    @Published private(set) var tick = Date()               // drives the live elapsed readout
    @Published var month = HoursModel.monthStart(Date())    // month shown in the log
    @Published private var uploads: [String: UploadRecord] = [:]   // bucketKey -> what's on Severa

    private let url = URL(fileURLWithPath: kajoConfigDir + "/hours.json")
    private let uploadsKey = "hours.uploads.v1"
    private var ticker: Timer?

    static func bucketKey(_ day: Date, _ phaseGuid: String, _ wtGuid: String) -> String {
        "\(Int(Calendar.current.startOfDay(for: day).timeIntervalSinceReferenceDate))|\(phaseGuid)|\(wtGuid)"
    }
    // Has this entry been pushed to Severa? (its bucket has an upload record)
    func isUploaded(_ e: TimeEntry) -> Bool {
        guard let p = e.phaseGuid, let w = e.workTypeGuid else { return false }
        return uploads[Self.bucketKey(e.start, p, w)] != nil
    }

    var running: TimeEntry? { entries.first { $0.end == nil } }

    init() {
        try? FileManager.default.createDirectory(atPath: kajoConfigDir, withIntermediateDirectories: true)
        load()
        if let d = UserDefaults.standard.data(forKey: uploadsKey),
           let m = try? JSONDecoder().decode([String: UploadRecord].self, from: d) { uploads = m }
        if running != nil { startTicker() }
    }

    static func monthStart(_ d: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: d)) ?? d
    }

    // MARK: start / stop / resume
    func start(task: String? = nil) {
        guard running == nil else { return }
        let name = (task ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        // Carry the sticky Severa selection onto the new entry (kept for the next start too).
        entries.insert(TimeEntry(task: name.isEmpty ? "Untitled" : name, start: Date(), end: nil,
                                 projectGuid: draftProject?.guid, projectName: draftProject?.name,
                                 phaseGuid: draftPhase?.guid, phaseName: draftPhase?.name,
                                 workTypeGuid: draftPhase?.workTypeGuid, workTypeName: draftPhase?.workTypeName), at: 0)
        draft = ""
        save(); startTicker()
    }
    func stop() {
        guard let i = entries.firstIndex(where: { $0.end == nil }) else { return }
        entries[i].end = Date()
        if entries[i].seconds < 1 { entries.remove(at: i) }   // discard accidental taps
        save(); stopTicker()
    }
    func resume(_ e: TimeEntry) {
        stop()
        if let pg = e.projectGuid { draftProject = SeveraProject(guid: pg, name: e.projectName ?? "—", phases: []) }
        if let hg = e.phaseGuid {
            draftPhase = SeveraPhase(guid: hg, name: e.phaseName ?? "—",
                                     workTypeGuid: e.workTypeGuid, workTypeName: e.workTypeName)
        }
        start(task: e.task)
    }
    func resume(task: String) { stop(); start(task: task) }   // group resume: keeps current sticky selection

    // MARK: edit / delete / add
    func update(_ e: TimeEntry) {
        guard let i = entries.firstIndex(where: { $0.id == e.id }) else { return }
        entries[i] = e; save()
    }
    // Assign a Severa project·phase to a whole nest (all sessions of a task/day).
    func setProject(ids: [UUID], project: SeveraProject?, phase: SeveraPhase?) {
        for i in entries.indices where ids.contains(entries[i].id) {
            entries[i].projectGuid = project?.guid;   entries[i].projectName = project?.name
            entries[i].phaseGuid = phase?.guid;       entries[i].phaseName = phase?.name
            entries[i].workTypeGuid = phase?.workTypeGuid; entries[i].workTypeName = phase?.workTypeName
        }
        save()
    }
    func delete(_ e: TimeEntry) {
        entries.removeAll { $0.id == e.id }
        if running == nil { stopTicker() }
        save()
    }
    @discardableResult func addManual() -> TimeEntry {
        // default: a 1-hour block ending now (or noon on the last day of the viewed month)
        let cal = Calendar.current
        let anchor: Date = cal.isDate(Date(), equalTo: month, toGranularity: .month)
            ? Date()
            : (cal.date(byAdding: .month, value: 1, to: month)?.addingTimeInterval(-43200) ?? month)
        let e = TimeEntry(task: "", start: anchor.addingTimeInterval(-3600), end: anchor)
        entries.append(e); save()
        return e
    }

    // MARK: month view
    func shiftMonth(_ d: Int) { month = Calendar.current.date(byAdding: .month, value: d, to: month) ?? month }
    private func inMonth(_ e: TimeEntry) -> Bool { Calendar.current.isDate(e.start, equalTo: month, toGranularity: .month) }
    func monthSeconds() -> TimeInterval { entries.filter(inMonth).reduce(0) { $0 + $1.seconds } }
    func daySeconds(_ day: Date) -> TimeInterval {
        entries.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.seconds }
    }
    // completed entries in the viewed month, grouped by day (newest day first), then by task
    // within each day (same task done several times collapses to one group). Running one lives in the card.
    func days() -> [(day: Date, groups: [TaskGroup])] {
        let logged = entries.filter { $0.end != nil && inMonth($0) }
        let byDay = Dictionary(grouping: logged) { Calendar.current.startOfDay(for: $0.start) }
        return byDay.keys.sorted(by: >).map { day in
            var order: [String] = []                 // preserve most-recent-session-first order
            var map: [String: [TimeEntry]] = [:]
            for e in byDay[day]!.sorted(by: { $0.start > $1.start }) {
                if map[e.task] == nil { order.append(e.task) }
                map[e.task, default: []].append(e)
            }
            return (day: day, groups: order.map { TaskGroup(day: day, task: $0, items: map[$0]!) })
        }
    }

    // MARK: export (one line per task per day, chronological — for Severa)
    func exportMonth() -> String {
        let rows = entries.filter { $0.end != nil && inMonth($0) }
        struct Key: Hashable { let day: Date; let task: String }
        var sum: [Key: TimeInterval] = [:], first: [Key: Date] = [:]
        for e in rows {
            let k = Key(day: Calendar.current.startOfDay(for: e.start), task: e.task)
            sum[k, default: 0] += e.seconds
            first[k] = min(first[k] ?? e.start, e.start)
        }
        var out = hoursMonthFmt.string(from: month) + "\n\n"
        for k in sum.keys.sorted(by: { (first[$0] ?? .distantPast) < (first[$1] ?? .distantPast) }) {
            out += "\(hoursDayFmt.string(from: k.day))  \(k.task.isEmpty ? "—" : k.task) — \(decimalHours(sum[k]!)) h\n"
        }
        out += "\nTotal: \(decimalHours(sum.values.reduce(0, +))) h\n"
        return out
    }
    func copyMonth() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportMonth(), forType: .string)
    }

    // MARK: Severa upload — aggregate the viewed month into day×phase×workType posts
    // (only completed, phase+workType-assigned entries not already uploaded).
    // Buckets needing a sync: a bucket that's new (POST) or whose hours/description
    // changed since last upload (PATCH the existing Severa row). Already-synced,
    // unchanged buckets are omitted. Pass a `day` to scope to that day.
    // The running entry (end == nil) is never included.
    func pendingUploads(day: Date? = nil, roundMinutes: Int = 30) -> [WorkHourPost] {
        let rows = entries.filter { e in
            guard e.end != nil, e.phaseGuid != nil, e.workTypeGuid != nil else { return false }
            return day == nil ? inMonth(e) : Calendar.current.isDate(e.start, inSameDayAs: day!)
        }
        struct Key: Hashable { let day: Date; let phase: String; let wt: String }
        var order: [Key] = []
        var bucket: [Key: [TimeEntry]] = [:]
        for e in rows {
            let k = Key(day: Calendar.current.startOfDay(for: e.start), phase: e.phaseGuid!, wt: e.workTypeGuid!)
            if bucket[k] == nil { order.append(k) }
            bucket[k, default: []].append(e)
        }
        return order.compactMap { k -> WorkHourPost? in
            let items = bucket[k]!
            let hours = ceilToMinutes(items.reduce(0) { $0 + $1.seconds } / 3600, roundMinutes)
            var seen = Set<String>(); var descs: [String] = []
            for e in items.sorted(by: { $0.start < $1.start }) {
                let t = e.task.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty && seen.insert(t).inserted { descs.append(t) }
            }
            let desc = descs.joined(separator: ", ")
            let bk = Self.bucketKey(k.day, k.phase, k.wt)
            if let rec = uploads[bk], rec.hours == hours, rec.desc == desc { return nil }   // already synced, unchanged
            return WorkHourPost(key: bk, eventDate: k.day, phaseGuid: k.phase,
                                phaseName: items.first?.phaseName ?? "—", workTypeGuid: k.wt,
                                hours: hours, description: desc,
                                sourceIDs: items.map { $0.id }, existingGuid: uploads[bk]?.guid)
        }
    }
    // Completed entries with no phase assigned (can't upload).
    func unassignedCount(day: Date? = nil) -> Int {
        entries.filter { e in
            guard e.end != nil, e.phaseGuid == nil else { return false }
            return day == nil ? inMonth(e) : Calendar.current.isDate(e.start, inSameDayAs: day!)
        }.count
    }
    // Record a successful POST/PATCH so re-uploads update instead of duplicating.
    func recordUpload(_ p: WorkHourPost, guid: String) {
        uploads[p.key] = UploadRecord(guid: guid, hours: p.hours, desc: p.description)
        if let d = try? JSONEncoder().encode(uploads) { UserDefaults.standard.set(d, forKey: uploadsKey) }
    }

    // MARK: ticker + persistence
    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick = Date() }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func load() {
        guard let d = try? Data(contentsOf: url),
              let a = try? JSONDecoder().decode([TimeEntry].self, from: d) else { return }
        entries = a.sorted { $0.start > $1.start }
    }
    private func save() {
        entries.sort { $0.start > $1.start }
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: url) }
    }
}

struct HoursTab: View {
    @ObservedObject var model: HoursModel
    @StateObject private var severa = SeveraModel()
    @State private var editingID: UUID?
    @State private var copiedTag: String?
    @State private var expanded: Set<String> = []          // group ids showing their sessions
    @State private var draftEntry = TimeEntry(task: "", start: Date(), end: Date())
    @State private var confirmDay: Date?          // day pending upload confirmation
    @State private var uploading = false
    @State private var uploadMsg: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tracker
            monthBar
            if let m = uploadMsg {
                Text(m).font(.system(size: 11))
                    .foregroundColor(m.hasPrefix("✓") ? Gruv.green : Gruv.red)
            }
            log
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { severa.refresh() }
    }

    // running / start card
    private var tracker: some View {
        Group {
            if let r = model.running {
                if editingID == r.id {
                    editor(r)                       // tap the card to edit the running task's text + start time
                } else {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.task.isEmpty ? "—" : r.task).foregroundColor(Gruv.fg1).lineLimit(1)
                            if let s = r.severaLabel {
                                Text(s).font(.system(size: 10)).foregroundColor(Gruv.blue).lineLimit(1)
                            }
                            Text(durText(model.tick.timeIntervalSince(r.start), seconds: true))
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .foregroundColor(Gruv.green)
                        }
                        Spacer()
                        Button { model.stop() } label: {
                            Image(systemName: "stop.circle.fill").font(.system(size: 30)).foregroundColor(Gruv.red)
                        }.buttonStyle(.plain).help("Stop")
                    }
                    .padding(12).background(Gruv.bg1).cornerRadius(10)
                    .contentShape(Rectangle())
                    .onTapGesture { draftEntry = r; editingID = r.id }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        TextField("What are you working on?", text: $model.draft)
                            .textFieldStyle(.plain).foregroundColor(Gruv.fg1)
                            .onSubmit { model.start() }
                        Button { model.start() } label: {
                            Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundColor(Gruv.green)
                        }.buttonStyle(.plain).help("Start")
                    }
                    if severa.configured {
                        severaMenu(current: model.draftPhase?.name ?? model.draftProject?.name) { p, ph in
                            model.draftProject = p; model.draftPhase = ph
                        }
                    }
                }
                .padding(12).background(Gruv.bg1).cornerRadius(10)
            }
        }
    }

    private var monthBar: some View {
        HStack(spacing: 6) {
            Button { model.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundColor(Gruv.fg4)
            Text(hoursMonthFmt.string(from: model.month)).font(.system(size: 12, weight: .semibold)).foregroundColor(Gruv.fg2)
            Button { model.shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundColor(Gruv.fg4)
            Spacer()
            Text(durText(model.monthSeconds())).font(.system(size: 12, weight: .semibold)).foregroundColor(Gruv.yellow)
            Button { PanelController.shared?.closePanel(); HoursWindowController.shared.show(model: model) } label: { Image(systemName: "macwindow") }
                .buttonStyle(.plain).foregroundColor(Gruv.fg2).help("Open in a window (park it next to your browser)")
            Button { model.copyMonth() } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundColor(Gruv.fg2).help("Copy month for Severa")
            Button { let e = model.addManual(); draftEntry = e; editingID = e.id } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).foregroundColor(Gruv.green).help("Add entry manually")
        }
        .confirmationDialog(uploadPrompt, isPresented: Binding(get: { confirmDay != nil }, set: { if !$0 { confirmDay = nil } }), titleVisibility: .visible) {
            Button("Upload to Severa") { if let d = confirmDay { confirmDay = nil; Task { await runUpload(day: d) } } }
            Button("Cancel", role: .cancel) { confirmDay = nil }
        }
    }

    private var uploadPrompt: String {
        guard let d = confirmDay else { return "" }
        let posts = model.pendingUploads(day: d, roundMinutes: severa.roundUpMinutes)
        let news = posts.filter { $0.existingGuid == nil }.count
        let upd = posts.count - news
        let hrs = posts.reduce(0) { $0 + $1.hours }
        let un = model.unassignedCount(day: d)
        var parts: [String] = []
        if news > 0 { parts.append("\(news) new") }
        if upd > 0 { parts.append("\(upd) updated") }
        let rounding = severa.roundUpMinutes > 0 ? ", rounded up to \(severa.roundUpMinutes) min" : ""
        var s = "Sync \(hoursDayHdrFmt.string(from: d)) to Severa — \(parts.joined(separator: ", ")) (\(decimalHours(hrs * 3600)) h\(rounding))?"
        if un > 0 { s += "\n\(un) unassigned entr\(un == 1 ? "y is" : "ies are") skipped (pick a project first)." }
        return s
    }

    private func runUpload(day: Date) async {
        uploading = true; uploadMsg = nil
        let posts = model.pendingUploads(day: day, roundMinutes: severa.roundUpMinutes)
        var ok = 0, fail = 0
        for p in posts {
            if let guid = await severa.sync(p) { model.recordUpload(p, guid: guid); ok += 1 }
            else { fail += 1 }
        }
        uploading = false
        uploadMsg = fail == 0 ? "✓ Synced \(ok) to Severa (\(hoursDayFmt.string(from: day)))" : "Synced \(ok), \(fail) failed"
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if uploadMsg != nil { uploadMsg = nil } }
    }

    private var log: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let days = model.days()
                if days.isEmpty {
                    Text("No entries this month").foregroundColor(Gruv.fg4).font(.system(size: 12)).padding(.top, 24)
                }
                ForEach(days, id: \.day) { grp in
                    HStack(spacing: 6) {
                        Text(hoursDayHdrFmt.string(from: grp.day)).font(.system(size: 11, weight: .semibold)).foregroundColor(Gruv.fg4)
                        Spacer()
                        Text(durText(model.daySeconds(grp.day))).font(.system(size: 11)).foregroundColor(Gruv.fg4)
                        if severa.configured && !model.pendingUploads(day: grp.day, roundMinutes: severa.roundUpMinutes).isEmpty {
                            Button { confirmDay = grp.day } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 12)) }
                                .buttonStyle(.plain).foregroundColor(Gruv.blue).disabled(uploading)
                                .help("Upload this day to Severa")
                        }
                    }
                    .padding(.top, 4)
                    ForEach(grp.groups) { g in groupView(g) }
                }
            }
            .padding(.bottom, 8)
        }
        .frame(maxHeight: .infinity)
    }

    // copy `text` to the pasteboard with a 1 s ✓ flash, disambiguated by `tag` (entry id or group id)
    private func copyButton(_ text: String, tag: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copiedTag = tag
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if copiedTag == tag { copiedTag = nil } }
        } label: {
            Image(systemName: copiedTag == tag ? "checkmark" : "doc.on.doc")
                .foregroundColor(copiedTag == tag ? Gruv.green : Gruv.fg4)
        }.buttonStyle(.plain).help("Copy task text")
    }

    // Severa project → phase picker. Nested Menu: projects, each expanding to its
    // phases; picking a phase sets both. `current` is the label to show.
    private func severaMenu(current: String?, tint: Color = Gruv.blue, onPick: @escaping (SeveraProject?, SeveraPhase?) -> Void) -> some View {
        Menu {
            if !severa.configured {
                Text(severa.status)
            } else if severa.projects.isEmpty {
                Text(severa.status.isEmpty ? "Loading…" : severa.status)
                Button("Refresh") { severa.refresh() }
            } else {
                Button("None") { onPick(nil, nil) }
                ForEach(severa.projects) { p in
                    Menu(p.name) {
                        if p.phases.isEmpty {
                            Button(p.name) { onPick(p, nil) }
                        } else {
                            ForEach(p.phases) { ph in Button(ph.name) { onPick(p, ph) } }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "briefcase").font(.system(size: 11))
                Text(current ?? "Project").font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundColor(current == nil ? Gruv.fg4 : tint)
            .frame(maxWidth: .infinity, alignment: .leading)   // truncate, don't push the window wide
        }
        .menuStyle(.borderlessButton)
    }

    // A day's task-group: a single session renders as a plain row; multiple sessions
    // collapse to a header showing the total, expandable to the individual sessions.
    @ViewBuilder private func groupView(_ g: TaskGroup) -> some View {
        if g.items.count == 1 {
            let e = g.items[0]
            if editingID == e.id { editor(e) } else { row(e) }
        } else {
            VStack(spacing: 6) {
                groupHeader(g)
                if expanded.contains(g.id) {
                    ForEach(g.items) { e in
                        if editingID == e.id { editor(e, showProject: false) } else { sessionRow(e) }
                    }
                }
            }
        }
    }

    private func groupHeader(_ g: TaskGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: expanded.contains(g.id) ? "chevron.down" : "chevron.right")
                .font(.system(size: 10)).foregroundColor(Gruv.fg4).frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(g.task.isEmpty ? "—" : g.task).foregroundColor(Gruv.fg1).lineLimit(1)
                if severa.configured {
                    let up = g.items.first.map { model.isUploaded($0) } ?? false
                    HStack(spacing: 3) {
                        if up { Image(systemName: "checkmark.icloud.fill").font(.system(size: 9)).foregroundColor(Gruv.green) }
                        severaMenu(current: g.items.first?.phaseName ?? g.items.first?.projectName,
                                   tint: up ? Gruv.green : Gruv.blue) { p, ph in
                            model.setProject(ids: g.items.map { $0.id }, project: p, phase: ph)
                        }
                    }
                } else {
                    Text("\(g.items.count) sessions").font(.system(size: 10)).foregroundColor(Gruv.fg4)
                }
            }
            Spacer()
            Text(durText(g.seconds)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(Gruv.fg2)
            copyButton(g.task, tag: g.id)
            Button { model.resume(task: g.task) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundColor(Gruv.blue).help("Resume this task")
        }
        .padding(10).background(Gruv.bg1).cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) } }
    }

    // one session inside an expanded group — compact, tap to edit
    private func sessionRow(_ e: TimeEntry) -> some View {
        HStack(spacing: 8) {
            Text("\(hoursTimeFmt.string(from: e.start))–\(e.end.map { hoursTimeFmt.string(from: $0) } ?? "…")")
                .font(.system(size: 11, design: .monospaced)).foregroundColor(Gruv.fg4)
            Spacer()
            Text(durText(e.seconds)).font(.system(size: 11, design: .monospaced)).foregroundColor(Gruv.fg4)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Gruv.bg0).cornerRadius(6)
        .padding(.leading, 18)
        .contentShape(Rectangle())
        .onTapGesture { draftEntry = e; editingID = e.id }
    }

    private func row(_ e: TimeEntry) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.task.isEmpty ? "—" : e.task).foregroundColor(Gruv.fg1).lineLimit(1)
                if let s = e.severaLabel {
                    let up = model.isUploaded(e)
                    HStack(spacing: 3) {
                        if up { Image(systemName: "checkmark.icloud.fill").font(.system(size: 9)).foregroundColor(Gruv.green) }
                        Text(s).font(.system(size: 10)).foregroundColor(up ? Gruv.green : Gruv.blue).lineLimit(1)
                    }
                }
                Text("\(hoursTimeFmt.string(from: e.start))–\(e.end.map { hoursTimeFmt.string(from: $0) } ?? "…")")
                    .font(.system(size: 10)).foregroundColor(Gruv.fg4)
            }
            Spacer()
            Text(durText(e.seconds)).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(Gruv.fg2)
            copyButton(e.task, tag: e.id.uuidString)
            Button { model.resume(e) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundColor(Gruv.blue).help("Resume this task")
        }
        .padding(10).background(Gruv.bg1).cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { draftEntry = e; editingID = e.id }
    }

    private enum EditField: Hashable { case task, start, end }
    @FocusState private var focus: EditField?

    private func editor(_ e: TimeEntry, showProject: Bool = true) -> some View {
        func commit() { model.update(draftEntry); editingID = nil; focus = nil }
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Task", text: $draftEntry.task)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .task)
                .onSubmit(commit)
            DatePicker("Start", selection: $draftEntry.start).datePickerStyle(.field).font(.system(size: 12))
                .focused($focus, equals: .start)
            if draftEntry.end != nil {
                DatePicker("End", selection: Binding(get: { draftEntry.end ?? Date() }, set: { draftEntry.end = $0 }))
                    .datePickerStyle(.field).font(.system(size: 12))
                    .focused($focus, equals: .end)
            } else {
                Text("running…").font(.system(size: 11)).foregroundColor(Gruv.green)
            }
            if severa.configured && showProject {
                severaMenu(current: draftEntry.phaseName ?? draftEntry.projectName) { p, ph in
                    draftEntry.projectGuid = p?.guid; draftEntry.projectName = p?.name
                    draftEntry.phaseGuid = ph?.guid; draftEntry.phaseName = ph?.name
                    draftEntry.workTypeGuid = ph?.workTypeGuid; draftEntry.workTypeName = ph?.workTypeName
                }
            }
            HStack {
                Button { model.delete(e); editingID = nil } label: { Image(systemName: "trash").foregroundColor(Gruv.red) }
                    .buttonStyle(.plain).help("Delete")
                Spacer()
                Button("Cancel") { editingID = nil; focus = nil }.buttonStyle(.plain).foregroundColor(Gruv.fg4)
                Button("Save", action: commit).buttonStyle(.plain).foregroundColor(Gruv.green)
                    .keyboardShortcut(.defaultAction)     // Enter saves from any field, incl. the date pickers
            }
        }
        .padding(10).background(Gruv.bg1)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Gruv.green.opacity(0.5), lineWidth: 1))
        .cornerRadius(8)
        // Don't intercept Tab — let AppKit's key-view loop walk task → the date pickers'
        // day/month/year/hour/min sub-fields → buttons natively. Enter still saves (default action).
        .onAppear { focus = .task }
    }
}

// MARK: - Detached window — park the month's log next to the browser while filling Severa

struct HoursWindow: View {
    @ObservedObject var model: HoursModel
    @State private var copiedKey: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button { model.shiftMonth(-1) } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain).foregroundColor(Gruv.fg4)
                Text(hoursMonthFmt.string(from: model.month)).font(.system(size: 15, weight: .bold)).foregroundColor(Gruv.fg0)
                Button { model.shiftMonth(1) } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain).foregroundColor(Gruv.fg4)
                Spacer()
                Text("Total \(durText(model.monthSeconds()))").font(.system(size: 13, weight: .semibold)).foregroundColor(Gruv.yellow)
                Button { model.copyMonth() } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundColor(Gruv.fg2).help("Copy month for Severa")
            }
            Divider().overlay(Gruv.bg3)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    let days = model.days()
                    if days.isEmpty {
                        Text("No entries this month").foregroundColor(Gruv.fg4).padding(.top, 30)
                    }
                    ForEach(days, id: \.day) { grp in
                        HStack {
                            Text(hoursDayHdrFmt.string(from: grp.day)).font(.system(size: 12, weight: .semibold)).foregroundColor(Gruv.fg4)
                            Spacer()
                            Text(durText(model.daySeconds(grp.day))).font(.system(size: 12)).foregroundColor(Gruv.fg4)
                        }.padding(.top, 8)
                        ForEach(grp.groups) { g in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(g.task, forType: .string)
                                    copiedKey = g.id
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if copiedKey == g.id { copiedKey = nil } }
                                } label: {
                                    Image(systemName: copiedKey == g.id ? "checkmark" : "doc.on.doc")
                                        .foregroundColor(copiedKey == g.id ? Gruv.green : Gruv.fg4)
                                        .font(.system(size: 11))
                                }.buttonStyle(.plain).help("Copy task text")
                                Text(hoursDayFmt.string(from: g.day)).font(.system(size: 12, design: .monospaced)).foregroundColor(Gruv.fg4).frame(width: 42, alignment: .leading)
                                Text(g.task.isEmpty ? "—" : g.task).foregroundColor(Gruv.fg1).textSelection(.enabled)
                                Spacer()
                                Text(decimalHours(g.seconds) + " h").font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(Gruv.fg2)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .padding(18)
        .frame(minWidth: 420, minHeight: 420)
    }
}

final class HoursWindowController {
    static let shared = HoursWindowController()
    private var window: NSWindow?

    func show(model: HoursModel) {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Hours"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.level = .floating                          // stay above the browser while filling Severa
        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.appearance = NSAppearance(named: .darkAqua)
        w.contentView = visual
        let hosting = NSHostingView(rootView: HoursWindow(model: model))
        hosting.frame = visual.bounds
        hosting.autoresizingMask = [.width, .height]
        visual.addSubview(hosting)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

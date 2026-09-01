import AppKit
import SwiftUI

// MARK: - Work-hour tracking: stopwatch + logged entries + monthly Severa export

struct TimeEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var task: String
    var start: Date
    var end: Date?                    // nil = currently running
    var seconds: TimeInterval { max(0, (end ?? Date()).timeIntervalSince(start)) }
}

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
    @Published private(set) var tick = Date()               // drives the live elapsed readout
    @Published var month = HoursModel.monthStart(Date())    // month shown in the log

    private let url = URL(fileURLWithPath: kajoConfigDir + "/hours.json")
    private var ticker: Timer?

    var running: TimeEntry? { entries.first { $0.end == nil } }

    init() {
        try? FileManager.default.createDirectory(atPath: kajoConfigDir, withIntermediateDirectories: true)
        load()
        if running != nil { startTicker() }
    }

    static func monthStart(_ d: Date) -> Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: d)) ?? d
    }

    // MARK: start / stop / resume
    func start(task: String? = nil) {
        guard running == nil else { return }
        let name = (task ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        entries.insert(TimeEntry(task: name.isEmpty ? "Untitled" : name, start: Date(), end: nil), at: 0)
        draft = ""
        save(); startTicker()
    }
    func stop() {
        guard let i = entries.firstIndex(where: { $0.end == nil }) else { return }
        entries[i].end = Date()
        if entries[i].seconds < 1 { entries.remove(at: i) }   // discard accidental taps
        save(); stopTicker()
    }
    func resume(_ e: TimeEntry) { resume(task: e.task) }
    func resume(task: String) { stop(); start(task: task) }

    // MARK: edit / delete / add
    func update(_ e: TimeEntry) {
        guard let i = entries.firstIndex(where: { $0.id == e.id }) else { return }
        entries[i] = e; save()
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
    @State private var editingID: UUID?
    @State private var copiedTag: String?
    @State private var expanded: Set<String> = []          // group ids showing their sessions
    @State private var draftEntry = TimeEntry(task: "", start: Date(), end: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tracker
            monthBar
            log
        }
        .frame(maxHeight: .infinity, alignment: .top)
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
                HStack(spacing: 10) {
                    TextField("What are you working on?", text: $model.draft)
                        .textFieldStyle(.plain).foregroundColor(Gruv.fg1)
                        .onSubmit { model.start() }
                    Button { model.start() } label: {
                        Image(systemName: "play.circle.fill").font(.system(size: 30)).foregroundColor(Gruv.green)
                    }.buttonStyle(.plain).help("Start")
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
    }

    private var log: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let days = model.days()
                if days.isEmpty {
                    Text("No entries this month").foregroundColor(Gruv.fg4).font(.system(size: 12)).padding(.top, 24)
                }
                ForEach(days, id: \.day) { grp in
                    HStack {
                        Text(hoursDayHdrFmt.string(from: grp.day)).font(.system(size: 11, weight: .semibold)).foregroundColor(Gruv.fg4)
                        Spacer()
                        Text(durText(model.daySeconds(grp.day))).font(.system(size: 11)).foregroundColor(Gruv.fg4)
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
                        if editingID == e.id { editor(e) } else { sessionRow(e) }
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
                Text("\(g.items.count) sessions").font(.system(size: 10)).foregroundColor(Gruv.fg4)
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

    private func editor(_ e: TimeEntry) -> some View {
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

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

// Per-install config dir: "kajo" for the real app, "kajo-dev" for the dev build,
// so the two never share state. (ponytail: one derived constant, no flag.)
let kajoConfigDir = NSHomeDirectory() + "/.config/"
    + ((Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false) ? "kajo-dev" : "kajo")

// MARK: - Gruvbox palette

enum Gruv {
    static let bg0    = Color(hex: 0x282828)
    static let bg1    = Color(hex: 0x3c3836)
    static let bg3    = Color(hex: 0x665c54)
    static let fg0    = Color(hex: 0xfbf1c7)
    static let fg1    = Color(hex: 0xebdbb2)
    static let fg2    = Color(hex: 0xd5c4a1)
    static let fg4    = Color(hex: 0xa89984)
    static let gray   = Color(hex: 0x928374)
    static let blue   = Color(hex: 0x83a598)
    static let aqua   = Color(hex: 0x8ec07c)
    static let green  = Color(hex: 0xb8bb26)
    static let yellow = Color(hex: 0xfabd2f)
    static let red    = Color(hex: 0xfb4934)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue:  Double(hex & 0xff) / 255,
                  opacity: 1)
    }
}

// MARK: - Tabs

enum Tab: String, CaseIterable, Identifiable {
    case calendar, timer, music, sound, power, network, unifi, vpn, home, pi, ai, system, memes, clipboard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .timer:    return "Timer"
        case .music:    return "Now Playing"
        case .sound:    return "Sound"
        case .power:    return "Power"
        case .network:  return "Network"
        case .unifi:    return "UniFi"
        case .vpn:      return "VPN"
        case .home:     return "Smart Home"
        case .pi:       return "Pi"
        case .ai:       return "AI"
        case .system:   return "System"
        case .memes:    return "Memes"
        case .clipboard: return "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .timer:    return "timer"
        case .music:    return "music.note"
        case .sound:    return "speaker.wave.2.fill"
        case .power:    return "bolt.fill"
        case .network:  return "wifi"
        case .unifi:    return "shield.lefthalf.filled"
        case .vpn:      return "lock.fill"
        case .home:     return "house.fill"
        case .pi:       return "server.rack"
        case .ai:       return "sparkles"
        case .system:   return "slider.horizontal.3"
        case .memes:    return "photo.stack"
        case .clipboard: return "doc.on.clipboard"
        }
    }
}

// config.json (optional): { "enabledModules": ["calendar",…], "menuBarIcon": true }
// "enabledModules" uses the same names as kajo://tab/<name>.
private let appConfig: [String: Any] = {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: kajoConfigDir + "/config.json")),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return j
}()
let enabledModules: Set<Tab> = {
    guard let names = appConfig["enabledModules"] as? [String] else { return Set(Tab.allCases) }
    let tabs = names.compactMap { Tab(rawValue: $0.lowercased()) }
    return tabs.isEmpty ? Set(Tab.allCases) : Set(tabs)
}()
// Menu-bar launch trigger — on by default so a fresh install is usable without
// sketchybar; set "menuBarIcon": false to hide it (e.g. if you summon elsewhere).
let menuBarEnabled = (appConfig["menuBarIcon"] as? Bool) ?? true

// MARK: - Launch another app + dismiss the panel

extension Notification.Name {
    static let kajoDismiss = Notification.Name("fi.mangusti.kajo.dismiss")
}

enum AppLauncher {
    static func open(_ bundleID: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        NotificationCenter.default.post(name: .kajoDismiss, object: nil)
    }

    static func openURL(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
        NotificationCenter.default.post(name: .kajoDismiss, object: nil)
    }

    static func openApp(named name: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", name]
        try? p.run()
        NotificationCenter.default.post(name: .kajoDismiss, object: nil)
    }
}

// MARK: - Shared state

final class PanelState: ObservableObject {
    @Published var tab: Tab = Tab.allCases.first { enabledModules.contains($0) } ?? .calendar
}

// MARK: - SwiftUI content

struct PanelView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var weather: WeatherModel
    @ObservedObject var events: EventsModel
    @ObservedObject var timer: TimerModel
    @ObservedObject var nowPlaying: NowPlayingModel
    @ObservedObject var sound: SoundModel
    @ObservedObject var bluetooth: BluetoothModel
    @ObservedObject var power: PowerModel
    @ObservedObject var network: NetworkModel
    @ObservedObject var unifi: UniFiModel
    @ObservedObject var vpn: VPNModel
    @ObservedObject var ha: HAModel
    @ObservedObject var pi: PiModel
    @ObservedObject var ai: AIModel
    @ObservedObject var system: SystemModel
    @ObservedObject var memes: MemeLibrary
    @ObservedObject var clipboard: ClipboardModel

    var body: some View {
        HStack(spacing: 0) {
            rail
            Rectangle().fill(Gruv.bg3.opacity(0.4)).frame(width: 1)
            content
        }
        .frame(width: 430, height: 600)
        .background(Gruv.bg0.opacity(0.72))
    }

    private var rail: some View {
        VStack(spacing: 1) {                       // tightened from 3 to fit 14 tabs
            ForEach(Tab.allCases.filter { enabledModules.contains($0) }) { t in
                RailIcon(tab: t, isActive: state.tab == t) { state.tab = t }
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .frame(width: 60)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(state.tab.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Gruv.fg1)
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Group {
                switch state.tab {
                case .calendar: CalendarTab(weather: weather, events: events)
                case .timer:    TimerView(model: timer)
                case .music:    MusicTab(model: nowPlaying)
                case .sound:    SoundTab(model: sound, bt: bluetooth)
                case .power:    PowerTab(model: power)
                case .network:  NetworkTab(model: network)
                case .unifi:    UniFiTab(model: unifi)
                case .vpn:      VPNTab(model: vpn)
                case .home:     HATab(model: ha)
                case .pi:       PiTab(model: pi)
                case .ai:       AITab(model: ai)
                case .system:   SystemTab(model: system)
                case .memes:    MemesTab(model: memes)
                case .clipboard: ClipboardTab(model: clipboard)
                }
            }
            .padding(.horizontal, 18)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rail icon with hover state

struct RailIcon: View {
    let tab: Tab
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tab.symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(fill)
                )
                .foregroundStyle(isActive ? Gruv.aqua : Gruv.fg4)
        }
        .buttonStyle(.plain)
        .help(tab.title)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: isActive)
    }

    private var fill: Color {
        if isActive { return Gruv.aqua.opacity(0.20) }
        if hovering { return Gruv.fg4.opacity(0.14) }
        return .clear
    }
}

// MARK: - Tab bodies

// MARK: - World cities (shared by the clocks + weather)

struct WorldCity: Identifiable {
    let name: String
    let tzID: String
    let lat: Double
    let lon: Double
    var id: String { name }
    var tz: TimeZone { TimeZone(identifier: tzID)! }
}

// calendar.json (optional): { "homeTimezone": "...", "cities": [{name,tz,lat,lon}…] }
// Missing/partial → these defaults. (ponytail: parse-with-defaults, no Codable ceremony.)
private let calendarCfg: [String: Any] = {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: kajoConfigDir + "/calendar.json")),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return j
}()

let homeTZ = (calendarCfg["homeTimezone"] as? String).flatMap(TimeZone.init(identifier:))
    ?? TimeZone(identifier: "Europe/Helsinki") ?? .current

let worldCities: [WorldCity] = {
    let defaults = [
        WorldCity(name: "Helsinki",     tzID: "Europe/Helsinki",   lat: 60.1699, lon: 24.9384),
        WorldCity(name: "Kuala Lumpur", tzID: "Asia/Kuala_Lumpur", lat:  3.1390, lon: 101.6869),
        WorldCity(name: "Málaga",       tzID: "Europe/Madrid",     lat: 36.7213, lon: -4.4214),
    ]
    guard let arr = calendarCfg["cities"] as? [[String: Any]] else { return defaults }
    let parsed = arr.compactMap { d -> WorldCity? in
        guard let n = d["name"] as? String, let tz = d["tz"] as? String,
              let la = d["lat"] as? Double, let lo = d["lon"] as? Double else { return nil }
        return WorldCity(name: n, tzID: tz, lat: la, lon: lo)
    }
    return parsed.isEmpty ? defaults : parsed
}()

// MARK: - Weather (Open-Meteo, no API key — one request for all clock cities)

struct WeatherNow: Equatable {
    var tempC = 0.0
    var hiC = 0.0
    var loC = 0.0
    var code = 0
    var loaded = false
}

final class WeatherModel: ObservableObject {
    @Published var byCity: [String: WeatherNow] = [:]
    private var lastFetch = Date.distantPast

    func refresh() {
        // Weather changes slowly — refetch at most every 10 min (always on first load).
        guard byCity.isEmpty || Date().timeIntervalSince(lastFetch) > 600 else { return }
        let lats = worldCities.map { String($0.lat) }.joined(separator: ",")
        let lons = worldCities.map { String($0.lon) }.joined(separator: ",")
        let s = "https://api.open-meteo.com/v1/forecast?latitude=\(lats)&longitude=\(lons)"
            + "&current=temperature_2m,weather_code"
            + "&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1"
        guard let url = URL(string: s) else { return }
        lastFetch = Date()
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data else { return }
            // Multi-location → array; single → object. Handle both.
            var items: [[String: Any]] = []
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                items = arr
            } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                items = [obj]
            }
            var result: [String: WeatherNow] = [:]
            for (i, item) in items.enumerated() where i < worldCities.count {
                var w = WeatherNow()
                if let cur = item["current"] as? [String: Any] {
                    w.tempC = cur["temperature_2m"] as? Double ?? 0
                    w.code = cur["weather_code"] as? Int ?? 0
                }
                if let daily = item["daily"] as? [String: Any] {
                    w.hiC = (daily["temperature_2m_max"] as? [Double])?.first ?? 0
                    w.loC = (daily["temperature_2m_min"] as? [Double])?.first ?? 0
                }
                w.loaded = true
                result[worldCities[i].name] = w
            }
            DispatchQueue.main.async { self?.byCity = result }
        }.resume()
    }
}

enum WeatherIcon {
    // WMO weather code → SF Symbol.
    static func symbol(_ c: Int) -> String {
        switch c {
        case 0:            return "sun.max.fill"
        case 1, 2:         return "cloud.sun.fill"
        case 3:            return "cloud.fill"
        case 45, 48:       return "cloud.fog.fill"
        case 51...57:      return "cloud.drizzle.fill"
        case 61...67:      return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82:      return "cloud.heavyrain.fill"
        case 95...99:      return "cloud.bolt.rain.fill"
        default:           return "cloud.fill"
        }
    }
    static func tint(_ c: Int) -> Color {
        switch c {
        case 0:        return Gruv.yellow
        case 1, 2:     return Gruv.fg2
        case 95...99:  return Gruv.red
        default:       return Gruv.blue
        }
    }
}

// MARK: - Calendar events (EventKit)

struct CalEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let allDay: Bool
    let color: Color
}

final class EventsModel: ObservableObject {
    @Published var events: [CalEvent] = []
    @Published var access = false
    @Published var asked = false
    private let store = EKEventStore()

    func refresh() {
        let done: (Bool) -> Void = { [weak self] granted in
            DispatchQueue.main.async {
                self?.access = granted; self?.asked = true
                if granted { self?.load() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { granted, _ in done(granted) }
        } else {
            store.requestAccess(to: .event) { granted, _ in done(granted) }
        }
    }

    private func load() {
        let cal = Calendar.current
        let start = Date()
        guard let end = cal.date(byAdding: .day, value: 7, to: cal.startOfDay(for: start)) else { return }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let evs = store.events(matching: pred)
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { e -> CalEvent in
                var col = Gruv.blue
                if let cg = e.calendar.cgColor { col = Color(cgColor: cg) }
                return CalEvent(id: e.eventIdentifier ?? UUID().uuidString,
                                title: e.title ?? "(no title)",
                                start: e.startDate, allDay: e.isAllDay, color: col)
            }
        let out = Array(evs)
        DispatchQueue.main.async { self.events = out }
    }
}

struct EventsList: View {
    @ObservedObject var model: EventsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Upcoming").font(.caption.weight(.semibold)).foregroundStyle(Gruv.yellow)
            if model.asked && !model.access {
                Text("Calendar access denied — enable in Settings ▸ Privacy")
                    .font(.caption).foregroundStyle(Gruv.gray)
            } else if model.events.isEmpty {
                Text("Nothing in the next 7 days").font(.caption).foregroundStyle(Gruv.gray)
            } else {
                ForEach(model.events) { e in row(e) }
            }
        }
    }

    private func row(_ e: CalEvent) -> some View {
        Button { AppLauncher.open("com.apple.iCal") } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(e.color).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.title).font(.callout).foregroundStyle(Gruv.fg1).lineLimit(1)
                    Text(when(e)).font(.caption2).foregroundStyle(Gruv.gray)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func when(_ e: CalEvent) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        f.timeZone = homeTZ
        if e.allDay {
            f.dateFormat = cal.isDateInToday(e.start) ? "'Today · all day'" : "EEE d · 'all day'"
            return f.string(from: e.start)
        }
        if cal.isDateInToday(e.start) { f.dateFormat = "'Today' HH:mm" }
        else if cal.isDateInTomorrow(e.start) { f.dateFormat = "'Tomorrow' HH:mm" }
        else { f.dateFormat = "EEE d · HH:mm" }
        return f.string(from: e.start)
    }
}

struct CalendarTab: View {
    @ObservedObject var weather: WeatherModel
    @ObservedObject var events: EventsModel

    private var today: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, d MMMM"
        f.timeZone = homeTZ
        return f.string(from: Date())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(today)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Gruv.fg0)
            WorldClocksView(weather: weather)
            Rectangle().fill(Gruv.bg3.opacity(0.45)).frame(height: 1)
            EventsList(model: events)
            Rectangle().fill(Gruv.bg3.opacity(0.45)).frame(height: 1)
            MiniCalendar()
        }
    }
}

// MARK: - Mini month calendar (tap → Calendar.app)

struct MiniCalendar: View {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday
        c.timeZone = homeTZ
        return c
    }
    private let weekdays = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
    private var cols: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 2), count: 7) }

    var body: some View {
        let now = Date()
        let first = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let daysInMonth = cal.range(of: .day, in: .month, for: first)!.count
        let leading = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let today = cal.component(.day, from: now)

        VStack(alignment: .leading, spacing: 6) {
            Text(monthLabel(first))
                .font(.callout.weight(.semibold))
                .foregroundStyle(Gruv.fg1)
            LazyVGrid(columns: cols, spacing: 3) {
                ForEach(weekdays, id: \.self) { d in
                    Text(d).font(.caption2).foregroundStyle(Gruv.gray).frame(maxWidth: .infinity)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.frame(height: 24) }
                ForEach(1...daysInMonth, id: \.self) { day in
                    Text("\(day)")
                        .font(.caption).monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(day == today ? Gruv.bg0 : Gruv.fg2)
                        .background(
                            Circle().fill(day == today ? Gruv.yellow : .clear)
                                .frame(width: 24, height: 24)
                        )
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { AppLauncher.open("com.apple.iCal") }
    }

    private func monthLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; f.timeZone = cal.timeZone
        return f.string(from: d)
    }
}

struct WorldClocksView: View {
    @ObservedObject var weather: WeatherModel
    private let home = homeTZ

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            VStack(spacing: 14) {
                ForEach(worldCities) { row($0, now: ctx.date) }
            }
        }
    }

    @ViewBuilder
    private func row(_ city: WorldCity, now: Date) -> some View {
        let isHome = city.tzID == home.identifier
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(city.name)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Gruv.fg1)
                Text(subtitle(city, now: now))
                    .font(.caption2)
                    .foregroundStyle(isHome ? Gruv.aqua : Gruv.gray)
            }
            Spacer()
            chip(city)
            Text(timeString(city.tz, now))
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isHome ? Gruv.fg0 : Gruv.fg1)
                .frame(minWidth: 58, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { AppLauncher.open("com.apple.clock") }
    }

    @ViewBuilder
    private func chip(_ city: WorldCity) -> some View {
        if let w = weather.byCity[city.name], w.loaded {
            HStack(spacing: 6) {
                Image(systemName: WeatherIcon.symbol(w.code))
                    .font(.system(size: 15))
                    .foregroundStyle(WeatherIcon.tint(w.code))
                    .symbolRenderingMode(.multicolor)
                    .frame(width: 18)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(w.tempC.rounded()))°")
                        .font(.callout.weight(.medium)).foregroundStyle(Gruv.fg1).monospacedDigit()
                    Text("\(Int(w.hiC.rounded()))°/\(Int(w.loC.rounded()))°")
                        .font(.system(size: 9)).foregroundStyle(Gruv.gray).monospacedDigit()
                }
            }
        }
    }

    private func timeString(_ tz: TimeZone, _ now: Date) -> String {
        let f = DateFormatter(); f.timeZone = tz; f.dateFormat = "HH:mm"
        return f.string(from: now)
    }

    private func subtitle(_ city: WorldCity, now: Date) -> String {
        if city.tzID == home.identifier { return "home" }
        let diff = (city.tz.secondsFromGMT(for: now) - home.secondsFromGMT(for: now)) / 3600
        let dayF = DateFormatter(); dayF.timeZone = city.tz; dayF.dateFormat = "EEE"
        return "\(dayF.string(from: now)) · \(diff >= 0 ? "+" : "")\(diff)h"
    }
}

// MARK: - Now Playing (Spotify via AppleScript)

final class NowPlayingModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: NSImage?
    @Published var isPlaying = false
    @Published var hasTrack = false
    @Published var progress: Double = 0   // 0...1

    private var timer: Timer?
    private var artURL: String?

    private let infoScript = """
    set out to ""
    if application "Spotify" is running then
    \ttell application "Spotify"
    \t\tset ps to player state as string
    \t\tif ps is not "stopped" then
    \t\t\tset out to ps & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track) & linefeed & (artwork url of current track) & linefeed & ((duration of current track) as text) & linefeed & ((player position) as text)
    \t\tend if
    \tend tell
    end if
    return out
    """

    func startPolling() {
        stopPolling()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        let script = infoScript
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = NowPlayingModel.runOSA(script) ?? ""
            let lines = out.components(separatedBy: "\n")
            DispatchQueue.main.async { self?.apply(lines) }
        }
    }

    private func apply(_ lines: [String]) {
        guard lines.count >= 7, !lines[0].isEmpty else {
            hasTrack = false; isPlaying = false
            title = ""; artist = ""; album = ""; artwork = nil; artURL = nil; progress = 0
            return
        }
        hasTrack = true
        isPlaying = lines[0] == "playing"
        title = lines[1]; artist = lines[2]; album = lines[3]
        let durMs = Double(lines[5]) ?? 0
        let pos = Double(lines[6].replacingOccurrences(of: ",", with: ".")) ?? 0
        progress = durMs > 0 ? min(1, max(0, pos / (durMs / 1000))) : 0
        if lines[4] != artURL { artURL = lines[4]; loadArtwork(lines[4]) }
    }

    private func loadArtwork(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { artwork = nil; return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { self?.artwork = img }
        }.resume()
    }

    func playPause() { control("playpause") }
    func next()      { control("next track") }
    func previous()  { control("previous track") }

    private func control(_ cmd: String) {
        let script = "if application \"Spotify\" is running then tell application \"Spotify\" to \(cmd)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = NowPlayingModel.runOSA(script)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refresh() }
        }
    }

    private static func runOSA(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct MusicTab: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        if model.hasTrack {
            VStack(spacing: 14) {
                artwork
                VStack(spacing: 3) {
                    Text(model.title).font(.headline).foregroundStyle(Gruv.fg0).lineLimit(1)
                    Text(model.artist).font(.callout).foregroundStyle(Gruv.fg2).lineLimit(1)
                    Text(model.album).font(.caption).foregroundStyle(Gruv.gray).lineLimit(1)
                }
                progressBar
                controls
                openSpotifyButton
                Spacer()
            }
        } else {
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Gruv.bg1.opacity(0.6))
                    .frame(height: 150)
                    .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(Gruv.gray))
                Text("Nothing playing").font(.headline).foregroundStyle(Gruv.fg2)
                openSpotifyButton
                Spacer()
            }
        }
    }

    private var openSpotifyButton: some View {
        Button { AppLauncher.open("com.spotify.client") } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                Text("Open Spotify")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Gruv.aqua)
            .padding(.vertical, 7)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.bg1.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private var artwork: some View {
        Group {
            if let art = model.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                Gruv.bg1.opacity(0.6)
                    .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(Gruv.gray))
            }
        }
        .frame(width: 168, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Gruv.bg3.opacity(0.5))
                Capsule().fill(Gruv.green).frame(width: geo.size.width * model.progress)
            }
        }
        .frame(height: 4)
    }

    private var controls: some View {
        HStack(spacing: 30) {
            ctrl("backward.fill") { model.previous() }
            ctrl(model.isPlaying ? "pause.fill" : "play.fill", size: 30) { model.playPause() }
            ctrl("forward.fill") { model.next() }
        }
        .padding(.top, 4)
    }

    private func ctrl(_ symbol: String, size: CGFloat = 20, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Gruv.fg1)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

final class SystemModel: ObservableObject {
    @Published var keepAwake = false
    private var caffeinate: Process?

    func toggleKeepAwake() {
        keepAwake.toggle()
        if keepAwake {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-d", "-i"]   // prevent display + idle sleep until killed
            try? p.run()
            caffeinate = p
        } else {
            caffeinate?.terminate()
            caffeinate = nil
        }
    }

    func emptyTrash() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Finder\" to empty trash"]
        try? p.run()
        NotificationCenter.default.post(name: .kajoDismiss, object: nil)
    }
}

struct SystemTab: View {
    @ObservedObject var model: SystemModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: model.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 17)).frame(width: 22)
                    .foregroundStyle(model.keepAwake ? Gruv.aqua : Gruv.fg4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Awake").foregroundStyle(Gruv.fg1)
                    Text(model.keepAwake ? "Mac won't sleep" : "Normal sleep")
                        .font(.caption).foregroundStyle(Gruv.gray)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.keepAwake }, set: { _ in model.toggleKeepAwake() }))
                    .labelsHidden().toggleStyle(.switch).tint(Gruv.green)
            }

            Button { model.emptyTrash() } label: {
                HStack(spacing: 11) {
                    Image(systemName: "trash").font(.system(size: 16)).frame(width: 22).foregroundStyle(Gruv.red)
                    Text("Empty Trash").foregroundStyle(Gruv.fg1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Gruv.fg4)
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .font(.callout)
    }
}

private func placeholderRow(_ text: String) -> some View {
    HStack {
        Circle().fill(Gruv.gray.opacity(0.6)).frame(width: 6, height: 6)
        Text(text).font(.callout).foregroundStyle(Gruv.gray)
    }
}

// MARK: - Timer (custom duration, remembered across launches)

final class TimerModel: ObservableObject {
    @Published private(set) var totalSeconds: Int
    @Published private(set) var remaining: Int
    @Published private(set) var running = false

    private var ticker: Timer?
    private static let key = "timerSeconds"

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.key)
        let total = saved > 0 ? saved : 25 * 60   // default 25 min (pomodoro)
        totalSeconds = total
        remaining = total
    }

    var isPristine: Bool { !running && remaining == totalSeconds }

    func adjust(minutes delta: Int) {
        let m = max(1, min(180, totalSeconds / 60 + delta))
        totalSeconds = m * 60
        UserDefaults.standard.set(totalSeconds, forKey: Self.key)
        if !running { remaining = totalSeconds }
    }

    func startOrPause() { running ? pause() : start() }

    func start() {
        guard !running else { return }
        if remaining <= 0 { remaining = totalSeconds }
        running = true
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func pause() {
        running = false
        ticker?.invalidate(); ticker = nil
    }

    func reset() { pause(); remaining = totalSeconds }

    private func tick() {
        guard remaining > 1 else { finish(); return }
        remaining -= 1
    }

    private func finish() {
        pause()
        remaining = 0
        NSSound(named: "Glass")?.play()
    }
}

struct TimerView: View {
    @ObservedObject var model: TimerModel

    private var shown: Int { model.isPristine ? model.totalSeconds : model.remaining }

    var body: some View {
        VStack(spacing: 18) {
            Text(format(shown))
                .font(.system(size: 52, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.remaining == 0 ? Gruv.yellow : Gruv.fg0)
                .padding(.top, 6)

            HStack(spacing: 8) {
                stepButton("−5") { model.adjust(minutes: -5) }
                stepButton("−1") { model.adjust(minutes: -1) }
                stepButton("+1") { model.adjust(minutes: +1) }
                stepButton("+5") { model.adjust(minutes: +5) }
            }
            .disabled(model.running)
            .opacity(model.running ? 0.4 : 1)

            HStack(spacing: 10) {
                Button(action: model.startOrPause) {
                    Text(model.running ? "Pause" : "Start")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.green.opacity(0.85)))
                        .foregroundStyle(Gruv.bg0)
                }
                Button(action: model.reset) {
                    Text("Reset")
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.bg3.opacity(0.6)))
                        .foregroundStyle(Gruv.fg1)
                }
            }
            .font(.callout.weight(.medium))
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private func stepButton(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.callout.weight(.semibold)).monospacedDigit()
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.bg1.opacity(0.8)))
                .foregroundStyle(Gruv.fg1)
        }
        .buttonStyle(.plain)
    }

    private func format(_ s: Int) -> String {
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - CoreAudio engine

struct AudioDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
}

enum AudioSystem {
    private static let sys = AudioObjectID(kAudioObjectSystemObject)

    static func allDevices() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device(for: $0) }
    }

    private static func device(for id: AudioDeviceID) -> AudioDevice? {
        guard let name = name(of: id) else { return nil }
        let out = channels(id, scope: kAudioObjectPropertyScopeOutput) > 0
        let inp = channels(id, scope: kAudioObjectPropertyScopeInput) > 0
        guard out || inp else { return nil }
        return AudioDevice(id: id, name: name, hasOutput: out, hasInput: inp)
    }

    private static func name(of id: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString?
        let status = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return cf as String?
    }

    private static func channels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func defaultDevice(output: Bool) -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &id)
        return id
    }

    static func setDefault(output: Bool, id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = id
        AudioObjectSetPropertyData(sys, &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    // Volume on the current default output. Many devices (Bluetooth, DACs,
    // aggregates) expose no main-element volume — it lives on channels 1/2 —
    // so fall back to averaging those, mirroring setVolume's element list.
    static func volume() -> Float {
        let dev = defaultDevice(output: true)
        func read(_ element: AudioObjectPropertyElement) -> Float? {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectHasProperty(dev, &addr) else { return nil }
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr else { return nil }
            return v
        }
        if let main = read(kAudioObjectPropertyElementMain) { return main }
        let channels = [read(1), read(2)].compactMap { $0 }
        return channels.isEmpty ? 0 : channels.reduce(0, +) / Float(channels.count)
    }

    static func setVolume(_ value: Float) {
        let dev = defaultDevice(output: true)
        var v = max(0, min(1, value))
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(dev, &addr),
               AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue {
                AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
                if element == kAudioObjectPropertyElementMain { return }
            }
        }
    }

    static func muted() -> Bool {
        let dev = defaultDevice(output: true)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var m: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(dev, &addr) {
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &m)
        }
        return m != 0
    }

    static func setMuted(_ on: Bool) {
        let dev = defaultDevice(output: true)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var m: UInt32 = on ? 1 : 0
        var settable = DarwinBoolean(false)
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr, settable.boolValue {
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
}

final class SoundModel: ObservableObject {
    @Published var volume: Float = 0
    @Published var muted = false
    @Published var outputs: [AudioDevice] = []
    @Published var inputs: [AudioDevice] = []
    @Published var defaultOutput: AudioDeviceID = 0
    @Published var defaultInput: AudioDeviceID = 0

    func refresh() {
        let all = AudioSystem.allDevices()
        outputs = all.filter { $0.hasOutput }
        inputs = all.filter { $0.hasInput }
        defaultOutput = AudioSystem.defaultDevice(output: true)
        defaultInput = AudioSystem.defaultDevice(output: false)
        volume = AudioSystem.volume()
        muted = AudioSystem.muted()
    }

    func setVolume(_ v: Float) {
        volume = v
        AudioSystem.setVolume(v)
        if v > 0 && muted { muted = false; AudioSystem.setMuted(false) }
    }

    func toggleMute() {
        muted.toggle()
        AudioSystem.setMuted(muted)
    }

    func selectOutput(_ id: AudioDeviceID) {
        AudioSystem.setDefault(output: true, id: id)
        defaultOutput = id
        volume = AudioSystem.volume()
        muted = AudioSystem.muted()
    }

    func selectInput(_ id: AudioDeviceID) {
        AudioSystem.setDefault(output: false, id: id)
        defaultInput = id
    }
}

// MARK: - Bluetooth (paired audio devices via blueutil)

struct BTDevice: Identifiable, Equatable {
    let id: String   // MAC address
    let name: String
    var connected: Bool
}

final class BluetoothModel: ObservableObject {
    @Published var devices: [BTDevice] = []
    @Published var busy: Set<String> = []

    private let tool = "/opt/homebrew/bin/blueutil"

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var found: [BTDevice] = []
            if let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] {
                // 0x04 = Audio major class → AirPods, headphones, speakers only.
                for d in paired where d.deviceClassMajor == 0x04 {
                    let addr = (d.addressString ?? "").lowercased()
                    guard !addr.isEmpty else { continue }
                    found.append(BTDevice(id: addr, name: d.name ?? addr, connected: d.isConnected()))
                }
            }
            DispatchQueue.main.async { self.devices = found }
        }
    }

    func toggle(_ d: BTDevice) {
        guard !busy.contains(d.id) else { return }
        busy.insert(d.id)
        let flag = d.connected ? "--disconnect" : "--connect"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            _ = self.run([self.tool, flag, d.id])
            Thread.sleep(forTimeInterval: d.connected ? 1.0 : 2.5)
            let on = (self.run([self.tool, "--is-connected", d.id]) ?? "0")
                .trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            DispatchQueue.main.async {
                self.busy.remove(d.id)
                if let i = self.devices.firstIndex(where: { $0.id == d.id }) {
                    self.devices[i].connected = on
                }
            }
        }
    }

    private func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

struct SoundTab: View {
    @ObservedObject var model: SoundModel
    @ObservedObject var bt: BluetoothModel

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                volumeRow
                deviceSection("Output", devices: model.outputs, selected: model.defaultOutput) {
                    model.selectOutput($0)
                }
                deviceSection("Input", devices: model.inputs, selected: model.defaultInput) {
                    model.selectInput($0)
                }
                bluetoothSection
            }
            .padding(.bottom, 8)
        }
    }

    private var bluetoothSection: some View {
        Group {
            if !bt.devices.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Bluetooth")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Gruv.yellow)
                        Spacer()
                        Button {
                            AppLauncher.openURL("x-apple.systempreferences:com.apple.BluetoothSettings")
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.caption)
                                .foregroundStyle(Gruv.fg4)
                        }
                        .buttonStyle(.plain)
                        .help("Bluetooth Settings")
                    }
                    ForEach(bt.devices) { d in
                        Button { bt.toggle(d) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: icon(for: d.name))
                                    .frame(width: 18)
                                    .foregroundStyle(d.connected ? Gruv.aqua : Gruv.fg4)
                                Text(d.name).foregroundStyle(Gruv.fg1).lineLimit(1)
                                Spacer()
                                if bt.busy.contains(d.id) {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text(d.connected ? "Connected" : "Connect")
                                        .font(.caption)
                                        .foregroundStyle(d.connected ? Gruv.green : Gruv.fg4)
                                }
                            }
                            .font(.callout)
                            .padding(.vertical, 6).padding(.horizontal, 8)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(d.connected ? Gruv.bg1.opacity(0.65) : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Button { model.toggleMute() } label: {
                Image(systemName: model.muted || model.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(model.muted ? Gruv.red : Gruv.fg2)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            Slider(value: Binding(get: { Double(model.volume) },
                                  set: { model.setVolume(Float($0)) }), in: 0...1)
                .tint(Gruv.green)
        }
    }

    private func deviceSection(_ title: String, devices: [AudioDevice],
                               selected: AudioDeviceID, pick: @escaping (AudioDeviceID) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Gruv.yellow)
            ForEach(devices) { d in
                Button { pick(d.id) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: icon(for: d.name))
                            .frame(width: 18).foregroundStyle(Gruv.fg4)
                        Text(d.name).foregroundStyle(Gruv.fg1).lineLimit(1)
                        Spacer()
                        if d.id == selected {
                            Image(systemName: "checkmark").foregroundStyle(Gruv.green)
                        }
                    }
                    .font(.callout)
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(d.id == selected ? Gruv.bg1.opacity(0.65) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpods.max" }
        if n.contains("airpods")     { return "airpods" }
        if n.contains("headphone")   { return "headphones" }
        if n.contains("microphone") || n.contains("mic") { return "mic.fill" }
        if n.contains("display")     { return "display" }
        return "hifispeaker.fill"
    }
}

// MARK: - Power (battery + wattage via IOKit)

struct PowerInfo {
    var hasBattery = false
    var percent = 0
    var charging = false
    var onAC = false
    var fullyCharged = false
    var batteryWatts = 0.0   // + charging, − discharging
    var adapterWatts = 0
    var timeToEmpty = -1     // minutes (−1 = calculating)
    var timeToFull = -1
}

final class PowerModel: ObservableObject {
    @Published var info = PowerInfo()
    private var timer: Timer?

    func startPolling() {
        stopPolling()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    func refresh() {
        var i = PowerInfo()
        readPowerSources(into: &i)
        readSmartBattery(into: &i)
        info = i
    }

    private func readPowerSources(into i: inout PowerInfo) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            i.hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let mx  = d[kIOPSMaxCapacityKey as String] as? Int ?? 100
            i.percent = mx > 0 ? Int((Double(cur) / Double(mx) * 100).rounded()) : cur
            i.charging = d[kIOPSIsChargingKey as String] as? Bool ?? false
            i.onAC = (d[kIOPSPowerSourceStateKey as String] as? String) == (kIOPSACPowerValue as String)
            i.fullyCharged = d[kIOPSIsChargedKey as String] as? Bool ?? false
            i.timeToEmpty = d[kIOPSTimeToEmptyKey as String] as? Int ?? -1
            i.timeToFull = d[kIOPSTimeToFullChargeKey as String] as? Int ?? -1
            return
        }
    }

    private func readSmartBattery(into i: inout PowerInfo) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }

        func int(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }
        // InstantAmperage reacts faster than the averaged Amperage.
        let amperage = int("InstantAmperage") ?? int("Amperage") ?? 0   // mA, signed
        let voltage = int("Voltage") ?? 0                               // mV
        i.batteryWatts = Double(amperage) * Double(voltage) / 1_000_000.0
        if let adapter = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString,
                                                         kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
            i.adapterWatts = (adapter["Watts"] as? Int) ?? 0
        }
    }
}

struct PowerTab: View {
    @ObservedObject var model: PowerModel

    var body: some View {
        let i = model.info
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: batteryIcon(i))
                    .font(.system(size: 38))
                    .foregroundStyle(color(i))
                Text("\(i.percent)%")
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Gruv.fg0)
            }
            .padding(.top, 4)

            VStack(spacing: 0) {
                row("Status", statusText(i), color(i))
                row(flowLabel(i), String(format: "%.1f W", abs(i.batteryWatts)))
                if i.adapterWatts > 0 { row("Adapter", "\(i.adapterWatts) W") }
                row(timeLabel(i), timeValue(i))
            }
            Spacer()
        }
    }

    private func row(_ label: String, _ value: String, _ valueColor: Color = Gruv.fg1) -> some View {
        HStack {
            Text(label).foregroundStyle(Gruv.fg4)
            Spacer()
            Text(value).foregroundStyle(valueColor).monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 9)
        .overlay(Rectangle().fill(Gruv.bg3.opacity(0.3)).frame(height: 1), alignment: .bottom)
    }

    private func batteryIcon(_ i: PowerInfo) -> String {
        if i.charging { return "battery.100.bolt" }
        switch i.percent {
        case 90...:  return "battery.100"
        case 65..<90: return "battery.75"
        case 40..<65: return "battery.50"
        case 15..<40: return "battery.25"
        default:      return "battery.0"
        }
    }

    private func color(_ i: PowerInfo) -> Color {
        if i.charging { return Gruv.green }
        switch i.percent {
        case ..<15: return Gruv.red
        case ..<30: return Gruv.yellow
        default:    return Gruv.fg2
        }
    }

    private func statusText(_ i: PowerInfo) -> String {
        if i.fullyCharged { return "Fully charged" }
        if i.charging { return "Charging" }
        if i.onAC { return "On adapter" }
        return "On battery"
    }

    private func flowLabel(_ i: PowerInfo) -> String {
        i.batteryWatts >= 0 ? "Charging at" : "Draining at"
    }

    private func timeLabel(_ i: PowerInfo) -> String {
        i.onAC ? "Time to full" : "Time remaining"
    }

    private func timeValue(_ i: PowerInfo) -> String {
        if i.fullyCharged { return "—" }
        let m = i.onAC ? i.timeToFull : i.timeToEmpty
        if m < 0 { return "Calculating…" }
        let h = m / 60, min = m % 60
        return h > 0 ? "\(h)h \(min)m" : "\(min)m"
    }
}

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
                    row("WAN IP", s.wanIP.isEmpty ? "—" : s.wanIP)
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

final class HAModel: NSObject, ObservableObject, URLSessionDelegate {
    @Published var lights: [HAEntity] = []
    @Published var sensors: [HAEntity] = []
    @Published var configured = false
    @Published var reachable = false
    @Published var busy: Set<String> = []

    private var url = "", token = ""
    private var wanted: [String] = []
    private var session: URLSession!
    private var timer: Timer?

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        loadConfig()
    }

    private func loadConfig() {
        let path = kajoConfigDir + "/ha.json"
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { configured = false; return }
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

    func refresh() { guard configured else { return }; Task { [weak self] in await self?.load() } }

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
            await MainActor.run { self.busy.remove(e.entityId) }
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
            var e = HAEntity(entityId: id, domain: domain,
                             name: attrs["friendly_name"] as? String ?? id,
                             state: s["state"] as? String ?? "",
                             unit: attrs["unit_of_measurement"] as? String ?? "",
                             targetTemp: attrs["temperature"] as? Double)
            if e.domain == "light" || e.domain == "switch" || e.domain == "lock" { lts.append(e) } else { sns.append(e) }
        }
        await MainActor.run { self.lights = lts; self.sensors = sns; self.reachable = true }
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

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
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

    private func hint(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Gruv.fg2)
            Text(sub).font(.callout).foregroundStyle(Gruv.gray)
        }.padding(.top, 8)
    }
}

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
        let path = kajoConfigDir + "/pi.json"
        guard let data = FileManager.default.contents(atPath: path),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            configured = false; return
        }
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
        guard configured else { return }
        loading = true
        // LAN first (live, fast). Fall back to the CloudFront snapshot when away.
        fetch(local, timeoutOverride: 2.5) { [weak self] lan in
            guard let self else { return }
            if var s = lan { s.source = "lan"; self.apply(s); return }
            guard !self.remote.isEmpty else { self.markUnreachable(); return }
            var req = URLRequest(url: URL(string: self.remote)!)
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
            self.loading = false
            self.everLoaded = true
            self.status = s
            if let enc = try? JSONEncoder().encode(s) {
                UserDefaults.standard.set(enc, forKey: "pi.cache")   // keep last view for instant open
            }
        }
    }

    private func markUnreachable() {
        DispatchQueue.main.async {
            self.loading = false
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

    private func hint(_ title: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline).foregroundStyle(Gruv.fg2)
            Text(sub).font(.callout).foregroundStyle(Gruv.gray)
        }.padding(.top, 8)
    }
}

// MARK: - Memes (curated picker: grid · fuzzy search · click-to-copy)

let memeUntagged = "tagthis"   // untagged memes carry this so you can search for them

struct Meme: Identifiable, Codable, Equatable {
    var file: String
    var tags: [String]
    var added: Date
    var id: String { file }
}

final class MemeLibrary: ObservableObject {
    @Published var memes: [Meme] = []
    @Published var search = ""
    @Published var editingMeme: Meme?          // the meme whose tags are being edited (inline overlay)
    private let filesDir: URL, trashDir: URL, indexURL: URL

    var filtered: [Meme] {
        guard !search.isEmpty else { return memes }
        return memes
            .compactMap { m in memeFuzzy(search, m.tags.joined(separator: " ") + " " + m.file).map { (m, $0) } }
            .sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    init() {
        let base = URL(fileURLWithPath: kajoConfigDir).appendingPathComponent("memes")
        filesDir = base.appendingPathComponent("files")
        trashDir = base.appendingPathComponent("trash")
        indexURL = base.appendingPathComponent("index.json")
        for d in [filesDir, trashDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        load()
    }

    func url(_ m: Meme) -> URL { filesDir.appendingPathComponent(m.file) }

    func load() {
        var list: [Meme] = []
        if let data = try? Data(contentsOf: indexURL),
           let arr = try? JSONDecoder().decode([Meme].self, from: data) {
            list = arr.filter { FileManager.default.fileExists(atPath: filesDir.appendingPathComponent($0.file).path) }
        }
        let known = Set(list.map { $0.file })
        let exts: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic"]
        if let files = try? FileManager.default.contentsOfDirectory(atPath: filesDir.path) {
            for f in files where !f.hasPrefix(".") && !known.contains(f) && exts.contains((f as NSString).pathExtension.lowercased()) {
                list.append(Meme(file: f, tags: [memeUntagged], added: Date()))
            }
        }
        list.sort { $0.added > $1.added }
        memes = list
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(memes) { try? data.write(to: indexURL) }
    }

    func add(data: Data, ext: String, tags: [String] = []) {
        let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).\(ext.isEmpty ? "png" : ext)"
        try? data.write(to: filesDir.appendingPathComponent(name))
        memes.insert(Meme(file: name, tags: tags.isEmpty ? [memeUntagged] : tags, added: Date()), at: 0)
        persist()
    }

    func setTags(_ m: Meme, _ tags: [String]) {
        guard let i = memes.firstIndex(where: { $0.id == m.id }) else { return }
        memes[i].tags = tags.isEmpty ? [memeUntagged] : tags
        persist()
    }

    func delete(_ m: Meme) {
        try? FileManager.default.moveItem(at: url(m), to: trashDir.appendingPathComponent(m.file))
        memes.removeAll { $0.id == m.id }
        persist()
    }

    private static let imgExts: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic"]

    func addFromClipboard() {
        let pb = NSPasteboard.general
        // 1. A real file copied in Finder → read the original bytes (keeps GIF animation, exact image).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first(where: { Self.imgExts.contains($0.pathExtension.lowercased()) }),
           let data = try? Data(contentsOf: u) { add(data: data, ext: u.pathExtension.lowercased()); return }
        // 2. Raw GIF bytes.
        if let gif = pb.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")) { add(data: gif, ext: "gif"); return }
        // 3. PNG bytes.
        if let png = pb.data(forType: .png) { add(data: png, ext: "png"); return }
        // 4. TIFF / generic image → re-encode to PNG.
        if let tiff = pb.data(forType: .tiff) ?? NSImage(pasteboard: pb)?.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { add(data: png, ext: "png") }
    }

    var clipboardHasImage: Bool {
        let pb = NSPasteboard.general
        if pb.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")) != nil { return true }
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil { return true }
        if NSImage(pasteboard: pb) != nil { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return urls.contains { Self.imgExts.contains($0.pathExtension.lowercased()) }
        }
        return false
    }

    func copy(_ m: Meme) {
        let u = url(m); let pb = NSPasteboard.general; pb.clearContents()
        let item = NSPasteboardItem()
        if let data = try? Data(contentsOf: u) {
            switch u.pathExtension.lowercased() {
            case "gif": item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            case "png": item.setData(data, forType: .png)
            default: break
            }
        }
        if let img = NSImage(contentsOf: u), let tiff = img.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item, u as NSURL])
    }
}

// Subsequence fuzzy match with a consecutive-run bonus.
func memeFuzzy(_ query: String, _ text: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased()), t = Array(text.lowercased())
    var qi = 0, score = 0, last = -2
    for (ti, c) in t.enumerated() where qi < q.count {
        if c == q[qi] { score += (ti == last + 1) ? 6 : 1; last = ti; qi += 1 }
    }
    return qi == q.count ? score : nil
}

struct MemeThumb: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown      // fit within the cell, keep aspect ratio
        v.imageAlignment = .alignCenter
        v.animates = true
        v.image = NSImage(contentsOf: url)
        // Don't let the image's natural size dictate layout — let the SwiftUI frame shrink it.
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) { v.animates = true }
}

// AppKit text field that reliably grabs first-responder in Kajo's borderless,
// non-activating panel (SwiftUI @FocusState doesn't engage there) and reports
// every keystroke for live filtering.
struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 13)
        tf.textColor = NSColor(Gruv.fg1)
        tf.delegate = context.coordinator
        tf.lineBreakMode = .byTruncatingTail
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }
    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self           // keep the binding fresh so edits propagate
        if tf.stringValue != text { tf.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusedTextField
        init(_ p: FocusedTextField) { parent = p }
        func controlTextDidChange(_ note: Notification) {
            if let tf = note.object as? NSTextField { parent.text = tf.stringValue }
        }
        func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
    }
}

struct MemesTab: View {
    @ObservedObject var model: MemeLibrary
    @State private var editText = ""

    private let cols = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Gruv.fg4)
                FocusedTextField(text: $model.search, placeholder: "Search…  (try “tagthis”)",
                                 onSubmit: { if let f = model.filtered.first { pick(f) } })
                Text("\(model.filtered.count)").font(.caption2).foregroundStyle(Gruv.gray)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.bg1.opacity(0.6)))

            if model.filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(Gruv.fg4)
                    Text(model.memes.isEmpty ? "Paste (⌘V) or drag a meme in" : "No match")
                        .font(.caption).foregroundStyle(Gruv.gray)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(model.filtered) { cell($0) }
                    }.padding(.vertical, 4)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { drop($0); return true }
        .overlay { if let m = model.editingMeme { editorOverlay(m) } }
    }

    private func cell(_ m: Meme) -> some View {
        VStack(spacing: 2) {
            MemeThumb(url: model.url(m))
                .frame(height: 78).frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(m.tags.contains(memeUntagged) ? memeUntagged : m.tags.prefix(2).joined(separator: ", "))
                .font(.system(size: 10)).lineLimit(1)
                .foregroundStyle(m.tags.contains(memeUntagged) ? Gruv.yellow : Gruv.gray)
        }
        .contentShape(Rectangle())
        .onTapGesture { pick(m) }
        .help(m.tags.joined(separator: ", "))
        .contextMenu {
            Button("Copy") { model.copy(m) }
            Button("Edit tags…") { startEdit(m) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(m) }
        }
    }

    private func editorOverlay(_ m: Meme) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { model.editingMeme = nil }
            VStack(alignment: .leading, spacing: 10) {
                Text("Edit tags").font(.headline).foregroundStyle(Gruv.fg1)
                MemeThumb(url: model.url(m)).frame(height: 110)
                    .background(Color.black.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 6))
                FocusedTextField(text: $editText, placeholder: "comma, separated, tags", onSubmit: { saveEdit(m) })
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Gruv.bg1.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Gruv.fg4.opacity(0.3)))
                HStack {
                    Button("Cancel") { model.editingMeme = nil }
                    Spacer()
                    Button("Save") { saveEdit(m) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14).frame(width: 290)
            .background(RoundedRectangle(cornerRadius: 12).fill(Gruv.bg0))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Gruv.fg4.opacity(0.25)))
        }
    }

    private func startEdit(_ m: Meme) {
        editText = m.tags.filter { $0 != memeUntagged }.joined(separator: ", ")
        model.editingMeme = m
    }
    private func saveEdit(_ m: Meme) {
        model.setTags(m, editText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        model.editingMeme = nil
    }
    private func pick(_ m: Meme) {
        model.copy(m)
        NotificationCenter.default.post(name: .kajoDismiss, object: nil)
    }

    private func drop(_ providers: [NSItemProvider]) {
        for p in providers {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var u: URL?
                if let d = item as? Data { u = URL(dataRepresentation: d, relativeTo: nil) } else if let x = item as? URL { u = x }
                guard let u, let data = try? Data(contentsOf: u) else { return }
                DispatchQueue.main.async { model.add(data: data, ext: u.pathExtension.lowercased()) }
            }
        }
    }
}

// MARK: - URL cleaner (kajo://clip/clean, Hyper+U)
//
// Strips tracking params from an http(s) URL string; returns nil if the input
// isn't one. ponytail: param blocklist + an Amazon special case covers ~95% of
// real links; add per-host rules here as they annoy in practice (ClearURLs-style
// rule engine is the upgrade path if this list ever feels unmaintainable).
func cleanedURL(_ raw: String) -> String? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var comps = URLComponents(string: s), let host = comps.host?.lowercased(),
          comps.scheme == "http" || comps.scheme == "https" else { return nil }

    // Amazon: everything but /dp/ASIN is noise (300 chars → 30).
    if host.contains("amazon.") {
        let parts = comps.path.split(separator: "/").map(String.init)
        for (i, p) in parts.enumerated() where (p == "dp" || p == "product") && i + 1 < parts.count {
            let asin = parts[i + 1]
            if asin.count == 10, asin.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return "https://\(host)/dp/\(asin)"
            }
        }
    }

    let junkPrefixes = ["utm_", "pk_", "mc_", "vero_", "oly_", "fb_", "hsa_", "matomo_", "piwik_"]
    let junk: Set<String> = ["fbclid", "gclid", "gclsrc", "dclid", "msclkid", "yclid", "twclid",
                             "ttclid", "igsh", "igshid", "srsltid", "spm", "sk", "_hsenc", "_hsmi",
                             "wt_mc", "cmpid", "ncid", "li_fat_id", "ref", "ref_src", "ref_url",
                             "soc_src", "soc_trk", "wickedid", "sms_source", "gbraid", "wbraid"]
    // Pure share-tracking on these hosts, but meaningful elsewhere — keep host-scoped.
    var hostJunk: Set<String> = []
    if host.contains("youtube.com") || host == "youtu.be" { hostJunk = ["si", "feature", "pp", "start_radio"] }
    else if host.contains("spotify.com") { hostJunk = ["si"] }
    else if host == "x.com" || host.contains("twitter.com") { hostJunk = ["s", "t"] }

    // percentEncodedQueryItems (not queryItems) so kept values stay byte-identical.
    let kept = (comps.percentEncodedQueryItems ?? []).filter { item in
        let n = item.name.lowercased()
        // ponytail: list=RD… is an auto-generated radio mix, not a saved playlist — drop it
        if n == "list", (item.value ?? "").hasPrefix("RD"),
           host.contains("youtube.com") || host == "youtu.be" { return false }
        return !junk.contains(n) && !hostJunk.contains(n)
            && !junkPrefixes.contains { n.hasPrefix($0) }
    }
    comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
    return comps.string
}

// Tiny transient HUD — feedback for headless kajo:// actions (no panel shown).
func showHUD(_ text: String) {
    let label = NSTextField(labelWithString: text)
    label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
    label.textColor = NSColor(red: 0.92, green: 0.86, blue: 0.70, alpha: 1)   // gruvbox fg
    label.sizeToFit()
    let pad: CGFloat = 14
    let size = NSSize(width: label.frame.width + pad * 2, height: label.frame.height + pad)
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .transient]
    let bg = NSView(frame: NSRect(origin: .zero, size: size))
    bg.wantsLayer = true
    bg.layer?.backgroundColor = NSColor(red: 0.157, green: 0.157, blue: 0.157, alpha: 0.95).cgColor
    bg.layer?.cornerRadius = 9
    label.frame.origin = NSPoint(x: pad, y: pad / 2)
    bg.addSubview(label)
    panel.contentView = bg
    if let screen = NSScreen.main {
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 60))
    }
    panel.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }
}

// MARK: - Clipboard tab (replaces Maccy + Hammerspoon Hyper+V)
//
// App-lifetime clipboard monitor: polls NSPasteboard.changeCount every 0.5s (the
// only way — macOS has no clipboard-change event). Text + image history, newest
// first, capped at 100 (non-secret). Concealed copies (1Password passwords, marked
// org.nspasteboard.ConcealedType) go to an in-memory "secret" lane with a 20s TTL —
// pasteable briefly, never written to disk. Select → copies back (you paste).
// Text items also have a → vim action (nvr), porting Hammerspoon's Hyper+V.

struct ClipItem: Identifiable, Codable {
    enum Kind: String, Codable { case text, image }
    var id = UUID()
    var kind: Kind
    var text: String?
    var file: String?            // image filename in files/
    var added = Date()
    var secret = false           // concealed → ephemeral, RAM-only
    var expiresAt: Date?         // set for secret items
}

final class ClipboardModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var search = "" { didSet { sel = 0 } }
    @Published var sel = 0          // ↑/↓ highlighted index into `filtered`

    private let filesDir: URL
    private let indexURL: URL
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let cap: Int
    private let secretTTL: TimeInterval
    private let maxImageBytes: Int
    private let nvrPath: String
    private let nvimSocket: String

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let gifType   = NSPasteboard.PasteboardType("com.compuserve.gif")
    private static let imgExts: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic"]

    init() {
        let base = URL(fileURLWithPath: kajoConfigDir).appendingPathComponent("clipboard")
        filesDir = base.appendingPathComponent("files")
        indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        // clipboard.json (optional): historyCap, secretTTLSeconds, maxImageMB, nvrPath, nvimSocket
        let cfg = (try? Data(contentsOf: URL(fileURLWithPath: kajoConfigDir + "/clipboard.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        cap = (cfg["historyCap"] as? Int) ?? 100
        secretTTL = (cfg["secretTTLSeconds"] as? Double) ?? 20
        maxImageBytes = ((cfg["maxImageMB"] as? Int) ?? 5) * 1024 * 1024
        nvrPath = ((cfg["nvrPath"] as? String).map { ($0 as NSString).expandingTildeInPath }) ?? (NSHomeDirectory() + "/Library/Python/3.14/bin/nvr")
        nvimSocket = (cfg["nvimSocket"] as? String) ?? "/tmp/nvimsocket2"
        load()
    }

    func fileURL(_ name: String) -> URL { filesDir.appendingPathComponent(name) }

    // Runs for the whole app lifetime (NOT tab-scoped) — you copy things all day,
    // then open Kajo to retrieve. Started once from PanelController.init.
    func startMonitoring() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        pruneExpired()
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        capture(pb)
    }

    private func pruneExpired() {
        let now = Date()
        if items.contains(where: { ($0.expiresAt ?? .distantFuture) < now }) {
            items.removeAll { ($0.expiresAt ?? .distantFuture) < now }
        }
    }

    private func capture(_ pb: NSPasteboard) {
        let types = pb.types ?? []
        if types.contains(Self.transient) { return }          // honor the no-store opt-out
        let secret = types.contains(Self.concealed)

        // Image first (passwords are concealed text, never images).
        if let (data, ext) = imageData(pb) {
            guard data.count <= maxImageBytes else { return }
            let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).\(ext)"
            try? data.write(to: fileURL(name))
            insert(ClipItem(kind: .image, file: name))
            return
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            if s.hasPrefix("kajo://") { return }               // never store our own control URLs
            if items.first?.text == s { return }               // dedup consecutive
            var it = ClipItem(kind: .text, text: s, secret: secret)
            if secret { it.expiresAt = Date().addingTimeInterval(secretTTL) }
            insert(it)
        }
    }

    private func imageData(_ pb: NSPasteboard) -> (Data, String)? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first(where: { Self.imgExts.contains($0.pathExtension.lowercased()) }),
           let d = try? Data(contentsOf: u) { return (d, u.pathExtension.lowercased()) }
        if let gif = pb.data(forType: Self.gifType) { return (gif, "gif") }
        if let png = pb.data(forType: .png) { return (png, "png") }
        if let tiff = pb.data(forType: .tiff) ?? NSImage(pasteboard: pb)?.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { return (png, "png") }
        return nil
    }

    private func insert(_ it: ClipItem) {
        items.insert(it, at: 0)
        var normal = 0
        items = items.filter { item in
            if item.expiresAt != nil { return true }           // secrets self-expire, exempt from cap
            normal += 1
            if normal > cap {
                if item.kind == .image, let f = item.file { try? FileManager.default.removeItem(at: fileURL(f)) }
                return false
            }
            return true
        }
        persist()
    }

    // Write an item to the pasteboard. Suppress re-capture of our own write —
    // critical for secrets, else the plain re-copy would be stored to disk.
    private func writePasteboard(_ it: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch it.kind {
        case .text:
            if let t = it.text { pb.setString(t, forType: .string) }
        case .image:
            if let f = it.file, let data = try? Data(contentsOf: fileURL(f)) {
                let item = NSPasteboardItem()
                if (f as NSString).pathExtension.lowercased() == "gif" { item.setData(data, forType: Self.gifType) }
                else { item.setData(data, forType: .png) }
                if let img = NSImage(data: data), let tiff = img.tiffRepresentation { item.setData(tiff, forType: .tiff) }
                pb.writeObjects([item])
            }
        }
        lastChange = pb.changeCount
    }

    // Copies an item back to the pasteboard (you paste) and floats it to the top,
    // so the list always reflects what's currently on the clipboard.
    func select(_ it: ClipItem) {
        writePasteboard(it)
        if let idx = items.firstIndex(where: { $0.id == it.id }), idx != 0 {
            let moved = items.remove(at: idx)
            items.insert(moved, at: 0)
            persist()
        }
    }

    // Headless (kajo://clip/prev): grab the PREVIOUS item → it becomes current and
    // floats to the top. Press again to swap back. No panel shown.
    func copyPrevious() {
        guard items.count >= 2 else { return }
        select(items[1])
    }

    // Headless (kajo://clip/clean): strip tracking junk off the URL currently on
    // the clipboard. Writes back WITHOUT suppressing capture, so the cleaned URL
    // lands in history as a new item on the monitor's next tick.
    func cleanClipboardURL() {
        let pb = NSPasteboard.general
        guard let s = pb.string(forType: .string), let cleaned = cleanedURL(s) else {
            showHUD("🧹 not a URL"); return
        }
        if cleaned == s.trimmingCharacters(in: .whitespacesAndNewlines) {
            showHUD("🧹 already clean"); return
        }
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
        showHUD("🧹 URL cleaned")
    }

    // Row action: clean a history item's URL and copy the result (captured as a new item).
    func cleanAndCopy(_ it: ClipItem) {
        guard let t = it.text, let cleaned = cleanedURL(t) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
    }

    func delete(_ it: ClipItem) {
        if it.kind == .image, let f = it.file { try? FileManager.default.removeItem(at: fileURL(f)) }
        items.removeAll { $0.id == it.id }
        persist()
    }

    // Text → a new nvim tab (replaces Hammerspoon Hyper+V).
    func pasteToVim(_ it: ClipItem) {
        guard it.kind == .text, let text = it.text else { return }
        let sock = nvimSocket
        guard FileManager.default.fileExists(atPath: sock) else { return }
        let tmp = NSTemporaryDirectory() + "kajo-clip-\(UUID().uuidString.prefix(6)).txt"
        try? text.write(toFile: tmp, atomically: true, encoding: .utf8)
        let nvr = nvrPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "'\(nvr)' --servername '\(sock)' --remote-tab-silent '\(tmp)'"]
        try? p.run()
    }

    // Persist NON-secret items only — secrets never touch disk.
    private func persist() {
        let durable = items.filter { $0.expiresAt == nil && !$0.secret }
        if let data = try? JSONEncoder().encode(durable) { try? data.write(to: indexURL) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let arr = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = arr.filter { it in
            if it.kind == .image, let f = it.file { return FileManager.default.fileExists(atPath: fileURL(f).path) }
            return it.text != nil
        }
    }

    // While querying, hide images and fuzzy-rank text matches.
    var filtered: [ClipItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return items }
        return items.filter { $0.kind == .text }
            .compactMap { it -> (ClipItem, Int)? in
                guard let t = it.text, let s = memeFuzzy(q, t) else { return nil }
                return (it, s)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    var selectedItem: ClipItem? {
        let f = filtered
        return f.indices.contains(sel) ? f[sel] : f.first
    }
    func move(_ d: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        sel = max(0, min(n - 1, sel + d))
    }
}

struct ClipboardTab: View {
    @ObservedObject var model: ClipboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Gruv.fg4)
                FocusedTextField(text: $model.search, placeholder: "Search clipboard…",
                                 onSubmit: { if let it = model.selectedItem { pick(it) } })
                Text("\(model.filtered.count)").font(.caption2).foregroundStyle(Gruv.gray)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.bg1.opacity(0.6)))
            .onAppear { model.sel = 0 }

            if model.filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(Gruv.fg4)
                    Text(model.items.isEmpty ? "Copy something — it shows up here" : "No match")
                        .font(.caption).foregroundStyle(Gruv.gray)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.filtered) { row($0) }
                        }.padding(.vertical, 2)
                    }
                    .onChange(of: model.sel) { _, _ in
                        if let id = model.selectedItem?.id {
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ it: ClipItem) -> some View {
        HStack(spacing: 8) {
            if it.kind == .image, let f = it.file {
                MemeThumb(url: model.fileURL(f))
                    .frame(width: 54, height: 38)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Spacer(minLength: 0)
            } else {
                Image(systemName: it.secret ? "lock.fill" : "text.alignleft")
                    .font(.caption).frame(width: 18)
                    .foregroundStyle(it.secret ? Gruv.yellow : Gruv.fg4)
                Text(preview(it))
                    .font(.system(size: 12, design: it.secret ? .default : .monospaced))
                    .foregroundStyle(it.secret ? Gruv.yellow : Gruv.fg1)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if !it.secret, let t = it.text, cleanedURL(t) != nil {
                    Button { model.cleanAndCopy(it); dismiss() } label: {
                        Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(Gruv.yellow)
                    }
                    .buttonStyle(.plain)
                    .help("Clean URL & copy")
                }
                if it.secret, let exp = it.expiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("\(max(0, Int(exp.timeIntervalSince(ctx.date).rounded(.up))))s")
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(Gruv.gray)
                    }
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(it.id == model.selectedItem?.id ? Gruv.yellow.opacity(0.18) : Gruv.bg1.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(it.id == model.selectedItem?.id ? Gruv.yellow.opacity(0.7) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { pick(it) }
        .contextMenu {
            Button("Copy") { model.select(it) }
            if it.kind == .text { Button("→ vim") { model.pasteToVim(it); dismiss() } }
            if let t = it.text, !it.secret, cleanedURL(t) != nil {
                Button("🧹 Clean URL & copy") { model.cleanAndCopy(it); dismiss() }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(it) }
        }
    }

    private func preview(_ it: ClipItem) -> String {
        switch it.kind {
        case .image: return "🖼 image"
        case .text:
            let t = (it.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return it.secret ? "•••••• (concealed)" : t
        }
    }

    private func pick(_ it: ClipItem) { model.select(it); dismiss() }
    private func dismiss() { NotificationCenter.default.post(name: .kajoDismiss, object: nil) }
}

// MARK: - Floating panel that can become key (for Esc / focus dismissal)

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Allow positioning off-screen (above the top edge) so the slide-down
    // animation can start fully hidden instead of being clamped on-screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - Panel controller

final class PanelController {
    let state = PanelState()
    let weather = WeatherModel()
    let events = EventsModel()
    let timer = TimerModel()
    let nowPlaying = NowPlayingModel()
    let sound = SoundModel()
    let bluetooth = BluetoothModel()
    let power = PowerModel()
    let network = NetworkModel()
    let unifi = UniFiModel()
    let vpn = VPNModel()
    let ha = HAModel()
    let pi = PiModel()
    let ai = AIModel()
    let system = SystemModel()
    let memes = MemeLibrary()
    let clipboard = ClipboardModel()
    private let panel: FloatingPanel
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?   // app that had focus before we showed
    private var cancellables = Set<AnyCancellable>()
    private let size = NSSize(width: 430, height: 600)

    init() {
        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.appearance = NSAppearance(named: .darkAqua)
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 16
        visual.layer?.masksToBounds = true
        visual.frame = NSRect(origin: .zero, size: size)

        let hosting = NSHostingView(rootView: PanelView(state: state, weather: weather, events: events, timer: timer, nowPlaying: nowPlaying, sound: sound, bluetooth: bluetooth, power: power, network: network, unifi: unifi, vpn: vpn, ha: ha, pi: pi, ai: ai, system: system, memes: memes, clipboard: clipboard))
        hosting.frame = visual.bounds
        hosting.autoresizingMask = [.width, .height]
        visual.addSubview(hosting)

        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = visual
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        NotificationCenter.default.addObserver(forName: .kajoDismiss, object: nil, queue: .main) { [weak self] _ in
            self?.hide()
        }

        // Track the last externally-active app so hide() can hand focus back to it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if app.bundleIdentifier != Bundle.main.bundleIdentifier { self?.previousApp = app }
        }

        // Poll now-playing only while the Music tab is open.
        state.$tab
            .receive(on: RunLoop.main)
            .sink { [weak self] tab in self?.updatePolling(forTab: tab) }
            .store(in: &cancellables)

        if enabledModules.contains(.clipboard) { clipboard.startMonitoring() }   // app-lifetime monitor, only if enabled
    }

    private func updatePolling(forTab tab: Tab) {
        if panel.isVisible && tab == .calendar { weather.refresh(); events.refresh() }
        if panel.isVisible && tab == .music { nowPlaying.startPolling() }
        else { nowPlaying.stopPolling() }
        if panel.isVisible && tab == .sound { sound.refresh(); bluetooth.refresh() }
        if panel.isVisible && tab == .power { power.startPolling() } else { power.stopPolling() }
        if panel.isVisible && tab == .network { network.refresh(); network.scan() }
        if panel.isVisible && tab == .unifi { unifi.startPolling() } else { unifi.stopPolling() }
        if panel.isVisible && tab == .vpn { vpn.startPolling() } else { vpn.stopPolling() }
        if panel.isVisible && tab == .home { ha.startPolling() } else { ha.stopPolling() }
        if panel.isVisible && tab == .pi { pi.startPolling() } else { pi.stopPolling() }
        if panel.isVisible && tab == .ai { ai.startPolling() } else { ai.stopPolling() }
        if panel.isVisible && tab == .memes { memes.search = ""; memes.load(); NSApp.activate(ignoringOtherApps: true) }
        if panel.isVisible && tab == .clipboard { clipboard.search = ""; NSApp.activate(ignoringOtherApps: true) }
    }

    func toggle(tab: Tab) {
        if panel.isVisible && state.tab == tab {
            hide()
        } else {
            state.tab = tab
            show()
        }
    }

    // CADisplayLink-driven animation state (vsync-synced; time-based so it's
    // smooth at any refresh rate — 60/100/120 Hz alike).
    private var animLink: CADisplayLink?
    private var animFrom: NSPoint = .zero
    private var animTo: NSPoint = .zero
    private var animStartT: CFTimeInterval = 0
    private var animDur: Double = 0.001
    private var animCurve: ((Double) -> Double)?
    private var animDone: (() -> Void)?

    // Bounce: drops past the resting spot, then settles back up.
    private static func easeOutBack(_ p: Double) -> Double {
        let s = 1.5
        let q = p - 1
        return 1 + (s + 1) * (q * q * q) + s * (q * q)
    }
    private static func easeInQuad(_ p: Double) -> Double { p * p }

    // Vsync-synced animation: a CADisplayLink bound to the panel's screen drives
    // frames at the display's native rate; progress is time-based so duration is
    // honored regardless of refresh rate.
    private func animateOrigin(to target: NSPoint, duration: Double,
                               curve: @escaping (Double) -> Double, then: (() -> Void)? = nil) {
        animLink?.invalidate()
        animFrom = panel.frame.origin
        animTo = target
        animDur = max(0.001, duration)
        animStartT = CACurrentMediaTime()
        animCurve = curve
        animDone = then
        let view = panel.contentView ?? NSView()
        let link = view.displayLink(target: self, selector: #selector(stepAnim))
        link.add(to: .main, forMode: .common)   // keep firing during event tracking
        animLink = link
    }

    @objc private func stepAnim() {
        let p = min(1.0, (CACurrentMediaTime() - animStartT) / animDur)
        let e = animCurve?(p) ?? p
        panel.setFrameOrigin(NSPoint(x: animFrom.x + (animTo.x - animFrom.x) * e,
                                     y: animFrom.y + (animTo.y - animFrom.y) * e))
        if p >= 1.0 {
            animLink?.invalidate(); animLink = nil
            let done = animDone; animDone = nil
            done?()
        }
    }

    private func show() {
        let final = topRightOrigin()
        panel.alphaValue = 1
        panel.setFrameOrigin(NSPoint(x: final.x, y: final.y + size.height))   // start fully above
        panel.makeKeyAndOrderFront(nil)
        if state.tab == .memes || state.tab == .clipboard { NSApp.activate(ignoringOtherApps: true) }   // text fields need the app active for keyboard focus
        animateOrigin(to: final, duration: 0.34, curve: Self.easeOutBack)
        installMonitors()
        updatePolling(forTab: state.tab)
    }

    private func hide() {
        removeMonitors()
        stopAllPolling()
        if NSApp.isActive { previousApp?.activate() }   // hand focus back to the app you came from
        let final = topRightOrigin()
        animateOrigin(to: NSPoint(x: final.x, y: final.y + size.height),
                      duration: 0.16, curve: Self.easeInQuad) { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            self.panel.setFrameOrigin(final)   // reset for next open
        }
    }

    private func stopAllPolling() {
        nowPlaying.stopPolling()
        power.stopPolling()
        unifi.stopPolling()
        vpn.stopPolling()
        ha.stopPolling()
        pi.stopPolling()
    }

    private func topRightOrigin() -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let vf = screen.visibleFrame
        let gap: CGFloat = 8
        return NSPoint(x: vf.midX - size.width / 2,
                       y: vf.maxY - size.height - gap)
    }

    private func installMonitors() {
        removeMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {                                            // Esc
                if self.state.tab == .memes, self.memes.editingMeme != nil { self.memes.editingMeme = nil; return nil }
                self.hide(); return nil
            }
            if self.state.tab == .memes, self.memes.editingMeme == nil,
               event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v",
               self.memes.clipboardHasImage {
                self.memes.addFromClipboard(); return nil                       // ⌘V adds the clipboard image as a meme
            }
            if self.state.tab == .clipboard {                                   // ↑/↓ move the clipboard selection
                if event.keyCode == 126 { self.clipboard.move(-1); return nil }
                if event.keyCode == 125 { self.clipboard.move(1);  return nil }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor   { NSEvent.removeMonitor(m); keyMonitor = nil }
    }
}

// MARK: - Quake terminal controller (replaces Hammerspoon's Ctrl+' toggle)
//
// Toggles a drop-down kitty window titled "quake-terminal" via the Accessibility
// API. The quake kitty runs as its OWN process (kitty --instance-group quake), so
// hiding "its" app doesn't disturb the main kitty. Triggered by kajo://quake.

final class QuakeController {
    static let shared = QuakeController()

    private let quakeTitle = "quake-terminal"
    private let launcher = NSHomeDirectory() + "/.config/kitty/kitty-quake"
    private let topGap: CGFloat = 40          // clear SketchyBar so it stays visible
    private var refocusWork: [DispatchWorkItem] = []
    private var quakePID: pid_t?              // the one kitty process we manage (stable for its lifetime)
    private var isShown = false               // OUR authoritative state — we're the sole controller

    func toggle() {
        guard ensureTrusted() else { qlog("NOT TRUSTED"); return }  // first run prompts for Accessibility
        guard let app = quakeApp() else {
            qlog("branch=LAUNCH (no live quake process)"); isShown = true; launch(); discoverPIDThenShow(); return
        }
        if isShown {
            qlog("branch=HIDE (pid \(app.processIdentifier))")
            app.hide(); isShown = false
        } else {
            qlog("branch=SHOW (pid \(app.processIdentifier))")
            if let win = quakeWindow(of: app) {
                show(app: app, win: win)
            } else {
                launch(); discoverPIDThenShow()   // window was closed; recreate
            }
            isShown = true
        }
    }

    // Resolve the kitty process we manage, by tracked PID; rediscover via the
    // /tmp/mykitty-quake-<PID> socket the launcher creates if our PID is stale.
    private func quakeApp() -> NSRunningApplication? {
        if let pid = quakePID, let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            return app
        }
        if let pid = discoverQuakePID(), let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
            quakePID = pid; return app
        }
        quakePID = nil; return nil
    }

    private func discoverQuakePID() -> pid_t? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: "/tmp") else { return nil }
        for f in files where f.hasPrefix("mykitty-quake-") {
            if let pid = pid_t(f.dropFirst("mykitty-quake-".count)),
               let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated {
                return pid
            }
        }
        return nil
    }

    private func discoverPIDThenShow() {
        for delay in [0.5, 1.0, 1.5, 2.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let app = self.quakeApp(), let win = self.quakeWindow(of: app) else { return }
                self.show(app: app, win: win); self.isShown = true
            }
        }
    }

    private func qlog(_ s: String) {
        let line = "[\(Date())] \(s)\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/kajo-quake.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else { try? line.write(toFile: "/tmp/kajo-quake.log", atomically: true, encoding: .utf8) }
    }

    // MARK: trust
    @discardableResult
    private func ensureTrusted() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: discovery — the kitty *process* that owns the quake window
    private func quakeWindow(of app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { axString($0, kAXTitleAttribute) == quakeTitle }
    }

    // MARK: show / position / focus
    private func show(app: NSRunningApplication, win: AXUIElement) {
        if app.isHidden { app.unhide() }
        AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        position(win)
        app.activate()
        raiseFocus(win)
        armRefocusGuard(app: app, win: win)
    }

    private func position(_ win: AXUIElement) {
        let screen = activeScreen()
        let vf = screen.visibleFrame                       // excludes menu bar / dock
        let width = vf.width * 0.8
        let height = vf.height * 0.5
        let x = vf.minX + (vf.width - width) / 2
        let cocoaTop = vf.maxY - topGap                    // window top edge (Cocoa, bottom-left origin)
        // AX uses a top-left global origin anchored on the primary display → flip Y.
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen).frame.height
        var pos = CGPoint(x: x, y: primaryHeight - cocoaTop)
        var size = CGSize(width: width, height: height)
        if let p = AXValueCreate(.cgPoint, &pos) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
        }
        if let s = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        }
    }

    private func raiseFocus(_ win: AXUIElement) {
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(win, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    // Port of Hammerspoon's focus-guard: macOS Tahoe hands focus back to a "main"
    // kitty window 0.06–1.5s after toggle-on, so re-assert focus across that window.
    private func armRefocusGuard(app: NSRunningApplication, win: AXUIElement) {
        refocusWork.forEach { $0.cancel() }; refocusWork.removeAll()
        for delay in [0.06, 0.15, 0.30, 0.6, 1.0, 1.5] {
            let work = DispatchWorkItem { [weak self] in
                app.activate()
                self?.raiseFocus(win)
            }
            refocusWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    // MARK: launch (cold start / warm relaunch handled by the script), then show
    private func launch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", launcher]
        try? p.run()
    }

    // MARK: AX helpers
    private func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }
    private func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
}

// MARK: - App delegate (URL scheme entry point)

final class AppDelegate: NSObject, NSApplicationDelegate, CBCentralManagerDelegate {
    let controller = PanelController()
    private var btManager: CBCentralManager?
    private let locationManager = CLLocationManager()
    private var statusItem: NSStatusItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Instantiating a central manager triggers the Bluetooth permission
        // prompt, so blueutil (spawned by us) is allowed to enumerate devices.
        btManager = CBCentralManager(delegate: self, queue: nil)
        // Location authorization is required by macOS to scan for Wi-Fi networks.
        locationManager.requestWhenInUseAuthorization()
        setupMenuBar()
    }

    // Optional menu-bar icon (config "menuBarIcon", default on) → makes Kajo
    // summonable without sketchybar/Raycast, the main shareability blocker.
    private func setupMenuBar() {
        guard menuBarEnabled else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "square.grid.2x2.fill", accessibilityDescription: "Kajo")
        let menu = NSMenu()
        for tab in Tab.allCases where enabledModules.contains(tab) {
            let mi = NSMenuItem(title: tab.title, action: #selector(openTab(_:)), keyEquivalent: "")
            mi.representedObject = tab; mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kajo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        controller.toggle(tab: tab)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    @objc func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let str = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: str) else { return }
        handle(url)
    }

    private func handle(_ url: URL) {
        // Headless clipboard actions (no panel shown): kajo://clip/prev, kajo://clip/clean
        if url.host == "clip" {
            switch url.pathComponents.last ?? "" {
            case "prev":  controller.clipboard.copyPrevious()
            case "clean": controller.clipboard.cleanClipboardURL()
            default: break
            }
            return
        }
        if url.host == "hide" {   // kajo://hide — close the panel (e.g. from Hammerspoon Hyper+V)
            NotificationCenter.default.post(name: .kajoDismiss, object: nil)
            return
        }
        // Accept both  kajo://tab/calendar  and  kajo://calendar
        let raw = (url.host == "tab" ? url.pathComponents.last : url.host) ?? ""
        let name = raw.lowercased()
        try? "\(name)\n".append(toFile: "/tmp/kajo.log")
        // Quake terminal ON HOLD — Hammerspoon (Ctrl+') handles it for now. QuakeController
        // is kept dormant; re-enable by uncommenting the two lines below.
        // if name == "quake" { QuakeController.shared.toggle(); return }
        if let tab = Tab(rawValue: name) {
            controller.toggle(tab: tab)
        } else {
            controller.toggle(tab: controller.state.tab)
        }
    }
}

// Tiny debug helper so we can verify the URL pipeline without seeing the UI.
private extension String {
    func append(toFile path: String) throws {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Bootstrap

// Self-check / scripting: `Kajo --clean-url <url>` prints the cleaned URL and exits.
if let i = CommandLine.arguments.firstIndex(of: "--clean-url"), i + 1 < CommandLine.arguments.count {
    print(cleanedURL(CommandLine.arguments[i + 1]) ?? CommandLine.arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

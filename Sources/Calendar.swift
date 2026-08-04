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
let calendarCfg: [String: Any] = {
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

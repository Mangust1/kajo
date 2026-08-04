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

// MARK: - Tabs

enum Tab: String, CaseIterable, Identifiable {
    case calendar, timer, music, sound, power, network, unifi, vpn, home, pi, ai, system, currency, memes, clipboard

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
        case .currency: return "Currency"
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
        case .currency: return "dollarsign.arrow.circlepath"
        }
    }
}

// config.json (optional): { "enabledModules": ["calendar",…], "menuBarIcon": true }
// "enabledModules" uses the same names as kajo://tab/<name>.
let appConfig: [String: Any] = {
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

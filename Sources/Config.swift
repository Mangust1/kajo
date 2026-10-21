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
    case calendar, timer, music, sound, power, network, unifi, vpn, home, pi, ai, system, currency, memes, clipboard, hours

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
        case .hours:    return "Hours"
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
        case .hours:    return "clock.badge.checkmark"
        }
    }
}

// config.json (optional): { "enabledModules": ["calendar",…], "menuBarIcon": true, "notchHover": true, "islandEars": true }
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
// Hovering the notch (or the top-centre strip on a notchless screen) peeks a row of tab icons;
// "notchHover": false keeps the panel to explicit summons only.
let notchHover = (appConfig["notchHover"] as? Bool) ?? true
// Live hours + now-playing "ears" flanking the notch on the collapsed island (notched screens only).
let islandEars = (appConfig["islandEars"] as? Bool) ?? true
// Scratch notepad: "scratchFontSize": 13 and "scratchSize": [1300, 660] (points; the default size,
// a hand resize is remembered separately and the reset button returns to this).
let scratchFontSize = CGFloat((appConfig["scratchFontSize"] as? Double) ?? 13)
let scratchSize: NSSize = {
    if let a = appConfig["scratchSize"] as? [Double], a.count == 2, a[0] > 0, a[1] > 0 { return NSSize(width: a[0], height: a[1]) }
    return NSSize(width: 1300, height: 660)
}()

// Network tab travel-router row: "berylSSID" is the router's own Wi-Fi ("" = row hidden),
// "berylScript" the join + captive-portal helper it runs (tilde-expanded).
let berylSSID = (appConfig["berylSSID"] as? String) ?? ""
let berylScript = NSString(string: (appConfig["berylScript"] as? String) ?? "~/Oma/claude/travel/beryl-up.sh").expandingTildeInPath

// Now Playing source: "spotify" (Spotify.app via AppleScript + its notification, default) or "spotifyd"
// (headless Connect player: now playing from the hook-written spotifyd-state.json, controls via the
// Spotify Web API with the PKCE app "spotifyClientID", aimed at the Connect device "spotifyDevice").
let musicSource = ((appConfig["musicSource"] as? String) ?? "spotify").lowercased()
let spotifyClientID = ((appConfig["spotifyClientID"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
let spotifyDevice = (appConfig["spotifyDevice"] as? String) ?? "MacBook"

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

// MARK: - Shared plumbing (one copy — every tab used to carry its own)

/// Run a CLI and return its stdout, nil if it couldn't launch. Drains the pipe
/// BEFORE waiting for exit: waiting first deadlocks once output exceeds the 64 KB
/// pipe buffer (e.g. `tailscale status --json` on a big tailnet).
func shell(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8)
}

/// `~/.config/kajo/<name>` parsed as a JSON object; [:] when missing or invalid.
func loadConfigJSON(_ name: String) -> [String: Any] {
    guard let d = try? Data(contentsOf: URL(fileURLWithPath: kajoConfigDir + "/" + name)),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return j
}

/// Write atomically (a crash mid-write can't truncate the file) and owner-only.
/// Used for anything holding customer names, clipboard text or credentials.
func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

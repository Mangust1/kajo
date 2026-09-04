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

// "Not configured" / "unreachable" placeholder used by the Pi, Home and UniFi tabs.
func hint(_ title: String, _ sub: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline).foregroundStyle(Gruv.fg2)
        Text(sub).font(.callout).foregroundStyle(Gruv.gray)
    }.padding(.top, 8)
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

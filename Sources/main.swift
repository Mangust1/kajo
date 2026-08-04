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

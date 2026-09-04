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
        // Only ask for what the enabled tabs need — a fresh install shouldn't get three prompts.
        // Instantiating a central manager triggers the Bluetooth permission
        // prompt, so blueutil (spawned by us) is allowed to enumerate devices.
        if enabledModules.contains(.sound) { btManager = CBCentralManager(delegate: self, queue: nil) }
        // Location authorization is required by macOS to scan for Wi-Fi networks (and for weather).
        if enabledModules.contains(.network) || enabledModules.contains(.calendar) {
            locationManager.requestWhenInUseAuthorization()
        }
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
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Kajo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openTab(_ sender: NSMenuItem) {
        guard let tab = sender.representedObject as? Tab else { return }
        controller.toggle(tab: tab)
    }

    @objc private func openSettings() { ConfigWindowController.shared.show() }

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
        if url.host == "config" {   // kajo://config — the Settings window
            NotificationCenter.default.post(name: .kajoDismiss, object: nil)
            ConfigWindowController.shared.show()
            return
        }
        // Accept both  kajo://tab/calendar  and  kajo://calendar
        let raw = (url.host == "tab" ? url.pathComponents.last : url.host) ?? ""
        let name = raw.lowercased()
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
extension String {
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

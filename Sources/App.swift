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
        installEditMenu()
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

    /// Agent apps have no menu bar, so ⌘C/⌘V/⌘X/⌘A never reach the responder chain unless an
    /// Edit menu declares the key equivalents. Needed by the terminal window (paste, incl.
    /// clipboard images) and it also fixes paste into the panel's text fields.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

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
        // kajo://terminal — quake-style drop-down terminal pinned to one Space (Terminal.swift);
        // kajo://terminal/repin — re-place it on the current Space/screen.
        if url.host == "terminal" {
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func flag(_ n: String) -> Bool { ["1", "true", "yes"].contains((q.first { $0.name == n }?.value ?? "").lowercased()) }
            switch url.pathComponents.last {
            case "repin": TerminalWindowController.shared.repin()
            case "send":  // kajo://terminal/send?text=…&enter=1&show=1
                if let text = q.first(where: { $0.name == "text" })?.value {
                    TerminalWindowController.shared.send(text: text, enter: flag("enter"), show: flag("show"))
                }
            case "paste": // kajo://terminal/paste[?enter=1&show=1] — clipboard text into the prompt
                if let text = NSPasteboard.general.string(forType: .string) {
                    TerminalWindowController.shared.send(text: text, enter: flag("enter"), show: flag("show"))
                }
            default: TerminalWindowController.shared.toggle()
            }
            return
        }
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

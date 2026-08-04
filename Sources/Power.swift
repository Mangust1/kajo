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

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

struct BTBattery: Equatable {
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var main: Int?
    var isEmpty: Bool { left == nil && right == nil && caseLevel == nil && main == nil }
    var label: String {
        if left != nil || right != nil || caseLevel != nil {
            var parts: [String] = []
            if let l = left { parts.append("L \(l)%") }
            if let r = right { parts.append("R \(r)%") }
            if let c = caseLevel { parts.append("Case \(c)%") }
            return parts.joined(separator: "  ")
        }
        if let m = main { return "\(m)%" }
        return ""
    }
}

struct BTDevice: Identifiable, Equatable {
    let id: String   // MAC address
    let name: String
    var connected: Bool
    var battery: BTBattery? = nil
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

            // Battery via system_profiler (~1s) — fetched after devices show, then merged in.
            let batteries = self.batteryLevels()
            DispatchQueue.main.async {
                for i in self.devices.indices {
                    self.devices[i].battery = batteries[Self.normAddr(self.devices[i].id)]
                }
            }
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

    // Strip separators so IOBluetooth's "28-2d-…" matches system_profiler's "28:2D:…".
    private static func normAddr(_ s: String) -> String {
        s.lowercased().filter(\.isHexDigit)
    }

    // Parse per-device battery levels from `system_profiler SPBluetoothDataType -json`.
    private func batteryLevels() -> [String: BTBattery] {
        guard let out = run(["/usr/sbin/system_profiler", "SPBluetoothDataType", "-json"]),
              let data = out.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]],
              let connected = arr.first?["device_connected"] as? [[String: Any]]
        else { return [:] }
        func pct(_ v: Any?) -> Int? {
            guard let s = v as? String else { return nil }
            return Int(s.replacingOccurrences(of: "%", with: "")
                        .trimmingCharacters(in: .whitespaces))
        }
        var map: [String: BTBattery] = [:]
        for entry in connected {
            for (_, val) in entry {
                guard let p = val as? [String: Any],
                      let addr = p["device_address"] as? String else { continue }
                var b = BTBattery()
                b.left = pct(p["device_batteryLevelLeft"])
                b.right = pct(p["device_batteryLevelRight"])
                b.caseLevel = pct(p["device_batteryLevelCase"])
                b.main = pct(p["device_batteryLevelMain"])
                if !b.isEmpty { map[Self.normAddr(addr)] = b }
            }
        }
        return map
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
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.name).foregroundStyle(Gruv.fg1).lineLimit(1)
                                    if d.connected, let b = d.battery, !b.isEmpty {
                                        Text(b.label)
                                            .font(.caption2)
                                            .foregroundStyle(Gruv.fg4)
                                    }
                                }
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

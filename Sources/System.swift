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

final class SystemModel: ObservableObject {
    @Published var keepAwake = false                 // caffeinate running (timed OR indefinite)
    @Published private(set) var remaining: String?   // "1h 23m" while timed; nil = indefinite/off
    @Published private(set) var activeMinutes: Int?  // which preset is running (nil = indefinite/off)

    private var caffeinate: Process?
    private var endDate: Date?
    private var ticker: Timer?
    private var autoOff: DispatchWorkItem?

    // Duration presets shown as chips. nil label handled separately (indefinite = the toggle).
    static let presets: [(label: String, minutes: Int)] =
        [("15m", 15), ("30m", 30), ("1h", 60), ("2h", 120), ("4h", 240)]

    // Indefinite on/off — the original toggle behavior.
    func toggleKeepAwake() {
        if keepAwake { stop() } else { start(minutes: nil) }
    }

    // Timed keep-awake: auto-off after `minutes`, with a live countdown.
    func keepAwake(forMinutes minutes: Int) { start(minutes: minutes) }

    private func start(minutes: Int?) {
        stop()                                       // clean slate — restart caffeinate + timers
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // -w <own pid>: caffeinate auto-exits when Kajo does (quit/reinstall/crash/SIGKILL) so it
        // can never orphan and block sleep. The Swift auto-off below handles the timed duration.
        p.arguments = ["-d", "-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        try? p.run()
        caffeinate = p
        keepAwake = true
        activeMinutes = minutes
        if let minutes {
            endDate = Date().addingTimeInterval(Double(minutes) * 60)
            let work = DispatchWorkItem { [weak self] in self?.stop() }
            autoOff = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(minutes) * 60, execute: work)
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            tick()
        } else {
            endDate = nil; remaining = nil
        }
    }

    func stop() {
        autoOff?.cancel(); autoOff = nil
        ticker?.invalidate(); ticker = nil
        caffeinate?.terminate(); caffeinate = nil
        endDate = nil; remaining = nil; activeMinutes = nil
        keepAwake = false
    }

    private func tick() {
        guard let end = endDate else { remaining = nil; return }
        let secs = Int(end.timeIntervalSinceNow.rounded())
        if secs <= 0 { stop(); return }
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        remaining = h > 0 ? String(format: "%dh %02dm", h, m) : String(format: "%dm %02ds", m, s)
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

    private var statusText: String {
        if let r = model.remaining { return "\(r) left" }
        return model.keepAwake ? "Mac won't sleep" : "Normal sleep"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: model.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 17)).frame(width: 22)
                    .foregroundStyle(model.keepAwake ? Gruv.aqua : Gruv.fg4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Awake").foregroundStyle(Gruv.fg1)
                    Text(statusText)
                        .font(.caption).foregroundStyle(model.remaining != nil ? Gruv.aqua : Gruv.gray)
                        .monospacedDigit()
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.keepAwake }, set: { _ in model.toggleKeepAwake() }))
                    .labelsHidden().toggleStyle(.switch).tint(Gruv.green)
            }

            // Timed presets — start a keep-awake that auto-releases. Tapping the running
            // one (or the toggle) turns it off.
            HStack(spacing: 6) {
                ForEach(SystemModel.presets, id: \.minutes) { preset in
                    let active = model.activeMinutes == preset.minutes
                    Button {
                        if active { model.stop() } else { model.keepAwake(forMinutes: preset.minutes) }
                    } label: {
                        Text(preset.label)
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(active ? Gruv.aqua.opacity(0.22) : Gruv.bg1.opacity(0.5)))
                            .foregroundStyle(active ? Gruv.aqua : Gruv.fg2)
                    }
                    .buttonStyle(.plain)
                }
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

            // Pinned to the bottom edge — opens the external Settings window (config editor).
            Button {
                NotificationCenter.default.post(name: .kajoDismiss, object: nil)   // close the panel first
                ConfigWindowController.shared.show()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape").font(.system(size: 14))
                    Text("Settings")
                    Spacer()
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 12))
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(Gruv.aqua)
                .padding(.vertical, 9).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Gruv.aqua.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
    }
}

func placeholderRow(_ text: String) -> some View {
    HStack {
        Circle().fill(Gruv.gray.opacity(0.6)).frame(width: 6, height: 6)
        Text(text).font(.callout).foregroundStyle(Gruv.gray)
    }
}

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
    @Published var keepAwake = false
    private var caffeinate: Process?

    func toggleKeepAwake() {
        keepAwake.toggle()
        if keepAwake {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            // -w <own pid>: caffeinate auto-exits when Kajo does (quit/reinstall/crash/SIGKILL),
            // so it can never orphan and block sleep across app lifetimes. terminate() below
            // still handles the normal in-session toggle-off.
            p.arguments = ["-d", "-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
            try? p.run()
            caffeinate = p
        } else {
            caffeinate?.terminate()
            caffeinate = nil
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: model.keepAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.system(size: 17)).frame(width: 22)
                    .foregroundStyle(model.keepAwake ? Gruv.aqua : Gruv.fg4)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Awake").foregroundStyle(Gruv.fg1)
                    Text(model.keepAwake ? "Mac won't sleep" : "Normal sleep")
                        .font(.caption).foregroundStyle(Gruv.gray)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.keepAwake }, set: { _ in model.toggleKeepAwake() }))
                    .labelsHidden().toggleStyle(.switch).tint(Gruv.green)
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

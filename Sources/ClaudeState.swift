import SwiftUI

// Claude Code session state for the island's left ear (replaces SketchyBar's claude_group).
// The Claude Code hook writes one word per instance into <kajoConfigDir>/claude-state/<who>
// (who = personal | work | renta) via tmp + mv, so every update is a create/rename in the
// directory and a directory .write watch sees it. (An in-place `echo > file` would not fire.)

enum ClaudeState: String {
    case busy, done, attention, idle

    var color: Color {
        switch self {
        case .busy:      return Gruv.yellow
        case .done:      return Gruv.green
        case .attention: return Gruv.orange
        case .idle:      return Gruv.gray
        }
    }
}

final class ClaudeStateModel: ObservableObject {
    @Published var personal: ClaudeState = .idle
    @Published var work: ClaudeState = .idle
    @Published var renta: ClaudeState = .idle

    var active: Bool { personal != .idle || work != .idle || renta != .idle }

    private let dir = kajoConfigDir + "/claude-state/"
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        reload()
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in self?.scheduleReload() }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        // Shortcut: if the directory itself is deleted/replaced the watch goes stale until relaunch;
        // upgrade path is adding .delete/.rename to the mask and re-opening the fd.
    }

    deinit { source?.cancel() }

    /// A tmp + mv fires twice (create, rename): coalesce into one read 50 ms later.
    private func scheduleReload() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reload() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
    }

    private func read(_ who: String) -> ClaudeState {
        let s = (try? String(contentsOfFile: dir + who, encoding: .utf8)) ?? ""
        return ClaudeState(rawValue: s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .idle
    }

    private func reload() {
        let p = read("personal"), w = read("work"), r = read("renta")
        withAnimation(.easeOut(duration: 0.2)) {
            if personal != p { personal = p }
            if work != w { work = w }
            if renta != r { renta = r }
        }
    }
}

/// `[ ▍ ✱ ▍ ]` like the SketchyBar box: left bar = personal, right bar = work, underline = renta.
struct ClaudeGlyph: View {
    @ObservedObject var model: ClaudeStateModel

    var body: some View {
        HStack(spacing: 4) {
            Capsule().fill(model.personal.color).frame(width: 3, height: 16)
            VStack(spacing: 2) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Capsule().fill(model.renta.color).frame(width: 14, height: 3)
            }
            Capsule().fill(model.work.color).frame(width: 3, height: 16)
        }
        .animation(.easeOut(duration: 0.2), value: [model.personal, model.work, model.renta])
    }
}

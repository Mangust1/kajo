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

// MARK: - URL cleaner (kajo://clip/clean, Hyper+U)
//
// Strips tracking params from an http(s) URL string; returns nil if the input
// isn't one. ponytail: param blocklist + an Amazon special case covers ~95% of
// real links; add per-host rules here as they annoy in practice (ClearURLs-style
// rule engine is the upgrade path if this list ever feels unmaintainable).
func cleanedURL(_ raw: String) -> String? {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var comps = URLComponents(string: s), let host = comps.host?.lowercased(),
          comps.scheme == "http" || comps.scheme == "https" else { return nil }

    // Amazon: everything but /dp/ASIN is noise (300 chars → 30).
    if host.contains("amazon.") {
        let parts = comps.path.split(separator: "/").map(String.init)
        for (i, p) in parts.enumerated() where (p == "dp" || p == "product") && i + 1 < parts.count {
            let asin = parts[i + 1]
            if asin.count == 10, asin.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return "https://\(host)/dp/\(asin)"
            }
        }
    }

    let junkPrefixes = ["utm_", "pk_", "mc_", "vero_", "oly_", "fb_", "hsa_", "matomo_", "piwik_", "gad_"]
    let junk: Set<String> = ["fbclid", "gclid", "gclsrc", "dclid", "msclkid", "yclid", "twclid",
                             "ttclid", "igsh", "igshid", "srsltid", "spm", "sk", "_hsenc", "_hsmi",
                             "wt_mc", "cmpid", "ncid", "li_fat_id", "ref", "ref_src", "ref_url",
                             "soc_src", "soc_trk", "wickedid", "sms_source", "gbraid", "wbraid"]
    // Pure share-tracking on these hosts, but meaningful elsewhere — keep host-scoped.
    var hostJunk: Set<String> = []
    if host.contains("youtube.com") || host == "youtu.be" { hostJunk = ["si", "feature", "pp", "start_radio"] }
    else if host.contains("spotify.com") { hostJunk = ["si"] }
    else if host == "x.com" || host.contains("twitter.com") { hostJunk = ["s", "t"] }
    // Booking.com: session/affiliate + search-results tracking. Keeps checkin/checkout/party size.
    else if host.contains("booking.com") {
        hostJunk = ["sid", "aid", "label", "ucfs", "sr_order", "srpvid", "srepoch",
                    "matching_block_id", "atlas_src", "highlighted_blocks",
                    "dest_id", "dest_type"]
    }
    // Threads: Meta share-tracking token + share-log flag. Post ID in the path is all that's needed.
    else if host.contains("threads.com") || host.contains("threads.net") { hostJunk = ["xmt", "slof"] }
    // Goodreads: search/referral context on /book/show/ links. The path (ID.Title) is the whole link.
    else if host.contains("goodreads.com") { hostJunk = ["from_search", "from_srp", "qid", "rank", "ac", "from_choice"] }

    // percentEncodedQueryItems (not queryItems) so kept values stay byte-identical.
    let kept = (comps.percentEncodedQueryItems ?? []).filter { item in
        let n = item.name.lowercased()
        // ponytail: list=RD… is an auto-generated radio mix, not a saved playlist — drop it
        if n == "list", (item.value ?? "").hasPrefix("RD"),
           host.contains("youtube.com") || host == "youtu.be" { return false }
        return !junk.contains(n) && !hostJunk.contains(n)
            && !junkPrefixes.contains { n.hasPrefix($0) }
    }
    comps.percentEncodedQueryItems = kept.isEmpty ? nil : kept
    return comps.string
}

// Tiny transient HUD — feedback for headless kajo:// actions (no panel shown).
func showHUD(_ text: String) {
    let label = NSTextField(labelWithString: text)
    label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
    label.textColor = NSColor(red: 0.92, green: 0.86, blue: 0.70, alpha: 1)   // gruvbox fg
    label.sizeToFit()
    let pad: CGFloat = 14
    let size = NSSize(width: label.frame.width + pad * 2, height: label.frame.height + pad)
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .transient]
    let bg = NSView(frame: NSRect(origin: .zero, size: size))
    bg.wantsLayer = true
    bg.layer?.backgroundColor = NSColor(red: 0.157, green: 0.157, blue: 0.157, alpha: 0.95).cgColor
    bg.layer?.cornerRadius = 9
    label.frame.origin = NSPoint(x: pad, y: pad / 2)
    bg.addSubview(label)
    panel.contentView = bg
    if let screen = NSScreen.main {
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 60))
    }
    panel.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }
}

// MARK: - Clipboard tab (replaces Maccy + Hammerspoon Hyper+V)
//
// App-lifetime clipboard monitor: polls NSPasteboard.changeCount every 0.5s (the
// only way — macOS has no clipboard-change event). Text + image history, newest
// first, capped at 100 (non-secret). Concealed copies (1Password passwords, marked
// org.nspasteboard.ConcealedType) go to an in-memory "secret" lane with a 20s TTL —
// pasteable briefly, never written to disk. Select → copies back (you paste).
// Text items also have a → vim action (nvr), porting Hammerspoon's Hyper+V.

struct ClipItem: Identifiable, Codable {
    enum Kind: String, Codable { case text, image }
    var id = UUID()
    var kind: Kind
    var text: String?
    var file: String?            // image filename in files/
    var added = Date()
    var secret = false           // concealed → ephemeral, RAM-only
    var expiresAt: Date?         // set for secret items
}

final class ClipboardModel: ObservableObject {
    @Published var items: [ClipItem] = []
    @Published var search = "" { didSet { sel = 0 } }
    @Published var sel = 0          // ↑/↓ highlighted index into `filtered`

    private let filesDir: URL
    private let indexURL: URL
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let cap: Int
    private let secretTTL: TimeInterval
    private let maxImageBytes: Int
    private let nvrPath: String
    private let nvimSocket: String
    private let kdeconnectCli: String
    private let kdeconnectDevice: String

    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let gifType   = NSPasteboard.PasteboardType("com.compuserve.gif")
    private static let imgExts: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic"]

    init() {
        let base = URL(fileURLWithPath: kajoConfigDir).appendingPathComponent("clipboard")
        filesDir = base.appendingPathComponent("files")
        indexURL = base.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
        // clipboard.json (optional): historyCap, secretTTLSeconds, maxImageMB, nvrPath, nvimSocket, kdeconnectCli, kdeconnectDeviceId
        let cfg = (try? Data(contentsOf: URL(fileURLWithPath: kajoConfigDir + "/clipboard.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        cap = (cfg["historyCap"] as? Int) ?? 100
        secretTTL = (cfg["secretTTLSeconds"] as? Double) ?? 20
        maxImageBytes = ((cfg["maxImageMB"] as? Int) ?? 5) * 1024 * 1024
        nvrPath = ((cfg["nvrPath"] as? String).map { ($0 as NSString).expandingTildeInPath }) ?? (NSHomeDirectory() + "/Library/Python/3.14/bin/nvr")
        nvimSocket = (cfg["nvimSocket"] as? String) ?? "/tmp/nvimsocket2"
        kdeconnectCli = (cfg["kdeconnectCli"] as? String) ?? "/Applications/KDE Connect.app/Contents/MacOS/kdeconnect-cli"
        kdeconnectDevice = (cfg["kdeconnectDeviceId"] as? String) ?? ""  // ponytail: empty = first available device
        load()
    }

    func fileURL(_ name: String) -> URL { filesDir.appendingPathComponent(name) }

    // Runs for the whole app lifetime (NOT tab-scoped) — you copy things all day,
    // then open Kajo to retrieve. Started once from PanelController.init.
    func startMonitoring() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        pruneExpired()
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        capture(pb)
    }

    private func pruneExpired() {
        let now = Date()
        if items.contains(where: { ($0.expiresAt ?? .distantFuture) < now }) {
            items.removeAll { ($0.expiresAt ?? .distantFuture) < now }
        }
    }

    private func capture(_ pb: NSPasteboard) {
        let types = pb.types ?? []
        if types.contains(Self.transient) { return }          // honor the no-store opt-out
        let secret = types.contains(Self.concealed)

        // Image first (passwords are concealed text, never images).
        if let (data, ext) = imageData(pb) {
            guard data.count <= maxImageBytes else { return }
            let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).\(ext)"
            try? data.write(to: fileURL(name))
            insert(ClipItem(kind: .image, file: name))
            return
        }
        if let s = pb.string(forType: .string), !s.isEmpty {
            if s.hasPrefix("kajo://") { return }               // never store our own control URLs
            if items.first?.text == s { return }               // dedup consecutive
            var it = ClipItem(kind: .text, text: s, secret: secret)
            if secret { it.expiresAt = Date().addingTimeInterval(secretTTL) }
            insert(it)
        }
    }

    private func imageData(_ pb: NSPasteboard) -> (Data, String)? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first(where: { Self.imgExts.contains($0.pathExtension.lowercased()) }),
           let d = try? Data(contentsOf: u) { return (d, u.pathExtension.lowercased()) }
        if let gif = pb.data(forType: Self.gifType) { return (gif, "gif") }
        if let png = pb.data(forType: .png) { return (png, "png") }
        if let tiff = pb.data(forType: .tiff) ?? NSImage(pasteboard: pb)?.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { return (png, "png") }
        return nil
    }

    private func insert(_ it: ClipItem) {
        items.insert(it, at: 0)
        var normal = 0
        items = items.filter { item in
            if item.expiresAt != nil { return true }           // secrets self-expire, exempt from cap
            normal += 1
            if normal > cap {
                if item.kind == .image, let f = item.file { try? FileManager.default.removeItem(at: fileURL(f)) }
                return false
            }
            return true
        }
        persist()
    }

    // Write an item to the pasteboard. Suppress re-capture of our own write —
    // critical for secrets, else the plain re-copy would be stored to disk.
    private func writePasteboard(_ it: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch it.kind {
        case .text:
            if let t = it.text { pb.setString(t, forType: .string) }
        case .image:
            if let f = it.file, let data = try? Data(contentsOf: fileURL(f)) {
                let item = NSPasteboardItem()
                if (f as NSString).pathExtension.lowercased() == "gif" { item.setData(data, forType: Self.gifType) }
                else { item.setData(data, forType: .png) }
                if let img = NSImage(data: data), let tiff = img.tiffRepresentation { item.setData(tiff, forType: .tiff) }
                pb.writeObjects([item])
            }
        }
        lastChange = pb.changeCount
    }

    // Copies an item back to the pasteboard (you paste) and floats it to the top,
    // so the list always reflects what's currently on the clipboard.
    func select(_ it: ClipItem) {
        writePasteboard(it)
        if let idx = items.firstIndex(where: { $0.id == it.id }), idx != 0 {
            let moved = items.remove(at: idx)
            items.insert(moved, at: 0)
            persist()
        }
    }

    // Headless (kajo://clip/prev): grab the PREVIOUS item → it becomes current and
    // floats to the top. Press again to swap back. No panel shown.
    func copyPrevious() {
        guard items.count >= 2 else { return }
        select(items[1])
    }

    // Headless (kajo://clip/clean): strip tracking junk off the URL currently on
    // the clipboard. Writes back WITHOUT suppressing capture, so the cleaned URL
    // lands in history as a new item on the monitor's next tick.
    func cleanClipboardURL() {
        let pb = NSPasteboard.general
        guard let s = pb.string(forType: .string), let cleaned = cleanedURL(s) else {
            showHUD("🧹 not a URL"); return
        }
        if cleaned == s.trimmingCharacters(in: .whitespacesAndNewlines) {
            showHUD("🧹 already clean"); return
        }
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
        showHUD("🧹 URL cleaned")
    }

    // Row action: clean a history item's URL and copy the result (captured as a new item).
    func cleanAndCopy(_ it: ClipItem) {
        guard let t = it.text, let cleaned = cleanedURL(t) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(cleaned, forType: .string)
    }

    func delete(_ it: ClipItem) {
        if it.kind == .image, let f = it.file { try? FileManager.default.removeItem(at: fileURL(f)) }
        items.removeAll { $0.id == it.id }
        persist()
    }

    // Text → a new nvim tab (replaces Hammerspoon Hyper+V).
    func pasteToVim(_ it: ClipItem) {
        guard it.kind == .text, let text = it.text else { return }
        let sock = nvimSocket
        guard FileManager.default.fileExists(atPath: sock) else { return }
        let tmp = NSTemporaryDirectory() + "kajo-clip-\(UUID().uuidString.prefix(6)).txt"
        try? text.write(toFile: tmp, atomically: true, encoding: .utf8)
        let nvr = nvrPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "'\(nvr)' --servername '\(sock)' --remote-tab-silent '\(tmp)'"]
        try? p.run()
    }

    // Text → the Android device's clipboard via KDE Connect (copy-style: item also
    // lands on the Mac pasteboard + moves to top, same as clicking it).
    func sendToThor(_ it: ClipItem) {
        guard it.kind == .text, !it.secret else { return }
        select(it)
        guard FileManager.default.fileExists(atPath: kdeconnectCli) else { return }
        let dev = kdeconnectDevice.isEmpty
            ? "$('\(kdeconnectCli)' --list-available --id-only | head -n1)"
            : "'\(kdeconnectDevice)'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", "'\(kdeconnectCli)' -d \(dev) --send-clipboard"]
        try? p.run()
    }

    // Persist NON-secret items only — secrets never touch disk.
    private func persist() {
        let durable = items.filter { $0.expiresAt == nil && !$0.secret }
        if let data = try? JSONEncoder().encode(durable) { try? data.write(to: indexURL) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let arr = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        items = arr.filter { it in
            if it.kind == .image, let f = it.file { return FileManager.default.fileExists(atPath: fileURL(f).path) }
            return it.text != nil
        }
    }

    // While querying, hide images and fuzzy-rank text matches.
    var filtered: [ClipItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return items }
        return items.filter { $0.kind == .text }
            .compactMap { it -> (ClipItem, Int)? in
                guard let t = it.text, let s = memeFuzzy(q, t) else { return nil }
                return (it, s)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    var selectedItem: ClipItem? {
        let f = filtered
        return f.indices.contains(sel) ? f[sel] : f.first
    }
    func move(_ d: Int) {
        let n = filtered.count
        guard n > 0 else { return }
        sel = max(0, min(n - 1, sel + d))
    }
}

struct ClipboardTab: View {
    @ObservedObject var model: ClipboardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Gruv.fg4)
                FocusedTextField(text: $model.search, placeholder: "Search clipboard…",
                                 onSubmit: { if let it = model.selectedItem { pick(it) } })
                Text("\(model.filtered.count)").font(.caption2).foregroundStyle(Gruv.gray)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.bg1.opacity(0.6)))
            .onAppear { model.sel = 0 }

            if model.filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard").font(.title2).foregroundStyle(Gruv.fg4)
                    Text(model.items.isEmpty ? "Copy something — it shows up here" : "No match")
                        .font(.caption).foregroundStyle(Gruv.gray)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.filtered) { row($0) }
                        }.padding(.vertical, 2)
                    }
                    .onChange(of: model.sel) { _, _ in
                        if let id = model.selectedItem?.id {
                            withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ it: ClipItem) -> some View {
        HStack(spacing: 8) {
            if it.kind == .image, let f = it.file {
                MemeThumb(url: model.fileURL(f))
                    .frame(width: 54, height: 38)
                    .background(Color.black.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Spacer(minLength: 0)
            } else {
                Image(systemName: it.secret ? "lock.fill" : "text.alignleft")
                    .font(.caption).frame(width: 18)
                    .foregroundStyle(it.secret ? Gruv.yellow : Gruv.fg4)
                Text(preview(it))
                    .font(.system(size: 12, design: it.secret ? .default : .monospaced))
                    .foregroundStyle(it.secret ? Gruv.yellow : Gruv.fg1)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if !it.secret, let t = it.text, cleanedURL(t) != nil {
                    Button { model.cleanAndCopy(it); dismiss() } label: {
                        Image(systemName: "wand.and.stars").font(.caption).foregroundStyle(Gruv.yellow)
                    }
                    .buttonStyle(.plain)
                    .help("Clean URL & copy")
                }
                if it.secret, let exp = it.expiresAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text("\(max(0, Int(exp.timeIntervalSince(ctx.date).rounded(.up))))s")
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(Gruv.gray)
                    }
                }
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(it.id == model.selectedItem?.id ? Gruv.yellow.opacity(0.18) : Gruv.bg1.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(it.id == model.selectedItem?.id ? Gruv.yellow.opacity(0.7) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { pick(it) }
        .contextMenu {
            Button("Copy") { model.select(it) }
            if it.kind == .text { Button("→ vim") { model.pasteToVim(it); dismiss() } }
            if it.kind == .text, !it.secret { Button("📱 → Thor") { model.sendToThor(it); dismiss() } }
            if let t = it.text, !it.secret, cleanedURL(t) != nil {
                Button("🧹 Clean URL & copy") { model.cleanAndCopy(it); dismiss() }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(it) }
        }
    }

    private func preview(_ it: ClipItem) -> String {
        switch it.kind {
        case .image: return "🖼 image"
        case .text:
            let t = (it.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return it.secret ? "•••••• (concealed)" : t
        }
    }

    private func pick(_ it: ClipItem) { model.select(it); dismiss() }
    private func dismiss() { NotificationCenter.default.post(name: .kajoDismiss, object: nil) }
}

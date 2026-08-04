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

// MARK: - Memes (curated picker: grid · fuzzy search · click-to-copy)

let memeUntagged = "tagthis"   // untagged memes carry this so you can search for them

struct Meme: Identifiable, Codable, Equatable {
    var file: String
    var tags: [String]
    var added: Date
    var id: String { file }
}

final class MemeLibrary: ObservableObject {
    @Published var memes: [Meme] = []
    @Published var search = ""
    @Published var editingMeme: Meme?          // the meme whose tags are being edited (inline overlay)
    private let filesDir: URL, trashDir: URL, indexURL: URL

    var filtered: [Meme] {
        guard !search.isEmpty else { return memes }
        return memes
            .compactMap { m in memeFuzzy(search, m.tags.joined(separator: " ") + " " + m.file).map { (m, $0) } }
            .sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    init() {
        let base = URL(fileURLWithPath: kajoConfigDir).appendingPathComponent("memes")
        filesDir = base.appendingPathComponent("files")
        trashDir = base.appendingPathComponent("trash")
        indexURL = base.appendingPathComponent("index.json")
        for d in [filesDir, trashDir] { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        load()
    }

    func url(_ m: Meme) -> URL { filesDir.appendingPathComponent(m.file) }

    func load() {
        var list: [Meme] = []
        if let data = try? Data(contentsOf: indexURL),
           let arr = try? JSONDecoder().decode([Meme].self, from: data) {
            list = arr.filter { FileManager.default.fileExists(atPath: filesDir.appendingPathComponent($0.file).path) }
        }
        let known = Set(list.map { $0.file })
        let exts: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic"]
        if let files = try? FileManager.default.contentsOfDirectory(atPath: filesDir.path) {
            for f in files where !f.hasPrefix(".") && !known.contains(f) && exts.contains((f as NSString).pathExtension.lowercased()) {
                list.append(Meme(file: f, tags: [memeUntagged], added: Date()))
            }
        }
        list.sort { $0.added > $1.added }
        memes = list
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(memes) { try? data.write(to: indexURL) }
    }

    func add(data: Data, ext: String, tags: [String] = []) {
        let name = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).\(ext.isEmpty ? "png" : ext)"
        try? data.write(to: filesDir.appendingPathComponent(name))
        memes.insert(Meme(file: name, tags: tags.isEmpty ? [memeUntagged] : tags, added: Date()), at: 0)
        persist()
    }

    func setTags(_ m: Meme, _ tags: [String]) {
        guard let i = memes.firstIndex(where: { $0.id == m.id }) else { return }
        memes[i].tags = tags.isEmpty ? [memeUntagged] : tags
        persist()
    }

    func delete(_ m: Meme) {
        try? FileManager.default.moveItem(at: url(m), to: trashDir.appendingPathComponent(m.file))
        memes.removeAll { $0.id == m.id }
        persist()
    }

    private static let imgExts: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic"]

    func addFromClipboard() {
        let pb = NSPasteboard.general
        // 1. A real file copied in Finder → read the original bytes (keeps GIF animation, exact image).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let u = urls.first(where: { Self.imgExts.contains($0.pathExtension.lowercased()) }),
           let data = try? Data(contentsOf: u) { add(data: data, ext: u.pathExtension.lowercased()); return }
        // 2. Raw GIF bytes.
        if let gif = pb.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")) { add(data: gif, ext: "gif"); return }
        // 3. PNG bytes.
        if let png = pb.data(forType: .png) { add(data: png, ext: "png"); return }
        // 4. TIFF / generic image → re-encode to PNG.
        if let tiff = pb.data(forType: .tiff) ?? NSImage(pasteboard: pb)?.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { add(data: png, ext: "png") }
    }

    var clipboardHasImage: Bool {
        let pb = NSPasteboard.general
        if pb.data(forType: NSPasteboard.PasteboardType("com.compuserve.gif")) != nil { return true }
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil { return true }
        if NSImage(pasteboard: pb) != nil { return true }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            return urls.contains { Self.imgExts.contains($0.pathExtension.lowercased()) }
        }
        return false
    }

    func copy(_ m: Meme) {
        let u = url(m); let pb = NSPasteboard.general; pb.clearContents()
        let item = NSPasteboardItem()
        if let data = try? Data(contentsOf: u) {
            switch u.pathExtension.lowercased() {
            case "gif": item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            case "png": item.setData(data, forType: .png)
            default: break
            }
        }
        if let img = NSImage(contentsOf: u), let tiff = img.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item, u as NSURL])
    }
}

// Subsequence fuzzy match with a consecutive-run bonus.
func memeFuzzy(_ query: String, _ text: String) -> Int? {
    if query.isEmpty { return 0 }
    let q = Array(query.lowercased()), t = Array(text.lowercased())
    var qi = 0, score = 0, last = -2
    for (ti, c) in t.enumerated() where qi < q.count {
        if c == q[qi] { score += (ti == last + 1) ? 6 : 1; last = ti; qi += 1 }
    }
    return qi == q.count ? score : nil
}

struct MemeThumb: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown      // fit within the cell, keep aspect ratio
        v.imageAlignment = .alignCenter
        v.animates = true
        v.image = NSImage(contentsOf: url)
        // Don't let the image's natural size dictate layout — let the SwiftUI frame shrink it.
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }
    func updateNSView(_ v: NSImageView, context: Context) { v.animates = true }
}

// AppKit text field that reliably grabs first-responder in Kajo's borderless,
// non-activating panel (SwiftUI @FocusState doesn't engage there) and reports
// every keystroke for live filtering.
struct FocusedTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 13)
        tf.textColor = NSColor(Gruv.fg1)
        tf.delegate = context.coordinator
        tf.lineBreakMode = .byTruncatingTail
        DispatchQueue.main.async { tf.window?.makeFirstResponder(tf) }
        return tf
    }
    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.parent = self           // keep the binding fresh so edits propagate
        if tf.stringValue != text { tf.stringValue = text }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusedTextField
        init(_ p: FocusedTextField) { parent = p }
        func controlTextDidChange(_ note: Notification) {
            if let tf = note.object as? NSTextField { parent.text = tf.stringValue }
        }
        func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertNewline(_:)) { parent.onSubmit(); return true }
            return false
        }
    }
}

struct MemesTab: View {
    @ObservedObject var model: MemeLibrary
    @State private var editText = ""

    private let cols = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Gruv.fg4)
                FocusedTextField(text: $model.search, placeholder: "Search…  (try “tagthis”)",
                                 onSubmit: { if let f = model.filtered.first { pick(f) } })
                Text("\(model.filtered.count)").font(.caption2).foregroundStyle(Gruv.gray)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.bg1.opacity(0.6)))

            if model.filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.title2).foregroundStyle(Gruv.fg4)
                    Text(model.memes.isEmpty ? "Paste (⌘V) or drag a meme in" : "No match")
                        .font(.caption).foregroundStyle(Gruv.gray)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: cols, spacing: 8) {
                        ForEach(model.filtered) { cell($0) }
                    }.padding(.vertical, 4)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { drop($0); return true }
        .overlay { if let m = model.editingMeme { editorOverlay(m) } }
    }

    private func cell(_ m: Meme) -> some View {
        VStack(spacing: 2) {
            MemeThumb(url: model.url(m))
                .frame(height: 78).frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(m.tags.contains(memeUntagged) ? memeUntagged : m.tags.prefix(2).joined(separator: ", "))
                .font(.system(size: 10)).lineLimit(1)
                .foregroundStyle(m.tags.contains(memeUntagged) ? Gruv.yellow : Gruv.gray)
        }
        .contentShape(Rectangle())
        .onTapGesture { pick(m) }
        .help(m.tags.joined(separator: ", "))
        .contextMenu {
            Button("Copy") { model.copy(m) }
            Button("Edit tags…") { startEdit(m) }
            Divider()
            Button("Delete", role: .destructive) { model.delete(m) }
        }
    }

    private func editorOverlay(_ m: Meme) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { model.editingMeme = nil }
            VStack(alignment: .leading, spacing: 10) {
                Text("Edit tags").font(.headline).foregroundStyle(Gruv.fg1)
                MemeThumb(url: model.url(m)).frame(height: 110)
                    .background(Color.black.opacity(0.2)).clipShape(RoundedRectangle(cornerRadius: 6))
                FocusedTextField(text: $editText, placeholder: "comma, separated, tags", onSubmit: { saveEdit(m) })
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Gruv.bg1.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Gruv.fg4.opacity(0.3)))
                HStack {
                    Button("Cancel") { model.editingMeme = nil }
                    Spacer()
                    Button("Save") { saveEdit(m) }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14).frame(width: 290)
            .background(RoundedRectangle(cornerRadius: 12).fill(Gruv.bg0))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Gruv.fg4.opacity(0.25)))
        }
    }

    private func startEdit(_ m: Meme) {
        editText = m.tags.filter { $0 != memeUntagged }.joined(separator: ", ")
        model.editingMeme = m
    }
    private func saveEdit(_ m: Meme) {
        model.setTags(m, editText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        model.editingMeme = nil
    }
    private func pick(_ m: Meme) {
        model.copy(m)
        NotificationCenter.default.post(name: .kajoDismiss, object: nil)
    }

    private func drop(_ providers: [NSItemProvider]) {
        for p in providers {
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                var u: URL?
                if let d = item as? Data { u = URL(dataRepresentation: d, relativeTo: nil) } else if let x = item as? URL { u = x }
                guard let u, let data = try? Data(contentsOf: u) else { return }
                DispatchQueue.main.async { model.add(data: data, ext: u.pathExtension.lowercased()) }
            }
        }
    }
}

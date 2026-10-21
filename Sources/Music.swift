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

// MARK: - Now Playing (Spotify via AppleScript)

final class NowPlayingModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var album = ""
    @Published var artwork: NSImage?
    @Published var isPlaying = false
    @Published var hasTrack = false
    @Published var progress: Double = 0   // 0...1
    @Published var positionSec: Double = 0
    @Published var durationSec: Double = 0
    /// osascript got -1743 while Spotify is running. Every time so far the cause was Spotify
    /// updating itself in place: the running binary no longer matches the bundle on disk, so
    /// tccd "cannot create an attribution chain" and refuses AppleEvents for every client
    /// until Spotify is relaunched. Nothing in Kajo or TCC settings fixes it — a restart does.
    @Published var automationDenied = false
    @Published var restarting = false
    @Published var volume: Double?        // 0…1, spotifyd only (its hook exports VOLUME 0…65535)
    @Published var upNext: [SpotifyWeb.QueueItem] = []   // spotifyd only: the play queue (up to ~20)
    @Published var showPlaylists = false   // spotifyd only: the playlists slide-over is open (Esc closes it first)
    /// spotifyd mode: never AppleScript, launch or restart Spotify.app; controls go through the Web API.
    let spotifyd = musicSource == "spotifyd"
    let web: SpotifyWeb? = musicSource == "spotifyd" ? SpotifyWeb() : nil
    private var positionBase: Double = 0     // last real position we were told…
    private var positionAt = Date.distantPast  // …and when; the 1.5 s timer extrapolates from these

    private var timer: Timer?
    private var artURL: String?
    private var lastNotification: Date?   // Spotify's own PlaybackStateChanged — needs no Automation grant

    init() {
        if spotifyd { watchSpotifydState(); return }
        // Same source SketchyBar uses. Keeps the tab alive when AppleScript to Spotify is denied (TCC -1743).
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] n in self?.applyNotification(n.userInfo) }
    }

    private func applyNotification(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        let state = (info["Player State"] as? String ?? "").lowercased()
        lastNotification = Date()
        guard state != "stopped", let name = info["Name"] as? String, !name.isEmpty else {
            hasTrack = false; isPlaying = false; title = ""; artist = ""; album = ""; progress = 0; return
        }
        hasTrack = true
        isPlaying = state == "playing"
        let newArtist = info["Artist"] as? String ?? ""
        if name != title || newArtist != artist {
            artwork = nil; artURL = nil
            fetchArtworkFallback(track: name, artist: newArtist, album: info["Album"] as? String ?? "")   // Spotify's URL only comes via AppleScript
        }
        title = name
        artist = newArtist
        album = info["Album"] as? String ?? ""
        let durMs = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
        let pos = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
        setPosition(pos, duration: durMs / 1000)
    }

    /// Record a real position and re-derive progress. `tick()` moves it forward between reports.
    private func setPosition(_ pos: Double, duration: Double) {
        positionBase = pos; positionAt = Date()
        durationSec = duration
        positionSec = pos
        progress = duration > 0 ? min(1, max(0, pos / duration)) : 0
    }

    /// Spotify's notification only fires on track/state changes, and a denied AppleScript reports
    /// nothing — so advance the clock locally while playing, or the bar sits frozen.
    private func tick() {
        guard isPlaying, durationSec > 0, positionAt != .distantPast else { return }
        let pos = min(durationSec, positionBase + Date().timeIntervalSince(positionAt))
        positionSec = pos
        progress = pos / durationSec
    }

    // The `try` matters: without it osascript exits 1 with the -1743 text on stderr, which
    // shell() discards, and Kajo can't tell "denied" from "Spotify quit". This returns ERR<code>.
    private let infoScript = """
    set out to ""
    try
    \tif application "Spotify" is running then
    \t\ttell application "Spotify"
    \t\t\tset ps to player state as string
    \t\t\tif ps is not "stopped" then
    \t\t\t\tset out to ps & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track) & linefeed & (artwork url of current track) & linefeed & ((duration of current track) as text) & linefeed & ((player position) as text)
    \t\t\tend if
    \t\tend tell
    \tend if
    on error errMsg number errNum
    \treturn "ERR" & errNum
    end try
    return out
    """

    func startPolling() {
        stopPolling()
        refresh()
        if spotifyd {   // the state file pushes changes; the timer only moves the clock
            tabOpen = true
            refreshQueue()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() { timer?.invalidate(); timer = nil; tabOpen = false; queuePending?.cancel() }

    /// spotifyd: refresh "Next" — on tab open and after track changes while the tab is open. No timer.
    private var tabOpen = false
    private var queuePending: DispatchWorkItem?
    private func refreshQueue(after delay: Double = 0) {
        guard let web, web.hasToken else { return }
        queuePending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.tabOpen else { return }
            web.queue { [weak self] items in self?.upNext = items }   // errors: list just stays
        }
        queuePending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Jump to queue row `index` (0-based) = index+1 × next; see SpotifyWeb.skip for the ceiling.
    func playQueued(_ index: Int) { web?.skip(index + 1) }

    /// "Play next": add the row's item to the user queue, then re-read the queue (Spotify lags ~1 s).
    func playNext(_ item: SpotifyWeb.QueueItem) {
        web?.addToQueue(item.uri) { [weak self] ok in if ok { self?.refreshQueue(after: 1) } }
    }

    /// The bottom link field's Enter: track/episode → play next, album/playlist → play now,
    /// short links resolved first. `done(text, ok)` feeds the field's own caption.
    func submitLink(_ text: String, done: @escaping (String, Bool) -> Void) {
        guard let web else { return }
        if SpotifyWeb.isShortLink(text) {
            SpotifyWeb.resolveShortLink(text) { [weak self] ref in
                guard let ref else { done("Not a Spotify link", false); return }
                self?.submit(ref, web: web, done: done)
            }
        } else if let ref = SpotifyWeb.parseRef(text) {
            submit(ref, web: web, done: done)
        } else {
            done("Not a Spotify link", false)
        }
    }

    private func submit(_ ref: SpotifyWeb.Ref, web: SpotifyWeb, done: @escaping (String, Bool) -> Void) {
        // api() writes failures to web.caption (shown by the controls); move it to the field's line instead.
        weak let weakSelf = self   // nested closures: see the repo's weakSelf convention
        let finish: (String) -> (Bool) -> Void = { okText in { ok in
            if ok { done(okText, true); weakSelf?.refreshQueue(after: 1) } else { done(web.caption.isEmpty ? "Spotify refused" : web.caption, false); web.caption = "" }
        } }
        switch ref.kind {
        case "album", "playlist": web.playContext(ref.uri, done: finish("Playing \(ref.kind)"))
        default:                  web.addToQueue(ref.uri, done: finish("Queued"))
        }
    }

    private var inFlight = false

    func refresh() {
        if spotifyd { reloadSpotifydState(); return }
        guard !inFlight else { return }   // Spotify not answering AppleEvents must not stack osascripts every 1.5 s
        inFlight = true
        let script = infoScript
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = NowPlayingModel.runOSA(script) ?? ""
            let lines = out.components(separatedBy: "\n")
            DispatchQueue.main.async { self?.inFlight = false; self?.apply(lines) }
        }
    }

    private static let spotifyID = "com.spotify.client"
    private var spotifyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.spotifyID }
    }

    private func apply(_ lines: [String]) {
        if let first = lines.first, first.hasPrefix("ERR") {
            // -1743 = "Not authorised to send Apple events". Only meaningful while Spotify is up.
            automationDenied = first == "ERR-1743" && spotifyRunning
            tick()
            return
        }
        automationDenied = false
        guard lines.count >= 7, !lines[0].isEmpty else {
            // AppleScript gave nothing. If Spotify's notification is feeding us, don't wipe its state.
            if lastNotification != nil, spotifyRunning { tick(); return }
            hasTrack = false; isPlaying = false
            title = ""; artist = ""; album = ""; artwork = nil; artURL = nil
            setPosition(0, duration: 0)
            return
        }
        hasTrack = true
        isPlaying = lines[0] == "playing"
        title = lines[1]; artist = lines[2]; album = lines[3]
        let durMs = Double(lines[5]) ?? 0
        let pos = Double(lines[6].replacingOccurrences(of: ",", with: ".")) ?? 0
        setPosition(pos, duration: durMs / 1000)
        if lines[4] != artURL { artURL = lines[4]; loadArtwork(lines[4]) }
    }

    /// Quit Spotify and launch it again. Spotify does not resume playback by itself afterwards.
    func restartSpotify() {
        guard !spotifyd, !restarting else { return }
        restarting = true
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.spotifyID)
        apps.forEach { _ = $0.terminate() }
        var waited = 0
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            waited += 1
            guard let self else { t.invalidate(); return }
            if !self.spotifyRunning || waited > 40 {       // up to ~12 s, then give up waiting
                t.invalidate()
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.spotifyID) {
                    NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
                        DispatchQueue.main.async { self.restarting = false; self.refresh() }
                    }
                } else { self.restarting = false }
            }
        }
    }

    /// Cover art without Automation rights: Apple's public iTunes Search API (no key). Upscales the
    /// 100px thumbnail URL to 600px. Ignored if Spotify's own artwork arrives via AppleScript first.
    private func fetchArtworkFallback(track: String, artist: String, album: String) {
        let wantTitle = track
        weak var weakSelf = self
        let a = artist.lowercased(), al = album.lowercased()
        func norm(_ v: Any?) -> String { ((v as? String) ?? "").lowercased() }
        func results(_ url: URL, _ done: @escaping ([[String: Any]]) -> Void) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                done(json?["results"] as? [[String: Any]] ?? [])
            }.resume()
        }
        func search(_ items: [String: String]) -> URL {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = items.map { .init(name: $0.key, value: $0.value) } + [.init(name: "limit", value: "25")]
            return c.url!
        }
        func use(_ art: String?) {
            guard let art else { return }
            let big = art.replacingOccurrences(of: "100x100bb", with: "600x600bb")
            DispatchQueue.main.async {
                guard let me = weakSelf, me.title == wantTitle, me.artwork == nil else { return }   // still the same track, nothing better arrived
                me.loadArtwork(big)
            }
        }
        // 1) song search — the first hit is often a lullaby/8-bit cover, so insist on the same artist,
        //    prefer the same album, never show another artist's art.
        results(search(["term": "\(artist) \(track)", "entity": "song"])) { r in
            let same = r.filter { norm($0["artistName"]) == a }
            if let hit = same.first(where: { !al.isEmpty && norm($0["collectionName"]).hasPrefix(al) }) ?? same.first {
                use(hit["artworkUrl100"] as? String); return
            }
            // 2) some catalogues (TOOL…) never surface in song search: artist id → albums → album name.
            guard !al.isEmpty else { return }
            results(search(["term": artist, "entity": "musicArtist"])) { r in
                guard let id = r.first(where: { norm($0["artistName"]) == a })?["artistId"] as? Int else { return }
                var c = URLComponents(string: "https://itunes.apple.com/lookup")!
                c.queryItems = [.init(name: "id", value: String(id)), .init(name: "entity", value: "album"), .init(name: "limit", value: "200")]
                results(c.url!) { r in
                    use(r.first(where: { norm($0["collectionName"]).hasPrefix(al) })?["artworkUrl100"] as? String)
                }
            }
        }
    }

    private func loadArtwork(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { artwork = nil; return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async { self?.artwork = img }
        }.resume()
    }

    func playPause() {
        if let web { isPlaying ? web.pause() : web.play() } else { control("playpause") }
    }
    func next()      { if let web { web.next() } else { control("next track") } }
    func previous()  { if let web { web.previous() } else { control("previous track") } }

    private func control(_ cmd: String) {
        let script = "if application \"Spotify\" is running then tell application \"Spotify\" to \(cmd)"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = NowPlayingModel.runOSA(script)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.refresh() }
        }
    }

    private static func runOSA(_ script: String) -> String? {
        shell("/usr/bin/osascript", ["-e", script])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: spotifyd source
    // spotifyd's onevent hook merges each event's env into <kajoConfigDir>/spotifyd-state.json
    // (tmp + mv, plus "ts" = unix seconds). Every field persists until an event overwrites it, so
    // only POSITION_MS from an event that carries it is fresh (spotifyd src/process.rs).
    // Events: change (TRACK_NAME/DURATION/COVER), start/pause/load/seeked/positioncorrection/
    // position_changed (POSITION_MS), stop, sessiondisconnected, volumeset (VOLUME), and others we ignore.
    // The hook exports no artist/album; those come from the Web API once a token exists.

    private var stateSource: DispatchSourceFileSystemObject?
    private var statePending: DispatchWorkItem?
    private var trackID = ""
    private var infoFetchedFor = ""
    private static let positionEvents: Set<String> = ["start", "pause", "load", "seeked", "positioncorrection", "position_changed"]

    private func watchSpotifydState() {
        reloadSpotifydState()
        let fd = open(kajoConfigDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in   // the dir also changes for other files: coalesce, then one small read
            guard let self else { return }
            self.statePending?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.reloadSpotifydState() }
            self.statePending = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        stateSource = src
        // Same shortcut as ClaudeStateModel: a replaced config dir needs a relaunch.
    }

    private func reloadSpotifydState() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: kajoConfigDir + "/spotifyd-state.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            if hasTrack { hasTrack = false; isPlaying = false }
            return
        }
        func str(_ k: String) -> String { j[k].map { "\($0)" } ?? "" }
        let event = str("PLAYER_EVENT")
        let at = (j["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        if let v = Double(str("VOLUME")) { volume = min(1, max(0, v / 65535)) }

        let name = str("TRACK_NAME")
        guard !name.isEmpty, !["stop", "sessiondisconnected"].contains(event) else {
            hasTrack = false; isPlaying = false; setPosition(0, duration: durationSec); return
        }
        hasTrack = true
        // Shortcut: other events (change, load, volumeset…) keep the last known play state, so a
        // launch that lands on one of them shows paused until the next start/pause.
        if event == "start" { isPlaying = true } else if event == "pause" { isPlaying = false }

        let id = str("TRACK_ID")
        if id != trackID {
            trackID = id; artist = ""; album = ""; positionAt = .distantPast   // new track starts at 0 unless the event says otherwise
            if tabOpen, ["change", "load", "start"].contains(event) { refreshQueue(after: 2) }   // Spotify's queue lags the change
        }
        title = name
        let duration = (Double(str("TRACK_DURATION")) ?? 0) / 1000
        if Self.positionEvents.contains(event), let ms = Double(str("POSITION_MS")) {
            positionBase = ms / 1000; positionAt = at
        } else if positionAt == .distantPast {
            positionBase = 0; positionAt = at
        }
        durationSec = duration
        positionSec = positionBase
        progress = duration > 0 ? min(1, positionBase / duration) : 0
        tick()

        let cover = str("TRACK_COVER")
        if !cover.isEmpty, cover != artURL { artURL = cover; loadArtwork(cover) }   // old art stays until the new one loads
        if let web, web.hasToken, !id.isEmpty, infoFetchedFor != id {
            infoFetchedFor = id
            web.trackInfo(id) { [weak self] a, al in
                guard let self, self.trackID == id else { return }
                self.artist = a; self.album = al
                Self.shareArtist(a, trackID: id)
            }
        }
    }

    /// Writes ARTIST + ARTIST_TRACK_ID into the spotifyd state file so SketchyBar's music item
    /// can show the artist (spotifyd's hook doesn't export it). Merge + tmp/rename like the hook;
    /// the dir watcher re-reads once, and infoFetchedFor stops a second fetch → no loop.
    private static func shareArtist(_ artist: String, trackID: String) {
        guard !artist.isEmpty else { return }
        let path = kajoConfigDir + "/spotifyd-state.json"
        var d = (try? Data(contentsOf: URL(fileURLWithPath: path)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        guard (d["TRACK_ID"] as? String) == trackID else { return }
        d["ARTIST"] = artist; d["ARTIST_TRACK_ID"] = trackID
        guard let out = try? JSONSerialization.data(withJSONObject: d) else { return }
        let tmp = path + ".kajo.tmp"
        if (try? out.write(to: URL(fileURLWithPath: tmp))) != nil { _ = rename(tmp, path) }
        let bar = "/opt/homebrew/bin/sketchybar"   // optional; launchedProcess throws (ObjC) on a missing binary
        if FileManager.default.isExecutableFile(atPath: bar) { Process.launchedProcess(launchPath: bar, arguments: ["--trigger", "spotifyd_change"]) }
    }
}

struct MusicTab: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        if model.hasTrack {
            VStack(spacing: 14) {
                artwork
                VStack(spacing: 3) {
                    Text(model.title).font(.headline).foregroundStyle(Gruv.fg0).lineLimit(1)
                    Text(model.artist).font(.callout).foregroundStyle(Gruv.fg2).lineLimit(1)
                    Text(model.album).font(.caption).foregroundStyle(Gruv.gray).lineLimit(1)
                }
                progressBar
                timeRow
                if let web = model.web {
                    SpotifydControls(model: model, web: web)
                    UpNextList(model: model, web: web)   // fills the middle when non-empty
                    Spacer(minLength: 0)
                    SpotifyLinkField(model: model, web: web)   // pinned to the bottom
                } else {
                    if model.automationDenied { deniedNotice } else { controls }
                    if !model.spotifyd { openSpotifyButton }
                    Spacer()
                }
            }
        } else {
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Gruv.bg1.opacity(0.6))
                    .frame(height: 150)
                    .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(Gruv.gray))
                Text(model.spotifyd ? "Nothing playing on \(spotifyDevice)" : "Nothing playing").font(.headline).foregroundStyle(Gruv.fg2)
                if let web = model.web { SpotifydControls(model: model, web: web) } else { openSpotifyButton }
                Spacer()
                if let web = model.web { SpotifyLinkField(model: model, web: web) }
            }
        }
    }

    private var openSpotifyButton: some View {
        Button { AppLauncher.open("com.spotify.client") } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                Text("Open Spotify")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Gruv.aqua)
            .padding(.vertical, 7)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.bg1.opacity(0.7)))
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private var artwork: some View {
        Group {
            if let art = model.artwork {
                Image(nsImage: art).resizable().aspectRatio(contentMode: .fill)
            } else {
                Gruv.bg1.opacity(0.6)
                    .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(Gruv.gray))
            }
        }
        .frame(width: 168, height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Gruv.bg3.opacity(0.5))
                Capsule().fill(Gruv.green).frame(width: geo.size.width * model.progress)
            }
        }
        .frame(height: 4)
    }

    private var timeRow: some View {
        HStack {
            Text(mmss(model.positionSec))
            Spacer()
            Text(mmss(model.durationSec))
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Gruv.gray)
        .padding(.top, -6)
    }

    private func mmss(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    /// Shown instead of the controls while AppleEvents to Spotify are refused (see automationDenied).
    private var deniedNotice: some View {
        VStack(spacing: 8) {
            Text("Spotify updated itself in place, so macOS refuses control commands until it restarts.")
                .font(.caption).foregroundStyle(Gruv.fg2).multilineTextAlignment(.center)
            Button { model.restartSpotify() } label: {
                HStack(spacing: 6) {
                    if model.restarting { ProgressView().controlSize(.small) }
                    Text(model.restarting ? "Restarting…" : "Restart Spotify")
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(Gruv.yellow)
                .padding(.vertical, 7).padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.yellow.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .disabled(model.restarting)
        }
        .padding(.top, 2)
    }

    private var controls: some View {
        HStack(spacing: 30) {
            ctrl("backward.fill") { model.previous() }
            ctrl(model.isPlaying ? "pause.fill" : "play.fill", size: 30) { model.playPause() }
            ctrl("forward.fill") { model.next() }
        }
        .padding(.top, 4)
    }

    private func ctrl(_ symbol: String, size: CGFloat = 20, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(Gruv.fg1)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

/// spotifyd mode: the play queue under the controls, scrolling in the panel height left below
/// them. Click skips ahead to a row; right-click offers Play next / Play now / Copy link.
struct UpNextList: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb

    var body: some View {
        if web.hasToken, !model.upNext.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("UP NEXT").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(Gruv.gray)
                    Rectangle().fill(Gruv.bg2).frame(height: 1)
                }
                .padding(.horizontal, 6)   // text lines up with the thumbnails below
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.upNext.enumerated()), id: \.offset) { i, item in
                            UpNextRow(item: item) { model.playQueued(i) }
                                .contextMenu {
                                    Button("Play next") { model.playNext(item) }.disabled(item.uri.isEmpty)
                                    Button("Play now") { model.playQueued(i) }
                                    if !item.link.isEmpty {
                                        Button("Copy Spotify link") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(item.link, forType: .string)
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.bottom, 10)   // last row clears the fade below
                }
                // Subtle fade at the bottom edge so a cut-off row reads as "scroll for more".
                .mask(VStack(spacing: 0) {
                    Color.white
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
                })
            }
            // Full width = same edges as the progress bar; the hover background reaches them.
            // Takes the height left under the controls (layoutPriority beats MusicTab's Spacer).
            .frame(maxHeight: .infinity, alignment: .top)
            .layoutPriority(1)
        }
    }
}

/// spotifyd mode, bottom of the tab: paste a Spotify link, Enter = play next (album/playlist:
/// play now). Own caption line: green on success, orange on failure, cleared after a few seconds.
struct SpotifyLinkField: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    @State private var status = ""
    @State private var ok = true
    @State private var busy = false
    @State private var clearTask: DispatchWorkItem?

    var body: some View {
        if web.hasToken {
            VStack(spacing: 4) {
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(ok ? Gruv.green : Gruv.orange).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Image(systemName: "link").font(.caption).foregroundStyle(Gruv.fg4)
                    LinkTextField(placeholder: "Paste Spotify link · Enter = play next", onSubmit: submit)
                    if busy { ProgressView().controlSize(.small) }
                }
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Gruv.bg1))
            }
        }
    }

    /// Returns true when the field should clear (accepted for sending).
    private func submit(_ text: String) -> Bool {
        guard !busy, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        busy = true
        model.submitLink(text) { msg, good in
            busy = false; status = msg; ok = good
            clearTask?.cancel()
            let w = DispatchWorkItem { status = "" }
            clearTask = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (good ? 2.5 : 5), execute: w)
        }
        return true
    }
}

/// AppKit single-line field (same reasoning as CurrencyField: SwiftUI TextField misbehaves in the
/// borderless non-activating panel). Enter calls `onSubmit`; a true return clears the field.
private struct LinkTextField: NSViewRepresentable {
    let placeholder: String
    var onSubmit: (String) -> Bool
    var onChange: ((String) -> Void)? = nil   // every edit (the playlists filter)

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField()
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 12)
        tf.textColor = NSColor(Gruv.fg1)
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        tf.cell?.lineBreakMode = .byTruncatingTail
        tf.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(Gruv.fg4), .font: NSFont.systemFont(ofSize: 12)])
        tf.delegate = context.coordinator
        return tf
    }
    func updateNSView(_ tf: NSTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit; context.coordinator.onChange = onChange
    }
    func makeCoordinator() -> Coordinator { Coordinator(onSubmit: onSubmit, onChange: onChange) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onSubmit: (String) -> Bool
        var onChange: ((String) -> Void)?
        init(onSubmit: @escaping (String) -> Bool, onChange: ((String) -> Void)?) { self.onSubmit = onSubmit; self.onChange = onChange }
        func controlTextDidChange(_ n: Notification) {
            if let tf = n.object as? NSTextField { onChange?(tf.stringValue) }
        }
        func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            guard sel == #selector(NSResponder.insertNewline(_:)), let tf = c as? NSTextField else { return false }
            if onSubmit(tf.stringValue) { tf.stringValue = "" }
            return true
        }
    }
}

private struct UpNextRow: View {
    let item: SpotifyWeb.QueueItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                QueueThumb(url: item.imageURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.medium)).foregroundStyle(Gruv.fg1)
                        .lineLimit(1).truncationMode(.tail)
                    if !item.artist.isEmpty {
                        Text(item.artist).font(.caption).foregroundStyle(Gruv.gray)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "forward.end.fill").font(.caption).foregroundStyle(Gruv.fg4)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Gruv.bg1 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Header-row button (Panel.swift, Music tab title row): toggles the playlists slide-over.
struct PlaylistsButton: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb

    var body: some View {
        if web.hasToken {
            Button { withAnimation(.spring(duration: 0.3)) { model.showPlaylists.toggle() } } label: {
                Image(systemName: "music.note.list").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.showPlaylists ? Gruv.aqua : Gruv.fg4)
                    .frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Playlists")
        }
    }
}

/// spotifyd mode: the user's playlists, sliding in from the right over the Music tab (Panel.swift
/// overlays it). Click = play on the configured device and close; right-click = Play / Shuffle play / Copy link.
struct PlaylistsPanel: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    @State private var filter = ""
    @State private var busy = false

    private var shown: [SpotifyWeb.Playlist] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? web.playlists : web.playlists.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { close() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Gruv.fg2)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Playlists").font(.system(size: 15, weight: .semibold)).foregroundStyle(Gruv.fg1)
                if web.canReadPlaylists, !web.playlists.isEmpty {
                    Text("\(web.playlists.count)").font(.caption.monospacedDigit()).foregroundStyle(Gruv.gray)
                }
                Spacer()
                if web.playlistsLoading || busy { ProgressView().controlSize(.small) }
            }
            .padding(.top, 10)   // breathing room under the tab's title row
            if web.canReadPlaylists {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").font(.caption).foregroundStyle(Gruv.fg4)
                    LinkTextField(placeholder: "Filter playlists", onSubmit: { _ in false }, onChange: { filter = $0 })
                }
                .padding(.vertical, 7).padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Gruv.bg1))
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(shown) { p in
                            PlaylistRow(playlist: p) { play(p, shuffle: false) }
                                .contextMenu {
                                    Button("Play") { play(p, shuffle: false) }
                                    Button("Shuffle play") { play(p, shuffle: true) }
                                    Button("Copy link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(p.link, forType: .string)
                                    }
                                }
                        }
                    }
                    .padding(.bottom, 10)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Kajo needs permission to read your playlists.")
                        .font(.caption).foregroundStyle(Gruv.fg2).multilineTextAlignment(.center)
                    Button { web.connect() } label: {
                        HStack(spacing: 6) {
                            if web.connecting { ProgressView().controlSize(.small) }
                            Text(web.connecting ? "Waiting for the browser…" : "Reconnect Spotify")
                        }
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Gruv.green)
                        .padding(.vertical, 7).padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.green.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .disabled(web.connecting)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
                Spacer(minLength: 0)
            }
            if !web.caption.isEmpty {
                Text(web.caption).font(.caption).foregroundStyle(Gruv.orange).lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Gruv.bg0)
        .overlay(alignment: .leading) { Rectangle().fill(Gruv.bg3.opacity(0.4)).frame(width: 1) }
        .shadow(color: .black.opacity(0.35), radius: 8, x: -3)
        .onAppear { web.loadPlaylists() }
        .onChange(of: web.canReadPlaylists) { _, ok in if ok { web.loadPlaylists(force: true) } }
    }

    private func close() { withAnimation(.spring(duration: 0.3)) { model.showPlaylists = false } }

    private func play(_ p: SpotifyWeb.Playlist, shuffle: Bool) {
        guard !busy else { return }
        busy = true
        let done: (Bool) -> Void = { ok in
            busy = false
            if ok { close() }   // failure: the caption above explains, panel stays
        }
        if shuffle { web.shufflePlay(p.uri, done: done) } else { web.playContext(p.uri, done: done) }
    }
}

private struct PlaylistRow: View {
    let playlist: SpotifyWeb.Playlist
    let action: () -> Void
    @State private var hovering = false

    private var detail: String {
        [playlist.total.map { "\($0) tracks" }, playlist.owner.isEmpty ? nil : playlist.owner]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                QueueThumb(url: playlist.imageURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.callout.weight(.medium)).foregroundStyle(Gruv.fg1)
                        .lineLimit(1).truncationMode(.tail)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Gruv.gray).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "play.fill").font(.caption).foregroundStyle(Gruv.fg4).opacity(hovering ? 1 : 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Gruv.bg1 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 36 pt queue thumbnail. Loaded once per URL into a process-lifetime cache (smallest Spotify
/// image, ~64 px, a few KB each, so no eviction; upgrade path: NSCache if memory ever shows it).
private struct QueueThumb: View {
    let url: String
    @State private var image: NSImage?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Gruv.bg2.overlay(Image(systemName: "music.note").font(.caption).foregroundStyle(Gruv.fg4))
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .task(id: url) { await load() }
    }

    @MainActor private func load() async {
        if let hit = Self.cache[url] { image = hit; return }
        image = nil
        guard let u = URL(string: url), !url.isEmpty,
              let (data, _) = try? await URLSession.shared.data(from: u),
              let img = NSImage(data: data) else { return }
        Self.cache[url] = img
        image = img
    }
}

/// spotifyd mode transport: Web API buttons, a volume slider, and the setup states
/// (no client ID → greyed + hint, no token → Connect Spotify). Errors land in `web.caption`.
struct SpotifydControls: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    @State private var vol: Double = 0.5

    var body: some View {
        VStack(spacing: 8) {
            if web.clientID.isEmpty {
                buttons.disabled(true).opacity(0.35)
                caption("set spotifyClientID in config.json", Gruv.gray)
            } else if !web.hasToken {
                Button { web.connect() } label: {
                    HStack(spacing: 6) {
                        if web.connecting { ProgressView().controlSize(.small) }
                        Text(web.connecting ? "Waiting for the browser…" : "Connect Spotify")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Gruv.green)
                    .padding(.vertical, 7).padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.green.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .disabled(web.connecting)
            } else {
                buttons
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(Gruv.gray)
                    Slider(value: $vol, in: 0...1) { editing in
                        if !editing { web.setVolume(Int((vol * 100).rounded())) }
                    }
                    .tint(Gruv.green)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(Gruv.gray)
                }
                .padding(.horizontal, 24)
            }
            if !web.caption.isEmpty { caption(web.caption, Gruv.orange) }
        }
        .padding(.top, 4)
        .onAppear { if let v = model.volume { vol = v } }
        .onChange(of: model.volume) { _, v in if let v { vol = v } }
    }

    private var buttons: some View {
        HStack(spacing: 30) {
            ctrl("backward.fill") { model.previous() }
            ctrl(model.isPlaying ? "pause.fill" : "play.fill", size: 30) { model.playPause() }
            ctrl("forward.fill") { model.next() }
        }
    }

    private func caption(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption).foregroundStyle(color).multilineTextAlignment(.center).lineLimit(2)
    }

    private func ctrl(_ symbol: String, size: CGFloat = 20, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(Gruv.fg1).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

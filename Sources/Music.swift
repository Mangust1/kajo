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
    enum SlideOver { case playlists, search }
    @Published var slideOver: SlideOver?   // spotifyd only: the open slide-over, one at a time (Esc closes it first)
    @Published var openPlaylist: SpotifyWeb.Playlist?   // Playlists slide-over showing this one's tracks (Esc goes back first)
    @Published var showDevices = false     // spotifyd only: the device picker popover is open (Esc closes it first)
    /// spotifyd mode: never AppleScript, launch or restart Spotify.app; controls go through the Web API.
    let spotifyd = musicSource == "spotifyd"
    let web: SpotifyWeb? = musicSource == "spotifyd" ? SpotifyWeb() : nil
    let zeroconf = SpotifyZeroconf()   // device picker's "On your network" (idle until the picker opens)
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
            web?.loadDevices()   // device-button tint
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
            web.queue { [weak self] items in self?.setQueue(items) }   // errors: list just stays
        }
        queuePending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Jump to shown queue row `index` (0-based) = its position in Spotify's queue + 1 × next; see
    /// SpotifyWeb.skip for the ceiling. Hidden (removed) rows jumped over leave the skip list, or
    /// their passing change events would fire extra nexts.
    func playQueued(_ index: Int) {
        guard index < upNextRaw.count else { return }
        let raw = upNextRaw[index]
        rawQueue.prefix(raw).forEach { skipIDs[Self.itemID($0.uri)] = nil }
        web?.skip(raw + 1)
    }

    // MARK: Remove from queue (local skip list)
    // ponytail: Spotify's Web API has no queue-delete endpoint, so "Remove from queue" only hides the
    // row and records the track id; when that track becomes current (change/load/start) Kajo sends
    // one next(). Ceiling: the track may be audible for a fraction of a second, nothing is removed
    // server-side, and Spotify's own clients still list it. In memory only: max 50 ids, 3 h each.
    // Upgrade path if Spotify ever adds a queue-delete endpoint: call it and drop the skip list.
    private var skipIDs: [String: Date] = [:]   // track/episode id → when it was removed
    private var rawQueue: [SpotifyWeb.QueueItem] = []   // Spotify's queue as last read
    private var upNextRaw: [Int] = []                   // upNext[i] = rawQueue[upNextRaw[i]]

    private static func itemID(_ uri: String) -> String { uri.split(separator: ":").last.map(String.init) ?? "" }

    private func pruneSkips() {
        let cutoff = Date().addingTimeInterval(-3 * 3600)
        skipIDs = skipIDs.filter { $0.value > cutoff }
        while skipIDs.count > 50, let oldest = skipIDs.min(by: { $0.value < $1.value }) { skipIDs[oldest.key] = nil }
    }

    /// Spotify's queue minus skip-listed ids.
    private func setQueue(_ items: [SpotifyWeb.QueueItem]) {
        pruneSkips()
        rawQueue = items
        upNextRaw = items.indices.filter { skipIDs[Self.itemID(items[$0].uri)] == nil }
        upNext = upNextRaw.map { items[$0] }
    }

    func removeFromQueue(_ item: SpotifyWeb.QueueItem) {
        let id = Self.itemID(item.uri)
        guard !id.isEmpty else { return }
        skipIDs[id] = Date()
        setQueue(rawQueue)
    }

    /// "Play next": add the row's item to the user queue, then re-read the queue (Spotify lags ~1 s).
    func playNext(_ item: SpotifyWeb.QueueItem) { enqueue(item.uri) }

    /// Add `uri` to the user queue; on success re-read the queue (Spotify lags ~1 s). Errors → web.caption.
    func enqueue(_ uri: String, done: @escaping (Bool) -> Void = { _ in }) {
        web?.addToQueue(uri) { [weak self] ok in
            if ok { self?.refreshQueue(after: 1) }
            done(ok)
        }
    }

    /// Open `s`, or close it when it is already the open one.
    func toggleSlideOver(_ s: SlideOver) { withAnimation(.spring(duration: 0.3)) { slideOver = slideOver == s ? nil : s; openPlaylist = nil } }
    func closeSlideOver() { withAnimation(.spring(duration: 0.3)) { slideOver = nil; openPlaylist = nil } }
    /// Playlists slide-over: push a playlist's track list (nil = back to the list).
    func showPlaylist(_ p: SpotifyWeb.Playlist?) { withAnimation(.spring(duration: 0.3)) { openPlaylist = p } }

    /// Device picker row click: transfer playback there, then re-read the queue (Spotify lags ~1 s).
    func transferPlayback(to d: SpotifyWeb.Device) {
        web?.transfer(to: d) { [weak self] ok in
            guard ok else { return }
            self?.refreshQueue(after: 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.web?.loadDevices() }   // re-tint
        }
    }

    /// "On your network" row click: sign the speaker in with spotifyd's login (zeroconf addUser),
    /// wait until the Web API lists it, then transfer playback there. addUser errors stay on the row.
    func connectSpeaker(_ s: SpotifyZeroconf.Speaker) {
        guard let web else { return }
        zeroconf.addUser(s) { [weak self] ok in
            guard ok, let self else { return }
            self.showDevices = false
            web.caption = "Connecting \(s.name)…"
            web.waitForDevice(named: s.name) { [weak self] d in
                guard let d else { web.caption = "\(s.name) signed in, but Spotify doesn't list it yet"; return }
                self?.transferPlayback(to: d)
            }
        }
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
        // Removed from the queue (skip list): skip it once as it starts, then forget it so a later deliberate play works.
        if ["change", "load", "start"].contains(event), !id.isEmpty, skipIDs.removeValue(forKey: id) != nil { web?.next() }
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
            infoFetchedFor = id   // in flight: blocks duplicate fetches from further state-file events
            web.trackInfo(id) { [weak self] info in
                guard let self else { return }
                guard let info else {   // every try failed (e.g. mid token reconnect): the next event for this track retries
                    if self.infoFetchedFor == id { self.infoFetchedFor = "" }
                    return
                }
                guard self.trackID == id else { return }
                self.artist = info.artist; self.album = info.album
                Self.shareArtist(info.artist, trackID: id)
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
                SectionHeader(text: "UP NEXT")
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.upNext.enumerated()), id: \.offset) { i, item in
                            MediaRow(title: item.title, detail: item.artist, imageURL: item.imageURL, hoverSymbol: "forward.end.fill") { model.playQueued(i) }
                                .contextMenu {
                                    Button("Play next") { model.playNext(item) }.disabled(item.uri.isEmpty)
                                    Button("Play now") { model.playQueued(i) }
                                    Button("Remove from queue") { model.removeFromQueue(item) }.disabled(item.uri.isEmpty)
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
    var autoFocus = false                      // first responder as soon as it is in a window (search)

    func makeNSView(context: Context) -> NSTextField {
        let tf = FocusingTextField()
        tf.autoFocus = autoFocus
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

    final class FocusingTextField: NSTextField {
        var autoFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard autoFocus, window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) }   // after the slide-in's layout pass
        }
    }

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

/// One list row in the UpNextRow look: 36 pt thumb (round for artists), title, caption, a symbol on hover.
/// Used by Up next, Playlists and Search.
private struct MediaRow: View {
    let title: String
    let detail: String
    let imageURL: String
    var round = false
    let hoverSymbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                QueueThumb(url: imageURL, round: round)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium)).foregroundStyle(Gruv.fg1)
                        .lineLimit(1).truncationMode(.tail)
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(Gruv.gray)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: hoverSymbol).font(.caption).foregroundStyle(Gruv.fg4)
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

/// Small caps list header with a rule ("UP NEXT", search sections).
private struct SectionHeader: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Text(text).font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(Gruv.gray)
            Rectangle().fill(Gruv.bg2).frame(height: 1)
        }
        .padding(.horizontal, 6)   // text lines up with the thumbnails below
    }
}

/// Header-row button (Panel.swift, Music tab title row): toggles one slide-over (search, playlists).
struct SlideOverButton: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    let kind: NowPlayingModel.SlideOver
    let symbol: String
    let help: String

    var body: some View {
        if web.hasToken {
            Button { model.toggleSlideOver(kind) } label: {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.slideOver == kind ? Gruv.aqua : Gruv.fg4)
                    .frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        }
    }
}

/// Header-row button left of the playlists one: opens the device picker popover. Green while
/// another device than `spotifyDevice` is the active one.
struct DevicesButton: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb

    var body: some View {
        if web.hasToken {
            Button { model.showDevices.toggle() } label: {
                Image(systemName: "hifispeaker.2").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(web.playingElsewhere ? Gruv.green : Gruv.fg4)
                    .frame(width: 26, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Play on…")
            .popover(isPresented: $model.showDevices, arrowEdge: .bottom) {
                DevicesPicker(model: model, web: web, zc: model.zeroconf)
            }
        }
    }
}

/// The device picker's content: Spotify Connect devices, fetched each time it opens, plus
/// Connect speakers found on the LAN that the account doesn't list yet (browsed while open).
private struct DevicesPicker: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    @ObservedObject var zc: SpotifyZeroconf

    /// LAN speakers minus our own spotifyd and anything the Web API already lists.
    private var network: [SpotifyZeroconf.Speaker] {
        zc.speakers.filter { s in s.name != spotifyDevice && !web.devices.contains { $0.name == s.name } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Play on").font(.caption.weight(.semibold)).foregroundStyle(Gruv.fg2)
                Spacer()
                if web.devicesLoading { ProgressView().controlSize(.mini) }
            }
            if web.devices.isEmpty, !web.devicesLoading {
                Text("No devices listed").font(.caption).foregroundStyle(Gruv.gray)
            }
            ForEach(web.devices) { d in
                DeviceRow(device: d) {
                    model.showDevices = false
                    model.transferPlayback(to: d)
                }
            }
            if network.isEmpty {
                Text("Speakers on your network: connect once from Spotifast or the phone.")
                    .font(.caption2).foregroundStyle(Gruv.gray)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            } else {
                Text("On your network").font(.caption.weight(.semibold)).foregroundStyle(Gruv.fg2).padding(.top, 4)
                ForEach(network) { s in
                    NetworkSpeakerRow(speaker: s, zc: zc) { model.connectSpeaker(s) }
                }
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(Gruv.bg0)
        .onAppear { web.loadDevices(); zc.start() }
        .onDisappear { zc.stop() }
    }
}

/// A Connect speaker from Bonjour that isn't on the account yet. Click = zeroconf addUser.
private struct NetworkSpeakerRow: View {
    let speaker: SpotifyZeroconf.Speaker
    @ObservedObject var zc: SpotifyZeroconf
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let busy = zc.connecting == speaker.id
        let usable = zc.hasCredentials && zc.connecting == nil
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "hifispeaker").font(.system(size: 13)).foregroundStyle(Gruv.fg2).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(speaker.name).font(.callout).foregroundStyle(Gruv.fg1).lineLimit(1)
                    if !zc.hasCredentials {
                        Text("needs spotifyd login").font(.caption2).foregroundStyle(Gruv.gray)
                    } else if busy {
                        Text("connecting…").font(.caption2).foregroundStyle(Gruv.gray)
                    } else if let err = zc.errors[speaker.id] {
                        Text(err).font(.caption2).foregroundStyle(Gruv.orange).lineLimit(2)
                    } else {
                        Text("tap to connect").font(.caption2).foregroundStyle(Gruv.gray)
                    }
                }
                Spacer(minLength: 4)
                if busy { ProgressView().controlSize(.mini) }
            }
            .padding(.vertical, 5).padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && usable ? Gruv.bg1 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .opacity(zc.hasCredentials ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

private struct DeviceRow: View {
    let device: SpotifyWeb.Device
    let action: () -> Void
    @State private var hovering = false

    private var symbol: String {
        switch device.type.lowercased() {
        case "computer":   return "laptopcomputer"
        case "smartphone": return "iphone"
        case "speaker":    return "hifispeaker"
        case "tv":         return "tv"
        default:           return "speaker.wave.2"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 13))
                    .foregroundStyle(device.isActive ? Gruv.green : Gruv.fg2).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.callout).foregroundStyle(device.isActive ? Gruv.green : Gruv.fg1).lineLimit(1)
                    if let v = device.volume {
                        Text("\(v)%").font(.caption2.monospacedDigit()).foregroundStyle(Gruv.gray)
                    }
                }
                Spacer(minLength: 4)
                if device.isActive {
                    Image(systemName: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Gruv.green)
                }
            }
            .padding(.vertical, 5).padding(.horizontal, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering && device.selectable ? Gruv.bg1 : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!device.selectable)
        .opacity(device.selectable ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

/// Chrome shared by the Music tab's slide-overs (Panel.swift overlays them from the right):
/// back chevron, title + accessory, spinner, the content, and web.caption errors at the bottom.
private struct SlideOverPanel<Accessory: View, Content: View>: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    let title: String
    let busy: Bool
    var onBack: (() -> Void)? = nil   // nil = close the slide-over (a pushed view goes back instead)
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { if let onBack { onBack() } else { model.closeSlideOver() } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Gruv.fg2)
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Gruv.fg1)
                    .lineLimit(1).truncationMode(.tail)
                accessory
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .padding(.top, 10)   // breathing room under the tab's title row
            content
            if !web.caption.isEmpty {
                Text(web.caption).font(.caption).foregroundStyle(Gruv.orange).lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Gruv.bg0)
        .overlay(alignment: .leading) { Rectangle().fill(Gruv.bg3.opacity(0.4)).frame(width: 1) }
        .shadow(color: .black.opacity(0.35), radius: 8, x: -3)
    }
}

/// Rounded bg1 field row (icon + AppKit text field) used by the slide-overs' filter/search fields.
private struct FieldBox<Content: View>: View {
    let symbol: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(Gruv.fg4)
            content
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Gruv.bg1))
    }
}

private func copyLink(_ link: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(link, forType: .string)
}

/// spotifyd mode: the user's playlists slide-over. Click = open its tracks (PlaylistDetail, pushed in
/// the same slide-over); right-click = Play / Shuffle play / Copy link.
struct PlaylistsPanel: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb

    var body: some View {
        if let p = model.openPlaylist {
            PlaylistDetail(model: model, web: web, playlist: p).id(p.id)
                .transition(.move(edge: .trailing))
        } else {
            PlaylistList(model: model, web: web)
        }
    }
}

private struct PlaylistList: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    @State private var filter = ""
    @State private var busy = false

    private var shown: [SpotifyWeb.Playlist] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? web.playlists : web.playlists.filter { $0.name.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        SlideOverPanel(model: model, web: web, title: "Playlists", busy: web.playlistsLoading || busy) {
            if web.canReadPlaylists, !web.playlists.isEmpty {
                Text("\(web.playlists.count)").font(.caption.monospacedDigit()).foregroundStyle(Gruv.gray)
            }
        } content: {
            if web.canReadPlaylists {
                FieldBox(symbol: "line.3.horizontal.decrease") {
                    LinkTextField(placeholder: "Filter playlists", onSubmit: { _ in false }, onChange: { filter = $0 })
                }
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(shown) { p in
                            MediaRow(title: p.name, detail: detail(p), imageURL: p.imageURL, hoverSymbol: "chevron.right") { model.showPlaylist(p) }
                                .contextMenu {
                                    Button("Play") { play(p, shuffle: false) }
                                    Button("Shuffle play") { play(p, shuffle: true) }
                                    Button("Copy link") { copyLink(p.link) }
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
        }
        .onAppear { web.loadPlaylists() }
        .onChange(of: web.canReadPlaylists) { _, ok in if ok { web.loadPlaylists(force: true) } }
    }

    private func detail(_ p: SpotifyWeb.Playlist) -> String {
        [p.total.map { "\($0) tracks" }, p.owner.isEmpty ? nil : p.owner].compactMap { $0 }.joined(separator: " · ")
    }

    private func play(_ p: SpotifyWeb.Playlist, shuffle: Bool) {
        guard !busy else { return }
        busy = true
        let done: (Bool) -> Void = { ok in
            busy = false
            if ok { model.closeSlideOver() }   // failure: the caption explains, panel stays
        }
        if shuffle { web.shufflePlay(p.uri, done: done) } else { web.playContext(p.uri, done: done) }
    }
}

/// A playlist's tracks inside the Playlists slide-over: Play / Shuffle row, then the tracks. Click =
/// play the playlist from that track; right-click Play from here / Play next / Copy link / Remove from
/// playlist (owner only; a token without the modify scopes offers Reconnect instead). Removal is
/// optimistic with a 6 s Undo bar; an API error puts the row back (the caption says why).
private struct PlaylistDetail: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    let playlist: SpotifyWeb.Playlist
    @State private var tracks: [SpotifyWeb.PlaylistTrack] = []
    @State private var snapshot = ""
    @State private var loading = true
    @State private var busy = false
    @State private var note: Note?
    @State private var noteTask: DispatchWorkItem?

    /// Bottom bar: "Queued: x" (green) or "Removed x · Undo" (`undo` set once the DELETE succeeded).
    struct Note { let text: String; var removed: (track: SpotifyWeb.PlaylistTrack, index: Int)? = nil; var undoReady = false }

    private var owned: Bool { !playlist.ownerID.isEmpty && playlist.ownerID == web.userID }

    var body: some View {
        SlideOverPanel(model: model, web: web, title: playlist.name, busy: loading || busy, onBack: { model.showPlaylist(nil) }) {
            if !loading { Text("\(tracks.count)").font(.caption.monospacedDigit()).foregroundStyle(Gruv.gray) }
        } content: {
            HStack(spacing: 8) {
                pill("play.fill", "Play") { play(shuffle: false) }
                pill("shuffle", "Shuffle") { play(shuffle: true) }
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(tracks) { t in
                        MediaRow(title: t.title, detail: t.detail, imageURL: t.imageURL, hoverSymbol: "play.fill") { playFrom(t) }
                            .contextMenu { menu(t) }
                    }
                }
                .padding(.bottom, 10)
            }
            if let note { noteBar(note) }
        }
        .onAppear { load(); web.loadMe() }
        .onDisappear { noteTask?.cancel() }
    }

    private func pill(_ symbol: String, _ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { Image(systemName: symbol); Text(text) }
                .font(.callout.weight(.medium)).foregroundStyle(Gruv.green)
                .padding(.vertical, 5).padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.green.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    @ViewBuilder private func menu(_ t: SpotifyWeb.PlaylistTrack) -> some View {
        Button("Play from here") { playFrom(t) }
        Button("Play next") { queue(t) }
        Button("Copy link") { copyLink(t.link) }.disabled(t.link.isEmpty)
        if owned {
            if web.canEditPlaylists {
                Button("Remove from playlist") { remove(t) }
            } else {
                Button("Reconnect to edit playlists") { web.connect() }.disabled(web.connecting)
            }
        }
    }

    private func noteBar(_ n: Note) -> some View {
        HStack(spacing: 8) {
            Text(n.text).font(.caption).foregroundStyle(n.removed == nil ? Gruv.green : Gruv.fg2).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if n.removed != nil {
                Button("Undo") { undo() }.buttonStyle(.plain).font(.caption.weight(.semibold))
                    .foregroundStyle(n.undoReady ? Gruv.aqua : Gruv.gray).disabled(!n.undoReady)
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Gruv.bg1))
    }

    private func show(_ n: Note?, for seconds: Double) {
        note = n
        noteTask?.cancel()
        let w = DispatchWorkItem { note = nil }
        noteTask = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func load() {
        web.playlistTracks(playlist.id) { r in
            loading = false
            if let r { tracks = r.tracks; snapshot = r.snapshot.isEmpty ? playlist.snapshotID : r.snapshot }
        }
    }

    private func finish(_ ok: Bool) { busy = false; if ok { model.closeSlideOver() } }   // failure: the caption explains

    private func play(shuffle: Bool) {
        guard !busy else { return }
        busy = true
        if shuffle { web.shufflePlay(playlist.uri, done: finish) } else { web.playContext(playlist.uri, done: finish) }
    }

    private func playFrom(_ t: SpotifyWeb.PlaylistTrack) {
        guard !busy else { return }
        busy = true
        web.playFromPlaylist(playlist.uri, track: t.uri, done: finish)
    }

    private func queue(_ t: SpotifyWeb.PlaylistTrack) {
        model.enqueue(t.uri) { ok in if ok { show(Note(text: "Queued: \(t.title)"), for: 2.5) } }
    }

    /// Spotify drops every occurrence of the uri (see removeFromPlaylist), so every matching row goes;
    /// Undo puts one back at the first one's index.
    private func remove(_ t: SpotifyWeb.PlaylistTrack) {
        guard let index = tracks.firstIndex(where: { $0.id == t.id }) else { return }
        let gone = tracks.enumerated().filter { $0.element.uri == t.uri }   // (original index, row)
        let first = gone.first?.offset ?? index
        withAnimation { tracks.removeAll { $0.uri == t.uri } }
        show(Note(text: "Removed \(t.title)", removed: (t, first)), for: 6)
        web.removeFromPlaylist(playlist.id, uri: t.uri, snapshot: snapshot) { snap in
            guard let snap else {   // restore; api() put the error in the orange caption
                withAnimation { gone.forEach { tracks.insert($0.element, at: min($0.offset, tracks.count)) } }
                if note?.removed?.track.id == t.id { note = nil }
                return
            }
            if !snap.isEmpty { snapshot = snap }
            if note?.removed?.track.id == t.id { note?.undoReady = true }
        }
    }

    private func undo() {
        guard let r = note?.removed, note?.undoReady == true else { return }
        note = nil; noteTask?.cancel()
        withAnimation { tracks.insert(r.track, at: min(r.index, tracks.count)) }
        web.addToPlaylist(playlist.id, uri: r.track.uri, position: r.index) { snap in
            guard let snap else { withAnimation { tracks.removeAll { $0.id == r.track.id } }; return }   // caption says why
            if !snap.isEmpty { snapshot = snap }
        }
    }
}

/// spotifyd mode: Spotify search slide-over. Types as you go (350 ms debounce, 2+ chars; Enter = now).
/// Tracks: click = play next (stays open), right-click Play next / Play now / Copy link.
/// Albums, playlists, artists: click = play now and close; right-click Play / Shuffle play / Copy link
/// (no shuffle for artists).
struct SearchPanel: View {
    @ObservedObject var model: NowPlayingModel
    @ObservedObject var web: SpotifyWeb
    @State private var query = ""
    @State private var results: SpotifyWeb.SearchResults?
    @State private var searching = false
    @State private var busy = false
    @State private var pending: DispatchWorkItem?
    @State private var expanded: Set<String> = []   // sections showing all rows
    @State private var status = ""                   // green "Queued: …" line
    @State private var clearTask: DispatchWorkItem?

    var body: some View {
        SlideOverPanel(model: model, web: web, title: "Search", busy: searching || busy) {
            EmptyView()
        } content: {
            FieldBox(symbol: "magnifyingglass") {
                LinkTextField(placeholder: "Songs, artists, albums, playlists", onSubmit: { text in
                    run(text, delay: 0); return false
                }, onChange: { text in run(text, delay: 0.35) }, autoFocus: true)
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(Gruv.green).lineLimit(1)
            }
            if let results {
                if results.isEmpty {
                    muted("No results for \u{201C}\(query)\u{201D}")
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 4) {
                            section("TRACKS", results.tracks, limit: 6)
                            section("ARTISTS", results.artists, limit: 4)
                            section("ALBUMS", results.albums, limit: 4)
                            section("PLAYLISTS", results.playlists, limit: 4)
                        }
                        .padding(.bottom, 10)
                    }
                }
            } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                muted("Type at least two characters")
            }
        }
        .onDisappear { pending?.cancel() }
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Gruv.gray).frame(maxWidth: .infinity).padding(.top, 12)
    }

    @ViewBuilder private func section(_ title: String, _ items: [SpotifyWeb.SearchItem], limit: Int) -> some View {
        if !items.isEmpty {
            let all = expanded.contains(title)
            SectionHeader(text: title).padding(.top, 6)
            ForEach(all ? items : Array(items.prefix(limit))) { item in
                MediaRow(title: item.title, detail: item.detail, imageURL: item.imageURL, round: item.kind == "artist",
                         hoverSymbol: item.kind == "track" ? "text.line.first.and.arrowtriangle.forward" : "play.fill") { primary(item) }
                    .contextMenu { menu(item) }
            }
            if items.count > limit {
                Button(all ? "Show less" : "Show all \(items.count)") {
                    if all { expanded.remove(title) } else { expanded.insert(title) }
                }
                .buttonStyle(.plain).font(.caption).foregroundStyle(Gruv.aqua).padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder private func menu(_ item: SpotifyWeb.SearchItem) -> some View {
        if item.kind == "track" {
            Button("Play next") { queue(item) }
            Button("Play now") { play(item, shuffle: false) }
        } else {
            Button("Play") { play(item, shuffle: false) }
            if item.kind != "artist" { Button("Shuffle play") { play(item, shuffle: true) } }
        }
        Button("Copy link") { copyLink(item.link) }.disabled(item.link.isEmpty)
    }

    private func primary(_ item: SpotifyWeb.SearchItem) {
        if item.kind == "track" { queue(item) } else { play(item, shuffle: false) }
    }

    /// Debounced search; `delay` 0 = Enter. Under 2 characters clears the results.
    private func run(_ text: String, delay: Double) {
        query = text
        pending?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { results = nil; searching = false; return }
        let w = DispatchWorkItem {
            searching = true
            web.search(q) { r in
                searching = false
                guard q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }   // field changed since (e.g. cleared)
                if let r { results = r; expanded = [] }   // nil: api() put the error in the caption
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func queue(_ item: SpotifyWeb.SearchItem) {
        model.enqueue(item.uri) { ok in
            guard ok else { return }
            status = "Queued: \(item.title)"
            clearTask?.cancel()
            let w = DispatchWorkItem { status = "" }
            clearTask = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
        }
    }

    private func play(_ item: SpotifyWeb.SearchItem, shuffle: Bool) {
        guard !busy else { return }
        busy = true
        let done: (Bool) -> Void = { ok in
            busy = false
            if ok { model.closeSlideOver() }   // failure: the caption explains, panel stays
        }
        if item.kind == "track" { web.playTrack(item.uri, done: done) }
        else if shuffle { web.shufflePlay(item.uri, done: done) }
        else { web.playContext(item.uri, done: done) }
    }
}

/// 36 pt queue thumbnail. Loaded once per URL into a process-lifetime cache (smallest Spotify
/// image, ~64 px, a few KB each, so no eviction; upgrade path: NSCache if memory ever shows it).
private struct QueueThumb: View {
    let url: String
    var round = false   // artists
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
        .clipShape(RoundedRectangle(cornerRadius: round ? 18 : 5, style: .continuous))
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

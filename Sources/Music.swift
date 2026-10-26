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
    /// Apple Music mode ("musicSource": "applemusic"): Music.app's playerInfo notification + AppleScript.
    /// Opening the tab never launches Music (every script checks `is running` first); play/pause may.
    let appleMusic = musicSource == "applemusic"
    @Published var shuffleOn = false        // applemusic: Music's `shuffle enabled`
    @Published var repeatMode = "off"       // applemusic: Music's `song repeat` (off | one | all)
    @Published var musicPlaylists: [LibraryItem] = []   // applemusic: Playlists slide-over
    @Published var musicBusy = false        // applemusic: a library script is running
    @Published var musicCaption = ""        // applemusic: library errors, shown by the slide-overs
    private var musicTrackKey = ""          // applemusic: name/artist/album of the shown track (artwork reload)
    private var exportSub: AnyCancellable?  // nowplaying.json for SketchyBar (all sources)
    @Published var musicNext: [LibraryItem] = []   // applemusic: next tracks of the current playlist (up to 25)
    @Published var musicNextNote = ""       // applemusic: muted caption instead of the list (shuffle on)
    var musicNextKey = ""                   // track|shuffle|repeat the list was last read for
    var musicNextGen = 0                    // drops stale list reads
    private var positionBase: Double = 0     // last real position we were told…
    private var positionAt = Date.distantPast  // …and when; the 1.5 s timer extrapolates from these

    private var timer: Timer?
    private var artURL: String?
    private var lastNotification: Date?   // Spotify's own PlaybackStateChanged — needs no Automation grant

    init() {
        startNowPlayingExport()
        if spotifyd { watchSpotifydState(); startWatchdog(); return }
        if appleMusic {   // posted by Music on every play/pause/track change; needs no Automation grant
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
            ) { [weak self] n in self?.applyMusicNotification(n.userInfo) }
            return
        }
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
            web?.noteContext(trackID: trackID)   // context may have changed without a track change
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
        if appleMusic { musicNextKey = "" }   // tab open: re-read Next in playlist on the first refresh
    }

    func stopPolling() { timer?.invalidate(); timer = nil; tabOpen = false; queuePending?.cancel() }

    /// spotifyd: refresh "Next" — on tab open, after track changes, `start` events and a session
    /// reconnect while the tab is open. No timer. A failed or empty read while playing retries at
    /// +2 s, then +5 s (max 2 per trigger; a newer trigger supersedes the chain): after a session
    /// drop Spotify answers empty/errors for a while and nothing else would re-ask.
    private var tabOpen = false
    private var queuePending: DispatchWorkItem?
    private var queueGen = 0             // bumped per trigger: stale responses don't schedule retries
    private var emptyQueueStreak = 0     // consecutive 200-with-empty answers
    private static let queueRetryDelays: [Double] = [2, 5]

    private func refreshQueue(after delay: Double = 0, retry: Int = 0) {
        guard let web, web.hasToken else { return }
        queuePending?.cancel()
        if retry == 0 { queueGen += 1 }
        let gen = queueGen
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.tabOpen else { return }
            web.queue { [weak self] items in
                guard let self, self.applyQueue(items), gen == self.queueGen, self.tabOpen, self.isPlaying,
                      retry < Self.queueRetryDelays.count else { return }
                self.refreshQueue(after: Self.queueRetryDelays[retry], retry: retry + 1)
            }
        }
        queuePending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Apply one queue read; returns true when it was a failure or empty (worth a retry). A failed
    /// call never touches the list; an empty one clears it only on the second empty 200 in a row.
    @discardableResult
    private func applyQueue(_ items: [SpotifyWeb.QueueItem]?) -> Bool {
        guard let items else { return true }
        if items.isEmpty {
            emptyQueueStreak += 1
            if emptyQueueStreak >= 2 { setQueue([]) }
            return true
        }
        emptyQueueStreak = 0
        setQueue(items)
        return false
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

    /// Shuffle toggle; on success re-read Up next at 0.8 s and 2.5 s (Spotify reorders the queue
    /// server-side and its response lags). No local reorder: the list shows what Spotify returns.
    func toggleShuffle() {
        web?.toggleShuffle { [weak self] ok in
            guard ok, let self, let web = self.web else { return }
            for delay in [0.8, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.tabOpen else { return }
                    web.queue { [weak self] items in self?.applyQueue(items) }
                }
            }
        }
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
        resumeArmed = nil
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
        if appleMusic, !musicRunning { applyMusicApp([]); return }   // no osascript spawn while Music is closed
        guard !inFlight else { return }   // Spotify not answering AppleEvents must not stack osascripts every 1.5 s
        inFlight = true
        let script = appleMusic ? musicInfoScript : infoScript
        let am = appleMusic
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = NowPlayingModel.runOSA(script) ?? ""
            let lines = out.components(separatedBy: "\n")
            DispatchQueue.main.async { self?.inFlight = false; if am { self?.applyMusicApp(lines) } else { self?.apply(lines) } }
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
        guard !spotifyd, !appleMusic, !restarting else { return }
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
        resumeArmed = nil   // a user action wins over auto-resume
        if let web {
            let wantPlay = !isPlaying
            lastAction = (wantPlay, Date())
            wantPlay ? web.play() : web.pause()
        } else { control("playpause", launch: appleMusic) }   // Apple Music: the play button may launch Music
    }

    // MARK: spotifyd watchdog (see SpotifydWatchdog.swift)
    private var watchdog: SpotifydWatchdog?
    private var lastAction: (play: Bool, at: Date)?   // last play/pause press
    private var lastMissAt = Date.distantPast         // last "device not found" from the Web API

    private func startWatchdog() {
        guard let web, !spotifydLaunchLabel.isEmpty else { return }
        let w = SpotifydWatchdog(label: spotifydLaunchLabel, web: web)
        w.onRecovered = { [weak self] in
            // A play/pause that failed with "not found" while the tab is open: retry it once.
            guard let self, let a = self.lastAction, self.tabOpen, self.lastMissAt >= a.at,
                  Date().timeIntervalSince(a.at) < 120, let web = self.web else { return }
            self.lastAction = nil
            a.play ? web.play() : web.pause()
        }
        web.onDeviceMissing = { [weak self, weak w] in
            self?.lastMissAt = Date()
            w?.schedule(after: 0)
        }
        watchdog = w
    }
    func next()      { resumeArmed = nil; if let web { web.next() } else { control("next track") } }
    func previous()  { resumeArmed = nil; if let web { web.previous() } else { control("previous track") } }

    private func control(_ cmd: String, launch: Bool = false) {
        let app = appleMusic ? "Music" : "Spotify"
        let script = launch ? "tell application \"\(app)\" to \(cmd)"
                            : "if application \"\(app)\" is running then tell application \"\(app)\" to \(cmd)"
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
        let volumeBefore = volume   // the drop event may already carry the fresh player's volume
        if let v = Double(str("VOLUME")) { volume = min(1, max(0, v / 65535)) }

        noteSessionEvent(event, at: at, volumeBefore: volumeBefore)
        // Fields persist in the file, so only the event that carries them is fresh. REPEAT: none|all|track.
        if event == "shuffle_changed", let web { web.shuffleState = str("SHUFFLE") == "true" }
        if event == "repeat_changed", let web { web.repeatState = ["all": "context", "track": "track"][str("REPEAT")] ?? "off" }
        learnVolume(before: volumeBefore)
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
            web?.noteContext(trackID: id)   // playlist/album context for auto-resume
            if tabOpen, ["change", "load", "start"].contains(event) { refreshQueue(after: 2) }   // Spotify's queue lags the change
        } else if tabOpen, event == "start" {
            refreshQueue(after: 2)   // same track restarted (auto-resume, play after pause): the queue may have been read mid-drop
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

    // MARK: auto-resume after a session drop
    // spotifyd issue #1306: Spotify resets the session mid-song (sessiondisconnected), spotifyd
    // reconnects by itself (sessionconnected), but playback stays stopped. Arm on the disconnect
    // while playing, fire once on the reconnect (or 5 s after the drop if it never comes).
    // ponytail: one attempt per drop and a 60 s window; a drop that takes longer to heal is left
    // alone (the user may have moved on). Upgrade path: retry with backoff if one try proves too few.
    private var resumeArmed: (trackID: String, positionMs: Int, volumePercent: Int?, at: Date)?
    private var resumeFallback: DispatchWorkItem?

    private func noteSessionEvent(_ event: String, at: Date, volumeBefore: Double?) {
        switch event {
        case "sessiondisconnected":
            // Re-reads of the same file see isPlaying already false, so this arms once per drop.
            // A repeat disconnect while armed keeps the first timestamp: the 60 s window counts
            // from the original drop, not the latest one.
            guard spotifyAutoResume, resumeArmed == nil, isPlaying, let web, web.hasToken, !trackID.isEmpty else { return }
            tick()   // the event carries POSITION_MS=0: take the extrapolated position instead
            resumeArmed = (trackID, Int(positionSec * 1000), Self.lastVolume ?? volumeBefore.map { Int(($0 * 100).rounded()) }, Date())
            resumeFallback?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.fireResume() }
            resumeFallback = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
        case "sessionconnected":
            connectedAt = Date()
            if resumeArmed != nil { fireResume() }   // the resume restores lastVolume itself
            else if let v = Self.lastVolume, let web, web.hasToken { web.restoreVolume(v) }
            if tabOpen, let web, web.hasToken {   // a read during the drop came back empty/failed: re-read once the device is back
                web.waitForDevice(named: web.deviceName) { [weak self] d in
                    guard d != nil, let self, self.tabOpen else { return }
                    self.refreshQueue(after: 1)
                }
            }
        case "start":
            resumeArmed = nil   // playing again by other means (spotifyd itself, another client)
        default: break
        }
    }

    // MARK: remembered volume
    // A spotifyd PROCESS restart (launchd kickstart, upgrade, reboot) starts a fresh player at its
    // initial_volume and emits sessionconnected + volumeset with no disconnect, so the pre-drop
    // volume above never exists. Remember the user's last deliberate volume instead: learned while
    // a track plays, ignored for 10 s after a sessionconnected (the fresh player's default, and our
    // own restore, land there), put back on every sessionconnected.
    // ponytail: "deliberate" = changed while playing outside that window; a volume changed while
    // paused isn't learned. Upgrade path: tag Kajo's own setVolume calls if that ever matters.
    private static let lastVolumeKey = "spotify.lastVolume"
    static var lastVolume: Int? { UserDefaults.standard.object(forKey: lastVolumeKey) as? Int }
    private var connectedAt = Date.distantPast

    private func learnVolume(before: Double?) {
        guard let v = volume, v != before, isPlaying, Date().timeIntervalSince(connectedAt) > 10 else { return }
        UserDefaults.standard.set(Int((v * 100).rounded()), forKey: Self.lastVolumeKey)
    }

    private func fireResume() {
        resumeFallback?.cancel(); resumeFallback = nil
        guard let r = resumeArmed else { return }
        resumeArmed = nil   // one attempt per arm
        guard let web else { return }
        guard Date().timeIntervalSince(r.at) < 60 else { if let v = r.volumePercent { web.restoreVolume(v) }; return }   // too late to resume, still fix the volume
        web.resumeAfterDrop(trackID: r.trackID, positionMs: r.positionMs, volumePercent: r.volumePercent)
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

// MARK: - nowplaying.json export (SketchyBar's music item, any source)
// <kajoConfigDir>/nowplaying.json = {"source","playing","title","artist","album","ts"}, written tmp + rename
// only when the track or play state changed (position ticks never write), then
// `sketchybar --trigger kajo_nowplaying`. Stopped / nothing loaded = playing false, empty strings.

extension NowPlayingModel {
    private struct Exported: Equatable { let playing: Bool; let title: String; let artist: String; let album: String }

    fileprivate func startNowPlayingExport() {
        exportSub = Publishers.CombineLatest(Publishers.CombineLatest4($hasTrack, $isPlaying, $title, $artist), $album)
            .map { a, album in
                a.0 ? Exported(playing: a.1, title: a.2, artist: a.3, album: album)
                    : Exported(playing: false, title: "", artist: "", album: "")
            }
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)   // a refresh sets the fields one by one
            .removeDuplicates()
            .sink { e in DispatchQueue.global(qos: .utility).async { Self.writeNowPlaying(e) } }
    }

    private static func writeNowPlaying(_ e: Exported) {
        let obj: [String: Any] = ["source": musicSource, "playing": e.playing, "title": e.title,
                                  "artist": e.artist, "album": e.album, "ts": Int(Date().timeIntervalSince1970)]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        let path = kajoConfigDir + "/nowplaying.json"
        let tmp = path + ".tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data),
              rename(tmp, path) == 0 else { return }
        let bar = "/opt/homebrew/bin/sketchybar"
        guard FileManager.default.isExecutableFile(atPath: bar) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bar)
        p.arguments = ["--trigger", "kajo_nowplaying"]
        try? p.run()
    }
}

// MARK: - Apple Music source ("musicSource": "applemusic")
// Now playing comes from Music's `com.apple.Music.playerInfo` distributed notification (keys "Player
// State" Playing/Paused/Stopped, "Name", "Artist", "Album", "Total Time" ms; no position), so the ear
// works without an Automation grant. Position, volume, shuffle/repeat and artwork come from
// AppleScript while the tab is open; denial (-1743/-1744) surfaces as ERR<code> like the Spotify path.

/// A Music library row (playlist or track) for the slide-overs; `id` = Music's persistent ID.
struct LibraryItem: Identifiable { let id: String; let title: String; let detail: String }

extension NowPlayingModel {
    static let musicID = "com.apple.Music"
    static let automationSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
    static let musicDeniedText = "Allow Kajo to control Music in System Settings → Privacy & Security → Automation."

    var musicRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Self.musicID).isEmpty }

    fileprivate var musicInfoScript: String { """
    set out to ""
    try
    \tif application "Music" is running then
    \t\ttell application "Music"
    \t\t\tset ps to player state as string
    \t\t\tset out to ps & linefeed & (sound volume as text) & linefeed & (shuffle enabled as text) & linefeed & (song repeat as text)
    \t\t\tif ps is not "stopped" then
    \t\t\t\tset t to current track
    \t\t\t\tset out to out & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & ((duration of t) as text) & linefeed & ((player position) as text)
    \t\t\tend if
    \t\tend tell
    \tend if
    on error errMsg number errNum
    \treturn "ERR" & errNum
    end try
    return out
    """ }

    private func clearMusicTrack() {
        hasTrack = false; isPlaying = false
        title = ""; artist = ""; album = ""; artwork = nil; musicTrackKey = ""
        setPosition(0, duration: 0)
        musicNext = []; musicNextNote = ""; musicNextKey = ""
    }

    fileprivate func applyMusicNotification(_ info: [AnyHashable: Any]?) {
        guard let info else { return }
        #if DEBUG
        NSLog("Kajo: com.apple.Music.playerInfo %@", info.description)
        #endif
        lastNotification = Date()
        let state = (info["Player State"] as? String ?? "").lowercased()
        guard state != "stopped", let name = info["Name"] as? String, !name.isEmpty else { clearMusicTrack(); return }
        tick()   // bring the extrapolated position up to now before the play state flips
        hasTrack = true
        isPlaying = state == "playing"
        title = name
        artist = info["Artist"] as? String ?? ""
        album = info["Album"] as? String ?? ""
        let dur = ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000
        let key = "\(name)\u{1}\(artist)\u{1}\(album)"
        if key != musicTrackKey {
            musicTrackKey = key
            artwork = nil
            setPosition(0, duration: dur)
            loadMusicArtwork(key)
        } else {
            setPosition(positionSec, duration: dur > 0 ? dur : durationSec)   // no position in the notification: keep the extrapolated one
        }
        if timer != nil { refresh() }   // tab open: read the real position now
    }

    fileprivate func applyMusicApp(_ lines: [String]) {
        if let first = lines.first, first.hasPrefix("ERR") {
            automationDenied = ["ERR-1743", "ERR-1744"].contains(first) && musicRunning
            tick()
            return
        }
        automationDenied = false
        guard lines.count >= 4, !lines[0].isEmpty else { clearMusicTrack(); return }   // Music not running
        volume = Double(lines[1]).map { min(1, max(0, $0 / 100)) }
        shuffleOn = lines[2] == "true"
        repeatMode = lines[3]
        guard lines.count >= 9 else { clearMusicTrack(); return }   // stopped
        func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }   // Finnish locale: 235,19
        hasTrack = true
        isPlaying = lines[0] == "playing"
        title = lines[4]; artist = lines[5]; album = lines[6]
        setPosition(num(lines[8]), duration: num(lines[7]))
        let key = "\(title)\u{1}\(artist)\u{1}\(album)"
        if key != musicTrackKey { musicTrackKey = key; artwork = nil; loadMusicArtwork(key) }
        // Track change (the notification triggers this refresh), shuffle/repeat toggle or tab open.
        let nextKey = "\(key)\u{1}\(shuffleOn)\u{1}\(repeatMode)"
        if timer != nil, nextKey != musicNextKey { musicNextKey = nextKey; loadMusicNext() }
    }

    // MARK: Next in playlist
    // ponytail: Music's real Up Next queue isn't scriptable, so this is the rest of `current playlist`
    // after the current track (playlist order; unchecked tracks skipped; `song repeat` all wraps).
    // With shuffle on Music doesn't reveal its shuffled order, so only a caption shows.
    // Upgrade path: none via AppleScript; MusicKit's ApplicationMusicPlayer.queue is a different player.
    private static let musicNextScript = """
    set out to ""
    try
    \tif application "Music" is not running then return ""
    \ttell application "Music"
    \t\tif player state is stopped then return ""
    \t\tif shuffle enabled then return "SHUFFLE"
    \t\tset rep to song repeat as string
    \t\ttry
    \t\t\tset p to current playlist
    \t\ton error
    \t\t\treturn ""
    \t\tend try
    \t\tset cid to persistent ID of current track
    \t\tset ids to persistent ID of every track of p
    \t\tset n to count of ids
    \t\tset idx to 0
    \t\ttry
    \t\t\tset i to index of current track
    \t\t\tif i ≤ n and item i of ids is cid then set idx to i
    \t\tend try
    \t\tif idx is 0 then
    \t\t\trepeat with i from 1 to n
    \t\t\t\tif item i of ids is cid then
    \t\t\t\t\tset idx to i
    \t\t\t\t\texit repeat
    \t\t\t\tend if
    \t\t\tend repeat
    \t\tend if
    \t\tif idx is 0 then return ""
    \t\tset out to "OK" & linefeed
    \t\tset got to 0
    \t\tset i to idx
    \t\trepeat (n - 1) times
    \t\t\tset i to i + 1
    \t\t\tif i > n then
    \t\t\t\tif rep is not "all" then exit repeat
    \t\t\t\tset i to 1
    \t\t\tend if
    \t\t\tset t to track i of p
    \t\t\tif enabled of t then
    \t\t\t\tset out to out & (item i of ids) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & linefeed
    \t\t\t\tset got to got + 1
    \t\t\t\tif got ≥ 25 then exit repeat
    \t\t\tend if
    \t\tend repeat
    \tend tell
    on error errMsg number errNum
    \treturn "ERR" & errNum
    end try
    return out
    """

    /// One osascript off the main thread (~0.1–0.2 s for a 50-track playlist). Errors, no playlist
    /// context or a track outside it → no list.
    private func loadMusicNext() {
        musicNextGen += 1
        let gen = musicNextGen
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = NowPlayingModel.runOSA(Self.musicNextScript)?.trimmingCharacters(in: .newlines) ?? ""
            DispatchQueue.main.async {
                guard let self, gen == self.musicNextGen else { return }
                self.musicNextNote = out == "SHUFFLE" ? "Shuffle is on — Music doesn't reveal the shuffled order" : ""
                guard out.hasPrefix("OK") else { self.musicNext = []; return }
                self.musicNext = out.split(separator: "\n").dropFirst().map { $0.components(separatedBy: "\t") }
                    .filter { $0.count >= 3 }
                    .map { r in LibraryItem(id: r[0], title: r[1], detail: [r[2], r.count > 3 ? r[3] : ""].filter { !$0.isEmpty }.joined(separator: " · ")) }
            }
        }
    }

    /// Row click / "Play now": play that track of the current playlist, keeping the playlist context.
    func playMusicNext(_ id: String) { playMusic("first track of current playlist whose persistent ID is (item 1 of argv)", id) }
    func revealMusicNext(_ id: String) {
        control("reveal (first track of current playlist whose persistent ID is \"\(id.filter { $0.isHexDigit })\")")
        AppLauncher.open(Self.musicID)   // bring Music forward to show it (closes the panel)
    }

    /// Thumbnail for a Next row (~0.1 s per track, measured), serialised so 25 rows don't fire 25
    /// osascripts at once; `QueueThumb` caches the result by persistent ID.
    private static let musicArtQueue = DispatchQueue(label: "kajo.music-next-art", qos: .utility)
    static func musicTrackArtwork(_ id: String) async -> NSImage? {
        let script = """
        on run argv
        \ttry
        \t\ttell application "Music"
        \t\t\tset t to first track of current playlist whose persistent ID is (item 1 of argv)
        \t\t\tif (count of artworks of t) is 0 then return "NOART"
        \t\t\tset d to raw data of artwork 1 of t
        \t\tend tell
        \t\tset f to open for access (POSIX file (item 2 of argv)) with write permission
        \t\tset eof f to 0
        \t\twrite d to f
        \t\tclose access f
        \t\treturn "OK"
        \ton error errMsg number errNum
        \t\ttry
        \t\t\tclose access (POSIX file (item 2 of argv))
        \t\tend try
        \t\treturn "ERR" & errNum
        \tend try
        end run
        """
        return await withCheckedContinuation { cont in
            musicArtQueue.async {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: musicID).isEmpty else { cont.resume(returning: nil); return }
                let path = NSTemporaryDirectory() + "kajo-music-next-\(UUID().uuidString)"
                let out = shell("/usr/bin/osascript", ["-e", script, id, path])?.trimmingCharacters(in: .whitespacesAndNewlines)
                var img: NSImage?
                if out == "OK", let full = NSImage(contentsOfFile: path),   // shrink: the files are ~1200 px
                   let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 72, pixelsHigh: 72, bitsPerSample: 8,
                                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0),
                   let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    full.draw(in: NSRect(x: 0, y: 0, width: 72, height: 72))
                    NSGraphicsContext.restoreGraphicsState()
                    let small = NSImage(size: NSSize(width: 72, height: 72))
                    small.addRepresentation(rep)
                    img = small
                }
                try? FileManager.default.removeItem(atPath: path)
                cont.resume(returning: img)
            }
        }
    }

    /// Cover art: Music writes `raw data of artwork 1` to a temp file (osascript can't hand binary
    /// back on stdout). No art, an error or a denied grant → the iTunes Search fallback.
    private func loadMusicArtwork(_ key: String) {
        let path = NSTemporaryDirectory() + "kajo-music-art-\(UUID().uuidString)"
        let script = """
        on run argv
        \ttry
        \t\tif application "Music" is running then
        \t\t\ttell application "Music"
        \t\t\t\tif player state is stopped then return ""
        \t\t\t\tif (count of artworks of current track) is 0 then return "NOART"
        \t\t\t\tset d to raw data of artwork 1 of current track
        \t\t\tend tell
        \t\t\tset f to open for access (POSIX file (item 1 of argv)) with write permission
        \t\t\tset eof f to 0
        \t\t\twrite d to f
        \t\t\tclose access f
        \t\t\treturn "OK"
        \t\tend if
        \ton error errMsg number errNum
        \t\ttry
        \t\t\tclose access (POSIX file (item 1 of argv))
        \t\tend try
        \t\treturn "ERR" & errNum
        \tend try
        \treturn ""
        end run
        """
        let (t, a, al) = (title, artist, album)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = shell("/usr/bin/osascript", ["-e", script, path])?.trimmingCharacters(in: .whitespacesAndNewlines)
            let img = out == "OK" ? NSImage(contentsOfFile: path) : nil
            try? FileManager.default.removeItem(atPath: path)
            DispatchQueue.main.async {
                guard let self, self.musicTrackKey == key else { return }
                if let img { self.artwork = img } else { self.fetchArtworkFallback(track: t, artist: a, album: al) }
            }
        }
    }

    // MARK: controls (optimistic; the 0.25 s refresh in control() corrects them)
    func setMusicVolume(_ v: Double) { volume = v; control("set sound volume to \(Int((v * 100).rounded()))") }
    func seekMusic(to fraction: Double) {
        guard durationSec > 0 else { return }
        let s = min(durationSec, max(0, fraction * durationSec))
        setPosition(s, duration: durationSec)
        control("set player position to \(s)")
    }
    func toggleMusicShuffle() { shuffleOn.toggle(); control("set shuffle enabled to \(shuffleOn)") }
    func cycleMusicRepeat() {
        repeatMode = ["off": "all", "all": "one"][repeatMode] ?? "off"
        control("set song repeat to \(repeatMode)")
    }

    // MARK: library (Playlists / Search slide-overs)
    /// Run a library script (argv passed separately, so queries need no escaping); ERR codes → caption.
    private func musicScript(_ script: String, _ args: [String] = [], done: @escaping (String?) -> Void) {
        guard musicRunning else { musicCaption = "Music isn't running."; done(nil); return }
        musicBusy = true; musicCaption = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = shell("/usr/bin/osascript", ["-e", script] + args)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ERR"
            DispatchQueue.main.async {
                self?.musicBusy = false
                guard out.hasPrefix("ERR") else { done(out); return }
                self?.musicCaption = ["ERR-1743", "ERR-1744"].contains(out) ? Self.musicDeniedText : "Music didn't answer (\(out.dropFirst(3)))."
                done(nil)
            }
        }
    }

    private func rows(_ out: String) -> [[String]] {
        out.split(separator: "\n").map { $0.components(separatedBy: "\t") }.filter { $0.count >= 3 }
    }

    /// `user playlists whose special kind is none`: drops the Library ("Music") and folders.
    func loadMusicPlaylists() {
        let script = """
        set out to ""
        try
        \ttell application "Music"
        \t\trepeat with p in (get user playlists whose special kind is none)
        \t\t\tset out to out & (persistent ID of p) & tab & (name of p) & tab & ((count of tracks of p) as text) & linefeed
        \t\tend repeat
        \tend tell
        on error errMsg number errNum
        \treturn "ERR" & errNum
        end try
        return out
        """
        musicScript(script) { [weak self] out in
            guard let out, let self else { return }
            self.musicPlaylists = self.rows(out).map { LibraryItem(id: $0[0], title: $0[1], detail: "\($0[2]) tracks") }
        }
    }

    /// Library song search, first 25 hits.
    func searchMusic(_ q: String, done: @escaping ([LibraryItem]?) -> Void) {
        let script = """
        on run argv
        \tset out to ""
        \ttry
        \t\ttell application "Music"
        \t\t\tset r to search library playlist 1 for (item 1 of argv) only songs
        \t\t\tset n to count of r
        \t\t\tif n > 25 then set n to 25
        \t\t\trepeat with i from 1 to n
        \t\t\t\tset t to item i of r
        \t\t\t\tset out to out & (persistent ID of t) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & linefeed
        \t\t\tend repeat
        \t\tend tell
        \ton error errMsg number errNum
        \t\treturn "ERR" & errNum
        \tend try
        \treturn out
        end run
        """
        musicScript(script, [q]) { [weak self] out in
            guard let out, let self else { done(nil); return }
            done(self.rows(out).map { r in
                LibraryItem(id: r[0], title: r[1], detail: [r[2], r.count > 3 ? r[3] : ""].filter { !$0.isEmpty }.joined(separator: " · "))
            })
        }
    }

    func playMusicPlaylist(_ id: String) { playMusic("first user playlist whose persistent ID is (item 1 of argv)", id) }
    func playMusicTrack(_ id: String) { playMusic("first track of library playlist 1 whose persistent ID is (item 1 of argv)", id) }

    private func playMusic(_ ref: String, _ id: String) {
        let script = """
        on run argv
        \ttry
        \t\ttell application "Music" to play (\(ref))
        \ton error errMsg number errNum
        \t\treturn "ERR" & errNum
        \tend try
        \treturn "OK"
        end run
        """
        musicScript(script, [id]) { [weak self] out in
            if out != nil { self?.closeSlideOver(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refresh() } }
        }
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
                } else if model.appleMusic {
                    if model.automationDenied { musicDeniedNotice } else { MusicAppControls(model: model) }
                    // ponytail: Music.app's Up Next isn't scriptable; NEXT IN PLAYLIST is the rest of the current
                    // playlist instead. No device picker either: AirPlay routing is scriptable (`AirPlay devices`,
                    // `current AirPlay devices`); upgrade path = a picker over those.
                    if !model.automationDenied { MusicNextList(model: model) }
                    openSpotifyButton   // under the list, which takes the height left (else right under the controls)
                    Spacer(minLength: 0)
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
                if let web = model.web { SpotifydControls(model: model, web: web) }
                else if model.appleMusic {
                    if model.automationDenied { musicDeniedNotice } else { MusicAppControls(model: model) }
                    openSpotifyButton
                } else { openSpotifyButton }
                Spacer()
                if let web = model.web { SpotifyLinkField(model: model, web: web) }
            }
        }
    }

    private var openSpotifyButton: some View {
        Button { AppLauncher.open(model.appleMusic ? NowPlayingModel.musicID : "com.spotify.client") } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.forward.app")
                Text(model.appleMusic ? "Open Music" : "Open Spotify")
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
            .frame(height: 4)
            .frame(maxHeight: .infinity)   // centred in a 14 pt hit area
            .contentShape(Rectangle())
            .onTapGesture { loc in if model.appleMusic { model.seekMusic(to: loc.x / max(1, geo.size.width)) } }   // click to seek (Apple Music only)
        }
        .frame(height: 14)
        .padding(.vertical, -5)   // lays out as the old 4 pt bar
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

    /// Apple Music: AppleEvents to Music refused (-1743/-1744). Unlike Spotify this is a real TCC denial.
    private var musicDeniedNotice: some View {
        VStack(spacing: 8) {
            Text(NowPlayingModel.musicDeniedText)
                .font(.caption).foregroundStyle(Gruv.fg2).multilineTextAlignment(.center)
            Button { AppLauncher.openURL(NowPlayingModel.automationSettingsURL) } label: {
                Text("Open Automation settings")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Gruv.yellow)
                    .padding(.vertical, 7).padding(.horizontal, 16)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Gruv.yellow.opacity(0.15)))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
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
                    .animation(.easeInOut, value: model.upNext.map(\.uri))   // reshuffle after the shuffle toggle
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

/// Apple Music mode: the rest of the current playlist (Music's own Up Next isn't scriptable), in the
/// UP NEXT look. Rows are lazy so artwork is only fetched for rows scrolled into view.
struct MusicNextList: View {
    @ObservedObject var model: NowPlayingModel

    var body: some View {
        if !model.musicNextNote.isEmpty {
            Text(model.musicNextNote).font(.caption).foregroundStyle(Gruv.gray)
                .multilineTextAlignment(.center).padding(.top, 4)
        } else if !model.musicNext.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(text: "NEXT IN PLAYLIST")
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.musicNext) { t in
                            MediaRow(title: t.title, detail: t.detail, imageURL: "applemusic:\(t.id)", hoverSymbol: "play.fill") { model.playMusicNext(t.id) }
                                .contextMenu {
                                    // ponytail: no "Play next" — Music's Up Next isn't scriptable.
                                    Button("Play now") { model.playMusicNext(t.id) }
                                    Button("Reveal in Music") { model.revealMusicNext(t.id) }
                                }
                        }
                    }
                    .padding(.bottom, 10)   // last row clears the fade below
                }
                .mask(VStack(spacing: 0) {
                    Color.white
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom).frame(height: 14)
                })
            }
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
        if web.hasToken { SlideOverToggle(model: model, kind: kind, symbol: symbol, help: help) }
    }
}

/// The header-row slide-over button itself (Apple Music uses it directly: no token to wait for).
struct SlideOverToggle: View {
    @ObservedObject var model: NowPlayingModel
    let kind: NowPlayingModel.SlideOver
    let symbol: String
    let help: String

    var body: some View {
        Button { model.toggleSlideOver(kind) } label: {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(model.slideOver == kind ? Gruv.aqua : Gruv.fg4)
                .frame(width: 26, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
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
    let caption: String   // web.caption (spotifyd) or model.musicCaption (Apple Music)
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
            if !caption.isEmpty {
                Text(caption).font(.caption).foregroundStyle(Gruv.orange).lineLimit(2)
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
        SlideOverPanel(model: model, caption: web.caption, title: "Playlists", busy: web.playlistsLoading || busy) {
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
        SlideOverPanel(model: model, caption: web.caption, title: playlist.name, busy: loading || busy, onBack: { model.showPlaylist(nil) }) {
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
        SlideOverPanel(model: model, caption: web.caption, title: "Search", busy: searching || busy) {
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
        if url.hasPrefix("applemusic:") {   // Next in playlist: art comes from Music by persistent ID, placeholder if none
            guard let img = await NowPlayingModel.musicTrackArtwork(String(url.dropFirst(11))), !Task.isCancelled else { return }
            Self.cache[url] = img
            image = img
            return
        }
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
        HStack(spacing: 22) {
            mode("shuffle", on: web.shuffleState == true) { model.toggleShuffle() }
            ctrl("backward.fill") { model.previous() }
            ctrl(model.isPlaying ? "pause.fill" : "play.fill", size: 30) { model.playPause() }
            ctrl("forward.fill") { model.next() }
            mode(web.repeatState == "track" ? "repeat.1" : "repeat", on: (web.repeatState ?? "off") != "off") { web.cycleRepeat() }
        }
    }

    private func mode(_ symbol: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        TransportToggle(symbol: symbol, on: on, action: action)
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

/// Shuffle / repeat toggle in the transport row: green when on, fg4 when off (spotifyd + Apple Music).
struct TransportToggle: View {
    let symbol: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Gruv.green : Gruv.fg4).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

/// Apple Music transport: shuffle · previous · play/pause · next · repeat (off → all → one), and
/// Music's own volume (0–100) once the first AppleScript read reported it.
struct MusicAppControls: View {
    @ObservedObject var model: NowPlayingModel
    @State private var vol: Double = 0.5

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 22) {
                TransportToggle(symbol: "shuffle", on: model.shuffleOn) { model.toggleMusicShuffle() }
                ctrl("backward.fill") { model.previous() }
                ctrl(model.isPlaying ? "pause.fill" : "play.fill", size: 30) { model.playPause() }
                ctrl("forward.fill") { model.next() }
                TransportToggle(symbol: model.repeatMode == "one" ? "repeat.1" : "repeat", on: model.repeatMode != "off") { model.cycleMusicRepeat() }
            }
            if model.volume != nil {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(Gruv.gray)
                    Slider(value: $vol, in: 0...1) { editing in if !editing { model.setMusicVolume(vol) } }
                        .tint(Gruv.green)
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(Gruv.gray)
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.top, 4)
        .onAppear { if let v = model.volume { vol = v } }
        .onChange(of: model.volume) { _, v in if let v { vol = v } }
    }

    private func ctrl(_ symbol: String, size: CGFloat = 20, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(Gruv.fg1).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
    }
}

/// Apple Music: user playlists (no Library, no folders) with a filter. Click = play it and close.
struct MusicPlaylistsPanel: View {
    @ObservedObject var model: NowPlayingModel
    @State private var filter = ""

    private var shown: [LibraryItem] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        return f.isEmpty ? model.musicPlaylists : model.musicPlaylists.filter { $0.title.localizedCaseInsensitiveContains(f) }
    }

    var body: some View {
        SlideOverPanel(model: model, caption: model.musicCaption, title: "Playlists", busy: model.musicBusy) {
            if !model.musicPlaylists.isEmpty {
                Text("\(model.musicPlaylists.count)").font(.caption.monospacedDigit()).foregroundStyle(Gruv.gray)
            }
        } content: {
            FieldBox(symbol: "line.3.horizontal.decrease") {
                LinkTextField(placeholder: "Filter playlists", onSubmit: { _ in false }, onChange: { filter = $0 })
            }
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(shown) { p in
                        MediaRow(title: p.title, detail: p.detail, imageURL: "", hoverSymbol: "play.fill") { model.playMusicPlaylist(p.id) }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .onAppear { model.loadMusicPlaylists() }
    }
}

/// Apple Music: library song search (350 ms debounce, 2+ characters, first 25). Click = play the track.
struct MusicSearchPanel: View {
    @ObservedObject var model: NowPlayingModel
    @State private var query = ""
    @State private var results: [LibraryItem]?
    @State private var pending: DispatchWorkItem?

    var body: some View {
        SlideOverPanel(model: model, caption: model.musicCaption, title: "Search", busy: model.musicBusy) {
            EmptyView()
        } content: {
            FieldBox(symbol: "magnifyingglass") {
                LinkTextField(placeholder: "Songs in your library", onSubmit: { text in run(text, delay: 0); return false },
                              onChange: { text in run(text, delay: 0.35) }, autoFocus: true)
            }
            if let results {
                if results.isEmpty {
                    Text("No songs for \u{201C}\(query)\u{201D}").font(.caption).foregroundStyle(Gruv.gray)
                        .frame(maxWidth: .infinity).padding(.top, 12)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(results) { t in
                                MediaRow(title: t.title, detail: t.detail, imageURL: "", hoverSymbol: "play.fill") { model.playMusicTrack(t.id) }
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
            } else if query.trimmingCharacters(in: .whitespaces).count < 2 {
                Text("Type at least two characters").font(.caption).foregroundStyle(Gruv.gray)
                    .frame(maxWidth: .infinity).padding(.top, 12)
            }
        }
        .onDisappear { pending?.cancel() }
    }

    private func run(_ text: String, delay: Double) {
        query = text
        pending?.cancel()
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { results = nil; return }
        let w = DispatchWorkItem {
            model.searchMusic(q) { r in
                guard q == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }   // field changed since
                if let r { results = r }   // nil: the caption says why
            }
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }
}

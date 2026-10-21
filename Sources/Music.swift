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
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
            return
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

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
        if id != trackID { trackID = id; artist = ""; album = ""; positionAt = .distantPast }   // new track starts at 0 unless the event says otherwise
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
            }
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
                if let web = model.web { SpotifydControls(model: model, web: web) }
                else if model.automationDenied { deniedNotice } else { controls }
                if !model.spotifyd { openSpotifyButton }
                Spacer()
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

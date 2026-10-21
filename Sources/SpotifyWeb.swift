import AppKit
import Network
import CryptoKit

// Spotify Web API controls for the spotifyd source ("musicSource": "spotifyd"). spotifyd is a
// headless Connect player, so play/pause/next go through Spotify's cloud and come back to it.
// OAuth = Authorization Code + PKCE (no client secret): the app's client ID comes from config.json
// "spotifyClientID", and the Spotify dashboard must list the redirect URI below exactly
// (Spotify rejects "localhost"; loopback IP literals are allowed). Tokens live in
// <kajoConfigDir>/spotify-token.json, mode 0600, and are refreshed on demand.
// Deliberately no HTTP abstraction: one URLSession call per endpoint, captions on failure.

final class SpotifyWeb: ObservableObject {
    static let port: NWEndpoint.Port = 8899
    static let redirect = "http://127.0.0.1:8899/callback"
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative playlist-modify-private playlist-modify-public"

    let clientID = spotifyClientID
    let deviceName = spotifyDevice
    @Published var hasToken = false
    @Published var connecting = false
    @Published var caption = ""
    @Published var playlists: [Playlist] = []
    @Published var playlistsLoading = false
    private var playlistsAt: Date?
    @Published var devices: [Device] = []
    @Published var devicesLoading = false

    /// The stored token was granted the playlist scopes (tokens from before 0.39 carry no scope → false).
    var canReadPlaylists: Bool { token?.scope?.split(separator: " ").contains("playlist-read-private") ?? false }
    /// The stored token may edit playlists (tokens from before 0.43 lack the modify scopes → Reconnect).
    var canEditPlaylists: Bool {
        let s = token?.scope?.split(separator: " ") ?? []
        return s.contains("playlist-modify-private") && s.contains("playlist-modify-public")
    }
    /// Current user's id from GET /me (owner check for "Remove from playlist"), cached for the session.
    @Published var userID: String?

    private struct Token: Codable { var access_token: String; var refresh_token: String; var expires_at: Double; var scope: String? }
    private var token: Token?
    private let tokenURL = URL(fileURLWithPath: kajoConfigDir + "/spotify-token.json")
    private var listener: NWListener?
    private var verifier = ""
    private var oauthState = ""
    private var refreshWaiters: [(String?) -> Void] = []   // calls queued behind one in-flight refresh

    init() {
        if let d = try? Data(contentsOf: tokenURL), let t = try? JSONDecoder().decode(Token.self, from: d) {
            token = t; hasToken = true
        }
    }

    // MARK: OAuth (PKCE + one-shot loopback listener)

    func connect() {
        guard !clientID.isEmpty, !connecting else { return }
        verifier = Self.randomString(64)
        oauthState = Self.randomString(16)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback   // never reachable from the LAN
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: Self.port)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] s in
                if case .failed(let e) = s { DispatchQueue.main.async { self?.finishConnect("listener on 8899 failed: \(e)") } }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            caption = "can't listen on 127.0.0.1:8899: \(error.localizedDescription)"; return
        }
        connecting = true
        caption = "finish the login in the browser…"
        // Abandoned logins must not hold the port forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in
            guard let self, self.connecting else { return }
            self.finishConnect("login timed out")
        }
        var c = URLComponents(string: "https://accounts.spotify.com/authorize")!
        c.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: Self.redirect), .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge),
            .init(name: "state", value: oauthState),
        ]
        AppLauncher.openURL(c.url!.absoluteString)
    }

    private func finishConnect(_ message: String) {
        listener?.cancel(); listener = nil
        connecting = false
        caption = message
    }

    /// Minimal HTTP: read the request line, answer, close. Anything but /callback (favicon…) gets a 404.
    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let path = parts.count >= 2 ? String(parts[1]) : ""
            guard path.hasPrefix("/callback"), let q = URLComponents(string: "http://127.0.0.1" + path)?.queryItems else {
                Self.reply(conn, status: "404 Not Found", body: "not found"); return
            }
            func item(_ n: String) -> String? { q.first { $0.name == n }?.value }
            guard let self else { Self.reply(conn, status: "200 OK", body: "Kajo is gone."); return }
            if let err = item("error") {
                Self.reply(conn, status: "200 OK", body: "Spotify said: \(err). You can close this tab.")
                self.finishConnect("login refused: \(err)"); return
            }
            guard item("state") == self.oauthState, let code = item("code") else {
                Self.reply(conn, status: "400 Bad Request", body: "state mismatch"); return
            }
            Self.reply(conn, status: "200 OK", body: "Done, return to Kajo. You can close this tab.")
            self.listener?.cancel(); self.listener = nil
            self.tokenRequest(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect,
                               "client_id": self.clientID, "code_verifier": self.verifier]) { ok in
                self.connecting = false
                self.caption = ok ? "" : self.caption
            }
        }
    }

    private static func reply(_ conn: NWConnection, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><title>Kajo</title><body style=\"font:16px -apple-system;background:#282828;color:#ebdbb2;padding:3em\">\(body)"
        let resp = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    /// POST /api/token (code exchange or refresh); stores the token and reports success on main.
    private func tokenRequest(_ form: [String: String], done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").utf8)
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            DispatchQueue.main.async {
                guard let self else { return }
                guard let access = j["access_token"] as? String else {
                    let why = (j["error_description"] as? String) ?? (j["error"] as? String) ?? err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
                    self.caption = "Spotify token: \(why)"
                    if j["error"] as? String == "invalid_grant" { self.forget() }   // revoked / rotated away: reconnect
                    done(false); return
                }
                // PKCE refresh tokens rotate: keep the new one when sent, else the old one stays valid.
                let refresh = (j["refresh_token"] as? String) ?? self.token?.refresh_token ?? ""
                let exp = Date().timeIntervalSince1970 + ((j["expires_in"] as? Double) ?? 3600)
                let t = Token(access_token: access, refresh_token: refresh, expires_at: exp,
                              scope: (j["scope"] as? String) ?? self.token?.scope)
                if form["grant_type"] == "authorization_code" { self.userID = nil }   // maybe another account now
                self.token = t; self.hasToken = true
                if let d = try? JSONEncoder().encode(t) { try? writePrivate(d, to: self.tokenURL) }
                done(true)
            }
        }.resume()
    }

    private func forget() {
        token = nil; hasToken = false
        try? FileManager.default.removeItem(at: tokenURL)
    }

    /// A valid access token (refreshing when within a minute of expiry), nil after a failed refresh.
    private func withToken(force: Bool = false, _ f: @escaping (String?) -> Void) {
        guard let t = token else { f(nil); return }
        if !force, t.expires_at > Date().timeIntervalSince1970 + 60 { f(t.access_token); return }
        refreshWaiters.append(f)
        guard refreshWaiters.count == 1 else { return }
        tokenRequest(["grant_type": "refresh_token", "refresh_token": t.refresh_token, "client_id": clientID]) { [weak self] ok in
            guard let self else { return }
            let w = self.refreshWaiters; self.refreshWaiters = []
            w.forEach { $0(ok ? self.token?.access_token : nil) }
        }
    }

    // MARK: Web API

    /// One call to api.spotify.com/v1; a 401 refreshes once and retries. `done` gets status + body on main.
    /// `quiet` calls (background reads) never touch the caption.
    private func api(_ method: String, _ path: String, json: [String: Any]? = nil, retried: Bool = false, quiet: Bool = false,
                     done: @escaping (Int, Data?) -> Void = { _, _ in }) {
        withToken(force: retried) { [weak self] access in
            guard let self else { return }
            guard let access else { done(0, nil); return }
            var req = URLRequest(url: URL(string: "https://api.spotify.com/v1" + path)!)
            req.httpMethod = method
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            if let json {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: json)
            } else if method != "GET" {
                req.httpBody = Data()   // PUT/POST without a body still wants Content-Length: 0
            }
            URLSession.shared.dataTask(with: req) { data, resp, err in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                DispatchQueue.main.async {
                    if code == 401, !retried { self.api(method, path, json: json, retried: true, quiet: quiet, done: done); return }
                    if quiet {}
                    else if code == 0 { self.caption = err?.localizedDescription ?? "network error" }
                    else if code >= 300 {
                        let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        let msg = (j?["error"] as? [String: Any])?["message"] as? String
                        self.caption = "Spotify: " + (msg ?? "HTTP \(code)")
                    } else { self.caption = "" }
                    done(code, data)
                }
            }.resume()
        }
    }

    /// Resume on the configured device; if it isn't the active one, transfer playback to it.
    func play() {
        api("GET", "/me/player/devices") { [weak self] code, data in
            guard let self, code == 200 else { return }
            let devices = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["devices"] as? [[String: Any]]) ?? []
            guard let dev = devices.first(where: { ($0["name"] as? String) == self.deviceName }), let id = dev["id"] as? String else {
                self.caption = "device \"\(self.deviceName)\" not found (is spotifyd running?)"; return
            }
            if dev["is_active"] as? Bool == true {
                self.api("PUT", "/me/player/play?device_id=\(id)")
            } else {
                self.api("PUT", "/me/player", json: ["device_ids": [id], "play": true])
            }
        }
    }

    /// Last playback context seen for a track (GET /me/player): the playlist/album to resume in,
    /// plus shuffle/repeat. `contextURI` is nil when Spotify reports none (e.g. a lone track).
    struct PlaybackContext { let trackID: String; let contextURI: String?; let shuffle: Bool?; let repeatState: String? }
    private(set) var lastContext: PlaybackContext?

    /// Quietly reads /me/player and remembers its context when it is playing `trackID`. The Web API
    /// lags spotifyd's track change, so a mismatch retries after 2 s (twice at most).
    func noteContext(trackID: String, attempt: Int = 1) {
        guard hasToken, !trackID.isEmpty else { return }
        api("GET", "/me/player", quiet: true) { [weak self] code, data in
            guard let self, code == 200,
                  let j = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
            guard (j["item"] as? [String: Any])?["id"] as? String == trackID else {
                if attempt < 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.noteContext(trackID: trackID, attempt: attempt + 1) } }
                return
            }
            self.lastContext = PlaybackContext(trackID: trackID,
                                               contextURI: (j["context"] as? [String: Any])?["uri"] as? String,
                                               shuffle: j["shuffle_state"] as? Bool,
                                               repeatState: j["repeat_state"] as? String)
        }
    }

    /// After a resume: put shuffle/repeat back to what `ctx` saw, only where /me/player now differs.
    private func restoreModes(_ ctx: PlaybackContext?, deviceID id: String) {
        guard let ctx, ctx.shuffle != nil || ctx.repeatState != nil else { return }
        api("GET", "/me/player", quiet: true) { [weak self] code, data in
            guard let self, code == 200,
                  let j = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
            if let want = ctx.shuffle, j["shuffle_state"] as? Bool != want {
                self.api("PUT", "/me/player/shuffle?state=\(want)&device_id=\(id)", quiet: true)
            }
            if let want = ctx.repeatState, j["repeat_state"] as? String != want {
                self.api("PUT", "/me/player/repeat?state=\(want)&device_id=\(id)", quiet: true)
            }
        }
    }

    /// spotifyd session drop healed but playback stayed stopped: if nothing plays anywhere, start
    /// the configured device again — same track → transfer + play (seek only when > 5 s off),
    /// another or no track loaded → play `trackID` at `positionMs`, inside its remembered playlist/
    /// album context when `noteContext` saw one (else as a lone track, which stops at its end).
    /// Shuffle/repeat are put back afterwards when they differ. Errors → caption.
    /// After spotifyd rebuilds its session the device is missing from /me/player/devices for a few
    /// seconds, so the lookup polls once a second for up to 15 s before captioning "not found";
    /// /me/player is read after the device is back so the "nothing plays" check is fresh.
    /// spotifyd's fresh player starts at its config initial_volume, so once the device is back
    /// `volumePercent` (the volume before the drop) is restored on it when it differs by > 2 —
    /// after a successful resume, or right away when something already plays (user pressed play).
    // ponytail: "nothing plays" is judged from one GET /me/player; a client that starts playing a
    // second later gets overridden by the transfer. Acceptable for a one-shot within 60 s of the drop.
    func resumeAfterDrop(trackID: String, positionMs: Int, volumePercent: Int?) {
        guard hasToken else { return }
        waitForDevice(named: deviceName, tries: 15) { [weak self] d in
            guard let self else { return }
            guard let d, let id = d.deviceID else { self.caption = "device \"\(self.deviceName)\" not found (is spotifyd running?)"; return }
            let restoreVolume = {
                guard let v = volumePercent, abs((d.volume ?? -100) - v) > 2 else { return }
                self.setVolume(v, deviceID: id)   // by device id: another device may be the active one
            }
            self.api("GET", "/me/player", quiet: true) { code, data in
                guard code == 200 || code == 204 else { return }   // 204 = no active device
                let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if j?["is_playing"] as? Bool == true { restoreVolume(); return }   // playing here or elsewhere: leave playback
                let loaded = (j?["item"] as? [String: Any])?["id"] as? String
                let progress = j?["progress_ms"] as? Int ?? 0
                let ctx = self.lastContext?.trackID == trackID ? self.lastContext : nil
                let resumed = {   // after api() cleared the caption
                    self.caption = "Resumed after a Spotify disconnect"; restoreVolume(); self.restoreModes(ctx, deviceID: id)
                }
                if loaded != trackID {
                    let uri = "spotify:track:\(trackID)"
                    let body: [String: Any] = ctx?.contextURI.map { ["context_uri": $0, "offset": ["uri": uri], "position_ms": positionMs] }
                        ?? ["uris": [uri], "position_ms": positionMs]
                    self.api("PUT", "/me/player/play?device_id=\(id)", json: body) { code, _ in
                        if code > 0, code < 300 { resumed() }
                    }
                    return
                }
                self.api("PUT", "/me/player", json: ["device_ids": [id], "play": true]) { code, _ in
                    guard code > 0, code < 300 else { return }
                    guard abs(progress - positionMs) > 5000 else { resumed(); return }
                    self.api("PUT", "/me/player/seek?position_ms=\(positionMs)&device_id=\(id)") { code, _ in
                        if code > 0, code < 300 { resumed() }
                    }
                }
            }
        }
    }

    func pause()    { api("PUT", "/me/player/pause") }
    func next()     { api("POST", "/me/player/next") }
    func previous() { api("POST", "/me/player/previous") }
    func setVolume(_ percent: Int, deviceID: String? = nil) {
        api("PUT", "/me/player/volume?volume_percent=\(max(0, min(100, percent)))" + (deviceID.map { "&device_id=\($0)" } ?? ""))
    }

    /// Skip forward n tracks, one POST after another so Spotify sees them in order.
    // Ceiling: the Web API has no "play queue item N" endpoint, so jumping into the queue is
    // n × next. Upgrade path if Spotify ever adds one: replace the loop with that call.
    func skip(_ n: Int) {
        guard n > 0 else { return }
        api("POST", "/me/player/next") { [weak self] code, _ in
            guard code < 300, code > 0 else { return }
            self?.skip(n - 1)
        }
    }

    struct QueueItem: Equatable {
        let title: String; let artist: String; let imageURL: String
        let uri: String     // spotify:track:<id> / spotify:episode:<id>
        let link: String    // https://open.spotify.com/... (empty when Spotify sent neither)
    }

    /// The whole play queue as Spotify returns it (tracks or episodes, up to ~20). Silent on failure.
    func queue(done: @escaping ([QueueItem]) -> Void) {
        guard hasToken else { return }
        api("GET", "/me/player/queue", quiet: true) { code, data in
            guard code == 200,
                  let r = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  let items = r["queue"] as? [[String: Any]] else { return }
            done(items.compactMap { j in
                guard let name = j["name"] as? String, !name.isEmpty else { return nil }
                let artists = ((j["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                let show = (j["show"] as? [String: Any])?["name"] as? String
                // Tracks carry art on album.images, episodes on images; take the smallest (thumbnail).
                let imgs = ((j["album"] as? [String: Any])?["images"] as? [[String: Any]]) ?? (j["images"] as? [[String: Any]]) ?? []
                let thumb = imgs.min { ($0["width"] as? Int ?? .max) < ($1["width"] as? Int ?? .max) }?["url"] as? String
                let uri = j["uri"] as? String ?? ""
                var link = (j["external_urls"] as? [String: Any])?["spotify"] as? String ?? ""
                let parts = uri.split(separator: ":")   // spotify:<type>:<id>
                if link.isEmpty, parts.count == 3 { link = "https://open.spotify.com/\(parts[1])/\(parts[2])" }
                return QueueItem(title: name, artist: artists.isEmpty ? (show ?? "") : artists.joined(separator: ", "),
                                 imageURL: thumb ?? "", uri: uri, link: link)
            })
        }
    }

    /// Add `uri` to the user queue, which plays right after the current track. Targets the
    /// configured device when it is listed (else Spotify's active one). Errors → caption.
    // Ceiling: there is no move/reorder endpoint, so a queue row added this way also stays at its
    // old position in the context queue. Upgrade path if Spotify ever adds one: move instead of add.
    func addToQueue(_ uri: String, done: @escaping (Bool) -> Void) {
        guard hasToken, !uri.isEmpty else { done(false); return }
        withDeviceID { [weak self] id in
            let enc = uri.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? uri
            self?.api("POST", "/me/player/queue?uri=\(enc)" + (id.map { "&device_id=\($0)" } ?? "")) { code, _ in
                done(code > 0 && code < 300)
            }
        }
    }

    /// Play an album/playlist now on the configured device (else the active one). Errors → caption.
    func playContext(_ uri: String, done: @escaping (Bool) -> Void) {
        guard hasToken else { done(false); return }
        withDeviceID { [weak self] id in
            self?.api("PUT", "/me/player/play" + (id.map { "?device_id=\($0)" } ?? ""), json: ["context_uri": uri]) { code, _ in
                done(code > 0 && code < 300)
            }
        }
    }

    /// Shuffle on, then play `uri` — both on the configured device (else the active one). Errors → caption.
    func shufflePlay(_ uri: String, done: @escaping (Bool) -> Void) {
        guard hasToken else { done(false); return }
        withDeviceID { [weak self] id in
            let dev = id.map { "&device_id=\($0)" } ?? ""
            self?.api("PUT", "/me/player/shuffle?state=true" + dev) { code, _ in
                guard code > 0, code < 300 else { done(false); return }
                self?.api("PUT", "/me/player/play" + (id.map { "?device_id=\($0)" } ?? ""), json: ["context_uri": uri]) { code, _ in
                    done(code > 0 && code < 300)
                }
            }
        }
    }

    /// Play one track/episode now (`{"uris":[uri]}`) on the configured device (else the active one). Errors → caption.
    func playTrack(_ uri: String, done: @escaping (Bool) -> Void) {
        guard hasToken, !uri.isEmpty else { done(false); return }
        withDeviceID { [weak self] id in
            self?.api("PUT", "/me/player/play" + (id.map { "?device_id=\($0)" } ?? ""), json: ["uris": [uri]]) { code, _ in
                done(code > 0 && code < 300)
            }
        }
    }

    // MARK: Search

    /// One search hit. `kind` is track / artist / album / playlist; `detail` is the row's caption.
    struct SearchItem: Identifiable, Equatable {
        let kind: String; let title: String; let detail: String
        let imageURL: String; let uri: String; let link: String
        var id: String { uri }
    }
    struct SearchResults: Equatable {
        var tracks: [SearchItem] = []; var artists: [SearchItem] = []
        var albums: [SearchItem] = []; var playlists: [SearchItem] = []
        var isEmpty: Bool { tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty }
    }

    private var searchSeq = 0

    /// GET /search for tracks, artists, albums and playlists. Only the newest call's answer reaches
    /// `done` (older ones are dropped by sequence number); nil = failed (api() set the caption).
    // limit=10: Spotify caps search at 10 per type for development-mode apps since Feb 2026 (a 2026-10-21
    // live search returned 10 of each). Upgrade path if the app ever gets extended quota: raise it.
    func search(_ q: String, done: @escaping (SearchResults?) -> Void) {
        guard hasToken else { done(nil); return }
        searchSeq += 1
        let seq = searchSeq
        let enc = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        api("GET", "/search?q=\(enc)&type=track,album,artist,playlist&limit=10") { [weak self] code, data in
            guard let self, seq == self.searchSeq else { return }   // stale: a newer search is in flight
            guard code == 200, let j = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { done(nil); return }
            done(Self.searchResults(j))
        }
    }

    /// /search response → SearchResults. Spotify sends null items (seen in playlists); they are skipped. Pure.
    static func searchResults(_ j: [String: Any]) -> SearchResults {
        func items(_ key: String) -> [[String: Any]] { ((j[key] as? [String: Any])?["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] } }
        func thumb(_ x: [String: Any]?) -> String {
            let imgs = (x?["images"] as? [[String: Any]]) ?? []
            return imgs.min { ($0["width"] as? Int ?? .max) < ($1["width"] as? Int ?? .max) }?["url"] as? String ?? ""
        }
        func artists(_ x: [String: Any]?) -> String {
            ((x?["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        }
        func item(_ x: [String: Any], kind: String, detail: String, image: String) -> SearchItem? {
            guard let uri = x["uri"] as? String, let name = x["name"] as? String, !name.isEmpty else { return nil }
            var link = (x["external_urls"] as? [String: Any])?["spotify"] as? String ?? ""
            let p = uri.split(separator: ":")
            if link.isEmpty, p.count == 3 { link = "https://open.spotify.com/\(p[1])/\(p[2])" }
            return SearchItem(kind: kind, title: name, detail: detail, imageURL: image, uri: uri, link: link)
        }
        var r = SearchResults()
        r.tracks = items("tracks").compactMap { t in
            let album = (t["album"] as? [String: Any])
            let d = [artists(t), album?["name"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return item(t, kind: "track", detail: d, image: thumb(album))
        }
        r.artists = items("artists").compactMap { item($0, kind: "artist", detail: "Artist", image: thumb($0)) }
        r.albums = items("albums").compactMap { a in
            let year = String((a["release_date"] as? String ?? "").prefix(4))
            return item(a, kind: "album", detail: [artists(a), year].filter { !$0.isEmpty }.joined(separator: " · "), image: thumb(a))
        }
        r.playlists = items("playlists").compactMap { p in
            item(p, kind: "playlist", detail: ((p["owner"] as? [String: Any])?["display_name"] as? String) ?? "", image: thumb(p))
        }
        return r
    }

    // MARK: Playlists

    struct Playlist: Identifiable, Equatable {
        let id: String; let name: String; let uri: String; let owner: String
        var ownerID = ""; var snapshotID = ""
        let total: Int?; let imageURL: String
        var link: String { "https://open.spotify.com/playlist/\(id)" }
    }

    /// The user's playlists (GET /me/playlists, following `next` up to 200), cached in memory for
    /// 5 minutes. No playlist scope → nothing (the panel shows Reconnect). Errors → caption.
    // Liked Songs is not listed: the play endpoint documents albums, artists and playlists as the
    // only valid contexts. Upgrade path if Spotify ever accepts spotify:user:<id>:collection: a pinned row.
    func loadPlaylists(force: Bool = false) {
        guard hasToken, canReadPlaylists, !playlistsLoading else { return }
        if !force, let at = playlistsAt, Date().timeIntervalSince(at) < 300 { return }
        playlistsLoading = true
        fetchPlaylists("/me/playlists?limit=50", into: [])
    }

    private func fetchPlaylists(_ path: String, into acc: [Playlist]) {
        api("GET", path) { [weak self] code, data in
            guard let self else { return }
            guard code == 200, let r = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
                self.playlistsLoading = false; return
            }
            let page = ((r["items"] as? [[String: Any]]) ?? []).compactMap(Self.playlist)
            let all = acc + page
            let base = "https://api.spotify.com/v1"
            if all.count < 200, let next = r["next"] as? String, next.hasPrefix(base) {
                self.fetchPlaylists(String(next.dropFirst(base.count)), into: all); return
            }
            self.playlists = Array(all.prefix(200))
            self.playlistsAt = Date()
            self.playlistsLoading = false
        }
    }

    /// One /me/playlists item → Playlist. The track count sits under `tracks.total`, or `items.total`
    /// after Spotify's 2026 rename; both are read. Pure.
    static func playlist(_ j: [String: Any]) -> Playlist? {
        guard let id = j["id"] as? String, let uri = j["uri"] as? String else { return nil }
        let total = ((j["tracks"] as? [String: Any])?["total"] as? Int) ?? ((j["items"] as? [String: Any])?["total"] as? Int)
        let imgs = (j["images"] as? [[String: Any]]) ?? []
        let thumb = imgs.min { ($0["width"] as? Int ?? .max) < ($1["width"] as? Int ?? .max) }?["url"] as? String
        let owner = j["owner"] as? [String: Any]
        return Playlist(id: id, name: (j["name"] as? String) ?? "", uri: uri,
                        owner: (owner?["display_name"] as? String) ?? "",
                        ownerID: (owner?["id"] as? String) ?? "", snapshotID: (j["snapshot_id"] as? String) ?? "",
                        total: total, imageURL: thumb ?? "")
    }

    /// GET /me once per session → userID (quiet; nil stays nil on failure and the next call retries).
    func loadMe() {
        guard hasToken, userID == nil else { return }
        api("GET", "/me", quiet: true) { [weak self] code, data in
            guard code == 200, let j = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return }
            self?.userID = j["id"] as? String
        }
    }

    // MARK: Playlist tracks

    struct PlaylistTrack: Identifiable {
        let id = UUID()   // playlists may hold the same track twice, so the uri is no identity
        let title: String; let detail: String; let imageURL: String
        let uri: String; let link: String
    }

    /// A playlist's tracks + current snapshot id: GET /playlists/{id}?fields=snapshot_id, then
    /// GET /playlists/{id}/items (Feb 2026 rename; falls back to /tracks on a 404) following `next`
    /// up to 500. nil = failed (api() set the caption).
    // Ceiling: 500 rows. Upgrade path for bigger playlists: page on scroll instead of up front.
    func playlistTracks(_ playlistID: String, done: @escaping ((tracks: [PlaylistTrack], snapshot: String)?) -> Void) {
        guard hasToken else { done(nil); return }
        api("GET", "/playlists/\(playlistID)?fields=snapshot_id", quiet: true) { [weak self] _, data in
            let snap = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["snapshot_id"] as? String) ?? ""
            self?.fetchTracks("/playlists/\(playlistID)/items?limit=100", fallback: "/playlists/\(playlistID)/tracks?limit=100", into: []) { t in
                done(t.map { ($0, snap) })
            }
        }
    }

    private func fetchTracks(_ path: String, fallback: String?, into acc: [PlaylistTrack], done: @escaping ([PlaylistTrack]?) -> Void) {
        api("GET", path) { [weak self] code, data in   // a 404 caption is cleared by the fallback's success
            guard let self else { return }
            if code == 404, let fallback { self.fetchTracks(fallback, fallback: nil, into: acc, done: done); return }
            guard code == 200, let r = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { done(nil); return }
            let all = acc + ((r["items"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.compactMap(Self.playlistTrack)
            let base = "https://api.spotify.com/v1"
            if all.count < 500, let next = r["next"] as? String, next.hasPrefix(base) {
                self.fetchTracks(String(next.dropFirst(base.count)), fallback: nil, into: all, done: done); return
            }
            done(Array(all.prefix(500)))
        }
    }

    /// One playlist item → PlaylistTrack. The track sits under `item` (2026 API, verified 2026-10-21)
    /// or `track` (older shape; in the new one `item.track` is a flag, hence dict casts). Local files
    /// and null items are skipped (no playable URI). Pure.
    static func playlistTrack(_ j: [String: Any]) -> PlaylistTrack? {
        guard j["is_local"] as? Bool != true,
              let t = (j["item"] as? [String: Any]) ?? (j["track"] as? [String: Any]),
              let uri = t["uri"] as? String, !uri.hasPrefix("spotify:local:"),
              let name = t["name"] as? String, !name.isEmpty else { return nil }
        let album = t["album"] as? [String: Any]
        let artists = ((t["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", ")
        let imgs = (album?["images"] as? [[String: Any]]) ?? (t["images"] as? [[String: Any]]) ?? []
        let thumb = imgs.min { ($0["width"] as? Int ?? .max) < ($1["width"] as? Int ?? .max) }?["url"] as? String
        var link = (t["external_urls"] as? [String: Any])?["spotify"] as? String ?? ""
        let p = uri.split(separator: ":")
        if link.isEmpty, p.count == 3 { link = "https://open.spotify.com/\(p[1])/\(p[2])" }
        let detail = [artists, album?["name"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return PlaylistTrack(title: name, detail: detail, imageURL: thumb ?? "", uri: uri, link: link)
    }

    /// Play `contextURI` starting at `trackURI` on the configured device (else the active one). Errors → caption.
    func playFromPlaylist(_ contextURI: String, track trackURI: String, done: @escaping (Bool) -> Void) {
        guard hasToken else { done(false); return }
        withDeviceID { [weak self] id in
            self?.api("PUT", "/me/player/play" + (id.map { "?device_id=\($0)" } ?? ""),
                      json: ["context_uri": contextURI, "offset": ["uri": trackURI]]) { code, _ in
                done(code > 0 && code < 300)
            }
        }
    }

    /// DELETE /playlists/{id}/items `{"items":[{"uri"}], "snapshot_id"}` (docs checked 2026-10-21;
    /// the old /tracks takes the same under "tracks", tried on a 404). `done` gets the new snapshot
    /// id, nil on failure (api() set the caption).
    // Ceiling: Spotify removes every occurrence of the uri; position-based removal is gone from the
    // API. Upgrade path if positions return: send the row's index.
    func removeFromPlaylist(_ playlistID: String, uri: String, snapshot: String, done: @escaping (String?) -> Void) {
        guard hasToken, !uri.isEmpty else { done(nil); return }
        func body(_ key: String) -> [String: Any] {
            var b: [String: Any] = [key: [["uri": uri]]]
            if !snapshot.isEmpty { b["snapshot_id"] = snapshot }
            return b
        }
        api("DELETE", "/playlists/\(playlistID)/items", json: body("items")) { [weak self] code, data in
            if code == 404 {
                self?.api("DELETE", "/playlists/\(playlistID)/tracks", json: body("tracks")) { code, data in done(Self.snapshot(code, data)) }
                return
            }
            done(Self.snapshot(code, data))
        }
        playlistsAt = nil   // track counts changed: reload the list next time it opens
    }

    /// POST /playlists/{id}/items `{"uris":[uri], "position"}` (Undo; /tracks on a 404). New snapshot id or nil.
    func addToPlaylist(_ playlistID: String, uri: String, position: Int, done: @escaping (String?) -> Void) {
        guard hasToken, !uri.isEmpty else { done(nil); return }
        let body: [String: Any] = ["uris": [uri], "position": position]
        api("POST", "/playlists/\(playlistID)/items", json: body) { [weak self] code, data in
            if code == 404 {
                self?.api("POST", "/playlists/\(playlistID)/tracks", json: body) { code, data in done(Self.snapshot(code, data)) }
                return
            }
            done(Self.snapshot(code, data))
        }
        playlistsAt = nil
    }

    private static func snapshot(_ code: Int, _ data: Data?) -> String? {
        guard code > 0, code < 300 else { return nil }
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["snapshot_id"] as? String) ?? ""
    }

    /// The configured device's id when Spotify lists it, else nil (quiet lookup).
    private func withDeviceID(_ f: @escaping (String?) -> Void) {
        api("GET", "/me/player/devices", quiet: true) { [weak self] _, data in
            let devices = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["devices"] as? [[String: Any]]) ?? []
            f(devices.first { ($0["name"] as? String) == self?.deviceName }?["id"] as? String)
        }
    }

    // MARK: Devices

    struct Device: Identifiable, Equatable {
        let deviceID: String?   // Spotify sends null for some restricted devices
        let name: String; let type: String
        let isActive: Bool; let isRestricted: Bool; let volume: Int?
        var id: String { deviceID ?? "name:" + name }
        var selectable: Bool { !isRestricted && deviceID != nil }
    }

    /// Connect devices Spotify currently lists (GET /me/player/devices). Quiet: refreshes the
    /// device-button tint on tab open as well as the picker's rows.
    func loadDevices(done: (([Device]) -> Void)? = nil) {
        guard hasToken else { done?([]); return }
        devicesLoading = true
        api("GET", "/me/player/devices", quiet: true) { [weak self] code, data in
            guard let self else { return }
            self.devicesLoading = false
            guard code == 200 else { done?([]); return }
            let list = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["devices"] as? [[String: Any]]) ?? []
            self.devices = list.map { j in
                Device(deviceID: j["id"] as? String, name: (j["name"] as? String) ?? "", type: (j["type"] as? String) ?? "",
                       isActive: j["is_active"] as? Bool ?? false, isRestricted: j["is_restricted"] as? Bool ?? false,
                       volume: j["volume_percent"] as? Int)
            }
            done?(self.devices)
        }
    }

    /// After a zeroconf addUser: re-read the device list once a second until `name` is listed
    /// and selectable, giving up after `tries` reads (nil).
    func waitForDevice(named name: String, tries: Int = 10, done: @escaping (Device?) -> Void) {
        loadDevices { [weak self] list in
            if let d = list.first(where: { $0.name == name && $0.selectable }) { done(d); return }
            guard tries > 1 else { done(nil); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.waitForDevice(named: name, tries: tries - 1, done: done) }
        }
    }

    /// Something other than the configured device is the active one (button tint).
    var playingElsewhere: Bool { devices.contains { $0.isActive && $0.name != deviceName } }

    /// Transfer playback to `d` and start playing. Success → "Playing on <name>" caption; errors → caption.
    func transfer(to d: Device, done: @escaping (Bool) -> Void) {
        guard hasToken, d.selectable, let id = d.deviceID else { done(false); return }
        api("PUT", "/me/player", json: ["device_ids": [id], "play": true]) { [weak self] code, _ in
            let ok = code > 0 && code < 300
            if ok { self?.caption = "Playing on \(d.name)" }   // set after api() cleared it on success
            done(ok)
        }
    }

    // MARK: Pasted links

    /// `kind` is track / episode / album / playlist.
    struct Ref: Equatable { let kind: String; let id: String; var uri: String { "spotify:\(kind):\(id)" } }

    /// open.spotify.com URLs (incl. /intl-xx/ and ?si=) and spotify:<kind>:<id> URIs → Ref. Pure.
    static func parseRef(_ text: String) -> Ref? {
        let kinds = ["track", "episode", "album", "playlist"]
        let ok: (String) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("spotify:") {
            let p = t.split(separator: ":").map(String.init)
            return p.count == 3 && kinds.contains(p[1]) && ok(p[2]) ? Ref(kind: p[1], id: p[2]) : nil
        }
        guard let u = URL(string: t), ["http", "https"].contains(u.scheme?.lowercased() ?? ""),
              u.host?.lowercased() == "open.spotify.com" else { return nil }
        var c = u.path.split(separator: "/").map(String.init)
        if c.first?.hasPrefix("intl-") == true { c.removeFirst() }
        return c.count >= 2 && kinds.contains(c[0]) && ok(c[1]) ? Ref(kind: c[0], id: c[1]) : nil
    }

    /// spotify.link / spotify.app.link short links (Branch redirects).
    static func isShortLink(_ text: String) -> Bool {
        let h = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
        return h == "spotify.link" || h == "spotify.app.link"
    }

    /// First open.spotify.com item link in an HTML page (the short link's landing page). Pure.
    static func refInHTML(_ html: String) -> Ref? {
        let re = try! NSRegularExpression(pattern: #"https://open\.spotify\.com/(?:intl-[A-Za-z-]+/)?(?:track|episode|album|playlist)/[A-Za-z0-9]+"#)
        guard let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range, in: html) else { return nil }
        return parseRef(String(html[r]))
    }

    /// Follow a short link's redirects; parse the final URL, else the landing page's HTML. nil on main if neither works.
    static func resolveShortLink(_ text: String, done: @escaping (Ref?) -> Void) {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { done(nil); return }
        URLSession.shared.dataTask(with: u) { data, resp, _ in
            let ref = (resp?.url).flatMap { parseRef($0.absoluteString) }
                ?? data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(refInHTML)
            DispatchQueue.main.async { done(ref) }
        }.resume()
    }

    /// Artist + album for a track id (spotifyd's hook only exports the track name). `done(nil)` once
    /// all tries failed (no token, non-200, network error); quiet either way.
    // GET /tracks/{id} (verified 200 with artists on 2026-10-21) is keyed by id, so it has none of
    // currently-playing's track-change lag. Failures retry after 3 s, 3 tries in all.
    func trackInfo(_ id: String, attempt: Int = 1, done: @escaping ((artist: String, album: String)?) -> Void) {
        guard hasToken, !id.isEmpty else { done(nil); return }
        api("GET", "/tracks/\(id)", quiet: true) { [weak self] code, data in
            guard code == 200, let j = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else {
                if attempt < 3, let self {
                    weak var weakSelf = self
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { weakSelf?.trackInfo(id, attempt: attempt + 1, done: done) ?? done(nil) }
                } else { done(nil) }
                return
            }
            let artists = ((j["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            done((artists.joined(separator: ", "), ((j["album"] as? [String: Any])?["name"] as? String) ?? ""))
        }
    }

    // MARK: helpers

    private static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var g = SystemRandomNumberGenerator()
        return String((0..<n).map { _ in chars.randomElement(using: &g)! })
    }

    private static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")   // RFC 3986 unreserved only
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

#if DEBUG
// ponytail: asserts for the pasted-link parser; runs with the other self-checks (`make check` / `make dev`).
func _spotifyLinkSelfCheck() {
    typealias R = SpotifyWeb.Ref
    assert(SpotifyWeb.parseRef("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc") == R(kind: "track", id: "4uLU6hMCjMI75M1A2tKUQC"))
    assert(SpotifyWeb.parseRef(" https://open.spotify.com/intl-fi/track/4uLU6hMCjMI75M1A2tKUQC\n") == R(kind: "track", id: "4uLU6hMCjMI75M1A2tKUQC"))
    assert(SpotifyWeb.parseRef("spotify:episode:512ojhOuo1ktJprKbVcKyQ")?.uri == "spotify:episode:512ojhOuo1ktJprKbVcKyQ")
    assert(SpotifyWeb.parseRef("https://open.spotify.com/album/1DFixLWuPkv3KT3TnV35m3")?.kind == "album")
    assert(SpotifyWeb.parseRef("https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=x")?.kind == "playlist")
    assert(SpotifyWeb.parseRef("https://open.spotify.com/artist/0OdUWJ0sBjDrqHygGUXeCF") == nil)
    assert(SpotifyWeb.parseRef("https://example.com/track/abc") == nil)
    assert(SpotifyWeb.parseRef("hello") == nil)
    assert(SpotifyWeb.isShortLink("https://spotify.link/AbCdEf") && !SpotifyWeb.isShortLink("https://open.spotify.com/track/x"))
    assert(SpotifyWeb.refInHTML("<a href=\"https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=1\">")?.id == "4uLU6hMCjMI75M1A2tKUQC")
    // Search parsing: null items skipped, track caption = artists · album, album caption = artists · year.
    let sr = SpotifyWeb.searchResults([
        "tracks": ["items": [["name": "T", "uri": "spotify:track:t1", "artists": [["name": "A"]], "album": ["name": "Al", "images": []]]]],
        "albums": ["items": [["name": "Al", "uri": "spotify:album:a1", "release_date": "2001-05-15", "artists": [["name": "A"]]]]],
        "playlists": ["items": [NSNull(), ["name": "P", "uri": "spotify:playlist:p1", "owner": ["display_name": "O"]]]],
    ])
    assert(sr.tracks.first?.detail == "A · Al" && sr.tracks.first?.link == "https://open.spotify.com/track/t1")
    assert(sr.albums.first?.detail == "A · 2001" && sr.playlists.map(\.detail) == ["O"] && sr.artists.isEmpty)
    // Playlist items: 2026 `item` key (with the boolean item.track flag), old `track` key, local files skipped.
    let pt = SpotifyWeb.playlistTrack(["is_local": false, "item": ["name": "T", "uri": "spotify:track:t1", "track": true,
                                       "artists": [["name": "A"]], "album": ["name": "Al"]]])
    assert(pt?.detail == "A · Al" && pt?.link == "https://open.spotify.com/track/t1")
    assert(SpotifyWeb.playlistTrack(["track": ["name": "T", "uri": "spotify:track:t2"]])?.uri == "spotify:track:t2")
    assert(SpotifyWeb.playlistTrack(["is_local": true, "track": ["name": "L", "uri": "spotify:local:x"]]) == nil)
    assert(SpotifyWeb.playlistTrack(["item": NSNull()]) == nil)
    assert(SpotifyWeb.playlist(["id": "p", "uri": "spotify:playlist:p", "snapshot_id": "s", "owner": ["id": "u"]])?.ownerID == "u")
}
#endif

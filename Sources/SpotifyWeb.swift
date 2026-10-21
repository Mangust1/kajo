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
    static let scopes = "user-read-playback-state user-modify-playback-state user-read-currently-playing"

    let clientID = spotifyClientID
    let deviceName = spotifyDevice
    @Published var hasToken = false
    @Published var connecting = false
    @Published var caption = ""

    private struct Token: Codable { var access_token: String; var refresh_token: String; var expires_at: Double }
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
                let t = Token(access_token: access, refresh_token: refresh, expires_at: exp)
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
    private func api(_ method: String, _ path: String, json: [String: Any]? = nil, retried: Bool = false,
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
                    if code == 401, !retried { self.api(method, path, json: json, retried: true, done: done); return }
                    if code == 0 { self.caption = err?.localizedDescription ?? "network error" }
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

    func pause()    { api("PUT", "/me/player/pause") }
    func next()     { api("POST", "/me/player/next") }
    func previous() { api("POST", "/me/player/previous") }
    func setVolume(_ percent: Int) { api("PUT", "/me/player/volume?volume_percent=\(max(0, min(100, percent)))") }

    /// Artist + album for a track id (spotifyd's hook only exports the track name). Silent on failure.
    func trackInfo(_ id: String, done: @escaping (String, String) -> Void) {
        guard hasToken, !id.isEmpty else { return }
        // currently-playing, not /tracks/{id}: the Player endpoints survived Spotify's Feb–Mar 2026 Web API cuts.
        api("GET", "/me/player/currently-playing") { code, data in
            guard code == 200,
                  let r = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
                  let j = r["item"] as? [String: Any], (j["id"] as? String) == id else { return }
            let artists = ((j["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            done(artists.joined(separator: ", "), ((j["album"] as? [String: Any])?["name"] as? String) ?? "")
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

import Foundation
import Network
import CryptoKit
import CommonCrypto

// Spotify Connect zeroconf, client side: find Connect speakers on the LAN (Bonjour
// `_spotify-connect._tcp`) and sign one in with spotifyd's cached reusable login ("addUser"),
// so a speaker that isn't on the account yet shows up in GET /me/player/devices.
// Written as the exact inverse of librespot 0.8.0's receiving side: discovery/src/server.rs
// (DH + outer AES-128-CTR/HMAC-SHA1 blob) and core/src/authentication.rs (Credentials::with_blob,
// inner AES-192-ECB blob). The credentials file is read at send time only and never logged.

// MARK: - Minimal bignum: modular exponentiation with UInt32 limbs (Montgomery, CIOS)

enum ZCBig {
    typealias Limbs = [UInt32]   // little-endian limbs

    static func limbs(_ be: [UInt8], count n: Int) -> Limbs {
        var r = Limbs(repeating: 0, count: n)
        for (i, b) in be.reversed().enumerated() where i < 4 * n { r[i / 4] |= UInt32(b) << (8 * UInt32(i % 4)) }
        return r
    }

    /// Big-endian bytes without leading zeros (num-bigint's `to_bytes_be`).
    static func bytes(_ a: Limbs) -> [UInt8] {
        var out: [UInt8] = []
        for l in a.reversed() { for s in stride(from: 24, through: 0, by: -8) { out.append(UInt8(truncatingIfNeeded: l >> UInt32(s))) } }
        let trimmed = Array(out.drop { $0 == 0 })
        return trimmed.isEmpty ? [0] : trimmed
    }

    static func geq(_ a: Limbs, _ b: Limbs) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] { return a[i] > b[i] }
        return true
    }

    static func sub(_ a: Limbs, _ b: Limbs) -> Limbs {   // a - b mod 2^(32n)
        var r = a; var borrow: UInt64 = 0
        for i in 0..<a.count {
            let d = UInt64(a[i]) &- UInt64(b[i]) &- borrow
            r[i] = UInt32(truncatingIfNeeded: d); borrow = (d >> 63) & 1
        }
        return r
    }

    /// a·b·R⁻¹ mod m, R = 2^(32n); m odd, a·b < m·R.
    static func montMul(_ a: Limbs, _ b: Limbs, _ m: Limbs, _ n0: UInt32) -> Limbs {
        let n = m.count
        var t = [UInt32](repeating: 0, count: n + 2)
        for i in 0..<n {
            var c: UInt64 = 0, s: UInt64
            let bi = UInt64(b[i])
            for j in 0..<n {
                s = UInt64(t[j]) + UInt64(a[j]) * bi + c
                t[j] = UInt32(truncatingIfNeeded: s); c = s >> 32
            }
            s = UInt64(t[n]) + c
            t[n] = UInt32(truncatingIfNeeded: s); t[n + 1] = UInt32(s >> 32)
            let q = UInt64(t[0] &* n0)
            c = (UInt64(t[0]) + q * UInt64(m[0])) >> 32
            for j in 1..<max(n, 1) {
                s = UInt64(t[j]) + q * UInt64(m[j]) + c
                t[j - 1] = UInt32(truncatingIfNeeded: s); c = s >> 32
            }
            s = UInt64(t[n]) + c
            t[n - 1] = UInt32(truncatingIfNeeded: s)
            t[n] = t[n + 1] + UInt32(s >> 32)
        }
        var r = Array(t[0..<n])
        if t[n] != 0 || geq(r, m) { r = sub(r, m) }
        return r
    }

    /// base^exp mod m. `exp` big-endian bytes; m odd and its top limb non-zero.
    static func modPow(_ base: Limbs, _ exp: [UInt8], _ m: Limbs) -> Limbs {
        let n = m.count
        var inv: UInt32 = 1   // m⁻¹ mod 2^32 by Newton (5 steps double 1 → 32 correct bits)
        for _ in 0..<5 { inv = inv &* (2 &- m[0] &* inv) }
        let n0 = 0 &- inv
        var one = Limbs(repeating: 0, count: n); one[0] = 1
        var r2 = one   // R² mod m by doubling 64n times
        for _ in 0..<(64 * n) {
            let carry = r2[n - 1] >> 31
            for i in stride(from: n - 1, through: 1, by: -1) { r2[i] = r2[i] << 1 | r2[i - 1] >> 31 }
            r2[0] <<= 1
            if carry != 0 || geq(r2, m) { r2 = sub(r2, m) }
        }
        let x = montMul(base, r2, m, n0)
        var acc = montMul(one, r2, m, n0)
        for byte in exp {
            for bit in stride(from: 7, through: 0, by: -1) {
                acc = montMul(acc, acc, m, n0)
                if (byte >> UInt8(bit)) & 1 == 1 { acc = montMul(acc, x, m, n0) }
            }
        }
        return montMul(acc, one, m, n0)
    }
}

// MARK: - Crypto (librespot's DH group + blob layers)

enum ZCCrypto {
    /// librespot core/src/diffie_hellman.rs DH_PRIME (768-bit MODP group 1), generator 2.
    static let prime: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xc9, 0x0f, 0xda, 0xa2, 0x21, 0x68, 0xc2,
        0x34, 0xc4, 0xc6, 0x62, 0x8b, 0x80, 0xdc, 0x1c, 0xd1, 0x29, 0x02, 0x4e, 0x08, 0x8a, 0x67,
        0xcc, 0x74, 0x02, 0x0b, 0xbe, 0xa6, 0x3b, 0x13, 0x9b, 0x22, 0x51, 0x4a, 0x08, 0x79, 0x8e,
        0x34, 0x04, 0xdd, 0xef, 0x95, 0x19, 0xb3, 0xcd, 0x3a, 0x43, 0x1b, 0x30, 0x2b, 0x0a, 0x6d,
        0xf2, 0x5f, 0x14, 0x37, 0x4f, 0xe1, 0x35, 0x6d, 0x6d, 0x51, 0xc2, 0x45, 0xe4, 0x85, 0xb5,
        0x76, 0x62, 0x5e, 0x7e, 0xc6, 0xf4, 0x4c, 0x42, 0xe9, 0xa6, 0x3a, 0x36, 0x20, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    ]
    static let limbCount = 24

    static func dhPow(_ base: [UInt8], _ exp: [UInt8]) -> [UInt8] {
        ZCBig.bytes(ZCBig.modPow(ZCBig.limbs(base, count: limbCount), exp, ZCBig.limbs(prime, count: limbCount)))
    }

    struct Keys {
        let priv: [UInt8]; let pub: [UInt8]
        static func random() -> Keys {
            var p = [UInt8](repeating: 0, count: 95)   // librespot also draws 95 random bytes
            _ = SecRandomCopyBytes(kSecRandomDefault, p.count, &p)
            return Keys(priv: p, pub: dhPow([2], p))
        }
        func shared(_ remote: [UInt8]) -> [UInt8] { dhPow(remote, priv) }
    }

    static func sha1(_ d: [UInt8]) -> [UInt8] { Array(Insecure.SHA1.hash(data: d)) }
    static func hmac(_ key: [UInt8], _ d: [UInt8]) -> [UInt8] {
        Array(HMAC<Insecure.SHA1>.authenticationCode(for: d, using: SymmetricKey(data: key)))
    }

    static func pbkdf2(_ password: [UInt8], salt: [UInt8], rounds: UInt32, length: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: length)
        let rc = password.withUnsafeBufferPointer { pw in
            pw.withMemoryRebound(to: Int8.self) { pw8 in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw8.baseAddress, pw.count, salt, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), rounds, &out, length)
            }
        }
        return rc == kCCSuccess ? out : []
    }

    /// AES-ECB, no padding; data length must be a multiple of 16.
    static func aesECB(_ op: Int, key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: data.count + 16)
        var moved = 0
        let rc = CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                         key, key.count, nil, data, data.count, &out, out.count, &moved)
        return rc == kCCSuccess ? Array(out[0..<moved]) : []
    }

    /// AES-128-CTR with the whole 16-byte IV as a big-endian counter (librespot's Ctr128BE).
    /// Built from ECB blocks: symmetric, so it both encrypts and decrypts.
    static func aesCTR(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var counter = iv, out = data
        for start in stride(from: 0, to: data.count, by: 16) {
            let ks = aesECB(kCCEncrypt, key: key, counter)
            for i in start..<min(start + 16, data.count) { out[i] ^= ks[i - start] }
            for i in stride(from: 15, through: 0, by: -1) { counter[i] &+= 1; if counter[i] != 0 { break } }
        }
        return out
    }

    /// with_blob's read_int: one byte below 0x80, else low 7 bits + a second byte.
    static func varint(_ v: Int) -> [UInt8] {
        precondition(v >= 0 && v < 0x8000)
        return v < 0x80 ? [UInt8(v)] : [UInt8(v & 0x7f) | 0x80, UInt8(v >> 7)]
    }

    /// AES-192 key of the inner blob: PBKDF2-HMAC-SHA1(SHA1(deviceID), username, 256) → SHA1 → + BE u32 20.
    static func innerKey(username: String, deviceID: String) -> [UInt8] {
        let k = pbkdf2(sha1(Array(deviceID.utf8)), salt: Array(username.utf8), rounds: 0x100, length: 20)
        return sha1(k) + [0, 0, 0, 20]
    }

    /// Inverse of Credentials::with_blob: base64 of the ECB-encrypted, XOR-chained
    /// 0x49 ‖ bytes(username) ‖ 0x50 ‖ int(auth_type) ‖ 0x51 ‖ bytes(auth_data), zero-padded to 16.
    /// The tag bytes are skipped by the parser; 0x49/0x50/0x51 are the protobuf-style tags
    /// Spotify's own blobs carry. Trailing zero padding is ignored by the parser.
    static func innerBlob(username: String, authType: Int, authData: [UInt8], deviceID: String) -> String {
        let user = Array(username.utf8)
        var p: [UInt8] = [0x49] + varint(user.count) + user + [0x50] + varint(authType) + [0x51] + varint(authData.count) + authData
        p += [UInt8](repeating: 0, count: (16 - p.count % 16) % 16)
        var d = p   // with_blob does P[j] = D[j] ^ D[j-16] (top down, so on the undecrypted D) → D[j] = P[j] ^ D[j-16]
        for j in 16..<d.count { d[j] = p[j] ^ d[j - 16] }
        return Data(aesECB(kCCEncrypt, key: innerKey(username: username, deviceID: deviceID), d)).base64EncodedString()
    }

    /// Outer layer (server.rs handle_add_user): base_key = SHA1(shared)[0..16], keys = HMAC(base_key,
    /// "checksum"/"encryption"), blob = iv ‖ AES-128-CTR(enc[0..16], iv, payload) ‖ HMAC(checksum, ciphertext).
    static func outerBlob(_ payload: [UInt8], shared: [UInt8]) -> String {
        let base = Array(sha1(shared)[0..<16])
        let ck = hmac(base, Array("checksum".utf8)), ek = Array(hmac(base, Array("encryption".utf8))[0..<16])
        var iv = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &iv)
        let enc = aesCTR(key: ek, iv: iv, payload)
        return Data(iv + enc + hmac(ck, enc)).base64EncodedString()
    }
}

// MARK: - Discovery + addUser

final class SpotifyZeroconf: ObservableObject {
    struct Speaker: Identifiable, Equatable {
        let id: String           // Bonjour service name
        let name: String         // getInfo remoteName
        let deviceID: String
        let publicKey: String    // base64 DH public key
        let endpoint: URL        // http://host:port<CPath>
    }

    @Published var speakers: [Speaker] = []
    @Published var connecting: String?          // Speaker.id while addUser runs
    @Published var errors: [String: String] = [:]

    static let credentialsPath = NSHomeDirectory() + "/Library/Caches/spotifyd/oauth/credentials.json"
    var hasCredentials: Bool { FileManager.default.fileExists(atPath: Self.credentialsPath) }

    private var browser: NWBrowser?
    private var pending: Set<String> = []
    private var generation = 0   // bumps on stop(); late resolves/getInfos of an old browse are dropped

    /// Picker opened: browse until stop().
    func start() {
        stop()
        errors = [:]
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_spotify-connect._tcp", domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser = b
        b.start(queue: .main)
    }

    func stop() {
        browser?.cancel(); browser = nil
        generation += 1
        pending = []
        speakers = []
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var names: Set<String> = []
        for r in results {
            guard case let .service(name, _, _, _) = r.endpoint else { continue }
            names.insert(name)
            guard !pending.contains(name), !speakers.contains(where: { $0.id == name }) else { continue }
            var cpath = "/"
            if case let .bonjour(txt) = r.metadata, let p = txt["CPath"], !p.isEmpty { cpath = p.hasPrefix("/") ? p : "/" + p }
            pending.insert(name)
            resolve(name: name, endpoint: r.endpoint, cpath: cpath)
        }
        speakers.removeAll { !names.contains($0.id) }
    }

    /// Bonjour service → IPv4 host:port via a throwaway TCP connection, then getInfo.
    private func resolve(name: String, endpoint: NWEndpoint, cpath: String) {
        let gen = generation
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let conn = NWConnection(to: endpoint, using: params)
        var finished = false
        let finish: (URL?) -> Void = { [weak self] url in
            guard !finished else { return }
            finished = true
            conn.cancel()
            guard let self, gen == self.generation else { return }
            guard let url else { self.pending.remove(name); return }
            self.getInfo(name: name, url: url, gen: gen)
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(.ipv4(a), port)? = conn.currentPath?.remoteEndpoint {
                    let host = a.rawValue.map(String.init).joined(separator: ".")
                    finish(URL(string: "http://\(host):\(port.rawValue)\(cpath)"))
                } else { finish(nil) }
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish(nil) }
    }

    private func getInfo(name: String, url: URL, gen: Int) {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { pending.remove(name); return }
        c.queryItems = [URLQueryItem(name: "action", value: "getInfo")]
        var req = URLRequest(url: c.url!, timeoutInterval: 3)
        req.httpMethod = "GET"
        weak let weakSelf = self
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            DispatchQueue.main.async {
                guard let self = weakSelf, gen == self.generation else { return }
                self.pending.remove(name)
                guard let j, let remote = j["remoteName"] as? String, let dev = j["deviceID"] as? String,
                      let pub = j["publicKey"] as? String, !pub.isEmpty else { return }
                self.speakers.append(Speaker(id: name, name: remote, deviceID: dev, publicKey: pub, endpoint: url))
                self.speakers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }.resume()
    }

    /// spotifyd's cached reusable login (librespot Credentials JSON: username, auth_type, auth_data base64).
    private static func loadCredentials() -> (user: String, type: Int, data: [UInt8])? {
        guard let d = FileManager.default.contents(atPath: credentialsPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let user = j["username"] as? String, let type = j["auth_type"] as? Int,
              let b64 = j["auth_data"] as? String, let data = Data(base64Encoded: b64) else { return nil }
        return (user, type, Array(data))
    }

    /// Sign the speaker in with spotifyd's login. `done(true)` = the speaker answered status 101;
    /// failures land in `errors[speaker.id]`.
    func addUser(_ s: Speaker, done: @escaping (Bool) -> Void) {
        guard connecting == nil else { return }
        connecting = s.id
        errors[s.id] = nil
        weak let weakSelf = self
        let fail: (String) -> Void = { msg in
            DispatchQueue.main.async { weakSelf?.connecting = nil; weakSelf?.errors[s.id] = msg; done(false) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            guard let cred = Self.loadCredentials() else { fail("needs spotifyd login"); return }
            guard let remote = Data(base64Encoded: s.publicKey) else { fail("speaker sent no usable key"); return }
            let keys = ZCCrypto.Keys.random()
            let inner = ZCCrypto.innerBlob(username: cred.user, authType: cred.type, authData: cred.data, deviceID: s.deviceID)
            let blob = ZCCrypto.outerBlob(Array(inner.utf8), shared: keys.shared(Array(remote)))
            // server.rs reads only userName, blob and clientKey; tokenType=default = "blob, not an access token".
            let form = [("action", "addUser"), ("userName", cred.user), ("blob", blob),
                        ("clientKey", Data(keys.pub).base64EncodedString()), ("tokenType", "default")]
            var req = URLRequest(url: s.endpoint, timeoutInterval: 5)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&").data(using: .utf8)
            URLSession.shared.dataTask(with: req) { data, resp, err in
                let j = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if (j?["status"] as? Int) == 101 {
                    DispatchQueue.main.async { weakSelf?.connecting = nil; done(true) }
                } else if let j {
                    fail("speaker refused: " + ((j["statusString"] as? String) ?? "status \(j["status"] ?? "?")"))
                } else {
                    fail(err?.localizedDescription ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
                }
            }.resume()
        }
    }

    private static func formEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

#if DEBUG
// MARK: - Self-check: bignum vectors + round trip through Swift ports of librespot's receiving side

/// server.rs handle_add_user, outer layer: verify the MAC, AES-128-CTR decrypt.
private func _zcReceiveOuter(_ b64: String, shared: [UInt8]) -> [UInt8]? {
    guard let blob = Data(base64Encoded: b64).map(Array.init), blob.count >= 36 else { return nil }
    let iv = Array(blob[0..<16]), enc = Array(blob[16..<(blob.count - 20)]), mac = Array(blob[(blob.count - 20)...])
    let base = Array(ZCCrypto.sha1(shared)[0..<16])
    let ck = ZCCrypto.hmac(base, Array("checksum".utf8)), ek = Array(ZCCrypto.hmac(base, Array("encryption".utf8))[0..<16])
    guard ZCCrypto.hmac(ck, enc) == mac else { return nil }
    return ZCCrypto.aesCTR(key: ek, iv: iv, enc)
}

/// authentication.rs Credentials::with_blob.
private func _zcReceiveInner(_ b64: [UInt8], username: String, deviceID: String) -> (type: Int, data: [UInt8])? {
    guard let raw = Data(base64Encoded: Data(b64)).map(Array.init) else { return nil }
    var data = ZCCrypto.aesECB(kCCDecrypt, key: ZCCrypto.innerKey(username: username, deviceID: deviceID), raw)
    let l = data.count
    for i in 0..<(l - 0x10) { data[l - i - 1] ^= data[l - i - 0x11] }
    var pos = 0
    func u8() -> Int { defer { pos += 1 }; return Int(data[pos]) }
    func int() -> Int { let lo = u8(); return lo & 0x80 == 0 ? lo : (lo & 0x7f) | (u8() << 7) }
    func bytes() -> [UInt8] { let n = int(); defer { pos += n }; return Array(data[pos..<(pos + n)]) }
    _ = u8(); _ = bytes(); _ = u8()
    let type = int()
    _ = u8()
    return (type, bytes())
}

func _spotifyZeroconfSelfCheck() {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    // Vectors from Python's pow().
    assert(ZCBig.modPow([3], [0x01, 0x23, 0x45, 0x67], [1_000_003]) == [675_567])
    assert(hex(ZCCrypto.dhPow([2], Array(1...95))) ==
           "67fc0ff26b0890085f41ce5a9e85b60bd921034ba1f26c752b5c7b582b41aa68043655712a895c7d2b305c6b84dff1b5060056ab43b89934a56241e8a289a2ed4ea5c8fc941850cb36675b10b689e6827cd6cdc8237c6b72c381319ecba20f40")
    assert(hex(ZCCrypto.dhPow([0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe], [0x01, 0x00, 0x01])) ==
           "c7b0b261715d8394499c64a02cfff5235a1fc06ef500a65747184bb3e809ab606fbefaa636c894954353a34d5414783e36124243e94a2a943ebb63b0d93a467b46b2672f723778564b7bb1f5e576b40b4881d76ed37efddef995b799e2fdcfba")
    // DH agreement.
    let a = ZCCrypto.Keys.random(), b = ZCCrypto.Keys.random()
    assert(a.shared(b.pub) == b.shared(a.pub))
    // Blob round trip with fake credentials (200-byte auth_data → two-byte length, like real ones).
    let user = "example-user", dev = "0123456789abcdef0123456789abcdef01234567"
    let authData = (0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
    let inner = ZCCrypto.innerBlob(username: user, authType: 1, authData: authData, deviceID: dev)
    let outer = ZCCrypto.outerBlob(Array(inner.utf8), shared: a.shared(b.pub))
    let got = _zcReceiveOuter(outer, shared: b.shared(a.pub))
    assert(got == Array(inner.utf8))
    let cred = got.flatMap { _zcReceiveInner($0, username: user, deviceID: dev) }
    assert(cred?.type == 1 && cred?.data == authData)
    assert(ZCCrypto.innerKey(username: user, deviceID: dev) != ZCCrypto.innerKey(username: user, deviceID: "other-device"))
    var tampered = Array(Data(base64Encoded: outer)!); tampered[20] ^= 1
    assert(_zcReceiveOuter(Data(tampered).base64EncodedString(), shared: b.shared(a.pub)) == nil)
}
#endif

import AppKit
import SwiftUI

// MARK: - Config window
//
// External settings window (a real NSWindow, not the drop-down panel) for the
// ~/.config/kajo/*.json files. Each file has BOTH a typed Form (toggles/fields) and
// a raw JSON editor; a segmented switch at the top edge flips between them and the two
// stay in sync (only one view is mounted at a time, so we sync value↔text on switch —
// no feedback loop). One generic form renderer driven by per-file field descriptors,
// plus two composite editors (module toggles, calendar cities) for the array cases.

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

func prettyJSON(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let s = String(data: d, encoding: .utf8) else { return "" }
    return s
}
func parseJSON(_ text: String) -> [String: Any]? {
    guard let d = text.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return o
}

enum FieldKind {
    case toggle
    case text(String)        // placeholder
    case secret
    case int
    case stringList(String)  // e.g. HA entities; placeholder
    case modules             // config.json enabledModules ↔ Tab.allCases
    case cities              // calendar.json cities array
    case currencies          // currency.json currencies array (code + flag)
}

struct Field: Identifiable {
    let key: String
    let label: String
    let kind: FieldKind
    var id: String { key }
}

struct ConfigFile: Identifiable {
    var id: String { name }
    let name: String
    let title: String
    let symbol: String
    let secret: Bool
    let blurb: String
    let fields: [Field]
    let template: String
    var help: (label: String, url: String)? = nil   // optional "learn more" link under the blurb
}

// Tabs that have no JSON config — listed in the sidebar (greyed) so they don't look
// forgotten; selecting one shows a short "why there's nothing here" note.
struct PlaceholderTab: Identifiable {
    let title: String
    let symbol: String
    let note: String
    var id: String { title }
}

let noConfigTabs: [PlaceholderTab] = [
    .init(title: "Timer", symbol: "timer", note: "Nothing to configure — the last-used duration persists automatically."),
    .init(title: "Now Playing", symbol: "music.note", note: "Nothing to configure — controls Spotify via automation. Approve the Automation → Spotify permission on first use."),
    .init(title: "Sound", symbol: "speaker.wave.2.fill", note: "Nothing to configure — output picker + Bluetooth battery work out of the box. `blueutil` is optional (for BT connect/disconnect)."),
    .init(title: "Power", symbol: "bolt.fill", note: "Nothing to configure — reads battery/SMC data from IOKit."),
    .init(title: "Network", symbol: "wifi", note: "No JSON config. The Wi-Fi priority toggle needs a sudoers rule (see the README's Installation notes)."),
    .init(title: "VPN", symbol: "lock.fill", note: "Nothing to configure — auto-detects Twingate / OpenVPN / NordVPN / Tailscale."),
    .init(title: "System", symbol: "slider.horizontal.3", note: "Nothing to configure — Keep Awake and Empty Trash need no settings."),
    .init(title: "Memes", symbol: "photo.stack", note: "Nothing to configure — add and tag images in the tab itself; they're stored under ~/.config/kajo/memes/."),
]

let configFiles: [ConfigFile] = [
    ConfigFile(name: "config.json", title: "General", symbol: "slider.horizontal.3", secret: false,
        blurb: "Which tabs are enabled + the menu-bar icon. Omit the file → all tabs.",
        fields: [
            Field(key: "menuBarIcon", label: "Menu-bar icon", kind: .toggle),
            Field(key: "enabledModules", label: "Enabled tabs", kind: .modules),
        ],
        template: """
        {
          "enabledModules": [\(Tab.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))],
          "menuBarIcon": true
        }
        """),
    ConfigFile(name: "calendar.json", title: "Calendar", symbol: "calendar", secret: false,
        blurb: "World-clock cities (name / IANA tz / lat / lon) and your home timezone. Weather via Open-Meteo, no key.",
        fields: [
            Field(key: "homeTimezone", label: "Home timezone", kind: .text("Europe/Helsinki")),
            Field(key: "cities", label: "World-clock cities", kind: .cities),
        ],
        template: """
        {
          "homeTimezone": "Europe/Helsinki",
          "cities": [
            {"name": "Helsinki", "tz": "Europe/Helsinki", "lat": 60.1699, "lon": 24.9384},
            {"name": "Kuala Lumpur", "tz": "Asia/Kuala_Lumpur", "lat": 3.1390, "lon": 101.6869},
            {"name": "Málaga", "tz": "Europe/Madrid", "lat": 36.7213, "lon": -4.4214}
          ]
        }
        """,
        help: ("IANA timezone names + how to find coordinates ↗", "https://en.wikipedia.org/wiki/List_of_tz_database_time_zones")),
    ConfigFile(name: "clipboard.json", title: "Clipboard", symbol: "doc.on.clipboard", secret: false,
        blurb: "History cap, secret TTL, max image size, and paths for → vim (nvr / nvim socket).",
        fields: [
            Field(key: "historyCap", label: "History cap", kind: .int),
            Field(key: "secretTTLSeconds", label: "Secret TTL (seconds)", kind: .int),
            Field(key: "maxImageMB", label: "Max image (MB)", kind: .int),
            Field(key: "nvrPath", label: "nvr path", kind: .text("~/Library/Python/3.14/bin/nvr")),
            Field(key: "nvimSocket", label: "nvim socket", kind: .text("/tmp/nvimsocket2")),
        ],
        template: """
        {
          "historyCap": 100,
          "secretTTLSeconds": 20,
          "maxImageMB": 5,
          "nvrPath": "~/Library/Python/3.14/bin/nvr",
          "nvimSocket": "/tmp/nvimsocket2"
        }
        """),
    ConfigFile(name: "ai.json", title: "AI", symbol: "sparkles", secret: false,
        blurb: "Base URL of your local oMLX server.",
        fields: [ Field(key: "omlxURL", label: "oMLX URL", kind: .text("http://127.0.0.1:8000")) ],
        template: #"{ "omlxURL": "http://127.0.0.1:8000" }"#),
    ConfigFile(name: "currency.json", title: "Currency", symbol: "dollarsign.arrow.circlepath", secret: false,
        blurb: "Currencies in the converter (code + flag emoji). EUR is the base and is always shown first. Codes must be ones Frankfurter serves (ECB majors + THB, MYR, SGD…).",
        fields: [ Field(key: "currencies", label: "Currencies", kind: .currencies) ],
        template: """
        {
          "currencies": [
            {"code": "EUR", "flag": "🇪🇺"},
            {"code": "GBP", "flag": "🇬🇧"},
            {"code": "THB", "flag": "🇹🇭"},
            {"code": "MYR", "flag": "🇲🇾"}
          ]
        }
        """,
        help: ("Supported currency codes ↗", "https://api.frankfurter.app/currencies")),
    ConfigFile(name: "unifi.json", title: "UniFi", symbol: "shield.lefthalf.filled", secret: true,
        blurb: "Local UniFi controller account. host = controller URL (self-signed OK). Saved chmod 600.",
        fields: [
            Field(key: "host", label: "Host", kind: .text("https://192.168.1.1")),
            Field(key: "username", label: "Username", kind: .text("kajo")),
            Field(key: "password", label: "Password", kind: .secret),
            Field(key: "site", label: "Site", kind: .text("default")),
        ],
        template: """
        {
          "host": "https://192.168.1.1",
          "username": "kajo",
          "password": "SECRET",
          "site": "default"
        }
        """),
    ConfigFile(name: "ha.json", title: "Smart Home", symbol: "house.fill", secret: true,
        blurb: "Home Assistant URL + long-lived token + the entities to show. Saved chmod 600.",
        fields: [
            Field(key: "url", label: "URL", kind: .text("http://homeassistant.local:8123")),
            Field(key: "token", label: "Long-lived token", kind: .secret),
            Field(key: "entities", label: "Entities", kind: .stringList("light.living_room")),
        ],
        template: """
        {
          "url": "http://homeassistant.local:8123",
          "token": "LONG_LIVED_ACCESS_TOKEN",
          "entities": ["light.living_room", "switch.coffee", "lock.front_door", "climate.bedroom", "sensor.outdoor_temp"]
        }
        """),
    ConfigFile(name: "pi.json", title: "Pi", symbol: "server.rack", secret: true,
        blurb: "Health endpoint on your LAN. Optional remote snapshot URL for when you're away. Saved chmod 600.",
        fields: [
            Field(key: "local", label: "Local health URL", kind: .text("http://192.168.1.50:9099/health")),
            Field(key: "remote", label: "Remote URL (optional)", kind: .text("")),
        ],
        template: """
        {
          "local": "http://192.168.1.50:9099/health"
        }
        """),
    ConfigFile(name: "severa.json", title: "Severa", symbol: "clock.badge.checkmark", secret: true,
        blurb: "Visma Severa REST credentials for the Hours project picker + direct upload. Client ID/secret come from a Severa admin (gear → Integrations). Grant scopes projects:read, hours:read, hours:write. userGuid scopes the picker to you. roundUpMinutes rounds each uploaded day/phase up to that step (0 = off). Saved chmod 600.",
        fields: [
            Field(key: "url", label: "REST base URL", kind: .text("https://api.severa.visma.com/rest-api")),
            Field(key: "clientId", label: "Client ID", kind: .text("")),
            Field(key: "clientSecret", label: "Client secret (API key)", kind: .secret),
            Field(key: "userGuid", label: "Your user GUID", kind: .text("")),
            Field(key: "roundUpMinutes", label: "Round up to (minutes)", kind: .int),
        ],
        template: """
        {
          "url": "https://api.severa.visma.com/rest-api",
          "clientId": "YOUR_CLIENT_ID",
          "clientSecret": "YOUR_CLIENT_SECRET",
          "userGuid": "YOUR_USER_GUID",
          "roundUpMinutes": 30
        }
        """,
        help: ("How to create Severa REST credentials ↗", "https://support.severa.com/en/support/solutions/articles/77000545737-how-to-create-rest-api-credentials")),
]

final class ConfigModel: ObservableObject {
    enum Mode { case form, json }

    @Published var selected: ConfigFile
    @Published var value: [String: Any] = [:]
    @Published var text: String = ""
    @Published var mode: Mode = .form
    @Published var status = ""
    @Published var statusOK = true
    @Published var exists = false
    @Published var placeholder: PlaceholderTab?   // non-nil = a config-less tab is selected

    init() { selected = configFiles[0]; load() }

    private func path(_ f: ConfigFile) -> String { kajoConfigDir + "/" + f.name }

    func select(_ f: ConfigFile) { placeholder = nil; selected = f; mode = .form; load() }
    func selectPlaceholder(_ p: PlaceholderTab) { placeholder = p }

    func load() {
        let p = path(selected)
        exists = FileManager.default.fileExists(atPath: p)
        if exists {
            let raw = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
            text = raw
            value = parseJSON(raw) ?? [:]
            status = ""
        } else {
            // No file → show the app's effective defaults so the form reflects what's
            // actually running (e.g. the hardcoded calendar cities), not a blank.
            value = parseJSON(selected.template) ?? [:]
            text = prettyJSON(value)
            status = "No file yet — showing defaults. Edit and Save to create it."
        }
        statusOK = true
    }

    func loadTemplate() {
        value = parseJSON(selected.template) ?? [:]
        text = prettyJSON(value)
        status = "Template loaded — review, then Save."
        statusOK = true
    }

    // Segmented switch. Syncs the target representation from the source before flipping.
    var modeBinding: Binding<Mode> {
        Binding(get: { self.mode }, set: { self.setMode($0) })
    }
    private func setMode(_ m: Mode) {
        if m == mode { return }
        if m == .json {                       // form → json: regenerate text from the edited value
            text = prettyJSON(value)
        } else {                              // json → form: parse text into value (block if invalid)
            guard let parsed = parseJSON(text) else {
                status = "Invalid JSON — fix it before switching to Form."; statusOK = false; return
            }
            value = parsed
        }
        mode = m
        if statusOK { status = "" }
    }

    var jsonValid: Bool { parseJSON(text) != nil }

    // MARK: field bindings
    func boolBinding(_ k: String) -> Binding<Bool> {
        Binding(get: { self.value[k] as? Bool ?? false }, set: { self.value[k] = $0 })
    }
    func stringBinding(_ k: String) -> Binding<String> {
        Binding(get: { self.value[k] as? String ?? "" }, set: { self.value[k] = $0 })
    }
    func intBinding(_ k: String) -> Binding<Int> {
        Binding(get: { (self.value[k] as? NSNumber)?.intValue ?? 0 }, set: { self.value[k] = $0 })
    }

    // enabledModules ↔ per-tab toggles (absent = all enabled, matching app behavior)
    func moduleOn(_ name: String) -> Binding<Bool> {
        Binding(get: {
            let arr = self.value["enabledModules"] as? [String] ?? Tab.allCases.map { $0.rawValue }
            return arr.contains(name)
        }, set: { on in
            var arr = self.value["enabledModules"] as? [String] ?? Tab.allCases.map { $0.rawValue }
            if on { if !arr.contains(name) { arr.append(name) } } else { arr.removeAll { $0 == name } }
            self.value["enabledModules"] = arr
        })
    }

    // MARK: string-list (entities)
    func listCount(_ k: String) -> Int { (value[k] as? [String])?.count ?? 0 }
    func listItem(_ k: String, _ i: Int) -> Binding<String> {
        Binding(get: { (self.value[k] as? [String])?[safe: i] ?? "" },
                set: { v in var a = self.value[k] as? [String] ?? []; if i < a.count { a[i] = v; self.value[k] = a } })
    }
    func listAdd(_ k: String) { var a = value[k] as? [String] ?? []; a.append(""); value[k] = a }
    func listRemove(_ k: String, _ i: Int) { var a = value[k] as? [String] ?? []; if i < a.count { a.remove(at: i); value[k] = a } }

    // MARK: cities
    func cityCount() -> Int { (value["cities"] as? [[String: Any]])?.count ?? 0 }
    func cityStr(_ i: Int, _ k: String) -> Binding<String> {
        Binding(get: { ((self.value["cities"] as? [[String: Any]])?[safe: i]?[k]) as? String ?? "" },
                set: { v in var c = self.value["cities"] as? [[String: Any]] ?? []; if i < c.count { c[i][k] = v; self.value["cities"] = c } })
    }
    func cityNum(_ i: Int, _ k: String) -> Binding<Double> {
        Binding(get: { ((self.value["cities"] as? [[String: Any]])?[safe: i]?[k] as? NSNumber)?.doubleValue ?? 0 },
                set: { v in var c = self.value["cities"] as? [[String: Any]] ?? []; if i < c.count { c[i][k] = v; self.value["cities"] = c } })
    }
    func cityAdd() { var c = value["cities"] as? [[String: Any]] ?? []; c.append(["name": "", "tz": "", "lat": 0, "lon": 0]); value["cities"] = c }
    func cityRemove(_ i: Int) { var c = value["cities"] as? [[String: Any]] ?? []; if i < c.count { c.remove(at: i); value["cities"] = c } }

    // MARK: currencies
    func ccyCount() -> Int { (value["currencies"] as? [[String: Any]])?.count ?? 0 }
    func ccyStr(_ i: Int, _ k: String) -> Binding<String> {
        Binding(get: { ((self.value["currencies"] as? [[String: Any]])?[safe: i]?[k]) as? String ?? "" },
                set: { v in var c = self.value["currencies"] as? [[String: Any]] ?? []; if i < c.count { c[i][k] = v; self.value["currencies"] = c } })
    }
    func ccyAdd() { var c = value["currencies"] as? [[String: Any]] ?? []; c.append(["code": "", "flag": ""]); value["currencies"] = c }
    func ccyRemove(_ i: Int) { var c = value["currencies"] as? [[String: Any]] ?? []; if i < c.count { c.remove(at: i); value["currencies"] = c } }

    // MARK: save / relaunch
    func save() {
        let out: String
        if mode == .json {
            guard jsonValid else { status = "Invalid JSON — fix before saving."; statusOK = false; return }
            out = text
        } else {
            guard !value.isEmpty else { status = "Nothing to save."; statusOK = false; return }
            out = prettyJSON(value)
        }
        do {
            try FileManager.default.createDirectory(atPath: kajoConfigDir, withIntermediateDirectories: true)
            let p = path(selected)
            // Secrets: atomic + 0600 in one step (a failed chmod used to leave the token world-readable, silently).
            if selected.secret { try writePrivate(Data(out.utf8), to: URL(fileURLWithPath: p)) }
            else { try out.write(toFile: p, atomically: true, encoding: .utf8) }
            text = out; value = parseJSON(out) ?? value; exists = true
            status = "Saved \(selected.name)\(selected.secret ? " (chmod 600)" : "") — relaunch to apply."
            statusOK = true
        } catch {
            status = "Save failed: \(error.localizedDescription)"; statusOK = false
        }
    }

    func relaunch() {
        let p = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for THIS process to be gone before `open`, or a slow teardown just re-activates the dying instance.
        t.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.1; done; open \"\(p)\""]
        try? t.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Views

struct ConfigView: View {
    @StateObject private var model = ConfigModel()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Gruv.bg3.opacity(0.4)).frame(width: 1)
            editor
        }
        .frame(minWidth: 700, minHeight: 500)
        .background(Gruv.bg0.opacity(0.5))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.headline).foregroundStyle(Gruv.fg0)
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(configFiles) { f in fileRow(f) }
                    Divider().overlay(Gruv.bg3.opacity(0.5)).padding(.horizontal, 12).padding(.vertical, 7)
                    Text("NO SETTINGS").font(.system(size: 9, weight: .semibold)).foregroundStyle(Gruv.fg4)
                        .padding(.horizontal, 16).padding(.bottom, 3)
                    ForEach(noConfigTabs) { p in placeholderRow(p) }
                }
                .padding(.bottom, 8)
            }
            Text("~/.config/kajo/").font(.caption2).foregroundStyle(Gruv.fg4)
                .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .frame(width: 200)
        .background(Gruv.bg0.opacity(0.6))
    }

    private func fileRow(_ f: ConfigFile) -> some View {
        let sel = model.placeholder == nil && model.selected.id == f.id
        let exists = FileManager.default.fileExists(atPath: kajoConfigDir + "/" + f.name)
        return Button { model.select(f) } label: {
            HStack(spacing: 9) {
                Image(systemName: f.symbol).font(.system(size: 13)).frame(width: 18)
                    .foregroundStyle(sel ? Gruv.aqua : Gruv.fg4)
                Text(f.title).foregroundStyle(sel ? Gruv.fg0 : Gruv.fg2)
                if f.secret { Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(Gruv.fg4) }
                Spacer(minLength: 0)
                Circle().fill(exists ? Gruv.green : Gruv.bg3.opacity(0.7)).frame(width: 5, height: 5)
            }
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Gruv.aqua.opacity(0.16) : .clear))
            .overlay(alignment: .leading) { if sel { RoundedRectangle(cornerRadius: 2).fill(Gruv.aqua).frame(width: 3, height: 18) } }
        }
        .buttonStyle(.plain).padding(.horizontal, 6)
    }

    private func placeholderRow(_ p: PlaceholderTab) -> some View {
        let sel = model.placeholder?.id == p.id
        return Button { model.selectPlaceholder(p) } label: {
            HStack(spacing: 9) {
                Image(systemName: p.symbol).font(.system(size: 13)).frame(width: 18)
                    .foregroundStyle(sel ? Gruv.aqua : Gruv.fg4.opacity(0.6))
                Text(p.title).foregroundStyle(sel ? Gruv.fg0 : Gruv.fg4)
                Spacer(minLength: 0)
            }
            .font(.callout).padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(sel ? Gruv.aqua.opacity(0.16) : .clear))
            .overlay(alignment: .leading) { if sel { RoundedRectangle(cornerRadius: 2).fill(Gruv.aqua).frame(width: 3, height: 18) } }
        }
        .buttonStyle(.plain).padding(.horizontal, 6)
    }

    private var editor: some View {
        Group {
            if let ph = model.placeholder { placeholderPane(ph) } else { fileEditor }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Gruv.bg0.opacity(0.4))
    }

    private func placeholderPane(_ p: PlaceholderTab) -> some View {
        VStack(spacing: 14) {
            Image(systemName: p.symbol).font(.system(size: 42)).foregroundStyle(Gruv.fg4)
            Text(p.title).font(.title3.weight(.semibold)).foregroundStyle(Gruv.fg1)
            Text(p.note).font(.callout).foregroundStyle(Gruv.gray)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }

    private func helpLink(_ h: (label: String, url: String)) -> some View {
        Button { if let u = URL(string: h.url) { NSWorkspace.shared.open(u) } } label: {
            Label(h.label, systemImage: "info.circle").font(.caption)
        }
        .buttonStyle(.plain).foregroundStyle(Gruv.blue)
    }

    private var fileEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.selected.name).font(.system(.callout, design: .monospaced)).foregroundStyle(Gruv.fg1)
                Spacer()
                ModeSwitch(model: model)
                Button("Load template") { model.loadTemplate() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Gruv.blue)
            }
            Text(model.selected.blurb).font(.caption).foregroundStyle(Gruv.gray)
                .fixedSize(horizontal: false, vertical: true)
            if let h = model.selected.help { helpLink(h) }

            if model.mode == .form {
                ScrollView { ConfigForm(model: model).padding(.trailing, 6) }
            } else {
                TextEditor(text: $model.text)
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(Gruv.fg1)
                    .scrollContentBackground(.hidden).padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.bg0.opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(model.text.isEmpty || model.jsonValid ? Gruv.bg3.opacity(0.5) : Gruv.red.opacity(0.7), lineWidth: 1))
            }

            HStack {
                if model.mode == .json, !model.text.isEmpty {
                    Label(model.jsonValid ? "valid JSON" : "invalid JSON",
                          systemImage: model.jsonValid ? "checkmark.circle" : "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(model.jsonValid ? Gruv.green : Gruv.red)
                }
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(model.statusOK ? Gruv.gray : Gruv.red)
            }

            HStack(spacing: 10) {
                Button { model.save() } label: {
                    Text("Save").font(.callout.weight(.medium)).foregroundStyle(Gruv.bg0)
                        .padding(.vertical, 7).padding(.horizontal, 18)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.green))
                }.buttonStyle(.plain).keyboardShortcut("s")
                Button { model.relaunch() } label: {
                    Text("Relaunch Kajo").font(.callout).foregroundStyle(Gruv.yellow)
                        .padding(.vertical, 7).padding(.horizontal, 14)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.yellow.opacity(0.15)))
                }.buttonStyle(.plain)
                Spacer()
            }
        }
        .padding(16)
    }
}

// Generic form renderer — dispatches each field descriptor to a widget.
struct ConfigForm: View {
    @ObservedObject var model: ConfigModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(model.selected.fields) { field in
                fieldView(field)
            }
        }
    }

    @ViewBuilder private func fieldView(_ f: Field) -> some View {
        switch f.kind {
        case .toggle:
            Toggle(isOn: model.boolBinding(f.key)) { Text(f.label).foregroundStyle(Gruv.fg1) }
                .toggleStyle(.switch).tint(Gruv.green)
        case .text(let ph):
            labeled(f.label) { TextField(ph, text: model.stringBinding(f.key)).textFieldStyle(.roundedBorder) }
        case .secret:
            labeled(f.label) { SecureField("", text: model.stringBinding(f.key)).textFieldStyle(.roundedBorder) }
        case .int:
            labeled(f.label) {
                TextField("", value: model.intBinding(f.key), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 110)
            }
        case .stringList(let ph):
            VStack(alignment: .leading, spacing: 5) {
                Text(f.label).font(.caption).foregroundStyle(Gruv.fg4)
                ForEach(Array(0..<model.listCount(f.key)), id: \.self) { i in
                    HStack {
                        TextField(ph, text: model.listItem(f.key, i)).textFieldStyle(.roundedBorder)
                        Button { model.listRemove(f.key, i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Gruv.red)
                    }
                }
                Button { model.listAdd(f.key) } label: { Label("Add", systemImage: "plus").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(Gruv.blue)
            }
        case .modules:
            VStack(alignment: .leading, spacing: 6) {
                Text(f.label).font(.caption).foregroundStyle(Gruv.fg4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(Tab.allCases) { t in moduleChip(t) }
                }
            }
        case .cities:
            VStack(alignment: .leading, spacing: 8) {
                Text(f.label).font(.caption).foregroundStyle(Gruv.fg4)
                ForEach(Array(0..<model.cityCount()), id: \.self) { i in
                    VStack(spacing: 4) {
                        HStack {
                            TextField("name", text: model.cityStr(i, "name")).textFieldStyle(.roundedBorder)
                            TextField("Europe/Helsinki", text: model.cityStr(i, "tz")).textFieldStyle(.roundedBorder)
                            Button { model.cityRemove(i) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).foregroundStyle(Gruv.red)
                        }
                        HStack {
                            TextField("lat", value: model.cityNum(i, "lat"), format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                            TextField("lon", value: model.cityNum(i, "lon"), format: .number).textFieldStyle(.roundedBorder).frame(width: 100)
                            Spacer()
                        }
                    }
                    .padding(8).background(RoundedRectangle(cornerRadius: 7).fill(Gruv.bg0.opacity(0.4)))
                }
                Button { model.cityAdd() } label: { Label("Add city", systemImage: "plus").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(Gruv.blue)
            }
        case .currencies:
            VStack(alignment: .leading, spacing: 6) {
                Text(f.label).font(.caption).foregroundStyle(Gruv.fg4)
                ForEach(Array(0..<model.ccyCount()), id: \.self) { i in
                    HStack(spacing: 8) {
                        TextField("🇪🇺", text: model.ccyStr(i, "flag")).textFieldStyle(.roundedBorder).frame(width: 60)
                        TextField("EUR", text: model.ccyStr(i, "code")).textFieldStyle(.roundedBorder).frame(width: 90)
                        Button { model.ccyRemove(i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(Gruv.red)
                        Spacer()
                    }
                }
                Button { model.ccyAdd() } label: { Label("Add currency", systemImage: "plus").font(.caption) }
                    .buttonStyle(.plain).foregroundStyle(Gruv.blue)
            }
        }
    }

    @ViewBuilder private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(Gruv.fg4)
            content()
        }
    }

    private func moduleChip(_ t: Tab) -> some View {
        let bind = model.moduleOn(t.rawValue)
        let on = bind.wrappedValue
        return Button { bind.wrappedValue.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: t.symbol).font(.system(size: 11)).frame(width: 15)
                Text(t.title).font(.caption)
                Spacer(minLength: 0)
                if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Gruv.aqua.opacity(0.20) : Gruv.bg1.opacity(0.45)))
            .foregroundStyle(on ? Gruv.aqua : Gruv.fg4)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Gruv.aqua.opacity(0.45) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// Gruv-themed Form/JSON segmented switch (replaces the system-accent Picker).
struct ModeSwitch: View {
    @ObservedObject var model: ConfigModel
    var body: some View {
        HStack(spacing: 3) {
            seg("Form", .form)
            seg("JSON", .json)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Gruv.bg0.opacity(0.6)))
    }
    private func seg(_ label: String, _ m: ConfigModel.Mode) -> some View {
        let on = model.mode == m
        return Button { model.modeBinding.wrappedValue = m } label: {
            Text(label).font(.caption.weight(.medium))
                .padding(.vertical, 4).padding(.horizontal, 14)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Gruv.aqua.opacity(0.9) : Color.clear))
                .foregroundStyle(on ? Gruv.bg0 : Gruv.fg2)
        }
        .buttonStyle(.plain)
    }
}

// Single reusable window (LSUIElement app → we drive activation ourselves).
final class ConfigWindowController {
    static let shared = ConfigWindowController()
    private var window: NSWindow?

    func show() {
        if let w = window { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Kajo Settings"
        w.titlebarAppearsTransparent = true          // let the titlebar blend into the translucent body
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)

        // Translucent backing to match the Kajo panel's hudWindow look.
        let visual = NSVisualEffectView()
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.appearance = NSAppearance(named: .darkAqua)
        w.contentView = visual                       // AppKit sizes visual to the content area
        let hosting = NSHostingView(rootView: ConfigView())
        hosting.frame = visual.bounds
        hosting.autoresizingMask = [.width, .height]
        visual.addSubview(hosting)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

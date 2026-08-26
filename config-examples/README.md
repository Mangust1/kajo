# Kajo config

All files are **optional** — Kajo ships sane defaults, so it runs fine with an
empty `~/.config/kajo/`. Copy any of these into `~/.config/kajo/` and edit only
what you want to change, then restart Kajo (config loads at launch).

**Easier than hand-editing:** the built-in **Settings window** (menu-bar →
*Settings…*, the System tab's Settings button, or `kajo://config`) edits every
one of these with typed forms *and* a raw-JSON view, validates on save, writes
secrets `chmod 600`, and has a Relaunch button to apply. When a file doesn't
exist yet it pre-fills the app's current effective defaults, so nothing looks
blank. These files are the generic starting points; your real config lives in
`~/.config/kajo/`.

| File | What it controls |
|---|---|
| `config.json` | Which modules (tabs) are enabled + the menu-bar icon. `enabledModules` names match `kajo://tab/<name>`. Omit the file → all modules. |
| `calendar.json` | World-clock cities (name/tz/lat/lon) + `homeTimezone`. |
| `clipboard.json` | History cap, secret TTL, max image MB, `nvrPath`, `nvimSocket`. |
| `ai.json` | oMLX base URL. |
| `currency.json` | Currencies in the converter (`code` + `flag`). EUR is the base, always shown first. Codes must be ones Frankfurter serves. |
| `ha.json` / `unifi.json` / `pi.json` | Home Assistant / UniFi / Pi-health endpoints + tokens (secrets — `chmod 600`). The tab shows a "needs config" hint until present. |

Paths support `~`. A missing or partial file just falls back to defaults.

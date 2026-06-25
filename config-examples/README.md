# Kajo config

All files are **optional** — Kajo ships sane defaults, so it runs fine with an
empty `~/.config/kajo/`. Copy any of these into `~/.config/kajo/` and edit only
what you want to change, then restart Kajo (config loads at launch).

| File | What it controls |
|---|---|
| `config.json` | Which modules (tabs) are enabled + the menu-bar icon. `enabledModules` names match `kajo://tab/<name>`. Omit the file → all modules. |
| `calendar.json` | World-clock cities (name/tz/lat/lon) + `homeTimezone`. |
| `clipboard.json` | History cap, secret TTL, max image MB, `nvrPath`, `nvimSocket`. |
| `ai.json` | oMLX base URL. |
| `ha.json` / `unifi.json` / `pi.json` | Home Assistant / UniFi / Pi-health endpoints + tokens (secrets — `chmod 600`). The tab shows a "needs config" hint until present. |

Paths support `~`. A missing or partial file just falls back to defaults.

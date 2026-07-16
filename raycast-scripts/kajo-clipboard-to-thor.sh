#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Clipboard to Thor
# @raycast.mode silent
# ponytail: talks to kdeconnect-cli directly — Kajo not involved for "send current clipboard"
CLI="/Applications/KDE Connect.app/Contents/MacOS/kdeconnect-cli"
"$CLI" -d "$("$CLI" --list-available --id-only | head -n1)" --send-clipboard 2>/dev/null

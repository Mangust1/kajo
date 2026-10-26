#!/bin/bash
# spotifyd event hook for Kajo's "musicSource": "spotifyd".
# Point spotifyd at it (chmod +x first):
#   on_song_change_hook = "/absolute/path/to/spotifyd-onevent.sh"
# in ~/Library/Application Support/spotifyd/spotifyd.conf (the macOS config path, not ~/.config).
#
# Every player event merges its env (PLAYER_EVENT, TRACK_ID, TRACK_NAME, TRACK_COVER,
# TRACK_DURATION, POSITION_MS, VOLUME, SHUFFLE, REPEAT…) into one JSON file, newest value wins, plus
# "_playing" (changed only by play-state events) and "ts" (unix seconds).
# Written to a temp file and mv'd into place: Kajo watches the directory, and a rename is
# what makes the watcher fire (and nobody ever reads a half-written file).
out="$HOME/.config/kajo/spotifyd-state.json"
/usr/bin/python3 -c 'import json,os,sys,time
p=sys.argv[1]
try: d=json.load(open(p))
except Exception: d={}
d.update({k:v for k,v in os.environ.items() if k.startswith(("PLAYER_","TRACK_","PLAY_","POSITION","DURATION","VOLUME","SINK","SHUFFLE","REPEAT"))})
ev=d.get("PLAYER_EVENT","")
if ev in ("start","play"): d["_playing"]=True
elif ev in ("pause","stop","sessiondisconnected","unavailable"): d["_playing"]=False
d["ts"]=int(time.time()); json.dump(d,open(p+".tmp","w"))' "$out" && mv "$out.tmp" "$out"

# Optional: tell SketchyBar (an item subscribed to the custom event `spotifyd_change`).
# Kajo fires the same trigger after it adds ARTIST + ARTIST_TRACK_ID to the file.
[ -x /opt/homebrew/bin/sketchybar ] && /opt/homebrew/bin/sketchybar --trigger spotifyd_change >/dev/null 2>&1 &
exit 0

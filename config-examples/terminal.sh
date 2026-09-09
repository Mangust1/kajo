#!/bin/bash
# Kajo terminal command (~/.config/kajo/terminal.sh, chmod +x). Kajo runs this inside its
# drop-down terminal window. This example attaches a persistent tmux session so whatever
# runs inside survives Kajo restarts; adjust panes/commands to taste, or delete the file
# to get a plain login shell.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
SESSION="quake"
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  tmux new-session -d -s "$SESSION" -c "$HOME"
  tmux set-option -t "$SESSION" status off      # drop-down look: no status line
  # pane frames: gruvbox orange on the active pane, dim on the rest (matches the window frame)
  "${TMUX_BIN:-tmux}" set-option -w -t "$SESSION" pane-border-style 'fg=#3c3836'
  "${TMUX_BIN:-tmux}" set-option -w -t "$SESSION" pane-active-border-style 'fg=#d65d0e'
  "${TMUX_BIN:-tmux}" set-option -w -t "$SESSION" pane-border-lines heavy
fi
exec tmux attach-session -t "$SESSION"

#!/usr/bin/env bash
# Record window most-recently-used order for the "recent" view.
# Store: $STATE_DIR/window-mru, lines "<window_id>\t<epoch>" (newest last).
# Arg: a tmux target (window/session); empty = current window.
set -euo pipefail

STATE_DIR="${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}"
MRU_FILE="${TMUX_SWITCHER_MRU_FILE:-$STATE_DIR/window-mru}"
target="${1:-}"

if [ -n "$target" ]; then
  window_id="$(tmux display-message -p -t "$target" '#{window_id}' 2>/dev/null || true)"
else
  window_id="$(tmux display-message -p '#{window_id}' 2>/dev/null || true)"
fi
[ -n "$window_id" ] || exit 0

mkdir -p "$STATE_DIR"
tmp_file="$STATE_DIR/.window-mru.$$"

if [ -r "$MRU_FILE" ]; then
  awk -F '\t' -v id="$window_id" '$1 != id' "$MRU_FILE" > "$tmp_file"
else
  : > "$tmp_file"
fi

printf '%s\t%s\n' "$window_id" "$(date +%s)" >> "$tmp_file"
tail -n 200 "$tmp_file" > "$MRU_FILE"
rm -f "$tmp_file"

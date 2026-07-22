#!/usr/bin/env bash
# Record most-recently-used order for the "recent" view and the last-pane jump.
# Stores (newest last):
#   $STATE_DIR/window-mru  lines "<window_id>\t<epoch>"
#   $STATE_DIR/pane-mru    lines "<pane_id>\t<epoch>"
# Arg: a tmux target (pane/window/session); empty = current context. The
# target's window and its active pane are both recorded, so window-level hooks
# (session-window-changed) and pane-level hooks (window-pane-changed) share
# this one recorder.
set -euo pipefail

STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
MRU_FILE="${TMUX_RADAR_MRU_FILE:-${TMUX_SWITCHER_MRU_FILE:-$STATE_DIR/window-mru}}"
PANE_MRU_FILE="${TMUX_RADAR_PANE_MRU_FILE:-$STATE_DIR/pane-mru}"
target="${1:-}"

if [ -n "$target" ]; then
  ids="$(tmux display-message -p -t "$target" '#{window_id} #{pane_id}' 2>/dev/null || true)"
else
  ids="$(tmux display-message -p '#{window_id} #{pane_id}' 2>/dev/null || true)"
fi
window_id="${ids%% *}"
pane_id="${ids##* }"
[ -n "$window_id" ] || exit 0

mkdir -p "$STATE_DIR"
now="$(date +%s)"

_record() {  # _record <file> <id> <keep>
  local file="$1" id="$2" keep="$3" tmp
  tmp="$file.$$"
  if [ -r "$file" ]; then
    awk -F '\t' -v id="$id" '$1 != id' "$file" > "$tmp"
  else
    : > "$tmp"
  fi
  printf '%s\t%s\n' "$id" "$now" >> "$tmp"
  # atomic replace: a concurrent hook invocation must never observe truncation
  tail -n "$keep" "$tmp" > "$tmp.trim" && mv "$tmp.trim" "$file"
  rm -f "$tmp"
}

_record "$MRU_FILE" "$window_id" 200
case "$pane_id" in
  %*) _record "$PANE_MRU_FILE" "$pane_id" 400 ;;
esac

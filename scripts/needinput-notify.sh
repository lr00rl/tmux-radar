#!/usr/bin/env bash
# Mark / clear tmux panes that are "waiting for user input", driven by Claude
# Code hooks and Codex notify. Maintains two files under $STATE_DIR:
#
#   need-input         persistent waiting panes (consumed by the need-input view)
#                      lines: "<pane_id>\t<epoch>\t<source>\t<label>"
#   need-input-toasts  transient toasts for the status line
#                      lines: "<expiry_epoch>\t<text>"
#
# Pane is taken from $TMUX_PANE (hook subprocesses inherit it) unless given.
# Safe to call outside tmux (no-op).
set -euo pipefail

# Hooks may run with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/needinput-notify.sh"
TOAST_BIN="$SCRIPT_DIR/needinput-toast.sh"

STATE_DIR="${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}"
STATE_FILE="${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}"
TOAST_FILE="${TMUX_SWITCHER_TOASTS:-$STATE_DIR/need-input-toasts}"
TTL="${TMUX_SWITCHER_TOAST_TTL:-3}"
LOCK="$STATE_DIR/.need-input.lock"

mkdir -p "$STATE_DIR"

have_tmux() { command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; }
lock()   { local n=0; until mkdir "$LOCK" 2>/dev/null; do n=$((n+1)); [ "$n" -gt 100 ] && break; sleep 0.02; done; }
unlock() { rmdir "$LOCK" 2>/dev/null || true; }

_drop_panes() {  # drop lines whose pane_id is in newline-list $1
  local drop="$1" tmp
  [ -r "$STATE_FILE" ] || return 0
  tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  awk -F '\t' -v drop="$drop" '
    BEGIN { n = split(drop, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") rm[a[i]] = 1 }
    !($1 in rm)
  ' "$STATE_FILE" > "$tmp" || true
  mv "$tmp" "$STATE_FILE"
}

_refresh() { have_tmux && tmux refresh-client -S 2>/dev/null || true; }

_pane_is_viewed() {  # pane currently on screen for an attached client?
  local pane="$1" v
  v="$(tmux display-message -p -t "$pane" \
        '#{&&:#{pane_active},#{&&:#{window_active},#{!=:#{session_attached},0}}}' 2>/dev/null || echo 0)"
  [ "$v" = "1" ]
}

cmd_mark() {
  local pane="${1:-${TMUX_PANE:-}}" source="${2:-tool}" label="${3:-needs input}"
  [ -n "$pane" ] || exit 0
  have_tmux || exit 0
  local wtarget wname now toasted=0
  wtarget="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}' 2>/dev/null || true)"
  [ -n "$wtarget" ] || exit 0
  wname="$(tmux display-message -p -t "$pane" '#{window_name}' 2>/dev/null || true)"
  now="$(date +%s)"

  lock
  _drop_panes "$pane"
  printf '%s\t%s\t%s\t%s\n' "$pane" "$now" "$source" "$label" >> "$STATE_FILE"
  if ! _pane_is_viewed "$pane"; then
    printf '%s\t%s\n' "$((now + TTL))" "⚠ ${label} · ${wtarget} ${wname}" >> "$TOAST_FILE"
    "$TOAST_BIN" prune >/dev/null 2>&1 || true
    toasted=1
  fi
  unlock

  if [ "$toasted" = 1 ]; then
    tmux set -g status 2 >/dev/null 2>&1 || true
    _refresh
    ( sleep "$TTL"; "$SELF" tick ) >/dev/null 2>&1 &
  fi
}

cmd_tick() {
  "$TOAST_BIN" prune >/dev/null 2>&1 || true
  local n=0
  [ -r "$TOAST_FILE" ] && n="$(awk -F '\t' -v now="$(date +%s)" '($1+0)>now' "$TOAST_FILE" | wc -l | tr -d ' ')"
  if have_tmux; then
    if [ "${n:-0}" -gt 0 ]; then tmux set -g status 2 >/dev/null 2>&1 || true
    else tmux set -g status on >/dev/null 2>&1 || true; fi
    tmux refresh-client -S >/dev/null 2>&1 || true
  fi
}

cmd_clear() {
  local pane="${1:-${TMUX_PANE:-}}"
  [ -n "$pane" ] || exit 0
  lock; _drop_panes "$pane"; unlock
  _refresh
}

cmd_clear_window() {
  local target="${1:-}"
  [ -n "$target" ] || exit 0
  have_tmux || exit 0
  local panes
  panes="$(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null || true)"
  [ -n "$panes" ] || return 0
  lock; _drop_panes "$panes"; unlock
  _refresh
}

cmd_clear_all() { lock; : > "$STATE_FILE"; unlock; _refresh; }

# Extract a JSON string field (jq if present, else sed best-effort).
_json_field() {
  local field="$1" json="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null || true
  else
    printf '%s' "$json" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

cmd_claude_mark() {  # Claude Notification (STDIN JSON, has .message)
  local json msg; json="$(cat 2>/dev/null || true)"
  msg="$(_json_field message "$json")"; [ -n "$msg" ] || msg="Claude needs input"
  cmd_mark "" claude "$msg"
}
cmd_claude_stop()  { cat >/dev/null 2>&1 || true; cmd_mark "" claude "Claude finished — your turn"; }
cmd_claude_clear() { cat >/dev/null 2>&1 || true; cmd_clear ""; }

cmd_codex() {  # Codex notify passes its event JSON as the last argv argument
  local json="${1:-}" type
  type="$(_json_field type "$json")"
  [ -n "$type" ] && cmd_mark "" codex "Codex: ${type}" || true
}

case "${1:-}" in
  mark)          shift; cmd_mark "${1:-}" "${2:-tool}" "${3:-needs input}" ;;
  clear)         shift; cmd_clear "${1:-}" ;;
  clear-window)  shift; cmd_clear_window "${1:-}" ;;
  clear-all)     cmd_clear_all ;;
  tick)          cmd_tick ;;
  claude-mark)   cmd_claude_mark ;;
  claude-stop)   cmd_claude_stop ;;
  claude-clear)  cmd_claude_clear ;;
  codex)         shift; cmd_codex "${1:-}" ;;
  *) echo "usage: needinput-notify.sh {mark|clear|clear-window <t>|clear-all|tick|claude-mark|claude-stop|claude-clear|codex <json>}" >&2; exit 2 ;;
esac

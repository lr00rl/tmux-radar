#!/usr/bin/env bash
# Create exactly one native supervisor surface for a target pane. The launcher
# owns tmux geometry only; the Go process owns input, rendering, and liveness.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AI_SCRIPT="${TMUX_RADAR_ENGINE_SCRIPT:-$ROOT/scripts/ai.sh}"
ENSURE_NATIVE="$ROOT/scripts/ensure-native.sh"
STATE_ROOT="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
TARGET_PANE="${1:-}"
ENTRY="${2:-quick}"

fail() {
  printf 'tmux-radar: %s\n' "$*" >&2
  tmux display-message -d 5000 "tmux-radar: $*" 2>/dev/null || true
  return 1
}

shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

state_value() {
  local path="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$path" 2>/dev/null || true
}

existing_run_active() {
  local key watch_file pid run_dir owner_file owner_kind owner_pane
  key="$(printf '%s' "$TARGET_PANE" | sed 's/[^a-zA-Z0-9_.-]/_/g')"
  watch_file="$STATE_ROOT/ai-watch/$key.watch"
  [ -r "$watch_file" ] || return 1
  pid="$(state_value "$watch_file" pid)"
  run_dir="$(state_value "$watch_file" run_dir)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$run_dir" ] && [ -d "$run_dir" ] && [ ! -e "$run_dir/final.json" ] || return 1

  owner_file="$(state_value "$watch_file" owner_file)"
  [ -n "$owner_file" ] || owner_file="$run_dir/owner.json"
  owner_kind="$(jq -r '.kind // empty' "$owner_file" 2>/dev/null || true)"
  owner_pane="$(jq -r '.pane // empty' "$owner_file" 2>/dev/null || true)"
  if [ "$owner_kind" = split ] && [ -n "$owner_pane" ]; then
    tmux select-pane -t "$owner_pane" 2>/dev/null || \
      tmux display-message "tmux-radar supervisor is already active for $TARGET_PANE" 2>/dev/null || true
  else
    tmux display-message "tmux-radar supervisor is already active for $TARGET_PANE" 2>/dev/null || true
  fi
  return 0
}

resolve_binary() {
  local candidate="${TMUX_RADAR_BIN:-}"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$ROOT/bin/tmux-radar"
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate="$(command -v tmux-radar 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ -x "$ENSURE_NATIVE" ]; then
    "$ENSURE_NATIVE" resolve 2>/dev/null || true
  fi
}

legacy_launch() {
  local command mode=quick preset=""
  case "$ENTRY" in
    quick) : ;;
    always-allow) preset=always-allow ;;
    advanced) mode=advanced ;;
    *) fail "unsupported setup entry: $ENTRY"; return 1 ;;
  esac
  command="exec $(shell_quote "${BASH:-bash}") $(shell_quote "$AI_SCRIPT") watch-setup $(shell_quote "$TARGET_PANE") $(shell_quote "$mode")"
  [ -z "$preset" ] || command="$command $(shell_quote "$preset")"
  tmux display-popup -E -w 90% -h 85% -t "$TARGET_PANE" "$command"
}

case "$TARGET_PANE" in
  %*) : ;;
  *) fail "target pane must be a tmux pane ID"; exit 2 ;;
esac
case "$TARGET_PANE" in *[!%0-9]*) fail "target pane must be a tmux pane ID"; exit 2 ;; esac
case "$ENTRY" in quick|always-allow|advanced) : ;; *) fail "unsupported setup entry: $ENTRY"; exit 2 ;; esac
[ -x "$AI_SCRIPT" ] || { fail "engine script is not executable: $AI_SCRIPT"; exit 3; }
[ "${TMUX_RADAR_LEGACY_UI:-0}" != 1 ] || { legacy_launch; exit $?; }

# Reject sequential duplicates before creating a pane or popup. The engine's
# atomic per-pane reservation remains authoritative for concurrent launches.
if existing_run_active; then
  exit 0
fi

BINARY="$(resolve_binary)"
[ -n "$BINARY" ] && [ -x "$BINARY" ] || {
  fail "native binary is unavailable; run scripts/ensure-native.sh install, scripts/build-native.sh, or set TMUX_RADAR_LEGACY_UI=1"
  exit 3
}
VERSION_OUTPUT="$($BINARY version 2>/dev/null || true)"
case "$VERSION_OUTPUT" in
  *"protocol 1"*) : ;;
  *) fail "native binary protocol mismatch (requires protocol 1)"; exit 5 ;;
esac

TARGET_WIDTH="$(tmux display-message -p -t "$TARGET_PANE" '#{pane_width}' 2>/dev/null || true)"
TARGET_HEIGHT="$(tmux display-message -p -t "$TARGET_PANE" '#{pane_height}' 2>/dev/null || true)"
case "$TARGET_WIDTH" in ''|*[!0-9]*) TARGET_WIDTH=120 ;; esac
case "$TARGET_HEIGHT" in ''|*[!0-9]*) TARGET_HEIGHT=30 ;; esac

BASE_COMMAND="exec $(shell_quote "$BINARY") supervisor setup --target-pane $(shell_quote "$TARGET_PANE") --entry $(shell_quote "$ENTRY") --engine-script $(shell_quote "$AI_SCRIPT") --state-root $(shell_quote "$STATE_ROOT")"
# @radar-ai-console: auto (right split when the target is wide enough, else
# popup) | popup (always overlay; never take columns from the work pane).
SURFACE_PREF="$(tmux show-option -gqv @radar-ai-console 2>/dev/null || true)"
case "$SURFACE_PREF" in auto|popup) ;; *) SURFACE_PREF=auto ;; esac
if [ "$SURFACE_PREF" = popup ] || [ "$TARGET_WIDTH" -lt 121 ] || [ "$TARGET_HEIGHT" -lt 24 ]; then
  POPUP_COMMAND="$BASE_COMMAND --surface popup"
  tmux display-popup -E -w 90% -h 85% -t "$TARGET_PANE" "$POPUP_COMMAND"
  exit $?
fi

REQUESTED_WIDTH="$(tmux show-option -gqv @radar-ai-monitor-size-h 2>/dev/null || true)"
case "$REQUESTED_WIDTH" in ''|*[!0-9]*) REQUESTED_WIDTH=84 ;; esac
[ "$REQUESTED_WIDTH" -ge 56 ] || REQUESTED_WIDTH=56
[ "$REQUESTED_WIDTH" -le 112 ] || REQUESTED_WIDTH=112
MAX_WIDTH=$((TARGET_WIDTH - 65))
[ "$REQUESTED_WIDTH" -le "$MAX_WIDTH" ] || REQUESTED_WIDTH="$MAX_WIDTH"
SPLIT_COMMAND="$BASE_COMMAND --surface split --monitor-pane \"\$TMUX_PANE\""
tmux split-window -h -l "$REQUESTED_WIDTH" -P -F '#{pane_id}' -t "$TARGET_PANE" "$SPLIT_COMMAND" >/dev/null

#!/usr/bin/env bash

umask 077

RADAR_STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
RADAR_WATCH_DIR="$RADAR_STATE_DIR/ai-watch"
RADAR_RUNS_DIR="$RADAR_STATE_DIR/ai-runs"

mkdir -p "$RADAR_STATE_DIR" "$RADAR_WATCH_DIR" "$RADAR_RUNS_DIR"

RADAR_RUN_ID="${RADAR_RUN_ID:-}"
RADAR_RUN_DIR="${RADAR_RUN_DIR:-}"
RADAR_RUN_PANE="${RADAR_RUN_PANE:-}"
RADAR_RUN_CHANNEL="${RADAR_RUN_CHANNEL:-}"

_radar_require_jq() {
  command -v jq >/dev/null 2>&1 || {
    printf 'tmux-radar runtime needs jq\n' >&2
    return 1
  }
}

_radar_now_iso() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_radar_run_stamp() {
  date '+%Y%m%d-%H%M%S'
}

_radar_pane_token() {
  local pane="${1:-}" token
  token="$(printf '%s' "$pane" | tr -cd 'A-Za-z0-9')"
  [ -n "$token" ] || token="pane"
  printf '%s' "$token"
}

_radar_watch_channel() {
  printf 'radar-run-%s' "$(_radar_pane_token "$1")"
}

_radar_watch_field() {
  local file="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$file" 2>/dev/null || true
}

_radar_write_snapshot() {
  local path="$1" payload="$2" dir tmp
  dir="$(dirname "$path")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 1
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$path"
}

_radar_json_number() {
  case "${1:-0}" in
    ''|*[!0-9-]*) printf '0' ;;
    *) printf '%s' "$1" ;;
  esac
}

_radar_append_jsonl() {
  local path="$1" payload="$2"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$payload" >> "$path"
}

_radar_watch_write() {
  local watch_file="$1" pane="$2" run_id="$3" run_dir="$4" pid="$5" channel="$6"
  local overview="${7:-}" detail="${8:-}"
  _radar_write_snapshot "$watch_file" "$(cat <<EOF
run_id=$run_id
run_dir=$run_dir
pid=$pid
pane=$pane
channel=$channel
monitor_overview_pane=$overview
monitor_detail_pane=$detail
EOF
)"
}

_radar_use_run() {
  RADAR_RUN_PANE="$1"
  RADAR_RUN_ID="$2"
  RADAR_RUN_DIR="$3"
  RADAR_RUN_CHANNEL="$4"
}

radar_watch_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'
}

radar_watch_file() {
  printf '%s/%s.watch' "$RADAR_WATCH_DIR" "$(radar_watch_key "$1")"
}

radar_run_create() {
  local pane="$1" config_json="$2"
  local pane_token stamp run_id run_dir watch_file channel config_payload
  _radar_require_jq || return 1
  mkdir -p "$RADAR_WATCH_DIR" "$RADAR_RUNS_DIR"
  pane_token="$(_radar_pane_token "$pane")"
  stamp="$(_radar_run_stamp)"
  run_id="${stamp}-${pane_token}-$$-${RANDOM:-0}"
  run_dir="$RADAR_RUNS_DIR/$run_id"
  watch_file="$(radar_watch_file "$pane")"
  channel="$(_radar_watch_channel "$pane")"
  mkdir -p "$run_dir"
  config_payload="$(
    jq -cn \
      --argjson config "$config_json" \
      --arg run_id "$run_id" \
      --arg pane "$pane" \
      --arg timestamp "$(_radar_now_iso)" \
      '$config + {run_id:$run_id, pane:$pane, created_at:$timestamp}'
  )" || return 1
  _radar_write_snapshot "$run_dir/config.json" "$config_payload" || return 1
  : > "$run_dir/events.jsonl"
  : > "$run_dir/inbox.jsonl"
  _radar_watch_write "$watch_file" "$pane" "$run_id" "$run_dir" "$$" "$channel" "" "" || return 1
  _radar_use_run "$pane" "$run_id" "$run_dir" "$channel"
}

radar_run_open() {
  local target="$1" watch_file run_dir run_id pane channel
  if [ -f "$target" ]; then
    watch_file="$target"
  else
    watch_file="$(radar_watch_file "$target")"
  fi
  [ -r "$watch_file" ] || return 1
  run_dir="$(_radar_watch_field "$watch_file" run_dir)"
  run_id="$(_radar_watch_field "$watch_file" run_id)"
  pane="$(_radar_watch_field "$watch_file" pane)"
  channel="$(_radar_watch_field "$watch_file" channel)"
  [ -n "$run_dir" ] || return 1
  _radar_use_run "$pane" "$run_id" "$run_dir" "$channel"
  printf '%s\n' "$run_dir"
}

radar_state_set() {
  local phase="$1" status="$2" next_kind="$3" next_at raw_next_at payload
  raw_next_at="$(_radar_json_number "${4:-0}")"
  _radar_require_jq || return 1
  [ -n "$RADAR_RUN_DIR" ] || return 1
  payload="$(
    jq -cn \
      --arg phase "$phase" \
      --arg status "$status" \
      --arg next_kind "$next_kind" \
      --argjson next_at "$raw_next_at" \
      --arg run_id "$RADAR_RUN_ID" \
      --arg pane "$RADAR_RUN_PANE" \
      --arg timestamp "$(_radar_now_iso)" \
      '{phase:$phase, status:$status, next:{kind:$next_kind, at:$next_at}, run_id:$run_id, pane:$pane, updated_at:$timestamp}'
  )" || return 1
  _radar_write_snapshot "$RADAR_RUN_DIR/state.json" "$payload"
}

_radar_current_event_json() {
  local kind="$1" source="$2" label="$3" extra_json="${4:-"{}"}"
  jq -cn \
    --arg kind "$kind" \
    --arg source "$source" \
    --arg label "$label" \
    --arg run_id "$RADAR_RUN_ID" \
    --arg pane "$RADAR_RUN_PANE" \
    --arg timestamp "$(_radar_now_iso)" \
    --argjson extra "$extra_json" \
    '($extra + {kind:$kind, source:$source, label:$label, run_id:$run_id, pane:$pane, timestamp:$timestamp})'
}

radar_event_append() {
  local payload extra_json="${4:-"{}"}"
  _radar_require_jq || return 1
  [ -n "$RADAR_RUN_DIR" ] || return 1
  payload="$(_radar_current_event_json "$1" "$2" "$3" "$extra_json")" || return 1
  _radar_append_jsonl "$RADAR_RUN_DIR/events.jsonl" "$payload"
}

radar_inbox_append() {
  local payload extra_json="${4:-"{}"}"
  _radar_require_jq || return 1
  [ -n "$RADAR_RUN_DIR" ] || return 1
  payload="$(_radar_current_event_json "$1" "$2" "$3" "$extra_json")" || return 1
  _radar_append_jsonl "$RADAR_RUN_DIR/inbox.jsonl" "$payload"
}

radar_inbox_drain() {
  local inbox_path tmp_path
  [ -n "$RADAR_RUN_DIR" ] || return 1
  inbox_path="$RADAR_RUN_DIR/inbox.jsonl"
  [ -s "$inbox_path" ] || return 0
  tmp_path="$(mktemp "$RADAR_RUN_DIR/.inbox.XXXXXX")" || return 1
  mv "$inbox_path" "$tmp_path"
  cat "$tmp_path"
  rm -f "$tmp_path"
  : > "$inbox_path"
}

radar_run_finalize() {
  local outcome="$1" reason="$2" payload
  _radar_require_jq || return 1
  [ -n "$RADAR_RUN_DIR" ] || return 1
  payload="$(
    jq -cn \
      --arg outcome "$outcome" \
      --arg reason "$reason" \
      --arg run_id "$RADAR_RUN_ID" \
      --arg pane "$RADAR_RUN_PANE" \
      --arg timestamp "$(_radar_now_iso)" \
      '{outcome:$outcome, reason:$reason, run_id:$run_id, pane:$pane, finalized_at:$timestamp}'
  )" || return 1
  _radar_write_snapshot "$RADAR_RUN_DIR/final.json" "$payload"
}

_radar_run_protected() {
  local run_dir="$1" watch_file watch_run_dir
  [ -d "$RADAR_WATCH_DIR" ] || return 1
  for watch_file in "$RADAR_WATCH_DIR"/*.watch; do
    [ -e "$watch_file" ] || continue
    watch_run_dir="$(_radar_watch_field "$watch_file" run_dir)"
    [ "$watch_run_dir" = "$run_dir" ] && return 0
  done
  return 1
}

radar_cleanup_runs() {
  local retention_days="${1:-7}" run_dir
  mkdir -p "$RADAR_RUNS_DIR"
  find "$RADAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$retention_days" 2>/dev/null |
    while IFS= read -r run_dir; do
      [ -n "$run_dir" ] || continue
      if _radar_run_protected "$run_dir"; then
        continue
      fi
      rm -rf "$run_dir"
    done
}

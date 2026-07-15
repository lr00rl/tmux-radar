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

_radar_inbox_dir() {
  printf '%s/inbox' "$RADAR_RUN_DIR"
}

_radar_inbox_batch_dir() {
  mktemp -d "$RADAR_RUN_DIR/.inbox-batch.XXXXXX"
}

_radar_inbox_publish_ready() {
  local tmp_path="$1" inbox_dir="$2" base_name ready_path attempt=0
  base_name="$(basename "$tmp_path")"
  base_name="${base_name#.tmp.}"
  while [ "$attempt" -lt 32 ]; do
    ready_path="$inbox_dir/$base_name"
    if [ "$attempt" -gt 0 ]; then
      ready_path="${ready_path}.${attempt}.${RANDOM}"
    fi
    ready_path="${ready_path}.ready"
    if ln "$tmp_path" "$ready_path" 2>/dev/null; then
      rm -f "$tmp_path" || true
      return 0
    fi
    attempt=$((attempt + 1))
  done
  rm -f "$tmp_path"
  return 1
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
  local pane_token stamp run_id run_dir watch_file channel config_payload created_epoch
  _radar_require_jq || return 1
  mkdir -p "$RADAR_WATCH_DIR" "$RADAR_RUNS_DIR"
  pane_token="$(_radar_pane_token "$pane")"
  stamp="$(_radar_run_stamp)"
  run_id="${stamp}-${pane_token}-$$-${RANDOM:-0}"
  run_dir="$RADAR_RUNS_DIR/$run_id"
  watch_file="$(radar_watch_file "$pane")"
  channel="$(_radar_watch_channel "$pane")"
  created_epoch="$(date '+%s')"
  mkdir -p "$run_dir"
  config_payload="$(
    jq -cn \
      --argjson config "$config_json" \
      --arg run_id "$run_id" \
      --arg pane "$pane" \
      --arg timestamp "$(_radar_now_iso)" \
      --argjson created_epoch "$created_epoch" \
      '$config + {schema_version:1, run_id:$run_id, pane:$pane, created_at:$timestamp, created_epoch:$created_epoch}'
  )" || return 1
  _radar_write_snapshot "$run_dir/config.json" "$config_payload" || return 1
  : > "$run_dir/events.jsonl"
  mkdir -p "$run_dir/inbox"
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
  local phase="$1" status="$2" next_kind="$3" raw_next_at payload
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
      '{schema_version:1, phase:$phase, status:$status, next:{kind:$next_kind, at:$next_at}, run_id:$run_id, pane:$pane, updated_at:$timestamp}'
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
    '($extra + {schema_version:1, kind:$kind, source:$source, label:$label, run_id:$run_id, pane:$pane, timestamp:$timestamp})'
}

radar_event_append() {
  local payload extra_json="${4:-"{}"}"
  _radar_require_jq || return 1
  [ -n "$RADAR_RUN_DIR" ] || return 1
  payload="$(_radar_current_event_json "$1" "$2" "$3" "$extra_json")" || return 1
  _radar_append_jsonl "$RADAR_RUN_DIR/events.jsonl" "$payload"
}

radar_inbox_append() {
  local payload extra_json="${4:-"{}"}" inbox_dir tmp_path
  _radar_require_jq || return 1
  [ -n "$RADAR_RUN_DIR" ] || return 1
  payload="$(_radar_current_event_json "$1" "$2" "$3" "$extra_json")" || return 1
  inbox_dir="$(_radar_inbox_dir)"
  mkdir -p "$inbox_dir"
  tmp_path="$(mktemp "$inbox_dir/.tmp.XXXXXX")" || return 1
  if ! printf '%s\n' "$payload" > "$tmp_path"; then
    rm -f "$tmp_path"
    return 1
  fi
  if ! _radar_inbox_publish_ready "$tmp_path" "$inbox_dir"; then
    return 1
  fi
}

radar_inbox_drain() {
  local inbox_dir batch_dir ready_path batch_path moved=0
  [ -n "$RADAR_RUN_DIR" ] || return 1
  inbox_dir="$(_radar_inbox_dir)"
  mkdir -p "$inbox_dir"
  batch_dir="$(_radar_inbox_batch_dir)" || return 1
  for ready_path in "$inbox_dir"/*.ready; do
    [ -e "$ready_path" ] || continue
    batch_path="$batch_dir/$(basename "$ready_path")"
    if mv "$ready_path" "$batch_path" 2>/dev/null; then
      moved=1
    fi
  done
  if [ "$moved" -eq 0 ]; then
    rmdir "$batch_dir" 2>/dev/null || rm -rf "$batch_dir"
    return 0
  fi
  if ! cat "$batch_dir"/*.ready; then
    return 1
  fi
  rm -rf "$batch_dir"
}

radar_run_finalize() {
  local outcome="$1" reason="$2" payload config events latest_decision
  local now_epoch created_epoch duration event_count decision_count action_count error_count goal goal_status
  _radar_require_jq || return 1
  [ -n "$RADAR_RUN_DIR" ] || return 1
  config="$RADAR_RUN_DIR/config.json"
  events="$RADAR_RUN_DIR/events.jsonl"
  now_epoch="$(date '+%s')"
  created_epoch="$(jq -r '.created_epoch // 0' "$config" 2>/dev/null || printf 0)"
  case "$created_epoch" in ''|*[!0-9]*) created_epoch=0 ;; esac
  [ "$created_epoch" -gt 0 ] || created_epoch="$now_epoch"
  duration=$((now_epoch - created_epoch)); [ "$duration" -ge 0 ] || duration=0
  goal="$(jq -r '.goal // .values.goal.value // ""' "$config" 2>/dev/null || true)"
  if [ -s "$events" ]; then
    event_count="$(jq -s 'length' "$events" 2>/dev/null || printf 0)"
    action_count="$(jq -s '[.[] | select(.sent == true)] | length' "$events" 2>/dev/null || printf 0)"
    error_count="$(jq -s '[.[] | select(
      (.kind // "" | test("failed|error|warning"; "i")) or
      (.phase // "" | test("ERROR"; "i")) or
      (.record // "" | test("error|warning"; "i"))
    )] | length' "$events" 2>/dev/null || printf 0)"
  else
    event_count=0; action_count=0; error_count=0
  fi
  decision_count=0; latest_decision=""
  if [ -d "$RADAR_RUN_DIR/decisions" ]; then
    decision_count="$(find "$RADAR_RUN_DIR/decisions" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9].json' 2>/dev/null | wc -l | tr -d '[:space:]')"
    latest_decision="$(find "$RADAR_RUN_DIR/decisions" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9].json' 2>/dev/null | sort | tail -n 1)"
  fi
  goal_status=""
  [ -n "$latest_decision" ] && goal_status="$(jq -r '.goal_status // ""' "$latest_decision" 2>/dev/null || true)"
  payload="$(
    jq -cn \
      --arg outcome "$outcome" \
      --arg reason "$reason" \
      --arg run_id "$RADAR_RUN_ID" \
      --arg pane "$RADAR_RUN_PANE" \
      --arg goal "$goal" \
      --arg goal_status "$goal_status" \
      --arg log_path "$RADAR_RUN_DIR" \
      --arg timestamp "$(_radar_now_iso)" \
      --argjson finalized_epoch "$now_epoch" \
      --argjson duration_seconds "$duration" \
      --argjson event_count "${event_count:-0}" \
      --argjson decision_count "${decision_count:-0}" \
      --argjson action_count "${action_count:-0}" \
      --argjson error_count "${error_count:-0}" \
      '{schema_version:1, outcome:$outcome, reason:$reason, run_id:$run_id, pane:$pane,
        goal:$goal, goal_status:$goal_status, duration_seconds:$duration_seconds,
        event_count:$event_count, decision_count:$decision_count,
        action_count:$action_count, error_count:$error_count,
        log_path:$log_path, finalized_at:$timestamp, finalized_epoch:$finalized_epoch}'
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
  local retention_days="${1:-7}" run_dir final_epoch cutoff now_epoch mtime
  mkdir -p "$RADAR_RUNS_DIR"
  case "$retention_days" in ''|*[!0-9]*) retention_days=7 ;; esac
  now_epoch="$(date '+%s')"; cutoff=$((now_epoch - retention_days * 86400))
  for run_dir in "$RADAR_RUNS_DIR"/*; do
    [ -d "$run_dir" ] || continue
    _radar_run_protected "$run_dir" && continue
    final_epoch="$(jq -r '.finalized_epoch // 0' "$run_dir/final.json" 2>/dev/null || printf 0)"
    case "$final_epoch" in ''|*[!0-9]*) final_epoch=0 ;; esac
    if [ "$final_epoch" -le 0 ]; then
      mtime="$(stat -f '%m' "$run_dir/final.json" 2>/dev/null || stat -c '%Y' "$run_dir/final.json" 2>/dev/null || printf 0)"
      case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
      final_epoch="$mtime"
    fi
    [ "$final_epoch" -gt 0 ] || continue
    [ "$final_epoch" -le "$cutoff" ] || continue
    rm -rf "$run_dir"
  done
}

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir runtime)"
CLEANUP_PIDS=""
TEST_EXIT_CODE=0
trap 'TEST_EXIT_CODE=$?' ERR
SYSTEM_MV="$(command -v mv)"

cleanup() {
  local rc="${TEST_EXIT_CODE:-$?}"
  for pid in $CLEANUP_PIDS; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
  exit "$rc"
}

append_capture() {
  local file="$1" chunk="$2"
  [ -n "$chunk" ] || return 0
  printf '%s\n' "$chunk" >> "$file"
}

drain_into() {
  local file="$1" chunk=""
  if ! chunk="$(radar_inbox_drain)"; then
    _fail_assert "radar_inbox_drain failed" "run_dir" "$RADAR_RUN_DIR"
  fi
  append_capture "$file" "$chunk"
}

export TMUX_RADAR_STATE_DIR="$TMP/state"
if ! source "$ROOT/scripts/lib/ai-runtime.sh"; then
  exit 1
fi
trap cleanup EXIT

config='{"goal":"监控到测试全绿","values":{"timeout":{"value":"60","source":"custom"}}}'
radar_run_create %39 "$config"
assert_file "$RADAR_RUN_DIR/config.json"
assert_json "$RADAR_RUN_DIR/config.json" '.goal == "监控到测试全绿"'
assert_eq "600" "$(stat -f '%Lp' "$RADAR_RUN_DIR/config.json")" "config.json mode"
assert_file "$(radar_watch_file %39)"

opened_run_dir="$(radar_run_open %39)"
assert_eq "$RADAR_RUN_DIR" "$opened_run_dir" "open by pane returns run directory"

watch_file_path="$(radar_watch_file %39)"
opened_from_watch_file="$(radar_run_open "$watch_file_path")"
assert_eq "$RADAR_RUN_DIR" "$opened_from_watch_file" "open by watch file returns run directory"

assert_eq "$RADAR_RUN_ID" "$(jq -r '.run_id' "$RADAR_RUN_DIR/config.json")" "config run id"
assert_eq "%39" "$(jq -r '.pane' "$RADAR_RUN_DIR/config.json")" "config pane"

watch_contents="$(cat "$(radar_watch_file %39)")"
assert_contains "$watch_contents" "run_id=$RADAR_RUN_ID" "watch run_id"
assert_contains "$watch_contents" "run_dir=$RADAR_RUN_DIR" "watch run_dir"
assert_contains "$watch_contents" "pid=$$" "watch pid"
assert_contains "$watch_contents" "pane=%39" "watch pane"
assert_contains "$watch_contents" "channel=radar-run-39" "watch channel"
assert_contains "$watch_contents" "monitor_overview_pane=" "watch overview pane key"
assert_contains "$watch_contents" "monitor_detail_pane=" "watch detail pane key"

radar_state_set ARMED "waiting for hook" none 0
assert_json "$RADAR_RUN_DIR/state.json" '.phase == "ARMED" and .status == "waiting for hook" and .next.kind == "none" and .next.at == 0 and .run_id == "'"$RADAR_RUN_ID"'"'

radar_event_append approval codex "Codex needs approval" '{}'
assert_json "$RADAR_RUN_DIR/events.jsonl" 'select(.kind == "approval" and .source == "codex" and .label == "Codex needs approval" and .run_id == "'"$RADAR_RUN_ID"'")'

radar_inbox_append user_resumed hook "User resumed flow" '{"pane_title":"测试面板"}'
if ! drained_once="$(radar_inbox_drain)"; then
  _fail_assert "initial radar_inbox_drain failed" "run_dir" "$RADAR_RUN_DIR"
fi
assert_contains "$drained_once" '"kind":"user_resumed"' "inbox drain contains event"
assert_contains "$drained_once" '测试面板' "inbox drain preserves CJK"
assert_eq "" "$(radar_inbox_drain)" "second inbox drain empty"

radar_run_finalize completed "goal reached"
assert_json "$RADAR_RUN_DIR/final.json" '.outcome == "completed" and .reason == "goal reached" and .run_id == "'"$RADAR_RUN_ID"'"'
assert_eq "600" "$(stat -f '%Lp' "$RADAR_RUN_DIR/final.json")" "final.json mode"

stale_dir="$RADAR_RUNS_DIR/19990101-000000-pane-111"
mkdir -p "$stale_dir"
cat > "$stale_dir/final.json" <<'EOF'
{"outcome":"completed","reason":"stale"}
EOF
touch -t 199901010000 "$stale_dir" "$stale_dir/final.json"

active_dir="$RADAR_RUNS_DIR/19990101-000001-pane-222"
mkdir -p "$active_dir"
cat > "$active_dir/final.json" <<'EOF'
{"outcome":"completed","reason":"active"}
EOF
touch -t 199901010000 "$active_dir" "$active_dir/final.json"
active_watch="$(radar_watch_file %88)"
mkdir -p "$(dirname "$active_watch")"
cat > "$active_watch" <<EOF
run_id=19990101-000001-pane-222
run_dir=$active_dir
pid=222
pane=%88
channel=radar-run-88
monitor_overview_pane=
monitor_detail_pane=
EOF
radar_cleanup_runs 1

if [ -e "$stale_dir" ]; then
  _fail_assert "stale inactive run should be removed" "run_dir" "$stale_dir"
fi
if [ ! -e "$active_dir" ]; then
  _fail_assert "active run referenced by watch file must be retained" "run_dir" "$active_dir"
fi

radar_run_create %55 '{"goal":"stale reclaim regression"}'
stale_reclaim_run_dir="$RADAR_RUN_DIR"
stale_reclaim_lock="$stale_reclaim_run_dir/inbox.jsonl.lock"
stale_reclaim_output="$TMP/stale-reclaim.jsonl"
: > "$stale_reclaim_output"
mkdir -p "$stale_reclaim_lock"
printf '%s\n' 999999 > "$stale_reclaim_lock/pid"
touch -t 199901010000 "$stale_reclaim_lock" "$stale_reclaim_lock/pid"

(
  RADAR_TEST_LOCK_RECLAIM_MARK="$TMP/reclaim-a.mark"
  RADAR_TEST_LOCK_RECLAIM_WAIT="$TMP/reclaim-a.release"
  RADAR_TEST_LOCK_RECLAIM_DONE_MARK="$TMP/reclaim-a.done"
  radar_inbox_append approval reclaim "event 1" '{"event_id":1}'
) &
stale_a_pid=$!
CLEANUP_PIDS="$CLEANUP_PIDS $stale_a_pid"
wait_for_file "$TMP/reclaim-a.mark"

(
  RADAR_TEST_LOCK_ACQUIRE_MARK="$TMP/reclaim-b.mark"
  RADAR_TEST_LOCK_ACQUIRE_WAIT="$TMP/reclaim-b.release"
  radar_inbox_append approval reclaim "event 2" '{"event_id":2}'
) &
stale_b_pid=$!
CLEANUP_PIDS="$CLEANUP_PIDS $stale_b_pid"
wait_for_file "$TMP/reclaim-b.mark"
assert_file "$stale_reclaim_lock/pid"

: > "$TMP/reclaim-a.release"
wait_for_file "$TMP/reclaim-a.done"
assert_file "$stale_reclaim_lock/pid"

: > "$TMP/reclaim-b.release"
wait_for_exit "$stale_b_pid"
wait_for_exit "$stale_a_pid"
wait "$stale_b_pid"
wait "$stale_a_pid"

drain_into "$stale_reclaim_output"
assert_eq "2" "$(jq -s 'length' "$stale_reclaim_output")" "stale reclaim event count"
if ! jq -se '
  length == 2 and
  ([.[].event_id] | sort == [1, 2])
' "$stale_reclaim_output" >/dev/null; then
  _fail_assert "stale reclaim must preserve exact-once inbox events" "file" "$stale_reclaim_output" "actual" "$(cat "$stale_reclaim_output")"
fi
CLEANUP_PIDS=""

radar_run_create %77 '{"goal":"concurrency regression"}'
concurrency_run_dir="$RADAR_RUN_DIR"
concurrency_output="$TMP/concurrency-drain.jsonl"
concurrency_expected=48
: > "$concurrency_output"

mv() {
  if [ "${RADAR_TEST_SLOW_INBOX_RENAME:-0}" = 1 ] && [ "$#" -ge 2 ] &&
    [ "$1" = "$concurrency_run_dir/inbox.jsonl" ]; then
    "$SYSTEM_MV" "$@"
    sleep 0.02
    return
  fi
  "$SYSTEM_MV" "$@"
}

RADAR_TEST_SLOW_INBOX_RENAME=1
append_pids=""
i=0
while [ "$i" -lt 4 ]; do
  (
    start=$((i * 12 + 1))
    finish=$((start + 11))
    event_id="$start"
    while [ "$event_id" -le "$finish" ]; do
      radar_inbox_append approval hook "event $event_id" "{\"event_id\":$event_id}"
      sleep 0.003
      event_id=$((event_id + 1))
    done
  ) &
  append_pids="$append_pids $!"
  CLEANUP_PIDS="$CLEANUP_PIDS $!"
  i=$((i + 1))
done

drain_round=0
while :; do
  drain_into "$concurrency_output"
  live_appenders=0
  for pid in $append_pids; do
    if kill -0 "$pid" 2>/dev/null; then
      live_appenders=1
      break
    fi
  done
  if [ "$live_appenders" -eq 0 ] && [ "$drain_round" -ge 10 ]; then
    break
  fi
  sleep 0.004
  drain_round=$((drain_round + 1))
done

for pid in $append_pids; do
  wait "$pid"
done
CLEANUP_PIDS=""
drain_into "$concurrency_output"
unset -f mv
RADAR_TEST_SLOW_INBOX_RENAME=0

line_count="$(awk 'END { print NR + 0 }' "$concurrency_output")"
parsed_count="$(jq -s 'length' "$concurrency_output")"
assert_eq "$line_count" "$parsed_count" "every drained line parses as JSON"
assert_eq "$concurrency_expected" "$parsed_count" "all concurrent inbox events accounted for"
if ! jq -se '
  length == 48 and
  ([.[].event_id] | sort == [range(1; 49)])
' "$concurrency_output" >/dev/null; then
  _fail_assert "concurrent drains must preserve every event exactly once" "file" "$concurrency_output" "actual" "$(cat "$concurrency_output")"
fi

printf 'PASS: structured run runtime\n'

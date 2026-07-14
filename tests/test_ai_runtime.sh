#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir runtime)"
CLEANUP_PIDS=""
TEST_EXIT_CODE=0
trap 'TEST_EXIT_CODE=$?' ERR
SYSTEM_MKTEMP="$(command -v mktemp)"

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
assert_json "$RADAR_RUN_DIR/final.json" '
  .outcome == "completed" and .reason == "goal reached" and
  .run_id == "'"$RADAR_RUN_ID"'" and .goal == "监控到测试全绿" and
  .duration_seconds >= 0 and .event_count == 1 and .decision_count == 0 and
  .action_count == 0 and .error_count == 0 and
  .log_path == "'"$RADAR_RUN_DIR"'" and .finalized_epoch > 0
'
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

radar_run_create %66 '{"goal":"no-clobber publication regression"}'
no_clobber_run_dir="$RADAR_RUN_DIR"
no_clobber_inbox_dir="$no_clobber_run_dir/inbox"
no_clobber_output="$TMP/no-clobber.jsonl"
radar_inbox_append approval hook "event 1" '{"event_id":1}'
existing_ready_file="$(find "$no_clobber_inbox_dir" -maxdepth 1 -name '*.ready' -print -quit)"
existing_ready_base="$(basename "$existing_ready_file" .ready)"
mktemp() {
  if [ "${RADAR_TEST_COLLIDE_MKTEMP:-0}" = 1 ] &&
    [ "$#" -eq 1 ] &&
    [ "$1" = "$no_clobber_inbox_dir/.tmp.XXXXXX" ]; then
    collision_path="$no_clobber_inbox_dir/.tmp.$existing_ready_base"
    : > "$collision_path"
    printf '%s\n' "$collision_path"
    RADAR_TEST_COLLIDE_MKTEMP=0
    return 0
  fi
  "$SYSTEM_MKTEMP" "$@"
}
RADAR_TEST_COLLIDE_MKTEMP=1
radar_inbox_append approval hook "event 2" '{"event_id":2}'
unset -f mktemp
assert_eq "2" "$(find "$no_clobber_inbox_dir" -maxdepth 1 -name '*.ready' | wc -l | tr -d '[:space:]')" "no-clobber publication keeps both ready files"
drain_into "$no_clobber_output"
assert_eq "2" "$(jq -s 'length' "$no_clobber_output")" "no-clobber drain event count"
if ! jq -se '
  length == 2 and
  ([.[].event_id] | sort == [1, 2])
' "$no_clobber_output" >/dev/null; then
  _fail_assert "no-clobber publication must keep both events" "file" "$no_clobber_output" "actual" "$(cat "$no_clobber_output")"
fi

radar_run_create %67 '{"goal":"read failure preservation regression"}'
read_failure_run_dir="$RADAR_RUN_DIR"
read_failure_inbox_dir="$read_failure_run_dir/inbox"
read_failure_output="$TMP/read-failure.jsonl"
read_failure_recovered="$TMP/read-failure-recovered.jsonl"
radar_inbox_append approval hook "event 1" '{"event_id":1}'
cat() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      "$read_failure_run_dir"/.inbox-batch.*/*.ready) return 1 ;;
    esac
  done
  command cat "$@"
}
if radar_inbox_drain > "$read_failure_output"; then
  _fail_assert "radar_inbox_drain should fail when batch read fails" "run_dir" "$read_failure_run_dir"
fi
unset -f cat
read_failure_batch_dir="$(find "$read_failure_run_dir" -maxdepth 1 -type d -name '.inbox-batch.*' -print -quit)"
assert_file "$read_failure_batch_dir/$(basename "$(find "$read_failure_batch_dir" -maxdepth 1 -name '*.ready' -print -quit)")"
mv "$(find "$read_failure_batch_dir" -maxdepth 1 -name '*.ready' -print -quit)" "$read_failure_inbox_dir/"
rmdir "$read_failure_batch_dir"
drain_into "$read_failure_recovered"
assert_eq "1" "$(jq -s 'length' "$read_failure_recovered")" "read failure preserved claimed event"
assert_json "$read_failure_recovered" 'select(.event_id == 1)'

radar_run_create %77 '{"goal":"concurrency regression"}'
concurrency_run_dir="$RADAR_RUN_DIR"
concurrency_inbox_dir="$concurrency_run_dir/inbox"
concurrency_output_a="$TMP/concurrency-drain-a.jsonl"
concurrency_output_b="$TMP/concurrency-drain-b.jsonl"
concurrency_output_final="$TMP/concurrency-drain-final.jsonl"
concurrency_output_all="$TMP/concurrency-drain-all.jsonl"
concurrency_expected=48
partial_tmp="$(mktemp "$concurrency_inbox_dir/.tmp.partial.XXXXXX")"
printf '%s' '{"event_id":999' > "$partial_tmp"
: > "$concurrency_output_a"
: > "$concurrency_output_b"
: > "$concurrency_output_final"
: > "$concurrency_output_all"

drainer_loop() {
  local outfile="$1" rounds="$2" delay="$3" round=0
  while [ "$round" -lt "$rounds" ]; do
    drain_into "$outfile"
    sleep "$delay"
    round=$((round + 1))
  done
}

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

drainer_loop "$concurrency_output_a" 40 0.004 &
drainer_a_pid=$!
CLEANUP_PIDS="$CLEANUP_PIDS $drainer_a_pid"
drainer_loop "$concurrency_output_b" 40 0.004 &
drainer_b_pid=$!
CLEANUP_PIDS="$CLEANUP_PIDS $drainer_b_pid"

for pid in $append_pids; do
  wait "$pid"
done
wait "$drainer_a_pid"
wait "$drainer_b_pid"
drain_into "$concurrency_output_final"
assert_file "$partial_tmp"
rm -f "$partial_tmp"
CLEANUP_PIDS=""

cat "$concurrency_output_a" "$concurrency_output_b" "$concurrency_output_final" > "$concurrency_output_all"
line_count="$(awk 'END { print NR + 0 }' "$concurrency_output_all")"
parsed_count="$(jq -s 'length' "$concurrency_output_all")"
assert_eq "$line_count" "$parsed_count" "every drained line parses as JSON"
assert_eq "$concurrency_expected" "$parsed_count" "all concurrent inbox events accounted for"
if ! jq -se '
  length == 48 and
  ([.[].event_id] | sort == [range(1; 49)]) and
  ([.[].event_id] | index(999) | not)
' "$concurrency_output_all" >/dev/null; then
  _fail_assert "concurrent drains must preserve every event exactly once" "file" "$concurrency_output_all" "actual" "$(cat "$concurrency_output_all")"
fi

printf 'PASS: structured run runtime\n'

#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir runtime)"
CHILD_PID=""
TEST_EXIT_CODE=0
trap 'TEST_EXIT_CODE=$?' ERR

cleanup() {
  local rc="${TEST_EXIT_CODE:-$?}"
  if [ -n "$CHILD_PID" ]; then
    kill -KILL "$CHILD_PID" 2>/dev/null || true
    wait "$CHILD_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  exit "$rc"
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
drained_once="$(radar_inbox_drain)"
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

sleep 5 &
CHILD_PID=$!
wait_for_file "$RADAR_RUN_DIR/final.json"
radar_cleanup_runs 1

if [ -e "$stale_dir" ]; then
  _fail_assert "stale inactive run should be removed" "run_dir" "$stale_dir"
fi
if [ ! -e "$active_dir" ]; then
  _fail_assert "active run referenced by watch file must be retained" "run_dir" "$active_dir"
fi

printf 'PASS: structured run runtime\n'

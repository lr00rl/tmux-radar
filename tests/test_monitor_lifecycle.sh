#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir monitor-lifecycle)"
MONITOR_PID=""
cleanup() {
  local rc="${1:-$?}"
  trap - EXIT TERM INT HUP
  if [ -n "$MONITOR_PID" ] && kill -0 "$MONITOR_PID" 2>/dev/null; then
    kill -KILL "$MONITOR_PID" 2>/dev/null || true
    wait "$MONITOR_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

STATE="$TMP/state"
RUN="$STATE/ai-runs/stale-run"
WATCH="$STATE/ai-watch/_1.watch"
mkdir -p "$RUN/inbox" "$(dirname "$WATCH")"

cat > "$WATCH" <<EOF
run_id=stale-run
run_dir=$RUN
generation=stale-generation
pid=999999
pane=%1
started=1
poll=5
EOF
cat > "$RUN/config.json" <<'EOF'
{"schema_version":1,"run_id":"stale-run","pane":"%1","goal":"test","values":{}}
EOF
cat > "$RUN/state.json" <<'EOF'
{"schema_version":1,"run_id":"stale-run","pane":"%1","phase":"ARMED","status":"waiting","calls":0,"max_calls":1,"retry":0,"poll":5,"next":{"kind":"event","at":0}}
EOF
: > "$RUN/events.jsonl"

if output="$(TMUX_RADAR_STATE_DIR="$STATE" TMUX_RADAR_MONITOR_COLS=80 \
  bash "$ROOT/scripts/ai-monitor.sh" overview %1 --once 2>&1)"; then
  _fail_assert 'legacy monitor accepted a pointer whose watcher PID is dead' \
    'output' "$output"
fi
assert_contains "$output" 'no live run' 'stale watcher rejection is explicit'

LIVE_RUN="$STATE/ai-runs/live-run"
mkdir -p "$LIVE_RUN/inbox"
cat > "$WATCH" <<EOF
run_id=live-run
run_dir=$LIVE_RUN
generation=live-generation
pid=$$
pane=%1
started=$(date '+%s')
poll=5
EOF
cat > "$LIVE_RUN/config.json" <<'EOF'
{"schema_version":1,"run_id":"live-run","pane":"%1","goal":"test","values":{}}
EOF
cat > "$LIVE_RUN/state.json" <<'EOF'
{"schema_version":1,"run_id":"live-run","pane":"%1","phase":"ARMED","status":"waiting","calls":0,"max_calls":1,"retry":0,"poll":5,"next":{"kind":"event","at":0}}
EOF
cat > "$LIVE_RUN/start.json" <<EOF
{"schema_version":1,"run_id":"live-run","generation":"live-generation","watcher_pid":$$}
EOF
: > "$LIVE_RUN/events.jsonl"

cat > "$TMP/fake-ai" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_CONTROL_LOG"
exit 0
EOF
chmod +x "$TMP/fake-ai"
export TEST_CONTROL_LOG="$TMP/control.log"
: > "$TEST_CONTROL_LOG"

run_monitor_signal() {
  local signal="$1" expected_rc="$2" monitor_rc=0
  : > "$TMP/monitor.out"
  : > "$TMP/monitor.err"
  set +e
  TMUX_RADAR_STATE_DIR="$STATE" TMUX_RADAR_AI_SCRIPT="$TMP/fake-ai" \
    TMUX_RADAR_MONITOR_COLS=80 bash -c '
      signal="$1"; script="$2"
      (/bin/sleep 0.2; kill -"$signal" "$$") &
      exec bash "$script" overview %1
    ' _ "$signal" "$ROOT/scripts/ai-monitor.sh" \
    >"$TMP/monitor.out" 2>"$TMP/monitor.err"
  monitor_rc=$?
  set -e
  assert_eq "$expected_rc" "$monitor_rc" "$signal exit status"
}

run_monitor_signal TERM 143
run_monitor_signal INT 130
run_monitor_signal HUP 143

assert_contains "$(cat "$TEST_CONTROL_LOG")" 'control live-run %1 stop monitor.' \
  'signal cleanup uses run-scoped native stop'
assert_eq 3 "$(wc -l < "$TEST_CONTROL_LOG" | tr -d ' ')" \
  'every signal requests one exact-run stop'

printf 'PASS: legacy monitor rejects stale ownership and TERM/INT/HUP stop the exact run\n'

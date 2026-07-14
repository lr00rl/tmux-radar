#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir ai-supervision)"
WATCH_PID=""
RUN_DIR=""
OLD_PATH="$PATH"

cleanup() {
  local rc="${1:-$?}"
  if [ -n "$WATCH_PID" ]; then
    kill -TERM "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  PATH="$OLD_PATH"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'cleanup $?' EXIT

wait_until() {
  local description="$1" command="$2" attempts="${3:-160}" i=0
  while [ "$i" -lt "$attempts" ]; do
    if eval "$command"; then return 0; fi
    sleep 0.025
    i=$((i + 1))
  done
  _fail_assert "timed out waiting for $description" "command" "$command"
}

assert_process_gone() {
  local pid="$1" context="$2"
  [ -n "$pid" ] || return 0
  if kill -0 "$pid" 2>/dev/null; then
    _fail_assert "process survived ($context)" "pid" "$pid"
  fi
}

assert_process_group_gone() {
  local pgid="$1" context="$2"
  [ -n "$pgid" ] || return 0
  if kill -0 -- "-$pgid" 2>/dev/null; then
    _fail_assert "process group survived ($context)" "pgid" "$pgid"
  fi
}

write_fakes() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
set -eu
cmd="${1:-}"
shift || true
case "$cmd" in
  list-sessions) exit 0 ;;
  show-option)
    key=""
    for arg in "$@"; do key="$arg"; done
    case "$key" in
      @radar-ai-timeout|@switcher-ai-timeout) printf '%s\n' "${TEST_AI_TIMEOUT:-5}" ;;
      @radar-ai-max-calls|@switcher-ai-max-calls) printf '%s\n' "${TEST_MAX_CALLS:-40}" ;;
      @radar-ai-capture-lines|@switcher-ai-capture-lines) printf '%s\n' 120 ;;
      @radar-ai-monitor-excerpt-lines|@switcher-ai-monitor-excerpt-lines) printf '%s\n' 16 ;;
      *) exit 0 ;;
    esac
    ;;
  display-message)
    [ -f "$TEST_PANE_ALIVE" ] || exit 1
    case "$*" in
      *pane_id*) printf '%s\n' '%1' ;;
      *) printf '%s\n' 'test:0.0 codex' ;;
    esac
    ;;
  capture-pane)
    [ -f "$TEST_PANE_ALIVE" ] || exit 1
    cat "$TEST_SCREEN"
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$TEST_SENDS"
    ;;
  wait-for)
    if [ "${1:-}" = -S ]; then
      shift
      : > "$TEST_SIGNALS/${1}.signal"
      exit 0
    fi
    channel="${1:-}"
    printf '%s\n' "$$" >> "$TEST_WAITER_PIDS"
    while [ ! -e "$TEST_SIGNALS/$channel.signal" ]; do sleep 0.01; done
    rm -f "$TEST_SIGNALS/$channel.signal"
    ;;
  *) exit 0 ;;
esac
TMUXEOF
  chmod +x "$TMP/bin/tmux"
  printf '%s\n' 'tmux() { "$TEST_FAKE_TMUX" "$@"; }' > "$TMP/bashenv"

  cat > "$TMP/bin/fake-backend" <<'BACKENDEOF'
#!/usr/bin/env bash
set -eu
cat >/dev/null
printf '%s\n' "${TMUX_RADAR_INTERNAL:-}" >> "$TEST_INTERNAL_LOG"
mkdir "$TEST_ACTIVE_LOCK" 2>/dev/null || {
  printf 'concurrent\n' >> "$TEST_CONCURRENT"
  while ! mkdir "$TEST_ACTIVE_LOCK" 2>/dev/null; do sleep 0.01; done
}
active=1
[ -s "$TEST_MAX_ACTIVE" ] && active="$(cat "$TEST_MAX_ACTIVE")"
[ "$active" -ge 1 ] || active=1
printf '%s\n' "$active" > "$TEST_MAX_ACTIVE"
call=1
[ -s "$TEST_CALL_COUNT" ] && call=$(( $(cat "$TEST_CALL_COUNT") + 1 ))
printf '%s\n' "$call" > "$TEST_CALL_COUNT"
printf '%s\n' "$call" >> "$TEST_MODEL_CALLS"
printf '%s %s\n' "$$" "$(ps -o pgid= -p $$ | tr -d ' ')" >> "$TEST_BACKEND_PIDS"
if [ "${TEST_BACKEND_NOTIFY:-0}" = 1 ]; then
  TMUX_PANE=%1 bash "$TEST_ROOT/scripts/needinput-notify.sh" codex-hook <<<'{"hook_event_name":"PermissionRequest"}'
fi
while [ -e "$TEST_BLOCK_BACKEND" ]; do sleep 0.01; done
response="$TEST_RESPONSES/$call.json"
if [ -f "$response" ]; then cat "$response"; fi
rm -rf "$TEST_ACTIVE_LOCK"
BACKENDEOF
  chmod +x "$TMP/bin/fake-backend"
}

reset_case() {
  local name="$1"
  if [ -n "$WATCH_PID" ]; then
    kill -TERM "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
  fi
  CASE="$TMP/$name"
  mkdir -p "$CASE/state" "$CASE/signals" "$CASE/responses"
  export TMUX_RADAR_STATE_DIR="$CASE/state"
  export TMUX_RADAR_NEEDINPUT_FILE="$CASE/state/need-input"
  export TMUX_RADAR_AI_CMD="$TMP/bin/fake-backend"
  export TMUX_RADAR_TEST_RETRY_DELAYS="0.02,0.02,0.02"
  export TMUX_RADAR_TEST_VERIFY_TIMEOUT="2"
  export TMUX_RADAR_TEST_WAIT_TICK="0.01"
  export TEST_PANE_ALIVE="$CASE/pane-alive"
  export TEST_FAKE_TMUX="$TMP/bin/tmux"
  export BASH_ENV="$TMP/bashenv"
  export TEST_SCREEN="$CASE/screen"
  export TEST_SENDS="$CASE/sends"
  export TEST_SIGNALS="$CASE/signals"
  export TEST_MODEL_CALLS="$CASE/model.calls"
  export TEST_CALL_COUNT="$CASE/call-count"
  export TEST_INTERNAL_LOG="$CASE/internal.log"
  export TEST_ACTIVE_LOCK="$CASE/active.lock"
  export TEST_MAX_ACTIVE="$CASE/max-active"
  export TEST_CONCURRENT="$CASE/concurrent"
  export TEST_BACKEND_PIDS="$CASE/backend.pids"
  export TEST_WAITER_PIDS="$CASE/waiter.pids"
  export TEST_BLOCK_BACKEND="$CASE/block-backend"
  export TEST_RESPONSES="$CASE/responses"
  export TEST_ROOT="$ROOT"
  export TEST_AI_TIMEOUT=5
  export TEST_MAX_CALLS=40
  export TEST_BACKEND_NOTIFY=0
  : > "$TMUX_RADAR_NEEDINPUT_FILE"
  : > "$TEST_SENDS"
  : > "$TEST_MODEL_CALLS"
  : > "$TEST_CALL_COUNT"
  : > "$TEST_INTERNAL_LOG"
  : > "$TEST_MAX_ACTIVE"
  : > "$TEST_CONCURRENT"
  : > "$TEST_BACKEND_PIDS"
  : > "$TEST_WAITER_PIDS"
  printf 'screen-0\n' > "$TEST_SCREEN"
  touch "$TEST_PANE_ALIVE"
  RUN_DIR=""
}

start_watch() {
  local poll="${1:-30}" goal="${2:-supervise until done}"
  PATH="$TMP/bin:$OLD_PATH" \
    bash "$ROOT/scripts/ai.sh" _watch_loop %1 "$goal" always-allow "$poll" auto-safe \
    >"$CASE/watch.out" 2>"$CASE/watch.err" &
  WATCH_PID=$!
  wait_until 'watch pointer' "[ -s '$CASE/state/ai-watch/_1.watch' ]"
  RUN_DIR="$(awk -F= '$1 == "run_dir" { print $2; exit }' "$CASE/state/ai-watch/_1.watch")"
  [ -n "$RUN_DIR" ] || _fail_assert 'watch pointer lacks run_dir'
}

stop_watch() {
  local pid="$WATCH_PID"
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  WATCH_PID=""
}

emit_event() {
  local event_id="$1" kind="$2" label="${3:-$2}"
  PATH="$TMP/bin:$OLD_PATH" TMUX_RADAR_EVENT_ID="$event_id" \
    bash "$ROOT/scripts/ai.sh" emit-event %1 "$kind" test "$label"
}

write_response() {
  local n="$1" json="$2"
  printf '%s\n' "$json" > "$TEST_RESPONSES/$n.json"
}

write_fakes
export PATH="$TMP/bin:$OLD_PATH"

# 1. Events accumulating during a blocked model call remain serialized.
reset_case serialized
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"first"}'
write_response 2 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"second"}'
touch "$TEST_BLOCK_BACKEND"
start_watch 30
emit_event event-1 approval first
wait_until 'blocked first backend call' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 1 ]"
emit_event event-2 turn_complete second
emit_event event-3 manual_reassess third
sleep 0.1
rm -f "$TEST_BLOCK_BACKEND"
wait_until 'queued batch decision' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" -ge 2 ]"
assert_eq 1 "$(cat "$TEST_MAX_ACTIVE")" 'maximum concurrent model calls'
assert_eq '' "$(cat "$TEST_CONCURRENT")" 'no overlapping backend lock acquisition'
stop_watch
printf 'PASS: serialized watcher owns one model call\n'

# 2. event_id, not screen fingerprint, is the decision identity.
reset_case dedupe
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"once"}'
start_watch 30
emit_event stable-duplicate approval duplicate
wait_until 'first deduplicated decision' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 1 ]"
printf 'screen-changed\n' > "$TEST_SCREEN"
emit_event stable-duplicate approval duplicate
sleep 0.2
assert_eq 1 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'duplicate event decided once after screen change'
stop_watch
printf 'PASS: canonical event journal deduplicates replay\n'

# 3. User activity supersedes queued requests and never calls the model.
reset_case supersede
start_watch 30
kill -STOP "$WATCH_PID"
emit_event queued-approval approval approval
emit_event user-resumed user_resumed resumed
kill -CONT "$WATCH_PID"
wait_until 'superseded journal record' "jq -e 'select(.kind == \"superseded\" and .supersedes_kind == \"approval\")' '$RUN_DIR/events.jsonl' >/dev/null"
assert_eq 0 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'user_resumed causes no model call'
stop_watch
printf 'PASS: user resume supersedes queued approval\n'

# 4. Safe sends enter VERIFYING and suppress further decisions.
reset_case verifying
write_response 1 '{"action":"send","text":"","keys":["Enter"],"safe":true,"reason":"approve"}'
write_response 2 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"later"}'
start_watch 30
emit_event verify-send approval approve
wait_until 'VERIFYING state' "jq -e '.phase == \"VERIFYING\"' '$RUN_DIR/state.json' >/dev/null"
emit_event queued-during-verify turn_complete queued
sleep 0.2
assert_eq 1 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'no model call during verification'
assert_eq 1 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'safe action sent exactly once'
stop_watch
printf 'PASS: safe send remains VERIFYING until evidence changes\n'

# 5. Malformed/empty output retries the same event and pauses after retry 3.
reset_case retry
write_response 1 ''
write_response 2 '{bad json'
write_response 3 ''
write_response 4 '{"action":"mystery","reason":"unknown"}'
start_watch 30
emit_event retry-event approval retry
wait_until 'PAUSED_ERROR retry exhaustion' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 3' '$RUN_DIR/state.json' >/dev/null" 240
assert_eq 4 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'initial call plus three bounded retries'
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'retry exhaustion sends no keys'
wait_until 'watch exits after retry exhaustion' "! kill -0 '$WATCH_PID' 2>/dev/null"
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: malformed decisions pause after bounded retries\n'

# 6. Every custom backend is internal, preventing hook/notifier recursion.
reset_case internal
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"internal"}'
TEST_BACKEND_NOTIFY=1
export TEST_BACKEND_NOTIFY
start_watch 30
emit_event internal-event approval internal
wait_until 'internal backend decision' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 1 ]"
assert_eq 1 "$(head -n 1 "$TEST_INTERNAL_LOG")" 'TMUX_RADAR_INTERNAL reaches custom backend'
assert_eq 1 "$(jq -s '[.[] | select(.event_id == "internal-event" and .kind == "approval")] | length' "$RUN_DIR/events.jsonl")" 'notifier recursion suppressed'
stop_watch
printf 'PASS: internal backend environment suppresses recursion\n'

# 7. Idle fallback starts after verification completes, not at send time.
reset_case idle
write_response 1 '{"action":"send","text":"","keys":["Enter"],"safe":true,"reason":"send"}'
write_response 2 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"idle"}'
export TMUX_RADAR_TEST_VERIFY_TIMEOUT=4
start_watch 0.2
emit_event idle-send approval send
wait_until 'verification before idle timing' "jq -e '.phase == \"VERIFYING\"' '$RUN_DIR/state.json' >/dev/null"
sleep 0.35
assert_eq 1 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'idle timer dormant during verification'
printf 'screen-after-send\n' > "$TEST_SCREEN"
wait_until 'verification completion' "jq -e 'select(.kind == \"verification_completed\")' '$RUN_DIR/events.jsonl' >/dev/null"
sleep 0.08
assert_eq 1 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'idle interval starts after verification completion'
wait_until 'idle fallback decision' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 2 ]"
stop_watch
printf 'PASS: idle fallback starts after completed verification\n'

# 8. Active screen changes reset the idle latch instead of spending calls.
reset_case active-idle
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"stable idle"}'
start_watch 0.18
wait_until 'active idle timer armed' "[ -s '$RUN_DIR/state.json' ] && jq -e '.phase == \"ARMED\" and .timer_pid > 0' '$RUN_DIR/state.json' >/dev/null 2>&1"
sleep 0.05
printf 'screen-active-1\n' > "$TEST_SCREEN"
sleep 0.2
printf 'screen-active-2\n' > "$TEST_SCREEN"
sleep 0.12
assert_eq 0 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'screen changes suppress idle fallback decisions'
wait_until 'stable-screen idle decision' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 1 ]"
stop_watch
printf 'PASS: idle fallback requires a stable screen interval\n'

# 9. A user resume/screen change during DECIDING cancels a stale send.
reset_case stale-send
write_response 1 '{"action":"send","text":"","keys":["Enter"],"safe":true,"reason":"now stale"}'
touch "$TEST_BLOCK_BACKEND"
start_watch 30
emit_event stale-approval approval approval
wait_until 'blocked stale-send backend' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 1 ]"
printf 'user changed the pane\n' > "$TEST_SCREEN"
emit_event stale-user user_resumed resumed
rm -f "$TEST_BLOCK_BACKEND"
wait_until 'stale decision superseded' "jq -e 'select(.kind == \"superseded\" and .supersedes_event_id == \"stale-approval\")' '$RUN_DIR/events.jsonl' >/dev/null"
sleep 0.1
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'stale send is never executed'
stop_watch
printf 'PASS: post-decision user evidence cancels stale sends\n'

# 10. `done` is valid only for completion/reassessment event classes.
reset_case done-gate
write_response 1 '{"action":"done","text":"","keys":[],"safe":true,"reason":"wrong event"}'
write_response 2 '{"action":"done","text":"","keys":[],"safe":true,"reason":"still wrong"}'
write_response 3 '{"action":"done","text":"","keys":[],"safe":true,"reason":"still wrong"}'
write_response 4 '{"action":"done","text":"","keys":[],"safe":true,"reason":"still wrong"}'
start_watch 30
emit_event approval-cannot-complete approval approval
wait_until 'invalid done rejection' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 3' '$RUN_DIR/state.json' >/dev/null 2>&1" 600
wait_until 'invalid done final outcome' "[ -s '$RUN_DIR/final.json' ]"
assert_eq paused_error "$(jq -r '.outcome' "$RUN_DIR/final.json")" 'approval event cannot complete run'
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'invalid done sends no keys'
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: done is gated by completion-capable event kinds\n'

# 11. user_resumed supersedes stale prompts but retains other batch work.
reset_case retained-batch
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"retained turn"}'
start_watch 30
kill -STOP "$WATCH_PID"
emit_event stale-batch-approval approval approval
emit_event batch-user user_resumed resumed
emit_event retained-turn turn_complete turn
emit_event retained-manual manual_reassess manual
kill -CONT "$WATCH_PID"
wait_until 'retained turn_complete decision' "jq -e 'select(.kind == \"model_started\" and .event_id == \"retained-turn\")' '$RUN_DIR/events.jsonl' >/dev/null"
assert_eq 1 "$(jq -s '[.[] | select(.kind == "superseded" and .supersedes_event_id == "stale-batch-approval")] | length' "$RUN_DIR/events.jsonl")" 'only stale approval is superseded'
stop_watch
printf 'PASS: user resume retains non-stale batch events\n'

# 12. Ctrl-C/TERM tears down waiter, timer, backend group, and live pointer.
reset_case cleanup
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"blocked"}'
touch "$TEST_BLOCK_BACKEND"
start_watch 30
emit_event cleanup-event approval cleanup
wait_until 'backend metadata' "jq -e '.model.pid > 0 and .model.pgid > 0' '$RUN_DIR/state.json' >/dev/null"
backend_pid="$(jq -r '.model.pid' "$RUN_DIR/state.json")"
backend_pgid="$(jq -r '.model.pgid' "$RUN_DIR/state.json")"
waiter_pid="$(jq -r '.waiter_pid // 0' "$RUN_DIR/state.json")"
timer_pid="$(jq -r '.timer_pid // 0' "$RUN_DIR/state.json")"
stop_watch
assert_process_gone "$backend_pid" backend
assert_process_group_gone "$backend_pgid" backend-group
[ "$waiter_pid" = 0 ] || assert_process_gone "$waiter_pid" waiter
[ "$timer_pid" = 0 ] || assert_process_gone "$timer_pid" timer
while IFS= read -r waiter_child; do
  assert_process_gone "$waiter_child" waiter-child
done < "$TEST_WAITER_PIDS"
[ ! -e "$CASE/state/ai-watch/_1.watch" ] || _fail_assert 'live watch pointer survived termination'
assert_json "$RUN_DIR/final.json" '.outcome == "stopped"'
printf 'PASS: watcher cleanup leaves no owned process or live pointer\n'

printf 'PASS: serialized event-driven supervision suite\n'

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
    count=1
    [ -s "$TEST_SEND_COUNT" ] && count=$(( $(cat "$TEST_SEND_COUNT") + 1 ))
    printf '%s\n' "$count" > "$TEST_SEND_COUNT"
    [ "${TEST_SEND_FAIL_AT:-0}" = "$count" ] && exit 1
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
if [ -n "${TEST_PROMPT_FILE:-}" ]; then
  cat > "$TEST_PROMPT_FILE"
else
  cat >/dev/null
fi
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
  export TEST_SEND_COUNT="$CASE/send-count"
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
  export TEST_PROMPT_FILE="$CASE/prompt.txt"
  export TEST_ROOT="$ROOT"
  export TEST_AI_TIMEOUT=5
  export TEST_MAX_CALLS=40
  export TEST_BACKEND_NOTIFY=0
  export TEST_SEND_FAIL_AT=0
  export TMUX_RADAR_TEST_PRE_SEND_BLOCK=""
  export TMUX_RADAR_TEST_GATE_ATTEMPTS=""
  export TMUX_RADAR_TEST_COMPLETION_DELAY=0
  : > "$TMUX_RADAR_NEEDINPUT_FILE"
  : > "$TEST_SENDS"
  : > "$TEST_SEND_COUNT"
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
  wait_until 'initial state snapshot' "[ -s '$RUN_DIR/state.json' ]"
}

start_watch_config() {
  local poll="$1" stable_threshold="$2" hooks_first="$3" goal="${4:-supervise until done}" extra="${5:-}" config overrides
  overrides="poll=$poll,stable_screen_threshold=$stable_threshold,hooks_first=$hooks_first"
  [ -z "$extra" ] || overrides="$overrides,$extra"
  config="$(TMUX_RADAR_SETUP_OVERRIDES="$overrides" \
    PATH="$TMP/bin:$OLD_PATH" bash "$ROOT/scripts/ai.sh" _build-watch-config %1 "$goal")"
  PATH="$TMP/bin:$OLD_PATH" \
    bash "$ROOT/scripts/ai.sh" _watch_loop %1 '' '' '' '' "$config" \
    >"$CASE/watch.out" 2>"$CASE/watch.err" &
  WATCH_PID=$!
  wait_until 'watch pointer' "[ -s '$CASE/state/ai-watch/_1.watch' ]"
  RUN_DIR="$(awk -F= '$1 == "run_dir" { print $2; exit }' "$CASE/state/ai-watch/_1.watch")"
  [ -n "$RUN_DIR" ] || _fail_assert 'watch pointer lacks run_dir'
  wait_until 'initial configured state snapshot' "[ -s '$RUN_DIR/state.json' ]"
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

# 12. Publication after the final drain but before delivery cancels the send.
reset_case final-send-guard
write_response 1 '{"action":"send","text":"","keys":["Enter"],"safe":true,"reason":"must be cancelled"}'
export TMUX_RADAR_TEST_PRE_SEND_BLOCK="$CASE/pre-send-block"
touch "$TMUX_RADAR_TEST_PRE_SEND_BLOCK"
start_watch 30

# A failed private-owner write cannot publish a malformed canonical gate.
set +e
owner_error="$(TMUX_RADAR_TEST_GATE_OWNER_WRITE_FAIL=1 emit_event owner-write-fail manual_reassess blocked 2>&1)"
owner_rc=$?
set -e
[ "$owner_rc" -ne 0 ] || _fail_assert 'failed owner write should reject emit-event'
case "$owner_error" in *'delivery gate'*) : ;; *) _fail_assert 'owner write failure must be visible' 'output' "$owner_error" ;; esac
assert_eq 0 "$(find "$RUN_DIR" -maxdepth 1 \( -name '.delivery-gate*' -o -name '.delivery-owner.*' -o -name '.delivery-pending.*' \) | wc -l | tr -d ' ')" 'failed owner write publishes no gate artifacts'

# A fully published live gate bounds hook latency and leaves no intent behind.
printf 'pid=%s\ntoken=live-test\ncreated=%s\n' "$$" "$(date '+%s')" > "$RUN_DIR/.delivery-gate"
[ -f "$RUN_DIR/.delivery-gate" ] || _fail_assert 'canonical gate must be one atomic owner file'
set +e
gate_error="$(TMUX_RADAR_TEST_GATE_ATTEMPTS=3 emit_event gate-timeout manual_reassess blocked 2>&1)"
gate_rc=$?
set -e
[ "$gate_rc" -ne 0 ] || _fail_assert 'live delivery gate should bound emit-event'
case "$gate_error" in *'delivery gate'*) : ;; *) _fail_assert 'gate failure must be visible' 'output' "$gate_error" ;; esac
assert_eq 0 "$(find "$RUN_DIR" -maxdepth 1 -name '.delivery-pending.*' | wc -l | tr -d ' ')" 'failed publication releases intent'
rm -f "$RUN_DIR/.delivery-gate"

# A dead owner is recovered by the next publisher.
printf 'pid=99999999\ntoken=stale-test\ncreated=1\n' > "$RUN_DIR/.delivery-gate"
# A crash before canonical hard-link publication can leave only a private owner
# file; it must never block acquisition because it was never the lock.
printf 'pid=99999999\ntoken=private-orphan\ncreated=1\n' > "$RUN_DIR/.delivery-owner.private-orphan"
emit_event final-race-approval approval approval
rm -f "$RUN_DIR/.delivery-owner.private-orphan"
wait_until 'final pre-send seam' "[ -s '$TMUX_RADAR_TEST_PRE_SEND_BLOCK.ready' ]" 600

# The publisher linearizes while the watcher is blocked after its final drain.
PATH="$TMP/bin:$OLD_PATH" TMUX_RADAR_EVENT_ID=final-race-user \
  bash "$ROOT/scripts/ai.sh" emit-event %1 user_resumed test resumed \
  >"$CASE/emit.out" 2>"$CASE/emit.err" &
emit_pid=$!
wait_until 'publication intent after final drain' "find '$RUN_DIR' -maxdepth 1 -name '.delivery-pending.*' | grep -q ." 400
rm -f "$TMUX_RADAR_TEST_PRE_SEND_BLOCK"
wait "$emit_pid"
wait_until 'final guard supersedes stale decision' "jq -e 'select(.kind == \"superseded\" and .supersedes_event_id == \"final-race-approval\")' '$RUN_DIR/events.jsonl' >/dev/null"
sleep 0.1
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'final pre-send guard prevents stale delivery'
assert_eq 1 "$(jq -s '[.[] | select(.record == "incoming" and .event_id == "final-race-user")] | length' "$RUN_DIR/events.jsonl")" 'takeover event remains durable after cancellation'
assert_eq 0 "$(find "$RUN_DIR" -maxdepth 1 \( -name '.delivery-gate*' -o -name '.delivery-owner.*' -o -name '.delivery-admission*' -o -name '.delivery-pending.*' -o -name '.delivery-closed' \) | wc -l | tr -d ' ')" 'delivery gate artifacts released'
stop_watch
printf 'PASS: final pre-send guard closes stale delivery window\n'

# 13. Burst selection chooses the newest actionable event regardless of kind.
reset_case newest-burst
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"newest turn"}'
write_response 2 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"retained manual"}'
start_watch 30
kill -STOP "$WATCH_PID"
emit_event burst-old-approval approval old
emit_event burst-mid-input input_required input
emit_event burst-new-turn turn_complete turn
emit_event burst-manual manual_reassess manual
kill -CONT "$WATCH_PID"
wait_until 'burst winner model call' "jq -e 'select(.kind == \"model_started\")' '$RUN_DIR/events.jsonl' >/dev/null"
assert_eq burst-new-turn "$(jq -r 'select(.kind == "model_started") | .event_id' "$RUN_DIR/events.jsonl" | head -n 1)" 'newest actionable turn wins burst'
assert_eq 1 "$(jq -s '[.[] | select(.kind == "coalesced" and .event_id == "burst-old-approval" and .coalesced_into_event_id == "burst-new-turn")] | length' "$RUN_DIR/events.jsonl")" 'older approval explicitly coalesced'
assert_eq 1 "$(jq -s '[.[] | select(.kind == "coalesced" and .event_id == "burst-mid-input" and .coalesced_into_event_id == "burst-new-turn")] | length' "$RUN_DIR/events.jsonl")" 'older input explicitly coalesced'
assert_eq 1 "$(jq -s '[.[] | select(.kind == "requeued" and .event_id == "burst-manual" and .after_event_id == "burst-new-turn")] | length' "$RUN_DIR/events.jsonl")" 'lower-priority manual explicitly requeued'
stop_watch
printf 'PASS: burst coalescing selects newest actionable event\n'

# 14. Required decision fields retain their exact JSON types.
reset_case schema-types
write_response 1 '{"action":"send","text":"","keys":["Enter"],"reason":"missing safe"}'
write_response 2 '{"action":"send","text":"","keys":["Enter"],"safe":null,"reason":"null safe"}'
write_response 3 '{"action":"send","text":"","keys":["Enter"],"safe":"true","reason":"string safe"}'
write_response 4 '{"action":"send","text":"","keys":["Enter",1],"safe":true,"reason":"bad keys"}'
start_watch 30
emit_event schema-event approval schema
wait_until 'schema validation exhaustion' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 3' '$RUN_DIR/state.json' >/dev/null 2>&1" 600
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'malformed decision types send no keys'
assert_eq 4 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'malformed decision types retry same event'
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: decision schema types are validated locally\n'

# 15. tmux delivery failure is visible and never journaled as sent.
reset_case send-failure
write_response 1 '{"action":"send","text":"","keys":["Enter"],"safe":true,"reason":"delivery fails"}'
export TEST_SEND_FAIL_AT=1
start_watch 30
emit_event send-failure-event approval send
wait_until 'delivery failure final outcome' "[ -s '$RUN_DIR/final.json' ]"
assert_eq delivery_error "$(jq -r '.outcome' "$RUN_DIR/final.json")" 'delivery failure outcome'
assert_eq 0 "$(jq -s '[.[] | select(.kind == "sent" and .sent == true)] | length' "$RUN_DIR/events.jsonl")" 'no false sent journal'
assert_eq 1 "$(jq -s '[.[] | select(.kind == "delivery_failed")] | length' "$RUN_DIR/events.jsonl")" 'delivery failure is journaled'
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: send failure pauses without false verification\n'

# 16. Verification timeout is a visible warning, not normal completion.
reset_case verify-timeout
write_response 1 '{"action":"send","text":"","keys":["Enter"],"safe":true,"reason":"no visible effect"}'
export TMUX_RADAR_TEST_VERIFY_TIMEOUT=0.2
start_watch 30
emit_event verify-timeout-event approval send
wait_until 'verification timeout final outcome' "[ -s '$RUN_DIR/final.json' ]" 400
assert_eq verification_timeout "$(jq -r '.outcome' "$RUN_DIR/final.json")" 'verification timeout outcome'
assert_eq 1 "$(jq -s '[.[] | select(.kind == "verification_warning" and .result == "timeout")] | length' "$RUN_DIR/events.jsonl")" 'verification timeout warning journal'
assert_json "$RUN_DIR/state.json" '.phase == "PAUSED_ERROR" and (.status | contains("verification timeout"))'
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: verification timeout remains visibly paused\n'

# 17. user_resumed interrupts retry backoff before another model call.
reset_case backoff-takeover
write_response 1 '{"action":"send","text":"","keys":["Enter"],"safe":"true","reason":"invalid"}'
write_response 2 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"must not run"}'
export TMUX_RADAR_TEST_RETRY_DELAYS=1,1,1
start_watch 30
emit_event backoff-approval approval retry
wait_until 'retry waiter armed' "jq -e '.phase == \"DECIDING\" and .retry == 1 and .waiter_pid > 0' '$RUN_DIR/state.json' >/dev/null 2>&1" 400
emit_event backoff-user user_resumed resumed
wait_until 'retry cancelled by takeover' "jq -e 'select(.kind == \"retry_cancelled\" and .event_id == \"backoff-approval\")' '$RUN_DIR/events.jsonl' >/dev/null" 400
sleep 0.2
assert_eq 1 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'takeover prevents extra retry call'
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'takeover during backoff sends no keys'
stop_watch
printf 'PASS: retry backoff is interruptible by takeover\n'

# 18. Ctrl-C/TERM tears down waiter, timer, backend group, and live pointer.
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

# 19. A configured stable-screen threshold requires consecutive stable samples,
# and a screen change resets the count.
reset_case stable-threshold
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"stable threshold reached"}'
start_watch_config 0.12 2 on
sleep 0.14
printf 'screen-reset\n' > "$TEST_SCREEN"
sleep 0.16
assert_eq 0 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'screen change resets consecutive stable count'
wait_until 'thresholded screen-idle decision' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 1 ]"
assert_eq screen_idle "$(jq -r 'select(.record == "incoming") | .kind' "$RUN_DIR/events.jsonl" | tail -n 1)" 'threshold emits screen_idle event'
stop_watch
printf 'PASS: stable-screen threshold counts consecutive unchanged samples\n'

# 20. hooks_first=off journals native events without immediate model calls;
# user takeover still supersedes, while manual reassessment and idle continue.
reset_case hooks-disabled
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"manual still works"}'
write_response 2 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"idle still works"}'
start_watch_config 0.3 1 off
kill -STOP "$WATCH_PID"
emit_event hooks-stale-approval approval approval
emit_event hooks-user-resumed user_resumed resumed
kill -CONT "$WATCH_PID"
wait_until 'hooks-off takeover supersedes approval' "jq -e 'select(.kind == \"superseded\" and .supersedes_event_id == \"hooks-stale-approval\")' '$RUN_DIR/events.jsonl' >/dev/null"
assert_eq 0 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'hooks-off user resume causes no model call'
emit_event hooks-approval approval approval
emit_event hooks-input input_required input
emit_event hooks-turn turn_complete turn
wait_until 'hooks-off native events deferred' "[ \"\$(jq -s '[.[] | select(.kind == \"hook_deferred\")] | length' '$RUN_DIR/events.jsonl')\" = 3 ]"
assert_eq 0 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'hooks-off native events cause no immediate model call'
emit_event hooks-manual manual_reassess manual
wait_until 'hooks-off manual reassessment' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 1 ]"
wait_until 'hooks-off idle fallback' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 2 ]" 240
stop_watch
printf 'PASS: hooks-first off defers native events but keeps fallback triggers\n'

# 21. A terminal newline in the goal survives config, runtime state, and the
# exact model prompt boundary.
reset_case exact-goal
goal=$'  exact\ngoal  \n'
printf '%s' "$goal" > "$CASE/expected-goal"
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"goal preserved"}'
start_watch_config 30 1 on "$goal"
jq -j '.goal' "$RUN_DIR/config.json" > "$CASE/config-goal"
cmp -s "$CASE/expected-goal" "$CASE/config-goal" || _fail_assert 'config goal bytes changed'
jq -j '.goal' "$RUN_DIR/state.json" > "$CASE/state-goal"
cmp -s "$CASE/expected-goal" "$CASE/state-goal" || _fail_assert 'state goal bytes changed' \
  'expected_hex' "$(od -An -tx1 "$CASE/expected-goal" | tr -d ' \n')" \
  'actual_hex' "$(od -An -tx1 "$CASE/state-goal" | tr -d ' \n')"
emit_event exact-goal-manual manual_reassess manual
wait_until 'exact goal prompt' "[ -s '$TEST_PROMPT_FILE' ]"
prompt="$(cat "$TEST_PROMPT_FILE")"
expected_prompt=$'GOAL (set by the user for this watch):   exact\ngoal  \nSteer the pane toward completing this goal.'
case "$prompt" in
  *"$expected_prompt"*) : ;;
  *) _fail_assert 'prompt goal bytes changed' 'expected fragment' "$expected_prompt" 'prompt' "$prompt" ;;
esac
stop_watch
printf 'PASS: exact goal bytes reach config, state, and prompt\n'

# 22. Decision logging keeps one structured decision, metadata, and backend
# stderr per call without persisting the sensitive screen or prompt by default.
reset_case decision-logging
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"tests are still running","pane_state":"working","goal_status":"working","risk":"low","evidence":["test command remains active"]}'
start_watch_config 30 1 on 'monitor until tests pass' 'logging=decision,screen_snapshots=off'
emit_event decision-log manual_reassess inspect
wait_until 'structured decision log' "[ -s '$RUN_DIR/decisions/0001.json' ] && [ -s '$RUN_DIR/decisions/0001.meta.json' ] && [ -e '$RUN_DIR/backend/0001.stderr' ]"
assert_json "$RUN_DIR/decisions/0001.json" '.action == "wait" and .pane_state == "working" and .goal_status == "working" and .risk == "low" and .evidence == ["test command remains active"]'
assert_json "$RUN_DIR/decisions/0001.meta.json" '.call == 1 and .event_id == "decision-log" and .schema_valid == true and .backend_rc == 0 and .elapsed_seconds >= 0 and .timeout_seconds > 0'
assert_eq 600 "$(stat -f '%Lp' "$RUN_DIR/decisions/0001.json")" 'decision log mode'
assert_eq 600 "$(stat -f '%Lp' "$RUN_DIR/decisions/0001.meta.json")" 'decision metadata mode'
assert_eq 600 "$(stat -f '%Lp' "$RUN_DIR/backend/0001.stderr")" 'backend stderr mode'
[ ! -e "$RUN_DIR/screens" ] || _fail_assert 'decision logging must omit screens'
[ ! -e "$RUN_DIR/prompts" ] || _fail_assert 'decision logging must omit prompts'
stop_watch
printf 'PASS: decision logging is structured and privacy-bounded\n'

# 23. Full logging explicitly persists the exact pane capture and model prompt.
reset_case full-logging
printf 'screen-full-log-marker\n' > "$TEST_SCREEN"
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"continue","evidence":["screen-full-log-marker"]}'
start_watch_config 30 1 on 'full audit goal' 'logging=full,screen_snapshots=off'
emit_event full-log manual_reassess inspect
wait_until 'full screen and prompt logs' "[ -s '$RUN_DIR/screens/0001.txt' ] && [ -s '$RUN_DIR/prompts/0001.txt' ]"
assert_contains "$(cat "$RUN_DIR/screens/0001.txt")" 'screen-full-log-marker' 'full screen log content'
assert_contains "$(cat "$RUN_DIR/prompts/0001.txt")" 'GOAL (set by the user for this watch): full audit goal' 'full prompt goal content'
assert_contains "$(cat "$RUN_DIR/prompts/0001.txt")" 'screen-full-log-marker' 'full prompt pane content'
assert_eq 600 "$(stat -f '%Lp' "$RUN_DIR/screens/0001.txt")" 'screen log mode'
assert_eq 600 "$(stat -f '%Lp' "$RUN_DIR/prompts/0001.txt")" 'prompt log mode'
stop_watch
printf 'PASS: full logging persists explicit private evidence\n'

# 24. Completion remains inspectable for the configured hold, reports its
# summary, and auto-closes only after the deadline.
reset_case completion-hold
export TMUX_RADAR_TEST_COMPLETION_DELAY=3
write_response 1 '{"action":"done","text":"","keys":[],"safe":true,"reason":"goal reached","pane_state":"done","goal_status":"done","risk":"low","evidence":["all tests passed"]}'
start_watch_config 30 1 on 'finish all tests' 'completion_close_delay=3'
completion_run_id="$(basename "$RUN_DIR")"
emit_event completion-turn turn_complete complete
wait_until 'completion final report' "[ -s '$RUN_DIR/final.json' ]" 400
assert_file "$CASE/state/ai-watch/_1.watch"
assert_json "$RUN_DIR/state.json" '.phase == "COMPLETED" and .next.kind == "auto_close" and .next.at > 0'
assert_json "$RUN_DIR/final.json" '.outcome == "completed" and .reason == "goal reached" and .goal == "finish all tests" and .goal_status == "done" and .decision_count == 1 and .event_count > 0 and .duration_seconds >= 0 and .log_path == "'"$RUN_DIR"'"'
report="$(PATH="$TMP/bin:$OLD_PATH" bash "$ROOT/scripts/ai.sh" report "$completion_run_id")"
assert_contains "$report" 'Outcome:   completed' 'report outcome'
assert_contains "$report" 'Counts:    events=' 'report counts'
assert_contains "$report" "Logs:      $RUN_DIR" 'report log path'
wait_until 'completion auto-close' "[ ! -e '$CASE/state/ai-watch/_1.watch' ]" 400
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: completion hold exposes final report before auto-close\n'

# 25. Keeping a completed run cancels auto-close until the user stops it.
reset_case completion-keep
export TMUX_RADAR_TEST_COMPLETION_DELAY=3
write_response 1 '{"action":"done","text":"","keys":[],"safe":true,"reason":"kept result","goal_status":"done","evidence":["goal complete"]}'
start_watch_config 30 1 on 'keep completion open' 'completion_close_delay=3'
emit_event completion-keep-turn turn_complete complete
wait_until 'keepable completion' "[ -s '$RUN_DIR/final.json' ]" 400
PATH="$TMP/bin:$OLD_PATH" bash "$ROOT/scripts/ai.sh" keep %1 >/dev/null
wait_until 'completion keep marker' "[ -e '$RUN_DIR/keep-open' ]"
sleep 3.2
assert_file "$CASE/state/ai-watch/_1.watch"
assert_json "$RUN_DIR/state.json" '.phase == "COMPLETED" and .next.kind == "manual_close" and .next.at == 0'
stop_watch
printf 'PASS: completion keep requires explicit close\n'

printf 'PASS: serialized event-driven supervision suite\n'

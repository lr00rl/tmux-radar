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
  trap - EXIT TERM INT HUP
  [ -z "${TEST_WAITER_LIVENESS:-}" ] || rm -f "$TEST_WAITER_LIVENESS"
  [ -z "${TEST_PROCESS_LIVENESS:-}" ] || rm -f "$TEST_PROCESS_LIVENESS"
  stop_watch || rc=1
  stop_recorded_waiters || rc=1
  PATH="$OLD_PATH"
  if [ "$rc" -eq 0 ] && recorded_waiters_gone; then
    rm -rf "$TMP"
  else
    if ! recorded_waiters_gone; then
      printf 'FAIL: test cleanup retained live supervision waiters\n' >&2
      rc=1
    fi
    printf 'INFO: failed supervision artifacts kept at %s\n' "$TMP" >&2
  fi
  exit "$rc"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

process_tree_pids() {
  local root="$1"
  ps -axo pid=,ppid= 2>/dev/null | awk -v root="$root" '
    { n++; pid[n]=$1; ppid[n]=$2 }
    END {
      keep[root]=1
      for (pass=1; pass<=n; pass++)
        for (i=1; i<=n; i++)
          if (keep[ppid[i]]) keep[pid[i]]=1
      for (i=n; i>=1; i--)
        if (pid[i] != root && keep[pid[i]]) print pid[i]
      print root
    }'
}

stop_process_tree() {
  local root="$1" tree pid alive attempt=0
  case "$root" in ''|0|*[!0-9]*) return 0 ;; esac
  tree="$(process_tree_pids "$root" || true)"
  [ -n "$tree" ] || tree="$root"
  for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
  while [ "$attempt" -lt 80 ]; do
    alive=0
    for pid in $tree; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" -eq 1 ] || break
    sleep 0.05
    attempt=$((attempt + 1))
  done
  for pid in $tree; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
  wait "$root" 2>/dev/null || true
}

waiter_pid_belongs_to_test() {
  local pid="$1" command
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  case "$command" in *"$TMP/bin/tmux"*) return 0 ;; *) return 1 ;; esac
}

stop_recorded_waiters() {
  local file pid
  for file in "$TMP"/*/waiter.pids; do
    [ -r "$file" ] || continue
    while IFS= read -r pid; do
      case "$pid" in ''|0|*[!0-9]*) continue ;; esac
      if kill -0 "$pid" 2>/dev/null && waiter_pid_belongs_to_test "$pid"; then
        stop_process_tree "$pid"
      fi
    done < "$file"
  done
}

recorded_waiters_gone() {
  local file pid
  for file in "$TMP"/*/waiter.pids; do
    [ -r "$file" ] || continue
    while IFS= read -r pid; do
      case "$pid" in ''|0|*[!0-9]*) continue ;; esac
      if kill -0 "$pid" 2>/dev/null && waiter_pid_belongs_to_test "$pid"; then
        return 1
      fi
    done < "$file"
  done
  return 0
}

wait_until() {
  local description="$1" command="$2" attempts="${3:-400}" i=0
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
  cp "$ROOT/tests/fixtures/fake-tmux-supervision" "$TMP/bin/tmux"
  chmod +x "$TMP/bin/tmux"
  printf '%s\n' 'tmux() { "$TEST_FAKE_TMUX" "$@"; }' > "$TMP/bashenv"

  cat > "$TMP/bin/fake-backend" <<'BACKENDEOF'
#!/usr/bin/env bash
set -eu
backend_owner_pid="$PPID"
backend_liveness="${TEST_PROCESS_LIVENESS:-}"
backend_max_seconds="${TEST_PROCESS_MAX_SECONDS:-300}"
case "$backend_max_seconds" in ''|*[!0-9]*) backend_max_seconds=300 ;; esac
backend_deadline=$((SECONDS + backend_max_seconds))
backend_wait_fifo="$TEST_SIGNALS/.backend-wait.$$"
mkfifo "$backend_wait_fifo"
exec 8<>"$backend_wait_fifo"
rm -f "$backend_wait_fifo"
backend_wait() { IFS= read -r -t 1 _ <&8 || true; }
backend_live() {
  [ -z "$backend_liveness" ] || [ -e "$backend_liveness" ] || return 1
  kill -0 "$backend_owner_pid" 2>/dev/null || return 1
  [ "$SECONDS" -lt "$backend_deadline" ]
}
backend_cleanup() {
  rc="$?"
  trap - EXIT TERM INT HUP
  rm -rf "$TEST_ACTIVE_LOCK"
  exit "$rc"
}
trap 'backend_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
if [ -n "${TEST_PROMPT_FILE:-}" ]; then
  cat > "$TEST_PROMPT_FILE"
else
  cat >/dev/null
fi
printf '%s\n' "${TMUX_RADAR_INTERNAL:-}" >> "$TEST_INTERNAL_LOG"
mkdir "$TEST_ACTIVE_LOCK" 2>/dev/null || {
  printf 'concurrent\n' >> "$TEST_CONCURRENT"
  while ! mkdir "$TEST_ACTIVE_LOCK" 2>/dev/null; do
    backend_live || exit 0
    backend_wait
  done
}
active=1
[ -s "$TEST_MAX_ACTIVE" ] && active="$(cat "$TEST_MAX_ACTIVE")"
[ "$active" -ge 1 ] || active=1
printf '%s\n' "$active" > "$TEST_MAX_ACTIVE"
call=1
[ -s "$TEST_CALL_COUNT" ] && call=$(( $(cat "$TEST_CALL_COUNT") + 1 ))
printf '%s\n' "$call" > "$TEST_CALL_COUNT"
printf '%s\n' "$call" >> "$TEST_MODEL_CALLS"
pgid="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || true)"
[ -n "$pgid" ] || pgid="$$"
printf '%s %s\n' "$$" "$pgid" >> "$TEST_BACKEND_PIDS"
if [ "${TEST_BACKEND_NOTIFY:-0}" = 1 ]; then
  TMUX_PANE=%1 bash "$TEST_ROOT/scripts/needinput-notify.sh" codex-hook <<<'{"hook_event_name":"PermissionRequest"}'
fi
while [ -e "$TEST_BLOCK_BACKEND" ]; do
  backend_live || exit 0
  backend_wait
done
backend_stderr="${TEST_BACKEND_STDERR:-}"
[ -f "$TEST_RESPONSES/$call.stderr" ] && backend_stderr="$(cat "$TEST_RESPONSES/$call.stderr")"
if [ -n "$backend_stderr" ]; then
  printf '%s\n' "$backend_stderr" >&2
fi
backend_rc="${TEST_BACKEND_RC:-0}"
[ -f "$TEST_RESPONSES/$call.rc" ] && backend_rc="$(cat "$TEST_RESPONSES/$call.rc")"
if [ "$backend_rc" -ne 0 ]; then
  exit "$backend_rc"
fi
response="$TEST_RESPONSES/$call.json"
if [ -f "$response" ]; then cat "$response"; fi
BACKENDEOF
  chmod +x "$TMP/bin/fake-backend"

  cat > "$TMP/bin/fake-notify" <<'NOTIFYEOF'
#!/usr/bin/env bash
exit "${TEST_NOTIFY_RC:-0}"
NOTIFYEOF
  chmod +x "$TMP/bin/fake-notify"

  cat > "$TMP/bin/frozen-codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'codex-cli 0.144.4'
  exit 0
fi
printf '%s\n' "$*" >> "$TEST_CODEX_EXEC_LOG"
exit 1
CODEXEOF
  chmod +x "$TMP/bin/frozen-codex"
}

reset_case() {
  local name="$1"
  if [ -n "$WATCH_PID" ]; then
    stop_watch
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
  export TEST_WAITER_LIVENESS="$CASE/waiter.live"
  export TEST_WAITER_MAX_SECONDS=300
  export TEST_PROCESS_LIVENESS="$CASE/process.live"
  export TEST_PROCESS_MAX_SECONDS=300
  export TEST_BLOCK_BACKEND="$CASE/block-backend"
  export TEST_RESPONSES="$CASE/responses"
  export TEST_PROMPT_FILE="$CASE/prompt.txt"
  export TEST_ROOT="$ROOT"
  export TEST_AI_TIMEOUT=5
  export TEST_MAX_CALLS=40
  export TEST_BACKEND_NOTIFY=0
  export TEST_BACKEND_RC=0
  export TEST_BACKEND_STDERR=""
  export TEST_NOTIFY_RC=0
  export TMUX_RADAR_NOTIFY_CMD="$TMP/bin/fake-notify"
  export TMUX_RADAR_AI_LOG="$CASE/audit.log"
  export TEST_CODEX_PATH=""
  export TEST_CODEX_EXEC_LOG="$CASE/codex-exec.log"
  export TMUX_RADAR_TEST_BEFORE_DECIDE_BLOCK="$CASE/before-decide"
  export TMUX_RADAR_TEST_BEFORE_BRAIN_BLOCK=""
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
  : > "$TEST_CODEX_EXEC_LOG"
  printf 'screen-0\n' > "$TEST_SCREEN"
  touch "$TEST_PANE_ALIVE"
  touch "$TEST_WAITER_LIVENESS"
  touch "$TEST_PROCESS_LIVENESS"
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
  [ -z "${TEST_WAITER_LIVENESS:-}" ] || rm -f "$TEST_WAITER_LIVENESS"
  [ -z "${TEST_PROCESS_LIVENESS:-}" ] || rm -f "$TEST_PROCESS_LIVENESS"
  if [ -n "$pid" ]; then
    stop_process_tree "$pid"
  fi
  WATCH_PID=""
  stop_recorded_waiters
  recorded_waiters_gone
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

# 5. Malformed output receives one explicit repair attempt, then pauses.
reset_case retry
write_response 1 ''
write_response 2 '{bad json'
start_watch 30
emit_event retry-event approval retry
wait_until 'PAUSED_ERROR after repair attempt' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 1' '$RUN_DIR/state.json' >/dev/null" 600
assert_eq 2 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'initial call plus one repair attempt'
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'retry exhaustion sends no keys'
if ! jq -e 'select(.kind == "decision_repair" and .repair_attempt == 1)' \
  "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'invalid output repair attempt is not explicit' 'events' "$(cat "$RUN_DIR/events.jsonl")"
fi
wait_until 'watch exits after retry exhaustion' "! kill -0 '$WATCH_PID' 2>/dev/null" 400
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: malformed decisions receive one bounded repair attempt\n'

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
start_watch 30
emit_event approval-cannot-complete approval approval
wait_until 'invalid done rejection' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 1' '$RUN_DIR/state.json' >/dev/null 2>&1" 600
wait_until 'invalid done final outcome' "[ -s '$RUN_DIR/final.json' ]"
assert_eq paused_error "$(jq -r '.outcome' "$RUN_DIR/final.json")" 'approval event cannot complete run'
assert_eq 2 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'invalid done receives one repair attempt'
if ! jq -e 'select(.kind == "decision_invalid" and .error_class == "decision-invalid")' \
  "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'event-invalid done is not classified as a decision error' \
    'events' "$(cat "$RUN_DIR/events.jsonl")"
fi
assert_contains "$(cat "$TEST_PROMPT_FILE")" 'done is invalid for event kind: approval' \
  'semantic repair prompt names the violated event constraint'
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
start_watch 30
emit_event schema-event approval schema
wait_until 'schema validation exhaustion' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 1' '$RUN_DIR/state.json' >/dev/null 2>&1" 600
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'malformed decision types send no keys'
assert_eq 2 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'malformed decision types receive one repair attempt'
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
export TEST_BACKEND_RC=1
export TEST_BACKEND_STDERR='temporary connection reset by peer'
# Keep the timer far beyond any loaded-CI scheduling jitter. The user-resumed
# event must wake the waiter immediately, so this does not lengthen the case.
export TMUX_RADAR_TEST_RETRY_DELAYS=30,30,30
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
assert_json "$RUN_DIR/decisions/0001.meta.json" '.schema_version == 1 and .call == 1 and .event_id == "decision-log" and .schema_valid == true and .backend_rc == 0 and .elapsed_seconds >= 0 and .timeout_seconds > 0'
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

# 26. Transport retries and output repair have independent budgets.
reset_case mixed-recovery
printf '%s\n' 'temporary connection reset by peer' > "$TEST_RESPONSES/1.stderr"
printf '%s\n' 1 > "$TEST_RESPONSES/1.rc"
write_response 2 '{bad json'
write_response 3 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"recovered after repair"}'
start_watch 30
emit_event mixed-recovery-event manual_reassess inspect
wait_until 'mixed transient and repair recovery' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 3 ] && jq -e '.phase == \"ARMED\"' '$RUN_DIR/state.json' >/dev/null 2>&1" 600
assert_eq 1 "$(jq -s '[.[] | select(.kind == "decision_repair")] | length' "$RUN_DIR/events.jsonl")" \
  'mixed recovery uses exactly one repair attempt'
assert_eq 1 "$(jq -s '[.[] | select(.kind == "backend_error" and .error.class == "transient")] | length' "$RUN_DIR/events.jsonl")" \
  'mixed recovery preserves one transient failure'
stop_watch
printf 'PASS: transient retries and output repair use independent budgets\n'

# 27. A transport failure during the one logical repair keeps the repair prompt
# and uses the independent transient retry budget.
reset_case repair-transport-recovery
write_response 1 '{bad json'
printf '%s\n' 'temporary connection reset by peer' > "$TEST_RESPONSES/2.stderr"
printf '%s\n' 1 > "$TEST_RESPONSES/2.rc"
write_response 3 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"repair recovered after transport"}'
start_watch 30
emit_event repair-transport-event manual_reassess inspect
wait_until 'repair transport recovery' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 3 ] && jq -e '.phase == \"ARMED\"' '$RUN_DIR/state.json' >/dev/null 2>&1" 600
assert_eq 1 "$(jq -s '[.[] | select(.kind == "decision_repair")] | length' "$RUN_DIR/events.jsonl")" \
  'repair transport recovery keeps one logical repair attempt'
assert_eq 1 "$(jq -s '[.[] | select(.kind == "backend_error" and .error.class == "transient")] | length' "$RUN_DIR/events.jsonl")" \
  'repair transport recovery records the transient failure'
assert_contains "$(cat "$TEST_PROMPT_FILE")" 'previous decision was invalid' \
  'transport retry preserves repair context'
stop_watch
printf 'PASS: repair transport failure uses the transient retry budget\n'

# 28. Repeated transport failures during repair remain bounded.
reset_case repair-transport-exhausted
write_response 1 '{bad json'
for call in 2 3 4; do
  printf '%s\n' 'temporary connection reset by peer' > "$TEST_RESPONSES/$call.stderr"
  printf '%s\n' 1 > "$TEST_RESPONSES/$call.rc"
done
start_watch_config 30 1 on 'bound repair transport retries' 'retry_limit=2'
emit_event repair-transport-exhausted-event manual_reassess inspect
wait_until 'repair transport retry exhaustion' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 2' '$RUN_DIR/state.json' >/dev/null 2>&1" 700
assert_eq 4 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" \
  'initial invalid output plus three bounded repair transport calls'
assert_eq 1 "$(jq -s '[.[] | select(.kind == "decision_repair")] | length' "$RUN_DIR/events.jsonl")" \
  'transport exhaustion does not spend a second repair attempt'
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: repair transport retries remain bounded\n'

# 29. A transient transport failure retains bounded retry/backoff behavior.
reset_case transient-backend
export TEST_BACKEND_RC=1
export TEST_BACKEND_STDERR='connection reset by peer'
start_watch_config 30 1 on 'retry recoverable transport errors' 'retry_limit=3'
emit_event transient-backend-event manual_reassess inspect
wait_until 'transient backend retry exhaustion' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 3' '$RUN_DIR/state.json' >/dev/null 2>&1" 600
assert_eq 4 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'transient backend uses bounded retry budget'
transient_error_event_id="$(jq -r 'select(.kind == "backend_error") | .event_id' "$RUN_DIR/events.jsonl" | tail -n 1)"
assert_eq "$transient_error_event_id" "$(jq -r '.latest_error_event_id' "$RUN_DIR/state.json")" \
  'paused transient state links to its latest backend error event'
if ! jq -e 'select(
  .record == "error" and .kind == "backend_error" and
  .error.class == "transient" and .error.retryable == true and .error.call == 1
)' "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'transient backend error lacks retryable classification' \
    'events' "$(cat "$RUN_DIR/events.jsonl")"
fi
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: transient backend failures retain bounded retries\n'

# 30. A selected Codex that cannot run the configured model is a permanent
# configuration failure. It must spend one attempt, preserve the exact stderr
# evidence path, and never schedule a retry that cannot heal the configuration.
reset_case permanent-backend
export TEST_BACKEND_RC=1
export TEST_BACKEND_STDERR="The 'gpt-5.6-luna' model requires a newer version of Codex."
start_watch_config 30 1 on 'finish without wasting model calls' 'retry_limit=3'
emit_event permanent-backend-event manual_reassess inspect
wait_until 'permanent backend pause' "jq -e '.phase == \"PAUSED_ERROR\"' '$RUN_DIR/state.json' >/dev/null 2>&1" 1200
assert_eq 1 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'permanent backend launches once'
assert_json "$RUN_DIR/state.json" '.phase == "PAUSED_ERROR" and .retry == 0'
permanent_error_event_id="$(jq -r 'select(.kind == "backend_error") | .event_id' "$RUN_DIR/events.jsonl" | tail -n 1)"
assert_eq "$permanent_error_event_id" "$(jq -r '.latest_error_event_id' "$RUN_DIR/state.json")" \
  'paused permanent state links to its backend error event'
assert_eq "$TEST_BACKEND_STDERR" "$(cat "$RUN_DIR/backend/0001.stderr")" \
  'permanent backend keeps exact stderr'
if ! jq -e --arg path "$RUN_DIR/backend/0001.stderr" '
  select(
    .record == "error" and
    .kind == "backend_error" and
    .error.class == "config-permanent" and
    .error.retryable == false and
    .error.stderr_path == $path and
    .error.call == 1 and
    (.error.code | length) > 0 and
    (.error.timestamp | length) > 0
  )
' "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'permanent backend error lacks structured evidence' \
    'events' "$(cat "$RUN_DIR/events.jsonl")"
fi
if jq -e 'select(.kind == "backend_error") | .error.detail | contains("requires a newer version")' \
  "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'backend event duplicated private stderr instead of referencing its evidence path'
fi
if jq -e 'select(.kind == "backend_error" and has("error_class"))' "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'backend event used legacy flat error fields instead of the canonical error object'
fi
wait_until 'permanent watcher exits' "! kill -0 '$WATCH_PID' 2>/dev/null" 400
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: permanent backend incompatibility spends no retry budget\n'

# 31. Authoritative launch failure status outranks transient-looking stderr.
reset_case launch-permanent
export TEST_BACKEND_RC=127
export TEST_BACKEND_STDERR='connection timeout while launching missing executable'
start_watch 30
emit_event launch-permanent-event manual_reassess inspect
wait_until 'launch failure permanent pause' "jq -e '.phase == \"PAUSED_ERROR\" and .retry == 0' '$RUN_DIR/state.json' >/dev/null 2>&1" 400
assert_eq 1 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'launch failure does not retry transient-looking text'
if ! jq -e 'select(.kind == "backend_error" and .error.class == "config-permanent" and .error.retryable == false)' \
  "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'launch exit status did not outrank stderr wording' 'events' "$(cat "$RUN_DIR/events.jsonl")"
fi
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: launch exit status outranks fuzzy stderr classification\n'

# 32. Ordered classifier rules keep permanent evidence ahead of transport words
# and leave unknown nonzero failures retryable.
reset_case classifier-matrix
assert_json "$ROOT/scripts/prompts/decide.schema.json" '
  (.required | sort) == (.properties | keys | sort)
'
classifier_stderr="$CASE/classifier.stderr"
printf '%s\n' 'connection timeout followed by unsupported model' > "$classifier_stderr"
PATH="$TMP/bin:$OLD_PATH" bash "$ROOT/scripts/ai.sh" _classify-backend-failure 1 "$classifier_stderr" 0 > "$CASE/mixed.json"
assert_json "$CASE/mixed.json" '.class == "config-permanent" and .retryable == false'
printf '%s\n' "invalid_request_error: invalid_json_schema: required is missing 'pane_state' (status 400)" \
  > "$classifier_stderr"
PATH="$TMP/bin:$OLD_PATH" bash "$ROOT/scripts/ai.sh" _classify-backend-failure 1 "$classifier_stderr" 0 \
  > "$CASE/schema.json"
assert_json "$CASE/schema.json" '
  .class == "config-permanent" and
  .code == "decision-schema-invalid" and
  .retryable == false
'
printf '%s\n' 'profile not found' > "$classifier_stderr"
PATH="$TMP/bin:$OLD_PATH" bash "$ROOT/scripts/ai.sh" _classify-backend-failure 1 "$classifier_stderr" 0 > "$CASE/profile.json"
assert_json "$CASE/profile.json" '.class == "config-permanent"'
printf '%s\n' 'authentication failed: unauthorized' > "$classifier_stderr"
PATH="$TMP/bin:$OLD_PATH" bash "$ROOT/scripts/ai.sh" _classify-backend-failure 1 "$classifier_stderr" 0 > "$CASE/auth.json"
assert_json "$CASE/auth.json" '.class == "config-permanent"'
printf '%s\n' 'unrecognized backend failure' > "$classifier_stderr"
PATH="$TMP/bin:$OLD_PATH" bash "$ROOT/scripts/ai.sh" _classify-backend-failure 1 "$classifier_stderr" 0 > "$CASE/unknown.json"
assert_json "$CASE/unknown.json" '.class == "transient" and .retryable == true and .code == "backend-failed"'
printf 'PASS: classifier ordering covers permanent, mixed, and unknown failures\n'

# 33. Pane loss before cmd_decide starts a model is a lifecycle stop. It does
# not reuse the previous decision, spend budget, or schedule output repair.
reset_case pre-decision-pane-loss
write_response 1 '{"action":"wait","text":"","keys":[],"safe":true,"reason":"first decision"}'
start_watch 30
emit_event pane-loss-first manual_reassess first
wait_until 'first decision before pane loss' "[ \"\$(wc -l < '$TEST_MODEL_CALLS' | tr -d ' ')\" = 1 ] && jq -e '.phase == \"ARMED\"' '$RUN_DIR/state.json' >/dev/null 2>&1"
rm -f "${TMUX_RADAR_TEST_BEFORE_DECIDE_BLOCK}.ready"
touch "$TMUX_RADAR_TEST_BEFORE_DECIDE_BLOCK"
emit_event pane-loss-second manual_reassess second
wait_until 'pre-decision block armed' "[ -e '${TMUX_RADAR_TEST_BEFORE_DECIDE_BLOCK}.ready' ]"
rm -f "$TEST_PANE_ALIVE" "$TMUX_RADAR_TEST_BEFORE_DECIDE_BLOCK"
wait_until 'pane loss lifecycle final' "[ -s '$RUN_DIR/final.json' ]" 400
assert_json "$RUN_DIR/final.json" '.outcome == "stopped" and (.reason | contains("target pane disappeared"))'
assert_json "$RUN_DIR/state.json" '.phase == "STOPPED" and .calls == 1'
assert_eq 1 "$(wc -l < "$TEST_MODEL_CALLS" | tr -d ' ')" 'pane loss starts no second backend'
assert_eq 0 "$(jq -s '[.[] | select(.kind == "decision_repair")] | length' "$RUN_DIR/events.jsonl")" \
  'pane loss schedules no model-output repair'
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: pre-decision pane loss is a zero-call lifecycle stop\n'

# 34. Codex identity drift after freeze is a permanent zero-launch failure with
# exact protected evidence rather than a dangling stderr reference.
reset_case backend-identity-drift
unset TMUX_RADAR_AI_CMD
cp "$TMP/bin/frozen-codex" "$CASE/frozen-codex"
chmod +x "$CASE/frozen-codex"
export TEST_CODEX_PATH="$CASE/frozen-codex"
export TMUX_RADAR_TEST_BEFORE_BRAIN_BLOCK="$CASE/before-brain"
touch "$TMUX_RADAR_TEST_BEFORE_BRAIN_BLOCK"
start_watch 30
emit_event identity-drift-event manual_reassess inspect
wait_until 'identity drift block armed' "[ -e '${TMUX_RADAR_TEST_BEFORE_BRAIN_BLOCK}.ready' ]"
printf '%s\n' '# identity drift' >> "$TEST_CODEX_PATH"
rm -f "$TMUX_RADAR_TEST_BEFORE_BRAIN_BLOCK"
wait_until 'identity drift permanent pause' "jq -e '.phase == \"PAUSED_ERROR\" and .calls == 0 and .retry == 0' '$RUN_DIR/state.json' >/dev/null 2>&1" 500
assert_eq 0 "$(wc -l < "$TEST_CODEX_EXEC_LOG" | tr -d ' ')" 'identity drift launches no Codex exec'
identity_stderr="$(jq -r 'select(.kind == "backend_error") | .error.stderr_path' "$RUN_DIR/events.jsonl")"
assert_file "$identity_stderr"
assert_eq 'selected Codex executable changed after preflight' "$(cat "$identity_stderr")" \
  'identity drift keeps exact evidence'
assert_eq 600 "$(stat -f '%Lp' "$identity_stderr")" 'identity drift evidence mode'
if ! jq -e 'select(.kind == "backend_error" and .error.code == "backend-identity-changed" and
  (.error.summary | contains("changed after preflight")) and .error.call == 0)' \
  "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'identity drift lacks exact canonical evidence' 'events' "$(cat "$RUN_DIR/events.jsonl")"
fi
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: backend identity drift fails before launch with exact evidence\n'

# 35. Unsafe or non-auto delivery is a policy halt, not a backend failure.
reset_case policy-halt
export TEST_NOTIFY_RC=1
write_response 1 '{"action":"send","text":"2","keys":["Enter"],"safe":false,"reason":"requires human approval"}'
start_watch 30
emit_event policy-halt-event approval inspect
wait_until 'policy halt final outcome' "[ -s '$RUN_DIR/final.json' ]" 400
assert_json "$RUN_DIR/state.json" '.phase == "PAUSED_POLICY" and .retry == 0'
assert_json "$RUN_DIR/final.json" '.outcome == "policy_halt"'
if ! jq -e 'select(.kind == "policy_halt" and .record == "policy_halt")' \
  "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'policy halt lacks canonical event' 'events' "$(cat "$RUN_DIR/events.jsonl")"
fi
assert_eq policy-halt "$(jq -r 'select(.kind == "policy_halt") | .outcome_class' "$RUN_DIR/events.jsonl")" \
  'policy halt uses the stable outcome classifier'
assert_eq 0 "$(jq -s '[.[] | select(.kind == "backend_error")] | length' "$RUN_DIR/events.jsonl")" \
  'policy halt is not a backend error'
assert_eq 0 "$(wc -l < "$TEST_SENDS" | tr -d ' ')" 'policy halt sends no keys'
if ! jq -e 'select(.kind == "notification_failed" and .record == "notification_error")' \
  "$RUN_DIR/events.jsonl" >/dev/null 2>&1; then
  _fail_assert 'notifier failure lacks durable journal evidence' 'events' "$(cat "$RUN_DIR/events.jsonl")"
fi
assert_contains "$(cat "$TMUX_RADAR_AI_LOG")" 'notification-failed' 'notifier failure reaches audit log'
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
printf 'PASS: policy refusal remains distinct from backend failure\n'

printf 'PASS: serialized event-driven supervision suite\n'

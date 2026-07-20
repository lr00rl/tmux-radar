#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted lines intentionally generate fake scripts
set -euo pipefail
export TMUX_RADAR_TEST_ALLOW_SUBSECOND_POLL=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tmux-radar-lifecycle.XXXXXX")"
WATCH_PID=""
MONITOR_PID=""
LEGACY_PID=""
LEGACY_CHILD_PID=""
RUN_DIR=""

process_alive() {
  kill -0 "$1" 2>/dev/null
}

process_effectively_alive() {
  local state
  process_alive "$1" || return 1
  state="$(ps -p "$1" -o state= 2>/dev/null | awk '{$1=$1; print; exit}')"
  case "$state" in Z*|z*) return 1 ;; esac
  return 0
}

wait_for_file() {
  local file="$1"
  for _ in {1..600}; do
    [ -s "$file" ] && return 0
    sleep 0.05
  done
  return 1
}

wait_for_exit() {
  local pid="$1"
  for _ in {1..600}; do
    process_alive "$pid" || return 0
    sleep 0.05
  done
  return 1
}

wait_for_effective_exit() {
  local pid="$1"
  for _ in {1..600}; do
    process_effectively_alive "$pid" || return 0
    sleep 0.05
  done
  return 1
}

current_run_dir() {
  local watch_file="$TMP/state/ai-watch/_1.watch"
  [ -r "$watch_file" ] || return 1
  awk -F= '$1 == "run_dir" { print $2; exit }' "$watch_file"
}

assert_stopped_run() {
  local run_dir="$1" context="$2"
  if [ ! -s "$run_dir/final.json" ]; then
    printf 'FAIL: structured final outcome missing after %s\n' "$context" >&2
    return 1
  fi
  if ! jq -e '.outcome == "stopped" and (.reason | length > 0)' "$run_dir/final.json" >/dev/null; then
    printf 'FAIL: structured final outcome is not stopped after %s\n' "$context" >&2
    cat "$run_dir/final.json" >&2
    return 1
  fi
  if [ -e "$TMP/state/ai-watch/_1.watch" ]; then
    printf 'FAIL: live watch pointer survived %s\n' "$context" >&2
    return 1
  fi
}

cleanup() {
  local rc="${1:-$?}" pid brain_pid="" brain_child_pid=""
  [ -n "$MONITOR_PID" ] && kill -KILL "$MONITOR_PID" 2>/dev/null || true
  [ -n "$WATCH_PID" ] && kill -KILL "$WATCH_PID" 2>/dev/null || true
  [ -n "$LEGACY_PID" ] && kill -KILL "$LEGACY_PID" 2>/dev/null || true
  [ -n "$LEGACY_CHILD_PID" ] && kill -KILL "$LEGACY_CHILD_PID" 2>/dev/null || true
  if [ -r "$TMP/brain.pids" ]; then
    read -r brain_pid brain_child_pid < "$TMP/brain.pids" || true
    for pid in "$brain_pid" "$brain_child_pid"; do
      [ -n "$pid" ] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done
  fi
  wait "$MONITOR_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
  wait "$LEGACY_PID" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then
    rm -rf "$TMP"
  else
    printf 'INFO: failed lifecycle artifacts kept at %s\n' "$TMP" >&2
  fi
  return "$rc"
}
trap 'cleanup $?' EXIT

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/model-tmp"
export TMPDIR="$TMP/model-tmp"
printf '%s\n' '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  list-sessions) exit 0 ;;' \
  '  show-option)' \
  '    case "$*" in *@radar-ai-timeout*) [ -n "${TEST_AI_TIMEOUT:-}" ] && printf "%s\n" "$TEST_AI_TIMEOUT" ;; esac' \
  '    exit 0' \
  '    ;;' \
  '  display-message)' \
  '    [ -f "$TEST_PANE_ALIVE" ] || exit 1' \
  '    case "$*" in *pane_id*) printf "%s\n" "%1" ;; *) printf "%s\n" "test:0.0 codex" ;; esac' \
  '    ;;' \
  '  capture-pane)' \
  '    [ -f "$TEST_PANE_ALIVE" ] || exit 1' \
  '    printf "%s\n" "stable screen"' \
  '    ;;' \
  '  split-window)' \
  '    [ "${TEST_SPLIT_FAIL:-0}" = 1 ] && exit 1' \
  '    printf "%s\n" "%99"' \
  '    ;;' \
  '  send-keys|list-panes|kill-pane) exit 0 ;;' \
  '  *) exit 0 ;;' \
  'esac' > "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
printf '%s\n' 'tmux() { "$TEST_FAKE_TMUX" "$@"; }' > "$TMP/bashenv"

printf '%s\n' '#!/usr/bin/env bash' \
  'if [ -n "${TEST_CLEANUP_ORPHAN_PID:-}" ] && [ "$*" = "-axo pid=,command=" ]; then' \
  '  /bin/ps "$@" 2>/dev/null || true' \
  '  if [ -n "${TEST_CLEANUP_PUBLISH_POINTER:-}" ]; then' \
  '    printf "pane=%%99\npid=%s\nrun_id=%s\nrun_dir=%s\n" "$TEST_CLEANUP_ORPHAN_PID" "$TEST_CLEANUP_ORPHAN_RUN" "$TEST_CLEANUP_ORPHAN_DIR" > "$TEST_CLEANUP_PUBLISH_POINTER"' \
  '  fi' \
  '  printf "%s bash %s _watch_run %s\n" "$TEST_CLEANUP_ORPHAN_PID" "$TEST_CLEANUP_AI" "$TEST_CLEANUP_ORPHAN_RUN"' \
  '  exit 0' \
  'fi' \
  'if [ -n "${TEST_CLEANUP_ORPHAN_CHILD_PID:-}" ] && [ "$*" = "-axo pid=,ppid=" ]; then' \
  '  /bin/ps "$@" 2>/dev/null || true' \
  '  printf "%s 1\n%s %s\n" "$TEST_CLEANUP_ORPHAN_PID" "$TEST_CLEANUP_ORPHAN_CHILD_PID" "$TEST_CLEANUP_ORPHAN_PID"' \
  '  exit 0' \
  'fi' \
  'if [ -n "${TEST_CLEANUP_ORPHAN_PID:-}" ] && [ "$*" = "-p $TEST_CLEANUP_ORPHAN_PID -o command=" ]; then' \
  '  printf "bash %s _watch_run %s\n" "$TEST_CLEANUP_AI" "$TEST_CLEANUP_ORPHAN_RUN"' \
  '  exit 0' \
  'fi' \
  'exec /bin/ps "$@"' > "$TMP/bin/ps"
chmod +x "$TMP/bin/ps"

printf '%s\n' '#!/usr/bin/env bash' \
  'trap "" TERM INT HUP' \
  '(trap "" TERM INT HUP; exec /bin/sleep 300) &' \
  'child=$!' \
  'printf "%s %s\n" "$$" "$child" > "$TEST_LEGACY_PIDS"' \
  'wait "$child"' > "$TMP/bin/fake-legacy-owner"
chmod +x "$TMP/bin/fake-legacy-owner"

printf '%s\n' '#!/usr/bin/env bash' \
  'cat >/dev/null' \
  'trap "" TERM INT HUP' \
  'sleep 9999 &' \
  'child=$!' \
  'printf "%s %s\n" "$$" "$child" > "$TEST_BRAIN_PIDS"' \
  'wait "$child"' > "$TMP/bin/fake-brain"
chmod +x "$TMP/bin/fake-brain"

printf '%s\n' '#!/usr/bin/env bash' \
  'if [ -n "${TEST_DECISION_PROMPT:-}" ]; then cat > "$TEST_DECISION_PROMPT"; else cat >/dev/null; fi' \
  'printf "%s\n" '\''{"action":"send","text":"","keys":["Enter"],"safe":true,"reason":"test decision"}'\''' \
  > "$TMP/bin/fake-decision"
chmod +x "$TMP/bin/fake-decision"

printf '%s\n' '#!/usr/bin/env bash' \
  'cat >/dev/null' \
  '(trap "" TERM INT HUP; exec /bin/sleep 9999) &' \
  'child=$!' \
  'pgid="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d " ")"' \
  'printf "%s %s %s\n" "$$" "$child" "$pgid" > "$TEST_BRAIN_PIDS"' \
  'printf "%s\n" '\''{"action":"send","text":"","keys":["Enter"],"safe":true,"reason":"orphan cleanup decision"}'\''' \
  > "$TMP/bin/fake-orphan-decision"
chmod +x "$TMP/bin/fake-orphan-decision"

touch "$TMP/pane-alive"
printf '%%1\t0\tai\ttest\n' > "$TMP/state/need-input"

PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_AI_CMD="$TMP/bin/fake-brain" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_BRAIN_PIDS="$TMP/brain.pids" \
  bash "$ROOT/scripts/ai.sh" _watch_loop %1 '' always-allow 0.05 auto-safe \
  >"$TMP/watch.out" 2>"$TMP/watch.err" &
WATCH_PID=$!

wait_for_file "$TMP/brain.pids" || {
  printf 'FAIL: fake brain never started\n' >&2
  printf '%s\n' '--- watcher stdout ---' >&2
  cat "$TMP/watch.out" >&2 || true
  printf '%s\n' '--- watcher stderr ---' >&2
  cat "$TMP/watch.err" >&2 || true
  exit 1
}
RUN_DIR="$(current_run_dir)"

PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_TEST_MONITOR_READY="$TMP/monitor.ready" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
  bash "$ROOT/scripts/ai.sh" monitor-timeline %1 \
  >"$TMP/monitor.out" 2>"$TMP/monitor.err" &
MONITOR_PID=$!
wait_for_file "$TMP/monitor.ready" || {
  printf 'FAIL: monitor never acquired watcher ownership\n' >&2
  cat "$TMP/monitor.err" >&2 || true
  exit 1
}

kill -TERM "$MONITOR_PID"
wait "$MONITOR_PID" 2>/dev/null || true
MONITOR_PID=""

read -r brain_pid brain_child_pid < "$TMP/brain.pids"
failed=0
for pid in "$WATCH_PID" "$brain_pid" "$brain_child_pid"; do
  if ! wait_for_exit "$pid"; then
    printf 'FAIL: process %s survived monitor-pane termination\n' "$pid" >&2
    ps -p "$pid" -o pid=,ppid=,state=,command= -ww >&2 || true
    failed=1
  fi
done
if [ "$failed" -ne 0 ]; then
  printf '%s\n' '--- watcher stdout ---' >&2
  cat "$TMP/watch.out" >&2 || true
  printf '%s\n' '--- watcher stderr ---' >&2
  cat "$TMP/watch.err" >&2 || true
  exit 1
fi
assert_stopped_run "$RUN_DIR" "monitor-pane termination"

WATCH_PID=""
printf 'PASS: monitor-pane termination stops watcher and full brain process tree\n'

# A model call must not outlive the target pane even when the watcher is
# blocked waiting for the model response.
: > "$TMP/brain.pids"
touch "$TMP/pane-alive"
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_AI_CMD="$TMP/bin/fake-brain" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_BRAIN_PIDS="$TMP/brain.pids" \
  bash "$ROOT/scripts/ai.sh" _watch_loop %1 '' always-allow 0.05 auto-safe \
  >"$TMP/watch.out" 2>"$TMP/watch.err" &
WATCH_PID=$!

wait_for_file "$TMP/brain.pids" || {
  printf 'FAIL: fake brain never started for target-pane test\n' >&2
  exit 1
}
RUN_DIR="$(current_run_dir)"
read -r brain_pid brain_child_pid < "$TMP/brain.pids"
rm -f "$TMP/pane-alive"

failed=0
for pid in "$WATCH_PID" "$brain_pid" "$brain_child_pid"; do
  if ! wait_for_exit "$pid"; then
    printf 'FAIL: process %s survived target-pane removal\n' "$pid" >&2
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1
assert_stopped_run "$RUN_DIR" "target-pane removal"

WATCH_PID=""
printf 'PASS: target-pane removal stops watcher and full brain process tree\n'

# A wedged CLI/API call must have a finite lifetime even while its target pane
# remains valid.
: > "$TMP/brain.pids"
touch "$TMP/pane-alive"
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_AI_TIMEOUT=5 \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_AI_CMD="$TMP/bin/fake-brain" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_BRAIN_PIDS="$TMP/brain.pids" \
  bash "$ROOT/scripts/ai.sh" _watch_loop %1 '' always-allow 0.05 auto-safe \
  >"$TMP/watch.out" 2>"$TMP/watch.err" &
WATCH_PID=$!

wait_for_file "$TMP/brain.pids" || {
  printf 'FAIL: fake brain never started for timeout test\n' >&2
  exit 1
}
RUN_DIR="$(current_run_dir)"
read -r brain_pid brain_child_pid < "$TMP/brain.pids"

failed=0
for pid in "$brain_pid" "$brain_child_pid"; do
  if ! wait_for_exit "$pid"; then
    printf 'FAIL: process %s survived the brain-call timeout\n' "$pid" >&2
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1

kill -TERM "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""
assert_stopped_run "$RUN_DIR" "brain timeout owner shutdown"
printf 'PASS: brain-call timeout stops the full brain process tree\n'

# One-shot popup commands own their model process just like resident watchers.
# Closing the popup during a decision must not orphan the CLI process group.
: > "$TMP/brain.pids"
touch "$TMP/pane-alive"
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_AI_CMD="$TMP/bin/fake-brain" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_BRAIN_PIDS="$TMP/brain.pids" \
  bash "$ROOT/scripts/ai.sh" decide %1 auto-safe \
  >"$TMP/decide.out" 2>"$TMP/decide.err" &
WATCH_PID=$!

wait_for_file "$TMP/brain.pids" || {
  printf 'FAIL: fake brain never started for one-shot owner test\n' >&2
  exit 1
}
read -r brain_pid brain_child_pid < "$TMP/brain.pids"
kill -TERM "$WATCH_PID"
wait "$WATCH_PID" 2>/dev/null || true

failed=0
for pid in "$brain_pid" "$brain_child_pid"; do
  if ! wait_for_exit "$pid"; then
    printf 'FAIL: process %s survived one-shot owner termination\n' "$pid" >&2
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1

WATCH_PID=""
printf 'PASS: one-shot owner termination stops the full brain process tree\n'

touch "$TMP/pane-alive"
decision_output="$(
  PATH="$TMP/bin:$PATH" \
  BASH_ENV="$TMP/bashenv" \
  TEST_FAKE_TMUX="$TMP/bin/tmux" \
  TMUX_RADAR_STATE_DIR="$TMP/state" \
  TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  TMUX_RADAR_AI_CMD="$TMP/bin/fake-decision" \
  TEST_PANE_ALIVE="$TMP/pane-alive" \
    bash "$ROOT/scripts/ai.sh" decide %1 auto-safe
)"
case "$decision_output" in
  *"已发送"*) : ;;
  *)
    printf 'FAIL: normal brain decision was not parsed after lifecycle refactor\n%s\n' "$decision_output" >&2
    exit 1
    ;;
esac
printf 'PASS: normal brain decisions still return structured actions\n'

# A backend leader can emit a valid result and exit while a helper survives in
# its process group. The result is usable only after the whole group is proven
# gone and its marker is removed.
: > "$TMP/brain.pids"
decision_output="$(
  PATH="$TMP/bin:$PATH" \
  BASH_ENV="$TMP/bashenv" \
  TEST_FAKE_TMUX="$TMP/bin/tmux" \
  TMUX_RADAR_STATE_DIR="$TMP/state" \
  TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  TMUX_RADAR_AI_CMD="$TMP/bin/fake-orphan-decision" \
  TEST_PANE_ALIVE="$TMP/pane-alive" \
  TEST_BRAIN_PIDS="$TMP/brain.pids" \
    bash "$ROOT/scripts/ai.sh" decide %1 auto-safe
)"
read -r _ orphan_child orphan_pgid < "$TMP/brain.pids"
case "$decision_output" in
  *"已发送"*) : ;;
  *)
    printf 'FAIL: cleaned orphan-group decision did not complete\n%s\n' "$decision_output" >&2
    exit 1
    ;;
esac
if process_effectively_alive "$orphan_child"; then
  printf 'FAIL: normal backend leader exit left descendant %s alive\n' "$orphan_child" >&2
  exit 1
fi
if ps -axo pgid=,state= 2>/dev/null |
  awk -v pgid="$orphan_pgid" '$1 == pgid && $2 !~ /^[Zz]/ { found=1 } END { exit !found }'; then
  printf 'FAIL: normal backend leader exit left process group %s alive\n' "$orphan_pgid" >&2
  exit 1
fi
[ ! -e "$TMP/state/ai-watch/_1.brain.pid" ] || {
  printf 'FAIL: proven-empty normal backend group retained its marker\n' >&2
  exit 1
}
printf 'PASS: normal backend leader exit proves its full process group gone\n'

# The private fallback authority is an in-process watcher channel. A public
# decide invocation must ignore an inherited environment variable that points
# at an arbitrary readable file.
printf 'must-not-reach-model\n' > "$TMP/ambient-capture"
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_DECISION_PROMPT="$TMP/public-decide.prompt" \
TMUX_RADAR_DECIDE_CAPTURE_FILE="$TMP/ambient-capture" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_AI_CMD="$TMP/bin/fake-decision" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
  bash "$ROOT/scripts/ai.sh" decide %1 auto-safe >/dev/null
grep -q 'stable screen' "$TMP/public-decide.prompt" || {
  printf 'FAIL: public decide did not use the live pane capture\n' >&2
  exit 1
}
if grep -q 'must-not-reach-model' "$TMP/public-decide.prompt"; then
  printf 'FAIL: public decide trusted an ambient capture-file path\n' >&2
  exit 1
fi
printf 'PASS: public decide ignores ambient capture-file paths\n'

# When monitor panes are enabled, failure to create their visible control
# surface must abort the just-launched watcher instead of degrading to a hidden
# background consumer.
: > "$TMP/brain.pids"
touch "$TMP/pane-alive"
set +e
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_SPLIT_FAIL=1 \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_AI_CMD="$TMP/bin/fake-brain" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_BRAIN_PIDS="$TMP/brain.pids" \
  bash "$ROOT/scripts/ai.sh" watch %1 '' always-allow 0.05 auto-safe \
  >"$TMP/watch-launch.out" 2>"$TMP/watch-launch.err"
watch_rc=$?
set -e
sleep 0.4

watch_file="$TMP/state/ai-watch/_1.watch"
if [ -r "$watch_file" ]; then
  WATCH_PID="$(awk -F= '$1 == "pid" { print $2; exit }' "$watch_file")"
fi
if [ "$watch_rc" -eq 0 ]; then
  printf 'FAIL: watch reported success when its monitor pane could not be created\n' >&2
  exit 1
fi
if [ -n "$WATCH_PID" ] && process_alive "$WATCH_PID"; then
  printf 'FAIL: watcher %s survived monitor-pane creation failure\n' "$WATCH_PID" >&2
  exit 1
fi
WATCH_PID=""
printf 'PASS: monitor-pane creation failure aborts the watcher\n'

# The active brain owner must also fail closed when TERM/KILL was sent but the
# liveness proof itself cannot be established. It must return promptly, retain
# the ownership marker for a later cleanup attempt, and never retry the model.
: > "$TMP/brain.pids"
touch "$TMP/pane-alive"
set +e
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_AI_CMD="$TMP/bin/fake-brain" \
TMUX_RADAR_TEST_FORCE_TERMINATION_LIVE=1 \
TMUX_RADAR_TERMINATE_TERM_ATTEMPTS=1 \
TMUX_RADAR_TERMINATE_KILL_ATTEMPTS=1 \
TMUX_RADAR_TERMINATE_DELAY=0.01 \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_BRAIN_PIDS="$TMP/brain.pids" \
  bash "$ROOT/scripts/ai.sh" decide %1 auto-safe \
  >"$TMP/unproven-decide.out" 2>"$TMP/unproven-decide.err" &
WATCH_PID=$!
set -e

wait_for_file "$TMP/brain.pids" || {
  printf 'FAIL: fake brain never started for active termination-proof test\n' >&2
  exit 1
}
brain_marker="$TMP/state/ai-watch/_1.brain.pid"
wait_for_file "$brain_marker" || {
  printf 'FAIL: active brain did not publish its ownership marker\n' >&2
  exit 1
}
rm -f "$TMP/pane-alive"
if ! wait_for_exit "$WATCH_PID"; then
  printf 'FAIL: active brain blocked after termination proof failed\n' >&2
  exit 1
fi
set +e
wait "$WATCH_PID"
unproven_decide_rc=$?
set -e
WATCH_PID=""
[ "$unproven_decide_rc" -ne 0 ] || {
  printf 'FAIL: active brain reported success without process termination proof\n' >&2
  exit 1
}
[ -e "$brain_marker" ] || {
  printf 'FAIL: active brain deleted its marker without termination proof\n' >&2
  exit 1
}
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  bash "$ROOT/scripts/ai.sh" stop %1 >/dev/null
[ ! -e "$brain_marker" ] || {
  printf 'FAIL: later proven cleanup did not remove the active brain marker\n' >&2
  exit 1
}
printf 'PASS: active brain preserves ownership evidence when exit is unproven\n'

# A failed liveness proof must retain the brain marker and make `stop` fail.
# Marker deletion is evidence only after the recorded process/group is gone.
printf 'pid=999999\npgid=999999\nidentity=\nwatch_pid=999998\npane=%%1\nstarted=1\noutput=\n' \
  > "$brain_marker"
set +e
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_TEST_FORCE_TERMINATION_LIVE=1 \
TMUX_RADAR_TERMINATE_TERM_ATTEMPTS=1 \
TMUX_RADAR_TERMINATE_KILL_ATTEMPTS=1 \
TMUX_RADAR_TERMINATE_DELAY=0.01 \
  bash "$ROOT/scripts/ai.sh" stop %1 >"$TMP/unproven-stop.out" 2>"$TMP/unproven-stop.err"
unproven_stop_rc=$?
set -e
[ "$unproven_stop_rc" -ne 0 ] || {
  printf 'FAIL: stop reported success without process termination proof\n' >&2
  exit 1
}
[ -e "$brain_marker" ] || {
  printf 'FAIL: failed termination proof deleted the brain marker\n' >&2
  exit 1
}
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  bash "$ROOT/scripts/ai.sh" stop %1 >/dev/null
[ ! -e "$brain_marker" ] || {
  printf 'FAIL: proven-dead brain marker was not removed\n' >&2
  exit 1
}
printf 'PASS: stop cannot acknowledge an unproven process-group exit\n'

# SIGKILL bypasses watcher traps. `cleanup` must remove the transient raw
# fallback authority independently from brain-process termination proof.
: > "$TMP/brain.pids"
: > "$TMP/state/need-input"
touch "$TMP/pane-alive"
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_AI_CMD="$TMP/bin/fake-brain" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_BRAIN_PIDS="$TMP/brain.pids" \
  bash "$ROOT/scripts/ai.sh" _watch_loop %1 '' always-allow 0.05 auto-safe \
  >"$TMP/crash-watch.out" 2>"$TMP/crash-watch.err" &
WATCH_PID=$!
wait_for_file "$TMP/state/ai-watch/_1.watch" || {
  printf 'FAIL: crash-GC watcher did not publish its pointer\n' >&2
  exit 1
}
RUN_DIR="$(current_run_dir)"
wait_for_file "$RUN_DIR/.decision-capture" || {
  printf 'FAIL: crash-GC watcher did not publish fallback authority\n' >&2
  exit 1
}
brain_marker="$TMP/state/ai-watch/_1.brain.pid"
wait_for_file "$brain_marker" || {
  printf 'FAIL: crash-GC watcher did not publish brain ownership\n' >&2
  exit 1
}
kill -KILL "$WATCH_PID"
wait "$WATCH_PID" 2>/dev/null || true
WATCH_PID=""

PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
TMUX_RADAR_TEST_FORCE_TERMINATION_LIVE=1 \
TMUX_RADAR_TERMINATE_TERM_ATTEMPTS=1 \
TMUX_RADAR_TERMINATE_KILL_ATTEMPTS=1 \
TMUX_RADAR_TERMINATE_DELAY=0.01 \
  bash "$ROOT/scripts/ai.sh" cleanup >/dev/null
[ ! -e "$RUN_DIR/.decision-capture" ] || {
  printf 'FAIL: crash cleanup retained the raw fallback authority\n' >&2
  exit 1
}
[ -e "$brain_marker" ] || {
  printf 'FAIL: crash cleanup deleted unproven brain ownership\n' >&2
  exit 1
}

PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  bash "$ROOT/scripts/ai.sh" cleanup >/dev/null
[ ! -e "$brain_marker" ] || {
  printf 'FAIL: crash cleanup did not remove proven-dead brain ownership\n' >&2
  exit 1
}
printf 'PASS: crash cleanup removes private captures without discarding ownership evidence\n'

# A ready acknowledgement is not terminal proof: cleanup may race a native
# watcher between process launch and pointer publication.
ready_run='ready-native-owner'
mkdir -p "$TMP/state/ai-runs/$ready_run"
printf '{"schema_version":1,"run_id":"%s"}\n' "$ready_run" \
  > "$TMP/state/ai-runs/$ready_run/ready.json"
TEST_LEGACY_PIDS="$TMP/ready-owner.pids" "$TMP/bin/fake-legacy-owner" &
LEGACY_PID=$!
wait_for_file "$TMP/ready-owner.pids" || {
  printf 'FAIL: ready native owner did not start\n' >&2
  exit 1
}
read -r owner_pid LEGACY_CHILD_PID < "$TMP/ready-owner.pids"
[ "$owner_pid" = "$LEGACY_PID" ] || {
  printf 'FAIL: ready native owner PID mismatch\n' >&2
  exit 1
}
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_CLEANUP_ORPHAN_PID="$LEGACY_PID" \
TEST_CLEANUP_ORPHAN_RUN="$ready_run" \
TEST_CLEANUP_AI="$ROOT/scripts/ai.sh" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  bash "$ROOT/scripts/ai.sh" cleanup >/dev/null
if ! process_effectively_alive "$LEGACY_PID" || ! process_effectively_alive "$LEGACY_CHILD_PID"; then
  printf 'FAIL: cleanup reaped a ready native owner without terminal proof\n' >&2
  exit 1
fi
kill -KILL "$LEGACY_CHILD_PID" "$LEGACY_PID" 2>/dev/null || true
wait "$LEGACY_PID" 2>/dev/null || true
LEGACY_PID=""; LEGACY_CHILD_PID=""
printf 'PASS: cleanup preserves ready native owners without terminal proof\n'

# Even a finalized run is protected when its pointer appears after cleanup's
# initial snapshot. Once that pointer is removed, cleanup must reap the exact
# TERM-resistant parent and child tree left by pre-v0.1.2 native owners.
legacy_run='legacy-native-orphan'
legacy_dir="$TMP/state/ai-runs/$legacy_run"
legacy_pointer="$TMP/state/ai-watch/legacy-race.watch"
mkdir -p "$legacy_dir"
printf '{"schema_version":1,"run_id":"%s","outcome":"stopped","reason":"test final","finalized_epoch":1}\n' \
  "$legacy_run" > "$legacy_dir/final.json"
TEST_LEGACY_PIDS="$TMP/legacy-owner.pids" "$TMP/bin/fake-legacy-owner" &
LEGACY_PID=$!
wait_for_file "$TMP/legacy-owner.pids" || {
  printf 'FAIL: finalized native owner did not start\n' >&2
  exit 1
}
read -r owner_pid LEGACY_CHILD_PID < "$TMP/legacy-owner.pids"
[ "$owner_pid" = "$LEGACY_PID" ] || {
  printf 'FAIL: finalized native owner PID mismatch\n' >&2
  exit 1
}
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_CLEANUP_ORPHAN_PID="$LEGACY_PID" \
TEST_CLEANUP_ORPHAN_RUN="$legacy_run" \
TEST_CLEANUP_ORPHAN_DIR="$legacy_dir" \
TEST_CLEANUP_PUBLISH_POINTER="$legacy_pointer" \
TEST_CLEANUP_AI="$ROOT/scripts/ai.sh" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  bash "$ROOT/scripts/ai.sh" cleanup >/dev/null
if ! process_effectively_alive "$LEGACY_PID" || ! process_effectively_alive "$LEGACY_CHILD_PID"; then
  printf 'FAIL: cleanup ignored a pointer published after its initial snapshot\n' >&2
  exit 1
fi
rm -f "$legacy_pointer"
PATH="$TMP/bin:$PATH" \
BASH_ENV="$TMP/bashenv" \
TEST_FAKE_TMUX="$TMP/bin/tmux" \
TEST_PANE_ALIVE="$TMP/pane-alive" \
TEST_CLEANUP_ORPHAN_PID="$LEGACY_PID" \
TEST_CLEANUP_ORPHAN_CHILD_PID="$LEGACY_CHILD_PID" \
TEST_CLEANUP_ORPHAN_RUN="$legacy_run" \
TEST_CLEANUP_ORPHAN_DIR="$legacy_dir" \
TEST_CLEANUP_AI="$ROOT/scripts/ai.sh" \
TMUX_RADAR_STATE_DIR="$TMP/state" \
TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  bash "$ROOT/scripts/ai.sh" cleanup >/dev/null
legacy_parent_alive=0
legacy_child_alive=0
wait_for_effective_exit "$LEGACY_PID" || legacy_parent_alive=1
wait_for_effective_exit "$LEGACY_CHILD_PID" || legacy_child_alive=1
if [ "$legacy_parent_alive" -ne 0 ] || [ "$legacy_child_alive" -ne 0 ]; then
  printf 'FAIL: cleanup left finalized native owner processes alive (parent=%s child=%s)\n' \
    "$legacy_parent_alive" "$legacy_child_alive" >&2
  /bin/ps -p "$LEGACY_PID" -o pid=,ppid=,state=,command= >&2 || true
  /bin/ps -p "$LEGACY_CHILD_PID" -o pid=,ppid=,state=,command= >&2 || true
  exit 1
fi
wait "$LEGACY_PID" 2>/dev/null || true
LEGACY_PID=""; LEGACY_CHILD_PID=""
printf 'PASS: cleanup closes pointer races and reaps finalized native owner trees\n'

brain_temp_files="$(find "$TMP/model-tmp" -maxdepth 1 -type f -name 'tmuxai.*' -print)"
if [ -n "$brain_temp_files" ]; then
  printf 'FAIL: brain temporary files survived lifecycle termination\n%s\n' "$brain_temp_files" >&2
  exit 1
fi
printf 'PASS: lifecycle termination removes brain temporary files\n'

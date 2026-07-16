#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir idle-process-budget)"
WATCH_PID=""

cleanup() {
  local rc="${1:-$?}" attempt=0 pid
  trap - EXIT TERM INT HUP
  rm -f "${TEST_WAITER_LIVENESS:-}" "${TEST_PROCESS_LIVENESS:-}"
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
    kill -TERM "$WATCH_PID" 2>/dev/null || true
    while [ "$attempt" -lt 80 ] && kill -0 "$WATCH_PID" 2>/dev/null; do
      /bin/sleep 0.05
      attempt=$((attempt + 1))
    done
    kill -0 "$WATCH_PID" 2>/dev/null && kill -KILL "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  for pid in $(cat "${TEST_WAITER_PIDS:-/dev/null}" 2>/dev/null || true); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
  exit "$rc"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/signals"
cp "$ROOT/tests/fixtures/fake-tmux-supervision" "$TMP/bin/tmux"
chmod +x "$TMP/bin/tmux"
cat > "$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$TEST_SLEEP_LOG"
exec /bin/sleep "$@"
EOF
chmod +x "$TMP/bin/sleep"
# shellcheck disable=SC2016
printf '%s\n' 'tmux() { "$TEST_FAKE_TMUX" "$@"; }' > "$TMP/bashenv"

export TMUX_RADAR_STATE_DIR="$TMP/state"
export TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input"
export TMUX_RADAR_AI_CMD=/usr/bin/true
export TEST_FAKE_TMUX="$TMP/bin/tmux"
export BASH_ENV="$TMP/bashenv"
export TEST_PANE_ALIVE="$TMP/pane-alive"
export TEST_SCREEN="$TMP/screen"
export TEST_SENDS="$TMP/sends"
export TEST_SEND_COUNT="$TMP/send-count"
export TEST_SIGNALS="$TMP/signals"
export TEST_WAITER_PIDS="$TMP/waiter.pids"
export TEST_WAITER_LIVENESS="$TMP/waiter.live"
export TEST_WAITER_MAX_SECONDS=30
export TEST_PROCESS_LIVENESS="$TMP/process.live"
export TEST_SLEEP_LOG="$TMP/sleep.log"
export TEST_AI_TIMEOUT=5
export TEST_MAX_CALLS=1
: > "$TMUX_RADAR_NEEDINPUT_FILE"
: > "$TEST_SENDS"
: > "$TEST_SEND_COUNT"
: > "$TEST_WAITER_PIDS"
: > "$TEST_SLEEP_LOG"
printf 'idle screen\n' > "$TEST_SCREEN"
touch "$TEST_PANE_ALIVE" "$TEST_WAITER_LIVENESS" "$TEST_PROCESS_LIVENESS"

env -u TMUX_RADAR_TEST_WAIT_TICK PATH="$TMP/bin:$PATH" \
  bash "$ROOT/scripts/ai.sh" _watch_loop %1 'idle process budget' always-allow 30 auto-safe \
  >"$TMP/watch.out" 2>"$TMP/watch.err" &
WATCH_PID=$!

attempt=0
while [ "$attempt" -lt 120 ] && [ ! -s "$TMP/state/ai-watch/_1.watch" ]; do
  /bin/sleep 0.025
  attempt=$((attempt + 1))
done
assert_file "$TMP/state/ai-watch/_1.watch"
/bin/sleep 2

assert_eq 1 "$(wc -l < "$TEST_SLEEP_LOG" | tr -d ' ')" \
  'idle watcher starts one timer and does not fork polling sleeps'
assert_eq 30 "$(cat "$TEST_SLEEP_LOG")" 'only the configured idle timer sleeps'

printf 'PASS: idle watcher has a one-process timer budget and no polling forks\n'

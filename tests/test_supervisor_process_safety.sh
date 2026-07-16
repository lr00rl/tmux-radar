#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir supervisor-process-safety)"
WAITER_PID=""

cleanup() {
  local rc="${1:-$?}"
  if [ -n "$WAITER_PID" ] && kill -0 "$WAITER_PID" 2>/dev/null; then
    kill -TERM "$WAITER_PID" 2>/dev/null || true
    wait "$WAITER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap 'cleanup $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

FAKE_TMUX="$ROOT/tests/fixtures/fake-tmux-supervision"
[ -x "$FAKE_TMUX" ] || _fail_assert \
  'supervision fake tmux must be a directly testable executable fixture' \
  'file' "$FAKE_TMUX"

if awk '
  /while .*sleep 0\.01/ { print FNR ":" $0; found=1 }
  END { exit found ? 0 : 1 }
' "$ROOT/tests/test_ai_supervision.sh" > "$TMP/hot-loops"; then
  _fail_assert 'supervision fixtures contain an unbounded 10 ms external-sleep loop' \
    'matches' "$(cat "$TMP/hot-loops")"
fi

if awk '
  /^_watch_wait_for_batch\(\)/ { inside=1 }
  inside && /sleep "\$tick"/ { print FNR ":" $0; found=1 }
  inside && /^}/ { inside=0 }
  END { exit found ? 0 : 1 }
' "$ROOT/scripts/ai.sh" > "$TMP/idle-poll-loops"; then
  _fail_assert 'idle supervision waits by repeatedly forking sleep' \
    'matches' "$(cat "$TMP/idle-poll-loops")"
fi

mkdir -p "$TMP/lock-bin" "$TMP/lock-state/ai-watch/.launch-_1.lock"
printf '%s\n' "$$" > "$TMP/lock-state/ai-watch/.launch-_1.lock/owner"
cat > "$TMP/lock-bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$TEST_LOCK_SLEEP_LOG"
exec /bin/sleep "$@"
EOF
chmod +x "$TMP/lock-bin/sleep"
export TEST_LOCK_SLEEP_LOG="$TMP/lock-sleeps"
: > "$TEST_LOCK_SLEEP_LOG"
(
  export RADAR_WATCH_DIR="$TMP/lock-state/ai-watch"
  # shellcheck disable=SC1091
  source "$ROOT/scripts/lib/ai-runtime.sh"
  set +e
  PATH="$TMP/lock-bin:$PATH" radar_launch_lock_acquire %1 1000 0.005
  lock_rc=$?
  set -e
  [ "$lock_rc" -ne 0 ] || _fail_assert 'live launch lock was stolen'
)
lock_sleeps="$(wc -l < "$TEST_LOCK_SLEEP_LOG" | tr -d ' ')"
[ "$lock_sleeps" -le 12 ] || _fail_assert \
  'bounded launch-lock contention still forks too many sleep processes' \
  'sleep calls' "$lock_sleeps"

mkdir -p "$TMP/signals"
export TEST_SIGNALS="$TMP/signals"
export TEST_WAITER_PIDS="$TMP/waiter.pids"
export TEST_WAITER_LIVENESS="$TMP/waiter.live"
export TEST_WAITER_MAX_SECONDS=5
touch "$TEST_WAITER_LIVENESS"

"$FAKE_TMUX" wait-for radar-process-safety &
WAITER_PID=$!
wait_for_file "$TEST_WAITER_PIDS" 40 0.025
assert_eq "$WAITER_PID" "$(tail -n 1 "$TEST_WAITER_PIDS")" \
  'fixture records the exact blocking waiter'

rm -f "$TEST_WAITER_LIVENESS"
wait_for_exit "$WAITER_PID" 100 0.025
wait "$WAITER_PID"
WAITER_PID=""

touch "$TEST_WAITER_LIVENESS"
: > "$TEST_WAITER_PIDS"
"$FAKE_TMUX" wait-for radar-process-signal &
WAITER_PID=$!
wait_for_file "$TEST_WAITER_PIDS" 40 0.025
"$FAKE_TMUX" wait-for -S radar-process-signal
wait_for_exit "$WAITER_PID" 100 0.025
wait "$WAITER_PID"
WAITER_PID=""

for signal in TERM INT HUP; do
  : > "$TEST_WAITER_PIDS"
  bash -c '
    signal="$1"; fixture="$2"
    (/bin/sleep 0.1; kill -"$signal" "$$") &
    exec "$fixture" wait-for "radar-process-${signal}"
  ' _ "$signal" "$FAKE_TMUX"
done

export TEST_WAITER_MAX_SECONDS=1
: > "$TEST_WAITER_PIDS"
"$FAKE_TMUX" wait-for radar-process-deadline &
WAITER_PID=$!
wait_for_file "$TEST_WAITER_PIDS" 40 0.025
wait_for_exit "$WAITER_PID" 100 0.025
wait "$WAITER_PID"
WAITER_PID=""

printf 'PASS: supervision waiters have wake, owner-liveness, TERM/INT/HUP, and deadline exits\n'

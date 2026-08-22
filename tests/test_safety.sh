#!/usr/bin/env bash
# Regression tests for the 4 fix-first review findings. Isolated tmux server.
# shellcheck disable=SC2034
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$WT/scripts/needinput-notify.sh"
T="$(mktemp -d /tmp/radar-regress.XXXXXX)"
export TMUX_RADAR_STATE_DIR="$T/state"
MARKS="$TMUX_RADAR_STATE_DIR/need-input"
REG="$TMUX_RADAR_STATE_DIR/agent-registry"
LOCK="$TMUX_RADAR_STATE_DIR/.need-input.lock"
SPOOL="$TMUX_RADAR_STATE_DIR/needinput-spool"
export TMUX_RADAR_NO_SCHEDULE=1   # ticks are driven explicitly in this suite

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi; }

tmux -L radarreg -f /dev/null kill-server 2>/dev/null || true
tmux -L radarreg -f /dev/null new-session -d -s reg 2>/dev/null
TMUX="$(tmux -L radarreg display-message -p '#{socket_path}'),99999,0"
export TMUX
unset TMUX_PANE CLAUDE_JOB_DIR 2>/dev/null || true
PANE="$(tmux list-panes -a -F '#{pane_id}' | head -1)"
mkdir -p "$TMUX_RADAR_STATE_DIR"

echo
echo "### #3 HIGH: paneless marks are not wiped without a registry snapshot"
rm -f "$REG" "$MARKS"
"$N" mark - claude "Claude·proj: Claude needs your permission" s:nosnap
"$N" tick
chk "no registry file => paneless agent mark SURVIVES tick" "grep -q 's:nosnap' '$MARKS'"
: > "$REG"        # registry exists but empty (all sessions ended)
"$N" tick
chk "empty registry (sessions ended) => stale paneless mark IS GCd" "! grep -q 's:nosnap' '$MARKS' 2>/dev/null || ! [ -s '$MARKS' ]"
# public `mark -` API from a user script must never be GCd by agent liveness
"$N" mark - tool "my script wants attention" k:userscript
"$N" tick
chk "non-agent source (public mark API) survives tick" "grep -q 'k:userscript' '$MARKS'"
"$N" clear-all

echo
echo "### #4 MEDIUM: lock ownership — reap stale, never rmdir a live holder's lock"
mkdir -p "$LOCK"; printf '999999' > "$LOCK/pid"    # crashed holder (dead pid)
S="$(date +%s)"; "$N" tick >/dev/null 2>&1; E="$(date +%s)"
chk "stale lock reaped, no 2s stall" "[ \$((E - S)) -lt 2 ]"
chk "stale lock dir is gone" "[ ! -d '$LOCK' ]"
# live holder: a real running pid owns the lock -> we must give up WITHOUT deleting it
sleep 30 & HOLDER=$!
mkdir -p "$LOCK"; printf '%s' "$HOLDER" > "$LOCK/pid"
LOCKED_MARK_RC=0
"$N" mark - tool "must not race" k:lock-race >/dev/null 2>&1 || LOCKED_MARK_RC=$?
"$N" tick >/dev/null 2>&1
chk "live holder's lock NOT rmdir'd by a give-up path" "[ -d '$LOCK' ] && [ \"\$(cat '$LOCK/pid')\" = '$HOLDER' ]"
chk "lock timeout never falls through to an unlocked write" "! grep -q 'k:lock-race' '$MARKS' 2>/dev/null"
chk "lock exhaustion spools the event instead of dropping it" \
  "[ '$LOCKED_MARK_RC' -eq 0 ] && grep -q 'k:lock-race' '$SPOOL'"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -rf "$LOCK"
"$N" tick >/dev/null 2>&1
chk "next tick replays the spooled mark" \
  "grep -q 'k:lock-race' '$MARKS' && [ ! -s '$SPOOL' ]"
"$N" clear-all; rm -f "$SPOOL" "$TMUX_RADAR_STATE_DIR/.drain-at"
# A legacy holder may be between mkdir and owner publication. Absence of an
# owner is not proof of death, so the new implementation must fail closed.
mkdir -p "$LOCK"
"$N" mark - tool "must not steal unpublished lock" k:unpublished >/dev/null 2>&1
chk "owner-publication window is never stolen" \
  "[ -d '$LOCK' ] && ! grep -q 'k:unpublished' '$MARKS' 2>/dev/null"
rm -rf "$LOCK"

echo
echo "### #5 HIGH: concurrent stale reapers have exactly one lock owner"
rm -f "$MARKS"; mkdir -p "$LOCK"; printf '999999' > "$LOCK/pid"
PIDS=""
for i in 1 2 3 4 5 6 7 8; do
  "$N" mark - tool "parallel-$i" "k:parallel-$i" >/dev/null 2>&1 &
  PIDS="$PIDS $!"
done
for p in $PIDS; do wait "$p"; done
chk "all concurrent marks survive stale-lock recovery" \
  "[ \$(grep -c 'k:parallel-' '$MARKS' 2>/dev/null || true) -eq 8 ]"
chk "parallel stale recovery leaves no lock" "[ ! -d '$LOCK' ]"
"$N" clear-all

echo
echo "### #6 MEDIUM: an orphaned legacy reaper guard cannot disable notifications"
rm -f "$MARKS"; rm -rf "$LOCK"; mkdir -p "$LOCK" "${LOCK}.reap"
printf '999999' > "$LOCK/pid"
"$N" mark - tool "guard-independent" k:guard-independent >/dev/null 2>&1
chk "orphaned legacy reaper guard does not block a new mark" \
  "grep -q 'k:guard-independent' '$MARKS'"
rm -rf "${LOCK}.reap"; "$N" clear-all

echo
echo "### #7 LOW: tick takes one ps snapshot, including failure"
PSBIN="$T/ps-bin"; mkdir -p "$PSBIN"
cat > "$PSBIN/ps" <<'SH'
#!/usr/bin/env bash
printf '1\n' >> "$TMUX_RADAR_PS_COUNT"
exit 0
SH
chmod +x "$PSBIN/ps"
PS_COUNT="$T/ps-count"; : > "$PS_COUNT"
TMUX_RADAR_TEST_PS_BIN="$PSBIN/ps" TMUX_RADAR_PS_COUNT="$PS_COUNT" "$N" tick >/dev/null 2>&1
chk "empty/failed ps path is not retried inside one tick" \
  "[ \$(wc -l < '$PS_COUNT' | tr -d ' ') -eq 1 ]"

echo
echo "### #8 HIGH: tick cannot delete a newer row from a stale snapshot"
sleep 30 & FRESH=$!
now="$(date +%s)"
printf 'claude\ts:gc-race\t999999\t-\t%s\t%s\twaiting\t/tmp\tclaude\n' "$now" "$now" > "$REG"
"$N" mark - claude "Claude needs your permission" s:gc-race
mkdir -p "$LOCK"; printf '%s' "$$" > "$LOCK/pid"
"$N" tick >/dev/null 2>&1 & TICK_PID=$!
sleep 0.2
printf 'claude\ts:gc-race\t%s\t-\t%s\t%s\twaiting\t/tmp\tsleep\n' "$FRESH" "$now" "$((now + 1))" > "$REG"
rm -rf "$LOCK"
wait "$TICK_PID"
chk "newer live registry row survives stale GC verdict" \
  "awk -F'\t' -v p='$FRESH' '\$2==\"s:gc-race\" && \$3==p' '$REG' | grep -q ."
chk "newer session action mark survives stale GC verdict" "grep -q 's:gc-race' '$MARKS'"
kill "$FRESH" 2>/dev/null; wait "$FRESH" 2>/dev/null
"$N" clear-all

echo
echo "### #9/#10 follow-ups"
chk "completion marks have no lifecycle-cleanup exemption" \
  "! grep -Eq 'DONE_RE|donere' '$N'"
sleep 30 & OC=$!
printf '{"event":"start","session_id":"realsid","pane":"%s","pid":%s,"cwd":"/tmp/oc"}' "$PANE" "$OC" | "$N" opencode-hook
printf '{"event":"permission","session_id":"realsid","pane":"%s","pid":%s,"cwd":"/tmp/oc","message":"y?"}' "$PANE" "$OC" | "$N" opencode-hook
chk "opencode uses ONE session key across lifecycle events" \
  "[ \$(awk -F'\t' '\$1==\"opencode\" && \$2==\"oc:s:realsid\"' '$REG' | wc -l | tr -d ' ') -eq 1 ]"
printf '{"event":"end","session_id":"realsid","pane":"%s","pid":%s,"cwd":"/tmp/oc"}' "$PANE" "$OC" | "$N" opencode-hook
chk "opencode end clears the permission mark it set" "! grep -q 'needs approval' '$MARKS' 2>/dev/null || ! [ -s '$MARKS' ]"
chk "opencode end removes the registry row" "! grep -q 'opencode' '$REG' 2>/dev/null || ! [ -s '$REG' ]"
kill "$OC" 2>/dev/null

echo
echo "### #11 HIGH: generic agent events fail closed before state mutation"
"$N" clear-all
rm -f "$REG" "$MARKS"
assert_agent_event_rejected() {
  local name="$1" kind="$2" event="$3" payload="$4" rc
  rm -f "$REG" "$MARKS"
  rc=0
  printf '%s' "$payload" | "$N" agent-event "$kind" "$event" >/dev/null 2>"$T/agent-event.err"
  rc=$?
  chk "$name returns usage/data error" "[ '$rc' -eq 2 ]"
  chk "$name leaves registry untouched" "[ ! -s '$REG' ]"
  chk "$name leaves marks untouched" "[ ! -s '$MARKS' ]"
}

assert_agent_event_rejected "malformed JSON" demo approval '{'
assert_agent_event_rejected "two newline-delimited JSON objects" demo approval \
  '{"session_id":"first","pane":"%1","pid":1,"process":"demo"}
{"session_id":"second","pane":"%1","pid":1,"process":"demo"}'
assert_agent_event_rejected "two concatenated JSON objects" demo approval \
  '{"session_id":"first","pane":"%1","pid":1,"process":"demo"}{"session_id":"second","pane":"%1","pid":1,"process":"demo"}'
assert_agent_event_rejected "JSON object followed by junk" demo approval \
  '{"session_id":"first","pane":"%1","pid":1,"process":"demo"} trailing'
assert_agent_event_rejected "JSON array" demo approval '[]'
assert_agent_event_rejected "JSON scalar" demo approval '"one"'
assert_agent_event_rejected "missing session id" demo approval \
  '{"pane":"%1","pid":1,"process":"demo"}'
assert_agent_event_rejected "unknown normalized event" demo mystery \
  '{"session_id":"bad-event","pane":"%1","pid":1,"process":"demo"}'
assert_agent_event_rejected "invalid pane id" demo approval \
  '{"session_id":"bad-pane","pane":"1","pid":1,"process":"demo"}'
assert_agent_event_rejected "invalid pid" demo approval \
  '{"session_id":"bad-pid","pane":"%1","pid":"abc","process":"demo"}'
assert_agent_event_rejected "invalid agent kind" '../demo' approval \
  '{"session_id":"bad-kind","pane":"%1","pid":1,"process":"demo"}'

sleep 30 & AGENT_LOCK_HOLDER=$!
mkdir -p "$LOCK"; printf '%s' "$AGENT_LOCK_HOLDER" > "$LOCK/pid"
AGENT_LOCK_RC=0
printf '%s' '{"session_id":"locked","pane":"%1","pid":1,"process":"demo"}' |
  "$N" agent-event demo approval >/dev/null 2>"$T/agent-event-lock.err" ||
  AGENT_LOCK_RC=$?
chk "generic event lock exhaustion spools instead of dropping" \
  "[ '$AGENT_LOCK_RC' -eq 0 ] && grep -q '^agent	demo	approval	' '$SPOOL'"
chk "generic event lock failure leaves registry and marks untouched" \
  "[ ! -s '$REG' ] && [ ! -s '$MARKS' ]"
kill "$AGENT_LOCK_HOLDER" 2>/dev/null
wait "$AGENT_LOCK_HOLDER" 2>/dev/null
rm -rf "$LOCK"
rm -f "$SPOOL" "$TMUX_RADAR_STATE_DIR/.drain-at"   # do not replay into later cases

KIMI_UNKNOWN_RC=0
printf '%s' '{"hook_event_name":"Unknown","session_id":"kimi-unknown","cwd":"/tmp"}' |
  "$N" kimi-hook >/dev/null 2>"$T/kimi-hook.err"
KIMI_UNKNOWN_RC=$?
chk "unknown Kimi hook event fails open instead of blocking the agent" \
  "[ '$KIMI_UNKNOWN_RC' -ne 0 ] && [ '$KIMI_UNKNOWN_RC' -ne 2 ]"
chk "unknown Kimi hook event leaves state untouched" "[ ! -s '$REG' ] && [ ! -s '$MARKS' ]"

KIMI_INVALID_RC=0
printf '%s' '{"hook_event_name":"Stop","cwd":"/tmp"}' |
  "$N" kimi-hook >/dev/null 2>"$T/kimi-hook-invalid.err"
KIMI_INVALID_RC=$?
chk "invalid Kimi Stop payload cannot block turn completion" \
  "[ '$KIMI_INVALID_RC' -ne 0 ] && [ '$KIMI_INVALID_RC' -ne 2 ]"
chk "invalid Kimi Stop payload leaves state untouched" "[ ! -s '$REG' ] && [ ! -s '$MARKS' ]"

echo
echo "### #12 HIGH: custom vendor adapters fail open on validation/notifier errors"
ADAPTER="$WT/examples/hooks/custom-agent-adapter.sh"
cat > "$T/adapter-notify" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$ADAPTER_ARGS"
cat > "$ADAPTER_PAYLOAD"
exit "${ADAPTER_NOTIFY_RC:-0}"
EOF
chmod +x "$T/adapter-notify"
ADAPTER_ARGS="$T/adapter.args" ADAPTER_PAYLOAD="$T/adapter.payload" \
  TMUX_RADAR_NOTIFY="$T/adapter-notify" TMUX_RADAR_AGENT_KIND=demo \
  "$ADAPTER" <<'EOF'
{"event":"VENDOR_PERMISSION_REQUEST","session_id":"vendor-1","cwd":"/tmp","pane":"%1","pid":1,"process":"demo","message":"approve"}
EOF
chk "custom adapter forwards the normalized event" \
  "grep -qx 'agent-event demo approval' '$T/adapter.args'"
chk "custom adapter forwards one normalized payload" \
  "jq -e '.session_id == \"vendor-1\" and .label == \"approve\"' '$T/adapter.payload' >/dev/null"

ADAPTER_NOTIFY_FAILURE_RC=0
ADAPTER_ARGS="$T/adapter-fail.args" ADAPTER_PAYLOAD="$T/adapter-fail.payload" \
  ADAPTER_NOTIFY_RC=2 TMUX_RADAR_NOTIFY="$T/adapter-notify" \
  "$ADAPTER" <<'EOF' >/dev/null 2>"$T/adapter-fail.err"
{"event":"VENDOR_PERMISSION_REQUEST","session_id":"vendor-2"}
EOF
ADAPTER_NOTIFY_FAILURE_RC=$?
chk "custom adapter translates notifier validation errors to fail-open" \
  "[ '$ADAPTER_NOTIFY_FAILURE_RC' -ne 0 ] && [ '$ADAPTER_NOTIFY_FAILURE_RC' -ne 2 ]"

ADAPTER_UNKNOWN_RC=0
TMUX_RADAR_NOTIFY="$T/adapter-notify" "$ADAPTER" <<'EOF' >/dev/null 2>"$T/adapter-unknown.err"
{"event":"VENDOR_UNKNOWN","session_id":"vendor-3"}
EOF
ADAPTER_UNKNOWN_RC=$?
chk "custom adapter unknown events cannot block the vendor" \
  "[ '$ADAPTER_UNKNOWN_RC' -ne 0 ] && [ '$ADAPTER_UNKNOWN_RC' -ne 2 ]"

ADAPTER_MALFORMED_RC=0
TMUX_RADAR_NOTIFY="$T/adapter-notify" "$ADAPTER" <<'EOF' >/dev/null 2>"$T/adapter-malformed.err"
{
EOF
ADAPTER_MALFORMED_RC=$?
chk "custom adapter malformed payloads cannot block the vendor" \
  "[ '$ADAPTER_MALFORMED_RC' -ne 0 ] && [ '$ADAPTER_MALFORMED_RC' -ne 2 ]"

tmux -L radarreg kill-server 2>/dev/null || true

tmux -L radarreg kill-server 2>/dev/null || true

tmux -L radarreg kill-server 2>/dev/null || true

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

#!/usr/bin/env bash
# Regression tests for the 4 fix-first review findings. Isolated tmux server.
# shellcheck disable=SC2034
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$WT/scripts/needinput-notify.sh"
AI="$WT/scripts/ai.sh"
T="$(mktemp -d /tmp/radar-regress.XXXXXX)"
export TMUX_RADAR_STATE_DIR="$T/state"
MARKS="$TMUX_RADAR_STATE_DIR/need-input"
REG="$TMUX_RADAR_STATE_DIR/agent-registry"
LOCK="$TMUX_RADAR_STATE_DIR/.need-input.lock"

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

echo "### #1 CRITICAL: cmd_ask ';'-chain allowlist bypass"
rm -f /tmp/PWNED_BY_ASK
# stub brain reads its JSON from a file: printf would eat the \" escapes
cat > "$T/evil.json" <<'JSON'
{"explain":"x","commands":["split-window -d ; run-shell \"touch /tmp/PWNED_BY_ASK\""]}
JSON
cat > "$T/clean.json" <<'JSON'
{"explain":"x","commands":["# a comment","split-window -d"]}
JSON
cat > "$T/shell-arg.json" <<'JSON'
{"explain":"x","commands":["split-window -d touch /tmp/PWNED_BY_ASK"]}
JSON
export TMUX_RADAR_AI_PAUSE=1
tmux set -g @radar-ai-autonomy auto     # worst case: no confirmation gate
export TMUX_RADAR_AI_CMD="cat >/dev/null; cat '$T/evil.json'"
OUT="$(TMUX_PANE="$PANE" bash "$AI" ask "make a split" 2>&1)"; RC=$?
sleep 0.5
chk "';'-chained run-shell is rejected (rc=4)" "[ $RC -eq 4 ]"
chk "';'-chain never executed (no PWNED file)" "[ ! -f /tmp/PWNED_BY_ASK ]"
chk "rejection names the chain reason" "printf '%s' \"\$OUT\" | grep -q '链式'"
# An allowed tmux verb can itself accept a shell command. Reject that positional
# argument even when it contains no separator or shell metacharacter.
export TMUX_RADAR_AI_CMD="cat >/dev/null; cat '$T/shell-arg.json'"
OUT_SHELL="$(TMUX_PANE="$PANE" bash "$AI" ask "make a split" 2>&1)"; RC_SHELL=$?
sleep 0.2
chk "split-window positional shell command is rejected" "[ $RC_SHELL -eq 4 ]"
chk "split-window shell argument never executed" "[ ! -f /tmp/PWNED_BY_ASK ]"
# a clean layout batch still passes the allowlist (no false rejection)
export TMUX_RADAR_AI_CMD="cat >/dev/null; cat '$T/clean.json'"
OUT2="$(TMUX_PANE="$PANE" bash "$AI" ask "split" 2>&1)"; RC2=$?
chk "clean layout batch + comment line still executes (rc=0)" "[ $RC2 -eq 0 ]"
chk "the split really happened" "[ \$(tmux list-panes -t '$PANE' | wc -l | tr -d ' ') -ge 2 ]"
# empty command list must not spew "[: integer expression expected"
printf '{"explain":"nothing to do","commands":[]}' > "$T/empty.json"
export TMUX_RADAR_AI_CMD="cat >/dev/null; cat '$T/empty.json'"
OUT3="$(TMUX_PANE="$PANE" bash "$AI" ask "nothing" 2>&1)"; RC3=$?
chk "empty command list exits 0 cleanly (no integer-expression error)" \
  "[ $RC3 -eq 0 ] && ! printf '%s' \"\$OUT3\" | grep -q 'integer expression'"
unset TMUX_RADAR_AI_CMD TMUX_RADAR_AI_PAUSE

echo
echo "### #2 HIGH: cleanup must not kill a user pane whose %id matches a stale watch file"
USERPANE="$(tmux list-panes -a -F '#{pane_id}' | tail -1)"   # a real, non-monitor pane
WD="$TMUX_RADAR_STATE_DIR/ai-watch"; mkdir -p "$WD"
# stale watch file: dead pid, monitors= pointing at the user's live pane (id reuse after restart)
printf 'pid=999999\npane=%%99\nstarted=1\nmonitors=%s\n' "$USERPANE" > "$WD/_99.watch"
bash "$AI" cleanup >/dev/null 2>&1
chk "user pane with reused %id SURVIVES cleanup" \
  "tmux list-panes -a -F '#{pane_id}' | grep -qx '$USERPANE'"
chk "stale watch file was still GCd" "[ ! -f '$WD/_99.watch' ]"

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
"$N" mark - tool "must not race" k:lock-race >/dev/null 2>&1
"$N" tick >/dev/null 2>&1
chk "live holder's lock NOT rmdir'd by a give-up path" "[ -d '$LOCK' ] && [ \"\$(cat '$LOCK/pid')\" = '$HOLDER' ]"
chk "lock timeout never falls through to an unlocked write" "! grep -q 'k:lock-race' '$MARKS' 2>/dev/null"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null; rm -rf "$LOCK"
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
chk "DONE_RE includes bare 'done' (matches switcher level_for)" \
  "grep -q \"DONE_RE='(finished|your turn|turn complete|task complete|done|\" '$N'"
sleep 30 & OC=$!
printf '{"event":"start","session_id":"realsid","pane":"%s","pid":%s,"cwd":"/tmp/oc"}' "$PANE" "$OC" | "$N" opencode-hook
printf '{"event":"permission","session_id":"realsid","pane":"%s","pid":%s,"cwd":"/tmp/oc","message":"y?"}' "$PANE" "$OC" | "$N" opencode-hook
chk "opencode uses ONE session key across lifecycle events" \
  "[ \$(awk -F'\t' '\$1==\"opencode\" && \$2==\"oc:s:realsid\"' '$REG' | wc -l | tr -d ' ') -eq 1 ]"
printf '{"event":"end","session_id":"realsid","pane":"%s","pid":%s,"cwd":"/tmp/oc"}' "$PANE" "$OC" | "$N" opencode-hook
chk "opencode end clears the permission mark it set" "! grep -q 'needs approval' '$MARKS' 2>/dev/null || ! [ -s '$MARKS' ]"
chk "opencode end removes the registry row" "! grep -q 'opencode' '$REG' 2>/dev/null || ! [ -s '$REG' ]"
kill "$OC" 2>/dev/null

tmux -L radarreg kill-server 2>/dev/null || true
rm -f /tmp/PWNED_BY_ASK
echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

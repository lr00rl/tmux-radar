#!/usr/bin/env bash
# Smoke tests for tmux-radar precise AI tracking, on an isolated tmux server
# (-L radartest) + isolated state dir. Never touches the user's live server.
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$WT/scripts/needinput-notify.sh"
SW="$WT/scripts/switcher.sh"
T="$(mktemp -d /tmp/radar-smoke.XXXXXX)"
export TMUX_RADAR_STATE_DIR="$T/state"
MARKS="$TMUX_RADAR_STATE_DIR/need-input"
REG="$TMUX_RADAR_STATE_DIR/agent-registry"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi; }

tmux -L radartest -f /dev/null kill-server 2>/dev/null || true
tmux -L radartest -f /dev/null new-session -d -s smoke 2>/dev/null
SOCK="$(tmux -L radartest display-message -p '#{socket_path}')"
export TMUX="$SOCK,99999,0"
unset TMUX_PANE CLAUDE_JOB_DIR 2>/dev/null || true
PANE="$(tmux list-panes -a -F '#{pane_id}' | head -1)"
echo "test server pane: $PANE  state: $TMUX_RADAR_STATE_DIR"
tmux set -g status off   # baseline for the exact-restore test

# --- 1. registry: register/alive/crash-GC (pid+argv identity) --------------
sleep 300 & SLEEP_PID=$!
"$N" agent-register sleep s:live1 "$SLEEP_PID" "$PANE" /tmp/proj
chk "register writes a 9-field row" \
  "awk -F'\t' 'NF==9 && \$2==\"s:live1\" && \$1==\"sleep\"' '$REG' | grep -q ."
env -u CLAUDE_JOB_DIR "$N" mark "$PANE" claude "Claude needs your permission" s:live1
"$N" tick
chk "action mark with LIVE registry row survives tick" \
  "grep -q 's:live1' '$MARKS'"
kill "$SLEEP_PID" 2>/dev/null; wait "$SLEEP_PID" 2>/dev/null
"$N" tick
chk "crash: dead pid drops registry row" "! grep -q 's:live1' '$REG'"
chk "crash: dead session's action mark dropped" "! grep -q 's:live1' '$MARKS' 2>/dev/null || ! [ -s '$MARKS' ]"

# --- 2. pid-reuse defence: recorded proc must still match argv -------------
sleep 300 & S2=$!
"$N" agent-register claude s:reuse "$S2" "$PANE" ""     # proc recorded as "claude", argv is "sleep"
"$N" tick
chk "pid alive but argv!=proc counts as dead (no fake liveness)" "! grep -q 's:reuse' '$REG'"
kill "$S2" 2>/dev/null

# --- 3. SessionEnd selective clear ------------------------------------------
env -u CLAUDE_JOB_DIR "$N" mark "$PANE" claude "Claude needs your permission" s:end1
printf '{"session_id":"end1"}' | "$N" claude-end
chk "SessionEnd clears action mark instantly" "! grep -q 's:end1' '$MARKS'"
env -u CLAUDE_JOB_DIR "$N" mark "$PANE" claude "Claude finished — your turn" s:end2
printf '{"session_id":"end2"}' | "$N" claude-end
chk "SessionEnd keeps finished-your-turn mark" "grep -q 's:end2' '$MARKS'"
"$N" clear-key s:end2

# --- 4. THE user bug: paneless zombie action mark, no liveness source -------
"$N" mark - claude "Claude·lattice: Claude is waiting for your input" s:zombie
"$N" tick
chk "paneless zombie ACTION mark GCd by tick (the C-i stale bug)" \
  "! grep -q 's:zombie' '$MARKS'"
"$N" mark - claude "Claude·lattice: finished — your turn" s:done-bg
"$N" tick
chk "paneless DONE mark survives tick (announcement semantics)" \
  "grep -q 's:done-bg' '$MARKS'"
"$N" clear-key s:done-bg

# --- 5. claude-register / SessionStart stale-ask cleanup --------------------
env -u CLAUDE_JOB_DIR "$N" mark "$PANE" claude "Claude needs your permission" s:rs1
printf '{"session_id":"rs1","cwd":"/tmp/proj"}' | env -u CLAUDE_JOB_DIR TMUX_PANE="$PANE" "$N" claude-register
chk "SessionStart registers the session" "grep -q 's:rs1' '$REG'"
chk "SessionStart drops the stale action ask" "! grep -q 's:rs1' '$MARKS'"
printf '{"session_id":"rs1"}' | "$N" claude-end
chk "claude-end removes registry row" "! grep -q 's:rs1' '$REG'"

# --- 6. opencode-hook lifecycle ---------------------------------------------
sleep 300 & OC=$!
printf '{"event":"start","session_id":"oc1","pane":"%s","pid":%s,"cwd":"/tmp/oc","message":""}' "$PANE" "$OC" | "$N" opencode-hook
chk "opencode start registers session-keyed (numeric pid parsed)" \
  "awk -F'\t' '\$1==\"opencode\" && \$2==\"oc:s:oc1\" && \$3=='$OC'' '$REG' | grep -q ."
printf '{"event":"permission","session_id":"oc1","pane":"%s","pid":%s,"cwd":"/tmp/oc","message":"run tests"}' "$PANE" "$OC" | "$N" opencode-hook
chk "opencode permission marks the pane" "grep -q 'opencode needs approval: run tests' '$MARKS'"
printf '{"event":"user","session_id":"oc1","pane":"%s","pid":%s,"cwd":"/tmp/oc","message":""}' "$PANE" "$OC" | "$N" opencode-hook
chk "opencode user reply clears the mark" "! grep -q 'needs approval' '$MARKS'"
printf '{"event":"end","session_id":"oc1","pane":"%s","pid":%s,"cwd":"/tmp/oc","message":""}' "$PANE" "$OC" | "$N" opencode-hook
chk "opencode end removes registry row" "! grep -q 'opencode' '$REG' 2>/dev/null || ! [ -s '$REG' ]"
kill "$OC" 2>/dev/null

# Multiple OpenCode sessions may share one TUI pane. Session B must not
# overwrite or clear session A, and old generations/sequences cannot mutate a
# newer replacement session.
"$N" clear-all
oc_event() { printf '%s' "$1" | "$N" opencode-hook; }
oc_event "{\"event\":\"start\",\"session_id\":\"oc-a\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"generation\":\"g-old\",\"generation_started\":100,\"sequence\":1}"
oc_event "{\"event\":\"permission\",\"session_id\":\"oc-a\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"message\":\"bash: go test\",\"generation\":\"g-old\",\"generation_started\":100,\"sequence\":2}"
oc_event "{\"event\":\"start\",\"session_id\":\"oc-b\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"generation\":\"g-old\",\"generation_started\":100,\"sequence\":3}"
oc_event "{\"event\":\"idle\",\"session_id\":\"oc-b\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"generation\":\"g-old\",\"generation_started\":100,\"sequence\":4}"
oc_event "{\"event\":\"end\",\"session_id\":\"oc-b\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"generation\":\"g-old\",\"generation_started\":100,\"sequence\":5}"
chk "session B idle/end does not clear session A action" "grep -q 'oc:s:oc-a.*bash: go test' '$MARKS'"
chk "session B end leaves session A registry row" "grep -q $'opencode\\toc:s:oc-a\\t' '$REG'"

oc_event "{\"event\":\"start\",\"session_id\":\"oc-a\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"generation\":\"g-new\",\"generation_started\":200,\"sequence\":1}"
oc_event "{\"event\":\"permission\",\"session_id\":\"oc-a\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"message\":\"edit: README\",\"generation\":\"g-new\",\"generation_started\":200,\"sequence\":2}"
oc_event "{\"event\":\"end\",\"session_id\":\"oc-a\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"generation\":\"g-old\",\"generation_started\":100,\"sequence\":99}"
chk "old-generation delayed end cannot delete replacement session" "grep -q $'opencode\\toc:s:oc-a\\t' '$REG'"
chk "old-generation delayed end cannot clear replacement mark" "grep -q 'oc:s:oc-a.*edit: README' '$MARKS'"
oc_event "{\"event\":\"user\",\"session_id\":\"oc-a\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"generation\":\"g-new\",\"generation_started\":200,\"sequence\":1}"
chk "out-of-order sequence cannot clear a newer mark" "grep -q 'oc:s:oc-a.*edit: README' '$MARKS'"
oc_event "{\"event\":\"input\",\"session_id\":\"oc-a\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"message\":\"Which target?\",\"generation\":\"g-new\",\"generation_started\":200,\"sequence\":3}"
chk "question input becomes an ACTION mark" "grep -q 'oc:s:oc-a.*Which target' '$MARKS'"
oc_event "{\"event\":\"user\",\"session_id\":\"oc-a\",\"pane\":\"$PANE\",\"pid\":$$,\"cwd\":\"/tmp/oc\",\"generation\":\"g-new\",\"generation_started\":200,\"sequence\":4}"
chk "matching question reply clears only its session mark" "! grep -q 'oc:s:oc-a' '$MARKS'"
"$N" clear-all

# Codex registry and mark keys must be identical so registry liveness remains
# authoritative instead of silently falling back to pane-process heuristics.
printf '{"hook_event_name":"PermissionRequest","thread_id":"codex-key"}' |
  TMUX_PANE="$PANE" "$N" codex-hook
CODEX_REG_KEY="$(awk -F '\t' '$1=="codex" { print $2; exit }' "$REG")"
CODEX_MARK_KEY="$(awk -F '\t' '$3=="codex" { print $4; exit }' "$MARKS")"
chk "codex mark key matches its registry key" \
  "[ '$CODEX_REG_KEY' = 's:codex-key' ] && [ '$CODEX_MARK_KEY' = '$CODEX_REG_KEY' ]"
"$N" clear-all

# --- 7. bar exact-restore (baseline status off) ------------------------------
env -u CLAUDE_JOB_DIR "$N" mark "$PANE" claude "Claude needs your permission" s:bar1
# the marked pane is on-screen (only pane) so bar may not raise; force paneless
"$N" mark - claude "Claude·x: Claude needs your permission" s:bar2
ST="$(tmux show-option -gv status)"
chk "bar raised to 2 while paneless action mark live" "[ '$ST' = '2' ]"
PREV="$(tmux show-option -gqv @radar-prev-status)"
chk "prev status value saved (off)" "[ '$PREV' = 'off' ]"
"$N" clear-all
ST2="$(tmux show-option -gv status)"
chk "clear-all restores the EXACT prior status (off, not on)" "[ '$ST2' = 'off' ]"

tmux set -g status 2
tmux set -gu @radar-prev-status 2>/dev/null || true
"$N" mark - claude "Claude needs your permission" s:bar-two
chk "auto bar preserves a user-owned status 2" \
  "[ \"\$(tmux show-option -gv status)\" = 2 ] && [ -z \"\$(tmux show-option -gqv @radar-prev-status)\" ]"
"$N" clear-all
chk "clear preserves user-owned status 2" "[ \"\$(tmux show-option -gv status)\" = 2 ]"

tmux set -g status 3
"$N" mark - claude "Claude needs your permission" s:bar-three
chk "auto bar never reduces an existing status 3" \
  "[ \"\$(tmux show-option -gv status)\" = 3 ] && [ -z \"\$(tmux show-option -gqv @radar-prev-status)\" ]"
"$N" clear-all
tmux set -g @radar-bar pinned
bash "$WT/tmux-radar.tmux"
chk "pinned bar never reduces an existing status 3" "[ \"\$(tmux show-option -gv status)\" = 3 ]"
tmux set -gu @radar-bar

# --- 8. switcher renders + preview ------------------------------------------
sleep 300 & S3=$!
"$N" agent-register claude s:view "$S3" "$PANE" /tmp/proj 2>/dev/null
# make the registry row point at a live 'sleep' proc for view purposes
awk -F'\t' -v OFS='\t' '{ if ($2=="s:view") $9="sleep"; print }' "$REG" > "$REG.t" && mv "$REG.t" "$REG"
env -u CLAUDE_JOB_DIR "$N" mark "$PANE" claude "Claude needs your permission" s:view
ROWS="$("$SW" list needinput 2>"$T/sw.err")"
chk "switcher AI list emits rows, no stderr" "[ -n \"\$ROWS\" ] && ! [ -s '$T/sw.err' ]"
printf '%s\n' "$ROWS" | head -3
PREV_OUT="$("$SW" preview "$PANE" 2>&1)"
chk "preview shows technical header (sid + pid)" \
  "printf '%s' \"\$PREV_OUT\" | grep -q 'sid s:vi\\|sid view\\|pid'"
printf '%s\n' "$PREV_OUT" | head -4
kill "$S3" 2>/dev/null

# --- 9. doctor runs clean -----------------------------------------------------
"$N" doctor > "$T/doctor.out" 2>"$T/doctor.err"
chk "doctor exits 0 with output, no stderr" "[ -s '$T/doctor.out' ] && ! [ -s '$T/doctor.err' ]"
sed -n '1,12p' "$T/doctor.out"

tmux -L radartest kill-server 2>/dev/null || true
echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

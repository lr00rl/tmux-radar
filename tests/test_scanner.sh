#!/usr/bin/env bash
# Live-scanner tests: hook-free detection, adoption, stall/blocked
# classification, stale-mark healing, foreign-pane re-home, and the picker
# surfaces fed by ai-live. Isolated tmux server; never touches the live one.
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$WT/scripts/needinput-notify.sh"
SW="$WT/scripts/switcher.sh"
T="$(mktemp -d /tmp/radar-scan.XXXXXX)"
export TMUX_RADAR_STATE_DIR="$T/state"
MARKS="$TMUX_RADAR_STATE_DIR/need-input"
REG="$TMUX_RADAR_STATE_DIR/agent-registry"
LIVE="$TMUX_RADAR_STATE_DIR/ai-live"
LIVE_SAMPLES="$TMUX_RADAR_STATE_DIR/.ai-live-samples"
STAMP="$TMUX_RADAR_STATE_DIR/.ai-live-at"
SOCKET="radarscan$$"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$T" 2>/dev/null || true
}
trap cleanup EXIT

tmux -L "$SOCKET" -f /dev/null kill-server 2>/dev/null || true
tmux -L "$SOCKET" -f /dev/null new-session -d -s scan -x 200 -y 50
SOCK="$(tmux -L "$SOCKET" display-message -p '#{socket_path}')"
export TMUX="$SOCK,99999,0"
unset TMUX_PANE CLAUDE_JOB_DIR 2>/dev/null || true
mkdir -p "$TMUX_RADAR_STATE_DIR"

# Two fake "claude" agents. The watcher match works on ps argv0 path
# components, and a #! script's argv0 becomes /bin/sh — so the fakes exec
# their payloads with a synthetic argv0 carrying a "claude" path component.
mkdir -p "$T/bin1" "$T/bin2"
cat > "$T/start-working.sh" <<EOF
#!/usr/bin/env bash
exec -a "$T/bin1/claude" bash -c 'i=0; while :; do i=\$((i+1)); printf "working %s\n" "\$i"; sleep 0.2; done'
EOF
cat > "$T/start-static.sh" <<EOF
#!/usr/bin/env bash
printf 'waiting at a prompt\n'
exec -a "$T/bin2/claude" sleep 600
EOF
chmod +x "$T/start-working.sh" "$T/start-static.sh"

WPANE="$(tmux display-message -p '#{pane_id}')"           # working agent
tmux send-keys -t "$WPANE" "bash $T/start-working.sh" Enter
tmux new-window -n still "bash $T/start-static.sh"        # static agent
SPANE="$(tmux display-message -p '#{pane_id}')"
tmux select-window -t 0

force_scan() { printf '1\n' > "$STAMP"; "$N" tick; }

sleep 1   # let both fake agents start and print

# --- 1. hook-free adoption ---------------------------------------------------
force_scan
chk "scanner adopts a hookless agent pane into ai-live" \
  "awk -F'\t' -v p='$WPANE' '\$1==p' '$LIVE' | grep -q ."
chk "scanner adopts a hookless agent pane into the registry as p:<pid>" \
  "awk -F'\t' -v p='$WPANE' '\$4==p && \$2 ~ /^p:[0-9]+\$/' '$REG' | grep -q ."
WANT_CWD="$(tmux display-message -p -t "$WPANE" '#{pane_current_path}')"
chk "registry adoption records the pane cwd" \
  "awk -F'\t' -v p='$WPANE' -v c='$WANT_CWD' '\$4==p && \$8==c' '$REG' | grep -q ."

# --- 2. working vs stalled classification ------------------------------------
chk "looping agent classified working" \
  "awk -F'\t' -v p='$WPANE' '\$1==p && \$3==\"working\"' '$LIVE' | grep -q ."
chk "static agent first observation is working (no prior sample)" \
  "awk -F'\t' -v p='$SPANE' '\$1==p && \$3==\"working\"' '$LIVE' | grep -q ."
force_scan   # second scan: static pane stops changing
chk "static agent turns stalled on the next scan" \
  "awk -F'\t' -v p='$SPANE' '\$1==p && \$3==\"stalled\"' '$LIVE' | grep -q ."
chk "looping agent stays working across scans" \
  "awk -F'\t' -v p='$WPANE' '\$1==p && \$3==\"working\"' '$LIVE' | grep -q ."

# --- 2.5 transition synthesis: hookless panes still reach the Inbox ------------
# the isolated server is detached, so every pane counts as off-screen here
chk "working to stalled transition synthesizes one DONE mark" \
  "awk -F'\t' -v p='$SPANE' '\$1==p && \$5 ~ /finished.*scan/' '$MARKS' | grep -q ."
chk "synthesized DONE mark appears on the Agents board" \
  "'$SW' list agents | grep -q '$SPANE'"
chk "an agent that keeps working synthesizes nothing" \
  "! awk -F'\t' -v p='$WPANE' '\$1==p' '$MARKS' | grep -q ."

# --- 2.6 node-wrapped agents (pi's real ps shape: argv0=node, program in argv1) ---
# a #!/usr/bin/env node script shows as "node <path>" in ps, exactly like pi
mkdir -p "$T/lib/pi-coding-agent"
printf '#!/usr/bin/env node\nsetInterval(() => {}, 1000)\n' > "$T/lib/pi-coding-agent/cli.js"
chmod +x "$T/lib/pi-coding-agent/cli.js"
tmux new-window -n pifake "$T/lib/pi-coding-agent/cli.js"
PI_PANE="$(tmux display-message -p '#{pane_id}')"
sleep 1
force_scan
chk "node-wrapped agent is detected via argv1 path components" \
  "awk -F'\t' -v p='$PI_PANE' '\$1==p && \$2==\"pi\"' '$LIVE' | grep -q ."
chk "its adopted registry row survives the tick liveness GC" \
  "awk -F'\t' -v p='$PI_PANE' '\$4==p && \$2 ~ /^p:[0-9]+\$/ && \$9==\"pi\"' '$REG' | grep -q ."
tmux kill-window -t "$PI_PANE" 2>/dev/null || true

# --- 3. blocked title beats change detection ---------------------------------
tmux select-pane -t "$SPANE" -T '[ . ] Action Required | proj'
force_scan
chk "animated Action Required title classifies blocked, not working" \
  "awk -F'\t' -v p='$SPANE' '\$1==p && \$3==\"blocked\"' '$LIVE' | grep -q ."
chk "an existing unread mark suppresses the blocked synthesis" \
  "! awk -F'\t' -v p='$SPANE' '\$1==p && \$5 ~ /needs approval/' '$MARKS' | grep -q ."
"$N" clear "$SPANE"   # clear the synthesized DONE; pane still blocked
force_scan            # same state, no transition -> still no new mark
chk "no transition, no second mark" \
  "! awk -F'\t' -v p='$SPANE' '\$1==p' '$MARKS' | grep -q ."
tmux select-pane -t "$SPANE" -T 'plain title'
force_scan   # the retitle itself is one activity signal
force_scan   # settle: no further change -> stalled (synthesizes DONE again)
chk "title back to normal settles to stalled" \
  "awk -F'\t' -v p='$SPANE' '\$1==p && \$3==\"stalled\"' '$LIVE' | grep -q ."
"$N" clear "$SPANE"
tmux select-pane -t "$SPANE" -T '[ ! ] Action Required | proj'
force_scan   # stalled -> blocked with no unread mark: the event fires
chk "blocked transition synthesizes an ACTION mark for a hookless pane" \
  "awk -F'\t' -v p='$SPANE' '\$1==p && \$5 ~ /needs approval.*scan/' '$MARKS' | grep -q ."
force_scan   # still blocked: transition already consumed
chk "a held blocked state does not re-fire" \
  "[ \"\$(awk -F'\t' -v p='$SPANE' '\$1==p' '$MARKS' | wc -l | tr -d ' ')\" = 1 ]"

# --- 4. stale mark healing (post-mark working streak) ---------------------------
# fresh streak: prior scans already proved this pane works; healing needs two
# consecutive working verdicts counted from the mark's own lifetime
rm -f "$LIVE_SAMPLES"
env -u CLAUDE_JOB_DIR "$N" mark "$WPANE" claude "Claude needs your permission" s:heal1
force_scan   # first post-mark working scan: mark must survive
chk "ACTION mark survives the first post-mark working scan" \
  "grep -q 's:heal1' '$MARKS'"
force_scan   # second post-mark working scan: the wait is observably over
chk "sustained working heals the stale ACTION mark" \
  "! grep -q 's:heal1' '$MARKS'"

# DONE marks heal by the same rule when the agent demonstrably works again
env -u CLAUDE_JOB_DIR "$N" mark "$WPANE" claude "Claude finished — your turn" s:heal2
force_scan
chk "DONE mark survives the first post-mark scan" \
  "grep -q 's:heal2' '$MARKS'"
force_scan
chk "renewed working heals the superseded DONE mark" \
  "! grep -q 's:heal2' '$MARKS'"

# A static pane whose title flips once (one activity signal, like a freshly
# rendered permission prompt) must NOT heal: two in a row is the contract.
rm -f "$LIVE_SAMPLES"
tmux select-pane -t "$SPANE" -T 'plain title'
force_scan   # baseline sample for the new title
"$N" clear "$SPANE" 2>/dev/null || true
env -u CLAUDE_JOB_DIR "$N" mark "$SPANE" claude "Claude needs your permission" s:prompt1
tmux select-pane -t "$SPANE" -T '[ . ] Action Required | proj'   # the prompt renders
force_scan   # one screen change since the mark: working verdict, no heal
chk "a freshly rendered prompt does not heal after one changed scan" \
  "grep -q 's:prompt1' '$MARKS'"
force_scan   # unchanged ever since: stalled, streak resets
force_scan
chk "a held permission prompt never heals" \
  "grep -q 's:prompt1' '$MARKS'"
"$N" clear "$SPANE" 2>/dev/null || true

# --- 4.5 done-ttl expiry --------------------------------------------------------
tmux set -g @radar-done-ttl 60
OLD=$(($(date +%s) - 3700))
printf '%s\t%s\tclaude\ts:old-done\tClaude finished — your turn\t\n' "$WPANE" "$OLD" > "$MARKS"
printf '%s\t%s\tclaude\ts:fresh-done\tClaude finished — your turn\t\n' "$WPANE" "$(date +%s)" >> "$MARKS"
"$N" tick
chk "DONE marks older than @radar-done-ttl expire" \
  "! grep -q 's:old-done' '$MARKS'"
chk "fresh DONE marks survive done-ttl" \
  "grep -q 's:fresh-done' '$MARKS'"
tmux set -gu @radar-done-ttl
"$N" clear-all 2>/dev/null || true

# --- 5. contradicted waiting row downgraded -----------------------------------
WPID="$(tmux display-message -p -t "$WPANE" '#{pane_pid}')"
AGENT_PID="$(pgrep -f "$T/bin1/claude" | head -1)"
printf 'claude\ts:wait1\t%s\t%s\t100\t100\twaiting\t/tmp\tclaude\n' "$AGENT_PID" "$WPANE" >> "$REG"
"$N" tick   # GC keeps the live row; scan downgrades it after streak 2
force_scan
chk "registry waiting contradicted by a working screen becomes working" \
  "awk -F'\t' '\$2==\"s:wait1\" && \$7==\"working\"' '$REG' | grep -q ."

# --- 6. foreign/dead pane re-home ---------------------------------------------
sleep 600 & BG_PID=$!
"$N" agent-register claude s:swarm1 "$BG_PID" "%99999" /tmp/proj 2>/dev/null || true
# recorded proc must match argv for liveness: register writes proc=claude but
# argv is sleep, so align the row with reality for this GC pass
awk -F'\t' -v OFS='\t' '$2=="s:swarm1"{$9="sleep"}1' "$REG" > "$REG.t" && mv "$REG.t" "$REG"
force_scan   # GC keeps the live row; the scan re-homes its dead pane
chk "dead-pane row with a live pid is re-homed to paneless, not dropped" \
  "awk -F'\t' '\$2==\"s:swarm1\" && \$4==\"-\"' '$REG' | grep -q ."
kill "$BG_PID" 2>/dev/null

# --- 6.5 mis-homed rows: pid coherent with a foreign tty, not the named pane ---
FSOCK="radarforeign$$"
tmux -L "$FSOCK" -f /dev/null kill-server 2>/dev/null || true
tmux -L "$FSOCK" -f /dev/null new-session -d -s elsewhere 'sleep 601'
# the pane_pid is the sleep itself (sh -c execs it); pgrep -f would match the
# harness's own command line, which merely mentions the pattern
FPID="$(tmux -L "$FSOCK" display-message -p -t elsewhere:0.0 '#{pane_pid}')"
tmux new-window -n plain                       # a pane with no agent at all
PLAIN_PANE="$(tmux display-message -p '#{pane_id}')"
tmux select-window -t 0
"$N" agent-register claude s:misplaced "$FPID" "$PLAIN_PANE" /tmp/proj 2>/dev/null || true
awk -F'\t' -v OFS='\t' '$2=="s:misplaced"{$9="sleep"}1' "$REG" > "$REG.t" && mv "$REG.t" "$REG"
env -u CLAUDE_JOB_DIR "$N" mark "$PLAIN_PANE" claude "Claude finished — your turn" s:misplaced
force_scan
chk "row whose pid lives on a foreign tmux server is re-homed to paneless" \
  "awk -F'\t' '\$2==\"s:misplaced\" && \$4==\"-\"' '$REG' | grep -q ."
chk "its wrong-pane mark is dropped in the same scan" \
  "! grep -q 's:misplaced' '$MARKS'"
tmux kill-window -t "$PLAIN_PANE" 2>/dev/null || true
tmux -L "$FSOCK" kill-server 2>/dev/null || true

# --- 7. picker surfaces ---------------------------------------------------------
AGENTS="$("$SW" list agents)"
chk "Agents view lists the scanner-adopted working pane" \
  "printf '%s' \"$AGENTS\" | grep -q '$WPANE'"
chk "Agents view hides idle panes" \
  "! printf '%s' \"$AGENTS\" | grep -q 'IDLE'"
BLPOS="$(printf '%s' "$AGENTS" | grep -nE 'ACTION|BLOCKED' | head -1 | cut -d: -f1)"
WKPOS="$(printf '%s' "$AGENTS" | grep -n 'WORKING' | head -1 | cut -d: -f1)"
chk "Agents view ranks needs-you above working" \
  "[ -n '$BLPOS' ] && [ -n '$WKPOS' ] && [ '$BLPOS' -lt '$WKPOS' ]"
RECENT="$("$SW" list recent)"
chk "Recent window rows carry a working badge for agent windows" \
  "printf '%s' \"$RECENT\" | grep -q '◐'"
chk "Recent rows keep the three-field TSV contract with badges present" \
  "printf '%s' \"$RECENT\" | awk -F'\t' 'NF!=3{bad=1} END{exit bad}'"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

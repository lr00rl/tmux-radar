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
unset TMUX_PANE CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_ID 2>/dev/null || true
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

# --- 0. the process matcher, on command lines as ps prints them ---------------
# shellcheck source=../scripts/radar-match.sh
. "$WT/scripts/radar-match.sh"
WATCHED='codex claude opencode kimi pi cursor-agent grok gemini amp droid auggie'
kind_of() {  # prints "<kind>/<name recorded for liveness>"; the kind is empty for no agent
  RADAR_CMD="$1" LC_ALL=C awk -v names="$WATCHED" "$RADAR_MATCH_AWK"'
    BEGIN { n = split(names, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1
            printf "%s/%s", radar_kind(ENVIRON["RADAR_CMD"], "", want), radar_proc(ENVIRON["RADAR_CMD"], radar_kind(ENVIRON["RADAR_CMD"], "", want)) }'
}
chk "a native binary is matched on its own name" \
  "[ \"\$(kind_of 'claude --permission-mode bypassPermissions')\" = 'claude/claude' ]"
chk "a path component of argv0 is enough" \
  "[ \"\$(kind_of '/opt/tools/claude/bin/run --flag')\" = 'claude/run' ]"
chk "a node script is matched on the script path" \
  "[ \"\$(kind_of 'node /opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js')\" = 'pi/pi' ]"
chk "runtime flags ahead of the script are skipped" \
  "[ \"\$(kind_of 'node --no-warnings --max-old-space-size=4096 /x/lib/node_modules/@google/gemini-cli/bundle/gemini.js -p hi')\" = 'gemini/gemini' ]"
chk "Cursor's launcher invoked as cursor-agent" \
  "[ \"\$(kind_of '/Users/u/.local/bin/cursor-agent --use-system-ca /Users/u/.local/share/cursor-agent/versions/2026.09.26/index.js')\" = 'cursor-agent/cursor-agent' ]"
chk "Cursor's launcher invoked as agent is still Cursor" \
  "[ \"\$(kind_of '/Users/u/.local/bin/agent --use-system-ca /Users/u/.local/share/cursor-agent/versions/2026.09.26/index.js')\" = 'cursor-agent/cursor-agent' ]"
chk "some other program called agent is nothing" \
  "[ \"\$(kind_of '/opt/datadog-agent/bin/agent run --cfgpath /etc/datadog' | cut -d/ -f1)\" = '' ]"
chk "a watched name inside an argument of an ordinary program is nothing" \
  "[ \"\$(kind_of 'vim /Users/u/src/claude/notes.md' | cut -d/ -f1)\" = '' ]"
chk "a shell is nothing" "[ \"\$(kind_of '-zsh' | cut -d/ -f1)\" = '' ]"
chk "an empty command line is nothing" "[ \"\$(kind_of '' | cut -d/ -f1)\" = '' ]"

# Who fired an event, and from inside which agent. Trees are given as ps would
# print them: pid, ppid, etime, command. The hook process is always pid 900.
firing() {  # firing <kind> <ps rows>
  printf '%s\n' "$2" | LC_ALL=C awk -v names="$WATCHED" -v kind="$1" "$RADAR_MATCH_AWK"'
    BEGIN { n = split(names, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
    NF >= 4 {
      row = $0; sub(/^[[:space:]]+/, "", row)
      pid = row; sub(/[[:space:]].*/, "", pid); sub(/^[^[:space:]]+[[:space:]]+/, "", row)
      ppid = row; sub(/[[:space:]].*/, "", ppid); sub(/^[^[:space:]]+[[:space:]]+/, "", row)
      et = row; sub(/[[:space:]].*/, "", et); sub(/^[^[:space:]]+[[:space:]]+/, "", row)
      par[pid] = ppid; age[pid] = radar_elapsed(et); cmd[pid] = row
    }
    END { out = radar_firing("900", kind, want); gsub(/\t/, " ", out); print out }'
}
chk "an agent started from a pane shell fired for itself" \
  "[ \"\$(firing claude '900 500 00:01 bash needinput-notify.sh claude-stop
500 400 02:10:00 claude --permission-mode default
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux')\" = '500 claude 0 claude' ]"
chk "a claude -p run inside another agent's tool call is nested" \
  "[ \"\$(firing claude '900 800 00:01 bash needinput-notify.sh claude-stop
800 700 00:09 claude -p say-ok
700 500 00:10 /bin/zsh -c source snapshot.sh && claude -p say-ok
500 400 02:10:00 claude --permission-mode default
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux')\" = '800 claude 1 claude' ]"
chk "a codex launcher and the binary it spawned are one agent" \
  "[ \"\$(firing codex '900 600 00:01 bash needinput-notify.sh codex-hook
600 500 10:00 /x/node_modules/@openai/codex/vendor/aarch64/codex/codex
500 400 10:01 node /x/lib/node_modules/@openai/codex/bin/codex.js
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux')\" = '600 codex 0 codex' ]"
chk "codex exec run by a claude session is nested" \
  "[ \"\$(firing codex '900 800 00:01 bash needinput-notify.sh codex-hook
800 750 00:20 /x/node_modules/@openai/codex/vendor/aarch64/codex/codex exec fix-it
750 700 00:21 node /x/lib/node_modules/@openai/codex/bin/codex.js exec fix-it
700 500 00:21 /bin/zsh -c codex exec fix-it; echo done
500 400 02:10:00 claude
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux')\" = '800 codex 1 codex' ]"
chk "the same CLI run through an exec-ing shell is nested, not a launcher" \
  "[ \"\$(firing codex '900 800 00:01 bash needinput-notify.sh codex-hook
800 750 00:20 /x/node_modules/@openai/codex/vendor/aarch64/codex/codex exec fix-it
750 600 00:21 node /x/lib/node_modules/@openai/codex/bin/codex.js exec fix-it
600 500 45:00 /x/node_modules/@openai/codex/vendor/aarch64/codex/codex
500 400 45:01 node /x/lib/node_modules/@openai/codex/bin/codex.js
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux')\" = '800 codex 1 codex' ]"
chk "an SDK-run claude session under a claude host is nested" \
  "[ \"\$(firing claude '900 800 00:01 bash needinput-notify.sh claude-stop
800 700 00:30 node /x/node_modules/@anthropic-ai/claude-code/cli.js --output-format stream-json
700 650 00:31 python run_people.py
650 500 00:31 /bin/zsh -c python run_people.py
500 400 02:10:00 claude --permission-mode bypassPermissions
400 300 03:00:00 -zsh')\" = '800 claude 1 claude' ]"
# asked for nobody in particular: a hook radar installed for Claude may be
# fired by another agent that runs Claude's hooks
chk "Grok running Claude's hooks inside a Claude session is Grok, nested" \
  "[ \"\$(firing '' '900 800 00:01 bash needinput-notify.sh claude-stop
800 700 00:07 grok -p say-ok
700 500 00:07 /bin/zsh -c source snapshot.sh && grok -p say-ok
500 400 02:10:00 claude --permission-mode bypassPermissions
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux')\" = '800 grok 1 grok' ]"
chk "Cursor's TUI launched as agent is Cursor, on its own" \
  "[ \"\$(firing '' '900 850 00:01 bash tap.sh
850 800 00:01 /bin/zsh -c builtin export PATH=/usr/bin; snap=1
800 400 00:29 /Users/u/.local/bin/agent --use-system-ca /Users/u/.local/share/cursor-agent/versions/2026.09.26/index.js
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux')\" = '800 cursor-agent 0 cursor-agent' ]"
chk "a launcher of another kind right above is no launcher of this one" \
  "[ \"\$(firing '' '900 800 00:01 bash needinput-notify.sh claude-stop
800 500 00:02 grok -p say-ok
500 400 00:03 claude -p wrap
400 300 03:00:00 -zsh')\" = '800 grok 1 grok' ]"
chk "a hook with no agent above it names nobody" \
  "[ \"\$(firing claude '900 400 00:01 bash needinput-notify.sh claude-stop
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux')\" = '' ]"
chk "elapsed time is read with and without days" \
  "[ \"\$(LC_ALL=C awk \"\$RADAR_MATCH_AWK\"'BEGIN { print radar_elapsed(\"00:09\"), radar_elapsed(\"02:10:00\"), radar_elapsed(\"1-00:00:05\") }')\" = '9 7800 86405' ]"

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

# --- 2.7 a pane whose session reports natively is left to its hooks -------------
# Same working to stalled transition as 2.5, but a hook-claimed Claude session
# owns the pane: its Stop hook is the event, the screen change is not.
tmux new-window -n owned "bash $T/start-static.sh"
OPANE="$(tmux display-message -p '#{pane_id}')"
tmux select-window -t 0
sleep 1
force_scan   # first observation: working, adopted as p:<pid>
OPID="$(awk -F'\t' -v p="$OPANE" '$4==p && $2 ~ /^p:/ { print $3; exit }' "$REG")"
printf 'claude\ts:owned1\t%s\t%s\t100\t100\tworking\t/tmp\tclaude\n' "$OPID" "$OPANE" >> "$REG"
force_scan   # unchanged since: stalled
chk "the hook-owned pane made the working to stalled transition" \
  "[ -n '$OPID' ] && awk -F'\t' -v p='$OPANE' '\$1==p && \$3==\"stalled\"' '$LIVE' | grep -q ."
chk "a hook-owned Claude pane gets no synthesized mark" \
  "! awk -F'\t' -v p='$OPANE' '\$1==p' '$MARKS' | grep -q ."
tmux kill-window -t "$OPANE" 2>/dev/null || true

# pi reports finished turns but has no approval event, so its panes keep the
# scanner floor; the mark carries the session key so pi's own events clear it
tmux new-window -n piowned "$T/lib/pi-coding-agent/cli.js"
PO_PANE="$(tmux display-message -p '#{pane_id}')"
tmux select-window -t 0
sleep 1
force_scan
PO_PID="$(awk -F'\t' -v p="$PO_PANE" '$4==p && $2 ~ /^p:/ { print $3; exit }' "$REG")"
printf 'pi\ts:pi-owned\t%s\t%s\t100\t100\tworking\t/tmp\tpi\n' "$PO_PID" "$PO_PANE" >> "$REG"
force_scan
chk "a hook-owned pi pane still gets the synthesized mark" \
  "[ -n '$PO_PID' ] && awk -F'\t' -v p='$PO_PANE' '\$1==p && \$5 ~ /finished.*scan/' '$MARKS' | grep -q ."
chk "that mark is keyed by the owning session, not the pid" \
  "awk -F'\t' -v p='$PO_PANE' '\$1==p && \$4==\"s:pi-owned\"' '$MARKS' | grep -q ."
tmux kill-window -t "$PO_PANE" 2>/dev/null || true
"$N" tick   # both fixtures are gone: GC their rows before the next section

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
# Cursor's status title, as Cursor CLI 2026.09.28 set it during an approval.
# A marked pane wears its mark's label as title, so clear before retitling.
"$N" clear "$SPANE"
tmux select-pane -t "$SPANE" -T 'plain title'
force_scan; force_scan   # working, then stalled
"$N" clear "$SPANE"
tmux select-pane -t "$SPANE" -T 'Shell Command Touch - 🔐 Waiting for confirmation'
force_scan
chk "Cursor's 'Waiting for confirmation' title is a blocked pane" \
  "awk -F'\t' -v p='$SPANE' '\$1==p && \$3==\"blocked\"' '$LIVE' | grep -q . && awk -F'\t' -v p='$SPANE' '\$1==p && \$5 ~ /needs approval.*scan/' '$MARKS' | grep -q ."

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

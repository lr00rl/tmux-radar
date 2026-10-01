#!/usr/bin/env bash
# One hook adapter reads every agent that speaks Claude's hook dialect. The
# payloads below are the ones Grok Build 1.0.41, the Cursor CLI 2026.09.26 and
# Droid 0.82.0 (its SessionStart) really sent; Gemini and Auggie follow their
# documented schemas, since neither was logged in to run live. The process
# tree each hook sees is scripted through a stand-in ps (see test_nested.sh).
# Isolated tmux server; never touches the live one.
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$WT/scripts/needinput-notify.sh"
T="$(mktemp -d /tmp/radar-dialects.XXXXXX)"
export TMUX_TMPDIR="$T"   # the test servers' sockets go with $T at cleanup
export TMUX_RADAR_STATE_DIR="$T/state" TMUX_RADAR_NO_SCHEDULE=1
MARKS="$TMUX_RADAR_STATE_DIR/need-input"
REG="$TMUX_RADAR_STATE_DIR/agent-registry"
SOCKET="radardialects$$"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk()  { if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi; }

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$T" 2>/dev/null || true
}
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
tmux -L "$SOCKET" -f /dev/null kill-server 2>/dev/null || true
tmux -L "$SOCKET" -f /dev/null new-session -d -s dialects -x 160 -y 40
SOCK="$(tmux -L "$SOCKET" display-message -p '#{socket_path}')"
export TMUX="$SOCK,99999,0"
unset TMUX_PANE CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_ID GROK_SESSION_ID GEMINI_SESSION_ID \
  AUGMENT_CONVERSATION_ID 2>/dev/null || true
mkdir -p "$TMUX_RADAR_STATE_DIR" "$T/bin"
PANE="$(tmux list-panes -a -F '#{pane_id}' | head -1)"

REAL_PS="$(command -v ps)"
cat > "$T/bin/ps" <<EOF
#!/bin/bash
case " \$* " in
  *etime=*)
    me="\$("$REAL_PS" -o ppid= -p "\$PPID" | tr -d ' ')"
    printf '%s\n' "\$RADAR_TREE" | sed "s/^ME /\$me /"
    ;;
  *) exec "$REAL_PS" "\$@" ;;
esac
EOF
chmod +x "$T/bin/ps"
export TMUX_RADAR_TEST_PS_BIN="$T/bin/ps"

tree() {  # tree <command line of the agent in the pane>
  printf 'ME 500 00:01 bash needinput-notify.sh\n500 400 20:00 %s\n400 300 03:00:00 -zsh\n300 1 1-00:00:00 tmux' "$1"
}
GROK="$(tree 'grok')"
CURSOR="$(tree '/Users/u/.local/bin/agent --use-system-ca /Users/u/.local/share/cursor-agent/versions/2026.09.26/index.js')"
GEMINI="$(tree '/x/bin/node --max-old-space-size=8192 /x/bin/gemini')"
DROID="$(tree 'droid')"
AUGGIE="$(tree 'node /x/bin/auggie')"
CLAUDE="$(tree 'claude --permission-mode default')"
GROK_IN_CLAUDE='ME 800 00:01 bash needinput-notify.sh
800 700 00:07 grok -p say-ok
700 500 00:07 /bin/zsh -c source snapshot.sh && grok -p say-ok
500 400 02:10:00 claude --permission-mode bypassPermissions
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
UNKNOWN_IN_CLAUDE='ME 800 00:01 bash needinput-notify.sh
800 700 00:07 /opt/newagent/bin/newagent --print
700 500 00:07 /bin/zsh -c newagent --print
500 400 02:10:00 claude
400 300 03:00:00 -zsh'

hook() {  # hook <tree> <subcommand...>, payload on stdin
  local t="$1"
  shift
  RADAR_TREE="$t" TMUX_PANE="$PANE" "$N" "$@"
}
reset_all() { "$N" clear-all; : > "$REG"; tmux select-pane -t "$PANE" -T 'pane-title'; }
mark_of()   { awk -F '\t' -v k="$1" '$4 == k { print $3 "|" $5 }' "$MARKS" 2>/dev/null; }
reg_of()    { awk -F '\t' -v k="$1" '$2 == k { print $1 "|" $3 "|" $7 "|" $9 }' "$REG" 2>/dev/null; }
title()     { tmux display-message -p -t "$PANE" '#{pane_title}'; }

# --- Grok, through the hooks radar installed for Claude ------------------------
# Grok loads ~/.claude/settings.json. Its payload carries camelCase fields and
# snake_case twins for a few of them.
G='"sessionId":"g1","session_id":"g1","cwd":"/tmp/p","workspaceRoot":"/tmp/p","permissionMode":"default","permission_mode":"default"'
reset_all
printf '{"hookEventName":"session_start","hook_event_name":"SessionStart","source":"new",%s}' "$G" | hook "$GROK" claude-register
chk "a session Grok started is registered as Grok, under Grok's process" \
  "[ \"\$(reg_of s:g1)\" = 'grok|500|working|grok' ]"
printf '{"hookEventName":"notification","hook_event_name":"Notification","notificationType":"permission_prompt","message":"Grok needs your permission to use Bash",%s}' "$G" |
  hook "$GROK" claude-mark
chk "a camelCase notification type is read" "[ \"\$(mark_of s:g1)\" = 'grok|Grok needs approval: Bash' ]"
chk "the pane says who is asking" "[ \"\$(title)\" = '⚠ Grok needs approval: Bash' ]"
printf '{"hookEventName":"notification","hook_event_name":"Notification","notificationType":"idle_prompt","message":"Grok is waiting for your input",%s}' "$G" |
  hook "$GROK" claude-mark
chk "Grok's idle reminder changes nothing either" "[ \"\$(mark_of s:g1)\" = 'grok|Grok needs approval: Bash' ]"
printf '{"hookEventName":"stop","hook_event_name":"Stop","reason":"end_turn","stopHookActive":false,"lastAssistantMessage":"Renamed the module and fixed its imports.","backgroundTasks":[],"sessionCrons":[],%s}' "$G" |
  hook "$GROK" claude-stop
chk "a finished Grok turn carries its camelCase last message" \
  "[ \"\$(mark_of s:g1)\" = 'grok|Grok finished: Renamed the module and fixed its imports.' ]"
chk "and leaves the session done" "[ \"\$(reg_of s:g1)\" = 'grok|500|done|grok' ]"
printf '{"hookEventName":"session_end","hook_event_name":"SessionEnd","reason":"shutdown",%s}' "$G" | hook "$GROK" claude-end
printf '{"hookEventName":"stop","hook_event_name":"Stop","reason":"shutdown","stopHookActive":false,%s}' "$G" | hook "$GROK" claude-stop
chk "the stop Grok sends while shutting down brings nothing back" \
  "[ -z \"\$(mark_of s:g1)\" ] && [ -z \"\$(reg_of s:g1)\" ]"
printf '{"hookEventName":"stop","hook_event_name":"Stop","reason":"end_turn","backgroundTasks":[{"id":"a","type":"subagent","status":"running","description":"d"}],%s}' "$G" |
  hook "$GROK" claude-stop
chk "camelCase background work pauses a Grok turn" \
  "[ -z \"\$(mark_of s:g1)\" ] && [ \"\$(reg_of s:g1)\" = 'grok|500|working|grok' ]"

reset_all
for sub in claude-register claude-clear claude-stop claude-end; do
  printf '{"hookEventName":"x","sessionId":"g2","session_id":"g2","cwd":"/tmp/p","reason":"end_turn"}' | hook "$GROK_IN_CLAUDE" "$sub"
done
chk "grok -p inside a Claude session reports nothing" \
  "[ -z \"\$(mark_of s:g2)\" ] && [ -z \"\$(reg_of s:g2)\" ] && [ \"\$(title)\" = 'pane-title' ]"
printf '{"session_id":"g3","cwd":"/tmp/p","reason":"end_turn"}' |
  RADAR_TREE="$GROK_IN_CLAUDE" TMUX_PANE="$PANE" CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli \
  CLAUDE_CODE_SESSION_ID=host-session "$N" claude-stop
chk "the Claude variables a nested agent inherited do not vouch for it" \
  "[ -z \"\$(mark_of s:g3)\" ] && [ -z \"\$(reg_of s:g3)\" ]"
printf '{"session_id":"g4","cwd":"/tmp/p"}' |
  RADAR_TREE="$GROK" TMUX_PANE="$PANE" CLAUDE_CODE_SESSION_ATTENDED=0 "$N" claude-stop
chk "nor does a stale unattended flag silence an agent that is not Claude" \
  "[ \"\$(mark_of s:g4)\" = 'grok|Grok finished — your turn' ]"
printf '{"session_id":"g5","cwd":"/tmp/p"}' | RADAR_TREE="$GROK" "$N" claude-stop
chk "only Claude has paneless background sessions" "[ -z \"\$(mark_of s:g5)\" ]"

# --- Cursor, hooks in its own config ---------------------------------------------
C='"conversation_id":"c1","session_id":"c1","generation_id":"c1","model":"unknown","cursor_version":"2026.09.26-dd393fe","workspace_roots":["/tmp/work/proj"]'
reset_all
printf '{"is_background_agent":false,"hook_event_name":"sessionStart",%s}' "$C" | hook "$CURSOR" hook cursor-agent
chk "Cursor launched as agent is registered as Cursor" \
  "[ \"\$(reg_of s:c1)\" = 'cursor-agent|500|working|cursor-agent' ]"
chk "its directory comes from workspace_roots" \
  "awk -F'\t' '\$2==\"s:c1\" && \$8==\"/tmp/work/proj\"' '$REG' | grep -q ."
printf '{"status":"completed","loop_count":0,"hook_event_name":"stop",%s}' "$C" | hook "$CURSOR" hook cursor-agent
chk "a completed Cursor stop is a finished turn" \
  "[ \"\$(mark_of s:c1)\" = 'cursor-agent|Cursor finished — your turn' ]"
printf '{"prompt":"next","attachments":[],"hook_event_name":"beforeSubmitPrompt",%s}' "$C" | hook "$CURSOR" hook cursor-agent
chk "beforeSubmitPrompt clears it" \
  "[ -z \"\$(mark_of s:c1)\" ] && [ \"\$(reg_of s:c1)\" = 'cursor-agent|500|working|cursor-agent' ]"
printf '{"status":"completed","hook_event_name":"stop",%s}' "$C" | hook "$CURSOR" hook cursor-agent
printf '{"status":"aborted","hook_event_name":"stop",%s}' "$C" | hook "$CURSOR" hook cursor-agent
chk "an aborted stop is the person's own doing and marks nothing" "[ -z \"\$(mark_of s:c1)\" ]"
printf '{"status":"error","hook_event_name":"stop",%s}' "$C" | hook "$CURSOR" hook cursor-agent
chk "an error stop is a failed turn" "[ \"\$(mark_of s:c1)\" = 'cursor-agent|Cursor turn failed: error' ]"
chk "a failed turn is a notice" "[ \"\$(title)\" = '! Cursor turn failed: error' ]"
printf '{"text":"ok","hook_event_name":"afterAgentResponse",%s}' "$C" | hook "$CURSOR" hook cursor-agent
chk "an event radar has no use for changes nothing and is no error" \
  "[ \"\$(mark_of s:c1)\" = 'cursor-agent|Cursor turn failed: error' ]"
printf '{"reason":"completed","final_status":"completed","hook_event_name":"sessionEnd",%s}' "$C" | hook "$CURSOR" hook cursor-agent
chk "sessionEnd removes the session" "[ -z \"\$(mark_of s:c1)\" ] && [ -z \"\$(reg_of s:c1)\" ]"

# --- Gemini, Droid, Auggie ---------------------------------------------------------
reset_all
printf '{"session_id":"m1","cwd":"/tmp/p","hook_event_name":"BeforeAgent","timestamp":"t"}' | hook "$GEMINI" hook gemini
chk "Gemini's BeforeAgent registers a working session, past its runtime flags" \
  "[ \"\$(reg_of s:m1)\" = 'gemini|500|working|gemini' ]"
printf '{"session_id":"m1","cwd":"/tmp/p","hook_event_name":"Notification","notification_type":"ToolPermission","message":"Allow run_shell_command?","details":{}}' |
  hook "$GEMINI" hook gemini
chk "Gemini's ToolPermission is an approval" \
  "[ \"\$(mark_of s:m1)\" = 'gemini|Gemini needs approval: Allow run_shell_command?' ]"
printf '{"session_id":"m1","cwd":"/tmp/p","hook_event_name":"AfterTool","tool_name":"run_shell_command"}' | hook "$GEMINI" hook-resolved gemini
chk "AfterTool resolves it" "[ -z \"\$(mark_of s:m1)\" ]"
printf '{"session_id":"m1","cwd":"/tmp/p","hook_event_name":"AfterAgent","prompt_response":"Added the retry and its test."}' | hook "$GEMINI" hook gemini
chk "Gemini's AfterAgent is a finished turn with its answer" \
  "[ \"\$(mark_of s:m1)\" = 'gemini|Gemini finished: Added the retry and its test.' ]"

reset_all
# Droid 0.82.0's own SessionStart: Claude's fields with camelCase twins
printf '{"session_id":"d1","transcript_path":"/x/d1.jsonl","cwd":"/tmp/p","permission_mode":"off","hook_event_name":"SessionStart","source":"startup","CLAUDE_ENV_FILE":"/x/droid-env-d1.sh","sessionId":"d1","transcriptPath":"/x/d1.jsonl","permissionMode":"off","hookEventName":"SessionStart"}' |
  hook "$DROID" hook droid
chk "a real Droid SessionStart registers the session" "[ \"\$(reg_of s:d1)\" = 'droid|500|working|droid' ]"
printf '{"session_id":"d1","cwd":"/tmp/p","permission_mode":"default","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Droid needs your permission to use Execute"}' |
  hook "$DROID" hook droid
chk "Droid speaks Claude's schema as it is" "[ \"\$(mark_of s:d1)\" = 'droid|Droid needs approval: Execute' ]"
printf '{"session_id":"d1","cwd":"/tmp/p","hook_event_name":"Stop","stop_hook_active":false,"tool_execution_count":3}' | hook "$DROID" hook droid
chk "a Droid stop without a final text keeps the plain label" \
  "[ \"\$(mark_of s:d1)\" = 'droid|Droid finished — your turn' ]"

reset_all
A='"conversation_id":"a1","workspace_roots":["/tmp/work/aug"]'
printf '{"hook_event_name":"SessionStart",%s}' "$A" | hook "$AUGGIE" hook auggie
chk "Auggie's conversation_id is its session" "[ \"\$(reg_of s:a1)\" = 'auggie|500|working|auggie' ]"
printf '{"hook_event_name":"Stop","agent_stop_cause":"end_turn",%s}' "$A" | hook "$AUGGIE" hook auggie
chk "an Auggie end_turn is a finished turn" "[ \"\$(mark_of s:a1)\" = 'auggie|Auggie finished — your turn' ]"
printf '{"hook_event_name":"Stop","agent_stop_cause":"interrupted",%s}' "$A" | hook "$AUGGIE" hook auggie
chk "an interrupted Auggie turn marks nothing" "[ -z \"\$(mark_of s:a1)\" ]"

# --- an agent radar does not know, speaking through Claude's hooks -------------
reset_all
printf '{"session_id":"host","cwd":"/tmp/p","notification_type":"permission_prompt","message":"Claude needs your permission"}' |
  hook "$CLAUDE" claude-mark
printf '{"session_id":"u1","cwd":"/tmp/p"}' | hook "$UNKNOWN_IN_CLAUDE" hook newagent
chk "a hinted agent the matcher cannot see is nested when any agent stands above" \
  "[ -z \"\$(mark_of s:u1)\" ] && [ -z \"\$(reg_of s:u1)\" ]"
chk "the pane's own session keeps its mark" "[ \"\$(mark_of s:host)\" = 'claude|Claude needs approval' ]"
printf '{"session_id":"host","cwd":"/tmp/p"}' | hook "$CLAUDE" claude-register 2>/dev/null
printf '{"session_id":"host","cwd":"/tmp/p","notification_type":"permission_prompt","message":"Claude needs your permission"}' |
  hook "$CLAUDE" claude-mark
printf '{"sessionId":"host","session_id":"host","hook_event_name":"SessionEnd","reason":"other"}' | hook "$GROK_IN_CLAUDE" claude-end
chk "a nested run's session end leaves a host session with the same id alone" \
  "[ \"\$(mark_of s:host)\" = 'claude|Claude needs approval' ] && [ -n \"\$(reg_of s:host)\" ]"
# Grok loads other agents' hook files. A hook written for one agent and fired
# by another belongs to the agent in the tree, which reports through its own.
reset_all
printf '{"hookEventName":"session_start","hook_event_name":"SessionStart",%s}' "$G" | hook "$GROK" claude-register
printf '{"hookEventName":"notification","hook_event_name":"Notification","notificationType":"permission_prompt","message":"x",%s}' "$G" |
  hook "$GROK" claude-mark
printf '{"hook_event_name":"Stop","reason":"end_turn",%s}' "$G" | hook "$GROK" hook droid
printf '{"hook_event_name":"SessionEnd",%s}' "$G" | hook "$GROK" hook droid
chk "a hook written for another agent and fired by Grok changes nothing, not even at its end" \
  "[ \"\$(mark_of s:g1)\" = 'grok|Grok needs approval: x' ] && [ -n \"\$(reg_of s:g1)\" ]"

# The Cursor desktop app runs ~/.cursor/hooks.json and Claude's hooks too, from
# no pane. Only a Claude hook without a terminal may be placed by its directory.
reset_all
IDE='ME 500 00:01 bash needinput-notify.sh
500 400 00:30 /Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin) --type=utility
400 1 2-00:00:00 /Applications/Cursor.app/Contents/MacOS/Cursor'
HERE="$(tmux display-message -p -t "$PANE" '#{pane_current_path}')"
printf '{"session_id":"i0","cwd":"%s"}' "$HERE" | RADAR_TREE="$IDE" "$N" claude-stop
if [ -n "$(mark_of s:i0)" ]; then
  printf '{"conversation_id":"i1","session_id":"i1","status":"completed","hook_event_name":"stop","cursor_version":"2026.09.26-dd393fe","workspace_roots":["%s"]}' "$HERE" |
    RADAR_TREE="$IDE" "$N" claude-stop
  chk "a Cursor event from no pane is never pinned on a pane that shares its directory" \
    "[ -z \"\$(mark_of s:i1)\" ] && [ -z \"\$(reg_of s:i1)\" ]"
else
  echo "SKIP: this shell has a terminal, which turns the directory guess off for every hook"
fi

printf '{"session_id":"u2","cwd":"/tmp/p"}' | hook "$CLAUDE" hook 'bad kind!' 2>/dev/null
chk "an invalid kind fails without the exit code that blocks an agent" "[ \$? -eq 1 ]"
chk "and writes nothing" "[ -z \"\$(mark_of s:u2)\" ]"

# --- the tool-result hook leaves early for every agent ----------------------------
reset_all
printf '{"session_id":"q1","cwd":"/tmp/p","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Droid needs your permission"}' |
  hook "$DROID" hook droid
printf '{"session_id":"q2","cwd":"/tmp/p","hook_event_name":"AfterTool"}' |
  RADAR_TREE="$GEMINI" TMUX_PANE="$PANE" GEMINI_SESSION_ID=q2 "$N" hook-resolved gemini
chk "a tool result in a session without a mark touches nothing" \
  "[ \"\$(mark_of s:q1)\" = 'droid|Droid needs approval' ] && [ -z \"\$(reg_of s:q2)\" ]"
printf '{"session_id":"q1","cwd":"/tmp/p","hook_event_name":"PostToolUse"}' |
  RADAR_TREE="$GROK" TMUX_PANE="$PANE" GROK_SESSION_ID=q1 CLAUDE_CODE_SESSION_ID=some-host "$N" claude-resolved
chk "an agent's own session variable outranks an inherited Claude one" "[ -z \"\$(mark_of s:q1)\" ]"

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

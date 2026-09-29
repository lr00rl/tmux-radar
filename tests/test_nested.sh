#!/usr/bin/env bash
# A run started from inside another agent's tool call inherits that agent's
# $TMUX_PANE. Every adapter must refuse its events, and must keep accepting the
# events of the agent that really sits in the pane. The process tree each hook
# sees is scripted through a stand-in ps, so the outcome does not depend on
# whether this suite itself runs inside an agent. Isolated tmux server.
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$WT/scripts/needinput-notify.sh"
T="$(mktemp -d /tmp/radar-nested.XXXXXX)"
export TMUX_RADAR_STATE_DIR="$T/state" TMUX_RADAR_NO_SCHEDULE=1
MARKS="$TMUX_RADAR_STATE_DIR/need-input"
REG="$TMUX_RADAR_STATE_DIR/agent-registry"
SOCKET="radarnested$$"

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
tmux -L "$SOCKET" -f /dev/null new-session -d -s nested -x 160 -y 40
SOCK="$(tmux -L "$SOCKET" display-message -p '#{socket_path}')"
export TMUX="$SOCK,99999,0"
unset TMUX_PANE CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_ID 2>/dev/null || true
mkdir -p "$TMUX_RADAR_STATE_DIR" "$T/bin"
PANE="$(tmux list-panes -a -F '#{pane_id}' | head -1)"

# The stand-in answers the one snapshot that asks for etime (the ancestry
# walk) from $RADAR_TREE, with ME replaced by the notifier's own pid: the
# snapshot runs in a command substitution, so that pid is our grandparent.
# Every other question goes to the real ps.
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

ALONE_CLAUDE='ME 500 00:01 bash needinput-notify.sh
500 400 02:10:00 claude --permission-mode default
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
CLAUDE_IN_CLAUDE='ME 800 00:01 bash needinput-notify.sh
800 700 00:09 claude --print say-ok
700 500 00:10 /bin/zsh -c source snapshot.sh && claude --print say-ok
500 400 02:10:00 claude --permission-mode default
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
ALONE_CODEX='ME 600 00:01 bash needinput-notify.sh
600 500 10:00 /x/node_modules/@openai/codex/vendor/aarch64/codex/codex
500 400 10:01 node /x/lib/node_modules/@openai/codex/bin/codex.js
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
CODEX_IN_CLAUDE='ME 800 00:01 bash needinput-notify.sh
800 750 00:20 /x/node_modules/@openai/codex/vendor/aarch64/codex/codex exec fix-it
750 700 00:21 node /x/lib/node_modules/@openai/codex/bin/codex.js exec fix-it
700 500 00:21 /bin/zsh -c codex exec fix-it; echo done
500 400 02:10:00 claude
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
ALONE_KIMI='ME 500 00:01 bash needinput-notify.sh
500 400 20:00 /Users/u/.kimi-code/bin/kimi
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
KIMI_IN_CODEX='ME 800 00:01 bash needinput-notify.sh
800 700 00:05 /Users/u/.kimi-code/bin/kimi --print summarize
700 600 00:05 bash -lc kimi --print summarize | tee out.txt
600 500 10:00 /x/node_modules/@openai/codex/vendor/aarch64/codex/codex
500 400 10:01 node /x/lib/node_modules/@openai/codex/bin/codex.js
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
ALONE_OPENCODE='ME 500 00:01 bash needinput-notify.sh opencode-stream
500 400 20:00 /Users/u/.opencode/bin/opencode
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
OPENCODE_IN_PI='ME 800 00:01 bash needinput-notify.sh opencode-stream
800 700 00:05 /Users/u/.opencode/bin/opencode run tidy-up
700 500 00:05 /bin/bash -c opencode run tidy-up && true
500 400 20:00 node /opt/homebrew/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'
CURSOR_IN_CLAUDE='ME 800 00:01 bash needinput-notify.sh
800 700 00:05 /Users/u/.local/bin/agent --use-system-ca /Users/u/.local/share/cursor-agent/versions/2026.09.26/index.js -p review
700 500 00:05 /bin/zsh -c agent -p review; true
500 400 02:10:00 claude
400 300 03:00:00 -zsh
300 1 1-00:00:00 tmux'

# hook <tree> <subcommand...> with the payload on stdin
hook() {
  local tree="$1"
  shift
  RADAR_TREE="$tree" TMUX_PANE="$PANE" "$N" "$@"
}
reset_all() { "$N" clear-all; : > "$REG"; tmux select-pane -t "$PANE" -T 'host-title'; }
rows_for()  { awk -F '\t' -v k="$1" '$4 == k' "$MARKS" 2>/dev/null | wc -l | tr -d ' '; }
reg_for()   { awk -F '\t' -v k="$1" '$2 == k' "$REG" 2>/dev/null | wc -l | tr -d ' '; }
title()     { tmux display-message -p -t "$PANE" '#{pane_title}'; }

# --- Claude, by the shape of the tree alone (no environment flag set) ---------
reset_all
printf '{"session_id":"host","cwd":"/tmp/p","notification_type":"permission_prompt","message":"Claude needs your permission"}' |
  hook "$ALONE_CLAUDE" claude-mark
chk "the agent sitting in the pane marks it" "[ \"\$(rows_for s:host)\" = 1 ]"
chk "its registry row names the agent process, not the hook" \
  "awk -F'\t' '\$2==\"s:host\" && \$3==500 && \$9==\"claude\"' '$REG' | grep -q ."
for sub in claude-register claude-clear claude-stop claude-end; do
  printf '{"session_id":"inner","cwd":"/tmp/p"}' | hook "$CLAUDE_IN_CLAUDE" "$sub"
done
chk "a nested claude run writes no mark" "[ \"\$(rows_for s:inner)\" = 0 ]"
chk "a nested claude run registers nothing" "[ \"\$(reg_for s:inner)\" = 0 ]"
chk "the host's unread mark survives the nested run" "[ \"\$(rows_for s:host)\" = 1 ]"
chk "the host pane keeps its action title" "[ \"\$(title)\" = '⚠ Claude needs approval' ]"

# --- Codex: native hooks and the legacy notify program ------------------------
reset_all
printf '{"hook_event_name":"Stop","thread_id":"cx-host"}' | hook "$ALONE_CODEX" codex-hook
chk "codex behind its own launcher is one agent and marks the pane" \
  "[ \"\$(rows_for s:cx-host)\" = 1 ]"
chk "its row records the binary, not the launcher" \
  "awk -F'\t' '\$2==\"s:cx-host\" && \$3==600 && \$9==\"codex\"' '$REG' | grep -q ."
printf '{"hook_event_name":"UserPromptSubmit","thread_id":"cx-inner"}' | hook "$CODEX_IN_CLAUDE" codex-hook
chk "a nested codex prompt does not clear the pane's mark" "[ \"\$(rows_for s:cx-host)\" = 1 ]"
printf '{"hook_event_name":"Stop","thread_id":"cx-inner"}' | hook "$CODEX_IN_CLAUDE" codex-hook
chk "codex exec inside another agent writes no mark" "[ \"\$(rows_for s:cx-inner)\" = 0 ]"
chk "codex exec inside another agent registers nothing" "[ \"\$(reg_for s:cx-inner)\" = 0 ]"
hook "$CODEX_IN_CLAUDE" codex '{"type":"agent-turn-complete","thread-id":"cx-notify"}' </dev/null
chk "the legacy notify path refuses a nested run too" \
  "[ \"\$(rows_for s:cx-notify)\" = 0 ] && [ \"\$(reg_for s:cx-notify)\" = 0 ]"
hook "$ALONE_CODEX" codex '{"type":"agent-turn-complete","thread-id":"cx-notify-host"}' </dev/null
chk "the legacy notify path still serves the pane's own agent" \
  "[ \"\$(rows_for s:cx-notify-host)\" = 1 ]"

# codex exec in a plain pane, under no agent at all: Codex itself says it is headless
reset_all
hook "$ALONE_CODEX" codex '{"type":"agent-turn-complete","thread-id":"cx-exec","client":"codex_exec"}' </dev/null
chk "a notify payload from codex exec reports nothing" \
  "[ \"\$(rows_for s:cx-exec)\" = 0 ] && [ \"\$(reg_for s:cx-exec)\" = 0 ]"
hook "$ALONE_CODEX" codex '{"type":"agent-turn-complete","thread-id":"cx-tui","client":"codex-tui"}' </dev/null
chk "a notify payload from the TUI still marks the pane" "[ \"\$(rows_for s:cx-tui)\" = 1 ]"
printf '%s\n%s\n' '{"type":"session_meta","payload":{"id":"x","originator":"codex_exec","source":"exec"}}' '{"type":"event"}' > "$T/rollout-exec.jsonl"
printf '%s\n' '{"type":"session_meta","payload":{"id":"y","originator":"codex-tui","source":"cli"}}' > "$T/rollout-tui.jsonl"
printf '{"hook_event_name":"Stop","session_id":"cx-hook-exec","transcript_path":"%s"}' "$T/rollout-exec.jsonl" | hook "$ALONE_CODEX" codex-hook
chk "a hook whose rollout was originated by codex exec reports nothing" \
  "[ \"\$(rows_for s:cx-hook-exec)\" = 0 ] && [ \"\$(reg_for s:cx-hook-exec)\" = 0 ]"
printf '{"hook_event_name":"Stop","session_id":"cx-hook-tui","transcript_path":"%s"}' "$T/rollout-tui.jsonl" | hook "$ALONE_CODEX" codex-hook
chk "a hook whose rollout the TUI originated marks the pane" "[ \"\$(rows_for s:cx-hook-tui)\" = 1 ]"
printf '{"hook_event_name":"Stop","session_id":"cx-hook-gone","transcript_path":"%s"}' "$T/no-such-file.jsonl" | hook "$ALONE_CODEX" codex-hook
chk "a rollout that cannot be read decides nothing" "[ \"\$(rows_for s:cx-hook-gone)\" = 1 ]"
# the payload names the file; a FIFO there must not hold the hook open
mkfifo "$T/rollout-fifo"
( printf '{"hook_event_name":"Stop","session_id":"cx-hook-fifo","transcript_path":"%s"}' "$T/rollout-fifo" |
    hook "$ALONE_CODEX" codex-hook ) &
FIFO_JOB=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$FIFO_JOB" 2>/dev/null || break; sleep 0.5; done
FIFO_HUNG=0
if kill -0 "$FIFO_JOB" 2>/dev/null; then
  FIFO_HUNG=1
  : > "$T/rollout-fifo" &   # a writer lets a blocked reader see EOF and leave
  wait "$FIFO_JOB" 2>/dev/null
fi
chk "a transcript path that is a FIFO does not hang the hook" \
  "[ $FIFO_HUNG = 0 ] && [ \"\$(rows_for s:cx-hook-fifo)\" = 1 ]"

# --- Kimi and the generic adapter ----------------------------------------------
reset_all
printf '{"hook_event_name":"Stop","session_id":"km-host","cwd":"/tmp/p"}' | hook "$ALONE_KIMI" kimi-hook
chk "kimi in its pane marks a finished turn" "[ \"\$(rows_for s:km-host)\" = 1 ]"
printf '{"hook_event_name":"Stop","session_id":"km-inner","cwd":"/tmp/p"}' | hook "$KIMI_IN_CODEX" kimi-hook
chk "kimi run by a codex session writes nothing" \
  "[ \"\$(rows_for s:km-inner)\" = 0 ] && [ \"\$(reg_for s:km-inner)\" = 0 ]"
printf '{"session_id":"cur-inner","cwd":"/tmp/p"}' | hook "$CURSOR_IN_CLAUDE" agent-event cursor-agent turn_complete
chk "a Cursor run launched as agent inside another agent writes nothing" \
  "[ \"\$(rows_for s:cur-inner)\" = 0 ] && [ \"\$(reg_for s:cur-inner)\" = 0 ]"
printf '{"session_id":"free","cwd":"/tmp/p"}' | hook "$ALONE_CLAUDE" agent-event demo turn_complete
chk "an adapter with no process of its kind above it is served as before" \
  "[ \"\$(rows_for s:free)\" = 1 ]"

# --- OpenCode -------------------------------------------------------------------
reset_all
printf '{"event":"idle","session_id":"oc-host","pane":"%s","pid":500,"cwd":"/tmp/p"}' "$PANE" |
  hook "$ALONE_OPENCODE" opencode-hook
chk "opencode in its pane marks a finished turn" "[ \"\$(rows_for oc:s:oc-host)\" = 1 ]"
printf '{"event":"idle","session_id":"oc-inner","pane":"%s","pid":800,"cwd":"/tmp/p"}' "$PANE" |
  hook "$OPENCODE_IN_PI" opencode-hook
chk "opencode run inside a pi session writes nothing" \
  "[ \"\$(rows_for oc:s:oc-inner)\" = 0 ] && [ \"\$(reg_for oc:s:oc-inner)\" = 0 ]"

# --- a paneless event is none of this rule's business ---------------------------
reset_all
printf '{"session_id":"bg","cwd":"/nonexistent/bgproj"}' |
  RADAR_TREE="$CLAUDE_IN_CLAUDE" CLAUDE_JOB_DIR=/tmp/job "$N" claude-stop
chk "a background job keeps its paneless mark whatever stands above it" \
  "awk -F'\t' '\$1 == \"-\" && \$4 == \"s:bg\"' '$MARKS' | grep -q ."

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

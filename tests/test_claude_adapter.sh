#!/usr/bin/env bash
# Claude adapter tests: the hook payload and environment decide what an event
# means. Covers unattended (headless) runs, typed notifications, paused versus
# finished turns, failed turns, in-place resolution, and the shared severity
# classifier. Isolated tmux server; never touches the live one.
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$WT/scripts/needinput-notify.sh"
T="$(mktemp -d /tmp/radar-claude.XXXXXX)"
export TMUX_TMPDIR="$T"   # the test servers' sockets go with $T at cleanup
export TMUX_RADAR_STATE_DIR="$T/state" TMUX_RADAR_NO_SCHEDULE=1
MARKS="$TMUX_RADAR_STATE_DIR/need-input"
REG="$TMUX_RADAR_STATE_DIR/agent-registry"
SOCKET="radarclaude$$"

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
tmux -L "$SOCKET" -f /dev/null new-session -d -s claude -x 160 -y 40
SOCK="$(tmux -L "$SOCKET" display-message -p '#{socket_path}')"
export TMUX="$SOCK,99999,0"
# the suite may itself run inside an agent: none of its session identity may
# leak into the hooks under test
unset TMUX_PANE CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_ID 2>/dev/null || true
mkdir -p "$TMUX_RADAR_STATE_DIR"
PANE="$(tmux list-panes -a -F '#{pane_id}' | head -1)"
PANE2="$(tmux new-window -d -P -F '#{pane_id}' -n other)"

# claude_hook <subcommand> <json> [VAR=value ...]: one hook delivery on $PANE
claude_hook() {
  local sub="$1" json="$2"
  shift 2
  printf '%s' "$json" | env TMUX_PANE="$PANE" "$@" "$N" "$sub"
}
mark_of()   { awk -F '\t' -v k="$1" '$4 == k { print $5 }' "$MARKS" 2>/dev/null; }
epoch_of()  { awk -F '\t' -v k="$1" '$4 == k { print $2 }' "$MARKS" 2>/dev/null; }
state_of()  { awk -F '\t' -v k="$1" '$2 == k { print $7 }' "$REG" 2>/dev/null; }
title_of()  { tmux display-message -p -t "$1" '#{pane_title}'; }
reset_all() { "$N" clear-all; : > "$REG"; }

# shellcheck source=../scripts/radar-level.sh
. "$WT/scripts/radar-level.sh"

# --- 1. severity comes from the label head, not from words in the detail ------
chk "finished head is done" \
  "[ \"\$(radar_level claude 'Claude finished — your turn')\" = done ]"
chk "finished head stays done when the detail mentions approval" \
  "[ \"\$(radar_level claude 'Claude finished: asked for approval earlier')\" = done ]"
chk "approval head stays action when the detail says done" \
  "[ \"\$(radar_level claude 'Claude needs approval: Bash(echo done)')\" = action ]"
chk "input head stays action when the detail says finished" \
  "[ \"\$(radar_level claude 'Claude needs your input: is the migration finished?')\" = action ]"
chk "paneless prefix is skipped before the head is read" \
  "[ \"\$(radar_level claude 'Claude·proj: Claude needs approval: mark it done')\" = action ]"
chk "paneless finished label is done" \
  "[ \"\$(radar_level claude 'Claude·proj: finished — your turn')\" = done ]"
chk "failed turn is a notice" \
  "[ \"\$(radar_level claude 'Claude turn failed: rate_limit')\" = notice ]"
chk "free-form label with no known head falls back to the whole text" \
  "[ \"\$(radar_level tool 'deploy: waiting on approval')\" = action ]"
chk "free-form completion label is done" \
  "[ \"\$(radar_level tool 'build: done')\" = done ]"
chk "unknown label is a notice" \
  "[ \"\$(radar_level tool 'disk almost full')\" = notice ]"
chk "Chinese completion label is done" \
  "[ \"\$(radar_level tool '任务完成')\" = done ]"
chk "a backslash in the label is read literally" \
  "[ \"\$(radar_level claude 'Claude needs approval: C:\\new\\temp')\" = action ]"

# --- 2. unattended runs never claim a pane -------------------------------------
# claude -p / the Agent SDK started from an agent's tool call inherit that
# agent's $TMUX_PANE. Nobody sits at their prompt.
reset_all
tmux select-pane -t "$PANE" -T 'host-agent-title'
claude_hook claude-register '{"session_id":"nested1","cwd":"/tmp/proj"}' \
  CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=sdk-cli
chk "unattended SessionStart registers nothing" "! grep -q 's:nested1' '$REG' 2>/dev/null"
claude_hook claude-stop '{"session_id":"nested1","cwd":"/tmp/proj"}' \
  CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=sdk-cli
chk "unattended Stop writes no mark" "! grep -q 's:nested1' '$MARKS' 2>/dev/null"
chk "unattended Stop registers nothing" "! grep -q 's:nested1' '$REG' 2>/dev/null"
chk "unattended Stop leaves the host pane title alone" \
  "[ \"\$(title_of '$PANE')\" = 'host-agent-title' ]"
claude_hook claude-mark '{"session_id":"nested1","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' \
  CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=sdk-cli
chk "unattended Notification writes no mark" "! grep -q 's:nested1' '$MARKS' 2>/dev/null"
claude_hook claude-stop '{"session_id":"nested2","cwd":"/tmp/proj"}' CLAUDE_CODE_ENTRYPOINT=sdk-py
chk "an sdk entrypoint alone marks the run unattended" \
  "! grep -q 's:nested2' '$MARKS' 2>/dev/null && ! grep -q 's:nested2' '$REG' 2>/dev/null"

# the host session's own unread mark survives a nested run's whole lifecycle
claude_hook claude-mark '{"session_id":"host1","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}' \
  CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli
for sub in claude-register claude-clear claude-stop claude-end; do
  claude_hook "$sub" '{"session_id":"nested3","cwd":"/tmp/proj"}' \
    CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=sdk-cli
done
chk "a nested run leaves the host session mark in place" \
  "[ \"\$(mark_of s:host1)\" = 'Claude needs approval: Bash' ]"
chk "a nested run leaves the host registry row in place" "[ \"\$(state_of s:host1)\" = waiting ]"

# attended sessions and background jobs keep their behaviour
reset_all
claude_hook claude-stop '{"session_id":"att1","cwd":"/tmp/proj"}' \
  CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_ENTRYPOINT=cli
chk "an attended session still marks its finished turn" "[ -n \"\$(mark_of s:att1)\" ]"
claude_hook claude-stop '{"session_id":"job1","cwd":"/nonexistent/bgproj"}' \
  CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_JOB_DIR=/tmp/job1
chk "a background job keeps its paneless mark" \
  "awk -F'\t' '\$1 == \"-\" && \$4 == \"s:job1\" && \$5 ~ /^Claude·bgproj: finished/' '$MARKS' | grep -q ."
claude_hook claude-stop '{"session_id":"job2","cwd":"/tmp/proj"}' \
  CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_SESSION_KIND=bg
chk "a bg session kind is a supervised job, not an unattended run" "[ -n \"\$(mark_of s:job2)\" ]"

# --- 3. notifications are classified by type -----------------------------------
reset_all
claude_hook claude-mark '{"session_id":"n1","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
chk "permission_prompt becomes an approval mark naming the tool" \
  "[ \"\$(mark_of s:n1)\" = 'Claude needs approval: Bash' ]"
chk "permission_prompt sets the registry to waiting" "[ \"\$(state_of s:n1)\" = waiting ]"
chk "permission_prompt retitles the pane as action" \
  "[ \"\$(title_of '$PANE')\" = '⚠ Claude needs approval: Bash' ]"
# Claude Code 2.1.283 sends the bare sentence, with no tool in it
claude_hook claude-mark '{"session_id":"n1b","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission"}'
chk "a permission message that names no tool adds no detail" \
  "[ \"\$(mark_of s:n1b)\" = 'Claude needs approval' ]"
claude_hook claude-mark '{"session_id":"n1c","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Approve the deploy step"}'
chk "an unfamiliar permission message is kept as the detail" \
  "[ \"\$(mark_of s:n1c)\" = 'Claude needs approval: Approve the deploy step' ]"

claude_hook claude-mark '{"session_id":"n1","cwd":"/tmp/proj","notification_type":"elicitation_dialog","message":"Is the migration done?"}'
chk "elicitation_dialog becomes an input mark" \
  "[ \"\$(mark_of s:n1)\" = 'Claude needs your input: Is the migration done?' ]"
chk "an input mark whose detail says done is still action" \
  "[ \"\$(title_of '$PANE')\" = '⚠ Claude needs your input: Is the migration done?' ]"
claude_hook claude-mark '{"session_id":"n1","cwd":"/tmp/proj","notification_type":"elicitation_response","message":"answered"}'
chk "elicitation_response clears the input mark" "[ -z \"\$(mark_of s:n1)\" ]"
chk "elicitation_response returns the registry to working" "[ \"\$(state_of s:n1)\" = working ]"

# idle_prompt is a reminder about a turn that already ended
reset_all
claude_hook claude-stop '{"session_id":"n2","cwd":"/tmp/proj"}'
DONE_LABEL="$(mark_of s:n2)"; DONE_EPOCH="$(epoch_of s:n2)"
sleep 1
claude_hook claude-mark '{"session_id":"n2","cwd":"/tmp/proj","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
chk "idle_prompt keeps the finished mark as it was" \
  "[ \"\$(mark_of s:n2)\" = '$DONE_LABEL' ] && [ \"\$(epoch_of s:n2)\" = '$DONE_EPOCH' ]"
chk "idle_prompt keeps the registry state" "[ \"\$(state_of s:n2)\" = done ]"
reset_all
claude_hook claude-mark '{"session_id":"n3","cwd":"/tmp/proj","notification_type":"idle_prompt","message":"Claude is waiting for your input"}'
chk "idle_prompt alone creates no mark" "[ -z \"\$(mark_of s:n3)\" ]"
claude_hook claude-mark '{"session_id":"n3","cwd":"/tmp/proj","notification_type":"auth_success","message":"Signed in"}'
chk "auth_success creates no mark" "[ -z \"\$(mark_of s:n3)\" ]"

# payloads from before notification_type existed, and types not mapped yet
claude_hook claude-mark '{"session_id":"n4","cwd":"/tmp/proj","message":"Claude needs your permission to use Edit"}'
chk "an untyped notification keeps its message as the label" \
  "[ \"\$(mark_of s:n4)\" = 'Claude needs your permission to use Edit' ]"
claude_hook claude-mark '{"session_id":"n5","cwd":"/tmp/proj","notification_type":"some_future_type","message":"Quota resumed"}'
chk "an unmapped notification type keeps its message as the label" \
  "[ \"\$(mark_of s:n5)\" = 'Quota resumed' ]"

# --- 4. a stop is only a finished turn when nothing will resume the session ----
reset_all
claude_hook claude-stop '{"session_id":"s1","cwd":"/tmp/proj","background_tasks":[],"session_crons":[]}'
chk "a plain stop keeps the finished label" \
  "[ \"\$(mark_of s:s1)\" = 'Claude finished — your turn' ]"
chk "a plain stop sets the registry to done" "[ \"\$(state_of s:s1)\" = done ]"

claude_hook claude-stop "$(jq -cn '{session_id:"s2",cwd:"/tmp/proj",
  last_assistant_message:"## Summary\n\nFixed the flaky auth test and reran the suite.\n\nDetails follow."}')"
chk "the label carries the first sentence line, past any heading" \
  "[ \"\$(mark_of s:s2)\" = 'Claude finished: Fixed the flaky auth test and reran the suite.' ]"
claude_hook claude-stop "$(jq -cn '{session_id:"s3",cwd:"/tmp/proj",
  last_assistant_message:"修复了登录接口的超时问题，并补充了回归测试，全部通过。后续建议把重试次数改成可配置项，避免线上再次出现同样的问题，同时给网关加上熔断，防止下游抖动拖垮整条链路。"}')"
S3_LABEL="$(mark_of s:s3)"
# jq counts code points whatever the locale; ${#var} counts bytes under LC_ALL=C
S3_CHARS="$(printf '%s' "$S3_LABEL" | jq -Rr 'length')"
chk "a long summary is cut on a character boundary" \
  "[ \"\$(printf '%s' '$S3_LABEL' | iconv -f UTF-8 -t UTF-8 2>/dev/null)\" = '$S3_LABEL' ] && [ '$S3_CHARS' -le 80 ] && [ '$S3_CHARS' -gt 40 ]"
chk "a cut summary ends with an ellipsis" "case '$S3_LABEL' in *…) true ;; *) false ;; esac"
claude_hook claude-stop "$(jq -cn '{session_id:"s4",cwd:"/tmp/proj",
  last_assistant_message:"I need your approval before deploying."}')"
chk "a finished turn is done whatever its summary says" \
  "[ \"\$(title_of '$PANE')\" = '✓ Claude finished: I need your approval before deploying.' ]"

reset_all
claude_hook claude-mark '{"session_id":"s5","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
claude_hook claude-stop '{"session_id":"s5","cwd":"/tmp/proj","background_tasks":[{"id":"a1","type":"subagent","status":"running","description":"review"}],"session_crons":[]}'
chk "agent work in flight: no finished mark" "[ -z \"\$(mark_of s:s5)\" ]"
chk "agent work in flight: the registry stays working" "[ \"\$(state_of s:s5)\" = working ]"
claude_hook claude-stop '{"session_id":"s6","cwd":"/tmp/proj","background_tasks":[{"id":"w1","type":"workflow","status":"running","description":"fan out","name":"review"}]}'
chk "a running workflow pauses the session too" "[ -z \"\$(mark_of s:s6)\" ]"
claude_hook claude-stop '{"session_id":"s7","cwd":"/tmp/proj","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"dev server","command":"npm run dev"}]}'
chk "a background shell does not hide a finished turn" "[ -n \"\$(mark_of s:s7)\" ]"

# a scheduled wakeup only pauses a turn the schedule itself started
reset_all
CRON='[{"id":"c1","schedule":"*/30 * * * *","recurring":true,"prompt":"check the deploy"}]'
claude_hook claude-clear '{"session_id":"s8","cwd":"/tmp/proj","source":"loop_wakeup"}'
claude_hook claude-stop "{\"session_id\":\"s8\",\"cwd\":\"/tmp/proj\",\"session_crons\":$CRON}"
chk "a loop iteration with a wakeup pending writes no finished mark" "[ -z \"\$(mark_of s:s8)\" ]"
chk "a loop iteration leaves the registry working" "[ \"\$(state_of s:s8)\" = working ]"
claude_hook claude-clear '{"session_id":"s8","cwd":"/tmp/proj","source":"user"}'
claude_hook claude-stop "{\"session_id\":\"s8\",\"cwd\":\"/tmp/proj\",\"session_crons\":$CRON}"
chk "a turn the user started is finished even while a loop is scheduled" \
  "[ -n \"\$(mark_of s:s8)\" ]"
claude_hook claude-clear '{"session_id":"s9","cwd":"/tmp/proj","source":"schedule_wakeup"}'
claude_hook claude-stop '{"session_id":"s9","cwd":"/tmp/proj","session_crons":[]}'
chk "the last scheduled run, with nothing left to wake it, is finished" \
  "[ -n \"\$(mark_of s:s9)\" ]"
claude_hook claude-clear '{"session_id":"s10","cwd":"/tmp/proj"}'
claude_hook claude-stop "{\"session_id\":\"s10\",\"cwd\":\"/tmp/proj\",\"session_crons\":$CRON}"
chk "a prompt with no source counts as the user's" "[ -n \"\$(mark_of s:s10)\" ]"

# --- 5. a failed turn is said out loud ------------------------------------------
reset_all
claude_hook claude-fail '{"session_id":"f1","cwd":"/tmp/proj","hook_event_name":"StopFailure","error":"rate_limit","error_details":"429"}'
chk "StopFailure writes a failed-turn mark naming the error" \
  "[ \"\$(mark_of s:f1)\" = 'Claude turn failed: rate_limit' ]"
chk "a failed turn is a notice" "[ \"\$(title_of '$PANE')\" = '! Claude turn failed: rate_limit' ]"
chk "a failed turn leaves the session idle" "[ \"\$(state_of s:f1)\" = done ]"
claude_hook claude-fail '{"session_id":"f2","cwd":"/tmp/proj"}' CLAUDE_CODE_SESSION_ATTENDED=0
chk "an unattended failed turn writes nothing" "[ -z \"\$(mark_of s:f2)\" ]"

# no payload field may bloat the state file every tick rewrites
reset_all
# (one pane holds one mark, so each label is checked before the next arrives)
claude_hook claude-fail "$(jq -cn '{session_id:"f3",cwd:"/tmp/proj",error:("x" * 5000)}')"
F3_LEN="$(mark_of s:f3 | jq -Rr 'length')"
chk "an oversized error is cut to the label limit" "[ '${F3_LEN:-0}' -gt 100 ] && [ '${F3_LEN:-0}' -le 200 ]"
claude_hook claude-mark "$(jq -cn '{session_id:"f4",cwd:"/tmp/proj",message:("长" * 5000)}')"
F4_LEN="$(mark_of s:f4 | jq -Rr 'length')"
chk "an oversized multibyte message is cut on a character boundary" \
  "[ '${F4_LEN:-0}' -gt 100 ] && [ '${F4_LEN:-0}' -le 200 ] && mark_of s:f4 | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1"
chk "an oversized label leaves one well-formed row" \
  "[ \"\$(awk -F'\t' 'NF != 6' '$MARKS' | wc -l | tr -d ' ')\" = 0 ] && [ \"\$(wc -l < '$MARKS' | tr -d ' ')\" = 1 ]"

# --- 6. a tool that ran proves the wait is over ---------------------------------
reset_all
chk "with no marks at all the resolver leaves at once" \
  "claude_hook claude-resolved '{\"session_id\":\"r0\",\"cwd\":\"/tmp/proj\",\"tool_name\":\"Bash\"}' && ! [ -s '$REG' ]"
tmux select-pane -t "$PANE" -T 'before-approval'
claude_hook claude-mark '{"session_id":"r1","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
env TMUX_PANE="$PANE2" "$N" mark "$PANE2" claude 'Claude needs approval: Edit' s:r-other
claude_hook claude-resolved '{"session_id":"r1","cwd":"/tmp/proj","tool_name":"Bash","agent_id":"sub-1"}'
chk "a subagent tool call does not resolve the main session" "[ -n \"\$(mark_of s:r1)\" ]"
claude_hook claude-resolved '{"session_id":"r1","cwd":"/tmp/proj","tool_name":"Bash"}' \
  CLAUDE_CODE_SESSION_ATTENDED=0
chk "an unattended tool call resolves nothing" "[ -n \"\$(mark_of s:r1)\" ]"
claude_hook claude-resolved '{"session_id":"r1","cwd":"/tmp/proj","tool_name":"Bash"}'
chk "an approval answered in place clears on the next tool result" "[ -z \"\$(mark_of s:r1)\" ]"
chk "resolution restores the pane title" "[ \"\$(title_of '$PANE')\" = 'before-approval' ]"
chk "resolution returns the registry to working" "[ \"\$(state_of s:r1)\" = working ]"
chk "resolution leaves another session's mark alone" "[ -n \"\$(mark_of s:r-other)\" ]"
claude_hook claude-stop '{"session_id":"r2","cwd":"/tmp/proj"}'
claude_hook claude-resolved '{"session_id":"r2","cwd":"/tmp/proj","tool_name":"Read"}'
chk "a session that resumed work supersedes its finished mark" "[ -z \"\$(mark_of s:r2)\" ]"

# a slower call of the same batch was already running when the prompt appeared
claude_hook claude-mark '{"session_id":"r5","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission"}'
claude_hook claude-resolved '{"session_id":"r5","cwd":"/tmp/proj","tool_name":"WebFetch","duration_ms":30000}'
chk "a tool that began before the prompt does not resolve it" "[ -n \"\$(mark_of s:r5)\" ]"
claude_hook claude-resolved '{"session_id":"r5","cwd":"/tmp/proj","tool_name":"Bash","duration_ms":169}'
chk "the tool that ran after the approval resolves it" "[ -z \"\$(mark_of s:r5)\" ]"
claude_hook claude-mark '{"session_id":"r6","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission"}'
claude_hook claude-resolved '{"session_id":"r6","cwd":"/tmp/proj","tool_name":"Bash","duration_ms":12.75}'
chk "a fractional duration is read as a number" "[ -z \"\$(mark_of s:r6)\" ]"

# the hook environment names the session, which lets the resolver leave before
# it parses anything when that session holds no mark
claude_hook claude-mark '{"session_id":"r3","cwd":"/tmp/proj","notification_type":"permission_prompt","message":"Claude needs your permission to use Bash"}'
claude_hook claude-resolved '{"session_id":"r4","cwd":"/tmp/proj","tool_name":"Bash"}' \
  CLAUDE_CODE_SESSION_ID=r4
chk "a tool call in a session with no mark leaves other marks alone" \
  "[ -n \"\$(mark_of s:r3)\" ] && ! grep -q 's:r4' '$REG' 2>/dev/null"
claude_hook claude-resolved '{"session_id":"r3","cwd":"/tmp/proj","tool_name":"Bash"}' \
  CLAUDE_CODE_SESSION_ID=r3
chk "a tool call in the marked session resolves it" "[ -z \"\$(mark_of s:r3)\" ]"

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

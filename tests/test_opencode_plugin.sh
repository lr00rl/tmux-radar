#!/usr/bin/env bash
# Verify current upstream event shapes and one bounded notifier stream.
set -euo pipefail

WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/radar-opencode-plugin.XXXXXX)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi; }

cat > "$T/notify" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >> "$OPENCODE_PID_LOG"
if [ "${1:-}" = "opencode-stream" ]; then
  while IFS= read -r payload; do
    printf '%s\n' "$payload" >> "$OPENCODE_EVENT_LOG"
    printf 'ok\t%s\t%s\n' \
      "$(printf '%s' "$payload" | jq -r .generation)" \
      "$(printf '%s' "$payload" | jq -r .sequence)"
  done
else
  payload="$(cat)"
  printf '%s\n' "$payload" >> "$OPENCODE_EVENT_LOG"
fi
SH
chmod +x "$T/notify"

escaped="$(printf '%s' "$T/notify" | sed 's/[&#\]/\\&/g')"
sed "s#__TMUX_RADAR_NOTIFY__#$escaped#g" \
  "$WT/scripts/opencode-tmux-notify.js" > "$T/plugin.mjs"

cat > "$T/run.mjs" <<'JS'
const { default: plugin } = await import(process.argv[2]);
const hooks = await plugin({
  directory: "/tmp/opencode-project",
  client: { app: { log: async () => {} } },
});

await Promise.all([
  hooks.event({ event: { type: "session.created", properties: { info: { id: "s1" } } } }),
  hooks.event({ event: { type: "permission.asked", properties: {
    id: "p1", sessionID: "s1", permission: "bash",
    patterns: ["go test ./..."], metadata: {}, always: [],
  } } }),
  hooks.event({ event: { type: "session.created", properties: { info: { id: "s2" } } } }),
  hooks.event({ event: { type: "session.idle", properties: { sessionID: "s2" } } }),
  hooks.event({ event: { type: "session.deleted", properties: { info: { id: "s2" } } } }),
  hooks.event({ event: { type: "question.asked", properties: {
    id: "q1", sessionID: "s1",
    questions: [{ header: "Target", question: "Which target should I deploy?" }],
  } } }),
  hooks.event({ event: { type: "question.replied", properties: {
    sessionID: "s1", requestID: "q1", answers: [["staging"]],
  } } }),
  hooks.event({ event: { type: "permission.replied", properties: {
    sessionID: "s1", requestID: "p1", reply: "once",
  } } }),
  hooks.event({ event: { type: "message.updated", properties: {
    info: { role: "assistant", sessionID: "s1" },
  } } }),
]);
await hooks.dispose();
JS

export TMUX_PANE="%88"
export OPENCODE_EVENT_LOG="$T/events.jsonl"
export OPENCODE_PID_LOG="$T/pids"
node "$T/run.mjs" "$T/plugin.mjs"

events="$(jq -r .event "$OPENCODE_EVENT_LOG" | paste -sd, -)"
chk "current OpenCode events map to ordered lifecycle transitions" \
  "[ '$events' = 'start,permission,start,idle,end,input,user,user' ]"
chk "assistant message.updated does not clear the mark" \
  "[ \$(grep -c '\"event\":\"user\"' '$OPENCODE_EVENT_LOG') -eq 2 ]"
chk "permission.asked carries current permission and pattern details" \
  "jq -e 'select(.event==\"permission\") | .session_id==\"s1\" and (.message | contains(\"bash\")) and (.message | contains(\"go test ./...\"))' '$OPENCODE_EVENT_LOG' >/dev/null"
chk "question.asked carries a useful input label" \
  "jq -e 'select(.event==\"input\") | .session_id==\"s1\" and (.message | contains(\"Which target\"))' '$OPENCODE_EVENT_LOG' >/dev/null"
chk "one OpenCode plugin owns exactly one notifier process" \
  "[ \$(sort -u '$OPENCODE_PID_LOG' | wc -l | tr -d ' ') -eq 1 ]"
chk "all events carry one generation and strictly increasing sequences" \
  "jq -s 'map(.generation) | unique | length == 1' '$OPENCODE_EVENT_LOG' >/dev/null && jq -s 'map(.sequence) as \$s | \$s == ([range(1; (\$s|length)+1)])' '$OPENCODE_EVENT_LOG' >/dev/null"
chk "bridge implementation has a bounded pending-event budget" \
  "grep -q 'MAX_PENDING' '$WT/scripts/opencode-tmux-notify.js'"
chk "bridge escalates a stuck process group to SIGKILL" \
  "grep -q 'signalGroup(\"SIGKILL\")' '$WT/scripts/opencode-tmux-notify.js'"

cat > "$T/stuck-notify" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$OPENCODE_STUCK_PIDS"
trap '' TERM
sleep 30 &
printf '%s\n' "$!" >> "$OPENCODE_STUCK_PIDS"
wait
SH
chmod +x "$T/stuck-notify"
stuck_escaped="$(printf '%s' "$T/stuck-notify" | sed 's/[&#\]/\\&/g')"
sed "s#__TMUX_RADAR_NOTIFY__#$stuck_escaped#g" \
  "$WT/scripts/opencode-tmux-notify.js" > "$T/stuck-plugin.mjs"
cat > "$T/stuck-run.mjs" <<'JS'
import { appendFileSync, existsSync } from "node:fs";
const { default: plugin } = await import(process.argv[2]);
const hooks = await plugin({
  directory: "/tmp/opencode-project",
  client: {
    app: {
      log: async (entry) =>
        appendFileSync(process.env.OPENCODE_STUCK_LOG, JSON.stringify(entry) + "\n"),
    },
  },
});
for (let attempt = 0; attempt < 100; attempt += 1) {
  if (existsSync(process.env.OPENCODE_STUCK_PIDS)) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
await Promise.all(
  Array.from({ length: 80 }, (_, index) =>
    hooks.event({
      event: {
        type: "session.created",
        properties: { info: { id: `overflow-${index}` } },
      },
    })
  )
);
await hooks.dispose();
JS
export OPENCODE_STUCK_PIDS="$T/stuck-pids"
export OPENCODE_STUCK_LOG="$T/stuck-log"
node "$T/stuck-run.mjs" "$T/stuck-plugin.mjs"
sleep 0.4
chk "queue overflow is surfaced through the OpenCode log" \
  "grep -q 'pending event limit' '$OPENCODE_STUCK_LOG'"
chk "overflow still owns only one bridge process tree" \
  "[ \$(wc -l < '$OPENCODE_STUCK_PIDS' | tr -d ' ') -eq 2 ]"
stuck_alive=0
while IFS= read -r stuck_pid; do
  if kill -0 "$stuck_pid" 2>/dev/null; then stuck_alive=$((stuck_alive + 1)); fi
done < "$OPENCODE_STUCK_PIDS"
chk "TERM-resistant bridge and descendant are both reaped" "[ '$stuck_alive' -eq 0 ]"

cat > "$T/leader-first-notify" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$OPENCODE_STUCK_PIDS"
trap 'exit 0' TERM
sh -c 'trap "" TERM; sleep 30' &
printf '%s\n' "$!" >> "$OPENCODE_STUCK_PIDS"
wait
SH
chmod +x "$T/leader-first-notify"
leader_escaped="$(printf '%s' "$T/leader-first-notify" | sed 's/[&#\]/\\&/g')"
sed "s#__TMUX_RADAR_NOTIFY__#$leader_escaped#g" \
  "$WT/scripts/opencode-tmux-notify.js" > "$T/leader-first-plugin.mjs"
export OPENCODE_STUCK_PIDS="$T/leader-first-pids"
export OPENCODE_STUCK_LOG="$T/leader-first-log"
node "$T/stuck-run.mjs" "$T/leader-first-plugin.mjs"
sleep 0.4
leader_alive=0
while IFS= read -r stuck_pid; do
  if kill -0 "$stuck_pid" 2>/dev/null; then leader_alive=$((leader_alive + 1)); fi
done < "$OPENCODE_STUCK_PIDS"
chk "leader-first exit still reaps its TERM-resistant descendant" \
  "[ '$leader_alive' -eq 0 ]"

cat > "$T/host-exit-run.mjs" <<'JS'
import { existsSync } from "node:fs";
const { default: plugin } = await import(process.argv[2]);
await plugin({
  directory: "/tmp/opencode-project",
  client: { app: { log: async () => {} } },
});
for (let attempt = 0; attempt < 100; attempt += 1) {
  if (existsSync(process.env.OPENCODE_STUCK_PIDS)) break;
  await new Promise((resolve) => setTimeout(resolve, 10));
}
process.exit(0);
JS
export OPENCODE_STUCK_PIDS="$T/host-exit-pids"
node "$T/host-exit-run.mjs" "$T/stuck-plugin.mjs"
sleep 0.3
host_exit_alive=0
while IFS= read -r stuck_pid; do
  if kill -0 "$stuck_pid" 2>/dev/null; then host_exit_alive=$((host_exit_alive + 1)); fi
done < "$OPENCODE_STUCK_PIDS"
chk "host exit without dispose synchronously kills the bridge group" \
  "[ '$host_exit_alive' -eq 0 ]"

# `opencode run` loads plugins too, with nobody at the prompt. The bridge reads
# the subcommand off its own argv and registers nothing.
cat > "$T/headless.mjs" <<'JS'
const { default: plugin } = await import(process.argv[2]);
const hooks = await plugin({
  directory: "/tmp/opencode-project",
  client: { app: { log: async () => {} } },
});
process.stdout.write(String(Object.keys(hooks).length));
// a bridge that did start owns a child process: let it go, or node never exits
if (hooks.dispose) await hooks.dispose();
process.exit(0);
JS
export OPENCODE_PID_LOG="$T/headless-pids"
: > "$OPENCODE_PID_LOG"
chk "opencode run registers no hooks" \
  "[ \"\$(node '$T/headless.mjs' '$T/plugin.mjs' run 'fix the build')\" = 0 ]"
chk "opencode run starts no notifier process" "! [ -s '$OPENCODE_PID_LOG' ]"
chk "a flag ahead of the subcommand does not hide it" \
  "[ \"\$(node '$T/headless.mjs' '$T/plugin.mjs' --print-logs run)\" = 0 ]"
chk "the word run inside a path is no subcommand" \
  "[ \"\$(node '$T/headless.mjs' '$T/plugin.mjs' /work/run/project)\" -gt 0 ]"

# pi: the bridge runs in-process, so drive its handlers the way pi fires them.
# The fake notifier, called as `agent-event pi <event>`, logs
# "<event>\t<payload>"; it can stall one event to show
# that the next one still lands after it. The fake tmux answers the two
# display options from the environment.
cat > "$T/pi-notify" <<'SH'
#!/usr/bin/env bash
payload="$(cat)"
# a notifier that ignores TERM and never returns
if [ "${3:-}" = "${PI_HANG_EVENT:-}" ]; then trap '' TERM; exec sleep 30; fi
[ "${3:-}" != "${PI_SLOW_EVENT:-}" ] || sleep 0.4
printf '%s\t%s\n' "${3:-}" "$payload" >> "$PI_EVENT_LOG"
SH
mkdir -p "$T/fakebin"
cat > "$T/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${3:-}" in
  @radar-turn-stamp) printf '%s\n' "${FAKE_TURN_STAMP:-}" ;;
  @radar-session-info) printf '%s\n' "${FAKE_SESSION_INFO:-}" ;;
esac
SH
chmod +x "$T/pi-notify" "$T/fakebin/tmux"
pi_escaped="$(printf '%s' "$T/pi-notify" | sed 's/[&#\]/\\&/g')"
sed "s#__TMUX_RADAR_NOTIFY__#$pi_escaped#g" "$WT/scripts/pi-tmux-notify.ts" > "$T/pi-bridge.mjs"
chk "pi bridge parses as plain JS" "node --check '$T/pi-bridge.mjs'"
cat > "$T/pi-run.mjs" <<'JS'
const [bridgePath, scenario, mode] = process.argv.slice(2);
const { default: bridge } = await import(bridgePath);
const handlers = {};
bridge({ on: (name, fn) => { handlers[name] = fn; } });
const notes = [];
const ctx = { cwd: process.env.PI_CWD || "/tmp/pi-project", hasUI: true, ui: { notify: (text) => notes.push(text) } };
if (mode !== "none") ctx.mode = mode;
if (!process.env.PI_NO_SESSION) {
  ctx.sessionManager = {
    getSessionId: () => "sess-1",
    getSessionFile: () => `${process.env.HOME}/.pi/agent/sessions/--tmp-pi-project--/s1.jsonl`,
  };
}
const said = (stopReason, errorMessage) => ({ messages: [{ role: "assistant", stopReason, errorMessage }] });
const start = ["session_start", { reason: "startup" }];
const settle = (outcome, aborted = false) => [["agent_before_settle", { outcome }], ["agent_settled", { aborted }]];
const steps = {
  run: [start, ["agent_start"], ["agent_end", said("stop")], ...settle("completed")],
  approval: [start, ["agent_start"],
    ["ui_prompt_start", { kind: "select", title: "Permission Required\nCurrent agent requested bash command 'rm -rf x'" }],
    ["ui_prompt_end", { kind: "select" }],
    ["agent_end", said("stop")], ...settle("completed")],
  question: [start, ["agent_start"], ["ui_prompt_start", { kind: "input", title: "Which target?" }],
    ["ui_prompt_end", { kind: "input" }], ["agent_end", said("stop")], ...settle("completed")],
  idle_dialog: [start, ["ui_prompt_start", { kind: "select", title: "Pick a model" }], ["ui_prompt_end", { kind: "select" }]],
  retry: [start, ["agent_start"], ["agent_end", said("error", "overloaded")],
    ["agent_start"], ["agent_end", said("stop")], ...settle("completed")],
  failed: [start, ["agent_start"], ["agent_end", said("error", "429 Too Many Requests\nretry later")], ...settle("error")],
  aborted: [start, ["agent_start"], ["agent_end", said("aborted")], ...settle("aborted", true)],
  settle_only: [start, ...settle("completed")],
  reload: [["session_start", { reason: "reload" }]],
  shutdown: [start, ["session_shutdown", { reason: "quit" }]],
};
for (const [name, event = {}] of steps[scenario]) await handlers[name]?.(event, ctx);
await new Promise((resolve) => setTimeout(resolve, Number(process.env.PI_WAIT || 700)));
process.stdout.write(JSON.stringify(notes));
JS
pi_run() {  # pi_run <scenario> <ctx.mode|none>: events to $PI_EVENT_LOG, notes on stdout
  export PI_EVENT_LOG="$T/pi-$1-$2.log"
  : > "$PI_EVENT_LOG"
  PATH="$T/fakebin:$PATH" TMUX_PANE="${PI_PANE-%9}" node "$T/pi-run.mjs" "$T/pi-bridge.mjs" "$1" "$2"
}
pi_events() { pi_run "$1" "$2" >/dev/null; cut -f1 "$PI_EVENT_LOG" | paste -sd' ' -; }
pi_field() {  # pi_field <scenario> <event> <field>: from that scenario's last TUI run
  awk -F'\t' -v e="$2" '$1 == e { print $2; exit }' "$T/pi-$1-tui.log" | jq -r ".$3"
}

# only the TUI has a person in front of it
chk "pi in its TUI reports a run's start and end" \
  "[ \"\$(pi_events run tui)\" = 'session_start user_resumed turn_complete' ]"
chk "pi in print mode reports nothing" "[ -z \"\$(pi_events run print)\" ]"
chk "pi in json mode reports nothing" "[ -z \"\$(pi_events run json)\" ]"
chk "pi in rpc mode reports nothing" "[ -z \"\$(pi_events run rpc)\" ]"
chk "a pi that does not say its mode is served as before" \
  "[ \"\$(pi_events run none)\" = 'session_start user_resumed turn_complete' ]"
pi_run run tui >/dev/null
chk "pi events carry pi's own session id" "[ \"\$(pi_field run turn_complete session_id)\" = sess-1 ]"
PI_NO_SESSION=1 pi_run run tui >/dev/null
chk "a pi with no session manager is keyed by its pid" \
  "[ \"\$(pi_field run turn_complete session_id)\" -gt 0 ] 2>/dev/null"

# dialogs: an approval mid-run is one, a dialog between runs is not
chk "an approval dialog mid-run marks the session and its answer clears it" \
  "[ \"\$(pi_events approval tui)\" = 'session_start user_resumed approval approval_resolved turn_complete' ]"
chk "the dialog's title becomes one line of label" \
  "[ \"\$(pi_field approval approval label)\" = \"Permission Required Current agent requested bash command 'rm -rf x'\" ]"
chk "a question mid-run asks for input" \
  "[ \"\$(pi_events question tui)\" = 'session_start user_resumed input_required approval_resolved turn_complete' ]"
chk "a dialog between runs is the person's own and reports nothing" \
  "[ \"\$(pi_events idle_dialog tui)\" = 'session_start' ]"
PI_SLOW_EVENT=approval_resolved PI_WAIT=2000 pi_run approval tui >/dev/null
chk "a slow event still reaches radar before the one fired after it" \
  "[ \"\$(cut -f1 '$PI_EVENT_LOG' | paste -sd' ' -)\" = 'session_start user_resumed approval approval_resolved turn_complete' ]"

# agent_end is not the end of a run; agent_settled is, and says how it ended
chk "an automatic retry after agent_end is the same run" \
  "[ \"\$(pi_events retry tui)\" = 'session_start user_resumed turn_complete' ]"
chk "a run that settles on an error is a failed turn" \
  "[ \"\$(pi_events failed tui)\" = 'session_start user_resumed turn_failed' ]"
chk "the failed turn carries the error as one line" \
  "[ \"\$(pi_field failed turn_failed label)\" = '429 Too Many Requests retry later' ]"
chk "a run stopped with Escape is an interrupt, not a finished turn" \
  "[ \"\$(pi_events aborted tui)\" = 'session_start user_resumed interrupt' ]"
chk "quitting ends the session" "[ \"\$(pi_events shutdown tui)\" = 'session_start session_end' ]"
chk "a settle with no run behind it reports nothing" \
  "[ \"\$(pi_events settle_only tui)\" = 'session_start' ]"
chk "and shows no stamp" "[ \"\$(pi_run settle_only tui | jq length)\" = 1 ]"
PI_HANG_EVENT=approval_resolved PI_WAIT=11500 pi_run approval tui >/dev/null
chk "a notifier that hangs is killed and the next event still goes out" \
  "[ \"\$(cut -f1 '$T/pi-approval-tui.log' | paste -sd' ' -)\" = 'session_start user_resumed approval turn_complete' ]"
PI_CWD="$(printf '/tmp/pi\tproject')" pi_run run tui >/dev/null
chk "a working directory radar would reject is left out" \
  "[ \"\$(grep -c . '$T/pi-run-tui.log')\" = 3 ] && [ \"\$(pi_field run turn_complete cwd)\" = '' ]"

# the turn stamp and session lines Claude Code and Codex get
PI_NOTES="$(pi_run run tui)"
chk "a session start shows the session id and file" \
  "[ \"\$(printf '%s' '$PI_NOTES' | jq -r '.[0]')\" = \"\$(printf 'session sess-1\n~/.pi/agent/sessions/--tmp-pi-project--/s1.jsonl')\" ]"
chk "a run's end shows its start, end and length, then the session" \
  "printf '%s' '$PI_NOTES' | jq -e '.[1] | test(\"^UTC [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z → ([0-9]{4}-[0-9]{2}-[0-9]{2}T)?[0-9:]{8}Z  turn took [0-9]+s\\nsession sess-1\\n~/.pi/agent/sessions/--tmp-pi-project--/s1.jsonl$\")' >/dev/null"
PI_NOTES="$(FAKE_TURN_STAMP=off pi_run run tui)"
chk "@radar-turn-stamp off leaves only the session lines" \
  "printf '%s' '$PI_NOTES' | jq -e '.[1] | startswith(\"session sess-1\")' >/dev/null"
PI_NOTES="$(FAKE_SESSION_INFO=off pi_run run tui)"
chk "@radar-session-info off leaves only the stamp" \
  "printf '%s' '$PI_NOTES' | jq -e 'length == 1 and (.[0] | test(\"turn took [0-9]+s$\"))' >/dev/null"
chk "a reload shows nothing" "[ \"\$(pi_run reload tui)\" = '[]' ]"
PI_NOTES="$(PI_PANE='' pi_run run tui)"
chk "pi outside tmux reports nothing to radar" "! [ -s '$T/pi-run-tui.log' ]"
chk "but still shows the stamp and session lines" \
  "printf '%s' '$PI_NOTES' | jq -e 'length == 2' >/dev/null"

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

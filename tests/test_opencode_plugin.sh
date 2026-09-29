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

# pi loads its extensions in print, json and rpc mode as well; only the TUI
# has a person in front of it.
sed "s#__TMUX_RADAR_NOTIFY__#$escaped#g" "$WT/scripts/pi-tmux-notify.ts" > "$T/pi-bridge.mjs"
cat > "$T/pi-run.mjs" <<'JS'
const { default: bridge } = await import(process.argv[2]);
const handlers = {};
bridge({ on: (name, fn) => { handlers[name] = fn; } });
const ctx = { cwd: "/tmp/pi-project" };
if (process.argv[3] !== "none") ctx.mode = process.argv[3];
handlers.session_start({}, ctx);
handlers.input({ source: "interactive" }, ctx);
handlers.agent_end({}, ctx);
await new Promise((resolve) => setTimeout(resolve, 400));
JS
pi_events() {  # pi_events <ctx.mode|none>: how many events reached the notifier
  export OPENCODE_EVENT_LOG="$T/pi-$1.jsonl" OPENCODE_PID_LOG="$T/pi-$1.pids"
  : > "$OPENCODE_EVENT_LOG"
  node "$T/pi-run.mjs" "$T/pi-bridge.mjs" "$1"
  grep -c . "$OPENCODE_EVENT_LOG" || true
}
chk "pi in its TUI reports every turn boundary" "[ \"\$(pi_events tui)\" = 3 ]"
chk "pi in print mode reports nothing" "[ \"\$(pi_events print)\" = 0 ]"
chk "pi in json mode reports nothing" "[ \"\$(pi_events json)\" = 0 ]"
chk "pi in rpc mode reports nothing" "[ \"\$(pi_events rpc)\" = 0 ]"
chk "a pi that does not say its mode is served as before" "[ \"\$(pi_events none)\" = 3 ]"

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]

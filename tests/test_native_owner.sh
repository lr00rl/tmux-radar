#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir native-owner)"
WATCHER_PID=""
EXTRA_PIDS=""

cleanup() {
  local pid
  if [ -n "$WATCHER_PID" ]; then
    kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  for pid in $EXTRA_PIDS; do
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/state"
export TEST_TARGET_PANE_ALIVE="$TMP/target-pane-alive"
touch "$TEST_TARGET_PANE_ALIVE"

cat > "$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    target="%1"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -t ] && [ "$#" -gt 1 ]; then target="$2"; shift; fi
      shift
    done
    if [ "$target" = %99 ] && [ -n "${TEST_OWNER_PANE_ALIVE:-}" ] && \
      [ ! -e "$TEST_OWNER_PANE_ALIVE" ]; then
      exit 1
    fi
    if [ "$target" = %1 ] && [ -n "${TEST_TARGET_PANE_ALIVE:-}" ] && \
      [ ! -e "$TEST_TARGET_PANE_ALIVE" ]; then
      exit 1
    fi
    printf '%s\n' "$target"
    ;;
  capture-pane) printf '%s\n' 'stable target screen' ;;
  wait-for)
    [ "${2:-}" = -S ] && exit 0
    sleep 0.02
    ;;
  show-option|list-sessions|list-panes|send-keys|kill-pane) exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$TMP/bin/tmux"

cat > "$TMP/bin/fake-brain" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
if [ -n "${TEST_BRAIN_BLOCK:-}" ] && [ -e "$TEST_BRAIN_BLOCK" ]; then
  trap '' TERM INT HUP
  /bin/sleep 300 &
  child=$!
  printf '%s %s\n' "$$" "$child" > "$TEST_BRAIN_PIDS"
  wait "$child"
  exit $?
fi
printf '%s\n' '{"action":"wait","text":"","keys":[],"safe":true,"reason":"fixture wait","pane_state":"working","goal_status":"working","risk":"low","evidence":[]}'
SH
chmod +x "$TMP/bin/fake-brain"

cat > "$TMP/bin/owner-heartbeat" <<'SH'
#!/usr/bin/env bash
set -eu
path="$1" token="$2"
trap 'exit 0' TERM INT HUP
while :; do
  tmp="${path}.tmp.$$"
  printf 'schema_version=1\ntoken=%s\npid=%s\nupdated_epoch=%s\n' \
    "$token" "$$" "$(date '+%s')" > "$tmp"
  mv "$tmp" "$path"
  sleep 1
done
SH
chmod +x "$TMP/bin/owner-heartbeat"

run_ai() {
  PATH="$TMP/bin:$PATH" \
  TMUX_RADAR_STATE_DIR="$TMP/state" \
  TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
  TMUX_RADAR_AI_CMD="$TMP/bin/fake-brain" \
  TMUX_RADAR_RUNTIME_OVERRIDES='poll=30,completion_close_delay=0' \
  TMUX_RADAR_TEST_WAIT_TICK=0.01 \
    bash "$ROOT/scripts/ai.sh" "$@"
}

build_request() {
  local goal="$1" owner config backend
  if [ "$#" -gt 1 ]; then owner="$2"
  else owner='{"schema_version":1,"kind":"detached"}'; fi
  config="$(run_ai _build-watch-config %1 "$goal")"
  backend="$(run_ai doctor-json | jq -c '.backend')"
  config="$(printf '%s' "$config" | jq -c --argjson backend "$backend" '. + {backend:$backend}')"
  jq -cn \
    --arg state_root "$TMP/state" \
    --argjson config "$config" \
    --argjson owner "$owner" \
    '{protocol_version:1,config_schema_version:1,state_root:$state_root,
      target_pane:"%1",config:$config,owner:$owner}'
}

goal=$'private goal line 1\nprivate goal line 2'
request="$(build_request "$goal")"

invalid="$(printf '%s' "$request" | jq -c '. + {unknown_field:true}')"
set +e
invalid_result="$(printf '%s\n' "$invalid" | run_ai engine-start)"
invalid_rc=$?
set -e
[ "$invalid_rc" -ne 0 ] || _fail_assert 'invalid request returned success'
printf '%s' "$invalid_result" | jq -e '
  .protocol_version == 1 and .ok == false and .status == "rejected" and
  .error.code == "invalid-request"
' >/dev/null || _fail_assert 'invalid request did not return a stable rejection' 'actual' "$invalid_result"
[ -z "$(find "$TMP/state/ai-runs" -mindepth 1 -maxdepth 1 -type d -print -quit 2>/dev/null)" ] ||
  _fail_assert 'invalid request created a run directory'
printf 'PASS: strict engine-start rejects before side effects\n'

printf '%s\n' "$request" | run_ai engine-start > "$TMP/start-1.json" 2> "$TMP/start-1.err" &
start_one=$!
printf '%s\n' "$request" | run_ai engine-start > "$TMP/start-2.json" 2> "$TMP/start-2.err" &
start_two=$!
wait "$start_one"
wait "$start_two"

statuses="$(jq -r '.status' "$TMP/start-1.json" "$TMP/start-2.json" | sort | tr '\n' ' ')"
assert_eq 'already-active started ' "$statuses" 'concurrent start outcomes'
started_file="$TMP/start-1.json"
[ "$(jq -r '.status' "$started_file")" = started ] || started_file="$TMP/start-2.json"
run_id="$(jq -r '.run_id' "$started_file")"
run_dir="$(jq -r '.run_dir' "$started_file")"
WATCHER_PID="$(jq -r '.watcher_pid' "$started_file")"
if [ -z "$run_id" ] || [ ! -d "$run_dir" ] || ! kill -0 "$WATCHER_PID" 2>/dev/null; then
  _fail_assert 'started result does not identify one live watcher' 'result' "$(cat "$started_file")"
fi
assert_eq 1 "$(find "$TMP/state/ai-runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" \
  'concurrent start run count'
assert_json "$run_dir/ready.json" '.schema_version == 1 and .phase == "ARMED"'
assert_json "$run_dir/start.json" ".schema_version == 1 and .generation != \"\" and .watcher_pid == $WATCHER_PID"
command_line="$(ps -p "$WATCHER_PID" -o command=)"
case "$command_line" in
  *'private goal'*|*'fake-brain'*)
    _fail_assert 'immutable config leaked into watcher argv' 'argv' "$command_line"
    ;;
esac
assert_contains "$command_line" '_watch_run' 'native watcher uses run identity only'
printf 'PASS: concurrent start is atomic and keeps config out of argv\n'

pause_result="$(run_ai control "$run_id" %1 pause req-pause)"
printf '%s' "$pause_result" | jq -e '.ok == true and .status == "acknowledged"' >/dev/null ||
  _fail_assert 'pause was not acknowledged' 'actual' "$pause_result"
assert_json "$run_dir/state.json" '.phase == "PAUSED_USER"'
pause_duplicate="$(run_ai control "$run_id" %1 pause req-pause)"
assert_eq "$pause_result" "$pause_duplicate" 'duplicate pause acknowledgement'
assert_eq 1 "$(jq -s '[.[] | select(.request_id == "req-pause" and .kind == "paused")] | length' "$run_dir/events.jsonl")" \
  'idempotent pause event count'

resume_result="$(run_ai control "$run_id" %1 resume req-resume)"
printf '%s' "$resume_result" | jq -e '.ok == true and .status == "acknowledged"' >/dev/null ||
  _fail_assert 'resume was not acknowledged' 'actual' "$resume_result"
set +e
reassess_result="$(run_ai control "$run_id" %1 reassess req-reassess)"
reassess_rc=$?
set -e
[ "$reassess_rc" -eq 0 ] || _fail_assert 'reassess command failed' 'actual' "$reassess_result"
printf '%s' "$reassess_result" | jq -e '.ok == true and .status == "acknowledged"' >/dev/null ||
  _fail_assert 'reassess was not acknowledged' 'actual' "$reassess_result"
assert_file "$run_dir/controls/req-pause.request.json"
assert_file "$run_dir/controls/req-pause.ack.json"
printf 'PASS: run-scoped controls persist idempotent request and acknowledgement evidence\n'

watch_file="$TMP/state/ai-watch/_1.watch"
replace_watch_pointer() {
  local source="$1" lock="$TMP/state/ai-watch/.launch-_1.lock" attempt=0 next
  while ! mkdir "$lock" 2>/dev/null; do
    [ "$attempt" -lt 200 ] || _fail_assert 'test could not acquire launch lock'
    sleep 0.01
    attempt=$((attempt + 1))
  done
  printf '%s\n' "$$" > "$lock/owner"
  next="${watch_file}.replace.$$"
  cp "$source" "$next"
  mv "$next" "$watch_file"
  rm -f "$lock/owner"
  rmdir "$lock"
}

cp "$watch_file" "$TMP/original.watch"
sed 's/^run_id=.*/run_id=replacement-run/; s/^generation=.*/generation=replacement-generation/' \
  "$TMP/original.watch" > "$TMP/replacement.watch"
replace_watch_pointer "$TMP/replacement.watch"
sleep 0.2
assert_eq replacement-run "$(awk -F= '$1 == "run_id" { print $2; exit }' "$watch_file")" \
  'old watcher must not overwrite a replacement pointer'
set +e
stale_result="$(run_ai control "$run_id" %1 pause req-stale)"
stale_rc=$?
set -e
[ "$stale_rc" -ne 0 ] || _fail_assert 'stale control returned success'
printf '%s' "$stale_result" | jq -e '.ok == false and .status == "stale-run"' >/dev/null ||
  _fail_assert 'stale control did not fail closed' 'actual' "$stale_result"
[ ! -e "$run_dir/paused" ] || _fail_assert 'stale control mutated the requested run'
replace_watch_pointer "$TMP/original.watch"
printf 'PASS: stale run identity cannot mutate a replacement pointer\n'

stop_result="$(run_ai control "$run_id" %1 stop req-stop)"
printf '%s' "$stop_result" | jq -e '.ok == true and .status == "acknowledged"' >/dev/null ||
  _fail_assert 'stop was not acknowledged' 'actual' "$stop_result"
jq -e --arg run_id "$run_id" '.run_id == $run_id and .outcome == "stopped"' \
  "$run_dir/final.json" >/dev/null || _fail_assert 'stop final evidence does not match the requested run'
wait_for_exit "$WATCHER_PID" 200 0.02
WATCHER_PID=""
[ ! -e "$watch_file" ] || _fail_assert 'terminal stop left a live pointer'
printf 'PASS: stop acknowledges only after terminal evidence\n'

printf 'PASS: native start and run-scoped control protocol\n'

expect_start_rejected() {
  local request="$1" code="$2" before after result rc
  before="$(find "$TMP/state/ai-runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  set +e
  result="$(printf '%s\n' "$request" | run_ai engine-start)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    WATCHER_PID="$(printf '%s' "$result" | jq -r '.watcher_pid // empty')"
    _fail_assert 'invalid owner start returned success' 'result' "$result"
  fi
  printf '%s' "$result" | jq -e --arg code "$code" \
    '.protocol_version == 1 and .ok == false and .status == "rejected" and .error.code == $code' \
    >/dev/null || _fail_assert 'invalid owner rejection is not canonical' 'actual' "$result"
  after="$(find "$TMP/state/ai-runs" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  assert_eq "$before" "$after" 'invalid owner creates no run directory'
}

viewer_request="$(build_request 'viewer cannot own a run' \
  '{"schema_version":1,"kind":"viewer"}')"
expect_start_rejected "$viewer_request" invalid-owner

dead_token=0123456789abcdef0123456789abcdef
dead_heartbeat="$TMP/dead-owner.heartbeat"
printf 'schema_version=1\ntoken=%s\npid=999999\nupdated_epoch=%s\n' \
  "$dead_token" "$(date '+%s')" > "$dead_heartbeat"
dead_owner="$(jq -cn --arg token "$dead_token" --arg heartbeat "$dead_heartbeat" \
  '{schema_version:1,kind:"popup",pid:999999,token:$token,heartbeat_path:$heartbeat}')"
dead_request="$(build_request 'dead owner cannot start' "$dead_owner")"
expect_start_rejected "$dead_request" owner-unavailable

printf 'PASS: viewer and dead active owners are rejected before side effects\n'

split_token=fedcba9876543210fedcba9876543210
split_heartbeat="$TMP/split-owner.heartbeat"
export TEST_OWNER_PANE_ALIVE="$TMP/owner-pane-alive"
export TEST_BRAIN_BLOCK="$TMP/split-brain.block"
export TEST_BRAIN_PIDS="$TMP/split-brain.pids"
touch "$TEST_OWNER_PANE_ALIVE" "$TEST_BRAIN_BLOCK"
"$TMP/bin/owner-heartbeat" "$split_heartbeat" "$split_token" &
split_owner_pid=$!
EXTRA_PIDS="$EXTRA_PIDS $split_owner_pid"
wait_for_file "$split_heartbeat" 80 0.025
split_owner="$(jq -cn --arg token "$split_token" --arg heartbeat "$split_heartbeat" \
  --argjson pid "$split_owner_pid" \
  '{schema_version:1,kind:"split",pane:"%99",pid:$pid,token:$token,heartbeat_path:$heartbeat}')"
split_request="$(build_request 'split owner lifecycle' "$split_owner")"
split_result="$(printf '%s\n' "$split_request" | run_ai engine-start)"
printf '%s' "$split_result" | jq -e '.ok == true and .status == "started"' >/dev/null ||
  _fail_assert 'split owner run did not start' 'result' "$split_result"
WATCHER_PID="$(printf '%s' "$split_result" | jq -r '.watcher_pid')"
split_run_dir="$(printf '%s' "$split_result" | jq -r '.run_dir')"
assert_eq "$split_run_dir/owner.json" \
  "$(awk -F= '$1 == "owner_file" { print $2; exit }' "$TMP/state/ai-watch/_1.watch")" \
  'pointer preserves canonical owner metadata path'
assert_json "$split_run_dir/owner.json" ".kind == \"split\" and .pid == $split_owner_pid and .token == \"$split_token\""

run_ai control "$(printf '%s' "$split_result" | jq -r '.run_id')" %1 reassess req-split-brain >/dev/null
wait_for_file "$TEST_BRAIN_PIDS" 200 0.025
read -r split_brain_pid split_brain_child < "$TEST_BRAIN_PIDS"
EXTRA_PIDS="$EXTRA_PIDS $split_brain_pid $split_brain_child"
rm -f "$TEST_OWNER_PANE_ALIVE"
wait_for_exit "$WATCHER_PID" 240 0.025 || _fail_assert \
  'watcher survived split owner pane removal' 'watcher pid' "$WATCHER_PID"
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""
for pid in "$split_brain_pid" "$split_brain_child"; do
  kill -0 "$pid" 2>/dev/null && _fail_assert \
    'backend process survived split owner pane removal' 'pid' "$pid"
done
assert_json "$split_run_dir/final.json" \
  '.outcome == "stopped" and (.reason | contains("owner pane"))'

printf 'PASS: split owner pane removal stops watcher and backend process tree\n'

kill -TERM "$split_owner_pid" 2>/dev/null || true
wait "$split_owner_pid" 2>/dev/null || true
rm -f "$TEST_BRAIN_BLOCK"
popup_token=00112233445566778899aabbccddeeff
popup_heartbeat="$TMP/popup-owner.heartbeat"
"$TMP/bin/owner-heartbeat" "$popup_heartbeat" "$popup_token" &
popup_owner_pid=$!
EXTRA_PIDS="$EXTRA_PIDS $popup_owner_pid"
wait_for_file "$popup_heartbeat" 80 0.025
popup_owner="$(jq -cn --arg token "$popup_token" --arg heartbeat "$popup_heartbeat" \
  --argjson pid "$popup_owner_pid" \
  '{schema_version:1,kind:"popup",pid:$pid,token:$token,heartbeat_path:$heartbeat}')"
popup_request="$(build_request 'popup detach lifecycle' "$popup_owner")"
popup_result="$(printf '%s\n' "$popup_request" | run_ai engine-start)"
printf '%s' "$popup_result" | jq -e '.ok == true and .status == "started"' >/dev/null ||
  _fail_assert 'popup owner run did not start' 'result' "$popup_result"
WATCHER_PID="$(printf '%s' "$popup_result" | jq -r '.watcher_pid')"
popup_run_id="$(printf '%s' "$popup_result" | jq -r '.run_id')"
popup_run_dir="$(printf '%s' "$popup_result" | jq -r '.run_dir')"
detach_result="$(run_ai control "$popup_run_id" %1 detach req-popup-detach)"
printf '%s' "$detach_result" | jq -e \
  '.ok == true and .status == "acknowledged" and .action == "detach"' >/dev/null ||
  _fail_assert 'popup detach was not acknowledged' 'result' "$detach_result"
assert_json "$popup_run_dir/owner.json" '.schema_version == 1 and .kind == "detached"'
kill -TERM "$popup_owner_pid" 2>/dev/null || true
wait "$popup_owner_pid" 2>/dev/null || true
/bin/sleep 2
kill -0 "$WATCHER_PID" 2>/dev/null || _fail_assert \
  'acknowledged popup detach did not preserve the watcher'
rm -f "$TEST_TARGET_PANE_ALIVE"
wait_for_exit "$WATCHER_PID" 240 0.025
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""
assert_json "$popup_run_dir/final.json" \
  '.outcome == "stopped" and (.reason | contains("target pane"))'

printf 'PASS: popup detach survives owner exit but remains bound to the target pane\n'

write_heartbeat_atomic() {
  local path="$1" token="$2" pid="$3" updated="$4" tmp="${1}.test.$$"
  printf 'schema_version=1\ntoken=%s\npid=%s\nupdated_epoch=%s\n' \
    "$token" "$pid" "$updated" > "$tmp"
  mv "$tmp" "$path"
}

start_popup_case() {
  local token="$1" heartbeat="$2" owner_pid="$3" goal="$4" owner request result
  touch "$TEST_TARGET_PANE_ALIVE"
  owner="$(jq -cn --arg token "$token" --arg heartbeat "$heartbeat" --argjson pid "$owner_pid" \
    '{schema_version:1,kind:"popup",pid:$pid,token:$token,heartbeat_path:$heartbeat}')"
  request="$(build_request "$goal" "$owner")"
  result="$(printf '%s\n' "$request" | run_ai engine-start)"
  printf '%s' "$result" | jq -e '.ok == true and .status == "started"' >/dev/null ||
    _fail_assert 'popup owner case did not start' 'result' "$result"
  WATCHER_PID="$(printf '%s' "$result" | jq -r '.watcher_pid')"
  CASE_RUN_ID="$(printf '%s' "$result" | jq -r '.run_id')"
  CASE_RUN_DIR="$(printf '%s' "$result" | jq -r '.run_dir')"
}

crash_token=11112222333344445555666677778888
crash_heartbeat="$TMP/crash-owner.heartbeat"
"$TMP/bin/owner-heartbeat" "$crash_heartbeat" "$crash_token" &
crash_owner_pid=$!
EXTRA_PIDS="$EXTRA_PIDS $crash_owner_pid"
wait_for_file "$crash_heartbeat" 80 0.025
start_popup_case "$crash_token" "$crash_heartbeat" "$crash_owner_pid" 'popup crash lifecycle'
kill -KILL "$crash_owner_pid"
wait "$crash_owner_pid" 2>/dev/null || true
wait_for_exit "$WATCHER_PID" 240 0.025
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""
assert_json "$CASE_RUN_DIR/final.json" \
  '.outcome == "stopped" and (.reason | contains("owner PID"))'
printf 'PASS: popup owner crash stops the watcher\n'

mismatch_token=22223333444455556666777788889999
mismatch_heartbeat="$TMP/mismatch-owner.heartbeat"
export TEST_BRAIN_BLOCK="$TMP/mismatch-brain.block"
export TEST_BRAIN_PIDS="$TMP/mismatch-brain.pids"
touch "$TEST_BRAIN_BLOCK"
"$TMP/bin/owner-heartbeat" "$mismatch_heartbeat" "$mismatch_token" &
mismatch_owner_pid=$!
EXTRA_PIDS="$EXTRA_PIDS $mismatch_owner_pid"
wait_for_file "$mismatch_heartbeat" 80 0.025
start_popup_case "$mismatch_token" "$mismatch_heartbeat" "$mismatch_owner_pid" 'token mismatch lifecycle'
run_ai control "$CASE_RUN_ID" %1 reassess req-token-brain >/dev/null
wait_for_file "$TEST_BRAIN_PIDS" 200 0.025
read -r mismatch_brain_pid mismatch_brain_child < "$TEST_BRAIN_PIDS"
EXTRA_PIDS="$EXTRA_PIDS $mismatch_brain_pid $mismatch_brain_child"
kill -STOP "$mismatch_owner_pid"
write_heartbeat_atomic "$mismatch_heartbeat" deadbeefdeadbeefdeadbeefdeadbeef \
  "$mismatch_owner_pid" "$(date '+%s')"
wait_for_exit "$WATCHER_PID" 240 0.025
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""
for pid in "$mismatch_brain_pid" "$mismatch_brain_child"; do
  kill -0 "$pid" 2>/dev/null && _fail_assert \
    'backend process survived heartbeat token mismatch' 'pid' "$pid"
done
assert_json "$CASE_RUN_DIR/final.json" \
  '.outcome == "stopped" and (.reason | contains("token mismatch"))'
kill -KILL "$mismatch_owner_pid" 2>/dev/null || true
wait "$mismatch_owner_pid" 2>/dev/null || true
rm -f "$TEST_BRAIN_BLOCK"
printf 'PASS: heartbeat token mismatch stops the backend process tree\n'

stale_token=3333444455556666777788889999aaaa
stale_heartbeat="$TMP/stale-owner.heartbeat"
"$TMP/bin/owner-heartbeat" "$stale_heartbeat" "$stale_token" &
stale_owner_pid=$!
EXTRA_PIDS="$EXTRA_PIDS $stale_owner_pid"
wait_for_file "$stale_heartbeat" 80 0.025
start_popup_case "$stale_token" "$stale_heartbeat" "$stale_owner_pid" 'stale heartbeat lifecycle'
kill -STOP "$stale_owner_pid"
write_heartbeat_atomic "$stale_heartbeat" "$stale_token" "$stale_owner_pid" \
  "$(( $(date '+%s') - 10 ))"
wait_for_exit "$WATCHER_PID" 240 0.025
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""
assert_json "$CASE_RUN_DIR/final.json" \
  '.outcome == "stopped" and (.reason | contains("heartbeat is stale"))'
kill -KILL "$stale_owner_pid" 2>/dev/null || true
wait "$stale_owner_pid" 2>/dev/null || true
printf 'PASS: stale heartbeat stops the watcher\n'

takeover_request="$(build_request 'detached owner takeover')"
takeover_result="$(printf '%s\n' "$takeover_request" | run_ai engine-start)"
printf '%s' "$takeover_result" | jq -e '.ok == true and .status == "started"' >/dev/null ||
  _fail_assert 'detached takeover case did not start' 'result' "$takeover_result"
WATCHER_PID="$(printf '%s' "$takeover_result" | jq -r '.watcher_pid')"
takeover_run_id="$(printf '%s' "$takeover_result" | jq -r '.run_id')"
takeover_run_dir="$(printf '%s' "$takeover_result" | jq -r '.run_dir')"

dead_takeover_token=aaaaaaaa11111111bbbbbbbb22222222
dead_takeover_heartbeat="$TMP/dead-takeover-owner.heartbeat"
write_heartbeat_atomic "$dead_takeover_heartbeat" "$dead_takeover_token" 999999 "$(date '+%s')"
dead_takeover_owner="$(jq -cn --arg token "$dead_takeover_token" \
  --arg heartbeat "$dead_takeover_heartbeat" \
  '{schema_version:1,kind:"popup",pid:999999,token:$token,heartbeat_path:$heartbeat}')"
set +e
dead_takeover_result="$(printf '%s\n' "$dead_takeover_owner" | \
  run_ai control "$takeover_run_id" %1 takeover-owner req-dead-takeover)"
dead_takeover_rc=$?
set -e
[ "$dead_takeover_rc" -ne 0 ] || _fail_assert 'dead owner takeover returned success'
printf '%s' "$dead_takeover_result" | jq -e '
  .ok == false and .status == "owner-unavailable" and .action == "takeover-owner"
' >/dev/null || _fail_assert 'dead owner takeover did not fail closed' 'result' "$dead_takeover_result"
assert_json "$takeover_run_dir/owner.json" '.schema_version == 1 and .kind == "detached"'

takeover_token=444455556666777788889999aaaabbbb
takeover_heartbeat="$TMP/takeover-owner.heartbeat"
"$TMP/bin/owner-heartbeat" "$takeover_heartbeat" "$takeover_token" &
takeover_owner_pid=$!
EXTRA_PIDS="$EXTRA_PIDS $takeover_owner_pid"
wait_for_file "$takeover_heartbeat" 80 0.025
takeover_owner="$(jq -cn --arg token "$takeover_token" --arg heartbeat "$takeover_heartbeat" \
  --argjson pid "$takeover_owner_pid" \
  '{schema_version:1,kind:"popup",pid:$pid,token:$token,heartbeat_path:$heartbeat}')"
takeover_ack="$(printf '%s\n' "$takeover_owner" | \
  run_ai control "$takeover_run_id" %1 takeover-owner req-takeover-owner)"
printf '%s' "$takeover_ack" | jq -e '
  .ok == true and .status == "acknowledged" and .action == "takeover-owner"
' >/dev/null || _fail_assert 'detached owner takeover was not acknowledged' 'result' "$takeover_ack"
jq -e --argjson expected "$takeover_owner" '. == $expected' \
  "$takeover_run_dir/owner.json" >/dev/null || _fail_assert 'takeover did not persist the exact owner lease'

set +e
second_takeover="$(printf '%s\n' "$takeover_owner" | \
  run_ai control "$takeover_run_id" %1 takeover-owner req-takeover-again)"
second_takeover_rc=$?
set -e
[ "$second_takeover_rc" -ne 0 ] || _fail_assert 'active run accepted a second owner takeover'
printf '%s' "$second_takeover" | jq -e \
  '.ok == false and .status == "invalid-state" and .action == "takeover-owner"' >/dev/null ||
  _fail_assert 'second owner takeover did not fail closed' 'result' "$second_takeover"
jq -e --argjson expected "$takeover_owner" '. == $expected' \
  "$takeover_run_dir/owner.json" >/dev/null || _fail_assert 'rejected takeover mutated the active owner'

kill -KILL "$takeover_owner_pid"
wait "$takeover_owner_pid" 2>/dev/null || true
wait_for_exit "$WATCHER_PID" 240 0.025
wait "$WATCHER_PID" 2>/dev/null || true
WATCHER_PID=""
assert_json "$takeover_run_dir/final.json" \
  '.outcome == "stopped" and (.reason | contains("owner PID"))'
printf 'PASS: detached run takeover binds the watcher to the new owner lease\n'

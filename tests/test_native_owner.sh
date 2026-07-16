#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir native-owner)"
WATCHER_PID=""

cleanup() {
  if [ -n "$WATCHER_PID" ]; then
    kill -TERM "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/bin" "$TMP/state"

cat > "$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    target="%1"
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -t ] && [ "$#" -gt 1 ]; then target="$2"; shift; fi
      shift
    done
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
printf '%s\n' '{"action":"wait","text":"","keys":[],"safe":true,"reason":"fixture wait","pane_state":"working","goal_status":"working","risk":"low","evidence":[]}'
SH
chmod +x "$TMP/bin/fake-brain"

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
  local goal="$1" config backend
  config="$(run_ai _build-watch-config %1 "$goal")"
  backend="$(run_ai doctor-json | jq -c '.backend')"
  config="$(printf '%s' "$config" | jq -c --argjson backend "$backend" '. + {backend:$backend}')"
  jq -cn \
    --arg state_root "$TMP/state" \
    --argjson config "$config" \
    '{protocol_version:1,config_schema_version:1,state_root:$state_root,
      target_pane:"%1",config:$config,owner:{schema_version:1,kind:"detached"}}'
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
cp "$watch_file" "$TMP/original.watch"
sed 's/^run_id=.*/run_id=replacement-run/; s/^generation=.*/generation=replacement-generation/' \
  "$TMP/original.watch" > "$TMP/replacement.watch"
mv "$TMP/replacement.watch" "$watch_file"
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
cp "$TMP/original.watch" "$watch_file"
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

#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir ai-events)"
EVENT_FILE=""
OLD_PATH="$PATH"
OLD_HOME="${HOME:-}"
cleanup() {
  local rc="${1:-$?}"
  PATH="$OLD_PATH"
  HOME="$OLD_HOME"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'cleanup $?' EXIT

assert_not_contains() {
  local haystack="$1" needle="$2" context="${3:-}"
  case "$haystack" in
    *"$needle"*)
      if [ -n "$context" ]; then
        _fail_assert "unexpected substring found ($context)" "needle" "$needle" "actual" "$haystack"
      fi
      _fail_assert "unexpected substring found" "needle" "$needle" "actual" "$haystack"
      ;;
  esac
}

assert_missing_or_empty() {
  local path="$1"
  if [ ! -e "$path" ] || [ ! -s "$path" ]; then
    return 0
  fi
  _fail_assert "expected file to be absent or empty" "file" "$path" "actual" "$(cat "$path")"
}

assert_file_same() {
  local left="$1" right="$2" context="${3:-}"
  cmp -s "$left" "$right" && return 0
  if [ -n "$context" ]; then
    _fail_assert "files differ ($context)" "left" "$left" "right" "$right" "left_contents" "$(cat "$left")" "right_contents" "$(cat "$right")"
  fi
  _fail_assert "files differ" "left" "$left" "right" "$right"
}

snake_event() {
  case "$1" in
    PermissionRequest) printf 'permission_request' ;;
    Stop) printf 'stop' ;;
    UserPromptSubmit) printf 'user_prompt_submit' ;;
    *) _fail_assert "unknown event for snake conversion" "event" "$1" ;;
  esac
}

write_fake_tmux() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$TEST_TMUX_CALLS"
cmd="${1:-}"
shift || true
case "$cmd" in
  list-sessions)
    exit 0
    ;;
  show-option)
    last=""
    for arg in "$@"; do
      last="$arg"
    done
    case "$last" in
      @radar-needinput) printf '%s\n' "${TEST_OPT_NEEDINPUT:-on}" ;;
      @switcher-needinput) printf '%s\n' "${TEST_OPT_NEEDINPUT:-on}" ;;
      @radar-retitle) printf '%s\n' "${TEST_OPT_RETITLE:-on}" ;;
      @switcher-retitle) printf '%s\n' "${TEST_OPT_RETITLE:-on}" ;;
      @radar-claude-bg) printf '%s\n' "${TEST_OPT_CLAUDE_BG:-on}" ;;
      @switcher-claude-bg) printf '%s\n' "${TEST_OPT_CLAUDE_BG:-on}" ;;
      @radar-bar-ttl) printf '%s\n' "${TEST_OPT_BAR_TTL:-60}" ;;
      @switcher-bar-ttl) printf '%s\n' "${TEST_OPT_BAR_TTL:-60}" ;;
      @radar-needinput-commands) printf '%s\n' "${TEST_OPT_NEEDINPUT_COMMANDS:-codex claude}" ;;
      @switcher-needinput-commands) printf '%s\n' "${TEST_OPT_NEEDINPUT_COMMANDS:-codex claude}" ;;
      *) exit 0 ;;
    esac
    ;;
  display-message)
    target="${TMUX_PANE:-%0}"
    format=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p)
          ;;
        -t)
          shift
          target="$1"
          ;;
        *)
          format="$1"
          ;;
      esac
      shift || true
    done
    case "$format" in
      '#{pane_id}') printf '%s\n' "$target" ;;
      '#{pane_title}')
        if [ -f "$TEST_PANE_TITLE_FILE" ]; then
          cat "$TEST_PANE_TITLE_FILE"
        else
          printf '%s\n' "${TEST_PANE_TITLE:-Original title}"
        fi
        ;;
      *) printf '%s\n' "${TEST_DISPLAY_MESSAGE:-test:0.0 codex}" ;;
    esac
    ;;
  select-pane)
    target=""
    title=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t)
          shift
          target="$1"
          ;;
        -T)
          shift
          title="$1"
          ;;
      esac
      shift || true
    done
    printf '%s\t%s\n' "$target" "$title" >> "$TEST_TMUX_TITLES"
    printf '%s\n' "$title" > "$TEST_PANE_TITLE_FILE"
    ;;
  set|refresh-client|wait-for|list-panes|kill-pane|split-window|send-keys)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
TMUXEOF
  chmod +x "$TMP/bin/tmux"
  printf '%s\n' 'tmux() { "$TEST_FAKE_TMUX" "$@"; }' > "$TMP/bashenv"
}

prepare_env() {
  mkdir -p "$TMP/home/.claude" "$TMP/home/.codex" "$TMP/state"
  export HOME="$TMP/home"
  export TEST_FAKE_TMUX="$TMP/bin/tmux"
  export BASH_ENV="$TMP/bashenv"
  export PATH="$TMP/bin:$OLD_PATH"
  export TMUX_RADAR_STATE_DIR="$TMP/state"
  export TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input"
  export CLAUDE_SETTINGS="$TMP/home/.claude/settings.json"
  export CODEX_CONFIG="$TMP/home/.codex/config.toml"
  export CODEX_HOOKS_JSON="$TMP/home/.codex/hooks.json"
  export TEST_TMUX_CALLS="$TMP/tmux.calls"
  export TEST_TMUX_TITLES="$TMP/tmux.titles"
  export TEST_PANE_TITLE_FILE="$TMP/pane-title"
  export TEST_OPT_NEEDINPUT=on
  export TEST_OPT_RETITLE=on
  export TEST_OPT_CLAUDE_BG=on
  export TEST_OPT_BAR_TTL=60
  export TEST_PANE_TITLE='Original title'
  : > "$TEST_TMUX_CALLS"
  : > "$TEST_TMUX_TITLES"
  : > "$TMUX_RADAR_NEEDINPUT_FILE"
  : > "$TMUX_RADAR_NEEDINPUT_FILE"
  printf '%s\n' "$TEST_PANE_TITLE" > "$TEST_PANE_TITLE_FILE"
  printf '{}\n' > "$CLAUDE_SETTINGS"
  printf 'notify = ["/usr/bin/existing-notify"]\n' > "$CODEX_CONFIG"
  printf '{"hooks":{}}\n' > "$CODEX_HOOKS_JSON"
}

reset_fake_tmux_logs() {
  : > "$TEST_TMUX_CALLS"
  : > "$TEST_TMUX_TITLES"
  : > "$TMUX_RADAR_NEEDINPUT_FILE"
  printf '%s\n' "$TEST_PANE_TITLE" > "$TEST_PANE_TITLE_FILE"
}

new_run() {
  local pane="$1" goal="$2"
  radar_run_create "$pane" "{\"goal\":\"$goal\"}"
}

drain_run_to_file() {
  local pane="$1" output="$2"
  radar_run_open "$pane" >/dev/null
  radar_inbox_drain > "$output"
}

expect_event_kind() {
  local path="$1" kind="$2" source="$3" output
  if output="$(jq -e 'select(.kind == "'"$kind"'" and .source == "'"$source"'" )' "$path" 2>&1)"; then
    return 0
  fi
  _fail_assert "json event assertion failed" "file" "$path" "kind" "$kind" "source" "$source" "jq" "$output" "actual" "$(cat "$path")"
}

trusted_hash_for_handler() {
  local event="$1" group_index="$2" handler_index="$3" snake
  snake="$(snake_event "$event")"
  jq -c --arg event "$event" --arg event_name "$snake" --argjson group_index "$group_index" --argjson handler_index "$handler_index" '
    .hooks[$event][$group_index] as $entry
    | $entry.hooks[$handler_index] as $hook
    | ({event_name:$event_name}
      + (if ($entry.matcher // "") != "" then {matcher:$entry.matcher} else {} end)
      + {hooks:[({type:"command", command:$hook.command, timeout:(($hook.timeout // 600) | if . < 1 then 1 else . end), async:false}
          + (if ($hook.statusMessage // "") != "" then {statusMessage:$hook.statusMessage} else {} end))]})
  ' "$CODEX_HOOKS_JSON" | jq -S -c '.' | shasum -a 256 | awk '{print "sha256:" $1}'
}

radar_position_for_event() {
  local event="$1" command="$2"
  jq -r --arg event "$event" --arg command "$command" '
    .hooks[$event]
    | to_entries[]
    | .key as $group
    | .value.hooks
    | to_entries[]
    | select(.value.type == "command" and .value.command == $command and .value.timeout == 5 and .value.statusMessage == "tmux-radar lifecycle bridge")
    | "\($group):\(.key)"
  ' "$CODEX_HOOKS_JSON"
}

seed_install_fixtures() {
  cat > "$CODEX_CONFIG" <<EOFCONF
notify = ["/usr/bin/existing-notify"]

[hooks.state."/tmp/unrelated/hooks.json:stop:0:0"]
trusted_hash = "sha256:keep-me"

# BEGIN tmux-radar Codex hooks
[[hooks.PermissionRequest]]
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '/old/radar/needinput-notify.sh codex-hook'

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = '/old/radar/needinput-notify.sh codex-hook'

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = '/old/radar/needinput-notify.sh codex-hook'

[hooks.state."/old/hooks.json:permission_request:0:0"]
trusted_hash = "sha256:old-radar"
# END tmux-radar Codex hooks
EOFCONF

  cat > "$CODEX_HOOKS_JSON" <<EOFJSON
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": "^omx",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/omx permission",
            "timeout": 5,
            "async": true,
            "statusMessage": "OMX permission"
          }
        ]
      },
      {
        "matcher": "^user-scope",
        "hooks": [
          {
            "type": "command",
            "command": "$ROOT/scripts/needinput-notify.sh codex-hook",
            "timeout": 77,
            "async": true,
            "statusMessage": "user-owned same command"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/omx stop"
          }
        ]
      },
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/user stop",
            "timeout": 9
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/usr/bin/user resume",
            "statusMessage": "resume"
          }
        ]
      }
    ]
  }
}
EOFJSON
}

write_fake_tmux
prepare_env
source "$ROOT/scripts/lib/ai-runtime.sh"

new_run %39 'emit event direct'
EVENT_FILE="$TMP/emit-event.json"
reset_fake_tmux_logs
if ! bash "$ROOT/scripts/ai.sh" emit-event %39 approval codex $'Line one\nLine two' >"$TMP/emit-event.out" 2>"$TMP/emit-event.err"; then
  _fail_assert "ai.sh emit-event should succeed for active runs" "stderr" "$(cat "$TMP/emit-event.err")"
fi
drain_run_to_file %39 "$EVENT_FILE"
expect_event_kind "$EVENT_FILE" approval codex
assert_eq 'Line one Line two' "$(jq -r '.label' "$EVENT_FILE")" "emit-event sanitizes label"
assert_contains "$(cat "$TEST_TMUX_CALLS")" 'wait-for -S radar-run-39' 'emit-event signals channel'

new_run %49 'old generation'
old_run_id="$RADAR_RUN_ID"
new_run %49 'new generation'
reset_fake_tmux_logs
TMUX_RADAR_EXPECT_RUN_ID="$old_run_id" \
  bash "$ROOT/scripts/ai.sh" emit-event %49 approval codex 'stale old-run event'
assert_eq '' "$(radar_run_open %49 >/dev/null; radar_inbox_drain)" 'stale event must not enter a replacement run'
assert_eq '' "$(cat "$TEST_TMUX_CALLS")" 'stale event must not signal a replacement run'

reset_fake_tmux_logs
if ! bash "$ROOT/scripts/ai.sh" emit-event %88 approval codex 'missing watch is benign' >"$TMP/emit-nowatch.out" 2>"$TMP/emit-nowatch.err"; then
  _fail_assert "missing watch should be a benign emit-event no-op" "stderr" "$(cat "$TMP/emit-nowatch.err")"
fi
assert_eq '' "$(cat "$TEST_TMUX_CALLS")" 'no signal for missing watch'

set +e
bash "$ROOT/scripts/ai.sh" emit-event %39 '' codex label >"$TMP/emit-bad.out" 2>"$TMP/emit-bad.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || _fail_assert 'malformed emit-event input must fail visibly'
assert_contains "$(cat "$TMP/emit-bad.err")" 'emit-event' 'emit-event invalid usage message'

set +e
bash "$ROOT/scripts/ai.sh" emit-event %39 approval codex >"$TMP/emit-missing-label.out" 2>"$TMP/emit-missing-label.err"
missing_label_rc=$?
set -e
[ "$missing_label_rc" -ne 0 ] || _fail_assert 'emit-event without a label must fail visibly'
assert_contains "$(cat "$TMP/emit-missing-label.err")" 'emit-event' 'missing-label usage message'

new_run %40 'codex permission event while marks disabled'
EVENT_FILE="$TMP/codex-permission-off.json"
reset_fake_tmux_logs
printf '%s' '{"hook_event_name":"PermissionRequest","tool_name":"exec_command","description":"Need approval\nnow"}' |
  TMUX_PANE=%40 TEST_OPT_NEEDINPUT=off bash "$ROOT/scripts/needinput-notify.sh" codex-hook
drain_run_to_file %40 "$EVENT_FILE"
expect_event_kind "$EVENT_FILE" approval codex
assert_eq 'Codex needs approval: exec_command' "$(jq -r '.label' "$EVENT_FILE")" 'permission label'
assert_not_contains "$(cat "$EVENT_FILE")" 'tool_name' 'raw hook payload omitted'
assert_not_contains "$(cat "$EVENT_FILE")" 'description' 'raw hook payload omitted'
assert_missing_or_empty "$TMUX_RADAR_NEEDINPUT_FILE"
assert_contains "$(cat "$TEST_TMUX_CALLS")" 'wait-for -S radar-run-40' 'permission signal while marks disabled'

new_run %41 'codex stop event'
EVENT_FILE="$TMP/codex-stop.json"
reset_fake_tmux_logs
printf '%s' '{"hook_event_name":"Stop"}' |
  TMUX_PANE=%41 bash "$ROOT/scripts/needinput-notify.sh" codex-hook
drain_run_to_file %41 "$EVENT_FILE"
expect_event_kind "$EVENT_FILE" turn_complete codex
assert_contains "$(cat "$TMUX_RADAR_NEEDINPUT_FILE")" 'Codex finished - your turn' 'stop keeps done mark'
assert_not_contains "$(cat "$TMUX_RADAR_NEEDINPUT_FILE")" 'needs approval' 'stop is not action mark'

new_run %42 'codex user resumed'
EVENT_FILE="$TMP/codex-resumed.json"
reset_fake_tmux_logs
TMUX_PANE=%42 bash "$ROOT/scripts/needinput-notify.sh" mark %42 codex 'Codex needs approval'
[ -s "$TMUX_RADAR_NEEDINPUT_FILE" ] || _fail_assert 'expected pre-existing mark before user resume'
printf '%s' '{"hook_event_name":"UserPromptSubmit"}' |
  TMUX_PANE=%42 bash "$ROOT/scripts/needinput-notify.sh" codex-hook
drain_run_to_file %42 "$EVENT_FILE"
expect_event_kind "$EVENT_FILE" user_resumed codex
assert_missing_or_empty "$TMUX_RADAR_NEEDINPUT_FILE"
assert_contains "$(cat "$TEST_TMUX_TITLES")" $'%42\tOriginal title' 'user resume restores pane title'

new_run %43 'claude notification mapping'
EVENT_FILE="$TMP/claude-notification.json"
reset_fake_tmux_logs
printf '%s' '{"session_id":"claude-s1","cwd":"/tmp/project","message":"Claude needs input\nsoon"}' |
  TMUX_PANE=%43 bash "$ROOT/scripts/needinput-notify.sh" claude-mark
drain_run_to_file %43 "$EVENT_FILE"
expect_event_kind "$EVENT_FILE" input_required claude
assert_eq 'Claude needs input soon' "$(jq -r '.label' "$EVENT_FILE")" 'claude notification label sanitized'
assert_contains "$(cat "$TMUX_RADAR_NEEDINPUT_FILE")" 'Claude needs input soon' 'claude action mark preserved'

new_run %44 'claude stop mapping'
EVENT_FILE="$TMP/claude-stop.json"
reset_fake_tmux_logs
printf '%s' '{"session_id":"claude-s2","cwd":"/tmp/project"}' |
  TMUX_PANE=%44 bash "$ROOT/scripts/needinput-notify.sh" claude-stop
drain_run_to_file %44 "$EVENT_FILE"
expect_event_kind "$EVENT_FILE" turn_complete claude
assert_contains "$(cat "$TMUX_RADAR_NEEDINPUT_FILE")" 'finished' 'claude done mark preserved'

new_run %45 'claude clear mapping'
EVENT_FILE="$TMP/claude-clear.json"
reset_fake_tmux_logs
printf '%s' '{"session_id":"claude-s3","cwd":"/tmp/project","message":"Claude waiting"}' |
  TMUX_PANE=%45 bash "$ROOT/scripts/needinput-notify.sh" claude-mark
printf '%s' '{"session_id":"claude-s3","cwd":"/tmp/project"}' |
  TMUX_PANE=%45 bash "$ROOT/scripts/needinput-notify.sh" claude-clear
drain_run_to_file %45 "$EVENT_FILE"
expect_event_kind "$EVENT_FILE" user_resumed claude
assert_missing_or_empty "$TMUX_RADAR_NEEDINPUT_FILE"

new_run %46 'claude background is paneless'
reset_fake_tmux_logs
printf '%s' '{"session_id":"claude-bg","cwd":"/tmp/project","message":"Background notice"}' |
  env -u TMUX_PANE CLAUDE_JOB_DIR=/tmp/bg-job TEST_OPT_CLAUDE_BG=on PATH="$PATH" HOME="$HOME" TMUX_RADAR_STATE_DIR="$TMUX_RADAR_STATE_DIR" TMUX_RADAR_NEEDINPUT_FILE="$TMUX_RADAR_NEEDINPUT_FILE" TEST_TMUX_CALLS="$TEST_TMUX_CALLS" TEST_TMUX_TITLES="$TEST_TMUX_TITLES" TEST_OPT_NEEDINPUT=on TEST_OPT_RETITLE=on bash "$ROOT/scripts/needinput-notify.sh" claude-mark
assert_eq '' "$(radar_run_open %46 >/dev/null; radar_inbox_drain)" 'paneless background event should not enter pane watcher'
assert_contains "$(cat "$TMUX_RADAR_NEEDINPUT_FILE")" $'-\t' 'paneless mark retained'
assert_contains "$(cat "$TMUX_RADAR_NEEDINPUT_FILE")" 's:claude-bg' 'paneless mark key retained'

legacy_types='request_user_input:input_required exec_approval_request:approval apply_patch_approval_request:approval request_permissions:approval agent-turn-complete:turn_complete task_complete:turn_complete turn_complete:turn_complete'
for mapping in $legacy_types; do
  type="${mapping%%:*}"
  kind="${mapping##*:}"
  pane="%47"
  new_run "$pane" "legacy $type"
  EVENT_FILE="$TMP/legacy-$type.json"
  reset_fake_tmux_logs
  TMUX_PANE="$pane" bash "$ROOT/scripts/needinput-notify.sh" codex "{\"type\":\"$type\"}"
  drain_run_to_file "$pane" "$EVENT_FILE"
  expect_event_kind "$EVENT_FILE" "$kind" codex
done

new_run %48 'internal suppression'
EVENT_FILE="$TMP/internal-suppression.json"
reset_fake_tmux_logs
if ! printf '%s' '{"hook_event_name":"PermissionRequest","tool_name":"exec_command"}' |
  TMUX_RADAR_INTERNAL=1 TMUX_PANE=%48 bash "$ROOT/scripts/needinput-notify.sh" codex-hook; then
  _fail_assert 'internal suppression hook should still zero-exit'
fi
assert_eq '' "$(radar_run_open %48 >/dev/null; radar_inbox_drain)" 'internal suppression emits no inbox event'
assert_missing_or_empty "$TMUX_RADAR_NEEDINPUT_FILE"
assert_eq '' "$(cat "$TEST_TMUX_CALLS")" 'internal suppression does not touch tmux'

internal_empty_state="$TMP/internal-state-missing"
printf '%s' '{"hook_event_name":"Stop"}' |
  TMUX_RADAR_INTERNAL=1 TMUX_RADAR_STATE_DIR="$internal_empty_state" TMUX_PANE=%48 \
  bash "$ROOT/scripts/needinput-notify.sh" codex-hook
[ ! -e "$internal_empty_state" ] || _fail_assert 'internal hook must not create a state directory' 'path' "$internal_empty_state"

seed_install_fixtures
cp "$CODEX_CONFIG" "$TMP/config.before.install"
cp "$CODEX_HOOKS_JSON" "$TMP/hooks.before.install"
install_output_one="$(bash "$ROOT/scripts/install-hooks.sh" install 2>&1)"
install_output_two="$(bash "$ROOT/scripts/install-hooks.sh" install 2>&1)"
status_output="$(bash "$ROOT/scripts/install-hooks.sh" status 2>&1)"
radar_command="$ROOT/scripts/needinput-notify.sh codex-hook"

assert_json "$CODEX_HOOKS_JSON" '.hooks.PermissionRequest[0].matcher == "^omx"'
assert_json "$CODEX_HOOKS_JSON" '.hooks.Stop[0].hooks[0].command == "/usr/bin/omx stop"'
assert_json "$CODEX_HOOKS_JSON" '.hooks.UserPromptSubmit[0].hooks[0].command == "/usr/bin/user resume"'
assert_eq '3' "$(jq -r --arg command "$radar_command" '[.hooks.PermissionRequest[], .hooks.Stop[], .hooks.UserPromptSubmit[] | .hooks[] | select(.type == "command" and .command == $command and .timeout == 5 and .statusMessage == "tmux-radar lifecycle bridge")] | length' "$CODEX_HOOKS_JSON")" 'radar native handlers installed exactly once per event'
assert_json "$CODEX_HOOKS_JSON" '[.hooks.PermissionRequest[] | select(.matcher == "^user-scope") | .hooks[] | select(.command == "'"$radar_command"'" and .timeout == 77 and .statusMessage == "user-owned same command")] | length == 1'
assert_not_contains "$(cat "$CODEX_CONFIG")" '[[hooks.PermissionRequest]]' 'no radar native arrays remain in toml'
assert_not_contains "$(cat "$CODEX_CONFIG")" '[[hooks.Stop]]' 'no radar native arrays remain in toml'
assert_not_contains "$(cat "$CODEX_CONFIG")" '[[hooks.UserPromptSubmit]]' 'no radar native arrays remain in toml'
assert_contains "$(cat "$CODEX_CONFIG")" 'notify = [' 'legacy notify fallback preserved'
assert_not_contains "$(cat "$CODEX_CONFIG")" 'Codex notify' 'installer diagnostics must not enter config.toml'
assert_contains "$install_output_one" 'PermissionRequest' 'install reports native coverage'
assert_contains "$install_output_one" 'UserPromptSubmit' 'install reports native coverage'
assert_contains "$status_output" 'PermissionRequest' 'status reports PermissionRequest'
assert_contains "$status_output" 'Stop' 'status reports Stop'
assert_contains "$status_output" 'UserPromptSubmit' 'status reports UserPromptSubmit'
assert_contains "$status_output" 'legacy notify fallback' 'status reports notify fallback'
assert_not_contains "$install_output_two" 'already integrated already integrated' 'second install remains stable'

for event in PermissionRequest Stop UserPromptSubmit; do
  position="$(radar_position_for_event "$event" "$radar_command")"
  [ -n "$position" ] || _fail_assert 'expected radar handler position in hooks.json' 'event' "$event"
  group_index="${position%%:*}"
  handler_index="${position##*:}"
  snake="$(snake_event "$event")"
  trust_key="$CODEX_HOOKS_JSON:$snake:$group_index:$handler_index"
  trust_hash="$(trusted_hash_for_handler "$event" "$group_index" "$handler_index")"
  assert_contains "$(cat "$CODEX_CONFIG")" "[hooks.state.\"$trust_key\"]" "trust state key for $event"
  assert_contains "$(cat "$CODEX_CONFIG")" "trusted_hash = \"$trust_hash\"" "trust state hash for $event"
done

bash "$ROOT/scripts/install-hooks.sh" uninstall >"$TMP/uninstall.out" 2>"$TMP/uninstall.err"
assert_eq '0' "$(jq -r --arg command "$radar_command" '[.hooks.PermissionRequest[], .hooks.Stop[], .hooks.UserPromptSubmit[] | .hooks[] | select(.type == "command" and .command == $command and .timeout == 5 and .statusMessage == "tmux-radar lifecycle bridge")] | length' "$CODEX_HOOKS_JSON")" 'uninstall removes only radar-owned handlers'
assert_json "$CODEX_HOOKS_JSON" '[.hooks.PermissionRequest[] | select(.matcher == "^user-scope") | .hooks[] | select(.command == "'"$radar_command"'" and .timeout == 77 and .statusMessage == "user-owned same command")] | length == 1'
assert_json "$CODEX_HOOKS_JSON" '.hooks.PermissionRequest[0].hooks[0].command == "/usr/bin/omx permission"'
assert_contains "$(cat "$CODEX_CONFIG")" 'sha256:keep-me' 'unrelated trust entry preserved'
assert_not_contains "$(cat "$CODEX_CONFIG")" '/old/hooks.json:permission_request:0:0' 'stale radar trust removed'
assert_not_contains "$(cat "$CODEX_CONFIG")" "$CODEX_HOOKS_JSON:permission_request" 'managed radar trust removed'
assert_contains "$(cat "$CODEX_CONFIG")" 'notify = ["/usr/bin/existing-notify"]' 'uninstall restores the existing notify chain'
assert_not_contains "$(cat "$CODEX_CONFIG")" "$ROOT/scripts/codex-notify-wrap.sh" 'uninstall removes only the radar wrapper'

isolated_hooks="$TMP/home/.codex/hooks-without-config.json"
isolated_config="$TMP/home/.codex/config-does-not-exist.toml"
cat > "$isolated_hooks" <<EOFJSON
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$radar_command","timeout":5,"statusMessage":"tmux-radar lifecycle bridge"}]},{"hooks":[{"type":"command","command":"/usr/bin/user-stop"}]}]}}
EOFJSON
rm -f "$isolated_config"
CODEX_CONFIG="$isolated_config" CODEX_HOOKS_JSON="$isolated_hooks" \
  bash "$ROOT/scripts/install-hooks.sh" uninstall >"$TMP/uninstall-no-config.out" 2>"$TMP/uninstall-no-config.err"
assert_json "$isolated_hooks" '[.hooks.Stop[]?.hooks[]? | select(.command == "'"$radar_command"'")] | length == 0'
assert_json "$isolated_hooks" '[.hooks.Stop[]?.hooks[]? | select(.command == "/usr/bin/user-stop")] | length == 1'
[ ! -e "$isolated_config" ] || _fail_assert 'uninstall created a missing config.toml' 'file' "$isolated_config"

printf 'notify = ["%s", "codex", "custom-user-argument"]\n' "$ROOT/scripts/needinput-notify.sh" > "$CODEX_CONFIG"
bash "$ROOT/scripts/install-hooks.sh" uninstall >"$TMP/uninstall-modified.out" 2>"$TMP/uninstall-modified.err"
assert_contains "$(cat "$CODEX_CONFIG")" 'custom-user-argument' 'modified direct notify is preserved'
assert_contains "$(cat "$CODEX_CONFIG")" "$ROOT/scripts/needinput-notify.sh" 'modified direct radar notify is not destructively removed'

printf '%s\n' '{not valid json' > "$CODEX_HOOKS_JSON"
cp "$CODEX_CONFIG" "$TMP/config.before.bad"
cp "$CODEX_HOOKS_JSON" "$TMP/hooks.before.bad"
set +e
bash "$ROOT/scripts/install-hooks.sh" install >"$TMP/bad-install.out" 2>"$TMP/bad-install.err"
bad_rc=$?
set -e
[ "$bad_rc" -ne 0 ] || _fail_assert 'malformed hooks.json install must fail visibly'
assert_contains "$(cat "$TMP/bad-install.err")" 'hooks.json' 'malformed hooks.json error mentions file'
assert_file_same "$CODEX_CONFIG" "$TMP/config.before.bad" 'config unchanged after malformed hooks.json'
assert_file_same "$CODEX_HOOKS_JSON" "$TMP/hooks.before.bad" 'hooks.json unchanged after malformed hooks.json'

missing_config="$TMP/home/.codex/missing-config.toml"
rm -f "$missing_config"
set +e
CODEX_CONFIG="$missing_config" bash "$ROOT/scripts/install-hooks.sh" install >"$TMP/bad-missing-config.out" 2>"$TMP/bad-missing-config.err"
bad_missing_config_rc=$?
set -e
[ "$bad_missing_config_rc" -ne 0 ] || _fail_assert 'malformed hooks.json must fail before creating config.toml'
[ ! -e "$missing_config" ] || _fail_assert 'malformed hooks.json created an unrelated config file' 'file' "$missing_config"

seed_install_fixtures
printf '%s\n' '{invalid claude settings' > "$CLAUDE_SETTINGS"
cp "$CODEX_CONFIG" "$TMP/config.before-transaction-failure"
cp "$CODEX_HOOKS_JSON" "$TMP/hooks.before-transaction-failure"
set +e
bash "$ROOT/scripts/install-hooks.sh" install >"$TMP/transaction-failure.out" 2>"$TMP/transaction-failure.err"
transaction_failure_rc=$?
set -e
[ "$transaction_failure_rc" -ne 0 ] || _fail_assert 'invalid Claude settings must fail the full hook transaction'
assert_file_same "$CODEX_CONFIG" "$TMP/config.before-transaction-failure" 'Codex config rolled back after downstream Claude failure'
assert_file_same "$CODEX_HOOKS_JSON" "$TMP/hooks.before-transaction-failure" 'Codex hooks rolled back after downstream Claude failure'

seed_install_fixtures
printf '%s\n' '{}' > "$CLAUDE_SETTINGS"
bash "$ROOT/scripts/install-hooks.sh" install >"$TMP/transaction-uninstall-setup.out" 2>"$TMP/transaction-uninstall-setup.err"
printf '%s\n' '{invalid claude settings' > "$CLAUDE_SETTINGS"
cp "$CODEX_CONFIG" "$TMP/config.before-uninstall-failure"
cp "$CODEX_HOOKS_JSON" "$TMP/hooks.before-uninstall-failure"
set +e
bash "$ROOT/scripts/install-hooks.sh" uninstall >"$TMP/transaction-uninstall-failure.out" 2>"$TMP/transaction-uninstall-failure.err"
transaction_uninstall_failure_rc=$?
set -e
[ "$transaction_uninstall_failure_rc" -ne 0 ] || _fail_assert 'invalid Claude settings must fail the full uninstall transaction'
assert_file_same "$CODEX_CONFIG" "$TMP/config.before-uninstall-failure" 'Codex config rolled back after downstream Claude uninstall failure'
assert_file_same "$CODEX_HOOKS_JSON" "$TMP/hooks.before-uninstall-failure" 'Codex hooks rolled back after downstream Claude uninstall failure'

printf 'PASS: ai hook events and codex hook installation\n'

#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir ai-console)"
OLD_PATH="$PATH"
FAILURES=0

cleanup() {
  local rc="${1:-$?}"
  PATH="$OLD_PATH"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'cleanup $?' EXIT

write_fake_tmux() {
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
set -eu
cmd="${1:-}"
shift || true
case "$cmd" in
  list-sessions)
    exit 0
    ;;
  show-option)
    key=""
    for arg in "$@"; do key="$arg"; done
    case "$key" in
      @radar-ai-poll|@switcher-ai-poll) printf '%s\n' 17 ;;
      *) exit 0 ;;
    esac
    ;;
  display-message)
    case "$*" in
      *pane_id*) printf '%s\n' '%39' ;;
      *) printf '%s\n' 'test:0.0 codex' ;;
    esac
    ;;
  display-menu)
    printf '%s\n' "$@" > "$TEST_TMUX_MENU_ARGS"
    ;;
  *)
    exit 0
    ;;
esac
TMUXEOF
  chmod +x "$TMP/bin/tmux"
  printf '%s\n' 'tmux() { "$TEST_FAKE_TMUX" "$@"; }' > "$TMP/bashenv"
}

run_ai() {
  PATH="$TMP/bin:$OLD_PATH" \
    BASH_ENV="$TMP/bashenv" \
    TEST_FAKE_TMUX="$TMP/bin/tmux" \
    TEST_TMUX_MENU_ARGS="$TMP/menu.args" \
    TMUX_RADAR_STATE_DIR="$TMP/state" \
    TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
    bash "$ROOT/scripts/ai.sh" "$@"
}

run_test() {
  local name="$1" test_fn="$2" output rc
  set +e
  output="$($test_fn 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'PASS: %s\n' "$name"
    return 0
  fi
  FAILURES=$((FAILURES + 1))
  printf 'FAIL: %s\n' "$name" >&2
  while IFS= read -r line; do
    printf '  %s\n' "$line" >&2
  done <<< "$output"
}

menu_action_for_key() {
  local key="$1"
  awk -v key="$key" '$0 == key { getline; print; exit }' "$TMP/menu.args"
}

test_decode_goal_preserves_cjk_and_whitespace() {
  local goal decoded
  goal=$'  允许继续\t直到测试全绿  '
  decoded="$(run_ai _decode-goal "$goal")"
  assert_eq $'quick\t  允许继续\t直到测试全绿  ' "$decoded" \
    '_decode-goal preserves exact CJK and whitespace'
}

test_decode_goal_detects_advanced_sentinel() {
  local goal decoded
  goal=$' 允许到测试全绿 \t__RADAR_ADVANCED__'
  decoded="$(run_ai _decode-goal "$goal")"
  assert_eq $'advanced\t 允许到测试全绿 \t' "$decoded" \
    '_decode-goal strips only the advanced sentinel'
}

test_build_watch_config_contains_all_settings_and_provenance() {
  local config_file="$TMP/full-config.json"
  TMUX_RADAR_SETUP_OVERRIDES='timeout=45,logging=full' \
    TMUX_RADAR_RUNTIME_OVERRIDES='monitor_width=52' \
    run_ai _build-watch-config %39 '允许到测试全绿' > "$config_file"

  assert_json "$config_file" '
    (keys == ["goal", "pane", "values"]) and
    (.goal == "允许到测试全绿") and
    (.pane == "%39") and
    (.values | keys == [
      "always_allow",
      "approval_policy",
      "autonomy",
      "capture_lines",
      "command",
      "completion_close_delay",
      "effort",
      "goal",
      "hooks_first",
      "logging",
      "max_decisions",
      "model",
      "monitor_excerpt_lines",
      "monitor_position",
      "monitor_width",
      "overview_ratio",
      "poll",
      "profile",
      "retention_days",
      "retry_backoff",
      "retry_limit",
      "screen_snapshots",
      "stable_screen_threshold",
      "timeout"
    ]) and
    ([.values[] | ((keys == ["source", "value"]) and
      (.source | IN("default", "tmux", "custom", "runtime")))] | all) and
    (.values.goal == {value:"允许到测试全绿", source:"custom"}) and
    (.values.poll == {value:17, source:"tmux"}) and
    (.values.model == {value:"gpt-5.6-luna", source:"default"}) and
    (.values.completion_close_delay == {value:12, source:"default"}) and
    (.values.timeout == {value:45, source:"custom"}) and
    (.values.logging == {value:"full", source:"custom"}) and
    (.values.completion_close_delay == {value:12, source:"default"}) and
    (.values.monitor_width == {value:52, source:"runtime"}) and
    ([.values[].source] | unique == ["custom", "default", "runtime", "tmux"])
  '
}

test_invalid_numeric_overrides_retain_effective_values() {
  local config_file="$TMP/rejected-config.json" errors="$TMP/rejected.err"
  TMUX_RADAR_SETUP_OVERRIDES='poll=abc,timeout=0,retry_limit=-1' \
    run_ai _build-watch-config %39 'keep going' > "$config_file" 2> "$errors"

  assert_json "$config_file" '
    (.values.poll == {value:17, source:"tmux"}) and
    (.values.timeout == {value:120, source:"default"}) and
    (.values.retry_limit == {value:3, source:"default"})
  '
}

test_invalid_numeric_overrides_surface_rejections() {
  local errors="$TMP/rejection-messages.err"
  TMUX_RADAR_SETUP_OVERRIDES='poll=abc,timeout=0,retry_limit=-1' \
    run_ai _build-watch-config %39 'keep going' > /dev/null 2> "$errors"

  assert_contains "$(cat "$errors")" 'rejected' 'numeric rejection is explicit'
  assert_contains "$(cat "$errors")" 'poll=abc' 'poll rejection identifies input'
  assert_contains "$(cat "$errors")" 'timeout=0' 'timeout rejection identifies input'
  assert_contains "$(cat "$errors")" 'retry_limit=-1' 'retry rejection identifies input'
}

test_menu_routes_w_to_quick_setup() {
  local action
  run_ai menu
  action="$(menu_action_for_key w)"
  assert_contains "$action" 'watch-setup' 'w uses shared setup flow'
  assert_contains "$action" "'#{pane_id}' quick" 'w selects quick mode'
  case "$action" in
    *always-allow*) _fail_assert 'w must not preset always-allow' 'actual' "$action" ;;
  esac
}

test_menu_routes_W_to_quick_setup_with_always_allow() {
  local action
  run_ai menu
  action="$(menu_action_for_key W)"
  assert_contains "$action" 'watch-setup' 'W uses shared setup flow'
  assert_contains "$action" "'#{pane_id}' quick always-allow" \
    'W selects quick mode with always-allow preset'
}

test_menu_routes_v_to_advanced_setup() {
  local action
  run_ai menu
  action="$(menu_action_for_key v)"
  assert_contains "$action" 'watch-setup' 'v uses shared setup flow'
  assert_contains "$action" "'#{pane_id}' advanced" 'v selects advanced mode'
}

test_blank_goal_uses_explicit_default() {
  local config_file="$TMP/default-goal.json"
  run_ai _build-watch-config %39 '' > "$config_file"
  assert_json "$config_file" '
    (.goal == "推进当前任务直到完成") and
    (.values.goal == {value:"推进当前任务直到完成", source:"default"})
  '
}

test_quick_goal_reaches_config_byte_for_byte() {
  local original="$TMP/original-goal" actual="$TMP/config-goal" decoded mode goal
  goal=$'  修复中文\tspacing\n保留尾随空格  '
  printf '%s' "$goal" > "$original"

  decoded="$(run_ai _decode-goal "$goal")"
  mode="${decoded%%$'\t'*}"
  goal="${decoded#*$'\t'}"
  assert_eq quick "$mode" 'ordinary goal remains on quick path'

  run_ai _build-watch-config %39 "$goal" | jq -j '.goal' > "$actual"
  if ! cmp -s "$original" "$actual"; then
    _fail_assert 'quick goal bytes changed before config' \
      'expected_hex' "$(od -An -tx1 "$original" | tr -d ' \n')" \
      'actual_hex' "$(od -An -tx1 "$actual" | tr -d ' \n')"
  fi
}

test_decode_goal_preserves_terminal_newlines_before_sentinel() {
  local original="$TMP/sentinel-goal" expected="$TMP/sentinel-expected" actual="$TMP/sentinel-actual"
  printf '%s' $' \n\t继续\n' > "$original"
  {
    printf 'advanced\t'
    cat "$original"
  } > "$expected"

  run_ai _decode-goal $' \n\t继续\n__RADAR_ADVANCED__' > "$actual"
  if ! cmp -s "$expected" "$actual"; then
    _fail_assert '_decode-goal changed bytes before terminal sentinel' \
      'expected_hex' "$(od -An -tx1 "$expected" | tr -d ' \n')" \
      'actual_hex' "$(od -An -tx1 "$actual" | tr -d ' \n')"
  fi
}

test_advanced_summary_lists_every_group_field_and_provenance() {
  local config summary key
  config="$(TMUX_RADAR_SETUP_OVERRIDES='timeout=45,logging=full' \
    run_ai _build-watch-config %39 'summary goal')"
  summary="$(run_ai _render-watch-config "$config")"
  for key in Intent Authority Triggering Brain Budget Context Console Logging; do
    assert_contains "$summary" "$key" "advanced summary contains $key group"
  done
  for key in goal autonomy approval_policy always_allow hooks_first poll \
    stable_screen_threshold command profile model effort timeout max_decisions \
    retry_limit retry_backoff capture_lines monitor_excerpt_lines monitor_position \
    monitor_width overview_ratio completion_close_delay logging screen_snapshots retention_days; do
    assert_contains "$summary" "$key" "advanced summary contains $key"
  done
  assert_contains "$summary" '[custom]' 'advanced summary shows custom provenance'
  assert_contains "$summary" '[tmux]' 'advanced summary shows tmux provenance'
}

test_config_reaches_run_config_and_runtime_without_codex() {
  local config_file="$TMP/launch-config.json" runtime_file="$TMP/runtime.json" run_config
  TMUX_RADAR_SETUP_OVERRIDES='autonomy=suggest,approval_policy=manual,always_allow=on,hooks_first=off,poll=23,stable_screen_threshold=4,command=fake-backend,profile=qa,model=gpt-test,effort=high,timeout=45,max_decisions=9,retry_limit=2,retry_backoff=7,capture_lines=77,monitor_excerpt_lines=11,monitor_position=bottom,monitor_width=66,overview_ratio=30,completion_close_delay=8,logging=full,screen_snapshots=on,retention_days=13' \
    run_ai _build-watch-config %39 $'  launch\ngoal  \n' > "$config_file"

  TMUX_RADAR_TEST_EXIT_AFTER_CONFIG=1 \
    TMUX_RADAR_TEST_RUNTIME_FILE="$runtime_file" \
    run_ai _watch_loop %39 '' '' '' '' "$(cat "$config_file")"
  run_config="$(find "$TMP/state/ai-runs" -name config.json -type f -print -quit)"
  assert_file "$run_config"
  assert_json "$run_config" '
    (.goal == "  launch\ngoal  \n") and
    (.values.model == {value:"gpt-test",source:"custom"}) and
    (.values.timeout == {value:45,source:"custom"}) and
    (.values.max_decisions == {value:9,source:"custom"}) and
    (.values.screen_snapshots == {value:"on",source:"custom"}) and
    (.values.retention_days == {value:13,source:"custom"})
  '
  assert_json "$runtime_file" '
    .goal == "  launch\ngoal  \n" and .autonomy == "suggest" and
    .approval_policy == "manual" and .always_allow == "on" and
    .hooks_first == "off" and .poll == 23 and .stable_screen_threshold == 4 and
    .command == "fake-backend" and .profile == "qa" and .model == "gpt-test" and
    .effort == "high" and .timeout == 45 and .max_decisions == 9 and
    .retry_limit == 2 and .retry_backoff == 7 and .capture_lines == 77 and
    .monitor_excerpt_lines == 11 and .monitor_position == "bottom" and
    .monitor_width == 66 and .overview_ratio == 30 and
    .completion_close_delay == 8 and .logging == "full" and
    .screen_snapshots == "on" and .retention_days == 13
  '
}

write_fake_tmux
mkdir -p "$TMP/state"

run_test '_decode-goal preserves CJK and whitespace' test_decode_goal_preserves_cjk_and_whitespace
run_test '_decode-goal detects advanced sentinel' test_decode_goal_detects_advanced_sentinel
run_test '_build-watch-config represents every setting and provenance' test_build_watch_config_contains_all_settings_and_provenance
run_test 'invalid numeric overrides retain previous effective values' test_invalid_numeric_overrides_retain_effective_values
run_test 'invalid numeric overrides surface rejection details' test_invalid_numeric_overrides_surface_rejections
run_test 'menu routes w to quick setup' test_menu_routes_w_to_quick_setup
run_test 'menu routes W to quick setup with always-allow' test_menu_routes_W_to_quick_setup_with_always_allow
run_test 'menu routes v to advanced setup' test_menu_routes_v_to_advanced_setup
run_test 'blank goal uses explicit default' test_blank_goal_uses_explicit_default
run_test 'quick goal reaches config byte-for-byte' test_quick_goal_reaches_config_byte_for_byte
run_test '_decode-goal preserves terminal newlines before sentinel' test_decode_goal_preserves_terminal_newlines_before_sentinel
run_test 'advanced summary lists all grouped fields and provenance' test_advanced_summary_lists_every_group_field_and_provenance
run_test 'immutable config reaches run config and per-run runtime' test_config_reaches_run_config_and_runtime_without_codex

if [ "$FAILURES" -ne 0 ]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'PASS: all AI console tests\n'

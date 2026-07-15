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
      *client_width*) printf '%s\n' 80 ;;
      *client_height*) printf '%s\n' 24 ;;
      *pane_width*) printf '%s\n' "${TEST_PANE_WIDTH:-284}" ;;
      *pane_height*) printf '%s\n' "${TEST_PANE_HEIGHT:-54}" ;;
      *pane_id*) printf '%s\n' '%39' ;;
      *) printf '%s\n' 'test:0.0 codex' ;;
    esac
    ;;
  display-menu)
    printf '%s\n' "$@" > "$TEST_TMUX_MENU_ARGS"
    ;;
  split-window)
    printf 'split-window %s\n' "$*" >> "$TEST_TMUX_CALLS"
    n="$(cat "$TEST_TMUX_SPLIT_COUNT" 2>/dev/null || printf 90)"
    n=$((n + 1)); printf '%s\n' "$n" > "$TEST_TMUX_SPLIT_COUNT"
    printf '%%%s\n' "$n"
    ;;
  display-popup|select-pane|kill-pane|wait-for|capture-pane)
    printf '%s %s\n' "$cmd" "$*" >> "$TEST_TMUX_CALLS"
    [ "$cmd" != capture-pane ] || printf 'target line one\ntarget line two\n'
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
    TEST_TMUX_CALLS="$TMP/tmux.calls" \
    TEST_TMUX_SPLIT_COUNT="$TMP/split.count" \
    TEST_PANE_WIDTH="${TEST_PANE_WIDTH:-284}" \
    TEST_PANE_HEIGHT="${TEST_PANE_HEIGHT:-54}" \
    TMUX_RADAR_REUSE_POPUP="${TMUX_RADAR_REUSE_POPUP:-0}" \
    TMUX_RADAR_TEST_MONITOR_ONCE="${TMUX_RADAR_TEST_MONITOR_ONCE:-0}" \
    TMUX_RADAR_STATE_DIR="$TMP/state" \
    TMUX_RADAR_NEEDINPUT_FILE="$TMP/state/need-input" \
    bash "$ROOT/scripts/ai.sh" "$@"
}

seed_monitor_run() {
  local config run_dir="$TMP/state/ai-runs/test-run" wf="$TMP/state/ai-watch/_39.watch"
  rm -rf "$run_dir"; mkdir -p "$run_dir/inbox" "$run_dir/backend"
  config="$(run_ai _build-watch-config %39 '监控到测试全绿')"
  printf '%s\n' "$config" | jq -c '. + {run_id:"test-run",created_at:"2026-07-13T00:00:00Z"}' > "$run_dir/config.json"
  printf '%s\n' '{"phase":"ARMED","status":"waiting for native event","next":{"kind":"idle","at":0},"goal":"监控到测试全绿","policy":"safe-auto","autonomy":"auto-safe","poll":5,"calls":1,"max_calls":40,"retry":0}' > "$run_dir/state.json"
  printf '%s\n' '{"timestamp":"2026-07-13T00:00:01Z","record":"incoming","kind":"approval","source":"codex","label":"permission requested"}' > "$run_dir/events.jsonl"
  mkdir -p "$(dirname "$wf")"
  cat > "$wf" <<EOF
run_id=test-run
run_dir=$run_dir
pid=$$
pane=%39
channel=radar-run-39
monitor_overview_pane=
monitor_detail_pane=
started=$(date '+%s')
EOF
  printf '%s\n' 90 > "$TMP/split.count"
  : > "$TMP/tmux.calls"
}

clear_layout_calls() {
  printf '%s\n' 90 > "$TMP/split.count"
  : > "$TMP/tmux.calls"
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
    (.values.effort == {value:"high", source:"default"}) and
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
  assert_contains "$action" 'display-popup -E -w 90% -h 85%' 'w reserves a full supervision setup console'
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
  assert_contains "$action" 'display-popup -E -w 90% -h 85%' 'W reserves a full supervision setup console'
  assert_contains "$action" "'#{pane_id}' quick always-allow" \
    'W selects quick mode with always-allow preset'
}

test_menu_routes_v_to_advanced_setup() {
  local action
  run_ai menu
  action="$(menu_action_for_key v)"
  assert_contains "$action" 'watch-setup' 'v uses shared setup flow'
  assert_contains "$action" 'display-popup -E -w 90% -h 85%' 'v reserves a full advanced setup console'
  assert_contains "$action" "'#{pane_id}' advanced" 'v selects advanced mode'
}

test_native_tpm_menu_matches_goal_first_setup_routes() {
  local entrypoint
  entrypoint="$(cat "$ROOT/tmux-radar.tmux")"
  assert_contains "$entrypoint" 'MONITOR_POP="display-popup -E -w 90% -h 85%"' \
    'native prefix+A menu reserves the supervision popup'
  assert_contains "$entrypoint" "watch-setup '#{pane_id}' quick" \
    'native w binding uses quick goal-first setup'
  assert_contains "$entrypoint" "watch-setup '#{pane_id}' quick always-allow" \
    'native W binding uses quick goal-first setup with always-allow'
  assert_contains "$entrypoint" "watch-setup '#{pane_id}' advanced" \
    'native v binding uses advanced goal-first setup'
  case "$entrypoint" in
    *'run-shell \"$SCRIPTS/ai.sh watch'*) _fail_assert 'native menu bypasses goal entry with direct watch' ;;
  esac
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

test_wide_layout_uses_right_rail_with_25_75_split() {
  local calls detail_line overview_line wf="$TMP/state/ai-watch/_39.watch"
  seed_monitor_run
  TEST_PANE_WIDTH=284 TEST_PANE_HEIGHT=54 run_ai _launch-monitor %39 "$wf"
  calls="$(cat "$TMP/tmux.calls")"
  assert_contains "$calls" 'split-window -h -l 84' 'wide layout creates right rail'
  assert_contains "$calls" "ai-monitor.sh' detail" 'wide layout starts detail first'
  assert_contains "$calls" 'split-window -v -b -p 25' 'wide layout creates overview above at 25 percent'
  assert_contains "$calls" "ai-monitor.sh' overview" 'wide layout starts overview renderer'
  assert_contains "$calls" 'select-pane -t %39' 'wide layout restores target focus'
  detail_line="$(awk "/ai-monitor.sh' detail/{print NR; exit}" "$TMP/tmux.calls")"
  overview_line="$(awk "/ai-monitor.sh' overview/{print NR; exit}" "$TMP/tmux.calls")"
  [ "$detail_line" -lt "$overview_line" ] || _fail_assert 'detail pane must be created before overview'
  assert_contains "$(cat "$wf")" 'monitor_overview_pane=%92' 'watch pointer stores overview pane'
  assert_contains "$(cat "$wf")" 'monitor_detail_pane=%91' 'watch pointer stores detail pane'
  assert_file "$TMP/state/ai-runs/test-run/monitors"
  assert_contains "$(cat "$TMP/state/ai-runs/test-run/monitors")" 'monitor_overview_pane=%92' 'run ownership stores overview pane'
  assert_contains "$(cat "$TMP/state/ai-runs/test-run/monitors")" 'monitor_detail_pane=%91' 'run ownership stores detail pane'
}

test_medium_layout_uses_one_compact_right_console() {
  local calls wf="$TMP/state/ai-watch/_39.watch"
  seed_monitor_run; clear_layout_calls
  TEST_PANE_WIDTH=150 TEST_PANE_HEIGHT=40 run_ai _launch-monitor %39 "$wf"
  calls="$(cat "$TMP/tmux.calls")"
  assert_contains "$calls" 'split-window -h -l 57' 'medium layout reserves proportional right rail'
  assert_contains "$calls" "ai-monitor.sh' compact" 'medium layout uses compact console'
  case "$calls" in *"ai-monitor.sh' overview"*) _fail_assert 'medium layout must not create separate overview pane' ;; esac
}

test_narrow_layout_uses_popup_without_target_split() {
  local calls wf="$TMP/state/ai-watch/_39.watch"
  seed_monitor_run; clear_layout_calls
  TEST_PANE_WIDTH=100 TEST_PANE_HEIGHT=30 run_ai _launch-monitor %39 "$wf"
  calls="$(cat "$TMP/tmux.calls")"
  assert_contains "$calls" 'display-popup -E -w 90% -h 85%' 'narrow layout uses large popup'
  assert_contains "$calls" 'TMUX_RADAR_MONITOR_COLS=70 TMUX_RADAR_MONITOR_ROWS=18' 'narrow popup receives its real inner geometry'
  assert_contains "$calls" "ai-monitor.sh' compact" 'narrow popup uses compact console'
  case "$calls" in *'split-window'*) _fail_assert 'narrow layout must not split target pane' ;; esac
}

test_narrow_setup_reuses_existing_popup_for_monitor() {
  local calls output="$TMP/reused-popup.out" wf="$TMP/state/ai-watch/_39.watch"
  seed_monitor_run; clear_layout_calls
  TMUX_RADAR_REUSE_POPUP=1 TMUX_RADAR_TEST_MONITOR_ONCE=1 \
    TEST_PANE_WIDTH=100 TEST_PANE_HEIGHT=30 run_ai _launch-monitor %39 "$wf" > "$output"
  calls="$(cat "$TMP/tmux.calls")"
  case "$calls" in *'display-popup'*) _fail_assert 'setup popup reuse must not request a nested popup' ;; esac
  case "$calls" in *'split-window'*) _fail_assert 'setup popup reuse must not split target pane' ;; esac
  assert_contains "$(cat "$wf")" 'monitor_overview_pane=popup' 'reused popup stores overview ownership'
  assert_contains "$(cat "$wf")" 'monitor_detail_pane=popup' 'reused popup stores detail ownership'
  assert_contains "$(cat "$output")" '监控到测试全绿' 'reused setup popup renders compact monitor'
}

count_clear_sequences() {
  LC_ALL=C grep -ao $'\033\[2J' "$1" 2>/dev/null | wc -l | tr -d ' '
}

strip_ansi() {
  LC_ALL=C awk -v esc="$(printf '\033')" '{ gsub(esc "\\[[0-9;?]*[ -/]*[@-~]", ""); print }'
}

test_monitor_views_render_from_structured_run_without_refresh_loop() {
  local output="$TMP/monitor.out" view clears
  seed_monitor_run
  TMUX_RADAR_STATE_DIR="$TMP/state" PATH="$TMP/bin:$OLD_PATH" \
    TEST_FAKE_TMUX="$TMP/bin/tmux" TEST_TMUX_CALLS="$TMP/tmux.calls" \
    TEST_TMUX_SPLIT_COUNT="$TMP/split.count" TEST_PANE_WIDTH=284 TEST_PANE_HEIGHT=54 \
    bash "$ROOT/scripts/ai-monitor.sh" overview %39 --once > "$output"
  assert_contains "$(cat "$output")" '监控到测试全绿' 'overview shows exact goal'
  assert_contains "$(cat "$output")" 'native hook or stable-screen fallback' 'overview reports honest next trigger'
  clears="$(count_clear_sequences "$output")"; [ "$clears" -le 1 ] || _fail_assert 'overview clears more than once' 'actual' "$clears"
  for view in Timeline Decision Screen Config Logs; do
    TMUX_RADAR_STATE_DIR="$TMP/state" PATH="$TMP/bin:$OLD_PATH" \
      TEST_FAKE_TMUX="$TMP/bin/tmux" TEST_TMUX_CALLS="$TMP/tmux.calls" \
      TEST_TMUX_SPLIT_COUNT="$TMP/split.count" \
      bash "$ROOT/scripts/ai-monitor.sh" detail %39 "$view" --once > "$output"
    assert_contains "$(cat "$output")" "$view" "detail renders $view tab"
    clears="$(count_clear_sequences "$output")"; [ "$clears" -le 1 ] || _fail_assert "$view clears more than once" 'actual' "$clears"
  done
}

test_compact_console_keeps_actions_readable_at_narrow_width() {
  local output="$TMP/compact-narrow.out" plain="$TMP/compact-narrow.txt"
  seed_monitor_run
  TERM=xterm-256color COLUMNS=70 LINES=18 \
    TMUX_RADAR_STATE_DIR="$TMP/state" PATH="$TMP/bin:$OLD_PATH" \
    TEST_FAKE_TMUX="$TMP/bin/tmux" TEST_TMUX_CALLS="$TMP/tmux.calls" \
    TEST_TMUX_SPLIT_COUNT="$TMP/split.count" \
    bash "$ROOT/scripts/ai-monitor.sh" compact %39 --once > "$output"
  strip_ansi < "$output" > "$plain"

  assert_contains "$(cat "$plain")" 'Goal  监控到测试全绿' 'compact view keeps exact goal visible'
  assert_contains "$(cat "$plain")" 'Next  native hook or stable-screen fallback' 'compact view explains what it is waiting for'
  assert_contains "$(cat "$plain")" '[1] Timeline  [2] Decision  [3] Screen' 'compact view lists primary detail views'
  assert_contains "$(cat "$plain")" '[4] Config    [5] Logs' 'compact view lists configuration and logs'
  assert_contains "$(cat "$plain")" '[p] Pause/resume  [r] Reassess now  [k] Keep open' 'compact view lists run controls without truncation'
  assert_contains "$(cat "$plain")" '[Enter] Target pane  [q] Stop supervision' 'compact view lists navigation and stop controls'
  case "$(cat "$plain")" in
    *'Enter t…'*) _fail_assert 'compact controls were clipped before visible width' ;;
  esac
}

test_compact_console_renders_requested_detail_view() {
  local output="$TMP/compact-config.out" plain="$TMP/compact-config.txt"
  seed_monitor_run
  TERM=xterm-256color COLUMNS=70 LINES=30 \
    TMUX_RADAR_STATE_DIR="$TMP/state" PATH="$TMP/bin:$OLD_PATH" \
    TEST_FAKE_TMUX="$TMP/bin/tmux" TEST_TMUX_CALLS="$TMP/tmux.calls" \
    TEST_TMUX_SPLIT_COUNT="$TMP/split.count" \
    bash "$ROOT/scripts/ai-monitor.sh" compact %39 Config --once > "$output"
  strip_ansi < "$output" > "$plain"

  assert_contains "$(cat "$plain")" 'View  Config' 'compact console names the selected detail view'
  assert_contains "$(cat "$plain")" 'Effective configuration' 'compact console renders selected configuration details'
  assert_contains "$(cat "$plain")" 'Authority' 'compact configuration keeps grouped detail available'
}

test_pause_resume_controls_persist_and_signal() {
  local run_dir="$TMP/state/ai-runs/test-run"
  seed_monitor_run
  run_ai pause %39
  assert_file "$run_dir/paused"
  assert_json "$run_dir/events.jsonl" 'select(.kind == "paused" and .record == "control")'
  run_ai resume %39
  [ ! -e "$run_dir/paused" ] || _fail_assert 'resume leaves pause sentinel'
  assert_json "$run_dir/events.jsonl" 'select(.kind == "resume_requested" and .record == "control")'
  assert_contains "$(cat "$TMP/tmux.calls")" 'wait-for -S radar-run-39' 'controls wake watcher channel'
}

test_completion_overview_shows_summary_countdown_and_keep_control() {
  local output="$TMP/completion-monitor.out" run_dir="$TMP/state/ai-runs/test-run" deadline
  seed_monitor_run
  deadline=$(( $(date '+%s') + 9 ))
  jq -cn --argjson deadline "$deadline" '{phase:"COMPLETED",status:"goal reached",next:{kind:"auto_close",at:$deadline},goal:"监控到测试全绿",policy:"safe-auto",autonomy:"auto-safe",poll:5,calls:1,max_calls:40,retry:0}' > "$run_dir/state.json"
  jq -cn --arg path "$run_dir" '{outcome:"completed",reason:"goal reached",run_id:"test-run",pane:"%39",goal:"监控到测试全绿",goal_status:"done",duration_seconds:14,event_count:8,decision_count:1,action_count:0,error_count:0,log_path:$path}' > "$run_dir/final.json"
  TMUX_RADAR_STATE_DIR="$TMP/state" PATH="$TMP/bin:$OLD_PATH" \
    TEST_FAKE_TMUX="$TMP/bin/tmux" TEST_TMUX_CALLS="$TMP/tmux.calls" \
    TEST_TMUX_SPLIT_COUNT="$TMP/split.count" \
    bash "$ROOT/scripts/ai-monitor.sh" overview %39 --once > "$output"
  assert_contains "$(cat "$output")" 'Outcome' 'completion overview labels final outcome'
  assert_contains "$(cat "$output")" 'completed · decisions=1 actions=0 errors=0 · 14s' 'completion overview summarizes final counts'
  assert_contains "$(cat "$output")" 'auto-close in ' 'completion overview shows countdown'
  assert_contains "$(cat "$output")" 'k keep' 'completion overview exposes keep control'

  jq '.next={kind:"manual_close",at:0} | .status="completed; kept open until q"' "$run_dir/state.json" > "$run_dir/state.next"
  mv "$run_dir/state.next" "$run_dir/state.json"
  TMUX_RADAR_STATE_DIR="$TMP/state" PATH="$TMP/bin:$OLD_PATH" \
    TEST_FAKE_TMUX="$TMP/bin/tmux" TEST_TMUX_CALLS="$TMP/tmux.calls" \
    TEST_TMUX_SPLIT_COUNT="$TMP/split.count" \
    bash "$ROOT/scripts/ai-monitor.sh" overview %39 --once > "$output"
  assert_contains "$(cat "$output")" 'kept open; press q to close' 'kept completion has honest close state'
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
run_test 'native prefix+A menu matches goal-first setup routes' test_native_tpm_menu_matches_goal_first_setup_routes
run_test 'blank goal uses explicit default' test_blank_goal_uses_explicit_default
run_test 'quick goal reaches config byte-for-byte' test_quick_goal_reaches_config_byte_for_byte
run_test '_decode-goal preserves terminal newlines before sentinel' test_decode_goal_preserves_terminal_newlines_before_sentinel
run_test 'advanced summary lists all grouped fields and provenance' test_advanced_summary_lists_every_group_field_and_provenance
run_test 'immutable config reaches run config and per-run runtime' test_config_reaches_run_config_and_runtime_without_codex
run_test 'wide layout creates right-side 25/75 console' test_wide_layout_uses_right_rail_with_25_75_split
run_test 'medium layout creates compact right console' test_medium_layout_uses_one_compact_right_console
run_test 'narrow layout uses popup console' test_narrow_layout_uses_popup_without_target_split
run_test 'narrow setup reuses its popup for monitor' test_narrow_setup_reuses_existing_popup_for_monitor
run_test 'monitor views derive from structured state without repeated clears' test_monitor_views_render_from_structured_run_without_refresh_loop
run_test 'compact console keeps actions readable at narrow width' test_compact_console_keeps_actions_readable_at_narrow_width
run_test 'compact console renders requested detail view' test_compact_console_renders_requested_detail_view
run_test 'pause and resume controls persist and signal' test_pause_resume_controls_persist_and_signal
run_test 'completion overview shows summary countdown and keep control' test_completion_overview_shows_summary_countdown_and_keep_control

if [ "$FAILURES" -ne 0 ]; then
  printf '%s test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'PASS: all AI console tests\n'

#!/usr/bin/env bash
# shellcheck disable=SC1091
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helpers.sh
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir native-tui)"
FAILURES=0

cleanup() {
  local rc="${1:-$?}"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'cleanup $?' EXIT

mkdir -p "$TMP/bin" "$TMP/state" "$TMP/gocache"
GOCACHE="$TMP/gocache" go build -o "$TMP/bin/tmux-radar" "$ROOT/cmd/tmux-radar"

cat > "$TMP/bin/ai.sh" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = doctor-json ]; then
  printf '%s\n' '{"ok":true,"backend":{"mode":"codex","path":"/tmp/codex","version":"0.144.0","identity":"test","source":"test","model":"gpt-5.6-luna","effort":"high","model_source":"default","effort_source":"default","compatible":true},"model":"gpt-5.6-luna","effort":"high","candidates":[]}'
  exit 0
fi
exit 9
SH
chmod +x "$TMP/bin/ai.sh"

cat > "$TMP/bin/native-stub" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = version ]; then
  printf '%s\n' "tmux-radar dev (protocol ${TEST_NATIVE_PROTOCOL:-1}, schema 1)"
  exit 0
fi
printf '%s\n' "$*" >> "$TEST_NATIVE_CALLS"
SH
chmod +x "$TMP/bin/native-stub"

cat > "$TMP/bin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
command="${1:-}"
shift || true
case "$command" in
  display-message)
    case "$*" in
      *pane_width*) printf '%s\n' "${TEST_TARGET_WIDTH:-284}" ;;
      *pane_height*) printf '%s\n' "${TEST_TARGET_HEIGHT:-40}" ;;
      *pane_id*) printf '%s\n' '%42' ;;
      *) printf 'display-message %s\n' "$*" >> "$TEST_TMUX_CALLS" ;;
    esac
    ;;
  show-option)
    printf '%s\n' "${TEST_MONITOR_WIDTH:-84}"
    ;;
  split-window)
    printf 'split-window %s\n' "$*" >> "$TEST_TMUX_CALLS"
    printf '%s\n' '%90'
    ;;
  display-popup|select-pane|kill-pane)
    printf '%s %s\n' "$command" "$*" >> "$TEST_TMUX_CALLS"
    ;;
  *)
    printf '%s %s\n' "$command" "$*" >> "$TEST_TMUX_CALLS"
    ;;
esac
SH
chmod +x "$TMP/bin/tmux"

run_launcher() {
  local width="$1" height="$2" entry="$3"
  : > "$TMP/tmux.calls"
  : > "$TMP/native.calls"
  PATH="$TMP/bin:$PATH" \
    TEST_TARGET_WIDTH="$width" TEST_TARGET_HEIGHT="$height" TEST_MONITOR_WIDTH=84 \
    TEST_TMUX_CALLS="$TMP/tmux.calls" TEST_NATIVE_CALLS="$TMP/native.calls" \
    TMUX_RADAR_BIN="$TMP/bin/native-stub" TMUX_RADAR_ENGINE_SCRIPT="$TMP/bin/ai.sh" \
    TMUX_RADAR_STATE_DIR="$TMP/state" \
    bash "$ROOT/scripts/native-launcher.sh" %42 "$entry"
}

run_test() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS: %s\n' "$name"
  else
    FAILURES=$((FAILURES + 1))
    printf 'FAIL: %s\n' "$name" >&2
  fi
}

test_version_contract() {
  local output
  output="$("$TMP/bin/tmux-radar" version)"
  assert_contains "$output" 'protocol 1' 'version exposes protocol'
  assert_contains "$output" 'schema 1' 'version exposes schema'
}

test_doctor_json_contract() {
  local output_file="$TMP/doctor.json"
  "$TMP/bin/tmux-radar" supervisor doctor --json --engine-script "$TMP/bin/ai.sh" > "$output_file"
  assert_json "$output_file" '.ok == true and .model == "gpt-5.6-luna" and .effort == "high"'
}

test_invalid_arguments_exit_two() {
  local rc
  set +e
  "$TMP/bin/tmux-radar" supervisor setup --surface other --target-pane %1 >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq 2 "$rc" 'invalid setup exits with usage status'
}

test_missing_attach_is_permanent() {
  local rc
  set +e
  "$TMP/bin/tmux-radar" supervisor attach --run missing --state-root "$TMP/state" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq 3 "$rc" 'missing run exits with permanent status'
}

test_launcher_uses_popup_at_width_120() {
  local calls
  run_launcher 120 30 quick
  calls="$(cat "$TMP/tmux.calls")"
  assert_contains "$calls" 'display-popup' '120-column target uses popup'
  case "$calls" in *split-window*) _fail_assert 'popup path must not split target' 'calls' "$calls" ;; esac
  assert_contains "$calls" "--entry 'quick'" 'popup receives quick preset'
}

test_launcher_uses_minimum_split_at_width_121() {
  local calls
  run_launcher 121 30 always-allow
  calls="$(cat "$TMP/tmux.calls")"
  assert_contains "$calls" 'split-window' '121-column target uses split'
  assert_contains "$calls" '-l 56' 'minimum split is 56 columns'
  assert_contains "$calls" "--entry 'always-allow'" 'W preset reaches native setup'
  assert_contains "$calls" "--monitor-pane \"\$TMUX_PANE\"" 'split owner binds to the created pane'
  case "$calls" in *display-popup*) _fail_assert 'split path must not open popup' 'calls' "$calls" ;; esac
}

test_launcher_clamps_wide_monitor_without_using_client_width() {
  local calls
  run_launcher 284 54 advanced
  calls="$(cat "$TMP/tmux.calls")"
  assert_contains "$calls" '-l 84' 'wide target honors configured monitor width'
  assert_contains "$calls" "--entry 'advanced'" 'advanced preset reaches native setup'
}

test_launcher_rejects_duplicate_before_surface_creation() {
  local calls pointer="$TMP/state/ai-watch/_42.watch" run_dir="$TMP/state/ai-runs/existing"
  mkdir -p "$(dirname "$pointer")" "$run_dir"
  printf '%s\n' '{"schema_version":1,"kind":"split","pane":"%77","pid":1,"token":"00000000000000000000000000000000","heartbeat_path":"/tmp/existing"}' > "$run_dir/owner.json"
  printf 'run_id=existing\nrun_dir=%s\npid=%s\nowner_file=%s\n' "$run_dir" "$$" "$run_dir/owner.json" > "$pointer"
  run_launcher 284 54 quick
  calls="$(cat "$TMP/tmux.calls")"
  assert_contains "$calls" 'select-pane -t %77' 'duplicate focuses existing split owner'
  case "$calls" in *split-window*|*display-popup*) _fail_assert 'duplicate must not create a surface' 'calls' "$calls" ;; esac
  rm -f "$pointer"
  rm -rf "$run_dir"
}

test_launcher_legacy_rollback_is_explicit() {
  local calls
  : > "$TMP/tmux.calls"
  PATH="$TMP/bin:$PATH" TEST_TARGET_WIDTH=284 TEST_TARGET_HEIGHT=54 \
    TEST_TMUX_CALLS="$TMP/tmux.calls" TEST_NATIVE_CALLS="$TMP/native.calls" \
    TMUX_RADAR_LEGACY_UI=1 TMUX_RADAR_ENGINE_SCRIPT="$TMP/bin/ai.sh" TMUX_RADAR_STATE_DIR="$TMP/state" \
    bash "$ROOT/scripts/native-launcher.sh" %42 advanced
  calls="$(cat "$TMP/tmux.calls")"
  assert_contains "$calls" 'display-popup' 'legacy rollback opens legacy popup'
  assert_contains "$calls" 'watch-setup' 'legacy rollback invokes watch-setup'
  assert_contains "$calls" 'advanced' 'legacy rollback preserves preset'
}

test_launcher_protocol_mismatch_creates_no_surface() {
  local rc calls
  : > "$TMP/tmux.calls"
  set +e
  PATH="$TMP/bin:$PATH" TEST_NATIVE_PROTOCOL=9 TEST_TARGET_WIDTH=284 TEST_TARGET_HEIGHT=54 \
    TEST_TMUX_CALLS="$TMP/tmux.calls" TEST_NATIVE_CALLS="$TMP/native.calls" \
    TMUX_RADAR_BIN="$TMP/bin/native-stub" TMUX_RADAR_ENGINE_SCRIPT="$TMP/bin/ai.sh" \
    TMUX_RADAR_STATE_DIR="$TMP/state" \
    bash "$ROOT/scripts/native-launcher.sh" %42 quick >/dev/null 2>&1
  rc=$?
  set -e
  calls="$(cat "$TMP/tmux.calls")"
  [ "$rc" -ne 0 ] || _fail_assert 'protocol mismatch must fail' 'rc' "$rc"
  case "$calls" in *split-window*|*display-popup*) _fail_assert 'protocol mismatch must not create a surface' 'calls' "$calls" ;; esac
}

test_ensure_native_maps_release_platforms() {
  local actual
  actual="$(TMUX_RADAR_PLATFORM_OS=darwin TMUX_RADAR_PLATFORM_ARCH=arm64 \
    bash "$ROOT/scripts/ensure-native.sh" platform v0.1.0)"
  assert_eq 'tmux-radar_v0.1.0_darwin_arm64' "$actual" 'darwin arm64 asset name'
  actual="$(TMUX_RADAR_PLATFORM_OS=linux TMUX_RADAR_PLATFORM_ARCH=amd64 \
    bash "$ROOT/scripts/ensure-native.sh" platform v0.1.0)"
  assert_eq 'tmux-radar_v0.1.0_linux_amd64' "$actual" 'linux amd64 asset name'
}

test_ensure_native_resolve_is_local_only() {
  local resolved network_log="$TMP/network.log" no_network_bin="$TMP/no-network-bin"
  mkdir -p "$no_network_bin"
  cat > "$no_network_bin/curl" <<'SH'
#!/usr/bin/env bash
printf 'curl called\n' >> "$TEST_NETWORK_LOG"
exit 91
SH
  chmod +x "$no_network_bin/curl"
  resolved="$(PATH="$no_network_bin:$PATH" TEST_NETWORK_LOG="$network_log" \
    TMUX_RADAR_BIN="$TMP/bin/native-stub" bash "$ROOT/scripts/ensure-native.sh" resolve)"
  assert_eq "$TMP/bin/native-stub" "$resolved" 'configured native binary wins'
  [ ! -e "$network_log" ] || _fail_assert 'resolve must not call the network' 'network log' "$(cat "$network_log")"
}

test_ensure_native_refuses_checksum_mismatch() {
  local version=v0.1.0 asset release_dir install_dir rc
  asset="$(TMUX_RADAR_PLATFORM_OS=darwin TMUX_RADAR_PLATFORM_ARCH=arm64 \
    bash "$ROOT/scripts/ensure-native.sh" platform "$version")"
  release_dir="$TMP/releases/$version"
  install_dir="$TMP/install-mismatch"
  mkdir -p "$release_dir" "$install_dir"
  cp "$TMP/bin/native-stub" "$release_dir/$asset"
  printf '%064d  %s\n' 0 "$asset" > "$release_dir/checksums.txt"
  set +e
  TMUX_RADAR_PLATFORM_OS=darwin TMUX_RADAR_PLATFORM_ARCH=arm64 \
    bash "$ROOT/scripts/ensure-native.sh" install "$version" \
      --base-url "file://$release_dir" --install-dir "$install_dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || _fail_assert 'checksum mismatch must fail' 'rc' "$rc"
  [ ! -e "$install_dir/tmux-radar" ] || _fail_assert 'checksum mismatch installed a binary'
}

test_ensure_native_installs_verified_asset_atomically() {
  local version=v0.1.1 asset release_dir install_dir checksum output
  asset="$(TMUX_RADAR_PLATFORM_OS=darwin TMUX_RADAR_PLATFORM_ARCH=arm64 \
    bash "$ROOT/scripts/ensure-native.sh" platform "$version")"
  release_dir="$TMP/releases/$version"
  install_dir="$TMP/install-ok"
  mkdir -p "$release_dir" "$install_dir"
  cp "$TMP/bin/native-stub" "$release_dir/$asset"
  checksum="$(shasum -a 256 "$release_dir/$asset" | awk '{print $1}')"
  printf '%s  %s\n' "$checksum" "$asset" > "$release_dir/checksums.txt"
  output="$(TMUX_RADAR_PLATFORM_OS=darwin TMUX_RADAR_PLATFORM_ARCH=arm64 \
    bash "$ROOT/scripts/ensure-native.sh" install "$version" \
      --base-url "file://$release_dir" --install-dir "$install_dir")"
  assert_eq "$install_dir/tmux-radar" "$output" 'verified installer prints installed path'
  [ -x "$install_dir/tmux-radar" ] || _fail_assert 'verified binary is not executable'
  assert_contains "$("$install_dir/tmux-radar" version)" 'protocol 1' 'installed binary passes protocol check'
  if find "$install_dir" -name '*.tmp.*' -print | grep -q .; then
    _fail_assert 'installer left a temporary artifact' 'files' "$(find "$install_dir" -maxdepth 1 -type f -print)"
  fi
}

test_ensure_native_legacy_selection_is_explicit() {
  local output
  output="$(bash "$ROOT/scripts/ensure-native.sh" legacy)"
  assert_contains "$output" 'TMUX_RADAR_LEGACY_UI=1' 'legacy command prints explicit rollback switch'
}

run_test 'native CLI version contract' test_version_contract
run_test 'native doctor JSON contract' test_doctor_json_contract
run_test 'native invalid argument exit contract' test_invalid_arguments_exit_two
run_test 'native missing attach exit contract' test_missing_attach_is_permanent
run_test 'launcher uses popup at target width 120' test_launcher_uses_popup_at_width_120
run_test 'launcher uses minimum split at target width 121' test_launcher_uses_minimum_split_at_width_121
run_test 'launcher clamps wide monitor from target geometry' test_launcher_clamps_wide_monitor_without_using_client_width
run_test 'launcher rejects duplicate before surface creation' test_launcher_rejects_duplicate_before_surface_creation
run_test 'launcher explicit legacy rollback' test_launcher_legacy_rollback_is_explicit
run_test 'launcher protocol mismatch creates no surface' test_launcher_protocol_mismatch_creates_no_surface
run_test 'ensure-native maps release platforms' test_ensure_native_maps_release_platforms
run_test 'ensure-native resolve is local only' test_ensure_native_resolve_is_local_only
run_test 'ensure-native rejects checksum mismatch' test_ensure_native_refuses_checksum_mismatch
run_test 'ensure-native installs a verified asset atomically' test_ensure_native_installs_verified_asset_atomically
run_test 'ensure-native legacy selection is explicit' test_ensure_native_legacy_selection_is_explicit

if [ "$FAILURES" -ne 0 ]; then
  printf '%d native TUI test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'PASS: native CLI contract suite\n'

#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir ai-preflight)"
OLD_PATH="$PATH"
FAILURES=0

cleanup() {
  local rc="${1:-$?}"
  PATH="$OLD_PATH"
  rm -rf "$TMP"
  exit "$rc"
}
trap 'cleanup $?' EXIT

write_fakes() {
  mkdir -p "$TMP/bin" "$TMP/old-bin" "$TMP/new-bin" "$TMP/slow-bin" "$TMP/prerelease-bin"
  cat > "$TMP/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
set -eu
cmd="${1:-}"
shift || true
case "$cmd" in
  list-sessions) exit 0 ;;
  list-panes) printf '%s\n' '%1' ;;
  show-option)
    key=""
    for arg in "$@"; do key="$arg"; done
    case "$key" in
      @radar-ai-codex-path|@switcher-ai-codex-path)
        [ -n "${TEST_CODEX_PATH:-}" ] && printf '%s\n' "$TEST_CODEX_PATH"
        ;;
      @radar-ai-profile|@switcher-ai-profile)
        [ -n "${TEST_PROFILE:-}" ] && printf '%s\n' "$TEST_PROFILE"
        ;;
    esac
    ;;
  display-message)
    case "$*" in
      *pane_id*) printf '%s\n' '%1' ;;
      *) printf '%s\n' 'test:0.0 codex' ;;
    esac
    ;;
  capture-pane) printf '%s\n' 'approval prompt' ;;
  send-keys) exit 0 ;;
  *) exit 0 ;;
esac
TMUXEOF
  chmod +x "$TMP/bin/tmux"
  cat > "$TMP/bashenv" <<'BASHENVEOF'
tmux() { "$TEST_FAKE_TMUX" "$@"; }

# Make the production PATH-prepend regression deterministic without writing to
# host-owned /opt/homebrew. Bash resolves this function before its export
# builtin: only the old prepend form is translated to the fake old candidate.
# The corrected inherited-first append form falls through unchanged.
export() {
  case "${1:-}" in
    PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:*)
      inherited="${1#PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:}"
      builtin export PATH="$TEST_OLD_BIN:$inherited"
      ;;
    *) builtin export "$@" ;;
  esac
}
BASHENVEOF

  cat > "$TMP/old-bin/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --version ]; then
  printf '%s\n' "$0" >> "$TEST_VERSION_LOG"
  printf '%s\n' 'codex-cli 0.139.0'
  exit 0
fi
printf '%s\n' "The 'gpt-5.6-luna' model requires a newer version of Codex." >&2
printf '%s\n' old-exec >> "$TEST_EXEC_LOG"
exit 1
CODEXEOF

  cat > "$TMP/new-bin/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = --version ]; then
  printf '%s\n' "$0" >> "$TEST_VERSION_LOG"
  printf '%s\n' 'codex-cli 0.144.3'
  exit 0
fi
printf '%s\t%s\n' "$0" "$*" >> "$TEST_EXEC_LOG"
output=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output" ] || exit 98
printf '%s\n' '{"action":"send","text":"","keys":[],"safe":true,"reason":"fixture"}' > "$output"
CODEXEOF

  cat > "$TMP/slow-bin/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -eu
sleep 30
CODEXEOF

  cat > "$TMP/prerelease-bin/codex" <<'CODEXEOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' 'codex-cli 0.144.0-alpha.1'
CODEXEOF
  chmod +x "$TMP/old-bin/codex" "$TMP/new-bin/codex" \
    "$TMP/slow-bin/codex" "$TMP/prerelease-bin/codex"
}

run_ai() {
  local case_name="${TEST_CASE_NAME:-default}"
  local exec_log="$TMP/$case_name.exec.log"
  local version_log="$TMP/$case_name.version.log"
  : > "$exec_log"
  : > "$version_log"
  PATH="$TMP/bin:$TMP/new-bin:/usr/bin:/bin" \
    BASH_ENV="$TMP/bashenv" \
    TEST_FAKE_TMUX="$TMP/bin/tmux" \
    TEST_OLD_BIN="$TMP/old-bin" \
    TEST_EXEC_LOG="$exec_log" \
    TEST_VERSION_LOG="$version_log" \
    TEST_CODEX_PATH="${TEST_CODEX_PATH:-}" \
    TEST_PROFILE="${TEST_PROFILE:-}" \
    TMUX_RADAR_STATE_DIR="$TMP/state-$case_name" \
    TMUX_RADAR_NEEDINPUT_FILE="$TMP/state-$case_name/need-input" \
    bash "$ROOT/scripts/ai.sh" "$@"
}

run_test() {
  local name="$1" fn="$2" output rc
  set +e
  output="$(set -Eeuo pipefail; "$fn" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'PASS: %s\n' "$name"
    return 0
  fi
  FAILURES=$((FAILURES + 1))
  printf 'FAIL: %s\n' "$name" >&2
  while IFS= read -r line; do printf '  %s\n' "$line" >&2; done <<< "$output"
}

test_builtin_defaults_are_luna_high() {
  local config="$TMP/defaults.json"
  TEST_CASE_NAME=defaults run_ai _build-watch-config %1 '' > "$config"
  assert_json "$config" '
    .values.model == {value:"gpt-5.6-luna",source:"default"} and
    .values.effort == {value:"high",source:"default"}
  '
}

test_inherited_path_order_is_preserved() {
  local result="$TMP/path-doctor.json"
  TEST_CASE_NAME=path TEST_CODEX_PATH="" run_ai doctor-json > "$result"
  if ! jq -e --arg expected "$TMP/new-bin/codex" '
    .ok == true and
    .backend.mode == "codex" and
    .backend.path == $expected and
    .backend.version == "0.144.3" and
    .backend.source == "path" and
    .model == "gpt-5.6-luna" and
    .effort == "high"
  ' "$result" >/dev/null; then
    _fail_assert 'inherited PATH did not select the expected Codex' 'actual' "$(cat "$result")"
  fi
}

test_old_explicit_backend_reports_newer_candidate_without_exec() {
  local result="$TMP/old-doctor.json"
  TEST_CASE_NAME=old-explicit TEST_CODEX_PATH="$TMP/old-bin/codex" run_ai doctor-json > "$result"
  if ! jq -e --arg selected "$TMP/old-bin/codex" --arg candidate "$TMP/new-bin/codex" '
    .ok == false and
    .class == "config-permanent" and
    .backend.path == $selected and
    .backend.version == "0.139.0" and
    .backend.source == "tmux" and
    (.candidates | any(
      .path == $candidate and
      .version == "0.144.3" and
      .compatible == true
    ))
  ' "$result" >/dev/null; then
    _fail_assert 'explicit old Codex diagnostic is incorrect' 'actual' "$(cat "$result")"
  fi
  assert_eq 0 "$(wc -l < "$TMP/old-explicit.exec.log" | tr -d ' ')" 'doctor never launches a model call'
}

test_custom_command_bypasses_codex_preflight() {
  local result="$TMP/custom-doctor.json"
  TEST_CASE_NAME=custom TEST_CODEX_PATH="$TMP/old-bin/codex" \
    TMUX_RADAR_AI_CMD='printf custom' run_ai doctor-json > "$result"
  assert_json "$result" '
    .ok == true and
    .backend.mode == "custom-command" and
    .backend.command == "printf custom" and
    .backend.source == "env" and
    .candidates == []
  '
  assert_eq 0 "$(wc -l < "$TMP/custom.version.log" | tr -d ' ')" \
    'custom command bypasses Codex version checks'
}

test_custom_command_precedes_profile_with_warning() {
  local result="$TMP/custom-profile-doctor.json" errors="$TMP/custom-profile.err"
  TEST_CASE_NAME=custom-profile TEST_PROFILE=locked \
    TMUX_RADAR_AI_CMD='printf custom' run_ai doctor-json > "$result" 2> "$errors"
  assert_json "$result" '
    .ok == true and
    .backend.mode == "custom-command" and
    .backend.profile == "locked" and
    (.backend.warning | contains("custom command takes precedence"))
  '
  assert_contains "$(cat "$errors")" 'custom command takes precedence' \
    'command/profile precedence warning'
  assert_eq 0 "$(wc -l < "$TMP/custom-profile.version.log" | tr -d ' ')" \
    'command/profile mode bypasses Codex checks'
}

test_profile_executes_the_frozen_explicit_codex() {
  local invocation
  TEST_CASE_NAME=profile TEST_PROFILE=locked TEST_CODEX_PATH="$TMP/new-bin/codex" \
    run_ai decide %1 auto-safe safe-auto 'complete fixture'
  invocation="$(cat "$TMP/profile.exec.log")"
  assert_contains "$invocation" \
    "$TMP/new-bin/codex"$'\t''exec -p locked' \
    'profile execution uses the pinned absolute Codex path'
  assert_contains "$invocation" '-s read-only --ephemeral --skip-git-repo-check' \
    'profile execution preserves safety flags'
  assert_contains "$invocation" '--output-schema' 'profile execution uses a strict output schema'
  case "$invocation" in
    *' -m '*|*model_reasoning_effort*)
      _fail_assert 'profile execution must not override profile model settings' 'invocation' "$invocation"
      ;;
  esac
}

test_version_probe_is_bounded_and_rejects_prereleases() {
  local result="$TMP/slow-doctor.json" started elapsed
  started="$(date '+%s')"
  TEST_CASE_NAME=slow TEST_CODEX_PATH="$TMP/slow-bin/codex" run_ai doctor-json > "$result"
  elapsed=$(( $(date '+%s') - started ))
  [ "$elapsed" -lt 10 ] || _fail_assert 'Codex version probe exceeded its bound' 'elapsed' "$elapsed"
  assert_json "$result" '.ok == false and .class == "config-permanent"'

  result="$TMP/prerelease-doctor.json"
  TEST_CASE_NAME=prerelease TEST_CODEX_PATH="$TMP/prerelease-bin/codex" run_ai doctor-json > "$result"
  assert_json "$result" '
    .ok == false and
    .class == "config-permanent" and
    .backend.compatible == false
  '
}

write_fakes
run_test 'built-in supervision defaults are Luna/high' test_builtin_defaults_are_luna_high
run_test 'inherited PATH order selects the user Codex' test_inherited_path_order_is_preserved
run_test 'old explicit Codex reports a diagnostic-only newer candidate' test_old_explicit_backend_reports_newer_candidate_without_exec
run_test 'custom command bypasses Codex preflight' test_custom_command_bypasses_codex_preflight
run_test 'custom command keeps precedence over profile with a warning' test_custom_command_precedes_profile_with_warning
run_test 'profile execution uses the frozen explicit Codex' test_profile_executes_the_frozen_explicit_codex
run_test 'version probes are bounded and prereleases fail closed' test_version_probe_is_bounded_and_rejects_prereleases

if [ "$FAILURES" -ne 0 ]; then
  printf 'FAIL: %s preflight regression(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'PASS: backend preflight contract\n'

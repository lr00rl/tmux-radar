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
  mkdir -p "$TMP/bin" "$TMP/old-bin" "$TMP/new-bin"
  cat > "$TMP/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
set -eu
cmd="${1:-}"
shift || true
case "$cmd" in
  list-sessions) exit 0 ;;
  show-option)
    key=""
    for arg in "$@"; do key="$arg"; done
    case "$key" in
      @radar-ai-codex-path|@switcher-ai-codex-path)
        [ -n "${TEST_CODEX_PATH:-}" ] && printf '%s\n' "$TEST_CODEX_PATH"
        ;;
    esac
    ;;
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
  printf '%s\n' 'codex-cli 0.144.3'
  exit 0
fi
printf '%s\n' new-exec >> "$TEST_EXEC_LOG"
exit 99
CODEXEOF
  chmod +x "$TMP/old-bin/codex" "$TMP/new-bin/codex"
}

run_ai() {
  local case_name="${TEST_CASE_NAME:-default}"
  local exec_log="$TMP/$case_name.exec.log"
  : > "$exec_log"
  PATH="$TMP/bin:$TMP/new-bin:/usr/bin:/bin" \
    BASH_ENV="$TMP/bashenv" \
    TEST_FAKE_TMUX="$TMP/bin/tmux" \
    TEST_OLD_BIN="$TMP/old-bin" \
    TEST_EXEC_LOG="$exec_log" \
    TEST_CODEX_PATH="${TEST_CODEX_PATH:-}" \
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
  assert_json "$result" '
    .ok == true and
    .backend.mode == "codex" and
    .backend.path == "'"$TMP"'/new-bin/codex" and
    .backend.version == "0.144.3" and
    .backend.source == "path" and
    .model == "gpt-5.6-luna" and
    .effort == "high"
  '
}

test_old_explicit_backend_reports_newer_candidate_without_exec() {
  local result="$TMP/old-doctor.json"
  TEST_CASE_NAME=old-explicit TEST_CODEX_PATH="$TMP/old-bin/codex" run_ai doctor-json > "$result"
  assert_json "$result" '
    .ok == false and
    .class == "config-permanent" and
    .backend.path == "'"$TMP"'/old-bin/codex" and
    .backend.version == "0.139.0" and
    .backend.source == "tmux" and
    (.candidates | any(
      .path == "'"$TMP"'/new-bin/codex" and
      .version == "0.144.3" and
      .compatible == true
    ))
  '
  assert_eq 0 "$(wc -l < "$TMP/old-explicit.exec.log" | tr -d ' ')" 'doctor never launches a model call'
}

write_fakes
run_test 'built-in supervision defaults are Luna/high' test_builtin_defaults_are_luna_high
run_test 'inherited PATH order selects the user Codex' test_inherited_path_order_is_preserved
run_test 'old explicit Codex reports a diagnostic-only newer candidate' test_old_explicit_backend_reports_newer_candidate_without_exec

if [ "$FAILURES" -ne 0 ]; then
  printf 'FAIL: %s preflight regression(s)\n' "$FAILURES" >&2
  exit 1
fi
printf 'PASS: backend preflight contract\n'

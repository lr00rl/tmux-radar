#!/usr/bin/env bash
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
  output="$($TMP/bin/tmux-radar version)"
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

run_test 'native CLI version contract' test_version_contract
run_test 'native doctor JSON contract' test_doctor_json_contract
run_test 'native invalid argument exit contract' test_invalid_arguments_exit_two
run_test 'native missing attach exit contract' test_missing_attach_is_permanent

if [ "$FAILURES" -ne 0 ]; then
  printf '%d native TUI test(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'PASS: native CLI contract suite\n'

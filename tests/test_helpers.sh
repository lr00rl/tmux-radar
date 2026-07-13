#!/usr/bin/env bash
set -euo pipefail

test_tmpdir() {
  local label="${1:-tmp}"
  mktemp -d "${TMPDIR:-/tmp}/tmux-radar-${label}.XXXXXX"
}

_fail_assert() {
  local message="$1"
  shift || true
  TEST_EXIT_CODE=1
  {
    printf 'FAIL: %s\n' "$message"
    while [ "$#" -gt 1 ]; do
      printf '%s: %s\n' "$1" "$2"
      shift 2
    done
  } >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" context="${3:-}"
  [ "$expected" = "$actual" ] && return 0
  if [ -n "$context" ]; then
    _fail_assert "values differ ($context)" "expected" "$expected" "actual" "$actual"
  fi
  _fail_assert "values differ" "expected" "$expected" "actual" "$actual"
}

assert_file() {
  local path="$1"
  [ -f "$path" ] && return 0
  _fail_assert "expected file to exist" "file" "$path"
}

assert_contains() {
  local haystack="$1" needle="$2" context="${3:-}"
  case "$haystack" in
    *"$needle"*) return 0 ;;
  esac
  if [ -n "$context" ]; then
    _fail_assert "substring not found ($context)" "needle" "$needle" "actual" "$haystack"
  fi
  _fail_assert "substring not found" "needle" "$needle" "actual" "$haystack"
}

assert_json() {
  local path="$1" filter="$2"
  local output=""
  assert_file "$path"
  if output="$(jq -e "$filter" "$path" 2>&1)"; then
    return 0
  fi
  _fail_assert "json assertion failed" "file" "$path" "filter" "$filter" "jq" "$output" "actual" "$(cat "$path")"
}

wait_for_file() {
  local file="$1" attempts="${2:-80}" delay="${3:-0.05}"
  local i=0
  while [ "$i" -lt "$attempts" ]; do
    [ -s "$file" ] && return 0
    sleep "$delay"
    i=$((i + 1))
  done
  _fail_assert "timed out waiting for file" "file" "$file"
}

wait_for_exit() {
  local pid="$1" attempts="${2:-140}" delay="${3:-0.05}"
  local i=0
  while [ "$i" -lt "$attempts" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    sleep "$delay"
    i=$((i + 1))
  done
  _fail_assert "timed out waiting for process exit" "pid" "$pid"
}

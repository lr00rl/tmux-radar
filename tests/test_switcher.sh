#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWITCHER="$ROOT/scripts/switcher.sh"
TMP="$(mktemp -d /tmp/radar-sw.XXXXXX)"
SOCKET="rs$$"
FAKE_BIN="$TMP/bin"
FZF_CALLED="$TMP/fzf-called"

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_BIN" "$TMP/state"
export TMUX_TMPDIR="$TMP"
cat > "$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
: > "$TMUX_RADAR_FZF_CALLED"
SH
chmod +x "$FAKE_BIN/fzf"

tmux -L "$SOCKET" -f /dev/null new-session -d -s switcher
export TMUX
TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),$$,0"
export TMUX_RADAR_STATE_DIR="$TMP/state"
export TMUX_RADAR_FZF_CALLED="$FZF_CALLED"

set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu \
  >"$TMP/stdout" 2>"$TMP/stderr"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  printf 'FAIL: default tree menu exited %s\n' "$rc" >&2
  sed -n '1,120p' "$TMP/stderr" >&2
  exit 1
fi
if [ ! -f "$FZF_CALLED" ]; then
  printf 'FAIL: default tree menu exited before invoking fzf\n' >&2
  sed -n '1,120p' "$TMP/stderr" >&2
  exit 1
fi
if grep -q 'unbound variable' "$TMP/stderr"; then
  printf 'FAIL: default tree menu expanded an unset optional argument array\n' >&2
  sed -n '1,120p' "$TMP/stderr" >&2
  exit 1
fi

printf 'PASS: default tree menu invokes fzf under nounset\n'

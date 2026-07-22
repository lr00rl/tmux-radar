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

# --- last-pane: cross-window MRU toggle --------------------------------------
tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
tmux -L "$SOCKET" -f /dev/null new-session -d -s mru -x 80 -y 24
TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),$$,0"
tmux -L "$SOCKET" new-window -t mru
P_W0="$(tmux -L "$SOCKET" list-panes -t mru:0 -F '#{pane_id}' | head -1)"
P_W1="$(tmux -L "$SOCKET" list-panes -t mru:1 -F '#{pane_id}' | head -1)"
tmux -L "$SOCKET" select-window -t mru:1

bash "$ROOT/scripts/mru-record.sh" "$P_W0"
bash "$ROOT/scripts/mru-record.sh" "$P_W1"   # current pane is the newest entry
if ! grep -q "^$P_W0	" "$TMP/state/pane-mru" || ! grep -q "^$P_W1	" "$TMP/state/pane-mru"; then
  printf 'FAIL: mru-record did not record pane-level MRU rows\n' >&2
  exit 1
fi

bash "$SWITCHER" last-pane >/dev/null 2>&1
ACTIVE="$(tmux -L "$SOCKET" display-message -p -t mru '#{pane_id}')"
if [ "$ACTIVE" != "$P_W0" ]; then
  printf 'FAIL: last-pane did not jump to the previous pane (want %s got %s)\n' "$P_W0" "$ACTIVE" >&2
  exit 1
fi
printf 'PASS: last-pane jumps to the most recent other pane across windows\n'

bash "$ROOT/scripts/mru-record.sh" "$P_W0"   # what the pane hook records after the jump
bash "$SWITCHER" last-pane >/dev/null 2>&1
ACTIVE="$(tmux -L "$SOCKET" display-message -p -t mru '#{pane_id}')"
if [ "$ACTIVE" != "$P_W1" ]; then
  printf 'FAIL: last-pane did not toggle back (want %s got %s)\n' "$P_W1" "$ACTIVE" >&2
  exit 1
fi
printf 'PASS: last-pane toggles between the two most recent panes\n'

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
  printf 'FAIL: default Recent menu exited %s\n' "$rc" >&2
  sed -n '1,120p' "$TMP/stderr" >&2
  exit 1
fi
if [ ! -f "$FZF_CALLED" ]; then
  printf 'FAIL: default Recent menu exited before invoking fzf\n' >&2
  sed -n '1,120p' "$TMP/stderr" >&2
  exit 1
fi
if grep -q 'unbound variable' "$TMP/stderr"; then
  printf 'FAIL: default Recent menu expanded an unset optional argument array\n' >&2
  sed -n '1,120p' "$TMP/stderr" >&2
  exit 1
fi

printf 'PASS: default Recent menu invokes fzf under nounset\n'

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

# --- pane-first list contract -----------------------------------------------
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

strip_ansi() {
  LC_ALL=C sed $'s/\\033\\[[0-9;]*m//g'
}

assert_pane_rows() { # assert_pane_rows <label> <file>
  local label="$1" file="$2"
  [ -s "$file" ] || fail "$label emitted no pane rows"
  awk -F '\t' '
    NF != 3 { printf "row %d has %d fields: %s\n", NR, NF, $0 > "/dev/stderr"; bad=1 }
    $1 !~ /^[^:]+:[0-9]+\.[0-9]+$/ { printf "row %d has non-pane target: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
    END { exit bad }
  ' "$file" || fail "$label violated the canonical three-field live-pane row contract"
  while IFS=$'\t' read -r target _; do
    tmux -L "$SOCKET" display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1 ||
      fail "$label emitted dead target $target"
  done < "$file"
}

tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
tmux -L "$SOCKET" -f /dev/null new-session -d -s alpha -n zero -x 120 -y 40
TMUX="$(tmux -L "$SOCKET" display-message -p '#{socket_path}'),$$,0"
tmux -L "$SOCKET" split-window -d -t alpha:0
tmux -L "$SOCKET" new-window -d -t alpha:1 -n one
tmux -L "$SOCKET" new-session -d -s beta -n zero -x 120 -y 40
tmux -L "$SOCKET" split-window -d -t beta:0

# User-derived titles may contain delimiters/control characters. They must not
# create a fourth field or a physical extra line in the public row protocol.
tmux -L "$SOCKET" select-pane -t alpha:0.0 -T $'unsafe\ttitle\rcontrol'

PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list all > "$TMP/all.rows"
strip_ansi < "$TMP/all.rows" > "$TMP/all.plain"
assert_pane_rows 'All' "$TMP/all.plain"
all_count="$(wc -l < "$TMP/all.plain" | tr -d ' ')"
[ "$all_count" -eq 5 ] || fail "All should emit all 5 panes exactly once (got $all_count)"
if LC_ALL=C grep -q $'\r' "$TMP/all.plain"; then
  fail 'All left a carriage return in user-derived display content'
fi
printf 'PASS: All emits canonical sanitized live-pane rows\n'

PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list tree > "$TMP/tree-alias.rows"
# Detached panes can populate pane_current_path between consecutive tmux scans;
# the compatibility contract is the same ordered target set, not a frozen copy
# of inherently live display metadata.
cut -f1 "$TMP/all.rows" > "$TMP/all.targets"
cut -f1 "$TMP/tree-alias.rows" > "$TMP/tree-alias.targets"
cmp -s "$TMP/all.targets" "$TMP/tree-alias.targets" || fail 'legacy tree alias does not resolve to All'
printf 'PASS: legacy tree alias resolves to All\n'

# Recent is pane-MRU, not window-MRU: newest live pane IDs lead, duplicates and
# dead IDs are ignored, then remaining panes retain canonical server order.
P_ALPHA_0="$(tmux -L "$SOCKET" display-message -p -t alpha:0.0 '#{pane_id}')"
P_ALPHA_1="$(tmux -L "$SOCKET" display-message -p -t alpha:0.1 '#{pane_id}')"
P_BETA_1="$(tmux -L "$SOCKET" display-message -p -t beta:0.1 '#{pane_id}')"
cat > "$TMP/state/pane-mru" <<EOF
$P_ALPHA_0	1
%999999	2
$P_BETA_1	3
$P_ALPHA_0	4
EOF
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent > "$TMP/recent.rows"
strip_ansi < "$TMP/recent.rows" > "$TMP/recent.plain"
assert_pane_rows 'Recent' "$TMP/recent.plain"
recent_first="$(sed -n '1s/\t.*//p' "$TMP/recent.plain")"
recent_second="$(sed -n '2s/\t.*//p' "$TMP/recent.plain")"
[ "$recent_first" = 'alpha:0.0' ] || fail "Recent did not put newest live pane first (got $recent_first)"
[ "$recent_second" = 'beta:0.1' ] || fail "Recent did not preserve the next deduplicated MRU pane (got $recent_second)"
[ "$(wc -l < "$TMP/recent.plain" | tr -d ' ')" -eq 5 ] || fail 'Recent omitted or duplicated live panes'
printf 'PASS: Recent is pane-level, deduplicated, and MRU ordered\n'

# --- Attention ordering, Kimi detection, and empty state -------------------
now="$(date +%s)"
P_ALPHA_W1="$(tmux -L "$SOCKET" display-message -p -t alpha:1.0 '#{pane_id}')"
P_BETA_0="$(tmux -L "$SOCKET" display-message -p -t beta:0.0 '#{pane_id}')"
cat > "$TMP/state/need-input" <<EOF
$P_BETA_1	$((now - 20))	test	new-action	needs approval
$P_ALPHA_1	$((now - 20))	test	other-action	needs input
$P_ALPHA_W1	$((now - 30))	test	done	turn complete
$P_BETA_0	$((now - 40))	test	notice	informational update
-	$((now - 5))	claude	background	needs input
EOF
# pid 0 is an intentionally unresolved but authoritative hook registry row.
printf 'codex\ta:active\t0\t%s\t%s\t%s\tactive\t/tmp\tcodex\n' \
  "$P_ALPHA_0" "$((now - 100))" "$((now - 1))" > "$TMP/state/agent-registry"

PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list attention > "$TMP/attention.rows"
strip_ansi < "$TMP/attention.rows" > "$TMP/attention.plain"
assert_pane_rows 'Attention' "$TMP/attention.plain"
attention_targets="$(cut -f1 "$TMP/attention.plain" | paste -sd ' ' -)"
[ "$attention_targets" = 'alpha:0.1 beta:0.1 alpha:1.0 beta:0.0 alpha:0.0' ] ||
  fail "Attention ordering is not ACTION/DONE/NOTICE/ACTIVE with canonical tie breaks: $attention_targets"
grep -q $'ACTION\|DONE\|NOTICE\|ACTIVE' "$TMP/attention.plain" ||
  fail 'Attention display does not lead with semantic state'
if grep -q '__bg__\|background session\|not a tmux pane' "$TMP/attention.plain"; then
  fail 'Attention exposed a paneless/background mark as a selectable row'
fi
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list needinput > "$TMP/needinput-alias.rows"
cut -f1 "$TMP/attention.rows" > "$TMP/attention.targets"
cut -f1 "$TMP/needinput-alias.rows" > "$TMP/needinput-alias.targets"
cmp -s "$TMP/attention.targets" "$TMP/needinput-alias.targets" || fail 'legacy needinput alias does not resolve to Attention'
printf 'PASS: Attention ordering, paneless omission, and legacy alias are stable\n'

# Default command detection includes Kimi without requiring a configuration
# override. Use a real pane process so this exercises the detector, not registry.
ln -sf /bin/sleep "$FAKE_BIN/kimi"
tmux -L "$SOCKET" respawn-pane -k -t beta:0.0 "$FAKE_BIN/kimi 120"
: > "$TMP/state/need-input"
: > "$TMP/state/agent-registry"
sleep 0.1
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list attention > "$TMP/kimi.rows"
strip_ansi < "$TMP/kimi.rows" > "$TMP/kimi.plain"
grep -qi 'kimi' "$TMP/kimi.plain" || fail 'default Attention command set did not detect a live Kimi pane'
printf 'PASS: default Attention detection includes Kimi\n'

# Empty Attention has no synthetic selectable row; the menu carries the
# explanatory 0/0 state in its persistent header.
: > "$TMP/state/need-input"
: > "$TMP/state/agent-registry"
tmux -L "$SOCKET" respawn-pane -k -t beta:0.0 'sleep 120'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list attention > "$TMP/empty-attention.rows"
[ ! -s "$TMP/empty-attention.rows" ] || fail 'empty Attention emitted a selectable or synthetic row'

cat > "$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TMUX_RADAR_FZF_ARGS"
cat > "$TMUX_RADAR_FZF_INPUT"
SH
chmod +x "$FAKE_BIN/fzf"
export TMUX_RADAR_FZF_ARGS="$TMP/fzf.args"
export TMUX_RADAR_FZF_INPUT="$TMP/fzf.input"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu attention >/dev/null 2>"$TMP/menu-attention.err" ||
  fail 'menu attention failed while rendering its empty state'
grep -qi 'attention' "$TMP/fzf.args" || fail 'menu attention did not open Attention as the initial scope'
grep -Eq '0/0|no detected AI pane' "$TMP/fzf.args" || fail 'empty Attention menu omitted its persistent 0/0 explanation'
[ ! -s "$TMP/fzf.input" ] || fail 'empty Attention menu passed a synthetic row to fzf'
printf 'PASS: menu attention opens directly with a nonselectable empty explanation\n'

# --- exact switch, disappearing target, and switch-command failure ----------
REAL_TMUX="$(command -v tmux)"
export REAL_TMUX
cat > "$FAKE_BIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${TMUX_RADAR_TEST_FAIL_SWITCH:-0}" = 1 ]; then
  case "${1:-}" in
    switch-client|select-window|select-pane)
      printf 'INJECTED_RAW_TMUX_ERROR\n' >&2
      exit 42
      ;;
  esac
fi
# Detached fixtures have no client. Treat switch-client as successful; window
# and pane selection still run against the isolated server and are observable.
[ "${1:-}" = switch-client ] && exit 0
exec "$REAL_TMUX" "$@"
SH
chmod +x "$FAKE_BIN/tmux"
cat > "$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
row="$(printf '%s\n' "$input" | awk -F '\t' -v t="$TMUX_RADAR_TEST_SELECT" '$1 == t { print; exit }')"
if [ "${TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT:-0}" = 1 ]; then
  "$REAL_TMUX" kill-pane -t "$TMUX_RADAR_TEST_SELECT"
fi
printf '%s\n' "$row"
SH
chmod +x "$FAKE_BIN/fzf"

export TMUX_RADAR_TEST_SELECT='alpha:0.1'
unset TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT TMUX_RADAR_TEST_FAIL_SWITCH
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/exact.out" 2>"$TMP/exact.err" ||
  fail 'selecting an exact All pane returned failure'
active_pane="$(tmux -L "$SOCKET" display-message -p -t alpha:0 '#{pane_index}')"
[ "$active_pane" = 1 ] || fail "selection did not switch to the exact pane (active index $active_pane)"
printf 'PASS: selection switches to the exact pane target\n'

tmux -L "$SOCKET" split-window -d -t alpha:1
export TMUX_RADAR_TEST_SELECT='alpha:1.1'
export TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT=1
set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/race.out" 2>"$TMP/race.err"
race_rc=$?
set -e
[ "$race_rc" -ne 0 ] || fail 'disappearing selected pane incorrectly returned success'
grep -q 'pane closed; reopen the switcher' "$TMP/race.err" "$TMP/race.out" 2>/dev/null ||
  { printf '%s\n' '--- disappearing selection stderr ---' >&2; cat "$TMP/race.err" >&2; fail 'disappearing selected pane omitted the concise closed-pane explanation'; }
if grep -qiE 'can.t find pane|no such pane|unknown target' "$TMP/race.err"; then
  fail 'disappearing selected pane leaked a raw tmux error'
fi
printf 'PASS: disappearing selection fails explicitly without partial switching\n'

unset TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT
export TMUX_RADAR_TEST_SELECT='beta:0.0'
export TMUX_RADAR_TEST_FAIL_SWITCH=1
before_target="$(tmux -L "$SOCKET" display-message -p -t alpha '#{session_name}:#{window_index}.#{pane_index}')"
set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/switch-fail.out" 2>"$TMP/switch-fail.err"
switch_rc=$?
set -e
[ "$switch_rc" -ne 0 ] || fail 'injected switch-command failure incorrectly returned success'
! grep -q 'INJECTED_RAW_TMUX_ERROR' "$TMP/switch-fail.err" || fail 'switch-command failure leaked raw tmux stderr'
after_target="$(tmux -L "$SOCKET" display-message -p -t alpha '#{session_name}:#{window_index}.#{pane_index}')"
[ "$after_target" = "$before_target" ] || fail 'switch-command failure partially changed the selected pane'
printf 'PASS: injected switch failure is explicit, nonzero, and non-partial\n'

# --- larger fixture: stable complete pane scan ------------------------------
unset TMUX_RADAR_TEST_FAIL_SWITCH TMUX_RADAR_TEST_SELECT
tmux -L "$SOCKET" new-session -d -s scale -n w0 -x 200 -y 60
for win in 0 1 2; do
  if [ "$win" -gt 0 ]; then tmux -L "$SOCKET" new-window -d -t "scale:$win" -n "w$win"; fi
  # Give each added pane a fixed one-column slice so repeated splits do not
  # exhaust tmux's minimum size before reaching the 30-pane scale fixture.
  for _ in $(seq 1 9); do tmux -L "$SOCKET" split-window -d -h -l 1 -t "scale:$win"; done
done
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list all > "$TMP/large.rows"
strip_ansi < "$TMP/large.rows" > "$TMP/large.plain"
assert_pane_rows 'large All fixture' "$TMP/large.plain"
scale_count="$(awk -F '\t' '$1 ~ /^scale:/ { n++ } END { print n+0 }' "$TMP/large.plain")"
[ "$scale_count" -eq 30 ] || fail "large All scan lost or duplicated panes (got $scale_count, want 30)"
scale_targets="$(awk -F '\t' '$1 ~ /^scale:/ { print $1 }' "$TMP/large.plain")"
expected_targets="$(for win in 0 1 2; do for pane in $(seq 0 9); do printf 'scale:%s.%s\n' "$win" "$pane"; done; done)"
[ "$scale_targets" = "$expected_targets" ] || fail 'large All fixture ordering is not canonical session/window/pane order'
printf 'PASS: 30-pane fixture scans completely in stable canonical order\n'

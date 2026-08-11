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
REAL_TMUX="$(command -v tmux)"
export REAL_TMUX
mkdir -p "$TMP/last-bin"
cat > "$TMP/last-bin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = switch-client ]; then
  target="${3:-}"
  "$REAL_TMUX" select-window -t "$target" >/dev/null 2>&1 || exit 1
  "$REAL_TMUX" select-pane -t "$target" >/dev/null 2>&1 || exit 1
  exit 0
fi
exec "$REAL_TMUX" "$@"
SH
chmod +x "$TMP/last-bin/tmux"
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

PATH="$TMP/last-bin:$PATH" bash "$SWITCHER" last-pane >/dev/null 2>&1
ACTIVE="$(tmux -L "$SOCKET" display-message -p -t mru '#{pane_id}')"
if [ "$ACTIVE" != "$P_W0" ]; then
  printf 'FAIL: last-pane did not jump to the previous pane (want %s got %s)\n' "$P_W0" "$ACTIVE" >&2
  exit 1
fi
printf 'PASS: last-pane jumps to the most recent other pane across windows\n'

bash "$ROOT/scripts/mru-record.sh" "$P_W0"   # what the pane hook records after the jump
PATH="$TMP/last-bin:$PATH" bash "$SWITCHER" last-pane >/dev/null 2>&1
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
  LC_ALL=C sed $'s/\033\\[[0-9;]*m//g'
}

assert_pane_rows() { # assert_pane_rows <label> <file>
  local label="$1" file="$2"
  [ -s "$file" ] || fail "$label emitted no pane rows"
  awk -F '\t' '
    NF != 3 { printf "row %d has %d fields: %s\n", NR, NF, $0 > "/dev/stderr"; bad=1 }
    $1 !~ /^%[0-9]+$/ { printf "row %d has non-pane-id target: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
    $2 !~ /[^:[:space:]]+:[0-9]+\.[0-9]+/ { printf "row %d hides the visible pane location: %s\n", NR, $2 > "/dev/stderr"; bad=1 }
    END { exit bad }
  ' "$file" || fail "$label violated the canonical three-field live-pane row contract"
  while IFS=$'\t' read -r target _; do
    [ "$(tmux -L "$SOCKET" display-message -p -t "$target" '#{pane_id}' 2>/dev/null)" = "$target" ] ||
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
[ "$recent_first" = "$P_ALPHA_0" ] || fail "Recent did not put newest live pane first (got $recent_first)"
[ "$recent_second" = "$P_BETA_1" ] || fail "Recent did not preserve the next deduplicated MRU pane (got $recent_second)"
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
[ "$attention_targets" = "$P_ALPHA_1 $P_BETA_1 $P_ALPHA_W1 $P_BETA_0 $P_ALPHA_0" ] ||
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

# Attention mark fields are user-controlled. Strip CR/ESC/control bytes from
# source, label, saved title, and session keys while retaining renderer-owned
# ANSI badges.
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$P_ALPHA_1" "$((now - 10))" $'hook\rsource\033X' $'s:mark\rkey\033X' \
  $'your\r turn\033Y' $'saved\rtitle\033Z' > "$TMP/state/need-input"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  $'co\033dex' $'s:reg\rkey\033X' 0 "$P_ALPHA_0" "$((now - 100))" "$((now - 1))" \
  $'active\rstate\033X' '/tmp' 'codex' > "$TMP/state/agent-registry"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list attention > "$TMP/attention-controls.rows"
grep -q $'\033\[' "$TMP/attention-controls.rows" || fail 'Attention sanitization removed renderer-owned ANSI'
strip_ansi < "$TMP/attention-controls.rows" > "$TMP/attention-controls.plain"
assert_pane_rows 'Attention control fixture' "$TMP/attention-controls.plain"
if LC_ALL=C grep -q $'\r\|\033' "$TMP/attention-controls.plain"; then
  fail 'Attention leaked CR/ESC from mark source, label, or saved title'
fi
grep -q 'hook source' "$TMP/attention-controls.plain" || fail 'Attention lost sanitized source text'
grep -q 'your turn' "$TMP/attention-controls.plain" || fail 'Attention lost sanitized label text'
grep -q 'saved title' "$TMP/attention-controls.plain" || fail 'Attention lost sanitized saved-title text'
grep -q 'co dex' "$TMP/attention-controls.plain" || fail 'Attention lost sanitized registry kind'
grep -q 'active state X' "$TMP/attention-controls.plain" || fail 'Attention lost sanitized registry state'
grep -q 'DONE' "$TMP/attention-controls.plain" || fail 'Attention classified sanitized completion label incorrectly'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" preview "$P_ALPHA_1" > "$TMP/preview-controls.out"
strip_ansi < "$TMP/preview-controls.out" > "$TMP/preview-controls.plain"
if LC_ALL=C grep -q $'\r\|\033' "$TMP/preview-controls.plain"; then
  fail 'preview leaked CR/ESC from Attention metadata'
fi
grep -q '^✓' "$TMP/preview-controls.plain" || fail 'preview semantics diverged from sanitized Attention completion label'
grep -q 'sid mark key' "$TMP/preview-controls.plain" || fail 'preview lost the sanitized mark session key'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" preview "$P_ALPHA_0" > "$TMP/preview-registry-controls.out"
strip_ansi < "$TMP/preview-registry-controls.out" > "$TMP/preview-registry-controls.plain"
if LC_ALL=C grep -q $'\r\|\033' "$TMP/preview-registry-controls.plain"; then
  fail 'preview leaked CR/ESC from the registry session key'
fi
grep -q 'sid reg key ' "$TMP/preview-registry-controls.plain" || fail 'preview lost the sanitized registry session key'
printf 'PASS: Attention and preview sanitize user control bytes while retaining renderer ANSI\n'

# Equal-severity/equal-epoch marks retain canonical tmux server order. Create a
# lexically earlier session after the existing panes so pane-id creation order
# is deliberately the opposite of server order.
tmux -L "$SOCKET" new-session -d -s aardvark -n zero -x 120 -y 40
P_AARDVARK_0="$(tmux -L "$SOCKET" display-message -p -t aardvark:0.0 '#{pane_id}')"
cat > "$TMP/state/need-input" <<EOF
$P_AARDVARK_0	$((now - 20))	test	tie-action	needs input
$P_BETA_1	$((now - 20))	test	tie-action	needs input
EOF
: > "$TMP/state/agent-registry"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list attention > "$TMP/attention-ties.rows"
tie_targets="$(cut -f1 "$TMP/attention-ties.rows" | paste -sd ' ' -)"
[ "$tie_targets" = "$P_AARDVARK_0 $P_BETA_1" ] ||
  fail "equal-epoch Attention ties did not preserve canonical server order: $tie_targets"
tmux -L "$SOCKET" kill-session -t aardvark
printf 'PASS: equal-epoch Attention ties preserve canonical server order\n'

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
export TMUX_RADAR_TEST_TMUX_LOG="$TMP/tmux.log"
cat > "$FAKE_BIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-panes ] && [ "${TMUX_RADAR_TEST_FAIL_LIST:-0}" = 1 ]; then
  printf 'INJECTED_RAW_LIST_ERROR\n' >&2
  exit 41
fi
case "${1:-}" in
  switch-client|select-window|select-pane)
    printf '%s\n' "$*" >> "$TMUX_RADAR_TEST_TMUX_LOG"
    ;;
esac
if [ "${1:-}" = switch-client ]; then
  if [ "${TMUX_RADAR_TEST_FAIL_SWITCH:-0}" = 1 ]; then
    printf 'INJECTED_RAW_TMUX_ERROR\n' >&2
    exit 42
  fi
  target="${3:-}"
  # Detached fixtures have no client. Model a successful atomic client switch
  # by selecting the target window/pane on the isolated server.
  "$REAL_TMUX" select-window -t "$target" >/dev/null 2>&1 || exit 43
  "$REAL_TMUX" select-pane -t "$target" >/dev/null 2>&1 || exit 43
  exit 0
fi
exec "$REAL_TMUX" "$@"
SH
chmod +x "$FAKE_BIN/tmux"
cat > "$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
[ -n "${TMUX_RADAR_TEST_FZF_MARKER:-}" ] && : > "$TMUX_RADAR_TEST_FZF_MARKER"
if [ -n "${TMUX_RADAR_TEST_FZF_EXIT:-}" ]; then
  printf 'INJECTED_RAW_FZF_ERROR\033[31m\n' >&2
  exit "$TMUX_RADAR_TEST_FZF_EXIT"
fi
row="$(printf '%s\n' "$input" | awk -F '\t' -v t="$TMUX_RADAR_TEST_SELECT" '$1 == t { print; exit }')"
if [ "${TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT:-0}" = 1 ]; then
  old_coord="$("$REAL_TMUX" display-message -p -t "$TMUX_RADAR_TEST_SELECT" '#{session_name}:#{window_index}.#{pane_index}')"
  "$REAL_TMUX" kill-pane -t "$TMUX_RADAR_TEST_SELECT"
  replacement="$("$REAL_TMUX" display-message -p -t "$old_coord" '#{pane_id}' 2>/dev/null || true)"
  if [ -z "$replacement" ]; then
    replacement="$("$REAL_TMUX" split-window -d -P -F '#{pane_id}' -t "${old_coord%.*}")"
  fi
  printf '%s\t%s\n' "$old_coord" "$replacement" > "$TMUX_RADAR_TEST_REUSE_PROOF"
fi
printf '%s\n' "$row"
SH
chmod +x "$FAKE_BIN/fzf"

# List generation is distinct from fzf. Producer failures are nonzero and
# sanitized, and fzf is never invoked on a failed initial list.
export TMUX_RADAR_TEST_FZF_MARKER="$TMP/fzf-invoked"
export TMUX_RADAR_TEST_FAIL_LIST=1
for view in all recent attention; do
  set +e
  PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list "$view" >"$TMP/list-$view.out" 2>"$TMP/list-$view.err"
  list_rc=$?
  set -e
  [ "$list_rc" -ne 0 ] || fail "list $view failure incorrectly returned success"
  grep -q 'unable to list panes' "$TMP/list-$view.err" || fail "list $view failure omitted concise diagnostic"
  ! grep -q 'INJECTED_RAW_LIST_ERROR' "$TMP/list-$view.err" || fail "list $view leaked raw tmux stderr"
done
rm -f "$TMUX_RADAR_TEST_FZF_MARKER"
set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/menu-list-fail.out" 2>"$TMP/menu-list-fail.err"
menu_list_rc=$?
set -e
[ "$menu_list_rc" -ne 0 ] || fail 'menu list failure incorrectly returned success'
[ ! -e "$TMUX_RADAR_TEST_FZF_MARKER" ] || fail 'menu invoked fzf after list generation failed'
grep -q 'unable to list panes' "$TMP/menu-list-fail.err" || fail 'menu list failure omitted concise diagnostic'
! grep -q 'INJECTED_RAW_LIST_ERROR' "$TMP/menu-list-fail.err" || fail 'menu list failure leaked raw tmux stderr'
unset TMUX_RADAR_TEST_FAIL_LIST
printf 'PASS: list failures are explicit and stop before fzf\n'

# fzf exit 1 (no match) and 130 (cancel) are clean success; internal failures
# are nonzero, sanitized, and do not mutate switch or MRU state.
cp "$TMP/state/pane-mru" "$TMP/fzf.mru.before"
for fzf_exit in 1 130; do
  export TMUX_RADAR_TEST_FZF_EXIT="$fzf_exit"
  : > "$TMUX_RADAR_TEST_TMUX_LOG"
  PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/fzf-$fzf_exit.out" 2>"$TMP/fzf-$fzf_exit.err" ||
    fail "fzf exit $fzf_exit should be a clean cancellation"
  ! [ -s "$TMUX_RADAR_TEST_TMUX_LOG" ] || fail "fzf exit $fzf_exit attempted a switch"
  cmp -s "$TMP/fzf.mru.before" "$TMP/state/pane-mru" || fail "fzf exit $fzf_exit mutated MRU"
done
export TMUX_RADAR_TEST_FZF_EXIT=2
: > "$TMUX_RADAR_TEST_TMUX_LOG"
set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/fzf-2.out" 2>"$TMP/fzf-2.err"
fzf_rc=$?
set -e
[ "$fzf_rc" -ne 0 ] || fail 'fzf exit 2 incorrectly returned success'
grep -q 'picker failed' "$TMP/fzf-2.err" || fail 'fzf exit 2 omitted concise diagnostic'
! grep -q 'INJECTED_RAW_FZF_ERROR' "$TMP/fzf-2.err" || fail 'fzf exit 2 leaked raw stderr'
! [ -s "$TMUX_RADAR_TEST_TMUX_LOG" ] || fail 'fzf exit 2 attempted a switch'
cmp -s "$TMP/fzf.mru.before" "$TMP/state/pane-mru" || fail 'fzf exit 2 mutated MRU'
unset TMUX_RADAR_TEST_FZF_EXIT
printf 'PASS: only fzf cancel/no-match exits are successful\n'

export TMUX_RADAR_TEST_SELECT="$P_ALPHA_1"
unset TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT TMUX_RADAR_TEST_FAIL_SWITCH
: > "$TMUX_RADAR_TEST_TMUX_LOG"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/exact.out" 2>"$TMP/exact.err" ||
  fail 'selecting an exact All pane returned failure'
active_pane="$(tmux -L "$SOCKET" display-message -p -t alpha:0 '#{pane_index}')"
[ "$active_pane" = 1 ] || fail "selection did not switch to the exact pane (active index $active_pane)"
switch_log="$(cat "$TMUX_RADAR_TEST_TMUX_LOG")"
[ "$switch_log" = "switch-client -t $P_ALPHA_1" ] || fail "exact selection was not one stable-id switch: $switch_log"
[ "$(tail -1 "$TMP/state/pane-mru" | cut -f1)" = "$P_ALPHA_1" ] || fail 'successful switch did not record MRU after switching'
printf 'PASS: selection switches to the exact pane target\n'

tmux -L "$SOCKET" split-window -d -t alpha:0
TMUX_RADAR_TEST_SELECT="$(tmux -L "$SOCKET" list-panes -t alpha:0 -F '#{pane_index} #{pane_id}' | sort -n | sed -n '2s/^[^ ]* //p')"
export TMUX_RADAR_TEST_SELECT
export TMUX_RADAR_TEST_REUSE_PROOF="$TMP/reuse.proof"
export TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT=1
cp "$TMP/state/pane-mru" "$TMP/race.mru.before"
: > "$TMUX_RADAR_TEST_TMUX_LOG"
set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/race.out" 2>"$TMP/race.err"
race_rc=$?
set -e
[ "$race_rc" -ne 0 ] || fail 'disappearing selected pane incorrectly returned success'
IFS=$'\t' read -r reused_coord replacement_id < "$TMUX_RADAR_TEST_REUSE_PROOF"
[ -n "$replacement_id" ] && [ "$replacement_id" != "$TMUX_RADAR_TEST_SELECT" ] || fail 'race fixture did not reuse the killed pane coordinate'
[ "$(tmux -L "$SOCKET" display-message -p -t "$reused_coord" '#{pane_id}')" = "$replacement_id" ] || fail 'race fixture lost its coordinate replacement proof'
grep -q 'pane closed; reopen the switcher' "$TMP/race.err" "$TMP/race.out" 2>/dev/null ||
  { printf '%s\n' '--- disappearing selection stderr ---' >&2; cat "$TMP/race.err" >&2; fail 'disappearing selected pane omitted the concise closed-pane explanation'; }
if grep -qiE 'can.t find pane|no such pane|unknown target' "$TMP/race.err"; then
  fail 'disappearing selected pane leaked a raw tmux error'
fi
! [ -s "$TMUX_RADAR_TEST_TMUX_LOG" ] || fail 'dead stable pane ID attempted a switch'
cmp -s "$TMP/race.mru.before" "$TMP/state/pane-mru" || fail 'dead stable pane ID mutated MRU'
printf 'PASS: disappearing selection fails explicitly without partial switching\n'

unset TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT
export TMUX_RADAR_TEST_SELECT="$P_BETA_0"
export TMUX_RADAR_TEST_FAIL_SWITCH=1
cp "$TMP/state/pane-mru" "$TMP/switch-fail.mru.before"
: > "$TMUX_RADAR_TEST_TMUX_LOG"
before_target="$(tmux -L "$SOCKET" display-message -p -t alpha '#{session_name}:#{window_index}.#{pane_index}')"
set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/switch-fail.out" 2>"$TMP/switch-fail.err"
switch_rc=$?
set -e
[ "$switch_rc" -ne 0 ] || fail 'injected switch-command failure incorrectly returned success'
! grep -q 'INJECTED_RAW_TMUX_ERROR' "$TMP/switch-fail.err" || fail 'switch-command failure leaked raw tmux stderr'
after_target="$(tmux -L "$SOCKET" display-message -p -t alpha '#{session_name}:#{window_index}.#{pane_index}')"
[ "$after_target" = "$before_target" ] || fail 'switch-command failure partially changed the selected pane'
switch_log="$(cat "$TMUX_RADAR_TEST_TMUX_LOG")"
[ "$switch_log" = "switch-client -t $P_BETA_0" ] || fail "failure path was not one stable-id switch attempt: $switch_log"
cmp -s "$TMP/switch-fail.mru.before" "$TMP/state/pane-mru" || fail 'failed switch mutated pane MRU'
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
scale_count="$(awk -F '\t' '$2 ~ /^scale:/ { n++ } END { print n+0 }' "$TMP/large.plain")"
[ "$scale_count" -eq 30 ] || fail "large All scan lost or duplicated panes (got $scale_count, want 30)"
scale_targets="$(awk -F '\t' '$2 ~ /^scale:/ { split($2, a, " · "); print a[1] }' "$TMP/large.plain")"
expected_targets="$(for win in 0 1 2; do for pane in $(seq 0 9); do printf 'scale:%s.%s\n' "$win" "$pane"; done; done)"
[ "$scale_targets" = "$expected_targets" ] || fail 'large All fixture ordering is not canonical session/window/pane order'
printf 'PASS: 30-pane fixture scans completely in stable canonical order\n'

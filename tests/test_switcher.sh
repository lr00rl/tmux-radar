#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWITCHER="$ROOT/scripts/switcher.sh"
NOTIFY="$ROOT/scripts/needinput-notify.sh"
REAL_FZF="$(command -v fzf || true)"
TMP="$(mktemp -d /tmp/radar-sw.XXXXXX)"
SOCKET="rs$$"
FAKE_BIN="$TMP/bin"
FZF_CALLED="$TMP/fzf-called"

cleanup() {
  [ -z "${ATT_REG_PID:-}" ] || kill "$ATT_REG_PID" >/dev/null 2>&1 || true
  [ -z "${TICK_HOLDER_PID:-}" ] || kill "$TICK_HOLDER_PID" >/dev/null 2>&1 || true
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_BIN" "$TMP/state"
[ -n "$REAL_FZF" ] || { printf 'FAIL: fzf is required for search integration tests\n' >&2; exit 1; }
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

PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list tree > "$TMP/tree.rows"
strip_ansi < "$TMP/tree.rows" > "$TMP/tree.plain"
awk -F '\t' '
  NF != 3 { bad=1 }
  $1 ~ /^%[0-9]+$/ { panes++; next }
  $2 ~ /alpha|beta/ { structural++ }
  END { exit !(bad == 0 && panes == 5 && structural == 5) }
' "$TMP/tree.plain" || fail 'Tree is not a canonical 2-session/3-window/5-pane hierarchy'
awk -F '\t' '$1 ~ /^%[0-9]+$/ { print $1 }' "$TMP/tree.plain" > "$TMP/tree-pane.targets"
tmux -L "$SOCKET" list-panes -a -F '#{pane_id}' > "$TMP/live-pane.targets"
cmp -s "$TMP/tree-pane.targets" "$TMP/live-pane.targets" ||
  fail 'Tree pane leaves are not stable pane IDs in canonical server order'
TREE_STRUCT_TARGET="$(awk -F '\t' '$1 !~ /^%[0-9]+$/ { print $1; exit }' "$TMP/tree.plain")"
[ -n "$TREE_STRUCT_TARGET" ] || fail 'Tree omitted non-accepting structural session/window rows'
if LC_ALL=C grep -q $'\r' "$TMP/tree.plain"; then
  fail 'Tree left a carriage return in user-derived display content'
fi

# `all` is accepted for old callers, but resolves to the Tree product surface.
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list all > "$TMP/all-alias.rows"
strip_ansi < "$TMP/all-alias.rows" > "$TMP/all-alias.plain"
cut -f1 "$TMP/tree.plain" > "$TMP/tree.targets"
cut -f1 "$TMP/all-alias.plain" > "$TMP/all-alias.targets"
cmp -s "$TMP/tree.targets" "$TMP/all-alias.targets" || fail 'all compatibility alias does not resolve to Tree'
printf 'PASS: Tree emits canonical structural hierarchy and all is only its compatibility alias\n'

# Recent is pane-MRU, not window-MRU: only recorded live pane IDs appear;
# newest wins, duplicates collapse, and dead IDs are ignored.
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
[ "$(wc -l < "$TMP/recent.plain" | tr -d ' ')" -eq 2 ] || fail 'Recent appended live panes that were not recorded in pane MRU'

# Search identity starts with the user-assigned window name. Location, cwd,
# command, pane title, and AI metadata may follow but cannot outrank it.
tmux -L "$SOCKET" rename-window -t alpha:0 'user-search-name'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent > "$TMP/recent-search.rows"
strip_ansi < "$TMP/recent-search.rows" > "$TMP/recent-search.plain"
awk -F '\t' -v pane="$P_ALPHA_0" '$1 == pane { exit !($2 ~ /^user-search-name([[:space:]\/]|$)/) } END { if (NR == 0) exit 1 }' \
  "$TMP/recent-search.plain" || fail 'pane search text does not begin with the user window name'

: > "$TMP/state/pane-mru"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent > "$TMP/recent-empty.rows"
[ ! -s "$TMP/recent-empty.rows" ] || fail 'empty pane MRU emitted Recent rows'
rm -f "$TMP/state/pane-mru"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent > "$TMP/recent-missing.rows"
[ ! -s "$TMP/recent-missing.rows" ] || fail 'missing pane MRU emitted Recent rows'
printf '%s\t1\n%s\t2\n' "$P_ALPHA_0" "$P_BETA_1" > "$TMP/state/pane-mru"
printf 'PASS: Recent contains only live recorded panes and window name leads search text\n'

# --- Attention ordering, Kimi detection, and empty state -------------------
now="$(date +%s)"
P_ALPHA_W1="$(tmux -L "$SOCKET" display-message -p -t alpha:1.0 '#{pane_id}')"
P_BETA_0="$(tmux -L "$SOCKET" display-message -p -t beta:0.0 '#{pane_id}')"
sleep 300 & ATT_REG_PID=$!
cat > "$TMP/state/need-input" <<EOF
$P_BETA_1	$((now - 20))	test	new-action	needs approval
$P_ALPHA_1	$((now - 20))	test	other-action	needs input
$P_ALPHA_W1	$((now - 30))	test	done	turn complete
$P_BETA_0	$((now - 40))	test	notice	informational update
-	$((now - 5))	claude	background	needs input
EOF
# Every marked pane gets positive PID + argv identity evidence: a mark alone
# must never make a pane eligible for Attention.
{
  printf 'codex\ta:action-1\t%s\t%s\t%s\t%s\twaiting\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_BETA_1" "$((now - 100))" "$((now - 1))"
  printf 'codex\ta:action-2\t%s\t%s\t%s\t%s\twaiting\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_ALPHA_1" "$((now - 100))" "$((now - 1))"
  printf 'codex\ta:done\t%s\t%s\t%s\t%s\tdone\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_ALPHA_W1" "$((now - 100))" "$((now - 1))"
  printf 'codex\ta:notice\t%s\t%s\t%s\t%s\tactive\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_BETA_0" "$((now - 100))" "$((now - 1))"
  printf 'codex\ta:active\t%s\t%s\t%s\t%s\tactive\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_ALPHA_0" "$((now - 100))" "$((now - 1))"
} > "$TMP/state/agent-registry"

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

# Registry rows are evidence only when their process identity is current.
printf '%s\t%s\ttest\ts:pid-zero\tneeds input\t\n' \
  "$P_ALPHA_1" "$((now - 10))" > "$TMP/state/need-input"
printf 'codex\ts:pid-zero\t0\t%s\t%s\t%s\twaiting\t/tmp\tcodex\n' \
  "$P_ALPHA_1" "$((now - 100))" "$((now - 1))" > "$TMP/state/agent-registry"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list attention > "$TMP/attention-pid-zero.rows"
[ ! -s "$TMP/attention-pid-zero.rows" ] || fail 'unresolved PID-0 registry row created false Attention liveness'
printf 'codex\ts:pid-reuse\t%s\t%s\t%s\t%s\twaiting\t/tmp\tcodex\n' \
  "$ATT_REG_PID" "$P_ALPHA_1" "$((now - 100))" "$((now - 1))" > "$TMP/state/agent-registry"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list attention > "$TMP/attention-pid-reuse.rows"
[ ! -s "$TMP/attention-pid-reuse.rows" ] || fail 'PID reuse with mismatched argv created false Attention liveness'
printf 'PASS: Attention rejects unresolved and argv-mismatched registry liveness\n'

# Attention mark fields are user-controlled. Strip CR/ESC/control bytes from
# source, label, saved title, and session keys while retaining renderer-owned
# ANSI badges.
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$P_ALPHA_1" "$((now - 10))" $'hook\rsource\033X' $'s:mark\rkey\033X' \
  $'your\r turn\033Y' $'saved\rtitle\033Z' > "$TMP/state/need-input"
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    'codex' $'s:mark\rkey\033X' "$ATT_REG_PID" "$P_ALPHA_1" "$((now - 100))" "$((now - 1))" \
    'waiting' '/tmp' 'sleep'
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    $'co\033dex' $'s:reg\rkey\033X' "$ATT_REG_PID" "$P_ALPHA_0" "$((now - 100))" "$((now - 1))" \
    $'active\rstate\033X' '/tmp' 'sleep'
} > "$TMP/state/agent-registry"
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

# The public notifier API must keep its persisted TSV safe, not merely rely on
# the switcher renderer to repair unsafe hook data on read.
: > "$TMP/state/need-input"
: > "$TMP/state/agent-registry"
# shellcheck disable=SC2329 # exported below; invoked inside the notifier child
tmux() {
  case " $* " in
    *' #{pane_title} '*) printf '%s' $'saved\ttitle\rcontrol\033X'; return 0 ;;
  esac
  "$REAL_TMUX" "$@"
}
export -f tmux
env -u CLAUDE_JOB_DIR "$NOTIFY" mark "$P_ALPHA_1" \
  $'hook\tsource\rcontrol\033X' $'your\t\rturn\033Y' $'s:mark\t\rkey\033Z'
unset -f tmux
[ "$(wc -l < "$TMP/state/need-input" | tr -d ' ')" -eq 1 ] ||
  fail 'public mark API wrote more than one physical state row'
awk -F '\t' 'NF == 6 { ok=1 } END { exit !ok }' "$TMP/state/need-input" ||
  fail 'public mark API did not preserve the exact six-field TSV contract'
if LC_ALL=C tr -d '\t\n' < "$TMP/state/need-input" | LC_ALL=C grep -q '[[:cntrl:]]'; then
  fail 'public mark API persisted an unsafe control byte'
fi
IFS=$'\t' read -r _mark_pane _mark_epoch mark_source mark_key mark_label mark_title < "$TMP/state/need-input"
[ "$mark_source" = 'hook source control X' ] || fail "public mark API normalized source incorrectly: $mark_source"
[ "$mark_key" = 's:mark key Z' ] || fail "public mark API normalized key incorrectly: $mark_key"
[ "$mark_label" = 'your turn Y' ] || fail "public mark API normalized label incorrectly: $mark_label"
[ "$mark_title" = 'saved title control X' ] || fail "public mark API normalized saved title incorrectly: $mark_title"
printf 'codex\t%s\t%s\t%s\t%s\t%s\tdone\t/tmp\tsleep\n' \
  "$mark_key" "$ATT_REG_PID" "$P_ALPHA_1" "$((now - 100))" "$((now - 1))" > "$TMP/state/agent-registry"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list attention > "$TMP/public-mark.rows"
strip_ansi < "$TMP/public-mark.rows" > "$TMP/public-mark.plain"
assert_pane_rows 'public mark Attention fixture' "$TMP/public-mark.plain"
grep -q 'DONE' "$TMP/public-mark.plain" || fail 'public mark API normalization changed Attention semantics'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" preview "$P_ALPHA_1" > "$TMP/public-mark-preview.out"
strip_ansi < "$TMP/public-mark-preview.out" > "$TMP/public-mark-preview.plain"
if { cat "$TMP/public-mark.plain" "$TMP/public-mark-preview.plain" | LC_ALL=C tr -d '\t\n' | LC_ALL=C grep -q '[[:cntrl:]]'; }; then
  fail 'public mark API leaked unsafe controls into Attention or preview'
fi
grep -q 'sid mark key' "$TMP/public-mark-preview.plain" || fail 'preview lost the normalized public mark session key'
printf 'PASS: public mark API persists normalized six-field Attention metadata\n'

# Equal-severity/equal-epoch marks retain canonical tmux server order. Create a
# lexically earlier session after the existing panes so pane-id creation order
# is deliberately the opposite of server order.
tmux -L "$SOCKET" new-session -d -s aardvark -n zero -x 120 -y 40
P_AARDVARK_0="$(tmux -L "$SOCKET" display-message -p -t aardvark:0.0 '#{pane_id}')"
cat > "$TMP/state/need-input" <<EOF
$P_AARDVARK_0	$((now - 20))	test	tie-action	needs input
$P_BETA_1	$((now - 20))	test	tie-action	needs input
EOF
{
  printf 'codex\ta:tie-a\t%s\t%s\t%s\t%s\twaiting\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_AARDVARK_0" "$((now - 100))" "$((now - 1))"
  printf 'codex\ta:tie-b\t%s\t%s\t%s\t%s\twaiting\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_BETA_1" "$((now - 100))" "$((now - 1))"
} > "$TMP/state/agent-registry"
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

grep -Eq -- '--tiebreak(=|$).*begin,index|--tiebreak=begin,index' "$TMP/fzf.args" ||
  fail 'fzf does not tie-break relevance by beginning position then input order'
! grep -qx -- '--nth=2..' "$TMP/fzf.args" ||
  fail 'fzf excludes the window-name search field after applying with-nth'
grep -q 'C-t Tree' "$TMP/fzf.args" || fail 'picker header does not advertise C-t Tree'
grep -Eq 'ctrl-t:transform\([^)]*set-view tree\)' "$TMP/fzf.args" ||
  fail 'C-t does not switch to the Tree view'
search_order="$(
  printf '%%1\tpriority-window alpha:0.0/title\t/tmp · zsh\n%%2\tother-window alpha:0.1/title\t/tmp/priority-window · zsh\n' |
    "$REAL_FZF" --filter='priority-window' --delimiter=$'\t' --with-nth=2.. --tiebreak=begin,index |
    cut -f1 | paste -sd ' ' -
)"
[ "$search_order" = '%1 %2' ] || fail "window-name match did not outrank metadata-only match: $search_order"
printf 'PASS: picker binds C-t to Tree and ranks beginning matches before input-order ties\n'

# Cleanup must complete before fzf sees its first row, even when Recent/Tree is
# the initial view. A deliberately slow ps snapshot makes the old background
# tick race deterministic.
tmux -L "$SOCKET" select-pane -t "$P_ALPHA_1" -T 'title-before-picker'
: > "$TMP/state/agent-registry"
env -u CLAUDE_JOB_DIR "$NOTIFY" mark "$P_ALPHA_1" claude 'Claude finished — your turn' s:first-render
cat > "$FAKE_BIN/slow-ps" <<'SH'
#!/usr/bin/env bash
sleep 1
exec /bin/ps "$@"
SH
chmod +x "$FAKE_BIN/slow-ps"
cat > "$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
if grep -q 's:first-render' "$TMUX_RADAR_STATE_DIR/need-input" 2>/dev/null; then
  : > "$TMUX_RADAR_FIRST_RENDER_STALE"
fi
cat >/dev/null
SH
chmod +x "$FAKE_BIN/fzf"
export TMUX_RADAR_FIRST_RENDER_STALE="$TMP/first-render-stale"
PATH="$FAKE_BIN:$PATH" TMUX_RADAR_TEST_PS_BIN="$FAKE_BIN/slow-ps" \
  bash "$SWITCHER" menu recent >/dev/null 2>"$TMP/menu-first-render.err" ||
  fail 'Recent menu failed during synchronous-cleanup fixture'
[ ! -e "$TMUX_RADAR_FIRST_RENDER_STALE" ] || fail 'picker first render raced ahead of stale AI cleanup'
sleep 1.1
printf 'PASS: picker first render observes completed stale-AI cleanup\n'

# A synchronous cleanup failure must fail the render/reload transaction rather
# than publishing stale rows as if cleanup succeeded.
sleep 30 & TICK_HOLDER_PID=$!
mkdir -p "$TMP/state/.need-input.lock"
printf '%s' "$TICK_HOLDER_PID" > "$TMP/state/.need-input.lock/pid"
cat > "$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
: > "$TMUX_RADAR_FZF_CALLED"
cat >/dev/null
SH
chmod +x "$FAKE_BIN/fzf"
rm -f "$TMUX_RADAR_FZF_CALLED"
set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu recent >"$TMP/tick-fail.out" 2>"$TMP/tick-fail.err"
tick_menu_rc=$?
set -e
[ "$tick_menu_rc" -ne 0 ] || fail 'initial cleanup failure was reported as a successful menu render'
[ ! -e "$TMUX_RADAR_FZF_CALLED" ] || fail 'fzf opened after initial cleanup failed'
grep -q 'unable to refresh AI state' "$TMP/tick-fail.err" || fail 'initial cleanup failure omitted its concise diagnostic'
printf 'recent\n' > "$TMP/tick-fail.state"
: > "$TMP/tick-fail.rows"
rm -f "$TMP/tick-fail.error"
tick_action="$(SW_STATE="$TMP/tick-fail.state" SW_ROWS="$TMP/tick-fail.rows" SW_ERROR="$TMP/tick-fail.error" \
  PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" set-view tree)"
[ "$tick_action" = abort ] || fail 'reload cleanup failure did not abort the fzf transform'
[ -e "$TMP/tick-fail.error" ] || fail 'reload cleanup failure omitted the producer error marker'
kill "$TICK_HOLDER_PID" 2>/dev/null; wait "$TICK_HOLDER_PID" 2>/dev/null || true
unset TICK_HOLDER_PID
rm -rf "$TMP/state/.need-input.lock"
printf 'PASS: cleanup failures abort initial and reload rendering\n'

# --- exact switch, disappearing target, and switch-command failure ----------
export TMUX_RADAR_TEST_TMUX_LOG="$TMP/tmux.log"
cat > "$FAKE_BIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-panes ] && [ "${TMUX_RADAR_TEST_FAIL_RELOAD:-0}" = 1 ]; then
  count="$(cat "$TMUX_RADAR_TEST_LIST_COUNT" 2>/dev/null || printf 0)"
  count=$((count + 1))
  printf '%s\n' "$count" > "$TMUX_RADAR_TEST_LIST_COUNT"
  if [ "$count" -gt 1 ]; then
    printf 'INJECTED_RAW_LIST_ERROR\033[31m\n' >&2
    exit 41
  fi
fi
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
for view in tree all recent attention; do
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

# A scope reload is a second producer transaction. If it fails after the
# initial list succeeds, fzf must abort and the menu must report producer
# failure rather than treating abort/no-match as a clean empty result.
export TMUX_RADAR_TEST_FAIL_RELOAD=1
export TMUX_RADAR_TEST_LIST_COUNT="$TMP/reload-list-count"
export TMUX_RADAR_TEST_SWITCHER="$SWITCHER"
rm -f "$TMUX_RADAR_TEST_LIST_COUNT"
cat > "$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
action="$(bash "$TMUX_RADAR_TEST_SWITCHER" set-view attention)"
[ "$action" = abort ] && exit 130
printf 'unexpected transform action: %s\n' "$action" >&2
exit 2
SH
chmod +x "$FAKE_BIN/fzf"
set +e
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu all >"$TMP/reload-fail.out" 2>"$TMP/reload-fail.err"
reload_rc=$?
set -e
[ "$reload_rc" -ne 0 ] || fail 'scope reload list failure incorrectly returned success'
grep -q 'unable to list panes' "$TMP/reload-fail.err" || fail 'scope reload failure omitted concise producer diagnostic'
! grep -q 'INJECTED_RAW_LIST_ERROR' "$TMP/reload-fail.err" || fail 'scope reload failure leaked raw tmux stderr'
! grep -q 'picker failed' "$TMP/reload-fail.err" || fail 'scope reload producer failure was misreported as picker failure'
[ "$(cat "$TMUX_RADAR_TEST_LIST_COUNT")" -ge 2 ] || fail 'scope reload regression did not exercise a successful initial list followed by reload'
unset TMUX_RADAR_TEST_FAIL_RELOAD TMUX_RADAR_TEST_LIST_COUNT TMUX_RADAR_TEST_SWITCHER
printf 'PASS: scope reload producer failures abort the menu explicitly\n'

# Restore the selection-capable fake picker for the remaining menu scenarios.
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

# Structural Tree rows are context only: even a picker implementation that
# returns one defensively must not switch, mutate MRU, or report an error.
export TMUX_RADAR_TEST_SELECT="$TREE_STRUCT_TARGET"
: > "$TMUX_RADAR_TEST_TMUX_LOG"
cp "$TMP/state/pane-mru" "$TMP/tree-struct.mru.before" 2>/dev/null || : > "$TMP/tree-struct.mru.before"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu tree >"$TMP/tree-struct.out" 2>"$TMP/tree-struct.err" ||
  fail 'selecting a structural Tree row was not a clean no-op'
! [ -s "$TMUX_RADAR_TEST_TMUX_LOG" ] || fail 'structural Tree row attempted a tmux switch'
cmp -s "$TMP/tree-struct.mru.before" "$TMP/state/pane-mru" || fail 'structural Tree row mutated pane MRU'
printf 'PASS: structural Tree rows are non-accepting\n'

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
awk -F '\t' '$1 ~ /^%[0-9]+$/ { print }' "$TMP/large.plain" > "$TMP/large-pane.plain"
assert_pane_rows 'large Tree pane leaves' "$TMP/large-pane.plain"
scale_count="$(awk -F '\t' '$1 ~ /^%[0-9]+$/ && $2 ~ /scale:[0-9]+\.[0-9]+/ { n++ } END { print n+0 }' "$TMP/large.plain")"
[ "$scale_count" -eq 30 ] || fail "large Tree scan lost or duplicated panes (got $scale_count, want 30)"
scale_targets="$(awk -F '\t' '
  $1 ~ /^%[0-9]+$/ && match($2, /scale:[0-9]+\.[0-9]+/) {
    print substr($2, RSTART, RLENGTH)
  }
' "$TMP/large.plain")"
expected_targets="$(for win in 0 1 2; do for pane in $(seq 0 9); do printf 'scale:%s.%s\n' "$win" "$pane"; done; done)"
[ "$scale_targets" = "$expected_targets" ] || fail 'large Tree pane ordering is not canonical session/window/pane order'
printf 'PASS: 30-pane Tree fixture scans completely in stable canonical order\n'

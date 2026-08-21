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
[ "${1:-}" != --version ] || { printf '0.70.0\n'; exit 0; }
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

# --- window-first switcher contract -----------------------------------------
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

strip_ansi() {
  LC_ALL=C sed $'s/\033\\[[0-9;]*m//g'
}

assert_live_rows() { # assert_live_rows <label> <file>
  local label="$1" file="$2"
  [ -s "$file" ] || fail "$label emitted no rows"
  awk -F '\t' '
    NF != 3 { printf "row %d has %d fields: %s\n", NR, NF, $0 > "/dev/stderr"; bad=1 }
    $1 !~ /^%[0-9]+$/ { printf "row %d has non-pane-id target: %s\n", NR, $1 > "/dev/stderr"; bad=1 }
    END { exit bad }
  ' "$file" || fail "$label violated the three-field live-target row contract"
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

# Tree rests at session/window granularity. Session and window rows still carry
# a real active-pane target, so Enter never lands on a synthetic/no-op row.
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list tree 0 > "$TMP/tree.rows"
strip_ansi < "$TMP/tree.rows" > "$TMP/tree.plain"
assert_live_rows 'collapsed Tree' "$TMP/tree.plain"
awk -F '\t' '
  $2 ~ /^▾ (alpha|beta)$/ && $3 ~ /^[[:space:]]*[0-9]+w$/ { sessions++ }
  $2 ~ /^  [├└]─ [[:space:]][0-9]+ (zero|one)$/ { windows++ }
  $2 ~ /:[0-9]+\.[0-9]+/ { panes++ }
  END { exit !(NR == 5 && sessions == 2 && windows == 3 && panes == 0) }
' "$TMP/tree.plain" || fail 'Tree does not rest as a canonical 2-session/3-window hierarchy'
TREE_SESSION_TARGET="$(awk -F '\t' '$2 == "▾ beta" && $3 ~ /^[[:space:]]*1w$/ { print $1; exit }' "$TMP/tree.plain")"
[ -n "$TREE_SESSION_TARGET" ] || fail 'Tree omitted the switchable beta session row'
awk -F '\t' '
  $2 ~ /^  [├└]─ [[:space:]]0 zero$/ && $3 !~ /^2p · / { bad=1 }
  $2 ~ /^  [├└]─ [[:space:]]1 one$/ && $3 ~ /^1p · / { bad=1 }
  $3 ~ /window ·| pane(s)?([[:space:]]|$)/ { bad=1 }
  END { exit bad }
' "$TMP/tree.plain" || fail 'Tree kept redundant prose instead of compact runtime evidence'
if LC_ALL=C grep -q $'\r' "$TMP/tree.plain"; then
  fail 'Tree left a carriage return in user-derived display content'
fi

PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list tree 1 > "$TMP/tree-expanded.rows"
strip_ansi < "$TMP/tree-expanded.rows" > "$TMP/tree-expanded.plain"
assert_live_rows 'expanded Tree' "$TMP/tree-expanded.plain"
awk -F '\t' '
  $2 ~ /^▾ (alpha|beta)$/ && $3 ~ /^[[:space:]]*[0-9]+w$/ { sessions++ }
  $2 ~ /^  [├└]─ [[:space:]][0-9]+ (zero|one)$/ { windows++ }
  $2 ~ /^  ([│]   |    )[├└]─ [0-9]+ / { panes++ }
  END { exit !(NR == 10 && sessions == 2 && windows == 3 && panes == 5) }
' "$TMP/tree-expanded.plain" || fail 'Ctrl-e expansion model is not a canonical 2-session/3-window/5-pane hierarchy'

# `all` is accepted for old callers, but resolves to the Tree product surface.
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list all 0 > "$TMP/all-alias.rows"
strip_ansi < "$TMP/all-alias.rows" > "$TMP/all-alias.plain"
cmp -s "$TMP/tree.plain" "$TMP/all-alias.plain" || fail 'all compatibility alias does not resolve to Tree'
printf 'PASS: Tree rests at window level, expands exact panes, and every row is switchable\n'

# A tmux window may be linked into multiple sessions. Tree represents each
# session/window link once with that link's own coordinate; Recent represents
# the underlying window once and must not duplicate its pane leaves.
tmux -L "$SOCKET" link-window -s alpha:1 -t beta:1
LINKED_PANE="$(tmux -L "$SOCKET" display-message -p -t alpha:1.0 '#{pane_id}')"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list tree 0 > "$TMP/tree-linked.rows"
strip_ansi < "$TMP/tree-linked.rows" > "$TMP/tree-linked.plain"
assert_live_rows 'linked-window collapsed Tree' "$TMP/tree-linked.plain"
[ "$(awk -F '\t' '$2 ~ /^  [├└]─ [[:space:]]1 one$/ { n++ } END { print n+0 }' "$TMP/tree-linked.plain")" -eq 2 ] ||
  fail 'linked window was not represented once under each session in Tree'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list tree 1 > "$TMP/tree-linked-expanded.rows"
strip_ansi < "$TMP/tree-linked-expanded.rows" > "$TMP/tree-linked-expanded.plain"
[ "$(awk -F '\t' '$2 ~ /^  [├└]─ [[:space:]]1 one$/ { n++ } END { print n+0 }' "$TMP/tree-linked-expanded.plain")" -eq 2 ] ||
  fail 'linked Tree did not emit one window row under each session'
[ "$(awk -F '\t' -v p="$LINKED_PANE" '$1 == p && $2 ~ /^  ([│]   |    )[├└]─ 0 / { n++ } END { print n+0 }' "$TMP/tree-linked-expanded.plain")" -eq 2 ] ||
  fail 'linked Tree did not emit one pane leaf under each session link'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent 1 > "$TMP/recent-linked.rows"
strip_ansi < "$TMP/recent-linked.rows" > "$TMP/recent-linked.plain"
[ "$(wc -l < "$TMP/recent-linked.plain" | tr -d ' ')" -eq 8 ] ||
  fail 'Recent duplicated a linked window or its pane leaves'
[ "$(awk -F '\t' -v p="$LINKED_PANE" '$1 == p { n++ } END { print n+0 }' "$TMP/recent-linked.plain")" -eq 2 ] ||
  fail 'Recent did not keep one window row plus one pane leaf for a linked window'
printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$LINKED_PANE" "$(date +%s)" claude linked-window 'Claude is waiting for your input' one \
  > "$TMP/state/need-input"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list inbox > "$TMP/inbox-linked.rows"
strip_ansi < "$TMP/inbox-linked.rows" > "$TMP/inbox-linked.plain"
assert_live_rows 'linked-window Inbox' "$TMP/inbox-linked.plain"
[ "$(awk -F '\t' -v p="$LINKED_PANE" '$1 == p { n++ } END { print n+0 }' "$TMP/inbox-linked.plain")" -eq 1 ] ||
  fail 'Inbox duplicated one unread event through multiple session links'
: > "$TMP/state/need-input"
tmux -L "$SOCKET" unlink-window -t beta:1
printf 'PASS: linked windows preserve Tree links and stay deduplicated in Recent and Inbox\n'

# The rendered Tree shape must honor the same window-name-first search contract
# as Recent/Inbox, even when a session has the identical name.
tmux -L "$SOCKET" new-session -d -s priority-window -n neutral -x 120 -y 40
tmux -L "$SOCKET" rename-window -t alpha:1 priority-window
TMUX_RADAR_PICKER_ROWS=1 PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list tree 0 > "$TMP/tree-search-priority.rows"
tree_search_first="$(
  "$REAL_FZF" --ansi --filter='priority-window' --delimiter=$'\t' --with-nth=2.. --tiebreak=begin,index \
    < "$TMP/tree-search-priority.rows" | cut -f1 | head -1
)"
[ "$tree_search_first" = "$LINKED_PANE" ] ||
  fail 'Tree session metadata outranked an identical user window-name match'
tmux -L "$SOCKET" rename-window -t alpha:1 one
tmux -L "$SOCKET" kill-session -t priority-window
printf 'PASS: Tree search ranks an identical window-name match before session metadata\n'

# Recent contains every live window. Window MRU changes order but never changes
# membership; missing/dead/duplicate history falls back to canonical windows.
P_ALPHA_0="$(tmux -L "$SOCKET" display-message -p -t alpha:0.0 '#{pane_id}')"
P_ALPHA_1="$(tmux -L "$SOCKET" display-message -p -t alpha:0.1 '#{pane_id}')"
P_ALPHA_W1="$(tmux -L "$SOCKET" display-message -p -t alpha:1.0 '#{pane_id}')"
P_BETA_0="$(tmux -L "$SOCKET" display-message -p -t beta:0.0 '#{pane_id}')"
P_BETA_1="$(tmux -L "$SOCKET" display-message -p -t beta:0.1 '#{pane_id}')"
W_ALPHA_0="$(tmux -L "$SOCKET" display-message -p -t alpha:0 '#{window_id}')"
W_ALPHA_1="$(tmux -L "$SOCKET" display-message -p -t alpha:1 '#{window_id}')"
W_BETA_0="$(tmux -L "$SOCKET" display-message -p -t beta:0 '#{window_id}')"
cat > "$TMP/state/window-mru" <<EOF
$W_ALPHA_1	1
@999999	2
$W_BETA_0	3
$W_ALPHA_0	4
EOF
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent 0 > "$TMP/recent.rows"
strip_ansi < "$TMP/recent.rows" > "$TMP/recent.plain"
assert_live_rows 'Recent' "$TMP/recent.plain"
recent_targets="$(cut -f1 "$TMP/recent.plain" | paste -sd ' ' -)"
[ "$recent_targets" = "$P_ALPHA_0 $P_BETA_0 $P_ALPHA_W1" ] ||
  fail "Recent is not all windows in MRU-then-canonical order: $recent_targets"
[ "$(wc -l < "$TMP/recent.plain" | tr -d ' ')" -eq 3 ] || fail 'Recent is not one row per live window'

# Search identity starts with the user-assigned window name. Location, cwd,
# command, pane title, and AI metadata may follow but cannot outrank it.
tmux -L "$SOCKET" rename-window -t alpha:0 'user-search-name'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent 0 > "$TMP/recent-search.rows"
strip_ansi < "$TMP/recent-search.rows" > "$TMP/recent-search.plain"
awk -F '\t' -v pane="$P_ALPHA_0" '$1 == pane { exit !($2 ~ /^user-search-name([[:space:]\/]|$)/) } END { if (NR == 0) exit 1 }' \
  "$TMP/recent-search.plain" || fail 'window search text does not begin with the user-assigned name'

: > "$TMP/state/window-mru"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent 0 > "$TMP/recent-empty.rows"
[ "$(wc -l < "$TMP/recent-empty.rows" | tr -d ' ')" -eq 3 ] || fail 'empty window MRU hid live windows'
rm -f "$TMP/state/window-mru"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent 0 > "$TMP/recent-missing.rows"
[ "$(wc -l < "$TMP/recent-missing.rows" | tr -d ' ')" -eq 3 ] || fail 'missing window MRU hid live windows'
printf '%s\t1\n%s\t2\n' "$W_BETA_0" "$W_ALPHA_0" > "$TMP/state/window-mru"

PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list recent 1 > "$TMP/recent-expanded.rows"
strip_ansi < "$TMP/recent-expanded.rows" > "$TMP/recent-expanded.plain"
assert_live_rows 'expanded Recent' "$TMP/recent-expanded.plain"
[ "$(wc -l < "$TMP/recent-expanded.plain" | tr -d ' ')" -eq 8 ] || fail 'expanded Recent is not 3 windows plus 5 panes'
[ "$(awk -F '\t' '$2 ~ /:[0-9]+\.[0-9]+/ { n++ } END { print n+0 }' "$TMP/recent-expanded.plain")" -eq 5 ] ||
  fail 'expanded Recent did not reveal every pane'
printf 'PASS: Recent is window-first, complete, MRU-ordered, and pane-expandable\n'

# --- Inbox ordering, noise rejection, and empty state -----------------------
now="$(date +%s)"
sleep 300 & ATT_REG_PID=$!
cat > "$TMP/state/need-input" <<EOF
$P_BETA_1	$((now - 20))	test	new-action	needs approval
$P_ALPHA_1	$((now - 20))	test	other-action	needs input
$P_ALPHA_W1	$((now - 30))	test	done	turn complete
$P_BETA_0	$((now - 40))	test	notice	informational update
-	$((now - 5))	claude	background	needs input
malformed-state-row-without-tabs
%999999	$((now - 5))	test	dead-pane	needs input
EOF
# Registry/process evidence may enrich a marked row, but never creates an Inbox
# row by itself. The last two registry rows deliberately model long-lived
# working/done Claude shells with no unread lifecycle mark.
{
  printf 'codex\ta:action-1\t%s\t%s\t%s\t%s\twaiting\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_BETA_1" "$((now - 100))" "$((now - 1))"
  printf 'codex\ta:action-2\t%s\t%s\t%s\t%s\twaiting\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_ALPHA_1" "$((now - 100))" "$((now - 1))"
  printf 'codex\ta:done\t%s\t%s\t%s\t%s\tdone\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_ALPHA_W1" "$((now - 100))" "$((now - 1))"
  printf 'codex\ta:notice\t%s\t%s\t%s\t%s\tactive\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_BETA_0" "$((now - 100))" "$((now - 1))"
  printf 'claude\ta:unmarked-working\t%s\t%s\t%s\t%s\tworking\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_ALPHA_0" "$((now - 100))" "$((now - 1))"
  printf 'claude\ta:unmarked-done\t%s\t%s\t%s\t%s\tdone\t/tmp\tsleep\n' \
    "$ATT_REG_PID" "$P_ALPHA_0" "$((now - 100))" "$((now - 1))"
} > "$TMP/state/agent-registry"

PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list inbox > "$TMP/inbox.rows"
strip_ansi < "$TMP/inbox.rows" > "$TMP/inbox.plain"
assert_live_rows 'Inbox' "$TMP/inbox.plain"
inbox_targets="$(cut -f1 "$TMP/inbox.plain" | paste -sd ' ' -)"
[ "$inbox_targets" = "$P_ALPHA_1 $P_BETA_1 $P_ALPHA_W1 $P_BETA_0" ] ||
  fail "Inbox is not marked ACTION/DONE/NOTICE only: $inbox_targets"
if ! grep -q 'ACTION' "$TMP/inbox.plain" ||
   ! grep -q 'DONE' "$TMP/inbox.plain" ||
   ! grep -q 'NOTICE' "$TMP/inbox.plain"; then
  fail 'Inbox lost semantic ACTION/DONE/NOTICE labels'
fi
if grep -q 'ACTIVE\|__bg__\|background session\|not a tmux pane' "$TMP/inbox.plain"; then
  fail 'Inbox exposed an unmarked ACTIVE or paneless/background row'
fi
grep -q 'malformed-state-row\|dead-pane' "$TMP/inbox.plain" &&
  fail 'Inbox exposed malformed or dead-target mark input'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list needinput > "$TMP/needinput-alias.rows"
cut -f1 "$TMP/inbox.rows" > "$TMP/inbox.targets"
cut -f1 "$TMP/needinput-alias.rows" > "$TMP/needinput-alias.targets"
cmp -s "$TMP/inbox.targets" "$TMP/needinput-alias.targets" || fail 'legacy needinput alias does not resolve to Inbox'
printf 'PASS: Inbox contains unread pane events and rejects unmarked AI shells\n'

# Inbox mark fields are user-controlled. Strip CR/ESC/control bytes from
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
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list inbox > "$TMP/inbox-controls.rows"
grep -q $'\033\[' "$TMP/inbox-controls.rows" || fail 'Inbox sanitization removed renderer-owned ANSI'
strip_ansi < "$TMP/inbox-controls.rows" > "$TMP/inbox-controls.plain"
assert_live_rows 'Inbox control fixture' "$TMP/inbox-controls.plain"
if LC_ALL=C grep -q $'\r\|\033' "$TMP/inbox-controls.plain"; then
  fail 'Inbox leaked CR/ESC from mark source, label, or saved title'
fi
grep -q 'hook source' "$TMP/inbox-controls.plain" || fail 'Inbox lost sanitized source text'
grep -q 'your turn' "$TMP/inbox-controls.plain" || fail 'Inbox lost sanitized label text'
grep -q 'saved title' "$TMP/inbox-controls.plain" || fail 'Inbox lost sanitized saved-title text'
grep -q 'DONE' "$TMP/inbox-controls.plain" || fail 'Inbox classified sanitized completion label incorrectly'
[ "$(wc -l < "$TMP/inbox-controls.plain" | tr -d ' ')" -eq 1 ] || fail 'unmarked registry metadata created an Inbox row'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" preview "$P_ALPHA_1" > "$TMP/preview-controls.out"
strip_ansi < "$TMP/preview-controls.out" > "$TMP/preview-controls.plain"
if LC_ALL=C grep -q $'\r\|\033' "$TMP/preview-controls.plain"; then
  fail 'preview leaked CR/ESC from Inbox metadata'
fi
grep -q '^✓' "$TMP/preview-controls.plain" || fail 'preview semantics diverged from sanitized Inbox completion label'
grep -q 'sid mark key' "$TMP/preview-controls.plain" || fail 'preview lost the sanitized mark session key'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" preview "$P_ALPHA_0" > "$TMP/preview-registry-controls.out"
strip_ansi < "$TMP/preview-registry-controls.out" > "$TMP/preview-registry-controls.plain"
if LC_ALL=C grep -q $'\r\|\033' "$TMP/preview-registry-controls.plain"; then
  fail 'preview leaked CR/ESC from the registry session key'
fi
grep -q 'sid reg key ' "$TMP/preview-registry-controls.plain" || fail 'preview lost the sanitized registry session key'
printf 'PASS: Inbox and preview sanitize control bytes without promoting registry-only rows\n'

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
# DONE remains reviewable after the agent process/registry row exits; the unread
# pane-backed mark and live pane are sufficient until focus handles it.
: > "$TMP/state/agent-registry"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list inbox > "$TMP/public-mark.rows"
strip_ansi < "$TMP/public-mark.rows" > "$TMP/public-mark.plain"
assert_live_rows 'public mark Inbox fixture' "$TMP/public-mark.plain"
grep -q 'DONE' "$TMP/public-mark.plain" || fail 'public mark API normalization changed Inbox semantics'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" preview "$P_ALPHA_1" > "$TMP/public-mark-preview.out"
strip_ansi < "$TMP/public-mark-preview.out" > "$TMP/public-mark-preview.plain"
if { cat "$TMP/public-mark.plain" "$TMP/public-mark-preview.plain" | LC_ALL=C tr -d '\t\n' | LC_ALL=C grep -q '[[:cntrl:]]'; }; then
  fail 'public mark API leaked unsafe controls into Inbox or preview'
fi
grep -q 'sid mark key' "$TMP/public-mark-preview.plain" || fail 'preview lost the normalized public mark session key'
printf 'PASS: public DONE marks survive agent exit with safe six-field metadata\n'

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
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list inbox > "$TMP/inbox-ties.rows"
tie_targets="$(cut -f1 "$TMP/inbox-ties.rows" | paste -sd ' ' -)"
[ "$tie_targets" = "$P_AARDVARK_0 $P_BETA_1" ] ||
  fail "equal-epoch Inbox ties did not preserve canonical server order: $tie_targets"
tmux -L "$SOCKET" kill-session -t aardvark
printf 'PASS: equal-epoch Inbox ties preserve canonical server order\n'

# A real Kimi process and a live working registry row are still not unread
# events. Process detection belongs to GC/doctor, not to Inbox membership.
ln -sf /bin/sleep "$FAKE_BIN/kimi"
tmux -L "$SOCKET" respawn-pane -k -t beta:0.0 "$FAKE_BIN/kimi 120"
: > "$TMP/state/need-input"
printf 'kimi\ts:kimi-working\t0\t%s\t%s\t%s\tworking\t/tmp\tkimi\n' \
  "$P_BETA_0" "$((now - 100))" "$((now - 1))" > "$TMP/state/agent-registry"
sleep 0.1
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list inbox > "$TMP/kimi.rows"
strip_ansi < "$TMP/kimi.rows" > "$TMP/kimi.plain"
[ ! -s "$TMP/kimi.plain" ] || fail 'process-only Kimi session polluted Inbox'
printf 'PASS: live unmarked AI processes remain outside Inbox\n'

# Empty Inbox has no synthetic row and explains unread-event semantics.
: > "$TMP/state/need-input"
: > "$TMP/state/agent-registry"
tmux -L "$SOCKET" respawn-pane -k -t beta:0.0 'sleep 120'
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list inbox > "$TMP/empty-inbox.rows"
[ ! -s "$TMP/empty-inbox.rows" ] || fail 'empty Inbox emitted a selectable or synthetic row'

cat > "$FAKE_BIN/fzf" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { printf '0.70.0\n'; exit 0; }
printf '%s\n' "$@" > "$TMUX_RADAR_FZF_ARGS"
cat > "$TMUX_RADAR_FZF_INPUT"
SH
chmod +x "$FAKE_BIN/fzf"
export TMUX_RADAR_FZF_ARGS="$TMP/fzf.args"
export TMUX_RADAR_FZF_INPUT="$TMP/fzf.input"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu inbox >/dev/null 2>"$TMP/menu-inbox.err" ||
  fail 'menu inbox failed while rendering its empty state'
grep -q 'Inbox>' "$TMP/fzf.args" || fail 'menu inbox did not open with the Inbox prompt'
grep -Eqi 'Inbox clear|no unread AI event' "$TMP/fzf.args" || fail 'empty Inbox omitted its unread-event explanation'
[ ! -s "$TMP/fzf.input" ] || fail 'empty Inbox passed a synthetic row to fzf'
printf 'PASS: menu Inbox opens directly with a truthful nonselectable empty state\n'

mkdir -p "$TMP/old-fzf-bin"
cat > "$TMP/old-fzf-bin/fzf" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '0.58.0\n'; exit 0; fi
: > "$TMUX_RADAR_OLD_FZF_OPENED"
SH
chmod +x "$TMP/old-fzf-bin/fzf"
export TMUX_RADAR_OLD_FZF_OPENED="$TMP/old-fzf-opened"
set +e
PATH="$TMP/old-fzf-bin:$PATH" bash "$SWITCHER" menu recent >"$TMP/old-fzf.out" 2>"$TMP/old-fzf.err"
old_fzf_rc=$?
set -e
[ "$old_fzf_rc" -ne 0 ] || fail 'unsupported fzf version opened the picker'
[ ! -e "$TMUX_RADAR_OLD_FZF_OPENED" ] || fail 'unsupported fzf version reached interactive mode'
grep -q 'fzf 0.59 or newer is required' "$TMP/old-fzf.err" ||
  fail 'unsupported fzf version omitted the upgrade diagnostic'

mkdir -p "$TMP/min-fzf-bin"
cat > "$TMP/min-fzf-bin/fzf" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf '0.59.0\n'; exit 0; fi
: > "$TMUX_RADAR_MIN_FZF_OPENED"
cat >/dev/null
SH
chmod +x "$TMP/min-fzf-bin/fzf"
export TMUX_RADAR_MIN_FZF_OPENED="$TMP/min-fzf-opened"
PATH="$TMP/min-fzf-bin:$PATH" bash "$SWITCHER" menu recent >/dev/null 2>"$TMP/min-fzf.err" ||
  fail 'minimum supported fzf version failed to open the picker'
[ -e "$TMUX_RADAR_MIN_FZF_OPENED" ] || fail 'fzf 0.59 did not reach interactive mode'
printf 'PASS: unsupported fzf versions fail before interactive mode\n'

# Capture the actual initial Recent invocation separately from the empty Inbox
# invocation above: the fast-switch view has a deliberate row-2 focus policy.
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu recent >/dev/null 2>"$TMP/menu-recent.err" ||
  fail 'menu recent failed while capturing its initial selection policy'
grep -Eq -- '--tiebreak(=|$).*begin,index|--tiebreak=begin,index' "$TMP/fzf.args" ||
  fail 'fzf does not tie-break relevance by beginning position then input order'
! grep -qx -- '--nth=2..' "$TMP/fzf.args" ||
  fail 'fzf excludes the window-name search field after applying with-nth'
grep -q 'C-t Tree' "$TMP/fzf.args" || fail 'picker header does not advertise C-t Tree'
grep -q 'C-i Inbox' "$TMP/fzf.args" || fail 'picker header does not advertise C-i Inbox'
grep -q 'C-e panes' "$TMP/fzf.args" || fail 'picker header does not advertise C-e pane drill-down'
grep -q 'A-1..9' "$TMP/fzf.args" || fail 'picker header does not advertise direct row jumps'
grep -Eq 'ctrl-t:transform\([^)]*set-view tree\)' "$TMP/fzf.args" ||
  fail 'C-t does not switch to the Tree view'
grep -qx -- '--sync' "$TMP/fzf.args" ||
  fail 'initial Recent selection can race before fzf has loaded row 2'
grep -Eq 'start:pos\(2\)' "$TMP/fzf.args" ||
  fail 'initial Recent view does not select the previous window on row 2'
grep -Eq 'ctrl-e:transform\([^)]*toggle-expand' "$TMP/fzf.args" ||
  fail 'C-e does not toggle pane drill-down'
grep -Eq 'alt-1:transform\([^)]*jump 1\)' "$TMP/fzf.args" || fail 'Alt-1 safe row jump is not bound'
grep -Eq 'alt-9:transform\([^)]*jump 9\)' "$TMP/fzf.args" || fail 'Alt-9 safe row jump is not bound'
in_range_jump="$(FZF_MATCH_COUNT=2 bash "$SWITCHER" jump 2)"
[ "$in_range_jump" = 'pos(2)+accept' ] || fail "in-range Alt-N action is unsafe: $in_range_jump"
out_of_range_jump="$(FZF_MATCH_COUNT=2 bash "$SWITCHER" jump 9)"
[ "$out_of_range_jump" = 'bell' ] || fail "out-of-range Alt-N action accepted or moved: $out_of_range_jump"
printf 'tree\t0\n' > "$TMP/recent-focus.state"
: > "$TMP/recent-focus.rows"
rm -f "$TMP/recent-focus.error"
recent_focus_action="$(
  SW_STATE="$TMP/recent-focus.state" SW_ROWS="$TMP/recent-focus.rows" SW_ERROR="$TMP/recent-focus.error" \
    PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" set-view recent
)"
case "$recent_focus_action" in *'+pos(2)') ;; *)
  fail "C-r reload does not select the previous window on row 2: $recent_focus_action" ;;
esac
search_order="$(
  printf '%%1\tpriority-window alpha:0.0/title\t/tmp · zsh\n%%2\tother-window alpha:0.1/title\t/tmp/priority-window · zsh\n' |
    "$REAL_FZF" --filter='priority-window' --delimiter=$'\t' --with-nth=2.. --tiebreak=begin,index |
    cut -f1 | paste -sd ' ' -
)"
[ "$search_order" = '%1 %2' ] || fail "window-name match did not outrank metadata-only match: $search_order"
printf 'PASS: picker exposes the restored controls and ranks window names first\n'

# Exercise the real fzf transform protocol through a real tmux key event. fzf
# ignores unterminated output and rejects a transform containing an unknown
# action even when the state/row producer itself ran successfully.
REAL_FZF_BIN="$TMP/real-fzf-bin"
mkdir -p "$REAL_FZF_BIN" "$TMP/keyboard-state"
ln -sf "$REAL_FZF" "$REAL_FZF_BIN/fzf"
cat > "$REAL_FZF_BIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = switch-client ] && [ -n "${TMUX_RADAR_TEST_SWITCH_TARGET:-}" ]; then
  printf '%s\n' "${3:-}" > "$TMUX_RADAR_TEST_SWITCH_TARGET"
  exit 0
fi
exec "$REAL_TMUX" "$@"
SH
chmod +x "$REAL_FZF_BIN/tmux"
tmux -L "$SOCKET" select-pane -t "$P_ALPHA_1" -T 'keyboard-pane-leaf'
tmux -L "$SOCKET" new-window -d -t alpha: -n ct-keyboard
KEYBOARD_TARGET='alpha:ct-keyboard.0'
KEYBOARD_PATH="$REAL_FZF_BIN:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
KEYBOARD_WINDOW_ID="$(tmux -L "$SOCKET" display-message -p -t "$KEYBOARD_TARGET" '#{window_id}')"
tmux -L "$SOCKET" list-windows -a -F '#{window_id}' |
  awk -v previous="$W_ALPHA_1" -v current="$KEYBOARD_WINDOW_ID" '
    $0 != previous && $0 != current && !seen[$0]++ { print }
    END { print previous; print current }
  ' > "$TMP/keyboard-state/window-mru"
keyboard_expected_second="$(
  PATH="$KEYBOARD_PATH" TMUX_RADAR_STATE_DIR="$TMP/keyboard-state" bash "$SWITCHER" list recent 0 |
    awk -F '\t' 'NR == 2 { print $1 }'
)"
[ "$keyboard_expected_second" = "$P_ALPHA_W1" ] ||
  fail "Recent fixture did not place the previous window on row 2: $keyboard_expected_second"
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" -l -- \
  "PATH='$KEYBOARD_PATH' TMUX_RADAR_STATE_DIR='$TMP/keyboard-state' TMUX_RADAR_TEST_SWITCH_TARGET='$TMP/keyboard-switch-target' bash '$SWITCHER' menu"
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" Enter
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-before"
  grep -q '^Recent>' "$TMP/keyboard-before" && break
  sleep 0.1
done
grep -q '^Recent>' "$TMP/keyboard-before" || fail 'real picker did not reach its initial Recent prompt'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" Enter
for _ in $(seq 1 50); do
  [ -s "$TMP/keyboard-switch-target" ] && break
  sleep 0.1
done
[ "$(cat "$TMP/keyboard-switch-target" 2>/dev/null || true)" = "$P_ALPHA_W1" ] ||
  fail 'opening Recent and pressing Enter did not switch to the previous window on row 2'

# Open a second real picker to exercise the remaining view transforms.
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" -l -- \
  "PATH='$KEYBOARD_PATH' TMUX_RADAR_STATE_DIR='$TMP/keyboard-state' bash '$SWITCHER' menu"
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" Enter
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-before-views"
  grep -q '^Recent>' "$TMP/keyboard-before-views" && break
  sleep 0.1
done
grep -q '^Recent>' "$TMP/keyboard-before-views" || fail 'real picker did not reopen after Recent quick-switch proof'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-t
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-after"
  grep -q '^Tree>' "$TMP/keyboard-after" && break
  sleep 0.1
done
grep -q '^Tree>' "$TMP/keyboard-after" || fail 'real Ctrl-t key event did not change the picker to Tree'
grep -q 'keyboard-pane-leaf' "$TMP/keyboard-after" && fail 'collapsed Tree exposed pane rows before Ctrl-e'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-e
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-expanded"
  grep -q '^Tree+>' "$TMP/keyboard-expanded" && grep -q 'keyboard-pane-leaf' "$TMP/keyboard-expanded" && break
  sleep 0.1
done
grep -q '^Tree+>' "$TMP/keyboard-expanded" || fail 'real Ctrl-e key event did not enter expanded Tree state'
grep -q 'keyboard-pane-leaf' "$TMP/keyboard-expanded" || fail 'real Ctrl-e key event did not reveal pane rows'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-i
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-inbox"
  grep -q '^Inbox>' "$TMP/keyboard-inbox" && break
  sleep 0.1
done
grep -q '^Inbox>' "$TMP/keyboard-inbox" || fail 'real Ctrl-i key event did not change the picker to Inbox'
grep -q 'Inbox clear.*no unread AI event' "$TMP/keyboard-inbox" ||
  fail 'switching into an empty Inbox did not publish its truthful empty state'
# Inbox is already pane-level. Ctrl-e is a no-op here and must not mutate the
# remembered Tree expansion state behind the current view.
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-e
sleep 0.2
tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-inbox-after-expand"
grep -q '^Inbox>' "$TMP/keyboard-inbox-after-expand" || fail 'Ctrl-e escaped or reloaded the pane-level Inbox'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-t
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-tree-restored"
  grep -q '^Tree+>' "$TMP/keyboard-tree-restored" && break
  sleep 0.1
done
grep -q '^Tree+>' "$TMP/keyboard-tree-restored" || fail 'Ctrl-e inside Inbox mutated the remembered Tree expansion'
grep -q 'Inbox clear.*no unread AI event' "$TMP/keyboard-tree-restored" &&
  fail 'leaving Inbox retained a stale empty-state header'
# Agents is pane-level too: the view key transforms, the empty state is
# truthful, and Ctrl-e is a structural no-op.
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-a
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-agents"
  grep -q '^Agents>' "$TMP/keyboard-agents" && break
  sleep 0.1
done
grep -q '^Agents>' "$TMP/keyboard-agents" || fail 'real Ctrl-a key event did not change the picker to Agents'
grep -q 'Agents clear' "$TMP/keyboard-agents" || fail 'empty Agents view did not publish its truthful empty state'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-e
sleep 0.2
tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-agents-expand"
grep -q '^Agents>' "$TMP/keyboard-agents-expand" || fail 'Ctrl-e escaped or reloaded the pane-level Agents view'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-t
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-tree-after-agents"
  grep -q '^Tree+>' "$TMP/keyboard-tree-after-agents" && break
  sleep 0.1
done
grep -q '^Tree+>' "$TMP/keyboard-tree-after-agents" || fail 'leaving Agents did not restore the expanded Tree'
# Collapse back to the six structural results. fzf must not clamp Alt-9 to the
# last visible row and accept it.
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-e
for _ in $(seq 1 50); do
  tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-tree-collapsed"
  grep -q '^Tree>' "$TMP/keyboard-tree-collapsed" && break
  sleep 0.1
done
grep -q '^Tree>' "$TMP/keyboard-tree-collapsed" || fail 'real Ctrl-e did not collapse Tree before numeric jump'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" M-9
sleep 0.2
tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-alt9"
grep -q '^Tree>' "$TMP/keyboard-alt9" || fail 'out-of-range Alt-9 exited the real picker'
# Filtering to one result must keep the same safe behavior.
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" -l -- 'ct-keyboard'
sleep 0.2
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" M-9
sleep 0.2
tmux -L "$SOCKET" capture-pane -p -t "$KEYBOARD_TARGET" > "$TMP/keyboard-alt9-filtered"
grep -q '^Tree>' "$TMP/keyboard-alt9-filtered" || fail 'filtered out-of-range Alt-9 exited the real picker'
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" C-u
tmux -L "$SOCKET" send-keys -t "$KEYBOARD_TARGET" Escape
tmux -L "$SOCKET" kill-window -t alpha:ct-keyboard
printf 'PASS: Recent opens on row 2; real view keys, Inbox no-op, and safe Alt-N work\n'

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
[ "${1:-}" != --version ] || { printf '0.70.0\n'; exit 0; }
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
[ "${1:-}" != --version ] || { printf '0.70.0\n'; exit 0; }
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
if [ "${TMUX_RADAR_TEST_COUNT_LIST_CALLS:-0}" = 1 ]; then
  case "${1:-}" in
    list-panes|list-windows) printf '%s\n' "$*" >> "$TMUX_RADAR_TEST_LIST_CALLS" ;;
  esac
fi
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
[ "${1:-}" != --version ] || { printf '0.70.0\n'; exit 0; }
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
if [ "${TMUX_RADAR_TEST_CHANGE_ACTIVE_BEFORE_SELECT:-0}" = 1 ]; then
  "$REAL_TMUX" select-pane -t "$TMUX_RADAR_TEST_CHANGE_ACTIVE_TARGET" >/dev/null 2>&1 || exit 44
fi
printf '%s\n' "$row"
SH
chmod +x "$FAKE_BIN/fzf"

# List generation is distinct from fzf. Producer failures are nonzero and
# sanitized, and fzf is never invoked on a failed initial list.
export TMUX_RADAR_TEST_FZF_MARKER="$TMP/fzf-invoked"
export TMUX_RADAR_TEST_FAIL_LIST=1
for view in tree all recent inbox attention; do
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
[ "${1:-}" != --version ] || { printf '0.70.0\n'; exit 0; }
cat >/dev/null
action="$(bash "$TMUX_RADAR_TEST_SWITCHER" set-view inbox)"
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
[ "${1:-}" != --version ] || { printf '0.70.0\n'; exit 0; }
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
if [ "${TMUX_RADAR_TEST_CHANGE_ACTIVE_BEFORE_SELECT:-0}" = 1 ]; then
  "$REAL_TMUX" select-pane -t "$TMUX_RADAR_TEST_CHANGE_ACTIVE_TARGET" >/dev/null 2>&1 || exit 44
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

# Session rows provide hierarchy and remain useful destinations: selecting one
# switches atomically to its active pane and records that exact pane in MRU.
export TMUX_RADAR_TEST_SELECT="$TREE_SESSION_TARGET"
: > "$TMUX_RADAR_TEST_TMUX_LOG"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu tree >"$TMP/tree-struct.out" 2>"$TMP/tree-struct.err" ||
  fail 'selecting a Tree session row returned failure'
[ "$(cat "$TMUX_RADAR_TEST_TMUX_LOG")" = "switch-client -t $TREE_SESSION_TARGET" ] ||
  fail 'Tree session row was not one exact pane switch'
[ "$(tail -1 "$TMP/state/pane-mru" | cut -f1)" = "$TREE_SESSION_TARGET" ] ||
  fail 'Tree session row did not record its exact active pane'
printf 'PASS: Tree session rows are hierarchy plus real pane destinations\n'

# Window/session rows are pane snapshots, not late-bound coordinates. Change
# the active pane after fzf receives the rendered row; the accepted target must
# remain the original stable pane ID carried by that row.
tmux -L "$SOCKET" select-pane -t "$P_ALPHA_0"
WINDOW_SNAPSHOT_TARGET="$P_ALPHA_0"
export TMUX_RADAR_TEST_SELECT="$WINDOW_SNAPSHOT_TARGET"
export TMUX_RADAR_TEST_CHANGE_ACTIVE_BEFORE_SELECT=1
export TMUX_RADAR_TEST_CHANGE_ACTIVE_TARGET="$P_ALPHA_1"
: > "$TMUX_RADAR_TEST_TMUX_LOG"
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" menu tree >"$TMP/window-snapshot.out" 2>"$TMP/window-snapshot.err" ||
  fail 'render-time window target failed after its active pane changed'
[ "$(cat "$TMUX_RADAR_TEST_TMUX_LOG")" = "switch-client -t $WINDOW_SNAPSHOT_TARGET" ] ||
  fail 'window row redirected to a later active pane instead of its rendered target'
unset TMUX_RADAR_TEST_CHANGE_ACTIVE_BEFORE_SELECT TMUX_RADAR_TEST_CHANGE_ACTIVE_TARGET
printf 'PASS: window rows keep their render-time stable pane target\n'

export TMUX_RADAR_TEST_SELECT="$P_ALPHA_1"
unset TMUX_RADAR_TEST_CLOSE_BEFORE_SELECT TMUX_RADAR_TEST_FAIL_SWITCH
tmux -L "$SOCKET" set-option -g @radar-expand-panes on
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
tmux -L "$SOCKET" new-session -d -s scale -n w0 -x 240 -y 80
for win in $(seq 0 9); do
  if [ "$win" -gt 0 ]; then tmux -L "$SOCKET" new-window -d -t "scale:$win" -n "w$win"; fi
  # Give each added pane a fixed one-column slice so repeated splits do not
  # exhaust tmux's minimum size before reaching the 100-pane scale fixture.
  for _ in $(seq 1 9); do tmux -L "$SOCKET" split-window -d -h -l 1 -t "scale:$win"; done
done
: > "$TMP/tmux-list-calls"
export TMUX_RADAR_TEST_LIST_CALLS="$TMP/tmux-list-calls"
export TMUX_RADAR_TEST_COUNT_LIST_CALLS=1
PATH="$FAKE_BIN:$PATH" bash "$SWITCHER" list all 1 > "$TMP/large.rows"
unset TMUX_RADAR_TEST_COUNT_LIST_CALLS
strip_ansi < "$TMP/large.rows" > "$TMP/large.plain"
assert_live_rows 'large expanded Tree' "$TMP/large.plain"
scale_count="$(awk -F '\t' '
  $2 == "▾ scale" { in_scale=1; next }
  in_scale && $2 ~ /^▾ / { in_scale=0 }
  in_scale && $2 ~ /^  ([│]   |    )[├└]─ [0-9]+ / { n++ }
  END { print n+0 }
' "$TMP/large.plain")"
[ "$scale_count" -eq 100 ] || fail "large Tree scan lost or duplicated panes (got $scale_count, want 100)"
scale_targets="$(awk -F '\t' '
  $2 == "▾ scale" { in_scale=1; next }
  in_scale && $2 ~ /^▾ / { in_scale=0 }
  in_scale && $2 ~ /^  [├└]─ / {
    line=$2; sub(/^.*[├└]─ /, "", line); split(line, part, " "); win=part[1]; next
  }
  in_scale && $2 ~ /^  ([│]   |    )[├└]─ [0-9]+ / {
    line=$2; sub(/^.*[├└]─ /, "", line); split(line, part, " ")
    print "scale:" win "." part[1]
  }
' "$TMP/large.plain")"
expected_targets="$(for win in $(seq 0 9); do for pane in $(seq 0 9); do printf 'scale:%s.%s\n' "$win" "$pane"; done; done)"
[ "$scale_targets" = "$expected_targets" ] || fail 'large Tree pane ordering is not canonical session/window/pane order'
pane_calls="$(grep -c '^list-panes ' "$TMP/tmux-list-calls" 2>/dev/null || true)"
window_calls="$(grep -c '^list-windows ' "$TMP/tmux-list-calls" 2>/dev/null || true)"
[ "$pane_calls" -le 1 ] && [ "$window_calls" -le 1 ] ||
  fail "100-pane render used N+1 tmux calls (panes=$pane_calls windows=$window_calls)"
printf 'PASS: 100-pane Tree is complete, canonical, and bulk-snapshotted\n'

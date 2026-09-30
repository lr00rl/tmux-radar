#!/usr/bin/env bash
# A write that adds a mark announces it once: a toast on each attached client
# that is not on the marked pane, and @radar-notify-command with the mark in
# RADAR_* variables. The client is real: a second isolated server runs
# `tmux attach` in a pane, so capturing that pane shows exactly what the
# person would see, status line included. Never touches the live server.
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
N="$WT/scripts/needinput-notify.sh"
T="$(mktemp -d /tmp/radar-announce.XXXXXX)"
export TMUX_RADAR_STATE_DIR="$T/state" TMUX_RADAR_NO_SCHEDULE=1
INNER="radarann$$"
OUTER="radarannview$$"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi; }

cleanup() {
  tmux -L "$OUTER" kill-server 2>/dev/null || true
  tmux -L "$INNER" kill-server 2>/dev/null || true
  rm -rf "$T" 2>/dev/null || true
}
trap cleanup EXIT

unset TMUX_PANE CLAUDE_JOB_DIR CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_ENTRYPOINT \
  CLAUDE_CODE_SESSION_KIND CLAUDE_CODE_SESSION_ID 2>/dev/null || true
mkdir -p "$TMUX_RADAR_STATE_DIR"

tmux -L "$INNER" -f /dev/null new-session -d -s work -n billing-api -x 120 -y 20 'bash --norc'
tmux -L "$INNER" new-window -t work -n notes 'bash --norc'
tmux -L "$INNER" select-window -t work:notes
tmux -L "$OUTER" -f /dev/null new-session -d -s view -x 120 -y 20 "env -u TMUX tmux -L $INNER attach -t work; exec bash --norc"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -n "$(tmux -L "$INNER" list-clients -F '#{client_name}' 2>/dev/null)" ] && break
  sleep 0.3
done
SOCK="$(tmux -L "$INNER" display-message -p '#{socket_path}')"
export TMUX="$SOCK,99999,0"
BILL="$(tmux display-message -p -t work:billing-api '#{pane_id}')"
NOTES="$(tmux display-message -p -t work:notes '#{pane_id}')"
tmux set -g @radar-notify-command "env | grep '^RADAR_' | sort > '$T/notified.'\"\$RADAR_KEY\""

screen() { tmux -L "$OUTER" capture-pane -p -t view | tail -1 | sed 's/ *$//'; }
# The tmux server announces after the write returns (run-shell -b). A mark's
# claim under .announced/ appears the moment its announcement starts.
settle() {  # settle <key>: wait until the mark was announced, or 6 s
  local _ id="${1//[^A-Za-z0-9._-]/_}"
  for _ in $(seq 1 30); do
    set -- "$TMUX_RADAR_STATE_DIR"/.announced/*_"$id"_*
    [ -d "$1" ] && break
    sleep 0.2
  done
  sleep 0.3
}
notified() {  # notified <key> <var>: the value the notify command saw, waiting for run-shell -b
  local _
  for _ in $(seq 1 30); do
    [ -s "$T/notified.$1" ] && break
    sleep 0.2
  done
  sed -n "s/^$2=//p" "$T/notified.$1" 2>/dev/null
}
dismiss() { tmux -L "$OUTER" send-keys -t view x C-u; sleep 0.3; }   # a typed key clears it at once

chk "the viewer client is attached and on the notes pane" \
  "[ \"\$(tmux list-clients -F '#{pane_id}')\" = '$NOTES' ]"

# --- the floating toast, drawn in the top-right corner (the default) ------------------
# The notify command is not under test here: leave it out so its runs cannot
# overlap the screen checks.
tmux set -gu @radar-notify-command
tmux set -g @radar-toast-duration 1500
rows() { tmux -L "$OUTER" capture-pane -p -t view | sed -n "$1,$2p"; }
ends() {  # ends <first> <last>: the display column where each line ends
  rows "$1" "$2" | perl -CS -ne 'chomp; s/\s+$//; my $w = 0; $w += /\p{EA=W}|\p{EA=F}/ ? 2 : 1 for split //; print "$w\n"'
}
shown() {  # shown <text>...: every text is on the screen within 4 s
  local _ t missing
  for _ in $(seq 1 20); do
    missing=0
    for t in "$@"; do tmux -L "$OUTER" capture-pane -p -t view | grep -qF "$t" || missing=1; done
    [ "$missing" = 0 ] && return 0
    sleep 0.2
  done
  return 1
}
gone() {  # gone <text>: the text left the screen within 4 s
  local _
  for _ in $(seq 1 20); do
    tmux -L "$OUTER" capture-pane -p -t view | grep -qF "$1" || return 0
    sleep 0.2
  done
  return 1
}
idle() {  # idle: every floating toast has ended (their slots are free), within 4 s
  local _
  for _ in $(seq 1 40); do
    set -- "$TMUX_RADAR_STATE_DIR"/.toast-slots/*/*
    [ -e "$1" ] || return 0
    sleep 0.1
  done
  return 1
}
"$N" mark "$BILL" claude 'Claude finished: Added the retry and its test.' s:f1
shown 'Added the retry and its test.'
chk "a floating toast appears in the top-right corner" \
  "rows 2 2 | grep -qF '╭─ ✓ billing-api ─' && rows 3 3 | grep -qF '│ Claude finished: Added the retry and its test. │' && rows 4 4 | grep -qF '╰─'"
chk "its three lines end on one column, two short of the right edge" \
  "[ \"\$(ends 2 4 | sort -u)\" = 118 ]"
chk "the status line is left alone" "! screen | grep -q 'Added the retry'"
chk "it leaves after its duration" "gone 'Added the retry'"

tmux set -g @radar-toast-duration 8000
"$N" mark "$BILL" claude 'Claude needs approval: Bash' s:f2
shown 'needs approval: Bash'
tmux -L "$OUTER" send-keys -t view -l 'echo typed-under-toast'
tmux -L "$OUTER" send-keys -t view Enter
sleep 0.8
chk "typing reaches the pane while the toast is up, and the pane draws it" \
  "[ \"\$(tmux capture-pane -p -t '$NOTES' | grep -c typed-under-toast)\" = 2 ] && tmux -L \"\$OUTER\" capture-pane -p -t view | grep -q '^typed-under-toast' && rows 3 3 | grep -qF 'needs approval: Bash'"
"$N" clear "$BILL"
sleep 0.5
chk "clearing its mark (going to the pane) takes the toast away within half a second" \
  "! rows 2 4 | grep -qF 'needs approval: Bash'"
idle

"$N" mark "$BILL" claude 'Claude finished: first of two' s:f3
"$N" mark - claude 'Claude·lattice: needs approval: 重构完成，所有测试通过，准备提交' s:f4
shown 'first of two' '⚠ lattice'
# two announce jobs race for the first slot, so either may take the top
chk "two toasts stack, one below the other" \
  "{ rows 2 4 | grep -qF 'first of two' && rows 5 7 | grep -qF '⚠ lattice'; } || { rows 2 4 | grep -qF '⚠ lattice' && rows 5 7 | grep -qF 'first of two'; }"
chk "a toast with Chinese text keeps its right edge straight" \
  "[ \"\$(ends 2 4 | sort -u | wc -l | tr -d ' ')\" = 1 ] && [ \"\$(ends 5 7 | sort -u | wc -l | tr -d ' ')\" = 1 ]"
"$N" clear-all
idle

tmux rename-window -t work:billing-api "evil$(printf '\033]0;pwned-title\007')name"
tmux -L "$OUTER" select-pane -t view -T 'viewer-title'
"$N" mark "$BILL" claude 'Claude finished: escape check' s:f6
shown 'escape check'
chk "an escape sequence in a window name reaches the terminal as text" \
  "rows 2 2 | grep -qF 'evil' && [ \"\$(tmux -L \"\$OUTER\" display-message -p -t view '#{pane_title}')\" = viewer-title ]"
tmux rename-window -t work:0 billing-api
"$N" clear-all
idle
# tmux prints a raw ESC in a name as the text \033; hand the renderer one itself
"$WT/scripts/radar-float.sh" "$(tmux list-clients -F '#{client_name}')" "$(tmux list-clients -F '#{client_tty}')" \
  "$(tmux list-clients -F '#{client_pid}')" 120 1 19 1 'done' "raw$(printf '\033]0;pwned-title\007')where" "raw$(printf '\342\033]2;pwned-title\007\233')label" \
  1500 '' /dev/null "$T/slots" &
sleep 0.6
chk "the renderer turns raw escape sequences into plain text" \
  "rows 2 2 | grep -qF 'raw ]0;pwned-title where' && rows 3 3 | grep -qF 'raw ]2;pwned-title' && [ \"\$(tmux -L \"\$OUTER\" display-message -p -t view '#{pane_title}')\" = viewer-title ]"
chk "a stray UTF-8 lead byte before an escape leaves the box whole" "rows 4 4 | grep -qF '╰─'"
wait

"$N" mark "$BILL" claude 'Claude finished: signal check' s:f7
shown 'signal check'
pkill -TERM -f 'radar-float.sh.*signal check'
chk "a toast that is killed is erased and frees its slot" "gone 'signal check' && idle"
"$N" clear-all

for k in 1 2 3 4 5 6 7; do "$N" mark - tool "Test·fill$k: finished: fill-$k" "s:fill$k"; done
full=0
for _ in $(seq 1 30); do
  if [ "$(tmux -L "$OUTER" capture-pane -p -t view | grep -c '╭─ ✓ fill')" = 6 ] && screen | grep -q 'fill-'; then full=1; break; fi
  sleep 0.2
done
chk "six toasts fill the corner and a seventh goes to the status line" "[ $full = 1 ]"
"$N" clear-all
idle
dismiss

"$N" mark "$NOTES" claude 'Claude needs approval: on this pane' s:f5
settle s:f5
chk "no floating toast on the client that is on the pane" "! tmux -L \"\$OUTER\" capture-pane -p -t view | grep -qF 'on this pane'"
"$N" clear-all
tmux set -gu @radar-toast-duration
tmux set -g @radar-notify-command "env | grep '^RADAR_' | sort > '$T/notified.'\"\$RADAR_KEY\""

# The status-line toast, for the rest of this suite.
tmux set -g @radar-toast status

# --- a mark on a pane the person is not looking at ---------------------------------
"$N" mark "$BILL" claude 'Claude finished: Added the retry and its test.' s:a1
settle s:a1
chk "a finished turn elsewhere shows as a toast on the client" \
  "[ \"\$(screen)\" = ' ✓  billing-api · Claude finished: Added the retry and its test.' ]"
chk "the notify command gets the mark" \
  "[ \"\$(notified s:a1 RADAR_LEVEL)\" = done ] && [ \"\$(notified s:a1 RADAR_AGENT)\" = claude ] && [ \"\$(notified s:a1 RADAR_WHERE)\" = billing-api ] && [ \"\$(notified s:a1 RADAR_PANE)\" = '$BILL' ] && [ \"\$(notified s:a1 RADAR_SESSION)\" = work ]"
chk "and knows nobody is looking at the pane" "[ \"\$(notified s:a1 RADAR_WATCHED)\" = 0 ]"
chk "RADAR_TEXT is the toast as plain text" \
  "[ \"\$(notified s:a1 RADAR_TEXT)\" = '✓ billing-api · Claude finished: Added the retry and its test.' ]"
dismiss
chk "a key press dismisses the toast" "! screen | grep -q 'Added the retry'"

# --- announced once -----------------------------------------------------------------
rm -f "$T/notified.s:a1"
"$N" mark "$NOTES" tool 'a mark written for another reason' s:other
settle s:other
"$N" tick >/dev/null 2>&1
sleep 0.6
chk "a later write does not announce an older mark again" "[ ! -e '$T/notified.s:a1' ]"
"$N" clear-all
dismiss

# --- the pane the person is looking at ----------------------------------------------
"$N" mark "$NOTES" claude 'Claude needs approval: Bash' s:a2
settle s:a2
chk "no toast on the client that is already on the pane" "! screen | grep -q 'needs approval'"
chk "the notify command still runs, told the pane is watched" \
  "[ \"\$(notified s:a2 RADAR_WATCHED)\" = 1 ] && [ \"\$(notified s:a2 RADAR_LEVEL)\" = action ]"
"$N" clear-all

# --- levels and switches --------------------------------------------------------------
tmux set -g @radar-toast-levels 'action'
"$N" mark "$BILL" claude 'Claude finished: quiet one' s:a3
settle s:a3
chk "a level left out of @radar-toast-levels shows no toast" "! screen | grep -q 'quiet one'"
chk "but still reaches the notify command" "[ \"\$(notified s:a3 RADAR_LEVEL)\" = done ]"
"$N" mark "$BILL" claude 'Claude needs approval: Edit' s:a4
settle s:a4
chk "a listed level still toasts" "screen | grep -q '⚠  billing-api · Claude needs approval: Edit'"
dismiss
tmux set -gu @radar-toast-levels
tmux set -g @radar-toast off
"$N" mark "$BILL" claude 'Claude finished: toast is off' s:a5
settle s:a5
chk "@radar-toast off shows nothing" "! screen | grep -q 'toast is off'"
chk "and leaves the notify command on" "[ \"\$(notified s:a5 RADAR_LEVEL)\" = done ]"
tmux set -g @radar-toast status
"$N" clear-all

# --- paneless marks and old marks -----------------------------------------------------
"$N" mark - claude 'Claude·lattice: finished: all tests pass' s:bg1
settle s:bg1
chk "a background session's mark toasts with its project" \
  "[ \"\$(screen)\" = ' ✓  lattice · Claude finished: all tests pass' ]"
chk "and reaches the command with no pane" "[ \"\$(notified s:bg1 RADAR_PANE)\" = - ]"
dismiss
"$N" clear-all
printf '%s\t%s\tclaude\ts:old\tClaude finished: long ago\t\n' "$BILL" "$(( $(date +%s) - 600 ))" \
  > "$TMUX_RADAR_STATE_DIR/need-input"
"$N" mark "$NOTES" tool 'a fresh write' s:new
settle s:new
chk "a mark written long ago is never announced" "[ ! -e '$T/notified.s:old' ] && ! screen | grep -q 'long ago'"
"$N" clear-all

# --- text from agents and window names stays text ---------------------------------------
tmux rename-window -t work:billing-api "api##(touch $T/pwned-by-window)"
"$N" mark "$BILL" codex "Codex finished: see #(touch $T/pwned-by-label)" s:a6
settle s:a6
chk "a # in the window name or the label is printed, never run" \
  "screen | grep -qF 'api#(touch' && screen | grep -qF 'see #(touch' && sleep 1 && [ ! -e '$T/pwned-by-window' ] && [ ! -e '$T/pwned-by-label' ]"
chk "the notify command sees the label unchanged" \
  "[ \"\$(notified s:a6 RADAR_LABEL)\" = \"Codex finished: see #(touch $T/pwned-by-label)\" ]"
dismiss
"$N" mark "$BILL" claude 'Claude needs approval: date +%Y at 50% load' s:a9
settle s:a9
chk "a % in the label is printed, not read as a strftime field" \
  "screen | grep -qF 'Claude needs approval: date +%Y at 50% load'"
dismiss
tmux rename-window -t work:0 billing-api
"$N" clear-all

# --- a mark spooled while the state lock was busy is announced when replayed ---------
# written ten minutes ago: the lock stayed busy, and the replay came late
printf 'mark\t%s\t%s\ttool\ts:spooled\tClaude finished: replayed later\t\n' "$BILL" "$(( $(date +%s) - 600 ))" \
  > "$TMUX_RADAR_STATE_DIR/needinput-spool"
"$N" tick >/dev/null 2>&1
settle s:spooled
chk "a spooled mark is announced when tick replays it" \
  "[ \"\$(notified s:spooled RADAR_LABEL)\" = 'Claude finished: replayed later' ]"
dismiss
"$N" clear-all

# --- a notify command that fails or never ends holds up nothing -----------------------
tmux set -g @radar-notify-command 'sleep 30'
# shellcheck disable=SC2034 # read by the chk assertion below
start=$(date +%s)
"$N" mark "$BILL" claude 'Claude finished: slow command' s:a7
chk "the write returns while the notify command still runs" "[ \$(( \$(date +%s) - start )) -le 3 ]"
tmux set -g @radar-notify-command 'exit 3'
"$N" mark "$BILL" claude 'Claude finished: failing command' s:a8
settle s:a8
chk "a failing notify command shows nothing on the client" "! screen | grep -q 'returned'"
dismiss

# --- a client that detaches is not painted after it leaves ----------------------------
tmux set -gu @radar-notify-command
tmux set -g @radar-toast float
tmux set -g @radar-toast-duration 8000
"$N" mark "$BILL" claude 'Claude finished: detach check' s:f9
shown 'detach check'
tmux detach-client -t "$(tmux list-clients -F '#{client_name}')"
sleep 0.3
tmux -L "$OUTER" send-keys -t view 'echo shell-is-back' Enter
sleep 1
chk "after a detach the toast stops and paints nothing over the shell" \
  "tmux -L \"\$OUTER\" capture-pane -p -t view | grep -q '^shell-is-back' && ! tmux -L \"\$OUTER\" capture-pane -p -t view | grep -qF 'detach check' && idle"

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

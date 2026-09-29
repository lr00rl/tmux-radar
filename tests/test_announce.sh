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
tmux -L "$OUTER" -f /dev/null new-session -d -s view -x 120 -y 20 "env -u TMUX tmux -L $INNER attach -t work"
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
tmux set -gu @radar-toast
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

echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

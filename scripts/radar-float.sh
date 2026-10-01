#!/usr/bin/env bash
# Draw one floating toast in the top-right corner of one tmux client.
#
# Not a tmux popup: while a popup is open tmux stops redrawing every pane and
# sends every key to the popup. This writes the box straight to the client's
# terminal instead, the way Tarilonte/tmux-toast does: save the cursor (ESC 7),
# paint the box at absolute positions, restore the cursor (ESC 8, which also
# restores the colours tmux believes are set). tmux knows nothing of the box,
# so panes keep drawing and keys go where they always go. When a pane redraws
# under the box, the next repaint (every 20 ms) puts it back; a pane that
# scrolls fast can still tear it between repaints. At the end refresh-client
# repaints the screen from tmux's own copy. It works over SSH: the client's
# terminal is a device on the tmux host.
#
#   ╭─ ✓ billing-api ────────────────────────╮
#   │ Claude finished: Added the retry and … │
#   ╰────────────────────────────────────────╯
#
# Several toasts on one client stack downward in slots; when none is free or
# the screen has no room, the toast goes to the status line instead. A toast
# ends after its duration (60 s at most), as soon as its mark is gone (the
# person went to the pane), or the moment its client leaves: the client
# process exits on detach, and from then on the terminal is the shell's.
#
# A click on the box goes to the mark's pane. tmux never sees the box, so the
# plugin's MouseDown1Pane binding asks needinput-notify.sh toast-click whether
# a click landed on one, but only while @radar-toast-live is set: no fork per
# click otherwise. While a toast is up its slot holds `hit`:
#   <column> <row> <width> <pane> <pid of this script>
# and the flag stays set while any slot does.
#
# usage: radar-float.sh <client> <tty> <client-pid> <cols> <top> <bottom>
#                       <utf8> <level> <where> <label> <ms> <key> <marks> <slots>
#                       [pane]
#   top, bottom  first and last screen rows free of status lines (1-based)
#   utf8         1 when the client's terminal speaks UTF-8
#   pane         where a click goes; `-` (a paneless mark) opens the picker
set -u

client="$1" tty="$2" cpid="$3" cols="$4" top="$5" bottom="$6" utf8="$7" level="$8"
where="$9" label="${10}" ms="${11}" key="${12}" marks="${13}" slots="${14}" pane="${15:--}"

case "$cpid$cols$top$bottom$ms" in *[!0-9]*) exit 0 ;; esac
[ -n "$tty" ] && [ -w "$tty" ] || exit 0
[ "$ms" -le 60000 ] || ms=60000

# Character counts need a UTF-8 locale; the tmux server's may have none. The
# announce job looks one up once and passes it in RADAR_UTF8_LOCALE.
unset LC_ALL
if [ "$utf8" = 1 ]; then
  if [ -n "${RADAR_UTF8_LOCALE:-}" ]; then
    LC_ALL="$RADAR_UTF8_LOCALE"; export LC_ALL
  else
    for loc in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
      if locale -a 2>/dev/null | grep -qx "$loc"; then LC_ALL="$loc"; export LC_ALL; break; fi
    done
  fi
fi

# Text from agents and window names reaches the terminal as it is: every
# control character (ESC, and C1 such as the one-byte CSI) becomes a space,
# so no text can move the cursor, set a title or write the clipboard. Bytes
# that are not UTF-8 go first, so no stray lead byte can eat the escape
# sequence that follows the text.
clean_utf8() {
  command -v iconv >/dev/null 2>&1 || { printf '%s' "$1"; return; }
  printf '%s' "$1" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
}
if [ -n "${LC_ALL:-}" ]; then
  where="$(clean_utf8 "$where")"
  label="$(clean_utf8 "$label")"
  where="${where//[[:cntrl:]]/ }"
  label="${label//[[:cntrl:]]/ }"
else
  # byte by byte: anything outside printable ASCII, 8-bit controls included
  LC_ALL=C
  where="${where//[^[:print:]]/?}"
  label="${label//[^[:print:]]/?}"
  unset LC_ALL
fi

# Columns a string may take: a non-ASCII character counts as two, which is
# true for CJK and more than enough for everything else.
cols_of() {
  local s="$1" na
  na="${s//[[:ascii:]]/}"
  printf '%s' $(( ${#s} + ${#na} ))
}

fit() {  # fit <text> <cols>: the text, cut with an ellipsis to fit
  local s="$1" max="$2"
  [ "$(cols_of "$s")" -le "$max" ] && { printf '%s' "$s"; return; }
  s="${s:0:$max}"
  while [ -n "$s" ] && [ $(( $(cols_of "$s") + 1 )) -gt "$max" ]; do s="${s%?}"; done
  printf '%s%s' "$s" "$ell"
}

repeat() {  # repeat <char> <n>
  local out="" i=0
  while [ "$i" -lt "$2" ]; do out="$out$1"; i=$((i + 1)); done
  printf '%s' "$out"
}

if [ "$utf8" = 1 ] && [ -n "${LC_ALL:-}" ]; then
  tl='╭' tr='╮' bl='╰' br='╯' h='─' v='│' ell='…'
  case "$level" in action) glyph='⚠' ;; done) glyph='✓' ;; *) glyph='!' ;; esac
else
  tl='+' tr='+' bl='+' br='+' h='-' v='|' ell='~'
  case "$level" in action) glyph='!' ;; done) glyph='v' ;; *) glyph='i' ;; esac
fi
case "$level" in
  action) accent=$'\033[38;5;208m' ;;
  done)   accent=$'\033[38;5;35m' ;;
  *)      accent=$'\033[38;5;220m' ;;
esac
bold=$'\033[1m' reset=$'\033[0m'

# No box fits: say it on the status line, printed as it is (-l).
fallback() {
  tmux display-message -C -l -d "$ms" -c "$client" "$glyph $where · $label" 2>/dev/null
  exit 0
}
[ "$cols" -ge 30 ] || fallback

# Inner width: the label's, between 24 and 60 columns, within the screen.
max=$(( cols - 8 )); [ "$max" -le 60 ] || max=60
title="$(fit "$glyph $where" "$((max - 2))")"
body="$(fit "$label" "$max")"
inner=$(cols_of "$body")
t=$(( $(cols_of "$title") + 2 )); [ "$t" -le "$inner" ] || inner=$t
[ "$inner" -ge 24 ] || inner=24
[ "$inner" -le "$max" ] || inner=$max
width=$(( inner + 4 ))
x=$(( cols - width - 1 ))

# A slot per toast on this client, claimed with mkdir; a slot older than two
# minutes was left by a toast that was killed.
sdir="$slots/${client//[^A-Za-z0-9._-]/_}"
mkdir -p "$sdir" 2>/dev/null || exit 0
find "$sdir" -mindepth 1 -maxdepth 1 -type d -mmin +2 -exec rm -rf {} + 2>/dev/null
slot=""
for s in 0 1 2 3 4 5; do
  if mkdir "$sdir/$s" 2>/dev/null; then slot=$s; break; fi
done
[ -n "$slot" ] || fallback
y=$(( top + 1 + slot * 3 ))
if [ $(( y + 2 )) -gt "$bottom" ]; then rmdir "$sdir/$slot" 2>/dev/null; fallback; fi

# Each line is painted whole first (every cell width one, so the right edge
# lands exactly), then the text is written over it from the left.
at() { printf '\033[%d;%dH' "$1" "$2"; }
frame=$'\0337'
frame="$frame$(at "$y" "$x")$reset$accent$tl$(repeat "$h" $((width - 2)))$tr"
frame="$frame$(at "$y" $((x + 2)))$bold$accent $title $reset"
frame="$frame$(at $((y + 1)) "$x")$accent$v$reset$(repeat ' ' $((width - 2)))$accent$v$reset"
frame="$frame$(at $((y + 1)) $((x + 2)))$body"
frame="$frame$(at $((y + 2)) "$x")$accent$bl$(repeat "$h" $((width - 2)))$br$reset"
frame="$frame"$'\0338'

# Checked before every repaint, both without a fork.
attached() { kill -0 "$cpid" 2>/dev/null; }
marked() {
  local l
  [ -n "$key" ] || return 0
  [ -r "$marks" ] || return 1
  while IFS= read -r l; do
    case "$l" in *"	$key	"*) return 0 ;; esac
  done < "$marks"
  return 1
}

# However the toast ends (its time, its mark, its client, a signal), the slot
# is freed and tmux repaints the screen over the box, if the client is there.
cleanup() {
  rm -f "$sdir/$slot/hit"
  rmdir "$sdir/$slot" 2>/dev/null
  # the last toast anywhere lowers the click flag; one that started meanwhile
  # raises it again
  set -- "$slots"/*/*/hit
  if [ ! -e "$1" ]; then
    tmux set -gu @radar-toast-live 2>/dev/null
    set -- "$slots"/*/*/hit
    [ ! -e "$1" ] || tmux set -g @radar-toast-live 1 2>/dev/null
  fi
  exec 3>&- 2>/dev/null
  attached && tmux refresh-client -t "$client" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM PIPE

printf '%s %s %s %s %s\n' "$x" "$y" "$width" "$pane" "$$" > "$sdir/$slot/hit" 2>/dev/null
tmux set -g @radar-toast-live 1 2>/dev/null

{ exec 3>"$tty"; } 2>/dev/null || exit 0
n=$(( ms / 20 )); [ "$n" -ge 1 ] || n=1
i=0
while [ "$i" -lt "$n" ] && attached && marked; do
  printf '%s' "$frame" >&3 2>/dev/null || break
  sleep 0.02
  i=$((i + 1))
done
exit 0

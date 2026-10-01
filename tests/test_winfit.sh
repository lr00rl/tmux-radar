#!/usr/bin/env bash
# Window names fitted to the client's width (scripts/radar-winfit.sh). A real
# client is attached: a second isolated server runs `tmux attach` in a pane,
# and the test reads that pane's last line, which is the status line the
# person sees. The expected names come from the rule written out
# independently here: share the room equally, hand back what short names do
# not use to the cut ones, repeat. Never touches the live server.
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIT="$WT/scripts/radar-winfit.sh"
N="$WT/scripts/needinput-notify.sh"
T="$(mktemp -d /tmp/radar-winfit.XXXXXX)"
export TMUX_RADAR_STATE_DIR="$T/state" TMUX_RADAR_NO_SCHEDULE=1 TMUX_TMPDIR="$T"
INNER="radarfit$$"
OUTER="radarfitview$$"

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

NAMES="tmux-radar editor_theme editor-plugin-lite feedsync infra shared_working_place billing-claude frontend blog misc"
first=1
for n in $NAMES; do
  if [ "$first" = 1 ]; then
    tmux -L "$INNER" -f /dev/null new-session -d -s work -n "$n" -x 175 -y 10 'sleep 600'; first=0
  else
    tmux -L "$INNER" new-window -d -t work: -n "$n" 'sleep 600'
  fi
done
SOCK="$(tmux -L "$INNER" display-message -p '#{socket_path}')"
export TMUX="$SOCK,99999,0"
tmux set -g automatic-rename off \; set -g status-left '[work] ' \; set -g status-right '10-01 05:51 ' \
  \; set -g window-status-separator '' \; select-window -t work:0
# catppuccin v2 builds these with set -gF: the text and number colour are copied in
CTP_FMT='#[fg=#11111b,bg=#{@thm_overlay_2}] #I #[fg=#cdd6f4,bg=#313244] #W '
CTP_CUR='#[fg=#11111b,bg=#{@thm_mauve}] #I #[fg=#cdd6f4,bg=#45475a] #W '
tmux set -g @thm_overlay_2 '#9399b2' \; set -g @thm_mauve '#cba6f7' \
  \; set -g @catppuccin_window_number_color '#{@thm_overlay_2}' \
  \; set -gw window-status-format "$CTP_FMT" \; set -gw window-status-current-format "$CTP_CUR"

tmux -L "$OUTER" -f /dev/null new-session -d -s view -x 175 -y 10 "env -u TMUX tmux -L $INNER attach -t work; exec sleep 600"
for _ in $(seq 1 20); do
  [ -n "$(tmux list-clients -F '#{client_name}' 2>/dev/null)" ] && break
  sleep 0.2
done

cells() { perl -CS -ne 'my $w = 0; $w += /\p{EA=W}|\p{EA=F}/ ? 2 : 1 for split //; print $w'; }
bar() { tmux -L "$OUTER" capture-pane -p -t view | tail -1 | sed 's/ *$//'; }
width() {  # width <cols>: resize the client and wait for its status line to settle
  local _ prev="" cur
  tmux -L "$OUTER" resize-window -t view -x "$1" -y 10
  for _ in $(seq 1 15); do
    sleep 0.2
    cur="$(bar)"
    [ -n "$cur" ] && [ "$cur" = "$prev" ] && break
    prev="$cur"
  done
}
# the names the bar shows, in window order ("" for a number alone)
shown() {  # shown <line> <status-left text> <status-right text>: drop both sides and the numbers
  local l="$1" lt="$2" rt="$3"
  rt="${rt%"${rt##*[! ]}"}"                       # the bar's line has no trailing spaces
  l="${l#"$lt"}"; l="${l%"$rt"}"
  printf '%s' "$l" |
    awk '{ s = ""; for (i = 1; i <= NF; i++) if ($i !~ /^[0-9]+$/) s = s (s == "" ? "" : " ") $i; print s }'
}
client() { tmux list-clients -F '#{client_name}' | head -1; }
# a status side as this client draws it, styles removed
side() { tmux display-message -c "$(client)" -p "#{T:$1}" | sed 's/#\[[^]]*\]//g'; }
# The rule, written out on its own: room = width - left - right - each
# window's number and padding; equal shares; whatever a short name leaves goes
# back to the cut ones; repeat; spare columns go one each to the first cut
# windows. Below <min> each, only marked windows (their positions) keep
# names, each at least <min> or none, the most urgent first when not all fit
# (<marks> lists position:urgency, 3 approval, 2 notice, 1 finished); what
# they leave goes to the current window (position <cur>) if <min> of it fits.
expect() {  # expect <cols> <pad per window> <marks> <cur> <left width> <right width> <names...>
  local cols="$1" pad="$2" marks="$3" cur="$4" lw="$5" rw="$6"; shift 6
  printf '%s\n' "$@" | awk -v W="$cols" -v pad="$pad" -v marks=" $marks " -v cur="$cur" -v LW="$lw" -v RW="$rw" -v M=4 '
    { n++; nm[n] = $0; L[n] = length($0) }
    END {
      R = W - LW - RW
      for (i = 1; i <= n; i++) R -= pad + length(i - 1)
      wide = 0
      for (i = 1; i <= n; i++) wide += (L[i] < M ? L[i] : M)
      nmk = split(marks, mp, " ")
      for (x = 1; x <= nmk; x++) { split(mp[x], kv, ":"); mk[kv[1] + 1] = kv[2] + 0 }
      # the most urgent marked windows that get <min> each
      # (radar names at most the 4 most urgent on a narrow client)
      used = 0; stop = 0; ntake = 0
      for (u = 3; u >= 1; u--) for (i = 1; i <= n; i++)
        if ((i in mk) && mk[i] == u && !stop && ntake < 4) { m = (L[i] < M ? L[i] : M); if (used + m <= R) { used += m; take[i] = 1; ntake++ } else stop = 1 }
      for (i = 1; i <= n; i++) act[i] = (wide <= R) || take[i]
      b = R
      while (1) {
        na = 0; for (i = 1; i <= n; i++) if (act[i]) na++
        if (na == 0) break
        s = int(b / na); if (s < 0) s = 0; moved = 0
        for (i = 1; i <= n; i++) if (act[i] && L[i] <= s) { give[i] = L[i]; b -= L[i]; act[i] = 0; moved = 1 }
        if (!moved) {
          r = b - s * na
          for (i = 1; i <= n; i++) if (act[i]) { give[i] = s + (r > 0 ? 1 : 0); if (r > 0) r--; act[i] = 0 }
          break
        }
      }
      if (wide > R) {
        c = cur + 1; left = R; for (i = 1; i <= n; i++) left -= give[i]
        m = (L[c] < M ? L[c] : M)
        if (!(c in mk) && left >= m) give[c] = (left < L[c] ? left : L[c])
      }
      out = ""
      for (i = 1; i <= n; i++) if (give[i] > 0) out = out (out == "" ? "" : " ") substr(nm[i], 1, give[i])
      print out
    }'
}
fits() {  # fits <cols> <case> [marks]: the bar shows the expected names and fills, never overflows
  local cols="$1" what="$2" marks="${3:-}" line got want used lt rt reserve
  width "$cols"
  lt="$(side status-left)"; rt="$(side status-right)"
  reserve="$(tmux show -gqv @radar-win-reserve)"
  line="$(bar)"; got="$(shown "$line" "$lt" "$rt")"
  # shellcheck disable=SC2086
  want="$(expect "$cols" 4 "$marks" "$(tmux display -p -t work: '#{window_index}')" \
    "$(printf '%s' "$lt" | cells)" "$(( $(printf '%s' "$rt" | cells) + ${reserve:-0} ))" \
    $(tmux list-windows -t work -F '#{window_name}'))"
  used="$(printf '%s' "$line" | cells)"
  chk "$what: names [$got]" '[ "$got" = "$want" ] || { echo "   want [$want]"; echo "   line |$line|"; false; }'
  chk "$what: within $cols columns, no overflow marker" '[ "$used" -le "$cols" ] && ! printf "%s" "$line" | grep -q "[<>]"'
}

echo "== patch: point the theme's formats at the fitted name =="
"$FIT" patch
chk "state is on" '[ "$(tmux show -gv @radar-win-fit-state)" = on ]'
F="$(tmux show -gwv window-status-format)"; C="$(tmux show -gwv window-status-current-format)"
chk "the name in each format is the fitted name" '[[ "$F" == *"#{E:@radar-wname} " ]] && [[ "$C" == *"#{E:@radar-wname} " ]] && [[ "$F" != *"#W"* ]]'
chk "catppuccin's number colour follows the radar colour" '[[ "$F" == *"bg=#{?#{@radar-color},#{@radar-color},#{@thm_overlay_2}}"* ]]'
chk "the current window keeps its own colour" '[[ "$C" == *"bg=#{@thm_mauve}"* ]]'
chk "what a window costs without its name is recorded" '[ "$(tmux show -gv @radar-win-shell)" = "${F%#\{E:@radar-wname\} } " ]'
# the option holds format text, so read it with show-option, not #{?...}
without() { local w n=0; for w in $(tmux list-windows -a -F '#{window_id}'); do [ -n "$(tmux show -wqv -t "$w" @radar-wname)" ] || n=$((n+1)); done; echo "$n"; }
chk "every window has cut points" '[ "$(without)" -eq 0 ]'
"$FIT" patch
chk "patching twice changes nothing" '[ "$(tmux show -gwv window-status-format)" = "$F" ] && [ "$(tmux show -gwv window-status-current-format)" = "$C" ]'

echo "== the fill rule at several widths (catppuccin-style padding) =="
fits 175 "175 columns, every name whole"
fits 150 "150 columns"
fits 130 "130 columns"
fits 116 "116 columns"
fits 110 "110 columns, still four or more per name"
chk "110 columns uses the full width" '[ "$(bar | cells)" -eq 110 ]'
fits 90 "90 columns, nothing marked: the current window's name only"
chk "90 columns, nothing marked: that is window 0" '[ "$(shown "$(bar)" "$(side status-left)" "$(side status-right)")" = tmux-radar ]'

echo "== narrow: only marked windows keep a name =="
tmux set -wq -t work:5 @radar-color colour208 \; set -wq -t work:2 @radar-color colour35
"$FIT" publish
fits 90 "90 columns, windows 2 and 5 marked" "2:1 5:3"
fits 80 "80 columns, windows 2 and 5 marked" "2:1 5:3"
fits 76 "76 columns, windows 2 and 5 marked: only the approval keeps its name" "2:1 5:3"
fits 70 "70 columns, windows 2 and 5 marked: too little for four, numbers only" "2:1 5:3"
tmux set -wqu -t work:2 @radar-color; "$FIT" publish
fits 75 "75 columns, window 5 marked: its name, then window 0 in what is left" "5:3"
fits 100 "100 columns, window 5 marked: its whole name, then window 0 in what is left" "5:3"
tmux set -wq -t work:2 @radar-color colour35; "$FIT" publish
fits 130 "130 columns, marks change nothing when every name fits its share" "2:1 5:3"
tmux set -wqu -t work:5 @radar-color \; set -wqu -t work:2 @radar-color
"$FIT" publish

echo "== a mark written by radar republishes the names =="
P5="$(tmux display-message -p -t work:5 '#{pane_id}')"
"$N" mark "$P5" tool 'Claude needs approval: Bash' s:fit5
chk "the marked window got its colour" '[ -n "$(tmux show -wqv -t work:5 @radar-color)" ]'
fits 90 "90 columns after a real mark on window 5" "5:3"
"$N" clear-key s:fit5
fits 90 "90 columns once the mark is handled" ""

echo "== two-digit window numbers and a wide-character name =="
tmux new-window -d -t work:10 -n 中文窗口名字 'sleep 600' \; new-window -d -t work:11 -n eleven 'sleep 600'
"$FIT" publish
for c in 175 150 130; do
  width "$c"; line="$(bar)"; used="$(printf '%s' "$line" | cells)"
  chk "$c columns with 12 windows: within the width, no overflow marker" '[ "$used" -le "$c" ] && ! printf "%s" "$line" | grep -q "<\|>"'
done
width 210
chk "210 columns: the wide-character name is whole" '[[ "$(bar)" == *"10  中文窗口名字  11  eleven"* ]]'
width 150
chk "150 columns: the wide-character name is cut on a character" '[[ "$(bar)" =~ 10\ \ 中文[^\ ]*\ \ 11 ]]'
tmux kill-window -t work:10 \; kill-window -t work:11
"$FIT" publish

echo "== many marked windows with long names stay under tmux's 16 KB command limit =="
orig="$(tmux list-windows -t work -F '#{window_index} #{window_name}')"
for i in 0 1 2 3 4 5 6 7 8 9; do
  tmux rename-window -t "work:$i" "a-window-name-thirty-one-cells-$i" \; set -wq -t "work:$i" @radar-color "$( [ $((i % 3)) = 0 ] && echo colour208 || echo colour35)"
done
"$FIT" publish
big=0; for w in $(tmux list-windows -t work -F '#{window_id}'); do n="$(tmux show -wqv -t "$w" @radar-wname | wc -c)"; [ "$n" -gt "$big" ] && big="$n"; done
chk "every window got its cut points in one publish" '[ "$(without)" -eq 0 ]'
chk "no window's cut points come near 16 KB (largest: $big bytes)" '[ "$big" -lt 15000 ]'
fits 175 "175 columns, ten long names" "0:3 1:1 2:1 3:3 4:1 5:1 6:3 7:1 8:1 9:3"
fits 90 "90 columns, all marked: the four most urgent keep names" "0:3 1:1 2:1 3:3 4:1 5:1 6:3 7:1 8:1 9:3"
printf '%s\n' "$orig" | while read -r i n; do tmux rename-window -t "work:$i" "$n" \; set -wqu -t "work:$i" @radar-color; done
"$FIT" publish
fits 130 "130 columns, names and marks back as before"

echo "== past 30 windows a session keeps its whole names =="
tmux new-session -d -s many -n first 'sleep 600'
for i in $(seq 1 30); do tmux new-window -d -t many: -n "many-window-$i" 'sleep 600'; done
"$FIT" publish
chk "31 windows: every name is left whole" '[ "$(for w in $(tmux list-windows -t many -F "#{window_id}"); do tmux show -wqv -t "$w" @radar-wname; done | sort -u)" = "#W" ]'
tmux kill-window -t many:30; "$FIT" publish
chk "30 windows: fitted again" '! tmux show -wqv -t many:1 @radar-wname | grep -qx "#W"'
tmux kill-session -t many; "$FIT" publish

echo "== a stale publish can waste room but never overflow =="
tmux rename-window -t work:9 'a-much-longer-name-than-before-for-misc'
for c in 175 130 90; do
  width "$c"; line="$(bar)"; used="$(printf '%s' "$line" | cells)"
  chk "$c columns before republishing: within the width" '[ "$used" -le "$c" ] && ! printf "%s" "$line" | grep -q "<\|>"'
done
tmux rename-window -t work:9 misc
"$FIT" publish

echo "== tmux's own window format (no theme) =="
tmux set -gwu window-status-format \; set -gwu window-status-current-format
"$FIT" patch
chk "the default formats are patched" '[ "$(tmux show -gv @radar-win-fit-state)" = on ] && [[ "$(tmux show -gwv window-status-format)" == *"#I:#{E:@radar-wname}#"* ]]'
for c in 175 130 110 90; do
  width "$c"; line="$(bar)"; used="$(printf '%s' "$line" | cells)"
  chk "$c columns, default format: within the width, no overflow marker" '[ "$used" -le "$c" ] && ! printf "%s" "$line" | grep -q "<\|>"'
done
width 175
chk "175 columns, default format: every name whole" '[[ "$(bar)" == *"0:tmux-radar*"*":editor-plugin-lite"*":shared_working_place"*"9:misc"* ]]'

echo "== formats it cannot patch are left alone =="
tmux set -gw window-status-format '#I #W #W' \; set -gw window-status-current-format '#I #W'
"$FIT" patch
chk "two names in one format: skipped, with a reason" '[[ "$(tmux show -gv @radar-win-fit-state)" == skipped:* ]]'
chk "two names in one format: the formats are untouched" '[ "$(tmux show -gwv window-status-format)" = "#I #W #W" ] && [ "$(tmux show -gwv window-status-current-format)" = "#I #W" ]'
tmux set -gw window-status-format '#{?#{==:#{window_name},x},#W,#I}' \; set -gw window-status-current-format '#I #W'
"$FIT" patch
chk "a name inside #{...} is not a stand-alone name" '[[ "$(tmux show -gv @radar-win-fit-state)" == skipped:* ]]'
held="$(tmux show -wqv -t work:4 @radar-wname)"; tmux rename-window -t work:4 infra-renamed-while-skipped; "$FIT" publish
chk "publish does nothing while skipped" '[ "$(tmux show -wqv -t work:4 @radar-wname)" = "$held" ]'
tmux rename-window -t work:4 infra

echo "== off puts the plain name back =="
tmux set -gw window-status-format "$CTP_FMT" \; set -gw window-status-current-format "$CTP_CUR"
"$FIT" patch
"$FIT" off
chk "off: the formats show #W again" '[[ "$(tmux show -gwv window-status-format)" == *" #W " ]] && [[ "$(tmux show -gwv window-status-current-format)" == *" #W " ]]'
chk "off: no window keeps cut points" '[ "$(without)" -eq "$(tmux list-windows -a | wc -l | tr -d " ")" ]'
chk "off: state says off" '[ "$(tmux show -gv @radar-win-fit-state)" = off ]'

echo "== the sides are measured as drawn: the session's own, in the current window =="
tmux set -gw window-status-format "$CTP_FMT" \; set -gw window-status-current-format "$CTP_CUR"
"$FIT" patch
tmux select-pane -t work:0 -T short \; select-pane -t work:1 -T 'a much longer pane title here' \; select-pane -t work:2 -T mid-title
# a pane-dependent right side: each window would measure its own pane's title
tmux set -g status-right '"#{=21:pane_title}" '
"$FIT" publish
fits 150 "150 columns, the right side shows the current pane's title"
fits 120 "120 columns, the right side shows the current pane's title"
tmux select-window -t work:1
fits 120 "120 columns after moving to the window with the long title"
fits 100 "100 columns after moving to the window with the long title"
tmux select-window -t work:0
# a job on the right runs as often as with radar off, not once more per window
tmux set -g status-interval 1 \; set -g status-right "#(echo x >> $T/jobs) 10-01 05:51 "
"$FIT" publish
chk "the room is measured from a copy without the job" '[ "$(tmux show -gv @radar-win-right)" = " 10-01 05:51 " ]'
width 150; : > "$T/jobs"; sleep 4; on="$(wc -l < "$T/jobs" | tr -d ' ')"
"$FIT" off; : > "$T/jobs"; sleep 4; off="$(wc -l < "$T/jobs" | tr -d ' ')"
chk "the job ran about as often with fitting on ($on) as off ($off)" '[ "$on" -le $((off + 2)) ]'
"$FIT" patch
# a job that prints: its columns are kept back with @radar-win-reserve
tmux set -g status-right '#(echo job-output-here) 10-01 05:51 '
"$FIT" publish
tmux set -g @radar-win-reserve 16
width 120; sleep 2.2; width 121; width 120
line="$(bar)"; used="$(printf '%s' "$line" | cells)"
chk "with the reserve the job's text fits and the bar fills to it" '[[ "$line" == *"job-output-here 10-01 05:51" ]] && [ "$used" -ge 118 ] && [ "$used" -le 120 ] && ! printf "%s" "$line" | grep -q "[<>]"'
tmux set -gu @radar-win-reserve
tmux set -g status-interval 15 \; set -g status-right '10-01 05:51 '
"$FIT" publish
# a session's own status-right is the one drawn
tmux set -t work status-right 'session-own-right-side-of-forty-cells '
"$FIT" publish
chk "a session's own side gets its own copy" '[ "$(tmux show -qv -t work @radar-win-right)" = "session-own-right-side-of-forty-cells " ]'
fits 130 "130 columns with a session's own status-right"
tmux set -t work -u status-right
"$FIT" publish
chk "the copy goes when the session drops its own side" '[ -z "$(tmux show -qv -t work @radar-win-right)" ]'
tmux set -g status-right '10-01 05:51\;'
"$FIT" publish
chk "a side ending in ; keeps it in the copy" '[ "$(tmux show -gv status-right)" = "10-01 05:51;" ] && [ "$(tmux show -gv @radar-win-right)" = "10-01 05:51;" ]'
tmux set -g status-right '10-01 05:51 '
"$FIT" publish
fits 130 "130 columns with the global status-right again"

echo "== escapes and jobs in a window format =="
tmux set -gw window-status-format '#{?window_zoomed_flag,#}#W,} #I #W ' \; set -gw window-status-current-format '#(echo #W) #I #W '
"$FIT" patch
chk "a #W after #} inside #{...} and one inside #(...) are left alone" '[ "$(tmux show -gv @radar-win-fit-state)" = on ] && [ "$(tmux show -gwv window-status-format)" = "#{?window_zoomed_flag,#}#W,} #I #{E:@radar-wname} " ] && [ "$(tmux show -gwv window-status-current-format)" = "#(echo #W) #I #{E:@radar-wname} " ]'

echo "== a reload that cannot patch takes the old patch away =="
tmux set -gw window-status-format "$CTP_FMT" \; set -gw window-status-current-format "$CTP_CUR"
"$FIT" patch
sf="$(tmux show -gv 'status-format[0]')"
tmux set -g 'status-format[0]' '#[align=left]#{W:#I }'
"$FIT" patch
chk "a customised status line: skipped" '[[ "$(tmux show -gv @radar-win-fit-state)" == skipped:* ]]'
chk "a customised status line: #W and the theme colour are back" '[ "$(tmux show -gwv window-status-format)" = "$CTP_FMT" ] && [ "$(tmux show -gwv window-status-current-format)" = "$CTP_CUR" ]'
chk "a customised status line: no window keeps cut points" '[ "$(without)" -eq "$(tmux list-windows -a | wc -l | tr -d " ")" ] && [ -z "$(tmux show -gqv @radar-win-avail)" ]'
tmux set -g 'status-format[0]' "$sf"
"$FIT" patch
chk "the patch comes back with the default status line" '[ "$(tmux show -gv @radar-win-fit-state)" = on ]'

echo "== publishes that overlap end in the same state as one =="
for i in 1 2 3 4 5 6 7 8; do "$FIT" publish & done; wait
want_state="$(for w in $(tmux list-windows -a -F '#{window_id}'); do tmux show -wqv -t "$w" @radar-wname | cksum; done)"
for w in $(tmux list-windows -a -F '#{window_id}'); do tmux set -wqu -t "$w" @radar-wname; done
"$FIT" publish
chk "eight at once leave every window as one publish would" '[ "$(for w in $(tmux list-windows -a -F "#{window_id}"); do tmux show -wqv -t "$w" @radar-wname | cksum; done)" = "$want_state" ]'
chk "no request is left waiting" '[ ! -e "$TMUX_RADAR_STATE_DIR/.winfit.again" ]'
# a publish killed while holding the lock
L="$TMUX_RADAR_STATE_DIR/.winfit.lock"
if command -v flock >/dev/null; then flock "$L" sleep 30 & holder=$!
else lockf "$L" sleep 30 & holder=$!; fi
sleep 0.5
tmux rename-window -t work:4 infra-held; "$FIT" publish
chk "while the lock is held a publish only leaves its request" '[ -e "$TMUX_RADAR_STATE_DIR/.winfit.again" ] && ! tmux show -wqv -t work:4 @radar-wname | grep -q "=10:"'
pkill -P "$holder" 2>/dev/null; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
tmux rename-window -t work:4 infra-renamed; "$FIT" publish
chk "a lock held by a dead publish does not block the next one" 'tmux show -wqv -t work:4 @radar-wname | grep -q "=13:"'
tmux rename-window -t work:4 infra
# a lock file that cannot be opened: publish anyway, unserialised
rm -f "$L"; mkdir "$L"
tmux rename-window -t work:4 infra-lockdir; "$FIT" publish
chk "an unopenable lock does not stop publishing" 'tmux show -wqv -t work:4 @radar-wname | grep -q "=13:" && [ ! -e "$TMUX_RADAR_STATE_DIR/.winfit.again" ]'
rmdir "$L"; tmux rename-window -t work:4 infra; "$FIT" publish
# nowhere to keep a lock: publish anyway
: > "$T/not-a-dir"
TMUX_RADAR_STATE_DIR="$T/not-a-dir/state" "$FIT" publish 2>"$T/err"
chk "an unusable state directory still publishes, quietly" 'tmux show -wqv -t work:4 @radar-wname | grep -q "=5:" && [ ! -s "$T/err" ]'

echo "== a window linked into two sessions is fitted for the bigger one =="
tmux new-session -d -s small -n alone 'sleep 600'
tmux link-window -s work:5 -t small:7
"$FIT" publish
linked="$(tmux show -wqv -t work:5 @radar-wname)"
tmux unlink-window -t small:7; "$FIT" publish
chk "linked or not, window 5 keeps the cut points of its ten-window session" '[ "$linked" = "$(tmux show -wqv -t work:5 @radar-wname)" ]'
tmux kill-session -t small; "$FIT" publish

echo "== off puts the theme back as it was =="
"$FIT" off
chk "off: the theme's number colour is back" '[ "$(tmux show -gwv window-status-format)" = "$CTP_FMT" ]'
"$FIT" patch

echo "== the plugin entry keeps the names current =="
tmux set -gw window-status-format "$CTP_FMT" \; set -gw window-status-current-format "$CTP_CUR"
bash "$WT/tmux-radar.tmux" >/dev/null 2>&1
chk "loading the plugin patches the formats" '[ "$(tmux show -gv @radar-win-fit-state)" = on ]'
waitfor() { local _; for _ in $(seq 1 25); do eval "$1" && return 0; sleep 0.2; done; return 1; }
chk "loading the plugin sets the window hooks" '[ "$( { tmux show-hooks -g; tmux show-hooks -gw; } | grep -c "radar-winfit.sh publish")" -eq 4 ]'
tmux new-session -d -s other -n fresh-session-window 'sleep 600'
chk "a new session's window gets cut points" 'waitfor "[ -n \"\$(tmux show -wqv -t other:0 @radar-wname)\" ]"'
# a session's own status-right set at runtime is picked up by a session switch
tmux set -t work status-right 'set-at-runtime '
tmux switch-client -c "$(client)" -t other; tmux switch-client -c "$(client)" -t work
chk "a session switch refreshes the session's copy" 'waitfor "[ \"\$(tmux show -qv -t work @radar-win-right)\" = \"set-at-runtime \" ]"'
tmux set -t work -u status-right; "$FIT" publish
tmux kill-session -t other
base="$(tmux show -wqv -t work:0 @radar-wname)"
tmux new-window -d -t work:12 -n brand-new-window 'sleep 600'
chk "a new window gets cut points" 'waitfor "[ -n \"\$(tmux show -wqv -t work:12 @radar-wname)\" ]"'
waitfor "[ \"\$(tmux show -wqv -t work:0 @radar-wname)\" != \"\$base\" ]"
# a longer name moves the cut points of windows long enough to compete with it
before="$(tmux show -wqv -t work:5 @radar-wname)"
tmux rename-window -t work:12 renamed-to-something-quite-a-bit-longer
chk "a rename republishes the others" 'waitfor "[ \"\$(tmux show -wqv -t work:5 @radar-wname)\" != \"\$before\" ]"'
tmux kill-window -t work:12
chk "closing a window republishes" 'waitfor "[ \"\$(tmux show -wqv -t work:0 @radar-wname)\" = \"\$base\" ]"'
fits 130 "130 columns after the plugin entry, a new window and its close"
tmux set -g @radar-restoring 1
held="$(tmux show -wqv -t work:3 @radar-wname)"
tmux rename-window -t work:3 restored-window-name-long
sleep 0.8
chk "while restoring, renames do not republish" '[ "$(tmux show -wqv -t work:3 @radar-wname)" = "$held" ]'
"$N" restore-end
chk "restore-end republishes once" 'waitfor "tmux show -wqv -t work:3 @radar-wname | grep -q =25:"'
tmux rename-window -t work:3 feedsync
tmux set -g @radar-win-fit off
bash "$WT/tmux-radar.tmux" >/dev/null 2>&1
chk "@radar-win-fit off: formats restored and hooks removed" '[[ "$(tmux show -gwv window-status-format)" == *" #W " ]] && [ "$( { tmux show-hooks -g; tmux show-hooks -gw; } | grep -c "radar-winfit.sh")" -eq 0 ]'

echo
echo "passed: $PASS failed: $FAIL"
[ "$FAIL" -eq 0 ]

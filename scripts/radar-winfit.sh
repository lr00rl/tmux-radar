#!/usr/bin/env bash
# Fit the window list to each client's width (@radar-win-fit, default on).
#
# The bar's width is shared out the way you would by hand: take what the
# session name, the right side, each window's number and padding, and the
# separators leave; give every window an equal share of it; hand back what a
# short name does not use to the names that are cut, and repeat. That ends
# with every cut name at one shared length, plus one more character for the
# first few cut windows, so the list fills the line exactly. When even
# @radar-win-min characters per window do not fit, only windows with an
# unread radar mark (@radar-color) keep a name, shared out the same way, and
# the room they leave goes to the current window's name. A name shows at
# least @radar-win-min characters or none: a two-letter stub says nothing
# the coloured number does not. When the marked windows cannot all have that
# much, the most urgent keep theirs: approvals, then notices, then finished
# turns, in window order within a level.
#
# The share depends on each client's width, and two clients of one session
# can differ, so radar does not compute a length. It publishes, per window,
# the cut points: a format (@radar-wname) that compares the room this client
# has (@radar-win-avail, measured by tmux at draw time) with the thresholds
# where this window gains a character, and truncates accordingly. tmux runs
# it on every redraw; radar reruns `publish` when windows come, go, are
# renamed or reordered, and when the set of marked windows changes.
#
# The room counts status-left and status-right as tmux draws them: the
# session's own values, expanded with the current window (a pane title on the
# right is the current pane's, not the drawn window's), but from copies without
# their #(command) jobs. tmux keys a job by the format it runs in, so measuring
# a side with its job starts the job a second time at every redraw, in the
# same instant as the status line's own run: tmux-continuum's auto-save would
# race itself. A job's output counts as zero width; @radar-win-reserve keeps
# columns for jobs that print text. Each publish refreshes the copies.
#
#   patch    at plugin load: point the theme's window formats at the fitted
#            name, record what each window costs without its name, and set
#            the room formula. Leaves the theme's formats in place (undoing
#            an earlier patch), and says why in @radar-win-fit-state, when it
#            cannot find exactly one window name in each format.
#   publish  recompute every window's @radar-wname; writes only changes.
#            One runs at a time; one that arrives meanwhile reruns it once.
#   off      undo patch.
#
# A window name is a stand-alone #W or #{window_name} outside any #{...}.
# catppuccin copies its window text into the formats when it loads and shows
# the pane title by default; set @catppuccin_window_text and
# @catppuccin_window_current_text to ' #W'. Its number colour is copied in
# the same way, so `patch` also points it at @radar-color.
set -euo pipefail

TOKEN='#{E:@radar-wname}'
COLOUR='#{?#{@radar-color},#{@radar-color},'
# Each window's cut points grow with its name length and with the number of
# marked windows. tmux takes a command line of at most 16 KB, so a name is
# fitted over its first 32 cells (a longer one shows those at most), a narrow
# client names at most the 4 most urgent marked windows (more would not fit
# there anyway), and the updates go to tmux in pieces.
CAP=32
TOP=4
CHUNK=12000
# Drawing costs grow with the square of a session's windows (each window's
# search measures them all): about 0.5 ms a redraw at 10 windows, 3 ms at 30,
# 9 ms at 60. Past 30 even the numbers and padding fill a wide screen, so
# radar leaves those sessions' names whole, as the theme draws them.
MAXWIN=30
STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
LOCK="$STATE_DIR/.winfit.lock"
AGAIN="$STATE_DIR/.winfit.again"

opt() { tmux show-option -gqv "$1" 2>/dev/null || true; }
# A value for a tmux command line: one ending in ";" would read as a command
# separator and lose it.
val() { case "$1" in *';') printf '%s\\;' "${1%;}" ;; *) printf '%s' "$1" ;; esac; }

# Scan a format for stand-alone window names. Prints
# <hits> \001 <format with each name replaced by TOKEN> \001 <format without it>
# A name already replaced counts as a hit, so patching twice is harmless.
# ##, #, and #} are escapes; a #(command) is copied whole, never searched.
scan() {  # scan <format>
  F="$1" T="$TOKEN" LC_ALL=C awk 'BEGIN {
    f = ENVIRON["F"]; t = ENVIRON["T"]; n = length(f); i = 1; d = 0; hits = 0
    out = ""; shell = ""
    while (i <= n) {
      c = substr(f, i, 2)
      if (c == "##" || c == "#," || c == "#}") { out = out c; shell = shell c; i += 2; continue }
      if (c == "#(") {
        p = 1; j = i + 2
        while (j <= n && p > 0) { ch = substr(f, j, 1); if (ch == "(") p++; else if (ch == ")") p--; j++ }
        out = out substr(f, i, j - i); shell = shell substr(f, i, j - i); i = j; continue
      }
      if (d == 0 && substr(f, i, length(t)) == t) { hits++; out = out t; i += length(t); continue }
      if (d == 0 && substr(f, i, 14) == "#{window_name}") { hits++; out = out t; i += 14; continue }
      if (d == 0 && c == "#W") { hits++; out = out t; i += 2; continue }
      if (c == "#{") { d++; out = out c; shell = shell c; i += 2; continue }
      ch = substr(f, i, 1)
      if (ch == "}" && d > 0) d--
      out = out ch; shell = shell ch; i++
    }
    printf "%d\001%s\001%s", hits, out, shell
  }'
}

# A status side without its #(command) jobs, for measuring.
nojobs() {  # nojobs <format>
  F="$1" LC_ALL=C awk 'BEGIN {
    f = ENVIRON["F"]; n = length(f); i = 1; out = ""
    while (i <= n) {
      c = substr(f, i, 2)
      if (c == "##") { out = out c; i += 2; continue }
      if (c == "#(") {
        p = 1; j = i + 2
        while (j <= n && p > 0) { ch = substr(f, j, 1); if (ch == "(") p++; else if (ch == ")") p--; j++ }
        i = j; continue
      }
      out = out substr(f, i, 1); i++
    }
    printf "%s", out
  }'
}

# catppuccin: the number colour is copied into the format as bg=<value>;
# make it the window's radar colour when it has one.
ctp_colour() {  # ctp_colour <format>  -> the format, coloured when possible
  local v
  v="$(opt @catppuccin_window_number_color)"
  case "$1" in *'@radar-color'*) printf '%s' "$1"; return ;; esac
  if [ -z "$v" ]; then printf '%s' "$1"; return; fi
  F="$1" V="bg=$v" R="bg=$COLOUR$v}" LC_ALL=C awk 'BEGIN {
    f = ENVIRON["F"]; v = ENVIRON["V"]; r = ENVIRON["R"]
    p = index(f, v)
    if (p == 0 || index(substr(f, p + length(v)), v) > 0) { printf "%s", f; exit }
    printf "%s%s%s", substr(f, 1, p - 1), r, substr(f, p + length(v))
  }'
}

# Undo ctp_colour: bg=#{?#{@radar-color},#{@radar-color},<value>} -> bg=<value>
ctp_uncolour() {  # ctp_uncolour <format>
  F="$1" P="bg=$COLOUR" LC_ALL=C awk 'BEGIN {
    f = ENVIRON["F"]; pre = ENVIRON["P"]
    p = index(f, pre)
    if (p == 0) { printf "%s", f; exit }
    i = p + length(pre); d = 1; n = length(f)
    for (j = i; j <= n && d > 0; j++) {
      c = substr(f, j, 2)
      if (c == "#{") { d++; j++; continue }
      if (substr(f, j, 1) == "}") d--
    }
    printf "%sbg=%s%s", substr(f, 1, p - 1), substr(f, i, j - 1 - i), substr(f, j)
  }'
}

# The room for names on this client: its width less every window's format
# without its name, status-left and status-right (the job-free copies,
# expanded with the current window, where tmux draws the sides), the
# separators and @radar-win-reserve. One loop over the windows measures all of
# it, at draw time. A side longer than its status-*-length is clipped by tmux,
# which only leaves room unused.
AVAIL='#{e|-:#{client_width},#{e|+:#{w:#{W:#{T:@radar-win-shell},#{T:@radar-win-shell-current}#{T:@radar-win-left}#{T:@radar-win-right}}},#{e|+:#{e|*:#{w:#{T:window-status-separator}},#{e|-:#{session_windows},1}},#{?#{@radar-win-reserve},#{@radar-win-reserve},0}}}}'

state() { tmux set-option -g @radar-win-fit-state "$1" 2>/dev/null || true; }

# Put the plain name and colour back and drop radar's options.
unpatch() {
  local f v w
  for f in window-status-format window-status-current-format; do
    v="$(tmux show-option -gwv "$f" 2>/dev/null || true)"
    case "$v" in *"$TOKEN"*|*"bg=$COLOUR"*)
      v="${v//"$TOKEN"/#W}"
      v="$(ctp_uncolour "$v")"
      tmux set-option -gw "$f" "$(val "$v")" 2>/dev/null || true ;;
    esac
  done
  tmux set-option -gu @radar-win-shell \; set-option -gu @radar-win-shell-current \; \
       set-option -gu @radar-win-left \; set-option -gu @radar-win-right \; \
       set-option -gu @radar-win-avail 2>/dev/null || true
  for w in $(tmux list-sessions -F '#{session_id}' 2>/dev/null || true); do
    tmux set-option -qu -t "$w" @radar-win-left \; set-option -qu -t "$w" @radar-win-right 2>/dev/null || true
  done
  # every window: the option's value is format text, which #{?...} cannot test
  local -a args=()
  while IFS= read -r w; do
    [ -n "$w" ] || continue
    [ "${#args[@]}" -eq 0 ] || args+=(";")
    args+=(set-option -wqu -t "$w" @radar-wname)
  done <<< "$(tmux list-windows -a -F '#{window_id}' 2>/dev/null || true)"
  [ "${#args[@]}" -eq 0 ] || tmux "${args[@]}" >/dev/null 2>&1 || true
}

# The job-free copies of the sides: global ones, and a session's own where it
# sets its own status-left or status-right. Writes only what changed.
sides() {
  local gl gr sid own side copy want have
  gl="$(opt status-left)"; gr="$(opt status-right)"
  local -a args=()
  want="$(nojobs "$gl")"; [ "$(opt @radar-win-left)" = "$want" ] || args+=(set-option -g @radar-win-left "$(val "$want")" ";")
  want="$(nojobs "$gr")"; [ "$(opt @radar-win-right)" = "$want" ] || args+=(set-option -g @radar-win-right "$(val "$want")" ";")
  for sid in $(tmux list-sessions -F '#{session_id}' 2>/dev/null || true); do
    # the options this session sets itself, by name (show-option prints
    # nothing at all for one it inherits)
    own=" $(tmux show-options -t "$sid" 2>/dev/null | awk '{ printf "%s ", $1 }')"
    for side in left right; do
      copy="@radar-win-$side"
      case "$own" in
        *" status-$side "*)
          want="$(nojobs "$(tmux show-option -qv -t "$sid" "status-$side" 2>/dev/null || true)")"
          have="$(tmux show-option -qv -t "$sid" "$copy" 2>/dev/null || true)"
          [ "$have" = "$want" ] || args+=(set-option -t "$sid" "$copy" "$(val "$want")" ";") ;;
        *" $copy "*) args+=(set-option -u -t "$sid" "$copy" ";") ;;
      esac
    done
  done
  [ "${#args[@]}" -gt 0 ] || return 0
  unset "args[$((${#args[@]} - 1))]"            # the trailing ";"
  tmux "${args[@]}" >/dev/null 2>&1 || true
}

skip() {  # skip <reason>
  unpatch
  state "skipped: $1"
}

cmd_patch() {
  local fmt cur sf a b
  fmt="$(tmux show-option -gwv window-status-format 2>/dev/null || true)"
  cur="$(tmux show-option -gwv window-status-current-format 2>/dev/null || true)"
  sf="$(tmux show-option -gv 'status-format[0]' 2>/dev/null || true)"
  # the room formula assumes the default first status line
  case "$sf" in *status-left*status-right*) ;; *)
    skip "status-format[0] is customised"; return 0 ;; esac
  # a side that lists the windows would measure the window list from inside it
  case "$(opt status-left)$(opt status-right)" in *'#{W:'*)
    skip "status-left or status-right lists the windows"; return 0 ;; esac
  fmt="$(ctp_colour "$fmt")"
  a="$(scan "$fmt")"; b="$(scan "$cur")"
  if [ "${a%%$'\001'*}" != 1 ] || [ "${b%%$'\001'*}" != 1 ]; then
    skip "no single #W or #{window_name} in the window formats"
    return 0
  fi
  sides
  a="${a#*$'\001'}"; b="${b#*$'\001'}"
  tmux set-option -gw window-status-format "$(val "${a%%$'\001'*}")" \; \
       set-option -gw window-status-current-format "$(val "${b%%$'\001'*}")" \; \
       set-option -g @radar-win-shell "$(val "${a#*$'\001'}")" \; \
       set-option -g @radar-win-shell-current "$(val "${b#*$'\001'}")" \; \
       set-option -g @radar-win-avail "$AVAIL" \; \
       set-option -g @radar-win-fit-state on 2>/dev/null || true
}

cmd_off() {
  unpatch
  state off
}

publish_once() {
  local min plan id val size=0
  # a restore links window after window; restore-end publishes once
  [ "$(tmux display-message -p '#{@radar-win-fit-state}#{@radar-restoring}' 2>/dev/null || true)" = on ] || return 0
  sides
  min="$(opt @radar-win-min)"
  case "$min" in ''|*[!0-9]*) min=4 ;; esac
  local -a args=()
  plan="$(tmux list-windows -a -F '#{session_id}'$'\t''#{window_index}'$'\t''#{window_id}'$'\t''#{w:window_name}'$'\t''#{@radar-color}'$'\t''#{@radar-wname}' 2>/dev/null |
    sort -t $'\t' -k1,1 -k2,2n |
    awk -F '\t' -v M="$min" -v CAP="$CAP" -v TOP="$TOP" -v MAXWIN="$MAXWIN" -v A='#{E:@radar-win-avail}' '
      {
        s = $1
        if (!(s in k)) { k[s] = 0; order[++ns] = s }
        j = ++k[s]; wid[s, j] = $3; len[s, j] = ($4 + 0 > CAP ? CAP : $4 + 0)
        # urgency from the colour radar gave the window: approval, notice, finished
        urg[s, j] = ($5 == "colour208" ? 3 : ($5 == "colour220" ? 2 : ($5 != "" ? 1 : 0)))
        have[$3] = $6
      }
      # The set of windows sharing the room: all of them (top < 0), or the
      # <top> most urgent marked ones (rank[s, j] is 1 for the most urgent).
      function inset(s, j, top) { return (top < 0 || (rank[s, j] > 0 && rank[s, j] <= top)) }
      # The room the names take when window i gets c cells: every window of
      # the set capped at c-1, plus one for each window up to i that is long
      # enough for c. Window i gets the largest c whose total fits.
      function need(s, c, i, only,    j, t) {
        t = 0
        for (j = 1; j <= k[s]; j++) {
          if (!inset(s, j, only)) continue
          t += (len[s, j] < c - 1 ? len[s, j] : c - 1)
          if (j <= i && len[s, j] >= c) t++
        }
        return t
      }
      function leaf(c) { return (c <= 0 ? "" : "#{=" c ":window_name}") }
      # binary search over 0..hi, the answer known to lie in lo..hi
      function pick(s, i, lo, hi, only,    mid) {
        if (lo >= hi) return leaf(lo)
        mid = int((lo + hi + 1) / 2)
        return "#{?#{e|>=:" A "," need(s, mid, i, only) "}," pick(s, i, mid, hi, only) "," pick(s, i, lo, mid - 1, only) "}"
      }
      # the whole name first: on a wide client that is the only comparison
      function fit(s, i, only,    l) {
        l = len[s, i]
        if (l == 0) return ""
        return "#{?#{e|>=:" A "," need(s, l, i, only) "}," leaf(l) "," pick(s, i, 0, l - 1, only) "}"
      }
      # the current window on a narrow client: the room left after <base>
      # cells of marked names, if at least min(M, its length) of it is left
      function rest(s, i, base,    l, m) {
        l = len[s, i]
        if (l == 0) return ""
        m = (l < M ? l : M)
        return "#{?#{e|>=:" A "," base + m "}," upto(m, l, base) ",}"
      }
      function upto(lo, hi, base,    mid) {  # the largest c in lo..hi with base + c of room
        if (lo >= hi) return leaf(lo)
        mid = int((lo + hi + 1) / 2)
        return "#{?#{e|>=:" A "," base + mid "}," upto(mid, hi, base) "," upto(lo, mid - 1, base) "}"
      }
      END {
        for (q = 1; q <= ns; q++) for (j = 1; j <= k[order[q]]; j++)
          if (k[order[q]] > most[wid[order[q], j]]) most[wid[order[q], j]] = k[order[q]]
        for (q = 1; q <= ns; q++) {
          s = order[q]; wide = 0; nm = 0
          if (k[s] > MAXWIN) {
            for (i = 1; i <= k[s]; i++)
              if (k[s] >= most[wid[s, i]] && have[wid[s, i]] != "#W") { print wid[s, i] "\t#W"; have[wid[s, i]] = "#W" }
            continue
          }
          for (j = 1; j <= k[s]; j++) { wide += (len[s, j] < M ? len[s, j] : M); rank[s, j] = 0 }
          # marked windows by urgency, then window order; few[t] and full[t]
          # are what the t most urgent need at M cells each and in full
          for (u = 3; u >= 1; u--)
            for (j = 1; j <= k[s]; j++)
              if (urg[s, j] == u && nm < TOP) {
                rank[s, j] = ++nm
                few[nm] = few[nm - 1] + (len[s, j] < M ? len[s, j] : M)
                full[nm] = full[nm - 1] + len[s, j]
              }
          for (i = 1; i <= k[s]; i++) {
            # a window linked into several sessions has one option: the session
            # with the most windows decides, so in the others it only under-uses
            if (k[s] < most[wid[s, i]]) continue
            # narrow: the most urgent marked names that get M cells each, then
            # what they leave to the current window
            narrow = ""
            if (rank[s, i] > 0) {
              for (t = rank[s, i]; t <= nm; t++)
                narrow = "#{?#{e|>=:" A "," few[t] "}," fit(s, i, t) "," narrow "}"
            } else {
              narrow = rest(s, i, 0)
              for (t = 1; t <= nm; t++)
                narrow = "#{?#{e|>=:" A "," few[t] "}," rest(s, i, full[t]) "," narrow "}"
              narrow = "#{?window_active," narrow ",}"
            }
            v = "#{?#{e|>=:" A "," wide "}," fit(s, i, -1) "," narrow "}"
            if (length(v) > 15000) v = ""      # cannot be sent; the number stands alone
            if (v != have[wid[s, i]]) { print wid[s, i] "\t" v; have[wid[s, i]] = v }
          }
        }
      }' || true)"
  [ -n "$plan" ] || return 0
  while IFS=$'\t' read -r id val; do
    [ -n "$id" ] || continue
    if [ "${#args[@]}" -gt 0 ] && [ $((size + ${#val})) -gt "$CHUNK" ]; then
      tmux "${args[@]}" >/dev/null 2>&1 || true
      args=(); size=0
    fi
    [ "${#args[@]}" -eq 0 ] || args+=(";")
    if [ -n "$val" ]; then args+=(set-option -wq -t "$id" @radar-wname "$val")
    else args+=(set-option -wqu -t "$id" @radar-wname); fi
    size=$((size + ${#val} + 64))
  done <<< "$plan"
  [ "${#args[@]}" -eq 0 ] || tmux "${args[@]}" >/dev/null 2>&1 || true
}

# One publish at a time: two that overlap could each read the window list at a
# different moment, and the later write would win with stale thresholds. The
# publish runs under flock(1) (Linux) or lockf(1) (macOS): a kernel lock that
# dies with its holder, so a killed publish leaves nothing to reap. A publish
# that finds the lock held asks the holder to go again and leaves; the request
# is written before the lock is tried, so the holder cannot miss it.
cmd_publish() {
  local self rc busy
  self="${BASH_SOURCE[0]}"
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  # nowhere to keep a lock: publish anyway, unserialised
  if ! { : > "$AGAIN"; } 2>/dev/null; then publish_once || true; return 0; fi
  while [ -e "$AGAIN" ]; do
    rc=0; busy=200
    if command -v flock >/dev/null 2>&1; then
      flock -n -E 200 "$LOCK" "$self" publish-locked || rc=$?
    elif command -v lockf >/dev/null 2>&1; then
      busy=75                                   # EX_TEMPFAIL
      lockf -s -t 0 "$LOCK" "$self" publish-locked || rc=$?
    else
      rc=1
    fi
    [ "$rc" -ne "$busy" ] || return 0           # held: its holder goes again
    if [ "$rc" -ne 0 ]; then                    # no lock to be had: publish anyway
      "$self" publish-locked
      return 0
    fi
  done
}

case "${1:-}" in
  patch)   cmd_patch; cmd_publish ;;
  publish) cmd_publish ;;
  publish-locked) rm -f "$AGAIN"; publish_once || true ;;
  off)     cmd_off ;;
  *) echo "usage: radar-winfit.sh patch|publish|off" >&2; exit 2 ;;
esac

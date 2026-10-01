#!/usr/bin/env bash
# Render the AI-status chip strip (pure: reads state, prints chips, changes
# nothing). The notifier's _sync_bar publishes this output into the
# @radar-chips tmux option, which the status line embeds via #{E:@radar-chips}
# — inside the user's status-right (`auto`) or on a pinned line 2 (`pinned`).
#
# Reads the need-input state file (see needinput-notify.sh for the format) and
# prints one styled chip per window (or per project, for paneless background
# marks) holding live marks whose pane is NOT currently on screen: the most
# urgent level of the window, and a count when it holds more than one mark.
# Approvals come first, then newest first; at most $MAX chips, then a "+N"
# for the windows left out. Chips are deliberately terse — `⚠ billing-api`,
# never the full sentence — because they share one line with the window list;
# the picker (Inbox/Agents) carries the long form.
#
# A chip leaves the bar after its level's lifetime in @radar-bar-ttl: one
# number for every level, or words such as `action=0 done=600 notice=600`
# (seconds; 0 keeps the chip until the mark is handled, a level left out keeps
# its default). The mark itself stays in the picker and the pane title.
#
# On tmux 3.4 and later each chip is a status range of type user named
# radar<pane number> (radar- for a paneless chip or "+N"), so a click on it can
# jump there (@radar-click, needinput-notify.sh click). `render auto` then
# reopens the right range after the strip, which sits inside status-right.
#
# `fresh <max-age>` prints, as plain data for the notifier's toast and notify
# command, the marks written in the last <max-age> seconds, oldest first:
#   <epoch><TAB><level><TAB><where><TAB><label><TAB><pane><TAB><key><TAB><source>
# <where> is the window name (session:index when unnamed), or the project of a
# paneless mark, whose label is then read without its "Agent·project: " prefix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=radar-level.sh
. "$SCRIPT_DIR/radar-level.sh"
STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
STATE_FILE="${TMUX_RADAR_NEEDINPUT_FILE:-${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}}"
MAX="${TMUX_RADAR_BAR_MAX:-${TMUX_SWITCHER_BAR_MAX:-3}}"

opt() {  # opt <option> <default>
  local key="$1" def="$2" v legacy
  v="$(tmux show-option -gqv "$key" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; return; fi
  case "$key" in
    @radar-*)
      legacy="@switcher-${key#@radar-}"
      v="$(tmux show-option -gqv "$legacy" 2>/dev/null || true)"
      ;;
  esac
  if [ -n "${v:-}" ]; then printf '%s' "$v"; else printf '%s' "$def"; fi
}

# Records joined with \001 (BSD awk rejects newlines in -v values).
pane_map() {
  tmux list-panes -a -F \
    '#{pane_id}'$'\t''#{&&:#{pane_active},#{&&:#{window_active},#{!=:#{session_attached},0}}}'$'\t''#{session_name}:#{window_index}'$'\t''#{window_name}'$'\t''#{window_id}' 2>/dev/null |
    tr '\n' '\001' || true
}

case "${1:-render}" in
  render|publish)  # render [auto|pinned] | publish [auto|pinned]
    what="$1"
    [ -r "$STATE_FILE" ] || exit 0
    click=0
    if [ "$(opt @radar-click on)" != off ]; then
      v="$(tmux -V 2>/dev/null || true)"; v="${v#tmux }"; v="${v#next-}"
      case "$v" in
        master*) click=1 ;;
        [0-9]*.[0-9]*)
          maj="${v%%.*}"; min="${v#*.}"; min="${min%%[!0-9]*}"
          if [ "$maj" -gt 3 ] || { [ "$maj" -eq 3 ] && [ "${min:-0}" -ge 4 ]; }; then click=1; fi
          ;;
      esac
    fi
    out="$(awk -F '\t' -v max="$MAX" -v panes="$(pane_map)" -v now="$(date +%s)" \
          -v ttls="$(opt @radar-bar-ttl 'action=0 done=600 notice=600')" \
          -v click="$click" -v mode="${2:-auto}" -v what="$what" "$RADAR_LEVEL_AWK"'
      function icon_for(level) {
        return (level == "action" ? "⚠" : (level == "done" ? "✓" : "!"))
      }
      function style_for(level) {
        return (level == "action" ? "#[fg=colour234,bg=colour208,bold]" : (level == "done" ? "#[fg=colour234,bg=colour35,bold]" : "#[fg=colour234,bg=colour220,bold]"))
      }
      function rank_of(level) { return (level == "action" ? 3 : (level == "notice" ? 2 : 1)) }
      function colour_for(level) { return (level == "action" ? "colour208" : (level == "done" ? "colour35" : "colour220")) }
      function target(pane) { return (pane == "-" ? "-" : substr(pane, 2)) }
      # Terse chip identity. Pane marks: the user-named window (fallback
      # session:window). Paneless bg marks ("Claude·proj: text"): the project.
      # The strip is expanded as a tmux format (#{E:@radar-chips}), so a "#"
      # in a window or directory name would be read as one: "#(cmd)" runs cmd.
      # The status line also runs through strftime, which eats a "%". Doubling
      # both makes tmux print the character instead.
      function literal(s) { gsub(/#/, "##", s); gsub(/%/, "%%", s); return s }
      function chip_text(label, pane,    s) {
        if (pane != "-") {
          s = wname[pane]
          if (s == "") s = where[pane]
          return literal(s)
        }
        s = label
        sub(/^[A-Za-z]+·/, "", s)      # strip "Claude·" / "Codex·" source prefix
        sub(/:.*/, "", s)              # drop the ": detail" tail
        if (s == "" || s == label) s = label
        return literal(s)
      }
      BEGIN {
        ttl["action"] = 0; ttl["done"] = 600; ttl["notice"] = 600
        if (ttls ~ /^[0-9]+$/) ttl["action"] = ttl["done"] = ttl["notice"] = ttls + 0
        else {
          n = split(ttls, w, /[[:space:],]+/)
          for (i = 1; i <= n; i++)
            if (w[i] ~ /^(action|done|notice)=[0-9]+$/) { split(w[i], kv, "="); ttl[kv[1]] = kv[2] + 0 }
        }
        n = split(panes, pl, "\001")
        for (i = 1; i <= n; i++) {
          split(pl[i], f, "\t")
          if (f[1] == "") continue
          alive[f[1]] = 1
          if (f[2] == 1) viewed[f[1]] = 1
          where[f[1]] = f[3]
          wname[f[1]] = f[4]
          wid[f[1]] = f[5]
        }
      }
      NF >= 4 {
        pane = $1
        label = (NF >= 5 ? $5 : $4)
        level = radar_level($3, label)
        if (ttl[level] > 0 && now - $2 > ttl[level]) next
        if (pane != "-" && (!(pane in alive) || (pane in viewed))) next
        # a window is its session:index, whatever it is called (two windows
        # named claude are two chips); a paneless mark is its project
        t = chip_text(label, pane)
        id = (pane != "-" ? where[pane] : "-" t)
        if (!(id in gi)) { gi[id] = ++g; gtext[g] = t; grank[g] = 0; gcount[g] = 0; gnew[g] = 0; gat[g] = 0 }
        k = gi[id]; r = rank_of(level); at = $2 + 0
        gcount[k]++
        if (at > gnew[k]) gnew[k] = at
        # the chip shows, and a click goes to, the newest of its most urgent marks
        if (r > grank[k] || (r == grank[k] && at >= gat[k])) { grank[k] = r; glevel[k] = level; gpane[k] = pane; gat[k] = at }
        # the counts for narrow screens, and the colour each window carries
        lcount[level]++
        if (at >= lat[level]) { lat[level] = at; lpane[level] = pane }
        if (pane != "-" && wid[pane] != "" && r > wrank[wid[pane]]) { wrank[wid[pane]] = r; wlevel[wid[pane]] = level }
      }
      END {
        for (i = 1; i <= g; i++) {
          x = i; j = i
          while (j > 1 && (grank[ord[j-1]] < grank[x] || (grank[ord[j-1]] == grank[x] && gnew[ord[j-1]] < gnew[x]))) { ord[j] = ord[j-1]; j-- }
          ord[j] = x
        }
        full = ""; shown = 0
        for (i = 1; i <= g && shown < max; i++) {
          k = ord[i]
          if (shown) full = full " "
          if (click) full = full "#[range=user|radar" target(gpane[k]) "]"
          full = full style_for(glevel[k]) " " icon_for(glevel[k]) " " gtext[k] (gcount[k] > 1 ? " ×" gcount[k] : "") " #[default]"
          if (click) full = full "#[norange]"
          shown++
        }
        if (g > max) {
          full = full " "
          if (click) full = full "#[range=user|radar-]"
          full = full "#[fg=colour244]+" (g - max) "#[default]"
          if (click) full = full "#[norange]"
        }
        if (click && shown && mode == "auto") full = full "#[range=right]"
        if (what == "render") { printf "%s", full; exit }
        # Narrow screens: one count per level, most urgent first. A count of
        # one goes to its pane; a larger one opens the picker to choose.
        short = ""; nl = split("action notice done", lv, " ")
        for (i = 1; i <= nl; i++) {
          l = lv[i]
          if (!(l in lcount)) continue
          if (short != "") short = short " "
          if (click) short = short "#[range=user|radar" (lcount[l] == 1 ? target(lpane[l]) : "-") "]"
          short = short "#[fg=" colour_for(l) ",bold]" icon_for(l) lcount[l] "#[default]"
          if (click) short = short "#[norange]"
        }
        if (click && short != "" && mode == "auto") short = short "#[range=right]"
        printf "%s\n%s\n", full, short
        for (win in wlevel) printf "W\t%s\t%s\n", win, colour_for(wlevel[win])
      }' "$STATE_FILE" 2>/dev/null || true)"
    printf '%s' "$out"
    ;;
  fresh)
    max_age="${2:-30}"
    case "$max_age" in ''|*[!0-9]*) max_age=30 ;; esac
    [ -r "$STATE_FILE" ] || exit 0
    awk -F '\t' -v OFS='\t' -v panes="$(pane_map)" -v now="$(date +%s)" -v maxage="$max_age" \
        "$RADAR_LEVEL_AWK"'
      # "Claude·proj: finished: x" reads "Claude finished: x" beside its project
      function plain_label(label,    agent, rest) {
        if (label !~ /^[A-Za-z]+·[^:]*: /) return label
        agent = label; sub(/·.*/, "", agent)
        rest = label; sub(/^[A-Za-z]+·[^:]*: /, "", rest)
        if (index(tolower(rest), tolower(agent) " ") == 1) return rest
        return agent " " rest
      }
      function project(label,    s) {
        s = label
        sub(/^[A-Za-z]+·/, "", s); sub(/:.*/, "", s)
        return (s == "" || s == label) ? "background" : s
      }
      BEGIN {
        n = split(panes, pl, "\001")
        for (i = 1; i <= n; i++) {
          split(pl[i], f, "\t")
          if (f[1] == "") continue
          alive[f[1]] = 1
          where[f[1]] = (f[4] != "" ? f[4] : f[3])
        }
      }
      NF >= 5 && now - $2 <= maxage {
        pane = $1
        if (pane == "-") { print $2, radar_level($3, $5), project($5), plain_label($5), pane, $4, $3; next }
        if (!(pane in alive)) next
        print $2, radar_level($3, $5), where[pane], $5, pane, $4, $3
      }' "$STATE_FILE" 2>/dev/null || true
    ;;
  prune)  # legacy no-op kept for compatibility; state GC lives in the notifier
    exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/needinput-notify.sh" tick
    ;;
  *)
    echo "usage: needinput-toast.sh [render [auto|pinned]|fresh [max-age]|prune]" >&2; exit 2 ;;
esac

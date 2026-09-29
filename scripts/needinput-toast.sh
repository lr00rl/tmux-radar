#!/usr/bin/env bash
# Render the AI-status chip strip (pure: reads state, prints chips, changes
# nothing). The notifier's _sync_bar publishes this output into the
# @radar-chips tmux option, which the status line embeds via #{E:@radar-chips}
# — inside the user's status-right (`auto`) or on a pinned line 2 (`pinned`).
#
# Reads the need-input state file (see needinput-notify.sh for the format) and
# prints one styled chip per live mark whose pane is NOT currently on screen
# (paneless background marks always show), newest first, capped at $MAX with a
# "+N" overflow counter. Chips are deliberately terse — `⚠ billing-api`, never
# the full sentence — because they share one line with the window list; the
# picker (Inbox/Agents) carries the long form.
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
    '#{pane_id}'$'\t''#{&&:#{pane_active},#{&&:#{window_active},#{!=:#{session_attached},0}}}'$'\t''#{session_name}:#{window_index}'$'\t''#{window_name}' 2>/dev/null |
    tr '\n' '\001' || true
}

case "${1:-render}" in
  render)
    [ -r "$STATE_FILE" ] || exit 0
    # chips fade from the bar after @radar-bar-ttl seconds (0 = persistent);
    # the underlying mark stays in the AI status view until handled
    out="$(awk -F '\t' -v max="$MAX" -v panes="$(pane_map)" \
          -v now="$(date +%s)" -v barttl="$(opt @radar-bar-ttl 60)" "$RADAR_LEVEL_AWK"'
      function icon_for(level) {
        return (level == "action" ? "⚠" : (level == "done" ? "✓" : "!"))
      }
      function style_for(level) {
        return (level == "action" ? "#[fg=colour234,bg=colour208,bold]" : (level == "done" ? "#[fg=colour234,bg=colour35,bold]" : "#[fg=colour234,bg=colour220,bold]"))
      }
      # Terse chip identity. Pane marks: the user-named window (fallback
      # session:window). Paneless bg marks ("Claude·proj: text"): the project.
      # The strip is expanded as a tmux format (#{E:@radar-chips}), so a "#"
      # in a window or directory name would be read as one: "#(cmd)" runs cmd.
      # Doubling it makes tmux print the character instead.
      function literal(s) { gsub(/#/, "##", s); return s }
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
        n = split(panes, pl, "\001")
        for (i = 1; i <= n; i++) {
          split(pl[i], f, "\t")
          if (f[1] == "") continue
          alive[f[1]] = 1
          if (f[2] == 1) viewed[f[1]] = 1
          where[f[1]] = f[3]
          wname[f[1]] = f[4]
        }
      }
      NF >= 4 {
        pane = $1
        label = (NF >= 5 ? $5 : $4)
        level = radar_level($3, label)
        if (barttl + 0 > 0 && now - $2 > barttl + 0) next
        if (pane == "-") { txt[++c] = chip_text(label, pane); lv[c] = level; next }
        if (!(pane in alive) || (pane in viewed)) next
        txt[++c] = chip_text(label, pane)
        lv[c] = level
      }
      END {
        shown = 0
        for (i = c; i >= 1 && shown < max; i--) {
          printf "%s%s %s %s #[default]", (shown ? " " : ""), style_for(lv[i]), icon_for(lv[i]), txt[i]
          shown++
        }
        if (c > max) printf " #[fg=colour244]+%d#[default]", c - max
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
    echo "usage: needinput-toast.sh [render|fresh [max-age]|prune]" >&2; exit 2 ;;
esac

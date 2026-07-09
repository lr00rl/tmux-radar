#!/usr/bin/env bash
# Render the persistent AI-status bar for the tmux status line.
# (Filename kept for status-format compatibility; this used to render 3s toasts.)
#
# Reads the need-input state file (see needinput-notify.sh for the format) and
# prints one styled chip per live mark whose pane is NOT currently on screen
# (paneless background marks always show), newest first, capped at $MAX with a
# "+N" overflow counter. Embedded in status-format[1] via #(...); the notifier
# toggles `status 2` <-> `on` so this line only exists while a mark is visible.
#
# If everything visible got resolved without an event (e.g. the marked pane
# died), rendering finds nothing and flips the status line back itself.
set -euo pipefail

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
          -v now="$(date +%s)" -v barttl="$(opt @radar-bar-ttl 60)" '
      function level_for(src, label,    l) {
        l = tolower(src " " label)
        if (l ~ /(finished|your turn|turn complete|task complete|done|任务完成|完成)/) return "done"
        if (l ~ /(needs approval|needs your permission|needs input|waiting.*input|waiting on you|wait.*input|permission|approval|action required|approve|拿不准|需要你|需要.*许可|需要.*批准|等待.*输入)/) return "action"
        return "notice"
      }
      function icon_for(level) {
        return (level == "action" ? "⚠" : (level == "done" ? "✓" : "!"))
      }
      function style_for(level) {
        return (level == "action" ? "#[fg=colour234,bg=colour208,bold]" : (level == "done" ? "#[fg=colour234,bg=colour35,bold]" : "#[fg=colour234,bg=colour220,bold]"))
      }
      BEGIN {
        n = split(panes, pl, "\001")
        for (i = 1; i <= n; i++) {
          split(pl[i], f, "\t")
          if (f[1] == "") continue
          alive[f[1]] = 1
          if (f[2] == 1) viewed[f[1]] = 1
          where[f[1]] = f[3] " " f[4]
        }
      }
      NF >= 4 {
        pane = $1
        label = (NF >= 5 ? $5 : $4)
        level = level_for($3, label)
        if (barttl + 0 > 0 && now - $2 > barttl + 0) next
        if (pane == "-") { txt[++c] = label; lv[c] = level; next }
        if (!(pane in alive) || (pane in viewed)) next
        txt[++c] = label " · " where[pane]
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
    if [ -n "$out" ]; then
      printf '%s' "$out"
      # Self-heal: a chip whose agent TUI already closed only disappears via a
      # GC pass, so while the bar is visible run one in the background at most
      # every 30s (epoch stored IN the stamp file — stat flags aren't portable).
      stamp="$STATE_DIR/.gc-stamp"; now="$(date +%s)"; last=0
      read -r last < "$stamp" 2>/dev/null || true
      case "$last" in ''|*[!0-9]*) last=0 ;; esac
      if [ $((now - last)) -ge 30 ]; then
        printf '%s\n' "$now" > "$stamp" 2>/dev/null || true
        ("$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/needinput-notify.sh" tick >/dev/null 2>&1 &)
      fi
    else
      # nothing left to show: drop the extra status line (idempotent)
      tmux set -g status on >/dev/null 2>&1 || true
    fi
    ;;
  prune)  # legacy no-op kept for compatibility; state GC lives in the notifier
    exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/needinput-notify.sh" tick
    ;;
  *)
    echo "usage: needinput-toast.sh [render|prune]" >&2; exit 2 ;;
esac

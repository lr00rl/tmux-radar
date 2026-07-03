#!/usr/bin/env bash
# Render the persistent "needs input" bar for the tmux status line.
# (Filename kept for status-format compatibility; this used to render 3s toasts.)
#
# Reads the need-input state file (see needinput-notify.sh for the format) and
# prints one styled chip per live mark whose pane is NOT currently on screen
# (paneless background marks always show), newest first, capped at $MAX with a
# "+N" overflow counter. Embedded in status-format[1] via #(...); the notifier
# toggles `status 2` <-> `on` so this line only exists while something waits.
#
# If everything visible got resolved without an event (e.g. the marked pane
# died), rendering finds nothing and flips the status line back itself.
set -euo pipefail

STATE_DIR="${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}"
STATE_FILE="${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}"
MAX="${TMUX_SWITCHER_BAR_MAX:-3}"

opt() {  # opt <option> <default>
  local v; v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
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
    # chips fade from the bar after @switcher-bar-ttl seconds (0 = persistent);
    # the underlying mark stays in the need-input view until handled
    out="$(awk -F '\t' -v max="$MAX" -v panes="$(pane_map)" \
          -v now="$(date +%s)" -v barttl="$(opt @switcher-bar-ttl 60)" '
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
        if (barttl + 0 > 0 && now - $2 > barttl + 0) next
        if (pane == "-") { txt[++c] = label; next }
        if (!(pane in alive) || (pane in viewed)) next
        txt[++c] = label " · " where[pane]
      }
      END {
        shown = 0
        for (i = c; i >= 1 && shown < max; i--) {
          printf "%s#[fg=colour234,bg=colour208,bold] ⚠ %s #[default]", (shown ? " " : ""), txt[i]
          shown++
        }
        if (c > max) printf " #[fg=colour208]+%d#[default]", c - max
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

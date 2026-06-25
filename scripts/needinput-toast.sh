#!/usr/bin/env bash
# Render transient "needs input" toasts for the tmux status line.
#
# Toast store: $STATE_DIR/need-input-toasts
#   one toast per line, TAB-separated: "<expiry_epoch>\t<text>"
# `render` prints living toasts (newest first, capped), styled with tmux #[...]
# directives for embedding in status-format via #(...).
set -euo pipefail

STATE_DIR="${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}"
TOAST_FILE="${TMUX_SWITCHER_TOASTS:-$STATE_DIR/need-input-toasts}"
MAX="${TMUX_SWITCHER_TOAST_MAX:-3}"

now="$(date +%s)"

case "${1:-render}" in
  render)
    [ -r "$TOAST_FILE" ] || exit 0
    awk -F '\t' -v now="$now" -v max="$MAX" '
      ($1 + 0) > now { txt[++n] = $2 }
      END {
        if (n == 0) exit 0
        shown = 0
        for (i = n; i >= 1 && shown < max; i--) {
          printf "%s#[fg=colour234,bg=colour208,bold] %s #[default]", (shown ? " " : ""), txt[i]
          shown++
        }
        if (n > max) printf " #[fg=colour208]+%d#[default]", n - max
      }' "$TOAST_FILE"
    ;;
  prune)
    [ -r "$TOAST_FILE" ] || exit 0
    tmp="$(mktemp "${TOAST_FILE}.XXXXXX")"
    awk -F '\t' -v now="$now" '($1 + 0) > now' "$TOAST_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$TOAST_FILE"
    ;;
  *)
    echo "usage: needinput-toast.sh [render|prune]" >&2; exit 2 ;;
esac

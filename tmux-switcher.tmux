#!/usr/bin/env bash
# tmux-switcher — TPM entry point.
# Sets up the picker key binding, MRU recording, and (optionally) the
# need-input toast status line. All behaviour is configurable via @switcher-*
# options set BEFORE this plugin is loaded.
set -eu

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$CURRENT_DIR/scripts"

opt() {  # opt <option-name> <default>
  local v
  v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

KEY="$(opt @switcher-key C-w)"
POPUP_W="$(opt @switcher-popup-width 100%)"
POPUP_H="$(opt @switcher-popup-height 100%)"
NEEDINPUT="$(opt @switcher-needinput on)"

# Picker binding (display-popup runs the script fresh each time, so option
# changes take effect immediately without rebinding).
tmux bind-key "$KEY" display-popup -E -w "$POPUP_W" -h "$POPUP_H" "$SCRIPTS/switcher.sh menu"

# Hooks are appended (-ga) so we don't clobber other hooks; guard against
# duplicate registration on config reload.
if [ "$(tmux show-option -gqv @switcher-hooked 2>/dev/null || true)" != "1" ]; then
  tmux set-hook -ga session-window-changed "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_window}'\""
  tmux set-hook -ga client-session-changed "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_session_name}:'\""
  if [ "$NEEDINPUT" = "on" ]; then
    tmux set-hook -ga session-window-changed "run-shell -b \"$SCRIPTS/needinput-notify.sh clear-window '#{hook_window}'\""
  fi
  tmux set-option -g @switcher-hooked 1
fi

# Transient toast line (revealed only while toasts are live; the notifier
# toggles `status 2` <-> `on`). Re-set each load (idempotent).
if [ "$NEEDINPUT" = "on" ]; then
  tmux set-option -g status-format[1] "#[align=right]#($SCRIPTS/needinput-toast.sh render) "
fi

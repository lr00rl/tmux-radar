#!/usr/bin/env bash
# tmux-radar — TPM entry point.
# Sets up the picker key binding, MRU recording, and (optionally) the
# AI-status bar. All behaviour is configurable via @radar-* options set BEFORE
# this plugin is loaded. Legacy @switcher-* options are still honored.
set -eu

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$CURRENT_DIR/scripts"

opt() {  # opt <option-name> <default>
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

KEY="$(opt @radar-key C-w)"
POPUP_W="$(opt @radar-popup-width 100%)"
POPUP_H="$(opt @radar-popup-height 100%)"
NEEDINPUT="$(opt @radar-needinput on)"

# Picker binding (display-popup runs the script fresh each time, so option
# changes take effect immediately without rebinding).
tmux bind-key "$KEY" display-popup -E -w "$POPUP_W" -h "$POPUP_H" "$SCRIPTS/switcher.sh menu"

# Global last-pane toggle: prefix + <@radar-last-key> (default Tab) jumps to
# the most recently used other pane across windows AND sessions (tmux's own
# last-pane only works inside one window). Set to `none` to skip binding.
LAST_KEY="$(opt @radar-last-key Tab)"
case "$LAST_KEY" in none|off|'') ;; *)
  tmux bind-key "$LAST_KEY" run-shell "$SCRIPTS/switcher.sh last-pane" ;;
esac

# Hooks use reserved high array indexes so reloads replace only tmux-radar's
# entries and never clobber another plugin or a user hook on the same event.
# The one-time migration removes only legacy entries whose command points at a
# tmux-radar-owned script.
HOOK_VERSION=4
_remove_legacy_hooks() {  # remove pre-v4 append slots owned by tmux-radar only
  local event="$1" scope="$2" line spec hooks
  if [ "$scope" = window ]; then
    hooks="$(tmux show-hooks -gw 2>/dev/null || true)"
  else
    hooks="$(tmux show-hooks -g 2>/dev/null || true)"
  fi
  while IFS= read -r line; do
    case "$line" in "$event"'['*) ;; *) continue ;; esac
    case "$line" in
      *"$SCRIPTS/mru-record.sh"*|*"$SCRIPTS/needinput-notify.sh"*)
        spec="${line%% *}"
        tmux set-hook -gu "$spec" 2>/dev/null || true
        ;;
    esac
  done <<< "$hooks"
}

if [ "$(tmux show-option -gqv @radar-hooked 2>/dev/null || true)" != "$HOOK_VERSION" ]; then
  _remove_legacy_hooks session-window-changed server
  _remove_legacy_hooks client-session-changed server
  _remove_legacy_hooks window-pane-changed window
fi

tmux set-hook -g 'session-window-changed[9000]' "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_window}'\""
tmux set-hook -g 'client-session-changed[9000]' "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_session_name}:'\""
# pane-level MRU: fires when the active pane changes inside a window
tmux set-hook -g 'window-pane-changed[9000]' "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_pane}'\""
if [ "$NEEDINPUT" = "on" ]; then
  # Read handling is pane-specific. Resolve session/window targets once to
  # their newly active pane; never consume unread sibling panes.
  tmux set-hook -g 'session-window-changed[9001]' "run-shell -b \"$SCRIPTS/needinput-notify.sh clear '#{hook_window}'\""
  tmux set-hook -g 'window-pane-changed[9001]' "run-shell -b \"$SCRIPTS/needinput-notify.sh clear '#{hook_pane}'\""
  tmux set-hook -g 'client-session-changed[9001]' "run-shell -b \"$SCRIPTS/needinput-notify.sh clear '#{hook_session_name}:'\""
  # Session switches change which panes are on screen -> resync the bar.
  tmux set-hook -g 'client-session-changed[9002]' "run-shell -b \"$SCRIPTS/needinput-notify.sh tick\""
else
  tmux set-hook -gu 'session-window-changed[9001]' 2>/dev/null || true
  tmux set-hook -gu 'window-pane-changed[9001]' 2>/dev/null || true
  tmux set-hook -gu 'client-session-changed[9001]' 2>/dev/null || true
  tmux set-hook -gu 'client-session-changed[9002]' 2>/dev/null || true
fi
tmux set-option -g @radar-hooked "$HOOK_VERSION"

# AI-status chips. The strip is pure option content (#{E:@radar-chips}) that
# the notifier republishes on every event, so a notification never changes the
# status line COUNT — toggling `status` resizes every pane and SIGWINCHes every
# full-screen app. @radar-bar: auto (default; chips render inline inside the
# existing status-right) | pinned (chips on a permanently reserved line 2) |
# off (track marks only).
if [ "$NEEDINPUT" = "on" ]; then
  tmux set-option -g @radar-chips "" 2>/dev/null || true
  case "$(opt @radar-bar auto)" in
    off) ;;
    pinned)
      BAR_STATUS="$(tmux show-option -gv status 2>/dev/null || echo on)"
      case "$BAR_STATUS" in
        2|[3-9]|[1-9][0-9]*) ;;
        *) tmux set-option -g status 2 ;;
      esac
      tmux set-option -g status-format[1] "#[align=right]#{E:@radar-chips}"
      ;;
    *)
      # inline: wrap the user's status-right once (config reload resets the
      # option to the user's raw value, so re-wrapping stays idempotent)
      CUR_RIGHT="$(tmux show-option -gv status-right 2>/dev/null || true)"
      case "$CUR_RIGHT" in
        *'@radar-chips'*) ;;
        *) tmux set-option -g status-right "#{E:@radar-chips}$CUR_RIGHT" ;;
      esac
      ;;
  esac
  # prune marks left over from a previous server / restore on every (re)load;
  # tick also republishes @radar-chips and heals a pre-inline raised bar
  tmux run-shell -b "$SCRIPTS/needinput-notify.sh tick" 2>/dev/null || true
fi

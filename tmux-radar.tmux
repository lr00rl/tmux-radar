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

# `|| true` is load-bearing: tmux prints `'cmd' returned 1` for a background
# run-shell whose command exits non-zero, even when stdout/stderr are redirected.
# Every focus hook names its pane as #{pane_id}: run in the hook's own target,
# that is the pane that just came into view (the new window's active pane, the
# window's new active pane, the client's new current pane). The hook_* formats
# are no use here: tmux 3.6 leaves #{hook_window} empty in
# session-window-changed, #{hook_pane} in window-pane-changed, and
# #{hook_session_name} in client-session-changed.
tmux set-hook -g 'session-window-changed[9000]' "run-shell -b \"$SCRIPTS/mru-record.sh '#{pane_id}' || true\""
tmux set-hook -g 'client-session-changed[9000]' "run-shell -b \"$SCRIPTS/mru-record.sh '#{pane_id}' || true\""
# pane-level MRU: fires when the active pane changes inside a window
tmux set-hook -g 'window-pane-changed[9000]' "run-shell -b \"$SCRIPTS/mru-record.sh '#{pane_id}' || true\""
if [ "$NEEDINPUT" = "on" ]; then
  # Read handling is pane-specific: clear the one pane that came into view,
  # never its unread siblings, and only while some client shows its window
  # (a script that switches windows in a detached session has read nothing;
  # a window linked into several sessions counts every client showing it).
  # `-` says "nobody": an empty argument would fall back to $TMUX_PANE.
  tmux set-hook -g 'session-window-changed[9001]' "run-shell -b \"$SCRIPTS/needinput-notify.sh clear '#{?window_active_clients,#{pane_id},-}' || true\""
  tmux set-hook -g 'window-pane-changed[9001]' "run-shell -b \"$SCRIPTS/needinput-notify.sh clear '#{?window_active_clients,#{pane_id},-}' || true\""
  tmux set-hook -g 'client-session-changed[9001]' "run-shell -b \"$SCRIPTS/needinput-notify.sh clear '#{?window_active_clients,#{pane_id},-}' || true\""
  # Session switches change which panes are on screen -> resync the bar.
  tmux set-hook -g 'client-session-changed[9002]' "run-shell -b \"$SCRIPTS/needinput-notify.sh hook-tick || true\""
else
  tmux set-hook -gu 'session-window-changed[9001]' 2>/dev/null || true
  tmux set-hook -gu 'window-pane-changed[9001]' 2>/dev/null || true
  tmux set-hook -gu 'client-session-changed[9001]' 2>/dev/null || true
  tmux set-hook -gu 'client-session-changed[9002]' 2>/dev/null || true
fi
tmux set-option -g @radar-hooked "$HOOK_VERSION"

# tmux-resurrect eval's these options. Restore is a bulk topology change:
# begin suppresses focus-clears and hook ticks; end schedules one quiet GC
# after the layout exists. A documented `tick` workaround is replaced; any
# other user hook is kept beside ours. Idempotent across plugin reloads.
_radar_compose_resurrect_hook() {
  local opt="$1" ours="$2" existing
  existing="$(tmux show-option -gqv "$opt" 2>/dev/null || true)"
  case "$existing" in
    "$ours"|*"needinput-notify.sh restore-"*) return 0 ;;
    *"needinput-notify.sh"*"tick"*) tmux set-option -g "$opt" "$ours" ;;
    '') tmux set-option -g "$opt" "$ours" ;;
    *) tmux set-option -g "$opt" "$ours; $existing" ;;
  esac
}
NOTIFY_Q="$(printf '%q' "$SCRIPTS/needinput-notify.sh")"
_radar_compose_resurrect_hook @resurrect-hook-pre-restore-all "$NOTIFY_Q restore-begin"
_radar_compose_resurrect_hook @resurrect-hook-post-restore-all "$NOTIFY_Q restore-end"

# AI-status chips. The strip is pure option content (#{E:@radar-chips}) that
# the notifier republishes on every event, so a notification never changes the
# status line COUNT — toggling `status` resizes every pane and SIGWINCHes every
# full-screen app. @radar-bar: auto (default; chips render inline inside the
# existing status-right) | pinned (chips on a permanently reserved line 2) |
# off (track marks only).
if [ "$NEEDINPUT" = "on" ]; then
  tmux set-option -g @radar-chips "" \; set-option -g @radar-chips-short "" 2>/dev/null || true
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
      # option to the user's raw value, so re-wrapping stays idempotent). A
      # client under 120 columns gets the counts instead of the chips.
      CUR_RIGHT="$(tmux show-option -gv status-right 2>/dev/null || true)"
      CHIPS_FMT='#{?#{e|<:#{client_width},120},#{E:@radar-chips-short},#{E:@radar-chips}}'
      case "$CUR_RIGHT" in
        *'@radar-chips-short'*) ;;
        # the wrapper of an earlier version, left by a reload of the plugin
        # without one of the config
        '#{E:@radar-chips}'*) tmux set-option -g status-right "$CHIPS_FMT${CUR_RIGHT#'#{E:@radar-chips}'}" ;;
        *'@radar-chips'*) ;;
        *) tmux set-option -g status-right "$CHIPS_FMT$CUR_RIGHT" ;;
      esac
      ;;
  esac
  # prune marks left over from a previous server / restore on every (re)load;
  # hook-tick also republishes @radar-chips and heals a pre-inline raised bar
  tmux run-shell -b "$SCRIPTS/needinput-notify.sh hook-tick || true" 2>/dev/null || true
fi

# Clicks: a chip or a floating toast jumps to its pane (needinput-notify.sh
# click / toast-click). The first mouse button's root bindings are wrapped,
# and what was bound there still runs for every other click: the original is
# kept in @radar-click-orig-<key> when first wrapped, so a reload wraps it
# again, never the wrapper. A pane click forks nothing unless a toast is up
# (@radar-toast-live). `@radar-click off` puts the originals back.
_radar_click_bound() {  # the command bound to <key> in the root table, as list-keys prints it
  tmux list-keys -T root "$1" 2>/dev/null | head -1 |
    sed -E 's/^bind-key +(-[rn] +)*-T +root +[^ ]+ +//'
}
_radar_click() {  # _radar_click on|off
  local want="$1" key cur orig conf notify else_part inner
  notify="$SCRIPTS/needinput-notify.sh"
  case "$notify" in *[\'\"\$\`\\]*) return 0 ;; esac   # cannot be quoted in a binding
  notify="${notify//\#/##}"                            # run-shell and if-shell expand formats
  conf="$(mktemp "${TMPDIR:-/tmp}/radar-click.XXXXXX")" || return 0
  for key in MouseDown1Status MouseDown1Pane; do
    cur="$(_radar_click_bound "$key")"
    case "$cur" in
      *needinput-notify.sh*) orig="$(tmux show-option -gqv "@radar-click-orig-$key" 2>/dev/null || true)" ;;
      *)
        [ "$want" = on ] || continue                   # not wrapped: nothing to undo
        orig="$cur"
        tmux set-option -g "@radar-click-orig-$key" "$orig"
        ;;
    esac
    if [ "$want" != on ]; then
      if [ -n "$orig" ]; then printf 'bind-key -T root %s %s\n' "$key" "$orig" >> "$conf"
      else printf 'unbind-key -T root %s\n' "$key" >> "$conf"; fi
      tmux set-option -gu "@radar-click-orig-$key" 2>/dev/null || true
      continue
    fi
    # list-keys separates commands with "\;"; inside braces that is a literal
    # semicolon, so the original goes in with plain separators
    inner="${orig// \\; / ; }"
    else_part=""
    [ -z "$orig" ] || else_part=" { $inner }"
    if [ "$key" = MouseDown1Status ]; then
      printf '%s\n' "bind-key -T root $key if-shell -F '#{m/r:^radar(-|[0-9]+)\$,#{mouse_status_range}}' { run-shell -b '\"$notify\" click #{q:client_name} #{q:mouse_status_range}' }$else_part" >> "$conf"
    else
      printf '%s\n' "bind-key -T root $key if-shell -F '#{@radar-toast-live}' { if-shell '\"$notify\" toast-click #{q:client_name} #{pane_left} #{pane_top} #{mouse_x} #{mouse_y} \"#{status}\" \"#{status-position}\" #{?window_bigger,#{window_offset_x},0} #{?window_bigger,#{window_offset_y},0}' {}$else_part }$else_part" >> "$conf"
    fi
  done
  [ ! -s "$conf" ] || tmux source-file "$conf" 2>/dev/null || true
  rm -f "$conf"
}
if [ "$NEEDINPUT" = "on" ] && [ "$(opt @radar-click on)" != off ]; then
  _radar_click on
else
  _radar_click off
fi

# Window names fitted to each client's width (radar-winfit.sh). Loaded after
# the theme, so the patch sees the window formats the theme built. tmux
# redraws from per-window cut points that radar republishes whenever windows
# come, go or are renamed (move-window links and unlinks), and on a session
# switch, which refreshes the measured copies of status-left and status-right;
# a client's width needs no republish. tmux has no hook for swap-window: a swap only changes
# which cut windows get the spare characters, never the total, and the next
# republish puts them back in order.
WINFIT_EVENTS="window-linked window-unlinked window-renamed client-session-changed"
if [ "$(opt @radar-win-fit on)" != off ]; then
  "$SCRIPTS/radar-winfit.sh" patch || true
  for ev in $WINFIT_EVENTS; do
    tmux set-hook -g "$ev[9003]" "run-shell -b \"$SCRIPTS/radar-winfit.sh publish || true\"" 2>/dev/null || true
  done
else
  "$SCRIPTS/radar-winfit.sh" off || true
  for ev in $WINFIT_EVENTS; do tmux set-hook -gu "$ev[9003]" 2>/dev/null || true; done
fi

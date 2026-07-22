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

# AI supervisor (Codex-driven), opt-in via `set -g @radar-ai on`. prefix +
# <@radar-ai-key> (default `A` — capital, so a stray prefix+a can't launch
# it by accident) opens a menu: arrange tmux from natural language,
# decide/answer a waiting AI pane, or run a resident watcher that auto-approves
# safe prompts until a pane's task is done. display-menu is bound natively
# (client context) rather than through the script for reliability; keep the
# items in sync with cmd_menu in scripts/ai.sh (the CLI fallback).
if [ "$(opt @radar-ai off)" = "on" ]; then
  AI_KEY="$(opt @radar-ai-key A)"
  POP="display-popup -E -w 80% -h 70%"
  tmux bind-key "$AI_KEY" display-menu -T "#[align=centre] tmux AI 主管 " -x C -y C \
    "指挥 tmux（自然语言）"            a "$POP \"TMUX_RADAR_AI_PAUSE=1 $SCRIPTS/ai.sh ask\"" \
    "让当前 pane 继续 / 决定一次"       c "$POP \"TMUX_RADAR_AI_PAUSE=1 $SCRIPTS/ai.sh decide '#{pane_id}'\"" \
    "" \
    "常驻监控当前 pane 直到完成"        w "run-shell \"$SCRIPTS/native-launcher.sh '#{pane_id}' quick\"" \
    "常驻监控 + always-allow（更省心）"  W "run-shell \"$SCRIPTS/native-launcher.sh '#{pane_id}' always-allow\"" \
    "自定义监控（目标 / 间隔 / 策略）…"  v "run-shell \"$SCRIPTS/native-launcher.sh '#{pane_id}' advanced\"" \
    "" \
    "状态 / 最近决策"                  s "$POP \"TMUX_RADAR_AI_PAUSE=1 $SCRIPTS/ai.sh status\"" \
    "停止全部监控"                     S "run-shell \"$SCRIPTS/ai.sh stop all\"" \
    "列出 AI pane"                    l "$POP \"TMUX_RADAR_AI_PAUSE=1 $SCRIPTS/ai.sh list\""
  # housekeeping on every (re)load: GC stale watcher files / monitor panes /
  # AI-status marks — also what a tmux-resurrect post-restore hook should run
  tmux run-shell -b "$SCRIPTS/ai.sh cleanup >/dev/null 2>&1" 2>/dev/null || true
fi

# Hooks are appended (-ga) so we don't clobber other hooks; a version guard
# avoids duplicate registration on config reload. On version bump we reset our
# events with -gu first (removes any hook on those events) and re-register.
HOOK_VERSION=3
if [ "$(tmux show-option -gqv @radar-hooked 2>/dev/null || true)" != "$HOOK_VERSION" ]; then
  tmux set-hook -gu session-window-changed 2>/dev/null || true
  tmux set-hook -gu client-session-changed 2>/dev/null || true
  tmux set-hook -gu window-pane-changed 2>/dev/null || true
  tmux set-hook -ga session-window-changed "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_window}'\""
  tmux set-hook -ga client-session-changed "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_session_name}:'\""
  # pane-level MRU: fires when the active pane changes inside a window
  tmux set-hook -ga window-pane-changed "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_pane}'\""
  if [ "$NEEDINPUT" = "on" ]; then
    tmux set-hook -ga session-window-changed "run-shell -b \"$SCRIPTS/needinput-notify.sh clear-window '#{hook_window}'\""
    # session switches change which panes are on screen -> resync the bar
    tmux set-hook -ga client-session-changed "run-shell -b \"$SCRIPTS/needinput-notify.sh tick\""
  fi
  tmux set-option -g @radar-hooked "$HOOK_VERSION"
fi

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

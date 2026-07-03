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

# AI supervisor (Codex-driven), opt-in via `set -g @switcher-ai on`. prefix +
# <@switcher-ai-key> (default `a`) opens a menu: arrange tmux from natural
# language, decide/answer a waiting AI pane, or run a resident watcher that
# auto-approves safe prompts until a pane's task is done. display-menu is bound
# natively (client context) rather than through the script for reliability.
if [ "$(opt @switcher-ai off)" = "on" ]; then
  AI_KEY="$(opt @switcher-ai-key a)"
  POP="display-popup -E -w 80% -h 70%"
  tmux bind-key "$AI_KEY" display-menu -T "#[align=centre] tmux AI 主管 " -x C -y C \
    "指挥 tmux（自然语言）"          a "$POP \"TMUX_SWITCHER_AI_PAUSE=1 $SCRIPTS/ai.sh ask\"" \
    "让当前 pane 继续 / 决定一次"     c "$POP \"TMUX_SWITCHER_AI_PAUSE=1 $SCRIPTS/ai.sh decide '#{pane_id}'\"" \
    "常驻监控当前 pane 直到完成"      w "run-shell \"$SCRIPTS/ai.sh watch '#{pane_id}'\"" \
    "常驻监控 + always-allow（更省心）" W "run-shell \"$SCRIPTS/ai.sh watch '#{pane_id}' '' always-allow\"" \
    "" \
    "查看 / 停止监控"               s "$POP \"TMUX_SWITCHER_AI_PAUSE=1 $SCRIPTS/ai.sh status\"" \
    "停止全部监控"                  S "run-shell \"$SCRIPTS/ai.sh stop all\"" \
    "列出所有 AI pane"              l "$POP \"TMUX_SWITCHER_AI_PAUSE=1 $SCRIPTS/ai.sh list\""
fi

# Hooks are appended (-ga) so we don't clobber other hooks; a version guard
# avoids duplicate registration on config reload. On version bump we reset our
# events with -gu first (removes any hook on those events) and re-register.
HOOK_VERSION=2
if [ "$(tmux show-option -gqv @switcher-hooked 2>/dev/null || true)" != "$HOOK_VERSION" ]; then
  tmux set-hook -gu session-window-changed 2>/dev/null || true
  tmux set-hook -gu client-session-changed 2>/dev/null || true
  tmux set-hook -ga session-window-changed "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_window}'\""
  tmux set-hook -ga client-session-changed "run-shell -b \"$SCRIPTS/mru-record.sh '#{hook_session_name}:'\""
  if [ "$NEEDINPUT" = "on" ]; then
    tmux set-hook -ga session-window-changed "run-shell -b \"$SCRIPTS/needinput-notify.sh clear-window '#{hook_window}'\""
    # session switches change which panes are on screen -> resync the bar
    tmux set-hook -ga client-session-changed "run-shell -b \"$SCRIPTS/needinput-notify.sh tick\""
  fi
  tmux set-option -g @switcher-hooked "$HOOK_VERSION"
fi

# Transient toast line (revealed only while toasts are live; the notifier
# toggles `status 2` <-> `on`). Re-set each load (idempotent).
if [ "$NEEDINPUT" = "on" ]; then
  tmux set-option -g status-format[1] "#[align=right]#($SCRIPTS/needinput-toast.sh render) "
fi

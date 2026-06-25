#!/usr/bin/env bash
# Install / uninstall the "needs input" hooks for Claude Code and Codex so they
# flag the tmux pane they run in (via $TMUX_PANE) when they wait on you.
#
# Edits, idempotently and with a timestamped backup:
#   ~/.claude/settings.json   (Claude hooks)
#   ~/.codex/config.toml      (Codex notify — wraps an existing chain, non-destructively)
#
# Usage: install-hooks.sh [install|uninstall|status]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${TMUX_SWITCHER_NOTIFY:-$SCRIPT_DIR/needinput-notify.sh}"
CODEX_WRAP="${TMUX_SWITCHER_CODEX_WRAP:-$SCRIPT_DIR/codex-notify-wrap.sh}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"

CLAUDE_EVENTS=(Notification Stop UserPromptSubmit SessionEnd)
CLAUDE_SUBCMDS=(claude-mark claude-stop claude-clear claude-clear)
CODEX_NOTIFY_JSON="[\"$NOTIFY\", \"codex\"]"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "  $*"; }
need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"; }

claude_install() {
  need_jq
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  jq empty "$CLAUDE_SETTINGS" 2>/dev/null || die "$CLAUDE_SETTINGS is not valid JSON"
  local i ev cmd tmp
  for i in "${!CLAUDE_EVENTS[@]}"; do
    ev="${CLAUDE_EVENTS[$i]}"; cmd="$NOTIFY ${CLAUDE_SUBCMDS[$i]}"; tmp="$(mktemp)"
    jq --arg ev "$ev" --arg cmd "$cmd" '
      .hooks //= {} | .hooks[$ev] //= []
      | if any(.hooks[$ev][]?; ((.hooks // [])[]?.command) == $cmd) then .
        else .hooks[$ev] += [ { "hooks": [ { "type": "command", "command": $cmd } ] } ] end
    ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    info "Claude $ev -> $cmd"
  done
}

claude_uninstall() {
  need_jq
  [ -f "$CLAUDE_SETTINGS" ] || { info "no $CLAUDE_SETTINGS"; return 0; }
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  local tmp; tmp="$(mktemp)"
  jq --arg p "$NOTIFY " '
    if .hooks then
      .hooks |= with_entries(
        .value |= ( map( .hooks |= map(select((.command // "") | startswith($p) | not)) )
                    | map(select((.hooks // []) | length > 0)) )
      ) | .hooks |= with_entries(select((.value | length) > 0))
    else . end
  ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
  info "removed Claude need-input hooks"
}

claude_status() {
  if command -v jq >/dev/null 2>&1 && [ -f "$CLAUDE_SETTINGS" ]; then
    local c; c="$(jq --arg p "$NOTIFY " '[.hooks // {} | .. | .command? // empty | select(startswith($p))] | length' "$CLAUDE_SETTINGS" 2>/dev/null || echo 0)"
    echo "Claude hooks installed: ${c:-0}/4"
  else echo "Claude settings: (none / jq missing)"; fi
}

codex_install() {
  mkdir -p "$(dirname "$CODEX_CONFIG")"
  if [ ! -f "$CODEX_CONFIG" ]; then
    printf 'notify = %s\n' "$CODEX_NOTIFY_JSON" > "$CODEX_CONFIG"
    info "Codex notify -> created $CODEX_CONFIG (direct)"; return 0
  fi
  cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  if grep -qF "$CODEX_WRAP" "$CODEX_CONFIG" || grep -qF "$NOTIFY" "$CODEX_CONFIG"; then
    info "Codex notify already integrated"; return 0
  fi
  if grep -qE '^[[:space:]]*notify[[:space:]]*=[[:space:]]*\[' "$CODEX_CONFIG"; then
    sed -i '' "s#^\([[:space:]]*notify[[:space:]]*=[[:space:]]*\[\)#\1\"$CODEX_WRAP\", #" "$CODEX_CONFIG"
    if grep -qF "$CODEX_WRAP" "$CODEX_CONFIG"; then info "Codex notify -> wrapped existing chain (preserved)"
    else echo "  WARNING: could not auto-wrap Codex notify (multi-line array?). Prepend \"$CODEX_WRAP\" manually." >&2; fi
  else
    printf '\nnotify = %s\n' "$CODEX_NOTIFY_JSON" >> "$CODEX_CONFIG"
    info "Codex notify -> appended (direct)"
  fi
}

codex_uninstall() {
  [ -f "$CODEX_CONFIG" ] || { info "no $CODEX_CONFIG"; return 0; }
  cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  if grep -qF "$CODEX_WRAP" "$CODEX_CONFIG"; then
    sed -i '' "s#\"$CODEX_WRAP\", ##" "$CODEX_CONFIG"; info "unwrapped Codex notify (restored chain)"
  elif grep -qF "$NOTIFY" "$CODEX_CONFIG"; then
    grep -vF "$NOTIFY" "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp" && mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"; info "removed direct Codex notify"
  else info "Codex notify not ours / absent"; fi
}

codex_status() {
  if [ -f "$CODEX_CONFIG" ] && { grep -qF "$CODEX_WRAP" "$CODEX_CONFIG" || grep -qF "$NOTIFY" "$CODEX_CONFIG"; }; then
    echo "Codex notify: installed"
  else echo "Codex notify: not installed"; fi
}

[ -x "$NOTIFY" ] || die "$NOTIFY not found/executable"

case "${1:-install}" in
  install)   echo "Installing tmux-switcher need-input hooks:"; claude_install; codex_install
             echo "Done. Restart Claude/Codex sessions (or open new ones) to pick up the hooks." ;;
  uninstall) echo "Uninstalling tmux-switcher need-input hooks:"; claude_uninstall; codex_uninstall ;;
  status)    claude_status; codex_status ;;
  *) die "usage: install-hooks.sh [install|uninstall|status]" ;;
esac

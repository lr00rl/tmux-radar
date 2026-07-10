#!/usr/bin/env bash
# Install / uninstall the AI-status hooks for Claude Code, Codex and opencode
# so they flag action-required prompts and finished-turn notices in tmux.
#
# Edits, idempotently and with a timestamped backup:
#   ~/.claude/settings.json                 (Claude hooks)
#   ~/.codex/config.toml                    (Codex hooks + legacy notify fallback)
#   ~/.config/opencode/plugins/tmux-radar.js (opencode plugin, path baked in)
#
# Usage: install-hooks.sh [install|uninstall|status]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${TMUX_RADAR_NOTIFY:-${TMUX_SWITCHER_NOTIFY:-$SCRIPT_DIR/needinput-notify.sh}}"
CODEX_WRAP="${TMUX_RADAR_CODEX_WRAP:-${TMUX_SWITCHER_CODEX_WRAP:-$SCRIPT_DIR/codex-notify-wrap.sh}}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
OPENCODE_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
OPENCODE_PLUGIN="$OPENCODE_DIR/plugins/tmux-radar.js"

# NOTE: SessionEnd IS hooked (claude-end), with selective semantics: it removes
# the session from the agent registry and clears its action/notice marks (a
# "needs your input" mark for a dead session is a lie), but KEEPS done-level
# "finished — your turn" marks. Short-lived / print-mode runs fire Stop then
# SessionEnd back-to-back, and their finished mark must survive that.
CLAUDE_EVENTS=(SessionStart Notification Stop UserPromptSubmit SessionEnd)
CLAUDE_SUBCMDS=(claude-register claude-mark claude-stop claude-clear claude-end)
CODEX_NOTIFY_JSON="[\"$NOTIFY\", \"codex\"]"
CODEX_HOOK_CMD="$NOTIFY codex-hook"
CODEX_HOOK_BEGIN="# BEGIN tmux-radar Codex hooks"
CODEX_HOOK_END="# END tmux-radar Codex hooks"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "  $*"; }
need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"; }

claude_install() {
  need_jq
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
  cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.bak.$(date +%Y%m%d%H%M%S)"
  jq empty "$CLAUDE_SETTINGS" 2>/dev/null || die "$CLAUDE_SETTINGS is not valid JSON"
  # Migration: older versions hooked SessionEnd -> claude-clear, which wiped the
  # "finished" mark the moment a session ended. Strip ONLY that legacy wiring
  # (exact command match) — a broad "$NOTIFY "-prefix strip would delete the
  # claude-end hook we install below on every reinstall.
  local mtmp; mtmp="$(mktemp)"
  jq --arg legacy "$NOTIFY claude-clear" '
    if (.hooks // {}).SessionEnd then
      .hooks.SessionEnd |= ( map(.hooks |= map(select((.command // "") != $legacy)))
                             | map(select((.hooks // []) | length > 0)) )
      | if (.hooks.SessionEnd | length) == 0 then del(.hooks.SessionEnd) else . end
    else . end
  ' "$CLAUDE_SETTINGS" > "$mtmp" && mv "$mtmp" "$CLAUDE_SETTINGS"
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
  info "removed Claude AI-status hooks"
}

claude_status() {
  if command -v jq >/dev/null 2>&1 && [ -f "$CLAUDE_SETTINGS" ]; then
    local c; c="$(jq --arg p "$NOTIFY " '[.hooks // {} | .. | .command? // empty | select(startswith($p))] | length' "$CLAUDE_SETTINGS" 2>/dev/null || echo 0)"
    echo "Claude hooks installed: ${c:-0}/5"
  else echo "Claude settings: (none / jq missing)"; fi
}

# Detect our scripts in the notify chain even when another tool (e.g. the
# Codex desktop app) re-wrapped notify and buried ours inside a JSON-escaped
# `--previous-notify` argument, where full paths appear as `\/Users\/...`.
codex_has_notify() {
  [ -f "$CODEX_CONFIG" ] || return 1
  grep -qF "codex-notify-wrap.sh" "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh", "codex' "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh","codex' "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh\", \"codex' "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh\",\"codex' "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh\\\",\\\"codex' "$CODEX_CONFIG" && return 0
  return 1
}

codex_hook_count() {
  [ -f "$CODEX_CONFIG" ] || { echo 0; return 0; }
  local count
  count="$(grep -F "$CODEX_HOOK_CMD" "$CODEX_CONFIG" 2>/dev/null | wc -l | tr -d '[:space:]')"
  [ "${count:-0}" -gt 3 ] && count=3
  echo "${count:-0}"
}

codex_has_hooks() {
  [ "$(codex_hook_count)" -ge 3 ]
}

codex_install_hooks() {
  if codex_has_hooks; then
    info "Codex hooks already integrated"; return 0
  fi
  cat >> "$CODEX_CONFIG" <<EOF

$CODEX_HOOK_BEGIN
[[hooks.PermissionRequest]]
[[hooks.PermissionRequest.hooks]]
type = "command"
command = '$CODEX_HOOK_CMD'

[[hooks.Stop]]
[[hooks.Stop.hooks]]
type = "command"
command = '$CODEX_HOOK_CMD'

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = '$CODEX_HOOK_CMD'
$CODEX_HOOK_END
EOF
  info "Codex hooks -> PermissionRequest/Stop/UserPromptSubmit"
}

codex_install() {
  mkdir -p "$(dirname "$CODEX_CONFIG")"
  if [ ! -f "$CODEX_CONFIG" ]; then
    printf 'notify = %s\n' "$CODEX_NOTIFY_JSON" > "$CODEX_CONFIG"
    info "Codex notify -> created $CODEX_CONFIG (direct)"
  fi
  cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  if codex_has_notify; then
    info "Codex notify already integrated (legacy fallback)"
  else
    if grep -qE '^[[:space:]]*notify[[:space:]]*=[[:space:]]*\[' "$CODEX_CONFIG"; then
      sed -i '' "s#^\([[:space:]]*notify[[:space:]]*=[[:space:]]*\[\)#\1\"$CODEX_WRAP\", #" "$CODEX_CONFIG"
      if grep -qF "$CODEX_WRAP" "$CODEX_CONFIG"; then info "Codex notify -> wrapped existing chain (preserved fallback)"
      else echo "  WARNING: could not auto-wrap Codex notify (multi-line array?). Prepend \"$CODEX_WRAP\" manually." >&2; fi
    else
      printf '\nnotify = %s\n' "$CODEX_NOTIFY_JSON" >> "$CODEX_CONFIG"
      info "Codex notify -> appended (direct fallback)"
    fi
  fi
  codex_install_hooks
}

codex_uninstall() {
  [ -f "$CODEX_CONFIG" ] || { info "no $CODEX_CONFIG"; return 0; }
  cp "$CODEX_CONFIG" "$CODEX_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  if grep -qF "$CODEX_HOOK_BEGIN" "$CODEX_CONFIG"; then
    sed -i '' "/$(printf '%s' "$CODEX_HOOK_BEGIN" | sed 's/[]\[^$.*/]/\\&/g')/,/$(printf '%s' "$CODEX_HOOK_END" | sed 's/[]\[^$.*/]/\\&/g')/d" "$CODEX_CONFIG"
    info "removed Codex hooks"
  fi
  if grep -qF "$CODEX_WRAP" "$CODEX_CONFIG"; then
    sed -i '' "s#\"$CODEX_WRAP\", ##" "$CODEX_CONFIG"; info "unwrapped Codex notify (restored chain)"
  elif grep -qF "$NOTIFY" "$CODEX_CONFIG"; then
    grep -vF "$NOTIFY" "$CODEX_CONFIG" > "$CODEX_CONFIG.tmp" && mv "$CODEX_CONFIG.tmp" "$CODEX_CONFIG"; info "removed direct Codex notify"
  elif codex_has_notify; then
    echo "  WARNING: our wrap is buried (JSON-escaped) inside another notify chain in $CODEX_CONFIG." >&2
    echo "  Remove the codex-notify-wrap.sh entry from that chain manually." >&2
  else info "Codex notify not ours / absent"; fi
}

codex_status() {
  local c; c="$(codex_hook_count)"
  echo "Codex hooks installed: ${c:-0}/3"
  if codex_has_notify; then echo "Codex notify fallback: installed"
  else echo "Codex notify fallback: not installed"; fi
}

# opencode is detected via its config dir or binary; without either we skip
# rather than create ~/.config/opencode for a tool that isn't there.
opencode_present() {
  [ -d "$OPENCODE_DIR" ] || command -v opencode >/dev/null 2>&1
}

opencode_install() {
  if ! opencode_present; then
    info "opencode not found (no $OPENCODE_DIR, no 'opencode' on PATH) — skipped"
    return 0
  fi
  local src="$SCRIPT_DIR/opencode-tmux-notify.js" tmp esc
  [ -f "$src" ] || die "$src not found"
  mkdir -p "$(dirname "$OPENCODE_PLUGIN")"
  tmp="$(mktemp)"
  # bake the absolute notify path into the plugin template. Escape the sed
  # replacement (& = whole match, # = our delimiter, \ = escape) and reject
  # a path that can't survive a JS string literal.
  case "$NOTIFY" in
    *'"'*|*$'\n'*) die "notify path contains a quote/newline; cannot template: $NOTIFY" ;;
  esac
  esc="$(printf '%s' "$NOTIFY" | sed 's/[&#\\]/\\&/g')"
  sed "s#__TMUX_RADAR_NOTIFY__#$esc#g" "$src" > "$tmp"
  if [ -f "$OPENCODE_PLUGIN" ] && ! cmp -s "$tmp" "$OPENCODE_PLUGIN"; then
    cp "$OPENCODE_PLUGIN" "$OPENCODE_PLUGIN.bak.$(date +%Y%m%d%H%M%S)"
  fi
  mv "$tmp" "$OPENCODE_PLUGIN"
  info "opencode plugin -> $OPENCODE_PLUGIN"
}

opencode_uninstall() {
  if [ -f "$OPENCODE_PLUGIN" ]; then
    rm -f "$OPENCODE_PLUGIN"; info "removed opencode plugin"
  else
    info "no opencode plugin installed"
  fi
}

opencode_status() {
  if ! opencode_present; then echo "opencode: not installed (skipped)"
  elif [ -f "$OPENCODE_PLUGIN" ]; then echo "opencode plugin: installed"
  else echo "opencode plugin: absent"; fi
}

[ -x "$NOTIFY" ] || die "$NOTIFY not found/executable"

case "${1:-install}" in
  install)   echo "Installing tmux-radar AI-status hooks:"; claude_install; codex_install; opencode_install
             echo "Done. Restart Claude/Codex/opencode sessions (or open new ones) to pick up the hooks." ;;
  uninstall) echo "Uninstalling tmux-radar AI-status hooks:"; claude_uninstall; codex_uninstall; opencode_uninstall ;;
  status)    claude_status; codex_status; opencode_status ;;
  *) die "usage: install-hooks.sh [install|uninstall|status]" ;;
esac

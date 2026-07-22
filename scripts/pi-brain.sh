#!/usr/bin/env bash
# tmux-radar decision brain adapter for the `pi` CLI.
#
# Implements the @radar-ai-cmd contract: the decision prompt arrives on stdin,
# the model's decision JSON goes to stdout. The engine validates/retries the
# JSON and remains the only actor, exactly as with the Codex backend. Wire it
# with:
#
#   set -g @radar-ai-cmd '~/.tmux/plugins/tmux-radar/scripts/pi-brain.sh'
#   # optional, when pi's default provider isn't the one you want:
#   set -g @radar-ai-pi-provider 'openai-codex'
#
# Model resolves from @radar-ai-model (same option the Codex backend uses;
# e.g. gpt-5.3-codex-spark configured as a pi provider model), effort maps to
# pi's --thinking level. Env overrides: TMUX_RADAR_PI_MODEL,
# TMUX_RADAR_PI_PROVIDER, TMUX_RADAR_PI_THINKING, TMUX_RADAR_PI_BIN.
#
# The invocation is deliberately inert: --no-tools (no file/shell access),
# --no-session (ephemeral, nothing persisted), one process the engine can
# time out and kill as a group.
set -euo pipefail

PI_BIN="${TMUX_RADAR_PI_BIN:-pi}"
command -v "$PI_BIN" >/dev/null 2>&1 || {
  echo "pi-brain: pi CLI not found (install pi or set TMUX_RADAR_PI_BIN)" >&2
  exit 3
}

opt() { tmux show-option -gqv "$1" 2>/dev/null || true; }

MODEL="${TMUX_RADAR_PI_MODEL:-$(opt @radar-ai-model)}"
PROVIDER="${TMUX_RADAR_PI_PROVIDER:-$(opt @radar-ai-pi-provider)}"
THINKING="${TMUX_RADAR_PI_THINKING:-$(opt @radar-ai-effort)}"
case "$THINKING" in
  off|minimal|low|medium|high|xhigh|max) ;;
  *) THINKING="" ;;
esac

prompt="$(cat)"
[ -n "$prompt" ] || { echo "pi-brain: empty prompt on stdin" >&2; exit 2; }

args=(--print --no-session --no-tools)
[ -n "$PROVIDER" ] && args+=(--provider "$PROVIDER")
[ -n "$MODEL" ] && args+=(--model "$MODEL")
[ -n "$THINKING" ] && args+=(--thinking "$THINKING")
exec "$PI_BIN" "${args[@]}" "$prompt"

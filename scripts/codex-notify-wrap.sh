#!/usr/bin/env bash
# Chain shim for Codex `notify`. Installed as the FIRST element of the existing
# notify array so Codex invokes:
#
#   codex-notify-wrap.sh <original-notify-argv...> <event-json>
#
# We mark the Codex pane with an AI-status notice (JSON is the last arg;
# $TMUX_PANE is inherited), then exec the original chain unchanged so existing notify
# behaviour keeps working. With no prior chain it is invoked as
# `codex-notify-wrap.sh <event-json>` and simply marks.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/needinput-notify.sh" codex "${@: -1}" >/dev/null 2>&1 || true

# Forward to the original chain only if one was prepended (i.e. >1 arg: the
# original argv plus the json). With a single arg there is nothing to exec.
if [ "$#" -gt 1 ]; then
  exec "$@"
fi
exit 0

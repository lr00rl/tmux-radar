#!/usr/bin/env bash
#
# Template: bridge one vendor hook JSON object to tmux-radar's public agent API.
#
# Copy this file into your agent integration, set TMUX_RADAR_NOTIFY to the
# absolute path of tmux-radar's scripts/needinput-notify.sh, and replace the
# VENDOR_* event names and JSON field paths below with the vendor's documented
# values. The template deliberately has no direct access to radar state files.
#
# Expected vendor input for this example (one JSON object on standard input):
# {
#   "event": "VENDOR_PERMISSION_REQUEST",
#   "session_id": "vendor-stable-session-id",
#   "cwd": "/absolute/project/path",
#   "pane": "%42",
#   "pid": 1234,
#   "process": "vendor-agent",
#   "message": "optional detail for the user"
# }
#
# macOS ships Bash 3.2. Keep this script POSIX-shaped: no associative arrays,
# mapfile, readarray, or Bash 4+ string features.
set -eu

: "${TMUX_RADAR_NOTIFY:?set TMUX_RADAR_NOTIFY to the absolute path of scripts/needinput-notify.sh}"

# Use a stable, lowercase identifier that contains only letters, digits, dots,
# underscores, or hyphens. Change this placeholder for the vendor integration.
AGENT_KIND="${TMUX_RADAR_AGENT_KIND:-example-agent}"

command -v jq >/dev/null 2>&1 || {
  echo "custom-agent-adapter: jq is required" >&2
  exit 1
}

[ -x "$TMUX_RADAR_NOTIFY" ] || {
  echo "custom-agent-adapter: notifier is not executable: $TMUX_RADAR_NOTIFY" >&2
  exit 1
}

# Read once so the same one-object validation feeds both event mapping and the
# normalized payload. jq -s rejects a stream containing zero or multiple JSON
# documents; hooks should pass exactly one object.
raw="$(cat 2>/dev/null || true)"

vendor_event="$(printf '%s' "$raw" | jq -ser 'if (length != 1) or (.[0] | type != "object") then error("expected exactly one vendor JSON object") elif (.[0].event | type) != "string" or .[0].event == "" then error("vendor event must be a non-empty string at .event") else .[0].event end' 2>/dev/null)" || {
  echo "custom-agent-adapter: malformed vendor payload" >&2
  exit 1
}

# Replace these placeholder event strings with the vendor's documented events.
# Keep the normalized names unchanged: needinput-notify.sh validates this set.
case "$vendor_event" in
  VENDOR_SESSION_STARTED)      normalized_event=session_start ;;
  VENDOR_PERMISSION_REQUEST)   normalized_event=approval ;;
  VENDOR_PERMISSION_RESOLVED)  normalized_event=approval_resolved ;;
  VENDOR_INPUT_REQUIRED)       normalized_event=input_required ;;
  VENDOR_USER_RESUMED)         normalized_event=user_resumed ;;
  VENDOR_TURN_COMPLETED)       normalized_event=turn_complete ;;
  VENDOR_INTERRUPTED)          normalized_event=interrupt ;;
  VENDOR_SESSION_ENDED)        normalized_event=session_end ;;
  *)
    echo "custom-agent-adapter: unsupported vendor event: $vendor_event" >&2
    exit 1
    ;;
esac

# Replace .session_id, .cwd, .pane, .pid, .process, and .message if the vendor
# uses different names. session_id is required and must remain stable for the
# full vendor session. pane and pid are optional: radar falls back to
# TMUX_PANE, then process ancestry, when they are omitted or empty.
payload="$(printf '%s' "$raw" | jq -sce 'if (length != 1) or (.[0] | type != "object") then error("expected exactly one vendor JSON object") else .[0] | if (.session_id | type) != "string" or .session_id == "" then error("missing stable .session_id") elif ((.cwd // "") | type) != "string" or ((.pane // "") | type) != "string" or ((.pid // 0) | type) != "number" or ((.process // "") | type) != "string" or ((.message // .label // "") | type) != "string" then error("vendor payload has an invalid normalized field type") else {session_id:.session_id,cwd:(.cwd // ""),pane:(.pane // ""),pid:(.pid // 0),process:(.process // ""),label:(.message // .label // "")} end end' 2>/dev/null)" || {
  echo "custom-agent-adapter: malformed vendor payload" >&2
  exit 1
}

# Do not write registry, mark, inbox, or run files here. The shared command
# owns validation, locking, identity resolution, notifications, watcher events,
# and cleanup. agent-event uses exit 2 for strict validation, but many vendors
# reserve exit 2 for "block this operation". Translate that internal data error
# to an ordinary nonzero failure so this observability adapter fails open.
notify_rc=0
"$TMUX_RADAR_NOTIFY" agent-event "$AGENT_KIND" "$normalized_event" <<EOF || notify_rc=$?
$payload
EOF
[ "$notify_rc" -eq 2 ] && notify_rc=1
exit "$notify_rc"

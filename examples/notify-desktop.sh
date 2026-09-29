#!/bin/sh
# A desktop notification for a mark nobody is looking at. tmux-radar runs
# @radar-notify-command once per new mark, with the mark in RADAR_* variables:
#
#   set -g @radar-notify-command '~/.tmux/plugins/tmux-radar/examples/notify-desktop.sh'
#
# Copy it and change it: RADAR_LEVEL is action, done or notice, so a
# turn-end-only notifier starts with  [ "$RADAR_LEVEL" = done ] || exit 0.
# Always quote the RADAR_* values: a label carries text the agent wrote.
[ "${RADAR_WATCHED:-0}" = 1 ] && exit 0
title="${RADAR_WHERE:-tmux-radar}"
case "$(uname -s)" in
  Darwin)
    # the text goes in as arguments, never into the AppleScript source
    osascript -e 'on run argv' \
      -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' "$title" "${RADAR_LABEL:-}"
    ;;
  *)
    command -v notify-send >/dev/null 2>&1 && notify-send "$title" "${RADAR_LABEL:-}"
    ;;
esac
exit 0

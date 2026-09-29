#!/usr/bin/env bash
# shellcheck shell=bash
# Mark severity, defined once for the notifier, the chip renderer, the picker
# and doctor. Sourced, never executed.
#
# A label reads "<head>[: <detail>]". Adapters write the head from a fixed
# vocabulary ("Claude needs approval", "Codex finished - your turn"); the
# detail is free text from the agent. A head that ends in a known phrase
# decides the severity on its own, so no word in the detail can change it.
# Any other label (the public `mark` API, older rows, scanner labels) is
# classified by its whole text, completion before action, as it always was.
# Paneless labels put "<Agent>·<where>: " ahead of the head.
#
# RADAR_LEVEL_AWK holds the awk function; prepend it to an awk program that
# calls radar_level(source, label). Keep the text free of apostrophes.
# shellcheck disable=SC2034  # consumed by the scripts that source this file
RADAR_LEVEL_AWK='
function radar_level(src, label,    h, i, l, done_re, action_re) {
  done_re = "(finished|your turn|turn complete|task complete|done|任务完成|完成)"
  action_re = "(needs approval|needs your permission|needs input|needs your input|waiting.*input|waiting on you|wait.*input|permission|approval|action required|approve|拿不准|需要你|需要.*许可|需要.*批准|等待.*输入)"
  h = tolower(label)
  sub(/^[a-z]+·[^:]*: /, "", h)
  i = index(h, ": ")
  if (i > 0) h = substr(h, 1, i - 1)
  if (h ~ /(needs approval|needs your permission|needs your input|needs input)$/) return "action"
  if (h ~ /finished( - your turn| — your turn)?$/) return "done"
  if (h ~ /turn failed$/) return "notice"
  l = tolower(src " " label)
  if (l ~ done_re) return "done"
  if (l ~ action_re) return "action"
  return "notice"
}
'

radar_level() {  # radar_level <source> <label> -> done | action | notice
  # ENVIRON, not -v: awk would expand backslash escapes in a -v value
  RADAR_SRC="${1:-}" RADAR_LABEL="${2:-}" LC_ALL=C awk "$RADAR_LEVEL_AWK"'
    BEGIN { printf "%s", radar_level(ENVIRON["RADAR_SRC"], ENVIRON["RADAR_LABEL"]) }'
}

radar_icon() {  # radar_icon <source> <label> -> the status glyph for that level
  case "$(radar_level "${1:-}" "${2:-}")" in
    action) printf '⚠' ;;
    done)   printf '✓' ;;
    *)      printf '!' ;;
  esac
}

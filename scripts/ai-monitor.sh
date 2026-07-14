#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI="$SCRIPT_DIR/ai.sh"
STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
WATCH_DIR="$STATE_DIR/ai-watch"

RESET=$'\033[0m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
CYAN=$'\033[1;36m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
RED=$'\033[1;31m'
BLUE=$'\033[1;34m'

PANE=""
WATCH_FILE=""
RUN_DIR=""
RUN_ID=""
STOP_ON_EXIT=1

watch_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
field() { awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null || true; }
json_value() { jq -r --arg key "$2" '.values[$key].value // "-"' "$1" 2>/dev/null || printf '-'; }
json_source() { jq -r --arg key "$2" '.values[$key].source // "-"' "$1" 2>/dev/null || printf '-'; }
clip() {
  local width="$1"
  awk -v width="$width" -v esc="$(printf '\033')" '
    {
      gsub(/\t/, "  ")
      line=$0
      plain=line
      csi=esc "\\[[0-9;?]*[ -/]*[@-~]"
      gsub(csi, "", plain)
      if (length(plain) <= width) { print line; next }
      if (width <= 1) { print "…"; next }
      print substr(plain, 1, width - 1) "…"
    }'
}

open_run() {
  PANE="$1"
  WATCH_FILE="$WATCH_DIR/$(watch_key "$PANE").watch"
  [ -r "$WATCH_FILE" ] || return 1
  RUN_DIR="$(field "$WATCH_FILE" run_dir)"
  RUN_ID="$(field "$WATCH_FILE" run_id)"
  [ -d "$RUN_DIR" ]
}

phase_color() {
  case "$1" in
    COMPLETED|DONE) printf '%s' "$GREEN" ;;
    STOPPED|ERROR|PAUSED_ERROR) printf '%s' "$RED" ;;
    PAUSED*|RETRY*|EVENT_PENDING|POLICY_GATE) printf '%s' "$YELLOW" ;;
    DECIDING|CAPTURING|EXECUTING|VERIFYING) printf '%s' "$CYAN" ;;
    *) printf '%s' "$BLUE" ;;
  esac
}

next_label() {
  local phase="$1" kind="$2" at="$3" now remaining
  now="$(date '+%s')"
  case "$phase" in
    DECIDING) printf 'after model response' ;;
    CAPTURING) printf 'after pane capture' ;;
    POLICY_GATE) printf 'after policy gate' ;;
    EXECUTING) printf 'after guarded key delivery' ;;
    VERIFYING) printf 'waiting for target change or resume hook' ;;
    PAUSED_USER) printf 'paused; press p to resume' ;;
    PAUSED_ERROR) printf 'paused on error; inspect Decision/Logs' ;;
    COMPLETED|DONE)
      if [ "$kind" = manual_close ]; then
        printf 'kept open; press q to close'
      else
        case "$at" in ''|*[!0-9]*) at=0 ;; esac
        remaining=$((at - now)); [ "$remaining" -lt 0 ] && remaining=0
        printf 'auto-close in %ss; press k to keep' "$remaining"
      fi
      ;;
    *)
      case "$at" in ''|*[!0-9]*) at=0 ;; esac
      remaining=$((at - now)); [ "$remaining" -lt 0 ] && remaining=0
      if [ "$at" -gt 0 ]; then printf '%s in %ss' "${kind:-next event}" "$remaining"
      else printf 'native hook or stable-screen fallback'; fi
      ;;
  esac
}

overview_rows() {
  local state="$RUN_DIR/state.json" config="$RUN_DIR/config.json" phase status goal policy autonomy
  local calls max_calls retry poll model profile effort logging retention event source elapsed started queued next_kind next_at color final summary
  [ -r "$state" ] || return 1
  phase="$(jq -r '.phase // "CREATED"' "$state")"
  status="$(jq -r '.status // "starting"' "$state")"
  goal="$(jq -r '.goal // "-"' "$state")"
  policy="$(jq -r '.policy // "safe-auto"' "$state")"
  autonomy="$(jq -r '.autonomy // "auto-safe"' "$state")"
  calls="$(jq -r '.calls // 0' "$state")"; max_calls="$(jq -r '.max_calls // 0' "$state")"
  retry="$(jq -r '.retry // 0' "$state")"; poll="$(jq -r '.poll // 0' "$state")"
  next_kind="$(jq -r '.next.kind // "event"' "$state")"; next_at="$(jq -r '.next.at // 0' "$state")"
  model="$(json_value "$config" model)"; profile="$(json_value "$config" profile)"; effort="$(json_value "$config" effort)"
  logging="$(json_value "$config" logging)"; retention="$(json_value "$config" retention_days)"
  event="$(jq -r 'select(.record == "incoming") | .kind' "$RUN_DIR/events.jsonl" 2>/dev/null | tail -n 1)"
  source="$(jq -r 'select(.record == "incoming") | .source' "$RUN_DIR/events.jsonl" 2>/dev/null | tail -n 1)"
  started="$(field "$WATCH_FILE" started)"; case "$started" in ''|*[!0-9]*) started="$(date '+%s')" ;; esac
  elapsed=$(( $(date '+%s') - started )); [ "$elapsed" -lt 0 ] && elapsed=0
  queued="$(find "$RUN_DIR/inbox" -maxdepth 1 -name '*.ready' -type f 2>/dev/null | wc -l | tr -d ' ')"
  color="$(phase_color "$phase")"
  printf '%s%s tmux-radar supervisor %s%s  %s%s%s  %srun %s%s\n' "$BOLD" "$CYAN" "$RESET" "$DIM" "$color" "$phase" "$RESET" "$DIM" "$RUN_ID" "$RESET"
  printf '%sGoal%s      %s\n' "$BOLD" "$RESET" "$goal"
  printf '%sEvent%s     %s%s%s · source=%s · queued=%s · elapsed=%ss\n' "$BOLD" "$RESET" "$YELLOW" "${event:-none}" "$RESET" "${source:-none}" "$queued" "$elapsed"
  final="$RUN_DIR/final.json"
  if [ -r "$final" ]; then
    summary="$(jq -r '"\(.outcome) · decisions=\(.decision_count // 0) actions=\(.action_count // 0) errors=\(.error_count // 0) · \(.duration_seconds // 0)s"' "$final" 2>/dev/null || true)"
    printf '%sOutcome%s   %s · %s\n' "$BOLD" "$RESET" "${summary:-completed}" "$status"
  else
    printf '%sDecision%s  %s/%s · retry=%s · %s\n' "$BOLD" "$RESET" "$calls" "$max_calls" "$retry" "$status"
  fi
  printf '%sBrain%s     model=%s profile=%s effort=%s\n' "$BOLD" "$RESET" "$model" "${profile:--}" "$effort"
  printf '%sPolicy%s    %s · autonomy=%s\n' "$BOLD" "$RESET" "$policy" "$autonomy"
  printf '%sTrigger%s   hooks-first + stable screen · poll=%ss\n' "$BOLD" "$RESET" "$poll"
  printf '%sLogs%s      %s · retention=%sd\n' "$BOLD" "$RESET" "$logging" "$retention"
  printf '%sNext%s      %s\n' "$BOLD" "$RESET" "$(next_label "$phase" "$next_kind" "$next_at")"
  printf '%sControls%s  p pause/resume · r reassess · k keep · c config · Enter target · q stop\n' "$DIM" "$RESET"
}

draw_rows_at() {
  local previous="$1" current="$2" cols="$3" start="$4" count row terminal_row old new rendered
  count="$(wc -l < "$current" | tr -d ' ')"; row=1
  while [ "$row" -le "$count" ]; do
    old="$(sed -n "${row}p" "$previous" 2>/dev/null || true)"
    new="$(sed -n "${row}p" "$current" 2>/dev/null || true)"
    if [ "$new" != "$old" ]; then
      terminal_row=$((start + row - 1))
      printf '\033[%s;1H\033[2K' "$terminal_row"
      rendered="$(printf '%s\n' "$new" | clip "$cols")"
      printf '%s' "$rendered"
    fi
    row=$((row + 1))
  done
  cp "$current" "$previous"
}

draw_fixed_rows() { draw_rows_at "$1" "$2" "$3" 1; }

overview_loop() {
  local once="$1" previous current cols last_cols=0
  previous="$(mktemp "${TMPDIR:-/tmp}/radar-overview.prev.XXXXXX")" || exit 1
  current="$(mktemp "${TMPDIR:-/tmp}/radar-overview.cur.XXXXXX")" || exit 1
  : > "$previous"
  trap 'rm -f "${previous:-}" "${current:-}"; printf "\033[?25h"; [ "$STOP_ON_EXIT" -eq 0 ] || "$AI" stop "$PANE" >/dev/null 2>&1 || true' EXIT TERM INT HUP
  printf '\033[?25l'
  while [ -r "$WATCH_FILE" ]; do
    cols="$(tput cols 2>/dev/null || printf 100)"; case "$cols" in ''|*[!0-9]*) cols=100 ;; esac
    if [ "$cols" -ne "$last_cols" ]; then printf '\033[H\033[2J'; : > "$previous"; last_cols="$cols"; fi
    overview_rows > "$current" || break
    draw_fixed_rows "$previous" "$current" "$cols"
    [ "$once" -eq 1 ] && { STOP_ON_EXIT=0; break; }
    sleep 1
  done
}

timeline_render() {
  local from="${1:-1}"
  jq -r --argjson from "$from" '
    to_entries[] | select(.key + 1 >= $from) | .value |
    [(.timestamp // "" | sub("^.*T";"") | sub("Z$";"")),
     (.phase // .kind // "event"), (.source // "watcher"), (.label // .status // "")] | @tsv
  ' < <(jq -s '.' "$RUN_DIR/events.jsonl" 2>/dev/null || printf '[]') 2>/dev/null |
  awk -F '\t' -v reset="$RESET" -v cyan="$CYAN" -v yellow="$YELLOW" -v red="$RED" -v green="$GREEN" '
    {
      color=cyan
      if ($2 ~ /failed|error|STOPPED/) color=red
      else if ($2 ~ /completed|sent|verification_completed/) color=green
      else if ($2 ~ /paused|deferred|retry|approval|input_required/) color=yellow
      printf "%s%s%s  %-22s %-10s %s\n", color,$1,reset,$2,$3,$4
    }'
}

decision_render() {
  local latest meta
  latest="$(find "$RUN_DIR/decisions" -maxdepth 1 -name '[0-9][0-9][0-9][0-9].json' -type f 2>/dev/null | sort | tail -n 1)"
  if [ -n "$latest" ]; then
    meta="${latest%.json}.meta.json"
    printf '%sDecision evidence%s\n\n' "$CYAN" "$RESET"
    jq -r '"Action: \(.action // "-")\nPane: \(.pane_state // "unknown")\nGoal: \(.goal_status // "unclear")\nRisk: \(.risk // "unknown")\nSafe: \(.safe // false)\nReason: \(.reason // "-")\nText: \(.text // "")\nKeys: \((.keys // []) | join(", "))\nEvidence:\n  - \((.evidence // []) | join("\n  - "))"' "$latest" 2>/dev/null
    [ -r "$meta" ] && { printf '\n%sCall metadata%s\n' "$CYAN" "$RESET"; jq . "$meta"; }
  else
    printf '%sDecision evidence%s\n\nNo persisted decision yet.\n\nRecent decision lifecycle:\n' "$CYAN" "$RESET"
    jq -r 'select(.kind | test("model|decision|sent|verification|wait|suggest|delivery")) | "\(.timestamp // "")  \(.kind): \(.label // "")"' "$RUN_DIR/events.jsonl" 2>/dev/null | tail -n 24
  fi
}

screen_render() {
  local lines config="$RUN_DIR/config.json"
  lines="$(json_value "$config" monitor_excerpt_lines)"; case "$lines" in ''|*[!0-9]*) lines=16 ;; esac
  printf '%sTarget screen%s  %s · last %s lines\n%sModel capture%s  %s lines\n\n' "$CYAN" "$RESET" "$PANE" "$lines" "$DIM" "$RESET" "$(json_value "$config" capture_lines)"
  tmux capture-pane -p -t "$PANE" -S "-$lines" 2>/dev/null || printf 'target pane unavailable\n'
}

config_render() {
  local config="$RUN_DIR/config.json" group keys key
  printf '%sEffective configuration%s  value [source]\n' "$CYAN" "$RESET"
  while IFS=$'\t' read -r group keys; do
    printf '\n%s%s%s\n' "$BOLD" "$group" "$RESET"
    for key in $keys; do
      printf '  %-27s %s %s[%s]%s\n' "$key" "$(json_value "$config" "$key")" "$DIM" "$(json_source "$config" "$key")" "$RESET"
    done
  done <<'EOF'
Intent	goal
Authority	autonomy approval_policy always_allow
Triggering	hooks_first poll stable_screen_threshold
Brain	command profile model effort timeout
Budget	max_decisions retry_limit retry_backoff
Context	capture_lines monitor_excerpt_lines
Console	monitor_position monitor_width overview_ratio completion_close_delay
Logging	logging screen_snapshots retention_days
EOF
}

logs_render() {
  local file size
  printf '%sRun logs%s\n%s%s%s\n\n' "$CYAN" "$RESET" "$DIM" "$RUN_DIR" "$RESET"
  for file in config.json state.json events.jsonl final.json decisions backend screens prompts; do
    if [ -d "$RUN_DIR/$file" ]; then
      size="$(find "$RUN_DIR/$file" -type f 2>/dev/null | wc -l | tr -d ' ') files"
    elif [ -e "$RUN_DIR/$file" ]; then
      size="$(wc -c < "$RUN_DIR/$file" | tr -d ' ') bytes"
    else
      size='not created'
    fi
    printf '  %-18s %s\n' "$file" "$size"
  done
  printf '\n%sRecent backend stderr / errors%s\n' "$YELLOW" "$RESET"
  find "$RUN_DIR/backend" -maxdepth 1 -name '*.stderr' -type f 2>/dev/null | sort | tail -n 1 | while IFS= read -r file; do tail -n 18 "$file"; done
  jq -r 'select(.kind | test("failed|error|warning")) | "\(.timestamp // "")  \(.kind): \(.label // "")"' "$RUN_DIR/events.jsonl" 2>/dev/null | tail -n 12
}

detail_header() {
  local view="$1"
  printf '%s tmux-radar detail %s  %srun %s%s\n' "$CYAN" "$RESET" "$DIM" "$RUN_ID" "$RESET"
  printf '%s1%s Timeline  %s2%s Decision  %s3%s Screen  %s4%s Config  %s5%s Logs\n' "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET" "$BOLD" "$RESET"
  printf '%sp%s pause/resume  %sr%s reassess  %sk%s keep  %sc%s config  %sEnter%s target  %sq%s stop   view=%s\n' "$YELLOW" "$RESET" "$YELLOW" "$RESET" "$YELLOW" "$RESET" "$YELLOW" "$RESET" "$YELLOW" "$RESET" "$RED" "$RESET" "$view"
  printf '%s\n' '────────────────────────────────────────────────────────────────────────'
}

render_view() {
  case "$1" in
    Timeline) timeline_render 1 ;;
    Decision) decision_render ;;
    Screen) screen_render ;;
    Config) config_render ;;
    Logs) logs_render ;;
  esac
}

handle_key() {
  local key="$1"
  case "$key" in
    1) DETAIL_VIEW=Timeline; DETAIL_REDRAW=1 ;;
    2) DETAIL_VIEW=Decision; DETAIL_REDRAW=1 ;;
    3) DETAIL_VIEW=Screen; DETAIL_REDRAW=1 ;;
    4|c) DETAIL_VIEW=Config; DETAIL_REDRAW=1 ;;
    5) DETAIL_VIEW=Logs; DETAIL_REDRAW=1 ;;
    p)
      if [ -e "$RUN_DIR/paused" ]; then "$AI" resume "$PANE" >/dev/null 2>&1
      else "$AI" pause "$PANE" >/dev/null 2>&1; fi
      ;;
    r) "$AI" emit-event "$PANE" manual_reassess monitor 'manual reassessment' >/dev/null 2>&1 ;;
    k) "$AI" keep "$PANE" >/dev/null 2>&1 || true ;;
    q)
      STOP_ON_EXIT=0
      "$AI" stop "$PANE" >/dev/null 2>&1 || true
      return 10
      ;;
    '')
      if [ "${COMPACT_POPUP:-0}" -eq 1 ]; then
        STOP_ON_EXIT=0
        return 11
      fi
      tmux select-pane -t "$PANE" >/dev/null 2>&1 || true
      ;;
  esac
  return 0
}

detail_loop() {
  local once="$1" key count last_count=0
  DETAIL_VIEW="${2:-Timeline}"; DETAIL_REDRAW=1
  trap 'printf "\033[?25h"; [ "$STOP_ON_EXIT" -eq 0 ] || "$AI" stop "$PANE" >/dev/null 2>&1 || true' EXIT TERM INT HUP
  printf '\033[?25l'
  while [ -r "$WATCH_FILE" ]; do
    if [ "$DETAIL_REDRAW" -eq 1 ]; then
      printf '\033[H\033[2J'
      detail_header "$DETAIL_VIEW"
      render_view "$DETAIL_VIEW"
      last_count="$(wc -l < "$RUN_DIR/events.jsonl" | tr -d ' ')"
      DETAIL_REDRAW=0
    elif [ "$DETAIL_VIEW" = Timeline ]; then
      count="$(wc -l < "$RUN_DIR/events.jsonl" | tr -d ' ')"
      if [ "$count" -gt "$last_count" ]; then timeline_render "$((last_count + 1))"; last_count="$count"; fi
    fi
    [ "$once" -eq 1 ] && { STOP_ON_EXIT=0; break; }
    key=""
    if IFS= read -rsn1 -t 1 key </dev/tty 2>/dev/null; then
      if [ "$key" = $'\033' ]; then IFS= read -rsn2 -t 0.02 _rest </dev/tty 2>/dev/null || true; continue; fi
      handle_key "$key" || break
    fi
  done
}

compact_goal_rows() {
  local goal="$1" width="$2"
  awk -v width="$width" '
    {
      gsub(/\t/, "  ")
      text=text (text == "" ? "" : " / ") $0
    }
    END {
      if (width < 8) width=8
      if (length(text) <= width) { print text; print ""; exit }
      split_at=width
      while (split_at > 1 && substr(text, split_at, 1) != " ") split_at--
      if (split_at <= 1) split_at=width
      first=substr(text, 1, split_at)
      rest=substr(text, split_at + 1)
      sub(/^ +/, "", rest)
      if (length(rest) > width) rest=substr(rest, 1, width - 1) "…"
      print first
      print rest
    }' <<EOF
$goal
EOF
}

compact_rows() {
  local cols="$1" state="$RUN_DIR/state.json" config="$RUN_DIR/config.json"
  local phase status goal calls max_calls retry poll policy autonomy model effort logging retention
  local event source queued elapsed started next_kind next_at color goal_width goal_first goal_second
  phase="$(jq -r '.phase // "CREATED"' "$state")"
  status="$(jq -r '.status // "starting"' "$state")"
  goal="$(jq -r '.goal // "-"' "$state")"
  calls="$(jq -r '.calls // 0' "$state")"; max_calls="$(jq -r '.max_calls // 0' "$state")"
  retry="$(jq -r '.retry // 0' "$state")"; poll="$(jq -r '.poll // 0' "$state")"
  case "$poll" in ''|*[!0-9.]*) ;; *) poll="$(awk -v value="$poll" 'BEGIN { printf "%g", value }')" ;; esac
  policy="$(jq -r '.policy // "safe-auto"' "$state")"; autonomy="$(jq -r '.autonomy // "auto-safe"' "$state")"
  next_kind="$(jq -r '.next.kind // "event"' "$state")"; next_at="$(jq -r '.next.at // 0' "$state")"
  model="$(json_value "$config" model)"; effort="$(json_value "$config" effort)"
  logging="$(json_value "$config" logging)"; retention="$(json_value "$config" retention_days)"
  event="$(jq -r 'select(.record == "incoming") | .kind' "$RUN_DIR/events.jsonl" 2>/dev/null | tail -n 1)"
  source="$(jq -r 'select(.record == "incoming") | .source' "$RUN_DIR/events.jsonl" 2>/dev/null | tail -n 1)"
  queued="$(find "$RUN_DIR/inbox" -maxdepth 1 -name '*.ready' -type f 2>/dev/null | wc -l | tr -d ' ')"
  started="$(field "$WATCH_FILE" started)"; case "$started" in ''|*[!0-9]*) started="$(date '+%s')" ;; esac
  elapsed=$(( $(date '+%s') - started )); [ "$elapsed" -lt 0 ] && elapsed=0
  color="$(phase_color "$phase")"
  goal_width=$((cols - 6)); [ "$goal_width" -lt 8 ] && goal_width=8
  goal_first="$(compact_goal_rows "$goal" "$goal_width" | sed -n '1p')"
  goal_second="$(compact_goal_rows "$goal" "$goal_width" | sed -n '2p')"

  printf '%s%s tmux-radar supervisor%s  %s%s%s · elapsed %ss\n' "$BOLD" "$CYAN" "$RESET" "$color" "$phase" "$RESET" "$elapsed"
  printf '%sGoal%s  %s\n' "$BOLD" "$RESET" "$goal_first"
  printf '      %s\n' "$goal_second"
  printf '%sNow%s   %s\n' "$BOLD" "$RESET" "$status"
  printf '%sNext%s  %s\n' "$BOLD" "$RESET" "$(next_label "$phase" "$next_kind" "$next_at")"
  printf '%sProgress%s  decisions %s/%s · retry %s · queue %s\n' "$BOLD" "$RESET" "$calls" "$max_calls" "$retry" "$queued"
  printf '%sEvent%s  %s · source %s\n' "$BOLD" "$RESET" "${event:-none}" "${source:-none}"
  printf '%sPolicy%s  %s · %s · hooks-first · poll %ss\n' "$BOLD" "$RESET" "$policy" "$autonomy" "$poll"
  printf '%sBrain%s  %s · effort %s · logs %s/%sd\n' "$BOLD" "$RESET" "$model" "$effort" "$logging" "$retention"
}

compact_is_popup() {
  [ "$(field "$RUN_DIR/monitors" monitor_detail_pane)" = popup ]
}

compact_control_rows() {
  local target_label='Target pane'
  [ "${COMPACT_POPUP:-0}" -eq 0 ] || target_label='Hide monitor (run continues)'
  printf '%sView%s  %s · [u]/[d] scroll detail\n' "$BOLD" "$RESET" "$DETAIL_VIEW"
  printf '[1] Timeline  [2] Decision  [3] Screen\n'
  printf '[4] Config    [5] Logs\n'
  printf '[p] Pause/resume  [r] Reassess now  [k] Keep open\n'
  printf '[Enter] %s  [q] Stop supervision\n' "$target_label"
}

compact_render_body() {
  local output="$1" start="$2" end="$3" cols="$4" body_rows total start_line row line rendered
  render_view "$DETAIL_VIEW" > "$output"
  total="$(wc -l < "$output" | tr -d ' ')"
  body_rows=$((end - start + 1)); [ "$body_rows" -gt 0 ] || return 0
  if [ "${COMPACT_FOLLOW:-0}" -eq 1 ]; then
    start_line=$((total - body_rows + 1)); [ "$start_line" -gt 0 ] || start_line=1
  else
    start_line=$((COMPACT_OFFSET + 1))
    [ "$start_line" -le "$total" ] || start_line=$((total > 0 ? total : 1))
  fi
  COMPACT_OFFSET=$((start_line - 1))
  row=0
  while [ "$row" -lt "$body_rows" ]; do
    line="$(sed -n "$((start_line + row))p" "$output" 2>/dev/null || true)"
    printf '\033[%s;1H\033[2K' "$((start + row))"
    if [ -n "$line" ]; then
      rendered="$(printf '%s\n' "$line" | clip "$cols")"
      printf '%s' "$rendered"
    fi
    row=$((row + 1))
  done
}

compact_loop() {
  local once="$1" initial_view="${2:-Timeline}" cols last_cols=0 count=0 last_count=0 key rows
  local body_start=10 body_end control_start body_rows old_view
  COMPACT_PREVIOUS="$(mktemp "${TMPDIR:-/tmp}/radar-compact.prev.XXXXXX")" || exit 1
  COMPACT_CURRENT="$(mktemp "${TMPDIR:-/tmp}/radar-compact.cur.XXXXXX")" || exit 1
  COMPACT_PREVIOUS_CONTROLS="$(mktemp "${TMPDIR:-/tmp}/radar-compact-controls.prev.XXXXXX")" || exit 1
  COMPACT_CONTROLS="$(mktemp "${TMPDIR:-/tmp}/radar-compact-controls.cur.XXXXXX")" || exit 1
  COMPACT_BODY="$(mktemp "${TMPDIR:-/tmp}/radar-compact-body.XXXXXX")" || exit 1
  : > "$COMPACT_PREVIOUS"; : > "$COMPACT_PREVIOUS_CONTROLS"
  DETAIL_VIEW="$initial_view"; DETAIL_REDRAW=1; COMPACT_OFFSET=0; COMPACT_FOLLOW=0; COMPACT_POPUP=0
  compact_is_popup && COMPACT_POPUP=1
  [ "$DETAIL_VIEW" != Timeline ] || COMPACT_FOLLOW=1
  trap 'rm -f "${COMPACT_PREVIOUS:-}" "${COMPACT_CURRENT:-}" "${COMPACT_PREVIOUS_CONTROLS:-}" "${COMPACT_CONTROLS:-}" "${COMPACT_BODY:-}"; printf "\033[r\033[?25h"; [ "$STOP_ON_EXIT" -eq 0 ] || "$AI" stop "$PANE" >/dev/null 2>&1 || true' EXIT TERM INT HUP
  printf '\033[?25l'
  while [ -r "$WATCH_FILE" ]; do
    cols="${TMUX_RADAR_MONITOR_COLS:-$(tput cols 2>/dev/null || printf 80)}"
    rows="${TMUX_RADAR_MONITOR_ROWS:-$(tput lines 2>/dev/null || printf 30)}"
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac; case "$rows" in ''|*[!0-9]*) rows=30 ;; esac
    control_start=$((rows - 4)); [ "$control_start" -gt "$body_start" ] || control_start=$((body_start + 1))
    body_end=$((control_start - 1)); body_rows=$((body_end - body_start + 1))
    if [ "$cols" -ne "$last_cols" ]; then
      printf '\033[r\033[H\033[2J'
      : > "$COMPACT_PREVIOUS"; : > "$COMPACT_PREVIOUS_CONTROLS"
      last_cols="$cols"; last_count=0; DETAIL_REDRAW=1
    fi
    compact_rows "$cols" > "$COMPACT_CURRENT" || break
    draw_rows_at "$COMPACT_PREVIOUS" "$COMPACT_CURRENT" "$cols" 1
    compact_control_rows > "$COMPACT_CONTROLS"
    draw_rows_at "$COMPACT_PREVIOUS_CONTROLS" "$COMPACT_CONTROLS" "$cols" "$control_start"
    count="$(wc -l < "$RUN_DIR/events.jsonl" | tr -d ' ')"
    if [ "$DETAIL_REDRAW" -eq 1 ] || { [ "$DETAIL_VIEW" = Timeline ] && [ "$count" -gt "$last_count" ]; }; then
      compact_render_body "$COMPACT_BODY" "$body_start" "$body_end" "$cols"
      last_count="$count"; DETAIL_REDRAW=0
    fi
    [ "$once" -eq 1 ] && { STOP_ON_EXIT=0; break; }
    key=""
    if IFS= read -rsn1 -t 1 key </dev/tty 2>/dev/null; then
      old_view="$DETAIL_VIEW"
      case "$key" in
        u)
          COMPACT_FOLLOW=0; COMPACT_OFFSET=$((COMPACT_OFFSET - body_rows))
          [ "$COMPACT_OFFSET" -ge 0 ] || COMPACT_OFFSET=0
          DETAIL_REDRAW=1
          ;;
        d)
          COMPACT_FOLLOW=0; COMPACT_OFFSET=$((COMPACT_OFFSET + body_rows)); DETAIL_REDRAW=1
          ;;
        *) handle_key "$key" || break ;;
      esac
      if [ "$DETAIL_VIEW" != "$old_view" ]; then
        COMPACT_OFFSET=0; COMPACT_FOLLOW=0
        [ "$DETAIL_VIEW" != Timeline ] || COMPACT_FOLLOW=1
      fi
    fi
  done
}

usage() { printf 'usage: ai-monitor.sh {overview|detail|compact} <pane> [view] [--once]\n' >&2; exit 2; }

mode="${1:-}"; shift || true
pane="${1:-}"; shift || true
[ -n "$mode" ] && [ -n "$pane" ] || usage
open_run "$pane" || { printf 'tmux-radar: no active run for %s\n' "$pane" >&2; exit 1; }
once=0; view=Timeline
for arg in "$@"; do case "$arg" in --once) once=1 ;; Timeline|Decision|Screen|Config|Logs) view="$arg" ;; esac; done
case "$mode" in
  overview) overview_loop "$once" ;;
  detail) detail_loop "$once" "$view" ;;
  compact) compact_loop "$once" "$view" ;;
  *) usage ;;
esac

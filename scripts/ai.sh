#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2329
# tmux-radar AI supervisor — an AI (Codex) that watches the AI coding TUIs
# running inside your tmux panes (Claude Code / Codex), answers their prompts on
# your behalf, and arranges your tmux layout from natural language.
#
# Design principle: Codex is a READ-ONLY BRAIN. It never touches your system.
# This script is the only actor: it captures a pane, asks Codex for a structured
# decision, then — gated by an autonomy setting, a safety denylist, and an audit
# log — sends the keystrokes itself. Codex runs `-s read-only --ephemeral`, so a
# confused or adversarial answer can at most propose keys we still get to veto.
#
# Subcommands:
#   ask [<request>]     one-shot: arrange tmux from a natural-language request
#   decide [<pane>]     read one pane, decide the best reply, act once
#   watch <pane> [goal] [policy] [poll] [autonomy]
#                       resident: keep deciding for a pane until its task is done
#   watch-setup [<pane>] interactive setup (goal / interval / approval policy)
#   stop  <pane|all>    stop a resident watcher
#   status              list active watchers + recent decisions
#   list                list AI panes and their AI-status state
#   cleanup             GC stale watcher files / monitor panes / AI-status marks
#   menu                tmux display-menu entry point (prefix + <@radar-ai-key>)
#
# Config (tmux options, all optional):
#   @radar-ai-key            A                     menu key (prefix + A)
#   @radar-ai-model          gpt-5.3-codex-spark   Codex model slug (spark = fast tier)
#   @radar-ai-effort         low                   minimal|low|medium|high|xhigh
#   @radar-ai-profile        (none)                codex config profile (-p); overrides model/effort
#   @radar-ai-cmd            (none)                replace Codex entirely: shell cmd,
#                                                     prompt on stdin -> decision JSON on stdout
#   @radar-ai-autonomy       confirm               ask: suggest|confirm|auto
#   @radar-ai-watch-autonomy auto-safe             watch: auto-safe|suggest|auto
#   @radar-ai-poll           5                     watch: seconds between polls
#   @radar-ai-max-calls      40                    watch: cost cap on brain calls
#   @radar-ai-timeout        120                   hard limit for one brain call
#   @radar-ai-capture-lines  120                   pane lines fed to the brain
#   @radar-ai-monitor        on                    open companion monitor pane
#   @radar-ai-monitor-pos    top                   top|bottom|right
#   @radar-ai-monitor-size   12                    monitor height (top/bottom)
#   @radar-ai-monitor-size-h 60                    monitor width (right)
#   @radar-ai-monitor-layout split                 split|single
#   @radar-ai-monitor-excerpt-lines 16             pane-capture lines shown in monitor detail
#   @radar-ai-rules          (none)                file path OR literal text: user rules
#                                                     (what to auto-approve / always escalate),
#                                                     appended to every decide prompt; default
#                                                     file ~/.config/tmux-radar/rules.md
#   @radar-ai-prompt-dir     (none)                dir shadowing prompts/ (decide.md,
#                                                     control.md, *.schema.json) per file
#
# Testing seam: set TMUX_RADAR_AI_CMD to a shell snippet that reads the prompt
# on stdin and writes the decision JSON to stdout; Codex is then never called.
# (@radar-ai-cmd is the user-facing version of the same seam.)
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
# Interactive prompts use `read -e` (readline): canonical-mode reads erase CJK
# input by the BYTE (deleting one Chinese char took two+ presses and mangled
# the line). readline edits by character — but only under a UTF-8 locale.
case "${LC_ALL:-${LANG:-}}" in *[Uu][Tt][Ff]*) ;; *) export LANG=en_US.UTF-8 ;; esac
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
PROMPT_DIR="$SCRIPT_DIR/prompts"
AI_RUNTIME_LIB="$SCRIPT_DIR/lib/ai-runtime.sh"
NOTIFY="$SCRIPT_DIR/needinput-notify.sh"
[ -r "$AI_RUNTIME_LIB" ] || { echo "tmux-radar AI needs $AI_RUNTIME_LIB" >&2; exit 1; }
# shellcheck source=scripts/lib/ai-runtime.sh
. "$AI_RUNTIME_LIB"

STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
STATE_FILE="${TMUX_RADAR_NEEDINPUT_FILE:-${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}}"
WATCH_DIR="$STATE_DIR/ai-watch"
LOG="${TMUX_RADAR_AI_LOG:-${TMUX_SWITCHER_AI_LOG:-$STATE_DIR/ai.log}}"
mkdir -p "$STATE_DIR" "$WATCH_DIR"

# A resident watcher runs the brain in this shell, not inside command
# substitution, so its signal trap can always terminate the complete process
# tree. The pidfile is a second line of defence for `stop` and `cleanup`.
BRAIN_PID=""
BRAIN_PGID=""
BRAIN_PID_FILE=""
BRAIN_OUT_FILE=""
BRAIN_BOUND_PANE=""
BRAIN_RESULT=""
BRAIN_LAST_RC=0
BRAIN_LAST_STARTED=0
BRAIN_LAST_ELAPSED=0
BRAIN_LAST_TIMEOUT=0
BRAIN_LAST_PID=""
BRAIN_LAST_PGID=""
BRAIN_STOP_REASON=""

DECISION_JSON=""
DECISION_ACTION=""
DECISION_TEXT=""
DECISION_SAFE=0
DECISION_REASON=""
DECISION_KEYS=()
DECISION_SCHEMA_VALID=0
DECISION_SCHEMA_ERROR=""

WATCH_WAITER_PID=""
WATCH_TIMER_PID=""
WATCH_PANE=""
WATCH_WF=""
WATCH_STARTED=0
WATCH_POLL=5
WATCH_GOAL=""
WATCH_POLICY=""
WATCH_AUTONOMY="auto-safe"
WATCH_MAX_CALLS=40
WATCH_CALLS=0
WATCH_RETRY=0
WATCH_EVENT_ID=""
WATCH_PHASE="CREATED"
WATCH_STATUS="starting"
WATCH_FINALIZED=0
WATCH_DELIVERY_FINGERPRINT=""

DELIVERY_GATE_HELD=0
DELIVERY_GATE_TOKEN=""
DELIVERY_GATE_DIR=""
DELIVERY_PENDING_FILE=""

opt() {
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
have_tmux() { command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; }
need_jq()  { command -v jq >/dev/null 2>&1 || { echo "tmux-radar AI needs 'jq'." >&2; exit 3; }; }
have_brain() { [ -n "${TMUX_RADAR_AI_CMD:-${TMUX_SWITCHER_AI_CMD:-}}" ] || [ -n "$(opt @radar-ai-cmd '')" ] || command -v codex >/dev/null 2>&1; }
now()  { date '+%s'; }
audit() { printf '%s\t%s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

# ANSI palette for popup / feed output (never routed through tmux formats —
# some tmux builds vis-escape control chars in -F output).
CG=$'\033[1;32m'; CY=$'\033[33m'; CC=$'\033[1;36m'; CM=$'\033[1;35m'; CD=$'\033[2m'; CR=$'\033[0m'
_hdr() {  # _hdr <title> [subtitle] — one consistent reverse-video header
  printf '\033[7;1m %s \033[0m' "$1"
  [ -n "${2:-}" ] && printf '  %s%s%s' "$CD" "$2" "$CR"
  printf '\n\n'
}

readline_tty() {  # readline paints the editable line on stderr; keep it on tty.
  local __var="$1"
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    IFS= read -e -r "${__var?}" </dev/tty 2>/dev/tty || printf -v "$__var" ''
  else
    IFS= read -r "${__var?}" || printf -v "$__var" ''
  fi
}

# Prompt "skills" are plain files; @radar-ai-prompt-dir lets the user shadow
# any of them (decide.md / control.md / *.schema.json) with their own copies.
_skill_file() {
  local d; d="$(opt @radar-ai-prompt-dir '')"
  if [ -n "$d" ] && [ -r "$d/$1" ]; then printf '%s/%s' "$d" "$1"
  else printf '%s/%s' "$PROMPT_DIR" "$1"; fi
}
_skill() { cat "$(_skill_file "$1")" 2>/dev/null; }

# User approval rules — @radar-ai-rules is a file path (contents used) or a
# literal text block; falls back to ~/.config/tmux-radar/rules.md when unset.
# Appended to every decide prompt as the highest-priority section, so the user
# controls what gets auto-approved vs escalated without editing the plugin.
_user_rules() {
  local r; r="$(opt @radar-ai-rules '')"
  [ -z "$r" ] && [ -r "$HOME/.config/tmux-radar/rules.md" ] && r="$HOME/.config/tmux-radar/rules.md"
  [ -n "$r" ] || return 0
  [ -r "$r" ] && r="$(cat "$r" 2>/dev/null)"
  [ -n "$r" ] || return 0
  printf '\n\nUSER RULES (set by the user in their tmux config; when they conflict with the guidance above, the USER RULES win):\n%s' "$r"
}
_wf()  { printf '%s/%s.watch' "$WATCH_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
_wbase() { local wf; wf="$(_wf "$1")"; printf '%s' "${wf%.watch}"; }
_flat() { printf '%s' "$1" | tr '\n\t' '  '; }
_monitor_excerpt_lines() {
  local n; n="$(opt @radar-ai-monitor-excerpt-lines 16)"
  case "$n" in ''|*[!0-9]*) n=16 ;; esac
  [ "$n" -lt 3 ] && n=3
  printf '%s' "$n"
}

_pretty_json() {
  local json="$1"
  [ -n "$json" ] || { printf '<empty>'; return 0; }
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq . 2>/dev/null || printf '%s' "$json"
  else
    printf '%s' "$json"
  fi
}

_watch_file_tail() {  # _watch_file_tail <file> <keep-lines>
  local file="$1" keep="${2:-240}" n tmp
  [ -f "$file" ] || return 0
  n="$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  [ "${n:-0}" -le "$((keep + 40))" ] && return 0
  tmp="$(mktemp "${file}.XXXXXX")" || return 0
  if tail -n "$keep" "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

_watch_timeline() {  # _watch_timeline <pane> <kind> <message>
  local pane="$1" kind="$2" msg="$3" file
  file="$(_wbase "$pane").timeline"
  printf '%s  %-10s %s\n' "$(date '+%H:%M:%S')" "$kind" "$(_flat "$msg")" >> "$file" 2>/dev/null || true
  _watch_file_tail "$file" 240
}

_watch_detail() {  # _watch_detail <pane> <title> <body>
  local pane="$1" title="$2" body="$3" file log
  file="$(_wbase "$pane").detail"
  log="$(_wbase "$pane").detail.log"
  {
    printf '%s\n' "$title"
    printf '%s\n\n' "$(date '+%F %T')"
    printf '%s\n' "$body"
  } > "$file" 2>/dev/null || true
  {
    printf '\n===== %s · %s =====\n' "$(date '+%F %T')" "$title"
    printf '%s\n' "$body"
  } >> "$log" 2>/dev/null || true
  _watch_file_tail "$log" 1200
}

_watch_state_write() {  # pane started poll goal policy auto maxcalls calls quiet marked status next_at last_decision
  local pane="$1" started="$2" poll="$3" goal="$4" policy="$5" auto="$6" maxcalls="$7" calls="$8" quiet="$9"
  shift 9
  local marked="$1" status="$2" next_at="$3" last_decision="$4" wf tmp
  wf="$(_wf "$pane")"
  tmp="$(mktemp "${wf}.XXXXXX")" || return 0
  {
    printf 'pid=%s\npane=%s\nstarted=%s\npoll=%s\ngoal=%s\n' "$$" "$pane" "$started" "$poll" "$(_flat "$goal")"
    printf 'policy=%s\nautonomy=%s\nmaxcalls=%s\ncalls=%s\nquiet=%s\nmarked=%s\n' \
      "${policy:-safe-auto}" "$auto" "$maxcalls" "$calls" "$quiet" "$marked"
    printf 'status=%s\nnext_at=%s\nlast_decision=%s\nupdated=%s\n' \
      "$(_flat "$status")" "$next_at" "$last_decision" "$(now)"
  } > "$tmp" 2>/dev/null
  if [ -s "$tmp" ]; then
    mv "$tmp" "$wf" || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

_watch_pointer_write() {
  local wf="$WATCH_WF" tmp run_id run_dir channel overview detail
  [ -n "$wf" ] || return 0
  run_id="$(_state_get "$wf" run_id)"; [ -n "$run_id" ] || run_id="${RADAR_RUN_ID:-}"
  run_dir="$(_state_get "$wf" run_dir)"; [ -n "$run_dir" ] || run_dir="${RADAR_RUN_DIR:-}"
  channel="$(_state_get "$wf" channel)"; [ -n "$channel" ] || channel="${RADAR_RUN_CHANNEL:-}"
  overview="$(_state_get "$wf" monitor_overview_pane)"
  detail="$(_state_get "$wf" monitor_detail_pane)"
  tmp="$(mktemp "${wf}.XXXXXX")" || return 1
  {
    printf 'run_id=%s\nrun_dir=%s\nchannel=%s\n' "$run_id" "$run_dir" "$channel"
    printf 'monitor_overview_pane=%s\nmonitor_detail_pane=%s\n' "$overview" "$detail"
    printf 'pid=%s\npane=%s\nstarted=%s\ngoal=%s\npoll=%s\n' \
      "$$" "$WATCH_PANE" "$WATCH_STARTED" "$(_flat "$WATCH_GOAL")" "$WATCH_POLL"
    printf 'policy=%s\nautonomy=%s\nmaxcalls=%s\nmax_calls=%s\ncalls=%s\n' \
      "${WATCH_POLICY:-safe-auto}" "$WATCH_AUTONOMY" "$WATCH_MAX_CALLS" "$WATCH_MAX_CALLS" "$WATCH_CALLS"
    printf 'status=%s\nphase=%s\nretry=%s\nevent_id=%s\nnext_at=%s\nlast_decision=%s\nupdated=%s\n' \
      "$(_flat "$WATCH_STATUS")" "$WATCH_PHASE" "$WATCH_RETRY" "$WATCH_EVENT_ID" \
      "${WATCH_NEXT_AT:-0}" "${WATCH_LAST_DECISION:-}" "$(now)"
    printf 'quiet=0\nmarked=0\n'
  } > "$tmp"
  mv "$tmp" "$wf"
}

_watch_pointer_set_monitors() {
  local wf="$1" overview="${2:-}" detail="${3:-}" tmp
  [ -r "$wf" ] || return 0
  tmp="$(mktemp "${wf}.XXXXXX")" || return 1
  awk -F= -v overview="$overview" -v detail="$detail" '
    $1 == "monitor_overview_pane" { print "monitor_overview_pane=" overview; seen_overview=1; next }
    $1 == "monitor_detail_pane" { print "monitor_detail_pane=" detail; seen_detail=1; next }
    { print }
    END {
      if (!seen_overview) print "monitor_overview_pane=" overview
      if (!seen_detail) print "monitor_detail_pane=" detail
    }
  ' "$wf" > "$tmp"
  mv "$tmp" "$wf"
}

_watch_state_snapshot() {
  local extra="${1:-}" payload tmp
  [ -n "$extra" ] || extra='{}'
  [ -n "${RADAR_RUN_DIR:-}" ] || return 0
  payload="$(jq -c \
    --argjson extra "$extra" \
    --arg phase "$WATCH_PHASE" --arg status "$WATCH_STATUS" \
    --arg event_id "$WATCH_EVENT_ID" --arg goal "$WATCH_GOAL" \
    --arg policy "${WATCH_POLICY:-safe-auto}" --arg autonomy "$WATCH_AUTONOMY" \
    --argjson poll "$(awk -v p="$WATCH_POLL" 'BEGIN { printf "%.6f", p+0 }')" \
    --argjson calls "$WATCH_CALLS" --argjson max_calls "$WATCH_MAX_CALLS" \
    --argjson retry "$WATCH_RETRY" --argjson waiter_pid "${WATCH_WAITER_PID:-0}" \
    --argjson timer_pid "${WATCH_TIMER_PID:-0}" \
    --argjson model_started_at "${BRAIN_LAST_STARTED:-0}" \
    --argjson model_elapsed "${BRAIN_LAST_ELAPSED:-0}" \
    --argjson model_timeout "${BRAIN_LAST_TIMEOUT:-0}" \
    --argjson model_pid "${BRAIN_LAST_PID:-0}" \
    --argjson model_pgid "${BRAIN_LAST_PGID:-0}" \
    '. + $extra + {
      phase:$phase,status:$status,event_id:$event_id,goal:$goal,policy:$policy,
      autonomy:$autonomy,poll:$poll,calls:$calls,max_calls:$max_calls,retry:$retry,
      waiter_pid:$waiter_pid,timer_pid:$timer_pid,
      model:{started_at:$model_started_at,elapsed:$model_elapsed,pid:$model_pid,
             pgid:$model_pgid,timeout:$model_timeout,call_count:$calls}
    }' "$RADAR_RUN_DIR/state.json")" || return 1
  tmp="$(mktemp "$RADAR_RUN_DIR/.state.XXXXXX")" || return 1
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$RADAR_RUN_DIR/state.json"
  _watch_pointer_write
}

_watch_phase() {
  local phase="$1" status="$2" next_kind="${3:-none}" next_at="${4:-0}" extra="${5:-}"
  [ -n "$extra" ] || extra='{}'
  WATCH_PHASE="$phase"; WATCH_STATUS="$status"; WATCH_NEXT_AT="$next_at"
  radar_state_set "$phase" "$status" "$next_kind" "$next_at"
  _watch_state_snapshot "$extra"
  radar_event_append phase watcher "$status" "$(jq -cn \
    --arg phase "$phase" --arg event_id "$WATCH_EVENT_ID" --argjson retry "$WATCH_RETRY" \
    '{record:"phase",phase:$phase,event_id:$event_id,retry:$retry}')"
}

_watch_model_started() {
  BRAIN_LAST_STARTED="$1"; BRAIN_LAST_PID="$2"; BRAIN_LAST_PGID="$3"; BRAIN_LAST_TIMEOUT="$4"
  _watch_state_snapshot
  radar_event_append model_started watcher "model call $WATCH_CALLS started" "$(jq -cn \
    --arg event_id "$WATCH_EVENT_ID" --argjson call "$WATCH_CALLS" --argjson started "$1" \
    --argjson pid "$2" --argjson pgid "$3" --argjson timeout "$4" \
    '{record:"model",event_id:$event_id,call:$call,model_started_at:$started,pid:$pid,pgid:$pgid,timeout:$timeout}')"
}

_watch_model_finished() {
  _watch_state_snapshot
  radar_event_append model_finished watcher "model call $WATCH_CALLS finished" "$(jq -cn \
    --arg event_id "$WATCH_EVENT_ID" --argjson call "$WATCH_CALLS" --argjson elapsed "$BRAIN_LAST_ELAPSED" \
    --argjson rc "$BRAIN_LAST_RC" '{record:"model",event_id:$event_id,call:$call,elapsed:$elapsed,rc:$rc}')"
}

_state_get() {  # _state_get <watch-file> <key>
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null || true
}

_process_tree_pids() {  # _process_tree_pids <root-pid>; descendants first
  local root="$1"
  case "$root" in ''|*[!0-9]*) return 0 ;; esac
  ps -axo pid=,ppid= 2>/dev/null | awk -v root="$root" '
    { n++; pid[n]=$1; ppid[n]=$2 }
    END {
      keep[root]=1
      for (pass=1; pass<=n; pass++)
        for (i=1; i<=n; i++)
          if (keep[ppid[i]]) keep[pid[i]]=1
      for (i=n; i>=1; i--)
        if (pid[i] != root && keep[pid[i]]) print pid[i]
      print root
    }'
}

_terminate_process_tree() {  # _terminate_process_tree <root-pid> [process-group-id]
  local root="$1" pgid="${2:-}" tree pid alive
  case "$root" in ''|*[!0-9]*) return 0 ;; esac
  case "$pgid" in
    ''|*[!0-9]*|"$$") pgid="" ;;
  esac
  if [ -n "$pgid" ]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 -- "-$pgid" 2>/dev/null || break
      sleep 0.1
    done
    kill -0 -- "-$pgid" 2>/dev/null && kill -KILL -- "-$pgid" 2>/dev/null || true
    return 0
  fi
  tree="$(_process_tree_pids "$root")"
  [ -n "$tree" ] || tree="$root"
  for pid in $tree; do kill -TERM "$pid" 2>/dev/null || true; done
  for _ in 1 2 3 4 5; do
    alive=0
    for pid in $tree; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [ "$alive" -eq 0 ] && break
    sleep 0.1
  done
  # A CLI wrapper may ignore TERM or fail to forward it to its native child.
  # Kill every PID captured before the parent can orphan its descendants.
  for pid in $tree; do
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  done
}

_terminate_brain_file() {  # _terminate_brain_file <brain-pidfile>
  local file="$1" pid pgid output
  [ -r "$file" ] || return 0
  pid="$(_state_get "$file" pid)"
  pgid="$(_state_get "$file" pgid)"
  output="$(_state_get "$file" output)"
  _terminate_process_tree "$pid" "$pgid"
  [ -n "$output" ] && rm -f "$output"
  rm -f "$file"
}

# shellcheck disable=SC2329  # invoked from the watcher's signal trap
_terminate_current_brain() {
  local pid="${BRAIN_PID:-}" pgid="${BRAIN_PGID:-}" file="${BRAIN_PID_FILE:-}" output="${BRAIN_OUT_FILE:-}"
  [ -n "$pid" ] && _terminate_process_tree "$pid" "$pgid"
  [ -n "$output" ] && rm -f "$output"
  [ -n "$file" ] && rm -f "$file"
  BRAIN_PID=""
  BRAIN_PGID=""
  BRAIN_OUT_FILE=""
}

# shellcheck disable=SC2329  # invoked from the process-owner signal traps
_brain_owner_signal() {
  local rc="$1"
  trap - TERM INT HUP
  _delivery_cleanup
  _terminate_current_brain
  exit "$rc"
}
trap '_brain_owner_signal 143' TERM
trap '_brain_owner_signal 130' INT
trap '_brain_owner_signal 129' HUP

_clip_lines() {  # _clip_lines <width> <max-lines> [file]
  local width="$1" max="$2"
  awk -v w="$width" -v max="$max" '
    BEGIN { if (w < 12) w = 12 }
    {
      gsub(/\t/, "  ")
      if (length($0) > w) print substr($0, 1, w - 1) "…"
      else print
      n++
      if (n >= max) exit
    }'
}

_monitor_state_read() {  # sets monitor globals for a watch file
  local wf="$1"
  mon_now="$(now)"
  mon_poll="$(_state_get "$wf" poll)"
  mon_goal="$(_state_get "$wf" goal)"
  mon_policy="$(_state_get "$wf" policy)"
  mon_auto="$(_state_get "$wf" autonomy)"
  mon_maxcalls="$(_state_get "$wf" maxcalls)"
  mon_calls="$(_state_get "$wf" calls)"
  mon_quiet="$(_state_get "$wf" quiet)"
  mon_marked="$(_state_get "$wf" marked)"
  mon_status="$(_state_get "$wf" status)"
  mon_next_at="$(_state_get "$wf" next_at)"
  mon_updated="$(_state_get "$wf" updated)"
  mon_last_decision="$(_state_get "$wf" last_decision)"
  case "$mon_next_at" in ''|*[!0-9]*) mon_remain=0 ;; *) mon_remain=$((mon_next_at - mon_now)); [ "$mon_remain" -lt 0 ] && mon_remain=0 ;; esac
  case "$mon_status" in
    "calling model:"*) mon_next_label="after model + ${mon_poll:-?}s" ;;
    *) mon_next_label="${mon_remain}s" ;;
  esac
}

_monitor_draw_header() {  # _monitor_draw_header <mode> <label> <cols> <wf>
  local mode="$1" label="$2" cols="$3" wf="$4" sep
  _monitor_state_read "$wf"
  sep="$(printf '%*s' "$cols" '' | tr ' ' '-')"
  printf '\0337'
  printf '\033[1;1H\033[2K\033[7;1m AI monitor · %s \033[0m  %s%s%s' "$mode" "$CD" "$label" "$CR"
  printf '\033[2;1H\033[2Kstatus=%s%s%s · next=%s · calls=%s/%s · quiet=%s · mark=%s · poll=%ss · updated=%s' \
    "$CC" "${mon_status:-starting}" "$CR" "$mon_next_label" "${mon_calls:-0}" "${mon_maxcalls:-?}" "${mon_quiet:-0}" "${mon_marked:-0}" "${mon_poll:-?}" "${mon_updated:-?}"
  printf '\033[3;1H\033[2K'
  if [ -n "$mon_goal" ]; then
    printf '%sgoal: %s%s' "$CD" "$mon_goal" "$CR"
  else
    printf '%spolicy=%s autonomy=%s last-decision=%s%s' "$CD" "${mon_policy:-?}" "${mon_auto:-?}" "${mon_last_decision:-none}" "$CR"
  fi
  printf '\033[4;1H\033[2K%s%s%s' "$CD" "$sep" "$CR"
  printf '\0338'
}

_monitor_color_timeline() {
  awk -v CG="$CG" -v CY="$CY" -v CC="$CC" -v CM="$CM" -v CD="$CD" -v CR="$CR" '
    {
      kind=$2
      color=CD
      if (kind == "send" || kind == "done") color=CG
      else if (kind == "decide" || kind == "cooldown") color=CC
      else if (kind == "pause" || kind == "unknown" || kind == "escalate") color=CM
      else if (kind == "wait") color=CY
      printf "%s%s%s\n", color, $0, CR
    }'
}

_monitor_color_detail() {
  awk -v CC="$CC" -v CD="$CD" -v CR="$CR" '
    /^===== / { printf "%s%s%s\n", CC, $0, CR; next }
    /^(Backend|Target|Autonomy|Policy|Goal|Model JSON|Backend stderr|Pane excerpt|Parsed decision|Recent feed)/ {
      printf "%s%s%s\n", CD, $0, CR; next
    }
    { print }'
}

_monitor_emit_new() {  # _monitor_emit_new <mode> <file> <old-line-count> <width>
  local mode="$1" file="$2" old="$3" width="$4" total start
  monitor_emit_total="$old"
  [ -f "$file" ] || return 0
  total="$(wc -l < "$file" 2>/dev/null | tr -d '[:space:]' || echo 0)"
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  if [ "$total" -lt "$old" ]; then old=0; fi
  if [ "$total" -gt "$old" ]; then
    start=$((old + 1))
    case "$mode" in
      timeline)
        sed -n "${start},${total}p" "$file" 2>/dev/null | _clip_lines "$width" "$((total - old))" | _monitor_color_timeline
        ;;
      detail)
        sed -n "${start},${total}p" "$file" 2>/dev/null | _monitor_color_detail
        ;;
      *)
        sed -n "${start},${total}p" "$file" 2>/dev/null
        ;;
    esac
  fi
  monitor_emit_total="$total"
}

# Human-readable target for headers: "session:win.pane cmd" instead of "%160".
_pane_label() {
  tmux display-message -p -t "$1" '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null || printf '%s' "$1"
}

# Resolve a pane target -> canonical %id. Empty arg falls back to $TMUX_PANE,
# then to the most recently marked live pane in the AI-status state.
_resolve_pane() {
  local p="${1:-}"
  [ -z "$p" ] && p="${TMUX_PANE:-}"
  if [ -z "$p" ] && [ -r "$STATE_FILE" ]; then
    p="$(awk -F '\t' '$1 != "-" && NF >= 2 { if ($2+0 >= best) { best=$2+0; win=$1 } } END { print win }' "$STATE_FILE" 2>/dev/null || true)"
  fi
  [ -n "$p" ] || return 1
  tmux display-message -p -t "$p" '#{pane_id}' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Codex brain. _brain <schema-file> <prompt>  ->  final decision JSON on stdout.
# Codex is read-only + ephemeral; only its --output-schema'd last message is used.
# ---------------------------------------------------------------------------
_brain() {
  local schema="$1" prompt="$2" out custom profile err pid rc=0 started timeout stop_reason="" had_job_control=0
  BRAIN_RESULT=""
  BRAIN_LAST_RC=0
  BRAIN_LAST_STARTED=0
  BRAIN_LAST_ELAPSED=0
  BRAIN_LAST_TIMEOUT=0
  BRAIN_LAST_PID=""
  BRAIN_LAST_PGID=""
  BRAIN_STOP_REASON=""
  out="$(mktemp "${TMPDIR:-/tmp}/tmuxai.XXXXXX")"
  BRAIN_OUT_FILE="$out"
  err="${TMUX_RADAR_AI_ERR:-${TMUX_SWITCHER_AI_ERR:-/dev/null}}"
  [ "$err" = "/dev/null" ] || : > "$err" 2>/dev/null || true
  # env seam (tests) wins over the user-facing option; both replace codex with
  # any command that reads the prompt on stdin and prints decision JSON.
  custom="${TMUX_RADAR_AI_CMD:-${TMUX_SWITCHER_AI_CMD:-$(opt @radar-ai-cmd '')}}"
  case "$-" in *m*) had_job_control=1 ;; esac
  set -m
  if [ -n "$custom" ]; then
    (export TMUX_RADAR_INTERNAL=1; printf '%s' "$prompt" | eval "$custom" > "$out" 2>"$err") &
  elif [ -n "$(opt @radar-ai-profile '')" ]; then
    # a codex profile bundles model/effort/etc in ~/.codex/config.toml; the
    # safety flags (read-only, ephemeral) stay ours and are not overridable
    profile="$(opt @radar-ai-profile '')"
    TMUX_RADAR_INTERNAL=1 codex exec -p "$profile" \
      -s read-only --ephemeral --skip-git-repo-check \
      --output-schema "$schema" -o "$out" -- "$prompt" >/dev/null 2>"$err" &
  else
    TMUX_RADAR_INTERNAL=1 codex exec \
      -m "$(opt @radar-ai-model gpt-5.3-codex-spark)" \
      -c model_reasoning_effort="$(opt @radar-ai-effort low)" \
      -s read-only --ephemeral --skip-git-repo-check \
      --output-schema "$schema" -o "$out" -- "$prompt" >/dev/null 2>"$err" &
  fi
  BRAIN_PID=$!
  BRAIN_PGID="$BRAIN_PID"
  [ "$had_job_control" -eq 1 ] || set +m
  pid="$BRAIN_PID"
  started="$(now)"
  timeout="$(opt @radar-ai-timeout 120)"
  case "$timeout" in ''|*[!0-9]*) timeout=120 ;; esac
  [ "$timeout" -lt 5 ] && timeout=5
  BRAIN_LAST_STARTED="$started"
  BRAIN_LAST_TIMEOUT="$timeout"
  BRAIN_LAST_PID="$pid"
  BRAIN_LAST_PGID="$BRAIN_PGID"
  if [ -n "${BRAIN_PID_FILE:-}" ]; then
    {
      printf 'pid=%s\npgid=%s\nwatch_pid=%s\npane=%s\nstarted=%s\noutput=%s\n' \
        "$pid" "$BRAIN_PGID" "$$" "${BRAIN_BOUND_PANE:-}" "$started" "$out"
    } > "$BRAIN_PID_FILE"
  fi
  if [ -n "${RADAR_RUN_DIR:-}" ] && [ -n "${WATCH_EVENT_ID:-}" ]; then
    _watch_model_started "$started" "$pid" "$BRAIN_PGID" "$timeout"
  fi

  while kill -0 "$pid" 2>/dev/null; do
    if [ -n "${BRAIN_BOUND_PANE:-}" ] && \
       ! tmux display-message -p -t "$BRAIN_BOUND_PANE" '#{pane_id}' >/dev/null 2>&1; then
      stop_reason="target pane $BRAIN_BOUND_PANE disappeared"
      _terminate_process_tree "$pid" "$BRAIN_PGID"
      break
    fi
    if [ "$(( $(now) - started ))" -ge "$timeout" ]; then
      stop_reason="brain call exceeded ${timeout}s timeout"
      _terminate_process_tree "$pid" "$BRAIN_PGID"
      break
    fi
    sleep 0.2
  done
  if wait "$pid" 2>/dev/null; then rc=0; else rc=$?; fi
  BRAIN_LAST_RC="$rc"
  BRAIN_LAST_ELAPSED="$(( $(now) - started ))"
  BRAIN_STOP_REASON="$stop_reason"
  BRAIN_PID=""
  BRAIN_PGID=""
  [ -n "${BRAIN_PID_FILE:-}" ] && rm -f "$BRAIN_PID_FILE"
  if [ -n "$stop_reason" ]; then
    printf 'tmux-radar: %s\n' "$stop_reason" >> "$err" 2>/dev/null || true
    audit "brain-stop\t${BRAIN_BOUND_PANE:--}\t$stop_reason"
  elif [ "$rc" -ne 0 ]; then
    audit "brain-exit\t${BRAIN_BOUND_PANE:--}\trc=$rc"
  fi
  BRAIN_RESULT="$(cat "$out" 2>/dev/null || true)"
  rm -f "$out"
  BRAIN_OUT_FILE=""
  if [ -n "${RADAR_RUN_DIR:-}" ] && [ -n "${WATCH_EVENT_ID:-}" ]; then
    _watch_model_finished
  fi
}

_brain_label() {
  local custom profile
  custom="${TMUX_RADAR_AI_CMD:-${TMUX_SWITCHER_AI_CMD:-$(opt @radar-ai-cmd '')}}"
  if [ -n "$custom" ]; then
    printf 'custom command: %s' "$(_flat "$custom")"
  elif [ -n "$(opt @radar-ai-profile '')" ]; then
    profile="$(opt @radar-ai-profile '')"
    printf 'codex profile: %s (read-only, ephemeral)' "$profile"
  else
    printf 'codex exec: model=%s effort=%s (read-only, ephemeral)' \
      "$(opt @radar-ai-model gpt-5.3-codex-spark)" "$(opt @radar-ai-effort low)"
  fi
}

_escalate() { [ -x "$NOTIFY" ] && "$NOTIFY" mark "$1" ai "$2" >/dev/null 2>&1 || true; }
_clearmark() { [ -x "$NOTIFY" ] && "$NOTIFY" clear "$1" >/dev/null 2>&1 || true; }

# Send a decision to a pane: literal text (may contain spaces), then key names.
_send() {  # _send <pane> <text> <key> <key> ...
  local pane="$1" text="$2"; shift 2
  if [ -n "$text" ]; then
    tmux send-keys -t "$pane" -l -- "$text" 2>/dev/null || return 1
  fi
  local k
  for k in "$@"; do
    [ -n "$k" ] || continue
    tmux send-keys -t "$pane" "$k" 2>/dev/null || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# decide: evaluate one pane, return an action, and act on it once.
# Prints a human line; exit code encodes the action for the watch loop:
#   0 sent   2 done   3 wait/working   4 escalated   5 error   6 suggest-only
# $2 = autonomy (suggest|confirm|auto|auto-safe); default from @radar-ai-autonomy
# ---------------------------------------------------------------------------
cmd_decide() {
  need_jq
  have_brain || { echo "codex 未安装/不可用，无法决策。"; return 3; }
  local pane autonomy policy goal cap cap_tail where json pretty_json action text safe reason extra="" prompt backend
  local excerpt_lines errfile err_tail TMUX_RADAR_AI_ERR="" TMUX_SWITCHER_AI_ERR=""
  pane="$(_resolve_pane "${1:-}")" || { echo "no target pane"; return 5; }
  autonomy="${2:-$(opt @radar-ai-autonomy confirm)}"
  policy="${3:-}"
  goal="${4:-}"
  if [ -n "$goal" ]; then
    extra=$'\n\nGOAL (set by the user for this watch): '"$goal"$'\nSteer the pane toward completing this goal. If the pane asks a question whose answer is implied by the goal, answer it; only report `done` when the goal itself looks achieved.'
  fi
  if [ "$policy" = "always-allow" ]; then
    extra="$extra"$'\n\nPOLICY: watch-until-done with ALWAYS-ALLOW enabled. When the pending action is SAFE and the prompt offers a "Yes, and don\'t ask again" / "always allow" / "don\'t ask again for … commands" option, PREFER that option so the agent stops interrupting for this command type. Still escalate anything destructive or ambiguous; NEVER pick an always-allow option for an unsafe action.'
  fi
  extra="$extra$(_user_rules)"
  where="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null || echo "$pane")"
  cap="$(tmux capture-pane -p -t "$pane" -S "-$(opt @radar-ai-capture-lines 120)" 2>/dev/null || true)"
  [ -n "$cap" ] || { echo "pane $pane: nothing to read"; return 5; }
  excerpt_lines="$(_monitor_excerpt_lines)"
  cap_tail="$(printf '%s\n' "$cap" | tail -n "$excerpt_lines")"

  prompt="$(_skill decide.md)$extra"$'\n\n'"PANE ($where):"$'\n'"$cap"
  backend="$(_brain_label)"
  if [ -n "${TMUX_RADAR_AI_DETAIL:-${TMUX_SWITCHER_AI_DETAIL:-}}" ]; then
    errfile="$(_wbase "$pane").brain.err"
    _watch_detail "$pane" "模型请求中" "$(printf 'Backend: %s\nTarget: %s\nAutonomy: %s\nPolicy: %s\nGoal: %s\n\nPane excerpt shown here (last %s lines; model receives last %s lines):\n%s\n' \
      "$backend" "$where" "$autonomy" "${policy:-safe-auto}" "${goal:-<none>}" \
      "$excerpt_lines" "$(opt @radar-ai-capture-lines 120)" "$cap_tail")"
  fi
  if [ -n "${TMUX_RADAR_AI_DETAIL:-${TMUX_SWITCHER_AI_DETAIL:-}}" ]; then
    TMUX_RADAR_AI_ERR="$errfile"
    TMUX_SWITCHER_AI_ERR="$errfile"
  fi
  BRAIN_BOUND_PANE="$pane"
  BRAIN_PID_FILE="$(_wbase "$pane").brain.pid"
  _brain "$(_skill_file decide.schema.json)" "$prompt"
  json="$BRAIN_RESULT"
  BRAIN_BOUND_PANE=""
  BRAIN_PID_FILE=""
  pretty_json="$(_pretty_json "$json")"
  DECISION_SCHEMA_VALID=0
  DECISION_SCHEMA_ERROR="decision schema/type validation failed"
  if printf '%s' "$json" | jq -e '
    type == "object"
    and (.action | type == "string")
    and (.action == "send" or .action == "wait" or .action == "done" or .action == "escalate" or .action == "suggest")
    and (.text | type == "string")
    and (.keys | type == "array" and all(.[]; type == "string"))
    and (.safe | type == "boolean")
    and (.reason | type == "string")
  ' >/dev/null 2>&1; then
    DECISION_SCHEMA_VALID=1
    DECISION_SCHEMA_ERROR=""
  fi
  if [ "$DECISION_SCHEMA_VALID" -eq 1 ]; then
    action="$(printf '%s' "$json" | jq -r '.action')"
    text="$(printf '%s' "$json" | jq -r '.text')"
    safe="$(printf '%s' "$json" | jq -r 'if .safe == true then "1" else "0" end')"
    reason="$(printf '%s' "$json" | jq -r '.reason')"
  else
    action="unknown"; text=""; safe=0; reason="$DECISION_SCHEMA_ERROR"
  fi
  local keys=() _k                     # bash 3.2 (macOS) has no mapfile
  if [ "$DECISION_SCHEMA_VALID" -eq 1 ]; then
    while IFS= read -r _k; do [ -n "$_k" ] && keys+=("$_k"); done \
      < <(printf '%s' "$json" | jq -r '.keys[]')
  fi
  local plan; plan="$(printf 'text=%q keys=[%s]' "$text" "${keys[*]:-}")"

  DECISION_JSON="$json"
  DECISION_ACTION="$action"
  DECISION_TEXT="$text"
  DECISION_SAFE="$safe"
  DECISION_REASON="$reason"
  DECISION_KEYS=()
  for _k in ${keys[@]+"${keys[@]}"}; do DECISION_KEYS+=("$_k"); done

  if [ -n "${TMUX_RADAR_AI_DETAIL:-${TMUX_SWITCHER_AI_DETAIL:-}}" ]; then
    err_tail=""
    [ -n "${errfile:-}" ] && [ -s "$errfile" ] && err_tail="$(tail -n 20 "$errfile" 2>/dev/null || true)"
    _watch_detail "$pane" "最近一次模型决策" "$(
      printf 'Backend: %s\nTarget: %s\nAutonomy: %s\nPolicy: %s\nGoal: %s\n\n' \
        "$backend" "$where" "$autonomy" "${policy:-safe-auto}" "${goal:-<none>}"
      printf 'Parsed decision:\n  action: %s\n  safe: %s\n  reason: %s\n  plan: %s\n\n' \
        "$action" "$safe" "${reason:-<none>}" "$plan"
      printf 'Model JSON:\n%s\n\n' "$pretty_json"
      if [ -n "$err_tail" ]; then
        printf 'Backend stderr (last 20 lines):\n%s\n\n' "$err_tail"
      fi
      printf 'Pane excerpt shown here (last %s lines; model receives last %s lines):\n%s\n' \
        "$excerpt_lines" "$(opt @radar-ai-capture-lines 120)" "$cap_tail"
    )"
    _watch_timeline "$pane" "${action:-unknown}" "${reason:-no reason} · $plan"
  fi

  if [ "${TMUX_RADAR_DECIDE_PARSE_ONLY:-0}" = 1 ]; then
    case "$action" in
      send) return 0 ;;
      done) return 2 ;;
      wait) return 3 ;;
      escalate) return 4 ;;
      suggest) return 6 ;;
      *) return 5 ;;
    esac
  fi

  case "$action" in
    wait)  printf '%s· %s 仍在工作%s — %s\n' "$CD" "$pane" "$CR" "$reason"; return 3 ;;
    done)  printf '%s✓ %s 任务完成%s — %s\n' "$CG" "$pane" "$CR" "$reason"; _clearmark "$pane"; return 2 ;;
    suggest) printf '%s→ %s 建议:%s %s\n' "$CC" "$pane" "$CR" "$reason"; return 6 ;;
    unknown|"") printf '%s? %s 无法判读%s — %s\n' "$CY" "$pane" "$CR" "$reason"; return 5 ;;
  esac
  # action == send (or escalate)
  if [ "$action" = "escalate" ] || [ "$safe" = "0" ]; then
    printf '%s⚠ %s 需要你来定%s — %s\n' "$CM" "$pane" "$CR" "$reason"; _escalate "$pane" "AI 拿不准: $reason"
    audit "escalate\t$pane\t$reason"; return 4
  fi
  case "$autonomy" in
    suggest)
      printf '%s→ %s 建议发送:%s %s   %s(%s)%s\n' "$CC" "$pane" "$CR" "$plan" "$CD" "$reason" "$CR"
      audit "suggest\t$pane\t$plan\t$reason"; return 6 ;;
    confirm)
      printf '%s→ %s:%s %s\n   发送: %s\n' "$CC" "$pane" "$CR" "$reason" "$plan"
      printf '   执行? [y/N] '; local ans=""; readline_tty ans
      case "$ans" in y|Y|yes) ;; *) printf '   %s已跳过%s\n' "$CD" "$CR"; return 6 ;; esac ;;
    auto-safe|auto) : ;;   # safe already ensured above
    *) echo "unknown autonomy: $autonomy" >&2; return 5 ;;
  esac
  if ! _send "$pane" "$text" ${keys[@]+"${keys[@]}"}; then
    printf '%s⚠ %s 发送失败%s — %s\n' "$CM" "$pane" "$CR" "$plan"
    audit "send-failed\t$pane\t$plan\t$reason"
    return 5
  fi
  printf '%s✓ %s 已发送:%s %s   %s(%s)%s\n' "$CG" "$pane" "$CR" "$plan" "$CD" "$reason" "$CR"; _clearmark "$pane"
  audit "send\t$pane\t$plan\t$reason"; return 0
}

# ---------------------------------------------------------------------------
# watch: serialized event-driven supervisor. Native inbox events are the
# decision identity; screen fingerprints are used only for idle fallback and
# post-send verification.
# ---------------------------------------------------------------------------
_watch_fingerprint() {
  tmux capture-pane -p -t "$WATCH_PANE" -S "-$(opt @radar-ai-capture-lines 120)" 2>/dev/null |
    cksum | awk '{print $1 ":" $2}'
}

_watch_kill_waiters() {
  local pid
  for pid in "${WATCH_WAITER_PID:-}" "${WATCH_TIMER_PID:-}"; do
    case "$pid" in ''|0|*[!0-9]*) continue ;; esac
    _terminate_process_tree "$pid" ""
    wait "$pid" 2>/dev/null || true
  done
  WATCH_WAITER_PID=""; WATCH_TIMER_PID=""
  [ -n "${WATCH_WAITER_DONE:-}" ] && rm -f "$WATCH_WAITER_DONE"
  [ -n "${WATCH_TIMER_DONE:-}" ] && rm -f "$WATCH_TIMER_DONE"
}

_watch_start_waiter() {
  WATCH_WAITER_DONE="$RADAR_RUN_DIR/.waiter.$$"
  rm -f "$WATCH_WAITER_DONE"
  (tmux wait-for "$RADAR_RUN_CHANNEL" >/dev/null 2>&1 || true; : > "$WATCH_WAITER_DONE") &
  WATCH_WAITER_PID=$!
}

_watch_start_timer() {
  local delay="$1"
  WATCH_TIMER_DONE="$RADAR_RUN_DIR/.timer.$$"
  rm -f "$WATCH_TIMER_DONE"
  (sleep "$delay"; : > "$WATCH_TIMER_DONE") &
  WATCH_TIMER_PID=$!
}

_watch_wait_delay() {
  local delay="$1" tick="${TMUX_RADAR_TEST_WAIT_TICK:-0.05}"
  _watch_start_timer "$delay"
  _watch_state_snapshot
  while [ ! -e "$WATCH_TIMER_DONE" ]; do
    tmux display-message -p -t "$WATCH_PANE" '#{pane_id}' >/dev/null 2>&1 || {
      _watch_kill_waiters
      return 1
    }
    sleep "$tick"
  done
  _watch_kill_waiters
}

_watch_event_seen() {
  local event_id="$1"
  jq -e --arg event_id "$event_id" \
    'select(.record == "incoming" and .event_id == $event_id)' \
    "$RADAR_RUN_DIR/events.jsonl" >/dev/null 2>&1
}

_watch_event_id() {
  local seed="$1" sum
  sum="$(printf '%s' "$seed" | cksum | awk '{print $1 "-" $2}')"
  printf 'radar-%s-%s' "$RADAR_RUN_ID" "$sum"
}

_watch_next_event_order() {
  local lock="$RADAR_RUN_DIR/.event-order.lock" counter="$RADAR_RUN_DIR/.event-order"
  local attempt=0 value=0 tmp
  while ! mkdir "$lock" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 200 ] || return 1
    sleep 0.005
  done
  [ -s "$counter" ] && value="$(cat "$counter" 2>/dev/null || echo 0)"
  case "$value" in ''|*[!0-9]*) value=0 ;; esac
  value=$((value + 1))
  tmp="$(mktemp "$RADAR_RUN_DIR/.event-order.XXXXXX")" || { rmdir "$lock"; return 1; }
  printf '%s\n' "$value" > "$tmp"
  mv "$tmp" "$counter"
  rmdir "$lock"
  printf '%s' "$value"
}

_delivery_owner_field() {
  local owner="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$owner" 2>/dev/null || true
}

_delivery_gate_reap_stale() {
  local gate="$1" observed_pid observed_token tomb moved_token
  [ -r "$gate" ] || return 1
  observed_pid="$(_delivery_owner_field "$gate" pid)"
  observed_token="$(_delivery_owner_field "$gate" token)"
  case "$observed_pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$observed_pid" 2>/dev/null && return 1
  [ -n "$observed_token" ] || return 1

  tomb="${gate}.stale.${observed_token}.$$"
  if ! mv "$gate" "$tomb" 2>/dev/null; then return 1; fi
  moved_token="$(_delivery_owner_field "$tomb" token)"
  if [ "$moved_token" = "$observed_token" ]; then
    rm -rf "$tomb"
    return 0
  fi

  # The owner changed between observation and rename. Restore that live lock
  # instead of deleting it; acquisitions only proceed while the canonical path
  # exists, so no new owner can enter before this restoration attempt.
  if [ ! -e "$gate" ]; then mv "$tomb" "$gate" 2>/dev/null || true; fi
  return 1
}

_delivery_gate_acquire() {
  local attempts="${TMUX_RADAR_TEST_GATE_ATTEMPTS:-500}" attempt=0 pid token private written_pid written_token
  [ -n "${RADAR_RUN_DIR:-}" ] || return 1
  case "$attempts" in ''|*[!0-9]*) attempts=500 ;; esac
  [ "$attempts" -gt 0 ] || attempts=1
  DELIVERY_GATE_DIR="$RADAR_RUN_DIR/.delivery-gate"
  token="$$-${RANDOM:-0}-$(date '+%s')"
  private="$RADAR_RUN_DIR/.delivery-owner.$token"
  if [ "${TMUX_RADAR_TEST_GATE_OWNER_WRITE_FAIL:-0}" = 1 ] || \
     ! printf 'pid=%s\ntoken=%s\ncreated=%s\n' "$$" "$token" "$(date '+%s')" > "$private"; then
    rm -f "$private"
    DELIVERY_GATE_DIR=""
    return 1
  fi
  written_pid="$(_delivery_owner_field "$private" pid)"
  written_token="$(_delivery_owner_field "$private" token)"
  if [ "$written_pid" != "$$" ] || [ "$written_token" != "$token" ]; then
    rm -f "$private"
    DELIVERY_GATE_DIR=""
    return 1
  fi
  while [ "$attempt" -lt "$attempts" ]; do
    if ln "$private" "$DELIVERY_GATE_DIR" 2>/dev/null; then
      rm -f "$private"
      DELIVERY_GATE_TOKEN="$token"
      DELIVERY_GATE_HELD=1
      return 0
    fi
    if [ -r "$DELIVERY_GATE_DIR" ]; then
      pid="$(_delivery_owner_field "$DELIVERY_GATE_DIR" pid)"
      case "$pid" in ''|*[!0-9]*) : ;; *)
        if ! kill -0 "$pid" 2>/dev/null; then _delivery_gate_reap_stale "$DELIVERY_GATE_DIR" || true; fi
        ;;
      esac
    fi
    attempt=$((attempt + 1))
    sleep 0.01
  done
  rm -f "$private"
  DELIVERY_GATE_HELD=0
  DELIVERY_GATE_TOKEN=""
  return 1
}

_delivery_gate_release() {
  local current
  [ "${DELIVERY_GATE_HELD:-0}" -eq 1 ] || return 0
  current="$(_delivery_owner_field "$DELIVERY_GATE_DIR" token)"
  if [ -n "$DELIVERY_GATE_TOKEN" ] && [ "$current" = "$DELIVERY_GATE_TOKEN" ]; then
    rm -f "$DELIVERY_GATE_DIR"
  fi
  DELIVERY_GATE_HELD=0
  DELIVERY_GATE_TOKEN=""
  DELIVERY_GATE_DIR=""
}

_delivery_cleanup() {
  _delivery_gate_release
  if [ -n "${DELIVERY_PENDING_FILE:-}" ]; then rm -f "$DELIVERY_PENDING_FILE"; fi
  DELIVERY_PENDING_FILE=""
}

_delivery_pending_exists() {
  local pending
  for pending in "$RADAR_RUN_DIR"/.delivery-pending.*; do
    [ -e "$pending" ] && return 0
  done
  return 1
}

_delivery_wait_for_publishers() {
  local attempt=0 max="${TMUX_RADAR_TEST_GATE_ATTEMPTS:-500}" tick="${TMUX_RADAR_TEST_WAIT_TICK:-0.05}"
  case "$max" in ''|*[!0-9]*) max=500 ;; esac
  while _delivery_pending_exists; do
    tmux display-message -p -t "$WATCH_PANE" '#{pane_id}' >/dev/null 2>&1 || return 2
    attempt=$((attempt + 1))
    [ "$attempt" -lt "$max" ] || return 1
    sleep "$tick"
  done
}

_watch_event_priority() {
  case "$1" in
    approval|input_required) printf '0' ;;
    turn_complete) printf '1' ;;
    idle|screen_idle|manual_reassess) printf '2' ;;
    *) printf '3' ;;
  esac
}

_watch_event_actionable() {
  case "$1" in approval|input_required|turn_complete) return 0 ;; *) return 1 ;; esac
}

_watch_normalize_event() {
  local event="$1" event_id
  event_id="$(printf '%s' "$event" | jq -r '.event_id // empty')"
  [ -n "$event_id" ] || event_id="$(_watch_event_id "$event")"
  printf '%s' "$event" | jq -c --arg event_id "$event_id" '. + {event_id:$event_id}'
}

_watch_record_incoming() {
  local event="$1" event_id kind source label extra
  event="$(_watch_normalize_event "$event")"
  event_id="$(printf '%s' "$event" | jq -r '.event_id')"
  kind="$(printf '%s' "$event" | jq -r '.kind // "manual_reassess"')"
  source="$(printf '%s' "$event" | jq -r '.source // "unknown"')"
  label="$(printf '%s' "$event" | jq -r '.label // .kind // "event"')"
  _watch_event_seen "$event_id" && return 1
  extra="$(printf '%s' "$event" | jq -c --arg event_id "$event_id" '. + {record:"incoming",event_id:$event_id}')"
  radar_event_append "$kind" "$source" "$label" "$extra"
  printf '%s' "$event" | jq -c --arg event_id "$event_id" '. + {event_id:$event_id}'
}

_watch_coalesce_batch() {
  local batch="$1" accepted="$RADAR_RUN_DIR/.accepted.$$" unique="$RADAR_RUN_DIR/.unique.$$"
  local retained="$RADAR_RUN_DIR/.retained.$$" event normalized kind event_id winner_id winner_kind
  local winner_priority event_priority winner_actionable=0
  : > "$accepted"
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    normalized="$(_watch_normalize_event "$event")" || continue
    _watch_event_seen "$(printf '%s' "$normalized" | jq -r '.event_id')" && continue
    printf '%s\n' "$normalized" >> "$accepted"
  done < "$batch"
  if [ -s "$accepted" ]; then
    jq -s -c 'unique_by(.event_id)[]' "$accepted" > "$unique"
    mv "$unique" "$accepted"
  fi
  if [ ! -s "$accepted" ]; then
    rm -f "$accepted"
    return 11
  fi
  if jq -e 'select(.kind == "user_resumed")' "$accepted" >/dev/null 2>&1; then
    : > "$retained"
    while IFS= read -r event; do
      kind="$(printf '%s' "$event" | jq -r '.kind')"
      case "$kind" in
        user_resumed)
          _watch_record_incoming "$event" >/dev/null || true
          ;;
        approval|input_required)
          normalized="$(_watch_record_incoming "$event")" || true
          radar_event_append superseded watcher "superseded by user_resumed" "$(printf '%s' "$event" | jq -c \
            '{record:"superseded",event_id:.event_id,supersedes_event_id:.event_id,supersedes_kind:.kind,reason:"user_resumed"}')"
          ;;
        *) printf '%s\n' "$event" >> "$retained" ;;
      esac
    done < "$accepted"
    _watch_requeue_file "$retained"
    rm -f "$accepted" "$retained"
    return 10
  fi
  WATCH_EVENT_JSON="$(jq -s -c '
    def actionable: .kind == "approval" or .kind == "input_required" or .kind == "turn_complete";
    . as $events
    | ($events | map(select(actionable))) as $actionable
    | (if ($actionable | length) > 0 then $actionable else $events end)
    | max_by([(.event_order // 0), (.timestamp // ""), (.event_id // "")])
  ' "$accepted")"
  winner_id="$(printf '%s' "$WATCH_EVENT_JSON" | jq -r '.event_id')"
  winner_kind="$(printf '%s' "$WATCH_EVENT_JSON" | jq -r '.kind')"
  winner_priority="$(_watch_event_priority "$winner_kind")"
  _watch_event_actionable "$winner_kind" && winner_actionable=1
  normalized="$(_watch_record_incoming "$WATCH_EVENT_JSON")" || { rm -f "$accepted"; return 11; }
  WATCH_EVENT_JSON="$normalized"
  WATCH_EVENT_ID="$winner_id"
  : > "$retained"
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    event_id="$(printf '%s' "$event" | jq -r '.event_id')"
    [ "$event_id" = "$winner_id" ] && continue
    kind="$(printf '%s' "$event" | jq -r '.kind')"
    event_priority="$(_watch_event_priority "$kind")"
    if { [ "$winner_actionable" -eq 1 ] && _watch_event_actionable "$kind"; } || \
       { [ "$winner_actionable" -eq 0 ] && [ "$event_priority" = "$winner_priority" ]; }; then
      _watch_record_incoming "$event" >/dev/null || continue
      radar_event_append coalesced watcher "coalesced into $winner_id" "$(printf '%s' "$event" | jq -c \
        --arg winner "$winner_id" '{record:"coalesced",event_id:.event_id,original_kind:.kind,coalesced_into_event_id:$winner}')"
    else
      radar_event_append requeued watcher "retained after burst winner $winner_id" "$(printf '%s' "$event" | jq -c \
        --arg winner "$winner_id" '{record:"requeued",event_id:.event_id,original_kind:.kind,after_event_id:$winner}')"
      printf '%s\n' "$event" >> "$retained"
    fi
  done < "$accepted"
  _watch_requeue_file "$retained"
  rm -f "$accepted" "$unique" "$retained"
}

_watch_wait_for_batch() {
  local batch="$1" tick="${TMUX_RADAR_TEST_WAIT_TICK:-0.05}"
  : > "$batch"
  _watch_start_waiter
  _watch_start_timer "$WATCH_POLL"
  _watch_state_snapshot
  # The waiter is installed before the durable inbox is inspected. If the
  # signal raced with waiter startup, the durable file is still claimed here.
  radar_inbox_drain > "$batch"
  if [ -s "$batch" ]; then
    _watch_kill_waiters
    return 0
  fi
  while :; do
    tmux display-message -p -t "$WATCH_PANE" '#{pane_id}' >/dev/null 2>&1 || {
      _watch_kill_waiters
      return 2
    }
    if [ -e "$WATCH_TIMER_DONE" ]; then
      _watch_kill_waiters
      return 1
    fi
    if [ -e "$WATCH_WAITER_DONE" ]; then
      _terminate_process_tree "$WATCH_WAITER_PID" ""
      wait "$WATCH_WAITER_PID" 2>/dev/null || true
      WATCH_WAITER_PID=""
      rm -f "$WATCH_WAITER_DONE"
      # Re-arm before draining so an event that lands during this drain is
      # either signalled to the new waiter or remains durable for the next one.
      _watch_start_waiter
      _watch_state_snapshot
      radar_inbox_drain > "$batch"
      if [ -s "$batch" ]; then
        _watch_kill_waiters
        return 0
      fi
    fi
    sleep "$tick"
  done
}

_watch_retry_batch() {
  local batch="$1" current_kind="$2" retained="$RADAR_RUN_DIR/.retry-retained.$$"
  local event normalized kind
  [ -s "$batch" ] || return 1
  if ! jq -e 'select(.kind == "user_resumed")' "$batch" >/dev/null 2>&1; then
    _watch_requeue_file "$batch"
    return 1
  fi
  : > "$retained"
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    normalized="$(_watch_normalize_event "$event")" || continue
    kind="$(printf '%s' "$normalized" | jq -r '.kind')"
    case "$kind" in
      user_resumed) _watch_record_incoming "$normalized" >/dev/null || true ;;
      approval|input_required)
        _watch_record_incoming "$normalized" >/dev/null || true
        radar_event_append superseded watcher "superseded during retry backoff" "$(printf '%s' "$normalized" | jq -c \
          '{record:"superseded",event_id:.event_id,supersedes_event_id:.event_id,supersedes_kind:.kind,reason:"user_resumed"}')"
        ;;
      *) printf '%s\n' "$normalized" >> "$retained" ;;
    esac
  done < "$batch"
  _watch_requeue_file "$retained"
  rm -f "$retained"
  _watch_supersede_current user_resumed "$current_kind"
  radar_event_append retry_cancelled watcher "retry cancelled by user_resumed" "$(jq -cn \
    --arg event_id "$WATCH_EVENT_ID" --argjson retry "$WATCH_RETRY" \
    '{record:"retry_cancelled",event_id:$event_id,retry:$retry,reason:"user_resumed"}')"
  return 10
}

_watch_retry_delay() {
  local retry="$1" current_kind="$2" schedule="${TMUX_RADAR_TEST_RETRY_DELAYS:-15,30,60}"
  local old_ifs="$IFS" delay tick="${TMUX_RADAR_TEST_WAIT_TICK:-0.05}"
  local batch="$RADAR_RUN_DIR/.retry-batch.$$" batch_rc
  IFS=,
  # Intentional field splitting turns the comma-separated test seam into the
  # three fixed production retry slots without arrays or Bash 4 features.
  # shellcheck disable=SC2086
  set -- $schedule
  IFS="$old_ifs"
  case "$retry" in 1) delay="${1:-15}" ;; 2) delay="${2:-30}" ;; *) delay="${3:-60}" ;; esac
  : > "$batch"
  _watch_start_waiter
  _watch_start_timer "$delay"
  _watch_state_snapshot
  radar_inbox_drain > "$batch"
  while :; do
    if [ -s "$batch" ]; then
      set +e; _watch_retry_batch "$batch" "$current_kind"; batch_rc=$?; set -e
      : > "$batch"
      if [ "$batch_rc" -eq 10 ]; then
        _watch_kill_waiters; rm -f "$batch"; return 10
      fi
    fi
    tmux display-message -p -t "$WATCH_PANE" '#{pane_id}' >/dev/null 2>&1 || {
      _watch_kill_waiters; rm -f "$batch"; return 2
    }
    if [ -e "$WATCH_TIMER_DONE" ]; then
      _watch_kill_waiters; rm -f "$batch"; return 0
    fi
    if [ -e "$WATCH_WAITER_DONE" ]; then
      _terminate_process_tree "$WATCH_WAITER_PID" ""
      wait "$WATCH_WAITER_PID" 2>/dev/null || true
      WATCH_WAITER_PID=""; rm -f "$WATCH_WAITER_DONE"
      _watch_start_waiter
      _watch_state_snapshot
      radar_inbox_drain > "$batch"
    fi
    sleep "$tick"
  done
}

_watch_requeue_file() {
  local file="$1" event kind source label extra
  [ -s "$file" ] || return 0
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    kind="$(printf '%s' "$event" | jq -r '.kind')"
    source="$(printf '%s' "$event" | jq -r '.source // "unknown"')"
    label="$(printf '%s' "$event" | jq -r '.label // .kind')"
    extra="$(printf '%s' "$event" | jq -c '{event_id:.event_id,event_order:(.event_order // 0)}')"
    radar_inbox_append "$kind" "$source" "$label" "$extra"
  done < "$file"
}

_watch_supersede_current() {
  local reason="$1" current_kind="$2"
  radar_event_append superseded watcher "$reason" "$(jq -cn \
    --arg event_id "$WATCH_EVENT_ID" --arg kind "$current_kind" --arg reason "$reason" \
    '{record:"superseded",event_id:$event_id,supersedes_event_id:$event_id,supersedes_kind:$kind,reason:$reason}')"
}

_watch_post_decision_guard() {
  local pre="$1" current_kind="$2" batch="$RADAR_RUN_DIR/.post-decision.$$"
  local retained="$RADAR_RUN_DIR/.post-retained.$$" event normalized kind current
  : > "$batch"; : > "$retained"
  # Re-arm before the post-model drain. Signals emitted while the model was
  # running remain durable, and a new signal racing this drain is latched.
  _watch_start_waiter
  _watch_state_snapshot
  radar_inbox_drain > "$batch"
  _watch_kill_waiters
  if [ -s "$batch" ] && jq -e 'select(.kind == "user_resumed")' "$batch" >/dev/null 2>&1; then
    while IFS= read -r event; do
      [ -n "$event" ] || continue
      normalized="$(_watch_normalize_event "$event")" || continue
      kind="$(printf '%s' "$normalized" | jq -r '.kind')"
      case "$kind" in
        user_resumed)
          _watch_record_incoming "$normalized" >/dev/null || true
          ;;
        approval|input_required)
          _watch_record_incoming "$normalized" >/dev/null || true
          radar_event_append superseded watcher "superseded by user_resumed after decision" "$(printf '%s' "$normalized" | jq -c \
            '{record:"superseded",event_id:.event_id,supersedes_event_id:.event_id,supersedes_kind:.kind,reason:"user_resumed"}')"
          ;;
        *) printf '%s\n' "$normalized" >> "$retained" ;;
      esac
    done < "$batch"
    _watch_requeue_file "$retained"
    _watch_supersede_current user_resumed "$current_kind"
    rm -f "$batch" "$retained"
    return 10
  fi
  # No takeover event: preserve every event for the next serialized cycle.
  _watch_requeue_file "$batch"
  current="$(_watch_fingerprint || true)"
  rm -f "$batch" "$retained"
  if [ -z "$current" ]; then return 2; fi
  if [ "$current" != "$pre" ]; then
    _watch_supersede_current evidence_changed "$current_kind"
    return 12
  fi
  return 0
}

_watch_verification_batch() {
  local batch="$1" deferred="$2" event normalized has_resume=0
  [ -s "$batch" ] || return 1
  jq -e 'select(.kind == "user_resumed")' "$batch" >/dev/null 2>&1 && has_resume=1
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    if [ "$has_resume" -eq 1 ] && [ "$(printf '%s' "$event" | jq -r '.kind')" = user_resumed ]; then
      normalized="$(_watch_record_incoming "$event")" || true
      continue
    fi
    if [ "$has_resume" -eq 1 ]; then
      case "$(printf '%s' "$event" | jq -r '.kind')" in
        approval|input_required)
          normalized="$(_watch_record_incoming "$event")" || true
          radar_event_append superseded watcher "superseded during verification" "$(printf '%s' "$event" | jq -c \
            '{record:"superseded",event_id:.event_id,supersedes_event_id:.event_id,supersedes_kind:.kind,reason:"user_resumed"}')"
          continue
          ;;
      esac
    fi
    printf '%s\n' "$event" >> "$deferred"
  done < "$batch"
  [ "$has_resume" -eq 1 ]
}

_watch_verify_send() {
  local pre="$1" timeout="${TMUX_RADAR_TEST_VERIFY_TIMEOUT:-$(opt @radar-ai-verify-timeout 30)}"
  local tick="${TMUX_RADAR_TEST_WAIT_TICK:-0.05}" batch="$RADAR_RUN_DIR/.verify-batch.$$"
  local deferred="$RADAR_RUN_DIR/.verify-deferred.$$" reason="timeout" current
  : > "$batch"; : > "$deferred"
  _watch_phase VERIFYING "waiting for send effect" verification 0 "$(jq -cn --arg pre "$pre" '{verification:{pre_send_fingerprint:$pre}}')"
  _watch_start_waiter
  _watch_start_timer "$timeout"
  _watch_state_snapshot "$(jq -cn --arg pre "$pre" '{verification:{pre_send_fingerprint:$pre}}')"
  radar_inbox_drain > "$batch"
  if _watch_verification_batch "$batch" "$deferred"; then reason="user_resumed"; else :; fi
  while [ "$reason" = timeout ]; do
    tmux display-message -p -t "$WATCH_PANE" '#{pane_id}' >/dev/null 2>&1 || {
      reason="pane_death"; break
    }
    current="$(_watch_fingerprint || true)"
    if [ -n "$current" ] && [ "$current" != "$pre" ]; then reason="screen_change"; break; fi
    [ -e "$WATCH_TIMER_DONE" ] && break
    if [ -e "$WATCH_WAITER_DONE" ]; then
      _terminate_process_tree "$WATCH_WAITER_PID" ""
      wait "$WATCH_WAITER_PID" 2>/dev/null || true
      WATCH_WAITER_PID=""; rm -f "$WATCH_WAITER_DONE"
      _watch_start_waiter
      _watch_state_snapshot "$(jq -cn --arg pre "$pre" '{verification:{pre_send_fingerprint:$pre}}')"
      radar_inbox_drain > "$batch"
      if _watch_verification_batch "$batch" "$deferred"; then reason="user_resumed"; break; fi
    fi
    sleep "$tick"
  done
  _watch_kill_waiters
  _watch_requeue_file "$deferred"
  rm -f "$batch" "$deferred"
  radar_event_append verification_completed watcher "$reason" "$(jq -cn \
    --arg event_id "$WATCH_EVENT_ID" --arg reason "$reason" --arg pre "$pre" \
    '{record:"verification",event_id:$event_id,result:$reason,pre_send_fingerprint:$pre}')"
  case "$reason" in
    pane_death) return 2 ;;
    timeout)
      _watch_phase PAUSED_ERROR "verification timeout: no observable send effect" none 0
      radar_event_append verification_warning watcher "verification timeout" "$(jq -cn \
        --arg event_id "$WATCH_EVENT_ID" --arg pre "$pre" \
        '{record:"verification_warning",event_id:$event_id,result:"timeout",pre_send_fingerprint:$pre}')"
      return 3
      ;;
    *) return 0 ;;
  esac
}

_watch_pre_send_test_seam() {
  local block="${TMUX_RADAR_TEST_PRE_SEND_BLOCK:-}" tick="${TMUX_RADAR_TEST_WAIT_TICK:-0.05}"
  [ -n "$block" ] || return 0
  printf 'ready\n' > "$block.ready"
  while [ -e "$block" ]; do
    tmux display-message -p -t "$WATCH_PANE" '#{pane_id}' >/dev/null 2>&1 || return 2
    sleep "$tick"
  done
  rm -f "$block.ready"
}

_watch_deliver_under_gate() {
  local evidence="$1" current_kind="$2" guard_rc seam_rc wait_rc delivery
  WATCH_DELIVERY_FINGERPRINT=""
  if ! _delivery_gate_acquire; then return 20; fi

  while :; do
    set +e; _watch_post_decision_guard "$evidence" "$current_kind"; guard_rc=$?; set -e
    case "$guard_rc" in
      0) : ;;
      *) _delivery_gate_release; return "$guard_rc" ;;
    esac

    set +e; _watch_pre_send_test_seam; seam_rc=$?; set -e
    if [ "$seam_rc" -ne 0 ]; then _delivery_gate_release; return "$seam_rc"; fi

    # Publishers create an intent before waiting on the gate. If one arrived
    # after our drain, yield the gate, let it publish durably, reacquire, and
    # repeat the drain before delivery. If no intent exists at this point,
    # delivery is the earlier linearized operation and remains under the lock.
    if _delivery_pending_exists; then
      _delivery_gate_release
      set +e; _delivery_wait_for_publishers; wait_rc=$?; set -e
      [ "$wait_rc" -eq 0 ] || return "$wait_rc"
      if ! _delivery_gate_acquire; then return 20; fi
      continue
    fi

    delivery="$(_watch_fingerprint || true)"
    if [ -z "$delivery" ]; then _delivery_gate_release; return 2; fi
    if [ "$delivery" != "$evidence" ]; then
      _watch_supersede_current evidence_changed "$current_kind"
      _delivery_gate_release
      return 12
    fi
    if ! _send "$WATCH_PANE" "$DECISION_TEXT" ${DECISION_KEYS[@]+"${DECISION_KEYS[@]}"}; then
      _delivery_gate_release
      return 21
    fi
    WATCH_DELIVERY_FINGERPRINT="$delivery"
    _delivery_gate_release
    return 0
  done
}

_watch_finalize() {
  local outcome="$1" phase="$2" reason="$3"
  _delivery_cleanup
  _watch_kill_waiters
  _terminate_current_brain
  _watch_phase "$phase" "$reason" none 0
  radar_run_finalize "$outcome" "$reason"
  WATCH_FINALIZED=1
  rm -f "$WATCH_WF" "$BRAIN_PID_FILE" "$BRAIN_OUT_FILE"
}

_watch_signal_exit() {
  local signal="$1" rc="$2"
  trap - TERM INT HUP
  _delivery_cleanup
  if [ "$WATCH_FINALIZED" -eq 0 ] && [ -n "${RADAR_RUN_DIR:-}" ]; then
    _watch_finalize stopped STOPPED "watcher received $signal"
  else
    _watch_kill_waiters
    _terminate_current_brain
    [ -n "$WATCH_WF" ] && rm -f "$WATCH_WF"
  fi
  exit "$rc"
}

cmd_watch_loop() {
  local pane goal policy poll auto maxcalls config batch wait_rc coalesce_rc event_kind
  local rc valid failure evidence_fingerprint delivery_fingerprint armed_fingerprint current_fingerprint guard_rc
  local retry_rc retry_cancelled verify_rc
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane" >&2; return 1; }
  goal="${2:-}"
  policy="${3:-}"
  [ -z "$policy" ] && [ "$(opt @radar-ai-watch-always-allow off)" = on ] && policy="always-allow"
  poll="${4:-}"; case "$poll" in ''|*[!0-9.]*) poll="$(opt @radar-ai-poll 5)" ;; esac
  auto="${5:-}"; [ -n "$auto" ] || auto="$(opt @radar-ai-watch-autonomy auto-safe)"
  maxcalls="$(opt @radar-ai-max-calls 40)"; case "$maxcalls" in ''|*[!0-9]*) maxcalls=40 ;; esac

  WATCH_PANE="$pane"; WATCH_WF="$(_wf "$pane")"; WATCH_STARTED="$(now)"
  WATCH_POLL="$poll"; WATCH_GOAL="$goal"; WATCH_POLICY="$policy"
  WATCH_AUTONOMY="$auto"; WATCH_MAX_CALLS="$maxcalls"; WATCH_CALLS=0
  WATCH_RETRY=0; WATCH_EVENT_ID=""; WATCH_LAST_DECISION=""; WATCH_FINALIZED=0
  config="$(jq -cn --arg goal "$goal" --arg policy "${policy:-safe-auto}" --arg autonomy "$auto" \
    --argjson poll "$(awk -v p="$poll" 'BEGIN { printf "%.6f", p+0 }')" --argjson max_calls "$maxcalls" '
    {goal:$goal,policy:$policy,autonomy:$autonomy,poll:$poll,max_calls:$max_calls,
     source:{kind:"watch_cli",provenance:"legacy-compatible"},
     provenance:{goal:"argument",policy:"argument_or_tmux",autonomy:"argument_or_tmux",
                 poll:"argument_or_tmux",max_calls:"tmux_or_default"}}
  ')"
  radar_run_create "$pane" "$config"
  WATCH_WF="$(radar_watch_file "$pane")"
  trap '_watch_signal_exit TERM 143' TERM
  trap '_watch_signal_exit INT 130' INT
  trap '_watch_signal_exit HUP 129' HUP
  _watch_phase CREATED "run created" none 0
  _watch_phase ARMED "waiting for native event or idle fallback" idle 0
  audit "watch-start\t$pane\t$goal\t${policy:-safe}\tpoll=$poll\trun=$RADAR_RUN_ID"
  _watch_timeline "$pane" start "$(_pane_label "$pane") · event-driven · poll=${poll}s · goal=${goal:-<none>}"
  printf '%s▶ 开始监控%s %s%s\n' "$CG" "$CR" "$(_pane_label "$pane")" "${goal:+  ${CD}· ${goal}${CR}}"

  batch="$RADAR_RUN_DIR/.batch.$$"
  while :; do
    _watch_phase ARMED "waiting for native event or idle fallback" idle 0
    armed_fingerprint="$(_watch_fingerprint || true)"
    [ -n "$armed_fingerprint" ] || { _watch_finalize stopped STOPPED "target pane disappeared while arming"; break; }
    set +e; _watch_wait_for_batch "$batch"; wait_rc=$?; set -e
    case "$wait_rc" in
      2) _watch_finalize stopped STOPPED "target pane disappeared"; break ;;
      1)
        current_fingerprint="$(_watch_fingerprint || true)"
        if [ -z "$current_fingerprint" ]; then
          _watch_finalize stopped STOPPED "target pane disappeared at idle deadline"
          break
        fi
        if [ "$current_fingerprint" != "$armed_fingerprint" ]; then
          radar_event_append idle_reset watcher "screen changed during idle interval" "$(jq -cn \
            --arg before "$armed_fingerprint" --arg after "$current_fingerprint" \
            '{record:"idle_reset",before:$before,after:$after}')"
          continue
        fi
        WATCH_IDLE_SEQ=$(( ${WATCH_IDLE_SEQ:-0} + 1 ))
        WATCH_EVENT_ID="idle-$RADAR_RUN_ID-$WATCH_IDLE_SEQ"
        jq -cn --arg id "$WATCH_EVENT_ID" --arg pane "$pane" --arg timestamp "$(_radar_now_iso)" \
          --argjson event_order "$(_watch_next_event_order)" \
          '{kind:"idle",source:"watcher",label:"idle fallback",event_id:$id,pane:$pane,timestamp:$timestamp,event_order:$event_order}' > "$batch"
        ;;
    esac
    _watch_phase EVENT_PENDING "event batch ready" event 0
    set +e; _watch_coalesce_batch "$batch"; coalesce_rc=$?; set -e
    : > "$batch"
    case "$coalesce_rc" in
      10) WATCH_EVENT_ID=""; _watch_phase ARMED "user resumed; idle timing reset" idle 0; continue ;;
      11) WATCH_EVENT_ID=""; _watch_phase ARMED "replayed events ignored" idle 0; continue ;;
      0) : ;;
      *) _watch_finalize paused_error PAUSED_ERROR "failed to coalesce event batch"; _escalate "$pane" "AI 监控事件队列读取失败"; break ;;
    esac
    event_kind="$(printf '%s' "$WATCH_EVENT_JSON" | jq -r '.kind')"
    _watch_phase CAPTURING "capturing pane for $event_kind" none 0
    evidence_fingerprint="$(_watch_fingerprint || true)"
    if [ -z "$evidence_fingerprint" ]; then _watch_finalize stopped STOPPED "target pane disappeared during capture"; break; fi

    WATCH_RETRY=0; retry_cancelled=0
    while :; do
      if [ "$WATCH_CALLS" -ge "$WATCH_MAX_CALLS" ]; then
        _watch_phase PAUSED_ERROR "max_calls reached before model launch" none 0
        _escalate "$pane" "AI 监控达到调用上限($WATCH_MAX_CALLS),已暂停"
        radar_run_finalize paused "max_calls reached"
        WATCH_FINALIZED=1; rm -f "$WATCH_WF"
        break 2
      fi
      WATCH_CALLS=$((WATCH_CALLS + 1))
      _watch_phase DECIDING "model call $WATCH_CALLS/$WATCH_MAX_CALLS for $event_kind" none 0
      DECISION_ACTION=""; DECISION_JSON=""; DECISION_TEXT=""; DECISION_SAFE=0; DECISION_REASON=""; DECISION_KEYS=()
      set +e
      TMUX_RADAR_AI_DETAIL=1 TMUX_RADAR_DECIDE_PARSE_ONLY=1 cmd_decide "$pane" "$auto" "$policy" "$goal"
      rc=$?
      set -e
      WATCH_LAST_DECISION="$(now)"
      valid=1; failure=""
      if [ "$BRAIN_LAST_RC" -ne 0 ]; then valid=0; failure="backend rc=$BRAIN_LAST_RC${BRAIN_STOP_REASON:+ ($BRAIN_STOP_REASON)}"
      elif [ "$DECISION_SCHEMA_VALID" -ne 1 ]; then valid=0; failure="${DECISION_SCHEMA_ERROR:-decision schema/type validation failed}"
      else
        if [ "$valid" -eq 1 ] && [ "$DECISION_ACTION" = "done" ]; then
          case "$event_kind" in turn_complete|screen_idle|idle|manual_reassess) : ;;
            *) valid=0; failure="done is invalid for event kind: $event_kind" ;;
          esac
        fi
      fi
      [ "$valid" -eq 1 ] && break
      radar_event_append decision_failed watcher "$failure" "$(jq -cn --arg event_id "$WATCH_EVENT_ID" \
        --arg reason "$failure" --argjson retry "$WATCH_RETRY" '{record:"decision_error",event_id:$event_id,reason:$reason,retry:$retry}')"
      if [ "$WATCH_RETRY" -ge 3 ]; then
        _watch_phase PAUSED_ERROR "$failure; retry exhausted" none 0
        _escalate "$pane" "AI 监控连续决策失败，已暂停: $failure"
        radar_run_finalize paused_error "$failure"
        WATCH_FINALIZED=1; rm -f "$WATCH_WF"
        break 2
      fi
      WATCH_RETRY=$((WATCH_RETRY + 1))
      _watch_phase DECIDING "$failure; retry $WATCH_RETRY scheduled" retry 0
      set +e; _watch_retry_delay "$WATCH_RETRY" "$event_kind"; retry_rc=$?; set -e
      case "$retry_rc" in
        0) : ;;
        10) retry_cancelled=1; break ;;
        2) _watch_finalize stopped STOPPED "target pane disappeared during retry delay"; break 2 ;;
        *) _watch_finalize paused_error PAUSED_ERROR "retry wait failed"; break 2 ;;
      esac
    done

    if [ "$retry_cancelled" -eq 1 ]; then
      WATCH_EVENT_ID=""; WATCH_RETRY=0
      continue
    fi

    set +e; _watch_post_decision_guard "$evidence_fingerprint" "$event_kind"; guard_rc=$?; set -e
    case "$guard_rc" in
      0) : ;;
      2) _watch_finalize stopped STOPPED "target pane disappeared after decision"; break ;;
      10|12)
        WATCH_EVENT_ID=""; WATCH_RETRY=0
        continue
        ;;
      *) _watch_finalize paused_error PAUSED_ERROR "post-decision event drain failed"; break ;;
    esac

    _watch_phase POLICY_GATE "evaluating $DECISION_ACTION (safe=$DECISION_SAFE)" none 0
    case "$DECISION_ACTION" in
      done)
        _clearmark "$pane"; _escalate "$pane" "AI: 任务完成 ✓${goal:+ ($goal)}"
        _watch_finalize completed COMPLETED "${DECISION_REASON:-goal completed}"
        break
        ;;
      wait)
        radar_event_append wait watcher "${DECISION_REASON:-model says wait}" "$(jq -cn --arg event_id "$WATCH_EVENT_ID" '{record:"decision",event_id:$event_id}')"
        WATCH_EVENT_ID=""; WATCH_RETRY=0
        continue
        ;;
      suggest)
        radar_event_append suggest watcher "${DECISION_REASON:-suggestion only}" "$(jq -cn --arg event_id "$WATCH_EVENT_ID" '{record:"decision",event_id:$event_id,sent:false}')"
        WATCH_EVENT_ID=""; WATCH_RETRY=0
        continue
        ;;
      escalate)
        _watch_phase PAUSED_ERROR "model escalated: ${DECISION_REASON:-unspecified}" none 0
        _escalate "$pane" "AI 拿不准: ${DECISION_REASON:-需要人工处理}"
        radar_run_finalize paused "${DECISION_REASON:-model escalated}"
        WATCH_FINALIZED=1; rm -f "$WATCH_WF"
        break
        ;;
      send)
        if [ "$DECISION_SAFE" != 1 ] || [ "$auto" = suggest ] || [ "$auto" = confirm ]; then
          _watch_phase PAUSED_ERROR "policy requires user: ${DECISION_REASON:-unsafe or non-auto action}" none 0
          _escalate "$pane" "AI 需要你确认: ${DECISION_REASON:-操作未自动执行}"
          radar_run_finalize paused "policy gate"
          WATCH_FINALIZED=1; rm -f "$WATCH_WF"
          break
        fi
        ;;
    esac
    _watch_phase EXECUTING "final delivery guard" none 0
    set +e; _watch_deliver_under_gate "$evidence_fingerprint" "$event_kind"; guard_rc=$?; set -e
    case "$guard_rc" in
      0) : ;;
      2) _watch_finalize stopped STOPPED "target pane disappeared at final delivery guard"; break ;;
      10|12) WATCH_EVENT_ID=""; WATCH_RETRY=0; continue ;;
      21)
        radar_event_append delivery_failed watcher "tmux send-keys failed" "$(jq -cn \
          --arg event_id "$WATCH_EVENT_ID" --arg pre "$evidence_fingerprint" \
          '{record:"delivery_error",event_id:$event_id,sent:false,pre_send_fingerprint:$pre}')"
        _escalate "$pane" "AI 监控发送按键失败，已暂停"
        _watch_finalize delivery_error PAUSED_ERROR "tmux send-keys delivery failed"
        break
        ;;
      20) _watch_finalize paused_error PAUSED_ERROR "delivery gate acquisition failed"; break ;;
      *) _watch_finalize paused_error PAUSED_ERROR "final delivery guard failed"; break ;;
    esac
    delivery_fingerprint="$WATCH_DELIVERY_FINGERPRINT"
    radar_event_append sent watcher "${DECISION_REASON:-safe action sent}" "$(jq -cn --arg event_id "$WATCH_EVENT_ID" \
      --arg pre "$delivery_fingerprint" '{record:"execution",event_id:$event_id,sent:true,pre_send_fingerprint:$pre}')"
    _clearmark "$pane"
    set +e; _watch_verify_send "$delivery_fingerprint"; verify_rc=$?; set -e
    case "$verify_rc" in
      0) : ;;
      2) _watch_finalize stopped STOPPED "target pane disappeared during verification"; break ;;
      3)
        _escalate "$pane" "AI 监控发送后未观察到变化，已暂停"
        _watch_finalize verification_timeout PAUSED_ERROR "verification timeout: no observable send effect"
        break
        ;;
      *) _watch_finalize paused_error PAUSED_ERROR "verification failed"; break ;;
    esac
    WATCH_EVENT_ID=""; WATCH_RETRY=0
  done
  rm -f "$batch"
  _watch_kill_waiters
  _terminate_current_brain
  [ "$WATCH_FINALIZED" -eq 1 ] || _watch_finalize stopped STOPPED "watch loop ended"
  audit "watch-stop\t$pane\trun=$RADAR_RUN_ID"
}

monitor_size() {  # monitor_size <pane> <height|width> <requested> <min> <reserve>
  local pane="$1" axis="$2" requested="$3" min="$4" reserve="$5" dim max
  case "$requested" in ''|*[!0-9]*) requested="$min" ;; esac
  case "$axis" in
    width)  dim="$(tmux display-message -p -t "$pane" '#{pane_width}' 2>/dev/null || true)" ;;
    *)      dim="$(tmux display-message -p -t "$pane" '#{pane_height}' 2>/dev/null || true)" ;;
  esac
  case "$dim" in ''|*[!0-9]*) printf '%s' "$requested"; return 0 ;; esac
  max=$((dim - reserve))
  [ "$max" -lt "$min" ] && return 1
  [ "$requested" -gt "$max" ] && requested="$max"
  [ "$requested" -lt "$min" ] && requested="$min"
  printf '%s' "$requested"
}

_abort_watch_launch() {  # _abort_watch_launch <pane> <watcher-pid>
  local pane="$1" pid="$2" base
  base="$(_wbase "$pane")"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  _terminate_brain_file "$base.brain.pid"
  rm -f "$base.watch" "$base.out" "$base.timeline" "$base.detail" \
    "$base.detail.log" "$base.brain.err"
}

cmd_watch() {  # detach the loop so the caller (popup/menu) can return
  local pane goal policy poll auto wf base feed pos mon_size err layout mon_pane detail_pane detail_cmd timeline_cmd single_cmd watch_pid
  local -a split_args
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane"; return 1; }
  goal="${2:-}"; policy="${3:-}"; poll="${4:-}"; auto="${5:-}"
  wf="$(_wf "$pane")"; base="${wf%.watch}"; feed="$base.out"
  if [ -f "$wf" ] && kill -0 "$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)" 2>/dev/null; then
    echo "already watching $pane (stop it first)"; return 0
  fi
  : > "$feed"                                  # create the feed before the monitor tails it
  : > "$base.timeline"
  : > "$base.detail"
  : > "$base.detail.log"
  nohup bash "$SELF" _watch_loop "$pane" "$goal" "$policy" "$poll" "$auto" >"$feed" 2>&1 &
  watch_pid=$!
  disown 2>/dev/null || true
  # The structured watcher owns creation of the compatibility pointer. Wait a
  # bounded moment so monitor pane IDs can be merged without racing startup.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$wf" ] && break
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 0.01
  done
  # Companion monitor: a split next to the watched pane, not a covering popup.
  # In the default split layout, the monitor region is split again into
  # timeline + detail panes. If the second split fails, the watcher still runs.
  if [ "$(opt @radar-ai-monitor on)" = "on" ] && have_tmux; then
    pos="$(opt @radar-ai-monitor-pos top)"
    layout="$(opt @radar-ai-monitor-layout split)"
    timeline_cmd="TMUX_RADAR_STATE_DIR='$STATE_DIR' exec bash '$SELF' monitor-timeline '$pane'"
    detail_cmd="TMUX_RADAR_STATE_DIR='$STATE_DIR' exec bash '$SELF' monitor-detail '$pane'"
    single_cmd="TMUX_RADAR_STATE_DIR='$STATE_DIR' exec bash '$SELF' monitor '$pane'"
    split_args=()
    case "$pos" in
      bottom)
        if mon_size="$(monitor_size "$pane" height "$(opt @radar-ai-monitor-size 12)" 8 4)"; then
          split_args=(-v -l "$mon_size")
        fi ;;
      right)
        if mon_size="$(monitor_size "$pane" width "$(opt @radar-ai-monitor-size-h 60)" 20 30)"; then
          split_args=(-h -l "$mon_size")
        fi ;;
      *)
        pos="top"
        if mon_size="$(monitor_size "$pane" height "$(opt @radar-ai-monitor-size 12)" 8 4)"; then
          split_args=(-v -b -l "$mon_size")
        fi ;;
    esac
    if [ "${#split_args[@]}" -gt 0 ]; then
      # pass STATE_DIR explicitly: the split pane inherits the tmux server env, not
      # the watcher's, so this keeps the monitor's feed/pidfile paths in sync.
      if [ "$layout" = "single" ]; then
        if mon_pane="$(tmux split-window "${split_args[@]}" -P -F '#{pane_id}' -d -t "$pane" "$single_cmd" 2>&1)"; then
          _watch_pointer_set_monitors "$wf" "$mon_pane" ""
          audit "monitor-start\t$pane\t$pos\tsingle\tsize=$mon_size"
        else
          err="$mon_pane"
          printf '%s⚠ 监控 pane 打开失败，已停止 watch%s%s\n' "$CY" "$CR" "${err:+: $err}"
          audit "monitor-fail\t$pane\t$pos\tsingle\tsize=${mon_size:-?}\t$err"
          _abort_watch_launch "$pane" "$watch_pid"
          return 1
        fi
      elif mon_pane="$(tmux split-window "${split_args[@]}" -P -F '#{pane_id}' -d -t "$pane" "$timeline_cmd" 2>&1)"; then
        if [ "$pos" = "right" ]; then
          detail_pane="$(tmux split-window -v -P -F '#{pane_id}' -d -t "$mon_pane" -p 55 "$detail_cmd" 2>/dev/null || true)"
          [ -n "$detail_pane" ] || audit "monitor-detail-fail\t$pane\t$pos\t$mon_pane"
        else
          detail_pane="$(tmux split-window -h -P -F '#{pane_id}' -d -t "$mon_pane" -p 58 "$detail_cmd" 2>/dev/null || true)"
          [ -n "$detail_pane" ] || audit "monitor-detail-fail\t$pane\t$pos\t$mon_pane"
        fi
        _watch_pointer_set_monitors "$wf" "$mon_pane" "$detail_pane"
        audit "monitor-start\t$pane\t$pos\tsplit\tsize=$mon_size"
      else
        printf '%s⚠ 监控 pane 打开失败，已停止 watch%s%s\n' "$CY" "$CR" "${mon_pane:+: $mon_pane}"
        audit "monitor-fail\t$pane\t$pos\tsplit\tsize=${mon_size:-?}\t$mon_pane"
        _abort_watch_launch "$pane" "$watch_pid"
        return 1
      fi
    else
      printf '%s⚠ 目标 pane 太小，未打开监控 pane；已停止 watch%s\n' "$CY" "$CR"
      audit "monitor-skip\t$pane\t$pos\tpane-too-small"
      _abort_watch_launch "$pane" "$watch_pid"
      return 1
    fi
  fi
  printf '%s✓ 已开始监控%s %s%s%s\n' "$CG" "$CR" "$(_pane_label "$pane")" \
    "${goal:+  ${CD}· ${goal}${CR}}" "${policy:+  ${CY}[$policy]${CR}}"
}

# Interactive setup for a watch: goal / poll interval / approval policy, read
# from the popup tty. Runs in a display-popup so there is no tmux menu/quoting
# escaping to fight, and every choice is per-watch (no global option flips).
cmd_watch_setup() {
  local pane goal poll ans policy="" auto=""
  pane="$(_resolve_pane "${1:-}")" || { echo "watch-setup: no target pane"; return 1; }
  _hdr "AI 常驻监控 · 设置" "$(_pane_label "$pane")"
  printf '%s目标（回车 = 通用：推进直到任务完成）%s\n> ' "$CD" "$CR"
  readline_tty goal
  printf '\n%s轮询间隔秒（回车 = %s）%s\n> ' "$CD" "$(opt @radar-ai-poll 5)" "$CR"
  readline_tty poll
  printf '\n%s批准策略%s\n' "$CD" "$CR"
  printf '  1) 安全项自动批准，其余上报给你（默认）\n'
  printf '  2) always-allow — 安全项可选“不再询问”，更省心\n'
  printf '  3) 仅建议 — 只播报，不代按任何键\n> '
  readline_tty ans
  case "$ans" in 2) policy="always-allow" ;; 3) auto="suggest" ;; esac
  echo
  cmd_watch "$pane" "$goal" "$policy" "$poll" "$auto"
  sleep 1.2   # let the popup show the result before it closes
}

cmd_stop() {
  local target="${1:-all}" wf pid brain_file
  if [ "$target" = "all" ]; then
    for wf in "$WATCH_DIR"/*.watch; do
      [ -e "$wf" ] || continue
      pid="$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)"
      brain_file="${wf%.watch}.brain.pid"
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
      _terminate_brain_file "$brain_file"
      rm -f "$wf"
    done
    for brain_file in "$WATCH_DIR"/*.brain.pid; do
      [ -e "$brain_file" ] || continue
      _terminate_brain_file "$brain_file"
    done
    echo "stopped all watchers"; return 0
  fi
  target="$(_resolve_pane "$target" 2>/dev/null || echo "$target")"
  wf="$(_wf "$target")"
  brain_file="${wf%.watch}.brain.pid"
  if [ ! -f "$wf" ]; then
    _terminate_brain_file "$brain_file"
    echo "no watcher for $target"
    return 0
  fi
  pid="$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  _terminate_brain_file "$brain_file"
  rm -f "$wf"; echo "stopped watcher for $target"
}

cmd_status() {
  local wf pid pane goal started poll any=0 ts act rest
  _hdr "AI 主管 · 状态"
  for wf in "$WATCH_DIR"/*.watch; do
    [ -e "$wf" ] || continue
    pid="$(awk -F= '/^pid=/{print $2}' "$wf")"; pane="$(awk -F= '/^pane=/{print $2}' "$wf")"
    goal="$(awk -F= '/^goal=/{print $2}' "$wf")"; started="$(awk -F= '/^started=/{print $2}' "$wf")"
    poll="$(awk -F= '/^poll=/{print $2}' "$wf")"
    if kill -0 "$pid" 2>/dev/null; then
      any=1
      printf '%s●%s %-24s %s%s · pid %s · 已运行 %ss · 轮询 %ss%s\n' \
        "$CG" "$CR" "$(_pane_label "$pane")" "$CD" "$pane" "$pid" \
        "$(( $(now) - ${started:-$(now)} ))" "${poll:-5}" "$CR"
      [ -n "$goal" ] && printf '   %s目标: %s%s\n' "$CD" "$goal" "$CR"
    else rm -f "$wf" "${wf%.watch}.out"; fi
  done
  [ "$any" = 1 ] || printf '%s（当前没有活动监控）%s\n' "$CD" "$CR"
  if [ -r "$LOG" ] && [ -s "$LOG" ]; then
    printf '\n%s── 最近决策 ──%s\n' "$CD" "$CR"
    tail -n 8 "$LOG" | while IFS=$'\t' read -r ts act pane rest; do
      printf '%s%s%s  %-10s %-6s %s%s%s\n' "$CD" "$ts" "$CR" "$act" "$pane" "$CD" "$rest" "$CR"
    done
  fi
}

# ---------------------------------------------------------------------------
# monitor: live viewers that run in companion split panes. The default layout
# uses two read-only panes: timeline on the left, detail on the right. They
# repaint from the watcher's state files once per second, so countdown/status
# stays live even when the watcher is sleeping between polls.
# ---------------------------------------------------------------------------
_monitor_loop() {  # _monitor_loop <timeline|detail|combined> <pane>
  local mode="$1" pane="$2" wf base feed timeline detail detail_log label cols rows stream_top file pos=0
  local last_cols=0 last_rows=0
  pane="$(_resolve_pane "$pane" 2>/dev/null || echo "$pane")"
  wf="$(_wf "$pane")"; base="${wf%.watch}"
  feed="$base.out"; timeline="$base.timeline"; detail="$base.detail"; detail_log="$base.detail.log"
  label="$(_pane_label "$pane")"
  [ -f "$feed" ] || : > "$feed"
  [ -f "$timeline" ] || : > "$timeline"
  [ -f "$detail_log" ] || : > "$detail_log"
  [ -f "$detail" ] || : > "$detail"
  case "$mode" in
    timeline) file="$timeline" ;;
    detail) file="$detail_log" ;;
    *) file="$detail_log" ;;
  esac
  # Clear once, then keep the top four rows fixed. The content region below is
  # append-only, so tmux scrollback stays useful and countdown updates do not
  # repaint the whole pane.
  printf '\033[?25l\033[H\033[J'
  # The companion pane owns the watch from the user's point of view. Closing it
  # or pressing Ctrl-C must stop the watcher instead of leaving a hidden brain
  # call running after its visible control surface is gone.
  trap 'printf "\033[r\033[?25h"; "$SELF" stop "$pane" >/dev/null 2>&1 || true; exit 0' TERM INT HUP
  while [ -f "$wf" ]; do
    cols="$(tput cols 2>/dev/null || echo 100)"
    rows="$(tput lines 2>/dev/null || echo 24)"
    case "$cols" in ''|*[!0-9]*) cols=100 ;; esac
    case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
    if [ "$cols" -ne "$last_cols" ] || [ "$rows" -ne "$last_rows" ]; then
      stream_top=5
      printf '\033[r\033[H\033[J'
      printf '\033[%s;%sr' "$stream_top" "$rows"
      printf '\033[%s;1H' "$stream_top"
      case "$mode" in
        timeline) printf '%sTimeline%s\n' "$CC" "$CR" ;;
        detail) printf '%sDetail log%s\n' "$CC" "$CR" ;;
        *) printf '%sDetail log%s\n' "$CC" "$CR" ;;
      esac
      pos=0
      last_cols="$cols"; last_rows="$rows"
    fi
    _monitor_draw_header "$mode" "$label" "$cols" "$wf"
    _monitor_emit_new "$mode" "$file" "$pos" "$cols"
    case "${monitor_emit_total:-}" in ''|*[!0-9]*) : ;; *) pos="$monitor_emit_total" ;; esac
    sleep 1
  done
  printf '\033[r\033[?25h'
  printf '\033[2m— 监控结束，本窗即将关闭 —\033[0m\n'
  sleep 3
}

cmd_monitor_timeline() { _monitor_loop timeline "${1:-}"; }
cmd_monitor_detail() { _monitor_loop detail "${1:-}"; }

cmd_monitor() {
  local pane
  pane="$(_resolve_pane "${1:-}" 2>/dev/null || echo "${1:-}")"
  _monitor_loop combined "$pane"
}

# ---------------------------------------------------------------------------
# ask: arrange tmux from natural language. Codex returns a batch of tmux
# commands (no leading "tmux"); we run them via `source-file` (native tmux
# parsing, no shell eval) after a denylist scan + autonomy gate.
# ---------------------------------------------------------------------------
cmd_ask() {
  need_jq
  have_brain || { echo "codex 未安装/不可用，无法使用 AI 指挥。"; return 3; }
  local req autonomy snap json explain n cmds_file
  req="${*:-}"
  [ -n "$req" ] || { printf 'tmux 指令（自然语言）: '; readline_tty req; }
  [ -n "$req" ] || { echo "nothing to do"; return 0; }
  autonomy="$(opt @radar-ai-autonomy confirm)"
  snap="$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{?pane_active,*,} #{pane_current_command} #{pane_current_path} "#{pane_title}"' 2>/dev/null || true)"
  echo "· thinking…"
  BRAIN_BOUND_PANE=""
  BRAIN_PID_FILE=""
  _brain "$PROMPT_DIR/control.schema.json" "$(_skill control.md)"$'\n\n'"CURRENT TMUX PANES:"$'\n'"$snap"$'\n\n'"CURRENT PANE: ${TMUX_PANE:-?}"$'\n'"USER REQUEST: $req"
  json="$BRAIN_RESULT"
  explain="$(printf '%s' "$json" | jq -r '.explain // ""' 2>/dev/null || echo '')"
  cmds_file="$(mktemp "${TMPDIR:-/tmp}/tmuxask.XXXXXX")"
  printf '%s' "$json" | jq -r '.commands[]? // empty' 2>/dev/null > "$cmds_file" || true
  n="$(grep -cve '^$' "$cmds_file" 2>/dev/null || echo 0)"
  [ "$n" -gt 0 ] || { echo "${explain:-无可执行命令}"; rm -f "$cmds_file"; return 0; }

  echo "计划：${explain}"; echo "--- tmux 命令 ---"; cat "$cmds_file"; echo "-----------------"
  # catastrophic denylist — these break out of "just arrange my tmux"
  if grep -qiE '(^|[[:space:]])(run-shell|if-shell|source-file|kill-server|respawn-pane|respawn-window)([[:space:]]|$)' "$cmds_file"; then
    echo "⚠ 含有危险命令(run-shell/kill-server 等)，已拒绝执行。"; rm -f "$cmds_file"; return 4
  fi
  case "$autonomy" in
    suggest) echo "(suggest 模式：自行执行)"; rm -f "$cmds_file"; return 6 ;;
    confirm)
      printf '执行? [y/N] '; local ans=""; readline_tty ans
      case "$ans" in y|Y|yes) ;; *) echo "已取消"; rm -f "$cmds_file"; return 6 ;; esac ;;
  esac
  tmux source-file "$cmds_file" 2>&1 && echo "✓ 已执行 $n 条" || echo "部分命令执行失败"
  audit "ask\t$req\t$n cmds"
  rm -f "$cmds_file"
}

# ---------------------------------------------------------------------------
# list: AI panes + their AI-status / watch state (quick picker source).
# Detection goes through the notifier's process scan (ps argv0 components), not
# pane_current_command — Claude Code's foreground binary is a bare version
# number ("2.1.199"), so the naive match misses it.
# ---------------------------------------------------------------------------
cmd_list() {
  have_tmux || { echo "no tmux server"; return 0; }
  _hdr "AI panes" "⚠ 操作 · ✓ 完成 · ! 通知 · ● 监控中"
  # join mark records with \001 — BSD awk rejects newlines in -v values
  local marks="" agents="" watching="" wf
  [ -r "$STATE_FILE" ] && marks="$(tr '\n' '\001' < "$STATE_FILE")"
  agents="$("$NOTIFY" agent-panes 2>/dev/null | tr '\n' '\001')"   # "OK\001%1\001…"
  for wf in "$WATCH_DIR"/*.watch; do
    [ -e "$wf" ] || continue
    kill -0 "$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)" 2>/dev/null || continue
    watching="$watching$(awk -F= '/^pane=/{print $2}' "$wf" 2>/dev/null)"$'\001'   # real \001 byte
  done
  tmux list-panes -a -F '#{pane_id}'$'\t''#{session_name}:#{window_index}.#{pane_index}'$'\t''#{pane_current_command}'$'\t''#{pane_title}' 2>/dev/null |
  awk -F '\t' -v marks="$marks" -v agents="$agents" -v watching="$watching" \
      -v CG="$CG" -v CY="$CY" -v CM="$CM" -v CD="$CD" -v CR="$CR" '
    function level_for(src, label,    l) {
      l = tolower(src " " label)
      if (l ~ /(finished|your turn|turn complete|task complete|done|任务完成|完成)/) return "done"
      if (l ~ /(needs approval|needs your permission|needs input|waiting.*input|waiting on you|wait.*input|permission|approval|action required|approve|拿不准|需要你|需要.*许可|需要.*批准|等待.*输入)/) return "action"
      return "notice"
    }
    function icon_for(level) { return (level == "action" ? "⚠" : (level == "done" ? "✓" : "!")) }
    function color_for(level) { return (level == "action" ? CM : (level == "done" ? CG : CY)) }
    BEGIN {
      n=split(marks, ml, "\001"); for(i=1;i<=n;i++){split(ml[i],f,"\t"); if(f[1]!=""){flagged[f[1]]=(f[5]?f[5]:f[4]); flag_src[f[1]]=f[3]}}
      have_scan = (index(agents, "OK\001") == 1)
    }
    {
      # precise scan when available, else fall back to the command heuristic
      if (have_scan) { if (index(agents, "\001" $1 "\001") == 0 && !($1 in flagged)) next }
      else if (tolower($3) !~ /codex|claude/ && !($1 in flagged)) next
      w = (index(watching, $1 "\001") > 0) ? CG "●" CR : " "
      if ($1 in flagged) { lvl=level_for(flag_src[$1], flagged[$1]); tail = color_for(lvl) icon_for(lvl) " " flagged[$1] CR }
      else               tail = CD $4 CR
      printf "%s %-5s %-20s %s%-10s%s %s\n", w, $1, $2, CD, $3, CR, tail
    }'
}

# ---------------------------------------------------------------------------
# cleanup: GC everything a dead server / resurrect restore can leave behind —
# watcher pidfiles whose process is gone, orphan feed files, leftover monitor
# panes whose watcher ended, and stale AI-status marks (via the notifier).
# Safe to run any time; wired to plugin load and (optionally) the
# tmux-resurrect post-restore hook.
# ---------------------------------------------------------------------------
cmd_cleanup() {
  local wf pid f base n=0 mon start watched live_pids orphan_pids opid
  for wf in "$WATCH_DIR"/*.watch; do
    [ -e "$wf" ] || continue
    pid="$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)"
    kill -0 "$pid" 2>/dev/null && continue
    _terminate_brain_file "${wf%.watch}.brain.pid"
    rm -f "$wf" "${wf%.watch}.out" "${wf%.watch}.timeline" "${wf%.watch}.detail" "${wf%.watch}.detail.log" "${wf%.watch}.brain.err"; n=$((n+1))
  done
  for f in "$WATCH_DIR"/*.out "$WATCH_DIR"/*.timeline "$WATCH_DIR"/*.detail "$WATCH_DIR"/*.detail.log "$WATCH_DIR"/*.brain.err "$WATCH_DIR"/*.brain.pid; do
    [ -e "$f" ] || continue
    case "$f" in
      *.out) base="${f%.out}" ;;
      *.timeline) base="${f%.timeline}" ;;
      *.detail.log) base="${f%.detail.log}" ;;
      *.detail) base="${f%.detail}" ;;
      *.brain.err) base="${f%.brain.err}" ;;
      *.brain.pid) base="${f%.brain.pid}" ;;
      *) base="${f%.*}" ;;
    esac
    if [ ! -f "$base.watch" ]; then
      case "$f" in *.brain.pid) _terminate_brain_file "$f" ;; *) rm -f "$f" ;; esac
    fi
  done
  live_pids=""
  for wf in "$WATCH_DIR"/*.watch; do
    [ -e "$wf" ] || continue
    pid="$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)"
    [ -n "$pid" ] && live_pids="$live_pids$pid"$'\034'
  done
  orphan_pids="$(ps -axo pid=,command= 2>/dev/null | LC_ALL=C awk -v self="$SELF" -v live="$live_pids" '
    index($0, self " _watch_loop") == 0 { next }
    {
      pid=$1
      if (pid != "" && index("\034" live, "\034" pid "\034") == 0) print pid
    }' || true)"
  while IFS= read -r opid; do
    [ -n "$opid" ] || continue
    kill "$opid" 2>/dev/null && n=$((n+1)) || true
  done <<< "$orphan_pids"
  if have_tmux; then
    tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_start_command}' 2>/dev/null |
      while IFS=$'\t' read -r mon start; do
        case "$start" in *"$SELF"*"' monitor"*"' "*) ;; *) continue ;; esac
        watched="$(printf '%s' "$start" | sed -n "s/.* monitor[-a-z]* '\(%[0-9][0-9]*\)'.*/\1/p")"
        [ -n "$watched" ] || continue
        [ -f "$(_wf "$watched")" ] || tmux kill-pane -t "$mon" 2>/dev/null || true
      done
  fi
  [ -x "$NOTIFY" ] && "$NOTIFY" tick >/dev/null 2>&1 || true
  if [ "$n" -gt 0 ]; then echo "cleanup: removed $n stale watcher file(s)"; else echo "cleanup: ok"; fi
}

# ---------------------------------------------------------------------------
# menu: the display-menu chooser. Single source of truth — tmux-radar.tmux
# binds prefix + <@radar-ai-key> to `ai.sh menu` so this never drifts from
# the plugin binding.
# ---------------------------------------------------------------------------
cmd_menu() {
  local pop; pop="display-popup -E -w 80% -h 70%"
  tmux display-menu -T "#[align=centre] tmux AI 主管 " -x C -y C \
    "指挥 tmux（自然语言）"             a "$pop \"TMUX_RADAR_AI_PAUSE=1 $SELF ask\"" \
    "让当前 pane 继续 / 决定一次"        c "$pop \"TMUX_RADAR_AI_PAUSE=1 $SELF decide '#{pane_id}'\"" \
    "" \
    "常驻监控当前 pane 直到完成"         w "run-shell \"$SELF watch '#{pane_id}'\"" \
    "常驻监控 + always-allow（更省心）"  W "run-shell \"$SELF watch '#{pane_id}' '' always-allow\"" \
    "自定义监控（目标 / 间隔 / 策略）…"   v "$pop \"$SELF watch-setup '#{pane_id}'\"" \
    "" \
    "状态 / 最近决策"                   s "$pop \"TMUX_RADAR_AI_PAUSE=1 $SELF status\"" \
    "停止全部监控"                      S "run-shell \"$SELF stop all\"" \
    "列出 AI pane"                     l "$pop \"TMUX_RADAR_AI_PAUSE=1 $SELF list\""
}

_event_kind_valid() {
  case "$1" in
    approval|input_required|turn_complete|user_resumed|screen_idle|manual_reassess) return 0 ;;
    *) return 1 ;;
  esac
}

_emit_event_usage() {
  echo "usage: ai.sh emit-event <pane> <kind> <source> <label>" >&2
}

cmd_emit_event() {
  local pane="${1:-}" kind="${2:-}" source="${3:-}" label="${4-}"
  local sanitized expected_run_id="${TMUX_RADAR_EXPECT_RUN_ID:-}" event_id event_order extra intent_token
  if [ -z "$pane" ] || [ -z "$kind" ] || [ -z "$source" ] || [ "${4+x}" != x ]; then
    _emit_event_usage
    return 2
  fi
  if ! _event_kind_valid "$kind"; then
    echo "emit-event: invalid kind: $kind" >&2
    _emit_event_usage
    return 2
  fi
  sanitized="$(_flat "$label")"
  if ! radar_run_open "$pane" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$expected_run_id" ] && [ "$RADAR_RUN_ID" != "$expected_run_id" ]; then
    return 0
  fi
  [ -d "${RADAR_RUN_DIR:-}" ] || return 0
  event_id="${TMUX_RADAR_EVENT_ID:-}"
  if [ -z "$event_id" ]; then
    event_id="event-${RADAR_RUN_ID}-$(date '+%s')-$$-${RANDOM:-0}"
  fi
  intent_token="$$-${RANDOM:-0}-$(date '+%s')"
  DELIVERY_PENDING_FILE="$RADAR_RUN_DIR/.delivery-pending.$intent_token"
  printf 'pid=%s\ntoken=%s\nevent_id=%s\n' "$$" "$intent_token" "$event_id" > "$DELIVERY_PENDING_FILE"
  if ! _delivery_gate_acquire; then
    rm -f "$DELIVERY_PENDING_FILE"
    DELIVERY_PENDING_FILE=""
    echo "emit-event: delivery gate acquisition failed" >&2
    return 1
  fi
  event_order="$(_watch_next_event_order)" || {
    _delivery_cleanup
    echo "emit-event: failed to allocate event order" >&2
    return 1
  }
  extra="$(jq -cn --arg event_id "$event_id" --argjson event_order "$event_order" \
    '{event_id:$event_id,event_order:$event_order}')"
  if ! radar_inbox_append "$kind" "$source" "$sanitized" "$extra"; then
    _delivery_cleanup
    echo "emit-event: failed to append event" >&2
    return 1
  fi
  _delivery_gate_release
  rm -f "$DELIVERY_PENDING_FILE"
  DELIVERY_PENDING_FILE=""
  if [ -n "${RADAR_RUN_CHANNEL:-}" ] && have_tmux; then
    tmux wait-for -S "$RADAR_RUN_CHANNEL" >/dev/null 2>&1 || true
  fi
}

rc=0
case "${1:-}" in
  ask)          shift; cmd_ask "$@" || rc=$? ;;
  decide)       shift; cmd_decide "${1:-}" "${2:-}" "${3:-}" "${4:-}" || rc=$? ;;
  watch)        shift; cmd_watch "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" || rc=$? ;;
  emit-event)   shift; cmd_emit_event "$@" || rc=$? ;;
  watch-setup)  shift; cmd_watch_setup "${1:-}" || rc=$? ;;
  _watch_loop)  shift; cmd_watch_loop "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" || rc=$? ;;
  monitor)      shift; cmd_monitor "${1:-}" || rc=$? ;;
  monitor-timeline) shift; cmd_monitor_timeline "${1:-}" || rc=$? ;;
  monitor-detail) shift; cmd_monitor_detail "${1:-}" || rc=$? ;;
  stop)         shift; cmd_stop "${1:-all}" || rc=$? ;;
  status)       cmd_status || rc=$? ;;
  list)         cmd_list || rc=$? ;;
  cleanup)      cmd_cleanup || rc=$? ;;
  menu)         cmd_menu || rc=$? ;;
  *) echo "usage: ai.sh {ask [req]|decide [pane] [autonomy] [policy]|watch <pane> [goal] [policy] [poll] [autonomy]|emit-event <pane> <kind> <source> <label>|watch-setup [pane]|monitor <pane>|monitor-timeline <pane>|monitor-detail <pane>|stop <pane|all>|status|list|cleanup|menu}" >&2; exit 2 ;;
esac
# menu-launched popups set this so the result stays on screen until a keypress
if [ -n "${TMUX_RADAR_AI_PAUSE:-${TMUX_SWITCHER_AI_PAUSE:-}}" ] && [ -t 0 ]; then
  printf '\n%s按任意键关闭…%s' "$CD" "$CR"; read -n1 -r _ </dev/tty 2>/dev/null || true
fi
exit "$rc"

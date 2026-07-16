#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2153,SC2329
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
#   report [run-id|latest] print the final structured run summary
#   stop  <pane|all>    stop a resident watcher
#   status              list active watchers + recent decisions
#   list                list AI panes and their AI-status state
#   cleanup             GC stale watcher files / monitor panes / AI-status marks
#   menu                tmux display-menu entry point (prefix + <@radar-ai-key>)
#
# Config (tmux options, all optional):
#   @radar-ai-key            A                     menu key (prefix + A)
#   @radar-ai-model          gpt-5.6-luna          Codex model slug (fast tier)
#   @radar-ai-effort         high                  minimal|low|medium|high|xhigh
#   @radar-ai-profile        (none)                codex config profile (-p); overrides model/effort
#   @radar-ai-codex-path     (PATH)                absolute Codex executable override
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

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
# Interactive prompts use `read -e` (readline): canonical-mode reads erase CJK
# input by the BYTE (deleting one Chinese char took two+ presses and mangled
# the line). readline edits by character — but only under a UTF-8 locale.
case "${LC_ALL:-${LANG:-}}" in *[Uu][Tt][Ff]*) ;; *) export LANG=en_US.UTF-8 ;; esac
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF")"
PROMPT_DIR="$SCRIPT_DIR/prompts"
AI_RUNTIME_LIB="$SCRIPT_DIR/lib/ai-runtime.sh"
NOTIFY="${TMUX_RADAR_NOTIFY_CMD:-$SCRIPT_DIR/needinput-notify.sh}"
AI_MONITOR="$SCRIPT_DIR/ai-monitor.sh"
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
BRAIN_LAST_ERR_FILE=""
BRAIN_BACKEND_FROZEN=0
BRAIN_BACKEND_OK=0
BRAIN_BACKEND_MODE=""
BRAIN_BACKEND_PATH=""
BRAIN_BACKEND_VERSION=""
BRAIN_BACKEND_IDENTITY=""
BRAIN_BACKEND_SOURCE=""
BRAIN_BACKEND_COMMAND=""
BRAIN_BACKEND_PROFILE=""
BRAIN_BACKEND_MODEL="gpt-5.6-luna"
BRAIN_BACKEND_EFFORT="high"
BRAIN_BACKEND_WARNING=""
BRAIN_BACKEND_JSON='{}'
BRAIN_PREFLIGHT_JSON='{}'

DECISION_JSON=""
DECISION_ACTION=""
DECISION_TEXT=""
DECISION_SAFE=0
DECISION_REASON=""
DECISION_KEYS=()
DECISION_SCHEMA_VALID=0
DECISION_SCHEMA_ERROR=""
DECISION_READY=0
DECISION_FAILURE_KIND=""
DECISION_FAILURE_DETAIL=""
DECISION_MODEL_LAUNCHED=0

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
WATCH_TRANSIENT_RETRIES=0
WATCH_REPAIR_ATTEMPTS=0
WATCH_RETRY_LIMIT=3
WATCH_RETRY_BACKOFF=15
WATCH_EVENT_ID=""
WATCH_PHASE="CREATED"
WATCH_STATUS="starting"
WATCH_NEXT_KIND="none"
WATCH_NEXT_AT=0
WATCH_FINALIZED=0
WATCH_DELIVERY_FINGERPRINT=""

DELIVERY_GATE_HELD=0
DELIVERY_GATE_TOKEN=""
DELIVERY_GATE_DIR=""
DELIVERY_PENDING_FILE=""

opt() {
  local key="$1" def="$2" v legacy run_var=""
  case "$key" in
    @radar-ai-cmd) run_var=TMUX_RADAR_RUN_COMMAND ;;
    @radar-ai-profile) run_var=TMUX_RADAR_RUN_PROFILE ;;
    @radar-ai-model) run_var=TMUX_RADAR_RUN_MODEL ;;
    @radar-ai-effort) run_var=TMUX_RADAR_RUN_EFFORT ;;
    @radar-ai-watch-autonomy) run_var=TMUX_RADAR_RUN_AUTONOMY ;;
    @radar-ai-watch-always-allow) run_var=TMUX_RADAR_RUN_ALWAYS_ALLOW ;;
    @radar-ai-poll) run_var=TMUX_RADAR_RUN_POLL ;;
    @radar-ai-max-calls) run_var=TMUX_RADAR_RUN_MAX_DECISIONS ;;
    @radar-ai-timeout) run_var=TMUX_RADAR_RUN_TIMEOUT ;;
    @radar-ai-capture-lines) run_var=TMUX_RADAR_RUN_CAPTURE_LINES ;;
    @radar-ai-monitor-excerpt-lines) run_var=TMUX_RADAR_RUN_MONITOR_EXCERPT_LINES ;;
    @radar-ai-monitor-pos) run_var=TMUX_RADAR_RUN_MONITOR_POSITION ;;
    @radar-ai-monitor-size-h) run_var=TMUX_RADAR_RUN_MONITOR_WIDTH ;;
  esac
  if [ -n "$run_var" ] && [ "${!run_var+x}" = x ]; then
    printf '%s' "${!run_var}"
    return
  fi
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

_explicit_opt() {  # _explicit_opt <tmux-option>; empty means no inherited value
  local key="$1" value legacy
  value="$(tmux show-option -gqv "$key" 2>/dev/null || true)"
  if [ -z "$value" ]; then
    case "$key" in
      @radar-*)
        legacy="@switcher-${key#@radar-}"
        value="$(tmux show-option -gqv "$legacy" 2>/dev/null || true)"
        ;;
    esac
  fi
  printf '%s' "$value"
}

_config_constraint() {
  case "$1" in
    autonomy) printf 'one of suggest, confirm, auto-safe, auto' ;;
    approval_policy) printf 'one of safe-auto, manual, always-allow' ;;
    always_allow|hooks_first|screen_snapshots) printf 'one of on, off' ;;
    poll) printf 'number from 0.05 to 3600' ;;
    stable_screen_threshold) printf 'integer from 1 to 20' ;;
    effort) printf 'one of minimal, low, medium, high, xhigh' ;;
    timeout) printf 'integer from 5 to 3600' ;;
    max_decisions) printf 'integer from 1 to 10000' ;;
    retry_limit) printf 'integer from 0 to 10' ;;
    retry_backoff) printf 'integer from 0 to 3600' ;;
    capture_lines) printf 'integer from 20 to 5000' ;;
    monitor_excerpt_lines) printf 'integer from 3 to 500' ;;
    monitor_position) printf 'one of top, bottom, right' ;;
    monitor_width) printf 'integer from 20 to 240' ;;
    overview_ratio) printf 'integer from 15 to 50' ;;
    completion_close_delay) printf 'integer from 0 to 60' ;;
    logging) printf 'one of decision, full' ;;
    retention_days) printf 'integer from 0 to 3650' ;;
    goal|command|profile|model) printf 'any text value' ;;
    *) printf 'a known watch configuration key' ;;
  esac
}

_config_value_valid() {
  local key="$1" value="$2"
  case "$key" in
    goal|command|profile|model) return 0 ;;
    autonomy) case "$value" in suggest|confirm|auto-safe|auto) return 0 ;; esac ;;
    approval_policy) case "$value" in safe-auto|manual|always-allow) return 0 ;; esac ;;
    always_allow|hooks_first|screen_snapshots) case "$value" in on|off) return 0 ;; esac ;;
    effort) case "$value" in minimal|low|medium|high|xhigh) return 0 ;; esac ;;
    monitor_position) case "$value" in top|bottom|right) return 0 ;; esac ;;
    logging) case "$value" in decision|full) return 0 ;; esac ;;
    poll)
      case "$value" in ''|*[!0-9.]*) return 1 ;; esac
      awk -v n="$value" 'BEGIN {
        exit !(n ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && n >= 0.05 && n <= 3600)
      }'
      return $?
      ;;
    stable_screen_threshold) _integer_between "$value" 1 20; return $?
      ;;
    timeout) _integer_between "$value" 5 3600; return $?
      ;;
    max_decisions) _integer_between "$value" 1 10000; return $?
      ;;
    retry_limit) _integer_between "$value" 0 10; return $?
      ;;
    retry_backoff) _integer_between "$value" 0 3600; return $?
      ;;
    capture_lines) _integer_between "$value" 20 5000; return $?
      ;;
    monitor_excerpt_lines) _integer_between "$value" 3 500; return $?
      ;;
    monitor_width) _integer_between "$value" 20 240; return $?
      ;;
    overview_ratio) _integer_between "$value" 15 50; return $?
      ;;
    completion_close_delay) _integer_between "$value" 0 60; return $?
      ;;
    retention_days) _integer_between "$value" 0 3650; return $?
      ;;
  esac
  return 1
}

_integer_between() {
  local value="$1" min="$2" max="$3"
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]
}

_config_value_type() {
  case "$1" in
    poll|stable_screen_threshold|timeout|max_decisions|retry_limit|retry_backoff|capture_lines|monitor_excerpt_lines|monitor_width|overview_ratio|completion_close_delay|retention_days)
      printf number ;;
    *) printf string ;;
  esac
}

_config_set() {  # mutates CONFIG_JSON; preserves old effective value on rejection
  local key="$1" value="$2" source="$3" noisy="${4:-1}" type constraint
  if ! _config_value_valid "$key" "$value"; then
    constraint="$(_config_constraint "$key")"
    [ "$noisy" -eq 0 ] || printf 'rejected %s=%s; allowed: %s\n' "$key" "$value" "$constraint" >&2
    return 1
  fi
  type="$(_config_value_type "$key")"
  if [ "$type" = number ]; then
    CONFIG_JSON="$(printf '%s' "$CONFIG_JSON" | jq -c --arg key "$key" --arg source "$source" \
      --argjson value "$value" '.values[$key] = {value:$value,source:$source}')"
  else
    CONFIG_JSON="$(printf '%s' "$CONFIG_JSON" | jq -c --arg key "$key" --arg source "$source" \
      --arg value "$value" '.values[$key] = {value:$value,source:$source}')"
  fi
  return 0
}

_config_apply_overrides() {
  local overrides="$1" source="$2" item key value
  [ -n "$overrides" ] || return 0
  while [ -n "$overrides" ]; do
    case "$overrides" in
      *,*) item="${overrides%%,*}"; overrides="${overrides#*,}" ;;
      *) item="$overrides"; overrides="" ;;
    esac
    key="${item%%=*}"
    if [ "$item" = "$key" ]; then
      printf 'rejected %s; allowed: key=value\n' "$item" >&2
      continue
    fi
    value="${item#*=}"
    _config_set "$key" "$value" "$source" 1 || true
  done
}

_config_apply_tmux() {
  local key option value
  while IFS=$'\t' read -r key option; do
    value="$(_explicit_opt "$option")"
    [ -n "$value" ] || continue
    _config_set "$key" "$value" tmux 1 || true
  done <<'EOF'
autonomy	@radar-ai-watch-autonomy
approval_policy	@radar-ai-approval-policy
always_allow	@radar-ai-watch-always-allow
hooks_first	@radar-ai-hooks-first
poll	@radar-ai-poll
stable_screen_threshold	@radar-ai-stable-screen-threshold
command	@radar-ai-cmd
profile	@radar-ai-profile
model	@radar-ai-model
effort	@radar-ai-effort
timeout	@radar-ai-timeout
max_decisions	@radar-ai-max-calls
retry_limit	@radar-ai-retry-limit
retry_backoff	@radar-ai-retry-backoff
capture_lines	@radar-ai-capture-lines
monitor_excerpt_lines	@radar-ai-monitor-excerpt-lines
monitor_position	@radar-ai-monitor-pos
monitor_width	@radar-ai-monitor-size-h
overview_ratio	@radar-ai-overview-ratio
completion_close_delay	@radar-ai-completion-close-delay
logging	@radar-ai-logging
screen_snapshots	@radar-ai-screen-snapshots
retention_days	@radar-ai-retention-days
EOF
}

cmd_build_watch_config() {
  local pane="$1" raw_goal="${2-}" goal goal_source env_command
  need_jq
  if [ -n "$raw_goal" ]; then goal="$raw_goal"; goal_source=custom
  else goal='推进当前任务直到完成'; goal_source=default
  fi
  CONFIG_JSON="$(jq -cn --arg pane "$pane" --arg goal "$goal" --arg goal_source "$goal_source" '
    {schema_version:1,pane:$pane,goal:$goal,values:{
      goal:{value:$goal,source:$goal_source},
      autonomy:{value:"auto-safe",source:"default"},
      approval_policy:{value:"safe-auto",source:"default"},
      always_allow:{value:"off",source:"default"},
      hooks_first:{value:"on",source:"default"},
      poll:{value:5,source:"default"},
      stable_screen_threshold:{value:1,source:"default"},
      command:{value:"",source:"default"},
      profile:{value:"",source:"default"},
      model:{value:"gpt-5.6-luna",source:"default"},
      effort:{value:"high",source:"default"},
      timeout:{value:120,source:"default"},
      max_decisions:{value:40,source:"default"},
      retry_limit:{value:3,source:"default"},
      retry_backoff:{value:15,source:"default"},
      capture_lines:{value:120,source:"default"},
      monitor_excerpt_lines:{value:16,source:"default"},
      monitor_position:{value:"right",source:"default"},
      monitor_width:{value:84,source:"default"},
      overview_ratio:{value:25,source:"default"},
      completion_close_delay:{value:12,source:"default"},
      logging:{value:"decision",source:"default"},
      screen_snapshots:{value:"off",source:"default"},
      retention_days:{value:7,source:"default"}
    }}')"
  _config_apply_tmux
  _config_apply_overrides "${TMUX_RADAR_SETUP_OVERRIDES:-}" custom
  _config_apply_overrides "${TMUX_RADAR_RUNTIME_OVERRIDES:-}" runtime
  env_command="${TMUX_RADAR_AI_CMD:-${TMUX_SWITCHER_AI_CMD:-}}"
  [ -z "$env_command" ] || _config_set command "$env_command" runtime 0
  CONFIG_JSON="$(printf '%s' "$CONFIG_JSON" | jq -c '
    if .values.profile.value != "" then
      (if .values.model.source == "default" then .values.model={value:"",source:"profile-managed"} else . end) |
      (if .values.effort.source == "default" then .values.effort={value:"",source:"profile-managed"} else . end)
    else . end |
    .goal=.values.goal.value')"
  printf '%s\n' "$CONFIG_JSON"
}

cmd_decode_goal() {
  local raw="${1-}" mode=quick sentinel='__RADAR_ADVANCED__'
  case "$raw" in
    *"$sentinel") mode=advanced; raw="${raw%"$sentinel"}" ;;
  esac
  printf '%s\t%s' "$mode" "$raw"
}

cmd_render_watch_config() {
  local config="$1" group fields key value source
  need_jq
  while IFS=$'\t' read -r group fields; do
    printf '%s\n' "$group"
    for key in $fields; do
      value="$(_config_read "$config" "$key")"
      source="$(printf '%s' "$config" | jq -r --arg key "$key" '.values[$key].source')"
      printf '  %-26s = %s [%s]\n' "$key" "$value" "$source"
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

_config_read() {  # command substitution safe even when a value ends in newlines
  local config="$1" key="$2" marker='__RADAR_VALUE_END_8F3A1C__' encoded
  encoded="$(printf '%s' "$config" | jq -jr --arg key "$key" '.values[$key].value, "__RADAR_VALUE_END_8F3A1C__"')"
  printf '%s' "${encoded%"$marker"}"
}

_config_assign() {  # _config_assign <config> <key> <variable>; preserves terminal newlines
  local config="$1" key="$2" target="$3" marker='__RADAR_VALUE_END_8F3A1C__' encoded
  encoded="$(printf '%s' "$config" | jq -jr --arg key "$key" '.values[$key].value, "__RADAR_VALUE_END_8F3A1C__"')" || return 1
  encoded="${encoded%"$marker"}"
  printf -v "$target" '%s' "$encoded"
}

_apply_watch_config() {
  local config="$1"
  _config_assign "$config" goal TMUX_RADAR_RUN_GOAL
  _config_assign "$config" autonomy TMUX_RADAR_RUN_AUTONOMY
  _config_assign "$config" approval_policy TMUX_RADAR_RUN_APPROVAL_POLICY
  _config_assign "$config" always_allow TMUX_RADAR_RUN_ALWAYS_ALLOW
  _config_assign "$config" hooks_first TMUX_RADAR_RUN_HOOKS_FIRST
  _config_assign "$config" poll TMUX_RADAR_RUN_POLL
  _config_assign "$config" stable_screen_threshold TMUX_RADAR_RUN_STABLE_SCREEN_THRESHOLD
  _config_assign "$config" command TMUX_RADAR_RUN_COMMAND
  _config_assign "$config" profile TMUX_RADAR_RUN_PROFILE
  _config_assign "$config" model TMUX_RADAR_RUN_MODEL
  _config_assign "$config" effort TMUX_RADAR_RUN_EFFORT
  TMUX_RADAR_RUN_MODEL_SOURCE="$(printf '%s' "$config" | jq -r '.values.model.source')"
  TMUX_RADAR_RUN_EFFORT_SOURCE="$(printf '%s' "$config" | jq -r '.values.effort.source')"
  _config_assign "$config" timeout TMUX_RADAR_RUN_TIMEOUT
  _config_assign "$config" max_decisions TMUX_RADAR_RUN_MAX_DECISIONS
  _config_assign "$config" retry_limit TMUX_RADAR_RUN_RETRY_LIMIT
  _config_assign "$config" retry_backoff TMUX_RADAR_RUN_RETRY_BACKOFF
  _config_assign "$config" capture_lines TMUX_RADAR_RUN_CAPTURE_LINES
  _config_assign "$config" monitor_excerpt_lines TMUX_RADAR_RUN_MONITOR_EXCERPT_LINES
  _config_assign "$config" monitor_position TMUX_RADAR_RUN_MONITOR_POSITION
  _config_assign "$config" monitor_width TMUX_RADAR_RUN_MONITOR_WIDTH
  _config_assign "$config" overview_ratio TMUX_RADAR_RUN_OVERVIEW_RATIO
  _config_assign "$config" completion_close_delay TMUX_RADAR_RUN_COMPLETION_CLOSE_DELAY
  _config_assign "$config" logging TMUX_RADAR_RUN_LOGGING
  _config_assign "$config" screen_snapshots TMUX_RADAR_RUN_SCREEN_SNAPSHOTS
  _config_assign "$config" retention_days TMUX_RADAR_RUN_RETENTION_DAYS
  export TMUX_RADAR_RUN_GOAL TMUX_RADAR_RUN_AUTONOMY TMUX_RADAR_RUN_APPROVAL_POLICY
  export TMUX_RADAR_RUN_ALWAYS_ALLOW TMUX_RADAR_RUN_HOOKS_FIRST TMUX_RADAR_RUN_POLL
  export TMUX_RADAR_RUN_STABLE_SCREEN_THRESHOLD TMUX_RADAR_RUN_COMMAND TMUX_RADAR_RUN_PROFILE
  export TMUX_RADAR_RUN_MODEL TMUX_RADAR_RUN_EFFORT TMUX_RADAR_RUN_MODEL_SOURCE TMUX_RADAR_RUN_EFFORT_SOURCE
  export TMUX_RADAR_RUN_TIMEOUT
  export TMUX_RADAR_RUN_MAX_DECISIONS TMUX_RADAR_RUN_RETRY_LIMIT TMUX_RADAR_RUN_RETRY_BACKOFF
  export TMUX_RADAR_RUN_CAPTURE_LINES TMUX_RADAR_RUN_MONITOR_EXCERPT_LINES
  export TMUX_RADAR_RUN_MONITOR_POSITION TMUX_RADAR_RUN_MONITOR_WIDTH TMUX_RADAR_RUN_OVERVIEW_RATIO
  export TMUX_RADAR_RUN_COMPLETION_CLOSE_DELAY TMUX_RADAR_RUN_LOGGING
  export TMUX_RADAR_RUN_SCREEN_SNAPSHOTS TMUX_RADAR_RUN_RETENTION_DAYS
}

_watch_runtime_json() {
  _ensure_backend_frozen
  jq -cn \
    --arg goal "$TMUX_RADAR_RUN_GOAL" --arg autonomy "$TMUX_RADAR_RUN_AUTONOMY" \
    --arg approval_policy "$TMUX_RADAR_RUN_APPROVAL_POLICY" --arg always_allow "$TMUX_RADAR_RUN_ALWAYS_ALLOW" \
    --arg hooks_first "$TMUX_RADAR_RUN_HOOKS_FIRST" --arg command "$TMUX_RADAR_RUN_COMMAND" \
    --arg profile "$TMUX_RADAR_RUN_PROFILE" --arg model "$TMUX_RADAR_RUN_MODEL" --arg effort "$TMUX_RADAR_RUN_EFFORT" \
    --arg monitor_position "$TMUX_RADAR_RUN_MONITOR_POSITION" --arg logging "$TMUX_RADAR_RUN_LOGGING" \
    --arg screen_snapshots "$TMUX_RADAR_RUN_SCREEN_SNAPSHOTS" \
    --argjson poll "$TMUX_RADAR_RUN_POLL" --argjson stable_screen_threshold "$TMUX_RADAR_RUN_STABLE_SCREEN_THRESHOLD" \
    --argjson timeout "$TMUX_RADAR_RUN_TIMEOUT" --argjson max_decisions "$TMUX_RADAR_RUN_MAX_DECISIONS" \
    --argjson retry_limit "$TMUX_RADAR_RUN_RETRY_LIMIT" --argjson retry_backoff "$TMUX_RADAR_RUN_RETRY_BACKOFF" \
    --argjson capture_lines "$TMUX_RADAR_RUN_CAPTURE_LINES" --argjson monitor_excerpt_lines "$TMUX_RADAR_RUN_MONITOR_EXCERPT_LINES" \
    --argjson monitor_width "$TMUX_RADAR_RUN_MONITOR_WIDTH" --argjson overview_ratio "$TMUX_RADAR_RUN_OVERVIEW_RATIO" \
    --argjson completion_close_delay "$TMUX_RADAR_RUN_COMPLETION_CLOSE_DELAY" --argjson retention_days "$TMUX_RADAR_RUN_RETENTION_DAYS" \
    --argjson backend "$BRAIN_BACKEND_JSON" \
    '{goal:$goal,autonomy:$autonomy,approval_policy:$approval_policy,always_allow:$always_allow,
      hooks_first:$hooks_first,poll:$poll,stable_screen_threshold:$stable_screen_threshold,
      command:$command,profile:$profile,model:$model,effort:$effort,timeout:$timeout,
      max_decisions:$max_decisions,retry_limit:$retry_limit,retry_backoff:$retry_backoff,
      capture_lines:$capture_lines,monitor_excerpt_lines:$monitor_excerpt_lines,
      monitor_position:$monitor_position,monitor_width:$monitor_width,overview_ratio:$overview_ratio,
      completion_close_delay:$completion_close_delay,logging:$logging,
      screen_snapshots:$screen_snapshots,retention_days:$retention_days,backend:$backend}'
}

_codex_version() {
  local executable="$1" raw tmp pid started timeout=3 had_job_control=0
  [ -x "$executable" ] || return 1
  tmp="$(mktemp "${TMPDIR:-/tmp}/tmux-radar-version.XXXXXX")" || return 1
  case "$-" in *m*) had_job_control=1 ;; esac
  set -m
  ("$executable" --version 2>/dev/null | head -c 4096 > "$tmp") &
  pid=$!
  [ "$had_job_control" -eq 1 ] || set +m
  started="$(date '+%s')"
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$(( $(date '+%s') - started ))" -ge "$timeout" ]; then
      _terminate_process_tree "$pid" "$pid"
      break
    fi
    sleep 0.05
  done
  wait "$pid" 2>/dev/null || true
  raw="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  printf '%s\n' "$raw" |
    awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+[.][0-9]+[.][0-9]+$/) { print $i; exit } }'
}

_backend_file_identity() {
  local executable="$1" identity
  # This guard detects package upgrades/path drift between preflight and a
  # model call. It is not a same-user security sandbox: a process that can
  # replace the user's Codex can also rewrite this plugin, tmux options, and
  # run state. Copying Codex into a private artifact would hide upgrades and
  # execute a different path than the one shown during launch review.
  identity="$(stat -f '%d:%i:%m:%z' "$executable" 2>/dev/null || true)"
  [ -n "$identity" ] || identity="$(stat -c '%d:%i:%Y:%s' "$executable" 2>/dev/null || true)"
  printf '%s' "$identity"
}

_version_ge() {
  local actual="$1" required="$2"
  awk -v actual="$actual" -v required="$required" 'BEGIN {
    split(actual, a, "."); split(required, r, ".")
    for (i = 1; i <= 3; i++) {
      av = a[i] + 0; rv = r[i] + 0
      if (av > rv) exit 0
      if (av < rv) exit 1
    }
    exit 0
  }'
}

_model_min_codex() {
  case "$1" in
    gpt-5.6-luna) printf '%s' '0.144.0' ;;
    *) printf '%s' '0.0.0' ;;
  esac
}

_absolute_executable() {
  local requested="$1" found dir
  [ -n "$requested" ] || return 1
  case "$requested" in
    */*)
      [ -x "$requested" ] || return 1
      case "$requested" in
        /*) printf '%s' "$requested" ;;
        *)
          dir="$(cd "$(dirname "$requested")" 2>/dev/null && pwd -P)" || return 1
          printf '%s/%s' "$dir" "$(basename "$requested")"
          ;;
      esac
      ;;
    *)
      found="$(command -v "$requested" 2>/dev/null || true)"
      [ -n "$found" ] && [ -x "$found" ] || return 1
      case "$found" in
        /*) printf '%s' "$found" ;;
        *)
          dir="$(cd "$(dirname "$found")" 2>/dev/null && pwd -P)" || return 1
          printf '%s/%s' "$dir" "$(basename "$found")"
          ;;
      esac
      ;;
  esac
}

_codex_candidates_json() {
  local selected="$1" model="$2" candidates='[]' paths candidate absolute version minimum compatible item seen=''
  minimum="$(_model_min_codex "$model")"
  paths="$(type -a -p codex 2>/dev/null || true)"
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    absolute="$(_absolute_executable "$candidate" 2>/dev/null || true)"
    [ -n "$absolute" ] || continue
    [ "$absolute" = "$selected" ] && continue
    case "$seen" in *$'\n'"$absolute"$'\n'*) continue ;; esac
    seen="$seen"$'\n'"$absolute"$'\n'
    version="$(_codex_version "$absolute" || true)"
    compatible=0
    [ -n "$version" ] && _version_ge "$version" "$minimum" && compatible=1
    item="$(jq -cn --arg path "$absolute" --arg version "$version" \
      --arg source path --arg required_version "$minimum" --argjson compatible "$compatible" \
      '{path:$path,version:$version,source:$source,required_version:$required_version,
        compatible:($compatible == 1)}')"
    candidates="$(jq -cn --argjson items "$candidates" --argjson item "$item" '$items + [$item]')"
  done <<< "$paths"
  printf '%s' "$candidates"
}

_freeze_backend() {
  local diagnostics="${1:-0}" custom explicit selected version minimum compatible=0
  local source='path' profile model effort model_source effort_source warning='' candidates='[]' class='' summary='' detail=''
  BRAIN_BACKEND_FROZEN=1
  BRAIN_BACKEND_OK=0
  BRAIN_BACKEND_MODE=''
  BRAIN_BACKEND_PATH=''
  BRAIN_BACKEND_VERSION=''
  BRAIN_BACKEND_IDENTITY=''
  BRAIN_BACKEND_SOURCE=''
  BRAIN_BACKEND_COMMAND=''
  BRAIN_BACKEND_PROFILE=''
  BRAIN_BACKEND_WARNING=''

  model="$(opt @radar-ai-model gpt-5.6-luna)"
  effort="$(opt @radar-ai-effort high)"
  profile="$(opt @radar-ai-profile '')"
  model_source="${TMUX_RADAR_RUN_MODEL_SOURCE:-}"
  effort_source="${TMUX_RADAR_RUN_EFFORT_SOURCE:-}"
  if [ -z "$model_source" ]; then
    if [ -n "$profile" ] && [ -z "$(_explicit_opt @radar-ai-model)" ]; then
      model=''; model_source='profile-managed'
    elif [ -n "$(_explicit_opt @radar-ai-model)" ]; then model_source='tmux'
    else model_source='default'; fi
  fi
  if [ -z "$effort_source" ]; then
    if [ -n "$profile" ] && [ -z "$(_explicit_opt @radar-ai-effort)" ]; then
      effort=''; effort_source='profile-managed'
    elif [ -n "$(_explicit_opt @radar-ai-effort)" ]; then effort_source='tmux'
    else effort_source='default'; fi
  fi
  custom="${TMUX_RADAR_AI_CMD:-${TMUX_SWITCHER_AI_CMD:-}}"
  if [ -n "$custom" ]; then
    source='env'
  else
    custom="$(opt @radar-ai-cmd '')"
    [ -n "$custom" ] && source='config'
  fi

  BRAIN_BACKEND_MODEL="$model"
  BRAIN_BACKEND_EFFORT="$effort"
  BRAIN_BACKEND_PROFILE="$profile"
  if [ -n "$custom" ]; then
    [ -n "$profile" ] && warning='custom command takes precedence over the configured Codex profile'
    BRAIN_BACKEND_OK=1
    BRAIN_BACKEND_MODE='custom-command'
    BRAIN_BACKEND_COMMAND="$custom"
    BRAIN_BACKEND_SOURCE="$source"
    BRAIN_BACKEND_WARNING="$warning"
    BRAIN_BACKEND_JSON="$(jq -cn --arg mode "$BRAIN_BACKEND_MODE" --arg command "$custom" \
      --arg source "$source" --arg profile "$profile" --arg warning "$warning" \
      --arg model "$model" --arg effort "$effort" --arg model_source "$model_source" --arg effort_source "$effort_source" \
      '{mode:$mode,command:$command,source:$source,profile:$profile,warning:$warning,
        model:$model,effort:$effort,model_source:$model_source,effort_source:$effort_source}')"
    BRAIN_PREFLIGHT_JSON="$(jq -cn --argjson backend "$BRAIN_BACKEND_JSON" \
      --arg model "$model" --arg effort "$effort" --argjson candidates "$candidates" \
      '{ok:true,backend:$backend,model:$model,effort:$effort,candidates:$candidates}')"
    [ -z "$warning" ] || printf 'tmux-radar: %s\n' "$warning" >&2
    return 0
  fi

  explicit="$(_explicit_opt @radar-ai-codex-path)"
  [ -n "$explicit" ] && source='tmux'
  if [ -n "$explicit" ]; then
    selected="$(_absolute_executable "$explicit" 2>/dev/null || true)"
  else
    selected="$(_absolute_executable codex 2>/dev/null || true)"
    source='path'
  fi

  minimum="$(_model_min_codex "$model")"
  if [ -z "$selected" ]; then
    class='config-permanent'
    summary='Codex executable is missing or not executable'
    detail="requested=${explicit:-codex}"
  else
    version="$(_codex_version "$selected" || true)"
    if [ -z "$version" ]; then
      class='config-permanent'
      summary='Codex version could not be determined'
      detail="path=$selected"
    elif _version_ge "$version" "$minimum"; then
      compatible=1
      BRAIN_BACKEND_OK=1
    else
      class='config-permanent'
      summary="Codex $version is too old for $model"
      detail="requires Codex >= $minimum"
    fi
  fi
  [ "$diagnostics" = 1 ] && candidates="$(_codex_candidates_json "$selected" "$model")"

  BRAIN_BACKEND_MODE='codex'
  BRAIN_BACKEND_PATH="$selected"
  BRAIN_BACKEND_VERSION="$version"
  BRAIN_BACKEND_IDENTITY="$(_backend_file_identity "$selected")"
  BRAIN_BACKEND_SOURCE="$source"
  BRAIN_BACKEND_JSON="$(jq -cn --arg mode "$BRAIN_BACKEND_MODE" --arg path "$selected" \
    --arg version "$version" --arg identity "$BRAIN_BACKEND_IDENTITY" --arg source "$source" --arg profile "$profile" \
    --arg model "$model" --arg effort "$effort" --arg model_source "$model_source" --arg effort_source "$effort_source" \
    --arg required_version "$minimum" --argjson compatible "$compatible" \
    '{mode:$mode,path:$path,version:$version,identity:$identity,source:$source,profile:$profile,
      model:$model,effort:$effort,model_source:$model_source,effort_source:$effort_source,
      required_version:$required_version,compatible:($compatible == 1)}')"
  BRAIN_PREFLIGHT_JSON="$(jq -cn --argjson ok "$BRAIN_BACKEND_OK" \
    --argjson backend "$BRAIN_BACKEND_JSON" --arg model "$model" --arg effort "$effort" \
    --argjson candidates "$candidates" --arg class "$class" --arg summary "$summary" --arg detail "$detail" '
    {ok:($ok == 1),backend:$backend,model:$model,effort:$effort,candidates:$candidates}
    + (if $class == "" then {} else {class:$class,summary:$summary,detail:$detail} end)')"
}

_ensure_backend_frozen() {
  [ "$BRAIN_BACKEND_FROZEN" -eq 1 ] || _freeze_backend 0
}

cmd_doctor_json() {
  need_jq
  _freeze_backend 1
  printf '%s\n' "$BRAIN_PREFLIGHT_JSON"
}

have_tmux() { command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; }
need_jq()  { command -v jq >/dev/null 2>&1 || { echo "tmux-radar AI needs 'jq'." >&2; exit 3; }; }
have_brain() { _ensure_backend_frozen; [ "$BRAIN_BACKEND_OK" -eq 1 ]; }
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

_decision_call_tag() {
  local call="${WATCH_CALLS:-1}"
  case "$call" in ''|*[!0-9]*) call=1 ;; esac
  printf '%04d' "$call"
}

_persist_decision_call() {
  local tag="$1" json="$2" backend="$3" autonomy="$4" policy="$5"
  local decision_file meta_file payload model profile effort
  [ -n "${RADAR_RUN_DIR:-}" ] || return 0
  mkdir -p "$RADAR_RUN_DIR/decisions" "$RADAR_RUN_DIR/backend"
  decision_file="$RADAR_RUN_DIR/decisions/$tag.json"
  meta_file="$RADAR_RUN_DIR/decisions/$tag.meta.json"
  if [ "$DECISION_SCHEMA_VALID" -eq 1 ]; then
    _radar_write_snapshot "$decision_file" "$json"
  else
    payload="$(jq -cn --arg raw "$json" --arg error "$DECISION_SCHEMA_ERROR" \
      '{valid:false,raw:$raw,error:$error}')"
    _radar_write_snapshot "$decision_file" "$payload"
  fi
  _ensure_backend_frozen
  model="$BRAIN_BACKEND_MODEL"
  profile="$BRAIN_BACKEND_PROFILE"
  effort="$BRAIN_BACKEND_EFFORT"
  payload="$(jq -cn \
    --arg run_id "$RADAR_RUN_ID" --arg pane "$RADAR_RUN_PANE" \
    --arg event_id "${WATCH_EVENT_ID:-}" --arg backend "$backend" \
    --arg autonomy "$autonomy" --arg policy "${policy:-safe-auto}" \
    --arg model "$model" --arg profile "$profile" --arg effort "$effort" \
    --arg schema_error "$DECISION_SCHEMA_ERROR" --arg completed_at "$(_radar_now_iso)" \
    --argjson call "$((10#$tag))" --argjson started_at "${BRAIN_LAST_STARTED:-0}" \
    --argjson elapsed_seconds "${BRAIN_LAST_ELAPSED:-0}" \
    --argjson timeout_seconds "${BRAIN_LAST_TIMEOUT:-0}" \
    --argjson backend_rc "${BRAIN_LAST_RC:-0}" \
    --argjson schema_valid "$DECISION_SCHEMA_VALID" \
    '{schema_version:1,run_id:$run_id,pane:$pane,event_id:$event_id,call:$call,backend:$backend,
      model:$model,profile:$profile,effort:$effort,autonomy:$autonomy,policy:$policy,
      started_at:$started_at,elapsed_seconds:$elapsed_seconds,
      timeout_seconds:$timeout_seconds,backend_rc:$backend_rc,
      schema_valid:($schema_valid == 1),schema_error:$schema_error,completed_at:$completed_at}')"
  _radar_write_snapshot "$meta_file" "$payload"
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
  local wf="$WATCH_WF" tmp run_id run_dir channel overview detail monitors_file
  [ -n "$wf" ] || return 0
  run_id="$(_state_get "$wf" run_id)"; [ -n "$run_id" ] || run_id="${RADAR_RUN_ID:-}"
  run_dir="$(_state_get "$wf" run_dir)"; [ -n "$run_dir" ] || run_dir="${RADAR_RUN_DIR:-}"
  channel="$(_state_get "$wf" channel)"; [ -n "$channel" ] || channel="${RADAR_RUN_CHANNEL:-}"
  monitors_file="$run_dir/monitors"
  if [ -r "$monitors_file" ]; then
    overview="$(_state_get "$monitors_file" monitor_overview_pane)"
    detail="$(_state_get "$monitors_file" monitor_detail_pane)"
  else
    overview="$(_state_get "$wf" monitor_overview_pane)"
    detail="$(_state_get "$wf" monitor_detail_pane)"
  fi
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
  local wf="$1" overview="${2:-}" detail="${3:-}" tmp run_dir monitors_file monitors_tmp
  [ -r "$wf" ] || return 0
  run_dir="$(_state_get "$wf" run_dir)"
  if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
    monitors_file="$run_dir/monitors"
    monitors_tmp="$(mktemp "$run_dir/.monitors.XXXXXX")" || return 1
    printf 'monitor_overview_pane=%s\nmonitor_detail_pane=%s\n' \
      "$overview" "$detail" > "$monitors_tmp"
    mv "$monitors_tmp" "$monitors_file"
  fi
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
  local extra="${1:-}" payload tmp base timestamp
  [ -n "$extra" ] || extra='{}'
  [ -n "${RADAR_RUN_DIR:-}" ] || return 0
  if [ -r "$RADAR_RUN_DIR/state.json" ]; then base="$(cat "$RADAR_RUN_DIR/state.json")"; else base='{}'; fi
  timestamp="$(_radar_now_iso)"
  payload="$(printf '%s' "$base" | jq -c \
    --argjson extra "$extra" \
    --arg phase "$WATCH_PHASE" --arg status "$WATCH_STATUS" \
    --arg event_id "$WATCH_EVENT_ID" --arg goal "$WATCH_GOAL" \
    --arg policy "${WATCH_POLICY:-safe-auto}" --arg autonomy "$WATCH_AUTONOMY" \
    --arg next_kind "$WATCH_NEXT_KIND" --argjson next_at "${WATCH_NEXT_AT:-0}" \
    --arg run_id "$RADAR_RUN_ID" --arg pane "$WATCH_PANE" --arg timestamp "$timestamp" \
    --argjson poll "$(awk -v p="$WATCH_POLL" 'BEGIN { printf "%.6f", p+0 }')" \
    --argjson calls "$WATCH_CALLS" --argjson max_calls "$WATCH_MAX_CALLS" \
    --argjson retry "$WATCH_RETRY" --argjson waiter_pid "${WATCH_WAITER_PID:-0}" \
    --argjson timer_pid "${WATCH_TIMER_PID:-0}" \
    --argjson model_started_at "${BRAIN_LAST_STARTED:-0}" \
    --argjson model_elapsed "${BRAIN_LAST_ELAPSED:-0}" \
    --argjson model_timeout "${BRAIN_LAST_TIMEOUT:-0}" \
    --argjson model_pid "${BRAIN_LAST_PID:-0}" \
    --argjson model_pgid "${BRAIN_LAST_PGID:-0}" \
    '. + $extra + {schema_version:1,
      phase:$phase,status:$status,event_id:$event_id,goal:$goal,policy:$policy,
      autonomy:$autonomy,poll:$poll,calls:$calls,max_calls:$max_calls,retry:$retry,
      next:{kind:$next_kind,at:$next_at},run_id:$run_id,pane:$pane,updated_at:$timestamp,
      waiter_pid:$waiter_pid,timer_pid:$timer_pid,
      model:{started_at:$model_started_at,elapsed:$model_elapsed,pid:$model_pid,
             pgid:$model_pgid,timeout:$model_timeout,call_count:$calls}
    }')" || return 1
  tmp="$(mktemp "$RADAR_RUN_DIR/.state.XXXXXX")" || return 1
  printf '%s\n' "$payload" > "$tmp"
  mv "$tmp" "$RADAR_RUN_DIR/state.json"
  _watch_pointer_write
}

_watch_phase() {
  local phase="$1" status="$2" next_kind="${3:-none}" next_at="${4:-0}" extra="${5:-}"
  [ -n "$extra" ] || extra='{}'
  WATCH_PHASE="$phase"; WATCH_STATUS="$status"; WATCH_NEXT_KIND="$next_kind"; WATCH_NEXT_AT="$next_at"
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
  local p="${1:-}" resolved
  [ -z "$p" ] && p="${TMUX_PANE:-}"
  if [ -z "$p" ] && [ -r "$STATE_FILE" ]; then
    p="$(awk -F '\t' '$1 != "-" && NF >= 2 { if ($2+0 >= best) { best=$2+0; win=$1 } } END { print win }' "$STATE_FILE" 2>/dev/null || true)"
  fi
  [ -n "$p" ] || return 1
  case "$p" in
    %*)
      if tmux list-panes -a -F '#{pane_id}' 2>/dev/null | awk -v pane="$p" '$0 == pane { found=1 } END { exit !found }'; then
        printf '%s\n' "$p"
        return 0
      fi
      ;;
  esac
  resolved="$(tmux display-message -p -t "$p" '#{pane_id}' 2>/dev/null || true)"
  [ -n "$resolved" ] || return 1
  printf '%s\n' "$resolved"
}

# ---------------------------------------------------------------------------
# Codex brain. _brain <schema-file> <prompt>  ->  final decision JSON on stdout.
# Codex is read-only + ephemeral; only its --output-schema'd last message is used.
# ---------------------------------------------------------------------------
_brain() {
  local schema="$1" prompt="$2" out err pid pid_tmp rc=0 started timeout stop_reason="" had_job_control=0
  _ensure_backend_frozen
  BRAIN_RESULT=""
  BRAIN_LAST_RC=0
  BRAIN_LAST_STARTED=0
  BRAIN_LAST_ELAPSED=0
  BRAIN_LAST_TIMEOUT=0
  BRAIN_LAST_PID=""
  BRAIN_LAST_PGID=""
  BRAIN_STOP_REASON=""
  DECISION_MODEL_LAUNCHED=0
  err="${TMUX_RADAR_AI_ERR:-${TMUX_SWITCHER_AI_ERR:-/dev/null}}"
  [ "$err" = "/dev/null" ] || : > "$err" 2>/dev/null || true
  if [ "$BRAIN_BACKEND_OK" -ne 1 ]; then
    BRAIN_LAST_RC=78
    BRAIN_STOP_REASON="$(printf '%s' "$BRAIN_PREFLIGHT_JSON" | jq -r '.summary // "backend preflight failed"')"
    [ "$err" = "/dev/null" ] || printf '%s\n' "$BRAIN_STOP_REASON" > "$err"
    return 0
  fi
  if [ -n "${TMUX_RADAR_TEST_BEFORE_BRAIN_BLOCK:-}" ]; then
    : > "${TMUX_RADAR_TEST_BEFORE_BRAIN_BLOCK}.ready"
    while [ -e "$TMUX_RADAR_TEST_BEFORE_BRAIN_BLOCK" ]; do sleep 0.01; done
  fi
  if [ "$BRAIN_BACKEND_MODE" = codex ] && \
     [ "$(_backend_file_identity "$BRAIN_BACKEND_PATH")" != "$BRAIN_BACKEND_IDENTITY" ]; then
    BRAIN_LAST_RC=78
    BRAIN_STOP_REASON='selected Codex executable changed after preflight'
    [ "$err" = "/dev/null" ] || printf '%s\n' "$BRAIN_STOP_REASON" > "$err"
    return 0
  fi
  out="$(mktemp "${TMPDIR:-/tmp}/tmuxai.XXXXXX")"
  BRAIN_OUT_FILE="$out"
  case "$-" in *m*) had_job_control=1 ;; esac
  set -m
  if [ "$BRAIN_BACKEND_MODE" = custom-command ]; then
    (export TMUX_RADAR_INTERNAL=1; printf '%s' "$prompt" | eval "$BRAIN_BACKEND_COMMAND" > "$out" 2>"$err") &
  elif [ -n "$BRAIN_BACKEND_PROFILE" ]; then
    # a codex profile bundles model/effort/etc in ~/.codex/config.toml; the
    # safety flags (read-only, ephemeral) stay ours and are not overridable
    TMUX_RADAR_INTERNAL=1 "$BRAIN_BACKEND_PATH" exec -p "$BRAIN_BACKEND_PROFILE" \
      -s read-only --ephemeral --skip-git-repo-check \
      --output-schema "$schema" -o "$out" -- "$prompt" >/dev/null 2>"$err" &
  else
    TMUX_RADAR_INTERNAL=1 "$BRAIN_BACKEND_PATH" exec \
      -m "$BRAIN_BACKEND_MODEL" \
      -c model_reasoning_effort="$BRAIN_BACKEND_EFFORT" \
      -s read-only --ephemeral --skip-git-repo-check \
      --output-schema "$schema" -o "$out" -- "$prompt" >/dev/null 2>"$err" &
  fi
  BRAIN_PID=$!
  DECISION_MODEL_LAUNCHED=1
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
    pid_tmp="$(mktemp "${BRAIN_PID_FILE}.tmp.XXXXXX")" || pid_tmp=''
  fi
  if [ -n "${pid_tmp:-}" ]; then
    {
      printf 'pid=%s\npgid=%s\nwatch_pid=%s\npane=%s\nstarted=%s\noutput=%s\n' \
        "$pid" "$BRAIN_PGID" "$$" "${BRAIN_BOUND_PANE:-}" "$started" "$out"
    } > "$pid_tmp"
    chmod 600 "$pid_tmp" 2>/dev/null || true
    mv "$pid_tmp" "$BRAIN_PID_FILE"
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
  _ensure_backend_frozen
  if [ "$BRAIN_BACKEND_MODE" = custom-command ]; then
    printf 'custom command: %s' "$(_flat "$BRAIN_BACKEND_COMMAND")"
  elif [ -n "$BRAIN_BACKEND_PROFILE" ]; then
    printf 'codex %s profile: %s (read-only, ephemeral)' \
      "$BRAIN_BACKEND_VERSION" "$BRAIN_BACKEND_PROFILE"
  else
    printf 'codex %s: model=%s effort=%s (read-only, ephemeral)' \
      "$BRAIN_BACKEND_VERSION" "$BRAIN_BACKEND_MODEL" "$BRAIN_BACKEND_EFFORT"
  fi
}

_classify_backend_failure() {
  local rc="$1" stderr_file="$2" schema_valid="$3" stop_reason="${4:-}" stderr_text normalized
  local class code retryable summary detail
  stderr_text="$(tail -c 16384 "$stderr_file" 2>/dev/null || true)"
  normalized="$(printf '%s' "$stderr_text" | tr '[:upper:]' '[:lower:]')"
  class='transient'; code='backend-failed'; retryable=1; summary='backend failed with a retryable error'; detail='see stderr_path for private evidence'

  if [ "$rc" -eq 78 ]; then
    class='config-permanent'; code='backend-preflight'; retryable=0
    summary="${stop_reason:-backend preflight failed}"
    detail='backend rejected before model launch'
    case "$stop_reason" in *changed*after*preflight*) code='backend-identity-changed' ;; esac
  elif [ "$rc" -ne 0 ]; then
    case "$rc" in
      126|127)
        class='config-permanent'; retryable=0; summary='backend executable could not be launched'
        if [ "$rc" -eq 126 ]; then code='backend-not-executable'; else code='backend-command-missing'; fi
        ;;
      *)
        case "$normalized" in
          *requires*a*newer*version*|*unsupported*model*|*unknown*model*|*model*not*found*|\
          *profile*not*found*|*authentication*|*unauthorized*|*invalid*api*key*|\
          *not*logged*in*|*forbidden*|*permission*denied*)
            class='config-permanent'; code='backend-config-invalid'; retryable=0
            summary='backend configuration cannot run the selected model'
            ;;
          *rate*limit*|*too*many*requests*|*connection*|*network*|*temporar*|\
          *timed*out*|*timeout*|*service*unavailable*|*server*error*)
            class='transient'; code='backend-transport'; retryable=1
            ;;
        esac
        ;;
    esac
  elif [ "$schema_valid" -ne 1 ]; then
    class='output-invalid'; code='decision-output-invalid'; retryable=1
    summary='model output failed decision validation'
    detail='decision schema/type validation failed'
  fi

  jq -cn --arg class "$class" --arg code "$code" --arg summary "$summary" --arg detail "$detail" \
    --argjson retryable "$retryable" \
    '{class:$class,code:$code,retryable:($retryable == 1),summary:$summary,detail:$detail}'
}

_classify_outcome() {
  local kind="$1"
  shift
  case "$kind" in
    backend) _classify_backend_failure "$@" ;;
    policy-halt)
      jq -cn --arg summary "${1:-policy requires user action}" \
        '{class:"policy-halt",code:"policy-requires-user",retryable:false,summary:$summary,detail:""}'
      ;;
    decision-invalid)
      jq -cn --arg summary "${1:-decision violates the current event contract}" \
        '{class:"decision-invalid",code:"decision-contract-invalid",retryable:true,summary:$summary,
          detail:"repair must satisfy the event-specific decision contract"}'
      ;;
    *) return 2 ;;
  esac
}

_watch_record_backend_error() {
  local classification="$1" stderr_path="$2" call="$3" summary error_event_id timestamp
  summary="$(printf '%s' "$classification" | jq -r '.summary')"
  error_event_id="${WATCH_EVENT_ID:-$RADAR_RUN_ID}:backend:$call"
  timestamp="$(_radar_now_iso)"
  radar_event_append backend_error watcher "$summary" "$(jq -cn \
    --argjson classification "$classification" \
    --arg event_id "$error_event_id" --arg trigger_event_id "${WATCH_EVENT_ID:-}" --arg backend_mode "$BRAIN_BACKEND_MODE" \
    --arg backend_path "$BRAIN_BACKEND_PATH" --arg backend_version "$BRAIN_BACKEND_VERSION" \
    --arg stderr_path "$stderr_path" --arg timestamp "$timestamp" --argjson call "$call" '
    {schema_version:1,record:"error",event_id:$event_id,trigger_event_id:$trigger_event_id,
     error:{class:$classification.class,code:$classification.code,retryable:$classification.retryable,
       summary:$classification.summary,detail:$classification.detail,backend_mode:$backend_mode,
       backend_path:$backend_path,backend_version:$backend_version,stderr_path:$stderr_path,
       call:$call,timestamp:$timestamp}}')"
  _watch_state_snapshot "$(jq -cn --arg event_id "$error_event_id" '{latest_error_event_id:$event_id}')"
}

_escalate() {
  local pane="$1" message="$2"
  if [ -x "$NOTIFY" ] && "$NOTIFY" mark "$pane" ai "$message" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "${RADAR_RUN_DIR:-}" ]; then
    radar_event_append notification_failed notifier 'user notification could not be delivered' \
      '{"record":"notification_error","retryable":false}' || true
  fi
  audit "notification-failed\t$pane\t$(_flat "$message")"
  return 0
}
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
  local pane autonomy policy goal cap cap_tail where json pretty_json action text safe reason extra="" prompt backend
  local excerpt_lines errfile err_tail call_tag="" logging snapshots TMUX_RADAR_AI_ERR="" TMUX_SWITCHER_AI_ERR=""
  DECISION_READY=0
  DECISION_FAILURE_KIND=""
  DECISION_FAILURE_DETAIL=""
  DECISION_MODEL_LAUNCHED=0
  BRAIN_LAST_ERR_FILE=""
  if ! have_brain; then
    DECISION_FAILURE_KIND='config-permanent'
    DECISION_FAILURE_DETAIL="$(printf '%s' "$BRAIN_PREFLIGHT_JSON" | jq -r '.summary // "backend unavailable"')"
    echo "codex 未安装/不可用，无法决策。"
    return 3
  fi
  if ! pane="$(_resolve_pane "${1:-}")"; then
    DECISION_FAILURE_KIND='lifecycle-stop'
    DECISION_FAILURE_DETAIL='target pane disappeared before decision capture'
    echo "no target pane"
    return 5
  fi
  autonomy="${2:-$(opt @radar-ai-autonomy confirm)}"
  policy="${3:-}"
  goal="${4:-}"
  if [ -n "$goal" ]; then
    extra=$'\n\nGOAL (set by the user for this watch): '"$goal"
    case "$goal" in
      *$'\n') : ;;
      *) extra="$extra"$'\n' ;;
    esac
    extra="${extra}Steer the pane toward completing this goal. If the pane asks a question whose answer is implied by the goal, answer it; only report \`done\` when the goal itself looks achieved."
  fi
  if [ "$policy" = "always-allow" ]; then
    extra="$extra"$'\n\nPOLICY: watch-until-done with ALWAYS-ALLOW enabled. When the pending action is SAFE and the prompt offers a "Yes, and don\'t ask again" / "always allow" / "don\'t ask again for … commands" option, PREFER that option so the agent stops interrupting for this command type. Still escalate anything destructive or ambiguous; NEVER pick an always-allow option for an unsafe action.'
  fi
  extra="$extra$(_user_rules)"
  if [ "${TMUX_RADAR_REPAIR_ATTEMPT:-0}" -gt 0 ] 2>/dev/null; then
    extra="$extra"$'\n\nREPAIR: the previous decision was invalid: '"${TMUX_RADAR_REPAIR_REASON:-decision schema/type validation failed}"$'. Return exactly one corrected decision object that satisfies both the JSON schema and the event-specific action constraints; do not add prose or markdown.'
  fi
  where="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null || echo "$pane")"
  cap="$(tmux capture-pane -p -t "$pane" -S "-$(opt @radar-ai-capture-lines 120)" 2>/dev/null || true)"
  if [ -z "$cap" ]; then
    if tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1; then
      DECISION_FAILURE_KIND='capture-error'
      DECISION_FAILURE_DETAIL='target pane capture returned no readable content'
    else
      DECISION_FAILURE_KIND='lifecycle-stop'
      DECISION_FAILURE_DETAIL='target pane disappeared during decision capture'
    fi
    echo "pane $pane: nothing to read"
    return 5
  fi
  excerpt_lines="$(_monitor_excerpt_lines)"
  cap_tail="$(printf '%s\n' "$cap" | tail -n "$excerpt_lines")"

  prompt="$(_skill decide.md)$extra"$'\n\n'"PANE ($where):"$'\n'"$cap"
  backend="$(_brain_label)"
  if [ -n "${RADAR_RUN_DIR:-}" ]; then
    call_tag="$(_decision_call_tag)"
    mkdir -p "$RADAR_RUN_DIR/decisions" "$RADAR_RUN_DIR/backend"
    errfile="$RADAR_RUN_DIR/backend/$call_tag.stderr"
    logging="${TMUX_RADAR_RUN_LOGGING:-decision}"
    snapshots="${TMUX_RADAR_RUN_SCREEN_SNAPSHOTS:-off}"
    if [ "$logging" = full ] || [ "$snapshots" = on ]; then
      mkdir -p "$RADAR_RUN_DIR/screens"
      _radar_write_snapshot "$RADAR_RUN_DIR/screens/$call_tag.txt" "$cap"
    fi
    if [ "$logging" = full ]; then
      mkdir -p "$RADAR_RUN_DIR/prompts"
      _radar_write_snapshot "$RADAR_RUN_DIR/prompts/$call_tag.txt" "$prompt"
    fi
  fi
  if [ -n "${TMUX_RADAR_AI_DETAIL:-${TMUX_SWITCHER_AI_DETAIL:-}}" ]; then
    [ -n "${errfile:-}" ] || errfile="$(_wbase "$pane").brain.err"
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
  BRAIN_LAST_ERR_FILE="${errfile:-}"
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
    and ((.pane_state? // null) == null or (.pane_state | IN("working","blocked","idle","done","unknown")))
    and ((.goal_status? // null) == null or (.goal_status | IN("working","blocked","done","unclear")))
    and ((.risk? // null) == null or (.risk | IN("low","medium","high","unknown")))
    and ((.evidence? // null) == null or (.evidence | type == "array" and all(.[]; type == "string")))
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
  if [ -n "$call_tag" ] && [ "$DECISION_MODEL_LAUNCHED" -eq 1 ]; then
    _persist_decision_call "$call_tag" "$json" "$backend" "$autonomy" "$policy"
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
  DECISION_READY=1

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

_watch_defer_native_events() {  # hooks-first=off: keep takeover/manual events, journal native triggers
  local batch="$1" retained="$RADAR_RUN_DIR/.hooks-retained.$$" event normalized kind event_id
  [ "${WATCH_HOOKS_FIRST:-on}" = off ] || return 0
  [ -s "$batch" ] || return 0
  # Let the normal coalescer see a takeover together with stale prompts so it
  # can record the stronger supersession relation instead of merely deferring.
  if jq -e 'select(.kind == "user_resumed")' "$batch" >/dev/null 2>&1; then
    return 0
  fi
  : > "$retained"
  while IFS= read -r event; do
    [ -n "$event" ] || continue
    normalized="$(_watch_normalize_event "$event")" || continue
    kind="$(printf '%s' "$normalized" | jq -r '.kind')"
    case "$kind" in
      approval|input_required|turn_complete)
        normalized="$(_watch_record_incoming "$normalized")" || continue
        event_id="$(printf '%s' "$normalized" | jq -r '.event_id')"
        radar_event_append hook_deferred watcher "hooks-first disabled; waiting for idle fallback" "$(jq -cn \
          --arg event_id "$event_id" --arg original_kind "$kind" \
          '{record:"hook_deferred",event_id:$event_id,original_kind:$original_kind,reason:"hooks_first_off"}')"
        ;;
      *) printf '%s\n' "$normalized" >> "$retained" ;;
    esac
  done < "$batch"
  mv "$retained" "$batch"
}

_watch_wait_for_batch() {
  local batch="$1" tick="${TMUX_RADAR_TEST_WAIT_TICK:-0.05}"
  : > "$batch"
  [ ! -e "$RADAR_RUN_DIR/paused" ] || return 3
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
    if [ -e "$RADAR_RUN_DIR/paused" ]; then
      _watch_kill_waiters
      return 3
    fi
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
  local retry="$1" current_kind="$2" base="${WATCH_RETRY_BACKOFF:-15}" schedule
  schedule="${TMUX_RADAR_TEST_RETRY_DELAYS:-$base,$((base * 2)),$((base * 4))}"
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

_watch_completion_hold() {
  local deadline="$1" tick="${TMUX_RADAR_TEST_WAIT_TICK:-0.1}" kept=0
  while [ -r "$WATCH_WF" ]; do
    if [ -e "$RADAR_RUN_DIR/keep-open" ]; then
      if [ "$kept" -eq 0 ]; then
        WATCH_STATUS="completed; kept open until q"
        WATCH_NEXT_KIND="manual_close"
        WATCH_NEXT_AT=0
        _watch_state_snapshot
        kept=1
      fi
    elif [ "$(now)" -ge "$deadline" ]; then
      return 0
    fi
    sleep "$tick"
  done
}

_watch_finalize() {
  local outcome="$1" phase="$2" reason="$3" delay deadline
  _delivery_cleanup
  _watch_kill_waiters
  _terminate_current_brain
  if [ "$outcome" = completed ]; then
    delay="${TMUX_RADAR_TEST_COMPLETION_DELAY:-${TMUX_RADAR_RUN_COMPLETION_CLOSE_DELAY:-12}}"
    case "$delay" in ''|*[!0-9]*) delay=12 ;; esac
    deadline=$(( $(now) + delay ))
    _watch_phase "$phase" "$reason" auto_close "$deadline"
    radar_run_finalize "$outcome" "$reason"
    WATCH_FINALIZED=1
    _watch_completion_hold "$deadline"
  else
    _watch_phase "$phase" "$reason" none 0
    radar_run_finalize "$outcome" "$reason"
    WATCH_FINALIZED=1
  fi
  rm -f "$WATCH_WF" "$BRAIN_PID_FILE" "$BRAIN_OUT_FILE" \
    "$RADAR_RUN_DIR/paused" "$RADAR_RUN_DIR/keep-open"
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
    [ -n "${RADAR_RUN_DIR:-}" ] && rm -f "$RADAR_RUN_DIR/paused" "$RADAR_RUN_DIR/keep-open"
  fi
  exit "$rc"
}

cmd_watch_loop() {
  local pane goal policy poll auto maxcalls config supplied_config="${6:-}" batch wait_rc coalesce_rc event_kind
  local rc valid failure evidence_fingerprint delivery_fingerprint armed_fingerprint current_fingerprint guard_rc
  local retry_rc retry_cancelled verify_rc classification error_class retryable summary detail stderr_path failure_kind repair_reason
  local requested_policy requested_poll requested_auto always_allow_source
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane" >&2; return 1; }
  if [ -n "$supplied_config" ]; then
    config="$supplied_config"
    _apply_watch_config "$config"
    pane="$(printf '%s' "$config" | jq -r '.pane')"
    goal="$TMUX_RADAR_RUN_GOAL"
    policy="$TMUX_RADAR_RUN_APPROVAL_POLICY"
    [ "$TMUX_RADAR_RUN_ALWAYS_ALLOW" = on ] && policy=always-allow
    poll="$TMUX_RADAR_RUN_POLL"
    auto="$TMUX_RADAR_RUN_AUTONOMY"
    maxcalls="$TMUX_RADAR_RUN_MAX_DECISIONS"
    WATCH_RETRY_LIMIT="$TMUX_RADAR_RUN_RETRY_LIMIT"
    WATCH_RETRY_BACKOFF="$TMUX_RADAR_RUN_RETRY_BACKOFF"
    WATCH_HOOKS_FIRST="$TMUX_RADAR_RUN_HOOKS_FIRST"
    WATCH_STABLE_THRESHOLD="$TMUX_RADAR_RUN_STABLE_SCREEN_THRESHOLD"
  else
    goal="${2:-}"
    requested_policy="${3:-}"
    requested_poll="${4:-}"
    requested_auto="${5:-}"
    config="$(cmd_build_watch_config "$pane" "$goal")"
    CONFIG_JSON="$config"
    if [ -n "$requested_policy" ]; then
      _config_set approval_policy "$requested_policy" custom 0 || true
      if [ "$requested_policy" = always-allow ]; then
        _config_set always_allow on custom 0 || true
      else
        _config_set always_allow off custom 0 || true
      fi
    elif [ "$(printf '%s' "$CONFIG_JSON" | jq -r '.values.always_allow.value')" = on ]; then
      always_allow_source="$(printf '%s' "$CONFIG_JSON" | jq -r '.values.always_allow.source')"
      _config_set approval_policy always-allow "$always_allow_source" 0 || true
    fi
    [ -z "$requested_poll" ] || _config_set poll "$requested_poll" custom 0 || true
    [ -z "$requested_auto" ] || _config_set autonomy "$requested_auto" custom 0 || true
    CONFIG_JSON="$(printf '%s' "$CONFIG_JSON" | jq -c '.goal=.values.goal.value')"
    config="$CONFIG_JSON"
    _apply_watch_config "$config"
    goal="$TMUX_RADAR_RUN_GOAL"
    policy="$TMUX_RADAR_RUN_APPROVAL_POLICY"
    [ "$TMUX_RADAR_RUN_ALWAYS_ALLOW" = on ] && policy=always-allow
    poll="$TMUX_RADAR_RUN_POLL"
    auto="$TMUX_RADAR_RUN_AUTONOMY"
    maxcalls="$TMUX_RADAR_RUN_MAX_DECISIONS"
    WATCH_RETRY_LIMIT="$TMUX_RADAR_RUN_RETRY_LIMIT"
    WATCH_RETRY_BACKOFF="$TMUX_RADAR_RUN_RETRY_BACKOFF"
    WATCH_HOOKS_FIRST="$TMUX_RADAR_RUN_HOOKS_FIRST"
    WATCH_STABLE_THRESHOLD="$TMUX_RADAR_RUN_STABLE_SCREEN_THRESHOLD"
  fi

  _freeze_backend 0
  config="$(printf '%s' "$config" | jq -c --argjson backend "$BRAIN_BACKEND_JSON" \
    '. + {backend:$backend}')"

  WATCH_PANE="$pane"; WATCH_WF="$(_wf "$pane")"; WATCH_STARTED="$(now)"
  WATCH_POLL="$poll"; WATCH_GOAL="$goal"; WATCH_POLICY="$policy"
  WATCH_AUTONOMY="$auto"; WATCH_MAX_CALLS="$maxcalls"; WATCH_CALLS=0
  WATCH_RETRY=0; WATCH_TRANSIENT_RETRIES=0; WATCH_REPAIR_ATTEMPTS=0
  WATCH_EVENT_ID=""; WATCH_LAST_DECISION=""; WATCH_FINALIZED=0
  WATCH_STABLE_COUNT=0
  radar_run_create "$pane" "$config"
  WATCH_WF="$(radar_watch_file "$pane")"
  if [ "$BRAIN_BACKEND_OK" -ne 1 ]; then
    classification="$(jq -cn --arg summary "$(printf '%s' "$BRAIN_PREFLIGHT_JSON" | jq -r '.summary')" \
      --arg detail "$(printf '%s' "$BRAIN_PREFLIGHT_JSON" | jq -r '.detail // ""')" \
      '{class:"config-permanent",code:"backend-preflight",retryable:false,summary:$summary,detail:$detail}')"
    _watch_phase CREATED "run created" none 0
    _watch_record_backend_error "$classification" "" 0
    _watch_phase PAUSED_ERROR "$(printf '%s' "$classification" | jq -r '.summary')" none 0
    radar_run_finalize paused_error "$(printf '%s' "$classification" | jq -r '.summary')"
    WATCH_FINALIZED=1
    rm -f "$WATCH_WF"
    return 3
  fi
  if [ -n "${TMUX_RADAR_TEST_RUNTIME_FILE:-}" ] && [ -n "$supplied_config" ]; then
    _watch_runtime_json > "$TMUX_RADAR_TEST_RUNTIME_FILE"
  fi
  if [ -n "${TMUX_RADAR_RUN_RETENTION_DAYS:-}" ]; then
    radar_cleanup_runs "$TMUX_RADAR_RUN_RETENTION_DAYS"
  fi
  if [ -n "${TMUX_RADAR_TEST_EXIT_AFTER_CONFIG:-}" ]; then
    return 0
  fi
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
      3)
        _watch_phase PAUSED_USER "paused by user" resume 0
        while [ -e "$RADAR_RUN_DIR/paused" ]; do
          tmux display-message -p -t "$WATCH_PANE" '#{pane_id}' >/dev/null 2>&1 || {
            _watch_finalize stopped STOPPED "target pane disappeared while paused"
            break 2
          }
          sleep "${TMUX_RADAR_TEST_WAIT_TICK:-0.1}"
        done
        radar_event_append resumed monitor "supervision resumed" '{"record":"control"}'
        WATCH_STABLE_COUNT=0
        continue
        ;;
      0) WATCH_STABLE_COUNT=0 ;;
      1)
        current_fingerprint="$(_watch_fingerprint || true)"
        if [ -z "$current_fingerprint" ]; then
          _watch_finalize stopped STOPPED "target pane disappeared at idle deadline"
          break
        fi
        if [ "$current_fingerprint" != "$armed_fingerprint" ]; then
          WATCH_STABLE_COUNT=0
          radar_event_append idle_reset watcher "screen changed during idle interval" "$(jq -cn \
            --arg before "$armed_fingerprint" --arg after "$current_fingerprint" \
            '{record:"idle_reset",before:$before,after:$after}')"
          continue
        fi
        WATCH_STABLE_COUNT=$((WATCH_STABLE_COUNT + 1))
        if [ "$WATCH_STABLE_COUNT" -lt "$WATCH_STABLE_THRESHOLD" ]; then
          radar_event_append idle_stable watcher "stable sample $WATCH_STABLE_COUNT/$WATCH_STABLE_THRESHOLD" "$(jq -cn \
            --argjson count "$WATCH_STABLE_COUNT" --argjson threshold "$WATCH_STABLE_THRESHOLD" \
            '{record:"idle_stable",count:$count,threshold:$threshold}')"
          continue
        fi
        WATCH_STABLE_COUNT=0
        WATCH_IDLE_SEQ=$(( ${WATCH_IDLE_SEQ:-0} + 1 ))
        WATCH_EVENT_ID="idle-$RADAR_RUN_ID-$WATCH_IDLE_SEQ"
        jq -cn --arg id "$WATCH_EVENT_ID" --arg pane "$pane" --arg timestamp "$(_radar_now_iso)" \
          --argjson event_order "$(_watch_next_event_order)" \
          '{kind:"screen_idle",source:"watcher",label:"idle fallback",event_id:$id,pane:$pane,timestamp:$timestamp,event_order:$event_order}' > "$batch"
        ;;
    esac
    _watch_defer_native_events "$batch"
    if [ ! -s "$batch" ]; then
      WATCH_EVENT_ID=""
      _watch_phase ARMED "native events deferred; waiting for idle fallback" idle 0
      continue
    fi
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

    WATCH_RETRY=0; WATCH_TRANSIENT_RETRIES=0; WATCH_REPAIR_ATTEMPTS=0; retry_cancelled=0; repair_reason=""
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
      DECISION_READY=0; DECISION_SCHEMA_VALID=0; DECISION_SCHEMA_ERROR='decision was not produced'
      DECISION_FAILURE_KIND=""; DECISION_FAILURE_DETAIL=""; DECISION_MODEL_LAUNCHED=0
      BRAIN_LAST_RC=0; BRAIN_STOP_REASON=""; BRAIN_LAST_ERR_FILE=""
      if [ -n "${TMUX_RADAR_TEST_BEFORE_DECIDE_BLOCK:-}" ]; then
        : > "${TMUX_RADAR_TEST_BEFORE_DECIDE_BLOCK}.ready"
        while [ -e "$TMUX_RADAR_TEST_BEFORE_DECIDE_BLOCK" ]; do sleep 0.01; done
      fi
      set +e
      TMUX_RADAR_REPAIR_ATTEMPT="$WATCH_REPAIR_ATTEMPTS" \
        TMUX_RADAR_REPAIR_REASON="${repair_reason:-}" \
        TMUX_RADAR_AI_DETAIL=1 TMUX_RADAR_DECIDE_PARSE_ONLY=1 \
        cmd_decide "$pane" "$auto" "$policy" "$goal"
      rc=$?
      set -e
      if [ "$DECISION_MODEL_LAUNCHED" -ne 1 ]; then
        WATCH_CALLS=$((WATCH_CALLS - 1))
      fi
      WATCH_LAST_DECISION="$(now)"
      valid=1; failure=""; failure_kind=""
      if [ "$DECISION_READY" -ne 1 ]; then
        valid=0
        failure="${DECISION_FAILURE_DETAIL:-decision was not produced (cmd rc=$rc)}"
        failure_kind="${DECISION_FAILURE_KIND:-decision-invalid}"
      elif [ "$BRAIN_LAST_RC" -ne 0 ]; then
        valid=0; failure="backend rc=$BRAIN_LAST_RC${BRAIN_STOP_REASON:+ ($BRAIN_STOP_REASON)}"; failure_kind='backend'
      elif [ "$DECISION_SCHEMA_VALID" -ne 1 ]; then
        valid=0; failure="${DECISION_SCHEMA_ERROR:-decision schema/type validation failed}"; failure_kind='output-invalid'
      else
        if [ "$valid" -eq 1 ] && [ "$DECISION_ACTION" = "done" ]; then
          case "$event_kind" in turn_complete|screen_idle|idle|manual_reassess) : ;;
            *) valid=0; failure="done is invalid for event kind: $event_kind"; failure_kind='decision-invalid' ;;
          esac
        fi
      fi
      [ "$valid" -eq 1 ] && break

      if [ "$failure_kind" = lifecycle-stop ]; then
        _watch_finalize stopped STOPPED "$failure"
        break 2
      fi

      case "$failure_kind" in
        decision-invalid) classification="$(_classify_outcome decision-invalid "$failure")" ;;
        config-permanent)
          classification="$(jq -cn --arg summary "$failure" \
            '{class:"config-permanent",code:"backend-preflight",retryable:false,summary:$summary,detail:"backend rejected before model launch"}')"
          ;;
        capture-error)
          classification="$(jq -cn --arg summary "$failure" \
            '{class:"transient",code:"pane-capture-failed",retryable:true,summary:$summary,detail:"target remained live but capture produced no content"}')"
          ;;
        *) classification="$(_classify_outcome backend "$BRAIN_LAST_RC" "${BRAIN_LAST_ERR_FILE:-}" "$DECISION_SCHEMA_VALID" "$BRAIN_STOP_REASON")" ;;
      esac
      error_class="$(printf '%s' "$classification" | jq -r '.class')"
      retryable="$(printf '%s' "$classification" | jq -r '.retryable')"
      if { [ "$error_class" = output-invalid ] || [ "$error_class" = decision-invalid ]; } && [ -n "$failure" ]; then
        classification="$(printf '%s' "$classification" | jq -c --arg summary "$failure" '.summary=$summary')"
      fi
      summary="$(printf '%s' "$classification" | jq -r '.summary')"
      detail="$(printf '%s' "$classification" | jq -r '.detail')"
      stderr_path="${BRAIN_LAST_ERR_FILE:-}"
      if [ "$error_class" = decision-invalid ]; then
        radar_event_append decision_invalid watcher "$summary" "$(jq -cn \
          --arg event_id "$WATCH_EVENT_ID" --arg detail "$detail" --argjson call "$WATCH_CALLS" \
          '{record:"decision_error",event_id:$event_id,error_class:"decision-invalid",
            retryable:true,detail:$detail,call:$call}')"
      else
        _watch_record_backend_error "$classification" "$stderr_path" "$WATCH_CALLS"
      fi

      if [ "$retryable" != true ]; then
        _watch_phase PAUSED_ERROR "$summary" none 0
        _escalate "$pane" "AI 监控配置错误，已暂停: $summary"
        radar_run_finalize paused_error "$summary"
        WATCH_FINALIZED=1; rm -f "$WATCH_WF"
        break 2
      fi

      if [ "$error_class" = output-invalid ] || [ "$error_class" = decision-invalid ]; then
        if [ "$WATCH_REPAIR_ATTEMPTS" -ge 1 ]; then
          _watch_phase PAUSED_ERROR "$summary; repair attempt failed" none 0
          _escalate "$pane" "AI 监控输出修复失败，已暂停: $summary"
          radar_run_finalize paused_error "$summary"
          WATCH_FINALIZED=1; rm -f "$WATCH_WF"
          break 2
        fi
        WATCH_REPAIR_ATTEMPTS=1
        repair_reason="$failure"
        WATCH_RETRY="$WATCH_REPAIR_ATTEMPTS"
        radar_event_append decision_repair watcher "$summary" "$(jq -cn \
          --arg event_id "$WATCH_EVENT_ID" --arg detail "$detail" \
          --arg error_class "$error_class" \
          '{record:"repair",event_id:$event_id,error_class:$error_class,repair_attempt:1,detail:$detail}')"
        _watch_phase DECIDING "$summary; repair attempt 1 scheduled" repair 0
        continue
      fi

      if [ "$WATCH_TRANSIENT_RETRIES" -ge "$WATCH_RETRY_LIMIT" ]; then
        _watch_phase PAUSED_ERROR "$summary; retry exhausted" none 0
        _escalate "$pane" "AI 监控连续决策失败，已暂停: $summary"
        radar_run_finalize paused_error "$summary"
        WATCH_FINALIZED=1; rm -f "$WATCH_WF"
        break 2
      fi
      WATCH_TRANSIENT_RETRIES=$((WATCH_TRANSIENT_RETRIES + 1))
      WATCH_RETRY="$WATCH_TRANSIENT_RETRIES"
      _watch_phase DECIDING "$summary; retry $WATCH_RETRY scheduled" retry 0
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
        classification="$(_classify_outcome policy-halt "${DECISION_REASON:-model requested human judgment}")"
        radar_event_append policy_halt policy "${DECISION_REASON:-model requested human judgment}" "$(jq -cn \
          --arg event_id "$WATCH_EVENT_ID" --argjson classification "$classification" \
          '{record:"policy_halt",event_id:$event_id,sent:false,outcome_class:$classification.class,
            retryable:$classification.retryable}')"
        _watch_phase PAUSED_POLICY "model escalated: ${DECISION_REASON:-unspecified}" none 0
        _escalate "$pane" "AI 拿不准: ${DECISION_REASON:-需要人工处理}"
        radar_run_finalize policy_halt "${DECISION_REASON:-model escalated}"
        WATCH_FINALIZED=1; rm -f "$WATCH_WF"
        break
        ;;
      send)
        if [ "$DECISION_SAFE" != 1 ] || [ "$auto" = suggest ] || [ "$auto" = confirm ]; then
          classification="$(_classify_outcome policy-halt "${DECISION_REASON:-unsafe or non-auto action}")"
          radar_event_append policy_halt policy "${DECISION_REASON:-unsafe or non-auto action}" "$(jq -cn \
            --arg event_id "$WATCH_EVENT_ID" --argjson classification "$classification" \
            '{record:"policy_halt",event_id:$event_id,sent:false,outcome_class:$classification.class,
              retryable:$classification.retryable}')"
          _watch_phase PAUSED_POLICY "policy requires user: ${DECISION_REASON:-unsafe or non-auto action}" none 0
          _escalate "$pane" "AI 需要你确认: ${DECISION_REASON:-操作未自动执行}"
          radar_run_finalize policy_halt "policy gate"
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

_monitor_command() {  # _monitor_command <mode> <pane>
  printf "TMUX_RADAR_STATE_DIR='%s' exec bash '%s' %s '%s'" \
    "${STATE_DIR//\'/\'\\\'\'}" "${AI_MONITOR//\'/\'\\\'\'}" "$1" "${2//\'/\'\\\'\'}"
}

_popup_inner_geometry() {  # _popup_inner_geometry <width-percent> <height-percent>
  local width_percent="$1" height_percent="$2" client_cols client_rows inner_cols inner_rows
  client_cols="$(tmux display-message -p '#{client_width}' 2>/dev/null || true)"
  client_rows="$(tmux display-message -p '#{client_height}' 2>/dev/null || true)"
  case "$client_cols" in ''|*[!0-9]*) client_cols="$(tput cols 2>/dev/null || printf 120)" ;; esac
  case "$client_rows" in ''|*[!0-9]*) client_rows="$(tput lines 2>/dev/null || printf 40)" ;; esac
  case "$client_cols" in ''|*[!0-9]*) client_cols=120 ;; esac
  case "$client_rows" in ''|*[!0-9]*) client_rows=40 ;; esac
  inner_cols=$((client_cols * width_percent / 100 - 2))
  inner_rows=$((client_rows * height_percent / 100 - 2))
  [ "$inner_cols" -ge 40 ] || inner_cols=40
  [ "$inner_rows" -ge 12 ] || inner_rows=12
  printf '%s\t%s\n' "$inner_cols" "$inner_rows"
}

_launch_monitor() {  # _launch_monitor <target-pane> <watch-file>
  local pane="$1" wf="$2" cols rows requested width max_width ratio pos
  local detail_pane overview_pane compact_pane detail_cmd overview_cmd compact_cmd err
  local popup_geometry popup_cols popup_rows
  [ -x "$AI_MONITOR" ] || { echo "monitor executable missing: $AI_MONITOR" >&2; return 1; }
  [ "$(opt @radar-ai-monitor on)" = on ] || { echo 'visible monitor is required for supervision' >&2; return 1; }
  cols="$(tmux display-message -p -t "$pane" '#{pane_width}' 2>/dev/null || true)"
  rows="$(tmux display-message -p -t "$pane" '#{pane_height}' 2>/dev/null || true)"
  case "$cols" in ''|*[!0-9]*) cols=120 ;; esac
  case "$rows" in ''|*[!0-9]*) rows=30 ;; esac
  requested="${TMUX_RADAR_RUN_MONITOR_WIDTH:-$(opt @radar-ai-monitor-size-h 84)}"
  case "$requested" in ''|*[!0-9]*) requested=84 ;; esac
  ratio="${TMUX_RADAR_RUN_OVERVIEW_RATIO:-25}"; case "$ratio" in ''|*[!0-9]*) ratio=25 ;; esac
  [ "$ratio" -ge 15 ] && [ "$ratio" -le 50 ] || ratio=25
  pos="${TMUX_RADAR_RUN_MONITOR_POSITION:-$(opt @radar-ai-monitor-pos right)}"
  detail_cmd="$(_monitor_command detail "$pane")"
  overview_cmd="$(_monitor_command overview "$pane")"
  compact_cmd="$(_monitor_command compact "$pane")"

  # Explicit legacy top/bottom settings remain available for migration, but
  # use the new single-process compact console instead of the old repaint loop.
  case "$pos" in
    top|bottom)
      if [ "$pos" = top ]; then
        compact_pane="$(tmux split-window -v -b -l "$(opt @radar-ai-monitor-size 12)" -P -F '#{pane_id}' -d -t "$pane" "$compact_cmd" 2>&1)" || {
          err="$compact_pane"; echo "monitor split failed: $err" >&2; return 1; }
      else
        compact_pane="$(tmux split-window -v -l "$(opt @radar-ai-monitor-size 12)" -P -F '#{pane_id}' -d -t "$pane" "$compact_cmd" 2>&1)" || {
          err="$compact_pane"; echo "monitor split failed: $err" >&2; return 1; }
      fi
      _watch_pointer_set_monitors "$wf" "" "$compact_pane"
      tmux select-pane -t "$pane" >/dev/null 2>&1 || true
      return 0
      ;;
  esac

  if [ "$cols" -lt 120 ] || [ "$rows" -lt 24 ]; then
    popup_geometry="$(_popup_inner_geometry 90 85)"
    popup_cols="${popup_geometry%%$'\t'*}"
    popup_rows="${popup_geometry#*$'\t'}"
    if [ "${TMUX_RADAR_REUSE_POPUP:-0}" = 1 ]; then
      _watch_pointer_set_monitors "$wf" popup popup
      if [ "${TMUX_RADAR_TEST_MONITOR_ONCE:-0}" = 1 ]; then
        TMUX_RADAR_MONITOR_COLS="$popup_cols" TMUX_RADAR_MONITOR_ROWS="$popup_rows" \
          TMUX_RADAR_STATE_DIR="$STATE_DIR" exec bash "$AI_MONITOR" compact "$pane" --once
      fi
      TMUX_RADAR_MONITOR_COLS="$popup_cols" TMUX_RADAR_MONITOR_ROWS="$popup_rows" \
        TMUX_RADAR_STATE_DIR="$STATE_DIR" exec bash "$AI_MONITOR" compact "$pane"
    fi
    compact_cmd="TMUX_RADAR_MONITOR_COLS=$popup_cols TMUX_RADAR_MONITOR_ROWS=$popup_rows $compact_cmd"
    tmux display-popup -E -w 90% -h 85% "$compact_cmd" >/dev/null 2>&1 || return 1
    _watch_pointer_set_monitors "$wf" popup popup
    tmux select-pane -t "$pane" >/dev/null 2>&1 || true
    return 0
  fi

  if [ "$cols" -ge 180 ]; then
    width="$requested"; [ "$width" -lt 72 ] && width=72; [ "$width" -gt 112 ] && width=112
    max_width=$((cols - 68)); [ "$width" -gt "$max_width" ] && width="$max_width"
    detail_pane="$(tmux split-window -h -l "$width" -P -F '#{pane_id}' -d -t "$pane" "$detail_cmd" 2>&1)" || {
      err="$detail_pane"; echo "monitor detail split failed: $err" >&2; return 1; }
    overview_pane="$(tmux split-window -v -b -p "$ratio" -P -F '#{pane_id}' -d -t "$detail_pane" "$overview_cmd" 2>&1)" || {
      err="$overview_pane"; tmux kill-pane -t "$detail_pane" >/dev/null 2>&1 || true
      echo "monitor overview split failed: $err" >&2; return 1; }
    _watch_pointer_set_monitors "$wf" "$overview_pane" "$detail_pane"
  else
    width=$((cols * 38 / 100)); [ "$width" -lt 52 ] && width=52; [ "$width" -gt 72 ] && width=72
    compact_pane="$(tmux split-window -h -l "$width" -P -F '#{pane_id}' -d -t "$pane" "$compact_cmd" 2>&1)" || {
      err="$compact_pane"; echo "monitor compact split failed: $err" >&2; return 1; }
    _watch_pointer_set_monitors "$wf" "" "$compact_pane"
  fi
  tmux select-pane -t "$pane" >/dev/null 2>&1 || true
}

cmd_watch() {  # detach the loop so the caller (popup/menu) can return
  local pane goal policy poll auto config_json="${6:-}" wf base feed watch_pid existing_detail existing_overview
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane"; return 1; }
  goal="${2:-}"; policy="${3:-}"; poll="${4:-}"; auto="${5:-}"
  if [ -n "$config_json" ]; then
    _apply_watch_config "$config_json"
    goal="$TMUX_RADAR_RUN_GOAL"
    policy="$TMUX_RADAR_RUN_APPROVAL_POLICY"
    [ "$TMUX_RADAR_RUN_ALWAYS_ALLOW" = on ] && policy=always-allow
    poll="$TMUX_RADAR_RUN_POLL"
    auto="$TMUX_RADAR_RUN_AUTONOMY"
  fi
  wf="$(_wf "$pane")"; base="${wf%.watch}"; feed="$base.out"
  if [ -f "$wf" ] && kill -0 "$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)" 2>/dev/null; then
    existing_detail="$(_state_get "$wf" monitor_detail_pane)"
    existing_overview="$(_state_get "$wf" monitor_overview_pane)"
    case "$existing_detail" in %*) tmux select-pane -t "$existing_detail" >/dev/null 2>&1 || true ;;
      *) case "$existing_overview" in %*) tmux select-pane -t "$existing_overview" >/dev/null 2>&1 || true ;; esac ;;
    esac
    echo "already watching $pane (run $(_state_get "$wf" run_id))"; return 0
  fi
  : > "$feed"                                  # create the feed before the monitor tails it
  : > "$base.timeline"
  : > "$base.detail"
  : > "$base.detail.log"
  nohup bash "$SELF" _watch_loop "$pane" "$goal" "$policy" "$poll" "$auto" "$config_json" >"$feed" 2>&1 &
  watch_pid=$!
  disown 2>/dev/null || true
  # The structured watcher owns creation of the compatibility pointer. Wait a
  # bounded moment so monitor pane IDs can be merged without racing startup.
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$wf" ] && break
    kill -0 "$watch_pid" 2>/dev/null || break
    sleep 0.01
  done
  if ! have_tmux || ! _launch_monitor "$pane" "$wf"; then
    printf '%s⚠ 无法创建可见监控控制台，已停止 watch%s\n' "$CY" "$CR"
    audit "monitor-fail\t$pane\tresponsive-launch"
    _abort_watch_launch "$pane" "$watch_pid"
    return 1
  fi
  printf '%s✓ 已开始监控%s %s%s%s\n' "$CG" "$CR" "$(_pane_label "$pane")" \
    "${goal:+  ${CD}· ${goal}${CR}}" "${policy:+  ${CY}[$policy]${CR}}"
}

# Interactive setup for quick and advanced launch. Every editable value lives
# in CONFIG_JSON, so the launch summary and the watcher consume one truth.
_advanced_edit_config() {
  local key value
  while :; do
    printf '\n'
    cmd_render_watch_config "$CONFIG_JSON"
    printf '\n%sEdit field (Enter = done)%s\n> ' "$CD" "$CR"
    readline_tty key
    [ -n "$key" ] || break
    if ! printf '%s' "$CONFIG_JSON" | jq -e --arg key "$key" '.values | has($key)' >/dev/null; then
      printf 'rejected %s; allowed: a field listed above\n' "$key" >&2
      continue
    fi
    printf 'value for %s> ' "$key"
    readline_tty value
    _config_set "$key" "$value" custom 1 || true
    CONFIG_JSON="$(printf '%s' "$CONFIG_JSON" | jq -c '.goal=.values.goal.value')"
  done
}

cmd_watch_setup() {
  local pane mode="${2:-quick}" preset="${3:-}" raw decoded goal ans config decode_marker='__RADAR_DECODE_END_71C4__'
  pane="$(_resolve_pane "${1:-}")" || { echo "watch-setup: no target pane"; return 1; }
  case "$mode" in quick|advanced) ;; *) echo "watch-setup: mode must be quick or advanced" >&2; return 2 ;; esac
  _hdr "AI 常驻监控 · 目标" "$(_pane_label "$pane")"
  printf '%s目标（回车 = 推进当前任务直到完成；Tab = 高级设置）%s\n> ' "$CD" "$CR"
  bind '"\t":"__RADAR_ADVANCED__\C-m"' 2>/dev/null || true
  readline_tty raw
  decoded="$(cmd_decode_goal "$raw"; printf '%s' "$decode_marker")"
  decoded="${decoded%"$decode_marker"}"
  goal="${decoded#*$'\t'}"
  [ "${decoded%%$'\t'*}" = advanced ] && mode=advanced
  config="$(cmd_build_watch_config "$pane" "$goal")"
  CONFIG_JSON="$config"
  if [ "$preset" = always-allow ]; then
    _config_set always_allow on custom 1
    _config_set approval_policy always-allow custom 1
  fi
  [ "$mode" = advanced ] && _advanced_edit_config
  while :; do
    printf '\n'
    _hdr "AI 常驻监控 · 启动摘要" "$(_pane_label "$pane")"
    cmd_render_watch_config "$CONFIG_JSON"
    printf '\n%sEnter = start · a = advanced · Esc = cancel%s\n> ' "$CD" "$CR"
    readline_tty ans
    case "$ans" in
      '') break ;;
      a|A) _advanced_edit_config ;;
      $'\e'|q|Q) echo '已取消'; return 0 ;;
      *) printf 'Enter, a, or Esc only.\n' >&2 ;;
    esac
  done
  TMUX_RADAR_REUSE_POPUP=1 cmd_watch "$pane" '' '' '' '' "$CONFIG_JSON"
  sleep "${TMUX_RADAR_SETUP_LAUNCH_PAUSE:-1.2}"
}

cmd_pause() {
  local pane run_dir
  pane="$(_resolve_pane "${1:-}" 2>/dev/null || echo "${1:-}")"
  radar_run_open "$pane" >/dev/null 2>&1 || { echo "no watcher for $pane" >&2; return 1; }
  run_dir="$RADAR_RUN_DIR"
  : > "$run_dir/paused"
  chmod 600 "$run_dir/paused" 2>/dev/null || true
  radar_event_append paused monitor "paused by user" '{"record":"control"}'
  [ -n "$RADAR_RUN_CHANNEL" ] && tmux wait-for -S "$RADAR_RUN_CHANNEL" >/dev/null 2>&1 || true
}

cmd_resume() {
  local pane run_dir
  pane="$(_resolve_pane "${1:-}" 2>/dev/null || echo "${1:-}")"
  radar_run_open "$pane" >/dev/null 2>&1 || { echo "no watcher for $pane" >&2; return 1; }
  run_dir="$RADAR_RUN_DIR"
  rm -f "$run_dir/paused"
  radar_event_append resume_requested monitor "resume requested" '{"record":"control"}'
  [ -n "$RADAR_RUN_CHANNEL" ] && tmux wait-for -S "$RADAR_RUN_CHANNEL" >/dev/null 2>&1 || true
}

cmd_keep() {
  local pane phase
  pane="$(_resolve_pane "${1:-}" 2>/dev/null || echo "${1:-}")"
  radar_run_open "$pane" >/dev/null 2>&1 || { echo "no watcher for $pane" >&2; return 1; }
  phase="$(jq -r '.phase // ""' "$RADAR_RUN_DIR/state.json" 2>/dev/null || true)"
  [ "$phase" = COMPLETED ] || { echo "watcher for $pane is not completed" >&2; return 1; }
  : > "$RADAR_RUN_DIR/keep-open"
  chmod 600 "$RADAR_RUN_DIR/keep-open" 2>/dev/null || true
  [ -n "$RADAR_RUN_CHANNEL" ] && tmux wait-for -S "$RADAR_RUN_CHANNEL" >/dev/null 2>&1 || true
  printf 'kept completion console open for %s\n' "$pane"
}

cmd_report() {
  local requested="${1:-latest}" run_dir final
  need_jq
  case "$requested" in
    ''|latest)
      run_dir="$(find "$RADAR_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n 1)"
      ;;
    */*) echo "report: invalid run id" >&2; return 2 ;;
    *) run_dir="$RADAR_RUNS_DIR/$requested" ;;
  esac
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || { echo "report: run not found: $requested" >&2; return 1; }
  final="$run_dir/final.json"
  [ -r "$final" ] || { echo "report: run has not finished: $(basename "$run_dir")" >&2; return 1; }
  jq -r '
    "tmux-radar supervision report",
    "Run:       \(.run_id)",
    "Target:    \(.pane)",
    "Outcome:   \(.outcome)",
    "Goal:      \(.goal // "")",
    (if (.goal_status // "") == "" then empty else "Goal state: \(.goal_status)" end),
    "Reason:    \(.reason)",
    "Duration:  \(.duration_seconds // 0)s",
    "Counts:    events=\(.event_count // 0) decisions=\(.decision_count // 0) actions=\(.action_count // 0) errors=\(.error_count // 0)",
    "Logs:      \(.log_path)"
  ' "$final"
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
  if [ -n "${TMUX_RADAR_TEST_MONITOR_READY:-}" ]; then
    printf 'ready\n' > "$TMUX_RADAR_TEST_MONITOR_READY"
  fi
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
  local pop monitor_pop
  pop="display-popup -E -w 80% -h 70%"
  monitor_pop="display-popup -E -w 90% -h 85%"
  tmux display-menu -T "#[align=centre] tmux AI 主管 " -x C -y C \
    "指挥 tmux（自然语言）"             a "$pop \"TMUX_RADAR_AI_PAUSE=1 $SELF ask\"" \
    "让当前 pane 继续 / 决定一次"        c "$pop \"TMUX_RADAR_AI_PAUSE=1 $SELF decide '#{pane_id}'\"" \
    "" \
    "常驻监控当前 pane 直到完成"         w "$monitor_pop \"$SELF watch-setup '#{pane_id}' quick\"" \
    "常驻监控 + always-allow（更省心）"  W "$monitor_pop \"$SELF watch-setup '#{pane_id}' quick always-allow\"" \
    "自定义监控（目标 / 间隔 / 策略）…"   v "$monitor_pop \"$SELF watch-setup '#{pane_id}' advanced\"" \
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
  _decode-goal) shift; cmd_decode_goal "${1-}" || rc=$? ;;
  _build-watch-config) shift; cmd_build_watch_config "${1:-}" "${2-}" || rc=$? ;;
  _render-watch-config) shift; cmd_render_watch_config "${1:-}" || rc=$? ;;
  _classify-backend-failure) shift; _classify_backend_failure "${1:-0}" "${2:-/dev/null}" "${3:-0}" "${4:-}" || rc=$? ;;
  doctor-json)   shift; cmd_doctor_json "$@" || rc=$? ;;
  ask)          shift; cmd_ask "$@" || rc=$? ;;
  decide)       shift; cmd_decide "${1:-}" "${2:-}" "${3:-}" "${4:-}" || rc=$? ;;
  watch)        shift; cmd_watch "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" || rc=$? ;;
  emit-event)   shift; cmd_emit_event "$@" || rc=$? ;;
  watch-setup)  shift; cmd_watch_setup "${1:-}" "${2:-quick}" "${3:-}" || rc=$? ;;
  _watch_loop)  shift; cmd_watch_loop "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" || rc=$? ;;
  _launch-monitor) shift; _launch_monitor "${1:-}" "${2:-$(_wf "${1:-}")}" || rc=$? ;;
  pause)        shift; cmd_pause "${1:-}" || rc=$? ;;
  resume)       shift; cmd_resume "${1:-}" || rc=$? ;;
  keep)         shift; cmd_keep "${1:-}" || rc=$? ;;
  report)       shift; cmd_report "${1:-latest}" || rc=$? ;;
  monitor)      shift; cmd_monitor "${1:-}" || rc=$? ;;
  monitor-timeline) shift; cmd_monitor_timeline "${1:-}" || rc=$? ;;
  monitor-detail) shift; cmd_monitor_detail "${1:-}" || rc=$? ;;
  stop)         shift; cmd_stop "${1:-all}" || rc=$? ;;
  status)       cmd_status || rc=$? ;;
  list)         cmd_list || rc=$? ;;
  cleanup)      cmd_cleanup || rc=$? ;;
  menu)         cmd_menu || rc=$? ;;
  *) echo "usage: ai.sh {doctor-json|ask [req]|decide [pane] [autonomy] [policy]|watch <pane> [goal] [policy] [poll] [autonomy]|emit-event <pane> <kind> <source> <label>|watch-setup [pane]|pause <pane>|resume <pane>|keep <pane>|report [run-id|latest]|monitor <pane>|monitor-timeline <pane>|monitor-detail <pane>|stop <pane|all>|status|list|cleanup|menu}" >&2; exit 2 ;;
esac
# menu-launched popups set this so the result stays on screen until a keypress
if [ -n "${TMUX_RADAR_AI_PAUSE:-${TMUX_SWITCHER_AI_PAUSE:-}}" ] && [ -t 0 ]; then
  printf '\n%s按任意键关闭…%s' "$CD" "$CR"; read -n1 -r _ </dev/tty 2>/dev/null || true
fi
exit "$rc"

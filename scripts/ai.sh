#!/usr/bin/env bash
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
NOTIFY="$SCRIPT_DIR/needinput-notify.sh"

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
    (printf '%s' "$prompt" | eval "$custom" > "$out" 2>"$err") &
  elif [ -n "$(opt @radar-ai-profile '')" ]; then
    # a codex profile bundles model/effort/etc in ~/.codex/config.toml; the
    # safety flags (read-only, ephemeral) stay ours and are not overridable
    profile="$(opt @radar-ai-profile '')"
    codex exec -p "$profile" \
      -s read-only --ephemeral --skip-git-repo-check \
      --output-schema "$schema" -o "$out" -- "$prompt" >/dev/null 2>"$err" &
  else
    codex exec \
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
  if [ -n "${BRAIN_PID_FILE:-}" ]; then
    {
      printf 'pid=%s\npgid=%s\nwatch_pid=%s\npane=%s\nstarted=%s\noutput=%s\n' \
        "$pid" "$BRAIN_PGID" "$$" "${BRAIN_BOUND_PANE:-}" "$started" "$out"
    } > "$BRAIN_PID_FILE"
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
  [ -n "$text" ] && tmux send-keys -t "$pane" -l -- "$text" 2>/dev/null || true
  local k; for k in "$@"; do [ -n "$k" ] && tmux send-keys -t "$pane" "$k" 2>/dev/null || true; done
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
  action="$(printf '%s' "$json" | jq -r '.action // "unknown"' 2>/dev/null || echo unknown)"
  text="$(printf '%s' "$json" | jq -r '.text // ""' 2>/dev/null || echo '')"
  safe="$(printf '%s' "$json" | jq -r 'if .safe == false then "0" else "1" end' 2>/dev/null || echo 0)"
  reason="$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null || echo '')"
  local keys=() _k                     # bash 3.2 (macOS) has no mapfile
  while IFS= read -r _k; do [ -n "$_k" ] && keys+=("$_k"); done \
    < <(printf '%s' "$json" | jq -r '.keys[]? // empty' 2>/dev/null || true)
  local plan; plan="$(printf 'text=%q keys=[%s]' "$text" "${keys[*]:-}")"

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

  case "$action" in
    wait)  printf '%s· %s 仍在工作%s — %s\n' "$CD" "$pane" "$CR" "$reason"; return 3 ;;
    done)  printf '%s✓ %s 任务完成%s — %s\n' "$CG" "$pane" "$CR" "$reason"; _clearmark "$pane"; return 2 ;;
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
  _send "$pane" "$text" "${keys[@]}"
  printf '%s✓ %s 已发送:%s %s   %s(%s)%s\n' "$CG" "$pane" "$CR" "$plan" "$CD" "$reason" "$CR"; _clearmark "$pane"
  audit "send\t$pane\t$plan\t$reason"; return 0
}

# ---------------------------------------------------------------------------
# watch: resident loop. Only consults the brain when the pane is "quiet"
# (screen unchanged for a couple polls) or already flagged needs-input, so we
# don't burn a Codex call every tick while the agent is actively working.
# ---------------------------------------------------------------------------
cmd_watch_loop() {
  local pane goal policy wf poll auto maxcalls calls=0 last="" quiet=0 decided="" rc started last_decision="" status next_at
  local cooldown_until=0 now_s sleep_for marked=0 cap h
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane" >&2; return 1; }
  goal="${2:-}"
  policy="${3:-}"
  [ -z "$policy" ] && [ "$(opt @radar-ai-watch-always-allow off)" = "on" ] && policy="always-allow"
  poll="${4:-}"; case "$poll" in ''|*[!0-9.]*) poll="$(opt @radar-ai-poll 5)" ;; esac
  auto="${5:-}"; [ -n "$auto" ] || auto="$(opt @radar-ai-watch-autonomy auto-safe)"
  maxcalls="$(opt @radar-ai-max-calls 40)"
  wf="$(_wf "$pane")"
  started="$(now)"
  _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" 0 "starting" "$(now)" ""
  audit "watch-start\t$pane\t$goal\t${policy:-safe}\tpoll=$poll"
  _watch_timeline "$pane" "start" "$(_pane_label "$pane") · policy=${policy:-safe-auto} autonomy=$auto poll=${poll}s max=$maxcalls goal=${goal:-<none>}"
  _watch_detail "$pane" "等待首轮采样" "$(printf 'Target: %s\nPolicy: %s\nAutonomy: %s\nPoll: %ss\nMax calls: %s\nGoal: %s\n' \
    "$(_pane_label "$pane")" "${policy:-safe-auto}" "$auto" "$poll" "$maxcalls" "${goal:-<none>}")"
  printf '%s▶ 开始监控%s %s%s\n%s  策略 %s · 自主度 %s · 轮询 %ss · 决策上限 %s 次%s\n' \
    "$CG" "$CR" "$(_pane_label "$pane")" "${goal:+  ${CD}· ${goal}${CR}}" \
    "$CD" "${policy:-安全项自动}" "$auto" "$poll" "$maxcalls" "$CR"
  # Keep the brain in this shell's lifecycle. Signals from `stop`, monitor-pane
  # Ctrl-C/close, or tmux teardown terminate every descendant before state is
  # removed, so a Codex CLI child cannot be reparented to PID 1.
  trap 'trap - TERM INT HUP; _terminate_current_brain; rm -f "$wf"; exit 0' TERM INT HUP

  while :; do
    tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1 || { echo "pane $pane gone"; break; }
    now_s="$(now)"
    if [ "$cooldown_until" -gt "$now_s" ]; then
      status="cooldown after decision"
      _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "$status" "$cooldown_until" "$last_decision"
      sleep_for=$((cooldown_until - now_s))
      [ "$sleep_for" -lt 1 ] && sleep_for=1
      sleep "$sleep_for"
      continue
    fi

    marked=0
    cap="$(tmux capture-pane -p -t "$pane" -S "-$(opt @radar-ai-capture-lines 120)" 2>/dev/null || true)"
    h="$(printf '%s' "$cap" | cksum | awk '{print $1}')"
    [ -r "$STATE_FILE" ] && grep -q "^$pane"$'\t' "$STATE_FILE" 2>/dev/null && marked=1
    if [ "$h" = "$last" ]; then quiet=$((quiet+1)); else quiet=0; last="$h"; fi

    # trigger a decision on a fresh quiet screen or a new needs-input mark
    if { [ "$marked" = 1 ] || [ "$quiet" -ge 2 ]; } && [ "$h" != "$decided" ]; then
      decided="$h"
      calls=$((calls+1))
      status="calling model: $([ "$marked" = 1 ] && printf 'AI-status mark' || printf 'quiet=%s' "$quiet")"
      _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "$status" 0 "$last_decision"
      _watch_timeline "$pane" "decide" "call $calls/$maxcalls · $status"
      if [ "$calls" -gt "$maxcalls" ]; then
        echo "watch $pane: hit max-calls ($maxcalls), pausing"
        _watch_timeline "$pane" "pause" "hit max-calls ($maxcalls)"
        _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "paused: max-calls hit" "$(now)" "$last_decision"
        _escalate "$pane" "AI 监控达到调用上限($maxcalls),已暂停"; audit "watch-cap\t$pane"; break
      fi
      set +e; TMUX_RADAR_AI_DETAIL=1 cmd_decide "$pane" "$auto" "$policy" "$goal"; rc=$?; set -e
      last_decision="$(now)"
      cooldown_until="$(awk -v n="$last_decision" -v p="$poll" 'BEGIN { if ((p+0) < 1) p = 1; printf "%d", n + p }')"
      case "$rc" in
        0) status="sent safe action" ;;
        2) status="done" ;;
        3) status="model says wait" ;;
        4) status="paused: escalated to user" ;;
        5) status="decision error/unknown" ;;
        6) status="suggested; not sent" ;;
        *) status="decision rc=$rc" ;;
      esac
      _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "$status" "$cooldown_until" "$last_decision"
      case "$rc" in
        2) echo "watch $pane: done"; _watch_timeline "$pane" "done" "${goal:-task complete}"; audit "watch-done\t$pane\t$goal"; _escalate "$pane" "AI: 任务完成 ✓${goal:+ ($goal)}"; break ;;
        4) echo "watch $pane: escalated to user, pausing"; _watch_timeline "$pane" "pause" "escalated to user"; break ;;
      esac
      _watch_timeline "$pane" "cooldown" "next check starts ${poll}s after decision completion"
    else
      if [ "$marked" = 1 ]; then status="marked; already decided for this screen"
      elif [ "$quiet" -lt 2 ]; then status="watching active screen; quiet=$quiet/2"
      else status="quiet screen already evaluated; waiting for change"; fi
    fi
    now_s="$(now)"
    if [ "$cooldown_until" -gt "$now_s" ]; then
      next_at="$cooldown_until"
    else
      next_at="$(awk -v n="$now_s" -v p="$poll" 'BEGIN { if ((p+0) < 1) p = 1; printf "%d", n + p }')"
    fi
    _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "$status" "$next_at" "$last_decision"
    sleep_for=$((next_at - now_s))
    [ "$sleep_for" -lt 1 ] && sleep_for=1
    sleep "$sleep_for"
  done
  _watch_timeline "$pane" "stop" "watch loop ended"
  rm -f "$wf"; audit "watch-stop\t$pane"
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
  local pane goal policy poll auto wf base feed pos mon_size err layout mon_pane detail_cmd timeline_cmd single_cmd watch_pid
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
        if err="$(tmux split-window "${split_args[@]}" -d -t "$pane" "$single_cmd" 2>&1)"; then
          audit "monitor-start\t$pane\t$pos\tsingle\tsize=$mon_size"
        else
          printf '%s⚠ 监控 pane 打开失败，已停止 watch%s%s\n' "$CY" "$CR" "${err:+: $err}"
          audit "monitor-fail\t$pane\t$pos\tsingle\tsize=${mon_size:-?}\t$err"
          _abort_watch_launch "$pane" "$watch_pid"
          return 1
        fi
      elif mon_pane="$(tmux split-window "${split_args[@]}" -P -F '#{pane_id}' -d -t "$pane" "$timeline_cmd" 2>&1)"; then
        if [ "$pos" = "right" ]; then
          tmux split-window -v -d -t "$mon_pane" -p 55 "$detail_cmd" >/dev/null 2>&1 || \
            audit "monitor-detail-fail\t$pane\t$pos\t$mon_pane"
        else
          tmux split-window -h -d -t "$mon_pane" -p 58 "$detail_cmd" >/dev/null 2>&1 || \
            audit "monitor-detail-fail\t$pane\t$pos\t$mon_pane"
        fi
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

rc=0
case "${1:-}" in
  ask)          shift; cmd_ask "$@" || rc=$? ;;
  decide)       shift; cmd_decide "${1:-}" "${2:-}" "${3:-}" "${4:-}" || rc=$? ;;
  watch)        shift; cmd_watch "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" || rc=$? ;;
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
  *) echo "usage: ai.sh {ask [req]|decide [pane] [autonomy] [policy]|watch <pane> [goal] [policy] [poll] [autonomy]|watch-setup [pane]|monitor <pane>|monitor-timeline <pane>|monitor-detail <pane>|stop <pane|all>|status|list|cleanup|menu}" >&2; exit 2 ;;
esac
# menu-launched popups set this so the result stays on screen until a keypress
if [ -n "${TMUX_RADAR_AI_PAUSE:-${TMUX_SWITCHER_AI_PAUSE:-}}" ] && [ -t 0 ]; then
  printf '\n%s按任意键关闭…%s' "$CD" "$CR"; read -n1 -r _ </dev/tty 2>/dev/null || true
fi
exit "$rc"

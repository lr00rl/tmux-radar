#!/usr/bin/env bash
# tmux-switcher AI supervisor — an AI (Codex) that watches the AI coding TUIs
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
#   list                list AI panes and their need-input state
#   cleanup             GC stale watcher files / monitor panes / need-input marks
#   menu                tmux display-menu entry point (prefix + <@switcher-ai-key>)
#
# Config (tmux options, all optional):
#   @switcher-ai-key            A                     menu key (prefix + A)
#   @switcher-ai-model          gpt-5.3-codex-spark   Codex model slug (spark = fast tier)
#   @switcher-ai-effort         low                   minimal|low|medium|high|xhigh
#   @switcher-ai-profile        (none)                codex config profile (-p); overrides model/effort
#   @switcher-ai-cmd            (none)                replace Codex entirely: shell cmd,
#                                                     prompt on stdin -> decision JSON on stdout
#   @switcher-ai-autonomy       confirm               ask: suggest|confirm|auto
#   @switcher-ai-watch-autonomy auto-safe             watch: auto-safe|suggest|auto
#   @switcher-ai-poll           5                     watch: seconds between polls
#   @switcher-ai-max-calls      40                    watch: cost cap on brain calls
#   @switcher-ai-capture-lines  120                   pane lines fed to the brain
#   @switcher-ai-monitor        on                    open companion monitor pane
#   @switcher-ai-monitor-pos    top                   top|bottom|right
#   @switcher-ai-monitor-size   12                    monitor height (top/bottom)
#   @switcher-ai-monitor-size-h 60                    monitor width (right)
#   @switcher-ai-monitor-layout split                 split|single
#   @switcher-ai-rules          (none)                file path OR literal text: user rules
#                                                     (what to auto-approve / always escalate),
#                                                     appended to every decide prompt; default
#                                                     file ~/.config/tmux-switcher/rules.md
#   @switcher-ai-prompt-dir     (none)                dir shadowing prompts/ (decide.md,
#                                                     control.md, *.schema.json) per file
#
# Testing seam: set TMUX_SWITCHER_AI_CMD to a shell snippet that reads the prompt
# on stdin and writes the decision JSON to stdout; Codex is then never called.
# (@switcher-ai-cmd is the user-facing version of the same seam.)
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

STATE_DIR="${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}"
STATE_FILE="${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}"
WATCH_DIR="$STATE_DIR/ai-watch"
LOG="${TMUX_SWITCHER_AI_LOG:-$STATE_DIR/ai.log}"
mkdir -p "$STATE_DIR" "$WATCH_DIR"

opt() { local v; v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }
have_tmux() { command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; }
need_jq()  { command -v jq >/dev/null 2>&1 || { echo "tmux-switcher AI needs 'jq'." >&2; exit 3; }; }
have_brain() { [ -n "${TMUX_SWITCHER_AI_CMD:-}" ] || [ -n "$(opt @switcher-ai-cmd '')" ] || command -v codex >/dev/null 2>&1; }
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

# Prompt "skills" are plain files; @switcher-ai-prompt-dir lets the user shadow
# any of them (decide.md / control.md / *.schema.json) with their own copies.
_skill_file() {
  local d; d="$(opt @switcher-ai-prompt-dir '')"
  if [ -n "$d" ] && [ -r "$d/$1" ]; then printf '%s/%s' "$d" "$1"
  else printf '%s/%s' "$PROMPT_DIR" "$1"; fi
}
_skill() { cat "$(_skill_file "$1")" 2>/dev/null; }

# User approval rules — @switcher-ai-rules is a file path (contents used) or a
# literal text block; falls back to ~/.config/tmux-switcher/rules.md when unset.
# Appended to every decide prompt as the highest-priority section, so the user
# controls what gets auto-approved vs escalated without editing the plugin.
_user_rules() {
  local r; r="$(opt @switcher-ai-rules '')"
  [ -z "$r" ] && [ -r "$HOME/.config/tmux-switcher/rules.md" ] && r="$HOME/.config/tmux-switcher/rules.md"
  [ -n "$r" ] || return 0
  [ -r "$r" ] && r="$(cat "$r" 2>/dev/null)"
  [ -n "$r" ] || return 0
  printf '\n\nUSER RULES (set by the user in their tmux config; when they conflict with the guidance above, the USER RULES win):\n%s' "$r"
}
_wf()  { printf '%s/%s.watch' "$WATCH_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
_wbase() { local wf; wf="$(_wf "$1")"; printf '%s' "${wf%.watch}"; }
_flat() { printf '%s' "$1" | tr '\n\t' '  '; }

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
  local pane="$1" title="$2" body="$3" file
  file="$(_wbase "$pane").detail"
  {
    printf '%s\n' "$title"
    printf '%s\n\n' "$(date '+%F %T')"
    printf '%s\n' "$body"
  } > "$file" 2>/dev/null || true
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

# Human-readable target for headers: "session:win.pane cmd" instead of "%160".
_pane_label() {
  tmux display-message -p -t "$1" '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null || printf '%s' "$1"
}

# Resolve a pane target -> canonical %id. Empty arg falls back to $TMUX_PANE,
# then to the most recently marked live pane in the need-input state.
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
  local schema="$1" prompt="$2" out custom profile
  out="$(mktemp "${TMPDIR:-/tmp}/tmuxai.XXXXXX")"
  # env seam (tests) wins over the user-facing option; both replace codex with
  # any command that reads the prompt on stdin and prints decision JSON.
  custom="${TMUX_SWITCHER_AI_CMD:-$(opt @switcher-ai-cmd '')}"
  if [ -n "$custom" ]; then
    printf '%s' "$prompt" | eval "$custom" > "$out" 2>/dev/null || true
  elif [ -n "$(opt @switcher-ai-profile '')" ]; then
    # a codex profile bundles model/effort/etc in ~/.codex/config.toml; the
    # safety flags (read-only, ephemeral) stay ours and are not overridable
    profile="$(opt @switcher-ai-profile '')"
    codex exec -p "$profile" \
      -s read-only --ephemeral --skip-git-repo-check \
      --output-schema "$schema" -o "$out" -- "$prompt" >/dev/null 2>&1 || true
  else
    codex exec \
      -m "$(opt @switcher-ai-model gpt-5.3-codex-spark)" \
      -c model_reasoning_effort="$(opt @switcher-ai-effort low)" \
      -s read-only --ephemeral --skip-git-repo-check \
      --output-schema "$schema" -o "$out" -- "$prompt" >/dev/null 2>&1 || true
  fi
  cat "$out" 2>/dev/null; rm -f "$out"
}

_brain_label() {
  local custom profile
  custom="${TMUX_SWITCHER_AI_CMD:-$(opt @switcher-ai-cmd '')}"
  if [ -n "$custom" ]; then
    printf 'custom command: %s' "$(_flat "$custom")"
  elif [ -n "$(opt @switcher-ai-profile '')" ]; then
    profile="$(opt @switcher-ai-profile '')"
    printf 'codex profile: %s (read-only, ephemeral)' "$profile"
  else
    printf 'codex exec: model=%s effort=%s (read-only, ephemeral)' \
      "$(opt @switcher-ai-model gpt-5.3-codex-spark)" "$(opt @switcher-ai-effort low)"
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
# $2 = autonomy (suggest|confirm|auto|auto-safe); default from @switcher-ai-autonomy
# ---------------------------------------------------------------------------
cmd_decide() {
  need_jq
  have_brain || { echo "codex 未安装/不可用，无法决策。"; return 3; }
  local pane autonomy policy goal cap where json action text safe reason extra="" prompt backend
  pane="$(_resolve_pane "${1:-}")" || { echo "no target pane"; return 5; }
  autonomy="${2:-$(opt @switcher-ai-autonomy confirm)}"
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
  cap="$(tmux capture-pane -p -t "$pane" -S "-$(opt @switcher-ai-capture-lines 120)" 2>/dev/null || true)"
  [ -n "$cap" ] || { echo "pane $pane: nothing to read"; return 5; }

  prompt="$(_skill decide.md)$extra"$'\n\n'"PANE ($where):"$'\n'"$cap"
  backend="$(_brain_label)"
  if [ -n "${TMUX_SWITCHER_AI_DETAIL:-}" ]; then
    _watch_detail "$pane" "模型请求中" "$(printf 'Backend: %s\nTarget: %s\nAutonomy: %s\nPolicy: %s\nGoal: %s\n\nPane excerpt sent to model (last %s lines):\n%s\n' \
      "$backend" "$where" "$autonomy" "${policy:-safe-auto}" "${goal:-<none>}" "$(opt @switcher-ai-capture-lines 120)" "$cap")"
  fi
  json="$(_brain "$(_skill_file decide.schema.json)" "$prompt")"
  action="$(printf '%s' "$json" | jq -r '.action // "unknown"' 2>/dev/null || echo unknown)"
  text="$(printf '%s' "$json" | jq -r '.text // ""' 2>/dev/null || echo '')"
  safe="$(printf '%s' "$json" | jq -r 'if .safe == false then "0" else "1" end' 2>/dev/null || echo 0)"
  reason="$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null || echo '')"
  local keys=() _k                     # bash 3.2 (macOS) has no mapfile
  while IFS= read -r _k; do [ -n "$_k" ] && keys+=("$_k"); done \
    < <(printf '%s' "$json" | jq -r '.keys[]? // empty' 2>/dev/null || true)
  local plan; plan="$(printf 'text=%q keys=[%s]' "$text" "${keys[*]:-}")"

  if [ -n "${TMUX_SWITCHER_AI_DETAIL:-}" ]; then
    _watch_detail "$pane" "最近一次模型决策" "$(printf 'Backend: %s\nTarget: %s\nAutonomy: %s\nPolicy: %s\nGoal: %s\n\nParsed decision:\n  action: %s\n  safe: %s\n  reason: %s\n  plan: %s\n\nModel JSON:\n%s\n\nPane excerpt sent to model (last %s lines):\n%s\n' \
      "$backend" "$where" "$autonomy" "${policy:-safe-auto}" "${goal:-<none>}" \
      "$action" "$safe" "${reason:-<none>}" "$plan" "${json:-<empty>}" "$(opt @switcher-ai-capture-lines 120)" "$cap")"
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
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane" >&2; return 1; }
  goal="${2:-}"
  policy="${3:-}"
  [ -z "$policy" ] && [ "$(opt @switcher-ai-watch-always-allow off)" = "on" ] && policy="always-allow"
  poll="${4:-}"; case "$poll" in ''|*[!0-9.]*) poll="$(opt @switcher-ai-poll 5)" ;; esac
  auto="${5:-}"; [ -n "$auto" ] || auto="$(opt @switcher-ai-watch-autonomy auto-safe)"
  maxcalls="$(opt @switcher-ai-max-calls 40)"
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
  # $wf is a function-local, so an EXIT trap would see it out-of-scope after the
  # loop returns (rm no-ops). Trap signals only (wf is in scope mid-loop); clean
  # up normal exits explicitly after the loop.
  trap 'rm -f "$wf"; exit 0' TERM INT

  while :; do
    tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1 || { echo "pane $pane gone"; break; }
    local cap h marked=0
    cap="$(tmux capture-pane -p -t "$pane" -S "-$(opt @switcher-ai-capture-lines 120)" 2>/dev/null || true)"
    h="$(printf '%s' "$cap" | cksum | awk '{print $1}')"
    [ -r "$STATE_FILE" ] && grep -q "^$pane"$'\t' "$STATE_FILE" 2>/dev/null && marked=1
    if [ "$h" = "$last" ]; then quiet=$((quiet+1)); else quiet=0; last="$h"; fi

    # trigger a decision on a fresh quiet screen or a new needs-input mark
    if { [ "$marked" = 1 ] || [ "$quiet" -ge 2 ]; } && [ "$h" != "$decided" ]; then
      decided="$h"
      calls=$((calls+1))
      status="calling model: $([ "$marked" = 1 ] && printf 'need-input mark' || printf 'quiet=%s' "$quiet")"
      _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "$status" "$(now)" "$last_decision"
      _watch_timeline "$pane" "decide" "call $calls/$maxcalls · $status"
      if [ "$calls" -gt "$maxcalls" ]; then
        echo "watch $pane: hit max-calls ($maxcalls), pausing"
        _watch_timeline "$pane" "pause" "hit max-calls ($maxcalls)"
        _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "paused: max-calls hit" "$(now)" "$last_decision"
        _escalate "$pane" "AI 监控达到调用上限($maxcalls),已暂停"; audit "watch-cap\t$pane"; break
      fi
      set +e; TMUX_SWITCHER_AI_DETAIL=1 cmd_decide "$pane" "$auto" "$policy" "$goal"; rc=$?; set -e
      last_decision="$(now)"
      _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "decision rc=$rc" "$(now)" "$last_decision"
      case "$rc" in
        2) echo "watch $pane: done"; _watch_timeline "$pane" "done" "${goal:-task complete}"; audit "watch-done\t$pane\t$goal"; _escalate "$pane" "AI: 任务完成 ✓${goal:+ ($goal)}"; break ;;
        4) echo "watch $pane: escalated to user, pausing"; _watch_timeline "$pane" "pause" "escalated to user"; break ;;
      esac
    else
      if [ "$marked" = 1 ]; then status="marked; already decided for this screen"
      elif [ "$quiet" -lt 2 ]; then status="watching active screen; quiet=$quiet/2"
      else status="quiet screen already evaluated; waiting for change"; fi
    fi
    next_at="$(awk -v n="$(now)" -v p="$poll" 'BEGIN { if ((p+0) < 1) p = 1; printf "%d", n + p }')"
    _watch_state_write "$pane" "$started" "$poll" "$goal" "$policy" "$auto" "$maxcalls" "$calls" "$quiet" "$marked" "$status" "$next_at" "$last_decision"
    sleep "$poll"
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

cmd_watch() {  # detach the loop so the caller (popup/menu) can return
  local pane goal policy poll auto wf base feed pos mon_size err layout mon_pane detail_cmd timeline_cmd single_cmd
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
  nohup bash "$SELF" _watch_loop "$pane" "$goal" "$policy" "$poll" "$auto" >"$feed" 2>&1 &
  disown 2>/dev/null || true
  # Companion monitor: a split next to the watched pane, not a covering popup.
  # In the default split layout, the monitor region is split again into
  # timeline + detail panes. If the second split fails, the watcher still runs.
  if [ "$(opt @switcher-ai-monitor on)" = "on" ] && have_tmux; then
    pos="$(opt @switcher-ai-monitor-pos top)"
    layout="$(opt @switcher-ai-monitor-layout split)"
    timeline_cmd="TMUX_SWITCHER_STATE_DIR='$STATE_DIR' exec bash '$SELF' monitor-timeline '$pane'"
    detail_cmd="TMUX_SWITCHER_STATE_DIR='$STATE_DIR' exec bash '$SELF' monitor-detail '$pane'"
    single_cmd="TMUX_SWITCHER_STATE_DIR='$STATE_DIR' exec bash '$SELF' monitor '$pane'"
    split_args=()
    case "$pos" in
      bottom)
        if mon_size="$(monitor_size "$pane" height "$(opt @switcher-ai-monitor-size 12)" 8 4)"; then
          split_args=(-v -l "$mon_size")
        fi ;;
      right)
        if mon_size="$(monitor_size "$pane" width "$(opt @switcher-ai-monitor-size-h 60)" 20 30)"; then
          split_args=(-h -l "$mon_size")
        fi ;;
      *)
        pos="top"
        if mon_size="$(monitor_size "$pane" height "$(opt @switcher-ai-monitor-size 12)" 8 4)"; then
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
          printf '%s⚠ 监控 pane 打开失败%s（watch 仍在运行）%s\n' "$CY" "$CR" "${err:+: $err}"
          audit "monitor-fail\t$pane\t$pos\tsingle\tsize=${mon_size:-?}\t$err"
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
        printf '%s⚠ 监控 pane 打开失败%s（watch 仍在运行）%s\n' "$CY" "$CR" "${mon_pane:+: $mon_pane}"
        audit "monitor-fail\t$pane\t$pos\tsplit\tsize=${mon_size:-?}\t$mon_pane"
      fi
    else
      printf '%s⚠ 目标 pane 太小，未打开监控 pane%s（watch 仍在运行）\n' "$CY" "$CR"
      audit "monitor-skip\t$pane\t$pos\tpane-too-small"
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
  printf '\n%s轮询间隔秒（回车 = %s）%s\n> ' "$CD" "$(opt @switcher-ai-poll 5)" "$CR"
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
  local target="${1:-all}" wf pid
  if [ "$target" = "all" ]; then
    for wf in "$WATCH_DIR"/*.watch; do
      [ -e "$wf" ] || continue
      pid="$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)"
      [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
      rm -f "$wf"
    done
    echo "stopped all watchers"; return 0
  fi
  target="$(_resolve_pane "$target" 2>/dev/null || echo "$target")"
  wf="$(_wf "$target")"
  [ -f "$wf" ] || { echo "no watcher for $target"; return 0; }
  pid="$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
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
  local mode="$1" pane="$2" wf base feed timeline detail label cols rows body now_s next_at remain
  local started poll goal policy auto maxcalls calls quiet marked status updated last_decision leftw rightw lefttmp righttmp
  pane="$(_resolve_pane "$pane" 2>/dev/null || echo "$pane")"
  wf="$(_wf "$pane")"; base="${wf%.watch}"
  feed="$base.out"; timeline="$base.timeline"; detail="$base.detail"
  label="$(_pane_label "$pane")"
  [ -f "$feed" ] || : > "$feed"
  [ -f "$timeline" ] || : > "$timeline"
  [ -f "$detail" ] || : > "$detail"
  while [ -f "$wf" ]; do
    cols="$(tput cols 2>/dev/null || echo 100)"
    rows="$(tput lines 2>/dev/null || echo 24)"
    case "$cols" in ''|*[!0-9]*) cols=100 ;; esac
    case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
    body=$((rows - 5)); [ "$body" -lt 6 ] && body=6
    now_s="$(now)"
    started="$(_state_get "$wf" started)"; poll="$(_state_get "$wf" poll)"
    goal="$(_state_get "$wf" goal)"; policy="$(_state_get "$wf" policy)"
    auto="$(_state_get "$wf" autonomy)"; maxcalls="$(_state_get "$wf" maxcalls)"
    calls="$(_state_get "$wf" calls)"; quiet="$(_state_get "$wf" quiet)"
    marked="$(_state_get "$wf" marked)"; status="$(_state_get "$wf" status)"
    next_at="$(_state_get "$wf" next_at)"; updated="$(_state_get "$wf" updated)"
    last_decision="$(_state_get "$wf" last_decision)"
    case "$next_at" in ''|*[!0-9]*) remain=0 ;; *) remain=$((next_at - now_s)); [ "$remain" -lt 0 ] && remain=0 ;; esac

    printf '\033[H\033[J'
    printf '\033[7;1m AI monitor · %s \033[0m  %s%s%s\n' "$mode" "$CD" "$label" "$CR"
    printf 'status=%s%s%s · next=%ss · calls=%s/%s · quiet=%s · mark=%s · poll=%ss · updated=%s\n' \
      "$CC" "${status:-starting}" "$CR" "$remain" "${calls:-0}" "${maxcalls:-?}" "${quiet:-0}" "${marked:-0}" "${poll:-?}" "${updated:-?}"
    [ -n "$goal" ] && printf '%sgoal: %s%s\n' "$CD" "$goal" "$CR" || printf '%spolicy=%s autonomy=%s last-decision=%s%s\n' "$CD" "${policy:-?}" "${auto:-?}" "${last_decision:-none}" "$CR"
    printf '%s%s\n' "$CD" "$(printf '%*s' "$cols" '' | tr ' ' '-')"

    case "$mode" in
      timeline)
        { printf 'Timeline\n'; tail -n "$((body - 1))" "$timeline" 2>/dev/null; } | _clip_lines "$cols" "$body"
        ;;
      detail)
        {
          printf 'Detail\n'
          cat "$detail" 2>/dev/null
          printf '\nRecent feed\n'
          tail -n 8 "$feed" 2>/dev/null
        } | _clip_lines "$cols" "$body"
        ;;
      *)
        leftw=$((cols * 42 / 100)); [ "$leftw" -lt 34 ] && leftw=34
        rightw=$((cols - leftw - 3)); [ "$rightw" -lt 30 ] && rightw=30
        lefttmp="$(mktemp "${TMPDIR:-/tmp}/tmuxai-left.XXXXXX")"
        righttmp="$(mktemp "${TMPDIR:-/tmp}/tmuxai-right.XXXXXX")"
        { printf 'Timeline\n'; tail -n "$((body - 1))" "$timeline" 2>/dev/null; } | _clip_lines "$leftw" "$body" > "$lefttmp"
        {
          printf 'Detail\n'
          cat "$detail" 2>/dev/null
          printf '\nRecent feed\n'
          tail -n 6 "$feed" 2>/dev/null
        } | _clip_lines "$rightw" "$body" > "$righttmp"
        paste "$lefttmp" "$righttmp" 2>/dev/null | while IFS=$'\t' read -r l r; do
          printf "%-${leftw}s │ %s\n" "$l" "$r"
        done
        rm -f "$lefttmp" "$righttmp"
        ;;
    esac
    sleep 1
  done
  printf '\033[H\033[J'
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
  autonomy="$(opt @switcher-ai-autonomy confirm)"
  snap="$(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{?pane_active,*,} #{pane_current_command} #{pane_current_path} "#{pane_title}"' 2>/dev/null || true)"
  echo "· thinking…"
  json="$(_brain "$PROMPT_DIR/control.schema.json" "$(_skill control.md)"$'\n\n'"CURRENT TMUX PANES:"$'\n'"$snap"$'\n\n'"CURRENT PANE: ${TMUX_PANE:-?}"$'\n'"USER REQUEST: $req")"
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
# list: AI panes + their need-input / watch state (quick picker source).
# Detection goes through the notifier's process scan (ps argv0 components), not
# pane_current_command — Claude Code's foreground binary is a bare version
# number ("2.1.199"), so the naive match misses it.
# ---------------------------------------------------------------------------
cmd_list() {
  have_tmux || { echo "no tmux server"; return 0; }
  _hdr "AI panes" "⚠ 等待输入 · ● 监控中"
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
      -v CG="$CG" -v CM="$CM" -v CD="$CD" -v CR="$CR" '
    BEGIN {
      n=split(marks, ml, "\001"); for(i=1;i<=n;i++){split(ml[i],f,"\t"); if(f[1]!="") flagged[f[1]]=(f[5]?f[5]:f[4])}
      have_scan = (index(agents, "OK\001") == 1)
    }
    {
      # precise scan when available, else fall back to the command heuristic
      if (have_scan) { if (index(agents, "\001" $1 "\001") == 0 && !($1 in flagged)) next }
      else if (tolower($3) !~ /codex|claude/ && !($1 in flagged)) next
      w = (index(watching, $1 "\001") > 0) ? CG "●" CR : " "
      if ($1 in flagged) tail = CM "⚠ " flagged[$1] CR
      else               tail = CD $4 CR
      printf "%s %-5s %-20s %s%-10s%s %s\n", w, $1, $2, CD, $3, CR, tail
    }'
}

# ---------------------------------------------------------------------------
# cleanup: GC everything a dead server / resurrect restore can leave behind —
# watcher pidfiles whose process is gone, orphan feed files, leftover monitor
# panes whose watcher ended, and stale need-input marks (via the notifier).
# Safe to run any time; wired to plugin load and (optionally) the
# tmux-resurrect post-restore hook.
# ---------------------------------------------------------------------------
cmd_cleanup() {
  local wf pid f base n=0 mon start watched live_pids orphan_pids opid
  for wf in "$WATCH_DIR"/*.watch; do
    [ -e "$wf" ] || continue
    pid="$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)"
    kill -0 "$pid" 2>/dev/null && continue
    rm -f "$wf" "${wf%.watch}.out" "${wf%.watch}.timeline" "${wf%.watch}.detail"; n=$((n+1))
  done
  for f in "$WATCH_DIR"/*.out "$WATCH_DIR"/*.timeline "$WATCH_DIR"/*.detail; do
    [ -e "$f" ] || continue
    case "$f" in
      *.out) base="${f%.out}" ;;
      *.timeline) base="${f%.timeline}" ;;
      *.detail) base="${f%.detail}" ;;
      *) base="${f%.*}" ;;
    esac
    [ -f "$base.watch" ] || rm -f "$f"
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
# menu: the display-menu chooser. Single source of truth — tmux-switcher.tmux
# binds prefix + <@switcher-ai-key> to `ai.sh menu` so this never drifts from
# the plugin binding.
# ---------------------------------------------------------------------------
cmd_menu() {
  local pop; pop="display-popup -E -w 80% -h 70%"
  tmux display-menu -T "#[align=centre] tmux AI 主管 " -x C -y C \
    "指挥 tmux（自然语言）"             a "$pop \"TMUX_SWITCHER_AI_PAUSE=1 $SELF ask\"" \
    "让当前 pane 继续 / 决定一次"        c "$pop \"TMUX_SWITCHER_AI_PAUSE=1 $SELF decide '#{pane_id}'\"" \
    "" \
    "常驻监控当前 pane 直到完成"         w "run-shell \"$SELF watch '#{pane_id}'\"" \
    "常驻监控 + always-allow（更省心）"  W "run-shell \"$SELF watch '#{pane_id}' '' always-allow\"" \
    "自定义监控（目标 / 间隔 / 策略）…"   v "$pop \"$SELF watch-setup '#{pane_id}'\"" \
    "" \
    "状态 / 最近决策"                   s "$pop \"TMUX_SWITCHER_AI_PAUSE=1 $SELF status\"" \
    "停止全部监控"                      S "run-shell \"$SELF stop all\"" \
    "列出 AI pane"                     l "$pop \"TMUX_SWITCHER_AI_PAUSE=1 $SELF list\""
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
if [ -n "${TMUX_SWITCHER_AI_PAUSE:-}" ] && [ -t 0 ]; then
  printf '\n%s按任意键关闭…%s' "$CD" "$CR"; read -n1 -r _ </dev/tty 2>/dev/null || true
fi
exit "$rc"

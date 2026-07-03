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
  local pane autonomy policy goal cap where json action text safe reason extra=""
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

  json="$(_brain "$(_skill_file decide.schema.json)" "$(_skill decide.md)$extra"$'\n\n'"PANE ($where):"$'\n'"$cap")"
  action="$(printf '%s' "$json" | jq -r '.action // "unknown"' 2>/dev/null || echo unknown)"
  text="$(printf '%s' "$json" | jq -r '.text // ""' 2>/dev/null || echo '')"
  safe="$(printf '%s' "$json" | jq -r 'if .safe == false then "0" else "1" end' 2>/dev/null || echo 0)"
  reason="$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null || echo '')"
  local keys=() _k                     # bash 3.2 (macOS) has no mapfile
  while IFS= read -r _k; do [ -n "$_k" ] && keys+=("$_k"); done \
    < <(printf '%s' "$json" | jq -r '.keys[]? // empty' 2>/dev/null || true)

  case "$action" in
    wait)  printf '%s· %s 仍在工作%s — %s\n' "$CD" "$pane" "$CR" "$reason"; return 3 ;;
    done)  printf '%s✓ %s 任务完成%s — %s\n' "$CG" "$pane" "$CR" "$reason"; _clearmark "$pane"; return 2 ;;
    unknown|"") printf '%s? %s 无法判读%s — %s\n' "$CY" "$pane" "$CR" "$reason"; return 5 ;;
  esac
  # action == send (or escalate)
  local plan; plan="$(printf 'text=%q keys=[%s]' "$text" "${keys[*]:-}")"
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
      printf '   执行? [y/N] '; local ans=""; read -e -r ans </dev/tty 2>/dev/null || ans=""
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
  local pane goal policy wf poll auto maxcalls calls=0 last="" quiet=0 decided="" rc
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane" >&2; return 1; }
  goal="${2:-}"
  policy="${3:-}"
  [ -z "$policy" ] && [ "$(opt @switcher-ai-watch-always-allow off)" = "on" ] && policy="always-allow"
  poll="${4:-}"; case "$poll" in ''|*[!0-9.]*) poll="$(opt @switcher-ai-poll 5)" ;; esac
  auto="${5:-}"; [ -n "$auto" ] || auto="$(opt @switcher-ai-watch-autonomy auto-safe)"
  maxcalls="$(opt @switcher-ai-max-calls 40)"
  wf="$(_wf "$pane")"
  printf 'pid=%s\npane=%s\nstarted=%s\npoll=%s\ngoal=%s\n' "$$" "$pane" "$(now)" "$poll" "$goal" > "$wf"
  audit "watch-start\t$pane\t$goal\t${policy:-safe}\tpoll=$poll"
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
      if [ "$calls" -gt "$maxcalls" ]; then
        echo "watch $pane: hit max-calls ($maxcalls), pausing"
        _escalate "$pane" "AI 监控达到调用上限($maxcalls),已暂停"; audit "watch-cap\t$pane"; break
      fi
      set +e; cmd_decide "$pane" "$auto" "$policy" "$goal"; rc=$?; set -e
      case "$rc" in
        2) echo "watch $pane: done"; audit "watch-done\t$pane\t$goal"; _escalate "$pane" "AI: 任务完成 ✓${goal:+ ($goal)}"; break ;;
        4) echo "watch $pane: escalated to user, pausing"; break ;;
      esac
    fi
    sleep "$poll"
  done
  rm -f "$wf"; audit "watch-stop\t$pane"
}

cmd_watch() {  # detach the loop so the caller (popup/menu) can return
  local pane goal policy poll auto wf feed size pos split
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane"; return 1; }
  goal="${2:-}"; policy="${3:-}"; poll="${4:-}"; auto="${5:-}"
  wf="$(_wf "$pane")"; feed="${wf%.watch}.out"
  if [ -f "$wf" ] && kill -0 "$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)" 2>/dev/null; then
    echo "already watching $pane (stop it first)"; return 0
  fi
  : > "$feed"                                  # create the feed before the monitor tails it
  nohup bash "$SELF" _watch_loop "$pane" "$goal" "$policy" "$poll" "$auto" >"$feed" 2>&1 &
  disown 2>/dev/null || true
  # Companion monitor pane: a small split NEXT TO the watched pane (not a
  # covering popup), live-tailing the decision feed; it self-closes when the
  # watch ends. So you see the supervisor's decisions AND the pane's progress.
  if [ "$(opt @switcher-ai-monitor on)" = "on" ] && have_tmux; then
    pos="$(opt @switcher-ai-monitor-pos top)"
    case "$pos" in
      bottom) split="-v -l $(opt @switcher-ai-monitor-size 8)" ;;
      right)  split="-h -l $(opt @switcher-ai-monitor-size-h 60)" ;;
      *)      split="-v -b -l $(opt @switcher-ai-monitor-size 8)" ;;   # top (default)
    esac
    # pass STATE_DIR explicitly: the split pane inherits the tmux server env, not
    # the watcher's, so this keeps the monitor's feed/pidfile paths in sync.
    tmux split-window $split -d -t "$pane" \
      "TMUX_SWITCHER_STATE_DIR='$STATE_DIR' exec bash '$SELF' monitor '$pane'" 2>/dev/null || true
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
  IFS= read -e -r goal </dev/tty 2>/dev/null || goal=""
  printf '\n%s轮询间隔秒（回车 = %s）%s\n> ' "$CD" "$(opt @switcher-ai-poll 5)" "$CR"
  IFS= read -e -r poll </dev/tty 2>/dev/null || poll=""
  printf '\n%s批准策略%s\n' "$CD" "$CR"
  printf '  1) 安全项自动批准，其余上报给你（默认）\n'
  printf '  2) always-allow — 安全项可选“不再询问”，更省心\n'
  printf '  3) 仅建议 — 只播报，不代按任何键\n> '
  IFS= read -e -r ans </dev/tty 2>/dev/null || ans=""
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
# monitor: the live viewer that runs in the companion split pane. Tails the
# watcher's decision feed; when the watcher ends (its pidfile disappears), it
# lingers briefly then returns, so the exec'd pane closes and the layout
# restores. Read-only — you watch here, the watched pane runs below/beside.
# ---------------------------------------------------------------------------
cmd_monitor() {
  local pane wf feed tailpid
  pane="$(_resolve_pane "${1:-}" 2>/dev/null || echo "${1:-}")"
  wf="$(_wf "$pane")"; feed="${wf%.watch}.out"
  _hdr "▶ AI 监控 $(_pane_label "$pane")" "被监控的 pane 就在旁边 · 本窗随监控结束自动关闭"
  [ -f "$feed" ] || : > "$feed"
  tail -n +1 -F "$feed" 2>/dev/null &
  tailpid=$!
  while [ -f "$wf" ]; do sleep 1; done
  kill "$tailpid" 2>/dev/null || true
  printf '\n\033[2m— 监控结束，本窗即将关闭 —\033[0m\n'; sleep 3
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
  [ -n "$req" ] || { printf 'tmux 指令（自然语言）: '; read -e -r req </dev/tty 2>/dev/null || true; }
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
      printf '执行? [y/N] '; local ans=""; read -e -r ans </dev/tty 2>/dev/null || ans=""
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
  local wf pid f n=0 mon start watched
  for wf in "$WATCH_DIR"/*.watch; do
    [ -e "$wf" ] || continue
    pid="$(awk -F= '/^pid=/{print $2}' "$wf" 2>/dev/null)"
    kill -0 "$pid" 2>/dev/null && continue
    rm -f "$wf" "${wf%.watch}.out"; n=$((n+1))
  done
  for f in "$WATCH_DIR"/*.out; do
    [ -e "$f" ] || continue
    [ -f "${f%.out}.watch" ] || rm -f "$f"
  done
  if have_tmux; then
    tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_start_command}' 2>/dev/null |
      grep -F "' monitor '" | grep -F "$SELF" |
      while IFS=$'\t' read -r mon start; do
        watched="$(printf '%s' "$start" | sed -n "s/.* monitor '\(%[0-9][0-9]*\)'.*/\1/p")"
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
  stop)         shift; cmd_stop "${1:-all}" || rc=$? ;;
  status)       cmd_status || rc=$? ;;
  list)         cmd_list || rc=$? ;;
  cleanup)      cmd_cleanup || rc=$? ;;
  menu)         cmd_menu || rc=$? ;;
  *) echo "usage: ai.sh {ask [req]|decide [pane] [autonomy] [policy]|watch <pane> [goal] [policy] [poll] [autonomy]|watch-setup [pane]|monitor <pane>|stop <pane|all>|status|list|cleanup|menu}" >&2; exit 2 ;;
esac
# menu-launched popups set this so the result stays on screen until a keypress
if [ -n "${TMUX_SWITCHER_AI_PAUSE:-}" ] && [ -t 0 ]; then
  printf '\n%s按任意键关闭…%s' "$CD" "$CR"; read -n1 -r _ </dev/tty 2>/dev/null || true
fi
exit "$rc"

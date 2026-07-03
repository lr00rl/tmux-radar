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
#   watch <pane> [goal] resident: keep deciding for a pane until its task is done
#   stop  <pane|all>    stop a resident watcher
#   status              list active watchers + recent decisions
#   list                list AI panes and their need-input state
#   menu                tmux display-menu entry point (prefix + a)
#
# Config (tmux options, all optional):
#   @switcher-ai-model          gpt-5.3-codex-spark   Codex model slug
#   @switcher-ai-effort         low                   reasoning effort per call
#   @switcher-ai-autonomy       confirm               ask: suggest|confirm|auto
#   @switcher-ai-watch-autonomy auto-safe             watch: auto-safe|suggest|auto
#   @switcher-ai-poll           5                     watch: seconds between polls
#   @switcher-ai-max-calls      40                    watch: cost cap on brain calls
#   @switcher-ai-capture-lines  120                   pane lines fed to the brain
#
# Testing seam: set TMUX_SWITCHER_AI_CMD to a shell snippet that reads the prompt
# on stdin and writes the decision JSON to stdout; Codex is then never called.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
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
have_brain() { [ -n "${TMUX_SWITCHER_AI_CMD:-}" ] || command -v codex >/dev/null 2>&1; }
now()  { date '+%s'; }
audit() { printf '%s\t%s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }
_skill() { cat "$PROMPT_DIR/$1" 2>/dev/null; }
_wf()  { printf '%s/%s.watch' "$WATCH_DIR" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

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
  local schema="$1" prompt="$2" out; out="$(mktemp "${TMPDIR:-/tmp}/tmuxai.XXXXXX")"
  if [ -n "${TMUX_SWITCHER_AI_CMD:-}" ]; then
    printf '%s' "$prompt" | eval "$TMUX_SWITCHER_AI_CMD" > "$out" 2>/dev/null || true
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
  local pane autonomy cap where json action text safe reason
  pane="$(_resolve_pane "${1:-}")" || { echo "no target pane"; return 5; }
  autonomy="${2:-$(opt @switcher-ai-autonomy confirm)}"
  where="$(tmux display-message -p -t "$pane" '#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}' 2>/dev/null || echo "$pane")"
  cap="$(tmux capture-pane -p -t "$pane" -S "-$(opt @switcher-ai-capture-lines 120)" 2>/dev/null || true)"
  [ -n "$cap" ] || { echo "pane $pane: nothing to read"; return 5; }

  json="$(_brain "$PROMPT_DIR/decide.schema.json" "$(_skill decide.md)"$'\n\n'"PANE ($where):"$'\n'"$cap")"
  action="$(printf '%s' "$json" | jq -r '.action // "unknown"' 2>/dev/null || echo unknown)"
  text="$(printf '%s' "$json" | jq -r '.text // ""' 2>/dev/null || echo '')"
  safe="$(printf '%s' "$json" | jq -r 'if .safe == false then "0" else "1" end' 2>/dev/null || echo 0)"
  reason="$(printf '%s' "$json" | jq -r '.reason // ""' 2>/dev/null || echo '')"
  local keys=() _k                     # bash 3.2 (macOS) has no mapfile
  while IFS= read -r _k; do [ -n "$_k" ] && keys+=("$_k"); done \
    < <(printf '%s' "$json" | jq -r '.keys[]? // empty' 2>/dev/null || true)

  case "$action" in
    wait)  echo "· $pane still working — $reason"; return 3 ;;
    done)  echo "✓ $pane task complete — $reason"; _clearmark "$pane"; return 2 ;;
    unknown|"") echo "? $pane unreadable — $reason"; return 5 ;;
  esac
  # action == send (or escalate)
  local plan; plan="$(printf 'text=%q keys=[%s]' "$text" "${keys[*]:-}")"
  if [ "$action" = "escalate" ] || [ "$safe" = "0" ]; then
    echo "⚠ $pane needs YOU — $reason"; _escalate "$pane" "AI 拿不准: $reason"
    audit "escalate\t$pane\t$reason"; return 4
  fi
  case "$autonomy" in
    suggest)
      echo "→ $pane would send: $plan   ($reason)"; audit "suggest\t$pane\t$plan\t$reason"; return 6 ;;
    confirm)
      echo "→ $pane: $reason"; echo "   send: $plan"
      printf '   apply? [y/N] '; local ans=""; read -r ans </dev/tty 2>/dev/null || ans=""
      case "$ans" in y|Y|yes) ;; *) echo "   skipped"; return 6 ;; esac ;;
    auto-safe|auto) : ;;   # safe already ensured above
    *) echo "unknown autonomy: $autonomy" >&2; return 5 ;;
  esac
  _send "$pane" "$text" "${keys[@]}"
  echo "✓ $pane sent: $plan   ($reason)"; _clearmark "$pane"
  audit "send\t$pane\t$plan\t$reason"; return 0
}

# ---------------------------------------------------------------------------
# watch: resident loop. Only consults the brain when the pane is "quiet"
# (screen unchanged for a couple polls) or already flagged needs-input, so we
# don't burn a Codex call every tick while the agent is actively working.
# ---------------------------------------------------------------------------
cmd_watch_loop() {
  local pane goal wf poll maxcalls calls=0 last="" quiet=0 decided="" rc
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane" >&2; return 1; }
  goal="${2:-}"
  poll="$(opt @switcher-ai-poll 5)"
  maxcalls="$(opt @switcher-ai-max-calls 40)"
  wf="$(_wf "$pane")"
  printf 'pid=%s\npane=%s\nstarted=%s\ngoal=%s\n' "$$" "$pane" "$(now)" "$goal" > "$wf"
  audit "watch-start\t$pane\t$goal"
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
      set +e; cmd_decide "$pane" "$(opt @switcher-ai-watch-autonomy auto-safe)"; rc=$?; set -e
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
  local pane goal
  pane="$(_resolve_pane "${1:-}")" || { echo "watch: no target pane"; return 1; }
  goal="${2:-}"
  if [ -f "$(_wf "$pane")" ] && kill -0 "$(awk -F= '/^pid=/{print $2}' "$(_wf "$pane")" 2>/dev/null)" 2>/dev/null; then
    echo "already watching $pane (stop it first)"; return 0
  fi
  nohup bash "$SELF" _watch_loop "$pane" "$goal" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  echo "watching $pane${goal:+ — goal: $goal}"
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
  local wf pid pane goal started any=0
  for wf in "$WATCH_DIR"/*.watch; do
    [ -e "$wf" ] || continue
    pid="$(awk -F= '/^pid=/{print $2}' "$wf")"; pane="$(awk -F= '/^pane=/{print $2}' "$wf")"
    goal="$(awk -F= '/^goal=/{print $2}' "$wf")"; started="$(awk -F= '/^started=/{print $2}' "$wf")"
    if kill -0 "$pid" 2>/dev/null; then
      any=1; printf 'watching %s  (pid %s, %ss)  %s\n' "$pane" "$pid" "$(( $(now) - ${started:-$(now)} ))" "${goal:-—}"
    else rm -f "$wf"; fi
  done
  [ "$any" = 1 ] || echo "no active watchers"
  if [ -r "$LOG" ]; then echo "--- recent decisions ---"; tail -n 8 "$LOG"; fi
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
  [ -n "$req" ] || { printf 'tmux 指令（自然语言）: '; read -r req </dev/tty 2>/dev/null || true; }
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
      printf '执行? [y/N] '; local ans=""; read -r ans </dev/tty 2>/dev/null || ans=""
      case "$ans" in y|Y|yes) ;; *) echo "已取消"; rm -f "$cmds_file"; return 6 ;; esac ;;
  esac
  tmux source-file "$cmds_file" 2>&1 && echo "✓ 已执行 $n 条" || echo "部分命令执行失败"
  audit "ask\t$req\t$n cmds"
  rm -f "$cmds_file"
}

# ---------------------------------------------------------------------------
# list: AI panes + their need-input marks (quick picker source).
# ---------------------------------------------------------------------------
cmd_list() {
  have_tmux || { echo "no tmux server"; return 0; }
  # join mark records with \001 — BSD awk rejects newlines in -v values
  local marks=""; [ -r "$STATE_FILE" ] && marks="$(tr '\n' '\001' < "$STATE_FILE")"
  tmux list-panes -a -F '#{pane_id}'$'\t''#{session_name}:#{window_index}.#{pane_index}'$'\t''#{pane_current_command}'$'\t''#{pane_title}' 2>/dev/null |
  awk -F '\t' -v marks="$marks" '
    BEGIN { n=split(marks, ml, "\001"); for(i=1;i<=n;i++){split(ml[i],f,"\t"); if(f[1]!="") flagged[f[1]]=(f[5]?f[5]:f[4])} }
    tolower($3) ~ /codex|claude/ {
      printf "%s  %-16s %-8s %s%s\n", $1, $2, $3, ($1 in flagged?"⚠ ":"  "), ($1 in flagged?flagged[$1]:$4)
    }'
}

# ---------------------------------------------------------------------------
# menu: prefix + a entry — a small tmux display-menu chooser.
# ---------------------------------------------------------------------------
cmd_menu() {
  local pop; pop="display-popup -E -w 80% -h 60%"
  tmux display-menu -T "#[align=centre] tmux AI 主管 " \
    "指挥 tmux（自然语言）" a "$pop \"$SELF ask; echo; read -n1 -p '回车关闭…' _\"" \
    "让当前 pane 继续 / 决定"  c "$pop \"$SELF decide '#{pane_id}'; echo; read -n1 -p '回车关闭…' _\"" \
    "常驻监控当前 pane 到完成" w "run-shell \"$SELF watch '#{pane_id}'\"" \
    "" \
    "查看 / 停止监控" s "$pop \"$SELF status; echo; read -n1 -p '回车关闭…' _\"" \
    "停止全部监控" S "run-shell \"$SELF stop all\"" \
    "列出所有 AI pane" l "$pop \"$SELF list; echo; read -n1 -p '回车关闭…' _\""
}

rc=0
case "${1:-}" in
  ask)          shift; cmd_ask "$@" || rc=$? ;;
  decide)       shift; cmd_decide "${1:-}" "${2:-}" || rc=$? ;;
  watch)        shift; cmd_watch "${1:-}" "${2:-}" || rc=$? ;;
  _watch_loop)  shift; cmd_watch_loop "${1:-}" "${2:-}" || rc=$? ;;
  stop)         shift; cmd_stop "${1:-all}" || rc=$? ;;
  status)       cmd_status || rc=$? ;;
  list)         cmd_list || rc=$? ;;
  menu)         cmd_menu || rc=$? ;;
  *) echo "usage: ai.sh {ask [req]|decide [pane]|watch <pane> [goal]|stop <pane|all>|status|list|menu}" >&2; exit 2 ;;
esac
# menu-launched popups set this so the result stays on screen until a keypress
if [ -n "${TMUX_SWITCHER_AI_PAUSE:-}" ] && [ -t 0 ]; then
  printf '\n回车关闭…'; read -n1 -r _ </dev/tty 2>/dev/null || true
fi
exit "$rc"

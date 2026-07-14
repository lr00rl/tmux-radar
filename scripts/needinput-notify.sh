#!/usr/bin/env bash
# shellcheck disable=SC2016
# Mark / clear panes and sessions with AI-status notices, driven by Claude Code
# hooks plus Codex hooks / legacy notify. Single state file under $STATE_DIR:
#
#   need-input   one mark per line, 6 TAB-separated fields:
#                "<pane>\t<epoch>\t<source>\t<key>\t<label>\t<saved_title>"
#     pane        %id of the marked pane, or "-" for paneless (background) marks
#     key         stable clear key: "s:<claude session_id>" or the pane id
#     saved_title pane_title before we retitled it (restored on clear)
#
# Presentation (kept in sync by every mutation + `tick`):
#   - persistent bar: status line 2 (status-format[1] -> needinput-toast.sh)
#     shows marks whose pane is not currently on screen; `status 2` while any
#     such mark is live, `status on` when none.
#   - pane retitle: marked panes get a status-prefixed pane_title (`⚠` action,
#     `✓` finished, `!` notice), restored on clear.
#     Disable with `set -g @radar-retitle off`.
#
# Claude background sessions (dashboard / cloud / `claude` jobs) run outside
# any tmux pane ($TMUX_PANE unset, $CLAUDE_JOB_DIR set): they are recorded as
# paneless marks keyed by session_id so the bar still notifies you, and the
# AI status view lists them. Disable with `set -g @radar-claude-bg off`.
#
# Safe to call outside tmux (no-op unless a server is reachable).
set -euo pipefail

# Hooks may run with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
STATE_FILE="${TMUX_RADAR_NEEDINPUT_FILE:-${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}}"
BG_TTL="${TMUX_RADAR_BG_TTL:-${TMUX_SWITCHER_BG_TTL:-86400}}"   # paneless marks expire after 24h
LOCK="$STATE_DIR/.need-input.lock"

[ "${TMUX_RADAR_INTERNAL:-0}" = 1 ] && exit 0

mkdir -p "$STATE_DIR"

have_tmux() { command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; }
lock()   { local n=0; until mkdir "$LOCK" 2>/dev/null; do n=$((n+1)); [ "$n" -gt 100 ] && break; sleep 0.02; done; }
unlock() { rmdir "$LOCK" 2>/dev/null || true; }

opt() {  # opt <option> <default> (empty/no server -> default)
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

_san() { printf '%s' "${1:-}" | tr '\t\n' '  '; }

_watch_field() {
  awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$1" 2>/dev/null || true
}

_watch_event() {  # _watch_event <pane> <kind> <source> <label>
  local pane="$1" kind="$2" source="$3" label="$4" wf run_dir run_id
  [ -n "$pane" ] || return 0
  wf="$STATE_DIR/ai-watch/$(printf '%s' "$pane" | tr -c 'A-Za-z0-9' '_').watch"
  [ -r "$wf" ] || return 0
  run_dir="$(_watch_field "$wf" run_dir)"
  run_id="$(_watch_field "$wf" run_id)"
  [ -d "$run_dir" ] && [ -n "$run_id" ] || return 0
  TMUX_RADAR_EXPECT_RUN_ID="$run_id" \
    "$SCRIPT_DIR/ai.sh" emit-event "$pane" "$kind" "$source" "$(_san "$label")" >/dev/null 2>&1 || true
}


# One tmux round-trip: "<pane_id> <on_screen 0|1>" per live pane, records
# joined with \001 (BSD awk rejects newlines in -v values).
_pane_map() {
  have_tmux || return 0
  tmux list-panes -a -F \
    '#{pane_id} #{&&:#{pane_active},#{&&:#{window_active},#{!=:#{session_attached},0}}}' 2>/dev/null |
    tr '\n' '\001' || true
}

# Panes currently hosting a watched AI agent (claude/codex/…). Prints
# "OK\001%id\001%id\001…" — "OK\001" alone means the scan RAN and found none;
# EMPTY output means the scan failed and the caller must not GC on it.
# Matching mirrors switcher.sh's AI status view: an agent claims a pane when
# its ps argv0 — any path component, ".app" stripped — equals a watched command
# name AND it either sits on the pane's tty or has the pane's shell in its
# parent chain. pane_current_command is NOT reliable here: Claude Code's
# foreground binary is a bare version number ("2.1.199"), its argv0 is "claude".
_agent_panes() {
  have_tmux || return 0
  local cmds panes ps_rows
  cmds="${TMUX_RADAR_NEEDINPUT_COMMANDS:-${TMUX_SWITCHER_NEEDINPUT_COMMANDS:-$(opt @radar-needinput-commands 'codex claude')}}"
  panes="$(tmux list-panes -a -F '#{pane_id} #{pane_pid} #{pane_tty}' 2>/dev/null)" || return 0
  [ -n "$panes" ] || return 0
  ps_rows="$(ps -axo pid=,ppid=,tty=,command= 2>/dev/null)" || return 0
  [ -n "$ps_rows" ] || return 0
  { printf '__PANES__\n%s\n__PS__\n%s\n' "$panes" "$ps_rows"; } | LC_ALL=C awk -v cmds="$cmds" '
    function cleantty(t) { sub(/^\/dev\//, "", t); return t }
    function is_agent(a0,    n, parts, i, c, w) {
      a0 = tolower(a0); gsub(/\\/, "/", a0)
      n = split(a0, parts, "/")
      for (w in want)
        for (i = 1; i <= n; i++) { c = parts[i]; sub(/\.app$/, "", c); if (c == w) return 1 }
      return 0
    }
    BEGIN {
      m = split(tolower(cmds), raw, /[[:space:],:]+/)
      for (i = 1; i <= m; i++) if (raw[i] != "") want[raw[i]] = 1
    }
    $0 == "__PANES__" { mode = 1; next }
    $0 == "__PS__"    { mode = 2; next }
    mode == 1 && $1 != "" { bypid[$2] = $1; bytty[cleantty($3)] = $1; next }
    mode == 2 && $1 != "" {
      par[$1] = $2
      if (is_agent($4)) { agent[$1] = 1; atty[$1] = cleantty($3) }
      next
    }
    END {
      for (pid in agent) {
        if (atty[pid] != "" && atty[pid] != "??" && (atty[pid] in bytty)) { hit[bytty[atty[pid]]] = 1; continue }
        cur = pid
        for (hops = 0; hops < 80 && cur != "" && cur != "0"; hops++) {
          if (cur in bypid) { hit[bypid[cur]] = 1; break }
          cur = par[cur]
        }
      }
      out = "OK"
      for (p in hit) out = out "\001" p
      printf "%s\001", out
    }'
}

_claude_live_keys() {
  local f json sid state out="OK"
  for f in "$HOME"/.claude/jobs/*/state.json; do
    [ -r "$f" ] || continue
    json="$(cat "$f" 2>/dev/null || true)"
    [ -n "$json" ] || continue
    sid="$(_json_field sessionId "$json")"
    state="$(_json_field state "$json")"
    [ -n "$sid" ] || continue
    case "$state" in
      blocked|working|idle|"") out="$out"$'\001'"s:$sid" ;;
    esac
  done
  printf '%s\001' "$out"
}

# Find the tmux pane hosting THIS process (a Claude hook runs as a child of its
# claude): match our controlling tty against pane ttys, else walk our parent
# chain to a pane shell pid. Lets marks land on the real pane even when
# $TMUX_PANE was scrubbed from the environment (agent launchers, job runners).
_resolve_pane_by_proc() {
  have_tmux || return 1
  local map rel
  map="$(tmux list-panes -a -F '#{pane_id} #{pane_pid} #{pane_tty}' 2>/dev/null)"
  [ -n "$map" ] || return 1
  rel="$(ps -axo pid=,ppid=,tty= 2>/dev/null)"
  [ -n "$rel" ] || return 1
  { printf '__PANES__\n%s\n__PS__\n%s\n' "$map" "$rel"; } | awk -v me="$$" '
    function cleantty(t) { sub(/^\/dev\//, "", t); return t }
    $0 == "__PANES__" { mode = 1; next }
    $0 == "__PS__"    { mode = 2; next }
    mode == 1 && $1 != "" { bypid[$2] = $1; bytty[cleantty($3)] = $1; next }
    mode == 2 && $1 != "" { par[$1] = $2; tty[$1] = cleantty($3); next }
    END {
      if (tty[me] != "" && tty[me] != "??" && (tty[me] in bytty)) { print bytty[tty[me]]; exit }
      cur = me
      for (hops = 0; hops < 40 && cur != "" && cur != "0" && cur != "1"; hops++) {
        if (cur in bypid) { print bypid[cur]; exit }
        cur = par[cur]
      }
    }'
}

_resolve_pane_by_cwd() {  # _resolve_pane_by_cwd <cwd>
  have_tmux || return 1
  local cwd="${1:-}" map
  [ -n "$cwd" ] || return 1
  map="$(tmux list-panes -a -F '#{pane_id}'$'\t''#{pane_current_path}'$'\t''#{window_name}'$'\t''#{pane_title}'$'\t''#{pane_current_command}' 2>/dev/null)"
  [ -n "$map" ] || return 1
  printf '%s\n' "$map" | awk -F '\t' -v cwd="$cwd" '
    function score(name, title, cmd, text) {
      text = tolower(name " " title " " cmd)
      return (text ~ /claude/ ? 3 : (text ~ /(ai|agent)/ ? 2 : 1))
    }
    $2 == cwd {
      s = score($3, $4, $5)
      if (s > best) { best = s; pane = $1 }
      hits++
    }
    END {
      if (hits == 1 || best >= 3) print pane
    }'
}

# Rewrite the state file through an awk filter (callers hold the lock).
# Also normalizes legacy 4-field rows and drops dead-pane / expired-bg rows.
_rewrite() {  # _rewrite <awk-filter-body> [extra awk -v args...]
  local body="$1"; shift || true
  local tmp; tmp="$(mktemp "${STATE_FILE}.XXXXXX")"
  { [ -r "$STATE_FILE" ] && cat "$STATE_FILE"; :; } |
    awk -F '\t' -v OFS='\t' -v now="$(date +%s)" -v bgttl="$BG_TTL" -v panes="$(_pane_map)" "$@" '
      BEGIN {
        n = split(panes, pl, "\001")
        have_map = 0
        for (i = 1; i <= n; i++) { split(pl[i], f, " "); if (f[1] != "") { alive[f[1]] = 1; have_map = 1 } }
      }
      NF < 4 { next }
      {
        pane = $1; epoch = $2; src = $3
        if (NF >= 5) { key = $4; label = $5; title = (NF >= 6 ? $6 : "") }
        else         { key = $1; label = $4; title = "" }          # legacy row
        if (pane == "-") { if (now - epoch > bgttl) next }         # expired bg
        else if (have_map && !(pane in alive)) next                # dead pane
        '"$body"'
        print pane, epoch, src, key, label, title
      }
    ' > "$tmp" || true
  mv "$tmp" "$STATE_FILE"
}

_restore_title() {  # _restore_title <pane> <saved_title>
  local pane="$1" saved="$2" cur
  [ "$pane" = "-" ] || [ -z "$pane" ] && return 0
  [ "$(opt @radar-retitle on)" = "off" ] && return 0
  cur="$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)"
  case "$cur" in "⚠ "*|"✓ "*|"! "*|"· "*) tmux select-pane -t "$pane" -T "$saved" 2>/dev/null || true ;; esac
}

_mark_icon() {  # _mark_icon <source> <label>
  local text
  text="$(printf '%s %s' "${1:-}" "${2:-}" | tr '[:upper:]' '[:lower:]')"
  case "$text" in
    *finished*|*"your turn"*|*"turn complete"*|*"task complete"*|*"任务完成"*|*"完成"*) printf '✓' ;;
    *"needs approval"*|*"needs your permission"*|*"needs input"*|*waiting*input*|*"waiting on you"*|*permission*|*approval*|*"action required"*|*approve*|*"拿不准"*|*"需要你"*|*"等待"*"输入"*) printf '⚠' ;;
    *) printf '!' ;;
  esac
}

_refresh_titles() {
  have_tmux || return 0
  [ "$(opt @radar-retitle on)" = "off" ] && return 0
  [ -r "$STATE_FILE" ] || return 0
  local pane _epoch source _key label _title
  while IFS=$'\t' read -r pane _epoch source _key label _title; do
    [ -n "$pane" ] || continue
    [ "$pane" = "-" ] && continue
    tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1 || continue
    tmux select-pane -t "$pane" -T "$(_mark_icon "$source" "$label") ${label}" 2>/dev/null || true
  done < "$STATE_FILE"
}

# Restore titles for rows an awk filter is about to drop, then rewrite.
_drop_rows() {  # _drop_rows <awk-condition-marking-rows-to-DROP> [extra -v args...]
  local cond="$1"; shift || true
  if [ -r "$STATE_FILE" ] && [ "$(opt @radar-retitle on)" != "off" ]; then
    local victims pane title
    victims="$(awk -F '\t' "$@" "NF >= 6 && ($cond) { print \$1 \"\t\" \$6 }" "$STATE_FILE" 2>/dev/null || true)"
    while IFS=$'\t' read -r pane title; do
      [ -n "$pane" ] && [ -n "$title" ] && _restore_title "$pane" "$title"
    done <<< "$victims"
  fi
  _rewrite "if ($cond) next" "$@"
}

# Recompute bar visibility: status 2 while any mark is bar-visible, else status
# on. A chip is bar-visible while its mark is off-screen AND younger than
# @radar-bar-ttl seconds (0 = show until handled); the mark itself persists
# in the AI status view / pane title until actually cleared.
_sync_bar() {
  have_tmux || return 0
  local n=0 barttl
  barttl="$(opt @radar-bar-ttl 60)"
  if [ -r "$STATE_FILE" ]; then
    n="$(awk -F '\t' -v panes="$(_pane_map)" -v now="$(date +%s)" -v barttl="$barttl" '
      BEGIN {
        m = split(panes, pl, "\001")
        for (i = 1; i <= m; i++) { split(pl[i], f, " "); if (f[1] != "") { alive[f[1]] = 1; if (f[2] == 1) viewed[f[1]] = 1 } }
      }
      NF >= 4 {
        pane = $1
        if (barttl + 0 > 0 && now - $2 > barttl + 0) next
        if (pane == "-") { c++; next }
        if ((pane in alive) && !(pane in viewed)) c++
      }
      END { print c + 0 }' "$STATE_FILE" 2>/dev/null || echo 0)"
  fi
  if [ "${n:-0}" -gt 0 ]; then tmux set -g status 2 >/dev/null 2>&1 || true
  else tmux set -g status on >/dev/null 2>&1 || true; fi
  tmux refresh-client -S >/dev/null 2>&1 || true
}

cmd_mark() {  # cmd_mark <pane|-> <source> <label> [key]
  local pane="${1:-${TMUX_PANE:-}}" source="${2:-tool}" label="${3:-needs input}" key="${4:-}"
  have_tmux || exit 0
  label="$(_san "$label")"
  local now saved_title=""
  now="$(date +%s)"

  if [ "$pane" != "-" ]; then
    [ -n "$pane" ] || exit 0
    tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null 2>&1 || exit 0
    [ -n "$key" ] || key="$pane"
    if [ "$(opt @radar-retitle on)" != "off" ]; then
      saved_title="$(_san "$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)")"
      case "$saved_title" in "⚠ "*|"✓ "*|"! "*|"· "*) saved_title="" ;; esac   # keep original across re-marks
      tmux select-pane -t "$pane" -T "$(_mark_icon "$source" "$label") ${label}" 2>/dev/null || true
    fi
  else
    [ -n "$key" ] || exit 0
  fi

  lock
  # replace any previous mark with the same key or same pane (a pane waits for
  # at most one thing); keep the earliest saved title across re-marks
  local prev_title=""
  prev_title="$(awk -F '\t' -v k="$key" -v p="$pane" \
    'NF >= 6 && ($4 == k || (p != "-" && $1 == p)) && $6 != "" { print $6; exit }' "$STATE_FILE" 2>/dev/null || true)"
  [ -n "$prev_title" ] && saved_title="$prev_title"
  _rewrite 'if (key == delkey || (mp != "-" && pane == mp)) next' -v delkey="$key" -v mp="$pane"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pane" "$now" "$source" "$key" "$label" "$saved_title" >> "$STATE_FILE"
  unlock
  _sync_bar
}

cmd_clear_key()  { [ -n "${1:-}" ] || exit 0; lock; _drop_rows '$4 == k' -v k="$1"; unlock; _sync_bar; }
cmd_clear_pane() {
  local pane="${1:-${TMUX_PANE:-}}"
  [ -n "$pane" ] || exit 0
  lock; _drop_rows '$1 == p' -v p="$pane"; unlock; _sync_bar
}

cmd_clear_window() {  # clear marks for every pane inside a window target
  local target="${1:-}"
  [ -n "$target" ] || exit 0
  have_tmux || exit 0
  local panes
  panes="$(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null | tr '\n' '\034')"
  [ -n "$panes" ] || { _sync_bar; return 0; }
  lock; _drop_rows 'index(ps, "\034" $1 "\034") > 0' -v ps=$'\034'"$panes"; unlock
  _sync_bar
}

cmd_clear_all() { lock; _drop_rows '1'; unlock; _sync_bar; }

# tick = prune + agent-liveness GC + bar resync. A pane mark whose source is an
# AI agent (claude/codex/ai) but whose pane no longer hosts that agent (TUI
# closed, shell reused for something else) is stale — drop it and restore the
# pane title. If the process scan failed we only do the plain prune.
cmd_tick() {
  local agents claude_keys
  agents="$(_agent_panes || true)"
  claude_keys="$(_claude_live_keys || true)"
  lock
  if [ -n "$agents" ]; then
    _drop_rows '$1 != "-" && ($3 == "claude" || $3 == "codex" || $3 == "ai") && index(ag, "\001" $1 "\001") == 0 && !($3 == "claude" && index(ck, "\001" $4 "\001") > 0)' \
      -v ag="${agents#OK}" -v ck="${claude_keys#OK}"
  else
    _rewrite ''
  fi
  unlock
  _refresh_titles
  _sync_bar
}

# Extract a JSON string field (jq if present, else sed best-effort).
_json_field() {
  local field="$1" json="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null || true
  else
    printf '%s' "$json" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
  fi
}

# Claude hooks pass JSON on stdin (session_id, cwd, message, ...).
# Interactive TUI in a pane: $TMUX_PANE is the claude pane -> pane mark.
# Background session (dashboard/cloud/job): $CLAUDE_JOB_DIR set or $TMUX_PANE
# unset -> paneless mark keyed by session_id, labelled with the project dir.
_claude_target() {  # sets PANE / KEY / WHERE from hook json in $1
  local json="$1" sid cwd ignore p
  sid="$(_json_field session_id "$json")"
  cwd="$(_json_field cwd "$json")"
  KEY=""; [ -n "$sid" ] && KEY="s:${sid}"
  WHERE=""; [ -n "$cwd" ] && WHERE="$(basename "$cwd")"
  if [ -n "${CLAUDE_JOB_DIR:-}" ] || [ -z "${TMUX_PANE:-}" ]; then
    # No $TMUX_PANE — but the session may still live in a pane (env-scrubbed
    # launcher, agent runner forked from a pane's claude). Resolve through our
    # own tty / process ancestry before falling back to a paneless mark, so the
    # mark is jumpable instead of a bare "session id + name" row.
    p="$(_resolve_pane_by_proc || true)"
    if [ -z "$p" ] && [ -n "$cwd" ]; then p="$(_resolve_pane_by_cwd "$cwd" || true)"; fi
    if [ -n "$p" ]; then PANE="$p"; return 0; fi
    PANE="-"
    [ -n "$KEY" ] || KEY="bg:${WHERE:-unknown}"
    # plugin-internal background sessions (claude-mem observers, SDK helpers,
    # ...) live under these path prefixes — pure noise, don't track them
    ignore="$(opt @radar-claude-bg-ignore "$HOME/.claude:$HOME/.claude-mem")"
    if [ -n "$cwd" ] && [ -n "$ignore" ]; then
      IFS=':' read -ra _pfx <<< "$ignore"
      for p in "${_pfx[@]}"; do
        [ -n "$p" ] || continue
        case "$cwd" in "$p"*) exit 0 ;; esac
      done
    fi
  else
    PANE="$TMUX_PANE"
  fi
}

cmd_claude_mark() {  # Notification hook (permission request / waiting on you)
  local json msg
  json="$(cat 2>/dev/null || true)"
  msg="$(_json_field message "$json")"
  [ -n "$msg" ] || msg="Claude needs input"
  _claude_target "$json"
  if [ "$PANE" = "-" ]; then
    [ "$(opt @radar-claude-bg on)" = "on" ] || exit 0
    msg="Claude·${WHERE:-bg}: ${msg}"
  else
    _watch_event "$PANE" input_required claude "$msg"
  fi
  [ "$(opt @radar-needinput on)" = "on" ] || exit 0
  cmd_mark "$PANE" claude "$msg" "$KEY"
}

cmd_claude_stop() {  # Stop hook (turn finished — your move)
  local json msg
  json="$(cat 2>/dev/null || true)"
  _claude_target "$json"
  msg="Claude finished — your turn"
  if [ "$PANE" = "-" ]; then
    [ "$(opt @radar-claude-bg on)" = "on" ] || exit 0
    msg="Claude·${WHERE:-bg}: finished — your turn"
  else
    _watch_event "$PANE" turn_complete claude "$msg"
  fi
  [ "$(opt @radar-needinput on)" = "on" ] || exit 0
  cmd_mark "$PANE" claude "$msg" "$KEY"
}

cmd_claude_clear() {  # UserPromptSubmit hook (you replied)
  local json
  json="$(cat 2>/dev/null || true)"
  _claude_target "$json"
  if [ "$PANE" != "-" ] && [ -n "$PANE" ]; then
    _watch_event "$PANE" user_resumed claude 'Claude resumed by user'
  fi
  if [ -n "$KEY" ] && [ "${KEY#s:}" != "$KEY" ]; then cmd_clear_key "$KEY"
  elif [ "$PANE" != "-" ] && [ -n "$PANE" ]; then cmd_clear_pane "$PANE"
  fi
}

_codex_pane() {
  local pane
  pane="${TMUX_PANE:-}"
  [ -n "$pane" ] || pane="$(_resolve_pane_by_proc || true)"
  printf '%s' "$pane"
}

_codex_event_kind() {
  case "$1" in
    PermissionRequest|exec_approval_request|apply_patch_approval_request|request_permissions) printf 'approval' ;;
    Stop|task_complete|agent-turn-complete|turn_complete) printf 'turn_complete' ;;
    request_user_input) printf 'input_required' ;;
    UserPromptSubmit) printf 'user_resumed' ;;
    *) return 1 ;;
  esac
}

_codex_label() {  # _codex_label <event-or-type> <json>
  local event="$1" json="$2" tool desc
  case "$event" in
    PermissionRequest|exec_approval_request|apply_patch_approval_request|request_permissions)
      tool="$(_json_field tool_name "$json")"
      desc="$(_json_field description "$json")"
      [ -n "$desc" ] || desc="$(_json_field reason "$json")"
      if [ -n "$tool" ]; then printf 'Codex needs approval: %s' "$tool"
      else printf 'Codex needs approval'; fi
      ;;
    Stop|task_complete|agent-turn-complete|turn_complete)
      printf 'Codex finished - your turn'
      ;;
    request_user_input)
      printf 'Codex needs your input'
      ;;
    UserPromptSubmit)
      printf 'Codex resumed by user'
      ;;
    *)
      if [ -n "$event" ]; then printf 'Codex: %s' "$event"
      else printf 'Codex needs input'; fi
      ;;
  esac
}

cmd_codex_hook() {  # Codex native hooks pass JSON on stdin
  local json event pane kind label
  json="$(cat 2>/dev/null || true)"
  event="$(_json_field hook_event_name "$json")"
  [ -n "$event" ] || exit 0
  pane="$(_codex_pane)"
  case "$event" in
    UserPromptSubmit)
      if [ -n "$pane" ]; then
        _watch_event "$pane" user_resumed codex "$(_codex_label "$event" "$json")"
        cmd_clear_pane "$pane"
      fi
      ;;
    PermissionRequest|Stop)
      [ -n "$pane" ] || exit 0
      kind="$(_codex_event_kind "$event")" || exit 0
      label="$(_codex_label "$event" "$json")"
      _watch_event "$pane" "$kind" codex "$label"
      [ "$(opt @radar-needinput on)" = "on" ] || exit 0
      cmd_mark "$pane" codex "$label"
      ;;
  esac
}

cmd_codex() {  # Codex notify passes its event JSON as the last argv argument
  local json="${1:-}" type pane kind label
  type="$(_json_field type "$json")"
  [ -n "$type" ] || exit 0
  pane="$(_codex_pane)"
  case "$type" in
    UserPromptSubmit)
      if [ -n "$pane" ]; then
        _watch_event "$pane" user_resumed codex "$(_codex_label "$type" "$json")"
        cmd_clear_pane "$pane"
      fi
      ;;
    *)
      [ -n "$pane" ] || exit 0
      kind="$(_codex_event_kind "$type")" || exit 0
      label="$(_codex_label "$type" "$json")"
      _watch_event "$pane" "$kind" codex "$label"
      [ "$(opt @radar-needinput on)" = "on" ] || exit 0
      cmd_mark "$pane" codex "$label"
      ;;
  esac
}

case "${1:-}" in
  mark)          shift; cmd_mark "${1:-}" "${2:-tool}" "${3:-needs input}" "${4:-}" ;;
  clear)         shift; cmd_clear_pane "${1:-}" ;;
  clear-key)     shift; cmd_clear_key "${1:-}" ;;
  clear-window)  shift; cmd_clear_window "${1:-}" ;;
  clear-all)     cmd_clear_all ;;
  tick)          cmd_tick ;;
  claude-mark)   cmd_claude_mark ;;
  claude-stop)   cmd_claude_stop ;;
  claude-clear)  cmd_claude_clear ;;
  codex-hook)    cmd_codex_hook ;;
  codex)         shift; cmd_codex "${1:-}" ;;
  agent-panes)   _agent_panes | tr '\001' '\n' ;;   # debug: which panes host an agent
  resolve-pane)  _resolve_pane_by_proc ;;           # debug: pane of this process tree
  resolve-cwd)   shift; _resolve_pane_by_cwd "${1:-$PWD}" ;;  # debug: pane owning a cwd
  *) echo "usage: needinput-notify.sh {mark|clear|clear-key <k>|clear-window <t>|clear-all|tick|claude-mark|claude-stop|claude-clear|codex-hook|codex <json>|agent-panes|resolve-pane|resolve-cwd [cwd]}" >&2; exit 2 ;;
esac

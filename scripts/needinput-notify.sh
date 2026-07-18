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
# Agent-session registry (agent-registry, TSV, 9 fields):
#   "<kind>\t<key>\t<pid>\t<pane>\t<started>\t<last_event>\t<state>\t<cwd>\t<proc>"
# One row per live agent session, maintained by native lifecycle hooks:
# Claude SessionStart/SessionEnd (claude-register / claude-end), every other
# Claude/Codex event (sessions predating hook install are adopted on their
# first event), and the opencode plugin (opencode-hook). pid is the agent
# process resolved from the hook's own ancestry; `proc` records the argv
# basename that matched, so GC requires pid alive AND argv still matching —
# a reused pid can't fake liveness. The registry replaces the old
# ~/.claude/jobs/*/state.json guessing (those files freeze at "blocked"
# after a session dies and kept zombie marks alive for hours).
#
# Safe to call outside tmux (no-op unless a server is reachable).
set -euo pipefail

# Hooks may run with a minimal PATH.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
STATE_FILE="${TMUX_RADAR_NEEDINPUT_FILE:-${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}}"
REG_FILE="${TMUX_RADAR_REGISTRY_FILE:-$STATE_DIR/agent-registry}"
OC_EVENTS_FILE="${TMUX_RADAR_OPENCODE_EVENTS_FILE:-$STATE_DIR/opencode-events}"
BG_TTL="${TMUX_RADAR_BG_TTL:-${TMUX_SWITCHER_BG_TTL:-86400}}"   # paneless marks expire after 24h
LOCK="$STATE_DIR/.need-input.lock"    # one lock guards need-input AND agent-registry
PS_BIN="${TMUX_RADAR_TEST_PS_BIN:-ps}"

# labels that mean "turn finished": these marks survive session end / GC so
# short-lived and background runs still surface. Keep in sync with level_for
# in switcher.sh / needinput-toast.sh.
DONE_RE='(finished|your turn|turn complete|task complete|done|任务完成|完成)'

[ "${TMUX_RADAR_INTERNAL:-0}" = 1 ] && exit 0

mkdir -p "$STATE_DIR"

have_tmux() { command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; }

# Use an OS lock primitive instead of a shell-level reaper protocol. macOS
# shlock publishes with link(2) and reaps dead PIDs; Linux flock is released by
# the kernel when the process exits. Legacy directory locks are migrated only
# when their recorded owner is dead.
LOCK_OWNED=0
LOCK_KIND=""

_legacy_lock_migrate() {
  local owner holder stale
  [ -d "$LOCK" ] || return 0
  if [ -r "$LOCK/owner" ]; then owner="$(cat "$LOCK/owner" 2>/dev/null || true)"
  else owner="$(cat "$LOCK/pid" 2>/dev/null || true)"; fi
  holder="${owner%% *}"
  [ -n "$holder" ] || return 1
  [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null && return 1
  # The owner is absent/dead. Atomic rename means concurrent migrators cannot
  # delete a replacement lock published after this legacy directory.
  stale="${LOCK}.legacy.$$.$RANDOM"
  if mv "$LOCK" "$stale" 2>/dev/null; then
    rm -rf "$stale" 2>/dev/null || true
  fi
  [ ! -d "$LOCK" ]
}

lock() {
  local n=0 max_attempts=40
  while [ -d "$LOCK" ]; do
    _legacy_lock_migrate && continue
    n=$((n + 1))
    [ "$n" -gt "$max_attempts" ] && return 1
    sleep 0.05
  done
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK" 2>/dev/null || return 1
    if flock -w 2 9 2>/dev/null; then
      LOCK_KIND=flock
      LOCK_OWNED=1
      return 0
    fi
    exec 9>&-
    return 1
  fi
  if command -v shlock >/dev/null 2>&1; then
    n=0
    while ! shlock -f "$LOCK" -p "$$" 2>/dev/null; do
      n=$((n + 1))
      [ "$n" -gt "$max_attempts" ] && return 1
      sleep 0.05
    done
    LOCK_KIND=shlock
    LOCK_OWNED=1
    return 0
  fi
  return 1
}
unlock() {
  [ "${LOCK_OWNED:-0}" = 1 ] || return 0
  case "$LOCK_KIND" in
    flock)
      flock -u 9 2>/dev/null || true
      exec 9>&-
      ;;
    shlock)
      [ "$(cat "$LOCK" 2>/dev/null || true)" = "$$" ] && rm -f "$LOCK"
      ;;
  esac
  LOCK_OWNED=0
  LOCK_KIND=""
  return 0
}
trap 'unlock' EXIT INT TERM                             # never leak on set -e abort

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
  cmds="${TMUX_RADAR_NEEDINPUT_COMMANDS:-${TMUX_SWITCHER_NEEDINPUT_COMMANDS:-$(opt @radar-needinput-commands 'codex claude opencode kimi')}}"
  panes="$(tmux list-panes -a -F '#{pane_id} #{pane_pid} #{pane_tty}' 2>/dev/null)" || return 0
  [ -n "$panes" ] || return 0
  ps_rows="${1:-}"
  if [ "$#" -eq 0 ]; then
    ps_rows="$("$PS_BIN" -axo pid=,ppid=,tty=,command= 2>/dev/null)" || return 0
  fi
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

# The agent process this hook descends from: hooks run as children of their
# agent (claude/codex spawn hook commands directly), so walking our own
# ancestry finds the agent pid even under env-scrubbed launchers. Prints
# "pid<TAB>argv-basename"; empty when nothing in the chain matches <kind>.
_resolve_agent_pid() {  # _resolve_agent_pid <kind>
  local kind="${1:-}" rel
  [ -n "$kind" ] || return 0
  rel="$("$PS_BIN" -axo pid=,ppid=,command= 2>/dev/null)" || return 0
  [ -n "$rel" ] || return 0
  printf '%s\n' "$rel" | LC_ALL=C awk -v me="$$" -v kind="$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function kindmatch(argv0,    low, n, parts, i, c) {
      low = tolower(argv0); gsub(/\\/, "/", low)
      n = split(low, parts, "/")
      for (i = 1; i <= n; i++) { c = parts[i]; sub(/\.app$/, "", c); if (c == kind) return 1 }
      return 0
    }
    {
      rest = trim($0)
      pid = rest; sub(/[[:space:]].*/, "", pid); sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
      ppid = rest; sub(/[[:space:]].*/, "", ppid); sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
      a0 = rest; sub(/[[:space:]].*/, "", a0)
      par[pid] = ppid; argv[pid] = a0
    }
    END {
      cur = me
      for (hops = 0; hops < 40 && cur != "" && cur != "0" && cur != "1"; hops++) {
        if (kindmatch(argv[cur])) {
          n = split(argv[cur], parts, "/"); b = parts[n]; sub(/\.app$/, "", b)
          print cur "\t" b
          exit
        }
        cur = par[cur]
      }
    }'
}

# --- agent-session registry (see header). -----------------------------------
_reg_upsert_locked() {  # caller holds lock
  local kind="${1:-}" key="${2:-}" pid="${3:-0}" pane="${4:--}" state="${5:-working}" cwd="${6:-}" proc="${7:-}"
  [ -n "$kind" ] && [ -n "$key" ] || return 0
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  local now old started tmp
  now="$(date +%s)"
  old="$(awk -F '\t' -v k="$key" 'NF >= 9 && $2 == k { print; exit }' "$REG_FILE" 2>/dev/null || true)"
  started="$now"
  if [ -n "$old" ]; then
    # carry fields forward when this event could not re-resolve them
    started="$(printf '%s' "$old" | cut -f5)"
    [ "$pid" = 0 ] && pid="$(printf '%s' "$old" | cut -f3)"
    [ "$pane" = "-" ] && pane="$(printf '%s' "$old" | cut -f4)"
    [ -z "$cwd" ] && cwd="$(printf '%s' "$old" | cut -f8)"
    [ -z "$proc" ] && proc="$(printf '%s' "$old" | cut -f9)"
  fi
  [ -n "$proc" ] || proc="$kind"
  tmp="$(mktemp "${REG_FILE}.XXXXXX")" || return 0
  { [ -r "$REG_FILE" ] && awk -F '\t' -v k="$key" 'NF >= 9 && $2 != k' "$REG_FILE"; :; } > "$tmp" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$kind" "$(_san "$key")" "$pid" "$pane" "$started" "$now" "$state" "$(_san "$cwd")" "$(_san "$proc")" >> "$tmp"
  mv "$tmp" "$REG_FILE"
}

_reg_upsert() {  # _reg_upsert <kind> <key> <pid> <pane> <state> <cwd> <proc>
  lock || return 0
  _reg_upsert_locked "$@"
  unlock
}

_reg_remove_locked() {  # caller holds lock
  local key="${1:-}" tmp
  [ -n "$key" ] && [ -r "$REG_FILE" ] || return 0
  tmp="$(mktemp "${REG_FILE}.XXXXXX")" || return 0
  awk -F '\t' -v k="$key" 'NF >= 9 && $2 != k' "$REG_FILE" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$REG_FILE"
}

_reg_remove() {  # _reg_remove <key>
  lock || return 0
  _reg_remove_locked "$1"
  unlock
}

# Drop a dead session's marks but keep unseen "finished — your turn" notices:
# an action/notice mark for a session that can no longer take input is a lie.
_drop_session_marks() {  # _drop_session_marks <key>
  [ -n "${1:-}" ] || return 0
  lock || return 0
  _drop_rows '$4 == k && tolower($5) !~ donere' -v k="$1" -v donere="$DONE_RE"
  unlock
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
  rel="$("$PS_BIN" -axo pid=,ppid=,tty= 2>/dev/null)"
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
    *finished*|*"your turn"*|*"turn complete"*|*"task complete"*|*done*|*"任务完成"*|*"完成"*) printf '✓' ;;
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

_bar_raise() {  # remember the user's status value, then show line 2
  local cur
  cur="$(tmux show-option -gv status 2>/dev/null || echo on)"
  # Two or more lines are already sufficient and user-owned unless the marker
  # below proves radar raised them. Never reduce an existing multi-line status.
  case "$cur" in 2|[3-9]|[1-9][0-9]*) return 0 ;; esac
  tmux set -g @radar-prev-status "$cur" >/dev/null 2>&1 || true
  tmux set -g status 2 >/dev/null 2>&1 || true
}

_bar_lower() {  # restore EXACTLY what the user had; never touch what we didn't set
  local cur prev
  prev="$(tmux show-option -gqv @radar-prev-status 2>/dev/null || true)"
  [ -n "$prev" ] || return 0                     # we never raised — not ours
  cur="$(tmux show-option -gv status 2>/dev/null || echo on)"
  if [ "$cur" = "2" ]; then
    tmux set -g status "$prev" >/dev/null 2>&1 || true
  fi                                             # user changed it since: leave it
  tmux set -gu @radar-prev-status >/dev/null 2>&1 || true
}

# Recompute bar visibility. A chip is bar-visible while its mark is off-screen
# AND younger than @radar-bar-ttl seconds (0 = show until handled); the mark
# itself persists in the AI status view / pane title until actually cleared.
# @radar-bar: auto (default) toggles status 1<->2 saving/restoring the user's
# exact prior value; pinned never touches the status line COUNT (toggling it
# resizes every window and SIGWINCHes every app — users who keep `status 2`
# themselves want this; the content line self-hides); off never raises.
_sync_bar() {
  have_tmux || return 0
  local mode n=0 barttl
  mode="$(opt @radar-bar auto)"
  case "$mode" in auto|pinned|off) ;; *) mode=auto ;; esac
  barttl="$(opt @radar-bar-ttl 60)"
  if [ "$mode" = auto ] && [ -r "$STATE_FILE" ]; then
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
  case "$mode" in
    pinned) : ;;
    off)    _bar_lower ;;
    *)      if [ "${n:-0}" -gt 0 ]; then _bar_raise; else _bar_lower; fi ;;
  esac
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

  lock || return 0
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

cmd_clear_key()  { [ -n "${1:-}" ] || exit 0; lock || return 0; _drop_rows '$4 == k' -v k="$1"; unlock; _sync_bar; }
cmd_clear_pane() {
  local pane="${1:-${TMUX_PANE:-}}"
  [ -n "$pane" ] || exit 0
  lock || return 0
  _drop_rows '$1 == p' -v p="$pane"
  unlock
  _sync_bar
}

cmd_clear_window() {  # clear marks for every pane inside a window target
  local target="${1:-}"
  [ -n "$target" ] || exit 0
  have_tmux || exit 0
  local panes
  panes="$(tmux list-panes -t "$target" -F '#{pane_id}' 2>/dev/null | tr '\n' '\034')"
  [ -n "$panes" ] || { _sync_bar; return 0; }
  lock || return 0
  _drop_rows 'index(ps, "\034" $1 "\034") > 0' -v ps=$'\034'"$panes"
  unlock
  _sync_bar
}

cmd_clear_all() { lock || return 0; _drop_rows '1'; unlock; _sync_bar; }

# tick = prune + liveness GC + bar resync. Liveness, in order of authority:
#   1. registry rows: pid alive AND argv still matching the recorded proc
#      (one ps snapshot for all rows; reused pids don't count as alive)
#   2. pane agent scan (_agent_panes): fallback for marks with no registry row
# Dead registry rows are removed and their action/notice marks dropped; done
# marks stay until handled (or BG_TTL for paneless ones). If both the ps
# snapshot and the pane scan failed we only do the plain prune.
cmd_tick() {
  local snapshot verdicts dead_specs="" dead_keys="" registry_keys="" agents tmp reg_ok=""
  snapshot="$("$PS_BIN" -axo pid=,ppid=,tty=,command= 2>/dev/null || true)"
  # reg_ok = "the registry answered". Without it (ps failed, or the registry
  # was never created — pre-upgrade, hooks not installed) we must NOT infer
  # death from a missing row: absence of evidence isn't evidence of absence.
  if [ -n "$snapshot" ] && [ -r "$REG_FILE" ]; then
    reg_ok=1
    verdicts="$({ printf '__PS__\n%s\n__REG__\n' "$snapshot"; cat "$REG_FILE"; } | LC_ALL=C awk -F '\t' '
      function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
      function argmatch(argv0, name,    low, n, parts, i, c) {
        low = tolower(argv0); gsub(/\\/, "/", low)
        n = split(low, parts, "/")
        for (i = 1; i <= n; i++) { c = parts[i]; sub(/\.app$/, "", c); if (c == name) return 1 }
        return 0
      }
      $0 == "__PS__"  { mode = 1; next }
      $0 == "__REG__" { mode = 2; next }
      mode == 1 && $0 != "" {
        rest = trim($0)
        pid = rest; sub(/[[:space:]].*/, "", pid); sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
        ppid = rest; sub(/[[:space:]].*/, "", ppid); sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
        tty = rest; sub(/[[:space:]].*/, "", tty); sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
        a0 = rest; sub(/[[:space:]].*/, "", a0)
        argv[pid] = a0; next
      }
      mode == 2 && NF >= 9 {
        pid = $3 + 0
        alive = 0
        if (pid <= 0) alive = 1            # unresolved pid: GC via pane scan only
        else if ((pid in argv) && argmatch(argv[pid], tolower($9))) alive = 1
        print (alive ? "L" : "D") "\t" $0
      }')"
    dead_specs="$(printf '%s\n' "$verdicts" | awk -F '\t' '$1 == "D" { print }')"
    if [ -n "$dead_specs" ]; then
      lock || return 0
      # Revalidate the exact row identity under the lock. A SessionStart may
      # have replaced the same key after the snapshot; key-only deletion would
      # erase that newer live session and its mark.
      dead_keys="$({ printf '__DEAD__\n%s\n__REG__\n' "$dead_specs"; cat "$REG_FILE"; } |
        awk -F '\t' '
          $0 == "__DEAD__" { mode=1; next }
          $0 == "__REG__"  { mode=2; next }
          mode == 1 && $1 == "D" {
            row=$0
            sub(/^D\t/, "", row)
            dead[row]=1
            next
          }
          mode == 2 && NF >= 9 {
            if ($0 in dead) printf "%s\001", $2
          }')"
      if [ -n "$dead_keys" ]; then
        tmp="$(mktemp "${REG_FILE}.XXXXXX")" || { unlock; return 0; }
        awk -F '\t' -v dk="$(printf '\001%s' "$dead_keys")" \
          'NF >= 9 && index(dk, "\001" $2 "\001") == 0' "$REG_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$REG_FILE"
        _drop_rows 'index(dk, "\001" $4 "\001") > 0 && tolower($5) !~ donere' \
          -v dk="$(printf '\001%s' "$dead_keys")" -v donere="$DONE_RE"
      fi
      unlock
    fi
  fi
  agents="$(_agent_panes "$snapshot" || true)"
  lock || return 0
  [ -r "$REG_FILE" ] &&
    registry_keys="$(awk -F '\t' 'NF >= 9 { printf "%s\001", $2 }' "$REG_FILE" 2>/dev/null || true)"
  if [ -n "$agents" ] || [ -n "$registry_keys" ] || [ -n "$reg_ok" ]; then
    # 1) agent-source pane marks with no current registry row whose pane no longer
    #    hosts that agent (TUI closed, shell reused) — pre-registry fallback;
    # 2) paneless agent action/notice marks with no current registry row are stale
    #    (a background session that cannot take input any more). Requires
    #    regok, and only touches agent sources — a `mark - tool ...` from a
    #    user script has no registry row by design and must survive.
    _drop_rows '( $1 != "-" && ($3 == "claude" || $3 == "codex" || $3 == "opencode" || $3 == "kimi" || $3 == "ai") && index(rk, "\001" $4 "\001") == 0 && ag != "" && index(ag, "\001" $1 "\001") == 0 ) ||
      ( $1 == "-" && regok != "" && ($3 == "claude" || $3 == "codex" || $3 == "opencode" || $3 == "kimi" || $3 == "ai") && index(rk, "\001" $4 "\001") == 0 && tolower($5) !~ donere )' \
      -v rk="$(printf '\001%s' "$registry_keys")" -v ag="${agents#OK}" \
      -v donere="$DONE_RE" -v regok="$reg_ok"
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

# Like _json_field but tolerant of unquoted values (numbers: pid fields).
_json_field_any() {
  local field="$1" json="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty | tostring' 2>/dev/null || true
  else
    printf '%s' "$json" | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" | head -1
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

_claude_adopt() {  # _claude_adopt <state> <json> — registry upsert for this event
  local state="$1" json="$2" agent pid="" proc=""
  [ -n "${KEY:-}" ] || return 0
  agent="$(_resolve_agent_pid claude || true)"
  if [ -n "$agent" ]; then pid="${agent%%$'\t'*}"; proc="${agent#*$'\t'}"; fi
  _reg_upsert claude "$KEY" "${pid:-0}" "${PANE:--}" "$state" "$(_json_field cwd "$json")" "$proc"
}

cmd_claude_mark() {  # Notification hook (permission request / waiting on you)
  local json msg; json="$(cat 2>/dev/null || true)"
  msg="$(_json_field message "$json")"; [ -n "$msg" ] || msg="Claude needs input"
  _claude_target "$json"
  _claude_adopt waiting "$json"
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
  local json; json="$(cat 2>/dev/null || true)"
  _claude_target "$json"
  _claude_adopt "done" "$json"
  local msg="Claude finished — your turn"
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
  local json; json="$(cat 2>/dev/null || true)"
  _claude_target "$json"
  _claude_adopt working "$json"
  if [ "$PANE" != "-" ] && [ -n "$PANE" ]; then
    _watch_event "$PANE" user_resumed claude 'Claude resumed by user'
  fi
  if [ -n "$KEY" ] && [ "${KEY#s:}" != "$KEY" ]; then cmd_clear_key "$KEY"
  elif [ "$PANE" != "-" ] && [ -n "$PANE" ]; then cmd_clear_pane "$PANE"
  fi
}

cmd_claude_register() {  # SessionStart hook: adopt the session, drop stale asks
  local json; json="$(cat 2>/dev/null || true)"
  _claude_target "$json"
  [ -n "${KEY:-}" ] || exit 0
  _claude_adopt working "$json"
  # a session that just (re)started cannot be waiting on you yet; an unseen
  # "finished — your turn" from its previous life is still worth showing
  _drop_session_marks "$KEY"
  _sync_bar
}

cmd_claude_end() {  # SessionEnd hook: the native, instant "session is gone"
  local json sid key
  json="$(cat 2>/dev/null || true)"
  sid="$(_json_field session_id "$json")"
  [ -n "$sid" ] || exit 0
  key="s:${sid}"
  _reg_remove "$key"
  _drop_session_marks "$key"
  _sync_bar
}

_codex_pane() {
  local pane
  pane="${TMUX_PANE:-}"
  [ -n "$pane" ] || pane="$(_resolve_pane_by_proc || true)"
  printf '%s' "$pane"
}

CODEX_KEY=""
_codex_adopt() {  # _codex_adopt <state> <json> <pane> — sets CODEX_KEY
  local state="$1" json="$2" pane="${3:--}" sid key agent pid="" proc=""
  CODEX_KEY=""
  agent="$(_resolve_agent_pid codex || true)"
  if [ -n "$agent" ]; then pid="${agent%%$'\t'*}"; proc="${agent#*$'\t'}"; fi
  # notify payloads carry thread-id / thread_id; hook payloads may not — fall
  # back to a pid key so liveness GC still applies
  sid="$(_json_field thread-id "$json")"
  [ -n "$sid" ] || sid="$(_json_field thread_id "$json")"
  [ -n "$sid" ] || sid="$(_json_field session_id "$json")"
  if [ -n "$sid" ]; then key="s:${sid}"
  elif [ -n "$pid" ]; then key="p:${pid}"
  else return 0; fi
  if [ -n "$sid" ] && [ -n "$pid" ]; then
    _reg_remove "p:${pid}"
  fi
  _reg_upsert codex "$key" "${pid:-0}" "$pane" "$state" "$(_json_field cwd "$json")" "$proc"
  CODEX_KEY="$key"
}

_codex_event_kind() {
  case "$1" in
    PermissionRequest|exec_approval_request|apply_patch_approval_request|request_permissions) printf 'approval' ;;
    Stop|task_complete|agent-turn-complete|turn_complete|turn-complete) printf 'turn_complete' ;;
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
      _codex_adopt working "$json" "$pane"
      if [ -n "$pane" ]; then
        label="$(_codex_label "$event" "$json")"
        _watch_event "$pane" user_resumed codex "$label"
        [ -n "$CODEX_KEY" ] && cmd_clear_key "$CODEX_KEY"
        cmd_clear_pane "$pane"  # also clears pre-registry pane-keyed marks
      fi
      ;;
    *)
      [ -n "$pane" ] || exit 0
      kind="$(_codex_event_kind "$event")" || exit 0
      label="$(_codex_label "$event" "$json")"
      if [ "$kind" = "turn_complete" ]; then _codex_adopt "done" "$json" "$pane"
      else _codex_adopt waiting "$json" "$pane"; fi
      _watch_event "$pane" "$kind" codex "$label"
      [ "$(opt @radar-needinput on)" = "on" ] || exit 0
      cmd_mark "$pane" codex "$label" "$CODEX_KEY"
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
      _codex_adopt working "$json" "$pane"
      if [ -n "$pane" ]; then
        label="$(_codex_label "$type" "$json")"
        _watch_event "$pane" user_resumed codex "$label"
        [ -n "$CODEX_KEY" ] && cmd_clear_key "$CODEX_KEY"
        cmd_clear_pane "$pane"  # also clears pre-registry pane-keyed marks
      fi
      ;;
    *)
      [ -n "$pane" ] || exit 0
      kind="$(_codex_event_kind "$type")" || exit 0
      label="$(_codex_label "$type" "$json")"
      if [ "$kind" = "turn_complete" ]; then _codex_adopt "done" "$json" "$pane"
      else _codex_adopt waiting "$json" "$pane"; fi
      _watch_event "$pane" "$kind" codex "$label"
      [ "$(opt @radar-needinput on)" = "on" ] || exit 0
      cmd_mark "$pane" codex "$label" "$CODEX_KEY"
      ;;
  esac
}

# OpenCode watermarks are tombstones as well as ordering metadata:
#   key<TAB>generation<TAB>generation_started_ms<TAB>sequence<TAB>updated_epoch
# A newer plugin generation supersedes an older one for the same session. The
# row remains after end so a delayed event from the old process cannot resurrect
# a deleted/replaced session.
_opencode_accept_locked() {  # <key> <generation> <started-ms> <sequence>
  local key="$1" generation="$2" generation_started="$3" sequence="$4"
  local old old_generation old_started old_sequence now tmp
  generation="$(_san "$generation")"
  case "$generation_started" in ''|*[!0-9]*) generation_started=0 ;; esac
  case "$sequence" in ''|*[!0-9]*) sequence=0 ;; esac
  old="$(awk -F '\t' -v k="$key" 'NF >= 5 && $1 == k { print; exit }' "$OC_EVENTS_FILE" 2>/dev/null || true)"
  if [ -n "$old" ]; then
    old_generation="$(printf '%s' "$old" | cut -f2)"
    old_started="$(printf '%s' "$old" | cut -f3)"
    old_sequence="$(printf '%s' "$old" | cut -f4)"
  else
    old_generation=""; old_started=0; old_sequence=0
  fi

  # Legacy one-shot events carry no ordering fields. Accept them only when they
  # are not attempting to overwrite a generation-aware row.
  if [ -z "$generation" ]; then
    case "$old_generation" in ""|legacy) ;; *) return 1 ;; esac
    generation="legacy"
    generation_started=0
    sequence=$((old_sequence + 1))
  elif [ "$generation" = "$old_generation" ]; then
    [ "$sequence" -gt "$old_sequence" ] || return 1
  elif [ -n "$old_generation" ]; then
    [ "$generation_started" -gt "$old_started" ] || return 1
  fi

  now="$(date +%s)"
  tmp="$(mktemp "${OC_EVENTS_FILE}.XXXXXX")" || return 2
  { [ -r "$OC_EVENTS_FILE" ] &&
      awk -F '\t' -v k="$key" -v now="$now" -v ttl="$BG_TTL" \
        'NF >= 5 && $1 != k && now - $5 <= ttl' "$OC_EVENTS_FILE"; :; } > "$tmp" 2>/dev/null
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(_san "$key")" "$generation" "$generation_started" "$sequence" "$now" >> "$tmp"
  mv "$tmp" "$OC_EVENTS_FILE"
}

_session_mark_locked() {  # <pane|-> <source> <label> <key>
  local pane="$1" source="$2" label key="$4" now saved_title="" prev_title=""
  label="$(_san "$3")"
  now="$(date +%s)"
  if [ "$pane" != "-" ] && [ -n "$pane" ] && [ "$(opt @radar-retitle on)" != "off" ]; then
    saved_title="$(_san "$(tmux display-message -p -t "$pane" '#{pane_title}' 2>/dev/null || true)")"
    case "$saved_title" in "⚠ "*|"✓ "*|"! "*|"· "*) saved_title="" ;; esac
  fi
  prev_title="$(awk -F '\t' -v k="$key" -v p="$pane" \
    'NF >= 6 && ($4 == k || $1 == p) && $6 != "" { print $6; exit }' "$STATE_FILE" 2>/dev/null || true)"
  [ -n "$prev_title" ] && saved_title="$prev_title"
  # Agent hosts may run several sessions in one pane. Replace only this
  # session, unlike the public pane mark API which intentionally keeps one row
  # per pane.
  _rewrite 'if (key == delkey) next' -v delkey="$key"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$pane" "$now" "$source" "$key" "$label" "$saved_title" >> "$STATE_FILE"
}

_opencode_mark_locked() {  # <pane|-> <label> <key>
  _session_mark_locked "$1" opencode "$2" "$3"
}

_opencode_event() {  # _opencode_event <one JSON object>
  local json="$1" event sid key pane pid cwd msg where label
  local generation generation_started sequence watch_kind=""
  event="$(_json_field event "$json")"
  [ -n "$event" ] || return 0
  sid="$(_json_field session_id "$json")"
  pane="$(_json_field pane "$json")"
  pid="$(_json_field_any pid "$json")"; case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  cwd="$(_json_field cwd "$json")"
  msg="$(_json_field message "$json")"
  generation="$(_json_field generation "$json")"
  generation_started="$(_json_field_any generation_started "$json")"
  sequence="$(_json_field_any sequence "$json")"
  [ -n "$pane" ] || pane="$(_resolve_pane_by_proc || true)"
  if [ -n "$sid" ]; then key="oc:s:$(_san "$sid")"
  elif [ -n "$generation" ]; then key="oc:g:$(_san "$generation")"
  elif [ "$pid" -gt 0 ]; then key="oc:p:$pid"
  else return 0; fi
  where=""; [ -n "$cwd" ] && where="$(basename "$cwd")"

  lock || return 0
  if ! _opencode_accept_locked "$key" "$generation" "$generation_started" "$sequence"; then
    unlock
    return 0
  fi
  case "$event" in
    start)
      _reg_upsert_locked opencode "$key" "$pid" "${pane:--}" working "$cwd" opencode
      ;;
    user)
      _reg_upsert_locked opencode "$key" "$pid" "${pane:--}" working "$cwd" opencode
      _drop_rows '$4 == k' -v k="$key"
      watch_kind=user_resumed
      ;;
    permission|input)
      _reg_upsert_locked opencode "$key" "$pid" "${pane:--}" waiting "$cwd" opencode
      if [ "$(opt @radar-needinput on)" = "on" ]; then
        if [ "$event" = "input" ]; then
          label="opencode needs your input${msg:+: $msg}"
          watch_kind=input_required
        else
          label="opencode needs approval${msg:+: $msg}"
          watch_kind=approval
        fi
        [ -n "$pane" ] || label="opencode·${where:-bg}: ${label#opencode }"
        _opencode_mark_locked "${pane:--}" "$label" "$key"
      fi
      ;;
    idle)
      _reg_upsert_locked opencode "$key" "$pid" "${pane:--}" "done" "$cwd" opencode
      if [ "$(opt @radar-needinput on)" = "on" ]; then
        label="opencode finished — your turn"
        [ -n "$pane" ] || label="opencode·${where:-bg}: finished — your turn"
        _opencode_mark_locked "${pane:--}" "$label" "$key"
        watch_kind=turn_complete
      fi
      ;;
    error)
      if [ "$(opt @radar-needinput on)" = "on" ]; then
        label="opencode: ${msg:-error}"
        [ -n "$pane" ] || label="opencode·${where:-bg}: ${msg:-error}"
        _opencode_mark_locked "${pane:--}" "$label" "$key"
      fi
      ;;
    end)
      _reg_remove_locked "$key"
      _drop_rows '$4 == k && tolower($5) !~ donere' -v k="$key" -v donere="$DONE_RE"
      ;;
  esac
  unlock
  [ -n "$watch_kind" ] && [ -n "$pane" ] &&
    _watch_event "$pane" "$watch_kind" opencode "${label:-opencode resumed}"
  _refresh_titles
  _sync_bar
}

cmd_opencode_hook() {
  local json
  json="$(cat 2>/dev/null || true)"
  _opencode_event "$json"
}

# One blocking reader per OpenCode TUI. It sleeps in read(2), creates no polling
# processes, and exits on pipe EOF. Acknowledgements make the JS side apply
# backpressure and prove each event finished before the next begins.
cmd_opencode_stream() {
  local json generation sequence
  while IFS= read -r json; do
    _opencode_event "$json"
    generation="$(_json_field generation "$json")"
    sequence="$(_json_field_any sequence "$json")"
    printf 'ok\t%s\t%s\n' "$generation" "$sequence"
  done
}

_agent_json_object() {  # read exactly one JSON object from stdin
  local raw
  command -v jq >/dev/null 2>&1 || {
    echo "agent event requires jq" >&2
    return 2
  }
  raw="$(cat 2>/dev/null || true)"
  printf '%s' "$raw" | jq -ce '
    if type == "object" then . else error("expected one JSON object") end
  ' 2>/dev/null || {
    echo "agent event: expected one JSON object" >&2
    return 2
  }
}

_agent_kind_valid() {
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*|[._-]*) return 1 ;;
    *) [ "${#1}" -le 64 ] ;;
  esac
}

_agent_event_valid() {
  case "${1:-}" in
    session_start|approval|approval_resolved|input_required|user_resumed|turn_complete|interrupt|session_end) return 0 ;;
    *) return 1 ;;
  esac
}

_agent_payload_valid() {
  local json="$1"
  printf '%s' "$json" | jq -e '
    def clean_string:
      type == "string" and (explode | all(. >= 32 and . != 127));
    (.session_id | clean_string and length > 0 and length <= 200) and
    ((.cwd // "") | clean_string) and
    ((.label // "") | clean_string) and
    ((.process // "") | clean_string and length <= 200) and
    ((has("pane") | not) or
      (.pane | type == "string" and (. == "" or test("^%[0-9]+$")))) and
    ((has("pid") | not) or
      (.pid | type == "number" and floor == . and . >= 0))
  ' >/dev/null 2>&1
}

_agent_display_name() {
  case "$1" in
    kimi) printf 'Kimi' ;;
    codex) printf 'Codex' ;;
    claude) printf 'Claude' ;;
    opencode) printf 'OpenCode' ;;
    *) printf '%s' "$1" ;;
  esac
}

_agent_event_apply() {  # <agent-kind> <normalized-event> <one JSON object>
  local kind="$1" event="$2" json="$3" sid key pane pid cwd proc detail
  local agent display label="" watch_kind="" state=working
  _agent_kind_valid "$kind" || {
    echo "agent-event: invalid agent kind" >&2
    return 2
  }
  _agent_event_valid "$event" || {
    echo "agent-event: unsupported event: $event" >&2
    return 2
  }
  _agent_payload_valid "$json" || {
    echo "agent-event: invalid payload" >&2
    return 2
  }

  sid="$(_json_field session_id "$json")"
  key="s:${sid}"
  pane="$(_json_field pane "$json")"
  [ -n "$pane" ] || pane="${TMUX_PANE:-}"
  [ -n "$pane" ] || pane="$(_resolve_pane_by_proc || true)"
  [ -n "$pane" ] || pane="-"
  pid="$(_json_field_any pid "$json")"
  proc="$(_json_field process "$json")"
  if [ -z "$pid" ] || [ "$pid" = 0 ]; then
    agent="$(_resolve_agent_pid "$kind" || true)"
    if [ -n "$agent" ]; then
      pid="${agent%%$'\t'*}"
      [ -n "$proc" ] || proc="${agent#*$'\t'}"
    fi
  fi
  case "$pid" in ''|*[!0-9]*) pid=0 ;; esac
  [ -n "$proc" ] || proc="$kind"
  cwd="$(_json_field cwd "$json")"
  detail="$(_json_field label "$json")"
  display="$(_agent_display_name "$kind")"

  lock || return 0
  case "$event" in
    session_start)
      _reg_upsert_locked "$kind" "$key" "$pid" "$pane" working "$cwd" "$proc"
      _drop_rows '$4 == k && tolower($5) !~ donere' -v k="$key" -v donere="$DONE_RE"
      ;;
    approval)
      _reg_upsert_locked "$kind" "$key" "$pid" "$pane" waiting "$cwd" "$proc"
      label="$display needs approval${detail:+: $detail}"
      [ "$(opt @radar-needinput on)" = "on" ] &&
        _session_mark_locked "$pane" "$kind" "$label" "$key"
      watch_kind=approval
      ;;
    input_required)
      _reg_upsert_locked "$kind" "$key" "$pid" "$pane" waiting "$cwd" "$proc"
      label="$display needs your input${detail:+: $detail}"
      [ "$(opt @radar-needinput on)" = "on" ] &&
        _session_mark_locked "$pane" "$kind" "$label" "$key"
      watch_kind=input_required
      ;;
    approval_resolved|user_resumed|interrupt)
      _reg_upsert_locked "$kind" "$key" "$pid" "$pane" working "$cwd" "$proc"
      _drop_rows '$4 == k' -v k="$key"
      case "$event" in
        approval_resolved) label="$display approval resolved" ;;
        interrupt) label="$display interrupted by user" ;;
        *) label="$display resumed by user" ;;
      esac
      watch_kind=user_resumed
      ;;
    turn_complete)
      _reg_upsert_locked "$kind" "$key" "$pid" "$pane" done "$cwd" "$proc"
      label="$display finished - your turn${detail:+: $detail}"
      [ "$(opt @radar-needinput on)" = "on" ] &&
        _session_mark_locked "$pane" "$kind" "$label" "$key"
      watch_kind=turn_complete
      ;;
    session_end)
      _reg_remove_locked "$key"
      _drop_rows '$4 == k && tolower($5) !~ donere' -v k="$key" -v donere="$DONE_RE"
      ;;
  esac
  unlock

  [ -n "$watch_kind" ] && [ "$pane" != "-" ] &&
    _watch_event "$pane" "$watch_kind" "$kind" "$label"
  _refresh_titles
  _sync_bar
}

cmd_agent_event() {  # agent-event <agent-kind> <normalized-event>
  local kind="${1:-}" event="${2:-}" json
  json="$(_agent_json_object)" || return 2
  _agent_event_apply "$kind" "$event" "$json"
}

cmd_kimi_hook() {
  local json event normalized
  json="$(_agent_json_object)" || return 2
  event="$(_json_field hook_event_name "$json")"
  case "$event" in
    SessionStart) normalized=session_start ;;
    PermissionRequest) normalized=approval ;;
    PermissionResult) normalized=approval_resolved ;;
    UserPromptSubmit) normalized=user_resumed ;;
    Stop) normalized=turn_complete ;;
    Interrupt) normalized=interrupt ;;
    SessionEnd) normalized=session_end ;;
    *)
      echo "kimi-hook: unsupported event: ${event:-<missing>}" >&2
      return 2
      ;;
  esac
  _agent_event_apply kimi "$normalized" "$json"
}

# Public API for any other agent that wants radar tracking: register with a
# stable key + its own pid, end when it exits. Liveness GC does the rest.
cmd_agent_register() {  # agent-register <kind> <key> <pid> <pane> [cwd]
  local kind="${1:-}" key="${2:-}" pid="${3:-0}" pane="${4:--}" cwd="${5:-}"
  [ -n "$kind" ] && [ -n "$key" ] || { echo "usage: agent-register <kind> <key> <pid> <pane> [cwd]" >&2; exit 2; }
  _reg_upsert "$kind" "$key" "$pid" "$pane" working "$cwd" "$kind"
}

cmd_agent_end() {  # agent-end <kind> <key>
  local key="${2:-}"
  [ -n "$key" ] || { echo "usage: agent-end <kind> <key>" >&2; exit 2; }
  _reg_remove "$key"
  _drop_session_marks "$key"
  _sync_bar
}

cmd_registry() {  # debug: registry rows + per-row liveness verdicts
  if [ ! -r "$REG_FILE" ] || [ ! -s "$REG_FILE" ]; then
    echo "registry: empty ($REG_FILE)"; return 0
  fi
  local kind key pid pane started state cwd proc verdict now age
  now="$(date +%s)"
  printf '%-9s %-40s %-8s %-8s %-6s %s\n' KIND KEY PANE STATE AGE LIVENESS
  while IFS=$'\t' read -r kind key pid pane started _ state cwd proc; do
    [ -n "$kind" ] || continue
    if [ "${pid:-0}" -gt 0 ] 2>/dev/null; then
      if ! kill -0 "$pid" 2>/dev/null; then verdict="dead: pid $pid gone → GC next tick"
      elif "$PS_BIN" -p "$pid" -o command= 2>/dev/null | head -1 | grep -Fqi "$proc"; then verdict="alive: pid $pid ($proc)"
      else verdict="dead: pid $pid reused (argv is no longer $proc) → GC next tick"; fi
    else
      verdict="pid unresolved → liveness via pane scan only"
    fi
    age=$(( now - ${started:-now} )); [ "$age" -lt 0 ] && age=0
    printf '%-9s %-40s %-8s %-8s %-6s %s\n' "$kind" "$key" "$pane" "$state" "${age}s" "$verdict"
  done < "$REG_FILE"
}

cmd_doctor() {  # one-stop "why is this row (not) showing?"
  local o v now agents
  now="$(date +%s)"
  echo "tmux-radar doctor"
  echo "================="
  printf '%-11s %s\n' 'state dir' "$STATE_DIR"
  printf '%-11s %s\n' 'marks' "$STATE_FILE"
  printf '%-11s %s\n' 'registry' "$REG_FILE"
  have_tmux && printf '%-11s reachable\n' 'tmux' || printf '%-11s NOT reachable (marks/bar inert)\n' 'tmux'
  echo
  echo "-- options in effect --"
  for o in @radar-needinput @radar-needinput-commands @radar-bar @radar-bar-ttl \
           @radar-retitle @radar-claude-bg @radar-claude-bg-ignore; do
    v="$(opt "$o" '(default)')"
    printf '  %-26s %s\n' "$o" "$v"
  done
  echo
  echo "-- agent registry --"
  cmd_registry | sed 's/^/  /'
  echo
  echo "-- marks --"
  if [ -r "$STATE_FILE" ] && [ -s "$STATE_FILE" ]; then
    local pane epoch src key label _title why lvl
    while IFS=$'\t' read -r pane epoch src key label _title; do
      [ -n "$pane" ] || continue
      lvl=notice
      case "$(printf '%s %s' "$src" "$label" | tr '[:upper:]' '[:lower:]')" in
        *finished*|*'your turn'*|*'turn complete'*|*'task complete'*|*done*|*任务完成*|*完成*) lvl="done" ;;
        *permission*|*approval*|*approve*|*'needs input'*|*waiting*|*'action required'*|*需要你*|*等待*) lvl=action ;;
      esac
      why="no liveness source — GC candidate"
      if [ -r "$REG_FILE" ] && awk -F '\t' -v k="$key" 'NF >= 9 && $2 == k { found=1 } END { exit !found }' "$REG_FILE" 2>/dev/null; then
        why="registry row exists (see verdict above)"
      elif [ "$lvl" = "done" ]; then
        why="done-level: kept until handled${pane:+ / pane dies}"
      fi
      printf '  %-8s %-7s %-9s %-40s %ss old · %s\n    %s\n' "$pane" "$lvl" "$src" "$key" "$(( now - ${epoch:-now} ))" "$why" "$label"
    done < "$STATE_FILE"
  else
    echo "  (none)"
  fi
  echo
  echo "-- agent panes (process scan) --"
  agents="$(_agent_panes | tr '\001' '\n' || true)"
  if [ -z "$agents" ]; then echo "  scan failed (ps/tmux unavailable)"
  else printf '%s\n' "$agents" | sed '1d;/^$/d' | sed 's/^/  /'
       printf '%s\n' "$agents" | sed '1d;/^$/d' | grep -q . || echo "  (none detected)"
  fi
  if [ -x "$SCRIPT_DIR/install-hooks.sh" ]; then
    echo
    echo "-- hooks --"
    "$SCRIPT_DIR/install-hooks.sh" status 2>/dev/null | sed 's/^/  /' || echo "  (status unavailable)"
  fi
}

case "${1:-}" in
  mark)          shift; cmd_mark "${1:-}" "${2:-tool}" "${3:-needs input}" "${4:-}" ;;
  clear)         shift; cmd_clear_pane "${1:-}" ;;
  clear-key)     shift; cmd_clear_key "${1:-}" ;;
  clear-window)  shift; cmd_clear_window "${1:-}" ;;
  clear-all)     cmd_clear_all ;;
  tick)          cmd_tick ;;
  claude-mark)     cmd_claude_mark ;;
  claude-stop)     cmd_claude_stop ;;
  claude-clear)    cmd_claude_clear ;;
  claude-register) cmd_claude_register ;;
  claude-end)      cmd_claude_end ;;
  codex-hook)      cmd_codex_hook ;;
  codex)           shift; cmd_codex "${1:-}" ;;
  opencode-hook)   cmd_opencode_hook ;;
  opencode-stream) cmd_opencode_stream ;;
  kimi-hook)       cmd_kimi_hook ;;
  agent-event)     shift; cmd_agent_event "${1:-}" "${2:-}" ;;
  agent-register)  shift; cmd_agent_register "${1:-}" "${2:-}" "${3:-0}" "${4:--}" "${5:-}" ;;
  agent-end)       shift; cmd_agent_end "${1:-}" "${2:-}" ;;
  registry)        cmd_registry ;;                   # debug: registry + liveness verdicts
  doctor)          cmd_doctor ;;                     # debug: full "why is this row here?"
  agent-panes)     _agent_panes | tr '\001' '\n' ;;  # debug: which panes host an agent
  resolve-pane)    _resolve_pane_by_proc ;;          # debug: pane of this process tree
  resolve-cwd)     shift; _resolve_pane_by_cwd "${1:-$PWD}" ;;  # debug: pane owning a cwd
  *) echo "usage: needinput-notify.sh {mark|clear|clear-key <k>|clear-window <t>|clear-all|tick|claude-mark|claude-stop|claude-clear|claude-register|claude-end|codex-hook|codex <json>|opencode-hook|opencode-stream|kimi-hook|agent-event <kind> <event>|agent-register <kind> <key> <pid> <pane> [cwd]|agent-end <kind> <key>|registry|doctor|agent-panes|resolve-pane|resolve-cwd [cwd]}" >&2; exit 2 ;;
esac

#!/usr/bin/env bash
# tmux-radar — pane-first picker with Recent / Attention / Tree scopes and a
# live bottom-anchored preview.
#
# Subcommands (the script calls itself for fzf reload/preview/binds):
#   menu (default)                  launch the fzf popup
#   list [view]                     print TAB rows "%pane-id\t<name>\t<meta>"
#   preview <target>                render the right-hand preview for one row
#   set-view <view>                 (fzf transform) switch view, emit actions
#
# View state is shared with the fzf bind subprocesses via $SW_STATE. fzf hides
# the target field, searches the two display fields, and returns the full row.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/switcher.sh"

STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
PANE_MRU_FILE="${TMUX_RADAR_PANE_MRU_FILE:-$STATE_DIR/pane-mru}"
NEEDINPUT_FILE="${TMUX_RADAR_NEEDINPUT_FILE:-${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}}"
# agent-session registry written by needinput-notify.sh hooks (TSV, 9 fields:
# kind key pid pane started last_event state cwd proc); readers need no lock
REGISTRY_FILE="${TMUX_RADAR_REGISTRY_FILE:-$STATE_DIR/agent-registry}"
MRU_RECORD="$SCRIPT_DIR/mru-record.sh"

mkdir -p "$STATE_DIR" 2>/dev/null || true

opt() {  # opt <option> <default>
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

# ANSI (tmux -F / printf emit literally; fzf --ansi renders)
C=$'\033[1;36m'; Y=$'\033[33m'; G=$'\033[1;32m'; M=$'\033[1;35m'; D=$'\033[2m'; R=$'\033[0m'
SEP=$'\037'

short_path() {  # short_path <path> -> compact display path
  local p="${1:-}" home_prefix
  home_prefix="${HOME%/}/"
  case "$p" in
    "$HOME") printf '~' ;;
    "$home_prefix"*) printf '%s/%s' '~' "${p#"$home_prefix"}" ;;
    *) printf '%s' "$p" ;;
  esac
}

needinput_commands() {  # newline-separated process names watched by AI status
  local configured
  configured="${TMUX_RADAR_NEEDINPUT_COMMANDS:-${TMUX_SWITCHER_NEEDINPUT_COMMANDS:-$(opt @radar-needinput-commands 'codex claude opencode kimi')}}"
  printf '%s\n' "$configured" | tr ',:' '  '
}

# ---- shared view state ------------------------------------------------------
normalize_view() {
  case "${1:-}" in
    all|tree) printf tree ;;
    attention|needinput) printf attention ;;
    recent) printf recent ;;
    *) printf recent ;;
  esac
}

VIEW=recent
read_state() {  # read_state [view-override]
  VIEW=recent
  if [ -n "${SW_STATE:-}" ] && [ -r "${SW_STATE:-/nonexistent}" ]; then
    IFS= read -r VIEW < "$SW_STATE" 2>/dev/null || true
  fi
  [ -n "${1:-}" ] && VIEW="$1"
  VIEW="$(normalize_view "$VIEW")"
}
write_state() { [ -n "${SW_STATE:-}" ] && printf '%s\n' "$VIEW" > "$SW_STATE"; }

# ---- row builders ----------------------------------------------------------
# Each public row is exactly "<target>\t<search-display>\t<meta-display>".
# live_pane_snapshot is the one canonical server snapshot used to build pane
# rows and the fully expanded Tree. User-derived fields are flattened before
# tabs are introduced.
live_pane_snapshot() {
  local raw
  raw="$(tmux list-panes -a -F \
    "#{pane_id}${SEP}#{session_name}${SEP}#{window_id}${SEP}#{window_index}${SEP}#{pane_index}${SEP}#{window_name}${SEP}#{pane_title}${SEP}#{pane_current_command}${SEP}#{pane_current_path}" 2>/dev/null)" || return 1
  printf '%s\n' "$raw" |
    LC_ALL=C awk -v FS="$SEP" -v OFS='\t' -v home="$HOME" '
      function clean(s) {
        gsub(/[[:cntrl:]]/, " ", s)
        gsub(/[[:space:]][[:space:]]+/, " ", s)
        sub(/^ /, "", s); sub(/ $/, "", s)
        return s
      }
      function spath(p) {
        if (p == home) return "~"
        if (index(p, home "/") == 1) return "~" substr(p, length(home) + 1)
        return p
      }
      {
        id=$1; session=clean($2); wid=$3; widx=clean($4); pidx=clean($5)
        window=clean($6); title=clean($7); cmd=clean($8); path=spath(clean($9))
        if (title == "") title=cmd
        print id, session, wid, widx, pidx, window, title, cmd, path
      }
    '
}

pane_rows() {
  LC_ALL=C awk -F '\t' -v OFS='\t' '
    { location=$2 ":" $4 "." $5; print $1, $6 " " location "/" $7, $9 " · " $8 }
  '
}

live_pane_records() {
  live_pane_snapshot | pane_rows
}

list_tree() {
  live_pane_snapshot | LC_ALL=C awk -F '\t' -v OFS='\t' '
    {
      location=$2 ":" $4 "." $5
      if ($2 != last_session) {
        print "@session:" $2, $2, "session"
        last_session=$2; last_window=""
      }
      if ($3 != last_window) {
        print "@window:" $3, "  " $6 " " $2 ":" $4, "window"
        last_window=$3
      }
      print $1, $6 " " location "/" $7, $9 " · " $8
    }
  '
}

list_recent() {
  local mfile="$PANE_MRU_FILE" live
  [ -r "$mfile" ] || mfile=/dev/null
  live="$(live_pane_records)" || return 1
  awk -F '\t' '
    NR==FNR { row[$1]=$0; next }
    { recent[++n]=$1 }
    END {
      for (i=n; i>=1; i--) { id=recent[i]; if ((id in row) && !seen[id]++) print row[id] }
    }
  ' <(printf '%s\n' "$live") "$mfile"
}

list_attention() {  # pane-level AI-status process view; hook-marked panes float first
  local live live_raw flags ps_rows commands reg now
  live_raw="$(tmux list-panes -a -F \
    "#{pane_id}${SEP}#{session_name}:#{window_index}${SEP}#{pane_index}${SEP}#{window_name}${SEP}#{pane_title}${SEP}#{pane_current_command}${SEP}#{pane_current_path}${SEP}#{pane_pid}${SEP}#{pane_tty}" 2>/dev/null)" || return 1
  live="$(printf '%s\n' "$live_raw" | LC_ALL=C awk -v FS="$SEP" -v OFS='\t' '
      function clean(s) { gsub(/[[:cntrl:]]/, " ", s); gsub(/[[:space:]][[:space:]]+/, " ", s); return s }
      { for (i=1; i<=NF; i++) $i=clean($i); print }
    ')"
  [ -n "$live" ] || return 0
  flags=""; [ -r "$NEEDINPUT_FILE" ] && flags="$(cat "$NEEDINPUT_FILE" 2>/dev/null || true)"
  reg=""; [ -r "$REGISTRY_FILE" ] && reg="$(cat "$REGISTRY_FILE" 2>/dev/null || true)"
  ps_rows="$(ps -axo pid=,ppid=,tty=,command= 2>/dev/null || true)"
  commands="$(needinput_commands)"
  now="$(date +%s)"

  # __REG__ must come after __PS__: registry liveness checks the ps snapshot
  { printf '__PANES__\n%s\n__FLAGS__\n%s\n__PS__\n%s\n__REG__\n%s\n' "$live" "$flags" "$ps_rows" "$reg"; } |
    LC_ALL=C awk -F '\t' -v cmds="$commands" -v now="$now" -v C="$C" -v Y="$Y" -v G="$G" -v M="$M" -v D="$D" -v R="$R" '
      function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
      function clean_user(s) { gsub(/[[:cntrl:]]/, " ", s); gsub(/[[:space:]][[:space:]]+/, " ", s); return trim(s) }
      function clean_tty(t) { sub(/^\/dev\//, "", t); return t }
      function first_word(s, x) { x=trim(s); sub(/[[:space:]].*/, "", x); return x }
      function level_for(src, label,    l) {
        l=tolower(src " " label)
        if (l ~ /(finished|your turn|turn complete|task complete|done|任务完成|完成)/) return "done"
        if (l ~ /(needs approval|needs your permission|needs input|waiting.*input|waiting on you|wait.*input|permission|approval|action required|approve|拿不准|需要你|需要.*许可|需要.*批准|等待.*输入)/) return "action"
        return "notice"
      }
      function level_rank(level) { return (level == "action" ? 1 : (level == "done" ? 2 : (level == "notice" ? 3 : 4))) }
      function level_color(level) { return (level == "action" ? M : (level == "done" ? G : (level == "notice" ? Y : D))) }
      function level_word(level) { return (level == "action" ? "ACTION" : (level == "done" ? "DONE" : (level == "notice" ? "NOTICE" : "ACTIVE"))) }
      function level_icon(level) { return (level == "action" ? "⚠" : (level == "done" ? "✓" : (level == "notice" ? "!" : "·"))) }
      function badge(level) { return level_color(level) level_icon(level) " " level_word(level) " " R }
      function age_str(sec) {
        sec += 0
        if (sec < 0) sec = 0
        if (sec < 60) return sec "s"
        if (sec < 3600) return int(sec / 60) "m"
        if (sec < 86400) return int(sec / 3600) "h"
        return int(sec / 86400) "d"
      }
      function proc_match(argv0, raw, n, a, i, c, wanted) {
        raw=tolower(argv0); gsub(/\\/, "/", raw)
        n=split(raw, a, "/")
        for (wanted in want) {
          for (i=1; i<=n; i++) {
            c=a[i]
            sub(/\.app$/, "", c)
            if (c == wanted) return want[wanted]
          }
        }
        return ""
      }
      function proc_identity_match(argv0, wanted,    raw, n, a, i, c) {
        raw=tolower(argv0); wanted=tolower(wanted)
        gsub(/\\/, "/", raw)
        if (wanted == "") return 0
        n=split(raw, a, "/")
        for (i=1; i<=n; i++) {
          c=a[i]
          sub(/\.app$/, "", c)
          if (c == wanted) return 1
        }
        return 0
      }
      function add_match(pane, cmd) {
        if (pane == "" || cmd == "") return
        if (!(pane in ai)) ai[pane]=1
        ai_cmd[pane SUBSEP cmd]=1
        # registry kinds outside the watch list must still show in cmds_for
        if (!(cmd in cmd_known)) { cmd_known[cmd]=1; cmd_order[++cmd_n]=cmd }
      }
      function add_process_match(pane, cmd) {
        add_match(pane, cmd)
        if (pane != "" && cmd != "") process_ai[pane]=1
      }
      function emit_pane(pane, level,    is_flagged, display_title, title, matched, hint, tail) {
        is_flagged=(pane in flagged)
        if (level == "") level=(is_flagged ? flag_level[pane] : "active")
        display_title=ti[pane]
        if (is_flagged) {
          if (flag_saved[pane] != "") display_title=flag_saved[pane]
          else {
            sub(/^⚠ /, "", display_title)
            sub(/^✓ /, "", display_title)
            sub(/^! /, "", display_title)
            sub(/^· /, "", display_title)
          }
        } else {
          if (display_title ~ /^(⚠|✓|!|·) /) display_title=""
        }
        title=(display_title != "" && display_title != wn[pane] ? "/" display_title : "")
        matched=cmds_for(pane)
        hint=""
        if (is_flagged) {
          hint=flag_label[pane]
          if (flag_source[pane] != "") hint=flag_source[pane] ": " hint
          if (hint != "") hint=" · " level_color(level) level_word(level) ": " hint R
        }
        # trailing dim age: mark age when flagged, registry kind/state/uptime otherwise
        tail=""
        if (is_flagged) {
          if (flag_epoch[pane] > 0) tail=" " D "· " age_str(now - flag_epoch[pane]) R
        } else if (pane in reg_state) {
          tail=" " D "· " reg_kind[pane] " " reg_state[pane] " · " age_str(now - reg_started[pane]) R
        }
        printf "%s\t%s %s%s.%s%s%s\t%s%s%s · %s · %s%s%s\n", \
          pane_target[pane], wn[pane], C, wt[pane], pidx[pane], title, R, \
          badge(level), D, matched, cm[pane], pa[pane], R, hint tail
      }
      function cmds_for(pane,    i, out, cmd) {
        out=""
        for (i=1; i<=cmd_n; i++) {
          cmd=cmd_order[i]
          if (ai_cmd[pane SUBSEP cmd]) out=(out == "" ? cmd : out "," cmd)
        }
        return out
      }
      function read_ps(line,    rest, pid, ppid, tty, argv0, matched) {
        rest=trim(line)
        pid=first_word(rest); sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
        ppid=first_word(rest); sub(/^[^[:space:]]+[[:space:]]+/, "", rest)
        tty=clean_tty(first_word(rest)); sub(/^[^[:space:]]+[[:space:]]*/, "", rest)
        argv0=first_word(rest)
        proc_parent[pid]=ppid
        proc_tty[pid]=tty
        proc_argv[pid]=argv0
        matched=proc_match(argv0)
        if (matched != "") proc_cmd[pid]=matched
      }
      BEGIN {
        cmd_n=split(cmds, raw_cmds, /[[:space:],:]+/)
        for (i=1; i<=cmd_n; i++) {
          c=tolower(raw_cmds[i])
          if (c == "") continue
          want[c]=raw_cmds[i]
          cmd_order[++real_cmd_n]=raw_cmds[i]
          cmd_known[raw_cmds[i]]=1
        }
        cmd_n=real_cmd_n
      }
      $0 == "__PANES__" { mode="panes"; next }
      $0 == "__FLAGS__" { mode="flags"; next }
      $0 == "__PS__" { mode="ps"; next }
      $0 == "__REG__" { mode="reg"; next }
      mode == "panes" && $0 != "" {
        pane=$1
        wt[pane]=$2; pidx[pane]=$3; wn[pane]=$4; ti[pane]=$5; cm[pane]=$6; pa[pane]=$7
        pane_shell=$8; pane_tty[pane]=clean_tty($9)
        pane_target[pane]=pane
        pane_by_pid[pane_shell]=pane
        panes_on_tty[pane_tty[pane]]=panes_on_tty[pane_tty[pane]] pane "\034"
        order[++n]=pane
        next
      }
      mode == "flags" && $0 != "" {
        if ($1 == "-") next                   # paneless marks are not pane targets
        flagged[$1]=1
        flag_epoch[$1]=$2 + 0
        flag_source[$1]=clean_user($3)
        flag_label[$1]=clean_user(NF >= 5 ? $5 : $4)
        flag_saved[$1]=clean_user(NF >= 6 ? $6 : "")
        flag_level[$1]=level_for(flag_source[$1], flag_label[$1])
        next
      }
      mode == "ps" && $0 != "" { read_ps($0); next }
      mode == "reg" && $0 != "" {
        # Positive PIDs require current argv identity. Unresolved PIDs are
        # accepted later only with independent pane-process evidence.
        if (NF < 9 || $4 == "" || $4 == "-") next
        pid=$3 + 0
        proc=clean_user($9)
        if (pid > 0 && (!(pid in proc_parent) || !proc_identity_match(proc_argv[pid], proc))) next
        if (($4 in reg_last) && reg_last[$4] > $6 + 0) next
        reg_last[$4]=$6 + 0
        kind=clean_user($1); state=clean_user($7)
        if (pid <= 0) {
          unresolved_kind[$4]=kind; unresolved_started[$4]=$5 + 0; unresolved_state[$4]=state
          next
        }
        reg_kind[$4]=kind; reg_started[$4]=$5 + 0; reg_state[$4]=state
        add_match($4, kind)
        next
      }
      END {
        for (pid in proc_cmd) {
          tty=proc_tty[pid]
          if (tty in panes_on_tty) {
            c=split(panes_on_tty[tty], tty_panes, "\034")
            for (i=1; i<=c; i++) add_process_match(tty_panes[i], proc_cmd[pid])
          }

          seen=""
          cur=pid
          for (hops=0; hops<80 && cur != ""; hops++) {
            if (cur in pane_by_pid) { add_process_match(pane_by_pid[cur], proc_cmd[pid]); break }
            if (index("\034" seen "\034", "\034" cur "\034") > 0) break
            seen=seen "\034" cur
            cur=proc_parent[cur]
          }
        }

        for (pane in unresolved_kind) {
          if (!(pane in process_ai)) continue
          reg_kind[pane]=unresolved_kind[pane]
          reg_started[pane]=unresolved_started[pane]
          reg_state[pane]=unresolved_state[pane]
          add_match(pane, unresolved_kind[pane])
        }

        # Marked live panes first, split by meaning: real action requests before
        # finished/notice marks. Paneless marks were omitted during flag input.
        need_n=0
        for (i=1; i<=n; i++) {
          pane=order[i]
          if ((pane in flagged) && (pane in ai)) {
            need_n++; nr[need_n]=level_rank(flag_level[pane]); ne[need_n]=flag_epoch[pane]; nv[need_n]=pane
          }
        }
        for (i=2; i<=need_n; i++) {          # severity, event recency; exact ties stay in pane order
          r=nr[i]; e=ne[i]; v=nv[i]
          for (j=i-1; j>=1 && (nr[j] > r || (nr[j] == r && ne[j] < e)); j--) {
            nr[j+1]=nr[j]; ne[j+1]=ne[j]; nv[j+1]=nv[j]
          }
          nr[j+1]=r; ne[j+1]=e; nv[j+1]=v
        }
        for (i=1; i<=need_n; i++) {
          emit_pane(nv[i], flag_level[nv[i]])
        }

        # Then every other detected AI pane, in pane order. These are context,
        # not action-required rows.
        for (i=1; i<=n; i++) {
          pane=order[i]
          if (!(pane in ai) || (pane in flagged)) continue
          emit_pane(pane, "active")
        }
      }
    '
}

do_list() {  # do_list [view]
  local rows list_fn
  read_state "${1:-}"
  case "$VIEW" in
    recent) list_fn=list_recent ;;
    attention) list_fn=list_attention ;;
    tree) list_fn=list_tree ;;
  esac
  if ! rows="$("$list_fn")"; then
    printf '%s\n' 'unable to list panes; reopen the switcher' >&2
    return 1
  fi
  [ -n "$rows" ] && printf '%s\n' "$rows"
  return 0
}

sanitize_text() { LC_ALL=C tr '\000-\037\177' ' ' | sed 's/  */ /g; s/^ //; s/ $//'; }

_age_since() {  # _age_since <epoch> -> 45s / 3m / 2h / 1d
  local s
  s=$(( $(date +%s) - ${1:-0} ))
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' $(( s / 60 ))
  elif [ "$s" -lt 86400 ]; then printf '%sh' $(( s / 3600 ))
  else printf '%sd' $(( s / 86400 )); fi
}

_level_for() {  # _level_for <source> <label>; mirrors the list awk level_for
  local l
  l="$(printf '%s %s' "${1:-}" "${2:-}" | tr '[:upper:]' '[:lower:]')"
  case "$l" in
    *finished*|*'your turn'*|*'turn complete'*|*'task complete'*|*done*|*任务完成*|*完成*)
      printf 'done'; return 0 ;;
  esac
  case "$l" in
    *'needs approval'*|*'needs your permission'*|*'needs input'*|*waiting*input*|*'waiting on you'*|*wait*input*|*permission*|*approval*|*'action required'*|*approve*|*拿不准*|*需要你*|*需要*许可*|*需要*批准*|*等待*输入*)
      printf 'action'; return 0 ;;
  esac
  printf 'notice'
}

_pane_status_header() {  # $1 = pane %id; tech header + separator when the pane has a mark/registry row
  local pane="$1" mark="" reg="" level="" icon='·' color="$D" parts kind sid
  local m_epoch="" m_src="" m_key="" m_label=""
  local r_kind="" r_key="" r_pid="" r_started="" r_state="" r_cwd="" alive
  [ -n "$pane" ] || return 0
  [ -r "$NEEDINPUT_FILE" ] && mark="$(awk -F '\t' -v p="$pane" '$1 == p { print; exit }' "$NEEDINPUT_FILE" 2>/dev/null || true)"
  [ -r "$REGISTRY_FILE" ] && reg="$(awk -F '\t' -v p="$pane" '$4 == p { r=$0 } END { if (r != "") print r }' "$REGISTRY_FILE" 2>/dev/null || true)"
  [ -n "$mark" ] || [ -n "$reg" ] || return 0
  # \037-joined field extraction: tab is IFS whitespace, empty fields would collapse
  if [ -n "$mark" ]; then
    IFS=$'\037' read -r m_epoch m_src m_key m_label <<< "$(printf '%s' "$mark" |
      awk -F '\t' '{ printf "%s\037%s\037%s\037%s", $2, $3, $4, (NF >= 5 ? $5 : $4) }')"
    m_src="$(printf '%s' "$m_src" | sanitize_text)"
    m_label="$(printf '%s' "$m_label" | sanitize_text)"
    level="$(_level_for "$m_src" "$m_label")"
    case "$level" in
      action) icon='⚠'; color="$M" ;;
      done)   icon='✓'; color="$G" ;;
      *)      icon='!'; color="$Y" ;;
    esac
  fi
  if [ -n "$reg" ]; then
    IFS=$'\037' read -r r_kind r_key r_pid r_started r_state r_cwd <<< "$(printf '%s' "$reg" |
      awk -F '\t' '{ printf "%s\037%s\037%s\037%s\037%s\037%s", $1, $2, $3, $5, $7, $8 }')"
  fi
  r_kind="$(printf '%s' "$r_kind" | sanitize_text)"
  r_state="$(printf '%s' "$r_state" | sanitize_text)"
  r_cwd="$(printf '%s' "$r_cwd" | sanitize_text)"
  kind="${r_kind:-$m_src}"
  parts="$icon ${kind:-?}"
  [ -n "$r_state" ] && parts="$parts · $r_state"
  [ -n "$m_epoch" ] && parts="$parts · mark $(_age_since "$m_epoch") ago"
  sid="$(printf '%s' "${r_key:-$m_key}" | sanitize_text)"
  case "$sid" in
    s:*) sid="${sid#s:}"; parts="$parts · sid $(printf '%.8s' "$sid")…" ;;
  esac
  if [ -n "$r_pid" ] && [ "$r_pid" -gt 0 ] 2>/dev/null; then
    alive=dead; kill -0 "$r_pid" 2>/dev/null && alive=alive
    parts="$parts · pid $r_pid $alive"
  fi
  [ -n "$r_started" ] && [ "$r_started" -gt 0 ] 2>/dev/null && parts="$parts · up $(_age_since "$r_started")"
  [ -n "$r_cwd" ] && parts="$parts · $(short_path "$r_cwd")"
  printf '%s%s%s\n' "$color" "$parts" "$R"
  [ -n "$m_label" ] && printf '%s%s:%s %s\n' "$D" "${m_src:-mark}" "$R" "$m_label"
  printf '%s────────────────────────────────────────%s\n' "$D" "$R"
}

do_preview() {
  local t="${1:-}" out pane_id capture
  case "$t" in
    '')        : ;;
    *)
      # one tmux client call: pane id (line 1) then the capture
      out="$(tmux display-message -p -t "$t" '#{pane_id}' ';' capture-pane -ep -t "$t" 2>/dev/null || true)"
      if [ -z "$out" ]; then echo "(no preview available)"; return 0; fi
      pane_id="${out%%$'\n'*}"
      capture=""
      case "$out" in *$'\n'*) capture="${out#*$'\n'}" ;; esac
      _pane_status_header "$pane_id" || true
      printf '%s\n' "$capture"
      ;;
  esac
}

_prompt() {
  case "$VIEW" in
    recent) printf 'Recent> ' ;;
    attention) printf 'Attention> ' ;;
    tree) printf 'Tree> ' ;;
  esac
}

cmd_set_view() {  # fzf transform: switch view, reload, repoint prompt
  local next_view rows_tmp reload_cmd
  read_state
  next_view="$(normalize_view "${1:-recent}")"
  if [ -z "${SW_ROWS:-}" ] || [ -z "${SW_ERROR:-}" ]; then
    printf abort
    return 0
  fi
  # Every reload observes a completed cleanup pass before publishing its rows.
  if ! "$SCRIPT_DIR/needinput-notify.sh" tick >/dev/null 2>&1; then
    : > "$SW_ERROR"
    printf abort
    return 0
  fi
  rows_tmp="$(mktemp "${SW_ROWS}.XXXXXX")" || {
    : > "$SW_ERROR"
    printf abort
    return 0
  }
  if ! "$SELF" list "$next_view" > "$rows_tmp" 2>/dev/null || ! mv "$rows_tmp" "$SW_ROWS"; then
    rm -f "$rows_tmp" 2>/dev/null || true
    : > "$SW_ERROR"
    printf abort
    return 0
  fi
  VIEW="$next_view"
  write_state
  printf -v reload_cmd 'cat %q' "$SW_ROWS"
  printf 'enable-sort+reload-sync(%s)+change-prompt(%s)+pos(1)' "$reload_cmd" "$(_prompt)"
}

do_menu() {
  local initial_view="${1:-}"
  local fzf preview_pos follow preview_win selected target list_file fzf_rc reload_failed
  local -a fzf_args
  fzf="$(command -v fzf || true)"
  [ -n "$fzf" ] || { tmux display-message "tmux-radar: fzf not found"; exit 1; }

  VIEW="$(normalize_view "${initial_view:-$(opt @radar-default-view recent)}")"
  preview_pos="$(opt @radar-preview right:62%)"
  follow="$(opt @radar-preview-follow on)"
  preview_win="${preview_pos},nowrap"
  [ "$follow" = "on" ] && preview_win="${preview_win},follow"

  SW_STATE="$(mktemp "${STATE_DIR}/.sw.XXXXXX")"; export SW_STATE
  write_state

  # Complete stale AI cleanup before fzf reads its first list in every view.
  if ! "$SCRIPT_DIR/needinput-notify.sh" tick >/dev/null 2>&1; then
    rm -f "$SW_STATE" 2>/dev/null || true
    printf '%s\n' 'unable to refresh AI state; reopen the switcher' >&2
    tmux display-message 'tmux-radar: unable to refresh AI state; reopen the switcher' >/dev/null 2>&1 || true
    return 1
  fi

  # Relevance applies consistently; input order is the final tie break, which
  # preserves each view's canonical order for an empty query.
  fzf_args=(--ansi --delimiter=$'\t' --with-nth=2.. --cycle '--tiebreak=begin,index')

  list_file="$(mktemp "${STATE_DIR}/.rows.XXXXXX")"
  SW_ROWS="$list_file"; export SW_ROWS
  SW_ERROR="${SW_STATE}.error"; export SW_ERROR
  if ! "$SELF" list > "$list_file" 2>/dev/null; then
    rm -f "$SW_STATE" "$SW_ERROR" "$list_file" 2>/dev/null || true
    printf '%s\n' 'unable to list panes; reopen the switcher' >&2
    tmux display-message 'tmux-radar: unable to list panes; reopen the switcher' >/dev/null 2>&1 || true
    return 1
  fi

  if selected="$(
    "$fzf" \
      "${fzf_args[@]}" \
      --layout=reverse --prompt="$(_prompt)" \
      --header='C-r Recent · C-i Attention (0/0 = no detected AI pane) · C-t Tree · A-p preview · Enter switch' \
      --preview="$SELF preview {1}" --preview-window="$preview_win" \
      --bind='change:pos(1)' \
      --bind="ctrl-t:transform($SELF set-view tree)" \
      --bind="ctrl-r:transform($SELF set-view recent)" \
      --bind="ctrl-i:transform($SELF set-view attention)" \
      --bind='alt-p:toggle-preview' \
      --bind='shift-up:preview-up,shift-down:preview-down' \
      --bind='pgup:preview-page-up,pgdn:preview-page-down' \
      < "$list_file" 2>/dev/null
  )"; then
    fzf_rc=0
  else
    fzf_rc=$?
  fi
  reload_failed=0
  [ -e "$SW_ERROR" ] && reload_failed=1
  rm -f "$SW_STATE" "$SW_ERROR" "$list_file" 2>/dev/null || true

  if [ "$reload_failed" = 1 ]; then
    printf '%s\n' 'unable to list panes; reopen the switcher' >&2
    tmux display-message 'tmux-radar: unable to list panes; reopen the switcher' >/dev/null 2>&1 || true
    return 1
  fi

  case "$fzf_rc" in
    0) ;;
    1|130) return 0 ;;
    *)
      printf '%s\n' 'picker failed; reopen the switcher' >&2
      tmux display-message 'tmux-radar: picker failed; reopen the switcher' >/dev/null 2>&1 || true
      return 1
      ;;
  esac

  [ -n "$selected" ] || exit 0
  target="${selected%%$'\t'*}"
  [[ "$target" =~ ^%[0-9]+$ ]] || return 0

  if [ "$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null || true)" != "$target" ]; then
    printf '%s\n' 'pane closed; reopen the switcher' >&2
    tmux display-message 'tmux-radar: pane closed; reopen the switcher' >/dev/null 2>&1 || true
    return 1
  fi

  if ! tmux switch-client -t "$target" 2>/dev/null; then
    printf '%s\n' 'unable to switch pane; reopen the switcher' >&2
    tmux display-message 'tmux-radar: unable to switch pane; reopen the switcher' >/dev/null 2>&1 || true
    return 1
  fi
  [ -x "$MRU_RECORD" ] && "$MRU_RECORD" "$target" >/dev/null 2>&1 || true
}

cmd_last_pane() {  # jump to the most recently used *other* pane, cross-session
  local cur pane
  cur="$(tmux display-message -p '#{pane_id}' 2>/dev/null || true)"
  if [ ! -r "$PANE_MRU_FILE" ]; then
    tmux display-message "tmux-radar: no pane history yet" 2>/dev/null || true
    exit 0
  fi
  # newest first; skip the current pane and panes that no longer exist
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    [ "$pane" != "$cur" ] || continue
    [ "$(tmux display-message -p -t "$pane" '#{pane_id}' 2>/dev/null || true)" = "$pane" ] || continue
    if tmux switch-client -t "$pane" 2>/dev/null; then exit 0; fi
    printf '%s\n' 'unable to switch pane; reopen the switcher' >&2
    exit 1
  done < <(awk -F '\t' '{ ids[NR] = $1 } END { for (i = NR; i >= 1; i--) print ids[i] }' \
    "$PANE_MRU_FILE" 2>/dev/null)
  tmux display-message "tmux-radar: no other live pane in history" 2>/dev/null || true
}

case "${1:-menu}" in
  list)          do_list "${2:-}" ;;
  preview)       do_preview "${2:-}" ;;
  set-view)      cmd_set_view "${2:-recent}" ;;
  last-pane)     cmd_last_pane ;;
  menu | *)      do_menu "${2:-}" ;;
esac

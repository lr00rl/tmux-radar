#!/usr/bin/env bash
# tmux-radar — full-screen window/pane picker with tree / recent / AI-status
# views, an expand/collapse pane level, and a live bottom-anchored preview.
#
# Subcommands (the script calls itself for fzf reload/preview/binds):
#   menu (default)                  launch the fzf popup
#   list [view] [expand]            print TAB rows "<target>\t<name>\t<meta>"
#   preview <target>                render the right-hand preview for one row
#   set-view <view>                 (fzf transform) switch view, emit actions
#   toggle-expand <curline>         (fzf transform) flip expand, keep cursor
#
# View + expand state is shared with the fzf bind subprocesses via $SW_STATE.
# fzf shows name+meta but fuzzy-searches the NAME field (window + pane titles).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/switcher.sh"

STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
MRU_FILE="${TMUX_RADAR_MRU_FILE:-${TMUX_SWITCHER_MRU_FILE:-$STATE_DIR/window-mru}}"
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
    "$home_prefix"*) printf '~/%s' "${p#$home_prefix}" ;;
    *) printf '%s' "$p" ;;
  esac
}

needinput_commands() {  # newline-separated process names watched by AI status
  local configured
  configured="${TMUX_RADAR_NEEDINPUT_COMMANDS:-${TMUX_SWITCHER_NEEDINPUT_COMMANDS:-$(opt @radar-needinput-commands 'codex claude opencode')}}"
  printf '%s\n' "$configured" | tr ',:' '  '
}

# ---- shared view/expand state (VIEW: tree|recent|needinput, EXPAND: 0|1) -----
VIEW=tree; EXPAND=0
read_state() {  # read_state [view-override] [expand-override]
  VIEW=tree; EXPAND=0
  if [ -n "${SW_STATE:-}" ] && [ -r "${SW_STATE:-/nonexistent}" ]; then
    { IFS= read -r VIEW; IFS= read -r EXPAND; } < "$SW_STATE" 2>/dev/null || true
  fi
  [ -n "${1:-}" ] && VIEW="$1"
  [ -n "${2:-}" ] && EXPAND="$2"
  case "$VIEW" in tree|recent|needinput) ;; *) VIEW=tree ;; esac
  case "$EXPAND" in 0|1) ;; *) EXPAND=0 ;; esac
}
write_state() { [ -n "${SW_STATE:-}" ] && printf '%s\n%s\n' "$VIEW" "$EXPAND" > "$SW_STATE"; }

# ---- row builders ----------------------------------------------------------
# Each row is "<target>\t<name>\t<meta>". <name> (field 2) is what fzf searches.
# Pane rows put "<window_name>/<index> <pane_title>" in <name> so a window-title
# search keeps a window and its panes together, and a pane-title search finds it.

win_row() {  # $1 = sess:win  -> one window row (active pane drives the meta)
  local target="$1" info name idx panes cmd cur_path
  info="$(tmux display-message -p -t "$target" \
    "#{window_name}${SEP}#{window_index}${SEP}#{window_panes}${SEP}#{pane_current_command}${SEP}#{pane_current_path}" 2>/dev/null)" || return 0
  IFS="$SEP" read -r name idx panes cmd cur_path <<< "$info"
  printf '%s\t%s\t%s%s%s %s%s · %s · %s%s\n' \
    "$target" "$name" "$Y" "$idx" "$R" "$D" "${panes}p" "$cmd" "$(short_path "$cur_path")" "$R"
}

tree_win_row() {  # $1 = sess:win, $2 = visual tree prefix
  local target="$1" prefix="$2" info name idx panes cmd cur_path idx_label
  info="$(tmux display-message -p -t "$target" \
    "#{window_name}${SEP}#{window_index}${SEP}#{window_panes}${SEP}#{pane_current_command}${SEP}#{pane_current_path}" 2>/dev/null)" || return 0
  IFS="$SEP" read -r name idx panes cmd cur_path <<< "$info"
  printf -v idx_label '%2s' "$idx"
  printf '%s\t%s%s%s %s%s%s %s\t%s%s · %s · %s%s\n' \
    "$target" "$D" "$prefix" "$R" "$Y" "$idx_label" "$R" "$name" "$D" "${panes}p" "$cmd" "$(short_path "$cur_path")" "$R"
}

pane_rows() {  # $1 = sess:win, $2 = tree stem, $3 = include window name (0/1)
  local target="$1" stem="${2:-  }" include_window="${3:-1}"
  local total i idx title cmd cur_path win_name branch pane_label label
  total="$(tmux list-panes -t "$target" -F x 2>/dev/null | wc -l | tr -d ' ')"
  [ "${total:-0}" -gt 0 ] || return 0
  i=0
  tmux list-panes -t "$target" -F \
    "#{pane_index}${SEP}#{pane_title}${SEP}#{pane_current_command}${SEP}#{pane_current_path}${SEP}#{window_name}" 2>/dev/null |
    while IFS="$SEP" read -r idx title cmd cur_path win_name; do
      i=$((i + 1))
      if [ "$i" -eq "$total" ]; then branch="└─"; else branch="├─"; fi
      if [ -n "$title" ]; then
        pane_label="${idx} ${title}"
      else
        pane_label="${idx} ${cmd}"
      fi
      if [ "$include_window" = 1 ]; then
        label="${win_name}/${pane_label}"
      else
        label="$pane_label"
      fi
      printf '%s.%s\t%s%s%s %s\t%s%s · %s%s\n' \
        "$target" "$idx" "$D" "${stem}${branch}" "$R" "$label" "$D" "$cmd" "$(short_path "$cur_path")" "$R"
    done
}

list_tree() {  # $1 = expand
  local expand="$1" s wc t i win_prefix pane_stem
  tmux list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r s; do
    wc="$(tmux list-windows -t "$s" -F x 2>/dev/null | wc -l | tr -d ' ')"
    printf '__hdr__:%s\t%s▾ %s%s\t%s%s windows%s\n' "$s" "$C" "$s" "$R" "$D" "$wc" "$R"
    i=0
    tmux list-windows -t "$s" -F '#{session_name}:#{window_index}' 2>/dev/null | while IFS= read -r t; do
      i=$((i + 1))
      if [ "$i" -eq "$wc" ]; then
        win_prefix="  └─"; pane_stem="     "
      else
        win_prefix="  ├─"; pane_stem="  │  "
      fi
      tree_win_row "$t" "$win_prefix"
      if [ "$expand" = 1 ]; then
        pane_rows "$t" "$pane_stem" 0
      fi
    done
  done
}

list_recent() {  # $1 = expand
  local expand="$1" rows pairs ordered mfile tgt
  if [ "$expand" != 1 ]; then
    # Ask tmux for PLAIN fields only and colorize afterwards: some tmux builds
    # (Linux distros) vis-escape control characters in command output, so a raw
    # ESC embedded in the -F format comes back as a literal "\033[1;32m".
    rows="$(tmux list-windows -a -F \
      '#{window_id}'$'\t''#{session_name}:#{window_index}'$'\t''#{window_name}'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}' 2>/dev/null)"
    mfile="$MRU_FILE"; [ -r "$mfile" ] || mfile=/dev/null
    awk -F '\t' -v G="$G" -v D="$D" -v R="$R" -v home="$HOME" '
      function spath(p) {
        if (p == home) return "~"
        if (index(p, home "/") == 1) return "~" substr(p, length(home) + 1)
        return p
      }
      function emit(id,    name) {
        name = nm[id]
        while (length(name) < w) name = name " "   # align the meta column
        printf "%s\t%s\t%s%s%s %s%s · %s%s\n", \
          tgt[id], name, G, tgt[id], R, D, cmd[id], spath(path[id]), R
      }
      NR==FNR {
        tgt[$1]=$2; nm[$1]=$3; cmd[$1]=$4; path[$1]=$5; ord[++m]=$1
        if (length($3) > w) w = length($3)
        next
      }
      { mru[++n]=$1 }
      END {
        if (w > 24) w = 24
        for (i=n;i>=1;i--){id=mru[i]; if((id in tgt) && !seen[id]++) emit(id)}
        for (j=1;j<=m;j++){id=ord[j];  if(!seen[id]++)               emit(id)}
      }' <(printf '%s\n' "$rows") "$mfile"
    return 0
  fi
  # expanded: order windows by MRU, then nest panes under each
  pairs="$(tmux list-windows -a -F '#{window_id}'$'\t''#{session_name}:#{window_index}' 2>/dev/null)"
  mfile="$MRU_FILE"; [ -r "$mfile" ] || mfile=/dev/null
  ordered="$(awk -F '\t' '
    NR==FNR { tgt[$1]=$2; ord[++m]=$1; next }
    { mru[++n]=$1 }
    END {
      for (i=n;i>=1;i--){id=mru[i]; if((id in tgt) && !seen[id]++) print tgt[id]}
      for (j=1;j<=m;j++){id=ord[j];  if(!seen[id]++)             print tgt[id]}
    }' <(printf '%s\n' "$pairs") "$mfile")"
  while IFS= read -r tgt; do
    [ -n "$tgt" ] || continue
    win_row "$tgt"; pane_rows "$tgt"
  done <<< "$ordered"
}

list_needinput() {  # pane-level AI-status process view; hook-marked panes float first
  local live flags ps_rows commands reg now
  live="$(tmux list-panes -a -F \
    '#{pane_id}'$'\t''#{session_name}:#{window_index}'$'\t''#{pane_index}'$'\t''#{window_name}'$'\t''#{pane_title}'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}'$'\t''#{pane_pid}'$'\t''#{pane_tty}' 2>/dev/null)"
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
      function add_match(pane, cmd) {
        if (pane == "" || cmd == "") return
        if (!(pane in ai)) ai[pane]=1
        ai_cmd[pane SUBSEP cmd]=1
        # registry kinds outside the watch list must still show in cmds_for
        if (!(cmd in cmd_known)) { cmd_known[cmd]=1; cmd_order[++cmd_n]=cmd }
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
        printf "%s\t%s%s%s%s %s%s%s\t%s%s · %s · %s%s%s\n", \
          pane_target[pane], badge(level), C, wt[pane] "." pidx[pane], R, wn[pane], title, R, \
          D, matched, cm[pane], pa[pane], R, hint tail
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
        pane_target[pane]=wt[pane] "." pidx[pane]
        pane_by_pid[pane_shell]=pane
        panes_on_tty[pane_tty[pane]]=panes_on_tty[pane_tty[pane]] pane "\034"
        order[++n]=pane
        next
      }
      mode == "flags" && $0 != "" {
        if ($1 == "-") {                     # paneless background-session mark
          bg_n++
          bg_epoch[bg_n]=$2 + 0
          bg_src[bg_n]=$3
          bg_label[bg_n]=(NF >= 5 ? $5 : $4)
          bg_level[bg_n]=level_for(bg_src[bg_n], bg_label[bg_n])
          next
        }
        flagged[$1]=1
        flag_epoch[$1]=$2 + 0
        flag_source[$1]=$3
        flag_label[$1]=(NF >= 5 ? $5 : $4)
        flag_saved[$1]=(NF >= 6 ? $6 : "")
        flag_level[$1]=level_for(flag_source[$1], flag_label[$1])
        next
      }
      mode == "ps" && $0 != "" { read_ps($0); next }
      mode == "reg" && $0 != "" {
        # kind key pid pane started last_event state cwd proc — authoritative
        # AI-pane detector; pid must be in the ps snapshot (0 = unresolved,
        # trust tick GC); newest last_event wins when a pane has two rows
        if (NF < 9 || $4 == "" || $4 == "-") next
        if ($3 + 0 > 0 && !($3 in proc_parent)) next
        if (($4 in reg_last) && reg_last[$4] > $6 + 0) next
        reg_last[$4]=$6 + 0
        reg_kind[$4]=$1; reg_started[$4]=$5 + 0; reg_state[$4]=$7
        add_match($4, $1)
        next
      }
      END {
        for (pid in proc_cmd) {
          tty=proc_tty[pid]
          if (tty in panes_on_tty) {
            c=split(panes_on_tty[tty], tty_panes, "\034")
            for (i=1; i<=c; i++) add_match(tty_panes[i], proc_cmd[pid])
          }

          seen=""
          cur=pid
          for (hops=0; hops<80 && cur != ""; hops++) {
            if (cur in pane_by_pid) { add_match(pane_by_pid[cur], proc_cmd[pid]); break }
            if (index("\034" seen "\034", "\034" cur "\034") > 0) break
            seen=seen "\034" cur
            cur=proc_parent[cur]
          }
        }

        # Marked rows first, but split by meaning: real action requests before
        # finished/notice marks. Background rows are not pane-jumpable; they are
        # status rows for external Claude sessions.
        need_n=0
        for (i=1; i<=n; i++) {
          pane=order[i]
          if (pane in flagged) {
            need_n++; nr[need_n]=level_rank(flag_level[pane]); ne[need_n]=flag_epoch[pane]; nk[need_n]="p"; nv[need_n]=pane
          }
        }
        for (b=1; b<=bg_n; b++) {
          need_n++; nr[need_n]=level_rank(bg_level[b]); ne[need_n]=bg_epoch[b]; nk[need_n]="b"; nv[need_n]=b
        }
        for (i=2; i<=need_n; i++) {          # insertion sort: severity, then epoch descending
          r=nr[i]; e=ne[i]; k=nk[i]; v=nv[i]
          for (j=i-1; j>=1 && (nr[j] > r || (nr[j] == r && ne[j] < e)); j--) {
            nr[j+1]=nr[j]; ne[j+1]=ne[j]; nk[j+1]=nk[j]; nv[j+1]=nv[j]
          }
          nr[j+1]=r; ne[j+1]=e; nk[j+1]=k; nv[j+1]=v
        }
        for (i=1; i<=need_n; i++) {
          if (nk[i] == "b") {
            b=nv[i]
            printf "%s\t%s%s\t%s%s · background session · not a tmux pane%s\n", \
              "__bg__:" b, badge(bg_level[b]), bg_label[b], D, bg_src[b], R
          } else {
            emit_pane(nv[i], flag_level[nv[i]])
          }
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

do_list() {  # do_list [view] [expand]
  read_state "${1:-}" "${2:-}"
  case "$VIEW" in
    recent)    list_recent "$EXPAND" ;;
    needinput) list_needinput "$EXPAND" ;;
    *)         list_tree "$EXPAND" ;;
  esac
}

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
  kind="${r_kind:-$m_src}"
  parts="$icon ${kind:-?}"
  [ -n "$r_state" ] && parts="$parts · $r_state"
  [ -n "$m_epoch" ] && parts="$parts · mark $(_age_since "$m_epoch") ago"
  sid="${r_key:-$m_key}"
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

_preview_bg() {  # $1 = 1-based index among paneless (-) marks, need-input file order
  local idx="$1" line="" reg="" verdict
  local epoch="" src="" key="" label="" r_kind="" r_pid="" r_state="" r_cwd=""
  [ -r "$NEEDINPUT_FILE" ] && line="$(awk -F '\t' -v n="$idx" \
    '$1 == "-" { if (++c == n + 0) { print; exit } }' "$NEEDINPUT_FILE" 2>/dev/null || true)"
  if [ -z "$line" ]; then
    printf 'Background AI session\n\nThis mark is no longer in the state file (handled or GCd since the list rendered).\nReload the view (C-i) to refresh.\n'
    return 0
  fi
  IFS=$'\037' read -r epoch src key label <<< "$(printf '%s' "$line" |
    awk -F '\t' '{ printf "%s\037%s\037%s\037%s", $2, $3, $4, (NF >= 5 ? $5 : $4) }')"
  [ -n "$key" ] && [ -r "$REGISTRY_FILE" ] && reg="$(awk -F '\t' -v k="$key" \
    '$2 == k { r=$0 } END { if (r != "") print r }' "$REGISTRY_FILE" 2>/dev/null || true)"
  printf 'Background AI session (no tmux pane)\n\n'
  printf '  label:  %s\n' "$label"
  printf '  source: %s\n' "$src"
  printf '  key:    %s\n' "${key:-—}"
  printf '  age:    %s\n' "$(_age_since "$epoch")"
  if [ -n "$reg" ]; then
    IFS=$'\037' read -r r_kind r_pid r_state r_cwd <<< "$(printf '%s' "$reg" |
      awk -F '\t' '{ printf "%s\037%s\037%s\037%s", $1, $3, $7, $8 }')"
    verdict='dead (cleared on next tick)'
    if [ "${r_pid:-0}" -gt 0 ] 2>/dev/null && kill -0 "$r_pid" 2>/dev/null; then verdict='alive'; fi
    printf '  agent:  %s · %s · pid %s %s' "$r_kind" "$r_state" "${r_pid:-?}" "$verdict"
    [ -n "$r_cwd" ] && printf ' · %s' "$(short_path "$r_cwd")"
    printf '\n'
  else
    printf '  agent:  no registry row (session ended, or started before hooks were installed)\n'
  fi
  printf '\nNo pane to switch to. Run needinput-notify.sh doctor for the full diagnostic.\n'
}

do_preview() {
  local t="${1:-}" out pane_id capture
  case "$t" in
    __bg__:*)  _preview_bg "${t#__bg__:}" ;;
    __noop__:*) printf 'This row is informational and has no tmux target.\n' ;;
    __hdr__:*) tmux list-windows -t "${t#__hdr__:}" \
                 -F '  #{window_index}: #{window_name}  (#{window_panes} panes · #{pane_current_command})' 2>/dev/null ;;
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

_prompt() {  # echo "label[+]> " for current VIEW/EXPAND
  local label="$VIEW"; [ "$VIEW" = needinput ] && label="AI status"
  local ind=""; [ "$EXPAND" = 1 ] && ind="+"
  printf '%s%s> ' "$label" "$ind"
}

cmd_set_view() {  # fzf transform: switch view, reload, repoint prompt
  local pos
  read_state
  VIEW="${1:-tree}"; case "$VIEW" in tree|recent|needinput) ;; *) VIEW=tree ;; esac
  # GC stale marks before the AI status list renders (~50ms, one keystroke)
  [ "$VIEW" = needinput ] && "$SCRIPT_DIR/needinput-notify.sh" tick >/dev/null 2>&1 || true
  write_state
  pos=1
  [ "$VIEW" = recent ] && pos=2
  printf 'reload-sync(%s list)+change-prompt(%s)+pos(%s)' "$SELF" "$(_prompt)" "$pos"
}

cmd_toggle_expand() {  # fzf transform: flip expand, keep cursor on the window
  local curline="${1:-}" ctgt cwin idx actions
  read_state
  EXPAND=$((1 - EXPAND)); write_state
  ctgt="${curline%%$'\t'*}"
  case "$ctgt" in
    __bg__:*|__noop__:*) cwin="" ;;
    __hdr__:*) cwin="$ctgt" ;;
    *.*)       cwin="${ctgt%.*}" ;;   # strip ".pane"
    *)         cwin="$ctgt" ;;
  esac
  # 1-based row index of the window (or header) the cursor belonged to
  # read the whole list (no early awk exit -> no SIGPIPE killing do_list under
  # set -e); prefer the exact window-row match, else first row in that window.
  idx="$(do_list 2>/dev/null | awk -F '\t' -v w="$cwin" '
    { t=$1; sub(/\.[0-9]+$/,"",t)
      if (!ex && $1==w) ex=NR
      if (!fb && t==w) fb=NR }
    END { print (ex ? ex : (fb ? fb : "")) }' 2>/dev/null || true)"
  [ -n "$idx" ] || idx=1
  # sort flips with expand (relevance when collapsed, grouped order when expanded)
  actions="toggle-sort+reload-sync($SELF list)+change-prompt($(_prompt))"
  [ -z "${FZF_QUERY:-}" ] && actions="$actions+pos($idx)"
  printf '%s' "$actions"
}

do_menu() {
  local fzf preview_pos follow preview_win selected target session win
  local start_bind sort_flag
  fzf="$(command -v fzf || true)"
  [ -n "$fzf" ] || { tmux display-message "tmux-radar: fzf not found"; exit 1; }

  VIEW="$(opt @radar-default-view tree)"; case "$VIEW" in tree|recent|needinput) ;; *) VIEW=tree ;; esac
  case "$(opt @radar-expand-panes off)" in on|1|true) EXPAND=1 ;; *) EXPAND=0 ;; esac
  preview_pos="$(opt @radar-preview right:62%)"
  follow="$(opt @radar-preview-follow on)"
  preview_win="${preview_pos},nowrap"
  [ "$follow" = "on" ] && preview_win="${preview_win},follow"

  SW_STATE="$(mktemp "${STATE_DIR}/.sw.XXXXXX")"; export SW_STATE
  write_state

  # GC stale AI-status marks so the view opens clean; synchronous only when
  # AI status is the first view shown (elsewhere the C-i transform re-GCs).
  if [ "$VIEW" = needinput ]; then "$SCRIPT_DIR/needinput-notify.sh" tick >/dev/null 2>&1 || true
  else ("$SCRIPT_DIR/needinput-notify.sh" tick >/dev/null 2>&1 &)
  fi

  # Recent opens with the cursor on row 2 (row 1 is the current window), both
  # on initial popup open and when switching back into the recent view.
  # Tree/AI-status view switches and query changes reset to row 1.
  # --sync is required so the list is loaded before 'start' fires.
  start_bind=""
  [ "$VIEW" = recent ] && start_bind="--sync --bind=start:pos(2)"
  # sort: relevance when collapsed; preserve window/pane grouping when expanded.
  # AI status is already pane-level and floats hook-marked panes first.
  sort_flag=""; { [ "$EXPAND" = 1 ] || [ "$VIEW" = needinput ]; } && sort_flag="--no-sort"

  selected="$(
    "$SELF" list | "$fzf" \
      --ansi --delimiter=$'\t' --with-nth=2.. --nth=1 --cycle $sort_flag $start_bind \
      --layout=reverse --prompt="$(_prompt)" \
      --header='C-t tree · C-r recent · C-i AI status · C-e expand/collapse panes · A-p preview · S-↑/↓ PgUp/Dn scroll · Enter switch' \
      --preview="$SELF preview {1}" --preview-window="$preview_win" \
      --bind='change:pos(1)' \
      --bind="ctrl-t:transform($SELF set-view tree)" \
      --bind="ctrl-r:transform($SELF set-view recent)" \
      --bind="ctrl-i:transform($SELF set-view needinput)" \
      --bind="ctrl-e:transform($SELF toggle-expand {})" \
      --bind='alt-p:toggle-preview' \
      --bind='shift-up:preview-up,shift-down:preview-down' \
      --bind='pgup:preview-page-up,pgdn:preview-page-down' \
      || true
  )"
  rm -f "$SW_STATE" 2>/dev/null || true

  [ -n "$selected" ] || exit 0
  target="${selected%%$'\t'*}"
  case "$target" in
    __bg__:* | __noop__:* | __hdr__:* | '')
      tmux display-message "tmux-radar: status-only row; no tmux pane to switch to" 2>/dev/null || true
      exit 0
      ;;
    __*)
      tmux display-message "tmux-radar: unknown internal row; no switch performed" 2>/dev/null || true
      exit 0
      ;;
    *:*) ;;
    *)
      tmux display-message "tmux-radar: invalid target '$target'; no switch performed" 2>/dev/null || true
      exit 0
      ;;
  esac

  session="${target%%:*}"
  win="${target%.*}"            # sess:win (drops ".pane" if present)
  [ -x "$MRU_RECORD" ] && "$MRU_RECORD" "$win" >/dev/null 2>&1 || true
  tmux switch-client -t "$session"
  tmux select-window -t "$win"
  case "$target" in *.*) tmux select-pane -t "$target" 2>/dev/null || true ;; esac
}

case "${1:-menu}" in
  list)          do_list "${2:-}" "${3:-}" ;;
  preview)       do_preview "${2:-}" ;;
  set-view)      cmd_set_view "${2:-tree}" ;;
  toggle-expand) cmd_toggle_expand "${2:-}" ;;
  menu | *)      do_menu ;;
esac

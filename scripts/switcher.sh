#!/usr/bin/env bash
# tmux-switcher — full-screen window/pane picker with tree / recent / need-input
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

STATE_DIR="${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}"
MRU_FILE="${TMUX_SWITCHER_MRU_FILE:-$STATE_DIR/window-mru}"
NEEDINPUT_FILE="${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}"
MRU_RECORD="$SCRIPT_DIR/mru-record.sh"

mkdir -p "$STATE_DIR" 2>/dev/null || true

opt() {  # opt <option> <default>
  local v; v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
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

needinput_commands() {  # newline-separated process names watched by need-input
  local configured
  configured="${TMUX_SWITCHER_NEEDINPUT_COMMANDS:-$(opt @switcher-needinput-commands 'codex claude')}"
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
    rows="$(tmux list-windows -a -F \
      "#{window_id}"$'\t'"#{session_name}:#{window_index}"$'\t'"#{window_name}"$'\t'"${G}#{session_name}:#{window_index}${R} ${D}#{pane_current_command} · #{pane_current_path}${R}" 2>/dev/null)"
    if [ -r "$MRU_FILE" ]; then
      awk -F '\t' '
        NR==FNR { tgt[$1]=$2; nm[$1]=$3; meta[$1]=$4; ord[++m]=$1; next }
        { mru[++n]=$1 }
        END {
          for (i=n;i>=1;i--){id=mru[i]; if((id in tgt) && !seen[id]++) print tgt[id] "\t" nm[id] "\t" meta[id]}
          for (j=1;j<=m;j++){id=ord[j];  if(!seen[id]++)             print tgt[id] "\t" nm[id] "\t" meta[id]}
        }' <(printf '%s\n' "$rows") "$MRU_FILE"
    else
      printf '%s\n' "$rows" | cut -f2-
    fi
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

list_needinput() {  # pane-level AI process view; hook-marked panes float first
  local live flags ps_rows commands
  live="$(tmux list-panes -a -F \
    '#{pane_id}'$'\t''#{session_name}:#{window_index}'$'\t''#{pane_index}'$'\t''#{window_name}'$'\t''#{pane_title}'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}'$'\t''#{pane_pid}'$'\t''#{pane_tty}' 2>/dev/null)"
  [ -n "$live" ] || return 0
  flags=""; [ -r "$NEEDINPUT_FILE" ] && flags="$(cat "$NEEDINPUT_FILE" 2>/dev/null || true)"
  ps_rows="$(ps -axo pid=,ppid=,tty=,command= 2>/dev/null || true)"
  commands="$(needinput_commands)"

  { printf '__PANES__\n%s\n__FLAGS__\n%s\n__PS__\n%s\n' "$live" "$flags" "$ps_rows"; } |
    awk -F '\t' -v cmds="$commands" -v C="$C" -v M="$M" -v D="$D" -v R="$R" '
      function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
      function clean_tty(t) { sub(/^\/dev\//, "", t); return t }
      function first_word(s, x) { x=trim(s); sub(/[[:space:]].*/, "", x); return x }
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
        }
        cmd_n=real_cmd_n
      }
      $0 == "__PANES__" { mode="panes"; next }
      $0 == "__FLAGS__" { mode="flags"; next }
      $0 == "__PS__" { mode="ps"; next }
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
          bg_src[bg_n]=$3
          bg_label[bg_n]=(NF >= 5 ? $5 : $4)
          next
        }
        flagged[$1]=1
        flag_source[$1]=$3
        flag_label[$1]=(NF >= 5 ? $5 : $4)
        next
      }
      mode == "ps" && $0 != "" { read_ps($0); next }
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

        # background rows jump to a pane running the claude TUI, if any
        claude_pane=""
        for (i=1; i<=n; i++) { p=order[i]; if (ai_cmd[p SUBSEP "claude"]) { claude_pane=p; break } }

        for (pass=1; pass<=3; pass++) {
          if (pass == 2) {                   # paneless background marks, newest first
            for (b=bg_n; b>=1; b--) {
              tgt=(claude_pane != "" ? pane_target[claude_pane] : "__hdr__:bg")
              printf "%s\t%s⚠%s %s\t%s%s · background session%s\n", \
                tgt, M, R, bg_label[b], D, bg_src[b], R
            }
            continue
          }
          for (i=1; i<=n; i++) {
            pane=order[i]
            if (!(pane in ai)) continue
            is_flagged=(pane in flagged)
            if ((pass == 1 && !is_flagged) || (pass == 3 && is_flagged)) continue

            mark=(is_flagged ? M "⚠ " R : "")
            title=(ti[pane] != "" && ti[pane] != wn[pane] ? "/" ti[pane] : "")
            matched=cmds_for(pane)
            hint=""
            if (is_flagged) {
              hint=flag_label[pane]
              if (flag_source[pane] != "") hint=flag_source[pane] ": " hint
              if (hint != "") hint=" · " M hint R
            }
            printf "%s\t%s%s%s%s %s%s%s\t%s%s · %s · %s%s%s\n", \
              pane_target[pane], mark, C, wt[pane] "." pidx[pane], R, wn[pane], title, R, \
              D, matched, cm[pane], pa[pane], R, hint
          }
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

do_preview() {
  local t="${1:-}"
  case "$t" in
    __hdr__:*) tmux list-windows -t "${t#__hdr__:}" \
                 -F '  #{window_index}: #{window_name}  (#{window_panes} panes · #{pane_current_command})' 2>/dev/null ;;
    '')        : ;;
    *)         tmux capture-pane -ep -t "$t" 2>/dev/null || echo "(no preview available)" ;;
  esac
}

_prompt() {  # echo "label[+]> " for current VIEW/EXPAND
  local label="$VIEW"; [ "$VIEW" = needinput ] && label="need-input"
  local ind=""; [ "$EXPAND" = 1 ] && ind="+"
  printf '%s%s> ' "$label" "$ind"
}

cmd_set_view() {  # fzf transform: switch view, reload, repoint prompt
  local pos
  read_state
  VIEW="${1:-tree}"; case "$VIEW" in tree|recent|needinput) ;; *) VIEW=tree ;; esac
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
  [ -n "$fzf" ] || { tmux display-message "tmux-switcher: fzf not found"; exit 1; }

  VIEW="$(opt @switcher-default-view tree)"; case "$VIEW" in tree|recent|needinput) ;; *) VIEW=tree ;; esac
  case "$(opt @switcher-expand-panes off)" in on|1|true) EXPAND=1 ;; *) EXPAND=0 ;; esac
  preview_pos="$(opt @switcher-preview right:62%)"
  follow="$(opt @switcher-preview-follow on)"
  preview_win="${preview_pos},nowrap"
  [ "$follow" = "on" ] && preview_win="${preview_win},follow"

  SW_STATE="$(mktemp "${STATE_DIR}/.sw.XXXXXX")"; export SW_STATE
  write_state

  # Recent opens with the cursor on row 2 (row 1 is the current window), both
  # on initial popup open and when switching back into the recent view.
  # Tree/need-input view switches and query changes reset to row 1.
  # --sync is required so the list is loaded before 'start' fires.
  start_bind=""
  [ "$VIEW" = recent ] && start_bind="--sync --bind=start:pos(2)"
  # sort: relevance when collapsed; preserve window/pane grouping when expanded.
  # need-input is already pane-level and floats hook-marked panes first.
  sort_flag=""; { [ "$EXPAND" = 1 ] || [ "$VIEW" = needinput ]; } && sort_flag="--no-sort"

  selected="$(
    "$SELF" list | "$fzf" \
      --ansi --delimiter=$'\t' --with-nth=2.. --nth=1 --cycle $sort_flag $start_bind \
      --layout=reverse --prompt="$(_prompt)" \
      --header='C-t tree · C-r recent · C-i need-input · C-e expand/collapse panes · A-p preview · S-↑/↓ PgUp/Dn scroll · Enter switch' \
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
  case "$target" in __hdr__:* | '') exit 0 ;; esac

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

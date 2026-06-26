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
  tmux display-message -p -t "$1" \
    "$1"$'\t'"#{window_name}"$'\t'"${Y}#{window_index}${R} ${D}#{window_panes}p · #{pane_current_command} · #{pane_current_path}${R}" 2>/dev/null
}

pane_rows() {  # $1 = sess:win  -> one row per pane, nested/indented
  tmux list-panes -t "$1" -F \
    "$1.#{pane_index}"$'\t'"  ${D}└ #{window_name}/${R}#{pane_index} #{pane_title}"$'\t'"${D}#{pane_current_command} · #{pane_current_path}${R}" 2>/dev/null
}

list_tree() {  # $1 = expand
  local expand="$1" s wc t
  tmux list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r s; do
    wc="$(tmux list-windows -t "$s" -F x 2>/dev/null | wc -l | tr -d ' ')"
    printf '__hdr__:%s\t%s▸ %s%s\t%s%s windows%s\n' "$s" "$C" "$s" "$R" "$D" "$wc" "$R"
    if [ "$expand" = 1 ]; then
      tmux list-windows -t "$s" -F '#{session_name}:#{window_index}' 2>/dev/null | while IFS= read -r t; do
        win_row "$t"; pane_rows "$t"
      done
    else
      tmux list-windows -t "$s" -F \
        "#{session_name}:#{window_index}"$'\t'"#{window_name}"$'\t'"${Y}#{window_index}${R} ${D}#{window_panes}p · #{pane_current_command} · #{pane_current_path}${R}" 2>/dev/null
    fi
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

list_needinput() {  # $1 = expand
  local expand="$1" live
  [ -r "$NEEDINPUT_FILE" ] || return 0
  live="$(tmux list-panes -a -F \
    '#{pane_id}'$'\t''#{session_name}:#{window_index}'$'\t''#{pane_index}'$'\t''#{window_name}'$'\t''#{pane_title}'$'\t''#{pane_current_command}'$'\t''#{pane_current_path}' 2>/dev/null)"
  awk -F '\t' -v expand="$expand" -v M="$M" -v D="$D" -v R="$R" '
    NR==FNR { wt[$1]=$2; pidx[$1]=$3; wn[$1]=$4; ti[$1]=$5; cm[$1]=$6; pa[$1]=$7; next }
    {
      pid=$1
      if (!(pid in wt)) next                         # dead / not live -> skip
      w=wt[pid]
      if (!(w in seen)) { seen[w]=1; order[++n]=w; firstpid[w]=pid }
      plist[w]=plist[w] pid "\n"
    }
    END {
      for (i=1;i<=n;i++){
        w=order[i]; fp=firstpid[w]
        printf "%s\t%s⚠ %s%s\t%s%s · %s%s\n", w, M, wn[fp], R, D, cm[fp], pa[fp], R
        if (expand=="1"){
          c=split(plist[w], a, "\n")
          for (k=1;k<=c;k++){ pid=a[k]; if(pid=="")continue
            printf "%s.%s\t  %s└ %s/%s%s %s\t%s%s · %s%s\n", w, pidx[pid], D, wn[pid], R, pidx[pid], ti[pid], D, cm[pid], pa[pid], R
          }
        }
      }
    }
  ' <(printf '%s\n' "$live") "$NEEDINPUT_FILE"
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
  read_state
  VIEW="${1:-tree}"; case "$VIEW" in tree|recent|needinput) ;; *) VIEW=tree ;; esac
  write_state
  printf 'reload-sync(%s list)+change-prompt(%s)' "$SELF" "$(_prompt)"
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

  # recent opens with the cursor on row 2 (row 1 is the current window). --sync
  # is required so the list is loaded before 'start' fires.
  start_bind=""
  [ "$VIEW" = recent ] && start_bind="--sync --bind=start:down"
  # sort: relevance when collapsed; preserve window/pane grouping when expanded
  sort_flag=""; [ "$EXPAND" = 1 ] && sort_flag="--no-sort"

  selected="$(
    "$SELF" list | "$fzf" \
      --ansi --delimiter=$'\t' --with-nth=2.. --nth=1 --cycle $sort_flag $start_bind \
      --layout=reverse --prompt="$(_prompt)" \
      --header='C-t tree · C-r recent · C-i need-input · C-e expand/collapse panes · A-p preview · S-↑/↓ PgUp/Dn scroll · Enter switch' \
      --preview="$SELF preview {1}" --preview-window="$preview_win" \
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

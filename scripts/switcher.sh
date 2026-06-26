#!/usr/bin/env bash
# tmux-switcher — full-screen window picker with tree / recent / need-input
# views and a live, bottom-anchored preview.
#
# Subcommands (the script calls itself for fzf reload/preview):
#   menu (default)                  launch the fzf popup
#   list <tree|recent|needinput>    print TAB rows "<target>\t<name>\t<meta>"
#   preview <target>                render the right-hand preview for one row
#
# fzf shows name+meta but fuzzy-searches the window NAME only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/switcher.sh"

STATE_DIR="${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}"
MRU_FILE="${TMUX_SWITCHER_MRU_FILE:-$STATE_DIR/window-mru}"
NEEDINPUT_FILE="${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}"
MRU_RECORD="$SCRIPT_DIR/mru-record.sh"

opt() {  # opt <option> <default>
  local v; v="$(tmux show-option -gqv "$1" 2>/dev/null || true)"
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "$2"; fi
}

# ANSI (tmux -F / printf emit literally; fzf --ansi renders)
C=$'\033[1;36m'; Y=$'\033[33m'; G=$'\033[1;32m'; M=$'\033[1;35m'; D=$'\033[2m'; R=$'\033[0m'

# ---- views: each prints "<target>\t<name>\t<meta>" -------------------------

list_tree() {
  local s w_count
  tmux list-sessions -F '#{session_name}' | while IFS= read -r s; do
    w_count="$(tmux list-windows -t "$s" -F x | wc -l | tr -d ' ')"
    printf '__hdr__:%s\t%s▸ %s%s\t%s%s windows%s\n' "$s" "$C" "$s" "$R" "$D" "$w_count" "$R"
    tmux list-windows -t "$s" -F \
      "#{session_name}:#{window_index}"$'\t'"    #{window_name}"$'\t'"${Y}#{window_index}${R} ${D}#{window_panes}p · #{pane_current_command} · #{pane_current_path}${R}"
  done
}

list_recent() {
  local rows
  rows="$(tmux list-windows -a -F \
    "#{window_id}"$'\t'"#{session_name}:#{window_index}"$'\t'"#{window_name}"$'\t'"${G}#{session_name}:#{window_index}${R} ${D}#{pane_current_command} · #{pane_current_path}${R}")"
  if [ -r "$MRU_FILE" ]; then
    awk -F '\t' '
      NR==FNR { tgt[$1]=$2; nm[$1]=$3; meta[$1]=$4; ord[++m]=$1; next }
      { mru[++n]=$1 }
      END {
        for (i=n; i>=1; i--) { id=mru[i]; if ((id in tgt) && !seen[id]++) print tgt[id] "\t" nm[id] "\t" meta[id] }
        for (j=1; j<=m; j++) { id=ord[j];  if (!seen[id]++)             print tgt[id] "\t" nm[id] "\t" meta[id] }
      }' <(printf '%s\n' "$rows") "$MRU_FILE"
  else
    printf '%s\n' "$rows" | cut -f2-
  fi
}

list_needinput() {
  [ -r "$NEEDINPUT_FILE" ] || return 0
  local panes
  panes="$(tmux list-panes -a -F \
    "#{pane_id}"$'\t'"#{session_name}:#{window_index}"$'\t'"#{window_name}"$'\t'"${M}⚠ #{session_name}:#{window_index}${R} ${D}#{pane_current_command} · #{pane_current_path}${R}")"
  awk -F '\t' '
    NR==FNR { tgt[$1]=$2; nm[$1]=$3; meta[$1]=$4; next }
    { pid=$1; if ((pid in tgt) && !seen[pid]++) print tgt[pid] "\t" nm[pid] "\t" meta[pid] }
  ' <(printf '%s\n' "$panes") "$NEEDINPUT_FILE"
}

do_list() {
  case "${1:-tree}" in
    recent)    list_recent ;;
    needinput) list_needinput ;;
    *)         list_tree ;;
  esac
}

do_preview() {
  local t="${1:-}"
  case "$t" in
    __hdr__:*) tmux list-windows -t "${t#__hdr__:}" \
                 -F '  #{window_index}: #{window_name}  (#{window_panes} panes · #{pane_current_command})' ;;
    '')        : ;;
    *)         tmux capture-pane -ep -t "$t" 2>/dev/null || echo "(no preview available)" ;;
  esac
}

do_menu() {
  local fzf default_view preview_pos follow preview_win selected target session
  fzf="$(command -v fzf || true)"
  [ -n "$fzf" ] || { tmux display-message "tmux-switcher: fzf not found"; exit 1; }

  default_view="$(opt @switcher-default-view tree)"
  case "$default_view" in tree|recent|needinput) ;; *) default_view=tree ;; esac
  preview_pos="$(opt @switcher-preview right:62%)"
  follow="$(opt @switcher-preview-follow on)"
  preview_win="${preview_pos},nowrap"
  [ "$follow" = "on" ] && preview_win="${preview_win},follow"

  selected="$(
    "$SELF" list "$default_view" | "$fzf" \
      --ansi --delimiter=$'\t' --with-nth=2.. --nth=1 --cycle \
      --layout=reverse --prompt="${default_view}> " \
      --header='ctrl-s tree · ctrl-r recent · ctrl-i need-input · alt-p preview · S-↑/↓ PgUp/PgDn scroll · Enter switch' \
      --preview="$SELF preview {1}" --preview-window="$preview_win" \
      --bind="ctrl-s:reload($SELF list tree)+change-prompt(tree> )" \
      --bind="ctrl-r:reload($SELF list recent)+change-prompt(recent> )" \
      --bind="ctrl-i:reload($SELF list needinput)+change-prompt(need-input> )" \
      --bind='alt-p:toggle-preview' \
      --bind='shift-up:preview-up,shift-down:preview-down' \
      --bind='pgup:preview-page-up,pgdn:preview-page-down' \
      || true
  )"

  [ -n "$selected" ] || exit 0
  target="${selected%%$'\t'*}"
  case "$target" in __hdr__:* | '') exit 0 ;; esac

  session="${target%%:*}"
  [ -x "$MRU_RECORD" ] && "$MRU_RECORD" "$target" >/dev/null 2>&1 || true
  tmux switch-client -t "$session"
  tmux select-window -t "$target"
}

case "${1:-menu}" in
  list)    do_list "${2:-tree}" ;;
  preview) do_preview "${2:-}" ;;
  menu | *) do_menu ;;
esac

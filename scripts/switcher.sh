#!/usr/bin/env bash
# tmux-radar — window-first tmux switcher with Recent / Inbox / Tree views and
# a live pane preview.
#
# Subcommands (the script calls itself for fzf reload/preview/binds):
#   menu (default)                  launch the fzf popup
#   list [view]                     print TAB rows "%pane-id\t<name>\t<meta>"
#   preview <target>                render the right-hand preview for one row
#   set-view <view>                 (fzf transform) switch view, emit actions
#   toggle-expand                   (fzf transform) show/hide pane leaves
#   jump <1..9>                     (fzf transform) safe visible-row jump
#
# View state is shared with the fzf bind subprocesses via $SW_STATE. fzf hides
# the target field, searches the two display fields, and returns the full row.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/switcher.sh"

STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
WINDOW_MRU_FILE="${TMUX_RADAR_MRU_FILE:-${TMUX_SWITCHER_MRU_FILE:-$STATE_DIR/window-mru}}"
PANE_MRU_FILE="${TMUX_RADAR_PANE_MRU_FILE:-$STATE_DIR/pane-mru}"
NEEDINPUT_FILE="${TMUX_RADAR_NEEDINPUT_FILE:-${TMUX_SWITCHER_NEEDINPUT_FILE:-$STATE_DIR/need-input}}"
# agent-session registry written by needinput-notify.sh hooks (TSV, 9 fields:
# kind key pid pane started last_event state cwd proc); readers need no lock
REGISTRY_FILE="${TMUX_RADAR_REGISTRY_FILE:-$STATE_DIR/agent-registry}"
# live scanner output (TSV, 5 fields: pane kind state title epoch)
LIVE_FILE="${TMUX_RADAR_LIVE_FILE:-$STATE_DIR/ai-live}"
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
C=$'\033[1;36m'; Y=$'\033[33m'; G=$'\033[1;32m'; M=$'\033[1;35m'; B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
SEP=$'\037'
ZWSP=$'\342\200\213'

short_path() {  # short_path <path> -> compact display path
  local p="${1:-}" home_prefix
  home_prefix="${HOME%/}/"
  case "$p" in
    "$HOME") printf '~' ;;
    "$home_prefix"*) printf '%s/%s' '~' "${p#"$home_prefix"}" ;;
    *) printf '%s' "$p" ;;
  esac
}

# ---- shared view state ------------------------------------------------------
normalize_view() {
  case "${1:-}" in
    all|tree) printf tree ;;
    attention|needinput|inbox) printf inbox ;;
    agents|agent|ai) printf agents ;;
    recent) printf recent ;;
    *) printf recent ;;
  esac
}

VIEW=recent
EXPANDED=0
read_state() {  # read_state [view-override] [expanded-override]
  local stored=""
  VIEW=recent
  EXPANDED=0
  if [ -n "${SW_STATE:-}" ] && [ -r "${SW_STATE:-/nonexistent}" ]; then
    IFS= read -r stored < "$SW_STATE" 2>/dev/null || true
    VIEW="${stored%%$'\t'*}"
    case "$stored" in *$'\t'*) EXPANDED="${stored#*$'\t'}" ;; esac
  fi
  [ -n "${1:-}" ] && VIEW="$1"
  [ -n "${2:-}" ] && EXPANDED="$2"
  VIEW="$(normalize_view "$VIEW")"
  case "$EXPANDED" in 1|on|yes|true) EXPANDED=1 ;; *) EXPANDED=0 ;; esac
}
write_state() { [ -n "${SW_STATE:-}" ] && printf '%s\t%s\n' "$VIEW" "$EXPANDED" > "$SW_STATE"; }

# ---- row builders ----------------------------------------------------------
# Each public row is exactly "<target>\t<search-display>\t<meta-display>".
# One list-panes call is the canonical server snapshot for a render. It includes
# the render-time active pane for every window/session so structural rows never
# need late-bound coordinates or per-window tmux calls.
live_pane_snapshot() {
  local raw
  raw="$(tmux list-panes -a -F \
    "#{pane_id}${SEP}#{session_name}${SEP}#{session_id}${SEP}#{window_id}${SEP}#{window_index}${SEP}#{window_name}${SEP}#{window_active}${SEP}#{pane_index}${SEP}#{pane_active}${SEP}#{pane_title}${SEP}#{pane_current_command}${SEP}#{pane_current_path}" 2>/dev/null)" || return 1
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
        id=$1; session=clean($2); sid=$3; wid=$4; widx=clean($5)
        window=clean($6); winactive=$7; pidx=clean($8); paneactive=$9
        title=clean($10); cmd=clean($11); path=spath(clean($12))
        if (title == "") title=cmd
        print id, session, sid, wid, widx, window, winactive, pidx, paneactive, title, cmd, path
      }
    '
}

# Merge the three AI evidence sources into one row per pane:
#   pane \t sev \t glyph \t word \t kind \t text \t epoch
# sev: 1 unread ACTION, 2 waiting/blocked, 3 unread DONE/NOTICE (or read DONE),
# 4 working, 5 idle. Precedence: an unread mark outranks live state; a live
# blocked/waiting signal outranks a stale registry working; a live working
# verdict contradicts a registry waiting (the scanner heals the row itself
# once the activity holds for two scans). Plain text only — list builders add
# their own colors by sev.
ai_merged() {
  local marks=/dev/null reg=/dev/null livef=/dev/null
  [ -r "$NEEDINPUT_FILE" ] && marks="$NEEDINPUT_FILE"
  [ -r "$REGISTRY_FILE" ] && reg="$REGISTRY_FILE"
  [ -r "$LIVE_FILE" ] && livef="$LIVE_FILE"
  LC_ALL=C awk -F '\t' -v OFS='\t' -v mp="$marks" -v rp="$reg" -v lp="$livef" '
    FILENAME == mp && NF >= 5 && $1 ~ /^%[0-9]+$/ {
      p=$1; l=tolower($3 " " $5)
      if (l ~ /(finished|your turn|turn complete|task complete|done|任务完成|完成)/) { msev[p]=3; mword[p]="DONE" }
      else if (l ~ /(needs approval|needs your permission|needs input|waiting.*input|waiting on you|wait.*input|permission|approval|action required|approve|拿不准|需要你|需要.*许可|需要.*批准|等待.*输入)/) { msev[p]=1; mword[p]="ACTION" }
      else { msev[p]=3; mword[p]="NOTICE" }
      mkind[p]=$3; mtext[p]=$5; mepoch[p]=$2+0; next
    }
    FILENAME == rp && NF >= 9 {
      if ($4 == "-") next
      p=$4; e=$6+0
      if (!(p in repoch) || e >= repoch[p]) { repoch[p]=e; rstate[p]=$7; rkind[p]=$1 }
      next
    }
    FILENAME == lp && NF >= 5 {
      lkind[$1]=$2; lstate[$1]=$3; ltext[$1]=$4; lepoch[$1]=$5+0; next
    }
    END {
      for (p in mtext)  panes[p]=1
      for (p in rstate) panes[p]=1
      for (p in lstate) panes[p]=1
      for (p in panes) {
        sev=""; glyph=""; word=""; kind=""; text=""; epoch=0
        if (p in mtext) {
          sev=msev[p]; word=mword[p]; kind=mkind[p]; text=mtext[p]; epoch=mepoch[p]
          glyph=(msev[p]==1 ? "⚠" : (mword[p]=="DONE" ? "✓" : "!"))
        } else if ((p in lstate) && lstate[p] == "blocked") {
          sev=2; glyph="⚠"; word="BLOCKED"; kind=lkind[p]; text=ltext[p]; epoch=lepoch[p]
        } else if ((p in rstate) && rstate[p] == "waiting" && !((p in lstate) && lstate[p] == "working")) {
          sev=2; glyph="⚠"; word="WAITING"; kind=rkind[p]; text=rkind[p] " waiting"; epoch=repoch[p]
        } else if ((p in lstate) && lstate[p] == "working") {
          sev=4; glyph="◐"; word="WORKING"; kind=lkind[p]; text=ltext[p]; epoch=lepoch[p]
        } else if ((p in lstate) && lstate[p] == "stalled") {
          sev=5; glyph="·"; word="IDLE"; kind=lkind[p]; text=ltext[p]; epoch=lepoch[p]
        } else if (p in rstate) {
          if (rstate[p] == "done")         { sev=3; glyph="✓"; word="DONE" }
          else if (rstate[p] == "waiting") { sev=2; glyph="⚠"; word="WAITING" }
          else if (rstate[p] == "stalled") { sev=5; glyph="·"; word="IDLE" }
          else                             { sev=4; glyph="◐"; word="WORKING" }
          kind=rkind[p]; text=rkind[p] " " rstate[p]; epoch=repoch[p]
        }
        if (sev != "") print p, sev, glyph, word, kind, text, epoch
      }
    }
  ' "$marks" "$reg" "$livef"
}

# colored glyph for a severity; needs the caller awk's color vars
# (defined here as documentation: 1 magenta, 2 yellow, 3 green, 4 cyan, 5 dim)

list_tree() {
  local live merged
  live="$(live_pane_snapshot)" || return 1
  merged="$(ai_merged)"
  printf '%s\n%s\n' "$live" "$merged" | LC_ALL=C awk -F '\t' -v OFS='\t' -v expanded="$EXPANDED" \
    -v picker="${TMUX_RADAR_PICKER_ROWS:-0}" -v ZWSP="$ZWSP" \
    -v C="$C" -v Y="$Y" -v G="$G" -v M="$M" -v B="$B" -v D="$D" -v R="$R" '
    function cg(sev, glyph) { return (sev==1 ? M glyph R : sev==2 ? Y glyph R : sev==3 ? G glyph R : sev==4 ? C glyph R : D glyph R) }
    function runtime_meta(count, cmd, path, show_count,    text) {
      text=""
      if (show_count && count > 1) text=count "p"
      if (cmd != "") text=text (text != "" ? " · " : "") cmd
      if (path != "") text=text (text != "" ? " · " : "") path
      return D text R
    }
    function badge_for(link,    i, raw, s, c1, c2, c3, c4, out, e) {
      c1=c2=c3=c4=0
      for (i=1; i<=pn[link]; i++) {
        raw=ptarget[porder[link,i]]
        # sev 5 (idle) is deliberately not badged: an idle agent pane reads as
        # a free shell, not as work that needs you
        if (raw in aisev) { s=aisev[raw]; if (s==1) c1++; else if (s==2) c2++; else if (s==3) c3++; else if (s==4) c4++ }
      }
      out=""; e=0
      if (c1 && e<2) { out=out " " cg(1,"⚠") (c1>1?c1:""); e++ }
      if (c2 && e<2) { out=out " " cg(2,"⚠") (c2>1?c2:""); e++ }
      if (c3 && e<2) { out=out " " cg(3,"✓") (c3>1?c3:""); e++ }
      if (c4 && e<2) { out=out " " cg(4,"◐") (c4>1?c4:""); e++ }
      sub(/^ /, "", out)
      return out
    }
    function picker_session_name(name,    weighted) {
      if (picker != 1) return name
      # fzf cannot weight a hidden field separately from the displayed fields.
      # Zero-width separators preserve the rendered label while making an exact
      # window-name match outrank an identical structural session label.
      weighted=name
      gsub(/[A-Za-z0-9]/, "&" ZWSP, weighted)
      return weighted
    }
    function session_row(sk) {
      return C "▾" R " " B picker_session_name(sname[sk]) R
    }
    function session_meta(sk) {
      return D wn[sk] "w" R
    }
    function window_row(link, branch) {
      return D "  " branch R " " Y sprintf("%2s", widx[link]) R " " wname[link]
    }
    function window_meta(link,    b) {
      b=badge_for(link)
      return (b != "" ? b " " : "") runtime_meta(pn[link], wcmd[link], wpath[link], 1)
    }
    function pane_row(pk, stem, branch,    raw, g) {
      raw=ptarget[pk]; g=((raw in aisev) && aisev[raw] != 5 ? cg(aisev[raw], aiglyph[raw]) " " : "")
      return D stem branch R " " Y pidx[pk] R " " g ptitle[pk]
    }
    NF >= 10 {
      p=$1; s=$2; sk=$3; w=$4; link=sk SUBSEP w; pk=link SUBSEP p
      if (!(sk in seen_s)) {
        seen_s[sk]=1; sorder[++sn]=sk; sname[sk]=s; starget[sk]=p
      }
      if ($7 == 1 && $9 == 1) starget[sk]=p
      if (!(link in seen_link)) {
        seen_link[link]=1; worder[sk, ++wn[sk]]=link
        widx[link]=$5; wname[link]=$6; wtarget[link]=p
        wcmd[link]=$11; wpath[link]=$12
      }
      if ($9 == 1) {
        wtarget[link]=p; wcmd[link]=$11; wpath[link]=$12
      }
      if (pk in seen_pane_link) next
      seen_pane_link[pk]=1; porder[link, ++pn[link]]=pk; ptarget[pk]=p
      pidx[pk]=$8
      ptitle[pk]=$10; pcmd[pk]=$11; ppath[pk]=$12
      next
    }
    NF == 7 { aisev[$1]=$2+0; aiglyph[$1]=$3; next }
    END {
      for (si=1; si<=sn; si++) {
        sk=sorder[si]
        print starget[sk], session_row(sk), session_meta(sk)
        for (wi=1; wi<=wn[sk]; wi++) {
          link=worder[sk, wi]; wb=(wi == wn[sk] ? "└─" : "├─")
          print wtarget[link], window_row(link, wb), window_meta(link)
          if (expanded != 1) continue
          stem=(wi == wn[sk] ? "      " : "  │   ")
          for (pi=1; pi<=pn[link]; pi++) {
            pk=porder[link, pi]; pb=(pi == pn[link] ? "└─" : "├─")
            print ptarget[pk], pane_row(pk, stem, pb), runtime_meta(0, pcmd[pk], ppath[pk], 0)
          }
        }
      }
    }
  '
}

list_recent() {
  local live merged mfile="$WINDOW_MRU_FILE"
  live="$(live_pane_snapshot)" || return 1
  merged="$(ai_merged)"
  [ -r "$mfile" ] || mfile=/dev/null
  { printf '%s\n' "$live"; printf '%s\n' "$merged"; cat "$mfile"; } |
  LC_ALL=C awk -F '\t' -v OFS='\t' -v expanded="$EXPANDED" -v C="$C" -v Y="$Y" -v G="$G" -v M="$M" -v D="$D" -v R="$R" '
    function cg(sev, glyph) { return (sev==1 ? M glyph R : sev==2 ? Y glyph R : sev==3 ? G glyph R : sev==4 ? C glyph R : D glyph R) }
    function badge_for(w,    i, pk, s, c1, c2, c3, c4, out, e) {
      c1=c2=c3=c4=0
      for (i=1; i<=pn[w]; i++) {
        pk=porder[w, i]
        # sev 5 (idle) is deliberately not badged: an idle agent pane reads as
        # a free shell, not as work that needs you
        if (pk in aisev) { s=aisev[pk]; if (s==1) c1++; else if (s==2) c2++; else if (s==3) c3++; else if (s==4) c4++ }
      }
      out=""; e=0
      if (c1 && e<2) { out=out " " cg(1,"⚠") (c1>1?c1:""); e++ }
      if (c2 && e<2) { out=out " " cg(2,"⚠") (c2>1?c2:""); e++ }
      if (c3 && e<2) { out=out " " cg(3,"✓") (c3>1?c3:""); e++ }
      if (c4 && e<2) { out=out " " cg(4,"◐") (c4>1?c4:""); e++ }
      sub(/^ /, "", out)
      return out
    }
    function emit_window(w,    title, p, i, b, g) {
      if (shown[w]++) return
      p=wtarget[w]; title=(ptitle[p] != "" && ptitle[p] != wname[w] ? "/" ptitle[p] : "")
      b=badge_for(w)
      print p, wname[w] " " C session[w] ":" widx[w] title R, (b != "" ? b " " : "") D pcmd[p] " · " ppath[p] R
      if (expanded != 1) return
      for (i=1; i<=pn[w]; i++) {
        p=porder[w, i]; title=(ptitle[p] != "" ? "/" ptitle[p] : "")
        g=((p in aisev) && aisev[p] != 5 ? cg(aisev[p], aiglyph[p]) " " : "")
        print p, "   " wname[w] " " C session[w] ":" widx[w] "." pidx[p] g title R, D pcmd[p] " · " ppath[p] R
      }
    }
    NF >= 10 {
      p=$1; w=$4
      if (!(w in seen_w)) {
        seen_w[w]=1; canonical[++walln]=w
        chosen_session[w]=$3; session[w]=$2; widx[w]=$5; wname[w]=$6; wtarget[w]=p
      }
      if ($3 != chosen_session[w]) next
      if ($9 == 1) wtarget[w]=p
      if (seen_window_pane[w, p]++) next
      porder[w, ++pn[w]]=p; pidx[p]=$8; ptitle[p]=$10; pcmd[p]=$11; ppath[p]=$12
      next
    }
    NF == 7 { aisev[$1]=$2+0; aiglyph[$1]=$3; next }
    NF >= 1 && $1 != "" { recent[++rn]=$1 }
    END {
      for (i=rn; i>=1; i--) if (recent[i] in seen_w) emit_window(recent[i])
      for (i=1; i<=walln; i++) emit_window(canonical[i])
    }
  '
}

list_inbox() {
  local live marks=/dev/null now
  live="$(live_pane_snapshot)" || return 1
  [ -r "$NEEDINPUT_FILE" ] && marks="$NEEDINPUT_FILE"
  now="$(date +%s)"
  LC_ALL=C awk -F '\t' -v OFS='\t' -v now="$now" -v C="$C" -v Y="$Y" -v G="$G" -v M="$M" -v D="$D" -v R="$R" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function clean(s) { gsub(/[[:cntrl:]]/, " ", s); gsub(/[[:space:]][[:space:]]+/, " ", s); return trim(s) }
    function level_for(src, label,    l) {
      l=tolower(src " " label)
      if (l ~ /(finished|your turn|turn complete|task complete|done|任务完成|完成)/) return "done"
      if (l ~ /(needs approval|needs your permission|needs input|waiting.*input|waiting on you|wait.*input|permission|approval|action required|approve|拿不准|需要你|需要.*许可|需要.*批准|等待.*输入)/) return "action"
      return "notice"
    }
    function rank(l) { return (l == "action" ? 1 : (l == "done" ? 2 : 3)) }
    function word(l) { return (l == "action" ? "ACTION" : (l == "done" ? "DONE" : "NOTICE")) }
    function icon(l) { return (l == "action" ? "⚠" : (l == "done" ? "✓" : "!")) }
    function color(l) { return (l == "action" ? M : (l == "done" ? G : Y)) }
    function age(sec) {
      if (sec < 0) sec=0
      if (sec < 60) return sec "s"
      if (sec < 3600) return int(sec/60) "m"
      if (sec < 86400) return int(sec/3600) "h"
      return int(sec/86400) "d"
    }
    NR==FNR {
      p=$1
      if (p in live) next
      live[p]=1; order[++n]=p
      session[p]=$2; widx[p]=$5; wname[p]=$6; pidx[p]=$8
      ptitle[p]=$10; pcmd[p]=$11; ppath[p]=$12
      next
    }
    NF >= 5 && $1 ~ /^%[0-9]+$/ {
      p=$1
      if (!(p in live)) next
      marked[p]=1; epoch[p]=$2+0; source[p]=clean($3); label[p]=clean($5)
      saved[p]=(NF >= 6 ? clean($6) : ""); level[p]=level_for(source[p], label[p])
    }
    END {
      cn=0
      for (i=1; i<=n; i++) {
        p=order[i]; if (!(p in marked)) continue
        cn++; cr[cn]=rank(level[p]); ce[cn]=epoch[p]; cp[cn]=p
      }
      for (i=2; i<=cn; i++) {
        r=cr[i]; e=ce[i]; p=cp[i]
        for (j=i-1; j>=1 && (cr[j] > r || (cr[j] == r && ce[j] < e)); j--) {
          cr[j+1]=cr[j]; ce[j+1]=ce[j]; cp[j+1]=cp[j]
        }
        cr[j+1]=r; ce[j+1]=e; cp[j+1]=p
      }
      for (i=1; i<=cn; i++) {
        p=cp[i]; title=(saved[p] != "" ? saved[p] : ptitle[p])
        sub(/^(⚠|✓|!|·) /, "", title)
        title=(title != "" && title != wname[p] ? "/" title : "")
        badge=color(level[p]) icon(level[p]) " " word(level[p]) R
        hint=source[p] (source[p] != "" && label[p] != "" ? ": " : "") label[p]
        tail=(epoch[p] > 0 ? " · " age(now-epoch[p]) : "")
        print p, wname[p] " " C session[p] ":" widx[p] "." pidx[p] title R, badge " " hint " " D "· " pcmd[p] " · " ppath[p] tail R
      }
    }
  ' <(printf '%s\n' "$live") "$marks"
}

list_agents() {
  local live merged now
  live="$(live_pane_snapshot)" || return 1
  merged="$(ai_merged)"
  now="$(date +%s)"
  printf '%s\n%s\n' "$live" "$merged" | LC_ALL=C awk -F '\t' -v OFS='\t' -v now="$now" \
    -v C="$C" -v Y="$Y" -v G="$G" -v M="$M" -v B="$B" -v D="$D" -v R="$R" '
    function cg(sev, glyph) { return (sev==1 ? M glyph R : sev==2 ? Y glyph R : sev==3 ? G glyph R : sev==4 ? C glyph R : D glyph R) }
    function age(sec) {
      if (sec < 0) sec=0
      if (sec < 60) return sec "s"
      if (sec < 3600) return int(sec/60) "m"
      if (sec < 86400) return int(sec/3600) "h"
      return int(sec/86400) "d"
    }
    NF >= 10 {
      p=$1
      if (p in live) next
      live[p]=1; order[++n]=p
      session[p]=$2; widx[p]=$5; wname[p]=$6; pidx[p]=$8
      ptitle[p]=$10; pcmd[p]=$11; ppath[p]=$12
      next
    }
    NF == 7 {
      if (!($1 in live)) next
      asev[$1]=$2+0; aglyph[$1]=$3; aword[$1]=$4; akind[$1]=$5; atext[$1]=$6; aepoch[$1]=$7+0
      next
    }
    END {
      cn=0
      for (i=1; i<=n; i++) {
        p=order[i]; if (!(p in asev)) continue
        # the board is for the live fleet: blocked/waiting and working panes,
        # plus unread ACTION events. DONE/NOTICE belong to the Inbox review
        # queue and IDLE panes are just free shells — both stay out.
        if (asev[p] != 1 && asev[p] != 2 && asev[p] != 4) continue
        cn++; cr[cn]=asev[p]; ce[cn]=aepoch[p]; cp[cn]=p
      }
      # severity asc, then newest first (insertion sort over a tiny set)
      for (i=2; i<=cn; i++) {
        r=cr[i]; e=ce[i]; p=cp[i]
        for (j=i-1; j>=1 && (cr[j] > r || (cr[j] == r && ce[j] < e)); j--) {
          cr[j+1]=cr[j]; ce[j+1]=ce[j]; cp[j+1]=cp[j]
        }
        cr[j+1]=r; ce[j+1]=e; cp[j+1]=p
      }
      for (i=1; i<=cn; i++) {
        p=cp[i]
        word=aword[p]
        primary=sprintf("%s " B "%-8s" R " %s " C "%s:%s.%s" R, cg(asev[p], aglyph[p]), word, wname[p], session[p], widx[p], pidx[p])
        tail=(aepoch[p] > 0 ? " · " age(now-aepoch[p]) : "")
        text=atext[p]
        meta=sprintf("%s%s%s " D "· %s · %s%s" R, akind[p], (text != "" ? " · " : ""), text, pcmd[p], ppath[p], tail)
        print p, primary, meta
      }
    }
  '
}

do_list() {  # do_list [view] [expanded]
  local rows list_fn
  read_state "${1:-}" "${2:-}"
  case "$VIEW" in
    recent) list_fn=list_recent ;;
    inbox) list_fn=list_inbox ;;
    agents) list_fn=list_agents ;;
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
  local pane="$1" mark="" reg="" live="" level="" icon='·' color="$D" parts kind sid
  local m_epoch="" m_src="" m_key="" m_label=""
  local r_kind="" r_key="" r_pid="" r_started="" r_state="" r_cwd="" alive
  local l_state="" l_kind="" l_title=""
  [ -n "$pane" ] || return 0
  [ -r "$NEEDINPUT_FILE" ] && mark="$(awk -F '\t' -v p="$pane" '$1 == p { print; exit }' "$NEEDINPUT_FILE" 2>/dev/null || true)"
  # a pane can carry several session rows (parent + adopted/bg children); the
  # newest event is the only state worth showing
  [ -r "$REGISTRY_FILE" ] && reg="$(awk -F '\t' -v p="$pane" '$4 == p && ($6+0) >= max { max=$6+0; r=$0 } END { if (r != "") print r }' "$REGISTRY_FILE" 2>/dev/null || true)"
  [ -r "$LIVE_FILE" ] && live="$(awk -F '\t' -v p="$pane" '$1 == p { print; exit }' "$LIVE_FILE" 2>/dev/null || true)"
  [ -n "$mark" ] || [ -n "$reg" ] || [ -n "$live" ] || return 0
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
  if [ -z "$mark" ] && [ -z "$reg" ]; then
    # scanner-only pane: no hook ever fired for it
    l_state="$(printf '%s' "$live" | cut -f3 | sanitize_text)"
    l_kind="$(printf '%s' "$live" | cut -f2 | sanitize_text)"
    l_title="$(printf '%s' "$live" | cut -f4 | sanitize_text)"
    printf '%s%s %s · %s (live scan)%s\n' "$D" "${l_kind:-ai}" "${l_state:-?}" "$l_title" "$R"
    printf '%s────────────────────────────────────────%s\n' "$D" "$R"
    return 0
  fi
  parts="$icon ${kind:-?}"
  [ -n "$r_state" ] && parts="$parts · $r_state"
  if [ -n "$live" ]; then
    l_state="$(printf '%s' "$live" | cut -f3 | sanitize_text)"
    [ -n "$l_state" ] && [ "$l_state" != "$r_state" ] && parts="$parts · live:$l_state"
  fi
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
    recent) [ "$EXPANDED" = 1 ] && printf 'Recent+> ' || printf 'Recent> ' ;;
    inbox) printf 'Inbox> ' ;;
    agents) printf 'Agents> ' ;;
    tree) [ "$EXPANDED" = 1 ] && printf 'Tree+> ' || printf 'Tree> ' ;;
  esac
}

_header() {
  if [ "$VIEW" = inbox ] && [ -n "${SW_ROWS:-}" ] && [ ! -s "$SW_ROWS" ]; then
    printf '%s · ' 'Inbox clear — no unread AI event needs you.'
  fi
  if [ "$VIEW" = agents ] && [ -n "${SW_ROWS:-}" ] && [ ! -s "$SW_ROWS" ]; then
    printf '%s · ' 'Agents clear — nothing blocked, waiting, or working.'
  fi
  printf '%s' 'C-r Recent · C-i Inbox · C-a Agents · C-t Tree'
  printf '%s' ' · C-e panes · A-1..9 jump · A-p preview · Enter switch'
}

_fzf_version_supported() {
  local raw version major minor
  raw="$($1 --version 2>/dev/null || true)"
  version="${raw%% *}"
  case "$version" in [0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) ;; *) return 0 ;; esac
  major="${version%%.*}"
  minor="${version#*.}"; minor="${minor%%.*}"
  case "$major:$minor" in *[!0-9:]*|:*) return 0 ;; esac
  [ "$major" -gt 0 ] || [ "$minor" -ge 59 ]
}

_reload_picker() {  # publish VIEW/EXPANDED as one coherent fzf transaction
  local focus_pos="${1:-1}" rows_tmp reload_cmd header
  if [ -z "${SW_ROWS:-}" ] || [ -z "${SW_ERROR:-}" ]; then
    printf 'abort\n'
    return 0
  fi
  # Every reload observes a completed cleanup pass before publishing its rows.
  if ! "$SCRIPT_DIR/needinput-notify.sh" tick >/dev/null 2>&1; then
    : > "$SW_ERROR"
    printf 'abort\n'
    return 0
  fi
  rows_tmp="$(mktemp "${SW_ROWS}.XXXXXX")" || {
    : > "$SW_ERROR"
    printf 'abort\n'
    return 0
  }
  if ! TMUX_RADAR_PICKER_ROWS=1 "$SELF" list "$VIEW" "$EXPANDED" > "$rows_tmp" 2>/dev/null || ! mv "$rows_tmp" "$SW_ROWS"; then
    rm -f "$rows_tmp" 2>/dev/null || true
    : > "$SW_ERROR"
    printf 'abort\n'
    return 0
  fi
  write_state
  printf -v reload_cmd 'cat %q' "$SW_ROWS"
  header="$(_header)"
  # fzf reads transform actions line-by-line and ignores a final unterminated
  # record even when the producer command itself succeeded.
  printf 'reload-sync(%s)+change-prompt(%s)+change-header(%s)+pos(%s)\n' \
    "$reload_cmd" "$(_prompt)" "$header" "$focus_pos"
}

cmd_set_view() {  # fzf transform: switch view, reload, repoint prompt
  local focus_pos=1
  read_state
  VIEW="$(normalize_view "${1:-recent}")"
  [ "$VIEW" = recent ] && focus_pos=2
  _reload_picker "$focus_pos"
}

cmd_toggle_expand() {  # fzf transform: toggle pane leaves in Recent/Tree
  read_state
  case "$VIEW" in inbox|agents) printf 'bell\n'; return 0 ;; esac
  [ "$EXPANDED" = 1 ] && EXPANDED=0 || EXPANDED=1
  _reload_picker
}

cmd_jump() {  # fzf transform: accept only an existing visible result
  local n="${1:-0}" count="${FZF_MATCH_COUNT:-0}"
  case "$n" in [1-9]) ;; *) printf 'bell\n'; return 0 ;; esac
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -ge "$n" ]; then
    printf 'pos(%s)+accept\n' "$n"
  else
    printf 'bell\n'
  fi
}

do_menu() {
  local initial_view="${1:-}"
  local fzf preview_pos follow preview_win selected target list_file fzf_rc reload_failed header
  local -a fzf_args
  fzf="$(command -v fzf || true)"
  if [ -z "$fzf" ]; then
    printf '%s\n' 'fzf not found; install fzf and reopen tmux-radar' >&2
    tmux display-message 'tmux-radar: fzf not found' >/dev/null 2>&1 || true
    return 1
  fi
  VIEW="$(normalize_view "${initial_view:-$(opt @radar-default-view recent)}")"
  case "$(opt @radar-expand-panes off)" in on|yes|true|1) EXPANDED=1 ;; *) EXPANDED=0 ;; esac
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
  if ! _fzf_version_supported "$fzf"; then
    rm -f "$SW_STATE" 2>/dev/null || true
    printf '%s\n' 'fzf 0.59 or newer is required; upgrade fzf and reopen tmux-radar' >&2
    tmux display-message 'tmux-radar: fzf 0.59+ required' >/dev/null 2>&1 || true
    return 1
  fi

  # Relevance applies consistently; input order is the final tie break, which
  # preserves each view's canonical order for an empty query.
  fzf_args=(--ansi --delimiter=$'\t' --with-nth=2.. --cycle '--tiebreak=begin,index')
  # Recent is a switch-back surface: row 1 is the current MRU window and row 2
  # is the previous window. Wait for the list before placing the initial cursor.
  [ "$VIEW" = recent ] && fzf_args+=(--sync '--bind=start:pos(2)')

  list_file="$(mktemp "${STATE_DIR}/.rows.XXXXXX")"
  SW_ROWS="$list_file"; export SW_ROWS
  SW_ERROR="${SW_STATE}.error"; export SW_ERROR
  if ! TMUX_RADAR_PICKER_ROWS=1 "$SELF" list > "$list_file" 2>/dev/null; then
    rm -f "$SW_STATE" "$SW_ERROR" "$list_file" 2>/dev/null || true
    printf '%s\n' 'unable to list panes; reopen the switcher' >&2
    tmux display-message 'tmux-radar: unable to list panes; reopen the switcher' >/dev/null 2>&1 || true
    return 1
  fi
  header="$(_header)"

  if selected="$(
    "$fzf" \
      "${fzf_args[@]}" \
      --layout=reverse --prompt="$(_prompt)" \
      --header="$header" \
      --preview="$SELF preview {1}" --preview-window="$preview_win" \
      --bind='change:pos(1)' \
      --bind="ctrl-t:transform($SELF set-view tree)" \
      --bind="ctrl-r:transform($SELF set-view recent)" \
      --bind="ctrl-i:transform($SELF set-view inbox)" \
      --bind="ctrl-a:transform($SELF set-view agents)" \
      --bind="ctrl-e:transform($SELF toggle-expand)" \
      --bind="alt-1:transform($SELF jump 1)" \
      --bind="alt-2:transform($SELF jump 2)" \
      --bind="alt-3:transform($SELF jump 3)" \
      --bind="alt-4:transform($SELF jump 4)" \
      --bind="alt-5:transform($SELF jump 5)" \
      --bind="alt-6:transform($SELF jump 6)" \
      --bind="alt-7:transform($SELF jump 7)" \
      --bind="alt-8:transform($SELF jump 8)" \
      --bind="alt-9:transform($SELF jump 9)" \
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
  list)          do_list "${2:-}" "${3:-}" ;;
  preview)       do_preview "${2:-}" ;;
  set-view)      cmd_set_view "${2:-recent}" ;;
  toggle-expand) cmd_toggle_expand ;;
  jump)          cmd_jump "${2:-}" ;;
  last-pane)     cmd_last_pane ;;
  menu | *)      do_menu "${2:-}" ;;
esac

#!/usr/bin/env bash
# Install / uninstall the AI-status hooks for Claude Code and Codex so they flag
# action-required prompts and finished-turn notices in tmux.
#
# Edits, idempotently and with a timestamped backup:
#   ~/.claude/settings.json   (Claude hooks)
#   ~/.codex/config.toml      (Codex trust marker + legacy notify fallback)
#   ~/.codex/hooks.json       (Codex native hooks)
#
# Usage: install-hooks.sh [install|uninstall|status]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTIFY="${TMUX_RADAR_NOTIFY:-${TMUX_SWITCHER_NOTIFY:-$SCRIPT_DIR/needinput-notify.sh}}"
CODEX_WRAP="${TMUX_RADAR_CODEX_WRAP:-${TMUX_SWITCHER_CODEX_WRAP:-$SCRIPT_DIR/codex-notify-wrap.sh}}"
CLAUDE_SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
CODEX_CONFIG="${CODEX_CONFIG:-$HOME/.codex/config.toml}"
CODEX_HOOKS_JSON="${CODEX_HOOKS_JSON:-$HOME/.codex/hooks.json}"

# NOTE: SessionEnd is intentionally NOT hooked. It fires the instant a session
# ends — which immediately follows Stop for short-lived / print-mode / background
# runs — so a SessionEnd clear would wipe the "finished" mark the moment a session
# ended. Marks are cleared when you navigate to the window (session-window-changed
# hook) and dead panes are filtered from the view.
CLAUDE_EVENTS=(Notification Stop UserPromptSubmit)
CLAUDE_SUBCMDS=(claude-mark claude-stop claude-clear)
CODEX_EVENTS=(PermissionRequest Stop UserPromptSubmit)
CODEX_NOTIFY_JSON="[\"$NOTIFY\", \"codex\"]"
CODEX_HOOK_CMD="$NOTIFY codex-hook"
CODEX_HOOK_TIMEOUT=5
CODEX_HOOK_STATUS="tmux-radar lifecycle bridge"
CODEX_HOOK_BEGIN="# BEGIN tmux-radar Codex hooks"
CODEX_HOOK_END="# END tmux-radar Codex hooks"

RADAR_TS="$(date +%Y%m%d%H%M%S)"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "  $*"; }
need_jq() { command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"; }

toml_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

backup_file() {
  local path="$1"
  [ -f "$path" ] || return 0
  cp "$path" "$path.bak.$RADAR_TS"
}

TXN_DIR=""
TXN_COMMITTED=0
TXN_PATHS=()

transaction_restore() {
  local i path
  set +e
  i=0
  for path in "${TXN_PATHS[@]}"; do
    if [ -f "$TXN_DIR/$i.exists" ]; then
      mkdir -p "$(dirname "$path")"
      cp "$TXN_DIR/$i.data" "$path"
    else
      rm -f "$path"
    fi
    i=$((i + 1))
  done
}

transaction_cleanup() {
  [ -n "$TXN_DIR" ] && rm -rf "$TXN_DIR"
  TXN_DIR=""
}

transaction_exit() {
  local rc=$?
  trap - EXIT HUP INT TERM
  if [ "$TXN_COMMITTED" -ne 1 ]; then
    transaction_restore
  fi
  transaction_cleanup
  exit "$rc"
}

transaction_start() {
  local path i=0
  TXN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tmux-radar-hooks.XXXXXX")" || die "cannot create hook transaction"
  TXN_COMMITTED=0
  TXN_PATHS=("$@")
  for path in "${TXN_PATHS[@]}"; do
    if [ -f "$path" ]; then
      cp "$path" "$TXN_DIR/$i.data"
      : > "$TXN_DIR/$i.exists"
    fi
    i=$((i + 1))
  done
  trap transaction_exit EXIT
  trap 'exit 130' HUP INT TERM
}

transaction_commit() {
  TXN_COMMITTED=1
  trap - EXIT HUP INT TERM
  transaction_cleanup
}

append_marker_block() {
  local block_file="$1" marker_file="$2"
  cat "$block_file"
  if [ -s "$marker_file" ]; then
    printf '\n%s\n' "$CODEX_HOOK_BEGIN"
    cat "$marker_file"
    printf '%s\n' "$CODEX_HOOK_END"
  fi
}

strip_marker_block() {
  local path="$1"
  awk -v begin="$CODEX_HOOK_BEGIN" -v end="$CODEX_HOOK_END" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$path"
}

codex_event_label() {
  case "$1" in
    PermissionRequest) printf 'permission_request' ;;
    Stop) printf 'stop' ;;
    UserPromptSubmit) printf 'user_prompt_submit' ;;
    *) die "unknown Codex event: $1" ;;
  esac
}

ensure_codex_files() {
  mkdir -p "$(dirname "$CODEX_CONFIG")" "$(dirname "$CODEX_HOOKS_JSON")"
  [ -f "$CODEX_CONFIG" ] || printf 'notify = %s\n' "$CODEX_NOTIFY_JSON" > "$CODEX_CONFIG"
  [ -f "$CODEX_HOOKS_JSON" ] || printf '{"hooks":{}}\n' > "$CODEX_HOOKS_JSON"
}

validate_codex_hooks_json() {
  need_jq
  [ -f "$CODEX_HOOKS_JSON" ] || return 0
  jq empty "$CODEX_HOOKS_JSON" >/dev/null 2>&1 || die "$CODEX_HOOKS_JSON is not valid JSON"
}

codex_has_notify() {
  [ -f "$CODEX_CONFIG" ] || return 1
  grep -qF "codex-notify-wrap.sh" "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh", "codex' "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh","codex' "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh\", \"codex' "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh\",\"codex' "$CODEX_CONFIG" && return 0
  grep -qF 'needinput-notify.sh\\\",\\\"codex' "$CODEX_CONFIG" && return 0
  return 1
}

codex_native_count_for_event() {
  local event="$1"
  [ -f "$CODEX_HOOKS_JSON" ] || { echo 0; return 0; }
  jq -r --arg event "$event" --arg command "$CODEX_HOOK_CMD" --arg status "$CODEX_HOOK_STATUS" --argjson timeout "$CODEX_HOOK_TIMEOUT" '
    [(.hooks[$event] // [])[]?.hooks[]?
      | select(.type == "command" and .command == $command and .timeout == $timeout and .statusMessage == $status)]
    | length
  ' "$CODEX_HOOKS_JSON" 2>/dev/null || echo 0
}

codex_native_position() {
  local event="$1"
  jq -r --arg event "$event" --arg command "$CODEX_HOOK_CMD" --arg status "$CODEX_HOOK_STATUS" --argjson timeout "$CODEX_HOOK_TIMEOUT" '
    (.hooks[$event] // [])
    | to_entries[]
    | .key as $group
    | .value.hooks
    | to_entries[]
    | select(.value.type == "command" and .value.command == $command and .value.timeout == $timeout and .value.statusMessage == $status)
    | "\($group):\(.key)"
  ' "$CODEX_HOOKS_JSON"
}

codex_trusted_hash() {
  local event="$1" group_index="$2" handler_index="$3" label
  label="$(codex_event_label "$event")"
  jq -c --arg event "$event" --arg event_name "$label" --argjson group_index "$group_index" --argjson handler_index "$handler_index" '
    .hooks[$event][$group_index] as $entry
    | $entry.hooks[$handler_index] as $hook
    | ({event_name:$event_name}
      + (if ($entry.matcher // "") != "" then {matcher:$entry.matcher} else {} end)
      + {hooks:[({type:"command", command:$hook.command, timeout:(($hook.timeout // 600) | if . < 1 then 1 else . end), async:false}
          + (if ($hook.statusMessage // "") != "" then {statusMessage:$hook.statusMessage} else {} end))]})
  ' "$CODEX_HOOKS_JSON" | jq -S -c '.' | shasum -a 256 | awk '{print "sha256:" $1}'
}

build_codex_trust_entries() {
  local event position group_index handler_index trust_key trust_hash
  for event in "${CODEX_EVENTS[@]}"; do
    position="$(codex_native_position "$event")"
    [ -n "$position" ] || continue
    group_index="${position%%:*}"
    handler_index="${position##*:}"
    trust_key="$CODEX_HOOKS_JSON:$(codex_event_label "$event"):$group_index:$handler_index"
    trust_hash="$(codex_trusted_hash "$event" "$group_index" "$handler_index")"
    printf '[hooks.state."%s"]\n' "$(toml_escape "$trust_key")"
    printf 'trusted_hash = "%s"\n\n' "$trust_hash"
  done
}

merge_codex_hooks_json() {
  local mode="$1" tmp
  tmp="$(mktemp "$(dirname "$CODEX_HOOKS_JSON")/.hooks.XXXXXX")" || die "mktemp failed for $CODEX_HOOKS_JSON"
  jq --arg command "$CODEX_HOOK_CMD" --arg status "$CODEX_HOOK_STATUS" --argjson timeout "$CODEX_HOOK_TIMEOUT" --arg mode "$mode" '
    def radar_hook:
      (type == "object") and
      (.type == "command") and
      (.command == $command) and
      (.timeout == $timeout) and
      (.statusMessage == $status) and
      ((.async // false) == false) and
      (((keys_unsorted - ["type","command","timeout","statusMessage","async"]) | length) == 0);
    def radar_group:
      (type == "object") and
      (((keys_unsorted - ["hooks"]) | length) == 0) and
      (((.hooks // []) | type) == "array") and
      (((.hooks // []) | length) == 1) and
      ((.hooks[0] | radar_hook));
    .hooks = (.hooks // {})
    | reduce ["PermissionRequest","Stop","UserPromptSubmit"][] as $event (.;
        .hooks[$event] = ((.hooks[$event] // [])
          | map(select(radar_group | not))
          | if $mode == "install" then
              . + [{hooks:[{type:"command", command:$command, timeout:$timeout, statusMessage:$status}]}]
            else . end
        )
      )
  ' "$CODEX_HOOKS_JSON" > "$tmp" || {
    rm -f "$tmp"
    die "failed to merge $CODEX_HOOKS_JSON"
  }
  backup_file "$CODEX_HOOKS_JSON"
  mv "$tmp" "$CODEX_HOOKS_JSON"
}

install_notify_fallback() {
  local base tmp escaped_wrap
  tmp="$(mktemp "$(dirname "$CODEX_CONFIG")/.config.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  base="$(mktemp "$(dirname "$CODEX_CONFIG")/.config-base.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  strip_marker_block "$CODEX_CONFIG" > "$base"
  if grep -qF "$CODEX_WRAP" "$base"; then
    cp "$base" "$tmp"
    info "Codex notify already integrated (legacy fallback)" >&2
  elif grep -qF "$NOTIFY" "$base"; then
    cp "$base" "$tmp"
    info "Codex notify already integrated (legacy fallback)" >&2
  elif grep -qE '^[[:space:]]*notify[[:space:]]*=[[:space:]]*\[' "$base"; then
    escaped_wrap="$(toml_escape "$CODEX_WRAP")"
    awk -v wrap="$escaped_wrap" '
      BEGIN { inserted = 0 }
      !inserted && /^[[:space:]]*notify[[:space:]]*=[[:space:]]*\[/ {
        open = index($0, "[")
        if (open > 0) {
          print substr($0, 1, open) "\"" wrap "\", " substr($0, open + 1)
          inserted = 1
          next
        }
      }
      { print }
      END { if (!inserted) exit 42 }
    ' "$base" > "$tmp" || {
      rm -f "$base" "$tmp"
      die "could not auto-wrap Codex notify in $CODEX_CONFIG"
    }
    if grep -qF "$CODEX_WRAP" "$tmp"; then
      info "Codex notify -> wrapped existing chain (preserved fallback)" >&2
    else
      rm -f "$base" "$tmp"
      die "could not auto-wrap Codex notify in $CODEX_CONFIG"
    fi
  else
    cat "$base" > "$tmp"
    printf '\nnotify = %s\n' "$CODEX_NOTIFY_JSON" >> "$tmp"
    info "Codex notify -> appended (direct fallback)" >&2
  fi
  cat "$tmp"
  rm -f "$base" "$tmp"
}

remove_notify_fallback() {
  local base tmp escaped_wrap direct_line
  base="$(mktemp "$(dirname "$CODEX_CONFIG")/.config-base.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  tmp="$(mktemp "$(dirname "$CODEX_CONFIG")/.config.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  strip_marker_block "$CODEX_CONFIG" > "$base"
  if grep -qF "$CODEX_WRAP" "$base"; then
    escaped_wrap="$(toml_escape "$CODEX_WRAP")"
    awk -v wrap="$escaped_wrap" '
      BEGIN { removed = 0; needle = "\"" wrap "\"," }
      !removed && /^[[:space:]]*notify[[:space:]]*=/ {
        pos = index($0, needle)
        if (pos > 0) {
          tail = substr($0, pos + length(needle))
          sub(/^[[:space:]]*/, "", tail)
          print substr($0, 1, pos - 1) tail
          removed = 1
          next
        }
      }
      { print }
      END { if (!removed) exit 42 }
    ' "$base" > "$tmp" || {
      rm -f "$base" "$tmp"
      die "could not safely unwrap Codex notify in $CODEX_CONFIG"
    }
    info "unwrapped Codex notify (restored chain)" >&2
  elif grep -qF "$NOTIFY" "$base"; then
    direct_line="notify = $CODEX_NOTIFY_JSON"
    awk -v owned="$direct_line" '
      $0 == owned && !removed { removed = 1; next }
      { print }
      END { if (!removed) exit 42 }
    ' "$base" > "$tmp" || {
      cp "$base" "$tmp"
      info "Codex direct notify was modified; preserved it for manual review" >&2
    }
    if ! grep -qF "$NOTIFY" "$tmp"; then
      info "removed direct Codex notify" >&2
    fi
  else
    cp "$base" "$tmp"
    info "Codex notify not ours / absent" >&2
  fi
  cat "$tmp"
  rm -f "$base" "$tmp"
}

write_codex_config_with_marker() {
  local base_file="$1" marker_file="$2"
  local tmp
  tmp="$(mktemp "$(dirname "$CODEX_CONFIG")/.config-final.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  append_marker_block "$base_file" "$marker_file" > "$tmp"
  backup_file "$CODEX_CONFIG"
  mv "$tmp" "$CODEX_CONFIG"
}

codex_install() {
  local base_file marker_file
  validate_codex_hooks_json
  ensure_codex_files
  merge_codex_hooks_json install
  base_file="$(mktemp "$(dirname "$CODEX_CONFIG")/.config-base.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  marker_file="$(mktemp "$(dirname "$CODEX_CONFIG")/.config-marker.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  install_notify_fallback > "$base_file"
  build_codex_trust_entries > "$marker_file"
  write_codex_config_with_marker "$base_file" "$marker_file"
  rm -f "$base_file" "$marker_file"
  local event
  for event in "${CODEX_EVENTS[@]}"; do
    info "Codex native $event -> $CODEX_HOOK_CMD"
  done
}

codex_uninstall() {
  local base_file marker_file
  if [ ! -f "$CODEX_CONFIG" ] && [ ! -f "$CODEX_HOOKS_JSON" ]; then
    info "no Codex hook configuration"
    return 0
  fi
  if [ -f "$CODEX_HOOKS_JSON" ]; then
    validate_codex_hooks_json
    merge_codex_hooks_json uninstall
    info "removed Codex native hooks from $CODEX_HOOKS_JSON"
  fi
  [ -f "$CODEX_CONFIG" ] || { info "no $CODEX_CONFIG"; return 0; }
  base_file="$(mktemp "$(dirname "$CODEX_CONFIG")/.config-base.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  marker_file="$(mktemp "$(dirname "$CODEX_CONFIG")/.config-marker.XXXXXX")" || die "mktemp failed for $CODEX_CONFIG"
  remove_notify_fallback > "$base_file"
  : > "$marker_file"
  write_codex_config_with_marker "$base_file" "$marker_file"
  rm -f "$base_file" "$marker_file"
  info "removed Codex trust marker"
}

codex_status() {
  local event count
  if [ ! -f "$CODEX_HOOKS_JSON" ]; then
    for event in "${CODEX_EVENTS[@]}"; do
      echo "Codex native $event: not installed"
    done
  elif ! jq empty "$CODEX_HOOKS_JSON" >/dev/null 2>&1; then
    echo "Codex hooks JSON: invalid ($CODEX_HOOKS_JSON)"
  else
    for event in "${CODEX_EVENTS[@]}"; do
      count="$(codex_native_count_for_event "$event")"
      if [ "${count:-0}" -gt 0 ]; then
        echo "Codex native $event: installed (${count})"
      else
        echo "Codex native $event: not installed"
      fi
    done
  fi
  if codex_has_notify; then echo "Codex legacy notify fallback: installed"
  else echo "Codex legacy notify fallback: not installed"; fi
}

claude_install() {
  need_jq
  mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
  [ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
  jq empty "$CLAUDE_SETTINGS" >/dev/null 2>&1 || die "$CLAUDE_SETTINGS is not valid JSON"
  backup_file "$CLAUDE_SETTINGS"
  # Migration: older versions hooked SessionEnd -> claude-clear, which wiped the
  # "finished" mark the moment a session ended. Strip it so upgrades self-heal.
  local mtmp; mtmp="$(mktemp)"
  jq --arg p "$NOTIFY " '
    if (.hooks // {}).SessionEnd then
      .hooks.SessionEnd |= ( map(.hooks |= map(select((.command // "") | startswith($p) | not)))
                             | map(select((.hooks // []) | length > 0)) )
      | if (.hooks.SessionEnd | length) == 0 then del(.hooks.SessionEnd) else . end
    else . end
  ' "$CLAUDE_SETTINGS" > "$mtmp" && mv "$mtmp" "$CLAUDE_SETTINGS"
  local i ev cmd tmp
  for i in "${!CLAUDE_EVENTS[@]}"; do
    ev="${CLAUDE_EVENTS[$i]}"; cmd="$NOTIFY ${CLAUDE_SUBCMDS[$i]}"; tmp="$(mktemp)"
    jq --arg ev "$ev" --arg cmd "$cmd" '
      .hooks //= {} | .hooks[$ev] //= []
      | if any(.hooks[$ev][]?; ((.hooks // [])[]?.command) == $cmd) then .
        else .hooks[$ev] += [ { "hooks": [ { "type": "command", "command": $cmd } ] } ] end
    ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
    info "Claude $ev -> $cmd"
  done
}

claude_uninstall() {
  need_jq
  [ -f "$CLAUDE_SETTINGS" ] || { info "no $CLAUDE_SETTINGS"; return 0; }
  backup_file "$CLAUDE_SETTINGS"
  local tmp; tmp="$(mktemp)"
  jq --arg p "$NOTIFY " '
    if .hooks then
      .hooks |= with_entries(
        .value |= ( map( .hooks |= map(select((.command // "") | startswith($p) | not)) )
                    | map(select((.hooks // []) | length > 0)) )
      ) | .hooks |= with_entries(select((.value | length) > 0))
    else . end
  ' "$CLAUDE_SETTINGS" > "$tmp" && mv "$tmp" "$CLAUDE_SETTINGS"
  info "removed Claude AI-status hooks"
}

claude_status() {
  if command -v jq >/dev/null 2>&1 && [ -f "$CLAUDE_SETTINGS" ]; then
    local c; c="$(jq --arg p "$NOTIFY " '[.hooks // {} | .. | .command? // empty | select(startswith($p))] | length' "$CLAUDE_SETTINGS" 2>/dev/null || echo 0)"
    echo "Claude hooks installed: ${c:-0}/3"
  else echo "Claude settings: (none / jq missing)"; fi
}

[ -x "$NOTIFY" ] || die "$NOTIFY not found/executable"

case "${1:-install}" in
  install)
    echo "Installing tmux-radar AI-status hooks:"
    transaction_start "$CLAUDE_SETTINGS" "$CODEX_CONFIG" "$CODEX_HOOKS_JSON"
    codex_install
    claude_install
    transaction_commit
    echo "Done. Restart Claude/Codex sessions (or open new ones) to pick up the hooks."
    ;;
  uninstall)
    echo "Uninstalling tmux-radar AI-status hooks:"
    transaction_start "$CLAUDE_SETTINGS" "$CODEX_CONFIG" "$CODEX_HOOKS_JSON"
    codex_uninstall
    claude_uninstall
    transaction_commit
    ;;
  status)
    claude_status
    codex_status
    ;;
  *) die "usage: install-hooks.sh [install|uninstall|status]" ;;
esac

#!/usr/bin/env bash
# install-hooks.sh portability + safety tests. Runs entirely against throwaway
# HOME-like dirs; never touches the real ~/.claude, ~/.codex, ~/.config/opencode.
#
# The interesting trick: a `sed` shim on PATH that FAILS on any -i invocation.
# GNU sed reads `-i ''` as "-i" plus an empty script, so BSD-only in-place edits
# would break a Linux install. Running the whole installer under the shim proves
# no such call survives, without needing a Linux box.
# shellcheck disable=SC2034
set -u
WT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/radar-install.XXXXXX)"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
REAL_SED="$(command -v sed)"

# --- the GNU-sed shim ------------------------------------------------------
mkdir -p "$T/bin"
cat > "$T/bin/sed" <<EOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    -i|-i*) echo "sed-shim: refusing '-i' (GNU sed would eat the next arg as its script)" >&2; exit 42 ;;
  esac
done
exec "$REAL_SED" "\$@"
EOF
chmod +x "$T/bin/sed"
export PATH="$T/bin:$PATH"
chk "shim is active (sed -i now fails)" "! sed -i '' 's/a/b/' /dev/null 2>/dev/null"

echo
echo "### lint: no BSD-only in-place edits anywhere in scripts/"
# real code only — a comment explaining why `sed -i` is banned isn't a violation
sed_i_hits() {
  grep -rn --include='*.sh' -E '(^|[^_[:alnum:]])sed[[:space:]]+-i' "$WT/scripts/" 2>/dev/null |
    grep -vE ':[0-9]+:[[:space:]]*#'
}
chk "no 'sed -i' in scripts/ (comments excluded)" "! sed_i_hits | grep -q ."

echo
echo "### install/uninstall round-trip under the shim, from a path with & and #"
# a scripts dir whose path contains sed-hostile characters
SRC="$T/pa#th & dir/scripts"
mkdir -p "$SRC"; cp "$WT/scripts/"*.sh "$SRC/"; cp "$WT/scripts/opencode-tmux-notify.js" "$SRC/"
chmod +x "$SRC/"*.sh
IH="$SRC/install-hooks.sh"
NOTIFY_PATH="$SRC/needinput-notify.sh"

export CLAUDE_SETTINGS="$T/home/.claude/settings.json"
export CODEX_CONFIG="$T/home/.codex/config.toml"
export CODEX_HOOKS_JSON="$T/home/.codex/hooks.json"
export KIMI_CONFIG="$T/home/.kimi-code/config.toml"
export TMUX_RADAR_TEST_KIMI_PRESENT=on
export OPENCODE_CONFIG_DIR="$T/home/.config/opencode"
mkdir -p "$T/home/.claude" "$T/home/.codex" "$T/home/.kimi-code" "$OPENCODE_CONFIG_DIR"

# pre-existing user content that must be preserved
cat > "$CLAUDE_SETTINGS" <<'JSON'
{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}
JSON
cat > "$CODEX_CONFIG" <<'TOML'
model = "gpt-5.3-codex"
notify = ["node", "/opt/other-tool/notify.js"]
TOML
cat > "$KIMI_CONFIG" <<'TOML'
model = "kimi-k2"
# user hook before radar
[[hooks]]
event = "PermissionRequest"
command = "echo user-kimi-hook"
timeout = 9
# user config after hook
max_context = 1000000
TOML
cp "$KIMI_CONFIG" "$T/kimi.user.before"

OUT="$(bash "$IH" install 2>&1)"; RC=$?
chk "install exits 0 under the GNU-sed shim" "[ $RC -eq 0 ]"
chk "install never invoked 'sed -i'" "! printf '%s' \"\$OUT\" | grep -q 'sed-shim'"

chk "claude: 5 hooks installed" "[ \$(jq '[.hooks[]?[]?.hooks[]?.command | select(startswith(\"$NOTIFY_PATH \"))] | length' '$CLAUDE_SETTINGS') -eq 5 ]"
chk "claude: SessionStart -> claude-register" "jq -e '[.hooks.SessionStart[]?.hooks[]?.command] | any(endswith(\"claude-register\"))' '$CLAUDE_SETTINGS' >/dev/null"
chk "claude: SessionEnd -> claude-end" "jq -e '[.hooks.SessionEnd[]?.hooks[]?.command] | any(endswith(\"claude-end\"))' '$CLAUDE_SETTINGS' >/dev/null"
chk "claude: user's own Stop hook preserved" "jq -e '[.hooks.Stop[]?.hooks[]?.command] | any(. == \"echo mine\")' '$CLAUDE_SETTINGS' >/dev/null"
chk "claude: unrelated keys preserved" "[ \$(jq -r .model '$CLAUDE_SETTINGS') = opus ]"

chk "codex: notify chain WRAPPED, not replaced (& and # in path survived)" \
  "grep -q 'other-tool/notify.js' '$CODEX_CONFIG' && grep -qF 'codex-notify-wrap.sh' '$CODEX_CONFIG'"
chk "codex: 3 native hook groups merged" \
  "[ \$(jq '[.hooks.PermissionRequest[], .hooks.Stop[], .hooks.UserPromptSubmit[] | .hooks[]? | select(.command == \"$NOTIFY_PATH codex-hook\")] | length' '$CODEX_HOOKS_JSON') -eq 3 ]"
chk "codex: trust marker written without replacing config" \
  "grep -qF '# BEGIN tmux-radar Codex hooks' '$CODEX_CONFIG'"
chk "kimi: one managed marker block installed" \
  "[ \$(grep -cF '# >>> tmux-radar kimi hooks >>>' '$KIMI_CONFIG') -eq 1 ] && [ \$(grep -cF '# <<< tmux-radar kimi hooks <<<' '$KIMI_CONFIG') -eq 1 ]"
chk "kimi: seven managed event tables installed" \
  "[ \$(awk '/# >>> tmux-radar kimi hooks >>>/{inside=1;next}/# <<< tmux-radar kimi hooks <<</{inside=0} inside && /^event = /{n++} END{print n+0}' '$KIMI_CONFIG') -eq 7 ]"
chk "kimi: all seven official events are present" \
  "[ \$(for ev in PermissionRequest PermissionResult Stop UserPromptSubmit SessionStart SessionEnd Interrupt; do awk '/# >>> tmux-radar kimi hooks >>>/{inside=1;next}/# <<< tmux-radar kimi hooks <<</{inside=0} inside' '$KIMI_CONFIG' | grep -qF \"event = \\\"\$ev\\\"\" || echo missing; done | wc -l | tr -d ' ') -eq 0 ]"
chk "kimi: user hook and surrounding config preserved" \
  "grep -qF 'echo user-kimi-hook' '$KIMI_CONFIG' && grep -qF 'model = \"kimi-k2\"' '$KIMI_CONFIG' && grep -qF 'max_context = 1000000' '$KIMI_CONFIG'"
chk "kimi: shell-safe notifier path reaches kimi-hook" \
  "grep -qF \"needinput-notify.sh' kimi-hook\" '$KIMI_CONFIG'"
chk "opencode: plugin installed" "[ -f '$OPENCODE_CONFIG_DIR/plugins/tmux-radar.js' ]"
chk "opencode: placeholder substituted with the real (&/# laden) path" \
  "grep -qF 'const NOTIFY = \"$NOTIFY_PATH\"' '$OPENCODE_CONFIG_DIR/plugins/tmux-radar.js'"
chk "opencode: plugin is valid JS after substitution" \
  "! command -v node >/dev/null || node --check '$OPENCODE_CONFIG_DIR/plugins/tmux-radar.js' 2>/dev/null"

echo
echo "### idempotency: a second install must not duplicate anything"
bash "$IH" install >/dev/null 2>&1
chk "claude: still exactly 5 hooks after reinstall" "[ \$(jq '[.hooks[]?[]?.hooks[]?.command | select(startswith(\"$NOTIFY_PATH \"))] | length' '$CLAUDE_SETTINGS') -eq 5 ]"
chk "claude: SessionEnd survived the legacy-migration pass" "jq -e '[.hooks.SessionEnd[]?.hooks[]?.command] | any(endswith(\"claude-end\"))' '$CLAUDE_SETTINGS' >/dev/null"
chk "codex: still exactly 3 native hook groups" \
  "[ \$(jq '[.hooks.PermissionRequest[], .hooks.Stop[], .hooks.UserPromptSubmit[] | .hooks[]? | select(.command == \"$NOTIFY_PATH codex-hook\")] | length' '$CODEX_HOOKS_JSON') -eq 3 ]"
chk "codex: notify wrapped only once" "[ \$(grep -cF 'codex-notify-wrap.sh' '$CODEX_CONFIG') -eq 1 ]"
chk "kimi: reinstall keeps one seven-event managed block" \
  "[ \$(grep -cF '# >>> tmux-radar kimi hooks >>>' '$KIMI_CONFIG') -eq 1 ] && [ \$(awk '/# >>> tmux-radar kimi hooks >>>/{inside=1;next}/# <<< tmux-radar kimi hooks <<</{inside=0} inside && /^event = /{n++} END{print n+0}' '$KIMI_CONFIG') -eq 7 ]"

STATUS="$(bash "$IH" status 2>&1)"
chk "status reports 5/5 claude hooks" "printf '%s' \"\$STATUS\" | grep -q 'Claude hooks installed: 5/5'"
chk "status reports all 3 Codex hooks" \
  "[ \$(printf '%s' \"\$STATUS\" | grep -Ec '^Codex native (PermissionRequest|Stop|UserPromptSubmit): installed') -eq 3 ]"
chk "status reports all 7 Kimi hooks" "printf '%s' \"\$STATUS\" | grep -q 'Kimi hooks installed: 7/7'"
chk "status reports the opencode plugin" "printf '%s' \"\$STATUS\" | grep -qi 'opencode plugin: installed'"

awk '
  /^# >>> tmux-radar kimi hooks >>>$/ { inside=1 }
  inside && !changed && /^timeout = 5$/ { $0="timeout = 6"; changed=1 }
  { print }
' "$KIMI_CONFIG" > "$T/kimi-status-broken.toml"
mv "$T/kimi-status-broken.toml" "$KIMI_CONFIG"
STATUS_BROKEN="$(bash "$IH" status 2>&1)"
chk "status rejects a Kimi event whose managed command contract drifted" \
  "printf '%s' \"\$STATUS_BROKEN\" | grep -q 'Kimi hooks installed: 6/7'"
bash "$IH" install >/dev/null 2>&1

echo
echo "### uninstall under the shim leaves the user's config intact"
OUT2="$(bash "$IH" uninstall 2>&1)"; RC2=$?
chk "uninstall exits 0 under the GNU-sed shim" "[ $RC2 -eq 0 ]"
chk "uninstall never invoked 'sed -i'" "! printf '%s' \"\$OUT2\" | grep -q 'sed-shim'"
chk "claude: all 5 of our hooks removed" "[ \$(jq '[.hooks[]?[]?.hooks[]?.command | select(startswith(\"$NOTIFY_PATH \"))] | length' '$CLAUDE_SETTINGS') -eq 0 ]"
chk "claude: user's own Stop hook still there" "jq -e '[.hooks.Stop[]?.hooks[]?.command] | any(. == \"echo mine\")' '$CLAUDE_SETTINGS' >/dev/null"
chk "codex: native hook groups gone" \
  "! grep -qF 'needinput-notify.sh codex-hook' '$CODEX_HOOKS_JSON'"
chk "codex: our wrap unwrapped" "! grep -qF 'codex-notify-wrap.sh' '$CODEX_CONFIG'"
chk "codex: the user's original notify chain restored" "grep -q 'other-tool/notify.js' '$CODEX_CONFIG'"
chk "codex: unrelated config preserved" "grep -q 'gpt-5.3-codex' '$CODEX_CONFIG'"
chk "kimi: managed block removed" "! grep -qF '# >>> tmux-radar kimi hooks >>>' '$KIMI_CONFIG'"
chk "kimi: user hook and config survive uninstall" \
  "grep -qF 'echo user-kimi-hook' '$KIMI_CONFIG' && grep -qF 'model = \"kimi-k2\"' '$KIMI_CONFIG' && grep -qF 'max_context = 1000000' '$KIMI_CONFIG'"
chk "opencode: plugin removed" "[ ! -f '$OPENCODE_CONFIG_DIR/plugins/tmux-radar.js' ]"

echo
echo "### symlinked configs (dotfile repos) must stay symlinks"
rm -rf "${T:?}/home"; mkdir -p "$T/home/.claude" "$T/home/.codex" "$T/home/.kimi-code" "$T/dots"
printf '{}' > "$T/dots/settings.json"
printf 'model = "x"\n' > "$T/dots/config.toml"
printf '{"hooks":{}}\n' > "$T/dots/hooks.json"
printf 'model = "kimi"\n' > "$T/dots/kimi.toml"
ln -sf "$T/dots/settings.json" "$CLAUDE_SETTINGS"
ln -sf "$T/dots/config.toml" "$CODEX_CONFIG"
ln -sf "$T/dots/hooks.json" "$CODEX_HOOKS_JSON"
ln -sf "$T/dots/kimi.toml" "$KIMI_CONFIG"
bash "$IH" install >/dev/null 2>&1
chk "claude settings is STILL a symlink after install" "[ -L '$CLAUDE_SETTINGS' ]"
chk "codex config is STILL a symlink after install" "[ -L '$CODEX_CONFIG' ]"
chk "codex hooks is STILL a symlink after install" "[ -L '$CODEX_HOOKS_JSON' ]"
chk "kimi config is STILL a symlink after install" "[ -L '$KIMI_CONFIG' ]"
chk "the dotfile-repo file actually received the hooks" "grep -q claude-register '$T/dots/settings.json'"
chk "the dotfile-repo TOML received the trust marker" "grep -qF '# BEGIN tmux-radar Codex hooks' '$T/dots/config.toml'"
chk "the dotfile-repo hooks JSON received the hook command" "grep -qF 'codex-hook' '$T/dots/hooks.json'"
chk "the dotfile-repo Kimi TOML received all hooks" \
  "[ \$(grep -c '^event = ' '$T/dots/kimi.toml') -eq 7 ]"
bash "$IH" uninstall >/dev/null 2>&1
chk "claude settings is still a symlink after uninstall" "[ -L '$CLAUDE_SETTINGS' ]"
chk "codex config is still a symlink after uninstall" "[ -L '$CODEX_CONFIG' ]"
chk "codex hooks is still a symlink after uninstall" "[ -L '$CODEX_HOOKS_JSON' ]"
chk "kimi config is still a symlink after uninstall" "[ -L '$KIMI_CONFIG' ]"

echo
echo "### malformed Kimi ownership markers fail without changing the file"
rm -f "$KIMI_CONFIG"; mkdir -p "$(dirname "$KIMI_CONFIG")"
cat > "$KIMI_CONFIG" <<'TOML'
model = "kimi"
# >>> tmux-radar kimi hooks >>>
[[hooks]]
event = "Stop"
command = "old"
# >>> tmux-radar kimi hooks >>>
TOML
cp "$KIMI_CONFIG" "$T/kimi.bad.before"
BAD_KIMI_OUT="$(bash "$IH" install 2>&1)"; BAD_KIMI_RC=$?
chk "duplicate Kimi markers fail visibly" "[ '$BAD_KIMI_RC' -ne 0 ] && printf '%s' \"\$BAD_KIMI_OUT\" | grep -qi 'Kimi.*marker'"
chk "malformed Kimi config remains byte-identical" "cmp -s '$KIMI_CONFIG' '$T/kimi.bad.before'"

echo
echo "### opencode absent => skip, never create the directory"
rm -rf "$T/home2"; export OPENCODE_CONFIG_DIR="$T/home2/.config/opencode"
export KIMI_CONFIG="$T/home2/.kimi-code/config.toml"
export TMUX_RADAR_TEST_KIMI_PRESENT=off
if command -v opencode >/dev/null 2>&1; then
  echo "SKIP: opencode is on PATH here, cannot test the absent branch"
else
  OUT3="$(bash "$IH" install 2>&1)"
  chk "opencode absent: reported as skipped" "printf '%s' \"\$OUT3\" | grep -qi 'opencode not found'"
  chk "opencode absent: no directory created" "[ ! -d '$T/home2' ]"
fi
OUT_KIMI_ABSENT="$(bash "$IH" status 2>&1)"
chk "kimi absent: reported as skipped" "printf '%s' \"\$OUT_KIMI_ABSENT\" | grep -qi 'Kimi: not installed'"
chk "kimi absent: no directory created" "[ ! -d '$T/home2/.kimi-code' ]"

rm -rf "$T"
echo
echo "=============================="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]

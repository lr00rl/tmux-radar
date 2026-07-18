# Design: precise AI-session tracking (native lifecycle registry)

Status: implemented and integrated. Native supervision subsequently replaced
the older watcher/monitor internals described in the companion-fixes section;
the lifecycle registry and status-view contracts remain current.

## Problem

The AI status view (`C-i`) and the status bar show marks for Claude Code
sessions that are already closed. Root causes found by live forensics:

1. `cmd_tick` exempts any claude mark whose key appears in
   `~/.claude/jobs/*/state.json` from liveness GC (`_claude_live_keys`).
   Those state files routinely freeze at `blocked`/`idle` after the session
   is gone (7 of 21 job dirs on this machine are stuck at `blocked`, some
   19h old), so their marks are immortal.
2. Paneless (`-`) background marks have **no** liveness check at all —
   only a 24h TTL.
3. Liveness is *inferred* (full `ps` scan matched back to panes by tty /
   parent chain) instead of *tracked*. Inference breaks for daemons,
   env-scrubbed launchers, and anything whose argv doesn't match.
4. `SessionEnd` — the one native, instant "this session is gone" signal —
   is deliberately not hooked (an earlier version cleared *all* marks on
   SessionEnd, wiping "finished — your turn" for short-lived runs, so the
   hook was dropped entirely instead of being made selective).

## Fix: an agent-session registry driven by native lifecycle hooks

New state file `$STATE_DIR/agent-registry` (TSV, lock-shared with `need-input`):

```
kind \t key \t pid \t pane \t started \t last_event \t state \t cwd \t proc
```

- `kind`   — claude | codex | opencode
- `key`    — same key space as marks: `s:<session_id>` (claude), pane/pid
             fallback otherwise
- `pid`    — the agent process PID, resolved by walking the hook process's
             ancestor chain until an argv matches the agent pattern
             (hooks run as children of the agent process)
- `pane`   — `%id` or `-` (paneless/background)
- `state`  — working | waiting | done (from the last hook event)
- `proc`   — matched process name recorded at registration; on GC we
             require pid alive **and** command still matching, so PID
             reuse can't fake liveness

### Event → registry mapping (claude)

| Hook             | Registry                     | Marks                          |
|------------------|------------------------------|--------------------------------|
| SessionStart     | upsert, state=working        | clear stale action marks for key |
| Notification     | upsert, state=waiting        | mark (existing behavior)       |
| Stop             | upsert, state=done           | mark "finished" (existing)     |
| UserPromptSubmit | upsert, state=working        | clear (existing)               |
| SessionEnd       | **remove row**               | clear action/notice marks for key; **keep done marks** |

Keeping done marks on SessionEnd resolves the original objection to
hooking SessionEnd: `claude -p` / short-lived runs fire Stop then
SessionEnd back-to-back, and "finished — your turn" must survive that.
What must NOT survive is a "needs your permission / waiting for input"
mark for a session that can no longer receive input.

Every event upserts, so sessions started before install/upgrade are
adopted on their first event.

### GC (`tick`)

1. Snapshot `ps -axo pid=,command=` once.
2. Registry row dead ⇔ pid missing or command no longer matches `proc`.
   Dead row → drop it + drop its action/notice marks (done marks stay
   until handled/TTL, matching bar semantics).
3. Marks keyed `s:<sid>`: live ⇔ registry row exists and is alive.
   `_claude_live_keys` (jobs/state.json guessing) is **deleted**.
4. Marks with no registry entry (pre-upgrade, unhooked agents): existing
   pane-agent ps-scan GC stays as fallback.
5. Paneless marks are now GC'd by pid liveness (fixes 24h-zombie bug).

### Latency budget

- Clean close → SessionEnd hook → clear + bar resync: **instant**.
- Crash / kill -9 → next tick (popup open, C-i, session switch, bar
  self-heal ≤30s): detected via pid+command check, no text scanning.

### AI status view (switcher.sh)

- Claude rows come from the registry first (authoritative), ps-scan only
  as fallback for unhooked agents; per-pane the registry wins.
- Rows gain an age column (`3m`, `2h`) and state from the registry.
- Preview for AI rows shows the technical detail (mark source, key, sid,
  pid, state, cwd, age) above the pane capture — this plugin's users are
  terminal people; expose the machinery.

### Diagnostics

`needinput-notify.sh doctor` — prints state dir, hook install status,
registry rows with per-row liveness verdicts, marks with level and the
reason they are kept, and the pane-agent scan result. One command to
answer "why is this row (not) showing?".

## Recon-confirmed facts feeding this design

- Claude Code (v2.1.206 docs): `SessionStart` fires on
  `startup|resume|clear|compact` with `session_id`, `source`, `cwd`,
  `model`; `SessionEnd` fires with `reason ∈ {clear, resume, logout,
  prompt_input_exit, bypass_permissions_disabled, other}` and does fire
  for `claude -p`. Crash/SIGKILL delivery is NOT documented — hence the
  pid+proc GC fallback is mandatory, not optional.
- Hooks run as children of the claude process; parent-chain resolution
  (already used by `_resolve_pane_by_proc`) reaches the agent pid.
- opencode: drop-in plugin dir `~/.config/opencode/plugins/*.{ts,js}`
  is auto-discovered (no config merge); plugins run inside the TUI
  process (can read `TMUX_PANE`, `process.pid` directly) and receive
  `session.status(idle)` / legacy `session.idle`, `permission.updated`,
  `chat.message`, `session.error`, `dispose`. Integration =
  `scripts/opencode-tmux-notify.js` installed as
  `~/.config/opencode/plugins/tmux-radar.js` by install-hooks.sh.
- tmux (3.6b installed, verified in source): keys sent to a pane in
  copy-mode land in the copy-mode key table (y/Enter copy-and-cancel —
  destroys the user's scrollback position); `capture-pane` is always
  read-only-safe and reads the live screen; toggling the status line
  COUNT resizes every window (SIGWINCH to all apps, copy-mode reflow) —
  only content changes are geometry-safe.

## Companion fixes on this branch (ai.sh / bar)

- Supervisor gates: `#{pane_in_mode}` check before deciding and before
  every send (defer, never cancel the user's mode); re-capture + hash
  compare immediately before send (TOCTOU); `safe` field fail-closed;
  `ask` arrangement commands allowlisted (split/join/swap/resize/layout
  family only); watch-start lock; monitor pane ids recorded and closed
  atomically.
- Bar: `@radar-bar auto|pinned|off`; auto saves/restores the exact
  prior `status` value instead of hardcoding `on`; pinned never touches
  the status line count.
- README repositioning (workspace radar story) ships on this branch too.

# Development guide

This guide describes the component boundaries and invariants for contributors.
The current implementation is dependency-free shell (macOS Bash 3.2 safe) plus
one JavaScript and one TypeScript agent bridge.

## Architecture

tmux-radar has four cooperating parts:

| Part | Main paths | Responsibility |
| --- | --- | --- |
| tmux entry | `tmux-radar.tmux` | Binds the picker and last-pane keys, installs the focus/MRU hooks, wires the chip strip. |
| picker | `scripts/switcher.sh` | Builds Recent/Agents/Tree rows from one bulk tmux snapshot plus the state files, drives fzf, switches to exact pane targets. |
| notifier | `scripts/needinput-notify.sh`, `scripts/needinput-toast.sh`, `scripts/mru-record.sh` | Owns the mark file, the agent registry, and the live scanner; renders the chip strip; records MRU. |
| agent bridges | `scripts/install-hooks.sh`, `scripts/codex-notify-wrap.sh`, `scripts/opencode-tmux-notify.js`, `scripts/pi-tmux-notify.ts`, `examples/hooks/custom-agent-adapter.sh` | Normalize vendor lifecycle events into the notifier's `agent-event` API and keep vendor config edits owned and reversible. |

State lives in `~/.local/state/tmux/`: `need-input` (unread marks),
`agent-registry` (live sessions), `ai-live` (scanner verdicts),
`opencode-events` (watermarks), `window-mru` / `pane-mru`, and the `ai.log`
audit log. All writers use mktemp+mv atomic renames under one OS lock
(`shlock`/`flock`); readers never take the lock.

## The live scanner contract

The scanner (`_scan_live` in the notifier, called from `tick`, TTL-guarded by
`.ai-live-at`) is the pull-based floor beneath the push hooks. Per scan and per
pane hosting a watched agent process it decides working/stalled/blocked from
visible change (title hash + screen cksum), adopts untracked panes into the
registry as `p:<pid>` rows, heals marks the screen proves stale (two working
scans counted from the mark's own epoch), downgrades contradicted `waiting`
rows, re-homes rows whose pid provably lives on another tty, and synthesizes
one mark for an off-screen transition into blocked or out of working.

Rules that keep it truthful: empty TSV fields collapse under `IFS=tab` reads
(use `-` placeholders); an apostrophe inside a single-quoted awk program flips
shell quoting (avoid them in comments there); scan work happens after the
tick's own GC so adoption never resurrects dead rows.

## Add an agent safely

Adding an agent has three separate pieces: adapter, installer (when radar owns
a vendor configuration), and tests.

1. **Adapter.** Map documented vendor events to the normalized events in
   `needinput-notify.sh`. Require one JSON object, require a stable vendor
   session ID, validate before state mutation, and use the `agent-event`
   command instead of direct file writes.
2. **Installer.** In `install-hooks.sh`, manage a single marker-delimited
   block or an equivalent exact ownership boundary. Preserve unrelated bytes
   and user hooks, write through symlinks, back up changed files, support
   idempotent reinstall, show partial status, and remove only owned content.
   Include the file in the all-agent transaction so later failures roll back.
3. **Tests.** Add event mapping and failure tests before implementation, then
   installer ownership and rollback tests. Cover each vendor event, concurrent
   sessions, selective cleanup, malformed/unknown input, absence handling,
   status, uninstall, symlink preservation, malformed markers, and rollback.

Kimi Code is the reference integration; pi (`scripts/pi-tmux-notify.ts`) shows
the in-process extension shape. Node-wrapped agents (argv0 `node`, the real
program in argv1) are matched by the runtime-wrapper rule in every ps matcher:
normalize `pi-coding-agent`-style package components to the watched name.

## Test-driven workflow

Start with the narrowest failing test for the behavior you intend to change.
These commands are the repository test entry points:

```sh
bash tests/test_switcher.sh      # picker: views, rows, real-fzf key transforms
bash tests/test_scanner.sh       # scanner: classify/adopt/heal/re-home/synthesize
bash tests/test_registry.sh      # marks, registry, GC, chips, hooks
bash tests/test_safety.sh        # fail-closed notifier and adapter behavior
bash tests/test_install.sh       # installer ownership/idempotency/rollback
bash tests/test_opencode_plugin.sh
find scripts examples -type f -name '*.sh' -exec bash -n {} \;
shellcheck -S warning scripts/*.sh
```

The suites spin up isolated tmux servers (`tmux -L <socket>`) and never touch
the live one. Two timing traps to remember when a picker test flakes: fixture
panes must not source a user shell rc (rc commands make `pane_current_command`
nondeterministic — the switcher suite sets `default-command 'bash --norc'`),
and `pgrep -f` matches the test harness's own command line (take pids from
`pane_pid`).

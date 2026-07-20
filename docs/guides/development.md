# Development guide

This guide describes the supervisor and hook boundaries for contributors. It is
specific to the current Bash/Go implementation and schema-v1 run artifacts.

## Architecture

tmux-radar has four cooperating layers:

| Layer | Main paths | Responsibility |
| --- | --- | --- |
| tmux entry and navigation | `tmux-radar.tmux`, `scripts/switcher.sh` | Binds keys, opens the picker/supervisor UI, and manages tmux-side hooks. |
| notifications and agent bridge | `scripts/needinput-notify.sh`, `scripts/install-hooks.sh` | Installs agent hooks; normalizes lifecycle events; owns registry rows, marks, and watcher delivery. |
| serialized supervisor | `scripts/ai.sh`, `scripts/lib/ai-runtime.sh` | Builds effective configuration, captures panes, runs the decision backend, gates sends, journals events, and finalizes runs. |
| native console and schema | `cmd/tmux-radar`, `internal/runmodel`, `internal/tui` | Validates schema-v1 configuration and provides the supervised native setup/monitor surface. |

The decision model is read-only and ephemeral. The shell owns pane capture,
policy gating, key delivery, verification, audit artifacts, process-group
termination, and all state transitions. Do not move a direct state mutation or
key-send decision into an adapter or model prompt.

## State and run journal

The default state root is `~/.local/state/tmux`; test environment overrides
can redirect it. A live pane has a watch pointer in `ai-watch/`; each run has
a distinct directory with durable artifacts:

| Artifact | Purpose |
| --- | --- |
| `config.json` | Effective schema-v1 settings, provenance, frozen backend identity, run ID, pane, and creation time. |
| `state.json` | Current phase, status, next wait kind/deadline, run ID, and pane. |
| `events.jsonl` | Append-only journal for incoming events, phases, decisions, delivery, verification, errors, fallback projections, and controls. |
| `inbox/*.ready` | Durable event handoff from the notifier to the watcher. The inbox is authoritative; transient tmux wake signals are not. |
| `decisions/` | Structured model decisions and call metadata. |
| `backend/` | Backend stderr evidence and owned-model PID records while a call is active. |
| `screens/`, `prompts/`, `fallback/` | Optional sensitive artifacts. They are written only for full logging and/or screen snapshots. |
| `final.json` | One terminal summary: outcome, reason, duration, counts, goal status, and log path. |

The native console reads these artifacts rather than holding a competing state
machine. Preserve schema-v1 reader compatibility when extending artifacts:
unknown fields may be additive, but launch-boundary configuration is strict and
rejects unsupported or misspelled fields.

## Add an agent safely

Adding an agent has three separate pieces: adapter, installer (when radar owns
a vendor configuration), and tests.

1. **Adapter.** Map documented vendor events to the eight normalized events in
   `needinput-notify.sh`. Require one JSON object, require a stable vendor
   session ID, validate before state mutation, and use `agent-event` behavior
   instead of direct file writes.
2. **Installer.** In `install-hooks.sh`, manage a single marker-delimited
   block or equivalent exact ownership boundary. Preserve unrelated bytes and
   user hooks, write through symlinks, back up changed files, support
   idempotent reinstall, show partial status, and remove only owned content.
   Include the file in the all-agent transaction so later failures roll it back.
3. **Tests.** Add event mapping and failure tests before implementation, then
   installer ownership and rollback tests. Cover each vendor event, concurrent
   sessions, selective cleanup, malformed/unknown input, absence handling,
   status, uninstall, symlink preservation, malformed markers, and rollback.

Kimi Code is the reference integration: its adapter maps seven vendor events,
its installer owns a marked block in the active config
(`$KIMI_CODE_HOME/config.toml` or `~/.kimi-code/config.toml`), and the
registry/safety/install suites prove lifecycle and fail-closed behavior.

## Test-driven workflow

Start with the narrowest failing test for the behavior you intend to change.
These commands are repository test entry points:

```sh
bash tests/test_registry.sh
bash tests/test_ai_events.sh
bash tests/test_install.sh
bash tests/test_safety.sh
bash tests/test_ai_supervision.sh
bash tests/test_idle_process_budget.sh
bash tests/test_supervisor_process_safety.sh
bash tests/test_native_owner.sh
go test ./...
go vet ./...
go build ./cmd/tmux-radar
find scripts examples -type f -name '*.sh' -exec bash -n {} \;
```

Use the lifecycle and idle-process suites when changing delays, control flow,
finalization, or process ownership. Use registry/safety/install suites when
changing an agent adapter or installer. Run the whole relevant group after the
narrow test is green; do not rely on a successful static syntax check for
process or tmux behavior.

## Performance and lifecycle invariants

Treat the following as compatibility requirements, not tuning suggestions.

- **One model call at a time.** A watcher serializes capture, decision,
  delivery, and verification. A new polling interval begins only after the
  preceding operation reaches a terminal phase.
- **Native events first.** With `hooks_first=on`, actionable native events are
  processed immediately. Fallback uses a stable projection of only the bottom
  `fallback_capture_lines` lines and deduplicates an already assessed
  projection.
- **One fallback evidence artifact.** A `screen_idle` decision must read the
  immutable normalized capture retained by its watcher. Automatic delivery is
  authorized only by `cmp -s` against a fresh capture; projection hashes and
  separately repeated `capture-pane` calls are never delivery authority. The
  path is an in-process watcher value, never an inherited environment input;
  crash GC removes the artifact when its watcher is no longer live.
- **No background waiters or timers.** ARMED polling, retry backoff,
  verification, and completion hold block in the watcher’s Bash process with
  bounded `read -t` waits. Do not add `tmux wait-for`, timer children, or a
  fork-per-tick loop to these phases. Production poll values are whole seconds
  (`1`–`3600`) because macOS Bash 3.2 rejects fractional `read -t` values.
- **Durable inbox first.** Deliver events through the run inbox. A tmux signal
  may accelerate a wake but must not become the source of truth.
- **Owned process groups only.** A model process runs in an owned group and is
  recorded while active. On timeout, target loss, owner loss, or stop,
  terminate the group and recorded descendants before reporting a terminal
  result. A normal leader exit must also prove that no same-group helper
  survived before its marker is removed. TERM/KILL delivery is not completion
  evidence: bounded liveness checks must prove every recorded runnable process
  is gone, and a failed proof retains the brain marker.
- **One idempotent finalizer.** `q`, `Ctrl-C`, `TERM`, `INT`, `HUP`,
  pane loss, owner loss, and session termination must converge on one
  finalizer. It clears transient files, removes the live pointer only for its
  generation, writes one `final.json`, and cannot claim success with an owned
  process still alive.
- **No silent partial delivery.** A failed model call, invalid output, blocked
  policy decision, send failure, or failed verification must be journaled and
  surfaced as an error/escalation/paused outcome rather than a successful run.

The one-second bounded waiter is deliberate: it removes the orphanable child
process class at the cost of an explicit normal wake-latency ceiling of roughly
one second. Preserve that tradeoff unless a new design and process audit prove
an equivalent lifecycle guarantee.

## Debugging a run

Use the native console’s Logs/Evidence views or inspect the run directory from
the watch pointer. `scripts/ai.sh status` lists live watchers and recent
decisions; `scripts/needinput-notify.sh doctor` explains registry, marks,
options, and installed-hook status.

Before diagnosing a missing trigger, determine which layer failed:

1. Run `scripts/install-hooks.sh status` and confirm the agent event is
   installed; Kimi should report `7/7`.
2. Check the notifier’s registry/marks with `scripts/needinput-notify.sh doctor`.
3. Inspect the live run’s `events.jsonl` and `state.json`; a native event
   with `hooks_first=off` is intentionally recorded as `hook_deferred`.
4. For fallback, inspect `fallback_projection` journal entries before changing
   `poll` or capture budgets. A changing footer should disappear from the
   stable projection rather than trigger an agent-specific regex.
5. For stop issues, inspect `final.json` and recorded backend PID evidence;
   run the process-safety suites before changing termination code.

## Release workflow

Release only from a clean, verified source commit. The v0.1.2 release gate is:

1. Run all Go tests, all shell suites, `go vet ./...`, a native build, and
   `bash -n` for every shell script/example. Run ShellCheck when available.
2. Run real tmux Kimi hook injection and a no-hook semantic-fallback smoke
   test. Confirm native events use `capture_lines` and fallback uses only
   `fallback_capture_lines`.
3. Audit the process table after tests. No `tmux-radar`, `ai-monitor`,
   `tmux wait-for`, watcher/timer, or backend process owned by a completed run
   may remain.
4. Synchronize the installed copy to the source commit and verify Kimi status
   reports all seven hooks.
5. Push `main`, then create and push annotated tag `v0.1.2`.

Record release evidence and validation gaps in the release commit message. Do
not publish a tag from a run that only appears successful while leaving owned
processes, dropped events, or failed sub-operations behind.

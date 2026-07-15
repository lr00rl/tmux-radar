# tmux-radar Native Supervisor TUI Design

Date: 2026-07-14
Status: Architecture approved; written specification pending final review
Scope: `prefix + A -> w/W/v`, supervisor setup, backend preflight, live console, control bridge, binary distribution, compatibility, and staged engine migration
Supersedes: the setup and presentation-layer sections of `2026-07-13-supervision-console-design.md`
Preserves: the existing hook, event journal, safety gate, delivery verification, one-model-call, and process-tree lifecycle contracts

## Decision Summary

tmux-radar will add one Go binary named `tmux-radar`. The binary will use the current v2 Charm stack:

- `charm.land/bubbletea/v2` for the stateful terminal event loop and renderer
- `charm.land/bubbles/v2` for Unicode-aware text input, textarea, viewport, table, help, and key bindings
- `charm.land/lipgloss/v2` for layout, wrapping, terminal-width measurement, and color-profile degradation

No additional form framework, file-watching package, RPC framework, database, or async runtime is introduced in the first delivery. The binary polls local file metadata at a low fixed cadence and only updates the Bubble Tea model when canonical state changes; Bubble Tea decides the terminal diff.

The migration is UI-first:

1. Fix backend resolution, preflight, and error classification in the existing engine.
2. Move goal entry, advanced configuration, launch confirmation, live views, and controls into the Go TUI.
3. Keep the tested Bash watcher as the Phase 1 engine.
4. Build an engine-independent replay/parity harness.
5. Move the watcher into Go only after both engines satisfy the same journal and lifecycle fixtures.

A big-bang engine rewrite is rejected. The recent history contains subtle fixes for event ownership, stale delivery, user takeover, process-tree termination, and evidence completeness. UI quality must improve without reopening those behaviors.

## Product Boundary

tmux-radar remains a workspace navigator. Supervision is an optional per-pane capability. It does not create worktrees, assign tasks, queue runs, coordinate multiple agents, or own the user's development workflow.

One supervisor process represents exactly one target pane and one run. The product may list many runs in the existing AI-status view, but a supervisor TUI never becomes a multi-run orchestrator.

tmux continues to own layout and pane lifecycle. The Go binary owns all interaction and presentation inside the allocated terminal surface. The engine owns event processing, model calls, policy, key delivery, and verification.

## Success Criteria

- `prefix + A`, then `w`, opens a full-height right-side supervisor TUI with the goal field focused.
- `W` opens the same TUI with always-allow visibly preset; `v` opens it with Advanced expanded. There is one implementation, not three flows.
- Goal input supports CJK editing, cursor movement, multiline paste, bracketed paste, and terminal resize without byte corruption or invisible echo.
- Default brain is `gpt-5.6-luna` with `effort=high`. Any tmux or per-run override is shown with provenance.
- Advanced values are edited in place with controls appropriate to their type. The user never types a field name to select a setting.
- The setup view continuously shows the selected Codex path, version, model compatibility status, hook capability, and launch-blocking errors.
- Permanent configuration failures start zero model calls and receive zero retries.
- The live view always exposes current phase, next condition, event source, model call state, policy outcome, exact proposed/sent keys, verification, and errors.
- Timeline scrolling remains stable while new events arrive. Auto-follow resumes only when the user explicitly returns to the bottom.
- Controls remain discoverable at every supported width. Narrow layouts drop labels before dropping keys and expose `?` help.
- Closing the target pane, closing the owned monitor pane, explicitly stopping, or terminating the TUI owner ends the watcher and complete backend process tree.
- Existing CLI commands and run directories remain usable during rollback.

## Non-Goals

- Replacing the tmux workspace picker with Go in this project slice
- Moving Claude/Codex hook processing into a persistent daemon
- Parsing agent screen text to infer native lifecycle events
- Exposing private chain-of-thought
- Supporting Windows outside WSL
- Automatically changing the configured model when the requested model is unavailable
- Shipping a native Go engine before journal parity is proved

## Component Architecture

```text
tmux-radar.tmux
  creates/reuses the monitor surface
  passes target pane, monitor pane, state dir, and engine script
            |
            v
bin/tmux-radar
  supervisor setup|attach|doctor|version
            |
            +-- internal/tui
            |     setup form, launch review, live views, help, confirmation
            +-- internal/runmodel
            |     versioned config/state/events/decisions/final readers
            +-- internal/preflight
            |     backend resolution, version, auth/config and hook checks
            +-- internal/enginebridge
            |     start Bash engine through JSON stdin; parse start result
            +-- internal/control
                  invoke existing pause/resume/reassess/keep/stop commands
            |
            v
scripts/ai.sh + scripts/lib/ai-runtime.sh
  Phase 1 engine: hooks, queue, capture, model, policy, delivery, verification
```

### tmux Plugin Ownership

The plugin creates the UI surface because it already owns tmux compatibility, options, initial focus, duplicate-run selection, and cleanup.

- At 120 or more client columns and at least 24 rows, create a full-height right pane and select it so Goal input is immediately active.
- Use approximately 38% of the client width, clamped to 56-96 columns, while leaving at least 64 columns for the target.
- Below that threshold, run the same binary in a 90% by 85% popup instead of crushing the target pane.
- Keep focus in the TUI after launch so the user sees preflight and the first live state. `Enter` explicitly returns focus to the target pane.
- Cancelling setup closes the newly created monitor surface and starts no watcher.
- A duplicate launch selects the existing monitor and shows the existing run ID.

The binary never creates, resizes, or kills tmux panes. It may focus the supplied target pane in response to `Enter`. It receives `--target-pane`, `--monitor-pane`, `--surface split|popup`, and `--engine-script` from the plugin.

### Binary Commands

```text
tmux-radar supervisor setup  --target-pane %N --monitor-pane %M --surface split
tmux-radar supervisor attach --run <run-id>
tmux-radar supervisor doctor [--json]
tmux-radar version
```

`setup` transitions into the live console in the same process after a successful launch. `attach` is read-only unless the referenced run is active and its target/control bridge can be resolved. `doctor --json` is stable machine-readable evidence for tests and troubleshooting.

### Engine Start Protocol

Phase 1 adds one internal Bash command:

```text
ai.sh engine-start <target-pane> <monitor-pane>
```

It reads one immutable configuration object from stdin, validates every field with the existing constraints, creates the run, starts the watcher, records the existing monitor owner, and prints exactly one JSON result:

```json
{"ok":true,"run_id":"...","run_dir":"...","watcher_pid":1234}
```

Failure output is also JSON and contains a stable error class, user-facing summary, detail, retryability, and evidence path. Configuration JSON is never placed in argv, a tmux option, or a world-readable temporary file.

After launch, the Go process reads canonical files and invokes existing public control commands. No Unix socket is required in Phase 1.

## Canonical Run Contract

The run directory remains the durable API and the source of truth:

```text
ai-runs/<run-id>/
  config.json
  state.json
  events.jsonl
  monitors
  inbox/
  decisions/
  backend/
  screens/       optional
  prompts/       optional
  final.json
```

Newly written JSON includes `schema_version: 1`. Readers treat a missing version as legacy version 0. Version 1 changes are additive. Existing field meanings are not repurposed.

The TUI does not rewrite engine state. It writes configuration only before launch. After launch, controls go through `ai.sh`; acknowledgement is proved by a matching canonical event/state transition, not by process exit code alone.

The UI checks file size/modification metadata every 250 milliseconds. It reparses only changed files and emits a Bubble Tea message only when the derived model changes. Timeline reads continue from the last byte offset and handle truncation or inode replacement defensively. A one-second tick updates elapsed time and countdowns without reconstructing timeline content.

## Setup Experience

The setup TUI is a single stateful form, not a sequence of shell prompts.

```text
 tmux-radar supervisor  SETUP                         cdcd:4.0  codex

 Goal
 > 允许所有安全操作，直到任务全部完成▌

 Preset       Default        Cautious        Always allow
 Policy       safe-auto      Autonomy auto-safe

 Brain        gpt-5.6-luna   effort high
 Backend      ~/.local/bin/codex  0.144.3
 Preflight    OK  model/backend compatible · native hooks available

 Advanced     collapsed · 2 inherited overrides

 Tab/Shift-Tab move  Enter edit/select  Space toggle  ? help  q cancel
                                               Enter on Start launches
```

### Focus And Editing

- Initial focus is the Goal textarea.
- `Tab` and `Shift-Tab` move through controls.
- Arrow keys operate the focused list/selector and move within text while editing.
- `Enter` edits or selects the focused field. The explicit Start row launches.
- `Space` toggles binary values.
- `Esc` exits field editing without discarding the form; `q` on the form requests cancellation.
- `?` opens a help overlay derived from the active key map.
- Validation appears directly below the field and focus remains on the rejected value.

### Advanced Form

Advanced settings remain grouped as Intent, Authority, Triggering, Brain, Budget, Context, Console, and Logging. Collapsed groups show changed/inherited counts. Expanded fields use selectors for enums, toggles for booleans, and validated text/numeric inputs for free values.

Every row shows effective value and provenance:

```text
Effort      high              default
Timeout     60s               tmux: @radar-ai-timeout
Poll        10s               custom for this run
```

The final review is part of the same screen, not a second shell prompt. It highlights only changed values plus the complete goal, policy, model, backend path, logging privacy level, and any warning. Starting is disabled while preflight has a blocking error.

## Backend Resolution And Preflight

The engine must stop prepending `/opt/homebrew/bin` ahead of the user's environment. Backend resolution order is:

1. Explicit per-run `command` or profile
2. Explicit `@radar-ai-codex-path`
3. The first executable from the inherited user/tmux `PATH`

The resolved absolute path, version, source, and model/effort are frozen in `config.json`. The preflight scans other PATH candidates only to produce diagnostics; it never silently substitutes one after launch review.

Preflight checks:

- executable exists and can run `--version`
- configured profile and command are not mutually ambiguous
- known minimum CLI compatibility for the built-in default model
- Codex authentication/config health through `codex login status` when that subcommand is supported; otherwise show `not checked by this CLI version` without claiming success
- native hook installation status, reported as native, legacy, fallback, or missing
- state directory permissions and run-directory writability
- target and monitor pane identity/liveness

Model compatibility remains fail-closed. There is no silent fallback model. Unknown compatibility is visibly marked and runtime permanent-error classification remains authoritative.

The built-in default is:

```text
model  = gpt-5.6-luna
effort = high
```

## Error Model

`backend rc=1` is evidence, not a user-facing diagnosis. Every failure is classified:

| Class | Examples | Retry behavior | UI behavior |
| --- | --- | --- | --- |
| `config-permanent` | executable too old, unsupported model, bad profile/auth, missing executable | never | block launch or halt immediately with exact fix |
| `transient` | timeout, connection reset, rate limit, service 5xx | bounded exponential backoff | show retry count, next time, stderr evidence |
| `output-invalid` | empty output, malformed JSON, schema/type error | one repair attempt | show raw output and validation error; halt after repair failure |
| `policy-halt` | destructive, irreversible, ambiguous, production or secret-bearing action | never automatic | pause for user with evidence and target jump |
| `lifecycle-stop` | target/owner disappeared or user stopped | never | terminal STOPPED state and cleanup evidence |

Error records include class, code, retryable flag, summary, detail, backend path/version, stderr file, call number, and timestamp. Known permanent stderr such as `requires a newer version of Codex` consumes no retry budget.

## Live Console

The TUI uses the alternate screen and owns its own viewport history. Users do not depend on tmux copy-mode scrollback for live navigation. All evidence remains available in files and through `attach` after exit.

```text
 tmux-radar supervisor  DECIDING                         run 20260714-...
 Goal  允许所有安全操作，直到任务全部完成
 Now   model call 2/100 · 8.2s
 Next  validate decision, then apply local policy

 [1 Timeline] [2 Decision] [3 Screen] [4 Config] [5 Logs]
 ----------------------------------------------------------------
 13:42:20  CREATED          run created
 13:42:20  ARMED            native hooks or stable-screen fallback
 13:42:41  SCREEN_IDLE      stable screen captured
 13:42:42  MODEL_STARTED    luna/high · call 1
 13:42:56  CONFIG_ERROR     Codex 0.139.0 does not support luna
                            newer candidate: ~/.local/bin/codex 0.144.3

 p pause  r reassess  k keep  c config  Enter target  q stop  ? help
```

### View Behavior

- Timeline is append-only in the canonical log. The presentation collapses consecutive identical state rows into `xN`; `e` expands or collapses the selected group without altering raw records.
- Timeline follows new events only while already at the bottom. Scrolling up pins the selected offset and shows a `new events` counter.
- Decision shows model metadata, pane/goal assessment, risk, evidence, parsed action, exact text/keys, local policy result, delivery, and verification. It never labels private reasoning or chain-of-thought.
- Screen shows the monitor excerpt and the exact capture dimensions sent to the model. Persisted content depends on logging policy.
- Config shows every launch value, provenance, resolved backend, and runtime adjustment. `c` switches here from any view.
- Logs shows run paths, file sizes, retention, backend stderr, structured errors, and final report.

### Controls

The existing control vocabulary remains stable:

- `1`-`5`: switch views
- arrows or `j/k`: move/scroll
- `g/G`: first/last; `G` resumes timeline follow
- `e`: expand/collapse a grouped Timeline row
- `p`: pause/resume
- `r`: enqueue one manual reassessment
- `k`: keep a completed console open
- `c`: Config view
- `Enter`: focus the target pane from a split; close a popup while leaving an explicitly detached run active
- `q`: request stop confirmation while active; close immediately after a terminal state
- `?`: context-sensitive help

At narrow widths, footer labels shorten before keys disappear. The minimum footer still contains `1-5`, `p`, `r`, `Enter`, `q`, and `?`.

### Rendering

- Bubble Tea receives state changes and owns cell-diff rendering. No manual ANSI cursor-addressing loop remains.
- Resize recomputes header, viewport, and footer dimensions without changing selected view or scroll offset.
- Semantic colors distinguish active, waiting, action-required, success, warning, and failure; text labels always carry the meaning without color.
- Motion is limited to a spinner during an active backend call and a completion countdown. No decorative animation is added.
- Mouse wheel scrolling is enabled by default and can be disabled with `@radar-supervisor-mouse off`. Tab clicking is outside Phase 1; every workflow remains keyboard-complete.

## Lifecycle And Control Semantics

Phase 1 preserves the current watcher state machine and ownership checks. The existing monitor pane is recorded before watcher pointer snapshots can overwrite monitor IDs.

Control commands are asynchronous from the TUI's perspective:

1. invoke the engine command with target/run identity
2. show the request as pending
3. wait for a canonical event/state acknowledgement
4. show success only after acknowledgement
5. show a loud control failure if acknowledgement does not arrive within the bounded timeout

The TUI never reports success solely because a shell command exited zero.

If the TUI process exits unexpectedly in a split owner, the pane closes and existing owner-GC stops the watcher and backend tree. In popup mode, explicit detach is recorded before the popup exits; an unmarked popup crash stops the watcher. Target-pane disappearance always stops the run.

## Distribution And Installation

Release artifacts are built for:

- `darwin/arm64`
- `darwin/amd64`
- `linux/arm64`
- `linux/amd64`

Each release includes SHA-256 checksums. The source repository does not commit platform binaries.

`@radar-supervisor-binary` may point to a user-managed binary. Otherwise the plugin uses `bin/tmux-radar` in its install directory. When absent, the first explicit supervisor launch offers to install the matching checksummed release asset; it does not perform hidden network work from hooks or plugin startup. If Go is installed, source build is an explicit alternative. Declining installation keeps the workspace navigator functional and offers the legacy Bash supervisor during the migration window.

The binary and Bash engine exchange a protocol version at launch. A mismatch blocks supervision with an update instruction; it never attempts a partially compatible run.

## Migration Plan And Deletion Gates

### Phase 0: Backend Correctness

- preserve user PATH and resolve/pin the selected Codex binary
- set built-in Luna/high defaults
- add preflight and structured error classification
- classify the reproduced old-Codex failure as permanent and zero-retry

Acceptance: the supplied failure configuration names `/opt/homebrew/bin/codex 0.139.0`, identifies the newer candidate, starts zero model calls, and consumes zero retry budget.

### Phase 1: Go TUI Over Bash Engine

- add Go module and `tmux-radar supervisor` commands
- implement setup, review, preflight, live views, help, and controls
- add stdin engine-start protocol and external monitor ownership
- keep `TMUX_RADAR_LEGACY_UI=1` rollback

Acceptance: all current events, lifecycle, serialized-supervision, runtime, and ownership tests pass with the Go monitor owner; TUI-specific unit and real tmux tests pass.

After one release with successful rollback telemetry/manual evidence, delete `scripts/ai-monitor.sh` and the readline/advanced field-name setup loop.

### Phase 2: Engine Parity Harness

- normalize timestamps/PIDs from recorded run fixtures
- replay inbox and screen-fingerprint sequences through the Bash engine
- assert canonical state/event/action/final outcomes through an engine-neutral harness

No production engine behavior changes in this phase.

### Phase 3: Opt-In Go Engine

- move coalescing, backend process ownership, policy, delivery, and verification into `internal/engine`
- select with `@radar-supervisor-engine go|bash`
- make both engines pass the same replay and live process-tree tests
- keep journal schema additive and legacy runs attachable

Go becomes default only after one dual-engine release. Bash watcher code is deleted only after another stable release. Thin tmux glue and minimal hook append/signal scripts remain.

## Verification Matrix

### Unit And Contract

- reducer/state transitions for every setup and live message
- config validation and provenance
- schema v0/v1 parsing and additive unknown fields
- incremental JSONL tailing, replacement, truncation, partial final line
- permanent/transient/output-invalid/policy/lifecycle classification
- footer degradation and width-safe rendering
- CJK grapheme editing and exact JSON round-trip
- control acknowledgement and timeout behavior

### Automated tmux

- `80x24`: popup setup/live console, minimum controls visible
- `120x30`: minimum right pane, target remains at least 64 columns
- `150x40`: compact right console
- `284x54`: full setup form and live views
- resize across thresholds without losing form values/view/scroll position
- close monitor, close target, `q`, and `Ctrl-C` process-tree cleanup
- Enter target behavior and popup detach ownership
- duplicate launch selects existing monitor
- active backend call remains singular while hook events burst

### Manual Release Acceptance

- type, edit, delete, cursor-move, and paste mixed ASCII/CJK text
- scroll Timeline upward while events arrive; verify position does not jump
- inspect a long decision, screen capture, config, and stderr without clipping
- reproduce unsupported-model and old-binary errors with zero retries
- complete, keep, stop, and reattach to finished runs
- verify dark/light terminal themes and ANSI-16 fallback remain legible

## Rollback And Compatibility

- Phase 1 keeps `TMUX_RADAR_LEGACY_UI=1` for one release.
- The Go TUI reads legacy version-0 runs.
- Existing `ai.sh` CLI commands remain through the dual-engine period.
- Run files are additive and locally inspectable without the binary.
- Installation or protocol failure never breaks the picker or AI-status views.
- No migration deletes active or retained run evidence.

## Risks And Mitigations

- TUI hides evidence in alternate screen: mitigate with persistent run files and `attach`.
- UI and engine disagree: treat journals as authoritative and require control acknowledgement.
- New binary weakens owner cleanup: reuse existing owner IDs and keep kill-tree tests as release gates.
- CJK library behavior differs by terminal: retain byte-exact tests and real Ghostty/tmux acceptance.
- Binary installation reduces TPM simplicity: checksummed four-platform releases, explicit install, source-build and legacy fallback.
- Project drifts into orchestration: enforce one process, one run, one pane as an architectural invariant.
- Model availability changes: pin backend evidence, fail closed, and never silently downgrade.

## Resolved Decisions

- Language: Go
- TUI stack: Bubble Tea v2, Bubbles v2, Lip Gloss v2
- Migration: UI-first staged migration
- Phase 1 engine: existing Bash watcher
- State transport: canonical run directory
- Phase 1 control transport: existing `ai.sh` commands plus journal acknowledgement
- tmux layout ownership: plugin shell
- Default model/effort: `gpt-5.6-luna` / `high`
- Narrow layout: same binary in popup
- Browser/web UI: none
- Full rewrite before parity: rejected
- Silent model fallback: rejected

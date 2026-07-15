# tmux-radar Native Supervisor TUI Design

Date: 2026-07-14
Status: Approved for Phase 0-1 implementation; boundary contracts revised after adversarial plan review
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
  routes every entry through scripts/native-launcher.sh
            |
scripts/native-launcher.sh
  duplicate lookup, legacy routing, binary bootstrap, geometry, surface creation
  passes target pane, nullable monitor pane, surface, state dir, and engine script
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
            |     atomic versioned start through JSON stdin; run-scoped controls
            +-- internal/control
                  invoke existing pause/resume/reassess/keep/stop commands
            |
            v
scripts/ai.sh + scripts/lib/ai-runtime.sh
  Phase 1 engine: hooks, queue, capture, model, policy, delivery, verification
```

### tmux Plugin Ownership

The plugin delegates one shell launcher to create the UI surface because shell remains available when the native binary is missing, corrupt, or built for the wrong architecture. Both `tmux-radar.tmux` and the `ai.sh menu` fallback call this launcher; neither duplicates routing or geometry logic.

- Use the actual target-pane width as the hard geometry input; client width is diagnostic only.
- At 121 or more target-pane columns and at least 24 rows, create a full-height right pane and select it so Goal input is immediately active.
- Use approximately 38% of the target width, clamped to 56-96 columns, while leaving at least 64 target columns plus the tmux divider.
- Below that threshold, run the same binary in a 90% by 85% popup instead of crushing the target pane.
- Keep focus in the TUI after launch so the user sees preflight and the first live state. `Enter` explicitly returns focus to the target pane.
- Cancelling setup closes the newly created monitor surface and starts no watcher.
- The launcher checks for an existing live run before creating a surface. A sequential duplicate selects the existing split monitor or opens a read-only attach view for a detached run. The engine's atomic reservation remains the concurrency backstop.

The binary never creates, resizes, or kills tmux panes. It may focus the supplied target pane in response to `Enter`. It receives `--target-pane`, optional `--monitor-pane`, `--surface split|popup`, and `--engine-script` from the launcher. Resize reflows content inside the existing surface; a running split never transforms into a popup and a popup never transforms into a split.

### Binary Commands

```text
tmux-radar supervisor setup  --target-pane %N [--monitor-pane %M] --surface split|popup
tmux-radar supervisor attach --run <run-id>
tmux-radar supervisor doctor [--json]
tmux-radar version
```

`setup` transitions into the live console in the same process after a successful launch. `attach` is read-only unless the referenced run is active and its target/control bridge can be resolved. `doctor --json` is stable machine-readable evidence for tests and troubleshooting.

### Engine Start Protocol

Phase 1 adds two versioned internal Bash commands:

```text
ai.sh engine-start
ai.sh control <run-id> <target-pane> <action> <request-id>
```

`engine-start` reads one strict request from stdin. The request contains `protocol_version:1`, `config_schema_version:1`, authoritative target pane, expected state root, immutable config, and an owner descriptor. Split and popup owners contain a random 128-bit token, Go PID, heartbeat path, and optional pane ID. Detached and viewer descriptors contain no active owner lease. Request target and config target must match after canonical pane resolution.

The parent acquires an atomic per-pane launch lock before checking/replacing the live pointer. It validates the complete request, creates the run and owner metadata, writes a starting pointer, starts a watcher that opens the pre-created run without config in argv, and waits for a ready record proving traps and first state are installed. Only then does it print exactly one JSON result:

```json
{"protocol_version":1,"ok":true,"status":"started","run_id":"...","run_dir":"...","watcher_pid":1234}
```

An active duplicate returns `status:"already-active"` and the existing run/owner without creating a process. Failure output is one JSON line and contains protocol version, stable error class/code, summary, detail, retryability, and evidence path. Diagnostics go to stderr. Invalid requests, dead identities, protocol mismatch, readiness timeout, or child failure leave no live pointer or hidden process; an incomplete run is finalized as `startup-failed`. Configuration JSON is never placed in argv, a tmux option, or a world-readable temporary file.

After launch, the Go process reads canonical files and invokes the run-scoped `control` command. No Unix socket is required in Phase 1.

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

New `config.json`, `state.json`, `final.json`, every `events.jsonl` record, every decision metadata record, every control request/acknowledgement, owner descriptor, and start request/result include `schema_version:1` or `protocol_version:1` as appropriate. Raw `decisions/NNNN.json` remains the model's existing strict output and is not wrapped or versioned. Readers treat missing artifact versions as legacy version 0, ignore additive unknown fields, and reject unsupported major/protocol versions before control or launch.

The TUI does not rewrite engine state. It writes configuration only in the stdin start request. After launch, controls use run ID, target pane, action, and a UUID request ID. The engine atomically verifies that the current pointer still names that run and pane before any sentinel, event, or signal. A stale viewer receives `stale-run` and cannot affect the replacement run.

Every control writes one idempotent request record. Repeating the same request ID returns the stored result and causes no second transition. Engine acknowledgements carry the same request ID. Pause succeeds only at `PAUSED_USER`; resume succeeds on `resumed`; reassess succeeds when its manual event is accepted; keep succeeds on a persisted keep acknowledgement; stop succeeds only when that run's `final.json` is terminal. UI acknowledgement timeout is five seconds, except stop is ten seconds. Timeout does not resend or claim success; the request remains inspectable and a later acknowledgement updates the UI.

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

The engine must stop prepending `/opt/homebrew/bin` ahead of the user's environment. Backend modes are explicit:

- `codex`: a resolved and pinned absolute Codex executable, optionally with a profile
- `custom-command`: the existing arbitrary command backend, exempt from Codex path/version/auth/model checks

When custom command and profile coexist, existing command precedence remains for compatibility and preflight emits a warning that the profile is ignored. Codex backend resolution order is:

1. Explicit `@radar-ai-codex-path`
2. The first executable from the inherited user/tmux `PATH`

The resolved absolute path, version, source, profile, and model/effort are frozen as one backend object in `config.json`. `_brain`, metadata, labels, preflight, and logs use that object and never rerun `command -v`. A profile uses the pinned executable; when profile-managed model/effort are not passed explicitly, the UI labels them `profile-managed` instead of claiming Luna/high. The preflight scans other PATH candidates only to produce diagnostics; it never silently substitutes one after launch review.

Preflight checks:

- executable exists and can run `--version`
- custom-command/profile coexistence warning and command precedence
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

Canonical error evidence is an `events.jsonl` record with `record:"error"`, `kind:"backend_error"`, and an `error` object containing class, code, retryable flag, summary, detail, frozen backend path/version, stderr reference, call number, and timestamp. `state.json` references the latest error event ID; decision metadata retains call-local evidence. Known permanent stderr such as `requires a newer version of Codex` consumes no retry budget. A setup-detected permanent error starts zero backend processes and leaves calls/retry at zero. A runtime-discovered permanent error records one failed backend attempt and schedules zero retries. Output-invalid performs one explicitly labeled repair attempt that counts against the decision budget, then halts if invalid. Transient retries use the configured retry limit and backoff.

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

Phase 1 preserves the watcher state machine but adds an engine-enforced owner lease; current shell EXIT traps alone are insufficient for a native owner.

Owner descriptors are canonical version-1 JSON:

- `split`: monitor pane ID, owner PID, random 128-bit token, heartbeat path
- `popup`: no pane ID, owner PID, token, heartbeat path
- `detached`: no active UI owner; target-pane liveness owns the run
- `viewer`: read-only and never owns or controls the run

The Go owner atomically refreshes a token-bearing heartbeat once per second. The Bash watcher checks token and heartbeat age during idle waits, retry delays, capture, delivery, verification, and backend-call polling; split owners also require the pane to remain live. A three-second stale lease stops the watcher and complete backend tree. The random token prevents an unrelated reused PID from satisfying the lease. Owner metadata is persisted before the first `CREATED`/`ARMED` state and survives every pointer rewrite.

Popup `Enter` first submits a run-scoped `detach` control and waits for its acknowledgement changing the descriptor to `detached`; only then may the process exit while the run continues. Popup crash/SIGKILL without that transition stops the run. An attached viewer is read-only. A detached active run may transfer ownership only through a separate atomic `takeover-owner` control that verifies the run is still detached.

Control commands are asynchronous from the TUI's perspective:

1. invoke the engine command with target/run identity
2. show the request as pending
3. wait for a canonical event/state acknowledgement
4. show success only after acknowledgement
5. show a loud control failure if acknowledgement does not arrive within the bounded timeout

The TUI never reports success solely because a shell command exited zero.

If the TUI process exits unexpectedly, the lease expires and engine-side owner-GC stops the watcher and backend tree even if tmux leaves the pane process state unusual. Target-pane disappearance always stops the run. `scripts/ai-monitor.sh` is not deleted until native split death, forced process death, popup crash, explicit popup detach, and detached target death all pass the process-tree suite.

## Distribution And Installation

Release artifacts are built for:

- `darwin/arm64`
- `darwin/amd64`
- `linux/arm64`
- `linux/amd64`

Each release includes SHA-256 checksums. The source repository does not commit platform binaries.

`scripts/native-launcher.sh` exists independently of the binary and handles bootstrap. `@radar-supervisor-binary` may point to a user-managed binary. Otherwise the launcher uses `bin/tmux-radar` in the plugin directory. When absent, corrupt, wrong-architecture, or protocol-incompatible, the shell launcher offers matching checksummed release install, explicit source build when Go exists, or legacy UI. It does not perform hidden network work from hooks or plugin startup. Declining/failing installation keeps the navigator and AI-status functional and starts no watcher.

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
- add atomic stdin engine-start transaction, run-scoped controls, and owner leases
- keep `TMUX_RADAR_LEGACY_UI=1` rollback

Acceptance: all intentionally preserved events, lifecycle, serialized-supervision, runtime, and ownership behavior passes with the Go monitor owner; tests whose retry/schema semantics intentionally change are updated with explicit replacement assertions. Concurrent starts produce one run. Stale viewers cannot control replacement runs. Config never appears in process argv. Every owner-death/detach case passes against a backend with a child process.

After one release where automated legacy routing passes and manual release acceptance proves native/legacy switching in both menu entrypoints, the readline/advanced field-name setup loop may be deleted. `scripts/ai-monitor.sh` is deleted only after the native owner lease matrix passes; elapsed release time alone is not a deletion gate.

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
- explicit schema v0/v1 fixtures for config, state, events, final, decision metadata, controls, owner and start records; additive unknown fields and unsupported-major rejection
- incremental JSONL tailing, replacement, truncation, partial final line
- permanent/transient/output-invalid/policy/lifecycle classification
- footer degradation and width-safe rendering
- CJK grapheme editing and exact JSON round-trip
- run-scoped control idempotency, stale-run refusal, correlated acknowledgement, and timeout behavior
- atomic per-pane start reservation, readiness failure cleanup, and argv privacy

### Automated tmux

- `80x24`: popup setup/live console, minimum controls visible
- `120x30`: popup because the 121-column split invariant is not met
- `121x30`: minimum right pane, 56-column monitor, divider, and 64-column target
- `150x40`: compact right console
- `284x54`: full setup form and live views
- resize content inside its existing split/popup without losing form values/view/scroll position; no implicit surface migration
- close split monitor, SIGKILL native owner, crash popup, close detached target, `q`, and `Ctrl-C` process-tree cleanup
- popup Enter detach acknowledgement before run continuation
- sequential duplicate selects existing monitor; concurrent duplicate creates exactly one run
- stale run A controls cannot change replacement run B on the same pane
- missing/corrupt/wrong-architecture binary, checksum failure, and protocol mismatch start zero watchers and preserve legacy routing
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
- Phase 1 start transport: protocol-v1 JSON stdin, atomic per-pane reservation, child-ready handshake
- Phase 1 control transport: run-scoped idempotent `ai.sh control` plus correlated journal acknowledgement
- Native owner liveness: token-bearing one-second heartbeat, engine-enforced three-second lease
- tmux layout/bootstrap ownership: one plugin shell launcher shared by both menu entrypoints
- Default model/effort: `gpt-5.6-luna` / `high`
- Narrow layout: same binary in popup
- Browser/web UI: none
- Full rewrite before parity: rejected
- Silent model fallback: rejected

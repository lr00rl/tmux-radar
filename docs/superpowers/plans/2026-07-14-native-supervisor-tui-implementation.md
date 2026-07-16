# Native Supervisor TUI Phase 0-1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a production-usable Go terminal interface for tmux-radar supervision, including backend preflight and permanent-error handling, while retaining the proven Bash watcher as the Phase 1 engine.

**Architecture:** `tmux-radar.tmux` creates the right pane or narrow popup and execs one `tmux-radar` Go binary. The binary owns setup, launch review, preflight, canonical run readers, live views, and controls. It starts and controls the existing Bash engine through JSON stdin and existing CLI commands; run directories remain authoritative.

**Tech Stack:** Go 1.24+; `charm.land/bubbletea/v2@v2.0.8`; `charm.land/bubbles/v2@v2.1.1`; `charm.land/lipgloss/v2@v2.0.5`; Bash 3.2-compatible shell; jq; tmux; Go unit tests plus existing shell and real-tmux suites.

---

## Incident Gate: Process And Performance Safety

Development is blocked on this gate after an interrupted supervision test left 34
orphan fake `tmux wait-for` processes polling a deleted temporary directory every
10 ms. The resulting external `sleep` fork loop created roughly 1,500 processes
per second and exhausted an 8-core host for three days. Two stale legacy monitor
processes also redrew once per second for about 47 hours.

- [x] A fake waiter exits when its owner PID or liveness file disappears and has
  an absolute maximum lifetime.
- [x] No waiter, timer, backend, monitor, or watcher survives normal stop, failed
  assertion, `TERM`, `INT`, or `HUP` cleanup paths.
- [x] Test cleanup proves zero owned PIDs remain before deleting temporary state.
- [x] No supervision test fixture uses an unbounded 5-10 ms external-process
  polling loop.
- [x] A legacy monitor validates watcher/run ownership on every wake and exits
  when the pointer is stale instead of trusting file existence alone.
- [x] Idle lifecycle and monitor checks have explicit bounded-work regression
  evidence; a passing functional suite is insufficient without a post-test
  process-table audit.
- [ ] The native TUI replaces the legacy multi-process redraw path before live
  deployment; the Bash monitor remains a bounded fallback, not the primary UI.

Do not resume feature tasks below until the focused process-safety suite passes,
the full supervision suite exits with zero residual processes, and fresh CPU/load
sampling shows no fork churn.

---

## Delivery Boundary

This plan implements Phase 0 and Phase 1 from `docs/superpowers/specs/2026-07-14-native-supervisor-tui-design.md`. It deliberately does not port the watcher into Go. After this plan passes real tmux acceptance, write a separate Phase 2-3 plan for the engine-neutral replay harness and opt-in Go engine.

## File Map

Create:

- `go.mod`, `go.sum`: Go module and pinned TUI dependencies.
- `cmd/tmux-radar/main.go`: CLI parsing and process exit contract.
- `internal/runmodel/types.go`: versioned config, state, event, decision, final, and start-result types.
- `internal/runmodel/config.go`: defaults, provenance, validation, and JSON encoding.
- `internal/runmodel/reader.go`: atomic state reads and incremental JSONL tailing.
- `internal/runmodel/config_test.go`, `internal/runmodel/reader_test.go`: contract tests.
- `internal/preflight/preflight.go`, `internal/preflight/preflight_test.go`: backend resolution and diagnostics.
- `internal/enginebridge/bridge.go`, `internal/enginebridge/bridge_test.go`: stdin start protocol and control acknowledgement.
- `internal/tui/app.go`: root Bubble Tea state and phase transitions.
- `internal/tui/setup.go`: goal/config form.
- `internal/tui/live.go`: live console reducer and viewport behavior.
- `internal/tui/views.go`: Timeline, Decision, Screen, Config, Logs renderers.
- `internal/tui/keys.go`, `internal/tui/styles.go`: adaptive keys and semantic styles.
- `internal/tui/setup_test.go`, `internal/tui/live_test.go`, `internal/tui/render_test.go`: reducer and fixed-size rendering tests.
- `scripts/build-native.sh`: reproducible local binary build.
- `scripts/native-launcher.sh`: shared duplicate/bootstrap/geometry/surface entrypoint.
- `scripts/ensure-native.sh`: explicit release install/source-build/legacy selection.
- `tests/test_ai_preflight.sh`: Phase 0 shell regression tests.
- `tests/test_native_tui.sh`: CLI/engine bridge/tmux layout tests.
- `tests/test_native_owner.sh`: owner lease, detach, stale control, and concurrent start tests.
- `.github/workflows/native-release.yml`: four-platform release build and checksums.

Modify:

- `scripts/ai.sh`: preserve PATH, Luna/high defaults, preflight/error classification, `engine-start`, external monitor ownership, JSON errors.
- `scripts/lib/ai-runtime.sh`: additive schema version and structured backend-error event support.
- `tmux-radar.tmux`: route w/W/v to the native launcher with legacy rollback.
- `tests/test_ai_supervision.sh`: permanent versus retryable backend behavior.
- `tests/test_ai_console.sh`: native entrypoint/layout assertions.
- `tests/test_ai_lifecycle.sh`: external monitor-owner cleanup.
- `README.md`: native setup, controls, errors, install, fallback, logs.

## Task 1: Lock The Backend-Resolution Failure

**Files:**
- Create: `tests/test_ai_preflight.sh`
- Modify: `tests/test_ai_supervision.sh`

- [ ] **Step 1: Add a fake old Codex and newer PATH candidate fixture**

Create executable fixtures inside the test temporary directory. The old fixture prints `codex-cli 0.139.0` for `--version` and emits the known Luna incompatibility on `exec`; the new fixture prints `codex-cli 0.144.3`.

```bash
cat > "$TMP/old-bin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then echo 'codex-cli 0.139.0'; exit 0; fi
echo "The 'gpt-5.6-luna' model requires a newer version of Codex." >&2
exit 1
SH
```

- [ ] **Step 2: Assert current behavior fails the new contract**

Run:

```bash
bash tests/test_ai_preflight.sh
```

Expected: FAIL because `ai.sh` prepends `/opt/homebrew/bin`, has no `doctor-json`, and retries the permanent model/version error.

- [ ] **Step 3: Add supervision assertions for zero retry budget**

Extend the existing fake-backend harness to assert a `config-permanent` result creates one failed attempt at most, schedules no retry, and records the exact stderr evidence path.

- [ ] **Step 4: Commit the red tests**

```bash
git add tests/test_ai_preflight.sh tests/test_ai_supervision.sh
git commit -m "Prove backend incompatibility before changing supervision" -m "Confidence: high
Scope-risk: narrow
Tested: New regression fails against the current PATH and retry behavior"
```

## Task 2: Preserve PATH And Make Luna/High The Built-In Contract

**Files:**
- Modify: `scripts/ai.sh`
- Test: `tests/test_ai_preflight.sh`, `tests/test_ai_console.sh`

- [ ] **Step 1: Remove PATH precedence inversion**

Replace the unconditional prepend with an append that never outranks the inherited environment:

```bash
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
```

Resolve Codex once per run with a helper that honors `@radar-ai-codex-path`, then inherited PATH, and records an absolute path. Separate `codex` and `custom-command` backend modes. A custom command bypasses Codex diagnostics; when command and profile coexist, preserve command precedence and emit a warning.

- [ ] **Step 2: Change code defaults and documentation comments**

Set both config construction and top-of-file option documentation to:

```text
model  gpt-5.6-luna
effort high
```

- [ ] **Step 3: Add JSON doctor output**

Add internal/public `doctor-json` output containing:

```json
{"ok":true,"backend":{"path":"...","version":"0.144.3","source":"path"},"model":"gpt-5.6-luna","effort":"high","candidates":[]}
```

On an old selected binary with a newer candidate, set `ok:false`, `class:"config-permanent"`, and include both paths/versions without silently switching. Profile mode must execute the same pinned Codex path; `_brain`, labels, metadata, and config must consume one frozen backend object even if PATH later changes.

- [ ] **Step 4: Run targeted tests**

```bash
bash tests/test_ai_preflight.sh
bash tests/test_ai_console.sh
bash -n scripts/ai.sh
shellcheck scripts/ai.sh tests/test_ai_preflight.sh
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/ai.sh tests/test_ai_preflight.sh tests/test_ai_console.sh
git commit -m "Resolve the configured brain before supervision spends a call" -m "Rejected: Silent fallback to a newer PATH candidate | launch review must remain truthful
Confidence: high
Scope-risk: moderate
Tested: preflight and console suites; bash -n; shellcheck"
```

## Task 3: Classify Permanent, Transient, Invalid, And Policy Outcomes

**Files:**
- Modify: `scripts/ai.sh`
- Modify: `scripts/lib/ai-runtime.sh`
- Test: `tests/test_ai_supervision.sh`, `tests/test_ai_runtime.sh`

- [ ] **Step 1: Add a stable classifier**

Implement `_classify_backend_failure <rc> <stderr-file> <schema-valid>` returning JSON with `class`, `retryable`, `summary`, and `detail`. Match known permanent version/model/auth/profile failures before generic transport failures.

- [ ] **Step 2: Journal structured errors**

Append `backend_error` with fields:

```json
{"error_class":"config-permanent","retryable":false,"backend_path":"...","backend_version":"...","stderr_path":"...","call":1}
```

Add `schema_version:1` to new run config/state/final documents while retaining version-0 readers.

- [ ] **Step 3: Gate retry scheduling**

Permanent failures transition directly to `PAUSED_ERROR`. Transient failures use bounded backoff. Invalid output receives one explicitly labeled repair attempt, counted against `max_decisions`, then pauses. Policy refusal remains `policy_halt`, not `decision_failed`. Replace the old malformed-output retry expectation rather than trying to preserve contradictory semantics.

- [ ] **Step 4: Run targeted suites**

```bash
bash tests/test_ai_supervision.sh
bash tests/test_ai_runtime.sh
```

Expected: all existing and new scenarios pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/ai.sh scripts/lib/ai-runtime.sh tests/test_ai_supervision.sh tests/test_ai_runtime.sh
git commit -m "Stop retrying failures that cannot heal" -m "Directive: User-visible backend failures must include class and evidence, never only rc
Confidence: high
Scope-risk: moderate
Tested: serialized supervision and runtime suites"
```

## Task 4: Create The Versioned Go Run Model

**Files:**
- Create: `go.mod`, `go.sum`
- Create: `internal/runmodel/types.go`, `internal/runmodel/config.go`
- Create: `internal/runmodel/config_test.go`

- [ ] **Step 1: Initialize and pin the module**

```bash
go mod init github.com/lr00rl/tmux-radar
go get charm.land/bubbletea/v2@v2.0.8
go get charm.land/bubbles/v2@v2.1.1
go get charm.land/lipgloss/v2@v2.0.5
```

- [ ] **Step 2: Write failing default/provenance tests**

Tests must assert Luna/high defaults, exact CJK goal bytes, enum/numeric validation, version-0 compatibility, and version-1 encoding.

- [ ] **Step 3: Implement typed contracts**

Define `Value[T]`, `Config`, `State`, `Event`, `Decision`, `Final`, `BackendError`, and `StartResult`. Keep unknown JSON fields readable by avoiding strict decoding in run readers; use strict validation only for launch config.

- [ ] **Step 4: Verify**

```bash
go test ./internal/runmodel
go vet ./internal/runmodel
```

- [ ] **Step 5: Commit**

```bash
git add go.mod go.sum internal/runmodel
git commit -m "Give the native console one versioned source of truth" -m "Constraint: Legacy schema-version-zero runs remain readable
Confidence: high
Scope-risk: narrow
Tested: runmodel unit tests; go vet"
```

## Task 5: Implement Incremental Run Reading

**Files:**
- Create: `internal/runmodel/reader.go`, `internal/runmodel/reader_test.go`

- [ ] **Step 1: Write failing reader tests**

Cover atomic `state.json` replacement, partial final JSONL line, append from last offset, truncation, inode replacement, unknown event fields, and a missing optional file.

- [ ] **Step 2: Implement `Reader`**

Expose:

```go
func Open(runDir string) (*Reader, error)
func (r *Reader) Snapshot() (Snapshot, bool, error)
func (r *Reader) PollEvents() ([]Event, error)
```

The boolean reports whether derived state changed. No external file-watch dependency is added.

- [ ] **Step 3: Verify and commit**

```bash
go test ./internal/runmodel -race
git add internal/runmodel
git commit -m "Replay supervision evidence without coupling UI and engine lifetimes" -m "Confidence: high
Scope-risk: narrow
Tested: run reader tests under race detector"
```

## Task 6: Build Atomic Start And Run-Scoped Control Protocols

**Files:**
- Create: `internal/preflight/preflight.go`, `internal/preflight/preflight_test.go`
- Create: `internal/enginebridge/bridge.go`, `internal/enginebridge/bridge_test.go`
- Modify: `scripts/ai.sh`, `scripts/lib/ai-runtime.sh`
- Test: `tests/test_native_owner.sh`

- [ ] **Step 1: Test executable resolution and diagnostics**

Use temporary PATH fixtures. Assert explicit path wins, inherited PATH order is preserved, candidates are diagnostic only, custom-command bypasses Codex checks, profile uses the pinned executable, malformed doctor JSON fails closed, and no model command runs during preflight.

- [ ] **Step 2: Implement preflight**

Call `ai.sh doctor-json` and map its JSON into typed `Result`. Keep Bash as the single Phase 1 authority for model compatibility rules.

- [ ] **Step 3: Add strict protocol-v1 request/result types**

Define request fields for protocol/schema version, state root, authoritative target, immutable config, and nullable owner descriptor. Reject unknown fields, target mismatch, dead identity, and unsupported versions before creating files/processes. Define one-line stdout result and stderr-only diagnostics.

- [ ] **Step 4: Make engine-start an atomic transaction**

Acquire an atomic per-pane launch directory, return `already-active` for a live pointer, pre-create the run/config/owner/start pointer, launch a watcher that opens that run without config in argv, and wait for a ready record after traps and first state. On timeout/failure, kill partial descendants, finalize startup failure, remove the pointer/reservation, and return stable JSON. Add concurrent-start and `ps` argv privacy tests.

- [ ] **Step 5: Add run-scoped idempotent controls**

Implement `ai.sh control <run-id> <target-pane> <action> <request-id>`. Atomically verify pointer generation before mutation. Persist request and acknowledgement with the same ID. Duplicate IDs return the stored result. Pause waits for `PAUSED_USER`; resume for `resumed`; reassess for accepted manual event; keep for persisted keep acknowledgement; stop for that run's terminal `final.json`. Stale viewers never touch replacement runs.

- [ ] **Step 6: Implement Go bridge**

Expose `Start(ctx, request)` and `Control(ctx, runID, pane, action, requestID)`. Use five-second acknowledgement timeout and ten seconds for stop. Timeout never retries or claims success.

- [ ] **Step 7: Verify and commit**

```bash
go test ./internal/preflight ./internal/enginebridge -race
bash tests/test_ai_preflight.sh
bash tests/test_ai_lifecycle.sh
bash tests/test_native_owner.sh
git add internal/preflight internal/enginebridge scripts/ai.sh tests
git commit -m "Bridge the native surface to the proven watcher without hidden state" -m "Rejected: Configuration in argv | goals and paths may be private or multiline
Confidence: high
Scope-risk: moderate
Tested: bridge race tests; preflight, owner, concurrent-start, stale-control, argv-privacy, and lifecycle suites"
```

## Task 7: Add Engine-Enforced Native Owner Leases

**Files:**
- Modify: `scripts/ai.sh`, `scripts/lib/ai-runtime.sh`
- Modify: `internal/enginebridge/bridge.go`
- Test: `tests/test_native_owner.sh`, `tests/test_ai_lifecycle.sh`

- [ ] **Step 1: Write owner matrix tests**

Use a backend that forks a child. Cover split pane close during call, Go owner TERM/KILL, popup crash, acknowledged popup detach, detached target close, viewer read-only, heartbeat token mismatch, stale heartbeat, and owner metadata surviving pointer rewrites.

- [ ] **Step 2: Define owner descriptors and heartbeat**

Version-1 descriptors distinguish split, popup, detached, and viewer. Go writes a random 128-bit token heartbeat once per second. Split includes pane ID; popup does not. The watcher validates token and age <=3 seconds during every long wait and backend polling, and validates split pane liveness.

- [ ] **Step 3: Add canonical detach/takeover controls**

Popup Enter submits `detach` and exits only after the owner descriptor is durably `detached`. Crash without ack stops. A viewer is read-only. `takeover-owner` succeeds only from detached and atomically installs the new lease.

- [ ] **Step 4: Verify and commit**

```bash
bash tests/test_native_owner.sh
bash tests/test_ai_lifecycle.sh
git add scripts internal/enginebridge tests
git commit -m "Bind native supervision to a durable owner lease" -m "Rejected: Go EXIT handler alone | SIGKILL and popup ownership require engine-side detection
Confidence: high
Scope-risk: broad
Tested: split, popup, detach, stale lease, target death, and forked backend process-tree matrix"
```

## Task 8: Build The Setup Form Reducer

**Files:**
- Create: `internal/tui/app.go`, `setup.go`, `keys.go`, `styles.go`
- Create: `internal/tui/setup_test.go`, `render_test.go`

- [ ] **Step 1: Write reducer tests before views**

Assert initial Goal focus, CJK insertion/deletion, Tab/Shift-Tab traversal, enum selection, boolean toggle, numeric rejection, Advanced collapse counts, preset behavior for w/W/v, cancellation, launch blocking, and exact immutable config output.

- [ ] **Step 2: Implement setup state**

Use Bubbles textarea/textinput components. Keep enum/toggle controls in local typed reducers. Run preflight asynchronously through Bubble Tea commands and ignore stale results by request ID.

- [ ] **Step 3: Implement adaptive setup rendering**

Snapshot plain-text views at 40x18, 56x24, 84x40, and 96x50. Assert every row fits its width and Start remains reachable.

- [ ] **Step 4: Verify and commit**

```bash
go test ./internal/tui -run 'Setup|Render' -race
git add internal/tui
git commit -m "Make the supervision contract editable without shell field names" -m "Confidence: high
Scope-risk: moderate
Tested: setup reducer, CJK, provenance, and fixed-size render tests"
```

## Task 9: Build The Live Console

**Files:**
- Create: `internal/tui/live.go`, `views.go`, `live_test.go`

- [ ] **Step 1: Test viewport and event behavior**

Assert five views, fixed header/footer, identical-event grouping, `e` expansion, bottom-only auto-follow, new-event count while pinned, `G` resume, control pending/ack/error, permanent error detail, completion keep, and help overlay.

- [ ] **Step 2: Implement canonical polling commands**

Poll file metadata every 250ms and elapsed/countdown every second. Parse only changed files. Never redraw from a busy loop.

- [ ] **Step 3: Implement view renderers**

Timeline, Decision, Screen, Config, and Logs must use a Bubbles viewport. Config shows provenance; Logs shows full stderr through scrolling; Decision shows observable evidence, not private reasoning.

- [ ] **Step 4: Implement controls**

Keep `1-5`, `j/k`, arrows, `g/G`, `e`, `p`, `r`, `k`, `c`, `Enter`, `q`, and `?`. Confirm active stop. Shorten labels before keys disappear.

- [ ] **Step 5: Verify and commit**

```bash
go test ./internal/tui -run 'Live|Timeline|Control|Render' -race
git add internal/tui
git commit -m "Keep live supervision navigable while evidence continues to arrive" -m "Directive: Scrolling away from the bottom must disable follow until G
Confidence: high
Scope-risk: moderate
Tested: live reducer and responsive render tests under race detector"
```

## Task 10: Wire The CLI

**Files:**
- Create: `cmd/tmux-radar/main.go`
- Test: `tests/test_native_tui.sh`

- [ ] **Step 1: Write CLI contract tests**

Cover `version`, `supervisor doctor --json`, invalid arguments, setup cancellation, attach missing/finished/active runs, and engine start failure exit codes.

- [ ] **Step 2: Implement command dispatch**

Use the standard library only. Exit 0 for normal completion/cancel, 2 for usage, 3 for preflight/config permanent, 4 for engine/control failure, and 5 for incompatible protocol.

- [ ] **Step 3: Run tests and build**

```bash
go test ./... -race
go vet ./...
go build -o bin/tmux-radar ./cmd/tmux-radar
bash tests/test_native_tui.sh
```

- [ ] **Step 4: Commit**

```bash
git add cmd tests/test_native_tui.sh
git commit -m "Expose the native supervisor through one stable command surface" -m "Confidence: high
Scope-risk: narrow
Tested: all Go tests, vet, binary build, CLI shell tests"
```

## Task 11: Replace w/W/v With The Native Surface

**Files:**
- Create: `scripts/native-launcher.sh`
- Modify: `tmux-radar.tmux`
- Modify: `scripts/ai.sh`
- Modify: `tests/test_ai_console.sh`, `tests/test_ai_lifecycle.sh`, `tests/test_native_tui.sh`, `tests/test_native_owner.sh`

- [ ] **Step 1: Add failing binding/layout tests**

Assert both native TPM and `cmd_menu` w/W/v call one shell launcher with quick/always-allow/advanced presets. Test popup at target width 120, minimum split at 121 with 56 monitor + divider + 64 target, already-narrow target despite wide client, selected setup focus, sequential duplicate before surface creation, concurrent duplicate through engine reservation, cancel cleanup, and `TMUX_RADAR_LEGACY_UI=1` rollback.

- [ ] **Step 2: Add launcher helpers**

Implement bootstrap outside the binary: duplicate lookup, legacy override, configured/install binary resolution, missing/corrupt/wrong-architecture/protocol handling, explicit install/build/legacy choices, actual-target geometry, split/popup creation, cancellation cleanup, and initial focus. Do not launch a watcher until setup returns a validated config.

- [ ] **Step 3: Preserve strict ownership**

The launcher passes nullable monitor pane and correct owner kind. Engine reservation remains authoritative against concurrent launch. Cancellation closes only the newly created surface. Resize only reflows the current TUI surface and never claims split/popup migration.

- [ ] **Step 4: Verify and commit**

```bash
bash tests/test_ai_console.sh
bash tests/test_ai_lifecycle.sh
bash tests/test_native_tui.sh
bash tests/test_native_owner.sh
bash -n tmux-radar.tmux scripts/ai.sh scripts/native-launcher.sh
shellcheck tmux-radar.tmux scripts/ai.sh scripts/native-launcher.sh tests/test_native_tui.sh tests/test_native_owner.sh
git add tmux-radar.tmux scripts/ai.sh tests
git commit -m "Put one native terminal surface behind every supervision entry" -m "Constraint: Legacy UI remains available for one release
Confidence: high
Scope-risk: broad
Tested: console, lifecycle, bootstrap failure, geometry, duplicate, native owner, legacy routing, bash syntax, shellcheck"
```

## Task 12: Build, Install, And Release Safely

**Files:**
- Create: `scripts/build-native.sh`, `scripts/ensure-native.sh`
- Create: `.github/workflows/native-release.yml`
- Modify: `tests/test_native_tui.sh`

- [ ] **Step 1: Test platform mapping and checksum refusal**

Assert darwin/linux and arm64/amd64 asset names, explicit install only, checksum mismatch failure, configured binary override, source build fallback, and legacy selection.

- [ ] **Step 2: Implement local build**

`build-native.sh` builds `bin/tmux-radar` with version/commit/date ldflags and no cgo.

- [ ] **Step 3: Implement explicit installer**

Download only after an explicit supervisor launch confirmation, verify SHA-256, write to a temporary file, chmod, then atomically rename. Hooks/plugin startup never perform network I/O.

- [ ] **Step 4: Add release workflow**

Build four archives, run Go and shell suites first, generate checksums, and attach artifacts only for version tags.

- [ ] **Step 5: Verify and commit**

```bash
bash tests/test_native_tui.sh
bash scripts/build-native.sh
./bin/tmux-radar version
git add scripts .github tests/test_native_tui.sh
git commit -m "Make the native console installable without hidden network behavior" -m "Confidence: high
Scope-risk: moderate
Tested: installer fixtures, local build, version output"
```

## Task 13: Documentation And Full Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-14-native-supervisor-tui-design.md` only if implementation evidence requires a factual correction

- [ ] **Step 1: Document the actual workflow**

Cover w/W/v, setup navigation, controls, default Luna/high, doctor output, error classes, install options, legacy fallback, run logs, privacy, and attach/report.

- [ ] **Step 2: Run static verification**

```bash
gofmt -w cmd internal
go test ./... -race
go vet ./...
bash -n tmux-radar.tmux scripts/*.sh scripts/lib/*.sh tests/*.sh
shellcheck tmux-radar.tmux scripts/*.sh scripts/lib/*.sh tests/*.sh
git diff --check
```

- [ ] **Step 3: Run all shell suites**

```bash
bash tests/test_ai_events.sh
bash tests/test_ai_preflight.sh
bash tests/test_ai_lifecycle.sh
bash tests/test_ai_supervision.sh
bash tests/test_ai_console.sh
bash tests/test_ai_runtime.sh
bash tests/test_native_tui.sh
bash tests/test_native_owner.sh
```

- [ ] **Step 4: Run real tmux acceptance**

Verify `80x24`, `120x30` popup, `121x30` minimum split, `150x40`, and `284x54`; mixed ASCII/CJK editing; in-surface resize reflow; timeline pinned scroll; permanent error; transient retry; model decision; run-scoped pause/reassess/keep/stop; stale viewer refusal; target/split owner/popup owner close; explicit detach; sequential/concurrent duplicate launch; completion and read-only reattach. Capture pane evidence and process audits in a private temporary artifact directory.

- [ ] **Step 5: Commit documentation/evidence fixes**

```bash
git add README.md docs cmd internal scripts tests tmux-radar.tmux go.mod go.sum .github
git commit -m "Document the native supervisor only after its full workflow is proven" -m "Confidence: high
Scope-risk: moderate
Tested: Go race/vet/build; all shell suites; real tmux size and lifecycle matrix
Not-tested: Platforms not represented by local execution are covered by cross-build and CI"
```

## Task 14: Review, Integrate, Deploy, And Start Phase 2 Planning

**Files:**
- Review all changed files; no new implementation file is implied by this task.

- [ ] **Step 1: Run separate code and UX reviews**

Require findings-first reviews for correctness/security and terminal interaction. Resolve all high/medium findings and rerun affected tests.

- [ ] **Step 2: Verify clean ownership and process state**

Audit for test tmux sessions, watcher/backend descendants, stale run pointers, and unowned Spark/Luna processes. Preserve unrelated user runs.

- [ ] **Step 3: Fast-forward main and push**

Merge the feature branch with `--ff-only`, push `origin main`, fast-forward `~/.tmux/plugins/tmux-radar`, build/install the native binary, and reload `tmux-radar.tmux`.

- [ ] **Step 4: Verify the live key table and hooks**

Confirm `prefix+A` routes w/W/v to the installed native binary and hook status remains complete.

- [ ] **Step 5: Create the Phase 2-3 plan**

Use the accepted run journals and Phase 1 evidence to write `docs/superpowers/plans/2026-07-XX-native-supervisor-engine-migration.md`. Do not begin engine migration until the parity fixtures in that plan fail against a deliberately incorrect engine.

## Plan Self-Review Checklist

- Every Phase 0-1 success criterion maps to a task.
- No engine behavior moves to Go before the separate parity plan.
- No launch configuration is exposed in argv or an unsafe temporary file.
- Permanent failures consume zero retries.
- Existing control success is acknowledged through canonical state/events.
- Every control is run-scoped, request-correlated, idempotent, and stale-generation safe.
- Engine start is atomically reserved, pre-creates its run, waits for child readiness, and keeps config out of argv.
- Split/popup/detached/viewer ownership has an engine-enforced token heartbeat and explicit detach transition.
- Missing native binary is handled by the shell launcher before any binary invocation.
- CJK, width, resize, scroll, ownership, duplicate launch, and rollback are explicit gates.
- Dependency versions come from current official releases.
- No placeholders or unspecified test commands remain.

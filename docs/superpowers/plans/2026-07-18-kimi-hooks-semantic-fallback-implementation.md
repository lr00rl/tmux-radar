# Kimi Hooks And Semantic Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Kimi a first-class hooked agent, expose a safe generic hook API, provide a low-cost semantic fallback for unhooked agents, eliminate orphanable idle waiters, document the ecosystem, and release v0.1.2.

**Architecture:** Agent-specific installers and adapters translate vendor events into one normalized `agent-event` lifecycle handled by the existing registry, marks, and supervisor inbox. Native hooks trigger immediately; unhooked agents use a deduplicated temporal projection of the bottom 20 pane lines. The Bash watcher retains serialized decision semantics but replaces background waiter/timer children with one in-process deadline loop.

**Tech Stack:** Bash 3.2; jq; tmux; Go 1.24+ typed configuration and Bubble Tea TUI; shell integration tests; Go unit tests; no new dependencies.

---

## File Map

Create:

- `docs/guides/configuration.md`: complete option reference and tuning profiles.
- `docs/guides/agent-hooks.md`: Kimi and custom-agent hook tutorial.
- `docs/guides/development.md`: architecture, testing, lifecycle, performance, and release guide.
- `examples/hooks/custom-agent-adapter.sh`: normalized custom-agent adapter template.

Modify:

- `scripts/install-hooks.sh`: Kimi TOML install, status, uninstall, backup, symlink preservation, and rollback.
- `scripts/needinput-notify.sh`: Kimi adapter and strict public `agent-event` command.
- `scripts/ai.sh`: fallback config, temporal projection, childless waits, fallback evidence budget, and terminal cleanup evidence.
- `internal/runmodel/types.go`: typed `fallback_capture_lines` config value.
- `internal/runmodel/config.go`: default, legacy decode, and validation.
- `internal/tui/setup_fields.go`: advanced Context field.
- `internal/tui/views.go`: fallback capture detail and honest trigger labels.
- `README.md`: Kimi support, semantic fallback, and guide navigation.
- `docs/design-precise-ai-tracking.md`: normalized event architecture and Kimi lifecycle.
- `tests/test_install.sh`: Kimi installer coverage.
- `tests/test_ai_events.sh`: installer ownership, status, and rollback coverage.
- `tests/test_registry.sh`: Kimi and generic lifecycle coverage.
- `tests/test_safety.sh`: malformed generic-event safety.
- `tests/test_ai_supervision.sh`: temporal fallback and ARMED stop regressions.
- `tests/test_idle_process_budget.sh`: childless idle-process budget.
- `tests/test_ai_console.sh`: new config field and provenance.
- Go tests under `internal/runmodel` and `internal/tui`.

## Task 1: Lock The Kimi Event Contract

**Files:**
- Test: `tests/test_registry.sh`
- Test: `tests/test_safety.sh`

- [ ] **Step 1: Add failing Kimi lifecycle tests**

Feed documented Kimi payloads to `needinput-notify.sh kimi-hook` and assert:

```text
SessionStart       -> kimi registry row, state=working
PermissionRequest  -> approval mark and approval inbox event
PermissionResult   -> mark cleared and user_resumed inbox event
UserPromptSubmit   -> state=working and stale action cleared
Stop               -> done mark and turn_complete inbox event
Interrupt          -> stale action cleared and user_resumed inbox event
SessionEnd         -> registry/action cleanup with done mark retained
```

Include two session IDs in one pane and assert one session never clears the other.

- [ ] **Step 2: Add failing strict generic-event tests**

Invoke:

```bash
printf '%s\n' '{"session_id":"s-1","pane":"%1","pid":123,"process":"demo"}' |
  "$NOTIFY" agent-event demo approval
```

Assert stable mark/registry key identity. Assert malformed JSON, unknown event, invalid pane, invalid PID, and missing session ID return 2 without changing state.

- [ ] **Step 3: Run RED**

Run:

```bash
bash tests/test_registry.sh
bash tests/test_safety.sh
```

Expected: FAIL because `kimi-hook` and `agent-event` are not implemented.

- [ ] **Step 4: Commit the red tests**

Use a Lore commit recording the normalized lifecycle contract and the expected failing commands.

## Task 2: Implement The Normalized Event Layer And Kimi Adapter

**Files:**
- Modify: `scripts/needinput-notify.sh`
- Test: `tests/test_registry.sh`
- Test: `tests/test_safety.sh`

- [ ] **Step 1: Add strict JSON and identity helpers**

Implement one-object stdin parsing, canonical event validation, stable `s:<session_id>` keys, optional pane/PID validation, process-ancestry pane resolution, and source-independent registry liveness for registered agent kinds.

- [ ] **Step 2: Implement `cmd_agent_event`**

Map the eight normalized events to existing locked registry, mark, notification, and `_watch_event` helpers. Keep key ownership session-specific and make repeated events idempotent.

- [ ] **Step 3: Implement `cmd_kimi_hook`**

Read one Kimi payload, validate `hook_event_name`, map the seven official events, and pass a normalized envelope to the shared event function without writing state twice.

- [ ] **Step 4: Run GREEN**

Run:

```bash
bash tests/test_registry.sh
bash tests/test_safety.sh
bash -n scripts/needinput-notify.sh
```

Expected: PASS with no stdout from successful hook commands.

- [ ] **Step 5: Commit**

Commit notifier, tests, and the explicit event mapping with Lore trailers.

## Task 3: Lock Kimi Installer Ownership

**Files:**
- Test: `tests/test_install.sh`
- Test: `tests/test_ai_events.sh`

- [ ] **Step 1: Add failing installation tests**

Use isolated HOME/config paths and assert:

- Kimi absent means skip without creating `~/.kimi-code`.
- Kimi present creates seven managed `[[hooks]]` tables.
- Existing comments, scalar settings, and user hooks are byte-preserved outside the block.
- Reinstall is idempotent.
- Paths containing spaces, `&`, `#`, and quotes remain valid TOML commands.
- Config symlinks remain symlinks.
- Status reports `7/7`, partial installation, and absence.
- Uninstall removes only the managed block.
- Duplicate/misaligned markers fail without mutation.
- A later installer failure rolls Kimi back.

- [ ] **Step 2: Run RED**

Run:

```bash
bash tests/test_install.sh
bash tests/test_ai_events.sh
```

Expected: FAIL because Kimi is not part of installer dispatch.

## Task 4: Implement Kimi TOML Installation

**Files:**
- Modify: `scripts/install-hooks.sh`
- Test: `tests/test_install.sh`
- Test: `tests/test_ai_events.sh`

- [ ] **Step 1: Add Kimi configuration and ownership helpers**

Define the config path override, seven-event array, exact begin/end markers, shell-command quoting, TOML basic-string encoding, block validation, and Kimi presence detection.

- [ ] **Step 2: Add install, uninstall, and status**

Use existing `_replace_file`, backups, and transaction helpers. Add Kimi's config path to install and uninstall transaction snapshots and dispatch.

- [ ] **Step 3: Run GREEN**

Run:

```bash
bash tests/test_install.sh
bash tests/test_ai_events.sh
bash -n scripts/install-hooks.sh
```

Expected: PASS with preserved user files and seven exact radar events.

- [ ] **Step 4: Commit**

Commit installer and tests with ownership and rollback directives in Lore trailers.

## Task 5: Lock Fallback Configuration And TUI Provenance

**Files:**
- Test: `internal/runmodel/config_test.go`
- Test: `internal/tui/setup_test.go`
- Test: `tests/test_ai_console.sh`

- [ ] **Step 1: Add failing typed-config tests**

Assert `fallback_capture_lines=20`, source `default`, accepted range 8-200, strict config transit, legacy defaulting, advanced Context visibility, tmux provenance, and setup override serialization.

- [ ] **Step 2: Run RED**

Run:

```bash
go test ./internal/runmodel ./internal/tui
bash tests/test_ai_console.sh
```

Expected: FAIL because the field is absent.

## Task 6: Implement Fallback Configuration

**Files:**
- Modify: `internal/runmodel/types.go`
- Modify: `internal/runmodel/config.go`
- Modify: `internal/tui/setup_fields.go`
- Modify: `internal/tui/views.go`
- Modify: `scripts/ai.sh`
- Test: Go config/TUI tests
- Test: `tests/test_ai_console.sh`

- [ ] **Step 1: Add the typed value and shell config plumbing**

Add `FallbackCaptureLines Value[int]`, default 20, range 8-200, tmux option `@radar-ai-fallback-capture-lines`, runtime variable, strict request keys, provenance, Context group, and advanced field.

- [ ] **Step 2: Run GREEN**

Run:

```bash
go test ./internal/runmodel ./internal/tui
bash tests/test_ai_console.sh
bash -n scripts/ai.sh
```

Expected: PASS.

- [ ] **Step 3: Commit**

Commit config plumbing separately so later fallback behavior has a stable typed contract.

## Task 7: Lock Temporal Projection And Cost Dedupe

**Files:**
- Test: `tests/test_ai_supervision.sh`

- [ ] **Step 1: Add a dynamic Kimi-like approval fixture**

Return two 20-line captures where the approval body is unchanged but elapsed/footer rows differ. Assert one `screen_idle` model call occurs after the threshold.

- [ ] **Step 2: Add cost and capture-budget assertions**

Assert:

- the same stable projection does not call the model twice;
- continuously changing content with no sufficient stable projection calls zero times;
- a meaningful new stable projection can call once;
- native approval capture uses `capture_lines`;
- `screen_idle` capture uses `fallback_capture_lines`;
- poll starts after model/verification completion.

- [ ] **Step 3: Run RED**

Run:

```bash
bash tests/test_ai_supervision.sh
```

Expected: the dynamic approval case never calls the model under raw checksum comparison.

## Task 8: Implement Temporal Semantic Fallback

**Files:**
- Modify: `scripts/ai.sh`
- Test: `tests/test_ai_supervision.sh`

- [ ] **Step 1: Implement bounded capture normalization and stable projection**

Capture the configured bottom lines, normalize only CR/trailing whitespace, compute an order-preserving unchanged-line projection, require a non-empty minimum evidence set, and fingerprint it for cost deduplication. Persist one immutable normalized capture per fallback decision, feed those same bytes to the model, and use a direct byte comparison rather than a digest for delivery authority.

- [ ] **Step 2: Add projection threshold and dedupe state**

Track previous sample, candidate projection, consecutive count, and last assessed projection per watcher. Record projection metadata without raw content unless logging permits it.

- [ ] **Step 3: Use the fallback evidence budget**

For `screen_idle`, pass only the fallback capture to `_brain`; retain normal capture lines for native events. Rebaseline after event, decision, verification, takeover, and meaningful screen change.

- [ ] **Step 4: Run GREEN**

Run:

```bash
bash tests/test_ai_supervision.sh
bash -n scripts/ai.sh
```

Expected: all native and fallback cases pass with bounded call counts.

- [ ] **Step 5: Commit**

Commit semantic fallback with explicit cost and non-regex directives.

## Task 9: Lock The ARMED Exit Race And Process Budget

**Files:**
- Test: `tests/test_ai_supervision.sh`
- Test: `tests/test_idle_process_budget.sh`
- Test: `tests/test_native_owner.sh`

- [ ] **Step 1: Reproduce the live orphan shape**

Start a watcher with a long poll, wait until ARMED, stop it while the idle waiter is active, and assert:

- terminal final evidence exists;
- live pointer is removed;
- watcher is gone;
- every recorded waiter/timer PID is gone;
- no matching `tmux wait-for radar-run-*` process remains.

- [ ] **Step 2: Add childless-idle assertions**

Sample the watcher process tree during ARMED and retry backoff. Assert it contains no `tmux wait-for`, timer shell, or external `sleep`, and that process creation stays within the existing budget.

- [ ] **Step 3: Run RED**

Run:

```bash
bash tests/test_ai_supervision.sh
bash tests/test_idle_process_budget.sh
bash tests/test_native_owner.sh
```

Expected: the current watcher exposes background waiter/timer children and the new assertions fail.

## Task 10: Implement Childless Waiting And Terminal Proof

**Files:**
- Modify: `scripts/ai.sh`
- Test: process/lifecycle suites

- [ ] **Step 1: Replace waiter/timer children**

Implement one in-process deadline primitive using Bash `SECONDS`, builtin `read -t`, durable inbox checks, pause checks, and lifecycle checks. Use it for ARMED, retry, verification, and completion hold.

- [ ] **Step 2: Make stop evidence process-complete**

Make finalization idempotent. Stop acknowledgements wait for watcher termination and verify all run-recorded backend PIDs are gone. Forced stop terminates recorded process trees before writing final evidence.

- [ ] **Step 3: Remove obsolete waiter state**

Keep schema-v1 reader compatibility for historical `waiter_pid` and `timer_pid`, but new state snapshots write zero and no new `.waiter.*`/`.timer.*` files.

- [ ] **Step 4: Run GREEN**

Run:

```bash
bash tests/test_ai_supervision.sh
bash tests/test_idle_process_budget.sh
bash tests/test_native_owner.sh
bash tests/test_supervisor_process_safety.sh
bash -n scripts/ai.sh
```

Expected: all pass and process audits report zero residual owned processes.

- [ ] **Step 5: Commit**

Commit the lifecycle fix separately with the live Kimi incident evidence in Lore trailers.

## Task 11: Add The Adapter Template And Ecosystem Guides

**Files:**
- Create: `examples/hooks/custom-agent-adapter.sh`
- Create: `docs/guides/configuration.md`
- Create: `docs/guides/agent-hooks.md`
- Create: `docs/guides/development.md`
- Modify: `README.md`
- Modify: `docs/design-precise-ai-tracking.md`
- Test: `tests/test_safety.sh`

- [ ] **Step 1: Add an executable generic adapter fixture**

The template validates required environment/arguments, builds one JSON envelope with jq, and invokes `agent-event`. Add a test that sends a fake approval and observes the same state as a native adapter.

- [ ] **Step 2: Document configuration**

Cover every tmux option, default, source precedence, cost/privacy impact, recommended default/cautious/always-allow profiles, and troubleshooting.

- [ ] **Step 3: Document hooks**

Cover Kimi install/reload/status/uninstall, event semantics, the normalized schema, adapter walkthrough, isolated testing, failure behavior, and how to add another first-class installer.

- [ ] **Step 4: Document development and optimization**

Cover architecture, state/run files, test suites, model-call serialization, lifecycle invariants, performance budgets, no-fork-loop rule, debugging, release, and contribution boundaries.

- [ ] **Step 5: Update README and design docs**

Add Kimi to the support matrix, explain semantic fallback and the 20-line default, link focused guides, and keep the top-level story concise.

- [ ] **Step 6: Verify and commit**

Run:

```bash
bash tests/test_safety.sh
bash -n examples/hooks/custom-agent-adapter.sh
```

Commit docs/template with Lore trailers.

## Task 12: Full Verification, Live Installation, And v0.1.2 Release

**Files:**
- Modify only files required by failing verification.

- [ ] **Step 1: Run static and unit checks**

Run:

```bash
go test ./...
go vet ./...
go build ./cmd/tmux-radar
find scripts examples -type f -name '*.sh' -exec bash -n {} \;
```

Run shellcheck over changed shell files when installed.

- [ ] **Step 2: Run every shell suite**

Run every executable `tests/test_*.sh` serially and retain the full pass/fail summary.

- [ ] **Step 3: Audit processes and load**

After tests, inspect process tables for orphan run IDs, `tmux-radar`, `ai-monitor`, `tmux wait-for radar-run-*`, fallback adapters, and model backends. Verify idle watchers have bounded CPU and no child churn.

- [ ] **Step 4: Merge the feature branch into local main**

Review the complete diff, ensure no unrelated files changed, merge with a non-destructive fast-forward or explicit merge commit, and preserve all Lore commits.

- [ ] **Step 5: Synchronize source and installed copies**

Fast-forward `/Users/cdcd/roobli/RTFS_justTaste/tmux-radar` and `/Users/cdcd/.tmux/plugins/tmux-radar` to the verified commit. Build the installed native binary and reload tmux configuration.

- [ ] **Step 6: Install and verify live Kimi hooks**

Run the installed hook installer, verify the active Kimi config
(`$KIMI_CODE_HOME/config.toml` or `~/.kimi-code/config.toml`) preserves user
content and reports seven of seven Kimi hooks, inject isolated Kimi fixture
events, and run a real tmux no-hook fallback smoke test. Existing Kimi sessions
may require `/reload` or restart before emitting newly installed hooks; report
this explicitly.

- [ ] **Step 7: Publish v0.1.2**

Push main, create annotated tag `v0.1.2` with release intent and verification evidence, push the tag, and verify local source, installed copy, origin main, and tag all identify the same commit.

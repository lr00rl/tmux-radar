# tmux-radar Kimi Hooks And Semantic Fallback Design

Date: 2026-07-18
Status: Approved
Scope: Kimi Code lifecycle hooks, a public normalized agent-event adapter, semantic no-hook fallback, watcher shutdown safety, documentation, and the v0.1.2 release
Preserves: serialized one-model-call supervision, run journals, policy gates, guarded delivery, verification, config provenance, and the native Go TUI

## Decision Summary

tmux-radar will treat Kimi Code as a first-class hooked agent and will expose the same normalized event entry point for third-party agents. Native lifecycle events remain the preferred trigger. Agents without hooks use a temporal semantic fallback that captures only the bottom 20 pane lines by default, removes lines that are changing between samples without inspecting their text, and asks the model at most once for each materially new stable projection.

The watcher will no longer create background `tmux wait-for` or timer children while armed, retrying, or verifying. Durable inbox files remain authoritative. The watcher blocks inside its own Bash process with bounded one-second reads, checks the inbox and lifecycle on every wake, and uses `SECONDS` deadlines. This trades sub-second wake latency for an explicit upper bound of one second while removing the process class that survived the Kimi run shutdown.

The implementation remains Bash 3.2 compatible and adds no dependency. The Go TUI and shell engine continue to share the existing schema-v1 config. One additive field, `fallback_capture_lines`, is introduced with a default of 20 and provenance like every other setting.

## Incident Evidence

The Kimi run `20260718-103014-145-89820-29745` demonstrated both defects:

- The target pane `%145` remained alive and displayed a Kimi approval prompt.
- `hooks_first=off`, the inbox was empty, and the model call count stayed at zero.
- Every ten-second sample produced `idle_reset` because Kimi changed an elapsed-time row and rotated a footer tip.
- The requested stop created `final.json` with `forced stop after watcher acknowledgement timeout`.
- The original watcher PID `90043` exited, but its waiter subshell PID `40583` and `tmux wait-for` PID `40585` were reparented to PID 1 and remained alive.
- Existing cleanup coverage exercised model-call termination, but did not exercise a stop racing an armed idle waiter.

This release must prove the original failure shape, not merely add another normal-exit test.

## Product Behavior

### Native Kimi Events

Kimi Code 0.26.0 reads repeated `[[hooks]]` tables from `~/.kimi-code/config.toml`. Each radar-owned table contains only the supported keys `event`, `command`, and `timeout`. Hook JSON arrives on stdin and contains at least `hook_event_name`, `session_id`, and `cwd`.

tmux-radar maps Kimi events as follows:

| Kimi event | Normalized event | Registry state | Mark and supervisor behavior |
| --- | --- | --- | --- |
| `SessionStart` | `session_start` | working | register session; remove stale action marks |
| `PermissionRequest` | `approval` | waiting | show permission notification; enqueue approval |
| `PermissionResult` | `approval_resolved` | working | clear the matching action mark; enqueue takeover/resume |
| `UserPromptSubmit` | `user_resumed` | working | clear the matching action mark; supersede pending delivery |
| `Stop` | `turn_complete` | done | show completion notification; enqueue turn completion |
| `Interrupt` | `interrupt` | working | clear pending action state and cancel stale automatic delivery |
| `SessionEnd` | `session_end` | removed | remove registry row and action marks; retain completion history until normal TTL |

`PermissionRequest` and `Stop` always remain user-visible notifications. A completed turn is not mislabeled as an approval request.

### Public Normalized Event Interface

Third-party adapters invoke:

```text
needinput-notify.sh agent-event <agent-kind> <normalized-event>
```

The command reads exactly one JSON object from stdin:

```json
{
  "session_id": "stable vendor session identifier",
  "cwd": "/absolute/project/path",
  "pane": "%42",
  "pid": 1234,
  "process": "vendor-agent",
  "label": "optional user-facing detail"
}
```

Allowed normalized events are:

```text
session_start
approval
approval_resolved
input_required
user_resumed
turn_complete
interrupt
session_end
```

Unknown events, malformed JSON, invalid pane IDs, invalid PIDs, and missing stable identity fail visibly with exit status 2 and do not mutate state. `pane` and `pid` are optional when the adapter is invoked inside the agent process: tmux-radar first uses the supplied pane, then `TMUX_PANE`, then process ancestry. `session_id` is required for the public generic interface. The Kimi adapter uses Kimi's documented `session_id`.

Adapters never write registry, mark, inbox, or run files directly. The shared command owns locking, identity, notification labels, watcher events, and cleanup.

### Kimi Installer Ownership

`scripts/install-hooks.sh` manages one marker-delimited block in Kimi's TOML:

```toml
# >>> tmux-radar kimi hooks >>>
[[hooks]]
event = "PermissionRequest"
command = "'/absolute/path/needinput-notify.sh' kimi-hook"
timeout = 5
# ...six more tables...
# <<< tmux-radar kimi hooks <<<
```

The command is encoded as a valid TOML basic string and shell-quotes the notifier path. Install behavior is:

- skip Kimi when neither the executable nor `~/.kimi-code` is present;
- create `config.toml` when Kimi is present and the file is absent;
- preserve all bytes outside the managed block, including comments and user hooks;
- replace exactly one prior radar block on reinstall;
- reject multiple radar blocks or malformed marker ordering instead of guessing;
- preserve a symlink and write through to its target;
- back up a changed existing file;
- include Kimi in the all-agent transaction and rollback;
- remove only the exact managed block on uninstall;
- report all seven events and partial installation in `status`.

Kimi hooks fail open by Kimi's runtime contract. tmux-radar writes no stdout from successful hook handling and returns quickly.

## No-Hook Semantic Fallback

### Trigger Algorithm

The fallback uses two separate capture budgets:

- `capture_lines` remains the normal model evidence budget for native events, default 120.
- `fallback_capture_lines` is the idle-fallback sample and model evidence budget, default 20.

At each idle deadline:

1. Capture the bottom `fallback_capture_lines` lines.
2. Normalize carriage returns and trailing whitespace only. Do not match agent words, prompt strings, elapsed-time formats, menu options, colors, or language.
3. Compare the previous and current samples using an order-preserving stable projection. Lines present unchanged in both samples form the projection; changing elapsed/footer rows disappear naturally.
4. Require `stable_screen_threshold` consecutive occurrences of the same non-empty projection.
5. Hash the projection. If it equals the last projection already assessed, return to ARMED without a model call.
6. Otherwise enqueue one `screen_idle` event and send only the current bottom fallback capture to the model.
7. Record the projection hash, source samples, stable-line count, and dedupe result in the timeline. Persist raw samples only when full logging or screen snapshots are enabled.

After a model decision, delivery, verification, native event, user takeover, or meaningful projection change, the fallback establishes a new baseline. The configured `poll` interval starts after the preceding operation reaches its terminal phase, never while a model call or verification is still running.

The fallback may occasionally ask the model about a stable non-prompt screen. The model can return `wait`; projection deduplication then prevents repeated spending on the same state. This is preferred to brittle prompt regexes and to unconditional periodic model calls.

### Decision Prompt

The model receives the normalized event source and agent context. For Kimi numbered approvals, it may select the visible numeric option and Enter, but no fixed option number is assumed. The model must infer the exact visible choice from the capture and obey the existing policy and autonomy gates.

## Childless Waiting And Shutdown

The watcher event loop owns no background waiter or timer process:

```text
deadline = SECONDS + requested_delay
while SECONDS < deadline:
    drain durable inbox
    check pause, target pane, owner lease, and stop state
    block in Bash builtin read -t <= 1 second
```

The same primitive is used by ARMED polling, retry backoff, verification, and completion hold. Model execution remains the only expected long-lived child process and continues to run in an owned process group with bounded timeout.

Terminal invariants:

- `q`, `Ctrl-C`, `TERM`, `INT`, `HUP`, target loss, owner loss, and session termination converge on one idempotent finalizer.
- The finalizer cancels delivery, terminates the model process group, removes the live pointer only when it still owns that generation, writes one terminal `final.json`, and removes transient files.
- A stop acknowledgement is successful only after the watcher is gone and no process recorded by the run remains alive.
- A forced stop must scan and terminate all run-owned recorded PIDs before writing terminal evidence.
- No code path may report terminal success while an owned waiter, timer, watcher, or backend remains.
- Repeated stop requests return the persisted acknowledgement and do not create a new process.

## Configuration Surface

Add:

| tmux option | Default | Meaning |
| --- | --- | --- |
| `@radar-ai-fallback-capture-lines` | `20` | Bottom pane lines used for no-hook stability analysis and a `screen_idle` model call |

Valid range is 8-200. The advanced TUI shows it in Context with effective value and provenance. `capture_lines` continues to control native-event decisions. Existing configs decode with the default value.

`hooks_first=on` remains the default and means native events are acted on immediately when available. `off` is an explicit troubleshooting mode that journals native approval/input/completion events but waits for semantic fallback. Documentation must make its cost and latency consequences explicit.

## Documentation And Ecosystem

Create:

- `docs/guides/configuration.md`: every option, default, provenance, tradeoff, and common profile.
- `docs/guides/agent-hooks.md`: normalized protocol, Kimi configuration, custom adapter tutorial, testing, status, reload, and uninstall.
- `docs/guides/development.md`: architecture, state model, adding an agent, TDD commands, performance budgets, lifecycle rules, and release workflow.
- `examples/hooks/custom-agent-adapter.sh`: executable, dependency-light adapter template using stdin JSON and `agent-event`.

Update README with positioning, support matrix, quick-start paths, Kimi installation, fallback behavior, configuration links, and diagnostics. Update `docs/design-precise-ai-tracking.md` with Kimi and the public normalized event layer.

## Test And Performance Gates

Required automated evidence:

- Kimi install, idempotency, preservation, symlink behavior, status, partial status, uninstall, malformed markers, and transaction rollback.
- All seven Kimi lifecycle events, exact session-key identity, two concurrent sessions, duplicate events, missing pane resolution, malformed payload rejection, and selective SessionEnd cleanup.
- Generic adapter happy path and malformed/unknown input.
- A dynamic Kimi-like screen whose elapsed/footer lines change while a stable approval body remains; one model call must occur.
- An unchanged projection must not spend a second call.
- Continuously changing output must not call the model.
- Native events still use `capture_lines`; fallback uses only `fallback_capture_lines`.
- ARMED stop, retry stop, verification stop, target loss, owner loss, and repeated stop leave zero run-owned processes.
- Idle watcher sampling shows no `tmux wait-for` or timer child and no external-process fork loop.

Required release evidence:

- all Go tests;
- all shell suites;
- `go vet ./...`;
- `bash -n` for every shell script and example;
- shellcheck when installed;
- native binary build;
- real tmux Kimi hook event injection and no-hook fallback smoke tests;
- post-test process-table audit for orphan `tmux-radar`, `ai-monitor`, `tmux wait-for`, and backend processes;
- installed copy synchronized to the source commit;
- Kimi config status reports seven of seven hooks;
- main pushed and annotated tag `v0.1.2` pushed.

## Rejected Alternatives

- Unconditional model calls every poll: robust but spends continuously during long tasks.
- Agent-specific prompt regexes: cheap but version-, locale-, theme-, and width-sensitive.
- A persistent daemon: unnecessary operational surface for local hook delivery.
- Keeping background `tmux wait-for` and adding more kill calls: does not eliminate the orphan race demonstrated by the live run.
- Moving the watcher into Go in this patch: too broad for a lifecycle integration release and reopens already-tested delivery semantics.


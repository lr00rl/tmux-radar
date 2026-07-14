# tmux-radar Supervision Console Design

Date: 2026-07-13
Status: Approved visual direction
Scope: `prefix + A -> w`, resident supervision lifecycle, monitor panes, hook integration, event logs, and completion reporting

## Product Intent

tmux-radar is a workspace navigator with an optional AI supervisor. The supervisor must not own the user's workflow or hide automation behind a spinner. Its job is narrower:

1. Accept the user's exact supervision goal.
2. Observe explicit Claude/Codex lifecycle events.
3. Ask a read-only model for a structured decision only when a decision is needed.
4. Apply policy gates before sending exact keys to the target pane.
5. Show what happened, why, and what will happen next.
6. Stop cleanly when the goal completes, the user takes over, or either owned pane disappears.

The primary user is an AI-heavy tmux user supervising many long-running coding agents. Behavioral precision outranks decoration. The visual register is a restrained terminal/data-dense console: neutral surfaces, hairline pane borders, semantic color, keyboard-first interaction, and no decorative motion.

## Success Criteria

- `prefix + A`, then `w`, always opens a quick goal input instead of silently starting a generic watch.
- The goal is preserved byte-for-byte and is visible in the launch summary, watcher state, every decision prompt, the monitor overview, and the final report.
- `Tab` from quick input opens advanced settings. A blank goal resolves to the explicit default `推进当前任务直到完成`.
- Advanced settings show every configurable value before launch. The running monitor distinguishes default, user override, and effective runtime values.
- The target pane remains readable and interactive while a right-side monitor console is open.
- The console shows the current lifecycle phase, event source, model duration, policy gate, exact planned/sent input, verification result, errors, and next trigger.
- Hook events trigger decisions promptly. No screen-text matching is introduced.
- Screen-idle sampling is only a fallback for unsupported/missing hooks.
- A watch has at most one model process tree in flight. Events received during a call are queued and coalesced, never turned into overlapping calls.
- Closing the target pane, closing the visible monitor owner, pressing `q`, or pressing `Ctrl-C` terminates the watcher and its complete model/MCP descendant tree.
- The detail pane does not repaint once per second. Copy-mode scrollback remains stable while the overview countdown/status updates.
- Every run leaves a structured local audit trail and a concise final summary.

## Entry Flow

### Quick path: `w`

`w` opens an 80% by 70% popup with:

- target label
- one readline-backed UTF-8 goal field
- effective quick defaults in one compact line
- `Enter` to start
- `Tab` to open advanced settings
- `Esc` to cancel

Readline remains mandatory because canonical-mode shell input erases UTF-8 by byte. The popup installs a process-local readline Tab macro that accepts the current line with an internal suffix; the suffix is removed before the goal is stored. This preserves character-wise editing and allows Tab to branch without adding a dependency.

After goal entry, the popup shows a launch summary. `Enter` starts, `a` opens advanced settings, and `Esc` cancels. This second gate is a fallback if a terminal/readline implementation does not deliver the Tab macro reliably.

### Advanced path

Advanced settings expose these per-watch fields:

| Group | Fields |
| --- | --- |
| Intent | goal |
| Authority | autonomy, approval policy, always-allow preference |
| Triggering | hooks-first mode, idle fallback interval, stable-screen threshold |
| Brain | command/profile/model, reasoning effort, timeout |
| Budget | maximum decisions, retry limit, retry backoff |
| Context | model capture lines, monitor excerpt lines |
| Console | monitor position, width, overview ratio, completion close delay |
| Logging | level, screen snapshot persistence, retention days |

The final pre-launch summary lists all effective values. Each row carries provenance:

- `default`: plugin default
- `tmux`: inherited tmux option
- `custom`: changed in this popup
- `runtime`: adjusted because of terminal dimensions or missing hook capability

`v` becomes an alias that opens the same flow directly in advanced mode. `W` keeps the quick goal flow but presets always-allow. There are no separate implementations for `w`, `W`, and `v`.

## Monitor Layout

### Wide terminals

For target panes at least 180 columns wide, create a right monitor region:

1. Split the target horizontally, detached, using approximately 38% width.
2. Clamp monitor width to 72-112 columns so the target remains usable.
3. Split the monitor vertically: top 25% overview, bottom 75% detail.
4. Restore focus to the target pane after creation.

The default changes from `top` to `right`. Existing explicit `@radar-ai-monitor-pos` values continue to work during migration.

### Narrow terminals

- 120-179 columns: use a right single-pane console with a compact six-line overview embedded above detail.
- Below 120 columns or below 24 rows: use a large popup console and keep the target pane unsplit.
- If no visible monitor can be created, abort the watch. Hidden supervision is not an acceptable degraded state.

### Overview: top 25%

The overview is fixed and never enters scrollback. It shows:

- semantic state: `ARMED`, `EVENT`, `CAPTURING`, `DECIDING`, `GATING`, `EXECUTING`, `VERIFYING`, `PAUSED`, `DONE`, or `ERROR`
- current event number, source, and elapsed duration
- exact goal
- policy and autonomy
- effective model/profile and effort
- decision count and maximum
- timeout and retry state
- trigger mode and idle fallback
- logging level and retention
- the next condition, expressed honestly (`after model`, `waiting for target change`, `idle check in 12s`) rather than a permanent `next=0s`
- controls: `p` pause/resume, `r` reassess, `c` config, `Enter` jump to target, `q` stop

Only changed rows are repainted with cursor addressing. The screen is cleared once on startup or resize, not every tick.

### Detail: bottom 75%

The detail pane has five keyboard views:

1. `Timeline`: append-only lifecycle events with timestamps and durations.
2. `Decision`: current/last model request, parsed output, evidence, risk, policy result, exact text/keys, and verification.
3. `Screen`: the excerpt visible to the monitor and the capture size sent to the model.
4. `Config`: every configuration key with default, override, effective value, and provenance.
5. `Logs`: run directory, file sizes, retention, recent backend stderr, and errors.

Timeline is the default. A decision event automatically selects Decision unless the user has manually pinned another tab. Switching tabs clears and replays only the detail pane. Timeline and log updates append; the one-second overview refresh never writes into detail scrollback.

The UI exposes observable model inputs and structured outputs. It does not claim to expose private chain-of-thought. The label is `Decision evidence`, not `Model reasoning` or `Model conversation`.

## Lifecycle State Machine

```text
CREATED
  -> ARMED
  -> EVENT_PENDING
  -> CAPTURING
  -> DECIDING
  -> POLICY_GATE
  -> EXECUTING
  -> VERIFYING
  -> ARMED

Any active state -> PAUSED_USER | RETRY_BACKOFF | COMPLETED | STOPPED
RETRY_BACKOFF -> DECIDING | PAUSED_ERROR
```

### Trigger rules

- `approval`: decide immediately.
- `turn_complete`: decide immediately whether the goal is complete or a follow-up instruction is required.
- `user_resumed`: clear stale marks, reset the stable-screen latch, and return to ARMED without a model call.
- `screen_idle`: decide only when no actionable hook arrived and the screen fingerprint has remained stable for the configured fallback interval.
- `manual_reassess`: decide once when the user presses `r`.

No event ID is evaluated twice unless the user explicitly retries it. A changing spinner cannot generate new decision IDs.

### One-call invariant

The watcher owns the model process directly. While DECIDING:

- no second `_brain` call can start
- incoming hook events are appended to the inbox and reflected as `queued=N`
- on completion, the watcher drains and coalesces the inbox
- user-resumed supersedes stale approval events
- the newest actionable approval/turn-complete event is then evaluated

The idle timer starts only after execution verification or a completed `wait` result. It never runs concurrently as a reason to open another model session.

### Execution verification

After sending keys, the watcher records the pre-action screen fingerprint and waits for one of:

- `UserPromptSubmit` / resume hook
- target screen fingerprint change
- target process termination
- verification timeout

Only then does the watcher return to ARMED and start the idle fallback timer. A verification timeout becomes a visible warning and does not silently resend the same action.

### Completion

`done` is accepted only from a decision tied to `turn_complete`, `screen_idle`, or manual reassessment; an approval event cannot directly complete the goal. Completion produces:

- tmux-radar DONE mark and notification
- final summary in the monitor
- duration, event/decision/action/error counts
- final reason and goal assessment
- run log location

The monitor remains for a configurable 12 seconds. `k` keeps it open; `q` closes immediately. If untouched, both monitor panes close and the target regains the released width.

## Hook Integration

Claude and Codex hooks continue to maintain global AI-status marks, but also emit minimal watcher events when the resolved pane has an active watch.

| Source event | Watch event |
| --- | --- |
| Claude `Notification` | `approval` or `input_required` |
| Claude `Stop` | `turn_complete` |
| Claude `UserPromptSubmit` | `user_resumed` |
| Codex `PermissionRequest` | `approval` |
| Codex `Stop` | `turn_complete` |
| Codex `UserPromptSubmit` | `user_resumed` |
| Legacy Codex notify `agent-turn-complete` | `turn_complete` fallback |

Hook handlers append sanitized event metadata and signal the watcher. They do not call the model and must always exit zero after recording their own errors.

The supervisor's internal `codex exec` runs with `TMUX_RADAR_INTERNAL=1`. Every tmux-radar hook exits immediately when that variable is present. This prevents the supervisor model from marking or waking the target watch and closes a self-triggering loop.

The UI reports hook capability as `native`, `legacy`, or `fallback`. Missing hooks do not masquerade as native event coverage.

## Decision Contract

The existing required schema remains backward compatible:

- `action`
- `text`
- `keys`
- `safe`
- `reason`

Optional fields improve the console without breaking custom backends:

- `pane_state`: `working`, `blocked`, `idle`, `done`, `unknown`
- `goal_status`: `working`, `blocked`, `done`, `unclear`
- `risk`: `low`, `medium`, `high`, `unknown`
- `evidence`: short string array

Policy is enforced by the script, never by presentation. Unsafe, destructive, irreversible, remote-write, production, or ambiguous decisions escalate regardless of always-allow.

## Persistence and Logs

`$STATE_DIR/ai-watch/<pane>.watch` remains the live compatibility pointer. Each launch creates:

```text
$STATE_DIR/ai-runs/<run-id>/
  config.json             immutable launch snapshot + provenance
  state.json              atomic latest state
  events.jsonl            canonical append-only event journal
  inbox/                  atomically published hook-event spool
  decisions/0001.json     raw structured model output
  decisions/0001.meta.json
  screens/0001.txt        only when screen logging is enabled
  backend/0001.stderr
  final.json              completion/stop summary
```

Each inbox event is written to a private temporary file and atomically renamed to a ready file. Drainers atomically claim ready files into private batches; events published during a drain remain for the next batch. This avoids shared-lock reclamation races, partial JSON reads, and truncation races while preserving exact-once ownership.

The global `ai.log` remains a compact cross-run index. Monitor UI is derived from structured state and journals, not a second independent truth.

Files are created with user-only permissions. Default logging is `decision`: events, configuration, parsed decisions, metadata, and stderr, without persistent screen captures. `full` adds screen excerpts and exact prompts; the advanced settings UI warns that these may contain source code, commands, paths, or secrets. Default retention is seven days, configurable per watch. Cleanup never removes an active run.

## Error and Recovery Behavior

- Empty/invalid model JSON: show raw output/stderr, retry with backoff, never send keys.
- Model timeout: terminate the complete process group; retry after 15s, 30s, then 60s; pause after the configured retry limit.
- Hook write failure: preserve global mark, record hook error when possible, and let idle fallback operate.
- Monitor creation failure: terminate the just-launched watcher and model tree.
- Target pane gone: stop immediately and close monitor panes.
- Monitor owner gone: stop immediately and terminate the model tree.
- Duplicate launch: focus the existing monitor and show its run ID; do not start another watcher.
- Stale event: show it as superseded; never apply its keys to a changed fingerprint.
- Policy escalation: pause with exact risk/evidence and `Enter` jump-to-target guidance.

## Notifications

Notifications are reserved for transitions that require attention:

- user decision required
- watcher paused after retry exhaustion or budget exhaustion
- goal completed
- watcher stopped because its target/monitor disappeared unexpectedly

Routine model calls and safe sends update the console and logs without OS-level noise. AI-status rows continue to distinguish `ACTION`, `DONE`, and `ACTIVE`.

## Compatibility and Migration

- Existing `TMUX_SWITCHER_*` environment aliases remain accepted.
- Existing explicit top/bottom/single monitor options remain available for one release.
- The new right console is the default for wide terminals.
- `v` maps to advanced launch; `W` maps to quick goal plus always-allow preset.
- Flat `.timeline`, `.detail`, and `.detail.log` files are read only for existing live watches, then removed by cleanup after those watches end.
- No new runtime dependency is introduced. Bash 3.2, tmux, jq, and the selected AI command remain sufficient.

## Verification Plan

### Unit and shell integration

- CJK quick-goal editing and one-backspace deletion
- Tab-to-advanced sentinel preserves the complete goal
- blank goal receives the explicit default
- every advanced field records default/override/effective provenance
- exact goal reaches config, prompt, monitor state, events, and final report
- hook event mapping for Claude/Codex native and legacy events
- internal supervisor hooks are ignored
- one-call invariant under multiple simultaneous events
- user-resumed supersedes queued approval
- idle timer begins after verification, not model start
- spinner/screen changes do not duplicate an event call
- invalid JSON and three timeout backoffs pause without sending keys
- target or monitor death terminates watcher and descendant model processes
- screen logs obey level and retention settings

### Isolated tmux end-to-end

- 284x54: right rail, clamped width, 25/75 split, target focus restored
- 150x40: compact right console
- 100x30: popup fallback
- overview updates without clearing detail scrollback
- copy-mode remains on the selected historical line while overview counts down
- tab switching replays the correct structured view
- `p`, `r`, `Enter`, `q`, and `Ctrl-C` behave as documented
- completion summary persists for the configured delay and then releases layout

### Manual acceptance journey

1. Start Codex or Claude in a target pane.
2. Invoke `prefix + A`, `w`.
3. Enter a Chinese goal, open advanced settings, change policy, timeout, and logging.
4. Confirm all settings and provenance in launch summary and Config view.
5. Trigger a safe approval and observe event-to-verification progression.
6. Trigger an unsafe remote/deploy action and verify escalation without key send.
7. Finish the target goal and verify DONE notification, final report, logs, and monitor auto-close.

## Explicit Non-Goals

- No screen-text pattern matching for Claude/Codex prompts.
- No attempt to expose hidden chain-of-thought.
- No autonomous task creation, pane creation, workflow ownership, or agent orchestration.
- No web UI or daemon dependency.
- No decorative animation or whole-pane repaint loop.

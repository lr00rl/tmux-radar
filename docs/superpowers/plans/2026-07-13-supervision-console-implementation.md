# tmux-radar Supervision Console Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the opaque polling watcher with a goal-first, hook-driven, single-call supervisor and a right-side 25/75 tmux control console with structured run logs.

**Architecture:** Keep `scripts/ai.sh` as the public command surface and process owner, extract structured run persistence into `scripts/lib/ai-runtime.sh`, and move monitor rendering/keyboard handling into `scripts/ai-monitor.sh`. Claude/Codex hooks append minimal events to each active run's inbox and signal the watcher; the watcher serializes model calls through an explicit state machine and writes one canonical JSONL journal consumed by the monitor.

**Tech Stack:** Bash 3.2, tmux 3.2+, jq, POSIX/macOS utilities, existing Codex/custom decision backend

---

## File Map

- Create `scripts/lib/ai-runtime.sh`: run IDs, config provenance, atomic state, event/inbox journals, final reports, retention cleanup.
- Create `scripts/ai-monitor.sh`: overview renderer, five detail views, keyboard loop, responsive pane content, completion hold.
- Modify `scripts/ai.sh`: source runtime library, quick/advanced setup, event-driven state machine, serialized brain calls, execution verification, right-rail launcher, CLI compatibility.
- Modify `scripts/needinput-notify.sh`: internal-supervisor suppression and watcher event emission from Claude/Codex hooks.
- Modify `scripts/install-hooks.sh`: capability/status reporting and idempotent native event coverage.
- Modify `scripts/prompts/decide.md`: event-aware goal evaluation and concise evidence requirements.
- Modify `scripts/prompts/decide.schema.json`: optional pane/goal/risk/evidence fields.
- Create `tests/test_helpers.sh`: assertions, waits, fake tmux/config helpers used by new tests.
- Create `tests/test_ai_runtime.sh`: structured state, journals, permissions, retention, provenance.
- Create `tests/test_ai_events.sh`: hook mapping, event signaling, internal suppression, coalescing.
- Create `tests/test_ai_supervision.sh`: one-call invariant, event latching, verification, retry/backoff, goal propagation.
- Create `tests/test_ai_console.sh`: quick/advanced parsing, responsive split commands, overview/detail rendering, no full-pane refresh.
- Modify `tests/test_ai_lifecycle.sh`: preserve process-tree ownership assertions with the new run-directory paths.
- Modify `README.md`: new `w` flow, controls, event semantics, options, logs, migration, troubleshooting.

### Task 1: Structured Run Runtime

**Files:**
- Create: `scripts/lib/ai-runtime.sh`
- Create: `tests/test_helpers.sh`
- Create: `tests/test_ai_runtime.sh`

- [ ] **Step 1: Add a failing runtime test**

Create a temporary state directory, source the runtime library, create a run for `%39`, update it, append an event, finalize it, and assert exact file layout and mode:

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/test_helpers.sh"

TMP="$(test_tmpdir runtime)"
trap 'rm -rf "$TMP"' EXIT
export TMUX_RADAR_STATE_DIR="$TMP/state"
source "$ROOT/scripts/lib/ai-runtime.sh"

config='{"goal":"监控到测试全绿","values":{"timeout":{"value":"60","source":"custom"}}}'
radar_run_create %39 "$config"
assert_file "$RADAR_RUN_DIR/config.json"
assert_json "$RADAR_RUN_DIR/config.json" '.goal == "监控到测试全绿"'
assert_eq "600" "$(stat -f '%Lp' "$RADAR_RUN_DIR/config.json")"

radar_state_set ARMED "waiting for hook" none 0
assert_json "$RADAR_RUN_DIR/state.json" '.phase == "ARMED" and .status == "waiting for hook"'

radar_event_append approval codex "Codex needs approval" '{}'
assert_json "$RADAR_RUN_DIR/events.jsonl" 'select(.kind == "approval" and .source == "codex")'

radar_run_finalize completed "goal reached"
assert_json "$RADAR_RUN_DIR/final.json" '.outcome == "completed" and .reason == "goal reached"'
printf 'PASS: structured run runtime\n'
```

`tests/test_helpers.sh` must provide `test_tmpdir`, `assert_eq`, `assert_file`, `assert_json`, `wait_for_file`, and `wait_for_exit`, with failures printing expected and actual values.

- [ ] **Step 2: Run the test and confirm the missing-library failure**

Run: `bash tests/test_ai_runtime.sh`

Expected: non-zero with `scripts/lib/ai-runtime.sh: No such file or directory`.

- [ ] **Step 3: Implement the runtime library**

Implement these public functions and globals:

```bash
RADAR_STATE_DIR="${TMUX_RADAR_STATE_DIR:-${TMUX_SWITCHER_STATE_DIR:-$HOME/.local/state/tmux}}"
RADAR_WATCH_DIR="$RADAR_STATE_DIR/ai-watch"
RADAR_RUNS_DIR="$RADAR_STATE_DIR/ai-runs"

radar_watch_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
radar_watch_file() { printf '%s/%s.watch' "$RADAR_WATCH_DIR" "$(radar_watch_key "$1")"; }
radar_run_create() { :; }
radar_run_open() { :; }
radar_state_set() { :; }
radar_event_append() { :; }
radar_inbox_append() { :; }
radar_inbox_drain() { :; }
radar_run_finalize() { :; }
radar_cleanup_runs() { :; }
```

Use `jq -cn` for JSON construction, `mktemp` plus `mv` for atomic snapshots, append-only JSONL for journals, and `umask 077`. A live `.watch` pointer remains key/value text for compatibility and includes `run_id`, `run_dir`, `pid`, `pane`, and monitor pane IDs.

- [ ] **Step 4: Verify runtime behavior**

Run: `bash tests/test_ai_runtime.sh`

Expected: `PASS: structured run runtime`.

- [ ] **Step 5: Commit the runtime slice**

```bash
git add scripts/lib/ai-runtime.sh tests/test_helpers.sh tests/test_ai_runtime.sh
git commit -m "Make every supervision run independently auditable" \
  -m "Constraint: Bash 3.2 and jq are the only structured-state runtime tools" \
  -m "Confidence: high" -m "Scope-risk: moderate" \
  -m "Tested: bash tests/test_ai_runtime.sh"
```

### Task 2: Hook Event Inbox and Internal Suppression

**Files:**
- Modify: `scripts/needinput-notify.sh`
- Modify: `scripts/install-hooks.sh`
- Create: `tests/test_ai_events.sh`
- Test: `tests/test_ai_runtime.sh`

- [ ] **Step 1: Write failing hook-event tests**

Cover four contracts:

```bash
# Active watch: PermissionRequest appends approval and signals its channel.
printf '%s' '{"hook_event_name":"PermissionRequest","tool_name":"exec_command"}' |
  TMUX_PANE=%39 bash "$ROOT/scripts/needinput-notify.sh" codex-hook
assert_json "$RUN_DIR/inbox.jsonl" 'select(.kind == "approval" and .source == "codex")'
assert_contains "$TMP/tmux.calls" 'wait-for -S radar-run-39'

# Stop maps to turn_complete, never to input_required.
printf '%s' '{"hook_event_name":"Stop"}' |
  TMUX_PANE=%39 bash "$ROOT/scripts/needinput-notify.sh" codex-hook
assert_json "$RUN_DIR/inbox.jsonl" 'select(.kind == "turn_complete")'

# UserPromptSubmit maps to user_resumed and still clears the global mark.
# TMUX_RADAR_INTERNAL=1 produces neither a mark nor an inbox event.
```

Use a fake `tmux` that records `wait-for -S`, `show-option`, title, and mark calls. Seed `<pane>.watch` with `run_dir`, `run_id`, and `channel`.

- [ ] **Step 2: Run and confirm no inbox events are emitted**

Run: `bash tests/test_ai_events.sh`

Expected: FAIL because `needinput-notify.sh` only mutates `need-input`.

- [ ] **Step 3: Add event emission without slowing hooks**

Add an early guard and one helper:

```bash
[ "${TMUX_RADAR_INTERNAL:-0}" = 1 ] && exit 0

_watch_event() { # pane kind source label
  local pane="$1" kind="$2" source="$3" label="$4" wf run_dir run_id channel
  wf="$STATE_DIR/ai-watch/$(printf '%s' "$pane" | tr -c 'A-Za-z0-9' '_').watch"
  [ -r "$wf" ] || return 0
  run_dir="$(_watch_field "$wf" run_dir)"
  run_id="$(_watch_field "$wf" run_id)"
  channel="$(_watch_field "$wf" channel)"
  [ -d "$run_dir" ] || return 0
  "$SCRIPT_DIR/ai.sh" emit-event "$pane" "$kind" "$source" "$label" >/dev/null 2>&1 || true
  [ -n "$channel" ] && tmux wait-for -S "$channel" >/dev/null 2>&1 || true
}
```

Call it from Claude/Codex hook handlers after target resolution. Preserve existing ACTION/DONE marks. Never pass raw hook JSON into persistent logs; store event type, source, sanitized label, pane, and timestamp.

- [ ] **Step 4: Report native capability accurately**

Update `install-hooks.sh status` to report each required native event and legacy fallback separately. Keep installation idempotent and retain existing notify chains.

- [ ] **Step 5: Run event and baseline lifecycle tests**

Run:

```bash
bash tests/test_ai_events.sh
bash tests/test_ai_lifecycle.sh
```

Expected: all PASS and no hook command returns non-zero.

- [ ] **Step 6: Commit the event slice**

```bash
git add scripts/needinput-notify.sh scripts/install-hooks.sh tests/test_ai_events.sh
git commit -m "Wake supervisors from native agent lifecycle events" \
  -m "Constraint: Hooks must remain fast, sanitized, and zero-exit" \
  -m "Rejected: Screen-text prompt detection | native hooks are authoritative" \
  -m "Confidence: high" -m "Scope-risk: moderate" \
  -m "Tested: hook event mapping and lifecycle regression suites"
```

### Task 3: Serialized Event-Driven Watcher

**Files:**
- Modify: `scripts/ai.sh`
- Create: `tests/test_ai_supervision.sh`
- Modify: `tests/test_ai_lifecycle.sh`

- [ ] **Step 1: Write failing state-machine tests**

Use a fake decision backend that records PID/start/end and returns scripted JSON. Assert:

```bash
# Three approval events arriving during a blocked first call yield max_active=1.
assert_eq 1 "$(cat "$TMP/max-active")"

# The same event ID is decided once even if the screen fingerprint changes.
assert_eq 1 "$(wc -l < "$TMP/model.calls" | tr -d ' ')"

# user_resumed supersedes queued approval events.
assert_json "$RUN_DIR/events.jsonl" 'select(.kind == "superseded" and .supersedes_kind == "approval")'

# After send, state is VERIFYING until screen change or user_resumed.
assert_json "$RUN_DIR/state.json" '.phase == "VERIFYING"'

# Timeout retries are 15/30/60 in production and test-overridable; exhaustion pauses.
assert_json "$RUN_DIR/state.json" '.phase == "PAUSED_ERROR" and .retry == 3'
```

Set test-only environment seams for wait duration and scripted time; production defaults remain from tmux options.

- [ ] **Step 2: Run and observe polling-based failures**

Run: `bash tests/test_ai_supervision.sh`

Expected: FAIL because the current loop triggers from quiet hashes and has no event IDs, inbox, verification state, or retry exhaustion.

- [ ] **Step 3: Replace the quiet-loop core with explicit phases**

Keep `_brain`, process-group ownership, `_send`, and policy gates, but restructure `_watch_loop` around:

```bash
while radar_watch_alive; do
  if radar_inbox_has_events; then
    event="$(radar_next_event)"
  elif radar_idle_deadline_reached; then
    event="$(radar_make_idle_event)"
  else
    radar_wait_for_signal_or_deadline
    continue
  fi

  radar_coalesce_events "$event"
  radar_capture_for_event
  radar_decide_once
  radar_policy_gate
  radar_execute_or_pause
  radar_verify_effect
done
```

Persist every phase transition through `radar_state_set` and `radar_event_append`. Event ID, not screen hash, is the decision latch. Screen fingerprints only support stale-decision verification and idle fallback.

- [ ] **Step 4: Enforce internal process and one-call invariants**

Launch every backend as:

```bash
TMUX_RADAR_INTERNAL=1 codex exec ...
```

or, for custom commands:

```bash
(export TMUX_RADAR_INTERNAL=1; printf '%s' "$prompt" | eval "$custom" ...)
```

Record `model_started_at`, elapsed seconds, PID, PGID, and timeout in state. Never spawn `_brain` from a monitor process.

- [ ] **Step 5: Add execution verification and backoff**

After `_send`, persist the pre-send fingerprint and wait for `user_resumed`, screen change, pane death, or verification timeout. Start idle fallback only after verification. Invalid/empty JSON and timeouts use bounded backoff; exhausted retries pause and notify without sending keys.

- [ ] **Step 6: Run supervision and lifecycle suites**

Run:

```bash
bash tests/test_ai_supervision.sh
bash tests/test_ai_lifecycle.sh
```

Expected: all assertions pass; process scans show no surviving fake backend children.

- [ ] **Step 7: Commit the watcher slice**

```bash
git add scripts/ai.sh tests/test_ai_supervision.sh tests/test_ai_lifecycle.sh
git commit -m "Prevent supervision decisions from racing their own evidence" \
  -m "Constraint: One watcher owns at most one complete model process tree" \
  -m "Directive: Never reintroduce screen hashes as decision identities" \
  -m "Confidence: high" -m "Scope-risk: broad" \
  -m "Tested: serialized events, verification, retry, and process lifecycle suites"
```

### Task 4: Goal-First Quick and Advanced Launch

**Files:**
- Modify: `scripts/ai.sh`
- Create/Modify: `tests/test_ai_console.sh`

- [ ] **Step 1: Add failing input/config tests**

Test pure parsing and generated config before terminal integration:

```bash
decoded="$(bash scripts/ai.sh _decode-goal $'允许到测试全绿__RADAR_ADVANCED__')"
assert_eq $'advanced\t允许到测试全绿' "$decoded"

config="$(TMUX_RADAR_SETUP_OVERRIDES='timeout=45,logging=full' \
  bash scripts/ai.sh _build-watch-config %39 '允许到测试全绿')"
assert_json_string "$config" '.goal == "允许到测试全绿"'
assert_json_string "$config" '.values.timeout.source == "custom"'
assert_json_string "$config" '.values.poll.source == "default" or .values.poll.source == "tmux"'
```

Also assert the menu maps `w` to quick setup, `W` to quick setup with always-allow preset, and `v` to advanced setup.

- [ ] **Step 2: Run and confirm current `w` bypasses input**

Run: `bash tests/test_ai_console.sh`

Expected: FAIL because the menu invokes `watch` directly.

- [ ] **Step 3: Implement one shared setup flow**

Add:

```bash
cmd_watch_setup() { # pane initial_mode policy_preset
  # readline goal, decode Tab sentinel, build provenance-aware JSON,
  # optionally edit advanced values, show full launch summary, then cmd_watch.
}
```

Use readline for all free text. Install the Tab macro only inside the popup process. Validate numeric values with explicit ranges and preserve the previous effective value on invalid input while showing what was rejected and how to fix it.

- [ ] **Step 4: Show all advanced values and provenance**

The pre-launch summary must render every field from `config.json` in stable group order and label `default`, `tmux`, `custom`, or `runtime`. No advanced field may exist only in shell locals.

- [ ] **Step 5: Verify parser, menu, and CJK behavior**

Run:

```bash
bash tests/test_ai_console.sh
bash tests/test_ai_lifecycle.sh
```

Then use an isolated tmux popup: enter `AB中文`, press one Backspace, and assert the accepted bytes equal `4142e4b8ad` (`AB中`).

- [ ] **Step 6: Commit the launch slice**

```bash
git add scripts/ai.sh tests/test_ai_console.sh
git commit -m "Make the watch goal the first-class supervision input" \
  -m "Constraint: Readline remains required for character-wise CJK editing" \
  -m "Confidence: high" -m "Scope-risk: moderate" \
  -m "Tested: goal parsing, provenance summary, menu routing, and isolated CJK input"
```

### Task 5: Right-Side 25/75 Monitor Console

**Files:**
- Create: `scripts/ai-monitor.sh`
- Modify: `scripts/ai.sh`
- Modify: `tests/test_ai_console.sh`

- [ ] **Step 1: Add failing responsive-layout tests**

Record fake tmux calls and assert:

```bash
# 284x54 target: right region, clamped width, overview above detail.
assert_contains "$TMP/tmux.calls" 'split-window -h'
assert_contains "$TMP/tmux.calls" 'ai-monitor.sh detail'
assert_contains "$TMP/tmux.calls" 'split-window -v -b -p 25'
assert_contains "$TMP/tmux.calls" 'ai-monitor.sh overview'
assert_contains "$TMP/tmux.calls" 'select-pane -t %39'

# 150x40: one compact right console.
# 100x30: popup console, no target split.
```

Render `overview --once` and each detail view from fixture JSON. Reject output containing repeated clear-screen sequences after initial draw.

- [ ] **Step 2: Run and confirm top-split failure**

Run: `bash tests/test_ai_console.sh`

Expected: FAIL because current defaults use a top split and separate append-only timeline/detail viewers.

- [ ] **Step 3: Implement responsive launcher**

For wide targets, create the detail pane first on the right, then split it with a detached overview above at 25%. Clamp computed columns to 72-112. Store `monitor_overview_pane` and `monitor_detail_pane` in the live watch pointer. Restore focus to the target.

For medium width, run `ai-monitor.sh compact`. For narrow targets, use `display-popup -E -w 90% -h 85%` and bind its lifecycle to the watcher.

- [ ] **Step 4: Implement overview renderer**

`ai-monitor.sh overview <pane>` reads `state.json` once per second, computes honest elapsed/next labels, and repaints only fixed rows with `\033[row;1H\033[2K`. It clears on startup and resize only. Use semantic colors for running, waiting, success, warning, and error.

- [ ] **Step 5: Implement detail views and controls**

`ai-monitor.sh detail <pane>` supports:

```text
1 Timeline  2 Decision  3 Screen  4 Config  5 Logs
p pause/resume  r reassess  c config  Enter target  q/Ctrl-C stop
```

Timeline appends new journal events. Other views redraw only on tab switch or relevant event change. Manual tab selection pins the view until the user selects another. Enter uses `tmux select-pane -t <target>`.

- [ ] **Step 6: Verify rendering and stable scrollback**

Run `bash tests/test_ai_console.sh`. In an isolated 284x54 tmux session, enter copy-mode in detail, hold a historical line, wait through three overview updates, and verify the detail pane's `scroll_position` and captured historical line remain unchanged.

- [ ] **Step 7: Commit the console slice**

```bash
git add scripts/ai-monitor.sh scripts/ai.sh tests/test_ai_console.sh
git commit -m "Keep supervision detail stable while live status changes" \
  -m "Constraint: The target pane must remain readable and focused after launch" \
  -m "Rejected: Whole-pane repaint loop | it destroys scrollback and causes visible flicker" \
  -m "Confidence: high" -m "Scope-risk: broad" \
  -m "Tested: responsive split fixtures, five rendered views, and real tmux copy-mode stability"
```

### Task 6: Decision Evidence, Logs, Completion, and Cleanup

**Files:**
- Modify: `scripts/prompts/decide.md`
- Modify: `scripts/prompts/decide.schema.json`
- Modify: `scripts/ai.sh`
- Modify: `scripts/ai-monitor.sh`
- Modify: `tests/test_ai_runtime.sh`
- Modify: `tests/test_ai_supervision.sh`

- [ ] **Step 1: Add failing evidence/logging tests**

Assert optional schema fields parse without becoming required, decision files contain exact structured output, `decision` logging omits screens, `full` logging writes mode-600 screen/prompt files, and final summary includes counts, duration, reason, and log path.

- [ ] **Step 2: Run and confirm current flat logs fail**

Run:

```bash
bash tests/test_ai_runtime.sh
bash tests/test_ai_supervision.sh
```

Expected: FAIL because current `.detail.log` is presentation text rather than canonical per-run data.

- [ ] **Step 3: Extend the optional decision contract**

Add optional `pane_state`, `goal_status`, `risk`, and `evidence` properties while preserving the five existing required fields. Update `decide.md` to tie `done` to the configured goal and request concise observable evidence, not hidden reasoning.

- [ ] **Step 4: Persist each model call and final report**

Write `decisions/NNNN.json`, `decisions/NNNN.meta.json`, and `backend/NNNN.stderr`. Under `full`, also write `screens/NNNN.txt` and `prompts/NNNN.txt`. Add `ai.sh report [run-id|latest]` for a terminal-readable final summary.

- [ ] **Step 5: Implement bounded completion hold and retention**

On DONE, write `final.json`, notify, show the final monitor summary, and wait 12 seconds by default. `k` cancels auto-close; `q` closes. Cleanup removes inactive runs older than retention and never deletes a run referenced by a live `.watch` file.

- [ ] **Step 6: Run all non-live test suites**

Run:

```bash
bash tests/test_ai_runtime.sh
bash tests/test_ai_events.sh
bash tests/test_ai_supervision.sh
bash tests/test_ai_console.sh
bash tests/test_ai_lifecycle.sh
```

Expected: all PASS.

- [ ] **Step 7: Commit the observability slice**

```bash
git add scripts/prompts/decide.md scripts/prompts/decide.schema.json scripts/ai.sh scripts/ai-monitor.sh tests
git commit -m "Leave a complete audit trail for every supervisor decision" \
  -m "Constraint: Full screen and prompt logs are explicit because they may contain secrets" \
  -m "Directive: Monitor rendering must remain derived from structured journals" \
  -m "Confidence: high" -m "Scope-risk: moderate" \
  -m "Tested: logging levels, evidence schema, final reports, retention, and full regression suite"
```

### Task 7: Documentation, Real tmux Acceptance, and Release Integration

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-13-supervision-console-design.md` only if implementation exposes a verified constraint that changes the contract
- Test: all `tests/test_ai_*.sh`

- [ ] **Step 1: Update user-facing documentation**

Document:

- `w`, `W`, and `v` unified entry flow
- right/compact/popup responsive behavior
- all overview/detail controls
- event-first and idle-fallback semantics
- one-call invariant and retry behavior
- configuration provenance
- run directory/file formats and sensitive `full` logging warning
- migration from top split and flat detail files
- hook status/reinstall troubleshooting

- [ ] **Step 2: Run static checks**

Run:

```bash
bash -n scripts/ai.sh scripts/ai-monitor.sh scripts/lib/ai-runtime.sh scripts/needinput-notify.sh scripts/install-hooks.sh
if command -v shellcheck >/dev/null 2>&1; then shellcheck scripts/ai.sh scripts/ai-monitor.sh scripts/lib/ai-runtime.sh scripts/needinput-notify.sh scripts/install-hooks.sh; fi
jq empty scripts/prompts/decide.schema.json
```

Expected: no syntax/schema errors; every shellcheck finding is fixed or documented with a narrow inline disable.

- [ ] **Step 3: Run the full automated suite twice**

Run:

```bash
for pass in 1 2; do
  for test in tests/test_ai_*.sh; do bash "$test"; done
done
```

Expected: two clean passes to catch timing flakiness.

- [ ] **Step 4: Run isolated real-tmux acceptance**

Create disposable sessions for 284x54, 150x40, and 100x30 layouts with a fake target agent and deterministic backend. Verify layout geometry, focus, controls, event wake latency, no overlapping backend PIDs, copy-mode stability, completion auto-close, and process cleanup. Capture pane screenshots/text as test evidence under `/private/tmp`, not the repository.

- [ ] **Step 5: Perform live configuration migration**

Fast-forward the installed copy at `~/.tmux/plugins/tmux-radar`, reload the plugin/config, run `scripts/install-hooks.sh install`, restart only the disposable Codex/Claude sessions used for acceptance, and verify `install-hooks.sh status`. Do not interrupt unrelated user sessions.

- [ ] **Step 6: Verify live process hygiene**

Confirm:

```bash
ps -axo pid=,ppid=,command= | rg 'tmux-radar|codex exec.*(spark|luna)' 
```

Only intentionally active live acceptance processes may remain. Stop the acceptance watch and verify the list is empty before completion.

- [ ] **Step 7: Commit documentation and integration evidence**

```bash
git add README.md docs/superpowers/specs/2026-07-13-supervision-console-design.md
git commit -m "Teach users how to inspect and control supervision" \
  -m "Confidence: high" -m "Scope-risk: narrow" \
  -m "Tested: two full automated passes and isolated real-tmux acceptance" \
  -m "Not-tested: Existing unrelated long-running user agent sessions were intentionally not restarted"
```

- [ ] **Step 8: Review, merge, push, and report**

Review the full branch diff for unrelated changes and secret-bearing fixtures. Merge `feature/supervision-console` into `main` with a fast-forward when possible, push `main`, synchronize `~/.tmux/plugins/tmux-radar`, and report commit IDs, test counts, live hook status, log location, and any residual compatibility risk.

## Completion Checklist

- [ ] Every spec success criterion maps to a passing test or documented manual acceptance result.
- [ ] No model call survives target/monitor/watch termination.
- [ ] No duplicate or overlapping model calls occur under event bursts or timeouts.
- [ ] The exact user goal and all advanced configuration provenance are visible and persisted.
- [ ] Overview updates do not alter detail scrollback.
- [ ] Native hooks wake watches; idle fallback uses no screen-text parsing.
- [ ] Full logging is permission-restricted and explicitly opt-in.
- [ ] Main, origin/main, and installed live copy resolve to the same final commit.

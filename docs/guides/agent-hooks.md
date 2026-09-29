# Agent hooks

tmux-radar uses native lifecycle hooks when an agent provides them. Hooks are
the preferred trigger: they identify an approval, user response, or completed
turn directly instead of inferring intent from terminal text. Agents without a
hook can still use the semantic idle fallback described in
[configuration](configuration.md#hooks-first-and-semantic-fallback).

## Claude Code hooks

The installer adds seven command hooks to `~/.claude/settings.json`. Each
calls one notifier subcommand with the hook JSON on stdin.

| Claude event | Subcommand | Result |
| --- | --- | --- |
| `SessionStart` | `claude-register` | Registers the session as working and drops a stale ask from its previous life. |
| `Notification` | `claude-mark` | Read by `notification_type`: `permission_prompt` is an approval (Claude Code 2.1.283 sends the bare sentence `Claude needs your permission`; a tool name is kept as the detail when the message carries one), `elicitation_dialog`, `elicitation_url_dialog` and `agent_needs_input` are questions, `elicitation_complete` and `elicitation_response` clear the mark, `idle_prompt` and `auth_success` change nothing. Any other type, or none, marks with the message as given. |
| `Stop` | `claude-stop` | Marks the turn finished, labelled with the first line of `last_assistant_message`. Writes no mark when a subagent or workflow is in `background_tasks`, or when `session_crons` is pending in a turn a wakeup started. |
| `StopFailure` | `claude-fail` | Marks the turn failed and names the `error`. |
| `UserPromptSubmit` | `claude-clear` | Clears the session mark. A `source` of `loop_wakeup` or `schedule_wakeup` records that the schedule started the turn. |
| `PostToolUse` | `claude-resolved` | Clears the session mark when a tool ran on the main thread and started after the mark was written (now minus `duration_ms`). Ignores tool calls that carry `agent_id`. |
| `SessionEnd` | `claude-end` | Removes the registry row and the session's marks. |

Every subcommand first asks whether the session is attended. Claude Code sets
`CLAUDE_CODE_SESSION_ATTENDED` in the hook environment: `1` for a session with
a person at the prompt, `0` for `claude -p`, Agent SDK runs and background
jobs. An unattended run that is not a background job (`CLAUDE_JOB_DIR` unset,
`CLAUDE_CODE_SESSION_KIND` not `bg`, `daemon` or `daemon-worker`) is ignored
completely. Such a run usually starts inside another agent's tool call and
inherits that agent's `TMUX_PANE`; without this rule its Stop marks the host
pane finished while the host agent is mid-turn. On Claude Code versions that
do not set the variable, an `sdk-*` `CLAUDE_CODE_ENTRYPOINT` means the same.

`claude-resolved` runs after every tool call, so it is built to cost almost
nothing when there is nothing to do. It exits before bash reads the rest of
the script when the mark file is empty, and after one `grep` when no mark
carries the key of `CLAUDE_CODE_SESSION_ID`: about 5 ms either way on the
machine it was measured on.

All seven hooks are synchronous. Claude Code waits for each, so a reply never
overtakes the Stop it answers and a tool result never clears the mark of a
prompt raised after it. Do not mark any of them `async`.

## Agents that speak Claude's hook dialect

Grok Build, the Cursor CLI, Factory Droid, Gemini CLI and Auggie took their
hook design from Claude Code: a JSON file maps event names to commands, and
each command receives the event as JSON on stdin. Event names, field names and
timeout units differ. One adapter reads all of them: `needinput-notify.sh
hook <agent>` for hooks in an agent's own file (`hook-resolved <agent>` for
tool results, which takes the fast exit described above), and the `claude-*`
subcommands for hooks in Claude's file. The adapter first rewrites the
payload into Claude's field names (`sessionId` and `conversation_id` become
`session_id`, `workspace_roots[0]` becomes `cwd`, `prompt_response` becomes
`last_assistant_message`), then reads which agent fired the event off the
process tree.

| Agent | Hook file | Events radar wires | Differences and checks |
| --- | --- | --- | --- |
| Grok Build 1.0.41 | none: it runs the hooks in `~/.claude/settings.json` | Claude's seven | camelCase payload with snake_case twins; `Stop` carries a `reason`. Checked against live sessions. |
| Cursor CLI 2026.09.28 | `~/.cursor/hooks.json` | `sessionStart`, `beforeSubmitPrompt`, `stop`, `postToolUse`, `sessionEnd` | No approval event. `stop` carries `status` (`completed`, `aborted`, `error`) and does not fire in `-p` mode. Checked against a live session. |
| Factory Droid 0.82.0 | `~/.factory/settings.json` | `SessionStart`, `UserPromptSubmit`, `Notification`, `Stop`, `PostToolUse`, `SessionEnd` | Claude's schema with camelCase twins; timeouts in seconds; `Stop` carries no final text. Session start and end checked live. |
| Gemini CLI 0.50.0 | `~/.gemini/settings.json` | `SessionStart`, `BeforeAgent`, `Notification`, `AfterAgent`, `AfterTool`, `SessionEnd` | Approval is `Notification` with `notification_type` `ToolPermission`; `AfterAgent` carries the answer. Timeouts in ms. Follows the published schema. |
| Auggie 0.22.0 | `~/.augment/settings.json` | `SessionStart`, `Stop`, `PostToolUse`, `SessionEnd` | No prompt and no approval event, so the first tool result of the next turn clears a finished mark. `conversation_id` is the session. Follows the published schema. |

The Cursor entries are the `claude-*` commands, spelled exactly as in
Claude's file. Cursor's hook loader can also read Claude's hook files (a live
check with this machine's settings showed it did not run them), and it drops
a Claude hook whose command equals one of its own for the same event; Grok
skips a repeated hook the same way. Either way each event runs once. Cursor rejects the whole file over one unknown event name, so the
installer writes only the five above. Gemini runs hooks by default
(`hooksConfig.enabled`) and shows an indicator while one runs
(`hooksConfig.notifications`).

A stop is read by its outcome where the agent names one (Grok's `reason`,
Cursor's `status`, Auggie's `agent_stop_cause`): `shutdown` changes nothing
because the session end reports it, an abort or interrupt clears the mark,
`error` marks the turn failed, and anything else is a finished turn.

Amp has no shell hooks, only a TypeScript plugin API, so the screen scanner
is all radar sees of it.

### Which agent fired the event

The nearest watched agent above the hook process fired it. Three rules keep
events on the right pane:

- A run that another watched agent started (it stands above the one that
  fired) reports nothing: `grok -p` or `codex exec` launched from a tool call
  inherits the host's `$TMUX_PANE`, and its events would mark a pane whose own
  agent is mid-turn. Agents that say they are headless are also read directly
  (Claude's attended flag, the `codex exec` originator in its rollout, pi's
  `ctx.mode`, OpenCode's `run` subcommand).
- A hook installed for one agent (`hook droid`) but fired by a different
  agent in the tree changes nothing. That agent read another tool's config,
  and it reports through hooks of its own.
- An event with no pane is placed by its working directory only when Claude
  sent it (its background sessions). A payload that carries `cursor_version`
  with no agent in the tree comes from the Cursor editor, which runs the same
  hook file outside tmux, and is dropped.

## Install Kimi Code hooks

Kimi Code reads repeated `[[hooks]]` tables from its active `config.toml`.
The installer follows the same path rule: `$KIMI_CODE_HOME/config.toml` when
`KIMI_CODE_HOME` is set, otherwise `~/.kimi-code/config.toml`. It manages
exactly one marker-delimited block at that path:

```sh
scripts/install-hooks.sh install
scripts/install-hooks.sh status
```

The installer skips Kimi when neither `kimi` nor the active Kimi config
directory is present.
If Kimi is present, it creates a missing `config.toml`, preserves every byte
outside tmux-radar’s block (including comments and user hooks), writes through
a symlink target, and backs up a changed existing file. A reinstall replaces
only the one managed block. Marker duplicates or malformed ordering are an
error rather than a guess.

The managed block contains seven `[[hooks]]` tables, each with only Kimi’s
supported `event`, `command`, and `timeout` keys. Each command invokes
`needinput-notify.sh kimi-hook` with a five-second timeout.

| Kimi event | Normalized event | Result |
| --- | --- | --- |
| `SessionStart` | `session_start` | Registers the session as working and clears stale action marks. |
| `PermissionRequest` | `approval` | Marks the session waiting, shows an approval notification, and enqueues an approval. |
| `PermissionResult` | `approval_resolved` | Clears only that session’s action mark and enqueues a resume/takeover signal. |
| `UserPromptSubmit` | `user_resumed` | Clears that session’s action mark and supersedes stale automatic delivery. |
| `Stop` | `turn_complete` | Marks the turn done, shows a completion notification, and enqueues completion. |
| `Interrupt` | `interrupt` | Clears pending action state and cancels stale automatic delivery. |
| `SessionEnd` | `session_end` | Removes registry/action state while retaining prior completion history until its normal TTL. |

Kimi’s documented payload includes `hook_event_name`, `session_id`, and
`cwd`. The session ID is the stable Kimi identity. `PermissionRequest` and
`Stop` remain visibly distinct: a completion notice is never labelled as an
approval.

Kimi hooks fail open by Kimi’s runtime contract. Successful hook handling
writes no stdout and returns quickly. Inspect the hook process’s stderr or the
tmux-radar run journal when a hook fails.

### Reload and status

After installation, run `/reload` inside an existing Kimi TUI or start a new
session, then check the current installation:

```sh
scripts/install-hooks.sh status
```

Healthy output lists all seven Kimi events as installed and ends with
`Kimi hooks installed: 7/7`. Status compares the complete owned block, not
substrings. Any missing, reordered, duplicated, changed, or unsupported field
reports `managed block drifted` and returns nonzero; reinstall after resolving
the marker/configuration error.

### Uninstall

```sh
scripts/install-hooks.sh uninstall
```

Uninstall removes only the exact Kimi marker block. It preserves user TOML and
other agents’ configuration. The all-agent install/uninstall command runs as a
transaction; if a later agent update fails, the installer restores the saved
configuration files.

## Normalized event interface

Custom integrations call the shared notifier instead of manipulating files:

```text
needinput-notify.sh agent-event <agent-kind> <normalized-event>
```

The command reads exactly one JSON object from standard input:

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

`session_id` is required and must be stable for one vendor session. `cwd`,
`label`, and `process` are optional strings. `pane` and `pid` are
optional: the notifier uses the supplied pane first, then `TMUX_PANE`, then
process ancestry; it resolves a missing/zero PID from the agent process when
possible. Valid pane IDs are `%` followed by digits; a supplied PID must be a
non-negative integer.

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

The notifier owns locking, identity, registry rows, marks, watcher inbox
events, notification labels, and cleanup. An adapter must never write the
registry, mark, inbox, or run-journal files directly.

### Validation and failure semantics

The generic interface fails closed before state mutation. Unknown events,
malformed or non-object JSON, an invalid agent kind, invalid pane/PID, and a
missing stable session ID write an error to stderr, exit with status **2**, and
leave registry and marks unchanged.

Vendor-facing adapters must then apply the vendor's documented failure
contract. Kimi reserves exit `2` for an intentional block on blockable events,
so `kimi-hook` converts validation/data failures to ordinary nonzero exit `1`.
The adapter template does the same by default. This reports failure without
allowing a broken observability hook to block a turn, prompt, or tool.

## Build a custom adapter

Start from
[`examples/hooks/custom-agent-adapter.sh`](../../examples/hooks/custom-agent-adapter.sh).
It is executable, Bash 3.2-compatible, and depends only on Bash, `jq`, and
the shared notifier.

1. Set `TMUX_RADAR_NOTIFY` to the absolute path of
   `scripts/needinput-notify.sh`.
2. Replace `example-agent` with a stable lowercase agent kind containing only
   letters, digits, dots, underscores, or hyphens.
3. Replace the eight `VENDOR_*` names with the vendor’s documented event names.
4. Update the `jq` field paths if the vendor does not use `event`,
   `session_id`, `cwd`, `pane`, `pid`, `process`, and `message`.
5. Keep the normalized event names and the final `agent-event` invocation.

The template reads one vendor object from stdin, rejects zero/multiple objects,
maps the vendor event in Bash, transforms the vendor fields with `jq`, then
calls the shared notifier. Unknown events, malformed payloads, and notifier
validation errors fail visibly on stderr with exit `1`, which is Kimi's
documented fail-open error class. Before adapting another vendor, confirm its
non-blocking error code and change the final translation if necessary.

### Isolated adapter checks

First validate the template itself:

```sh
bash -n examples/hooks/custom-agent-adapter.sh
```

For a functional test, use a disposable tmux server/state directory and feed a
single vendor approval object through the adapter. The repository’s safety and
registry tests exercise the same generic `agent-event` rejection and lifecycle
contract:

```sh
bash tests/test_safety.sh
bash tests/test_registry.sh
```

Do not “test” an adapter by creating registry or mark rows yourself; that
bypasses the validation and lifecycle behavior the adapter is required to use.

## Adding a first-class agent

Use a custom adapter when the vendor can invoke a hook but needs no managed
installation. Add a first-class integration only when tmux-radar should own a
vendor configuration file and lifecycle mapping.

1. Document the vendor’s official hook path, supported schema, reload behavior,
   and failure contract.
2. Add a strict adapter in `scripts/needinput-notify.sh` that maps only known
   vendor events to the normalized interface.
3. Add installer ownership in `scripts/install-hooks.sh`: one unambiguous
   managed block, preservation outside it, backup, symlink-safe writes,
   idempotent reinstall, status, uninstall, and transaction rollback.
4. Add tests for every lifecycle event, two concurrent sessions, duplicate or
   out-of-order delivery when relevant, malformed payloads, invalid markers,
   installation preservation, partial status, uninstall, and rollback.
5. Add a documentation table that distinguishes approvals, input, resumes,
   interrupts, completion, and session cleanup.

Do not add vendor-specific state mutations beside the shared event layer. A
single normalized path keeps session identity and notification semantics
consistent across agents.

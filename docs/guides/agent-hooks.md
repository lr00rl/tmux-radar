# Agent hooks

tmux-radar uses native lifecycle hooks when an agent provides them. Hooks are
the preferred trigger: they identify an approval, user response, or completed
turn directly instead of inferring intent from terminal text. Agents without a
hook can still use the semantic idle fallback described in
[configuration](configuration.md#hooks-first-and-semantic-fallback).

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
single normalized path keeps session identity, notification semantics, and
supervisor delivery consistent across agents.

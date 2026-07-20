# AI supervisor configuration

Configure the optional supervisor with tmux global options before tmux-radar
loads:

```tmux
set -g @radar-ai 'on'
set -g @radar-ai-hooks-first 'on'
set -g @radar-ai-fallback-capture-lines '20'
```

Reload the tmux configuration after changing `@radar-ai` or its key binding.
Other values are read when a run is created; changing them affects new runs,
not a run whose effective configuration was already journaled.

## Effective configuration and provenance

Each watch run records a schema-v1 `config.json`. Every run setting is stored
as `{value, source}`, and the native setup console shows the effective value
and its source.

| Source | Meaning |
| --- | --- |
| `default` | Built-in value. |
| `tmux` | An explicit `@radar-ai-*` tmux option. |
| `custom` | A value supplied in setup, a command argument, or a setup override. |
| `runtime` | A runtime override, including the backend command seam. |
| `preset` | One of the native console presets changed the authority fields. |
| `profile-managed` | A Codex profile supplies model and effort because no explicit option overrides them. |
| `legacy` | A decoded pre-schema-v1 run artifact. |

For current runs, precedence is built-in default, explicit tmux option,
setup/custom value, then runtime override. A nonempty `@radar-ai-profile`
replaces the default model and effort with `profile-managed`; explicit model
or effort options retain `tmux` provenance and win for that field. Legacy
`@switcher-ai-*` names remain fallback-only; use `@radar-ai-*` for new
configuration.

## Options

Values in parentheses are validated ranges or allowed values.

### Triggering, authority, and budget

| Option | Default | Meaning and tradeoff |
| --- | --- | --- |
| `@radar-ai` | `off` | Enables the supervisor menu and binding. Requires a compatible decision backend and `jq`. |
| `@radar-ai-key` | `A` | Key after the tmux prefix that opens the menu. Reload tmux after changing it. |
| `@radar-ai-autonomy` | `confirm` | One-shot `ask`/`decide` authority: `suggest`, `confirm`, or `auto`. `auto` can send an allowed decision without a prompt. |
| `@radar-ai-watch-autonomy` | `auto-safe` | Watch authority: `suggest`, `confirm`, `auto-safe`, or `auto`. `auto-safe` sends only decisions marked safe and escalates the rest. |
| `@radar-ai-approval-policy` | `safe-auto` | Watch policy: `safe-auto`, `manual`, or `always-allow`. It constrains approval handling. |
| `@radar-ai-watch-always-allow` | `off` | `on` prefers a visible “always allow” choice for safe actions. It lowers interruption frequency and increases authority. |
| `@radar-ai-hooks-first` | `on` | Uses native approval/input/completion hooks immediately. See [Hooks first](#hooks-first-and-semantic-fallback). |
| `@radar-ai-poll` | `5` | Idle interval in whole seconds (`1`–`3600`). Shorter intervals reduce fallback latency but sample panes more often. The next interval starts only after the preceding operation finishes. The one-second floor preserves a childless wait on macOS Bash 3.2. |
| `@radar-ai-stable-screen-threshold` | `1` | Required repeated nonempty stable projections (`1`–`20`) before fallback assessment. Higher values reduce incidental assessments and add latency. |
| `@radar-ai-max-calls` | `40` | Maximum model decisions per watch (`1`–`10000`). Reaching it pauses the watch rather than spending indefinitely. |
| `@radar-ai-timeout` | `120` | Per-model-call hard limit in seconds (`5`–`3600`). Timeout terminates the owned model process group. |
| `@radar-ai-retry-limit` | `3` | Retry count for retryable backend or decision-output failures (`0`–`10`). |
| `@radar-ai-retry-backoff` | `15` | Initial retry delay in seconds (`0`–`3600`); normal retries use 15/30/60 seconds from this base. |

### Brain and prompt

| Option | Default | Meaning and tradeoff |
| --- | --- | --- |
| `@radar-ai-model` | `gpt-5.6-luna` | Codex model for decision calls. Larger/slower models can improve judgement but raise latency and cost. |
| `@radar-ai-effort` | `high` | `minimal`, `low`, `medium`, `high`, or `xhigh`. Higher effort can improve complex decisions at the cost of latency and usage. |
| `@radar-ai-profile` | empty | Codex profile passed as `codex exec -p <profile>`. With no explicit model/effort, the profile manages both values. |
| `@radar-ai-codex-path` | `PATH` lookup | Absolute Codex executable override. The selected binary is preflighted and identity-checked. |
| `@radar-ai-cmd` | empty | Replaces Codex with a shell command that reads the decision prompt on stdin and emits decision JSON on stdout. Treat it as executable code with the same trust level as tmux config. |
| `@radar-ai-rules` | empty | File path or literal approval rules appended to each decision prompt. If unset, `~/.config/tmux-radar/rules.md` is used when present. Rules are sent to the decision backend. |
| `@radar-ai-prompt-dir` | empty | Directory that shadows `scripts/prompts/` by filename. It changes prompts and schemas; validate it before unattended use. |

### Pane evidence and console

| Option | Default | Meaning and tradeoff |
| --- | --- | --- |
| `@radar-ai-fallback-capture-lines` | `20` | Bottom lines used only for no-hook stability sampling and a `screen_idle` decision (`8`–`200`). Smaller captures cost less and expose less content; larger captures add context. |
| `@radar-ai-capture-lines` | `120` | Bottom lines passed to the model for native events and ordinary decisions (`20`–`5000`). It does not control fallback sampling. Larger values increase prompt size and privacy exposure. |
| `@radar-ai-monitor-excerpt-lines` | `16` | Lines rendered in console detail (`3`–`500`). This does not change model evidence. |
| `@radar-ai-monitor` | `on` | Compatibility guard. Native supervision requires a visible owner surface; setting this `off` rejects the launch instead of creating a detached watcher. |
| `@radar-ai-monitor-pos` | `right` | Legacy monitor placement: `right`, `top`, or `bottom`. Native launch chooses a split or popup from live dimensions. |
| `@radar-ai-monitor-size` | `12` | Legacy top/bottom compact-monitor height. |
| `@radar-ai-monitor-size-h` | `84` | Requested native right-console width. The launcher clamps it to 56–112 columns while keeping at least 64 target-pane columns. |
| `@radar-ai-overview-ratio` | `25` | Compatibility field (`15`–`50`). The native console uses a fixed summary header and gives remaining rows to its selected evidence view. |
| `@radar-ai-completion-close-delay` | `12` | Seconds that a completion summary remains visible (`0`–`60`). `k` keeps it open and `q` closes it. |
| `@radar-ai-verify-timeout` | `30` | Seconds allowed for post-send verification. Increase it only when a target needs longer to render a visible result. |

### Logging, privacy, and retention

| Option | Default | Meaning and tradeoff |
| --- | --- | --- |
| `@radar-ai-logging` | `decision` | `decision` stores structured decision metadata and backend stderr. `full` also stores exact decision prompts and pane captures. Full logging can retain secrets visible in a pane. |
| `@radar-ai-screen-snapshots` | `off` | Stores per-call pane captures without full prompt logging. Captures may still contain sensitive text. |
| `@radar-ai-retention-days` | `7` | Keeps finalized run directories for this many days (`0`–`3650`). Active runs are protected. `0` makes finalized runs eligible immediately. |

## Hooks first and semantic fallback

`hooks_first=on` is the default. When an installed agent hook reports
`approval`, `input_required`, or `turn_complete`, the watcher journals and
assesses it immediately. Native hooks give the fastest, most specific signal.

With `hooks_first=off`, actionable native events are still journaled, but
they are deliberately deferred. The watcher waits for semantic fallback:

1. It samples the bottom `fallback_capture_lines` lines at the idle deadline.
2. It normalizes only carriage returns and trailing whitespace, then computes
   an order-preserving projection of lines unchanged between samples.
3. A nonempty projection must recur `stable_screen_threshold` times.
4. Only an exactly equal projection hash is deduplicated. Adding, removing, or
   replacing any stable line creates one new `screen_idle` event, and the model
   receives only the current fallback capture.
5. The model reads one immutable normalized fallback capture. Before sending
   keys, a fresh capture must compare byte-for-byte equal to that same file.
   The stable projection controls triggering and cost only; it never authorizes
   delivery to a changed screen.

This troubleshooting mode can miss the immediacy and semantic precision of a
hook. It has at least one poll interval of latency, can assess a stable
non-prompt screen, and may consume a model call before returning `wait`.
Projection deduplication prevents repeated spending on unchanged evidence.
Use it to diagnose a hook integration or for agents without hooks; do not use
it as a lower-latency replacement for native lifecycle events.

This exact delivery guard is intentionally conservative. A changing timer or
spinner can cancel an automatic fallback action even when the prompt is still
visible. Install a native hook when reliable automatic action matters.

`capture_lines` and `fallback_capture_lines` are intentionally separate:
native-event decisions use `capture_lines` (120 by default), while fallback
sampling and `screen_idle` decisions use `fallback_capture_lines` (20 by
default). Raising one does not raise the other.

## Common profiles

These settings are run-start choices. Put them before plugin load, then start a
new watch.

### Default supervised work

```tmux
set -g @radar-ai-watch-autonomy 'auto-safe'
set -g @radar-ai-approval-policy 'safe-auto'
set -g @radar-ai-watch-always-allow 'off'
set -g @radar-ai-hooks-first 'on'
```

This uses native hooks, lets safe decisions proceed, and escalates unsafe or
ambiguous actions.

### Cautious review

```tmux
set -g @radar-ai-watch-autonomy 'confirm'
set -g @radar-ai-approval-policy 'manual'
set -g @radar-ai-watch-always-allow 'off'
set -g @radar-ai-logging 'decision'
set -g @radar-ai-screen-snapshots 'off'
```

This favors user review and minimizes durable screen retention. The native
console’s **Cautious** preset applies `manual`, `confirm`, and `off` to
these authority fields for that run.

### Trusted, repetitive local work

```tmux
set -g @radar-ai-watch-autonomy 'auto-safe'
set -g @radar-ai-approval-policy 'always-allow'
set -g @radar-ai-watch-always-allow 'on'
set -g @radar-ai-max-calls '20'
```

Use this only for a narrow, trusted local workflow. It prefers visible
“always allow” choices only for safe actions; destructive or ambiguous actions
still require escalation. The native **Always allow** preset makes the same
authority selection.

## Process lifecycle

A watch is a single serialized supervisor. It persists effective configuration,
accepts durable inbox events, and writes phase/event/final artifacts. One model
process group is the only expected long-lived child.

While armed, retrying, verifying, or holding a completion, the watcher blocks
inside its own Bash process with bounded reads of at most one second. It checks
the durable inbox, pause state, target pane, and owner lease on each wake. It
does not create a background `tmux wait-for` or timer child. This bounds
normal event wake latency to roughly one second and prevents orphaned waiters
after a stop.

`q`, `Ctrl-C`, `TERM`, `INT`, `HUP`, pane loss, owner loss, and
session loss converge on the same finalizer. It cancels delivery, terminates an
owned model process group, removes its live pointer only when it owns that
generation, writes one `final.json`, and removes transient files. A stop
acknowledgement is successful only after the watcher and recorded owned
processes are gone.

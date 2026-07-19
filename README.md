# tmux-radar

**Mission Control for busy tmux workspaces.**

Stop hunting through dozens of sessions, windows, and panes. tmux-radar gives
you a full-screen workspace navigator with live previews, recent context, and
AI-aware status so you can jump straight to the pane that needs you.

![view: tree | recent | AI status](https://img.shields.io/badge/views-tree%20%7C%20recent%20%7C%20AI--status-blue)

## Why not `choose-tree`?

tmux's built-in `choose-tree` is good for browsing sessions. tmux-radar is for
getting back to work fast when a workspace is large, active, and full of
long-running agents.

| Problem | tmux-radar gives you |
|---------|----------------------|
| "Where was I just working?" | MRU recent view |
| "Which pane is waiting for me?" | AI status view |
| "What is happening in that pane?" | Bottom-anchored live preview |
| "I know the pane title, not the session" | Title-focused fuzzy search |
| "Claude/Codex/Kimi finished while I was elsewhere" | Status marks and bar |

## Features

- **Workspace command palette** — session tree, recent (MRU), and AI status,
  switchable live inside the popup. Pick which one opens by default.
- **Title-only fuzzy search** — type to match the window name, not the path or
  running command. Results rank by match score as you type, recency order at rest.
- **Smart cursor in recent view** — opens with the cursor on the 2nd entry,
  since row 1 is always the current window (you won't switch back to yourself).
  The current window stays in the list, one `↑` away.
- **Live preview** — the selected window's content, no wrap, anchored to the
  bottom (current prompt/state visible), with line/page scroll.
- **AI status alerts** — Claude/Codex/Kimi/OpenCode flag their pane for action-required
  prompts and finished-turn notices; a **persistent bar** appears on a second
  status line while an off-screen mark is fresh,
  the pane's **title flips to a status label** (`⚠` action required, `✓`
  finished, `!` notice), and the pane shows up in the AI status view.
  Everything clears when you focus the window or reply — and
  **stale marks self-heal**: a mark whose agent TUI has exited is dropped
  automatically.
- **Background Claude sessions covered** — Claude Code sessions that run outside
  any tmux pane (dashboard / background jobs / cloud) are tracked per
  `session_id` and surface on the bar and in the AI status view too. Sessions
  that *do* live in a pane but lost `$TMUX_PANE` (env-scrubbing launchers,
  agent runners) are resolved back to their real pane via the process tree or
  Claude's hook/job cwd.
- **Optional AI supervisor** — `prefix + A`: drive tmux from natural language,
  have Codex answer a waiting Claude/Codex/Kimi prompt for you, or run a resident
  watcher that auto-approves *safe* prompts until a pane's task is done — with
  a read-only brain, an audit log, and escalation for anything risky.

## Requirements

- tmux ≥ 3.2 (uses `display-popup`)
- [`fzf`](https://github.com/junegunn/fzf)
- `jq` (AI-status hook installation and the optional supervisor runtime)
- macOS or Linux; hook installation avoids platform-specific `sed -i` behavior
  and preserves symlinked dotfile configs.
- The optional native supervisor console: a release binary installed by
  `scripts/ensure-native.sh install <version>`, or Go 1.25+ for a local build

## Install (TPM)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'lr00rl/tmux-radar'
```

Then `prefix + I` to install. Default binding: `prefix + C-w`.

Manual install:

```sh
git clone https://github.com/lr00rl/tmux-radar ~/.tmux/plugins/tmux-radar
run-shell ~/.tmux/plugins/tmux-radar/tmux-radar.tmux   # or add to tmux.conf
```

The picker and AI-status notifications are shell-only. The `w` / `W` / `v`
supervisor console uses one native `tmux-radar` process. Build it locally:

```sh
cd ~/.tmux/plugins/tmux-radar
scripts/build-native.sh
./bin/tmux-radar supervisor doctor
```

Or explicitly install a tagged release (download, SHA-256 verification,
protocol check, then atomic rename):

```sh
scripts/ensure-native.sh install vX.Y.Z
```

Plugin load and ordinary `prefix + A` use never download or compile anything.
`scripts/ensure-native.sh resolve` is local-only. Until the native binary is
installed, the one-release rollback is explicit:
`TMUX_RADAR_LEGACY_UI=1`.

## Usage

`prefix + C-w` opens the picker. Inside:

| Key | Action |
|-----|--------|
| type | fuzzy search **window + pane title** |
| `ctrl-t` | session **tree** view |
| `ctrl-r` | **recent** (MRU) view |
| `ctrl-i` | **AI status** view: action-required marks first, finished-turn notices next, then other detected AI panes as context |
| `ctrl-e` | **expand / collapse panes** (nest panes under each window) |
| `alt-p` | toggle preview |
| `shift-↑` / `shift-↓` | scroll preview by line |
| `PgUp` / `PgDn` | scroll preview by page |
| `ctrl-n` / `ctrl-p` | move selection (fzf default) |
| `Enter` | switch to the window (or pane, when a pane row is selected) |

**Pane level.** Tree and recent start at window granularity. Press `ctrl-e` to
expand panes nested under their window; press it again to collapse. The cursor
stays on the same window group across the toggle. When expanded, search matches
**both** window and pane titles and keeps the window→pane grouping (only matching
rows are shown). The AI status view is always pane-level so you can jump to the
exact AI TUI pane for real pane rows.

## Configuration

Set these **before** the plugin loads:

| Option | Default | Description |
|--------|---------|-------------|
| `@radar-default-view` | `tree` | Initial view: `tree`, `recent`, or `needinput`. |
| `@radar-expand-panes` | `off` | Start with panes expanded (`on`) or collapsed (`off`). Toggle live with `ctrl-e`. |
| `@radar-key` | `C-w` | Prefix key that opens the picker. |
| `@radar-popup-width` | `100%` | Popup width. |
| `@radar-popup-height` | `100%` | Popup height. |
| `@radar-preview` | `right:62%` | fzf preview position/size. |
| `@radar-preview-follow` | `on` | Anchor preview to the bottom (tail-style). |
| `@radar-needinput` | `on` | Enable the AI-status system (hooks/bar). |
| `@radar-needinput-commands` | `codex claude opencode kimi` | Process names the AI status view treats as AI panes. Comma/space/colon separated. |
| `@radar-retitle` | `on` | Rename a marked pane's title to a status label (`⚠` action required, `✓` finished, `!` notice), restored on clear. |
| `@radar-claude-bg` | `on` | Also track Claude sessions running outside tmux panes (background/dashboard/cloud). |
| `@radar-bar` | `auto` | `auto` raises line 2 only while needed and restores the exact previous `status`; `pinned` keeps line 2; `off` tracks marks without raising it. |
| `@radar-bar-ttl` | `60` | Seconds a chip stays on the bar before fading (`0` = until handled). The mark itself persists in the AI status view / pane title until cleared. |
| `@radar-claude-bg-ignore` | `~/.claude:~/.claude-mem` | Colon-separated path prefixes; background sessions whose cwd starts with one (plugin observers, SDK helpers) are not tracked. |
| `@radar-ai` | `off` | Enable the **AI supervisor** (`prefix + A` menu). Needs the `codex` CLI + `jq`. |
| `@radar-ai-key` | `A` | Prefix key that opens the AI supervisor menu (capital `A` so a stray `prefix + a` can't trigger it). |
| `@radar-ai-model` | `gpt-5.6-luna` | Codex model slug used by the supervisor's read-only decision calls. |
| `@radar-ai-effort` | `high` | Reasoning effort per decision (`minimal`/`low`/`medium`/`high`/`xhigh`). |
| `@radar-ai-profile` | *(none)* | Use a [codex config profile](https://github.com/openai/codex) (`codex exec -p <profile>`) instead of the model/effort options. Supervisor isolation still ignores the base interactive config and disables hooks/tools; the explicitly selected profile supplies the brain settings. |
| `@radar-ai-cmd` | *(none)* | Replace Codex entirely: any shell command that reads the prompt on **stdin** and prints the decision **JSON** on stdout (another CLI, a local model, …). |
| `@radar-ai-rules` | *(none)* | **Your approval rules**: a file path (contents used) or a literal text block, appended to every decision prompt with top priority — e.g. "auto-approve npm test / file reads; ALWAYS escalate git push, deploys, anything touching prod". Falls back to `~/.config/tmux-radar/rules.md` when that file exists. |
| `@radar-ai-prompt-dir` | *(none)* | Directory that **shadows** `scripts/prompts/` per file (`decide.md`, `control.md`, `*.schema.json`) — customize the default prompts without editing the plugin. |
| `@radar-ai-autonomy` | `confirm` | One-shot `ask`/`decide`: `suggest` (print only), `confirm` (ask first), `auto`. |
| `@radar-ai-watch-autonomy` | `auto-safe` | Resident `watch`: `auto-safe` (auto-send only safe replies, escalate the rest), `suggest`, `auto`. |
| `@radar-ai-approval-policy` | `safe-auto` | Per-watch approval policy inherited by quick setup; `W` presets `always-allow`. |
| `@radar-ai-hooks-first` | `on` | Let installed native Claude/Codex/Kimi/OpenCode lifecycle hooks wake the watcher immediately. `off` keeps only manual and semantic stable-screen fallback triggers. |
| `@radar-ai-poll` | `5` | Idle-listen interval while watching a pane. The next interval starts after a model decision/action returns, so slow decisions do not overlap. |
| `@radar-ai-stable-screen-threshold` | `1` | Consecutive equal **stable projections** required before no-hook fallback asks the model. Changing spinners, elapsed timers, and footers are removed before comparison. |
| `@radar-ai-max-calls` | `40` | Cost cap: a watcher pauses after this many model calls. |
| `@radar-ai-timeout` | `120` | Hard limit in seconds for one model call (minimum `5`). A timed-out Codex wrapper and all of its children are terminated as one process group. |
| `@radar-ai-retry-limit` | `3` | Maximum retries after invalid JSON, backend failure, or timeout. |
| `@radar-ai-retry-backoff` | `15` | Initial retry delay; production retries use 15/30/60 seconds by default. |
| `@radar-ai-fallback-capture-lines` | `20` | Bottom pane lines sampled by no-hook fallback. Keep this small to reduce capture/model cost; range `8`–`200`. Native events still use the full decision capture below. |
| `@radar-ai-capture-lines` | `120` | Pane lines fed to the model per decision. |
| `@radar-ai-watch-always-allow` | `off` | While watching, prefer the TUI's "don't ask again / always allow" option for **safe** actions (fewer interruptions, lower safety). Menu entry `W` enables it per-watch. |
| `@radar-ai-monitor` | `on` | Legacy monitor toggle. Native supervision always has one visible owner surface so lifecycle and controls cannot become detached accidentally. |
| `@radar-ai-monitor-pos` | `right` | Legacy monitor position. Native mode chooses a right split or popup from the target pane's actual dimensions. |
| `@radar-ai-monitor-size` | `12` | Legacy top/bottom compact-monitor height. |
| `@radar-ai-monitor-size-h` | `84` | Requested native right-console width, clamped to 56–112 columns while preserving at least 64 target columns. |
| `@radar-ai-overview-ratio` | `25` | Effective-config field retained for compatibility; the native console uses a fixed summary header and the remaining rows for the selected evidence view. |
| `@radar-ai-monitor-excerpt-lines` | `16` | Pane-capture lines shown in the monitor detail view. The model still receives `@radar-ai-capture-lines`; this only keeps the UI readable. |
| `@radar-ai-completion-close-delay` | `12` | Seconds to keep the final summary visible. Press `k` to keep it open or `q` to close now. |
| `@radar-ai-logging` | `decision` | `decision` stores structured decisions/metadata/stderr; `full` also stores exact prompts and pane captures. |
| `@radar-ai-screen-snapshots` | `off` | Persist per-call pane captures without enabling full prompt logging. These files may contain sensitive text. |
| `@radar-ai-retention-days` | `7` | Retain inactive structured run directories for this many days. Live runs are never removed. |

Legacy `@switcher-*` options are still honored as fallbacks, but new
configuration should use `@radar-*`.

Example:

```tmux
set -g @radar-default-view 'recent'
set -g @radar-key 'C-j'
set -g @radar-preview 'right:55%'
set -g @radar-needinput-commands 'codex claude opencode kimi'

# AI supervisor (optional)
set -g @radar-ai 'on'
set -g @radar-ai-effort 'minimal'      # fastest decisions
set -g @radar-ai-rules "$HOME/.config/tmux-radar/rules.md"

set -g @plugin 'lr00rl/tmux-radar'
```

An example `~/.config/tmux-radar/rules.md` (loaded automatically when it
exists, even without setting `@radar-ai-rules`):

```markdown
- Auto-approve: running tests, linters, read-only commands, file reads.
- ALWAYS escalate: git push, anything touching prod/deploys, package publishes.
- If Claude asks which approach to take, prefer the smallest change.
```

For focused walkthroughs, see [configuration](docs/guides/configuration.md),
[agent hooks](docs/guides/agent-hooks.md), and
[development](docs/guides/development.md).

## AI status view + alerts (Claude Code / Codex / Kimi / OpenCode)

The `ctrl-i` view scans live tmux panes for configured AI processes, defaulting
to `codex`, `claude`, `opencode`, and `kimi`, and lists matching panes directly. Matching is based on
the pane process tree and processes attached to the pane TTY, not on tmux window
or pane names. Rows are labeled by meaning: **ACTION** for permissions/input that
really need a decision, **DONE** for finished-turn notifications that are useful
to review but are not approvals, and **ACTIVE** for other detected AI panes shown
only as context. Background Claude sessions are shown as non-jumpable status rows
instead of pretending to be a tmux pane.

The plugin sets up the tmux side automatically (AI-status bar status line +
clear on window focus). To let Claude Code, Codex, Kimi, and OpenCode flag their
pane, install the hooks once:

```sh
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh install     # wire hooks
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh status      # check
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh uninstall   # remove
```

It edits `~/.claude/settings.json` with five lifecycle hooks:
`SessionStart` registers a live session, `Notification` marks input,
`Stop` marks a finished turn, `UserPromptSubmit` clears the handled mark, and
`SessionEnd` removes the live registry row plus stale action notices while
deliberately preserving the preceding finished-turn mark. Native Codex handlers
are merged into `~/.codex/hooks.json`; the managed block in
`~/.codex/config.toml` contains matching trust state plus the wrapped legacy
`notify` fallback. Kimi receives one owned marker block in
`~/.kimi-code/config.toml` for `SessionStart`, `PermissionRequest`,
`PermissionResult`, `UserPromptSubmit`, `Stop`, `Interrupt`, and `SessionEnd`.
The installer preserves Kimi's other config and hooks, refuses malformed or
duplicate managed markers, and rolls back all touched configs if a later write
fails. When OpenCode is installed, the installer writes the
dependency-free lifecycle bridge to
`~/.config/opencode/plugins/tmux-radar.js`. One bridge process blocks on a pipe
for the lifetime of each OpenCode TUI; it does not spawn or poll per event.
Permission requests, structured questions, replies, idle completion, errors,
and deletion are ordered by session/generation before changing marks. Existing
user hooks, trust entries, notify chains, and symlinked config paths are
preserved. Restart the affected agent sessions after installation, then review
`/hooks` if Codex asks you to trust the handlers. Kimi's event names and TOML
shape follow its [official hooks reference](https://moonshotai.github.io/kimi-code/en/customization/hooks).

### Agents without native hooks

A missing hook does not disable supervision. After each idle interval,
tmux-radar captures only the bottom
`@radar-ai-fallback-capture-lines` lines (20 by default) and compares adjacent
samples. It projects only lines that remain in order across both samples, which
removes changing spinners, elapsed counters, progress rows, and footers without
matching prompt text. The model is called only when that stable semantic
evidence reaches `@radar-ai-stable-screen-threshold`; an equal or
containment-only projection is deduplicated until meaningful stable evidence
changes.

This is deliberately a fallback, not fake hook coverage:
`install-hooks.sh status` still reports missing hooks, Timeline records
`screen_idle`, and native
events keep their immediate path and larger `@radar-ai-capture-lines` context.
See [Agent hooks and custom adapters](docs/guides/agent-hooks.md) for the
normalized event contract and a copyable adapter.

### How marks are targeted and cleared

- **Interactive TUI in a pane** — the pane comes from the `$TMUX_PANE` that hook
  subprocesses inherit. The mark clears when you focus that window, or (Claude)
  when you submit your next prompt in that session.
- **No `$TMUX_PANE`, but still in a pane** — some launchers scrub the
  environment, and agent runners fork sessions whose hooks don't inherit it.
  Before falling back to a paneless mark, the notifier resolves the hook
  process's **controlling tty / parent chain** against live panes. If that
  fails, Claude hook/job `cwd` is matched against live pane cwd, preferring
  panes whose window/title/command looks Claude-related — so daemon jobs with
  a visible parent workspace still get a jumpable pane mark instead of a bare
  "session id" row.
- **Background Claude sessions** — sessions genuinely outside tmux
  (`$CLAUDE_JOB_DIR` set: the dashboard, background jobs, cloud) get a
  **paneless mark keyed by `session_id`**, labelled `Claude·<project>`. It
  clears when you reply to that session (`UserPromptSubmit`) and is removed by
  `SessionEnd` or process-identity GC. In the AI status view these rows
  are non-jumpable status rows, because there is no real tmux pane to select.
- **Stale marks (agent-liveness GC)** — a pane mark is stale in two ways, and
  both self-heal: the **pane died** (dropped on every state change), or the
  pane is alive but the **agent TUI exited** and the shell got reused.
  Native events maintain `agent-registry` rows containing session key, PID,
  pane, state, cwd, and process identity. GC requires both the recorded PID and
  argv identity to match, so PID reuse cannot keep a dead session alive.
  Pre-upgrade/unhooked sessions retain the process-tree fallback. Detection
  matches ps **argv0 path components**, never
  `pane_current_command`: Claude Code's foreground binary is a bare version
  number (e.g. `2.1.199`), so the naive match would miss it. The GC runs on
  plugin load, while the bar is visible (every ≤30s), and whenever the
  AI status view opens; a failed scan skips GC rather than guessing. A marked
  pane you are currently looking at is kept out of the bar (no need to nag)
  but stays in the AI status view until cleared.

### Bar position note

tmux has a single `status-position`, so the bar renders on a second status line
adjacent to your main status bar. In `@radar-bar auto` mode the notifier records
the exact prior `status` value, raises `status 2`, and restores only the setting
it owns. `pinned` and `off` are available for explicit control. A bar strictly at
the top while the main line stays at the bottom is not possible natively.

## AI supervisor (Codex)

Opt in with `set -g @radar-ai 'on'` (needs the [`codex`](https://github.com/openai/codex)
CLI, logged in, plus `jq`). Then `prefix + A` opens a menu:

| Key | Entry | What it does |
|-----|-------|--------------|
| `a` | **指挥 tmux 布局（自然语言）** | Describe a split/join/move/resize/layout change; Codex proposes a layout-only argv batch, you confirm, and tmux runs it directly. Shell commands and pane input are rejected. |
| `c` | **让当前 pane 继续 / 决定一次** | Reads the current pane (a Claude Code / Codex TUI waiting on you), figures out the right answer, and — after you confirm — sends the keystrokes. |
| `w` | **常驻监控当前 pane 直到完成** | Opens the quick goal field, then a complete launch summary. Safe blocked prompts are handled until that exact goal is done. |
| `W` | **常驻监控 + always-allow** | The same goal-first flow with always-allow preset for safe repeated approvals. |
| `v` | **自定义监控…** | Opens the same flow in advanced mode, exposing every authority, trigger, brain, budget, context, console, and logging field with provenance. |
| `s` / `S` / `l` | **状态 / 停止全部 / 列出 AI pane** | Manage watchers, read the recent decision log, and see which panes are running AI tools (detected via the process tree — reliable even though Claude Code's foreground binary is a bare version number). |

`w`, `W`, and `v` are presets for one native setup reducer, not three watcher
implementations. The goal editor is active as soon as the console opens, so
typing immediately after `w` enters the real goal. CJK editing is rune-aware:
one Backspace removes one character. `Tab` / `Shift-Tab` commit and move between
Goal, Preset, Policy, Autonomy, Advanced, and Start; `Enter` edits/selects;
arrows change enum values; Space toggles booleans. A blank goal becomes the
explicit `推进当前任务直到完成`. `W` starts with always-allow selected. `v` opens
all advanced groups, and every field shows its effective value plus
`default`, `tmux`, `custom`, `runtime`, `preset`, or `profile-managed`
provenance. The immutable reviewed config is the exact JSON sent to the engine.

The visible console adapts without hiding supervision:

| Target size | Console |
|-------------|---------|
| ≥121 columns and ≥24 rows | One full-height right pane, requested width 84 and clamped to 56–112 columns while preserving at least 64 target columns. |
| ≤120 columns or <24 rows | 90% × 85% popup; the target pane is not split. |

The launcher creates exactly one surface and then `exec`s one Go process. It
never launches a heartbeat helper, redraw loop, or timer process.
Bubble Tea performs in-place terminal updates in the alternate screen; a single
in-process 250 ms file poll waits before every attempt and the one-second header
clock does not clear the evidence viewport. Scrolling up pins Timeline at the
current offset and counts new events until `G` resumes follow. The fixed header
always shows Goal, phase, current work, and the next trigger/countdown; the
remaining rows belong to the selected evidence view.

| Key | Console action |
|-----|----------------|
| `1`…`5` | Timeline, Decision, Screen, Config, or Logs |
| `j` / `k`, arrows, `PgUp` / `PgDn` | Scroll without clearing history |
| `g` / `G` | Top / resume bottom-follow |
| `e` | Expand/collapse a grouped Timeline event |
| `p` | Pause/resume supervision |
| `r` | Request one fresh assessment |
| `k` | Keep a completed summary open past auto-close |
| `c` | Open the complete effective configuration view |
| `Enter` | Split: focus the target with one `tmux select-pane`. Popup: request durable detach, then close only after acknowledgement. |
| `q` | Active run: ask for confirmation, then stop. Final report: close immediately. |
| `?` | Contextual controls without hiding the current evidence |

`Timeline` is the append-only lifecycle feed. `Decision` shows structured model
output, observable evidence, risk, exact text/keys, backend metadata, and policy
result, not private chain-of-thought. `Screen` shows a short live tail while the
configured capture can remain larger. `Config` lists all fields and provenance.
`Logs` shows the run directory, available artifacts, recent backend stderr, and
errors. Renderer tests cover `40x18`, `56x24`, `84x40`, and `96x50`; labels
shorten before controls disappear. A popup detach changes the durable owner to
`detached`; simply killing a popup does not detach and causes the watcher plus
its model process group to stop when the heartbeat lease expires.

Native lifecycle hooks are the primary trigger. Approval/input events request a
decision immediately; turn-complete asks whether the exact goal is done;
UserPromptSubmit cancels stale queued approvals and resets idle timing. A stable
semantic projection of the bottom 20 lines is only the fallback when a hook is
absent or unsupported. The `poll`
interval begins after the current decision/action/verification finishes. One
watch owns at most one model process tree, so a slow call cannot create another
call every five seconds; arrivals are durably queued and coalesced first. While
idle or backing off, the Bash watcher waits in-process on its owned FIFO and
deadline: it does not fork `sleep` or `tmux wait-for` children. The only child
a run may own is the currently active model process group.

**Codex is a decision-only brain; the script is the only actor.** Each call uses
`codex exec -s read-only --ephemeral` plus a JSON output schema, ignores the
interactive Codex config and execpolicy rules, omits skill instructions,
disables hooks and tool-bearing features, and runs from a private empty
workspace rather than the target project. The script then checks local types,
policy, safety, current event ID, and the target screen fingerprint before
sending exact keys. Destructive, irreversible, production, credential,
remote-write, or ambiguous actions escalate regardless of always-allow. Invalid
output and backend failures retry with bounded backoff; exact backend failures
and timeout limits remain visible in `Timeline` and `Logs`, and all stop paths
terminate the complete wrapper/Codex process group.

Every run is stored under `~/.local/state/tmux/ai-runs/<run-id>/`. Default
`decision` logging persists config, state, events, structured decisions,
metadata, and backend stderr, but not pane captures or prompts. `full` adds exact
screen and prompt files, which may contain source code, paths, commands, or
secrets. All run files are user-only. The global `ai.log` remains a compact
cross-run index; `ai.sh report latest` prints the final duration, reason, goal,
counts, and log location.

On goal completion the DONE notification is emitted and the native report shows
an explicit close countdown (12 seconds by default). Press `k` to durably keep
it or `q` to close it. Closing the target, closing the visible split owner,
killing an attached popup, pressing Ctrl-C, or stopping the run invalidates the
owner lease; the watcher checks that lease during waits and backend polling and
terminates its complete model process group. Prompt behavior is customizable
through `@radar-ai-prompt-dir` and `@radar-ai-rules` without editing the plugin.

### CLI reference

The stable native command surface is:

```sh
tmux-radar version
tmux-radar supervisor doctor [--json] [--engine-script path]
tmux-radar supervisor setup --target-pane %N --monitor-pane %M \
  --surface split --entry quick|always-allow|advanced
tmux-radar supervisor attach --run <run-id> [--state-root path]
```

`attach` is read-only and never steals an active owner's lease. CLI exits are
stable: `0` normal completion/cancel, `2` usage, `3` preflight or permanent
configuration failure, `4` engine/control failure, and `5` protocol mismatch.
`supervisor doctor --json` resolves the exact Codex binary/model/effort without
spending a model call.

The Phase 1 engine remains directly inspectable and scriptable:

```sh
ai.sh ask [request…]           # arrange tmux from natural language
ai.sh decide [pane] [autonomy] [policy] [goal]
                               # read one pane, act once
ai.sh watch <pane> [goal] [policy] [poll] [autonomy]
                               # resident watcher (policy: '' | always-allow)
ai.sh watch-setup [pane] [quick|advanced] [always-allow]
                               # one-release legacy setup UI
ai.sh emit-event <pane> <kind> <source> <label>
                               # append/signal one sanitized watcher event
ai.sh pause|resume <pane>      # pause or resume without ending the run
ai.sh keep <pane>              # cancel a completed console's auto-close
ai.sh report [run-id|latest]   # final outcome, goal, counts, duration, logs
ai.sh stop <pane|all>          # stop watcher(s)
ai.sh status                   # active watchers + recent decisions
ai.sh list                     # AI panes with ⚠ action / ✓ done / ● watching state
ai.sh cleanup                  # GC watcher files, monitor panes, stale marks
```

`decide` exit codes (what the watch loop keys off): `0` sent · `2` done ·
`3` still working · `4` escalated to you · `5` error · `6` suggest-only/skipped.
The cross-run index remains one TAB-separated line per audit action in
`~/.local/state/tmux/ai.log`: `datetime ⇥ action ⇥ pane ⇥ detail…`. Canonical
run evidence lives in `ai-runs/<run-id>/`.

Need-input internals are inspectable too:

```sh
needinput-notify.sh tick         # prune + agent-liveness GC + bar resync
needinput-notify.sh registry     # registry rows with liveness verdicts
needinput-notify.sh doctor       # full hooks/marks/registry diagnostic
needinput-notify.sh agent-panes  # which panes host a watched agent right now
needinput-notify.sh resolve-pane # which pane THIS process tree belongs to
needinput-notify.sh resolve-cwd [cwd] # which pane owns a Claude hook/job cwd
needinput-notify.sh kimi-hook     # Kimi hook adapter; JSON payload on stdin
needinput-notify.sh agent-event <kind> \
  <session_start|approval|approval_resolved|input_required|user_resumed|turn_complete|interrupt|session_end>
                                 # public normalized adapter; JSON on stdin
needinput-notify.sh mark|clear|clear-all …   # manual mark management
```

### tmux-resurrect / restarts

Watchers and their monitor panes don't survive a tmux server restart (by
design — an unattended auto-approver should not resurrect itself). The plugin
runs `ai.sh cleanup` on every load, which garbage-collects stale watcher state,
orphan monitor panes, and AI-status marks whose pane or agent is gone. If you
use [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), also wire
its post-restore hook so the cleanup runs right after a restore:

```tmux
set -g @resurrect-hook-post-restore-all 'run-shell -b "~/.tmux/plugins/tmux-radar/scripts/ai.sh cleanup >/dev/null 2>&1"'
```

Stale AI-status marks self-heal in general: any mark whose agent TUI has exited
(the pane is back to a plain shell) is dropped automatically — on plugin load,
when the bar renders (≤30s), and whenever the AI status view opens.

## How it works

- Rows are `target ⇥ name ⇥ meta`; fzf uses `--with-nth=2.. --nth=1` to display
  name+meta while searching only the name.
- Preview uses `--preview-window '<pos>,nowrap,follow'`; `follow` tails to the
  bottom so the current state is visible.
- Colors are applied **shell/awk-side after** every tmux round-trip, never
  embedded in a `-F` format — some tmux builds (Linux distros) vis-escape
  control characters in command output, which would render a raw ESC as a
  literal `\033[1;32m`.
- State lives in `~/.local/state/tmux/`:
  - `window-mru` — window ids, most recent last (drives the recent view).
  - `need-input` — one TAB-separated AI-status mark per line:
    `pane ⇥ epoch ⇥ source ⇥ key ⇥ label ⇥ saved_title` (`pane` is `-` for
    background-session marks; `key` is `s:<claude session_id>` or the pane id).
  - `agent-registry` — one live agent session per line:
    `kind ⇥ key ⇥ pid ⇥ pane ⇥ started ⇥ last_event ⇥ state ⇥ cwd ⇥ proc`.
  - `opencode-events` — one ordering watermark/tombstone per OpenCode session:
    `key ⇥ generation ⇥ generation_started_ms ⇥ sequence ⇥ updated`. It rejects
    duplicate, out-of-order, and old-process events after a TUI restart.
  - `ai-watch/` — one small `<pane>.watch` compatibility pointer per live run,
    including watcher PID, run directory, wake channel, and monitor pane IDs.
    While a model call is active, `<pane>.brain.pid` records its PID/process
    group for `stop` and crash GC. Legacy `.timeline`/`.detail` files remain a
    presentation fallback, not canonical history. Idle waits have no waiter or
    timer child; compatibility state records both PIDs as `0`.
  - `ai-runs/<run-id>/` — `config.json` (immutable values + provenance), atomic
    `state.json`, append-only `events.jsonl`, hook `inbox/`, per-call
    `decisions/NNNN.json` + `.meta.json`, `backend/NNNN.stderr`, and
    `final.json`. `monitors` records the overview/detail pane IDs or popup
    ownership before the compatibility pointer is rewritten. `screens/` is
    created only for snapshots/full logging; fallback raw samples are persisted
    only under those explicit modes.
    `prompts/` only for full logging. Default retention is seven days and a run
    referenced by a live `.watch` pointer is never collected.
  - `ai.log` — the AI supervisor's audit log.
- Environment overrides (mainly for scripting/tests): `TMUX_RADAR_STATE_DIR`,
  `TMUX_RADAR_MRU_FILE`, `TMUX_RADAR_NEEDINPUT_FILE`,
  `TMUX_RADAR_NEEDINPUT_COMMANDS`, `TMUX_RADAR_BG_TTL` (bg-mark expiry,
  default 86400s), `TMUX_RADAR_BAR_MAX` (bar chips, default 3),
  `TMUX_RADAR_AI_LOG`, and `TMUX_RADAR_AI_CMD` (test seam for the brain,
  overrides `@radar-ai-cmd`). Legacy `TMUX_SWITCHER_*` names remain accepted.

## Troubleshooting

- **Colors show as literal `\033[1;32m` (Linux)** — fixed in current versions
  (colors no longer round-trip through tmux); update the plugin (`prefix + I`
  or `git -C ~/.tmux/plugins/tmux-radar pull`).
- **A pane stays in the AI status list after I closed the AI TUI** — stale
  marks are GC'd automatically (plugin load / bar render / opening the view).
  Force a pass with `scripts/needinput-notify.sh tick`; see which panes are
  currently detected as agents with `scripts/needinput-notify.sh agent-panes`.
- **An agent pane isn't detected as an AI pane** — detection matches ps argv0
  path components against `@radar-needinput-commands` (`codex claude opencode kimi` by
  default) via the pane's tty and process tree. `pane_current_command` showing
  a version number (`2.1.199`) is normal and does not matter. If you renamed
  the binary, add that name to `@radar-needinput-commands`.
- **Hooks don't fire** — run `scripts/install-hooks.sh status`. It reports
  Claude, Codex, Kimi, and OpenCode coverage separately, including Kimi's seven
  managed events and Codex's legacy notify fallback. Re-run `install`, then
  restart the affected agent sessions because hooks are read at session start.
  A missing native hook remains visible; semantic fallback does not claim native
  coverage. The [agent hook guide](docs/guides/agent-hooks.md) includes payload
  diagnostics and a custom-agent adapter.
- **A watcher seems to launch a new model every poll interval** — update the
  plugin. Calls are serialized now: the idle interval begins only after the
  current call/action verification ends, equal stable projections are
  deduplicated, and queued hooks are coalesced. Inspect
  `ai.sh report latest`, `ai.sh status`, and the run's `events.jsonl`/
  `decisions/` before changing the interval.
- **Where are the monitor logs?** — use `ai.sh report latest`. Default
  `decision` logging keeps `config.json`, `state.json`, `events.jsonl`,
  `final.json`, `decisions/*.json`, `decisions/*.meta.json`, and bounded
  `backend/*.stderr` under `~/.local/state/tmux/ai-runs/<run-id>/`; it
  deliberately omits screen/prompt persistence. Set
  `@radar-ai-logging 'full'` only when you accept that exact prompts and pane
  captures may contain source code, paths, commands, or secrets.
- **The right console leaves too little room** — width is responsively clamped;
  targets with at least 121 columns keep at least 64 columns and receive a
  56–112-column right pane. Targets at 120 columns or below use a popup without
  shrinking the target. `@radar-ai-monitor-pos` affects only the legacy UI.
- **`w` says the native binary is unavailable** — run
  `scripts/build-native.sh` or the explicit verified release installer. Plugin
  startup never builds/downloads silently. `scripts/ensure-native.sh resolve`
  shows the selected local binary.
- **Deleting CJK text in supervisor setup misbehaves** — the native goal editor
  deletes by Unicode character and is active immediately. Verify the launcher
  selected `bin/tmux-radar`, not the explicit legacy rollback.
- **The supervisor consumed CPU after its pane closed** — current native owner
  heartbeats run inside the one Go TUI process, and engine waits are childless
  with bounded lease checks. `ai.sh stop` acknowledges only after final evidence
  exists, the watcher PID is gone, and its generation pointer is removed. Run
  `ps -ef | grep tmux-radar` and `ai.sh cleanup`; no
  `tmux-radar-ai-supervision` shim or `ai-monitor.sh` process is part of the
  primary native path.
- **The AI menu key** — default is capital `A` (`prefix + A`). If an old
  `@radar-ai-key 'a'` is still set globally on a running server, unset it
  (`tmux set -gu @radar-ai-key`) and re-run the plugin file, or reload your
  tmux config.

## License

MIT

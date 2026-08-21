# tmux-radar

**A window-first switcher for busy tmux workspaces.**

Find a named project window first, drill into panes only when needed, and switch
to one exact live destination. tmux-radar has three focused views — Recent,
Agents, and Tree — with a live preview for supporting context.

![views: Recent | Agents | Tree](https://img.shields.io/badge/views-Recent%20%7C%20Agents%20%7C%20Tree-blue)

## Why not `choose-tree`?

tmux's built-in `choose-tree` is good for browsing sessions. tmux-radar is for
getting back to work fast when a workspace is large, active, and full of
long-running agents.

| Problem | tmux-radar gives you |
|---------|----------------------|
| "Where was I just working?" | Complete window-MRU Recent view |
| "Which agent needs me, and what is the fleet doing?" | The Agents board |
| "What is happening in that pane?" | Bottom-anchored live preview |
| "I know its title, command, or path" | Search across visible identity and metadata |
| "Claude/Codex/Kimi finished while I was elsewhere" | Status marks and bar |

## Features

- **Three focused views** — Recent contains every live window in window-MRU
  order, Agents is the one AI surface — unread ACTION/DONE/NOTICE events
  first, then blocked/waiting, then the working set — and Tree browses the
  session/window hierarchy. `Ctrl-e` reveals pane leaves in Recent/Tree.
  Idle agent panes read as free shells and earn no board row or badge.
- **AI state badges everywhere** — Recent and Tree rows carry per-window agent
  badges (`⚠` needs you, `✓` finished unread, `◐` working), so the state of
  your whole fleet is visible in the default view without opening a dedicated
  surface.
- **A live scanner behind the hooks** — hooks are push and miss what they
  never saw: sessions started before hook installation, agents without an
  adapter, and permission prompts approved in place. Every
  `@radar-scan-interval` seconds the scanner classifies each pane hosting a
  watched agent process (ps argv0/argv1 match — node/bun-wrapped CLIs like pi
  included) as `working`, `stalled`, or `blocked` (Codex's own
  `Action Required` title is honored) from visible title/screen change.
  Untracked agent panes are adopted into the registry, stale ACTION marks
  heal after two consecutive working scans, registry rows whose pane lives on
  a foreign tmux server (Claude teammate swarms) are re-homed to paneless,
  and an observed transition into `blocked` or out of `working` synthesizes
  exactly one board event for off-screen panes — hookless sessions still
  reach you.
- **Window-name-first search** — the user-assigned window name is the first
  searchable identity; location, title, command, path, and event state follow.
- **Exact-pane switching** — every selectable row targets one pane. Selection
  is revalidated before switching and fails explicitly if that pane closed.
- **Useful Recent behavior** — newest recorded windows come first, every
  remaining live window follows in canonical order, and stale history cannot
  hide work.
- **Live preview** — the selected pane's content, no wrap, anchored to the
  bottom (current prompt/state visible), with line/page scroll.
- **AI status alerts** — Claude/Codex/Kimi/OpenCode/pi flag their pane for action-required
  prompts and finished-turn notices; a compact chip (`⚠ mira-api`, never a
  full sentence) appears in the existing
  status area while an off-screen mark is fresh,
  the pane's **title flips to a status label** (`⚠` action required, `✓`
  finished, `!` notice), and the pane shows up on the Agents board.
  Only the pane you focus is marked read; sibling agent panes remain unread.
  Marks also clear when you reply — and
  **stale marks self-heal**: a mark whose agent TUI has exited is dropped
  automatically, and any agent mark whose pane is observably working again
  heals after two working scans counted from the mark itself (a freshly
  rendered permission prompt never heals by accident).
- **Background Claude sessions covered** — Claude Code sessions that run outside
  any tmux pane (dashboard / background jobs / cloud) are tracked per
  `session_id` and surface on notification/supervisor surfaces. They are not
  exposed as fake switcher targets. Sessions
  that *do* live in a pane but lost `$TMUX_PANE` (env-scrubbing launchers,
  agent runners) are resolved back to their real pane via the process tree or
  Claude's hook/job cwd.
- **Optional AI supervisor** — `prefix + A`: drive tmux from natural language,
  have Codex answer a waiting Claude/Codex/Kimi prompt for you, or run a resident
  watcher that auto-approves *safe* prompts until a pane's task is done — with
  a read-only brain, an audit log, and escalation for anything risky.

## Requirements

- tmux ≥ 3.2 (uses `display-popup`)
- [`fzf`](https://github.com/junegunn/fzf) ≥ 0.59 (transform actions, `FZF_MATCH_COUNT`, and safe `bell` no-ops)
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

`prefix + Tab` toggles between your two most recently used panes — across
windows and sessions (pane-level MRU is recorded by tmux hooks; see
`@radar-last-key`).

`prefix + C-w` opens the picker. Every view contains only exact live-pane
destinations. The hidden target is the stable tmux pane ID (`%N`). Recent and
Agents keep the current `session:window.pane` location searchable; Tree uses the
visible session group plus aligned window/pane indexes instead of repeating the
full coordinate on every row:

| Key | Action |
|-----|--------|
| type | search visible identity and metadata |
| `ctrl-r` | **Recent**: all live windows, window MRU first; starts on row 2 so `Enter` switches back immediately |
| `ctrl-a` | **Agents**: the one AI surface — unread ACTION/DONE/NOTICE, then BLOCKED/WAITING, then WORKING |
| `ctrl-i` | alias for Agents |
| `ctrl-t` | **Tree**: session → window hierarchy |
| `ctrl-e` | show/hide exact pane leaves in Recent or Tree; no-op in Agents |
| `alt-1` … `alt-9` | switch to that visible result; out-of-range keys stay in the picker |
| `alt-p` | toggle preview |
| `shift-↑` / `shift-↓` | scroll preview by line |
| `PgUp` / `PgDn` | scroll preview by page |
| `ctrl-n` / `ctrl-p` | move selection (fzf default) |
| `Enter` | revalidate the stable pane ID and switch with one tmux client operation |
| `Esc` | cancel without switching |

All views emit exactly three TSV fields and every row carries a real,
stable `%pane_id`. Session rows snapshot the session's current pane; window rows
snapshot that window's active pane; pane and board rows target themselves.
There are no fake header/background/context targets. Paneless background
sessions remain available in notification/supervisor surfaces instead of
becoming nonfunctional picker rows. `all` aliases Tree and `needinput` aliases
Inbox for compatibility. The older `attention` token is accepted silently for
existing scripts but is no longer a documented product view.

Tree deliberately scans as a compact hierarchy rather than a prose report:

```text
▾ Openjobs-data                         8w
  ├─  0 openjobs-data-spark          zsh · ~/project
  ├─  7 tidb_123                  3p · ssh · ~
  └─  8 scripts                      ssh · ~/Falcon
```

Single-pane windows omit the meaningless `1p`; only multi-pane windows show a
compact count. `Ctrl-e` continues the same branch rail into exact pane leaves.

## Configuration

Set these **before** the plugin loads:

| Option | Default | Description |
|--------|---------|-------------|
| `@radar-default-view` | `recent` | Initial view: `recent`, `inbox`, `agents`, or `tree` (`needinput` and `all` remain compatibility aliases). Invalid values fall back to Recent. |
| `@radar-ai-console` | `auto` | Supervisor console surface: `auto` (right split when the target pane is ≥121×24, else popup) or `popup` (always overlay — never takes columns away from the work pane). |
| `@radar-key` | `C-w` | Prefix key that opens the picker. |
| `@radar-last-key` | `Tab` | Prefix key that jumps to the most recently used **other pane**, across windows and sessions (tmux's own `last-pane` is window-local). Press repeatedly to toggle between your two most recent panes. `none` skips the binding. |
| `@radar-popup-width` | `100%` | Popup width. |
| `@radar-popup-height` | `100%` | Popup height. |
| `@radar-preview` | `right:62%` | fzf preview position/size. |
| `@radar-preview-follow` | `on` | Anchor preview to the bottom (tail-style). |
| `@radar-expand-panes` | `off` | Open Recent/Tree with pane leaves already expanded; `Ctrl-e` still toggles them. |
| `@radar-needinput` | `on` | Enable the AI-status system (hooks/bar). |
| `@radar-needinput-commands` | `codex claude opencode kimi pi` | Process identities used for registry/mark garbage collection, the live scanner, and diagnostics. Comma/space/colon separated. |
| `@radar-scan` | `on` | Live agent scanner: classifies panes hosting watched agent processes as working/stalled/blocked, adopts hookless agent panes into the registry, heals stale ACTION marks, and powers the Agents view and the Recent/Tree badges. |
| `@radar-scan-interval` | `10` | Seconds between live scans (minimum `5`). Scans run inside `tick`, which the picker, the bar, and session hooks already trigger; the interval keeps repeat reloads cheap. |
| `@radar-retitle` | `on` | Rename a marked pane's title to a status label (`⚠` action required, `✓` finished, `!` notice), restored on clear. |
| `@radar-claude-bg` | `on` | Also track Claude sessions running outside tmux panes (background/dashboard/cloud). |
| `@radar-bar` | `auto` | `auto` renders chips **inline inside your existing status-right** (`#{E:@radar-chips}` is injected once); `pinned` keeps a permanently reserved line 2; `off` tracks marks only. The status line **count never changes at runtime** — no pane resize, no SIGWINCH flicker. |
| `@radar-bar-ttl` | `60` | Seconds a chip stays on the bar before fading (`0` = until handled). The mark itself persists on the board / the pane title until cleared. |
| `@radar-done-ttl` | `0` | Seconds a finished-turn (DONE) mark is kept for review before expiring (`0` = keep until focused/cleared). |
| `@radar-claude-bg-ignore` | `~/.claude:~/.claude-mem` | Colon-separated path prefixes; background sessions whose cwd starts with one (plugin observers, SDK helpers) are not tracked. |
| `@radar-ai` | `off` | Enable the **AI supervisor** (`prefix + A` menu). Needs the `codex` CLI + `jq`. |
| `@radar-ai-key` | `A` | Prefix key that opens the AI supervisor menu (capital `A` so a stray `prefix + a` can't trigger it). |
| `@radar-ai-model` | `gpt-5.3-codex-spark` | Codex model slug used by the supervisor's read-only decision calls. |
| `@radar-ai-effort` | `high` | Reasoning effort per decision (`minimal`/`low`/`medium`/`high`/`xhigh`). |
| `@radar-ai-profile` | *(none)* | Use a [codex config profile](https://github.com/openai/codex) (`codex exec -p <profile>`) instead of the model/effort options. Supervisor isolation still ignores the base interactive config and disables hooks/tools; the explicitly selected profile supplies the brain settings. |
| `@radar-ai-cmd` | *(none)* | Replace Codex entirely: any shell command that reads the prompt on **stdin** and prints the decision **JSON** on stdout (another CLI, a local model, …). A ready-made [pi](https://github.com/badlogic/pi-mono) adapter ships at `scripts/pi-brain.sh` — see *Using pi as the decision brain* below. |
| `@radar-ai-pi-provider` | *(none)* | Provider name `scripts/pi-brain.sh` passes to `pi --provider` (e.g. `openai-codex`). Empty = pi's own default provider. |
| `@radar-ai-rules` | *(none)* | **Your approval rules**: a file path (contents used) or a literal text block, appended to every decision prompt with top priority — e.g. "auto-approve npm test / file reads; ALWAYS escalate git push, deploys, anything touching prod". Falls back to `~/.config/tmux-radar/rules.md` when that file exists. |
| `@radar-ai-prompt-dir` | *(none)* | Directory that **shadows** `scripts/prompts/` per file (`decide.md`, `control.md`, `*.schema.json`) — customize the default prompts without editing the plugin. |
| `@radar-ai-autonomy` | `confirm` | One-shot `ask`/`decide`: `suggest` (print only), `confirm` (ask first), `auto`. |
| `@radar-ai-watch-autonomy` | `auto-safe` | Resident `watch`: `auto-safe` (auto-send only safe replies, escalate the rest), `suggest`, `auto`. Unattended sends are executor-capped to menu answers regardless of mode: single `1-9`/`y`/`n` text and navigation keys (Enter/arrows/Space/Tab/Escape/BSpace); anything richer escalates. A `persistent` (don't-ask-again) pick is honored only under an `always-allow` policy. |
| `@radar-ai-approval-policy` | `safe-auto` | Per-watch approval policy inherited by quick setup; `W` presets `always-allow`. |
| `@radar-ai-hooks-first` | `on` | Let installed native Claude/Codex/Kimi/OpenCode lifecycle hooks wake the watcher immediately. `off` keeps only manual and semantic stable-screen fallback triggers. |
| `@radar-ai-poll` | `5` | Idle-listen interval in whole seconds (`1`–`3600`). The next interval starts after a model decision/action returns, so slow decisions do not overlap. The one-second floor keeps production waits childless on macOS Bash 3.2. |
| `@radar-ai-stable-screen-threshold` | `1` | Consecutive equal **stable projections** required before no-hook fallback asks the model. Changing spinners, elapsed timers, and footers are removed before comparison. |
| `@radar-ai-fallback-reassess` | `600` | Seconds after which an **unchanged** stable projection is re-assessed anyway (`0` = never). Safety net for prompts whose visible tail collides with an earlier one; delivered keys always invalidate the dedup immediately. |
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
| `@radar-ai-monitor-excerpt-lines` | `16` | Pane-capture lines shown in the monitor detail view. The detail header reports the actual decision budget: `capture_lines` for native events and `fallback_capture_lines` for semantic fallback. |
| `@radar-ai-completion-close-delay` | `12` | Seconds to keep the final summary visible. Press `K` to keep it open or `q` to close now. |
| `@radar-ai-logging` | `decision` | `decision` stores structured decisions/metadata/stderr; `full` also stores exact prompts and pane captures. |
| `@radar-ai-screen-snapshots` | `off` | Persist per-call pane captures without enabling full prompt logging. These files may contain sensitive text. |
| `@radar-ai-retention-days` | `7` | Retain inactive structured run directories for this many days. Live runs are never removed. |

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

## Agents board + alerts (Claude Code / Codex / Kimi / OpenCode / pi)

Agents (`ctrl-a`, `ctrl-i` is a kept alias) is the one AI surface: unread
events first (**ACTION** for permission/input that needs a decision, **DONE**
for a completed turn worth reviewing, **NOTICE** for other explicit events),
then panes the scanner or registry prove are blocked/waiting, then the working
set. Idle agent panes and paneless background sessions never become rows;
background sessions notify through the chip strip instead.

The plugin sets up the tmux side automatically (AI-status strip + exact-pane
clear on focus). To let Claude Code, Codex, Kimi, and OpenCode flag their
pane, install the hooks once:

```sh
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh install     # wire hooks
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh status      # check
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh uninstall   # remove
```

It edits `~/.claude/settings.json` with five lifecycle hooks:
`SessionStart` registers a live session, `Notification` marks input,
`Stop` marks a finished turn, `UserPromptSubmit` clears the handled mark, and
`SessionEnd` removes the live registry row and every automatic mark for that
session, including a preceding finished-turn mark. Native Codex handlers
are merged into `~/.codex/hooks.json`; the managed block in
`~/.codex/config.toml` contains matching trust state plus the wrapped legacy
`notify` fallback. Kimi receives one owned marker block in the active
`config.toml` (`$KIMI_CODE_HOME/config.toml` when set, otherwise
`~/.kimi-code/config.toml`) for `SessionStart`, `PermissionRequest`,
`PermissionResult`, `UserPromptSubmit`, `Stop`, `Interrupt`, and `SessionEnd`.
The installer preserves Kimi's other config and hooks, refuses malformed or
duplicate managed markers, and rolls back all touched configs if a later write
fails. When OpenCode is installed, the installer writes the
dependency-free lifecycle bridge to
`~/.config/opencode/plugins/tmux-radar.js`. One bridge process blocks on a pipe
for the lifetime of each OpenCode TUI; it does not spawn or poll per event.
Permission requests, structured questions, replies, idle completion, errors,
and deletion are ordered by session/generation before changing marks. When pi
is installed, the installer drops a small in-process extension at
`~/.pi/agent/extensions/tmux-radar.ts` (auto-discovered; `/reload` picks it up
in live sessions) bridging `session_start` / interactive `input` / `agent_end`
/ `session_shutdown`. pi exposes no approval-request event, so its permission
waits are covered by the live scanner instead. Existing
user hooks, trust entries, notify chains, and symlinked config paths are
preserved. Restart the affected Claude/Codex/OpenCode sessions after
installation, then review `/hooks` if Codex asks you to trust the handlers.
For Kimi, run `/reload` in the TUI or start a new session. Kimi's event names and TOML
shape follow its [official hooks reference](https://moonshotai.github.io/kimi-code/en/customization/hooks).

### Agents without native hooks

The live scanner covers detection even when no hook ever fires: a pane whose
foreground process matches `@radar-needinput-commands` shows up in the Agents
view (and its window carries a badge) with a working/stalled/blocked verdict
derived from visible change. Claude Code and Codex both publish their task
and state in the pane title, so hookless sessions still read sensibly. What
only hooks provide is the *unread event* itself (board rows, chips, retitles)
— detection is a floor, not a replacement.

For the supervisor, a missing hook does not disable supervision either. After each idle interval,
tmux-radar captures only the bottom
`@radar-ai-fallback-capture-lines` lines (20 by default) and compares adjacent
samples. It projects only lines that remain in order across both samples, which
removes changing spinners, elapsed counters, progress rows, and footers without
matching prompt text. The model is called only when that stable semantic
evidence reaches `@radar-ai-stable-screen-threshold`. Only the exact stable
projection hash is deduplicated: adding, removing, or replacing a stable line
creates a new decision identity. Dedup memory is **invalidated whenever the
watcher acts**: after keys are delivered (or the user resumes/takes over), a
byte-identical prompt that reappears is a *new* decision, not a handled one —
recurring approval prompts therefore keep getting decisions instead of being
silently skipped. As a final safety net, an unchanged projection is re-assessed
after `@radar-ai-fallback-reassess` seconds (default 600, `0` disables). Semantic similarity never authorizes an
automatic send: one immutable normalized fallback capture is supplied to the
model and retained as delivery authority. Immediately before delivery,
tmux-radar captures again and uses a byte-for-byte comparison; any changed byte
cancels the old action. The private file is removed after the decision; normal
cleanup also removes it from a run whose watcher died without running traps.

This is deliberately a fallback, not fake hook coverage:
`install-hooks.sh status` still reports missing hooks, Timeline records
`screen_idle`, and native
events keep their immediate path and larger `@radar-ai-capture-lines` context.
See [Agent hooks and custom adapters](docs/guides/agent-hooks.md) for the
normalized event contract and a copyable adapter.

### How marks are targeted and cleared

- **Interactive TUI in a pane** — the pane comes from the `$TMUX_PANE` that hook
  subprocesses inherit. The mark clears when you focus that exact pane, or
  (Claude) when you submit your next prompt in that session. Focusing one pane
  never consumes unread siblings in the same window.
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
  `SessionEnd` or process-identity GC. They do not appear on the board because
  there is no real tmux pane to select.
- **Stale marks (agent-liveness GC)** — a pane mark is stale in two ways, and
  both self-heal: the **pane died** (dropped on every state change), or the
  pane is alive but the **agent TUI exited** and the shell got reused.
  Native events maintain `agent-registry` rows containing session key, PID,
  pane, state, cwd, and process identity. GC requires both the recorded PID and
  argv identity to match, so PID reuse cannot keep a dead session alive. An
  unresolved PID (`0`) remains only when the pane process scan independently
  finds a configured AI process; otherwise a successful tick removes it.
  Pre-upgrade/unhooked sessions retain the process-tree fallback. Detection
  matches ps **argv0 path components**, never
  `pane_current_command`: Claude Code's foreground binary is a bare version
  number (e.g. `2.1.199`), so the naive match would miss it. The GC runs on
  plugin load, while the bar is visible (every ≤30s), and synchronously
  before the picker first renders or reloads any view. An unavailable process
  scan skips destructive GC rather than guessing, while a notifier transaction
  failure aborts the picker render explicitly. Dead marks are removed without
  killing panes, and their saved titles are restored (empty saved titles fall
  back to window name, then current command). Prefix glyphs alone never imply
  notifier ownership, so user-authored titles are preserved.

### Bar position note

The chip strip is plain option content (`#{E:@radar-chips}`), republished by
the notifier on every state change and instantly redrawn via
`refresh-client -S` — no `#()` job runs on your status line, and the `status`
line **count** is never toggled at runtime (raising/lowering a status line
resizes every pane and SIGWINCHes every full-screen app; older versions did
this and it caused visible jitter). `auto` injects the strip at the left edge
of your existing `status-right`; `pinned` reserves a second status line
permanently so the strip gets a whole row without ever flapping. A bar
strictly at the top while the main line stays at the bottom is not possible
natively. If you previously used `auto`'s raised line, note the first `tick`
after upgrading restores any still-raised `status` to your saved value.

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
one Backspace removes one character. `Tab` / `Shift-Tab` (or `j` / `k` /
`↑` / `↓` outside a text editor) commit and move between
Goal, Preset, Policy, Autonomy, Advanced, and Start; `Enter` edits/selects;
`←` / `→` change enum values; Space toggles booleans. A blank goal becomes the
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
| `K` | Keep a completed summary open past auto-close (`k` always scrolls) |
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
interval begins after the current decision/action/verification finishes. It is
configured in whole seconds because the childless macOS Bash 3.2 waiter has a
one-second wake resolution. One
watch owns at most one model process tree, so a slow call cannot create another
call every five seconds; arrivals are durably queued and coalesced first. While
idle or backing off, the Bash watcher waits in-process on its owned FIFO and
deadline: it does not fork `sleep` or `tmux wait-for` children. The only child
a run may own is the currently active model process group. A model leader that
exits normally is not sufficient evidence: tmux-radar also proves that no
same-group helper remains before accepting its result and deleting ownership.

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
terminate the complete wrapper/Codex process group. The same bounded group
proof runs after normal model-leader exit so detached helpers cannot survive a
successful decision.

Every run is stored under `~/.local/state/tmux/ai-runs/<run-id>/`. Default
`decision` logging persists config, state, events, structured decisions,
metadata, and backend stderr, but not pane captures or prompts. `full` adds exact
screen and prompt files, which may contain source code, paths, commands, or
secrets. With `full` logging or screen snapshots enabled, raw fallback samples
are archived only after a new stable projection launches a model assessment;
unchanged deduped polls and pre-launch cancellations do not create files.
All run files are user-only. The `Logs` view lists at most 512 artifacts and
shows an omission marker for larger runs without interrupting Timeline,
Decision, or Screen updates. The global `ai.log` remains a compact cross-run
index; `ai.sh report latest` prints the final duration, reason, goal, counts,
and log location.

On goal completion the DONE notification is emitted and the native report shows
an explicit close countdown (12 seconds by default). Press `K` to durably keep
it or `q` to close it. Closing the target, closing the visible split owner,
killing an attached popup, pressing Ctrl-C, or stopping the run invalidates the
owner lease; the watcher checks that lease during waits and backend polling and
terminates its complete model process group. Prompt behavior is customizable
through `@radar-ai-prompt-dir` and `@radar-ai-rules` without editing the plugin.

### Using pi as the decision brain

The supervisor's brain is pluggable via `@radar-ai-cmd`. If you run the same
model through the [pi](https://github.com/badlogic/pi-mono) CLI (e.g. a
`openai-codex` provider serving `gpt-5.3-codex-spark`), point the brain at the
bundled adapter:

```tmux
set -g @radar-ai-cmd '~/.tmux/plugins/tmux-radar/scripts/pi-brain.sh'
set -g @radar-ai-pi-provider 'openai-codex'   # omit to use pi's default provider
```

The adapter reuses `@radar-ai-model` for `pi --model` and maps
`@radar-ai-effort` to `pi --thinking`. It runs pi non-interactively with
`--no-tools --no-session` (no file/shell access, nothing persisted), so the
engine remains the only actor exactly as with the Codex backend, including
timeout process-group termination, JSON validation, and retries.

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
ai.sh list                     # compatibility alias that opens the Agents board
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
when the bar renders (≤30s), and before every picker render/reload.

## How it works

- Rows are `target ⇥ search-display ⇥ meta-display`; every target is a stable
  `%pane-id`, including session/window hierarchy rows. Search starts with the
  sanitized user window name; for equivalent contiguous matches, beginning
  position and then producer order break ties before later metadata.
- Preview uses `--preview-window '<pos>,nowrap,follow'`; `follow` tails to the
  bottom so the current state is visible.
- Colors are applied **shell/awk-side after** every tmux round-trip, never
  embedded in a `-F` format — some tmux builds (Linux distros) vis-escape
  control characters in command output, which would render a raw ESC as a
  literal `\033[1;32m`.
- State lives in `~/.local/state/tmux/`:
  - `window-mru` — window ids, most recent last (drives Recent ordering).
  - `pane-mru` — pane ids, most recent last (drives the cross-session
    `prefix + Tab` toggle).
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
    only for newly assessed stable projections under those explicit modes.
    `prompts/` only for full logging. Default retention is seven days and a run
    referenced by a live `.watch` pointer is never collected.
  - `cleanup` also recognizes both current `_watch_loop` owners and native
    `_watch_run <run-id>` owners from older releases. A native owner is reaped
    only when its matching `final.json` proves the run finished and a fresh
    pointer check finds no live owner; the bounded cleanup includes legacy
    `tmux wait-for` children.
  - `ai.log` — the AI supervisor's audit log.
- Environment overrides (mainly for scripting/tests): `TMUX_RADAR_STATE_DIR`,
  `TMUX_RADAR_MRU_FILE`, `TMUX_RADAR_NEEDINPUT_FILE`,
  `TMUX_RADAR_NEEDINPUT_COMMANDS`, `TMUX_RADAR_BG_TTL` (bg-mark expiry,
  default 86400s), `TMUX_RADAR_BAR_MAX` (bar chips, default 3),
  `TMUX_RADAR_AI_LOG`, and `TMUX_RADAR_AI_CMD` (test seam for the brain,
  overrides `@radar-ai-cmd`).

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
- **A hook event seems to have vanished** — run
  `scripts/needinput-notify.sh doctor` and read the `delivery diagnostics`
  section: lock-contended events are spooled to `needinput-spool` and replayed
  by the next tick (never dropped), and every delivery error is recorded with
  a timestamp in `notify-errors.log` in the state dir. Orphaned atomic-write
  temp files (a hook process killed mid-update) are GC'd by `tick`.
- **Hooks don't fire** — run `scripts/install-hooks.sh status`. It reports
  Claude, Codex, Kimi, and OpenCode coverage separately, including Kimi's seven
  managed events and Codex's legacy notify fallback. Re-run `install`, then
  restart the affected Claude/Codex/OpenCode sessions. Kimi can load the active
  `$KIMI_CODE_HOME/config.toml` (or `~/.kimi-code/config.toml`) with `/reload`.
  A missing native hook remains visible; semantic fallback does not claim native
  coverage. The [agent hook guide](docs/guides/agent-hooks.md) includes payload
  diagnostics and a custom-agent adapter.
- **A watcher seems to launch a new model every poll interval** — update the
  plugin. Calls are serialized now: the idle interval begins only after the
  current call/action verification ends, exactly equal stable projections are
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
- **`Run reader: run contains more than 512 artifacts`** — update the plugin.
  Older native consoles treated the bounded `Logs` file-list limit as a fatal
  run error. Current consoles truncate only that presentation list, show an
  omission marker, and keep Timeline/Decision/Screen live.
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

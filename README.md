# tmux-switcher

A full-screen tmux window switcher with **tree / recent / need-input** views, a
live bottom-anchored preview, title-only fuzzy search — plus optional hook-driven
alerts that flag any window where **Claude Code** or **Codex** is waiting on you.

![view: tree | recent | need-input](https://img.shields.io/badge/views-tree%20%7C%20recent%20%7C%20need--input-blue)

## Features

- **One key, three views** — session tree, recent (MRU), and "needs input",
  switchable live inside the popup. Pick which one opens by default.
- **Title-only fuzzy search** — type to match the window name, not the path or
  running command. Results rank by match score as you type, recency order at rest.
- **Smart cursor in recent view** — opens with the cursor on the 2nd entry,
  since row 1 is always the current window (you won't switch back to yourself).
  The current window stays in the list, one `↑` away.
- **Live preview** — the selected window's content, no wrap, anchored to the
  bottom (current prompt/state visible), with line/page scroll.
- **Need-input alerts** — Claude/Codex flag their pane when they want you; a
  **persistent bar** appears on a second status line until you deal with it,
  the pane's **title flips to `⚠ <reason>`** (visible in pane borders, like
  Codex's native "Action Required" titles), and the pane shows up in the
  need-input view. Everything clears when you focus the window or reply — and
  **stale marks self-heal**: a mark whose agent TUI has exited is dropped
  automatically.
- **Background Claude sessions covered** — Claude Code sessions that run outside
  any tmux pane (dashboard / background jobs / cloud) are tracked per
  `session_id` and surface on the bar and in the need-input view too. Sessions
  that *do* live in a pane but lost `$TMUX_PANE` (env-scrubbing launchers,
  agent runners) are resolved back to their real pane via the process tree.
- **AI supervisor (opt-in)** — `prefix + A`: drive tmux from natural language,
  have Codex answer a waiting Claude/Codex prompt for you, or run a resident
  watcher that auto-approves *safe* prompts until a pane's task is done — with
  a read-only brain, an audit log, and escalation for anything risky.

## Requirements

- tmux ≥ 3.2 (uses `display-popup`)
- [`fzf`](https://github.com/junegunn/fzf)
- `jq` (only for the optional Claude/Codex hook installer)

## Install (TPM)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'lr00rl/tmux-switcher'
```

Then `prefix + I` to install. Default binding: `prefix + C-w`.

Manual install:

```sh
git clone https://github.com/lr00rl/tmux-switcher ~/.tmux/plugins/tmux-switcher
run-shell ~/.tmux/plugins/tmux-switcher/tmux-switcher.tmux   # or add to tmux.conf
```

## Usage

`prefix + C-w` opens the picker. Inside:

| Key | Action |
|-----|--------|
| type | fuzzy search **window + pane title** |
| `ctrl-t` | session **tree** view |
| `ctrl-r` | **recent** (MRU) view |
| `ctrl-i` | **need-input** view (all detected AI panes; hook-marked panes float first) |
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
rows are shown). The need-input view is always pane-level so you can jump to the
exact AI TUI pane.

## Configuration

Set these **before** the plugin loads:

| Option | Default | Description |
|--------|---------|-------------|
| `@switcher-default-view` | `tree` | Initial view: `tree`, `recent`, or `needinput`. |
| `@switcher-expand-panes` | `off` | Start with panes expanded (`on`) or collapsed (`off`). Toggle live with `ctrl-e`. |
| `@switcher-key` | `C-w` | Prefix key that opens the picker. |
| `@switcher-popup-width` | `100%` | Popup width. |
| `@switcher-popup-height` | `100%` | Popup height. |
| `@switcher-preview` | `right:62%` | fzf preview position/size. |
| `@switcher-preview-follow` | `on` | Anchor preview to the bottom (tail-style). |
| `@switcher-needinput` | `on` | Enable the need-input system (hooks/bar). |
| `@switcher-needinput-commands` | `codex claude` | Process names the need-input view treats as AI panes. Comma/space/colon separated. |
| `@switcher-retitle` | `on` | Rename a marked pane's title to `⚠ <reason>` (restored on clear). |
| `@switcher-claude-bg` | `on` | Also track Claude sessions running outside tmux panes (background/dashboard/cloud). |
| `@switcher-bar-ttl` | `60` | Seconds a chip stays on the bar before fading (`0` = until handled). The mark itself persists in the need-input view / pane title until cleared. |
| `@switcher-claude-bg-ignore` | `~/.claude:~/.claude-mem` | Colon-separated path prefixes; background sessions whose cwd starts with one (plugin observers, SDK helpers) are not tracked. |
| `@switcher-ai` | `off` | Enable the **AI supervisor** (`prefix + A` menu). Needs the `codex` CLI + `jq`. |
| `@switcher-ai-key` | `A` | Prefix key that opens the AI supervisor menu (capital `A` so a stray `prefix + a` can't trigger it). |
| `@switcher-ai-model` | `gpt-5.3-codex-spark` | Codex model slug the supervisor uses (`-spark` is the fast tier; pair with `effort minimal/low` for the fastest decisions). |
| `@switcher-ai-effort` | `low` | Reasoning effort per decision (`minimal`/`low`/`medium`/`high`/`xhigh`). |
| `@switcher-ai-profile` | *(none)* | Use a [codex config profile](https://github.com/openai/codex) (`codex exec -p <profile>`) instead of the model/effort options — bundle model, effort, etc. in `~/.codex/config.toml`. Safety flags (read-only, ephemeral) still apply. |
| `@switcher-ai-cmd` | *(none)* | Replace Codex entirely: any shell command that reads the prompt on **stdin** and prints the decision **JSON** on stdout (another CLI, a local model, …). |
| `@switcher-ai-rules` | *(none)* | **Your approval rules**: a file path (contents used) or a literal text block, appended to every decision prompt with top priority — e.g. "auto-approve npm test / file reads; ALWAYS escalate git push, deploys, anything touching prod". Falls back to `~/.config/tmux-switcher/rules.md` when that file exists. |
| `@switcher-ai-prompt-dir` | *(none)* | Directory that **shadows** `scripts/prompts/` per file (`decide.md`, `control.md`, `*.schema.json`) — customize the default prompts without editing the plugin. |
| `@switcher-ai-autonomy` | `confirm` | One-shot `ask`/`decide`: `suggest` (print only), `confirm` (ask first), `auto`. |
| `@switcher-ai-watch-autonomy` | `auto-safe` | Resident `watch`: `auto-safe` (auto-send only safe replies, escalate the rest), `suggest`, `auto`. |
| `@switcher-ai-poll` | `5` | Idle-listen interval while watching a pane. The next interval starts after a model decision/action returns, so slow decisions do not overlap. |
| `@switcher-ai-max-calls` | `40` | Cost cap: a watcher pauses after this many model calls. |
| `@switcher-ai-capture-lines` | `120` | Pane lines fed to the model per decision. |
| `@switcher-ai-watch-always-allow` | `off` | While watching, prefer the TUI's "don't ask again / always allow" option for **safe** actions (fewer interruptions, lower safety). Menu entry `W` enables it per-watch. |
| `@switcher-ai-monitor` | `on` | Open companion monitor pane(s) next to a watched pane, showing live countdown/status plus the supervisor's timeline/details (self-closes when the watch ends). |
| `@switcher-ai-monitor-pos` | `top` | Where the monitor pane opens: `top`, `bottom`, or `right`. |
| `@switcher-ai-monitor-size` | `12` | Monitor pane height in lines (`top`/`bottom`). |
| `@switcher-ai-monitor-size-h` | `60` | Monitor pane width in columns (`right`). |
| `@switcher-ai-monitor-layout` | `split` | `split` opens timeline + detail as two monitor panes; `single` keeps one combined pane. |
| `@switcher-ai-monitor-excerpt-lines` | `16` | Pane-capture lines shown in the monitor detail view. The model still receives `@switcher-ai-capture-lines`; this only keeps the UI readable. |

Example:

```tmux
set -g @switcher-default-view 'recent'
set -g @switcher-key 'C-j'
set -g @switcher-preview 'right:55%'
set -g @switcher-needinput-commands 'codex claude'

# AI supervisor (optional)
set -g @switcher-ai 'on'
set -g @switcher-ai-effort 'minimal'      # fastest decisions
set -g @switcher-ai-rules "$HOME/.config/tmux-switcher/rules.md"

set -g @plugin 'lr00rl/tmux-switcher'
```

An example `~/.config/tmux-switcher/rules.md` (loaded automatically when it
exists, even without setting `@switcher-ai-rules`):

```markdown
- Auto-approve: running tests, linters, read-only commands, file reads.
- ALWAYS escalate: git push, anything touching prod/deploys, package publishes.
- If Claude asks which approach to take, prefer the smallest change.
```

## Need-input AI pane view + alerts (Claude Code / Codex)

The `ctrl-i` view scans live tmux panes for configured AI processes, defaulting
to `codex` and `claude`, and lists matching panes directly. Matching is based on
the pane process tree and processes attached to the pane TTY, not on tmux window
or pane names. Rows needing input come first — hook-marked panes and background
session marks merged, newest mark first — followed by every other detected AI
pane for quick review.

The plugin sets up the tmux side automatically (need-input bar status line +
clear on window focus). To let Claude Code and Codex flag their pane, install
the hooks once:

```sh
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh install     # wire hooks
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh status      # check
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh uninstall   # remove
```

It edits `~/.claude/settings.json` (3 hooks: `Notification` + `Stop` mark the
pane, `UserPromptSubmit` clears it) and `~/.codex/config.toml` (Codex native
hooks: `PermissionRequest` marks approval prompts, `Stop` marks a finished turn,
`UserPromptSubmit` clears old marks; legacy `notify` is still wrapped as a
turn-ended fallback). Existing Codex notify chains are **wrapped** (preserved),
not replaced. Restart Claude/Codex sessions afterward, then review/trust the new
Codex hooks with `/hooks` if Codex prompts for hook trust.

> `SessionEnd` is intentionally **not** hooked: it fires the instant a session
> ends — right after `Stop` for short-lived / print-mode / background runs — so
> clearing on it would erase the "finished" mark before you ever see it. The
> mark instead clears when you navigate to the window.

### How marks are targeted and cleared

- **Interactive TUI in a pane** — the pane comes from the `$TMUX_PANE` that hook
  subprocesses inherit. The mark clears when you focus that window, or (Claude)
  when you submit your next prompt in that session.
- **No `$TMUX_PANE`, but still in a pane** — some launchers scrub the
  environment, and agent runners fork sessions whose hooks don't inherit it.
  Before falling back to a paneless mark, the notifier resolves the hook
  process's **controlling tty / parent chain** against live panes — so those
  sessions still get a jumpable pane mark instead of a bare "session id" row.
- **Background Claude sessions** — sessions genuinely outside tmux
  (`$CLAUDE_JOB_DIR` set: the dashboard, background jobs, cloud) get a
  **paneless mark keyed by `session_id`**, labelled `Claude·<project>`. It
  clears when you reply to that session (`UserPromptSubmit`) and expires after
  24h (`TMUX_SWITCHER_BG_TTL`) as a safety net. In the need-input view these
  rows jump to a pane running the `claude` TUI when one exists.
- **Stale marks (agent-liveness GC)** — a pane mark is stale in two ways, and
  both self-heal: the **pane died** (dropped on every state change), or the
  pane is alive but the **agent TUI exited** and the shell got reused. The
  latter is detected by scanning the process tree — a claude/codex mark whose
  pane no longer hosts that agent is dropped (and the pane title restored).
  Detection matches ps **argv0 path components**, never
  `pane_current_command`: Claude Code's foreground binary is a bare version
  number (e.g. `2.1.199`), so the naive match would miss it. The GC runs on
  plugin load, while the bar is visible (every ≤30s), and whenever the
  need-input view opens; a failed scan skips GC rather than guessing. A marked
  pane you are currently looking at is kept out of the bar (no need to nag)
  but stays in the need-input view until cleared.

### Bar position note

tmux has a single `status-position`, so the bar renders on a second status line
adjacent to your main status bar (revealed only while something waits, via
`status 2`). A bar strictly at the top while the main line stays at the bottom
is not possible natively.

## AI supervisor (Codex)

Opt in with `set -g @switcher-ai 'on'` (needs the [`codex`](https://github.com/openai/codex)
CLI, logged in, plus `jq`). Then `prefix + A` opens a menu:

| Key | Entry | What it does |
|-----|-------|--------------|
| `a` | **指挥 tmux（自然语言）** | Type a request ("split this window into build/test/lint"); Codex proposes a batch of tmux commands, you confirm, they run. |
| `c` | **让当前 pane 继续 / 决定一次** | Reads the current pane (a Claude Code / Codex TUI waiting on you), figures out the right answer, and — after you confirm — sends the keystrokes. |
| `w` | **常驻监控当前 pane 直到完成** | Starts a resident watcher: whenever the pane blocks on a prompt, the AI auto-answers the **safe** ones and keeps it moving until the task is done. |
| `W` | **常驻监控 + always-allow** | Same, but for safe approvals the AI prefers the TUI's "don't ask again" option — fewer interruptions, lower safety. |
| `v` | **自定义监控…** | Interactive setup for a watch: a **goal** for the AI to push toward, a **poll interval**, and a per-watch **approval policy** (safe-auto / always-allow / suggest-only). |
| `s` / `S` / `l` | **状态 / 停止全部 / 列出 AI pane** | Manage watchers, read the recent decision log, and see which panes are running AI tools (detected via the process tree — reliable even though Claude Code's foreground binary is a bare version number). |

Free-text prompts (the `a` request, the `v` goal) use **readline**, so CJK
input edits by character — one backspace deletes one 中文 char — and the usual
`←`/`→`/`Ctrl-W` editing keys work.

While a watcher runs, companion monitor pane(s) open next to the watched pane
(top by default; `@switcher-ai-monitor-pos`). The default `split` layout makes
the monitor region two panes: **timeline** on the left (polls, quiet/marked
state, decisions, pauses, completion) and **detail** on the right (countdown,
backend/model command, parsed action, raw decision JSON, backend stderr, a
short tail of the pane excerpt sent to the model, and the recent execution
feed). The monitor keeps a fixed status bar at the top and appends new history
below it instead of repainting the full pane, so tmux copy-mode / scrollback can
review older events without fighting a one-second refresh. Only the pane excerpt
is shortened in the detail view; model context still uses
`@switcher-ai-capture-lines`. It self-closes when the watch ends. Set
`@switcher-ai-monitor-layout 'single'` to keep one combined detail pane. The
**`W`** menu entry starts a watch with
**always-allow**: for safe approvals the AI prefers the TUI's "don't ask again"
so the agent runs with fewer interruptions (convenience over per-action vetting;
off by default).

**Design — Codex is a read-only brain; the script is the only actor.** For every
decision the plugin captures the pane, hands the text to `codex exec -s
read-only --ephemeral` with a JSON `--output-schema`, and gets back a structured
decision (`send` / `wait` / `done` / `escalate` + the exact keys). The **script**
then sends the keystrokes, gated by three safeguards:

- **Autonomy** — `ask`/`decide` default to `confirm` (show the plan, ask first);
  the resident `watch` uses `auto-safe` (auto-send only decisions the model
  marked safe).
- **Escalation** — anything destructive, irreversible, or ambiguous (rm, force
  push, deleting data, credentials, deploys, or "I'm not sure") is **never**
  auto-sent; it re-marks the pane needs-input and pauses so you decide.
- **Audit + caps** — every action is appended to `~/.local/state/tmux/ai.log`,
  and a watcher pauses after `@switcher-ai-max-calls` model calls.

The "skill" the model follows lives in `scripts/prompts/*.md`: how to read each
TUI's prompts, which menu option is the safe "Yes", and the safety rules.
Customize without touching the plugin: `@switcher-ai-prompt-dir` shadows any
prompt file with your own copy, and `@switcher-ai-rules` (or
`~/.config/tmux-switcher/rules.md`) appends **your** approve/escalate rules to
every decision with top priority. A watch's **goal** is also injected, so
"监控到测试全绿" actually steers the decisions. Watchers only consult the model
when a pane goes **quiet** (screen unchanged) or is already flagged needs-input,
so an actively-working agent doesn't burn model calls.

### CLI reference

Everything the menu does is scriptable:

```sh
ai.sh ask [request…]           # arrange tmux from natural language
ai.sh decide [pane] [autonomy] [policy] [goal]
                               # read one pane, act once
ai.sh watch <pane> [goal] [policy] [poll] [autonomy]
                               # resident watcher (policy: '' | always-allow)
ai.sh watch-setup [pane]       # interactive goal/interval/policy setup
ai.sh stop <pane|all>          # stop watcher(s)
ai.sh status                   # active watchers + recent decisions
ai.sh list                     # AI panes with ⚠ waiting / ● watching state
ai.sh cleanup                  # GC watcher files, monitor panes, stale marks
```

`decide` exit codes (what the watch loop keys off): `0` sent · `2` done ·
`3` still working · `4` escalated to you · `5` error · `6` suggest-only/skipped.
Every action is one TAB-separated line in `~/.local/state/tmux/ai.log`:
`datetime ⇥ action ⇥ pane ⇥ detail…`.

Need-input internals are inspectable too:

```sh
needinput-notify.sh tick         # prune + agent-liveness GC + bar resync
needinput-notify.sh agent-panes  # which panes host a watched agent right now
needinput-notify.sh resolve-pane # which pane THIS process tree belongs to
needinput-notify.sh mark|clear|clear-all …   # manual mark management
```

### tmux-resurrect / restarts

Watchers and their monitor panes don't survive a tmux server restart (by
design — an unattended auto-approver should not resurrect itself). The plugin
runs `ai.sh cleanup` on every load, which garbage-collects stale watcher state,
orphan monitor panes, and need-input marks whose pane or agent is gone. If you
use [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), also wire
its post-restore hook so the cleanup runs right after a restore:

```tmux
set -g @resurrect-hook-post-restore-all 'run-shell -b "~/.tmux/plugins/tmux-switcher/scripts/ai.sh cleanup"'
```

Stale "needs input" marks self-heal in general: any mark whose agent TUI has
exited (the pane is back to a plain shell) is dropped automatically — on plugin
load, when the bar renders (≤30s), and whenever the need-input view opens.

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
  - `need-input` — one TAB-separated mark per line:
    `pane ⇥ epoch ⇥ source ⇥ key ⇥ label ⇥ saved_title` (`pane` is `-` for
    background-session marks; `key` is `s:<claude session_id>` or the pane id).
  - `ai-watch/` — one `<pane>.watch` pid/state file per resident watcher, plus
    `<pane>.out` execution feed, `<pane>.timeline` monitor events, and
    `<pane>.detail` last model-call detail.
  - `ai.log` — the AI supervisor's audit log.
- Environment overrides (mainly for scripting/tests): `TMUX_SWITCHER_STATE_DIR`,
  `TMUX_SWITCHER_MRU_FILE`, `TMUX_SWITCHER_NEEDINPUT_FILE`,
  `TMUX_SWITCHER_NEEDINPUT_COMMANDS`, `TMUX_SWITCHER_BG_TTL` (bg-mark expiry,
  default 86400s), `TMUX_SWITCHER_BAR_MAX` (bar chips, default 3),
  `TMUX_SWITCHER_AI_LOG`, and `TMUX_SWITCHER_AI_CMD` (test seam for the brain,
  overrides `@switcher-ai-cmd`).

## Troubleshooting

- **Colors show as literal `\033[1;32m` (Linux)** — fixed in current versions
  (colors no longer round-trip through tmux); update the plugin (`prefix + I`
  or `git -C ~/.tmux/plugins/tmux-switcher pull`).
- **A pane stays in the need-input list after I closed the AI TUI** — stale
  marks are GC'd automatically (plugin load / bar render / opening the view).
  Force a pass with `scripts/needinput-notify.sh tick`; see which panes are
  currently detected as agents with `scripts/needinput-notify.sh agent-panes`.
- **A claude pane isn't detected as an AI pane** — detection matches ps argv0
  path components against `@switcher-needinput-commands` (`codex claude` by
  default) via the pane's tty and process tree. `pane_current_command` showing
  a version number (`2.1.199`) is normal and does not matter. If you renamed
  the binary, add that name to `@switcher-needinput-commands`.
- **Hooks don't fire** — run `scripts/install-hooks.sh status`, and restart the
  Claude/Codex sessions (hooks are read at session start).
- **Deleting CJK text in an AI popup misbehaves** — fixed (prompts use
  readline); update the plugin.
- **The AI menu key** — default is capital `A` (`prefix + A`). If an old
  `@switcher-ai-key 'a'` is still set globally on a running server, unset it
  (`tmux set -gu @switcher-ai-key`) and re-run the plugin file, or reload your
  tmux config.

## License

MIT

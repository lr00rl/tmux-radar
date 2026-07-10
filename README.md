# tmux-radar

**Stop hunting through 50 tmux panes to find the one that's waiting for you.**

You live in tmux. You run several Claude Code / Codex / opencode sessions in
parallel, across sessions, windows, and splits. The expensive question is never
"how do I split a pane" — it's *"which agent is waiting on ME right now?"*
tmux-radar is an AI-aware workspace radar: Mission Control for tmux.

![view: tree | recent | AI status](https://img.shields.io/badge/views-tree%20%7C%20recent%20%7C%20AI--status-blue)

## What it is

A full-screen workspace navigator (`prefix + C-w`) with three live views —
session tree, recent (MRU), and AI status — plus a status-bar alert system fed
by the agents' own lifecycle hooks, so "needs your approval" and "finished —
your turn" reach you wherever you are.

> **The radar tells you what's waiting; it never acts for you.** The AI
> supervisor is a separate, off-by-default opt-in — we don't own your workflow.

## 30 seconds with tmux-radar

<!-- TODO: demo GIF (prefix+C-w → search → C-i → Enter) -->

You're deep in a log window when the bar flickers: `⚠ claude·api-refactor`.
Hit `prefix + C-w` — the radar pops up full-screen. Type 3 letters of any
window title to jump anywhere; or hit `ctrl-i` for the AI status view:
**ACTION** rows sort first, and the bottom-anchored preview shows the *actual
prompt* the agent is blocked on — read the permission request before you even
switch. `Enter` drops you in the exact pane; the mark clears itself. Back to
work.

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

## Why not `choose-tree`?

tmux's built-in `choose-tree` is good for browsing sessions. tmux-radar is for
getting back to work fast when a workspace is large, active, and full of
long-running agents.

| Problem | tmux-radar gives you |
|---------|----------------------|
| "Where was I just working?" | MRU recent view — `choose-tree` has no recency ordering at all |
| "Which pane is waiting for me?" | AI status view — `choose-tree` has zero awareness of agents waiting for input |
| "What is happening in that pane?" | Bottom-anchored live preview — `choose-tree` previews are top-anchored, showing stale scrollback instead of the current prompt |
| "I know the pane title, not the session" | Title-focused fuzzy search |
| "Claude/Codex finished while I was elsewhere" | Status marks and bar |

## Install

Requirements: tmux ≥ 3.2 (uses `display-popup`), [`fzf`](https://github.com/junegunn/fzf),
`jq` (only for the optional agent hook installer). macOS and Linux; the scripts
target bash 3.2 and POSIX awk/sed, so no GNU-only or BSD-only invocations.

TPM — add to `~/.tmux.conf`, then `prefix + I`:

```tmux
set -g @plugin 'lr00rl/tmux-radar'
```

Manual install:

```sh
git clone https://github.com/lr00rl/tmux-radar ~/.tmux/plugins/tmux-radar
run-shell ~/.tmux/plugins/tmux-radar/tmux-radar.tmux   # or add to tmux.conf
```

Default binding: `prefix + C-w`.

## Features

**Find the right pane fast**

- **Workspace command palette** — session tree, recent (MRU), and AI status,
  switchable live inside the popup. Pick which one opens by default.
- **Title-only fuzzy search** — type to match the window name, not the path or
  running command. Results rank by match score as you type, recency order at rest.
- **Smart cursor in recent view** — opens with the cursor on the 2nd entry,
  since row 1 is always the current window (you won't switch back to yourself).
  The current window stays in the list, one `↑` away.
- **Live preview** — the selected window's content, no wrap, anchored to the
  bottom (current prompt/state visible), with line/page scroll.

**Know which agent needs you**

- **AI status alerts** — Claude Code / Codex / opencode flag their pane for
  action-required prompts and finished-turn notices; a **persistent bar**
  appears on a second status line while an off-screen mark is fresh, the
  pane's **title flips to a status label** (`⚠` action required, `✓` finished,
  `!` notice), and the pane shows up in the AI status view. Everything clears
  when you focus the window or reply.
- **Precise session tracking** — agents register themselves through native
  lifecycle hooks into a PID-verified session registry, so closed sessions
  vanish **instantly** on clean exit and within one GC tick after a crash. No
  text-scanning guesswork, no zombie rows. See
  [AI status: precise session tracking](#ai-status-precise-session-tracking).
- **Background Claude sessions covered** — Claude Code sessions that run outside
  any tmux pane (dashboard / background jobs / cloud) are tracked per
  `session_id` and surface on the bar and in the AI status view too.

**Optional**

```
prefix + A  →  AI supervisor (off by default): drive tmux from natural language,
               or let Codex answer a waiting agent prompt / babysit a pane —
               read-only brain, audited actor, escalates anything risky.
```

## AI status: precise session tracking

This is the part `choose-tree` — and pane-title heuristics — can't do.

### The agent-session registry

Every supported agent reports its lifecycle through **native hooks**, not
screen scraping:

- **Claude Code** — 5 hooks: `SessionStart`, `Notification`, `Stop`,
  `UserPromptSubmit`, `SessionEnd`.
- **Codex** — native hooks: `PermissionRequest` marks approval prompts, `Stop`
  marks a finished turn, `UserPromptSubmit` clears old marks; a legacy `notify`
  wrapper remains as a turn-ended fallback.
- **opencode** — a drop-in plugin (no config merge) that forwards
  start / permission / idle / user / error / end events.

The hooks feed an **agent-session registry** (`session_id → PID → pane`): one
row per live agent session, carrying kind, key, PID, pane, timestamps, state
(`working` / `waiting` / `done`), cwd, and the process name matched at
registration. The Claude event mapping:

| Hook | Registry | Marks |
|------|----------|-------|
| `SessionStart` | upsert, state=working | clear stale action marks for the key |
| `Notification` | upsert, state=waiting | mark the pane (action required) |
| `Stop` | upsert, state=done | mark "finished — your turn" |
| `UserPromptSubmit` | upsert, state=working | clear |
| `SessionEnd` | **remove row** | clear action/notice marks; **keep done marks** |

Every event upserts, so sessions started before install/upgrade are adopted on
their first event.

### Liveness: verified, not inferred

- Each registry row records the agent's **PID** (resolved by walking the hook
  process's ancestry — hooks run as children of the agent) and the **process
  name that matched at registration**. GC requires the PID alive **and** its
  current argv still matching that name, so PID reuse can't fake liveness.
- **Clean exit** — `SessionEnd` fires → the row and its action/notice marks are
  gone **instantly**, and the bar resyncs.
- **Crash / `kill -9`** — the next GC tick (popup open, `ctrl-i`, bar
  self-heal, ≤30s) sees the dead PID and drops the row and its action/notice
  marks.
- **"Finished — your turn" survives session end by design.** `claude -p` and
  short-lived runs fire `Stop` then `SessionEnd` back-to-back; the done notice
  must outlive the session so you actually see it. What must *not* survive is a
  "needs your permission" mark for a session that can no longer receive input —
  those die with their session.
- Marks with no registry entry (pre-upgrade sessions, unhooked agents) fall
  back to the existing pane process-tree scan GC.

### Installing the hooks

```sh
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh install     # wire hooks
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh status      # check
~/.tmux/plugins/tmux-radar/scripts/install-hooks.sh uninstall   # remove
```

It edits `~/.claude/settings.json` (the 5 Claude hooks above),
`~/.codex/config.toml` (existing Codex notify chains are **wrapped**, preserved,
not replaced), and drops the opencode plugin at
`~/.config/opencode/plugins/tmux-radar.js` — no opencode config merge needed.
Restart agent sessions afterward (hooks are read at session start), then
review/trust the new Codex hooks with `/hooks` if Codex prompts for hook trust.

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
  clears when you reply to that session (`UserPromptSubmit`) or when its
  registry row dies (PID liveness — paneless marks are no longer immortal),
  with a 24h TTL (`TMUX_RADAR_BG_TTL`) as the last-resort safety net. In the
  AI status view these rows are non-jumpable status rows, because there is no
  real tmux pane to select.
- **Stale marks** — the registry is authoritative: a mark keyed
  `s:<session_id>` lives exactly as long as its registry row is alive. For
  unhooked agents, the fallback is the pane process-tree scan: a claude/codex
  mark whose pane no longer hosts that agent is dropped (and the pane title
  restored). Detection matches ps **argv0 path components**, never
  `pane_current_command`: Claude Code's foreground binary is a bare version
  number (e.g. `2.1.199`), so the naive match would miss it. The GC runs on
  plugin load, while the bar is visible (every ≤30s), and whenever the AI
  status view opens; a failed scan skips GC rather than guessing. A marked
  pane you are currently looking at is kept out of the bar (no need to nag)
  but stays in the AI status view until cleared.

### `doctor`: why is this row (not) showing?

```sh
~/.tmux/plugins/tmux-radar/scripts/needinput-notify.sh doctor
```

One command for the whole diagnosis: state dir, hook install status, registry
rows with per-row **liveness verdicts**, marks with their level and the reason
each is being kept, and the pane-agent scan result. When a row surprises you —
in either direction — start here.

### The alert bar and your status line

tmux has a single `status-position`, so the bar renders on a second status line
adjacent to your main status bar. Changing the status line *count* resizes
every pane (tmux sends SIGWINCH), which some setups find disruptive —
`@radar-bar` picks the trade-off:

| Value | Behavior |
|-------|----------|
| `auto` (default) | Toggle `status 2` while a mark is fresh, then restore your **exact prior** status value (never hardcodes "on"). |
| `pinned` | Never change the status line count — you keep `set -g status 2` yourself; the bar only writes content into the second line. No resizes, ever. |
| `off` | Never raise the bar. Marks are still tracked (AI status view, pane titles). |

## Optional: the AI supervisor

```
Off by default. The radar tells you what's waiting; it never acts for you.
The supervisor is the separate, explicit opt-in for when you WANT an actor.
```

Opt in with `set -g @radar-ai 'on'` (needs the
[`codex`](https://github.com/openai/codex) CLI, logged in, plus `jq`). Then
`prefix + A` opens a menu:

| Key | Entry | What it does |
|-----|-------|--------------|
| `a` | **指挥 tmux（自然语言）** — command tmux in natural language | Type a request ("split this window into build/test/lint"); Codex proposes a batch of tmux commands, you confirm, they run. |
| `c` | **让当前 pane 继续 / 决定一次** — unblock this pane once | Reads the current pane (a Claude Code / Codex TUI waiting on you), figures out the right answer, and — after you confirm — sends the keystrokes. |
| `w` | **常驻监控当前 pane 直到完成** — watch this pane until done | Starts a resident watcher: whenever the pane blocks on a prompt, the AI auto-answers the **safe** ones and keeps it moving until the task is done. |
| `W` | **常驻监控 + always-allow** — watch with always-allow | Same, but for safe approvals the AI prefers the TUI's "don't ask again" option — fewer interruptions, lower safety. |
| `v` | **自定义监控…** — custom watch setup | Interactive setup for a watch: a **goal** for the AI to push toward, a **poll interval**, and a per-watch **approval policy** (safe-auto / always-allow / suggest-only). |
| `s` / `S` / `l` | **状态 / 停止全部 / 列出 AI pane** — status / stop all / list AI panes | Manage watchers, read the recent decision log, and see which panes are running AI tools (detected via the process tree — reliable even though Claude Code's foreground binary is a bare version number). |

Free-text prompts (the `a` request, the `v` goal) use **readline**, so CJK
input edits by character — one backspace deletes one 中文 char — and the usual
`←`/`→`/`Ctrl-W` editing keys work.

While a watcher runs, companion monitor pane(s) open next to the watched pane
(top by default; `@radar-ai-monitor-pos`). The default `split` layout is two
panes: **timeline** on the left (polls, quiet/marked state, decisions, pauses,
completion) and **detail** on the right (countdown, backend/model command,
parsed action, raw decision JSON, backend stderr, a short tail of the pane
excerpt sent to the model, and the recent execution feed). The monitor keeps a
fixed status bar at the top and appends history below it instead of repainting,
so copy-mode / scrollback review doesn't fight a one-second refresh. It
self-closes when the watch ends. `@radar-ai-monitor-layout 'single'` keeps one
combined pane. Watchers only consult the model when a pane goes **quiet**
(screen unchanged) or is already flagged needs-input, so an actively-working
agent doesn't burn model calls.

**Design — Codex is a read-only brain; the script is the only actor.** For every
decision the plugin captures the pane, hands the text to `codex exec -s
read-only --ephemeral` with a JSON `--output-schema`, and gets back a structured
decision (`send` / `wait` / `done` / `escalate` + the exact keys). The **script**
then sends the keystrokes, gated by these safeguards:

- **Autonomy** — `ask`/`decide` default to `confirm` (show the plan, ask first);
  the resident `watch` uses `auto-safe` (auto-send only decisions the model
  marked safe).
- **Escalation** — anything destructive, irreversible, or ambiguous (rm, force
  push, deleting data, credentials, deploys, or "I'm not sure") is **never**
  auto-sent; it re-marks the pane needs-input and pauses so you decide.
- **Copy-mode guard** — the supervisor never sends keys into a pane that is in
  copy-mode (you're probably reading scrollback); it defers to the next poll
  instead.
- **Screen re-verification** — the pane's screen hash is re-checked immediately
  before sending; if the content changed since the decision was made, the send
  is aborted and re-decided.
- **Arrangement allowlist** — tmux commands proposed by `ask` are restricted to
  an allowlist (split / join / swap / move / resize / layout / break / new /
  rename only); anything else — `send-keys`, `switch-client`, `kill-*`, `set`,
  `run-shell` — is rejected, not executed. Lines containing `;` are rejected
  outright: `tmux source-file` treats it as a command separator, so a chained
  `split-window -d ; run-shell …` would otherwise slip past a first-word check.
  Note this bounds the blast radius to what you could type yourself; the allowed
  verbs still take a shell-command argument (`new-window "cmd"`), so it is a
  guardrail, not a sandbox — keep `@radar-ai-autonomy` at `confirm` if that
  distinction matters to you.
- **Fail-closed safety** — a decision whose safety field is missing or invalid
  is treated as unsafe and escalated, never auto-sent.
- **Audit + caps** — every action is appended to `~/.local/state/tmux/ai.log`,
  and a watcher pauses after `@radar-ai-max-calls` model calls.

The "skill" the model follows lives in `scripts/prompts/*.md`: how to read each
TUI's prompts, which menu option is the safe "Yes", and the safety rules.
Customize without touching the plugin: `@radar-ai-prompt-dir` shadows any
prompt file with your own copy, and `@radar-ai-rules` (or
`~/.config/tmux-radar/rules.md`) appends **your** approve/escalate rules to
every decision with top priority. A watch's **goal** is also injected, so
"监控到测试全绿" actually steers the decisions.

An example `~/.config/tmux-radar/rules.md` (loaded automatically when it
exists, even without setting `@radar-ai-rules`):

```markdown
- Auto-approve: running tests, linters, read-only commands, file reads.
- ALWAYS escalate: git push, anything touching prod/deploys, package publishes.
- If Claude asks which approach to take, prefer the smallest change.
```

### Supervisor options

Set these **before** the plugin loads:

| Option | Default | Description |
|--------|---------|-------------|
| `@radar-ai` | `off` | Enable the **AI supervisor** (`prefix + A` menu). Needs the `codex` CLI + `jq`. |
| `@radar-ai-key` | `A` | Prefix key that opens the AI supervisor menu (capital `A` so a stray `prefix + a` can't trigger it). |
| `@radar-ai-model` | `gpt-5.3-codex-spark` | Codex model slug the supervisor uses (`-spark` is the fast tier; pair with `effort minimal/low` for the fastest decisions). |
| `@radar-ai-effort` | `low` | Reasoning effort per decision (`minimal`/`low`/`medium`/`high`/`xhigh`). |
| `@radar-ai-profile` | *(none)* | Use a [codex config profile](https://github.com/openai/codex) (`codex exec -p <profile>`) instead of the model/effort options — bundle model, effort, etc. in `~/.codex/config.toml`. Safety flags (read-only, ephemeral) still apply. |
| `@radar-ai-cmd` | *(none)* | Replace Codex entirely: any shell command that reads the prompt on **stdin** and prints the decision **JSON** on stdout (another CLI, a local model, …). |
| `@radar-ai-rules` | *(none)* | **Your approval rules**: a file path (contents used) or a literal text block, appended to every decision prompt with top priority — e.g. "auto-approve npm test / file reads; ALWAYS escalate git push, deploys, anything touching prod". Falls back to `~/.config/tmux-radar/rules.md` when that file exists. |
| `@radar-ai-prompt-dir` | *(none)* | Directory that **shadows** `scripts/prompts/` per file (`decide.md`, `control.md`, `*.schema.json`) — customize the default prompts without editing the plugin. |
| `@radar-ai-autonomy` | `confirm` | One-shot `ask`/`decide`: `suggest` (print only), `confirm` (ask first), `auto`. |
| `@radar-ai-watch-autonomy` | `auto-safe` | Resident `watch`: `auto-safe` (auto-send only safe replies, escalate the rest), `suggest`, `auto`. |
| `@radar-ai-poll` | `5` | Idle-listen interval while watching a pane. The next interval starts after a model decision/action returns, so slow decisions do not overlap. |
| `@radar-ai-max-calls` | `40` | Cost cap: a watcher pauses after this many model calls. |
| `@radar-ai-capture-lines` | `120` | Pane lines fed to the model per decision. |
| `@radar-ai-watch-always-allow` | `off` | While watching, prefer the TUI's "don't ask again / always allow" option for **safe** actions (fewer interruptions, lower safety). Menu entry `W` enables it per-watch. |
| `@radar-ai-monitor` | `on` | Open companion monitor pane(s) next to a watched pane, showing live countdown/status plus the supervisor's timeline/details (self-closes when the watch ends). |
| `@radar-ai-monitor-pos` | `top` | Where the monitor pane opens: `top`, `bottom`, or `right`. |
| `@radar-ai-monitor-size` | `12` | Monitor pane height in lines (`top`/`bottom`). |
| `@radar-ai-monitor-size-h` | `60` | Monitor pane width in columns (`right`). |
| `@radar-ai-monitor-layout` | `split` | `split` opens timeline + detail as two monitor panes; `single` keeps one combined pane. |
| `@radar-ai-monitor-excerpt-lines` | `16` | Pane-capture lines shown in the monitor detail view. The model still receives `@radar-ai-capture-lines`; this only keeps the UI readable. |

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
ai.sh list                     # AI panes with ⚠ action / ✓ done / ● watching state
ai.sh cleanup                  # GC watcher files, monitor panes, stale marks
```

`decide` exit codes (what the watch loop keys off): `0` sent · `2` done ·
`3` still working · `4` escalated to you · `5` error · `6` suggest-only/skipped.
Every action is one TAB-separated line in `~/.local/state/tmux/ai.log`:
`datetime ⇥ action ⇥ pane ⇥ detail…`.

Need-input / registry internals are inspectable too:

```sh
needinput-notify.sh doctor       # full diagnostic: registry + marks + verdicts
needinput-notify.sh registry     # dump the agent registry with liveness verdicts
needinput-notify.sh tick         # prune + registry/agent-liveness GC + bar resync
needinput-notify.sh agent-panes  # which panes host a watched agent right now
needinput-notify.sh resolve-pane # which pane THIS process tree belongs to
needinput-notify.sh resolve-cwd [cwd] # which pane owns a Claude hook/job cwd
needinput-notify.sh mark|clear|clear-all …   # manual mark management

# lifecycle entry points (normally called by hooks, not by hand)
needinput-notify.sh claude-register   # SessionStart (JSON on stdin)
needinput-notify.sh claude-end        # SessionEnd (JSON on stdin)
needinput-notify.sh opencode-hook     # opencode plugin events (JSON on stdin)
needinput-notify.sh agent-register <kind> <key> <pid> <pane> [cwd]
needinput-notify.sh agent-end <kind> <key>   # generic API for third-party agents
```

`agent-register` / `agent-end` let any third-party agent join the registry —
same liveness guarantees, no plugin changes.

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
| `@radar-needinput` | `on` | Enable the AI-status system (hooks/bar/registry). |
| `@radar-needinput-commands` | `codex claude opencode` | Process names the AI status view treats as AI panes. Comma/space/colon separated. |
| `@radar-retitle` | `on` | Rename a marked pane's title to a status label (`⚠` action required, `✓` finished, `!` notice), restored on clear. |
| `@radar-claude-bg` | `on` | Also track Claude sessions running outside tmux panes (background/dashboard/cloud). |
| `@radar-bar` | `auto` | Status-line strategy for the alert bar: `auto` (toggle `status 2`, restore your exact prior value), `pinned` (never change the line count — you keep `status 2` yourself), `off` (never raise the bar; marks still tracked). See [the bar section](#the-alert-bar-and-your-status-line). |
| `@radar-bar-ttl` | `60` | Seconds a chip stays on the bar before fading (`0` = until handled). The mark itself persists in the AI status view / pane title until cleared. |
| `@radar-claude-bg-ignore` | `~/.claude:~/.claude-mem` | Colon-separated path prefixes; background sessions whose cwd starts with one (plugin observers, SDK helpers) are not tracked. |

AI supervisor options (`@radar-ai-*`) live in
[Supervisor options](#supervisor-options).

Legacy `@switcher-*` options are still honored as fallbacks, but new
configuration should use `@radar-*`.

Example:

```tmux
set -g @radar-default-view 'recent'
set -g @radar-key 'C-j'
set -g @radar-preview 'right:55%'
set -g @radar-needinput-commands 'codex claude opencode'

# AI supervisor (optional)
set -g @radar-ai 'on'
set -g @radar-ai-effort 'minimal'      # fastest decisions
set -g @radar-ai-rules "$HOME/.config/tmux-radar/rules.md"

set -g @plugin 'lr00rl/tmux-radar'
```

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
  - `agent-registry` — one TAB-separated row per live agent session:
    `kind ⇥ key ⇥ pid ⇥ pane ⇥ started ⇥ last_event ⇥ state ⇥ cwd ⇥ proc`.
    `key` is `s:<session_id>` for Claude, `oc:<pane>` for opencode (its plugin
    lives in the TUI process, so the pane is stable across every event while
    the session id only rides on some of them), `p:<pid>` as a last resort.
    `proc` is the argv basename matched at registration: GC requires the pid to
    be alive **and** still running that command, so a reused pid can't fake
    liveness. Written atomically (mktemp + mv) under the same lock as
    `need-input` (an mkdir lock carrying its owner's pid, so a crashed hook's
    lock is reaped rather than stalling the next one); readers need no lock.
  - `ai-watch/` — one `<pane>.watch` pid/state file per resident watcher, plus
    `<pane>.out` execution feed, `<pane>.timeline` monitor events, and
    `<pane>.detail` last model-call detail.
  - `ai.log` — the AI supervisor's audit log.
- Environment overrides (mainly for scripting/tests): `TMUX_RADAR_STATE_DIR`,
  `TMUX_RADAR_MRU_FILE`, `TMUX_RADAR_NEEDINPUT_FILE`,
  `TMUX_RADAR_REGISTRY_FILE`, `TMUX_RADAR_NEEDINPUT_COMMANDS`,
  `TMUX_RADAR_BG_TTL` (bg-mark expiry, default 86400s), `TMUX_RADAR_BAR_MAX`
  (bar chips, default 3), `TMUX_RADAR_AI_LOG`, and `TMUX_RADAR_AI_CMD` (test
  seam for the brain, overrides `@radar-ai-cmd`). Legacy `TMUX_SWITCHER_*`
  names remain accepted.

### Tests

Both suites run against a throwaway tmux server (`-L radartest` / `-L radarreg`)
and an isolated `TMUX_RADAR_STATE_DIR`, so they never touch your live session:

```bash
bash tests/test-registry.sh   # registry lifecycle, crash GC, pid-reuse defence,
                              # SessionEnd semantics, opencode events, bar restore
bash tests/test-safety.sh     # supervisor guardrails: ask allowlist + ';' chains,
                              # cleanup pane-id safety, mark-GC evidence rules, locking
bash tests/test-install.sh    # hook install/uninstall round-trip, idempotency,
                              # symlinked configs, GNU/BSD sed portability
```

`test-install.sh` runs the whole installer against throwaway config dirs with a
`sed` shim on `PATH` that **fails on any `-i`**. GNU sed reads `sed -i '' …` as
`-i` plus an empty script, so a BSD-only in-place edit breaks a Linux install —
the shim catches that on macOS, without needing a Linux box. It also asserts
that a symlinked `settings.json` / `config.toml` (dotfile repos) stays a symlink
and that an existing Codex `notify` chain is wrapped, not replaced.

## Troubleshooting

- **Colors show as literal `\033[1;32m` (Linux)** — fixed in current versions
  (colors no longer round-trip through tmux); update the plugin (`prefix + I`
  or `git -C ~/.tmux/plugins/tmux-radar pull`).
- **A pane stays in the AI status list after I closed the AI TUI** — the root
  cause (inferred liveness) is fixed: sessions now register in a PID-verified
  registry, `SessionEnd` removes them instantly, and crashes are GC'd within
  one tick. If a stale row still appears, run
  `scripts/needinput-notify.sh doctor` first — it prints every registry row
  and mark with the exact reason it is (or isn't) showing. Force a GC pass
  with `scripts/needinput-notify.sh tick`. Marks from unhooked agents fall
  back to the process-tree scan; check it with
  `scripts/needinput-notify.sh agent-panes`.
- **A claude pane isn't detected as an AI pane** — detection matches ps argv0
  path components against `@radar-needinput-commands` (`codex claude opencode`
  by default) via the pane's tty and process tree. `pane_current_command`
  showing a version number (`2.1.199`) is normal and does not matter. If you
  renamed the binary, add that name to `@radar-needinput-commands`.
- **opencode events don't show up** — the opencode plugin no-ops when the
  session has no `$TMUX_PANE` (e.g. `opencode attach` to a server started
  outside tmux). Run opencode directly inside a tmux pane, and check the
  plugin is present at `~/.config/opencode/plugins/tmux-radar.js`
  (`install-hooks.sh status`).
- **Hooks don't fire** — run `scripts/install-hooks.sh status`, and restart the
  agent sessions (hooks are read at session start). `needinput-notify.sh
  doctor` also reports hook install status.
- **Deleting CJK text in an AI popup misbehaves** — fixed (prompts use
  readline); update the plugin.
- **The AI menu key** — default is capital `A` (`prefix + A`). If an old
  `@radar-ai-key 'a'` is still set globally on a running server, unset it
  (`tmux set -gu @radar-ai-key`) and re-run the plugin file, or reload your
  tmux config.

## License

MIT

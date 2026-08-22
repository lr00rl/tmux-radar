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
  `session_id` and surface on notification surfaces. They are not
  exposed as fake switcher targets. Sessions
  that *do* live in a pane but lost `$TMUX_PANE` (env-scrubbing launchers,
  agent runners) are resolved back to their real pane via the process tree or
  Claude's hook/job cwd.

## Requirements

- tmux ≥ 3.2 (uses `display-popup`)
- [`fzf`](https://github.com/junegunn/fzf) ≥ 0.59 (transform actions, `FZF_MATCH_COUNT`, and safe `bell` no-ops)
- `jq` (AI-status hook installation)
- macOS or Linux; hook installation avoids platform-specific `sed -i` behavior
  and preserves symlinked dotfile configs.
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

The picker and AI-status notifications are shell-only; nothing builds, downloads, or compiles.

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
sessions remain available in notification surfaces instead of
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

Example:

```tmux
set -g @radar-default-view 'recent'
set -g @radar-key 'C-j'
set -g @radar-preview 'right:55%'
set -g @radar-needinput-commands 'codex claude opencode kimi pi'

set -g @plugin 'lr00rl/tmux-radar'
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

An observed transition on an off-screen pane (into blocked, or from
working into stalled) also synthesizes exactly one board event, so hookless
sessions still reach the Inbox-equivalent surface once per real change.
`install-hooks.sh status` still reports missing hooks, and
[Agent hooks and custom adapters](docs/guides/agent-hooks.md) documents the
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

### CLI reference

The picker and the notifier are the stable surface:

```sh
switcher.sh menu [recent|agents|tree]   # the picker (inbox/needinput are kept aliases of agents)
switcher.sh last-pane                   # cross-session pane-MRU toggle
needinput-notify.sh mark <pane|-> <source> <label> [key]
needinput-notify.sh clear <target>      # clear marks for a pane/window/session target
needinput-notify.sh tick                # GC + live scan + bar republish
needinput-notify.sh doctor              # why-is-this-row-here diagnostics
needinput-notify.sh agent-event <kind> <event>   # normalized lifecycle event API for other agents
install-hooks.sh install|status|uninstall
```

### tmux-resurrect / restarts

The plugin runs a notifier `tick` on every load, which garbage-collects stale
AI-status marks (dead panes, exited agents) and refreshes the live scan. If you
use [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect), wire its
post-restore hook so the same cleanup runs right after a restore:

```tmux
set -g @resurrect-hook-post-restore-all 'run-shell -b "~/.tmux/plugins/tmux-radar/scripts/needinput-notify.sh tick >/dev/null 2>&1"'
```

Stale AI-status marks also self-heal continuously: a mark whose agent TUI has
exited is dropped on plugin load, while the bar renders, and before every
picker render, and a mark whose pane is observably working again heals within
two live scans.

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
  - `ai-live` — one live scanner row per agent pane: `pane ⇥ kind ⇥ state ⇥ title ⇥ epoch`.
- Environment overrides (mainly for scripting/tests): `TMUX_RADAR_STATE_DIR`,
  `TMUX_RADAR_MRU_FILE`, `TMUX_RADAR_NEEDINPUT_FILE`,
  `TMUX_RADAR_NEEDINPUT_COMMANDS`, `TMUX_RADAR_BG_TTL` (bg-mark expiry,
  default 86400s), `TMUX_RADAR_BAR_MAX` (bar chips, default 3),
  and `TMUX_RADAR_LIVE_FILE`.

## Troubleshooting

- **Colors show as literal `\033[1;32m` (Linux)** — fixed in current versions
  (colors no longer round-trip through tmux); update the plugin (`prefix + I`
  or `git -C ~/.tmux/plugins/tmux-radar pull`).
- **A pane stays in the AI status list after I closed the AI TUI** — stale
  marks are GC'd automatically (plugin load / bar render / opening the view).
  Force a pass with `scripts/needinput-notify.sh tick`; see which panes are
  currently detected as agents with `scripts/needinput-notify.sh agent-panes`.
- **An agent pane isn't detected as an AI pane** — detection matches ps argv0
  path components against `@radar-needinput-commands` (`codex claude opencode kimi pi` by
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
## License

MIT

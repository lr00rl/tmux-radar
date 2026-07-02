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
  need-input view. Everything clears when you focus the window or reply.
- **Background Claude sessions covered** — Claude Code sessions that run outside
  any tmux pane (dashboard / background jobs / cloud) are tracked per
  `session_id` and surface on the bar and in the need-input view too.

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

Example:

```tmux
set -g @switcher-default-view 'recent'
set -g @switcher-key 'C-j'
set -g @switcher-preview 'right:55%'
set -g @switcher-needinput-commands 'codex claude'
set -g @plugin 'lr00rl/tmux-switcher'
```

## Need-input AI pane view + alerts (Claude Code / Codex)

The `ctrl-i` view scans live tmux panes for configured AI processes, defaulting
to `codex` and `claude`, and lists matching panes directly. Matching is based on
the pane process tree and processes attached to the pane TTY, not on tmux window
or pane names. Hook-marked panes are shown first and annotated with the hook
message; unmarked AI panes remain visible for quick review.

The plugin sets up the tmux side automatically (need-input bar status line +
clear on window focus). To let Claude Code and Codex flag their pane, install
the hooks once:

```sh
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh install     # wire hooks
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh status      # check
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh uninstall   # remove
```

It edits `~/.claude/settings.json` (3 hooks: `Notification` + `Stop` mark the
pane, `UserPromptSubmit` clears it) and `~/.codex/config.toml` (`notify`),
idempotently and with timestamped backups. An existing Codex `notify` chain is
**wrapped** (preserved), not replaced. Restart Claude/Codex sessions afterward.

> `SessionEnd` is intentionally **not** hooked: it fires the instant a session
> ends — right after `Stop` for short-lived / print-mode / background runs — so
> clearing on it would erase the "finished" mark before you ever see it. The
> mark instead clears when you navigate to the window.

### How marks are targeted and cleared

- **Interactive TUI in a pane** — the pane comes from the `$TMUX_PANE` that hook
  subprocesses inherit. The mark clears when you focus that window, or (Claude)
  when you submit your next prompt in that session.
- **Background Claude sessions** — Claude Code sessions that don't live in a
  tmux pane (`$TMUX_PANE` unset, or `$CLAUDE_JOB_DIR` set: the dashboard, `&`
  background jobs, cloud sessions) get a **paneless mark keyed by
  `session_id`**, labelled `Claude·<project>`. It clears when you reply to that
  session (`UserPromptSubmit`), and expires after 24h
  (`TMUX_SWITCHER_BG_TTL`) as a safety net. In the need-input view these rows
  jump to a pane running the `claude` TUI when one exists.
- **Stale marks** — marks whose pane has died are garbage-collected on every
  state change; a marked pane you are currently looking at is kept out of the
  bar (no need to nag) but stays in the need-input view until cleared.

### Bar position note

tmux has a single `status-position`, so the bar renders on a second status line
adjacent to your main status bar (revealed only while something waits, via
`status 2`). A bar strictly at the top while the main line stays at the bottom
is not possible natively.

## How it works

- Rows are `target ⇥ name ⇥ meta`; fzf uses `--with-nth=2.. --nth=1` to display
  name+meta while searching only the name.
- Preview uses `--preview-window '<pos>,nowrap,follow'`; `follow` tails to the
  bottom so the current state is visible.
- State lives in `~/.local/state/tmux/` (`window-mru`, `need-input`). Each
  need-input mark is one TAB-separated line:
  `pane ⇥ epoch ⇥ source ⇥ key ⇥ label ⇥ saved_title` (`pane` is `-` for
  background-session marks; `key` is `s:<claude session_id>` or the pane id).

## License

MIT

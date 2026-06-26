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
  transient toast appears on the status line and the pane shows up in the
  need-input view until you focus it.

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
| type | fuzzy search the window **title** |
| `ctrl-t` | session **tree** view |
| `ctrl-r` | **recent** (MRU) view |
| `ctrl-i` | **need-input** view (waiting panes only) |
| `alt-p` | toggle preview |
| `shift-↑` / `shift-↓` | scroll preview by line |
| `PgUp` / `PgDn` | scroll preview by page |
| `ctrl-n` / `ctrl-p` | move selection (fzf default) |
| `Enter` | switch to the window |

## Configuration

Set these **before** the plugin loads:

| Option | Default | Description |
|--------|---------|-------------|
| `@switcher-default-view` | `tree` | Initial view: `tree`, `recent`, or `needinput`. |
| `@switcher-key` | `C-w` | Prefix key that opens the picker. |
| `@switcher-popup-width` | `100%` | Popup width. |
| `@switcher-popup-height` | `100%` | Popup height. |
| `@switcher-preview` | `right:62%` | fzf preview position/size. |
| `@switcher-preview-follow` | `on` | Anchor preview to the bottom (tail-style). |
| `@switcher-needinput` | `on` | Enable the need-input system (hooks/toast). |

Example:

```tmux
set -g @switcher-default-view 'recent'
set -g @switcher-key 'C-j'
set -g @switcher-preview 'right:55%'
set -g @plugin 'lr00rl/tmux-switcher'
```

## Need-input alerts (Claude Code / Codex)

The plugin sets up the tmux side automatically (toast status line + clear on
window focus). To let Claude Code and Codex flag their pane, install the hooks
once:

```sh
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh install     # wire hooks
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh status      # check
~/.tmux/plugins/tmux-switcher/scripts/install-hooks.sh uninstall   # remove
```

It edits `~/.claude/settings.json` (4 hooks: `Notification`, `Stop`,
`UserPromptSubmit`, `SessionEnd`) and `~/.codex/config.toml` (`notify`),
idempotently and with timestamped backups. An existing Codex `notify` chain is
**wrapped** (preserved), not replaced. Restart Claude/Codex sessions afterward.

A flagged pane is identified via the `$TMUX_PANE` that hook subprocesses inherit;
the flag clears when you focus that window (and, for Claude, when you submit your
next prompt).

### Toast position note

tmux has a single `status-position`, so the toast renders on a second status line
adjacent to your main status bar (revealed only while a toast is live). A toast
strictly at the top while the bar stays at the bottom is not possible natively.

## How it works

- Rows are `target ⇥ name ⇥ meta`; fzf uses `--with-nth=2.. --nth=1` to display
  name+meta while searching only the name.
- Preview uses `--preview-window '<pos>,nowrap,follow'`; `follow` tails to the
  bottom so the current state is visible.
- State lives in `~/.local/state/tmux/` (`window-mru`, `need-input`,
  `need-input-toasts`).

## License

MIT

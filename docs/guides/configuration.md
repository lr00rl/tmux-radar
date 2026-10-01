# Configuration

Set tmux-radar options before the plugin loads. The core picker is window-first:
Recent, Agents, and Tree are the canonical views. Recent and Tree rest at window
granularity and reveal exact panes with `Ctrl-e`; Agents is already pane-level.

```tmux
set -g @radar-default-view 'recent'
set -g @radar-key 'C-w'
set -g @radar-last-key 'Tab'
set -g @radar-preview 'right:62%'
set -g @radar-preview-follow 'on'
```

## Picker options

| Option | Default | Meaning |
| --- | --- | --- |
| `@radar-default-view` | `recent` | Initial view: `recent`, `agents`, or `tree`. `needinput`/`inbox` alias Agents and `all` aliases Tree for compatibility. Invalid values fall back to Recent. |
| `@radar-key` | `C-w` | Prefix key that opens the picker. Reload tmux after changing it. |
| `@radar-last-key` | `Tab` | Prefix key for the cross-session most-recent-other-pane toggle. Use `none` to leave it unbound. |
| `@radar-popup-width` | `100%` | Picker popup width. |
| `@radar-popup-height` | `100%` | Picker popup height. |
| `@radar-preview` | `right:62%` | fzf preview position and size. |
| `@radar-preview-follow` | `on` | Keep preview anchored to the selected pane's newest visible content. |
| `@radar-expand-panes` | `off` | Open Recent/Tree with pane leaves expanded; `Ctrl-e` toggles the state. |
| `@radar-needinput` | `on` | Enable lifecycle marks, board events, pane retitles, and the status strip. |
| `@radar-needinput-commands` | `codex claude opencode kimi pi cursor-agent grok gemini amp droid auggie` | Process identities used for the live scanner, liveness GC, and diagnostics. |
| `@radar-retitle` | `on` | Prefix marked pane titles with a textual status label and restore the mark-owned saved title when cleared. A matching glyph prefix alone is never treated as ownership. |
| `@radar-claude-bg` | `on` | Track paneless Claude sessions on notification surfaces; they never become selectable picker rows. |
| `@radar-bar` | `auto` | `auto` adds chips to `status-right`, `pinned` reserves a stable second line, and `off` hides chips while retaining marks. |
| `@radar-bar-ttl` | `action=0 done=600 notice=600` | Seconds a chip stays on the bar, per level (`0` keeps it until handled; one number sets every level); the underlying mark remains. |
| `@radar-win-fit` | `on` | Fit window names to each client's width; on a narrow client only marked windows, then the current one, keep names ([the window list](notifications.md#the-window-list-fits-your-width)). |
| `@radar-win-min` | `4` | The fewest characters a fitted name shows; below that it shows none. |
| `@radar-win-reserve` | `0` | Columns kept back for text printed by `#(command)` jobs on the status sides, which the fitting counts as zero width. |
| `@radar-done-ttl` | `0` | Seconds a finished-turn (DONE) mark is kept for review (`0` keeps it until focused or cleared). |
| `@radar-toast` | `float` | Show a new mark once on clients that are not on its pane: `float` (a box in the top-right corner), `status` (the status line), or `off`. |
| `@radar-toast-levels` | `action done notice` | Levels that toast. |
| `@radar-toast-duration` | `5000` | Milliseconds a toast stays up; going to its pane ends it sooner. |
| `@radar-notify-command` | (none) | Shell command run once per new mark, with the mark in `RADAR_*` variables ([notifications](notifications.md)). |
| `@radar-scan` | `on` | Live scanner: classifies agent panes working/stalled/blocked, adopts hookless sessions, heals stale marks, synthesizes transition events. |
| `@radar-scan-interval` | `10` | Seconds between live scans (minimum 5). |

The picker keys are intentionally fixed around its three views: `Ctrl-r`
opens Recent, `Ctrl-a` opens Agents (`Ctrl-i` is a kept alias), and `Ctrl-t` opens Tree. `Ctrl-e` toggles
pane leaves in Recent/Tree; `Alt-1`…`Alt-9` safely jumps to an existing visible
result; `Alt-p` toggles preview. `Enter` switches to the exact revalidated stable
pane ID (`%N`) with one tmux client operation. Search text starts with the
sanitized user window name, followed by the snapshot location/title; cwd,
command, and event state remain secondary metadata. Session/window hierarchy
rows also carry real render-time pane IDs, so no selectable row is a no-op. See
the interaction contract in
[`DESIGN.md`](../../DESIGN.md).

# Toasts and turn-end notifications

When an agent writes a mark (it needs approval, it finished its turn, its turn
failed), tmux-radar announces the mark once, in two ways: a toast on your tmux
client, and a command of your own. Every agent radar knows reaches both, since
both hang off the mark itself: Claude Code, Codex, Kimi, OpenCode, pi, Grok,
Cursor, Droid, Gemini, Auggie, and the panes the scanner watches.

## The toast

```
                                          ╭─ ✓ billing-api ────────────────────────────────╮
                                          │ Claude finished: Added the retry and its test. │
                                          ╰────────────────────────────────────────────────╯
```

The toast is a box floating in the top-right corner of every attached client
that is not already on the marked pane. The border takes the chip colour of
the level (`⚠` action, `✓` done, `!` notice), and the title names the window
(or the project of a background session). Several toasts stack downward. It is
drawn by tmux-radar inside tmux, so it looks the same on a laptop and over
SSH from anywhere, with no desktop notification service involved.

It is not a tmux popup. While a popup is open, tmux stops redrawing every pane
and sends every key to the popup, which is wrong for a notice that arrives
while you type. `scripts/radar-float.sh` writes the box straight to the
client's terminal instead, the method of
[Tarilonte/tmux-toast](https://github.com/Tarilonte/tmux-toast): it saves the
cursor, paints the box, and restores the cursor with the colours tmux set.
tmux knows nothing of the box, so:

- Panes keep drawing, and every key goes where it always goes.
- When a pane redraws under the box, the next repaint (every 20 ms) puts it
  back. A pane that scrolls fast under the corner still tears it between
  repaints: under a pane printing about 30 lines a second, the box was whole
  in two samples out of three. Agent screens that redraw in place leave it
  steady.
- It leaves after `@radar-toast-duration` milliseconds (60 s at most), as soon
  as its mark is cleared (such as when you go to that pane), or the moment
  its client detaches; then tmux repaints the client from its own copy of the
  screen. A killed toast is erased the same way.
- Up to six toasts stack in the corner while the screen has room; one more,
  or a client under 30 columns, gets a status-line message instead.
- The client that is on the marked pane gets no toast; the pane title already
  says it. Control-mode clients (`tmux -CC`) get none either.

Bytes that are not UTF-8 are dropped and every control character becomes a
space before the text reaches the terminal, so no label or window name can
move the cursor, set a title or write the clipboard. Non-ASCII text counts as two columns when the box is
sized, so Chinese text keeps the right edge straight.

`@radar-toast status` shows the same announcement as a one-line status-line
message instead (`display-message -C`): a key press reaches the pane and
dismisses it. There `#` and `%` are doubled, so `#(cmd)` cannot run and `%Y`
stays `%Y`.

| Option | Default | Description |
| --- | --- | --- |
| `@radar-toast` | `float` | `float` draws the box in the top-right corner, `status` uses the status line, `off` shows nothing (the notify command still runs). `on` means `float`. |
| `@radar-toast-levels` | `action done notice` | Levels that toast. `action` alone toasts only approvals and questions. |
| `@radar-toast-duration` | `5000` | Milliseconds the toast stays up. |

## Your own notification: `@radar-notify-command`

```tmux
set -g @radar-notify-command '~/.tmux/plugins/tmux-radar/examples/notify-desktop.sh'
```

The command runs once for every new mark, with the mark in these variables:

| Variable | Value |
| --- | --- |
| `RADAR_LEVEL` | `action` (needs approval or input), `done` (turn finished), `notice` (turn failed, anything else) |
| `RADAR_AGENT` | The agent: `claude`, `codex`, `cursor-agent`, `grok`, and so on |
| `RADAR_LABEL` | The mark: `Claude finished: Added the retry and its test.` |
| `RADAR_WHERE` | The window name, or the project of a background session |
| `RADAR_PANE` | The pane id, or `-` for a background session |
| `RADAR_SESSION` | The tmux session of the pane, empty for a background session |
| `RADAR_KEY` | The agent session key, such as `s:<session id>` |
| `RADAR_WATCHED` | `1` when an attached client is on the pane, else `0` |
| `RADAR_TEXT` | The toast as plain text: `✓ billing-api · Claude finished: …` |

It runs for every level and whether or not you are looking, so the command
decides. A notifier for finished turns you are not watching:

```sh
#!/bin/sh
[ "$RADAR_LEVEL" = done ] && [ "$RADAR_WATCHED" = 0 ] || exit 0
osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
  -e 'end run' "$RADAR_WHERE" "$RADAR_LABEL"
```

`examples/notify-desktop.sh` does the same for every level on macOS
(`osascript`) and Linux (`notify-send`). Quote every `RADAR_*` value: a label
carries text the agent wrote. Pass it to other programs as an argument, never
inside their source, as the example does with AppleScript.

The tmux server runs the command (`run-shell -b`), with the server's
environment and `PATH`, stdin closed and output discarded. The hook that wrote
the mark returns at once, so a slow command (a sound, a chat message, a web
request) never holds up the agent, and the agent cannot cut it short either.
A command that fails is logged to `notify-errors.log` in the state directory,
never shown on the client. A command that never ends is not killed: each one
keeps a background process alive until it exits, so give a network call its
own timeout. `doctor` lists the options in effect.

## When a mark is announced

A mark is announced by the write that added it, and only once:

- Each mark is claimed with an atomic `mkdir` under `.announced/` in the state
  directory, so two hooks that finish at the same moment cannot both announce
  it.
- Only marks written in the last 30 seconds qualify. Reloading the plugin or
  restarting tmux announces nothing old. A mark spooled while the state lock
  was busy counts from the moment it is replayed.
- A new mark for the same session (an approval after a finished turn) is a new
  announcement. The same mark rewritten does not repeat, and an idle reminder
  writes no mark at all.

Floating toasts stack, up to six per client while the screen has room, and
the rest go to the status line; in status mode a later toast replaces the one
on screen. The chips list every mark either way.

## Testing

`tests/test_announce.sh` attaches a real client to an isolated server from a
pane of a second isolated server, so it checks what a person would see: the
box in the corner, its alignment with Chinese text, typing under it, and the
status line. It never touches your live server.

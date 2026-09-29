# Toasts and turn-end notifications

When an agent writes a mark (it needs approval, it finished its turn, its turn
failed), tmux-radar announces the mark once, in two ways: a toast on your tmux
client, and a command of your own. Every agent radar knows reaches both, since
both hang off the mark itself: Claude Code, Codex, Kimi, OpenCode, pi, Grok,
Cursor, Droid, Gemini, Auggie, and the panes the scanner watches.

## The toast

```
 ✓  billing-api · Claude finished: Added the retry and its test.
```

The toast is a tmux status-line message on every attached client that is not
already on the marked pane. The glyph carries the chip colours (`⚠` action,
`✓` done, `!` notice); the rest of the line follows your own `message-style`.

It stays out of your way by design:

- The pane underneath keeps drawing (`display-message -C`).
- A key press reaches the pane as usual and dismisses the toast; nothing is
  swallowed. A popup was rejected for this reason: it takes the keyboard
  until it closes.
- The client that is on the marked pane gets no toast; the pane title already
  says it. Control-mode clients (`tmux -CC`) get none either.
- It shows for `@radar-toast-duration` milliseconds, then the status line
  returns. The chip and the pane title stay until you handle the mark.

Text from agents and window names is printed, never interpreted: `#` and `%`
are doubled before tmux sees them, so `#(cmd)` in a label cannot run anything
and `%Y` stays `%Y`.

| Option | Default | Description |
| --- | --- | --- |
| `@radar-toast` | `on` | `off` stops the toast; the notify command still runs. |
| `@radar-toast-levels` | `action done notice` | Levels that toast. `action` alone toasts only approvals and questions. |
| `@radar-toast-duration` | `5000` | Milliseconds the toast stays up, unless a key dismisses it first. |

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

Several marks in one second each toast in turn and the last one stays up; the
chips list all of them.

## Testing

`tests/test_announce.sh` attaches a real client to an isolated server from a
pane of a second isolated server, so it checks what a person would see on the
status line, and it never touches your live server.

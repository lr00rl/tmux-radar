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

## The chips, and clicking to go there

The toast says what just happened; a chip on the status line says what is
still unread. Each window that holds unread marks gets one chip: the most
urgent level among its marks, and a count when it has several. Approvals come
first, then the newest, three at most, then `+N` for the windows left out.

```
 ⚠ billing-api ×2   ✓ lattice   +1
```

A chip goes when you go to the pane, and on its own after its level's
lifetime in `@radar-bar-ttl`, in seconds. The default keeps an approval until
you handle it, since an agent is blocked on it, and lets a finished turn or a
notice go after ten minutes, since the toast already told you:

```tmux
set -g @radar-bar-ttl 'action=0 done=600 notice=600'   # the default
set -g @radar-bar-ttl 'done=120'                       # finished turns fade after two minutes
set -g @radar-bar-ttl 300                              # every chip fades after five minutes
set -g @radar-bar-ttl 0                                # every chip stays until handled
```

The mark behind a faded chip stays in the picker and in the pane title until
you go to the pane.

With `mouse on`, a click on a chip or on a floating toast takes the client you
clicked to the marked pane, across windows and sessions. A paneless chip
(a background session) and `+N` open the picker. Chips are click targets on
tmux 3.4 and later; the toast on any version. radar wraps the first mouse
button's root bindings for this and keeps what was bound there for every
other click; while no toast is up, a click in a pane costs nothing extra.
`@radar-click off` puts your original bindings back. A status-line toast
(`@radar-toast status`) cannot be clicked: tmux owns that line.

## Narrow screens and window colours

On a client under 120 columns the chips give way to one count per level,
most urgent first, in the level's colour:

```
 ⚠1 ✓2
```

A count of one goes to its pane when clicked; a larger count opens the picker
so you can choose. Each client picks for itself, so a laptop and a wide
monitor attached to the same session each get what fits.

radar also writes the level of every window that holds an unread mark into
the window option `@radar-color` (`colour208` for an approval, `colour35` for
a finished turn, `colour220` for a notice; unset otherwise), under the same
rules as the chips. With catppuccin, radar points the window number's colour
at it when the plugin loads, so the window list itself shows what needs you.
With another format, use it yourself:

```tmux
set -g window-status-format '#[bg=#{?#{@radar-color},#{@radar-color},colour238}] #I #[default] #W '
```

## The window list fits your width

radar shares the status line's width out among the window names, per client
(`@radar-win-fit`, on by default):

1. Take the client's width, less status-left, status-right (chips and clock
   included), every window's number and padding (one or two digits), and the
   separators. What is left is the room for names.
2. Give every window an equal share. A name shorter than its share keeps its
   whole length and hands the rest back.
3. Share what was handed back among the names that were cut, and repeat until
   nothing changes. Spare columns go one each to the first cut windows.

The list then fills the line exactly: no window hides behind `<` or `>`, and
no column is left empty while a name is cut. At 175 columns with ten windows:

```
[work]  0  tmux-radar  1  editor_theme  2  editor-plugin-lite  3  feedsync  4  infra  5  shared_working_place  …
```

and at 150 columns the long names give way first:

```
[work]  0  tmux-radar  1  editor_them  2  editor-plug  3  feedsync  4  infra  5  shared_wor  6  billing-cl  …
```

A name shows at least `@radar-win-min` characters (default 4) or none. When
the room cannot give every window that much, only windows with an unread mark
keep their names, the most urgent first (approvals, then notices, then
finished turns, at most four), and the room they leave goes to the current
window's name:

```
[work]  0    1    2  editor-p  3    4    5  shared_  6    7    8    9   ⚠1 ✓1 10-01 06:27
```

tmux does the measuring when it draws the bar, so a laptop and a phone over
SSH attached to the same session each get the list that fits them. radar
republishes the cut points when windows come, go or are renamed, and when the
set of marked windows changes.

status-left and status-right are measured as tmux draws them: your
session's own values, with the current window, so a pane title or a
directory on the right counts at its real width. A `#(command)` in them is
left out of the measurement: measuring it would run the command a second
time at every redraw, at the same instant as the status line's own run, and
a command like tmux-continuum's auto-save would race itself. Its output
therefore counts as zero width. If a command on your bar prints text, keep
columns back for it (`doctor` reminds you when a side runs a command):

```tmux
set -g @radar-win-reserve 6   # columns that #(...) output on the bar needs
```

A status-left or status-right changed while tmux runs is measured from the
next window change, session switch or mark; a config reload applies it at
once.

How it attaches: when the plugin loads (after your theme), radar replaces the
one stand-alone `#W` or `#{window_name}` in `window-status-format` and
`window-status-current-format` with its fitted name. That works with tmux's
own formats and with most themes. catppuccin shows the pane title by
default, so set its window text to the name:

```tmux
set -g @catppuccin_window_text ' #W'
set -g @catppuccin_window_current_text ' #W'
```

If a format has no such name, or more than one, or your status line lists
the windows some other way, radar leaves the bar alone and
`needinput-notify.sh doctor` says why (`window names fitted`).
`set -g @radar-win-fit off` puts `#W` back.

Limits: a name is fitted over its first 32 cells; a session with more than
30 windows keeps its names whole, as your theme draws them (the numbers alone
fill a wide screen there, and fitting would cost each redraw several
milliseconds); a window linked into several sessions is fitted for the one
with the most windows, so in the others it may leave room unused;
`swap-window` fires no hook, so after a swap the spare columns may go
to the wrong window until the next change (the total still fits).

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
on screen. The chips still show every window with unread marks.

## Testing

`tests/test_announce.sh` attaches a real client to an isolated server from a
pane of a second isolated server, so it checks what a person would see: the
box in the corner, its alignment with Chinese text, typing under it, and the
status line. It never touches your live server.

# tmux-radar interaction design

## Source of truth

- Status: Active
- Last refreshed: 2026-09-28
- Primary product surface: the `fzf` popup opened by `prefix + C-w`
- Supporting surfaces: pane preview, pane MRU toggle, AI lifecycle marks, status chips, status-line toasts and the user's notify command, and the live scanner
- Evidence reviewed:
  - historical picker at `v0.1.3` / `6ee7afc`, especially `scripts/switcher.sh`, `README.md`, and `tests/test_switcher.sh`;
  - the interaction commits `6e27cd4`, `7864f66`, and `4891290`;
  - the current `fdc107d` implementation and its real tmux/fzf regression suite;
  - live tmux state on 2026-08-11: 46 panes, 14 process/registry-detected AI panes, but only 2 pane-backed unread lifecycle marks;
  - live tmux state on 2026-08-20: a Codex session started before hook install was invisible to every surface; a Claude pane held an ACTION mark while observably working (approved in place); teammate-swarm registry rows pointed at panes of a foreign tmux server;
  - live tmux state on 2026-09-28: one pane held five registry rows because headless runs started from its agent's tool calls inherited `TMUX_PANE`; two hook-owned sessions idle for days carried scanner-synthesized DONE marks; one pane kept a `✓` title with no mark under it;
  - a probe on Claude Code 2.1.283: the hooks of a nested `claude -p` run see `CLAUDE_CODE_SESSION_ATTENDED=0` and `CLAUDE_CODE_ENTRYPOINT=sdk-cli`, and a Stop payload carries `background_tasks` and `session_crons`;
  - the Claude Code 2.1.274 hook type reference vendored in `fast-jev-compaction` (`types/claude-code.d.ts`), read for the payload fields the adapter did not use;
  - probes on 2026-09-28 in isolated tmux servers: Grok Build 1.0.41 ran the hooks in `~/.claude/settings.json` with a camelCase payload and did not load `~/.cursor/hooks.json`; Cursor CLI 2026.09.28 ran `~/.cursor/hooks.json` but not Claude's hooks, fired `stop` only in its TUI, and titled a pane `… - 🔐 Waiting for confirmation` during an approval with status indicators on; Droid 0.82.0 ran project hooks with snake_case fields and camelCase twins; Gemini, Auggie and Amp could not run a turn (not logged in, out of credits);
  - the local `cd-design-skill` Product/Deep design gates;
  - upstream fzf, tmux tree-mode, GitHub Notifications, Raycast, Warp, and Zellij documentation.

This document supersedes the pane-first assumptions introduced after `9fd89c4`.
The historical interaction model is the baseline; process-only AI noise is not.

## Role

tmux-radar routes attention in a tmux workspace that runs many coding agents.
It works at the multiplexer, the one layer that sees every pane of every agent
from every vendor. It answers three questions and nothing else: where a piece
of work lives (Recent, Tree), what state each agent is truthfully in (hooks
and the scanner), and which exact pane needs the user now (chips, pane titles,
the Agents board, one key to get there).

What happens inside a single session belongs to the agent and its plugins:
context, compaction, approvals, the toast a plugin shows in its own
transcript. An agent plugin such as `fast-jev-compaction` is that layer. It
speaks to the person already looking at the session. tmux-radar speaks to the
person looking somewhere else.

The boundaries that follow from this:

- It observes and routes. It never answers a prompt, sends keys to an agent,
  or closes a pane. The supervisor that did was removed in 2026-08.
- It reports events, and a running process is no event. An idle agent is a
  free shell.
- It reads what the agent states before it infers anything. A hook payload
  and its environment say what kind of notification this is, whether work is
  still in flight, and whether anyone sits at the prompt. The screen is the
  source only for sessions that cannot speak.
- Only an attended session asks for attention. A headless run is part of the
  work of whoever started it.
- One event makes one signal, at one level, with one destination, and the
  signal ends when its condition does. A reminder of an old event is no new
  event.

## Brand

- Personality: competent, direct, calm, terminal-native, and slightly opinionated.
- Trust signals: exact destinations, truthful state, instant keyboard response, stable hierarchy, and visible failure.
- Avoid: generic AI styling, decorative animation, emoji-only meaning, walls of undifferentiated panes, hidden destructive behavior, and status rows that cannot go anywhere.

The visual register is a restrained Data-Dense + Terminal hybrid. Density is
welcome when structure is clear. Craft comes from alignment, hierarchy,
keyboard behavior, and exact state—not decoration.

## Product goals

- Make the user-assigned window name the fastest and strongest way to find work.
- Restore the useful `v0.1.3` switcher model: window-first Recent, a real Tree,
  pane drill-down, numeric quick jumps, preview, and exact pane switching.
- Make the Agents board the single, accurate answer to "which agent needs me,
  and what is the fleet doing".
- Ensure every visible result can switch to one real live pane.
- Keep the popup fast and predictable at 40–100+ panes.

Non-goals:

- Presenting idle or long-finished agent panes as if they were active work.
- Auto-killing or closing user panes because an agent appears idle or finished.
- Showing paneless/background sessions as fake tmux destinations.
- Replacing the existing notifier, registry, or fzf dependency.
- Rewriting the picker as a native Go TUI.

Success signals:

- For equivalent contiguous matches, a match that begins in the window name
  ranks before the same text found only in pane title, command, session label,
  or working directory. Search still follows fzf relevance for non-equivalent
  fuzzy matches; the UI does not pretend to implement a hidden weighted index.
- `Ctrl-t`, `Ctrl-r`, `Ctrl-i`, and `Ctrl-e` work through real tmux key events
  with the installed fzf version.
- On the 2026-08-11 live fixture, the AI surface shows the 2 unread pane-backed
  events, not the 12 additional process-only `ACTIVE` shells.
- Tree and Recent never expose an unopenable structural or synthetic row.

## Personas and jobs

- Primary persona: a proficient tmux user supervising many named projects,
  windows, panes, and parallel coding agents from the keyboard.
- Context: 40+ panes, repeated use throughout the day, interruption-heavy work,
  mixed Chinese/English names, long paths, and multiple sessions.
- Jobs:
  1. return to a recently used project window;
  2. browse the full session/window/pane hierarchy when location is uncertain;
  3. review only AI work that has produced an unread action or result;
  4. inspect enough pane output to choose confidently, then switch exactly.

## Information architecture

The popup has three peer views over live tmux destinations:

| View | Question | Resting model | Default order |
| --- | --- | --- | --- |
| **Recent** | Where was I working? | All live windows; panes appear on drill-down | window MRU, then remaining live windows |
| **Agents** | Which agent needs me, and what is the fleet doing? | Unread marks, blocked/waiting rows, and working panes | ACTION, BLOCKED/WAITING, DONE unread, WORKING; newest first within level |
| **Tree** | Where is this work in tmux? | Session → window; panes appear on drill-down | canonical tmux server order |

Compatibility aliases may remain at the CLI boundary: `needinput`, `inbox`,
`attention`, and `ai`/`agent` all resolve to Agents; `all` resolves to Tree.
User-facing copy uses only Recent, Agents, and Tree.

There is deliberately one AI surface. A separate unread-events inbox was tried
and rejected in practice: it duplicated the board with weaker accuracy, and
its rows aged into noise. Unread events live on the board, kept truthful by
the scanner's post-mark healing.

### Object model

- **Session** contains window links and has one current window/pane.
- **Window** is the primary named navigation object and has one active pane; a
  linked window may appear under more than one session in Tree but only once in
  Recent.
- **Pane** is the exact terminal destination and preview source.
- **Unread mark** is an unread lifecycle event attached to a live pane.
- **Registry/process evidence** proves lifecycle and liveness; it is supporting
  machinery, not an inbox item by itself.

Every rendered row carries a stable `%pane_id` as its hidden target, captured
in the same bulk snapshot as the row's visible metadata:

- a session row targets that session's current live pane;
- a window row targets that window's active live pane;
- a pane row targets itself;
- an unread-mark row targets the pane named by its mark.

Session and window targets are render-time snapshots, not late-bound aliases.
If a window's active pane changes while the picker is open, accepting the old
row still selects the `%pane_id` shown by that row. If that pane vanished, the
selection fails honestly instead of silently redirecting to a different pane.

There are no `__hdr__`, `__bg__`, or other non-switchable picker rows.
Hierarchy is presentation; destination identity is always a real pane.

## Design principles

1. **Names before coordinates.** User-authored window names are primary;
   `session:window.pane`, command, cwd, and process state are supporting evidence.
2. **Unread means unread.** A running or leftover AI process is not an
   interruption. Unread marks rank above the working set on the board.
3. **Complexity available, not mandatory.** Recent and Tree rest at window
   granularity; `Ctrl-e` reveals exact panes without making every scan dense.
4. **Every row goes somewhere.** Session, window, pane, and mark rows all
   resolve to one stable live pane or fail explicitly before navigation.
5. **Search may flatten; rest preserves structure.** With an empty query, input
   order communicates MRU or hierarchy. While typing, fzf relevance may reorder
   matching rows, like a command palette flattening sections during search.
6. **Frequent actions are instant.** No animation, artificial delay, or modal
   ceremony in a surface used dozens of times per day.

Tradeoff: window-first presentation is less mechanically uniform than a
pane-only list, but matches how this user names and recalls work. Exact pane IDs
still preserve destination correctness underneath.

## Visual language

- Color: terminal defaults plus one selection accent; semantic magenta/yellow
  for ACTION, green for DONE, and amber for NOTICE. Text labels always carry
  the meaning without color.
- Typography: the terminal's monospace face. Hierarchy comes from brightness,
  alignment, branch glyphs, and concise labels—not larger type.
- Rhythm: one compact row per result; stable columns where width permits;
  secondary metadata dims before primary identity truncates.
- Geometry: flat terminal surface, hairline popup/preview separators, no cards,
  shadows, gradients, blur, or decorative motion.
- Signature details:
  - a continuous Tree rail with aligned two-column window indexes;
  - one compact keyboard legend that changes with the active view;
  - state words plus restrained icons on the Agents board;
  - direct row jumps (`Alt-1`…`Alt-9`) as visible expert affordances.

Recommended row hierarchy:

```text
Recent: window-name    session:window[.pane]    title/state · command · ~/cwd
Tree:   ▾ session-name                         8w
          ├─  0 window-name             command · ~/cwd
          └─  7 multi-pane-window    3p · command · ~/cwd
```

Recent keeps the window name as the first displayed term; Agents leads with the state word. Tree uses a
structural prefix before the same primary identity: disclosure/branch glyphs
and a two-column window index. Session names are primary; their compact window
count moves to the dim metadata column. Picker-only search weighting keeps an
exact window-name match ahead of an identical session label. Tree does not repeat
`session:window`, `window · 1 pane`, or the parent window name on every child;
its hierarchy already communicates those relationships. Multi-pane counts use
compact `Np` metadata, while command and compact cwd provide recognition value.

## Components

- View switcher: `Ctrl-r` Recent, `Ctrl-a` Agents, `Ctrl-t` Tree; `Ctrl-i` is a kept alias for Agents.
- Recent fast-switch focus: the current MRU window stays on row 1, while the
  initial cursor and every `Ctrl-r` view switch land on row 2—the previous
  window—so opening the picker and pressing `Enter` switches back immediately.
- Hierarchy drill-down: `Ctrl-e` toggles pane rows in Recent and Tree; Agents is
  already pane-level and leaves the toggle unavailable.
- Result list: one hidden stable pane target plus two visible fields.
- Preview: the selected pane's recent output; marked/registered panes add event
  and registry details above the capture without a second navigation surface.
- Fast actions: `Enter` switches; `Alt-1`…`Alt-9` switches directly only when
  that numbered row exists in the current filtered result set; an out-of-range
  jump rings the terminal bell and leaves the picker open. `Alt-p` toggles
  preview; standard fzf keys move selection.
- Cross-session fast path: `prefix + Tab` keeps its independent pane-MRU toggle.

No new component framework or dependency is introduced.

## Accessibility

- Target standard: complete keyboard operation and truthful text state in the
  terminal medium; color is never the sole state channel.
- Focus/selection: fzf's pointer and highlight remain visible. Recent starts on
  the previous window at row 2; Tree and Agents start on row 1. Query changes
  return to the first match, and no view accepts implicitly.
- Keyboard behavior: shortcuts are shown in the popup; `Esc` always cancels;
  preview scrolling retains standard documented keys.
- Readability: sanitize C0/DEL controls, preserve Chinese text, keep the window
  name before truncatable metadata, and avoid low-contrast decorative glyphs.
- Failure: missing fzf, missing tmux, cleanup failure, vanished target, and
  navigation failure are distinct from empty results and cancellation.

## Responsive behavior

- Wide popup: list plus right preview as configured.
- Narrow popup: primary identity remains; cwd/command truncate first and preview
  may move below or remain user-configured.
- Dense/long content: keep one row; do not wrap a single destination into a
  card-like block. Preview carries overflow detail.
- Input: keyboard is primary. Mouse support inherited from fzf is supplemental.
- Interruption: view changes preserve the query where fzf does so safely;
  reloads never publish partially written rows.

## Interaction states

### Loading

Run notifier cleanup synchronously before first render and view reload. The
surface either publishes a coherent snapshot or reports a concise failure.

### Empty

- Recent/Tree with a reachable tmux server normally contain live destinations.
- Empty Agents means: `Agents clear — nothing needs you, is working, or is awaiting review.`
  It emits zero selectable rows; it does not invent a placeholder target.

### Success

Revalidate the stable pane ID, switch with one tmux client operation, record MRU
only after success, and clear only the selected pane's mark. Focusing one
pane must not clear unread sibling panes in the same window.

### Error

If the selected pane vanished or the switch failed, remain honest: concise
diagnostic, nonzero result, no raw tmux stderr, no partial navigation, and no
false MRU update.

### Agents board membership

The board shows one row per live pane that has current AI significance:

1. an unread mark (ACTION, DONE, or NOTICE) attached to a live pane;
2. a registry row with a live pid (blocked/waiting/working/done session state);
3. a scanner verdict of `working` or `blocked` on a pane hosting a watched
   agent process.

Marks keep their historical eligibility rules: a normalized unread mark on a
live pane; ACTION/NOTICE liveness is revalidated by the notifier/registry GC;
DONE may remain after the agent exits so the completed output can be
reviewed; public `mark` API rows are eligible on the same contract.

Explicit exclusions:

- paneless/background marks (they notify through the chip strip, never
  through a fake destination);
- IDLE panes — an idle agent reads as a free shell and earns no row;
- stale claims the scanner has already contradicted (healed marks, waiting
  rows downgraded by observed working).

The registry, process scan, and doctor remain valuable for GC and diagnostics,
and now also feed the board's working/blocked rows.

### What a Claude event means

The adapter reads the payload and the hook environment instead of treating
every event alike.

| Signal | Source | Result |
| --- | --- | --- |
| Unattended run | `CLAUDE_CODE_SESSION_ATTENDED=0`, or an `sdk-*` `CLAUDE_CODE_ENTRYPOINT`, outside a background job | Every event is ignored: no row, no mark, no retitle. |
| Permission prompt | Notification `permission_prompt` | ACTION, `Claude needs approval`, followed by the tool when the message names one. |
| Question | Notification `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` | ACTION, `Claude needs your input: <message>`. |
| Answer | Notification `elicitation_complete`, `elicitation_response` | The session mark clears. |
| Reminder | Notification `idle_prompt`, `auth_success` | Nothing. Stop already said the turn ended. |
| Other or untyped notification | any other `notification_type`, or none | A mark with the message as given. |
| Finished turn | Stop | DONE, `Claude finished: <first line of the last message>`. |
| Paused turn | Stop with a subagent or workflow in `background_tasks`, or with `session_crons` pending in a turn the schedule started | No mark. The session resumes on its own. |
| Team member's turn | Stop from a process started with `--agent-id` (a member of an agent team) | No mark: the member reports to its lead. The registry records it as done, and an approval mark it had clears. Its approval requests are still marked. |
| Failed turn | StopFailure | NOTICE, `Claude turn failed: <error>`. |
| Tool result | PostToolUse on the main thread, for a tool that started after the mark was written | The session mark clears: a tool that ran proves nothing is waiting. |

Every hook is synchronous, so events reach the notifier in the order they
happened. A background shell in `background_tasks` decides nothing, because a
dev server never exits. A turn the user started is finished even while a loop is armed;
only the turn a wakeup started is paused by the next wakeup.

### Other agents

Grok, Cursor, Droid, Gemini and Auggie copy Claude's hook design, so the same
adapter reads them after it rewrites their fields into Claude's names; the
[agent hooks guide](docs/guides/agent-hooks.md) has the per-agent table. The
process tree decides who spoke. The nearest watched agent above the hook fired
the event; if another watched agent stands above that one, the run is part of
the other's work and reports nothing. A hook written for one agent but fired
by a different one changes nothing, since that agent reports through hooks of
its own. Only Claude's paneless hooks are placed by working directory: any
other agent's event without a pane comes from a desktop app (the Cursor
editor runs the same hook file) and is dropped. Agents with no approval event
(pi, Cursor, Auggie) and agents with no hooks (Amp) rely on the scanner for
waits; Cursor's status title makes its approvals visible when the user turns
it on.

### Toasts and the notify command

The chip says a mark exists; the toast says what just happened, once, to the
person looking elsewhere. After a write, each mark it added floats as a box in
the top-right corner of every attached client that is not on the marked pane:
the border in the chip colour of its level, the window (or project) in the
title, the label inside. Toasts stack downward.

A tmux popup was the obvious tool and the wrong one: while a popup is open
tmux stops redrawing every pane and sends every key to the popup, so a notice
would freeze the agents and swallow typing. `scripts/radar-float.sh` writes
the box to the client's terminal instead (the method of Tarilonte/tmux-toast):
save the cursor, paint at absolute positions, restore the cursor and the
colours tmux set. tmux never learns of it, so panes draw and keys pass as
usual; a repaint every 20 ms restores the box after a pane redraws under it
(a pane scrolling about 30 lines a second under the corner still tears it a
third of the time), and `refresh-client` erases it. The toast stops the
moment its client process exits, so a detached terminal is never painted,
and up to six stack before the rest fall back to the status line. It reaches a client over SSH because the
client's terminal is a device on the tmux host, and needs no desktop service.
Every control character in the text becomes a space before it reaches the
terminal, and non-ASCII counts as two columns when sizing, so Chinese keeps
the right edge straight. It lasts `@radar-toast-duration` milliseconds, ends
within a second of its mark being cleared, and `@radar-toast-levels` filters
it; `@radar-toast status` shows a `display-message -C` line instead. The chip
and the pane title remain the durable record.

The same announcement runs `@radar-notify-command` through `run-shell -b`,
with the mark in `RADAR_LEVEL`, `RADAR_AGENT`, `RADAR_LABEL`, `RADAR_WHERE`,
`RADAR_PANE`, `RADAR_SESSION`, `RADAR_KEY`, `RADAR_WATCHED` and `RADAR_TEXT`.
It runs for every level whether or not anyone watches, and the command
decides; this is how a turn-end notification leaves tmux (desktop, sound,
chat). A claim `mkdir` per mark makes "once" hold across concurrent hooks, and
only marks from the last 30 seconds qualify, so a restart announces nothing.

### Chips, focus and clicks

On a narrow client (under 120 columns) the strip is `@radar-chips-short`: one
count per level, most urgent first, a count of one clickable to its pane and a
larger one to the picker. The same pass writes each window's level to the
window option `@radar-color`, so a window-status format can light window
numbers; the window list then carries the attention map and the counts only
summarise it. The choice is a format conditional on `#{client_width}`, so each
client gets its own variant with no resize and no script.

A chip stands for a window, not a mark: the most urgent level among the
window's unread marks, a count when there are several, approvals first. Before
2026-09-30 every mark had its own chip, and the eleven idle teammates of one
agent team filled the bar with identical `✓ <window>` chips. Each level has
its own lifetime on the bar (`@radar-bar-ttl`, default `action=0 done=600
notice=600`): an approval blocks an agent and stays until handled, while a
finished turn was already announced by its toast. The strip goes through
format expansion and strftime, so `#` and `%` in names are doubled.

Reading a mark means a client shows its pane. The focus hooks
(`session-window-changed`, `window-pane-changed`, `client-session-changed`)
pass `#{pane_id}` from their own context, which is the pane that just came
into view, and clear it only while some client shows its window
(`window_active_clients`, which also counts a window linked into another
session); otherwise they pass `-`, never an empty argument that would fall
back to `$TMUX_PANE`. They used to pass `#{hook_window}`, `#{hook_pane}` and
`#{hook_session_name}`; tmux 3.6 leaves all three empty in these hooks, so
going to a pane cleared nothing and a chip came back each time you left. The
MRU recorder had the same gap. `tests/test_announce.sh` now checks focus
through a real client.

A click on a chip or a floating toast takes the clicked client to the mark's
pane (`needinput-notify.sh click`). A chip is a status range of type user,
`radar<pane number>` (tmux 3.4 and later). The toast is invisible to tmux, so
`MouseDown1Pane` asks `toast-click` whether the click landed inside a box,
using the geometry each toast writes to `.toast-slots/<client>/<slot>/hit`
with its own pid, which rules out the box of a killed toast. That question
forks a shell, so it is asked only while `@radar-toast-live` says a toast is
up. The plugin wraps the root `MouseDown1Status` and `MouseDown1Pane`
bindings, keeps the original under `@radar-click-orig-<key>`, and runs it for
every click that is not radar's; `@radar-click off` restores it.

### Window names fitted to the width

A theme cuts nothing: with ten windows on a laptop the list ran past the
right edge and tmux hid the last windows behind `>`. The first fix (a
format in the user's config, 2026-10-01) gave every window an equal share
and cut names to a ladder of lengths, which left 27 of 175 columns empty
while four names were cut: a short name could not hand its unused share to a
long one. `radar-winfit.sh` replaces it with the rule a person would apply by
hand: equal shares of the room left after status-left, status-right, every
window's number and padding, and the separators; what a short name does not
use goes back to the cut ones; repeat. The fixed point has a closed form:
the cut names share one length c, and the first r of them by window order
get c+1, so the list fills the line to the column.

The room depends on each client's width, and clients of one session differ
(a laptop and a phone over SSH), so radar cannot publish a length. It
publishes, per window, the cut points: `@radar-wname` is a format that
compares the room (`@radar-win-avail`, which tmux measures at draw time) with
the thresholds where this window gains a character, by binary search, whole
name first. Window i gets c cells when `sum over the set of min(len, c-1)`
plus the windows up to i that are long enough for c fits; that total grows
with c, so the search is sound.

The room is one `#{W:...}` loop: every other window contributes its format
without its name (`@radar-win-shell`), the current window contributes its own
plus `#{T:status-left}#{T:status-right}`. The first version expanded the two
sides inside each window's format, and the review caught two faults in that.
A side that depends on the window (tmux's default status-right shows the
pane title) was measured with each drawn window instead of the current one,
so the windows disagreed on the room and the bar overflowed. And a
`#(command)` job expanded in each window's format started a copy of its own
per window: a counting job ran 44 times in four seconds instead of 3. The
sides are now expanded in the loop's current-window branch, so they resolve
as the status line draws them (the current pane, the session's own values).
A second review argued that a job expanded there is the status line's own
and could stay; measured, it is not: tmux keys a job by the format tree it
runs in, and the counting job ran 8 times in four seconds against 3. That
second run starts in the same instant as the status line's, and
tmux-continuum's auto-save, a common companion of tmux-resurrect, would then
race itself into two resurrect saves of the same second. So the sides are
measured from copies without their jobs (`@radar-win-left`,
`@radar-win-right`, set per session where a session has its own sides and
refreshed by every publish), a job's output counts as zero width,
`@radar-win-reserve` keeps columns for jobs that print, and `doctor` says
when a side runs one. Drawing ten windows costs about 0.5 ms more than
the theme alone, thirty about 3 ms; each window's search measures every
window, so the cost grows with the square of the count, and a session with
more than 30 windows keeps its names whole.

Below `@radar-win-min` cells per window (4) the fill stops: a two-letter stub
says less than the coloured number. Then only marked windows keep names,
the most urgent first and at most four, and what they leave goes to the
current window, which is picked by `window_active` at draw time so a window
switch needs no republish. Radar republishes on `window-linked`,
`window-unlinked` and `window-renamed` (automatic renames fire it), and when
the set of coloured windows changes; a restore publishes once at its end.
Publishes run one at a time behind the notifier's kind of lock (flock, else
shlock, both of which free a dead holder's lock), because two that read the
window list at different moments could leave the later write's stale
thresholds; one that finds the lock taken asks the holder to run once more.
A window linked into several sessions takes the cut points of the session
with the most windows, so in the others it can only under-use.
A stale publish can only waste room: every leaf is `#{=c:window_name}`, never
longer than planned.

At load, after the theme, `patch` swaps the single stand-alone `#W` or
`#{window_name}` in both window formats for `#{E:@radar-wname}` and records
the rest as the window's cost (`@radar-win-shell`). Anything else (no name,
two, a name inside a conditional, a customised `status-format[0]`, a status
side that lists windows itself and would recurse) leaves the theme's own
formats in place, undoing an earlier patch, and says why in
`@radar-win-fit-state`. catppuccin copies its number colour
into the format at load (`set -gF`), so `patch` rewrites that one `bg=` to
follow `@radar-color`.

tmux sends a command line to its server as one message of at most 16 KB.
The first version batched every window's cut points into one `set-option`
chain; with marks the chain passed 16 KB, tmux refused it, and the error was
silenced, so the narrow names never appeared. Updates now go in pieces of 12
KB, a name is fitted over its first 32 cells, and the narrow set stops at
four windows, which keeps one window's value near 10 KB at worst.

### Severity

A label reads `<head>[: <detail>]`. Adapters write the head from a fixed
vocabulary and the detail is free text from the agent. A head that ends in a
known phrase (`needs approval`, `needs your input`, `finished`, `turn failed`)
decides the level alone, so no word in the detail changes it. Any other label
is classified by its whole text, completion before action. One definition in
`scripts/radar-level.sh` serves the notifier, the chips, the picker and
doctor. Labels and saved titles are stored at 200 characters at most, cut on
a character boundary, so no payload field can bloat the state file.

### Live scanner and badges

Hooks are push: they miss sessions started before installation, agents without
an adapter, approvals given in place (no `UserPromptSubmit` fires), and events
aimed at a foreign tmux server (Claude teammate swarms run under
`tmux -L claude-swarm-*`). The scanner is the pull-based floor beneath them:

1. Every `@radar-scan-interval` seconds (default 10, minimum 5) `tick`
   classifies each pane hosting a watched agent process — same ps argv0 rules
   as the mark GC — as `working` (pane title or screen changed since the last
   sample), `stalled` (no visible change while the process lives), or
   `blocked` (the agent's own title asks for action, e.g. Codex's animated
   `Action Required` marker). Results publish to `ai-live` (pane, kind, state,
   title, epoch), atomically, under a claim-stamp that caps scan frequency.
2. A pane with no hook-claimed registry row is adopted as a `p:<pid>` row with
   the scanned state, so every surface reads one model. A later native event
   with a session key supersedes the adopted row exactly as Codex's `p:`→`s:`
   upgrade already did.
3. Two consecutive `working` verdicts, counted from the mark's own epoch,
   heal an unread agent mark on that pane and downgrade a registry `waiting`
   the screen contradicts. For Claude the same fact now arrives as an event:
   the first tool result after an approval answered in place clears the mark
   at once, and the scanner remains the fallback.
4. A registry row whose pane is not live on this server keeps its liveness
   (pid + argv identity) but is re-homed to paneless `-`, so no surface ever
   targets a pane this server cannot switch to. The same validation applies
   to `$TMUX_PANE` arriving from a foreign server at hook time.
5. The scanner does not fabricate events, but an observed transition is one:
   an off-screen pane with no unread mark that flips into `blocked`, or from
   `working` into `stalled`, gets exactly one synthesized mark keyed by its
   adopted `p:<pid>` row. That is how sessions started before hook install,
   and agents without an adapter, still reach the board. A pane owned by a
   hook-claimed session of an agent that reports approvals and finished turns
   natively (Claude, Codex, Kimi, OpenCode) gets no synthesized mark at all:
   every real transition there arrives as an event, and the screen adds only
   redraw (a resize, a banner) read as work. pi has no approval event, so its
   panes keep the floor, and the mark carries the owning session key so pi's
   own events clear it. A synthesized mark never replaces an existing unread
   one.
6. Recent and Tree rows aggregate per-pane states into window badges, and
   `Ctrl-a` shows the live fleet. Both surfaces are deliberately lossy in the
   same direction: a finished turn stays in the Inbox review queue, and an
   idle agent pane is a free shell — neither earns a badge or a board row.
   The board shows unread ACTION, blocked/waiting, and working panes only.

Merge precedence per pane: an unread mark outranks live state; a live
`blocked`/`waiting` outranks a stale registry `working`; a live `working`
contradicts and hides a registry `waiting`. Badges aggregate per window, most
severe first, at most two groups with counts: `⚠` needs you, `✓` done unread,
`◐` working.

## Content voice

- Tone: terse, technical, calm.
- View terms: Recent, Agents, Tree. Do not mix AI status, Attention, Need Input,
  or Inbox into the user-facing surface.
- Actions: use outcome labels—`Enter switch`, `C-e panes`, `A-p preview`.
- Errors state what happened and the next useful action.
- Empty Agents copy must say that nothing needs the user; it must not claim
  there are no AI processes or panes.

## Implementation constraints

- Shell implementation remains compatible with macOS Bash 3.2.
- Current runtime evidence: tmux 3.6b and fzf 0.70.0.
- No new dependencies.
- Public rows remain exactly three TSV fields:

  ```text
  <stable-pane-id>\t<primary-display>\t<secondary-display>
  ```

- fzf uses `--delimiter=TAB --with-nth=2..` and searches the transformed visible
  line; do not add an `--nth` expression that removes the primary field.
- fzf 0.59 is the minimum because transform actions, `FZF_MATCH_COUNT`, and the
  safe `bell` action are required; parsable older versions fail before the
  picker opens.
- `--tiebreak=begin,index` makes beginning/window-name matches win equivalent
  contiguous-match ties while preserving producer order for an empty query;
  it is not a general weighted-search guarantee.
- fzf transform producers emit one newline-terminated action line and only
  actions supported by fzf 0.70.0.
- Safe numeric jumps are transform actions: accept `Alt-N` only when
  `FZF_MATCH_COUNT >= N`; otherwise emit `bell` and remain open. Direct
  `pos(N)+accept` bindings are forbidden because fzf clamps out-of-range
  positions to the last result.
- Each reload takes at most one bulk `tmux list-windows -a` snapshot and one
  bulk `tmux list-panes -a` snapshot. Per-session or per-window list loops are
  forbidden on the 40–100+ pane hot path.
- Session/window visible metadata and their stable pane targets come from the
  same snapshot transaction.
- Automatic focus handling is pane-specific: session/window focus resolves the
  newly active pane once, pane focus uses `#{hook_pane}`, and neither path calls
  `clear-window`. The explicit public `clear-window` command remains available.
- Focus/MRU hooks occupy fixed high indexed slots. Upgrade migration removes
  only legacy commands owned by tmux-radar and preserves foreign hooks.
- tmux-resurrect / continuum restore is topology, not focus. The plugin sets
  `@radar-restoring` around restore, skips focus-clears, MRU writes, and
  hook-ticks, then schedules one quiet GC. An empty `#{hook_session_name}`
  (`clear ':'`) is not the current session. Hook-invoked `run-shell` commands
  exit 0; the picker still calls `tick` synchronously so a stuck lock remains
  a visible cleanup failure there.
- Tests must cover current and dense fixtures without relying on fixed shared
  tmux sockets.

## Test and acceptance contract

Use coded, real-medium evidence because timing, transform output, key delivery,
sorting, and focus cannot be proven from argument inspection alone.

Required end-to-end checks:

1. Real tmux + real fzf: `Ctrl-t`, `Ctrl-r`, `Ctrl-i`, and `Ctrl-e` change the
   visible view/row structure.
2. Real fzf filtering: for identical contiguous query occurrences, a match at
   the beginning of one row's window name ranks before a match found only in
   another row's cwd or metadata.
3. Recent begins with all live windows in MRU order, then remaining windows.
4. Tree rests session → window and expands panes without synthetic rows.
5. Agents emits only pane-backed rows with current significance: unread
   marks, live registry sessions, and scanner working/blocked verdicts;
   idle panes and paneless/background rows stay absent.
6. In-range `Alt-N` and Enter switch to the exact stable pane target;
   out-of-range `Alt-N` before and after filtering leaves the picker open.
7. Session/window targets remain the rendered pane snapshot even when the
   active pane changes later; disappearance and switch failure are nonzero,
   concise, and atomic.
8. Two unread panes in one window remain independent: focusing one clears only
   that pane's event, while `Ctrl-e` inside Agents is a structural no-op.
9. Cleanup failure, malformed mark input, missing tmux/fzf, fzf no-match, and
   user cancellation remain distinguishable from an honestly empty Agents view.
10. A 100-pane fixture is complete and proves the producer uses no more than
    one bulk window call plus one bulk pane call per reload.
11. Linked windows appear once per session link in Tree, once per underlying
    window in Recent, and never duplicate pane leaves within one link/group.
12. Entering and leaving an empty Agents view updates and removes the
    empty-state header in the same atomic fzf reload transaction.
13. Hook migration preserves pre-existing foreign indexed hooks. Restore
    compose prepends `restore-begin` / `restore-end`, replaces a radar `tick`
    workaround, keeps a foreign resurrect hook, and does not stack on reload.
    A restore-time focus storm leaves unread marks in place and never prints
    `'… returned 1'`; `clear ':'` is a no-op.
14. The scanner adopts a hookless agent pane into `ai-live` and the registry,
    classifies a changing screen as working and a static one as stalled, and
    honors an `Action Required` title as blocked; an agent-sourced mark heals
    only after two working scans counted from the mark's own epoch, so a
    freshly rendered permission prompt (one screen change) never heals, and a
    contradicted waiting row downgrades to working.
15. A registry row whose pane is absent from this server keeps liveness but is
    re-homed to paneless; a row whose pid provably lives on another tty (a
    foreign server, a daemon pty) while its claimed pane hosts no agent is
    re-homed the same way, and its wrong-pane marks are dropped; `$TMUX_PANE`
    values that do not resolve locally are re-resolved before use, and the
    cwd fallback only applies to hooks with no controlling terminal.
16. Agents lists marked, registered, and scanner-found panes ordered by
    severity, and Recent/Tree window rows carry the aggregated badges without
    changing row targets or the three-field contract.
17. An unattended Claude run changes nothing: no registry row, no mark, no
    retitle, and the host session's unread mark survives its whole lifecycle.
    A background job keeps its paneless mark.
18. `idle_prompt` leaves a finished mark and its epoch untouched; a typed
    permission or question notification is ACTION whatever its detail says; a
    finished mark is DONE whatever its summary says.
19. A Stop with agent work in flight, or with a wakeup pending in a turn the
    schedule started, writes no mark; a background shell does not suppress
    one; a turn the user started is finished while a loop is armed.
20. A hook-owned pane of a natively reporting agent gets no synthesized mark
    on a working to stalled transition; a hook-owned pi pane gets one keyed by
    its session.
21. Every removal of a mark restores the pane title, done-ttl expiry included,
    and a focus-clear that lands during a tick strands no status title.
22. Chip text is literal: a `#` in a window or directory name is doubled
    before it reaches `@radar-chips`, so tmux prints it and runs nothing.
23. For every agent, an event fired under another watched agent in the
    process tree changes nothing on the pane; a launcher and the binary it
    starts within three seconds count as one agent.
24. A hook written for one agent and fired by a different one changes
    nothing, its session end included; an event from no pane is placed by
    working directory only when Claude sent it.
25. The Cursor hook entries are Claude's commands byte for byte and use only
    event names Cursor accepts; every agent config the installer touches keeps
    the user's own entries, gets a backup only when it changes, and returns to
    its prior content on uninstall.
26. A write announces each mark it added exactly once, whatever wrote it
    and however many hooks sync at the same moment: a floating toast in the
    top-right corner of each attached client that is not on the marked pane
    (panes keep drawing, keys reach the pane, Chinese text keeps the box
    straight, raw escape sequences arrive as text), and
    `@radar-notify-command` run by the tmux server with the mark in `RADAR_*`
    variables. A mark older than 30 seconds is never announced, text from
    agents and window names is printed literally, and a slow or failing
    command holds up no hook and shows nothing on the client.
27. Bash syntax, ShellCheck, all repository shell suites, and
    `git diff --check` pass before delivery.

## Open questions

- [ ] Verify whether every supported terminal forwards `Alt-1`…`Alt-9`
  unchanged; keep the feature because it is already a historical contract, but
  document any terminal-specific limitation found by real testing.
- [ ] Verify the narrow-popup preview breakpoint against a real 80×24 client;
  do not change the user's configured preview position without evidence.
- [ ] Consider a future contextual action panel only after the restored primary
  flow is stable. Do not add dismiss/kill operations without a recoverable
  notification history and explicit destructive semantics.

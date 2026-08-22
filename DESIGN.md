# tmux-radar interaction design

## Source of truth

- Status: Active
- Last refreshed: 2026-08-21
- Primary product surface: the `fzf` popup opened by `prefix + C-w`
- Supporting surfaces: pane preview, pane MRU toggle, AI lifecycle marks, status chips, and the live scanner
- Evidence reviewed:
  - historical picker at `v0.1.3` / `6ee7afc`, especially `scripts/switcher.sh`, `README.md`, and `tests/test_switcher.sh`;
  - the interaction commits `6e27cd4`, `7864f66`, and `4891290`;
  - the current `fdc107d` implementation and its real tmux/fzf regression suite;
  - live tmux state on 2026-08-11: 46 panes, 14 process/registry-detected AI panes, but only 2 pane-backed unread lifecycle marks;
  - live tmux state on 2026-08-20: a Codex session started before hook install was invisible to every surface; a Claude pane held an ACTION mark while observably working (approved in place); teammate-swarm registry rows pointed at panes of a foreign tmux server;
  - the local `cd-design-skill` Product/Deep design gates;
  - upstream fzf, tmux tree-mode, GitHub Notifications, Raycast, Warp, and Zellij documentation.

This document supersedes the pane-first assumptions introduced after `9fd89c4`.
The historical interaction model is the baseline; process-only AI noise is not.

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
3. Two consecutive `working` verdicts heal an unread ACTION mark on that pane
   (approved in place: the wait is observably over) and downgrade a registry
   `waiting` the screen contradicts. DONE marks never heal: they are a review
   queue, not a state claim.
4. A registry row whose pane is not live on this server keeps its liveness
   (pid + argv identity) but is re-homed to paneless `-`, so no surface ever
   targets a pane this server cannot switch to. The same validation applies
   to `$TMUX_PANE` arriving from a foreign server at hook time.
5. The scanner does not fabricate events, but an observed transition is one:
   an off-screen pane with no unread mark that flips into `blocked`, or from
   `working` into `stalled`, gets exactly one synthesized mark keyed by its
   adopted `p:<pid>` row. That is how sessions started before hook install —
   or agents without an adapter — still reach the Inbox. Hook-owned panes
   keep their native, richer events; a synthesized mark never replaces an
   existing unread one.
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
13. Hook migration preserves pre-existing foreign indexed hooks.
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
17. Bash syntax, ShellCheck, all repository shell suites, Go test/vet/build, and
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

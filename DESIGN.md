# tmux-radar interaction design

## Source of truth

- Status: Active
- Last refreshed: 2026-08-11
- Primary product surface: the `fzf` popup opened by `prefix + C-w`
- Supporting surfaces: pane preview, pane MRU toggle, AI lifecycle marks, status chips, and the optional supervisor
- Evidence reviewed:
  - historical picker at `v0.1.3` / `6ee7afc`, especially `scripts/switcher.sh`, `README.md`, and `tests/test_switcher.sh`;
  - the interaction commits `6e27cd4`, `7864f66`, and `4891290`;
  - the current `fdc107d` implementation and its real tmux/fzf regression suite;
  - live tmux state on 2026-08-11: 46 panes, 14 process/registry-detected AI panes, but only 2 pane-backed unread lifecycle marks;
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
- Make `Ctrl-i` an actionable AI inbox, not a process monitor.
- Ensure every visible result can switch to one real live pane.
- Keep the popup fast and predictable at 40–100+ panes.

Non-goals:

- Listing every `claude`, `codex`, `kimi`, or `opencode` process in the inbox.
- Auto-killing or closing user panes because an agent appears idle or finished.
- Showing paneless/background sessions as fake tmux destinations.
- Replacing the existing notifier, registry, supervisor, or fzf dependency.
- Rewriting the picker as a native Go TUI.

Success signals:

- For equivalent contiguous matches, a match that begins in the window name
  ranks before the same text found only in pane title, command, session label,
  or working directory. Search still follows fzf relevance for non-equivalent
  fuzzy matches; the UI does not pretend to implement a hidden weighted index.
- `Ctrl-t`, `Ctrl-r`, `Ctrl-i`, and `Ctrl-e` work through real tmux key events
  with the installed fzf version.
- On the 2026-08-11 live fixture, Inbox shows the 2 unread pane-backed events,
  not the 12 additional process-only `ACTIVE` shells.
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
| **Inbox** | Which AI result or request needs me? | Pane-backed unread lifecycle events only | ACTION, DONE, NOTICE; newest first within level |
| **Tree** | Where is this work in tmux? | Session → window; panes appear on drill-down | canonical tmux server order |

Compatibility aliases may remain at the CLI boundary: `needinput` → Inbox and
`all` → Tree. User-facing copy uses only Recent, Inbox, and Tree.

### Object model

- **Session** contains window links and has one current window/pane.
- **Window** is the primary named navigation object and has one active pane; a
  linked window may appear under more than one session in Tree but only once in
  Recent.
- **Pane** is the exact terminal destination and preview source.
- **Inbox event** is an unread lifecycle mark attached to a live pane.
- **Registry/process evidence** proves lifecycle and liveness; it is supporting
  machinery, not an inbox item by itself.

Every rendered row carries a stable `%pane_id` as its hidden target, captured
in the same bulk snapshot as the row's visible metadata:

- a session row targets that session's current live pane;
- a window row targets that window's active live pane;
- a pane row targets itself;
- an Inbox row targets the pane named by its unread mark.

Session and window targets are render-time snapshots, not late-bound aliases.
If a window's active pane changes while the picker is open, accepting the old
row still selects the `%pane_id` shown by that row. If that pane vanished, the
selection fails honestly instead of silently redirecting to a different pane.

There are no `__hdr__`, `__bg__`, or other non-switchable picker rows.
Hierarchy is presentation; destination identity is always a real pane.

## Design principles

1. **Names before coordinates.** User-authored window names are primary;
   `session:window.pane`, command, cwd, and process state are supporting evidence.
2. **Inbox means unread work.** A running or leftover AI process is not an
   interruption. Only an unread lifecycle event earns a `Ctrl-i` row.
3. **Complexity available, not mandatory.** Recent and Tree rest at window
   granularity; `Ctrl-e` reveals exact panes without making every scan dense.
4. **Every row goes somewhere.** Session, window, pane, and Inbox rows all
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
  - state words plus restrained icons in Inbox;
  - direct row jumps (`Alt-1`…`Alt-9`) as visible expert affordances.

Recommended row hierarchy:

```text
Recent: window-name    session:window[.pane]    title/state · command · ~/cwd
Tree:   ▾  8w ── session-name
          ├─  0 window-name             command · ~/cwd
          └─  7 multi-pane-window    3p · command · ~/cwd
```

Recent and Inbox keep the window name as the first displayed term. Tree uses a
structural prefix before the same primary identity: session count, branch rail,
and a two-column window index. The window name remains the first semantic search
term and begins before an equivalent session-name match. Tree does not repeat
`session:window`, `window · 1 pane`, or the parent window name on every child;
its hierarchy already communicates those relationships. Multi-pane counts use
compact `Np` metadata, while command and compact cwd provide recognition value.

## Components

- View switcher: `Ctrl-r` Recent, `Ctrl-i` Inbox, `Ctrl-t` Tree.
- Recent fast-switch focus: the current MRU window stays on row 1, while the
  initial cursor and every `Ctrl-r` view switch land on row 2—the previous
  window—so opening the picker and pressing `Enter` switches back immediately.
- Hierarchy drill-down: `Ctrl-e` toggles pane rows in Recent and Tree; Inbox is
  already pane-level and leaves the toggle unavailable.
- Result list: one hidden stable pane target plus two visible fields.
- Preview: the selected pane's recent output; Inbox adds event/registry details
  above the capture without becoming a second navigation surface.
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
  the previous window at row 2; Tree and Inbox start on row 1. Query changes
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

Run notifier cleanup synchronously before first render and Inbox reload. The
surface either publishes a coherent snapshot or reports a concise failure.

### Empty

- Recent/Tree with a reachable tmux server normally contain live destinations.
- Empty Inbox means: `Inbox clear — no unread AI event needs you.` It emits zero
  selectable rows; it does not invent a placeholder target.

### Success

Revalidate the stable pane ID, switch with one tmux client operation, record MRU
only after success, and clear only the selected pane's Inbox mark. Focusing one
pane must not clear unread sibling panes in the same window.

### Error

If the selected pane vanished or the switch failed, remain honest: concise
diagnostic, nonzero result, no raw tmux stderr, no partial navigation, and no
false MRU update.

### AI Inbox eligibility

Inbox inclusion is intentionally narrower than AI detection:

1. A normalized unread mark exists for a concrete `%pane_id`.
2. That pane is live in the current tmux snapshot.
3. The mark classifies as ACTION, DONE, or NOTICE.
4. ACTION/NOTICE liveness is checked by the notifier/registry GC before render;
   DONE may remain after the agent exits so the completed output can be reviewed.
5. Marks created through the public `mark` API are eligible when they meet the
   same pane-backed, live, ACTION/DONE/NOTICE contract.

Explicit exclusions:

- unmarked registry rows, even when their state is `working` or `done`;
- process/TTY/parent-chain matches without an unread mark;
- generic Claude/Codex shells and long-lived finished TUI processes;
- paneless/background marks and supervisor-only sessions.

The registry, process scan, and doctor remain valuable for GC and diagnostics.
They stop being list producers for `Ctrl-i`.

## Content voice

- Tone: terse, technical, calm.
- View terms: Recent, Inbox, Tree. Do not mix AI status, Attention, Need Input,
  and Inbox in the same user-facing surface.
- Actions: use outcome labels—`Enter switch`, `C-e panes`, `A-p preview`.
- Errors state what happened and the next useful action.
- Empty Inbox copy must say that no unread event needs the user; it must not
  claim there are no AI processes or panes.

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
5. Inbox emits only marked pane-backed ACTION/DONE/NOTICE rows; unmarked
   working/done registry rows and process-only detections stay absent.
6. In-range `Alt-N` and Enter switch to the exact stable pane target;
   out-of-range `Alt-N` before and after filtering leaves the picker open.
7. Session/window targets remain the rendered pane snapshot even when the
   active pane changes later; disappearance and switch failure are nonzero,
   concise, and atomic.
8. Two unread panes in one window remain independent: focusing one clears only
   that pane's event, while `Ctrl-e` inside Inbox is a structural no-op.
9. Cleanup failure, malformed mark input, missing tmux/fzf, fzf no-match, and
   user cancellation remain distinguishable from an honestly empty Inbox.
10. A 100-pane fixture is complete and proves the producer uses no more than
    one bulk window call plus one bulk pane call per reload.
11. Linked windows appear once per session link in Tree, once per underlying
    window in Recent, and never duplicate pane leaves within one link/group.
12. Entering and leaving an empty Inbox updates and removes the empty-state
    header in the same atomic fzf reload transaction.
13. Hook migration preserves pre-existing foreign indexed hooks.
14. Bash syntax, ShellCheck, all repository shell suites, Go test/vet/build, and
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

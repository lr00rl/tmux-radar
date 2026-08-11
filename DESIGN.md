# tmux-radar interaction design

This document is the UI decision source for the pane-first redesign approved in
`.omx/plans/tmux-switcher-redesign.md`. Where current README wording describes
the legacy window-first picker, this contract governs the migration target.

## Product job

tmux-radar is a **pane switcher** for large tmux workspaces. Its primary job is:

> Find one live pane, understand enough context to choose it, and switch to that
> exact pane.

Every selectable row must complete that job. Status, lifecycle, and supervisor
features may help prioritize panes, but they must not introduce a second pane
list or a selectable item that cannot switch.

## Scope model

The picker has three views over the same live-pane model:

| Scope | User question | Resting order |
| --- | --- | --- |
| **Recent** | Where was I working? | Pane MRU, newest first and deduplicated; unrecorded live panes follow in canonical server order. |
| **Attention** | Which detected AI pane should I review? | ACTION, DONE, NOTICE, then ACTIVE. Equal marked states use newest event first, then canonical target; ACTIVE uses canonical target. |
| **All** | Where is a pane I can identify? | Canonical session, window index, and pane index order. A nonempty query may apply fzf relevance sorting. |

The current pane remains visible in Recent. Cursor placement may initially prefer
the first other pane, but it must not change the data order or hide the current
pane.

`tree` remains a compatibility alias for All, and `needinput` remains a
compatibility alias for Attention during migration. Invalid view names fall back
to Recent.

## Row and target contract

Each producer emits exactly three tab-separated fields:

```text
<target>\t<search-display>\t<meta-display>
```

1. **Target** is the hidden stable tmux pane ID (`%N`). It identifies one live
   pane when the row is emitted and does not change when pane coordinates are
   reused.
2. **Search display** is the primary readable identity. It includes the
   session/window/pane location and window/pane title. Attention leads with the
   semantic state and agent kind.
3. **Meta display** is secondary context such as command, path, age, and event
   reason.

fzf hides field 1, searches fields 2–3, and returns the untouched complete row.
Selection extracts only field 1. Display text and mutable pane coordinates
never participate in target parsing.

Tabs, newlines, carriage returns, and unsafe control characters originating in
tmux or user-controlled display values are normalized to spaces before rows are
emitted. Truncation may protect layout, but must preserve the distinguishing
location and semantic state.

### Visual hierarchy

- Location and title identify the destination; they remain readable without
  color.
- Attention state uses both a word (`ACTION`, `DONE`, `NOTICE`, `ACTIVE`) and an
  optional icon/color. Color is never the only state signal.
- Command, path, age, and reason are dimmer secondary evidence. They must not
  overpower the destination identity.
- Alignment is helpful but not contractual; narrow terminals may wrap or
  truncate secondary content rather than hide the target identity.

## Interaction contract

The picker opens on the configured canonical scope, or on an explicitly passed
scope such as `menu attention`.

| Key | Action |
| --- | --- |
| type | Search visible identity and metadata. |
| `Ctrl-r` | Recent. |
| `Ctrl-i` | Attention. |
| `Ctrl-t` | All. |
| `Ctrl-n` / `Ctrl-p`, arrows | Move selection using fzf navigation. |
| `Alt-p` | Toggle preview. |
| `Shift-↑` / `Shift-↓` | Scroll preview by line. |
| `PgUp` / `PgDn` | Scroll preview by page. |
| `Enter` | Revalidate and switch to the selected exact pane. |
| cancel / `Esc` | Close without switching or reporting success. |

`Ctrl-e` expand/collapse and `Alt-1` through `Alt-9` row jumps are not part of
the pane-first design. Views differ by scope and ordering, not by whether pane
rows are expanded beneath window rows.

The existing `prefix + Tab` cross-session pane-MRU toggle is a complementary
fast path and remains independent of the searchable picker.

## Preview

Preview is supporting evidence, never a second navigation model. It shows the
selected pane's recent content and, when available, its Attention state. Preview
failure must not mutate selection. If a pane disappears, preview may show an
unavailable state while final selection still performs authoritative
revalidation.

## Empty and error states

### Empty Attention

No detected AI pane means zero selectable rows. The persistent header explains
that `0/0` means no detected AI pane. Paneless/background marks may remain in
the notifier or supervisor surfaces, but do not become fake targets in the
switcher.

### Pane disappears before selection

Immediately before switching, tmux-radar revalidates the exact pane ID with
tmux. If it is gone:

- show one concise message: `pane closed; reopen the switcher`;
- return non-success;
- expose no raw tmux error; and
- perform no partial session, window, or pane switch.

### Switch command fails after revalidation

A later tmux failure is also explicit and non-successful. Raw command stderr is
not dumped into the picker, and the UI must not claim completion. Navigation is
structured to avoid a partially applied session/window change.

Missing fzf or a missing tmux server is an operational error, not an empty
workspace. It receives a concise actionable diagnostic and a nonzero result.

## Accessibility and readability

- State and selection meaning are available in text, not color alone.
- Search covers the fields users can see.
- Keyboard help is short enough to remain readable at common popup widths.
- Dynamic age or process metadata must not cause the destination identity to
  jump unpredictably.
- Sanitization prevents control sequences in titles, paths, or commands from
  altering row structure or terminal behavior.
- Empty and failure outcomes are distinguishable from cancellation and success.

## Supporting-system boundary

The lifecycle registry, notifier hooks, persistent status bar, MRU recorder,
and preview are inputs or accelerators for the pane switcher. They do not own a
separate selectable-pane rendering contract.

The AI supervisor is optional and secondary. It may control agents, display
audits, and report paneless sessions. Its **list panes** action opens the same
searchable Attention picker used by `Ctrl-i`. The legacy `ai.sh list` entry is a
deprecated thin proxy to that picker rather than an independent scanner or
static renderer. The supervisor engine itself is outside this redesign and is
not removed.

## Evidence and assumptions

### Observed evidence

- The current shell/fzf picker already supports live preview, view transforms,
  exact pane selection when given a pane row, and pane-MRU recording.
- Existing registry and notifier paths combine lifecycle records with TTY and
  parent-chain process mapping, including wrapped/versioned agent processes.
- The current static AI list duplicates that detection and can fall back to an
  incomplete command set; convergence removes that drift.
- Current Tree and collapsed Recent rows are window-first, while Attention is
  pane-first. The mixed granularity creates ambiguous switching and additional
  expand/numeric-jump interaction state.

### Design assumptions to validate

- fzf remains available as the picker dependency and can preserve the hidden
  target field while searching visible fields.
- Stable `%N` pane IDs remain authoritative for a picker interaction even when
  tmux reuses a visible `session:window.pane` coordinate.
- Pane MRU is a better match for the product job than legacy window MRU.
- Removing direct numeric jumps and expand/collapse reduces interaction cost
  without removing an essential accessibility path; ordinary fzf navigation
  remains available.
- Large workspaces remain responsive. Isolated fixtures with multiple sessions,
  multiple windows, and at least 30 panes are the minimum regression scale, not
  a performance ceiling.

## Non-goals

- Rewriting the picker as a native Go TUI.
- Removing the optional supervisor engine.
- Treating paneless AI sessions as tmux navigation targets.
- Adding dependencies or a second picker framework.
- Changing lifecycle-hook or registry contracts beyond what pane-list
  convergence requires.

## Design invariants

1. Every selectable row maps to one live pane when emitted.
2. Every scope uses the same three-field target/display contract.
3. Attention is a priority view over panes, not a separate list product.
4. Selection either reaches the exact pane or fails explicitly without partial
   navigation.
5. Empty, cancelled, failed, and successful outcomes remain distinguishable.
6. Optional supervisor behavior cannot dominate or fork the core switcher UX.

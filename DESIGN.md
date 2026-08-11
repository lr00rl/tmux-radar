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
| **Recent** | Where was I working? | Only live panes recorded in pane MRU, newest first and deduplicated. Missing or empty MRU is empty. |
| **Attention** | Which detected AI pane should I review? | Live AI panes only: ACTION, DONE, NOTICE, then ACTIVE. A mark alone is not liveness evidence. |
| **Tree** | Where is a pane I can identify? | Fully expanded session → window → pane hierarchy in canonical server order. |

`all` is accepted only as an input compatibility alias for Tree, and
`needinput` remains a compatibility alias for Attention. UI copy names only the
three canonical views. Invalid view names fall back to Recent.

## Row and target contract

Each producer emits exactly three tab-separated fields:

```text
<target>\t<search-display>\t<meta-display>
```

1. **Target** is the hidden stable tmux pane ID (`%N`) for selectable pane
   leaves. Tree session/window rows use non-pane structural keys and accepting
   them is a clean no-op.
2. **Search display** is the primary readable identity. Pane rows begin with
   the sanitized user-assigned window name, followed by location and pane
   title. Attention puts semantic state and agent kind in metadata.
3. **Meta display** is secondary context such as command, path, age, and event
   reason.

fzf hides field 1, searches fields 2–3, and returns the untouched complete row.
Relevance uses `--tiebreak=begin,index`: beginning matches beat later metadata
matches, while empty-query ties retain input order.
Selection extracts only field 1. Display text and mutable pane coordinates
never participate in target parsing.

Attention accepts a positive registry PID only while its recorded argv identity
still matches. An unresolved PID (`0`) is not liveness: it requires independent
TTY/parent-chain process evidence for that pane. If a process scan is
unavailable, unresolved state may be retained for a later GC pass but is not
rendered as a live pane.

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
| `Ctrl-t` | Tree. |
| `Ctrl-n` / `Ctrl-p`, arrows | Move selection using fzf navigation. |
| `Alt-p` | Toggle preview. |
| `Shift-↑` / `Shift-↓` | Scroll preview by line. |
| `PgUp` / `PgDn` | Scroll preview by page. |
| `Enter` | Revalidate and switch to the selected exact pane. |
| cancel / `Esc` | Close without switching or reporting success. |

`Ctrl-e` expand/collapse and `Alt-1` through `Alt-9` row jumps are not part of
the pane-first design. Tree is always fully expanded; its session/window rows
provide context and are never selectable destinations.

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
The synchronous notifier cleanup is part of the same render transaction: if it
cannot acquire state or otherwise fails, the initial render/reload aborts
instead of publishing possibly stale rows.

Pane titles are restored only from a mark-owned saved title (falling back to
window name, then current command when that saved field is empty). A status-like
glyph prefix by itself is never treated as ownership, so user-authored titles
such as `✓ release` are not rewritten.

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
- Tree needs structural context, while Recent and Attention are pane-only.
  Keeping only Tree's session/window rows non-accepting avoids ambiguous
  switching without adding expansion state.

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
2. Every scope uses the same three-field target/display contract; only pane
   leaves carry selectable `%N` targets.
3. Attention is a priority view over panes, not a separate list product.
4. Selection either reaches the exact pane or fails explicitly without partial
   navigation.
5. Empty, cancelled, failed, and successful outcomes remain distinguishable.
6. Optional supervisor behavior cannot dominate or fork the core switcher UX.

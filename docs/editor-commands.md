# Editor commands, multi-caret ergonomics and typing behaviour

The editor face's editing verbs live in `src/editor/commands.zig`
(GTK-free, unit-tested in both test roots); the GTK dispatch, the
binding table and the context menu live in `src/ui/editorview.zig` and
`src/ui/editormenu.zig`. Every command builds ONE transaction through
`Document.applyTransactionSel`, so each invocation is exactly one undo
step -- across any number of carets -- and undo restores the pre-command
selection.

## Commands and default bindings

Bindings are configurable as `editor_keybind.<command> = <accel>`
lines (GTK accelerator syntax; empty value unbinds), editable on the
Preferences -> Keybindings page under "Editor Commands". They are a
separate namespace from `keybind.*` on purpose: they exist only while
the editor canvas has focus and can never shadow or consume a terminal
key. Defaults follow VS Code / Sublime muscle memory where one exists.

| Command | Default | Notes |
| --- | --- | --- |
| `duplicate_line_up` | Shift+Alt+Up | Caret line (or selection); caret stays on the upper copy (VS Code Copy Line Up) |
| `duplicate_line_down` | Shift+Alt+Down | Caret rides the lower copy |
| `move_line_up` | Alt+Up | Line blocks under carets/selections swap with their neighbour; blocks that touch merge; edge blocks stay put |
| `move_line_down` | Alt+Down | |
| `join_lines` | Ctrl+J | Sublime/JetBrains chord; next line's leading whitespace collapses to one space |
| `sort_lines` | F9 | Sublime chord; byte-order sort of each selection's lines; caret-only is a status-line no-op |
| `toggle_comment` | Ctrl+/ | See below |
| `indent` | Ctrl+] | Also: Tab with a non-empty selection |
| `dedent` | Ctrl+[ | Also: Shift+Tab always |
| `trim_trailing_ws` | Ctrl+Alt+T | Whole document, one undo step |
| `upper_case` | Ctrl+Alt+U | Selection, or the word at each caret |
| `lower_case` | Ctrl+Alt+L | |
| `title_case` | Ctrl+Alt+I | |
| `goto_line` | Ctrl+G | Dialog; accepts `line` or `line:column` (1-based) |
| `select_next_occurrence` | Ctrl+D | Caret grows to its word first; then adds the next literal match, wrapping |
| `skip_occurrence` | Ctrl+Alt+D | Drops the newest occurrence and takes the next match (VS Code's Ctrl+K Ctrl+D is a chord sequence, which the binding table does not model) |
| `select_all_occurrences` | Ctrl+Shift+L | Match count reported on the status line |
| `add_caret_above` | Ctrl+Alt+Up | Byte column, clamped to the target line |
| `add_caret_below` | Ctrl+Alt+Down | |
| `split_selection_lines` | Shift+Alt+I | One caret at the end of each covered line |

Escape collapses back to the primary caret (pre-existing). All
commands appear in the command palette (Ctrl+Shift+P) whenever the
focused pane wears an editor face; the palette rows show the active
binding and dispatch through the same `runCommand` path as the keys.

Occurrence matching is literal and case-sensitive; there is no
whole-word restriction carried from a word-grown start (documented
simplification).

## Comment toggle

The comment prefix comes from the document's RESOLVED language -- the
same `syntax.detect` (extension, then shebang) that picks the
Tree-sitter grammar, via `Lang.lineComment()` -- never from a second
extension table. It works even with `editor_syntax = false` (the
prefix is a fact about the file, not about highlighting).

* Zig and C: `//`. JSON and Markdown: none -- JSON has no comments per
  spec and Markdown only has HTML block comments, so the command
  reports "This language has no line-comment syntax." on the status
  line and does nothing. An unknown file type reports likewise.
* Mixed selections: if every covered non-blank line already starts
  (after leading whitespace) with the prefix, the block uncomments
  (prefix plus one following space removed); otherwise every non-blank
  line is commented at its first non-whitespace column with
  `<prefix> `. Blank lines are always skipped.
* Lines covered by several carets/selections are processed once.

## Column / block selection

Implemented, as Shift+Alt+drag on the canvas: one range per line
between the press corner and the pointer, in BYTE columns, clamped to
each line's content and snapped to UTF-8 boundaries. It fits the
selection model cleanly because a block IS a set of per-line ranges --
exactly what the multi-selection machinery already edits and maps.
Two deliberate limits, both consequences of keeping the model free of
virtual positions: there is no virtual space (a short line contributes
a caret at its end rather than a padded column), and columns are byte
columns, so a tab counts as one column rather than its rendered width.

## Typing behaviour

All three are app-level config keys, default on, with switch rows on
the Preferences -> Editor page ("Typing" group):

* `editor_auto_indent` -- Enter copies the current line's leading
  whitespace (clipped to the caret column) and goes ONE indent unit
  deeper when the character immediately left of the caret is `(`, `[`
  or `{`. When the character right of the caret is the matching
  closer, the closer drops onto its own line at the original depth and
  the caret lands on the indented middle line. That is the whole
  extent of its structure understanding: bracket adjacency, not a
  tree walk -- it does not consult Tree-sitter, does not understand
  `else`/`case` dedenting, continuation lines, or language-specific
  indent rules. Off falls back to the plain copy-previous-indent.
* `editor_auto_close_pairs` -- `( [ { " ' \`` insert their closer with
  the caret between; typing a closer that is already the next
  character moves past it instead (type-over, no edit, no undo entry);
  Backspace between an empty pair deletes both halves; typing an
  opener over a selection surrounds it (selection preserved inside).
  Deliberate refusals (the feature must never fight the user):
  nothing happens when the next character is a word character; quotes
  additionally refuse after a word character or the same quote (so
  `it's` never becomes `it''s`), and refuse where the grammar says the
  caret is inside a string or comment (`Highlighter.kindAt`; no
  grammar gates nothing). With several carets, a behaviour applies
  only when EVERY caret qualifies -- a mixed set falls through to a
  plain character insert. Paste, IPC inserts and multi-byte IM commits
  are never intercepted.
* `editor_smart_backspace` -- Backspace with the caret in a line's
  leading SPACES deletes back to the previous `editor_tab_width` stop.
  A prefix containing tabs deletes normally (a tab is already one
  unit). Mixed carets share one transaction: qualifying carets retreat
  a stop, the rest delete one grapheme.

Indent/dedent (and auto-indent's unit) respect `editor_insert_spaces`
and `editor_tab_width`.

## Context menu

Right-click on the editor canvas (`src/ui/editormenu.zig`, the
`ui/menu.zig` popover idiom). A click outside every selection moves
the caret there first, like every editor. Contents:

* Cut / Copy / Paste / Select All -- Cut and Copy are insensitive with
  no selection.
* Toggle Line Comment (insensitive when the language has no line
  comment), a Line submenu (Duplicate Down, Move Up/Down, Join, Sort,
  Indent, Dedent, Trim Trailing Whitespace; Sort insensitive without a
  selection) and a Change Case submenu.
* Go to Definition / Find References / Rename Symbol / Format
  Document / Code Actions -- present ONLY while a language server is
  attached to the document (hidden, not greyed, when not).
* A Folding submenu (Fold/Unfold Region, Fold/Unfold All), insensitive
  when `editor_folding` is off.
* Find... / Replace... / Go to Line....

Everything dispatches through `EditorView.menuAction`, which reuses
`runCommand` for the command-backed rows -- no second implementation.

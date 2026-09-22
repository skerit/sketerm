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
| `indent_use_tabs` | -- | Per-tab override: indent with hard tabs (see "Indentation") |
| `indent_use_spaces` | -- | Per-tab override: indent with spaces |
| `indent_width_2` / `_4` / `_8` | -- | Per-tab override of the indent (and tab) width |
| `indent_auto` | -- | Drop the tab's override and re-read `.editorconfig` and the content |

Escape collapses back to the primary caret (pre-existing). All
commands appear in the command palette (Ctrl+Shift+P) whenever the
focused pane wears an editor face; the palette rows show the active
binding and dispatch through the same `runCommand` path as the keys.

Occurrence matching is literal and case-sensitive; there is no
whole-word restriction carried from a word-grown start (documented
simplification).

## Comment toggle

The comment tokens come from the document's RESOLVED language -- the
language registry row (`src/editor/languages.zig`) that detection picked,
the same row that picks the grammar and the LSP `languageId` -- never
from a table of its own. It works with `editor_syntax = false` and for
languages with no grammar at all (the tokens are a fact about the file,
not about highlighting).

* A language with a line comment toggles that token: `//` (Zig, C, C++,
  Rust, Go, Java, JavaScript, TypeScript, ...), `#` (Python, shell,
  Ruby, YAML, TOML, Makefile, ...), `--` (Lua, SQL, Haskell), `;`, `%`.
* A language with only a block comment wraps each non-blank line in the
  pair instead: `/* ... */` (CSS), `<!-- ... -->` (HTML, XML, Markdown),
  `(* ... *)` (OCaml). A line uncomments when it starts with the opener
  and ends with the closer.
* JSON has no comments per its spec, so the command reports "This
  language has no comment syntax." on the status line and does nothing
  (JSONC -- `tsconfig.json`, `.jsonc` -- toggles `//`). An unknown file
  type reports likewise.
* Mixed selections: if every covered non-blank line is already
  commented, the block uncomments (token plus one adjacent space
  removed); otherwise every non-blank line is commented at its first
  non-whitespace column. Blank lines are always skipped.
* Lines covered by several carets/selections are processed once.

## Languages

`src/editor/languages.zig` declares ONE row per language: its name, LSP
`languageId`, extensions, exact filenames and `*` filename patterns,
shebang interpreters, first-line signatures, comment tokens, string and
character literal rules, grammar layers, fold fallback and tab policy.
Detection, toggle-comment, the LSP `languageId`, the lexical bracket
matcher and the fold fallback all read that row; adding a language is
adding a row.

Detection order: exact filename (`Makefile`, `tsconfig.json`), filename
pattern (`Dockerfile.*`), an ambiguous extension settled by the head
(`.h` is C unless it reads as C++: `class`, `namespace`, `template<`,
`std::`, ...), the extension, the shebang (`#!/usr/bin/env python3`,
version suffixes accepted), then a first-line signature (`<?xml`,
`diff --git`). Nothing matched is plain text.

With a Tree-sitter grammar (highlighting, tree brackets, tree folds, the
tree-based outline): Zig, C, C++ (and CUDA), JSON/JSONC, Markdown,
Python, Rust, JavaScript/JSX, TypeScript, TSX, Shell (bash/sh/zsh),
Go, HTML, CSS, TOML, YAML, Lua, Makefile, Java, Diff/patch, XML (and
SVG, plists, MSBuild files) and Dockerfile. `src/editor/grammars.zig`
pins each grammar's upstream commit and archive checksum; the build
downloads them on first use (`vendor/tree-sitter/PROVENANCE.txt`).

Without a grammar (comment toggling, string-aware brackets, bracket or
indentation folds, the LSP `languageId`): Objective-C/C++, SCSS, Less,
Ruby, PHP, C#, Kotlin, Swift, Scala, Dart, Groovy, Haskell, OCaml,
Elixir, Erlang, Clojure, Lisp/Scheme, Perl, R, Julia, SQL, Nix, HCL,
CMake, INI/systemd units, properties/.env, PowerShell, Fish, AWK,
Protocol Buffers, GraphQL, LaTeX, GLSL/HLSL/WGSL, git commit messages,
git rebase todos and ignore files.

When there is no usable syntax tree (no grammar, `editor_syntax = false`,
or a tree that lags the text), `src/editor/lexical.zig` lexes the row's
comment and string rules so bracket matching and bracket folding skip
`"a ( b"` and `// )`, and the quote auto-close gate knows a string from
code. It is not a tokenizer: regex literals, heredocs and raw strings
with custom delimiters are outside what a row describes.

What each grammar costs (measured 2026-09-23 on the 10-core build box
at load average ~10: one `zig cc -O2` per source file with a cold cache,
serially; "binary" is the grammar's text+data in the executable):

| Grammar | parser.c | Compile | Binary |
| --- | --- | --- | --- |
| C++ | 25 MB | 4.5 s | 5.4 MB |
| Bash | 9.6 MB | 2.9 s | 1.3 MB |
| TSX | 8.5 MB | 2.6 s | 1.4 MB |
| TypeScript | 8.4 MB | 2.4 s | 1.4 MB |
| Rust | 6.3 MB | 2.0 s | 1.1 MB |
| Python | 3.4 MB | 1.5 s | 0.44 MB |
| Makefile | 0.9 MB | 1.5 s | 0.16 MB |
| JavaScript | 2.8 MB | 1.3 s | 0.40 MB |
| Java | 2.5 MB | 0.9 s | 0.40 MB |
| YAML | 1.3 MB | 0.8 s | 0.18 MB |
| Dockerfile | 0.25 MB | 0.7 s | 0.06 MB |
| Go | 1.5 MB | 0.6 s | 0.21 MB |
| XML | 0.23 MB | 0.6 s | 0.04 MB |
| CSS | 0.5 MB | 0.6 s | 0.10 MB |
| HTML | 0.06 MB | 0.6 s | 0.02 MB |
| TOML | 0.13 MB | 0.5 s | 0.02 MB |
| Lua | 0.35 MB | 0.5 s | 0.05 MB |
| Diff | 0.14 MB | 0.4 s | 0.04 MB |

Together that is 25 s of serial compile on a cold cache (the libraries
build in parallel, so a build with free cores waits about as long as
C++ alone) and 13.2 MB of executable: the stripped ReleaseFast
`sketerm` went from 14.0 MB to 27.2 MB, C++ being 40% of the growth.
`sketerm-mux` is unchanged (4.4 MB, libc only).

Ruby was measured and not added (15 MB parser.c, 3.2 s, 2.0 MB); it
keeps the lexical fallback.

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
  caret is inside a string or comment (`Highlighter.kindAt`; without
  a current tree the language's lexical rules answer, and plain text
  gates nothing). With several carets, a behaviour applies
  only when EVERY caret qualifies -- a mixed set falls through to a
  plain character insert. Paste, IPC inserts and multi-byte IM commits
  are never intercepted.
* `editor_smart_backspace` -- Backspace with the caret in a line's
  leading SPACES deletes back to the previous indent stop (the tab's
  effective indent width, see "Indentation").
  A prefix containing tabs deletes normally (a tab is already one
  unit). Mixed carets share one transaction: qualifying carets retreat
  a stop, the rest delete one grapheme.

Indent/dedent, Tab, auto-indent's unit and the LSP formatting options
all use the tab's EFFECTIVE indentation (next section).

## Indentation

Every tab resolves its own indentation (`src/editor/indentation.zig`),
property by property, from the highest source that says anything:

1. the per-tab override (`indent_use_tabs`, `indent_use_spaces`,
   `indent_width_*` from the palette; `indent_auto` drops it),
2. a language that REQUIRES tabs (Makefile recipes: Tab inserts a hard
   tab however the project is configured),
3. `.editorconfig`,
4. the document's own content,
5. a language that PREFERS tabs (Go, as gofmt writes),
6. the global `editor_insert_spaces` / `editor_tab_width`.

The status line shows the result and its source, e.g.
`Python, Spaces: 4 (detected)` or `Makefile, Tabs: 4 (language)`.

Content detection reads the first 4000 lines (256 KB): tabs win when
more indented lines start with a tab than with spaces; otherwise the
width is the most frequent change in indentation between consecutive
lines, among 2, 3, 4, 6 and 8 (a step of 1 is ignored -- it is almost
always a C block comment's ` * `).

`.editorconfig` follows the spec (https://spec.editorconfig.org): every
file from the document's directory up to `/` is consulted until one says
`root = true`; nearer files override farther ones and later sections
override earlier ones; a section glob without `/` matches the file name
in any directory below the `.editorconfig`, one with `/` is anchored to
it; `*`, `**`, `?`, `[set]`, `[!set]`, `{a,b}` (nested) and `{n..m}`
are supported; `unset` clears a property. The files are read through the
daemon file service in one pipelined round trip when the document
loads, so a remote document resolves against the remote host's files
exactly like a local one does.

| Property | Effect |
| --- | --- |
| `indent_style`, `indent_size`, `tab_width` | The indentation above (`indent_size = tab` takes `tab_width`; a numeric `indent_size` implies `tab_width`). |
| `end_of_line` | `lf` / `crlf` decide how the document is written on save. `cr` is not a style the editor writes and is ignored. |
| `charset` | `utf-8-bom` adds a missing BOM on save, `utf-8` removes one. The editor reads and writes UTF-8 only, so `latin1` and `utf-16*` are ignored. |
| `trim_trailing_whitespace` | `true` strips trailing spaces and tabs on save. |
| `insert_final_newline` | `true` adds a missing final newline on save; `false` removes trailing newlines. |
| `max_line_length` | Read but unused: the editor draws no ruler. |

The save-time rules apply as ONE edit before the save snapshot, so a
single undo restores the buffer as it was typed.

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

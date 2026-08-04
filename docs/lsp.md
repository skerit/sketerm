# Language Server Protocol

sketerm's editor is an LSP client. This document is the architecture and
the user-facing surface; the invariants that will bite you are repeated
in `src/lsp/`'s module headers.

## Layering

```
src/lsp/rpc.zig          base protocol: Content-Length framing, JSON-RPC envelopes
src/lsp/position.zig     UTF-8 byte offsets <-> LSP positions in utf-8/16/32
src/lsp/servers.zig      server registry data, languageId table, root resolution, file:// URIs
src/lsp/session.zig      lifecycle, capabilities, document sync, request bookkeeping, cancellation
src/lsp/docsync.zig      per-document version counter + the didChange queue
src/lsp/diagnostics.zig  diagnostics as anchored byte ranges
src/lsp/proc.zig         fork/exec with non-blocking stdio pipes (libc only)
src/ui/editorlsp.zig     the ONLY GTK part: fd watches, popups, every feature
```

Everything above `editorlsp.zig` is GTK-free and lives in **both** test
roots (`src/tests.zig` and `src/tests_core.zig`). `session.zig` never
touches a file descriptor: bytes come in through `feed()` and go out into
`out`, which is what lets `src/lsp/session_test.zig` drive the entire
protocol from a scripted in-process server.

`sketerm-mux` links libc only, and nothing here changes that: the daemon
imports `config.zig`, which imports `lsp/servers.zig` — pure `std`, no
GTK, no GLib. `zig build mux-portable` + `ldd zig-out/bin/sketerm-mux`
are the checks.

## Transport

JSON-RPC over the server's stdio with `Content-Length` framing, the
standard. The child is forked with three pipes, all non-blocking:

* **stdout** is watched with `g_unix_fd_add(G_IO_IN|G_IO_ERR|G_IO_HUP)`,
  exactly like the mux socket. Never a blocking read, never a worker
  thread — the GUI is single-threaded.
* **stdin** is written directly; a `G_IO_OUT` watch is installed **only**
  when a write comes up short, and removed again when the queue drains.
* **stderr** is drained and the last line kept for the status line. It
  has to be drained: a server whose stderr pipe fills stops serving.

The child gets its own process group, so killing it kills whatever build
tooling it spawned.

A server that is not installed is never spawned (`proc.onPath`), and a
server whose `exec` fails shows up as immediate EOF on stdout, which is
the same "dead" path as a crash. Both are silent.

## Remote documents: a documented follow-up, not in this change

A language server must run **near the files**. For a document opened from
a remote host (`box:/path`), that means the server has to run on `box`,
which means `sketerm-mux` spawning it and tunnelling its stdio — a new
frame type plus process management in the daemon's poll loop.

That is not in this change. `Manager.attachTab` therefore **refuses a
host-qualified spec outright**: running a local server against a remote
path would resolve every import against the wrong filesystem and produce
confidently wrong diagnostics and jumps.

The structure is prepared for it: `Conn` owns a `proc.Child` and a
`session.Session`, and only `pumpWrite`/`onReadable` know that the
transport is a local pipe. A remote `Conn` replaces those two with the
daemon's byte-channel frames (`chan_open`/`chan_data`/`chan_close`,
already multiplexed over every mux transport) and everything else —
lifecycle, capabilities, sync, staleness, every feature — is unchanged.
The daemon-side piece must stay libc-only; `src/lsp/proc.zig` already is,
so it can move there as-is.

## Position encoding

LSP `character` counts **UTF-16 code units** by default: an astral-plane
codepoint (emoji) is 4 UTF-8 bytes, 1 codepoint and **2** characters.
`src/lsp/position.zig` converts in both directions for utf-8, utf-16 and
utf-32, clamps to the line's end (servers send end-of-line positions well
past it), and resolves a `character` landing inside a surrogate pair to
the codepoint's start.

We advertise `general.positionEncodings: ["utf-8","utf-16"]` and honour
whatever the server picks in its `initialize` result, so a server that
offers utf-8 gets byte offsets and no conversion cost.

The unit tests round-trip **every** codepoint boundary of a document
mixing ASCII, Latin-1, CJK and emoji through all three encodings, and the
smoke rig runs its whole end-to-end stage twice, once per encoding.

## Document sync

`textDocument/didOpen` on load, `didChange` incrementally when the server
asks for it (`textDocumentSync.change == 2`), full text otherwise,
`didSave` after a successful save, `didClose` when the tab closes.

The incremental ranges are captured in a **pre-edit document observer**
(`Document.observers` slot 2 — see the array's doc comment). They have to
be: a range is in the coordinates the server still holds, and once the
rope has been mutated those positions are gone. This is the same reason
the Tree-sitter highlighter has slot 0.

A transaction's edits are queued in **descending** offset order.
`Transaction.edits` are ascending in pre-transaction coordinates and the
document applies them back-to-front; LSP applies `contentChanges` in
array order, each against what the previous ones produced. Descending
reproduces the document's own application exactly, so no range needs
adjusting for its predecessors.

If a capture ever fails (out of memory), the document is flagged
`needs_full` and the next flush resends the whole text. Silently dropping
a change would desynchronise the server for the rest of the session.

## Staleness

Every request records the document `revision` it was built against, and
the answer carries it back. A response whose revision no longer matches
the document is **dropped** — this is the same discipline
`editor/syntax.zig` uses for parse results. Concretely:

* completion, hover: dropped (their ranges describe text that is gone);
* formatting: refused with "Document changed while formatting";
* diagnostics: **not** dropped. They are the one long-lived result, so
  they are converted once to byte offsets and then carried through every
  subsequent edit by `Store.mapThrough` — the same `tr.mapOffset`
  primitive selections and fold anchors use. A publish replaces the set
  wholesale.

## Debounce and cancellation

* **didChange** is debounced by `editor_lsp_debounce_ms` (default
  **250 ms**) after the last keystroke. Any feature request flushes the
  queue **first**, so an answer always describes the text on screen —
  the debounce trades server CPU against how fresh diagnostics feel, and
  nothing else.
* **completion** re-requests **120 ms** after a keystroke while the popup
  is open, and immediately on an explicit Ctrl+Space or a server-declared
  trigger character.
* A new request of a kind **cancels** the in-flight one for that tab with
  `$/cancelRequest` (`Session.cancelKind`). The cancelled request stays in
  the pending table until its answer arrives — the answer is consumed and
  dropped there, so no feature has to remember to check.
* Closing a tab drops its pending requests without a `$/cancelRequest`
  storm; `didClose` already told the server.
* Nothing is ever done per frame. The render pass reads a slice of
  already-computed byte ranges.

## Server-to-client requests

Answered, always. A server that waits on us stops serving the user.
`window/workDoneProgress/create`, `client/(un)registerCapability` and
`workspace/configuration` get `null` (an array of nulls, one per
requested section, for the last one); anything else gets a real
MethodNotFound error rather than silence.

## Features and how a user reaches them

Chords follow VS Code. They work identically in a pane's editor face and
in the standalone editor window, because both are one `EditorView`.

| Chord | Feature |
| --- | --- |
| — | **Diagnostics**: squiggles under the offending text, a coloured stripe at the left edge of the gutter, and the diagnostic under the caret in the status line |
| `F8` / `Shift+F8` | next / previous diagnostic |
| `Ctrl+Space` | completion (explicit); a trigger character opens it too |
| `Ctrl+I` | hover — also shows the diagnostic at the caret, even for a server with no hover provider |
| `F12` | go to definition |
| `Shift+F12` | find references |
| `Ctrl+F12` | go to type definition |
| `Ctrl+Shift+F12` | go to declaration |
| `Ctrl+Shift+O` | document symbols |
| `Ctrl+T` | workspace symbols (query = the word at the caret or the selection) |
| `F2` | rename |
| `Ctrl+Shift+I` | format document, or the selection when there is one |

**Popup behaviour.** One widget serves completion, results and symbols.
It is a `GtkPopover` with `autohide = false` pointed at the caret using
the **same** rectangle `setImCursorLocation` ships to the input method,
so a completion list and an IME candidate window can never disagree about
where the caret is. It deliberately does not take focus: the editor's own
key handler drives it (`Up`/`Down`/`PageUp`/`PageDown`/`Enter`/`Tab`/
`Escape`), which is what keeps typing flowing into the document while the
completion list follows the prefix. Symbols and results additionally
filter on typed characters. Completion documentation is fetched lazily
with `completionItem/resolve` for the selected row only.

**Navigation results** open in the **same** editor face as a tab, through
`EditorView.openSpecAtLineCol`, which reuses the ordinary tab machinery:
a file that is already open is focused rather than opened twice, and a
file that still has to load gets its caret placed once the async load
lands. A single result jumps straight there; several open the list.

**Rename** applies the server's `WorkspaceEdit` as **one transaction per
document** — one undo unit per file. Known limitation: the editor's
history is per `Document`, so a rename touching three files is three undo
units, one per file; a single cross-document unit would need a history
object nothing else in the editor wants. Files that are **not open** are
reported ("N not open") rather than edited behind the user's back.

**Formatting** folds the returned `TextEdit[]` into one transaction, so a
whole-file reformat is a single undo.

## Configuration

App-level, not per-profile: a language server serves a **language**, and
which pane profile a document happens to be open under says nothing about
that (the split CLAUDE.md describes for `ProfileSettings`).

```ini
editor_lsp = true              # master switch
editor_lsp_diagnostics = true  # squiggles + gutter stripe
editor_lsp_debounce_ms = 250

[lsp.zls]
args = --enable-debug-log

[lsp.clangd]
enabled = false

[lsp.tsserver]
command = typescript-language-server
args = --stdio
languages = typescript, typescriptreact, javascript, javascriptreact
root_files = tsconfig.json, package.json, .git
```

A `[lsp.<name>]` section whose name matches a built-in is **seeded from
that built-in** at parse time, so a section carrying only `args` keeps
the built-in's command, languages and root markers, and one carrying only
`enabled = false` still knows what it is switching off. A section always
replaces the built-in of the same name — a disabled section does not fall
through to it.

Built-ins ship for `zls` (Zig), `clangd` (C/C++/ObjC/CUDA) and
`rust-analyzer` (Rust). They are a fallback, not a policy.

Resolution picks the first server that both claims the language and is
actually **installed**, user sections before built-ins, so configuring a
fallback for a machine that lacks the first choice does the obvious
thing.

The workspace root is the nearest ancestor directory of the document
holding one of `root_files`, falling back to the document's own
directory. One server process is shared per (server, root) pair, and the
last tab out shuts it down (`shutdown`, then `exit`, then SIGKILL after
1.5 s).

The Editor page in Preferences carries the three switches plus one group
per server (enabled / command / arguments / languages / root markers) and
reports whether each command is on `PATH`. Editing a server there
materializes its `[lsp.<name>]` section; a server the user never touches
keeps no section and so keeps following the built-in.

## Degradation

A missing server is **silent**. No dialog, no error line, nothing in the
gutter. It becomes visible only where the user explicitly asked for a
feature, as a status-line message ("No language server for hover."). A
server that does not offer a capability says so the same way. A server
that dies takes its diagnostics down with it and the editor keeps working.

## Testing

* `zig build test-core` / `zig build test` — framing (including
  byte-at-a-time delivery and lost framing), position mapping in all
  three encodings, the registry and URI handling, the diagnostics store,
  the didChange queue, process spawn, and the whole session lifecycle
  against a scripted in-process server (`src/lsp/session_test.zig`).
* `zig build smoke-editor` — the LSP stage spawns
  **`sketerm-lsp-stub`**, a real child process speaking the base protocol
  over real pipes, and drives diagnostics, incremental sync, hover,
  definition, references, symbols, completion + resolve, rename and
  formatting through the production client. The stub maintains its **own**
  copy of the document from the `contentChanges` it receives and publishes
  diagnostics against it, so an off-by-one range makes the two copies
  diverge and the stage fail. The whole stage runs twice, once per
  position encoding, over a document full of astral-plane characters.

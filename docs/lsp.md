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
src/lsp/semantic.zig     the token legend, the packed data array, delta splicing
src/lsp/inlay.zig        inlay hints as (byte offset, text) pairs
src/lsp/proc.zig         fork/exec with non-blocking stdio pipes (libc only);
                         spawnSock = the daemon-side socketpair variant
src/mux/daemon.zig       handleLspOpen: remote spawn + root resolution + relay
src/ui/editorlsp.zig     the ONLY GTK part: fd watches, popups, every feature,
                         and RemoteLink (the per-host LSP transport)
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

## Remote documents: the server runs on the host that owns the files

A language server must run **near the files** — running a local server
against `box:/path` would resolve every include, project root and
`compile_commands.json` against the wrong filesystem and produce
confidently wrong answers. That rule survives unchanged; what changed
is that a host-qualified spec is now SERVED instead of refused: the
daemon on `box` spawns the server and this GUI stays the client.

**What crosses the wire is the server's own raw bytes.** The mux
protocol's "parsed events, never re-encoded escape sequences" rule
exists because terminal escape streams do not survive re-encoding;
JSON-RPC with Content-Length framing is already a structured,
length-delimited protocol, and the byte channels
(`chan_open`/`chan_data`/`chan_close`) are the wire protocol's
sanctioned generic stream (Wayland apps, audio, TCP forwards ride them
already, over every transport including roaming UDP). Parsing LSP in
the daemon only to re-serialize it would buy nothing and cost a second
LSP schema to keep in sync. The daemon never parses a single JSON-RPC
byte.

**The client stays in the GUI, whole.** One `Session` implementation
serves both transports; only `Conn.pumpWrite` and the link's frame
router know whether the far side is a pipe or a channel. Consequently
the per-server position-encoding negotiation and the revision-stamped
staleness discipline hold across the network hop by construction: the
`initialize` exchange happens over the relay exactly as over the pipe,
and revisions are stamped/checked entirely GUI-side (slower round
trips just mean more answers get dropped as stale — which is the
correct outcome). One deliberate difference: `Session.start` is given
pid 0 for a remote conn and sends `processId: null`, because our pid
means nothing on the server's host and clangd exits when the
advertised pid does not exist there. Lifetime is the daemon's job
instead (below).

**Discovery and roots are answered by the remote host.** `attachTab`
ships the config's ordered candidate list (name, command, args,
root_files) in one `lsp_open` frame together with the document's
directory; the daemon picks the first candidate whose command resolves
on ITS PATH, walks the directory's ancestors for the root markers on
ITS filesystem (falling back to the document's directory — the same
`servers.findRoot` semantics as local), spawns via a socketpair
(`lsp/proc.zig spawnSock`, libc-only) and answers `chan_open` (kind
`lsp`) plus `lsp_reply {req, ok, chan, name, root}`. `init_options`
stays client-side — it travels inside `initialize` anyway. Connections
are still deduplicated per (host, server, root): a reply naming a
(name, root) that already has a live conn closes the duplicate channel
and attaches the tab to the existing server.

**Transport.** The GUI keeps one dedicated mux connection per host
(`editorlsp.RemoteLink`), dialed on a worker thread because the ssh
bootstrap blocks, then watched with `g_unix_fd_add` — the GLib loop is
never blocked, writes queue in the mux `Conn`'s buffer behind a
`G_IO_OUT` watch when short. It is separate from the fs connections on
purpose: file IO uses short-lived request/reply pumps that would
tangle with a long-lived multiplexed frame stream.

**Lifecycle: the server dies with its channel.** The daemon SIGTERMs
the child's process group when the channel closes (explicit
`chan_close`, client disconnect, daemon shutdown) and escalates to
SIGKILL after 1.5 s (`Daemon.lsp_reaps`), reaping by exact pid. A warm
index argues for keeping servers alive across a GUI restart, but an
LSP session cannot be re-adopted — `initialize` happens once per
process and the daemon holds none of the client state — so a surviving
server could never answer a new GUI and would only hold memory on
someone else's machine. Symmetric with local: the last tab out shuts
the server down there too.

**Degradation is silent at every layer**, matching the local contract:
a daemon that predates the feature does not advertise `lsp:true` in
its welcome and is never asked; a host with no server installed
answers `ok:false`; a spawn failure likewise; a dropped link marks
every session on it dead through the same `onServerDead` path a local
crash takes. Each failure surfaces only where the user explicitly asks
for a feature ("No language server for hover."). A host that failed
once is remembered (`RemoteLink` stays listed as dead) so repeated
attaches neither redial nor prompt.

Known limitations: the remote server's stderr goes to /dev/null on the
daemon host (nobody is there to read it; the GUI's status line loses
the last-stderr-line nicety for remote conns), and a dead link is not
redialed until the editor face is recreated — reconnect-on-demand was
traded away to avoid a retry storm against an unreachable host.

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

`didOpen` is sent when the document HAS its content, which is not the
same moment the tab is attached to a server. A tab is created (and
attached) the instant the user asks for a file; its bytes arrive on the
async load. `Manager.openDocument` therefore returns early while
`ETab.loading` is set and the load's own `onDocumentReplaced` opens the
document — with the "new file" branch, which has no document replace to
ride on, calling `ensureOpen` instead.

That ordering is load-bearing and used to be wrong: the client opened
every document with **zero bytes** and sent the content as a
full-replace `didChange` immediately afterwards. Sync ended up correct
either way, which is why it survived so long, but `languageId` plus the
first text is what a server does its one-time indexing from, and handing
it an empty file is a bad way to start. `sketerm-lsp-stub` writes the
size of the `didOpen` payload it received to `$SKETERM_LSP_STUB_REPORT`
and `smoke-lsp-gui` asserts it equals the document — the only place that
number is observable at all.

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
| `Ctrl+Shift+Space` | signature help (also opens on the server's trigger characters) |
| `Ctrl+.` | code actions for the selection, or for the caret |
| — | **Inlay hints** in the visible lines, **semantic highlighting** on top of Tree-sitter, and a **hover on mouse dwell** |

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

**Signature help** opens on the server's own `triggerCharacters`
(typically `(`), refreshes on its `retriggerCharacters` (typically `,`),
and can always be asked for with Ctrl+Shift+Space. It is its own
popover, not a mode of the list, because VS Code-style behaviour has it
open at the same time as the completion list — so it points UP from the
caret while the list points down.

Following the active parameter as the caret moves is the re-entrant
part, and it is handled with exactly the machinery completion already
uses: the re-request is debounced by 120 ms, a new request supersedes
the in-flight one with `$/cancelRequest`, and an answer whose revision
no longer matches the document is dropped rather than shown. The popup
closes outright once the caret walks back past the offset the current
help was requested at — that call is gone.

**Code actions** ask for the selection, or for the caret when there is
none, and carry back the diagnostics OVERLAPPING that range as the
server's own objects. That is why `diagnostics.Diagnostic` keeps the
`raw` JSON of every published diagnostic: a fixit provider (clangd is
one) matches on its own `data` field, and a re-serialised approximation
of it produces no actions at all.

All three shapes a server can answer with are handled: an inline `edit`
is applied; a `command` goes to `workspace/executeCommand` and the
server's follow-up `workspace/applyEdit` is answered (this is why the
client advertises `workspace.applyEdit: true` and `Session.Handler` has
an `on_apply_edit` slot); an action carrying neither is resolved with
`codeAction/resolve` first.

Every one of those paths — rename included — applies through the SAME
`applyWorkspaceEdit`, so the one-transaction-per-document rule holds
once rather than three times. The consequence rename documents applies
unchanged and is not papered over: **history is per `Document`, so an
action touching three files is three undo units**. `create`/`rename`/
`delete` file operations inside a `WorkspaceEdit` are counted as skipped
and reported, never performed — the editor does not write files the user
did not open.

**Inlay hints** are requested for the visible line span widened by 80
lines, never for the whole document, and re-requested only when the
viewport leaves that window or the document changes (debounced 220 ms).

They are display-only, and the way that is guaranteed is worth stating
precisely, because "just draw them" is where editors get this wrong:
a hint reaches the renderer as `(byte offset, text)` on
`Layout.hints`, and `editor_layout` emits its glyphs with `hint = true`
and **appends no `Cluster`**. Clusters are the entire hit-testing and
caret currency (`caretPos`, `byteToX`, `xToByte` walk nothing else), so
the document's byte space is bit-for-bit what it was without hints: the
caret cannot enter a hint, a click inside one resolves to the nearest
real grapheme boundary, and no offset anywhere shifts. What hints DO
change is x — everything after one on the line moves right, which can
change that line's wrapped row count. That needs no new invalidation
rule: `RowIndex` is an estimate that `note()` refines for every line the
renderer lays out, so the scrollbar follows on the next frame exactly as
it does after any other content change. The per-line layout cache gains
`hints_gen` alongside `hl_gen` for the same reason `hl_gen` exists.

Hints are dropped, never carried, on an edit: a decoration anchored to
moved bytes is worse than no decoration, and the refresh is one round
trip.

**Semantic tokens** are requested for the whole document
(`semanticTokens/full`), with `full/delta` used whenever the server both
offers it and has given us a `resultId` for the array we still hold;
`semantic.Data` keeps that packed array verbatim so a delta can splice
into it (back-to-front, so one splice cannot move the next one's
offset). A delta that does not fit the array we hold is refused
WHOLESALE and the cached array dropped, so the next request is a full
one — half-applying a splice would mis-colour the rest of the session.
The `range` request is not used.

**Precedence, decided and fixed: Tree-sitter is the base layer and a
semantic token overrides it for the bytes it covers.** The server knows
things the grammar cannot (whether `foo` is a type, a macro or a local),
so where it speaks it wins. But servers routinely classify only
identifiers — punctuation, and often comments and strings, come back
untyped — so the grammar keeps everything the server did not claim. The
same reasoning decides what happens to a token type this editor has no
colour for (`concept`, a vendor extension, anything new): it is
**dropped**, not painted as `Kind.none`, because `.none` would blank out
the grammar's answer and lose information. This is exactly the contract
`semanticTokens.augmentsSyntaxTokens: true` in the client capabilities
describes. Token MODIFIERS are parsed off the wire but not used — a
`readonly` variable is coloured as a variable.

**Mouse-dwell hover** is a motion controller feeding a timer, and the
distinction that matters is that the motion handler only ever RESTARTS
the timer: the request is issued from the timer callback, so a pointer
crossing the window produces zero requests. The dwell is cancelled by
any key, any scroll, any click, and by the pointer moving again; a
second dwell landing on the same byte offset does not re-ask. The popup
is anchored at the POINTER (not the caret) and reports the diagnostic
under the pointer, and a dwell that finds nothing says nothing at all —
the user did not ask for it. `editor_lsp_hover_delay_ms = 0` turns it
off; Ctrl+I is unaffected.

## Configuration

App-level, not per-profile: a language server serves a **language**, and
which pane profile a document happens to be open under says nothing about
that (the split CLAUDE.md describes for `ProfileSettings`).

```ini
editor_lsp = true                   # master switch
editor_lsp_diagnostics = true       # squiggles + gutter stripe
editor_lsp_debounce_ms = 250
editor_lsp_inlay_hints = true       # inline type / parameter annotations
editor_lsp_semantic_tokens = true   # server colours on top of Tree-sitter
editor_lsp_signature_help = true    # parameter list while typing a call
editor_lsp_hover_delay_ms = 500     # mouse dwell; 0 = off (Ctrl+I unaffected)

[lsp.zls]
args = --enable-debug-log

[lsp.clangd]
enabled = false

[lsp.tsserver]
command = typescript-language-server
args = --stdio
languages = typescript, typescriptreact, javascript, javascriptreact
root_files = tsconfig.json, package.json, .git
init_options = {"tsserver":{"path":"/opt/ts/node_modules/typescript/lib/tsserver.js"}}
```

`init_options` is a raw JSON object passed through as
`initialize.initializationOptions`. Several widely-used servers are
unusable without it (typescript-language-server needs a `tsserver.path`
when the workspace has no local `typescript`; rust-analyzer takes its
settings there), and it is server-specific by definition, so it is a
pass-through string rather than a typed schema. Malformed JSON is
dropped rather than corrupting every `initialize`.

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

The Editor page in Preferences carries these switches plus one group
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
  the didChange queue, process spawn, the semantic-token legend / decode
  / delta splice, inlay-hint parsing (label parts, padding, the emoji
  line), and the whole session lifecycle against a scripted in-process
  server (`src/lsp/session_test.zig`). `zig build test` additionally
  covers the RENDER side in `render/editor_layout.zig`: that a hint
  shifts glyphs without adding a cluster or moving a byte, and that a
  semantic token overrides the Tree-sitter kind only where it lands.
* `zig build smoke-editor` — the LSP stage spawns
  **`sketerm-lsp-stub`**, a real child process speaking the base protocol
  over real pipes, and drives diagnostics, incremental sync, hover,
  definition, references, symbols, completion + resolve, rename and
  formatting through the production client — plus signature help (the
  active parameter must move with the caret), all three code-action
  shapes including `codeAction/resolve`, range-honouring inlay hints,
  and `semanticTokens/full` followed by a `full/delta` that has to
  decode to the same token set. The stub maintains its **own**
  copy of the document from the `contentChanges` it receives and publishes
  diagnostics against it, so an off-by-one range makes the two copies
  diverge and the stage fail. The whole stage runs twice, once per
  position encoding, over a document full of astral-plane characters.
* `zig build smoke-lsp-gui` — the REAL editor GUI on sketerm's own
  Wayland compositor (private daemon on a short socket, display session,
  viewer attached before the GUI — never Xvfb), driving
  `typescript-language-server` when it is on PATH and the stub
  otherwise; `SKETERM_SMOKE_LSP=ts|clangd|zls|stub` forces one, and it
  is meant to be run against a real server AND the stub, because the
  stub answers in the same tick and is the only thing that exposes
  race-shaped bugs (a fast `completionItem/resolve` growing a popover's
  minimum size once popped the completion list down; see the invariant
  on `ensurePopup`).

  The whole battery then runs a SECOND time on a **remote** document:
  a fake-ssh script (`$SKETERM_SSH`) execs `sketerm-mux --proxy` into
  a second private daemon built from this tree, the document opens as
  `rbox:/...`, and that daemon spawns the server and relays its stdio.
  Hermetic — no passwordless ssh, no installed daemon, and the leg
  cannot silently skip. Remote screenshots carry a `-remote-` infix.
  The daemon relay itself is unit-tested in `src/mux/daemon.zig`
  ("lsp_open resolves the root remotely…"): candidate walk, marker
  root, byte bridge through a real child, and kill-on-close with no
  zombie left.

  Asserts the diagnostic stripe renders, that Ctrl+I, Ctrl+Space,
  Ctrl+. and a typed `(` each open a popup (a GtkPopover is its own
  xdg_popup, so this is observable rather than inferred), that the
  signature popup SURVIVES the caret moving to the next parameter, that
  accepting a completion and applying a code action each change the
  document and close the list, that a pointer resting on a symbol opens
  a hover with no key pressed, and that F12 moves the caret. Inlay
  hints are asserted by their own colour appearing to the right of the
  gutter (nothing else uses it). Against the stub it additionally
  asserts that `didOpen` carried the whole document, and that the
  `SEM` marker is painted in the `property` colour — which no grammar
  gives that identifier, so it can only come from the semantic tokens.
  One screenshot per claim lands in `zig-out/`.

`SKETERM_LSP_DEBUG=1` traces attach decisions, server lifecycle and
published diagnostics to stderr — the client is silent by design, so
there is no other way to see why a server did not attach.

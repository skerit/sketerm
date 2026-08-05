<!-- Loads when working in src/lsp/. The full architecture, the feature
     list and the config surface live in docs/lsp.md — read that first.
     What follows is only the set of invariants that were expensive to
     learn and are cheap to break. -->

# LSP client

`docs/lsp.md` is the reference. These are the rules:

- **Everything here is GTK-free and lives in BOTH test roots.** The only
  GTK in the client is `src/ui/editorlsp.zig`. `config.zig` imports
  `servers.zig`, and `config.zig` is compiled into `sketerm-mux` — so a
  GLib or GTK import in this directory breaks the daemon's dependency
  invariant. `zig build mux-portable` + `ldd zig-out/bin/sketerm-mux`
  (libc/libm only) after touching anything reachable from `servers.zig`.

- **`session.zig` never touches a file descriptor.** Bytes in through
  `feed()`, bytes out into `out`. That is what makes the whole protocol
  testable without a process; do not "simplify" it by giving it the pipe.

- **`character` is UTF-16 code units by default.** An emoji is 4 bytes,
  1 codepoint, **2** characters. Every conversion goes through
  `position.zig` — never index a rope with an LSP `character`.

- **didChange ranges are captured PRE-edit**, in `Document`'s observer
  slot 2, and queued **descending** by offset. Ascending would need each
  range adjusted for its predecessors, because LSP applies
  `contentChanges` in array order. Losing a capture sets `needs_full`;
  never drop one silently, or the server is wrong for the rest of the
  session.

- **Every response is revision-stamped and dropped when stale**, exactly
  as `editor/syntax.zig` does. Diagnostics are the one exception: they
  are anchored byte ranges carried through edits by `mapThrough`.
  Inlay hints and semantic tokens are deliberately NOT carried — they
  are dropped on any edit and re-requested.

- **`didOpen` must carry the document's real content.** A tab is
  attached to a server before its async load lands, so
  `Manager.openDocument` returns early while `ETab.loading` is set and
  the load opens it. Do not "simplify" that away: it is how the
  zero-byte-didOpen-plus-full-didChange bug came back once already.

- **An inlay hint appends NO `Cluster`.** Hints advance the pen and emit
  glyphs in `editor_layout`, and that is all. Clusters are the whole
  hit-testing and caret currency, so giving a hint one would put the
  caret inside text that is not in the rope.

- **Semantic tokens AUGMENT Tree-sitter, they do not replace it**, and a
  token type with no `syntax.Kind` mapping is DROPPED rather than
  painted as `.none` (which would erase the grammar's answer).

- **`applyWorkspaceEdit` is the single cross-file applier.** Rename,
  code actions and `workspace/applyEdit` all go through it; do not add
  a second one.

- **Server-to-client requests must always be answered** (null, or a real
  MethodNotFound). A server waiting on us stops serving the user.

- **A missing or unsupported server is SILENT.** It may only surface
  where the user explicitly asked for a feature, as a status-line line.
  No dialogs, no gutter noise, no startup errors.

- **Never block the GLib main loop.** stdout is `g_unix_fd_add`-watched;
  stdin gets a `G_IO_OUT` watch only while a write is short; stderr must
  be drained or the server stalls when its pipe fills.

- **A remote document's server runs ON THE REMOTE HOST, never here.**
  The rule behind the old outright refusal still holds: a local server
  answering about `box:/src/main.c` would resolve includes, roots and
  compile_commands.json against the wrong filesystem. `attachTab`
  routes a host-qualified spec to the host's daemon (`lsp_open`), which
  picks the first candidate installed on ITS PATH, walks root markers
  on ITS filesystem, spawns the server and relays its raw JSON-RPC as a
  byte channel — the daemon never parses LSP. The client stays here,
  whole: one `Session`, same staleness stamps, same per-server encoding
  negotiation. `Session.start` with pid<=0 sends `processId:null` —
  OUR pid on the server's host would make clangd exit at once. The
  daemon-side child dies with its channel (chan_close, client death,
  daemon exit): an LSP session cannot be re-adopted mid-initialize, so
  a surviving process would only hold memory on someone else's machine.
  Daemon pieces are `lsp/proc.zig spawnSock` + `Daemon.handleLspOpen`
  (libc only); GUI transport is `editorlsp.RemoteLink`. See docs/lsp.md.

- `sketerm-lsp-stub` (`src/lsp_stub.zig`) is a REAL scripted server
  process used by `zig build smoke-editor`. It keeps its own copy of the
  document built from the `contentChanges` it receives, which is what
  makes the stage a true test of incremental sync — keep it that way.

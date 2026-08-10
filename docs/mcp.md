# MCP Tools

`sketerm mcp` exposes GUI-backed terminal tools in shared mode and
headless `term_*` and `app_*` tools against its isolated mux daemon.

## Tool exposure policy

By default every tool is offered. A policy narrows that, so one
assistant can get "the Wayland app tools but not the terminal tools"
while another on the same machine gets something else.

Three sources, in increasing precedence:

1. `[mcp.<name>]` in `config.conf` (`tools = ...`), selected with
   `sketerm mcp --profile <name>`.
2. `SKETERM_MCP_TOOLS` -- the usual path, since project `.mcp.json`
   files already configure this server through its `env` block.
3. `--tools <spec>` on the `sketerm mcp` command line.

An unknown term is fatal at startup: the server prints the offending
term, the spec it came from and the valid group names, and exits 2. A
typo must never silently withhold a whole group.

### Grammar

Comma- or space-separated terms:

| Term | Meaning |
| --- | --- |
| `all` | every tool |
| `<group>` | every tool in the group |
| `<group>:ro` | that group's non-mutating tools only |
| `<tool>` | one tool by name |
| `-<group>`, `-<group>:ro`, `-<tool>` | deny |

Groups: `panes` (a running GUI's tabs/panes), `app` (forwarded Wayland
apps), `term` (headless daemon terminals), `files`, `net` (port
forwards), `browser` (the `web_*` tools driving the GUI's own browser views), `ui`, `core`.

- Deny is absolute and order-independent; a spec cannot accidentally
  re-enable what it took away.
- A spec containing any allow term starts from "nothing"; a spec of
  only deny terms is a blocklist and keeps everything else.
- `core` (the `capabilities` tool) is always allowed, so an assistant
  can always ask what it is allowed to do.
- `<tool>:ro` is rejected: a tool's mutability is fixed, so the suffix
  is a category error rather than a no-op.

```
--tools "app, files:ro"            # drive apps, read files, nothing else
--tools "app:ro, browser"          # look at apps, drive a browser
--tools "-run_command, -file_delete_tree"   # everything but these two
```

### Enforcement, not presentation

A withheld tool is absent from `tools/list` **and** refused by
`tools/call`. Filtering the list alone would only hide it from a
client that had not read the docs. The refusal says the tool exists,
that the operator restricted this connection, and names the term that
would enable it -- an assistant should not spend turns guessing.

`capabilities` reports `tool_policy`: the raw spec, where it came from,
the available group names and the suppressed ones.

Group and read-only classification live in `src/ipc/mcpfilter.zig` as
typed Zig, not as extra fields in the tools payload. A test in
`src/ipc/mcp.zig` asserts the two lists name exactly the same tools, so
a tool added to one and not the other fails the build rather than
becoming quietly ungroupable.

## Terminal waits

Output quiescence and command completion are separate conditions:

- `term_wait_idle`, `wait_idle`, and the default `term_run` mode wait
  only until terminal output stops changing. A foreground process may
  still be running with stdout and stderr redirected.
- `term_run` with `wait_for: "command"` waits for the shell command to
  finish. It uses a new OSC 133 command zone when shell integration is
  active, preserving the shell's exact exit status.
- If the shell process itself exits before OSC 133 `D`, the isolated
  mux session's tracked process status completes the request instead.
  Sketerm never invents an exit status.

Command-mode results contain `state`, `command_sent`, `exit_status`,
`timed_out`, and `completion_source`. Sources are `shell_integration`,
`process_tracking`, or `none`.

When no shell integration was injected (unsupported shell), command
mode returns `state: "unsupported"`, `command_sent: false`, and
`exit_status: null`. The command is not sent because its completion
could not be identified reliably. When integration IS injected but the
shell's first prompt mark has not arrived yet (slow startup, or rc
files that broke the injection), command mode waits bounded (up to 10s
within the call's timeout) and then returns the same unsupported shape
with `timed_out: true` and a reason saying the state is retryable; the
full-length wait is paid only once per terminal.

If a foreground command started outside command mode (an idle-mode
`term_run` or raw `term_send_text`) is still running, command mode
also refuses with `command_sent: false`: the running command's OSC 133
`D` would otherwise be misattributed to the new send. Wait for it
(`term_wait_idle`) before retrying.

A command-mode timeout returns `state: "running"`, `timed_out: true`,
and `completion_source: "none"`, even if output remained idle.
Continue waiting with `term_wait_command`; do not resend the command.
While the tracked command is unresolved, Sketerm rejects BOTH another
command-mode send and an idle-mode `term_run` — running a new command
would let its OSC 133 `D` be misattributed to the tracked one. (If the
tracked command has meanwhile finished, the next `term_run` clears it
automatically and proceeds.) `term_send_text` stays available for
feeding input to the still-running command; avoid using it to start
new commands while a tracked command is pending.

```json
{"command":"timeout 3 sh -c 'sleep 10' >/tmp/silent.log 2>&1","wait_for":"command","timeout_ms":5000,"output_only":true}
```

The default `wait_for: "idle"` remains appropriate for interactive
programs that do not return to a shell prompt.

## Panels (`ui_*`)

`ui_show` renders a declarative document as native GTK widgets inside
the user's sketerm window: images, an A/B `image_compare` slider,
headings, sliders, selects, progress bars, buttons. The assistant
authors JSON; there is no raw HTML, CSS or script, and the component
catalog in `src/ui/panel/doc.zig` is the entire vocabulary. An image path
belongs to the panel's session host. For a remote mux session the attached
GUI fetches and validates the bytes before presenting the document; callers
do not need to copy remote images to the GUI host first.

| Tool | What it does |
| --- | --- |
| `ui_show` | show/replace a panel from `document` or `load` |
| `ui_show_files` | show a list of image files, document built server-side |
| `ui_patch` | apply patch ops to a live panel, in place |
| `ui_wait_event` | block until the user interacts (or the timeout) |
| `ui_panels` | live panels **and** saved documents, separately |
| `ui_save` | persist a document under its exact daemon origin and immutable session origin -- with no `document`, whatever the panel is showing right now |
| `ui_close` | remove a live panel from the screen |
| `ui_delete` | permanently delete a **saved** document |

`ui_close` and `ui_delete` are deliberately different tools: closing
keeps the saved copy, deleting is an unlink with no undo.

The tools are adapters over six control-socket commands --
`panel-show`, `panel-patch`, `panel-get`, `panel-events`, `panel-list`,
`panel-close` -- plus the disk store.

### `ui_show_files`: the one-call image case

Showing the user a set of images is the driving use case, and through
`ui_show` it costs roughly thirty lines of hand-authored JSON per call.
`ui_show_files` is a document GENERATOR on top of it: it builds the
document server-side and hands it to the same `panel-show`. It adds no
component, no control command and no second rendering path, and what it
produces is an ordinary panel -- `ui_patch`, `ui_save`, `ui_close` and
`ui_wait_event` all work on it.

```
ui_show_files {files: [{path, caption?} | "/abs/path"], name?, title?,
               target?, session?, compare?}
```

- **`compare: true` needs exactly two files** and emits one
  `image_compare` -- the A/B slider, with each file's caption as its
  side label. That is the component the super-resolution review turns
  on. Any other file count with `compare: true` is refused, naming the
  count it got.
- **Otherwise** the document is a heading (only when `title` is given)
  plus one `image` per file, in the order given, stacked in a column.
- **`name` defaults to `files`**, so the common call is one line.
  Re-showing the same name replaces that panel in place, same window and
  same `panel_id` -- which is exactly what "here is the next epoch"
  wants, and why the default is a fixed name rather than a unique one.
- **A caption defaults to the file's basename**, so a bare list of paths
  still labels itself.
- **Paths must be absolute and free of `..`** (the same structural
  constraint `doc.zig` puts on any image src, because documents are
  persisted and re-opened later). A bad one is refused, naming it.
- **Unreadable paths are checked up front.** The renderer already draws
  an explicit placeholder for an image it cannot decode, so a file that
  vanished mid-training is not worth failing the panel over: those files
  are still shown and the reply lists them under `unreadable`. But when
  *not one* file can be read -- the wrong directory, a typo'd prefix --
  the call is refused instead, because a panel made entirely of
  placeholders looks like a sketerm bug rather than a caller mistake.
  Either way the assistant can tell which it got.
- **Remote paths are hydrated by the presenting GUI.** `unreadable` is the
  MCP process's early host-side check; the final `assets` report says what
  the GUI actually fetched and decoded. Each item carries its logical path,
  byte count and SHA-256 on success, or a concrete error on failure.
- **Cap: 64 files** (`doc.MAX_CHILDREN` is 128 and the heading takes
  one). Over it, the refusal states the cap and the count.

The generated document is parsed through `doc.Document.parse` before it
leaves the server: a generator that emitted an invalid document would
otherwise surface as the GUI rejecting something the assistant never
wrote.

### The GUI holds the document

`ui_save` without a `document` argument reads the panel's CURRENT
document back from the GUI (`panel-get`, which serializes the live
`doc.Document` canonically) and stores those exact bytes. The MCP
server keeps no copy of what it showed, so this works against any panel
on screen -- one another process opened, or one shown before the server
started -- and it can never persist a stale document. That half needs a
live panel transport (origin-session relay or direct GUI socket);
passing `document` explicitly does not.

### Session scoping

Live panels are keyed by `(session, name)`. Saved documents are keyed by
`(exact canonical daemon socket, lifetime-unique origin_id, name)`, so a
rename keeps the same documents and later sessions that reuse the same
daemon/session name cannot overwrite or read one another. The store scope
is `panelstore.OriginScope` = `{daemon_origin, origin_id, label}`; `label`
is the session name and exists for diagnostics only -- it is never part of
a path, so it can never be the storage identity. The session is
resolved once per call: an explicitly present `session` argument, else
`$SKETERM_SESSION` (which every pane exports), else NO SESSION -- which
is a state, not a name. Explicit `session: ""` selects NO SESSION and
never falls through to the environment.
An `sketerm mcp` running outside any pane has no session, and its
panels are filed apart from every session's rather than under some
reserved session name that a real session could also be called. In
code that is `?[]const u8` (`panelstore.resolveSession`); on the
control socket it is an empty `session` field, which the GUI keeps
distinct from an ABSENT one (absent means "scope me to the requesting
pane"). Several assistants drive one sketerm, so one assistant's panels
are neither visible to nor collidable with another's, and re-showing a
name REPLACES that panel's document in place -- same window, same
`panel_id`, and an `image_compare` keeps its zoom, pan and split across
the swap.

Saved documents live under the session's daemon and lifetime:

    $XDG_STATE_HOME/sketerm/panels/by-origin/<sha256(canonical-socket)>/<origin_id>/<name>.json

`origin_id` is a random 128-bit lowercase hex value minted for each session
lifetime, so renaming a session keeps its documents while a later session that
reuses the name gets a fresh, empty store. Beside the hash directory an
`origin` file names the socket path it came from, purely so the directory is
identifiable by hand. Panel names, which the caller chooses, are still
rejected rather than sanitized. A caller with a session but no exact daemon --
a direct GUI control socket, or a daemon too old to report a lifetime id --
and a caller with no session at all use:

    $XDG_STATE_HOME/sketerm/panels/by-session/<session>/<name>.json
    $XDG_STATE_HOME/sketerm/panels/no-session/<name>.json

Nothing migrates between these three namespaces. A panel document is cheap to
re-save, and a migration a crash can only ever leave half-done costs more than
it is worth. Writes stage into `.<name>.<pid>.sketerm-part` and rename, so a
save either happened or did not. Persistence runs where
the MCP server runs: documents authored on a remote session host stay on
that host. The local GUI picker lists local daemon-origin documents and
reports that remote documents must be reopened through `ui_*` on their
remote host.

`ui_save.bytes` is the length of the canonical JSON actually written, not the
length of the caller's authored JSON. Save and delete failures before rename or
unlink use their ordinary store error (`PermissionDenied`,
`ReadOnlyFileSystem`, `IoFailed`, and so on), plus
`failure_class: "pre_commit"`, `mutation_state: "not_applied"`,
`committed: false`, and `mutation_may_have_applied: false`. Because the
staged write is only ever made visible by the final rename (and a delete by
the unlink itself), that one classification covers every store failure: the
mutation either happened or it did not.

### `ui_wait_event` polls; it never blocks the GUI

The `panel-events` control command answers immediately by design: it is
dispatched on the GLib main loop, and blocking there would freeze every
window. The blocking semantics therefore live in the MCP server, which
polls roughly every 100ms until an event arrives or the budget expires.
`timeout_ms` is clamped to 120000 (the same cap the app and terminal
waits use, under the 150s call watchdog). One absolute deadline covers
panel-name resolution, every request/reply exchange, and every sleep.

Events are drained, not sampled, so an interaction that happened
between calls is still delivered. If the panel's 64-event queue
overflowed, the reply states how many older events were dropped -- a
truncated interaction stream is never presented as the whole history. A
panel the GUI confirms is absent ends the wait immediately and says so. A
pre-delivery transport failure instead reports that open/closed state and
queued events are unknown, with `events_may_have_been_drained: false` and
`resend_safe: true`. If a direct or relayed `panel-events` request was written
but its reply is lost, the error states that queued events may already have
been drained and does not retry or claim that nothing was missed.

### Live panel transport

Live `ui_*` calls do not require `--shared`. With a session origin, MCP
attaches panel-only to that session on the exact daemon named by
`$SKETERM_MUX_SOCKET`; the explicit tool `session` wins over
`$SKETERM_SESSION`. Transport precedence is exact inherited daemon,
explicit direct GUI `--socket`, then canonical per-user daemon
compatibility. The compatibility path connects without autostarting or
discovering another daemon. A discovered GUI socket is never allowed to
redirect a sessionful panel mutation. The MCP private daemon used by app,
terminal, file and browser tools is never selected by this path.
When the exact daemon proves panel capability or panel-only attach is
unsupported before sending a panel operation, or a current daemon has no
compatible panel presenter, an explicitly supplied direct GUI `--socket` is
an actionable legacy fallback. This covers a released GUI that remains a
valid terminal viewer but never negotiated panel RPC. An unreachable origin,
identity mismatch, uncertain operation delivery, or an auto-discovered GUI
never uses that fallback.

Connections are nonblocking and deadline-bounded, persistent per
`(daemon socket, session, origin_id)`, and requests/replies carry correlation IDs.
Before a cached identity is returned, pending lifecycle frames are drained;
session `.gone`, EOF, or an error evicts the connection so name reuse cannot
inherit the previous session's persistence origin. Panel-only attach succeeds
only with a non-empty immutable `origin_name` and valid 128-bit `origin_id`;
daemon-owned callers also send their inherited ID as an attach fence, so a
reused name cannot bind them to a replacement lifetime. Missing or malformed
metadata is never replaced with the requested alias.
The daemon delivers each panel request to THE panel-capable attachment of the
session -- the earliest still-attached one when several exist. There is no
requester-to-presenter binding and no stickiness: when a presenter detaches
or dies, the next call simply routes to whichever panel-capable attachment is
present then, and an absent GUI is retry-safe `no_compatible_gui` --
restarting sketerm must not wedge panels for the life of the MCP server.
The GUI registry keys relayed panels by the session's immutable `origin_id`
alone. Duplicate viewers in one GUI therefore address one
panel namespace, routing-order changes do not change panel IDs, and closing one
viewer leaves the scope alive until its permanent last-viewer teardown. If a
shared `target: "pane"` panel was hosted on that viewer, its existing face is
unparented and rehosted on an empty surviving same-scope pane; the pane-tree
model is unchanged. A survivor that already hosts another panel is never
evicted: when no empty survivor exists, the departing viewer's pane panel
closes. The last viewer closes the panel normally.
Stale IDs are skipped. A request whose delivery became uncertain is
reported and never resent automatically, because replaying
`panel-show`, `panel-patch` or `panel-close` could apply a mutation twice.
Presenter replies are validated beyond JSON syntax: the top level must
be an object, `ok` must be boolean, failures need a non-empty `error`,
and successes require the operation result (`panel_id > 0`, `document`,
`panels`, or `events` plus `dropped`). A presenter that answers badly fails
every route already assigned to it, but keeps its panel capability: one broken
reply is a bug in one handler, and silently demoting a GUI to "panels no longer
work here" would hide it. A structured daemon failure keeps the correctly
framed requester connection; partial requester writes, disconnects, and
malformed daemon traffic retire the pooled connection. Post-delivery failures carry
`failure_class: "uncertain_delivery"`,
`mutation_may_have_applied: true`, and `resend_safe: false`; malformed
shape/envelope and failures after the first presenter request byte use that
classification. Failures before any request byte, including oversize,
allocation, backpressure, disconnect, session close, and route deadline,
carry `failure_class: "pre_delivery"`, `mutation_may_have_applied: false`,
and `resend_safe: true`. The direct control request cap is 4 MiB, enough for
an exactly 1 MiB valid panel document after JSON-string escaping and request
metadata; the document parser cap remains exactly 1 MiB.

Sessionless calls and daemons positively identified as predating panel relay
retain the explicit direct `--socket` path. If neither live transport exists,
the live tools fail honestly. Store-only calls remain available for
sessionless, explicit direct, default compatibility, validated exact lifetime,
and positively identified old-daemon scopes. An exact origin whose lifetime
scope cannot be validated returns the identity failure instead of entering a
reusable namespace. `ui_save` without a document also needs a live transport
to read the current document back.

`capabilities` reports `gui_socket`, `panels`, and `panels_store`
independently, with structured `panel_transport` and `panel_store` states.
It is a preflight: it probes the relay under a short deadline of its own and
writes nothing. `panels_store: true` means the store SCOPE resolves (an exact
origin has a daemon socket and a lifetime id, or the caller falls back to a
session/sessionless scope); a filesystem that then refuses the write is
reported by `ui_save` itself, with `error_code`, `mutation_may_have_applied:
false` and `resend_safe: true`.

### Remote panel images

When the selected GUI reaches the panel session through SSH or UDP, it reads
every `image.src` and both `image_compare` paths through ranged `fs_op read`
requests on that Terminal's existing mux connection. The daemon only serves
bytes; it never decodes images and `sketerm-mux` remains libc-only. Local mux
sessions and direct GUI-socket panels continue to open ordinary local paths.

The GUI stores successful bytes under their SHA-256 in a locked
per-process-incarnation namespace below
`$XDG_CACHE_HOME/sketerm/panel-assets` (or the usual `~/.cache` fallback),
then validates dimensions and performs a real decode before committing the
document and its resolver together. The document itself always retains the
logical remote path. Consequently `panel-get`, `ui_save`, and a later
`ui_show load=...` never expose or persist a GUI-private cache path. Reusing
one logical path after rewriting the remote file fetches new bytes and swaps
the rendered cache object.

Show, patch and close are transactional and serialized per RPC v2
presenter/session scope through hydration and deferred tab construction. Thus
a close waits behind an older delivered show and that show cannot recreate the
panel after close success. A direct panel close synchronously cancels its exact
per-panel hydration lane before replying.
Independent origins may progress together. Limits are 64 unique assets,
16 MiB per asset, 64 MiB per operation, four concurrent ranged reads, and a
30-second operation deadline. The cache is bounded to 256 MiB and 2048 blobs;
active panel hashes are protected from pruning, writes are staged, fsynced,
and atomically renamed, and a bounded startup sweep removes unlocked dead-GUI
namespaces without touching a live owner's lock. Images over 8192 px
on either axis or 32 megapixels are refused. Decoded panel pixbufs are charged
against ONE budget, the GUI process's: 128 megapixels and 512 MiB. Header
dimensions reserve conservative RGBA bytes before the full decoder is called,
the reservation is atomically reconciled to the exact decoded rowstride, and
over-budget paths become explicit asset errors. Every failure and cancellation
releases it. The resulting
charge belongs to a shared prepared-image lease: each GtkPicture internal ref
has a matching widget qdata lease and each image-compare side retains the same
lease directly. Closing a panel therefore cannot release process capacity while
GTK or accessibility still holds a deferred widget reference; the charge ends
only when the final retained GObject owner finalizes.

An individual transfer or decode failure does not replace the user's current
panel with a half-applied patch. The committed document gets an explicit
placeholder for that logical path, while the `ui_show`, `ui_show_files`, or
`ui_patch` result reports `assets`, `asset_failures`, and each path's error.
Transport loss cancels every queued or deferred mutation and generation-fences
tab handbacks; already-mounted panels remain while the Terminal reconnects.
Committed direct local-file hydration is transport-independent and continues
across that reconnect; permanent Terminal teardown still cancels it through
the DrainHandle lifetime fence.
For direct panels, the Terminal that supplied local image bytes is retained as
a liveness-fenced asset origin. After that Terminal is destroyed, a patch that
introduces an unresolved image path is rejected before document commit. Plain
document edits and paths already resolved by that panel remain usable.

A rejected document or patch comes back with `doc.Diag`'s own message,
verbatim: it names the offending component id, and that text is what
the authoring assistant needs to fix it.

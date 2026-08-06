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
forwards), `browser` (CDP), `ui`, `core`.

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
catalog in `src/ui/panel/doc.zig` is the entire vocabulary.

| Tool | What it does |
| --- | --- |
| `ui_show` | show/replace a panel from `document` or `load` |
| `ui_show_files` | show a list of image files, document built server-side |
| `ui_patch` | apply patch ops to a live panel, in place |
| `ui_wait_event` | block until the user interacts (or the timeout) |
| `ui_panels` | live panels **and** saved documents, separately |
| `ui_save` | persist a document under `(session, name)` -- with no `document`, whatever the panel is showing right now |
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
GUI socket; passing `document` explicitly does not.

### Session scoping

Panels are keyed by `(session, name)`. The session is resolved once per
call: the explicit `session` argument, else `$SKETERM_SESSION` (which
every pane exports), else NO SESSION -- which is a state, not a name.
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

Saved documents live in

    $XDG_STATE_HOME/sketerm/panels/by-session/<session>/<name>.json
    $XDG_STATE_HOME/sketerm/panels/no-session/<name>.json

Two parents, so the two sets share no directory and nothing can
collide. The session is percent-encoded into that one directory
component, because a session name is inherited from the daemon (which
only length-checks it) and `my work` must not be unstorable. Panel
names, which the caller chooses, are still rejected rather than
sanitized.

### `ui_wait_event` polls; it never blocks the GUI

The `panel-events` control command answers immediately by design: it is
dispatched on the GLib main loop, and blocking there would freeze every
window. The blocking semantics therefore live in the MCP server, which
polls roughly every 100ms until an event arrives or the budget expires.
`timeout_ms` is clamped to 120000 (the same cap the app and terminal
waits use, under the 150s call watchdog).

Events are drained, not sampled, so an interaction that happened
between calls is still delivered. If the panel's 64-event queue
overflowed, the reply states how many older events were dropped -- a
truncated interaction stream is never presented as the whole history. A
panel the user closed ends the wait immediately and says so.

### Requires a GUI socket

`sketerm mcp` is isolated by default and reaches the user's running GUI
only with `--shared` (or an explicit `--socket`). Without one,
`ui_show`, `ui_show_files`, `ui_patch`, `ui_wait_event` and `ui_close`
return a described error naming `--shared`; `ui_panels`, `ui_delete` and `ui_save` *with* a
`document` keep working, since they only touch the saved-document store.
`ui_save` without one needs the socket to read the panel back, and says
so. `capabilities`
reports `panels` alongside `gui_socket`.

A rejected document or patch comes back with `doc.Diag`'s own message,
verbatim: it names the offending component id, and that text is what
the authoring assistant needs to fix it.

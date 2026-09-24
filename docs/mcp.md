# MCP Tools

`sketerm mcp` is a Model Context Protocol server on stdio. Its tools come
from one table (`src/ipc/mcp_tools.zig`) in eight groups; the reference
below lists every one. The pane tools drive the running GUI's panes when
a GUI socket is attached (`--shared`, or an explicit `--socket`) and the
headless terminals of the server's own daemon otherwise; the `term_*`,
`app_*`, `file_*` and forwarding tools always run against that daemon
(private per server by default, see `--name`/`--durable`). `capabilities`
is the one preflight: it reports what this server can reach right now.

## Tool reference

Generated from the tool table; a unit test fails when this block and the
table disagree and prints the block to paste. A tool marked read-only
is kept by a `:ro` policy term. The full descriptions and schemas are in
`tools/list`.

<!-- tool-reference:begin (generated: do not edit by hand) -->
### `panes`

- `list_terminals` (read-only): List the terminals the pane tools address: every GUI tab and pane (ids, titles, sizes, cwd, focus), or, with no GUI socket attached, the headless terminals this server opened (headless:true; each id is the `pane` every pane tool takes and the `term` every term_* tool takes).
- `read_screen` (read-only): Read a pane's rendered screen: text plus cursor position, size and flags.
- `screenshot_pane` (read-only): Screenshot a terminal pane as a lossless PNG (inline image) exactly as rendered, including colours, cursor and any shader.
- `record_pane_start`: Start recording a terminal pane's session as an asciicast v2 (.cast) file: raw output with timestamps, playable with asciinema.
- `record_pane_stop`: Stop the asciicast recording of a terminal pane's session.
- `send_text`: Type literal text into a pane's terminal.
- `send_keys`: Press named keys in a pane: space-separated chords like 'ctrl+c', 'enter', 'up', 'escape', 'f5', 'alt+x', 'shift+tab', 'pagedown'.
- `run_command`: Type a shell command, press Enter, wait until OUTPUT settles (quiet_ms of no output), and return the resulting screen.
- `wait_idle` (read-only): Wait until a pane produced no output for quiet_ms (or timeout_ms elapsed).
- `new_tab`: Open a new shell tab in the GUI.
- `split_pane`: Split a pane.
- `focus_pane`: Focus a pane (selects its tab and grabs keyboard focus).
- `close_pane`: Close a pane.

### `app`

- `list_installed_apps` (read-only): List installed GUI apps on the host (name + launch command), from its .desktop entries.
- `launch_app`: Launch a GUI (Wayland) application HEADLESSLY: it renders into sketerm's mux daemon, never appears on any screen, and survives disconnects.
- `list_apps` (read-only): List launched headless apps and their windows.
- `app_windows` (read-only): List one app's rendered windows (ids, sizes, titles).
- `screenshot_app` (read-only): Screenshot a headless app window as a lossless PNG (inline image).
- `get_app_state` (read-only): One-call app observation: window list + screenshot of one window (inline PNG) with coordinate mapping.
- `app_output` (read-only): Read a headless app's stdout/stderr (its PTY output as RENDERED BY A TERMINAL — a fixed-width grid, so long lines wrap and scrolled-off content needs scrollback=true; right for TUI-style redraws).
- `app_log` (read-only): A headless app's stdout/stderr as an INDEXED LOG: each complete line gets a stable numeric id and a timestamp; the tail view shortens long lines (marked [+]) and any line can be re-read in full by id.
- `app_wait_log` (read-only): BLOCK until one of the app's log lines matches a pattern, then return that line immediately.
- `app_click`: Click inside an app window at surface-local pixel coordinates (from screenshot_app; apply the caption's multiplier if the image was downscaled).
- `app_actions`: Execute an ORDERED batch of interaction steps against one app in a single call — collapses click/wait/screenshot round-trips (driving menus, games, wizards).
- `app_mouse_move`: Move the pointer in an app window WITHOUT clicking.
- `app_perform_action`: Invoke a widget's default AT-SPI action (press/activate/toggle) directly by element id — the reliable coordinate-free way to 'click' a button, menu item or checkbox.
- `app_set_value`: Write a value straight into a widget via AT-SPI: 'text' replaces a text field's content (EditableText), 'value' sets a slider/spinner (Value).
- `app_wait_for_element` (read-only): Wait until a widget appears in the app's accessibility tree (dialog opened, page loaded, ...).
- `app_drag`: Press-move-release drag inside an app window (sliders, drag-and-drop, text selection).
- `app_type`: Type literal text into an app window.
- `app_clipboard_get` (read-only): Read what the app last copied to the clipboard (requires the app to have copied something).
- `app_clipboard_set`: Offer text to the app as the host clipboard.
- `app_key`: Press key chords in an app window: space-separated, e.g. 'ctrl+s', 'enter', 'alt+F4', 'down down enter'.
- `app_scroll`: Scroll inside an app window.
- `app_resize`: Ask an app window to redraw at a new size (deterministic screenshots).
- `app_wait` (read-only): Wait until an app stopped producing new frames for quiet_ms (render quiescence), or — pass change_pct — until each new frame changes less than that percentage of pixels for quiet_ms (VISUAL quiescence: use this for games and other continuously-animating apps, which never stop committing frames but do reach a visually stable screen).
- `app_watch` (read-only): Watch a window for a while and report WHEN it changed, as a timeline.
- `app_hover_map`: Sweep the pointer over a grid and report which cells made the window repaint — empirical discovery of interactive regions for an app with no accessibility tree (games, raw framebuffer UIs), where the only alternative is guessing coordinates.
- `app_backtrace`: Attach a debugger to the app on the daemon host and return every thread's backtrace.
- `app_a11y_tree` (read-only): Read the app's accessibility (AT-SPI) tree as JSON: every widget's role, name, AT-SPI accessible identifier when exposed, description, states and screen rectangle.
- `app_record_start`: Start recording a window's frames (a visual log of what you do).
- `app_record_stop`: Stop the recording and save it (WebM or GIF per app_record_start).
- `app_read_text` (read-only): OCR: read the TEXT rendered in an app window (or a region of it) — for custom-drawn UIs and games with no accessibility tree, this turns pixels into assertable strings.
- `app_wait_text` (read-only): Wait until a text string becomes visible in an app window (OCR-polled, case-insensitive substring) — assert 'the dialog opened' / 'the menu lists Repairs' without eyeballing screenshots.
- `app_template_save`: Save a named image template for visual matching: crop a distinctive UI element (a button, sprite, dialog frame) out of an app window via region, or pass image_b64 (PNG).
- `app_templates` (read-only): List saved image templates (name + dimensions), or delete one.
- `app_find_image` (read-only): Find a saved template (or inline PNG) in an app window RIGHT NOW by pixel matching — 'is the conversation frame on screen, and where?'.
- `app_wait_image` (read-only): Wait until a template appears in an app window (pixel matching, polled), then optionally click its center (click=true) — the coordinate-free 'wait for this sprite, then click it' primitive for apps without an accessibility tree.
- `app_macro_save`: Save a named, replayable input macro.
- `app_macro_run`: Replay a saved macro against an app: runs its steps through the app_actions engine (deterministic order, per-step report, stops on failure/exit; wait_image/wait_text steps make the replay state-driven rather than timing-driven).
- `app_macros` (read-only): List saved macros; show one's steps (show); delete one (delete); or view an app's recorded input journal (journal:true + app) to pick last_steps for app_macro_save.
- `close_app_window`: Ask the app to close one window (like the titlebar button; the app decides).
- `close_app`: Kill a headless app session outright.

### `term`

- `term_open`: Open a HEADLESS shell terminal on the private mux daemon (isolated mode) — a real PTY with no GUI, nothing of the user's reachable.
- `term_list` (read-only): List open headless terminals: shell name + whether shell integration is active, exit state + real exit_status, pending command/exec trackers, the last rendered screen line (drained first, so a finished process never shows a stale progress frame), and each terminal's asciicast recording path.
- `term_run`: Type a command line INTO the terminal's live session shell, exactly like a human: the SESSION SHELL parses it (its own dialect — bash/zsh/fish/whatever is running there) and state changes PERSIST across calls (cd, export, aliases, venv activation).
- `term_send_text`: Write text to a headless terminal's PTY.
- `term_send_keys`: Press named key chords in a headless terminal: 'ctrl+c', 'enter', 'up', 'tab', space-separated.
- `term_read` (read-only): Read a headless terminal's rendered screen with its cursor/size facts.
- `term_wait_idle` (read-only): Wait until a headless terminal's output stops changing (or timeout).
- `term_wait_command` (read-only): Continue waiting for a term_run wait_for=command request that timed out.
- `term_resize`: Resize a headless terminal's grid.
- `term_close`: Close a headless terminal (kills its shell).
- `term_exec`: Run one command inside a LIVE interactive shell (including a persistent SSH session from term_open host) and get STRUCTURED results: exact exit_status and the exact output between sentinel markers, independent of shell integration.
- `term_exec_wait`: Continue waiting for a pending term_exec without resending — always attachable, including after a client-side tool timeout or abort.
- `term_wait_exit` (read-only): Wait until a headless terminal's child PROCESS exits (distinct from output idleness — a silent scp can be running while output is idle, and an exited one can leave a stale progress frame).

### `files`

- `scp_put`: Copy a LOCAL file to an SSH host (scp), with integrity + atomicity built in: scp to a staged temp file, remote SHA-256 verify against the local hash, then an atomic mv into place (a corrupt transfer is discarded, never half-written).
- `scp_get`: Copy a file from an SSH host to this machine (scp), with integrity + atomicity: scp to <local>.sketerm-part, SHA-256 compare against the remote hash, atomic rename into place.
- `file_list` (read-only): Rich directory listing on the daemon's host in ONE round trip: kind, size, mtime, permissions and symlink target for every entry, dirs first.
- `file_stat` (read-only): Stat one path: kind (file/dir/link/other), size, mtime, mode, owner, symlink target.
- `file_read` (read-only): Read a file (ranged).
- `file_write`: Write content to a file (created if missing; replaced unless append=true).
- `file_mkdir`: Create a directory (single level, parent must exist).
- `file_rename`: Rename/move a file or directory on the same filesystem.
- `file_delete`: Delete ONE entry: a file, symlink, or EMPTY directory.
- `file_copy`: Copy a file or a whole directory tree as a daemon-side JOB: runs in its own process, survives this MCP server, and is RESUMABLE — resume=true continues a previous interrupted copy from its hash-verified partial (a corrupted partial honestly restarts from zero; the reply's resumed_from says which happened).
- `file_delete_tree`: Recursively delete a directory tree as a daemon-side job (same wait/job semantics as file_copy).
- `file_hash` (read-only): SHA-256 of a file, computed daemon-side as a job (only the digest crosses the wire — use for verifying copies).
- `file_extract`: Extract an archive ON THE HOST THAT OWNS IT.
- `file_archive_create`: Create an archive ON THE SOURCE HOST.
- `file_trash`: Move a file or directory to the owning host's freedesktop Trash as a daemon job, preserving restore metadata.
- `file_chmod`: Change permissions on the owning host.
- `file_truncate`: Set a file's exact byte length on the owning host.
- `file_media_info` (read-only): Media metadata for MANY files in ONE daemon-side batch: image/video dimensions, JPEG EXIF (camera, lens, orientation, DateTimeOriginal, exposure, GPS), audio tags (ID3v1/v2, Vorbis, MP4 ilst), duration and bitrate.
- `file_jobs` (read-only): List file jobs (running + recently finished): id, op, state, progress.
- `file_job` (read-only): Control a file job: cancel (SIGKILL — works even on jobs stuck in unkillable IO), pause (SIGSTOP), resume (SIGCONT).

### `net`

- `port_forward_open`: Open a STRUCTURED SSH port forward (ssh -N -L with keepalives + ExitOnForwardFailure): picks a free local port when none is given, verifies the listener actually accepts before replying, and returns a forward id.
- `port_forward_list` (read-only): List open port forwards with liveness and reconnect counts.
- `port_forward_check` (read-only): Health-check one forward: verifies the ssh process AND that the local port accepts connections; if the ssh died (network blip, sshd restart) it RECONNECTS by respawning the same spec on the same local port.
- `port_forward_close`: Close a port forward (kills its ssh).

### `browser`

- `web_tabs` (read-only): List the open browser views — SEVERAL can be open at once.
- `web_open`: Open a NEW web view and return its handle plus a FIRST SNAPSHOT of the requested page, once THAT navigation has settled.
- `web_close`: Close a web view.
- `web_profiles` (read-only): HEADLESS ONLY (with a GUI attached the browser's identity containers belong to the user).
- `web_profile_reset`: HEADLESS ONLY.
- `web_policy` (read-only): HEADLESS ONLY (with a GUI attached this refuses: the user's own tabs are not policed by an assistant).
- `web_policy_set`: HEADLESS ONLY (with a GUI attached this refuses).
- `web_navigate`: Navigate a web view: a 'url', or an 'action' (back|forward|reload|stop).
- `web_snapshot` (read-only): The page's ACCESSIBILITY-style tree as compact text: one line per node with a stable [id], role, name, states (focused/checked/disabled/required/invalid/expanded/current) and value.
- `web_act`: Act on an element: by semantic ID from web_snapshot/web_read, or by accessible 'name' (with optional 'role' and 'nth') to fold the find-then-act two-step into one call.
- `web_expand` (read-only): Full text of a node the snapshot truncated (the "(+N chars, expand [id])" marker), paged with offset/len.
- `web_query` (read-only): Cheap spot-check against the tree AS LAST SENT to you (no fresh DOM walk): find_text (nodes whose name contains 'arg'), subtree (children of the node id in 'arg'), focused, form (every form control with its value and checked/disabled states and the row or group it sits in - what Apply would submit; 'arg' = a node id to scope it, or omit for the page), or within_text ('arg' = JSON {"text","name","role"}: the controls named name under the smallest container that also holds text, the same resolution web_act within_text uses).
- `web_read` (read-only): READ THE PAGE: reader-mode markdown of the main content (headings, paragraphs, lists, code, links), with navigation and boilerplate dropped, plus stable semantic IDs for useful sections/headings/links/items.
- `web_wait` (read-only): Wait until the view reaches a state: "load" (no load in flight), "title" (its title contains 'arg', or any title when arg is omitted), "text" ('arg' appears in the page's semantic tree) or "idle" (the DOM stopped changing for 600ms).
- `web_scroll`: Scroll a web view and report the SETTLED position (before/after scrollX/scrollY plus the maximum), so "nothing moved" and "moved to the end" are different answers.
- `web_key`: Send named key chords to a web view as TRUSTED key events (the same input path a real keystroke rides), so Tab order, Escape-to-dismiss and Enter-to-submit are testable.
- `web_resize`: Resize a web view's viewport IN PLACE (width x height, logical px).
- `web_inspect`: Compact UI review: focused control, landmarks, accessible-name approximations, disclosure wrapper/control mismatches, horizontal overflow and new page/console errors.
- `web_checkpoint`: Without id, create a soft-navigation checkpoint.
- `web_diagnostic` (read-only): Retrieve bounded, redacted helper failure evidence by the id returned in an error.
- `web_console` (read-only): The page's console output (console.log/warn/error, uncaught exceptions as the engine reports them), mirrored per view since it opened - the blind spot behind "no console error column".
- `web_eval`: Evaluate JavaScript in the page — the escape hatch for everything the structured tools do not cover.
- `web_screenshot` (read-only): PNG of a web view.
- `web_download`: Download a url to a FILE, fetched by the web view's own browser — so it carries that browser's cookies, session and route, and a file behind a login needs no token, no signed url and no cookie copying.
- `web_network`: Content blocking + a network request log for a web view.

### `ui`

- `ui_show`: Show the user a real native UI PANEL in their sketerm window: a declarative document rendered as GTK widgets, not text or a screenshot.
- `ui_show_files`: FAST PATH for "show me these images": hand it a list of image files on the session's host and it builds the panel document for you and shows it — ONE call instead of hand-authoring a ui_show document.
- `ui_patch`: Update a live panel with a JSON array of ops applied as one transaction.
- `ui_wait_event` (read-only): Block until the user interacts with a panel, then return queued interactions with component id and monotonic timestamp: button click values are actions, slider/select changes carry their new value, and text_input submit carries up to 4096 UTF-8 bytes.
- `ui_panels` (read-only): Inventory of panels in a session, in two clearly separate lists: LIVE panels (on screen right now — panel_id, name, title, target) and SAVED documents (stored on disk by ui_save — name, title, size, mtime, and whether the stored file still parses).
- `ui_save`: Persist a panel document to disk under the session's daemon origin and lifetime id so a later ui_show can bring it back with load=<name>.
- `ui_close`: Close a LIVE panel: it disappears from the user's screen.
- `ui_delete`: DESTRUCTIVE: permanently delete a SAVED panel document from disk.

### `core`

- `capabilities` (read-only): Preflight report of what THIS MCP server can do right now: isolation mode, headless GUI-app support (headless_gui — launch_app renders apps into the mux daemon and NEVER needs a display, an X server or a sketerm window), whether a direct sketerm GUI control socket is attached (gui_socket; independent of the session panel relay and of headless GUI apps), the live panel transport (panels + panel_transport) and the saved-panel store (panels_store + panel_store), OCR (tesseract) availability, whether the web_* tools can run and against what (web + web_backend "gui"/"session"/"headless"/"none" — "session" adds web_session, the watchable Wayland app session the helper renders into — plus the sketerm-webengine path in web_helper; web_gui says whether the user granted the web_* tools their OWN browser and logins, web_gui_source where that came from and web_gui_transport which GUI socket they hold now; web_profiles says whether named cookie jars work, web_routes which per-tab network routes web_open can honour, web_engine_broker whether the mux daemon owns the engine's lifetime and web_engine_owner who started the one in use; web_downloads whether web_download can pull a url through a view; web_engine_started whether an engine exists YET, since web_backend/web_watch/web_session are undetermined until it does), ssh/scp presence, the directory terminal asciicast recordings land in, the EFFECTIVE input-timing defaults (hold_ms/settle_ms/timeout_ms/click_retry, each marked when a SKETERM_MCP_* env override changed it from the built-in), and open session counts.
<!-- tool-reference:end -->

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
| `all:ro` | every non-mutating tool, in every group |
| `<group>` | every tool in the group |
| `<group>:ro` | that group's non-mutating tools only |
| `<tool>` | one tool by name |
| `-<group>`, `-<group>:ro`, `-<tool>`, `-all:ro` | deny |

`all` is group-shaped, so `:ro` narrows it exactly as it narrows a named
group.

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
--tools "all:ro"                   # observe everything, mutate nothing
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

Group and read-only classification are fields of the one tool table,
`src/ipc/mcp_tools.zig`, which also generates the tools/list payload
(the extra fields never reach the wire). A tool is therefore one entry:
it cannot be advertised without a group or grouped without being
advertised.

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

## Browser (`web_*`)

These drive sketerm's OWN browser views (`src/ipc/mcp_web.zig`), not an
external Chromium over a debug port. There is no automation flag and no
CDP: input is delivered as real engine events, so a page sees
`isTrusted` clicks and keystrokes.

`web_open`, `web_navigate`, `web_tabs`, `web_wait`, `web_scroll`,
`web_screenshot` do the obvious things. The rest are the semantic layer:

- `web_open route:` picks the tab's network route. The grammar is one
  string: `direct` (the default), `tor` (through the SOCKS5 endpoint
  `mux_tor_socks_endpoint` names in config.conf), `via:<host>` (egress
  through that mux/SSH host) or `on:<host>` (the browser process itself
  runs on that host). Anything else is refused as `invalid_args`; an
  unparseable route never falls back to direct.

  A route is realized as a whole browser INSTANCE: its own
  `sketerm-webengine` process, its own profile directory and its own
  proxy, because one Chromium profile is one network context and
  cannot route two tabs differently. Two consequences worth planning
  for: a route sticks to the tab for its lifetime, across navigations;
  and each route has its own cookie jar, so a login on one route is not
  a login on another.

  Every web result carries the tab's actual `route`, and `web_tabs`
  lists it per tab. Read it rather than assuming the requested route
  was applied.

  Which kinds work depends on the backend, and `capabilities` reports
  that as `web_routes`: `gui` serves all four kinds; `headless` (the
  default isolated MCP mode) serves `direct` and `tor`, each as its own
  helper instance, and REFUSES `via:`/`on:`, because `via:` needs the GUI's
  local SOCKS5 bridge and `on:` a helper on the far host. A refusal
  opens nothing: a routed tab must never silently browse direct.

- `web_snapshot` returns the page as roles, names and stable ids. The
  FIRST snapshot of a document is complete; every later one is a
  **delta** against what was already sent, so an unchanged page answers
  `unchanged: true` with an empty body and a click answers with the two
  or three nodes that changed. Ask for a full snapshot explicitly when
  the client's own memory has been compacted away.
- Ids survive navigation where the content did: the server fingerprints
  subtrees and carries matching ones across a load, so moving between
  two pages of one site reports the shared chrome as carried rather
  than re-sending it.
- `web_act` acts on an id rather than a selector, and echoes what it
  actually hit.
- `web_expand` fetches text that a snapshot truncated; `web_read`
  returns the main content as prose; `web_query` spot-checks a subtree
  without paying for a snapshot; `web_eval` runs script, with DOM
  results returned as `{semantic_id, role, name}` so they feed straight
  back into `web_act`.

**Page content is untrusted input.** The reply channel is
authenticated, so a page cannot forge a snapshot or intercept a reply,
but a page owns its own DOM and can label a "Confirm payment" button
"Cancel". No server can adjudicate that, which is why `web_act` reports
what it clicked instead of refusing on content grounds.

### Browser review and durable evidence

`web_inspect` combines a bounded live DOM review with new page errors and
the existing console mirror. Use `selector` to narrow findings and
`screenshot:true` to include pixels. It lists landmarks, focus, control
names and disclosure attributes, wrapper/control mismatches, nested main
landmarks and horizontal overflow. Elements are described once in an
inspection-local reference table; these references are **not** `web_act`
ids. Coverage is the main document and open shadow roots, using the same
accname-lite naming as snapshots, not a full accessibility audit. Output
budgets and lost-error counts are explicit. The GUI backend reports its
missing native console mirror as unavailable; it still captures uncaught
page errors and promise rejections.

For document-preserving navigation:

1. Call `web_checkpoint` and retain its `checkpoint` id.
2. Use the ordinary `web_act`, `web_key`, etc. interaction tools.
3. Call `web_checkpoint` with `id` and a completion condition:
   `ready_selector` and/or `url_contains`, bounded by `timeout_ms`.

The result reports `document_preserved`, `passed`, URL before/after, focus
and errors since the checkpoint. `expect_preserved` defaults to true;
false tests a full navigation. A false `passed` is a failed assertion.
No navigation API is wrapped and no application window marker is planted:
identity belongs to the injected script's document context, so semantic
IDs carried across a reload cannot fool the assertion. BFCache restoration
of the original context counts as preservation. The MCP process retains
32 checkpoints for one hour; passing a checkpoint id to `web_inspect`
also scopes its error history.

Either tool accepts `out_dir:"/absolute/new-review-directory"` to export
`report.md`, `review.json` and, when requested, `screenshot.png`. The
parent must exist and the directory must be new: existing evidence is
never overwritten. Directories are private (0700), files 0600, and the
report is published last using the shared atomic writer. The report
contains the observations, viewport and wall-clock capture time, and
remains readable after closing the browser. Screenshot and DOM are
sampled sequentially, not atomically; a document change during capture
refuses the export. No cookies, storage or form values are collected;
URL userinfo, query and fragment are omitted, sensitive diagnostic text
is conservatively redacted. **Pixels can still show sensitive visible
page content**, so screenshot export is always explicit. A failed export
can leave partial files in its newly created directory, as the error says.

These operations require the helper's `review` capability; update the
helper as well as the MCP binary. `capabilities.web_review` describes
the support and limitations. Because optional export writes files, the
two review operations are classified as mutating in tool policy.

### Browser failure diagnostics

Headless browser failures include a stage, diagnostic id, exit code or
signal when observed, and a bounded redacted helper-stderr excerpt in
`error.details` as well as concise text. `web_diagnostic {"id":"..."}`
retrieves retained detail without starting another helper or finding a
log file. A cause is not guessed from helper death: an OS refusal is
reported as an OS refusal, not a broken CEF installation.

Capture is shared by direct and broker-owned launches. New brokers
advertise it in `engine_open`; old brokers and externally adopted
helpers may have no captured stderr. `stderr_available` and
`best_effort` make this distinction explicit. Capture uses bounded
nonblocking datagrams, so a noisy helper cannot block and a lingering
helper cannot receive SIGPIPE when its diagnostic reader disappears.
Under extreme logging, datagrams may be lost; an empty excerpt never
proves no errors were written. Only complete sanitized lines are
retained (8KiB; initial replies 2KiB). IDs last until the next launch
attempt on that route or MCP shutdown. GUI-owned launch capture is not
available through this tool; `capabilities.web_diagnostics` says so.

### Your own browser: the `web_gui` grant

In the default isolated mode the web tools run a PRIVATE
`sketerm-webengine` with its own cookie jar under
`$XDG_STATE_HOME/sketerm/web-profiles/<instance>/`, so the assistant is
logged in nowhere the user is. `--shared` is not the answer to that: it
hands every tool the user's daemon and GUI. The `web_gui` grant scopes
the user's own browser to the `web_*` tools alone; terminal, app, file
and panel tools keep the private daemon.

The setting has one name in three places, lowest precedence first:

| Source | Form | `web_gui_source` |
| --- | --- | --- |
| config.conf | `web_gui = true` in `[mcp]` (every run) or in the `[mcp.<name>]` that `--profile <name>` selects (a profile that omits the key inherits `[mcp]`) | `config` |
| environment | `SKETERM_MCP_WEB_GUI=1` (or `0` to override a config grant; anything else refuses to start, exit 2) | `env` |
| flag | `sketerm mcp --web-gui` | `flag` |

What it does, and the three rules a consumer can rely on:

- **Lazy.** Nothing is discovered or spawned until the first `web_*`
  call; `capabilities` never touches the GUI. A session that never
  browses never starts a browser.
- **Discover, else spawn.** The first web call looks for a running
  sketerm GUI's control socket (`$SKETERM_SOCKET` when the server runs
  inside a pane, else any live `$XDG_RUNTIME_DIR/sketerm/<pid>.sock`;
  any window can host a web tab, so two GUIs are not "ambiguous" here).
  With none running it starts `sketerm web` DETACHED (double-forked,
  its own session, stdio on /dev/null -- the MCP's stdio is the
  JSON-RPC stream) and waits up to 15s for its socket. The executable
  is this sketerm binary; `SKETERM_GUI_BIN=<path>` names another,
  started as `<path> web` (the smoke rig's fake GUI uses it). A GUI that
  disappears mid-session is found or started again on the next call.
- **Fails closed.** When no GUI can be reached the call answers
  `unavailable` with the reason; it never falls back to the private
  headless jar, because a quietly not-logged-in browser is exactly the
  bug the grant exists to fix.

`capabilities` reports `web_gui` (bool), `web_gui_source`
(`none|config|env|flag`) and `web_gui_transport`
(`none|discovered|spawned|explicit` -- `explicit` when a server-wide
`--socket`/`--shared` socket serves the web tools as before), with
`web_backend: gui` while granted. Under the grant the GUI-mode rules
apply: `profile:`/`ephemeral`, `policy`, `accept_cert`, `web_key`,
`web_resize` are refused as headless-only features, and the refusal
names the grant.

### Headless web profiles

`web_open profile:"work"` opens a view in a named, persistent browsing
identity (its own cookie jar and cache); `ephemeral:true` opens a
throwaway one; `web_profiles` lists them and `web_profile_reset` erases
one. Headless only: with a GUI attached, `profile` is refused
(`invalid_args`), because the GUI's containers are identities the user
owns and names.

- **Storage.** The helper's `--cache-dir` is the durable store root
  `$XDG_STATE_HOME/sketerm/web-profiles/<instance-key>/` (`--name`, else
  `anon`), because CEF requires every context's jar to be a child of the
  root cache. Each jar is `profile-<name>-<id>`; `profiles.json` persists
  the name-to-id table, since re-minting an id would hand a profile an
  empty jar. The root is never the GUI's own web cache: two CEF
  processes must not share one.
- **One owner.** The store root is flock'd for the engine's lifetime. A
  second process on the same instance key gets every profile request
  refused, naming the owning pid and suggesting `--name`; its engine
  keeps a volatile cache.
- **Fail closed.** A profile view needs both the `contexts` and
  `contexts-fail-closed` helper capabilities, an open store, and no
  `ev_view_create_failed` for the new view. There is no shared-jar
  fallback, ever; a refusal opens nothing.
- **Reset retires the id.** The entry is dropped and the jar removed, so
  the next use mints a fresh id and a fresh directory; a half-failed
  removal can never come back as that profile's cookies. Orphan jars
  are swept at open; a corrupt `profiles.json` is rebuilt from the jar
  directories rather than restarting at id 1. Resetting a profile with
  open views is a `conflict` naming them.
- **Persistence.** Only the directory is durable, and the engine flushes
  it only on a graceful helper exit. Chromium never persists session
  cookies. `profile` with `ephemeral`, and the reserved names `default`
  and `none`, are `invalid_args`.
- **Privacy.** Store directories are 0700, but a profile store is not a
  secret store: Chromium's Linux cookie encryption falls back to a fixed
  key when no keyring is available, which is the headless case.

`web_close` closes a view. With a GUI attached it closes one page of the
pane (the `web-close` control verb; an older GUI without it gets the
whole-pane `close-pane`), and the pane only with its last page.

### Enforced network policy

`web_open`'s `policy` object installs a per-view network policy that the
browser engine enforces before a request leaves the process
(`src/web/netpolicy.zig`, wire block 0x86 behind the `net-policy`
capability). Headless only; with a GUI it is `unavailable`, and
`web_network` is the GUI's equivalent.

- **Fields.** `allow_hosts` (top-level document hosts and their
  subdomains; empty = the url's host), `allow_subresource_hosts`,
  `block_types` (the filter engine's resource types), `block_ads` (the
  built-in filter list, the same switch as `web_network`),
  `allow_schemes` (default http+https; `file` must be explicit),
  `allow_private_addresses` (default false), and the budgets
  `max_requests`, `max_bytes`, `max_navigations`, `deadline_ms`. A host
  list holds at most 64 entries and a `*` entry is refused. `about:` is always allowed: it is a view's own blank
  document.
- **Fail closed.** A helper without the capability, or a full policy
  table, refuses the open and the view never loads a page; there is no
  unpoliced fallback. The policy frame travels before the `view_create` naming
  the view, so it governs the very first request.
- **Budgets latch.** Once one trips, `web_navigate`, `web_act`,
  `web_eval` and `web_wait for:"load"` answer `refused` with the
  numbers in the sentence; read tools keep answering and carry
  `policy_exhausted` and `policy_exhausted_reason` as facts. `web_policy`
  is the machine-readable accounting (requests, bytes, navigations,
  time left, refusals by reason). `max_bytes` stops the NEXT request
  after the crossing response completes.
- **Only tighter.** `web_policy_set pane:` patches a live view: host
  lists shrink, budgets lower, blocked types grow, private addresses
  only turn off. A field the call omits stays as it was. A pure
  loosening is `refused` naming every ignored field.
  `web_policy_set profile:` registers a session default that a later
  `web_open profile:` applies; it is in memory by design
  (`durable:false`).
- **Redirects.** Each redirect hop passes the same host gate (measured
  on the pinned CEF: a 302 target is its own gate entry, and the request
  id survives the chain, which is how a denial is named
  `redirect_host`); main-frame hops count toward `max_navigations`.
- **Limits.** Traffic with no browser behind it (service workers, the
  favicon fetcher's browserless probe) is not policed; a per-context
  resource handler would close that lane. Private-address refusal is
  literal-only: a hostname that resolves to a private address is not
  caught.

## Panels (`ui_*`)

`ui_show` renders a declarative document as native GTK widgets inside
the user's sketerm window: flowing or fixed-position layouts, images,
an A/B `image_compare` slider, text inputs, headings, sliders, selects,
progress bars, and buttons. The assistant
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

The tools are adapters over the control-socket commands `panel-show`,
`panel-patch`, `panel-get`, legacy destructive `panel-events`, v2 acknowledged
`panel-events-reliable`, `panel-list`, and `panel-close`, plus the disk store.
The mux negotiates the panel RPC version per attachment: v1 requesters continue
to use v1 or newer presenters, while v2 requesters route only to v2 presenters.
Every live panel has a random `event_epoch`. Reliable discovery uses `ack:0`
with `event_epoch` absent or empty; a retry may echo that epoch with `ack:0`, and
every nonzero acknowledgement must carry the exact current epoch. Missing,
malformed, and stale epochs return typed errors before the queue is changed.

### Component catalog

Documents use a flat `components` map and a `root` id. Child references
participate in one graph: every reference must resolve, a reachable component
may be mounted only once, and cycles are rejected. The complete component
vocabulary is:

- `column` / `row`: `{children:[ids]}`.
- `scene`: `{width,height,children:[{id,x,y,width,height}]}`. Logical and
  placement sizes are integers from 1 through 4096. `x` and `y` are integers
  from -1048576 through 1048576. Array order is z-order from back to front.
- `heading`: `{text,level}` with level 1 through 4; `text`: `{text}`.
- `text_input`: `{value,placeholder,clear_on_submit}`. All fields are optional;
  strings default to empty and are limited to 4096 UTF-8 bytes, while
  `clear_on_submit` defaults to false. Enter emits a `submit` event carrying
  the current text and optionally clears the entry locally.
- `image`: `{src,caption}`; `image_compare`:
  `{left:{src,label},right:{src,label}}`.
- `button`: `{text,action}`; `slider`: `{min,max,step,value}`; `select`:
  `{options,value}`.
- `progress`: `{value,label,indeterminate}`; `separator`; `spacer`: `{size}`.

Any component may use named classes from `dim`, `accent`, `success`, `warning`,
`error`, `card`, `monospace`, `center`, `end`, and `expand`. There is no raw
HTML, CSS, script, or arbitrary drawing component.

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
`panel_id`. A full re-show rebuilds the component tree, but preserves focus and
an unsent `text_input` draft when the replacement keeps the same declared
value. An in-place `text_input` patch follows the same rule: changing only its
placeholder or `clear_on_submit` keeps a focused/in-progress draft, while a
changed declared `value` is authoritative. Other widget-local state resets.
Use a leaf `ui_patch` to preserve state such as an `image_compare`'s zoom, pan,
and split while changing its images.

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
`text_input` Enter event has kind `submit` and carries up to 4096 UTF-8 bytes;
button actions and select options remain bounded to 128 bytes. A
panel the GUI confirms is absent ends the wait immediately and says so. A
pre-delivery transport failure instead reports that open/closed state and
queued events are unknown, with `events_may_have_been_drained: false` and
`resend_safe: true`. If a direct or relayed `panel-events` request was written
but its reply is lost, the error states that queued events may already have
been drained and does not retry or claim that nothing was missed.

Raw RPC v2 consumers may instead use `panel-events-reliable`. Successful
replies carry the same valid `event_epoch`, a nondecreasing `cursor`, cumulative
`dropped_total`, and events with strictly increasing nonzero `seq` values no
greater than the cursor. A legacy destructive reader that removes data retained
for reliable retry advances that cursor and increments `dropped_total`; a later
old acknowledgement therefore cannot regress or wedge the stream.

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
`panels`, or the operation-specific event fields). Reliable events are checked
one by one: every item is an object with a valid component id, known kind,
scalar value, nonnegative timestamp, and a strictly increasing nonzero sequence
not beyond the reply cursor. A presenter that answers badly fails
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

The relay-only `panel-open-session` operation accepts only `mux_session`, its
exact `mux_origin_id`, and a required safe-ASCII `request_token` of at most 128
bytes. The GUI derives transport and placement from the source relay scope.
Tokens are target-bound: an in-flight duplicate joins the original operation,
and a completed duplicate returns the original reply without opening another
tab. Each relay scope retains only the last 64 completed tokens; the cache dies
with that GUI relay scope, so a GUI restart cannot duplicate an old tab that no
longer exists.

Sessionless calls and daemons positively identified as predating panel relay
retain the explicit direct `--socket` path. If neither live transport exists,
the live tools fail honestly. Store-only calls remain available for
sessionless, explicit direct, default compatibility, validated exact lifetime,
and positively identified old-daemon scopes. An exact origin whose lifetime
scope cannot be validated returns the identity failure instead of entering a
reusable namespace. `ui_save` without a document also needs a live transport
to read the current document back.

`capabilities` is where every server-side capability is announced --
a consumer never has to probe for one. Browser facts: `web` /
`web_backend` (gui, session, headless, none), `web_profiles` (named
cookie jars work), `web_engine_broker` (the mux daemon spawns and keeps
the browser engine across this server's restarts, versus a
client-spawned engine that exits with its last client) and
`web_engine_owner` (who started the engine in use now: `none` before
the first view, `broker`, `self`, or `adopted` for a live engine another
client of the instance started). It reports `gui_socket`, `panels`, and `panels_store`
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

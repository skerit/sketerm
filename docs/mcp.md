# MCP Tools

`sketerm mcp` is a Model Context Protocol server on stdio. Its tools come
from one table (`src/ipc/mcp_tools.zig`) in nine groups; the reference
below lists every one. The pane tools drive the running GUI's panes when
a GUI socket is attached (`--shared`, or an explicit `--socket`) and the
headless terminals of the server's own daemon otherwise; the `term_*`,
`app_*`, `file_*` and forwarding tools always run against that daemon
(private per server by default, see `--name`/`--durable`). `capabilities`
is the one preflight: it reports what this server can reach right now.

## Headless hosts: `sketerm-mcp`

`sketerm mcp` lives in the GUI binary, which links GTK 4.14+ and libadwaita.
For a server without them, `zig build mcp-standalone` builds `sketerm-mcp`,
the same server with the portable daemon's dependency set: libc (plus libm)
is its only runtime dependency. Its arguments are what `sketerm mcp` takes
after `mcp`. It finds `sketerm-mux` and `sketerm-webengine` as siblings of
its own executable, so ship the three side by side:

```
zig build mcp-standalone -Dvideo=false -Dtarget=x86_64-linux-gnu.2.36 -Dcpu=baseline
zig build mux-portable                       # install as bin/sketerm-mux
zig build web -Dtarget=x86_64-linux-gnu.2.36 -Dcpu=baseline -Dcef-runtime-dir=/opt/sketerm/cef
```

Deploy `zig-out/share/sketerm/shell-integration/` alongside the `bin/`
directory as `share/sketerm/shell-integration/` too. The standalone build
installs these scripts; local shell command-completion tracking and SSH
shell bootstrapping need them. The browser helper and CEF are optional
when no browser tools are needed. `--web-gui` still requires a running
GUI, a sibling `sketerm` executable, or an explicit `SKETERM_GUI_BIN`.

Pick the `-Dtarget` glibc to match the server's (`ldd --version`) and use
`-Dcpu=baseline` because the default build is tuned to the build host's
CPU. `-Dvideo=false` is needed for any explicit `-Dtarget` because the
optional codec shims compile against the host's headers. The helper
loads `libcef.so` from `-Dcef-runtime-dir`, so copy the matching CEF
`Release/` directory there (the pinned CDN build needs glibc 2.25+;
`ldd libcef.so` on the server lists any system library to install).
A distro CEF of a different version will not do: the helper is bound to
the pinned CEF API. The one difference from the GUI's server:
`app_record_start` records GIF only (no libvpx), reported as
`capabilities.app_record_webm: false`.

After building `mcp-standalone` and `mux`, run
`python3 dist/test-mcp-standalone.py` to check a relocated installation
with no GUI sibling, including shell integration and WebM refusal.

## Browser handoff and following

An assistant-owned browser does not open a visible viewer automatically.
`backend: "headless"` describes the automation connection; it does **not** mean
that the user cannot see or drive it. When `web_open` reports
`handoff.available: true`, click Sketerm's orange **AI** badge, then **Watch**
(read-only) or **Take control** (for example, to log in manually).

Give the browser a descriptive name on its first open:

```json
{"name":"Account login","url":"https://example.com","profile":"work"}
```

The badge shows that name above a shortened domain. Later opens on the same
route add browser tabs; omit `name` to keep the session name. Prefer
`web_navigate` to continue in an existing tab, and leave that tab open while
waiting for manual login. Profiles describe cookie storage, independently of
the human-facing name.

To follow beside the assistant, select its pane and choose **Show beside pane**
in the AI badge. The same action relocates an existing viewer. The viewer retains its
place when the assistant closes its last tab: it waits for the next tab in
that browser and displays it automatically. Closing the viewer yourself stops
following and leaves the assistant's pages running.

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
- `file_sync`: Make a LOCAL directory's contents present in up to 32 destinations (SSH hosts and/or local paths) in one call: the docs-to-every-clone job that otherwise takes a tar, an scp_put per host and an unpack per host.
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
- `web_open`: Open a NEW browser TAB and return its handle and the first snapshot after navigation settles.
- `web_close`: Close one browser TAB.
- `web_profiles` (read-only): HEADLESS ONLY (with a GUI attached the browser's identity containers belong to the user).
- `web_profile_reset`: HEADLESS ONLY.
- `web_profile_save`: HEADLESS ONLY.
- `web_policy` (read-only): HEADLESS ONLY (with a GUI attached this refuses: the user's own tabs are not policed by an assistant).
- `web_policy_set`: HEADLESS ONLY (with a GUI attached this refuses).
- `web_navigate`: Navigate a web view: a 'url', or an 'action' (back|forward|reload|stop).
- `web_snapshot` (read-only): The page's ACCESSIBILITY-style tree as compact text: one line per node with a stable [id], role, name, states (focused/checked/disabled/required/invalid/expanded/current) and value.
- `web_act`: Act on an element: by semantic ID from web_snapshot/web_read, or by accessible 'name' (with optional 'role' and 'nth') to fold the find-then-act two-step into one call.
- `web_expand` (read-only): Full text of a node the snapshot truncated (the "(+N chars, expand [id])" marker), paged with offset/len.
- `web_query` (read-only): Cheap spot-check against the tree AS LAST SENT to you (no fresh DOM walk): find_text (nodes whose name contains 'arg'), subtree (children of the node id in 'arg'), focused, form (every form control with its value and checked/disabled states and the row or group it sits in - what Apply would submit; 'arg' = a node id to scope it, or omit for the page), or within_text ('arg' = JSON {"text","name","role"}: the controls named name under the smallest container that also holds text, the same resolution web_act within_text uses).
- `web_read` (read-only): READ THE PAGE: reader-mode markdown of the main content (headings, paragraphs, lists, code, links), with navigation and boilerplate dropped, plus stable semantic IDs for useful sections/headings/links/items.
- `web_wait` (read-only): Wait until the view reaches a state: "load" (no load in flight), "title" (its title contains 'arg', or any title when arg is omitted), "text" ('arg' appears in the page's semantic tree), "idle" (the DOM stopped changing for 600ms) or "response" (headless, a view opened with a capture: a CAPTURED exchange matching the 'response' filter finished after cursor 'since' - default: after this call starts - or, with after_seq, one whose request came after that web_network seq; the reply carries the exchange, read its body with web_capture seq:N).
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
- `web_capture` (read-only): HEADLESS ONLY: read what a view's CAPTURE recorded (web_open 'capture' installs one), the response bodies the page itself received, exactly as it received them (decompressed; request bodies and response headers too).
- `web_capture_set`: HEADLESS ONLY: NARROW a view's live capture, never widen it (the same rule a live network policy follows).

### `ui`

- `ui_show`: Show the user a real native UI PANEL in their sketerm window: a declarative document rendered as GTK widgets, not text or a screenshot.
- `ui_show_files`: FAST PATH for "show me these images": hand it a list of image files on the session's host and it builds the panel document for you and shows it — ONE call instead of hand-authoring a ui_show document.
- `ui_patch`: Update a live panel with a JSON array of ops applied as one transaction.
- `ui_wait_event` (read-only): Block until the user interacts with a panel, then return queued interactions with component id and monotonic timestamp: button click values are actions, slider/select changes carry their new value, a checkbox change carries true/false, a table click carries the activated row index, and text_input submit carries up to 4096 UTF-8 bytes.
- `ui_panels` (read-only): Inventory of panels in a session, in two clearly separate lists: LIVE panels (on screen right now — panel_id, name, title, target) and SAVED documents (stored on disk by ui_save — name, title, size, mtime, and whether the stored file still parses).
- `ui_save`: Persist a panel document to disk under the session's daemon origin and lifetime id so a later ui_show can bring it back with load=<name>.
- `ui_close`: Close a LIVE panel: it disappears from the user's screen.
- `ui_delete`: DESTRUCTIVE: permanently delete a SAVED panel document from disk.

### `agent`

- `agent_adapters` (read-only): List the agent adapters this server can run (shipped ones plus user files in $XDG_CONFIG_HOME/sketerm/agents/*.json), whether each app's binary is installed on this machine (and where), and which actions each supports.
- `agent_open`: Run another coding agent as a SUB-AGENT and talk to it in clean records, never raw screens: app "claude" (Claude Code) or "opencode" (see agent_adapters).
- `agent_send`: Send a prompt to an agent and wait (bounded, timeout_ms default 60000, max 120000) for the turn.
- `agent_wait` (read-only): Wait (bounded, timeout_ms default 60000, max 120000) for an agent's next wake-up, with agent_send's filter rules, and return the events no result or waiter delivered before (a turn that finished meanwhile answers at once, with its job's answer and key messages, as agent_send).
- `agent_read` (read-only): Read what an agent did, per JOB (one user prompt and everything until the next, turns the agent started on its own included), returning only what no result has handed you before: delivery is per record, so every selected message reaches you once, whether a read or a done result (agent_send/agent_wait/agent_answer/agent_open) carried it; a job's earlier ones are not repeated, jobs[].earlier points at one, and with nothing new the read says so and returns no records.
- `agent_answer`: Answer the agent's pending prompt (permission, question or choice; see interaction) with `choice` (an option label, its 1-based number or a unique part of a label) OR `text` (a free-text answer, when interaction.free_text says the prompt takes one), then wait for the turn like agent_send.
- `agent_set`: Change an agent's model and/or effort level for THIS session only, never the user's defaults (Claude Code: /model with its session-only choice, confirmed by the app before this returns; effort by restarting Claude Code in the same terminal with --effort and resuming the conversation, since its /effort saves the user's default; opencode: the model and variant of the prompts this agent sends).
- `agent_interrupt`: Interrupt an agent's running turn (Claude Code: Escape; opencode: abort, subagents included).
- `agent_ask`: Ask an agent a SIDE QUESTION ("how far are you?", "which file are you editing?") and get its answer in this result: the app answers from its current context without a turn (Claude Code's /btw), whether it is busy or idle, and a running turn is NOT interrupted and goes on.
- `agent_list` (read-only): List this server's agents, one line each.
- `agent_close`: Stop an agent: kills its session(s) and ends its waiters.
- `agent_attach`: Resume an agent: `agent` (an id agent_open returned, or its name) picks up a live agent of THIS MACHINE from any MCP server, e.g. after a restart, and returns exactly one outcome in `attach`: reattached (it is yours again, with its latest job's selected records, as a first agent_read returns them), gone (its daemon answered that its session no longer exists, with `reason`: expired = no client for mcp_agent_idle_ttl_hours, exited with exit_status or signal, closed, or unknown when the daemon keeps no record), or unreachable (its host or daemon did not answer: `host` and `ssh_error`; its entry stays, so try again later).
- `agent_template_save`: Save a named BRIEF TEMPLATE (per user, $XDG_STATE_HOME/sketerm/agent-templates/<name>.json, mode 0600; replaces one of the same name): the rules every brief to your sub-agents repeats, written once.
- `agent_templates` (read-only): List the saved brief templates (name, description, variable names); with `name`, show one in full: its text and its variables with their defaults.
- `agent_template_delete`: Delete a saved brief template (no undo).

### `core`

- `capabilities` (read-only): Preflight report of what THIS MCP server can do right now: isolation mode, headless GUI-app support (headless_gui — launch_app renders apps into the mux daemon and NEVER needs a display, an X server or a sketerm window), whether a direct sketerm GUI control socket is attached (gui_socket; independent of the session panel relay and of headless GUI apps), the live panel transport (panels + panel_transport) and the saved-panel store (panels_store + panel_store), OCR (tesseract) availability, whether the web_* tools can run and against what (web + web_backend "gui"/"session"/"headless"/"none" — "session" adds web_session, the watchable Wayland app session the helper renders into — plus the sketerm-webengine path in web_helper; web_gui says whether the user granted the web_* tools their OWN browser and logins, web_gui_source where that came from and web_gui_transport which GUI socket they hold now; web_profiles says whether named cookie jars work, web_routes which per-tab network routes web_open can honour, web_engine_broker whether the mux daemon owns the engine's lifetime and web_engine_owner who started the one in use; web_downloads whether web_download can pull a url through a view; web_capture whether web_open can record the response bodies a headless view's page receives; web_engine_started whether an engine exists YET, since web_backend/web_watch/web_session are undetermined until it does), ssh/scp presence, the directory terminal asciicast recordings land in, the EFFECTIVE input-timing defaults (hold_ms/settle_ms/timeout_ms/click_retry, each marked when a SKETERM_MCP_* env override changed it from the built-in), whether sub-agents run here (agents, agent_adapters, agent_waiter, agent_ssh, agent_open_args_env for a wrapper's args and env, agent_open_resume for continuing an existing conversation (agent_resume_checked: an unknown id fails instead of starting afresh), agent_open_process_args for server_args/tui_args, agent_conversation for the conversation id results report, user_daemon_env_scrubbed for a per-user daemon started without the assistant's environment, agent_resume_by_id for agent_attach {agent} from any server, agent_idle_ttl_hours for how long an unattached agent lives, tombstones for agent_attach saying why a gone agent ended) and how agent_read selects what it returns (agent_read_select), how sub-agent output is delivered (agent_records_once, agent_events_shared), whether agent_wait can watch several agents (agent_wait_any; agent_wait_all: once every one settled), whether agent_send queues a prompt for a busy agent (agent_send_queue), reaches several agents in one call (agent_send_many) and interrupts a busy one first (agent_send_interrupt), whether agent_read returns just the final message (agent_read_final), agent_list is compact by default (agent_list_compact), each agent's attention is published for `sketerm mcp agents` (agent_attention), agent_attach relaunches a gone agent (agent_relaunch) and agent_open hands a prompt off with timeout_ms 0 (agent_open_handoff), whether agent_answer takes free text (agent_answer_text), agent_open takes a permission policy (agent_permissions), brief templates (agent_templates), side questions (agent_side_question: the apps agent_ask works with) and retry_on_overload (agent_retry_on_overload: the error classes it retries and its bounds), a lost link that finds its session gone ends the agent (agent_gone_on_reconnect), when done fires (agent_done), and whether agent events are pushed into this session (agent_push: channel = Claude Code channel messages; agent_push_follow / agent_push_followers for the agent-wait --server follower the opencode plugin runs), whether term_open takes exec_shell (term_exec_shell_default), and open session counts.
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

## Syncing a directory (`file_sync`)

`file_sync {local_dir, targets: [{host?, path}], keep_newer, delete,
exclude, dry_run}` makes the CONTENTS of `local_dir` present in up to 32
destinations: SSH hosts, and local directories when `host` is omitted.
It replaces the tar + `scp_put` per host + unpack per host loop.

- **Method per target.** Each distinct host is probed once per call
  (`rsync --version` and `tar`). When rsync works on BOTH ends the
  target syncs with `rsync -rlpt`, its `-e` built from the same ssh
  options every sketerm leg uses (ForwardX11=no, BatchMode, sketerm's
  ControlMaster, a forced Tor route). Otherwise a tar stream goes over
  ssh: it is extracted into `.sketerm-sync-<nonce>/` INSIDE the target,
  every staged file's SHA-256 is checked against the local hash before
  anything lands (one mismatch applies nothing), then each entry is moved
  into place. The method is a per-target fact (`method`), and so is how
  the landed files were verified (`verification`).
- **keep_newer** (default true) never overwrites a destination file
  modified after the local copy: rsync `--update`; in tar mode the
  manifest diff skips it and the apply re-checks with `find -newer`, so a
  file changed on the host between the two is still kept. With
  `keep_newer:false`, content decides (`--checksum`, or the sha256
  manifest).
- **delete** removes destination files `local_dir` lacks, strictly
  inside the target, and never what an `exclude` pattern covers. It only
  runs on an explicit `delete:true`, is refused for a target directory
  that does not already exist, and is refused outright for an empty
  `local_dir`.
- **Refusals.** A target that is `/` or the home directory (also as the
  HOST resolves it, so a symlink to either is caught), a path with `..`,
  an empty path, a target that exists as a file, a local target nested
  with `local_dir`, the same destination twice, and (tar mode) a path
  that is a file on one side and a directory on the other. Symlinks in
  `local_dir` are copied as links and never followed.
- **dry_run** changes and creates nothing; each target reports what it
  would send and delete (`sent`/`deleted`) and the text lane lists the
  first paths.
- At most 4 targets run at once, one deadline (`timeout_ms`, max 120 s)
  covers every leg, and a failed target is a `targets[]` entry with
  `status:"failed"` and an `error`, never an aborted call.
  `capabilities` reports `file_sync` and `file_sync_local_rsync`.

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

`term_exec` runs its command in a fresh `sh` by default, or in the
interpreter its `shell` names (bash for pipefail). `term_open
exec_shell: "bash"` makes that the terminal's default
(`capabilities.term_exec_shell_default`): every `term_exec` there runs
its command file with it unless the call names another `shell`, which
is what a fish login shell needs on every call otherwise. It is checked
like `shell` (a command name or absolute path of letters, digits, `.`,
`_`, `-`, `/`; anything else is `invalid_args`), applies only to the
isolated transport (`subshell: false` types into the session's own
shell), and `term_open` and `term_list` report it as `exec_shell`.

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
  `max_requests`, `max_bytes`, `max_navigations`, `deadline_ms`, plus
  `untrusted` (default false; the restricted mode below). Unknown keys
  are errors. A host list holds at most 64 entries and a `*` entry is refused. Entries can carry
  a port (`example.com:8443`, `[2001:db8::1]:443`). Explicit ports are
  enforced in every mode. Bare entries allow all ports ordinarily, but
  only the scheme's default port in untrusted mode. An IP-literal entry
  matches that exact address (any spelling of it), never as a domain
  suffix; a hostname entry never matches an address, and fragments such as
  `0.1` are refused. Internationalized hosts must be given in punycode
  (`xn--`) form. `about:` is always
  allowed for the view's own blank document; it does not enable arbitrary
  external protocols.
- **Fail closed.** A helper without the capability refuses the open and
  the view never loads a page; there is no unpoliced fallback. A full
  policy table (32 policied views per helper) refuses only the view that
  did not fit; the helper's other views keep working. The policy frame travels before the `view_create` naming
  the view, so it governs the very first request.
- **Installation acknowledgement.** `capabilities.web_policy_ack` is the
  current helper's verified `net-policy-ack` capability: null before its
  handshake, then boolean (false with a GUI backend). Untrusted opens and
  every live update require it. An untrusted initial install must receive
  its correlated successful acknowledgement before a browser is created.
  The client commits a live replacement only after its matching helper
  acknowledgement, not after sending it. Refusal, timeout or allocation
  failure closes the affected view fail-closed; rejected replacement or
  loosening latches `policy_refused` in the helper. A successful tightening
  preserves counters, the original deadline and exhaustion latches.
  Policy-status queries are also correlated, so a late status reply cannot
  satisfy a newer query. A status query (`web_policy`) only reads: when it
  times out or reports the policy refused, the view and its policy are left
  exactly as they were. Ordinary initial opens retain the ordered-frame
  contract with helpers lacking the acknowledgement capability.
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
- **Ordinary-mode limits.** Traffic with no browser behind it (service workers, the
  favicon fetcher's browserless probe) is not policed; a per-context
  resource handler would close that lane. Private-address refusal is
  literal-only: a hostname that resolves to a private address is not
  caught.

### Untrusted Loading

`web_open policy:{"untrusted":true} ephemeral:true route:"direct"` selects
a dedicated restricted helper automatically. This is Linux-only and
headless-only. Named profiles and the default identity are refused. Every
view in that helper must carry an untrusted policy and an ephemeral identity.
Ordinary route helpers remain separate; their existing behavior is unchanged,
and ordinary and untrusted views can coexist with stable handles.

The helper runs with `--untrusted`, software rendering, and no presenter,
helper adoption, durable store or broker-owned persistent engine. Its
renderers run Chromium's own namespace sandbox (user, PID and network
namespaces plus seccomp-bpf), which ordinary helpers do not use: a renderer
compromised by page script has no filesystem, no sockets of its own and no
route to the user's sessions. That requires unprivileged user namespaces;
without them Chromium refuses to start ("No usable sandbox") and the open
fails, never falling back to an unsandboxed renderer. It also requires
libcurl headers and a runtime library at least 7.85 with HTTP/HTTPS and TLS
support, plus Linux seccomp TSYNC; unavailable prerequisites refuse startup,
never fall back to the ordinary loader. The HTTP broker loads libcurl
dynamically; the mux daemon gains no CEF or curl dependency.

An independent subreaper supervisor creates and owns a fresh 0700 root at
`$XDG_RUNTIME_DIR/sketerm/u/<16 hex>` (the parents must be 0700 and owned by
the user, or the open is refused; a root whose `t` subdirectory would exceed
60 bytes is refused too, because Chromium places sockets under it). The
browser's `HOME`, `TMPDIR` and `XDG_*` directories all point into that root,
so nothing Chromium writes outlives it, and the session bus, display, audio
and sketerm socket variables are removed from its environment. Closing the
last untrusted view terminates the helper. Last-view close, startup failure,
helper/browser crash, MCP shutdown and MCP-parent SIGKILL all retire the
supervised browser, broker and their descendants. Only after `waitpid`
reports `ECHILD` does the supervisor delete the root, without following
symlinks or crossing filesystems. Descendants are found through
`/proc/self/task/*/children`, or a `/proc/*/stat` scan on kernels without
it. Deletion repairs owner permissions it finds stripped and gives up after
30 attempts; the supervisor then exits with status 251, which MCP logs, and
the next untrusted supervisor sweeps such stale roots once their owner is
gone. The supervisor does not depend on MCP running a shutdown handler.
Every process starts with both soft and hard `RLIMIT_CORE` at zero (for
which systemd-coredump stores no core). The browser turns nondumpable after
initialization and each renderer at its first script context; zygotes stay
dumpable, because a nondumpable process cannot map the namespace sandbox's
user namespace. These are kernel core-dump controls, not a claim that every
application crash reporter or external privileged collector can never write
a file.

`capabilities.web_untrusted` is a build fact: true when this server is a
Linux headless backend with a resolvable helper binary, false otherwise,
whichever engine is current. It is absent from builds without untrusted
mode, so a client that requires it must treat a missing key as "no". Each
open still requires the launched helper to advertise `untrusted-web` and
fails closed otherwise. `web_policy_ack` independently reports
`net-policy-ack`.
`web_untrusted_mode` names the current engine's selected mode;
selection alone is not a claim of enforcement. No unsupported helper may open
an untrusted view. Setting `untrusted` in either direction on a live view is
refused and requires a new dedicated instance. Unknown policy keys are errors.
An omitted/empty top-level host list defaults to the URL's effective port as
well as its host in untrusted mode.

For a verified untrusted view, `web_policy.enforced` reports this matrix.
The existing `internet_sockets`, `http_broker`, `service_workers`,
`websockets`, `webrtc`, `extensions`, `methods`, `ranges`,
`max_response_bytes` and `response_timeout_ms` facts remain compatible.
False feature flags mean the operation or traffic is denied, not that the
JavaScript API is necessarily absent. The explicit `disabled_lanes`, `cors`,
`credentials`, `redirects`, `permissions`, `downloads` and `cleanup` facts
describe the actual enforcement responsibility.

| Lane | Untrusted contract |
| --- | --- |
| Native network | Seccomp denies Internet socket/socketpair creation in the browser and its subprocesses, including UDP/QUIC; inherited Internet sockets are refused and io_uring is denied. AF_UNIX IPC and NETLINK_ROUTE remain available. Only the separate HTTP broker has Internet sockets. |
| Broker destinations | The policy checks scheme, host and effective port; the broker checks each actual binary IPv4/IPv6 socket address and port before connection. Private, loopback, link-local, mapped and special-purpose ranges, and every address currently assigned to one of this host's interfaces (a public address included), are refused by default, including hostname resolution and DNS rebinding. `allow_private_addresses:true` explicitly permits those addresses while retaining scheme, host, port and all other restrictions. |
| Renderer sandbox | Renderers run Chromium's namespace sandbox (user/PID/network namespaces + seccomp-bpf) on top of the helper's socket filter. Reported as `renderer_sandbox`. |
| Navigation | GET/HEAD and same-origin POST for top-level and subframe documents; CEF follows navigation redirects and every hop repeats policy and actual-address/port checks. |
| Same-origin resources | GET/HEAD/POST using the native CEF initiator's exact scheme/host/port, with ephemeral context cookies. Author headers are validated; an `Origin` header is consistency-checked and never supplies authority. |
| Cross-origin fetch/XHR | Denied before network, even with valid CORS headers, because CEF custom responses cannot faithfully preserve Fetch response tainting, opaque bodies or exposed-header semantics. |
| Cross-origin images/media | Denied before network to avoid exposing unsafe canvas/media/body lanes. Same-origin images/media remain subject to attribution and policy. |
| Workers/opaque documents | All worker HTTP(S) loads are denied. Navigation responses add a separate browser-enforced `Content-Security-Policy: worker-src 'none'`, preserving existing policies and blocking HTTP/blob worker bootstraps and inherited document cases. HTTP subresources with empty/null initiators are refused, including libraries requested directly from opaque documents. |
| Cross-origin scripts/styles/fonts | GET only from HTTP(S) documents, with safelisted author headers, no HTTPS-to-HTTP downgrade, 2xx, exactly one `Access-Control-Allow-Origin: *` and matching MIME. Scripts require `text/javascript` or `application/javascript`; styles require `text/css`; fonts require `font/woff`, `font/woff2`, `font/ttf`, `font/otf` or `application/font-woff`. `Cross-Origin-Resource-Policy`, if present, must be `cross-origin`. Cookie/Referer request headers and Set-Cookie response headers are stripped; the broker supplies Origin from native initiator metadata. |
| Non-navigation redirects | Denied, even same-origin; the broker never follows redirects itself. |
| Unsupported HTTP | Ranges/partial responses, file uploads, URL userinfo, HTTP/proxy authentication and protocol upgrades are denied. The broker has no cookie jar, ignores ambient proxies and netrc, uses HTTP/1.1, and verifies TLS peer and hostname. `accept_cert` cannot loosen broker TLS verification. |
| Unattributed/background traffic | Browserless loads, service-worker scripts/navigation preload, prefetch, favicon probes, and extension traffic are denied; context-level interception has no ordinary-network fallback. |
| Alternate network lanes | WebSocket, WebRTC and WebTransport network traffic is denied by native socket confinement, not JavaScript constructor replacement. Preconnect/DNS-prefetch prediction is disabled; Chromium's network path cannot bypass the broker. Broker DNS resolution remains necessary for allowed HTTP requests. |
| Permissions | All native permission/media-access prompts are denied. Fresh-context settings block USB, Bluetooth/scanning, HID, serial, NFC, notifications, geolocation, clipboard read, microphone/camera, MIDI sysex, sensors, filesystem access, background sync and direct sockets. Startup verifies effective settings; selected Blink APIs are disabled natively, not by injected JavaScript guards. Chromium may still grant sanitized clipboard writes without a prompt; `clipboard_sanitized_write` reports this limitation rather than claiming those writes are denied. |
| Popups/downloads | Page popups and both page-initiated and client-requested downloads are denied, including blob downloads. No target file is authorized. |
| Hard loader limits | At most 16 active broker jobs; further loads wait first-in first-out, up to 256, and past that are refused `untrusted_queue_full`. 8 KiB URLs (longer: `url_too_long`), 1 MiB byte-only upload, 64 KiB headers, 16 MiB decoded response and a 15-second deadline counted from when the load was opened, queueing and blocking resolver work included (`untrusted_timeout`). These are independent of policy budgets; oversize/unsupported responses fail rather than silently returning a prefix. Each broker job confines itself with Landlock where the kernel has it (no file writes, TCP only to the target port and DNS); a kernel without Landlock still loads, a failed Landlock setup refuses the load. |
| Cleanup/core controls | Independent supervisor owns retirement and root deletion after all descendants are reaped, including MCP-parent SIGKILL. Deletion is bounded (exit 251, swept by the next supervisor). Kernel core limits are zero; browser and renderers are nondumpable as described above. |
| Withheld helper requests | DevTools, PDF printing, WebExtensions, userscripts, observers and cookie sync are not advertised, and a request for one is refused at dispatch (`ev_request_refused`), never served. |

Policy budgets and tighter-only patches still apply; no policy field can
loosen these loader restrictions except the explicit private-address opt-in.
Budget-refused navigation is canceled before replacing the readable document;
native controller history operations use the same gate. Untrusted helpers
disable back/forward caching so page-driven history restoration cannot skip
the navigation hook. Native Chromium extensions and default background
components are disabled in addition to withholding Sketerm extension APIs;
this does not claim that Chromium contains no internal component-extension code.

The HTTP broker reconstructs `Sec-Fetch-Dest`, `Sec-Fetch-Mode`,
`Sec-Fetch-Site` and activated-navigation `Sec-Fetch-User` because CEF's
intercepted header map precedes Chromium's network-service metadata step.
Document/iframe navigation, classic and CORS/module libraries, images, fonts
and default fetch/XHR receive metadata on HTTPS and trustworthy loopback HTTP
origins. Copied `Sec-Fetch-*` fields are replaced. Navigation origin and
activation come from native callbacks and do not change policy authorization.
Same-site subdomain classification uses curl's runtime libpsl when available;
without it, different hosts are conservatively classified cross-site. CEF
does not expose arbitrary fetch modes or audio/video destination distinctions,
so this is not full Fetch Metadata fidelity for every resource shape.

Untrusted refusals are counted in `web_policy` and `web_network` under these
reasons, beside the ordinary ones: `resolved_private_address`,
`untrusted_http` (an unsupported HTTP shape), `untrusted_transport` (a lane
that is disabled outright), `untrusted_broker`, `untrusted_timeout`,
`untrusted_queue_full`, `url_too_long`, `malformed_url` and `policy_refused`.

The threat model is hostile web content under the native request/permission
boundaries. A renderer exploit is contained by Chromium's sandbox; a chain
that also escapes it (a browser-process or kernel exploit), a privileged or
same-user native attacker passing descriptors over AF_UNIX, killing the cleanup supervisor itself, machine failure and an
external privileged crash collector are outside that guarantee. Page-authored
DOM, text and evaluated results remain untrusted data, not instructions.

The tests do not download dependencies or fixtures:

- `zig build test-web-untrusted-native` compiles and runs the native loader
  and independent-supervisor C suites against the selected CEF headers and
  runtime, without starting a browser.
- `zig build test-web-untrusted-rig` runs
  `dist/test-web-untrusted.py --rig-only`; it validates the test machinery,
  not browser enforcement.
- `zig build smoke-web-untrusted` builds fresh helper and GTK-free MCP
  artifacts and runs the full browser matrix in rootless user/mount/network/PID
  namespaces, with a private DNS resolver and real QUIC/WebTransport responder,
  followed by native policy/media acknowledgement-failure tests. It requires
  util-linux, iproute2, and Python `aioquic`/`cryptography`; dependencies are not
  downloaded automatically. Host resolver files and interfaces are untouched.

### View Emulation

Headless `web_open` accepts `color_scheme:"light"|"dark"`,
`reduced_motion:"reduce"|"no-preference"`, and numeric
`device_scale_factor` from 0.5 through 4. Omitted settings keep engine defaults.
These options require the verified `web-emulation` capability; an unsupported
helper or GUI backend refuses the open, without loading a page. The settings
are sent before view creation. A native DevTools MediaObserver must receive
the matching successful execution acknowledgement within 5 seconds before
the initial URL loads; submission alone is not success. Asynchronous refusal,
timeout or agent detachment fails the affected view rather than exposing an
unemulated initial document. `web_open` echoes the selected settings.
Device scale uses native view geometry, not a JavaScript `devicePixelRatio`
override; scale is rounded to thousandths and survives `web_resize`, with
input and screenshot dimensions using the same geometry.
`capabilities.web_emulation` is null until the helper handshake, then boolean.
CEF applies media emulation internally through DevTools commands without
opening a remote debugging port or installing page-side JavaScript guards.

## Sub-agents (`agent_*`)

The `agent` group runs another coding agent as a sub-agent and reads it
through an adapter (`data/agents/*.json`, user overrides in
`$XDG_CONFIG_HOME/sketerm/agents/`): records (user, assistant, tool,
notice) grouped into jobs, a state, the pending prompt and events, never
raw screens.
Claude Code is a `screen` source (launched with `--ax-screen-reader`, read
off its terminal); opencode is an `opencode_api` source (`opencode serve`
on a free loopback port, read over its HTTP API and SSE stream; its
TUI attached to that server for a human to watch is optional, see below).

- **opencode's server generations (`api_version`,
  `capabilities.agent_api_versions`).** opencode 2.x moved its API under
  `/api/` and reshaped it (replies wrapped in `{data}`; prompts admitted
  to a session inbox and taken later; one assistant message per model
  step; questions are forms; the model is set on the session; the TUI
  connects with `opencode --server <url>`, there is no `attach`), while
  1.x builds (the oc11 fork among them) keep the old routes. Both are
  declared in the adapter as data (`api.generations`, newest first: a
  name, a dialect, a probe path, the TUI's `attach_args` and every
  route), and the shapes each dialect speaks live in ONE module
  (`src/agent/opencode_dialect.zig`), which translates 2.x into the 1.x
  vocabulary the source reads, so the turn, done and record rules are the
  same code for both. The generation is detected once, from the running
  server, when it first answers: each generation's probe in order, the
  first answered 200 with a JSON object wins (2.x answers every unknown
  path, the old ones included, with its web UI's HTML; 1.x answers
  `/api/info` that way), and never from `--version`. A server that
  answers every probe without matching one is refused at once
  (`unavailable`, naming what each probe got). Per-agent results carry
  `api_version` (`"2"` or `"1"`). Differences: a prompt sent to a busy
  2.x session waits in its inbox (`delivery: queue`) and starts its job
  only when the loop takes it, so `queued_prompts` counts the inbox; an
  interrupt PARKS queued prompts there (2.x runs them after the next
  prompt), so they are neither dropped nor typed again; a model or
  effort chosen with `agent_set` is set on the session before the next
  prompt or command; a 2.x form's field types (string with options,
  multi-select, boolean, number) map onto the question interaction, and
  answers are sent as the fields' option values.

- **opencode's attached TUI is optional (`capabilities.agent_tui`).**
  The adapter declares it (`attach_args` per server generation, and
  `launch.attach_default`: opencode's is `false`, because the TUI burns
  about 45% of a core while it runs and the agent is driven over the API
  either way), so an agent starts WITHOUT it: its `session` is then the
  server's (`agent-<id>-server`, the one the GUI watches), and `tui` is
  `false` on every per-agent result. `agent_open tui: true` starts it
  (session `agent-<id>`), and `agent_set tui: true|false` starts or
  stops it on a live agent (its password rides the spawn here and is
  typed on a remote host, as for the server). The setting is kept in the
  descriptor (`tui`), so a relaunch or re-attach starts it again; a TUI
  that is not running any more (a human quit it) never fails a re-attach,
  it is just not there, and an older descriptor reads as "a TUI when its
  session is not the server's". Readiness, delivery (the API's 2xx),
  facts, the port forward of a remote agent and `agent_close` never
  depended on it. `tui` is `invalid_args` for an app whose terminal is
  the app itself (Claude Code).

- **Sessions and ids.** An agent's id is machine-unique and short:
  `<app>-xxxx` (four lowercase base32 characters, `claude-k3f9`), checked
  against the per-user index below. Its session is `agent-<id>` (opencode
  adds `agent-<id>-server`) on the PER-USER daemon of the host it runs on
  (this machine's, the one the GUI uses, or the remote host's), so the GUI's
  AI badge and Session Overview list it for watch-along. `agent_open name:`
  gives it an alias usable wherever the id is (every `agent_*` call,
  `agent_attach`), unique among this machine's live agents (a taken name
  is `conflict`, never reused), listed by `agent_list` and used as the
  session's title (`SpawnReq.title`; an older daemon ignores it).
  `term_open name:` does the same for a terminal (unique among this
  server's terminals; `term` takes it, `term_list` shows it).
- **Agents outlive their MCP server.** A server that exits only detaches:
  every agent session (Claude Code, opencode's server and its TUI when it
  runs, the local
  end of a plain-ssh agent) is spawned with the daemon-enforced
  `ttl_secs` of `mcp_agent_idle_ttl_hours` (config, default 24), so it
  ends after that long with no client attached. `agent_close` ends one at
  once. Every agent has a 0600 descriptor in the per-user index
  `$XDG_STATE_HOME/sketerm/agents/<id>.json` (adapter, host, transport,
  session names and lifetime ids, daemon socket, opencode port, password
  file and API session, conversation id, launch values, args/env, name),
  removed when the agent is closed, or ends or is found gone with no way
  to start it again; an agent that ended and can be relaunched keeps its
  descriptor, stamped `gone_ms`, for `mcp_agent_idle_ttl_hours` (the
  next server start sweeps it after that). `agent_attach {agent: <id or name>}` resumes one
  from ANY server on this machine and answers exactly one of `reattached`
  (with its latest job's selected records), `gone` (its daemon answered
  that the session no longer exists: `reason` expired, exited with
  `exit_status`/`signal`, closed, or unknown when the daemon keeps no
  record) or `unreachable` (`host` and `ssh_error`; the entry stays).
  **Relaunch (`capabilities.agent_relaunch`).** A `gone` agent whose
  launch settings and conversation are known says so (`relaunchable:
  true`, and its text names the call); `agent_attach {agent, relaunch:
  true}` then starts it again with what its descriptor holds: the same
  binary, host, transport, cwd, model, effort, `args`/`env`/`server_args`/
  `tui_args`, `path_prepend` and login shell, resuming the same
  conversation (Claude Code `--resume`, opencode's API session; a Claude
  Code agent that never had a turn starts a fresh one), under the SAME
  agent id and name (`attach: "relaunched"`, every per-agent fact, a
  model chosen in the app since re-chosen). The case it is for: the host
  rebooted, so the daemon has no session (no tombstone either) while the
  index still names the agent. Without `relaunch` a gone agent stays
  gone; an agent whose session still runs is reattached instead; an agent
  whose app ended under this very server is let go and relaunched the
  same way. A conversation the app no longer has fails as for `resume`
  (`not_found`) and the descriptor goes; any other failure leaves it, so
  the relaunch can be tried again.
  Ownership is a held flock on `<id>.lock`, never a pid: an agent another
  LIVE server drives is refused as `conflict` unless `takeover: true`,
  which replaces the lock file; the displaced server notices between
  requests and lets the agent go. There is no auto-reattach for an
  isolated server; a durable instance (`--name`) still picks up at startup
  the agents it opened (and its pre-index descriptors in
  `<instance>/agents/`, migrated into the index). At startup every server
  drops index entries whose local session its daemon says ended.
- **Why a session ended (tombstones).** The daemon (broker) keeps a short
  record of ended sessions: name, lifetime id, end time and reason
  (`expired`, `exited` with status or signal, `closed`, `unknown`), at
  most 256 entries and 48 h (`src/mux/tombstones.zig`), answered by
  `tombstone_get`/`tombstone_reply` behind the `tombstones` welcome
  capability. A worker reports its session's end in a `'T'` control
  datagram before it goes. An older daemon has none: `gone` then says the
  reason is unknown. Its terminals are
  recorded as asciicasts like every headless terminal (`--no-record` opts
  out); `agent_open` and `agent_list` report the absolute paths as
  `recordings` (a relaunch adds `<session>-r<N>.cast`). Isolated and
  durable modes only; `--shared` answers `unavailable`
  (`capabilities.agents`).
- **Launch.** The binary is resolved from the adapter's ordered
  `candidates` (`binary` overrides it: a name looked up the same way, or
  an absolute path). `unset_env` is applied in the child by a POSIX `sh`
  wrapper, because the child inherits the daemon's environment, not this
  server's. opencode's password is random per agent and reaches the
  server and the TUI through the spawn request's environment, never an
  argv; a durable instance keeps it in a 0600 file beside the agent's
  descriptor. `model` and `effort` are launch arguments where the adapter
  has `model_args`/`effort_args` (Claude Code: `--model`, `--effort`,
  session-scoped; an effort outside `effort_values` is refused up front);
  otherwise they are applied through the app once it is ready.
  opencode's server is only waited for until it answers one of its
  generations' probes (short probes, each on a fresh connection: a starting
  opencode listens seconds before it answers and never answers what it
  received in between); a server that never does is a `timeout` saying it
  did not become ready. One that EXITS first is a `failed` naming its exit
  status, the argv that ran and the lines it printed that are not its
  argument parser's usage text (`launch.startFailure`): opencode
  0.0.0-oc11 answers an option `serve` does not take with the usage text
  alone (measured), which the result then says instead of quoting its last
  line (`--cors additional domains ...`).
- **The per-user daemon starts clean.** Agents run on this host's
  per-user daemon, which the server autostarts when it is down, and every
  shell the user later opens there inherits that daemon's environment. So
  a per-user daemon this server autostarts gets the server's environment
  without `client.Conn.USER_DAEMON_SCRUB`: the assistant's variables
  (`CLAUDE*`, `AI_AGENT`) and the server's own (`SKETERM_MCP_*`,
  `SKETERM_MUX_IDLE_EXIT`, `SKETERM_MUX_LIFETIME_FD`); a private instance
  daemon keeps today's environment (`capabilities.user_daemon_env_scrubbed`).
- **Wrappers: `binary` + `args` + `env`.** A wrapper script (a container
  or profile launcher that passes unknown arguments on to the app) is run
  by naming it as `binary` and giving its own options as `args` and the
  variables it reads as `env`. `args` (at most 64, each 1-4096 bytes of
  UTF-8 without control characters) go right after the binary and before
  the adapter's arguments, on every process started with the binary:
  Claude Code's one process (relaunches included), opencode's `serve` and
  its attached TUI. `env` (at most 64; names `[A-Za-z_][A-Za-z0-9_]*`,
  values 0-4096 bytes, same rules) is set on those processes and spared
  by `unset_env`, so it reads as applied after it: `env:
  {"CLAUDE_CAPTURE_PROFILE":"work"}` survives Claude Code's `CLAUDE*`
  removal while every variable not named is still removed. Anything
  else is refused as `invalid_args`, never cleaned up; spaces, quotes,
  `$`, `;`, backticks and `*` arrive byte-exact (`launch.checkExtra` is
  the one rule, `launch.startArgv` the one argv). Locally and on a remote
  daemon the values ride the spawn request's environment; over plain
  `ssh -tt` the start script exports them, and that script's base64 is on
  the ssh command line, so `env` is NOT for secrets. Both are kept for an
  effort relaunch and in a durable instance's descriptor; `agent_open`
  reports `args` and `env_names` (never the values), and
  `capabilities.agent_open_args_env` says the server takes them.
  `server_args` and `tui_args` (same rules, `launch.checkExtra`) go after
  `args` on ONE of an app's two processes: opencode's `serve` and its
  attached TUI (`attach`), whose options differ; an app started as one
  process (Claude Code) refuses them as `invalid_args`. They are kept like
  `args` and reported as facts when given
  (`capabilities.agent_open_process_args`).
- **Resuming a conversation.** `agent_open resume: "<id>"` continues an
  EXISTING conversation of the app instead of starting one: Claude Code is
  launched with `--resume <id>` (and later relaunches keep resuming it),
  opencode's server adopts session `<id>` (`ses_...`) and its TUI, when
  it runs, attaches to it. The earlier turns are history, not new records. Ids are plain
  `[A-Za-z0-9_-]`, at most 128 characters (`capabilities.agent_open_resume`).
  Every per-agent result and `agent_list` report the conversation an agent
  runs as `conversation`, fresh or resumed (Claude Code's session id,
  opencode's `ses_...`), so an orchestrator that restarted can resume it
  (`capabilities.agent_conversation`). An id the app does not know fails
  the open (`not_found`, naming the id, the binary and where it looked)
  and nothing is left running, never a new conversation started under the
  old id's name (`capabilities.agent_resume_checked`): opencode's server
  is asked for the session (its generation's `session_get` route) once it
  is up, and a 404 stops it before
  anything is adopted; Claude Code started with `--resume <unknown id>`
  prints `No conversation found with session ID: <id>` and exits with
  status 1 (measured, 2.1.287 in `--ax-screen-reader` mode: no picker, no
  new conversation), which the adapter's `screen.resume_refused` rule
  reads.
- **Settings are confirmed, never assumed.** A recipe step `command` is
  the adapter's own command (`/model`): its turn is hidden from the
  transcript and the events, and the picker it opens is the recipe's to
  answer (no `needs_input`). A `confirm` step waits until no prompt shows
  and the app printed its confirmation below that command (Claude Code:
  `Set model to … this session only`); without it `agent_set` fails and
  says what the screen shows (a picker left open is cancelled). The
  transcript gets one adapter `notice` instead of `user: /model`.
  `agent_answer` likewise waits for the prompt it answered to go
  (`wait: answered`).
- **Effort is a relaunch for Claude Code.** Its `/effort` writes the
  user's `~/.claude/settings.json` even when it was launched with
  `--effort` or `CLAUDE_CODE_EFFORT_LEVEL` (measured, 2.1.286), so the
  `set_effort` recipe is `relaunch`: the app is ended (`launch.exit`,
  `/exit`), started again in the SAME session name with `resume_args`
  (`--resume <id>`: every agent is started with its own `--session-id`,
  so it never resumes another conversation in the same directory, the
  calling assistant's included) and every launch value as set now, and a
  model chosen in the app since is chosen again. The restart raises no
  event; the screen engine re-syncs as after a wipe and the transcript
  gets a notice. An agent put on a `term_open` terminal cannot be
  relaunched.
- **Waiting.** `agent_send`, `agent_answer`, `agent_open prompt` and
  `agent_wait` wait (bounded, default 60 s, at most 120 s) on the agent's
  event queue. Always-on wake-ups (`done`, `needs_input`, `error`,
  `exited`, `connection_lost`, `connection_restored`, and `stalled` for
  an agent opened with `stall_after_min`) end every wait, except an `error` whose
  class the agent recovers from by itself (`retrying`: "servers
  overloaded", a provider retry; `vocab.ErrorClass.wakesByDefault`),
  which wakes only a caller that passes `retrying:true` (waiter
  `--retrying`); the `retrying` STATE still shows in every result and
  `agent_list`, and a retry that turns into a real error or a limit wakes
  through that class. The quiet `done` of the background cap (below) is
  the other opt-in, `background:true` (waiter `--background`);
  `capabilities.agent_done.quiet_opt_ins` names both. `messages:true` and `match:"text"` add opt-in
  wake-ups, rate limited per agent (burst 3, then one per 30 s; the rest
  ride the next wake-up as a `digest`). `outcome` is the highest-ranked
  kind delivered (`vocab.EventKind.outcomeRank`), else `still_working`,
  or `sent` when the prompt went in and the call returned before the
  agent started on it (`agent_send timeout_ms:0`; `vocab.WaitOutcome`).
  `timed_out` is true only when a wait ran out; a call asked not to wait
  (`timeout_ms: 0`) reports false, and its outcome says what happened.
  `agent_open` with a `prompt` and `timeout_ms: 0` is the one-call
  hand-off (`capabilities.agent_open_handoff`): the start and the wait
  for the app to be ready stay bounded by the default (60 s), the prompt
  is submitted, and the call returns `sent` without waiting for the turn
  (it used to return at once and never send the prompt).
  An event that announces a message (`done`, `message`, `match`:
  `EventKind.announcesRecord`) carries its `record` id and a one-line
  preview (`events.PREVIEW_MAX`, 120 bytes) in results, never the text
  again (the waiter's line is unchanged). On
  `done`, `message` is the job's answer and `records`/`jobs`/`cut_ids`
  are the job exactly as `agent_read` selects it (below), minus what was
  handed out before, so no extra read is needed. `agent_wait agents:[...]`
  (or `agents: "*"`, every live agent of this server) waits on several agents: the first wake-up of any wins, the result is
  that agent's (`agents` lists the ones waited on) and its
  `watch_command` waits on all of them with `--any`. With `all: true`
  (`capabilities.agent_wait_all`) it waits until EVERY one of them has
  settled (`vocab.State.settled`: idle, waiting on the user, or exited;
  and the turn of the prompt last sent to it ended in a `done`,
  `needs_input`, a waking `error` or `exited`, so an agent that has not
  started on a prompt yet is not settled; one never sent anything that
  is idle counts at once, as `idle`), and answers `outcome: all_settled`
  (or `still_working` with `timed_out` when the wait ran out) with
  `results`, one per agent: `outcome` (the settling kind, else its
  state), `text` (a done's one-line preview), `record` (its answer:
  `agent_read final` returns it whole), `settled`, `events`. What it
  reports is delivered like a waiter's line, and it marks no record. Its
  `watch_command` is `agent-wait --all`.
- **Delivery is confirmed (`capabilities.agent_delivery`).** `sent` and
  `queued` mean the app TOOK the prompt, never only that it was typed: a
  wedged Claude Code once showed `idle` while three `agent_send` calls
  answered `sent` and nothing arrived. After typing, a screen app must
  show it took the prompt within 10 s (`DELIVERY_CONFIRM_MS`): a turn
  starting (its OSC 133 prompt mark, or a state that leaves the
  prompt-taking ones: working, waiting on the user), a user record, or
  for a queued prompt its queue preview (`agent_mod.Uptake`). Otherwise
  the call fails with error code `not_delivered` (details `agent`,
  `state`, `waited_ms`; the message carries the screen) and the prompt is
  NOT typed again, since an app that wakes up late would then run it
  twice: look at the agent before resending. This holds for every send
  path: `agent_send` (one agent, `agents` where it is that agent's
  `failed` line, `timeout_ms: 0`, a queued send), `agent_open`'s prompt
  (an error naming the agent, which stays open) and a
  `retry_on_overload` continue (a notice). opencode's prompt is an HTTP
  call whose 2xx is the server's own acceptance; any other answer already
  fails the send. A busy server takes a prompt and answers too late, so
  every prompt carries a client message id in opencode's own ascending
  form (`msg_` + 48-bit time stamp + random; 1.x `messageID`, 2.x `id`,
  both checked only for the prefix, measured); when the answer never
  comes in time (or the connection drops) the id is looked up for at
  most 10 s more (`opencode.DELIVERY_LOOKUP_MS`; `routes.message_get`,
  and 2.x's `routes.inbox` for a prompt queued behind a turn) while the
  request stays open: 2.x drops a request whose client goes away before
  it answers (measured), so a timed-out POST is never closed while it
  may still land. Found, or its 2xx arriving late: the send succeeds
  with `delivery_confirmed_late: true`. The HTTP layer never resends a
  request whose duplicate has effects (`http.Request.retryable`: GETs
  and requests declared `idempotent` only, else only when provably none
  of it was written), so a prompt a stale kept-alive connection lost is
  settled by the same lookup. Not found: `not_delivered`, never sent again
  (`capabilities.agent_delivery.api_unanswered: "message_lookup"`). A
  prompt an interrupt made the app drop is sent again under its first
  id, and not at all when the session still holds it. Measured: 2.x answers a repeated id
  with the item it holds; 1.x appends the text to that message as
  another part, so the id alone does not make a 1.x re-send harmless.
- **One prompt to several agents, and interrupting first
  (`capabilities.agent_send_many`, `agent_send_interrupt`).** `agent_send
  interrupt: true` interrupts a busy agent (working, or waiting on the
  user) FIRST and then sends the text as a NEW prompt: never queued
  behind the running turn, never dropped (an agent that does not take
  prompts within 10 s of the interrupt is a `timeout` failure that sent
  nothing); on an idle agent it just sends; the result says
  `interrupted` and, when Claude Code's Escape discarded prompts it held
  queued, `queued_dropped`. The prompts THIS server had queued there
  (`Entry.queued_sent`, forgotten as the app takes them) are queued again
  right after the urgent one went in, in their original order, and listed
  as `requeued` (`text`, or for a rendered template only its `template`);
  a failure stops it and is `requeue_failed` (`code`, `message`,
  `not_requeued`). Nothing the app held from elsewhere is ever typed
  (`capabilities.agent_send_requeue`). `agents: [...]` (instead of `agent`, at most
  32 ids or names, or a selector string, see Selectors: `agents: "*"` is
  every live agent of this server, `capabilities.agent_agents_every`;
  one matching none, more than 32 or a string that is no selector is an
  error) sends the same text to each in one call: with
  `interrupt` every busy one is interrupted at once, then each gets the
  prompt; the call does not wait for the turns and answers with
  `results`, one per agent named (`outcome` sent, queued, still_working
  or failed with its `error`; `interrupted`, `queued_dropped`, the
  `events` no result had handed out), `failed` and a `watch_command`
  that is `agent-wait --all` on the agents sent to. A failed agent (an
  unknown name, a refusal) never stops the others.
- **Messaging a busy agent (`capabilities.agent_send_queue`).**
  `agent_send` to an agent that works (`working`, `waiting_subagent`,
  `retrying`: `vocab.State.queuesPrompt`) puts the prompt in the app's
  OWN queue for its next turn instead of refusing it, so "Docker is
  fixed" reaches a worker without interrupting its turn; the result
  carries `queued: true`, and `outcome: "queued"` when the call returned
  before the app took it. Both apps queue natively (measured): Claude Code
  2.1.287 takes typed input while it works, draws it as a `you:` preview
  with `ctrl+enter to send now` under it above the status block, and at the
  turn's end prints it as an ordinary prompt below the footer and starts a
  turn for it (the adapter's `actions.queue` recipe types it without the
  Escapes that would interrupt, and `screen.queued` marks the preview
  live, never a record; an idle app still showing one is not done; an
  `agent_interrupt` throws Claude Code's queue away with the turn, and its
  result says how many prompts went as `queued_dropped`; the ones THIS
  server had queued are typed again once it stopped, in their order, and
  listed as `requeued` / `requeue_failed` exactly as for `agent_send
  interrupt`, `capabilities.agent_interrupt_requeue`);
  opencode 1.x (oc11) answers `prompt_async` on a busy session with 204,
  creates the user message at once and runs it after the current answer
  (its records keep the job of the prompt they answer, by `parentID`). A
  queued prompt is a user prompt like any other: it starts a new job when
  the app takes it. The turn it waited behind never settles on its own,
  so it raises no `done`; the queued job's `done` covers every job since
  the previous waking done (`Event.first_job`, `select.Waker`), and its
  result's `records`/`jobs` include the earlier job's final message, so
  nothing is lost and the caller is woken once. The wait is for the queued
  job (same `timeout_ms` and wake rules; a `needs_input` meanwhile still
  wakes). Refused: an agent waiting for an answer (`conflict`: typed keys
  would answer its prompt), a Claude Code whose input box holds text a
  human is typing (`conflict`: it would merge), an adapter without a
  `queue` recipe (`conflict`, as before), and a typed prompt the app did
  not take out of its input box within 10 s (`timeout`, with the screen).
- **Side questions (`agent_ask`, `capabilities.agent_side_question`).**
  `agent_ask {agent, text}` asks "how far are you?" of a busy or idle agent
  and returns `{answer}` in the result: no job, no queue slot, no record,
  no event (none raised, none taken: pending events stay for the next
  result or waiter, and the waiter's remembered filter is untouched), no
  `watch_command`, and the state is never changed by it (a busy agent stays
  `working`). Claude Code's `/btw` is that question (measured, 2.1.288 in ax
  mode): it opens a panel below the transcript, `/btw <question>` and the
  answer above a footer ending `Esc to close` (`↑/↓ to scroll · c to copy ·
  f to fork · Esc to close` busy, `⇧←/→ to browse · … · x to clear history ·
  Esc to close` idle, a bare `Esc to close` under `Answering…` while
  pending), and Escape closes only the panel: a running turn goes on and
  ends with its own `done`, and nothing of the question reaches either
  transcript JSONL. Idle, it first prints `you: /btw <question>` exactly
  like a prompt line and the panel then REPLACES the status block and input
  box, listing earlier questions above the new one. All of it is declared,
  never coded: `screen.side_question` (`question`, `footer`, `pending`,
  `echo`, `settle_ms`) and `actions.side_question` (type `/btw {text}`,
  Enter as a separate write, `wait: side_asked`, `wait: side_answer`,
  `close_side: [escape]`), which go together. The engine marks the panel's
  rows live (`grammar.findSidePanel`: the footer is the last line that is
  not live, the questions above it), so they never become records or
  errors, the echo is chrome before any record rule (`classify`), the
  footer is chrome so the panel is never counted as status rows, a turn
  that ends while the panel is open is captured only once it closed, and
  with the panel drawn last a `$` in an answer is no input box. The answer
  is the rows after the LAST question line spelling the typed line (by
  alphanumerics, so a wrapped question matches) up to the footer, read once
  it is drawn, not `pending`, and unchanged for `settle_ms`
  (`waitSideAnswer`; the whole call's `timeout_ms` bounds it). Delivery
  needs the app's evidence like a prompt's: the panel naming the question
  within 10 s, else `not_delivered`, never typed again. `close_side` keys
  are sent only while the panel's footer shows (Escape anywhere else
  interrupts the turn and drops Claude's queue), and a recipe that fails
  with its panel open closes it the same way; `panel_closed: false` says it
  still shows. Refused: an adapter without the action (opencode,
  `invalid_args`), `agents`, a multi-line question or one over the app's
  paste threshold (`invalid_args`), an agent waiting for an answer or
  starting (`conflict`), a non-empty input box, and a panel already open
  (`conflict`); while a panel shows, every send path refuses too
  (`submitPrompt`: the panel has the keyboard).
- **Free-text answers (`capabilities.agent_answer_text`).** `agent_answer
  text:"..."` (instead of `choice`) answers a prompt in words when
  `interaction.free_text` says it takes them; otherwise it is refused as
  `invalid_args` naming the options, never answered with a guessed one.
  Claude Code: the adapter's `screen.text_options` rules name the option a
  text goes through (its permission's `No`, measured 2.1.287: in ax mode
  the dialog offers `1. Yes / 2. Yes, and always… / 3. No`, and `No` ends
  the turn with `Interrupted · What should Claude do instead?`), and the
  `answer_text` recipe picks it, waits for the app to be idle and types the
  text as the next prompt, which is a new job; the refused job's `done`
  rides along in the result, the wait is for the text's turn. opencode:
  a permission is rejected with the text as `message` (the model gets "The
  user rejected permission ... with the following feedback: <text>" in
  the same turn), a question takes it as a custom answer (one line per
  question when it asks several; a question with `custom: false` has no
  free-text route). Claude Code's AskUserQuestion dialog was not available
  to measure (the tool is not offered in this setup), so no text rule
  exists for its questions yet.
- **Wall-clock times.** Every record and event in a result (and
  `agent_read`) carries `at`: ISO-8601 LOCAL time with its UTC offset, to
  the second (`2026-10-04T11:32:50+02:00`), one format everywhere
  (`clock.isoLocal`). An event's is when it first happened; a record's is
  the app's own time where it gives one (opencode's part `time.start`),
  else when sketerm first read it (a screen app's record; one re-captured
  unchanged keeps its time). `agent_list detail` adds `last_activity_at`
  beside `last_activity_ms`; compact `agent_list` adds `active_at` (local
  `HH:MM`), and its line says `idle 40s (since 11:32)`. The waiter's
  printed line (and the pushed text, a channel's `meta.at`) puts the
  deciding event's `HH:MM` after its kind: `claude-k3f9 done at 11:32:
  ...`; the wire events carry the full `at`. `agent_read`'s text lane
  writes `[id HH:MM] kind: text`.
- **Answers that do not fit.** A `choice` that names no option is
  `invalid_args` listing the options and the accepted forms (label,
  1-based number, unique part of a label; `text` too when the prompt takes
  free text). An opencode question request that asks several questions
  takes ONE LINE PER QUESTION in `choice` (each a label/number, a
  comma-separated list where several may be chosen, or free text where
  allowed); a refusal says how many questions there are and how many lines
  came, then lists each question with its options and what it accepts,
  one per line. `agent_send` to an agent with a pending prompt is
  `conflict`, nothing sent, and its message names `agent_answer` (choice,
  or text where taken) and shows the prompt briefly.
- **`done` means settled.** An agent is done when it is idle with no
  subagents and no background tasks running. Claude Code shows the shells
  and monitors it started in the background on its mode line (`manual
  mode on  ·  2 shells, 1 monitor`, `·  1 monitor`; measured 2.1.287 with
  Haiku at 120 and at 48 columns, where the line still fits one row) and
  each background subagent as a `◯` row under `● main` below it (wrapped
  onto a second row on a narrow terminal), and drops them in the same
  frame in which it starts the turn that reports their end. The adapter's
  `screen.background` rule reads the mode line wherever on it the count
  sits (`· N shell`, `· N monitor`: a session another client resized
  wraps it on a narrow terminal or carries more after it on a wide one;
  every transport spawns at the `cols` asked for, 120 by default; its
  numbers summed are the count) and `screen.background_agent` counts the rows; the turn's
  footer (`· 2 shells still running`) is never read as the live count,
  since it keeps saying so after they ended. The state is
  `waiting_background` (the agent still takes prompts) and the `done`
  waits for the wake turn: the done that fired while a shell and a monitor
  still ran (`· 1 shell, 1 monitor`, which the old shells-only rule missed)
  no longer does. The segment's
  final is flagged when the agent goes idle, so the job's summary is
  still selected. An agent idle with background tasks for 30 minutes
  (`select.BACKGROUND_DONE_CAP_MS`) raises a QUIET `done` with
  `background_tasks` (their count) on the event: like a `retrying` error
  it reaches only a caller that opts in (`background: true` on the
  waiting calls, waiter `--background`; `events.Quiet`), it settles no
  turn (`agent_wait all` and `--all` keep waiting), and it leaves the
  job's first wake to the `done` that settles the turn once the tasks end
  (`select.Waker.peek`), so a long build no longer wakes the orchestrator
  with "the build is running in the background"
  (`capabilities.agent_done.background_cap_quiet`). The state stays
  `waiting_background` meanwhile. opencode has no background shells; its
  background subagents are child sessions, whose busy status already
  holds the root as `waiting_subagent`.
- **Compaction is a notice, never a message.** A compaction summary is
  never part of any result, `detail:"all"` and event text included, and
  compaction never counts as a new answer for the re-wake rule. opencode
  marks it in its API: the request is a root user message whose only
  part is `compaction` (it opens no job and arms no `done` of its own),
  the summary is an assistant message with `summary: true` (its parts are
  dropped), and `session.compacted` adds the notice `conversation
  compacted`. Claude Code never draws the summary (measured, 2.1.286:
  `/compact` erases the turn below the first prompt, reprints it shorter
  with `Conversation compacted (ctrl+o for history)`, and the command's
  own turn shows `Compacted (ctrl+o to see full summary)`, a notice); a
  `/compact` sent with `agent_send` is a job of its own whose one `done`
  carries an empty answer.
- **Jobs, and what is read back (`src/agent/select.zig`).** The unit is
  the JOB: one user prompt (whoever typed it: `agent_send`, `agent_open`'s
  prompt, a human in the GUI) and everything until the next one,
  including turns the agent starts on its own (a background task or a
  watcher waking it). Claude Code draws such a turn with no `you:` line
  (measured, 2.1.286: OSC 133 marks, a turn-end bell, a ` Background
  command "..." completed` line, which the adapter records as a notice, then
  the answer below the previous footer), so it extends the job. A
  SEGMENT ends each time the agent goes idle; the job's last assistant
  message then is that segment's final. By default a job returns its last
  message in full, every earlier segment final of 300+ characters, any
  message of 1500+ characters (a summary written before a trailing tool
  call) and every notice, chronologically; the rest is counted per job
  (`jobs[].omitted_messages`/`omitted_tools`, a `(14 more messages, 23
  tool calls)` line in the text lane). User prompts are never returned
  (the caller sent them); tool records only with `include_tools`. The
  thresholds come from 489 real Claude Code sessions (intermediates:
  median 137 chars; prompt-answer finals: median 2016; wake-segment
  finals: median 351; in 162 of 860 multi-segment jobs the last final was
  under 300 after an earlier final of 300+). **Delivery is per record**
  (`select.Handed`, one per agent): the default `agent_read` applies the
  selection to every job and returns only records no result handed out
  before, whichever result that was (a read, or a `done` result of
  `agent_open`/`agent_send`/`agent_wait`/`agent_answer`, which mark what
  they return). A done result's block is headed by exactly the jobs it
  holds (`job 3`, `jobs 2-4`, `jobs 2, 4`), never a range with nothing new
  in it. A selected record handed out earlier is never repeated;
  its job carries one pointer instead (`jobs[].returned_before`,
  `jobs[].earlier` and a line like `earlier in job 3: [12] assistant,
  3.1k chars, returned before`), and a read with nothing new says so in
  one line and returns no records. At most ~12000 characters per read:
  the newest job's last message whole, then the longest that fit; what
  the cap leaves out is listed in `cut_ids` and comes with the next read.
  A record handed out is never handed out again under another id with
  the same text, whitespace runs counting as one space (Claude Code
  re-wraps a message it reprints at another width).
  A record keeps its id and its job however often the app draws it again:
  Claude Code reprints older turns below the transcript without erasing
  (their old copies may be trimmed from the parse by then), places a
  prompt it took mid-turn at different points of different renderings,
  and a redraw of a live region taller than the screen leaves the part
  that scrolled into history behind and prints it again below. A reprinted
  turn is matched by prompt and content against what was captured of
  every earlier turn (a copy, most of the same records, or the same
  three substantial records first) and folded into it
  (`Engine.turnReprintedBy`), a run
  of three or more records an earlier job holds is left in that job
  (`Engine.knownRuns`), and a redraw's stale copy inside a turn is dropped
  (`grammar.dropStaleCopies`); a same-prompt turn whose answer differs is
  still a new job. Measured on a resumed agent's 3-hour cast: 36 jobs and
  860 texts under two or more ids before, 12 jobs for its 12 prompts and
  none after.
  `jobs` and `cut_ids` only cover jobs this read returns a record of (old
  history contributes at most its one pointer line); a job whose new
  records the cap kept out entirely is only counted, in `jobs_pending`.
  An explicit `since` re-reads the jobs with records above it, handed out
  or not; `detail: "all"` returns every assistant message and notice
  above `since` (or above what the previous detail-all read covered) by
  id, paged by `limit` with `next_since`/`more`. `final: true`
  (`capabilities.agent_read_final`) returns only the newest job's last
  assistant message, whole, under the same delivery rule: once, then a
  read names the job with a `jobs[].earlier` pointer at it; with `since`
  the newest job above it, handed out or not; refused with `detail:
  "all"`. It replaces reading an app's own transcript files (opencode's
  database, Claude Code's jsonl) for "what did it finally say".
  `detail: "activity"` (`capabilities.agent_read_activity`) is a glance at
  what the agent is doing, a few hundred bytes: `state`, `idle_s` and
  `last_activity_at` (since the app last drew or sent anything), and
  `tools`, the newest `limit` (default 10, at most 50) tool calls oldest
  first as `name` + local `at` (`HH:MM:SS`), never their inputs or
  outputs; `records`/`jobs`/`events` are empty, it takes no event and
  hands no record out, and it refuses `since`, `final` and
  `include_tools`. Record ids restart when
  a durable instance reattaches (the app's transcript is read again), so
  the handed-out state is not persisted: the first read after a reattach
  returns the selection again. The answer a `done` carries is the job's latest
  selected message of 300+ characters, else its last message. A job's
  FIRST `done` always wakes; a later one (a wake segment) wakes only when
  the job gained a message the rules select besides its last one, so a
  trivial "that was another wakeup, ignoring" goes idle without waking
  anyone (`agent_read` still shows it). `capabilities.agent_read_select`
  reports the unit and the thresholds; `agent_records_once`,
  `agent_events_shared`, `agent_wait_any` and `agent_done` (settled,
  `background_cap_ms`, `quiet_errors`) report the rest of this.
- **Being woken.** Every per-agent result carries `watch_command`, the
  exact command (this executable, absolute) that blocks until the agent
  next needs attention: `sketerm mcp agent-wait --socket <instance>/agents.sock
  [--match X] [--messages] [--retrying] [--background] <agent>`, or `--any <agent>
  <agent>...` for several (the first wake-up of any; with `--follow`, all
  of them), or `--all <agent> <agent>...` (one wake-up once every one of
  them settled, as `agent_wait all` decides it: a header line `all N
  agent(s) settled`, then one line per agent with its outcome, its text
  and its answer record; no filter, no `--follow`; a server that predates
  `--all` reads it as `--any`, and the line says so), or `--server` for
  every agent of the server, later ones
  included, printed as the pushed text below (`--parent PID` finds the
  server PID started instead of `--socket`; `--json` prints the server's
  lines verbatim). Events have ONE delivery state per agent (`Event.delivered`),
  shared by every `agent_*` result, `agent_wait` and every waiter: an
  event any of them delivered is delivered for all, because a waiter's
  line lands in the same assistant's context. So the same command can be
  run again any number of calls later and never re-wakes on an event
  already delivered; two waiters on one agent wake once between them;
  and a tool call on an agent holds that agent's waiters while it runs,
  so its own result gets what happens meanwhile. `--since SEQ` re-reads
  every event after SEQ, delivered or not. A waiter prints each wake-up
  as exactly the text a push delivers (below; `capabilities.agent_waiter_content`):
  one line (`claude-1 done: <first line> [state idle]`), then what the
  line cuts short: a `done`'s answer or a `message` in full when under
  2000 characters (that record is then handed out, so `agent_read` points
  at it instead of repeating it; a longer one gets a pointer to
  `agent_read`), a prompt's options, an error's whole text and detail.
  So a wake-up needs no extra read to act on. The CLI asks for that text
  in its subscribe line (`content`); a CLI that predates it gets the bare
  line and no record is marked. A text the line shortens is cut between
  words and marked ` ...`, never inside a value its own brackets would
  make read as a field. It exits after the first wake-up unless `--follow`, and always
  prints `watch ended: <reason>` when its agents close or the server goes
  away. `sketerm-mcp agent-wait` and `sketerm-mcp mcp agent-wait` are the
  same command; the subscribe line keeps `agent` (the first) beside
  `agents`, so an older server watches the first one.
- **At a glance: `sketerm mcp agents` (`capabilities.agent_attention`).**
  Every server publishes, per agent in its registry record
  (`$XDG_RUNTIME_DIR/sketerm/mcp-servers/<pid>.json`), its `state` and its
  `attention`, the one classification a person needs: `needs_input`
  (waiting_user), `lost` (disconnected, or exited until closed),
  `working` (starting, working, waiting_subagent, waiting_background,
  retrying) and `idle`, in that order of urgency (`vocab.Attention`). The
  record is rewritten when an agent's state moves (at most once per loop
  pass), and also carries the pane session the server was started from
  (`session`, `session_socket`, from `SKETERM_SESSION` /
  `SKETERM_MUX_SOCKET`; absent when unset). `sketerm mcp agents` (also
  `sketerm-mcp agents`) reads those files, nothing else (no socket, no
  daemon), and summarizes the agents of every live server that one of
  its own ANCESTOR processes started, so a Claude Code status line
  (claude -> sh -> node -> sketerm) sees exactly that Claude Code's
  agents, wherever they run; `--parent PID` matches only servers PID
  started. Formats:
  - `--format line` (the default): `agents 2 working · 1 needs input ·
    1 disconnected · 1 idle` in ANSI colour (`--no-color` for none),
    groups with no agents left out, `N unknown` for agents of an older
    server, and NOTHING at all (exit 0) when there are no agents.
    `--hosts` appends `(dalaran 2, local 1)`.
  - `--format compact`: `ag 2▶ 1? 1✗ 1✓` (`~` for unknown); the default
    turns into it when `$COLUMNS` is set and below 100.
  - `--format json`, a CONTRACT for scripts, one line:
    `{"total":N,"by_attention":{"needs_input":n,"lost":n,"working":n,"idle":n},
    "most_urgent":"needs_input"|"lost"|"working"|"idle"|null,
    "agents":[{"id","app","host","attention","state"}]}`. `host` is the
    SSH destination the agent runs on, null for this machine. An agent
    from a server that predates publishing attention counts in `total`
    with `attention` and `state` null (and in no `by_attention` group);
    a server that predates publishing its agents at all contributes
    none. No agents: `{"total":0,...,"most_urgent":null,"agents":[]}`.

  It exits 0 whatever it finds (an unreadable registry reads as no
  agents) and 2 only on bad usage. A status line runs it on every
  refresh, e.g. `execFileSync('sketerm', ['mcp', 'agents', '--format',
  'json'], {timeout: 500})`, and treats any failure as no segment.
- **Pushed events (`capabilities.agent_push`, `agent_push_follow`,
  `agent_push_followers`).** Instead of a waiter the orchestrator
  re-arms (a Monitor stops after 30 minutes, a background command after
  one wake-up), the wake-ups can be pushed INTO its session, where each
  starts a new turn. The event rules are unchanged (always-on kinds,
  the opt-in kinds of the last result's `watch_command`, the flood
  limiter, the hold during a call on the agent), and a push goes through
  the agent's ONE delivery state like a waiter: what it delivered no
  result, `agent_wait` or waiter hands out again, and the first of them
  to take an event delivers it. A pushed wake-up is the waiter's text
  above, composed once for every route (`agentpush.compose`; a record it
  carries in full is handed out, whichever route carried it). Results of a call that
  returned before its agent finished say the events are pushed instead
  of asking for a waiter, and the server instructions tell the
  orchestrator to end its turn and rely on them.
  - **Claude Code (channels, research preview).** The server declares
    the experimental capability `claude/channel` and sends
    `notifications/claude/channel` with `{content, meta}`; Claude Code
    wraps the content as `<channel source="sketerm" agent=... kind=...
    state=... seq=... record=... job=... conversation=...>` (every meta
    value a string) and queues it as the session's next prompt. It
    delivers them only in a session started with the channel, which for
    a server outside the approved plugin allowlist is
    `claude --dangerously-load-development-channels server:sketerm`
    (a confirmation dialog at startup; `--channels server:sketerm` only
    for allowlisted ones), where `sketerm` is the server's name in the
    session's MCP config (`sketerm mcp --channel-name NAME` when it is
    another), on a first-party login (not Bedrock, Vertex or Foundry),
    with channels enabled for the org (Team/Enterprise: managed setting
    `channelsEnabled: true`). Claude Code tells a server nothing about
    any of this (read from 2.1.287's bundled client: its client
    capabilities are empty and an unregistered notification is dropped), and a push marks its
    events delivered, so the server pushes only when the client is
    Claude Code (`clientInfo.name` `claude-code`) and its parent, or an
    ancestor up to 8 levels, has that option naming this server's
    channel on its argv (Linux; elsewhere `agent_push` stays `none`),
    and only from the session's first tool call on (Claude Code
    registers its listener after the handshake). A session whose channel
    Claude Code nevertheless refused (feature gate, org policy, a declined
    dialog) loses the pushed events: `agent_read` still returns the
    records.
  - **opencode (a plugin).** `data/opencode/sketerm-agents.js`, installed
    as `/usr/share/sketerm/opencode/sketerm-agents.js`; enable it with
    `mkdir -p ~/.config/opencode/plugin && ln -s /usr/share/sketerm/opencode/sketerm-agents.js ~/.config/opencode/plugin/`
    (or a project's `.opencode/plugin/`).
    On the first `agent_*` tool call of a session (its
    `tool.execute.before` hook) it starts `<sketerm> mcp agent-wait
    --server --follow --json --parent <its pid>`, which finds the server
    that opencode process started through the MCP registry (each record
    publishes `ppid` and `agent_socket`) and follows every agent of it,
    those opened later included; each wake-up is injected with
    `session.promptAsync` into the session that last called an `agent_*`
    tool, as `<sketerm-agent-event agent=... kind=...>` around the same
    content, which starts a turn there (or queues behind the running
    one). The sketerm binary is the `command` of the opencode MCP entry
    whose executable is `sketerm` or `sketerm-mcp` (plugin option
    `binary` overrides it). Without such an entry or server it does
    nothing; a follower that ended is started again by the next call.
- **Observation.** The server loop polls stdin together with every agent
  terminal, API stream and waiter connection, and wakes for the sources'
  timers, so agents are observed between requests. Turn detection is
  content-based (OSC 133 marks, the footer line, API events): a turn that
  ended while another tool call blocked the loop reads the same when it is
  observed afterwards.
- **On an SSH host (`host`, `capabilities.agent_ssh`).** One probe over
  ssh (key or agent auth) resolves the binary ON THE HOST from the
  adapter's candidates (`command -v` for `$PATH`, `$HOME` for `~/`; an
  ssh login's PATH lacks `~/.local/bin`, which is why the candidates
  exist), checks `cwd` there (default: the remote home) and is how
  `agent_adapters host` reports what is installed. The sessions use
  `term_open`'s transports (`transport` auto|mux|ssh): the host's own
  sketerm-mux daemon when it answers (sessions survive drops; not
  recorded, the cast would land on the host), else plain `ssh -tt` in a
  local session (dialect-proof base64 script, terminal on stdin; the
  remote process ends with the connection). Results report `host` and
  `transport`. opencode's server listens on the HOST's loopback (a random
  remote port, `{port}` in `attach_args`) and the API client reaches it
  through an ssh `-L` forward from a local port, one per agent, respawned
  whenever it dies. A remote start reads opencode's password off its own
  terminal with echo off after printing `[sketerm] agent secret:` and
  exports it, so it rides neither an argv (local or remote) nor the
  spawn request, and nothing records it.
- **The login environment (`login_shell`, `path_prepend`,
  `capabilities.agent_login_shell`).** A non-login ssh command gets
  sshd's bare PATH (measured: `/usr/local/sbin:/usr/local/bin:/usr/bin`,
  no `~/.local/bin`, nothing `/etc/profile.d` adds), which once picked an
  ancient `/usr/bin/claude` and hid the user's own tools. By default the
  probe AND the start run under the remote user's login shell: `$SHELL -l
  -c 'exec /bin/sh -c "$SKETERM_LOGIN_SCRIPT"'`, a command bash, zsh,
  fish, sh/dash and ksh parse alike, which re-enters POSIX sh with the
  profiles applied (csh/tcsh refuse `-l -c` and get `/bin/sh -l`). The
  probe runs it bounded (`launch.LOGIN_PROBE_SECS`, 10 s; a profile that
  execs another shell or waits forever costs that much), reads markers
  only (a profile's noise is ignored; the end marker must be a whole
  line), and falls back to the plain environment when the login run did
  not finish (`login_shell: false` in the result). `path_prepend`
  (absolute directories, refused like `env` values plus no `:`) goes in
  front of PATH after the login environment and before the lookup.
  A plain-ssh start exports `env` after the login shell; a start on the
  host's daemon (whose child would otherwise inherit the DAEMON's
  environment) carries `env` values under `SKETERM_AGENT_ENV_<name>` in
  the spawn request and restores them after the login shell, so no
  profile overrides them and no value goes on an argv. `login_shell:
  false` keeps the plain environment; locally both are ignored and
  `path_prepend` still applies to the lookup. The result reports
  `binary`, `binary_version` (the first line of the adapter's
  `version_args`, `--version` for both shipped adapters, so a stale
  binary is visible), `login_shell` and `login_shell_path`. Both are
  kept for relaunches and durable reattaches.
- **SSH logins and sketerm's ControlMaster (`fresh_login`).** Every
  ssh/scp leg sketerm runs takes its options from ONE home,
  `sshroute.Args.options` (ForwardX11=no everywhere, BatchMode,
  keepalives, forwardings, multiplexing, the Tor block), with each
  caller's differences named as a `sshroute.Leg`. The legs that
  multiplex share sketerm's own ControlMaster
  (`~/.ssh/sketerm-%C`, `ControlPersist=120`), and a master keeps the
  credentials of the login that made it, its group list included, for
  as long as any session uses it. So before a NEW connection rides it,
  sketerm stops a master older than `mux_ssh_master_max_age_secs`
  (default 3600; `ssh -O stop`: the sessions it carries keep running,
  the new connection logs in afresh), and `fresh_login: true` on
  `agent_open`/`term_open` does so whatever its age. The age is the
  control socket's mtime (`/proc` start times lie inside LXC containers,
  where lxcfs virtualizes uptime). `agent_open`, `term_open` and
  `port_forward_open` report `ssh_master` (`sketerm`, `user_config`,
  `none`, `unknown`), `ssh_master_reused`, `ssh_master_age_s`,
  `ssh_master_stopped` and `ssh_control_path`. A ControlPath your
  `ssh_config` sets (seen with `ssh -G`) is reported as `user_config`
  and never stopped; port forwards never multiplex (a forward in a
  master would outlive its ssh and keep the port bound). The remote
  sketerm-mux daemon is a separate long-lived process: an agent it
  spawns inherits the DAEMON's groups, which a fresh ssh login does not
  change.
- **Connection loss.** A remote-mux session whose link drops is
  reattached once at once; when that fails the agent reports
  `connection_lost` (state `disconnected`) and a background thread retries
  (2 s, doubling to 60 s, for as long as the host does not answer; an
  `agent_*` call on it retries at once without waiting); a recovered link
  re-syncs like a wipe (nothing is captured twice) and raises the always-on
  `connection_restored`, so a waiter learns it is back. A plain-ssh agent
  whose ssh lost the connection (status 255) reports `connection_lost` and
  `exited`.
- **Disconnected or gone (`capabilities.agent_gone_on_reconnect`).** A
  retry that REACHES the host's daemon and is refused the attach (no such
  session for that lifetime: it was closed or expired meanwhile, or the
  host rebooted and its daemon is a fresh one) ends the agent instead of
  retrying forever: the daemon's tombstone is asked why (the same rule as
  `agent_attach`, `askWhyGone`; a fresh daemon has no record, so
  `unknown`), the terminal is marked gone (no further retry), and the
  agent raises ONE always-on `exited` whose text names the host, the
  reason and what it means. From then on every per-agent result and
  `agent_list` (compact and detail) carry `gone_reason` (`closed`,
  `expired`, `exited`, `unknown`) and, as for any agent whose app ended,
  `relaunchable` exactly as `agent_attach` answers it, so `agent_attach
  {agent, relaunch: true}` starts it again under its id. A host that does
  not answer (ssh fails, or the daemon does not answer the attach in time)
  is still only `disconnected`, retried with the backoff above.
- **A permission policy (`permissions`, `capabilities.agent_permissions`).**
  `agent_open permissions: {"<name>": "allow"|"ask"|"deny", ...}` is
  app-neutral; each adapter maps it declaratively
  (`launch.permissions`: the `names` it takes plus `patterns`, the JSON
  `shape`, the object `path`, and exactly one of `env` or `arg`), and
  `launch.applySettings` is the one mapping, applied at every start
  (relaunches and reattaches included; the policy is kept in the
  descriptor). opencode (`by_name` under `permission`, env
  `OPENCODE_CONFIG_CONTENT`; its config schema's keys `*`, `read`, `edit`,
  `glob`, `grep`, `list`, `bash`, `task`, `external_directory`,
  `todowrite`, `question`, `webfetch`, `websearch`, `lsp`, `doom_loop`,
  `skill`): the policy is merged into an `OPENCODE_CONFIG_CONTENT` the
  caller passes in `env` (its other keys kept; a name in both takes the
  policy's action), so `{"external_directory": "allow"}` ends the
  `/tmp/*` prompts. Claude Code (`by_action` under `permissions`, option
  `--settings`, which 2.1.287 takes as a JSON string of additional
  settings whose `permissions.allow/ask/deny` are rule lists; read from
  its `--help` and bundled settings schema): the known tool names plus any
  rule `Tool(specifier)` (`Bash(git *)`) or `mcp__...` name. Refused as
  `invalid_args`, naming what that app takes (`agent_adapters` lists it
  per adapter as `permissions`): an unknown name or action, a name given
  twice, an app whose adapter declares no mapping, `args` that already
  pass the app's `--settings` (never overwritten), and an
  `OPENCODE_CONFIG_CONTENT` that is not a JSON object. `agent_open` and
  `agent_list detail` report the policy as `permissions` (names and
  actions; nothing secret).
- **Facts: context use, rate limits, cost (`facts`,
  `capabilities.agent_facts`).** Every per-agent result and `agent_list`
  (compact and detail) carry `facts`: what the agent's app reports about
  itself, only known values (a null or absent value is unknown and left
  out, never 0); `agent_list`'s one-line form adds `context 14%, 7d limit
  98%` when known, and `detail` adds `facts_unknown`, why none is known
  yet. The names live in ONE file, `data/agents/facts.json` (type
  `int`/`percent`/`tokens`/`usd`/`unix_time`, a one-line meaning, an
  optional `derive: {ratio: [a, b]}` = `100 * a / b` used when no path
  gives the fact, an optional `compact` label for the one-line form):
  `context_used_percent`, `context_window_tokens`, `context_used_tokens`,
  `rate_5h_used_percent`, `rate_5h_resets_at`, `rate_7d_used_percent`,
  `rate_7d_resets_at`, `cost_usd`. An adapter's `facts.map` maps names
  to dotted JSON paths into its source's document (a list of paths is
  summed); a name facts.json does not declare fails the adapter's load.
  `capabilities.agent_facts` gives the vocabulary and, per adapter, the
  names it can give (derived ones included). Adding a fact is a line in
  facts.json and a mapping in an adapter, no code
  (`src/agent/facts.zig`). Claude Code's source is its status line:
  2.1.288 in `--ax-screen-reader` mode runs the `statusLine` command
  from `--settings` at startup and after each turn with a JSON document
  on stdin (`context_window`, `rate_limits` after the first answer,
  `cost`, ...; measured). The adapter's `facts.status_command` puts
  sketerm's command (`src/agent/statusline.zig` `COMMAND`, plain POSIX
  sh) into the ONE `--settings` document the permissions use; it saves
  the JSON atomically (temp file + rename) to the file
  `$SKETERM_AGENT_FACTS` names (`<runtime dir>/sketerm/agent-facts/<id>.json`
  on the agent's host) and runs the user's own status command
  (`$SKETERM_AGENT_STATUS`) with the same JSON, so the screen shows what
  it always showed; with none it prints nothing. The user's command is
  looked up at each start on the agent's host, the way Claude Code does:
  the first of `{cwd}/.claude/settings.local.json`,
  `{cwd}/.claude/settings.json` and `~/.claude/settings.json` (its
  directory replaced by `CLAUDE_CONFIG_DIR` when the agent's environment
  sets it, which `unset_env` means only through `env`) with a
  `statusLine.command`; its other keys (`padding`) are kept. A caller
  whose `args` pass `--settings` gets no status command (facts unknown,
  `facts_unknown` says why), never a refusal. A local agent's file is
  read directly; a remote one's rides its host's probe (the same
  terminal, 15 s cache and 1.5 s `agent_list` wait as `hosts`), so
  remote facts can be up to 15 s old. opencode's source is its API:
  `message` (the latest root assistant message with a token count above
  0) and `model` (that model's entry in `GET /provider`, read again at
  the first facts read, since a catalog loaded while the server starts
  can hold another window, then kept); its percent is derived. Measured on both generations: each
  model step is its own message, created with every count 0 (1.x) and
  filled when the step ends, and its counts are that one request's
  (input without the cache read), so the sum of input, output,
  reasoning and both cache counts of the latest counted step is what
  the window holds, as opencode's own UI reads it; a lifetime total is
  never the context. No daemon wire change: the file path
  and the user's command ride the spawn's environment like `env`.
- **Retry on overload (`retry_on_overload`,
  `capabilities.agent_retry_on_overload`).** Off by default. `agent_open`
  or `agent_set` `retry_on_overload: {max, backoff_s}` (max 0-10, default
  3, 0 or null = off; backoff_s 1-600, default 15): when a turn ends on an
  `error` of class `overloaded` (the adapter's error rules: opencode
  `APIError 5xx`/`Overloaded`/`Service Unavailable` and a dropped provider
  connection, `APIError: Connection reset by server`/`ECONNRESET`, Claude
  Code `Repeated 529 Overloaded errors`, `API Error: 5xx`,
  `overloaded_error`), sketerm
  types the adapter's `retry.prompt` (`continue`) once the agent is idle,
  after the backoff (doubling, capped at 600 s), at most `max` times per
  job (a prompt the caller sends starts a new budget; `agent_interrupt`
  cancels a pending retry). Usage limits and auth failures are never
  retried (`vocab.ErrorClass.retriedOnOverload`). While a retry is
  pending, the overload `error` and the `done` of the turn it ended are
  HELD (`events.Event.held`: they wake nobody and settle no turn); a
  continued turn that ends in a `done` recovers: the errors stay held
  (they read as notices; a `retrying: true` consumer still gets them) and
  that done covers every job the retries spanned. Running out of retries,
  another error class in the continued turn or the app's exit gives up:
  every held error wakes with the one that ended it. Each step is a
  notice record (`retry 1 of 3, sending "continue" in 15 s`, `the turn
  went on after 1 retry`, `gave up`), and every per-agent result and
  `agent_list detail` carry `retry_on_overload` (`max`, `backoff_s`,
  `used`, `pending`, `next_in_ms`). `src/agent/retry.zig` is the one
  policy, unit-tested on fake error sequences; the MCP layer only types the
  prompt (never while a recipe runs on the agent).
- **Stall alarm (`stall_after_min`, `capabilities.agent_stall`).** Off by
  default. `agent_open` or `agent_set` `stall_after_min: N` (minutes,
  1-1440; 0 or null = off) raises ONE always-on `stalled` event when the
  agent shows no screen or record change for N minutes while it should
  be busy (`vocab.State.stallWatched`: starting, working, waiting on
  subagents or background tasks, retrying; never idle, waiting on the
  user, exited or disconnected), with the minutes and the state in its
  text (the state also as `detail`) and, when known, the last
  activity's wall time (`isoLocal`) and the last tool the agent called
  (`silent for 16 minutes while working, last activity
  2026-10-04T11:32:50+02:00, last tool Bash: ...`;
  `capabilities.agent_stall.names_last`). A busy Claude Code turn's calls
  are records only at the turn's end, so the last tool is read off its
  screen (`Agent.recentTools`, read-only, worked out only when the event
  fires); `agent_read detail "activity"` lists its calls the same way. It wakes every waiter and wait like
  `done` (the caller opted in by setting it) but settles no turn, and it
  re-arms only after the agent shows something again, so a wedged app
  costs one wake-up, not one per wait. It is silence only, no process
  inspection: an agent thinking for longer than N minutes without drawing
  raises it too. The value is kept in the descriptor (relaunches and
  reattaches keep it), reported as `stall_after_min` on every per-agent
  result and `agent_list detail`; `src/agent/stall.zig` is the one rule.
- **Relaunching after a reboot.** A relaunch of an agent whose app ended
  under THIS server keeps that entry's hold on the agent's lock (it is never
  let go and taken again), so it never needs `takeover`; an agent a live
  OTHER server holds is still refused as `conflict` without it. Its port
  forward (opencode on a host) is this server's own ssh under one name per
  agent, `agent-<id>-forward`: a dropped entry always ends it, and a start
  ends a session still holding the name first, so the relaunch sets the
  forward up again under the same id and name (the old one, left running,
  made every opencode relaunch fail with "could not start the port
  forward"). What the resumed app reprints is history, never news: from
  the start until the first prompt or answer sketerm sends (or a turn the
  app starts itself) every record it shows is marked handed out and every
  `done`/`message` event announcing one delivered (`foldHistory`; a long
  reprint lands after the app reads ready, which once put a `done` with an
  hours-old answer in the relaunch result and `agent_read final`), and a
  relaunch from the same server also carries the gone entry's handed-out
  content keys.
- **Unreachable hosts (`capabilities.ssh_connect_timeout_s`).** Every ssh
  and scp leg passes `ConnectTimeout=10` (`sshroute.Args.options`), so a
  host that is down fails within that bound instead of the kernel's ~2
  minutes; a leg riding a live ControlMaster opens no TCP connection and
  is unaffected. When ssh's own line says it could not reach the host
  (`sshroute.unreachableLine`: connect to host, unknown name, banner
  timeout), the connect is not retried and `term_open`, `agent_open`
  (probe or spawn) and `agent_attach` answer error `host_unreachable` with
  the host and ssh's line (`term_open`: details `host`, `ssh_error`)
  instead of falling back to a plain ssh session that would only fail
  later.
- **Remote agents never die with the link.** With `host`, `auto` runs the
  agent on the host's own sketerm-mux, deploying the portable one there
  when the host has none (`src/mux/deploy.zig`, the deployer every first
  hop uses); a failed deploy or start is an error naming why (with what
  ssh said), never a silent plain-ssh agent. `transport: "ssh"` asks for
  the plain ssh session explicitly. A remote opencode's port forward is
  this server's own ssh, re-created on a free local port on attach.
- **Long prompts and Claude Code's paste collapse.** Claude Code 2.1.288
  collapses typed input it reads as a paste into `[Pasted text #N]`, and
  the model receives it inside `<pasted_content>` (measured: a single
  write over 800 bytes collapses, a 99-byte four-line one does not; the
  threshold is `bJ=800` in the bundled CLI's paste handler, which also
  collapses more than `min(rows-10, 2)` line breaks of a real bracketed
  paste). The adapter's `screen.paste` (`lead_in`, `over_chars`,
  optional `over_newlines`, `pause_ms`) makes the recipe step that types
  `{text}` type `Please carry out the instructions in this text: ` first
  and pause 300 ms, so the message reads as typed words followed by the
  pasted block; short prompts (a retry's `continue`) get nothing, and no
  sender line is ever added. The lead-in must ASK for the pasted
  instructions to be followed: Claude Code tells the model to act on
  instructions inside `<pasted_content>` only where the user's own words
  ask it to. Measured on Haiku 4.5: `Here are my instructions: ` + paste
  was declined as "no explicit instruction"; the current wording + the
  same kind of paste was carried out exactly.
- **Startup prompts.** A prompt the app shows before it is ready is still
  an interaction (state `waiting_user`, `needs_input`), so `agent_open`
  returns instead of sitting in `starting`: Claude Code's "trust this
  folder" dialog (measured, 2.1.287: `Permission Required: Accessing
  workspace:` with lettered options `y. Yes, I trust this folder` / `n.
  No, exit` and `Enter y/n:`) is declared in `data/agents/claude.json`
  (the `choice_prompt` rule), and lettered options carry their `key`, the
  letter `agent_answer` types. Answering it waits for the app to be ready.
- **Hosts and caps (`capabilities.agent_hosts`, `agent_caps`).** `agent_list`
  (compact and detail) adds one line per host this server has live agents
  on (`local` for this machine) and `hosts`: its agent count,
  `mem_available_mb`/`mem_total_mb`, `load` (1, 5, 15 min) and `age_s`.
  The numbers come from one POSIX sh script (`src/agent/hoststats.zig`:
  `/proc` on Linux, `sysctl`/`vm_stat` on macOS) run by a short-lived
  terminal on this server's private daemon, over ssh for a remote host,
  cached 15 s per host; agent_list waits at most 1.5 s for them, and a host
  that cannot say, or did not answer, reads `unknown` with the reason,
  never a failed list. Config `mcp_agent_max_per_host` and
  `mcp_agent_min_free_mb` (0 = off, the default) make `agent_open` refuse
  (`refused`, naming the host, the number and the key) a host already at
  that many live agents of this server or with less memory available; a
  host whose memory is unknown is not refused, and the result's notes say
  the cap was not checked.
- **Gone agents in `agent_list`.** By default they are left out and only
  counted (`exited_hidden`, one line). With `include_exited: true` (or
  `state: "exited"`), compact, every gone agent shown shares ONE line
  (`gone: claude-qx9z (claude-8) relaunchable, ...`) and the `gone` fact
  (`agent`, `name`, `relaunchable`) instead of a full entry each, and
  `detail: true` lists them in full.
  `agent_open name:` that a gone agent holds is a `conflict` naming that
  agent: `agent_attach {agent, relaunch: true}` starts it again under the
  name, `agent_close {agent}` forgets it (also for a gone agent only the
  index still knows, unless another live server holds it) and frees the
  name. `resume` never takes a gone entry over by itself.
- **Selectors (`capabilities.agent_selectors`).** ONE grammar names a
  set of agents by what they are (`src/agent/selector.zig`, the only
  place it is parsed): `"*"` every live agent of this server (any state
  but `exited`); `"host:<name>"` the live agents on that SSH host,
  `host:local` the ones on this machine; `"state:<state>"` the agents
  in that state, one of the `vocab.State` names (`starting working
  waiting_subagent waiting_background waiting_user retrying idle exited
  disconnected`), `state:exited` the gone ones. Anything else, an
  unknown state included, fails closed (`invalid_args`) naming what is
  accepted; a selector that matches none is `not_found` listing this
  server's agents with their states and hosts. `agent_send`,
  `agent_wait` and `agent_close` take one as their `agents` string;
  `agent_list`'s `state` and `host` filters go through the same parse
  (both given: both must hold).
- **Closing in batches (`capabilities.agent_close_many`).** `agent_close
  agents: [...]` (ids or names, at most 32) or `agents: "<selector>"`
  (see Selectors) closes each, and `exited: true` (without `agent` or
  `agents`) forgets every gone (exited) agent of this server in one call.
  Both answer like `agent_send agents`: `results`, one per agent named
  (`agent`, `name`, `closed`, `sessions` killed, `forgotten` for a gone
  one only the index knew, or its `error`), `count` and `failed`; one
  agent's failure (an unknown name, another server's agent) never stops
  the others.
- **`agent_list`** gives one short text line per agent and, per agent in
  `agents`, by default the compact facts an orchestrator of many agents
  scans (`capabilities.agent_list_compact`; with 17 agents the full set
  cost ~5k tokens): `agent` (the id), `name`, `app`, `state`, `host` (or
  `local`), `cwd` (which clone a worker is in), `idle_s` (seconds since
  the app last drew or sent anything), `queued` (prompts its app holds),
  `pending` (the prompt it waits on: `kind` and `title`), `preview` (the
  first line, at most 120 bytes, of its newest job's last assistant
  message, `select.newestFinal`: a glance that hands nothing out, so
  `agent_read final` still returns it whole; absent before that job has
  one; `capabilities.agent_list_preview`), `conversation` and `facts`
  (above); `detail: false` says which. `detail: true` gives every
  fact: where and how it runs: `host` (absent: this machine),
  `transport`, `cwd`, `binary`, `model` and
  `effort` when known (Claude Code: the launch value or the model chosen
  since; opencode: the next prompt's), `state`, `session`/`sessions`
  (opencode adds its server's), `started_ms` (kept across a durable
  reattach), `last_activity_ms` (the app last drew or sent anything; both
  Unix ms), `queued_prompts`, `pending_events` and `recordings`.
  Both forms take `state` and `host` (Selectors) and leave gone
  (exited) agents out unless `include_exited: true` (or `state:
  "exited"`): they are only counted, `exited_hidden`, with one line
  saying so; `count` is the agents the list names.
- **`agent_attach`** with `agent` resumes an agent (above); with `term`
  and `app` it puts a screen adapter on a terminal `term_open` created
  (you started the app yourself), `attach: "adapter"`, and `agent_close`
  then drops only the adapter.
- **Watch-along from any host.** The server's registry record
  (`$XDG_RUNTIME_DIR/sketerm/mcp-servers/<pid>.json`,
  `src/ipc/mcp_registry.zig`) lists its agents and is rewritten
  atomically whenever one opens, is attached, closes, relaunches or is
  reattached: per agent its `id`, `app`, `sessions` (opencode's
  `-server` included) and `location`: `user` (this host's per-user
  daemon: local and plain-ssh agents), `host:<B>` (B's per-user daemon:
  the remote sketerm-mux transport) or `instance` (this server's private
  daemon: an adapter on a `term_open` terminal, or an agent of an older
  server). The record stays version 1
  (an older reader refuses any other version); a record without
  `agents` comes from a server that predates them. Every sketerm-mux
  reports its host's live servers in its session list (`assistants`,
  capability `assistants`), so a GUI that reaches host A, directly or
  through a route, learns A's assistants and their agents and derives
  where to watch each one (`sshroute.watchSpec`):
  `route:A#<instance>` for an `instance` agent, `route:A/B` for a
  `host:B` one, `A` itself for a `user` one (a GUI that predates `user`
  skips such an agent; its session still shows in the Session
  Overview). Such a route ends in `sketerm-mux --proxy --instance
  <key>` on A, which bridges only a LIVE server's daemon (the
  registry's flock decides) and never starts one: a server that exited
  is refused as not running, an unknown key as unknown. The instance
  key is the server's `--name`, or `tmp-<pid>` for an unnamed one.
- **Watching them from the GUI.** A sketerm window that has a pane (or
  app session) on host A reads A's report on its own: the tab-bar AI
  chip counts A's agents, its popover lists each server as `<name> on
  A` with one row per agent (`claude-1 (claude)`, and `claude-2 (claude)
  on B via A` for one placed on B), and the Session Overview lists the
  same rows. Watch and Take control attach along the derived route,
  read-only or with the controller lease, exactly as for an assistant on
  this machine; a refusal (the server exited, a too-old sketerm-mux on a
  hop, an unreachable hop) is shown as a message naming the hop. A host
  whose sketerm-mux predates the report contributes nothing. When the
  server exits, its agents leave the chip with A's next report (a few
  seconds).
- **Templates (`capabilities.agent_templates`).** An orchestrator that
  sends the same rules in every brief saves them once:
  `agent_template_save {name, text, vars, description}` writes
  `$XDG_STATE_HOME/sketerm/agent-templates/<name>.json` (0600, the
  per-user store `mcpassets.zig` keeps app templates and macros in; a bad
  name is refused, never cleaned up), `agent_templates` lists them (or
  shows one with `name`) and `agent_template_delete` removes one.
  `agent_send` and `agent_open` take `template` + `vars` instead of, or
  before, `text`/`prompt` (the caller's text is appended after the
  rendered template). Placeholders are `{name}`; `{{` and `}}` are
  literal braces and any other brace is refused at save; a variable with
  no default that is not passed, or one passed that the template does
  not have, is `invalid_args` naming it (`src/agent/brief.zig`). The
  rendered prompt goes through the same typing, queueing and interrupt
  paths as any other; the result of the call that sent it carries
  `template` (the name) and never the rendered text.

The server's `instructions` (initialize result) tell the assistant to use
`agent_open` for Claude Code and opencode, to run `watch_command` in the
background instead of polling (`--any` for several agents, `--all` for
one wake-up once all settled), that `agent_send` takes `interrupt` and
`agents`, that `agent_read final:true` returns just the last message and
`agent_list` is compact unless `detail:true`, and that `agent_open`
returns an id that `agent_attach {agent: id}` resumes after a restart
(`relaunch: true` for a gone one), whenever the agent tools are offered.

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
- `checkbox`: `{label,value}` with a boolean value (default false). Toggling it
  emits `change` carrying the new boolean.
- `table`: `{columns,rows}`. `columns` is an optional header row of strings;
  `rows` is an array of rows, each an array of cell strings of the same width
  (the header's, when there is one). Without a header, a one-column table is a
  list. Bounds: 16 columns, 256 rows, 256 bytes per cell. Activating a row
  (click, or Enter on a focused row) emits `click` with the row's 0-based index
  among the data rows. It is not virtualized.

The type set is part of the panel wire vocabulary (`src/panelvocab.zig`
`COMPONENT_KINDS`) and only ever grows at its end, so a document written for an
older GUI keeps its meaning.

The user reaches saved panels without an assistant through the palette, the
pane menu's Panels submenu and the window menu: Open Saved Panel… (in a tab of
its own, `panel_open`) and Open Saved Panel in Window… (`panel_open_window`),
both bindable in config.conf.

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

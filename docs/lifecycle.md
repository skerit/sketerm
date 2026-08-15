# Lifecycle

Session lifetime: PTY spawn in the daemon, pane creation and teardown in
the GUI, signal handling on both sides, the browser helper, application
startup and shutdown. Companion to `architecture.md` (read its "Data
flow", "Threading model" and "Deferred callbacks and liveness" sections
first); this document goes deeper on start/stop ordering and on the
hazards that only show up during teardown.

## There is no worker thread. There never is one again.

The GUI process owns no PTY, runs no VT parser and has no per-pane
worker thread. Every terminal, local or remote, is a session owned by
`sketerm-mux`; the GUI attaches to it as a client. `Terminal.initRemote`
(`src/terminal.zig`) is the only constructor, and the module header says
so.

Older revisions of this document, of `docs/plan.md` and of
`docs/milestones.md` describe an in-process design: `pthread_create`
per pane, a 64 KB lock-free SPSC ring, a `drain_pending: Atomic(bool)`
cross-thread wakeup, an `eventfd` shutdown fd, `pthread_join` at close,
"SIGCHLD blocked in workers". **All of that was deleted with the mux
rewrite and must not come back.** Nothing in the tree implements it:
there is no ring, no `drain_pending` field, no `workerMain`, and the
GUI installs no SIGCHLD handler at all. If a plan proposes reintroducing
a per-pane reader thread "for latency", the answer is that the parse
already happens off the GUI's thread, in another process, with process
isolation and session durability as bonuses.

What survived under a similar name is `DrainHandle`, which is not a
drain any more but a liveness fence (see below).

## PTY spawn (daemon side)

`Pty.spawn` in `src/pty.zig` is called only from
`src/mux/daemon_sessions.zig` when a session is created. `src/pty.zig`
is compiled into both binaries, and `build_options.glib` gates the two
places where it would otherwise need a main loop: the POLLOUT write
watch (`queueBytes`) and the asynchronous child reaper
(`closeAndReapAsync`). In the daemon both fall back to bounded blocking
loops.

Sequence, in `Pty.spawn` order:

1. `openpty(&master, &slave, NULL, NULL, &winsz)` with the requested
   rows/cols.
2. `FD_CLOEXEC` on the master, then `O_NONBLOCK` on the master. The
   non-blocking master is what stops a hung child (one that stopped
   reading its slave) from parking the caller on every keystroke.
3. `fork()`. On failure both fds are closed and `error.Fork` is
   returned.
4. Child (`childExec`, `noreturn`):
   `setsid()` -> `ioctl(slave, TIOCSCTTY, 0)` -> `dup2` slave over
   0/1/2 -> close slave and master -> Yama relaxation when
   `debuggable` (must precede exec; it survives execve) -> clear the
   signal mask -> `setenv` the terminal identity (`TERM`, `COLORTERM`,
   `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`, `KITTY_WINDOW_ID`) and the
   session identity (`SKETERM_PANE_ID`, `SKETERM_SESSION`,
   `SKETERM_SESSION_ORIGIN_ID`, `SKETERM_MUX_SOCKET`, `SKETERM_SOCKET`)
   -> optional Wayland/PulseAudio/runtime-dir/a11y-bus overrides ->
   caller-supplied `env` last, so it wins -> `chdir` -> `execvp`. On
   exec failure it writes a diagnostic to fd 2 and `_exit(127)`.
5. Parent closes the slave and keeps `{master_fd, child_pid}`.

Gotchas that are easy to undo:

- **`chdir` is skipped, never truncated.** A cwd longer than the 4096-byte
  stack buffer would otherwise chdir somewhere else entirely, silently.
- **`login_shell` rewrites argv[0] to `-<basename>`**, which is what makes
  the child source the login files. The bash shell-integration path
  instead injects `--rcfile <shim>` and only for a bare shell spawn:
  extra argv means a script or `-c` invocation, where trailing options
  would become the script's arguments.
- **The daemon sets `O_NONBLOCK` on the master a second time**, in
  `daemon_sessions.zig`, right after spawn. Its poll loop does bounded
  read rounds and cannot afford a blocking master.

## Window-size propagation

The GUI does not `ioctl` anything: it owns no master fd. The chain is

1. The pane's `GtkGLArea` allocation changes; `TerminalSurface` computes
   `{cols, rows}` from logical size and cell metrics.
2. `Terminal.requestResize(rows, cols)` stores `pending_rows/cols` and
   sends a `.resize` frame (4 bytes, little-endian u16 pair). If the
   transport is down the values stay pending and `sendPendingResize`
   replays them from `installReattachedConn` after a reconnect.
3. The daemon (`src/mux/daemon_serve.zig`, `.resize` case) validates the
   pair (nonzero, <= 1000), calls `Screen.resize` on the authoritative
   screen, `pty.setSize` (which is the `TIOCSWINSZ`), tells the cast
   recorder, and then **broadcasts a fresh snapshot to every attached
   client** because event streams assume a fixed grid.
4. The kernel delivers `SIGWINCH` to the pty's foreground process group.

Consequence worth remembering: the GUI deliberately does NOT resize its
mirror `Screen` locally. The snapshot that comes back replaces the grid
wholesale, so a local reflow would only be thrown away.

Neither binary installs a `SIGWINCH` handler. The GUI is not a tty
client, and the daemon's sizes are pushed to it, not signalled.

## Pane creation (GUI side)

A local tab or split goes through `Window.daemonSpawnPane`
(`src/ui/window.zig`):

1. Allocate a pane id and mint a session name.
2. `muxConnect(null)` -> `mux_client.Conn.connectLocalAutostart`: connect
   to `$XDG_RUNTIME_DIR/sketerm/mux.sock`, and if nothing answers, fork
   a detached `sketerm-mux --broker`, then retry the connect for up to
   two seconds. The child `setsid`s and redirects stdio to `/dev/null`
   before exec **because the daemon outlives the client that started
   it** - inheriting the client's stdout wedges any pipeline that client
   sits in forever.
3. Send `.spawn` (JSON: name, argv, cwd, 24x80 seed geometry, pane id,
   IPC socket, TERM, shell integration, `local: true`, the GUI's own
   `WAYLAND_DISPLAY`), await `.ok`.
4. `sendAttach` with `kind: "gui"`, then `recvGuiAttach` for the first
   snapshot. All of this blocking IO happens BEFORE any `Terminal`
   exists, which is exactly why `initRemote` can be non-blocking.
5. `makeRemotePaneFromSnap` builds the Pane + Terminal from that
   snapshot.
6. `r.ephemeral = true` marks the session GUI-owned, and
   `r.predictor.force = .never` disables predictive echo (there is no
   round-trip latency worth hiding on a local socket).

`Terminal.initRemote` then: restores the snapshot into a mirror `Screen`,
sets `screen.mute_responses = true` (the daemon's authoritative screen
already answers DSR/DA/DECRQM; a second reply would double every
response the app sees), sets the connection fd non-blocking, installs
the `g_unix_fd_add` watch, and posts **one idle kick**. That kick exists
because `recvExpect` may have buffered frames past the snapshot into
`conn.rbuf`, and an fd watch only fires on NEW socket bytes: without it
a quiet session could sit on already-received frames forever. The kick
is routed through the `DrainHandle`, not through the `Terminal`, so a
teardown before the idle runs cannot dangle.

Pane creation does not touch GL. Shaders, VBOs and the atlas are built
on the `GtkGLArea`'s `realize`, and every realize is treated as a
possible re-realize (see `docs/gpu.md`).

## Session end, and the kill-vs-detach asymmetry

This is the durability guarantee, and it is asymmetric on purpose:

| How the GUI goes away | What happens to the session |
| --- | --- |
| User closes the tab/pane/window, or quits cleanly | `Terminal.deinit` runs; an `ephemeral` session is KILLED, a durable one is DETACHED |
| GUI crashes (SIGSEGV, SIGKILL, power loss) | No teardown runs at all; every session survives in the daemon for reattach |

Both halves live in `Terminal.retireAttachmentForTeardown`
(`src/terminal.zig`), reached from `closePanelOrigin` at the top of
`deinit`: it flushes whatever is queued, then sends `.kill {"name":...}`
when `remote.ephemeral` is set and `.detach` otherwise. So closing a
local tab does not leak a daemon session, and killing -9 the GUI does
not lose the user's work. Do not "simplify" this into always-detach
(sessions pile up) or always-kill (durability gone).

`daemonSpawnPane` is what sets `ephemeral`; an explicit durable/remote
attach leaves it false. `layout.zig` persistence follows the same line:
`winlayout.zig` saves `mux_session`/`mux_host` only for NON-ephemeral
panes, because saving an ephemeral name would make restore recreate it
as a durable session (a leak, plus lost env parity). Ephemeral panes
restore as a plain command+cwd pane routed back through
`daemonSpawnPane`, which re-marks them ephemeral.

On the daemon side a session ends when the PTY read hits EOF or a
non-EAGAIN error (`src/mux/daemon.zig`, around the session read round)
and `sessionExited` runs: it clears the controller, then **retries
`pty.reap()` for up to 50 x 1 ms**. A single `WNOHANG` try races the
scheduler and ships exit status 0 for a child that actually died of
SIGSEGV - that was a real bug report ("segfault exited 0"). Then the
final log tail and, for a backlogged client, the resync snapshot go out
BEFORE the `.exit` frame, because clients stop pumping once they see
`.exit`.

`Pty.reap` and `Pty.closeAndReap` both bail on `child_pid <= 0`. That
guard is not decoration: `waitpid(-1)` there would reap an arbitrary
unrelated child (another session's, or a GUI child). `signalTree`
signals `-pid` first so a wrapper script's real payload dies with the
session, falling back to the bare pid when the group is gone, and
`closeAndReap` escalates nothing -> SIGTERM -> SIGKILL with a final
group sweep after the leader is reaped.

(`src/pty.zig`'s `decodeStatus` docblock still refers to a
`Terminal.reapStatus` to keep in lockstep with. That function no longer
exists - see "Known drift" at the end.)

## What the GUI does when a session ends

The daemon's `.exit` (clean child exit, carries the i32 status) and
`.gone` (killed, or daemon shutting down) both land in
`Terminal.handleRemoteFrame` -> `remoteClosed(reason, crashed=false)`,
which sets `screen.child_exited`. A transport that dies without either
frame is a CRASH: `remoteClosed(..., crashed=true)` fires `on_crashed`
so the GUI can show the sad-face overlay with a "Start new session"
button, falling back to `paintCrashFace` (which paints the grid
directly) when no GUI is wired.

`TerminalSurface`'s tick notices `child_exited`, and the pane forwards it
through `on_child_exit` -> `Window.onTermChildExit`
(`src/ui/termsinks.zig`). For a forwarded app (`remote.is_app`) that
exited before ever opening a window, the pane is HELD with its log
visible - that log is the only diagnostic a failed launch produces.
Otherwise `Window.detachPaneToShell` swaps a fresh local shell pane into
the same slot, so the tab survives.

The frame loop has one ordering rule that is easy to break: after
dispatching a frame, `remoteSocketCb` re-checks `remote.closed` and
returns `G_SOURCE_REMOVE` immediately. `remoteClosed` zeroes `watch_id`
on the assumption that the callback is about to remove itself, and
`detachPaneToShell` is about to free this `Terminal` - returning
`G_SOURCE_CONTINUE` there leaves a live fd watch on freed memory.

## Reconnect

Transport loss on a still-running session is not session death.
`transportLost` tears down the watches, cancels every in-flight
operation (uploads, downloads, ranged reads, ticket requests, app
channels), bumps the panel generation, and starts a reconnect: a
DETACHED `std.Thread` running `reconnectThreadMain`, which does the
blocking connect+attach and hands back through `g_idle_add`
(`reconnectHandback` -> `reconnectDone`). Backoff doubles from 1 s and
caps at 30 s (`nextReconnectDelay`, unit-tested).

Three fences make that safe, and all three are needed:

- The job's `drain: *DrainHandle` -> `alive` check, so a handback that
  lands after the pane died no-ops.
- `reconnect_generation`, bumped on every new attempt, so a stale job
  losing a race cannot install its connection. A transport lost
  mid-upgrade genuinely has two jobs in flight at once.
- `origin_id` (the session's lifetime-unique incarnation id). A daemon
  too old to report one cannot prove that a same-name session is the
  same shell, so the pane goes `.unavailable` instead of reattaching to
  something else. Session names are reusable; identities are not.

Destructive lifecycle owners use the same identity for kill. The daemon
advertises `kill_origin_fence:true` only when it enforces `KillReq.origin_id`;
`Conn.sendKill` refuses a fenced request when that capability is absent instead
of sending an additive field that an older daemon would silently ignore. Only
callers that genuinely have no lifetime identity use the legacy name-only kill.

The same machinery does the SSH -> UDP transport upgrade
(`startTransportUpgrade` / `finishTransportUpgrade`), which is refused
while an upload, download or recording is in flight.

## Pane teardown

`Pane.severFaces()` is THE pre-teardown entry point. It severs, in
order, the IM context, browser, editor, panel, web and app-embed faces,
plus the AT-SPI bridge, and it is idempotent. Every path that is about
to destroy a pane's widgets calls it: `Window.unlistPane`,
`Window.closePane`, `Window.swapPaneInPlace`, the tab-close sweep in
`collectAndFreePanes`, and once more as a last resort from
`Pane.deinit`. **A new face is added to `severFaces`, never to the call
sites** - it used to be a hand-copied `detachIm(); detachBrowser();`
list at four sites, and the editor face, added later, reached none of
them.

The last-resort call from `Pane.deinit` passes the pane's
`widgets_dead` flag down to each face's prepare-destroy hook, so a face
cannot touch a widget subtree GTK has already finalized.

Teardown order for a closing pane:

1. `severFaces()` while the widgets are still alive.
2. `Terminal.clearSinks()` - null every callback pointer, so anything
   already queued on the main loop finds a quiesced Terminal and
   produces no further callbacks.
3. `schedulePaneTeardown` -> `g_idle_add(deferredPaneTeardown)`, which
   frees Terminal then Pane. The defer is not cosmetic: the widget
   destroy chain must finish firing its controller and signal-closure
   cleanups first, or callbacks from that same subtree observe a
   half-freed Pane. The holder is allocated from `c_allocator` so its
   lifetime is independent of the app GPA; OOM falls back to a
   synchronous teardown (accepting the crash risk over a guaranteed
   leak).
4. `Terminal.deinit` sends the kill-or-detach frame, clears
   `drain.alive` and nulls `drain.terminal`, removes the read/write/idle
   watches and the reconnect and prediction timers, cancels transfers
   and channels, and frees the mirror screen, style pool and parser.
5. `Pane.deinit` stops the surface's visual timer sources (the
   frame-clock tick is widget-owned and dies with the GLArea; the
   `g_timeout` ones are not), detaches a11y, calls `severFaces` again,
   disconnects the wrapper-destroy fence if the widgets somehow outlived
   the pane, and deinits the surface.

`Window.collectAndFreePanes` additionally retires panel relay origins
first (closing one can close a panel tab and mutate the pane arrays
mid-iteration) and closes any window-level UI still pointing at the
dying pane - search bar, hints, copy mode, zoom - because those hold raw
`*Pane` pointers and slices into it.

## Deferred callbacks and liveness

`DrainHandle` (`src/terminal.zig`) is allocated per `Terminal`,
deliberately outlives it, and is **not freed in `deinit`** - reclaiming
it would need tracking of every pending glib invocation, which glib does
not expose, and the leak is under 32 bytes per pane ever created. It
carries:

- `alive` - cleared at the start of teardown; every callback that is not
  widget-attached checks it first.
- `terminal` - the fenced back-pointer, nulled at teardown, that those
  callbacks resolve through instead of capturing a `*Terminal`.
- `panel_assets_live` - cleared only on PERMANENT teardown. Transport
  loss leaves it set, so already-committed local panel hydration
  survives a reconnect.

Users: the attach idle kick, the socket write watch, reconnect and
prediction timers, reconnect handbacks, the async OSC 52 clipboard read
(`src/ui/clipboard.zig`), remote-control replies (`src/ui/remotectl.zig`)
and panel asset jobs (`src/ui/panelhost.zig`).

For widget-attached callbacks `DrainHandle` is the WRONG tool; the three
mechanisms (widget-owned `GDestroyNotify`, disconnect at teardown,
liveness fence) are alternatives and never layers. `CLAUDE.md`'s
memory-ownership section is the reference, and `src/ui/panel/canary.zig`
is a detector for when the choice was made wrong, not a fourth
mechanism.

## Threads

The GUI's only threads are short-lived DETACHED workers doing blocking
IO that touches no GTK, GL, `Screen` or `ImageStore` state:

- reconnect / transport upgrade (`src/terminal.zig`),
- panel transport setup and panel asset reads (`src/ui/panelhost.zig`),
- gdk-pixbuf decode and file-browser thumbnailing
  (`src/ui/browser/preview.zig`),
- browser-connection setup (`src/ui/browser/conn.zig`),
- the LSP link thread (`src/ui/editorlsp.zig`).

Every one of them hands back through `g_idle_add`, and **only the idle
handback frees the job**, so a cancelled worker can never race its own
teardown. A worker that needs GTK is a bug, not a pattern to copy.

The daemon is single-threaded: one `poll()` loop
(`Daemon.run` -> `tick`) drives PTY reads, parsing, client IO, channels
and timers.

## Signal handling

GUI (`src/main.zig`, `src/util/crashlog.zig`):

| Signal | Handler |
| --- | --- |
| `SIGTERM`, `SIGHUP`, `SIGINT` | `g_unix_signal_add` -> `g_application_quit`, so the "shutdown" handler runs and the layout is saved |
| `SIGUSR1` | Reload config from disk in every live window (`kill -USR1` from a script) |
| `SIGPIPE` | Neutered with a no-op handler, NOT `SIG_IGN` (the `SIG_IGN` macro translates to a bogus fn pointer here) |
| `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGFPE`, `SIGABRT`, `SIGTRAP` | Post-mortem record, then re-raise with the default disposition so the core dump still happens |
| `SIGCHLD` | No handler. The GUI owns no pty child; its only child is the browser helper, reaped with `waitpid(WNOHANG)` from the web client |

`g_unix_signal_add` dispatches on the main thread, so those handlers may
touch GTK state; the fatal handler may not, and is async-signal-safe by
construction (fd opened at install, fixed buffer, one `write`,
`SA_RESETHAND | SA_NODEFER | SA_SIGINFO`).

`crashlog.set`/`clear` leave a breadcrumb around risky operations, which
the fatal handler appends to `$XDG_STATE_HOME/sketerm/crash.log`. A GUI
death is worse than a daemon death - it takes every attached session's
viewer at once - and a stripped ReleaseFast build leaves no other
evidence.

Daemon (`src/mux_main.zig`): `SIGTERM`/`SIGINT` set the run loop's
`running = false` for a clean shutdown (socket unlink, child reap);
`SIGPIPE` gets the same no-op handler, so writing to a client that
vanished cannot kill the daemon. It installs no `SIGCHLD` handler
either - children are reaped from the poll loop.

## Browser helper (optional)

`sketerm-webengine` is a third process, the only binary linking CEF, and
its lifecycle is independent of both the daemon and any session. See
`src/web/CLAUDE.md` for the engine-side invariants (the re-exec with
`LD_PRELOAD`, the `cef_api_hash`-first rule, ozone platform selection)
and `src/ui/webface.zig`'s header for presentation and pacing.

GUI-side lifecycle (`Client` in `src/ui/webface.zig`), all of it
non-blocking:

- **One helper per GUI process**, module-level (`g_client`) and never
  freed; several web faces share it and are routed to by view id.
- **Started lazily** on the first `ensure`: locate the binary
  (`$SKETERM_WEB_BIN`, then a sibling of our own exe, then the dev tree,
  then `$PATH`), unlink any stale socket, `fork` + `execv` with stdio on
  `/dev/null` so the helper can never wedge a pipeline the GUI sits in.
- **Connected by a retry timer**, which each tick also `waitpid`s the
  child: a helper that died during startup (missing libcef, broken CEF
  deployment) reports "exited during startup" instead of timing out.
- **Degrades gracefully.** A missing binary, a helper that never answers
  and a crashed helper all end in `state = .unavailable` with a static
  reason string pushed to every face. `reason_retryable` is false only
  for "not installed", where a retry can only fail identically; the
  overlay's Reload button calls `restart`, which SIGTERMs and reaps the
  old helper and starts over.
- The socket fd is watched with `g_unix_fd_add` and reaped
  non-blockingly (`waitpid(WNOHANG)`), because the helper is our own
  child and an unreaped exit would be a zombie for the GUI's lifetime.

Frame buffers arrive as file descriptors over `SCM_RIGHTS`; the client
holds them in arrival order and a `frame_buffer` frame pops the front
one. `teardownConnection` closes all of them, which is the one place a
lost connection could otherwise leak fds.

## Application startup

`main(init: std.process.Init.Minimal)` in `src/main.zig`:

1. Profiling init and `crashlog.install()` - as early as possible, so a
   crash during startup is still recorded.
2. **Subcommand dispatch before GApplication.** `cli`, `mcp`, `app`,
   `mux`, `mount`, `run`, `portal`, `doctor` never enter GApplication:
   they are socket or stdio programs and must work with no display.
   `--help`/`--version` also exit here.
3. Identity selection: `files` / `edit` / `web` / viewer / play
   invocations set `g_app.mode`, which picks the GApplication id suffix,
   `g_set_prgname` and the application name. The prgname must match the
   desktop entry's `StartupWMClass` (see `CLAUDE.md`'s packaging
   section). `SKETERM_APP_ID` overrides the base id so a test instance
   cannot coalesce into the user's running one.
4. `upgradeLocalDaemon`: a leftover local daemon from before a binary
   upgrade would keep serving old code forever, so a daemon that is both
   STALE and IDLE (no sessions, no live jobs - `upgradeStaleIdle`) is
   asked to exit, and startup then waits, bounded, for a fresh one to
   answer. A busy daemon is the user's running work and is never
   touched.
5. `adw_application_new(app_id, G_APPLICATION_HANDLES_COMMAND_LINE)`,
   plus the `command-line` / `activate` / `shutdown` handlers, the
   `toggle` action, and the signal sources above.
6. `g_application_run`.

`onCommandLine` fires for the primary instance AND for every later
invocation (which is what makes `sketerm --toggle` reach a running
window), so it must be re-entrant: `--layout` and `--config` free the
previous dupe before storing a new one, or a repeated `--toggle` leaks
one path per call.

`onActivate` builds the window and its content:

- If a primary window already exists, this launch is one MORE window,
  and it is deliberately SECONDARY: a second `is_primary` window would
  quit the whole app when closed and would clobber the process's notion
  of the primary.
- Otherwise: `Window.initWithConfig`, then content from exactly one
  source - `--layout <path>`, else `--restore`
  (`$XDG_STATE_HOME/sketerm/last.json`), else the user's saved
  `default.json` if present, else one fresh shell tab. Files and web
  identities skip layouts entirely and open their own tab.

## Application shutdown

The `shutdown` signal handler (`onShutdown`) runs while the windows are
still alive; GTK destroys them afterwards. Order matters:

1. Free the pending request objects (viewer batch, play specs, editor
   and web requests).
2. For EVERY live window, not just the primary: save the layout if this
   is the primary window and saving is enabled, then
   `detachWindowSignals()` and `Window.deinit()`. Handlers are detached
   first, or GTK's later destroy calls back into freed Window state.
   Secondary windows (tab drag-out, repeat launch) own real panes and
   GUI-owned sessions; skipping them leaked both.
3. `hostmount.shutdownAll()` last, because a FUSE mount can still be
   serving a file a pane opened.

Only the primary window's layout is written, to
`$XDG_STATE_HOME/sketerm/last.json` (`layout.defaultSavePath`;
`$HOME/.local/state/...` then `/tmp/sketerm-last.json` as fallbacks).
`layout.Layout` has no window dimension, so writing several windows
would just leave the last one standing. `default.json`
(`layout.defaultLayoutPath`) is the separate, user-saved layout that is
auto-loaded when no flag is given. `--no-save` suppresses the exit save;
`layout_saved_final` keeps it from running twice.

## Crash posture

- Fatal signals are recorded and re-raised, so core dumps still happen.
- The kernel reclaims fds, memory and pty masters. Children of a killed
  GUI are not its children at all - they belong to the daemon.
- **Sessions survive**, because teardown never ran and therefore never
  sent kill or detach. Reattach restores screen and scrollback exactly.
- The last clean layout save is on disk; `--restore` brings the tabs
  back.
- Daemon death is the other boundary: sessions are gone, orphaned PTYs
  SIGHUP their children. Same boundary tmux has.
- Daemon lifecycle events and warnings go to
  `$XDG_STATE_HOME/sketerm/mux.log` (all instances share it, `[pid]`
  attributes lines, rotated at 2 MB).

## Invariants

| Invariant | Enforced by |
| --- | --- |
| GUI owns no PTY and no parser thread | `Terminal.initRemote` is the only constructor; `deinit`'s non-remote branch is `unreachable` |
| Slave fd closed in the parent before the child runs | `Pty.spawn` parent path |
| Master has `FD_CLOEXEC` and `O_NONBLOCK` | `Pty.spawn`, plus a second `O_NONBLOCK` in `daemon_sessions.zig` |
| `waitpid(-1)` is never reachable from a session | `child_pid <= 0` bail in `Pty.reap` and `Pty.closeAndReap` |
| A closed GUI-owned tab kills its session; a crashed GUI does not | `retireAttachmentForTeardown` (kill on `ephemeral`, detach otherwise), reached only from `deinit` |
| No socket read ever blocks the main loop | `g_unix_fd_add` + `O_NONBLOCK` on the daemon conn and the web helper conn |
| Every face is severed while its widgets are alive | `Pane.severFaces` from all five teardown paths |
| Pane/Terminal are freed after the widget destroy chain | `schedulePaneTeardown` -> `g_idle_add` |
| A deferred callback cannot resolve a dead Terminal | `DrainHandle.alive` + nulled `terminal`, checked in every non-widget callback |
| A stale reconnect cannot install its connection | `reconnect_generation` + `origin_id` checks in `reconnectDone` |
| GL resources are created and destroyed on the main thread | `realize` / `unrealize` on the `GtkGLArea` |
| `TIOCSWINSZ` follows every grid geometry change | daemon `.resize` handler calls `pty.setSize` unconditionally |

## Known drift in the code

Two stale references to the pre-mux design survive in comments, and are
worth knowing about when grepping:

- `src/pty.zig`'s `decodeStatus` docblock tells you to keep it in
  lockstep with `Terminal.reapStatus`. That function no longer exists;
  the guard it described now lives in `Pty.reap` / `Pty.closeAndReap`.
  `src/mux/CLAUDE.md` repeats the same stale name.
- `Window.onTermChildExit` (`src/ui/termsinks.zig`) returns early for
  every pane with a `remote`, and since every Terminal is remote, the
  `config.exit_action` branch below it (close / restart / hold, plus the
  `--hold` override) is unreachable for terminal panes. The setting is
  still parsed, still written by `prefs.zig`, and has no effect.

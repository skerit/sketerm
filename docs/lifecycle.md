# Lifecycle

PTY spawn, worker threads, pane teardown, signal handling,
application startup/shutdown. Referenced by `architecture.md`
threading model and `milestones.md` M1 / M4 / M7.

## Pane creation

Main thread, step by step. **SIGCHLD is blocked across the
fork/register window** (steps 3-5) — otherwise a fast-exiting child
can deliver SIGCHLD before the pid is registered, and the handler
silently drops it.

1. Allocate `Terminal` struct. Owns: pty fds, parser state,
   Screen, ImageStore, worker thread handle, SPSC ring,
   `drain_pending: Atomic(bool)`.
2. `openpty(&master, &slave, NULL, NULL, &winsz)` — initial window
   size from the parent pane's cell dimensions, or a default
   (80×24) if this is the very first pane.
3. Block SIGCHLD. Save the old mask; restore it in **every** exit
   path (including fork failure) — otherwise a leaked blocked
   SIGCHLD hangs zombie reaping forever:
   ```zig
   var blocked: std.posix.sigset_t = undefined;
   var set = std.posix.empty_sigset;
   std.os.linux.sigaddset(&set, std.os.linux.SIG.CHLD);
   std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, &blocked);
   errdefer std.posix.sigprocmask(std.posix.SIG.SETMASK, &blocked, null);
   // errdefer restores mask on any error before step 5.
   ```
4. `fork()` — if it returns -1, the errdefer above fires and we
   return the error cleanly.
   - **Child**:
     1. `setsid()` — new session, no controlling tty yet.
     2. `ioctl(slave, TIOCSCTTY, 0)` — claim slave as controlling tty.
     3. `dup2(slave, 0)`, `dup2(slave, 1)`, `dup2(slave, 2)`.
     4. `close(master); close(slave)` — dup2'd.
     5. Clear signal mask, reset signal handlers to SIG_DFL.
     6. Build env: copy parent env, overlay
        `TERM`, `COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION`,
        `COLUMNS`, `LINES`.
     7. `chdir(cwd)` — on failure, try `$HOME`, then `/`. Log to
        fd 2 on fallback so parent sees it in the pane grid.
     8. `execvpe(argv[0], argv, envp)`.
     9. On exec failure, `write(2, "...", ...)` the diagnostic and
        `_exit(127)`.
   - **Parent**:
     1. `close(slave)` — parent never touches it again.
     2. Set `FD_CLOEXEC` on master (belt + suspenders vs. openpty
        implementations).
     3. Store `master_fd`, `child_pid` on `Terminal`.
     4. Register pid → `Terminal*` in the global pane registry
        (used by `SIGCHLD` handler).
5. Unblock SIGCHLD (restore the old mask captured in step 3).
6. Allocate SPSC ring (64 KB).
7. Create `eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC)` → `shutdown_fd`.
8. Spawn worker thread: `pthread_create(... worker_main, Terminal*)`.
9. Construct the pane's `GtkGLArea`. Defer GL setup to `realize`
   (see `gpu.md`).
10. Attach widget to the tab's pane tree.

No GL/GTK work happens on the worker thread. Ever.

## Window-size propagation

The child learns of terminal-size changes via `SIGWINCH`, raised
by the kernel when the master is `TIOCSWINSZ`'d.

Chain when the pane resizes:

1. `GtkGLArea.resize` signal (main thread) with new dimensions.
2. Compute `{cols, rows}` from logical widget size ÷ cell metrics.
3. Call `Screen.resize(cols, rows)` — reflows grid (see `images.md`
   for image placement translation).
4. `ioctl(master_fd, TIOCSWINSZ, &ws)` with `{ws_row=rows, ws_col=cols,
   ws_xpixel=phys_w, ws_ypixel=phys_h}`.
5. Kernel delivers `SIGWINCH` to the foreground process group of
   the pty.
6. Shells re-render prompts; ncurses apps re-layout.

sketerm itself does not install a `SIGWINCH` handler. We're a GUI
process; resize is a widget signal for us, not a tty signal.

## Worker thread main loop

Pseudocode (real module uses `std.posix` throughout):

```zig
fn workerMain(term: *Terminal) void {
    // Block SIGCHLD so only main thread handles it.
    var set = std.posix.empty_sigset;
    std.os.linux.sigaddset(&set, std.os.linux.SIG.CHLD);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &set, null);

    var pfds = [_]std.posix.pollfd{
        .{ .fd = term.master_fd,   .events = std.posix.POLL.IN, .revents = 0 },
        .{ .fd = term.shutdown_fd, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        _ = std.posix.poll(&pfds, -1) catch break;
        if (pfds[1].revents & std.posix.POLL.IN != 0) break;  // shutdown

        if (pfds[0].revents & std.posix.POLL.IN != 0) {
            var buf: [64 * 1024]u8 = undefined;
            const n = std.posix.read(term.master_fd, &buf) catch 0;
            if (n == 0) {
                // EOF (child closed). Push synthetic event.
                term.ring.push(.{ .child_eof = {} });
                scheduleMainDrain(term);
                break;
            }
            var any: bool = false;
            term.parser.advance(buf[0..n], &any);
            if (any) scheduleMainDrain(term);
        }

        if (pfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) break;
    }
}

fn scheduleMainDrain(term: *Terminal) void {
    // Coalesce across multiple batches: at most one invoke in flight.
    const was_pending = term.drain_pending.swap(true, .acq_rel);
    if (!was_pending) {
        _ = c.g_main_context_invoke(null, mainDrainEvents, @ptrCast(term));
    }
}
```

Cross-thread wakeup coalescing (`drain_pending` atomic) matches the
pattern described in `docs/architecture.md` § Cross-thread wakeup.
Without it, high-throughput output would queue thousands of
invoke sources per second.

## Pane teardown — clean (user closes)

Main thread:

1. `eventfd_write(shutdown_fd, 1)` — unblock worker's `poll()`.
2. `pthread_join(worker)`.
3. `close(master_fd)`. Child receives EOF on its stdin/stdout/stderr.
4. If child still alive after 500 ms: `kill(pid, SIGHUP)`, then
   after another 500 ms `SIGKILL`.
5. `waitpid(pid, &status, 0)` (or let SIGCHLD handler reap).
6. Remove pid from pane registry.
7. Drain any remaining events from ring into Screen (optional —
   mostly they'll be terminal goodbye).
8. Free ring buffer.
9. `gtk_widget_destroy` on the `GtkGLArea` — triggers `unrealize`
   which frees per-pane GL resources.
10. `close(shutdown_fd)`.
11. Free `Terminal` struct.

## Pane teardown — child exited first

Possible orderings:

### Child exits, worker still blocked on read()

- Kernel closes master-side read when child fully closes slave.
- Worker's next `read()` returns 0 → treated as EOF.
- Worker pushes `.child_eof` event, wakes main, exits loop.
- Main thread drains remaining events, displays
  `[process exited with status N]` overlay.
- Default: `hold-on-exit = true` — pane remains until user closes.

### SIGCHLD arrives before worker sees EOF

- Main thread `SIGCHLD` handler fires:

  ```
  while ((pid = waitpid(-1, &status, WNOHANG)) > 0) {
      term = pane_registry.find(pid);
      if (term) term.onChildExited(status);
  }
  ```

- `onChildExited` marks child dead, notes status on Terminal.
- Worker shortly after gets EOF; pushes `.child_eof`.
- Main consumes `.child_eof`, sees child already marked dead,
  renders overlay with known exit status.

Racy-but-correct: the two paths converge on the same state.

### Exotic: child hangs master fd but doesn't exit

- Worker's read returns EOF; child still running (detached).
- Worker exits.
- Main thread's pane close will SIGHUP/SIGKILL the pid as per
  clean teardown.

## SIGCHLD handler

Installed via `g_unix_signal_add`:

```zig
_ = c.g_unix_signal_add(c.SIGCHLD, onSigchld, null);

fn onSigchld(_: ?*anyopaque) callconv(.C) c.gboolean {
    while (true) {
        const r = std.posix.waitpid(-1, std.posix.W.NOHANG) catch break;
        if (r.pid == 0) break;  // no children ready
        pane_registry.onExit(r.pid, r.status);
    }
    return c.G_SOURCE_CONTINUE;
}
```

Runs on main thread (thread-safe glib API). Workers have SIGCHLD
blocked via `std.posix.sigprocmask`.

## Application signal handling

| Signal    | Handler                                     |
|-----------|---------------------------------------------|
| `SIGCHLD` | Reap zombies, notify panes (above)          |
| `SIGTERM` | Graceful: save `last.zon`, close panes, exit |
| `SIGHUP`  | Graceful: same as SIGTERM                   |
| `SIGINT`  | Ignored (GUI apps; Ctrl-C belongs in panes) |
| `SIGPIPE` | Ignored (we handle EPIPE explicitly)        |
| `SIGSEGV` / `SIGBUS` / `SIGILL` | No handler in v1; rely on core dump |

`SIGTERM`/`SIGHUP`/`SIGINT` wired via `g_unix_signal_add` — runs
on main thread, does not interrupt syscalls.

## Invariants

| Invariant                                                      | Enforced by                                        |
|----------------------------------------------------------------|----------------------------------------------------|
| Slave fd closed in parent before exec                          | Parent close sequence                              |
| Master fd has `FD_CLOEXEC`                                     | Explicit `fcntl(F_SETFD)` after `openpty`          |
| Worker thread joined before ring freed                         | `pthread_join` precedes `free(ring)` in teardown   |
| GL resources destroyed on main thread                          | `unrealize` signal handler                         |
| Child reaped exactly once                                      | SIGCHLD handler uses `WNOHANG` loop + registry     |
| No GTK call from worker                                        | Static discipline; only `g_main_context_invoke`    |
| SIGCHLD blocked in workers                                     | `std.posix.sigprocmask(BLOCK, …)` at worker entry  |
| `TIOCSWINSZ` after any cell-grid dim change                    | `Screen.resize` calls `pty.setSize` unconditionally|

## Application startup

1. `adw_init()` (wraps `gtk_init`).
2. Install `SIGTERM`/`SIGHUP`/`SIGCHLD`/`SIGINT` handlers.
3. Parse CLI args: `--layout`, `--restore`, `--command`, `--cwd`,
   `--save-on-exit`.
4. Create `AdwApplication` with unique app id `dev.sker.sketerm`.
5. Register app; enter `g_application_run`.
6. On `activate`:
   a. Create main `AdwApplicationWindow`.
   b. Build tabs/panes from layout source:
      - `--layout <file>`: parse, construct tree.
      - `--restore`: parse `$XDG_STATE_HOME/sketerm/last.zon`
        (default to single-pane if missing).
      - `--command` (or default): single pane running the command
        (default: `$SHELL`).
   c. Present window.

## Application shutdown

Triggered by last-window-closed, SIGTERM, SIGHUP, or explicit
`g_application_quit`.

1. Save `last.zon` via `layout.save()`.
2. For each window, for each pane: clean teardown.
3. Close `AdwApplication`.
4. Return exit code 0 (1 if layout save failed).

## Crash posture

- No custom signal handler for `SIGSEGV`/`SIGBUS`/`SIGILL` in v1.
- Kernel cleans up fds, memory, pty masters.
- Closing master side causes child to see EOF on stdin; most
  shells exit on read-EOF.
- Last clean layout save remains on disk; user restores with
  `--restore`.
- Post-v1: minimal `SA_SIGINFO` handler that writes a crash layout
  then re-raises for a proper core dump.

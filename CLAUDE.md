# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`sketerm` — native GTK4 terminal emulator written from scratch in Zig. No vendored terminal cores, no wrapper crates: parser/screen/atlas/render are all in-tree. Dependencies are system C libraries (`gtk4`, `libadwaita-1`, `freetype2`, `harfbuzz`, `epoxy`, `fribidi`, `fontconfig`, `libvpx` — VP9/WebM app-window recording, GUI-only) plus vendored `stb_image.h`/`stb_image_write.h`/`msf_gif.h` for image + GIF encode and a vendored Tree-sitter runtime + generated grammars (`vendor/tree-sitter/`, editor syntax highlighting — compiled into the GUI/test targets ONLY, never into `sketerm-mux`).

Two binaries ship: `sketerm` (the GUI, plus the `cli`/`ssh`/`mux` subcommands) and `sketerm-mux` (the session daemon — **links libc only**, no GTK/GLib/freetype; check with `ldd` after touching its dep graph).

## Toolchain pin

Zig **0.16**. The default optimize mode is `ReleaseFast` because **`Debug` builds fail to link on Arch + gcc 15** — Zig's bundled LLD can't handle gcc 15's `.sframe` section in `crt1.o`. `ReleaseSafe` currently fails in translate-c, so ReleaseFast is effectively the only mode.

`use_lld = true` is set on shipped Linux artifacts for the same reason: the self-hosted linker chokes on `crt1.o`'s SFrame relocs.

On x86_64 Linux, `zig build test` and `test-core` deliberately use Zig's
self-hosted x86 backend + linker instead of LLVM. The monolithic test roots
compile in seconds that way instead of minutes; shipped artifacts still use
LLVM. Use `-Dtest-llvm=true` only for production-codegen parity or a suspected
compiler-specific failure.

### Zig 0.16 std-library quirks (will cost you turns)

- `std.posix` has **no** socket/bind/listen/accept/connect/mkdir/unlink/fcntl/getenv. Use libc through `@import("c.zig").c` (or the `cbindings` module in non-GUI targets). `std.posix.errno(ret)` still works for errno decoding.
- `std.process.argsAlloc`/`argsWithAllocator` are gone: `pub fn main(init: std.process.Init.Minimal)` + `init.args.vector` (see `main.zig`, `mux_main.zig`).
- `std.time.milliTimestamp`, `std.crypto.random`, `std.meta.intToEnum` are gone. Use `c.clock_gettime(CLOCK_MONOTONIC)` (see `nowMs()` in `mux_main.zig`), `c.getentropy`, `std.enums.fromInt`.
- File IO via libc (`c.fopen`/`c.open`) — `std.fs.cwd()` is gone (see `config.zig`).
- `std.Thread` has **no `Mutex`/`Condition`** (they moved behind an `Io` instance). Cross-thread state uses the repo's atomic spinlock pattern; `src/ui/panel/events.zig` documents why. A condvar would need `pthread.h`, which is deliberately absent from `vendor/cimport_core.h` — adding it (musl-clean) is the right fix if a core-side module ever truly needs one, rather than more spinlocks.
- ArrayLists are unmanaged: `.empty`, `list.append(allocator, x)`.
- `std.Io.Writer.Allocating` for JSON stringify targets. `@abs(i64)` returns `u64`.
- `std.process.Child.run` is gone. Inside `build.zig` use `b.run` / `b.runAllowFail` (configure-time subprocesses, e.g. the git describe embed).
- `@cImport` goes through an out-of-process TranslateC step + sed fixup (Aro can't parse GTK headers in-process). Translated bindings land at `.zig-cache/o/*/cimport_root_fixed.zig` (GUI set) and `cimport_core_fixed.zig` (mux set) — **grep there to check whether a C symbol exists before using it**. New C headers go in `vendor/cimport_root.h`; headers the mux side needs ALSO go in `vendor/cimport_core.h`, which must stay translatable against musl (no GTK/glibc-only headers — `zig build mux-portable` is the check).

## Build / run / test

`zig build --help` lists every step with its own description — consult it
rather than a copy that drifts. Steps worth knowing exist for the GUI, the
`mux` / `mux-portable` daemons, the unit suites, the `smoke-*` end-to-end
rigs, the `bench-*` microbenchmarks, and `replay`:

```bash
zig build replay -- cap.bin [cols rows]  # raw PTY bytes -> Screen grid dump
```

Tests are discovered via `src/tests.zig`, which `_ = @import(...)`s every module containing `test` blocks. **When adding a new test file, add it to `src/tests.zig`** or `zig build test` won't pick it up.

`src/tests_core.zig` is the GTK-free subset behind `zig build test-core`, built with the same lean `configureCoreDeps` set as `sketerm-mux`. It exists because `zig build test` compiles the GUI, so on a host whose GTK predates what the GUI calls into (Ubuntu 22.04 ships 4.6 vs the 4.14 required) the whole suite — daemon logic included — is unrunnable. **A new core-side test file belongs in BOTH roots**; anything reaching `ui/`/`render/` belongs only in `tests.zig`, and putting it in `tests_core.zig` breaks the build for `mux-portable` users.

There's no `--test-filter` wired through `build.zig`; to run a single test, either invoke `zig test src/path/to/file.zig` directly with the same `linkSystemLibrary` flags, or add a temporary `b.option(...)` filter to the `tests` step.

### The `glib` build option

`build.zig` defines a bool `build_options.glib`. GUI targets get `true`; `sketerm-mux` and `smoke-mux` get `false` plus the lean `configureCoreDeps` dependency set (libc only). `src/pty.zig` gates its GLib write-queue watch and async child reaper on this option, falling back to blocking writes and `waitpid`. Anything imported by the mux side (`src/mux/*`, parser, grid) must stay free of GTK/GLib references.

## Architecture (read `docs/architecture.md` for full detail)

**Unified client-server: the GUI is always a mux client.** Every terminal — local OR remote — is a session owned by the `sketerm-mux` daemon; the GUI process owns no PTY and runs no parser/worker thread. `Terminal` is `initRemote` only: it watches the daemon socket via `g_unix_fd_add`, applies parsed EVENTS straight to `Screen`, and swaps the whole grid on a SNAPSHOT. Local tabs/splits are minted as GUI-owned (`Remote.ephemeral`) sessions on the auto-started per-user daemon (`Window.daemonSpawnPane` → `muxConnect(null)` = `connectLocalAutostart`); the daemon does the PTY read + parse in its single-threaded poll loop. Closing a tab kills its session (no leak); a GUI crash skips teardown so sessions survive for reattach (durability). **The old in-process path (per-pane worker thread + lock-free SPSC ring + `drain_pending` cross-thread wakeup + `mainDrain`) was removed** — don't reintroduce it.

**`DrainHandle` is the deferred-callback liveness fence.** It's allocated per `Terminal` and outlives it; `alive` lets any queued callback (async sink replies like the OSC 52 clipboard read, reconnect worker handbacks, idle kicks, retry timers) detect a pane/terminal teardown between queue and dispatch, and `terminal` is the fenced back-pointer those callbacks resolve through. The worker-era `drain_pending` field is gone along with the worker.

**Threading rule:** all GTK/GDK/GL/Screen/ImageStore *widget and render* state lives on the main thread, and terminal rendering has no worker — the daemon (separate process) does the off-thread parsing. Never block the GLib main loop on a socket read; the socket is non-blocking + watched. The one exception is short-lived **detached** workers for blocking IO that touches none of that state (panel transport setup, panel asset file reads, gdk-pixbuf decode — `src/ui/panelhost.zig`; a `GdkPixbuf` decode is a self-contained pixel-buffer operation, not widget/render state, and is explicitly allowed off-thread): they touch no GTK widget/render or Screen state, they hand back through `g_idle_add`, and ONLY the idle handback frees the job, so a cancelled worker can never race its own teardown. A worker that needs GTK is a bug, not a pattern to copy.

**`Cell` is `extern struct`, 8 bytes flat.** Heavy data (OSC 8 links, images, multi-codepoint clusters, styles) lives in side tables on `Screen` (`StylePool`, `links`, `clusters`, `cell_images`). `comptime` asserts pin the size at 8.

**Pane vs TerminalSurface.** `src/ui/pane.zig` is the interactive workspace cell (input, menus, faces, Window sinks, split-tree participation); the terminal RENDERER — GtkGLArea + GL lifecycle, GridPass/CellPass/ImagePass/BgPass/shader/linear-light passes, ImageStore, cursor-blink/trail/bell/tick visual timers — is `TerminalSurface` in `src/ui/terminal_surface.zig`, composed by value inside Pane (`pane.surface`) and usable without Pane (cast-playback viewer). The surface owns the presentation-geometry policy `TerminalSurface.Geometry`: `live_terminal` (allocation drives the grid + resize propagation; what panes use) vs `fixed_grid` (letterboxed fixed cols x rows, never propagates geometry). What the surface's tick/resize notice but only the session owner can act on (child exit, IME caret placement, grid COUNT changes) goes out through its `host_ctx`/`on_child_exit`/`on_before_redraw`/`on_grid_geometry` hooks.

**One `GtkGLArea` per pane; share-group at the window level.** Atlas lives on `Window`, reachable from every pane's GL context. **Reparenting unrealizes the `GtkGLArea` and destroys its `GdkGLContext`** — `TerminalSurface`'s realize handler (`terminal_surface.zig onRealize`) therefore treats every realize as potentially a re-realize: `Atlas.deinit`, then `forgetGL()` on `GridPass`/`ImagePass`/`ImageStore`/`BgPass` so the realize path rebuilds against the fresh context. Without this, cached non-zero shader IDs from a dead context cause silent black renders.

**Renderer invariants.** After ANY atlas rebuild/swap, call `surface.onAtlasRebuilt()` — the single method that does `cell_pass.markAllDirty()` plus the GridPass `vbuf_valid`/`vbo_uploaded`/`row_caches_valid` resets (generation counters reset to 0 and won't trip eviction detection); never hand-copy that list again. GridPass `Snapshot` must gain a hash/field for any new Screen-side overlay state (hints, copy cursor, …) or the vbuf won't rebuild. Emoji/CJK rows render via CellPass, not GridPass — `rowNeedsBidiOrComplexShape` only routes RTL/complex scripts to the overlay; glyph-rendering changes must hit BOTH shader pairs.

**Shaders carry NO `#version`/`precision` lines.** `gl.zig compileShader` injects a per-API header (`300 es` on Linux/GLES, `330 core` on macOS desktop GL) — adding a version line to a shader source breaks one of the two platforms. `zig build smoke-gl-core` compiles every shader under desktop GL 3.3 core (the macOS path) via Mesa. Never call `gtk_gl_area_set_use_es` directly; use `gl.requestArea` + `gl.adoptAreaApi`.

**Platform layer.** Linux-vs-macOS primitives live ONLY in `src/util/platform.zig` (exe path, eventfd-vs-pipe wakeup, runtime dir, cloexec sockets), keyed on comptime `builtin.os.tag`. OS-specific headers are `#ifdef __linux__`-gated in `vendor/cimport_*.h`. `zig build mux-portable -Dportable-target=aarch64-macos` is the cross-compile check — keep it green. See `docs/macos.md`. **A green macOS build is not a working macOS build**: the 2026-08 re-verification found five bugs that all compiled fine and then failed at runtime (no session could spawn, no file could transfer) — run the smoke rigs, not just the compiler.

**Tab/pane tree is plain Zig data; GTK widgets are the view.** The model is `src/ui/tree.zig` (`Window.PaneTree`), one per tab, attached to the AdwTabPage as qdata (`sketerm-tree`) so it travels with cross-window tab drags. **Every widget-tree mutation (split / pane close / mux takeover / restore-build) must update the model in the same function** — `splitLeaf`/`removeLeaf`/`replaceLeaf`. Queries (`tabPageForPane`, layout collection, duplicate-tab) read the model, which stays correct while a pane is zoomed (zoom only reparents widgets). `SKETERM_VERIFY_TREE=1` cross-checks model vs widgets after each mutation and aborts on divergence — smoke-e2e runs with it set. Layout persistence (`layout.zig`) serializes the model to JSON; widgets+model rebuild from the tree on load. Saved at shutdown to `$XDG_STATE_HOME/sketerm/last.json`; restored via `--restore` or `--layout <path>`. This is step 1 of de-GTK-ing `src/ui` (goal: a future native AppKit frontend reusing core + model).

**CSI handling is split.** `Screen.csi()` is a small dispatcher that routes by `params.private` to `csiPrivate` (`?`), `csiAux` (`>`), `csiKittyKbd` (`=`/`<`), or `csiPublic`. Don't fold logic back into one giant function. CSI params are u16; `Event.Csi` carries colon sub-params via `setSub(idx)`/`isSub`.

**Helpers worth knowing.** `cast.userData(T, user)` in `src/util/cast.zig` collapses `@ptrCast(@alignCast(user.?))` for GTK callbacks. `style.colorToVec` / `style.colorToRGBA` in `src/render/style.zig` are the shared color-resolution path used by both `cell_pass` and `grid_pass` — don't copy that logic into a third place.

## Subsystem guidance (loaded on demand)

Three subsystems carry enough hard-won detail that keeping all of it in this
always-loaded file made up three quarters of its size. Each now lives in a
nested `CLAUDE.md` that loads when you work in that directory. **Read that file
before changing the subsystem** — and the invariants below hold whether or not
it is loaded, because breaking one is how each was learned:

- **`src/ipc/CLAUDE.md`** — remote control, the MCP server, appdrive/termdrive,
  browser automation (CDP).
  - MCP responses must stay newline-free (NDJSON framing).
  - Every appdrive/termdrive connection runs NON-BLOCKING with deadline recvs;
    plain blocking `recvFrame`/`recvExpect` must NOT be reintroduced on MCP paths.
  - Never always-stream native frames toward MCP clients — the backlog cap is
    what stopped screenshots lagging whole screens on busy apps.
  - Socket discovery in `resolveSocket` must skip `mux.sock`.

- **`src/mux/CLAUDE.md`** — the session daemon, wire protocol, transports,
  Wayland app forwarding, audio, external displays.
  - The wire protocol carries **parsed events, never re-encoded escape
    sequences**; FrameType/EventTag bytes are append-only.
  - `sketerm-mux` links **libc only** — never hard-link GTK/GLib/freetype,
    EGL/GLES/libdrm, gdk-pixbuf or libopus into it. `ldd` after touching its
    dep graph; `zig build mux-portable` is the musl check.
  - Nothing in `src/ui` touches `terminal.pty`. Remote terminals have
    `child_pid = -1`; `Terminal.reapStatus`'s `child_pid <= 0` guard must stay
    or the exit poller reaps arbitrary GUI children.
  - Any process hosting a `Daemon` must answer `--keep` (display keepers are
    spawned as the daemon's own `/proc/self/exe`).
  - The broker↔worker control channel is `platform.controlSocketpair`, NOT a
    raw `socketpair` — Darwin has no AF_UNIX SEQPACKET at all, and its
    datagram size cap is a socket-buffer setting. A closed peer there is
    `recv() == -1`/ECONNRESET, so "channel gone" is `n <= 0`, never `n == 0`.

- **`src/ui/browser/CLAUDE.md`** (+ pointer in `src/filebrowser/`) — the file
  browser.
  - The GUI never touches the disk: every file op goes to the daemon.
  - `renderList` splices a WINDOW, not the whole store; a full renderList per
    delta is the storm that ate clicks and flickered hover for minutes.
  - Content mutations outside the delta path MUST call `tab.noteChangedFull`,
    or rows show stale cells.

- **`src/lsp/CLAUDE.md`** (+ `docs/lsp.md` for the full reference) — the
  editor's Language Server Protocol client.
  - Everything under `src/lsp/` is GTK-free and in BOTH test roots; the only
    GTK is `src/ui/editorlsp.zig`. `config.zig` imports `lsp/servers.zig` and
    `config.zig` is compiled into `sketerm-mux`.
  - LSP `character` is UTF-16 code units by default — never index a rope with
    one; go through `lsp/position.zig`.
  - `didChange` ranges are captured in `Document` observer slot 2 (PRE-edit)
    and queued DESCENDING by offset.
  - Responses are revision-stamped and dropped when stale; a missing server
    degrades silently.

## Memory ownership

- All long-lived state via the app `GeneralPurposeAllocator`.
- Per-worker `ArenaAllocator` reset once per ring drain for transient parse payloads.
- **A struct that keeps a raw `GtkWidget*` past the widget tree's lifetime must OWN a reference to it.** `ui/imhost.zig` is the worked example: `gtk_im_context_set_client_widget(NULL)` on a multicontext walks the OLD client widget, and GTK's Wayland IM module `g_set_object`s that widget — so the IM often holds its LAST reference and the widget's `::destroy` (the hook a face would sever from) cannot fire until the IM lets go. Every "sever it early enough" rule there was therefore unkeepable; ImHost refs its client widget in `attach` and unrefs at the END of `detach` instead, so a detach from ANY teardown path — pane close, standalone editor window finalize, `wlapp` window teardown — is safe. Do not re-add an ordering rule to replace it.
- **`Pane.severFaces()` is the single pre-teardown entry point**: IM + browser + editor + app-embed, all idempotent, called by every path that is about to destroy a pane's widgets (`Window.unlistPane`, `closePane`, `swapPaneInPlace`, the tab-close sweep) and once more as a last resort from `Pane.deinit`. It replaced four hand-copied `detachIm(); detachBrowser();` lists that the editor face was never added to. Add a new face to `severFaces`, never to the call sites. A face's prepare-destroy is handed the pane's `widgets_dead` so the last-resort call cannot touch finalized widgets.
- **Three mechanisms stop a callback firing into freed user-data. Pick exactly ONE per allocation; they are not layers.** `g_signal_connect_object` is unavailable here (user-data is a Zig struct, not a GObject), so the question "does my data outlive this widget's callbacks?" has to be answered by hand every time. It has three answers:
  1. **The widget owns the data** — a `GDestroyNotify` as `g_signal_connect_data`'s 5th arg, or `g_object_set_data_full`. Correct *by construction*, so **prefer it whenever the data's lifetime may legitimately end with the widget**: GObject frees attached data at finalize, strictly after `::destroy` has been emitted from dispose, so no handler can run against freed memory and nobody has to remember anything. `menu.zig`/`prefs.zig` (notify), `panelwin.zig`/`browser/menu.zig`/`viewer.zig` (qdata) are the worked examples.
  2. **Disconnect at teardown** (`g_signal_handlers_disconnect_matched` with `G_SIGNAL_MATCH_DATA`) — for data that must OUTLIVE the widget or is shared by several widgets. Correct but *conditional*: it holds only if EVERY teardown path reaches the disconnect, so use it only where a single choke point guarantees that (the `severFaces` shape, `Pane.deinit`, a face's own `deinit`). `panel/view.zig`, `imhost.zig`, `remotectl.zig`, `configwatch.zig`. Owning a reference to the widget is NOT a substitute: our ref need not be the last one, so the widget's `::destroy` can still fire frames after we are freed.
  3. **A liveness fence** — for callbacks that are not widget-attached at all and so have no widget to hang ownership on: idle callbacks, timers, async socket replies, cross-thread handbacks. `DrainHandle` exists for exactly this. The nullable back-pointer variant (`CompCtx.view`, severed by `PanelView.deinit`) is the same idea for a context that must survive its owner.
- **Do not combine 1 and 2 — that combination is worse than either alone.** A `GDestroyNotify` on a signal connection runs when the CLOSURE is destroyed, and an explicit disconnect destroys the closure: the disconnect *is* the free. Any code that expected the data to survive the disconnect then has a use-after-free. (Qdata-at-finalize plus a disconnect is safely combinable, because there the free is tied to the object's finalize, not to the closure — `panelwin.zig` relies on that ordering.) Where one context is user-data for several connections, exactly one owner: `panel/view.zig`'s `Compare` is owned by its qdata notify and *borrowed*, notify-free, by its four gesture controllers.
- **`src/ui/panel/canary.zig` is a DETECTOR, not a fourth mechanism.** Panel heap contexts carry a `magic: u32`, poisoned at free; every callback resolves user-data through `canary.live(T, user)` and bails on a mismatch. It cannot make a wrong lifetime right — it converts an undebuggable random crash into an immediate, obvious one at the first stale callback. The check must stay an explicit branch: this project builds ReleaseFast only, where `std.debug.assert` compiles away.
- GTK signal contexts allocated on the heap (`*Ctx` types) **must** carry their own `allocator: std.mem.Allocator` and pass a matching `freeXxxCtx` callback as `g_signal_connect_data`'s 5th arg. The pattern is in `menu.zig` (`freeActionSlot`, `freeClickCtx`), `window.zig` (`PanedRatioCtx`/`freePanedRatio`, `RenameCtx`/`freeRenameCtx`), and every `add*Row` builder in `prefs.zig`. Skip the destroy-notify only when the user-data is the dialog's main `Ctx` (managed elsewhere) or is a non-heap pointer.
- Config lives in an arena: `applyConfigChange` clones into a fresh arena and frees the old one — anything holding config-arena slices (pane `font_path`, `active_profile`, `font_family`, …) must be re-pointed in that loop.
- **Pane-level settings are `ProfileSettings` bundles.** `Config.settings` IS the Default profile; `[profile.<name>]` sections are COMPLETE copies (seeded from Default at parse time — no inherit sentinels). Resolve a pane's bundle with `Config.profileSettings(name)` (empty/"default"/unknown → Default); never write field-by-field profile-vs-global fallbacks. App-level keys (window, mouse, keybinds, rendering flags, bells, background image/opacity) stay flat on `Config`.

## Debugging tips

- **Daemon log**: every daemon writes lifecycle + warnings to `$XDG_STATE_HOME/sketerm/mux.log` (all instances share it; `[pid]` attributes lines; rotated at 2MB to `.old`). `SKETERM_MUX_LOG=debug` adds wlhost tracing — pool mirror lifecycle (mapped/orphaned/reclaimed with incarnation serials) and commit pixel-path TRANSITIONS ("commit resolves NO mirror" is the silent-black-window failure class). `=off` disables the file, `=<path>` logs there at debug level. Warnings always also hit stderr. Module: `src/mux/log.zig` (libc-only, no allocator).
- `zig build replay -- capture.bin [cols rows]` replays raw PTY bytes through parser→Screen and dumps the grid — invaluable for "app X renders wrong" reports. Capture with a small `pty.fork` tee script.
- **Headless GUI testing: sketerm is its own display. NEVER Xvfb, never `GDK_BACKEND=x11`, never xdotool.** X11 changes the code under test: `GtkIMMulticontext` resolves to `GtkIMContextSimple` there, so IM/dead-key behaviour under Xvfb is not the behaviour on any Wayland compositor advertising `zwp_text_input_manager_v3` — an Xvfb run of smoke-e2e went green while dead keys were broken everywhere real. Any input- or compositor-related result from an X session is untrustworthy. The replacement is an external display session: `sketerm-mux display create --name <n> --ttl <secs> --json --socket <isolated mux.sock>` returns `{session, environment:{WAYLAND_DISPLAY, XDG_RUNTIME_DIR, PULSE_SERVER, LIBGL_ALWAYS_SOFTWARE}}` — export that to the GUI (**never derive `wl-*` paths yourself**), set `GDK_BACKEND=wayland` and unset `DISPLAY`. **Attach a viewer BEFORE starting the GUI**: the compositor brain is client-side, so an unattended hub never configures the toplevel it is handed and nothing ever paints. `src/smoke_e2e.zig` is the worked example (private daemon → display create → `appdrive.App.attachExisting` → GUI child → `waitFirstWindow`); the same `appdrive` API gives clicks/keys/screenshots/pixel diffs from Zig, and `sketerm mcp`'s app tools give them interactively. Destroy the session by name and kill pids exactly; `--ttl` is the orphan backstop. ALWAYS isolate `XDG_CONFIG_HOME`/`XDG_STATE_HOME` (prefs auto-saves would clobber the real config.conf) and set `SKETERM_APP_ID` so GApplication uniqueness doesn't reuse a live instance.
- **Dead keys ARE covered end to end** (`deadKeyStage` in `src/smoke_e2e.zig`). Two things make it possible: `sketerm-mux display create --kb-layout <name>` picks the session keymap (us/gb/fr/be/de), and `appdrive.App.tapKeyCodes` injects raw evdev HARDWARE keycodes on the seat. Use `tapKeyCodes` for anything with no codepoint of its own — `typeText`/`pressKey` go through `src/ipc/xkblayout.zig`, which maps CHARACTERS and skips every dead keysym, so `^` is untypable through them; evdev codes are keymap-independent and the session keymap does the rest (BE: 26 = `dead_circumflex`, 18 = `e`, i.e. xkb `<AD11>`/`<AD03>` minus the constant 8). The stage runs a SECOND display session (a session's keymap is fixed at creation) and a SECOND GUI instance, the latter deliberately WITHOUT `GTK_IM_MODULE=wayland`: that variable is what puts the main instance's editor face on a GtkIMMulticontext, and on Wayland a multicontext resolves to GTK's `wayland` IM module, which has no compose engine (see `src/ui/imhost.zig`). Composing is `GtkIMContextSimple`'s job. So the two instances test different halves and neither is redundant — the main one proves the IME/text-input-v3 path exists, the Belgian one proves `^`+`e` -> `ê` in both the terminal pane and an editor tab. Do not re-add an X path to "cover" any of this — X would test a different IM implementation.
- **Isolated test daemons: keep the socket path SHORT.** `sockaddr_un` caps at ~108 bytes; a daemon under a deep scratchpad path fails to bind (`BadPath`) and the GUI then silently autostarts the INSTALLED daemon instead. Use something like `/tmp/<short>/sketerm/mux.sock`.
- A `zig build test` run can fail spuriously in the OCR (tesseract) tests with leak warnings; rerun once before diagnosing.
- A detached daemon that re-exec'd via `/proc/self/exe` has comm **"exe"**, so `pgrep -x sketerm-mux` MISSES it — a stale test daemon can silently keep serving an old binary on its socket (this cost an hour once: new code everywhere, old behavior persisting). When hunting rig leftovers, also scan `pgrep -x exe` and match `/proc/<pid>/environ` against the isolated dir.
- **NEVER `pkill`/`killall`/`pgrep -f` on ANY "sketerm" name, including `pkill -x sketerm-mux`.** A by-name kill destroys the USER's real daemon and durable sessions (their running work), not just isolated test instances. There is no safe `pkill` here. Clean up a test instance by exact PID only: launch it under an isolated `XDG_RUNTIME_DIR`, capture the GUI pid at launch and kill just that; for its daemon, list read-only with `pgrep -x sketerm-mux` and kill ONLY the pid whose `/proc/<pid>/environ` contains YOUR isolated `XDG_RUNTIME_DIR=`. When unsure, leave the isolated process running rather than risk a broad kill.

## Commit style

Gitmoji + scope + short subject (≤70 chars), then a 2-3 line body explaining why. Examples from `git log`:
```
🐛 prefs: free row-builder signal contexts via GDestroyNotify
♻️ render: extract shared color resolution into style.zig
✨ goto_tab_1..9 actions (Alt+1..9)
📝 SESSION: log goto_tab_1..9
```
`🐛` bug fix · `✨` feature · `♻️` refactor · `✅` tests · `📝` docs/SESSION

`docs/SESSION.md` is a running log of what's landed; many `📝 SESSION:` commits update it after a feature commit. Keep that pattern when adding sizable features.

Design documents are never committed — proposals stay untracked in the working tree.

## Packaging

`dist/PKGBUILD` builds the locally-checked-out repo (no remote source) and packages both binaries. Run `cd dist && ./install.sh` (= `makepkg -sif`). **Plain `makepkg -si` is a trap**: `pkgver()` derives from HEAD and uncommitted changes do not move it, so rebuilding the same commit hits "A package has already been built", exits 13, and installs NOTHING while leaving the old binary in place. There is no `check()`: installing is not the time to run the suite. makepkg rewrites the `pkgver=` line on every build; a **clean filter keeps that out of git** so it no longer shows as a permanent local edit (which made `git pull` complain). `.gitattributes` marks `dist/PKGBUILD filter=pkgver`, and the driver lives in local git config — **a fresh clone must set it up or the dirt comes back**:

```bash
git config filter.pkgver.clean  "sed -E 's/^pkgver=.*/pkgver=0.0.0/'"
git config filter.pkgver.smudge cat
```

The stored `pkgver=0.0.0` is a deliberate placeholder: `pkgver()` derives the real version from `build.zig.zon` at build time, so the committed value is never read for anything. The filter masks ONLY that one assignment line — every other edit to PKGBUILD still diffs normally, and a clone without the driver configured degrades gracefully (git no-ops on an undefined filter).

**The semver has exactly one source of truth: `.version` in `build.zig.zon`.** `build.zig` imports the zon and hands the string to every target as `build_options.version`; `src/version.zig` re-exports it (with the `:0` sentinel re-attached, since callers pass it to `fprintf`) for the GUI, the daemon and the MCP server, which is how `sketerm doctor` detects binary skew. `pkgver()` greps the same line and appends `.r<commit-count>.g<sha>`. Bump that one line and everything moves together — never hardcode a version anywhere else. Consequence: **any module importing `src/version.zig` must be in a target that has a `build_options` module**, and a new option set (alongside `glib_opts`/`noglib_opts`/`portable_opts`) must add `version` or that target won't compile.

Two desktop entries and two app icons ship, because **files mode is its own application identity**: `sketerm files` registers the GApplication id `dev.sker.sketerm.files` and sets the matching prgname, so on Wayland the toplevel app_id and on X11 the WM_CLASS are that string and KDE gives the file manager its own taskbar entry and icon (a per-window `gtk_window_set_icon_name` cannot do this). `data/dev.sker.sketerm.desktop` + `apps/dev.sker.sketerm.svg` are the terminal; `data/dev.sker.sketerm.files.desktop` + `apps/dev.sker.sketerm.files.svg` are the file manager, and the latter declares `MimeType=inode/directory;x-scheme-handler/file;` so it can be set as the default file manager. `StartupWMClass` in that entry MUST stay equal to the app id. This is additive: a browser face on a pane inside a terminal window (palette `new_browser_tab`/`new_browser_split`, `cli new-browser-tab`, `sketerm files --here|--tab`) is unrelated to the files identity and must keep working. Terminfo source at `terminfo/sketerm-256color.src` — `tic`-compiled into `/usr/share/terminfo` by the PKGBUILD.

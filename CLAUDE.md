# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`sketerm` — native GTK4 terminal emulator written from scratch in Zig. No vendored terminal cores, no wrapper crates: parser/screen/atlas/render are all in-tree. Dependencies are system C libraries (`gtk4`, `libadwaita-1`, `freetype2`, `harfbuzz`, `epoxy`, `fribidi`, `fontconfig`, `libvpx` — VP9/WebM app-window recording, GUI-only) plus vendored `stb_image.h`/`stb_image_write.h`/`msf_gif.h` for image + GIF encode and a vendored Tree-sitter runtime + generated grammars (`vendor/tree-sitter/`, editor syntax highlighting — compiled into the GUI/test targets ONLY, never into `sketerm-mux`).

Two binaries ship: `sketerm` (the GUI, plus the `cli`/`ssh`/`mux` subcommands) and `sketerm-mux` (the session daemon — **links libc only**, no GTK/GLib/freetype; check with `ldd` after touching its dep graph).

## Toolchain pin

Zig **0.16**. The default optimize mode is `ReleaseFast` because **`Debug` builds fail to link on Arch + gcc 15** — Zig's bundled LLD can't handle gcc 15's `.sframe` section in `crt1.o`. `ReleaseSafe` currently fails in translate-c, so ReleaseFast is effectively the only mode.

`use_lld = true` is set on every artifact for the same reason: the self-hosted linker chokes on `crt1.o`'s SFrame relocs.

### Zig 0.16 std-library quirks (will cost you turns)

- `std.posix` has **no** socket/bind/listen/accept/connect/mkdir/unlink/fcntl/getenv. Use libc through `@import("c.zig").c` (or the `cbindings` module in non-GUI targets). `std.posix.errno(ret)` still works for errno decoding.
- `std.process.argsAlloc`/`argsWithAllocator` are gone: `pub fn main(init: std.process.Init.Minimal)` + `init.args.vector` (see `main.zig`, `mux_main.zig`).
- `std.time.milliTimestamp`, `std.crypto.random`, `std.meta.intToEnum` are gone. Use `c.clock_gettime(CLOCK_MONOTONIC)` (see `nowMs()` in `mux_main.zig`), `c.getentropy`, `std.enums.fromInt`.
- File IO via libc (`c.fopen`/`c.open`) — `std.fs.cwd()` is gone (see `config.zig`).
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

**Threading rule:** all GTK/GDK/GL/Screen/ImageStore state lives on the main thread — the GUI is single-threaded (no worker). The daemon (separate process) does the off-thread parsing. Never block the GLib main loop on a socket read; the socket is non-blocking + watched.

**`Cell` is `extern struct`, 8 bytes flat.** Heavy data (OSC 8 links, images, multi-codepoint clusters, styles) lives in side tables on `Screen` (`StylePool`, `links`, `clusters`, `cell_images`). `comptime` asserts pin the size at 8.

**One `GtkGLArea` per pane; share-group at the window level.** Atlas lives on `Window`, reachable from every pane's GL context. **Reparenting unrealizes the `GtkGLArea` and destroys its `GdkGLContext`** — `Pane.onRealize` therefore treats every realize as potentially a re-realize: `Atlas.deinit`, then `forgetGL()` on `GridPass`/`ImagePass`/`ImageStore`/`BgPass` so the realize path rebuilds against the fresh context. Without this, cached non-zero shader IDs from a dead context cause silent black renders.

**Renderer invariants.** After ANY atlas rebuild/swap, call `cell_pass.markAllDirty()` and reset GridPass `vbuf_valid`/`vbo_uploaded`/`row_caches_valid` (generation counters reset to 0 and won't trip eviction detection). GridPass `Snapshot` must gain a hash/field for any new Screen-side overlay state (hints, copy cursor, …) or the vbuf won't rebuild. Emoji/CJK rows render via CellPass, not GridPass — `rowNeedsBidiOrComplexShape` only routes RTL/complex scripts to the overlay; glyph-rendering changes must hit BOTH shader pairs.

**Shaders carry NO `#version`/`precision` lines.** `gl.zig compileShader` injects a per-API header (`300 es` on Linux/GLES, `330 core` on macOS desktop GL) — adding a version line to a shader source breaks one of the two platforms. `zig build smoke-gl-core` compiles every shader under desktop GL 3.3 core (the macOS path) via Mesa. Never call `gtk_gl_area_set_use_es` directly; use `gl.requestArea` + `gl.adoptAreaApi`.

**Platform layer.** Linux-vs-macOS primitives live ONLY in `src/util/platform.zig` (exe path, eventfd-vs-pipe wakeup, runtime dir, cloexec sockets), keyed on comptime `builtin.os.tag`. OS-specific headers are `#ifdef __linux__`-gated in `vendor/cimport_*.h`. `zig build mux-portable -Dportable-target=aarch64-macos` is the cross-compile check — keep it green. See `docs/macos.md`.

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

- **`src/ui/browser/CLAUDE.md`** (+ pointer in `src/filebrowser/`) — the file
  browser.
  - The GUI never touches the disk: every file op goes to the daemon.
  - `renderList` splices a WINDOW, not the whole store; a full renderList per
    delta is the storm that ate clicks and flickered hover for minutes.
  - Content mutations outside the delta path MUST call `tab.noteChangedFull`,
    or rows show stale cells.

## Memory ownership

- All long-lived state via the app `GeneralPurposeAllocator`.
- Per-worker `ArenaAllocator` reset once per ring drain for transient parse payloads.
- GTK signal contexts allocated on the heap (`*Ctx` types) **must** carry their own `allocator: std.mem.Allocator` and pass a matching `freeXxxCtx` callback as `g_signal_connect_data`'s 5th arg. The pattern is in `menu.zig` (`freeActionSlot`, `freeClickCtx`), `window.zig` (`PanedRatioCtx`/`freePanedRatio`, `RenameCtx`/`freeRenameCtx`), and every `add*Row` builder in `prefs.zig`. Skip the destroy-notify only when the user-data is the dialog's main `Ctx` (managed elsewhere) or is a non-heap pointer.
- Config lives in an arena: `applyConfigChange` clones into a fresh arena and frees the old one — anything holding config-arena slices (pane `font_path`, `active_profile`, `font_family`, …) must be re-pointed in that loop.
- **Pane-level settings are `ProfileSettings` bundles.** `Config.settings` IS the Default profile; `[profile.<name>]` sections are COMPLETE copies (seeded from Default at parse time — no inherit sentinels). Resolve a pane's bundle with `Config.profileSettings(name)` (empty/"default"/unknown → Default); never write field-by-field profile-vs-global fallbacks. App-level keys (window, mouse, keybinds, rendering flags, bells, background image/opacity) stay flat on `Config`.

## Debugging tips

- **Daemon log**: every daemon writes lifecycle + warnings to `$XDG_STATE_HOME/sketerm/mux.log` (all instances share it; `[pid]` attributes lines; rotated at 2MB to `.old`). `SKETERM_MUX_LOG=debug` adds wlhost tracing — pool mirror lifecycle (mapped/orphaned/reclaimed with incarnation serials) and commit pixel-path TRANSITIONS ("commit resolves NO mirror" is the silent-black-window failure class). `=off` disables the file, `=<path>` logs there at debug level. Warnings always also hit stderr. Module: `src/mux/log.zig` (libc-only, no allocator).
- `zig build replay -- capture.bin [cols rows]` replays raw PTY bytes through parser→Screen and dumps the grid — invaluable for "app X renders wrong" reports. Capture with a small `pty.fork` tee script.
- **Headless GUI testing: sketerm is its own display. NEVER Xvfb, never `GDK_BACKEND=x11`, never xdotool.** X11 changes the code under test: `GtkIMMulticontext` resolves to `GtkIMContextSimple` there, so IM/dead-key behaviour under Xvfb is not the behaviour on any Wayland compositor advertising `zwp_text_input_manager_v3` — an Xvfb run of smoke-e2e went green while dead keys were broken everywhere real. Any input- or compositor-related result from an X session is untrustworthy. The replacement is an external display session: `sketerm-mux display create --name <n> --ttl <secs> --json --socket <isolated mux.sock>` returns `{session, environment:{WAYLAND_DISPLAY, XDG_RUNTIME_DIR, PULSE_SERVER, LIBGL_ALWAYS_SOFTWARE}}` — export that to the GUI (**never derive `wl-*` paths yourself**), set `GDK_BACKEND=wayland` and unset `DISPLAY`. **Attach a viewer BEFORE starting the GUI**: the compositor brain is client-side, so an unattended hub never configures the toplevel it is handed and nothing ever paints. `src/smoke_e2e.zig` is the worked example (private daemon → display create → `appdrive.App.attachExisting` → GUI child → `waitFirstWindow`); the same `appdrive` API gives clicks/keys/screenshots/pixel diffs from Zig, and `sketerm mcp`'s app tools give them interactively. Destroy the session by name and kill pids exactly; `--ttl` is the orphan backstop. ALWAYS isolate `XDG_CONFIG_HOME`/`XDG_STATE_HOME` (prefs auto-saves would clobber the real config.conf) and set `SKETERM_APP_ID` so GApplication uniqueness doesn't reuse a live instance.
- **Gap, stated honestly**: dead keysyms cannot be injected through this path — `src/ipc/xkblayout.zig` maps codepoints, and a display session's keymap is always `us` (`display create` exposes no `kb_layout`). Dead-key/compose behaviour is covered by unit tests driving `gtk_im_context_filter_key` with hardware keycodes (`src/ui/imhost.zig`), not by smoke-e2e. Do not re-add an X path to "cover" it — X would test a different IM implementation.
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

`dist/PKGBUILD` builds the locally-checked-out repo (no remote source) and packages both binaries. Run `cd dist && ./install.sh` (= `makepkg -sif`). **Plain `makepkg -si` is a trap**: `pkgver()` derives from HEAD and uncommitted changes do not move it, so rebuilding the same commit hits "A package has already been built", exits 13, and installs NOTHING while leaving the old binary in place. There is no `check()`: installing is not the time to run the suite. The perpetually dirty `pkgver=` line in `git status` is makepkg's own rewrite, not a local edit.

Two desktop entries and two app icons ship, because **files mode is its own application identity**: `sketerm files` registers the GApplication id `dev.sker.sketerm.files` and sets the matching prgname, so on Wayland the toplevel app_id and on X11 the WM_CLASS are that string and KDE gives the file manager its own taskbar entry and icon (a per-window `gtk_window_set_icon_name` cannot do this). `data/dev.sker.sketerm.desktop` + `apps/dev.sker.sketerm.svg` are the terminal; `data/dev.sker.sketerm.files.desktop` + `apps/dev.sker.sketerm.files.svg` are the file manager, and the latter declares `MimeType=inode/directory;x-scheme-handler/file;` so it can be set as the default file manager. `StartupWMClass` in that entry MUST stay equal to the app id. This is additive: a browser face on a pane inside a terminal window (palette `new_browser_tab`/`new_browser_split`, `cli new-browser-tab`, `sketerm files --here|--tab`) is unrelated to the files identity and must keep working. Terminfo source at `terminfo/sketerm-256color.src` — `tic`-compiled into `/usr/share/terminfo` by the PKGBUILD.

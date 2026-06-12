# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`sketerm` — native GTK4 terminal emulator written from scratch in Zig. No vendored terminal cores, no wrapper crates: parser/screen/atlas/render are all in-tree. Dependencies are system C libraries (`gtk4`, `libadwaita-1`, `freetype2`, `harfbuzz`, `epoxy`, `fribidi`, `fontconfig`) plus vendored `stb_image.h` for PNG/JPEG decode.

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
- `@cImport` goes through an out-of-process TranslateC step + sed fixup (Aro can't parse GTK headers in-process). Translated bindings land at `.zig-cache/o/*/cimport_root_fixed.zig` (GUI set) and `cimport_core_fixed.zig` (mux set) — **grep there to check whether a C symbol exists before using it**. New C headers go in `vendor/cimport_root.h`; headers the mux side needs ALSO go in `vendor/cimport_core.h`, which must stay translatable against musl (no GTK/glibc-only headers — `zig build mux-portable` is the check).

## Build / run / test

```bash
zig build                       # GUI binary at zig-out/bin/sketerm
zig build run -- [args]         # build + run with optional CLI args
zig build mux                   # sketerm-mux session daemon (libc-only)
zig build mux-portable          # static-musl baseline-CPU daemon for scp-to-server
zig build test                  # full test suite (currently 454 tests)
zig build test --summary all    # show test count + timings
zig build smoke-mux             # mux daemon end-to-end smoke (headless)
zig build smoke-e2e             # drives the real GUI via the IPC socket (needs display)
zig build replay -- cap.bin [cols rows]  # replay raw PTY bytes → Screen grid dump
zig build spike-gl              # GL share-group + driver-info spike
zig build spike-shell           # headless PTY → parser → screen smoke
zig build bench-parser          # parser microbenchmark
zig build bench-cell-upload     # cell-upload microbench (GL without GTK)
zig build smoke-image           # headless GL image render
zig build smoke-cell            # headless GL cell-pipeline render (both passes + emoji)
zig build smoke-transparency    # headless GL bg-alpha render
```

Tests are discovered via `src/tests.zig`, which `_ = @import(...)`s every module containing `test` blocks. **When adding a new test file, add it to `src/tests.zig`** or `zig build test` won't pick it up.

There's no `--test-filter` wired through `build.zig`; to run a single test, either invoke `zig test src/path/to/file.zig` directly with the same `linkSystemLibrary` flags, or add a temporary `b.option(...)` filter to the `tests` step.

### The `glib` build option

`build.zig` defines a bool `build_options.glib`. GUI targets get `true`; `sketerm-mux` and `smoke-mux` get `false` plus the lean `configureCoreDeps` dependency set (libc only). `src/pty.zig` gates its GLib write-queue watch and async child reaper on this option, falling back to blocking writes and `waitpid`. Anything imported by the mux side (`src/mux/*`, parser, grid) must stay free of GTK/GLib references.

## Architecture (read `docs/architecture.md` for full detail)

**Events, not callbacks, parser → grid.** One PTY worker thread per pane parses bytes into a tagged-union `Event` and pushes to a lock-free SPSC ring. The main thread drains the ring under GLib's main loop, applies events to `Screen`, and queues a redraw.

**Cross-thread wakeup is coalesced via a per-Terminal `drain_pending: Atomic(bool)`.** Worker swaps it `true`; only the worker that observes the false→true transition calls `g_main_context_invoke(mainDrainEvents, term)`. Main-thread drain stores `false` *before* draining so the worker reschedules if it pushes during the drain. This guarantees one wake-up per drain cycle, regardless of event volume.

**Threading rule:** all GTK/GDK/GL/Screen/ImageStore state lives on the main thread. The PTY worker only touches its PTY fd, parser state, ring producer, and shutdown eventfd. Never call GTK from a worker.

**`Cell` is `extern struct`, 8 bytes flat.** Heavy data (OSC 8 links, images, multi-codepoint clusters, styles) lives in side tables on `Screen` (`StylePool`, `links`, `clusters`, `cell_images`). `comptime` asserts pin the size at 8.

**One `GtkGLArea` per pane; share-group at the window level.** Atlas lives on `Window`, reachable from every pane's GL context. **Reparenting unrealizes the `GtkGLArea` and destroys its `GdkGLContext`** — `Pane.onRealize` therefore treats every realize as potentially a re-realize: `Atlas.deinit`, then `forgetGL()` on `GridPass`/`ImagePass`/`ImageStore`/`BgPass` so the realize path rebuilds against the fresh context. Without this, cached non-zero shader IDs from a dead context cause silent black renders.

**Renderer invariants.** After ANY atlas rebuild/swap, call `cell_pass.markAllDirty()` and reset GridPass `vbuf_valid`/`vbo_uploaded`/`row_caches_valid` (generation counters reset to 0 and won't trip eviction detection). GridPass `Snapshot` must gain a hash/field for any new Screen-side overlay state (hints, copy cursor, …) or the vbuf won't rebuild. Emoji/CJK rows render via CellPass, not GridPass — `rowNeedsBidiOrComplexShape` only routes RTL/complex scripts to the overlay; glyph-rendering changes must hit BOTH shader pairs.

**Shaders carry NO `#version`/`precision` lines.** `gl.zig compileShader` injects a per-API header (`300 es` on Linux/GLES, `330 core` on macOS desktop GL) — adding a version line to a shader source breaks one of the two platforms. `zig build smoke-gl-core` compiles every shader under desktop GL 3.3 core (the macOS path) via Mesa. Never call `gtk_gl_area_set_use_es` directly; use `gl.requestArea` + `gl.adoptAreaApi`.

**Platform layer.** Linux-vs-macOS primitives live ONLY in `src/util/platform.zig` (exe path, eventfd-vs-pipe wakeup, runtime dir, cloexec sockets), keyed on comptime `builtin.os.tag`. OS-specific headers are `#ifdef __linux__`-gated in `vendor/cimport_*.h`. `zig build mux-portable -Dportable-target=aarch64-macos` is the cross-compile check — keep it green. See `docs/macos.md`.

**Tab/pane tree is plain Zig data; GTK widgets are the view.** The model is `src/ui/tree.zig` (`Window.PaneTree`), one per tab, attached to the AdwTabPage as qdata (`sketerm-tree`) so it travels with cross-window tab drags. **Every widget-tree mutation (split / pane close / mux takeover / restore-build) must update the model in the same function** — `splitLeaf`/`removeLeaf`/`replaceLeaf`. Queries (`tabPageForPane`, layout collection, duplicate-tab) read the model, which stays correct while a pane is zoomed (zoom only reparents widgets). `SKETERM_VERIFY_TREE=1` cross-checks model vs widgets after each mutation and aborts on divergence — smoke-e2e runs with it set. Layout persistence (`layout.zig`) serializes the model to JSON; widgets+model rebuild from the tree on load. Saved at shutdown to `$XDG_STATE_HOME/sketerm/last.json`; restored via `--restore` or `--layout <path>`. This is step 1 of de-GTK-ing `src/ui` (goal: a future native AppKit frontend reusing core + model).

**CSI handling is split.** `Screen.csi()` is a small dispatcher that routes by `params.private` to `csiPrivate` (`?`), `csiAux` (`>`), `csiKittyKbd` (`=`/`<`), or `csiPublic`. Don't fold logic back into one giant function. CSI params are u16; `Event.Csi` carries colon sub-params via `setSub(idx)`/`isSub`.

**Helpers worth knowing.** `cast.userData(T, user)` in `src/util/cast.zig` collapses `@ptrCast(@alignCast(user.?))` for GTK callbacks. `style.colorToVec` / `style.colorToRGBA` in `src/render/style.zig` are the shared color-resolution path used by both `cell_pass` and `grid_pass` — don't copy that logic into a third place.

## Remote control (IPC)

Every GUI instance serves a JSON-lines protocol on `$XDG_RUNTIME_DIR/sketerm/<pid>.sock` (a `GSocketService`, so everything runs on the main loop). `sketerm cli <command>` is the client: `list`, `send-text`, `get-text`, `new-tab`, `split`, `focus`, `close-pane`, `set-title`, `set-tab-color`, `new-durable-tab`, `attach-session`. Child processes inherit `SKETERM_SOCKET` and `SKETERM_PANE_ID`, so `--pane self` works from inside any pane. Code in `src/ipc/` (`protocol.zig`, `server.zig`, `client.zig`, `mux_cli.zig`). Socket discovery in `resolveSocket` must skip `mux.sock`.

`zig build smoke-e2e` uses this to drive a real GUI instance end-to-end. For manual testing: `SKETERM_APP_ID=dev.sker.sketerm.test ./zig-out/bin/sketerm --no-save &`, then `./zig-out/bin/sketerm cli --socket /run/user/$(id -u)/sketerm/<pid>.sock ...`.

## Mux (durable sessions)

`sketerm-mux` is a single-threaded poll-loop daemon owning one PTY + Parser + authoritative `Screen` per session. The wire protocol (`src/mux/wire.zig`) carries **parsed events, never re-encoded escape sequences** — append-only FrameType/EventTag bytes, every parser `Event` round-trips losslessly. Attach = sequence-stamped `Screen` snapshot (`src/mux/snapshot.zig`) + live event stream.

Transports, all speaking the same protocol:
- Local: Unix socket at `$XDG_RUNTIME_DIR/sketerm/mux.sock`.
- SSH: `ssh -T -o BatchMode=yes <host> sketerm-mux --proxy` over a socketpair (`src/mux/client.zig connectSsh`). `$SKETERM_SSH` overrides the ssh binary — the test rig fakes a remote host this way.
- UDP: mosh-style. SSH bootstrap runs `--udp-listen`, which announces `SKETERM-UDP <port> <keyhex>` and detaches; everything after runs over ChaCha20-Poly1305-sealed datagrams with a go-back-N stream on top (`src/mux/rudp.zig`, pure state machine with injectable clock — adversarial loss/replay/tamper tests live there). Roaming: peer address updates only from authenticated packets.

GUI side: `Terminal.initRemote` has no PTY/worker — the socket is watched via `g_unix_fd_add`, EVENTS apply directly, SNAPSHOT swaps `terminal.screen` wholesale and re-wires the sink. `writeRaw`/`requestResize` abstract PTY-vs-socket; **nothing in `src/ui` touches `terminal.pty`**. Remote terminals have `child_pid = -1`; `Terminal.reapStatus` guards `child_pid <= 0` — do not remove, or the exit poller calls `waitpid(-1)` and reaps arbitrary GUI children. Host strings: `null` = local, `"user@box"` = SSH, `"udp:box"` = UDP.

User entry points: `sketerm ssh [-u] <host>`, `sketerm mux [host] [list|attach <name>|new|kill <name>]`, bare `sketerm mux` = TUI picker, "New Durable Tab" in the palette.

## Memory ownership

- All long-lived state via the app `GeneralPurposeAllocator`.
- Per-worker `ArenaAllocator` reset once per ring drain for transient parse payloads.
- GTK signal contexts allocated on the heap (`*Ctx` types) **must** carry their own `allocator: std.mem.Allocator` and pass a matching `freeXxxCtx` callback as `g_signal_connect_data`'s 5th arg. The pattern is in `menu.zig` (`freeActionSlot`, `freeClickCtx`), `window.zig` (`PanedRatioCtx`/`freePanedRatio`, `RenameCtx`/`freeRenameCtx`), and every `add*Row` builder in `prefs.zig`. Skip the destroy-notify only when the user-data is the dialog's main `Ctx` (managed elsewhere) or is a non-heap pointer.
- Config lives in an arena: `applyConfigChange` clones into a fresh arena and frees the old one — anything holding config-arena slices (pane `font_path`, `active_profile`, `font_family`, …) must be re-pointed in that loop.
- **Pane-level settings are `ProfileSettings` bundles.** `Config.settings` IS the Default profile; `[profile.<name>]` sections are COMPLETE copies (seeded from Default at parse time — no inherit sentinels). Resolve a pane's bundle with `Config.profileSettings(name)` (empty/"default"/unknown → Default); never write field-by-field profile-vs-global fallbacks. App-level keys (window, mouse, keybinds, rendering flags, bells, background image/opacity) stay flat on `Config`.

## Debugging tips

- `zig build replay -- capture.bin [cols rows]` replays raw PTY bytes through parser→Screen and dumps the grid — invaluable for "app X renders wrong" reports. Capture with a small `pty.fork` tee script.
- **Never `pkill -f`/`pgrep -f` with a "sketerm" pattern** from a wrapper shell — the shell's own command string matches and you kill your session. Use `pkill -x sketerm-mux` or explicit PIDs.

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

`dist/PKGBUILD` builds the locally-checked-out repo (no remote source) and packages both binaries. Run `cd dist && makepkg -si`. The `.desktop` file lives at `data/dev.sker.sketerm.desktop`; the icon at `data/icons/hicolor/scalable/apps/dev.sker.sketerm.svg`. Terminfo source at `terminfo/sketerm-256color.src` — `tic`-compiled into `/usr/share/terminfo` by the PKGBUILD.

## License

GPL-3.0-or-later (see `LICENSE`). Shader presets in data/shaders/ keep
per-file licenses (all GPL-3-compatible) — see data/shaders/README.

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`sketerm` — native GTK4 terminal emulator written from scratch in Zig. No vendored terminal cores, no wrapper crates: parser/screen/atlas/render are all in-tree. Dependencies are system C libraries (`gtk4`, `libadwaita-1`, `freetype2`, `harfbuzz`, `epoxy`, `fribidi`, `fontconfig`, `libvpx` — VP9/WebM app-window recording, GUI-only) plus vendored `stb_image.h`/`stb_image_write.h`/`msf_gif.h` for image + GIF encode.

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
zig build test                  # full test suite (currently 663 tests)
zig build test --summary all    # show test count + timings
zig build smoke-mux             # mux daemon end-to-end smoke (headless)
zig build smoke-mcp             # `sketerm mcp` isolation + headless-terminal smoke (headless)
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

**Unified client-server: the GUI is always a mux client.** Every terminal — local OR remote — is a session owned by the `sketerm-mux` daemon; the GUI process owns no PTY and runs no parser/worker thread. `Terminal` is `initRemote` only: it watches the daemon socket via `g_unix_fd_add`, applies parsed EVENTS straight to `Screen`, and swaps the whole grid on a SNAPSHOT. Local tabs/splits are minted as GUI-owned (`Remote.ephemeral`) sessions on the auto-started per-user daemon (`Window.daemonSpawnPane` → `muxConnect(null)` = `connectLocalAutostart`); the daemon does the PTY read + parse in its single-threaded poll loop. Closing a tab kills its session (no leak); a GUI crash skips teardown so sessions survive for reattach (durability). **The old in-process path (per-pane worker thread + lock-free SPSC ring + `drain_pending` cross-thread wakeup + `mainDrain`) was removed** — don't reintroduce it.

**`DrainHandle` survives only for async-reply liveness.** It's still allocated per `Terminal`; its `alive` flag lets a deferred sink callback (e.g. the OSC 52 clipboard read reply, which the GUI answers asynchronously and writes back via `writeRaw` → INPUT frame → daemon PTY) detect a pane/terminal teardown between request and callback. `drain_pending`/`terminal` are now vestigial (the worker that used them is gone).

**Threading rule:** all GTK/GDK/GL/Screen/ImageStore state lives on the main thread — the GUI is single-threaded (no worker). The daemon (separate process) does the off-thread parsing. Never block the GLib main loop on a socket read; the socket is non-blocking + watched.

**`Cell` is `extern struct`, 8 bytes flat.** Heavy data (OSC 8 links, images, multi-codepoint clusters, styles) lives in side tables on `Screen` (`StylePool`, `links`, `clusters`, `cell_images`). `comptime` asserts pin the size at 8.

**One `GtkGLArea` per pane; share-group at the window level.** Atlas lives on `Window`, reachable from every pane's GL context. **Reparenting unrealizes the `GtkGLArea` and destroys its `GdkGLContext`** — `Pane.onRealize` therefore treats every realize as potentially a re-realize: `Atlas.deinit`, then `forgetGL()` on `GridPass`/`ImagePass`/`ImageStore`/`BgPass` so the realize path rebuilds against the fresh context. Without this, cached non-zero shader IDs from a dead context cause silent black renders.

**Renderer invariants.** After ANY atlas rebuild/swap, call `cell_pass.markAllDirty()` and reset GridPass `vbuf_valid`/`vbo_uploaded`/`row_caches_valid` (generation counters reset to 0 and won't trip eviction detection). GridPass `Snapshot` must gain a hash/field for any new Screen-side overlay state (hints, copy cursor, …) or the vbuf won't rebuild. Emoji/CJK rows render via CellPass, not GridPass — `rowNeedsBidiOrComplexShape` only routes RTL/complex scripts to the overlay; glyph-rendering changes must hit BOTH shader pairs.

**Shaders carry NO `#version`/`precision` lines.** `gl.zig compileShader` injects a per-API header (`300 es` on Linux/GLES, `330 core` on macOS desktop GL) — adding a version line to a shader source breaks one of the two platforms. `zig build smoke-gl-core` compiles every shader under desktop GL 3.3 core (the macOS path) via Mesa. Never call `gtk_gl_area_set_use_es` directly; use `gl.requestArea` + `gl.adoptAreaApi`.

**Platform layer.** Linux-vs-macOS primitives live ONLY in `src/util/platform.zig` (exe path, eventfd-vs-pipe wakeup, runtime dir, cloexec sockets), keyed on comptime `builtin.os.tag`. OS-specific headers are `#ifdef __linux__`-gated in `vendor/cimport_*.h`. `zig build mux-portable -Dportable-target=aarch64-macos` is the cross-compile check — keep it green. See `docs/macos.md`.

**Tab/pane tree is plain Zig data; GTK widgets are the view.** The model is `src/ui/tree.zig` (`Window.PaneTree`), one per tab, attached to the AdwTabPage as qdata (`sketerm-tree`) so it travels with cross-window tab drags. **Every widget-tree mutation (split / pane close / mux takeover / restore-build) must update the model in the same function** — `splitLeaf`/`removeLeaf`/`replaceLeaf`. Queries (`tabPageForPane`, layout collection, duplicate-tab) read the model, which stays correct while a pane is zoomed (zoom only reparents widgets). `SKETERM_VERIFY_TREE=1` cross-checks model vs widgets after each mutation and aborts on divergence — smoke-e2e runs with it set. Layout persistence (`layout.zig`) serializes the model to JSON; widgets+model rebuild from the tree on load. Saved at shutdown to `$XDG_STATE_HOME/sketerm/last.json`; restored via `--restore` or `--layout <path>`. This is step 1 of de-GTK-ing `src/ui` (goal: a future native AppKit frontend reusing core + model).

**CSI handling is split.** `Screen.csi()` is a small dispatcher that routes by `params.private` to `csiPrivate` (`?`), `csiAux` (`>`), `csiKittyKbd` (`=`/`<`), or `csiPublic`. Don't fold logic back into one giant function. CSI params are u16; `Event.Csi` carries colon sub-params via `setSub(idx)`/`isSub`.

**Helpers worth knowing.** `cast.userData(T, user)` in `src/util/cast.zig` collapses `@ptrCast(@alignCast(user.?))` for GTK callbacks. `style.colorToVec` / `style.colorToRGBA` in `src/render/style.zig` are the shared color-resolution path used by both `cell_pass` and `grid_pass` — don't copy that logic into a third place.

## Remote control (IPC)

Every GUI instance serves a JSON-lines protocol on `$XDG_RUNTIME_DIR/sketerm/<pid>.sock` (a `GSocketService`, so everything runs on the main loop). `sketerm cli <command>` is the client: `list`, `send-text`, `send-keys`, `get-text`, `screen-info`, `new-tab`, `split`, `focus`, `close-pane`, `set-title`, `set-tab-color`, `new-durable-tab`, `attach-session`. Child processes inherit `SKETERM_SOCKET` and `SKETERM_PANE_ID`, so `--pane self` works from inside any pane. Code in `src/ipc/` (`protocol.zig`, `server.zig`, `client.zig`, `mux_cli.zig`, `keys.zig` = pure chord→bytes encoder for send-keys). Socket discovery in `resolveSocket` must skip `mux.sock`.

`sketerm mcp` (`src/ipc/mcp.zig`) is a Model Context Protocol server on stdio for AI assistants: JSON-RPC 2.0 NDJSON in/out, tools adapted onto the same socket. Terminal tools (list_terminals, read_screen, screenshot_pane, send_text, send_keys, run_command, wait_idle, new_tab, split_pane, focus_pane, close_pane) go through the GUI socket. **Headless GUI-app tools** (`appTool` in mcp.zig, backed by `src/ipc/appdrive.zig` — a proto-v5 mux client with per-channel replica compositors, GTK-free) talk to the mux daemon DIRECTLY, so they work with no GUI: launch_app (cwd/env/wait_for, replies with the first window's screenshot inline), get_app_state, screenshot_app (bounded/downscaled inline PNG; region crop + integer zoom + wait_change), app_output (the app's PTY stdout/stderr — appdrive keeps a termdrive-style Screen mirror; exit summaries inline recent_output + signal), app_click/app_drag/app_type/app_key/app_scroll/app_resize, app_clipboard_get/set, app_a11y_tree, app_record_start/stop, app_wait, list_installed_apps, close_app. run_command/wait_idle detect output quiescence by polling `screen-info`'s `seq` (= `Terminal.activity_seq`) — the GUI dispatch stays synchronous. Dispatch takes an injectable `Backend` so it unit-tests with a scripted fake. Responses must stay newline-free (NDJSON framing); inline images (`imageResult`) are base64 PNG content blocks.

**MCP isolation (default).** `sketerm mcp` runs its app tools against a PRIVATE daemon instance (`$XDG_RUNTIME_DIR/sketerm/mcp-tmp-<pid>/mux.sock`, torn down on exit incl. SIGTERM; orphans from a SIGKILL are swept at the next mcp startup). `--durable` / `--name <n>` = named persistent instance (`mcp-<n>/`) — the daemon and its apps survive MCP restarts, and a reconnecting `sketerm mcp --name <n>` auto-reattaches to the still-running app sessions (`App.attachExisting` + `listAppSessions` in appdrive.zig; `App.detach` frees client state without killing the session). `--shared` opts into the user's real per-user daemon + running GUI (the only mode where terminal tools auto-discover the GUI socket; isolated mode requires an explicit `--socket`). Plumbing: `Conn.connectLocalAutostartAt(alloc, sock)` spawns `sketerm-mux --broker --socket <path>`; the daemon derives all aux paths (Wayland hub, a11y dirs) from the socket's directory, so an instance is fully contained in its dir.

**Forwarded-app input encoding.** `src/ipc/evkeys.zig` = char/chord→evdev encoder; `src/ipc/xkblayout.zig` parses the session's compiled-xkb keymap (`src/wlhost/keymaps.zig`: us/gb/fr/be/de) so MCP typing matches the session keymap (spawn `kb_layout`, config `app_keyboard_layout`). The compositor's `keymap` field must match whoever drives the seat.

**AT-SPI accessibility (`app_a11y_tree`).** Daemon-side so it works wherever the app runs. `src/mux/a11yhub.zig` spawns a PRIVATE `dbus-daemon` + `at-spi2-registryd` per app session (private `XDG_RUNTIME_DIR` so the a11y bus is per-session), sets `GTK_A11Y=atspi` (NOT `=1`) + `org.a11y.Status.IsEnabled` BEFORE the app starts (toolkits don't retry a11y registration — ordering is load-bearing, `Hub.setup` blocks on a readiness poll), then walks the tree with a pure-Zig D-Bus client (`src/mux/dbus.zig`, no libdbus, musl-clean — SASL EXTERNAL wants the uid as DECIMAL hex-encoded byte-by-byte). Wire: `app_a11y`/`app_a11y_tree` frames. `SKETERM_NO_A11Y=1` disables. Distinct from `src/a11y/` which is TUI-grid a11y for sketerm's own panes.

`zig build smoke-e2e` uses this to drive a real GUI instance end-to-end. For manual testing: `SKETERM_APP_ID=dev.sker.sketerm.test ./zig-out/bin/sketerm --no-save &`, then `./zig-out/bin/sketerm cli --socket /run/user/$(id -u)/sketerm/<pid>.sock ...`.

## Mux (durable sessions)

`sketerm-mux` is a single-threaded poll-loop daemon owning one PTY + Parser + authoritative `Screen` per session. The wire protocol (`src/mux/wire.zig`) carries **parsed events, never re-encoded escape sequences** — append-only FrameType/EventTag bytes, every parser `Event` round-trips losslessly. Attach = sequence-stamped `Screen` snapshot (`src/mux/snapshot.zig`) + live event stream.

Transports, all speaking the same protocol:
- Local: Unix socket at `$XDG_RUNTIME_DIR/sketerm/mux.sock`.
- SSH: `ssh -T -o BatchMode=yes <host> sketerm-mux --proxy` over a socketpair (`src/mux/client.zig connectSsh`). `$SKETERM_SSH` overrides the ssh binary — the test rig fakes a remote host this way.
- UDP: mosh-style. SSH bootstrap runs `--udp-listen`, which announces `SKETERM-UDP <port> <keyhex>` and detaches; everything after runs over ChaCha20-Poly1305-sealed datagrams with a go-back-N stream on top (`src/mux/rudp.zig`, pure state machine with injectable clock — adversarial loss/replay/tamper tests live there). Roaming: peer address updates only from authenticated packets.

**Wayland app forwarding (proto v2).** The compositor advertises the modern client surface (`compositor.zig globals`): core v6/v8-level globals plus primary selection, relative-pointer + pointer-constraints, text-input v3 (host IME → `text_commit` intents), xdg-activation, presentation-time, idle-inhibit, pointer gestures, and WITHIN-app dnd (`start_drag` state machine; the drop transfer is daemon-local via the `dnd_send` unit). Buffers are shm plus opt-in LINEAR-only linux-dmabuf — per session via `SpawnReq.gpu` (`sketerm app --gpu`, MCP `launch_app gpu:true`, launcher right-click "Launch with GPU", config `gpu_apps` list) or daemon-wide via `SKETERM_MUX_DMABUF=1`; either announces the global AND drops the forced `LIBGL_ALWAYS_SOFTWARE` (the daemon mmaps the plane fd, no GPU libraries; drivers that refuse CPU mmap degrade to a logged stale buffer, so the default stays shm-safe). Fractional scaling is REAL: the GUI ships its true monitor scale as a `set_scale` intent (scale×120); the brain answers `wp_fractional_scale` `preferred_scale`, honors `wp_viewport` destinations as the surface's logical size (`toplevel_frame` carries lw/lh), and re-announces all scale channels when the intent lands (apps may connect first). Pointer events are frame-grouped (seat v5+ clients buffer input until `wl_pointer.frame`); every advertised version's obligations are implemented — a client binding above an advertised version gets a logged protocol error. Byte channels (`chan_open/data/close` wire frames) multiplex generic streams over the mux connection — any transport, so forwarded apps roam with UDP. There is NO waypipe: the daemon IS the session's Wayland display. It listens on a per-session display socket (`setupWaylandHub`), sets the shell's `$WAYLAND_DISPLAY` to it, and parses each app connection itself (`Channel.native` = `wlhost/track.zig` tracker + mmapped shm-pool mirrors), tunneling parsed `wlhost/pipe.zig` units as `wayland_native` channels toward the latest attached proto>=2 client. `SKETERM_MUX_NO_WAYLAND=1` disables forwarding. GUI: `terminal.zig` feeds each `wayland_native` channel into a `wlapp.zig` `AppHost` (the `wlhost` compositor brain) that renders the windows locally — no external compositor bridge. **App view modes** (`app_view = window|tab`, default window): window mode attaches TABLESS (`Window.AppSession`, no pane/tab — like a desktop launcher; a held log tab materializes only on exit-without-window, and "Show in Tab" adopts the live terminal into a real pane via `adoptAppSessionIntoTab` + `Pane.adoptAppHost`); a pane that DOES host an app session shows the log + an "App window open" banner (`Terminal.on_app_window` fires on the FIRST toplevel frame — which is also when `app_window_opened` flips; channel-open alone must NOT count, or single-instance handoffs like pcmanfm take the wrong exit path). Tab mode reparents the primary toplevel's overlay into the pane (fully interactive; the hidden GtkWindow is kept alive childless so window-based paths stay valid); "Pop Out Window"/"Show in Tab" in the Ctrl+right-click host menu switch live. A pane MUST call `detachAppHost()` (unlistPane does) before its widget tree dies — the embedded overlay lives inside it. `Terminal.clearSinks` must null EVERY user_ctx-consuming callback (incl. on_app_view/on_app_window); a missed one = post-fence crash from deferred deinit. **Forwarded-app taskbar icons:** the daemon resolves the app's icon to image BYTES on the app's host (`src/mux/icons.zig`, freedesktop lookup) when it sees `set_app_id`, ships them as a `toplevel_icon` pipe unit (daemon-injected; cached per app_id, replayed on reattach), and the GUI builds a GdkTexture + `gdk_toplevel_set_icon_list` (drives xdg-toplevel-icon on Wayland / _NET_WM_ICON on X11). This is how REMOTE apps get their real icon (Wayland's app_id->local .desktop lookup can't). `gdk-pixbuf` is GUI-only (SVG decode) — keep it out of the mux graph. `sketerm app [-u] <host> <cmd>` (`src/remoteapp.zig`) spawns an app session and hands it to the running GUI to render; it therefore REQUIRES a sketerm window open on this desktop (no GUI → it errors). macOS remotes have no Wayland; they stream pixels instead (`winstream`, kind 3). **Remote audio (kind 4):** the daemon is ALSO the session's PulseAudio server (`mux/pulse.zig`, hand-rolled native protocol v13, SHM refused; `PULSE_SERVER` set per session, `SKETERM_MUX_NO_AUDIO=1` opts out). PCM units flow only to viewers that sent a `subscribe` unit; streams self-clock (instant-consume) until a viewer's `consumed` report flips them to viewer-clocked — the GUI's `audio_sink.zig` (async libpulse on the GLib loop, Linux GUI-only dep) reports real playback as the clock. Playback only; no capture. `-Daudio-opus` (default off, vcodec-style) compresses PCM ~12x: negotiated via subscribe flags, latched per stream, s16/48kHz-family only (44.1k stays raw), `pcm_opus` units carry a raw-byte count so non-decoding consumers keep the clock.

GUI side: `Terminal.initRemote` has no PTY/worker — the socket is watched via `g_unix_fd_add`, EVENTS apply directly, SNAPSHOT swaps `terminal.screen` wholesale and re-wires the sink. `writeRaw`/`requestResize` abstract PTY-vs-socket; **nothing in `src/ui` touches `terminal.pty`**. Remote terminals have `child_pid = -1`; `Terminal.reapStatus` guards `child_pid <= 0` — do not remove, or the exit poller calls `waitpid(-1)` and reaps arbitrary GUI children. Host strings: `null` = local, `"user@box"` = SSH, `"udp:box"` = UDP.

User entry points: `sketerm ssh [-u] <host>`, `sketerm mux [host] [list|attach <name>|new|kill <name>]`, bare `sketerm mux` = TUI picker, "New Durable Tab" in the palette.

## Memory ownership

- All long-lived state via the app `GeneralPurposeAllocator`.
- Per-worker `ArenaAllocator` reset once per ring drain for transient parse payloads.
- GTK signal contexts allocated on the heap (`*Ctx` types) **must** carry their own `allocator: std.mem.Allocator` and pass a matching `freeXxxCtx` callback as `g_signal_connect_data`'s 5th arg. The pattern is in `menu.zig` (`freeActionSlot`, `freeClickCtx`), `window.zig` (`PanedRatioCtx`/`freePanedRatio`, `RenameCtx`/`freeRenameCtx`), and every `add*Row` builder in `prefs.zig`. Skip the destroy-notify only when the user-data is the dialog's main `Ctx` (managed elsewhere) or is a non-heap pointer.
- Config lives in an arena: `applyConfigChange` clones into a fresh arena and frees the old one — anything holding config-arena slices (pane `font_path`, `active_profile`, `font_family`, …) must be re-pointed in that loop.
- **Pane-level settings are `ProfileSettings` bundles.** `Config.settings` IS the Default profile; `[profile.<name>]` sections are COMPLETE copies (seeded from Default at parse time — no inherit sentinels). Resolve a pane's bundle with `Config.profileSettings(name)` (empty/"default"/unknown → Default); never write field-by-field profile-vs-global fallbacks. App-level keys (window, mouse, keybinds, rendering flags, bells, background image/opacity) stay flat on `Config`.

## Debugging tips

- **Daemon log**: every daemon writes lifecycle + warnings to `$XDG_STATE_HOME/sketerm/mux.log` (all instances share it; `[pid]` attributes lines; rotated at 2MB to `.old`). `SKETERM_MUX_LOG=debug` adds wlhost tracing — pool mirror lifecycle (mapped/orphaned/reclaimed with incarnation serials) and commit pixel-path TRANSITIONS ("commit resolves NO mirror" is the silent-black-window failure class). `=off` disables the file, `=<path>` logs there at debug level. Warnings always also hit stderr. Module: `src/mux/log.zig` (libc-only, no allocator).
- `zig build replay -- capture.bin [cols rows]` replays raw PTY bytes through parser→Screen and dumps the grid — invaluable for "app X renders wrong" reports. Capture with a small `pty.fork` tee script.
- **Headless GUI testing works**: `xvfb-run -a zig build smoke-e2e`; for interactive visual checks run `Xvfb :99` + the app with `DISPLAY=:99 GDK_BACKEND=x11`, drive it with `xdotool` (clicks/keys) and screenshot with ImageMagick `import`. ALWAYS isolate `XDG_CONFIG_HOME`/`XDG_STATE_HOME` (prefs auto-saves would clobber the real config.conf) and set `SKETERM_APP_ID` so GApplication uniqueness doesn't reuse a live instance.
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

`dist/PKGBUILD` builds the locally-checked-out repo (no remote source) and packages both binaries. Run `cd dist && makepkg -si`. The `.desktop` file lives at `data/dev.sker.sketerm.desktop`; the icon at `data/icons/hicolor/scalable/apps/dev.sker.sketerm.svg`. Terminfo source at `terminfo/sketerm-256color.src` — `tic`-compiled into `/usr/share/terminfo` by the PKGBUILD.

## License

GPL-3.0-or-later (see `LICENSE`). Shader presets in data/shaders/ keep
per-file licenses (all GPL-3-compatible) — see data/shaders/README.

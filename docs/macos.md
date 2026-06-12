# macOS support

Status: **verified on real hardware** (Apple Silicon M2, macOS 26.4,
Homebrew GTK 4.22, Zig 0.16.0). The GUI builds and runs natively, the
full unit-test suite passes (500/507, 7 skipped), `smoke-mux` and
`smoke-e2e` PASS, and mux interop with a Linux daemon works over both
SSH and UDP transports. Remaining gaps are listed at the bottom.

## Verified on hardware (2026-06)

- **Native mux daemon**: `zig build mux && zig build smoke-mux` —
  PASS. The binary links libSystem + brew's libfribidi (the Mach-O
  linker does not drop the unused fribidi dep the way `--as-needed`
  does on Linux; harmless, but the native build is not
  single-file-portable — use `mux-portable` for that).
- **`cwdOfPid` offsets** (`layout.zig`): confirmed against the real
  SDK and a live call — sizeof(struct vnode_info)=152, vip_path at
  offset 152, MAXPATHLEN=1024, flavor 9, result matches getcwd().
- **GUI**: builds, opens a window, panes realize (GL via GDK's
  desktop-GL path), zsh runs, IPC socket + `sketerm cli` round-trips,
  OSC 7 cwd reporting works, `zig build smoke-e2e` passes natively
  (no DISPLAY env needed — gated on `platform.is_macos`).
- **Cross-direction builds**: `zig build mux-portable` (x86_64- and
  aarch64-linux-musl) cross-compiles green FROM macOS; a Mac-built
  aarch64-musl daemon runs unmodified on Ubuntu aarch64.
- **Mux interop from macOS**: `sketerm mux <host> list/new/attach`
  against a Linux daemon over SSH; durable sessions survive GUI
  restarts; snapshot-attach restores screen content. UDP transport
  (`udp:<ip>`) verified Darwin↔Darwin and Darwin↔Linux (ChaCha20
  datagrams, SSH bootstrap on Darwin, getentropy/clock paths in
  rudp.zig all exercised on hardware).
- **`sketerm app`** correctly refuses on macOS (no Wayland session) —
  Linux-only by design.

## Real-hardware friction found (and fixed)

1. **Aro SIGBUS on `<arm_neon.h>`** — the first GUI build failure.
   graphene-config.h picks its NEON backend on any aarch64, and Zig's
   translate-c (Aro) crashes outright on arm_neon.h. Fixed in
   `vendor/cimport_root.h`: `GRAPHENE_SIMD_BENCHMARK` +
   `GRAPHENE_HAS_SCALAR` force graphene's scalar backend during
   translation (aarch64 only; x86_64 keeps SSE). Scalar simd4f is
   layout-compatible and sketerm never calls graphene itself.
2. **`c.stdout` is not a value on Darwin** — <stdio.h> defines the
   std streams as macros over `__stdoutp` etc., which translate-c
   renders as inline *functions*; glibc exports extern variables.
   Use `platform.stdout()/stderr()/stdin()` — never `c.stdout`.
3. **EGL smoke harnesses** don't exist on macOS (no EGL). They are
   registered in build.zig only for Linux targets; the default
   `zig build` would otherwise fail before compiling anything.
4. **Font candidates** were Linux distro paths; a default config
   found no font and panes never realized. macOS now falls back to
   Menlo/Monaco/SF Mono/Courier New (`pane.zig FONT_CANDIDATES`).
   FreeType opens Menlo.ttc fine (face index 0).
5. **zsh OSC 7 trailing `%`** — `${PWD//%/%25}` in zsh anchors an
   empty match at the END (it doesn't escape `%`), appending `%25` to
   every reported cwd. All-platform bug, surfaced by cwd checks here.
6. **`zig build mux` requires the full GTK dev set installed** even
   though the daemon doesn't use GTK: build.zig resolves pkg-config
   for every package eagerly at configure time. On a GTK-less host
   the daemon can't be built from source (cross-compile mux-portable
   from elsewhere instead). Known wart, not yet fixed.

## Building on a Mac (verified recipe)

```bash
brew install zig pkgconf gtk4 libadwaita adwaita-icon-theme \
             freetype harfbuzz libepoxy fribidi fontconfig

zig build            # GUI → zig-out/bin/sketerm
zig build mux        # session daemon
zig build test       # 500/507 (7 skipped)
zig build smoke-mux  # daemon end-to-end
zig build smoke-e2e  # GUI end-to-end (opens a real window)
```

brew's zig 0.16.0 matches the pinned toolchain; `/opt/homebrew/bin`
must be on PATH (pkg-config lives there). No PKG_CONFIG_PATH fiddling
was needed — pkgconf's defaults cover the brew prefix.

## Known noise / open items

- GTK prints a stream of `Theme parser warning: gtk.css ...` at
  startup (brew's default theme vs GTK 4.22) — cosmetic.
- Two `gtk_gl_area_queue_render: assertion 'GTK_IS_GL_AREA' failed`
  CRITICALs during smoke-e2e teardown — timing issue on the macOS
  backend, not yet chased; test still passes.
- Visual rendering confirmed only indirectly (no GL errors, e2e text
  assertions pass). `screencapture` needs Screen Recording permission
  — eyeball a window when working interactively.
- Creating/attaching a remote tab runs the SSH/UDP bootstrap on the
  GTK main thread — a slow or failing connect freezes the UI for the
  duration (pre-existing on Linux too, just easier to hit over real
  networks).
- `udp:localhost` v4/v6 resolution bug still applies — use a real IP
  or hostname.
- `.app` bundle / packaging not started (run from zig-out/bin).
- Cmd-vs-Ctrl keybinding conventions not started.

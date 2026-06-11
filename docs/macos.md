# macOS support (work in progress)

Status: the **terminal core is macOS-portable and cross-compiles from
Linux** (`zig build mux-portable -Dportable-target=aarch64-macos`
produces a native arm64 Mach-O `sketerm-mux`). The GUI is expected to
build on a Mac against Homebrew GTK4 but has NOT yet been verified on
real hardware.

## What is already done

- **GL API portability.** macOS GDK is desktop-GL-only (OpenGL 4.1
  core via CGL); requesting GLES black-screens. All shaders now carry
  no `#version`/`precision` lines — `src/render/gl.zig` injects
  `#version 300 es` (Linux/GLES) or `#version 330 core` (macOS)
  per-stage at compile time, and `Pane.onRealize` adopts whatever API
  GDK actually realized. `zig build smoke-gl-core` proves every
  shader compiles under a desktop-GL 3.3 core context (run on Linux
  via Mesa).
- **Platform layer** (`src/util/platform.zig`): exe-path discovery
  (`/proc/self/exe` vs `_NSGetExecutablePath`), cross-thread wakeup
  (eventfd vs pipe), runtime dir (`$XDG_RUNTIME_DIR` vs `$TMPDIR`),
  close-on-exec sockets (`SOCK_CLOEXEC` is Linux-only).
- **Header gating** in `vendor/cimport_root.h` / `cimport_core.h`:
  `pty.h`/`sys/eventfd.h` are Linux; Darwin gets openpty/forkpty
  declared directly (Zig's bundled libc headers lack `util.h`) and
  `sys/random.h` for getentropy.
- **Child cwd** (`layout.zig cwdOfPid`): `/proc/<pid>/cwd` on Linux,
  `proc_pidinfo(PROC_PIDVNODEPATHINFO)` on macOS. The macOS struct
  offsets (152/1024) match Apple's libproc.h but are UNVERIFIED on
  hardware — check this first if layout-save cwd looks wrong.
- **build.zig**: `use_lld` only on Linux targets (the LLD pin works
  around gcc 15 `.sframe`; macOS wants Zig's self-hosted Mach-O
  linker).

## Building the GUI on a Mac (untested recipe)

```bash
# 1. Dependencies via Homebrew
brew install zig gtk4 libadwaita adwaita-icon-theme \
             freetype harfbuzz libepoxy fribidi fontconfig pkg-config

# 2. pkg-config must see brew's .pc files (Apple Silicon prefix)
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:/opt/homebrew/share/pkgconfig"

# 3. Build
zig build            # GUI
zig build mux        # session daemon
zig build test       # unit tests (all portable)
```

Note: brew's `zig` must be 0.16.x (the pinned toolchain). If brew
moved on, fetch the right tarball from ziglang.org/download.

## Expected friction points (in likely order)

1. **TranslateC on brew's GTK headers.** The out-of-process
   translate-c step (see CLAUDE.md) may hit Darwin-specific Clang
   constructs (availability attributes, blocks) needing new entries
   in the sed fixup or `vendor/aro_shims/`. This is the most likely
   first failure; capture the error output.
2. **Fontconfig first run** builds its cache for /System/Library/Fonts
   — takes a minute, looks like a hang.
3. **`gtk_gl_area_get_error` at realize.** If panes render black,
   check stderr for the realize error print; that's the GL-API path.
4. **Monospace alias.** fontconfig on mac resolves "monospace" to
   whatever its config says — Menlo usually. Set an explicit
   `font_family` in the config if the default looks off.
5. **Smoke binaries** (`smoke-cell`, `smoke-image`, …) are EGL-based
   and Linux-only by nature; skip them on a Mac. `zig build test`
   plus running the app is the verification path there.

## Not yet done

- `.app` bundle / packaging (run from zig-out/bin for now; gtk-osx +
  gtk-mac-bundler is the known-good route if we ever ship).
- Cmd-vs-Ctrl keybinding conventions.
- GUI verification on hardware — everything above the terminal core.

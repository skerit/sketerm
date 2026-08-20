# The CEF browser helper on macOS

Status: **builds, initializes and serves the wire protocol; page loads
do not complete yet.** `zig build smoke-web` reaches stage 1 (handshake)
and fails at stage 2 with `no load-finished after navigate`. Everything
below stage 2 — the framework, the bundle, the child processes, the
shared frame buffer — is working and verified on hardware (Apple
Silicon, macOS 26, CEF 151.3.16).

Read `src/web/CLAUDE.md` first. This file is only what differs here.

## What the platform actually requires

Four things, each established by a specific failure rather than from
documentation:

1. **A different distribution.** macOS ships
   `Chromium Embedded Framework.framework`, not `libcef.so`, and there
   is no top-level `Resources/` to flatten — everything is already
   inside the framework. `cefPlatform()` in `build.zig` maps the target
   to a CDN slug (`linux64`, `macosarm64`) and its checksum. macOS is
   **arm64 only** on purpose: `macosx64` exists but nothing here has
   ever run on an Intel Mac, and an unverified pin is worse than an
   honest refusal.

2. **A `uchar.h` shim to translate the headers.** CEF's
   `cef_string_types.h` guards `#include <uchar.h>` behind
   `#ifdef __clang__` + `__has_include`, precisely because the header
   only exists with Xcode 14.3+. Zig's translate-c (Aro) does not
   define `__clang__`, so it takes the unconditional branch and fails
   on a Command Line Tools SDK. `vendor/aro_shims/cef/uchar.h` supplies
   the two typedefs CEF uses, on the CEF translation's include path
   only.

3. **An app bundle. This is not packaging — it is a hard runtime
   requirement.** The loose `zig-out/bin/sketerm-webengine` CANNOT run:
   Chromium resolves `icudtl.dat` through the framework BUNDLE, which
   it can only locate from a bundled main executable, so an unbundled
   helper dies with `icudtl.dat not found in bundle` before
   `cef_initialize` returns. The real artifact is
   `zig-out/sketerm-webengine.app`, assembled by `dist/macos-bundle.sh`
   as part of `zig build web`.

4. **A separate helper `.app` for child processes.** macOS will not let
   CEF launch renderer/GPU/network children by re-executing the browser
   binary the way Linux does; you get
   `GPU process launch failed: error_code=1003` on a loop and then a
   fatal `GPU process isn't usable. Goodbye.` The helper needs its own
   bundle and `Info.plist` (with `LSUIElement`, or every child bounces
   a Dock icon). `CefSettings.browser_subprocess_path` points at it;
   `macHelperPath` in `cefhost.zig` derives that from our own location
   so a bundle stays relocatable.

   The helper also needs its framework load command **rewritten**. The
   framework's install name is
   `@executable_path/../Frameworks/…`, which is correct for
   `Contents/MacOS/` and resolves inside the HELPER's own bundle when
   used from `Contents/Frameworks/<helper>.app/Contents/MacOS/` — where
   no framework exists. `dist/macos-bundle.sh` runs `install_name_tool`
   to point it three levels up (the same relative path CEF's own
   `CefScopedLibraryLoader` uses for helpers) and re-signs, because
   editing a load command invalidates the signature and macOS refuses
   to exec a binary whose signature does not match.

## Linking, and why it deviates from CEF's README

CEF's README says executables "must load this framework dynamically at
runtime instead of linking it directly", via `cef_load_library` from
`libcef_dll_dylib.cc`. **This build links it directly instead**, and
the deviation is deliberate and toolchain-driven:

- `libcef_dll_dylib.cc` is C++, and its capi includes pull in
  `<cstring>`.
- Zig 0.16's BUNDLED libc++ does not compile against a current macOS
  SDK (`INFINITY` undeclared in `__random/clamp_to_integral.h`).
- The SDK's own libc++ headers refuse to be used out of Zig's include
  order (`<cstring> tried including <string.h> but didn't find
  libc++'s`).
- The file cannot be compiled as C either — it uses an anonymous
  `namespace`.

Direct linking needs no C++ translation unit at all, and the
framework's `@executable_path/../Frameworks/…` install name IS the
bundle layout, so one binary works from a bundle and from `zig-out`
(the build stages the framework accordingly). The cost is that the
helper is not relocatable away from its framework — which was already
true on Linux, where it needs the `.pak`/`icudtl.dat` siblings.

If a future Zig fixes the libc++ situation, the dylib-wrapper route is
the more conventional one and would remove the `install_name_tool` step.

## What is Linux-only by construction

- **The accelerated (GPU) frame path.** macOS `on_accelerated_paint`
  delivers an **IOSurface**;
  `cef_accelerated_paint_info_t` there is
  `{shared_texture_io_surface, format, extra}` with no `planes` array
  and no `plane_count`. There is no wire frame for an IOSurface and no
  GTK importer for one (`GdkDmabufTextureBuilder` is Linux-only). The
  helper therefore stays on the SOFTWARE paint path and
  `setAccelerated(false)` is unconditional here. An IOSurface frame
  family would be a new protocol capability, not a tweak.
- **Ozone.** `--ozone-platform=` is not a switch on macOS; Chromium
  uses its own windowing layer. `buildCefArgv` returns early rather
  than probing for a compositor that cannot exist.
- **The `LD_PRELOAD` re-exec.** There is no zygote on macOS and dyld
  binds the framework through its install name, so there is no load
  order to fix. Do not "port" it.

## Bugs this port surfaced that were NOT macOS-specific

- **`server.zig` read `errno` after `cefhost.pump()`.**
  `cef_do_message_loop_work` runs a whole Chromium iteration and
  clobbers `errno`, so a poll interrupted by a signal looked like a
  hard failure. macOS made it fatal on the first idle tick
  (`serve failed: PollFailed` before any client could connect); the
  same race was always present on Linux, where poll simply woke
  cleanly more often.
- **A macOS POSIX shm object accepts `ftruncate` EXACTLY ONCE**
  (a second call returns EINVAL). `platform.anonFileFd` spent that one
  call on a zero-sized truncate, so the helper's real sizing failed and
  its frame buffer stayed empty. `size == 0` now means
  "create, do not size".

## The open failure

`smoke-web` stage 2, `no load-finished after navigate`. What is known:

- The handshake completes, so the socket, framing and capability
  negotiation all work.
- The browser is created and its frame buffer is allocated and
  announced (stage 2 gets past `waitBufferAfter`).
- All child processes spawn and stay up: GPU, network, storage, utility
  and a renderer. No crash reports are generated, and the helper does
  not exit — it simply never reports the load finishing.

What has been ruled out:

- **Not** the missing `NSApplication`. `src/web/mac_app.m` adds one
  implementing `CefAppProtocol` (CEF contract for any macOS embedder,
  so it is kept), and the stall is **unchanged** with and without it.
- **Not** the shm sizing bug above — that was a different, earlier
  failure (the helper closed the socket) and is fixed.

Next things to try, in order:

1. Get CEF's own log out of the rig. `LOGSEVERITY_WARNING` produces no
   file when nothing warns, and the rig `rm -rf`s its temp dir through
   `/bin/rm` on failure, so the usual tricks do not survive. Run the
   bundled helper by hand with `--enable-logging --v=1` and a cache dir
   you control, and drive it with a minimal client.
2. Check whether the renderer ever commits a document — a Chromium
   renderer that starts but cannot host a frame would look exactly like
   this from outside.
3. Compare against a windowed (non-OSR) browser on the same helper: if
   a windowed load finishes, the problem is in the OSR path
   specifically rather than in navigation.
4. Only after the above: revisit `external_message_pump`. It is
   deliberately 0 and the entire "no lock, no atomic, no queue" threading
   invariant in `cefhost.zig` rests on that, so changing it is a design
   change, not a fix to try casually.

## Building it

```bash
zig build fetch-cef      # macosarm64 minimal tarball, checksum-pinned
zig build web            # -> zig-out/sketerm-webengine.app
zig build smoke-web      # drives the .app (stage 2 fails, see above)
```

`dist/macos-bundle.sh <out> <exe> <cef-release-dir> [--copy]` builds the
bundle standalone. It symlinks the 224MB framework by default (a dev
loop wants that); `--copy` makes a shippable bundle.

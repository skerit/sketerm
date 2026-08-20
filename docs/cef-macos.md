# The CEF browser helper on macOS

Status: **the full `zig build smoke-web` suite passes on macOS —
exit 0, every stage green** (Apple Silicon, macOS 26, CEF 151.3.16,
verified 2026-08-20, including an eyeballed screenshot of a real
rendered page). The one known red is `zig build test-web`: the unit
test binary links the framework directly and dyld cannot resolve
`@executable_path/../Frameworks/…` from `.zig-cache/o/<hash>/test` —
the fix is staging (or symlinking) the framework next to the test
binary in build.zig, and it has never worked on macOS.

Read `src/web/CLAUDE.md` first. This file is only what differs here.

## What the platform actually requires

Six things, each established by a specific failure rather than from
documentation:

1. **A different distribution.** macOS ships
   `Chromium Embedded Framework.framework`, not `libcef.so`, and there
   is no top-level `Resources/` to flatten — everything is already
   inside the framework. `cefPlatform()` in `build.zig` maps the target
   to a CDN slug (`linux64`, `macosarm64`) and its checksum. macOS is
   **arm64 only** on purpose: `macosx64` exists but nothing here has
   ever run on an Intel Mac, and an unverified pin is worse than an
   honest refusal.

2. **A separate helper `.app` VARIANT per child type.** Chromium on
   macOS launches a renderer from "<name> Helper (Renderer).app", not
   from the plain "<name> Helper.app" that serves GPU/network/utility
   children (look inside any Chrome or Electron bundle). With only the
   plain helper present, every RENDERER launch fails with
   `error_code=1003` (TS_LAUNCH_FAILED), every navigation dies
   pre-commit as ERR_ABORTED, and no page ever reports loading — while
   GPU and network children run, so the process tree looks healthy.
   That was the original "no load-finished after navigate" stall.
   `dist/macos-bundle.sh` ships the full standard set: Helper, (GPU),
   (Renderer), (Plugin), (Alerts).

3. **A mock keychain.** Chromium's cookie store encrypts at rest with
   a key from the Keychain ("Chrome Safe Storage"). For this helper —
   headless, ad-hoc-signed, re-identified every dev build — the
   SecKeychain call simply never returns: no prompt, no error, the
   cookie store never initializes (no `Default/Cookies` file ever
   appears), and CEF then holds EVERY http(s) request on its cookie
   load (`MaybeLoadCookies` in the interception wrapper — data: URLs
   skip cookies, which is why only network URLs hung). `buildCefArgv`
   appends `--use-mock-keychain` on macOS. Diagnosed with a netlog
   (only a speculative preconnect ever reached the network service)
   plus a client cookie enumeration that never answered.

4. **A `uchar.h` shim to translate the headers.** CEF's
   `cef_string_types.h` guards `#include <uchar.h>` behind
   `#ifdef __clang__` + `__has_include`, precisely because the header
   only exists with Xcode 14.3+. Zig's translate-c (Aro) does not
   define `__clang__`, so it takes the unconditional branch and fails
   on a Command Line Tools SDK. `vendor/aro_shims/cef/uchar.h` supplies
   the two typedefs CEF uses, on the CEF translation's include path
   only.

5. **An app bundle. This is not packaging — it is a hard runtime
   requirement.** The loose `zig-out/bin/sketerm-webengine` CANNOT run:
   Chromium resolves `icudtl.dat` through the framework BUNDLE, which
   it can only locate from a bundled main executable, so an unbundled
   helper dies with `icudtl.dat not found in bundle` before
   `cef_initialize` returns. The real artifact is
   `zig-out/sketerm-webengine.app`, assembled by `dist/macos-bundle.sh`
   as part of `zig build web`.

6. **A helper `.app` for child processes at all.** macOS will not let
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

## The load stall, and the run-loop findings under it (resolved 2026-08-20)

"No load-finished after navigate" was TWO stacked bugs, and chasing
them produced a measured map of how the CEF message pump behaves under
our poll loop. All of it was measured on this hardware; keep the map,
because every wrong turn below is one someone will propose again.

The two actual bugs:

1. **No renderer could ever launch** — the missing
   "Helper (Renderer).app" variant (requirement 2 above). Every
   navigation died pre-commit with ERR_ABORTED; `on_loading_state_change`
   still fired 1→0, which is why it looked like a load that "completed
   without finishing". Diagnosed by `on_render_process_terminated`
   status 4 (TS_LAUNCH_FAILED) code 1003, and by `ps` never showing a
   `--type=renderer` child.
2. **The cookie store could never initialize** — the Keychain wedge
   (requirement 3 above). With renderers fixed, every data: URL worked
   and every http(s) URL hung: CEF holds each request on a cookie load
   whose backing store was waiting forever on `SecKeychain*`.
   Diagnosed by a netlog that showed only a speculative preconnect, a
   `visit_url_cookies` enumeration that never answered, and the absence
   of any `Default/Cookies` file.

The pump-flavor matrix (measured, in case anyone proposes changing it):

- **Default NSApp pump + honest `[NSApp isRunning]`** — what ships.
  While the cookie wedge existed, a nested `base::RunLoop` bootstrapped
  `[NSApp run]` and the helper froze (main thread parked in
  `-[NSApplication run]`, captured in a `sample` stack). With the real
  bugs fixed there is nothing left to wedge on, and this flavor passes
  the whole suite including the `view_max_fps` pacing stage.
- **Overriding `isRunning` to YES** — routes every UI-thread run loop
  through the pull-events branch of `MessagePumpNSApplication::DoRun`.
  Loads unaffected, but `view_max_fps 30` measured ~10 paints/s
  (UI-thread delayed tasks themselves ticked a clean 33ms — the loss is
  in the capture pipeline). Do not re-add it.
- **`external_message_pump = 1`** — CEF's MessagePumpExternal
  TIME-SLICES nested runs (10ms, `Quit()` is a no-op), and the same
  network loads stalled again. Also breaks the pacing cap the same way.
  Do not flip it on as a "fix".

Two changes from that investigation DID ship:

- **The CFRunLoop lifeline timer** (`sketerm_web_add_iterate_timer` in
  `mac_app.m`, registered by `server.run` on macOS): one NON-BLOCKING
  server iteration per 5ms, on the MAIN run loop in common modes, with
  a re-entrancy guard (`Server.in_step`). While the poll loop runs it
  is a cheap duplicate; if any future nested loop swallows the thread
  the way the cookie wedge did, the helper keeps serving its socket
  instead of freezing. Same thread always — the single-threaded
  invariant holds.
- **`SKETERM_WEB_LOG=verbose|info`** raises `settings.log_severity`
  (which otherwise beats any `--log-severity` on the command line);
  pair with `--v=1` for VLOGs. This is the tap that made every
  diagnosis above possible.

Two macOS-only behaviours surfaced once loads worked:

- **Permission prompts REACH the client here.** On Linux the alloy
  windowless browser denies internally and `on_show_permission_prompt`
  never runs; on macOS it runs, so smoke-web stage 22g is a real
  allow/deny round trip on this platform (and still the
  engine-denies pin on Linux). The handler had a latent use-after-free
  ONLY reachable here: `Continue()` dismisses the prompt REENTRANTLY
  (`on_dismiss_permission_prompt` runs inside the cont call), so
  `resolvePerm` now takes the slot before continuing and owns the one
  release.
- **`ev_permission` for geolocation arrives without any OS location
  service involvement** — the deny path is fully client-controlled.

## Building it

```bash
zig build fetch-cef      # macosarm64 minimal tarball, checksum-pinned
zig build web            # -> zig-out/sketerm-webengine.app
zig build smoke-web      # drives the .app (all stages pass)
```

`dist/macos-bundle.sh <out> <exe> <cef-release-dir> [--copy]` builds the
bundle standalone. It symlinks the 224MB framework by default (a dev
loop wants that); `--copy` makes a shippable bundle.

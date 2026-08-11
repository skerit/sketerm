# src/web — the CEF browser helper

`sketerm-webengine` is the ONLY binary that links CEF. The GUI and the
daemon never see a CEF type; frames and input cross a unix socket in the
wire protocol defined by `protocol.zig`. The GUI side of the browser is
`src/ui/webface.zig` (read its header — it documents presentation and
pacing in full); the MCP `web_*` tools are in `src/ipc/`.

The split is for **crash isolation**: a browser-engine crash must not
take down the terminal and every shell running in it. It is NOT because
libcef needs GTK3 — `ldd libcef.so` shows no GTK at all, in both the
upstream and the distro build. That claim was wrong and cost a design
argument; do not repeat it.

## Startup order is not negotiable

`main.zig` does these in this exact order, and each step exists because
skipping it produced a silent hang or an abort:

1. **Re-exec with `LD_PRELOAD=libcef.so`.** Zig emits libc BEFORE libcef
   in `DT_NEEDED`, and libcef's zygote resolves `dlsym(RTLD_NEXT,
   "close")`, misses glibc and aborts with SIGTRAP. `LD_PRELOAD` can
   only be set before the loader runs, hence a re-exec guarded by
   `SKETERM_WEB_PRELOADED` (CEF's own subprocesses inherit the guard).
2. **`cef_api_hash` — the first libcef call of the process.** It
   configures the API version. Without it `cef_execute_process` spins
   forever making zero syscalls.
3. **Parse OUR arguments BEFORE `cef_execute_process`.** Chromium
   rewrites the process's argv BLOCK in place (switches first,
   positionals after) as soon as its command line carries a switch it
   acts on early — an explicit `--ozone-platform=` is one. Parsing
   afterwards reads `--socket /path` back as `--socket --cache-dir`, so
   the helper binds a socket literally named `--cache-dir` and the
   client waits forever.
4. **Hand the same argv to `cef_execute_process` AND `cef_initialize`.**
   Chromium's global command line is initialised by whichever runs
   first; switches missing there are silently ignored, and a browser
   process that keeps its GPU process paints EMPTY frames in windowless
   mode.

## Ozone platform decides whether a GPU exists at all

Measured, not inferred:

- `--ozone-platform=headless` — **no `--type=gpu-process` is ever
  spawned.** Everything rasterises on the CPU. `--enable-gpu`,
  `--ignore-gpu-blocklist` and `--use-angle=` change nothing, which is
  also why an old experiment concluded `--disable-gpu` "does nothing":
  the GPU was already gone.
- `--ozone-platform=x11` — a GPU process appears but hands out no
  shared textures, so no dma-buf path.
- `--ozone-platform=wayland` — a GPU process appears and
  `on_accelerated_paint` delivers dma-buf planes with modifiers. This is
  the only configuration with real GPU rasterisation.

So a headless smoke run exercises the software path by construction. It
cannot prove anything about the GPU path.

## Pacing: the engine paces itself

CEF's internal scheduler owns painting; the cap travels as
`view_max_fps` and is applied with `set_windowless_frame_rate`.

**Do not make external begin frames the default again.** With
`external_begin_frame_enabled` the paint landed only on the 2nd-3rd
begin frame REGARDLESS of their spacing — immediate-on-input, 0.3/5/10/
15ms bursts and `windowless_frame_rate` from 60 to 1000 all measured the
same constant ~30ms of added input-to-paint latency, against 5-19ms for
the internal scheduler. That is the "hovering a button takes a few
frames" bug. The numbers live at `externalPacingLatency` in
`cefhost.zig`; `SKETERM_WEB_EXTERNAL_BEGINFRAME=1`/`=0` still forces
either mode for A/B work.

`windowless_frame_rate` also bounds the frame CAPTURER, not just the
scheduler, so it throttles externally paced frames too.

An idle page must keep costing nothing: the scheduler paints only on
damage (smoke-web stage 20 asserts zero paints on a static page), and a
hidden view is stopped outright by `view_hide`.

## The canvas is opaque only if the BROWSER says so

A windowless CEF browser defaults to a TRANSPARENT canvas, so a page
that specifies no background of its own paints `(0,0,0,0)` everywhere
and a screenshot of a perfectly healthy page comes back uniformly
black (its tree, text and clicks all work — the pixels are simply
transparent). `cefhost.createViewAt` therefore sets
`cef_browser_settings_t.background_color = 0xffffffff` per browser.
`CefSettings.background_color` in `initialize` is documented as the
fallback for a zero value there and has been opaque white all along,
but measurably does NOT reach an alloy windowless browser. smoke-web
stage 22c is the guard, and every other stage styles its own
background, which is why this survived so long.

## DevTools cannot be an OSR view on CEF 151 (measured)

`devtools_show` (0xA2) asks for the inspector as ANOTHER windowless
view — same window info as `createViewAt`, our own client, its own view
id — so it would paint, resize and close through the frames every view
already uses, and **no debugging port is ever opened**. That is the
design, and the helper still takes that path first.

CEF refuses it. MEASURED 2026-08-11 on CEF 151.3.16 (the Arch `cef`
package AND the pinned upstream tarball, identically):
`show_dev_tools` with `windowless_rendering_enabled = 1` logs
`Windowless rendering is not supported for this DevTools window` from
`chrome_browser_delegate.cc` and creates an ORDINARY WINDOWED DevTools
browser instead — `is_window_rendering_disabled()` on the browser that
arrives in `on_after_created` answers 0. `runtime_style` is already
`ALLOY` (what `SetAsWindowless` sets) and the inspected browser is
itself windowless, so there is nothing left in the window info to
change. Do not "fix" this by adding `--remote-debugging-port`.

So `adoptBrowser` checks the browser it is handed and, when the engine
went windowed, keeps the view **without a frame buffer** purely to own
the browser, and answers `ev_devtools_view` with `devtools = 0, reason
= "windowed"`. Two consequences that are load-bearing:

- The view must STAY in the table. Releasing our reference and
  forgetting the browser leaves it open at `cef_shutdown`, which kills
  the helper on a signal (smoke-web stage 23 caught exactly that).
- A second `devtools_show` for the same page must be ANSWERED. CEF only
  FOCUSES an already-open inspector and creates no browser, so
  `on_after_created` never fires again; the helper answers from
  `has_dev_tools()`/the tracked view instead, and an engine that
  promises a browser and never delivers one is answered by the
  `adopt_timeout_ms` arm of `Host.watchdog`. Every path answers exactly
  once — a GUI blocks a menu item on that reply.

`print_pdf` (0xA4) has no such caveat: `print_to_pdf` writes the file
and the completion callback is correlated BY PATH, because CEF's
callback carries no request id.

## Presentation belongs to GTK, not to us

Frames are `GdkTexture`s on a `GtkPicture` (`webface.zig`). **Never
present them through a `GtkGLArea`.** A GL area's framebuffer is sized
at GTK's INTEGER scale factor (2 on a 1.5x output), so a frame the
engine rendered at the true fractional scale gets upscaled 1.5->2 by the
pass and then downscaled 2->1.5 by the compositor: two resamplings, and
the "text is soft" bug. Measured at 1.5, a 1px-stripe page left the
engine with hard 0/255 edges and reached the screen as `[5,117,127]`
mush. The texture must also sit ON the device pixel grid — a half-pixel
offset destroys 1px detail into uniform gray on its own.

## Measuring anything here

- **This shell exports `LIBGL_ALWAYS_SOFTWARE=1` from `pty.zig`.** Any
  GUI launched from inside a sketerm pane silently renders on llvmpipe,
  which has inverted these results more than once (`glTexSubImage2D` is
  a synchronous memcpy there while GTK's texture upload defers). Use
  `env -u LIBGL_ALWAYS_SOFTWARE` and check the renderer string.
- A host without `/dev/dri` has no GPU path at all; smoke-web stage 24
  reports the software fallback rather than failing, so read it.
- `SKETERM_WEB_STATS=1` prints a per-second line with delivered fps,
  client-side cost, bytes uploaded, GPU imports, requests and TICKS.
  Read `ticks` first when it looks slow: it is the rate the COMPOSITOR
  will present at and it caps everything else (GSK's Vulkan renderer
  measured roughly half the ngl renderer's tick rate on a 4K surface).
- `SKETERM_WEB_PACE=1` logs pacing transitions and aborts if a demoted
  face kept its tick. `SKETERM_WEB_LAT=1` runs the hover latency probe.
- `zig build measure-web` is the latency/sharpness rig; it reproduces a
  fractional 1.5x desktop through sketerm's own compositor.

## Build and packaging

`zig build web` needs CEF: either `zig build fetch-cef` (the pinned
upstream tarball, checksum-verified into the build cache) or a system
install via `-Dcef-include=/usr/include/cef -Dcef-lib=/usr/lib/cef`.
`-Dcef-runtime-dir` points the rpath and the `LD_PRELOAD` re-exec at the
installed location. The Arch package depends on distro `cef` and builds
against it, which is what the user actually runs — **verify smoke-web
against both**, since upstream ships WITHOUT proprietary codecs (no
H.264/AAC) while the distro build enables them.

## Rules that outlive any one change

- The wire protocol is **append-only**: new frame tags and capabilities,
  never a renumbering or a version bump. `protocol.zig` is the source of
  truth (`docs/proposal-browser-protocol.md` is an untracked design doc
  and may be absent). `view_create_url` (capability `view-create-url`)
  is the worked example of the rule: the initial url had to be a NEW
  frame, because adding a field to `view_create` would have changed an
  existing frame's layout.
- **`view_discard` destroys the BROWSER, never the view.** The record
  (id, geometry, scale, fps cap, user zoom, url) survives so the client
  sees a reload and nothing else; `dropBrowser` is the shared teardown
  and `spawnBrowser` the shared (re)creation, which is what keeps a
  revived view identical to a fresh one. Two consequences that are
  accepted, not bugs: the NAVIGATION HISTORY is gone (a fresh browser
  has none, and keeping it would mean keeping the browser), and a
  discarded view must ANSWER every request it cannot serve —
  `discarded_msg` for the semantic frames, an empty final
  `ev_find_result` for find — because a client waiting on a reply frame
  has no other way out. Only show/navigate/nav-action/input revive; a
  resize records the new geometry and a `frame_request` is ignored, so
  a background pane cannot resurrect itself.
- **A view opened at a url must not hold about:blank first.**
  `view_create` + `navigate` mints TWO documents, and the blank one
  finishes loading immediately — any client settling on "a url is loaded
  and nothing is in flight" can be answered by it, which is how
  `web_open` once returned a first snapshot of an empty page. Clients
  that create views after the handshake (`webdrive.zig`) use
  `view_create_url`; the GUI face creates its view the moment the socket
  connects, before the `hello_ack` that would advertise the capability,
  so it stays on create-then-navigate and the settle in `mcp_web.zig`
  sees past the blank document instead.
- CEF types stay inside this directory — that seam is what keeps a
  future engine swap to a new helper binary rather than a rewrite.
  `semantic.zig` and `semantic.js` in particular must stay engine-free.
- The semantic layer COALESCES: spontaneous MutationObserver walks fold
  into the live shadow tree and post nothing; a snapshot request answers
  with ONE delta from the client's consumed base to the current tree
  (`semantic.View.consume`), and `SnapMode.history` opts back into the
  bounded per-revision replay. Never reintroduce unsolicited
  `sem_snapshot` pushes or client-side delta-text concatenation — text
  deltas cannot cancel, and the buffered replay measured 64KB where the
  coalesced answer was ~100 bytes (smoke-web stage 13b guards this).
  Intra-document id carry (fingerprint match anchored to a matched
  parent) is what keeps a re-rendered identical row's id stable; the
  parent anchor is the safety property, do not loosen it.
- The injected bridge script is published at context-creation time,
  before any page script runs, then unpublished, with a per-request
  nonce authenticating replies. Page scripts otherwise win the race and
  can MITM every reply. Channel integrity is guaranteed; page HONESTY
  never can be, so page content is untrusted input to every consumer.
- `--keep` must return immediately: a daemon spawning `/proc/self/exe`
  as a display keeper must never get a browser helper instead.

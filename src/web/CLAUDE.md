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

## Accessibility (0x70 block, capability "a11y")

- **Nothing streams before `a11y_enable` for that view.** Engine-side
  accessibility costs real renderer CPU, and unsolicited tree frames
  would break the backlog rule. Disable stops the stream again
  (smoke-web stage 22j asserts both edges).
- **The accessibility callbacks carry NO browser pointer** — only the
  serialized payload's `ax_tree_id` token. `axResolveView` joins on
  the token a view was last seen with and rebinds an unknown token
  only when exactly ONE view has a11y enabled; with several enabled
  views an unattributable payload is dropped, never guessed.
- The payload shapes documented at the `onAxTreeChange` section header
  were verified empirically on CEF 151 (`SKETERM_WEB_AX_DEBUG=1` dumps
  the raw value as JSON). `checkedState`/`restriction` fold into wire
  state BITS, roles map to ARIA-ish lowercase tokens (kebab-cased
  pass-through for the long tail), and `inlineTextBox` nodes are
  dropped — a child id with no node is defined as an absent child.
- **The post-disconnect drain waits on `cefhost.openBrowsers() == 0`**
  (life-span `on_before_close`), not a fixed pump count: closing an
  a11y-enabled browser needs wall-clock renderer IPC time, and
  `cef_shutdown` with a live browser hangs the helper (stage 23 caught
  exactly that).
- GUI side: `web/axtree.zig` mirrors the stream per face and
  `a11y/webproj.zig` projects the mirror onto the SESSION a11y bus as
  its own accessible application (`Socket.Embed`, Chromium's shape —
  GTK4's internal AT-SPI backend cannot host a foreign subtree).
  `zig build smoke-webax` proves that half against a real private bus
  with no CEF at all; in the GUI it is gated by `SKETERM_WEB_A11Y=1`
  until screen-reader detection lands.

## DRM: what smoke-web pins, and what it cannot

smoke-web stage 22l probes `navigator.requestMediaKeySystemAccess`
inside `certStage`, on the https page stage 22f proceeded past — EME is
a secure-context API and a `data:` url would reject for the wrong
reason. It asks three times: ClearKey/WebM as the CONTROL (Chromium
implements it in-process, so it answers "yes" wherever EME works at
all), then `com.widevine.alpha` with webm/vp9+opus AND with
mp4/avc1+aac, because upstream CEF ships without proprietary codecs and
a mp4-only probe cannot tell a missing codec from a missing CDM.

MEASURED here (2026-08, both the pinned upstream tarball and the Arch
`cef` package): ClearKey is granted, Widevine is `NotSupportedError` for
both codec families, and neither build ships a `WidevineCdm` directory
next to `libcef.so`. **The CDM is a downloaded component**, so a grant
depends on a user-data dir that a component-updater pass has populated —
which a rig on a throwaway cache directory never has. The stage
therefore reports the refusal distinctly and still passes; what it fails
on is the API not answering, or ClearKey being refused (EME gone, or
the page stopped being a secure context).

A full PLAYBACK proof needs four things this stage deliberately does not
attempt, and all four cost a live external dependency:

- A real CDM on disk (bundle `WidevineCdm/` beside `libcef.so`, or run
  a component-updater pass with network access) — until then every
  Widevine result is about the CDM's absence, not about our config.
- A licence server and an encrypted stream: `MediaKeys` +
  `generateRequest` + a `message` event answered by a real licence, then
  `setMediaKeys` on a `<video>` fed encrypted segments (the EME/MSE
  reference streams, or Shaka's public test vectors).
- Proprietary codecs, hence the DISTRO build: upstream's tarball cannot
  decode the mp4/avc1+aac the commercial services use.
- A pixel assertion that the decoded frames actually reach us. Widevine
  L1 paths can hand back protected buffers that read back BLACK through
  `on_paint`/`on_accelerated_paint`, so "the licence was accepted" is
  not the same claim as "the video is visible in a pane", and only the
  second one is what a user gets.

## WebExtensions (0xB0 block, capability "webext")

MV2/Firefox-flavor extension host. The GUI owns the FILES (install an
unpacked dir in place, or unpack an XPI under
`$XDG_DATA_HOME/sketerm/webext/<id>/`; `src/ui/webext.zig` + its
`registry.json`); the helper LOADS them and reports state. `webext_host`
(`webext/host.zig`) owns the registry, `storage.local` persistence and
the **`browser.*` dispatch seam** (`dispatchApi`, keyed on namespace —
blocking webRequest is a later arm there, and the 0xB4-0xBF frame range
is reserved for its held-request protocol; do NOT restructure the
dispatch to add it).

- **Content scripts and the `browser.*` bridge reuse the semantic
  channel, they are NOT a second transport.** `semantic.js` gained an
  `ext-*` sub-protocol; the browser process drives injection with
  `execute_java_script` (the same `sendScript` path) and receives calls
  over the same nonce-authenticated process message. Do not add a
  separate V8 extension or secret for webext.
- **This is NOT a true isolated world.** CEF's OSR/capi exposes no way
  to create a content-script world, so each extension runs in its own
  JS CLOSURE in the MAIN world (its own `browser`/`chrome`, its content
  scripts run via `new Function`). The closure isolates the API surface
  and keeps extensions from clobbering each other; it does NOT isolate
  intrinsics, so page and content script still share globals/prototypes.
  If a future CEF grows an isolated-world capi, move injection onto it;
  until then this is the ceiling, pinned by smoke-web stage 33.
- **Background pages are hidden 1x1 windowless browsers** (`View.webext_bg`):
  no frame buffer, never announced to the client, marked `was_hidden`.
  `injectBackground` runs their scripts at load end. `runtime.sendMessage`
  from a content frame is routed content->browser-process->background and
  the reply back, correlated by a process-global gid (`webext_routes`).
- **A browser process that hosted a background page must `_exit`, not
  return through libc.** MEASURED: after `cef_shutdown` returns cleanly
  (openBrowsers == 0), the normal return-through-`main` exit HANGS
  indefinitely in libc's atexit path — a CEF worker thread outlives
  `cef_shutdown` and the join never returns. `main.zig` therefore runs
  all teardown inside a block (its defers) and then calls `c._exit`.
  This was invisible until background pages existed; do not revert to a
  plain `return`.
- `getManifest`/`getURL`/`i18n.getMessage` resolve SYNCHRONOUSLY in JS
  from constants inlined into the `ext-inject` command (manifest bytes +
  the `_locales/<default_locale>/messages.json` object); storage / tabs /
  sendMessage are async (Promises), matching the Firefox `browser.*`
  shape. `browser.tabs` is a stub (empty query) in this foundation.
- Smoke-web stage 33 is the end-to-end proof (a committed fixture under
  `webext/testdata/fixture`): content script injected at document_end
  mutates the DOM + messages the background + `getMessage`; storage.local
  survives a helper restart. It serves the page from a loopback HTTP
  server because content scripts match `http://…`, never a `data:` url.

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

## Cookies and site data: what the engine will and will not do

The 0xC8 block (capability `sitedata`) is served from CEF's cookie
manager plus one request-context verb, and TWO of the four things a
site-data panel wants have no browser-process API at all. Both are
reported to the client in `EvSitedataDone.detail` rather than papered
over, and both are measured, not assumed:

- **There is no per-origin cache clear.** `cef_request_context_t` has
  exactly one cache verb, `clear_http_cache`, and it drops the WHOLE
  context. A view in a container therefore loses only that container's
  cache; a view on the shared jar loses every site's. Reported as
  `cache-whole-context`.
- **localStorage / sessionStorage / IndexedDB / Cache Storage have no
  C API.** Chromium clears them through `BrowsingDataRemover`, which
  CEF does not expose, so `Host.clearPageStorage` runs script IN the
  document instead. That only works while the view is still ON the
  origin being cleared; a request for any other origin is reported as
  `storage-skipped-origin` and nothing is claimed. Do not "fix" this by
  navigating the view to the origin first — that would load a page the
  user did not ask for.
- **Deletion goes through the VISITOR, never `delete_cookies(url,…)`.**
  The url-only form of `delete_cookies` is documented to delete host
  cookies and spare DOMAIN cookies, so "clear this site's cookies"
  would silently leave the `.example.com` ones behind. Visiting with
  `deleteCookie = 1` deletes both and yields an exact removed count.
- **`CookieJob` is the only REALLY refcounted client-side struct in
  `cefhost.zig`** (everything else is a process-lifetime static with a
  no-op refcount). `visit_url_cookies` TAKES ownership of the visitor
  reference — CEF's CToCpp wrappers transfer, they never add — and may
  drop it before the call even returns when the manager refuses. The
  job is therefore created with two references and one is released
  after the call, so the return value is still readable when the answer
  is composed. The final release is both the "visiting finished" signal
  and the free, which is why the reply is posted from there and from
  nowhere else.

Cookie VALUES never cross the wire: `ev_cookies` carries names, scopes,
flags and the value's LENGTH. smoke-web stage 28 asserts the value byte
string is absent from the frame, so a future "just add the value, it is
convenient" change fails there.

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
- **User content (0xC0 block, capability "userscripts")** is REPLACE-ALL:
  `us_script_set` carries raw `==UserScript==` sources (the helper
  parses metadata via `userscript.zig`), `us_style_set` per-host CSS
  applied instantly to live views. Injection is browser-side
  `execute_java_script` at load start (`injectUserContent`), so
  "document-start" means AT COMMIT, cosmetic hiding can flash, and
  scripts run wrapped in the page's MAIN world — no isolated world
  exists on this path, and GM_* is a no-op `GM_info` only. Cosmetic
  hiding (`filter.zig cosmeticFor`) obeys the SAME per-view shield
  gate as network verdicts. Smoke stages 28-30 assert all of it.

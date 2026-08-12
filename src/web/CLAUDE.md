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
`webRequest` is now one of its arms, added WITHOUT restructuring the
dispatch, and the blocking half is documented in its own section below).

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

## Blocking webRequest (MV2) — where the decision goes, and what it costs

`browser.webRequest.onBeforeRequest` / `onBeforeSendHeaders` /
`onHeadersReceived` with the MV2 `["blocking"]` opt. This is the API MV3
removed, and supporting it is the whole reason the extension host targets
the Firefox surface at all.

**The round trip never leaves the helper.** An extension's background
page is a hidden windowless browser THIS process owns, so a decision goes

```
CEF IO thread (on_before_resource_load, holds the request)
  -> hold slot + a byte down the wake pipe
helper main thread (next poll turn)
  -> execute_java_script into the background page
that page's RENDERER process
  -> the MV2 listener runs, returns a BlockingResponse
  -> back over the nonce-authenticated bridge
helper main thread
  -> apply to the cef_request_t, then cont() or cancel()
```

The GUI is not involved and nothing crosses the mux wire. **There is
deliberately no `webext_request` / `webext_request_decision` frame pair**,
despite what the 0xB4-0xBF reservation originally anticipated: routing the
decision out to the client would add a socket hop, a GUI main-loop turn
and a whole "the client died mid-decision" failure mode to the most
latency-sensitive path in the browser. What 0xB4/0xB5 carry instead is
observability only — `webext_wreq_stats_req` and `ev_webext_wreq_stats`
(matched / held / cancelled / redirected / headers_modified /
headers_received_dropped / timed_out / failed_open, plus the helper's own
hold->answer p50/p95/max in microseconds).

### Precedence with the native blocker

1. `filter.zig` runs FIRST and its CANCEL is FINAL. An extension is never
   asked about a request the built-in engine already refused — MV2 has no
   "uncancel", and asking would put a JS round trip on requests decided in
   nanoseconds.
2. Extensions see everything the native engine let through.
3. Among extensions, first cancel wins and a cancel beats a redirect
   (Firefox's own resolution). v1 asks ONE extension per request, the
   first whose filters match: chaining several would multiply the round
   trip by the extension count, and the measured round trip is already the
   dominant term. Documented, not hidden.
4. The per-view shield (`intercept_enable`) gates BOTH. "Blocking off for
   this site" has to mean off.

### Every held request is answered, on every path

A request held forever is a page that never finishes loading, with no
error and no way out — the same iron rule the cert and permission
decisions follow. The exits are enumerated at `Host.wreqFailOpen` and
they are: a decision arrived; the deadline passed; the listener became
unreachable between hold and dispatch; the extension was disabled,
removed or reparsed (`wreqAbandonExt`); its background page or the
requesting view was destroyed (`wreqAbandonView`); the helper is shutting
down (`webrequestDeinit`). The hold table is 32 deep and a burst past it
fails open rather than queueing.

**The deadline is 500ms and it CONTINUES the request, never cancels it.**
A broken, wedged or slow extension must cost the user filtering, never
the ability to load a page. `SKETERM_WEB_WREQ_TIMEOUT_MS` overrides it;
smoke-web stage 34c is the canary for both halves (it fires, and it
fails open).

### Measured latency, 2026-08-12

`zig build bench-webreq`. 400 SEQUENTIAL same-origin `fetch()`es per
scenario against a loopback HTTP server, a fresh helper each time,
`--ozone-platform=headless`. Arch Linux, Zig 0.16 ReleaseFast, CEF
151.3.16 (distro `cef`), x86_64. Per-request wall time from the page's
own `performance.now()`; the helper-side number is its own hold->answer
clock.

| scenario | p50 | p95 | delta p50 | helper hold->answer p50/p95 |
|---|---|---|---|---|
| A no extension | 10.3ms | 11.3ms | — | — |
| B0 blocking listener, RequestFilter matches nothing | 10.3ms | 11.2ms | **+0us** | never dispatched |
| B non-blocking listener matching everything | 10.5ms | 11.5ms | +0.2ms | held=0 |
| C blocking, returns `{}` immediately | 11.7ms | 12.5ms | +1.4ms | 1307us / 1558us |
| D blocking, uBO-shaped work | 11.6ms | 12.8ms | +1.3ms | 1298us / 1562us |
| E = C with `SKETERM_WEB_WREQ_SPIN=1` | 10.9ms | 11.8ms | +0.6ms | 552us / 733us |

What the numbers say, plainly:

- **The short-circuit is real.** B0 registers a blocking listener that
  would cancel everything, but its `RequestFilter` names a host the page
  never touches: +0us, and the helper reports it was never dispatched.
  A request no filter matches costs one relaxed atomic load
  (`webrequest.any_listeners`) and a branch.
- **A non-blocking listener does not hold.** B reports `held=0` and costs
  0.2ms — the notification itself, delivered as a fire-and-forget mailbox
  drop whose slot is retired the moment the command is sent, not a hold.
- **A blocking decision costs ~1.3ms, and it is OUR loop, not IPC.** D
  does real uBO-shaped work (hostname map over 2000 rules, token scan,
  12 regexes) and is indistinguishable from C, which returns `{}`: the
  listener's own work is free relative to the trip. E is the proof of
  where the time goes — dropping the poll timeout from 1ms to 0 while a
  decision is outstanding cuts the helper-side trip from 1307us to 552us.
  The floor is the helper's poll/pump granularity, because the renderer's
  answer is only delivered inside `cef_do_message_loop_work`.
- **What would fix it**, in order of how much is left on the table: the
  remaining ~550us is two pump turns plus mojo; a dedicated CEF UI task
  (`cef_post_task`) would not help while WE own the message loop, so the
  real fix is a message pump that can be woken by the renderer's reply
  rather than polled. `external_message_pump` is the CEF-supported shape
  for that and is the next thing to try. Spinning (`WREQ_SPIN=1`) buys
  0.75ms of MEDIAN for a whole core, and a repeat run put its p95 at
  13.2ms against C's 12.5ms — it trades TAIL latency for median, because
  it competes with the engine for CPU. A measurement knob, not a
  default.

1.3ms per blocked subresource is acceptable for a filter list that
cancels a minority of requests and irrelevant for the ones it does not
match (they never reach JS). It would NOT be acceptable if every request
on a page paid it, which is exactly why the short-circuit is a
correctness requirement and not an optimisation.

### The onHeadersReceived ceiling (measured)

`cef_resource_request_handler_t::on_resource_response` takes NO
`cef_callback_t` and returns an int — there is no `RV_CONTINUE_ASYNC`
equivalent anywhere on the response path, so a request CANNOT be paused
while a listener in another process answers. Consequences, all of them
deliberate:

- The `onHeadersReceived` listener DOES run and DOES see the real
  response headers (stage 34d asserts it, via an `X-Stage` header the rig
  serves).
- A `responseHeaders` array it returns is COUNTED
  (`headers_received_dropped`) and dropped, not applied. Nothing pretends
  otherwise, and the counter is on the wire so a client can say so.
- The path that would fix it is taking the whole load over with our own
  `cef_resource_handler_t` and re-issuing it through `cef_urlrequest`.
  That puts credentials, cookies, ranges, streaming and redirects back in
  our hands — a far larger correctness surface than the feature buys, and
  a dead end if a future CEF grows an async response hook. Not done on
  purpose.

`onBeforeRequest` and `onBeforeSendHeaders` have no such caveat: CEF
gives ONE pre-flight callback for both, so a request needing both is
dispatched twice in sequence from the same hold, which is also MV2's
documented ordering. A redirect from the first phase skips the second,
because a redirect restarts the request and its own
`onBeforeSendHeaders` fires on the new load.

### Permissions, and where they are enforced

`webRequest` is required to register any listener and `webRequestBlocking`
to ask for `["blocking"]` — both refused at registration in
`webext/webrequest.zig` (unit-tested in both test roots), so a manifest
that did not ask cannot listen. Per REQUEST, a url must satisfy the
extension's HOST permissions as well as the listener's own
`RequestFilter`, which is why `Registry.hosts` compiles
`permissions` + `host_permissions` once. And a CONTENT SCRIPT may not
register at all — that gate lives in `cefhost.extApiCall`, because only
the engine side knows which frame a call arrived on, and a content script
runs in a page's main world where the page could reach it.

### Concurrency

`webrequest.slots` is the ONE piece of shared state in the extension
host: the main thread publishes a stable `*Registry` per extension and
CEF's IO thread reads it under `webrequest.lock` (the repo's spinlock;
`src/ui/panel/events.zig` documents why not a condvar). The registry
pointer is heap-allocated precisely because `Host.exts` is an ArrayList
that reallocates. A slot leaves the table BEFORE its registry is freed —
that ordering is the safety property. Lock order is fixed and never
nested: `webrequest.lock` is taken and released before `g_wreq.lock`
(the hold table), in that direction only. Nothing allocates on the IO
thread; url, method and header JSON go into fixed buffers in the hold
slot, exactly as the intercept log does.

### uBlock Origin compatibility, measured 2026-08-12 against uBO 1.73.0

The real Firefox MV2 build
(`uBlock0_1.73.0.firefox.signed.xpi`, sha256 `bccc51a7…4786a`), unpacked
and read — not recalled. **uBO does not run today, and blocking
webRequest is not what stops it.** It fails before any of its own code
executes:

- Its manifest parses fine with our parser (`ok = true`, enabled), and
  `hasPermission(webRequest)`/`webRequestBlocking`/`<all_urls>` are all
  true.
- But its background is **`"background": {"page": "background.html"}`**,
  and `injectBackground` iterates `background.scripts` only. The hidden
  browser is spawned, is handed an empty script list, and uBO's
  `lib/lz4`, `js/vapi.js` and `js/start.js` are never loaded. Silently:
  the extension reads as installed and enabled.
- Past that, `js/start.js` is `type="module"` with 20+ static `import`s.
  `semantic.js` runs background scripts as `new Function(...)`, where a
  static import is a SyntaxError — and the imports are real fetches
  against a `chrome-extension://` origin that **no scheme handler
  serves**. `runtime.getURL` returns such a url and nothing answers it.
- Its content scripts fail independently and quietly:
  `js/vapi-client.js` opens with `browser.runtime.connect(...)`, and we
  have no Port API, so the catch path calls `vAPI.shutdown.exec()` — uBO's
  content script deliberately tears itself down.

The webRequest surface it needs, against what now exists: it registers
nine listeners, and the two that matter are
`onBeforeRequest` `{urls:['http://*/*','https://*/*','ws://*/*','wss://*/*']}`
`['blocking']` (`js/vapi-background.js:1231`) and `onHeadersReceived`
`['blocking','responseHeaders']` (`js/traffic.js:1355`). The first is
fully supported; the second runs but cannot apply its decision (above).
It also reads `browser.webRequest.ResourceType.WEBSOCKET` at construction
time (`vapi-background.js:34`) — hence that object is a real value in the
bridge, not a stub. `onBeforeSendHeaders` it never registers in 1.73;
`filterResponseData` it feature-detects and degrades without (there is no
CEF equivalent, so HTML filtering stays off permanently).

The rest of the gap, in the order that would move it furthest:

1. Execute `background.page` (fetch the HTML, run its `<script src>` in
   order). Without this nothing else matters.
2. A `chrome-extension://<id>/` scheme handler over the unpacked dir, and
   load the background page AT that origin. Unblocks ES modules, `fetch`,
   `getURL`, `web_accessible_resources`, popup and options pages at once.
3. `runtime.connect` Ports — every content script self-destructs without
   them, so cosmetic filtering and scriptlets are dead regardless.
4. Per-frame content-script injection: `sendScript` targets
   `get_main_frame` only, so `all_frames: true` is parsed and not
   honoured. Ad iframes are the point.
5. Real `tabs.query`/`get` + `onUpdated`/`onRemoved`/`onActivated` and
   `webNavigation.getFrame`/`getAllFrames`. uBO's `PageStore` is keyed on
   tab ids; with `query -> []` its per-site state and logger stay empty
   even when blocking works.
6. `storage.local.get` honouring OBJECT defaults (we return only stored
   keys, so uBO's first-run defaults come back `{}`), `alarms`, `menus`,
   `browserAction`, `windows`.

Also absent and used by uBO, all of which it feature-detects and degrades
without: `storage.session`/`managed`/`sync`, `privacy`, `dns`,
`contentScripts.register`, `commands`. Its `i18n.getMessage` works but
does no placeholder substitution, so `$1`-bearing strings render wrong.

Two items on that list are CEILINGS rather than TODOs: the shared-world
injection (the CEF OSR limit already documented above) means uBO's
scriptlets and page scripts share intrinsics, and `filterResponseData`
has no CEF equivalent.

What this stage's own fixture verifies instead, since uBO cannot load:
smoke-web stage 34 exercises the same API surface uBO relies on —
`onBeforeRequest` blocking with cancel and redirect, `onBeforeSendHeaders`
with `requestHeaders` rewriting, `onHeadersReceived` with
`responseHeaders`, `<all_urls>` filters, and a listener returning a
Promise. What remains unverified against real uBO is everything above:
its module graph, its Port traffic, its per-tab bookkeeping, and the
interaction of its filter engine with ours.

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

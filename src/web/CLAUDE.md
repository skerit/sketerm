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
  (smoke-web stage 22k asserts both edges).
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
  with no CEF at all.
- **Whether it runs at all is `a11y/detect.zig`, never an inference.**
  It reads `org.a11y.Status` (`ScreenReaderEnabled`, else `IsEnabled`)
  on the SESSION bus, and asks `NameHasOwner` FIRST because
  `org.a11y.Bus` is ACTIVATABLE — a bare property read would start the
  accessibility stack on a desktop that has none. Every failure resolves
  to OFF. `SKETERM_WEB_A11Y` overrides both ways. The probe is a D-Bus
  round trip, so it runs on the same detached worker as the bus connect,
  never on the main loop; a negative answer is cached for 30s only, so a
  reader started later is picked up without a restart.
- **Events are DIFFED against a shadow, and the first publish is
  silent.** A reader that just embedded learns the tree by walking it;
  replaying it as thousands of children-changed signals is pure noise.
  A change bigger than the threshold collapses to one children-changed
  on the root, because a navigation would otherwise emit a per-node
  storm saying the same thing. `Proj.publish` is called after every
  applied frame and is linear in the tree — it deliberately keeps no
  parent in the shadow, since resolving one per node per frame made it
  quadratic in page size.
- **A projected `Action.DoAction` routes OUT through `on_action`**, it
  does not act: `webproj` must not learn how to reach an engine (that is
  what keeps it GLib-free and lets the smoke rig substitute a hook). The
  GUI turns it into real `input_pointer` frames at the node's resolved
  centre — the same trusted path a human click takes, and deliberately
  NOT a DOM `click()`, which is not user-activated and which pages
  reject. The helper keeps no AX tree, so resolving a node to a point is
  necessarily the CLIENT's job. `Component.GrabFocus` stays `false` on
  purpose: the only trusted route back is a pointer event, and clicking
  an element to focus it would also activate it.
- **`org.a11y.atspi.Text` counts CHARACTERS; the wire counts UTF-16.**
  `ev_a11y_caret` (0x76, capability `a11y-caret`) carries the caret and
  selection as UTF-16 code units — the unit the DOM itself defines text
  offsets in, so no engine has to convert — and `axtree.zig` turns them
  into character offsets because it is the only layer that also has the
  node TEXT. Converting at the bus boundary is not pedantry: an
  unsnapped byte offset can split a codepoint, and D-Bus rejects a
  string that is not valid UTF-8, so the whole reply would vanish.
  libatspi reads the caret through the `CaretOffset` PROPERTY, not
  `GetCaretOffset`; both are served, but that is the one that runs.
- **MEASURED CEILING (CEF 151, 2026-08-12): a text SELECTION is
  reported collapsed, and there is no second source for it.**
  `tree_data`'s `sel_anchor_*` / `sel_focus_*` track the caret
  correctly, but the extent never arrives — measured three ways, all in
  smoke-web stage 36: an `<input>` via `setSelectionRange(2,6)` gives
  `a=2@2 f=2@2`, a contenteditable via a DOM Range 2..6 gives
  `a=5@2 f=5@2`, and real shift+Right events give no frame at all.
  Contenteditable is NOT a working case — do not read the collapsed
  contenteditable frame as one. The node attributes carry no
  `textSelStart` / `textSelEnd` either; `axEmitUpdate` (not
  `axPutNode`) looks for them and prefers them for the focused field,
  which is forward-looking code that does nothing until some engine
  fills them in. The "no selection" sentinel the code actually honours
  is `sel_focus_object_id == 0`, not a numeric offset. The wire, the
  mirror and `org.a11y.atspi.Text` all carry a real range — smoke-webax
  proves that half against a live bus — so a braille display gets the
  caret and not the range purely because of the engine.

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
`registry.json`); the helper LOADS them and reports state. `registry.json` is rewritten WHOLE, so every read-modify-write of it
runs inside a `flock` on `<webext dir>/.registry.lock`
(`webext/registry.zig`) and applies its change, keyed by extension id,
to what is on DISK rather than to `g_exts`. The per-extension install
lock cannot cover this: two processes installing DIFFERENT extensions
hold different locks, both read the old array and one entry vanishes.
`webext_host`
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
- **An extension gets a real ORIGIN, and its scheme is
  `sketerm-extension://`, NOT `chrome-extension://`.** MEASURED on CEF
  151.3.16 (2026-08-12): `add_custom_scheme("chrome-extension")` returns
  **0** — Chromium owns the name and refuses client registration, and
  CEF's alloy runtime has the extensions component removed, so nothing
  else serves it. `cef_register_scheme_handler_factory` still answers 1
  for it, which is the trap: registration LOOKS fine and every load then
  fails `ERR_BLOCKED_BY_CLIENT` with the factory never once consulted.
  `SKETERM_WEB_SCHEME_DEBUG=1` prints both return values. Firefox has
  its own name too (`moz-extension://`), so extensions cope — they build
  urls with `runtime.getURL`. One that hard-codes the literal
  `chrome-extension:` does not, and that is a real limitation.
  - The HOST is not the id: `uBlock0@raymondhill.net` and
    `{7a7a4a92-…}` are both illegal in a url host, so
    `manifest.originHost` hashes the id to 16 hex digits. Firefox splits
    these the same way (a per-install UUID in the url, the author's id
    in `runtime.id`).
  - The origin table (`webext/origins.zig`) is read from CEF's **IO
    thread**, same shape and same reasoning as `webrequest.slots`, but
    storing the directory BY VALUE so the IO thread never dereferences
    main-thread memory. The negotiated locale is published with it
    because that thread must not scan a directory per request.
  - **An extension's own origin is never filtered.** `filter.zig` and
    the webRequest path both skip it (`onBeforeResourceLoad` returns
    early). It is not web traffic, Firefox draws the same line, and a
    filter list that could block a background page would disable
    extensions at random.
  - **A load with NO frame is the extension's own.** A Web Worker's
    script, a `cef_urlrequest`, a fetch from a worker: `create` gets a
    null frame and cannot attribute the load. Refusing it 403s uBO's
    serializer worker, and `serializeAsync` then stays pending FOREVER —
    uBO's boot stopped mid-sequence with no error anywhere and simply
    never filtered. `web_accessible_resources` gates only loads that DO
    have a frame on another origin.
- **`browser`/`chrome` are published as globals only for a PRIVILEGED
  `ext-inject`** — one carrying the process nonce, which only the
  browser process (which generated the served document) can produce.
  Extension pages need the globals before their first statement;
  content scripts must NOT have them, because this is the shared main
  world and a page could then reach an extension's `storage.local`.
  A consequence, measured against Violentmonkey: a content script that
  reads `window.browser` rather than its injected closure parameter
  fails. That is the isolated-world ceiling showing through, not a bug
  with a fix short of an isolated world.
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
  They are navigated TO THE EXTENSION'S OWN ORIGIN — the author's
  `background.page` document, or a generated one listing
  `background.scripts` — so the ENGINE loads the scripts in document
  order, ES modules and all. `injectBackground` is then a no-op and
  exists only as the fallback for a helper whose scheme registration
  failed (that path cannot run a module, and says so).
  `runtime.sendMessage` from a content frame is routed
  content->browser-process->background and the reply back, correlated by
  a process-global gid (`webext_routes`); `tabs.sendMessage` is the same
  table with the roles swapped.
  - The API bootstrap is a CLASSIC `<script src>` at a reserved path
    (`origins.BOOTSTRAP_PATH`), spliced into every extension HTML
    document ahead of every author script. It is not inline because it
    carries the manifest and the message catalogue — uBO's catalogue
    alone is 47KB, far too much to copy out of a slot under a spinlock,
    and reading `Host.exts` from the IO thread is exactly what the
    origin table exists to avoid. A classic script still blocks the
    parser, so ordering is the same either way.
  - **`runtime.reload()` is REAL and must stay real.** uBO's first run
    ends with `vAPI.app.restart()` and a bare `return`: on a
    Chromium-flavoured browser with no stored version it deliberately
    abandons the rest of its boot and waits to be restarted. With
    `reload` stubbed to a no-op it sat forever half-initialised —
    enabled, listening, filtering NOTHING, no error anywhere. It is
    performed on the next poll turn (`Host.webextPump`), never inside
    the call, because it destroys the page whose script is mid-call.
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
  the NEGOTIATED `_locales/<locale>/messages.json` object); storage /
  tabs / sendMessage are async (Promises), matching the Firefox
  `browser.*` shape. `getMessage` expands `$1`/`$name$` placeholders on
  both sides — the JS copy exists because the API is synchronous and a
  Promise would break every caller.
- **An extension id is a label, not authority.** Each enabled extension
  instance has a random 128-bit capability. The privileged bootstrap,
  API calls and results, routed messages and replies, Ports, webRequest
  holds, events and action clicks all carry it; the helper authorises the
  capability first and then verifies the claimed id. Reinstall, toggle,
  `runtime.reload`, removal and helper restart revoke the old instance and
  mint another capability. `ext-revoke` invalidates the old JavaScript API
  object, disconnects its Ports and rejects pending and future calls, so a
  stale page cannot keep using browser authority after its extension dies.
  Keep the capability in `webext/origins.zig`'s IO-thread-owned slot rather
  than reading `Host.exts` from the IO thread.
- **Unsupported asynchronous APIs reject their Promise.** A resolved no-op
  lies to feature detection and lets an extension continue under false
  assumptions. `runtime.getPlatformInfo` and `getBrowserInfo` are real
  resolved values; explicitly unsupported tabs/windows/menus/navigation/
  notification/command/permission methods reject with their API name.
- **`browser.tabs` is real, and the GUI owns it.** The client posts its
  WHOLE tab list as `webext_tabs` (0xB6, capability `webext-tabs`);
  `webext/tabs.zig` DIFFS it against what it held and synthesises MV2's
  `onCreated`/`onUpdated`/`onRemoved`/`onActivated`. Replace-all, like
  `us_script_set`: one frame, no incremental protocol to desynchronise,
  and the events are a function of two consecutive tables rather than of
  a sequence a dropped frame could break. The payload is a JSON array
  because this wire has no repeated-field encoding and a tab list
  changes a few times a minute.
  - **`tabId` is load-bearing, not decoration.** MV2 defines -1 as "not
    associated with a tab", and uBO's `onBeforeRequest` reads exactly
    that: `if (tabId < 0)` it takes its behind-the-scene path. With the
    old hard-coded -1 it CANCELLED the top-level navigation of every
    page. `view` in the tab record is what maps a helper view back to a
    tab, and it is also how `sender.tab` is answered.
  - **`documentUrl`/`originUrl` are OMITTED for a main-frame request**,
    as MV2 does. Sending the view's previous url there (`about:blank` on
    a fresh view) makes a page third-party to ITSELF and uBO
    strict-blocks the navigation.
- **A `RequestFilter` belongs to ONE listener.** `needFor` returns the
  ids of the listeners whose own filter matched and the frame runs only
  those. This is not a refinement: uBO registers a guard on
  `onBeforeRequest` filtered to its own `web_accessible_resources/*`
  that cancels anything arriving without a secret, so "some listener
  matched, run them all" cancels every page on the web.
- `browserAction` / `pageAction` is REAL and DISTINCT: manifest defaults,
  shared title/icon/popup state, browser-action badge/color/enabled state,
  per-tab overrides, trusted `onClicked`, `pageAction.show`/`hide`, programmatic
  `browserAction.openPopup`, and declared popup pages. A browser action is
  visible by default; a page action is hidden until shown for that tab. The
  GUI renders enabled visible actions in the focused window's focused pane
  and active page, and the helper validates the mirrored active tab before
  accepting an activation. Real process-wide `Window.id` values and
  per-window indices are published. Action state remains cached per active
  tab, but GTK presentation is a separate local gate: focus changes hide or
  restore the cached toolbar without waiting for a helper round trip, and an
  inactive split/window cannot present or activate a late snapshot.
  Popup pages are real extension-origin CEF browsers, not scraped HTML: they
  receive the same privileged bootstrap as background/options pages and
  paint through the ordinary shm/inline frame paths into a GTK popover.
  The popup id range starts at
  `WEBEXT_POPUP_VIEW_BASE` (0x60000000), disjoint from client views,
  DevTools and hidden background pages. Closing the popover posts
  `view_destroy`; destroying its owner or disabling/removing the extension
  closes it from the helper side. Action snapshots are replace-all, but the
  GTK side updates buttons in place when their ids are unchanged so a
  popup does not destroy its own anchor when it updates a badge.
  MV2 makes the two manifest keys mutually exclusive; a package declaring
  both is rejected instead of exposing two namespaces backed by one state.
  JavaScript exposes only the declared MV2 namespace: there is no MV3
  `action` alias, and page actions do not inherit browser-action-only badge
  or enablement methods.
  `openPopup` from a privileged extension page resolves the active tab in
  the focused window and asks that page's native toolbar to run the same
  activation path. It remains pending until the GUI returns the correlated
  append-only `webext_open_popup_result` (0xBB); failure text is UTF-8-safe.
  It shares ONE pending-reply table (`Host.webext_replies`) with routed
  `runtime`/`tabs.sendMessage`, so it inherits their deadline: a GUI that
  drops the 0xBB reply without the view or the extension dying rejects the
  Promise on the next expiry pass instead of parking it forever. Every
  parked extension Promise is answered on every exit — recipient gone,
  extension revoked, table full, deadline — and that is the same iron rule
  the held webRequest, cert and permission decisions follow.
  Content scripts and popup-less/hidden/disabled actions reject.
  **WebExtensions are local-browser only.** Installed-package paths
  belong to the GUI host and there is no package-transfer/remote-registry
  protocol, so remote clients suppress `webext`, `webext-tabs` and
  `webext-action` and receive no extension state. `setIcon` accepts package
  paths, not `ImageData`; popup size remains a fixed 420x520 logical pixels.
- Other namespaces an extension calls UNCONDITIONALLY are present as
  explicit rejecting stubs (`menus`, `windows`, `webNavigation`, `notifications`,
  `commands`, `permissions`, `extension`, and the notification-only
  `webRequest` events). They exist because their ABSENCE is fatal.
  `alarms` and `storage.session` are REAL (a timer and an in-memory map
  cost nothing). Anything an
  extension feature-detects — `privacy`, `dns`, `contentScripts`,
  `storage.sync`/`managed`, `filterResponseData` — is deliberately LEFT
  ABSENT, because degrading gracefully is what that detection is for.
  The cost is named: `webRequest.onResponseStarted` never fires, and
  that is where uBO injects its scriptlets.
- Smoke-web stage 33 is the content/background end-to-end proof (a committed fixture under
  `webext/testdata/fixture`): content script injected at document_end
  mutates the DOM + messages the background + `getMessage`; storage.local
  survives a helper restart. It serves the page from a loopback HTTP
  server because content scripts match `http://…`, never a `data:` url.
- Smoke-web stage 40 is the action proof: declared browser/page namespaces
  stay distinct, a hidden page action can be shown and clicked, and a trusted
  browser-action activation opens and paints a real extension-origin popup
  whose first script can call `runtime.getManifest`. It also proves
  `browserAction.openPopup`, popup-less clicks, malformed-id rejection, a
  missing popup asset failing without a view, correlated popup success/failure
  acknowledgement, capability impersonation/revocation/rotation, stale API
  rejection, unsupported Promise rejection, and both teardown directions.
  Ordinary, `about:blank`, `data:`, exact-host HTTP/HTTPS and foreign-extension
  origins cannot read the privileged bootstrap. The exact-origin
  `get_first_party_for_cookies` fallback in `extSchemeCreate` is required
  because CEF can expose the previous frame URL while a parser-blocking
  extension script loads. It must stay exact-origin: broadening it would
  reopen the bootstrap nonce to another origin.
  Smoke-e2e drives two real split panes and two real GTK toplevels: focus
  moves the sole presented action, inactive toolbars clear, the second
  window's trusted action opens its popup there, and closing it restores the
  first window's cached action.

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

### Tier-1 extension compatibility, measured 2026-08-12

Against the real signed Firefox MV2 builds, unpacked and RUN — not
recalled. `zig build fetch-webext-fixtures` downloads the pinned
uBlock Origin XPI (1.73.0, sha256 `bccc51a7…4786a`) that smoke-web
stage 35b measures; the stage reports itself SKIPPED when it is absent,
because a smoke run must not touch the network.

**uBlock Origin 1.73.0 RUNS and BLOCKS.** Stage 35b asserts it: its
module background page loads at its own origin, its filter lists parse
(~2.4s from launch), and a request the `ublock-filters` list names is
CANCELLED before it reaches the network — the loopback server counts
zero hits on the blocked path for the attempt that blocked, while the
control resource still arrives. The stage seeds uBO's own
`selectedFilterLists` through `storage.local` so it measures ONE named
list rather than whatever EasyList happens to ship this month.

Getting there took six distinct fixes, and every one of them was a
SILENT failure — the extension read as installed, enabled and `ok`
while doing nothing:

1. `background.page` was never executed at all (only `background.scripts`
   was), and its entry point is a `type="module"` with 20+ static
   imports that `new Function` cannot even parse. Fixed by giving the
   extension a real origin and letting the engine load the document.
2. Our own `on_before_resource_load` cancelled the extension origin:
   `ERR_BLOCKED_BY_CLIENT` on the background page itself.
3. The `web_accessible_resources` gate 403'd uBO's serializer WEB
   WORKER (a load with no frame), and `serializeAsync` then never
   settled — the boot stopped mid-sequence.
4. `browserAction.setIcon` was undefined; the TypeError aborted the rest
   of uBO's own startup.
5. Every registered listener ran on every dispatched request, so uBO's
   `web_accessible_resources` guard cancelled every page load.
6. `runtime.reload()` was a no-op, so uBO's first-run
   `vAPI.app.restart()` never came back.

What still does NOT work for uBO, and why:

- **Scriptlets do not inject.** `webRequest.onResponseStarted` is a
  notification-only event here and that is where uBO injects them.
- **Cosmetic filtering is limited** by the shared-world ceiling
  (below): uBO's content scripts run in the page's main world, so its
  scriptlets and page scripts share intrinsics.
- **`filterResponseData` is permanently absent** — no CEF equivalent.
- `onHeadersReceived` decisions are counted and dropped (the measured
  `on_resource_response` ceiling, still true).
- `storage.sync`/`managed`, `privacy`, `dns`, `contentScripts.register`
  and `commands` remain absent; uBO feature-detects all of them.

**Dark Reader, Stylus and Violentmonkey are NOT claimed to work.** They
load and their manifests parse; what was measured of each is recorded in
`docs/SESSION.md`. Violentmonkey specifically fails on the ceiling
above: its content scripts read `window.browser` rather than the
injected closure parameter, and publishing that global for a content
script would hand any page the extension's `storage.local`.

Two items here are CEILINGS rather than TODOs: the shared-world
injection (the CEF OSR limit documented above) and `filterResponseData`.

Stage 34 remains the fixture-based proof of the blocking-webRequest
surface itself (cancel, redirect, header rewriting, `<all_urls>`,
Promise-returning listeners, fail-open); stage 35a proves the LOADING
SHAPE of a real extension with no third-party download (module
background page at its own origin, a real static import, a package
`fetch`, Ports from two frames, object storage defaults, i18n
placeholders); stage 35b is the only one that can answer "does uBlock
Origin block a request", and it does.

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

- **A context's jar is an IMMEDIATE child of `root_cache_path`.** CEF's
  chrome runtime resolves `CefRequestContextSettings.cache_path`
  through Chrome's `ProfileManager`, which only accepts a profile
  directory whose PARENT is the user-data dir. The nested
  `{profile_dir}/contexts/{key}` this used to build was refused with a
  bare `ERROR:chrome_browser_context.cc:116 Cannot create profile at
  path` — a LOG LINE, not a failure return — so every named container
  quietly ran with no profile of its own. Nothing above the log said
  so; it was found by writing a cookie in a container and looking for
  it afterwards.
- **Reference ownership across the C API, in BOTH directions: every
  ref-counted struct that crosses the boundary carries exactly one
  reference owned by the RECEIVER.** This is what CEF's translator
  generates, not a convention: `libcef_dll/cpptoc/cpptoc_ref_counted.h`
  `Wrap()` adds "a reference to our wrapper object that will be released
  once our structure arrives on the other side", and its `Unwrap()`
  "Release[s] the reference to our wrapper object that was added before
  the structure was passed back to us"; `tools/make_ctocpp_impl.py`
  emits `CppToC_Wrap(arg)` for every `refptr_diff` argument of a client
  callback (and per ELEMENT of a `refptr_vec_diff_byref_const` such as a
  V8 handler's `arguments`, with no restore), `tools/make_cpptoc_impl.py`
  emits `CppToC_Unwrap(arg)` for every `refptr_same` argument we pass
  and `CppToC_Wrap(_retval)` for every struct we get back. So: an
  argument libcef hands one of our `callconv(.c)` callbacks is OURS to
  release (`releaseArg`, a `defer` per argument at the top of every
  callback; a callback that KEEPS the object, such as a held
  `cef_callback_t` or `on_after_created`'s adopted browser, keeps that
  very reference and adds none), a struct we pass into libcef is
  consumed (add_ref first if we still need it), and a struct returned
  to us is released when we are done. Before 2026-08-29 the callbacks
  released nothing, which measured as ~9 kB of browser-process RSS per
  HTTP request with no plateau, and `wreqConsider`/`adoptBrowser`
  add-ref'd on top of references they already owned.
- **`contextForSpawn` hands out an ADD-REF'd reference.**
  `create_browser_sync` wraps the `cef_request_context_t*` with
  `CefRequestContextCToCpp::Wrap`, which TAKES ownership (CToCpp
  wrappers transfer, they never add — the same rule `visit_url_cookies`
  documents below). Passing the registry's own reference therefore
  freed the context after the FIRST browser, and the second view in the
  same container segfaulted the helper on a freed vtable.
- **CEF 151 cannot combine shared storage with per-context proxy
  routing — this is why a browser route is a whole helper INSTANCE per
  route, not a context inside one profile.**
  `CefRequestContext::CreateContext(other, handler)` returns a distinct C
  API object for which `IsSharingWith(other)` is true, but `IsSame(other)`
  is ALSO true: the two contexts share the preference manager, so a proxy
  set on one reroutes BOTH. Measured with two real SOCKS5 tunnels: after
  installing the second context's proxy, every request — the first
  context's included — traversed that one proxy, and the first context's
  proxy saw nothing at all. There is therefore no way to give two
  storage-sharing contexts two different egress routes, and a route gets
  its own helper process with its own profile and a plain fixed-server
  proxy instead. The probe frames that measured this were removed; they
  live on the `spike/cef-routing-experiments` branch.
- **A malformed proxy preference is NOT protected by `pac_mandatory`.**
  Of the two PAC forms, only `{mode:"pac_script", pac_url:"data:..."}`
  works: it routes per-URL and fails CLOSED when the proxy is
  unreachable. The INLINE `{mode:"pac_script", pac_script:"..."}` key is
  a silent fail-OPEN — `set_preference` RETURNS SUCCESS, Chromium logs
  `Proxy settings request PAC script but do not specify its URL. Falling
  back to direct connection.`, and traffic goes DIRECT despite
  `pac_mandatory:true`. A caller that builds a proxy preference must
  validate its own shape; a success return from `set_preference` proves
  nothing about whether the traffic is actually proxied.
- **The headless MCP client now points `--cache-dir` at a DURABLE
  store**, not at its volatile instance dir: `$XDG_STATE_HOME/sketerm/
  web-profiles/<instance-key>/` (`src/ipc/webprofiles.zig`). No helper
  code changed — CEF simply requires a persistent context's
  `cache_path` to be a child of `root_cache_path`, so the jars can only
  live under the helper's own cache dir. That client refuses a named
  profile outright unless BOTH `contexts` and `contexts-fail-closed`
  are advertised, because with only the first an unknown context
  silently resolves through the shared jar. Context 0 stays an
  in-memory jar in both modes (`settings.cache_path` is never set), so
  without a profile nothing about a browsing session survives the
  helper.
**Enforced network policy (0x86 block, capability `net-policy`).** The
pure decision half lives in `src/web/netpolicy.zig` (std-only, both
test roots); the gate runs it inline in `on_before_resource_load`, so a
refusal cancels a request BEFORE any socket is touched. Enforcement
order on that path is filter engine -> policy -> extension webRequest:
a filter or policy cancel is final and an extension is never asked.
Facts that bound the design, each measured:

- **CEF re-enters `on_before_resource_load` for a server redirect**,
  with the request IDENTIFIER unchanged across the chain (the
  completion callback matches the FIRST ring entry). The ordinary host
  gate therefore IS the redirect defence — no `on_resource_redirect`
  handler exists — and "a live ring entry already carries this id" is
  what names a denial `redirect_host`.
- **Response-side ceilings are real:** headers cannot be held
  (`on_resource_response` has no callback) and a body cannot be
  pre-empted, so `max_bytes` is accounted in
  `on_resource_load_complete` and means "the response that CROSSES the
  cap completes; the NEXT request is refused". The `deadline_ms` sweep
  (`flushNetPolicy`, once per poll) issues one `stop_load` for a load
  already streaming past its deadline.
- **Slot-less traffic is unpoliced** (service workers, `cef_urlrequest`
  — and, measured live: CEF's favicon fetcher probes through a
  browserless URLRequest BESIDE the browser-path favicon request the
  gate correctly denies). The per-context
  `cef_request_context_handler_t::get_resource_request_handler` is the
  follow-up that would close this lane.
- **Private-address refusal is LITERAL only** (loopback/RFC1918/
  link-local/ULA text, `localhost`/`*.local`/`*.internal`): no
  resolver runs on this path, so a hostname that merely RESOLVES to a
  private address passes the address check — the positive host
  allow-list is the real defence, and the tool description says so.
- The policy install is `net_policy_set` BEFORE the `view_create*`
  naming the view (frame order is the guarantee; there is no ack); the
  slot is found-or-created so the pre-create frame sticks — the same
  fix `intercept_set` needed for a pre-create shield toggle.

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
- **`CookieJob` and subscription `FilterFetch` are the REALLY refcounted
  client-side structs in `cefhost.zig`** (everything else is a
  process-lifetime static with a no-op refcount). `visit_url_cookies`
  TAKES ownership of the visitor
  reference — CEF's CToCpp wrappers transfer, they never add — and may
  drop it before the call even returns when the manager refuses. The
  job is therefore created with two references and one is released
  after the call, so the return value is still readable when the answer
  is composed. The final release is both the "visiting finished" signal
  and the free, which is why the reply is posted from there and from
  nowhere else.

Cookie VALUES never cross the wire: `ev_cookies` carries names, scopes,
flags and the value's LENGTH. smoke-web stage 31 asserts the value byte
string is absent from the frame, so a future "just add the value, it is
convenient" change fails there.

## Cookie synchronisation across helper instances (0xE0 block, capability "cookie-sync")

A browser ROUTE is a whole helper INSTANCE with its own profile (the
measurement two sections up is why). That buys routing correctness by
construction — a Tor instance has no direct path — and costs a shared
identity, because separate profiles mean separate cookie jars. This block
buys the identity back. The GUI subscribes each client with
`cookie_sync_enable` and fans every observed change out to the others;
the helper never talks to another helper.

Four facts, each measured, each load-bearing:

- **`can_save_cookie` sees `Set-Cookie` RESPONSE HEADERS AND NOTHING
  ELSE.** A `document.cookie` write never touches the network stack, so
  there is no resource request to filter and the filter never fires;
  neither does anything see a script-side DELETE, since no response
  header carries a removal. Measured by running smoke-web stage 42 with
  the reconcile pushed out to 600s: the header phase still passed and the
  script phase failed with "a document.cookie write reached NEITHER
  observer". A header-only implementation therefore loses every
  JS-set token and every logout, silently. Both observers are required.
- **The reconcile is the other half.** A periodic `visit_all_cookies`
  walk per context, diffed against a shadow of last-known state
  (`SKETERM_WEB_COOKIE_SYNC_MS`, default 3s). Header writes are still
  emitted immediately and folded into the same shadow, so the walk does
  not re-emit them.
- **Loop prevention is STRUCTURAL, not a timing window.** An apply marks
  the identity `pending` BEFORE the engine call and settles the shadow in
  the engine's completion callback, so a reconcile landing between the
  two skips that identity — neither ordering of the two async events can
  emit a spurious change. Two normalisations the engine forces: the
  shadow is keyed on the DOTLESS domain (`set_cookie` with a non-empty
  domain reads back with a leading dot, so 140 applies looked like 140
  removals plus 140 adds), and a settled apply sets a one-shot `adopt`
  flag so the engine's own rewriting is learned silently. Measured: 283
  forwarded changes before, 1 after, then zero.
- **Two engine limits that read as bugs in our code.** Chromium CLAMPS a
  cookie expiry to 400 days, so a far-future date comes back as
  today+400d and looks like a dropped expiry; and `set_cookie`
  re-stamps `creation`/`last_access`, so those two do not survive a round
  trip. Everything that matters does: value, `Secure`, `HttpOnly`,
  `SameSite`, priority, path, domain, expiry and persistence.

Deletion goes through `delete_cookies(url, name)` — the NAMED form,
because the url-only form spares domain cookies, which is exactly how a
logout fails to propagate. `cookie_dump_req` is PAGED (`SYNC_DUMP_PAGE`
128 cookies or `SYNC_DUMP_PAGE_BYTES` 512KB, whichever first) so a large
jar seeds a new instance without one enormous frame; the cursor is an
index into the engine's visit order, so a write between pages can shift
the tail by one — it is a seed the change stream then keeps current, not
a transactional snapshot. A value over 4096 bytes is skipped by the
IO-thread mailbox (fixed buffers; nothing allocates on CEF's IO thread)
and picked up by the reconcile instead — late, never truncated.

Nothing streams before `cookie_sync_enable`, and `cookie_sync_enable{0}`
stops both the walk and the IO-thread observer: the reconcile is linear
in jar size per pass, so a client that subscribes and never unsubscribes
pays it forever. smoke-web stage 42 is the proof, across two real
helpers with separate `--cache-dir`s.

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
- **Reader semantic ids extend the semantic block at 0x6A-0x6C,
  capability `reader-ids`.** `sem_read_ids` (0x6A) leaves the legacy
  `sem_read` untouched; `sem_read_ids_result` (0x6B) carries the same useful
  markdown plus `doc_gen`, `rev`, and structured section/heading/link/
  item records `{id, guard, kind, text, url}`. The ids are allocated by
  `semantic.View`, exactly the space `sem_act` resolves. `guard` is an
  opaque action fingerprint that includes element identity and the exact
  link target; clients must
  round-trip it but never present or interpret it. `sem_act_guarded`
  (0x6C) solicits a fresh walk, then requires the exact document,
  revision, stable id and guard before delegating to the normal trusted
  action path. Any mismatch answers the existing `sem_act_result` with
  `ok=0` and a stale-reader message, never an action on a lookalike.
  Clients remember every ID ever exposed by rich reader mode for that
  helper view. A later rich read refreshes IDs it contains and marks
  absent reader IDs deliberately stale; snapshots never erase reader
  provenance, and navigation, stop, discard, crash or helper loss
  invalidates the remembered guards without allowing an ordinary
  `sem_act` fallback.
  `mcp_web.zig` chooses this pair only when the capability was
  advertised; otherwise it explicitly uses `sem_read` and reports the
  markdown-only fallback. Never infer a rich envelope from page bytes:
  legacy markdown can itself be valid JSON.
  The allocation was audited against `Tag` and its full git history:
  0x6A was explicitly left unused when `sem_eval` moved to the 0xA0
  debugging block, 0x6B/0x6C were never assigned, and 0xD0-0xD7 stays
  reserved for the remote-helper inline-frame family.
  Semantic requests are navigation-generation stamped: snapshots,
  hints and both read forms are reissued after the fresh main document
  loads, while actions/eval/expand are explicitly failed. Renderer
  replies also carry the browser generation and a per-context document
  token, so a late dying-context reply cannot satisfy the reissued
  request. Every pending request has a 120s helper deadline and is
  answered/freed on timeout, renderer crash, browser drop and teardown.
  `semantic-request-ids` adds `sem_request`/`sem_result` at 0x6D/0x6E:
  an append-only envelope around the unchanged legacy payloads, carrying
  a client operation id end to end. New clients match that id; with an
  older helper, a timed-out operation kind stays quarantined until its
  one uncorrelated late reply is consumed or the connection resets.
- **A held security decision must always be answered.** A certificate
  error (`ev_cert_error`) and a permission prompt (`ev_permission`)
  both keep an engine callback alive in `View` until a
  `cert_decision` / `permission_decision` resolves it, so every exit
  path answers: `freeView` cancels/denies whatever is still held, and
  `on_dismiss_permission_prompt` drops a slot the engine took back
  WITHOUT calling into a spent callback. The engine's own reference is
  released at the same moment. Nothing about a decision is remembered
  helper-side — no cert exception, no allowed origin — because a
  stateless render helper is the wrong owner for a stored security
  decision; the GUI remembers permissions in memory and a
  `SiteSettingSink` is where persistence plugs in.
- **`ev_popup_request` carries an OPTIONAL TRAILING `user_gesture`
  byte**, and its decoder treats a short payload as "field absent,
  assume a gesture". That is the only frame on this wire allowed to
  grow, and only because the reader tolerates the old length: an
  existing field may still never be widened, reordered or removed.
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
  - **Ids are bound to the ELEMENT for the document's lifetime**
    (`View.eid_sids`), not to membership of the walk. A modal that makes
    the page inert (`aria-hidden`) removes every node from the walk and
    hands them back later; before this they came back renumbered and a
    700-line page was re-sent as `-` plus `+` for a Escape keypress
    (measured 2026-08-27 against a zenit-cms panel: more than half of a
    250-call session's tokens). The consumed base likewise KEEPS entries
    for nodes that left (`present = false`, purged a document later or
    past `ABSENT_CAP`), so a node that returns unchanged is one
    `restored unchanged: [id] role (N nodes)` line, never re-listed;
    one that returns changed is a `~ ... (restored)`. Removals fold to
    subtree roots (`- [id] role "name" (+N descendants)`) and a
    superseded document to `previous document dropped (N nodes)`. The
    full-restatement fallback compares delta LINES against tree size,
    so a page that hid behind a dialog stays a delta; the old "under a
    quarter carried -> full" ratio rule is gone, because a delta never
    re-sends a carried node and so is never longer than the tree (the
    1580-line Settings page with only its chrome carried came back
    full under it).
  - **`SnapMode.peek` (3) folds a walk and answers the revision ONLY,
    consuming nothing.** It is what `web_wait` polls with: its idle
    poll used `auto` and silently ate the delta the caller's next
    snapshot was owed, which read as `unchanged` on a page that had
    just changed. A `sem_query` that arrives before any walk of the
    document solicits one (`Pending.Kind.query`) instead of answering
    "no snapshot yet", so act-by-name right after `web_open
    snapshot:"none"` costs no extra turn.
  - **The previous document's tree is a carry POOL for every walk of
    the new one** (`View.prev`), not only the first: a client-rendered
    shell that appears a moment after the context is created would
    otherwise have nothing to carry from. A claimed pool node stays
    claimed (`prev_used`); one id that two walk nodes end up claiming
    (a hidden element returning beside the look-alike that carried its
    id) is kept by the first in document order and the other minted.
  - **A scoped snapshot ADVANCES the base for that subtree only**
    (`consumeScoped`): the caller saw those nodes, so the next unscoped
    delta owes them nothing and everything outside the subtree still.
    `web_act`/`web_key` take `scope` for the follow-up delta and
    `web_act` takes `within` to bound a name lookup; both exist so a
    click on a row menu can never return more than the menu.
  - **`set_value`'s commit carries `want`, the typed text.** The keys
    are queued trusted input and the commit is a renderer IPC, so the
    commit script can run before the keys land; `commitValue` waits
    (bounded, 1.5s) until the value contains `want`. Without it stage
    3c failed about once in a hundred runs with a connected control
    reading "".
- **Repeated siblings are ROWS, without any role on the page.**
  A grid built from divs (FRITZ!OS: 688 divs, zero `<tr>`, no role)
  reached the walk as transparent containers and the reader as
  NOTHING — the one thing on the page was invisible to both readers,
  and the only path to a row's control was an `nth` index over 58
  identical buttons. `semantic.js repeatedRows` recognises >= 3
  siblings sharing a structural signature (tag + classes + child tags;
  a majority of the container, or >= 8) as rows: the container is
  emitted as `list` (so `LIST_CAP` applies), each row as `row` named by
  its cell texts joined with ` / ` (`rowLabel`), and the reader renders
  them as a pipe table (`rowsTable`). The reader also emits a bare
  block's OWN text as a paragraph — but only for a block with no
  structure inside (`hasStructure`: controls, tables, lists,
  headings): a `<label>Owner <input></label>` flattened to a paragraph
  loses its `Owner: jelle` line (stage 12 caught exactly that). Rows
  are what `within_text`, the echo context and the intra-document
  carry lean on: a row's name is the distinctive parent anchor
  identical buttons never had.
- **`within_text` is resolved HERE, from the live tree**
  (`View.queryWithinText`, `SemQuery.within_text`, a JSON `{text, name,
  role}` argument): each candidate's anchor is its nearest
  ancestor-or-self whose subtree text contains `text`; the smallest
  anchor wins; two different anchors of that size are `ambiguous` and
  said so. No row role is needed for it, rows only make the anchors
  small. `SemQuery.form` lists `FORM_ROLES` controls with value, states
  and their `describeContext` row. Both kinds are named through
  `SemQuery.fromName` — the one place the kind vocabulary is parsed,
  for both backends.
- **An action echo names the ROW** (`describeContext`, roles in
  `CONTEXT_ROLES`): `click on button "Edit" in row "PC-5 / LAN 5 /
  10.47.1.30 / Edit" at x,y`. With N identical controls the target
  alone was the identical string for the wrong row and the right one.
  An eval element result carries the same as `context`. And an
  "unknown id" says WHICH kind (`unknownReason`): never issued, a
  truncation marker, the previous document, or an element the page
  replaced since it was listed — the last is what a long-polling admin
  page does between an eval and the act.
- **The browser's idle re-arms a stuck semantic load.**
  `sem_nav.loading` is set by a main-frame `OnLoadStart` and cleared
  ONLY by `semRearm` (main-frame `OnLoadEnd`), a stop, or a crash; a
  navigation shape that starts without ending left every action refused
  as "navigating" while `web_tabs` said `loading:false`.
  `OnLoadingStateChange(false)` fires after every load-end/error, so
  `semnav.State.stuckLoading` there (loading, and not an explicit
  navigation still awaiting its start) re-arms. The four refusal
  strings name `web_navigate action:stop` as the way out.
- **Truncation is VISIBLE, as a `more` node.** A list-ish container
  (`LIST_TAGS` by tag, or an aria list/grid/tree role) past `LIST_CAP`
  children describes its first 50 and then emits one node with role
  `more` naming how many were left out; the global `MAX_NODES` stop
  emits one at the root saying so. Both exist because a silent stop is
  indistinguishable from "the element is not on the page", which is how
  a caller concludes a control does not exist. The marker is NOT in
  `byId` — there is no element behind it — so `web_act` on one answers
  "unknown id" rather than acting on something arbitrary, and its id is
  keyed on the CONTAINER element so a re-walk reuses it instead of
  churning the delta stream with a remove+add every snapshot.
- The injected bridge script is published at context-creation time,
  before any page script runs, then unpublished, with a per-request
  nonce authenticating replies. Page scripts otherwise win the race and
  can MITM every reply. Channel integrity is guaranteed; page HONESTY
  never can be, so page content is untrusted input to every consumer.
- `--keep` must return immediately: a daemon spawning `/proc/self/exe`
  as a display keeper must never get a browser helper instead.
- **Filter-list subscription (0xC4, capability "filter-subscribe")** is
  REPLACE-ALL like the userscript set: the client posts the whole url
  list plus the refresh interval, and the helper reconciles a cache
  directory against it. The HELPER fetches because it is the only
  process here with an HTTPS stack (the daemon is libc-only). Four
  rules, each learned from how a filter list actually breaks:
  a fetched body is written ATOMICALLY and only after
  `filtersub.looksLikeFilterList` accepts it — a captive portal and an
  HTML 404 are both a perfectly successful fetch, and writing one over
  a working list disables blocking with no error anywhere; any failure
  KEEPS the previous copy, because stale rules still block; the
  reconcile deletes only `sub-`-prefixed files, never a list the user
  dropped in by hand; and the decision half (`src/web/filtersub.zig`)
  is PURE and unit-tested in both roots, because these are the choices
  that can overwrite a working file and they should be provable without
  a network. The `cef_urlrequest_client_t` follows `CookieJob`'s
  two-reference rule exactly: CEF's CToCpp wrapper consumes BOTH the
  `cef_request_t` and client references, while the Host owns the returned
  URLRequest handle and the second client reference until a later-loop
  retirement. Releasing the request after create is a double release.
  `ev_intercept_subscribe_done` (0xC5) is the stateful boundary: it is
  posted only after every fetch in the reconcile completed and accepted
  files were reloaded. Empty replace-all therefore has a completion too.
  smoke-web stage 39 proves loopback fetch/reload, duplicate
  reconciliation, a zero-hit blocked resource alongside an arriving
  control request, empty removal, failure-open preservation for HTTP,
  HTML and oversize responses, and cancellation/drain during teardown.
  The feature is inert until `filter_list` is configured, so an
  unconfigured user runs none of it.
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

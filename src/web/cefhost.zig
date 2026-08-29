//! CEF containment: the ONLY file in sketerm-web that sees a CEF type.
//!
//! It owns the browser fleet (one windowless browser per protocol view),
//! turns OnPaint into memfd + `frame_damage`, turns CEF notifications
//! into protocol events, and turns protocol input frames into trusted
//! CEF input. Everything crosses the boundary as `protocol.zig` values,
//! so swapping engines means replacing this file and nothing else.
//!
//! THREADING: `multi_threaded_message_loop = 0` and
//! `external_message_pump = 0`, so every callback below arrives on the
//! thread that calls `pump()` — the single process thread. There is
//! therefore no lock, no atomic and no queue-to-main-thread anywhere in
//! sketerm-web, and adding a thread would invalidate all of it.
//!
//! REFCOUNTS: the static handler structs use no-op add_ref/release.
//! That is sound ONLY because they are process-lifetime statics that CEF
//! may never free; it is NOT a general pattern. Objects CEF hands US
//! (browser, host, frame) are returned with a reference held, and every
//! one of them is released here after use.
//!
//! SEMANTIC LAYER PROCESS FLOW: `sketerm-web` is also its own CEF
//! RENDERER subprocess (cef_execute_process re-enters this binary), so
//! the render-process half lives in this file too and is reached only
//! through `app.get_render_process_handler`. A command travels
//!   browser: Host.sendScript -> frame.execute_java_script ->
//!            window[<slot>](json)
//! and a reply travels back
//!   render : semantic.js -> post(<nonce> + json) -> onSemPost (the
//!            transport, held in a CLOSURE and unpublished from the
//!            page) -> frame.send_process_message(PID_BROWSER)
//!   browser: onProcessMessage -> Host.onScriptMessage -> semantic.zig.
//! Only the REPLY direction needs a process message, because
//! `execute_java_script` already works browser-side. Both halves are
//! single-threaded within their own process; nothing is shared between
//! them but the JSON strings and the two secrets (see `Secret`).

const std = @import("std");
const SpinLock = @import("../util/spinlock.zig").SpinLock;
const builtin = @import("builtin");
const cef = @import("cef");
const c = @import("cbindings");
const proto = @import("protocol.zig");
// The raw-deflate codec pool updates on the native app pipe use
// (src/wlhost/zpool.zig), mapped in as a named module because the
// helper's module root is src/web/.
const zpool = @import("zpool");
const keymap = @import("keymap.zig");
const presenter = @import("presenter.zig");
const platform = @import("../util/platform.zig");
const semantic = @import("semantic.zig");
const semnav = @import("semnav.zig");
const filter = @import("filter.zig");
const filtersub = @import("filtersub.zig");
const netpolicy = @import("netpolicy.zig");
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const userscript = @import("userscript.zig");
const webexthost = @import("webext/host.zig");
const extinstall = @import("webext/install.zig");
const extmatch = @import("webext/match.zig");
const extmanifest = @import("webext/manifest.zig");
const webrequest = @import("webext/webrequest.zig");
const extassets = @import("webext/assets.zig");
const extorigins = @import("webext/origins.zig");
const bgpage = @import("webext/bgpage.zig");
const exttabs = @import("webext/tabs.zig");
const manifestRunAt = extmanifest.RunAt;
const manifestContentScript = extmanifest.ContentScript;

/// The content script — a function expression, called with the two
/// secrets and the transport (see `onContextCreated`).
const semantic_js = @embedFile("semantic.js");

/// The V8 extension that publishes the transport: a plain global
/// function (no `window` — see `onWebKitInitialized`). The injected
/// script captures it and unpublishes it before any page script runs.
const sem_bridge_js =
    \\function __sketermSemPost(json) {
    \\  native function semPost();
    \\  return semPost(json);
    \\}
;

/// Everything a subframe gets: the transport, taken away. Commands only
/// ever go to the main frame, so a subframe has no use for it and no
/// business posting anything.
const disarm_js = "window.__sketermSemPost=undefined;";

/// Process-message name carrying a script REPLY (render -> browser);
/// the payload is always a single JSON string argument.
const sem_msg = "sketerm.sem";

/// Command-line switch carrying `<nonce>:<slot>` to the renderer.
const sem_switch = "sketerm-sem-secret";

/// The two per-process secrets of the semantic layer, minted in the
/// browser process and handed to the renderer on its command line.
///
/// They exist because the injected script shares its global scope with
/// the PAGE: without `nonce` a hostile page could post forged replies
/// (fabricated snapshots, invented act results) at an agent reading
/// them, and with a guessable command name it could replace the command
/// handler. Neither name is derived from the other — `slot` is a
/// property name page script can enumerate, `nonce` never appears in
/// any name.
const Secret = struct {
    /// Prefix every reply must carry; hex, so it survives JSON.
    nonce: [32]u8 = @splat(0),
    /// Random global name the command entry point is installed under.
    slot: [32]u8 = @splat(0),
    ok: bool = false,
};

var sem_secret: Secret = .{};

/// Mint the secrets; a failure leaves the semantic layer OFF rather
/// than unauthenticated.
fn mintSecret() void {
    var raw: [32]u8 = undefined;
    if (c.getentropy(&raw, raw.len) != 0) return;
    sem_secret.nonce = std.fmt.bytesToHex(raw[0..16].*, .lower);
    sem_secret.slot = std.fmt.bytesToHex(raw[16..32].*, .lower);
    sem_secret.ok = true;
}

/// Length-checked compare that does not stop at the first difference.
fn secretEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

// The event-flag values keymap.zig hardcodes to stay CEF-free.
comptime {
    std.debug.assert(keymap.flag_shift == cef.EVENTFLAG_SHIFT_DOWN);
    std.debug.assert(keymap.flag_control == cef.EVENTFLAG_CONTROL_DOWN);
    std.debug.assert(keymap.flag_alt == cef.EVENTFLAG_ALT_DOWN);
    std.debug.assert(keymap.flag_command == cef.EVENTFLAG_COMMAND_DOWN);
    std.debug.assert(keymap.flag_caps_lock == cef.EVENTFLAG_CAPS_LOCK_ON);
    std.debug.assert(keymap.flag_num_lock == cef.EVENTFLAG_NUM_LOCK_ON);
    std.debug.assert(keymap.flag_is_key_pad == cef.EVENTFLAG_IS_KEY_PAD);
    std.debug.assert(keymap.flag_left_mouse == cef.EVENTFLAG_LEFT_MOUSE_BUTTON);
    // The presenter mirrors the protocol's modifier vocabulary so it can
    // stay protocol-free; the two must never drift.
    std.debug.assert(presenter.mod_shift == proto.mod_shift);
    std.debug.assert(presenter.mod_ctrl == proto.mod_ctrl);
    std.debug.assert(presenter.mod_alt == proto.mod_alt);
    std.debug.assert(presenter.mod_super == proto.mod_super);
    std.debug.assert(presenter.mod_capslock == proto.mod_capslock);
    std.debug.assert(presenter.mod_numlock == proto.mod_numlock);
}

/// memfd_create hides behind _GNU_SOURCE, which translate-c does not
/// define — declared here, resolved at link (Linux-only helper; the
/// macOS side of `createMemfdSystem` goes through platform.anonFileFd,
/// so this symbol is never referenced there).
extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
const MFD_CLOEXEC: c_uint = 1;

const FrameMap = []align(std.heap.page_size_min) u8;

/// Wraps fallible browser-spawn calls so CEF-gated tests can inject failures without starting the engine.
const BrowserSpawnOps = struct {
    ctx: ?*anyopaque = null,
    /// Times a refused browser create is retried (pumping CEF between
    /// attempts) before the DESCRIBED refusal is posted. Non-zero only
    /// for the system ops: the transient being absorbed is CEF's
    /// profile recovery after a predecessor's SIGKILL, which injected
    /// test ops do not have.
    create_retries: u32 = 0,
    create_browser: *const fn (?*anyopaque, *Host, *View, []const u8) ?*cef.cef_browser_t = Host.createBrowserSystem,
    create_memfd: *const fn (?*anyopaque) ?c_int = Host.createMemfdSystem,
    truncate: *const fn (?*anyopaque, c_int, usize) bool = Host.truncateSystem,
    map: *const fn (?*anyopaque, usize, bool, c_int) ?FrameMap = Host.mapSystem,
    announce: *const fn (?*anyopaque, *Host, *View, c_int) anyerror!void = Host.announceBufferSystem,
};

const system_browser_spawn_ops: BrowserSpawnOps = .{ .create_retries = 5 };

/// Wraps the one engine call `contextCreate` makes, so CEF-gated tests can
/// drive its refusal and rollback paths without starting the engine.
const ContextCreateOps = struct {
    ctx: ?*anyopaque = null,
    create: *const fn (?*anyopaque, *const cef.cef_request_context_settings_t) ?*cef.cef_request_context_t =
        Host.createRequestContextSystem,
};

const system_context_create_ops: ContextCreateOps = .{};

/// Cap on damage rects forwarded per paint; beyond it a single
/// full-view rect is cheaper than the bookkeeping.
///
/// Raising it to 128 was MEASURED to change nothing for a scrolling page
/// at 3840x2160 (1.14 GB/s either way): Chromium reports full-viewport
/// damage there, it is not the cap collapsing a long list.
const max_rects = 32;

/// First helper-minted view id for a WebExtensions background page.
/// Above `DEVTOOLS_VIEW_BASE` (0x4000_0000) so the three id ranges
/// (client, inspector, background) never collide.
const webext_bg_view_base: u32 = 0x5000_0000;

/// A per-content-script asset is bounded so a pathological manifest
/// cannot make one `ext-inject` command unbounded.
const webext_max_asset: usize = 4 * 1024 * 1024;

/// `sem_expand_result` carries a `str`, so one expand cannot exceed
/// what a u16 length can describe.
const max_expand: u32 = 60_000;

/// What every semantic request for a DISCARDED view is answered with.
///
/// Answering at all is the point: those requests have no page to reach
/// and no reply would ever arrive on its own, so a client that waits
/// for one (`webdrive`, the `web_*` MCP tools) would sit out its whole
/// timeout on what is really a one-line explanation.
const discarded_msg = "view discarded: its browser was destroyed to free memory. Show or navigate the view to bring the page back.";

/// Ceiling on the engine's own scheduler (and, on the accelerated
/// path, the minimum capture period of the frame-sink video capturer —
/// MEASURED at 3840x2160: 60 gives 59.7 dma-buf paints/s, 240 gives
/// 150). 240 is CEF's maximum; the REAL pacing lever is the client's
/// `view_max_fps` (its `browser_max_fps` clamped to the display's
/// refresh), applied through `set_windowless_frame_rate` per view.
const windowless_fps: c_int = 240;

/// The `windowless_frame_rate` for a view whose client cap is
/// `max_fps` (0 = uncapped): the cap clamped into CEF's valid 1-240
/// band. `SKETERM_WEB_WFPS` overrides outright (measurement knob).
fn effectiveWindowlessFps(max_fps: u16) c_int {
    if (c.getenv("SKETERM_WEB_WFPS")) |v| {
        const n = std.fmt.parseInt(c_int, std.mem.span(v), 10) catch 0;
        if (n > 0) return n;
    }
    if (max_fps == 0) return windowless_fps;
    return std.math.clamp(@as(c_int, max_fps), 1, windowless_fps);
}

/// Whether the browsers this process creates are driven by the CLIENT's
/// `frame_request`s (`external_begin_frame_enabled`) or by CEF's own
/// windowless scheduler. Fixed per browser at creation.
///
/// `SKETERM_WEB_EXTERNAL_BEGINFRAME=1`/`=0` forces it either way; that
/// is the switch the measurements in `externalPacingLatency` were taken
/// with.
fn externalPacingDefault() bool {
    if (c.getenv("SKETERM_WEB_EXTERNAL_BEGINFRAME")) |v| {
        const s = std.mem.span(v);
        return !(std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "no"));
    }
    return false;
}

/// How long a view may go without a client `frame_request` before the
/// helper begins pacing it itself.
///
/// THE WATCHDOG, and the answer to "what if the GUI stalls": external
/// begin frames make the CLIENT the frame source, so a client that stops
/// asking freezes the page — no animation, no rAF, no video, and no way
/// for the user to tell that apart from a hung renderer. Past this
/// deadline the helper issues its own begin frames, so the worst case is
/// a visibly slow page rather than a dead one. The
/// deadline is deliberately LONGER than the GUI's idle interval (5Hz),
/// so a live GUI is always the pacer and this never fires. Once it does
/// fire it keeps firing at this same spacing, i.e. the self-paced floor
/// is 1000/250 = 4fps: alive, obviously degraded, and cheap enough to
/// leave running under a wedged client forever.
const watchdog_ms: i64 = 250;

/// How long a `devtools_show` may go without the engine producing the
/// browser it promised before the client is told nothing opened.
const adopt_timeout_ms: i64 = 8000;

// ---------------------------------------------------------------------
// GPU (accelerated / dma-buf) mode
// ---------------------------------------------------------------------

/// Whether this process runs its browsers with `shared_texture_enabled`,
/// i.e. whether `on_accelerated_paint` can fire at all. Decided ONCE at
/// startup by `main.zig` (the ozone platform is a process-wide
/// command-line choice) and read from here by everything that has to
/// behave differently.
///
/// MEASURED (2026-08-10, CEF 150, Arch, hybrid-GPU laptop):
///   `--ozone-platform=headless` spawns no GPU process at all, whatever
///   else is passed, so accelerated paints are impossible there;
///   `--ozone-platform=wayland` gets a GPU process that holds
///   /dev/dri render nodes and delivers 1-plane BGRA dma-bufs.
var accelerated: bool = false;

/// Called by `main.zig` before `Host.install`.
pub fn setAccelerated(on: bool) void {
    accelerated = on;
}

pub fn isAccelerated() bool {
    return accelerated;
}

/// externalPacingLatency — why the DEFAULT is the engine's own
/// scheduler, in numbers. Client-driven external begin frames shipped
/// first on a throughput/idle-cost table (kept below); what they turned
/// out to cost is INPUT LATENCY, which outranks both.
///
/// MEASURED 2026-08-11, hover probe (`SKETERM_WEB_LAT`, src/ui/webface
/// `Lat`): pointer-move sent -> paint arrived / -> hover pixel in OUR
/// framebuffer, software (memfd) path, 60Hz session, idle start:
///
///   external begin frames   input->paint 39ms CONSTANT (->pixel 52ms)
///   internal scheduler      input->paint 5-19ms       (->pixel 16-26ms)
///
/// The external 39ms is a fixed property of Chromium's external-begin-
/// frame mode, not of our pacing: it survives an immediate begin frame
/// on input, a burst of begin frames 0.3/5/10/15ms after input, and
/// every `windowless_frame_rate` from 60 to 1000. The helper-side trace
/// (`hostlat:`) showed the paint landing only after the 2nd-3rd begin
/// frame REGARDLESS of their spacing. That constant is 2-3 refresh
/// periods of added latency on every interaction — the user-facing
/// "hover takes a few frames" bug — so internal pacing wins and the
/// client's cap now travels as `view_max_fps` instead of as request
/// spacing.
///
/// What the old external default bought, and where that went:
/// - cap enforcement: now `set_windowless_frame_rate` (view_max_fps).
/// - idle cost: the internal scheduler only paints on damage; a static
///   page produces nothing. Verified by the stats line reading 0 fps
///   on an untouched page.
/// - background tabs: `view_hide`/`was_hidden` still stops everything.
/// - a window the compositor stops PRESENTING while it animates keeps
///   painting under internal pacing (external stopped asking when the
///   GUI's ticks stopped). Known, accepted: latency outranks it, and
///   the frames are dropped helper-side without ever crossing the
///   socket when the backlog cap bites.
///
/// The historical throughput table (GSK `ngl`, 3840x2160 physical pane,
/// scale 1.5, GPU hardware), kept because its PRESENTED column is what
/// settled the earlier round:
///
///   animating page      delivered  presented  per-frame  uploaded
///     GPU     external    98-106      ~180/s     0.2 us    0 MiB/s
///     GPU     internal       240      ~120/s     2.0 us    0 MiB/s
///     memfd   external     79- 82      ~100/s     101 us   23 MiB/s
///     memfd   internal        90         8/s      100 us   35 MiB/s
///
///   scrolling a heavy page
///     GPU     external    73-110      ~130/s     0.2 us    0 MiB/s
///     GPU     internal       240      ~120/s     0.2 us    0 MiB/s
///     memfd   external        44        46/s     1.93 ms 1244 MiB/s
///     memfd   internal      8-9          0/s      109 ms  250 MiB/s
///
/// (The two poor `memfd internal` rows were measured with NO frame-rate
/// cap; `view_max_fps` now clamps the internal scheduler to the
/// display's refresh, which is exactly the spacing external requests
/// used to impose.)
/// How the engine is told what DPR to lay out at.
///
/// The protocol's scale contract (docs/proposal-browser-protocol.md) is
/// "view rect LOGICAL, buffers PHYSICAL, DPR from `get_screen_info`".
/// That works exactly as documented under headless ozone, and NOT under
/// any real ozone platform: MEASURED under `--ozone-platform=wayland`,
/// `get_screen_info`'s `device_scale_factor` is ignored outright — the
/// page reports `devicePixelRatio === 1` and the engine renders the view
/// rect one buffer pixel per DIP, i.e. at logical resolution. That is
/// the "why is the browser blurry" bug all over again, and no
/// combination of `--force-device-scale-factor` moves it.
///
/// So in accelerated mode the same contract is honoured through a
/// different lever: `get_view_rect` reports PHYSICAL pixels and the
/// browser's ZOOM LEVEL carries the scale (Chromium's zoom multiplies
/// `devicePixelRatio` and divides the layout viewport, which is exactly
/// a device scale factor). MEASURED at logical 1280x720 scale 1.5:
/// dpr 1.5, innerWidth 1280, dma-buf 1920x1080 — the contract, intact.
///
/// Everything the client sees is unchanged: wire sizes stay logical,
/// buffers stay physical. Only input needs a conversion, because CEF's
/// mouse coordinates live in view-rect space — see `viewPoint`.
fn scaleViaZoom() bool {
    return accelerated;
}

/// CEF's zoom LEVEL for a device scale factor: zoom factor = 1.2^level.
fn zoomLevelFor(scale_x1000: u16) f64 {
    const f = @as(f64, @floatFromInt(scale_x1000)) / 1000.0;
    return @log(f) / @log(@as(f64, 1.2));
}

// Latency tracing (`SKETERM_WEB_LAT`, measurement harness): stamps the
// input/begin-frame/paint path so the GUI's probe deltas decompose.
var g_lat_trace: enum { unknown, off, on } = .unknown;

fn latTrace() bool {
    if (g_lat_trace == .unknown)
        g_lat_trace = if (c.getenv("SKETERM_WEB_LAT") != null) .on else .off;
    return g_lat_trace == .on;
}

fn latStamp(tag: []const u8) void {
    if (!latTrace()) return;
    const ms = @as(f64, @floatFromInt(@import("../util/clock.zig").nowNs())) / 1e6;
    std.debug.print("hostlat: {s} {d:.2}\n", .{ tag, ms });
}

const nowMs = @import("../util/clock.zig").nowMs;

const nowUs = @import("../util/clock.zig").nowUs;

/// Physical pixels for `logical` at `scale_x1000`, per the protocol's
/// scale contract: `ceil(logical * scale)`, never 0.
fn physicalOf(logical: u16, scale_x1000: u16) u16 {
    const n = (@as(u32, logical) * @as(u32, scale_x1000) + 999) / 1000;
    return @intCast(std.math.clamp(n, 1, std.math.maxInt(u16)));
}

// ---------------------------------------------------------------------
// Per-view state
// ---------------------------------------------------------------------

/// One protocol view: a windowless browser plus its shared frame buffer.
pub const View = struct {
    id: u32,
    /// Connection that created the view (multi-client serving); 0 when
    /// the host runs without a router (unit tests, legacy single
    /// client). Owner-scoped: every view-carrying event routes to this
    /// connection only, and `find` refuses the view to any OTHER
    /// dispatching connection.
    owner: u32 = 0,
    /// The owning connection asked for inline frames (`frame_mode`),
    /// per-connection where `Host.inline_mode` is the process-wide
    /// `--frames-inline` force. Latching like the global flag: never
    /// turned back off (an anonymous buffer was never announced).
    inline_view: bool = false,
    /// Latest scroll offset Chromium reported, and the last pair
    /// actually posted — the difference is what the throttle owes the
    /// client, so a scroll that STOPS still gets its resting position
    /// out (see onScrollOffsetChanged / flushScroll).
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    scroll_sent_x: i32 = 0,
    scroll_sent_y: i32 = 0,
    scroll_posted_ms: i64 = 0,
    /// CEF's own browser id, the key callbacks are resolved through.
    cef_id: c_int = 0,
    /// Owned reference from create_browser_sync; released on destroy.
    browser: ?*cef.cef_browser_t = null,
    /// LOGICAL (DIP) size: what `get_view_rect` reports, what input
    /// coordinates are in, and what the client sends on the wire.
    w: u16,
    h: u16,
    /// Device scale factor x1000, reported to the engine through
    /// `get_screen_info` so the PAGE lays out at that DPR.
    scale_x1000: u16,
    /// PHYSICAL size: the frame buffer's real pixel dimensions, what
    /// `frame_buffer` announces, and the size CEF's OnPaint delivers.
    pw: u16,
    ph: u16,
    buf_id: u32 = 0,
    /// Writable mapping of the memfd announced by `frame_buffer`. The
    /// fd itself is handed to the client and closed by the sender: a
    /// mapping outlives its descriptor.
    map: []align(std.heap.page_size_min) u8 = &.{},
    /// The mapping was just (re)allocated and is still all zeroes, so
    /// its contents are UNKNOWN: the next paint must be copied WHOLE,
    /// however little the engine says is damaged. Without this a paint
    /// that reports only what changed leaves the rest of a freshly
    /// zeroed buffer black forever on a page that never repaints again
    /// — and a first paint arriving before the buffer existed is
    /// dropped outright by the `map.len == 0` guard in `onPaint`.
    buf_unpainted: bool = false,
    gen: u32 = 0,
    hidden: bool = false,
    /// Monotonic milliseconds of the last begin frame issued for this
    /// view, whoever asked for it. Drives the watchdog.
    last_begin_ms: i64 = 0,
    /// Client-set frame-rate cap (`view_max_fps`), 0 = uncapped.
    max_fps: u16 = 0,
    /// Whether this browser was created with external begin frames, so
    /// the client is the frame source. See `externalPacingLatency`.
    external_pacing: bool = false,
    /// Last address CEF reported, owned; the `ev_nav_state` payload,
    /// and — after a `view_discard` — the address the browser comes
    /// back at.
    url: []u8 = &.{},
    /// `view_discard` destroyed this view's browser; the record (id,
    /// geometry, scale, address, fps cap) is all that is left. Any
    /// frame that must show, navigate or reach the page revives it
    /// through `findWake`. NAVIGATION HISTORY DOES NOT SURVIVE: the
    /// revived browser starts a fresh session at `url`, so back and
    /// forward are empty — the memory is the whole point, and keeping
    /// the history would mean keeping the browser.
    discarded: bool = false,
    /// USER zoom (`set_zoom`), as the engine's log-scale level x100.
    /// Added on top of the DPR zoom in `applyZoom`, and re-applied on
    /// every load start because Chromium resets zoom per navigation.
    user_zoom_x100: i32 = 0,
    /// Identity context this view was created in (0 = shared default).
    /// Kept so a post-discard revival re-uses the same request context
    /// and its cookie jar / egress; resolved to a pointer per spawn.
    context: u32 = 0,

    /// The client asked for accessibility streaming (`a11y_enable`).
    /// Survives a discard: the revived browser re-enables engine-side
    /// accessibility in `spawnBrowser`.
    a11y: bool = false,
    /// The engine's tree-id token this view's AX stream was last
    /// attributed by (owned). The accessibility callbacks carry NO
    /// browser pointer — only this token — so it is the join key; see
    /// `axResolveView` for how it gets (re)bound.
    ax_tree: []u8 = &.{},
    /// Last caret/selection sent, so a repeated tree_data does not
    /// re-post an unchanged caret. `ax_caret_sent` distinguishes
    /// "never sent" from "sent an all-zero caret".
    ax_caret: proto.EvA11yCaret = .{ .view = 0, .anchor_id = 0, .anchor_offset = 0, .focus_id = 0, .focus_offset = 0 },
    ax_caret_sent: bool = false,

    /// The engine's callback for a certificate error whose request is
    /// HELD, waiting for a `cert_decision`. At most one per view: a
    /// second error arriving while one is pending takes CEF's default
    /// handling (the load fails) rather than queueing, because the
    /// client shows one interstitial per view and could not answer two.
    /// The reference is owned and released when it is resolved.
    cert_cb: ?*cef.cef_callback_t = null,
    /// Permission prompts held for this view (see `PendingPerm`).
    perms: [max_pending_perms]PendingPerm = @splat(.{}),

    /// Semantic-layer state: the shadow tree plus the requests waiting
    /// on a reply from the injected script.
    sem: semantic.View = undefined,
    /// Set once the client asked for a snapshot; from then on mutation
    /// batches keep arriving and fold into the live shadow tree
    /// (nothing is pushed for them — the next snapshot request answers
    /// with one coalesced delta).
    sem_observing: bool = false,
    /// Observation is a client preference that survives navigation;
    /// `sem_observing` says only whether this document was armed.
    sem_want_observer: bool = false,
    /// Detail level of the last request, replayed after a navigation.
    sem_detail: u8 = 1,
    sem_next_req: u32 = 1,
    /// Main-document generation and load/stop transitions.
    sem_nav: semnav.State = .{},
    /// Renderer token of the current main-frame V8 context. Every
    /// semantic reply carries it; mismatches are late old-context data.
    sem_context_doc: u32 = 0,
    /// An explicit navigate/back/forward/reload has advanced the
    /// generation before CEF's matching load-start callback arrives.
    pending: std.ArrayList(Pending) = .empty,

    /// The view id of this view's OPEN inspector, 0 when it has none.
    /// Set on the SOURCE view; destroying it takes the inspector with
    /// it, because an inspector whose target is gone shows nothing and
    /// nobody would ever close it.
    devtools_view: u32 = 0,
    /// The source view this view INSPECTS, 0 for an ordinary view.
    devtools_of: u32 = 0,
    /// An inspector the engine insisted on giving its OWN WINDOW. It is
    /// tracked as a view only so somebody owns the browser and closes
    /// it — it paints nothing, is never announced to the client, and
    /// takes no frames.
    windowed: bool = false,

    /// dma-buf pool identity (accelerated mode only). The engine renders
    /// into a handful of buffers and cycles through them, handing the
    /// same underlying object back under a fresh descriptor every time;
    /// keying on the object's inode turns that into a stable `buf_id`,
    /// which is what lets the client import each pool member ONCE
    /// instead of once per frame.
    pool: [max_pool]PoolEntry = @splat(.{}),
    next_buf_id: u32 = 0,

    /// Inline mode only: damage accumulated since the last posted
    /// `frame_inline`, as one union rect. Damage is unioned rather
    /// than queued so a slow link coalesces bursts instead of
    /// ballooning the outbox; the flush (`flushInlineView`) clears it.
    inline_dirty: ?proto.Rect = null,
    /// A hidden WebExtensions background page: a 1x1 windowless browser
    /// that hosts the extension's background scripts and never paints or
    /// is announced to the client. It has no frame buffer, so `onPaint`
    /// posts nothing for it.
    webext_bg: bool = false,

    /// A browser-action popup: real extension document and ordinary
    /// frame/input path, but no tab/navigation chrome on the client.
    webext_popup: bool = false,
    popup_owner: u32 = 0,
    popup_ext: [extmanifest.MAX_ID_LEN]u8 = @splat(0),
    popup_ext_len: usize = 0,

    /// The background page was spawned AT its `chrome-extension://`
    /// origin, so the engine loads its scripts and nothing is injected.
    ///
    /// A separate flag rather than a test on `url`, because `url` is
    /// fed by `onAddressChange`, which deliberately ignores background
    /// views (they face no client) and so leaves it empty forever.
    webext_origin: bool = false,

    /// CEF frame identifiers seen on this view, in the order seen. The
    /// INDEX is MV2's `frameId`, so the main frame is 0 by construction
    /// (it is always the first frame a view has). CEF's own identifier
    /// is an opaque string and no use to an extension.
    frame_ids: std.ArrayList([]u8) = .empty,

    /// The frame the message being dispatched RIGHT NOW arrived on.
    ///
    /// Set by `onProcessMessage` immediately before `onScriptMessage`
    /// and meaningless outside that call. The whole path is synchronous
    /// and on one thread, so a field carries it; threading a frame id
    /// through every `ext-*` handler's signature would buy nothing and
    /// touch a dozen call sites.
    cur_frame_id: u32 = 0,

    const PoolEntry = struct { ino: u64 = 0, id: u32 = 0, seen: u64 = 0 };

    /// MV2 `frameId` for a CEF frame identifier, minting one on first
    /// sight. Bounded: a page that mints frames forever gets `-1`-style
    /// fallback 0 rather than an unbounded table.
    fn frameIdFor(self: *View, gpa: std.mem.Allocator, ident: []const u8) u32 {
        for (self.frame_ids.items, 0..) |f, i| {
            if (std.mem.eql(u8, f, ident)) return @intCast(i);
        }
        if (self.frame_ids.items.len >= 512) return 0;
        const copy = gpa.dupe(u8, ident) catch return 0;
        self.frame_ids.append(gpa, copy) catch {
            gpa.free(copy);
            return 0;
        };
        return @intCast(self.frame_ids.items.len - 1);
    }

    fn forgetFrames(self: *View, gpa: std.mem.Allocator) void {
        for (self.frame_ids.items) |f| gpa.free(f);
        self.frame_ids.deinit(gpa);
        self.frame_ids = .empty;
    }

    fn stride(self: *const View) u32 {
        return @as(u32, self.pw) * 4;
    }

    /// Stable id for the dma-buf object behind `ino`, minting one on
    /// first sight and evicting the least recently used entry when the
    /// pool table is full (a resize retires a whole generation).
    fn poolId(self: *View, ino: u64, now: u64) u32 {
        var lru: usize = 0;
        for (&self.pool, 0..) |*e, i| {
            if (e.ino == ino and e.id != 0) {
                e.seen = now;
                return e.id;
            }
            if (e.seen < self.pool[lru].seen) lru = i;
        }
        self.next_buf_id +%= 1;
        if (self.next_buf_id == 0) self.next_buf_id = 1;
        self.pool[lru] = .{ .ino = ino, .id = self.next_buf_id, .seen = now };
        return self.next_buf_id;
    }

    fn forgetPool(self: *View) void {
        self.pool = @splat(.{});
    }
};

/// Pool entries tracked per view. Chromium's OSR pool is 2-3 deep; 8
/// leaves room for a resize's overlap without ever growing.
const max_pool = 8;

/// Permission prompts a view may hold at once. A page can legitimately
/// ask for two things at once (notifications on load, geolocation on a
/// click); beyond this the engine's default handling answers, which
/// denies under alloy style.
const max_pending_perms = 4;

/// One permission request whose engine callback is HELD until the
/// client answers with `permission_decision`.
///
/// CEF has two of these and they are not interchangeable: a prompt
/// carries an engine-minted `prompt_id` and a
/// `cef_permission_prompt_callback_t`, while a media (camera/mic)
/// request carries NO id at all and a `cef_media_access_callback_t`
/// whose `cont` takes back the bits it may grant. Media requests
/// therefore get an id minted here, in a disjoint id space (bit 63 set)
/// so the two can never collide on the wire.
const PendingPerm = struct {
    id: u64 = 0,
    /// Exactly one of these is non-null while `id != 0`.
    prompt_cb: ?*cef.cef_permission_prompt_callback_t = null,
    media_cb: ?*cef.cef_media_access_callback_t = null,
    /// CEF media bits as asked for, handed back verbatim on an allow.
    media_bits: u32 = 0,

    fn busy(self: *const PendingPerm) bool {
        return self.id != 0;
    }
};

/// Bit marking a media-access id as helper-minted; see `PendingPerm`.
const media_id_bit: u64 = 1 << 63;

/// Queued messages past which a GPU frame is dropped rather than
/// enqueued — see `Host.postDmabuf`.
const max_frame_backlog = 8;

/// One in-flight round trip to the injected script.
///
/// Actions are multi-step on purpose: a click first asks the script
/// where the element IS, and the click itself is then synthesized
/// through the ordinary input path so the page sees `isTrusted`.
const Pending = struct {
    req: u32,
    kind: Kind,
    /// Client operation id from `sem_request`; 0 for legacy frames.
    client_request: u32 = 0,
    nav_gen: u32 = 0,
    deadline_ms: i64 = 0,
    /// Reissue in the fresh context when the navigation settles.
    rearm: bool = false,
    /// This and every later phase originated from `sem_act_guarded`.
    guarded: bool = false,
    sid: u32 = 0,
    mode: u8 = 0,
    detail: u8 = 0,
    scope: u32 = 0,
    /// Owned copy of a `sem_act` argument (the text to type), or of an
    /// `eval` request's code so a CSP refusal can re-send it spliced.
    arg: []u8 = &.{},
    off: u32 = 0,
    guard: u64 = 0,
    /// Eval-only: the await flag and timeout travel with the code so
    /// the CSP re-send is byte-equivalent, and `eval_retried` makes the
    /// fallback single-shot.
    eval_await: bool = false,
    eval_timeout_ms: u32 = 0,
    eval_retried: bool = false,

    const Kind = enum {
        snapshot,
        /// A `sem_query` of kind `visible` (link hints): answered from
        /// the live tree AFTER the fresh walk this request solicits,
        /// because scrolling moves every rect without one DOM mutation.
        /// `arg` holds the "<vw> <vh>" viewport string.
        hints,
        /// A `sem_query` that arrived before any walk (a view opened
        /// with the first snapshot skipped, then act-by-name): it
        /// solicits one walk and answers from the live tree, without
        /// consuming the base. `mode` is the query kind.
        query,
        click,
        hover,
        act,
        set_value,
        commit,
        expand,
        read,
        read_ids,
        guarded_act,
        eval,
        /// A custom dropdown was clicked open; waiting for the option's
        /// rect so the pick itself can be a trusted click too.
        choose_pick,
        /// The option was clicked; waiting for what the control reads
        /// as now.
        choose_done,
    };
};

const semantic_request_timeout_ms: i64 = 120_000;
/// How long a routed runtime/tabs.sendMessage may wait for `ext-reply`
/// before the sender's Promise is settled with an error. Same expiry
/// tick as the semantic Pending deadlines (`semanticPump`); shorter,
/// because the common failure is a background page whose bootstrap has
/// not run yet, and the sender retries.
const route_reply_timeout_ms: i64 = 30_000;
const stale_reader_msg = "stale reader id: the page changed since web_read; read the page again";

fn semanticResult(comptime T: type) bool {
    return switch (T.tag) {
        .sem_snapshot,
        .sem_act_result,
        .sem_expand_result,
        .sem_query_result,
        .sem_read_result,
        .sem_read_ids_result,
        .sem_eval_result,
        => true,
        else => false,
    };
}

// ---------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------

/// The browser fleet plus its outbound protocol queue.
///
/// A single instance per process, reachable from the C callbacks
/// through `g_host` — CEF handlers take no user-data pointer, and the
/// single-threaded loop makes a global sound here.
/// Multi-client routing seam, provided by the server that owns the
/// connections. The host resolves an owning connection's outbound
/// queue through it; when unset (unit tests, the pre-multi-client
/// single-client shape) every post lands in `Host.out`.
pub const Router = struct {
    ctx: *anyopaque,
    /// Outbox of connection `conn_id`, or null when that connection is
    /// gone — the post is then dropped, exactly like a dead socket.
    route: *const fn (ctx: *anyopaque, conn_id: u32) ?*proto.Outbox,
    /// Live connection count + indexed access, for the rare broadcast
    /// (viewless event with no dispatching connection).
    count: *const fn (ctx: *anyopaque) usize,
    at: *const fn (ctx: *anyopaque, i: usize) ?*proto.Outbox,
    /// Client-namespace view id -> engine-global id for `conn_id`, 0
    /// when invalid. The edge translates every TOP-LEVEL frame; this
    /// exists for the one place a view id hides INSIDE a payload the
    /// edge cannot see — `sem_request`'s wrapped inner frame.
    mapView: *const fn (ctx: *anyopaque, conn_id: u32, id: u32) u32,
};

/// A resolved outbound target: where to post, and the id-window base
/// to subtract so the frame carries the CLIENT's namespace again.
const RouteTo = struct { out: *proto.Outbox, base: u32 };

pub const Host = struct {
    gpa: std.mem.Allocator,
    out: *proto.Outbox,
    /// Multi-client routing; null = single-outbox legacy behaviour.
    router: ?Router = null,
    /// Connection whose inbound frame is being dispatched (0 = none:
    /// a CEF callback, a flush, a drain). Set by the server around
    /// `dispatch`, consumed by `find`'s ownership check, view creation
    /// stamping, and viewless-post routing.
    dispatch_conn: u32 = 0,
    /// The dispatching connection's inline-frame latch, stamped onto
    /// views it creates.
    dispatch_inline: bool = false,
    views: std.ArrayList(*View) = .empty,
    /// The view a create_browser_sync call is currently building, for
    /// the callbacks CEF fires BEFORE it returns the browser pointer.
    pending: ?*View = null,
    /// Correlated semantic request being dispatched or completed. The
    /// generic `post` wrapper turns only semantic replies into
    /// `sem_result` while this is non-zero.
    active_sem_request: u32 = 0,
    /// The view waiting for a browser CEF creates on its own schedule:
    /// `show_dev_tools` returns void and the inspector browser appears
    /// in a later `on_after_created`, so unlike `pending` this cannot
    /// be scoped to one call. It is consulted only for a browser no
    /// view claims by cef id, and cleared the moment one is adopted.
    adopting: ?*View = null,
    /// When `adopting` was armed. An engine that answers a
    /// `show_dev_tools` with no browser at all would otherwise leave a
    /// client waiting for a reply that never comes — see `watchdog`.
    adopting_ms: i64 = 0,
    /// Next helper-minted view id (inspectors). Client ids come from
    /// the client and start at 1; see `proto.DEVTOOLS_VIEW_BASE`.
    next_devtools: u32 = proto.DEVTOOLS_VIEW_BASE,
    /// Prints the engine has not finished yet. `path` is owned and is
    /// also the correlation key: CEF's callback hands back the path,
    /// not a request id.
    prints: std.ArrayList(Print) = .empty,
    /// Downloads the engine has told us about (capability "downloads").
    /// Owned by the HOST, not by a view, because the engine's update
    /// callbacks outlive our target decision — but every entry still
    /// names the view it came from, and `dropBrowser` cancels that
    /// view's entries when the browser goes.
    downloads: std.ArrayList(Dl) = .empty,

    /// Inline frame mode (capability "frames-inline"): paint pixels ride
    /// the protocol socket as `frame_inline` payloads and NO memfd or
    /// dma-buf ever crosses it — the frame family a remote (bridged)
    /// helper must use. Set by the client's `frame_mode` frame or forced
    /// from spawn by `--frames-inline`; buffers allocated while it is on
    /// are anonymous mappings and are never announced.
    inline_mode: bool = false,

    /// Per-tab identity contexts (`context_create`). A view names one by
    /// id; id 0 is the shared default (a null request context) and never
    /// appears here.
    contexts: std.ArrayList(Ctx) = .empty,
    /// In-flight `flush_req` bookkeeping: completions arrive through ONE
    /// anonymous static callback, so each is charged to the OLDEST entry
    /// — conservative (a later flush completing means the stores are at
    /// least as fresh), and per-request state without a per-request CEF
    /// object. Entries with `conn == 0` are the engine's own periodic
    /// flushes: tracked so their completions cannot release a client's
    /// pending answer early, but answered to nobody.
    pending_flushes: std.ArrayList(PendingFlush) = .empty,

    // -- cross-instance cookie sync (capability "cookie-sync") --------
    //
    // Nothing here runs until a connection subscribes: `g_cksync.on` is
    // the IO thread's fast path out of `can_save_cookie`, and an empty
    // `cookie_sync_conns` is the main thread's fast path out of the
    // reconcile. A helper nobody asked to synchronise pays one relaxed
    // atomic load per saved cookie and nothing else.

    /// Connections subscribed via `cookie_sync_enable`. Ids, not
    /// outboxes: a connection can die between subscribing and the next
    /// reconcile, and the router answers null for it then.
    cookie_sync_conns: std.ArrayList(u32) = .empty,
    /// Last-known state of every jar this helper synchronises, keyed by
    /// (context, domain, path, name). The reconcile emits on a DIFF
    /// against it, which is also what makes loop prevention structural:
    /// an applied cookie updates the shadow as part of writing the jar,
    /// so there is no diff left to emit for it.
    cookie_shadow: std.ArrayList(CookieShadow) = .empty,
    /// Monotonic ms of the last reconcile pass.
    cookie_reconcile_ms: i64 = 0,
    /// Reconcile visits outstanding (one per context). A second round
    /// must not start while any of them is still walking, or the same
    /// jar is diffed twice against a shadow one of them is mid-update.
    cookie_reconcile_busy: u32 = 0,
    /// The shadow has never been filled for at least one context. The
    /// FIRST reconcile of a context is SILENT — it learns the jar
    /// rather than replaying every cookie already in it as a change,
    /// the same reason `a11y/webproj.zig`'s first publish is silent.
    cookie_shadow_seeded: std.ArrayList(u32) = .empty,

    /// WebExtensions host: the loaded-extension registry, storage and
    /// browser.* dispatch. Content-script injection and background-page
    /// hosting are driven from here through the existing semantic bridge.
    webext: webexthost.Host = undefined,
    /// Next helper-minted view id for a background page. Kept far above
    /// both client ids (from 1) and inspector ids (DEVTOOLS_VIEW_BASE).
    next_bg_view: u32 = webext_bg_view_base,
    /// Cross-frame runtime.sendMessage routing: a content script's
    /// message gets a process-global id here so the background's reply
    /// can find its way home. Bounded — the oldest is dropped.
    webext_replies: std.ArrayList(PendingReply) = .empty,
    webext_next_gid: u32 = 1,
    webext_ports: std.ArrayList(Port) = .empty,
    webext_next_port: u32 = 1,
    /// Extension ids awaiting a `runtime.reload`, performed on the next
    /// poll turn rather than inside the call that asked for it.
    webext_reload: std.ArrayList([]u8) = .empty,
    /// Root cache directory (the `--cache-dir`), under which a persistent
    /// context's own cache dir is minted. Set by the server before `run`.
    profile_dir: []const u8 = "",
    /// This instance's route proxy url ("" = direct), from `--proxy`.
    /// Applied to the global context at `install` and to every container
    /// context at create, so a routed instance has no direct path at
    /// all — the route is the process, never a per-view setting.
    instance_proxy: []const u8 = "",
    /// The Wayland presenter (capability "presenter"): every presentable
    /// view is mirrored as a toplevel on the session hub. Null when the
    /// helper was not started as a session client, or once it disarmed.
    presenter: ?*presenter.Presenter = null,

    /// User content (capability "userscripts"): the enabled userscript
    /// and userstyle sets, replaced whole by `us_script_set` /
    /// `us_style_set` and injected per navigation in `onLoadStart`
    /// (see `injectUserContent` for the timing/world limitations).
    /// Each set owns ONE arena so a replace frees the old set whole
    /// without invalidating the other's slices.
    us_script_arena: ?std.heap.ArenaAllocator = null,
    us_scripts: std.ArrayList(ScriptRec) = .empty,
    us_style_arena: ?std.heap.ArenaAllocator = null,
    us_styles: std.ArrayList(StyleRec) = .empty,

    /// Client-loaded extra filter-list paths (owned), remembered so a
    /// subscription reconcile's reload cannot silently drop them.
    intercept_extra: std.ArrayList([]const u8) = .empty,

    /// Host-owned subscription state and URLRequests. CEF owns a
    /// separate transferred client reference for each live request.
    filter_sub_urls: std.ArrayList([]u8) = .empty,
    filter_fetches: std.ArrayList(*FilterFetch) = .empty,
    filter_sub_hours: u32 = 0,
    filter_sub_serial: u32 = 0,
    filter_sub_active: u16 = 0,
    filter_sub_fetched: u16 = 0,
    filter_sub_updated: u16 = 0,
    filter_sub_failed: u16 = 0,
    filter_sub_pending: u16 = 0,
    filter_sub_reload: bool = false,
    filter_sub_batch_open: bool = false,
    filter_sub_stopping: bool = false,
    filter_sub_next_ms: i64 = std.math.maxInt(i64),

    const ScriptRec = struct {
        id: u32,
        meta: userscript.Meta,
        source: []const u8,
    };
    const StyleRec = struct {
        id: u32,
        /// "" = every page; otherwise the host and its subdomains.
        host: []const u8,
        css: []const u8,
    };
    /// One extension-API Promise parked on somebody else's answer.
    ///
    /// The two kinds are the same problem with different recipients — a
    /// `runtime`/`tabs.sendMessage` waiting for another FRAME's
    /// `ext-reply`, and a `browserAction.openPopup` waiting for the
    /// GUI's `webext_open_popup_result` — so they share one table, one
    /// abandon sweep and one expiry pass. They were separate once, and
    /// the copy without the deadline could park a Promise forever when
    /// the correlated reply simply never arrived.
    const PendingReply = struct {
        kind: Kind,
        /// Correlation id minted here: the `gid` in the `ext-message`
        /// command, or the `req` on the `webext_open_popup` frame.
        gid: u32,
        /// The view whose JS is waiting, and the request id it waits on.
        origin_view: u32,
        origin_req: u32,
        /// The view expected to produce the answer.
        reply_view: u32,
        ext: []u8,
        deadline_ms: i64,

        const Kind = enum {
            message,
            popup,

            /// What the waiting Promise is rejected with when its
            /// recipient goes away.
            fn gone(self: Kind) []const u8 {
                return switch (self) {
                    .message => "message recipient is gone",
                    .popup => "popup target is gone",
                };
            }

            /// ... and when it simply never answers.
            fn expired(self: Kind) []const u8 {
                return switch (self) {
                    .message => "message recipient did not reply",
                    .popup => "native popup was never acknowledged",
                };
            }
        };
    };

    /// One `runtime.connect` Port, from the browser process's point of
    /// view: two views and the extension they belong to.
    ///
    /// The browser process mints the id because it is the only side that
    /// can see both ends. Frames key their own Port objects on the same
    /// id, so a message needs no translation — just "send it to the
    /// other view".
    const Port = struct {
        gid: u32,
        ext: []u8,
        a_view: u32,
        b_view: u32,

        fn peerOf(self: *const Port, view: u32) u32 {
            if (self.a_view == view) return self.b_view;
            if (self.b_view == view) return self.a_view;
            return 0;
        }
    };

    /// One `print_pdf` in flight.
    const Print = struct { view: u32, path: []u8 };

    /// One engine download. `before_cb` is the HELD target decision
    /// (`ev_download_offer`'s other half); `item_cb` is the latest
    /// cancel handle the engine offered, kept so a `download_cancel`
    /// (or a dying view) can abort the transfer. Both references are
    /// owned and released exactly once, same discipline as `cert_cb`.
    const Dl = struct {
        id: u32,
        view: u32,
        before_cb: ?*cef.cef_before_download_callback_t = null,
        item_cb: ?*cef.cef_download_item_callback_t = null,
        /// The offer was posted (an entry can exist earlier: the engine
        /// reports progress before `on_before_download`).
        offered: bool = false,
        /// The client answered with a path; progress frames flow.
        decided: bool = false,
        cancel_requested: bool = false,
        received: u64 = 0,
        total: u64 = 0,
        done: bool = false,
        failed: bool = false,
        /// Counters moved since the last flush (the intercept_status
        /// coalescing pattern: one frame per poll iteration at most).
        dirty: bool = false,
        /// Throwaway path a CANCELLED offer was continued into (see
        /// `cancelDl`: the engine's held target callback must always
        /// run, or shutdown hangs on the download manager). Unlinked
        /// when the entry is dropped.
        trash: [128]u8 = @splat(0),
        trash_len: usize = 0,

        fn terminal(self: *const Dl) bool {
            return self.done or self.failed;
        }

        fn dropTrash(self: *Dl) void {
            if (self.trash_len == 0) return;
            self.trash[self.trash_len] = 0;
            _ = c.unlink(@ptrCast(&self.trash));
            self.trash_len = 0;
        }

        fn releaseCbs(self: *Dl) void {
            if (self.before_cb) |cb| release(&cb.base);
            self.before_cb = null;
            if (self.item_cb) |cb| release(&cb.base);
            self.item_cb = null;
        }
    };

    /// A live identity context: our owned reference to the engine's
    /// request context, keyed by the client's id.
    const Ctx = struct {
        id: u32,
        rc: *cef.cef_request_context_t,
        ephemeral: bool,
        /// Creating connection (multi-client), 0 without a router.
        owner: u32 = 0,
    };

    const PendingFlush = struct { token: u32, conn: u32, outstanding: u32 };

    pub fn init(gpa: std.mem.Allocator, out: *proto.Outbox) Host {
        return .{ .gpa = gpa, .out = out, .webext = webexthost.Host.init(gpa) };
    }

    pub fn deinit(self: *Host) void {
        self.destroyAll();
        if (self.presenter) |p| {
            p.deinit();
            self.presenter = null;
        }
        self.views.deinit(self.gpa);
        self.webext.deinit();
        for (self.webext_replies.items) |r| self.gpa.free(r.ext);
        self.webext_replies.deinit(self.gpa);
        for (self.webext_ports.items) |p| self.gpa.free(p.ext);
        self.webext_ports.deinit(self.gpa);
        for (self.webext_reload.items) |p| self.gpa.free(p);
        self.webext_reload.deinit(self.gpa);
        extorigins.clear();
        for (self.prints.items) |p| self.gpa.free(p.path);
        self.prints.deinit(self.gpa);
        // destroyAll's dropBrowser sweep already cancelled and freed
        // per-view entries; whatever is left never named a live view.
        for (self.downloads.items) |*d| d.releaseCbs();
        self.downloads.deinit(self.gpa);
        for (self.contexts.items) |ctx| release(&ctx.rc.base.base);
        self.contexts.deinit(self.gpa);
        self.pending_flushes.deinit(self.gpa);
        self.cookie_sync_conns.deinit(self.gpa);
        for (self.cookie_shadow.items) |*sh| sh.free(self.gpa);
        self.cookie_shadow.deinit(self.gpa);
        self.cookie_shadow_seeded.deinit(self.gpa);
        self.us_scripts.deinit(self.gpa);
        if (self.us_script_arena) |*a| a.deinit();
        self.us_styles.deinit(self.gpa);
        if (self.us_style_arena) |*a| a.deinit();
        filterSubAbandon(self);
        for (self.intercept_extra.items) |p| self.gpa.free(p);
        self.intercept_extra.deinit(self.gpa);
        for (self.filter_sub_urls.items) |u| self.gpa.free(u);
        self.filter_sub_urls.deinit(self.gpa);
        self.filter_fetches.deinit(self.gpa);
        if (g_host == self) g_host = null;
    }

    fn lookupContext(self: *Host, id: u32) ?*cef.cef_request_context_t {
        if (id == 0) return null;
        for (self.contexts.items) |ctx| {
            if (ctx.id == id) return ctx.rc;
        }
        return null;
    }

    /// The request context a view's browser must be created in.
    ///
    /// A NULL context means CEF's GLOBAL one -- no proxy, the shared
    /// cookie jar -- so a view that asked for a container and whose
    /// container is gone must REFUSE, never fall back. The container may
    /// carry the SOCKS egress the page's traffic is supposed to leave
    /// by, and a silent fall back to direct traffic is exactly the
    /// privacy failure the create-time check was added to remove. Every
    /// browser creation for a client view resolves its context here.
    ///
    /// The returned reference is ADD-REF'd: `create_browser_sync` wraps
    /// the pointer with `CefRequestContextCToCpp::Wrap`, which TAKES
    /// ownership (CEF's CToCpp wrappers transfer, they never add), so
    /// handing it the registry's own reference freed the context after
    /// the FIRST browser and the second view in the same container
    /// crashed the helper on a freed vtable. Callers pass the result
    /// straight to a create_browser call and must not release it.
    ///
    /// Call it ONLY where the reference is about to be handed to such a
    /// call; a pre-flight refusal wants `requireContext`, which answers
    /// the same question without minting a reference nobody consumes.
    fn contextForSpawn(self: *Host, v: *const View) error{ContextGone}!?*cef.cef_request_context_t {
        if (v.context == 0) return null;
        const rc = self.lookupContext(v.context) orelse return error.ContextGone;
        if (rc.base.base.add_ref) |add| add(&rc.base.base);
        return rc;
    }

    /// `contextForSpawn`'s refusal without its reference: the container a
    /// view names still exists (or it never named one).
    fn requireContext(self: *Host, v: *const View) error{ContextGone}!void {
        if (v.context == 0) return;
        if (self.lookupContext(v.context) == null) return error.ContextGone;
    }

    /// Mint a per-tab identity context (its own cookie jar / cache),
    /// optionally routed through a proxy exactly as the spike proved:
    /// `set_preference("proxy", {mode:"fixed_servers", server:<url>})`
    /// on the context's base preference manager. An ephemeral context
    /// gets an EMPTY cache path — CEF's in-memory incognito store, wiped
    /// with the context, so nothing has to be scrubbed off disk.
    pub fn contextCreate(self: *Host, req: proto.ContextCreate) void {
        return self.contextCreateWith(req, &system_context_create_ops);
    }

    fn contextCreateWith(self: *Host, req: proto.ContextCreate, ops: *const ContextCreateOps) void {
        if (req.id == 0 or self.lookupContext(req.id) != null) return;

        var settings = std.mem.zeroes(cef.cef_request_context_settings_t);
        settings.size = @sizeOf(cef.cef_request_context_settings_t);
        // Persistent context: a distinct cache dir under the profile
        // dir, keyed by the sanitized name so cookies follow a named
        // container across helper restarts. Ephemeral leaves it empty.
        //
        // It must be an IMMEDIATE child of `root_cache_path`. CEF's
        // chrome runtime resolves a context cache_path through Chrome's
        // ProfileManager, which only accepts a profile directory whose
        // parent IS the user-data dir; a nested `contexts/<key>` was
        // refused with "Cannot create profile at path" (an ERROR log,
        // no failure return), and every container silently ran without
        // its own profile.
        var path_buf: [1024]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        if (req.ephemeral == 0 and self.profile_dir.len != 0) {
            const dir_key = sanitizeContextName(req.name, self.ownerCtxId(req.id), &name_buf);
            const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.profile_dir, dir_key }) catch return;
            setStr(path, &settings.cache_path);
        }
        defer cef.cef_string_utf16_clear(&settings.cache_path);

        const rc: *cef.cef_request_context_t = ops.create(ops.ctx, &settings) orelse return;

        // A proxied context is all-or-nothing. Registering an rc whose
        // preference was refused would make its views use direct traffic.
        // The proxy is the INSTANCE's route (per-context proxies were
        // removed with per-tab routing); a direct instance leaves it
        // empty and every context is direct.
        if (self.instance_proxy.len != 0 and !applyProxy(rc, self.instance_proxy)) {
            release(&rc.base.base);
            return;
        }

        // The global registration does not reach this context.
        registerExtSchemeOn(rc);

        self.contexts.append(self.gpa, .{
            .id = req.id,
            .rc = rc,
            .ephemeral = req.ephemeral != 0,
            // A persisted context (id below the partition line) is
            // ENGINE-GLOBAL: its id came from the one profile store
            // this engine serves, other connections may name it to
            // share the live session, and owner 0 keeps `dropConn`
            // from destroying it when its first publisher leaves.
            .owner = if (req.ephemeral == 0 and req.id < proto.EPHEMERAL_CTX_BASE)
                0
            else
                self.dispatch_conn,
        }) catch {
            release(&rc.base.base);
            return;
        };
    }

    fn createRequestContextSystem(
        _: ?*anyopaque,
        settings: *const cef.cef_request_context_settings_t,
    ) ?*cef.cef_request_context_t {
        return cef.cef_request_context_create_context(settings, null);
    }

    /// The id the OWNING CLIENT minted for an engine-global context id.
    ///
    /// Persisted ids now cross the wire untranslated (the shared
    /// namespace), so this is normally the identity — but it stays as
    /// the belt for any windowed id reaching a jar path: the persistent
    /// jar directory is named by the id the STORE persisted
    /// (`profile-<name>-<id>`, reconstructed from directory names), and
    /// keying it on a window-shifted id would move a named profile's
    /// cookies into a fresh, empty jar and leave the old one an orphan
    /// the store then sweeps away.
    fn ownerCtxId(self: *const Host, id: u32) u32 {
        const base = self.dispatch_conn *| proto.CONN_ID_WINDOW;
        return if (id >= base) id - base else id;
    }

    /// Drop our reference to a context. Live browsers on it keep their
    /// own references, so their pages survive; no NEW view may name the
    /// id afterwards. An ephemeral (in-memory) context's storage is
    /// released once the last reference goes.
    pub fn contextDestroy(self: *Host, id: u32) void {
        for (self.contexts.items, 0..) |ctx, i| {
            if (ctx.id != id) continue;
            release(&ctx.rc.base.base);
            _ = self.contexts.swapRemove(i);
            // Its jar died with it: keeping shadow entries would make
            // the next reconcile of a REUSED id emit deletions for
            // cookies nothing ever had.
            self.cookieSyncForgetContext(id);
            return;
        }
    }

    /// Publish this host to the CEF callbacks and build the handler set.
    pub fn install(self: *Host) void {
        g_host = self;
        installHandlers();
        // The global context serves context-0 (default-jar) views; a
        // routed instance must proxy it too, or an un-containered tab
        // would leak direct. A refusal here is fatal to the route's
        // promise, so log loudly — the instance still runs (its
        // container views are proxied at create), matching how a failed
        // container proxy refuses just that context.
        if (self.instance_proxy.len != 0) {
            const global_c: ?*cef.cef_request_context_t = cef.cef_request_context_get_global_context();
            const global = global_c orelse return;
            defer release(&global.base.base);
            if (!applyProxy(global, self.instance_proxy))
                std.debug.print("sketerm-web: could not apply route proxy to the global context\n", .{});
        }
    }

    // -- presenter -----------------------------------------------------

    /// Arm the Wayland presenter when the environment asks for it.
    /// Called once by the server after `install`; a helper that is not
    /// a session client gets null and never presents.
    pub fn presenterStart(self: *Host) void {
        self.presenter = presenter.Presenter.start(self.gpa, .{
            .ctx = self,
            .pointer = presenterPointer,
            .scroll = presenterScroll,
            .key = presenterKey,
        });
    }

    /// Whether the presenter came up, for `hello_ack` (a reported fact,
    /// never inferred from the environment by a client).
    pub fn presenterActive(self: *const Host) bool {
        const p = self.presenter orelse return false;
        return p.active;
    }

    /// The display fd for the server's poll set; -1 when none.
    pub fn presenterFd(self: *const Host) c_int {
        const p = self.presenter orelse return -1;
        return p.pollFd();
    }

    pub fn presenterWantsWrite(self: *const Host) bool {
        const p = self.presenter orelse return false;
        return p.wantsWrite();
    }

    /// One poll turn of display service; a disarmed presenter is freed
    /// here so its fd leaves the poll set.
    pub fn presenterPump(self: *Host) void {
        const p = self.presenter orelse return;
        p.pump();
        if (!p.active) {
            p.deinit();
            self.presenter = null;
        }
    }

    /// Views a human may watch: pages, never engine chrome. Background
    /// pages and action popups belong to extensions, inspectors are
    /// engine UI, and a windowed inspector has no frames at all.
    fn presentable(v: *const View) bool {
        return !v.webext_bg and !v.webext_popup and v.devtools_of == 0 and !v.windowed;
    }

    /// New pixels landed in `v.map`: mirror them to the toplevel.
    fn presentPaint(self: *Host, v: *View, rects: []const proto.Rect) void {
        const p = self.presenter orelse return;
        if (!presentable(v)) return;
        p.paint(v.id, v.pw, v.ph, v.scale_x1000, v.map, rects);
    }

    fn presentTitle(self: *Host, v: *View, title: []const u8) void {
        const p = self.presenter orelse return;
        if (!presentable(v)) return;
        p.setTitle(v.id, title);
    }

    /// View lookup, and the multi-client ownership chokepoint: while a
    /// connection's frame is being dispatched, another connection's
    /// view does not exist. Regular ids cannot cross namespaces (the
    /// server's window arithmetic keeps them apart); this check is the
    /// belt for engine-minted ids (inspectors), which pass the edge
    /// untranslated.
    pub fn find(self: *Host, id: u32) ?*View {
        const v = self.findAny(id) orelse return null;
        if (self.dispatch_conn != 0 and v.owner != 0 and v.owner != self.dispatch_conn) return null;
        return v;
    }

    /// Lookup without the ownership check — for the host's own routing
    /// and cleanup, never for dispatching a client's frame.
    fn findAny(self: *Host, id: u32) ?*View {
        for (self.views.items) |v| {
            if (v.id == id) return v;
        }
        return null;
    }

    fn findCef(self: *Host, cef_id: c_int) ?*View {
        for (self.views.items) |v| {
            if (v.cef_id == cef_id) return v;
        }
        return null;
    }

    pub fn viewCount(self: *const Host) usize {
        return self.views.items.len;
    }

    /// Create a windowless browser showing a blank document.
    pub fn createView(self: *Host, req: proto.ViewCreate) !void {
        return self.createViewAt(req, "");
    }

    /// Create a windowless browser AT `req.url` (capability
    /// `view-create-url`): the browser's first and only document is the
    /// requested page, where create-then-navigate would have loaded
    /// about:blank first.
    pub fn createViewUrl(self: *Host, req: proto.ViewCreateUrl) !void {
        return self.createViewAt(.{
            .view = req.view,
            .w = req.w,
            .h = req.h,
            .scale_x1000 = req.scale_x1000,
            .context = req.context,
        }, req.url);
    }

    /// Create a windowless browser for `id`. A duplicate id is ignored
    /// (view ids are client-allocated and never reused). An empty
    /// `initial_url` means a blank document.
    fn createViewAt(self: *Host, req: proto.ViewCreate, initial_url: []const u8) !void {
        return self.createViewAtWith(req, initial_url, &system_browser_spawn_ops);
    }

    fn createViewAtWith(self: *Host, req: proto.ViewCreate, initial_url: []const u8, ops: *const BrowserSpawnOps) !void {
        if (req.view == 0 or self.find(req.view) != null) return;
        if (req.context != 0 and self.lookupContext(req.context) == null) {
            self.post(proto.EvViewCreateFailed{
                .view = req.view,
                .context = req.context,
                .reason = "requested browser context does not exist",
            });
            return;
        }
        const v = try self.registerView(req);
        // registerView transferred ownership to Host.views. From here on
        // every failure leaves cleanup to that owner, never to spawnBrowser.
        errdefer self.destroyView(v.id);
        // CEF refuses a browser TRANSIENTLY while a persistent profile a
        // SIGKILLed predecessor held is still in recovery (reproduced in
        // every third focused smoke run once engines began surviving
        // kills). Deterministic bring-up is this engine's contract now:
        // pump CEF and retry briefly, and only a refusal that outlasts
        // the budget becomes a DESCRIBED failure — never a cut
        // connection, which blamed the client with a bare ECONNRESET.
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            const spawned: bool = if (self.spawnBrowserWith(v, initial_url, ops)) |_| true else |err| switch (err) {
                error.BrowserCreateFailed => false,
                else => return err,
            };
            if (spawned) return;
            if (attempt >= ops.create_retries) break;
            var pumps: u32 = 0;
            while (pumps < 10) : (pumps += 1) {
                pump();
                _ = c.usleep(30_000);
            }
        }
        std.debug.print("sketerm-web: browser create failed for view {d} (context {d}) after retries\n", .{ v.id, v.context });
        const view_id = v.id;
        const ctx_id = v.context;
        self.destroyView(view_id);
        self.post(proto.EvViewCreateFailed{
            .view = view_id,
            .context = ctx_id,
            .reason = "the engine could not create a browser (transient engine condition; retry)",
        });
    }

    /// Construct a view and transfer ownership only after it is in the list.
    fn registerView(self: *Host, req: proto.ViewCreate) !*View {
        const v = try self.gpa.create(View);
        errdefer self.gpa.destroy(v);
        const scale: u16 = if (req.scale_x1000 == 0) 1000 else req.scale_x1000;
        const lw = @max(req.w, 1);
        const lh = @max(req.h, 1);
        v.* = .{
            .id = req.view,
            .owner = self.dispatch_conn,
            .inline_view = self.dispatch_inline,
            .w = lw,
            .h = lh,
            .scale_x1000 = scale,
            .pw = physicalOf(lw, scale),
            .ph = physicalOf(lh, scale),
            .context = req.context,
            .sem = semantic.View.init(self.gpa),
        };
        errdefer v.sem.deinit();
        try self.views.append(self.gpa, v);
        return v;
    }

    /// Register the inspector view for `src`.
    ///
    /// Through `registerView`/`destroyView` like every other view, so
    /// `Host.views` stays the single owner: this used to append by hand
    /// and unwind with `views.pop()`, which drops whatever a
    /// `swapRemove` moved into the last slot rather than the view it
    /// meant.
    fn registerDevtoolsView(self: *Host, src: *View) !*View {
        self.next_devtools +%= 1;
        if (self.next_devtools < proto.DEVTOOLS_VIEW_BASE) self.next_devtools = proto.DEVTOOLS_VIEW_BASE + 1;
        const v = try self.registerView(.{
            .view = self.next_devtools,
            // The client resizes it the moment its surface is laid out;
            // this is only what the first layout happens at.
            .w = src.w,
            .h = src.h,
            .scale_x1000 = src.scale_x1000,
            // The inspector is engine UI, never a container's page.
            .context = 0,
        });
        v.devtools_of = src.id;
        src.devtools_view = v.id;
        return v;
    }

    /// Give an EXISTING view record a windowless browser at
    /// `initial_url`, plus the frame buffer that makes it visible.
    ///
    /// Both the first creation and a post-discard revival come through
    /// here, which is what makes a revived view identical to a fresh one
    /// in everything but its id: same window info, same per-browser
    /// opaque background, same zoom-carried scale, same buffer
    /// announcement. The caller owns the view record throughout and
    /// decides whether a failure destroys it or leaves it discarded.
    fn spawnBrowser(self: *Host, v: *View, initial_url: []const u8) !void {
        return self.spawnBrowserWith(v, initial_url, &system_browser_spawn_ops);
    }

    fn spawnBrowserWith(self: *Host, v: *View, initial_url: []const u8, ops: *const BrowserSpawnOps) !void {
        // Refuse BEFORE the engine is asked: a vanished container must
        // never resolve to the global context. This covers the revival
        // of a discarded view, whose container can be destroyed while it
        // holds no browser at all. The reference the engine consumes is
        // minted by `createBrowserSystem`; taking one here as well leaked
        // it per spawn, and an ephemeral context that never reaches zero
        // never wipes its in-memory jar.
        try self.requireContext(v);
        const browser = ops.create_browser(ops.ctx, self, v, initial_url) orelse return error.BrowserCreateFailed;
        v.browser = browser;
        v.cef_id = browserInt(browser, "get_identifier");
        interceptRegister(self.gpa, v.id, v.cef_id);
        applyZoom(v);
        // A revived (or freshly created) browser knows nothing of the
        // client's earlier `a11y_enable`; re-apply it. ALWAYS, including
        // the off case: leaving the engine at STATE_DEFAULT lets it turn
        // accessibility on by ITSELF whenever the platform looks like it
        // wants it (an at-spi bus on the session, i.e. every GNOME/KDE
        // desktop with toolkit-accessibility set). The whole a11y block
        // is opt-in per view — a view that never asked must not have the
        // engine's AX machinery running behind the client's back.
        applyA11yState(v);
        try self.allocBufferWith(v, ops);
    }

    fn createBrowserSystem(_: ?*anyopaque, self: *Host, v: *View, initial_url: []const u8) ?*cef.cef_browser_t {
        var winfo = windowlessInfo(v);
        var bsettings = windowlessSettings(v);

        var url = std.mem.zeroes(cef.cef_string_t);
        setStr(if (initial_url.len != 0) initial_url else "about:blank", &url);
        defer cef.cef_string_utf16_clear(&url);

        self.pending = v;
        defer self.pending = null;
        const browser = cef.cef_browser_host_create_browser_sync(
            &winfo,
            &client,
            &url,
            &bsettings,
            null,
            self.contextForSpawn(v) catch return null,
        );
        return browser;
    }

    fn createMemfdSystem(_: ?*anyopaque) ?c_int {
        // Darwin has no memfd_create; `platform.anonFileFd` is the one
        // place that difference lives (shm_open + immediate unlink
        // there). Size 0 means "create, do not size": a macOS shm object
        // accepts ftruncate EXACTLY ONCE, and `truncateSystem` needs
        // that one call to set the view's real dimensions. Sizing it to
        // 0 here instead cost the whole browser — the second ftruncate
        // returned EINVAL, the frame buffer stayed empty and the helper
        // gave up the socket right after the handshake.
        if (builtin.target.os.tag == .macos) {
            const fd = platform.anonFileFd(0);
            return if (fd >= 0) fd else null;
        }
        const fd = memfd_create("sketerm-web-view", MFD_CLOEXEC);
        return if (fd >= 0) fd else null;
    }

    fn truncateSystem(_: ?*anyopaque, fd: c_int, size: usize) bool {
        return c.ftruncate(fd, @intCast(size)) == 0;
    }

    fn mapSystem(_: ?*anyopaque, size: usize, shared: bool, fd: c_int) ?FrameMap {
        const flags = if (shared) c.MAP_SHARED else c.MAP_PRIVATE | c.MAP_ANONYMOUS;
        const addr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, flags, fd, 0);
        if (addr == c.MAP_FAILED) return null;
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
        return bytes[0..size];
    }

    fn announceBufferSystem(_: ?*anyopaque, self: *Host, v: *View, fd: c_int) !void {
        const r = self.routeFor(v.id) orelse return error.OwnerGone;
        try r.out.post(toClientIds(proto.FrameBuffer{
            .view = v.id,
            .buf_id = v.buf_id,
            .w = v.pw,
            .h = v.ph,
            .stride = v.stride(),
        }, r.base), fd);
    }

    /// Enumerated exits for everything that could wait on `id` forever.
    ///
    /// Held webRequests (a page whose requests are held, or a background
    /// page that was going to answer them), runtime.connect Ports (the
    /// surviving peer must get onDisconnect), routed sendMessage slots
    /// and openPopup waits all resolve here; EVERY path that removes a
    /// view from the table must run these sweeps.
    fn abandonViewWaiters(self: *Host, id: u32) void {
        wreqAbandonView(id);
        self.portsAbandonView(id);
        self.repliesAbandonView(id);
    }

    pub fn destroyView(self: *Host, id: u32) void {
        self.abandonViewWaiters(id);
        // A page owns every browser-action popup it opened. Close those
        // first so no floating extension page survives its toolbar.
        while (self.popupForOwner(id)) |popup| self.destroyView(popup.id);
        for (self.views.items, 0..) |v, i| {
            if (v.id != id) continue;
            _ = self.views.swapRemove(i);
            // An inspector outliving its target inspects nothing and
            // has no client surface left to close it, so it goes too;
            // an inspector being closed simply frees its target's slot.
            const inspector = v.devtools_view;
            if (v.devtools_of != 0) {
                if (self.find(v.devtools_of)) |src| src.devtools_view = 0;
            }
            if (self.adopting == v) self.adopting = null;
            if (v.webext_popup) self.post(proto.EvWebextPopup{
                .owner_view = v.popup_owner,
                .popup_view = v.id,
                .state = proto.webext_popup_closed,
                .detail = "",
            });
            self.freeView(v);
            if (inspector != 0) self.destroyView(inspector);
            return;
        }
    }

    fn popupForOwner(self: *Host, owner: u32) ?*View {
        for (self.views.items) |v| {
            if (v.webext_popup and v.popup_owner == owner) return v;
        }
        return null;
    }

    fn popupClosedByEngine(self: *Host, id: u32) void {
        for (self.views.items, 0..) |v, i| {
            if (v.id != id or !v.webext_popup) continue;
            self.abandonViewWaiters(id);
            _ = self.views.swapRemove(i);
            self.post(proto.EvWebextPopup{
                .owner_view = v.popup_owner,
                .popup_view = v.id,
                .state = proto.webext_popup_closed,
                .detail = "",
            });
            self.freeViewOpts(v, false);
            return;
        }
    }

    pub fn destroyAll(self: *Host) void {
        self.adopting = null;
        while (self.views.pop()) |v| self.freeView(v);
    }

    /// One connection is gone: destroy ITS views and contexts, leave
    /// everyone else's alone. The engine keeps running for the clients
    /// that remain; the last connection leaving is the server's cue to
    /// exit through the ordinary destroyAll + drain path — the ONLY
    /// path that reaches `cef_shutdown`, which is what flushes a
    /// persistent profile's cookie jar to disk.
    pub fn dropConn(self: *Host, conn_id: u32) void {
        if (conn_id == 0) return;
        self.cookieSyncDropConn(conn_id);
        // destroyView mutates the list (and closes popup/inspector
        // dependents itself), so collect ids first and re-check each.
        while (true) {
            var target: u32 = 0;
            for (self.views.items) |v| {
                if (v.owner == conn_id) {
                    target = v.id;
                    break;
                }
            }
            if (target == 0) break;
            self.destroyView(target);
        }
        while (true) {
            var ctx_id: u32 = 0;
            for (self.contexts.items) |ctx| {
                // Persisted contexts carry owner 0 (engine-global, the
                // shared-profile namespace) and survive any one
                // client's exit; the engine's own teardown releases
                // them, and that exit path (`cef_shutdown`) is what
                // flushes their jars.
                if (ctx.owner == conn_id) {
                    ctx_id = ctx.id;
                    break;
                }
            }
            if (ctx_id == 0) break;
            self.contextDestroy(ctx_id);
        }
        // Bare policy slots: `net_policy_set` before `view_create`
        // reserves a slot the view sweep above cannot see (no view
        // exists). Without this, a client that policied ids it never
        // opened would pin slots from the shared MAX_POLICY_VIEWS pool
        // until engine exit.
        const base = conn_id *| proto.CONN_ID_WINDOW;
        var slot_ids: [proto.MAX_POLICY_VIEWS]u32 = undefined;
        var n: usize = 0;
        {
            g_int.acquire();
            defer g_int.release();
            for (&g_int.slots) |*s| {
                if (!s.used) continue;
                if (s.view_id < base or s.view_id >= base + proto.CONN_ID_WINDOW) continue;
                slot_ids[n] = s.view_id;
                n += 1;
            }
        }
        for (slot_ids[0..n]) |vid| {
            if (self.findAny(vid) != null) continue;
            interceptUnregister(self.gpa, vid);
        }
    }

    /// `view_discard`: destroy the browser, keep the view.
    ///
    /// The record — id, logical geometry, scale, fps cap, USER ZOOM and
    /// the address in `v.url` — survives; the browser, its render
    /// process, the frame buffer and the whole semantic shadow tree do
    /// not. The revival therefore re-applies the zoom itself
    /// (`spawnBrowser` -> `applyZoom`) and the client never re-sends
    /// one, unlike the helper-restart path where the record is gone
    /// too. Sending this for a view that is already discarded (or
    /// unknown) does nothing.
    pub fn discardView(self: *Host, id: u32) void {
        const v = self.find(id) orelse return;
        if (v.discarded) return;
        self.dropBrowser(v, true);
        v.discarded = true;
        // The engine is gone, so nothing may be asked of it: hidden is
        // what keeps the watchdog and every paint path off this view
        // until it is revived.
        v.hidden = true;
    }

    /// Bring a discarded view's browser back at the address it held.
    ///
    /// The client is told nothing: the id, the geometry and the scale
    /// are the ones it already knows, and the only thing it observes is
    /// a fresh `frame_buffer` plus the load of the same url — i.e. a
    /// reload. The navigation history is NOT restored (see
    /// `View.discarded`).
    fn reviveView(self: *Host, v: *View) void {
        return self.reviveViewWith(v, &system_browser_spawn_ops);
    }

    fn reviveViewWith(self: *Host, v: *View, ops: *const BrowserSpawnOps) void {
        if (!v.discarded) return;
        // `spawnBrowser` can reach `setUrl` through an address-change
        // callback fired inside create_browser_sync, which would free
        // the very slice it is loading; the copy costs one url.
        const url = self.gpa.dupe(u8, v.url) catch return;
        defer self.gpa.free(url);
        self.reviveAtWith(v, url, ops);
    }

    /// Revive a discarded view AT `url` — the same single document a
    /// fresh `view_create_url` produces, which is why a navigation into
    /// a discarded view does not first load the address it had.
    fn reviveAt(self: *Host, v: *View, url: []const u8) void {
        return self.reviveAtWith(v, url, &system_browser_spawn_ops);
    }

    fn reviveAtWith(self: *Host, v: *View, url: []const u8, ops: *const BrowserSpawnOps) void {
        const id = v.id;
        v.discarded = false;
        v.hidden = false;
        self.spawnBrowserWith(v, url, ops) catch |err| {
            // Browser creation used to leave the retained record
            // discarded, while a later frame-buffer failure destroyed it.
            // Keep that distinction while making this owner perform both.
            // A vanished container joins the first group: the record is
            // worth keeping (the client still knows the id) and the page
            // must not come back on the global context.
            if (err == error.BrowserCreateFailed or err == error.ContextGone) {
                v.discarded = true;
            } else {
                self.destroyView(id);
            }
        };
    }

    /// The view a SHOW/navigation/input frame names, revived first if it
    /// was discarded — those frames are exactly the ones that mean
    /// "somebody is using this page again". Null when the id is unknown
    /// or the revival failed, which every caller treats as "ignore".
    fn findWake(self: *Host, id: u32) ?*View {
        return self.findWakeWith(id, &system_browser_spawn_ops);
    }

    fn findWakeWith(self: *Host, id: u32, ops: *const BrowserSpawnOps) ?*View {
        var v = self.find(id) orelse return null;
        if (v.discarded) {
            self.reviveViewWith(v, ops);
            // A failed revival is `reviveAt`'s to own, and everything but
            // `BrowserCreateFailed` DESTROYS the record, so the pointer
            // is re-established from the table rather than dereferenced
            // again. Reading `v.discarded` off freed memory returned the
            // dangling view to callers that then wrote through it.
            v = self.find(id) orelse return null;
        }
        if (v.discarded) return null;
        return v;
    }

    // -- devtools ------------------------------------------------------

    /// Open the engine's inspector for a view, AS ANOTHER VIEW.
    ///
    /// `show_dev_tools` with a windowless `cef_window_info_t` and our
    /// own client makes the inspector an ordinary OSR browser: it
    /// paints through the same `on_paint`/`on_accelerated_paint`, takes
    /// the same input frames, and is closed with `view_destroy`. That
    /// is the whole reason no remote debugging PORT is involved.
    ///
    /// The browser does NOT exist when this returns — CEF creates it on
    /// its own schedule and announces it in `on_after_created`, which
    /// is where the view is finished and `ev_devtools_view` is posted.
    /// Every path answers exactly once, so a client can always wait for
    /// one reply.
    pub fn devtoolsShow(self: *Host, req: proto.DevToolsShow) !void {
        const src = self.find(req.view) orelse {
            self.post(proto.EvDevToolsView{ .view = req.view, .devtools = 0, .reason = "no such view" });
            return;
        };
        // Already open: the client gets the id it has, not a second
        // inspector for the same page — or, for the engine-window
        // fallback, the same "no view, it is a window" answer.
        if (src.devtools_view != 0) {
            if (self.find(src.devtools_view)) |dev| {
                if (dev.windowed) {
                    focusDevTools(src);
                    self.post(proto.EvDevToolsView{ .view = req.view, .devtools = 0, .reason = "windowed" });
                } else {
                    self.post(proto.EvDevToolsView{ .view = req.view, .devtools = src.devtools_view, .reason = "" });
                }
                return;
            }
            src.devtools_view = 0;
        }
        const host = browserHost(src) orelse {
            self.post(proto.EvDevToolsView{ .view = req.view, .devtools = 0, .reason = "no browser" });
            return;
        };
        defer release(&host.base);
        const show = host.show_dev_tools orelse {
            self.post(proto.EvDevToolsView{ .view = req.view, .devtools = 0, .reason = "unsupported" });
            return;
        };
        // An inspector this helper does NOT track as a view: the
        // engine-window fallback below already gave this page one.
        // `show_dev_tools` then only FOCUSES it and creates no browser,
        // so nothing would ever announce it — answer here instead, and
        // let the call through so the focus still happens.
        const has = if (host.has_dev_tools) |f| f(host) != 0 else false;
        if (has) {
            show(host, null, null, null, null);
            self.post(proto.EvDevToolsView{ .view = req.view, .devtools = 0, .reason = "windowed" });
            return;
        }

        const v = try self.registerDevtoolsView(src);
        errdefer self.destroyView(v.id);

        var winfo = windowlessInfo(v);
        var bsettings = windowlessSettings(v);
        var point = cef.cef_point_t{ .x = 0, .y = 0 };
        const inspect = req.x != 0 or req.y != 0;
        if (inspect) {
            const pt = viewPoint(src, req.x, req.y);
            point = .{ .x = pt.x, .y = pt.y };
        }
        self.adopting = v;
        self.adopting_ms = nowMs();
        show(host, &winfo, &client, &bsettings, if (inspect) &point else null);
    }

    /// Finish an inspector view once CEF hands over its browser, and
    /// tell the client which view id it may drive. Called from
    /// `on_after_created` for a browser no view claims.
    fn adoptBrowser(self: *Host, v: *View, browser: *cef.cef_browser_t) void {
        self.adopting = null;
        // `on_after_created`'s browser arrives with a reference the
        // callback OWNS (libcef wraps every argument with a reference for
        // the receiver); adopting keeps that reference as `v.browser`, the
        // same one `create_browser_sync` returns on the other path, and
        // `freeView` releases it either way.
        v.browser = browser;
        v.cef_id = browserInt(browser, "get_identifier");
        // DID THE ENGINE HONOUR THE WINDOWLESS REQUEST?
        //
        // MEASURED (CEF 151.3.16, the Arch `cef` package and the pinned
        // upstream build alike): it does NOT. `show_dev_tools` with a
        // windowless `cef_window_info_t` logs "Windowless rendering is
        // not supported for this DevTools window" from
        // chrome_browser_delegate.cc and creates an ORDINARY WINDOWED
        // DevTools browser instead — `is_window_rendering_disabled()`
        // on it answers 0. Nothing in the window info moves that:
        // runtime_style is already ALLOY (what `SetAsWindowless` sets)
        // and the inspected browser is itself windowless.
        //
        // The window it made is real, working DevTools, so it is LEFT
        // OPEN and the client is told there is no VIEW to present
        // (`devtools = 0` plus the reason). The client turns that into
        // "DevTools opened in its own window" rather than an empty
        // pane. Everything below is the path an engine that honours the
        // request takes, and it runs the moment one does.
        if (!isWindowless(v)) {
            // The view stays in the table WITHOUT a frame buffer: it is
            // how the window gets closed when its target goes away, and
            // how `cef_shutdown` finds no browser left open (it aborts
            // the process otherwise — that is how this was found).
            v.windowed = true;
            self.post(proto.EvDevToolsView{
                .view = v.devtools_of,
                .devtools = 0,
                .reason = "windowed",
            });
            return;
        }
        applyZoom(v);
        // THE ID GOES OUT FIRST, before the view's `frame_buffer`.
        // A client learns which view an inspector is from this frame
        // alone, and one that has not seen it yet has nowhere to put
        // the buffer — the GUI drops a frame for an unknown view and
        // would then wait for a repaint that only a geometry change
        // produces.
        self.post(proto.EvDevToolsView{ .view = v.devtools_of, .devtools = v.id, .reason = "" });
        // A view with no frame buffer can never be seen. Nothing but
        // OOM gets here, and the client's pane simply stays blank
        // until it is closed; a second `devtools_show` mints a fresh
        // inspector, because destroying this one frees the slot.
        self.allocBuffer(v) catch self.destroyView(v.id);
    }

    // -- print to PDF --------------------------------------------------

    /// Render a view to a PDF file. The answer is always exactly one
    /// `ev_print_pdf_done`, including for a view that does not exist —
    /// a client waiting on a save must never wait forever.
    pub fn printPdf(self: *Host, req: proto.PrintPdf) void {
        const v = self.find(req.view) orelse {
            self.post(proto.EvPrintPdfDone{ .view = req.view, .ok = 0, .path = req.path });
            return;
        };
        const host = browserHost(v) orelse {
            self.post(proto.EvPrintPdfDone{ .view = req.view, .ok = 0, .path = req.path });
            return;
        };
        defer release(&host.base);
        const print = host.print_to_pdf orelse {
            self.post(proto.EvPrintPdfDone{ .view = req.view, .ok = 0, .path = req.path });
            return;
        };
        const owned = self.gpa.dupe(u8, req.path) catch {
            self.post(proto.EvPrintPdfDone{ .view = req.view, .ok = 0, .path = req.path });
            return;
        };
        self.prints.append(self.gpa, .{ .view = v.id, .path = owned }) catch {
            self.gpa.free(owned);
            self.post(proto.EvPrintPdfDone{ .view = req.view, .ok = 0, .path = req.path });
            return;
        };

        var settings = std.mem.zeroes(cef.cef_pdf_print_settings_t);
        settings.size = @sizeOf(cef.cef_pdf_print_settings_t);
        settings.landscape = if (req.flags & proto.print_flag_landscape != 0) 1 else 0;
        settings.print_background = if (req.flags & proto.print_flag_background != 0) 1 else 0;
        if (proto.paperInches(req.paper)) |sheet| {
            settings.paper_width = sheet.w;
            settings.paper_height = sheet.h;
        }
        var path = std.mem.zeroes(cef.cef_string_t);
        setStr(req.path, &path);
        defer cef.cef_string_utf16_clear(&path);
        print(host, &path, &settings, &pdf_callback);
    }

    /// The engine finished writing (or failed to write) a PDF. The
    /// path is the correlation key: CEF's callback carries no request
    /// id, and a client may have several prints in flight.
    fn onPrintDone(self: *Host, path: []const u8, ok: bool) void {
        for (self.prints.items, 0..) |p, i| {
            if (!std.mem.eql(u8, p.path, path)) continue;
            const done = self.prints.orderedRemove(i);
            defer self.gpa.free(done.path);
            self.post(proto.EvPrintPdfDone{
                .view = done.view,
                .ok = if (ok) 1 else 0,
                .path = done.path,
            });
            return;
        }
    }

    // -- cookies + site data (capability "sitedata") -------------------

    /// This view's request context, WITH a reference held.
    ///
    /// The browser's own context is the authority (it is the one the
    /// page's requests actually use), but a DISCARDED view has no
    /// browser at all and still has cookies to show, so the container
    /// it was created in answers for it — and view 0's shared jar is
    /// the engine's global context.
    fn requestContextFor(self: *Host, v: *View) ?*cef.cef_request_context_t {
        if (browserHost(v)) |bh| {
            defer release(&bh.base);
            if (bh.get_request_context) |get| {
                if (get(bh)) |rc| return rc;
            }
        }
        if (v.context != 0) {
            // Same rule as `contextForSpawn`: the global context is a
            // DIFFERENT cookie jar and a different cache, so answering a
            // container view from it would report and delete the wrong
            // site's data. No context is an honest failure.
            const rc = self.lookupContext(v.context) orelse return null;
            if (rc.base.base.add_ref) |add| add(&rc.base.base);
            return rc;
        }
        const global: ?*cef.cef_request_context_t = cef.cef_request_context_get_global_context();
        return global;
    }

    /// This view's cookie manager, WITH a reference held.
    fn cookieManagerFor(self: *Host, v: *View) ?*cef.cef_cookie_manager_t {
        const rc = self.requestContextFor(v) orelse return null;
        defer release(&rc.base.base);
        const get = rc.get_cookie_manager orelse return null;
        const mgr: ?*cef.cef_cookie_manager_t = get(rc, null);
        return mgr;
    }

    /// Force every persistent jar to disk (`flush_req`, and the engine's
    /// own periodic cadence with `conn == 0`). Chromium commits cookies
    /// on a ~30s timer and `cef_shutdown` is otherwise the only forced
    /// flush — a long-lived engine needs this to close the loss window.
    /// The GLOBAL context is included: with a durable store root, its
    /// shared jar is persistent too.
    pub fn flushProfileStores(self: *Host, token: u32, conn: u32) void {
        var outstanding: u32 = 0;
        const global: ?*cef.cef_cookie_manager_t = cef.cef_cookie_manager_get_global_manager(null);
        if (global) |mgr| {
            defer release(&mgr.base);
            if (flushOne(mgr)) outstanding += 1;
        }
        for (self.contexts.items) |ctx| {
            if (ctx.ephemeral) continue;
            const get = ctx.rc.get_cookie_manager orelse continue;
            const mgr: *cef.cef_cookie_manager_t = get(ctx.rc, null) orelse continue;
            defer release(&mgr.base);
            if (flushOne(mgr)) outstanding += 1;
        }
        if (outstanding == 0) {
            // Nothing flushable IS completion; an unanswered flush_req
            // would read as a wedged engine.
            if (conn != 0) self.postFlushed(token, conn);
            return;
        }
        self.pending_flushes.append(self.gpa, .{ .token = token, .conn = conn, .outstanding = outstanding }) catch {
            // Cannot track the completions: answer now rather than
            // never. The flushes themselves are already running.
            if (conn != 0) self.postFlushed(token, conn);
        };
    }

    fn flushOne(mgr: *cef.cef_cookie_manager_t) bool {
        const fs = mgr.flush_store orelse return false;
        return fs(mgr, &flush_callback) != 0;
    }

    /// One anonymous flush completion (see `pending_flushes`).
    fn flushCompleted(self: *Host) void {
        if (self.pending_flushes.items.len == 0) return;
        const p = &self.pending_flushes.items[0];
        if (p.outstanding > 0) p.outstanding -= 1;
        if (p.outstanding == 0) {
            const done = self.pending_flushes.orderedRemove(0);
            if (done.conn != 0) self.postFlushed(done.token, done.conn);
        }
    }

    fn postFlushed(self: *Host, token: u32, conn: u32) void {
        const prev = self.dispatch_conn;
        self.dispatch_conn = conn;
        defer self.dispatch_conn = prev;
        self.post(proto.EvFlushed{ .token = token });
    }

    /// The url a 0xC8-block request is scoped to: what it named, or the
    /// view's current address. Never guessed — an empty result means
    /// "there is no site here yet" and the request is answered as a
    /// failure rather than run against every site at once.
    fn siteUrlOf(v: *View, asked: []const u8) []const u8 {
        return if (asked.len != 0) asked else v.url;
    }

    /// Enumerate the cookies visible to a site (metadata only).
    pub fn cookiesReq(self: *Host, req: proto.CookiesReq) void {
        const v = self.find(req.view) orelse return self.postNoCookies(req.view, req.req);
        const url = siteUrlOf(v, req.url);
        if (url.len == 0) return self.postNoCookies(req.view, req.req);
        const mgr = self.cookieManagerFor(v) orelse return self.postNoCookies(req.view, req.req);
        defer release(&mgr.base);
        CookieJob.start(self.gpa, mgr, url, .{
            .view = req.view,
            .req = req.req,
            .mode = .list,
            .kind = .cookies_clear,
            .name = "",
            .detail = "",
        }) orelse self.postNoCookies(req.view, req.req);
    }

    fn postNoCookies(self: *Host, view: u32, req: u32) void {
        self.post(proto.EvCookies{ .view = view, .req = req, .ok = 0, .total = 0, .entries = &.{} });
    }

    pub fn cookieDelete(self: *Host, req: proto.CookieDelete) void {
        self.deleteCookies(req.view, req.req, req.url, req.name, .cookie_delete, "");
    }

    pub fn cookiesClear(self: *Host, req: proto.CookiesClear) void {
        self.deleteCookies(req.view, req.req, req.url, "", .cookies_clear, "");
    }

    /// Shared body of `cookie_delete` / `cookies_clear` and of the
    /// cookie half of `sitedata_clear`. An empty `name` deletes every
    /// cookie the site can see, host and domain cookies alike — which
    /// is why the deletion runs through the VISITOR rather than
    /// `delete_cookies(url, ...)`, whose url-only form deliberately
    /// spares domain cookies.
    fn deleteCookies(
        self: *Host,
        view: u32,
        req: u32,
        asked_url: []const u8,
        name: []const u8,
        kind: proto.SitedataKind,
        detail: []const u8,
    ) void {
        const v = self.find(view) orelse return self.postSiteFail(view, req, kind, detail);
        const url = siteUrlOf(v, asked_url);
        if (url.len == 0) return self.postSiteFail(view, req, kind, detail);
        const mgr = self.cookieManagerFor(v) orelse return self.postSiteFail(view, req, kind, detail);
        defer release(&mgr.base);
        CookieJob.start(self.gpa, mgr, url, .{
            .view = view,
            .req = req,
            .mode = if (name.len != 0) .delete_named else .delete_all,
            .kind = kind,
            .name = name,
            .detail = detail,
        }) orelse self.postSiteFail(view, req, kind, detail);
    }

    fn postSiteFail(self: *Host, view: u32, req: u32, kind: proto.SitedataKind, detail: []const u8) void {
        self.post(proto.EvSitedataDone{
            .view = view,
            .req = req,
            .ok = 0,
            .kind = @intFromEnum(kind),
            .removed = 0,
            .detail = detail,
        });
    }

    /// Clear an origin's site data: cookies, script-visible storage,
    /// and the HTTP cache, each independently selected by `what`.
    ///
    /// TWO ENGINE LIMITS ARE REPORTED, NOT HIDDEN (see
    /// `EvSitedataDone.detail`):
    ///   - `clear_http_cache` is the only cache verb the C API has and
    ///     it clears the WHOLE request context, so a shared-jar view
    ///     drops every site's cache. Reported as `cache-whole-context`.
    ///   - localStorage / sessionStorage / IndexedDB / Cache Storage
    ///     have no browser-process API at all; they are cleared by
    ///     running script IN the document, which only works while the
    ///     view is still ON that origin. A request for another origin's
    ///     storage is reported as `storage-skipped-origin` rather than
    ///     silently claiming success.
    pub fn sitedataClear(self: *Host, req: proto.SitedataClear) void {
        var detail_buf: [96]u8 = undefined;
        var detail_len: usize = 0;
        const v = self.find(req.view) orelse
            return self.postSiteFail(req.view, req.req, .sitedata_clear, "");
        const url = siteUrlOf(v, req.url);
        if (url.len == 0) return self.postSiteFail(req.view, req.req, .sitedata_clear, "");

        if (req.what & proto.sitedata_storage != 0) {
            if (sameOrigin(url, v.url)) {
                self.clearPageStorage(v);
            } else {
                appendDetail(&detail_buf, &detail_len, "storage-skipped-origin");
            }
        }
        if (req.what & proto.sitedata_cache != 0) {
            if (self.requestContextFor(v)) |rc| {
                defer release(&rc.base.base);
                if (rc.clear_http_cache) |clear| clear(rc, null);
                appendDetail(&detail_buf, &detail_len, "cache-whole-context");
            } else {
                // A destroyed container has no cache left to reach, and
                // claiming success for work nothing performed is what
                // every other arm of this reply refuses to do.
                appendDetail(&detail_buf, &detail_len, "cache-context-gone");
            }
        }
        if (req.what & proto.sitedata_cookies != 0) {
            // The cookie visit is asynchronous and owns the reply, so
            // it carries the detail accumulated above.
            return self.deleteCookies(req.view, req.req, url, "", .sitedata_clear, detail_buf[0..detail_len]);
        }
        self.post(proto.EvSitedataDone{
            .view = req.view,
            .req = req.req,
            .ok = 1,
            .kind = @intFromEnum(proto.SitedataKind.sitedata_clear),
            .removed = 0,
            .detail = detail_buf[0..detail_len],
        });
    }

    // -- cross-instance cookie sync (capability "cookie-sync") --------

    /// Subscribe or unsubscribe one connection. Idempotent both ways.
    /// The IO-thread observer is armed by the FIRST subscriber and
    /// disarmed by the last, so an unsubscribed helper is back to one
    /// relaxed load per saved cookie.
    pub fn cookieSyncEnable(self: *Host, conn: u32, enable: bool) void {
        var i: usize = 0;
        while (i < self.cookie_sync_conns.items.len) : (i += 1) {
            if (self.cookie_sync_conns.items[i] != conn) continue;
            if (!enable) _ = self.cookie_sync_conns.orderedRemove(i);
            self.cookieSyncArm();
            return;
        }
        if (enable) self.cookie_sync_conns.append(self.gpa, conn) catch {};
        self.cookieSyncArm();
    }

    /// Drop a dead connection's subscription (called from `dropConn`).
    pub fn cookieSyncDropConn(self: *Host, conn: u32) void {
        self.cookieSyncEnable(conn, false);
    }

    fn cookieSyncArm(self: *Host) void {
        const on = self.cookie_sync_conns.items.len != 0;
        g_cksync.on.store(on, .release);
        if (on) return;
        // Nobody is listening: the shadow is stale the moment the walk
        // stops, so it is dropped rather than kept and trusted later.
        for (self.cookie_shadow.items) |*sh| sh.free(self.gpa);
        self.cookie_shadow.clearRetainingCapacity();
        self.cookie_shadow_seeded.clearRetainingCapacity();
        g_cksync.drain();
    }

    fn cookieSyncOn(self: *const Host) bool {
        return self.cookie_sync_conns.items.len != 0;
    }

    /// Post one cookie-sync frame to ONE connection, translating the
    /// context id back into that connection's namespace. `Host.post`
    /// cannot do this: it only rewrites ids on VIEW-routed frames, and
    /// every frame in this block is viewless.
    fn postSyncTo(self: *Host, conn: u32, value: anytype) void {
        const rt = self.router orelse {
            self.out.post(value, null) catch {};
            return;
        };
        const out = rt.route(rt.ctx, conn) orelse return;
        var v2 = value;
        // Persisted context ids are a shared namespace and cross
        // verbatim; only ephemeral ones are windowed per connection.
        if (v2.context >= proto.EPHEMERAL_CTX_BASE) v2.context -= conn * proto.CONN_ID_WINDOW;
        out.post(v2, null) catch {};
    }

    /// Fan one change out to every subscriber.
    fn postSyncAll(self: *Host, value: anytype) void {
        if (self.router == null) {
            self.out.post(value, null) catch {};
            return;
        }
        for (self.cookie_sync_conns.items) |conn| self.postSyncTo(conn, value);
    }

    /// The cookie manager for a CONTEXT id, WITH a reference held.
    /// Context 0 is the engine's global jar — which, with a durable
    /// `--cache-dir`, is the per-route profile this whole block exists
    /// to replicate.
    fn cookieManagerForContext(self: *Host, id: u32) ?*cef.cef_cookie_manager_t {
        if (id == 0) return cef.cef_cookie_manager_get_global_manager(null);
        const rc = self.lookupContext(id) orelse return null;
        const get = rc.get_cookie_manager orelse return null;
        return get(rc, null);
    }

    /// Every context this helper synchronises: the shared jar plus each
    /// live identity context.
    fn cookieSyncContexts(self: *Host, buf: []u32) []u32 {
        var n: usize = 0;
        buf[n] = 0;
        n += 1;
        for (self.contexts.items) |ctx| {
            if (n >= buf.len) break;
            buf[n] = ctx.id;
            n += 1;
        }
        return buf[0..n];
    }

    /// One turn of the cookie-sync machinery, called from the server
    /// loop: drain what the IO thread saw, then reconcile on cadence.
    pub fn cookieSyncPump(self: *Host, now: i64) void {
        if (!self.cookieSyncOn()) return;
        self.drainSavedCookies();
        if (self.cookie_reconcile_busy != 0) return;
        if (now - self.cookie_reconcile_ms < cookieReconcileMs()) return;
        self.cookie_reconcile_ms = now;
        var ctx_buf: [64]u32 = undefined;
        const ctxs = self.cookieSyncContexts(&ctx_buf);
        for (ctxs) |id| {
            const mgr = self.cookieManagerForContext(id) orelse continue;
            defer release(&mgr.base);
            if (SyncVisitJob.start(self.gpa, mgr, .{
                .mode = .reconcile,
                .context = id,
                .conn = 0,
                .req = 0,
                .cursor = 0,
            })) |_| self.cookie_reconcile_busy += 1;
        }
    }

    /// MAIN THREAD. Fold everything `can_save_cookie` recorded into the
    /// shadow and emit it. A response-header write is emitted from HERE
    /// rather than waiting for the next reconcile so a login propagates
    /// in milliseconds, and folding it into the shadow at the same time
    /// is what stops the reconcile emitting it a second time.
    fn drainSavedCookies(self: *Host) void {
        var rec: CkRec = undefined;
        while (g_cksync.take(&rec)) {
            // The IO thread could only record the VIEW; the context is
            // main-thread state.
            const context = if (rec.view_id == 0) 0 else blk: {
                const v = self.findAny(rec.view_id) orelse break :blk 0;
                break :blk v.context;
            };
            const ck = proto.SyncCookie{
                .name = rec.slice(&rec.name, rec.name_len),
                .value = rec.slice(&rec.value, rec.value_len),
                .domain = rec.slice(&rec.domain, rec.domain_len),
                .path = rec.slice(&rec.path, rec.path_len),
                .flags = rec.flags,
                .same_site = rec.same_site,
                .priority = rec.priority,
                .creation_ms = rec.creation_ms,
                .last_access_ms = rec.last_access_ms,
                .expires_ms = rec.expires_ms,
            };
            // A Set-Cookie whose expiry is already past IS a deletion;
            // saying so beats making every client rediscover it.
            const removed = ck.expires_ms != 0 and ck.expires_ms <= wallMsNow();
            self.noteCookie(context, ck, removed, .response_header, rec.slice(&rec.url, rec.url_len));
        }
    }

    /// Fold one observation into the shadow and emit it when it is
    /// genuinely new. THE one place a change reaches the wire.
    ///
    /// An identity with an apply in flight is skipped outright: the jar
    /// and the shadow disagree until the engine's completion callback
    /// lands, and emitting that disagreement is exactly the ping-pong
    /// this block must not have.
    fn noteCookie(
        self: *Host,
        context: u32,
        ck: proto.SyncCookie,
        removed: bool,
        cause: proto.CookieCause,
        url: []const u8,
    ) void {
        const idh = CookieShadow.identity(context, ck.domain, ck.path, ck.name);
        const sh = self.shadowFind(idh, context, ck.domain, ck.path, ck.name);
        const vh = CookieShadow.valueHash(ck);
        if (sh) |entry| {
            if (entry.pending) return;
            if (removed) {
                entry.free(self.gpa);
                self.shadowRemove(entry);
            } else {
                if (entry.hash == vh) return;
                entry.hash = vh;
                entry.seen = true;
            }
        } else {
            if (removed) return; // never seen it, nothing to forget
            const entry = self.shadowInsert(idh, context, ck) orelse return;
            entry.hash = vh;
        }
        self.postSyncAll(proto.EvCookieChange{
            .context = context,
            .cause = @intFromEnum(cause),
            .removed = if (removed) 1 else 0,
            .url = url,
            .cookie = ck,
        });
    }

    fn shadowFind(
        self: *Host,
        idh: u64,
        context: u32,
        domain: []const u8,
        path: []const u8,
        name: []const u8,
    ) ?*CookieShadow {
        for (self.cookie_shadow.items) |*sh| {
            if (sh.id_hash != idh or sh.context != context) continue;
            // The hash is a PREFILTER, never the identity: a collision
            // would otherwise silently replicate the wrong cookie.
            if (!std.mem.eql(u8, CookieShadow.normDomain(sh.domain), CookieShadow.normDomain(domain))) continue;
            if (!std.mem.eql(u8, sh.path, path)) continue;
            if (!std.mem.eql(u8, sh.name, name)) continue;
            return sh;
        }
        return null;
    }

    fn shadowInsert(self: *Host, idh: u64, context: u32, ck: proto.SyncCookie) ?*CookieShadow {
        const entry = CookieShadow.init(self.gpa, idh, context, ck) orelse return null;
        self.cookie_shadow.append(self.gpa, entry) catch {
            var tmp = entry;
            tmp.free(self.gpa);
            return null;
        };
        return &self.cookie_shadow.items[self.cookie_shadow.items.len - 1];
    }

    fn shadowRemove(self: *Host, entry: *CookieShadow) void {
        const base = self.cookie_shadow.items.ptr;
        const idx = (@intFromPtr(entry) - @intFromPtr(base)) / @sizeOf(CookieShadow);
        _ = self.cookie_shadow.orderedRemove(idx);
    }

    /// Drop every shadow entry for a context (its jar went away with
    /// it, so remembering its cookies would resurrect them).
    pub fn cookieSyncForgetContext(self: *Host, context: u32) void {
        var i: usize = 0;
        while (i < self.cookie_shadow.items.len) {
            if (self.cookie_shadow.items[i].context != context) {
                i += 1;
                continue;
            }
            self.cookie_shadow.items[i].free(self.gpa);
            _ = self.cookie_shadow.orderedRemove(i);
        }
        var j: usize = 0;
        while (j < self.cookie_shadow_seeded.items.len) {
            if (self.cookie_shadow_seeded.items[j] == context) {
                _ = self.cookie_shadow_seeded.orderedRemove(j);
                continue;
            }
            j += 1;
        }
    }

    fn shadowSeeded(self: *Host, context: u32) bool {
        for (self.cookie_shadow_seeded.items) |id| {
            if (id == context) return true;
        }
        return false;
    }

    fn markShadowSeeded(self: *Host, context: u32) void {
        if (self.shadowSeeded(context)) return;
        self.cookie_shadow_seeded.append(self.gpa, context) catch {};
    }

    /// Write (or remove) one cookie in another instance's stead.
    ///
    /// LOOP PREVENTION, structurally: the identity is marked pending
    /// BEFORE the engine call and its shadow entry is settled to the
    /// applied value in the completion callback. A reconcile between
    /// the two skips the identity entirely, so neither ordering of the
    /// two asynchronous events can produce a spurious change — and once
    /// settled, the shadow already equals the jar, so the diff is empty.
    pub fn cookieApply(self: *Host, req: proto.CookieApply) void {
        const conn = self.dispatch_conn;
        if (req.url.len == 0 or originSlice(req.url).len == 0)
            return self.postApplyDone(conn, req.req, req.context, false, "bad-url");
        const mgr = self.cookieManagerForContext(req.context) orelse
            return self.postApplyDone(conn, req.req, req.context, false, "no-context");
        defer release(&mgr.base);

        const idh = CookieShadow.identity(req.context, req.cookie.domain, req.cookie.path, req.cookie.name);
        var entry = self.shadowFind(idh, req.context, req.cookie.domain, req.cookie.path, req.cookie.name);
        if (entry == null and req.remove == 0) {
            entry = self.shadowInsert(idh, req.context, req.cookie);
        }
        if (entry) |e| {
            e.pending = true;
            e.pending_remove = req.remove != 0;
            e.pending_hash = CookieShadow.valueHash(req.cookie);
        }

        const started = if (req.remove != 0)
            CookieApplyJob.startDelete(self.gpa, mgr, req, conn, idh)
        else
            CookieApplyJob.startSet(self.gpa, mgr, req, conn, idh);
        if (started == null) {
            self.settleApply(idh, req.context, req.cookie, false);
            self.postApplyDone(conn, req.req, req.context, false, "engine-refused");
        }
    }

    /// Land an apply's outcome on the shadow and clear the pending
    /// mark. Called from the engine's completion callback, and from the
    /// refusal path above so a failed apply never leaves an identity
    /// permanently skipped by the reconcile.
    fn settleApply(self: *Host, idh: u64, context: u32, ck: proto.SyncCookie, ok: bool) void {
        const entry = self.shadowFind(idh, context, ck.domain, ck.path, ck.name) orelse return;
        if (!entry.pending) return;
        entry.pending = false;
        if (!ok) {
            // The jar is whatever it was; let the next reconcile decide.
            if (entry.hash == 0) {
                entry.free(self.gpa);
                self.shadowRemove(entry);
            }
            return;
        }
        if (entry.pending_remove) {
            entry.free(self.gpa);
            self.shadowRemove(entry);
            return;
        }
        entry.hash = entry.pending_hash;
        entry.adopt = true;
        entry.seen = true;
    }

    fn postApplyDone(self: *Host, conn: u32, req: u32, context: u32, ok: bool, reason: []const u8) void {
        self.postSyncTo(conn, proto.EvCookieApplyDone{
            .req = req,
            .context = context,
            .ok = if (ok) 1 else 0,
            .reason = reason,
        });
    }

    /// Seed a fresh instance: one PAGE of a context's whole jar.
    pub fn cookieDump(self: *Host, req: proto.CookieDumpReq) void {
        const conn = self.dispatch_conn;
        const mgr = self.cookieManagerForContext(req.context) orelse
            return self.postDumpFail(conn, req);
        defer release(&mgr.base);
        if (SyncVisitJob.start(self.gpa, mgr, .{
            .mode = .dump,
            .context = req.context,
            .conn = conn,
            .req = req.req,
            .cursor = req.cursor,
        }) == null) self.postDumpFail(conn, req);
    }

    fn postDumpFail(self: *Host, conn: u32, req: proto.CookieDumpReq) void {
        self.postSyncTo(conn, proto.EvCookieDump{
            .req = req.req,
            .context = req.context,
            .ok = 0,
            .cursor = req.cursor,
            .next_cursor = req.cursor,
            .more = 0,
            .total = 0,
            .cookies = &.{},
        });
    }

    /// Wipe the document's own storage. Fire-and-forget on purpose:
    /// every API involved is either synchronous or a promise nobody can
    /// await from the browser process, and a failure to clear one of
    /// them must not stop the others.
    /// Flush a resting scroll position the throttle above held back. Called
    /// from the same watchdog turn that services the other per-view timers.
    pub fn flushScroll(self: *Host) void {
        const now = nowMs();
        for (self.views.items) |v| {
            if (v.scroll_x == v.scroll_sent_x and v.scroll_y == v.scroll_sent_y) continue;
            if (now - v.scroll_posted_ms < SCROLL_POST_MS) continue;
            v.scroll_posted_ms = now;
            v.scroll_sent_x = v.scroll_x;
            v.scroll_sent_y = v.scroll_y;
            self.post(proto.EvScroll{ .view = v.id, .x = v.scroll_x, .y = v.scroll_y });
        }
    }

    /// Put a page back where it was. `window.scrollTo` rather than a CEF
    /// call because the capi has no scroll setter at all; the numbers are
    /// the engine's own from `EvScroll`, so no unit conversion happens on
    /// either leg.
    pub fn scrollTo(self: *Host, req: proto.ScrollTo) void {
        const v = self.find(req.view) orelse return;
        const b = v.browser orelse return;
        const get_frame = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = get_frame(b) orelse return;
        defer release(&frame.base);
        var buf: [128]u8 = undefined;
        const js = std.fmt.bufPrint(&buf, "window.scrollTo({d},{d});", .{ req.x, req.y }) catch return;
        runJs(frame, js);
    }

    fn clearPageStorage(_: *Host, v: *View) void {
        const b = v.browser orelse return;
        const get_frame = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = get_frame(b) orelse return;
        defer release(&frame.base);
        runJs(frame, clear_storage_js);
    }

    /// Tear down a view's browser and everything that belonged to its
    /// document, leaving the record itself untouched. Shared by
    /// `freeViewOpts` (which then frees the record) and `discardView`
    /// (which keeps it). `close` is false only when the engine already
    /// closed the browser itself (`popupClosedByEngine`), where asking
    /// it to close again would re-enter a teardown in progress.
    fn dropBrowser(self: *Host, v: *View, close: bool) void {
        // The toplevel mirrors THIS browser's frame buffer, which goes
        // away below; a revived view paints again and gets a new one.
        if (self.presenter) |p| p.dropView(v.id);
        // Held requests belong to a browser that is going away:
        // answering them now is what stops the engine waiting on a
        // decision the client can no longer make. Cancel, never
        // proceed.
        resolveCert(v, false);
        for (&v.perms) |*p| resolvePerm(p, false);
        self.dropDownloadsOf(v.id);
        if (close) {
            if (browserHost(v)) |host| {
                // force_close: a windowless browser has no user to
                // prompt and no unload dialog anybody could answer.
                if (host.close_browser) |cb| cb(host, 1);
                release(&host.base);
            }
        }
        if (v.browser) |b| release(&b.base);
        v.browser = null;
        // `close_browser` is ASYNCHRONOUS: CEF may still run callbacks
        // for this browser after it returns. Clearing the id is what
        // stops `viewOf` resolving them onto a view whose buffer is
        // gone (browser ids start at 1, so 0 matches nothing).
        v.cef_id = 0;
        if (v.map.len != 0) {
            _ = c.munmap(v.map.ptr, v.map.len);
            v.map = &.{};
        }
        v.buf_unpainted = false;
        v.forgetPool();
        for (v.pending.items) |p| self.failPending(v, p, "semantic request canceled because the browser closed");
        v.pending.clearRetainingCapacity();
        // The shadow tree described a document that no longer exists;
        // its ids must not be answerable after this.
        v.sem.invalidateDocument();
        v.sem_observing = false;
        v.sem_want_observer = false;
        v.sem_nav.rearmed();
        v.sem_context_doc = 0;
        // The AX tree token named a document of the dead browser; a
        // revived one mints fresh ids and rebinds via `axResolveView`.
        if (v.ax_tree.len != 0) {
            self.gpa.free(v.ax_tree);
            v.ax_tree = &.{};
        }
        // Same reasoning for the caret: its node ids died with the
        // document, so the next one must be sent even if it looks
        // identical to the last.
        v.ax_caret_sent = false;
    }

    fn freeView(self: *Host, v: *View) void {
        self.freeViewOpts(v, true);
    }

    /// `close`: whether the browser goes down with the view — false
    /// only when the engine closed it already (see `dropBrowser`).
    fn freeViewOpts(self: *Host, v: *View, close: bool) void {
        // Frees the browser, the mapping, every pending request's arg
        // and the shadow tree; what is left is the record's own memory.
        interceptUnregister(self.gpa, v.id);
        self.dropBrowser(v, close);
        if (v.url.len != 0) self.gpa.free(v.url);
        v.pending.deinit(self.gpa);
        v.forgetFrames(self.gpa);
        v.sem.deinit();
        self.gpa.destroy(v);
    }

    /// (Re)allocate the view's shared frame buffer and announce it.
    ///
    /// The memfd is handed to the client through the outbox and closed
    /// by the sender; the write mapping made here survives that close.
    /// The buffer is PHYSICAL: stride is exactly pw*4 — no padding, per
    /// the spec — and the announced w/h are pw/ph.
    fn allocBuffer(self: *Host, v: *View) !void {
        return self.allocBufferWith(v, &system_browser_spawn_ops);
    }

    fn allocBufferWith(self: *Host, v: *View, ops: *const BrowserSpawnOps) !void {
        if (v.map.len != 0) {
            _ = c.munmap(v.map.ptr, v.map.len);
            v.map = &.{};
        }
        const size: usize = v.stride() * @as(usize, v.ph);
        if (self.viewInline(v)) {
            // Inline mode: the buffer is helper-private (the client gets
            // pixels in-band), so an anonymous mapping replaces the
            // memfd and nothing is announced — the first frame_inline
            // carries the new geometry instead.
            v.map = ops.map(ops.ctx, size, false, -1) orelse return error.MmapFailed;
            v.buf_unpainted = true;
            v.buf_id +%= 1;
            if (v.buf_id == 0) v.buf_id = 1;
            v.inline_dirty = null;
            if (!v.hidden) withHost(v, struct {
                fn f(host: *cef.cef_browser_host_t) void {
                    if (host.invalidate) |inv| inv(host, cef.PET_VIEW);
                }
            }.f);
            return;
        }
        const fd = ops.create_memfd(ops.ctx) orelse return error.MemfdFailed;
        var keep_fd = false;
        defer if (!keep_fd) {
            _ = c.close(fd);
        };
        if (!ops.truncate(ops.ctx, fd, size)) return error.FtruncateFailed;
        v.map = ops.map(ops.ctx, size, true, fd) orelse return error.MmapFailed;
        @memset(v.map, 0);
        v.buf_unpainted = true;
        v.buf_id +%= 1;
        if (v.buf_id == 0) v.buf_id = 1;
        try ops.announce(ops.ctx, self, v, fd);
        keep_fd = true;
        // Ask for a repaint INTO the buffer just installed (the fields
        // above already point at it, so this cannot land in the old
        // one). A view whose very first paint raced the buffer into
        // existence has no other way to get one: nothing else damages a
        // static page. A hidden view is not painted at all — `showView`
        // invalidates when it comes back, and `buf_unpainted` makes
        // that first paint a whole-buffer copy.
        if (!v.hidden) withHost(v, struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.invalidate) |inv| inv(host, cef.PET_VIEW);
            }
        }.f);
    }

    /// A resize OR a scale change (the window moved to a differently
    /// scaled output). A scale change must reach the engine through
    /// `notify_screen_info_changed` BEFORE `was_resized`, or the page
    /// re-lays out at the old DPR and the next paint arrives at the old
    /// physical size — which the paint guard then drops.
    pub fn resizeView(self: *Host, req: proto.ViewResize) !void {
        const v = self.find(req.view) orelse return;
        const w = @max(req.w, 1);
        const h = @max(req.h, 1);
        const scale: u16 = if (req.scale_x1000 == 0) 1000 else req.scale_x1000;
        const scale_changed = scale != v.scale_x1000;
        if (v.w == w and v.h == h and !scale_changed) return;
        v.w = w;
        v.h = h;
        v.scale_x1000 = scale;
        // A discarded view records the new geometry and stops there: a
        // background pane the window resized must NOT cost a revived
        // browser, and the revival lays out at these numbers anyway.
        if (v.discarded) {
            v.pw = physicalOf(w, scale);
            v.ph = physicalOf(h, scale);
            return;
        }
        const pw = physicalOf(w, scale);
        const ph = physicalOf(h, scale);
        const buffer_changed = pw != v.pw or ph != v.ph;
        v.pw = pw;
        v.ph = ph;
        if (buffer_changed) {
            // The old dma-buf pool is retired with the old geometry; its
            // ids must not be reused for differently sized buffers.
            v.forgetPool();
            try self.allocBuffer(v);
        }
        if (scale_changed) applyZoom(v);
        if (scale_changed) withHost(v, struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.notify_screen_info_changed) |ns| ns(host);
            }
        }.f);
        withHost(v, struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.was_resized) |wr| wr(host);
            }
        }.f);
        // Nothing repaints without a begin frame, and a resize that
        // waits for the client's next one shows a stale/black buffer in
        // the meantime.
        if (!v.hidden) issueBeginFrame(v);
    }

    /// `view_show` / `view_hide`. A SHOW revives a discarded view — it
    /// is the frame that means the pane is on screen again, and the
    /// revived browser is created visible, so the calls below then only
    /// re-state what is already true.
    pub fn showView(self: *Host, id: u32, show: bool) void {
        const v = if (show) self.findWake(id) orelse return else self.find(id) orelse return;
        if (v.discarded) return;
        v.hidden = !show;
        // A view coming back needs the invalidate below to land on a
        // frame; a view going away is simply never asked again.
        defer if (show) issueBeginFrame(v);
        withHost(v, if (show) struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.was_hidden) |wh| wh(host, 0);
                if (host.invalidate) |inv| inv(host, cef.PET_VIEW);
            }
        }.f else struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.was_hidden) |wh| wh(host, 1);
            }
        }.f);
    }

    // -- frame pacing --------------------------------------------------

    /// One client-requested frame. A hidden view is not painted at all:
    /// nobody can see it, and the whole point of external begin frames
    /// is that nothing is rendered unless somebody asks.
    pub fn beginFrame(self: *Host, req: proto.FrameRequest) void {
        const v = self.find(req.view) orelse return;
        if (v.hidden) return;
        issueBeginFrame(v);
    }

    fn issueBeginFrame(v: *View) void {
        // The timestamp is recorded either way: it is what keeps the
        // watchdog quiet for a client that IS asking.
        v.last_begin_ms = nowMs();
        // Without external begin frames CEF drives its own scheduler and
        // `send_external_begin_frame` is out of contract — the request
        // has already done its real job (promoting the view out of
        // hidden state, above).
        if (!v.external_pacing) return;
        latStamp("bf");
        withHost(v, struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.send_external_begin_frame) |bf| bf(host);
            }
        }.f);
    }

    /// Keep every visible view alive when the client stops asking (see
    /// `watchdog_ms`). Called once per poll iteration; a client pacing
    /// at anything above 4Hz never reaches the deadline.
    pub fn watchdog(self: *Host, now_ms: i64) void {
        filterSubPump(self, now_ms);
        filterSubTick(self, now_ms);
        // A scroll that STOPPED left its resting position behind the
        // throttle; this is where it gets out.
        self.flushScroll();
        // An inspector the engine never created. Answering is not
        // optional: a client blocks a menu item on this reply.
        if (self.adopting) |v| {
            if (now_ms - self.adopting_ms > adopt_timeout_ms) {
                const src_id = v.devtools_of;
                self.adopting = null;
                self.destroyView(v.id);
                self.post(proto.EvDevToolsView{ .view = src_id, .devtools = 0, .reason = "timeout" });
            }
        }
        for (self.views.items) |v| {
            if (v.hidden or v.windowed) continue;
            if (now_ms - v.last_begin_ms < watchdog_ms) continue;
            issueBeginFrame(v);
        }
    }

    /// `view_max_fps`: the client's cap (its `browser_max_fps` clamped
    /// to the display's real refresh; 0 = uncapped). On the default
    /// internal scheduler this IS the pacing lever —
    /// `set_windowless_frame_rate` takes effect immediately.
    pub fn setMaxFps(self: *Host, req: proto.ViewMaxFps) void {
        const v = self.find(req.view) orelse return;
        if (v.max_fps == req.fps) return;
        v.max_fps = req.fps;
        const rate = effectiveWindowlessFps(v.max_fps);
        withHostArgs(v, struct {
            fn f(host: *cef.cef_browser_host_t, r: c_int) void {
                if (host.set_windowless_frame_rate) |sw| sw(host, r);
            }
        }.f, .{rate});
    }

    // -- request interception ------------------------------------------

    /// Enable/disable blocking, globally (`view` 0) or per view. The
    /// filter lists stay loaded; only the verdict is gated.
    pub fn interceptSet(self: *Host, req: proto.InterceptSet) void {
        if (req.view == 0) {
            g_int.acquire();
            defer g_int.release();
            g_int.global_enabled = req.enabled != 0;
            for (&g_int.slots) |*s| {
                if (s.used) s.dirty = true;
            }
            return;
        }
        // Find-or-create: a per-view toggle sent BEFORE the
        // `view_create` naming the view (the ordering every policied
        // open relies on) used to be dropped silently here.
        const s = interceptSlotFor(self.gpa, req.view) orelse return;
        g_int.acquire();
        defer g_int.release();
        s.enabled = req.enabled != 0;
        s.dirty = true;
    }

    /// Reload the filter set from the seed list, the config filters
    /// dir, and any extra paths named. The paths are REMEMBERED (this
    /// frame is replace-all) so a later subscription reconcile's
    /// reload cannot silently drop them. No network fetching.
    pub fn interceptLists(self: *Host, req: proto.InterceptLists) void {
        var next: std.ArrayList([]const u8) = .empty;
        var adopted = false;
        defer if (!adopted) {
            for (next.items) |p| self.gpa.free(p);
            next.deinit(self.gpa);
        };
        for (req.paths) |p| {
            const dup = self.gpa.dupe(u8, p) catch return;
            next.append(self.gpa, dup) catch {
                self.gpa.free(dup);
                return;
            };
        }
        for (self.intercept_extra.items) |p| self.gpa.free(p);
        self.intercept_extra.deinit(self.gpa);
        self.intercept_extra = next;
        adopted = true;
        _ = interceptReload(self.gpa, self.intercept_extra.items);
    }

    /// The client's filter-list subscriptions (REPLACE-ALL).
    ///
    /// Reconciles the cache directory against exactly this set: stale
    /// or missing lists are fetched, and the cache files of
    /// subscriptions that went away are removed. Fetching is the one
    /// thing only this process can do — the daemon links libc and has
    /// no TLS — and it happens nowhere unless the user configured a
    /// url, so the default remains "filtering never touches the
    /// network".
    pub fn interceptSubscribe(self: *Host, req: proto.InterceptSubscribe) void {
        filterSubApply(self, req.update_hours, req.urls);
    }

    pub fn interceptStatus(self: *Host, req: proto.InterceptStatusReq) void {
        self.post(self.statusFrame(req.view));
    }

    fn statusFrame(self: *Host, view_id: u32) proto.InterceptStatus {
        _ = self;
        g_int.acquire();
        defer g_int.release();
        var out = proto.InterceptStatus{
            .view = view_id,
            .enabled = if (g_int.global_enabled) 1 else 0,
            .rules = g_int.rules,
            .blocked = 0,
            .total = 0,
        };
        for (&g_int.slots) |*s| {
            if (s.used and s.view_id == view_id) {
                out.enabled = if (g_int.global_enabled and s.enabled) 1 else 0;
                out.blocked = s.blocked;
                out.total = s.total;
                break;
            }
        }
        return out;
    }

    /// Answer a log pull: entries with seq > `req.since`, oldest first,
    /// up to `req.max` (bounded). The ring is snapshotted under the
    /// lock into a small stack buffer, then encoded outside it.
    pub fn interceptLog(self: *Host, req: proto.InterceptLogReq) void {
        var snap: [NLOG]proto.NetEntry = undefined;
        var url_store: [NLOG][LOG_URL_MAX]u8 = undefined;
        var method_store: [NLOG][8]u8 = undefined;
        var n: usize = 0;
        var next_seq: u32 = req.since;
        const cap: usize = @min(@as(usize, if (req.max == 0) NLOG else req.max), NLOG);
        {
            g_int.acquire();
            defer g_int.release();
            for (&g_int.slots) |*s| {
                if (!s.used or s.view_id != req.view) continue;
                next_seq = s.next_seq;
                const ring = s.ring orelse break;
                // Emit in seq order: the ring is a circular buffer, so
                // walk it and collect, then a caller-side sort would be
                // overkill — seqs increase with widx, so oldest is at
                // widx. Simplest correct pass: scan all, filter, insert
                // sorted (NLOG is tiny).
                for (ring) |*e| {
                    if (e.seq == 0 or e.seq <= req.since) continue;
                    if (n >= cap) {
                        // Keep the NEWEST `cap`: replace the oldest held
                        // if this one is newer.
                        var oldest: usize = 0;
                        for (snap[0..n], 0..) |se, i| {
                            if (se.seq < snap[oldest].seq) oldest = i;
                        }
                        if (e.seq <= snap[oldest].seq) continue;
                        fillEntry(&snap[oldest], &url_store[oldest], &method_store[oldest], e);
                        continue;
                    }
                    fillEntry(&snap[n], &url_store[n], &method_store[n], e);
                    n += 1;
                }
                break;
            }
        }
        // Sort ascending by seq (insertion sort; n <= NLOG).
        var i: usize = 1;
        while (i < n) : (i += 1) {
            var j = i;
            while (j > 0 and snap[j - 1].seq > snap[j].seq) : (j -= 1) {
                const tmp = snap[j];
                snap[j] = snap[j - 1];
                snap[j - 1] = tmp;
            }
        }
        self.post(proto.InterceptLog{ .view = req.view, .next_seq = next_seq, .entries = snap[0..n] });
    }

    // -- enforced network policy (0x86 block) --------------------------

    /// Install (or replace) a view's enforced policy. MAIN thread; the
    /// slot is found-or-created so the frame can precede the
    /// `view_create` naming the view. When no slot is free (the
    /// MAX_POLICY_VIEWS ceiling) an `active=0` event is posted — the
    /// client refuses the open on its own count, this is the belt.
    pub fn netPolicySet(self: *Host, req: proto.NetPolicySet) void {
        const pol = netpolicy.Policy.build(self.gpa, req) catch return;
        const s = interceptSlotFor(self.gpa, req.view) orelse {
            pol.deinit(self.gpa);
            self.post(proto.EvNetPolicy{
                .view = req.view,
                .serial = req.serial,
                .active = 0,
                .exhausted = 0,
                .requests = 0,
                .bytes = 0,
                .navigations = 0,
                .ms_left = 0,
                .denied = @splat(0),
            });
            return;
        };
        var old: ?*netpolicy.Policy = null;
        {
            g_int.acquire();
            defer g_int.release();
            old = s.pol;
            s.pol = pol;
            s.pc = .{ .started_ms = nowMs() };
            s.pol_dirty = true;
            s.deadline_stopped = false;
        }
        if (old) |o| o.deinit(self.gpa);
    }

    pub fn netPolicyStatus(self: *Host, req: proto.NetPolicyReq) void {
        self.post(netPolicyFrame(req.view));
    }

    /// Answer a reason-carrying log pull; the `intercept_log` shape
    /// with the policy verdict per entry.
    pub fn netLog(self: *Host, req: proto.NetLogReq) void {
        var snap: [NLOG]proto.NetEntry2 = undefined;
        var url_store: [NLOG][LOG_URL_MAX]u8 = undefined;
        var method_store: [NLOG][8]u8 = undefined;
        var n: usize = 0;
        var next_seq: u32 = req.since;
        const cap: usize = @min(@as(usize, if (req.max == 0) NLOG else req.max), NLOG);
        {
            g_int.acquire();
            defer g_int.release();
            for (&g_int.slots) |*s| {
                if (!s.used or s.view_id != req.view) continue;
                next_seq = s.next_seq;
                const ring = s.ring orelse break;
                for (ring) |*e| {
                    if (e.seq == 0 or e.seq <= req.since) continue;
                    if (n >= cap) {
                        var oldest: usize = 0;
                        for (snap[0..n], 0..) |se, i| {
                            if (se.entry.seq < snap[oldest].entry.seq) oldest = i;
                        }
                        if (e.seq <= snap[oldest].entry.seq) continue;
                        fillEntry(&snap[oldest].entry, &url_store[oldest], &method_store[oldest], e);
                        snap[oldest].reason = e.reason;
                        continue;
                    }
                    fillEntry(&snap[n].entry, &url_store[n], &method_store[n], e);
                    snap[n].reason = e.reason;
                    n += 1;
                }
                break;
            }
        }
        var i: usize = 1;
        while (i < n) : (i += 1) {
            var j = i;
            while (j > 0 and snap[j - 1].entry.seq > snap[j].entry.seq) : (j -= 1) {
                const tmp = snap[j];
                snap[j] = snap[j - 1];
                snap[j - 1] = tmp;
            }
        }
        self.post(proto.NetLog{ .view = req.view, .next_seq = next_seq, .entries = snap[0..n] });
    }

    fn netPolicyFrame(view_id: u32) proto.EvNetPolicy {
        g_int.acquire();
        defer g_int.release();
        var out = proto.EvNetPolicy{
            .view = view_id,
            .serial = 0,
            .active = 0,
            .exhausted = 0,
            .requests = 0,
            .bytes = 0,
            .navigations = 0,
            .ms_left = 0,
            .denied = @splat(0),
        };
        for (&g_int.slots) |*s| {
            if (!s.used or s.view_id != view_id) continue;
            const pol = s.pol orelse break;
            out.serial = pol.serial;
            out.active = 1;
            out.exhausted = @intFromEnum(s.pc.exhausted);
            out.requests = s.pc.requests;
            out.bytes = s.pc.bytes;
            out.navigations = s.pc.navigations;
            out.ms_left = if (pol.deadline_ms == 0)
                0
            else
                @intCast(std.math.clamp(@as(i64, pol.deadline_ms) - (nowMs() - s.pc.started_ms), 0, std.math.maxInt(u32)));
            out.denied = s.pc.denied;
            break;
        }
        return out;
    }

    /// The deadline sweep + coalesced accounting push. Called once per
    /// poll iteration next to `flushInterceptStatus`. A view whose
    /// deadline ran out gets ONE `stop_load` (an in-flight streaming
    /// body is invisible to the pre-request gate).
    pub fn flushNetPolicy(self: *Host) void {
        var pending: [MAX_ISLOTS]proto.EvNetPolicy = undefined;
        var stops: [MAX_ISLOTS]u32 = undefined;
        var n: usize = 0;
        var nstops: usize = 0;
        const now = nowMs();
        {
            g_int.acquire();
            defer g_int.release();
            for (&g_int.slots) |*s| {
                if (!s.used) continue;
                const pol = s.pol orelse continue;
                if (pol.deadline_ms != 0 and now - s.pc.started_ms >= pol.deadline_ms and !s.deadline_stopped) {
                    if (s.pc.exhausted == .none) s.pc.exhausted = .deadline;
                    s.deadline_stopped = true;
                    s.pol_dirty = true;
                    stops[nstops] = s.view_id;
                    nstops += 1;
                }
                if (!s.pol_dirty) continue;
                s.pol_dirty = false;
                pending[n] = .{
                    .view = s.view_id,
                    .serial = pol.serial,
                    .active = 1,
                    .exhausted = @intFromEnum(s.pc.exhausted),
                    .requests = s.pc.requests,
                    .bytes = s.pc.bytes,
                    .navigations = s.pc.navigations,
                    .ms_left = if (pol.deadline_ms == 0)
                        0
                    else
                        @intCast(std.math.clamp(@as(i64, pol.deadline_ms) - (now - s.pc.started_ms), 0, std.math.maxInt(u32))),
                    .denied = s.pc.denied,
                };
                n += 1;
            }
        }
        for (stops[0..nstops]) |view_id| {
            const v = self.find(view_id) orelse continue;
            const b = v.browser orelse continue;
            if (b.stop_load) |f| f(b);
        }
        for (pending[0..n]) |ev| self.post(ev);
    }

    /// Push a coalesced `intercept_status` for every view whose
    /// counters moved since the last flush. Called once per poll
    /// iteration — a page issuing thousands of requests still costs at
    /// most one status frame per iteration per view.
    pub fn flushInterceptStatus(self: *Host) void {
        var pending: [MAX_ISLOTS]proto.InterceptStatus = undefined;
        var n: usize = 0;
        {
            g_int.acquire();
            defer g_int.release();
            for (&g_int.slots) |*s| {
                if (!s.used or !s.dirty) continue;
                s.dirty = false;
                pending[n] = .{
                    .view = s.view_id,
                    .enabled = if (g_int.global_enabled and s.enabled) 1 else 0,
                    .rules = g_int.rules,
                    .blocked = s.blocked,
                    .total = s.total,
                };
                n += 1;
            }
        }
        for (pending[0..n]) |st| self.post(st);
    }

    // -- user content (userscripts / userstyles) -----------------------

    /// Replace the enabled userscript set. Sources whose
    /// `==UserScript==` block is missing or unterminated are refused
    /// (not a userscript); the rest take effect at the NEXT navigation
    /// of any matching page.
    pub fn usScriptSet(self: *Host, req: proto.UsScriptSet) void {
        if (self.us_script_arena) |*a| a.deinit();
        self.us_script_arena = std.heap.ArenaAllocator.init(self.gpa);
        const arena = self.us_script_arena.?.allocator();
        self.us_scripts.clearRetainingCapacity();
        for (req.scripts) |s| {
            const src = arena.dupe(u8, s.source.s) catch continue;
            const meta = (userscript.parseMeta(arena, src) catch continue) orelse continue;
            self.us_scripts.append(self.gpa, .{ .id = s.id, .meta = meta, .source = src }) catch {};
        }
    }

    /// Replace the enabled userstyle set and apply it INSTANTLY to
    /// every live view (including removing styles that are no longer
    /// in the set); navigations re-inject from the stored set.
    pub fn usStyleSet(self: *Host, req: proto.UsStyleSet) void {
        if (self.us_style_arena) |*a| a.deinit();
        self.us_style_arena = std.heap.ArenaAllocator.init(self.gpa);
        const arena = self.us_style_arena.?.allocator();
        self.us_styles.clearRetainingCapacity();
        for (req.styles) |s| {
            const host = arena.alloc(u8, s.host.len) catch continue;
            for (s.host, host) |ch, *o| o.* = std.ascii.toLower(ch);
            const css = arena.dupe(u8, s.css.s) catch continue;
            self.us_styles.append(self.gpa, .{ .id = s.id, .host = host, .css = css }) catch {};
        }
        for (self.views.items) |v| self.applyStylesNow(v);
    }

    fn styleMatches(st: *const StyleRec, host: []const u8) bool {
        if (st.host.len == 0) return true;
        return filter.hostWithin(host, st.host);
    }

    /// Swap a live document's userstyle elements for the current set.
    /// Runs even when NOTHING matches: that is how a deleted style
    /// disappears from the page it is on.
    fn applyStylesNow(self: *Host, v: *View) void {
        if (v.discarded) return;
        const b = v.browser orelse return;
        const gf = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = gf(b) orelse return;
        defer release(&frame.base);
        var fold_buf: [2048]u8 = undefined;
        const folded = filter.foldUrl(&fold_buf, v.url);
        const host = filter.hostOf(folded);

        var code: std.Io.Writer.Allocating = .init(self.gpa);
        defer code.deinit();
        const w = &code.writer;
        w.writeAll("(function(){var d=document;var o=d.querySelectorAll('style[data-sketerm-us]');" ++
            "for(var i=0;i<o.length;i++)o[i].remove();" ++
            "function A(t){var s=d.createElement('style');s.setAttribute('data-sketerm-us','');" ++
            "s.textContent=t;(d.head||d.documentElement).appendChild(s);}") catch return;
        for (self.us_styles.items) |*st| {
            if (!styleMatches(st, host)) continue;
            w.writeAll("A(") catch return;
            jsonStr(w, st.css) catch return;
            w.writeAll(");") catch return;
        }
        w.writeAll("})();") catch return;
        runJs(frame, code.written());
    }

    /// Inject the user content applicable to a newly-committed
    /// document: cosmetic hiding (shield-gated — a disabled shield
    /// injects NO cosmetic CSS), userstyles, and userscripts by
    /// `@run-at`. MAIN FRAME ONLY.
    ///
    /// LIMITATIONS (deliberate, verified by smoke-web): injection is
    /// browser-side `execute_java_script` at load START, which lands
    /// after the parser has begun — cosmetic hiding can flash briefly,
    /// and `document-start` here means "at commit", not "before every
    /// page script" (only the embedded semantic bridge gets that,
    /// renderer-side). Scripts run wrapped in a closure in the page's
    /// MAIN world — the C API exposes no isolated world on this path —
    /// with a no-op `GM_info` and NO other GM_* API (`@grant` values
    /// beyond `none` are recorded by the parser and provided nothing).
    fn injectUserContent(self: *Host, v: *View, frame: *cef.cef_frame_t) void {
        var url_raw: [2048]u8 = undefined;
        const gu = frame.get_url orelse return;
        const url = userfreeInto(gu(frame), &url_raw);
        var fold_buf: [2048]u8 = undefined;
        const folded = filter.foldUrl(&fold_buf, url);
        const host = filter.hostOf(folded);

        var code: std.Io.Writer.Allocating = .init(self.gpa);
        defer code.deinit();
        const w = &code.writer;
        var any = false;
        w.writeAll("(function(){var d=document;" ++
            "function A(t,m){var s=d.createElement('style');s.setAttribute(m,'');" ++
            "s.textContent=t;(d.head||d.documentElement).appendChild(s);}") catch return;

        if (cosmeticEnabledFor(v.id)) {
            if (cosmeticCss(self.gpa, host)) |css| {
                defer self.gpa.free(css);
                any = true;
                w.writeAll("A(") catch return;
                jsonStr(w, css) catch return;
                w.writeAll(",'data-sketerm-cos');") catch return;
            }
        }
        for (self.us_styles.items) |*st| {
            if (!styleMatches(st, host)) continue;
            any = true;
            w.writeAll("A(") catch return;
            jsonStr(w, st.css) catch return;
            w.writeAll(",'data-sketerm-us');") catch return;
        }

        var scripts = false;
        for (self.us_scripts.items) |*sc| {
            if (!userscript.applies(&sc.meta, url)) continue;
            if (!scripts) {
                scripts = true;
                any = true;
                w.writeAll("var S=[],E=[],I=[];") catch return;
            }
            const arr: []const u8 = switch (sc.meta.run_at) {
                .document_start => "S",
                .document_end => "E",
                .document_idle => "I",
            };
            w.writeAll(arr) catch return;
            w.writeAll(".push([") catch return;
            jsonStr(w, sc.meta.name) catch return;
            w.writeAll(",") catch return;
            jsonStr(w, sc.source) catch return;
            w.writeAll("]);") catch return;
        }
        if (scripts) {
            w.writeAll("function R(p){for(var i=0;i<p.length;i++){" ++
                "try{(new Function('GM_info',p[i][1]))" ++
                "({script:{name:p[i][0]},scriptHandler:'sketerm'});}" ++
                "catch(e){console.error('[sketerm userscript]',p[i][0],e);}}}" ++
                "R(S);" ++
                "if(d.readyState==='loading')d.addEventListener('DOMContentLoaded',function(){R(E);});else R(E);" ++
                "if(d.readyState==='complete')R(I);else window.addEventListener('load',function(){R(I);});") catch return;
        }
        if (!any) return;
        w.writeAll("})();") catch return;
        runJs(frame, code.written());
    }

    // -- downloads -----------------------------------------------------

    fn findDl(self: *Host, view: u32, id: u32) ?*Dl {
        for (self.downloads.items) |*d| {
            if (d.id == id and d.view == view) return d;
        }
        return null;
    }

    /// The client answered an `ev_download_offer`. An id the helper no
    /// longer holds is ignored (the download may already have failed or
    /// its view may be gone).
    pub fn downloadDecide(self: *Host, req: proto.DownloadDecide) void {
        const d = self.findDl(req.view, req.id) orelse return;
        if (req.path.len == 0) {
            self.cancelDl(d);
            return;
        }
        if (d.decided) return;
        d.decided = true;
        d.dirty = true;
        if (d.before_cb) |cb| {
            d.before_cb = null;
            var path = std.mem.zeroes(cef.cef_string_t);
            setStr(req.path, &path);
            defer cef.cef_string_utf16_clear(&path);
            if (cb.cont) |f| f(cb, &path, 0);
            release(&cb.base);
        }
    }

    /// `download_cancel`, and the decide-with-empty-path shape of the
    /// same intent. Idempotent; a download with no cancel handle yet is
    /// aborted by the next `on_download_updated`.
    fn cancelDl(self: *Host, d: *Dl) void {
        _ = self;
        if (d.terminal()) return;
        d.cancel_requested = true;
        // A held target decision must ALWAYS be run — dropping the
        // callback unanswered leaves Chromium's target determiner
        // waiting forever and the whole helper then hangs at shutdown
        // on its download manager (measured; stage 23 caught it). So a
        // cancel CONTINUES into a throwaway path first and cancels
        // right after; if the engine wins the race and completes
        // anyway, the throwaway is unlinked when the entry drops.
        if (d.before_cb) |cb| {
            d.before_cb = null;
            const p = std.fmt.bufPrint(
                d.trash[0 .. d.trash.len - 1],
                "/tmp/sketerm-webdl-cancel-{d}-{d}.part",
                .{ c.getpid(), d.id },
            ) catch "";
            d.trash_len = p.len;
            var path = std.mem.zeroes(cef.cef_string_t);
            setStr(p, &path);
            defer cef.cef_string_utf16_clear(&path);
            if (cb.cont) |f| f(cb, &path, 0);
            release(&cb.base);
        }
        if (d.item_cb) |cb| {
            d.item_cb = null;
            if (cb.cancel) |f| f(cb);
            release(&cb.base);
        }
    }

    pub fn downloadCancel(self: *Host, req: proto.DownloadCancel) void {
        const d = self.findDl(req.view, req.id) orelse return;
        self.cancelDl(d);
    }

    /// Largest RAW band one `frame_inline` rect may describe. Bands keep
    /// every message far under proto.MAX_FRAME (a 4K full frame is 33MB
    /// raw) and bound the compressor's working set; a paint larger than
    /// this simply arrives as several self-contained messages.
    const inline_band_raw_max: usize = 2 << 20;

    /// Client turned inline mode on (or spawn forced it). Never turned
    /// back off mid-connection: existing anonymous buffers were never
    /// announced, so a client flipping back would wait for a
    /// `frame_buffer` nobody re-sends.
    pub fn setInlineMode(self: *Host, on: bool) void {
        if (!on or self.inline_mode) return;
        self.inline_mode = true;
    }

    /// Latch inline mode onto every view a connection owns — the
    /// per-connection `frame_mode`, where `setInlineMode` is the
    /// process-wide spawn force. Buffers allocated afterwards are
    /// anonymous; existing announced memfds keep painting until their
    /// next reallocation, same as the global latch always behaved.
    pub fn latchInlineForConn(self: *Host, conn_id: u32) void {
        for (self.views.items) |v| {
            if (v.owner == conn_id) v.inline_view = true;
        }
    }

    fn viewInline(self: *const Host, v: *const View) bool {
        return self.inline_mode or v.inline_view;
    }

    /// Post accumulated inline damage for every view — the drain-side
    /// half of the union-and-flush backpressure. Called once per poll
    /// iteration, like `flushInterceptStatus`.
    pub fn flushInline(self: *Host) void {
        for (self.views.items) |v| {
            if (self.viewInline(v)) self.flushInlineView(v);
        }
    }

    /// Encode `v.inline_dirty` (if any) into banded `frame_inline`
    /// messages, unless the outbox is already backed up — then the
    /// damage stays accumulated and a later flush ships the union.
    fn flushInlineView(self: *Host, v: *View) void {
        const d = v.inline_dirty orelse return;
        if (v.map.len == 0) {
            v.inline_dirty = null;
            return;
        }
        const route = self.routeFor(v.id) orelse {
            v.inline_dirty = null;
            return;
        };
        if (route.out.pending() >= max_frame_backlog) return;
        const stride: usize = v.stride();
        // Clamp against the live buffer: a dirty rect can predate a
        // resize by one poll iteration.
        const x: u16 = @min(d.x, v.pw -| 1);
        const y0: u16 = @min(d.y, v.ph -| 1);
        const w: u16 = @min(d.w, v.pw - x);
        const total_h: u16 = @min(d.h, v.ph - y0);
        v.inline_dirty = null;
        if (w == 0 or total_h == 0) return;
        const row_bytes: usize = @as(usize, w) * 4;
        const band_rows_max: u16 = @intCast(@min(
            @as(usize, total_h),
            @max(@as(usize, 1), inline_band_raw_max / row_bytes),
        ));
        // Scratch for one band: gathered raw rows + the deflate output.
        const raw = self.gpa.alloc(u8, row_bytes * band_rows_max) catch return;
        defer self.gpa.free(raw);
        const zbuf = self.gpa.alloc(u8, row_bytes * band_rows_max) catch return;
        defer self.gpa.free(zbuf);
        var y: u16 = y0;
        const y_end: u32 = @as(u32, y0) + total_h;
        while (y < y_end) {
            const rows: u16 = @intCast(@min(@as(u32, band_rows_max), y_end - y));
            var r: usize = 0;
            while (r < rows) : (r += 1) {
                const src_off = (@as(usize, y) + r) * stride + @as(usize, x) * 4;
                @memcpy(raw[r * row_bytes ..][0..row_bytes], v.map[src_off..][0..row_bytes]);
            }
            const band_raw = raw[0 .. row_bytes * rows];
            var rect = proto.InlineRect{
                .x = x,
                .y = y,
                .w = w,
                .h = rows,
                .enc = proto.inline_enc_raw,
                .data = band_raw,
            };
            if (zpool.compress(band_raw, zbuf)) |z| {
                rect.enc = proto.inline_enc_deflate;
                rect.data = z;
            }
            self.post(proto.FrameInline{
                .view = v.id,
                .gen = v.gen,
                .w = v.pw,
                .h = v.ph,
                .rects = &.{rect},
            });
            y = @intCast(@min(y_end, @as(u32, y) + rows));
        }
    }

    /// Push a coalesced `ev_download_progress` for every download whose
    /// counters moved, and retire terminal entries. Called once per
    /// poll iteration, like `flushInterceptStatus`.
    pub fn flushDownloadProgress(self: *Host) void {
        var i: usize = 0;
        while (i < self.downloads.items.len) {
            const d = &self.downloads.items[i];
            if (d.dirty) {
                d.dirty = false;
                // Progress is only worth a frame once the client has a
                // row for it — but a TERMINAL state must reach an
                // offered download either way, or a client whose decide
                // raced the failure waits forever.
                if (d.offered and (d.decided or d.terminal())) self.post(proto.EvDownloadProgress{
                    .view = d.view,
                    .id = d.id,
                    .received = d.received,
                    .total = d.total,
                    .done = if (d.done) 1 else 0,
                    .failed = if (d.failed) 1 else 0,
                });
            }
            if (d.terminal()) {
                var gone = self.downloads.swapRemove(i);
                gone.releaseCbs();
                gone.dropTrash();
                continue;
            }
            i += 1;
        }
    }

    /// Cancel and drop every download of `view`, posting the terminal
    /// frame ourselves — the flush would otherwise never see entries
    /// removed here. Called from `dropBrowser`.
    fn dropDownloadsOf(self: *Host, view: u32) void {
        var i: usize = 0;
        while (i < self.downloads.items.len) {
            const d = &self.downloads.items[i];
            if (d.view != view) {
                i += 1;
                continue;
            }
            const was_terminal = d.terminal();
            const was_offered = d.offered;
            const was_decided = d.decided;
            self.cancelDl(d);
            var gone = self.downloads.swapRemove(i);
            gone.releaseCbs();
            gone.dropTrash();
            if (!was_terminal and was_offered and was_decided) self.post(proto.EvDownloadProgress{
                .view = view,
                .id = gone.id,
                .received = gone.received,
                .total = gone.total,
                .done = 0,
                .failed = 1,
            });
        }
    }

    pub fn navigate(self: *Host, req: proto.Navigate) void {
        const v = self.find(req.view) orelse return;
        // A discarded view is revived straight AT the requested address
        // rather than at the one it was discarded holding: reviving
        // first and navigating after would mint a document nobody asked
        // for, which is the two-document trap `view_create_url` exists
        // to avoid.
        self.semanticNavigationStarted(v);
        v.sem_nav.waiting_load_start = true;
        if (v.discarded) return self.reviveAt(v, req.url);
        const b = v.browser orelse return;
        const get_frame = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = get_frame(b) orelse return;
        defer release(&frame.base);
        var url = std.mem.zeroes(cef.cef_string_t);
        setStr(req.url, &url);
        defer cef.cef_string_utf16_clear(&url);
        if (frame.load_url) |lu| lu(frame, &url);
    }

    /// Back/forward/reload/stop. A discarded view is revived first, so
    /// a reload of one does exactly what the user expects; back and
    /// forward then find an empty history (see `View.discarded`).
    pub fn navAction(self: *Host, req: proto.NavAction) void {
        const v = self.findWake(req.view) orelse return;
        const b = v.browser orelse return;
        switch (@as(proto.NavAct, @enumFromInt(req.action))) {
            .back => if (browserInt(b, "can_go_back") != 0) {
                self.semanticNavigationStarted(v);
                v.sem_nav.waiting_load_start = true;
                if (b.go_back) |f| f(b);
            },
            .forward => if (browserInt(b, "can_go_forward") != 0) {
                self.semanticNavigationStarted(v);
                v.sem_nav.waiting_load_start = true;
                if (b.go_forward) |f| f(b);
            },
            .reload => {
                self.semanticNavigationStarted(v);
                v.sem_nav.waiting_load_start = true;
                if (b.reload) |f| f(b);
            },
            .stop => {
                v.sem_nav.requestStop();
                if (b.stop_load) |f| f(b);
                // A user stop can produce only ERR_ABORTED. If CEF did
                // not report it synchronously, clear the semantic load
                // state here rather than waiting forever for load-end.
                if (v.sem_nav.takeStopRequest()) {
                    self.semanticStopped(v);
                }
            },
            .reload_no_cache => {
                self.semanticNavigationStarted(v);
                v.sem_nav.waiting_load_start = true;
                if (b.reload_ignore_cache) |f| f(b);
            },
            _ => {},
        }
    }

    /// Find-in-page (capability "find"): straight onto the engine's own
    /// find API; results come back through `onFindResult`.
    pub fn findInPage(self: *Host, req: proto.Find) void {
        const v = self.find(req.view) orelse return;
        // No page, no matches — and a silent no-op would leave a client
        // waiting for a result frame that can never come.
        if (v.discarded) {
            self.post(proto.EvFindResult{ .view = v.id, .count = 0, .active = 0, .final = 1 });
            return;
        }
        var text = std.mem.zeroes(cef.cef_string_t);
        setStr(req.text, &text);
        defer cef.cef_string_utf16_clear(&text);
        withHostArgs(v, struct {
            fn f(host: *cef.cef_browser_host_t, t: *const cef.cef_string_t, fw: c_int, mc: c_int, next: c_int) void {
                if (host.find) |ff| ff(host, t, fw, mc, next);
            }
        }.f, .{
            &text,
            @as(c_int, if (req.forward != 0) 1 else 0),
            @as(c_int, if (req.match_case != 0) 1 else 0),
            @as(c_int, if (req.find_next != 0) 1 else 0),
        });
    }

    pub fn findStop(self: *Host, req: proto.FindStop) void {
        const v = self.find(req.view) orelse return;
        withHostArgs(v, struct {
            fn f(host: *cef.cef_browser_host_t, clear: c_int) void {
                if (host.stop_finding) |sf| sf(host, clear);
            }
        }.f, .{@as(c_int, if (req.clear_selection != 0) 1 else 0)});
    }

    /// `set_zoom` (capability "zoom"): remember the user level and push
    /// the combined zoom (see `applyZoom` for why the DPR rides along).
    pub fn setZoom(self: *Host, req: proto.SetZoom) void {
        const v = self.find(req.view) orelse return;
        if (v.user_zoom_x100 == req.level_x100) return;
        v.user_zoom_x100 = req.level_x100;
        applyZoom(v);
    }

    /// Turn engine-side accessibility on/off for a view (`a11y_enable`,
    /// capability `a11y`). Enabling is what starts the renderer
    /// producing AX trees — it is not free, so nothing happens until a
    /// client asks. Idempotent; survives a discard via the flag.
    pub fn a11yEnable(self: *Host, req: proto.A11yEnable) void {
        const v = self.find(req.view) orelse return;
        const want = req.enabled != 0;
        if (v.a11y == want) return;
        v.a11y = want;
        if (!want) {
            if (v.ax_tree.len != 0) {
                self.gpa.free(v.ax_tree);
                v.ax_tree = &.{};
            }
            // A re-enable must restate the caret: the client dropped
            // its mirror when the stream stopped.
            v.ax_caret_sent = false;
        }
        applyA11yState(v);
    }

    // -- held security decisions ---------------------------------------

    /// The client answered a `ev_cert_error`. A decision for a view with
    /// nothing held is ignored: the request may already have been
    /// cancelled by a navigation or by the view going away.
    pub fn certDecision(self: *Host, req: proto.CertDecision) void {
        const v = self.find(req.view) orelse return;
        resolveCert(v, req.proceed != 0);
    }

    /// The client answered an `ev_permission`. An unknown prompt id is
    /// ignored for the same reason.
    pub fn permissionDecision(self: *Host, req: proto.PermissionDecision) void {
        const v = self.find(req.view) orelse return;
        for (&v.perms) |*p| {
            if (p.busy() and p.id == req.prompt) {
                resolvePerm(p, req.allow != 0);
                return;
            }
        }
    }

    // -- input ---------------------------------------------------------

    pub fn pointer(self: *Host, req: proto.InputPointer) void {
        latStamp("input");
        const v = self.findWake(req.view) orelse return;
        const pt = viewPoint(v, req.x, req.y);
        var ev = cef.cef_mouse_event_t{
            .x = pt.x,
            .y = pt.y,
            .modifiers = keymap.eventFlags(req.mods),
        };
        const button: cef.cef_mouse_button_type_t = switch (req.button) {
            1 => cef.MBT_MIDDLE,
            2 => cef.MBT_RIGHT,
            else => cef.MBT_LEFT,
        };
        const clicks: c_int = @max(1, @as(c_int, req.clicks));
        switch (@as(proto.PointerKind, @enumFromInt(req.kind))) {
            .move => withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) }),
            .leave => withHostArgs(v, sendMove, .{ &ev, @as(c_int, 1) }),
            .down => withHostArgs(v, sendClick, .{ &ev, button, @as(c_int, 0), clicks }),
            .up => withHostArgs(v, sendClick, .{ &ev, button, @as(c_int, 1), clicks }),
            _ => {},
        }
    }

    pub fn scroll(self: *Host, req: proto.InputScroll) void {
        const v = self.findWake(req.view) orelse return;
        const pt = viewPoint(v, req.x, req.y);
        var ev = cef.cef_mouse_event_t{
            .x = pt.x,
            .y = pt.y,
            .modifiers = keymap.eventFlags(req.mods),
        };
        // Protocol dy is positive DOWN; CEF's wheel delta is positive UP.
        // The deltas live in view-rect space too, so they scale with it.
        const d = viewPoint(v, req.dx, req.dy);
        withHostArgs(v, sendWheel, .{ &ev, d.x, -d.y });
    }

    pub fn key(self: *Host, req: proto.InputKey) void {
        const v = self.findWake(req.view) orelse return;
        const mapped = keymap.map(req.keyval);
        var ev = std.mem.zeroes(cef.cef_key_event_t);
        ev.size = @sizeOf(cef.cef_key_event_t);
        ev.modifiers = keymap.eventFlags(req.mods);
        if (mapped.keypad) ev.modifiers |= keymap.flag_is_key_pad;
        ev.windows_key_code = mapped.windows_key_code;
        ev.native_key_code = @bitCast(req.keycode);
        ev.character = mapped.character;
        ev.unmodified_character = mapped.character;

        if (@as(proto.KeyKind, @enumFromInt(req.kind)) == .up) {
            ev.type = cef.KEYEVENT_KEYUP;
            withHostArgs(v, sendKey, .{&ev});
            return;
        }
        ev.type = cef.KEYEVENT_RAWKEYDOWN;
        withHostArgs(v, sendKey, .{&ev});

        // Text delivery: the committed text wins when the client sent
        // it (dead keys, IME-less compose), otherwise the keysym's own
        // character. Ctrl/Alt chords produce no text.
        const chorded = req.mods & (proto.mod_ctrl | proto.mod_alt) != 0;
        if (req.text.len != 0) {
            var it = std.unicode.Utf8Iterator{ .bytes = req.text, .i = 0 };
            while (it.nextCodepoint()) |cp| charEvent(v, ev, cp);
        } else if (mapped.character != 0 and !chorded) {
            charEvent(v, ev, mapped.character);
        }
    }

    /// One CHAR event for `cp`; codepoints outside the BMP need a
    /// surrogate pair because CEF's character field is UTF-16.
    fn charEvent(v: *View, base_ev: cef.cef_key_event_t, cp: u21) void {
        var ev = base_ev;
        ev.type = cef.KEYEVENT_CHAR;
        if (cp <= 0xffff) {
            ev.character = @intCast(cp);
            ev.unmodified_character = ev.character;
            withHostArgs(v, sendKey, .{&ev});
            return;
        }
        const off = cp - 0x10000;
        const units = [2]u16{
            @intCast(0xd800 + (off >> 10)),
            @intCast(0xdc00 + (off & 0x3ff)),
        };
        for (units) |u| {
            ev.character = u;
            ev.unmodified_character = u;
            withHostArgs(v, sendKey, .{&ev});
        }
    }

    pub fn ime(self: *Host, req: proto.InputIme) void {
        const v = self.findWake(req.view) orelse return;
        var text = std.mem.zeroes(cef.cef_string_t);
        setStr(req.text, &text);
        defer cef.cef_string_utf16_clear(&text);
        switch (@as(proto.ImeKind, @enumFromInt(req.kind))) {
            .compose => {
                const pos: u32 = @bitCast(req.cursor);
                const sel = cef.cef_range_t{ .from = pos, .to = pos };
                withHostArgs(v, imeCompose, .{ &text, &sel });
            },
            .commit => withHostArgs(v, imeCommit, .{ &text, req.cursor }),
            .cancel => withHostArgs(v, imeCancel, .{}),
            _ => {},
        }
    }

    pub fn focus(self: *Host, req: proto.InputFocus) void {
        const v = self.findWake(req.view) orelse return;
        withHostArgs(v, setFocus, .{@as(c_int, if (req.focused != 0) 1 else 0)});
    }

    // -- WebExtensions -------------------------------------------------

    /// Load-or-toggle an extension (`webext_set`) and report its state.
    pub fn webextSet(self: *Host, req: proto.WebextSet) void {
        if (!extmanifest.idValid(req.id)) {
            self.post(proto.EvWebextState{
                .id = "",
                .name = "",
                .version = "",
                .enabled = 0,
                .ok = 0,
                .err = "invalid extension id",
            });
            return;
        }
        var prepared = self.webext.prepareSet(req.id, req.dir, req.enabled != 0) catch {
            if (self.webext.find(req.id)) |old| {
                self.postWebextState(old);
                return;
            }
            self.post(proto.EvWebextState{
                .id = req.id,
                .name = "",
                .version = "",
                .enabled = 0,
                .ok = 0,
                .err = "out of memory",
            });
            return;
        };
        defer prepared.deinit();
        self.quiesceWebext(req.id, "extension was reinstalled or toggled");
        const e = self.webext.commitSet(&prepared);
        if (e.enabled and e.ok) {
            self.publishOrigin(e);
            self.ensureBackground(e);
            self.injectContentScriptsAll(e);
        } else {
            wreqAbandonExt(req.id);
            self.repliesAbandonExt(req.id);
            self.portsAbandonExt(req.id);
            self.webext.clearListeners(e);
            self.teardownBackground(e);
            self.unpublishOrigin(e.id);
            self.teardownPopups(e.id);
        }
        self.postWebextState(e);
        self.postActionsForActiveViews();
    }

    /// Validate a staged tree before quiescing the currently running instance.
    pub fn webextInstallPrepare(self: *Host, req: proto.WebextInstallPrepare) void {
        if (!extmanifest.idValid(req.id)) {
            self.post(proto.EvWebextInstallPrepared{ .req = req.req, .id = req.id, .ok = 0, .err = "invalid extension id" });
            return;
        }
        var candidate = extinstall.validateDirectory(self.gpa, req.dir, req.id, req.version, null) catch |err| {
            self.post(proto.EvWebextInstallPrepared{ .req = req.req, .id = req.id, .ok = 0, .err = @errorName(err) });
            return;
        };
        candidate.deinit();
        self.quiesceWebext(req.id, "extension upgrade is committing");
        self.postActionsForActiveViews();
        self.post(proto.EvWebextInstallPrepared{ .req = req.req, .id = req.id, .ok = 1, .err = "" });
    }

    /// Load a package after the GUI's atomic swap and correlate the result.
    pub fn webextInstallCommit(self: *Host, req: proto.WebextInstallCommit) void {
        self.webextSet(.{ .id = req.id, .dir = req.dir, .enabled = req.enabled });
        const installed = self.webext.find(req.id);
        const ok = if (installed) |e|
            e.ok and e.enabled == (req.enabled != 0) and
                std.mem.eql(u8, if (e.man) |*m| m.version else "", req.version)
        else
            false;
        var detail: []const u8 = "extension load failed";
        if (installed) |e| {
            if (!ok) {
                if (e.err.len != 0) detail = e.err else if (!std.mem.eql(u8, if (e.man) |*m| m.version else "", req.version)) detail = "extension version mismatch";
                self.quiesceWebext(req.id, "extension upgrade was refused");
            }
        }
        self.post(proto.EvWebextInstallCommitted{
            .req = req.req,
            .id = req.id,
            .ok = @intFromBool(ok),
            .err = if (ok) "" else detail,
        });
    }

    fn quiesceWebext(self: *Host, id: []const u8, reason: []const u8) void {
        const old = self.webext.find(id) orelse return;
        self.revokeExtension(old, reason);
        wreqAbandonExt(id);
        self.repliesAbandonExt(id);
        self.portsAbandonExt(id);
        self.webext.clearListeners(old);
        self.teardownBackground(old);
        self.teardownPopups(id);
        self.unpublishOrigin(id);
        old.enabled = false;
        old.capability = @splat(0);
        old.capability_ok = false;
    }

    /// Make `chrome-extension://<host>/` resolve to this extension's
    /// unpacked directory. The locale is negotiated HERE, on the main
    /// thread, because the IO thread that serves the origin must not
    /// scan a directory to work one out per request.
    fn publishOrigin(self: *Host, e: *webexthost.Extension) void {
        var host_buf: [16]u8 = undefined;
        const host = extmanifest.originHost(e.id, &host_buf);
        var loc_buf: [extorigins.MAX_LOCALE]u8 = undefined;
        const locale = self.webext.resolveLocale(e, &loc_buf) orelse "";
        const war: []const []const u8 = if (e.man) |*m| m.web_accessible_resources else &.{};
        if (!e.capability_ok) return;
        _ = extorigins.publish(host, e.id, e.dir, war, locale, &e.capability);
    }

    fn unpublishOrigin(self: *Host, id: []const u8) void {
        _ = self;
        var host_buf: [16]u8 = undefined;
        extorigins.unpublish(extmanifest.originHost(id, &host_buf));
    }

    fn revokeExtension(self: *Host, e: *const webexthost.Extension, reason: []const u8) void {
        if (!e.capability_ok) return;
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-revoke\",\"tok\":\"") catch return;
        w.writeAll(&sem_secret.nonce) catch return;
        w.writeAll("\",\"ext\":") catch return;
        jsonStr(w, e.id) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.capability) catch return;
        w.writeAll(",\"reason\":") catch return;
        jsonStr(w, reason) catch return;
        w.writeByte('}') catch return;
        for (self.views.items) |v| {
            if (v.browser == null or v.discarded) continue;
            self.sendScriptAllFrames(v, cmd.written());
        }
    }

    pub fn webextRemove(self: *Host, id: []const u8) void {
        if (!extmanifest.idValid(id)) return;
        // An enumerated exit: every request this extension was holding
        // is continued before its registry goes away.
        wreqAbandonExt(id);
        self.repliesAbandonExt(id);
        self.portsAbandonExt(id);
        if (self.webext.find(id)) |e| {
            self.revokeExtension(e, "extension was removed");
            self.webext.clearListeners(e);
            self.teardownBackground(e);
        }
        self.teardownPopups(id);
        self.unpublishOrigin(id);
        self.webext.remove(id);
        self.postActionsForActiveViews();
        // A removal has no dedicated frame; the client already dropped
        // the row. Nothing more to report.
    }

    fn teardownPopups(self: *Host, id: []const u8) void {
        while (true) {
            var found: u32 = 0;
            for (self.views.items) |v| {
                if (!v.webext_popup) continue;
                if (std.mem.eql(u8, v.popup_ext[0..v.popup_ext_len], id)) {
                    found = v.id;
                    break;
                }
            }
            if (found == 0) return;
            self.destroyView(found);
        }
    }

    pub fn webextList(self: *Host) void {
        for (self.webext.exts.items) |*e| self.postWebextState(e);
    }

    /// `webext_tabs`: replace the mirrored tab list and turn the DIFF
    /// into MV2 `tabs.on*` events for every enabled extension.
    ///
    /// Deriving the events from a replace-all diff rather than trusting
    /// the client to send them is what makes a dropped or coalesced
    /// update harmless: the table is the truth and the events are a
    /// function of two consecutive tables.
    pub fn webextTabs(self: *Host, tabs_json: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, tabs_json, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .array) return;

        var incoming: std.ArrayList(exttabs.Incoming) = .empty;
        defer incoming.deinit(self.gpa);
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const o = item.object;
            incoming.append(self.gpa, .{
                .id = jsonU32(o, "id"),
                // The tabs JSON names views in the SENDER's namespace;
                // the edge cannot see into it, so translate at parse.
                .view = self.mapDispatchView(jsonU32(o, "view")),
                .window_id = jsonU32(o, "windowId"),
                .index = jsonU32(o, "index"),
                .active = jsonBool(o, "active"),
                .focused_window = jsonBool(o, "focusedWindow"),
                .url = jsonStrField(o, "url"),
                .title = jsonStrField(o, "title"),
                .loading = jsonBool(o, "loading"),
            }) catch return;
        }

        var diff = self.webext.tabs.replace(self.gpa, incoming.items) catch return;
        defer diff.deinit(self.gpa);

        for (diff.created) |id| {
            if (self.webext.tabs.find(id)) |tb| self.postTabEvent("onCreated", tb, null);
        }
        for (diff.updated) |ch| {
            const tb = self.webext.tabs.find(ch.id) orelse continue;
            self.postTabEvent("onUpdated", tb, ch);
        }
        if (diff.activated) |id| {
            if (self.webext.tabs.find(id)) |tb| self.postTabEvent("onActivated", tb, null);
        }
        for (diff.removed) |id| {
            self.postTabRemoved(id);
            for (self.webext.exts.items) |*e| e.action.removeTab(self.gpa, id);
        }
        self.postActionsForActiveViews();
    }

    /// Replace-all toolbar action state for every active page view.
    fn postActionsForActiveViews(self: *Host) void {
        for (self.webext.tabs.tabs.items) |*tb| {
            if (tb.view == 0 or self.find(tb.view) == null) continue;
            if (tb.active) {
                const json = self.actionSnapshot(tb.id) orelse continue;
                defer self.gpa.free(json);
                self.post(proto.EvWebextActions{ .view = tb.view, .actions_json = json });
            } else {
                // Replace-all means inactive views must receive the empty
                // replacement too. Otherwise a split pane that loses focus
                // keeps a stale, clickable toolbar action forever.
                self.post(proto.EvWebextActions{ .view = tb.view, .actions_json = "[]" });
            }
        }
    }

    fn actionSnapshot(self: *Host, tab: u32) ?[]u8 {
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeByte('[') catch return null;
        var first = true;
        for (self.webext.exts.items) |*e| {
            if (!e.enabled or !e.ok or !e.action.present) continue;
            const a = e.action.effective(tab);
            if (!a.visible) continue;
            if (!first) w.writeByte(',') catch return null;
            first = false;
            w.writeAll("{\"id\":") catch return null;
            jsonStr(w, e.id) catch return null;
            w.writeAll(",\"title\":") catch return null;
            jsonStr(w, if (a.title.len != 0) a.title else if (e.man) |*m| m.name else e.id) catch return null;
            w.writeAll(",\"icon\":") catch return null;
            jsonStr(w, a.icon) catch return null;
            w.writeAll(",\"badge\":") catch return null;
            jsonStr(w, a.badge) catch return null;
            w.print(",\"badgeTextColor\":[{d},{d},{d},{d}],\"badgeBackgroundColor\":[{d},{d},{d},{d}],\"enabled\":{s},\"popup\":{s}}}", .{
                a.badge_text_color.r,               a.badge_text_color.g,                      a.badge_text_color.b,       a.badge_text_color.a,
                a.badge_background_color.r,         a.badge_background_color.g,                a.badge_background_color.b, a.badge_background_color.a,
                if (a.enabled) "true" else "false", if (a.popup.len != 0) "true" else "false",
            }) catch return null;
        }
        w.writeByte(']') catch return null;
        return aw.toOwnedSlice() catch null;
    }

    /// A trusted browser-toolbar activation. The active mirrored tab is
    /// the authority: a stale/background GUI face cannot activate one.
    pub fn webextActionActivate(self: *Host, req: proto.WebextActionActivate) void {
        if (!extmanifest.idValid(req.id)) {
            self.popupError(req, "invalid extension id");
            return;
        }
        const tb = self.webext.tabs.findByView(req.view) orelse {
            self.popupError(req, "action is not available for this tab");
            return;
        };
        if (!tb.active) {
            self.popupError(req, "action is not available for this tab");
            return;
        }
        const owner = self.find(req.view) orelse {
            self.popupError(req, "action owner is gone");
            return;
        };
        const e = self.webext.find(req.id) orelse {
            self.popupError(req, "extension is not available");
            return;
        };
        if (!e.enabled or !e.ok or !e.action.present) {
            self.popupError(req, "extension action is not available");
            return;
        }
        const a = e.action.effective(tb.id);
        if (!a.visible or !a.enabled) {
            self.popupError(req, "extension action is disabled");
            return;
        }
        if (a.popup.len == 0) {
            const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
            if (bg) |v| {
                var cmd: std.Io.Writer.Allocating = .init(self.gpa);
                defer cmd.deinit();
                cmd.writer.writeAll("{\"op\":\"ext-action-clicked\",\"ext\":") catch return;
                jsonStr(&cmd.writer, e.id) catch return;
                cmd.writer.writeAll(",\"cap\":") catch return;
                jsonStr(&cmd.writer, &e.capability) catch return;
                cmd.writer.writeAll(",\"tab\":") catch return;
                exttabs.Table.writeTab(tb, &cmd.writer) catch return;
                cmd.writer.writeByte('}') catch return;
                self.sendScript(v, cmd.written());
            }
            self.popupError(req, "extension action has no popup");
            return;
        }
        if (req.popup_view < proto.WEBEXT_POPUP_VIEW_BASE or self.find(req.popup_view) != null) {
            self.popupError(req, "invalid popup view id");
            return;
        }
        while (self.popupForOwner(req.view)) |old| self.destroyView(old.id);
        const clean = std.mem.trimStart(u8, a.popup, "/");
        const asset_end = std.mem.indexOfAny(u8, clean, "?#") orelse clean.len;
        const asset = clean[0..asset_end];
        if (asset.len == 0 or std.mem.indexOf(u8, asset, "..") != null) {
            self.popupError(req, "invalid popup path");
            return;
        }
        const popup_asset = self.webext.readAsset(e, asset) orelse {
            self.popupError(req, "popup asset not found");
            return;
        };
        self.gpa.free(popup_asset);
        var host_buf: [16]u8 = undefined;
        var url_buf: [2048]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, ext_scheme ++ "://{s}/{s}", .{
            extmanifest.originHost(e.id, &host_buf), clean,
        }) catch {
            self.popupError(req, "popup URL is too long");
            return;
        };
        const v = self.gpa.create(View) catch {
            self.popupError(req, "out of memory");
            return;
        };
        const scale: u16 = if (req.scale_x1000 == 0) 1000 else req.scale_x1000;
        v.* = .{
            .id = req.popup_view,
            // Hand-built (not registerView), so the multi-client owner
            // stamp must be applied here too or the popup's frames are
            // routed to nobody.
            .owner = self.dispatch_conn,
            .inline_view = self.dispatch_inline,
            .w = @max(req.w, 1),
            .h = @max(req.h, 1),
            .scale_x1000 = scale,
            .pw = physicalOf(@max(req.w, 1), scale),
            .ph = physicalOf(@max(req.h, 1), scale),
            .context = owner.context,
            .webext_popup = true,
            .webext_origin = true,
            .popup_owner = req.view,
            .sem = semantic.View.init(self.gpa),
        };
        if (e.id.len > v.popup_ext.len) {
            v.sem.deinit();
            self.gpa.destroy(v);
            self.popupError(req, "invalid extension id");
            return;
        }
        @memcpy(v.popup_ext[0..e.id.len], e.id);
        v.popup_ext_len = e.id.len;
        self.views.append(self.gpa, v) catch {
            v.sem.deinit();
            self.gpa.destroy(v);
            self.popupError(req, "out of memory");
            return;
        };
        self.spawnPopup(v, url) catch |err| {
            self.removePopupView(v);
            self.popupError(req, switch (err) {
                error.ContextGone => "the page's browser context no longer exists",
                else => "popup browser creation failed",
            });
        };
    }

    fn popupError(self: *Host, req: proto.WebextActionActivate, detail: []const u8) void {
        if (req.popup_view == 0) return;
        self.post(proto.EvWebextPopup{
            .owner_view = req.view,
            .popup_view = req.popup_view,
            .state = proto.webext_popup_error,
            .detail = detail,
        });
    }

    fn removePopupView(self: *Host, popup: *View) void {
        for (self.views.items, 0..) |v, i| {
            if (v != popup) continue;
            _ = self.views.swapRemove(i);
            self.freeView(v);
            return;
        }
    }

    fn spawnPopup(self: *Host, v: *View, url_utf8: []const u8) !void {
        // FIRST, before any engine call: the owner page's container may
        // have been destroyed since it opened, and a popup created on
        // the global context would leave the container's egress.
        const rc = try self.contextForSpawn(v);
        var winfo = windowlessInfo(v);
        // Popups are short-lived and small. Force software frames so the
        // GTK popover owns one simple mapping, never a dma-buf pool.
        winfo.shared_texture_enabled = 0;
        var settings = windowlessSettings(v);
        var url = std.mem.zeroes(cef.cef_string_t);
        setStr(url_utf8, &url);
        defer cef.cef_string_utf16_clear(&url);
        self.pending = v;
        defer self.pending = null;
        const browser = cef.cef_browser_host_create_browser_sync(
            &winfo,
            &client,
            &url,
            &settings,
            null,
            rc,
        );
        if (browser == null) return error.BrowserCreateFailed;
        v.browser = browser;
        v.cef_id = browserInt(browser, "get_identifier");
        applyA11yState(v);
        try self.allocBuffer(v);
        self.post(proto.EvWebextPopup{
            .owner_view = v.popup_owner,
            .popup_view = v.id,
            .state = proto.webext_popup_opened,
            .detail = url_utf8,
        });
    }

    /// One `tabs.on*` event, to every enabled extension's background
    /// page. Content frames do not get them: MV2 delivers `tabs` events
    /// to extension pages only.
    fn postTabEvent(self: *Host, ev: []const u8, tb: *const exttabs.Tab, change: ?exttabs.Change) void {
        for (self.webext.exts.items) |*e| {
            if (!e.enabled or !e.ok) continue;
            const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
            if (bg == null) continue;
            var cmd: std.Io.Writer.Allocating = .init(self.gpa);
            defer cmd.deinit();
            const w = &cmd.writer;
            w.writeAll("{\"op\":\"ext-tab-event\",\"ext\":") catch continue;
            jsonStr(w, e.id) catch continue;
            w.writeAll(",\"cap\":") catch continue;
            jsonStr(w, &e.capability) catch continue;
            w.writeAll(",\"ev\":") catch continue;
            jsonStr(w, ev) catch continue;
            w.writeAll(",\"args\":[") catch continue;
            if (std.mem.eql(u8, ev, "onActivated")) {
                w.print("{{\"tabId\":{d},\"windowId\":{d}}}", .{ tb.id, tb.window_id }) catch continue;
            } else if (change) |ch| {
                // MV2's onUpdated: (tabId, changeInfo, tab).
                w.print("{d},{{", .{tb.id}) catch continue;
                var first = true;
                if (ch.url) {
                    w.writeAll("\"url\":") catch continue;
                    jsonStr(w, tb.url) catch continue;
                    first = false;
                }
                if (ch.title) {
                    if (!first) w.writeByte(',') catch continue;
                    w.writeAll("\"title\":") catch continue;
                    jsonStr(w, tb.title) catch continue;
                    first = false;
                }
                if (ch.status) {
                    if (!first) w.writeByte(',') catch continue;
                    w.writeAll("\"status\":") catch continue;
                    jsonStr(w, if (tb.loading) "loading" else "complete") catch continue;
                }
                w.writeAll("},") catch continue;
                exttabs.Table.writeTab(tb, w) catch continue;
            } else {
                exttabs.Table.writeTab(tb, w) catch continue;
            }
            w.writeAll("]}") catch continue;
            self.sendScript(bg.?, cmd.written());
        }
    }

    fn postTabRemoved(self: *Host, id: u32) void {
        for (self.webext.exts.items) |*e| {
            if (!e.enabled or !e.ok) continue;
            const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
            if (bg == null) continue;
            var cmd: std.Io.Writer.Allocating = .init(self.gpa);
            defer cmd.deinit();
            const w = &cmd.writer;
            w.writeAll("{\"op\":\"ext-tab-event\",\"ext\":") catch continue;
            jsonStr(w, e.id) catch continue;
            w.writeAll(",\"cap\":") catch continue;
            jsonStr(w, &e.capability) catch continue;
            w.print(",\"ev\":\"onRemoved\",\"args\":[{d},{{\"windowId\":0,\"isWindowClosing\":false}}]}}", .{id}) catch continue;
            self.sendScript(bg.?, cmd.written());
        }
    }

    fn postWebextState(self: *Host, e: *webexthost.Extension) void {
        self.post(proto.EvWebextState{
            .id = e.id,
            .name = if (e.man) |*m| m.name else "",
            .version = if (e.man) |*m| m.version else "",
            .enabled = if (e.enabled) 1 else 0,
            .ok = if (e.ok) 1 else 0,
            .err = e.err,
        });
    }

    /// Spin up the hidden background page for an enabled extension that
    /// declares one. Idempotent.
    fn ensureBackground(self: *Host, e: *webexthost.Extension) void {
        const man = if (e.man) |*m| m else return;
        const bg = man.background orelse return;
        if (bg.scripts.len == 0 and bg.page == null) return;
        if (e.bg_view != 0 and self.find(e.bg_view) != null) return;

        const id = self.next_bg_view;
        self.next_bg_view += 1;
        const v = self.gpa.create(View) catch return;
        v.* = .{
            .id = id,
            .w = 1,
            .h = 1,
            .scale_x1000 = 1000,
            .pw = 1,
            .ph = 1,
            .context = 0,
            .webext_bg = true,
            .sem = semantic.View.init(self.gpa),
        };
        self.views.append(self.gpa, v) catch {
            v.sem.deinit();
            self.gpa.destroy(v);
            return;
        };
        e.bg_view = id;
        webrequest.setBgView(e.id, id);
        var url_buf: [512]u8 = undefined;
        const url = self.backgroundUrl(e, &url_buf);
        v.webext_origin = std.mem.startsWith(u8, url, ext_scheme ++ "://");
        self.spawnBackground(v, url) catch {
            webrequest.setBgView(e.id, 0);
            self.destroyView(id);
            e.bg_view = 0;
            return;
        };
    }

    /// Where a background page lives.
    ///
    /// With a working `chrome-extension://` scheme this is the AUTHOR's
    /// document at the extension's own origin, which is the whole reason
    /// the scheme exists: the engine then loads its `<script src>` in
    /// document order, ES modules and all, and every relative url,
    /// `fetch` and `import` inside resolves. `background.scripts` gets a
    /// generated document at the same origin, so both forms end up with
    /// one origin and one code path.
    ///
    /// Without the scheme (it was refused, or the extension declares no
    /// background page) it falls back to the old `data:` document, and
    /// `injectBackground` evaluates the scraped scripts instead — which
    /// cannot run a module and says so in the log.
    fn backgroundUrl(self: *Host, e: *webexthost.Extension, buf: []u8) []const u8 {
        const fallback = "data:text/html,<!doctype html><title>bg</title>";
        if (!ext_scheme_ok) return fallback;
        const man = if (e.man) |*m| m else return fallback;
        const bg = man.background orelse return fallback;
        var host_buf: [16]u8 = undefined;
        const host = extmanifest.originHost(e.id, &host_buf);
        _ = self;
        if (bg.page) |page| {
            const clean = std.mem.trimStart(u8, page, "/");
            return std.fmt.bufPrint(buf, ext_scheme ++ "://{s}/{s}", .{ host, clean }) catch fallback;
        }
        // `background.scripts`: a generated document at the same origin.
        // The path is reserved and served by the scheme handler.
        return std.fmt.bufPrint(buf, ext_scheme ++ "://{s}{s}", .{
            host, extorigins.GENERATED_BG_PATH,
        }) catch fallback;
    }

    /// Like `spawnBrowser` but for a hidden background page: no frame
    /// buffer, so it never paints or is announced. The semantic bridge
    /// still injects at context creation, so `injectBackground` can send
    /// its scripts on load.
    fn spawnBackground(self: *Host, v: *View, url_utf8: []const u8) !void {
        var winfo = windowlessInfo(v);
        var bsettings = windowlessSettings(v);
        var url = std.mem.zeroes(cef.cef_string_t);
        setStr(url_utf8, &url);
        defer cef.cef_string_utf16_clear(&url);
        self.pending = v;
        defer self.pending = null;
        const browser = cef.cef_browser_host_create_browser_sync(&winfo, &client, &url, &bsettings, null, null);
        if (browser == null) return error.BrowserCreateFailed;
        v.browser = browser;
        v.cef_id = browserInt(browser, "get_identifier");
        v.hidden = true;
        // The SAME rule as `spawnBrowser`, and this is the other browser
        // creation path — now taken for every real extension. Leaving a
        // background page at STATE_DEFAULT lets the engine enable
        // accessibility on it by itself on any desktop with an at-spi
        // bus, and its tree then arrives carrying an `ax_tree_id` bound
        // to no view: `axResolveView` rebinds the unknown token onto the
        // single a11y-enabled CLIENT view, so a screen reader gets the
        // blank 1x1 background page instead of the page being read.
        applyA11yState(v);
        // Tell the engine the view is hidden so it keeps no compositor /
        // frame production alive for a page that never paints.
        withHost(v, struct {
            fn f(host: *cef.cef_browser_host_t) void {
                if (host.was_hidden) |wh| wh(host, 1);
            }
        }.f);
    }

    fn teardownBackground(self: *Host, e: *webexthost.Extension) void {
        if (e.bg_view == 0) return;
        const view = e.bg_view;
        e.bg_view = 0;
        webrequest.setBgView(e.id, 0);
        // An enumerated exit: the page that would answer is going away.
        wreqAbandonView(view);
        self.destroyView(view);
    }

    /// Inject an extension's content scripts into every live, non-hidden
    /// client view whose url matches — used when an extension is enabled
    /// while pages are already open.
    fn injectContentScriptsAll(self: *Host, e: *webexthost.Extension) void {
        for (self.views.items) |v| {
            if (v.webext_bg or v.webext_popup or v.webext_origin or v.discarded or v.browser == null) continue;
            if (v.url.len == 0) continue;
            const b = v.browser orelse continue;
            const gf = b.get_main_frame orelse continue;
            const frame: *cef.cef_frame_t = gf(b) orelse continue;
            defer release(&frame.base);
            self.injectExtInto(frame, v.url, e, null);
        }
    }

    /// Inject every enabled extension's content scripts matching `v`'s
    /// url. `only_phase` null runs every content script (load end / late
    /// enable); a specific phase runs only scripts whose `run_at` equals
    /// it (load start, for document_start scripts).
    fn injectMatchingExtensions(
        self: *Host,
        v: *View,
        frame: *cef.cef_frame_t,
        only_phase: ?manifestRunAt,
    ) void {
        if (v.webext_bg or v.webext_popup or v.webext_origin) return;
        // A SUBFRAME's own url decides what matches there — an ad iframe
        // on `ads.example` is not the page's origin, and `all_frames`
        // exists precisely to reach it.
        const main = isMainFrame(frame);
        var url_buf: [2048]u8 = undefined;
        const url = if (main) v.url else blk: {
            const gu = frame.get_url orelse break :blk v.url;
            const u = userfreeInto(gu(frame), &url_buf);
            break :blk if (u.len != 0) u else v.url;
        };
        for (self.webext.exts.items) |*e| {
            if (!e.enabled or !e.ok) continue;
            self.injectExtInto(frame, url, e, only_phase);
        }
    }

    /// Build and send one `ext-inject` for extension `e` into view `v`,
    /// including only content scripts whose match patterns accept the
    /// url and (when `only_phase` is set) whose run_at equals it.
    fn injectExtInto(
        self: *Host,
        frame: *cef.cef_frame_t,
        url: []const u8,
        e: *webexthost.Extension,
        only_phase: ?manifestRunAt,
    ) void {
        const man = if (e.man) |*m| m else return;
        const main = isMainFrame(frame);
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        var any = false;

        // Buffer CSS and JS across all matching content_scripts.
        var css_buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer css_buf.deinit();
        var js_buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer js_buf.deinit();
        var css_first = true;
        var js_first = true;

        for (man.content_scripts) |cs| {
            if (only_phase) |p| {
                if (cs.run_at != p) continue;
            }
            // `all_frames` was parsed and honoured by nothing: every
            // injection went to the main frame. Honouring it is the
            // whole point of ad-iframe filtering.
            if (!main and !cs.all_frames) continue;
            if (!self.contentScriptMatches(cs, url)) continue;
            any = true;
            for (cs.css) |rel| {
                const bytes = self.webext.readAsset(e, rel) orelse continue;
                defer self.gpa.free(bytes);
                if (!css_first) css_buf.writer.writeByte(',') catch {};
                css_first = false;
                jsonStr(&css_buf.writer, bytes) catch {};
            }
            for (cs.js) |rel| {
                const bytes = self.webext.readAsset(e, rel) orelse continue;
                defer self.gpa.free(bytes);
                if (!js_first) js_buf.writer.writeByte(',') catch {};
                js_first = false;
                jsonStr(&js_buf.writer, bytes) catch {};
            }
        }
        if (!any) return;

        // The nonce AUTHENTICATES the command; `priv` (deliberately
        // absent here) AUTHORIZES publishing the globals. Content
        // scripts must not get `window.browser`, but they must still
        // prove they came from this process: `ext-inject` hands the
        // scripts it runs a live `browser.*` bound to `ext`, so an
        // unauthenticated one let ANY page pass its own source and get
        // that extension's tabs and storage.local.
        w.writeAll("{\"op\":\"ext-inject\",\"tok\":\"") catch return;
        w.writeAll(&sem_secret.nonce) catch return;
        w.writeAll("\",\"ext\":") catch return;
        jsonStr(w, e.id) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.capability) catch return;
        w.writeAll(",\"base\":") catch return;
        var base_buf: [256]u8 = undefined;
        var host_buf: [16]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buf, ext_scheme ++ "://{s}/", .{
            extmanifest.originHost(e.id, &host_buf),
        }) catch "";
        jsonStr(w, base) catch return;
        w.writeAll(",\"uilang\":") catch return;
        jsonStr(w, webexthost.uiLanguage()) catch return;
        // manifest inline (small), for getManifest.
        w.writeAll(",\"manifest\":") catch return;
        self.writeManifestJson(w, e) catch w.writeAll("{}") catch return;
        w.writeAll(",\"messages\":") catch return;
        self.writeMessagesJson(w, e);
        w.writeAll(",\"css\":[") catch return;
        w.writeAll(css_buf.written()) catch return;
        w.writeAll("],\"scripts\":[") catch return;
        w.writeAll(js_buf.written()) catch return;
        w.writeAll("]}") catch return;
        self.sendScriptToFrame(frame, cmd.written());
    }

    fn writeManifestJson(self: *Host, w: *std.Io.Writer, e: *webexthost.Extension) !void {
        var buf: [4096]u8 = undefined;
        const mpath = std.fmt.bufPrint(&buf, "{s}/manifest.json", .{e.dir}) catch return error.Path;
        const bytes = webexthost.readFilePub(self.gpa, mpath, webext_max_asset) orelse return error.NoFile;
        defer self.gpa.free(bytes);
        // Inline the raw manifest bytes verbatim (already valid JSON).
        try w.writeAll(bytes);
    }

    /// Inline the `_locales/<default_locale>/messages.json` object (or
    /// `null`) so `browser.i18n.getMessage` resolves synchronously in
    /// the content script.
    fn writeMessagesJson(self: *Host, w: *std.Io.Writer, e: *webexthost.Extension) void {
        var loc_buf: [extorigins.MAX_LOCALE]u8 = undefined;
        const locale = self.webext.resolveLocale(e, &loc_buf) orelse {
            w.writeAll("null") catch {};
            return;
        };
        var buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/_locales/{s}/messages.json", .{ e.dir, locale }) catch {
            w.writeAll("null") catch {};
            return;
        };
        const bytes = webexthost.readFilePub(self.gpa, path, webext_max_asset) orelse {
            w.writeAll("null") catch {};
            return;
        };
        defer self.gpa.free(bytes);
        w.writeAll(bytes) catch {};
    }

    fn contentScriptMatches(self: *Host, cs: manifestContentScript, url: []const u8) bool {
        var set = extmatch.PatternSet{};
        defer set.deinit(self.gpa);
        for (cs.matches) |pat| set.addInclude(self.gpa, pat) catch continue;
        for (cs.exclude_matches) |pat| set.addExclude(self.gpa, pat) catch continue;
        if (set.include.items.len == 0) return false;
        return set.matchesUrl(url);
    }

    /// Bring an extension's background page up once its document is
    /// loaded (called from the load handler).
    ///
    /// On the ORIGIN path there is nothing to do: the served document
    /// already carried the bootstrap and the engine already loaded the
    /// author's scripts itself, in document order, modules included.
    /// This function is therefore the FALLBACK — reached only when the
    /// `chrome-extension` scheme was refused — and it evaluates the
    /// scripts through the bridge instead.
    fn injectBackground(self: *Host, v: *View, e: *webexthost.Extension) void {
        if (v.webext_origin) return;
        const man = if (e.man) |*m| m else return;
        const bg = man.background orelse return;
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-inject\",\"tok\":\"") catch return;
        w.writeAll(&sem_secret.nonce) catch return;
        w.writeAll("\",\"priv\":true,") catch return;
        if (c.getenv("SKETERM_WEB_EXT_DEBUG") != null) w.writeAll("\"dbg\":true,") catch return;
        w.writeAll("\"ext\":") catch return;
        jsonStr(w, e.id) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.capability) catch return;
        w.writeAll(",\"base\":") catch return;
        var base_buf: [256]u8 = undefined;
        var host_buf: [16]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buf, ext_scheme ++ "://{s}/", .{
            extmanifest.originHost(e.id, &host_buf),
        }) catch "";
        jsonStr(w, base) catch return;
        w.writeAll(",\"manifest\":") catch return;
        self.writeManifestJson(w, e) catch w.writeAll("{}") catch return;
        w.writeAll(",\"messages\":") catch return;
        self.writeMessagesJson(w, e);
        w.writeAll(",\"css\":[],\"scripts\":[") catch return;
        var first = true;
        if (bg.page) |page| {
            // `background.page`: read the document and run its scripts
            // in source order. A MODULE cannot be run this way (a static
            // import is a SyntaxError under `new Function`) so it is
            // skipped with a diagnostic rather than thrown into the log
            // as a mystery parse error.
            self.writeBackgroundPageScripts(w, e, page, &first);
        }
        for (bg.scripts) |rel| {
            const bytes = self.webext.readAsset(e, rel) orelse continue;
            defer self.gpa.free(bytes);
            if (!first) w.writeByte(',') catch {};
            first = false;
            jsonStr(w, bytes) catch {};
        }
        w.writeAll("]}") catch return;
        self.sendScript(v, cmd.written());
    }

    /// Append a `background.page` document's scripts, in source order,
    /// to an `ext-inject` script array. FALLBACK PATH ONLY.
    fn writeBackgroundPageScripts(
        self: *Host,
        w: *std.Io.Writer,
        e: *webexthost.Extension,
        page: []const u8,
        first: *bool,
    ) void {
        const html = self.webext.readAsset(e, page) orelse return;
        defer self.gpa.free(html);
        var buf: [64]bgpage.Script = undefined;
        for (bgpage.scan(html, &buf)) |s| {
            if (s.is_module) {
                self.post(proto.EvConsole{
                    .view = 0,
                    .level = 2,
                    .msg = "[webext] background module skipped: no chrome-extension:// origin",
                });
                continue;
            }
            const src: []const u8 = if (s.src.len != 0) blk: {
                // Resolve relative to the page's own directory, as the
                // document itself would.
                var rel_buf: [1024]u8 = undefined;
                const rel = extassets.resolveRelative(page, s.src, &rel_buf) orelse continue;
                break :blk self.webext.readAsset(e, rel) orelse continue;
            } else s.body;
            defer if (s.src.len != 0) self.gpa.free(src);
            if (!first.*) w.writeByte(',') catch {};
            first.* = false;
            jsonStr(w, src) catch {};
        }
    }

    /// Handle one `ext-*` message from a content or background frame
    /// (routed here from `onScriptMessage`). `v` is the frame's view.
    fn onExtMessage(self: *Host, v: *View, op: []const u8, json: []const u8) void {
        if (std.mem.eql(u8, op, "ext-call")) {
            self.extApiCall(v, json);
        } else if (std.mem.eql(u8, op, "ext-send")) {
            self.extRouteSend(v, json);
        } else if (std.mem.eql(u8, op, "ext-wreq-decision")) {
            self.wreqDecision(v, json);
        } else if (std.mem.eql(u8, op, "ext-reply")) {
            self.extRouteReply(v, json);
        } else if (std.mem.eql(u8, op, "ext-connect")) {
            self.extPortConnect(v, json);
        } else if (std.mem.eql(u8, op, "ext-port-msg")) {
            self.extPortMessage(v, json);
        } else if (std.mem.eql(u8, op, "ext-port-close")) {
            self.extPortClose(v, json);
        } else if (std.mem.eql(u8, op, "ext-error")) {
            const E = struct { ext: []const u8 = "", cap: []const u8 = "", msg: []const u8 = "" };
            const e = std.json.parseFromSlice(E, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
            defer e.deinit();
            if (self.webext.authorize(e.value.ext, e.value.cap) == null) return;
            // Surfaced as a console frame so it reaches the client log.
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "[webext {s}] {s}", .{ e.value.ext, e.value.msg }) catch return;
            self.post(proto.EvConsole{ .view = v.id, .level = 2, .msg = line });
        }
    }

    /// A `browser.*` API call: dispatch through the host and reply with
    /// `ext-result`. A storage mutation's `onChanged` is broadcast to
    /// this extension's frames.
    fn extApiCall(self: *Host, v: *View, json: []const u8) void {
        const R = struct {
            ext: []const u8 = "",
            cap: []const u8 = "",
            ns: []const u8 = "",
            method: []const u8 = "",
            args: std.json.Value = .null,
            req: u32 = 0,
        };
        const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const r = parsed.value;
        const e = self.webext.authorizeCapability(r.cap) orelse return;
        if (!std.mem.eql(u8, e.id, r.ext)) {
            self.extReplyErr(v, r.req, r.ext, r.cap, "extension capability does not authorize the requested id");
            return;
        }
        // A CONTENT SCRIPT has no business registering a network
        // filter: it runs in a page's renderer, in the main world, and
        // a page could reach it. Only the extension's own background
        // page may. This is the one gate `dispatchApi` cannot make on
        // its own — it has no idea which frame called.
        if (std.mem.eql(u8, r.ns, "webRequest") and !v.webext_bg) {
            self.extReplyErr(v, r.req, e.id, &e.capability, "webRequest listeners require an extension page");
            return;
        }
        // `tabs.sendMessage` has to reach a FRAME, which the engine-free
        // host cannot do; it is answered here instead and never reaches
        // `dispatchApi`.
        if (std.mem.eql(u8, r.ns, "runtime") and std.mem.eql(u8, r.method, "reload")) {
            self.extRequestReload(r.ext);
            self.extReplyOk(v, e, r.req, "null");
            return;
        }
        if (std.mem.eql(u8, r.ns, "tabs") and std.mem.eql(u8, r.method, "sendMessage")) {
            self.extTabsSendMessage(v, e, r.req, r.args);
            return;
        }
        // `tabs.update`/`reload` navigate a VIEW, which again only the
        // engine side can do. uBO reaches for `update` to show its
        // "blocked page" document, so a stub that silently dropped it
        // would leave the user on a dead tab with no explanation.
        if (std.mem.eql(u8, r.ns, "tabs") and
            (std.mem.eql(u8, r.method, "update") or std.mem.eql(u8, r.method, "reload")))
        {
            self.extTabsNavigate(v, e, r.req, r.method, r.args);
            return;
        }
        if (std.mem.eql(u8, r.ns, "browserAction") and
            std.mem.eql(u8, r.method, "openPopup"))
        {
            self.extOpenPopup(v, e, r.req);
            return;
        }
        // Re-serialize args as a JSON array string for the host.
        var args_buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer args_buf.deinit();
        std.json.Stringify.value(r.args, .{}, &args_buf.writer) catch {
            self.extReplyErr(v, r.req, e.id, &e.capability, "arguments could not be encoded");
            return;
        };
        var changed: ?[]u8 = null;
        const result = self.webext.dispatchApi(e, r.ns, r.method, args_buf.written(), &changed);
        // A webRequest registration is the moment the request path
        // learns WHERE to send the question: `ensureBackground` may have
        // run before the extension was ever published, so recording the
        // view here — from the frame the call actually arrived on — is
        // the only placement that cannot be stale.
        if (std.mem.eql(u8, r.ns, "webRequest")) webrequest.setBgView(e.id, v.id);
        defer self.gpa.free(result);
        if (std.mem.eql(u8, r.ns, "browserAction") or std.mem.eql(u8, r.ns, "pageAction"))
            self.postActionsForActiveViews();
        // result is `{"result":..}` or `{"error":..}`; forward the inner
        // value/ok to the frame.
        self.sendExtResult(v, e, r.req, result);
        if (changed) |ch| {
            defer self.gpa.free(ch);
            self.broadcastChanged(e, ch);
        }
    }

    /// THE `ext-result` builder. Every answer to an extension API call
    /// — a host dispatch result, an error, a routed reply — goes out
    /// through here, so the command shape exists once.
    /// `result_json` must already BE JSON; an error message is escaped
    /// by `extReplyErr` before it gets here.
    fn sendExtReply(
        self: *Host,
        v: *View,
        ext: []const u8,
        capability: []const u8,
        req: u32,
        ok: bool,
        result_json: []const u8,
    ) void {
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-result\",\"ext\":") catch return;
        jsonStr(w, ext) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, capability) catch return;
        w.print(",\"req\":{d},\"ok\":{s},\"result\":", .{ req, if (ok) "true" else "false" }) catch return;
        w.writeAll(result_json) catch return;
        w.writeByte('}') catch return;
        self.sendScript(v, cmd.written());
    }

    fn sendExtResult(self: *Host, v: *View, e: *const webexthost.Extension, req: u32, host_result: []const u8) void {
        // host_result is a full `{"result":X}` / `{"error":X}` object;
        // the frame wants the inner value plus an ok flag.
        const is_err = std.mem.indexOf(u8, host_result, "\"error\"") != null;
        self.sendExtReply(v, e.id, &e.capability, req, !is_err, innerJson(host_result));
    }

    fn extReplyErr(self: *Host, v: *View, req: u32, ext: []const u8, capability: []const u8, message: []const u8) void {
        var msg: std.Io.Writer.Allocating = .init(self.gpa);
        defer msg.deinit();
        jsonStr(&msg.writer, message) catch return;
        self.sendExtReply(v, ext, capability, req, false, msg.written());
    }

    fn extReplyOk(self: *Host, v: *View, e: *const webexthost.Extension, req: u32, result_json: []const u8) void {
        self.sendExtReply(v, e.id, &e.capability, req, true, result_json);
    }

    /// Route `browserAction.openPopup()` to the GUI that owns the native toolbar.
    fn extOpenPopup(self: *Host, caller: *View, e: *webexthost.Extension, req: u32) void {
        if (e.action.kind != .browser or !(caller.webext_bg or caller.webext_popup or caller.webext_origin)) {
            self.extReplyErr(caller, req, e.id, &e.capability, "openPopup requires an extension page");
            return;
        }
        const tb = self.webext.tabs.active() orelse {
            self.extReplyErr(caller, req, e.id, &e.capability, "no active tab in the focused window");
            return;
        };
        const action = e.action.effective(tb.id);
        if (!action.visible or !action.enabled or action.popup.len == 0) {
            self.extReplyErr(caller, req, e.id, &e.capability, "extension action has no enabled visible popup");
            return;
        }
        const ext_copy = self.gpa.dupe(u8, e.id) catch {
            self.extReplyErr(caller, req, e.id, &e.capability, "out of memory");
            return;
        };
        const wire_req = self.webext_next_gid;
        self.webext_next_gid +%= 1;
        if (self.webext_next_gid == 0) self.webext_next_gid = 1;
        if (!self.pushReply(.{
            .kind = .popup,
            .gid = wire_req,
            .origin_req = req,
            .origin_view = caller.id,
            .reply_view = tb.view,
            .ext = ext_copy,
            // The GUI answers or it does not; without a deadline a
            // dropped 0xBB reply parks this Promise for the life of the
            // page. Same clock as a routed message.
            .deadline_ms = nowMs() + route_reply_timeout_ms,
        })) {
            self.gpa.free(ext_copy);
            self.extReplyErr(caller, req, e.id, &e.capability, "out of memory");
            return;
        }
        self.post(proto.EvWebextOpenPopup{ .view = tb.view, .id = e.id, .req = wire_req });
        // The Promise remains pending until the GUI acknowledges that
        // it created the native popup (or reports why it could not).
    }

    pub fn webextOpenPopupResult(self: *Host, result: proto.WebextOpenPopupResult) void {
        const wait = self.takeReply(.popup, result.req, result.view, result.id) orelse return;
        defer self.gpa.free(wait.ext);
        const caller = self.find(wait.origin_view) orelse return;
        const e = self.webext.find(wait.ext) orelse return;
        if (result.ok != 0) {
            self.extReplyOk(caller, e, wait.origin_req, "null");
        } else {
            const detail = if (result.detail.len != 0) result.detail else "native popup was not created";
            self.extReplyErr(caller, wait.origin_req, e.id, &e.capability, detail);
        }
    }

    /// Park a Promise on an answer from `reply_view`. The table is
    /// bounded; the oldest entry is REJECTED (never silently dropped)
    /// to make room.
    /// @return false when the record could not be stored, in which case
    /// the caller still owes its own Promise an answer.
    fn pushReply(self: *Host, rec: PendingReply) bool {
        while (self.webext_replies.items.len >= 256) {
            const old = self.webext_replies.orderedRemove(0);
            self.failReply(old, "too many pending extension replies");
        }
        self.webext_replies.append(self.gpa, rec) catch return false;
        return true;
    }

    /// Remove the one record matching a recipient's answer. The triple
    /// is what correlates: the id we minted, the view that answered,
    /// and the extension it claims to be.
    fn takeReply(self: *Host, kind: PendingReply.Kind, gid: u32, reply_view: u32, ext: []const u8) ?PendingReply {
        for (self.webext_replies.items, 0..) |rec, i| {
            if (rec.kind == kind and rec.gid == gid and rec.reply_view == reply_view and
                std.mem.eql(u8, rec.ext, ext))
                return self.webext_replies.orderedRemove(i);
        }
        return null;
    }

    /// Reject a parked Promise and free the record. Silent when the
    /// waiting view or the extension is already gone — there is then
    /// nothing left to answer.
    fn failReply(self: *Host, rec: PendingReply, message: []const u8) void {
        if (self.find(rec.origin_view)) |origin| {
            if (self.webext.find(rec.ext)) |e|
                self.extReplyErr(origin, rec.origin_req, e.id, &e.capability, message);
        }
        self.gpa.free(rec.ext);
    }

    /// A view died: every record naming it on either end leaves, and
    /// the OTHER end (if it is the one waiting) is told why.
    fn repliesAbandonView(self: *Host, view: u32) void {
        var i: usize = 0;
        while (i < self.webext_replies.items.len) {
            const rec = self.webext_replies.items[i];
            if (rec.origin_view != view and rec.reply_view != view) {
                i += 1;
                continue;
            }
            const taken = self.webext_replies.orderedRemove(i);
            if (taken.origin_view != view) {
                self.failReply(taken, taken.kind.gone());
            } else {
                self.gpa.free(taken.ext);
            }
        }
    }

    /// An extension was disabled, removed, reloaded or reparsed: its
    /// pages are going away with it, so the records are dropped without
    /// an answer — the JS object waiting for one has just been revoked.
    fn repliesAbandonExt(self: *Host, id: []const u8) void {
        var i: usize = 0;
        while (i < self.webext_replies.items.len) {
            if (!std.mem.eql(u8, self.webext_replies.items[i].ext, id)) {
                i += 1;
                continue;
            }
            self.gpa.free(self.webext_replies.orderedRemove(i).ext);
        }
    }

    /// A content frame's `runtime.sendMessage`: route it to the
    /// extension's background page, remembering where to send the reply.
    fn extRouteSend(self: *Host, v: *View, json: []const u8) void {
        const R = struct { ext: []const u8 = "", cap: []const u8 = "", req: u32 = 0, msg: std.json.Value = .null };
        const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const r = parsed.value;
        const e = self.webext.authorizeCapability(r.cap) orelse return;
        if (!std.mem.eql(u8, e.id, r.ext)) {
            self.extReplyErr(v, r.req, r.ext, r.cap, "extension capability does not authorize the requested id");
            return;
        }
        const bg = if (e.bg_view != 0) self.find(e.bg_view) else null;
        if (bg == null) {
            // No background listening: resolve to undefined, as the web
            // API does when nothing answers.
            self.extReplyErr(v, r.req, e.id, &e.capability, "extension has no background listener");
            return;
        }
        const gid = self.webext_next_gid;
        self.webext_next_gid +%= 1;
        if (self.webext_next_gid == 0) self.webext_next_gid = 1;
        const ext_copy = self.gpa.dupe(u8, e.id) catch {
            self.extReplyErr(v, r.req, e.id, &e.capability, "out of memory");
            return;
        };
        if (!self.pushReply(.{
            .kind = .message,
            .gid = gid,
            .origin_view = v.id,
            .origin_req = r.req,
            .reply_view = bg.?.id,
            .ext = ext_copy,
            .deadline_ms = nowMs() + route_reply_timeout_ms,
        })) {
            self.gpa.free(ext_copy);
            self.extReplyErr(v, r.req, e.id, &e.capability, "out of memory");
            return;
        }
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.print("{{\"op\":\"ext-message\",\"ext\":", .{}) catch return;
        jsonStr(w, e.id) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.capability) catch return;
        w.print(",\"gid\":{d},\"sender\":", .{gid}) catch return;
        self.writeSender(w, v, e.id) catch return;
        w.writeAll(",\"msg\":") catch return;
        std.json.Stringify.value(r.msg, .{}, w) catch return;
        w.writeByte('}') catch return;
        self.sendScript(bg.?, cmd.written());
    }

    /// `browser.runtime.reload()` — restart ONE extension.
    ///
    /// Not a nicety. uBlock Origin's first run ends with
    /// `vAPI.app.restart()` and a bare `return`: on a Chromium-flavoured
    /// browser with no stored version it deliberately abandons the rest
    /// of its boot and waits to be started again. With `reload` stubbed
    /// out as a no-op, uBO therefore sat forever half-initialised —
    /// enabled, listening, and filtering NOTHING, with no error anywhere.
    ///
    /// Deferred to the next poll turn (`webextPump`) because it destroys
    /// the background page whose script is mid-call.
    fn extRequestReload(self: *Host, id: []const u8) void {
        for (self.webext_reload.items) |pending| {
            if (std.mem.eql(u8, pending, id)) return;
        }
        const copy = self.gpa.dupe(u8, id) catch return;
        self.webext_reload.append(self.gpa, copy) catch {
            self.gpa.free(copy);
            return;
        };
    }

    /// Perform the deferred extension restarts. Once per poll turn.
    pub fn webextPump(self: *Host) void {
        // Debounced storage.local writes land here, one loop iteration
        // after their window expires.
        self.webext.flushStores(nowMs());
        if (self.webext_reload.items.len == 0) return;
        const pending = self.webext_reload.toOwnedSlice(self.gpa) catch return;
        defer {
            for (pending) |p| self.gpa.free(p);
            self.gpa.free(pending);
        }
        for (pending) |id| {
            const e = self.webext.find(id) orelse continue;
            if (!e.enabled or !e.ok) continue;
            // A full down-and-up: the listeners, the Ports and the
            // background page all belong to the instance going away.
            self.revokeExtension(e, "extension reloaded");
            wreqAbandonExt(id);
            self.repliesAbandonExt(id);
            self.portsAbandonExt(id);
            self.webext.clearListeners(e);
            self.teardownBackground(e);
            if (!self.webext.rotateCapability(e)) {
                self.unpublishOrigin(id);
                self.postWebextState(e);
                continue;
            }
            self.publishOrigin(e);
            self.ensureBackground(e);
            self.injectContentScriptsAll(e);
        }
    }

    /// `browser.tabs.update({url})` / `tabs.reload()` — navigate the
    /// view a tab is showing.
    fn extTabsNavigate(self: *Host, v: *View, e: *webexthost.Extension, req: u32, method: []const u8, args: std.json.Value) void {
        const items = if (args == .array) args.array.items else &[_]std.json.Value{};
        const raw_id: i64 = if (items.len > 0 and items[0] == .integer) items[0].integer else -1;
        // A negative id means "the active tab", MV2's default.
        const tb = blk: {
            // Range-checked, not narrowed: an out-of-range id must
            // resolve to NO tab, not wrap onto a real one. In
            // ReleaseFast `@intCast` truncates, so `tabs.update(2**32+1,
            // {url})` navigated tab 1 — a tab the extension never named.
            if (raw_id >= 0) break :blk if (exttabs.u32Of(items[0])) |id| self.webext.tabs.find(id) else null;
            break :blk self.webext.tabs.active();
        } orelse {
            self.extReplyErr(v, req, e.id, &e.capability, "no such tab");
            return;
        };
        const target = if (tb.view != 0) self.find(tb.view) else null;
        if (target == null) {
            self.extReplyErr(v, req, e.id, &e.capability, "tab has no live browser view");
            return;
        }
        var url: []const u8 = "";
        if (std.mem.eql(u8, method, "update")) {
            if (items.len > 1 and items[1] == .object) {
                if (items[1].object.get("url")) |u| {
                    if (u == .string) url = u.string;
                }
            }
        }
        if (c.getenv("SKETERM_WEB_WREQ_DEBUG") != null) {
            std.debug.print("tabs.{s} tab {d} -> \"{s}\"\n", .{ method, tb.id, url });
        }
        if (url.len != 0) {
            self.navigate(.{ .view = target.?.id, .url = url });
        } else if (std.mem.eql(u8, method, "reload")) {
            self.navAction(.{ .view = target.?.id, .action = @intFromEnum(proto.NavAct.reload) });
        }
        self.extReplyOk(v, e, req, "null");
    }

    /// `browser.tabs.sendMessage(tabId, message)` — the direction that
    /// did not exist: background -> a CONTENT frame.
    ///
    /// It cannot live in `webext/host.zig` with the rest of `tabs`,
    /// because delivering it means finding a view and evaluating in its
    /// frames, which is engine work. It reuses the `webext_replies`
    /// table, just with the roles swapped: the background is the origin
    /// awaiting a reply and the content frame answers with `ext-reply`.
    fn extTabsSendMessage(self: *Host, v: *View, e: *webexthost.Extension, req: u32, args: std.json.Value) void {
        const items = if (args == .array) args.array.items else &[_]std.json.Value{};
        if (items.len < 1 or items[0] != .integer) {
            self.extReplyErr(v, req, e.id, &e.capability, "bad tab id");
            return;
        }
        const tab_id: u32 = exttabs.u32Of(items[0]) orelse {
            // Same rule as extTabsNavigate: out of range names no tab.
            self.extReplyErr(v, req, e.id, &e.capability, "bad tab id");
            return;
        };
        const tb = self.webext.tabs.find(tab_id) orelse {
            self.extReplyErr(v, req, e.id, &e.capability, "no such tab");
            return;
        };
        const target = if (tb.view != 0) self.find(tb.view) else null;
        if (target == null) {
            self.extReplyErr(v, req, e.id, &e.capability, "tab has no live browser view");
            return;
        }
        const gid = self.webext_next_gid;
        self.webext_next_gid +%= 1;
        if (self.webext_next_gid == 0) self.webext_next_gid = 1;
        const ext_copy = self.gpa.dupe(u8, e.id) catch {
            self.extReplyErr(v, req, e.id, &e.capability, "out of memory");
            return;
        };
        if (!self.pushReply(.{
            .kind = .message,
            .gid = gid,
            .origin_view = v.id,
            .origin_req = req,
            .reply_view = target.?.id,
            .ext = ext_copy,
            .deadline_ms = nowMs() + route_reply_timeout_ms,
        })) {
            self.gpa.free(ext_copy);
            self.extReplyErr(v, req, e.id, &e.capability, "out of memory");
            return;
        }
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-message\",\"ext\":") catch return;
        jsonStr(w, e.id) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.capability) catch return;
        w.print(",\"gid\":{d},\"sender\":{{\"id\":", .{gid}) catch return;
        jsonStr(w, e.id) catch return;
        w.writeAll("},\"msg\":") catch return;
        const msg = if (items.len > 1) items[1] else std.json.Value.null;
        std.json.Stringify.value(msg, .{}, w) catch return;
        w.writeByte('}') catch return;
        // Every frame of the tab, so a content script in an iframe is
        // reachable too; the FIRST reply wins, which is what MV2's
        // single-response contract already means.
        self.sendScriptAllFrames(target.?, cmd.written());
    }

    // -- runtime.connect Ports ----------------------------------------

    /// A frame opened a Port. Mint the id, remember both ends, tell the
    /// opener its number and the far end that it has a connection.
    ///
    /// The far end is the extension's background page (MV2 routes a
    /// content script's `connect` there). A connect with no background
    /// listening is answered with `gid = 0`, which the JS side turns
    /// into an immediate `onDisconnect` — never a silent hang, since a
    /// content script that gets neither reply is a content script that
    /// wedged.
    fn extPortConnect(self: *Host, v: *View, json: []const u8) void {
        const R = struct { ext: []const u8 = "", cap: []const u8 = "", lid: u32 = 0, name: []const u8 = "" };
        const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const r = parsed.value;
        const e = self.webext.authorize(r.ext, r.cap);
        const bg_view = if (e) |ex| ex.bg_view else 0;
        // A background page cannot connect to itself.
        const target = if (bg_view != 0 and bg_view != v.id) self.find(bg_view) else null;
        if (e == null or target == null) {
            if (e) |ex| self.sendPortOpen(v, ex, r.lid, 0);
            return;
        }
        const gid = self.webext_next_port;
        self.webext_next_port +%= 1;
        if (self.webext_next_port == 0) self.webext_next_port = 1;
        // A page that opens ports without bound must not grow the table
        // without bound; the oldest is closed, exactly as `webext_replies`
        // drops its oldest entry.
        if (self.webext_ports.items.len >= 256) {
            const old = self.webext_ports.orderedRemove(0);
            self.notifyPortClosed(old.a_view, old.ext, old.gid);
            self.notifyPortClosed(old.b_view, old.ext, old.gid);
            self.gpa.free(old.ext);
        }
        const ext_copy = self.gpa.dupe(u8, r.ext) catch {
            self.sendPortOpen(v, e.?, r.lid, 0);
            return;
        };
        self.webext_ports.append(self.gpa, .{
            .gid = gid,
            .ext = ext_copy,
            .a_view = v.id,
            .b_view = bg_view,
        }) catch {
            self.gpa.free(ext_copy);
            self.sendPortOpen(v, e.?, r.lid, 0);
            return;
        };
        self.sendPortOpen(v, e.?, r.lid, gid);

        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-port-incoming\",\"ext\":") catch return;
        jsonStr(w, r.ext) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.?.capability) catch return;
        w.print(",\"gid\":{d},\"name\":", .{gid}) catch return;
        jsonStr(w, r.name) catch return;
        w.writeAll(",\"sender\":") catch return;
        self.writeSender(w, v, r.ext) catch return;
        w.writeByte('}') catch return;
        self.sendScript(target.?, cmd.written());
    }

    fn sendPortOpen(self: *Host, v: *View, e: *const webexthost.Extension, lid: u32, gid: u32) void {
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-port-open\",\"ext\":") catch return;
        jsonStr(w, e.id) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.capability) catch return;
        w.print(",\"lid\":{d},\"gid\":{d}}}", .{ lid, gid }) catch return;
        self.sendScript(v, cmd.written());
    }

    fn findPort(self: *Host, gid: u32) ?*Port {
        for (self.webext_ports.items) |*p| {
            if (p.gid == gid) return p;
        }
        return null;
    }

    fn extPortMessage(self: *Host, v: *View, json: []const u8) void {
        const R = struct { ext: []const u8 = "", cap: []const u8 = "", gid: u32 = 0, msg: std.json.Value = .null };
        const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
        const p = self.findPort(parsed.value.gid) orelse return;
        if (!std.mem.eql(u8, p.ext, e.id)) return;
        // "Not a participant" and "the peer is gone" are different
        // answers: `peerOf` returns 0 for both, and treating the first
        // as the second let a non-participant CLOSE any port it named.
        if (p.a_view != v.id and p.b_view != v.id) return;
        const peer_id = p.peerOf(v.id);
        const peer = if (peer_id != 0) self.find(peer_id) else null;
        if (peer == null) {
            // The far end went away: tell the sender rather than
            // dropping its message into nothing.
            self.closePortByGid(parsed.value.gid);
            return;
        }
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-port-recv\",\"ext\":") catch return;
        jsonStr(w, p.ext) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.capability) catch return;
        w.print(",\"gid\":{d},\"msg\":", .{parsed.value.gid}) catch return;
        std.json.Stringify.value(parsed.value.msg, .{}, w) catch return;
        w.writeByte('}') catch return;
        self.sendScript(peer.?, cmd.written());
    }

    fn extPortClose(self: *Host, v: *View, json: []const u8) void {
        const R = struct { ext: []const u8 = "", cap: []const u8 = "", gid: u32 = 0 };
        const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
        // ONLY a participant may close a port. gids are small and
        // sequential, so ignoring the calling view let anything able to
        // emit `ext-*` walk the space and disconnect ports belonging to
        // OTHER tabs — and a content script treats a disconnect as
        // teardown, so uBO and Violentmonkey would go silently dead
        // across every open tab with nothing logged.
        const p = self.findPort(parsed.value.gid) orelse return;
        if (!std.mem.eql(u8, p.ext, e.id)) return;
        if (p.a_view != v.id and p.b_view != v.id) return;
        self.closePortByGid(parsed.value.gid);
    }

    /// Drop a port and tell BOTH ends. Telling the closer too is
    /// deliberate: its own `disconnect()` already marked it dead, and a
    /// close arriving from the other direction must reach it.
    fn closePortByGid(self: *Host, gid: u32) void {
        for (self.webext_ports.items, 0..) |p, i| {
            if (p.gid != gid) continue;
            const rec = self.webext_ports.orderedRemove(i);
            self.notifyPortClosed(rec.a_view, rec.ext, rec.gid);
            self.notifyPortClosed(rec.b_view, rec.ext, rec.gid);
            self.gpa.free(rec.ext);
            return;
        }
    }

    fn notifyPortClosed(self: *Host, view: u32, ext: []const u8, gid: u32) void {
        const v = self.find(view) orelse return;
        const e = self.webext.find(ext) orelse return;
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        const w = &cmd.writer;
        w.writeAll("{\"op\":\"ext-port-closed\",\"ext\":") catch return;
        jsonStr(w, ext) catch return;
        w.writeAll(",\"cap\":") catch return;
        jsonStr(w, &e.capability) catch return;
        w.print(",\"gid\":{d}}}", .{gid}) catch return;
        self.sendScript(v, cmd.written());
    }

    /// Every port either end of which was `view` is closed, and the
    /// surviving end told. Called when a view goes away, and when its
    /// main document is replaced: a Port whose peer is gone (or whose
    /// peer's `Port` object died with its document) must disconnect,
    /// never wait forever. Idempotent, so the paths that do both in
    /// sequence cost only a scan.
    pub fn portsAbandonView(self: *Host, view: u32) void {
        var i: usize = 0;
        while (i < self.webext_ports.items.len) {
            const p = self.webext_ports.items[i];
            if (p.a_view != view and p.b_view != view) {
                i += 1;
                continue;
            }
            const rec = self.webext_ports.orderedRemove(i);
            self.notifyPortClosed(rec.peerOf(view), rec.ext, rec.gid);
            self.gpa.free(rec.ext);
        }
    }

    /// Same, for every port of one extension (disabled, removed,
    /// reparsed): the listener functions on both ends are going away.
    fn portsAbandonExt(self: *Host, id: []const u8) void {
        var i: usize = 0;
        while (i < self.webext_ports.items.len) {
            const p = self.webext_ports.items[i];
            if (!std.mem.eql(u8, p.ext, id)) {
                i += 1;
                continue;
            }
            const rec = self.webext_ports.orderedRemove(i);
            self.notifyPortClosed(rec.a_view, rec.ext, rec.gid);
            self.notifyPortClosed(rec.b_view, rec.ext, rec.gid);
            self.gpa.free(rec.ext);
        }
    }

    /// The MV2 `MessageSender`. `{id}` alone was never enough: Dark
    /// Reader keys its per-tab state on `sender.tab.id` and every
    /// extension that answers a content script reads `sender.url`.
    fn writeSender(self: *Host, w: *std.Io.Writer, v: *View, ext: []const u8) !void {
        try w.writeAll("{\"id\":");
        try jsonStr(w, ext);
        try w.writeAll(",\"url\":");
        try jsonStr(w, v.url);
        // Frame identity: 0 is the main frame, matching MV2. Subframe
        // ids are per-view sequence numbers assigned as frames are seen.
        try w.print(",\"frameId\":{d}", .{v.cur_frame_id});
        if (self.webext.tabs.findByView(v.id)) |tb| {
            try w.writeAll(",\"tab\":");
            try exttabs.Table.writeTab(tb, w);
        }
        try w.writeByte('}');
    }

    /// The background's reply to a routed message: deliver it to the
    /// original content frame's pending promise.
    fn extRouteReply(self: *Host, v: *View, json: []const u8) void {
        const R = struct { ext: []const u8 = "", cap: []const u8 = "", gid: u32 = 0, resp: std.json.Value = .null };
        const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
        const route = self.takeReply(.message, parsed.value.gid, v.id, e.id) orelse return;
        defer self.gpa.free(route.ext);
        const origin = self.find(route.origin_view) orelse return;
        var resp: std.Io.Writer.Allocating = .init(self.gpa);
        defer resp.deinit();
        std.json.Stringify.value(parsed.value.resp, .{}, &resp.writer) catch return;
        self.sendExtReply(origin, e.id, &e.capability, route.origin_req, true, resp.written());
    }

    // -- blocking webRequest, main-thread half ------------------------

    /// Called once per poll iteration. Two jobs, both of which have to
    /// happen on this thread because both touch a browser: dispatch the
    /// holds the IO thread queued, and fail-open anything past its
    /// deadline.
    ///
    /// Cheap when idle: one relaxed atomic load and a return.
    pub fn webrequestPump(self: *Host) void {
        if (!webrequestBusy()) return;
        webrequestDrainWake();

        // One pass, copying what we need out under the lock — sending a
        // command re-enters CEF and must not run with the spinlock held.
        const Job = struct {
            hid: u32,
            bg_view: u32,
            ext: usize,
            event: webrequest.Event,
            rtype: u8,
            view_id: u32,
            with_headers: bool,
            url: [HOLD_URL_MAX]u8,
            url_len: u16,
            method: [8]u8,
            method_len: u8,
            hdr: [HOLD_HDR_MAX]u8,
            hdr_len: u16,
            lids: [webrequest.MAX_MATCHED]u32,
            n_lids: u8,
        };
        var jobs: [MAX_HOLDS]Job = undefined;
        var njobs: usize = 0;
        var expired: [MAX_HOLDS]u32 = undefined;
        var nexpired: usize = 0;
        const now = nowMs();
        {
            g_wreq.acquire();
            defer g_wreq.release();
            for (&g_wreq.holds) |*h| {
                if (!h.used) continue;
                if (h.dispatched) {
                    if (now >= h.deadline_ms) {
                        expired[nexpired] = h.hid;
                        nexpired += 1;
                    }
                    continue;
                }
                h.dispatched = true;
                const j = &jobs[njobs];
                njobs += 1;
                j.* = .{
                    .hid = h.hid,
                    .bg_view = h.bg_view,
                    .ext = h.ext,
                    .event = h.event,
                    .rtype = h.rtype,
                    .view_id = h.view_id,
                    .with_headers = h.want_request_headers,
                    .url = h.url,
                    .url_len = h.url_len,
                    .method = h.method,
                    .method_len = h.method_len,
                    .hdr = h.hdr,
                    .hdr_len = h.hdr_len,
                    .lids = h.lids[@intFromEnum(h.event)],
                    .n_lids = h.n_lids[@intFromEnum(h.event)],
                };
            }
        }

        for (jobs[0..njobs]) |*j| {
            var ext_buf: [webrequest.MAX_ID]u8 = undefined;
            var ext_len: usize = 0;
            var observational = false;
            {
                g_wreq.acquire();
                defer g_wreq.release();
                if (wstatIdx(j.ext)) |s| {
                    ext_len = s.id_len;
                    @memcpy(ext_buf[0..ext_len], s.idSlice());
                }
                if (wreqFind(j.hid)) |h| observational = h.cb == null;
            }
            const bg = self.find(j.bg_view);
            if (ext_len == 0 or bg == null) {
                // The listener became unreachable between the hold and
                // this dispatch. An enumerated exit: fail open.
                self.wreqFailOpen(j.hid);
                continue;
            }
            var cmd: std.Io.Writer.Allocating = .init(self.gpa);
            defer cmd.deinit();
            const w = &cmd.writer;
            w.writeAll("{\"op\":\"ext-wreq\",\"ext\":") catch continue;
            jsonStr(w, ext_buf[0..ext_len]) catch continue;
            const e = self.webext.find(ext_buf[0..ext_len]) orelse {
                self.wreqFailOpen(j.hid);
                continue;
            };
            w.writeAll(",\"cap\":") catch continue;
            jsonStr(w, &e.capability) catch continue;
            w.print(",\"hid\":{d},\"event\":", .{j.hid}) catch continue;
            jsonStr(w, j.event.toStr()) catch continue;
            w.writeAll(",\"details\":{\"requestId\":") catch continue;
            var rid_buf: [24]u8 = undefined;
            const rid = std.fmt.bufPrint(&rid_buf, "{d}", .{j.hid}) catch "0";
            jsonStr(w, rid) catch continue;
            w.writeAll(",\"url\":") catch continue;
            jsonStr(w, j.url[0..j.url_len]) catch continue;
            w.writeAll(",\"method\":") catch continue;
            jsonStr(w, j.method[0..j.method_len]) catch continue;
            w.writeAll(",\"type\":") catch continue;
            const rt: webrequest.RType = @enumFromInt(j.rtype);
            jsonStr(w, rt.toStr()) catch continue;
            // THE TAB ID IS LOAD-BEARING, not decoration. MV2 defines
            // -1 as "not associated with a tab", and uBlock Origin's
            // `onBeforeRequest` reads exactly that: `if (tabId < 0)` it
            // takes its BEHIND-THE-SCENE path, where a page it has no
            // store for is handled by different rules — measured here as
            // uBO cancelling the top-level navigation of every page.
            // So the real tab is looked up from the client's mirrored
            // list, and -1 survives only for a view no tab claims (a
            // background page's own fetch, which IS tabless).
            const tab_id: i64 = if (self.webext.tabs.findByView(j.view_id)) |tb|
                @intCast(tb.id)
            else
                -1;
            w.print(",\"tabId\":{d},\"frameId\":0,\"parentFrameId\":-1,\"timeStamp\":{d}", .{ tab_id, now }) catch continue;
            // `documentUrl`/`originUrl` describe the document that CAUSED
            // the request, and MV2 OMITS them for a top-level navigation
            // — the document is the request. Sending the view's previous
            // url there (`about:blank` on a fresh view) makes a page
            // third-party to ITSELF, and uBO then strict-blocks the
            // navigation: measured as every page failing ERR_ABORTED.
            if (rt != .main_frame) {
                // OUR OWN view's url wins over the client's mirrored tab.
                // `v.url` is set in-process by `on_address_change`; the
                // tab table is at minimum a full round trip behind it
                // (helper -> socket -> GUI -> a coalescing idle -> back),
                // so right after a navigation the mirror still names the
                // PREVIOUS page. That made a page's own subresources
                // third-party to itself, which is exactly what uBO
                // strict-blocks. The mirror supplies IDENTITY (tabId),
                // never the url. Before the GUI posted a tab list at all
                // this could not bite, because the lookup always missed.
                const doc: []const u8 = if (self.find(j.view_id)) |pv| blk: {
                    if (pv.url.len != 0) break :blk pv.url;
                    break :blk if (self.webext.tabs.findByView(j.view_id)) |tb| tb.url else "";
                } else if (self.webext.tabs.findByView(j.view_id)) |tb| tb.url else "";
                if (doc.len != 0) {
                    w.writeAll(",\"documentUrl\":") catch continue;
                    jsonStr(w, doc) catch continue;
                    w.writeAll(",\"originUrl\":") catch continue;
                    jsonStr(w, doc) catch continue;
                }
            }
            if (j.with_headers and j.hdr_len != 0) {
                w.writeAll(",\"requestHeaders\":") catch continue;
                w.writeAll(j.hdr[0..j.hdr_len]) catch continue;
            }
            if (observational) w.writeAll(",\"obs\":true") catch continue;
            w.writeAll("}") catch continue;
            // The listener ids whose own filter matched. The frame runs
            // ONLY these.
            w.writeAll(",\"lids\":[") catch continue;
            for (j.lids[0..j.n_lids], 0..) |lid, li| {
                if (li != 0) w.writeByte(',') catch continue;
                w.print("{d}", .{lid}) catch continue;
            }
            w.writeByte(']') catch continue;
            if (c.getenv("SKETERM_WEB_WREQ_DEBUG") != null) {
                w.writeAll(",\"dbg\":true") catch continue;
            }
            w.writeByte('}') catch continue;
            self.sendScript(bg.?, cmd.written());
            // An OBSERVATIONAL notification is a mailbox drop, not a
            // question: the request continued long ago and no decision
            // is coming back. Retire the slot the moment the command is
            // out, so a page full of non-blocking notifications never
            // occupies the hold table or keeps the loop spinning.
            if (observational) self.wreqRetire(j.hid);
        }

        for (expired[0..nexpired]) |hid| {
            g_wreq.acquire();
            if (wreqFind(hid)) |h| {
                if (wstatIdx(h.ext)) |s| {
                    s.timed_out +%= 1;
                    s.failed_open +%= 1;
                }
            }
            g_wreq.release();
            // A timeout continues the request. NEVER cancels: a wedged
            // or slow extension must degrade the browser's filtering,
            // not its ability to load pages.
            self.wreqFailOpen(hid);
        }
    }

    /// Drop a slot that needs no answer (an observational mailbox that
    /// has been delivered). Distinct from `wreqFailOpen` only in that
    /// there is nothing to continue.
    fn wreqRetire(self: *Host, hid: u32) void {
        _ = self;
        g_wreq.acquire();
        defer g_wreq.release();
        const h = wreqFind(hid) orelse return;
        if (h.cb != null) return; // not ours to retire
        h.* = .{};
        _ = g_wreq.outstanding.fetchSub(1, .release);
    }

    /// Let a held request through, unfiltered, and free its slot. THE
    /// single "answer without a decision" exit, and it always continues
    /// — never cancels. A broken, slow or vanished extension must cost
    /// the user filtering, never the ability to load a page.
    ///
    /// Every path that can end a hold reaches one of exactly four
    /// places, and they are all of them:
    ///   - a decision arrived            -> `wreqDecision`
    ///   - the deadline passed           -> here, from `webrequestPump`
    ///   - the listener became unreachable between hold and dispatch
    ///                                   -> here, from `webrequestPump`
    ///   - the extension was disabled, removed or reparsed
    ///                                   -> `wreqAbandonExt`
    ///   - its background page or the requesting view was destroyed
    ///                                   -> `wreqAbandonView`
    ///   - the helper is shutting down   -> `webrequestDeinit`
    /// Anything added later that can make a listener unreachable MUST
    /// call one of these. A hold that is never answered is a page that
    /// never finishes loading, with no error and no way out.
    fn wreqFailOpen(self: *Host, hid: u32) void {
        _ = self;
        var cb: ?*cef.cef_callback_t = null;
        var req: ?*cef.cef_request_t = null;
        {
            g_wreq.acquire();
            defer g_wreq.release();
            const h = wreqFind(hid) orelse return;
            cb = h.cb;
            req = h.req;
            h.* = .{};
            _ = g_wreq.outstanding.fetchSub(1, .release);
        }
        if (cb) |x| {
            if (x.cont) |f| f(x);
            release(&x.base);
        }
        if (req) |r| release(&r.base);
    }

    /// A background page answered. Applies the decision to the held
    /// request and either continues it, cancels it, or moves it to the
    /// second phase (`onBeforeSendHeaders`).
    fn wreqDecision(self: *Host, v: *View, json: []const u8) void {
        const R = struct { ext: []const u8 = "", cap: []const u8 = "", hid: u32 = 0, d: std.json.Value = .null };
        const parsed = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const e = self.webext.authorize(parsed.value.ext, parsed.value.cap) orelse return;
        const hid = parsed.value.hid;

        // Take our OWN reference to the request before dropping the
        // lock: an abandon (extension removed, view destroyed) racing
        // us would otherwise release the last one while we are still
        // calling set_url on it.
        var req: ?*cef.cef_request_t = null;
        var event: webrequest.Event = .before_request;
        var want_sh = false;
        var ext: usize = 0;
        var start_us: i64 = 0;
        {
            g_wreq.acquire();
            defer g_wreq.release();
            const h = wreqFind(hid) orelse return;
            const st = wstatIdx(h.ext) orelse return;
            if (h.bg_view != v.id or !std.mem.eql(u8, st.idSlice(), e.id)) return;
            req = h.req;
            event = h.event;
            want_sh = h.want_send_headers;
            ext = h.ext;
            start_us = h.start_us;
            if (req) |r| if (r.base.add_ref) |ar| ar(&r.base);
        }
        defer if (req) |r| release(&r.base);

        var dec_buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer dec_buf.deinit();
        std.json.Stringify.value(parsed.value.d, .{}, &dec_buf.writer) catch return;
        const hdr_key: []const u8 = switch (event) {
            .before_send_headers => "requestHeaders",
            else => "",
        };
        var dp = webrequest.parseDecision(self.gpa, dec_buf.written(), hdr_key) catch return;
        defer dp.deinit(self.gpa);
        const d = dp.decision;
        // `SKETERM_WEB_WREQ_DEBUG=1` prints every decision with the url
        // it applies to. Finding out WHY a real extension blocked
        // something is otherwise guesswork: the verdict is computed in
        // another process, inside minified extension code.
        if (c.getenv("SKETERM_WEB_WREQ_DEBUG") != null) {
            var url_buf: [512]u8 = undefined;
            var url: []const u8 = "";
            if (req) |r| {
                if (r.get_url) |gu| url = userfreeInto(gu(r), &url_buf);
            }
            std.debug.print("wreq[{d}] {s} {s} -> {s}\n", .{
                hid, event.toStr(), url, dec_buf.written(),
            });
        }

        const cancel = d.cancel;
        var redirected = false;
        var hdr_changed = false;
        if (!cancel) {
            if (req) |r| {
                if (d.redirect) |u| {
                    // Changing the url of a request held in
                    // on_before_resource_load IS the redirect: CEF
                    // re-issues the load at the new url when we
                    // continue.
                    var s = std.mem.zeroes(cef.cef_string_t);
                    setStr(u, &s);
                    defer cef.cef_string_utf16_clear(&s);
                    if (r.set_url) |f| {
                        f(r, &s);
                        redirected = true;
                    }
                }
                if (d.headers) |edits| {
                    if (r.set_header_by_name) |seth| {
                        for (edits) |ed| {
                            var nk = std.mem.zeroes(cef.cef_string_t);
                            var nv = std.mem.zeroes(cef.cef_string_t);
                            setStr(ed.name, &nk);
                            defer cef.cef_string_utf16_clear(&nk);
                            if (ed.value.len != 0) setStr(ed.value, &nv);
                            defer cef.cef_string_utf16_clear(&nv);
                            // An empty value REMOVES the header: MV2
                            // expresses a deletion by omitting it from
                            // the returned array, and the JS side turns
                            // that omission into an empty-valued entry.
                            seth(r, &nk, if (ed.value.len != 0) &nv else null, 1);
                            hdr_changed = true;
                        }
                    }
                }
            }
        }

        // Second phase, only when the first neither cancelled nor
        // redirected — a redirect restarts the request and its own
        // onBeforeSendHeaders fires on the new load.
        const go_second = !cancel and !redirected and event == .before_request and want_sh;

        // The second phase's header snapshot is built HERE, against the
        // reference we took above, and only COPIED under the lock:
        // `get_header_map` re-enters Chromium and allocates, which no
        // spinlock may be held across. Same stash-then-copy shape as
        // the hold in `onBeforeResourceLoad`.
        var hdr_buf: [HOLD_HDR_MAX]u8 = undefined;
        var hdr_len: u16 = 0;
        if (go_second) {
            if (req) |r| hdr_len = wreqHeadersJson(r, &hdr_buf);
        }

        var cb: ?*cef.cef_callback_t = null;
        var hreq: ?*cef.cef_request_t = null;
        {
            g_wreq.acquire();
            defer g_wreq.release();
            const h = wreqFind(hid) orelse return; // abandoned meanwhile
            if (wstatIdx(ext)) |s| {
                if (cancel) s.cancelled +%= 1;
                if (redirected) s.redirected +%= 1;
                if (hdr_changed) s.headers_modified +%= 1;
                const us = nowUs() - start_us;
                s.note(@intCast(std.math.clamp(us, 0, std.math.maxInt(u32))));
            }
            if (go_second) {
                h.event = .before_send_headers;
                h.dispatched = false;
                h.want_request_headers = true;
                if (h.hdr_len == 0 and hdr_len != 0) {
                    @memcpy(h.hdr[0..hdr_len], hdr_buf[0..hdr_len]);
                    h.hdr_len = hdr_len;
                }
                return;
            }
            cb = h.cb;
            hreq = h.req;
            h.* = .{};
            _ = g_wreq.outstanding.fetchSub(1, .release);
        }
        // The hold's own request reference is dropped OUTSIDE the lock:
        // it can be the last one, and the destructor is CEF code.
        if (hreq) |r| release(&r.base);
        if (cb) |x| {
            if (cancel) {
                if (x.cancel) |f| f(x);
            } else {
                if (x.cont) |f| f(x);
            }
            release(&x.base);
        }
    }

    /// Report per-extension blocking-webRequest counters (0xB4 -> 0xB5).
    pub fn webrequestStats(self: *Host) void {
        var out: [webrequest.MAX_PUBLISHED]proto.EvWebextWreqStats = undefined;
        var ids: [webrequest.MAX_PUBLISHED][webrequest.MAX_ID]u8 = undefined;
        var n: usize = 0;
        {
            g_wreq.acquire();
            defer g_wreq.release();
            for (&g_wreq.stats) |*s| {
                if (!s.used) continue;
                @memcpy(ids[n][0..s.id_len], s.idSlice());
                var sorted: [WREQ_SAMPLES]u32 = undefined;
                const cnt = @min(s.nsamples, WREQ_SAMPLES);
                @memcpy(sorted[0..cnt], s.samples[0..cnt]);
                std.mem.sort(u32, sorted[0..cnt], {}, std.sort.asc(u32));
                out[n] = .{
                    .id = ids[n][0..s.id_len],
                    .matched = s.matched,
                    .held = s.held,
                    .cancelled = s.cancelled,
                    .redirected = s.redirected,
                    .headers_modified = s.headers_modified,
                    .headers_received_dropped = s.headers_received_dropped,
                    .timed_out = s.timed_out,
                    .failed_open = s.failed_open,
                    .us_p50 = pct(sorted[0..cnt], 50),
                    .us_p95 = pct(sorted[0..cnt], 95),
                    .us_max = if (cnt == 0) 0 else sorted[cnt - 1],
                    .samples = cnt,
                };
                n += 1;
            }
        }
        for (out[0..n]) |ev| self.post(ev);
    }

    /// Deliver a `storage.onChanged` payload to every live frame of the
    /// extension (its content-script frames and its background).
    fn broadcastChanged(self: *Host, e: *webexthost.Extension, changes_json: []const u8) void {
        for (self.views.items) |v| {
            if (v.browser == null or v.discarded) continue;
            // Every frame with the extension injected has its ctx; a
            // frame that never got it ignores the command harmlessly.
            var cmd: std.Io.Writer.Allocating = .init(self.gpa);
            defer cmd.deinit();
            const w = &cmd.writer;
            w.writeAll("{\"op\":\"ext-changed\",\"ext\":") catch continue;
            jsonStr(w, e.id) catch continue;
            w.writeAll(",\"cap\":") catch continue;
            jsonStr(w, &e.capability) catch continue;
            w.writeAll(",\"area\":\"local\",\"changes\":") catch continue;
            w.writeAll(changes_json) catch continue;
            w.writeByte('}') catch continue;
            self.sendScriptAllFrames(v, cmd.written());
        }
    }

    /// Whether a bridge payload is an `ext-*` op. The cheap prefix test
    /// `onProcessMessage` uses to decide whether a SUBFRAME may be heard
    /// at all, without parsing the JSON first.
    fn payloadIsExt(self: *Host, raw: []const u8) bool {
        _ = self;
        // The payload is still NONCE-PREFIXED here — `onScriptMessage`
        // is what strips and checks it — so the test has to skip the
        // nonce first. Looking at the raw head instead silently answered
        // "not an extension message" for everything, which is how the
        // subframe half of `all_frames` stayed broken after the frames
        // were already being injected.
        if (raw.len <= sem_secret.nonce.len) return false;
        const json = raw[sem_secret.nonce.len..];
        // The script always emits `op` first, so this is a prefix test
        // rather than a parse: `{"op":"ext-`.
        const head = json[0..@min(json.len, 24)];
        return std.mem.indexOf(u8, head, "\"op\":\"ext-") != null;
    }

    // -- semantic layer ------------------------------------------------

    /// Hand one JSON command to the view's main frame, as a call into
    /// the script's command entry point (`window[<slot>]`).
    ///
    /// `execute_java_script` works straight from the browser process
    /// (CEF routes it to the frame's renderer), which is why the
    /// command direction needs no process message and no V8 call at
    /// all — only the REPLY direction does.
    fn sendScript(self: *Host, v: *View, json: []const u8) void {
        if (!sem_secret.ok) return;
        const b = v.browser orelse return;
        const gf = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = gf(b) orelse return;
        defer release(&frame.base);
        self.sendScriptToFrameGen(frame, json, v.sem_nav.generation);
    }

    /// Hand a command to ONE frame, main or not.
    fn sendScriptToFrame(self: *Host, frame: *cef.cef_frame_t, json: []const u8) void {
        self.sendScriptToFrameGen(frame, json, 0);
    }

    fn sendScriptToFrameGen(self: *Host, frame: *cef.cef_frame_t, json: []const u8, nav_gen: u32) void {
        if (!sem_secret.ok) return;
        var code: std.Io.Writer.Allocating = .init(self.gpa);
        defer code.deinit();
        const slot: []const u8 = &sem_secret.slot;
        code.writer.print("window[\"{s}\"]&&window[\"{s}\"](", .{ slot, slot }) catch return;
        jsonStr(&code.writer, json) catch return;
        code.writer.print(",{d})", .{nav_gen}) catch return;
        runJs(frame, code.written());
    }

    /// Hand a command to every frame of a view.
    ///
    /// Frame identifiers are opaque STRINGS in this CEF, enumerated into
    /// a `cef_string_list_t`; `get_frame_by_identifier` then takes a
    /// reference we must release. Used for messages that address a TAB
    /// rather than a document, where a content script in an ad iframe is
    /// as much a recipient as the top one.
    fn sendScriptAllFrames(self: *Host, v: *View, json: []const u8) void {
        if (!sem_secret.ok) return;
        const b = v.browser orelse return;
        const gfi = b.get_frame_identifiers orelse {
            self.sendScript(v, json);
            return;
        };
        const list = cef.cef_string_list_alloc() orelse {
            self.sendScript(v, json);
            return;
        };
        defer cef.cef_string_list_free(list);
        gfi(b, list);
        const n = cef.cef_string_list_size(list);
        if (n == 0) {
            self.sendScript(v, json);
            return;
        }
        const byid = b.get_frame_by_identifier orelse return;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var ident = std.mem.zeroes(cef.cef_string_t);
            defer cef.cef_string_utf16_clear(&ident);
            if (cef.cef_string_list_value(list, i, &ident) == 0) continue;
            const frame: *cef.cef_frame_t = byid(b, &ident) orelse continue;
            defer release(&frame.base);
            self.sendScriptToFrame(frame, json);
        }
    }

    /// Queue a request; the oldest is dropped when a page stops
    /// answering, so a dead script cannot grow the list without bound.
    fn pushPending(self: *Host, v: *View, p: Pending) !u32 {
        if (v.pending.items.len >= 32) {
            const old = v.pending.orderedRemove(0);
            self.failPending(v, old, "semantic request queue overflowed");
        }
        var stamped = p;
        if (stamped.client_request == 0) stamped.client_request = self.active_sem_request;
        stamped.nav_gen = v.sem_nav.generation;
        stamped.deadline_ms = nowMs() + semantic_request_timeout_ms;
        try v.pending.append(self.gpa, stamped);
        return p.req;
    }

    fn takePending(self: *Host, v: *View, req: u32) ?Pending {
        _ = self;
        if (req == 0) return null;
        for (v.pending.items, 0..) |p, i| {
            if (p.req == req) return v.pending.orderedRemove(i);
        }
        return null;
    }

    fn pendingFor(self: *Host, v: *View, req: u32) ?*Pending {
        _ = self;
        if (req == 0) return null;
        for (v.pending.items) |*p| {
            if (p.req == req) return p;
        }
        return null;
    }

    fn nextReq(v: *View) u32 {
        const r = v.sem_next_req;
        v.sem_next_req +%= 1;
        if (v.sem_next_req == 0) v.sem_next_req = 1;
        return r;
    }

    fn freePending(self: *Host, p: Pending) void {
        if (p.arg.len != 0) self.gpa.free(p.arg);
    }

    fn failPending(self: *Host, v: *View, p: Pending, msg: []const u8) void {
        defer self.freePending(p);
        const old_request = self.active_sem_request;
        self.active_sem_request = p.client_request;
        defer self.active_sem_request = old_request;
        switch (p.kind) {
            .snapshot => self.post(proto.SemSnapshot{
                .view = v.id,
                .doc_gen = 0,
                .rev = 0,
                .kind = @intFromEnum(proto.SnapKind.full),
                .payload = .{ .s = msg },
            }),
            .hints, .query => self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = msg } }),
            .click, .hover, .act, .set_value, .commit, .guarded_act, .choose_pick, .choose_done => self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = msg }),
            .expand => self.post(proto.SemExpandResult{ .view = v.id, .id = p.sid, .off = p.off, .text = msg }),
            .read => self.post(proto.SemReadResult{ .view = v.id, .markdown = .{ .s = msg } }),
            .read_ids => self.post(proto.SemReadIdsResult{
                .view = v.id,
                .doc_gen = 0,
                .rev = 0,
                .markdown = .{ .s = msg },
                .entities = &.{},
            }),
            .eval => self.post(proto.SemEvalResult{ .view = v.id, .ok = 0, .json = .{ .s = "{\"error\":\"semantic request expired\"}" } }),
        }
    }

    /// Navigation invalidates every command sent to the old V8 context.
    /// Reads and snapshots are safe to reissue against the new page;
    /// actions are not and are answered explicitly instead of hanging.
    ///
    /// This is the ONE place a main-frame document replacement passes
    /// through: the client-driven paths (`navigate`, `navAction`) call it
    /// before asking the engine, and `onLoadStart` calls it for every load
    /// they did not arm. So it is also where a content script's
    /// `runtime.connect` Ports die: their JS `Port` objects go with the
    /// document, and a Port nobody can reach again would otherwise sit in
    /// the table for the life of the helper, still messageable by its
    /// background page.
    fn semanticNavigationStarted(self: *Host, v: *View) void {
        v.sem_nav.start(false);
        v.sem_context_doc = 0;
        v.sem_observing = false;
        self.portsAbandonView(v.id);
        for (v.pending.items) |*p| {
            switch (p.kind) {
                .snapshot, .hints, .query, .read, .read_ids => {
                    p.rearm = true;
                    p.nav_gen = v.sem_nav.generation;
                    p.req = nextReq(v);
                    p.deadline_ms = nowMs() + semantic_request_timeout_ms;
                },
                else => {},
            }
        }
        var i: usize = 0;
        while (i < v.pending.items.len) {
            if (v.pending.items[i].rearm) {
                i += 1;
                continue;
            }
            const p = v.pending.orderedRemove(i);
            self.failPending(v, p, if (p.guarded or p.kind == .guarded_act) stale_reader_msg else "semantic action interrupted by navigation");
        }
    }

    /// Bound script operations even when a renderer remains alive but
    /// never replies. This releases owned args and unblocks its client.
    pub fn semanticPump(self: *Host, now: i64) void {
        for (self.views.items) |v| {
            var i: usize = 0;
            while (i < v.pending.items.len) {
                if (v.pending.items[i].deadline_ms > now) {
                    i += 1;
                    continue;
                }
                const p = v.pending.orderedRemove(i);
                self.failPending(v, p, "semantic request expired before the page replied");
            }
        }
        // Same rule for every parked extension Promise: a recipient
        // that never answers (bridge not bootstrapped, listener silent,
        // a GUI that dropped the popup acknowledgement) must not park
        // the caller forever.
        var i: usize = 0;
        while (i < self.webext_replies.items.len) {
            if (self.webext_replies.items[i].deadline_ms > now) {
                i += 1;
                continue;
            }
            const rec = self.webext_replies.orderedRemove(i);
            self.failReply(rec, rec.kind.expired());
        }
    }

    test "semantic navigation reissues reads with fresh ids and rejects guarded actions" {
        const gpa = std.testing.allocator;
        var out = proto.Outbox.init(gpa);
        defer out.deinit();
        var host = Host.init(gpa, &out);
        defer host.webext.deinit();
        const v = try gpa.create(View);
        defer gpa.destroy(v);
        v.* = .{
            .id = 7,
            .w = 1,
            .h = 1,
            .scale_x1000 = 1000,
            .pw = 1,
            .ph = 1,
            .sem = semantic.View.init(gpa),
        };
        defer v.sem.deinit();
        defer v.pending.deinit(gpa);
        try host.views.append(gpa, v);
        defer host.views.deinit(gpa);

        const arg = try gpa.dupe(u8, "typed");
        _ = try host.pushPending(v, .{ .req = nextReq(v), .kind = .read });
        _ = try host.pushPending(v, .{ .req = nextReq(v), .kind = .read_ids });
        _ = try host.pushPending(v, .{ .req = nextReq(v), .kind = .guarded_act, .sid = 44, .guarded = true, .arg = arg });
        const old_read = v.pending.items[0].req;
        const old_rich = v.pending.items[1].req;

        host.semanticNavigationStarted(v);
        try std.testing.expectEqual(@as(usize, 2), v.pending.items.len);
        try std.testing.expect(v.pending.items[0].rearm and v.pending.items[0].req != old_read);
        try std.testing.expect(v.pending.items[1].rearm and v.pending.items[1].req != old_rich);
        try std.testing.expectEqual(@as(usize, 1), out.pending());
        const frame = proto.Reader.init(out.front().?.bytes);
        var reader = frame;
        const failed = (try reader.next()).?;
        try std.testing.expectEqual(proto.Tag.sem_act_result, failed.tag);
        try std.testing.expectEqual(@as(u8, 0), (try proto.decode(proto.SemActResult, failed.payload)).ok);

        const new_read = v.pending.items[0].req;
        try std.testing.expect(host.takePending(v, old_read) == null);
        try std.testing.expect(host.takePending(v, new_read) != null);
        while (v.pending.pop()) |p| host.freePending(p);
    }

    test "semantic result envelopes keep the client request id" {
        const gpa = std.testing.allocator;
        var out = proto.Outbox.init(gpa);
        defer out.deinit();
        var host = Host.init(gpa, &out);
        defer host.webext.deinit();
        host.active_sem_request = 77;
        host.post(proto.SemActResult{ .view = 4, .id = 9, .ok = 1, .msg = "ok" });
        var reader = proto.Reader.init(out.front().?.bytes);
        const frame = (try reader.next()).?;
        try std.testing.expectEqual(proto.Tag.sem_result, frame.tag);
        const result = try proto.decode(proto.SemResult, frame.payload);
        try std.testing.expectEqual(@as(u32, 77), result.request);
        try std.testing.expectEqual(@intFromEnum(proto.Tag.sem_act_result), result.kind);
        const inner = try proto.decode(proto.SemActResult, result.payload.s);
        try std.testing.expectEqual(@as(u32, 9), inner.id);
        try std.testing.expectEqualStrings("ok", inner.msg);
    }

    test "semantic stop exits loading and frees rearmed requests" {
        const gpa = std.testing.allocator;
        var out = proto.Outbox.init(gpa);
        defer out.deinit();
        var host = Host.init(gpa, &out);
        defer host.webext.deinit();
        var v = View{
            .id = 7,
            .w = 1,
            .h = 1,
            .scale_x1000 = 1000,
            .pw = 1,
            .ph = 1,
            .sem = semantic.View.init(gpa),
            .sem_nav = .{ .loading = true, .waiting_load_start = true },
        };
        defer v.pending.deinit(gpa);
        defer v.sem.deinit();
        const arg = try gpa.dupe(u8, "owned");
        try v.pending.append(gpa, .{ .req = 1, .kind = .read_ids, .client_request = 15, .rearm = true, .arg = arg });
        host.semanticStopped(&v);
        try std.testing.expect(!v.sem_nav.loading);
        try std.testing.expect(!v.sem_nav.waiting_load_start);
        try std.testing.expectEqual(@as(usize, 0), v.pending.items.len);
        var reader = proto.Reader.init(out.front().?.bytes);
        const result = try proto.decode(proto.SemResult, (try reader.next()).?.payload);
        try std.testing.expectEqual(@as(u32, 15), result.request);
        try std.testing.expectEqual(@intFromEnum(proto.Tag.sem_read_ids_result), result.kind);
    }

    pub fn semSnapshot(self: *Host, req: proto.SemSnapshotReq) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            // A discarded view has no page to walk, and a request that
            // simply went unanswered would hang every client that waits
            // for its reply frame. Answer, and say what to do about it.
            self.post(proto.SemSnapshot{
                .view = v.id,
                .doc_gen = 0,
                .rev = 0,
                .kind = @intFromEnum(proto.SnapKind.full),
                .payload = .{ .s = discarded_msg },
            });
            return;
        }
        v.sem_detail = req.detail;
        v.sem_want_observer = true;
        const rid = try self.pushPending(v, .{
            .req = nextReq(v),
            .kind = .snapshot,
            .mode = req.mode,
            .detail = req.detail,
            .scope = req.scope,
            .rearm = v.sem_nav.loading,
        });
        if (v.sem_nav.loading) return;
        var buf: [96]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &buf,
            "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
            .{ rid, req.detail },
        ) catch return;
        self.sendScript(v, cmd);
        if (!v.sem_observing) {
            v.sem_observing = true;
            self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
        }
    }

    /// Dispatch one request-id envelope through the existing semantic
    /// handlers. The inner payload is byte-for-byte the legacy frame's
    /// payload; only the outer tags are append-only additions.
    /// A view id the dispatching CLIENT encoded inside an opaque
    /// payload — where the socket edge could not translate it. Maps it
    /// into the engine's namespace through the router; identity without
    /// one, or outside a dispatch.
    fn mapDispatchView(self: *Host, id: u32) u32 {
        const rt = self.router orelse return id;
        if (self.dispatch_conn == 0) return id;
        return rt.mapView(rt.ctx, self.dispatch_conn, id);
    }

    /// The inner frame of a `sem_request` was encoded by the CLIENT, so
    /// its view id is in the client's namespace — the socket edge only
    /// translates top-level frames. Map it here, through the router.
    fn innerReq(self: *Host, comptime T: type, payload: []const u8) !T {
        var req = try proto.decode(T, payload);
        req.view = self.mapDispatchView(req.view);
        return req;
    }

    pub fn semRequest(self: *Host, req: proto.SemRequest) !void {
        if (req.request == 0) return;
        const old_request = self.active_sem_request;
        self.active_sem_request = req.request;
        defer self.active_sem_request = old_request;
        switch (@as(proto.Tag, @enumFromInt(req.kind))) {
            .sem_snapshot_req => try self.semSnapshot(try self.innerReq(proto.SemSnapshotReq, req.payload.s)),
            .sem_act => try self.semAct(try self.innerReq(proto.SemAction, req.payload.s)),
            .sem_expand => try self.semExpand(try self.innerReq(proto.SemExpand, req.payload.s)),
            .sem_query => try self.semQuery(try self.innerReq(proto.SemQueryReq, req.payload.s)),
            .sem_read => try self.semRead(try self.innerReq(proto.SemRead, req.payload.s)),
            .sem_read_ids => try self.semReadIds(try self.innerReq(proto.SemReadIds, req.payload.s)),
            .sem_act_guarded => try self.semActGuarded(try self.innerReq(proto.SemActGuarded, req.payload.s)),
            .sem_eval => try self.semEval(try self.innerReq(proto.SemEval, req.payload.s)),
            else => {},
        }
    }

    pub fn semAct(self: *Host, req: proto.SemAction) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = discarded_msg });
            return;
        }
        if (v.sem_nav.loading) {
            self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = "semantic action unavailable while the page is navigating (web_navigate action:stop clears a stuck one)" });
            return;
        }
        const eid = v.sem.eidFor(req.id);
        if (eid == 0) {
            self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = v.sem.unknownReason(req.id) });
            return;
        }
        var buf: [512]u8 = undefined;
        switch (@as(proto.SemAct, @enumFromInt(req.action))) {
            .click, .hover => {
                const kind: Pending.Kind = if (req.action == @intFromEnum(proto.SemAct.click)) .click else .hover;
                const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = kind, .sid = req.id });
                const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"locate\",\"req\":{d},\"eid\":{d}}}", .{ rid, eid }) catch return;
                self.sendScript(v, cmd);
            },
            .focus, .scroll_into_view => {
                const what = if (req.action == @intFromEnum(proto.SemAct.focus)) "focus" else "scroll";
                const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .act, .sid = req.id });
                const cmd = std.fmt.bufPrint(
                    &buf,
                    "{{\"op\":\"act\",\"req\":{d},\"eid\":{d},\"action\":\"{s}\"}}",
                    .{ rid, eid, what },
                ) catch return;
                self.sendScript(v, cmd);
            },
            .set_value => {
                const arg = try self.gpa.dupe(u8, req.arg);
                errdefer self.gpa.free(arg);
                const rid = try self.pushPending(v, .{
                    .req = nextReq(v),
                    .kind = .set_value,
                    .sid = req.id,
                    .arg = arg,
                });
                var cmd: std.Io.Writer.Allocating = .init(self.gpa);
                defer cmd.deinit();
                cmd.writer.print("{{\"op\":\"setvalue\",\"req\":{d},\"eid\":{d},\"arg\":", .{ rid, eid }) catch return;
                jsonStr(&cmd.writer, req.arg) catch return;
                cmd.writer.writeByte('}') catch return;
                self.sendScript(v, cmd.written());
            },
            _ => self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = "unknown action" }),
        }
    }

    /// Refresh the live tree before resolving a reader id, then require
    /// the exact document generation and revision returned by the read.
    pub fn semActGuarded(self: *Host, req: proto.SemActGuarded) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = discarded_msg });
            return;
        }
        if (v.sem_nav.loading) {
            self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = stale_reader_msg });
            return;
        }
        const arg = try self.gpa.dupe(u8, req.arg);
        errdefer self.gpa.free(arg);
        const rid = try self.pushPending(v, .{
            .req = nextReq(v),
            .kind = .guarded_act,
            .sid = req.id,
            .mode = req.action,
            .scope = req.doc_gen,
            .off = req.rev,
            .guard = req.guard,
            .guarded = true,
            .arg = arg,
        });
        var buf: [96]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &buf,
            "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
            .{ rid, v.sem_detail },
        ) catch return;
        self.sendScript(v, cmd);
    }

    pub fn semExpand(self: *Host, req: proto.SemExpand) !void {
        const v = self.find(req.view) orelse return;
        // A discarded view's shadow tree is empty, so the unknown-id
        // answer below would already fire; saying so explicitly keeps
        // "no text" from reading like a page that had none.
        if (v.discarded) {
            self.post(proto.SemExpandResult{
                .view = v.id,
                .id = req.id,
                .off = req.off,
                .text = discarded_msg,
            });
            return;
        }
        if (v.sem_nav.loading) {
            self.post(proto.SemExpandResult{ .view = v.id, .id = req.id, .off = req.off, .text = "semantic expansion unavailable while the page is navigating (web_navigate action:stop clears a stuck one)" });
            return;
        }
        const eid = v.sem.eidFor(req.id);
        if (eid == 0) {
            self.post(proto.SemExpandResult{ .view = v.id, .id = req.id, .off = req.off, .text = "" });
            return;
        }
        const rid = try self.pushPending(v, .{
            .req = nextReq(v),
            .kind = .expand,
            .sid = req.id,
            .off = req.off,
        });
        var buf: [160]u8 = undefined;
        const cmd = std.fmt.bufPrint(
            &buf,
            "{{\"op\":\"expand\",\"req\":{d},\"eid\":{d},\"off\":{d},\"len\":{d}}}",
            .{ rid, eid, req.off, @min(req.len, max_expand) },
        ) catch return;
        self.sendScript(v, cmd);
    }

    /// Queries are answered from the shadow tree, never by a fresh DOM
    /// walk: a spot-check must not cost a traversal and must not invent
    /// ids the client has never been told about. The ONE exception is
    /// the `visible` (link hints) kind, whose whole answer is rects: it
    /// solicits a walk first, because a scroll moves every box without
    /// a single mutation the observer could have folded.
    pub fn semQuery(self: *Host, req: proto.SemQueryReq) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = discarded_msg } });
            return;
        }
        if (v.sem_nav.loading and req.kind != @intFromEnum(proto.SemQuery.visible)) {
            self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = "semantic query unavailable while the page is navigating (web_navigate action:stop clears a stuck one)" } });
            return;
        }
        if (req.kind == @intFromEnum(proto.SemQuery.visible)) {
            const arg = try self.gpa.dupe(u8, req.arg);
            errdefer self.gpa.free(arg);
            const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .hints, .rearm = v.sem_nav.loading, .arg = arg });
            if (v.sem_nav.loading) return;
            var buf: [96]u8 = undefined;
            const cmd = std.fmt.bufPrint(
                &buf,
                "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
                .{ rid, v.sem_detail },
            ) catch return;
            self.sendScript(v, cmd);
            return;
        }
        if (!v.sem.has_tree) {
            // No walk has happened yet (the view was opened with its
            // first snapshot skipped): solicit one and answer from it,
            // so act-by-name does not cost the caller a snapshot turn.
            const arg = try self.gpa.dupe(u8, req.arg);
            errdefer self.gpa.free(arg);
            const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .query, .mode = req.kind, .rearm = v.sem_nav.loading, .arg = arg });
            if (v.sem_nav.loading) return;
            var buf: [96]u8 = undefined;
            const cmd = std.fmt.bufPrint(
                &buf,
                "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
                .{ rid, v.sem_detail },
            ) catch return;
            self.sendScript(v, cmd);
            return;
        }
        const text = v.sem.query(req.kind, req.arg) catch return;
        defer self.gpa.free(text);
        self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = text } });
    }

    /// Evaluate script in the page's main world and answer with the
    /// serialized result. The REPLY rides the authenticated bridge, so
    /// a page cannot forge it; the code itself runs where page script
    /// runs, so the RESULT is page-authored data like any other.
    pub fn semEval(self: *Host, req: proto.SemEval) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            self.post(proto.SemEvalResult{
                .view = v.id,
                .ok = 0,
                .json = .{ .s = "{\"error\":\"" ++ discarded_msg ++ "\"}" },
            });
            return;
        }
        if (v.sem_nav.loading) {
            self.post(proto.SemEvalResult{ .view = v.id, .ok = 0, .json = .{ .s = "{\"error\":\"semantic evaluation unavailable while the page is navigating (web_navigate action:stop clears a stuck one)\"}" } });
            return;
        }
        // The code is kept with the request: a page whose CSP blocks
        // eval() answers with a `csp` marker, and the retry re-sends
        // these same bytes spliced into the command script instead.
        const code_copy = self.gpa.dupe(u8, req.code.s) catch return;
        const want_await = req.flags & proto.eval_flag_await != 0;
        const timeout: u32 = @min(req.timeout_ms, 120_000);
        const rid = self.pushPending(v, .{
            .req = nextReq(v),
            .kind = .eval,
            .arg = code_copy,
            .eval_await = want_await,
            .eval_timeout_ms = timeout,
        }) catch {
            self.gpa.free(code_copy);
            return;
        };
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        cmd.writer.print("{{\"op\":\"eval\",\"req\":{d},\"await\":{s},\"timeout\":{d},\"code\":", .{
            rid,
            if (want_await) "true" else "false",
            timeout,
        }) catch return;
        jsonStr(&cmd.writer, req.code.s) catch return;
        cmd.writer.writeByte('}') catch return;
        self.sendScript(v, cmd.written());
    }

    /// The CSP lane of `sem_eval`: the code compiled INTO the command
    /// script as a function literal, which `execute_java_script` runs
    /// regardless of the page's CSP - only eval()-of-a-string is
    /// governed. Restricted to a single expression by construction; the
    /// `evalprobe` sent right behind it turns a parse failure (the
    /// whole script dies, nothing replies) into a clear answer instead
    /// of a 120s timeout.
    fn sendEvalSpliced(self: *Host, v: *View, rid: u32, code: []const u8, want_await: bool, timeout: u32) void {
        if (!sem_secret.ok) return;
        const b = v.browser orelse return;
        const gf = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = gf(b) orelse return;
        defer release(&frame.base);
        const slot: []const u8 = &sem_secret.slot;
        var script: std.Io.Writer.Allocating = .init(self.gpa);
        defer script.deinit();
        script.writer.print(
            "window[\"{s}\"]&&window[\"{s}\"](({{\"op\":\"eval\",\"req\":{d},\"await\":{s},\"timeout\":{d},\"fn\":function(){{return(\n",
            .{ slot, slot, rid, if (want_await) "true" else "false", timeout },
        ) catch return;
        script.writer.writeAll(code) catch return;
        script.writer.print("\n)}}}}),{d})", .{v.sem_nav.generation}) catch return;
        runJs(frame, script.written());
        var probe: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&probe, "{{\"op\":\"evalprobe\",\"req\":{d}}}", .{rid}) catch return;
        self.sendScriptToFrameGen(frame, cmd, v.sem_nav.generation);
    }

    pub fn semRead(self: *Host, req: proto.SemRead) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            self.post(proto.SemReadResult{ .view = v.id, .markdown = .{ .s = discarded_msg } });
            return;
        }
        const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .read, .rearm = v.sem_nav.loading });
        if (v.sem_nav.loading) return;
        var buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d}}}", .{rid}) catch return;
        self.sendScript(v, cmd);
    }

    pub fn semReadIds(self: *Host, req: proto.SemReadIds) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            self.post(proto.SemReadIdsResult{
                .view = v.id,
                .doc_gen = 0,
                .rev = 0,
                .markdown = .{ .s = discarded_msg },
                .entities = &.{},
            });
            return;
        }
        v.sem_want_observer = true;
        const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .read_ids, .rearm = v.sem_nav.loading });
        if (v.sem_nav.loading) return;
        var buf: [72]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d},\"ids\":true}}", .{rid}) catch return;
        self.sendScript(v, cmd);
        if (!v.sem_observing) {
            v.sem_observing = true;
            self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
        }
    }

    /// Re-arm a fresh document: a navigation builds a new V8 context,
    /// so the observer and the first walk have to be asked for again.
    ///
    /// A snapshot REQUEST sent into the dying context would never be
    /// answered (its walk dies with the context), so pending snapshot
    /// requests are re-issued here with their original ids — without
    /// this, a client that snapshots right after navigating times out.
    fn semRearm(self: *Host, v: *View) void {
        v.sem_nav.rearmed();
        v.sem_observing = v.sem_want_observer;
        if (v.sem_observing) self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
        var buf: [112]u8 = undefined;
        var reissued = false;
        for (v.pending.items) |*p| {
            if (!p.rearm or p.nav_gen != v.sem_nav.generation) continue;
            p.rearm = false;
            const cmd = switch (p.kind) {
                .snapshot, .hints, .query => std.fmt.bufPrint(
                    &buf,
                    "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
                    .{ p.req, if (p.kind == .snapshot) p.detail else v.sem_detail },
                ) catch continue,
                .read => std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d}}}", .{p.req}) catch continue,
                .read_ids => std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d},\"ids\":true}}", .{p.req}) catch continue,
                else => continue,
            };
            self.sendScript(v, cmd);
            reissued = true;
        }
        if (reissued or !v.sem_observing) return;
        // No request in flight: an unsolicited walk keeps the live tree
        // (queries, action routing) following the navigation.
        const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"snapshot\",\"req\":0,\"detail\":{d}}}", .{v.sem_detail}) catch return;
        self.sendScript(v, cmd);
    }

    /// Leave the loading state after an explicit stop. Work queued for
    /// the aborted document cannot be reissued safely; answer it now and
    /// solicit a fresh unsolicited walk for later ordinary operations.
    fn semanticStopped(self: *Host, v: *View) void {
        v.sem_nav.rearmed();
        v.sem_context_doc = 0;
        v.sem.invalidateDocument();
        var i: usize = 0;
        while (i < v.pending.items.len) {
            if (!v.pending.items[i].rearm) {
                i += 1;
                continue;
            }
            const p = v.pending.orderedRemove(i);
            self.failPending(v, p, "semantic request canceled because loading was stopped");
        }
        if (v.sem_want_observer) {
            v.sem_observing = true;
            self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
            var buf: [96]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"snapshot\",\"req\":0,\"detail\":{d}}}", .{v.sem_detail}) catch return;
            self.sendScript(v, cmd);
        }
    }

    /// One reply from the injected script: `<nonce><json>`.
    ///
    /// The nonce gate is the whole reason the render side has a secret.
    /// A page cannot reach the native reply function, but if it ever
    /// did, an unprefixed message buys it nothing: everything below is
    /// reached only by a message that carries the browser's own nonce,
    /// and only for a request id the browser is actually waiting on.
    fn onScriptMessage(self: *Host, v: *View, raw: []const u8) void {
        if (!sem_secret.ok) return;
        if (raw.len <= sem_secret.nonce.len) return;
        if (!secretEql(raw[0..sem_secret.nonce.len], &sem_secret.nonce)) return;
        const json = raw[sem_secret.nonce.len..];
        const Head = struct { op: []const u8 = "", req: u32 = 0, doc: u32 = 0, gen: u32 = 0 };
        const head = std.json.parseFromSlice(Head, self.gpa, json, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer head.deinit();
        const op = head.value.op;
        const rid = head.value.req;
        // WebExtensions traffic rides the same authenticated channel;
        // route every `ext-*` op to the webext handler.
        if (op.len > 4 and std.mem.eql(u8, op[0..4], "ext-")) {
            self.onExtMessage(v, op, json);
            return;
        }
        if (head.value.gen != v.sem_nav.generation) return;
        if (head.value.doc == 0) return;
        if (v.sem_context_doc == 0) {
            v.sem_context_doc = head.value.doc;
        } else if (head.value.doc != v.sem_context_doc) return;
        if (rid != 0) {
            const p = self.pendingFor(v, rid) orelse return;
            if (p.nav_gen != v.sem_nav.generation) return;
        }
        if (std.mem.eql(u8, op, "tree")) {
            self.onTree(v, rid, json);
            return;
        }
        var p = self.takePending(v, rid) orelse return;
        defer self.freePending(p);
        const old_request = self.active_sem_request;
        self.active_sem_request = p.client_request;
        defer self.active_sem_request = old_request;

        if (std.mem.eql(u8, op, "rect")) {
            self.onRect(v, &p, json);
        } else if (std.mem.eql(u8, op, "optrect")) {
            self.onOptionRect(v, &p, json);
        } else if (std.mem.eql(u8, op, "eval")) {
            const E = struct { ok: u8 = 0, csp: u8 = 0, json: []const u8 = "" };
            const e = std.json.parseFromSlice(E, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
            defer e.deinit();
            // eval() refused by the page's CSP: re-send the same code
            // spliced into the command script (single-shot), and only
            // answer the client from THAT attempt.
            if (e.value.ok == 0 and e.value.csp == 1 and !p.eval_retried and p.arg.len > 0) {
                var again = p;
                again.eval_retried = true;
                const code = again.arg;
                if (self.pushPending(v, again)) |_| {
                    p.arg = &.{}; // the re-queued copy owns the code now
                    self.sendEvalSpliced(v, again.req, code, again.eval_await, again.eval_timeout_ms);
                    return;
                } else |_| {}
            }
            const rewritten = self.rewriteNodeRefs(v, e.value.json) catch null;
            defer if (rewritten) |r| self.gpa.free(r);
            self.post(proto.SemEvalResult{
                .view = v.id,
                .ok = e.value.ok,
                .json = .{ .s = rewritten orelse e.value.json },
            });
        } else if (std.mem.eql(u8, op, "setvalue")) {
            self.onSetValue(v, &p, json);
        } else if (std.mem.eql(u8, op, "ack")) {
            const Ack = struct { ok: u8 = 0, msg: []const u8 = "", note: []const u8 = "" };
            const a = std.json.parseFromSlice(Ack, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
            defer a.deinit();
            var buf: [512]u8 = undefined;
            const msg = switch (p.kind) {
                .commit => if (a.value.note.len > 0)
                    std.fmt.bufPrint(&buf, "set-value ok, value=\"{s}\" ({s})", .{
                        a.value.msg[0..@min(a.value.msg.len, 128)],
                        a.value.note[0..@min(a.value.note.len, 160)],
                    }) catch a.value.msg
                else
                    std.fmt.bufPrint(&buf, "set-value ok, value=\"{s}\"", .{
                        a.value.msg[0..@min(a.value.msg.len, 128)],
                    }) catch a.value.msg,
                .choose_done => std.fmt.bufPrint(
                    &buf,
                    "custom dropdown: clicked option \"{s}\" (trusted); control now \"{s}\"",
                    .{ p.arg[0..@min(p.arg.len, 128)], a.value.msg[0..@min(a.value.msg.len, 128)] },
                ) catch a.value.msg,
                else => a.value.msg,
            };
            self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = a.value.ok, .msg = msg });
        } else if (std.mem.eql(u8, op, "text")) {
            const Txt = struct { off: u32 = 0, text: []const u8 = "" };
            const t = std.json.parseFromSlice(Txt, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
            defer t.deinit();
            self.post(proto.SemExpandResult{
                .view = v.id,
                .id = p.sid,
                .off = t.value.off,
                .text = t.value.text[0..@min(t.value.text.len, max_expand)],
            });
        } else if (std.mem.eql(u8, op, "markdown") and p.kind == .read_ids) {
            const tree = semantic.parseTree(self.gpa, json) catch return;
            defer tree.deinit();
            v.sem.apply(tree.value) catch return;
            const parsed = std.json.parseFromSlice(semantic.InReader, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
            defer parsed.deinit();
            const result = v.sem.readerResult(self.gpa, parsed.value) catch return;
            defer self.gpa.free(result.entities);
            var entities = self.gpa.alloc(proto.ReaderEntity, result.entities.len) catch return;
            defer self.gpa.free(entities);
            for (result.entities, 0..) |entity, i| {
                entities[i] = .{ .id = entity.id, .guard = entity.guard, .kind = entity.kind, .text = entity.text, .url = entity.url };
            }
            self.post(proto.SemReadIdsResult{
                .view = v.id,
                .doc_gen = result.doc_gen,
                .rev = result.rev,
                .markdown = .{ .s = result.markdown },
                .entities = entities,
            });
        } else if (std.mem.eql(u8, op, "markdown")) {
            const Md = struct { md: []const u8 = "" };
            const m = std.json.parseFromSlice(Md, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
            defer m.deinit();
            self.post(proto.SemReadResult{ .view = v.id, .markdown = .{ .s = m.value.md } });
        }
    }

    /// A full DOM walk, folded into the LIVE shadow tree either way. An
    /// unsolicited batch (req 0, the MutationObserver) posts NOTHING —
    /// the client is answered with one coalesced delta when it next
    /// asks (semantic.View.consume), so churn that appeared and
    /// vanished in between is never replayed at it.
    fn onTree(self: *Host, v: *View, rid: u32, json: []const u8) void {
        const pend = self.takePending(v, rid);
        // A named request id that nothing is waiting on was either
        // answered already or never asked for; only the observer's
        // unsolicited id 0 may arrive without a pending entry.
        if (rid != 0 and pend == null) return;
        defer if (pend) |p| self.freePending(p);
        const old_request = self.active_sem_request;
        self.active_sem_request = if (pend) |p| p.client_request else 0;
        defer self.active_sem_request = old_request;
        const parsed = semantic.parseTree(self.gpa, json) catch return;
        defer parsed.deinit();
        v.sem.apply(parsed.value) catch return;
        const p = pend orelse return;

        if (p.kind == .guarded_act) {
            if (!v.sem.revisionMatches(p.scope, p.off) or v.sem.actionGuard(p.sid) != p.guard) {
                self.post(proto.SemActResult{
                    .view = v.id,
                    .id = p.sid,
                    .ok = 0,
                    .msg = "stale reader id: the page changed since web_read; read the page again",
                });
                return;
            }
            self.semActAfterGuard(v, p);
            return;
        }

        if (p.kind == .query) {
            const text = v.sem.query(p.mode, p.arg) catch return;
            defer self.gpa.free(text);
            self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = text } });
            return;
        }

        if (p.kind == .hints) {
            // Link hints: the walk just folded, so the live tree's rects
            // are current. Renders from the live tree and does NOT
            // consume the base — a hints pass must not eat the delta a
            // real snapshot request is owed.
            var vw: i32 = std.math.maxInt(i32);
            var vh: i32 = std.math.maxInt(i32);
            var it = std.mem.tokenizeScalar(u8, p.arg, ' ');
            if (it.next()) |s| vw = std.fmt.parseInt(i32, s, 10) catch vw;
            if (it.next()) |s| vh = std.fmt.parseInt(i32, s, 10) catch vh;
            const text = v.sem.renderHints(vw, vh) catch return;
            defer self.gpa.free(text);
            self.post(proto.SemQueryResult{ .view = v.id, .payload = .{ .s = text } });
            return;
        }

        if (p.scope != 0) {
            // A scoped snapshot is one subtree rendered in full; it
            // advances the base for THAT subtree only (the caller did
            // not see the rest of the page).
            const scoped = v.sem.consumeScoped(p.scope) catch return;
            defer self.gpa.free(scoped);
            self.post(proto.SemSnapshot{
                .view = v.id,
                .doc_gen = v.sem.doc_gen,
                .rev = v.sem.rev,
                .kind = @intFromEnum(proto.SnapKind.full),
                .payload = .{ .s = scoped },
            });
            return;
        }
        if (p.mode == @intFromEnum(proto.SnapMode.peek)) {
            // A probe: the walk folded into the live tree, the answer
            // is the revision, and the base is untouched.
            self.post(proto.SemSnapshot{
                .view = v.id,
                .doc_gen = v.sem.doc_gen,
                .rev = v.sem.rev,
                .kind = @intFromEnum(proto.SnapKind.delta),
                .payload = .{ .s = "" },
            });
            return;
        }
        const mode: semantic.Mode = switch (p.mode) {
            @intFromEnum(proto.SnapMode.full) => .full,
            @intFromEnum(proto.SnapMode.history) => .history,
            else => .auto,
        };
        const up = v.sem.consume(mode) catch return;
        defer self.gpa.free(up.text);
        self.post(proto.SemSnapshot{
            .view = v.id,
            .doc_gen = up.doc_gen,
            .rev = up.rev,
            .kind = @intFromEnum(up.kind),
            .payload = .{ .s = up.text },
        });
    }

    /// Continue a guarded action without dropping its identity fence.
    /// Every second-phase request is marked guarded, so navigation
    /// before the trusted input is delivered fails it explicitly.
    fn semActAfterGuard(self: *Host, v: *View, p: Pending) void {
        const eid = v.sem.eidFor(p.sid);
        if (eid == 0) {
            self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = stale_reader_msg });
            return;
        }
        var buf: [512]u8 = undefined;
        switch (@as(proto.SemAct, @enumFromInt(p.mode))) {
            .click, .hover => {
                const kind: Pending.Kind = if (p.mode == @intFromEnum(proto.SemAct.click)) .click else .hover;
                const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = kind, .sid = p.sid, .guarded = true }) catch return;
                const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"locate\",\"req\":{d},\"eid\":{d}}}", .{ rid, eid }) catch return;
                self.sendScript(v, cmd);
            },
            .focus, .scroll_into_view => {
                const what = if (p.mode == @intFromEnum(proto.SemAct.focus)) "focus" else "scroll";
                const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = .act, .sid = p.sid, .guarded = true }) catch return;
                const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"act\",\"req\":{d},\"eid\":{d},\"action\":\"{s}\"}}", .{ rid, eid, what }) catch return;
                self.sendScript(v, cmd);
            },
            .set_value => {
                const arg = self.gpa.dupe(u8, p.arg) catch return;
                const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = .set_value, .sid = p.sid, .guarded = true, .arg = arg }) catch {
                    self.gpa.free(arg);
                    return;
                };
                var cmd: std.Io.Writer.Allocating = .init(self.gpa);
                defer cmd.deinit();
                cmd.writer.print("{{\"op\":\"setvalue\",\"req\":{d},\"eid\":{d},\"arg\":", .{ rid, eid }) catch return;
                jsonStr(&cmd.writer, p.arg) catch return;
                cmd.writer.writeByte('}') catch return;
                self.sendScript(v, cmd.written());
            },
            _ => self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = "unknown action" }),
        }
    }

    /// The script located an element: the click or hover is synthesized
    /// HERE, through the same input path a human uses, which is the
    /// whole reason `element.click()` is not an option.
    fn onRect(self: *Host, v: *View, p: *Pending, json: []const u8) void {
        const R = struct { ok: u8 = 0, x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };
        const r = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer r.deinit();
        if (r.value.ok == 0) {
            self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = if (p.guarded) stale_reader_msg else "element has no box" });
            return;
        }
        const pt = viewPoint(v, r.value.x, r.value.y);
        var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = 0 };
        withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) });
        // Echo WHAT the id resolved to, not only where the pointer
        // went: a mis-resolved id is invisible in bare coordinates.
        var target_buf: [140]u8 = undefined;
        const target: []const u8 = if (v.sem.describe(p.sid)) |d|
            std.fmt.bufPrint(&target_buf, "on {s} \"{s}\" ", .{ d.role, d.name[0..@min(d.name.len, 96)] }) catch ""
        else
            "";
        // ...and WHERE: with N identical "Edit" buttons the target alone
        // is the same string for the wrong row and the right one.
        var ctx_buf: [160]u8 = undefined;
        const ctx: []const u8 = if (v.sem.describeContext(p.sid)) |cx|
            std.fmt.bufPrint(&ctx_buf, "in {s} \"{s}\" ", .{ cx.role, cx.name[0..@min(cx.name.len, 120)] }) catch ""
        else
            "";
        var buf: [400]u8 = undefined;
        if (p.kind == .hover) {
            const msg = std.fmt.bufPrint(&buf, "hover {s}{s}at {d},{d}", .{ target, ctx, r.value.x, r.value.y }) catch "hover";
            self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 1, .msg = msg });
            return;
        }
        withHostArgs(v, setFocus, .{@as(c_int, 1)});
        withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 0), @as(c_int, 1) });
        withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });
        const msg = std.fmt.bufPrint(&buf, "click {s}{s}at {d},{d}", .{ target, ctx, r.value.x, r.value.y }) catch "click";
        self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 1, .msg = msg });
    }

    /// A custom dropdown's option, located after the trusted click that
    /// opened the list: clicking it is trusted too, which is the whole
    /// reason this is a round trip instead of `option.click()`.
    fn onOptionRect(self: *Host, v: *View, p: *Pending, json: []const u8) void {
        const R = struct {
            ok: u8 = 0,
            x: i32 = 0,
            y: i32 = 0,
            text: []const u8 = "",
            seen: []const u8 = "",
        };
        const r = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer r.deinit();
        var buf: [512]u8 = undefined;
        if (r.value.ok == 0) {
            const msg = std.fmt.bufPrint(
                &buf,
                "no option matched \"{s}\" in the opened dropdown; options seen: {s}",
                .{ p.arg[0..@min(p.arg.len, 96)], r.value.seen[0..@min(r.value.seen.len, 300)] },
            ) catch "no matching option in the opened dropdown";
            self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = msg });
            return;
        }
        const pt = viewPoint(v, r.value.x, r.value.y);
        var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = 0 };
        withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) });
        withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 0), @as(c_int, 1) });
        withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });

        const picked = self.gpa.dupe(u8, r.value.text) catch return;
        const eid = v.sem.eidFor(p.sid);
        const rid = self.pushPending(v, .{
            .req = nextReq(v),
            .kind = .choose_done,
            .sid = p.sid,
            .guarded = p.guarded,
            .arg = picked,
        }) catch {
            self.gpa.free(picked);
            return;
        };
        const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"chosen\",\"req\":{d},\"eid\":{d}}}", .{ rid, eid }) catch return;
        self.sendScript(v, cmd);
    }

    /// Replace the script's `{"__kind":"node","eid":N,...}` markers with
    /// PROTOCOL-facing `{"semantic_id":S,...}`, so an eval result that
    /// returned an element can be fed straight back into `sem_act`. An
    /// element the current tree does not hold answers null.
    fn rewriteNodeRefs(self: *Host, v: *View, json: []const u8) !?[]u8 {
        if (std.mem.indexOf(u8, json, "\"__kind\":\"node\"") == null) return null;
        const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, json, .{}) catch return null;
        defer parsed.deinit();
        var root = parsed.value;
        try rewriteValue(v, parsed.arena.allocator(), &root);
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        errdefer aw.deinit();
        try std.json.Stringify.value(root, .{}, &aw.writer);
        return try aw.toOwnedSlice();
    }

    fn rewriteValue(v: *View, arena: std.mem.Allocator, node: *std.json.Value) !void {
        switch (node.*) {
            .array => |*arr| for (arr.items) |*item| try rewriteValue(v, arena, item),
            .object => |*obj| {
                const kind = obj.get("__kind");
                const eid_v = obj.get("eid");
                if (kind != null and kind.? == .string and std.mem.eql(u8, kind.?.string, "node") and
                    eid_v != null and eid_v.? == .integer)
                {
                    const eid: u32 = if (eid_v.?.integer > 0) @intCast(eid_v.?.integer) else 0;
                    const sid = if (eid != 0) v.sem.sidFor(eid) else 0;
                    _ = obj.orderedRemove("__kind");
                    _ = obj.orderedRemove("eid");
                    try obj.put(arena, "semantic_id", if (sid != 0)
                        std.json.Value{ .integer = @intCast(sid) }
                    else
                        std.json.Value{ .null = {} });
                    if (sid == 0) try obj.put(
                        arena,
                        "note",
                        .{ .string = "this element is not in the current snapshot; take a web_snapshot to act on it" },
                    );
                    // The row it sits in, so a caller can fall back to
                    // web_act within_text instead of an index when the
                    // page re-renders the element before the act.
                    if (sid != 0) if (v.sem.describeContext(sid)) |cx| {
                        const ctx = try std.fmt.allocPrint(arena, "{s} \"{s}\"", .{ cx.role, cx.name });
                        try obj.put(arena, "context", .{ .string = ctx });
                    };
                    return;
                }
                var it = obj.iterator();
                while (it.next()) |entry| try rewriteValue(v, arena, entry.value_ptr);
            },
            else => {},
        }
    }

    /// Set-value: a typeable field is TYPED into with real key events;
    /// a native select (including one in an open shadow root) picks the
    /// matching option; a custom/ARIA dropdown is opened with a trusted
    /// click here and its option picked in `onOptionRect`; anything
    /// else can only be assigned from script, and the reply says so
    /// rather than pretending.
    fn onSetValue(self: *Host, v: *View, p: *Pending, json: []const u8) void {
        const S = struct {
            ok: u8 = 0,
            typeable: u8 = 0,
            custom: u8 = 0,
            x: i32 = 0,
            y: i32 = 0,
            msg: []const u8 = "",
        };
        const s = std.json.parseFromSlice(S, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer s.deinit();
        if (s.value.ok == 0) {
            self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = s.value.msg });
            return;
        }
        if (s.value.custom != 0) {
            // Open the list with a real click, then go looking for the
            // option; both clicks are trusted, which is what a custom
            // dropdown's own key handlers need to see.
            const pt = viewPoint(v, s.value.x, s.value.y);
            var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = 0 };
            withHostArgs(v, setFocus, .{@as(c_int, 1)});
            withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) });
            withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 0), @as(c_int, 1) });
            withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });
            const want = self.gpa.dupe(u8, p.arg) catch return;
            const rid = self.pushPending(v, .{
                .req = nextReq(v),
                .kind = .choose_pick,
                .sid = p.sid,
                .guarded = p.guarded,
                .arg = want,
            }) catch {
                self.gpa.free(want);
                return;
            };
            var cmd: std.Io.Writer.Allocating = .init(self.gpa);
            defer cmd.deinit();
            cmd.writer.print("{{\"op\":\"pickoption\",\"req\":{d},\"timeout\":4000,\"arg\":", .{rid}) catch return;
            jsonStr(&cmd.writer, p.arg) catch return;
            cmd.writer.writeByte('}') catch return;
            self.sendScript(v, cmd.written());
            return;
        }
        if (s.value.typeable == 0) {
            self.post(proto.SemActResult{
                .view = v.id,
                .id = p.sid,
                .ok = 1,
                .msg = if (s.value.msg.len > 0)
                    s.value.msg
                else
                    "set-value applied by script (element is not typeable; input+change dispatched)",
            });
            return;
        }
        withHostArgs(v, setFocus, .{@as(c_int, 1)});
        typeText(v, p.arg);
        const eid = v.sem.eidFor(p.sid);
        const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = .commit, .sid = p.sid, .guarded = p.guarded }) catch return;
        // The keystrokes are queued input and this script is an IPC to
        // the renderer: they race. `want` lets the commit read wait
        // (bounded) for the typed text to land before reporting.
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        cmd.writer.print("{{\"op\":\"commit\",\"req\":{d},\"eid\":{d},\"want\":", .{ rid, eid }) catch return;
        jsonStr(&cmd.writer, p.arg) catch return;
        cmd.writer.writeByte('}') catch return;
        self.sendScript(v, cmd.written());
    }

    // -- outbound ------------------------------------------------------

    /// Resolve where an event about `view_id` goes and which id-window
    /// base to strip so the frame reads in the owner's namespace again.
    /// Null = the owning connection is gone; drop the event, exactly as
    /// a dead socket would have.
    fn routeFor(self: *Host, view_id: u32) ?RouteTo {
        const rt = self.router orelse return .{ .out = self.out, .base = 0 };
        if (view_id == 0) {
            // A view-0 (engine-global) event answers the dispatching
            // connection when there is one.
            if (self.dispatch_conn != 0) {
                const out = rt.route(rt.ctx, self.dispatch_conn) orelse return null;
                return .{ .out = out, .base = 0 };
            }
            return null;
        }
        // Engine-minted ids (inspectors) carry no window; the owner is
        // on the view record. Client-minted ids encode it.
        const owner = if (view_id >= proto.DEVTOOLS_VIEW_BASE)
            (self.findAny(view_id) orelse return null).owner
        else
            view_id / proto.CONN_ID_WINDOW;
        const out = rt.route(rt.ctx, owner) orelse return null;
        return .{
            .out = out,
            .base = if (view_id >= proto.DEVTOOLS_VIEW_BASE) 0 else owner * proto.CONN_ID_WINDOW,
        };
    }

    /// Rewrite a frame's ids from the engine's global namespace into
    /// the owning connection's, per `routeFor`'s base. Every field
    /// carrying a client-minted view id is named here — `view`,
    /// `owner_view`, `popup_view` — plus the context id; a new frame
    /// field naming a view under a FOURTH name must be added or its
    /// events reach the client untranslated. Engine-minted ids
    /// (inspectors) pass through on purpose: the client learned them
    /// untranslated.
    fn toClientIds(value: anytype, base: u32) @TypeOf(value) {
        var v2 = value;
        if (base == 0) return v2;
        inline for (.{ "view", "owner_view", "popup_view" }) |f| {
            if (@hasField(@TypeOf(value), f)) {
                const id = @field(v2, f);
                if (id != 0 and id < proto.DEVTOOLS_VIEW_BASE) @field(v2, f) = id - base;
            }
        }
        if (@hasField(@TypeOf(value), "context")) {
            // Only ephemeral context ids are windowed; persisted ones
            // are the shared namespace and cross the wire verbatim
            // (subtracting base would underflow them).
            if (v2.context >= proto.EPHEMERAL_CTX_BASE) v2.context -= base;
        }
        return v2;
    }

    /// The view id a frame is routed by: `view`, else `owner_view`
    /// (the webext popup family), else null (viewless).
    fn routeKeyOf(value: anytype) ?u32 {
        const T = @TypeOf(value);
        if (@hasField(T, "view")) return @field(value, "view");
        if (@hasField(T, "owner_view")) return @field(value, "owner_view");
        return null;
    }

    /// Post an event, dropping it if the outbox is out of memory: a
    /// missed event must never take the helper down.
    fn post(self: *Host, value: anytype) void {
        const T = @TypeOf(value);
        if (comptime (@hasField(T, "view") or @hasField(T, "owner_view"))) {
            const r = self.routeFor(routeKeyOf(value).?) orelse return;
            const v2 = toClientIds(value, r.base);
            if (self.active_sem_request != 0 and semanticResult(T)) {
                var payload: std.ArrayList(u8) = .empty;
                defer payload.deinit(self.gpa);
                proto.encodePayload(self.gpa, &payload, v2) catch return;
                r.out.post(proto.SemResult{
                    .request = self.active_sem_request,
                    .kind = @intFromEnum(T.tag),
                    .payload = .{ .s = payload.items },
                }, null) catch {};
                return;
            }
            r.out.post(v2, null) catch {};
            return;
        }
        // Viewless frame: answer the dispatching connection, else
        // broadcast — the viewless family is engine-global state
        // (webext registry, filter lists), which in Phase 1 keeps its
        // last-writer-wins semantics, so every client observing every
        // change is the coherent reading. The per-connection-overlay
        // question is Phase 4's, decided deliberately, not here.
        const rt = self.router orelse {
            self.out.post(value, null) catch {};
            return;
        };
        if (self.dispatch_conn != 0) {
            if (rt.route(rt.ctx, self.dispatch_conn)) |out| out.post(value, null) catch {};
            return;
        }
        var i: usize = 0;
        const n = rt.count(rt.ctx);
        while (i < n) : (i += 1) {
            if (rt.at(rt.ctx, i)) |out| out.post(value, null) catch {};
        }
    }

    /// Post a GPU frame with its plane descriptors, or drop it.
    ///
    /// Dropping matters here in a way it does not for the memfd path: a
    /// queued dma-buf frame pins BOTH a descriptor per plane and the
    /// buffer behind it, so a client that stops reading would otherwise
    /// exhaust this process's fd table and starve the engine's pool at
    /// the same time. A dropped frame costs nothing — the next one is a
    /// full buffer, not a delta.
    fn postDmabuf(self: *Host, value: proto.FrameDmabuf, fds: []const i32) void {
        const r = self.routeFor(value.view) orelse {
            for (fds) |fd| _ = c.close(fd);
            return;
        };
        if (r.out.pending() >= max_frame_backlog) {
            for (fds) |fd| _ = c.close(fd);
            return;
        }
        r.out.postFds(toClientIds(value, r.base), fds) catch {
            for (fds) |fd| _ = c.close(fd);
        };
    }

    fn setUrl(self: *Host, v: *View, url: []const u8) void {
        const dup = self.gpa.dupe(u8, url) catch return;
        if (v.url.len != 0) self.gpa.free(v.url);
        v.url = dup;
    }

    fn postNavState(self: *Host, v: *View) void {
        const b = v.browser;
        const can_back: u8 = if (b != null and browserInt(b, "can_go_back") != 0) 1 else 0;
        const can_fwd: u8 = if (b != null and browserInt(b, "can_go_forward") != 0) 1 else 0;
        const loading: u8 = if (b != null and browserInt(b, "is_loading") != 0) 1 else 0;
        self.post(proto.EvNavState{
            .view = v.id,
            .can_back = can_back,
            .can_fwd = can_fwd,
            .loading = loading,
            .url = v.url,
        });
    }
};

var g_host: ?*Host = null;

const ViewConstructionTest = struct {
    const Failure = enum { none, browser, memfd, truncate, map, announce };

    failure: Failure = .none,
    seed_semantic: bool = false,
    semantic_seeded: bool = false,
    browser_calls: usize = 0,
    last_fd: c_int = -1,
    last_map: ?FrameMap = null,

    var fake_browser: cef.cef_browser_t = undefined;

    fn ops(self: *ViewConstructionTest) BrowserSpawnOps {
        return .{
            .ctx = self,
            .create_browser = createBrowser,
            .create_memfd = createMemfd,
            .truncate = truncate,
            .map = map,
            .announce = announce,
        };
    }

    fn state(ctx: ?*anyopaque) *ViewConstructionTest {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn browserId(_: [*c]cef.cef_browser_t) callconv(.c) c_int {
        return 0;
    }

    fn createBrowser(ctx: ?*anyopaque, _: *Host, v: *View, _: []const u8) ?*cef.cef_browser_t {
        const self = state(ctx);
        self.browser_calls += 1;
        if (self.seed_semantic) {
            const nodes = [_]semantic.InNode{.{ .id = 1, .role = "document", .name = "owned semantic state" }};
            v.sem.apply(.{ .doc = 1, .nodes = &nodes }) catch return null;
            self.semantic_seeded = true;
        }
        if (self.failure == .browser) return null;
        fake_browser = std.mem.zeroes(cef.cef_browser_t);
        fake_browser.get_identifier = browserId;
        return &fake_browser;
    }

    fn createMemfd(ctx: ?*anyopaque) ?c_int {
        const self = state(ctx);
        if (self.failure == .memfd) return null;
        const fd = Host.createMemfdSystem(null) orelse return null;
        self.last_fd = fd;
        return fd;
    }

    fn truncate(ctx: ?*anyopaque, fd: c_int, size: usize) bool {
        if (state(ctx).failure == .truncate) return false;
        return Host.truncateSystem(null, fd, size);
    }

    fn map(ctx: ?*anyopaque, size: usize, shared: bool, fd: c_int) ?FrameMap {
        const self = state(ctx);
        if (self.failure == .map) return null;
        const mapping = Host.mapSystem(null, size, shared, fd) orelse return null;
        self.last_map = mapping;
        return mapping;
    }

    fn announce(ctx: ?*anyopaque, host: *Host, v: *View, fd: c_int) !void {
        if (state(ctx).failure == .announce) return error.InjectedAnnouncementFailure;
        try Host.announceBufferSystem(null, host, v, fd);
    }

    fn expectReleased(self: *const ViewConstructionTest) !void {
        if (self.last_fd >= 0) try std.testing.expect(c.fcntl(self.last_fd, c.F_GETFD) < 0);
        if (self.last_map) |mapping| {
            var resident: u8 = 0;
            try std.testing.expect(c.mincore(mapping.ptr, mapping.len, &resident) != 0);
        }
    }

    fn req(id: u32, context: u32) proto.ViewCreate {
        return .{ .view = id, .w = 8, .h = 8, .scale_x1000 = 1000, .context = context };
    }

    fn closeOutboxFds(out: *proto.Outbox) void {
        while (out.front()) |msg| {
            for (msg.fdSlice()) |fd| _ = c.close(fd);
            out.advance(msg.bytes.len);
        }
    }

    fn allocationCase(gpa: std.mem.Allocator) !void {
        var out = proto.Outbox.init(std.testing.allocator);
        defer out.deinit();
        defer closeOutboxFds(&out);
        var host = Host.init(gpa, &out);
        defer host.deinit();

        // Exact capacity makes the second append an allocation point.
        try host.views.ensureTotalCapacityPrecise(gpa, 1);
        const prior = try host.registerView(req(41, 0));
        var injected: ViewConstructionTest = .{};
        var spawn_ops = injected.ops();
        if (host.createViewAtWith(req(42, 0), "", &spawn_ops)) |_| {
            try std.testing.expectEqual(@as(usize, 2), host.viewCount());
            try std.testing.expect(host.find(41) == prior);
            host.destroyView(42);
            closeOutboxFds(&out);
            try injected.expectReleased();
        } else |err| {
            try std.testing.expectEqual(@as(usize, 1), host.viewCount());
            try std.testing.expect(host.find(41) == prior);
            try std.testing.expect(host.find(42) == null);
            return err;
        }
    }
};

test "view construction allocation failures preserve prior views" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        ViewConstructionTest.allocationCase,
        .{},
    );
}

test "view construction system failures release one owned view" {
    const Case = struct { failure: ViewConstructionTest.Failure, inline_mode: bool = false };
    const cases = [_]Case{
        .{ .failure = .memfd },
        .{ .failure = .truncate },
        .{ .failure = .map },
        .{ .failure = .map, .inline_mode = true },
        .{ .failure = .announce },
    };

    for (cases) |case| {
        var out = proto.Outbox.init(std.testing.allocator);
        defer out.deinit();
        defer ViewConstructionTest.closeOutboxFds(&out);
        var host = Host.init(std.testing.allocator, &out);
        defer host.deinit();
        host.inline_mode = case.inline_mode;

        const prior = try host.registerView(ViewConstructionTest.req(51, 0));
        var injected = ViewConstructionTest{ .failure = case.failure, .seed_semantic = true };
        var spawn_ops = injected.ops();
        if (host.createViewAtWith(ViewConstructionTest.req(52, 0), "", &spawn_ops)) |_| {
            return error.ExpectedConstructionFailure;
        } else |_| {}

        try std.testing.expect(injected.semantic_seeded);
        try std.testing.expectEqual(@as(usize, 1), host.viewCount());
        try std.testing.expect(host.find(51) == prior);
        try std.testing.expect(host.find(52) == null);
        try injected.expectReleased();
    }
}

test "a refused browser create is a DESCRIBED failure, never an error or a kept view" {
    // The engine absorbs CEF's transient refusals itself (retry budget
    // on the SYSTEM ops); a refusal that outlasts the budget posts
    // `ev_view_create_failed` and destroys the registered view — it
    // does NOT error, which used to cut the whole connection with a
    // bare ECONNRESET for an engine-side condition.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    const prior = try host.registerView(ViewConstructionTest.req(51, 0));
    var injected = ViewConstructionTest{ .failure = .browser, .seed_semantic = true };
    var spawn_ops = injected.ops();
    try host.createViewAtWith(ViewConstructionTest.req(52, 0), "", &spawn_ops);

    try std.testing.expectEqual(@as(usize, 1), host.viewCount());
    try std.testing.expect(host.find(51) == prior);
    try std.testing.expect(host.find(52) == null);
    var saw_refusal = false;
    while (out.front()) |m| {
        var reader = proto.Reader.init(m.bytes);
        while (reader.next() catch null) |frame| {
            if (frame.tag == .ev_view_create_failed) saw_refusal = true;
        }
        out.advance(m.bytes.len);
    }
    try std.testing.expect(saw_refusal);
}

test "a failed revival leaves findWake with no view to hand back" {
    // Everything but `BrowserCreateFailed` makes `reviveAt` destroy the
    // record it was reviving, so `findWake` must re-establish liveness
    // instead of reading `discarded` back off freed memory -- which read
    // false, returned the dangling view, and let the callers write
    // through it into whatever reused the slot.
    const cases = [_]ViewConstructionTest.Failure{ .memfd, .truncate, .map, .announce };
    for (cases) |failure| {
        var out = proto.Outbox.init(std.testing.allocator);
        defer out.deinit();
        defer ViewConstructionTest.closeOutboxFds(&out);
        var host = Host.init(std.testing.allocator, &out);
        defer host.deinit();

        const prior = try host.registerView(ViewConstructionTest.req(71, 0));
        const doomed = try host.registerView(ViewConstructionTest.req(72, 0));
        host.discardView(doomed.id);
        try std.testing.expect(doomed.discarded);

        var injected = ViewConstructionTest{ .failure = failure };
        var spawn_ops = injected.ops();
        try std.testing.expect(host.findWakeWith(72, &spawn_ops) == null);
        try std.testing.expectEqual(@as(usize, 1), host.viewCount());
        try std.testing.expect(host.find(72) == null);
        try std.testing.expect(host.find(71) == prior);
        try std.testing.expect(!prior.discarded);
        try injected.expectReleased();
    }
}

test "a revival refused by the engine keeps the view discarded" {
    // The other half of `reviveAt`'s split: BrowserCreateFailed retains
    // the record, so the id stays known and a later attempt can succeed.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    const v = try host.registerView(ViewConstructionTest.req(81, 0));
    host.discardView(v.id);
    var injected = ViewConstructionTest{ .failure = .browser };
    var spawn_ops = injected.ops();
    try std.testing.expect(host.findWakeWith(81, &spawn_ops) == null);
    try std.testing.expectEqual(@as(usize, 1), host.viewCount());
    try std.testing.expect(host.find(81) == v);
    try std.testing.expect(v.discarded);
}

test "view construction rejects a missing context before ownership transfer" {
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    const prior = try host.registerView(ViewConstructionTest.req(61, 0));
    var injected: ViewConstructionTest = .{};
    var spawn_ops = injected.ops();
    try host.createViewAtWith(ViewConstructionTest.req(62, 99), "", &spawn_ops);

    try std.testing.expectEqual(@as(usize, 1), host.viewCount());
    try std.testing.expect(host.find(61) == prior);
    try std.testing.expect(host.find(62) == null);
    try std.testing.expectEqual(@as(usize, 0), injected.browser_calls);
    var reader = proto.Reader.init(out.front().?.bytes);
    const frame = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.ev_view_create_failed, frame.tag);
    const failure = try proto.decode(proto.EvViewCreateFailed, frame.payload);
    try std.testing.expectEqual(@as(u32, 62), failure.view);
    try std.testing.expectEqual(@as(u32, 99), failure.context);
}

test "the inspector view is owned and unwound by the view list" {
    // It used to be appended by hand and unwound with `views.pop()`, on
    // a list managed everywhere else with `swapRemove`: the pop drops
    // whatever moved into the last slot, not the view it meant. Pin the
    // ownership contract -- registered through `registerView`, released
    // through `destroyView` BY ID, and the source's back-pointer cleared
    // by that release rather than by hand.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    const src = try host.registerView(ViewConstructionTest.req(21, 0));
    const other = try host.registerView(ViewConstructionTest.req(22, 0));
    const dev = try host.registerDevtoolsView(src);
    // A view appended AFTER the inspector is what `pop()` would take.
    const later = try host.registerView(ViewConstructionTest.req(23, 0));

    try std.testing.expect(dev.id > proto.DEVTOOLS_VIEW_BASE);
    try std.testing.expectEqual(src.id, dev.devtools_of);
    try std.testing.expectEqual(dev.id, src.devtools_view);
    try std.testing.expect(host.find(dev.id) == dev);

    host.destroyView(dev.id);
    try std.testing.expect(host.find(dev.id) == null);
    try std.testing.expectEqual(@as(u32, 0), src.devtools_view);
    try std.testing.expect(host.find(21) == src);
    try std.testing.expect(host.find(22) == other);
    try std.testing.expect(host.find(23) == later);
}

fn devtoolsRegistrationCase(gpa: std.mem.Allocator) !void {
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(gpa, &out);
    defer host.deinit();

    try host.views.ensureTotalCapacityPrecise(gpa, 1);
    const src = try host.registerView(ViewConstructionTest.req(31, 0));
    if (host.registerDevtoolsView(src)) |dev| {
        try std.testing.expectEqual(@as(usize, 2), host.viewCount());
        host.destroyView(dev.id);
    } else |err| {
        try std.testing.expectEqual(@as(usize, 1), host.viewCount());
        try std.testing.expect(host.find(31) == src);
        try std.testing.expectEqual(@as(u32, 0), src.devtools_view);
        return err;
    }
}

test "inspector registration allocation failures leave no orphan" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        devtoolsRegistrationCase,
        .{},
    );
}

test "a revival whose container vanished is refused, not put on the global context" {
    // NULL is the global request context: no proxy, the shared jar. A
    // view minted in an egress container whose container was deleted
    // while it was discarded must stay discarded rather than come back
    // with its traffic leaving the machine directly.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    const v = try host.registerView(ViewConstructionTest.req(91, 7));
    host.discardView(v.id);
    var injected: ViewConstructionTest = .{};
    var spawn_ops = injected.ops();
    try std.testing.expect(host.findWakeWith(91, &spawn_ops) == null);
    try std.testing.expectEqual(@as(usize, 0), injected.browser_calls);
    try std.testing.expectEqual(@as(usize, 1), host.viewCount());
    try std.testing.expect(host.find(91) == v);
    try std.testing.expect(v.discarded);
}

test "the spawn's container check mints no reference the engine will not consume" {
    // `contextForSpawn` ADD-REFs for a create_browser call to CONSUME.
    // The spawn used it for its pre-flight refusal too and dropped that
    // reference on the floor, so an ephemeral container never reached
    // zero and its in-memory jar was never wiped.
    const Fake = struct {
        var added: usize = 0;
        var released: usize = 0;
        fn add(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) void {
            added += 1;
        }
        fn rel(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
            released += 1;
            return 1;
        }
    };
    Fake.added = 0;
    Fake.released = 0;
    var rc = std.mem.zeroes(cef.cef_request_context_t);
    rc.base.base.add_ref = Fake.add;
    rc.base.base.release = Fake.rel;

    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();
    try host.contexts.append(host.gpa, .{ .id = 7, .rc = &rc, .ephemeral = true });

    var injected: ViewConstructionTest = .{};
    var spawn_ops = injected.ops();
    try host.createViewAtWith(ViewConstructionTest.req(91, 7), "", &spawn_ops);
    try std.testing.expectEqual(@as(usize, 1), injected.browser_calls);
    try std.testing.expectEqual(@as(usize, 0), Fake.added);

    host.contextDestroy(7);
    try std.testing.expectEqual(@as(usize, 1), Fake.released);
}

test "a document replacement disconnects the ports bound to that view" {
    // A content script's `runtime.connect` Port dies with its document.
    // The table kept it, so ports accumulated for the life of the helper
    // and a background page could still message a page that was gone.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    const page = try host.registerView(ViewConstructionTest.req(11, 0));
    const bg = try host.registerView(ViewConstructionTest.req(12, 0));
    const other = try host.registerView(ViewConstructionTest.req(13, 0));
    try host.webext_ports.append(host.gpa, .{
        .gid = 1,
        .ext = try host.gpa.dupe(u8, "ext@example"),
        .a_view = page.id,
        .b_view = bg.id,
    });
    // A port between two OTHER views must survive this navigation.
    try host.webext_ports.append(host.gpa, .{
        .gid = 2,
        .ext = try host.gpa.dupe(u8, "ext@example"),
        .a_view = other.id,
        .b_view = bg.id,
    });

    host.semanticNavigationStarted(page);
    try std.testing.expectEqual(@as(usize, 1), host.webext_ports.items.len);
    try std.testing.expectEqual(@as(u32, 2), host.webext_ports.items[0].gid);
}

/// Fake engine objects for driving a callback directly: the only live
/// vtable slots count releases and answer the identity lookups.
const CallbackArgTest = struct {
    const cef_id: c_int = 4242;
    var browser: cef.cef_browser_t = undefined;
    var frame: cef.cef_frame_t = undefined;
    var released: usize = 0;

    fn rel(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
        released += 1;
        return 1;
    }

    fn ident(_: [*c]cef.cef_browser_t) callconv(.c) c_int {
        return cef_id;
    }

    fn mainFrame(_: [*c]cef.cef_frame_t) callconv(.c) c_int {
        return 1;
    }

    fn reset() void {
        released = 0;
        browser = std.mem.zeroes(cef.cef_browser_t);
        browser.base.release = rel;
        browser.get_identifier = ident;
        frame = std.mem.zeroes(cef.cef_frame_t);
        frame.base.release = rel;
        frame.is_main = mainFrame;
    }
};

test "releaseArg returns exactly one reference and tolerates null" {
    CallbackArgTest.reset();
    releaseArg(@as([*c]cef.cef_browser_t, &CallbackArgTest.browser));
    releaseArg(@as([*c]cef.cef_browser_t, null));
    try std.testing.expectEqual(@as(usize, 1), CallbackArgTest.released);
}

test "a background page replacing its document drops its ports and returns every argument" {
    // `on_load_start` used to leave a background page before the Port
    // sweep, so a `location.href` replacement kept its ports alive; and
    // every callback used to keep the reference libcef wraps each
    // argument with, which is the per-request leak the helper carried.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();
    g_host = &host;
    defer g_host = null;

    const page = try host.registerView(ViewConstructionTest.req(21, 0));
    const bg = try host.registerView(ViewConstructionTest.req(22, 0));
    bg.webext_bg = true;
    bg.cef_id = CallbackArgTest.cef_id;
    try host.webext_ports.append(host.gpa, .{
        .gid = 1,
        .ext = try host.gpa.dupe(u8, "ext@example"),
        .a_view = page.id,
        .b_view = bg.id,
    });

    CallbackArgTest.reset();
    onLoadStart(null, &CallbackArgTest.browser, &CallbackArgTest.frame, 0);
    try std.testing.expectEqual(@as(usize, 0), host.webext_ports.items.len);
    try std.testing.expectEqual(@as(usize, 2), CallbackArgTest.released);
}

/// A `cef_request_context_t` whose only live vtable slot counts releases.
const ContextCreateTest = struct {
    var rc: cef.cef_request_context_t = undefined;
    var released: usize = 0;

    fn rel(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
        released += 1;
        return 1;
    }

    fn create(_: ?*anyopaque, _: *const cef.cef_request_context_settings_t) ?*cef.cef_request_context_t {
        rc = std.mem.zeroes(cef.cef_request_context_t);
        rc.base.base.release = rel;
        return &rc;
    }

    fn ops() ContextCreateOps {
        released = 0;
        return .{ .create = create };
    }
};

test "a context whose proxy is refused registers nothing and releases once" {
    // The rollback used to release a value graph `set_preference` had
    // already consumed. Nothing but the request context is ours to drop
    // here, and it is dropped exactly once. The create path retains no
    // CEF object at all any more, so this is the whole contract.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    var context_ops = ContextCreateTest.ops();
    _ = c.setenv("SKETERM_WEB_FAIL_PROXY", "1", 1);
    defer _ = c.unsetenv("SKETERM_WEB_FAIL_PROXY");
    // The proxy is the INSTANCE's route; a per-context `proxy` on the
    // wire is ignored, so the refusal under test is the instance one.
    host.instance_proxy = "socks5://127.0.0.1:9";
    host.contextCreateWith(.{
        .id = 5,
        .ephemeral = 1,
        .name = "proxy-refused",
        .proxy = "",
    }, &context_ops);

    try std.testing.expectEqual(@as(usize, 1), ContextCreateTest.released);
    try std.testing.expectEqual(@as(usize, 0), host.contexts.items.len);
    try std.testing.expect(host.lookupContext(5) == null);
}

test "an accepted context is released exactly once, by its destroy" {
    // The counterpart: a registration that survived holds ONE reference,
    // and `contextDestroy` is the only thing that drops it. A retained
    // proxy value graph would show up here as extra releases.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    var context_ops = ContextCreateTest.ops();
    host.contextCreateWith(.{ .id = 5, .ephemeral = 1, .name = "kept", .proxy = "" }, &context_ops);
    try std.testing.expectEqual(@as(usize, 0), ContextCreateTest.released);
    try std.testing.expectEqual(@as(usize, 1), host.contexts.items.len);
    try std.testing.expect(host.lookupContext(5) != null);

    host.contextDestroy(5);
    try std.testing.expectEqual(@as(usize, 1), ContextCreateTest.released);
    try std.testing.expectEqual(@as(usize, 0), host.contexts.items.len);
}

test "a persistent jar directory is named by the id its OWNER minted" {
    // Multi-client windows the engine's context ids per connection, but
    // the jar directory is the CLIENT's durable profile store's own
    // `profile-<name>-<id>`: keyed on the global id instead, a client
    // that reconnects on another window would land in a fresh, empty
    // jar and orphan the one holding its cookies.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();
    var buf: [256]u8 = undefined;

    host.dispatch_conn = 3;
    try std.testing.expectEqual(@as(u32, 4), host.ownerCtxId(3 * proto.CONN_ID_WINDOW + 4));
    try std.testing.expectEqualStrings(
        "profile-work-4",
        sanitizeContextName("profile-work", host.ownerCtxId(3 * proto.CONN_ID_WINDOW + 4), &buf),
    );

    // Another connection, same profile: the same directory.
    host.dispatch_conn = 7;
    try std.testing.expectEqualStrings(
        "profile-work-4",
        sanitizeContextName("profile-work", host.ownerCtxId(7 * proto.CONN_ID_WINDOW + 4), &buf),
    );

    // A frame dispatched outside any connection carries an untranslated
    // id, and an id below its window is left alone rather than wrapped.
    host.dispatch_conn = 0;
    try std.testing.expectEqual(@as(u32, 4), host.ownerCtxId(4));
    host.dispatch_conn = 9;
    try std.testing.expectEqual(@as(u32, 4), host.ownerCtxId(4));
}

test "a popup whose owner's container vanished is refused before the engine call" {
    // The owner page keeps working after its container is destroyed, so
    // the popup it opens is the one path that could still hand a
    // container's page to the global context.
    var out = proto.Outbox.init(std.testing.allocator);
    defer out.deinit();
    defer ViewConstructionTest.closeOutboxFds(&out);
    var host = Host.init(std.testing.allocator, &out);
    defer host.deinit();

    const v = try host.registerView(ViewConstructionTest.req(proto.WEBEXT_POPUP_VIEW_BASE + 1, 7));
    v.webext_popup = true;
    try std.testing.expectError(error.ContextGone, host.spawnPopup(v, "about:blank"));
    try std.testing.expect(v.browser == null);
}

// ---------------------------------------------------------------------
// Cookies + site data (capability "sitedata")
// ---------------------------------------------------------------------

/// Everything an origin's own scripts can wipe. Guarded one by one:
/// a page served over a scheme where `localStorage` throws on ACCESS
/// (not on use) must still get its IndexedDB cleared.
const clear_storage_js =
    "(function(){" ++
    "try{localStorage.clear()}catch(e){}" ++
    "try{sessionStorage.clear()}catch(e){}" ++
    "try{if(indexedDB.databases)indexedDB.databases().then(function(l){" ++
    "l.forEach(function(d){try{indexedDB.deleteDatabase(d.name)}catch(e){}})})}catch(e){}" ++
    "try{if(window.caches)caches.keys().then(function(k){" ++
    "k.forEach(function(n){try{caches.delete(n)}catch(e){}})})}catch(e){}" ++
    "})();";

/// Scheme + authority of `url` ("https://host:8443"), empty when it has
/// no authority at all (about:, data:).
fn originSlice(url: []const u8) []const u8 {
    const sep = std.mem.indexOf(u8, url, "://") orelse return "";
    const rest = url[sep + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    return url[0 .. sep + 3 + end];
}

fn sameOrigin(a: []const u8, b: []const u8) bool {
    const oa = originSlice(a);
    if (oa.len == 0) return false;
    return std.ascii.eqlIgnoreCase(oa, originSlice(b));
}

/// Append one comma-separated token to a bounded detail string,
/// dropping it rather than truncating into a token nobody can match.
fn appendDetail(buf: []u8, len: *usize, token: []const u8) void {
    const need = token.len + @as(usize, if (len.* == 0) 0 else 1);
    if (len.* + need > buf.len) return;
    if (len.* != 0) {
        buf[len.*] = ',';
        len.* += 1;
    }
    @memcpy(buf[len.*..][0..token.len], token);
    len.* += token.len;
}

/// Milliseconds since the Unix epoch for a CEF base time, which counts
/// MICROSECONDS since the Windows epoch (1601). A time at or before the
/// Unix epoch reads as 0, i.e. "no useful expiry".
fn baseTimeMs(bt: cef.cef_basetime_t) u64 {
    const win_to_unix_us: i64 = 11_644_473_600 * std.time.us_per_s;
    const unix_us = bt.val - win_to_unix_us;
    if (unix_us <= 0) return 0;
    return @intCast(@divTrunc(unix_us, 1000));
}

/// One in-flight cookie visit.
///
/// REFCOUNTED FOR REAL, unlike every other client-side struct in this
/// file: `visit_url_cookies` takes ownership of the visitor reference
/// it is handed (CEF's CToCpp wrappers transfer, never add), calls
/// `visit` once per cookie on the UI thread — which under a
/// single-threaded message loop is THIS thread, inside `pump()` — and
/// releases when it is done. The final release is therefore both the
/// "visiting finished" signal and the free, so the answer is posted
/// from there and nowhere else. That also covers the failure path: a
/// manager that refuses the visit destroys the wrapper immediately and
/// the client still gets its (empty) reply.
const CookieJob = struct {
    /// FIRST FIELD: CEF is handed `&job.visitor` and hands the same
    /// pointer back as `self`.
    visitor: cef.cef_cookie_visitor_t,
    refs: std.atomic.Value(u32),
    gpa: std.mem.Allocator,
    view: u32,
    req: u32,
    mode: Mode,
    kind: proto.SitedataKind,
    /// Owned copy of the name `delete_named` matches.
    name: []u8,
    /// Owned copy of the detail tokens the reply must carry.
    detail: []u8,
    /// String bytes for every recorded cookie, referenced by OFFSET —
    /// the list grows, so a slice into it would dangle on the realloc.
    strings: std.ArrayList(u8) = .empty,
    recs: std.ArrayList(Rec) = .empty,
    /// Cookies seen, whether or not `recs` had room for them.
    total: u32 = 0,
    removed: u32 = 0,
    /// The manager accepted the visit. False means the cookie store
    /// could not be reached at all, which a client must be able to
    /// tell apart from a site with no cookies.
    accessible: bool = true,

    const Mode = enum { list, delete_named, delete_all };

    const Span = struct { off: u32, len: u32 };

    const Rec = struct {
        name: Span,
        domain: Span,
        path: Span,
        flags: u8,
        same_site: u8,
        expires_ms: u64,
        value_len: u32,
    };

    const Opts = struct {
        view: u32,
        req: u32,
        mode: Mode,
        kind: proto.SitedataKind,
        name: []const u8,
        detail: []const u8,
    };

    /// Hand a visitor to `mgr` for `url`. Null means nothing was
    /// started and the caller still owes the client a reply.
    fn start(
        gpa: std.mem.Allocator,
        mgr: *cef.cef_cookie_manager_t,
        url: []const u8,
        opts: Opts,
    ) ?void {
        const visit = mgr.visit_url_cookies orelse return null;
        const job = gpa.create(CookieJob) catch return null;
        const name = gpa.dupe(u8, opts.name) catch {
            gpa.destroy(job);
            return null;
        };
        const detail = gpa.dupe(u8, opts.detail) catch {
            gpa.free(name);
            gpa.destroy(job);
            return null;
        };
        job.* = .{
            .visitor = .{
                .base = JobRef.base(),
                .visit = jobVisit,
            },
            .refs = .init(1),
            .gpa = gpa,
            .view = opts.view,
            .req = opts.req,
            .mode = opts.mode,
            .kind = opts.kind,
            .name = name,
            .detail = detail,
        };

        var u = std.mem.zeroes(cef.cef_string_t);
        setStr(url, &u);
        defer cef.cef_string_utf16_clear(&u);
        // The call CONSUMES a reference (CEF's CToCpp wrappers take
        // ownership, they never add one) and may drop it before it even
        // returns, when the manager refuses. A second reference is held
        // across the call so the return value is still readable when
        // the answer is composed — releasing it here is then what
        // triggers `finish` in the ordinary case.
        job.refs.store(2, .release);
        if (visit(mgr, &u, 1, &job.visitor) == 0) job.accessible = false;
        _ = JobRef.release(&job.visitor.base);
        return {};
    }

    fn record(self: *CookieJob, cookie: *const cef.cef_cookie_t) void {
        if (self.recs.items.len >= proto.MAX_COOKIE_ENTRIES) return;
        var name = Utf8.init(&cookie.name);
        defer name.free();
        var domain = Utf8.init(&cookie.domain);
        defer domain.free();
        var path = Utf8.init(&cookie.path);
        defer path.free();
        var value = Utf8.init(&cookie.value);
        defer value.free();

        const n = self.intern(name.slice()) orelse return;
        const d = self.intern(domain.slice()) orelse return;
        const p = self.intern(path.slice()) orelse return;

        var flags: u8 = 0;
        if (cookie.secure != 0) flags |= proto.cookie_secure;
        if (cookie.httponly != 0) flags |= proto.cookie_httponly;
        if (cookie.has_expires == 0) flags |= proto.cookie_session;
        if (domain.slice().len != 0 and domain.slice()[0] == '.') flags |= proto.cookie_domain_scoped;

        self.recs.append(self.gpa, .{
            .name = n,
            .domain = d,
            .path = p,
            .flags = flags,
            .same_site = sameSiteOf(cookie.same_site),
            .expires_ms = if (cookie.has_expires != 0) baseTimeMs(cookie.expires) else 0,
            .value_len = @intCast(value.slice().len),
        }) catch {};
    }

    fn intern(self: *CookieJob, s: []const u8) ?Span {
        const off: u32 = @intCast(self.strings.items.len);
        self.strings.appendSlice(self.gpa, s) catch return null;
        return .{ .off = off, .len = @intCast(s.len) };
    }

    fn matches(self: *const CookieJob, cookie: *const cef.cef_cookie_t) bool {
        var name = Utf8.init(&cookie.name);
        defer name.free();
        return std.mem.eql(u8, name.slice(), self.name);
    }

    /// Post the answer. Runs from the LAST release, so the visit is
    /// over and every cookie has been seen.
    fn finish(self: *CookieJob) void {
        const host = g_host orelse return;
        switch (self.mode) {
            .list => {
                const entries = self.gpa.alloc(proto.CookieEntry, self.recs.items.len) catch {
                    host.postNoCookies(self.view, self.req);
                    return;
                };
                defer self.gpa.free(entries);
                for (entries, self.recs.items) |*e, r| {
                    e.* = .{
                        .name = self.str(r.name),
                        .domain = self.str(r.domain),
                        .path = self.str(r.path),
                        .flags = r.flags,
                        .same_site = r.same_site,
                        .expires_ms = r.expires_ms,
                        .value_len = r.value_len,
                    };
                }
                host.post(proto.EvCookies{
                    .view = self.view,
                    .req = self.req,
                    .ok = if (self.accessible) 1 else 0,
                    .total = self.total,
                    .entries = entries,
                });
            },
            .delete_named, .delete_all => host.post(proto.EvSitedataDone{
                .view = self.view,
                .req = self.req,
                .ok = if (self.accessible) 1 else 0,
                .kind = @intFromEnum(self.kind),
                .removed = self.removed,
                .detail = self.detail,
            }),
        }
    }

    fn str(self: *const CookieJob, s: Span) []const u8 {
        return self.strings.items[s.off..][0..s.len];
    }

    /// The LAST release is both "the visit is over" and the free, so
    /// the answer is posted from here and from nowhere else.
    fn destroyOwned(self: *CookieJob) void {
        self.finish();
        const gpa = self.gpa;
        self.strings.deinit(gpa);
        self.recs.deinit(gpa);
        gpa.free(self.name);
        gpa.free(self.detail);
        gpa.destroy(self);
    }
};

// ---------------------------------------------------------------------
// Cross-instance cookie sync (capability "cookie-sync")
// ---------------------------------------------------------------------
//
// sketerm runs one helper per network route, each with its own profile
// and therefore its own jar. This block is what makes a login follow
// the user between them: OBSERVE one jar changing, hand the change to
// the client, APPLY what the client hands back.
//
// TWO OBSERVERS, BECAUSE ONE IS NOT ENOUGH — measured on CEF 151.3.16
// (smoke-web stage 41 is the standing proof, and reports both halves):
//
//   - `cef_cookie_access_filter_t::can_save_cookie` fires per
//     `Set-Cookie` RESPONSE HEADER, on the IO thread, with the parsed
//     cookie and the request. It is immediate and exact, and it is the
//     ONLY thing that sees a header write.
//   - It does NOT fire for `document.cookie`, nor for a `CookieStore`
//     write. Both bypass the network stack entirely — there is no
//     resource request to filter — so a script-set session cookie is
//     invisible to it. That is not a bug to work around but the shape
//     of the API: it filters cookie ACCESS BY REQUESTS.
//
// So the header filter is the fast path and a periodic full walk
// (`visit_all_cookies`, diffed against a shadow) is the complete one.
// The walk also covers deletion, which no header observer can see at
// all: a `document.cookie` expiry, a `CookieStore.delete`, and the
// engine's own eviction all reach the wire as a diff.
//
// The two feed ONE funnel (`Host.noteCookie`), which is also where
// loop prevention lives — see `Host.cookieApply`.

/// How often the reconcile walks each jar. Deliberately slow: it is
/// the completeness net under an immediate header path, not the
/// primary mechanism, and a walk of every jar is real UI-thread work.
/// `SKETERM_WEB_COOKIE_SYNC_MS` overrides it (smoke-web runs it fast).
const cookie_reconcile_default_ms: i64 = 3_000;

fn cookieReconcileMs() i64 {
    const v = c.getenv("SKETERM_WEB_COOKIE_SYNC_MS") orelse return cookie_reconcile_default_ms;
    const n = std.fmt.parseInt(i64, std.mem.span(v), 10) catch return cookie_reconcile_default_ms;
    return if (n <= 0) cookie_reconcile_default_ms else n;
}

/// Wall-clock milliseconds, for comparing against a cookie's expiry
/// (which is an absolute date, not a monotonic instant).
fn wallMsNow() u64 {
    const ms = @import("../util/clock.zig").wallMs();
    return if (ms <= 0) 0 else @intCast(ms);
}

/// Last-known state of ONE cookie in ONE jar.
const CookieShadow = struct {
    context: u32,
    /// Prefilter over (context, domain, path, name); the strings below
    /// are the actual identity, always compared before a match counts.
    id_hash: u64,
    domain: []u8,
    path: []u8,
    name: []u8,
    /// `valueHash` of what the jar last held. Never includes creation
    /// or last-access: `last_access` moves on every request the cookie
    /// is sent with, and diffing on it would emit a change per page
    /// load forever.
    hash: u64 = 0,
    /// Marked by the current reconcile walk; an unmarked entry at the
    /// end of a walk is a cookie that left the jar.
    seen: bool = false,
    /// A `cookie_apply` is in flight for this identity. The jar and
    /// this entry disagree until the engine's completion callback
    /// lands, and emitting that disagreement is the ping-pong.
    pending: bool = false,
    pending_remove: bool = false,
    pending_hash: u64 = 0,
    /// An apply just settled on this identity: the NEXT reconcile that
    /// finds the jar disagreeing with `hash` adopts what the jar says
    /// WITHOUT emitting it. The engine normalises what it stores
    /// (a domain cookie gains its dot, an expiry past Chromium's
    /// 400-day cap is clamped), and reporting its normalisation back
    /// to the client as a change is a whole fan-out of frames saying
    /// nothing — 140 of them, measured, before this existed.
    adopt: bool = false,

    /// A cookie's domain WITHOUT its leading dot.
    ///
    /// MEASURED: `set_cookie` with a non-empty `domain` makes a DOMAIN
    /// cookie, which the jar then reports back with a leading dot —
    /// so an applied `site.example` reads back as `.site.example`. Key
    /// the shadow on the dotless form or every applied cookie looks
    /// like one identity leaving the jar and another arriving, which
    /// is a removal AND an add emitted for a cookie nothing changed.
    /// The dot itself is not lost: it travels as
    /// `cookie_domain_scoped` and is part of the VALUE hash.
    fn normDomain(domain: []const u8) []const u8 {
        return if (domain.len != 0 and domain[0] == '.') domain[1..] else domain;
    }

    fn identity(context: u32, domain: []const u8, path: []const u8, name: []const u8) u64 {
        var h = std.hash.Wyhash.init(0x0c00_c1e5);
        h.update(std.mem.asBytes(&context));
        h.update(normDomain(domain));
        h.update(&[_]u8{0});
        h.update(path);
        h.update(&[_]u8{0});
        h.update(name);
        return h.final();
    }

    fn valueHash(ck: proto.SyncCookie) u64 {
        var h = std.hash.Wyhash.init(0x5a17_ed_ba11);
        h.update(ck.value);
        h.update(&[_]u8{ ck.flags, ck.same_site, ck.priority });
        h.update(std.mem.asBytes(&ck.expires_ms));
        // Never zero: `settleApply` reads a zero hash as "this entry
        // was minted by the apply itself and never observed".
        const v = h.final();
        return if (v == 0) 1 else v;
    }

    fn init(gpa: std.mem.Allocator, idh: u64, context: u32, ck: proto.SyncCookie) ?CookieShadow {
        const d = gpa.dupe(u8, ck.domain) catch return null;
        const p = gpa.dupe(u8, ck.path) catch {
            gpa.free(d);
            return null;
        };
        const n = gpa.dupe(u8, ck.name) catch {
            gpa.free(d);
            gpa.free(p);
            return null;
        };
        return .{ .context = context, .id_hash = idh, .domain = d, .path = p, .name = n };
    }

    fn free(self: *CookieShadow, gpa: std.mem.Allocator) void {
        gpa.free(self.domain);
        gpa.free(self.path);
        gpa.free(self.name);
    }
};

/// Bytes a recorded cookie value may carry across the IO-thread
/// mailbox. RFC 6265 recommends 4096 per cookie including the name and
/// attributes, and Chromium enforces that; a longer one is DROPPED
/// from the mailbox rather than truncated, because half a session
/// token is a login that silently does not work. The reconcile — which
/// allocates and has no such cap — carries it instead.
const CK_VALUE_MAX = 4096;
const CK_NAME_MAX = 512;
const CK_URL_MAX = 1024;

/// One cookie the IO thread saw being saved. FIXED SIZE by design:
/// nothing allocates on CEF's IO thread here, exactly as the intercept
/// log and the webRequest hold table do not.
const CkRec = struct {
    used: bool = false,
    view_id: u32 = 0,
    name: [CK_NAME_MAX]u8 = undefined,
    name_len: usize = 0,
    value: [CK_VALUE_MAX]u8 = undefined,
    value_len: usize = 0,
    domain: [CK_NAME_MAX]u8 = undefined,
    domain_len: usize = 0,
    path: [CK_NAME_MAX]u8 = undefined,
    path_len: usize = 0,
    url: [CK_URL_MAX]u8 = undefined,
    url_len: usize = 0,
    flags: u8 = 0,
    same_site: u8 = 0,
    priority: u8 = 0,
    creation_ms: u64 = 0,
    last_access_ms: u64 = 0,
    expires_ms: u64 = 0,

    fn slice(_: *const CkRec, buf: []const u8, len: usize) []const u8 {
        return buf[0..len];
    }
};

/// The IO thread -> main thread mailbox for saved cookies.
///
/// No wake pipe: unlike a HELD webRequest (a page that has stopped
/// loading until we answer), an observed cookie is not blocking
/// anything. The server pumps every 5ms with a view open, and paying
/// for a descriptor plus a write per Set-Cookie to shave that would be
/// spending real cost on a path that has no deadline.
const CookieObs = struct {
    lock: SpinLock = .{},
    /// Read WITHOUT the lock on the IO thread's fast path: with nobody
    /// subscribed, `can_save_cookie` is one relaxed load and a return.
    on: std.atomic.Value(bool) = .init(false),
    recs: [64]CkRec = @splat(.{}),
    /// Cookies the mailbox had no room for. They are not lost to the
    /// SYNC — the reconcile finds them — only to the fast path.
    dropped: u32 = 0,

    /// IO THREAD.
    fn put(self: *CookieObs, rec: *const CkRec) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.recs) |*r| {
            if (r.used) continue;
            r.* = rec.*;
            r.used = true;
            return;
        }
        self.dropped +%= 1;
    }

    /// MAIN THREAD. False when the mailbox is empty.
    fn take(self: *CookieObs, out: *CkRec) bool {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.recs) |*r| {
            if (!r.used) continue;
            out.* = r.*;
            r.used = false;
            return true;
        }
        return false;
    }

    fn drain(self: *CookieObs) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (&self.recs) |*r| r.used = false;
        self.dropped = 0;
    }
};

var g_cksync: CookieObs = .{};

/// The one cookie access filter, handed out per resource request while
/// somebody is synchronising. A process-lifetime static like every
/// other handler here: it carries no per-request state.
var cookie_access_filter: cef.cef_cookie_access_filter_t = undefined;

/// IO THREAD. Never blocks a cookie and never alters one — this is an
/// OBSERVER. `can_send_cookie` is implemented purely so the interface
/// is complete; a filter that answered only half of it would be one
/// CEF version away from a surprise.
fn onCanSendCookie(
    _: [*c]cef.cef_cookie_access_filter_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    _: [*c]const cef.cef_cookie_t,
) callconv(.c) c_int {
    releaseArg(browser);
    releaseArg(frame);
    releaseArg(request);
    return 1;
}

/// IO THREAD. Record one `Set-Cookie` and ALWAYS allow the save.
fn onCanSaveCookie(
    _: [*c]cef.cef_cookie_access_filter_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
    cookie: [*c]const cef.cef_cookie_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    defer releaseArg(response);
    if (!g_cksync.on.load(.acquire)) return 1;
    const ck: *const cef.cef_cookie_t = cookie orelse return 1;

    var rec: CkRec = .{};
    var name = Utf8.init(&ck.name);
    defer name.free();
    var value = Utf8.init(&ck.value);
    defer value.free();
    var domain = Utf8.init(&ck.domain);
    defer domain.free();
    var path = Utf8.init(&ck.path);
    defer path.free();
    // A value past the mailbox's cap is left to the reconcile rather
    // than truncated: half a session token is worse than a late one.
    if (value.slice().len > CK_VALUE_MAX) return 1;
    if (!copyInto(&rec.name, &rec.name_len, name.slice())) return 1;
    if (!copyInto(&rec.value, &rec.value_len, value.slice())) return 1;
    if (!copyInto(&rec.domain, &rec.domain_len, domain.slice())) return 1;
    if (!copyInto(&rec.path, &rec.path_len, path.slice())) return 1;

    if (request != null) {
        const req: *cef.cef_request_t = @ptrCast(request);
        if (req.get_url) |gu| {
            var url_raw: [CK_URL_MAX]u8 = undefined;
            const u = userfreeInto(gu(req), &url_raw);
            _ = copyInto(&rec.url, &rec.url_len, u);
        }
    }
    // Resolving a browser to its CONTEXT is main-thread state; the view
    // id is all the IO thread may learn, exactly as in the intercept
    // path, and `drainSavedCookies` finishes the join.
    if (browser != null) {
        const b: *cef.cef_browser_t = @ptrCast(browser);
        if (b.get_identifier) |gi| {
            const cef_id = gi(b);
            g_int.acquire();
            defer g_int.release();
            if (g_int.slotByCef(cef_id)) |slot| rec.view_id = slot.view_id;
        }
    }

    rec.flags = 0;
    if (ck.secure != 0) rec.flags |= proto.cookie_secure;
    if (ck.httponly != 0) rec.flags |= proto.cookie_httponly;
    if (ck.has_expires == 0) rec.flags |= proto.cookie_session;
    if (rec.domain_len != 0 and rec.domain[0] == '.') rec.flags |= proto.cookie_domain_scoped;
    rec.same_site = sameSiteOf(ck.same_site);
    rec.priority = priorityOf(ck.priority);
    rec.creation_ms = baseTimeMs(ck.creation);
    rec.last_access_ms = baseTimeMs(ck.last_access);
    rec.expires_ms = if (ck.has_expires != 0) baseTimeMs(ck.expires) else 0;

    g_cksync.put(&rec);
    return 1;
}

fn copyInto(buf: []u8, len: *usize, src: []const u8) bool {
    if (src.len > buf.len) return false;
    @memcpy(buf[0..src.len], src);
    len.* = src.len;
    return true;
}

/// IO THREAD. Null while nobody synchronises, so an unsubscribed
/// helper never even constructs the filter path.
fn onGetCookieAccessFilter(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
) callconv(.c) [*c]cef.cef_cookie_access_filter_t {
    releaseArg(browser);
    releaseArg(frame);
    releaseArg(request);
    if (!g_cksync.on.load(.acquire)) return null;
    return &cookie_access_filter;
}

/// CEF's cookie priority (-1/0/1) -> the wire's (0/1/2). Comparisons
/// rather than a switch for `sameSiteOf`'s reason: translate-c gives
/// the enum type a different signedness from its constants.
fn priorityOf(v: cef.cef_cookie_priority_t) u8 {
    const T = cef.cef_cookie_priority_t;
    if (v == @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_LOW))) return @intFromEnum(proto.CookiePriority.low);
    if (v == @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_HIGH))) return @intFromEnum(proto.CookiePriority.high);
    return @intFromEnum(proto.CookiePriority.medium);
}

fn cefPriorityOf(v: u8) cef.cef_cookie_priority_t {
    const T = cef.cef_cookie_priority_t;
    return switch (@as(proto.CookiePriority, @enumFromInt(v))) {
        .low => @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_LOW)),
        .high => @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_HIGH)),
        else => @as(T, @intCast(cef.CEF_COOKIE_PRIORITY_MEDIUM)),
    };
}

fn cefSameSiteOf(v: u8) cef.cef_cookie_same_site_t {
    const T = cef.cef_cookie_same_site_t;
    return switch (@as(proto.SameSite, @enumFromInt(v))) {
        .none => @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_NO_RESTRICTION)),
        .lax => @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_LAX_MODE)),
        .strict => @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_STRICT_MODE)),
        else => @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_UNSPECIFIED)),
    };
}

/// Unix epoch milliseconds -> a CEF base time (microseconds since the
/// Windows epoch). The exact inverse of `baseTimeMs`, so an expiry
/// survives a round trip through the wire and back into a jar.
fn msToBaseTime(ms: u64) cef.cef_basetime_t {
    const win_to_unix_us: i64 = 11_644_473_600 * std.time.us_per_s;
    var bt = std.mem.zeroes(cef.cef_basetime_t);
    bt.val = @as(i64, @intCast(ms)) * 1000 + win_to_unix_us;
    return bt;
}

/// Fill a `cef_cookie_t` from a wire record. The strings are OWNED by
/// the returned struct and must be cleared with `freeCefCookie`.
fn toCefCookie(ck: proto.SyncCookie) cef.cef_cookie_t {
    var out = std.mem.zeroes(cef.cef_cookie_t);
    out.size = @sizeOf(cef.cef_cookie_t);
    setStr(ck.name, &out.name);
    setStr(ck.value, &out.value);
    setStr(ck.domain, &out.domain);
    setStr(ck.path, &out.path);
    out.secure = if (ck.flags & proto.cookie_secure != 0) 1 else 0;
    out.httponly = if (ck.flags & proto.cookie_httponly != 0) 1 else 0;
    out.same_site = cefSameSiteOf(ck.same_site);
    out.priority = cefPriorityOf(ck.priority);
    if (ck.creation_ms != 0) out.creation = msToBaseTime(ck.creation_ms);
    if (ck.last_access_ms != 0) out.last_access = msToBaseTime(ck.last_access_ms);
    // A dropped expiry silently turns a persistent cookie into a
    // session cookie, which is the whole login gone at the next
    // restart; `has_expires` and `expires` travel together or not at
    // all.
    if (ck.expires_ms != 0 and ck.flags & proto.cookie_session == 0) {
        out.has_expires = 1;
        out.expires = msToBaseTime(ck.expires_ms);
    }
    return out;
}

fn freeCefCookie(ck: *cef.cef_cookie_t) void {
    cef.cef_string_utf16_clear(&ck.name);
    cef.cef_string_utf16_clear(&ck.value);
    cef.cef_string_utf16_clear(&ck.domain);
    cef.cef_string_utf16_clear(&ck.path);
}

/// One `visit_all_cookies` walk: the periodic reconcile, or one page
/// of a client's jar dump. Same refcount rule as `CookieJob` and for
/// the same reason — the visit takes ownership of the reference, and
/// the LAST release is both "the walk is over" and the free, so the
/// answer is composed there and nowhere else.
const SyncVisitJob = struct {
    /// FIRST FIELD: CEF is handed `&job.visitor`.
    visitor: cef.cef_cookie_visitor_t,
    refs: std.atomic.Value(u32),
    gpa: std.mem.Allocator,
    mode: Mode,
    context: u32,
    /// Dump only: the connection to answer and its request id.
    conn: u32,
    req: u32,
    /// Dump only: the index this page starts at, and where it ended.
    cursor: u32,
    next_cursor: u32 = 0,
    /// Cookies the walk saw, whether or not this page carried them.
    total: u32 = 0,
    more: bool = false,
    accessible: bool = true,
    /// Owned copies of everything the answer needs; the visitor's
    /// `cef_cookie_t` is only valid for the duration of one call.
    strings: std.ArrayList(u8) = .empty,
    recs: std.ArrayList(Rec) = .empty,
    bytes: usize = 0,

    const Mode = enum { reconcile, dump };
    const Span = struct { off: u32, len: u32 };

    const Rec = struct {
        name: Span,
        value: Span,
        domain: Span,
        path: Span,
        flags: u8,
        same_site: u8,
        priority: u8,
        creation_ms: u64,
        last_access_ms: u64,
        expires_ms: u64,
    };

    const Opts = struct {
        mode: Mode,
        context: u32,
        conn: u32,
        req: u32,
        cursor: u32,
    };

    fn start(gpa: std.mem.Allocator, mgr: *cef.cef_cookie_manager_t, opts: Opts) ?void {
        const visit = mgr.visit_all_cookies orelse return null;
        const job = gpa.create(SyncVisitJob) catch return null;
        job.* = .{
            .visitor = .{ .base = SyncJobRef.base(), .visit = syncJobVisit },
            .refs = .init(2),
            .gpa = gpa,
            .mode = opts.mode,
            .context = opts.context,
            .conn = opts.conn,
            .req = opts.req,
            .cursor = opts.cursor,
            .next_cursor = opts.cursor,
        };
        // Two references for `CookieJob.start`'s reason: the call
        // CONSUMES one and may drop it before returning.
        if (visit(mgr, &job.visitor) == 0) job.accessible = false;
        _ = SyncJobRef.release(&job.visitor.base);
        return {};
    }

    fn record(self: *SyncVisitJob, cookie: *const cef.cef_cookie_t) void {
        var name = Utf8.init(&cookie.name);
        defer name.free();
        var value = Utf8.init(&cookie.value);
        defer value.free();
        var domain = Utf8.init(&cookie.domain);
        defer domain.free();
        var path = Utf8.init(&cookie.path);
        defer path.free();

        const n = self.intern(name.slice()) orelse return;
        const v = self.intern(value.slice()) orelse return;
        const d = self.intern(domain.slice()) orelse return;
        const p = self.intern(path.slice()) orelse return;

        var flags: u8 = 0;
        if (cookie.secure != 0) flags |= proto.cookie_secure;
        if (cookie.httponly != 0) flags |= proto.cookie_httponly;
        if (cookie.has_expires == 0) flags |= proto.cookie_session;
        if (domain.slice().len != 0 and domain.slice()[0] == '.') flags |= proto.cookie_domain_scoped;

        self.recs.append(self.gpa, .{
            .name = n,
            .value = v,
            .domain = d,
            .path = p,
            .flags = flags,
            .same_site = sameSiteOf(cookie.same_site),
            .priority = priorityOf(cookie.priority),
            .creation_ms = baseTimeMs(cookie.creation),
            .last_access_ms = baseTimeMs(cookie.last_access),
            .expires_ms = if (cookie.has_expires != 0) baseTimeMs(cookie.expires) else 0,
        }) catch {};
        self.bytes += name.slice().len + value.slice().len + domain.slice().len + path.slice().len + 40;
    }

    fn intern(self: *SyncVisitJob, s: []const u8) ?Span {
        const off: u32 = @intCast(self.strings.items.len);
        self.strings.appendSlice(self.gpa, s) catch return null;
        return .{ .off = off, .len = @intCast(s.len) };
    }

    fn str(self: *const SyncVisitJob, sp: Span) []const u8 {
        return self.strings.items[sp.off..][0..sp.len];
    }

    fn cookieAt(self: *const SyncVisitJob, r: Rec) proto.SyncCookie {
        return .{
            .name = self.str(r.name),
            .value = self.str(r.value),
            .domain = self.str(r.domain),
            .path = self.str(r.path),
            .flags = r.flags,
            .same_site = r.same_site,
            .priority = r.priority,
            .creation_ms = r.creation_ms,
            .last_access_ms = r.last_access_ms,
            .expires_ms = r.expires_ms,
        };
    }

    /// A synthetic url for a reconciled cookie: the scheme its `secure`
    /// flag implies, the domain without its leading dot, and its path.
    /// It is what a client hands back as `cookie_apply.url`, so it has
    /// to be a url the ENGINE will accept for that (domain, path).
    fn urlFor(r: Rec, self: *const SyncVisitJob, buf: []u8) []const u8 {
        const dom_raw = self.str(r.domain);
        const dom = if (dom_raw.len != 0 and dom_raw[0] == '.') dom_raw[1..] else dom_raw;
        const scheme = if (r.flags & proto.cookie_secure != 0) "https://" else "http://";
        const path = self.str(r.path);
        return std.fmt.bufPrint(buf, "{s}{s}{s}", .{ scheme, dom, path }) catch "";
    }

    fn finish(self: *SyncVisitJob) void {
        const host = g_host orelse return;
        switch (self.mode) {
            .reconcile => self.finishReconcile(host),
            .dump => self.finishDump(host),
        }
    }

    /// Diff the walk against the shadow: emit what is new or changed,
    /// then emit a removal for every shadow entry the walk did not see.
    ///
    /// THE FIRST WALK OF A CONTEXT IS SILENT. A helper that just
    /// subscribed would otherwise replay its entire existing jar as
    /// "changes", which is noise at best and, with two instances
    /// subscribing at once, a burst of mutual applies at worst. The
    /// seed path for a new instance is `cookie_dump_req`, which is
    /// explicit, paged and asked for.
    fn finishReconcile(self: *SyncVisitJob, host: *Host) void {
        if (host.cookie_reconcile_busy > 0) host.cookie_reconcile_busy -= 1;
        if (!self.accessible) return;
        if (!host.cookieSyncOn()) return;
        const seeding = !host.shadowSeeded(self.context);

        for (host.cookie_shadow.items) |*sh| {
            if (sh.context == self.context) sh.seen = false;
        }
        var url_buf: [1024]u8 = undefined;
        for (self.recs.items) |r| {
            const ck = self.cookieAt(r);
            const idh = CookieShadow.identity(self.context, ck.domain, ck.path, ck.name);
            if (host.shadowFind(idh, self.context, ck.domain, ck.path, ck.name)) |sh| {
                sh.seen = true;
                if (sh.pending) continue;
                const vh = CookieShadow.valueHash(ck);
                if (sh.hash == vh) {
                    sh.adopt = false;
                    continue;
                }
                sh.hash = vh;
                if (sh.adopt) {
                    // The engine's own normalisation of what we just
                    // applied, not news. Adopt it once and go quiet.
                    sh.adopt = false;
                    continue;
                }
                if (seeding) continue;
                host.postSyncAll(proto.EvCookieChange{
                    .context = self.context,
                    .cause = @intFromEnum(proto.CookieCause.reconcile),
                    .removed = 0,
                    .url = urlFor(r, self, &url_buf),
                    .cookie = ck,
                });
                continue;
            }
            const sh = host.shadowInsert(idh, self.context, ck) orelse continue;
            sh.hash = CookieShadow.valueHash(ck);
            sh.seen = true;
            if (seeding) continue;
            host.postSyncAll(proto.EvCookieChange{
                .context = self.context,
                .cause = @intFromEnum(proto.CookieCause.reconcile),
                .removed = 0,
                .url = urlFor(r, self, &url_buf),
                .cookie = ck,
            });
        }

        // Everything the walk did not see is gone from the jar. This is
        // the ONLY observer that can see a deletion at all: no response
        // header carries `document.cookie = "...; max-age=0"`.
        var i: usize = 0;
        while (i < host.cookie_shadow.items.len) {
            const sh = &host.cookie_shadow.items[i];
            if (sh.context != self.context or sh.seen or sh.pending) {
                i += 1;
                continue;
            }
            if (!seeding) {
                const scheme = "https://";
                const dom = if (sh.domain.len != 0 and sh.domain[0] == '.') sh.domain[1..] else sh.domain;
                const url = std.fmt.bufPrint(&url_buf, "{s}{s}{s}", .{ scheme, dom, sh.path }) catch "";
                host.postSyncAll(proto.EvCookieChange{
                    .context = self.context,
                    .cause = @intFromEnum(proto.CookieCause.reconcile),
                    .removed = 1,
                    .url = url,
                    .cookie = .{
                        .name = sh.name,
                        .value = "",
                        .domain = sh.domain,
                        .path = sh.path,
                        .flags = 0,
                        .same_site = 0,
                        .priority = @intFromEnum(proto.CookiePriority.medium),
                        .creation_ms = 0,
                        .last_access_ms = 0,
                        .expires_ms = 0,
                    },
                });
            }
            sh.free(host.gpa);
            _ = host.cookie_shadow.orderedRemove(i);
        }
        host.markShadowSeeded(self.context);
    }

    fn finishDump(self: *SyncVisitJob, host: *Host) void {
        const start_at: usize = self.cursor;
        var page: std.ArrayList(proto.SyncCookie) = .empty;
        defer page.deinit(self.gpa);
        var bytes: usize = 0;
        var idx: usize = start_at;
        var more = false;
        while (idx < self.recs.items.len) : (idx += 1) {
            if (page.items.len >= proto.SYNC_DUMP_PAGE or bytes >= proto.SYNC_DUMP_PAGE_BYTES) {
                more = true;
                break;
            }
            const r = self.recs.items[idx];
            const ck = self.cookieAt(r);
            page.append(self.gpa, ck) catch {
                more = true;
                break;
            };
            bytes += ck.name.len + ck.value.len + ck.domain.len + ck.path.len + 40;
        }
        host.postSyncTo(self.conn, proto.EvCookieDump{
            .req = self.req,
            .context = self.context,
            .ok = if (self.accessible) 1 else 0,
            .cursor = self.cursor,
            .next_cursor = @intCast(idx),
            .more = if (more) 1 else 0,
            .total = @intCast(self.recs.items.len),
            .cookies = page.items,
        });
    }

    fn destroyOwned(self: *SyncVisitJob) void {
        self.finish();
        const gpa = self.gpa;
        self.strings.deinit(gpa);
        self.recs.deinit(gpa);
        gpa.destroy(self);
    }
};

const SyncJobRef = HeapRef(SyncVisitJob, "visitor");

fn syncJobVisit(
    self_: [*c]cef.cef_cookie_visitor_t,
    cookie: [*c]const cef.cef_cookie_t,
    _: c_int,
    _: c_int,
    delete_cookie: [*c]c_int,
) callconv(.c) c_int {
    if (self_ == null or cookie == null) return 0;
    const vis: *cef.cef_cookie_visitor_t = @ptrCast(self_);
    const job: *SyncVisitJob = @fieldParentPtr("visitor", vis);
    if (delete_cookie != null) delete_cookie.* = 0;
    job.total += 1;
    job.record(@ptrCast(cookie));
    return 1;
}

/// One `cookie_apply` in flight. Refcounted for `CookieJob`'s reason:
/// `set_cookie` / `delete_cookies` take ownership of the callback
/// reference and may drop it before returning.
///
/// The completion is what SETTLES the shadow, which is why the apply
/// carries the identity hash and a copy of the cookie's identity
/// strings rather than a pointer into the frame it came from.
const CookieApplyJob = struct {
    cb: Cb,
    refs: std.atomic.Value(u32),
    gpa: std.mem.Allocator,
    conn: u32,
    req: u32,
    context: u32,
    remove: bool,
    id_hash: u64,
    /// name / domain / path, concatenated; the spans below index it.
    ident: []u8,
    name_len: usize,
    domain_len: usize,
    path_len: usize,
    ok: bool = false,
    answered: bool = false,

    /// `set_cookie` and `delete_cookies` take DIFFERENT callback
    /// interfaces. They are laid out as a union of the two first
    /// fields so one job type serves both without a second struct;
    /// only the arm named by `remove` is ever handed to CEF.
    const Cb = extern union {
        set: cef.cef_set_cookie_callback_t,
        del: cef.cef_delete_cookies_callback_t,

        comptime {
            // `HeapRef.base` stamps `base.size = @sizeOf(Cb)` and the
            // ENGINE validates the size of the interface it was given.
            // The two callbacks are the same shape today (a base plus
            // one function pointer); if a CEF version ever changes one,
            // this fails to compile instead of handing the engine a
            // struct whose size is a lie.
            std.debug.assert(@sizeOf(cef.cef_set_cookie_callback_t) == @sizeOf(cef.cef_delete_cookies_callback_t));
        }
    };

    fn nameOf(self: *const CookieApplyJob) []const u8 {
        return self.ident[0..self.name_len];
    }
    fn domainOf(self: *const CookieApplyJob) []const u8 {
        return self.ident[self.name_len..][0..self.domain_len];
    }
    fn pathOf(self: *const CookieApplyJob) []const u8 {
        return self.ident[self.name_len + self.domain_len ..][0..self.path_len];
    }

    fn create(gpa: std.mem.Allocator, req: proto.CookieApply, conn: u32, idh: u64) ?*CookieApplyJob {
        const job = gpa.create(CookieApplyJob) catch return null;
        const total = req.cookie.name.len + req.cookie.domain.len + req.cookie.path.len;
        const ident = gpa.alloc(u8, total) catch {
            gpa.destroy(job);
            return null;
        };
        @memcpy(ident[0..req.cookie.name.len], req.cookie.name);
        @memcpy(ident[req.cookie.name.len..][0..req.cookie.domain.len], req.cookie.domain);
        @memcpy(ident[req.cookie.name.len + req.cookie.domain.len ..][0..req.cookie.path.len], req.cookie.path);
        job.* = .{
            .cb = undefined,
            .refs = .init(2),
            .gpa = gpa,
            .conn = conn,
            .req = req.req,
            .context = req.context,
            .remove = req.remove != 0,
            .id_hash = idh,
            .ident = ident,
            .name_len = req.cookie.name.len,
            .domain_len = req.cookie.domain.len,
            .path_len = req.cookie.path.len,
        };
        return job;
    }

    fn startSet(
        gpa: std.mem.Allocator,
        mgr: *cef.cef_cookie_manager_t,
        req: proto.CookieApply,
        conn: u32,
        idh: u64,
    ) ?void {
        const set = mgr.set_cookie orelse return null;
        const job = create(gpa, req, conn, idh) orelse return null;
        job.cb.set = .{ .base = ApplyRef.base(), .on_complete = onSetCookieComplete };

        var ck = toCefCookie(req.cookie);
        defer freeCefCookie(&ck);
        var u = std.mem.zeroes(cef.cef_string_t);
        setStr(req.url, &u);
        defer cef.cef_string_utf16_clear(&u);
        if (set(mgr, &u, &ck, @ptrCast(&job.cb.set)) == 0) {
            // The engine refused OUTRIGHT (a malformed url or a value
            // carrying a disallowed character). Its callback may never
            // run, so the second reference is what answers.
            job.ok = false;
        }
        _ = ApplyRef.release(@ptrCast(&job.cb.set.base));
        return {};
    }

    fn startDelete(
        gpa: std.mem.Allocator,
        mgr: *cef.cef_cookie_manager_t,
        req: proto.CookieApply,
        conn: u32,
        idh: u64,
    ) ?void {
        // NAMED deletion, not the url-only form: with both a url and a
        // name, CEF deletes host AND domain cookies matching both.
        // The url-only form deliberately spares domain cookies, which
        // is exactly how a logout fails to propagate.
        const del = mgr.delete_cookies orelse return null;
        const job = create(gpa, req, conn, idh) orelse return null;
        job.cb.del = .{ .base = ApplyRef.base(), .on_complete = onDeleteCookiesComplete };

        var u = std.mem.zeroes(cef.cef_string_t);
        setStr(req.url, &u);
        defer cef.cef_string_utf16_clear(&u);
        var n = std.mem.zeroes(cef.cef_string_t);
        setStr(req.cookie.name, &n);
        defer cef.cef_string_utf16_clear(&n);
        if (del(mgr, &u, &n, @ptrCast(&job.cb.del)) == 0) job.ok = false;
        _ = ApplyRef.release(@ptrCast(&job.cb.del.base));
        return {};
    }

    /// The LAST release: settle the shadow and answer. Both happen
    /// here and nowhere else, so every apply is answered exactly once
    /// on every path — the engine's callback, or its refusal.
    fn destroyOwned(self: *CookieApplyJob) void {
        if (g_host) |host| {
            host.settleApply(self.id_hash, self.context, .{
                .name = self.nameOf(),
                .value = "",
                .domain = self.domainOf(),
                .path = self.pathOf(),
                .flags = 0,
                .same_site = 0,
                .priority = 0,
                .creation_ms = 0,
                .last_access_ms = 0,
                .expires_ms = 0,
            }, self.ok);
            host.postApplyDone(
                self.conn,
                self.req,
                self.context,
                self.ok,
                if (self.ok) "" else "set-failed",
            );
        }
        const gpa = self.gpa;
        gpa.free(self.ident);
        gpa.destroy(self);
    }
};

const ApplyRef = HeapRef(CookieApplyJob, "cb");

fn onSetCookieComplete(self_: [*c]cef.cef_set_cookie_callback_t, success: c_int) callconv(.c) void {
    if (self_ == null) return;
    const job: *CookieApplyJob = @fieldParentPtr("cb", @as(*CookieApplyJob.Cb, @ptrCast(@alignCast(self_))));
    job.ok = success != 0;
}

fn onDeleteCookiesComplete(self_: [*c]cef.cef_delete_cookies_callback_t, num_deleted: c_int) callconv(.c) void {
    if (self_ == null) return;
    const job: *CookieApplyJob = @fieldParentPtr("cb", @as(*CookieApplyJob.Cb, @ptrCast(@alignCast(self_))));
    // A logout that deleted nothing because the cookie was already
    // gone is a SUCCESS: the instances agree, which is the whole point.
    job.ok = num_deleted >= 0;
}

/// CEF's SameSite enum -> the wire's engine-agnostic one. Written as
/// comparisons rather than a switch because translate-c gives the enum
/// TYPE a different signedness from its CONSTANTS.
fn sameSiteOf(v: cef.cef_cookie_same_site_t) u8 {
    const T = cef.cef_cookie_same_site_t;
    if (v == @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_NO_RESTRICTION))) return @intFromEnum(proto.SameSite.none);
    if (v == @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_LAX_MODE))) return @intFromEnum(proto.SameSite.lax);
    if (v == @as(T, @intCast(cef.CEF_COOKIE_SAME_SITE_STRICT_MODE))) return @intFromEnum(proto.SameSite.strict);
    return @intFromEnum(proto.SameSite.unspecified);
}

// ── filter-list subscription ────────────────────────────────────
//
// The helper is the only process here with an HTTPS stack, so keeping a
// subscribed EasyList current happens in this file. A `cef_urlrequest`
// rather than a view: navigating a view to a `.txt` RENDERS it, and
// scraping a rendered document back out is neither exact nor bounded.
//
// The refcount rule is `CookieJob`'s and is not optional: CEF's CToCpp
// wrappers TRANSFER the request and client references and may drop the
// client before the create call even returns. The fetch is born with a
// CEF reference plus a Host reference that lasts through retirement.

/// A subscription fetch in flight. One per url; there is no queue,
/// because the set is small and CEF runs them concurrently anyway.
const FilterFetch = struct {
    client: cef.cef_urlrequest_client_t,
    refs: std.atomic.Value(u32) = .init(1),
    gpa: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    request: ?*cef.cef_urlrequest_t = null,
    dest: []u8,
    url: []u8,
    serial: u32,
    status_ok: bool = false,
    response_ok: bool = false,
    completed: bool = false,
    /// Set when an append failed: a truncated list must never be
    /// written, because half a filter list is a working filter list
    /// that silently stops blocking half of what it used to.
    lost: bool = false,

    fn destroyOwned(self: *FilterFetch) void {
        self.body.deinit(self.gpa);
        self.gpa.free(self.dest);
        self.gpa.free(self.url);
        self.gpa.destroy(self);
    }
};

fn warnSub(what: []const u8, url: []const u8) void {
    std.debug.print("sketerm-web: filter list {s}: {s}\n", .{ url, what });
}

const SubRef = HeapRef(FilterFetch, "client");

fn subOnDownloadData(
    self_: [*c]cef.cef_urlrequest_client_t,
    request: [*c]cef.cef_urlrequest_t,
    data: ?*const anyopaque,
    len: usize,
) callconv(.c) void {
    defer releaseArg(request);
    const f: *FilterFetch = SubRef.owner(@ptrCast(self_));
    if (f.lost or len == 0) return;
    // A list that grows past this is not a list we want to load either;
    // `interceptReload` reads at most 16MB back off disk.
    if (len > filter_list_max or f.body.items.len > filter_list_max - len) {
        f.lost = true;
        if (request) |r| {
            if (r.*.cancel) |cancel| cancel(r);
        }
        return;
    }
    const bytes: [*]const u8 = @ptrCast(data orelse return);
    f.body.appendSlice(f.gpa, bytes[0..len]) catch {
        f.lost = true;
    };
}

fn subOnComplete(
    self_: [*c]cef.cef_urlrequest_client_t,
    request: [*c]cef.cef_urlrequest_t,
) callconv(.c) void {
    defer releaseArg(request);
    const f: *FilterFetch = SubRef.owner(@ptrCast(self_));
    f.status_ok = false;
    f.response_ok = false;
    if (request) |r| {
        const st = if (r.*.get_request_status) |g| g(r) else @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_FAILED));
        f.status_ok = st == @as(cef.cef_urlrequest_status_t, @intCast(cef.UR_SUCCESS));
        if (r.*.get_response) |gr| {
            if (gr(r)) |resp| {
                defer release(&resp.*.base);
                const code = if (resp.*.get_status) |gs| gs(resp) else 0;
                f.response_ok = code >= 200 and code < 300;
            }
        }
    }
    // Host.filterSubPump retires this after the callback returns. The
    // Host reference keeps it alive if CEF releases immediately.
    f.completed = true;
}

fn subOnUploadProgress(_: [*c]cef.cef_urlrequest_client_t, request: [*c]cef.cef_urlrequest_t, _: i64, _: i64) callconv(.c) void {
    releaseArg(request);
}
fn subOnDownloadProgress(
    self_: [*c]cef.cef_urlrequest_client_t,
    request: [*c]cef.cef_urlrequest_t,
    _: i64,
    total: i64,
) callconv(.c) void {
    defer releaseArg(request);
    if (total <= filter_list_max) return;
    const f: *FilterFetch = SubRef.owner(@ptrCast(self_));
    f.lost = true;
    if (request) |r| {
        if (r.*.cancel) |cancel| cancel(r);
    }
}
fn subGetAuthCredentials(
    _: [*c]cef.cef_urlrequest_client_t,
    _: c_int,
    _: [*c]const cef.cef_string_t,
    _: c_int,
    _: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
    callback: [*c]cef.cef_auth_callback_t,
) callconv(.c) c_int {
    // Never authenticate to a filter-list host: a subscription is a
    // public url, and a prompt here has no user to answer it.
    releaseArg(callback);
    return 0;
}

/// Start one fetch. Returns false when nothing was started.
fn filterSubFetch(host: *Host, url: []const u8, dest: []const u8, serial: u32) bool {
    // `cef_request_create` is a plain extern fn here, not an optional
    // function pointer like the struct members are.
    const req = cef.cef_request_create() orelse return false;
    var request_transferred = false;
    defer if (!request_transferred) release(&req.*.base);

    var u = std.mem.zeroes(cef.cef_string_t);
    setStr(url, &u);
    defer cef.cef_string_utf16_clear(&u);
    if (req.*.set_url) |set| set(req, &u);
    var method = std.mem.zeroes(cef.cef_string_t);
    setStr("GET", &method);
    defer cef.cef_string_utf16_clear(&method);
    if (req.*.set_method) |set| set(req, &method);
    if (req.*.set_flags) |set| set(req, cef.UR_FLAG_DISABLE_CACHE | cef.UR_FLAG_NO_RETRY_ON_5XX);

    host.filter_fetches.ensureUnusedCapacity(host.gpa, 1) catch return false;
    const f = host.gpa.create(FilterFetch) catch return false;
    const dest_owned = host.gpa.dupe(u8, dest) catch {
        host.gpa.destroy(f);
        return false;
    };
    const url_owned = host.gpa.dupe(u8, url) catch {
        host.gpa.free(dest_owned);
        host.gpa.destroy(f);
        return false;
    };
    f.* = .{
        .client = .{
            .base = SubRef.base(),
            .on_request_complete = subOnComplete,
            .on_upload_progress = subOnUploadProgress,
            .on_download_progress = subOnDownloadProgress,
            .on_download_data = subOnDownloadData,
            .get_auth_credentials = subGetAuthCredentials,
        },
        .gpa = host.gpa,
        .dest = dest_owned,
        .url = url_owned,
        .serial = serial,
    };

    // CEF consumes one reference and may release it before returning;
    // the Host owns the other until the next-loop retirement. The
    // request object is consumed by the same CToCpp wrapper too.
    f.refs.store(2, .release);
    request_transferred = true;
    const handle = cef.cef_urlrequest_create(req, &f.client, null);
    if (handle) |h| {
        f.request = h;
        host.filter_fetches.appendAssumeCapacity(f);
        return true;
    }
    _ = SubRef.release(&f.client.base);
    return false;
}

const filter_list_max: usize = 16 * 1024 * 1024;

fn subRules() u32 {
    g_int.acquire();
    defer g_int.release();
    return g_int.rules;
}

fn subIntervalMs(hours: u32) i64 {
    if (hours == 0) return std.math.maxInt(i64);
    return @as(i64, hours) * 3_600_000;
}

fn ensureFiltersDir(dir: [:0]const u8) bool {
    pathz.makeDirs(dir, 0o700) catch return false;
    return true;
}

fn subUrlWanted(urls: []const []u8, name: []const u8) bool {
    for (urls) |u| {
        var nb: [filtersub.MAX_NAME]u8 = undefined;
        const want = filtersub.cacheName(u, &nb) catch continue;
        if (std.mem.eql(u8, want, name)) return true;
    }
    return false;
}

fn filterSubApply(self: *Host, hours: u32, urls: []const []const u8) void {
    var next: std.ArrayList([]u8) = .empty;
    var adopted = false;
    defer if (!adopted) {
        for (next.items) |u| self.gpa.free(u);
        next.deinit(self.gpa);
    };
    var invalid: u16 = 0;
    for (urls) |u| {
        if (!filtersub.validUrl(u)) {
            invalid +|= 1;
            continue;
        }
        var duplicate = false;
        for (next.items) |have| {
            if (std.mem.eql(u8, have, u)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const dup = self.gpa.dupe(u8, u) catch {
            filterSubFailAll(self, urls.len);
            return;
        };
        next.append(self.gpa, dup) catch {
            self.gpa.free(dup);
            filterSubFailAll(self, urls.len);
            return;
        };
    }

    filterSubCancel(self);
    for (self.filter_sub_urls.items) |u| self.gpa.free(u);
    self.filter_sub_urls.deinit(self.gpa);
    self.filter_sub_urls = next;
    adopted = true;
    self.filter_sub_hours = hours;
    self.filter_sub_serial +%= 1;
    if (self.filter_sub_serial == 0) self.filter_sub_serial = 1;
    self.filter_sub_active = @intCast(self.filter_sub_urls.items.len);
    self.filter_sub_fetched = 0;
    self.filter_sub_updated = 0;
    self.filter_sub_failed = invalid;
    self.filter_sub_pending = 0;
    self.filter_sub_reload = false;
    self.filter_sub_batch_open = true;
    filterSubReconcile(self);
}

/// Answer a replace-all whose owned url copies could not be allocated:
/// the previous subscription set and schedule stay live, but the
/// completion frame is still posted (every request is answered) with
/// every requested url counted as failed.
fn filterSubFailAll(self: *Host, requested: usize) void {
    filterSubCancel(self);
    self.filter_sub_serial +%= 1;
    if (self.filter_sub_serial == 0) self.filter_sub_serial = 1;
    self.filter_sub_active = @intCast(@min(requested, std.math.maxInt(u16)));
    self.filter_sub_fetched = 0;
    self.filter_sub_updated = 0;
    self.filter_sub_failed = self.filter_sub_active;
    self.filter_sub_pending = 0;
    self.filter_sub_reload = false;
    self.filter_sub_batch_open = true;
    filterSubFinish(self, nowMs());
}

fn filterSubReconcile(self: *Host) void {
    var dir_buf: [4096]u8 = undefined;
    const dir = filtersDir(&dir_buf) orelse {
        self.filter_sub_failed +|= self.filter_sub_active;
        filterSubFinish(self, nowMs());
        return;
    };
    if (self.filter_sub_urls.items.len != 0 and !ensureFiltersDir(dir)) {
        self.filter_sub_failed +|= self.filter_sub_active;
        filterSubFinish(self, nowMs());
        return;
    }

    // Drop the caches of subscriptions that went away. Only ever OUR
    // exact cache/stage names, never a similarly-prefixed user file.
    if (c.opendir(dir.ptr)) |dp| {
        defer _ = c.closedir(dp);
        while (c.readdir(dp)) |entp| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entp.*.d_name)));
            const staged = filtersub.stageCacheName(name);
            const cache_name = staged orelse
                (if (filtersub.isCacheName(name)) name else continue);
            // A stage is always an orphan: the writer renames its own.
            if (staged == null and subUrlWanted(self.filter_sub_urls.items, cache_name)) continue;
            var p_buf: [4352:0]u8 = undefined;
            const p = std.fmt.bufPrintZ(&p_buf, "{s}/{s}", .{ dir, name }) catch continue;
            if (c.unlink(p.ptr) == 0 and filtersub.isCacheName(name)) self.filter_sub_reload = true;
        }
    }

    const now: i64 = @intCast(c.time(null));
    for (self.filter_sub_urls.items) |u| {
        var nb: [filtersub.MAX_NAME]u8 = undefined;
        const name = filtersub.cacheName(u, &nb) catch continue;
        var p_buf: [4352:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&p_buf, "{s}/{s}", .{ dir, name }) catch continue;
        var st: c.struct_stat = undefined;
        // Darwin spells it st_mtimespec; the same @hasField idiom guards
        // every other stat site in the repo, and this was the one that
        // would have blocked a macOS build of the helper.
        const mtime: i64 = if (c.stat(path.ptr, &st) == 0)
            @intCast((if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec).tv_sec)
        else
            0;
        // A missing file is always due, whatever the interval says --
        // otherwise `filter_update_hours = 0` would mean "subscribe to
        // this and never actually get it".
        if (mtime != 0 and !filtersub.isStale(now, mtime, self.filter_sub_hours)) continue;
        self.filter_sub_fetched +|= 1;
        if (filterSubFetch(self, u, path, self.filter_sub_serial)) {
            self.filter_sub_pending +|= 1;
        } else {
            self.filter_sub_failed +|= 1;
        }
    }
    if (self.filter_sub_pending == 0) filterSubFinish(self, nowMs());
}

fn filterSubFinish(self: *Host, now_ms: i64) void {
    if (!self.filter_sub_batch_open) return;
    if (self.filter_sub_reload and !interceptReload(self.gpa, self.intercept_extra.items)) self.filter_sub_failed +|= 1;
    self.filter_sub_batch_open = false;
    self.filter_sub_next_ms = if (self.filter_sub_stopping)
        std.math.maxInt(i64)
    else
        now_ms +| subIntervalMs(self.filter_sub_hours);
    self.post(proto.EvInterceptSubscribeDone{
        .serial = self.filter_sub_serial,
        .active = self.filter_sub_active,
        .fetched = self.filter_sub_fetched,
        .updated = self.filter_sub_updated,
        .failed = self.filter_sub_failed,
        .rules = subRules(),
    });
}

fn filterSubPump(self: *Host, now_ms: i64) void {
    var i: usize = 0;
    while (i < self.filter_fetches.items.len) {
        const f = self.filter_fetches.items[i];
        if (!f.completed) {
            i += 1;
            continue;
        }
        const current = self.filter_sub_batch_open and f.serial == self.filter_sub_serial;
        if (current) {
            if (self.filter_sub_pending > 0) self.filter_sub_pending -= 1;
            if (!f.lost and f.status_ok and f.response_ok and filtersub.looksLikeFilterList(f.body.items)) {
                atomicwrite.writeFile(f.dest, f.body.items, 0o600) catch {
                    warnSub("could not be written; keeping the previous copy", f.url);
                    self.filter_sub_failed +|= 1;
                    retireFilterFetch(self, i);
                    continue;
                };
                self.filter_sub_updated +|= 1;
                self.filter_sub_reload = true;
            } else {
                warnSub("fetch failed or returned an invalid list; keeping the previous copy", f.url);
                self.filter_sub_failed +|= 1;
            }
        }
        retireFilterFetch(self, i);
    }
    if (self.filter_sub_batch_open and self.filter_sub_pending == 0) filterSubFinish(self, now_ms);
}

fn retireFilterFetch(self: *Host, i: usize) void {
    const f = self.filter_fetches.swapRemove(i);
    if (f.request) |r| release(&r.base);
    f.request = null;
    _ = SubRef.release(&f.client.base);
}

fn filterSubCancel(self: *Host) void {
    for (self.filter_fetches.items) |f| {
        if (f.request) |r| {
            if (r.cancel) |cancel| cancel(r);
        }
    }
    self.filter_sub_batch_open = false;
    self.filter_sub_pending = 0;
}

fn filterSubTick(self: *Host, now_ms: i64) void {
    if (self.filter_sub_stopping or self.filter_sub_batch_open or self.filter_sub_hours == 0 or now_ms < self.filter_sub_next_ms) return;
    self.filter_sub_serial +%= 1;
    if (self.filter_sub_serial == 0) self.filter_sub_serial = 1;
    self.filter_sub_active = @intCast(self.filter_sub_urls.items.len);
    self.filter_sub_fetched = 0;
    self.filter_sub_updated = 0;
    self.filter_sub_failed = 0;
    self.filter_sub_pending = 0;
    self.filter_sub_reload = false;
    self.filter_sub_batch_open = true;
    filterSubReconcile(self);
}

pub fn filterSubShutdown(self: *Host) void {
    self.filter_sub_stopping = true;
    filterSubCancel(self);
}

pub fn filterSubBusy(self: *const Host) bool {
    return self.filter_fetches.items.len != 0;
}

fn filterSubAbandon(self: *Host) void {
    filterSubShutdown(self);
    while (self.filter_fetches.items.len != 0) {
        const f = self.filter_fetches.pop().?;
        if (f.request) |r| release(&r.base);
        f.request = null;
        _ = SubRef.release(&f.client.base);
    }
}

const JobRef = HeapRef(CookieJob, "visitor");

fn jobVisit(
    self_: [*c]cef.cef_cookie_visitor_t,
    cookie: [*c]const cef.cef_cookie_t,
    count: c_int,
    total: c_int,
    delete_cookie: [*c]c_int,
) callconv(.c) c_int {
    _ = count;
    _ = total;
    if (self_ == null or cookie == null) return 0;
    const vis: *cef.cef_cookie_visitor_t = @ptrCast(self_);
    const job: *CookieJob = @fieldParentPtr("visitor", vis);
    const ck: *const cef.cef_cookie_t = @ptrCast(cookie);
    job.total += 1;
    switch (job.mode) {
        .list => job.record(ck),
        .delete_all => {
            if (delete_cookie != null) delete_cookie.* = 1;
            job.removed += 1;
        },
        .delete_named => {
            if (job.matches(ck)) {
                if (delete_cookie != null) delete_cookie.* = 1;
                job.removed += 1;
            }
        },
    }
    return 1;
}

// ---------------------------------------------------------------------
// Request interception (capability "intercept")
// ---------------------------------------------------------------------
//
// THE ONE EXCEPTION to this file's single-thread story: CEF delivers
// `on_before_resource_load` / `on_resource_load_complete` on its IO
// THREAD, not inside `pump()`. That is also the whole point — a
// blocking verdict must not round-trip anywhere (uBO's lesson: cross-
// process blocking latency is the hard part), so the filter engine
// lives in this process and the verdict is computed inline where the
// request already is. Everything the IO thread touches lives in the
// `g_int` registry below, guarded by the repo's spinlock pattern
// (src/ui/panel/events.zig documents why a spinlock and not a mutex),
// and NOTHING in it allocates on the IO thread: log entries are
// fixed-size, appended into per-view rings the MAIN thread allocated.
// The main thread only ever swaps whole engines / registers slots
// under the same lock. Host.views is never read from the IO thread.

/// Built-in seed list: a handful of universally safe ad/tracker hosts,
/// so blocking demonstrably works with zero setup. Typeless rules, so
/// none of them can ever block a top-level navigation.
const seed_filter_list =
    \\! sketerm built-in seed filters (ad/tracker hosts)
    \\||doubleclick.net^
    \\||googlesyndication.com^
    \\||googleadservices.com^
    \\||google-analytics.com^
    \\||adservice.google.com^
    \\||googletagservices.com^
    \\||scorecardresearch.com^
    \\||quantserve.com^
    \\||taboola.com^
    \\||outbrain.com^
    \\||criteo.com^
    \\||adnxs.com^
    \\||hotjar.com^$third-party
    \\
;

/// Log-ring depth per view. At ~300 bytes per entry a view costs
/// ~38KB, allocated only while the view lives.
const NLOG = 128;

/// Concurrent views the registry can track. A view past the cap still
/// gets verdicts (global engine + global enable), just no log/badge —
/// and can hold no POLICY, which is why the client refuses a policied
/// open past it (the constant is wire-adjacent and lives in protocol).
const MAX_ISLOTS = proto.MAX_POLICY_VIEWS;

/// Longest URL kept in a log entry; the tail is truncated, the
/// VERDICT always sees the full url.
const LOG_URL_MAX = 256;

const LogEntry = struct {
    seq: u32 = 0,
    req_id: u64 = 0,
    start_ms: i64 = 0,
    dur_ms: u32 = 0,
    status: u16 = 0,
    size: u32 = 0,
    rtype: u8 = 0,
    blocked: bool = false,
    done: bool = false,
    /// `proto.NetReason` byte; nonzero only on blocked entries.
    reason: u8 = 0,
    method_len: u8 = 0,
    method: [8]u8 = @splat(0),
    url_len: u16 = 0,
    url: [LOG_URL_MAX]u8 = @splat(0),
};

const ISlot = struct {
    used: bool = false,
    cef_id: c_int = 0,
    view_id: u32 = 0,
    enabled: bool = true,
    blocked: u32 = 0,
    total: u32 = 0,
    /// Counters changed since the last pushed `intercept_status`; the
    /// poll loop flushes at most one frame per view per iteration, so
    /// an ad-heavy page cannot stream a frame per request.
    dirty: bool = false,
    next_seq: u32 = 1,
    widx: usize = 0,
    ring: ?*[NLOG]LogEntry = null,
    /// Enforced policy, or null (the common case: one branch on the hot
    /// path and nothing else). Swapped whole by the MAIN thread under
    /// the lock, freed outside it, like the filter engine.
    pol: ?*netpolicy.Policy = null,
    /// Live accounting for `pol`; IO-thread-mutated under the lock.
    pc: netpolicy.Counters = .{},
    /// Accounting changed since the last pushed `ev_net_policy`.
    pol_dirty: bool = false,
    /// The deadline sweep already issued its one `stop_load`.
    deadline_stopped: bool = false,
};

const Intercept = struct {
    lock: SpinLock = .{},
    engine: ?*filter.Engine = null,
    /// IO-thread matches in flight against `engine` OUTSIDE the lock
    /// (`pinEngine`/`unpinEngine`). A match is a linear scan over tens
    /// of thousands of rules, far too long for a spinlock the main
    /// thread spins on, so the reader pins the engine and walks it
    /// unlocked; `retireEngine` waits for the pins to drain before
    /// freeing a swapped-out engine.
    readers: u32 = 0,
    global_enabled: bool = true,
    rules: u32 = 0,
    slots: [MAX_ISLOTS]ISlot = @splat(.{}),

    fn acquire(self: *Intercept) void {
        self.lock.lock();
    }

    fn release(self: *Intercept) void {
        self.lock.unlock();
    }

    /// The slot registered for a CEF browser id. Under the lock.
    fn slotByCef(self: *Intercept, cef_id: c_int) ?*ISlot {
        for (&self.slots) |*s| {
            if (s.used and s.cef_id == cef_id) return s;
        }
        return null;
    }

    /// Under the lock: the current engine, pinned so that a concurrent
    /// swap cannot free it until `unpinEngine`.
    fn pinEngine(self: *Intercept) ?*filter.Engine {
        const e = self.engine orelse return null;
        self.readers += 1;
        return e;
    }

    /// Takes the lock itself; never call while holding it.
    fn unpinEngine(self: *Intercept) void {
        self.acquire();
        defer self.release();
        self.readers -= 1;
    }

    /// Free an engine taken out of `engine` once no pinned reader can
    /// still be walking it. NOT under the lock: it waits for the IO
    /// thread's in-flight matches, which is bounded CPU work, and the
    /// wait must not block those readers' own `unpinEngine`.
    fn retireEngine(self: *Intercept, gpa: std.mem.Allocator, old: *filter.Engine) void {
        while (true) {
            self.acquire();
            const busy = self.readers != 0;
            self.release();
            if (!busy) break;
            std.atomic.spinLoopHint();
        }
        old.deinit();
        gpa.destroy(old);
    }
};

var g_int: Intercept = .{};

/// Register a view in the intercept registry (main thread; idempotent
/// per view id — `onAfterCreated` and `createViewAt` both call it, so
/// a load racing `create_browser_sync`'s return is still attributed).
fn interceptRegister(gpa: std.mem.Allocator, view_id: u32, cef_id: c_int) void {
    if (cef_id == 0) return;
    const ring = gpa.create([NLOG]LogEntry) catch return;
    ring.* = @splat(.{});
    var keep = false;
    defer if (!keep) gpa.destroy(ring);
    g_int.acquire();
    defer g_int.release();
    var free_slot: ?*ISlot = null;
    for (&g_int.slots) |*s| {
        if (s.used and s.view_id == view_id) {
            // Adopt a slot minted by a pre-create `net_policy_set` /
            // `intercept_set`: attach the missing ring instead of
            // leaving the view logless.
            s.cef_id = cef_id;
            if (s.ring == null) {
                s.ring = ring;
                keep = true;
            }
            return;
        }
        if (!s.used and free_slot == null) free_slot = s;
    }
    const s = free_slot orelse return;
    s.* = .{ .used = true, .cef_id = cef_id, .view_id = view_id, .ring = ring };
    keep = true;
}

/// MAIN thread. The slot for `view_id`, found or created (ring
/// included, `cef_id` 0 until `interceptRegister` attributes it). Slot
/// lifecycle is main-thread-only — the IO thread only ever READS the
/// table — so the returned pointer stays valid; mutate its fields under
/// the lock.
fn interceptSlotFor(gpa: std.mem.Allocator, view_id: u32) ?*ISlot {
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.slots) |*s| {
            if (s.used and s.view_id == view_id) return s;
        }
    }
    const ring = gpa.create([NLOG]LogEntry) catch return null;
    ring.* = @splat(.{});
    var keep = false;
    defer if (!keep) gpa.destroy(ring);
    g_int.acquire();
    defer g_int.release();
    var free_slot: ?*ISlot = null;
    for (&g_int.slots) |*s| {
        if (s.used and s.view_id == view_id) return s;
        if (!s.used and free_slot == null) free_slot = s;
    }
    const s = free_slot orelse return null;
    s.* = .{ .used = true, .cef_id = 0, .view_id = view_id, .ring = ring };
    keep = true;
    return s;
}

fn interceptUnregister(gpa: std.mem.Allocator, view_id: u32) void {
    var ring: ?*[NLOG]LogEntry = null;
    var pol: ?*netpolicy.Policy = null;
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.slots) |*s| {
            if (!s.used or s.view_id != view_id) continue;
            ring = s.ring;
            pol = s.pol;
            s.* = .{};
            break;
        }
    }
    // Freed OUTSIDE the lock: nobody can reach them any more, and the
    // IO thread re-resolves its slot on every callback.
    if (ring) |r| gpa.destroy(r);
    if (pol) |p| p.deinit(gpa);
}

/// Read one file whole (bounded); caller frees.
fn readFileBounded(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize) ?[]u8 {
    return readFileBoundedAlloc(gpa, path, max) catch null;
}

/// Error-returning so the `errdefer` runs. As a `?[]u8` body, a read
/// error or an over-cap file returned null with the partial read still
/// on the heap.
fn readFileBoundedAlloc(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize) ![]u8 {
    const f = c.fopen(path, "rb") orelse return error.OpenFailed;
    defer _ = c.fclose(f);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) {
            if (c.ferror(f) != 0) return error.ReadFailed;
            break;
        }
        if (n > max -| list.items.len) return error.StreamTooLong;
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}

/// $XDG_CONFIG_HOME/sketerm/filters (or ~/.config/...), NUL-terminated
/// into `buf`.
fn filtersDir(buf: []u8) ?[:0]const u8 {
    if (c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const base = std.mem.span(xdg);
        if (base.len != 0)
            return std.fmt.bufPrintZ(buf, "{s}/sketerm/filters", .{base}) catch null;
    }
    const home = c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.config/sketerm/filters", .{std.mem.span(home)}) catch null;
}

/// Build a fresh engine from the seed list, every *.txt in the config
/// filters dir, and `extra_paths`, then swap it in. Main thread only.
fn interceptReload(gpa: std.mem.Allocator, extra_paths: []const []const u8) bool {
    const eng = gpa.create(filter.Engine) catch return false;
    eng.* = filter.Engine.init(gpa);
    var ok = true;
    eng.addList(seed_filter_list) catch {
        ok = false;
    };

    var dir_buf: [4096]u8 = undefined;
    if (filtersDir(&dir_buf)) |dir| {
        if (c.opendir(dir.ptr)) |dp| {
            defer _ = c.closedir(dp);
            while (c.readdir(dp)) |entp| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entp.*.d_name)));
                if (!std.mem.endsWith(u8, name, ".txt")) continue;
                var path_buf: [4352:0]u8 = undefined;
                const p = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
                const text = readFileBounded(gpa, p.ptr, 16 * 1024 * 1024) orelse continue;
                eng.addList(text) catch {
                    gpa.free(text);
                    ok = false;
                    break;
                };
                gpa.free(text);
            }
        }
    }
    for (extra_paths) |path| {
        var path_buf: [4352:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch continue;
        const text = readFileBounded(gpa, p.ptr, 16 * 1024 * 1024) orelse continue;
        eng.addList(text) catch {
            gpa.free(text);
            ok = false;
            break;
        };
        gpa.free(text);
    }
    if (!ok) {
        eng.deinit();
        gpa.destroy(eng);
        return false;
    }

    var old: ?*filter.Engine = null;
    {
        g_int.acquire();
        defer g_int.release();
        old = g_int.engine;
        g_int.engine = eng;
        g_int.rules = eng.count;
        for (&g_int.slots) |*s| {
            if (s.used) s.dirty = true;
        }
    }
    if (old) |o| g_int.retireEngine(gpa, o);
    return true;
}

/// Load the initial filter set (seed + config dir). Called once at
/// helper startup, before any view exists.
pub fn interceptInit(gpa: std.mem.Allocator) void {
    _ = interceptReload(gpa, &.{});
    wreqInitPipe();
    wreqReadTimeoutEnv();
}

/// Free the engine and any leftover rings (client gone, views already
/// destroyed).
pub fn interceptDeinit(gpa: std.mem.Allocator) void {
    // Before anything else: a held request must not outlive the table
    // that owns its callback.
    webrequestDeinit();
    var old: ?*filter.Engine = null;
    var pols: [MAX_ISLOTS]?*netpolicy.Policy = @splat(null);
    var rings: [MAX_ISLOTS]?*[NLOG]LogEntry = @splat(null);
    {
        g_int.acquire();
        defer g_int.release();
        old = g_int.engine;
        g_int.engine = null;
        g_int.rules = 0;
        for (&g_int.slots, 0..) |*s, i| {
            if (s.used) {
                rings[i] = s.ring;
                pols[i] = s.pol;
                s.* = .{};
            }
        }
    }
    // Detached under the lock, freed outside it: an allocator call is
    // not spinlock work, and nothing can reach a ring once its slot
    // is cleared.
    for (rings) |r| {
        if (r) |ring| gpa.destroy(ring);
    }
    for (pols) |p| {
        if (p) |pol| pol.deinit(gpa);
    }
    if (old) |o| g_int.retireEngine(gpa, o);
}

/// Whether the shield allows cosmetic hiding for `view_id`: global
/// AND per-view, exactly the network-verdict gate. Main thread.
fn cosmeticEnabledFor(view_id: u32) bool {
    g_int.acquire();
    defer g_int.release();
    if (!g_int.global_enabled) return false;
    for (&g_int.slots) |*s| {
        if (s.used and s.view_id == view_id) return s.enabled;
    }
    return true;
}

/// The compiled element-hiding sheet for one host, or null when there
/// is nothing to hide. MAIN THREAD ONLY: the engine pointer is read
/// under the lock but walked outside it, which is safe because engine
/// swaps (`interceptReload`) happen on this same thread — the IO
/// thread only ever reads. Caller frees.
fn cosmeticCss(gpa: std.mem.Allocator, host: []const u8) ?[]u8 {
    var eng: ?*filter.Engine = null;
    {
        g_int.acquire();
        defer g_int.release();
        eng = g_int.engine;
    }
    const e = eng orelse return null;
    const css = e.cosmeticFor(gpa, host) catch return null;
    if (css.len == 0) {
        gpa.free(css);
        return null;
    }
    return css;
}

/// CEF's resource type as the wire's engine-agnostic byte.
fn rtypeOf(t: cef.cef_resource_type_t) filter.RType {
    return switch (t) {
        cef.RT_MAIN_FRAME => .document,
        cef.RT_SUB_FRAME => .subdocument,
        cef.RT_STYLESHEET => .stylesheet,
        cef.RT_SCRIPT => .script,
        cef.RT_IMAGE, cef.RT_FAVICON => .image,
        cef.RT_FONT_RESOURCE => .font,
        cef.RT_XHR => .xhr,
        cef.RT_MEDIA => .media,
        cef.RT_PING, cef.RT_CSP_REPORT => .ping,
        else => .other,
    };
}

/// UTF-8 of a userfree CEF string result, into `buf` (truncated).
fn jsonU32(o: std.json.ObjectMap, key: []const u8) u32 {
    const v = o.get(key) orelse return 0;
    return switch (v) {
        .integer => |i| @intCast(@max(i, 0)),
        else => 0,
    };
}

fn jsonBool(o: std.json.ObjectMap, key: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .bool and v.bool;
}

fn jsonStrField(o: std.json.ObjectMap, key: []const u8) []const u8 {
    const v = o.get(key) orelse return "";
    return if (v == .string) v.string else "";
}

fn userfreeInto(raw: cef.cef_string_userfree_t, buf: []u8) []const u8 {
    if (raw == null) return "";
    defer cef.cef_string_userfree_utf16_free(raw);
    var s = Utf8.init(raw);
    defer s.free();
    const src = s.slice();
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

/// IO THREAD. The verdict and the log append, inline with the request.
fn onBeforeResourceLoad(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    callback: [*c]cef.cef_callback_t,
) callconv(.c) cef.cef_return_value_t {
    defer releaseArg(browser);
    defer releaseArg(frame);
    // A hold KEEPS `request` and `callback` (the answer path releases
    // them); every other exit gives their references back here.
    var held = false;
    defer if (!held) {
        releaseArg(request);
        releaseArg(callback);
    };
    const req: *cef.cef_request_t = request orelse return cef.RV_CONTINUE;
    // Service-worker / urlrequest traffic has no browser and thus no
    // view to attribute it to; it passes unfiltered (matching without
    // a first-party context would misapply domain=/third-party rules).
    const b: *cef.cef_browser_t = browser orelse return cef.RV_CONTINUE;
    const gi = b.get_identifier orelse return cef.RV_CONTINUE;
    const cef_id = gi(b);

    var url_raw: [2048]u8 = undefined;
    var url_buf: [2048]u8 = undefined;
    const gu = req.get_url orelse return cef.RV_CONTINUE;
    const url_unf = userfreeInto(gu(req), &url_raw);

    // AN EXTENSION'S OWN ORIGIN IS NEVER FILTERED. `filter.hostOf` sees
    // a 16-hex-digit host it cannot know anything about, the seed engine
    // has no rule for it — and yet the load came back
    // ERR_BLOCKED_BY_CLIENT, because a `chrome-extension://` load is not
    // web traffic and must not enter this path at all. Firefox draws the
    // same line: webRequest never sees a `moz-extension://` load, and a
    // filter list that could block an extension's own background page
    // would disable the extension at random.
    if (std.mem.startsWith(u8, url_unf, ext_scheme ++ "://")) return cef.RV_CONTINUE;

    const url = filter.foldUrl(&url_buf, url_unf);
    const host = filter.hostOf(url);

    var fp_raw: [512]u8 = undefined;
    var fp_buf: [512]u8 = undefined;
    var doc_host: []const u8 = "";
    if (req.get_first_party_for_cookies) |gfp| {
        const fp = filter.foldUrl(&fp_buf, userfreeInto(gfp(req), &fp_raw));
        doc_host = filter.hostOf(fp);
    }

    var method_buf: [8]u8 = undefined;
    var method: []const u8 = "";
    if (req.get_method) |gm| method = userfreeInto(gm(req), &method_buf);

    const rtype = if (req.get_resource_type) |grt| rtypeOf(grt(req)) else filter.RType.other;
    const req_id: u64 = if (req.get_identifier) |gid| gid(req) else 0;
    const now = nowMs();

    var verdict = false;
    var shield_on = true;
    var view_id: u32 = 0;
    // The filter match runs OUTSIDE the lock against a pinned engine:
    // it is a linear scan over every generic rule, and the main thread
    // would spin for the whole of it. The slot is looked up again for
    // the policy + log step below, since a view can be unregistered in
    // between and a pointer into the table must not be carried across.
    var eng: ?*filter.Engine = null;
    {
        g_int.acquire();
        defer g_int.release();
        const slot = g_int.slotByCef(cef_id);
        if (slot) |s| view_id = s.view_id;
        shield_on = g_int.global_enabled and (if (slot) |s| s.enabled else true);
        if (shield_on and host.len > 0) eng = g_int.pinEngine();
    }
    if (eng) |e| {
        verdict = e.match(.{ .url = url, .host = host, .doc_host = doc_host, .rtype = rtype });
        g_int.unpinEngine();
    }
    {
        g_int.acquire();
        defer g_int.release();
        const slot = g_int.slotByCef(cef_id);
        // PRECEDENCE, step 2: the enforced POLICY. Runs only past the
        // filter (a filter cancel is final and keeps its own reason)
        // and never for a slotless request (service workers /
        // urlrequest traffic — documented unpoliced, matching the
        // filter's own exemption above).
        var pol_reason: proto.NetReason = .none;
        if (!verdict) {
            if (slot) |s| {
                if (s.pol) |pol| {
                    const is_top = rtype == .document;
                    // CEF keeps the request identifier across a server
                    // redirect chain (measured on CEF 151): a live ring
                    // entry with this id means this request IS the
                    // redirected re-issue.
                    var is_hop = false;
                    if (s.ring) |ring| {
                        for (ring) |*e| {
                            if (e.seq != 0 and e.req_id == req_id and !e.done) {
                                is_hop = true;
                                break;
                            }
                        }
                    }
                    pol_reason = netpolicy.decide(pol, &s.pc, .{
                        .host = host,
                        .scheme = netpolicy.schemeOf(url),
                        .rtype = rtype,
                        .is_top = is_top,
                        .is_redirect_hop = is_hop,
                    }, now);
                    if (pol_reason == .none) {
                        netpolicy.commit(&s.pc, is_top);
                    } else {
                        netpolicy.deny(&s.pc, pol_reason);
                        verdict = true;
                    }
                    s.pol_dirty = true;
                }
            }
        }
        if (slot) |s| {
            s.total +%= 1;
            if (verdict) s.blocked +%= 1;
            s.dirty = true;
            if (s.ring) |ring| {
                const e = &ring[s.widx];
                s.widx = (s.widx + 1) % NLOG;
                e.* = .{
                    .seq = s.next_seq,
                    .req_id = req_id,
                    .start_ms = now,
                    .rtype = @intFromEnum(rtype),
                    .blocked = verdict,
                    // A blocked entry never completes; it is final now.
                    .done = verdict,
                    .reason = if (pol_reason != .none)
                        @intFromEnum(pol_reason)
                    else if (verdict)
                        @intFromEnum(proto.NetReason.filter_list)
                    else
                        0,
                };
                s.next_seq +%= 1;
                if (s.next_seq == 0) s.next_seq = 1;
                e.method_len = @intCast(@min(method.len, e.method.len));
                @memcpy(e.method[0..e.method_len], method[0..e.method_len]);
                e.url_len = @intCast(@min(url_unf.len, e.url.len));
                @memcpy(e.url[0..e.url_len], url_unf[0..e.url_len]);
            }
        }
    }
    // PRECEDENCE, step 1: the native engine's cancel is FINAL, and a
    // policy denial is equally final. An extension is never asked about
    // a request either already refused, and never asked at all while
    // the shield is off.
    if (verdict) return cef.RV_CANCEL;
    if (!shield_on) return cef.RV_CONTINUE;

    held = wreqConsider(req, callback, url_unf, method, wreqTypeOf(
        if (req.get_resource_type) |grt| grt(req) else cef.RT_SUB_RESOURCE,
    ), view_id);
    return if (held) cef.RV_CONTINUE_ASYNC else cef.RV_CONTINUE;
}

/// IO THREAD. `onHeadersReceived`, observationally.
///
/// MEASURED ENGINE LIMITATION, and the reason this is not a hold:
/// `cef_resource_request_handler_t::on_resource_response` takes NO
/// `cef_callback_t` and returns an int — there is no
/// `RV_CONTINUE_ASYNC` equivalent anywhere on the response path, so the
/// request cannot be paused while a listener in another process
/// answers. The listener therefore RUNS and SEES the real response
/// headers, but a `responseHeaders` array it returns is counted and
/// dropped rather than applied. The alternative — taking the whole load
/// over with our own `cef_resource_handler_t` and re-issuing it through
/// `cef_urlrequest` — would put credentials, cookies, ranges and
/// streaming back in our hands, which is a far bigger correctness
/// surface than the feature buys. smoke-web stage 34d is the canary.
fn onResourceResponse(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    defer releaseArg(response);
    const req: *cef.cef_request_t = request orelse return 0;
    if (!webrequest.any_listeners.load(.acquire)) return 0;

    var url_raw: [2048]u8 = undefined;
    const gu = req.get_url orelse return 0;
    const url = userfreeInto(gu(req), &url_raw);
    const rtype = wreqTypeOf(if (req.get_resource_type) |grt| grt(req) else cef.RT_SUB_RESOURCE);

    var ext_buf: [webrequest.MAX_ID]u8 = undefined;
    var ext_len: usize = 0;
    var bg_view: u32 = 0;
    var need_hdr = webrequest.Need.none();
    {
        webrequest.acquire();
        defer webrequest.release();
        for (&webrequest.slots) |*s| {
            if (!s.used) continue;
            const reg = s.reg orelse continue;
            const nh = webrequest.needFor(reg, .headers_received, url, rtype);
            if (nh.isNone()) continue;
            ext_len = s.id_len;
            @memcpy(ext_buf[0..ext_len], s.idSlice());
            bg_view = s.bg_view;
            need_hdr = nh;
            break;
        }
    }
    if (ext_len == 0 or bg_view == 0) return 0;

    var hdr_buf: [HOLD_HDR_MAX]u8 = undefined;
    var hdr_len: u16 = 0;
    if (response) |resp| hdr_len = wreqResponseHeadersJson(resp, &hdr_buf);

    g_wreq.acquire();
    var slot: ?*Hold = null;
    for (&g_wreq.holds) |*h| {
        if (!h.used) {
            slot = h;
            break;
        }
    }
    const st = wstatFor(ext_buf[0..ext_len]);
    if (st) |s| {
        s.matched +%= 1;
        // Counted here, at the only moment we know a listener will be
        // told about headers it cannot change.
        s.headers_received_dropped +%= 1;
    }
    if (slot) |h| {
        h.* = .{
            .used = true,
            .hid = g_wreq.next_hid,
            .ext = if (st) |s| (@intFromPtr(s) - @intFromPtr(&g_wreq.stats[0])) / @sizeOf(WStat) else 0,
            .bg_view = bg_view,
            .event = .headers_received,
            .start_us = nowUs(),
            .deadline_ms = nowMs() + g_wreq.timeout_ms,
            .hdr_len = hdr_len,
            .want_request_headers = true,
            .rtype = @intFromEnum(rtype),
        };
        setHoldLids(h, .headers_received, &need_hdr);
        g_wreq.next_hid +%= 1;
        if (g_wreq.next_hid == 0) g_wreq.next_hid = 1;
        h.url_len = @intCast(@min(url.len, h.url.len));
        @memcpy(h.url[0..h.url_len], url[0..h.url_len]);
        if (hdr_len != 0) @memcpy(h.hdr[0..hdr_len], hdr_buf[0..hdr_len]);
        _ = g_wreq.outstanding.fetchAdd(1, .release);
    }
    g_wreq.release();
    wreqPoke();
    return 0;
}

/// A response's headers as a JSON array. IO THREAD, no allocation.
fn wreqResponseHeadersJson(resp: *cef.cef_response_t, out: []u8) u16 {
    const gh = resp.get_header_map orelse return 0;
    const map = cef.cef_string_multimap_alloc() orelse return 0;
    defer cef.cef_string_multimap_free(map);
    gh(resp, map);
    var w = std.Io.Writer.fixed(out);
    w.writeByte('[') catch return 0;
    const n = cef.cef_string_multimap_size(map);
    var i: usize = 0;
    var first = true;
    while (i < n) : (i += 1) {
        var key = std.mem.zeroes(cef.cef_string_t);
        var val = std.mem.zeroes(cef.cef_string_t);
        defer cef.cef_string_utf16_clear(&key);
        defer cef.cef_string_utf16_clear(&val);
        if (cef.cef_string_multimap_key(map, i, &key) == 0) continue;
        _ = cef.cef_string_multimap_value(map, i, &val);
        var kbuf: [256]u8 = undefined;
        var vbuf: [1024]u8 = undefined;
        const ks = utf16Into(&key, &kbuf);
        const vs = utf16Into(&val, &vbuf);
        if (!first) w.writeByte(',') catch break;
        first = false;
        w.writeAll("{\"name\":") catch break;
        jsonStr(&w, ks) catch break;
        w.writeAll(",\"value\":") catch break;
        jsonStr(&w, vs) catch break;
        w.writeByte('}') catch break;
    }
    w.writeByte(']') catch return 0;
    return @intCast(w.end);
}

/// IO THREAD. Completes a logged entry with status/size/timing.
fn onResourceLoadComplete(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
    _: cef.cef_urlrequest_status_t,
    received: i64,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    defer releaseArg(response);
    const req: *cef.cef_request_t = request orelse return;
    const b: *cef.cef_browser_t = browser orelse return;
    const gi = b.get_identifier orelse return;
    const cef_id = gi(b);
    const req_id: u64 = if (req.get_identifier) |gid| gid(req) else return;
    var status: u16 = 0;
    if (response) |resp| {
        if (resp.*.get_status) |gs| status = @intCast(std.math.clamp(gs(resp), 0, 999));
    }
    const now = nowMs();

    g_int.acquire();
    defer g_int.release();
    for (&g_int.slots) |*s| {
        if (!s.used or s.cef_id != cef_id) continue;
        // Byte budget: accounted at completion (the only place the
        // engine reports a size), so a response that CROSSES the cap
        // completes and the NEXT request is what gets refused. The
        // schema says so; no CEF callback can pre-empt a body.
        if (s.pol) |pol| {
            s.pc.bytes +|= @intCast(@max(received, 0));
            if (pol.max_bytes != 0 and s.pc.bytes >= pol.max_bytes and s.pc.exhausted == .none)
                s.pc.exhausted = .byte_cap;
            s.pol_dirty = true;
        }
        const ring = s.ring orelse return;
        for (ring) |*e| {
            if (e.seq == 0 or e.req_id != req_id or e.done) continue;
            e.done = true;
            e.status = status;
            e.size = @intCast(std.math.clamp(received, 0, std.math.maxInt(u32)));
            e.dur_ms = @intCast(std.math.clamp(now - e.start_ms, 0, std.math.maxInt(u32)));
            s.dirty = true;
            return;
        }
        return;
    }
}

/// Copy a ring `LogEntry` into a `proto.NetEntry`, with its strings
/// staged into caller-owned buffers (the entry's own storage is
/// released the moment the lock drops). Called under the lock.
fn fillEntry(out: *proto.NetEntry, url_buf: *[LOG_URL_MAX]u8, method_buf: *[8]u8, e: *const LogEntry) void {
    @memcpy(url_buf[0..e.url_len], e.url[0..e.url_len]);
    @memcpy(method_buf[0..e.method_len], e.method[0..e.method_len]);
    out.* = .{
        .seq = e.seq,
        .blocked = if (e.blocked) 1 else 0,
        .rtype = e.rtype,
        .done = if (e.done) 1 else 0,
        .status = e.status,
        .dur_ms = e.dur_ms,
        .size = e.size,
        .method = method_buf[0..e.method_len],
        .url = url_buf[0..e.url_len],
    };
}

// ---------------------------------------------------------------------
// Blocking webRequest: the held-request path
// ---------------------------------------------------------------------
//
// WHERE THE ROUND TRIP GOES, and why it never leaves this process:
//
//   CEF IO thread (on_before_resource_load)
//     -> hold slot + wake byte
//   helper main thread (between two poll iterations)
//     -> execute_java_script into the extension's BACKGROUND PAGE
//   that page's RENDERER process
//     -> the MV2 listener runs, returns a BlockingResponse
//   back over the nonce-authenticated bridge to the main thread
//     -> apply the decision to the cef_request_t, cont()/cancel()
//
// The background page is a hidden windowless browser THIS HELPER owns
// (View.webext_bg), so the only cross-process hop is the one Chromium
// forces on us. The GUI is not involved and no frame crosses the mux
// wire; a decision path through the client would add a socket hop and a
// GUI main-loop turn to the most latency-sensitive code in the browser.
//
// PRECEDENCE with the native engine (`filter.zig`), stated once here and
// mirrored in src/web/CLAUDE.md:
//
//   1. The native filter engine runs FIRST and its CANCEL is FINAL. An
//      extension is never consulted about a request the built-in
//      blocker already refused — there is nothing for it to un-cancel
//      (MV2 has no "uncancel"), and consulting it would put a JS round
//      trip on requests we already decided in nanoseconds.
//   2. Extensions see everything the native engine let through, in
//      registration order per extension and extension order after that.
//   3. Among extensions, FIRST CANCEL WINS and a cancel beats a
//      redirect, which is Firefox's own resolution.
//   4. The per-view shield gate (`intercept_enable`) disables BOTH: a
//      user who turned blocking off for a site gets no extension
//      filtering there either, because "off" has to mean off.
//
// EVERY HELD REQUEST IS ANSWERED ON EVERY PATH. That is not a wish, it
// is the reason this table has an explicit `answer()` and only one:
// a request held forever is a page that never finishes loading, with no
// error and no way out. The exits are enumerated at `answerHold`.

/// How long a blocking listener may take before the request is let
/// through unfiltered. Firefox has no such cap (it trusts its own
/// extension process); we do, because a wedged background page here is
/// a wedged browser. 500ms is far above the measured p95 (see the
/// benchmark numbers in src/web/CLAUDE.md) and far below a user's
/// patience for a stuck load.
const wreq_timeout_ms_default: i64 = 500;

/// Concurrent held/queued requests. A burst past this fails OPEN —
/// requests continue unfiltered rather than queue behind a listener.
const MAX_HOLDS = 32;
const HOLD_URL_MAX = 1024;
const HOLD_HDR_MAX = 3072;

/// Latency samples kept per extension for the p50/p95 report.
const WREQ_SAMPLES = 256;

const Hold = struct {
    used: bool = false,
    hid: u32 = 0,
    /// Non-null only while the request is genuinely HELD. An
    /// observational slot has none and must never touch these.
    cb: ?*cef.cef_callback_t = null,
    req: ?*cef.cef_request_t = null,
    /// Index into `g_wstats` — the extension being asked.
    ext: usize = 0,
    bg_view: u32 = 0,
    /// Which MV2 event this dispatch is for. CEF gives ONE pre-flight
    /// callback for both `onBeforeRequest` and `onBeforeSendHeaders`,
    /// so a request needing both is dispatched TWICE in sequence from
    /// the same hold — which is also MV2's documented ordering.
    event: webrequest.Event = .before_request,
    /// A slot with no `cb` is a MAILBOX, not a hold: the request has
    /// already continued and this exists only to deliver an
    /// observational notification.
    want_send_headers: bool = false,
    want_request_headers: bool = false,
    /// False until the main thread has actually sent the command.
    dispatched: bool = false,
    deadline_ms: i64 = 0,
    start_us: i64 = 0,
    rtype: u8 = 0,
    view_id: u32 = 0,
    url_len: u16 = 0,
    url: [HOLD_URL_MAX]u8 = @splat(0),
    method_len: u8 = 0,
    method: [8]u8 = @splat(0),
    /// A JSON array of `{name,value}` — built on the IO thread from the
    /// request's own header map, into this fixed buffer (no allocation
    /// on that thread, same rule the intercept log follows).
    hdr_len: u16 = 0,
    hdr: [HOLD_HDR_MAX]u8 = @splat(0),
    /// The listener ids whose OWN `RequestFilter` matched, PER EVENT
    /// (indexed by `@intFromEnum(Event)`) — one hold can be dispatched
    /// for `onBeforeRequest` and then again for `onBeforeSendHeaders`,
    /// and the two have different listeners.
    ///
    /// Only these ids may run; see `webrequest.Need.ids` for why running
    /// the others is not a small inaccuracy but a browser that loads no
    /// pages at all.
    lids: [3][webrequest.MAX_MATCHED]u32 = @splat(@splat(0)),
    n_lids: [3]u8 = @splat(0),

    fn urlSlice(self: *const Hold) []const u8 {
        return self.url[0..self.url_len];
    }
};

const WStat = struct {
    used: bool = false,
    id: [webrequest.MAX_ID]u8 = @splat(0),
    id_len: usize = 0,
    matched: u32 = 0,
    held: u32 = 0,
    cancelled: u32 = 0,
    redirected: u32 = 0,
    headers_modified: u32 = 0,
    headers_received_dropped: u32 = 0,
    timed_out: u32 = 0,
    failed_open: u32 = 0,
    nsamples: u32 = 0,
    widx: usize = 0,
    samples: [WREQ_SAMPLES]u32 = @splat(0),

    fn idSlice(self: *const WStat) []const u8 {
        return self.id[0..self.id_len];
    }

    fn note(self: *WStat, us: u32) void {
        self.samples[self.widx] = us;
        self.widx = (self.widx + 1) % WREQ_SAMPLES;
        if (self.nsamples < WREQ_SAMPLES) self.nsamples += 1;
    }
};

const WreqState = struct {
    lock: SpinLock = .{},
    /// Read WITHOUT the lock on the request path so a helper with no
    /// blocking extension pays one relaxed load per request.
    outstanding: std.atomic.Value(u32) = .init(0),
    next_hid: u32 = 1,
    timeout_ms: i64 = wreq_timeout_ms_default,
    holds: [MAX_HOLDS]Hold = @splat(.{}),
    stats: [webrequest.MAX_PUBLISHED]WStat = @splat(.{}),

    fn acquire(self: *WreqState) void {
        self.lock.lock();
    }
    fn release(self: *WreqState) void {
        self.lock.unlock();
    }
};

var g_wreq: WreqState = .{};

/// Self-pipe so the IO thread can cut the main loop's poll short the
/// instant a request is held. Without it the first hold of a page load
/// waits out whatever poll timeout was already running (5ms), which is
/// pure dead time on the critical path.
var g_wreq_wake: [2]c_int = .{ -1, -1 };

/// The read end for `server.zig` to poll, or -1 when the pipe could not
/// be made (the loop then falls back to its ordinary timeout).
pub fn webrequestWakeFd() c_int {
    return g_wreq_wake[0];
}

/// True while at least one request is held or queued. The loop shortens
/// its poll on this, because a held request is a stalled page.
pub fn webrequestBusy() bool {
    return g_wreq.outstanding.load(.acquire) != 0;
}

pub fn webrequestDrainWake() void {
    if (g_wreq_wake[0] < 0) return;
    var buf: [64]u8 = undefined;
    while (c.read(g_wreq_wake[0], &buf, buf.len) > 0) {}
}

fn wreqPoke() void {
    if (g_wreq_wake[1] < 0) return;
    const one: [1]u8 = .{1};
    _ = c.write(g_wreq_wake[1], &one, 1);
}

fn wreqInitPipe() void {
    if (g_wreq_wake[0] >= 0) return;
    if (c.pipe(&g_wreq_wake) != 0) {
        g_wreq_wake = .{ -1, -1 };
        return;
    }
    // Both ends non-blocking: the IO thread must never block on a full
    // pipe (a byte already there means the loop is already awake), and
    // the drain must never block on an empty one.
    for (g_wreq_wake) |fd| {
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
    }
}

/// Override the fail-open deadline. Used by the benchmark and the smoke
/// rig; `SKETERM_WEB_WREQ_TIMEOUT_MS=<n>` is the operator-facing form.
fn wreqReadTimeoutEnv() void {
    const v = c.getenv("SKETERM_WEB_WREQ_TIMEOUT_MS") orelse return;
    const s = std.mem.span(v);
    const n = std.fmt.parseInt(i64, s, 10) catch return;
    if (n > 0) g_wreq.timeout_ms = n;
}

fn wstatFor(id: []const u8) ?*WStat {
    for (&g_wreq.stats) |*s| {
        if (s.used and std.mem.eql(u8, s.idSlice(), id)) return s;
    }
    for (&g_wreq.stats) |*s| {
        if (s.used) continue;
        if (id.len > s.id.len) return null;
        s.* = .{ .used = true };
        @memcpy(s.id[0..id.len], id);
        s.id_len = id.len;
        return s;
    }
    return null;
}

/// CEF's resource type as the MV2 `ResourceType` the filters speak.
fn wreqTypeOf(t: cef.cef_resource_type_t) webrequest.RType {
    return switch (t) {
        cef.RT_MAIN_FRAME => .main_frame,
        cef.RT_SUB_FRAME => .sub_frame,
        cef.RT_STYLESHEET => .stylesheet,
        cef.RT_SCRIPT => .script,
        cef.RT_IMAGE => .image,
        cef.RT_FAVICON => .image,
        cef.RT_FONT_RESOURCE => .font,
        cef.RT_XHR => .xmlhttprequest,
        cef.RT_MEDIA => .media,
        cef.RT_PING => .ping,
        cef.RT_CSP_REPORT => .csp_report,
        cef.RT_OBJECT => .object,
        else => .other,
    };
}

/// Serialize a request's headers into `out` as a JSON array. IO THREAD:
/// CEF allocates the multimap, we allocate nothing.
fn wreqHeadersJson(req: *cef.cef_request_t, out: []u8) u16 {
    const gh = req.get_header_map orelse return 0;
    const map = cef.cef_string_multimap_alloc() orelse return 0;
    defer cef.cef_string_multimap_free(map);
    gh(req, map);
    var w = std.Io.Writer.fixed(out);
    w.writeByte('[') catch return 0;
    const n = cef.cef_string_multimap_size(map);
    var i: usize = 0;
    var first = true;
    while (i < n) : (i += 1) {
        var key = std.mem.zeroes(cef.cef_string_t);
        var val = std.mem.zeroes(cef.cef_string_t);
        defer cef.cef_string_utf16_clear(&key);
        defer cef.cef_string_utf16_clear(&val);
        if (cef.cef_string_multimap_key(map, i, &key) == 0) continue;
        _ = cef.cef_string_multimap_value(map, i, &val);
        var kbuf: [256]u8 = undefined;
        var vbuf: [1024]u8 = undefined;
        const ks = utf16Into(&key, &kbuf);
        const vs = utf16Into(&val, &vbuf);
        if (!first) w.writeByte(',') catch break;
        first = false;
        w.writeAll("{\"name\":") catch break;
        jsonStr(&w, ks) catch break;
        w.writeAll(",\"value\":") catch break;
        jsonStr(&w, vs) catch break;
        w.writeByte('}') catch break;
    }
    w.writeByte(']') catch return 0;
    return @intCast(w.end);
}

/// A `cef_string_t`'s UTF-8 into `buf` (truncated). Unlike
/// `userfreeInto` this does NOT take ownership.
fn utf16Into(s: *const cef.cef_string_t, buf: []u8) []const u8 {
    if (s.str == null or s.length == 0) return "";
    var u = Utf8.init(@constCast(s));
    defer u.free();
    const src = u.slice();
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

/// IO THREAD. Decide whether this request needs any extension at all,
/// and if so whether it must be HELD.
///
/// Returns true when the caller must return `RV_CONTINUE_ASYNC` — the
/// request is now this table's responsibility and WILL be answered.
///
/// LOCK ORDER: `webrequest.lock` (the registry) is taken and RELEASED
/// before `g_wreq.lock` (the hold table). They are never nested, in
/// either direction, anywhere.
fn wreqConsider(
    req: *cef.cef_request_t,
    cb: ?*cef.cef_callback_t,
    url: []const u8,
    method: []const u8,
    rtype: webrequest.RType,
    view_id: u32,
) bool {
    // THE fast path: one relaxed load. A helper with no extension
    // listener at all, which is the overwhelmingly common case, pays
    // exactly this and nothing else.
    if (!webrequest.any_listeners.load(.acquire)) return false;

    // Which extension cares, and how. Copied out under the registry
    // lock so nothing is held while we touch CEF.
    var ext_id_buf: [webrequest.MAX_ID]u8 = undefined;
    var ext_id_len: usize = 0;
    var bg_view: u32 = 0;
    var need_before = webrequest.Need.none();
    var need_send = webrequest.Need.none();
    {
        webrequest.acquire();
        defer webrequest.release();
        for (&webrequest.slots) |*s| {
            if (!s.used) continue;
            const reg = s.reg orelse continue;
            const nb = webrequest.needFor(reg, .before_request, url, rtype);
            const ns = webrequest.needFor(reg, .before_send_headers, url, rtype);
            if (nb.isNone() and ns.isNone()) continue;
            // v1 asks ONE extension per request — the first that
            // matches. Chaining several would multiply the round trip
            // by the extension count on the critical path, and the
            // measured cost of one round trip (src/web/CLAUDE.md) is
            // already the dominant term. Documented, not hidden.
            ext_id_len = s.id_len;
            @memcpy(ext_id_buf[0..s.id_len], s.idSlice());
            bg_view = s.bg_view;
            need_before = nb;
            need_send = ns;
            break;
        }
    }
    if (ext_id_len == 0) return false;

    const ext_id = ext_id_buf[0..ext_id_len];
    const blocking = need_before.blocking or need_send.blocking;
    // No background page yet (or torn down): there is nobody to ask.
    // Fail open immediately rather than hold for a listener that cannot
    // run — this is one of the enumerated exits.
    if (bg_view == 0) {
        g_wreq.acquire();
        defer g_wreq.release();
        if (wstatFor(ext_id)) |st| {
            st.matched +%= 1;
            if (blocking) st.failed_open +%= 1;
        }
        return false;
    }

    // Header collection costs a CEF multimap walk; only pay for it when
    // a matching listener asked for requestHeaders.
    var hdr_buf: [HOLD_HDR_MAX]u8 = undefined;
    var hdr_len: u16 = 0;
    if (need_before.want_request_headers or need_send.want_request_headers) {
        hdr_len = wreqHeadersJson(req, &hdr_buf);
    }

    g_wreq.acquire();
    var slot: ?*Hold = null;
    for (&g_wreq.holds) |*h| {
        if (!h.used) {
            slot = h;
            break;
        }
    }
    const st = wstatFor(ext_id);
    if (st) |s| s.matched +%= 1;
    const h = slot orelse {
        // Table full. Fail OPEN: a burst of requests must not queue
        // behind a listener, and dropping the notification is strictly
        // better than stalling the page.
        if (st) |s| if (blocking) {
            s.failed_open +%= 1;
        };
        g_wreq.release();
        return false;
    };

    const ext_idx: usize = if (st) |s| (@intFromPtr(s) - @intFromPtr(&g_wreq.stats[0])) / @sizeOf(WStat) else 0;
    h.* = .{
        .used = true,
        .hid = g_wreq.next_hid,
        .ext = ext_idx,
        .bg_view = bg_view,
        .view_id = view_id,
        .rtype = @intFromEnum(rtype),
        .start_us = nowUs(),
        .deadline_ms = nowMs() + g_wreq.timeout_ms,
        .hdr_len = hdr_len,
    };
    g_wreq.next_hid +%= 1;
    if (g_wreq.next_hid == 0) g_wreq.next_hid = 1;
    h.url_len = @intCast(@min(url.len, h.url.len));
    @memcpy(h.url[0..h.url_len], url[0..h.url_len]);
    h.method_len = @intCast(@min(method.len, h.method.len));
    @memcpy(h.method[0..h.method_len], method[0..h.method_len]);
    if (hdr_len != 0) @memcpy(h.hdr[0..hdr_len], hdr_buf[0..hdr_len]);

    if (!blocking) {
        // A NON-blocking listener must not hold the request at all —
        // the slot is only a mailbox for the notification, and the
        // caller has already been told to continue.
        h.event = if (need_before.matched) .before_request else .before_send_headers;
        h.want_request_headers = need_before.want_request_headers or need_send.want_request_headers;
    } else if (need_before.blocking) {
        h.event = .before_request;
        h.want_send_headers = need_send.blocking;
        h.want_request_headers = need_before.want_request_headers;
    } else {
        h.event = .before_send_headers;
        h.want_request_headers = true;
    }
    setHoldLids(h, .before_request, &need_before);
    setHoldLids(h, .before_send_headers, &need_send);

    if (blocking) {
        // The hold KEEPS the references the callback received with
        // `cb` and `req` (the caller releases them only when this
        // returns false), so no add_ref: one would never be paid back.
        h.cb = cb;
        h.req = req;
        if (st) |s| s.held +%= 1;
    }
    _ = g_wreq.outstanding.fetchAdd(1, .release);
    g_wreq.release();
    wreqPoke();
    return blocking;
}

fn setHoldLids(h: *Hold, event: webrequest.Event, need: *const webrequest.Need) void {
    const i: usize = @intFromEnum(event);
    h.n_lids[i] = need.n_ids;
    @memcpy(h.lids[i][0..need.n_ids], need.idSlice());
}

/// Answer every hold belonging to one extension. Main thread.
fn wreqAbandonExt(ext_id: []const u8) void {
    var cbs: [MAX_HOLDS]?*cef.cef_callback_t = @splat(null);
    var reqs: [MAX_HOLDS]?*cef.cef_request_t = @splat(null);
    var n: usize = 0;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        var want: ?usize = null;
        for (&g_wreq.stats, 0..) |*st, i| {
            if (st.used and std.mem.eql(u8, st.idSlice(), ext_id)) {
                want = i;
                break;
            }
        }
        const target = want orelse return;
        for (&g_wreq.holds) |*h| {
            if (!h.used or h.ext != target) continue;
            if (h.cb != null) {
                if (wstatIdx(target)) |st| st.failed_open +%= 1;
            }
            cbs[n] = h.cb;
            reqs[n] = h.req;
            n += 1;
            h.* = .{};
            _ = g_wreq.outstanding.fetchSub(1, .release);
        }
    }
    // CEF is re-entered OUTSIDE the spinlock, always.
    for (0..n) |i| {
        if (cbs[i]) |x| {
            if (x.cont) |f| f(x);
            release(&x.base);
        }
        if (reqs[i]) |r| release(&r.base);
    }
}

/// The `p`-th percentile of an ASCENDING slice (nearest-rank).
fn pct(sorted: []const u32, p: usize) u32 {
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * p + 99) / 100;
    const idx = @min(if (rank == 0) 0 else rank - 1, sorted.len - 1);
    return sorted[idx];
}

/// The hold with this id, or null when it has already been answered.
/// Caller holds `g_wreq.lock`.
fn wreqFind(hid: u32) ?*Hold {
    for (&g_wreq.holds) |*h| {
        if (h.used and h.hid == hid) return h;
    }
    return null;
}

fn wstatIdx(i: usize) ?*WStat {
    if (i >= g_wreq.stats.len) return null;
    return &g_wreq.stats[i];
}

/// Answer every hold whose background page or page view is `view`.
fn wreqAbandonView(view: u32) void {
    var cbs: [MAX_HOLDS]?*cef.cef_callback_t = @splat(null);
    var reqs: [MAX_HOLDS]?*cef.cef_request_t = @splat(null);
    var n: usize = 0;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        for (&g_wreq.holds) |*h| {
            if (!h.used) continue;
            if (h.bg_view != view and h.view_id != view) continue;
            if (h.cb != null) {
                if (wstatIdx(h.ext)) |s| s.failed_open +%= 1;
            }
            cbs[n] = h.cb;
            reqs[n] = h.req;
            n += 1;
            h.* = .{};
            _ = g_wreq.outstanding.fetchSub(1, .release);
        }
    }
    for (0..n) |i| {
        if (cbs[i]) |x| {
            if (x.cont) |f| f(x);
            release(&x.base);
        }
        if (reqs[i]) |r| release(&r.base);
    }
}

/// Free the pipe and answer anything still held. Helper shutdown.
pub fn webrequestDeinit() void {
    var cbs: [MAX_HOLDS]?*cef.cef_callback_t = @splat(null);
    var reqs: [MAX_HOLDS]?*cef.cef_request_t = @splat(null);
    var n: usize = 0;
    {
        g_wreq.acquire();
        defer g_wreq.release();
        for (&g_wreq.holds) |*h| {
            if (!h.used) continue;
            cbs[n] = h.cb;
            reqs[n] = h.req;
            n += 1;
            h.* = .{};
        }
        g_wreq.outstanding.store(0, .release);
    }
    for (0..n) |i| {
        if (cbs[i]) |x| {
            if (x.cont) |f| f(x);
            release(&x.base);
        }
        if (reqs[i]) |r| release(&r.base);
    }
    for (&g_wreq_wake) |*fd| {
        if (fd.* >= 0) _ = c.close(fd.*);
        fd.* = -1;
    }
}

fn onGetResourceRequestHandler(
    _: [*c]cef.cef_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    _: c_int,
    _: c_int,
    _: [*c]const cef.cef_string_t,
    _: [*c]c_int,
) callconv(.c) [*c]cef.cef_resource_request_handler_t {
    releaseArg(browser);
    releaseArg(frame);
    releaseArg(request);
    return &resource_request_handler;
}

// ---------------------------------------------------------------------
// Small CEF call helpers
// ---------------------------------------------------------------------

/// The windowless `cef_window_info_t` every browser this helper makes
/// is created with — the ordinary views AND the inspector, which is
/// exactly what makes DevTools just another view.
fn windowlessInfo(v: *View) cef.cef_window_info_t {
    var winfo = std.mem.zeroes(cef.cef_window_info_t);
    winfo.size = @sizeOf(cef.cef_window_info_t);
    winfo.windowless_rendering_enabled = 1;
    // The frame source: with this set, Chromium produces a frame per
    // `send_external_begin_frame` and never on its own, which is what
    // lifts the 60fps ceiling AND what makes an untouched page cost
    // nothing. It is fixed at browser creation and cannot be toggled
    // per frame, so ALL adaptive behaviour lives in how often somebody
    // asks (client pacing + the watchdog).
    v.external_pacing = externalPacingDefault();
    winfo.external_begin_frame_enabled = if (v.external_pacing) 1 else 0;
    // GPU frames. Fixed at browser creation like the flag above, and
    // only ever honoured when the process got a GPU: with it set and no
    // GPU compositing available, Chromium simply keeps calling
    // `on_paint`, which is the software path this helper already has.
    // That is the whole fallback — no probe, no timeout.
    winfo.shared_texture_enabled = if (accelerated) 1 else 0;
    winfo.runtime_style = cef.CEF_RUNTIME_STYLE_ALLOY;
    return winfo;
}

fn windowlessSettings(v: *View) cef.cef_browser_settings_t {
    var bsettings = std.mem.zeroes(cef.cef_browser_settings_t);
    bsettings.size = @sizeOf(cef.cef_browser_settings_t);
    bsettings.windowless_frame_rate = effectiveWindowlessFps(v.max_fps);
    // OPAQUE WHITE, PER BROWSER. A windowless browser defaults to
    // TRANSPARENT, and a page that specifies no background of its own
    // then paints (0,0,0,0) everywhere: a perfectly healthy page
    // photographs as a uniformly black frame (measured — the centre
    // pixel is exactly {0,0,0,0}, smoke-web stage 22c).
    // `CefSettings.background_color` is documented as the fallback for
    // a zero value here and is ALREADY opaque white in `initialize`,
    // but measurably does not reach an alloy windowless browser: only
    // this per-browser value does. Do not delete it in favour of the
    // global one.
    bsettings.background_color = 0xffffffff;
    return bsettings;
}

/// Re-show (i.e. focus) an inspector the engine already has open for
/// `src`. CEF documents `show_dev_tools` on an open inspector as a
/// focus request that ignores every other argument.
fn focusDevTools(src: *View) void {
    const host = browserHost(src) orelse return;
    defer release(&host.base);
    if (host.show_dev_tools) |show| show(host, null, null, null, null);
}

/// Whether the view's browser really renders off-screen. An engine can
/// refuse a windowless request (CEF's DevTools window does — see
/// `Host.adoptBrowser`), and a windowed browser delivers no frame this
/// protocol can carry.
fn isWindowless(v: *View) bool {
    const host = browserHost(v) orelse return false;
    defer release(&host.base);
    const f = host.is_window_rendering_disabled orelse return false;
    return f(host) != 0;
}

/// Invoke a nullary int-returning `cef_browser_t` accessor by name,
/// tolerating both a null browser and a null vtable slot.
fn browserInt(b: ?*cef.cef_browser_t, comptime name: []const u8) c_int {
    const br = b orelse return 0;
    const f = @field(br, name) orelse return 0;
    return f(br);
}

fn release(base: *cef.cef_base_ref_counted_t) void {
    if (base.release) |r| _ = r(base);
}

/// Release the reference libcef hands over with every ref-counted
/// argument of a callback (see "Reference ownership" in CLAUDE.md).
/// Null-tolerant, so an optional `[*c]` parameter goes in as is.
fn releaseArg(arg: anytype) void {
    if (arg == null) return;
    release(&arg.*.base);
}

fn setStr(utf8: []const u8, out: *cef.cef_string_t) void {
    _ = cef.cef_string_utf8_to_utf16(utf8.ptr, utf8.len, out);
}

/// Sanitize a container name into ONE safe path component so a
/// persistent context's cache dir follows the name. Anything outside
/// `[A-Za-z0-9._-]` becomes `_`; an empty result falls back to the id,
/// so the dir is always non-empty and never escapes its parent.
fn sanitizeContextName(name: []const u8, id: u32, buf: *[256]u8) []const u8 {
    var n: usize = 0;
    for (name) |ch| {
        if (n >= buf.len - 24) break;
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '.' or ch == '_' or ch == '-';
        buf[n] = if (ok) ch else '_';
        n += 1;
    }
    if (n == 0) return std.fmt.bufPrint(buf, "ctx-{d}", .{id}) catch "ctx";
    // Disambiguate names colliding after sanitization by appending the id.
    const tail = std.fmt.bufPrint(buf[n..], "-{d}", .{id}) catch return buf[0..n];
    return buf[0 .. n + tail.len];
}

/// Point a request context at a fixed-server proxy, exactly as the
/// browser spike proved: `set_preference("proxy", {mode:"fixed_servers",
/// server:<url>})` on the context's base preference manager. A socks5
/// url makes the engine resolve DNS at the proxy end — the "browse via
/// server X" property. False leaves the caller responsible for dropping the
/// request context before any view can use it.
///
/// Nothing built here outlives the call. A `cef_*_t*` handed to a CEF
/// function as a NON-SELF argument is a `refptr_same` transfer: the
/// receiving side releases one reference at parameter-unwrap time, BEFORE
/// the method body runs and whether it then succeeds or fails. So each
/// transfer latch below is set BEFORE its consuming call, and the pointer
/// is dangling from that point on: storing it, reading it or releasing it
/// afterwards is a use-after-free. Retaining this value graph past
/// `set_preference` is not merely unnecessary, it is unexpressible.
fn applyProxy(rc: *cef.cef_request_context_t, proxy_url: []const u8) bool {
    // Deterministic smoke seam for the otherwise engine-controlled refusal.
    if (c.getenv("SKETERM_WEB_FAIL_PROXY") != null) return false;

    const dict: *cef.cef_dictionary_value_t = cef.cef_dictionary_value_create() orelse return false;
    var dict_transferred = false;
    defer if (!dict_transferred) release(&dict.base);
    var mode_key = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&mode_key);
    var mode_value = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&mode_value);
    setStr("mode", &mode_key);
    setStr("fixed_servers", &mode_value);
    if ((dict.set_string orelse return false)(dict, &mode_key, &mode_value) == 0) return false;

    var server_key = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&server_key);
    var server_value = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&server_value);
    setStr("server", &server_key);
    setStr(proxy_url, &server_value);
    if ((dict.set_string orelse return false)(dict, &server_key, &server_value) == 0) return false;

    // Chromium otherwise bypasses localhost implicitly. Tor/egress routing is
    // fail-closed only when loopback destinations traverse the fixed proxy too.
    var bypass_key = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&bypass_key);
    var bypass_value = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&bypass_value);
    setStr("bypass_list", &bypass_key);
    setStr("<-loopback>", &bypass_value);
    if ((dict.set_string orelse return false)(dict, &bypass_key, &bypass_value) == 0) return false;

    const val: *cef.cef_value_t = cef.cef_value_create() orelse return false;
    var value_transferred = false;
    defer if (!value_transferred) release(&val.base);
    // `dict` is consumed on receipt here, pass or fail: latch first.
    const set_dict = val.set_dictionary orelse return false;
    dict_transferred = true;
    if (set_dict(val, dict) == 0) return false;

    var pref_key = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&pref_key);
    setStr("proxy", &pref_key);
    var err = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&err);
    // The preference manager is the SELF argument (retrieved with `Get()`,
    // no refcounting); `val` is not, and is consumed on receipt.
    const base: *cef.cef_preference_manager_t = &rc.base;
    const set_pref = base.set_preference orelse return false;
    value_transferred = true;
    return set_pref(base, &pref_key, val, &err) != 0;
}

/// Borrowed UTF-8 view of a CEF string; `free` releases it.
const Utf8 = struct {
    s: cef.cef_string_utf8_t,

    fn init(str: [*c]const cef.cef_string_t) Utf8 {
        var out = std.mem.zeroes(cef.cef_string_utf8_t);
        if (str != null and str.*.str != null) {
            _ = cef.cef_string_utf16_to_utf8(str.*.str, str.*.length, &out);
        }
        return .{ .s = out };
    }

    fn slice(self: *const Utf8) []const u8 {
        if (self.s.str == null) return "";
        return self.s.str[0..self.s.length];
    }

    fn free(self: *Utf8) void {
        cef.cef_string_utf8_clear(&self.s);
    }
};

/// The view's browser host, WITH a reference held: every caller must
/// release it (CEF's capi returns referenced pointers).
fn browserHost(v: *View) ?*cef.cef_browser_host_t {
    const b = v.browser orelse return null;
    const gh = b.get_host orelse return null;
    const host: ?*cef.cef_browser_host_t = gh(b);
    return host;
}

/// Run `f` against the view's browser host, releasing the reference.
fn withHost(v: *View, f: *const fn (*cef.cef_browser_host_t) void) void {
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    f(host);
}

/// `withHost` for the arg-taking senders below (Zig has no closures).
fn withHostArgs(v: *View, comptime f: anytype, args: anytype) void {
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    @call(.auto, f, .{host} ++ args);
}

fn sendMove(host: *cef.cef_browser_host_t, ev: *const cef.cef_mouse_event_t, leave: c_int) void {
    if (host.send_mouse_move_event) |f| f(host, ev, leave);
}

fn sendClick(
    host: *cef.cef_browser_host_t,
    ev: *const cef.cef_mouse_event_t,
    button: cef.cef_mouse_button_type_t,
    up: c_int,
    clicks: c_int,
) void {
    if (host.send_mouse_click_event) |f| f(host, ev, button, up, clicks);
}

fn sendWheel(host: *cef.cef_browser_host_t, ev: *const cef.cef_mouse_event_t, dx: c_int, dy: c_int) void {
    if (host.send_mouse_wheel_event) |f| f(host, ev, dx, dy);
}

fn sendKey(host: *cef.cef_browser_host_t, ev: *const cef.cef_key_event_t) void {
    if (host.send_key_event) |f| f(host, ev);
}

fn setFocus(host: *cef.cef_browser_host_t, on: c_int) void {
    if (host.set_focus) |f| f(host, on);
}

fn imeCompose(
    host: *cef.cef_browser_host_t,
    text: *const cef.cef_string_t,
    sel: *const cef.cef_range_t,
) void {
    if (host.ime_set_composition) |f| f(host, text, 0, null, null, sel);
}

fn imeCommit(host: *cef.cef_browser_host_t, text: *const cef.cef_string_t, cursor: c_int) void {
    if (host.ime_commit_text) |f| f(host, text, null, cursor);
}

fn imeCancel(host: *cef.cef_browser_host_t) void {
    if (host.ime_cancel_composition) |f| f(host);
}

/// Type `text` into whatever has focus as CHAR events — the same path
/// `input_key` uses, so the page cannot tell a semantic set-value from
/// a human at the keyboard.
fn typeText(v: *View, text: []const u8) void {
    var ev = std.mem.zeroes(cef.cef_key_event_t);
    ev.size = @sizeOf(cef.cef_key_event_t);
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| Host.charEvent(v, ev, cp);
}

/// Append `s` as a JSON string literal, quotes included.
/// Extract the value after the first `:` in a `{"result":X}` /
/// `{"error":X}` object, dropping the trailing `}`. Used to forward a
/// host dispatch result's inner value to the frame; the input is always
/// helper-produced JSON, never page-authored.
fn innerJson(obj: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, obj, ':') orelse return "null";
    var inner = obj[colon + 1 ..];
    if (inner.len > 0 and inner[inner.len - 1] == '}') inner = inner[0 .. inner.len - 1];
    if (inner.len == 0) return "null";
    return inner;
}

fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
    try w.writeByte('"');
}

/// The single JSON string argument of a `sketerm.sem` process message,
/// or null when the message is not ours. Caller frees with `free`.
fn semPayload(message: [*c]cef.cef_process_message_t) ?Utf8 {
    const msg: *cef.cef_process_message_t = message orelse return null;
    const gn = msg.get_name orelse return null;
    const raw = gn(msg);
    if (raw == null) return null;
    var name = Utf8.init(raw);
    defer name.free();
    cef.cef_string_userfree_utf16_free(raw);
    if (!std.mem.eql(u8, name.slice(), sem_msg)) return null;

    const gal = msg.get_argument_list orelse return null;
    const args: *cef.cef_list_value_t = gal(msg) orelse return null;
    defer release(&args.base);
    const gs = args.get_string orelse return null;
    const sraw = gs(args, 0);
    if (sraw == null) return null;
    const out = Utf8.init(sraw);
    cef.cef_string_userfree_utf16_free(sraw);
    return out;
}

// ---------------------------------------------------------------------
// chrome-extension:// — the WebExtensions origin
// ---------------------------------------------------------------------
//
// An extension needs a real ORIGIN, not just a way to run scripts. Every
// MV2 extension worth hosting reaches for one within its first few
// lines: uBO's `js/start.js` is `type="module"` with twenty static
// imports, each of which is a FETCH that only a scheme handler can
// answer; `runtime.getURL` hands such urls to pages and to `fetch`;
// popup and options pages are documents at that origin. Evaluating
// scraped script text through `new Function` — which is all this host
// could do before — cannot supply any of it, and a static `import` is
// not even syntactically legal there.
//
// So: `chrome-extension` is registered as a CUSTOM SCHEME from the app,
// in every process (Chromium requires the registration to agree
// process-wide), and a factory serves it out of the unpacked directory.
// The host component is NOT the extension id — see `manifest.originHost`
// for why it cannot be — so the table is keyed on that derived host.
//
// EVERYTHING BELOW `create` RUNS ON CEF's IO THREAD. It reads the origin
// table under `origins.lock` (copying by value, then releasing), and it
// allocates through `std.heap.c_allocator` rather than the host's
// DebugAllocator — malloc is unambiguously thread-safe and the host's
// allocator belongs to the main thread's ownership story. The file read
// is synchronous on that thread, which is what CEF's own samples do and
// is bounded by `webext_max_asset`; an extension's assets are local
// files, so this trades a bounded local read for not having to keep a
// half-built response alive across a thread hop.

/// The extension origin's scheme.
///
/// **NOT `chrome-extension`, and that is measured, not preference.**
/// `cef_scheme_registrar_t::add_custom_scheme("chrome-extension")`
/// returns **0** on CEF 151.3.16 (Arch `cef`, 2026-08-12): Chromium owns
/// the name, so a client may not register it — and CEF's alloy runtime
/// has the extensions component removed, so nothing else serves it
/// either. `cef_register_scheme_handler_factory` still answers 1 for it,
/// which is the trap: registration LOOKS fine and every load then fails
/// `ERR_BLOCKED_BY_CLIENT` with the factory never once consulted.
/// `SKETERM_WEB_SCHEME_DEBUG=1` prints both return values.
///
/// So the origin gets a name of our own, exactly as Firefox uses
/// `moz-extension://` rather than Chrome's. Extensions cope: they build
/// their urls with `runtime.getURL`. What does NOT cope is an extension
/// that hard-codes the literal `chrome-extension:` — a real limitation,
/// and the reason this constant is one place.
const ext_scheme = "sketerm-extension";

/// Set when `cef_register_scheme_handler_factory` accepted the scheme.
/// When it did not, background pages fall back to running their scraped
/// scripts inline (no modules), and `webextSchemeOk` says so out loud
/// rather than leaving a silent half-working extension host.
var ext_scheme_ok = false;

pub fn webextSchemeOk() bool {
    return ext_scheme_ok;
}

var scheme_factory: cef.cef_scheme_handler_factory_t = undefined;

/// The one-line `<script src>` spliced into every extension HTML
/// document we serve, ahead of every author script.
const bootstrap_tag = "<script src=\"" ++ extorigins.BOOTSTRAP_PATH ++ "\"></script>";

/// One in-flight `chrome-extension://` load.
///
/// REALLY refcounted, unlike the process-lifetime statics around it:
/// CEF owns the reference `create` returns and releases it when the load
/// ends, which is also this object's free. There is exactly one other
/// refcounted client-side struct in this file (`CookieJob`) and it
/// documents the same rule.
const ExtResource = struct {
    handler: cef.cef_resource_handler_t,
    refs: std.atomic.Value(u32),
    /// Response body, owned by `std.heap.c_allocator`. Empty for a 404.
    data: []u8 = &.{},
    offset: usize = 0,
    status: c_int = 200,
    mime: []const u8 = "text/plain",

    fn fromSelf(self: [*c]cef.cef_resource_handler_t) ?*ExtResource {
        if (self == null) return null;
        const p: *cef.cef_resource_handler_t = @ptrCast(self);
        return @fieldParentPtr("handler", p);
    }

    fn destroyOwned(self: *ExtResource) void {
        if (self.data.len != 0) std.heap.c_allocator.free(self.data);
        std.heap.c_allocator.destroy(self);
    }
};

const ExtResRef = HeapRef(ExtResource, "handler");

/// IO THREAD. Resolve one `chrome-extension://` url to bytes.
/// One refusal is reported per process (see the branches that set it).
var g_ext_refusal_logged = false;

fn extSchemeCreate(
    _: [*c]cef.cef_scheme_handler_factory_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: [*c]const cef.cef_string_t,
    request: [*c]cef.cef_request_t,
) callconv(.c) [*c]cef.cef_resource_handler_t {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    const req: *cef.cef_request_t = request orelse return null;
    const gu = req.get_url orelse return null;
    var url_buf: [2048]u8 = undefined;
    const url = userfreeInto(gu(req), &url_buf);
    if (url.len == 0) return null;

    const host = extassets.urlHost(url);
    if (!extassets.sameOrigin(url, ext_scheme, host)) return null;
    const dbg = c.getenv("SKETERM_WEB_SCHEME_DEBUG") != null;
    const slot = extorigins.lookup(host) orelse {
        if (dbg) std.debug.print("sketerm-web: scheme create: no origin for host \"{s}\" ({s})\n", .{ host, url });
        return null;
    };
    if (dbg) std.debug.print("sketerm-web: scheme create: {s}\n", .{url});

    // The web_accessible_resources gate. An extension's OWN documents
    // may read anything in their package; anybody else gets only what
    // the manifest published. The initiator is identified by the
    // requesting FRAME's url, which is the document doing the loading —
    // a referrer would be wrong here, since a referrer policy is free to
    // strip it and a stripped referrer must not silently open the gate.
    const path = extassets.urlPath(url);
    // NO FRAME means the load did not come from a document at all: a
    // WEB WORKER's script, a `cef_urlrequest`, a fetch from a worker
    // context. Such a load cannot be attributed, and refusing it is
    // wrong in a way that is very hard to see — uBlock Origin
    // (de)serializes its filter cache on a Worker, and a 403 on the
    // worker script left `serializeAsync` pending FOREVER: uBO's boot
    // stopped mid-sequence with no error anywhere, and it simply never
    // filtered. A page cannot mint such a load for another origin, so
    // treating it as the extension's own is both safe and necessary.
    // A NAVIGATION is the only load whose initiating frame legitimately
    // still reports the PREVIOUS document's url. Narrowing the `about:`
    // relaxation to it is what stops a hostile page creating an
    // about:blank iframe and `fetch()`ing any file in any installed
    // package — including the generated bootstrap, which carries the
    // bridge NONCE in plaintext and would defeat every nonce gate in
    // semantic.js.
    const rtype_raw = if (req.get_resource_type) |grt| grt(req) else cef.RT_SUB_RESOURCE;
    const is_navigation = rtype_raw == cef.RT_MAIN_FRAME or rtype_raw == cef.RT_SUB_FRAME;
    // Measured 2026-08-12 with this print: the generated background
    // document and an author's own `background.html` both arrive as
    // rtype 0 (RT_MAIN_FRAME) with a frame, and the bootstrap arrives
    // as rtype 3 (RT_SCRIPT) with the frame already at the extension
    // origin. That is what makes the split below safe.
    if (dbg) std.debug.print(
        "sketerm-web: ext gate path={s} rtype={d} frame={d}\n",
        .{ path, rtype_raw, @intFromBool(frame != null) },
    );

    // `strict` = the initiating document really IS this extension.
    // Tracked apart from `same_origin` because the relaxations below are
    // right for package FILES and wrong for the generated paths.
    var strict = false;
    var first_party_buf: [2048]u8 = undefined;
    const first_party = if (req.get_first_party_for_cookies) |get|
        userfreeInto(get(req), &first_party_buf)
    else
        "";
    var same_origin = frame == null;
    if (frame) |f| {
        if (f.*.get_url) |fu| {
            var fbuf: [2048]u8 = undefined;
            const furl = userfreeInto(fu(f), &fbuf);
            strict = extassets.sameOrigin(furl, ext_scheme, host);
            same_origin = strict;
            // A top-level navigation TO the extension page reports the
            // frame's previous url, so allow the document itself: this
            // is how the background page, the popup and the options page
            // load at all.
            if (!same_origin and is_navigation and
                (furl.len == 0 or std.mem.startsWith(u8, furl, "about:"))) same_origin = true;
        } else same_origin = true;
    }
    // CEF may expose the requesting frame's PREVIOUS url while parser-
    // blocking extension scripts are fetched. The request's first-party
    // url already names the committed top-level extension document, and
    // matching the exact target host keeps this strict: ordinary, blank,
    // data and another extension's origin still fail.
    if (!strict and extassets.sameOrigin(first_party, ext_scheme, host)) {
        strict = true;
        same_origin = true;
    }
    if (!same_origin) {
        var pats: [32][]const u8 = undefined;
        if (!extassets.webAccessible(slot.warPatterns(&pats), path)) {
            if (dbg) std.debug.print("sketerm-web: WAR 403 {s} (rtype={d})\n", .{ path, rtype_raw });
            return extResourceFor(&.{}, "text/plain", 403);
        }
    }

    // The reserved paths are GENERATED, never read from the package —
    // and they are checked before the file lookup so a package cannot
    // shadow either with a file of its own.
    if (std.mem.eql(u8, path, extorigins.BOOTSTRAP_PATH)) {
        // STRICT only. This body contains the bridge nonce, so it is the
        // one path where "close enough to same-origin" is not good
        // enough: it is always a `<script src>` from the extension's own
        // document, where the frame reports the extension origin. A
        // manifest publishing `"/*"` must not put it in reach either,
        // which is why this is checked AFTER the WAR gate.
        if (!strict) {
            // UNCONDITIONAL: this should never fire for a legitimate
            // load, and when it does the extension silently has no
            // `browser` at all — which reads as "the background page
            // never registered its listener" three layers away.
            // ONCE per process, not per request: this fires only for a
            // load that should never happen, but the whole premise of
            // the gate is that a HOSTILE page can trigger it at will,
            // and an unbounded stderr write on CEF's IO thread is a
            // free amplifier. One line still surfaces a real
            // misconfiguration.
            if (!g_ext_refusal_logged) {
                g_ext_refusal_logged = true;
                std.debug.print("sketerm-web: REFUSED bootstrap for {s} (rtype={d} frame={d})\n", .{ host, rtype_raw, @intFromBool(frame != null) });
            }
            return extResourceFor(&.{}, "text/plain", 403);
        }
        const js = buildExtBootstrap(&slot, host) orelse
            return extResourceFor("", "text/javascript", 500);
        return extResourceOwned(js, "text/javascript", 200);
    }
    if (std.mem.eql(u8, path, extorigins.GENERATED_BG_PATH)) {
        // The background DOCUMENT is fetched by a navigation, so it
        // cannot require `strict`; it must still never be a subresource
        // another origin can read.
        if (!strict and !is_navigation) {
            if (!g_ext_refusal_logged) {
                g_ext_refusal_logged = true;
                std.debug.print("sketerm-web: REFUSED generated bg for {s} (rtype={d} frame={d})\n", .{ host, rtype_raw, @intFromBool(frame != null) });
            }
            return extResourceFor(&.{}, "text/plain", 403);
        }
        const doc = buildGeneratedBackground(&slot) orelse
            return extResourceFor("", "text/html", 500);
        return extResourceOwned(doc, "text/html", 200);
    }

    var full_buf: [4096]u8 = undefined;
    const full = extassets.resolve(slot.dirSlice(), path, &full_buf) catch {
        return extResourceFor("", "text/plain", 404);
    };

    const bytes = readFileC(full, webext_max_asset) orelse
        return extResourceFor("", "text/plain", 404);
    const mime = extassets.mimeFor(full);

    // An extension HTML document gets the bootstrap `<script src>`
    // spliced in ahead of every author script; that script is what
    // defines `browser`/`chrome` before the document's first statement
    // uses one.
    if (std.mem.eql(u8, mime, "text/html")) {
        if (spliceBootstrapTag(bytes)) |s| {
            std.heap.c_allocator.free(bytes);
            return extResourceOwned(s, mime, 200);
        }
    }
    return extResourceOwned(bytes, mime, 200);
}

/// Read a whole file into a `c_allocator` buffer. IO-thread safe.
fn readFileC(path: []const u8, max: usize) ?[]u8 {
    var zbuf: [4200]u8 = undefined;
    if (path.len + 1 > zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&zbuf), c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return null;
    // A directory opens fine and then reads nothing; refuse it here so
    // `chrome-extension://host/js` is a 404 rather than an empty 200.
    if (st.st_mode & c.S_IFMT != c.S_IFREG) return null;
    const size: usize = @intCast(@max(st.st_size, 0));
    if (size > max) return null;
    if (size == 0) return std.heap.c_allocator.alloc(u8, 0) catch null;
    const buf = std.heap.c_allocator.alloc(u8, size) catch return null;
    var got: usize = 0;
    while (got < size) {
        const n = c.read(fd, buf.ptr + got, size - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != size) {
        std.heap.c_allocator.free(buf);
        return null;
    }
    return buf;
}

/// Splice the bootstrap `<script src>` into an HTML document. Returns a
/// new `c_allocator` buffer, or null when it could not be built (the
/// original is then served unchanged).
fn spliceBootstrapTag(html: []const u8) ?[]u8 {
    const off = @min(bgpage.bootstrapOffset(html), html.len);
    const out = std.heap.c_allocator.alloc(u8, html.len + bootstrap_tag.len) catch return null;
    @memcpy(out[0..off], html[0..off]);
    @memcpy(out[off..][0..bootstrap_tag.len], bootstrap_tag);
    @memcpy(out[off + bootstrap_tag.len ..], html[off..]);
    return out;
}

/// IO THREAD. The document a `background.scripts` extension gets: the
/// bootstrap followed by one classic `<script src>` per declared script,
/// in manifest order (MV2's own ordering).
fn buildGeneratedBackground(slot: *const extorigins.Lookup) ?[]u8 {
    return buildGeneratedBackgroundAlloc(slot) catch null;
}

/// Error-returning so the `errdefer` runs; as a `?[]u8` body every
/// write failure leaked the document built so far.
fn buildGeneratedBackgroundAlloc(slot: *const extorigins.Lookup) ![]u8 {
    var path_buf: [4096]u8 = undefined;
    const mpath = try std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{slot.dirSlice()});
    const bytes = readFileC(mpath, webext_max_asset) orelse return error.ManifestUnreadable;
    defer std.heap.c_allocator.free(bytes);
    var man = try extmanifest.parse(std.heap.c_allocator, bytes);
    defer man.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><title>background</title>");
    try w.writeAll(bootstrap_tag);
    if (man.background) |bg| {
        for (bg.scripts) |rel| {
            const clean = std.mem.trimStart(u8, rel, "/");
            // The path goes into an HTML attribute; anything that could
            // close it out is refused rather than escaped, because a
            // manifest naming such a file is broken either way.
            if (std.mem.indexOfAny(u8, clean, "\"'<>") != null) continue;
            try w.writeAll("<script src=\"/");
            try w.writeAll(clean);
            try w.writeAll("\"></script>");
        }
    }
    try w.writeAll("</head><body></body></html>");
    return out.toOwnedSlice();
}

/// IO THREAD. Build the extension API bootstrap script.
///
/// It calls the semantic bridge's own command entry point, which
/// `on_context_created` has already installed on this frame, so
/// `browser` exists SYNCHRONOUSLY before the document's first author
/// statement. A command sent the usual way — `execute_java_script` from
/// the browser process — would race that statement and lose.
///
/// Every input is a file on disk or a process-global secret; nothing
/// here reads main-thread state.
fn buildExtBootstrap(slot: *const extorigins.Lookup, host: []const u8) ?[]u8 {
    if (!sem_secret.ok) return null;
    return buildExtBootstrapAlloc(slot, host) catch null;
}

/// Error-returning so the `errdefer` runs; as a `?[]u8` body each of
/// the twenty-odd `catch return null` paths leaked the script so far.
fn buildExtBootstrapAlloc(slot: *const extorigins.Lookup, host: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    errdefer out.deinit();
    const w = &out.writer;

    var path_buf: [4096]u8 = undefined;
    const mpath = try std.fmt.bufPrint(&path_buf, "{s}/manifest.json", .{slot.dirSlice()});
    const man_bytes = readFileC(mpath, webext_max_asset);
    defer if (man_bytes) |b| std.heap.c_allocator.free(b);

    var msg_bytes: ?[]u8 = null;
    defer if (msg_bytes) |b| std.heap.c_allocator.free(b);
    if (slot.locale_len != 0) {
        var lbuf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&lbuf, "{s}/_locales/{s}/messages.json", .{
            slot.dirSlice(), slot.localeSlice(),
        })) |lpath| {
            msg_bytes = readFileC(lpath, webext_max_asset);
        } else |_| {}
    }

    try w.writeAll("(function(){try{var f=window[\"");
    try w.writeAll(&sem_secret.slot);
    try w.writeAll("\"];if(!f)return;f(JSON.stringify({op:\"ext-inject\",tok:\"");
    try w.writeAll(&sem_secret.nonce);
    try w.writeAll("\",priv:true,");
    if (c.getenv("SKETERM_WEB_EXT_DEBUG") != null) try w.writeAll("dbg:true,");
    try w.writeAll("ext:");
    try jsonStr(w, slot.idSlice());
    try w.writeAll(",cap:");
    try jsonStr(w, &slot.capability);
    try w.writeAll(",base:");
    var base_buf: [128]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, ext_scheme ++ "://{s}/", .{host});
    try jsonStr(w, base);
    try w.writeAll(",manifest:");
    try w.writeAll(if (man_bytes) |b| b else "{}");
    try w.writeAll(",messages:");
    try w.writeAll(if (msg_bytes) |b| b else "null");
    // A bootstrap that fails silently is an extension that is enabled,
    // loads, and does nothing at all — the exact failure mode this whole
    // area kept producing. Say so instead.
    try w.writeAll(",scripts:[],css:[]}));}catch(e){try{console.error(" ++
        "'[sketerm-webext] API bootstrap failed: '+(e&&e.stack||e));}catch(e2){}}})()");
    return out.toOwnedSlice();
}

fn extResourceFor(data: []const u8, mime: []const u8, status: c_int) [*c]cef.cef_resource_handler_t {
    const copy = std.heap.c_allocator.dupe(u8, data) catch return null;
    return extResourceOwned(copy, mime, status);
}

/// Wrap an owned buffer as a resource handler. Takes ownership of
/// `data` on success AND on failure (nothing is leaked either way).
fn extResourceOwned(data: []u8, mime: []const u8, status: c_int) [*c]cef.cef_resource_handler_t {
    const r = std.heap.c_allocator.create(ExtResource) catch {
        std.heap.c_allocator.free(data);
        return null;
    };
    r.* = .{
        .handler = std.mem.zeroes(cef.cef_resource_handler_t),
        .refs = .init(1),
        .data = data,
        .status = status,
        .mime = mime,
    };
    r.handler.base = ExtResRef.base();
    r.handler.open = extResOpen;
    r.handler.get_response_headers = extResHeaders;
    r.handler.read = extResRead;
    r.handler.cancel = extResCancel;
    return &r.handler;
}

fn extResOpen(
    self: [*c]cef.cef_resource_handler_t,
    request: [*c]cef.cef_request_t,
    handle_request: [*c]c_int,
    callback: [*c]cef.cef_callback_t,
) callconv(.c) c_int {
    releaseArg(request);
    releaseArg(callback);
    _ = ExtResource.fromSelf(self) orelse return 0;
    // The bytes are already in hand, so this is the synchronous form:
    // handled immediately, no callback, no second thread.
    if (handle_request) |hr| hr.* = 1;
    return 1;
}

fn extResHeaders(
    self: [*c]cef.cef_resource_handler_t,
    response: [*c]cef.cef_response_t,
    response_length: [*c]i64,
    _: [*c]cef.cef_string_t,
) callconv(.c) void {
    defer releaseArg(response);
    const r = ExtResource.fromSelf(self) orelse return;
    const resp: *cef.cef_response_t = response orelse return;
    if (resp.set_status) |ss| ss(resp, r.status);
    var mime = std.mem.zeroes(cef.cef_string_t);
    setStr(r.mime, &mime);
    defer cef.cef_string_utf16_clear(&mime);
    if (resp.set_mime_type) |sm| sm(resp, &mime);
    // Text formats are UTF-8; without saying so, a non-ASCII message
    // catalogue or a UTF-8 source file is decoded as Latin-1.
    if (std.mem.startsWith(u8, r.mime, "text/") or
        std.mem.eql(u8, r.mime, "application/json"))
    {
        var cs = std.mem.zeroes(cef.cef_string_t);
        setStr("utf-8", &cs);
        defer cef.cef_string_utf16_clear(&cs);
        if (resp.set_charset) |sc| sc(resp, &cs);
    }
    setResponseHeader(resp, "Access-Control-Allow-Origin", "*");
    if (response_length) |rl| rl.* = @intCast(r.data.len);
}

fn setResponseHeader(resp: *cef.cef_response_t, name: []const u8, value: []const u8) void {
    const set = resp.set_header_by_name orelse return;
    var n = std.mem.zeroes(cef.cef_string_t);
    setStr(name, &n);
    defer cef.cef_string_utf16_clear(&n);
    var v = std.mem.zeroes(cef.cef_string_t);
    setStr(value, &v);
    defer cef.cef_string_utf16_clear(&v);
    set(resp, &n, &v, 1);
}

fn extResRead(
    self: [*c]cef.cef_resource_handler_t,
    data_out: ?*anyopaque,
    bytes_to_read: c_int,
    bytes_read: [*c]c_int,
    callback: [*c]cef.cef_resource_read_callback_t,
) callconv(.c) c_int {
    releaseArg(callback);
    const r = ExtResource.fromSelf(self) orelse return 0;
    if (bytes_read) |br| br.* = 0;
    if (r.offset >= r.data.len) return 0;
    const want: usize = @intCast(@max(bytes_to_read, 0));
    const n = @min(want, r.data.len - r.offset);
    if (n == 0) return 0;
    const dst: [*]u8 = @ptrCast(data_out orelse return 0);
    @memcpy(dst[0..n], r.data[r.offset..][0..n]);
    r.offset += n;
    if (bytes_read) |br| br.* = @intCast(n);
    return 1;
}

fn extResCancel(_: [*c]cef.cef_resource_handler_t) callconv(.c) void {}

/// Register the scheme. Called from the APP, in every process — the
/// browser, the renderer and the network service must all agree that
/// `chrome-extension` is a standard, secure, CORS- and fetch-enabled
/// scheme, or a module import from an extension page is refused before
/// any factory is consulted.
fn onRegisterCustomSchemes(
    _: [*c]cef.cef_app_t,
    registrar: [*c]cef.cef_scheme_registrar_t,
) callconv(.c) void {
    const reg: *cef.cef_scheme_registrar_t = registrar orelse return;
    const add = reg.add_custom_scheme orelse return;
    var name = std.mem.zeroes(cef.cef_string_t);
    setStr(ext_scheme, &name);
    defer cef.cef_string_utf16_clear(&name);
    const ok = add(reg, &name, cef.CEF_SCHEME_OPTION_STANDARD |
        cef.CEF_SCHEME_OPTION_SECURE |
        cef.CEF_SCHEME_OPTION_CORS_ENABLED |
        cef.CEF_SCHEME_OPTION_FETCH_ENABLED);
    if (c.getenv("SKETERM_WEB_SCHEME_DEBUG") != null) {
        std.debug.print("sketerm-web: add_custom_scheme({s}) = {d}\n", .{ ext_scheme, ok });
    }
}

/// Browser process, after `cef_initialize`.
fn registerExtSchemeFactory() void {
    scheme_factory = std.mem.zeroes(cef.cef_scheme_handler_factory_t);
    scheme_factory.base = staticBase(cef.cef_scheme_handler_factory_t);
    scheme_factory.create = extSchemeCreate;
    var name = std.mem.zeroes(cef.cef_string_t);
    setStr(ext_scheme, &name);
    defer cef.cef_string_utf16_clear(&name);
    // A null domain matches every host of a STANDARD scheme, which is
    // what we want: one factory, many extensions, dispatched on the host
    // through the origin table.
    ext_scheme_ok = cef.cef_register_scheme_handler_factory(&name, null, &scheme_factory) != 0;
    // The doc calls this half the TRAP (it answers 1 even for a scheme
    // Chromium refuses to register), so the debug switch has to print it
    // — it was only printing add_custom_scheme's return, which is the
    // half that is never ambiguous.
    if (c.getenv("SKETERM_WEB_SCHEME_DEBUG") != null) {
        std.debug.print("sketerm-web: register_scheme_handler_factory(" ++ ext_scheme ++ ") = {d}\n", .{@intFromBool(ext_scheme_ok)});
    }
    if (!ext_scheme_ok) {
        std.debug.print("sketerm-web: " ++ ext_scheme ++ ":// scheme refused; " ++
            "background pages fall back to inline scripts (no ES modules)\n", .{});
    }
}

/// The same factory on ONE request context.
///
/// `cef_register_scheme_handler_factory` registers on the GLOBAL context
/// only, so a container view — which runs on its own
/// `cef_request_context_t` — has no handler for `ext_scheme` and every
/// extension url inside a container fails to load, silently: the factory
/// is never entered, so even the scheme debug env var prints nothing.
/// uBO's redirect rules rewrite trackers to extension urls, so this is
/// reached on ordinary browsing in a container, not just on an
/// extension page.
fn registerExtSchemeOn(rc: *cef.cef_request_context_t) void {
    if (!ext_scheme_ok) return;
    const reg = rc.register_scheme_handler_factory orelse return;
    var name = std.mem.zeroes(cef.cef_string_t);
    setStr(ext_scheme, &name);
    defer cef.cef_string_utf16_clear(&name);
    if (reg(rc, &name, null, &scheme_factory) == 0) {
        std.debug.print("sketerm-web: " ++ ext_scheme ++ ":// factory refused on a " ++
            "container context; extension urls will not load in it\n", .{});
    }
}

// ---------------------------------------------------------------------
// Static handler set
// ---------------------------------------------------------------------
//
// One shared instance of each handler serves every browser; callbacks
// resolve their view through the browser's CEF id. These structs are
// statics that live as long as the process, which is the ONLY reason
// their no-op add_ref/release is correct: CEF can never own or free
// them, so a refcount would have nothing to protect.

fn baseAddRef(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) void {}
fn baseRelease(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
    return 0;
}
fn baseHasOne(_: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
    return 1;
}

/// The refcount vtable for a HEAP-owned CEF client struct — the ones
/// CEF really can outlive us with (`CookieJob`, `FilterFetch`,
/// `ExtResource`), as opposed to the process-lifetime statics below.
///
/// `Owner` must carry `refs: std.atomic.Value(u32)` and a
/// `destroyOwned` that releases everything and frees itself; `field` is
/// the CEF struct embedded in it, which must be its FIRST field because
/// CEF is handed `&owner.<field>` and hands the same pointer back as
/// the base. `base.size` is the CEF struct's size, not the owner's:
/// the engine validates the size of the interface it was given.
fn HeapRef(comptime Owner: type, comptime field: []const u8) type {
    return struct {
        const Self = @This();
        const Struct = @FieldType(Owner, field);

        comptime {
            std.debug.assert(@offsetOf(Owner, field) == 0);
        }

        pub fn owner(b: [*c]cef.cef_base_ref_counted_t) *Owner {
            const p: *Struct = @ptrCast(@alignCast(b));
            return @fieldParentPtr(field, p);
        }

        pub fn addRef(b: [*c]cef.cef_base_ref_counted_t) callconv(.c) void {
            _ = owner(b).refs.fetchAdd(1, .monotonic);
        }

        pub fn release(b: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
            const o = owner(b);
            if (o.refs.fetchSub(1, .acq_rel) != 1) return 0;
            o.destroyOwned();
            return 1;
        }

        pub fn hasOneRef(b: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
            return if (owner(b).refs.load(.acquire) == 1) 1 else 0;
        }

        pub fn hasAtLeastOneRef(b: [*c]cef.cef_base_ref_counted_t) callconv(.c) c_int {
            return if (owner(b).refs.load(.acquire) >= 1) 1 else 0;
        }

        pub fn base() cef.cef_base_ref_counted_t {
            return .{
                .size = @sizeOf(Struct),
                .add_ref = Self.addRef,
                // Qualified: this file also has a free `release` helper
                // for the references CEF hands US.
                .release = Self.release,
                .has_one_ref = Self.hasOneRef,
                .has_at_least_one_ref = Self.hasAtLeastOneRef,
            };
        }
    };
}

fn staticBase(comptime T: type) cef.cef_base_ref_counted_t {
    return .{
        .size = @sizeOf(T),
        .add_ref = baseAddRef,
        .release = baseRelease,
        .has_one_ref = baseHasOne,
        .has_at_least_one_ref = baseHasOne,
    };
}

var app: cef.cef_app_t = undefined;
var client: cef.cef_client_t = undefined;
var accessibility_handler: cef.cef_accessibility_handler_t = undefined;
var render_handler: cef.cef_render_handler_t = undefined;
var display_handler: cef.cef_display_handler_t = undefined;
var life_span_handler: cef.cef_life_span_handler_t = undefined;
var load_handler: cef.cef_load_handler_t = undefined;
var request_handler: cef.cef_request_handler_t = undefined;
var resource_request_handler: cef.cef_resource_request_handler_t = undefined;
var find_handler: cef.cef_find_handler_t = undefined;
var context_menu_handler: cef.cef_context_menu_handler_t = undefined;
var permission_handler: cef.cef_permission_handler_t = undefined;
var download_handler: cef.cef_download_handler_t = undefined;
var bp_handler: cef.cef_browser_process_handler_t = undefined;
var rp_handler: cef.cef_render_process_handler_t = undefined;
var v8_handler: cef.cef_v8_handler_t = undefined;
/// The `print_to_pdf` completion callback. A process-lifetime static
/// like every other handler here, and for the same reason its no-op
/// refcount is sound: CEF may hold references to it forever and can
/// never free it. It carries no per-request state — the path in the
/// callback correlates the answer (see `Host.onPrintDone`).
var pdf_callback: cef.cef_pdf_print_callback_t = undefined;

/// The jar-flush completion callback: same static-lifetime reasoning as
/// `pdf_callback`; per-request state lives in `Host.pending_flushes`.
var flush_callback: cef.cef_completion_callback_t = undefined;

fn onFlushComplete(_: [*c]cef.cef_completion_callback_t) callconv(.c) void {
    const host = g_host orelse return;
    host.flushCompleted();
}

/// Milliseconds until CEF next wants `pump()`; -1 = nothing scheduled.
var pump_delay_ms: i64 = -1;

fn onScheduleMessagePumpWork(_: [*c]cef.cef_browser_process_handler_t, delay: i64) callconv(.c) void {
    pump_delay_ms = delay;
}

/// Hand the semantic-layer secrets to every child process; the renderer
/// picks them back up in `onWebKitInitialized`.
fn onBeforeChildProcessLaunch(
    _: [*c]cef.cef_browser_process_handler_t,
    command_line: [*c]cef.cef_command_line_t,
) callconv(.c) void {
    defer releaseArg(command_line);
    if (!sem_secret.ok) return;
    const cl: *cef.cef_command_line_t = command_line orelse return;
    const add = cl.append_switch_with_value orelse return;
    var name = std.mem.zeroes(cef.cef_string_t);
    setStr(sem_switch, &name);
    defer cef.cef_string_utf16_clear(&name);
    var buf: [96]u8 = undefined;
    const joined = std.fmt.bufPrint(&buf, "{s}:{s}", .{ &sem_secret.nonce, &sem_secret.slot }) catch return;
    var value = std.mem.zeroes(cef.cef_string_t);
    setStr(joined, &value);
    defer cef.cef_string_utf16_clear(&value);
    add(cl, &name, &value);
}

fn getBrowserProcessHandler(_: [*c]cef.cef_app_t) callconv(.c) [*c]cef.cef_browser_process_handler_t {
    return &bp_handler;
}

/// Poll timeout CEF asked for, clamped to `cap` ms.
pub fn pumpTimeoutMs(cap: i64) i64 {
    if (pump_delay_ms < 0) return cap;
    return @min(@max(pump_delay_ms, 0), cap);
}

fn getRenderHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_render_handler_t {
    return &render_handler;
}
fn getDisplayHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_display_handler_t {
    return &display_handler;
}
fn getLifeSpanHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_life_span_handler_t {
    return &life_span_handler;
}
fn getLoadHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_load_handler_t {
    return &load_handler;
}
/// MEASURED, and the reason a permission prompt does not reach the GUI
/// today: the installed CEF running an ALLOY windowless browser never
/// asks the client for this handler at all -- a geolocation request is
/// denied inside the engine and `on_show_permission_prompt` is never
/// called (smoke-web stage 22g pins that, and FAILS the day it
/// changes). The handler below is complete and correct for the
/// configurations that do consult it; nothing here can make the engine
/// ask.
fn getPermissionHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_permission_handler_t {
    return &permission_handler;
}

fn getDownloadHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_download_handler_t {
    return &download_handler;
}

fn getRequestHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_request_handler_t {
    return &request_handler;
}
fn getFindHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_find_handler_t {
    return &find_handler;
}
fn getContextMenuHandler(_: [*c]cef.cef_client_t) callconv(.c) [*c]cef.cef_context_menu_handler_t {
    return &context_menu_handler;
}

fn installHandlers() void {
    render_handler = std.mem.zeroes(cef.cef_render_handler_t);
    render_handler.base = staticBase(cef.cef_render_handler_t);
    render_handler.get_view_rect = onGetViewRect;
    render_handler.get_screen_info = onGetScreenInfo;
    render_handler.on_paint = onPaint;
    // BOTH are installed, always. Which one Chromium calls is its own
    // decision per frame: with shared textures off it is `on_paint`, and
    // with them on it is `on_accelerated_paint` right up until GPU
    // compositing goes away under it (a GPU process crash, a driver
    // reset), at which point it silently goes back to `on_paint`. The
    // client handles both frame families for the same reason.
    render_handler.on_accelerated_paint = onAcceleratedPaint;
    render_handler.on_scroll_offset_changed = onScrollOffsetChanged;
    render_handler.get_accessibility_handler = getAccessibilityHandler;

    accessibility_handler = std.mem.zeroes(cef.cef_accessibility_handler_t);
    accessibility_handler.base = staticBase(cef.cef_accessibility_handler_t);
    accessibility_handler.on_accessibility_tree_change = onAxTreeChange;
    accessibility_handler.on_accessibility_location_change = onAxLocationChange;

    display_handler = std.mem.zeroes(cef.cef_display_handler_t);
    display_handler.base = staticBase(cef.cef_display_handler_t);
    display_handler.on_address_change = onAddressChange;
    display_handler.on_title_change = onTitleChange;
    display_handler.on_favicon_urlchange = onFaviconChange;
    display_handler.on_console_message = onConsoleMessage;
    display_handler.on_cursor_change = onCursorChange;

    life_span_handler = std.mem.zeroes(cef.cef_life_span_handler_t);
    life_span_handler.base = staticBase(cef.cef_life_span_handler_t);
    life_span_handler.on_before_popup = onBeforePopup;
    life_span_handler.on_after_created = onAfterCreated;
    life_span_handler.on_before_close = onBeforeClose;

    load_handler = std.mem.zeroes(cef.cef_load_handler_t);
    load_handler.base = staticBase(cef.cef_load_handler_t);
    load_handler.on_loading_state_change = onLoadingStateChange;
    load_handler.on_load_start = onLoadStart;
    load_handler.on_load_end = onLoadEnd;
    load_handler.on_load_error = onLoadError;

    request_handler = std.mem.zeroes(cef.cef_request_handler_t);
    request_handler.base = staticBase(cef.cef_request_handler_t);
    request_handler.on_render_process_terminated = onRenderProcessTerminated;
    // Interception: the request handler hands out ONE shared resource
    // request handler, whose IO-thread callbacks run the filter engine
    // inline (see the Intercept registry above).
    request_handler.get_resource_request_handler = onGetResourceRequestHandler;

    resource_request_handler = std.mem.zeroes(cef.cef_resource_request_handler_t);
    resource_request_handler.base = staticBase(cef.cef_resource_request_handler_t);
    // Cookie sync: the filter is handed out only while a client
    // subscribed (see onGetCookieAccessFilter).
    resource_request_handler.get_cookie_access_filter = onGetCookieAccessFilter;
    resource_request_handler.on_before_resource_load = onBeforeResourceLoad;
    resource_request_handler.on_resource_response = onResourceResponse;
    resource_request_handler.on_resource_load_complete = onResourceLoadComplete;
    request_handler.on_certificate_error = onCertificateError;

    permission_handler = std.mem.zeroes(cef.cef_permission_handler_t);
    permission_handler.base = staticBase(cef.cef_permission_handler_t);
    permission_handler.on_show_permission_prompt = onShowPermissionPrompt;
    permission_handler.on_request_media_access_permission = onRequestMediaAccess;
    permission_handler.on_dismiss_permission_prompt = onDismissPermissionPrompt;

    download_handler = std.mem.zeroes(cef.cef_download_handler_t);
    download_handler.base = staticBase(cef.cef_download_handler_t);
    download_handler.can_download = onCanDownload;
    download_handler.on_before_download = onBeforeDownload;
    download_handler.on_download_updated = onDownloadUpdated;

    pdf_callback = std.mem.zeroes(cef.cef_pdf_print_callback_t);
    pdf_callback.base = staticBase(cef.cef_pdf_print_callback_t);
    pdf_callback.on_pdf_print_finished = onPdfPrintFinished;

    cookie_access_filter = std.mem.zeroes(cef.cef_cookie_access_filter_t);
    cookie_access_filter.base = staticBase(cef.cef_cookie_access_filter_t);
    cookie_access_filter.can_send_cookie = onCanSendCookie;
    cookie_access_filter.can_save_cookie = onCanSaveCookie;

    flush_callback = std.mem.zeroes(cef.cef_completion_callback_t);
    flush_callback.base = staticBase(cef.cef_completion_callback_t);
    flush_callback.on_complete = onFlushComplete;

    find_handler = std.mem.zeroes(cef.cef_find_handler_t);
    find_handler.base = staticBase(cef.cef_find_handler_t);
    find_handler.on_find_result = onFindResult;

    context_menu_handler = std.mem.zeroes(cef.cef_context_menu_handler_t);
    context_menu_handler.base = staticBase(cef.cef_context_menu_handler_t);
    context_menu_handler.run_context_menu = onRunContextMenu;

    client = std.mem.zeroes(cef.cef_client_t);
    client.base = staticBase(cef.cef_client_t);
    client.get_render_handler = getRenderHandler;
    client.get_display_handler = getDisplayHandler;
    client.get_life_span_handler = getLifeSpanHandler;
    client.get_load_handler = getLoadHandler;
    client.get_request_handler = getRequestHandler;
    client.get_find_handler = getFindHandler;
    client.get_context_menu_handler = getContextMenuHandler;
    client.get_permission_handler = getPermissionHandler;
    client.get_download_handler = getDownloadHandler;
    client.on_process_message_received = onProcessMessage;
}

/// Browser-process end of the semantic bridge.
fn onProcessMessage(
    _: [*c]cef.cef_client_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: cef.cef_process_id_t,
    message: [*c]cef.cef_process_message_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(message);
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    var payload = semPayload(message) orelse return 0;
    defer payload.free();
    const main = isMainFrame(frame);
    // A SUBFRAME may speak the `ext-*` sub-protocol — that is how a
    // content script in an ad iframe calls `browser.*` at all — but not
    // the semantic one: only the main frame's walk maps onto a view's
    // shadow tree, and an unsolicited subframe walk would corrupt it.
    if (!main and !host.payloadIsExt(payload.slice())) return 0;
    v.cur_frame_id = if (main) 0 else blk: {
        const f = frame orelse break :blk 0;
        const gi = f.*.get_identifier orelse break :blk 0;
        var ibuf: [128]u8 = undefined;
        const ident = userfreeInto(gi(f), &ibuf);
        if (ident.len == 0) break :blk 0;
        break :blk v.frameIdFor(host.gpa, ident);
    };
    defer v.cur_frame_id = 0;
    host.onScriptMessage(v, payload.slice());
    return 1;
}

/// Resolve the view a callback's browser belongs to. During
/// create_browser_sync the browser is not registered yet, so the
/// in-flight view answers instead — and likewise for the inspector
/// browser CEF builds asynchronously, whose `get_view_rect` is asked
/// before `on_after_created` ever runs.
/// Presenter seat input -> the same engine input the wire carries. The
/// presenter calls these between poll iterations, outside any client
/// dispatch, so `find` applies no ownership check and the view resolves
/// whichever connection created it.
fn presenterPointer(ctx: ?*anyopaque, view: u32, kind: presenter.PointerKind, x: i32, y: i32, button: u8, clicks: u8, mods: u32) void {
    const host: *Host = @ptrCast(@alignCast(ctx orelse return));
    // A press from the viewer's seat is also focus: the assistant's
    // client never sends `input_focus` for a page it did not click.
    if (kind == .down) host.focus(.{ .view = view, .focused = 1 });
    host.pointer(.{
        .view = view,
        .kind = @intFromEnum(@as(proto.PointerKind, switch (kind) {
            .move => .move,
            .down => .down,
            .up => .up,
            .leave => .leave,
        })),
        .x = x,
        .y = y,
        .button = button,
        .clicks = clicks,
        .mods = mods,
    });
}

fn presenterScroll(ctx: ?*anyopaque, view: u32, x: i32, y: i32, dx: i32, dy: i32, mods: u32) void {
    const host: *Host = @ptrCast(@alignCast(ctx orelse return));
    host.scroll(.{ .view = view, .x = x, .y = y, .dx = dx, .dy = dy, .mods = mods });
}

fn presenterKey(ctx: ?*anyopaque, view: u32, keysym: u32, keycode: u32, mods: u32, pressed: bool) void {
    const host: *Host = @ptrCast(@alignCast(ctx orelse return));
    host.key(.{
        .view = view,
        .kind = @intFromEnum(@as(proto.KeyKind, if (pressed) .down else .up)),
        .keyval = keysym,
        .keycode = keycode,
        .mods = mods,
        .text = "",
    });
}

fn viewOf(browser: [*c]cef.cef_browser_t) ?*View {
    const host = g_host orelse return null;
    if (browser != null) {
        if (browser.*.get_identifier) |gi| {
            if (host.findCef(gi(browser))) |v| return v;
        }
    }
    return host.pending orelse host.adopting;
}

/// The view rect the engine renders: LOGICAL (DIP) in software mode,
/// where CEF multiplies it by `get_screen_info`'s device_scale_factor to
/// get the paint size, and PHYSICAL in accelerated mode, where that
/// factor is ignored and the zoom level carries the scale instead. See
/// `scaleViaZoom`.
fn onGetViewRect(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    rect: [*c]cef.cef_rect_t,
) callconv(.c) void {
    defer releaseArg(browser);
    const v = viewOf(browser) orelse {
        rect.* = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
        return;
    };
    rect.* = viewRect(v);
}

fn viewRect(v: *const View) cef.cef_rect_t {
    if (scaleViaZoom()) return .{ .x = 0, .y = 0, .width = v.pw, .height = v.ph };
    return .{ .x = 0, .y = 0, .width = v.w, .height = v.h };
}

/// The DPR the PAGE lays out at (and picks 2x images / hints text for).
/// `rect`/`available_rect` are in the same space as the view rect.
///
/// In accelerated mode the factor is deliberately 1: the engine ignores
/// it there, and reporting the real scale as well as zooming would
/// double-apply it on any build that ever started honouring it again.
fn onGetScreenInfo(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    info: [*c]cef.cef_screen_info_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    const v = viewOf(browser) orelse return 0;
    info.* = std.mem.zeroes(cef.cef_screen_info_t);
    info.*.size = @sizeOf(cef.cef_screen_info_t);
    info.*.device_scale_factor = if (scaleViaZoom())
        1.0
    else
        @as(f32, @floatFromInt(v.scale_x1000)) / 1000.0;
    info.*.depth = 32;
    info.*.depth_per_component = 8;
    info.*.rect = viewRect(v);
    info.*.available_rect = info.*.rect;
    return 1;
}

/// Put the view's zoom into the browser: the device scale (which lives
/// in the zoom level in accelerated mode — see `scaleViaZoom`) plus the
/// client's user zoom (`set_zoom`, log-scale level x100). The two ADD,
/// because Chromium zoom levels are logarithmic (factor = 1.2^level).
///
/// Chromium resets zoom per navigation, so this runs on every load start
/// as well as at creation, on a scale change and on `set_zoom`.
fn applyZoom(v: *View) void {
    const base: f64 = if (scaleViaZoom()) zoomLevelFor(v.scale_x1000) else 0.0;
    const user: f64 = @as(f64, @floatFromInt(v.user_zoom_x100)) / 100.0;
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    if (host.set_zoom_level) |sz| sz(host, base + user);
}

/// Convert LOGICAL wire coordinates into the engine's view-rect space.
/// The two differ exactly when the view rect is physical.
fn viewPoint(v: *const View, x: i32, y: i32) struct { x: c_int, y: c_int } {
    if (!scaleViaZoom()) return .{ .x = x, .y = y };
    const s: i64 = @intCast(v.scale_x1000);
    return .{
        .x = @intCast(@divTrunc(@as(i64, x) * s, 1000)),
        .y = @intCast(@divTrunc(@as(i64, y) * s, 1000)),
    };
}

/// The inverse of `viewPoint`: view-rect coordinates (what the engine's
/// hit tests report) back into LOGICAL wire coordinates.
fn logicalPoint(v: *const View, x: c_int, y: c_int) struct { x: i32, y: i32 } {
    if (!scaleViaZoom()) return .{ .x = x, .y = y };
    const s: i64 = @intCast(@max(@as(i64, v.scale_x1000), 1));
    return .{
        .x = @intCast(@divTrunc(@as(i64, x) * 1000, s)),
        .y = @intCast(@divTrunc(@as(i64, y) * 1000, s)),
    };
}

// ── accessibility (0x70 block, capability "a11y") ────────────────────
//
// The engine serializes AX updates as `cef_value_t` dictionaries; this
// section translates them into the wire's engine-agnostic frames.
// PAYLOAD SHAPE (verified empirically on CEF 151 with
// SKETERM_WEB_AX_DEBUG=1, which dumps the raw value as JSON):
//   tree change: { "ax_tree_id": "<token>",
//                  "updates": [ { "root_id": int, "node_id_to_clear": int,
//                                 "tree_data": {...}, "nodes": [ {...} ] } ],
//                  "events":  [ { "event_type": "...", "id": int } ] }
//   node:        { "id": int, "role": "camelCaseToken",
//                  "child_ids": [int], "location": {x,y,width,height},
//                  "offset_container_id": int, "attributes": {...},
//                  "state": {...} }
//   location:    [ { "id": int, "ax_tree_id": "...",
//                    "new_location": {x,y,width,height} } ]
// Anything absent decodes as a default, and anything extra is ignored,
// so a Chromium that grows its serializer cannot break the helper.
//
// ATTRIBUTION: the accessibility callbacks carry NO browser pointer —
// only the tree-id token inside the payload. `axResolveView` therefore
// joins on the token a view was last seen with, and rebinds an unknown
// token to the SINGLE a11y-enabled view when there is exactly one
// (navigation mints a fresh token per document). With several enabled
// views an unknown token that matches no view is dropped: wrong
// attribution would read one page's tree to another page's reader.

fn getAccessibilityHandler(_: [*c]cef.cef_render_handler_t) callconv(.c) [*c]cef.cef_accessibility_handler_t {
    return &accessibility_handler;
}

/// Push the view's a11y flag into the engine. STATE_DISABLED (not
/// STATE_DEFAULT) on the off edge: default would leave it steerable by
/// command-line switches.
fn applyA11yState(v: *View) void {
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    if (host.set_accessibility_state) |set|
        set(host, if (v.a11y) cef.STATE_ENABLED else cef.STATE_DISABLED);
}

/// The view an AX payload belongs to (see the section header).
fn axResolveView(host: *Host, tree_id: []const u8) ?*View {
    if (tree_id.len != 0) {
        for (host.views.items) |v| {
            if (v.a11y and std.mem.eql(u8, v.ax_tree, tree_id)) return v;
        }
    }
    var only: ?*View = null;
    for (host.views.items) |v| {
        if (!v.a11y or v.browser == null) continue;
        // A background page is never a client view, so its tree must
        // never be adoptable as one. `spawnBackground` disables its AX
        // explicitly, which already prevents this; the skip is here so
        // a future path that forgets cannot silently hand a reader a
        // hidden 1x1 page in place of the page it is reading.
        if (v.webext_bg) continue;
        if (only != null) return null; // ambiguous — drop, never guess
        only = v;
    }
    const v = only orelse return null;
    if (tree_id.len != 0) {
        const dup = host.gpa.dupe(u8, tree_id) catch return null;
        if (v.ax_tree.len != 0) host.gpa.free(v.ax_tree);
        v.ax_tree = dup;
    }
    return v;
}

/// A UTF-16 CEF string key, for the dictionary getters.
const KeyStr = struct {
    s: cef.cef_string_t,

    fn init(key: []const u8) KeyStr {
        var out = std.mem.zeroes(cef.cef_string_t);
        setStr(key, &out);
        return .{ .s = out };
    }

    fn deinit(self: *KeyStr) void {
        cef.cef_string_utf16_clear(&self.s);
    }
};

fn dType(d: *cef.cef_dictionary_value_t, key: []const u8) cef.cef_value_type_t {
    var k = KeyStr.init(key);
    defer k.deinit();
    const gt = d.get_type orelse return cef.VTYPE_INVALID;
    return gt(d, &k.s);
}

fn dInt(d: *cef.cef_dictionary_value_t, key: []const u8) ?i32 {
    switch (dType(d, key)) {
        cef.VTYPE_INT => {},
        cef.VTYPE_DOUBLE => {
            var k = KeyStr.init(key);
            defer k.deinit();
            const gd = d.get_double orelse return null;
            return @intFromFloat(std.math.clamp(gd(d, &k.s), -2147483648.0, 2147483647.0));
        },
        else => return null,
    }
    var k = KeyStr.init(key);
    defer k.deinit();
    const gi = d.get_int orelse return null;
    return gi(d, &k.s);
}

/// UTF-8 copy of a string entry, allocated from `alloc` (an arena in
/// every caller). Null when absent or not a string.
fn dStr(alloc: std.mem.Allocator, d: *cef.cef_dictionary_value_t, key: []const u8) ?[]u8 {
    if (dType(d, key) != cef.VTYPE_STRING) return null;
    var k = KeyStr.init(key);
    defer k.deinit();
    const gs = d.get_string orelse return null;
    const raw = gs(d, &k.s);
    if (raw == null) return null;
    defer cef.cef_string_userfree_utf16_free(raw);
    var s = Utf8.init(raw);
    defer s.free();
    return alloc.dupe(u8, s.slice()) catch null;
}

/// Referenced; caller releases.
fn dDict(d: *cef.cef_dictionary_value_t, key: []const u8) ?*cef.cef_dictionary_value_t {
    if (dType(d, key) != cef.VTYPE_DICTIONARY) return null;
    var k = KeyStr.init(key);
    defer k.deinit();
    const gd = d.get_dictionary orelse return null;
    return gd(d, &k.s);
}

/// Referenced; caller releases.
fn dList(d: *cef.cef_dictionary_value_t, key: []const u8) ?*cef.cef_list_value_t {
    if (dType(d, key) != cef.VTYPE_LIST) return null;
    var k = KeyStr.init(key);
    defer k.deinit();
    const gl = d.get_list orelse return null;
    return gl(d, &k.s);
}

fn listLen(l: *cef.cef_list_value_t) usize {
    const gs = l.get_size orelse return 0;
    return gs(l);
}

/// Referenced; caller releases.
fn listDict(l: *cef.cef_list_value_t, i: usize) ?*cef.cef_dictionary_value_t {
    const gt = l.get_type orelse return null;
    if (gt(l, i) != cef.VTYPE_DICTIONARY) return null;
    const gd = l.get_dictionary orelse return null;
    return gd(l, i);
}

/// Engine role token -> wire role token: the ARIA name where one
/// exists, a small extension set otherwise, kebab-cased pass-through
/// (into `buf`) as the self-describing escape for the long tail.
fn axRole(buf: []u8, engine: []const u8) []const u8 {
    const Map = struct { from: []const u8, to: []const u8 };
    const map = [_]Map{
        .{ .from = "rootWebArea", .to = "document" },
        .{ .from = "genericContainer", .to = "generic" },
        .{ .from = "staticText", .to = "text" },
        .{ .from = "textField", .to = "textbox" },
        .{ .from = "textFieldWithComboBox", .to = "combobox" },
        .{ .from = "checkBox", .to = "checkbox" },
        .{ .from = "radioButton", .to = "radio" },
        .{ .from = "listBox", .to = "listbox" },
        .{ .from = "listBoxOption", .to = "option" },
        .{ .from = "menuListPopup", .to = "listbox" },
        .{ .from = "menuListOption", .to = "option" },
        .{ .from = "listItem", .to = "listitem" },
        .{ .from = "listMarker", .to = "generic" },
        .{ .from = "menuBar", .to = "menubar" },
        .{ .from = "menuItem", .to = "menuitem" },
        .{ .from = "tabList", .to = "tablist" },
        .{ .from = "tabPanel", .to = "tabpanel" },
        .{ .from = "treeItem", .to = "treeitem" },
        .{ .from = "columnHeader", .to = "columnheader" },
        .{ .from = "rowHeader", .to = "rowheader" },
        .{ .from = "contentInfo", .to = "contentinfo" },
        .{ .from = "alertDialog", .to = "alertdialog" },
        .{ .from = "progressIndicator", .to = "progressbar" },
        .{ .from = "spinButton", .to = "spinbutton" },
        .{ .from = "disclosureTriangle", .to = "button" },
        .{ .from = "iframePresentational", .to = "iframe" },
        .{ .from = "splitter", .to = "separator" },
        .{ .from = "figcaption", .to = "caption" },
        .{ .from = "cell", .to = "cell" },
        .{ .from = "docAbstract", .to = "section" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, engine, m.from)) return m.to;
    }
    // Kebab-case camelCase into buf; anything that does not fit is
    // truncated rather than dropped (a long unknown token beats none).
    var n: usize = 0;
    for (engine) |ch| {
        if (n + 2 > buf.len) break;
        if (ch >= 'A' and ch <= 'Z') {
            buf[n] = '-';
            buf[n + 1] = ch - 'A' + 'a';
            n += 2;
        } else {
            buf[n] = ch;
            n += 1;
        }
    }
    return buf[0..n];
}

/// Fold the engine's per-node "state" dictionary (name -> bool) into
/// the wire's `ax_*` bits.
fn axStateBits(state: *cef.cef_dictionary_value_t) u64 {
    const Map = struct { name: []const u8, bit: u64 };
    const map = [_]Map{
        .{ .name = "focusable", .bit = proto.ax_focusable },
        .{ .name = "focused", .bit = proto.ax_focused },
        .{ .name = "editable", .bit = proto.ax_editable },
        .{ .name = "richlyEditable", .bit = proto.ax_editable },
        .{ .name = "protected", .bit = proto.ax_protected },
        .{ .name = "required", .bit = proto.ax_required },
        .{ .name = "invisible", .bit = proto.ax_invisible },
        .{ .name = "ignored", .bit = proto.ax_ignored },
        .{ .name = "multiline", .bit = proto.ax_multiline },
        .{ .name = "default", .bit = proto.ax_default },
        .{ .name = "hovered", .bit = proto.ax_hovered },
        .{ .name = "visited", .bit = proto.ax_visited },
        .{ .name = "collapsed", .bit = proto.ax_collapsed },
        .{ .name = "expanded", .bit = proto.ax_expanded },
        .{ .name = "busy", .bit = proto.ax_busy },
        .{ .name = "modal", .bit = proto.ax_modal },
        .{ .name = "multiselectable", .bit = proto.ax_multiselectable },
        .{ .name = "selected", .bit = proto.ax_selected },
        .{ .name = "autofillAvailable", .bit = proto.ax_autofill_available },
    };
    var bits: u64 = 0;
    for (map) |m| {
        var k = KeyStr.init(m.name);
        defer k.deinit();
        const hk = state.has_key orelse break;
        if (hk(state, &k.s) == 0) continue;
        // Presence alone is the signal on a bool dict, but read the
        // value when it is one, so an explicit false stays false.
        const gt = state.get_type orelse break;
        if (gt(state, &k.s) == cef.VTYPE_BOOL) {
            const gb = state.get_bool orelse break;
            if (gb(state, &k.s) == 0) continue;
        }
        bits |= m.bit;
    }
    return bits;
}

/// Curated attribute forwarding: engine attribute -> wire attr key.
/// Everything else is dropped on purpose — the wire carries meaning,
/// not the engine's whole serializer.
const ax_attr_map = [_]struct { from: []const u8, to: []const u8 }{
    .{ .from = "htmlTag", .to = "tag" },
    .{ .from = "url", .to = "url" },
    .{ .from = "placeholder", .to = "placeholder" },
    .{ .from = "language", .to = "lang" },
    .{ .from = "roleDescription", .to = "role-description" },
    .{ .from = "hierarchicalLevel", .to = "level" },
    .{ .from = "liveStatus", .to = "live" },
    .{ .from = "invalidState", .to = "invalid" },
    .{ .from = "valueForRange", .to = "value-now" },
    .{ .from = "minValueForRange", .to = "value-min" },
    .{ .from = "maxValueForRange", .to = "value-max" },
    .{ .from = "autoComplete", .to = "autocomplete" },
    .{ .from = "accessKey", .to = "access-key" },
    .{ .from = "keyShortcuts", .to = "key-shortcuts" },
    // The engine's OWN verb for a node's default action ("press",
    // "check", "uncheck", "jump", "open", ...). A projection announces
    // this to the user, so taking Chromium's word beats guessing from
    // the role. "clickAncestor" marks a node whose click belongs to an
    // ancestor (static text inside a button) and must NOT read as
    // actionable; the consumer filters it.
    .{ .from = "defaultActionVerb", .to = "default-action" },
};

/// Any attribute value as its wire string, arena-allocated.
fn axAttrString(alloc: std.mem.Allocator, d: *cef.cef_dictionary_value_t, key: []const u8) ?[]const u8 {
    switch (dType(d, key)) {
        cef.VTYPE_STRING => return dStr(alloc, d, key),
        cef.VTYPE_INT => {
            const v = dInt(d, key) orelse return null;
            return std.fmt.allocPrint(alloc, "{d}", .{v}) catch null;
        },
        cef.VTYPE_DOUBLE => {
            var k = KeyStr.init(key);
            defer k.deinit();
            const gd = d.get_double orelse return null;
            return std.fmt.allocPrint(alloc, "{d}", .{gd(d, &k.s)}) catch null;
        },
        cef.VTYPE_BOOL => {
            var k = KeyStr.init(key);
            defer k.deinit();
            const gb = d.get_bool orelse return null;
            return if (gb(d, &k.s) != 0) "true" else "false";
        },
        else => return null,
    }
}

var g_ax_debug: enum { unknown, off, on } = .unknown;

fn axDebug() bool {
    if (g_ax_debug == .unknown)
        g_ax_debug = if (c.getenv("SKETERM_WEB_AX_DEBUG") != null) .on else .off;
    return g_ax_debug == .on;
}

/// Print one serialized accessibility payload as JSON.
///
/// `value` is a NON-SELF argument of `cef_write_json`, so the wrapper
/// releases one reference on receipt, before writing anything. The caller
/// holds the only reference to the callback parameter it passes here and
/// keeps reading it afterwards, so the debug dump pays for its own
/// consumption with an add_ref rather than donating the caller's.
fn axDump(label: []const u8, value: *cef.cef_value_t) void {
    // `cef_write_json` consumes one reference; without a way to pay for
    // it the caller's only reference would be donated, so dump nothing.
    const add = value.base.add_ref orelse return;
    add(&value.base);
    const raw = cef.cef_write_json(value, cef.JSON_WRITER_DEFAULT);
    if (raw == null) return;
    defer cef.cef_string_userfree_utf16_free(raw);
    var s = Utf8.init(raw);
    defer s.free();
    std.debug.print("sketerm-web ax {s}: {s}\n", .{ label, s.slice() });
}

/// One serialized tree update -> one `ev_a11y_tree` frame.
fn axEmitUpdate(
    host: *Host,
    v: *View,
    upd: *cef.cef_dictionary_value_t,
    alloc: std.mem.Allocator,
) void {
    var focus_id: u32 = 0;
    var caret: ?proto.EvA11yCaret = null;
    if (dDict(upd, "tree_data")) |td| {
        defer release(@ptrCast(&td.base));
        if (dInt(td, "focus_id")) |f| focus_id = @bitCast(f);
        // The caret/selection lives in tree_data, NOT on any node: it
        // is a pair of (node, offset) endpoints that may straddle
        // nodes. Absent keys mean this engine build does not report
        // it, which degrades to "no caret" rather than to a wrong one.
        if (dInt(td, "sel_focus_object_id")) |fo| {
            const fid: u32 = @bitCast(fo);
            if (fid != 0) {
                const aid: u32 = if (dInt(td, "sel_anchor_object_id")) |ao|
                    @bitCast(ao)
                else
                    fid;
                caret = .{
                    .view = v.id,
                    .anchor_id = aid,
                    .anchor_offset = @intCast(dInt(td, "sel_anchor_offset") orelse 0),
                    .focus_id = fid,
                    .focus_offset = @intCast(dInt(td, "sel_focus_offset") orelse 0),
                };
            }
        }
    }

    var field_sel: ?[2]i32 = null;
    var nodes_buf: std.ArrayList(u8) = .empty;
    defer nodes_buf.deinit(host.gpa);
    var w = proto.A11yNodeWriter{ .gpa = host.gpa, .buf = &nodes_buf };

    if (dList(upd, "nodes")) |nodes| {
        defer release(@ptrCast(&nodes.base));
        var i: usize = 0;
        const n = listLen(nodes);
        while (i < n) : (i += 1) {
            const nd = listDict(nodes, i) orelse continue;
            defer release(@ptrCast(&nd.base));
            axPutNode(&w, nd, alloc) catch return; // OOM: drop frame
            // A text form control's selection is NOT in tree_data:
            // MEASURED on CEF 151, setSelectionRange(2,6) in an
            // <input> arrives there as a COLLAPSED caret at 2. The
            // real range is on the node, so prefer it for the focused
            // field. Absent keys change nothing.
            if (focus_id != 0 and field_sel == null) {
                if (dInt(nd, "id")) |nid| {
                    if (@as(u32, @bitCast(nid)) == focus_id) {
                        if (dDict(nd, "attributes")) |at| {
                            defer release(@ptrCast(&at.base));
                            const ss = dInt(at, "textSelStart");
                            const se = dInt(at, "textSelEnd");
                            if (ss != null and se != null and ss.? >= 0 and se.? >= 0)
                                field_sel = .{ ss.?, se.? };
                        }
                    }
                }
            }
        }
    }
    if (field_sel) |fs| caret = .{
        .view = v.id,
        .anchor_id = focus_id,
        .anchor_offset = fs[0],
        .focus_id = focus_id,
        .focus_offset = fs[1],
    };

    host.post(proto.EvA11yTree{
        .view = v.id,
        .root_id = @bitCast(dInt(upd, "root_id") orelse 0),
        .node_id_to_clear = @bitCast(dInt(upd, "node_id_to_clear") orelse 0),
        .focus_id = focus_id,
        .nodes = .{ .s = nodes_buf.items },
    });
    // AFTER the tree: the caret names a node, and a client that has
    // not seen that node yet can only clamp the offset to nothing.
    if (caret) |cr| {
        if (!v.ax_caret_sent or !axCaretEql(v.ax_caret, cr)) {
            v.ax_caret = cr;
            v.ax_caret_sent = true;
            host.post(cr);
        }
    }
}

/// Two caret frames describing the same state. Coalescing matters:
/// Chromium repeats tree_data on every update, so an uncoalesced
/// caret would post a frame per keystroke-sized tree change even when
/// the caret never moved.
fn axCaretEql(a: proto.EvA11yCaret, b: proto.EvA11yCaret) bool {
    return a.anchor_id == b.anchor_id and a.anchor_offset == b.anchor_offset and
        a.focus_id == b.focus_id and a.focus_offset == b.focus_offset;
}

/// Translate one engine node dict into a wire record. Inline text
/// boxes (pure layout fragments of their static-text parent) are
/// skipped: they double the tree for no reader-visible content, and a
/// child id with no node is defined as an absent child.
fn axPutNode(
    w: *proto.A11yNodeWriter,
    nd: *cef.cef_dictionary_value_t,
    alloc: std.mem.Allocator,
) !void {
    const id = dInt(nd, "id") orelse return;

    var role_buf: [64]u8 = undefined;
    var role: []const u8 = "generic";
    if (dStr(alloc, nd, "role")) |r| {
        if (std.mem.eql(u8, r, "inlineTextBox")) return;
        role = axRole(&role_buf, r);
    }

    var spec = proto.A11yNodeSpec{ .id = @bitCast(id), .role = role };

    if (dDict(nd, "state")) |st| {
        defer release(@ptrCast(&st.base));
        spec.state = axStateBits(st);
    }

    if (dDict(nd, "location")) |loc| {
        defer release(@ptrCast(&loc.base));
        spec.x = dInt(loc, "x") orelse 0;
        spec.y = dInt(loc, "y") orelse 0;
        spec.w = dInt(loc, "width") orelse 0;
        spec.h = dInt(loc, "height") orelse 0;
    }
    if (dInt(nd, "offset_container_id")) |oc| spec.offset_container = @bitCast(oc);

    var children: std.ArrayList(u32) = .empty;
    defer children.deinit(alloc);
    if (dList(nd, "child_ids")) |ids| {
        defer release(@ptrCast(&ids.base));
        var i: usize = 0;
        const n = listLen(ids);
        while (i < n) : (i += 1) {
            const gi = ids.get_int orelse break;
            try children.append(alloc, @bitCast(gi(ids, i)));
        }
    }
    spec.children = children.items;

    var attrs: std.ArrayList(proto.A11yAttr) = .empty;
    defer attrs.deinit(alloc);
    if (dDict(nd, "attributes")) |at| {
        defer release(@ptrCast(&at.base));
        if (dStr(alloc, at, "name")) |s| spec.name = s;
        if (dStr(alloc, at, "value")) |s| spec.value = s;
        if (dStr(alloc, at, "description")) |s| spec.description = s;
        for (ax_attr_map) |m| {
            if (axAttrString(alloc, at, m.from)) |val|
                try attrs.append(alloc, .{ .key = m.to, .value = val });
        }
        // checkedState / restriction fold into state bits rather than
        // travelling as attrs (CheckedState: 2 true, 3 mixed;
        // Restriction: 1 readOnly, 2 disabled — verified via the
        // debug dump, and a string-valued serializer is handled too).
        if (dInt(at, "checkedState")) |cs| {
            if (cs == 2) spec.state |= proto.ax_checked;
            if (cs == 3) spec.state |= proto.ax_checked_mixed;
        } else if (dStr(alloc, at, "checkedState")) |cs| {
            if (std.mem.eql(u8, cs, "true")) spec.state |= proto.ax_checked;
            if (std.mem.eql(u8, cs, "mixed")) spec.state |= proto.ax_checked_mixed;
        }
        if (dInt(at, "restriction")) |r| {
            if (r == 1) spec.state |= proto.ax_readonly;
            if (r == 2) spec.state |= proto.ax_disabled;
        } else if (dStr(alloc, at, "restriction")) |r| {
            if (std.mem.eql(u8, r, "readOnly")) spec.state |= proto.ax_readonly;
            if (std.mem.eql(u8, r, "disabled")) spec.state |= proto.ax_disabled;
        }
    }
    spec.attributes = attrs.items;
    try w.put(spec);
}

fn onAxTreeChange(
    _: [*c]cef.cef_accessibility_handler_t,
    value: [*c]cef.cef_value_t,
) callconv(.c) void {
    defer releaseArg(value);
    const host = g_host orelse return;
    const val: *cef.cef_value_t = value orelse return;
    if (axDebug()) axDump("tree", val);
    const gt = val.get_type orelse return;
    if (gt(val) != cef.VTYPE_DICTIONARY) return;
    const gd = val.get_dictionary orelse return;
    const dict: *cef.cef_dictionary_value_t = gd(val) orelse return;
    defer release(@ptrCast(&dict.base));

    var arena_inst = std.heap.ArenaAllocator.init(host.gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const tree_id = dStr(arena, dict, "ax_tree_id") orelse "";
    const v = axResolveView(host, tree_id) orelse return;

    if (dList(dict, "updates")) |updates| {
        defer release(@ptrCast(&updates.base));
        var i: usize = 0;
        const n = listLen(updates);
        while (i < n) : (i += 1) {
            const upd = listDict(updates, i) orelse continue;
            defer release(@ptrCast(&upd.base));
            axEmitUpdate(host, v, upd, arena);
        }
    }

    if (dList(dict, "events")) |events| {
        defer release(@ptrCast(&events.base));
        var i: usize = 0;
        const n = listLen(events);
        while (i < n) : (i += 1) {
            const ev = listDict(events, i) orelse continue;
            defer release(@ptrCast(&ev.base));
            const etype = dStr(arena, ev, "event_type") orelse continue;
            const id: u32 = @bitCast(dInt(ev, "id") orelse 0);
            // Deliberately small vocabulary; everything else is noise
            // to a read-only projection and is dropped.
            const token: []const u8 = if (std.mem.eql(u8, etype, "focus"))
                "focus"
            else if (std.mem.eql(u8, etype, "loadComplete"))
                "load-complete"
            else
                continue;
            host.post(proto.EvA11yEvent{ .view = v.id, .id = id, .event = token });
        }
    }
}

fn onAxLocationChange(
    _: [*c]cef.cef_accessibility_handler_t,
    value: [*c]cef.cef_value_t,
) callconv(.c) void {
    defer releaseArg(value);
    const host = g_host orelse return;
    const val: *cef.cef_value_t = value orelse return;
    if (axDebug()) axDump("loc", val);
    const gt = val.get_type orelse return;
    if (gt(val) != cef.VTYPE_LIST) return;
    const gl = val.get_list orelse return;
    const list: *cef.cef_list_value_t = gl(val) orelse return;
    defer release(@ptrCast(&list.base));

    var arena_inst = std.heap.ArenaAllocator.init(host.gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Group per view lazily: entries in one callback share a tree in
    // practice, so one frame per callback covers the real shape.
    var locs_buf: std.ArrayList(u8) = .empty;
    defer locs_buf.deinit(host.gpa);
    var view: ?*View = null;

    var i: usize = 0;
    const n = listLen(list);
    while (i < n) : (i += 1) {
        const e = listDict(list, i) orelse continue;
        defer release(@ptrCast(&e.base));
        const tree_id = dStr(arena, e, "ax_tree_id") orelse "";
        const v = axResolveView(host, tree_id) orelse continue;
        if (view != null and view.? != v) continue; // one view per frame
        view = v;
        var l = proto.A11yLoc{
            .id = @bitCast(dInt(e, "id") orelse 0),
            .offset_container = 0,
            .x = 0,
            .y = 0,
            .w = 0,
            .h = 0,
        };
        if (dInt(e, "offset_container_id")) |oc| l.offset_container = @bitCast(oc);
        if (dDict(e, "new_location")) |loc| {
            defer release(@ptrCast(&loc.base));
            l.x = dInt(loc, "x") orelse 0;
            l.y = dInt(loc, "y") orelse 0;
            l.w = dInt(loc, "width") orelse 0;
            l.h = dInt(loc, "height") orelse 0;
        }
        proto.putA11yLoc(host.gpa, &locs_buf, l) catch return;
    }
    const v = view orelse return;
    if (locs_buf.items.len == 0) return;
    host.post(proto.EvA11yLoc{ .view = v.id, .locs = .{ .s = locs_buf.items } });
}

fn onFindResult(
    _: [*c]cef.cef_find_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: c_int,
    count: c_int,
    _: [*c]const cef.cef_rect_t,
    active_match_ordinal: c_int,
    final_update: c_int,
) callconv(.c) void {
    defer releaseArg(browser);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    host.post(proto.EvFindResult{
        .view = v.id,
        .count = count,
        .active = active_match_ordinal,
        .final = if (final_update != 0) 1 else 0,
    });
}

/// The context menu is the CLIENT's: report the hit test (position,
/// link, editability) as `ev_context_menu`, cancel the engine's own
/// display outright, and return "handled". The default model must
/// reach here UNCLEARED: an empty model after on_before_context_menu
/// means "show no menu" and Chromium then never calls
/// run_context_menu at all, so ev_context_menu was never sent.
fn onRunContextMenu(
    _: [*c]cef.cef_context_menu_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    params: [*c]cef.cef_context_menu_params_t,
    model: [*c]cef.cef_menu_model_t,
    callback: [*c]cef.cef_run_context_menu_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(params);
    defer releaseArg(model);
    defer releaseArg(callback);
    if (callback) |cb| {
        if (cb.*.cancel) |cancel| cancel(cb);
    }
    const host = g_host orelse return 1;
    const v = viewOf(browser) orelse return 1;
    const p: *cef.cef_context_menu_params_t = params orelse return 1;

    var x: c_int = 0;
    var y: c_int = 0;
    if (p.get_xcoord) |gx| x = gx(p);
    if (p.get_ycoord) |gy| y = gy(p);
    const pt = logicalPoint(v, x, y);

    var flags: u8 = 0;
    var link = Utf8{ .s = std.mem.zeroes(cef.cef_string_utf8_t) };
    defer link.free();
    if (p.get_link_url) |gl| {
        const raw = gl(p);
        if (raw != null) {
            link = Utf8.init(raw);
            cef.cef_string_userfree_utf16_free(raw);
            if (link.slice().len != 0) flags |= proto.ctx_flag_link;
        }
    }
    if (p.is_editable) |ie| {
        if (ie(p) != 0) flags |= proto.ctx_flag_editable;
    }
    var src = Utf8{ .s = std.mem.zeroes(cef.cef_string_utf8_t) };
    defer src.free();
    if (p.has_image_contents) |hi| {
        if (hi(p) != 0) {
            if (p.get_source_url) |gs| {
                const raw = gs(p);
                if (raw != null) {
                    src = Utf8.init(raw);
                    cef.cef_string_userfree_utf16_free(raw);
                    if (src.slice().len != 0) flags |= proto.ctx_flag_image;
                }
            }
        }
    }
    var sel = Utf8{ .s = std.mem.zeroes(cef.cef_string_utf8_t) };
    defer sel.free();
    if (p.get_selection_text) |gt| {
        const raw = gt(p);
        if (raw != null) {
            sel = Utf8.init(raw);
            cef.cef_string_userfree_utf16_free(raw);
            if (sel.slice().len != 0) flags |= proto.ctx_flag_selection;
        }
    }
    // A selection is a menu-row payload, not a document transfer: cap
    // it (on a UTF-8 boundary) so a select-all on a huge page cannot
    // bloat the event frame.
    var sel_text = sel.slice();
    if (sel_text.len > 256) {
        var end: usize = 256;
        while (end > 0 and (sel_text[end] & 0xC0) == 0x80) end -= 1;
        sel_text = sel_text[0..end];
    }
    host.post(proto.EvContextMenu{
        .view = v.id,
        .x = pt.x,
        .y = pt.y,
        .flags = flags,
        .link_url = link.slice(),
        .src_url = src.slice(),
        .selection_text = sel_text,
    });
    return 1;
}

/// Chromium's own scroll offset, forwarded so a session restore can put
/// the page back where it was.
///
/// THROTTLED: this fires per scroll step, which on a smooth wheel is
/// every frame, and a client only ever needs the latest. The value is
/// stashed on the view and posted at most every `SCROLL_POST_MS`; the
/// final resting position is not lost, because a scroll that stops
/// leaves the stashed value differing from the posted one and the next
/// tick sends it.
const SCROLL_POST_MS: i64 = 150;

fn onScrollOffsetChanged(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    x: f64,
    y: f64,
) callconv(.c) void {
    defer releaseArg(browser);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    v.scroll_x = @intFromFloat(@max(-2_000_000.0, @min(2_000_000.0, x)));
    v.scroll_y = @intFromFloat(@max(-2_000_000.0, @min(2_000_000.0, y)));
    const now = nowMs();
    if (now - v.scroll_posted_ms < SCROLL_POST_MS) return;
    v.scroll_posted_ms = now;
    v.scroll_sent_x = v.scroll_x;
    v.scroll_sent_y = v.scroll_y;
    host.post(proto.EvScroll{ .view = v.id, .x = v.scroll_x, .y = v.scroll_y });
}

fn onPaint(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    ptype: cef.cef_paint_element_type_t,
    count: usize,
    rects: [*c]const cef.cef_rect_t,
    buffer: ?*const anyopaque,
    width: c_int,
    height: c_int,
) callconv(.c) void {
    defer releaseArg(browser);
    if (ptype != cef.PET_VIEW) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    if (v.map.len == 0) return;
    // A paint for the pre-resize geometry: the resize triggers its own
    // full repaint, so dropping this one loses nothing. The comparison
    // is against the PHYSICAL size — OnPaint's width/height and its
    // dirty rects are device pixels, i.e. the view rect times the screen
    // info's device_scale_factor. Comparing them with the LOGICAL size
    // is what forced the v1 scale pin (every paint at scale != 1 was
    // dropped and the view stayed black).
    if (width != @as(c_int, v.pw) or height != @as(c_int, v.ph)) return;
    const src: [*]const u8 = @ptrCast(buffer orelse return);
    const stride: usize = v.stride();

    var list: [max_rects]proto.Rect = undefined;
    var n: usize = 0;
    // A buffer nobody has painted into yet is all zeroes: copy the
    // whole frame regardless of what the engine says changed.
    const collapse = v.buf_unpainted or count == 0 or count > max_rects;
    const src_rects = if (rects == null) &[_]cef.cef_rect_t{} else rects[0..count];
    if (collapse) {
        copyRect(v, src, stride, 0, 0, v.pw, v.ph);
        list[0] = .{ .x = 0, .y = 0, .w = v.pw, .h = v.ph };
        n = 1;
    } else {
        for (src_rects) |r| {
            const x: u16 = @intCast(std.math.clamp(r.x, 0, @as(c_int, v.pw)));
            const y: u16 = @intCast(std.math.clamp(r.y, 0, @as(c_int, v.ph)));
            const w: u16 = @intCast(std.math.clamp(r.width, 0, @as(c_int, v.pw) - @as(c_int, x)));
            const h: u16 = @intCast(std.math.clamp(r.height, 0, @as(c_int, v.ph) - @as(c_int, y)));
            if (w == 0 or h == 0) continue;
            copyRect(v, src, stride, x, y, w, h);
            list[n] = .{ .x = x, .y = y, .w = w, .h = h };
            n += 1;
        }
    }
    if (n == 0) return;
    v.buf_unpainted = false;
    latStamp("paint");
    v.gen +%= 1;
    host.presentPaint(v, list[0..n]);
    if (host.viewInline(v)) {
        // Union rather than queue: a slow bridge coalesces bursts into
        // one damage rect instead of growing the outbox without bound.
        for (list[0..n]) |r| unionDirty(v, r);
        host.flushInlineView(v);
        return;
    }
    host.post(proto.FrameDamage{
        .view = v.id,
        .buf_id = v.buf_id,
        .gen = v.gen,
        .rects = list[0..n],
    });
}

/// Grow `v.inline_dirty` to cover `r`.
fn unionDirty(v: *View, r: proto.Rect) void {
    const d = v.inline_dirty orelse {
        v.inline_dirty = r;
        return;
    };
    const x0 = @min(d.x, r.x);
    const y0 = @min(d.y, r.y);
    const x1 = @max(@as(u32, d.x) + d.w, @as(u32, r.x) + r.w);
    const y1 = @max(@as(u32, d.y) + d.h, @as(u32, r.y) + r.h);
    v.inline_dirty = .{
        .x = x0,
        .y = y0,
        .w = @intCast(x1 - x0),
        .h = @intCast(y1 - y0),
    };
}

/// A GPU frame: hand the engine's dma-buf planes straight to the client.
///
/// The descriptors in `info` are valid ONLY inside this call and the
/// buffer goes back to the engine's pool the moment it returns, so every
/// plane is `dup`'d here — a dup keeps the underlying dma-buf object
/// alive while the pool keeps its own reference, which is exactly the
/// sharing dma-bufs exist for. The CONTENTS are not preserved: the pool
/// cycles and the engine renders into this buffer again a few frames
/// later, the same benign tearing the memfd path already documents.
///
/// Nothing is copied and nothing is mapped in this process: the whole
/// point is that the pixels never enter an address space at all.
fn onAcceleratedPaint(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    ptype: cef.cef_paint_element_type_t,
    _: usize,
    _: [*c]const cef.cef_rect_t,
    info: [*c]const cef.cef_accelerated_paint_info_t,
) callconv(.c) void {
    defer releaseArg(browser);
    // macOS hands this callback an IOSurface, not dma-buf planes:
    // `cef_accelerated_paint_info_t` there is
    // {shared_texture_io_surface, format, extra} with no `planes` array
    // and no `plane_count`. There is no wire frame for an IOSurface and
    // no GTK importer for one either (`GdkDmabufTextureBuilder` is
    // Linux-only), so the accelerated path is Linux-only by
    // construction — `setAccelerated` is never given true on macOS, so
    // this callback cannot fire there. The early return keeps the
    // dma-buf field accesses below out of the macOS compile.
    if (builtin.target.os.tag != .linux) return;
    if (ptype != cef.PET_VIEW) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    // A hidden background page is never announced to the client.
    if (v.webext_bg or v.webext_popup) return;
    // `[*c]` field access leaks back into C-pointer land (`&x.*.planes`
    // is a pointer to the whole array), so bind a real Zig pointer once.
    const inf: *const cef.cef_accelerated_paint_info_t = @ptrCast(info orelse return);
    const n = inf.plane_count;
    if (n <= 0 or n > proto.MAX_PLANES) return;

    // A frame for the pre-resize geometry, dropped exactly like its
    // software counterpart: the resize brings its own full repaint.
    const coded = inf.extra.coded_size;
    if (coded.width != @as(c_int, v.pw) or coded.height != @as(c_int, v.ph)) return;

    var fds: [proto.MAX_PLANES]i32 = @splat(-1);
    var planes: [proto.MAX_PLANES]proto.Plane = @splat(.{ .stride = 0, .offset = 0 });
    var got: u8 = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(n))) : (i += 1) {
        const p = inf.planes[i];
        const dup = c.fcntl(p.fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
        if (dup < 0) break;
        fds[got] = dup;
        planes[got] = .{ .stride = p.stride, .offset = @truncate(p.offset) };
        got += 1;
    }
    if (got != @as(u8, @intCast(n))) {
        for (fds[0..got]) |fd| _ = c.close(fd);
        return;
    }

    v.gen +%= 1;
    host.postDmabuf(proto.FrameDmabuf{
        .view = v.id,
        .buf_id = v.poolId(inodeOf(fds[0]), @intCast(v.gen)),
        .gen = v.gen,
        .w = v.pw,
        .h = v.ph,
        .fourcc = fourccOf(inf.format),
        .modifier = inf.modifier,
        .nplanes = got,
        .planes = planes,
    }, fds[0..got]);
}

/// The dma-buf object's inode: its identity across the engine's pool,
/// and the only thing that distinguishes "the buffer from three frames
/// ago, back again" from "a new buffer". 0 when it cannot be read, which
/// simply costs the client a re-import.
fn inodeOf(fd: i32) u64 {
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return 0;
    return @intCast(st.st_ino);
}

/// CEF's colour type as a DRM FourCC — the wire is engine-agnostic, and
/// a FourCC is what every importer on this platform actually wants.
fn fourccOf(format: cef.cef_color_type_t) u32 {
    return switch (format) {
        cef.CEF_COLOR_TYPE_RGBA_8888 => fourcc('A', 'B', '2', '4'), // DRM_FORMAT_ABGR8888
        else => fourcc('A', 'R', '2', '4'), // DRM_FORMAT_ARGB8888 (BGRA bytes)
    };
}

fn fourcc(a: u8, b: u8, c0: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c0) << 16) | (@as(u32, d) << 24);
}

/// Copy one BGRA rect (device pixels) out of CEF's full-view buffer
/// into the memfd; both are pw x ph with the same stride.
fn copyRect(v: *View, src: [*]const u8, stride: usize, x: u16, y: u16, w: u16, h: u16) void {
    var row: usize = y;
    while (row < @as(usize, y) + h) : (row += 1) {
        const off = row * stride + @as(usize, x) * 4;
        const len = @as(usize, w) * 4;
        @memcpy(v.map[off..][0..len], src[off..][0..len]);
    }
}

fn onAddressChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    url: [*c]const cef.cef_string_t,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(frame);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var s = Utf8.init(url);
    defer s.free();
    if (v.webext_bg or v.webext_popup) return;
    host.setUrl(v, s.slice());
    host.postNavState(v);
}

fn onTitleChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    title: [*c]const cef.cef_string_t,
) callconv(.c) void {
    defer releaseArg(browser);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var s = Utf8.init(title);
    defer s.free();
    if (v.webext_bg or v.webext_popup) return;
    host.presentTitle(v, s.slice());
    host.post(proto.EvTitle{ .view = v.id, .title = s.slice() });
}

fn onFaviconChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    icon_urls: cef.cef_string_list_t,
) callconv(.c) void {
    defer releaseArg(browser);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    if (v.webext_bg) return;
    if (cef.cef_string_list_size(icon_urls) == 0) return;
    var first = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&first);
    if (cef.cef_string_list_value(icon_urls, 0, &first) != 1) return;
    var s = Utf8.init(&first);
    defer s.free();
    host.post(proto.EvFavicon{ .view = v.id, .url = s.slice() });
}

fn onConsoleMessage(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    level: cef.cef_log_severity_t,
    message: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
    _: c_int,
) callconv(.c) c_int {
    defer releaseArg(browser);
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    var s = Utf8.init(message);
    defer s.free();
    host.post(proto.EvConsole{
        .view = v.id,
        .level = @intCast(@min(level, 5)),
        .msg = s.slice(),
    });
    return 0;
}

fn onCursorChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: cef.cef_cursor_handle_t,
    ctype: cef.cef_cursor_type_t,
    _: [*c]const cef.cef_cursor_info_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const mapped: proto.Cursor = switch (ctype) {
        cef.CT_HAND => .pointer,
        cef.CT_IBEAM => .text,
        cef.CT_WAIT => .wait,
        cef.CT_CROSS => .crosshair,
        cef.CT_NOTALLOWED => .not_allowed,
        cef.CT_GRAB => .grab,
        cef.CT_GRABBING => .grabbing,
        cef.CT_EASTWESTRESIZE, cef.CT_COLUMNRESIZE => .ew_resize,
        cef.CT_NORTHSOUTHRESIZE, cef.CT_ROWRESIZE => .ns_resize,
        else => .default,
    };
    host.post(proto.EvCursor{ .view = v.id, .cursor = @intFromEnum(mapped) });
    return 0;
}

/// Popups are NEVER opened by the helper: it cancels them and reports
/// the request, leaving the tab/window decision to the client.
fn onBeforePopup(
    _: [*c]cef.cef_life_span_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: c_int,
    target_url: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
    disposition: cef.cef_window_open_disposition_t,
    user_gesture: c_int,
    _: [*c]const cef.cef_popup_features_t,
    _: [*c]cef.cef_window_info_t,
    _: [*c][*c]cef.cef_client_t,
    _: [*c]cef.cef_browser_settings_t,
    _: [*c][*c]cef.cef_dictionary_value_t,
    _: [*c]c_int,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    const host = g_host orelse return 1;
    const v = viewOf(browser) orelse return 1;
    var s = Utf8.init(target_url);
    defer s.free();
    const d: proto.Disposition = switch (disposition) {
        cef.CEF_WOD_NEW_WINDOW => .new_window,
        cef.CEF_WOD_NEW_POPUP, cef.CEF_WOD_NEW_PICTURE_IN_PICTURE => .popup,
        else => .new_tab,
    };
    host.post(proto.EvPopupRequest{
        .view = v.id,
        .url = s.slice(),
        .disposition = @intFromEnum(d),
        // The client's popup policy turns on this: a window.open the
        // page ran on its own is not the same event as one the user
        // asked for by clicking.
        .user_gesture = if (user_gesture != 0) 1 else 0,
    });
    return 1;
}

/// Browsers CEF has created and not yet destroyed, counted by
/// `on_after_created` / `on_before_close`. `cef_shutdown` with a live
/// browser hangs the process, so the post-disconnect drain in
/// `server.zig` pumps until this reaches zero: `close_browser` is
/// asynchronous, and a browser with post-close work queued (a cancelled
/// download's cleanup, an a11y-enabled renderer's teardown IPC) takes
/// longer than any fixed pump count (stage 23 caught it).
var open_browsers: usize = 0;

/// Live-browser count for the shutdown drain.
pub fn openBrowsers() usize {
    return open_browsers;
}

fn onBeforeClose(
    _: [*c]cef.cef_life_span_handler_t,
    browser: [*c]cef.cef_browser_t,
) callconv(.c) void {
    defer releaseArg(browser);
    if (open_browsers > 0) open_browsers -= 1;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    if (v.webext_popup and v.browser != null) host.popupClosedByEngine(v.id);
}

fn onAfterCreated(
    _: [*c]cef.cef_life_span_handler_t,
    browser: [*c]cef.cef_browser_t,
) callconv(.c) void {
    // Adoption keeps the reference this callback received as
    // `v.browser`; every other exit returns it.
    var adopted = false;
    defer if (!adopted) releaseArg(browser);
    open_browsers += 1;
    const host = g_host orelse return;
    const b: *cef.cef_browser_t = browser orelse return;
    if (host.pending) |v| {
        if (v.cef_id == 0) {
            if (b.get_identifier) |gi| {
                v.cef_id = gi(b);
                // Register as EARLY as possible so the first document's
                // own subresources are attributed: this fires inside
                // create_browser_sync, before createViewAt sets cef_id.
                interceptRegister(host.gpa, v.id, v.cef_id);
            }
        }
        return;
    }
    // Nothing is being created synchronously, so this is a browser CEF
    // made on its own schedule: the inspector `devtools_show` asked
    // for. It is the only such browser this helper can produce —
    // popups are cancelled in `on_before_popup`.
    const v = host.adopting orelse return;
    if (v.browser != null) return;
    host.adoptBrowser(v, b);
    adopted = true;
}

fn onPdfPrintFinished(
    _: [*c]cef.cef_pdf_print_callback_t,
    path: [*c]const cef.cef_string_t,
    ok: c_int,
) callconv(.c) void {
    const host = g_host orelse return;
    var s = Utf8.init(path);
    defer s.free();
    host.onPrintDone(s.slice(), ok != 0);
}

fn onLoadingStateChange(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    is_loading: c_int,
    can_back: c_int,
    can_fwd: c_int,
) callconv(.c) void {
    defer releaseArg(browser);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    if (v.webext_bg) return;
    if (v.webext_popup) {
        applyZoom(v);
        return;
    }
    host.post(proto.EvNavState{
        .view = v.id,
        .can_back = if (can_back != 0) 1 else 0,
        .can_fwd = if (can_fwd != 0) 1 else 0,
        .loading = if (is_loading != 0) 1 else 0,
        .url = v.url,
    });
    // This fires AFTER every load-end/error. A semantic side still in
    // "navigating" here saw a main-frame load-start with no matching
    // end, and would refuse every action while the client's view list
    // says loading:false (seen on a router's post-login page). The
    // browser's word wins: re-arm now.
    if (is_loading == 0 and v.sem_nav.stuckLoading()) host.semRearm(v);
}

fn onLoadStart(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: cef.cef_transition_type_t,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(frame);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    const main = isMainFrame(frame);
    // A hidden background page never faces the client: no zoom, no load
    // events. Its scripts arrive at load end (or, on the origin path,
    // from the document itself). Its Ports still die with its document,
    // exactly as a page's do below.
    if (v.webext_bg or v.webext_popup) {
        if (main) host.portsAbandonView(v.id);
        return;
    }
    const f = frame orelse return;
    // A SUBFRAME reaches this hook too, and only for the extension
    // injection: `all_frames` content scripts belong in it. Everything
    // else below is per-DOCUMENT and stays main-frame-only.
    host.injectMatchingExtensions(v, f, .document_start);
    if (!main) return;
    if (!v.sem_nav.takeExpectedLoadStart()) {
        host.semanticNavigationStarted(v);
    }
    // Chromium's zoom is per origin and resets across a navigation; in
    // accelerated mode the zoom IS the device scale factor, so a page
    // that lost it would render at logical resolution.
    applyZoom(v);
    // Cosmetic hiding, userstyles and userscripts go in per document,
    // as early as this path can put them (see `injectUserContent`).
    host.injectUserContent(v, f);
    host.post(proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.started),
        .url = v.url,
    });
}

fn onLoadEnd(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: c_int,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(frame);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    if (v.webext_bg) {
        if (!isMainFrame(frame)) return;
        // The background page's document is up. On the origin path the
        // engine already loaded its scripts and `injectBackground` is a
        // no-op; on the fallback path it evaluates them here.
        if (host.webext.findByBgView(v.id)) |e| host.injectBackground(v, e);
        return;
    }
    const f = frame orelse return;
    const main = isMainFrame(frame);
    // document_end / document_idle content scripts run now (the
    // document is parsed; document_start ones went in at load start).
    // Subframes get this too, gated on `all_frames`.
    host.injectMatchingExtensions(v, f, .document_end);
    host.injectMatchingExtensions(v, f, .document_idle);
    if (!main) return;
    if (v.webext_popup) return;
    host.post(proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.finished),
        .url = v.url,
    });
    // The semantic content script is already in: it goes in at context
    // creation, before any page script, so by load end it is only
    // re-armed.
    host.semRearm(v);
}

fn onLoadError(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    code: cef.cef_errorcode_t,
    text: [*c]const cef.cef_string_t,
    failed_url: [*c]const cef.cef_string_t,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(frame);
    if (!isMainFrame(frame)) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var url = Utf8.init(failed_url);
    defer url.free();
    var msg = Utf8.init(text);
    defer msg.free();
    if (v.webext_bg or v.webext_popup) {
        // A background page faces no client, so its load failures used
        // to go nowhere at all — and "the extension is enabled but does
        // nothing" is exactly the silent failure this whole area is
        // full of. Surfaced as a console frame, which the client logs.
        if (v.webext_popup) {
            host.post(proto.EvWebextPopup{
                .owner_view = v.popup_owner,
                .popup_view = v.id,
                .state = proto.webext_popup_error,
                .detail = msg.slice(),
            });
            host.removePopupView(v);
            return;
        }
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "[webext] background load failed ({d}) {s}: {s}", .{
            @as(i32, @intCast(code)), url.slice(), msg.slice(),
        }) catch return;
        host.post(proto.EvConsole{ .view = v.id, .level = 3, .msg = line });
        return;
    }
    // Chromium reports the document displaced by a redirect or a
    // second navigation as ERR_ABORTED. A newer load is still active;
    // rearming here would send current-generation requests into a
    // context that has not finished loading yet.
    if (code == cef.ERR_ABORTED) {
        if (v.sem_nav.takeStopRequest()) {
            host.semanticStopped(v);
        }
        return;
    }
    host.post(proto.EvLoadError{
        .view = v.id,
        .code = @intCast(code),
        .url = url.slice(),
        .msg = msg.slice(),
    });
    host.post(proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.failed),
        .url = url.slice(),
    });
    // Failed navigations still replace the main-frame context (often
    // with Chromium's error document). Reissue/fail pending semantic
    // work now rather than leaving it queued until its deadline.
    host.semRearm(v);
}

fn onRenderProcessTerminated(
    _: [*c]cef.cef_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: cef.cef_termination_status_t,
    _: c_int,
    _: [*c]const cef.cef_string_t,
) callconv(.c) void {
    defer releaseArg(browser);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    while (v.pending.items.len > 0) {
        const p = v.pending.orderedRemove(0);
        host.failPending(v, p, "semantic request canceled because the renderer crashed");
    }
    // The renderer's DOM and V8 element ids are gone. Keep the stable-id
    // counters monotonic so a reader id can never alias a post-crash id.
    v.sem.invalidateDocument();
    v.sem_nav.rearmed();
    v.sem_observing = false;
    v.sem_context_doc = 0;
    host.post(proto.EvCrashed{ .view = v.id });
}

// ---------------------------------------------------------------------
// TLS interstitials and permission prompts
// ---------------------------------------------------------------------

/// Answer a held certificate error and drop the reference. Idempotent:
/// a view with nothing held is left alone, so teardown may always call
/// it.
fn resolveCert(v: *View, proceed: bool) void {
    const cb = v.cert_cb orelse return;
    v.cert_cb = null;
    if (proceed) {
        if (cb.cont) |f| f(cb);
    } else {
        if (cb.cancel) |f| f(cb);
    }
    release(&cb.base);
}

/// Answer a held permission request and clear its slot. Idempotent for
/// the same reason as `resolveCert`; the two callback flavours differ
/// only here.
fn resolvePerm(p: *PendingPerm, allow: bool) void {
    if (!p.busy()) return;
    // TAKE the slot before continuing. `Continue()` can dismiss the
    // prompt REENTRANTLY — measured on macOS (the first platform where
    // the engine consults this handler at all): CEF 151 runs
    // `on_dismiss_permission_prompt` INSIDE the cont call, and a
    // dismiss that still finds this slot busy releases the callback,
    // after which the release below was a use-after-free (SIGSEGV at a
    // wild address, helper gone). With the slot already cleared the
    // reentrant dismiss finds nothing and this function owns the one
    // release.
    const prompt_cb = p.prompt_cb;
    const media_cb = p.media_cb;
    const media_bits = p.media_bits;
    p.* = .{};
    if (prompt_cb) |cb| {
        if (cb.cont) |f| f(cb, if (allow)
            cef.CEF_PERMISSION_RESULT_ACCEPT
        else
            cef.CEF_PERMISSION_RESULT_DENY);
        release(&cb.base);
    }
    if (media_cb) |cb| {
        // A media callback grants BITS, not a boolean: handing back the
        // ones asked for is an allow, handing back none is a deny.
        if (cb.cont) |f| f(cb, if (allow) media_bits else 0);
        release(&cb.base);
    }
}

/// Free slot for a new prompt on this view, or null when the view is
/// already holding as many as it may.
fn permSlot(v: *View) ?*PendingPerm {
    for (&v.perms) |*p| {
        if (!p.busy()) return p;
    }
    return null;
}

var next_media_id: u64 = 0;

/// The engine refused a certificate. The request is HELD and the client
/// decides; returning 0 instead would fail the load with the generic
/// error an interstitial exists to replace.
fn onCertificateError(
    _: [*c]cef.cef_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    cert_error: cef.cef_errorcode_t,
    request_url: [*c]const cef.cef_string_t,
    ssl_info: [*c]cef.cef_sslinfo_t,
    callback: [*c]cef.cef_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(ssl_info);
    // A held interstitial keeps the callback's reference; `cert_cb`'s
    // answer path releases it.
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const cb: *cef.cef_callback_t = callback orelse return 0;
    // One interstitial per view: a second error cannot be shown and
    // must not be silently held, so it takes default handling (fail).
    if (v.cert_cb != null) return 0;

    var url = Utf8.init(request_url);
    defer url.free();

    var subject: [256]u8 = undefined;
    var issuer: [256]u8 = undefined;
    var fingerprint: [64]u8 = undefined;
    const cert = certDetails(ssl_info, &subject, &issuer, &fingerprint);

    v.cert_cb = cb;
    kept = true;
    host.post(proto.EvCertError{
        .view = v.id,
        .code = @intCast(cert_error),
        .url = url.slice(),
        .host = hostOfUrl(url.slice()),
        .msg = certErrorName(cert_error),
        .subject = cert.subject,
        .issuer = cert.issuer,
        .fingerprint = cert.fingerprint,
    });
    return 1;
}

const CertDetails = struct {
    subject: []const u8 = "",
    issuer: []const u8 = "",
    fingerprint: []const u8 = "",
};

/// Pull the display name of the subject and issuer plus the SHA-256 of
/// the DER out of an ssl_info, into caller-owned buffers. Every step is
/// optional: an engine that hands us no certificate still produces an
/// interstitial, just a less specific one.
fn certDetails(
    ssl_info: [*c]cef.cef_sslinfo_t,
    subject_buf: []u8,
    issuer_buf: []u8,
    fp_buf: *[64]u8,
) CertDetails {
    var out: CertDetails = .{};
    const info: *cef.cef_sslinfo_t = ssl_info orelse return out;
    const get_cert = info.get_x509_certificate orelse return out;
    const cert: *cef.cef_x509_certificate_t = get_cert(info) orelse return out;
    defer release(&cert.base);

    if (cert.get_subject) |gs| {
        const p: ?*cef.cef_x509_cert_principal_t = gs(cert);
        if (p) |principal| {
            defer release(&principal.base);
            out.subject = principalName(principal, subject_buf);
        }
    }
    if (cert.get_issuer) |gi| {
        const p: ?*cef.cef_x509_cert_principal_t = gi(cert);
        if (p) |principal| {
            defer release(&principal.base);
            out.issuer = principalName(principal, issuer_buf);
        }
    }
    if (cert.get_derencoded) |gd| {
        const b: ?*cef.cef_binary_value_t = gd(cert);
        if (b) |bin| {
            defer release(&bin.base);
            var der: [8192]u8 = undefined;
            const size = if (bin.get_size) |gsz| gsz(bin) else 0;
            const want = @min(size, der.len);
            const got = if (bin.get_data) |gdta| gdta(bin, &der, want, 0) else 0;
            if (got != 0 and got == size) {
                var digest: [32]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(der[0..got], &digest, .{});
                out.fingerprint = std.fmt.bufPrint(fp_buf, "{x}", .{&digest}) catch "";
            }
        }
    }
    return out;
}

fn principalName(p: *cef.cef_x509_cert_principal_t, buf: []u8) []const u8 {
    const gn = p.get_display_name orelse return "";
    const raw = gn(p);
    if (raw == null) return "";
    defer cef.cef_string_userfree_utf16_free(raw);
    var s = Utf8.init(raw);
    defer s.free();
    const src = s.slice();
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return buf[0..n];
}

/// Host component of `url`, for an interstitial that must name what the
/// user thought they were visiting. Not a parser: everything between
/// "//" and the next "/", minus any userinfo and port.
fn hostOfUrl(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "//") orelse return url;
    var rest = url[scheme_end + 2 ..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        // An IPv6 literal keeps its colons; a port never follows "]".
        if (std.mem.indexOfScalar(u8, rest, ']') == null) rest = rest[0..colon];
    }
    return rest;
}

/// Symbolic name for the certificate errors an interstitial can show.
/// Anything else keeps its number, which the client prints anyway.
fn certErrorName(code: cef.cef_errorcode_t) []const u8 {
    return switch (code) {
        cef.ERR_CERT_COMMON_NAME_INVALID => "CERT_COMMON_NAME_INVALID",
        cef.ERR_CERT_DATE_INVALID => "CERT_DATE_INVALID",
        cef.ERR_CERT_AUTHORITY_INVALID => "CERT_AUTHORITY_INVALID",
        cef.ERR_CERT_CONTAINS_ERRORS => "CERT_CONTAINS_ERRORS",
        cef.ERR_CERT_NO_REVOCATION_MECHANISM => "CERT_NO_REVOCATION_MECHANISM",
        cef.ERR_CERT_UNABLE_TO_CHECK_REVOCATION => "CERT_UNABLE_TO_CHECK_REVOCATION",
        cef.ERR_CERT_REVOKED => "CERT_REVOKED",
        cef.ERR_CERT_INVALID => "CERT_INVALID",
        cef.ERR_CERT_WEAK_SIGNATURE_ALGORITHM => "CERT_WEAK_SIGNATURE_ALGORITHM",
        cef.ERR_CERT_NON_UNIQUE_NAME => "CERT_NON_UNIQUE_NAME",
        cef.ERR_CERT_WEAK_KEY => "CERT_WEAK_KEY",
        cef.ERR_CERT_NAME_CONSTRAINT_VIOLATION => "CERT_NAME_CONSTRAINT_VIOLATION",
        cef.ERR_CERT_VALIDITY_TOO_LONG => "CERT_VALIDITY_TOO_LONG",
        cef.ERR_CERTIFICATE_TRANSPARENCY_REQUIRED => "CERTIFICATE_TRANSPARENCY_REQUIRED",
        else => "CERT_ERROR",
    };
}

/// Engine permission bits -> the wire's own bits. Anything unmapped
/// becomes `perm_other`, which the client still names and prompts for
/// rather than dropping.
fn permTypes(bits: u32) u32 {
    var out: u32 = 0;
    var rest = bits;
    const table = [_]struct { cef_bit: u32, wire: u32 }{
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_GEOLOCATION, .wire = proto.perm_geolocation },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_NOTIFICATIONS, .wire = proto.perm_notifications },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_CAMERA_STREAM, .wire = proto.perm_camera },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM, .wire = proto.perm_camera },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_MIC_STREAM, .wire = proto.perm_microphone },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_MIDI_SYSEX, .wire = proto.perm_midi },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_CLIPBOARD, .wire = proto.perm_clipboard },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_POINTER_LOCK, .wire = proto.perm_pointer_lock },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_IDLE_DETECTION, .wire = proto.perm_idle_detection },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_STORAGE_ACCESS, .wire = proto.perm_storage_access },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS, .wire = proto.perm_storage_access },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT, .wire = proto.perm_window_management },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER, .wire = proto.perm_protected_media },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_LOCAL_FONTS, .wire = proto.perm_local_fonts },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS, .wire = proto.perm_file_system },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS, .wire = proto.perm_downloads },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_SENSORS, .wire = proto.perm_sensors },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_VR_SESSION, .wire = proto.perm_vr },
        .{ .cef_bit = cef.CEF_PERMISSION_TYPE_AR_SESSION, .wire = proto.perm_vr },
    };
    for (table) |e| {
        if (rest & e.cef_bit != 0) {
            out |= e.wire;
            rest &= ~e.cef_bit;
        }
    }
    if (rest != 0) out |= proto.perm_other;
    return out;
}

fn onShowPermissionPrompt(
    _: [*c]cef.cef_permission_handler_t,
    browser: [*c]cef.cef_browser_t,
    prompt_id: u64,
    requesting_origin: [*c]const cef.cef_string_t,
    requested_permissions: u32,
    callback: [*c]cef.cef_permission_prompt_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const cb: *cef.cef_permission_prompt_callback_t = callback orelse return 0;
    const slot = permSlot(v) orelse return 0;
    // A helper-minted media id could otherwise collide with an engine
    // one; the engine's own ids never carry the top bit.
    if (prompt_id & media_id_bit != 0) return 0;

    var origin = Utf8.init(requesting_origin);
    defer origin.free();
    slot.* = .{ .id = prompt_id, .prompt_cb = cb };
    kept = true;
    host.post(proto.EvPermission{
        .view = v.id,
        .prompt = prompt_id,
        .origin = origin.slice(),
        .types = permTypes(requested_permissions),
    });
    return 1;
}

/// Camera/microphone come through their OWN callback with no prompt id,
/// so one is minted here (see `PendingPerm`).
fn onRequestMediaAccess(
    _: [*c]cef.cef_permission_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    requesting_origin: [*c]const cef.cef_string_t,
    requested_permissions: u32,
    callback: [*c]cef.cef_media_access_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const cb: *cef.cef_media_access_callback_t = callback orelse return 0;
    const slot = permSlot(v) orelse return 0;

    var types: u32 = 0;
    if (requested_permissions & (cef.CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE |
        cef.CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE) != 0) types |= proto.perm_microphone;
    if (requested_permissions & (cef.CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE |
        cef.CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE) != 0) types |= proto.perm_camera;
    if (types == 0) types = proto.perm_other;

    next_media_id +%= 1;
    const id = media_id_bit | next_media_id;
    var origin = Utf8.init(requesting_origin);
    defer origin.free();
    slot.* = .{ .id = id, .media_cb = cb, .media_bits = requested_permissions };
    kept = true;
    host.post(proto.EvPermission{
        .view = v.id,
        .prompt = id,
        .origin = origin.slice(),
        .types = types,
    });
    return 1;
}

/// The engine gave up on a prompt we were holding (navigation, browser
/// closing, or our own Continue). The slot is dropped WITHOUT calling
/// back: the callback is spent, and a late `permission_decision` for
/// this id then finds nothing, which is exactly how it must behave.
fn onDismissPermissionPrompt(
    _: [*c]cef.cef_permission_handler_t,
    browser: [*c]cef.cef_browser_t,
    prompt_id: u64,
    _: cef.cef_permission_request_result_t,
) callconv(.c) void {
    defer releaseArg(browser);
    const v = viewOf(browser) orelse return;
    for (&v.perms) |*p| {
        if (p.busy() and p.id == prompt_id) {
            if (p.prompt_cb) |cb| release(&cb.base);
            p.* = .{};
            return;
        }
    }
}

// ---------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------

/// Every download may proceed as far as the TARGET decision — which is
/// then held for the client (`on_before_download`). Returning 0 here
/// would cancel silently, and the policy question belongs to the GUI.
fn onCanDownload(
    _: [*c]cef.cef_download_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
) callconv(.c) c_int {
    releaseArg(browser);
    return 1;
}

/// The engine's download entry for `id`, minted on first sight — the
/// engine reports progress BEFORE `on_before_download`, so either
/// callback can be the first to see an id.
fn dlSlot(host: *Host, view: u32, id: u32) ?*Host.Dl {
    if (host.findDl(view, id)) |d| return d;
    host.downloads.append(host.gpa, .{ .id = id, .view = view }) catch return null;
    return &host.downloads.items[host.downloads.items.len - 1];
}

fn onBeforeDownload(
    _: [*c]cef.cef_download_handler_t,
    browser: [*c]cef.cef_browser_t,
    download_item: [*c]cef.cef_download_item_t,
    suggested_name: [*c]const cef.cef_string_t,
    callback: [*c]cef.cef_before_download_callback_t,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(download_item);
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    const item: *cef.cef_download_item_t = download_item orelse return 0;
    const cb: *cef.cef_before_download_callback_t = callback orelse return 0;
    const id: u32 = if (item.get_id) |gid| gid(item) else return 0;
    const d = dlSlot(host, v.id, id) orelse return 0;
    if (d.cancel_requested or d.terminal()) return 0;

    if (item.get_total_bytes) |gt| {
        const t = gt(item);
        if (t > 0) d.total = @intCast(t);
    }
    d.before_cb = cb;
    kept = true;
    d.offered = true;

    var name = Utf8.init(suggested_name);
    defer name.free();
    var url_buf: [2048]u8 = undefined;
    const url = if (item.get_url) |gu| userfreeInto(gu(item), &url_buf) else "";
    var mime_buf: [256]u8 = undefined;
    const mime = if (item.get_mime_type) |gm| userfreeInto(gm(item), &mime_buf) else "";
    host.post(proto.EvDownloadOffer{
        .view = v.id,
        .id = id,
        .total = d.total,
        .url = url,
        .name = name.slice(),
        .mime = mime,
    });
    return 1;
}

/// Progress, coalesced: the counters land in the entry and the flush in
/// the poll loop posts at most one frame per iteration. The latest
/// cancel handle is kept (releasing the previous one), which is what a
/// `download_cancel` or a dying view aborts through.
fn onDownloadUpdated(
    _: [*c]cef.cef_download_handler_t,
    browser: [*c]cef.cef_browser_t,
    download_item: [*c]cef.cef_download_item_t,
    callback: [*c]cef.cef_download_item_callback_t,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(download_item);
    // The entry keeps the callback's reference as its cancel handle;
    // every other exit returns it.
    var kept = false;
    defer if (!kept) releaseArg(callback);
    const host = g_host orelse return;
    const item: *cef.cef_download_item_t = download_item orelse return;
    const id: u32 = if (item.get_id) |gid| gid(item) else return;
    // By id first: the engine's id is process-unique, and a browser
    // mid-close can stop resolving to its view while its download's
    // entry (keyed under the real view) lives on.
    var found: ?*Host.Dl = null;
    for (host.downloads.items) |*e| {
        if (e.id == id) found = e;
    }
    const view_id: u32 = if (viewOf(browser)) |v| v.id else 0;
    const cb_arg: ?*cef.cef_download_item_callback_t = callback;
    const d = (found orelse dlSlot(host, view_id, id)) orelse return;

    if (item.get_received_bytes) |gr| {
        const r = gr(item);
        if (r >= 0) d.received = @intCast(r);
    }
    if (item.get_total_bytes) |gt| {
        const t = gt(item);
        if (t > 0) d.total = @intCast(t);
    }
    if (item.is_complete) |f| {
        if (f(item) != 0) d.done = true;
    }
    const canceled = if (item.is_canceled) |f| f(item) != 0 else false;
    const interrupted = if (item.is_interrupted) |f| f(item) != 0 else false;
    if ((canceled or interrupted) and !d.done) d.failed = true;
    d.dirty = true;

    // One held cancel handle at a time; a terminal download needs none.
    if (d.item_cb) |old| {
        d.item_cb = null;
        release(&old.base);
    }
    if (cb_arg) |cb| {
        if (d.terminal()) {
            // Spent: the deferred release returns it.
        } else if (d.cancel_requested) {
            if (cb.cancel) |f| f(cb);
        } else {
            d.item_cb = cb;
            kept = true;
        }
    }
}

fn isMainFrame(frame: [*c]cef.cef_frame_t) bool {
    if (frame == null) return false;
    const f = frame.*.is_main orelse return false;
    return f(frame) != 0;
}

// ---------------------------------------------------------------------
// Render process: the semantic content script and its transport
// ---------------------------------------------------------------------
//
// Everything below runs in a DIFFERENT PROCESS from the Host above —
// CEF re-executes this same binary as its renderer, and
// `cef_execute_process` never returns there. The two halves share only
// the JSON strings that cross as process messages.

fn getRenderProcessHandler(_: [*c]cef.cef_app_t) callconv(.c) [*c]cef.cef_render_process_handler_t {
    return &rp_handler;
}

/// Register the transport as a V8 extension and read the secrets the
/// browser process appended to this renderer's command line.
///
/// A V8 extension is CEF's documented way to publish a NATIVE function
/// to every frame, and it is the only route left: extension code must
/// not touch `window` in any way (not even `typeof` — the DOM global
/// does not exist yet and the renderer dies silently), so the extension
/// declares a plain global and `onContextCreated` takes it away again
/// before the page can see it. Without the secrets nothing is injected
/// at all: an unauthenticated semantic layer is worse than none.
fn onWebKitInitialized(_: [*c]cef.cef_render_process_handler_t) callconv(.c) void {
    var ext_name = std.mem.zeroes(cef.cef_string_t);
    setStr("v8/sketerm-semantic", &ext_name);
    defer cef.cef_string_utf16_clear(&ext_name);
    var ext_code = std.mem.zeroes(cef.cef_string_t);
    setStr(sem_bridge_js, &ext_code);
    defer cef.cef_string_utf16_clear(&ext_code);
    _ = cef.cef_register_extension(&ext_name, &ext_code, &v8_handler);

    const cl: *cef.cef_command_line_t = cef.cef_command_line_get_global() orelse return;
    defer release(&cl.base);
    const gv = cl.get_switch_value orelse return;
    var name = std.mem.zeroes(cef.cef_string_t);
    setStr(sem_switch, &name);
    defer cef.cef_string_utf16_clear(&name);
    const raw = gv(cl, &name);
    if (raw == null) return;
    defer cef.cef_string_userfree_utf16_free(raw);
    var val = Utf8.init(raw);
    defer val.free();
    const s = val.slice();
    if (s.len != sem_secret.nonce.len + 1 + sem_secret.slot.len) return;
    if (s[sem_secret.nonce.len] != ':') return;
    @memcpy(&sem_secret.nonce, s[0..sem_secret.nonce.len]);
    @memcpy(&sem_secret.slot, s[sem_secret.nonce.len + 1 ..]);
    sem_secret.ok = true;
}

/// Inject the content script into a fresh main-frame V8 context.
///
/// This runs BEFORE any page script of the document, which is the whole
/// security argument: the script captures the transport (the extension
/// global `__sketermSemPost`) and unpublishes it while the page still
/// has no code running, so page script never gets to call it, wrap it,
/// or see the reply channel at all. Injecting at `on_load_end` instead
/// — as the first revision did — loses that race by construction: the
/// probe page reported `typeof __sketermSemPost === "function"` and no
/// injected script at parse time.
///
/// The call is baked into the evaluated SOURCE rather than made through
/// `execute_function`, because calling a V8 function from this callback
/// kills the renderer SILENTLY (black view, `ev_crashed`, nothing in
/// cef.log) — verified with a function body as small as `return 1`.
/// Two more routes die the same way and must not come back:
///   - `set_value_bykey` on the context global, the "obvious" injection;
///   - extension code touching `window` in any way, even `typeof`.
/// `cef_v8_context_t::eval` is the one thing that works here.
fn onContextCreated(
    _: [*c]cef.cef_render_process_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    context: [*c]cef.cef_v8_context_t,
) callconv(.c) void {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(context);
    const ctx: *cef.cef_v8_context_t = context orelse return;
    if (!sem_secret.ok) {
        // Without the secrets there is no authenticated channel, so the
        // transport is taken away and nothing is injected.
        evalJs(ctx, disarm_js);
        return;
    }
    // SUBFRAMES ARE INJECTED TOO, since 'all_frames' content scripts
    // must run in them and a content script needs the bridge to reach
    // `browser.*`. The old invariant — "commands only ever go to the
    // main frame, so an injected subframe could only post unsolicited
    // walks of ITS document into the shadow tree" — is preserved on the
    // OTHER side instead: `onProcessMessage` accepts only `ext-*` ops
    // from a subframe and drops every semantic one, so a subframe still
    // cannot put anything into the view's shadow tree.
    //
    // The cost is real and deliberate: every iframe of every page now
    // parses the bridge, where before it evaluated only `disarm_js`.
    // That is what a browser with extensions does, and the alternative
    // (a second, smaller subframe script) is a copy that would have to
    // stay in sync with this one.
    evalJs(ctx, injectSource() orelse return);
}

/// The content script wrapped into its own call, built once per render
/// process because the secrets only arrive at `on_web_kit_initialized`.
fn injectSource() ?[]const u8 {
    const State = struct {
        var buf: [semantic_js.len + 128]u8 = undefined;
        var built: []const u8 = &.{};
    };
    if (State.built.len != 0) return State.built;
    State.built = std.fmt.bufPrint(
        &State.buf,
        "({s})(\"{s}\",\"{s}\",__sketermSemPost);",
        .{ semantic_js, &sem_secret.nonce, &sem_secret.slot },
    ) catch return null;
    return State.built;
}

/// Evaluate a script in an already-created V8 context.
fn evalJs(ctx: *cef.cef_v8_context_t, source: []const u8) void {
    const ev = ctx.eval orelse return;
    var code = std.mem.zeroes(cef.cef_string_t);
    setStr(source, &code);
    defer cef.cef_string_utf16_clear(&code);
    var url = std.mem.zeroes(cef.cef_string_t);
    setStr("sketerm://semantic.js", &url);
    defer cef.cef_string_utf16_clear(&url);
    var retval: [*c]cef.cef_v8_value_t = null;
    var exc: [*c]cef.cef_v8_exception_t = null;
    _ = ev(ctx, &code, &url, 0, &retval, &exc);
    if (retval) |r| release(&r.*.base);
    if (exc) |e| release(&e.*.base);
}

/// Run a script in a frame's main world.
fn runJs(frame: *cef.cef_frame_t, code: []const u8) void {
    const exec = frame.execute_java_script orelse return;
    var js = std.mem.zeroes(cef.cef_string_t);
    setStr(code, &js);
    defer cef.cef_string_utf16_clear(&js);
    var url = std.mem.zeroes(cef.cef_string_t);
    setStr("sketerm://semantic.js", &url);
    defer cef.cef_string_utf16_clear(&url);
    exec(frame, &js, &url, 0);
}

/// The script's `post(nonce + json)`: forward the string to the browser
/// process untouched.
fn onSemPost(
    _: [*c]cef.cef_v8_handler_t,
    _: [*c]const cef.cef_string_t,
    object: [*c]cef.cef_v8_value_t,
    argc: usize,
    argv: [*c]const [*c]cef.cef_v8_value_t,
    _: [*c][*c]cef.cef_v8_value_t,
    _: [*c]cef.cef_string_t,
) callconv(.c) c_int {
    defer releaseArg(object);
    // Every element of `arguments` is wrapped with its own reference
    // (refptr_vec_diff_byref_const); only the array itself is freed by
    // the caller.
    defer if (argv != null) {
        var i: usize = 0;
        while (i < argc) : (i += 1) releaseArg(argv[i]);
    };
    if (argc < 1 or argv == null) return 0;
    const arg: *cef.cef_v8_value_t = argv[0] orelse return 0;
    const gs = arg.get_string_value orelse return 0;
    const raw = gs(arg);
    if (raw == null) return 0;
    defer cef.cef_string_userfree_utf16_free(raw);

    const ctx: *cef.cef_v8_context_t = cef.cef_v8_context_get_current_context() orelse return 0;
    defer release(&ctx.base);
    const gf = ctx.get_frame orelse return 0;
    const frame: *cef.cef_frame_t = gf(ctx) orelse return 0;
    defer release(&frame.base);

    var name = std.mem.zeroes(cef.cef_string_t);
    setStr(sem_msg, &name);
    defer cef.cef_string_utf16_clear(&name);
    const msg: *cef.cef_process_message_t = cef.cef_process_message_create(&name) orelse return 0;
    var sent = false;
    defer if (!sent) release(&msg.base);
    const gal = msg.get_argument_list orelse return 0;
    const args: *cef.cef_list_value_t = gal(msg) orelse return 0;
    defer release(&args.base);
    if (args.set_size) |ss| _ = ss(args, 1);
    if (args.set_string) |ss| _ = ss(args, 0, raw);
    const send = frame.send_process_message orelse return 0;
    send(frame, cef.PID_BROWSER, msg);
    sent = true;
    return 1;
}

// ---------------------------------------------------------------------
// Process bootstrap (the only CEF entry points main.zig needs)
// ---------------------------------------------------------------------

/// The macOS subprocess helper's executable, derived from OUR own
/// location so a bundle stays relocatable (no build-time absolute
/// path). Returns null when there is no helper beside us, which is the
/// honest answer for an unbundled dev binary — CEF then fails loudly
/// rather than us inventing a path that does not exist.
///
///   <app>.app/Contents/MacOS/sketerm-webengine          <- us
///   <app>.app/Contents/Frameworks/
///       sketerm-webengine Helper.app/Contents/MacOS/
///           sketerm-webengine Helper                     <- returned
fn macHelperPath(buf: *[4096:0]u8) ?[:0]const u8 {
    var exe_buf: [4096:0]u8 = undefined;
    const exe = platform.exePathZ(&exe_buf) orelse return null;
    const macos_dir = std.fs.path.dirname(exe) orelse return null;
    const contents = std.fs.path.dirname(macos_dir) orelse return null;
    const name = "sketerm-webengine Helper";
    const p = std.fmt.bufPrintZ(
        buf,
        "{s}/Frameworks/{s}.app/Contents/MacOS/{s}",
        .{ contents, name, name },
    ) catch return null;
    if (c.access(p.ptr, c.X_OK) != 0) return null;
    return p;
}

/// Configure the libcef API version. MUST be the first libcef call of
/// any process — without it `cef_execute_process` spins forever.
pub fn apiHash() bool {
    return cef.cef_api_hash(cef.CEF_API_VERSION_LAST, 0) != null;
}

/// CEF subprocess passthrough: returns the exit code for a helper
/// process, or null in the browser process.
pub fn executeProcess(argc: c_int, argv: [*c][*c]u8) ?u8 {
    bp_handler = std.mem.zeroes(cef.cef_browser_process_handler_t);
    bp_handler.base = staticBase(cef.cef_browser_process_handler_t);
    bp_handler.on_schedule_message_pump_work = onScheduleMessagePumpWork;
    bp_handler.on_before_child_process_launch = onBeforeChildProcessLaunch;
    v8_handler = std.mem.zeroes(cef.cef_v8_handler_t);
    v8_handler.base = staticBase(cef.cef_v8_handler_t);
    v8_handler.execute = onSemPost;
    rp_handler = std.mem.zeroes(cef.cef_render_process_handler_t);
    rp_handler.base = staticBase(cef.cef_render_process_handler_t);
    rp_handler.on_web_kit_initialized = onWebKitInitialized;
    rp_handler.on_context_created = onContextCreated;

    app = std.mem.zeroes(cef.cef_app_t);
    app.base = staticBase(cef.cef_app_t);
    app.get_browser_process_handler = getBrowserProcessHandler;
    // Reached only in CEF's renderer subprocess, which is THIS binary
    // re-executed; the browser process never calls it.
    app.get_render_process_handler = getRenderProcessHandler;
    // EVERY process, and it must agree in every one of them: the
    // renderer decides whether a module import from a chrome-extension
    // page is even allowed, and the network service decides whether the
    // scheme is fetchable at all. Registering it only in the browser
    // process leaves both answering "no" with no diagnostic.
    app.on_register_custom_schemes = onRegisterCustomSchemes;
    const args = cef.cef_main_args_t{ .argc = argc, .argv = argv };
    const code = cef.cef_execute_process(&args, &app, null);
    if (code < 0) return null;
    return @intCast(@as(u32, @bitCast(code)) & 0xff);
}

/// macOS: create the NSApplication CEF's Cocoa message pump needs.
/// Implemented in `mac_app.m`; see that file for why a helper without
/// one initializes fine and then never completes a navigation.
extern fn sketerm_web_init_nsapp() void;
extern fn sketerm_web_pump_runloop() void;

/// Bring CEF up in windowless mode with a private cache directory.
pub fn initialize(argc: c_int, argv: [*c][*c]u8, cache_dir: []const u8, log_file: []const u8) bool {
    // Before ANY CEF call that could touch NSApp: the first
    // `sharedApplication` decides the class of the singleton, and CEF
    // must find ours (it implements CefAppProtocol).
    if (builtin.target.os.tag == .macos) sketerm_web_init_nsapp();
    // Browser process only: `executeProcess` never returns in a child,
    // so a renderer never mints and only ever reads what it was given.
    mintSecret();
    const args = cef.cef_main_args_t{ .argc = argc, .argv = argv };
    var settings = std.mem.zeroes(cef.cef_settings_t);
    settings.size = @sizeOf(cef.cef_settings_t);
    settings.no_sandbox = 1;
    settings.windowless_rendering_enabled = 1;
    // Opaque background: a windowless browser defaults to transparent,
    // and Chromium disables LCD (subpixel) text AA on any surface that
    // MIGHT be transparent. Opaque is also what the face paints (it
    // composites over white).
    settings.background_color = 0xffffffff;
    // WARNING writes nothing when nothing warns, which made the first
    // macOS load stall undiagnosable: the hardcoded value also beats
    // any --log-severity on the command line. SKETERM_WEB_LOG=verbose
    // is the debug tap (pair it with --v=1 in the argv for VLOGs).
    settings.log_severity = blk: {
        const e = c.getenv("SKETERM_WEB_LOG") orelse break :blk cef.LOGSEVERITY_WARNING;
        const v = std.mem.span(e);
        if (std.mem.eql(u8, v, "verbose")) break :blk cef.LOGSEVERITY_VERBOSE;
        if (std.mem.eql(u8, v, "info")) break :blk cef.LOGSEVERITY_INFO;
        break :blk cef.LOGSEVERITY_WARNING;
    };
    setStr(cache_dir, &settings.root_cache_path);
    setStr(log_file, &settings.log_file);
    defer cef.cef_string_utf16_clear(&settings.root_cache_path);
    defer cef.cef_string_utf16_clear(&settings.log_file);

    // macOS launches every child (renderer, GPU, network service) from
    // a SEPARATE helper .app bundle — re-executing the browser
    // executable, which is what Linux does, fails with
    // "GPU process launch failed: error_code=1003" and then a fatal
    // "GPU process isn't usable. Goodbye." A helper needs its own
    // bundle and Info.plist so that, among other things, it takes no
    // dock icon; CEF's README documents the layout and
    // `dist/macos-bundle.sh` builds it.
    var helper_buf: [4096:0]u8 = undefined;
    if (builtin.target.os.tag == .macos) {
        if (macHelperPath(&helper_buf)) |p| setStr(p, &settings.browser_subprocess_path);
    }
    defer if (builtin.target.os.tag == .macos) cef.cef_string_utf16_clear(&settings.browser_subprocess_path);
    if (cef.cef_initialize(&args, &settings, &app, null) != 1) return false;
    // Only valid after initialize, and only in the browser process.
    registerExtSchemeFactory();
    return true;
}

/// One iteration of CEF's message loop. Every handler above runs
/// inside this call, on this thread.
pub fn pump() void {
    pump_delay_ms = -1;
    cef.cef_do_message_loop_work();
}

pub fn shutdown() void {
    cef.cef_shutdown();
}

/// Engine identity for the handshake.
pub fn engineName() []const u8 {
    return "cef";
}

pub fn engineVersion() []const u8 {
    return std.mem.span(@as([*:0]const u8, cef.CEF_VERSION));
}

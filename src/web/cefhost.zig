//! CEF containment: this file and the modules under `cefhost/` are the
//! ONLY code in sketerm-web that sees a CEF type.
//!
//! It owns the browser fleet (one windowless browser per protocol view),
//! turns OnPaint into memfd + `frame_damage`, turns CEF notifications
//! into protocol events, and turns protocol input frames into trusted
//! CEF input. Everything crosses the boundary as `protocol.zig` values,
//! so swapping engines means replacing this file and `cefhost/` and
//! nothing else. Feature sections of `Host` (semantic layer, webext,
//! webRequest, interception, cookies, downloads, prompts, user content,
//! observers, a11y) live in `cefhost/*.zig` as free functions taking
//! `*Host`; `Host` re-exports each under its old name. The table is in
//! src/web/CLAUDE.md ("Where the CEF code lives").
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
const host_obs = @import("cefhost/observe.zig");
const host_us = @import("cefhost/usercontent.zig");
const host_sec = @import("cefhost/security.zig");
const host_dl = @import("cefhost/downloads.zig");
const host_a11y = @import("cefhost/a11y.zig");
const host_icpt = @import("cefhost/intercept.zig");
const host_sem = @import("cefhost/semlayer.zig");
const host_wreq = @import("cefhost/webrequest.zig");
const host_webext = @import("cefhost/webext.zig");
const host_cookies = @import("cefhost/cookies.zig");
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
const loadretry = @import("loadretry.zig");
const filter = @import("filter.zig");

comptime {
    // The std-only rule names the code by value; the binding is the truth.
    std.debug.assert(loadretry.ERR_NETWORK_CHANGED == cef.ERR_NETWORK_CHANGED);
}
const filtersub = @import("filtersub.zig");
const netpolicy = @import("netpolicy.zig");
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const userscript = @import("userscript.zig");
const gmvalues = @import("gmvalues.zig");
const webexthost = @import("webext/host.zig");
const extinstall = @import("webext/install.zig");
const extmatch = @import("webext/match.zig");
const extmanifest = @import("webext/manifest.zig");
const webrequest = @import("webext/webrequest.zig");
const extassets = @import("webext/assets.zig");
const extorigins = @import("webext/origins.zig");
const bgpage = @import("webext/bgpage.zig");
const exttabs = @import("webext/tabs.zig");
pub const manifestRunAt = extmanifest.RunAt;
pub const manifestContentScript = extmanifest.ContentScript;

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

pub var sem_secret: Secret = .{};

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
pub fn secretEql(a: []const u8, b: []const u8) bool {
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
/// Above `ENGINE_VIEW_BASE` (0x4000_0000) so the three id ranges
/// (client, inspector, background) never collide.
const webext_bg_view_base: u32 = 0x5000_0000;

/// A per-content-script asset is bounded so a pathological manifest
/// cannot make one `ext-inject` command unbounded.
pub const webext_max_asset: usize = 4 * 1024 * 1024;

/// `sem_expand_result` carries a `str`, so one expand cannot exceed
/// what a u16 length can describe.
pub const max_expand: u32 = 60_000;

/// What every semantic request for a DISCARDED view is answered with.
///
/// Answering at all is the point: those requests have no page to reach
/// and no reply would ever arrive on its own, so a client that waits
/// for one (`webdrive`, the `web_*` MCP tools) would sit out its whole
/// timeout on what is really a one-line explanation.
pub const discarded_msg = "view discarded: its browser was destroyed to free memory. Show or navigate the view to bring the page back.";

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
/// spacing. The external mode (and its `SKETERM_WEB_EXTERNAL_BEGINFRAME`
/// switch, the self-pacing watchdog and the GUI's pacer) was removed
/// once no reachable helper could run it: every helper with
/// `frames-inline` (2026-08-12) or `multi-client` already paced itself.
/// `frame_request` stays on the wire for older clients and is ignored.
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
/// The protocol's scale contract (`protocol.ViewCreate`) is
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
// input/paint path so the GUI's probe deltas decompose.
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
pub fn physicalOf(logical: u16, scale_x1000: u16) u16 {
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
    /// Client-set frame-rate cap (`view_max_fps`), 0 = uncapped.
    max_fps: u16 = 0,
    /// Last address CEF reported, owned; the `ev_nav_state` payload,
    /// and — after a `view_discard` — the address the browser comes
    /// back at.
    url: []u8 = &.{},
    /// Last title CEF reported, owned. Kept for the observe family: a
    /// subscriber arriving mid-life is seeded with it, and the
    /// announcement carries it, where the owner already learnt it from
    /// the `ev_title` that stored it.
    title: []u8 = &.{},
    /// Last navigation state posted (`ev_nav_state`), for the same
    /// seeding; `postNavState` reads the engine, this is what a
    /// subscriber is told between two of its calls.
    nav_back: bool = false,
    nav_fwd: bool = false,
    nav_loading: bool = false,
    /// `view_discard` destroyed this view's browser; the record (id,
    /// geometry, scale, address, fps cap) is all that is left. Any
    /// frame that must show, navigate or reach the page revives it
    /// through `findWake`. NAVIGATION HISTORY DOES NOT SURVIVE: the
    /// revived browser starts a fresh session at `url`, so back and
    /// forward are empty — the memory is the whole point, and keeping
    /// the history would mean keeping the browser.
    discarded: bool = false,
    /// The one-shot `ERR_NETWORK_CHANGED` reload budget (see
    /// `loadretry.zig`): reset by a client navigation, spent by the
    /// retry, settled by the retried document's commit.
    load_retry: loadretry.State = .idle,
    /// USER zoom (`set_zoom`), as the engine's log-scale level x100.
    /// Added on top of the DPR zoom in `applyZoom`, and re-applied on
    /// every load start because Chromium resets zoom per navigation.
    user_zoom_x100: i32 = 0,
    /// `tabs.executeScript({runAt:"document_start"})` commands aimed at
    /// the document this view is navigating TO (a main-frame response
    /// has started, the document has not committed): run at the next
    /// main-frame load start. `exec_nav_pending` is that window.
    exec_at_start: std.ArrayList([]u8) = .empty,
    exec_nav_pending: bool = false,
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

    /// The page's current selection, UTF-8, gpa-owned. Kept because
    /// the client cannot ask the engine for it on demand: CEF's C API
    /// has no clipboard or selection getter, only the
    /// `on_text_selection_changed` push.
    sel_text: []u8 = &.{},

    /// A popup the ENGINE opened for `opener_view`, keeping the
    /// `window.opener` relationship the client could never recreate by
    /// opening a tab at the same url.
    page_popup: bool = false,
    opener_view: u32 = 0,
    /// Per-view popup policy override (`popup_policy_set`), or null to
    /// follow the connection default.
    popup_allow: ?bool = null,
    popup_disposition: u8 = 0,
    /// The page asked for a popup-SHAPED window, so the client can
    /// present it as one rather than as a full-size tab.
    popup_chromeless: bool = false,
    /// A client frame has named this popup, so it is presented
    /// somewhere. Until then the watchdog owns it — a browser nobody
    /// closes HANGS `cef_shutdown`.
    popup_answered: bool = false,
    /// When the popup's browser was claimed, for that watchdog.
    popup_opened_ms: i64 = 0,

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
pub const PendingPerm = struct {
    id: u64 = 0,
    /// Exactly one of these is non-null while `id != 0`.
    prompt_cb: ?*cef.cef_permission_prompt_callback_t = null,
    media_cb: ?*cef.cef_media_access_callback_t = null,
    /// CEF media bits as asked for, handed back verbatim on an allow.
    media_bits: u32 = 0,

    pub fn busy(self: *const PendingPerm) bool {
        return self.id != 0;
    }
};

/// Bit marking a media-access id as helper-minted; see `PendingPerm`.
pub const media_id_bit: u64 = 1 << 63;

/// Queued messages past which a GPU frame is dropped rather than
/// enqueued — see `Host.postDmabuf`.
pub const max_frame_backlog = 8;

/// One in-flight round trip to the injected script.
///
/// Actions are multi-step on purpose: a click first asks the script
/// where the element IS, and the click itself is then synthesized
/// through the ordinary input path so the page sees `isTrusted`.
pub const Pending = struct {
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
    /// Eval-only: the caller's per-string serialization budget
    /// (`SemEval.max_str`, 0 = the page-side default). It travels with
    /// the code for the same reason the two above do — the CSP re-send
    /// must be byte-equivalent, budget included.
    eval_max_str: u32 = 0,

    pub const Kind = enum {
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
        review,
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

pub const semantic_request_timeout_ms: i64 = 120_000;

/// How long a download's target decision is HELD for the client before
/// the helper cancels it itself. Generous, because the GUI's answer can
/// be a human in a save dialog; bounded at all, because a client that
/// does not understand the download frames (every client before this
/// wire grew them) otherwise leaves the engine's target determiner
/// waiting forever — the page's download then never lands anywhere and
/// nothing anywhere says so. That was the field failure: a clicked
/// download reported success, a temp file appeared and was reaped, and
/// no error existed on any side.
pub var download_hold_ms: i64 = 300_000;

/// `SKETERM_WEB_DOWNLOAD_HOLD_MS=<n>` shortens the hold so the smoke
/// rig can watch it expire; the operator-facing shape of
/// `wreqReadTimeoutEnv`.
pub fn dlReadHoldEnv() void {
    const v = c.getenv("SKETERM_WEB_DOWNLOAD_HOLD_MS") orelse return;
    const n = std.fmt.parseInt(i64, std.mem.span(v), 10) catch return;
    if (n > 0) download_hold_ms = n;
}

/// How long a `download_start` waits for the engine to offer ITS
/// download before the request is answered as failed. A url the engine
/// declines to download at all (it navigates instead, or refuses the
/// scheme) produces no callback whatsoever, so silence is the only
/// signal there is.
pub const dl_start_wait_ms: i64 = 15_000;
/// How long a routed runtime/tabs.sendMessage may wait for `ext-reply`
/// before the sender's Promise is settled with an error. Same expiry
/// tick as the semantic Pending deadlines (`semanticPump`); shorter,
/// because the common failure is a background page whose bootstrap has
/// not run yet, and the sender retries.
pub const route_reply_timeout_ms: i64 = 30_000;
pub const stale_reader_msg = "stale reader id: the page changed since web_read; read the page again";

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

/// One popup allowed in `on_before_popup` and awaiting its browser.
///
/// Keyed rather than a single slot because several popups can be in
/// flight at once, and matched on the OPENER's cef id: `popup_id`
/// appears on `on_before_popup`/`on_before_popup_aborted` only, never
/// on `on_after_created`, so within one opener the match is FIFO.
const PendingPopup = struct {
    popup_id: c_int = 0,
    opener_cef_id: c_int = 0,
    view: ?*View = null,
    armed_ms: i64 = 0,
};

/// A resolved outbound target: where to post, and the id-window base
/// to subtract so the frame carries the CLIENT's namespace again.
const RouteTo = struct {
    out: *proto.Outbox,
    base: u32,
    /// Non-zero: the receiver is an OBSERVER and knows the view under
    /// this alias id (its own namespace); `view` is replaced with it
    /// instead of window-shifted.
    alias_view: u32 = 0,
};

/// One observer subscription (capability "observe"): connection `conn`
/// sees the view `target` under the engine-global alias id `alias`
/// (in `conn`'s own id window). Frames toward the observer are ALWAYS
/// inline; `dirty` is the union of damage not yet shipped, the same
/// union-and-flush backpressure the owner's inline path uses.
pub const Sub = struct {
    conn: u32,
    alias: u32,
    target: u32,
    control: bool,
    /// `view_hide` from the observer: nothing is shipped until its
    /// `view_show`, which re-seeds the whole surface.
    paused: bool = false,
    dirty: ?proto.Rect = null,
};

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
    /// Non-zero while the frame being dispatched named an observer
    /// ALIAS (capability "observe"): the engine-global alias id. `find`
    /// then admits the foreign target and `routeFor` answers the
    /// dispatching observer under that id, so a synchronous reply to
    /// an observer's own request never reaches the owner.
    dispatch_alias: u32 = 0,
    /// Observer subscriptions, and the connections that asked for
    /// page announcements (`observe_enable`).
    subs: std.ArrayList(Sub) = .empty,
    observers: std.ArrayList(u32) = .empty,
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
    /// Connection-default popup policy, pushed by the client with
    /// `popup_policy_set{view=0}`. BLOCK unless told otherwise, so a
    /// client that never pushes keeps the old cancel-everything
    /// behaviour exactly.
    popup_default: bool = false,
    /// Popups allowed in `on_before_popup` and not yet claimed in
    /// `on_after_created`, keyed by the engine's own popup id and the
    /// opener's cef id. NOT `adopting`, whose docblock explains it
    /// cannot be scoped to one call — several popups can be in flight.
    pending_popups: [8]PendingPopup = @splat(.{}),
    /// Next helper-minted view id (inspectors and page popups). Client
    /// ids come from the client and start at 1; see
    /// `proto.ENGINE_VIEW_BASE`.
    next_engine_view: u32 = proto.ENGINE_VIEW_BASE,
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
    /// `download_start` requests whose engine download has not been
    /// offered yet, oldest first — the only join CEF leaves between a
    /// `start_download` call and the item it produces (`dlPendingReq`).
    dl_pending: std.ArrayList(DlPending) = .empty,

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
    /// both client ids (from 1) and inspector ids (ENGINE_VIEW_BASE).
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
    /// Why this ROUTED instance serves nothing (empty while it serves):
    /// the engine refused the route's proxy, or the WebRTC policy that
    /// keeps UDP inside it, on some request context. From then on no
    /// browser, background page or fetch is created, every view is
    /// refused with this sentence, and every client is told at its
    /// handshake (`ev_route_refused`): a routed tab that cannot prove its
    /// traffic takes the route must not load at all. Static text in
    /// `route_refusal_buf`.
    route_refusal: []const u8 = "",
    route_refusal_buf: [256]u8 = undefined,
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
    /// GM_setValue storage (see `gmvalues.zig`).
    gm_values: gmvalues.Values = undefined,
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

    pub const ScriptRec = struct {
        id: u32,
        meta: userscript.Meta,
        source: []const u8,
        /// Random per `us_script_set`: what a `us-call` must present.
        /// The id alone is guessable by any page.
        cap: [32]u8 = @splat('0'),
        /// `gmvalues.keyFor(@namespace, @name)`.
        key: [16]u8 = @splat('0'),
    };
    pub const StyleRec = struct {
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
    pub const PendingReply = struct {
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

        pub const Kind = enum {
            message,
            popup,
            /// `tabs.executeScript` / `insertCSS` / `removeCSS`: the
            /// target frame answers with `ext-exec-result`.
            exec,

            /// What the waiting Promise is rejected with when its
            /// recipient goes away.
            pub fn gone(self: Kind) []const u8 {
                return switch (self) {
                    .message => "message recipient is gone",
                    .popup => "popup target is gone",
                    .exec => "the tab's document went away before the script ran",
                };
            }

            /// ... and when it simply never answers.
            pub fn expired(self: Kind) []const u8 {
                return switch (self) {
                    .message => "message recipient did not reply",
                    .popup => "native popup was never acknowledged",
                    .exec => "the script did not run (it may not have compiled)",
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
    pub const Port = struct {
        gid: u32,
        ext: []u8,
        a_view: u32,
        b_view: u32,

        pub fn peerOf(self: *const Port, view: u32) u32 {
            if (self.a_view == view) return self.b_view;
            if (self.b_view == view) return self.a_view;
            return 0;
        }
    };

    /// One `print_pdf` in flight. `path` is the client's (the answer's
    /// correlation key); `staged`, when set, is where the engine really
    /// writes.
    const Print = struct {
        view: u32,
        path: []u8,
        staged: ?[:0]u8 = null,

        pub fn target(self: *const Print) []const u8 {
            return if (self.staged) |s| s else self.path;
        }

        pub fn deinit(self: *Print, gpa: std.mem.Allocator, unlink_staged: bool) void {
            if (self.staged) |s| {
                if (unlink_staged) _ = c.unlink(s.ptr);
                gpa.free(s);
            }
            gpa.free(self.path);
        }
    };

    /// One engine download. `before_cb` is the HELD target decision
    /// (`ev_download_offer`'s other half); `item_cb` is the latest
    /// cancel handle the engine offered, kept so a `download_cancel`
    /// (or a dying view) can abort the transfer. Both references are
    /// owned and released exactly once, same discipline as `cert_cb`.
    pub const Dl = struct {
        id: u32,
        view: u32,
        /// The `download_start.req` this download answers; 0 when the
        /// page started it by itself.
        req: u32 = 0,
        /// When the offer was posted, so an offer nobody ever answers
        /// is cancelled rather than held for the life of the helper
        /// (`download_hold_ms`).
        offered_ms: i64 = 0,
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
        interrupt_reason: i32 = 0,
        staging: [128:0]u8 = @splat(0),
        staging_len: usize = 0,
        /// Counters moved since the last flush (the intercept_status
        /// coalescing pattern: one frame per poll iteration at most).
        dirty: bool = false,
        /// Throwaway path a CANCELLED offer was continued into (see
        /// `cancelDl`: the engine's held target callback must always
        /// run, or shutdown hangs on the download manager). Unlinked
        /// when the entry is dropped.
        trash: [128]u8 = @splat(0),
        trash_len: usize = 0,

        pub fn terminal(self: *const Dl) bool {
            return self.done or self.failed;
        }

        pub fn dropTrash(self: *Dl) void {
            if (self.staging_len != 0 and (!self.done or self.cancel_requested)) {
                _ = c.unlink(&self.staging);
                self.staging_len = 0;
            }
            if (self.trash_len == 0) return;
            self.trash[self.trash_len] = 0;
            _ = c.unlink(@ptrCast(&self.trash));
            self.trash_len = 0;
        }

        pub fn releaseCbs(self: *Dl) void {
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

    /// One asked-for download waiting for the engine to offer it.
    const DlPending = struct { view: u32, req: u32, at_ms: i64 };

    pub fn init(gpa: std.mem.Allocator, out: *proto.Outbox) Host {
        return .{ .gpa = gpa, .out = out, .webext = webexthost.Host.init(gpa), .gm_values = gmvalues.Values.init(gpa) };
    }

    pub fn deinit(self: *Host) void {
        self.destroyAll();
        if (self.presenter) |p| {
            p.deinit();
            self.presenter = null;
        }
        self.views.deinit(self.gpa);
        self.subs.deinit(self.gpa);
        self.observers.deinit(self.gpa);
        self.webext.deinit();
        self.gm_values.deinit();
        for (self.webext_replies.items) |r| self.gpa.free(r.ext);
        self.webext_replies.deinit(self.gpa);
        for (self.webext_ports.items) |p| self.gpa.free(p.ext);
        self.webext_ports.deinit(self.gpa);
        for (self.webext_reload.items) |p| self.gpa.free(p);
        self.webext_reload.deinit(self.gpa);
        extorigins.clear();
        // Nobody will fetch a staged print that never finished.
        for (self.prints.items) |*p| p.deinit(self.gpa, true);
        self.prints.deinit(self.gpa);
        // destroyAll's dropBrowser sweep already cancelled and freed
        // per-view entries; whatever is left never named a live view.
        for (self.downloads.items) |*d| d.releaseCbs();
        self.downloads.deinit(self.gpa);
        self.dl_pending.deinit(self.gpa);
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

    pub fn lookupContext(self: *Host, id: u32) ?*cef.cef_request_context_t {
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
    pub fn contextForSpawn(self: *Host, v: *const View) SpawnRefusal!?*cef.cef_request_context_t {
        try self.requireContext(v);
        if (v.context == 0) return null;
        const rc = self.lookupContext(v.context).?;
        if (rc.base.base.add_ref) |add| add(&rc.base.base);
        return rc;
    }

    const SpawnRefusal = error{ ContextGone, RouteRefused };

    /// `contextForSpawn`'s refusal without its reference: this instance
    /// still serves its route, and the container a view names still
    /// exists (or it never named one).
    pub fn requireContext(self: *Host, v: *const View) SpawnRefusal!void {
        if (self.route_refusal.len != 0) return error.RouteRefused;
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
        // preference was refused would make its views use direct traffic,
        // and an engine that refused the route once has no business
        // serving it at all (`route_refusal`). The proxy is the
        // INSTANCE's route; a direct instance leaves it empty and every
        // context is direct.
        if (self.instance_proxy.len != 0) {
            if (routeContext(rc, self.instance_proxy)) |why| {
                release(&rc.base.base);
                self.refuseRoute(why);
                // The client minting the context learns now; any other
                // connection at its next view, which is refused.
                self.post(proto.EvRouteRefused{ .reason = self.route_refusal });
                return;
            }
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
        // The global context serves context-0 (default-jar) views,
        // background pages and filter fetches; a routed instance must
        // route it too, or an un-containered tab would leak direct.
        if (self.instance_proxy.len != 0) {
            const global_c: ?*cef.cef_request_context_t = cef.cef_request_context_get_global_context();
            const global = global_c orelse return self.refuseRoute("the engine has no global request context to route");
            defer release(&global.base.base);
            if (routeContext(global, self.instance_proxy)) |why| self.refuseRoute(why);
        }
    }

    /// Stop serving: see `route_refusal`. Idempotent; the first reason
    /// is the one clients are told.
    fn refuseRoute(self: *Host, why: []const u8) void {
        if (self.route_refusal.len != 0) return;
        self.route_refusal = std.fmt.bufPrint(
            &self.route_refusal_buf,
            "this route's browser serves nothing, because {s} (it fails closed rather than browse outside the route)",
            .{why},
        ) catch "this route's browser serves nothing (it fails closed rather than browse outside the route)";
        std.debug.print("sketerm-web: {s}\n", .{self.route_refusal});
    }

    pub const presenterStart = host_obs.presenterStart;
    pub const presenterActive = host_obs.presenterActive;
    pub const presenterFd = host_obs.presenterFd;
    pub const presenterWantsWrite = host_obs.presenterWantsWrite;
    pub const presenterPump = host_obs.presenterPump;
    pub const aliasOf = host_obs.aliasOf;
    pub const isObserver = host_obs.isObserver;
    pub const aliasWire = host_obs.aliasWire;
    pub const observerOut = host_obs.observerOut;
    pub const announceTo = host_obs.announceTo;
    pub const observeEnable = host_obs.observeEnable;
    pub const observeViewPresent = host_obs.observeViewPresent;
    pub const observeViewGone = host_obs.observeViewGone;
    pub const postObserveState = host_obs.postObserveState;
    pub const observeSubscribe = host_obs.observeSubscribe;
    pub const seedObserver = host_obs.seedObserver;
    pub const observeControl = host_obs.observeControl;
    pub const observeUnsubscribe = host_obs.observeUnsubscribe;
    pub const observePause = host_obs.observePause;
    pub const observeGeometry = host_obs.observeGeometry;
    pub const observeDropConn = host_obs.observeDropConn;
    pub const observeDamage = host_obs.observeDamage;
    pub const flushSub = host_obs.flushSub;
    pub const flushObservers = host_obs.flushObservers;
    pub const presentPaint = host_obs.presentPaint;
    pub const presentTitle = host_obs.presentTitle;

    /// View lookup, and the multi-client ownership chokepoint: while a
    /// connection's frame is being dispatched, another connection's
    /// view does not exist. Regular ids cannot cross namespaces (the
    /// server's window arithmetic keeps them apart); this check is the
    /// belt for engine-minted ids (inspectors and page popups), which
    /// pass the edge untranslated.
    ///
    /// A client frame naming a page popup is also what marks it
    /// ANSWERED: the popup is now presented somewhere, so the watchdog
    /// stops owning it and it may outlive its opener.
    pub fn find(self: *Host, id: u32) ?*View {
        const v = self.findAny(id) orelse return null;
        // An observer's frame arrives with its alias already resolved
        // to the target by the server edge, which also applied the
        // lease gate; `dispatch_alias` is the proof that this foreign
        // view is the one it subscribed to.
        if (self.dispatch_alias != 0) {
            if (self.aliasOf(self.dispatch_conn, self.dispatch_alias)) |sub| {
                if (sub.target == v.id) return v;
            }
            return null;
        }
        if (self.dispatch_conn != 0 and v.owner != 0 and v.owner != self.dispatch_conn) return null;
        if (self.dispatch_conn != 0 and v.page_popup) v.popup_answered = true;
        return v;
    }

    /// Lookup without the ownership check — for the host's own routing
    /// and cleanup, never for dispatching a client's frame.
    pub fn findAny(self: *Host, id: u32) ?*View {
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
        if (self.route_refusal.len != 0) {
            self.post(proto.EvViewCreateFailed{ .view = req.view, .context = req.context, .reason = self.route_refusal });
            return;
        }
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
            if (spawned) {
                self.observeViewPresent(v);
                return;
            }
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

    /// Mint the next helper-owned view id. One counter for inspectors
    /// and popups alike, so the two can never collide.
    fn nextEngineView(self: *Host) u32 {
        self.next_engine_view +%= 1;
        if (self.next_engine_view < proto.ENGINE_VIEW_BASE) self.next_engine_view = proto.ENGINE_VIEW_BASE + 1;
        return self.next_engine_view;
    }

    /// Prepare a REAL popup for the engine to create.
    ///
    /// Runs inside `on_before_popup`, which must answer synchronously,
    /// so everything here is bookkeeping plus writing the window info;
    /// the browser itself arrives later in `on_after_created`.
    /// @return false when the popup could not be prepared, leaving the
    /// caller to fall back to cancelling and telling the client.
    fn openPopupFor(
        self: *Host,
        opener: *View,
        popup_id: c_int,
        window_info: [*c]cef.cef_window_info_t,
        features: [*c]const cef.cef_popup_features_t,
        d: proto.Disposition,
        user_gesture: c_int,
        url: []const u8,
        frame_name: []const u8,
    ) bool {
        const slot = self.freePopupSlot() orelse return false;
        var w = opener.w;
        var h = opener.h;
        var chromeless = false;
        if (features != null) {
            if (features.*.widthSet != 0 and features.*.width > 0) w = @intCast(@min(features.*.width, 32767));
            if (features.*.heightSet != 0 and features.*.height > 0) h = @intCast(@min(features.*.height, 32767));
            chromeless = features.*.isPopup != 0;
        }
        const pv = self.registerView(.{
            .view = self.nextEngineView(),
            .w = w,
            .h = h,
            .scale_x1000 = opener.scale_x1000,
            // Bookkeeping only: CEF gives a popup its opener's request
            // context itself, and `on_before_popup` has no out-param
            // for one.
            .context = opener.context,
        }) catch return false;
        // `registerView` derives these from dispatch state, which is
        // zero inside a CEF callback. An owner of 0 also disables the
        // cross-client ownership guard in `find`, so a popup must
        // inherit the opener's.
        pv.owner = opener.owner;
        pv.inline_view = opener.inline_view;
        pv.page_popup = true;
        pv.opener_view = opener.id;
        pv.popup_disposition = @intFromEnum(d);
        pv.popup_chromeless = chromeless;
        pv.popup_allow = opener.popup_allow;
        _ = user_gesture;
        _ = url;
        _ = frame_name;
        // Inherit the opener's shield and enforced policy: without a
        // slot of its own the popup's requests FAIL OPEN, because the
        // whole policy block sits behind `if (slot)`.
        if (interceptSlotFor(self.gpa, pv.id)) |ps| {
            if (interceptSlotFor(self.gpa, opener.id)) |os| {
                host_icpt.g_int.acquire();
                defer host_icpt.g_int.release();
                ps.enabled = os.enabled;
                ps.pol = os.pol;
            }
        }
        window_info.* = windowlessInfo();
        slot.* = .{
            .popup_id = popup_id,
            .opener_cef_id = opener.cef_id,
            .view = pv,
            .armed_ms = nowMs(),
        };
        return true;
    }

    fn freePopupSlot(self: *Host) ?*PendingPopup {
        for (&self.pending_popups) |*p| {
            if (p.view == null) return p;
        }
        return null;
    }

    /// Claim the pending record for a popup that has arrived or been
    /// aborted. `popup_id` is not passed to `on_after_created`, so a
    /// zero id matches the oldest pending popup of that opener.
    fn takePendingPopup(self: *Host, popup_id: c_int, opener_cef_id: c_int) ?*View {
        var best: ?*PendingPopup = null;
        for (&self.pending_popups) |*p| {
            const v = p.view orelse continue;
            if (p.opener_cef_id != opener_cef_id) continue;
            if (popup_id != 0 and p.popup_id != popup_id) continue;
            _ = v;
            if (best == null or p.armed_ms < best.?.armed_ms) best = p;
        }
        const hit = best orelse return null;
        const v = hit.view.?;
        hit.* = .{};
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
        const v = try self.registerView(.{
            .view = self.nextEngineView(),
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
        var winfo = windowlessInfo();
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
        // A page popup the client never claimed belongs to nobody once
        // its opener goes, and a browser nobody closes hangs
        // `cef_shutdown`. An ANSWERED popup is the user's own tab and
        // outlives its opener, as it does in every browser.
        while (self.unansweredPopupOf(id)) |popup| self.destroyView(popup.id);
        // Drop any record still armed for a popup of this view: the
        // browser will never arrive to claim it.
        for (&self.pending_popups) |*p| {
            const pv = p.view orelse continue;
            if (pv.opener_view == id) p.* = .{};
        }
        for (self.views.items, 0..) |v, i| {
            if (v.id != id) continue;
            _ = self.views.swapRemove(i);
            self.observeViewGone(v, "the owner destroyed the view");
            // An inspector outliving its target inspects nothing and
            // has no client surface left to close it, so it goes too;
            // an inspector being closed simply frees its target's slot.
            const inspector = v.devtools_view;
            if (v.devtools_of != 0) {
                if (self.find(v.devtools_of)) |src| src.devtools_view = 0;
            }
            if (self.adopting == v) self.adopting = null;
            if (v.page_popup) self.post(proto.EvPagePopup{
                .owner_view = v.opener_view,
                .popup_view = v.id,
                .state = proto.page_popup_closed,
                .disposition = v.popup_disposition,
                .user_gesture = 0,
                .chromeless = if (v.popup_chromeless) 1 else 0,
                .w = v.w,
                .h = v.h,
                .url = "",
                .frame_name = "",
            });
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

    /// A page popup of `owner` that no client frame has named yet.
    fn unansweredPopupOf(self: *Host, owner: u32) ?*View {
        for (self.views.items) |v| {
            if (v.page_popup and !v.popup_answered and v.opener_view == owner) return v;
        }
        return null;
    }

    pub fn popupForOwner(self: *Host, owner: u32) ?*View {
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

    /// Bind a popup browser CEF just created to the View armed for it
    /// in `on_before_popup`.
    ///
    /// Runs the SPAWN sequence rather than `adoptBrowser`: that one
    /// registers no intercept slot, re-applies no a11y state, and
    /// hardwires an `ev_devtools_view` answer.
    /// @return true when the callback's browser reference was kept.
    fn claimPopupBrowser(self: *Host, b: *cef.cef_browser_t) bool {
        const opener_cef = browserHostInt(b, "get_opener_identifier");
        const v = self.takePendingPopup(0, opener_cef) orelse return false;
        v.browser = b;
        v.cef_id = browserInt(b, "get_identifier");
        // The engine may refuse windowless rendering, as it does for
        // DevTools. A windowed popup has no frames to present, so close
        // it and let the client open its own openerless tab instead of
        // showing a blank pane.
        if (!isWindowless(v)) {
            self.post(proto.EvPopupRequest{
                .view = v.opener_view,
                .url = "",
                .disposition = v.popup_disposition,
                .user_gesture = 1,
            });
            self.destroyView(v.id);
            return true;
        }
        v.popup_opened_ms = nowMs();
        interceptRegister(self.gpa, v.id, v.cef_id);
        applyZoom(v);
        applyA11yState(v);
        // THE ID GOES OUT FIRST, before the frame buffer: a client
        // drops a `frame_buffer` for a view it has never heard of and
        // then waits for a repaint only a geometry change produces.
        self.post(proto.EvPagePopup{
            .owner_view = v.opener_view,
            .popup_view = v.id,
            .state = proto.page_popup_opened,
            .disposition = v.popup_disposition,
            .user_gesture = 1,
            .chromeless = if (v.popup_chromeless) 1 else 0,
            .w = v.w,
            .h = v.h,
            .url = if (v.url.len != 0) v.url else "",
            .frame_name = "",
        });
        self.allocBuffer(v) catch {};
        self.observeViewPresent(v);
        return true;
    }

    /// The popup closed itself (`window.close()`, which every OAuth
    /// flow ends with). Tell the client so it can retire the tab, then
    /// free the record WITHOUT asking the engine to close again.
    fn pagePopupClosedByEngine(self: *Host, v: *View) void {
        for (self.views.items, 0..) |it, i| {
            if (it != v) continue;
            self.abandonViewWaiters(v.id);
            _ = self.views.swapRemove(i);
            self.observeViewGone(v, "the page closed itself");
            self.post(proto.EvPagePopup{
                .owner_view = v.opener_view,
                .popup_view = v.id,
                .state = proto.page_popup_closed,
                .disposition = v.popup_disposition,
                .user_gesture = 0,
                .chromeless = if (v.popup_chromeless) 1 else 0,
                .w = v.w,
                .h = v.h,
                .url = "",
                .frame_name = "",
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
        self.observeDropConn(conn_id);
        // Its tabs leave with it, as onRemoved, or an extension keeps
        // per-tab state for a window that no longer exists.
        if (self.webext.tabs.dropOwner(self.gpa, conn_id)) |gone| {
            defer self.gpa.free(gone);
            for (gone) |id| {
                self.postTabRemoved(id);
                for (self.webext.exts.items) |*e| e.action.removeTab(self.gpa, id);
            }
        } else |_| {}
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
            host_icpt.g_int.acquire();
            defer host_icpt.g_int.release();
            for (&host_icpt.g_int.slots) |*s| {
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
        // A revival goes through `create_browser_sync`, which makes a
        // fresh TOP-LEVEL browser — silently re-breaking the opener
        // relationship this popup exists for.
        if (v.page_popup) return;
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
            if (err == error.BrowserCreateFailed or err == error.ContextGone or err == error.RouteRefused) {
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

        var winfo = windowlessInfo();
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
        const refuse = proto.EvPrintPdfDone{ .view = req.view, .ok = 0, .path = req.path };
        const v = self.find(req.view) orelse return self.post(refuse);
        const host = browserHost(v) orelse return self.post(refuse);
        defer release(&host.base);
        const print = host.print_to_pdf orelse return self.post(refuse);
        const owned = self.gpa.dupe(u8, req.path) catch return self.post(refuse);
        var entry: Print = .{ .view = v.id, .path = owned };
        // Staged: the client is on another host and fetches the file
        // afterwards, so the engine writes a private file of ours and the
        // request path only correlates the answer.
        if (req.stage != 0) {
            var buf: [64:0]u8 = undefined;
            const staged = stagingFile(&buf, "webpdf") orelse {
                self.gpa.free(owned);
                return self.post(refuse);
            };
            entry.staged = self.gpa.dupeZ(u8, staged) catch {
                _ = c.unlink(staged.ptr);
                self.gpa.free(owned);
                return self.post(refuse);
            };
        }
        self.prints.append(self.gpa, entry) catch {
            entry.deinit(self.gpa, false);
            return self.post(refuse);
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
        setStr(entry.target(), &path);
        defer cef.cef_string_utf16_clear(&path);
        print(host, &path, &settings, &pdf_callback);
    }

    /// The engine finished writing (or failed to write) a PDF. The
    /// path it wrote is the correlation key: CEF's callback carries no
    /// request id, and a client may have several prints in flight.
    fn onPrintDone(self: *Host, path: []const u8, ok: bool) void {
        for (self.prints.items, 0..) |p, i| {
            if (!std.mem.eql(u8, p.target(), path)) continue;
            var done = self.prints.orderedRemove(i);
            // A failed staging file is ours to remove; a written one now
            // belongs to the client's delivery.
            defer done.deinit(self.gpa, !ok);
            self.post(proto.EvPrintPdfDone{
                .view = done.view,
                .ok = if (ok) 1 else 0,
                .path = done.path,
                .staged = if (ok) (done.staged orelse "") else "",
            });
            return;
        }
    }

    pub const requestContextFor = host_cookies.requestContextFor;
    pub const cookieManagerFor = host_cookies.cookieManagerFor;
    pub const flushProfileStores = host_cookies.flushProfileStores;
    pub const flushCompleted = host_cookies.flushCompleted;
    pub const postFlushed = host_cookies.postFlushed;
    pub const cookiesReq = host_cookies.cookiesReq;
    pub const postNoCookies = host_cookies.postNoCookies;
    pub const cookieDelete = host_cookies.cookieDelete;
    pub const cookiesClear = host_cookies.cookiesClear;
    pub const deleteCookies = host_cookies.deleteCookies;
    pub const postSiteFail = host_cookies.postSiteFail;
    pub const sitedataClear = host_cookies.sitedataClear;
    pub const cookieSyncEnable = host_cookies.cookieSyncEnable;
    pub const cookieSyncDropConn = host_cookies.cookieSyncDropConn;
    pub const cookieSyncArm = host_cookies.cookieSyncArm;
    pub const cookieSyncOn = host_cookies.cookieSyncOn;
    pub const postSyncTo = host_cookies.postSyncTo;
    pub const postSyncAll = host_cookies.postSyncAll;
    pub const cookieManagerForContext = host_cookies.cookieManagerForContext;
    pub const cookieSyncContexts = host_cookies.cookieSyncContexts;
    pub const cookieSyncPump = host_cookies.cookieSyncPump;
    pub const drainSavedCookies = host_cookies.drainSavedCookies;
    pub const noteCookie = host_cookies.noteCookie;
    pub const shadowFind = host_cookies.shadowFind;
    pub const shadowInsert = host_cookies.shadowInsert;
    pub const shadowRemove = host_cookies.shadowRemove;
    pub const cookieSyncForgetContext = host_cookies.cookieSyncForgetContext;
    pub const shadowSeeded = host_cookies.shadowSeeded;
    pub const markShadowSeeded = host_cookies.markShadowSeeded;
    pub const cookieApply = host_cookies.cookieApply;
    pub const settleApply = host_cookies.settleApply;
    pub const postApplyDone = host_cookies.postApplyDone;
    pub const cookieDump = host_cookies.cookieDump;
    pub const postDumpFail = host_cookies.postDumpFail;

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

    pub fn clearPageStorage(_: *Host, v: *View) void {
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

    pub fn freeView(self: *Host, v: *View) void {
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
        if (v.title.len != 0) self.gpa.free(v.title);
        if (v.sel_text.len != 0) self.gpa.free(v.sel_text);
        v.pending.deinit(self.gpa);
        for (v.exec_at_start.items) |js| self.gpa.free(js);
        v.exec_at_start.deinit(self.gpa);
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
    pub fn allocBuffer(self: *Host, v: *View) !void {
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
        self.observeGeometry(v);
    }

    /// `view_show` / `view_hide`. A SHOW revives a discarded view — it
    /// is the frame that means the pane is on screen again, and the
    /// revived browser is created visible, so the calls below then only
    /// re-state what is already true.
    pub fn showView(self: *Host, id: u32, show: bool) void {
        const v = if (show) self.findWake(id) orelse return else self.find(id) orelse return;
        if (v.discarded) return;
        v.hidden = !show;
        // A view coming back repaints everything (the invalidate): its
        // pixels may be stale from before it was hidden.
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

    // -- periodic duties -----------------------------------------------

    /// Everything that has to happen on time rather than on an event:
    /// filter-list fetches, a stopped scroll's resting position, and the
    /// deadlines of engine promises nobody else would ever answer.
    /// Called once per poll iteration.
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
        // A popup the client never claimed: it has no surface, nobody
        // will ever close it, and an open browser hangs `cef_shutdown`.
        var pi: usize = 0;
        while (pi < self.views.items.len) {
            const v = self.views.items[pi];
            pi += 1;
            if (!v.page_popup or v.popup_answered) continue;
            if (v.browser == null) continue;
            if (now_ms - v.popup_opened_ms <= adopt_timeout_ms) continue;
            self.destroyView(v.id);
            pi = 0;
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

    pub const interceptSet = host_icpt.interceptSet;
    pub const interceptLists = host_icpt.interceptLists;
    pub const interceptSubscribe = host_icpt.interceptSubscribe;
    pub const interceptStatus = host_icpt.interceptStatus;
    pub const statusFrame = host_icpt.statusFrame;
    pub const interceptLog = host_icpt.interceptLog;
    pub const netPolicySet = host_icpt.netPolicySet;
    pub const netPolicyStatus = host_icpt.netPolicyStatus;
    pub const netLog = host_icpt.netLog;
    pub const flushNetPolicy = host_icpt.flushNetPolicy;
    pub const flushInterceptStatus = host_icpt.flushInterceptStatus;
    pub const usScriptSet = host_us.usScriptSet;
    pub const usStyleSet = host_us.usStyleSet;
    pub const applyStylesNow = host_us.applyStylesNow;
    pub const injectUserContent = host_us.injectUserContent;
    pub const injectUserscript = host_us.injectUserscript;
    pub const usCall = host_us.usCall;
    pub const usXhrReply = host_us.usXhrReply;
    pub const findDl = host_dl.findDl;
    pub const downloadDecide = host_dl.downloadDecide;
    pub const cancelDl = host_dl.cancelDl;
    pub const downloadCancel = host_dl.downloadCancel;
    pub const downloadStart = host_dl.downloadStart;
    pub const dlPendingReq = host_dl.dlPendingReq;
    pub const expireDlPending = host_dl.expireDlPending;

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
        self.flushObservers();
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
        v.inline_dirty = null;
        const wire_view = if (route.alias_view != 0) route.alias_view else v.id - route.base;
        self.shipInline(v, d, route.out, wire_view);
    }

    /// Encode `d` of `v`'s live buffer into banded `frame_inline`
    /// messages on `out`, carrying `wire_view` (the RECEIVER's id for
    /// the view). Shared by the owner's inline path and the observer
    /// path, so both ship byte-identical frames.
    pub fn shipInline(self: *Host, v: *View, d: proto.Rect, out: *proto.Outbox, wire_view: u32) void {
        const stride: usize = v.stride();
        // Clamp against the live buffer: a dirty rect can predate a
        // resize by one poll iteration.
        const x: u16 = @min(d.x, v.pw -| 1);
        const y0: u16 = @min(d.y, v.ph -| 1);
        const w: u16 = @min(d.w, v.pw - x);
        const total_h: u16 = @min(d.h, v.ph - y0);
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
            out.post(proto.FrameInline{
                .view = wire_view,
                .gen = v.gen,
                .w = v.pw,
                .h = v.ph,
                .rects = &.{rect},
            }, null) catch {};
            y = @intCast(@min(y_end, @as(u32, y) + rows));
        }
    }

    pub const flushDownloadProgress = host_dl.flushDownloadProgress;
    pub const dropDownloadsOf = host_dl.dropDownloadsOf;
    pub fn navigate(self: *Host, req: proto.Navigate) void {
        const v = self.find(req.view) orelse return;
        // A discarded view is revived straight AT the requested address
        // rather than at the one it was discarded holding: reviving
        // first and navigating after would mint a document nobody asked
        // for, which is the two-document trap `view_create_url` exists
        // to avoid.
        v.load_retry.reset();
        self.semanticNavigationStarted(v);
        v.sem_nav.waiting_load_start = true;
        if (v.discarded) return self.reviveAt(v, req.url);
        self.loadUrl(v, req.url);
    }

    /// Load `url` in the view's main frame. The semantic side must
    /// already have been told a navigation started; the network-change
    /// retry and `navigate` share this and differ only in what they
    /// do to the retry budget.
    fn loadUrl(self: *Host, v: *View, url_text: []const u8) void {
        _ = self;
        const b = v.browser orelse return;
        const get_frame = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = get_frame(b) orelse return;
        defer release(&frame.base);
        var url = std.mem.zeroes(cef.cef_string_t);
        setStr(url_text, &url);
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
                v.load_retry.reset();
                self.semanticNavigationStarted(v);
                v.sem_nav.waiting_load_start = true;
                if (b.go_back) |f| f(b);
            },
            .forward => if (browserInt(b, "can_go_forward") != 0) {
                v.load_retry.reset();
                self.semanticNavigationStarted(v);
                v.sem_nav.waiting_load_start = true;
                if (b.go_forward) |f| f(b);
            },
            .reload => {
                v.load_retry.reset();
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

    pub const certDecision = host_sec.certDecision;
    pub const permissionDecision = host_sec.permissionDecision;
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
            .commit => commitText(v, req.text, req.cursor),
            .cancel => withHostArgs(v, imeCancel, .{}),
            _ => {},
        }
    }

    /// Commit `text` into `v`'s focused editable, replacing any
    /// selection — the ONE home for that call, shared by the IME commit
    /// and by `paste`, so the two cannot drift.
    ///
    /// `ime_commit_text` is documented windowless-only, which every
    /// frame-producing view here is (`windowlessInfo`); it is a silent
    /// no-op for the windowed DevTools inspector.
    fn commitText(v: *View, text: []const u8, cursor: i32) void {
        var s = std.mem.zeroes(cef.cef_string_t);
        setStr(text, &s);
        defer cef.cef_string_utf16_clear(&s);
        withHostArgs(v, imeCommit, .{ &s, cursor });
    }

    /// Insert the client's clipboard text at the caret.
    ///
    /// The client pushes the TEXT, not a "paste" command, because the
    /// engine's own clipboard is empty here: `cef_frame_t::paste` would
    /// run a real Paste against nothing, replacing the selection with
    /// nothing. Committing the text is what makes select-all + paste do
    /// what the user meant.
    /// Install the client's popup policy AHEAD of any decision.
    /// `view == 0` is the connection default; anything else is that
    /// view's override, which is how a per-site allow reaches here.
    pub fn popupPolicySet(self: *Host, req: proto.PopupPolicySet) void {
        const allow = req.mode == proto.popup_mode_allow;
        if (req.view == 0) {
            self.popup_default = allow;
            return;
        }
        const v = self.find(req.view) orelse return;
        v.popup_allow = allow;
    }

    /// Insert the client's clipboard text at the caret, as CHAR events.
    ///
    /// NOT `ime_commit_text`: MEASURED (smoke-web stage ob4b, which
    /// failed on exactly this) a standalone commit with no active
    /// composition inserts NOTHING in a windowless browser — the
    /// commit path at `Host.ime` works only because a composition is
    /// live there. `typeText` is the same trusted char-event path
    /// `set_value` and `input_key` use, so a page cannot tell a paste
    /// from a human typing, and it is the one already proven end to
    /// end. Newlines ride through as their own char events, which is
    /// what a real paste into a textarea does.
    pub fn paste(self: *Host, req: proto.InputPaste) void {
        const v = self.findWake(req.view) orelse return;
        typeText(v, req.text.s);
    }

    /// Answer the client's `clipboard_read` from the selection CEF
    /// reports through `on_text_selection_changed`. A `cut` deletes the
    /// selection only AFTER the answer is posted, so the text can never
    /// be lost to a delete that raced its own reply.
    pub fn clipboardRead(self: *Host, req: proto.ClipboardRead) void {
        const v = self.findWake(req.view) orelse return;
        self.post(proto.EvClipboardText{
            .view = v.id,
            .seq = req.seq,
            .text = .{ .s = v.sel_text },
        });
        if (@as(proto.ClipboardMode, @enumFromInt(req.mode)) != .cut) return;
        if (v.sel_text.len == 0) return;
        const b = v.browser orelse return;
        const get_frame = b.get_main_frame orelse return;
        const frame: *cef.cef_frame_t = get_frame(b) orelse return;
        defer release(&frame.base);
        if (frame.del) |del| del(frame);
    }

    pub fn focus(self: *Host, req: proto.InputFocus) void {
        const v = self.findWake(req.view) orelse return;
        withHostArgs(v, setFocus, .{@as(c_int, if (req.focused != 0) 1 else 0)});
    }

    pub const webextSet = host_webext.webextSet;
    pub const webextInstallPrepare = host_webext.webextInstallPrepare;
    pub const webextInstallCommit = host_webext.webextInstallCommit;
    pub const quiesceWebext = host_webext.quiesceWebext;
    pub const publishOrigin = host_webext.publishOrigin;
    pub const unpublishOrigin = host_webext.unpublishOrigin;
    pub const revokeExtension = host_webext.revokeExtension;
    pub const webextRemove = host_webext.webextRemove;
    pub const teardownPopups = host_webext.teardownPopups;
    pub const webextList = host_webext.webextList;
    pub const webextTabs = host_webext.webextTabs;
    pub const postActionsForActiveViews = host_webext.postActionsForActiveViews;
    pub const actionSnapshot = host_webext.actionSnapshot;
    pub const webextActionActivate = host_webext.webextActionActivate;
    pub const popupError = host_webext.popupError;
    pub const removePopupView = host_webext.removePopupView;
    pub const spawnPopup = host_webext.spawnPopup;
    pub const postTabEvent = host_webext.postTabEvent;
    pub const postTabRemoved = host_webext.postTabRemoved;
    pub const postWebextState = host_webext.postWebextState;
    pub const ensureBackground = host_webext.ensureBackground;
    pub const backgroundUrl = host_webext.backgroundUrl;
    pub const spawnBackground = host_webext.spawnBackground;
    pub const teardownBackground = host_webext.teardownBackground;
    pub const injectContentScriptsAll = host_webext.injectContentScriptsAll;
    pub const injectMatchingExtensions = host_webext.injectMatchingExtensions;
    pub const injectExtInto = host_webext.injectExtInto;
    pub const writeManifestJson = host_webext.writeManifestJson;
    pub const writeMessagesJson = host_webext.writeMessagesJson;
    pub const contentScriptMatches = host_webext.contentScriptMatches;
    pub const injectBackground = host_webext.injectBackground;
    pub const writeBackgroundPageScripts = host_webext.writeBackgroundPageScripts;
    pub const onExtMessage = host_webext.onExtMessage;
    pub const extApiCall = host_webext.extApiCall;
    pub const sendExtReply = host_webext.sendExtReply;
    pub const sendExtResult = host_webext.sendExtResult;
    pub const extReplyErr = host_webext.extReplyErr;
    pub const extReplyOk = host_webext.extReplyOk;
    pub const extOpenPopup = host_webext.extOpenPopup;
    pub const webextOpenPopupResult = host_webext.webextOpenPopupResult;
    pub const pushReply = host_webext.pushReply;
    pub const takeReply = host_webext.takeReply;
    pub const failReply = host_webext.failReply;
    pub const repliesAbandonView = host_webext.repliesAbandonView;
    pub const repliesAbandonExt = host_webext.repliesAbandonExt;
    pub const extRouteSend = host_webext.extRouteSend;
    pub const extRequestReload = host_webext.extRequestReload;
    pub const webextPump = host_webext.webextPump;
    pub const extTabsNavigate = host_webext.extTabsNavigate;
    pub const extTabView = host_webext.extTabView;
    pub const extHostAllowed = host_webext.extHostAllowed;
    pub const extTabsExec = host_webext.extTabsExec;
    pub const flushExecAtStart = host_webext.flushExecAtStart;
    pub const extExecResult = host_webext.extExecResult;
    pub const frameById = host_webext.frameById;
    pub const extTabsGetZoom = host_webext.extTabsGetZoom;
    pub const extWebNavFrames = host_webext.extWebNavFrames;
    pub const webNavEvent = host_webext.webNavEvent;
    pub const postNsEvent = host_webext.postNsEvent;
    pub const extTabsSendMessage = host_webext.extTabsSendMessage;
    pub const extPortConnect = host_webext.extPortConnect;
    pub const sendPortOpen = host_webext.sendPortOpen;
    pub const findPort = host_webext.findPort;
    pub const extPortMessage = host_webext.extPortMessage;
    pub const extPortClose = host_webext.extPortClose;
    pub const closePortByGid = host_webext.closePortByGid;
    pub const notifyPortClosed = host_webext.notifyPortClosed;
    pub const portsAbandonView = host_webext.portsAbandonView;
    pub const portsAbandonExt = host_webext.portsAbandonExt;
    pub const writeSender = host_webext.writeSender;
    pub const extRouteReply = host_webext.extRouteReply;
    pub const webrequestPump = host_wreq.webrequestPump;
    pub const writeWreqCommand = host_wreq.writeWreqCommand;
    pub const wreqStepDone = host_wreq.wreqStepDone;
    pub const wreqAdvance = host_wreq.wreqAdvance;
    pub const wreqFinish = host_wreq.wreqFinish;
    pub const wreqRetire = host_wreq.wreqRetire;
    pub const wreqDecision = host_wreq.wreqDecision;
    pub const webrequestStats = host_wreq.webrequestStats;
    pub const broadcastChanged = host_wreq.broadcastChanged;
    pub const payloadIsExt = host_wreq.payloadIsExt;
    pub const sendScript = host_sem.sendScript;
    pub const sendScriptToFrame = host_sem.sendScriptToFrame;
    pub const sendScriptToFrameGen = host_sem.sendScriptToFrameGen;
    pub const sendScriptAllFrames = host_sem.sendScriptAllFrames;
    pub const pushPending = host_sem.pushPending;
    pub const takePending = host_sem.takePending;
    pub const pendingFor = host_sem.pendingFor;
    pub const freePending = host_sem.freePending;
    pub const failPending = host_sem.failPending;
    pub const semanticNavigationStarted = host_sem.semanticNavigationStarted;
    pub const semanticPump = host_sem.semanticPump;
    pub const semSnapshot = host_sem.semSnapshot;
    pub const mapDispatchView = host_sem.mapDispatchView;
    pub const innerReq = host_sem.innerReq;
    pub const semRequest = host_sem.semRequest;
    pub const semAct = host_sem.semAct;
    pub const semActGuarded = host_sem.semActGuarded;
    pub const semExpand = host_sem.semExpand;
    pub const semQuery = host_sem.semQuery;
    pub const semEval = host_sem.semEval;
    pub const sendEvalSpliced = host_sem.sendEvalSpliced;
    pub const semRead = host_sem.semRead;
    pub const semReadIds = host_sem.semReadIds;
    pub const semRearm = host_sem.semRearm;
    pub const semanticStopped = host_sem.semanticStopped;
    pub const onScriptMessage = host_sem.onScriptMessage;
    pub const onTree = host_sem.onTree;
    pub const semActAfterGuard = host_sem.semActAfterGuard;
    pub const onRect = host_sem.onRect;
    pub const onOptionRect = host_sem.onOptionRect;
    pub const rewriteNodeRefs = host_sem.rewriteNodeRefs;
    pub const onSetValue = host_sem.onSetValue;
    // -- outbound ------------------------------------------------------

    /// Resolve where an event about `view_id` goes and which id-window
    /// base to strip so the frame reads in the owner's namespace again.
    /// Null = the owning connection is gone; drop the event, exactly as
    /// a dead socket would have.
    fn routeFor(self: *Host, view_id: u32) ?RouteTo {
        const rt = self.router orelse return .{ .out = self.out, .base = 0 };
        // A synchronous answer to an observer's own request goes back
        // to that observer, under its alias: the owner never asked.
        if (self.dispatch_alias != 0 and view_id != 0) {
            if (self.aliasOf(self.dispatch_conn, self.dispatch_alias)) |sub| {
                if (sub.target == view_id) {
                    const out = rt.route(rt.ctx, sub.conn) orelse return null;
                    return .{ .out = out, .base = 0, .alias_view = aliasWire(sub) };
                }
            }
        }
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
        const owner = if (view_id >= proto.ENGINE_VIEW_BASE)
            (self.findAny(view_id) orelse return null).owner
        else
            view_id / proto.CONN_ID_WINDOW;
        const out = rt.route(rt.ctx, owner) orelse return null;
        return .{
            .out = out,
            .base = if (view_id >= proto.ENGINE_VIEW_BASE) 0 else owner * proto.CONN_ID_WINDOW,
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
                if (id != 0 and id < proto.ENGINE_VIEW_BASE) @field(v2, f) = id - base;
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

    /// `view` replaced by `id`: how a frame is re-addressed to an
    /// observer's alias.
    fn withView(value: anytype, id: u32) @TypeOf(value) {
        var v2 = value;
        if (@hasField(@TypeOf(value), "view")) v2.view = id;
        return v2;
    }

    /// Which view-keyed events an observer receives beside the owner
    /// (capability "observe"). `all`: the page's own state, what any
    /// watcher sees. `control`: answers to input, meaningful only for
    /// a driving observer. Everything else is the owner's business
    /// (decisions such as cert, permission, download and popup, the
    /// semantic and a11y streams, engine chrome) and never fans out; a
    /// controlling observer's OWN request is still answered through
    /// `routeFor`.
    fn observedEvent(comptime T: type) enum { no, all, control } {
        return switch (T) {
            proto.EvTitle,
            proto.EvNavState,
            proto.EvLoad,
            proto.EvLoadError,
            proto.EvLoadRetry,
            proto.EvCursor,
            proto.EvFavicon,
            proto.EvScroll,
            proto.EvCrashed,
            => .all,
            proto.EvContextMenu, proto.EvFindResult => .control,
            else => .no,
        };
    }

    /// Deliver `value` about the view `key` to its subscribers. The
    /// dispatching observer always gets what its own request produced
    /// (the reply shape), paused or not; everyone else by
    /// `observedEvent` and their lease.
    fn fanout(self: *Host, target: u32, value: anytype) void {
        const T = @TypeOf(value);
        if (self.subs.items.len == 0 or target == 0) return;
        if (!@hasField(T, "view")) return;
        const kind = comptime observedEvent(T);
        for (self.subs.items) |*s| {
            if (s.target != target) continue;
            const mine = self.dispatch_alias != 0 and s.conn == self.dispatch_conn and s.alias == self.dispatch_alias;
            if (!mine) {
                if (s.paused) continue;
                switch (kind) {
                    .no => continue,
                    .all => {},
                    .control => if (!s.control) continue,
                }
            }
            const out = self.observerOut(s.conn) orelse continue;
            out.post(withView(value, aliasWire(s)), null) catch {};
        }
    }

    /// Post an event, dropping it if the outbox is out of memory: a
    /// missed event must never take the helper down.
    pub fn post(self: *Host, value: anytype) void {
        const T = @TypeOf(value);
        if (comptime (@hasField(T, "view") or @hasField(T, "owner_view"))) {
            const route_key = routeKeyOf(value).?;
            // Observers first: the owner's route below may be gone
            // (its socket died) while subscribers still read.
            self.fanout(route_key, value);
            const r = self.routeFor(route_key) orelse return;
            var v2 = toClientIds(value, r.base);
            if (r.alias_view != 0) v2 = withView(v2, r.alias_view);
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

    pub fn setTitle(self: *Host, v: *View, title: []const u8) void {
        const dup = self.gpa.dupe(u8, title) catch return;
        if (v.title.len != 0) self.gpa.free(v.title);
        v.title = dup;
    }

    fn postNavState(self: *Host, v: *View) void {
        const b = v.browser;
        const can_back: u8 = if (b != null and browserInt(b, "can_go_back") != 0) 1 else 0;
        const can_fwd: u8 = if (b != null and browserInt(b, "can_go_forward") != 0) 1 else 0;
        const loading: u8 = if (b != null and browserInt(b, "is_loading") != 0) 1 else 0;
        v.nav_back = can_back != 0;
        v.nav_fwd = can_fwd != 0;
        v.nav_loading = loading != 0;
        self.post(proto.EvNavState{
            .view = v.id,
            .can_back = can_back,
            .can_fwd = can_fwd,
            .loading = loading,
            .url = v.url,
        });
    }
};

pub var g_host: ?*Host = null;

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

    /// fd 2 pointed at `/dev/null` while a test drives an engine path
    /// that deliberately prints a diagnostic.
    ///
    /// The Zig build runner re-prints ANY stderr a test binary produced
    /// under a red `failed command:` header, even for a step that
    /// SUCCEEDED, so an expected diagnostic reads as a failing test to
    /// everyone running `zig build test-web`. Silence is scoped to the
    /// one call that provokes it; a real assertion failure still prints,
    /// because the runner reports those over its own pipe.
    const StderrHush = struct {
        saved: c_int = -1,

        fn begin() StderrHush {
            const saved = c.dup(2);
            if (saved < 0) return .{};
            const devnull = c.open("/dev/null", c.O_WRONLY);
            if (devnull < 0) {
                _ = c.close(saved);
                return .{};
            }
            _ = c.dup2(devnull, 2);
            _ = c.close(devnull);
            return .{ .saved = saved };
        }

        fn end(self: StderrHush) void {
            if (self.saved < 0) return;
            _ = c.dup2(self.saved, 2);
            _ = c.close(self.saved);
        }
    };

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
    // Exhausting the retry budget is the point of this test, and the
    // engine prints a diagnostic when it happens — see StderrHush.
    {
        const hush = ViewConstructionTest.StderrHush.begin();
        defer hush.end();
        try host.createViewAtWith(ViewConstructionTest.req(52, 0), "", &spawn_ops);
    }

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

    try std.testing.expect(dev.id > proto.ENGINE_VIEW_BASE);
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

    // Fail CLOSED, instance-wide: the client is told, and no view, not
    // even an un-containered one on the global context, is ever created.
    var told = false;
    while (out.front()) |m| {
        var reader = proto.Reader.init(m.bytes);
        while (reader.next() catch null) |frame| {
            if (frame.tag == .ev_route_refused) told = true;
        }
        out.advance(m.bytes.len);
    }
    try std.testing.expect(told);
    try std.testing.expect(host.route_refusal.len != 0);
    var injected: ViewConstructionTest = .{};
    var spawn_ops = injected.ops();
    try host.createViewAtWith(ViewConstructionTest.req(9, 0), "", &spawn_ops);
    try std.testing.expectEqual(@as(usize, 0), injected.browser_calls);
    try std.testing.expectEqual(@as(usize, 0), host.viewCount());
    var reader = proto.Reader.init(out.front().?.bytes);
    const frame = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.ev_view_create_failed, frame.tag);
    const failure = try proto.decode(proto.EvViewCreateFailed, frame.payload);
    try std.testing.expectEqualStrings(host.route_refusal, failure.reason);
    // The same gate covers every other browser the instance could make
    // (revivals, popups, background pages).
    const v = try host.registerView(ViewConstructionTest.req(10, 0));
    try std.testing.expectError(error.RouteRefused, host.requireContext(v));
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
const clear_storage_js = host_cookies.clear_storage_js;
pub const CookieJob = host_cookies.CookieJob;
const CookieShadow = host_cookies.CookieShadow;
const onCanSendCookie = host_cookies.onCanSendCookie;
const onCanSaveCookie = host_cookies.onCanSaveCookie;
const onGetCookieAccessFilter = host_cookies.onGetCookieAccessFilter;

const FilterFetch = host_icpt.FilterFetch;
pub const gmXhrStart = host_icpt.gmXhrStart;
const filterSubPump = host_icpt.filterSubPump;
const filterSubTick = host_icpt.filterSubTick;
pub const filterSubShutdown = host_icpt.filterSubShutdown;
pub const filterSubBusy = host_icpt.filterSubBusy;
const filterSubAbandon = host_icpt.filterSubAbandon;
pub const JobRef = host_icpt.JobRef;
pub const jobVisit = host_icpt.jobVisit;
const interceptRegister = host_icpt.interceptRegister;
const interceptSlotFor = host_icpt.interceptSlotFor;
const interceptUnregister = host_icpt.interceptUnregister;
pub const interceptInit = host_icpt.interceptInit;
pub const interceptDeinit = host_icpt.interceptDeinit;
pub const cosmeticEnabledFor = host_icpt.cosmeticEnabledFor;
pub const cosmeticCss = host_icpt.cosmeticCss;
pub const jsonU32 = host_icpt.jsonU32;
pub const jsonBool = host_icpt.jsonBool;
pub const jsonStrField = host_icpt.jsonStrField;
pub const userfreeInto = host_icpt.userfreeInto;
const onBeforeResourceLoad = host_icpt.onBeforeResourceLoad;
const onResourceResponse = host_icpt.onResourceResponse;
const netErrorName = host_icpt.netErrorName;
const onResourceLoadComplete = host_icpt.onResourceLoadComplete;

pub const HOLD_HDR_MAX = host_wreq.HOLD_HDR_MAX;
pub const webrequestWakeFd = host_wreq.webrequestWakeFd;
pub const webrequestBusy = host_wreq.webrequestBusy;
pub const webrequestDrainWake = host_wreq.webrequestDrainWake;
pub const wreqInitPipe = host_wreq.wreqInitPipe;
pub const wreqReadTimeoutEnv = host_wreq.wreqReadTimeoutEnv;
pub const wreqTypeOf = host_wreq.wreqTypeOf;
pub const headerMapJson = host_wreq.headerMapJson;
pub const utf16Into = host_wreq.utf16Into;
pub const wreqConsider = host_wreq.wreqConsider;
pub const wreqNotifyAll = host_wreq.wreqNotifyAll;
pub const wreqAbandonExt = host_wreq.wreqAbandonExt;
pub const wreqAbandonView = host_wreq.wreqAbandonView;
pub const webrequestDeinit = host_wreq.webrequestDeinit;
const onGetResourceRequestHandler = host_wreq.onGetResourceRequestHandler;

// ---------------------------------------------------------------------
// Small CEF call helpers
// ---------------------------------------------------------------------

/// The windowless `cef_window_info_t` every browser this helper makes
/// is created with — the ordinary views AND the inspector, which is
/// exactly what makes DevTools just another view.
pub fn windowlessInfo() cef.cef_window_info_t {
    var winfo = std.mem.zeroes(cef.cef_window_info_t);
    winfo.size = @sizeOf(cef.cef_window_info_t);
    winfo.windowless_rendering_enabled = 1;
    // `external_begin_frame_enabled` stays 0: the engine paces itself
    // (see `externalPacingLatency`).
    // GPU frames. Fixed at browser creation, and only ever honoured
    // when the process got a GPU: with it set and no
    // GPU compositing available, Chromium simply keeps calling
    // `on_paint`, which is the software path this helper already has.
    // That is the whole fallback — no probe, no timeout.
    winfo.shared_texture_enabled = if (accelerated) 1 else 0;
    winfo.runtime_style = cef.CEF_RUNTIME_STYLE_ALLOY;
    return winfo;
}

pub fn windowlessSettings(v: *View) cef.cef_browser_settings_t {
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
pub fn browserInt(b: ?*cef.cef_browser_t, comptime name: []const u8) c_int {
    const br = b orelse return 0;
    const f = @field(br, name) orelse return 0;
    return f(br);
}

/// `browserInt` for the fields that live on the browser HOST, which is
/// where CEF puts the opener identifier.
///
/// The explicit type on `host` is load-bearing: the upstream and distro
/// CEF header sets translate `get_host`'s return differently ([*c] vs
/// ?*), and only the coerced form supports field access in both.
fn browserHostInt(b: ?*cef.cef_browser_t, comptime name: []const u8) c_int {
    const br = b orelse return 0;
    const get_host = br.get_host orelse return 0;
    const host: *cef.cef_browser_host_t = get_host(br) orelse return 0;
    defer release(&host.base);
    const f = @field(host, name) orelse return 0;
    return f(host);
}

/// Create a private, empty file `/tmp/sketerm-<kind>-XXXXXX` in `buf`
/// for output a client on another host fetches afterwards (a staged
/// download or print). Null when nothing could be created.
pub fn stagingFile(buf: [:0]u8, comptime kind: []const u8) ?[:0]u8 {
    const path = std.fmt.bufPrintZ(buf, "/tmp/sketerm-" ++ kind ++ "-XXXXXX", .{}) catch return null;
    const fd = c.mkstemp(path.ptr);
    if (fd < 0) return null;
    _ = c.close(fd);
    return path;
}

test "staging files are private, empty and never shared between two requests" {
    var a: [64:0]u8 = undefined;
    var b: [64:0]u8 = undefined;
    const pa = stagingFile(&a, "webpdf") orelse return error.NoStaging;
    defer _ = c.unlink(pa.ptr);
    const pb = stagingFile(&b, "webpdf") orelse return error.NoStaging;
    defer _ = c.unlink(pb.ptr);
    try std.testing.expect(std.mem.startsWith(u8, pa, "/tmp/sketerm-webpdf-"));
    try std.testing.expect(!std.mem.eql(u8, pa, pb));
    var st: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.stat(pa.ptr, &st));
    try std.testing.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode)) & 0o777);
    try std.testing.expectEqual(@as(i64, 0), @as(i64, st.st_size));
}

pub fn release(base: *cef.cef_base_ref_counted_t) void {
    if (base.release) |r| _ = r(base);
}

/// Release the reference libcef hands over with every ref-counted
/// argument of a callback (see "Reference ownership" in CLAUDE.md).
/// Null-tolerant, so an optional `[*c]` parameter goes in as is.
pub fn releaseArg(arg: anytype) void {
    if (arg == null) return;
    release(&arg.*.base);
}

pub fn setStr(utf8: []const u8, out: *cef.cef_string_t) void {
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

/// The Chromium profile preference that decides which network paths
/// WebRTC may use, and the value that keeps it inside a proxy: with
/// `disable_non_proxied_udp` WebRTC gathers no host or STUN candidate at
/// all and uses UDP only through a proxy that supports it (SOCKS5 here
/// does not), so a page cannot learn this machine's addresses through
/// ICE on a Tor or `via:` route. smoke-web's route stage proves it by
/// gathering candidates on a routed and a direct helper.
pub const WEBRTC_POLICY_PREF = "webrtc.ip_handling_policy";
pub const WEBRTC_POLICY_ROUTED = "disable_non_proxied_udp";

/// Put `rc` on this instance's route: the proxy, then the WebRTC policy
/// that keeps UDP inside it. Null on success, else why not (the caller
/// refuses the route; nothing here may be half-applied and served).
fn routeContext(rc: *cef.cef_request_context_t, proxy_url: []const u8) ?[]const u8 {
    if (!applyProxy(rc, proxy_url)) return "the engine refused the route's proxy setting";
    if (!setStringPref(rc, WEBRTC_POLICY_PREF, WEBRTC_POLICY_ROUTED))
        return "the engine refused the WebRTC policy that keeps UDP inside the route";
    return null;
}

/// `set_preference(name, <string>)` on a context's preference manager,
/// with the same consume-on-receipt rule as `applyProxy`: the value is
/// the callee's the moment it is passed, pass or fail.
fn setStringPref(rc: *cef.cef_request_context_t, name: []const u8, value: []const u8) bool {
    if (c.getenv("SKETERM_WEB_FAIL_WEBRTC_POLICY") != null) return false;
    const val: *cef.cef_value_t = cef.cef_value_create() orelse return false;
    var transferred = false;
    defer if (!transferred) release(&val.base);
    var sval = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&sval);
    setStr(value, &sval);
    if ((val.set_string orelse return false)(val, &sval) == 0) return false;
    var key = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&key);
    setStr(name, &key);
    var err = std.mem.zeroes(cef.cef_string_t);
    defer cef.cef_string_utf16_clear(&err);
    const base: *cef.cef_preference_manager_t = &rc.base;
    const set_pref = base.set_preference orelse return false;
    transferred = true;
    return set_pref(base, &key, val, &err) != 0;
}

/// Borrowed UTF-8 view of a CEF string; `free` releases it.
pub const Utf8 = struct {
    s: cef.cef_string_utf8_t,

    pub fn init(str: [*c]const cef.cef_string_t) Utf8 {
        var out = std.mem.zeroes(cef.cef_string_utf8_t);
        if (str != null and str.*.str != null) {
            _ = cef.cef_string_utf16_to_utf8(str.*.str, str.*.length, &out);
        }
        return .{ .s = out };
    }

    pub fn slice(self: *const Utf8) []const u8 {
        if (self.s.str == null) return "";
        return self.s.str[0..self.s.length];
    }

    pub fn free(self: *Utf8) void {
        cef.cef_string_utf8_clear(&self.s);
    }
};

/// The view's browser host, WITH a reference held: every caller must
/// release it (CEF's capi returns referenced pointers).
pub fn browserHost(v: *View) ?*cef.cef_browser_host_t {
    const b = v.browser orelse return null;
    const gh = b.get_host orelse return null;
    const host: ?*cef.cef_browser_host_t = gh(b);
    return host;
}

/// Run `f` against the view's browser host, releasing the reference.
pub fn withHost(v: *View, f: *const fn (*cef.cef_browser_host_t) void) void {
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    f(host);
}

/// `withHost` for the arg-taking senders below (Zig has no closures).
pub fn withHostArgs(v: *View, comptime f: anytype, args: anytype) void {
    const host = browserHost(v) orelse return;
    defer release(&host.base);
    @call(.auto, f, .{host} ++ args);
}

pub fn sendMove(host: *cef.cef_browser_host_t, ev: *const cef.cef_mouse_event_t, leave: c_int) void {
    if (host.send_mouse_move_event) |f| f(host, ev, leave);
}

pub fn sendClick(
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

pub fn setFocus(host: *cef.cef_browser_host_t, on: c_int) void {
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
pub fn typeText(v: *View, text: []const u8) void {
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
pub fn innerJson(obj: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, obj, ':') orelse return "null";
    var inner = obj[colon + 1 ..];
    if (inner.len > 0 and inner[inner.len - 1] == '}') inner = inner[0 .. inner.len - 1];
    if (inner.len == 0) return "null";
    return inner;
}

pub fn jsonStr(w: *std.Io.Writer, s: []const u8) !void {
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

pub const ext_scheme = host_webext.ext_scheme;
const ExtResource = host_webext.ExtResource;
const extSchemeCreate = host_webext.extSchemeCreate;
const extResourceOwned = host_webext.extResourceOwned;

// ---------------------------------------------------------------------
// Net-error fault injection (rig only)
// ---------------------------------------------------------------------

/// `SKETERM_WEB_FAULT_NET_CHANGED=<n>`: fail the next `n` main-frame
/// http(s) requests with `ERR_NETWORK_CHANGED` before they touch the
/// network. smoke-web proves the one-shot retry with it, because a real
/// interface change needs root and a change the test does not control
/// could land anywhere. Read on CEF's IO thread; parsed once at install.
var g_fault_net_changed: std.atomic.Value(u32) = .init(0);

fn readFaultEnv() void {
    const v = c.getenv("SKETERM_WEB_FAULT_NET_CHANGED") orelse return;
    const n = std.fmt.parseInt(u32, std.mem.span(v), 10) catch return;
    g_fault_net_changed.store(n, .release);
}

/// IO THREAD. Hand the engine our own handler for a request only while
/// a fault is armed; NULL is the default network loader.
fn onGetResourceHandler(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
) callconv(.c) [*c]cef.cef_resource_handler_t {
    defer releaseArg(browser);
    defer releaseArg(frame);
    defer releaseArg(request);
    if (g_fault_net_changed.load(.acquire) == 0) return null;
    const req: *cef.cef_request_t = request orelse return null;
    const grt = req.get_resource_type orelse return null;
    if (grt(req) != cef.RT_MAIN_FRAME) return null;
    const gu = req.get_url orelse return null;
    var url_buf: [2048]u8 = undefined;
    const url = userfreeInto(gu(req), &url_buf);
    if (!std.mem.startsWith(u8, url, "http://") and !std.mem.startsWith(u8, url, "https://")) return null;
    // Claim one fault; a concurrent request past the count loads normally.
    while (true) {
        const left = g_fault_net_changed.load(.acquire);
        if (left == 0) return null;
        if (g_fault_net_changed.cmpxchgWeak(left, left - 1, .acq_rel, .acquire) == null) break;
    }
    const h = extResourceOwned(&.{}, "text/html", 0) orelse return null;
    if (ExtResource.fromSelf(h)) |r| r.err = cef.ERR_NETWORK_CHANGED;
    return h;
}

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
    host_webext.scheme_factory = std.mem.zeroes(cef.cef_scheme_handler_factory_t);
    host_webext.scheme_factory.base = staticBase(cef.cef_scheme_handler_factory_t);
    host_webext.scheme_factory.create = extSchemeCreate;
    var name = std.mem.zeroes(cef.cef_string_t);
    setStr(ext_scheme, &name);
    defer cef.cef_string_utf16_clear(&name);
    // A null domain matches every host of a STANDARD scheme, which is
    // what we want: one factory, many extensions, dispatched on the host
    // through the origin table.
    host_webext.ext_scheme_ok = cef.cef_register_scheme_handler_factory(&name, null, &host_webext.scheme_factory) != 0;
    // The doc calls this half the TRAP (it answers 1 even for a scheme
    // Chromium refuses to register), so the debug switch has to print it
    // — it was only printing add_custom_scheme's return, which is the
    // half that is never ambiguous.
    if (c.getenv("SKETERM_WEB_SCHEME_DEBUG") != null) {
        std.debug.print("sketerm-web: register_scheme_handler_factory(" ++ ext_scheme ++ ") = {d}\n", .{@intFromBool(host_webext.ext_scheme_ok)});
    }
    if (!host_webext.ext_scheme_ok) {
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
    if (!host_webext.ext_scheme_ok) return;
    const reg = rc.register_scheme_handler_factory orelse return;
    var name = std.mem.zeroes(cef.cef_string_t);
    setStr(ext_scheme, &name);
    defer cef.cef_string_utf16_clear(&name);
    if (reg(rc, &name, null, &host_webext.scheme_factory) == 0) {
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
pub fn HeapRef(comptime Owner: type, comptime field: []const u8) type {
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
pub var client: cef.cef_client_t = undefined;
pub var accessibility_handler: cef.cef_accessibility_handler_t = undefined;
var render_handler: cef.cef_render_handler_t = undefined;
var display_handler: cef.cef_display_handler_t = undefined;
var life_span_handler: cef.cef_life_span_handler_t = undefined;
var load_handler: cef.cef_load_handler_t = undefined;
var request_handler: cef.cef_request_handler_t = undefined;
pub var resource_request_handler: cef.cef_resource_request_handler_t = undefined;
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
pub var flush_callback: cef.cef_completion_callback_t = undefined;

fn onFlushComplete(_: [*c]cef.cef_completion_callback_t) callconv(.c) void {
    const host = g_host orelse return;
    host.flushCompleted();
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
    render_handler.on_text_selection_changed = onTextSelectionChanged;
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
    life_span_handler.on_before_popup_aborted = onBeforePopupAborted;
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
    // Rig-only net-error injection; answers NULL unless a fault is armed.
    resource_request_handler.get_resource_handler = onGetResourceHandler;
    readFaultEnv();
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

    host_cookies.cookie_access_filter = std.mem.zeroes(cef.cef_cookie_access_filter_t);
    host_cookies.cookie_access_filter.base = staticBase(cef.cef_cookie_access_filter_t);
    host_cookies.cookie_access_filter.can_send_cookie = onCanSendCookie;
    host_cookies.cookie_access_filter.can_save_cookie = onCanSaveCookie;

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
pub fn presenterPointer(ctx: ?*anyopaque, view: u32, kind: presenter.PointerKind, x: i32, y: i32, button: u8, clicks: u8, mods: u32) void {
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

pub fn presenterScroll(ctx: ?*anyopaque, view: u32, x: i32, y: i32, dx: i32, dy: i32, mods: u32) void {
    const host: *Host = @ptrCast(@alignCast(ctx orelse return));
    host.scroll(.{ .view = view, .x = x, .y = y, .dx = dx, .dy = dy, .mods = mods });
}

pub fn presenterKey(ctx: ?*anyopaque, view: u32, keysym: u32, keycode: u32, mods: u32, pressed: bool) void {
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

pub fn viewOf(browser: [*c]cef.cef_browser_t) ?*View {
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
pub fn viewPoint(v: *const View, x: i32, y: i32) struct { x: c_int, y: c_int } {
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

const getAccessibilityHandler = host_a11y.getAccessibilityHandler;
pub const applyA11yState = host_a11y.applyA11yState;
const onAxTreeChange = host_a11y.onAxTreeChange;
const onAxLocationChange = host_a11y.onAxLocationChange;

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

/// The engine's selection push. This is the ONLY way to learn the
/// page's selected text through CEF's C API — there is no getter, and
/// no clipboard call to read it back out of — so the copy verbs are
/// answered from what this last stored. Injecting JS to read the
/// selection would be the alternative and it fails on cross-origin
/// frames and on password-ish inputs; this does not.
fn onTextSelectionChanged(
    _: [*c]cef.cef_render_handler_t,
    browser: [*c]cef.cef_browser_t,
    selected_text: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_range_t,
) callconv(.c) void {
    defer releaseArg(browser);
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var s = Utf8.init(selected_text);
    defer s.free();
    const text = s.slice();
    // Keep the old selection on an allocation failure rather than
    // silently reporting an empty one to the next copy.
    const dup = host.gpa.dupe(u8, text) catch return;
    if (v.sel_text.len != 0) host.gpa.free(v.sel_text);
    v.sel_text = dup;
}

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
    host.observeDamage(v, list[0..n]);
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
    host.setTitle(v, s.slice());
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
    popup_id: c_int,
    target_url: [*c]const cef.cef_string_t,
    target_frame_name: [*c]const cef.cef_string_t,
    disposition: cef.cef_window_open_disposition_t,
    user_gesture: c_int,
    popup_features: [*c]const cef.cef_popup_features_t,
    window_info: [*c]cef.cef_window_info_t,
    _: [*c][*c]cef.cef_client_t,
    // Left untouched on purpose: the header defaults `settings` to the
    // SOURCE browser's, which already carries the opaque background
    // colour and the frame-rate cap `windowlessSettings` set. Writing
    // the whole struct would clobber both and leak its cef_string_t.
    _: [*c]cef.cef_browser_settings_t,
    _: [*c][*c]cef.cef_dictionary_value_t,
    // `no_javascript_access` stays as the engine set it: forcing it
    // would sever the very opener relationship this exists to keep.
    _: [*c]c_int,
) callconv(.c) c_int {
    defer releaseArg(browser);
    defer releaseArg(frame);
    const host = g_host orelse return 1;
    const v = viewOf(browser) orelse return 1;
    var s = Utf8.init(target_url);
    defer s.free();
    var fname = Utf8.init(target_frame_name);
    defer fname.free();
    // "Special case error condition from the renderer" — there is no
    // popup to open and nothing to tell the client about.
    if (disposition == cef.CEF_WOD_IGNORE_ACTION) return 1;
    const d: proto.Disposition = switch (disposition) {
        cef.CEF_WOD_NEW_WINDOW => .new_window,
        cef.CEF_WOD_NEW_POPUP, cef.CEF_WOD_NEW_PICTURE_IN_PICTURE => .popup,
        else => .new_tab,
    };
    const allow = v.popup_allow orelse host.popup_default;
    if (allow) {
        if (host.openPopupFor(v, popup_id, window_info, popup_features, d, user_gesture, s.slice(), fname.slice()))
            return 0;
        // Falling through means the popup could not be prepared; the
        // block path below still gives the client a usable answer.
    }
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

/// A popup CEF allowed and never created. The header names this as one
/// of the three places pending-popup state must be cleared; without it
/// a failed creation leaks a View and its frame buffer forever.
fn onBeforePopupAborted(
    _: [*c]cef.cef_life_span_handler_t,
    browser: [*c]cef.cef_browser_t,
    popup_id: c_int,
) callconv(.c) void {
    defer releaseArg(browser);
    const host = g_host orelse return;
    const opener = viewOf(browser);
    const opener_cef = if (opener) |o| o.cef_id else 0;
    if (host.takePendingPopup(popup_id, opener_cef)) |pv| host.destroyView(pv.id);
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
    // `findCef`, NOT `viewOf`: `destroyView` swapRemoves the record
    // before `dropBrowser` closes the browser, and close is
    // asynchronous, so on the client-initiated path `viewOf`'s
    // `pending orelse adopting` fallback would hand back a LIVE
    // unrelated view and we would close the wrong tab.
    const v = host.findCef(browserInt(browser, "get_identifier")) orelse return;
    if (v.webext_popup and v.browser != null) host.popupClosedByEngine(v.id);
    if (v.page_popup and v.browser != null) host.pagePopupClosedByEngine(v);
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
    // BEFORE the `pending` branch: `pending` stays live for the whole
    // of `create_browser_sync`, which pumps CEF inside its retry loop,
    // so a popup arriving then would be claimed by the pending view,
    // stamp the wrong cef id and orphan a browser — and an orphan
    // browser hangs `cef_shutdown`.
    // Only a browser we ARMED is ours: CEF reports the DevTools window
    // as a popup as well, and swallowing that one left `devtools_show`
    // waiting for an inspector that was already open.
    if (browserInt(b, "is_popup") != 0 and host.claimPopupBrowser(b)) {
        adopted = true;
        return;
    }
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
    // made on its own schedule: a page popup we allowed, or the
    // inspector `devtools_show` asked for.
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
    v.nav_back = can_back != 0;
    v.nav_fwd = can_fwd != 0;
    v.nav_loading = is_loading != 0;
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
    if (main) {
        v.exec_nav_pending = false;
        host.flushExecAtStart(v, f);
    }
    host.injectMatchingExtensions(v, f, .document_start);
    // CEF reports a document only once it COMMITS, so the two events
    // arrive together here (onBeforeNavigate cannot fire earlier: the
    // request path runs on the IO thread with no script to run).
    host.webNavEvent(v, f, "onBeforeNavigate", "", "");
    host.webNavEvent(v, f, "onCommitted", "", "\"transitionType\":\"link\",\"transitionQualifiers\":[]");
    if (!main) return;
    v.load_retry.loadStarted();
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
    if (!v.webext_popup) {
        // Load end is the one moment the engine names; DOMContentLoaded
        // has already happened by then, so both are reported, in order.
        host.webNavEvent(v, f, "onDOMContentLoaded", "", "");
        host.webNavEvent(v, f, "onCompleted", "", "");
    }
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
    {
        var ebuf: [96]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        var ew = std.Io.Writer.fixed(&ebuf);
        ew.writeAll("\"error\":") catch {};
        jsonStr(&ew, netErrorName(&name_buf, @intCast(code))) catch {};
        host.webNavEvent(v, frame, "onErrorOccurred", url.slice(), ebuf[0..ew.end]);
    }
    if (code != cef.ERR_ABORTED) {
        // The document the queued document_start scripts were for is
        // not coming; their Promises expire through the reply deadline.
        v.exec_nav_pending = false;
        for (v.exec_at_start.items) |js| host.gpa.free(js);
        v.exec_at_start.clearRetainingCapacity();
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
    // The local network stack blinked (an interface came or went) and
    // Chromium abandoned the navigation: nothing about the request or
    // the site was wrong, so load it again, once. The client hears the
    // retry, never a failure it would have to retry itself. Calling
    // `load_url` from inside this callback is the documented CEF shape
    // (its own error-page sample does exactly that).
    if (loadretry.retryable(@intCast(code)) and v.load_retry.arm()) {
        host.post(proto.EvLoadRetry{
            .view = v.id,
            .code = @intCast(code),
            .url = url.slice(),
            .msg = msg.slice(),
        });
        host.semanticNavigationStarted(v);
        v.sem_nav.waiting_load_start = true;
        host.loadUrl(v, url.slice());
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

const resolveCert = host_sec.resolveCert;
const resolvePerm = host_sec.resolvePerm;
const onCertificateError = host_sec.onCertificateError;
const onShowPermissionPrompt = host_sec.onShowPermissionPrompt;
const onRequestMediaAccess = host_sec.onRequestMediaAccess;
const onDismissPermissionPrompt = host_sec.onDismissPermissionPrompt;

const onCanDownload = host_dl.onCanDownload;
const onBeforeDownload = host_dl.onBeforeDownload;
const onDownloadUpdated = host_dl.onDownloadUpdated;

pub fn isMainFrame(frame: [*c]cef.cef_frame_t) bool {
    if (frame == null) return false;
    const f = frame.*.is_main orelse return false;
    return f(frame) != 0;
}

/// The WebExtension `frameId` of a frame: 0 for the main frame (the
/// spec's fixed value), otherwise a stable positive number derived from
/// the engine's opaque frame identifier string.
pub fn frameIdOf(frame: *cef.cef_frame_t) i64 {
    if (isMainFrame(frame)) return 0;
    const gi = frame.get_identifier orelse return 1;
    var buf: [128]u8 = undefined;
    const ident = userfreeInto(gi(frame), &buf);
    const h: u32 = std.hash.Fnv1a_32.hash(ident) & 0x7fff_ffff;
    return if (h == 0) 1 else h;
}

/// -1 for the main frame, else the parent's `frameIdOf`.
pub fn parentFrameIdOf(frame: *cef.cef_frame_t) i64 {
    if (isMainFrame(frame)) return -1;
    const gp = frame.get_parent orelse return 0;
    const parent: *cef.cef_frame_t = gp(frame) orelse return 0;
    defer release(&parent.base);
    return frameIdOf(parent);
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
pub fn runJs(frame: *cef.cef_frame_t, code: []const u8) void {
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

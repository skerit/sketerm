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
const cef = @import("cef");
const c = @import("cbindings");
const proto = @import("protocol.zig");
const keymap = @import("keymap.zig");
const semantic = @import("semantic.zig");
const filter = @import("filter.zig");

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
    hexInto(raw[0..16], &sem_secret.nonce);
    hexInto(raw[16..32], &sem_secret.slot);
    sem_secret.ok = true;
}

fn hexInto(raw: []const u8, out: []u8) void {
    const digits = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 0xf];
    }
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
}

/// memfd_create hides behind _GNU_SOURCE, which translate-c does not
/// define — declared here, resolved at link (Linux-only helper).
extern fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
const MFD_CLOEXEC: c_uint = 1;

/// Cap on damage rects forwarded per paint; beyond it a single
/// full-view rect is cheaper than the bookkeeping.
///
/// Raising it to 128 was MEASURED to change nothing for a scrolling page
/// at 3840x2160 (1.14 GB/s either way): Chromium reports full-viewport
/// damage there, it is not the cap collapsing a long list.
const max_rects = 32;

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
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    const ms = @as(f64, @floatFromInt(ts.tv_sec)) * 1000.0 + @as(f64, @floatFromInt(ts.tv_nsec)) / 1e6;
    std.debug.print("hostlat: {s} {d:.2}\n", .{ tag, ms });
}

/// Monotonic milliseconds (`std.time.milliTimestamp` is gone in 0.16).
pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(@as(i64, ts.tv_nsec), 1_000_000);
}

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

    /// The client asked for accessibility streaming (`a11y_enable`).
    /// Survives a discard: the revived browser re-enables engine-side
    /// accessibility in `spawnBrowser`.
    a11y: bool = false,
    /// The engine's tree-id token this view's AX stream was last
    /// attributed by (owned). The accessibility callbacks carry NO
    /// browser pointer — only this token — so it is the join key; see
    /// `axResolveView` for how it gets (re)bound.
    ax_tree: []u8 = &.{},

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
    /// Detail level of the last request, replayed after a navigation.
    sem_detail: u8 = 1,
    sem_next_req: u32 = 1,
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

    const PoolEntry = struct { ino: u64 = 0, id: u32 = 0, seen: u64 = 0 };

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
    sid: u32 = 0,
    mode: u8 = 0,
    detail: u8 = 0,
    scope: u32 = 0,
    /// Owned copy of a `sem_act` argument (the text to type).
    arg: []u8 = &.{},
    off: u32 = 0,

    const Kind = enum {
        snapshot,
        /// A `sem_query` of kind `visible` (link hints): answered from
        /// the live tree AFTER the fresh walk this request solicits,
        /// because scrolling moves every rect without one DOM mutation.
        /// `arg` holds the "<vw> <vh>" viewport string.
        hints,
        click,
        hover,
        act,
        set_value,
        commit,
        expand,
        read,
        eval,
        /// A custom dropdown was clicked open; waiting for the option's
        /// rect so the pick itself can be a trusted click too.
        choose_pick,
        /// The option was clicked; waiting for what the control reads
        /// as now.
        choose_done,
    };
};

// ---------------------------------------------------------------------
// Host
// ---------------------------------------------------------------------

/// The browser fleet plus its outbound protocol queue.
///
/// A single instance per process, reachable from the C callbacks
/// through `g_host` — CEF handlers take no user-data pointer, and the
/// single-threaded loop makes a global sound here.
pub const Host = struct {
    gpa: std.mem.Allocator,
    out: *proto.Outbox,
    views: std.ArrayList(*View) = .empty,
    /// The view a create_browser_sync call is currently building, for
    /// the callbacks CEF fires BEFORE it returns the browser pointer.
    pending: ?*View = null,
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

    pub fn init(gpa: std.mem.Allocator, out: *proto.Outbox) Host {
        return .{ .gpa = gpa, .out = out };
    }

    pub fn deinit(self: *Host) void {
        self.destroyAll();
        self.views.deinit(self.gpa);
        for (self.prints.items) |p| self.gpa.free(p.path);
        self.prints.deinit(self.gpa);
        // destroyAll's dropBrowser sweep already cancelled and freed
        // per-view entries; whatever is left never named a live view.
        for (self.downloads.items) |*d| d.releaseCbs();
        self.downloads.deinit(self.gpa);
        if (g_host == self) g_host = null;
    }

    /// Publish this host to the CEF callbacks and build the handler set.
    pub fn install(self: *Host) void {
        g_host = self;
        installHandlers();
    }

    pub fn find(self: *Host, id: u32) ?*View {
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
        if (req.view == 0 or self.find(req.view) != null) return;
        const v = try self.gpa.create(View);
        errdefer self.gpa.destroy(v);
        const scale: u16 = if (req.scale_x1000 == 0) 1000 else req.scale_x1000;
        const lw = @max(req.w, 1);
        const lh = @max(req.h, 1);
        v.* = .{
            .id = req.view,
            .w = lw,
            .h = lh,
            .scale_x1000 = scale,
            .pw = physicalOf(lw, scale),
            .ph = physicalOf(lh, scale),
            .sem = semantic.View.init(self.gpa),
        };
        try self.views.append(self.gpa, v);
        errdefer _ = self.views.pop();
        return self.spawnBrowser(v, initial_url);
    }

    /// Give an EXISTING view record a windowless browser at
    /// `initial_url`, plus the frame buffer that makes it visible.
    ///
    /// Both the first creation and a post-discard revival come through
    /// here, which is what makes a revived view identical to a fresh one
    /// in everything but its id: same window info, same per-browser
    /// opaque background, same zoom-carried scale, same buffer
    /// announcement. A failure destroys the view rather than leaving a
    /// record nothing can render.
    fn spawnBrowser(self: *Host, v: *View, initial_url: []const u8) !void {
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
            null,
        );
        if (browser == null) return error.BrowserCreateFailed;
        v.browser = browser;
        v.cef_id = browserInt(browser, "get_identifier");
        interceptRegister(self.gpa, v.id, v.cef_id);
        applyZoom(v);
        // A revived (or freshly created) browser knows nothing of the
        // client's earlier `a11y_enable`; re-apply it.
        if (v.a11y) applyA11yState(v);
        // A view without a frame buffer is invisible and unfixable, so
        // the whole view goes rather than leaving a stranded browser.
        self.allocBuffer(v) catch |e| {
            self.destroyView(v.id);
            return e;
        };
    }

    pub fn destroyView(self: *Host, id: u32) void {
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
            self.freeView(v);
            if (inspector != 0) self.destroyView(inspector);
            return;
        }
    }

    pub fn destroyAll(self: *Host) void {
        self.adopting = null;
        while (self.views.pop()) |v| self.freeView(v);
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
        if (!v.discarded) return;
        // `spawnBrowser` can reach `setUrl` through an address-change
        // callback fired inside create_browser_sync, which would free
        // the very slice it is loading; the copy costs one url.
        const url = self.gpa.dupe(u8, v.url) catch return;
        defer self.gpa.free(url);
        self.reviveAt(v, url);
    }

    /// Revive a discarded view AT `url` — the same single document a
    /// fresh `view_create_url` produces, which is why a navigation into
    /// a discarded view does not first load the address it had.
    fn reviveAt(self: *Host, v: *View, url: []const u8) void {
        const id = v.id;
        v.discarded = false;
        v.hidden = false;
        self.spawnBrowser(v, url) catch {
            // A hard failure destroys the view outright (spawnBrowser
            // will not strand a record with no buffer); if it is still
            // here, it stays discarded rather than pretending.
            if (self.find(id) != null) v.discarded = true;
        };
    }

    /// The view a SHOW/navigation/input frame names, revived first if it
    /// was discarded — those frames are exactly the ones that mean
    /// "somebody is using this page again". Null when the id is unknown
    /// or the revival failed, which every caller treats as "ignore".
    fn findWake(self: *Host, id: u32) ?*View {
        const v = self.find(id) orelse return null;
        if (v.discarded) self.reviveView(v);
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

        self.next_devtools +%= 1;
        if (self.next_devtools < proto.DEVTOOLS_VIEW_BASE) self.next_devtools = proto.DEVTOOLS_VIEW_BASE + 1;
        const v = try self.gpa.create(View);
        errdefer self.gpa.destroy(v);
        v.* = .{
            .id = self.next_devtools,
            // The client resizes it the moment its surface is laid out;
            // this is only what the first layout happens at.
            .w = src.w,
            .h = src.h,
            .scale_x1000 = src.scale_x1000,
            .pw = physicalOf(src.w, src.scale_x1000),
            .ph = physicalOf(src.h, src.scale_x1000),
            .devtools_of = src.id,
            .sem = semantic.View.init(self.gpa),
        };
        try self.views.append(self.gpa, v);
        errdefer _ = self.views.pop();
        src.devtools_view = v.id;

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
        // `on_after_created`'s browser is BORROWED; every other browser
        // pointer this file keeps comes from create_browser_sync with a
        // reference held, and `freeView` releases one either way.
        if (browser.base.add_ref) |ar| ar(&browser.base);
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

    /// Tear down a view's browser and everything that belonged to its
    /// document, leaving the record itself untouched. Shared by
    /// `freeViewOpts` (which then frees the record) and `discardView`
    /// (which keeps it). `close` is false exactly once — an inspector
    /// CEF insisted on giving its own OS window, where closing would
    /// take the user's DevTools away rather than clean up after it.
    fn dropBrowser(self: *Host, v: *View, close: bool) void {
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
        for (v.pending.items) |p| {
            if (p.arg.len != 0) self.gpa.free(p.arg);
        }
        v.pending.clearRetainingCapacity();
        // The shadow tree described a document that no longer exists;
        // its ids must not be answerable after this.
        v.sem.deinit();
        v.sem = semantic.View.init(self.gpa);
        v.sem_observing = false;
        // The AX tree token named a document of the dead browser; a
        // revived one mints fresh ids and rebinds via `axResolveView`.
        if (v.ax_tree.len != 0) {
            self.gpa.free(v.ax_tree);
            v.ax_tree = &.{};
        }
    }

    fn freeView(self: *Host, v: *View) void {
        self.freeViewOpts(v, true);
    }

    /// `close`: whether the browser goes down with the view — false
    /// exactly once, for the windowed inspector (see `dropBrowser`).
    fn freeViewOpts(self: *Host, v: *View, close: bool) void {
        // Frees the browser, the mapping, every pending request's arg
        // and the shadow tree; what is left is the record's own memory.
        interceptUnregister(self.gpa, v.id);
        self.dropBrowser(v, close);
        if (v.url.len != 0) self.gpa.free(v.url);
        v.pending.deinit(self.gpa);
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
        if (v.map.len != 0) {
            _ = c.munmap(v.map.ptr, v.map.len);
            v.map = &.{};
        }
        const size: usize = v.stride() * @as(usize, v.ph);
        const fd = memfd_create("sketerm-web-view", MFD_CLOEXEC);
        if (fd < 0) return error.MemfdFailed;
        var keep_fd = false;
        defer if (!keep_fd) {
            _ = c.close(fd);
        };
        if (c.ftruncate(fd, @intCast(size)) != 0) return error.FtruncateFailed;
        const addr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (addr == c.MAP_FAILED) return error.MmapFailed;
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
        v.map = bytes[0..size];
        @memset(v.map, 0);
        v.buf_unpainted = true;
        v.buf_id +%= 1;
        if (v.buf_id == 0) v.buf_id = 1;
        try self.out.post(proto.FrameBuffer{
            .view = v.id,
            .buf_id = v.buf_id,
            .w = v.pw,
            .h = v.ph,
            .stride = v.stride(),
        }, fd);
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
        _ = self;
        g_int.acquire();
        defer g_int.release();
        if (req.view == 0) {
            g_int.global_enabled = req.enabled != 0;
            for (&g_int.slots) |*s| {
                if (s.used) s.dirty = true;
            }
            return;
        }
        for (&g_int.slots) |*s| {
            if (s.used and s.view_id == req.view) {
                s.enabled = req.enabled != 0;
                s.dirty = true;
                return;
            }
        }
    }

    /// Reload the filter set from the seed list, the config filters
    /// dir, and any extra paths named. No network fetching.
    pub fn interceptLists(self: *Host, req: proto.InterceptLists) void {
        interceptReload(self.gpa, req.paths);
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
            .back => if (b.go_back) |f| f(b),
            .forward => if (b.go_forward) |f| f(b),
            .reload => if (b.reload) |f| f(b),
            .stop => if (b.stop_load) |f| f(b),
            .reload_no_cache => if (b.reload_ignore_cache) |f| f(b),
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
        if (!want and v.ax_tree.len != 0) {
            self.gpa.free(v.ax_tree);
            v.ax_tree = &.{};
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
        var code: std.Io.Writer.Allocating = .init(self.gpa);
        defer code.deinit();
        const slot: []const u8 = &sem_secret.slot;
        code.writer.print("window[\"{s}\"]&&window[\"{s}\"](", .{ slot, slot }) catch return;
        jsonStr(&code.writer, json) catch return;
        code.writer.writeByte(')') catch return;
        runJs(frame, code.written());
    }

    /// Queue a request; the oldest is dropped when a page stops
    /// answering, so a dead script cannot grow the list without bound.
    fn pushPending(self: *Host, v: *View, p: Pending) !u32 {
        if (v.pending.items.len >= 32) {
            const old = v.pending.orderedRemove(0);
            if (old.arg.len != 0) self.gpa.free(old.arg);
        }
        try v.pending.append(self.gpa, p);
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

    fn nextReq(v: *View) u32 {
        const r = v.sem_next_req;
        v.sem_next_req +%= 1;
        if (v.sem_next_req == 0) v.sem_next_req = 1;
        return r;
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
        const rid = try self.pushPending(v, .{
            .req = nextReq(v),
            .kind = .snapshot,
            .mode = req.mode,
            .detail = req.detail,
            .scope = req.scope,
        });
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

    pub fn semAct(self: *Host, req: proto.SemAction) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = discarded_msg });
            return;
        }
        const eid = v.sem.eidFor(req.id);
        if (eid == 0) {
            self.post(proto.SemActResult{ .view = v.id, .id = req.id, .ok = 0, .msg = "unknown id" });
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
        if (req.kind == @intFromEnum(proto.SemQuery.visible)) {
            const arg = try self.gpa.dupe(u8, req.arg);
            errdefer self.gpa.free(arg);
            const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .hints, .arg = arg });
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
        const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .eval });
        var cmd: std.Io.Writer.Allocating = .init(self.gpa);
        defer cmd.deinit();
        cmd.writer.print("{{\"op\":\"eval\",\"req\":{d},\"await\":{s},\"timeout\":{d},\"code\":", .{
            rid,
            if (req.flags & proto.eval_flag_await != 0) "true" else "false",
            @min(req.timeout_ms, 120_000),
        }) catch return;
        jsonStr(&cmd.writer, req.code.s) catch return;
        cmd.writer.writeByte('}') catch return;
        self.sendScript(v, cmd.written());
    }

    pub fn semRead(self: *Host, req: proto.SemRead) !void {
        const v = self.find(req.view) orelse return;
        if (v.discarded) {
            self.post(proto.SemReadResult{ .view = v.id, .markdown = .{ .s = discarded_msg } });
            return;
        }
        const rid = try self.pushPending(v, .{ .req = nextReq(v), .kind = .read });
        var buf: [64]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"read\",\"req\":{d}}}", .{rid}) catch return;
        self.sendScript(v, cmd);
    }

    /// Re-arm a fresh document: a navigation builds a new V8 context,
    /// so the observer and the first walk have to be asked for again.
    ///
    /// A snapshot REQUEST sent into the dying context would never be
    /// answered (its walk dies with the context), so pending snapshot
    /// requests are re-issued here with their original ids — without
    /// this, a client that snapshots right after navigating times out.
    fn semRearm(self: *Host, v: *View) void {
        if (!v.sem_observing) return;
        self.sendScript(v, "{\"op\":\"observe\",\"on\":true}");
        var buf: [96]u8 = undefined;
        var resent = false;
        for (v.pending.items) |p| {
            // Hints ride the same walk op, so they are re-solicited the
            // same way (their detail is the view's current level).
            if (p.kind != .snapshot and p.kind != .hints) continue;
            const cmd = std.fmt.bufPrint(
                &buf,
                "{{\"op\":\"snapshot\",\"req\":{d},\"detail\":{d}}}",
                .{ p.req, if (p.kind == .snapshot) p.detail else v.sem_detail },
            ) catch continue;
            self.sendScript(v, cmd);
            resent = true;
        }
        if (resent) return;
        // No request in flight: an unsolicited walk keeps the live tree
        // (queries, action routing) following the navigation.
        const cmd = std.fmt.bufPrint(
            &buf,
            "{{\"op\":\"snapshot\",\"req\":0,\"detail\":{d}}}",
            .{v.sem_detail},
        ) catch return;
        self.sendScript(v, cmd);
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
        const Head = struct { op: []const u8 = "", req: u32 = 0 };
        const head = std.json.parseFromSlice(Head, self.gpa, json, .{
            .ignore_unknown_fields = true,
        }) catch return;
        defer head.deinit();
        const op = head.value.op;
        const rid = head.value.req;

        if (std.mem.eql(u8, op, "tree")) {
            self.onTree(v, rid, json);
            return;
        }
        var p = self.takePending(v, rid) orelse return;
        defer if (p.arg.len != 0) self.gpa.free(p.arg);

        if (std.mem.eql(u8, op, "rect")) {
            self.onRect(v, &p, json);
        } else if (std.mem.eql(u8, op, "optrect")) {
            self.onOptionRect(v, &p, json);
        } else if (std.mem.eql(u8, op, "eval")) {
            const E = struct { ok: u8 = 0, json: []const u8 = "" };
            const e = std.json.parseFromSlice(E, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
            defer e.deinit();
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
            const Ack = struct { ok: u8 = 0, msg: []const u8 = "" };
            const a = std.json.parseFromSlice(Ack, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
            defer a.deinit();
            var buf: [512]u8 = undefined;
            const msg = switch (p.kind) {
                .commit => std.fmt.bufPrint(&buf, "set-value ok, value=\"{s}\"", .{
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
        defer if (pend) |p| {
            if (p.arg.len != 0) self.gpa.free(p.arg);
        };
        const parsed = semantic.parseTree(self.gpa, json) catch return;
        defer parsed.deinit();
        v.sem.apply(parsed.value) catch return;
        const p = pend orelse return;

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
            // A scoped snapshot is a peek at one subtree: rendered in
            // full, and deliberately NOT consuming the base (the caller
            // did not see the rest of the page).
            const scoped = v.sem.renderScoped(p.scope) catch return;
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

    /// The script located an element: the click or hover is synthesized
    /// HERE, through the same input path a human uses, which is the
    /// whole reason `element.click()` is not an option.
    fn onRect(self: *Host, v: *View, p: *Pending, json: []const u8) void {
        const R = struct { ok: u8 = 0, x: i32 = 0, y: i32 = 0, w: i32 = 0, h: i32 = 0 };
        const r = std.json.parseFromSlice(R, self.gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        defer r.deinit();
        if (r.value.ok == 0) {
            self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 0, .msg = "element has no box" });
            return;
        }
        const pt = viewPoint(v, r.value.x, r.value.y);
        var ev = cef.cef_mouse_event_t{ .x = pt.x, .y = pt.y, .modifiers = 0 };
        withHostArgs(v, sendMove, .{ &ev, @as(c_int, 0) });
        var buf: [128]u8 = undefined;
        if (p.kind == .hover) {
            const msg = std.fmt.bufPrint(&buf, "hover at {d},{d}", .{ r.value.x, r.value.y }) catch "hover";
            self.post(proto.SemActResult{ .view = v.id, .id = p.sid, .ok = 1, .msg = msg });
            return;
        }
        withHostArgs(v, setFocus, .{@as(c_int, 1)});
        withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 0), @as(c_int, 1) });
        withHostArgs(v, sendClick, .{ &ev, cef.MBT_LEFT, @as(c_int, 1), @as(c_int, 1) });
        const msg = std.fmt.bufPrint(&buf, "click at {d},{d}", .{ r.value.x, r.value.y }) catch "click";
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
        const rid = self.pushPending(v, .{ .req = nextReq(v), .kind = .commit, .sid = p.sid }) catch return;
        var buf: [128]u8 = undefined;
        const cmd = std.fmt.bufPrint(&buf, "{{\"op\":\"commit\",\"req\":{d},\"eid\":{d}}}", .{ rid, eid }) catch return;
        self.sendScript(v, cmd);
    }

    // -- outbound ------------------------------------------------------

    /// Post an event, dropping it if the outbox is out of memory: a
    /// missed event must never take the helper down.
    fn post(self: *Host, value: anytype) void {
        self.out.post(value, null) catch {};
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
        if (self.out.pending() >= max_frame_backlog) {
            for (fds) |fd| _ = c.close(fd);
            return;
        }
        self.out.postFds(value, fds) catch {
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
/// gets verdicts (global engine + global enable), just no log/badge.
const MAX_ISLOTS = 32;

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
};

const Intercept = struct {
    lock: std.atomic.Value(u8) = .init(0),
    engine: ?*filter.Engine = null,
    global_enabled: bool = true,
    rules: u32 = 0,
    slots: [MAX_ISLOTS]ISlot = @splat(.{}),

    fn acquire(self: *Intercept) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *Intercept) void {
        self.lock.store(0, .release);
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
            s.cef_id = cef_id;
            return;
        }
        if (!s.used and free_slot == null) free_slot = s;
    }
    const s = free_slot orelse return;
    s.* = .{ .used = true, .cef_id = cef_id, .view_id = view_id, .ring = ring };
    keep = true;
}

fn interceptUnregister(gpa: std.mem.Allocator, view_id: u32) void {
    var ring: ?*[NLOG]LogEntry = null;
    {
        g_int.acquire();
        defer g_int.release();
        for (&g_int.slots) |*s| {
            if (!s.used or s.view_id != view_id) continue;
            ring = s.ring;
            s.* = .{};
            break;
        }
    }
    // Freed OUTSIDE the lock: nobody can reach it any more, and the IO
    // thread re-resolves its slot on every callback.
    if (ring) |r| gpa.destroy(r);
}

/// Read one file whole (bounded); caller frees.
fn readFileBounded(gpa: std.mem.Allocator, path: [*:0]const u8, max: usize) ?[]u8 {
    const f = c.fopen(path, "rb") orelse return null;
    defer _ = c.fclose(f);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        list.appendSlice(gpa, buf[0..n]) catch {
            list.deinit(gpa);
            return null;
        };
        if (list.items.len > max) break;
    }
    return list.toOwnedSlice(gpa) catch {
        list.deinit(gpa);
        return null;
    };
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
fn interceptReload(gpa: std.mem.Allocator, extra_paths: []const []const u8) void {
    const eng = gpa.create(filter.Engine) catch return;
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
                defer gpa.free(text);
                eng.addList(text) catch {};
            }
        }
    }
    for (extra_paths) |path| {
        var path_buf: [4352:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch continue;
        const text = readFileBounded(gpa, p.ptr, 16 * 1024 * 1024) orelse continue;
        defer gpa.free(text);
        eng.addList(text) catch {};
    }
    if (!ok) {
        eng.deinit();
        gpa.destroy(eng);
        return;
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
    if (old) |o| {
        o.deinit();
        gpa.destroy(o);
    }
}

/// Load the initial filter set (seed + config dir). Called once at
/// helper startup, before any view exists.
pub fn interceptInit(gpa: std.mem.Allocator) void {
    interceptReload(gpa, &.{});
}

/// Free the engine and any leftover rings (client gone, views already
/// destroyed).
pub fn interceptDeinit(gpa: std.mem.Allocator) void {
    var old: ?*filter.Engine = null;
    {
        g_int.acquire();
        defer g_int.release();
        old = g_int.engine;
        g_int.engine = null;
        g_int.rules = 0;
        for (&g_int.slots) |*s| {
            if (s.used) {
                if (s.ring) |r| gpa.destroy(r);
                s.* = .{};
            }
        }
    }
    if (old) |o| {
        o.deinit();
        gpa.destroy(o);
    }
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
    _: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    _: [*c]cef.cef_callback_t,
) callconv(.c) cef.cef_return_value_t {
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
    {
        g_int.acquire();
        defer g_int.release();
        var slot: ?*ISlot = null;
        for (&g_int.slots) |*s| {
            if (s.used and s.cef_id == cef_id) {
                slot = s;
                break;
            }
        }
        const enabled = g_int.global_enabled and (if (slot) |s| s.enabled else true);
        if (enabled and host.len > 0) {
            if (g_int.engine) |eng| {
                verdict = eng.match(.{ .url = url, .host = host, .doc_host = doc_host, .rtype = rtype });
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
    return if (verdict) cef.RV_CANCEL else cef.RV_CONTINUE;
}

/// IO THREAD. Completes a logged entry with status/size/timing.
fn onResourceLoadComplete(
    _: [*c]cef.cef_resource_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: [*c]cef.cef_frame_t,
    request: [*c]cef.cef_request_t,
    response: [*c]cef.cef_response_t,
    _: cef.cef_urlrequest_status_t,
    received: i64,
) callconv(.c) void {
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

fn onGetResourceRequestHandler(
    _: [*c]cef.cef_request_handler_t,
    _: [*c]cef.cef_browser_t,
    _: [*c]cef.cef_frame_t,
    _: [*c]cef.cef_request_t,
    _: c_int,
    _: c_int,
    _: [*c]const cef.cef_string_t,
    _: [*c]c_int,
) callconv(.c) [*c]cef.cef_resource_request_handler_t {
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

fn setStr(utf8: []const u8, out: *cef.cef_string_t) void {
    _ = cef.cef_string_utf8_to_utf16(utf8.ptr, utf8.len, out);
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
    resource_request_handler.on_before_resource_load = onBeforeResourceLoad;
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
    // Subframes are injected but idle: only the main frame's walk maps
    // onto a view's shadow tree (iframe traversal is a later feature).
    if (!isMainFrame(frame)) return 0;
    const host = g_host orelse return 0;
    const v = viewOf(browser) orelse return 0;
    var payload = semPayload(message) orelse return 0;
    defer payload.free();
    host.onScriptMessage(v, payload.slice());
    return 1;
}

/// Resolve the view a callback's browser belongs to. During
/// create_browser_sync the browser is not registered yet, so the
/// in-flight view answers instead — and likewise for the inspector
/// browser CEF builds asynchronously, whose `get_view_rect` is asked
/// before `on_after_created` ever runs.
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

fn axDump(label: []const u8, value: [*c]cef.cef_value_t) void {
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
    if (dDict(upd, "tree_data")) |td| {
        defer release(@ptrCast(&td.base));
        if (dInt(td, "focus_id")) |f| focus_id = @bitCast(f);
    }

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
        }
    }

    host.post(proto.EvA11yTree{
        .view = v.id,
        .root_id = @bitCast(dInt(upd, "root_id") orelse 0),
        .node_id_to_clear = @bitCast(dInt(upd, "node_id_to_clear") orelse 0),
        .focus_id = focus_id,
        .nodes = .{ .s = nodes_buf.items },
    });
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
    _: [*c]cef.cef_frame_t,
    params: [*c]cef.cef_context_menu_params_t,
    _: [*c]cef.cef_menu_model_t,
    callback: [*c]cef.cef_run_context_menu_callback_t,
) callconv(.c) c_int {
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
    host.post(proto.EvContextMenu{
        .view = v.id,
        .x = pt.x,
        .y = pt.y,
        .flags = flags,
        .link_url = link.slice(),
    });
    return 1;
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
    host.post(proto.FrameDamage{
        .view = v.id,
        .buf_id = v.buf_id,
        .gen = v.gen,
        .rects = list[0..n],
    });
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
    if (ptype != cef.PET_VIEW) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
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
    errdefer {}
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
    _: [*c]cef.cef_frame_t,
    url: [*c]const cef.cef_string_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var s = Utf8.init(url);
    defer s.free();
    host.setUrl(v, s.slice());
    host.postNavState(v);
}

fn onTitleChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    title: [*c]const cef.cef_string_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var s = Utf8.init(title);
    defer s.free();
    host.post(proto.EvTitle{ .view = v.id, .title = s.slice() });
}

fn onFaviconChange(
    _: [*c]cef.cef_display_handler_t,
    browser: [*c]cef.cef_browser_t,
    icon_urls: cef.cef_string_list_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
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
    _: [*c]cef.cef_frame_t,
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
    _: [*c]cef.cef_browser_t,
) callconv(.c) void {
    if (open_browsers > 0) open_browsers -= 1;
}

fn onAfterCreated(
    _: [*c]cef.cef_life_span_handler_t,
    browser: [*c]cef.cef_browser_t,
) callconv(.c) void {
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
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    host.post(proto.EvNavState{
        .view = v.id,
        .can_back = if (can_back != 0) 1 else 0,
        .can_fwd = if (can_fwd != 0) 1 else 0,
        .loading = if (is_loading != 0) 1 else 0,
        .url = v.url,
    });
}

fn onLoadStart(
    _: [*c]cef.cef_load_handler_t,
    browser: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    _: cef.cef_transition_type_t,
) callconv(.c) void {
    if (!isMainFrame(frame)) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    // Chromium's zoom is per origin and resets across a navigation; in
    // accelerated mode the zoom IS the device scale factor, so a page
    // that lost it would render at logical resolution.
    applyZoom(v);
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
    if (!isMainFrame(frame)) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    host.post(proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.finished),
        .url = v.url,
    });
    // The content script is already in: it goes in at context creation,
    // before any page script, so by load end it is only re-armed.
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
    if (!isMainFrame(frame)) return;
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
    var url = Utf8.init(failed_url);
    defer url.free();
    var msg = Utf8.init(text);
    defer msg.free();
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
}

fn onRenderProcessTerminated(
    _: [*c]cef.cef_request_handler_t,
    browser: [*c]cef.cef_browser_t,
    _: cef.cef_termination_status_t,
    _: c_int,
    _: [*c]const cef.cef_string_t,
) callconv(.c) void {
    const host = g_host orelse return;
    const v = viewOf(browser) orelse return;
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
    if (p.prompt_cb) |cb| {
        if (cb.cont) |f| f(cb, if (allow)
            cef.CEF_PERMISSION_RESULT_ACCEPT
        else
            cef.CEF_PERMISSION_RESULT_DENY);
        release(&cb.base);
    }
    if (p.media_cb) |cb| {
        // A media callback grants BITS, not a boolean: handing back the
        // ones asked for is an allow, handing back none is a deny.
        if (cb.cont) |f| f(cb, if (allow) p.media_bits else 0);
        release(&cb.base);
    }
    p.* = .{};
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
    _: [*c]cef.cef_frame_t,
    requesting_origin: [*c]const cef.cef_string_t,
    requested_permissions: u32,
    callback: [*c]cef.cef_media_access_callback_t,
) callconv(.c) c_int {
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
    _: [*c]cef.cef_browser_t,
    _: [*c]const cef.cef_string_t,
    _: [*c]const cef.cef_string_t,
) callconv(.c) c_int {
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
    const d = (found orelse dlSlot(host, view_id, id)) orelse {
        if (cb_arg) |cb| release(&cb.base);
        return;
    };

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
            release(&cb.base);
        } else if (d.cancel_requested) {
            if (cb.cancel) |f| f(cb);
            release(&cb.base);
        } else {
            d.item_cb = cb;
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
    _: [*c]cef.cef_browser_t,
    frame: [*c]cef.cef_frame_t,
    context: [*c]cef.cef_v8_context_t,
) callconv(.c) void {
    const ctx: *cef.cef_v8_context_t = context orelse return;
    // Subframes get the transport taken away and nothing else: commands
    // only ever go to the main frame, so an injected subframe could only
    // post unsolicited walks of ITS document into the shadow tree.
    if (!isMainFrame(frame)) {
        evalJs(ctx, disarm_js);
        return;
    }
    if (!sem_secret.ok) return;
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
    _: [*c]cef.cef_v8_value_t,
    argc: usize,
    argv: [*c]const [*c]cef.cef_v8_value_t,
    _: [*c][*c]cef.cef_v8_value_t,
    _: [*c]cef.cef_string_t,
) callconv(.c) c_int {
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
    const args = cef.cef_main_args_t{ .argc = argc, .argv = argv };
    const code = cef.cef_execute_process(&args, &app, null);
    if (code < 0) return null;
    return @intCast(@as(u32, @bitCast(code)) & 0xff);
}

/// Bring CEF up in windowless mode with a private cache directory.
pub fn initialize(argc: c_int, argv: [*c][*c]u8, cache_dir: []const u8, log_file: []const u8) bool {
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
    settings.log_severity = cef.LOGSEVERITY_WARNING;
    setStr(cache_dir, &settings.root_cache_path);
    setStr(log_file, &settings.log_file);
    defer cef.cef_string_utf16_clear(&settings.root_cache_path);
    defer cef.cef_string_utf16_clear(&settings.log_file);
    return cef.cef_initialize(&args, &settings, &app, null) == 1;
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

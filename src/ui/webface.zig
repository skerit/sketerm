//! WebFace — a real browser inside a pane, rendered by the optional
//! `sketerm-webengine` helper (src/web/, docs/proposal-browser.md).
//!
//! Two objects live here:
//!
//! - `Client`: ONE helper process per GUI process, its unix socket
//!   watched with `g_unix_fd_add` and never read blocking. It owns the
//!   handshake, view-id allocation and event routing; faces register in
//!   it and are found by view id.
//! - `WebFace`: one PAGE = one view id. Chrome (address entry,
//!   back/forward/reload) plus a `GtkPicture` presenting the view's
//!   frames as `GdkTexture`s in GTK's own scene graph.
//!
//! A pane holds SEVERAL pages, in a `WebGroup` (src/ui/webgroup.zig) —
//! read its header before changing anything here that touches the pane.
//! Two consequences for this file:
//!
//! - `Pane.web_ctx` is the GROUP, not a face. `fromPane` answers with
//!   the group's ACTIVE page, which is what every pane-scoped verb
//!   means by "the browser on this pane"; `face.group()` goes the other
//!   way.
//! - Anything that writes shared chrome — the window tab's title, the
//!   pane titlebar — must be gated on `isActivePage`, or a background
//!   page relabels what the user is actually looking at.
//!
//! ## Rendering (why a GdkTexture and not a GL pass)
//!
//! ONE presentation path, TWO frame families. Both must keep working
//! for the whole life of a connection — the engine drops from one to
//! the other on its own when GPU compositing goes away — and both end
//! as a `GdkTexture` on the face's `GtkPicture`:
//!
//! - GPU (`frame_dmabuf`, cap "frames-dmabuf"): the engine's dma-buf
//!   planes wrapped by `GdkDmabufTextureBuilder`. GSK imports the
//!   buffer itself (EGLImage under GL, VkImage under Vulkan) and
//!   samples the engine's LIVE pool memory: no pixel ever enters this
//!   process and none is copied. Imports are cached per pool buffer
//!   id, so a steady 100fps costs two or three imports in total.
//! - memfd (`frame_buffer` + `frame_damage`, cap "frames-shm"): mmap
//!   kept refcounted (`MapRef`); every damage batch builds a
//!   `GdkMemoryTextureBuilder` texture over the mapping whose
//!   `update_region` is exactly the damaged rects diffed against the
//!   previous frame's texture, so GSK uploads ONLY those rects to the
//!   GPU. This is the damage-rect economy the old GL pass had, now
//!   done by GTK — NOT the old "fresh GdkMemoryTexture per frame"
//!   disaster (that one re-uploaded the whole 33 MB mapping per batch
//!   because it declared no update region).
//!
//! This replaced a GtkGLArea + own GL pass (`render/web_pass.zig`,
//! deleted with this change), and the reason is RESAMPLING on
//! fractional-scale desktops: a GtkGLArea's framebuffer is sized at
//! GTK's INTEGER scale (2 on a 1.5x output), so a frame CEF rendered
//! at the TRUE fractional scale was upscaled 1.5->2 by the pass and
//! then downscaled 2->1.5 by GSK — two resamplings, and the "browser
//! text is soft" bug. MEASURED at 1.5: a 1px-stripe page left the
//! engine with hard 0/255 edges and reached the screen as [5,117,127]
//! mush. A GdkTexture in the scene graph is composited by GSK at the
//! surface's REAL fractional scale: frame logical size x 1.5 == frame
//! physical size, 1:1 texels, ZERO resampling — provided the texture
//! sits ON the device pixel grid, which `snapAlignment` guarantees
//! (a half-pixel offset measurably destroys 1px detail into uniform
//! gray).
//!
//! No frame is ever QUEUED. The picture's paintable always wraps the
//! newest pixels, so several damage batches arriving between two GTK
//! paints collapse into one, and a paint can never present a frame
//! older than the last batch taken off the socket.
//!
//! ## Frame pacing (who decides when the page paints)
//!
//! The ENGINE paces itself (CEF's internal scheduler), throttled by the
//! `view_max_fps` this face ships — the configured `browser_max_fps`
//! clamped to the current output's real refresh. External begin frames
//! (the previous default) measured a CONSTANT ~30ms of added
//! input-to-paint latency that no request timing could remove; the
//! numbers live at `externalPacingLatency` in `src/web/cefhost.zig`.
//! An untouched page still costs nothing: the scheduler only paints on
//! damage (smoke-web stage 20 holds it at zero).
//!
//! The pacer below still runs, because the GUI-side state it manages is
//! about PRESENTING, not painting — when the tick exists, and when the
//! face may stop watching. Its requests ride along through
//! `src/web/pace.zig`:
//!
//! - IDLE: a 5Hz GLib timeout asks for a frame, so a page that starts
//!   moving on its own is still noticed. NO frame-clock tick exists in
//!   this state — see the `tick_id` docblock in
//!   `src/ui/terminal_surface.zig`: an installed tick keeps GDK's frame
//!   clock cycling at monitor refresh even when nothing is drawn, and
//!   on Wayland each empty cycle leaks a frame-callback object id per
//!   offload subsurface until KWin's id space runs out and the process
//!   dies. `stopTick` is not an optimisation, it is the crash guard.
//! - ACTIVE: a tick on the view widget paces requests at the CURRENT
//!   output's real refresh (from `gdk_frame_clock_get_refresh_info`),
//!   clamped by `browser_max_fps`. Any input promotes here immediately,
//!   so the first paint after a keystroke has no added latency.
//! - Back to IDLE after ~250ms of requests that produced no paint, at
//!   which point the tick REMOVES ITSELF (`onTick` returning
//!   G_SOURCE_REMOVE and zeroing `tick_id`), exactly like the terminal
//!   surface's animation tick.
//!
//! A background tab's view widget is unmapped: the face then sends
//! `view_hide` and stops asking altogether, so an off-screen page paints
//! nothing at all. `SKETERM_WEB_PACE=1` logs every transition (and
//! aborts if a demoted face somehow kept its tick).
//!
//! The REQUESTS the pacer sends are advisory now: the helper's default
//! is CEF's OWN scheduler (`externalPacingLatency` in
//! `src/web/cefhost.zig` — external begin frames measured a constant
//! ~30ms of added input latency that no request timing could remove),
//! so paints arrive on their own and `frame_request` only keeps the
//! helper's watchdog quiet. What replaced request-spacing as the
//! throttle is `view_max_fps`: `syncMaxFps` ships the cap clamped to
//! the CURRENT output's refresh whenever either changes, and the
//! helper applies it via `set_windowless_frame_rate`.
//!
//! Set `SKETERM_WEB_STATS=1` for a per-second stderr line with the
//! delivered frame rate, the time spent here, the bytes actually
//! uploaded, the GPU imports, and the REQUESTS and TICKS behind them.
//! MEASURED at 3840x2160 on a 60fps animating page whose spinner damages
//! 64x64: 1787 MiB/s handed to GDK before, 2 MiB/s of damage rects
//! after, and 0 MiB/s once the frame is a dma-buf import.
//!
//! Read the `ticks` number first when the browser looks slow. It is the
//! rate the COMPOSITOR is willing to present at, and everything else is
//! capped by it: a window straddling the gap between two monitors gets
//! zero ticks, and GSK's Vulkan renderer driving a 4K GtkGLArea measured
//! 11 ticks/s against `ngl`'s 140. Neither is an engine problem and no
//! engine-side change moves either.
//!
//! The helper rewrites the buffer in place, so a rect can be read
//! half-new: the benign tearing the protocol doc already accepts for
//! v1. Nothing outside this file points into the mapping, so unmapping
//! it on replacement is safe — the old `Mapping` refcount existed only
//! because GDK kept memory textures borrowing it alive past the frame
//! that set them.
//!
//! ## Scale (HiDPI)
//!
//! Per docs/proposal-browser-protocol.md "Scale contract": w/h on the
//! wire are LOGICAL, `scale_x1000` is the real fractional device scale,
//! and the buffer that comes back is PHYSICAL. The scale comes from
//! `gdk_surface_get_scale()` — `gtk_widget_get_scale_factor()` rounds
//! 1.5 up to 2 and must not be used. A surface only exists once the
//! view widget is realized, so the face starts at 1.0, re-sends on realize,
//! and watches `GdkSurface::notify::scale` so dragging the window to a
//! differently scaled output re-renders crisply.
//!
//! Input coordinates stay LOGICAL: CEF's `cef_mouse_event_t` is in DIP
//! and applies the screen info's device_scale_factor itself (verified
//! at 2x by the smoke rig's HiDPI click assertion).
//!
//! ## Lifetimes (CLAUDE.md "three mechanisms", one per allocation)
//!
//! - The `Client` is a module-level `var`: it is never freed, so the
//!   socket watch, the write watch and the connect-retry timer have
//!   nothing to dangle into. That immortality IS the liveness fence
//!   (mechanism 3) for every non-widget callback in this file; a face
//!   that dies simply disappears from `Client.faces`, and an event for
//!   its view id then finds nobody.
//! - Every widget signal in a face takes the face as user-data and is
//!   disconnected at the single teardown choke point
//!   (`Pane.severFaces` -> `detachWeb` -> `prepareDestroyCb`), i.e.
//!   mechanism 2. No `GDestroyNotify` is combined with it — that
//!   combination is a use-after-free per CLAUDE.md.
//! - The face allocates no idle/timer callbacks of its own, so it needs
//!   no fence of its own.
//! - A blocked-popup toast is the one exception, and it takes
//!   mechanism 1: the toast OWNS its context through a
//!   `GDestroyNotify`, and that context holds a VIEW ID rather than a
//!   face pointer, so a toast outliving its tab resolves to nothing
//!   instead of into freed memory.
//!
//! ## Security surfaces (what a page must never be able to imitate)
//!
//! Two decisions are made HERE and held by the helper until they are:
//!
//! - A certificate error (`ev_cert_error`, capability "tls") stops the
//!   request and raises a full-face interstitial that COVERS the page,
//!   dark and fixed-coloured rather than themed. "Back to safety" is
//!   the default and leaves; "Proceed anyway" accepts the certificate
//!   for that ONE request — nothing is remembered anywhere.
//! - A permission request (`ev_permission`, capability "permissions")
//!   raises a NON-MODAL banner above the page, because a permission is
//!   not worth blocking the window for. The answer is remembered for
//!   this face's lifetime, per (origin, permission bits), and reported
//!   to `SiteSettingSink` — the single hook a durable site-settings
//!   store attaches to. This file persists nothing.
//!   NOT REACHABLE TODAY: the CEF build this helper uses never asks
//!   for a permission handler in Alloy windowless mode and denies
//!   requests inside the engine, so the banner cannot appear yet. See
//!   `getPermissionHandler` in `src/web/cefhost.zig` and smoke-web
//!   stage 22g, which fails the day that changes.
//!
//! A helper that advertises neither capability sends neither event, so
//! it behaves exactly as it did before both existed.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const platform = @import("../util/platform.zig");
const input = @import("input.zig");
const toolbtn = @import("toolbtn.zig");
const cssutil = @import("cssutil.zig");
const proto = @import("../web/protocol.zig");
const webhints = @import("../web/hints.zig");
const findbin = @import("../web/findbin.zig");
const pace = @import("../web/pace.zig");
const web_model = @import("../web/model.zig");
const clock = @import("../util/clock.zig");
const classicmenu = @import("browser/classicmenu.zig");
const appmenu = @import("appmenu.zig");
const webhistory = @import("webhistory.zig");
const webuserscripts = @import("webuserscripts.zig");
const socksbridge = @import("../ipc/socksbridge.zig");
const mux_cli = @import("../ipc/mux_cli.zig");
const clipboard = @import("clipboard.zig");
const webreader = @import("webreader.zig");
const fpicker = @import("../filebrowser/picker.zig");
const webstore = @import("webstore.zig");
const websiteinfo = @import("websiteinfo.zig");
const webext = @import("webext.zig");
const secrets = @import("secrets.zig");
const suggest = @import("../util/suggest.zig");
const urlhost = @import("../web/urlhost.zig");
const omnibox = @import("omnibox.zig");
const axtree = @import("../web/axtree.zig");
const webproj = @import("../a11y/webproj.zig");
const webremote = @import("webremote.zig");
const webgroup = @import("webgroup.zig");
const zpool = @import("../wlhost/zpool.zig");
const Pane = @import("pane.zig").Pane;

/// How long the GUI waits for a freshly spawned helper to bind its
/// socket. CEF's startup (zygote + GPU process) dominates this.
const CONNECT_INTERVAL_MS: c_uint = 100;
const CONNECT_MAX_TRIES: u32 = 150;

const MISSING_MSG =
    \\The browser helper (sketerm-webengine) is not installed.
    \\
    \\It is opt-in because it needs a CEF binary distribution:
    \\    zig build fetch-cef
    \\    zig build web
;

const LOST_MSG = "The browser helper stopped. Reload to start it again.";
const DEVTOOLS_GONE_MSG =
    "This DevTools view is gone (the browser helper restarted). " ++
    "Open it again from the page you want to inspect.";
const CRASH_MSG = "This page's renderer crashed. Reload to bring it back.";

// ---------------------------------------------------------------------
// Optional frame statistics (`SKETERM_WEB_STATS=1`)
// ---------------------------------------------------------------------

/// Per-second stderr line with the delivered frame rate and the time
/// spent turning a damage batch into a paintable. Off unless the
/// environment variable is set; it is the measurement harness for the
/// rendering path and deliberately left in.
const Stats = struct {
    on: bool = false,
    checked: bool = false,
    frames: u32 = 0,
    /// GPU frames whose dma-buf GDK imported, and those that had to be
    /// mapped and read by the CPU instead. A nonzero `copies` is the
    /// visible symptom of a driver that cannot import what the engine
    /// allocates — the path is still correct, just no longer free.
    gpu_imports: u32 = 0,
    gpu_copies: u32 = 0,
    /// Frame requests sent and frame-clock ticks taken in this window.
    /// They are what separates "the engine is slow" from "the compositor
    /// is not running our frame clock" — a pane whose ticks are near
    /// zero is being throttled by the compositor (occluded, on no
    /// output, or on a monitor that is asleep) and no engine-side change
    /// can move it. That distinction cost an evening once.
    reqs: u32 = 0,
    ticks: u32 = 0,
    ns_total: u64 = 0,
    ns_max: u64 = 0,
    bytes: u64 = 0,
    window_start_ns: u64 = 0,

    fn enabled(self: *Stats) bool {
        if (!self.checked) {
            self.checked = true;
            self.on = c.getenv("SKETERM_WEB_STATS") != null;
        }
        return self.on;
    }

    fn nowNs() u64 {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
    }

    fn note(self: *Stats, ns: u64, payload: usize) void {
        self.frames += 1;
        self.ns_total += ns;
        if (ns > self.ns_max) self.ns_max = ns;
        self.bytes += payload;
        const now = nowNs();
        if (self.window_start_ns == 0) {
            self.window_start_ns = now;
            return;
        }
        const span = now - self.window_start_ns;
        if (span < 1_000_000_000) return;
        const fps = @as(f64, @floatFromInt(self.frames)) * 1e9 / @as(f64, @floatFromInt(span));
        const avg_us = @as(f64, @floatFromInt(self.ns_total)) / @as(f64, @floatFromInt(self.frames)) / 1000.0;
        const mbps = @as(f64, @floatFromInt(self.bytes)) * 1e9 /
            @as(f64, @floatFromInt(span)) / (1024.0 * 1024.0);
        std.debug.print(
            "webface stats: {d:.1} fps, frame avg {d:.1} us max {d:.1} us, {d:.0} MiB/s, gpu {d} imported / {d} copied, {d} reqs {d} ticks\n",
            .{ fps, avg_us, @as(f64, @floatFromInt(self.ns_max)) / 1000.0, mbps, self.gpu_imports, self.gpu_copies, self.reqs, self.ticks },
        );
        self.* = .{ .on = true, .checked = true, .window_start_ns = now };
    }
};

var g_stats: Stats = .{};

// ---------------------------------------------------------------------
// Hover-latency probe (`SKETERM_WEB_LAT=1` slow / `=fast`)
// ---------------------------------------------------------------------

/// Input-to-pixel latency probe: a timer alternates a synthetic pointer
/// move between a point INSIDE a hover-styled element (expected to turn
/// red) and one outside it (back to blue), and the render callback reads
/// the probed pixel back from the GL framebuffer after the draw. The
/// printed delta is input-send to pixel-in-our-framebuffer; compositor
/// presentation adds one more cycle on top and is NOT included.
/// `slow` (700ms period) starts each probe from the pacer's idle state —
/// the user's "mouse arrives at a button on a static page" case; `fast`
/// (100ms) keeps the view active.
const Lat = struct {
    mode: enum { off, slow, fast } = .off,
    checked: bool = false,
    /// A probe input was sent and its pixel not yet observed.
    pending: bool = false,
    expect_hover: bool = false,
    t_input_us: i64 = 0,
    /// First frame REQUEST sent after the input; 0 until one goes out.
    req_us: i64 = 0,
    /// First frame arrival after the input; 0 until one lands.
    arrival_us: i64 = 0,
    /// Frames that arrived between the input and the matching pixel.
    frames_seen: u32 = 0,

    fn enabled(self: *Lat) bool {
        if (!self.checked) {
            self.checked = true;
            if (c.getenv("SKETERM_WEB_LAT")) |v| {
                const s = std.mem.span(v);
                self.mode = if (std.mem.eql(u8, s, "fast")) .fast else .slow;
            }
        }
        return self.mode != .off;
    }
};

var g_lat: Lat = .{};

// ---------------------------------------------------------------------
// Pace logging (`SKETERM_WEB_PACE=1`)
// ---------------------------------------------------------------------

var g_pace_log: struct { on: bool = false, checked: bool = false } = .{};

fn paceLogging() bool {
    if (!g_pace_log.checked) {
        g_pace_log.checked = true;
        g_pace_log.on = c.getenv("SKETERM_WEB_PACE") != null;
    }
    return g_pace_log.on;
}

// ---------------------------------------------------------------------
// App-level frame cap
// ---------------------------------------------------------------------

/// `browser_max_fps` from the config; 0 = follow the display. App-level
/// like the other rendering flags, and module-level like the client it
/// paces — every face reads the same number.
var g_max_fps: u16 = 0;

/// Push the configured cap (0 = follow the display) into every live
/// face. Called from `applyConfigChange` and at window construction, the
/// same shape as `imhost.setPreference`.
pub fn setMaxFps(fps: u16) void {
    g_max_fps = fps;
    for (g_client.faces.items) |f| {
        f.pacer.cap_fps = fps;
        f.syncMaxFps();
    }
}

// ---------------------------------------------------------------------
// Automatic tab discard
// ---------------------------------------------------------------------

/// `web_discard_minutes`: how long a face may stay off screen before
/// its page is discarded outright (0 = never). App-level and
/// module-level for the same reason as the frame cap — every face reads
/// the same number.
var g_discard_minutes: u32 = 30;

/// Apply `web_discard_minutes`, re-arming every off-screen face against
/// the new interval (and disarming them all at 0). Called from
/// `applyConfigChange` and at window construction.
pub fn setDiscardMinutes(minutes: u32) void {
    g_discard_minutes = minutes;
    for (g_client.faces.items) |f| {
        f.stopDiscardTimer();
        if (!f.on_screen) f.armDiscardTimer();
    }
}

/// Discard every face that is not on screen, now — the
/// `web_discard_background` action. Returns how many pages were let go,
/// which is what the toast reports.
pub fn discardBackground() usize {
    var n: usize = 0;
    for (g_client.faces.items) |f| {
        if (f.on_screen) continue;
        if (f.discardNow()) n += 1;
    }
    return n;
}

/// Whether the connected helper can discard at all, so a UI can say
/// "not supported" instead of quietly doing nothing.
pub fn discardSupported() bool {
    return g_client.cap_discard;
}

/// Every registered web face in this GUI process — the omnibox's
/// open-tabs source. Borrowed; do not hold across GTK dispatch.
pub fn openFaces() []const *WebFace {
    return g_client.faces.items;
}

/// Resolve a view id to its face — the id-not-pointer indirection the
/// popup toast uses too, so a deferred activation can never touch a
/// face that died in between.
pub fn faceByView(view: u32) ?*WebFace {
    return g_client.findFace(view);
}

// ---------------------------------------------------------------------
// App-level popup policy
// ---------------------------------------------------------------------

/// What happens to a page's `window.open` / `target=_blank`.
///
/// The helper never opens a popup itself: it cancels and reports, so
/// this is purely the GUI's decision. `block_gestureless` is the
/// default because the flag it keys on is what separates "the user
/// clicked a link that opens a tab" from "the page opened one on its
/// own" — the second is the advertising pop-under, and it is the only
/// one blocked.
pub const PopupPolicy = enum { block_gestureless, allow, block_all };

var g_popup_policy: PopupPolicy = .block_gestureless;

/// `web_popup_policy` from the config. App-level and module-level for
/// the same reason as the frame cap: one helper client, one policy.
pub fn setPopupPolicy(policy: PopupPolicy) void {
    g_popup_policy = policy;
}

/// `web_download_ask` from the config: true = a save dialog per
/// download, false = auto-accept into ~/Downloads. App-level and
/// module-level for the same reason as the popup policy.
var g_download_ask: bool = true;

pub fn setDownloadAsk(ask: bool) void {
    g_download_ask = ask;
}

// ---------------------------------------------------------------------
// App-level search engine
// ---------------------------------------------------------------------

/// `web_search_engine` from the config, COPIED into a module buffer:
/// the config string lives in a per-window arena that
/// `applyConfigChange` frees, and a module global must not dangle when
/// the window that last applied it closes.
var g_search_buf: [512]u8 = undefined;
var g_search_len: usize = 0;

/// App-level and module-level like the popup policy: one helper
/// client, one engine. An over-long template falls back to the
/// default (the config layer never produces one).
pub fn setSearchEngine(template: []const u8) void {
    if (template.len > g_search_buf.len) {
        g_search_len = 0;
        return;
    }
    @memcpy(g_search_buf[0..template.len], template);
    g_search_len = template.len;
}

pub fn searchTemplate() []const u8 {
    return if (g_search_len == 0) suggest.default_search_template else g_search_buf[0..g_search_len];
}

// ---------------------------------------------------------------------
// Site settings (permission memory)
// ---------------------------------------------------------------------

/// Where a permission decision goes once the user has made it.
///
/// THE integration point for the daemon-side site-settings store: set
/// this once and every Allow/Block a face records is reported to it,
/// origin and permission bits included. Nothing in this file persists
/// anything — a face's memory is in-process and dies with the tab, by
/// design, so the store owns durability alone.
pub const SiteSettingSink = *const fn (origin: []const u8, types: u32, allow: bool) void;

var g_site_setting_sink: ?SiteSettingSink = null;

pub fn setSiteSettingSink(sink: ?SiteSettingSink) void {
    g_site_setting_sink = sink;
}

/// Allocator the store sink queues its `site_set` with. The sink is a
/// plain function pointer (one process, one store), so the allocator
/// has to live beside it rather than travel in a context.
var g_sink_gpa: ?std.mem.Allocator = null;

/// Make the daemon web store the durable home of permission answers.
/// Idempotent; called wherever the app-level browser policy is applied
/// (Window construction and every config reload).
pub fn installStoreSiteSink(gpa: std.mem.Allocator) void {
    g_sink_gpa = gpa;
    setSiteSettingSink(&storeSiteSink);
}

/// The installed sink: one `site_set` per remembered decision. A
/// permission set this build cannot name is simply not persisted — a
/// key that could not be read back would answer the wrong prompt.
fn storeSiteSink(origin: []const u8, types: u32, allow: bool) void {
    const gpa = g_sink_gpa orelse return;
    var buf: [256]u8 = undefined;
    const key = webstore.permKey(&buf, types) orelse return;
    webstore.siteSetPerm(gpa, origin, key, if (allow) "allow" else "deny");
}

// ---------------------------------------------------------------------
// Client — one helper process per GUI process
// ---------------------------------------------------------------------

pub const Client = struct {
    pub const State = enum { idle, connecting, ready, unavailable };

    gpa: std.mem.Allocator = undefined,
    /// `gpa`/`out` are set on the FIRST ensure and reused for the
    /// process's life; a restart re-uses them rather than leaking the
    /// outbox's buffer.
    initialized: bool = false,
    state: State = .idle,
    /// Why `state == .unavailable`. Static strings only.
    reason: []const u8 = "",
    /// False for "the binary is not installed", where a retry can only
    /// fail the same way; true for anything a restart might fix.
    reason_retryable: bool = true,
    fd: c_int = -1,
    pid: c.pid_t = -1,
    sock_path: [108]u8 = undefined,
    sock_len: usize = 0,
    /// Remote helper host ("" = the local helper this GUI spawns). A
    /// remote client's `fd` is one end of a socketpair whose other end
    /// a `webremote.Bridge` worker pumps to a helper the REMOTE mux
    /// daemon spawned (`web_helper_open`); such a helper runs
    /// `--frames-inline`, so every frame arrives in-band and no
    /// SCM_RIGHTS descriptor ever needs to cross.
    host: [256]u8 = undefined,
    host_len: usize = 0,
    bridge: ?*webremote.Bridge = null,
    /// Storage for a formatted (non-static) unavailable reason; stable
    /// because clients are never freed.
    reason_buf: [256]u8 = undefined,
    in: std.ArrayList(u8) = .empty,
    out: proto.Outbox = undefined,
    /// Descriptors received through SCM_RIGHTS, in arrival order. A
    /// `frame_buffer` frame pops the front one — the helper attaches
    /// exactly one fd to exactly that frame.
    fds: std.ArrayList(c_int) = .empty,
    read_watch: c.guint = 0,
    write_watch: c.guint = 0,
    connect_timer: c.guint = 0,
    connect_tries: u32 = 0,
    faces: std.ArrayList(*WebFace) = .empty,
    /// The helper advertised `discard` (protocol `CAP_DISCARD`). An
    /// older helper without it never sees a `view_discard` and every
    /// hidden face behaves exactly as it did before the feature: paused
    /// painting, browser kept.
    cap_discard: bool = false,
    /// Capabilities the CURRENT helper answered with. A helper that
    /// predates either feature advertises neither, sends neither event,
    /// and the face keeps behaving exactly as it did before them — the
    /// degradation is silent by construction, and these two flags only
    /// keep the GUI from posting decisions such a helper would ignore.
    has_tls: bool = false,
    has_permissions: bool = false,
    /// Capabilities the CURRENT helper advertised. A helper too old
    /// for one of these leaves its menu row insensitive rather than
    /// hidden, so the verb is still discoverable.
    cap_devtools: bool = false,
    cap_print_pdf: bool = false,
    cap_downloads: bool = false,
    /// The helper accepts `a11y_enable` and streams the AX tree. An
    /// older helper simply skips the unknown frame, so this flag only
    /// records what the face may expect back.
    cap_a11y: bool = false,
    /// The helper accepts `context_create`/`context_destroy` (per-tab
    /// identity contexts). An older helper ignores the frames and every
    /// view shares one cookie jar — silent, correct degradation.
    cap_contexts: bool = false,
    /// The helper accepts the 0xC0 user-content sets (userscripts +
    /// userstyles). On the ack the client fetches both sets from the
    /// daemon web store and pushes them; an older helper skips the
    /// frames and pages get no user content — silent degradation.
    cap_userscripts: bool = false,
    /// The helper answers the cookie / site-data frames. An older one
    /// advertises nothing, is sent none of them, and the site-info
    /// popover hides that section — permissions and blocking, which
    /// need no helper support at all, keep working.
    cap_sitedata: bool = false,
    /// The helper accepts `frame_mode` and can deliver `frame_inline`
    /// frames. A REMOTE client requires it: without it the bridge would
    /// silently eat every frame descriptor and the pane would stay
    /// black, so its absence is a described failure, never a hang.
    cap_frames_inline: bool = false,
    /// The helper hosts MV2-flavor WebExtensions (the 0xB0 frame block).
    /// Absent, the GUI loads no extension and the helper hosts none.
    cap_webext: bool = false,

    fn hostSlice(self: *const Client) []const u8 {
        return self.host[0..self.host_len];
    }

    pub fn isRemote(self: *const Client) bool {
        return self.host_len != 0;
    }

    /// Bring the helper up if it is not already. Never blocks: a
    /// missing binary or a helper that never answers leaves the client
    /// `.unavailable` and every face showing `reason`.
    pub fn ensure(self: *Client, gpa: std.mem.Allocator) void {
        if (self.state != .idle) return;
        if (!self.initialized) {
            self.gpa = gpa;
            self.out = proto.Outbox.init(gpa);
            self.initialized = true;
        }
        if (self.isRemote()) {
            self.ensureRemote();
            return;
        }

        var bin_buf: [4096:0]u8 = undefined;
        const bin = findbin.find(&bin_buf) orelse {
            self.failWith(MISSING_MSG, false);
            return;
        };
        const path = self.makeSocketPath() orelse {
            self.fail("No usable runtime directory for the browser helper socket.");
            return;
        };
        // A stale socket file from a crashed helper would make our
        // connect succeed against nothing; the helper unlinks it too,
        // but only once it gets that far.
        var path_z: [128:0]u8 = undefined;
        if (path.len + 1 > path_z.len) {
            self.fail("Runtime directory path is too long for a unix socket.");
            return;
        }
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        _ = c.unlink(&path_z);

        const pid = c.fork();
        if (pid == 0) {
            // stdin/stdout to /dev/null so the helper can never wedge a
            // pipeline the GUI sits in; stderr stays, it is where CEF
            // reports refusals.
            const devnull = c.open("/dev/null", c.O_RDWR);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 0);
                _ = c.dup2(devnull, 1);
                if (devnull > 2) _ = c.close(devnull);
            }
            var argv: [4:null]?[*:0]const u8 = .{ bin, "--socket", &path_z, null };
            _ = c.execv(bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        if (pid < 0) {
            self.fail("Could not start the browser helper (fork failed).");
            return;
        }
        self.pid = pid;
        self.state = .connecting;
        self.connect_tries = 0;
        self.connect_timer = c.g_timeout_add(CONNECT_INTERVAL_MS, @ptrCast(&onConnectTick), self);
    }

    /// Remote helper: adopt the bridge's socketpair end as the protocol
    /// socket and let the worker connect the mux transport behind it.
    /// The Client goes `.ready` immediately — outbound frames buffer in
    /// the socketpair until the bridge comes up, and a bridge failure
    /// surfaces as a HUP whose reason `lost()` collects. The inline
    /// frame family is REQUIRED on this path; `hello_ack` enforces it.
    fn ensureRemote(self: *Client) void {
        const br = webremote.Bridge.create(self.gpa, self.hostSlice()) orelse {
            self.fail("Could not create the remote browser bridge.");
            return;
        };
        const fd = br.guiFd();
        if (fd < 0) {
            br.stop();
            self.fail("Could not create the remote browser bridge.");
            return;
        }
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.bridge = br;
        self.fd = fd;
        self.state = .ready;
        self.read_watch = c.g_unix_fd_add(
            fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&onReadable),
            self,
        );
        br.spawn();
        self.post(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "sketerm-gui" });
        // Before any view exists (the frame-mode contract): everything
        // this helper ever paints must arrive in-band.
        self.post(proto.FrameMode{ .mode = proto.frame_mode_inline });
        publishContexts(self);
        for (self.faces.items) |f| f.onClientReady();
    }

    /// Drop everything and allow a later `ensure` to start over. The
    /// crashed/lost overlay's Reload button is the user-facing route.
    pub fn restart(self: *Client) void {
        if (self.state == .ready or self.state == .connecting) return;
        if (self.pid > 0) {
            _ = c.kill(self.pid, c.SIGTERM);
            self.reap();
        }
        self.state = .idle;
        self.reason = "";
        self.ensure(self.gpa);
        // Faces re-create their views as soon as the handshake lands.
    }

    fn fail(self: *Client, reason: []const u8) void {
        self.failWith(reason, true);
    }

    fn failWith(self: *Client, reason: []const u8, retryable: bool) void {
        self.teardownConnection();
        self.state = .unavailable;
        self.reason = reason;
        self.reason_retryable = retryable;
        for (self.faces.items) |f| f.onHelperUnavailable(reason, retryable);
    }

    fn teardownConnection(self: *Client) void {
        if (self.read_watch != 0) {
            _ = c.g_source_remove(self.read_watch);
            self.read_watch = 0;
        }
        if (self.write_watch != 0) {
            _ = c.g_source_remove(self.write_watch);
            self.write_watch = 0;
        }
        if (self.connect_timer != 0) {
            _ = c.g_source_remove(self.connect_timer);
            self.connect_timer = 0;
        }
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        // Capabilities belong to the CONNECTION, not to the client: a
        // restart may land on a different helper build.
        self.cap_discard = false;
        self.cap_frames_inline = false;
        if (self.bridge) |br| {
            self.bridge = null;
            br.stop();
        }
        for (self.fds.items) |fd| _ = c.close(fd);
        self.fds.clearRetainingCapacity();
        self.in.clearRetainingCapacity();
        while (self.out.front()) |m| self.out.advance(m.bytes.len);
    }

    /// Non-blocking child reap. The helper is our own child, so an
    /// unreaped exit would be a zombie for the GUI's lifetime.
    fn reap(self: *Client) void {
        if (self.pid <= 0) return;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, c.WNOHANG);
        if (r == self.pid) self.pid = -1;
    }

    fn makeSocketPath(self: *Client) ?[]const u8 {
        const rt = platform.runtimeDir();
        var dir_buf: [96:0]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/sketerm", .{rt}) catch return null;
        _ = c.mkdir(dir.ptr, 0o700);
        const p = std.fmt.bufPrint(&self.sock_path, "{s}/{s}{d}.sock", .{
            dir,
            @import("../ipc/server.zig").WEB_SOCKET_PREFIX,
            c.getpid(),
        }) catch return null;
        self.sock_len = p.len;
        return p;
    }

    fn onConnectTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Client, user);
        self.connect_tries += 1;

        // A helper that died on startup (missing libcef, bad CEF
        // deployment) will never bind; say so rather than time out.
        if (self.pid > 0) {
            var status: c_int = 0;
            if (c.waitpid(self.pid, &status, c.WNOHANG) == self.pid) {
                self.pid = -1;
                self.connect_timer = 0;
                self.fail("The browser helper exited during startup (see its stderr).");
                return 0;
            }
        }

        if (self.tryConnect()) {
            self.connect_timer = 0;
            return 0;
        }
        if (self.connect_tries >= CONNECT_MAX_TRIES) {
            self.connect_timer = 0;
            self.fail("The browser helper did not answer in time.");
            return 0;
        }
        return 1;
    }

    fn tryConnect(self: *Client) bool {
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        if (self.sock_len + 1 > addr.sun_path.len) return false;
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..self.sock_len], self.sock_path[0..self.sock_len]);
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return false;
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
            _ = c.close(fd);
            return false;
        }
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.fd = fd;
        self.state = .ready;
        self.read_watch = c.g_unix_fd_add(
            fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&onReadable),
            self,
        );
        self.post(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "sketerm-gui" });
        // Re-publish every container BEFORE the faces mint their views:
        // a fresh helper knows no contexts, and a view_create naming one
        // must be preceded by its context_create. Sent optimistically
        // (before hello_ack, like view_create) — an old helper skips the
        // unknown frames and every view shares the default jar.
        publishContexts(self);
        // Extensions the user installed are pushed to the fresh helper
        // the same way, before any view exists.
        webext.ensureLoaded(self.gpa);
        webext.publish(self);
        for (self.faces.items) |f| f.onClientReady();
        return true;
    }

    /// The connection died (helper crash, protocol error). Faces show
    /// the "helper stopped" overlay; a Reload starts a fresh one. A
    /// remote bridge records WHY it died before closing its end, so
    /// that reason (copied — teardown destroys the bridge) wins over
    /// the generic message.
    fn lost(self: *Client) void {
        if (self.state == .unavailable) return;
        self.reap();
        if (self.bridge) |br| {
            const why = br.takeReason();
            if (why.len != 0) {
                const n = @min(why.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..n], why[0..n]);
                self.fail(self.reason_buf[0..n]);
                return;
            }
        }
        self.fail(LOST_MSG);
    }

    pub fn register(self: *Client, face: *WebFace) void {
        self.faces.append(self.gpa, face) catch {};
    }

    pub fn unregister(self: *Client, face: *WebFace) void {
        for (self.faces.items, 0..) |f, i| {
            if (f == face) {
                _ = self.faces.swapRemove(i);
                return;
            }
        }
    }

    fn findFace(self: *Client, view: u32) ?*WebFace {
        for (self.faces.items) |f| {
            if (f.view == view) return f;
        }
        return null;
    }

    /// Fetch the stored userscript + userstyle sets from the daemon
    /// web store and push them to the helper as replace-all frames.
    /// Called on every hello_ack and after every management-UI edit
    /// (src/ui/webuserscripts.zig); a helper without the capability,
    /// or a store-less daemon, degrades to "no user content".
    pub fn refreshUserContent(self: *Client) void {
        if (self.state != .ready or !self.cap_userscripts) return;
        _ = webstore.userscriptList(self.gpa, @ptrCast(self), &onUserscriptsReply);
        _ = webstore.userstyleList(self.gpa, @ptrCast(self), &onUserstylesReply);
    }

    fn onUserscriptsReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
        const self = cast.userData(Client, ctx);
        if (!ok or self.state != .ready or !self.cap_userscripts) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const list = webstore.parseUserscripts(arena.allocator(), payload);
        var scripts: std.ArrayList(proto.UsScript) = .empty;
        defer scripts.deinit(self.gpa);
        for (list) |s| {
            if (!s.enabled or s.source.len == 0) continue;
            scripts.append(self.gpa, .{
                .id = @truncate(s.id),
                .source = .{ .s = s.source },
            }) catch return;
        }
        self.post(proto.UsScriptSet{ .scripts = scripts.items });
    }

    fn onUserstylesReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
        const self = cast.userData(Client, ctx);
        if (!ok or self.state != .ready or !self.cap_userscripts) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const list = webstore.parseUserstyles(arena.allocator(), payload);
        var styles: std.ArrayList(proto.UsStyle) = .empty;
        defer styles.deinit(self.gpa);
        for (list, 0..) |s, i| {
            if (!s.enabled or s.css.len == 0) continue;
            styles.append(self.gpa, .{
                .id = @intCast(i + 1),
                .host = s.host,
                .css = .{ .s = s.css },
            }) catch return;
        }
        self.post(proto.UsStyleSet{ .styles = styles.items });
    }

    /// Queue a frame and push what the socket takes now. A stalled
    /// helper must never block the GLib loop, so the remainder rides a
    /// writable-fd watch.
    pub fn post(self: *Client, value: anytype) void {
        if (self.state != .ready) return;
        self.out.post(value, null) catch return;
        self.flush();
    }

    fn flush(self: *Client) void {
        while (self.out.front()) |m| {
            const n = c.write(self.fd, m.bytes.ptr, m.bytes.len);
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                if (e == c.EINTR) continue;
                self.lost();
                return;
            }
            if (n == 0) break;
            self.out.advance(@intCast(n));
        }
        if (!self.out.empty() and self.write_watch == 0) {
            self.write_watch = c.g_unix_fd_add(
                self.fd,
                c.G_IO_OUT | c.G_IO_HUP | c.G_IO_ERR,
                @ptrCast(&onWritable),
                self,
            );
        }
    }

    fn onWritable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Client, user);
        self.write_watch = 0;
        if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            self.lost();
            return 0;
        }
        self.flush();
        return 0;
    }

    fn onReadable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Client, user);
        if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            self.read_watch = 0;
            self.lost();
            return 0;
        }
        if (!self.readIn()) {
            self.read_watch = 0;
            self.lost();
            return 0;
        }
        return 1;
    }

    /// Drain the socket into `in`, collecting passed descriptors, then
    /// dispatch every complete frame. False = the connection is done.
    fn readIn(self: *Client) bool {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            var iov = c.struct_iovec{ .iov_base = &buf, .iov_len = buf.len };
            var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
            var mh = std.mem.zeroes(c.struct_msghdr);
            mh.msg_iov = @ptrCast(&iov);
            mh.msg_iovlen = 1;
            mh.msg_control = &cbuf;
            mh.msg_controllen = cbuf.len;
            const n = c.recvmsg(self.fd, &mh, 0);
            if (n == 0) return false;
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                if (e == c.EINTR) continue;
                return false;
            }
            const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
            if (@as(usize, @intCast(mh.msg_controllen)) >= hdr_size) {
                const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(&cbuf));
                if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS and
                    @as(usize, @intCast(hdr.cmsg_len)) >= hdr_size + @sizeOf(c_int))
                {
                    // ONE control message can carry several descriptors:
                    // a memfd frame attaches one, a dma-buf frame one
                    // per plane. Reading only the first would leak the
                    // rest into this process forever.
                    const bytes = @as(usize, @intCast(hdr.cmsg_len)) - hdr_size;
                    var off: usize = 0;
                    while (off + @sizeOf(c_int) <= bytes and hdr_size + off + @sizeOf(c_int) <= cbuf.len) : (off += @sizeOf(c_int)) {
                        var passed: c_int = undefined;
                        @memcpy(std.mem.asBytes(&passed), cbuf[hdr_size + off ..][0..@sizeOf(c_int)]);
                        self.fds.append(self.gpa, passed) catch {
                            _ = c.close(passed);
                        };
                    }
                }
            }
            self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch return false;
            if (@as(usize, @intCast(n)) < buf.len) break;
        }

        var reader = proto.Reader.init(self.in.items);
        while (true) {
            const frame = (reader.next() catch return false) orelse break;
            self.dispatch(frame);
            // A frame can end the connection (protocol mismatch), which
            // empties `in` underneath us.
            if (self.fd < 0) return false;
        }
        const used = reader.consumed();
        if (used != 0 and used <= self.in.items.len) {
            const rest = self.in.items.len - used;
            std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[used..]);
            self.in.shrinkRetainingCapacity(rest);
        }
        return true;
    }

    fn takeFd(self: *Client) ?c_int {
        if (self.fds.items.len == 0) return null;
        const fd = self.fds.orderedRemove(0);
        return fd;
    }

    /// Pop the `n` descriptors a frame announced, into `out`. All or
    /// nothing: a partial set is a desynchronised stream, not a frame.
    fn takeFds(self: *Client, n: usize, out: []c_int) ?[]c_int {
        if (n == 0 or n > out.len or self.fds.items.len < n) return null;
        for (out[0..n]) |*fd| fd.* = self.fds.orderedRemove(0);
        return out[0..n];
    }

    fn dispatch(self: *Client, frame: proto.Frame) void {
        switch (frame.tag) {
            .hello_ack => {
                const ack = proto.HelloAck.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ack.caps);
                if (ack.proto != proto.PROTO_VERSION) {
                    self.fail("The browser helper speaks a different protocol version.");
                    return;
                }
                self.cap_discard = false;
                self.has_tls = false;
                self.has_permissions = false;
                self.cap_devtools = false;
                self.cap_print_pdf = false;
                self.cap_downloads = false;
                self.cap_a11y = false;
                self.cap_contexts = false;
                self.cap_userscripts = false;
                self.cap_sitedata = false;
                self.cap_frames_inline = false;
                for (ack.caps) |cap| {
                    if (std.mem.eql(u8, cap, proto.CAP_DISCARD)) self.cap_discard = true;
                    if (std.mem.eql(u8, cap, proto.CAP_TLS)) self.has_tls = true;
                    if (std.mem.eql(u8, cap, proto.CAP_PERMISSIONS)) self.has_permissions = true;
                    if (std.mem.eql(u8, cap, proto.CAP_DEVTOOLS)) self.cap_devtools = true;
                    if (std.mem.eql(u8, cap, proto.CAP_PRINT_PDF)) self.cap_print_pdf = true;
                    if (std.mem.eql(u8, cap, proto.CAP_DOWNLOADS)) self.cap_downloads = true;
                    if (std.mem.eql(u8, cap, proto.CAP_A11Y)) self.cap_a11y = true;
                    if (std.mem.eql(u8, cap, proto.CAP_CONTEXTS)) self.cap_contexts = true;
                    if (std.mem.eql(u8, cap, proto.CAP_USERSCRIPTS)) self.cap_userscripts = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SITEDATA)) self.cap_sitedata = true;
                    if (std.mem.eql(u8, cap, proto.CAP_FRAMES_INLINE)) self.cap_frames_inline = true;
                    if (std.mem.eql(u8, cap, proto.CAP_WEBEXT)) self.cap_webext = true;
                }
                // A remote helper without inline frames would keep
                // posting memfd frames whose descriptors the bridge
                // silently ate: a black pane forever. Fail loudly now.
                if (self.isRemote() and !self.cap_frames_inline) {
                    self.fail("The browser helper on the remote host is too old for remote browsing (no frames-inline capability).");
                    return;
                }
                // Seed the helper with the stored user content before
                // the faces' first navigations get far.
                self.refreshUserContent();
            },
            .ev_webext_state => {
                const st = proto.decode(proto.EvWebextState, frame.payload) catch return;
                webext.onState(st);
            },
            .frame_buffer => {
                const fb = proto.decode(proto.FrameBuffer, frame.payload) catch return;
                const fd = self.takeFd() orelse return;
                const face = self.findFace(fb.view) orelse {
                    _ = c.close(fd);
                    return;
                };
                face.adoptBuffer(fb, fd);
            },
            .frame_dmabuf => {
                const f = proto.FrameDmabuf.decodeFrom(frame.payload) catch return;
                var buf: [proto.MAX_PLANES]c_int = undefined;
                const fds = self.takeFds(f.nplanes, &buf) orelse return;
                const face = self.findFace(f.view) orelse {
                    for (fds) |fd| _ = c.close(fd);
                    return;
                };
                face.onDmabuf(f, fds);
            },
            .frame_damage => {
                const dmg = proto.FrameDamage.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(dmg.rects);
                const face = self.findFace(dmg.view) orelse return;
                face.onDamage(dmg);
            },
            .frame_inline => {
                const fi = proto.FrameInline.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(fi.rects);
                const face = self.findFace(fi.view) orelse return;
                face.onInline(fi);
            },
            .ev_title => {
                const ev = proto.decode(proto.EvTitle, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onTitle(ev.title);
            },
            .ev_nav_state => {
                const ev = proto.decode(proto.EvNavState, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onNavState(ev);
            },
            .ev_load => {
                const ev = proto.decode(proto.EvLoad, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onLoad(ev);
            },
            .ev_load_error => {
                const ev = proto.decode(proto.EvLoadError, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onLoadError(ev);
            },
            .ev_cursor => {
                const ev = proto.decode(proto.EvCursor, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onCursor(ev.cursor);
            },
            .ev_popup_request => {
                const ev = proto.decode(proto.EvPopupRequest, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onPopup(ev.url, ev.user_gesture != 0);
            },
            .ev_cert_error => {
                const ev = proto.decode(proto.EvCertError, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onCertError(ev);
            },
            .ev_permission => {
                const ev = proto.decode(proto.EvPermission, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onPermission(ev);
            },
            .ev_find_result => {
                const ev = proto.decode(proto.EvFindResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onFindResult(ev);
            },
            .ev_context_menu => {
                const ev = proto.decode(proto.EvContextMenu, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onContextMenu(ev);
            },
            .ev_crashed => {
                const ev = proto.decode(proto.EvCrashed, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onCrashed();
            },
            .ev_a11y_tree => {
                const ev = proto.decode(proto.EvA11yTree, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onAxTree(ev);
            },
            .ev_a11y_loc => {
                const ev = proto.decode(proto.EvA11yLoc, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onAxLoc(ev);
            },
            .sem_snapshot => {
                const ev = proto.decode(proto.SemSnapshot, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onSnapshot(ev);
            },
            .sem_act_result => {
                const ev = proto.decode(proto.SemActResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.completeOp(.act, ev.ok != 0, ev.msg, .{});
            },
            .sem_expand_result => {
                const ev = proto.decode(proto.SemExpandResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.completeOp(.expand, true, ev.text, .{});
            },
            .sem_query_result => {
                const ev = proto.decode(proto.SemQueryResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    // A hints request rides the query kind; the face
                    // consumes its own reply before the automation
                    // bookkeeping can hand it to an MCP caller.
                    if (!face.onHintsResult(ev.payload.s))
                        face.completeOp(.query, true, ev.payload.s, .{});
                }
            },
            .sem_read_result => {
                const ev = proto.decode(proto.SemReadResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    face.completeOp(.read, true, ev.markdown.s, .{});
                    // The GUI reader rides the same request kind as the
                    // `web_read` tool; this is where it collects its own.
                    face.onReadReply();
                }
            },
            .sem_eval_result => {
                const ev = proto.decode(proto.SemEvalResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onEvalResult(ev);
            },
            .intercept_status => {
                const ev = proto.decode(proto.InterceptStatus, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onInterceptStatus(ev);
            },
            .intercept_log => {
                const ev = proto.InterceptLog.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entries);
                if (self.findFace(ev.view)) |face| face.onInterceptLog(ev);
            },
            .ev_devtools_view => {
                const ev = proto.decode(proto.EvDevToolsView, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    face.onDevToolsView(ev.devtools, ev.reason);
                } else if (ev.devtools != 0) {
                    // The pane that asked is gone; the inspector it
                    // would have shown must not stay alive on the
                    // helper with nobody able to close it.
                    self.post(proto.ViewDestroy{ .view = ev.devtools });
                }
            },
            .ev_print_pdf_done => {
                const ev = proto.decode(proto.EvPrintPdfDone, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onPrintDone(ev.ok != 0, ev.path);
            },
            .ev_download_offer => {
                const ev = proto.decode(proto.EvDownloadOffer, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    face.onDownloadOffer(ev);
                } else {
                    // A held decision must always be answered; the pane
                    // that would ask is gone.
                    self.post(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" });
                }
            },
            .ev_cookies => {
                const ev = proto.EvCookies.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entries);
                if (self.findFace(ev.view)) |face| face.onCookies(ev);
            },
            .ev_sitedata_done => {
                const ev = proto.decode(proto.EvSitedataDone, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onSitedataDone(ev);
            },
            .ev_download_progress => {
                const ev = proto.decode(proto.EvDownloadProgress, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onDownloadProgress(ev);
            },
            else => {},
        }
    }
};

/// The one LOCAL helper connection of this GUI process. Module-level
/// and never freed — see the lifetime notes at the top of the file.
var g_client: Client = .{};

pub fn client() *Client {
    return &g_client;
}

/// Per-host remote helper clients, minted on first use and — like the
/// local one — NEVER freed: that immortality is the liveness fence for
/// every non-widget callback that carries a Client pointer.
var g_remote_clients: std.ArrayList(*Client) = .empty;

/// The client serving `host` ("" = the local one), created on demand.
/// Null only on allocation failure or an over-long host string.
pub fn clientForHost(gpa: std.mem.Allocator, host: []const u8) ?*Client {
    if (host.len == 0) return &g_client;
    for (g_remote_clients.items) |cl| {
        if (std.mem.eql(u8, cl.hostSlice(), host)) return cl;
    }
    const cl = gpa.create(Client) catch return null;
    cl.* = .{};
    if (host.len > cl.host.len) {
        gpa.destroy(cl);
        return null;
    }
    @memcpy(cl.host[0..host.len], host);
    cl.host_len = host.len;
    g_remote_clients.append(gpa, cl) catch {
        gpa.destroy(cl);
        return null;
    };
    return cl;
}

/// The client a face in `container` belongs on: a container with a
/// remote host gets that host's client, everything else the local one.
fn clientForContainer(gpa: std.mem.Allocator, container: u32) *Client {
    if (container != 0) {
        if (findContainer(container)) |ctn| {
            if (ctn.remote_host.len != 0) {
                if (clientForHost(gpa, ctn.remote_host)) |cl| return cl;
            }
        }
    }
    return &g_client;
}

/// Resolve a view id across every client — for widget callbacks whose
/// context carries only the id (download rows, print dialogs). View ids
/// are minted from ONE process-wide counter (`g_next_view`), so a
/// client-created view resolves unambiguously; only helper-minted
/// devtools ids could ever collide across helpers, and the local client
/// wins that lookup by order.
fn findFaceGlobal(view: u32) ?*WebFace {
    if (g_client.findFace(view)) |f| return f;
    for (g_remote_clients.items) |cl| {
        if (cl.findFace(view)) |f| return f;
    }
    return null;
}

/// Process-wide view-id mint (see `findFaceGlobal`).
var g_next_view: u32 = 1;

// ---------------------------------------------------------------------
// Containers — per-tab identity contexts (private cookie jar / cache,
// optional remote egress). The registry is process-wide, like the
// Client singleton; a container id is minted here, published to the
// helper as a `context_create`, and named by a face's `container` field.
// ---------------------------------------------------------------------

/// A small, visually distinct accent palette; the last entry is the
/// incognito preset's slate.
pub const container_palette = [_][3]u8{
    .{ 0x3b, 0x82, 0xf6 }, // blue
    .{ 0x22, 0xc5, 0x5e }, // green
    .{ 0xf5, 0x9e, 0x0b }, // amber
    .{ 0xef, 0x44, 0x44 }, // red
    .{ 0xa8, 0x55, 0xf7 }, // purple
    .{ 0x14, 0xb8, 0xa6 }, // teal
    .{ 0xec, 0x48, 0x99 }, // pink
    .{ 0x64, 0x74, 0x8b }, // slate (incognito)
};

pub const Container = struct {
    id: u32,
    name: []u8,
    color: [3]u8,
    ephemeral: bool,
    /// Fixed-server proxy url published to the helper ("" = direct). For
    /// an egress container this is `socks5://127.0.0.1:<bridge port>`.
    proxy: []u8,
    /// Egress host this container routes through ("" = none), shown in
    /// the UI.
    egress_host: []u8,
    /// Remote-helper host ("" = local): faces in this container run on
    /// a `sketerm-webengine` spawned by THAT host's mux daemon, frames
    /// inline over the wire — the browser IS there rather than proxied
    /// through there. Mutually exclusive with `egress_host`.
    remote_host: []u8,
    /// The live SOCKS5->mux bridge for an egress container, else null.
    egress: ?*socksbridge.Egress = null,
};

var g_containers: std.ArrayList(Container) = .empty;
var g_next_container_id: u32 = 1;

pub fn containers() []Container {
    return g_containers.items;
}

pub fn findContainer(id: u32) ?*Container {
    for (g_containers.items) |*ctn| {
        if (ctn.id == id) return ctn;
    }
    return null;
}

/// Accent color of a container, or null for the default context.
pub fn containerColor(id: u32) ?[3]u8 {
    if (id == 0) return null;
    if (findContainer(id)) |ctn| return ctn.color;
    return null;
}

/// Create a container. `egress_host` empty = local/direct; non-empty
/// spins a loopback SOCKS5 bridge that relays over the mux daemon to
/// that host (remote DNS), and the container's proxy points at it.
/// Returns the new id (0 on allocation failure).
pub fn createContainer(
    gpa: std.mem.Allocator,
    name: []const u8,
    ephemeral: bool,
    egress_host: []const u8,
) u32 {
    return createContainerFull(gpa, name, ephemeral, egress_host, "");
}

/// Container whose views RUN on `remote_host`: the helper is spawned by
/// that host's mux daemon (`web_helper_open`) and its frames arrive
/// inline over the wire — pages render, resolve and store cookies THERE.
/// The stronger sibling of an egress container, which only proxies.
pub fn createRemoteContainer(
    gpa: std.mem.Allocator,
    name: []const u8,
    ephemeral: bool,
    remote_host: []const u8,
) u32 {
    return createContainerFull(gpa, name, ephemeral, "", remote_host);
}

fn createContainerFull(
    gpa: std.mem.Allocator,
    name: []const u8,
    ephemeral: bool,
    egress_host: []const u8,
    remote_host: []const u8,
) u32 {
    const id = g_next_container_id;
    const color = if (ephemeral)
        container_palette[container_palette.len - 1]
    else
        container_palette[(g_containers.items.len) % (container_palette.len - 1)];

    const name_owned = gpa.dupe(u8, name) catch return 0;
    const host_owned = gpa.dupe(u8, egress_host) catch {
        gpa.free(name_owned);
        return 0;
    };
    const remote_owned = gpa.dupe(u8, remote_host) catch {
        gpa.free(name_owned);
        gpa.free(host_owned);
        return 0;
    };
    var proxy_owned: []u8 = gpa.dupe(u8, "") catch {
        gpa.free(name_owned);
        gpa.free(host_owned);
        gpa.free(remote_owned);
        return 0;
    };
    var egress: ?*socksbridge.Egress = null;
    if (egress_host.len != 0) {
        if (socksbridge.Egress.create(gpa, egress_host, mux_cli.muxConnect)) |eg| {
            eg.spawn();
            egress = eg;
            gpa.free(proxy_owned);
            proxy_owned = std.fmt.allocPrint(gpa, "socks5://127.0.0.1:{d}", .{eg.port()}) catch blk: {
                break :blk gpa.dupe(u8, "") catch unreachable;
            };
        }
    }

    g_containers.append(gpa, .{
        .id = id,
        .name = name_owned,
        .color = color,
        .ephemeral = ephemeral,
        .proxy = proxy_owned,
        .egress_host = host_owned,
        .remote_host = remote_owned,
        .egress = egress,
    }) catch {
        if (egress) |eg| {
            eg.stop();
            eg.destroy();
        }
        gpa.free(name_owned);
        gpa.free(host_owned);
        gpa.free(remote_owned);
        gpa.free(proxy_owned);
        return 0;
    };
    g_next_container_id += 1;
    // Publish to every live helper at once; a helper that starts later
    // gets the whole set replayed by `publishContexts` on connect.
    publishOne(client(), &g_containers.items[g_containers.items.len - 1]);
    for (g_remote_clients.items) |cl| publishOne(cl, &g_containers.items[g_containers.items.len - 1]);
    return id;
}

/// One-shot incognito preset: a throwaway ephemeral container.
pub fn createIncognito(gpa: std.mem.Allocator) u32 {
    return createContainer(gpa, "Incognito", true, "");
}

fn publishOne(cl: *Client, ctn: *const Container) void {
    if (cl.state != .ready) return;
    cl.post(proto.ContextCreate{
        .id = ctn.id,
        .ephemeral = if (ctn.ephemeral) 1 else 0,
        .name = ctn.name,
        // An egress proxy url names a LOOPBACK bridge port of THIS
        // machine; on a remote helper that loopback is the remote host's
        // own, so the proxy is stripped there (a remote container's
        // egress IS the remote host).
        .proxy = if (cl.isRemote()) "" else ctn.proxy,
    });
}

/// Re-publish every container to a (possibly fresh) helper, BEFORE its
/// faces re-create their views.
fn publishContexts(cl: *Client) void {
    for (g_containers.items) |*ctn| publishOne(cl, ctn);
}

// ---------------------------------------------------------------------
// WebFace
// ---------------------------------------------------------------------

// ---------------------------------------------------------------------
// Automation (the `web_*` MCP tools ride this)
// ---------------------------------------------------------------------

/// One kind of semantic round trip. At most ONE of each kind may be in
/// flight per view: the reply frames carry no request id (the protocol
/// correlates by view), so two overlapping evals could not be told
/// apart — and an awaited promise can settle out of order.
pub const AutoKind = enum { snapshot, act, expand, query, read, eval, network };

const AutoOp = struct {
    token: u32,
    kind: AutoKind,
    /// A `mode:full` snapshot is not satisfied by a spontaneous delta.
    want_full: bool = false,
    started_ms: i64 = 0,
};

/// How long an unanswered request blocks its kind. A page that never
/// answers (a wedged renderer, a promise that outlives its view) must
/// not lock the kind out for the life of the tab.
const AUTO_STALE_MS: i64 = 120_000;

/// Extra fields a snapshot reply carries; zero for every other kind.
pub const AutoMeta = struct {
    doc_gen: u32 = 0,
    rev: u32 = 0,
    snap_kind: u8 = 0,
};

/// A finished round trip, waiting to be collected by `autoTake`. `text`
/// is owned by the face until taken, then by the caller.
pub const AutoResult = struct {
    token: u32,
    kind: AutoKind,
    ok: bool,
    text: []u8,
    meta: AutoMeta = .{},
};

/// Completed results a face keeps before dropping the oldest. A caller
/// that never collects is a caller that crashed; the cap keeps that
/// from growing without bound.
const MAX_AUTO_RESULTS = 16;

/// CSS class dimming a discarded view's LAST frame, so the pane still
/// shows what the page looked like while reading as not-live. Subtle on
/// purpose: it is the same content, one keystroke from being real
/// again, not an error state.
const DISCARDED_CLASS = "sketerm-web-discarded";

/// Page background for the view area (what a browser shows where
/// nothing painted; also the gutter during a live resize). Theme's view
/// background rather than white, so a dark theme does not flash: a page
/// that paints its own background covers this anyway.
///
/// The two SECURITY surfaces are styled here too, and deliberately do
/// NOT follow the theme: an interstitial that a page could imitate is
/// worth less than one that always looks the same.
const WEBFACE_CSS =
    \\.sketerm-webview { background: @view_bg_color; }
    \\.sketerm-web-discarded { opacity: 0.65; }
    \\.sketerm-web-interstitial { background: #2b1416; color: #ffffff; padding: 24px; }
    \\.sketerm-web-interstitial label { color: #ffffff; }
    \\.sketerm-web-interstitial .title { font-size: 1.6em; font-weight: bold; }
    \\.sketerm-web-interstitial .detail { color: #e0c8c8; font-family: monospace; font-size: 0.9em; }
    \\.sketerm-web-permbar { background: #303030; color: #ffffff; padding: 6px; }
    \\.sketerm-web-permbar label { color: #ffffff; }
    \\.sketerm-web-dlstrip { background: @headerbar_bg_color; padding: 3px 6px; }
    \\.sketerm-web-dlrow progressbar { min-width: 120px; }
;

fn webviewCss(widget: *c.GtkWidget) void {
    c.gtk_widget_add_css_class(widget, "sketerm-webview");
    cssutil.install("webface", widget, WEBFACE_CSS);
}

/// Cap on painted hint labels; a page listing more is a page nobody
/// hint-navigates past the first few hundred anyway.
const MAX_HINTS = 300;

/// One painted link hint: the semantic id it activates, the link
/// target (for the new-tab modifier), its label and its label widget.
/// `url`/`label` are owned by the face's allocator; the widget belongs
/// to the hints layer and dies with it.
const HintItem = struct {
    sid: u32,
    url: []u8,
    label: []u8,
    widget: *c.GtkWidget,
};

/// Hint-label look, installed once via cssutil. Named libadwaita
/// colors keep it legible in both themes.
fn webhintCss(widget: *c.GtkWidget) void {
    cssutil.install("webhint", widget,
        \\.sketerm-webhint {
        \\  background: @accent_bg_color;
        \\  color: @accent_fg_color;
        \\  border: 1px solid alpha(@accent_fg_color, 0.5);
        \\  border-radius: 4px;
        \\  padding: 0px 4px;
        \\  font-weight: 700;
        \\  font-size: 11px;
        \\  font-family: monospace;
        \\}
    );
}

/// `g_object_set_data_full` notify for a toast's owned path string.
fn freeToastPath(user: ?*anyopaque) callconv(.c) void {
    const p: [*:0]u8 = @ptrCast(user orelse return);
    std.heap.c_allocator.free(std.mem.span(p));
}

/// Refcounted mmap of a frame memfd. `GBytes` built over it hold a
/// reference each; the pages stay mapped until the last texture using
/// them is released.
const MapRef = struct {
    ptr: [*]align(std.heap.page_size_min) u8,
    len: usize,
    refs: u32,
    allocator: std.mem.Allocator,

    fn ref(self: *MapRef) *MapRef {
        self.refs += 1;
        return self;
    }

    fn unref(self: *MapRef) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        _ = c.munmap(self.ptr, self.len);
        self.allocator.destroy(self);
    }

    fn gbytesDestroy(user: ?*anyopaque) callconv(.c) void {
        cast.userData(MapRef, user).unref();
    }
};

/// One imported dma-buf pool buffer: the pool id and the GdkTexture
/// wrapping it (owned reference).
const DmabufEntry = struct {
    buf_id: u32 = 0,
    tex: ?*c.GdkTexture = null,
};

/// Descriptors owned by a built dmabuf texture, closed when GDK
/// releases it.
const DmabufFds = struct {
    fds: [proto.MAX_PLANES]c_int,
    n: u8,
    allocator: std.mem.Allocator,

    fn destroy(user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(DmabufFds, user);
        for (self.fds[0..self.n]) |fd| _ = c.close(fd);
        self.allocator.destroy(self);
    }
};

/// One download this face is tracking, as its strip row shows it. The
/// string slices are owned by the face's allocator; the widgets belong
/// to the strip and die with the pane.
const Download = struct {
    /// The helper's download id (engine-minted, process-unique).
    id: u32,
    name: []u8,
    /// LOCAL path being written: the user's pick for a local save, the
    /// staging file for a redirected (host:) save.
    path: []u8,
    /// Remote destination of a redirected save; empty host = local.
    remote_host: []u8,
    remote_path: []u8,
    /// Transfer-service ledger token of the handoff upload.
    upload_token: ?[]u8 = null,
    received: u64 = 0,
    total: u64 = 0,
    state: enum { downloading, uploading, done, failed } = .downloading,
    /// The user pressed Cancel: the terminal event removes the row
    /// instead of showing a failure the user asked for.
    canceled: bool = false,

    row: *c.GtkWidget,
    label: *c.GtkWidget,
    bar: *c.GtkWidget,
    status: *c.GtkWidget,
    cancel_btn: *c.GtkWidget,
    open_btn: *c.GtkWidget,
    reveal_btn: *c.GtkWidget,

    fn free(self: *Download, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.path);
        a.free(self.remote_host);
        a.free(self.remote_path);
        if (self.upload_token) |t| a.free(t);
        a.destroy(self);
    }
};

/// User-data for a download row's buttons: ids only, resolved through
/// the client registry at click time (the PrintCtx liveness fence).
/// Owned by the button via `cast.destroyCtx` (mechanism 1).
const DlBtnCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    id: u32,
};

/// User-data for a download's save dialog; the dialog outlives a pane
/// close by construction, so this carries ids, never the face.
const DlPickCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    id: u32,
    /// Suggested name (owned), the fallback when a pick has no leaf.
    name: []u8,

    fn free(self: *DlPickCtx) void {
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};

/// One permission prompt the helper is holding, as the banner shows it.
/// `origin` is owned by the face.
const PermPrompt = struct {
    prompt: u64,
    origin: []u8,
    types: u32,
};

/// A remembered Allow/Block for one origin and one exact permission
/// set. Matching is on the exact bits: a page that later asks for
/// camera alone has not been answered by a camera+microphone decision.
const SiteSetting = struct {
    origin: []u8,
    types: u32,
    allow: bool,
};

pub const WebFace = struct {
    allocator: std.mem.Allocator,
    pane: ?*Pane = null,
    /// The helper connection this face's view lives on: the process's
    /// local client, or a per-host remote client when the face's
    /// container names a remote host. Fixed at attach (the container is
    /// immutable) and always valid — clients are never freed.
    cl: *Client = undefined,
    /// Helper-side view id, allocated once and kept across helper
    /// restarts (a fresh helper knows no ids at all).
    view: u32 = 0,
    /// Identity context (container) this face's view lives in, 0 = the
    /// shared default. Assigned once at creation and immutable — a
    /// container is a private cookie jar / cache / egress, and the
    /// helper fixes it at `view_create`. Kept across helper restarts so
    /// a rebuilt view lands back in the same container.
    container: u32 = 0,
    /// True once `view_create` was sent on the CURRENT connection.
    view_live: bool = false,
    /// This face PRESENTS a view somebody else created (the inspector
    /// `devtools_show` minted): it never sends `view_create`, and it
    /// cannot be rebuilt on a fresh helper connection, because the id
    /// it holds means nothing to a helper that just started.
    attached: bool = false,

    root_box: *c.GtkWidget = undefined,
    /// The navigation bar. An attached view has no address of its own
    /// to steer, so its face hides the whole bar.
    bar: *c.GtkWidget = undefined,
    back_btn: *c.GtkWidget = undefined,
    fwd_btn: *c.GtkWidget = undefined,
    reload_btn: *c.GtkWidget = undefined,
    reader_btn: *c.GtkWidget = undefined,
    shell_btn: *c.GtkWidget = undefined,
    /// The toolbar hamburger; also the anchor its menu pops under.
    burger_btn: *c.GtkWidget = undefined,
    entry: *c.GtkWidget = undefined,
    overlay: *c.GtkWidget = undefined,
    view_area: *c.GtkWidget = undefined,
    /// Input-transparent GtkDrawingArea filling the overlay: GTK4's
    /// only clean allocation-change hook (wlapp.zig precedent).
    sensor: *c.GtkWidget = undefined,
    /// The frame itself: a GtkPicture presenting a GdkTexture in GTK's
    /// scene graph, top-left anchored at the frame's LOGICAL size and
    /// nudged onto the device pixel grid (see `snapAlignment`).
    picture: *c.GtkWidget = undefined,
    /// Alignment nudge currently applied as the picture's start/top
    /// margins, in logical px. Input coordinates subtract it.
    snap_dx: u16 = 0,
    snap_dy: u16 = 0,
    /// Whether `tex_prev` wraps the shm mapping (only then may the next
    /// software frame use it as GSK's update/diff base).
    tex_prev_is_shm: bool = false,
    status_box: *c.GtkWidget = undefined,
    status_label: *c.GtkWidget = undefined,
    /// Full-face certificate interstitial (overlay child, hidden until
    /// an `ev_cert_error` arrives) and the labels it fills in.
    cert_box: *c.GtkWidget = undefined,
    cert_title: *c.GtkWidget = undefined,
    cert_detail: *c.GtkWidget = undefined,
    /// Non-modal permission banner between the toolbar and the page.
    perm_bar: *c.GtkWidget = undefined,
    perm_label: *c.GtkWidget = undefined,
    /// Find-in-page bar (Ctrl+F): hidden until opened. Built by hand --
    /// this tree has no shared findbar helper yet.
    find_bar: *c.GtkWidget = undefined,
    find_entry: *c.GtkWidget = undefined,
    find_count: *c.GtkWidget = undefined,

    /// Mirrored AX tree + its AT-SPI projection (see the accessibility
    /// section below). Both heap-allocated and owned; null until the
    /// connect worker's handback adopts them.
    ax_tree: ?*axtree.Tree = null,
    ax_proj: ?*webproj.Proj = null,
    ax_watch: c.guint = 0,
    /// A bus-connect worker for this face is in flight; its idle
    /// handback resolves through the client's faces list, never
    /// through a stored pointer.
    ax_connecting: bool = false,

    /// Objects carrying signals whose user-data is this face. All are
    /// disconnected at the teardown choke point -- so the array must be
    /// big enough for every one of them: `track` silently drops what
    /// does not fit, and a dropped object keeps a handler pointing at a
    /// freed face. Count the `track` calls in `buildUi`,
    /// `buildCertOverlay`, `buildFindBar` and `wireInput` before
    /// shrinking it.
    signal_objs: [32]?*c.GObject = .{null} ** 32,
    signal_count: usize = 0,

    /// Refcounted read-only mapping of the helper's frame memfd. Each
    /// presented software frame's `GBytes` holds a reference, so
    /// replacing the buffer never unmaps pages a `GdkTexture` GSK still
    /// samples from — the texture keeps the OLD mapping alive until it
    /// is released.
    map: ?*MapRef = null,
    buf_id: u32 = 0,
    /// PHYSICAL geometry of the mapped buffer (the wire announces it).
    buf_w: u16 = 0,
    buf_h: u16 = 0,
    buf_stride: u32 = 0,

    /// The last texture handed to the picture: the `update_texture`
    /// GSK diffs the next software frame against (that diff is what
    /// keeps damage-rect economy — GSK uploads only the update region).
    tex_prev: ?*c.GdkTexture = null,
    /// LOGICAL size of the frame currently presented.
    frame_lw: u16 = 0,
    frame_lh: u16 = 0,
    /// Imported GPU pool buffers, keyed on the helper's pool buffer id.
    /// A `GdkDmabufTexture` samples the LIVE buffer, so re-presenting a
    /// cached entry shows the engine's newest pixels for free.
    dmabuf_tex: [8]DmabufEntry = @splat(.{}),
    /// One-shot warning for a driver/GTK that cannot import.
    dmabuf_import_warned: bool = false,

    /// Last size handed to the helper, in logical pixels.
    sent_w: u16 = 0,
    sent_h: u16 = 0,
    /// Last device scale handed to the helper, x1000. 1000 until the
    /// view widget is realized and a GdkSurface can be asked.
    sent_scale: u16 = 1000,
    /// Last `view_max_fps` sent on the CURRENT connection; the sentinel
    /// forces a send after every (re)create.
    sent_max_fps: u16 = 0xffff,
    /// The realized surface whose scale we watch, with a reference held
    /// (CLAUDE.md: a raw widget/surface pointer kept past the widget
    /// tree's lifetime must own one) plus its handler id.
    scale_surface: ?*c.GdkSurface = null,
    scale_handler: c.gulong = 0,
    /// Last pointer position in view coordinates — scroll events carry
    /// no coordinates of their own.
    last_x: i32 = 0,
    last_y: i32 = 0,

    /// Adaptive frame pacing (see the header). Nothing this view shows
    /// is painted unless this decides to ask for it.
    pacer: pace.Pacer = .{},
    /// GTK frame-clock tick id on `view_area`, 0 when not installed. It
    /// exists ONLY while the page is actively repainting and removes
    /// itself the moment it is not — an idle tick is a KWin crash, not
    /// a waste (see the header and `terminal_surface.zig`'s `tick_id`).
    tick_id: c_uint = 0,
    /// Slow GLib timeout (5Hz): the idle floor that notices a page
    /// starting to move, and the reason no tick is needed to do so.
    /// Armed for the face's whole on-screen life.
    idle_timer: c.guint = 0,
    /// Latency-probe timer (`SKETERM_WEB_LAT`), 0 when absent.
    lat_timer: c.guint = 0,
    /// Whether the view widget is mapped. A background tab is unmapped: it
    /// gets `view_hide` and is never asked for a frame.
    on_screen: bool = false,
    /// The helper destroyed this view's browser at our request
    /// (`view_discard`): the page is gone from memory, the LAST frame
    /// is still on the picture (dimmed), and the next map, focus or
    /// navigation revives it. False on a helper without `CAP_DISCARD`,
    /// which is never sent the frame at all.
    discarded: bool = false,
    /// One-shot GLib timeout counting the off-screen minutes down to a
    /// discard, 0 when not armed. Armed the moment the face leaves the
    /// screen and removed the moment it comes back, so a face that is
    /// looked at every few minutes never discards.
    ///
    /// Lifetime is the pacing timers' (mechanism 2): the face is its
    /// user-data and `stopDiscardTimer` runs at the single teardown
    /// choke point (`prepareDestroyCb`) and once more in `deinit`.
    discard_timer: c.guint = 0,

    /// A `devtools_show` is out and its `ev_devtools_view` has not
    /// landed; a second request would open nothing new.
    devtools_pending: bool = false,

    /// Address to open once the view exists (attach-time URL).
    pending_url: ?[]u8 = null,
    /// Current address, as last reported by the helper. Owned.
    url: ?[]u8 = null,
    loading: bool = false,
    crashed: bool = false,
    widgets_dead: bool = false,
    /// Main-frame load-finished counter, reported by `web-list`. A
    /// settle needs it because "not loading" is also true BEFORE the
    /// navigation it is waiting for has started.
    load_seq: u32 = 0,

    /// True while the helper is HOLDING a request on a certificate the
    /// interstitial is asking about. Exactly one decision goes back.
    cert_pending: bool = false,
    /// Set when this face cancelled a held request itself, so the load
    /// error the cancellation produces is not also shown as a failure
    /// (the interstitial already said what happened).
    cert_cancelled: bool = false,
    /// Permission prompts the helper is holding for this view, oldest
    /// first; the banner shows `[0]`. Bounded by the helper, which holds
    /// at most four per view.
    perm_queue: std.ArrayList(PermPrompt) = .empty,
    /// Decisions this face remembers for the rest of its life, keyed on
    /// (origin, permission bits). In-process only — persistence belongs
    /// to whatever `SiteSettingSink` is set.
    site_settings: std.ArrayList(SiteSetting) = .empty,

    /// Where the pane's tab title comes from while this face lives.
    title: ?[]u8 = null,
    can_back: bool = false,
    can_fwd: bool = false,

    /// USER zoom as the engine's log-scale level x100 (`set_zoom`):
    /// one Ctrl+= / Ctrl+- step is 100 (a 1.2x factor, the conventional
    /// browser step), Ctrl+0 resets to 0. Kept here so a helper restart
    /// re-applies it in `ensureView`.
    zoom_x100: i32 = 0,

    /// Origin of the current page (owned) — the per-site-settings key.
    /// Changes on committed navigation; a change triggers a stored-zoom
    /// lookup in the daemon web store.
    nav_origin: ?[]u8 = null,
    /// URL whose visit was recorded but whose title is still pending;
    /// the first matching title event files a history_title update.
    visit_url: ?[]u8 = null,

    /// Automation bookkeeping (see AutoKind): in-flight requests, their
    /// finished results, the last snapshot as sent by the helper, and
    /// the last eval result in full (what `web_expand [0]` pages).
    auto_ops: std.ArrayList(AutoOp) = .empty,
    auto_results: std.ArrayList(AutoResult) = .empty,
    auto_next: u32 = 1,

    /// Reader mode (src/ui/webreader.zig): the extracted article laid
    /// out as text ON TOP of the live page, which keeps running
    /// underneath so that leaving reader mode costs one visibility
    /// flip. Built on first use, then kept for the face's life.
    reader: ?*webreader.Reader = null,
    reader_active: bool = false,

    /// The address bar's suggestion dropdown (src/ui/omnibox.zig).
    /// Same lifetime shape as the reader: severed at the face's
    /// prepare-destroy choke point, destroyed in deinit. Null on an
    /// attached face (its nav bar is hidden) or when creation failed.
    omni: ?*omnibox.Omnibox = null,
    /// The `sem_read` round trip the reader is waiting on, so its reply
    /// can be told apart from an MCP `web_read` running at the same
    /// time (both are `AutoKind.read`, correlated by token).
    reader_token: ?u32 = null,
    /// True while the code is driving the toggle button itself, so the
    /// `toggled` handler does not act on its own state sync.
    reader_syncing: bool = false,

    last_snapshot: ?[]u8 = null,
    last_snapshot_meta: AutoMeta = .{},
    last_eval: ?[]u8 = null,

    /// Link-hints mode (`web_hints`). `hints_token` is the automation
    /// token of the in-flight `visible` query (0 when none); once the
    /// reply builds the overlay, `hints_active` turns the face's key
    /// controller into the label matcher and nothing leaks to the page
    /// or the chord table until Escape/activation.
    hints_items: std.ArrayList(HintItem) = .empty,
    hints_layer: ?*c.GtkWidget = null,
    hints_typed: [8]u8 = @splat(0),
    hints_typed_len: usize = 0,
    hints_token: u32 = 0,
    hints_active: bool = false,
    /// Request interception (capability "intercept"): per-view counters,
    /// freshened by the helper's coalesced `intercept_status` pushes.
    /// The blocked count drives the toolbar badge; the log is PULLED on
    /// demand through the `.network` auto op.
    net_enabled: bool = true,
    net_blocked: u32 = 0,
    net_total: u32 = 0,
    net_rules: u32 = 0,
    net_next_seq: u32 = 0,
    /// The shield toggle button and its label; the badge shows the
    /// blocked count for the current page.
    shield_btn: *c.GtkWidget = undefined,
    shield_label: *c.GtkWidget = undefined,

    /// Downloads this face started (capability "downloads"), shown as
    /// one compact strip row each, and the strip they live in (bottom
    /// of the pane, hidden while empty).
    downloads: std.ArrayList(*Download) = .empty,
    dl_strip: *c.GtkWidget = undefined,
    /// 2Hz poll while any download is in its send-to-host phase: the
    /// transfer service has no per-intent callback, and the strip only
    /// needs coarse progress. Mechanism 2, severed at the choke point
    /// like the pacing timers.
    dl_timer: c.guint = 0,
    /// Bookmark star: the id of the bookmark for the CURRENT address,
    /// or 0 when there is none. Refreshed from the store on every
    /// committed navigation, so it reflects what other windows did too.
    bookmark_id: u64 = 0,
    star_btn: *c.GtkWidget = undefined,
    /// This origin's stored popup override; `.inherit` follows the
    /// app-level `web_popup_policy`.
    site_popup: enum { inherit, allow, block } = .inherit,

    /// The padlock button left of the address entry and the popover it
    /// opens (src/ui/websiteinfo.zig). The popover is built on first
    /// use and owned by this face: severed at the prepare-destroy
    /// choke point, freed in `deinit`.
    site_btn: *c.GtkWidget = undefined,
    site_info: ?*websiteinfo.SiteInfo = null,
    /// The user accepted a certificate interstitial for the CURRENT
    /// origin, so "https" no longer means what the padlock would
    /// otherwise claim. Cleared on every origin change.
    cert_exception: bool = false,
    /// Correlation id for `cookies_req` / the mutating site-data
    /// frames. Client-allocated, monotonic per face.
    site_req_next: u32 = 1,

    // ---- attach / teardown ------------------------------------------

    /// Put a web face on `pane`. A pane already wearing one just gets
    /// `url` opened in it. Never fails on a missing helper: the face
    /// exists and explains itself.
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, url: ?[]const u8) !*WebFace {
        return attachOpts(allocator, pane, .{ .url = url });
    }

    /// Web face whose view lives in identity `container` (0 = default).
    pub fn attachContainer(allocator: std.mem.Allocator, pane: *Pane, url: ?[]const u8, container: u32) !*WebFace {
        return attachOpts(allocator, pane, .{ .url = url, .container = container });
    }

    /// Put a face on `pane` that PRESENTS an existing helper-side view
    /// instead of creating one — how the inspector `devtools_show`
    /// minted becomes a pane (`Window.openDevToolsSplit`).
    ///
    /// It is the same face and the same connection: `Client` is one
    /// helper process per GUI process, faces are found by view id in
    /// it, and every frame this face sends or receives rides the socket
    /// the source face already uses. Nothing is shared BETWEEN faces,
    /// so there is no ownership to hand over.
    pub fn attachView(allocator: std.mem.Allocator, pane: *Pane, view: u32, on: *Client) !*WebFace {
        return attachOpts(allocator, pane, .{ .existing_view = view, .on_client = on });
    }

    const Opts = struct {
        url: ?[]const u8 = null,
        /// Non-zero: present this helper-side view rather than mint one.
        existing_view: u32 = 0,
        /// Identity context (container) to create the view in, 0 =
        /// default. Immutable once the face exists.
        container: u32 = 0,
        /// Pinned client for an existing view (the SOURCE face's — a
        /// devtools view lives on the helper of the page it inspects).
        on_client: ?*Client = null,
        /// Add a PAGE to the pane's existing group instead of answering
        /// with the page already there. Set only by `attachPage`.
        as_page: bool = false,
        /// Page this one was opened from, for the group's tree nesting.
        opener: ?*WebFace = null,
    };

    /// Add a page to an existing group — the in-pane equivalent of
    /// opening a new tab. `opener` nests it under the page that asked.
    pub fn attachPage(
        allocator: std.mem.Allocator,
        g: *webgroup.Group,
        url: ?[]const u8,
        opener: ?*WebFace,
    ) !*WebFace {
        return attachOpts(allocator, g.pane, .{
            .url = url,
            .as_page = true,
            .opener = opener,
            // A new page inherits the container of the page it was
            // opened from: a link followed inside a container stays in
            // that container, which is the whole point of one.
            .container = if (opener) |op| op.container else blk: {
                const cur = g.active() orelse break :blk 0;
                break :blk cur.container;
            },
        });
    }

    fn attachOpts(allocator: std.mem.Allocator, pane: *Pane, opts: Opts) !*WebFace {
        if (!opts.as_page) {
            if (fromPane(pane)) |existing| {
                if (opts.url) |u| existing.navigate(u);
                pane.setWebVisible(true);
                return existing;
            }
        }
        // The pane holds a GROUP of pages; a first attach mints it.
        const grp = try webgroup.Group.ensure(allocator, pane);
        const self = try allocator.create(WebFace);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };
        self.pane = pane;
        self.container = opts.container;
        self.pacer.cap_fps = g_max_fps;
        if (opts.url) |u| self.pending_url = allocator.dupe(u8, u) catch null;

        self.buildUi();
        if (opts.existing_view != 0) c.gtk_widget_set_visible(self.bar, 0);
        c.gtk_widget_set_vexpand(self.root_box, 1);
        c.gtk_widget_set_hexpand(self.root_box, 1);
        grp.adopt(self, opts.opener, grp.childInsertPos()) catch {
            // The box never reached a parent, so its floating reference
            // is still the only one.
            _ = c.g_object_ref_sink(@ptrCast(self.root_box));
            c.g_object_unref(@ptrCast(self.root_box));
            if (self.pending_url) |u| allocator.free(u);
            allocator.destroy(self);
            return error.PaneHasNoWrapper;
        };
        pane.setWebVisible(true);

        // Link hints dispatch (input.zig `web_hints` / `hints_open`).
        // The fn is stateless — it resolves this face from the Pane on
        // every call — so no teardown path has to clear it.
        if (pane.input_ctx) |ictx| ictx.web_hints = webHintsSink;

        // Suggestion dropdown under the address bar. An attached view
        // hides the whole nav bar, so it gets none; a face without one
        // still navigates exactly as before.
        if (opts.existing_view == 0)
            self.omni = omnibox.Omnibox.create(allocator, self, self.entry) catch null;

        const cl = opts.on_client orelse clientForContainer(allocator, opts.container);
        self.cl = cl;
        cl.ensure(allocator);
        if (opts.existing_view != 0) {
            // The view already exists on the CURRENT connection: adopt
            // it, live, without a create. Its first `view_resize`
            // arrives from the sensor's allocation like any other.
            self.attached = true;
            self.view = opts.existing_view;
            self.view_live = cl.state == .ready;
            cl.register(self);
            if (cl.state != .ready) self.onDevToolsLost();
            return self;
        }
        self.view = g_next_view;
        g_next_view += 1;
        cl.register(self);
        switch (cl.state) {
            .ready => self.onClientReady(),
            .unavailable => self.onHelperUnavailable(cl.reason, cl.reason_retryable),
            else => self.setStatus("Starting the browser helper…", false),
        }
        return self;
    }

    /// The ACTIVE page of the browser on `pane`, if any. A pane holds
    /// a `WebGroup` of pages (src/ui/webgroup.zig); "the web face of
    /// this pane" is the one the group is showing, which is what every
    /// pane-scoped verb — navigate, zoom, find, screenshot, the MCP
    /// tools — means by it.
    pub fn fromPane(pane: *Pane) ?*WebFace {
        const grp = webgroup.Group.fromPane(pane) orelse return null;
        return grp.active();
    }

    /// The group this face is a page of, if it still has a pane.
    pub fn group(self: *WebFace) ?*webgroup.Group {
        const pane = self.pane orelse return null;
        return webgroup.Group.fromPane(pane);
    }

    /// Open `url` in a new tab FROM this page — a popup, a hint with
    /// the new-tab modifier, "Open Link in New Tab".
    ///
    /// Where that tab lands is the tree-sidebar rule: while the sidebar
    /// is the browser's tab surface it becomes a PAGE of this browser,
    /// nested under the page that opened it; otherwise it becomes a
    /// window tab nested under this one, as it always did.
    pub fn openInNewTab(self: *WebFace, url: ?[]const u8) void {
        const win = self.ownerWindow() orelse return;
        if (win.browserPagesInSidebar()) {
            if (self.group()) |g| {
                _ = g.newPage(url, self) catch {};
                return;
            }
        }
        win.newWebTabFrom(url, self.ownerPage()) catch {};
    }

    /// Snapshot for layout persistence. The address falls back to the
    /// attach-time one so a pane saved before the helper answered still
    /// restores its page.
    ///
    pub fn paneState(self: *WebFace, arena: std.mem.Allocator) !web_model.PaneState {
        const addr: []const u8 = self.url orelse self.pending_url orelse "";
        return .{
            .url = try arena.dupe(u8, addr),
            .zoom_level_x100 = @intCast(std.math.clamp(self.zoom_x100, zoom_min_x100, zoom_max_x100)),
        };
    }

    /// Re-apply a persisted zoom on restore. Setting the field before
    /// the view is live is enough: the connect path re-posts a nonzero
    /// zoom_x100, the same way a helper restart re-applies it.
    pub fn applyRestoredZoom(self: *WebFace, zoom_level_x100: i16) void {
        self.setZoomLevel(std.math.clamp(@as(i32, zoom_level_x100), zoom_min_x100, zoom_max_x100));
    }

    /// Phase one of the face teardown: sever everything that could
    /// still call into this face. Public because a face is now a PAGE
    /// of a `WebGroup` (src/ui/webgroup.zig), and the group — not the
    /// Pane — is what runs the two-phase teardown for each of them.
    pub fn prepareDestroy(self: *WebFace, widgets_dead: bool) void {
        self.widgets_dead = self.widgets_dead or widgets_dead;
        self.cancelHints();
        // Owned reference: safe from any teardown path, dead widgets
        // included, and the ONLY place the surface watch is severed
        // besides the area's own unrealize.
        self.detachScaleWatch();
        // The reader's own controllers carry the READER as user-data,
        // so the disconnect loop below (which matches on this face)
        // cannot reach them; its `sever` is the same mechanism applied
        // at the same choke point. The omnibox is the same shape.
        if (self.reader) |r| r.sever(self.widgets_dead);
        if (self.omni) |o| o.sever(self.widgets_dead);
        // Same shape for the site-info popover: unparenting it destroys
        // its rows, and so frees the row contexts their GDestroyNotify
        // owns, before anything else lets go.
        if (self.site_info) |si| si.sever(self.widgets_dead);
        // Same mechanism (2: sever at the single choke point) for the
        // pacing sources and the discard countdown, which carry this
        // face as user-data and are not signals, so the disconnect loop
        // below misses them.
        self.stopPacing();
        self.stopDiscardTimer();
        self.stopDlTimer();
        // The a11y bus watch carries this face as user-data too.
        self.axTeardown();
        // Mechanism 2: one disconnect for every widget/controller that
        // carries this face as user-data, at the single choke point.
        // Nothing here owns a GDestroyNotify — combining the two would
        // free the face at the first disconnect.
        if (!self.widgets_dead) {
            for (self.signal_objs[0..self.signal_count]) |obj| {
                if (obj) |o| _ = c.g_signal_handlers_disconnect_matched(
                    o,
                    c.G_SIGNAL_MATCH_DATA,
                    0,
                    0,
                    null,
                    null,
                    @ptrCast(self),
                );
            }
        }
        self.signal_count = 0;
        self.widgets_dead = true;
    }

    /// Raising the face focuses the page — except on a blank tab,
    /// where the address bar is the only useful target (what every
    /// browser does with a new tab).
    pub fn focusFace(self: *WebFace) void {
        if (self.widgets_dead) return;
        // Raising a pane whose page was discarded brings it back before
        // the user has to ask twice.
        self.reviveNow();
        // Raising the face re-asserts its title on the pane titlebar
        // (the flip cleared whatever the previous face had put there).
        self.applyPaneFaceTitle();
        if (self.reader_active) {
            if (self.reader) |r| r.focus();
            return;
        }
        // An attached view has no address bar to focus (the whole nav
        // bar is hidden), so the page always takes it.
        if (!self.attached and self.url == null and self.pending_url == null) {
            _ = c.gtk_widget_grab_focus(self.entry);
            return;
        }
        _ = c.gtk_widget_grab_focus(self.view_area);
    }

    /// This page became the group's current one: it now owns the pane
    /// titlebar and the window tab's title, both of which were showing
    /// the page being left behind.
    pub fn onRaised(self: *WebFace) void {
        if (self.widgets_dead) return;
        self.applyPaneFaceTitle();
        self.applyTabTitle();
        self.focusFace();
    }

    pub fn deinit(self: *WebFace) void {
        const cl = self.cl;
        if (self.view_live) cl.post(proto.ViewDestroy{ .view = self.view });
        cl.unregister(self);
        // Web-store replies resolve through this face: the deinit
        // choke point drops every pending callback (CLAUDE.md rule 2).
        webstore.cancelFor(@ptrCast(self));
        self.axTeardown();
        self.detachScaleWatch();
        self.stopPacing();
        if (self.reader) |r| {
            r.sever(self.widgets_dead);
            r.destroy();
            self.reader = null;
        }
        if (self.omni) |o| {
            o.sever(self.widgets_dead);
            o.destroy();
            self.omni = null;
        }
        if (self.site_info) |si| {
            si.sever(self.widgets_dead);
            si.destroy();
            self.site_info = null;
        }
        self.stopDiscardTimer();
        self.stopDlTimer();
        // The helper cancels this view's engine-side downloads when the
        // ViewDestroy above lands; a handed-off upload is the durable
        // transfer service's and deliberately survives the pane.
        for (self.downloads.items) |d| d.free(self.allocator);
        self.downloads.deinit(self.allocator);
        self.dropMap();
        self.cancelHints();
        self.hints_items.deinit(self.allocator);
        if (self.pending_url) |u| self.allocator.free(u);
        if (self.url) |u| self.allocator.free(u);
        if (self.title) |t| self.allocator.free(t);
        // The helper cancels whatever it still holds for a destroyed
        // view, so nothing is answered here — only freed.
        for (self.perm_queue.items) |p| self.allocator.free(p.origin);
        self.perm_queue.deinit(self.allocator);
        for (self.site_settings.items) |s| self.allocator.free(s.origin);
        self.site_settings.deinit(self.allocator);
        if (self.nav_origin) |o| self.allocator.free(o);
        if (self.visit_url) |u| self.allocator.free(u);
        self.autoClear();
        self.auto_ops.deinit(self.allocator);
        self.auto_results.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ---- automation -------------------------------------------------

    fn autoClear(self: *WebFace) void {
        for (self.auto_results.items) |r| self.allocator.free(r.text);
        self.auto_results.clearRetainingCapacity();
        self.auto_ops.clearRetainingCapacity();
        if (self.last_snapshot) |s| self.allocator.free(s);
        self.last_snapshot = null;
        self.last_snapshot_meta = .{};
        if (self.last_eval) |e| self.allocator.free(e);
        self.last_eval = null;
    }

    fn autoBusy(self: *WebFace, kind: AutoKind) bool {
        const now = clock.nowMs();
        var i: usize = 0;
        while (i < self.auto_ops.items.len) {
            if (now - self.auto_ops.items[i].started_ms > AUTO_STALE_MS) {
                _ = self.auto_ops.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        for (self.auto_ops.items) |op| {
            if (op.kind == kind) return true;
        }
        return false;
    }

    /// Register an in-flight request; null when the view cannot serve
    /// one right now, which the caller reports rather than hanging.
    fn autoBegin(self: *WebFace, kind: AutoKind, want_full: bool) ?u32 {
        if (!self.view_live) return null;
        // An agent driving a background tab must not be handed the
        // helper's "this view is discarded" answer when what it wants
        // is the page: revive first, so the request rides the reload
        // (a pending snapshot is re-issued at load end helper-side).
        // The helper's error reply stays the backstop for any client
        // that does not do this.
        self.reviveNow();
        if (self.autoBusy(kind)) return null;
        const token = self.auto_next;
        self.auto_next +%= 1;
        if (self.auto_next == 0) self.auto_next = 1;
        self.auto_ops.append(self.allocator, .{
            .token = token,
            .kind = kind,
            .want_full = want_full,
            .started_ms = clock.nowMs(),
        }) catch return null;
        return token;
    }

    /// Satisfy the oldest in-flight request of `kind`, if any.
    fn completeOp(self: *WebFace, kind: AutoKind, ok: bool, text: []const u8, meta: AutoMeta) void {
        var idx: ?usize = null;
        for (self.auto_ops.items, 0..) |op, i| {
            if (op.kind != kind) continue;
            if (kind == .snapshot and op.want_full and meta.snap_kind != 0) continue;
            idx = i;
            break;
        }
        const i = idx orelse return;
        const op = self.auto_ops.orderedRemove(i);
        const owned = self.allocator.dupe(u8, text) catch return;
        if (self.auto_results.items.len >= MAX_AUTO_RESULTS) {
            const old = self.auto_results.orderedRemove(0);
            self.allocator.free(old.text);
        }
        self.auto_results.append(self.allocator, .{
            .token = op.token,
            .kind = kind,
            .ok = ok,
            .text = owned,
            .meta = meta,
        }) catch self.allocator.free(owned);
    }

    /// True while `token` is still waiting on the helper.
    pub fn autoPending(self: *WebFace, token: u32) bool {
        for (self.auto_ops.items) |op| {
            if (op.token == token) return true;
        }
        return false;
    }

    /// Collect a finished result; the caller owns `text` from here.
    pub fn autoTake(self: *WebFace, token: u32) ?AutoResult {
        for (self.auto_results.items, 0..) |r, i| {
            if (r.token == token) return self.auto_results.orderedRemove(i);
        }
        return null;
    }

    pub fn autoSnapshot(self: *WebFace, mode: u8, detail: u8, scope: u32) ?u32 {
        const token = self.autoBegin(.snapshot, mode == @intFromEnum(proto.SnapMode.full) or scope != 0) orelse return null;
        self.promote();
        self.cl.post(proto.SemSnapshotReq{
            .view = self.view,
            .mode = mode,
            .detail = detail,
            .scope = scope,
        });
        return token;
    }

    pub fn autoAct(self: *WebFace, id: u32, action: u8, arg: []const u8) ?u32 {
        const token = self.autoBegin(.act, false) orelse return null;
        self.cl.post(proto.SemAction{ .view = self.view, .id = id, .action = action, .arg = arg });
        // The helper synthesizes real input for this; the paints it
        // causes still need somebody asking for frames.
        self.promote();
        return token;
    }

    pub fn autoExpand(self: *WebFace, id: u32, off: u32, len: u32) ?u32 {
        const token = self.autoBegin(.expand, false) orelse return null;
        self.cl.post(proto.SemExpand{ .view = self.view, .id = id, .off = off, .len = len });
        return token;
    }

    pub fn autoQuery(self: *WebFace, kind: u8, arg: []const u8) ?u32 {
        const token = self.autoBegin(.query, false) orelse return null;
        self.cl.post(proto.SemQueryReq{ .view = self.view, .kind = kind, .arg = arg });
        return token;
    }

    pub fn autoRead(self: *WebFace) ?u32 {
        const token = self.autoBegin(.read, false) orelse return null;
        self.cl.post(proto.SemRead{ .view = self.view });
        return token;
    }

    pub fn autoEval(self: *WebFace, code: []const u8, want_await: bool, timeout_ms: u32) ?u32 {
        const token = self.autoBegin(.eval, false) orelse return null;
        self.cl.post(proto.SemEval{
            .view = self.view,
            .flags = if (want_await) proto.eval_flag_await else 0,
            .timeout_ms = timeout_ms,
            .code = .{ .s = code },
        });
        return token;
    }

    /// Pull recent network-log entries (`intercept_log`), answered
    /// through the same token/`web-result` path the semantic ops use.
    pub fn autoNetworkLog(self: *WebFace, since: u32, max: u16) ?u32 {
        const token = self.autoBegin(.network, false) orelse return null;
        self.cl.post(proto.InterceptLogReq{ .view = self.view, .since = since, .max = max });
        return token;
    }

    /// Enable/disable blocking for THIS view (the per-site toggle). The
    /// daemon-side per-site store is a separate integration point (see
    /// `netStoreApply`); this only moves the live helper state.
    pub fn setNetwork(self: *WebFace, enabled: bool) void {
        if (!self.view_live) return;
        self.net_enabled = enabled;
        self.cl.post(proto.InterceptSet{ .view = self.view, .enabled = if (enabled) 1 else 0 });
        self.updateShield();
    }

    pub fn netCounters(self: *WebFace) struct { enabled: bool, blocked: u32, total: u32, rules: u32 } {
        return .{ .enabled = self.net_enabled, .blocked = self.net_blocked, .total = self.net_total, .rules = self.net_rules };
    }

    /// A coalesced `intercept_status` arrived: refresh the badge.
    pub fn onInterceptStatus(self: *WebFace, ev: proto.InterceptStatus) void {
        self.net_enabled = ev.enabled != 0;
        self.net_blocked = ev.blocked;
        self.net_total = ev.total;
        self.net_rules = ev.rules;
        self.updateShield();
    }

    pub fn onInterceptLog(self: *WebFace, ev: proto.InterceptLog) void {
        self.net_next_seq = ev.next_seq;
        const json = proto.netLogJson(self.allocator, ev.next_seq, ev.entries) catch return;
        defer self.allocator.free(json);
        self.completeOp(.network, true, json, .{});
    }

    /// The daemon-side per-site store's entry point: called with the
    /// remembered decision for the page's site on every origin change
    /// (`onSiteReply`), including the "no override, back to the global
    /// default" case — a view walks many sites and the previous one's
    /// answer must not stick. Idempotent, so re-applying the default
    /// costs no round trip.
    pub fn netStoreApply(self: *WebFace, enabled: bool) void {
        if (enabled == self.net_enabled) return;
        self.setNetwork(enabled);
    }

    fn updateShield(self: *WebFace) void {
        if (self.widgets_dead) return;
        var buf: [32]u8 = undefined;
        const txt = if (!self.net_enabled)
            std.fmt.bufPrintZ(&buf, "off", .{}) catch "off"
        else if (self.net_blocked > 0)
            std.fmt.bufPrintZ(&buf, "{d}", .{self.net_blocked}) catch "0"
        else
            std.fmt.bufPrintZ(&buf, "0", .{}) catch "0";
        c.gtk_label_set_text(@ptrCast(self.shield_label), txt.ptr);
        self.refreshSiteInfo(false);
        var tip: [128]u8 = undefined;
        const t = std.fmt.bufPrintZ(&tip, "Content blocking: {s} ({d} blocked of {d} requests, {d} rules)", .{
            if (self.net_enabled) "on" else "off",
            self.net_blocked,
            self.net_total,
            self.net_rules,
        }) catch "Content blocking";
        c.gtk_widget_set_tooltip_text(self.shield_btn, t.ptr);
    }

    // ---- site info popover (permissions, cookies, site data) --------

    fn onSiteInfo(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        self.showSiteInfo();
    }

    /// Build the popover if it does not exist yet, refresh it from the
    /// live state and pop it up. A face whose widgets are gone does
    /// nothing.
    pub fn showSiteInfo(self: *WebFace) void {
        if (self.widgets_dead) return;
        if (self.site_info == null)
            self.site_info = websiteinfo.SiteInfo.create(self.allocator, self.view, self.site_btn);
        const info = self.site_info orelse return;
        self.refreshSiteInfo(true);
        // The cookie count is asynchronous: the popover shows
        // "counting" until the helper answers.
        _ = info;
        self.requestCookies();
    }

    /// Push the current state into an existing popover. `open` also
    /// pops it up.
    fn refreshSiteInfo(self: *WebFace, open: bool) void {
        const info = self.site_info orelse return;
        // Rebuilding the rows costs an allocation per row, so a closed
        // popover is left alone: it is refreshed when it opens.
        if (!open and !info.isOpen()) return;
        // Fixed capacity: the store keys decisions by exact permission
        // set, and a site with more than this many distinct sets is not
        // a site anybody is auditing row by row.
        var keys: [16][80]u8 = undefined;
        var perms: [16]websiteinfo.State.Perm = undefined;
        var n: usize = 0;
        const origin = self.nav_origin orelse "";
        if (origin.len != 0) {
            for (self.site_settings.items) |s| {
                if (n >= perms.len) break;
                if (!std.mem.eql(u8, s.origin, origin)) continue;
                const key = webstore.permKey(&keys[n], s.types) orelse continue;
                perms[n] = .{ .name = key, .allow = s.allow };
                n += 1;
            }
        }
        info.refresh(.{
            .origin = origin,
            .tls = self.tlsState(),
            .blocking = self.net_enabled,
            .blocked = self.net_blocked,
            .total = self.net_total,
            .perms = perms[0..n],
            .sitedata = client().cap_sitedata and self.view_live,
        }, open);
    }

    fn tlsState(self: *const WebFace) websiteinfo.Tls {
        const url = self.url orelse return .none;
        if (std.mem.startsWith(u8, url, "https://"))
            return if (self.cert_exception) .exception else .secure;
        if (std.mem.startsWith(u8, url, "http://")) return .insecure;
        return .none;
    }

    /// The padlock reflects the connection at a glance; the popover
    /// spells it out.
    fn updateSiteButton(self: *WebFace) void {
        if (self.widgets_dead) return;
        const tls = self.tlsState();
        const icon: [*:0]const u8 = switch (tls) {
            .none => "text-x-generic-symbolic",
            .insecure => "channel-insecure-symbolic",
            .secure => "channel-secure-symbolic",
            .exception => "dialog-warning-symbolic",
        };
        toolbtn.setIcon(self.site_btn, self.bar, icon, "Site");
        self.refreshSiteInfo(false);
    }

    fn nextSiteReq(self: *WebFace) u32 {
        const r = self.site_req_next;
        self.site_req_next +%= 1;
        if (self.site_req_next == 0) self.site_req_next = 1;
        return r;
    }

    /// Ask the helper what this site has stored. Silently does nothing
    /// on a helper without the capability — the popover hides the
    /// section it would fill.
    pub fn requestCookies(self: *WebFace) void {
        const info = self.site_info orelse return;
        if (!self.view_live or !client().cap_sitedata) return;
        const req = self.nextSiteReq();
        info.noteCookieRequest(req);
        client().post(proto.CookiesReq{ .view = self.view, .req = req, .url = "" });
    }

    pub fn deleteCookie(self: *WebFace, name: []const u8) void {
        if (!self.view_live or !client().cap_sitedata) return;
        client().post(proto.CookieDelete{
            .view = self.view,
            .req = self.nextSiteReq(),
            .url = "",
            .name = name,
        });
    }

    pub fn clearCookies(self: *WebFace) void {
        if (!self.view_live or !client().cap_sitedata) return;
        client().post(proto.CookiesClear{ .view = self.view, .req = self.nextSiteReq(), .url = "" });
    }

    /// Everything: cookies, the origin's script-visible storage, and
    /// the HTTP cache. The helper reports what it could not do exactly
    /// as asked in `EvSitedataDone.detail`.
    pub fn clearSiteData(self: *WebFace) void {
        if (!self.view_live or !client().cap_sitedata) return;
        client().post(proto.SitedataClear{
            .view = self.view,
            .req = self.nextSiteReq(),
            .url = "",
            .what = proto.sitedata_cookies | proto.sitedata_storage | proto.sitedata_cache,
        });
    }

    /// Forget one remembered permission decision, in this process AND
    /// in the daemon store, so the next request prompts again.
    pub fn forgetSitePermission(self: *WebFace, key: []const u8) void {
        const origin = self.nav_origin orelse return;
        const types = webstore.permTypes(key) orelse return;
        var i: usize = 0;
        while (i < self.site_settings.items.len) {
            const s = self.site_settings.items[i];
            if (s.types == types and std.mem.eql(u8, s.origin, origin)) {
                self.allocator.free(s.origin);
                _ = self.site_settings.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        webstore.siteSetPerm(self.allocator, origin, key, "");
        self.refreshSiteInfo(false);
    }

    /// The popover's blocking switch: same decision as the toolbar
    /// shield, so it stores the same override.
    pub fn setBlockingForSite(self: *WebFace, on: bool) void {
        self.setNetwork(on);
        if (self.nav_origin) |origin|
            webstore.siteSetBlock(self.allocator, origin, if (on) null else false);
        self.refreshSiteInfo(false);
    }

    pub fn onCookies(self: *WebFace, ev: proto.EvCookies) void {
        if (self.site_info) |info| info.onCookies(ev);
    }

    pub fn onSitedataDone(self: *WebFace, ev: proto.EvSitedataDone) void {
        if (self.site_info) |info| info.onSitedataDone(ev);
    }

    /// Wheel scrolling through the ORDINARY input path, at the last
    /// pointer position — the same frame an interactive scroll sends.
    pub fn autoScroll(self: *WebFace, dx: i32, dy: i32) bool {
        if (!self.view_live) return false;
        self.cl.post(proto.InputScroll{
            .view = self.view,
            .x = self.last_x,
            .y = self.last_y,
            .dx = dx,
            .dy = dy,
            .mods = 0,
        });
        self.promote();
        return true;
    }

    /// The last snapshot the helper sent, solicited or not.
    pub fn lastSnapshot(self: *WebFace) ?[]const u8 {
        return self.last_snapshot;
    }

    pub fn lastSnapshotMeta(self: *WebFace) AutoMeta {
        return self.last_snapshot_meta;
    }

    /// The full text of the last eval result, which a truncated tool
    /// reply pages through `web_expand [0]`.
    pub fn lastEval(self: *WebFace) ?[]const u8 {
        return self.last_eval;
    }

    // ---- link hints (the human skin over the semantic layer) --------

    /// Kick off link hints: ask the helper for the visible interactive
    /// elements (a `visible` semantic query — the same ids `web_act`
    /// clicks), then paint labels when the reply lands. Returns true
    /// when the chord is consumed; false only when this face cannot
    /// hint at all, so `hints_open` falls through to the terminal.
    pub fn startHints(self: *WebFace) bool {
        if (self.widgets_dead or !self.view_live) return false;
        if (self.hints_active) {
            // The chord toggles: hints-while-hinting means "never mind".
            self.cancelHints();
            return true;
        }
        if (self.hints_token != 0) return true; // request already out
        const token = self.autoBegin(.query, false) orelse return true;
        self.hints_token = token;
        // The viewport travels in the page's CSS px space: user zoom
        // shrinks the CSS viewport by its factor while the widget's
        // logical size stays put.
        const f = self.userZoomFactor();
        const vw: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(self.sent_w)) / f));
        const vh: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(self.sent_h)) / f));
        var buf: [32]u8 = undefined;
        const arg = std.fmt.bufPrint(&buf, "{d} {d}", .{ vw, vh }) catch return true;
        self.cl.post(proto.SemQueryReq{
            .view = self.view,
            .kind = @intFromEnum(proto.SemQuery.visible),
            .arg = arg,
        });
        // The matcher lives on the view area's key controller.
        _ = c.gtk_widget_grab_focus(self.view_area);
        self.promote();
        return true;
    }

    /// True when this query reply was a hints reply and is consumed
    /// here; false hands it to the automation bookkeeping untouched.
    pub fn onHintsResult(self: *WebFace, text: []const u8) bool {
        if (self.hints_token == 0) return false;
        for (self.auto_ops.items, 0..) |op, i| {
            if (op.token == self.hints_token) {
                _ = self.auto_ops.orderedRemove(i);
                break;
            }
        }
        self.hints_token = 0;
        self.buildHints(text);
        return true;
    }

    /// Parse the reply and paint one label per hint on a fresh overlay
    /// layer. Rects are page-logical px, which IS the widget's logical
    /// coordinate space — the inverse of the input mapping is just the
    /// `snap_dx/dy` pixel-grid nudge the picture is drawn under.
    fn buildHints(self: *WebFace, text: []const u8) void {
        self.cancelHints();
        if (self.widgets_dead or !self.on_screen) return;
        const parsed = (webhints.parse(self.allocator, text) catch return) orelse return;
        defer self.allocator.free(parsed);
        if (parsed.len == 0) return;
        const n = @min(parsed.len, MAX_HINTS);
        const labels = webhints.generateLabels(self.allocator, n, webhints.ALPHABET) catch return;
        var labels_moved: usize = 0;
        defer {
            for (labels[labels_moved..]) |l| self.allocator.free(l);
            self.allocator.free(labels);
        }

        webhintCss(self.view_area);
        const layer = c.gtk_fixed_new();
        c.gtk_widget_set_can_target(layer, 0);
        c.gtk_overlay_add_overlay(@ptrCast(self.overlay), layer);
        self.hints_layer = layer;

        const max_x: i32 = @max(0, @as(i32, self.sent_w) - 24);
        const max_y: i32 = @max(0, @as(i32, self.sent_h) - 16);
        // CSS px -> widget logical px: multiply the user-zoom factor
        // back in (DPR never appears — the wire is logical throughout).
        const f = self.userZoomFactor();
        for (parsed[0..n], 0..) |h, i| {
            const url = self.allocator.dupe(u8, h.url) catch break;
            var z: [16:0]u8 = @splat(0);
            const m = @min(labels[i].len, 15);
            @memcpy(z[0..m], labels[i][0..m]);
            const wgt = c.gtk_label_new(&z);
            c.gtk_widget_add_css_class(wgt, "sketerm-webhint");
            const zx: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(h.x)) * f));
            const zy: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(h.y)) * f));
            const x = std.math.clamp(zx + @as(i32, self.snap_dx), 0, max_x);
            const y = std.math.clamp(zy + @as(i32, self.snap_dy), 0, max_y);
            c.gtk_fixed_put(@ptrCast(layer), wgt, @floatFromInt(x), @floatFromInt(y));
            self.hints_items.append(self.allocator, .{
                .sid = h.sid,
                .url = url,
                .label = labels[i],
                .widget = wgt,
            }) catch {
                self.allocator.free(url);
                break;
            };
            labels_moved = i + 1;
        }
        if (self.hints_items.items.len == 0) {
            self.cancelHints();
            return;
        }
        self.hints_typed_len = 0;
        self.hints_active = true;
    }

    /// Take down the overlay and every owned hint string. Idempotent,
    /// safe with dead widgets, and it also orphans any reply still in
    /// flight (the automation bookkeeping absorbs it).
    fn cancelHints(self: *WebFace) void {
        if (self.hints_layer) |layer| {
            if (!self.widgets_dead) c.gtk_overlay_remove_overlay(@ptrCast(self.overlay), layer);
            self.hints_layer = null;
        }
        for (self.hints_items.items) |it| {
            self.allocator.free(it.url);
            self.allocator.free(it.label);
        }
        self.hints_items.clearRetainingCapacity();
        self.hints_typed_len = 0;
        self.hints_token = 0;
        self.hints_active = false;
    }

    /// The hints-mode key matcher. Consumes EVERY press — nothing may
    /// leak to the page or to the chord table while labels are up —
    /// and only Escape (or a dead-end prefix) leaves the mode.
    fn hintsKey(self: *WebFace, keyval: c.guint, state: c.GdkModifierType) c.gboolean {
        if (keyval == c.GDK_KEY_Escape) {
            self.cancelHints();
            return 1;
        }
        if (keyval == c.GDK_KEY_BackSpace) {
            if (self.hints_typed_len > 0) {
                self.hints_typed_len -= 1;
                self.refilterHints(false, false);
            }
            return 1;
        }
        const new_tab = (@as(c_uint, @intCast(state)) &
            (c.GDK_SHIFT_MASK | c.GDK_CONTROL_MASK)) != 0;
        if (keyval == c.GDK_KEY_Return or keyval == c.GDK_KEY_KP_Enter) {
            if (self.soleVisibleHint()) |i| self.activateHint(i, new_tab);
            return 1;
        }
        const lower = c.gdk_keyval_to_lower(keyval);
        if (lower >= 'a' and lower <= 'z' and
            std.mem.indexOfScalar(u8, webhints.ALPHABET, @intCast(lower)) != null)
        {
            if (self.hints_typed_len < self.hints_typed.len) {
                self.hints_typed[self.hints_typed_len] = @intCast(lower);
                self.hints_typed_len += 1;
            }
            self.refilterHints(true, new_tab);
            return 1;
        }
        // Everything else (bare modifiers included) is swallowed.
        return 1;
    }

    /// Show only the labels matching the typed prefix. A fully typed
    /// label activates (prefix-freedom makes that unambiguous); a
    /// prefix nothing matches ends the mode, like Vimium.
    fn refilterHints(self: *WebFace, allow_activate: bool, new_tab: bool) void {
        const typed = self.hints_typed[0..self.hints_typed_len];
        var visible: usize = 0;
        var exact: ?usize = null;
        for (self.hints_items.items, 0..) |it, i| {
            const match = std.mem.startsWith(u8, it.label, typed);
            if (!self.widgets_dead)
                c.gtk_widget_set_visible(it.widget, if (match) @as(c_int, 1) else 0);
            if (match) visible += 1;
            if (std.mem.eql(u8, it.label, typed)) exact = i;
        }
        if (!allow_activate) return;
        if (exact) |i| {
            self.activateHint(i, new_tab);
            return;
        }
        if (visible == 0) self.cancelHints();
    }

    fn soleVisibleHint(self: *WebFace) ?usize {
        const typed = self.hints_typed[0..self.hints_typed_len];
        var found: ?usize = null;
        for (self.hints_items.items, 0..) |it, i| {
            if (!std.mem.startsWith(u8, it.label, typed)) continue;
            if (found != null) return null;
            found = i;
        }
        return found;
    }

    /// Activate one hint: a link with the new-tab modifier opens its
    /// url in a fresh web tab (`newWebTabAt`, the popup path); anything
    /// else is a trusted click on the semantic id — byte-for-byte what
    /// MCP's `web_act` does.
    fn activateHint(self: *WebFace, idx: usize, new_tab: bool) void {
        const it = self.hints_items.items[idx];
        const sid = it.sid;
        var url_buf: [512]u8 = undefined;
        var url: []const u8 = "";
        if (it.url.len > 0 and it.url.len <= url_buf.len) {
            @memcpy(url_buf[0..it.url.len], it.url);
            url = url_buf[0..it.url.len];
        }
        self.cancelHints();
        if (new_tab and url.len > 0) {
            if (self.ownerWindow() != null) {
                self.openInNewTab(url);
                return;
            }
        }
        _ = self.autoAct(sid, @intFromEnum(proto.SemAct.click), "");
        self.promote();
    }

    /// PNG of the PAGE as the user sees it, for `screenshot_pane` /
    /// `web_screenshot`. The pane's own screenshot path renders the
    /// terminal surface, which on a web pane is the hidden shell
    /// underneath — so the face renders its view widget instead,
    /// with the same widget-paintable technique.
    pub fn screenshotPng(self: *WebFace) ?*c.GBytes {
        if (self.widgets_dead) return null;
        // Automation looking at the page counts as activity: the shot
        // itself is of whatever was last painted, but going active now
        // keeps a burst of them from each being an idle-floor tick old.
        self.promote();
        const w = self.overlay;
        const width = c.gtk_widget_get_width(w);
        const height = c.gtk_widget_get_height(w);
        if (width <= 0 or height <= 0) return null;
        const native = c.gtk_widget_get_native(w) orelse return null;
        const renderer = c.gtk_native_get_renderer(native) orelse return null;
        const paintable = c.gtk_widget_paintable_new(w) orelse return null;
        defer c.g_object_unref(paintable);
        const snapshot = c.gtk_snapshot_new();
        c.gdk_paintable_snapshot(
            @ptrCast(paintable),
            @ptrCast(snapshot),
            @floatFromInt(width),
            @floatFromInt(height),
        );
        const node = c.gtk_snapshot_free_to_node(snapshot) orelse return null;
        defer c.gsk_render_node_unref(node);
        var bounds = c.graphene_rect_t{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
        };
        const texture = c.gsk_renderer_render_texture(renderer, node, &bounds) orelse return null;
        defer c.g_object_unref(texture);
        return c.gdk_texture_save_to_png_bytes(texture);
    }

    /// Every `sem_snapshot` frame answers a request now: the helper
    /// coalesces spontaneous mutations into its shadow tree and pushes
    /// nothing for them (semantic.View.consume), so the old client-side
    /// delta-buffering is gone. `completeOp`'s want_full guard still
    /// drops a stray delta from a pre-coalescing helper.
    pub fn onSnapshot(self: *WebFace, ev: proto.SemSnapshot) void {
        const meta: AutoMeta = .{ .doc_gen = ev.doc_gen, .rev = ev.rev, .snap_kind = ev.kind };
        if (self.allocator.dupe(u8, ev.payload.s)) |owned| {
            if (self.last_snapshot) |old| self.allocator.free(old);
            self.last_snapshot = owned;
            self.last_snapshot_meta = meta;
        } else |_| {}
        self.completeOp(.snapshot, true, ev.payload.s, meta);
    }

    pub fn onEvalResult(self: *WebFace, ev: proto.SemEvalResult) void {
        if (self.allocator.dupe(u8, ev.json.s)) |owned| {
            if (self.last_eval) |old| self.allocator.free(old);
            self.last_eval = owned;
        } else |_| {}
        self.completeOp(.eval, ev.ok != 0, ev.json.s, .{});
    }

    /// Drop OUR reference to the frame mapping, and every GPU import
    /// keyed on the geometry it described. The picture keeps showing the
    /// last presented texture (whose own references keep what it needs
    /// alive) until a new frame replaces it.
    fn dropMap(self: *WebFace) void {
        if (self.map) |m| {
            m.unref();
            self.map = null;
        }
        self.clearDmabufCache();
        // The update chain must not diff a new buffer against a texture
        // built over the old one.
        if (self.tex_prev) |t| {
            c.g_object_unref(@ptrCast(t));
            self.tex_prev = null;
        }
        self.buf_id = 0;
        self.buf_w = 0;
        self.buf_h = 0;
    }

    fn clearDmabufCache(self: *WebFace) void {
        for (&self.dmabuf_tex) |*e| {
            if (e.tex) |t| c.g_object_unref(@ptrCast(t));
            e.* = .{};
        }
    }

    // ---- frame pacing ------------------------------------------------

    /// Ask the helper for one frame, now.
    fn requestFrame(self: *WebFace) void {
        if (!self.view_live or !self.on_screen) return;
        self.cl.post(proto.FrameRequest{ .view = self.view, .flags = 0 });
        if (g_stats.enabled()) g_stats.reqs += 1;
        if (g_lat.mode != .off and g_lat.pending and g_lat.req_us == 0)
            g_lat.req_us = c.g_get_monotonic_time();
        self.pacer.noteRequest(c.g_get_monotonic_time());
    }

    /// Ship the frame-rate cap the helper should apply — the configured
    /// `browser_max_fps` clamped to the CURRENT output's real refresh
    /// (`Pacer.effectiveFps`). The helper's internal scheduler paces
    /// paints with it (`set_windowless_frame_rate`); only changes are
    /// sent.
    fn syncMaxFps(self: *WebFace) void {
        if (!self.view_live) return;
        const want = self.pacer.effectiveFps();
        if (want == self.sent_max_fps) return;
        self.sent_max_fps = want;
        self.cl.post(proto.ViewMaxFps{ .view = self.view, .fps = want });
    }

    /// Go active: what every input, navigation and geometry change does.
    /// Idempotent and cheap, so callers never check state first.
    fn promote(self: *WebFace) void {
        const was_idle = self.pacer.promote();
        if (was_idle and paceLogging())
            std.debug.print("webface pace: view {d} idle -> active ({d} fps)\n", .{ self.view, self.pacer.effectiveFps() });
        self.ensureTick();
    }

    /// Install the frame-clock tick if it is not already running, and
    /// only while there is something on screen to pace. Modelled on
    /// `TerminalSurface.ensureTickRunning`; the counterpart that takes
    /// it away is `onTick` returning G_SOURCE_REMOVE, plus `stopTick`
    /// for the paths that end the pacing outright.
    fn ensureTick(self: *WebFace) void {
        if (self.tick_id != 0) return;
        if (self.widgets_dead or !self.on_screen) return;
        if (self.pacer.state != .active) return;
        self.tick_id = c.gtk_widget_add_tick_callback(
            self.view_area,
            @ptrCast(&onTick),
            @ptrCast(self),
            null,
        );
    }

    fn stopTick(self: *WebFace) void {
        if (self.tick_id == 0) return;
        if (!self.widgets_dead) c.gtk_widget_remove_tick_callback(self.view_area, self.tick_id);
        self.tick_id = 0;
    }

    /// Arm the idle floor. One 200ms timeout for the face's whole life;
    /// it is what notices a page starting to animate on its own, and it
    /// is deliberately NOT a tick.
    fn startIdleTimer(self: *WebFace) void {
        if (self.idle_timer != 0) return;
        const ms: c_uint = @intCast(@divTrunc(pace.Pacer.idleIntervalUs(), 1000));
        self.idle_timer = c.g_timeout_add(ms, @ptrCast(&onIdleTimer), @ptrCast(self));
    }

    /// End all pacing: tick gone, timeout gone, state reset. Idempotent,
    /// and safe to call with the widgets already finalized.
    fn stopPacing(self: *WebFace) void {
        self.stopTick();
        if (self.idle_timer != 0) {
            _ = c.g_source_remove(self.idle_timer);
            self.idle_timer = 0;
        }
        if (self.lat_timer != 0) {
            _ = c.g_source_remove(self.lat_timer);
            self.lat_timer = 0;
        }
        self.pacer.stop();
    }

    /// Arm the latency probe (measurement harness, env-gated).
    fn startLatProbe(self: *WebFace) void {
        if (!g_lat.enabled() or self.lat_timer != 0) return;
        const ms: c_uint = if (g_lat.mode == .fast) 100 else 700;
        self.lat_timer = c.g_timeout_add(ms, @ptrCast(&onLatTimer), @ptrCast(self));
    }

    fn onLatTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(WebFace, user);
        if (self.widgets_dead or !self.view_live) {
            self.lat_timer = 0;
            return 0;
        }
        if (self.sent_w < 200 or self.sent_h < 200) return 1;
        if (g_lat.pending) {
            std.debug.print(
                "weblat: {s} UNANSWERED after probe period (state {s}, {d} frames)\n",
                .{ if (g_lat.expect_hover) "hover" else "clear", @tagName(self.pacer.state), g_lat.frames_seen },
            );
        }
        g_lat.expect_hover = !g_lat.expect_hover;
        const x: f64 = if (g_lat.expect_hover) 60 else @floatFromInt(self.sent_w - 20);
        const y: f64 = @floatFromInt(self.sent_h / 2);
        g_lat.pending = true;
        g_lat.frames_seen = 0;
        g_lat.arrival_us = 0;
        g_lat.req_us = 0;
        g_lat.t_input_us = c.g_get_monotonic_time();
        self.sendPointer(.move, x, y, 0, 0, 0);
        return 1;
    }

    /// A paint landed: keep the view active, and wake it if the page
    /// started moving while nobody was touching it.
    fn notePaint(self: *WebFace) void {
        if (g_lat.mode != .off and g_lat.pending) {
            g_lat.frames_seen += 1;
            if (g_lat.arrival_us == 0) g_lat.arrival_us = c.g_get_monotonic_time();
        }
        if (self.pacer.notePaint() and paceLogging())
            std.debug.print("webface pace: view {d} idle -> active (paint)\n", .{self.view});
        self.ensureTick();
    }

    /// The page went on or off screen (tab switch, pane teardown). An
    /// off-screen page is not painted at all: `view_hide` stops the
    /// helper's own watchdog too, so nothing anywhere renders it — and
    /// after `web_discard_minutes` of that, the page is let go entirely.
    fn setOnScreen(self: *WebFace, on: bool) void {
        if (self.on_screen == on) return;
        self.on_screen = on;
        if (on) {
            if (paceLogging()) std.debug.print("webface pace: view {d} on screen\n", .{self.view});
            self.stopDiscardTimer();
            // `view_show` IS the revive frame, so the order below is
            // "clear our own discarded state, then show": the helper
            // recreates the browser and the buffer it announces lands
            // on a face that is no longer dimmed.
            self.noteRevived();
            if (self.view_live) self.cl.post(proto.ViewShow{ .view = self.view });
            self.startIdleTimer();
            self.startLatProbe();
            // A tab coming forward must show its current content at
            // once, not at the next idle tick.
            self.promote();
            return;
        }
        if (self.view_live) self.cl.post(proto.ViewHide{ .view = self.view });
        self.cancelHints();
        self.stopPacing();
        self.armDiscardTimer();
        if (paceLogging()) std.debug.print("webface pace: view {d} off screen (tick={d})\n", .{ self.view, self.tick_id });
    }

    // ---- tab discard --------------------------------------------------

    /// Start the off-screen countdown, if discarding is possible and
    /// configured. Idempotent; a face that is already discarded, has no
    /// view, or sits on a helper without the capability arms nothing.
    fn armDiscardTimer(self: *WebFace) void {
        if (self.discard_timer != 0 or self.discarded) return;
        if (g_discard_minutes == 0 or self.on_screen) return;
        if (!self.view_live or !self.cl.cap_discard) return;
        const ms: u64 = @as(u64, g_discard_minutes) * 60 * 1000;
        self.discard_timer = c.g_timeout_add(
            @intCast(@min(ms, std.math.maxInt(c_uint))),
            @ptrCast(&onDiscardTimer),
            @ptrCast(self),
        );
    }

    fn stopDiscardTimer(self: *WebFace) void {
        if (self.discard_timer == 0) return;
        _ = c.g_source_remove(self.discard_timer);
        self.discard_timer = 0;
    }

    /// The countdown ran out: let the page go. One-shot — a discarded
    /// face needs no timer, and a revived one arms a fresh one when it
    /// leaves the screen again.
    fn onDiscardTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(WebFace, user);
        self.discard_timer = 0;
        if (self.widgets_dead or self.on_screen) return 0; // G_SOURCE_REMOVE
        _ = self.discardNow();
        return 0; // G_SOURCE_REMOVE
    }

    /// Discard this face's page NOW. True when a `view_discard` went
    /// out, false when there was nothing to discard (no view, already
    /// discarded, helper too old).
    ///
    /// The last delivered frame deliberately STAYS on the picture: the
    /// pane keeps showing the page, dimmed, instead of going blank at a
    /// moment the user did not ask for anything. Only OUR reference to
    /// the shared mapping is dropped — the presented texture holds its
    /// own, so the pixels survive the memfd going away helper-side.
    pub fn discardNow(self: *WebFace) bool {
        if (self.discarded or !self.view_live) return false;
        const cl = self.cl;
        if (!cl.cap_discard) return false;
        self.stopDiscardTimer();
        cl.post(proto.ViewDiscard{ .view = self.view });
        self.discarded = true;
        self.auto_ops.clearRetainingCapacity();
        self.stopPacing();
        self.dropMap();
        // A fresh helper-side view knows no cap; the revival re-sends.
        self.sent_max_fps = 0xffff;
        if (!self.widgets_dead) c.gtk_widget_add_css_class(self.picture, DISCARDED_CLASS);
        if (paceLogging()) std.debug.print("webface pace: view {d} discarded\n", .{self.view});
        return true;
    }

    /// Undo the GUI half of a discard. The helper revives on the frame
    /// that follows (show, navigation or input), so this only clears
    /// what the face itself is holding — including the dim, which must
    /// go before the revived page's first frame lands under it.
    fn noteRevived(self: *WebFace) void {
        if (!self.discarded) return;
        self.discarded = false;
        if (!self.widgets_dead) c.gtk_widget_remove_css_class(self.picture, DISCARDED_CLASS);
        if (paceLogging()) std.debug.print("webface pace: view {d} revived\n", .{self.view});
    }

    /// Bring a discarded page back on purpose, with `view_show` as the
    /// waking frame. For a NAVIGATION use `noteRevived` instead: the
    /// navigate frame is itself a revive, and showing first would load
    /// the old address as an extra document.
    fn reviveNow(self: *WebFace) void {
        if (!self.discarded) return;
        self.noteRevived();
        if (self.view_live) self.cl.post(proto.ViewShow{ .view = self.view });
        self.promote();
    }

    // ---- device scale ----------------------------------------------

    /// The output's fractional device scale x1000.
    ///
    /// `gdk_surface_get_scale` is the only source that reports a REAL
    /// fractional scale (`gtk_widget_get_scale_factor` rounds 1.5 up to
    /// 2), and it needs a realized surface. Before realize there is
    /// none, and answering 1.0 there is how the FIRST buffer of every
    /// browser window came back 2.25x too few pixels on a 1.5x desktop —
    /// so an unrealized face asks a MONITOR instead, which is the same
    /// number for the overwhelmingly common single-scale desktop and a
    /// far better guess than 1.0 for the rest. The surface's own value
    /// replaces it at realize, `notify::scale` after that.
    fn currentScale(self: *WebFace) u16 {
        if (self.widgets_dead) return self.sent_scale;
        if (c.gtk_widget_get_native(self.view_area)) |native| {
            if (c.gtk_native_get_surface(native)) |surface| {
                const s = c.gdk_surface_get_scale(surface);
                if (s > 0.0) return clampScale(s);
            }
        }
        return self.monitorScale();
    }

    /// The scale of a monitor this widget's display actually has, for
    /// the pre-realize window. Falls back to the last value sent, which
    /// starts at 1.0 only when the display has no monitor at all.
    fn monitorScale(self: *WebFace) u16 {
        const display = c.gtk_widget_get_display(self.view_area) orelse return self.sent_scale;
        const monitors = c.gdk_display_get_monitors(display) orelse return self.sent_scale;
        const n = c.g_list_model_get_n_items(monitors);
        if (n == 0) return self.sent_scale;
        const item = c.g_list_model_get_item(monitors, 0) orelse return self.sent_scale;
        defer c.g_object_unref(item);
        const s = c.gdk_monitor_get_scale(@ptrCast(item));
        if (!(s > 0.0)) return self.sent_scale;
        return clampScale(s);
    }

    fn clampScale(s: f64) u16 {
        return @intFromFloat(std.math.clamp(@round(s * 1000.0), 250.0, 8000.0));
    }

    /// Watch the realized surface's scale so a drag to a differently
    /// scaled output re-renders at the new DPR.
    fn attachScaleWatch(self: *WebFace) void {
        if (self.widgets_dead) return;
        const native = c.gtk_widget_get_native(self.view_area) orelse return;
        const surface = c.gtk_native_get_surface(native) orelse return;
        if (self.scale_surface == surface) return;
        self.detachScaleWatch();
        _ = c.g_object_ref(@ptrCast(surface));
        self.scale_surface = surface;
        self.scale_handler = c.g_signal_connect_data(
            @ptrCast(surface),
            "notify::scale",
            @ptrCast(&onSurfaceScale),
            self,
            null,
            0,
        );
    }

    fn detachScaleWatch(self: *WebFace) void {
        const surface = self.scale_surface orelse return;
        if (self.scale_handler != 0) {
            c.g_signal_handler_disconnect(@ptrCast(surface), self.scale_handler);
            self.scale_handler = 0;
        }
        c.g_object_unref(@ptrCast(surface));
        self.scale_surface = null;
    }

    /// Re-send the view's geometry when the scale actually moved. The
    /// helper answers with a replacement buffer at the new physical
    /// size; the logical size is unchanged.
    fn syncScale(self: *WebFace) void {
        const scale = self.currentScale();
        if (scale == self.sent_scale) return;
        self.sent_scale = scale;
        if (!self.view_live or self.sent_w == 0 or self.sent_h == 0) return;
        self.cl.post(proto.ViewResize{
            .view = self.view,
            .w = self.sent_w,
            .h = self.sent_h,
            .scale_x1000 = scale,
        });
    }

    // ---- UI ---------------------------------------------------------

    fn track(self: *WebFace, obj: anytype) void {
        if (self.signal_count >= self.signal_objs.len) return;
        self.signal_objs[self.signal_count] = @ptrCast(@alignCast(obj));
        self.signal_count += 1;
    }

    fn buildUi(self: *WebFace) void {
        self.root_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

        // The file manager's toolbar is the reference look: same class,
        // same inset, same flat buttons, Back+Forward as one linked
        // control.
        const bar = toolbtn.newBar();
        self.bar = bar;
        toolbtn.installCss(bar);

        const navpair = toolbtn.newNavPair();
        self.back_btn = toolbtn.barButton(navpair, "go-previous-symbolic", "Back", "Back", &onBack, self);
        c.gtk_widget_set_sensitive(self.back_btn, 0);
        self.track(self.back_btn);

        self.fwd_btn = toolbtn.barButton(navpair, "go-next-symbolic", "Forward", "Forward", &onForward, self);
        c.gtk_widget_set_sensitive(self.fwd_btn, 0);
        self.track(self.fwd_btn);
        c.gtk_box_append(@ptrCast(bar), navpair);

        self.reload_btn = toolbtn.barButton(bar, "view-refresh-symbolic", "Reload", "Reload", &onReload, self);
        self.track(self.reload_btn);

        // Site button: the padlock every browser puts here, and the
        // only way back to a decision this site was once given.
        self.site_btn = toolbtn.barButton(
            bar,
            "channel-insecure-symbolic",
            "Site",
            "Site information, permissions and stored data",
            &onSiteInfo,
            self,
        );
        self.track(self.site_btn);

        self.entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(self.entry, 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(self.entry), "Enter an address");
        _ = c.g_signal_connect_data(@ptrCast(self.entry), "activate", @ptrCast(&onEntryActivate), self, null, 0);
        // `attach` already asks for the blank tab's address bar through
        // focusCb, but a face built before its window is presented
        // cannot take focus yet (grab_focus on an unmapped widget is a
        // no-op) — the first `sketerm web` tab is exactly that case.
        // Re-asking on map is the fix; the "still blank" test keeps it
        // from stealing focus from a page later on.
        _ = c.g_signal_connect_data(@ptrCast(self.entry), "map", @ptrCast(&onEntryMap), self, null, 0);
        self.track(self.entry);
        c.gtk_box_append(@ptrCast(bar), self.entry);

        // Bookmark star. A plain button, not a toggle: its pressed
        // look would have to be driven from an async store reply, and
        // a toggle that flips itself back a moment later reads as a
        // bug. The ICON carries the state instead.
        self.star_btn = toolbtn.barButton(bar, "non-starred-symbolic", "Bookmark", "Bookmark this page", &onStar, self);
        self.track(self.star_btn);

        // Reader mode. A toggle, because it is a state of the pane and
        // not an action: pressed = the article is showing.
        self.reader_btn = toolbtn.barToggle(
            bar,
            "sketerm-reader-symbolic",
            "Reader",
            "Reader view (the page's article as plain text)",
            &onReaderToggled,
            self,
        );
        self.track(self.reader_btn);
        // Content-blocking shield: a flat button carrying the
        // blocked-count badge for the current page, styled like the
        // rest of the toolbar chrome. Clicking it toggles blocking for
        // this view. A plain button (not a toggle) so a programmatic
        // counter refresh never re-fires a "toggled" handler.
        self.shield_btn = c.gtk_button_new().?;
        const shield_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_box_append(@ptrCast(shield_row), toolbtn.iconOrText(bar, "security-high-symbolic", "Block"));
        self.shield_label = c.gtk_label_new("0");
        c.gtk_box_append(@ptrCast(shield_row), self.shield_label);
        c.gtk_button_set_child(@ptrCast(self.shield_btn), shield_row);
        c.gtk_widget_set_tooltip_text(self.shield_btn, "Content blocking");
        toolbtn.flatten(self.shield_btn);
        _ = c.g_signal_connect_data(@ptrCast(self.shield_btn), "clicked", @ptrCast(&onShield), self, null, 0);
        self.track(self.shield_btn);
        c.gtk_box_append(@ptrCast(bar), self.shield_btn);

        // `sketerm-terminal-symbolic` is one of our own bundled icons,
        // but it goes through the fallback like every other name: a
        // theme chain that cannot draw it must not leave the way out
        // of the browser as an invisible button.
        self.shell_btn = toolbtn.barButton(bar, "sketerm-terminal-symbolic", "Shell", "Show this pane's shell", &onShowShell, self);
        self.track(self.shell_btn);

        // The hamburger is END-MOST on every sketerm toolbar. Its menu
        // is built fresh per open (every row's sensitivity depends on
        // the page's current state), the classicmenu way.
        self.burger_btn = toolbtn.barButton(bar, "open-menu-symbolic", "Menu", "Main Menu", &onBurger, self);
        self.track(self.burger_btn);

        c.gtk_box_append(@ptrCast(self.root_box), bar);

        // NON-MODAL by construction: a strip in the pane's own box, so
        // the page below stays live and the rest of the window keeps
        // working while a prompt is up. A permission request is not
        // worth a dialog that blocks the terminal behind it.
        self.perm_bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_add_css_class(self.perm_bar, "sketerm-web-permbar");
        self.perm_label = c.gtk_label_new("");
        c.gtk_label_set_wrap(@ptrCast(self.perm_label), 1);
        c.gtk_label_set_xalign(@ptrCast(self.perm_label), 0);
        c.gtk_widget_set_hexpand(self.perm_label, 1);
        c.gtk_box_append(@ptrCast(self.perm_bar), self.perm_label);
        const allow_btn = c.gtk_button_new_with_label("Allow");
        c.gtk_widget_add_css_class(allow_btn, "suggested-action");
        _ = c.g_signal_connect_data(@ptrCast(allow_btn), "clicked", @ptrCast(&onPermAllow), self, null, 0);
        self.track(allow_btn);
        c.gtk_box_append(@ptrCast(self.perm_bar), allow_btn);
        const block_btn = c.gtk_button_new_with_label("Block");
        _ = c.g_signal_connect_data(@ptrCast(block_btn), "clicked", @ptrCast(&onPermBlock), self, null, 0);
        self.track(block_btn);
        c.gtk_box_append(@ptrCast(self.perm_bar), block_btn);
        c.gtk_widget_set_visible(self.perm_bar, 0);
        c.gtk_box_append(@ptrCast(self.root_box), self.perm_bar);

        // Find-in-page bar (Ctrl+F), hidden until opened. Same toolbar
        // styling as the address bar above it.
        self.find_bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_add_css_class(self.find_bar, "toolbar");
        c.gtk_widget_set_margin_start(self.find_bar, 4);
        c.gtk_widget_set_margin_end(self.find_bar, 4);
        c.gtk_widget_set_margin_bottom(self.find_bar, 4);

        self.find_entry = c.gtk_search_entry_new();
        c.gtk_widget_set_hexpand(self.find_entry, 1);
        c.gtk_search_entry_set_placeholder_text(@ptrCast(self.find_entry), "Find in page");
        _ = c.g_signal_connect_data(@ptrCast(self.find_entry), "search-changed", @ptrCast(&onFindChanged), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.find_entry), "activate", @ptrCast(&onFindActivate), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.find_entry), "next-match", @ptrCast(&onFindNextSig), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.find_entry), "previous-match", @ptrCast(&onFindPrevSig), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.find_entry), "stop-search", @ptrCast(&onFindStopSig), self, null, 0);
        self.track(self.find_entry);
        c.gtk_box_append(@ptrCast(self.find_bar), self.find_entry);

        self.find_count = c.gtk_label_new("");
        c.gtk_widget_add_css_class(self.find_count, "dim-label");
        c.gtk_box_append(@ptrCast(self.find_bar), self.find_count);

        const find_prev = c.gtk_button_new_from_icon_name("go-up-symbolic");
        c.gtk_widget_set_tooltip_text(find_prev, "Previous match");
        _ = c.g_signal_connect_data(@ptrCast(find_prev), "clicked", @ptrCast(&onFindPrevClicked), self, null, 0);
        self.track(find_prev);
        c.gtk_box_append(@ptrCast(self.find_bar), find_prev);

        const find_next = c.gtk_button_new_from_icon_name("go-down-symbolic");
        c.gtk_widget_set_tooltip_text(find_next, "Next match");
        _ = c.g_signal_connect_data(@ptrCast(find_next), "clicked", @ptrCast(&onFindNextClicked), self, null, 0);
        self.track(find_next);
        c.gtk_box_append(@ptrCast(self.find_bar), find_next);

        const find_close = c.gtk_button_new_from_icon_name("window-close-symbolic");
        c.gtk_widget_set_tooltip_text(find_close, "Close find bar");
        _ = c.g_signal_connect_data(@ptrCast(find_close), "clicked", @ptrCast(&onFindCloseClicked), self, null, 0);
        self.track(find_close);
        c.gtk_box_append(@ptrCast(self.find_bar), find_close);

        c.gtk_widget_set_visible(self.find_bar, 0);
        c.gtk_box_append(@ptrCast(self.root_box), self.find_bar);

        self.overlay = c.gtk_overlay_new();
        c.gtk_widget_set_hexpand(self.overlay, 1);
        c.gtk_widget_set_vexpand(self.overlay, 1);

        // The INPUT surface: a plain focusable widget filling the
        // overlay. It owns focus, the cursor and every controller; the
        // pixels live on `picture`, a separate overlay child, so that
        // the frame can sit at its own exact size and alignment without
        // input ever missing the pane.
        self.view_area = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        webviewCss(self.view_area);
        c.gtk_widget_set_hexpand(self.view_area, 1);
        c.gtk_widget_set_vexpand(self.view_area, 1);
        c.gtk_widget_set_focusable(self.view_area, 1);
        // A realized widget has a surface whose scale can be asked; a
        // reparent unrealizes, so every realize re-attaches the watch.
        _ = c.g_signal_connect_data(@ptrCast(self.view_area), "realize", @ptrCast(&onAreaRealize), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.view_area), "unrealize", @ptrCast(&onAreaUnrealize), self, null, 0);
        // Map/unmap IS the on-screen signal: a background tab's pane is
        // unmapped, and a page nobody can see must not be painted.
        _ = c.g_signal_connect_data(@ptrCast(self.view_area), "map", @ptrCast(&onAreaMap), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.view_area), "unmap", @ptrCast(&onAreaUnmap), self, null, 0);
        self.track(self.view_area);
        c.gtk_overlay_set_child(@ptrCast(self.overlay), self.view_area);
        self.wireInput();

        // The frame. PLACED, never stretched: its size request is the
        // frame's logical size, so a mismatch during a live resize shows
        // as a one-frame gutter rather than a stretch (the old
        // `web_pass` contract, kept). `clip_overlay` keeps an oversized
        // frame from growing the pane. Input-transparent — the box
        // below it takes the events.
        self.picture = c.gtk_picture_new();
        c.gtk_picture_set_content_fit(@ptrCast(self.picture), c.GTK_CONTENT_FIT_FILL);
        c.gtk_widget_set_halign(self.picture, c.GTK_ALIGN_START);
        c.gtk_widget_set_valign(self.picture, c.GTK_ALIGN_START);
        c.gtk_widget_set_can_target(self.picture, 0);
        self.track(self.picture);
        c.gtk_overlay_add_overlay(@ptrCast(self.overlay), self.picture);
        c.gtk_overlay_set_clip_overlay(@ptrCast(self.overlay), self.picture, 1);

        self.sensor = c.gtk_drawing_area_new();
        c.gtk_widget_set_can_target(self.sensor, 0);
        c.gtk_widget_set_hexpand(self.sensor, 1);
        c.gtk_widget_set_vexpand(self.sensor, 1);
        _ = c.g_signal_connect_data(@ptrCast(self.sensor), "resize", @ptrCast(&onResize), self, null, 0);
        self.track(self.sensor);
        c.gtk_overlay_add_overlay(@ptrCast(self.overlay), self.sensor);

        self.status_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
        c.gtk_widget_set_halign(self.status_box, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(self.status_box, c.GTK_ALIGN_CENTER);
        self.status_label = c.gtk_label_new("");
        c.gtk_label_set_wrap(@ptrCast(self.status_label), 1);
        c.gtk_label_set_justify(@ptrCast(self.status_label), c.GTK_JUSTIFY_CENTER);
        c.gtk_label_set_selectable(@ptrCast(self.status_label), 1);
        c.gtk_box_append(@ptrCast(self.status_box), self.status_label);
        const retry = c.gtk_button_new_with_label("Reload");
        c.gtk_widget_set_halign(retry, c.GTK_ALIGN_CENTER);
        _ = c.g_signal_connect_data(@ptrCast(retry), "clicked", @ptrCast(&onRetry), self, null, 0);
        self.track(retry);
        c.gtk_box_append(@ptrCast(self.status_box), retry);
        c.gtk_widget_set_visible(self.status_box, 0);
        c.gtk_overlay_add_overlay(@ptrCast(self.overlay), self.status_box);

        self.buildCertOverlay();

        c.gtk_box_append(@ptrCast(self.root_box), self.overlay);

        // Download strip: one row per download, BELOW the page so an
        // arriving download never shifts the content the user is
        // reading. Hidden while empty.
        self.dl_strip = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
        c.gtk_widget_add_css_class(self.dl_strip, "sketerm-web-dlstrip");
        c.gtk_widget_set_visible(self.dl_strip, 0);
        c.gtk_box_append(@ptrCast(self.root_box), self.dl_strip);
    }

    /// The certificate interstitial: a full-face panel, opaque and
    /// dark, that COVERS the page rather than annotating it. It is an
    /// overlay child sized to fill, so nothing of the held page shows
    /// through and no click reaches it while a decision is outstanding.
    fn buildCertOverlay(self: *WebFace) void {
        self.cert_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
        c.gtk_widget_add_css_class(self.cert_box, "sketerm-web-interstitial");
        c.gtk_widget_set_halign(self.cert_box, c.GTK_ALIGN_FILL);
        c.gtk_widget_set_valign(self.cert_box, c.GTK_ALIGN_FILL);

        const heading = c.gtk_label_new("Your connection is not private");
        c.gtk_widget_add_css_class(heading, "title");
        c.gtk_label_set_wrap(@ptrCast(heading), 1);
        c.gtk_widget_set_valign(heading, c.GTK_ALIGN_END);
        c.gtk_widget_set_vexpand(heading, 1);
        c.gtk_box_append(@ptrCast(self.cert_box), heading);

        self.cert_title = c.gtk_label_new("");
        c.gtk_label_set_wrap(@ptrCast(self.cert_title), 1);
        c.gtk_label_set_justify(@ptrCast(self.cert_title), c.GTK_JUSTIFY_CENTER);
        c.gtk_box_append(@ptrCast(self.cert_box), self.cert_title);

        self.cert_detail = c.gtk_label_new("");
        c.gtk_widget_add_css_class(self.cert_detail, "detail");
        c.gtk_label_set_wrap(@ptrCast(self.cert_detail), 1);
        c.gtk_label_set_selectable(@ptrCast(self.cert_detail), 1);
        c.gtk_label_set_justify(@ptrCast(self.cert_detail), c.GTK_JUSTIFY_CENTER);
        c.gtk_box_append(@ptrCast(self.cert_box), self.cert_detail);

        const buttons = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
        c.gtk_widget_set_halign(buttons, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(buttons, c.GTK_ALIGN_START);
        c.gtk_widget_set_vexpand(buttons, 1);
        c.gtk_widget_set_margin_top(buttons, 8);
        // Safety is the DEFAULT action and the visually loud one; the
        // way out is deliberately spelled as the danger it is.
        const back = c.gtk_button_new_with_label("Back to safety");
        c.gtk_widget_add_css_class(back, "suggested-action");
        _ = c.g_signal_connect_data(@ptrCast(back), "clicked", @ptrCast(&onCertBack), self, null, 0);
        self.track(back);
        c.gtk_box_append(@ptrCast(buttons), back);
        const proceed = c.gtk_button_new_with_label("Proceed anyway (unsafe)");
        c.gtk_widget_add_css_class(proceed, "destructive-action");
        _ = c.g_signal_connect_data(@ptrCast(proceed), "clicked", @ptrCast(&onCertProceed), self, null, 0);
        self.track(proceed);
        c.gtk_box_append(@ptrCast(buttons), proceed);
        c.gtk_box_append(@ptrCast(self.cert_box), buttons);

        c.gtk_widget_set_visible(self.cert_box, 0);
        c.gtk_overlay_add_overlay(@ptrCast(self.overlay), self.cert_box);
    }

    fn wireInput(self: *WebFace) void {
        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(@ptrCast(motion), "motion", @ptrCast(&onMotion), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(motion), "leave", @ptrCast(&onPointerLeave), self, null, 0);
        c.gtk_widget_add_controller(self.view_area, motion);
        self.track(motion);

        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "pressed", @ptrCast(&onPressed), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "released", @ptrCast(&onReleased), self, null, 0);
        c.gtk_widget_add_controller(self.view_area, @ptrCast(click));
        self.track(click);

        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        _ = c.g_signal_connect_data(@ptrCast(scroll), "scroll", @ptrCast(&onScroll), self, null, 0);
        c.gtk_widget_add_controller(self.view_area, scroll);
        self.track(scroll);

        const key = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(key), "key-pressed", @ptrCast(&onKeyPressed), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(key), "key-released", @ptrCast(&onKeyReleased), self, null, 0);
        c.gtk_widget_add_controller(self.view_area, key);
        self.track(key);

        const focus = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(@ptrCast(focus), "enter", @ptrCast(&onFocusEnter), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(focus), "leave", @ptrCast(&onFocusLeave), self, null, 0);
        c.gtk_widget_add_controller(self.view_area, focus);
        self.track(focus);

        // File drag & drop -> navigate to the file's URI (a dropped
        // text is treated as an address). Mirrors pane.zig's target.
        const drop = c.gtk_drop_target_new(c.G_TYPE_INVALID, @intCast(c.GDK_ACTION_COPY));
        var drop_types = [_]c.GType{ c.gdk_file_list_get_type(), c.G_TYPE_STRING };
        c.gtk_drop_target_set_gtypes(drop, &drop_types, drop_types.len);
        _ = c.g_signal_connect_data(@ptrCast(drop), "drop", @ptrCast(&onFileDrop), self, null, 0);
        c.gtk_widget_add_controller(self.view_area, @ptrCast(drop));
        self.track(drop);
    }

    // ---- accessibility (capability "a11y") --------------------------
    //
    // Read-only projection, gated by SKETERM_WEB_A11Y=1: the helper
    // streams the page's AX tree only after `a11y_enable` (engine-side
    // accessibility costs real CPU), a mirrored tree (web/axtree.zig)
    // lives on this face, and a11y/webproj.zig registers it on the
    // session's accessibility bus as its own accessible application.
    // The env flag IS the "a client asked" signal for now; screen-
    // reader auto-detection (org.a11y.Status) and focus/action/caret
    // projection are the documented follow-ups.
    //
    // The bus connect (SASL auth + GetAddress + Socket.Embed) is
    // blocking IO, so it runs on a short-lived DETACHED worker that
    // touches no GTK/face state and hands back through g_idle_add;
    // only the handback frees the job, and it resolves the face
    // through the client's faces list (pointer identity, deref only
    // after match) so a face that died mid-connect just costs the
    // worker its work.

    fn a11yWanted() bool {
        const v = c.getenv("SKETERM_WEB_A11Y") orelse return false;
        return v[0] != 0 and v[0] != '0';
    }

    const AxJob = struct {
        gpa: std.mem.Allocator,
        /// Identity token; dereferenced only after it matches a live
        /// registered face.
        face: *WebFace,
        view: u32,
        tree: *axtree.Tree,
        proj: *webproj.Proj,
        ok: bool = false,

        fn discard(self: *AxJob) void {
            self.proj.deinit();
            self.gpa.destroy(self.proj);
            self.tree.deinit();
            self.gpa.destroy(self.tree);
        }
    };

    /// Bring the projection up (idempotent) and (re)tell the helper to
    /// stream. Safe against an old helper: an unknown `a11y_enable`
    /// frame is skipped by the reader, so nothing ever answers.
    fn ensureA11y(self: *WebFace) void {
        if (!a11yWanted() or self.attached or self.widgets_dead) return;
        if (self.ax_proj != null) {
            // A fresh helper connection knows nothing of the earlier
            // enable; the projection itself survives helper restarts.
            self.cl.post(proto.A11yEnable{ .view = self.view, .enabled = 1 });
            return;
        }
        if (self.ax_connecting) return;
        const gpa = self.allocator;
        const tree = gpa.create(axtree.Tree) catch return;
        tree.* = axtree.Tree.init(gpa);
        const proj = gpa.create(webproj.Proj) catch {
            gpa.destroy(tree);
            return;
        };
        proj.* = webproj.Proj.init(gpa, tree, "sketerm web page") catch {
            gpa.destroy(proj);
            tree.deinit();
            gpa.destroy(tree);
            return;
        };
        const job = gpa.create(AxJob) catch {
            proj.deinit();
            gpa.destroy(proj);
            tree.deinit();
            gpa.destroy(tree);
            return;
        };
        job.* = .{ .gpa = gpa, .face = self, .view = self.view, .tree = tree, .proj = proj };
        self.ax_connecting = true;
        const th = std.Thread.spawn(.{}, axConnectWorker, .{job}) catch {
            self.ax_connecting = false;
            job.discard();
            gpa.destroy(job);
            return;
        };
        th.detach();
    }

    /// WORKER THREAD: blocking bus IO only; no GTK, no face state.
    fn axConnectWorker(job: *AxJob) void {
        job.ok = if (job.proj.connect(null)) |_| true else |_| false;
        _ = c.g_idle_add(@ptrCast(&axConnectDone), job);
    }

    fn axConnectDone(user: ?*anyopaque) callconv(.c) c.gboolean {
        const job = cast.userData(AxJob, user);
        const gpa = job.gpa;
        defer gpa.destroy(job);
        var adopt: ?*WebFace = null;
        for (g_client.faces.items) |f| {
            if (f == job.face and f.view == job.view and !f.widgets_dead) {
                adopt = f;
                break;
            }
        }
        const face = adopt orelse {
            job.discard();
            return 0;
        };
        face.ax_connecting = false;
        if (!job.ok) {
            job.discard();
            return 0;
        }
        face.ax_tree = job.tree;
        face.ax_proj = job.proj;
        face.ax_watch = c.g_unix_fd_add(
            job.proj.fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&onAxBusReadable),
            face,
        );
        if (face.title) |t| job.proj.setAppName(t);
        face.cl.post(proto.A11yEnable{ .view = face.view, .enabled = 1 });
        return 0;
    }

    fn onAxBusReadable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(WebFace, user);
        const proj = self.ax_proj orelse {
            self.ax_watch = 0;
            return 0;
        };
        if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0 or !proj.step()) {
            self.ax_watch = 0;
            self.axTeardown();
            return 0;
        }
        return 1;
    }

    /// Drop the projection AND stop the helper-side stream: a mirror
    /// without a bus registration has no consumer. Idempotent; called
    /// from the teardown choke point, `deinit`, and a dead bus.
    fn axTeardown(self: *WebFace) void {
        if (self.ax_watch != 0) {
            _ = c.g_source_remove(self.ax_watch);
            self.ax_watch = 0;
        }
        if (self.ax_proj) |p| {
            self.cl.post(proto.A11yEnable{ .view = self.view, .enabled = 0 });
            p.deinit();
            self.allocator.destroy(p);
            self.ax_proj = null;
        }
        if (self.ax_tree) |t| {
            t.deinit();
            self.allocator.destroy(t);
            self.ax_tree = null;
        }
    }

    pub fn onAxTree(self: *WebFace, ev: proto.EvA11yTree) void {
        const t = self.ax_tree orelse return;
        t.applyTree(ev) catch {};
    }

    pub fn onAxLoc(self: *WebFace, ev: proto.EvA11yLoc) void {
        const t = self.ax_tree orelse return;
        t.applyLoc(ev) catch {};
    }

    fn setStatus(self: *WebFace, text: []const u8, retryable: bool) void {
        if (self.widgets_dead) return;
        var buf: [512]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch "";
        c.gtk_label_set_text(@ptrCast(self.status_label), z.ptr);
        c.gtk_widget_set_visible(self.status_box, 1);
        // The Reload button is the second child of the status box.
        if (c.gtk_widget_get_last_child(self.status_box)) |btn|
            c.gtk_widget_set_visible(btn, if (retryable) @as(c_int, 1) else 0);
    }

    fn clearStatus(self: *WebFace) void {
        if (self.widgets_dead) return;
        c.gtk_widget_set_visible(self.status_box, 0);
    }

    // ---- client callbacks ------------------------------------------

    /// A helper connection came up (first start, or after a Reload).
    pub fn onClientReady(self: *WebFace) void {
        // Nothing in flight can be answered by a helper that just came
        // up: drop the requests so their kinds are usable again.
        self.cancelHints();
        self.auto_ops.clearRetainingCapacity();
        // The document the article came from does not exist any more.
        self.exitReader();
        self.crashed = false;
        self.clearStatus();
        // Whatever the previous helper was holding died with it: a
        // decision now would name a request nobody has.
        self.cert_pending = false;
        self.cert_cancelled = false;
        if (!self.widgets_dead) c.gtk_widget_set_visible(self.cert_box, 0);
        self.clearPermPrompts();
        self.view_live = false;
        // A fresh helper holds no views at all, discarded or otherwise:
        // `ensureView` below mints this one again from scratch.
        self.stopDiscardTimer();
        self.noteRevived();
        self.devtools_pending = false;
        self.dropMap();
        self.sent_w = 0;
        self.sent_h = 0;
        // An attached view belonged to the OLD helper process; its id
        // means nothing to this one and there is nothing to re-create,
        // since only the source page can ask for an inspector.
        if (self.attached) {
            self.onDevToolsLost();
            return;
        }
        self.ensureView();
    }

    pub fn onHelperUnavailable(self: *WebFace, reason: []const u8, retryable: bool) void {
        self.cancelHints();
        self.auto_ops.clearRetainingCapacity();
        self.cert_pending = false;
        self.cert_cancelled = false;
        if (!self.widgets_dead) c.gtk_widget_set_visible(self.cert_box, 0);
        self.clearPermPrompts();
        self.view_live = false;
        self.stopDiscardTimer();
        self.noteRevived();
        self.devtools_pending = false;
        self.dropMap();
        if (self.attached) {
            self.onDevToolsLost();
            return;
        }
        self.setStatus(reason, retryable);
    }

    /// The helper this attached view lived in is gone. Say so, and
    /// offer no Reload: only the page being inspected can open a new
    /// inspector, and this pane no longer knows which page that was.
    fn onDevToolsLost(self: *WebFace) void {
        self.setStatus(DEVTOOLS_GONE_MSG, false);
    }

    fn ensureView(self: *WebFace) void {
        const cl = self.cl;
        // An attached view is created by whoever asked for it (the
        // inspector's source page), never here.
        if (self.attached) return;
        if (cl.state != .ready or self.view_live) return;
        // THE FIRST BUFFER MUST ALREADY BE THE RIGHT SIZE. The area's
        // CURRENT allocation is the truth whenever it has one; the
        // 800x600 below is for a face whose widget has never been laid
        // out at all — an MCP-opened tab nobody selected, which has no
        // size to be right about but still has to load and answer
        // semantic queries. `onResize` corrects it the moment such a tab
        // is shown.
        const alloc = self.allocationSize();
        const w: u16 = if (alloc.w != 0) alloc.w else if (self.sent_w != 0) self.sent_w else 800;
        const h: u16 = if (alloc.h != 0) alloc.h else if (self.sent_h != 0) self.sent_h else 600;
        self.sent_w = w;
        self.sent_h = h;
        self.sent_scale = self.currentScale();
        cl.post(proto.ViewCreate{
            .view = self.view,
            // LOGICAL size; the buffer comes back physical. See the
            // scale note at the top.
            .w = w,
            .h = h,
            .scale_x1000 = self.sent_scale,
            .context = self.container,
        });
        self.view_live = true;
        // A fresh helper connection knows no cap; force the send.
        self.sent_max_fps = 0xffff;
        self.syncMaxFps();
        // A fresh helper knows no user zoom either.
        if (self.zoom_x100 != 0)
            cl.post(proto.SetZoom{ .view = self.view, .level_x100 = self.zoom_x100 });
        // A view is created visible; tell the helper at once when this
        // face is on a background tab (a helper restart can rebuild a
        // view whose pane nobody is looking at).
        if (!self.on_screen) {
            cl.post(proto.ViewHide{ .view = self.view });
            // A view minted for a pane nobody is looking at starts its
            // off-screen countdown here, not at some later unmap that
            // will never come.
            self.armDiscardTimer();
        }
        // The first load has to paint promptly, and nothing paints
        // unless somebody asks.
        self.promote();
        // Accessibility rides the view's lifecycle: every path that
        // mints the view (first create, helper restart) re-asserts it.
        self.ensureA11y();
        // Deliberately create-then-navigate, not the helper's
        // `view_create_url`: this face's view is created the moment the
        // socket connects, before the `hello_ack` that would say whether
        // the capability exists. The cost is one about:blank document
        // per addressed tab, which only a load-settle has to see past
        // (mcp_web's `web_open`); the headless driver, which creates its
        // views after the handshake, takes the single-document path.
        if (self.pending_url) |u| {
            cl.post(proto.Navigate{ .view = self.view, .url = u });
        } else if (self.url) |u| {
            cl.post(proto.Navigate{ .view = self.view, .url = u });
        }
    }

    /// Report a new buffer's geometry against the widget's, under
    /// `SKETERM_WEB_STATS=1`. Buffers are rare (creation, resize, scale
    /// change), so this is a handful of lines per session and it is the
    /// only place the "is the FIRST frame already the right size"
    /// question is answerable — the defect it exists for corrects itself
    /// on the next interaction and is invisible afterwards.
    fn noteBufferGeometry(self: *WebFace, pw: u16, ph: u16) void {
        if (!g_stats.enabled()) return;
        const alloc = self.allocationSize();
        const lw = logicalOf(pw, self.sent_scale);
        const lh = logicalOf(ph, self.sent_scale);
        const fits = alloc.w == 0 or (lw == alloc.w and lh == alloc.h);
        std.debug.print(
            "webface geometry: buffer {d}x{d} phys = {d}x{d} logical at scale {d}, area {d}x{d} logical, match={s}\n",
            .{ pw, ph, lw, lh, self.sent_scale, alloc.w, alloc.h, if (fits) "yes" else "NO" },
        );
    }

    /// A PHYSICAL extent back in logical pixels. Rounded to nearest so
    /// an exact-fit frame stays an exact fit (1707 * 1500 / 1000 = 2560
    /// must come back as 1707, not 1706).
    fn logicalOf(physical: u16, scale_x1000: u16) u16 {
        if (scale_x1000 == 0) return physical;
        const n = (@as(u32, physical) * 1000 + scale_x1000 / 2) / scale_x1000;
        return @intCast(@min(n, std.math.maxInt(u16)));
    }

    /// The view widget's LOGICAL size, or 0x0 when it has never been laid
    /// out. `gtk_widget_get_width` reports the allocation, which exists
    /// from the first size-allocate — well before the first render.
    fn allocationSize(self: *WebFace) struct { w: u16, h: u16 } {
        if (self.widgets_dead) return .{ .w = 0, .h = 0 };
        const w = c.gtk_widget_get_width(self.view_area);
        const h = c.gtk_widget_get_height(self.view_area);
        if (w <= 0 or h <= 0) return .{ .w = 0, .h = 0 };
        return .{
            .w = @intCast(@min(w, std.math.maxInt(u16))),
            .h = @intCast(@min(h, std.math.maxInt(u16))),
        };
    }

    /// A fresh frame buffer for this view: map it (refcounted), drop
    /// the previous one, and tell the helper the old buffer is ours no
    /// more. Nothing is presented yet — a fresh buffer holds nothing
    /// until its first damage batch, and the picture keeps the last
    /// good frame meanwhile.
    pub fn adoptBuffer(self: *WebFace, fb: proto.FrameBuffer, fd: c_int) void {
        defer _ = c.close(fd);
        const size: usize = @as(usize, fb.stride) * @as(usize, fb.h);
        if (size == 0) return;
        const addr = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, fd, 0);
        if (addr == c.MAP_FAILED) return;
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
        const mref = self.allocator.create(MapRef) catch {
            _ = c.munmap(bytes, size);
            return;
        };
        mref.* = .{ .ptr = bytes, .len = size, .refs = 1, .allocator = self.allocator };
        const old_id = self.buf_id;
        self.dropMap();
        self.map = mref;
        self.buf_id = fb.buf_id;
        self.buf_w = fb.w;
        self.buf_h = fb.h;
        self.buf_stride = fb.stride;
        if (old_id != 0) self.cl.post(proto.FrameRelease{ .view = self.view, .buf_id = old_id });
        self.noteBufferGeometry(fb.w, fb.h);
        // A fresh buffer holds nothing yet: ask for the repaint that
        // fills it rather than waiting for the idle floor.
        self.promote();
    }

    /// Hand a frame texture to the picture, sized to its LOGICAL extent
    /// and re-snapped onto the device pixel grid. Takes ownership of
    /// the caller's reference. There is still no frame QUEUE anywhere:
    /// the paintable always wraps the newest pixels, so batches landing
    /// between two GTK paints collapse into one.
    fn presentTexture(self: *WebFace, tex: *c.GdkTexture, lw: u16, lh: u16, is_shm: bool) void {
        if (self.widgets_dead) {
            c.g_object_unref(@ptrCast(tex));
            return;
        }
        if (lw != self.frame_lw or lh != self.frame_lh) {
            self.frame_lw = lw;
            self.frame_lh = lh;
            c.gtk_widget_set_size_request(self.picture, lw, lh);
        }
        c.gtk_picture_set_paintable(@ptrCast(self.picture), @ptrCast(tex));
        if (self.tex_prev) |old| c.g_object_unref(@ptrCast(old));
        self.tex_prev = tex;
        self.tex_prev_is_shm = is_shm;
        self.snapAlignment();
        self.noteFrameGeometry();
        // A GdkTexture never invalidates itself (immutability contract),
        // and on the GPU path the SAME texture object is re-presented
        // over live pool memory — the explicit draw is what shows it.
        c.gtk_widget_queue_draw(self.picture);
    }

    /// Nudge the picture onto the device pixel grid. A GdkTexture whose
    /// device size matches 1:1 still blurs completely when its origin
    /// falls between device pixels (MEASURED: at 1.5x a half-pixel
    /// offset turns a 1px-stripe texture into uniform gray), and GTK
    /// margins are integer LOGICAL px — so the fix is the smallest
    /// margin that lands the origin on the grid: at 1.5 it is 0 or 1,
    /// at 1.25 up to 3. Input coordinates subtract `snap_dx/dy`.
    fn snapAlignment(self: *WebFace) void {
        if (self.widgets_dead) return;
        const native = c.gtk_widget_get_native(self.view_area) orelse return;
        const surface = c.gtk_native_get_surface(native) orelse return;
        const scale = c.gdk_surface_get_scale(surface);
        if (!(scale > 0)) return;
        var sx: f64 = 0;
        var sy: f64 = 0;
        c.gtk_native_get_surface_transform(native, &sx, &sy);
        var src = c.graphene_point_t{ .x = 0, .y = 0 };
        var out: c.graphene_point_t = undefined;
        if (c.gtk_widget_compute_point(self.picture, @ptrCast(@alignCast(native)), &src, &out) == 0) return;
        const base_x = sx + @as(f64, out.x) - @as(f64, @floatFromInt(self.snap_dx));
        const base_y = sy + @as(f64, out.y) - @as(f64, @floatFromInt(self.snap_dy));
        const dx = snapDelta(base_x, scale);
        const dy = snapDelta(base_y, scale);
        if (dx == self.snap_dx and dy == self.snap_dy) return;
        self.snap_dx = dx;
        self.snap_dy = dy;
        c.gtk_widget_set_margin_start(self.picture, dx);
        c.gtk_widget_set_margin_top(self.picture, dy);
    }

    /// Smallest whole-logical-pixel nudge that puts `base * scale` on
    /// an integer device coordinate (closest achievable otherwise).
    fn snapDelta(base: f64, scale: f64) u16 {
        var best: u16 = 0;
        var best_err: f64 = 1e9;
        var d: u16 = 0;
        while (d < 8) : (d += 1) {
            const dev = (base + @as(f64, @floatFromInt(d))) * scale;
            const err = @abs(dev - @round(dev));
            if (err < best_err - 1e-9) {
                best_err = err;
                best = d;
                if (err < 1e-6) break;
            }
        }
        return best;
    }

    /// A GPU frame: wrap the engine's dma-buf as a `GdkDmabufTexture`
    /// and hand it to the picture. GSK imports it (EGLImage on GL,
    /// VkImage on Vulkan) and samples the engine's LIVE buffer — no
    /// pixel is copied and none enters this process. Imports are cached
    /// per pool buffer id, so a steady 100fps costs two or three
    /// imports in total; the descriptors handed to GDK are dups closed
    /// when it releases the texture, and the frame's own fds are closed
    /// before this returns.
    pub fn onDmabuf(self: *WebFace, f: proto.FrameDmabuf, fds: []const c_int) void {
        defer for (fds) |fd| {
            _ = c.close(fd);
        };
        if (self.widgets_dead) return;
        const stats = g_stats.enabled();
        const t0 = if (stats) Stats.nowNs() else 0;

        // Geometry changes retire the whole pool: a cached import is the
        // old size, and the ids start over.
        if (f.w != self.buf_w or f.h != self.buf_h) {
            self.clearDmabufCache();
            self.buf_w = f.w;
            self.buf_h = f.h;
        }

        var tex: ?*c.GdkTexture = null;
        for (&self.dmabuf_tex) |*e| {
            if (e.buf_id == f.buf_id and e.tex != null) {
                tex = e.tex;
                break;
            }
        }
        if (tex == null) tex = self.importDmabuf(f, fds);
        const t = tex orelse {
            // Not importable; the last frame stays up rather than a
            // black pane, and the next frame tries again.
            if (!self.dmabuf_import_warned) {
                self.dmabuf_import_warned = true;
                std.debug.print("webface: GDK could not import a dma-buf frame; page frozen on the GPU path\n", .{});
            }
            return;
        };
        _ = c.g_object_ref(@ptrCast(t));
        self.presentTexture(t, logicalOf(f.w, self.sent_scale), logicalOf(f.h, self.sent_scale), false);
        if (stats) {
            g_stats.gpu_imports += 1;
            g_stats.note(Stats.nowNs() - t0, 0);
        }
        self.notePaint();
        self.clearStatus();
    }

    /// Build the `GdkDmabufTexture` for a pool buffer and cache it by
    /// pool id (evicting the oldest slot). The dups handed to GDK are
    /// closed by the texture's destroy notify.
    fn importDmabuf(self: *WebFace, f: proto.FrameDmabuf, fds: []const c_int) ?*c.GdkTexture {
        if (self.widgets_dead or fds.len == 0 or f.w == 0 or f.h == 0) return null;
        const display = c.gtk_widget_get_display(self.view_area) orelse return null;
        const own = self.allocator.create(DmabufFds) catch return null;
        own.* = .{ .fds = @splat(-1), .n = 0, .allocator = self.allocator };
        const b = c.gdk_dmabuf_texture_builder_new() orelse {
            self.allocator.destroy(own);
            return null;
        };
        defer c.g_object_unref(@ptrCast(b));
        c.gdk_dmabuf_texture_builder_set_display(b, display);
        c.gdk_dmabuf_texture_builder_set_width(b, f.w);
        c.gdk_dmabuf_texture_builder_set_height(b, f.h);
        c.gdk_dmabuf_texture_builder_set_fourcc(b, f.fourcc);
        c.gdk_dmabuf_texture_builder_set_modifier(b, f.modifier);
        c.gdk_dmabuf_texture_builder_set_n_planes(b, f.nplanes);
        c.gdk_dmabuf_texture_builder_set_premultiplied(b, 1);
        var i: usize = 0;
        while (i < f.nplanes) : (i += 1) {
            const dup = c.fcntl(fds[i], c.F_DUPFD_CLOEXEC, @as(c_int, 3));
            if (dup < 0) {
                DmabufFds.destroy(own);
                return null;
            }
            own.fds[i] = dup;
            own.n += 1;
            c.gdk_dmabuf_texture_builder_set_fd(b, @intCast(i), dup);
            c.gdk_dmabuf_texture_builder_set_stride(b, @intCast(i), f.planes[i].stride);
            c.gdk_dmabuf_texture_builder_set_offset(b, @intCast(i), f.planes[i].offset);
        }
        var err: [*c]c.GError = null;
        const tex = c.gdk_dmabuf_texture_builder_build(b, DmabufFds.destroy, own, &err) orelse {
            if (err != null) c.g_error_free(err);
            // Build never ran the destroy notify; the dups are ours.
            DmabufFds.destroy(own);
            return null;
        };
        // Cache it: reuse this pool id's slot, else the first empty,
        // else evict slot 0 (pool ids cycle; eviction only costs a
        // re-import).
        var slot: usize = 0;
        var found = false;
        for (&self.dmabuf_tex, 0..) |*e, idx| {
            if (e.tex == null or e.buf_id == f.buf_id) {
                slot = idx;
                found = true;
                break;
            }
        }
        if (!found) slot = 0;
        if (self.dmabuf_tex[slot].tex) |old| c.g_object_unref(@ptrCast(old));
        self.dmabuf_tex[slot] = .{ .buf_id = f.buf_id, .tex = tex };
        return tex;
    }

    /// An inline frame (capability "frames-inline", remote helpers):
    /// pixels arrived in-band, so the face materialises the buffer the
    /// memfd path would have mapped — an anonymous mapping in the SAME
    /// `MapRef` shape — decodes the damaged rects into it, and then
    /// takes the ordinary `onDamage` presentation path (GSK uploads
    /// only the damaged region, exactly as for shm frames).
    pub fn onInline(self: *WebFace, fi: proto.FrameInline) void {
        if (self.widgets_dead) return;
        if (fi.w == 0 or fi.h == 0) return;
        const stride: u32 = @as(u32, fi.w) * 4;
        const size: usize = @as(usize, stride) * @as(usize, fi.h);
        const need_new = self.map == null or self.buf_w != fi.w or self.buf_h != fi.h;
        if (need_new) {
            const addr = c.mmap(null, size, c.PROT_READ | c.PROT_WRITE, c.MAP_PRIVATE | c.MAP_ANONYMOUS, -1, 0);
            if (addr == c.MAP_FAILED) return;
            const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
            const mref = self.allocator.create(MapRef) catch {
                _ = c.munmap(bytes, size);
                return;
            };
            mref.* = .{ .ptr = bytes, .len = size, .refs = 1, .allocator = self.allocator };
            self.dropMap();
            self.map = mref;
            self.buf_w = fi.w;
            self.buf_h = fi.h;
            self.buf_stride = stride;
            // Local id only — the helper never announced this buffer, so
            // no frame_release goes back for it either.
            self.buf_id +%= 1;
            if (self.buf_id == 0) self.buf_id = 1;
            self.noteBufferGeometry(fi.w, fi.h);
        }
        const m = self.map orelse return;
        var rects_buf: [32]proto.Rect = undefined;
        var n: usize = 0;
        for (fi.rects) |r| {
            if (r.w == 0 or r.h == 0) continue;
            // Bounds are the peer's claim; a rect outside the surface is
            // a desynchronised stream and is dropped, never written.
            if (@as(u32, r.x) + r.w > fi.w or @as(u32, r.y) + r.h > fi.h) continue;
            const raw_len: usize = @as(usize, r.w) * @as(usize, r.h) * 4;
            const row_bytes: usize = @as(usize, r.w) * 4;
            var decoded: []const u8 = undefined;
            var scratch: ?[]u8 = null;
            defer if (scratch) |sc| self.allocator.free(sc);
            switch (r.enc) {
                proto.inline_enc_raw => {
                    if (r.data.len != raw_len) continue;
                    decoded = r.data;
                },
                proto.inline_enc_deflate => {
                    const sc = self.allocator.alloc(u8, raw_len) catch continue;
                    scratch = sc;
                    decoded = zpool.decompress(r.data, sc) catch continue;
                },
                else => continue,
            }
            var row: usize = 0;
            while (row < r.h) : (row += 1) {
                const dst_off = (@as(usize, r.y) + row) * stride + @as(usize, r.x) * 4;
                @memcpy(m.ptr[dst_off..][0..row_bytes], decoded[row * row_bytes ..][0..row_bytes]);
            }
            if (n < rects_buf.len) {
                rects_buf[n] = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
                n += 1;
            }
        }
        if (n == 0) return;
        // A fresh buffer has undefined pixels outside this frame's
        // rects; present the WHOLE surface once so nothing stale shows.
        if (need_new) {
            rects_buf[0] = .{ .x = 0, .y = 0, .w = fi.w, .h = fi.h };
            n = 1;
        }
        self.onDamage(.{
            .view = fi.view,
            .buf_id = self.buf_id,
            .gen = fi.gen,
            .rects = rects_buf[0..n],
        });
    }

    /// A software damage batch: wrap the mapping as a `GdkMemoryTexture`
    /// whose `update_region` is exactly the damaged rects, diffed
    /// against the previous frame's texture — GSK then uploads ONLY
    /// those rects into its GPU copy. That is the damage-rect economy
    /// the old GL pass had, now implemented by GTK. The `GBytes` holds a
    /// reference on the mapping, so a buffer replacement can never pull
    /// pages out from under a texture GSK still reads.
    pub fn onDamage(self: *WebFace, dmg: proto.FrameDamage) void {
        if (self.widgets_dead) return;
        // A damage batch for a buffer we already replaced describes
        // pixels we no longer have; the new buffer repaints in full.
        if (dmg.buf_id != self.buf_id) return;
        const m = self.map orelse return;
        if (self.buf_w == 0 or self.buf_h == 0) return;
        const stats = g_stats.enabled();
        const t0 = if (stats) Stats.nowNs() else 0;

        const builder = c.gdk_memory_texture_builder_new() orelse return;
        defer c.g_object_unref(@ptrCast(builder));
        const bytes = c.g_bytes_new_with_free_func(m.ptr, m.len, MapRef.gbytesDestroy, m.ref()) orelse {
            m.unref();
            return;
        };
        defer c.g_bytes_unref(bytes);
        c.gdk_memory_texture_builder_set_bytes(builder, bytes);
        c.gdk_memory_texture_builder_set_width(builder, self.buf_w);
        c.gdk_memory_texture_builder_set_height(builder, self.buf_h);
        c.gdk_memory_texture_builder_set_stride(builder, self.buf_stride);
        c.gdk_memory_texture_builder_set_format(builder, c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED);
        var uploaded: usize = 0;
        var region: ?*c.cairo_region_t = null;
        defer if (region) |r| c.cairo_region_destroy(r);
        if (self.tex_prev != null and self.tex_prev_is_shm) {
            region = c.cairo_region_create();
            for (dmg.rects) |r| {
                var cr = c.cairo_rectangle_int_t{
                    .x = r.x,
                    .y = r.y,
                    .width = r.w,
                    .height = r.h,
                };
                _ = c.cairo_region_union_rectangle(region, &cr);
                uploaded += @as(usize, r.w) * @as(usize, r.h) * 4;
            }
            c.gdk_memory_texture_builder_set_update_texture(builder, self.tex_prev);
            c.gdk_memory_texture_builder_set_update_region(builder, region);
        } else {
            uploaded = m.len;
        }
        const tex = c.gdk_memory_texture_builder_build(builder) orelse return;
        self.presentTexture(tex, logicalOf(self.buf_w, self.sent_scale), logicalOf(self.buf_h, self.sent_scale), true);

        // Measurement harness: `SKETERM_WEB_DUMP=<path>` keeps writing
        // the engine's raw BGRA buffer (the pre-presentation ground
        // truth) to <path> plus a .txt with its geometry.
        if (c.getenv("SKETERM_WEB_DUMP")) |dp| {
            const path = std.mem.span(dp);
            if (c.fopen(path.ptr, "wb")) |f| {
                _ = c.fwrite(m.ptr, 1, m.len, f);
                _ = c.fclose(f);
            }
            var meta_buf: [512]u8 = undefined;
            if (std.fmt.bufPrintZ(&meta_buf, "{s}.txt", .{path}) catch null) |mp| {
                if (c.fopen(mp.ptr, "wb")) |f| {
                    var line: [128]u8 = undefined;
                    const t = std.fmt.bufPrint(&line, "{d} {d} {d}\n", .{ self.buf_w, self.buf_h, self.buf_stride }) catch "";
                    _ = c.fwrite(t.ptr, 1, t.len, f);
                    _ = c.fclose(f);
                }
            }
        }
        self.probeMapping(m);
        self.notePaint();
        self.clearStatus();
        if (stats) g_stats.note(Stats.nowNs() - t0, uploaded);
    }

    pub fn onTitle(self: *WebFace, title: []const u8) void {
        if (self.title) |t| self.allocator.free(t);
        self.title = self.allocator.dupe(u8, title) catch null;
        // The visit was recorded at navigation commit; the first title
        // for that page completes its history entry (no extra count).
        if (self.visit_url) |vu| {
            const matches = if (self.url) |u| std.mem.eql(u8, vu, u) else false;
            if (matches and title.len > 0) {
                webstore.recordTitle(self.allocator, vu, title);
                self.allocator.free(vu);
                self.visit_url = null;
            }
        }
        self.applyTabTitle();
        self.applyPaneFaceTitle();
        // The strip label and the tree sidebar row name this PAGE, and
        // do so whether or not it is the active one.
        if (self.group()) |g| g.noteTitle(self);
        // The accessibility desktop lists the page by its title.
        if (self.ax_proj) |p| {
            if (title.len > 0) p.setAppName(title);
        }
    }

    /// True when this page is the one its group is showing. A
    /// background page must never write the pane titlebar or the
    /// window tab — those belong to whatever is actually on screen.
    fn isActivePage(self: *WebFace) bool {
        const g = self.group() orelse return true;
        const cur = g.active() orelse return true;
        return cur == self;
    }

    /// The pane's inner titlebar wears the page title too, but only
    /// while THIS face is the one showing -- a background face must
    /// not overwrite the visible face's title.
    fn applyPaneFaceTitle(self: *WebFace) void {
        const pane = self.pane orelse return;
        if (!pane.webFaceVisible()) return;
        if (!self.isActivePage()) return;
        const title = self.title orelse return;
        pane.setFaceTitle(title);
    }

    /// The pane's tab wears the page title while a web face is on it.
    fn applyTabTitle(self: *WebFace) void {
        if (self.widgets_dead) return;
        if (!self.isActivePage()) return;
        const pane = self.pane orelse return;
        const win = self.ownerWindow() orelse return;
        const page = @import("window.zig").tabPageForPane(win, pane) orelse return;
        // The same name the page wears in the strip and the tree
        // sidebar, so one page is not called two different things —
        // notably a blank page, which reports "about:blank" as its
        // title and reads as "New Tab" everywhere else.
        const title = webgroup.Group.pageTitle(self);
        @import("termsinks.zig").setTabPageTitleFromUtf8(self.allocator, page, title);
    }

    pub fn onNavState(self: *WebFace, ev: proto.EvNavState) void {
        if (self.widgets_dead) return;
        c.gtk_widget_set_sensitive(self.back_btn, if (ev.can_back != 0) @as(c_int, 1) else 0);
        c.gtk_widget_set_sensitive(self.fwd_btn, if (ev.can_fwd != 0) @as(c_int, 1) else 0);
        self.loading = ev.loading != 0;
        self.can_back = ev.can_back != 0;
        self.can_fwd = ev.can_fwd != 0;
        c.gtk_button_set_icon_name(
            @ptrCast(self.reload_btn),
            if (self.loading) "process-stop-symbolic" else "view-refresh-symbolic",
        );
        c.gtk_widget_set_tooltip_text(self.reload_btn, if (self.loading) "Stop" else "Reload");
        self.setUrl(ev.url);
    }

    fn setUrl(self: *WebFace, url: []const u8) void {
        if (self.url) |u| {
            if (std.mem.eql(u8, u, url)) return;
            self.allocator.free(u);
        }
        self.url = self.allocator.dupe(u8, url) catch null;
        if (self.pending_url) |u| {
            self.allocator.free(u);
            self.pending_url = null;
        }
        self.noteNavigation(url);
        // A page that has not answered with a title yet is named by its
        // host everywhere, so a navigation renames it.
        if (self.title == null) {
            if (self.group()) |g| g.noteTitle(self);
            self.applyTabTitle();
        }
        if (self.widgets_dead) return;
        self.updateSiteButton();
        // A blank page has no address to show: browsers leave the bar
        // empty there, and writing "about:blank" into the bar of a tab
        // that opens focused would land the user's typing in front of
        // it.
        const shown: []const u8 = if (std.mem.eql(u8, url, "about:blank")) "" else url;
        const z = self.allocator.dupeZ(u8, shown) catch return;
        defer self.allocator.free(z);
        // Never fight the user's typing: only rewrite an unfocused bar.
        if (c.gtk_widget_has_focus(self.entry) == 0)
            c.gtk_editable_set_text(@ptrCast(self.entry), z.ptr);
    }

    // ---- web store (daemon-side history + per-site settings) --------

    /// Bookkeeping on a committed navigation: record the visit in the
    /// daemon web store and, when the origin changed, fetch its stored
    /// per-site zoom.
    fn noteNavigation(self: *WebFace, url: []const u8) void {
        if (!recordableUrl(url)) {
            // A blank/error page is bookmarkable by nothing; make sure
            // the star does not keep claiming the page before it.
            self.bookmark_id = 0;
            self.updateStar();
            return;
        }
        webstore.recordVisit(self.allocator, url, "");
        if (self.visit_url) |u| self.allocator.free(u);
        self.visit_url = self.allocator.dupe(u8, url) catch null;
        // Per-URL, not per-origin: two pages of one site are two
        // different bookmarks.
        self.refreshBookmarkState();

        var obuf: [512]u8 = undefined;
        const origin = webstore.originOf(&obuf, url) orelse return;
        if (self.nav_origin) |o| {
            if (std.mem.eql(u8, o, origin)) return;
            self.allocator.free(o);
        }
        // A certificate the user accepted was accepted for the origin
        // they were looking at, not for the next one.
        self.cert_exception = false;
        self.nav_origin = self.allocator.dupe(u8, origin) catch null;
        _ = webstore.siteGet(self.allocator, origin, @ptrCast(self), &onSiteReply);
    }

    /// Only real documents make history; about:/data:/chrome-error
    /// noise never does.
    fn recordableUrl(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "http://") or
            std.mem.startsWith(u8, url, "https://") or
            std.mem.startsWith(u8, url, "file://");
    }

    /// site_get answer: apply everything the origin has stored — zoom,
    /// content-blocking, popup policy, permission decisions — WITHOUT
    /// writing any of it back (only a user action stores).
    fn onSiteReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
        const self = cast.userData(WebFace, ctx);
        if (!ok) return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const rep = webstore.parseSite(arena.allocator(), payload) orelse return;
        if (!rep.ok) return;
        // Stale reply: the face navigated elsewhere meanwhile.
        const cur = self.nav_origin orelse return;
        if (!std.ascii.eqlIgnoreCase(cur, rep.origin)) return;

        const zoom: i32 = if (rep.site) |site| site.zoom_x100 else 0;
        if (zoom != self.zoom_x100) {
            self.zoom_x100 = zoom;
            if (self.view_live)
                self.cl.post(proto.SetZoom{ .view = self.view, .level_x100 = zoom });
        }

        // An origin with no override follows the defaults, which is not
        // the same as "leave the previous origin's answer in place":
        // one view walks many sites.
        self.site_popup = .inherit;
        var want_block = true;
        if (rep.site) |site| {
            if (site.block) |b| want_block = b;
            if (std.mem.eql(u8, site.popup, "allow")) self.site_popup = .allow;
            if (std.mem.eql(u8, site.popup, "block")) self.site_popup = .block;
            for (site.perms) |p| self.preloadPermission(rep.origin, p);
        }
        // netStoreApply is the named hook; it no-ops when the live
        // state already matches.
        self.netStoreApply(want_block);
        // A prompt that arrived before this reply is answered now
        // rather than left on screen asking a question the store has
        // already answered.
        self.answerRememberedPrompts();
    }

    /// Seed the in-process permission memory from the store. Never
    /// reports to `SiteSettingSink`: this decision CAME from the store,
    /// and echoing it back would be a write per navigation.
    fn preloadPermission(self: *WebFace, origin: []const u8, p: webstore.PermEntry) void {
        const types = webstore.permTypes(p.name) orelse return;
        const allow = if (std.mem.eql(u8, p.decision, "allow"))
            true
        else if (std.mem.eql(u8, p.decision, "deny"))
            false
        else
            return;
        for (self.site_settings.items) |*s| {
            if (s.types == types and std.mem.eql(u8, s.origin, origin)) {
                s.allow = allow;
                return;
            }
        }
        const owned = self.allocator.dupe(u8, origin) catch return;
        self.site_settings.append(self.allocator, .{
            .origin = owned,
            .types = types,
            .allow = allow,
        }) catch self.allocator.free(owned);
    }

    /// Drain any held prompt the (now loaded) memory can answer.
    fn answerRememberedPrompts(self: *WebFace) void {
        var i: usize = 0;
        while (i < self.perm_queue.items.len) {
            const p = self.perm_queue.items[i];
            const allow = self.rememberedSetting(p.origin, p.types) orelse {
                i += 1;
                continue;
            };
            _ = self.perm_queue.orderedRemove(i);
            self.postPermission(p.prompt, allow);
            self.allocator.free(p.origin);
        }
        self.showPermPrompt();
    }

    // ---- bookmarks --------------------------------------------------

    /// Ask the store whether the current address is bookmarked; the
    /// reply moves the star. Cheap enough per navigation: a bookmark
    /// list is tens of entries, and it is the only way one window sees
    /// what another one starred.
    fn refreshBookmarkState(self: *WebFace) void {
        if (!webstore.bookmarkList(self.allocator, @ptrCast(self), &onBookmarkList)) {
            self.bookmark_id = 0;
            self.updateStar();
        }
    }

    fn onBookmarkList(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
        const self = cast.userData(WebFace, ctx);
        self.bookmark_id = 0;
        if (ok) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const url = self.url orelse self.visit_url orelse "";
            if (url.len > 0) {
                for (webstore.parseBookmarks(arena.allocator(), payload)) |b| {
                    if (std.mem.eql(u8, b.url, url)) {
                        self.bookmark_id = b.id;
                        break;
                    }
                }
            }
        }
        self.updateStar();
    }

    fn updateStar(self: *WebFace) void {
        if (self.widgets_dead) return;
        const on = self.bookmark_id != 0;
        toolbtn.setIcon(
            self.star_btn,
            self.bar,
            if (on) "starred-symbolic" else "non-starred-symbolic",
            if (on) "Bookmarked" else "Bookmark",
        );
        c.gtk_widget_set_tooltip_text(
            self.star_btn,
            if (on) "Remove this page from bookmarks" else "Bookmark this page",
        );
    }

    /// Star: add the current page, or remove the bookmark it already
    /// has. The reply-driven refresh is what learns the new id, so the
    /// star is only ever as wrong as one round trip.
    fn onStar(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (self.bookmark_id != 0) {
            webstore.bookmarkRemove(self.allocator, self.bookmark_id);
            self.bookmark_id = 0;
            self.updateStar();
            self.toast("Bookmark removed");
            return;
        }
        const url = self.url orelse self.visit_url orelse return;
        if (!recordableUrl(url)) return;
        webstore.bookmarkAdd(self.allocator, url, self.title orelse "", "");
        self.toast("Bookmarked");
        // Ordered behind the add on the same connection, so it comes
        // back with the id the add just minted.
        self.refreshBookmarkState();
    }

    pub fn onLoad(self: *WebFace, ev: proto.EvLoad) void {
        // A document changing state is about to paint.
        self.promote();
        if (ev.state == @intFromEnum(proto.LoadState.started)) {
            self.cancelHints();
            self.crashed = false;
            self.clearStatus();
            // A navigation the page started itself (a link the reader
            // did not send, a redirect, a form) also invalidates the
            // article that is showing.
            self.exitReader();
            // The engine dismisses the prompts of a document it is
            // leaving; a banner for a page that is gone would answer
            // into nothing.
            self.clearPermPrompts();
        } else if (ev.state == @intFromEnum(proto.LoadState.finished) or
            ev.state == @intFromEnum(proto.LoadState.failed))
        {
            self.load_seq +%= 1;
        }
    }

    pub fn onLoadError(self: *WebFace, ev: proto.EvLoadError) void {
        // A request this face is asking about, or just cancelled from
        // the interstitial, fails by design: the interstitial is the
        // explanation, and the generic overlay on top of it would only
        // restate it in weaker words.
        if (self.cert_pending) return;
        if (self.cert_cancelled) {
            self.cert_cancelled = false;
            return;
        }
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Could not load {s}: {s} ({d})", .{ ev.url, ev.msg, ev.code }) catch "Could not load this page.";
        self.setStatus(msg, true);
    }

    // ---- TLS interstitial -------------------------------------------

    /// The helper is HOLDING a request whose certificate failed. Until
    /// `certDecide` answers, the page is neither loaded nor failed.
    pub fn onCertError(self: *WebFace, ev: proto.EvCertError) void {
        self.cert_pending = true;
        self.cert_cancelled = false;
        if (self.widgets_dead) return;
        // The generic status overlay would otherwise sit on top of the
        // interstitial saying the same thing in weaker words.
        self.clearStatus();

        var buf: [512]u8 = undefined;
        const named = if (ev.host.len != 0) ev.host else ev.url;
        const title = std.fmt.bufPrintZ(
            &buf,
            "sketerm cannot verify that this is {s}. Someone may be impersonating it to steal what you type.",
            .{named},
        ) catch "This site's certificate could not be verified.";
        c.gtk_label_set_text(@ptrCast(self.cert_title), title.ptr);

        var dbuf: [1024]u8 = undefined;
        const detail = std.fmt.bufPrintZ(&dbuf, "{s} ({d})\nIssued to: {s}\nIssued by: {s}\nSHA-256: {s}", .{
            ev.msg,
            ev.code,
            if (ev.subject.len != 0) ev.subject else "(unknown)",
            if (ev.issuer.len != 0) ev.issuer else "(unknown)",
            if (ev.fingerprint.len != 0) ev.fingerprint else "(unavailable)",
        }) catch "";
        c.gtk_label_set_text(@ptrCast(self.cert_detail), detail.ptr);
        c.gtk_widget_set_visible(self.cert_box, 1);
    }

    /// Answer the held request. `proceed` accepts the certificate for
    /// THIS request only: nothing is remembered, here or helper-side.
    fn certDecide(self: *WebFace, proceed: bool) void {
        if (!self.cert_pending) return;
        self.cert_pending = false;
        self.cert_cancelled = !proceed;
        // A helper without the capability never sent the event, so it
        // can only be a decision for a request nobody holds.
        if (self.cl.has_tls) self.cl.post(proto.CertDecision{
            .view = self.view,
            .proceed = if (proceed) 1 else 0,
        });
        if (!self.widgets_dead) c.gtk_widget_set_visible(self.cert_box, 0);
        if (proceed) {
            // The padlock must stop claiming a verified identity the
            // moment the user overrode the verification.
            self.cert_exception = true;
            self.updateSiteButton();
            self.promote();
            return;
        }
        // "Back to safety" means LEAVING, not sitting on a cancelled
        // request: back where there is history, a blank page where the
        // bad site was the first thing this tab ever opened.
        if (self.can_back) {
            self.navAction(.back);
        } else {
            self.cl.post(proto.Navigate{ .view = self.view, .url = "about:blank" });
        }
    }

    fn onCertBack(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).certDecide(false);
    }

    fn onCertProceed(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).certDecide(true);
    }

    // ---- permission prompts -----------------------------------------

    /// A page asked for a permission and the helper is holding it.
    /// A remembered answer for the same (origin, permission set) is
    /// applied at once and nothing is shown.
    pub fn onPermission(self: *WebFace, ev: proto.EvPermission) void {
        if (self.rememberedSetting(ev.origin, ev.types)) |allow| {
            self.postPermission(ev.prompt, allow);
            return;
        }
        const origin = self.allocator.dupe(u8, ev.origin) catch return;
        self.perm_queue.append(self.allocator, .{
            .prompt = ev.prompt,
            .origin = origin,
            .types = ev.types,
        }) catch {
            self.allocator.free(origin);
            // Nobody can answer a prompt that was not queued, so answer
            // it now rather than leaving the page waiting forever.
            self.postPermission(ev.prompt, false);
            return;
        };
        self.showPermPrompt();
    }

    fn postPermission(self: *WebFace, prompt: u64, allow: bool) void {
        if (!self.cl.has_permissions) return;
        self.cl.post(proto.PermissionDecision{
            .view = self.view,
            .prompt = prompt,
            .allow = if (allow) 1 else 0,
        });
    }

    fn rememberedSetting(self: *WebFace, origin: []const u8, types: u32) ?bool {
        for (self.site_settings.items) |s| {
            if (s.types == types and std.mem.eql(u8, s.origin, origin)) return s.allow;
        }
        return null;
    }

    fn rememberSetting(self: *WebFace, origin: []const u8, types: u32, allow: bool) void {
        for (self.site_settings.items) |*s| {
            if (s.types == types and std.mem.eql(u8, s.origin, origin)) {
                s.allow = allow;
                break;
            }
        } else {
            const owned = self.allocator.dupe(u8, origin) catch return;
            self.site_settings.append(self.allocator, .{
                .origin = owned,
                .types = types,
                .allow = allow,
            }) catch {
                self.allocator.free(owned);
                return;
            };
        }
        if (g_site_setting_sink) |sink| sink(origin, types, allow);
    }

    /// Show the head of the queue, or hide the banner when it is empty.
    fn showPermPrompt(self: *WebFace) void {
        if (self.widgets_dead) return;
        if (self.perm_queue.items.len == 0) {
            c.gtk_widget_set_visible(self.perm_bar, 0);
            return;
        }
        const p = self.perm_queue.items[0];
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{s} wants to use {s}", .{
            if (p.origin.len != 0) p.origin else "This page",
            permissionLabel(p.types),
        }) catch "This page wants a permission";
        c.gtk_label_set_text(@ptrCast(self.perm_label), text.ptr);
        c.gtk_widget_set_visible(self.perm_bar, 1);
    }

    fn answerPermission(self: *WebFace, allow: bool) void {
        if (self.perm_queue.items.len == 0) {
            if (!self.widgets_dead) c.gtk_widget_set_visible(self.perm_bar, 0);
            return;
        }
        const p = self.perm_queue.orderedRemove(0);
        defer self.allocator.free(p.origin);
        self.postPermission(p.prompt, allow);
        if (p.origin.len != 0) self.rememberSetting(p.origin, p.types, allow);
        // Anything else already answered by the same decision goes with
        // it, so one Allow does not produce four identical banners.
        var i: usize = 0;
        while (i < self.perm_queue.items.len) {
            const q = self.perm_queue.items[i];
            if (q.types == p.types and std.mem.eql(u8, q.origin, p.origin)) {
                _ = self.perm_queue.orderedRemove(i);
                self.postPermission(q.prompt, allow);
                self.allocator.free(q.origin);
                continue;
            }
            i += 1;
        }
        self.showPermPrompt();
    }

    /// Drop every held prompt without answering: the engine dismisses
    /// its own prompts across a navigation, so the callbacks are gone.
    fn clearPermPrompts(self: *WebFace) void {
        for (self.perm_queue.items) |p| self.allocator.free(p.origin);
        self.perm_queue.clearRetainingCapacity();
        if (!self.widgets_dead) c.gtk_widget_set_visible(self.perm_bar, 0);
    }

    fn onPermAllow(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).answerPermission(true);
    }

    fn onPermBlock(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).answerPermission(false);
    }

    pub fn onCursor(self: *WebFace, cursor: u8) void {
        if (self.widgets_dead) return;
        const name: [*:0]const u8 = switch (@as(proto.Cursor, @enumFromInt(cursor))) {
            .pointer => "pointer",
            .text => "text",
            .wait => "wait",
            .crosshair => "crosshair",
            .not_allowed => "not-allowed",
            .grab => "grab",
            .grabbing => "grabbing",
            .ew_resize => "ew-resize",
            .ns_resize => "ns-resize",
            else => "default",
        };
        c.gtk_widget_set_cursor_from_name(self.view_area, name);
    }

    /// A popup (target=_blank, window.open) becomes a NEW web tab in
    /// this window — never a navigation of the page that asked.
    ///
    /// `user_gesture` decides whether it opens at all: under the
    /// default policy a popup the page produced on its own is BLOCKED
    /// and offered as a toast instead, which is the pop-under case. A
    /// helper that predates the flag reports every popup as gestured,
    /// so nothing changes against an old one.
    ///
    /// A per-site override stored for this origin wins over the
    /// app-level policy in both directions — that is the point of
    /// "allow popups on this site".
    pub fn onPopup(self: *WebFace, url: []const u8, user_gesture: bool) void {
        const open = switch (self.site_popup) {
            .allow => true,
            .block => false,
            .inherit => switch (g_popup_policy) {
                .allow => true,
                .block_all => false,
                .block_gestureless => user_gesture,
            },
        };
        if (open) {
            // Tree-style tabs: the popup nests under whatever opened it
            // (opener -> child, the TST relationship) — a page of this
            // browser, or a window tab, per `openInNewTab`.
            self.openInNewTab(url);
            return;
        }
        self.toastBlockedPopup(url);
    }

    /// Offer a blocked popup rather than swallowing it: a toast naming
    /// the host, with an Open button that opens the tab after all.
    fn toastBlockedPopup(self: *WebFace, url: []const u8) void {
        const win = self.ownerWindow() orelse return;
        var buf: [256]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "Popup blocked — {s}", .{hostOf(url)}) catch return;
        // Named `t` because the face already has a `toast` METHOD (the
        // plain, buttonless one); this popup toast needs a button, so
        // it is built here instead of going through it.
        const t = c.adw_toast_new(text.ptr);
        c.adw_toast_set_timeout(t, 6);
        // The toast OWNS the context (mechanism 1): the closure dies
        // with the toast, so a popup nobody opened frees itself and
        // there is no lifetime to remember. The context deliberately
        // holds no pointer to this face — a view id, resolved through
        // the immortal client at click time, cannot dangle.
        const ctx = self.allocator.create(PopupCtx) catch return;
        ctx.* = .{
            .allocator = self.allocator,
            .view = self.view,
            .url = self.allocator.dupe(u8, url) catch {
                self.allocator.destroy(ctx);
                return;
            },
        };
        c.adw_toast_set_button_label(t, "Open");
        _ = c.g_signal_connect_data(
            @ptrCast(t),
            "button-clicked",
            @ptrCast(&onPopupToastOpen),
            ctx,
            @ptrCast(&freePopupCtx),
            0,
        );
        c.adw_toast_overlay_add_toast(win.toast_overlay, t);
    }

    pub fn onCrashed(self: *WebFace) void {
        self.crashed = true;
        self.cancelHints();
        self.exitReader();
        self.dropMap();
        self.setStatus(CRASH_MSG, true);
    }

    /// The Window this face is displayed in, resolved through the
    /// widget root. Public because the omnibox dispatches command rows
    /// through it. Null once the widgets are dead.
    pub fn ownerWindow(self: *WebFace) ?*@import("window.zig").Window {
        if (self.widgets_dead) return null;
        const root = c.gtk_widget_get_root(self.root_box) orelse return null;
        return @import("remotectl.zig").windowFromGtk(@ptrCast(@alignCast(root)));
    }

    /// Bring this face's tab and pane to the front — what activating
    /// an omnibox open-tab candidate does instead of loading the page
    /// a second time.
    pub fn reveal(self: *WebFace) void {
        if (self.widgets_dead) return;
        const win = self.ownerWindow() orelse return;
        const pane = self.pane orelse return;
        if (@import("window.zig").tabPageForPane(win, pane)) |page|
            c.adw_tab_view_set_selected_page(win.tab_view, page);
        pane.setWebVisible(true);
        // The pane may be showing a DIFFERENT page of the same browser.
        if (self.group()) |g| g.setActive(self);
        self.reviveNow();
        _ = c.gtk_widget_grab_focus(self.view_area);
    }

    /// Tab page hosting this face's pane — the OPENER page for tabs
    /// this face spawns (tree-style tab nesting).
    fn ownerPage(self: *WebFace) ?*c.AdwTabPage {
        const pane = self.pane orelse return null;
        const win = self.ownerWindow() orelse return null;
        return @import("window.zig").tabPageForPane(win, pane);
    }

    // ---- commands ---------------------------------------------------

    /// Open `spec`, turning a bare host or a search-looking string into
    /// a URL the engine can take.
    pub fn navigate(self: *WebFace, spec: []const u8) void {
        const trimmed = std.mem.trim(u8, spec, " \t\r\n");
        if (trimmed.len == 0) return;
        // The article belongs to the document being left behind.
        self.exitReader();
        var buf: [4096]u8 = undefined;
        const url = normalizeUrl(&buf, trimmed) orelse return;
        if (self.pending_url) |u| self.allocator.free(u);
        self.pending_url = self.allocator.dupe(u8, url) catch null;
        self.crashed = false;
        self.clearStatus();
        const cl = self.cl;
        if (cl.state == .unavailable) {
            cl.restart();
            return;
        }
        cl.ensure(self.allocator);
        if (!self.view_live) {
            self.ensureView();
            return;
        }
        // The navigate frame IS the revive for a discarded view, and
        // the helper brings the browser back straight AT this url — so
        // only the GUI-side state is cleared here; sending `view_show`
        // as well would load the old address first.
        self.noteRevived();
        cl.post(proto.Navigate{ .view = self.view, .url = url });
        self.promote();
    }

    pub fn navAction(self: *WebFace, action: proto.NavAct) void {
        if (!self.view_live) return;
        // Same as a navigation: `nav_action` revives helper-side.
        self.noteRevived();
        self.cl.post(proto.NavAction{ .view = self.view, .action = @intFromEnum(action) });
        self.promote();
    }

    // ---- find-in-page ----------------------------------------------

    fn openFind(self: *WebFace) void {
        if (self.widgets_dead) return;
        c.gtk_widget_set_visible(self.find_bar, 1);
        _ = c.gtk_widget_grab_focus(self.find_entry);
    }

    fn closeFind(self: *WebFace) void {
        if (self.widgets_dead) return;
        c.gtk_widget_set_visible(self.find_bar, 0);
        c.gtk_label_set_text(@ptrCast(self.find_count), "");
        if (self.view_live)
            self.cl.post(proto.FindStop{ .view = self.view, .clear_selection = 1 });
        _ = c.gtk_widget_grab_focus(self.view_area);
    }

    /// The find entry's current text (borrowed from the widget).
    fn findQuery(self: *WebFace) []const u8 {
        const t = c.gtk_editable_get_text(@ptrCast(self.find_entry)) orelse return "";
        return std.mem.span(@as([*:0]const u8, @ptrCast(t)));
    }

    /// A NEW search for the entry's text; an emptied entry ends the
    /// search instead (matching every browser's find bar).
    fn findStart(self: *WebFace) void {
        if (self.widgets_dead or !self.view_live) return;
        const q = self.findQuery();
        if (q.len == 0) {
            c.gtk_label_set_text(@ptrCast(self.find_count), "");
            self.cl.post(proto.FindStop{ .view = self.view, .clear_selection = 1 });
            return;
        }
        self.cl.post(proto.Find{
            .view = self.view,
            .forward = 1,
            .match_case = 0,
            .find_next = 0,
            .text = q,
        });
        self.promote();
    }

    /// Step through the current search's matches.
    fn findStep(self: *WebFace, forward: bool) void {
        if (self.widgets_dead or !self.view_live) return;
        const q = self.findQuery();
        if (q.len == 0) return;
        self.cl.post(proto.Find{
            .view = self.view,
            .forward = if (forward) 1 else 0,
            .match_case = 0,
            .find_next = 1,
            .text = q,
        });
        self.promote();
    }

    pub fn onFindResult(self: *WebFace, ev: proto.EvFindResult) void {
        if (self.widgets_dead) return;
        if (c.gtk_widget_get_visible(self.find_bar) == 0) return;
        var buf: [64]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{d}/{d}", .{ ev.active, ev.count }) catch return;
        c.gtk_label_set_text(@ptrCast(self.find_count), z.ptr);
    }

    // ---- reader mode -------------------------------------------------

    /// The `web_reader` action, the toolbar toggle and the context-menu
    /// row all land here.
    pub fn toggleReader(self: *WebFace) void {
        if (self.reader_active) self.exitReader() else self.requestReader();
    }

    /// Ask the page for its article. The answer arrives on the socket,
    /// so this only starts the round trip; `onReadReply` finishes it.
    fn requestReader(self: *WebFace) void {
        if (self.widgets_dead) return;
        self.syncReaderButton(true);
        if (!self.view_live) {
            self.toast("The page is not ready yet.");
            self.syncReaderButton(false);
            return;
        }
        // `autoRead` refuses a second read while one is in flight — an
        // MCP `web_read` on the same view, or an earlier press.
        self.reader_token = self.autoRead() orelse {
            self.toast("Still reading this page. Try again in a moment.");
            self.syncReaderButton(false);
            return;
        };
    }

    /// A `sem_read_result` landed. It is only OURS when its token is
    /// the one this face is waiting on: an MCP `web_read` against the
    /// same view produces the same frame and must not be stolen.
    fn onReadReply(self: *WebFace) void {
        const token = self.reader_token orelse return;
        const res = self.autoTake(token) orelse return;
        defer self.allocator.free(res.text);
        self.reader_token = null;
        if (!res.ok) {
            self.toast("Could not read this page.");
            self.syncReaderButton(false);
            return;
        }
        self.enterReader(res.text);
    }

    fn enterReader(self: *WebFace, md: []const u8) void {
        if (self.widgets_dead) return;
        if (self.reader == null) {
            const r = webreader.Reader.create(
                self.allocator,
                @ptrCast(self),
                &readerLinkCb,
                &readerKeyCb,
            ) orelse {
                self.toast("Could not open the reader view.");
                self.syncReaderButton(false);
                return;
            };
            c.gtk_widget_set_visible(r.widget(), 0);
            // Last overlay child = on top of the frame, the sensor and
            // the status box, and the only one of them that takes
            // input, so the page underneath sees nothing while it shows.
            c.gtk_overlay_add_overlay(@ptrCast(self.overlay), r.widget());
            self.reader = r;
        }
        const r = self.reader.?;
        if (!r.setMarkdown(md, self.url orelse "")) {
            self.toast("No article found on this page.");
            self.syncReaderButton(false);
            return;
        }
        c.gtk_widget_set_visible(r.widget(), 1);
        c.gtk_widget_set_visible(self.picture, 0);
        self.reader_active = true;
        self.syncReaderButton(true);
        r.focus();
    }

    /// Back to the page. Cheap by design — the view never stopped
    /// living, so nothing is reloaded and no history entry was made.
    /// Also the exit path for a navigation, which is why it must be a
    /// no-op (and must NOT steal focus) when no reader is up.
    pub fn exitReader(self: *WebFace) void {
        const was_pending = self.reader_token != null;
        self.reader_token = null;
        if (!self.reader_active) {
            if (was_pending) self.syncReaderButton(false);
            return;
        }
        self.reader_active = false;
        if (self.widgets_dead) return;
        if (self.reader) |r| c.gtk_widget_set_visible(r.widget(), 0);
        c.gtk_widget_set_visible(self.picture, 1);
        self.syncReaderButton(false);
        _ = c.gtk_widget_grab_focus(self.view_area);
    }

    fn syncReaderButton(self: *WebFace, on: bool) void {
        if (self.widgets_dead) return;
        self.reader_syncing = true;
        defer self.reader_syncing = false;
        c.gtk_toggle_button_set_active(@ptrCast(self.reader_btn), if (on) @as(c_int, 1) else 0);
    }

    fn toast(self: *WebFace, msg: []const u8) void {
        const win = self.ownerWindow() orelse return;
        @import("window.zig").showToast(win, msg);
    }

    /// A link in the article: navigate the page underneath and leave
    /// reader mode, which is what a reader's link click means
    /// everywhere else too.
    fn readerLinkCb(ctx: ?*anyopaque, url: []const u8) void {
        const self = cast.userData(WebFace, ctx);
        self.exitReader();
        self.navigate(url);
    }

    /// Keys the reader did not want. Escape leaves; everything else
    /// gets the pane/window bindings, so a focused reader is no more of
    /// a keyboard trap than a focused page.
    fn readerKeyCb(ctx: ?*anyopaque, keyval: c.guint, state: c.GdkModifierType) bool {
        const self = cast.userData(WebFace, ctx);
        if (keyval == c.GDK_KEY_Escape) {
            self.exitReader();
            return true;
        }
        if (self.pane) |pane| {
            if (pane.input_ctx) |ictx| {
                if (input.fallbackToPaneBindings(ictx, keyval, state)) |handled| return handled != 0;
            }
        }
        return false;
    }

    fn onReaderToggled(btn: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (self.reader_syncing) return;
        if (c.gtk_toggle_button_get_active(@ptrCast(btn)) != 0)
            self.requestReader()
        else
            self.exitReader();
    }

    fn onMenuReader(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.toggleReader();
    }

    // ---- zoom -------------------------------------------------------

    /// Zoom bounds in level x100: 1.2^-7 (~28%) to 1.2^8 (~430%),
    /// Chromium's own preset range.
    const zoom_min_x100: i32 = -700;
    const zoom_max_x100: i32 = 800;

    fn zoomStep(self: *WebFace, dir: i32) void {
        self.setZoomLevel(std.math.clamp(self.zoom_x100 + dir * 100, zoom_min_x100, zoom_max_x100));
    }

    fn zoomReset(self: *WebFace) void {
        self.setZoomLevel(0);
    }

    /// Chromium zoom levels are logarithmic: factor = 1.2^(level/100).
    fn userZoomFactor(self: *const WebFace) f64 {
        if (self.zoom_x100 == 0) return 1.0;
        return std.math.pow(f64, 1.2, @as(f64, @floatFromInt(self.zoom_x100)) / 100.0);
    }

    fn setZoomLevel(self: *WebFace, level_x100: i32) void {
        if (level_x100 == self.zoom_x100) return;
        // A zoom rescales every hint rect; stale labels would lie.
        if (self.hints_active) self.cancelHints();
        self.zoom_x100 = level_x100;
        // A user-chosen zoom is a per-site setting: persist it on the
        // daemon so the origin comes back at this zoom (0 clears).
        if (self.nav_origin) |o| webstore.siteSetZoom(self.allocator, o, level_x100);
        if (!self.view_live) return;
        self.cl.post(proto.SetZoom{ .view = self.view, .level_x100 = level_x100 });
        self.promote();
    }

    /// Face-local chords, tried after the window bindings and before
    /// the page: Ctrl+F (find), Ctrl+=/-/0 (zoom). A page never sees
    /// these — the same trade every browser makes.
    fn faceChord(self: *WebFace, keyval: c.guint, state: c.GdkModifierType) bool {
        const s: c_int = @intCast(state);
        if (s & c.GDK_CONTROL_MASK == 0 or s & c.GDK_ALT_MASK != 0) return false;
        switch (c.gdk_keyval_to_lower(keyval)) {
            c.GDK_KEY_f => self.openFind(),
            c.GDK_KEY_equal, c.GDK_KEY_plus, c.GDK_KEY_KP_Add => self.zoomStep(1),
            c.GDK_KEY_minus, c.GDK_KEY_KP_Subtract => self.zoomStep(-1),
            c.GDK_KEY_0, c.GDK_KEY_KP_0 => self.zoomReset(),
            else => return false,
        }
        return true;
    }

    // ---- context menu ----------------------------------------------

    /// Per-popup state for the context menu's rows; owned by the menu
    /// Root (freed when the popover dies), never by the rows.
    const MenuCtx = struct {
        allocator: std.mem.Allocator,
        face: *WebFace,
        page: ?[]u8 = null,
        link: ?[]u8 = null,
    };

    fn freeMenuCtx(user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(MenuCtx, user);
        if (ctx.page) |p| ctx.allocator.free(p);
        if (ctx.link) |l| ctx.allocator.free(l);
        ctx.allocator.destroy(ctx);
    }

    /// The helper suppressed the engine's menu and reported the hit
    /// test; show ours at the reported page position.
    pub fn onContextMenu(self: *WebFace, ev: proto.EvContextMenu) void {
        if (self.widgets_dead) return;
        // Not on an inspector pane: our menu's verbs (Back, Reload,
        // Copy Page URL) would act on the DEVTOOLS browser, which is
        // never what a right-click inside the inspector means.
        if (self.attached) return;
        const root = classicmenu.Root.create(self.allocator) orelse return;
        const ctx = self.allocator.create(MenuCtx) catch {
            root.destroy();
            return;
        };
        ctx.* = .{ .allocator = self.allocator, .face = self };
        if (self.url) |u| ctx.page = self.allocator.dupe(u8, u) catch null;
        if (ev.flags & proto.ctx_flag_link != 0 and ev.link_url.len != 0)
            ctx.link = self.allocator.dupe(u8, ev.link_url) catch null;
        root.own(freeMenuCtx, ctx);

        const m = root.top();
        m.itemIconEnabled("Back", .{ .name = "go-previous-symbolic" }, self.can_back, &onMenuBack, ctx);
        m.itemIconEnabled("Forward", .{ .name = "go-next-symbolic" }, self.can_fwd, &onMenuForward, ctx);
        m.itemIcon("Reload", .{ .name = "view-refresh-symbolic" }, &onMenuReload, ctx);
        if (ctx.link != null) {
            const links = m.section();
            links.item("Open Link in New Tab", &onMenuOpenLink, ctx);
            links.item("Copy Link URL", &onMenuCopyLink, ctx);
        }
        const page = m.section();
        page.check("Reader View", self.reader_active, &onMenuReader, ctx);
        page.itemIconEnabled("Copy Page URL", .none, ctx.page != null, &onMenuCopyUrl, ctx);
        page.checkEnabled(
            "Bookmark This Page",
            self.bookmark_id != 0,
            ctx.page != null,
            &onMenuBookmark,
            ctx,
        );
        // Per-site popup override. Only offered once the page has an
        // origin to attach it to (about:blank has none).
        page.checkEnabled(
            "Allow Popups on This Site",
            self.site_popup == .allow,
            self.nav_origin != null,
            &onMenuAllowPopups,
            ctx,
        );

        const store_section = m.section();
        store_section.itemIcon("History", .{ .name = "document-open-recent-symbolic" }, &onMenuHistory, ctx);
        store_section.itemIcon("Bookmarks", .{ .name = "starred-symbolic" }, &onMenuBookmarks, ctx);
        store_section.itemIcon("Userscripts…", .{ .name = "application-x-addon-symbolic" }, &onMenuUserscripts, ctx);
        // A style needs a site to be scoped to; about:blank has none.
        store_section.itemIconEnabled(
            "Edit Site Style…",
            .{ .name = "applications-graphics-symbolic" },
            self.nav_origin != null,
            &onMenuSiteStyle,
            ctx,
        );
        // A helper too old for either verb greys the row out rather
        // than hiding it: what a browser pane CAN do stays visible.
        const cl = self.cl;
        const tools = m.section();
        tools.itemIconEnabled(
            "Print to PDF…",
            .{ .name = "document-print-symbolic" },
            // A remote helper would write the PDF on ITS host; greyed
            // out until the remote fetch path exists.
            self.view_live and cl.cap_print_pdf and !cl.isRemote(),
            &onMenuPrintPdf,
            ctx,
        );
        tools.itemIconEnabled(
            "Open DevTools",
            .{ .name = "applications-engineering-symbolic" },
            self.view_live and !self.attached and cl.cap_devtools,
            &onMenuDevTools,
            ctx,
        );
        tools.itemIconEnabled(
            "Fill Password…",
            .{ .name = "dialog-password-symbolic" },
            self.view_live and ctx.page != null,
            &onMenuFillPassword,
            ctx,
        );

        // Container / identity actions.
        const tabs = m.section();
        tabs.itemIcon("New Incognito Web Tab", .{ .name = "view-private-symbolic" }, &onMenuIncognito, ctx);
        tabs.itemIconEnabled(
            "Extensions…",
            .{ .name = "application-x-addon-symbolic" },
            client().cap_webext,
            &onMenuExtensions,
            ctx,
        );
        if (containers().len != 0) {
            const cont = tabs.submenu("New Tab in Container");
            for (containers()) |*ctn| {
                const rc = self.allocator.create(ContainerRowCtx) catch continue;
                rc.* = .{ .allocator = self.allocator, .face = self, .container = ctn.id };
                root.own(freeContainerRowCtx, rc);
                var lbuf: [128]u8 = undefined;
                cont.item(classicmenu.escapeLabel(ctn.name, &lbuf), &onMenuOpenInContainer, rc);
            }
        }

        const x: f64 = @floatFromInt(ev.x + @as(i32, self.snap_dx));
        const y: f64 = @floatFromInt(ev.y + @as(i32, self.snap_dy));
        _ = root.popup(self.view_area, x, y);
    }

    const ContainerRowCtx = struct {
        allocator: std.mem.Allocator,
        face: *WebFace,
        container: u32,
    };

    fn freeContainerRowCtx(user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(ContainerRowCtx, user);
        ctx.allocator.destroy(ctx);
    }

    fn onMenuIncognito(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const win = cast.userData(MenuCtx, user).face.ownerWindow() orelse return;
        win.newIncognitoWebTab() catch {};
    }

    fn onMenuExtensions(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        const win = face.ownerWindow() orelse return;
        webext.openManager(face.allocator, @ptrCast(@alignCast(win.app_window)));
    }

    fn onMenuOpenInContainer(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const rc = cast.userData(ContainerRowCtx, user);
        const win = rc.face.ownerWindow() orelse return;
        win.newWebTabInContainer(rc.container, null) catch {};
    }

    fn copyText(self: *WebFace, text: []const u8) void {
        if (self.widgets_dead) return;
        clipboard.copyText(self.allocator, self.root_box, text);
    }

    fn onMenuBack(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.navAction(.back);
    }

    fn onMenuForward(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.navAction(.forward);
    }

    fn onMenuReload(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.navAction(.reload);
    }

    fn onMenuCopyUrl(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(MenuCtx, user);
        if (ctx.page) |p| ctx.face.copyText(p);
    }

    fn onMenuCopyLink(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(MenuCtx, user);
        if (ctx.link) |l| ctx.face.copyText(l);
    }

    fn onMenuOpenLink(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(MenuCtx, user);
        const link = ctx.link orelse return;
        ctx.face.openInNewTab(link);
    }

    fn onMenuBookmark(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        onStar(face.star_btn, @ptrCast(face));
    }

    /// Store (or clear) this origin's popup override and apply it at
    /// once, so the next popup from the page obeys without a reload.
    fn onMenuAllowPopups(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        const origin = face.nav_origin orelse return;
        if (face.site_popup == .allow) {
            face.site_popup = .inherit;
            webstore.siteSetPopup(face.allocator, origin, "");
        } else {
            face.site_popup = .allow;
            webstore.siteSetPopup(face.allocator, origin, "allow");
        }
    }

    fn onMenuHistory(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        const win = face.ownerWindow() orelse return;
        webhistory.openHistory(win, face.pane);
    }

    fn onMenuBookmarks(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        const win = face.ownerWindow() orelse return;
        webhistory.openBookmarks(win, face.pane);
    }

    fn onMenuUserscripts(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        const win = face.ownerWindow() orelse return;
        webuserscripts.openManager(win);
    }

    fn onMenuSiteStyle(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        const win = face.ownerWindow() orelse return;
        const origin = face.nav_origin orelse return;
        // The style is keyed by HOST: strip the origin's scheme and
        // any port, so http/https share one style per site.
        var host = origin;
        if (std.mem.indexOf(u8, host, "://")) |i| host = host[i + 3 ..];
        if (std.mem.lastIndexOfScalar(u8, host, ':')) |ci| host = host[0..ci];
        if (host.len == 0) return;
        webuserscripts.openSiteStyle(win, host);
    }

    fn onMenuDevTools(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.openDevTools();
    }

    fn onMenuPrintPdf(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.printToPdf();
    }

    fn onMenuFillPassword(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.fillPassword();
    }

    // ---- toolbar hamburger -------------------------------------------

    fn onBurger(btn: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).showBurgerMenu(btn);
    }

    /// The toolbar's primary menu: every verb this face already has,
    /// gathered in one place.
    ///
    /// It shares the page context menu's handlers (and its `MenuCtx`)
    /// rather than repeating them — the difference between the two
    /// menus is which rows they list, never what a row does. Link rows
    /// are absent here: a toolbar click has no hit test behind it.
    fn showBurgerMenu(self: *WebFace, anchor: *c.GtkWidget) void {
        if (self.widgets_dead) return;
        const root = classicmenu.Root.create(self.allocator) orelse return;
        const ctx = self.allocator.create(MenuCtx) catch {
            root.destroy();
            return;
        };
        ctx.* = .{ .allocator = self.allocator, .face = self };
        if (self.url) |u| ctx.page = self.allocator.dupe(u8, u) catch null;
        root.own(freeMenuCtx, ctx);

        const m = root.top();
        m.itemIconEnabled("Back", .{ .name = "go-previous-symbolic" }, self.can_back, &onMenuBack, ctx);
        m.itemIconEnabled("Forward", .{ .name = "go-next-symbolic" }, self.can_fwd, &onMenuForward, ctx);
        m.itemIcon("Reload", .{ .name = "view-refresh-symbolic" }, &onMenuReload, ctx);

        const view = m.section();
        view.itemIcon("Find in Page…", .{ .name = "edit-find-symbolic" }, &onMenuFind, ctx);
        view.itemIcon("Zoom In", .{ .name = "zoom-in-symbolic" }, &onMenuZoomIn, ctx);
        view.itemIcon("Zoom Out", .{ .name = "zoom-out-symbolic" }, &onMenuZoomOut, ctx);
        view.itemIconEnabled("Reset Zoom", .{ .name = "zoom-original-symbolic" }, self.zoom_x100 != 0, &onMenuZoomReset, ctx);
        view.check("Reader View", self.reader_active, &onMenuReader, ctx);

        const page = m.section();
        page.itemIconEnabled("Copy Page URL", .none, ctx.page != null, &onMenuCopyUrl, ctx);
        page.checkEnabled("Bookmark This Page", self.bookmark_id != 0, ctx.page != null, &onMenuBookmark, ctx);
        page.checkEnabled(
            "Allow Popups on This Site",
            self.site_popup == .allow,
            self.nav_origin != null,
            &onMenuAllowPopups,
            ctx,
        );

        const store_section = m.section();
        store_section.itemIcon("History", .{ .name = "document-open-recent-symbolic" }, &onMenuHistory, ctx);
        store_section.itemIcon("Bookmarks", .{ .name = "starred-symbolic" }, &onMenuBookmarks, ctx);
        // The strip shows itself when a download starts; this row is
        // how it comes BACK after being dismissed, so it is dead
        // weight while this face has downloaded nothing.
        store_section.checkEnabled(
            "Downloads",
            self.downloads.items.len != 0 and c.gtk_widget_get_visible(self.dl_strip) != 0,
            self.downloads.items.len != 0,
            &onMenuDownloads,
            ctx,
        );

        const cl = client();
        const tools = m.section();
        tools.itemIconEnabled(
            "Print to PDF…",
            .{ .name = "document-print-symbolic" },
            self.view_live and cl.cap_print_pdf,
            &onMenuPrintPdf,
            ctx,
        );
        tools.itemIconEnabled(
            "Open DevTools",
            .{ .name = "applications-engineering-symbolic" },
            self.view_live and !self.attached and cl.cap_devtools,
            &onMenuDevTools,
            ctx,
        );
        tools.itemIconEnabled(
            "Fill Password…",
            .{ .name = "dialog-password-symbolic" },
            self.view_live and ctx.page != null,
            &onMenuFillPassword,
            ctx,
        );

        const tabs = m.section();
        tabs.itemIcon("New Incognito Web Tab", .{ .name = "view-private-symbolic" }, &onMenuIncognito, ctx);
        if (containers().len != 0) {
            const cont = tabs.submenu("New Tab in Container");
            for (containers()) |*ctn| {
                const rc = self.allocator.create(ContainerRowCtx) catch continue;
                rc.* = .{ .allocator = self.allocator, .face = self, .container = ctn.id };
                root.own(freeContainerRowCtx, rc);
                var lbuf: [128]u8 = undefined;
                cont.item(classicmenu.escapeLabel(ctn.name, &lbuf), &onMenuOpenInContainer, rc);
            }
        }
        tabs.itemIconEnabled(
            "Show This Pane's Shell",
            .{ .name = "sketerm-terminal-symbolic" },
            self.pane != null,
            &onMenuShell,
            ctx,
        );

        appmenu.appendHelp(
            m,
            self.allocator,
            if (self.ownerWindow()) |w| @ptrCast(@alignCast(w.app_window)) else null,
            .web,
        );

        _ = root.popup(
            anchor,
            @floatFromInt(@divTrunc(c.gtk_widget_get_width(anchor), 2)),
            @floatFromInt(c.gtk_widget_get_height(anchor)),
        );
    }

    fn onMenuFind(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.openFind();
    }

    fn onMenuZoomIn(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.zoomStep(1);
    }

    fn onMenuZoomOut(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.zoomStep(-1);
    }

    fn onMenuZoomReset(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        cast.userData(MenuCtx, user).face.zoomReset();
    }

    fn onMenuDownloads(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        if (face.widgets_dead) return;
        const on = c.gtk_widget_get_visible(face.dl_strip) != 0;
        c.gtk_widget_set_visible(face.dl_strip, if (on) 0 else 1);
    }

    fn onMenuShell(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const face = cast.userData(MenuCtx, user).face;
        onShowShell(face.shell_btn, @ptrCast(face));
    }

    // ---- password fill (Secret Service) ------------------------------

    /// Picker state for one "Fill Password…" popup, owned by the menu
    /// Root exactly like `MenuCtx`. It holds candidate LOGINS, never a
    /// secret: the secret is fetched only for the row the user picks
    /// and is wiped the moment it has been typed.
    const FillCtx = struct {
        allocator: std.mem.Allocator,
        face: *WebFace,
        matches: secrets.Matches,
        rows: []FillRow,
    };

    /// One row's user-data. Borrowed from the FillCtx that owns it.
    const FillRow = struct { ctx: *FillCtx, index: usize };

    fn freeFillCtx(user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(FillCtx, user);
        ctx.allocator.free(ctx.rows);
        ctx.matches.deinit();
        ctx.allocator.destroy(ctx);
    }

    /// Offer the keyring logins saved for this page's host, and type
    /// the picked one into the page as `username`, Tab, `password`.
    ///
    /// FILL ONLY, deliberately: sketerm never offers to save a
    /// password, never writes to the keyring, and never fills on load.
    /// The keyring is read once, when the user asks for it.
    ///
    /// FOCUS IS THE USER'S JOB. The characters go through the same
    /// trusted-input path as the keyboard (`sendKey` -> `input_key` ->
    /// CEF char events), so they land in whatever the page has
    /// focused — click the username field first. A page cannot tell
    /// this apart from typing, which is the point: no field-detection
    /// heuristic to be fooled, and no bridge into the page's DOM.
    pub fn fillPassword(self: *WebFace) void {
        if (self.widgets_dead) return;
        if (!self.view_live) {
            self.toast("This pane has no live web page.");
            return;
        }
        const addr: []const u8 = self.url orelse self.pending_url orelse "";
        const host = secrets.hostOf(addr);
        if (host.len == 0) {
            self.toast("This page has no address to match a saved login against.");
            return;
        }

        var matches = secrets.findForHost(self.allocator, host) catch |err| {
            self.toast(switch (err) {
                error.NoBus, error.NoService => "No password manager answered on the session bus (org.freedesktop.secrets).",
                else => "Could not read the keyring.",
            });
            return;
        };
        if (matches.items.len == 0) {
            matches.deinit();
            var buf: [320]u8 = undefined;
            self.toast(std.fmt.bufPrint(&buf, "No saved login for {s}.", .{host}) catch
                "No saved login for this site.");
            return;
        }

        var ok = false;
        defer if (!ok) matches.deinit();
        const root = classicmenu.Root.create(self.allocator) orelse return;
        var built = false;
        defer if (!built) root.destroy();

        const ctx = self.allocator.create(FillCtx) catch return;
        const rows = self.allocator.alloc(FillRow, matches.items.len) catch {
            self.allocator.destroy(ctx);
            return;
        };
        ctx.* = .{
            .allocator = self.allocator,
            .face = self,
            .matches = matches,
            .rows = rows,
        };
        ok = true;
        root.own(freeFillCtx, ctx);

        const menu = root.top();
        var text: [512]u8 = undefined;
        var label: [512]u8 = undefined;
        for (ctx.rows, 0..) |*row, i| {
            row.* = .{ .ctx = ctx, .index = i };
            menu.itemIcon(
                classicmenu.escapeLabel(fillRowLabel(&text, ctx.matches.items[i]), &label),
                .{ .name = "dialog-password-symbolic" },
                &onFillPick,
                row,
            );
        }
        built = true;
        const w: f64 = @floatFromInt(c.gtk_widget_get_width(self.view_area));
        _ = root.popup(self.view_area, w / 2, 24);
    }

    /// "user (label)", or the label alone for an entry with no login
    /// name. A locked entry says so — picking it may still fail.
    fn fillRowLabel(buf: []u8, m: secrets.Match) []const u8 {
        const lock: []const u8 = if (m.locked) " [locked]" else "";
        if (m.username.len != 0 and m.label.len != 0)
            return std.fmt.bufPrint(buf, "{s} ({s}){s}", .{ m.username, m.label, lock }) catch m.username;
        if (m.username.len != 0)
            return std.fmt.bufPrint(buf, "{s}{s}", .{ m.username, lock }) catch m.username;
        return std.fmt.bufPrint(buf, "{s}{s}", .{ m.label, lock }) catch m.label;
    }

    fn onFillPick(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
        const row = cast.userData(FillRow, user);
        row.ctx.face.fillFrom(row.ctx.matches.items[row.index]);
    }

    /// Fetch one entry's secret and type it. The buffer is wiped by
    /// `zeroFree` on every path, and the secret is never formatted
    /// into a toast, a title or a log line.
    fn fillFrom(self: *WebFace, m: secrets.Match) void {
        if (self.widgets_dead or !self.view_live) return;
        const secret = secrets.fetchSecret(self.allocator, m.path, m.locked) catch |err| {
            self.toast(switch (err) {
                error.Locked => "That entry is locked. Unlock the keyring, then try again.",
                error.NoBus, error.NoService => "The password manager stopped answering.",
                else => "Could not read that entry's password.",
            });
            return;
        };
        defer secrets.zeroFree(self.allocator, secret);
        // Typing walks codepoints, so a non-text secret (a key blob)
        // has to be refused rather than decoded.
        if (!std.unicode.utf8ValidateSlice(secret)) {
            self.toast("That entry's secret is not text.");
            return;
        }
        if (m.username.len != 0 and std.unicode.utf8ValidateSlice(m.username)) {
            self.typeIntoPage(m.username);
            self.tapKeyval(c.GDK_KEY_Tab);
        }
        self.typeIntoPage(secret);
    }

    /// Type `text` as ordinary key presses. `gdk_unicode_to_keyval`
    /// round-trips through the helper's `gdk_keyval_to_unicode`, so
    /// non-Latin1 characters survive.
    fn typeIntoPage(self: *WebFace, text: []const u8) void {
        var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        while (it.nextCodepoint()) |cp| self.tapKeyval(c.gdk_unicode_to_keyval(cp));
    }

    fn tapKeyval(self: *WebFace, keyval: c.guint) void {
        _ = self.sendKey(.down, keyval, 0, 0);
        _ = self.sendKey(.up, keyval, 0, 0);
    }

    // ---- DevTools ---------------------------------------------------

    /// Ask the helper for this page's inspector. The pane is opened by
    /// the REPLY (`ev_devtools_view`), because only then is there a
    /// view id to present.
    pub fn openDevTools(self: *WebFace) void {
        // An inspector cannot inspect itself.
        if (self.attached) return;
        if (!self.view_live) return;
        if (!self.cl.cap_devtools) {
            self.toast("This browser helper is too old for DevTools.");
            return;
        }
        if (self.devtools_pending) return;
        self.devtools_pending = true;
        self.cl.post(proto.DevToolsShow{ .view = self.view, .x = 0, .y = 0 });
    }

    /// The helper's answer: split this pane and give the new one a face
    /// bound to the inspector view.
    fn onDevToolsView(self: *WebFace, dev_view: u32, reason: []const u8) void {
        self.devtools_pending = false;
        if (dev_view == 0) {
            // `windowed` is not a failure: the inspector IS open, the
            // engine just insisted on giving it a window of its own
            // (every CEF 151 build does — src/web/cefhost.zig
            // `adoptBrowser`). Saying "could not open" there would be a
            // lie about a window the user is looking at.
            if (std.mem.eql(u8, reason, "windowed")) {
                self.toast("DevTools opened in its own window (this browser engine cannot render it inside a pane).");
                return;
            }
            self.toast("The browser engine did not open DevTools for this page.");
            return;
        }
        const pane = self.pane orelse {
            self.cl.post(proto.ViewDestroy{ .view = dev_view });
            return;
        };
        const win = self.ownerWindow() orelse {
            self.cl.post(proto.ViewDestroy{ .view = dev_view });
            return;
        };
        // A view nobody presents is a browser nobody can close: every
        // failure below hands it straight back.
        win.openDevToolsSplit(pane, dev_view) catch {
            self.cl.post(proto.ViewDestroy{ .view = dev_view });
            self.toast("Could not open a pane for DevTools.");
        };
    }

    // ---- print to PDF -------------------------------------------------

    /// User-data for the save dialog: the VIEW id, never the face
    /// pointer. The dialog outlives a pane close by construction, and
    /// looking the face back up in the client's registry — which a dead
    /// face leaves — is the liveness fence for exactly that.
    const PrintCtx = struct {
        allocator: std.mem.Allocator,
        view: u32,
    };

    /// Save dialog -> `print_pdf`. The helper writes the file itself
    /// (it is the process holding the page), so the pick has to be a
    /// path on THIS machine.
    pub fn printToPdf(self: *WebFace) void {
        if (!self.view_live) return;
        if (!self.cl.cap_print_pdf) {
            self.toast("This browser helper is too old to print to PDF.");
            return;
        }
        const pickwin = @import("picker.zig");
        const ctx = self.allocator.create(PrintCtx) catch return;
        ctx.* = .{ .allocator = self.allocator, .view = self.view };
        var name_buf: [160]u8 = undefined;
        const suggested = self.suggestedPdfName(&name_buf);
        const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
        _ = pickwin.PickerWindow.open(self.allocator, win, .{
            .mode = .save_file,
            .title = "Print to PDF",
            .suggested_name = suggested,
            .local_only = true,
        }, &onPdfPathPicked, @ptrCast(ctx)) catch {
            self.allocator.destroy(ctx);
            self.toast("Could not open the save dialog.");
        };
    }

    /// `<page title>.pdf`, with everything a filename should not carry
    /// flattened to '-'. A page with no title saves as "page.pdf".
    fn suggestedPdfName(self: *WebFace, buf: []u8) []const u8 {
        const title = self.title orelse return "page.pdf";
        var n: usize = 0;
        const room = @min(buf.len - 5, 80);
        for (title) |ch| {
            if (n >= room) break;
            buf[n] = switch (ch) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ' ', '.' => ch,
                else => '-',
            };
            n += 1;
        }
        while (n > 0 and (buf[n - 1] == ' ' or buf[n - 1] == '.' or buf[n - 1] == '-')) n -= 1;
        if (n == 0) return "page.pdf";
        @memcpy(buf[n..][0..4], ".pdf");
        return buf[0 .. n + 4];
    }

    fn onPdfPathPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
        const ctx: *PrintCtx = @ptrCast(@alignCast(user.?));
        defer ctx.allocator.destroy(ctx);
        const self = findFaceGlobal(ctx.view) orelse return;
        const res = result orelse return;
        if (res.specs.len == 0) return;
        const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
        // The HELPER writes the file and it runs on this machine; a
        // `host:/path` pick has nothing that could honour it.
        const path = @import("picker.zig").localPathOrRefuse(
            win,
            res.specs[0],
            "The browser engine writes the PDF itself, on this machine — pick a local path.",
        ) orelse return;
        if (!self.view_live) return;
        self.cl.post(proto.PrintPdf{
            .view = self.view,
            // Background graphics ON: a page saved without them looks
            // broken, which is not what "print this page" means here.
            .flags = proto.print_flag_background,
            .paper = @intFromEnum(proto.Paper.default),
            .path = path,
        });
        var msg: [512]u8 = undefined;
        self.toast(std.fmt.bufPrint(&msg, "Printing to {s}…", .{path}) catch "Printing to PDF…");
    }

    fn onPrintDone(self: *WebFace, ok: bool, path: []const u8) void {
        var msg: [512]u8 = undefined;
        if (!ok) {
            self.toast(std.fmt.bufPrint(&msg, "Could not write {s}", .{path}) catch "Could not write the PDF");
            return;
        }
        const win = self.ownerWindow() orelse return;
        const text = std.fmt.bufPrintZ(&msg, "Saved {s}", .{path}) catch "Saved the PDF";
        const note = c.adw_toast_new(text.ptr);
        c.adw_toast_set_timeout(note, 8);
        // The toast OWNS the path (mechanism 1): GObject frees attached
        // data at finalize, strictly after the button can be clicked,
        // so the Open handler can never read freed memory. c_allocator
        // and not the face's, because the string outlives the face.
        if (std.heap.c_allocator.dupeZ(u8, path)) |owned| {
            c.adw_toast_set_button_label(note, "Open");
            c.g_object_set_data_full(
                @ptrCast(@alignCast(note)),
                "sketerm-pdf-path",
                @ptrCast(owned.ptr),
                @ptrCast(&freeToastPath),
            );
            _ = c.g_signal_connect_data(
                @ptrCast(@alignCast(note)),
                "button-clicked",
                @ptrCast(&onToastOpen),
                @ptrCast(owned.ptr),
                null,
                0,
            );
        } else |_| {}
        c.adw_toast_overlay_add_toast(win.toast_overlay, note);
    }

    /// Hand the finished PDF to whatever the desktop opens PDFs with.
    fn onToastOpen(_: ?*c.AdwToast, user: ?*anyopaque) callconv(.c) void {
        const path: [*:0]const u8 = @ptrCast(user orelse return);
        var uri: [4096:0]u8 = undefined;
        const u = std.fmt.bufPrintZ(&uri, "file://{s}", .{std.mem.span(path)}) catch return;
        _ = c.g_app_info_launch_default_for_uri(u.ptr, null, null);
    }

    // ---- downloads --------------------------------------------------
    //
    // The helper HOLDS every download's target decision until the face
    // answers (`ev_download_offer` / `download_decide`). A local pick
    // downloads straight to it; a `host:` pick (the picker browses
    // remote hosts natively) downloads to a LOCAL staging file first
    // and then hands off to the daemon's durable transfer path — v1
    // deliberately routes origin -> local -> server, never
    // fetch-on-server.

    fn findDownload(self: *WebFace, id: u32) ?*Download {
        for (self.downloads.items) |d| {
            if (d.id == id) return d;
        }
        return null;
    }

    /// Static — callable from contexts whose face may be gone; the
    /// decision goes to whichever client owns the view (a held decision
    /// must always be answered).
    fn declineDownload(view: u32, id: u32) void {
        const cl = if (findFaceGlobal(view)) |f| f.cl else client();
        cl.post(proto.DownloadDecide{ .view = view, .id = id, .path = "" });
    }

    fn onDownloadOffer(self: *WebFace, ev: proto.EvDownloadOffer) void {
        if (self.widgets_dead) {
            declineDownload(ev.view, ev.id);
            return;
        }
        // A remote helper would write the picked path on ITS host, not
        // here — silently dropping files on the wrong machine. Decline
        // with a visible reason until the remote download path (helper
        // staging dir -> daemon file_get -> local pick) is designed;
        // this branch is the seam it plugs into.
        if (self.cl.isRemote()) {
            declineDownload(ev.view, ev.id);
            self.toast("Downloads are not yet supported in a remote-browser container");
            return;
        }
        const name = if (ev.name.len != 0) ev.name else "download";
        if (!g_download_ask) {
            self.autoAcceptDownload(ev.id, name);
            return;
        }
        const pickwin = @import("picker.zig");
        const ctx = self.allocator.create(DlPickCtx) catch {
            declineDownload(ev.view, ev.id);
            return;
        };
        ctx.* = .{
            .allocator = self.allocator,
            .view = self.view,
            .id = ev.id,
            .name = self.allocator.dupe(u8, name) catch {
                self.allocator.destroy(ctx);
                declineDownload(ev.view, ev.id);
                return;
            },
        };
        const win = self.ownerWindow();
        const gwin: ?*c.GtkWindow = if (win) |w| @ptrCast(w.app_window) else null;
        _ = pickwin.PickerWindow.open(self.allocator, gwin, .{
            .mode = .save_file,
            .title = "Save Download",
            .suggested_name = name,
            // Per-window memory: start where this window last saved.
            .initial_spec = if (win) |w| w.web_download_dir else null,
        }, &onDlPathPicked, @ptrCast(ctx)) catch {
            ctx.free();
            declineDownload(ev.view, ev.id);
            self.toast("Could not open the save dialog.");
        };
    }

    /// `web_download_ask = false`: straight into ~/Downloads under the
    /// suggested name, uniquified rather than overwritten.
    fn autoAcceptDownload(self: *WebFace, id: u32, name: []const u8) void {
        const home = c.getenv("HOME") orelse {
            declineDownload(self.view, id);
            return;
        };
        var dir_buf: [4096:0]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/Downloads", .{std.mem.span(@as([*:0]const u8, @ptrCast(home)))}) catch {
            declineDownload(self.view, id);
            return;
        };
        _ = c.mkdir(dir.ptr, 0o755);
        var path_buf: [4608]u8 = undefined;
        const path = uniquePath(&path_buf, dir, name) orelse {
            declineDownload(self.view, id);
            return;
        };
        self.startDownload(id, name, path, "", "");
    }

    fn onDlPathPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
        const ctx: *DlPickCtx = @ptrCast(@alignCast(user.?));
        defer ctx.free();
        const res = result orelse {
            declineDownload(ctx.view, ctx.id);
            return;
        };
        if (res.specs.len == 0) {
            declineDownload(ctx.view, ctx.id);
            return;
        }
        // The face may have died while the dialog was up; the held
        // decision still has to be answered (the client is immortal).
        const self = findFaceGlobal(ctx.view) orelse {
            declineDownload(ctx.view, ctx.id);
            return;
        };
        const spec = res.specs[0];
        self.rememberDownloadDir(spec);
        const loc = @import("../filebrowser/paths.zig").parseSpec(spec);
        const leaf = std.fs.path.basename(loc.path);
        const name = if (leaf.len != 0) leaf else ctx.name;
        if (loc.host) |host| {
            // Remote target: stage locally, hand off on completion.
            var stage_buf: [4608]u8 = undefined;
            const staging = self.stagingPath(&stage_buf, ctx.id, name) orelse {
                declineDownload(ctx.view, ctx.id);
                self.toast("No writable cache directory to stage the download in.");
                return;
            };
            self.startDownload(ctx.id, name, staging, host, loc.path);
            return;
        }
        self.startDownload(ctx.id, name, loc.path, "", "");
    }

    /// `$XDG_CACHE_HOME/sketerm/webdl/<id>-<name>`: where a redirected
    /// download lands before its daemon handoff. Unlinked when the
    /// handoff finishes (or its row is dismissed).
    fn stagingPath(self: *WebFace, buf: []u8, id: u32, name: []const u8) ?[]const u8 {
        _ = self;
        var root_buf: [4096]u8 = undefined;
        const cache: []const u8 = blk: {
            if (c.getenv("XDG_CACHE_HOME")) |x| {
                const s = std.mem.span(@as([*:0]const u8, @ptrCast(x)));
                if (s.len != 0) break :blk s;
            }
            const home = c.getenv("HOME") orelse return null;
            break :blk std.fmt.bufPrint(&root_buf, "{s}/.cache", .{std.mem.span(@as([*:0]const u8, @ptrCast(home)))}) catch return null;
        };
        var z: [4096:0]u8 = undefined;
        const d1 = std.fmt.bufPrintZ(&z, "{s}/sketerm", .{cache}) catch return null;
        _ = c.mkdir(d1.ptr, 0o700);
        const d2 = std.fmt.bufPrintZ(&z, "{s}/sketerm/webdl", .{cache}) catch return null;
        _ = c.mkdir(d2.ptr, 0o700);
        return std.fmt.bufPrint(buf, "{s}/sketerm/webdl/{d}-{s}", .{ cache, id, name }) catch null;
    }

    fn rememberDownloadDir(self: *WebFace, spec: []const u8) void {
        const win = self.ownerWindow() orelse return;
        const slash = std.mem.lastIndexOfScalar(u8, spec, '/') orelse return;
        if (slash == 0) return;
        const dir = spec[0..slash];
        const owned = win.allocator.dupe(u8, dir) catch return;
        if (win.web_download_dir) |old| win.allocator.free(old);
        win.web_download_dir = owned;
    }

    /// Create the tracking entry + strip row and answer the held offer
    /// with `path`.
    fn startDownload(self: *WebFace, id: u32, name: []const u8, path: []const u8, remote_host: []const u8, remote_path: []const u8) void {
        if (self.findDownload(id) != null) return;
        const d = self.allocator.create(Download) catch {
            declineDownload(self.view, id);
            return;
        };
        d.* = .{
            .id = id,
            .name = self.allocator.dupe(u8, name) catch &.{},
            .path = self.allocator.dupe(u8, path) catch &.{},
            .remote_host = self.allocator.dupe(u8, remote_host) catch &.{},
            .remote_path = self.allocator.dupe(u8, remote_path) catch &.{},
            .row = undefined,
            .label = undefined,
            .bar = undefined,
            .status = undefined,
            .cancel_btn = undefined,
            .open_btn = undefined,
            .reveal_btn = undefined,
        };
        if (d.path.len == 0) {
            d.free(self.allocator);
            declineDownload(self.view, id);
            return;
        }
        self.downloads.append(self.allocator, d) catch {
            d.free(self.allocator);
            declineDownload(self.view, id);
            return;
        };
        self.buildDlRow(d);
        self.cl.post(proto.DownloadDecide{ .view = self.view, .id = id, .path = d.path });
    }

    fn buildDlRow(self: *WebFace, d: *Download) void {
        if (self.widgets_dead) return;
        d.row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_add_css_class(d.row, "sketerm-web-dlrow");

        var name_z: [512:0]u8 = undefined;
        d.label = c.gtk_label_new(std.fmt.bufPrintZ(&name_z, "{s}", .{d.name}) catch "download");
        c.gtk_label_set_ellipsize(@ptrCast(d.label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(@ptrCast(d.label), 28);
        c.gtk_label_set_xalign(@ptrCast(d.label), 0);
        c.gtk_box_append(@ptrCast(d.row), d.label);

        d.bar = c.gtk_progress_bar_new();
        c.gtk_widget_set_hexpand(d.bar, 1);
        c.gtk_widget_set_valign(d.bar, c.GTK_ALIGN_CENTER);
        c.gtk_box_append(@ptrCast(d.row), d.bar);

        d.status = c.gtk_label_new("");
        c.gtk_widget_add_css_class(d.status, "dim-label");
        c.gtk_box_append(@ptrCast(d.row), d.status);

        d.open_btn = self.dlButton(d, "document-open-symbolic", "Open", &onDlOpenClicked);
        c.gtk_widget_set_visible(d.open_btn, 0);
        d.reveal_btn = self.dlButton(d, "folder-open-symbolic", "Show in Files", &onDlRevealClicked);
        c.gtk_widget_set_visible(d.reveal_btn, 0);
        d.cancel_btn = self.dlButton(d, "process-stop-symbolic", "Cancel", &onDlCancelClicked);

        c.gtk_box_append(@ptrCast(self.dl_strip), d.row);
        c.gtk_widget_set_visible(self.dl_strip, 1);
        self.updateDlRow(d);
    }

    /// A flat row button whose user-data is a `DlBtnCtx` OWNED BY THE
    /// BUTTON (mechanism 1) — never the face, which the row can
    /// outlive a callback dispatch of.
    fn dlButton(self: *WebFace, d: *Download, icon: [*:0]const u8, tip: [*:0]const u8, cb: *const fn (?*c.GtkButton, ?*anyopaque) callconv(.c) void) *c.GtkWidget {
        const btn = c.gtk_button_new_from_icon_name(icon).?;
        c.gtk_widget_add_css_class(btn, "flat");
        c.gtk_widget_set_tooltip_text(btn, tip);
        if (self.allocator.create(DlBtnCtx) catch null) |ctx| {
            ctx.* = .{ .allocator = self.allocator, .view = self.view, .id = d.id };
            _ = c.g_signal_connect_data(
                @ptrCast(btn),
                "clicked",
                @ptrCast(cb),
                @ptrCast(ctx),
                @ptrCast(cast.destroyCtx(DlBtnCtx)),
                0,
            );
        }
        c.gtk_box_append(@ptrCast(d.row), btn);
        return btn;
    }

    fn updateDlRow(self: *WebFace, d: *Download) void {
        if (self.widgets_dead) return;
        const format = @import("../filebrowser/format.zig");
        var size_buf: [48:0]u8 = undefined;
        var text: [128:0]u8 = undefined;
        switch (d.state) {
            .downloading => {
                if (d.total > 0) {
                    c.gtk_progress_bar_set_fraction(@ptrCast(d.bar), @as(f64, @floatFromInt(d.received)) / @as(f64, @floatFromInt(d.total)));
                } else {
                    c.gtk_progress_bar_pulse(@ptrCast(d.bar));
                }
                const t = std.fmt.bufPrintZ(&text, "{s}", .{format.fmtSize(&size_buf, d.received)}) catch "";
                c.gtk_label_set_text(@ptrCast(d.status), t.ptr);
            },
            .uploading => {
                var host_z: [128:0]u8 = undefined;
                const t = std.fmt.bufPrintZ(&text, "Sending to {s}…", .{
                    std.fmt.bufPrintZ(&host_z, "{s}", .{d.remote_host}) catch "host",
                }) catch "Sending…";
                c.gtk_label_set_text(@ptrCast(d.status), t.ptr);
                if (d.total > 0) c.gtk_progress_bar_set_fraction(@ptrCast(d.bar), @as(f64, @floatFromInt(d.received)) / @as(f64, @floatFromInt(d.total)));
            },
            .done => {
                c.gtk_progress_bar_set_fraction(@ptrCast(d.bar), 1.0);
                const t = if (d.remote_host.len != 0)
                    std.fmt.bufPrintZ(&text, "Sent to {s}", .{d.remote_host}) catch "Sent"
                else
                    std.fmt.bufPrintZ(&text, "Saved — {s}", .{format.fmtSize(&size_buf, d.received)}) catch "Saved";
                c.gtk_label_set_text(@ptrCast(d.status), t.ptr);
                // Open only makes sense for a file on THIS machine.
                c.gtk_widget_set_visible(d.open_btn, if (d.remote_host.len == 0) 1 else 0);
                c.gtk_widget_set_visible(d.reveal_btn, 1);
                c.gtk_button_set_icon_name(@ptrCast(d.cancel_btn), "window-close-symbolic");
                c.gtk_widget_set_tooltip_text(d.cancel_btn, "Dismiss");
            },
            .failed => {
                c.gtk_label_set_text(@ptrCast(d.status), "Failed");
                c.gtk_button_set_icon_name(@ptrCast(d.cancel_btn), "window-close-symbolic");
                c.gtk_widget_set_tooltip_text(d.cancel_btn, "Dismiss");
            },
        }
    }

    fn onDownloadProgress(self: *WebFace, ev: proto.EvDownloadProgress) void {
        const d = self.findDownload(ev.id) orelse return;
        d.received = ev.received;
        if (ev.total > 0) d.total = ev.total;
        if (ev.failed != 0) {
            if (d.canceled) {
                self.removeDownload(d);
                return;
            }
            d.state = .failed;
            self.updateDlRow(d);
            return;
        }
        if (ev.done != 0) {
            if (d.remote_host.len != 0) {
                self.beginHandoff(d);
            } else {
                d.state = .done;
                self.updateDlRow(d);
            }
            return;
        }
        self.updateDlRow(d);
    }

    /// The downloaded staging file becomes a durable daemon transfer to
    /// the picked host — the file browser's own machinery, so a GUI
    /// crash mid-send resumes like any other transfer.
    fn beginHandoff(self: *WebFace, d: *Download) void {
        const win = self.ownerWindow() orelse {
            d.state = .failed;
            self.updateDlRow(d);
            return;
        };
        const svc = win.transferService() orelse {
            d.state = .failed;
            self.updateDlRow(d);
            self.toast("Downloaded locally, but the transfer service is unavailable to send it on.");
            return;
        };
        d.upload_token = svc.submitUpload(self.allocator, d.path, d.remote_host, d.remote_path, null);
        if (d.upload_token == null) {
            d.state = .failed;
            self.updateDlRow(d);
            self.toast("Downloaded locally, but the send to the server could not be recorded.");
            return;
        }
        // Second phase: the bar restarts for the upload leg.
        d.state = .uploading;
        d.received = 0;
        self.updateDlRow(d);
        self.ensureDlTimer();
    }

    fn ensureDlTimer(self: *WebFace) void {
        if (self.dl_timer != 0) return;
        self.dl_timer = c.g_timeout_add(500, @ptrCast(&onDlTick), self);
    }

    fn stopDlTimer(self: *WebFace) void {
        if (self.dl_timer == 0) return;
        _ = c.g_source_remove(self.dl_timer);
        self.dl_timer = 0;
    }

    fn onDlTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(WebFace, user);
        const win = self.ownerWindow();
        const svc = if (win) |w| w.transferService() else null;
        var uploading = false;
        var i: usize = 0;
        while (i < self.downloads.items.len) {
            const d = self.downloads.items[i];
            i += 1;
            if (d.state != .uploading) continue;
            const token = d.upload_token orelse continue;
            const service = svc orelse continue;
            const progress = service.intentProgress(token) orelse {
                // Gone from the ledger = finished and acknowledged.
                self.finishHandoff(d, true);
                continue;
            };
            switch (progress.state) {
                .done => self.finishHandoff(d, true),
                .failed => self.finishHandoff(d, false),
                .canceled => {
                    self.dropStaging(d);
                    self.removeDownload(d);
                    i -|= 1;
                },
                else => {
                    d.received = progress.done;
                    if (progress.total > 0) d.total = progress.total;
                    self.updateDlRow(d);
                    uploading = true;
                },
            }
        }
        if (!uploading) {
            self.dl_timer = 0;
            return 0;
        }
        return 1;
    }

    fn finishHandoff(self: *WebFace, d: *Download, ok: bool) void {
        if (ok) self.dropStaging(d);
        d.state = if (ok) .done else .failed;
        if (ok and d.total > 0) d.received = d.total;
        self.updateDlRow(d);
    }

    /// Unlink the local staging copy of a redirected download.
    fn dropStaging(self: *WebFace, d: *Download) void {
        _ = self;
        if (d.remote_host.len == 0) return;
        var z: [4608:0]u8 = undefined;
        if (d.path.len + 1 > z.len) return;
        @memcpy(z[0..d.path.len], d.path);
        z[d.path.len] = 0;
        _ = c.unlink(&z);
    }

    fn removeDownload(self: *WebFace, d: *Download) void {
        for (self.downloads.items, 0..) |it, idx| {
            if (it != d) continue;
            _ = self.downloads.orderedRemove(idx);
            break;
        }
        if (!self.widgets_dead) {
            c.gtk_box_remove(@ptrCast(self.dl_strip), d.row);
            if (self.downloads.items.len == 0) c.gtk_widget_set_visible(self.dl_strip, 0);
        }
        d.free(self.allocator);
    }

    fn onDlCancelClicked(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(DlBtnCtx, user);
        const self = findFaceGlobal(ctx.view) orelse return;
        const d = self.findDownload(ctx.id) orelse return;
        switch (d.state) {
            .downloading => {
                d.canceled = true;
                self.cl.post(proto.DownloadCancel{ .view = ctx.view, .id = ctx.id });
            },
            .uploading => {
                d.canceled = true;
                if (d.upload_token) |token| {
                    if (self.ownerWindow()) |w| {
                        if (w.transferService()) |svc| svc.cancel(token);
                    }
                }
                // The tick sees the canceled state and removes the row.
                self.ensureDlTimer();
            },
            .done, .failed => self.removeDownload(d),
        }
    }

    fn onDlOpenClicked(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(DlBtnCtx, user);
        const self = findFaceGlobal(ctx.view) orelse return;
        const d = self.findDownload(ctx.id) orelse return;
        if (d.remote_host.len != 0) return;
        var uri: [4700:0]u8 = undefined;
        const u = std.fmt.bufPrintZ(&uri, "file://{s}", .{d.path}) catch return;
        _ = c.g_app_info_launch_default_for_uri(u.ptr, null, null);
    }

    fn onDlRevealClicked(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(DlBtnCtx, user);
        const self = findFaceGlobal(ctx.view) orelse return;
        const d = self.findDownload(ctx.id) orelse return;
        var spec: [4700]u8 = undefined;
        const s = if (d.remote_host.len != 0)
            std.fmt.bufPrint(&spec, "{s}:{s}", .{ d.remote_host, d.remote_path }) catch return
        else
            d.path;
        _ = @import("siblingapp.zig").showInFiles(s);
    }

    /// Fill `buf` with `<dir>/<name>`, appending " (n)" before the
    /// extension while the plain path already exists.
    fn uniquePath(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
        var z: [4608:0]u8 = undefined;
        const dot = blk: {
            const at = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk name.len;
            break :blk if (at == 0) name.len else at;
        };
        var n: u32 = 0;
        while (n < 100) : (n += 1) {
            const candidate = if (n == 0)
                std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch return null
            else
                std.fmt.bufPrint(buf, "{s}/{s} ({d}){s}", .{ dir, name[0..dot], n, name[dot..] }) catch return null;
            if (candidate.len + 1 > z.len) return null;
            @memcpy(z[0..candidate.len], candidate);
            z[candidate.len] = 0;
            if (c.access(&z, c.F_OK) != 0) return candidate;
        }
        return null;
    }

    // ---- widget callbacks ------------------------------------------

    fn onBack(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).navAction(.back);
    }

    fn onForward(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).navAction(.forward);
    }

    fn onReload(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        self.navAction(if (self.loading) .stop else .reload);
    }

    fn onShowShell(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (self.pane) |p| p.setWebVisible(false);
    }

    /// Flip content blocking for this view AND remember it for the
    /// site, so the next visit (in any window) starts that way.
    fn onShield(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        const want = !self.net_enabled;
        self.setNetwork(want);
        if (self.nav_origin) |origin| {
            // A choice that matches the global default clears the
            // override rather than pinning it, so changing the default
            // later still moves this site.
            webstore.siteSetBlock(self.allocator, origin, if (want) null else false);
        }
    }

    /// The crashed / helper-lost overlay's Reload: restart the helper
    /// when it is gone, else just reload the page.
    fn onRetry(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        const cl = self.cl;
        if (cl.state == .unavailable) {
            cl.restart();
            return;
        }
        self.clearStatus();
        if (!self.view_live) {
            self.ensureView();
            return;
        }
        self.navAction(.reload);
    }

    fn onEntryActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        const text = c.gtk_editable_get_text(@ptrCast(self.entry)) orelse return;
        self.navigate(std.mem.span(@as([*:0]const u8, @ptrCast(text))));
        _ = c.gtk_widget_grab_focus(self.view_area);
    }

    fn onFindChanged(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).findStart();
    }

    fn onFindActivate(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).findStep(true);
    }

    fn onFindNextSig(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).findStep(true);
    }

    fn onFindPrevSig(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).findStep(false);
    }

    /// Escape in the entry (GtkSearchEntry's stop-search).
    fn onFindStopSig(_: *c.GtkSearchEntry, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).closeFind();
    }

    fn onFindPrevClicked(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).findStep(false);
    }

    fn onFindNextClicked(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).findStep(true);
    }

    fn onFindCloseClicked(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).closeFind();
    }

    /// A dropped file navigates to its URI; dropped text is treated as
    /// an address (pane.zig's target shape, different verb).
    fn onFileDrop(_: *c.GtkDropTarget, value: [*c]const c.GValue, _: f64, _: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(WebFace, user);
        if (c.g_type_check_value_holds(value, c.gdk_file_list_get_type()) != 0) {
            const flist: ?*c.GdkFileList = @ptrCast(c.g_value_get_boxed(value));
            // get_files is transfer-container: free the list, not the GFiles.
            const files = c.gdk_file_list_get_files(flist);
            defer c.g_slist_free(files);
            if (files == null) return 0;
            // One page per view: the FIRST dropped file is the one opened.
            const gfile: ?*c.GFile = @ptrCast(files.*.data);
            const uri_c = c.g_file_get_uri(gfile);
            if (uri_c == null) return 0;
            defer c.g_free(uri_c);
            self.navigate(std.mem.span(@as([*:0]const u8, @ptrCast(uri_c))));
            return 1;
        }
        if (c.g_type_check_value_holds(value, c.G_TYPE_STRING) != 0) {
            const s = c.g_value_get_string(value);
            if (s == null) return 0;
            self.navigate(std.mem.span(@as([*:0]const u8, @ptrCast(s))));
            return 1;
        }
        return 0;
    }

    /// A blank tab's address bar takes focus the moment it can.
    fn onEntryMap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (self.widgets_dead) return;
        if (self.url != null or self.pending_url != null) return;
        _ = c.gtk_widget_grab_focus(self.entry);
    }

    /// Frame-clock tick: one frame request per refresh, capped.
    ///
    /// SELF-REMOVING, and that is the load-bearing property — see the
    /// header. It leaves whenever there is nothing to pace (page gone
    /// quiet, view off screen, widgets dying), zeroing `tick_id` on the
    /// way out exactly like `terminal_surface.zig`'s tick does.
    fn onTick(_: *c.GtkWidget, frame_clock: *c.GdkFrameClock, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(WebFace, user);
        if (self.widgets_dead or !self.on_screen or !self.view_live or self.pacer.state != .active) {
            self.tick_id = 0;
            return 0; // G_SOURCE_REMOVE
        }
        // Pace against the CURRENT output: dragging the window from the
        // 60Hz panel to the 165Hz one changes this with no config
        // change and no reconnect.
        if (g_stats.enabled()) g_stats.ticks += 1;
        self.pacer.display_fps = refreshFps(frame_clock, self.pacer.display_fps);
        // A changed refresh rate (window dragged across outputs) moves
        // the helper-side cap with it.
        self.syncMaxFps();
        if (self.pacer.dueAt(c.g_get_monotonic_time())) self.requestFrame();
        if (self.pacer.demoteDue()) {
            self.pacer.demote();
            self.tick_id = 0;
            if (paceLogging())
                std.debug.print("webface pace: view {d} active -> idle\n", .{self.view});
            return 0; // G_SOURCE_REMOVE
        }
        return 1; // G_SOURCE_CONTINUE
    }

    /// The idle floor: a few requests a second so a page that starts
    /// moving on its own is noticed. Runs for the face's whole life and
    /// does nothing at all while the tick is pacing.
    fn onIdleTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(WebFace, user);
        if (self.widgets_dead) {
            self.idle_timer = 0;
            return 0; // G_SOURCE_REMOVE
        }
        if (self.pacer.state == .idle) {
            // THE KWIN-CRASH GUARD, checked from outside the tick's own
            // callback so it observes what actually happened: an idle
            // face must hold no frame-clock tick. An explicit branch,
            // not std.debug.assert — this project builds ReleaseFast,
            // where that compiles away.
            if (paceLogging()) {
                std.debug.print("webface pace: view {d} idle, tick_id={d}\n", .{ self.view, self.tick_id });
                if (self.tick_id != 0) @panic("webface: idle with a frame-clock tick still installed");
            }
            self.requestFrame();
            return 1; // G_SOURCE_CONTINUE
        }
        // Active, but the tick has not asked for anything in an idle
        // interval: the frame clock is not running (an occluded or
        // unredirected surface stops it). The tick being the ONLY
        // requester would freeze the page here, so the floor applies in
        // both states — it just never fires while the tick delivers.
        if (c.g_get_monotonic_time() - self.pacer.last_req_us >= pace.Pacer.idleIntervalUs())
            self.requestFrame();
        return 1; // G_SOURCE_CONTINUE
    }

    fn onAreaMap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).setOnScreen(true);
    }

    fn onAreaUnmap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).setOnScreen(false);
    }

    /// A realized widget has a surface whose scale can be asked; every
    /// realize (a reparent unrealizes) re-attaches the watch and
    /// re-reads it. No GL state lives here any more — the textures are
    /// GdkTextures whose lifetime GTK manages across reparents.
    fn onAreaRealize(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        self.attachScaleWatch();
        self.syncScale();
    }

    fn onAreaUnrealize(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        self.detachScaleWatch();
    }

    /// One-time (per geometry) presentation report under
    /// `SKETERM_WEB_STATS=1`: the input area's logical size, the
    /// surface's REAL fractional scale, the frame's logical/physical
    /// sizes and the snap nudge. `frame logical x scale == frame
    /// physical` with a zero fractional device offset is the
    /// zero-resample invariant this path exists for.
    fn noteFrameGeometry(self: *WebFace) void {
        if (!g_stats.enabled() or self.widgets_dead) return;
        const S = struct {
            var last_lw: u16 = 0;
            var last_lh: u16 = 0;
            var last_dx: u16 = 0xffff;
            var last_dy: u16 = 0xffff;
        };
        if (S.last_lw == self.frame_lw and S.last_lh == self.frame_lh and
            S.last_dx == self.snap_dx and S.last_dy == self.snap_dy) return;
        S.last_lw = self.frame_lw;
        S.last_lh = self.frame_lh;
        S.last_dx = self.snap_dx;
        S.last_dy = self.snap_dy;
        var frac: f64 = 0;
        if (c.gtk_widget_get_native(self.view_area)) |native| {
            if (c.gtk_native_get_surface(native)) |surface|
                frac = c.gdk_surface_get_scale(surface);
        }
        std.debug.print(
            "webface present: area {d}x{d} logical, frame {d}x{d} logical / {d}x{d} phys at {d}, surface scale {d:.3}, snap +{d}+{d}\n",
            .{
                c.gtk_widget_get_width(self.view_area),
                c.gtk_widget_get_height(self.view_area),
                self.frame_lw,
                self.frame_lh,
                self.buf_w,
                self.buf_h,
                self.sent_scale,
                frac,
                self.snap_dx,
                self.snap_dy,
            },
        );
    }

    /// Latency-probe readback out of the engine's own buffer; see
    /// `Lat`. Reading the mapping (instead of a presented framebuffer)
    /// excludes GTK's presentation cycle, which adds one frame-clock
    /// period on top of the printed `->pixel` number.
    fn probeMapping(self: *WebFace, m: *MapRef) void {
        if (g_lat.mode == .off or !g_lat.pending) return;
        if (self.buf_w == 0 or self.buf_h == 0) return;
        const scale = @as(u32, self.sent_scale);
        const px: u32 = @min(60 * scale / 1000, @as(u32, self.buf_w) - 1);
        const py: u32 = @as(u32, self.buf_h) / 2;
        const off = @as(usize, py) * self.buf_stride + @as(usize, px) * 4;
        if (off + 4 > m.len) return;
        const b = m.ptr[off];
        const r = m.ptr[off + 2];
        const is_red = r > 150 and b < 100;
        const is_blue = b > 150 and r < 100;
        const matched = if (g_lat.expect_hover) is_red else is_blue;
        if (!matched) return;
        const now = c.g_get_monotonic_time();
        const arr = if (g_lat.arrival_us != 0) g_lat.arrival_us else now;
        const req = if (g_lat.req_us != 0) g_lat.req_us else now;
        std.debug.print(
            "weblat: {s} input->req {d:.1} ms, ->arrival {d:.1} ms, ->pixel {d:.1} ms, {d} frames\n",
            .{
                if (g_lat.expect_hover) "hover" else "clear",
                @as(f64, @floatFromInt(req - g_lat.t_input_us)) / 1000.0,
                @as(f64, @floatFromInt(arr - g_lat.t_input_us)) / 1000.0,
                @as(f64, @floatFromInt(now - g_lat.t_input_us)) / 1000.0,
                g_lat.frames_seen,
            },
        );
        g_lat.pending = false;
    }

    fn onSurfaceScale(_: ?*c.GObject, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).syncScale();
    }

    fn onResize(_: ?*c.GtkDrawingArea, w: c_int, h: c_int, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (self.hints_active) self.cancelHints();
        if (w <= 0 or h <= 0) return;
        const nw: u16 = @intCast(@min(w, std.math.maxInt(u16)));
        const nh: u16 = @intCast(@min(h, std.math.maxInt(u16)));
        const scale = self.currentScale();
        if (nw == self.sent_w and nh == self.sent_h and scale == self.sent_scale and self.view_live) return;
        self.sent_w = nw;
        self.sent_h = nh;
        self.sent_scale = scale;
        if (!self.view_live) {
            self.ensureView();
            return;
        }
        self.cl.post(proto.ViewResize{
            .view = self.view,
            .w = nw,
            .h = nh,
            .scale_x1000 = scale,
        });
        self.promote();
    }

    fn onMotion(ctrl: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        self.sendPointer(.move, x, y, 0, 0, modsOf(@ptrCast(ctrl)));
    }

    fn onPointerLeave(ctrl: *c.GtkEventControllerMotion, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        self.sendPointer(.leave, 0, 0, 0, 0, modsOf(@ptrCast(ctrl)));
    }

    fn onPressed(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        // A real click while labels are up means the user went back to
        // the mouse; the click itself still reaches the page.
        if (self.hints_active) self.cancelHints();
        _ = c.gtk_widget_grab_focus(self.view_area);
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        self.sendPointer(.down, x, y, cefButton(btn), @intCast(@max(1, n_press)), modsOf(@ptrCast(gesture)));
    }

    fn onReleased(gesture: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        const btn = c.gtk_gesture_single_get_current_button(@ptrCast(gesture));
        self.sendPointer(.up, x, y, cefButton(btn), @intCast(@max(1, n_press)), modsOf(@ptrCast(gesture)));
    }

    fn onScroll(ctrl: *c.GtkEventControllerScroll, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(WebFace, user);
        // Scrolling moves every hint rect; stale labels would lie.
        if (self.hints_active) self.cancelHints();
        if (!self.view_live) return 0;
        // Ctrl+wheel is zoom, not scroll — the page never sees it.
        if (modsOf(@ptrCast(ctrl)) & proto.mod_ctrl != 0) {
            if (dy < 0) {
                self.zoomStep(1);
            } else if (dy > 0) {
                self.zoomStep(-1);
            }
            return 1;
        }
        // GTK reports wheel notches (1.0 per click); Chromium's unit is
        // 120 per notch.
        self.cl.post(proto.InputScroll{
            .view = self.view,
            .x = self.last_x,
            .y = self.last_y,
            .dx = @intFromFloat(@round(dx * 120.0)),
            .dy = @intFromFloat(@round(dy * 120.0)),
            .mods = modsOf(@ptrCast(ctrl)),
        });
        self.promote();
        return 1;
    }

    /// Window-level chords win over the page (editor-face template):
    /// a browser that swallows every keystroke also swallows
    /// Ctrl+Shift+W and Alt+1..9, which is how a pane becomes a trap.
    fn onKeyPressed(
        ctrl: *c.GtkEventControllerKey,
        keyval: c.guint,
        keycode: c.guint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        _ = ctrl;
        const self = cast.userData(WebFace, user);
        // Hints mode owns the keyboard outright: labels are picked by
        // typing, and neither the page nor the chord table may see a
        // key until Escape or an activation ends the mode.
        if (self.hints_active) return self.hintsKey(keyval, state);
        if (self.pane) |pane| {
            if (pane.input_ctx) |ictx| {
                if (input.fallbackToPaneBindings(ictx, keyval, state)) |handled| return handled;
            }
        }
        if (self.faceChord(keyval, state)) return 1;
        return self.sendKey(.down, keyval, keycode, state);
    }

    fn onKeyReleased(
        ctrl: *c.GtkEventControllerKey,
        keyval: c.guint,
        keycode: c.guint,
        state: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) void {
        _ = ctrl;
        const self = cast.userData(WebFace, user);
        // The matching key-down was swallowed by hints mode; releasing
        // it into the page would be an unpaired key-up.
        if (self.hints_active) return;
        _ = self.sendKey(.up, keyval, keycode, state);
    }

    fn onFocusEnter(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (!self.view_live) return;
        self.cl.post(proto.InputFocus{ .view = self.view, .focused = 1 });
        self.promote();
    }

    fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (!self.view_live) return;
        self.cl.post(proto.InputFocus{ .view = self.view, .focused = 0 });
    }

    fn sendPointer(self: *WebFace, kind: proto.PointerKind, x: f64, y: f64, button: u8, clicks: u8, mods: u32) void {
        if (!self.view_live) return;
        if (kind != .leave) {
            // Controller coordinates are view-area space; the page is
            // drawn `snap_dx/dy` further in (the pixel-grid nudge), so
            // page space subtracts it.
            self.last_x = @max(0, @as(i32, @intFromFloat(@round(x))) - @as(i32, self.snap_dx));
            self.last_y = @max(0, @as(i32, @intFromFloat(@round(y))) - @as(i32, self.snap_dy));
        }
        self.cl.post(proto.InputPointer{
            .view = self.view,
            .kind = @intFromEnum(kind),
            .x = self.last_x,
            .y = self.last_y,
            .button = button,
            .clicks = clicks,
            .mods = mods,
        });
        // ANY input goes active immediately, so the paint it causes has
        // no pacing latency added to it.
        self.promote();
    }

    fn sendKey(
        self: *WebFace,
        kind: proto.KeyKind,
        keyval: c.guint,
        keycode: c.guint,
        state: c.GdkModifierType,
        ) c.gboolean {
        if (!self.view_live) return 0;
        const mods = modsFromState(state);
        // GDK keyvals ARE XKB keysyms; the helper maps them itself.
        var text_buf: [8]u8 = undefined;
        var text: []const u8 = &.{};
        if (kind == .down and mods & (proto.mod_ctrl | proto.mod_alt) == 0) {
            const cp = c.gdk_keyval_to_unicode(keyval);
            if (cp >= 0x20 and cp != 0x7f) {
                const n = std.unicode.utf8Encode(@intCast(cp), &text_buf) catch 0;
                text = text_buf[0..n];
            }
        }
        self.cl.post(proto.InputKey{
            .view = self.view,
            .kind = @intFromEnum(kind),
            .keyval = keyval,
            .keycode = keycode,
            .mods = mods,
            .text = text,
        });
        self.promote();
        return 1;
    }
};

/// input.zig `web_hints` sink: stateless, resolves the face from the
/// Pane on every call, so nothing dangles when the face detaches.
/// False (pane not showing a web page) lets `hints_open` fall through
/// to the terminal quick-select.
fn webHintsSink(pane_ctx: ?*anyopaque) bool {
    const pane: *Pane = @ptrCast(@alignCast(pane_ctx orelse return false));
    if (!pane.webFaceVisible()) return false;
    const face = WebFace.fromPane(pane) orelse return false;
    return face.startHints();
}

/// The refresh rate of the output this frame clock drives, or `fallback`
/// when GDK does not know one yet (an unmapped or just-realized
/// surface). `gdk_frame_clock_get_refresh_info` reports the interval in
/// microseconds; clamped to a sane band so a nonsense value cannot turn
/// into a request storm.
fn refreshFps(frame_clock: *c.GdkFrameClock, fallback: u16) u16 {
    var interval_us: i64 = 0;
    var presentation_us: i64 = 0;
    c.gdk_frame_clock_get_refresh_info(
        frame_clock,
        c.gdk_frame_clock_get_frame_time(frame_clock),
        &interval_us,
        &presentation_us,
    );
    if (interval_us <= 0) return fallback;
    const fps = @divTrunc(@as(i64, 1_000_000), interval_us);
    return @intCast(std.math.clamp(fps, 1, @as(i64, pace.max_cap_fps)));
}

/// GDK button number (1 left, 2 middle, 3 right) to the protocol's
/// CEF-shaped byte.
fn cefButton(btn: c.guint) u8 {
    return switch (btn) {
        2 => 1,
        3 => 2,
        else => 0,
    };
}

fn modsOf(ctrl: *c.GtkEventController) u32 {
    return modsFromState(c.gtk_event_controller_get_current_event_state(ctrl));
}

fn modsFromState(state: c.GdkModifierType) u32 {
    var mods: u32 = 0;
    const s: c_int = @intCast(state);
    if (s & c.GDK_SHIFT_MASK != 0) mods |= proto.mod_shift;
    if (s & c.GDK_CONTROL_MASK != 0) mods |= proto.mod_ctrl;
    if (s & c.GDK_ALT_MASK != 0) mods |= proto.mod_alt;
    if (s & c.GDK_SUPER_MASK != 0) mods |= proto.mod_super;
    if (s & c.GDK_LOCK_MASK != 0) mods |= proto.mod_capslock;
    return mods;
}

/// What the address bar means: an explicit scheme wins, a token with a
/// dot and no space is a host, anything else is a web search on the
/// configured `web_search_engine` (percent-encoded query).
fn normalizeUrl(buf: []u8, spec: []const u8) ?[]const u8 {
    return suggest.normalizeUrl(buf, spec, searchTemplate());
}

/// Host part of a url for a message that names a site. Falls back to
/// the whole string, which is still better than naming nothing.
fn hostOf(url: []const u8) []const u8 {
    return urlhost.hostOf(url, urlhost.prose);
}

/// What a permission bitmask is called in a sentence. A prompt can
/// carry several bits; the common pairs get a phrase of their own and
/// anything unrecognised is named honestly rather than guessed at.
fn permissionLabel(types: u32) []const u8 {
    if (types == (proto.perm_camera | proto.perm_microphone)) return "your camera and microphone";
    return switch (types) {
        proto.perm_geolocation => "your location",
        proto.perm_notifications => "notifications",
        proto.perm_camera => "your camera",
        proto.perm_microphone => "your microphone",
        proto.perm_midi => "your MIDI devices",
        proto.perm_clipboard => "your clipboard",
        proto.perm_pointer_lock => "pointer lock",
        proto.perm_idle_detection => "idle detection",
        proto.perm_storage_access => "storage across sites",
        proto.perm_window_management => "your window layout",
        proto.perm_protected_media => "protected media playback",
        proto.perm_local_fonts => "your installed fonts",
        proto.perm_file_system => "files on this machine",
        proto.perm_downloads => "multiple downloads",
        proto.perm_sensors => "device sensors",
        proto.perm_vr => "immersive VR/AR",
        else => "a device permission",
    };
}

/// Blocked-popup toast context. It carries a VIEW ID, not a face
/// pointer: the toast can outlive the face, and the immortal client
/// resolves the id to whatever still exists at click time.
const PopupCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    url: []u8,
};

fn onPopupToastOpen(_: *c.AdwToast, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(PopupCtx, user);
    const face = g_client.findFace(ctx.view) orelse return;
    face.openInNewTab(ctx.url);
}

fn freePopupCtx(user: ?*anyopaque, _: ?*c.GClosure) callconv(.c) void {
    const ctx: *PopupCtx = @ptrCast(@alignCast(user orelse return));
    ctx.allocator.free(ctx.url);
    ctx.allocator.destroy(ctx);
}

test "hostOf names the site a message is about" {
    try std.testing.expectEqualStrings("example.com", hostOf("https://example.com/a/b?c=d"));
    try std.testing.expectEqualStrings("example.com", hostOf("https://user@example.com/"));
    try std.testing.expectEqualStrings("example.com:8443", hostOf("https://example.com:8443/x"));
    try std.testing.expectEqualStrings("about:blank", hostOf("about:blank"));
}

test "normalizeUrl keeps explicit schemes and promotes hosts" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com/", normalizeUrl(&buf, "https://example.com/").?);
    try std.testing.expectEqualStrings("data:text/html,x", normalizeUrl(&buf, "data:text/html,x").?);
    try std.testing.expectEqualStrings("https://example.com", normalizeUrl(&buf, "example.com").?);
    try std.testing.expect(std.mem.startsWith(u8, normalizeUrl(&buf, "two words").?, "https://duckduckgo.com/"));
}

test "normalizeUrl percent-encodes searches on the configured engine" {
    var buf: [256]u8 = undefined;
    setSearchEngine("https://www.google.com/search?q={q}");
    defer setSearchEngine("");
    try std.testing.expectEqualStrings(
        "https://www.google.com/search?q=a%26b%20c",
        normalizeUrl(&buf, "a&b c").?,
    );
    // Reset falls back to the default engine.
    setSearchEngine("");
    try std.testing.expectEqualStrings(
        "https://duckduckgo.com/?q=two%20words",
        normalizeUrl(&buf, "two words").?,
    );
}

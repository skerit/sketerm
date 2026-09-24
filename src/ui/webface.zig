//! WebFace — a real browser inside a pane, rendered by the optional
//! `sketerm-webengine` helper (src/web/, and its CLAUDE.md).
//!
//! Two objects are exported here:
//!
//! - `Client` (`webface/client.zig`): ONE helper process per GUI
//!   process, its unix socket watched with `g_unix_fd_add` and never read
//!   blocking. It owns the handshake, view-id allocation and event
//!   routing; faces register in it and are found by view id. The
//!   process-wide registry (`g_client`, aux and observer clients, view-id
//!   counters) stays in this file.
//! - `WebFace`: one PAGE = one view id. Chrome (address entry,
//!   back/forward/reload) plus a `GtkPicture` presenting the view's
//!   frames as `GdkTexture`s in GTK's own scene graph.
//!
//! ## Layout
//!
//! This file keeps `WebFace`'s fields, attach/teardown, frame rate, tab
//! discard, device scale, UI construction, the client callbacks,
//! commands and the widget/input callbacks. Everything else sits in
//! `src/ui/webface/` (a pure move, 2026-09), each section a set of free
//! functions taking `*WebFace` that `WebFace` re-exports by name, so
//! `face.onDownloadOffer(...)` and every outside caller are unchanged:
//!
//! - process-wide: `client.zig`, `containers.zig` (containers, the
//!   browser.tabs table, filter-list config, stored containers),
//!   `cookiesync.zig` (0xE0 cookie sync between route instances);
//! - per face: `frames.zig` (buffer/dma-buf/inline presentation),
//!   `automation.zig` (the `web_*` MCP round trips), `hints.zig`,
//!   `siteinfo.zig`, `a11y.zig`, `observed.zig`, `store.zig` (history,
//!   site settings, bookmarks), `prompts.zig` (TLS interstitial and
//!   permission banner), `pageview.zig` (find bar, reader, zoom),
//!   `menus.zig` (context menu, hamburger), `password.zig`, `print.zig`
//!   (DevTools + print to PDF), `downloads.zig`.
//!
//! A new method goes in the module of its feature; alias it in `WebFace`
//! when anything outside that module calls it. Modules with tests are
//! imported by `src/tests.zig` (GUI root only).
//!
//! A pane holds SEVERAL pages, in a `WebGroup` (src/ui/webgroup.zig) —
//! read its header before changing anything here that touches the pane.
//! Two consequences for this file:
//!
//! - `Pane.faces.web.ctx` is the GROUP, not a face. `fromPane` answers with
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
//! So this face sends NO frame requests and installs NO frame-clock tick
//! at all: a paint arrives, its texture is set, GTK presents it. The
//! only pacing input it owns is the cap: `syncMaxFps` ships
//! `browser_max_fps` clamped to the refresh of the output the view is ON
//! (`gdk_monitor_get_refresh_rate` of the surface's monitor, re-read on
//! realize and when the surface enters another monitor), and the helper
//! applies it via `set_windowless_frame_rate`. That also keeps the old
//! crash guard true by construction: an installed tick keeps GDK's frame
//! clock cycling at monitor refresh even when nothing is drawn, and on
//! Wayland each empty cycle leaks a frame-callback object id per offload
//! subsurface until KWin's id space runs out (see the `tick_id` docblock
//! in `src/ui/terminal_surface.zig`); this face has no tick to leak.
//! The client-driven pacer that used to run here (`pace.zig`, idle
//! requests at 5Hz, a tick while active) was the losing side of that
//! A/B and is gone; `frame_request` stays on the wire only for older
//! clients, and the helper ignores it.
//!
//! A background tab's view widget is unmapped: the face then sends
//! `view_hide`, so an off-screen page paints nothing at all.
//!
//! Set `SKETERM_WEB_STATS=1` for a per-second stderr line with the
//! delivered frame rate, the time spent here, the bytes actually
//! uploaded, the GPU imports, and the frame-clock PRESENTS behind them.
//! MEASURED at 3840x2160 on a 60fps animating page whose spinner damages
//! 64x64: 1787 MiB/s handed to GDK before, 2 MiB/s of damage rects
//! after, and 0 MiB/s once the frame is a dma-buf import.
//!
//! Read the `presents` number first when the browser looks slow: it
//! counts the paint cycles of the frame clocks showing a web face, i.e.
//! the rate the COMPOSITOR is willing to present at, and everything else
//! is capped by it. A window straddling the gap between two monitors
//! gets zero, and GSK's Vulkan renderer on a 4K surface measured roughly
//! a tenth of `ngl`'s rate. Neither is an engine problem and no
//! engine-side change moves either.
//!
//! The helper rewrites the buffer in place, so a rect can be read
//! half-new: the benign tearing the protocol doc already accepts for
//! v1. Nothing outside the face (this file and `webface/frames.zig`)
//! points into the mapping, so unmapping
//! it on replacement is safe — the old `Mapping` refcount existed only
//! because GDK kept memory textures borrowing it alive past the frame
//! that set them.
//!
//! ## Scale (HiDPI)
//!
//! Per the scale contract (`protocol.ViewCreate`): w/h on the
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
//!   (mechanism 3) for every non-widget callback in this file and in
//!   `webface/`; a face
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
const wf_print = @import("webface/print.zig");
const wf_pw = @import("webface/password.zig");
const wf_page = @import("webface/pageview.zig");
const wf_auto = @import("webface/automation.zig");
const wf_site = @import("webface/siteinfo.zig");
const wf_hints = @import("webface/hints.zig");
const wf_a11y = @import("webface/a11y.zig");
const wf_obs = @import("webface/observed.zig");
const wf_frames = @import("webface/frames.zig");
const wf_store = @import("webface/store.zig");
const wf_prompts = @import("webface/prompts.zig");
const wf_menus = @import("webface/menus.zig");
const wf_dl = @import("webface/downloads.zig");
const wf_client = @import("webface/client.zig");
const wf_ctn = @import("webface/containers.zig");
const wf_cksync = @import("webface/cookiesync.zig");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const widgetshot = @import("widgetshot.zig");
const facehost = @import("facehost.zig");
const platform = @import("../util/platform.zig");
const input = @import("input.zig");
const toolbtn = @import("toolbtn.zig");
const cssutil = @import("cssutil.zig");
const proto = @import("../web/protocol.zig");
const download_policy = @import("../web/download.zig");
const quarantine = @import("../web/quarantine.zig");
const reader_model = @import("../web/reader.zig");
const reader_guards = @import("../web/reader_guards.zig");
const webhints = @import("../web/hints.zig");
const findbin = @import("../web/findbin.zig");
const web_model = @import("../web/model.zig");
const clock = @import("../util/clock.zig");
const fsserve = @import("../mux/fsserve.zig");
const classicmenu = @import("browser/classicmenu.zig");
const appmenu = @import("appmenu.zig");
const webhistory = @import("webhistory.zig");
const webuserscripts = @import("webuserscripts.zig");
const socksbridge = @import("../ipc/socksbridge.zig");
const mux_cli = @import("../ipc/mux_cli.zig");
const socks5_client = @import("../mux/socks5_client.zig");
const clipboard = @import("clipboard.zig");
const webreader = @import("webreader.zig");
const fpicker = @import("../filebrowser/picker.zig");
const webstore = @import("webstore.zig");
const websiteinfo = @import("websiteinfo.zig");
const webext = @import("webext.zig");
const webaction = @import("webaction.zig");
const webframe = @import("webframe.zig");
const secrets = @import("secrets.zig");
const suggest = @import("../util/suggest.zig");
const urlhost = @import("../web/urlhost.zig");
const navfault = @import("../web/navfault.zig");
const omnibox = @import("omnibox.zig");
const axtree = @import("../web/axtree.zig");
const webproj = @import("../a11y/webproj.zig");
const a11ydetect = @import("../a11y/detect.zig");
const webremote = @import("webremote.zig");
const webroute = @import("../web/route.zig");
const watchgeom = @import("../web/watchgeom.zig");
const webwatch = @import("webwatch.zig");
const webgroup = @import("webgroup.zig");
const Pane = @import("pane.zig").Pane;
const Window = @import("window.zig").Window;

/// How long the GUI waits for a freshly spawned helper to bind its
/// socket. CEF's startup (zygote + GPU process) dominates this.
pub const CONNECT_INTERVAL_MS: c_uint = 100;
pub const CONNECT_MAX_TRIES: u32 = 150;

pub const MISSING_MSG =
    \\The browser helper (sketerm-webengine) is not installed.
    \\
    \\It is opt-in because it needs a CEF binary distribution:
    \\    zig build fetch-cef
    \\    zig build web
;

pub const LOST_MSG = "The browser helper stopped. Reload to start it again.";
const DEVTOOLS_GONE_MSG =
    "This DevTools view is gone (the browser helper restarted). " ++
    "Open it again from the page you want to inspect.";
const CRASH_MSG = "This page's renderer crashed. Reload to bring it back.";
const OBSERVED_GONE_MSG = "The assistant's browser is gone.";

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
    /// Paint cycles of the frame clocks showing a web face in this
    /// window. What separates "the engine is slow" from "the compositor
    /// is not presenting us": near zero means the compositor throttles
    /// the surface (occluded, on no output, on a monitor that is asleep)
    /// and no engine-side change can move it. That distinction cost an
    /// evening once.
    presents: u32 = 0,
    ns_total: u64 = 0,
    ns_max: u64 = 0,
    bytes: u64 = 0,
    window_start_ns: u64 = 0,

    pub fn enabled(self: *Stats) bool {
        if (!self.checked) {
            self.checked = true;
            self.on = c.getenv("SKETERM_WEB_STATS") != null;
        }
        return self.on;
    }

    pub fn note(self: *Stats, ns: u64, payload: usize) void {
        self.frames += 1;
        self.ns_total += ns;
        if (ns > self.ns_max) self.ns_max = ns;
        self.bytes += payload;
        const now = clock.nowNs();
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
            "webface stats: {d:.1} fps, frame avg {d:.1} us max {d:.1} us, {d:.0} MiB/s, gpu {d} imported / {d} copied, {d} presents\n",
            .{ fps, avg_us, @as(f64, @floatFromInt(self.ns_max)) / 1000.0, mbps, self.gpu_imports, self.gpu_copies, self.presents },
        );
        self.* = .{ .on = true, .checked = true, .window_start_ns = now };
    }
};

pub var g_stats: Stats = .{};

// ---------------------------------------------------------------------
// Hover-latency probe (`SKETERM_WEB_LAT=1` slow / `=fast`)
// ---------------------------------------------------------------------

/// Input-to-pixel latency probe: a timer alternates a synthetic pointer
/// move between a point INSIDE a hover-styled element (expected to turn
/// red) and one outside it (back to blue), and the render callback reads
/// the probed pixel back out of the engine's buffer. The printed delta
/// is input-send to pixel-in-our-mapping; compositor presentation adds
/// one more cycle on top and is NOT included. `slow` (700ms period)
/// starts each probe from a page that has been still for a while — the
/// user's "mouse arrives at a button on a static page" case; `fast`
/// (100ms) keeps it busy.
const Lat = struct {
    mode: enum { off, slow, fast } = .off,
    checked: bool = false,
    /// A probe input was sent and its pixel not yet observed.
    pending: bool = false,
    expect_hover: bool = false,
    t_input_us: i64 = 0,
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
// App-level frame cap
// ---------------------------------------------------------------------

/// `browser_max_fps` from the config; 0 = follow the display. App-level
/// like the other rendering flags, and module-level like the client it
/// paces — every face reads the same number.
var g_max_fps: u16 = 0;

/// Refresh rate assumed before a view's surface can say which output it
/// is on.
const DEFAULT_DISPLAY_FPS: u16 = 60;

/// The `view_max_fps` a face ships: the configured cap (0 = follow the
/// display) clamped to the refresh of the output the view is on, since
/// painting faster than the output presents is pure waste. A configured
/// cap below 5 would make the page feel broken and one above 1000
/// describes no real display, so both are clamped.
fn effectiveMaxFps(cap: u16, display_fps: u16) u16 {
    const display = if (display_fps == 0) DEFAULT_DISPLAY_FPS else display_fps;
    if (cap == 0) return display;
    return @min(std.math.clamp(cap, 5, 1000), display);
}

test "the frame cap follows the display, and a configured cap only ever lowers it" {
    try std.testing.expectEqual(@as(u16, 144), effectiveMaxFps(0, 144));
    try std.testing.expectEqual(@as(u16, 60), effectiveMaxFps(0, 0));
    try std.testing.expectEqual(@as(u16, 30), effectiveMaxFps(30, 144));
    try std.testing.expectEqual(@as(u16, 60), effectiveMaxFps(240, 60));
    try std.testing.expectEqual(@as(u16, 5), effectiveMaxFps(1, 60));
}

/// Push the configured cap (0 = follow the display) into every live
/// face. Called from `applyConfigChange` and at window construction, the
/// same shape as `imhost.setPreference`.
pub fn setMaxFps(fps: u16) void {
    g_max_fps = fps;
    var it = ownFaces();
    while (it.next()) |f| f.syncMaxFps();
}

/// The machine-wide Tor SOCKS5 endpoint and the default route text,
/// both from config (`mux_tor_socks_endpoint`, `web_route`). Stored as
/// bytes so config arenas can be swapped underneath; every route that
/// says `tor` resolves through `torEndpoint` at the moment it is used.
var g_tor_endpoint: [64]u8 = undefined;
var g_tor_endpoint_len: usize = 0;
var g_default_route: [webroute.MAX_HOST + 8]u8 = undefined;
var g_default_route_len: usize = 0;

pub fn setRouteDefaults(route_text: []const u8, tor_endpoint: []const u8) void {
    const n = @min(tor_endpoint.len, g_tor_endpoint.len);
    @memcpy(g_tor_endpoint[0..n], tor_endpoint[0..n]);
    g_tor_endpoint_len = n;
    const m = @min(route_text.len, g_default_route.len);
    @memcpy(g_default_route[0..m], route_text[0..m]);
    g_default_route_len = m;
}

/// SOCKS5 `host:port` a `tor` route dials; the config default when
/// nothing was applied yet.
pub fn torEndpoint() []const u8 {
    if (g_tor_endpoint_len == 0) return socks5_client.DEFAULT_ENDPOINT;
    return g_tor_endpoint[0..g_tor_endpoint_len];
}

/// `web_route`: what a new tab uses when its container has no route of
/// its own. Text that no longer parses (a Tor endpoint that stopped
/// being valid) is direct here rather than nothing: the config loader
/// already refused the unparseable spelling.
pub fn defaultRoute() webroute.Spec {
    return webroute.Spec.parse(g_default_route[0..g_default_route_len], torEndpoint()) orelse .{};
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
    var it = ownFaces();
    while (it.next()) |f| {
        f.stopDiscardTimer();
        if (!f.on_screen) f.armDiscardTimer();
    }
}

/// Discard every face that is not on screen, now — the
/// `web_discard_background` action. Returns how many pages were let go,
/// which is what the toast reports.
pub fn discardBackground() usize {
    var n: usize = 0;
    var it = ownFaces();
    while (it.next()) |f| {
        if (f.on_screen) continue;
        if (f.discardNow()) n += 1;
    }
    return n;
}

/// Whether the connected helper can discard at all, so a UI can say
/// "not supported" instead of quietly doing nothing.
pub fn discardSupported() bool {
    return g_client.has(.discard);
}

/// Every face of this user's OWN tabs in this GUI process: the local
/// helper's and every route instance's, but never an observer's (those
/// pages are an assistant's). Iterate without GTK dispatch in between;
/// faces register and unregister on the main loop.
pub const OwnFaces = struct {
    client: usize = 0,
    face: usize = 0,

    pub fn next(self: *OwnFaces) ?*WebFace {
        while (true) {
            const cl: *Client = if (self.client == 0)
                &g_client
            else if (self.client - 1 < g_aux_clients.items.len)
                g_aux_clients.items[self.client - 1]
            else
                return null;
            if (self.face < cl.faces.items.len) {
                defer self.face += 1;
                return cl.faces.items[self.face];
            }
            self.client += 1;
            self.face = 0;
        }
    }
};

pub fn ownFaces() OwnFaces {
    return .{};
}

/// Resolve a view id to its face on WHICHEVER helper serves it (view ids
/// come from one process-wide mint, so the lookup is unambiguous) — the
/// id-not-pointer indirection popovers and toasts use, so a deferred
/// activation can never touch a face that died in between. A routed or
/// remote tab resolves too; a local-only lookup silently dropped every
/// site-info action on those.
pub fn faceByView(view: u32) ?*WebFace {
    return findFaceGlobal(view);
}

/// Resolve a view on its owning client. Auxiliary UI must use this form:
/// a remote face is not registered on the process-local client.
pub fn faceByViewOn(cl: *Client, view: u32) ?*WebFace {
    return cl.findFace(view);
}

// ---------------------------------------------------------------------
// App-level popup policy
// ---------------------------------------------------------------------

/// What happens to a page's `window.open` / `target=_blank`.
///
/// The helper opens a popup only under the policy the GUI pushed
/// ahead of time (`pushPopupPolicy`) and the GUI re-checks the gesture
/// bit when one is announced, so this is the GUI's decision either
/// way. A popup that opens is presented by `onPagePopup`: a popup
/// WINDOW when the page asked for a popup shape, a tab otherwise, and
/// only such an engine-opened page may close itself.
/// `block_gestureless` is the
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
    // The helper cannot ask at decision time, so every live face
    // restates its own effective policy.
    for (g_client.faces.items) |f| f.pushPopupPolicy();
}

/// `web_download_ask` from the config: true = a save dialog per
/// download, false = auto-accept into ~/Downloads. App-level and
/// module-level for the same reason as the popup policy.
pub var g_download_ask: bool = true;

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

pub var g_site_setting_sink: ?SiteSettingSink = null;

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

pub const Client = wf_client.Client;

/// The one LOCAL helper connection of this GUI process. Module-level
/// and never freed — see the lifetime notes at the top of the file.
pub var g_client: Client = .{};

pub fn client() *Client {
    return &g_client;
}

/// Per-host remote helper clients, minted on first use and — like the
/// local one — NEVER freed: that immortality is the liveness fence for
/// every non-widget callback that carries a Client pointer.
pub var g_aux_clients: std.ArrayList(*Client) = .empty;

/// The client serving `host` ("" = the local one), created on demand.
/// Null only on allocation failure or an over-long host string.
/// The helper instance realizing `spec`, spawning it on first use.
///
/// One instance per route is the whole mechanism: stock CEF gives a
/// profile exactly one proxy, so a tab's route can only be honoured by
/// putting the tab in a process configured for it. Instances are keyed by
/// the FULL spec, so `mux:box` and a remote helper on `box` are correctly
/// different instances.
///
/// An invalid spec returns null rather than an instance. That matters:
/// a `.tor` route with no endpoint would configure NO proxy, and its
/// instance would browse direct while claiming to be Tor.
pub fn clientForRoute(gpa: std.mem.Allocator, spec: webroute.Spec) ?*Client {
    if (spec.isDirect()) return &g_client;
    if (!spec.valid()) return null;
    for (g_aux_clients.items) |cl| {
        if (cl.routeSpec().eql(spec)) return cl;
    }
    const cl = gpa.create(Client) catch return null;
    cl.* = .{};
    // The allocator from birth, not from `ensure`: `setRoute` registers
    // a face on the client BEFORE ensuring it, and `register` appends
    // to `faces` with `self.gpa` -- an undefined vtable was a SIGSEGV
    // on the first routed tab of a process.
    cl.gpa = gpa;
    if (spec.host.len > cl.route_host.len or spec.endpoint.len > cl.route_endpoint.len) {
        gpa.destroy(cl);
        return null;
    }
    cl.route_kind = spec.kind;
    @memcpy(cl.route_host[0..spec.host.len], spec.host);
    cl.route_host_len = spec.host.len;
    @memcpy(cl.route_endpoint[0..spec.endpoint.len], spec.endpoint);
    cl.route_endpoint_len = spec.endpoint.len;
    // `host_len` is what `isRemote` keys on, so only a remote-helper
    // placement sets it; a tor/mux route runs a LOCAL helper whose
    // traffic is proxied.
    if (spec.kind == .remote_browser) {
        if (spec.host.len > cl.host.len) {
            gpa.destroy(cl);
            return null;
        }
        @memcpy(cl.host[0..spec.host.len], spec.host);
        cl.host_len = spec.host.len;
    }
    g_aux_clients.append(gpa, cl) catch {
        gpa.destroy(cl);
        return null;
    };
    return cl;
}

pub fn clientForHost(gpa: std.mem.Allocator, host: []const u8) ?*Client {
    if (host.len == 0) return &g_client;
    return clientForRoute(gpa, .{ .kind = .remote_browser, .host = host });
}

/// The route a NEW tab in `container` takes: the container's own
/// default route when it has one, else `web_route`. A container the
/// registry does not know yet (the stored list has not landed) counts
/// as routeless here; `rehomeContainerFaces` corrects such a face when
/// the list arrives.
pub fn routeForContainer(container: u32) webroute.Spec {
    if (container != 0) {
        if (findContainer(container)) |ctn| {
            const r = ctn.route();
            if (!r.isDirect()) return r;
        }
    }
    return defaultRoute();
}

/// Resolve a view id across every client — for widget callbacks whose
/// context carries only the id (download rows, print dialogs). View ids
/// are minted from ONE process-wide counter (`g_next_view`), so a
/// client-created view resolves unambiguously; only helper-minted
/// devtools ids could ever collide across helpers, and the local client
/// wins that lookup by order.
pub fn findFaceGlobal(view: u32) ?*WebFace {
    if (g_client.findFace(view)) |f| return f;
    for (g_aux_clients.items) |cl| {
        if (cl.findFace(view)) |f| return f;
    }
    for (g_observer_clients.items) |cl| {
        if (cl.findFace(view)) |f| return f;
    }
    return null;
}

/// Observer clients (`webwatch.zig`), kept APART from `g_aux_clients`:
/// every fan-out over the aux list (cookie sync, containers, filter
/// lists, extensions, tabs) would otherwise reach an assistant's
/// helper. Immortal like every client; an idle one is reused by the
/// next watch with the same key.
var g_observer_clients: std.ArrayList(*Client) = .empty;

pub const ObserverSpec = union(enum) {
    /// Helper socket path of a local assistant.
    local: []const u8,
    /// A remote assistant: mux host spec + its web session name.
    remote: struct { host: []const u8, session: []const u8 },
};

/// An idle or fresh observer client for `spec`. Null when the spec
/// does not fit the client's fixed buffers or memory is out.
pub fn observerClient(gpa: std.mem.Allocator, spec: ObserverSpec) ?*Client {
    var key_buf: [384]u8 = undefined;
    const key = switch (spec) {
        .local => |path| std.fmt.bufPrint(&key_buf, "sock:{s}", .{path}) catch return null,
        .remote => |r| std.fmt.bufPrint(&key_buf, "host:{s}|{s}", .{ r.host, r.session }) catch return null,
    };
    for (g_observer_clients.items) |cl| {
        if (cl.watch == null and cl.state == .idle and std.mem.eql(u8, cl.obs_key[0..cl.obs_key_len], key)) return cl;
    }
    const cl = gpa.create(Client) catch return null;
    cl.* = .{ .observer = true };
    @memcpy(cl.obs_key[0..key.len], key);
    cl.obs_key_len = key.len;
    switch (spec) {
        .local => |path| {
            if (path.len > cl.obs_local.len) {
                gpa.destroy(cl);
                return null;
            }
            @memcpy(cl.obs_local[0..path.len], path);
            cl.obs_local_len = path.len;
        },
        .remote => |r| {
            if (r.host.len > cl.host.len or r.session.len > cl.obs_session.len) {
                gpa.destroy(cl);
                return null;
            }
            @memcpy(cl.host[0..r.host.len], r.host);
            cl.host_len = r.host.len;
            cl.route_kind = .remote_browser;
            @memcpy(cl.route_host[0..r.host.len], r.host);
            cl.route_host_len = r.host.len;
            @memcpy(cl.obs_session[0..r.session.len], r.session);
            cl.obs_session_len = r.session.len;
        },
    }
    g_observer_clients.append(gpa, cl) catch {
        gpa.destroy(cl);
        return null;
    };
    return cl;
}

/// A fresh view id from the process-wide mint, for a face that
/// presents somebody else's view (an observed page).
pub fn mintViewId() u32 {
    const id = g_next_view;
    g_next_view += 1;
    return id;
}

/// Process-wide view-id mint (see `findFaceGlobal`).
var g_next_view: u32 = 1;
var g_next_aux_view: u32 = proto.WEBEXT_POPUP_VIEW_BASE;

/// Mint a client-owned auxiliary view id (extension popup). Kept in a
/// disjoint high range from ordinary views and helper-minted inspectors.
pub fn nextAuxView() u32 {
    const id = g_next_aux_view;
    g_next_aux_view +%= 1;
    if (g_next_aux_view < proto.WEBEXT_POPUP_VIEW_BASE)
        g_next_aux_view = proto.WEBEXT_POPUP_VIEW_BASE;
    return id;
}

pub const container_palette = wf_ctn.container_palette;
pub const Container = wf_ctn.Container;
const EPHEMERAL_CONTAINER_BASE = wf_ctn.EPHEMERAL_CONTAINER_BASE;
pub const containers = wf_ctn.containers;
pub const findContainer = wf_ctn.findContainer;
pub const containerColor = wf_ctn.containerColor;
pub const createContainer = wf_ctn.createContainer;
pub const ContainerSpec = wf_ctn.ContainerSpec;
pub const createContainerAt = wf_ctn.createContainerAt;
pub const renameContainer = wf_ctn.renameContainer;
pub const recolorContainer = wf_ctn.recolorContainer;
pub const destroyContainer = wf_ctn.destroyContainer;
pub const createIncognito = wf_ctn.createIncognito;
pub const publishContexts = wf_ctn.publishContexts;
const windowFocused = wf_ctn.windowFocused;
pub const setFilterSubscriptions = wf_ctn.setFilterSubscriptions;
pub const publishFilterSubs = wf_ctn.publishFilterSubs;
pub const tabsChanged = wf_ctn.tabsChanged;
pub const focusWithin = wf_ctn.focusWithin;
pub const hostOfUrl = wf_ctn.hostOfUrl;
pub const containerForUrl = wf_ctn.containerForUrl;
pub const containerForHost = wf_ctn.containerForHost;
pub const setSiteContainer = wf_ctn.setSiteContainer;
pub const loadContainers = wf_ctn.loadContainers;
pub const ContainerCreated = wf_ctn.ContainerCreated;
pub const cancelStoredCreateFor = wf_ctn.cancelStoredCreateFor;
pub const createStoredContainer = wf_ctn.createStoredContainer;
pub const cookieSyncOnReady = wf_cksync.cookieSyncOnReady;
pub const onCookieChange = wf_cksync.onCookieChange;
pub const onCookieDump = wf_cksync.onCookieDump;

// ---------------------------------------------------------------------
// WebFace
// ---------------------------------------------------------------------

pub const AutoKind = wf_auto.AutoKind;
const AutoOp = wf_auto.AutoOp;
pub const AutoMeta = wf_auto.AutoMeta;
pub const AutoResult = wf_auto.AutoResult;

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

const HintItem = wf_hints.HintItem;

/// Hint-label look, installed once via cssutil. Named libadwaita
/// colors keep it legible in both themes.
pub fn webhintCss(widget: *c.GtkWidget) void {
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
pub fn freeToastPath(user: ?*anyopaque) callconv(.c) void {
    const p: [*:0]u8 = @ptrCast(user orelse return);
    std.heap.c_allocator.free(std.mem.span(p));
}

/// Refcounted mmap of a frame memfd (shared shape; see webframe.zig).
const MapRef = webframe.Map;

const DmabufEntry = wf_frames.DmabufEntry;
pub const Download = wf_dl.Download;
const AskedDownload = wf_dl.AskedDownload;
const PermPrompt = wf_prompts.PermPrompt;
const SiteSetting = wf_prompts.SiteSetting;

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
    /// Where the page is scrolled, as the engine last reported it
    /// (`ev_scroll`). Saved with the layout and handed straight back on
    /// restore — the numbers are never interpreted here.
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    /// Scroll to apply once the restored page finishes loading. A
    /// document still growing clamps an early scroll to its current
    /// height and lands short, so this waits for the load to settle.
    pending_scroll: ?struct { x: i32, y: i32 } = null,
    /// Identity context (container) this face's view lives in, 0 = the
    /// shared default. Assigned once at creation and immutable — a
    /// container is a private cookie jar / cache / egress, and the
    /// helper fixes it at `view_create`. Kept across helper restarts so
    /// a rebuilt view lands back in the same container.
    container: u32 = 0,
    /// The route this tab's traffic takes, realized by `cl` (one helper
    /// instance per route). Kind plus copies of the host/endpoint, so
    /// the face holds no slice into a config arena or a container that
    /// may be renamed or removed under it.
    route_kind: webroute.Kind = .direct,
    route_host: [webroute.MAX_HOST]u8 = undefined,
    route_host_len: usize = 0,
    route_endpoint: [64]u8 = undefined,
    route_endpoint_len: usize = 0,
    /// The user (or an MCP caller) chose this tab's route; the
    /// container's default no longer applies to it.
    route_explicit: bool = false,
    /// The ALWAYS-visible route button beside the padlock ("Direct",
    /// "Tor", "via box"), whose click opens the one-click route menu
    /// (`showRouteMenu`). It is never hidden: a route indicator that
    /// appeared only once the route was non-direct was a switch nobody
    /// found, and the padlock alone cannot say where traffic leaves.
    /// `route_icon` / `route_text` are its two children, updated in
    /// place by `updateSiteButton`.
    route_btn: *c.GtkWidget = undefined,
    route_icon: *c.GtkWidget = undefined,
    route_text: *c.GtkWidget = undefined,
    /// True once `view_create` was sent on the CURRENT connection.
    view_live: bool = false,
    /// This face PRESENTS a view somebody else created (the inspector
    /// `devtools_show` minted): it never sends `view_create`, and it
    /// cannot be rebuilt on a fresh helper connection, because the id
    /// it holds means nothing to a helper that just started.
    attached: bool = false,
    /// The ENGINE opened this page (a real `window.open` popup the
    /// helper announced with `ev_page_popup`), so the engine may also
    /// close it: `page_popup_closed` retires the tab or popup window
    /// it lives in. Set only by the popup-presentation attach paths; a
    /// page the user opened never carries it, so a script can never
    /// close the user's tab.
    popup_owned: bool = false,
    /// An OBSERVED page (`webwatch.zig`): `attached`, and additionally
    /// the view's geometry is the ASSISTANT's, so frames are fitted
    /// into the area (`obs_fit`, never a `view_resize`) and pointer
    /// input maps through that fit back into the owner's coordinates.
    observed: bool = false,
    /// The observed view's logical size and DPR, from the helper.
    obs_w: u16 = 0,
    obs_h: u16 = 0,
    obs_scale: u16 = 1000,
    /// Whether this GUI holds control of the observed page (the
    /// helper's answer, not the request).
    obs_control: bool = false,
    obs_fit: watchgeom.Fit = .{ .x = 0, .y = 0, .w = 0, .h = 0, .scale = 1 },
    /// The `webwatch.Watch` this page belongs to; told on deinit.
    watch: ?*anyopaque = null,

    root_box: *c.GtkWidget = undefined,
    /// The navigation bar. An attached view has no address of its own
    /// to steer, so its face hides the whole bar.
    bar: *c.GtkWidget = undefined,
    back_btn: *c.GtkWidget = undefined,
    fwd_btn: *c.GtkWidget = undefined,
    reload_btn: *c.GtkWidget = undefined,
    reader_btn: *c.GtkWidget = undefined,
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
    /// `enter-monitor` on `scale_surface` (the frame cap follows the
    /// output's refresh) and, under `SKETERM_WEB_STATS`, `after-paint`
    /// on its frame clock.
    monitor_handler: c.gulong = 0,
    present_handler: c.gulong = 0,
    /// Last pointer position in view coordinates — scroll events carry
    /// no coordinates of their own.
    last_x: i32 = 0,
    last_y: i32 = 0,

    /// Latency-probe timer (`SKETERM_WEB_LAT`), 0 when absent.
    lat_timer: c.guint = 0,
    /// Whether the view widget is mapped. A background tab is unmapped: it
    /// gets `view_hide` and paints nothing.
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
    /// What the interstitial asks about (verdict `pending`) or last
    /// answered, and the last main-frame failure: `web-list` reports
    /// both, so a remote caller learns WHY a load is held instead of
    /// watching `loading:true` forever. Shared rule: `navfault`.
    cert_rec: ?navfault.CertRec = null,
    load_error_rec: ?navfault.LoadErrRec = null,
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
    /// A timed-out legacy operation's next uncorrelated reply is stale
    /// and must be consumed before the kind is reusable.
    auto_legacy_quarantine: quarantine.LegacyQuarantine(std.enums.values(AutoKind).len) = .{},

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

    last_eval: ?[]u8 = null,
    /// Every ID ever returned by rich reader mode on this helper view.
    /// New reads refresh matching guards and invalidate absent ones;
    /// unrelated snapshots never erase the ID's reader provenance.
    reader_guards: reader_guards.Store = .{},

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
    /// Correlates `clipboard_read` with its `ev_clipboard_text`, so a
    /// reply that lands after the user moved on is discarded.
    clip_seq: u32 = 0,
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
    /// Automation download requests (`web-download`) whose offer has
    /// not arrived yet: the target path travelled with the request, so
    /// the offer is answered without a save dialog. Owned paths.
    dl_asked: std.ArrayList(AskedDownload) = .empty,
    /// Next `web-download` request id for this face.
    dl_next_req: u32 = 1,
    /// 2Hz poll while any download is in its send-to-host phase: the
    /// transfer service has no per-intent callback, and the strip only
    /// needs coarse progress. Mechanism 2, severed at the choke point
    /// like the pacing timers.
    dl_timer: c.guint = 0,
    /// Bookmark star: the id of the bookmark for the CURRENT address,
    /// or 0 when there is none. Refreshed from the store on every
    /// committed navigation, so it reflects what other windows did too.
    bookmark_id: u64 = 0,
    /// The bookmark star lives INSIDE the address entry as its
    /// secondary icon; this fallback button exists only when the theme
    /// chain cannot draw either star icon, so the control is never an
    /// invisible pixel.
    star_btn: ?*c.GtkWidget = null,
    /// This origin's stored popup override; `.inherit` follows the
    /// app-level `web_popup_policy`.
    site_popup: enum { inherit, allow, block } = .inherit,

    /// The padlock button left of the address entry and the popover it
    /// opens (src/ui/websiteinfo.zig). The popover is built on first
    /// use and owned by this face: severed at the prepare-destroy
    /// choke point, freed in `deinit`.
    site_btn: *c.GtkWidget = undefined,
    site_info: ?*websiteinfo.SiteInfo = null,
    /// Extension browser-action buttons for this page and their popup.
    action_box: *c.GtkWidget = undefined,
    actions: ?*webaction.Toolbar = null,
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

    /// Web face born ON `route`: its very first view is created in
    /// that route's helper instance, so `url` is never handed to the
    /// direct instance first (opening direct and then moving would
    /// leak the address over the direct path). What "New Tor Tab" and
    /// `sketerm web --route` use. An invalid spec is refused.
    pub fn attachRouted(allocator: std.mem.Allocator, pane: *Pane, url: ?[]const u8, route: webroute.Spec) !*WebFace {
        if (!route.valid()) return error.InvalidRoute;
        return attachOpts(allocator, pane, .{ .url = url, .route = route });
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

    /// How an engine-opened popup is presented: as an ordinary tab
    /// (`chromeless == 0`, navigable like any tab) or as a popup
    /// WINDOW, whose address bar is read-only because the window has
    /// no other chrome and the page will routinely ask for a password.
    pub const PopupPresentation = enum { tab, window };

    /// `attachView` for a real page POPUP: same adoption, but the
    /// address bar stays, because the user must be able to read the
    /// origin of a page that is about to ask for their password, and
    /// the face is marked engine-owned so `window.close()` retires it.
    pub fn attachPopupView(allocator: std.mem.Allocator, pane: *Pane, view: u32, on: *Client, how: PopupPresentation) !*WebFace {
        return attachOpts(allocator, pane, .{
            .existing_view = view,
            .on_client = on,
            .keep_address_bar = true,
            .popup_owned = true,
            .address_readonly = how == .window,
        });
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
        /// Keep the address bar on an `existing_view` face. Set for a
        /// page popup, whose origin the user MUST be able to read.
        keep_address_bar: bool = false,
        /// The engine opened this page (see `WebFace.popup_owned`).
        popup_owned: bool = false,
        /// The address entry shows the origin but cannot be typed
        /// into: a popup window's only chrome is that bar.
        address_readonly: bool = false,
        /// The existing view is an OBSERVED page of `watch`.
        watch: ?*anyopaque = null,
        /// Route the FIRST view is created on, outranking the
        /// container's default. Marks the route explicit, like
        /// `setRoute` does.
        route: ?webroute.Spec = null,
    };

    /// First page of a watch: the face presenting the assistant's view
    /// `view` (an alias this GUI minted) on a fresh pane. Full chrome:
    /// the user must see where the assistant is and may steer it once
    /// in control.
    pub fn attachObserved(allocator: std.mem.Allocator, pane: *Pane, view: u32, on: *Client, watch: *anyopaque) !*WebFace {
        return attachOpts(allocator, pane, .{
            .existing_view = view,
            .on_client = on,
            .keep_address_bar = true,
            .watch = watch,
        });
    }

    /// A further page of a watch, in the tab's existing group.
    pub fn attachObservedPage(allocator: std.mem.Allocator, g: *webgroup.Group, view: u32, on: *Client, watch: *anyopaque) !*WebFace {
        return attachOpts(allocator, g.pane, .{
            .existing_view = view,
            .on_client = on,
            .as_page = true,
            .keep_address_bar = true,
            .watch = watch,
        });
    }

    /// Add a page to an existing group — the in-pane equivalent of
    /// opening a new tab. `opener` nests it under the page that asked.
    pub fn attachPage(
        allocator: std.mem.Allocator,
        g: *webgroup.Group,
        url: ?[]const u8,
        opener: ?*WebFace,
    ) !*WebFace {
        // A per-site rule outranks the opener's container: following a
        // link to a site assigned elsewhere lands in the assigned
        // identity, not the one the link happened to be clicked in.
        return attachPageIn(allocator, g, url, opener, containerForUrl(url, inheritedContainer(g, opener)));
    }

    /// A new page inherits the container of the page it was opened
    /// from: a link followed inside a container stays in that
    /// container, which is the whole point of one.
    fn inheritedContainer(g: *webgroup.Group, opener: ?*WebFace) u32 {
        if (opener) |op| return op.container;
        const cur = g.active() orelse return 0;
        return cur.container;
    }

    /// Page whose container is GIVEN rather than inherited — the
    /// restore path, which must reproduce what was saved instead of
    /// copying whichever page happens to be active.
    pub fn attachPageIn(
        allocator: std.mem.Allocator,
        g: *webgroup.Group,
        url: ?[]const u8,
        opener: ?*WebFace,
        container: u32,
    ) !*WebFace {
        return attachOpts(allocator, g.pane, .{
            .url = url,
            .as_page = true,
            .opener = opener,
            .container = container,
        });
    }

    /// A page in `g` PRESENTING an existing helper-side view: the
    /// sidebar equivalent of `Window.newWebTabForView`.
    pub fn attachPageExisting(
        allocator: std.mem.Allocator,
        g: *webgroup.Group,
        view: u32,
        opener: *WebFace,
    ) !*WebFace {
        return attachOpts(allocator, g.pane, .{
            .existing_view = view,
            .on_client = opener.cl,
            .as_page = true,
            .opener = opener,
            .keep_address_bar = true,
            .popup_owned = true,
        });
    }

    /// Retire this face COMPLETELY, for a view the ENGINE closed
    /// (`window.close()` from a popup, which is how an OAuth flow
    /// ends): its page in a group, else its whole tab, else its popup
    /// window. Never the hidden shell the tab was built on: a popup
    /// closing itself must not leave a terminal behind.
    ///
    /// Only an engine-opened face (`popup_owned`) is closed; the
    /// helper emits the event only for its own popups and this is the
    /// belt, so a script can never close a tab the user opened. The
    /// helper already freed the view, so nothing is posted back to it.
    pub fn closeSelf(self: *WebFace) void {
        if (!self.popup_owned) return;
        self.view_live = false;
        if (self.group()) |g| {
            if (g.pages.items.len > 1) {
                g.closePage(self, .promote);
                return;
            }
        }
        const win = self.ownerWindow() orelse return;
        const pane = self.pane orelse return;
        win.closePaneUnprompted(pane);
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
        if (opts.url) |u| self.pending_url = allocator.dupe(u8, u) catch null;

        self.buildUi();
        // An inspector has no address of its own, so it hides the bar.
        // A POPUP does: it routinely shows a password field, and a
        // credential prompt whose origin the user cannot see is exactly
        // what the security-surfaces section above exists to prevent.
        if (opts.existing_view != 0 and !opts.keep_address_bar)
            c.gtk_widget_set_visible(self.bar, 0);
        self.popup_owned = opts.popup_owned;
        // Read-only, not hidden: the origin stays visible, and Enter
        // on a non-editable entry never reaches `onEntryActivate`.
        if (opts.address_readonly)
            c.gtk_editable_set_editable(@ptrCast(self.entry), 0);
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
        if (pane.input_ctx) |ictx| {
            ictx.web_hints = webHintsSink;
            // The pane's clipboard bindings (Ctrl+Shift+V, Cmd+V, and
            // the palette / remote-control routes into the same
            // actions) must reach the PAGE, not the live shell still
            // sitting behind this face.
            ictx.face_paste = webPasteSink;
            ictx.face_copy = webCopySink;
        }

        // Suggestion dropdown under the address bar. An attached view
        // hides the whole nav bar, so it gets none; a face without one
        // still navigates exactly as before.
        if (opts.existing_view == 0)
            self.omni = omnibox.Omnibox.create(allocator, self, self.entry) catch null;

        // The tab's route: its container's default, else `web_route`,
        // realized by one helper instance per route. A route the client
        // registry cannot mint (out of memory, an over-long host) falls
        // back to the direct instance and SAYS so.
        const spec = opts.route orelse routeForContainer(opts.container);
        _ = self.storeRoute(spec);
        self.route_explicit = opts.route != null;
        const cl = opts.on_client orelse (clientForRoute(allocator, spec) orelse blk: {
            // A route the user ASKED for must not quietly become
            // direct: the address is dropped so the direct instance
            // never sees it, and the blank tab says why.
            if (opts.route != null) {
                if (self.pending_url) |u| allocator.free(u);
                self.pending_url = null;
                _ = self.storeRoute(.{});
                self.setStatus("This tab's route could not be started, so its address was not loaded. Pick a route from the toolbar's route button.", false);
                break :blk &g_client;
            }
            _ = self.storeRoute(.{});
            self.setStatus("This tab's route could not be started; browsing directly instead.", false);
            break :blk &g_client;
        });
        self.cl = cl;
        cl.ensure(allocator);
        if (opts.existing_view != 0) {
            // The view already exists on the CURRENT connection: adopt
            // it, live, without a create. Its first `view_resize`
            // arrives from the sensor's allocation like any other.
            self.attached = true;
            self.view = opts.existing_view;
            if (opts.watch) |w| {
                self.observed = true;
                self.watch = w;
                // The frame keeps the OWNER's size: fitted, never
                // stretched (see `layoutObserved`).
                c.gtk_picture_set_content_fit(@ptrCast(self.picture), c.GTK_CONTENT_FIT_CONTAIN);
            }
            self.view_live = cl.state == .ready;
            cl.register(self);
            if (cl.state != .ready) self.onAttachedLost();
            return self;
        }
        self.view = g_next_view;
        g_next_view += 1;
        if (self.actions) |a| a.bindView(self.view, self.cl);
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
        if (self.actions) |a| a.sever(self.widgets_dead);
        // Same mechanism (2: sever at the single choke point) for the
        // latency probe and the discard countdown, which carry this face
        // as user-data and are not signals, so the disconnect loop below
        // misses them.
        self.stopLatProbe();
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
        // For an observed page this is the UNSUBSCRIBE: the helper
        // keeps the assistant's view.
        if (self.view_live) cl.post(proto.ViewDestroy{ .view = self.view });
        cl.unregister(self);
        if (self.watch) |w| {
            self.watch = null;
            webwatch.Watch.onFaceGone(@ptrCast(@alignCast(w)), self);
        }
        // Web-store replies resolve through this face: the deinit
        // choke point drops every pending callback (CLAUDE.md rule 2).
        webstore.cancelFor(@ptrCast(self));
        self.axTeardown();
        self.detachScaleWatch();
        self.stopLatProbe();
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
        if (self.actions) |a| {
            a.sever(self.widgets_dead);
            a.destroy();
            self.actions = null;
        }
        self.stopDiscardTimer();
        self.stopDlTimer();
        // The helper cancels this view's engine-side downloads when the
        // ViewDestroy above lands; a handed-off upload is the durable
        // transfer service's and deliberately survives the pane.
        for (self.downloads.items) |d| d.free(self.allocator);
        self.downloads.deinit(self.allocator);
        for (self.dl_asked.items) |a| {
            self.allocator.free(a.path);
            self.allocator.free(a.url);
        }
        self.dl_asked.deinit(self.allocator);
        self.dropMap();
        self.cancelHints();
        self.hints_items.deinit(self.allocator);
        if (self.pending_url) |u| self.allocator.free(u);
        if (self.cert_rec) |*rec| rec.free(self.allocator);
        if (self.load_error_rec) |*rec| rec.free(self.allocator);
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
        self.reader_guards.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub const autoClear = wf_auto.autoClear;
    pub const abandonAutoOps = wf_auto.abandonAutoOps;
    pub const autoBusy = wf_auto.autoBusy;
    pub const autoBegin = wf_auto.autoBegin;
    pub const acceptsOp = wf_auto.acceptsOp;
    pub const completeOp = wf_auto.completeOp;
    pub const autoPending = wf_auto.autoPending;
    pub const autoTake = wf_auto.autoTake;
    pub const autoSnapshot = wf_auto.autoSnapshot;
    pub const autoAct = wf_auto.autoAct;
    pub const autoExpand = wf_auto.autoExpand;
    pub const autoQuery = wf_auto.autoQuery;
    pub const autoRead = wf_auto.autoRead;
    pub const readerGuard = wf_auto.readerGuard;
    pub const invalidateReaderGuards = wf_auto.invalidateReaderGuards;
    pub const onReadIds = wf_auto.onReadIds;
    pub const autoEval = wf_auto.autoEval;
    pub const postSemantic = wf_auto.postSemantic;
    pub const autoNetworkLog = wf_auto.autoNetworkLog;
    pub const setNetwork = wf_auto.setNetwork;
    pub const netCounters = wf_auto.netCounters;
    pub const onInterceptStatus = wf_auto.onInterceptStatus;
    pub const onInterceptLog = wf_auto.onInterceptLog;
    pub const netStoreApply = wf_auto.netStoreApply;
    pub const updateShield = wf_auto.updateShield;
    pub const onSiteInfo = wf_auto.onSiteInfo;
    pub const showSiteInfo = wf_auto.showSiteInfo;
    pub const onRouteButton = wf_auto.onRouteButton;
    pub const showRouteMenu = wf_auto.showRouteMenu;
    pub const appendRouteRows = wf_auto.appendRouteRows;
    pub const onMenuTorTab = wf_auto.onMenuTorTab;
    pub const chooseRoute = wf_auto.chooseRoute;
    pub const routeToast = wf_auto.routeToast;
    pub const refreshSiteInfo = wf_auto.refreshSiteInfo;
    pub const tlsState = wf_auto.tlsState;
    pub const updateSiteButton = wf_auto.updateSiteButton;
    pub const nextSiteReq = wf_auto.nextSiteReq;
    pub const siteDataUsable = wf_auto.siteDataUsable;
    pub const requestCookies = wf_auto.requestCookies;
    pub const deleteCookie = wf_auto.deleteCookie;
    pub const clearCookies = wf_auto.clearCookies;
    pub const clearSiteData = wf_auto.clearSiteData;
    pub const forgetSitePermission = wf_auto.forgetSitePermission;
    pub const storeOrigin = wf_auto.storeOrigin;
    pub const setBlockingForSite = wf_auto.setBlockingForSite;
    pub const onCookies = wf_auto.onCookies;
    pub const onSitedataDone = wf_auto.onSitedataDone;
    pub const autoScroll = wf_auto.autoScroll;
    pub const lastEval = wf_auto.lastEval;
    pub const startHints = wf_auto.startHints;
    pub const onHintsResult = wf_auto.onHintsResult;
    pub const buildHints = wf_auto.buildHints;
    pub const cancelHints = wf_auto.cancelHints;
    pub const hintsKey = wf_auto.hintsKey;
    pub const refilterHints = wf_auto.refilterHints;
    pub const soleVisibleHint = wf_auto.soleVisibleHint;
    pub const activateHint = wf_auto.activateHint;
    /// PNG of the PAGE as the user sees it, for `screenshot_pane` /
    /// `web_screenshot`. The pane's own screenshot path renders the
    /// terminal surface, which on a web pane is the hidden shell
    /// underneath — so the face renders its view widget instead,
    /// with the same widget-paintable technique.
    pub fn screenshotPng(self: *WebFace) ?*c.GBytes {
        if (self.widgets_dead) return null;
        return widgetshot.widgetToPng(self.overlay);
    }

    /// Every `sem_snapshot` frame answers a request now: the helper
    /// coalesces spontaneous mutations into its shadow tree and pushes
    /// nothing for them (semantic.View.consume), so the old client-side
    /// delta-buffering is gone. `completeOp`'s want_full guard still
    /// drops a stray delta from a pre-coalescing helper.
    pub fn onSnapshot(self: *WebFace, ev: proto.SemSnapshot, request: u32) void {
        if (!self.acceptsOp(.snapshot, request)) return;
        const meta: AutoMeta = .{ .doc_gen = ev.doc_gen, .rev = ev.rev, .snap_kind = ev.kind };
        self.completeOp(.snapshot, request, true, ev.payload.s, meta);
    }

    pub fn onEvalResult(self: *WebFace, ev: proto.SemEvalResult, request: u32) void {
        if (!self.acceptsOp(.eval, request)) return;
        if (self.allocator.dupe(u8, ev.json.s)) |owned| {
            if (self.last_eval) |old| self.allocator.free(old);
            self.last_eval = owned;
        } else |_| {}
        self.completeOp(.eval, request, ev.ok != 0, ev.json.s, .{});
    }

    pub const dropMap = wf_frames.dropMap;
    pub const clearDmabufCache = wf_frames.clearDmabufCache;
    // ---- frame rate --------------------------------------------------

    /// Ship the frame-rate cap the helper's scheduler applies
    /// (`set_windowless_frame_rate`): `browser_max_fps` clamped to the
    /// refresh of the output the view is on. Only changes are sent.
    fn syncMaxFps(self: *WebFace) void {
        if (!self.view_live) return;
        const want = effectiveMaxFps(g_max_fps, self.displayFps());
        if (want == self.sent_max_fps) return;
        self.sent_max_fps = want;
        self.cl.post(proto.ViewMaxFps{ .view = self.view, .fps = want });
    }

    /// Refresh rate, in Hz, of the output the view's surface is on; the
    /// default before the widget has a surface to ask about.
    fn displayFps(self: *WebFace) u16 {
        if (self.widgets_dead) return DEFAULT_DISPLAY_FPS;
        const native = c.gtk_widget_get_native(self.view_area) orelse return DEFAULT_DISPLAY_FPS;
        const surface = c.gtk_native_get_surface(native) orelse return DEFAULT_DISPLAY_FPS;
        const monitor = c.gdk_display_get_monitor_at_surface(c.gdk_surface_get_display(surface), surface) orelse
            return DEFAULT_DISPLAY_FPS;
        const mhz = c.gdk_monitor_get_refresh_rate(monitor);
        if (mhz <= 0) return DEFAULT_DISPLAY_FPS;
        return @intCast(std.math.clamp(@divTrunc(mhz + 500, 1000), 1, 1000));
    }

    fn stopLatProbe(self: *WebFace) void {
        if (self.lat_timer == 0) return;
        _ = c.g_source_remove(self.lat_timer);
        self.lat_timer = 0;
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
                "weblat: {s} UNANSWERED after probe period ({d} frames)\n",
                .{ if (g_lat.expect_hover) "hover" else "clear", g_lat.frames_seen },
            );
        }
        g_lat.expect_hover = !g_lat.expect_hover;
        const x: f64 = if (g_lat.expect_hover) 60 else @floatFromInt(self.sent_w - 20);
        const y: f64 = @floatFromInt(self.sent_h / 2);
        g_lat.pending = true;
        g_lat.frames_seen = 0;
        g_lat.arrival_us = 0;
        g_lat.t_input_us = c.g_get_monotonic_time();
        self.sendPointer(.move, x, y, 0, 0, 0);
        return 1;
    }

    /// A paint landed: the latency probe's arrival clock.
    pub fn notePaint(self: *WebFace) void {
        _ = self;
        if (g_lat.mode != .off and g_lat.pending) {
            g_lat.frames_seen += 1;
            if (g_lat.arrival_us == 0) g_lat.arrival_us = c.g_get_monotonic_time();
        }
    }

    /// The page went on or off screen (tab switch, pane teardown). An
    /// off-screen page is not painted at all (`view_hide`), and after
    /// `web_discard_minutes` of that, the page is let go entirely.
    fn setOnScreen(self: *WebFace, on: bool) void {
        if (self.on_screen == on) return;
        self.on_screen = on;
        tabsChanged(); // MV2 onActivated
        if (on) {
            self.stopDiscardTimer();
            // `view_show` IS the revive frame, so the order below is
            // "clear our own discarded state, then show": the helper
            // recreates the browser and the buffer it announces lands
            // on a face that is no longer dimmed.
            self.noteRevived();
            if (self.view_live) self.cl.post(proto.ViewShow{ .view = self.view });
            self.startLatProbe();
            return;
        }
        if (self.view_live) self.cl.post(proto.ViewHide{ .view = self.view });
        self.cancelHints();
        self.stopLatProbe();
        self.armDiscardTimer();
    }

    // ---- tab discard --------------------------------------------------

    /// Start the off-screen countdown, if discarding is possible and
    /// configured. Idempotent; a face that is already discarded, has no
    /// view, or sits on a helper without the capability arms nothing.
    fn armDiscardTimer(self: *WebFace) void {
        if (self.discard_timer != 0 or self.discarded or self.observed) return;
        if (g_discard_minutes == 0 or self.on_screen) return;
        if (!self.view_live or !self.cl.has(.discard)) return;
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
        if (!cl.has(.discard)) return false;
        self.stopDiscardTimer();
        cl.post(proto.ViewDiscard{ .view = self.view });
        self.discarded = true;
        self.abandonAutoOps(false);
        self.invalidateReaderGuards();
        self.stopLatProbe();
        self.dropMap();
        // A fresh helper-side view knows no cap; the revival re-sends.
        self.sent_max_fps = 0xffff;
        if (!self.widgets_dead) c.gtk_widget_add_css_class(self.picture, DISCARDED_CLASS);
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
    }

    /// Bring a discarded page back on purpose, with `view_show` as the
    /// waking frame. For a NAVIGATION use `noteRevived` instead: the
    /// navigate frame is itself a revive, and showing first would load
    /// the old address as an extra document.
    pub fn reviveNow(self: *WebFace) void {
        if (!self.discarded) return;
        self.noteRevived();
        if (self.view_live) self.cl.post(proto.ViewShow{ .view = self.view });
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
        // A window dragged onto an output with another refresh rate
        // moves the helper-side frame cap with it.
        self.monitor_handler = c.g_signal_connect_data(
            @ptrCast(surface),
            "enter-monitor",
            @ptrCast(&onSurfaceMonitor),
            self,
            null,
            0,
        );
        // Stats only: count the surface's presents (see `Stats`). A
        // signal on the frame clock, never a tick, so an idle surface's
        // clock is left alone.
        if (g_stats.enabled()) {
            if (c.gdk_surface_get_frame_clock(surface)) |clock_obj| {
                self.present_handler = c.g_signal_connect_data(
                    @ptrCast(clock_obj),
                    "after-paint",
                    @ptrCast(&onAfterPaint),
                    self,
                    null,
                    0,
                );
            }
        }
    }

    /// Disconnects everything `attachScaleWatch` connected. The frame
    /// clock belongs to the surface, which this face holds a reference
    /// to until the end of this call.
    fn detachScaleWatch(self: *WebFace) void {
        const surface = self.scale_surface orelse return;
        if (self.scale_handler != 0) {
            c.g_signal_handler_disconnect(@ptrCast(surface), self.scale_handler);
            self.scale_handler = 0;
        }
        if (self.monitor_handler != 0) {
            c.g_signal_handler_disconnect(@ptrCast(surface), self.monitor_handler);
            self.monitor_handler = 0;
        }
        if (self.present_handler != 0) {
            if (c.gdk_surface_get_frame_clock(surface)) |clock_obj|
                c.g_signal_handler_disconnect(@ptrCast(clock_obj), self.present_handler);
            self.present_handler = 0;
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
        // Where this tab's traffic leaves, as a button that is ALWAYS
        // there (`updateSiteButton` keeps its text current). Icon plus
        // text, like the shield: the word is what makes "Direct" and
        // "Tor" readable at a glance, and the click is the one-click
        // route menu.
        self.route_btn = c.gtk_button_new().?;
        const route_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        self.route_icon = c.gtk_image_new_from_icon_name(webroute.Choice.direct.icon()).?;
        c.gtk_box_append(@ptrCast(route_row), self.route_icon);
        self.route_text = c.gtk_label_new("Direct").?;
        c.gtk_box_append(@ptrCast(route_row), self.route_text);
        c.gtk_button_set_child(@ptrCast(self.route_btn), route_row);
        c.gtk_widget_set_tooltip_text(self.route_btn, "Route: where this tab's traffic leaves. Click to change it.");
        c.gtk_widget_add_css_class(self.route_btn, "sketerm-web-route");
        toolbtn.flatten(self.route_btn);
        _ = c.g_signal_connect_data(@ptrCast(self.route_btn), "clicked", @ptrCast(&onRouteButton), self, null, 0);
        self.track(self.route_btn);
        c.gtk_box_append(@ptrCast(bar), self.route_btn);

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

        // Bookmark star, INSIDE the address entry as its secondary icon
        // (the place every browser keeps it). Not a toggle: its pressed
        // look would have to be driven from an async store reply, and a
        // toggle that flips itself back a moment later reads as a bug.
        // The ICON carries the state. A theme chain that cannot draw
        // either star gets a labelled bar button instead, never an
        // invisible entry icon.
        if (toolbtn.iconAvailable("sketerm-starred-symbolic") and toolbtn.iconAvailable("sketerm-non-starred-symbolic")) {
            c.gtk_entry_set_icon_activatable(@ptrCast(self.entry), c.GTK_ENTRY_ICON_SECONDARY, 1);
            _ = c.g_signal_connect_data(@ptrCast(self.entry), "icon-press", @ptrCast(&onEntryIconPress), self, null, 0);
        } else {
            self.star_btn = toolbtn.barButton(bar, "sketerm-non-starred-symbolic", "Bookmark", "Bookmark this page", &onStar, self);
            self.track(self.star_btn.?);
        }

        self.action_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?;
        c.gtk_widget_set_visible(self.action_box, 0);
        c.gtk_box_append(@ptrCast(bar), self.action_box);
        self.actions = webaction.Toolbar.create(self.allocator, self.action_box);

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

        // The way back to the pane's shell is a menu row plus the
        // `toggle_web_face` chord, not a toolbar button: it is a
        // once-per-session action and the toolbar is for the page.

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
        if (webframe.wireInput(InputSink, self.view_area, self)) |ctrls| {
            self.track(ctrls.motion);
            self.track(ctrls.click);
            self.track(ctrls.scroll);
            self.track(ctrls.key);
            self.track(ctrls.focus);
        }

        // File drag & drop -> navigate to the file's URI (a dropped
        // text is treated as an address). Mirrors pane.zig's target.
        const drop = c.gtk_drop_target_new(c.G_TYPE_INVALID, @intCast(c.GDK_ACTION_COPY));
        var drop_types = [_]c.GType{ c.gdk_file_list_get_type(), c.G_TYPE_STRING };
        c.gtk_drop_target_set_gtypes(drop, &drop_types, drop_types.len);
        _ = c.g_signal_connect_data(@ptrCast(drop), "drop", @ptrCast(&onFileDrop), self, null, 0);
        c.gtk_widget_add_controller(self.view_area, @ptrCast(drop));
        self.track(drop);
    }

    pub const ensureA11y = wf_a11y.ensureA11y;
    pub const axTeardown = wf_a11y.axTeardown;
    pub const onAxTree = wf_a11y.onAxTree;
    pub const onAxLoc = wf_a11y.onAxLoc;
    pub const onAxCaret = wf_a11y.onAxCaret;
    pub const onAxEvent = wf_a11y.onAxEvent;
    pub fn setStatus(self: *WebFace, text: []const u8, retryable: bool) void {
        if (self.widgets_dead) return;
        var buf: [512]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch "";
        c.gtk_label_set_text(@ptrCast(self.status_label), z.ptr);
        c.gtk_widget_set_visible(self.status_box, 1);
        // The Reload button is the second child of the status box.
        if (c.gtk_widget_get_last_child(self.status_box)) |btn|
            c.gtk_widget_set_visible(btn, if (retryable) @as(c_int, 1) else 0);
    }

    pub fn clearStatus(self: *WebFace) void {
        if (self.widgets_dead) return;
        c.gtk_widget_set_visible(self.status_box, 0);
    }

    // ---- client callbacks ------------------------------------------

    /// A helper connection came up (first start, or after a Reload).
    /// This tab's route, rebuilt from the face's own copies.
    /// Whether this page leaves no trace in the daemon's web store: a page
    /// in an EPHEMERAL container (an incognito tab, "private, throwaway"),
    /// or a page this GUI only observes (a watched assistant's browsing is
    /// not this user's). Such a page records no history, persists no
    /// per-site override it makes (zoom, popups, blocking, permission
    /// answers apply to it alone), and is offered only to other private
    /// pages' address bars. An explicit bookmark is still the user's.
    /// A container the registry no longer knows is judged by its id range,
    /// so a destroyed incognito container can never read as persistent.
    pub fn isPrivate(self: *const WebFace) bool {
        if (self.observed) return true;
        if (self.container == 0) return false;
        if (findContainer(self.container)) |ctn| return ctn.ephemeral;
        return self.container >= EPHEMERAL_CONTAINER_BASE;
    }

    pub fn routeSpec(self: *const WebFace) webroute.Spec {
        return .{
            .kind = self.route_kind,
            .host = self.route_host[0..self.route_host_len],
            .endpoint = self.route_endpoint[0..self.route_endpoint_len],
        };
    }

    /// Copy `spec` into the face. False when a field does not fit,
    /// leaving the old route in place.
    pub fn storeRoute(self: *WebFace, spec: webroute.Spec) bool {
        if (spec.host.len > self.route_host.len or spec.endpoint.len > self.route_endpoint.len) return false;
        self.route_kind = spec.kind;
        @memcpy(self.route_host[0..spec.host.len], spec.host);
        self.route_host_len = spec.host.len;
        @memcpy(self.route_endpoint[0..spec.endpoint.len], spec.endpoint);
        self.route_endpoint_len = spec.endpoint.len;
        return true;
    }

    pub const RouteError = error{ InvalidRoute, AttachedView, RouteUnavailable };

    /// Move this tab onto `spec`'s helper instance: the current page is
    /// reloaded there, the old view is destroyed, and everything the
    /// tab is besides its traffic (container identity through cookie
    /// sync, bookmarks, history, the pane) stays. The route then sticks
    /// to the tab for its lifetime, across navigations and helper
    /// restarts. An inspector view cannot move (it presents somebody
    /// else's view); an invalid spec is refused rather than downgraded.
    pub fn setRoute(self: *WebFace, spec: webroute.Spec) RouteError!void {
        if (!spec.valid()) return error.InvalidRoute;
        if (self.attached) return error.AttachedView;
        const want = clientForRoute(self.allocator, spec) orelse return error.RouteUnavailable;
        const same_client = want == self.cl;
        if (!self.storeRoute(spec)) return error.InvalidRoute;
        self.route_explicit = true;
        self.updateSiteButton();
        // The tab strip wears the route badge (`applyTabTitle`), so a
        // moved tab is renamed even when its page title does not change.
        self.applyTabTitle();
        if (same_client) return;
        // Leave the old instance: the view there is torn down like a
        // closed tab, and the new instance mints a fresh id so nothing
        // in flight on the old socket can be mistaken for the new view.
        const old = self.cl;
        if (self.view_live) old.post(proto.ViewDestroy{ .view = self.view });
        self.cancelHints();
        self.abandonAutoOps(true);
        self.reader_guards.resetEpoch();
        self.exitReader();
        self.clearPermPrompts();
        self.dropMap();
        if (self.actions) |a| a.helperGone();
        old.unregister(self);
        self.view_live = false;
        self.view = g_next_view;
        g_next_view += 1;
        self.sent_w = 0;
        self.sent_h = 0;
        // The page moves with the tab: it is PENDING on the new view
        // until that view commits it, so the new view's blank first
        // document cannot replace it (`setUrl`) and a second move before
        // the commit still carries it.
        if (self.pending_url == null) {
            if (self.url) |u| {
                if (u.len != 0 and !std.mem.eql(u8, u, "about:blank"))
                    self.pending_url = self.allocator.dupe(u8, u) catch null;
            }
        }
        self.cl = want;
        if (self.actions) |a| a.bindView(self.view, self.cl);
        want.register(self);
        want.ensure(self.allocator);
        switch (want.state) {
            .ready => self.onClientReady(),
            .unavailable => self.onHelperUnavailable(want.reason, want.reason_retryable),
            else => self.setStatus("Starting the browser helper for this route...", false),
        }
    }

    pub fn onClientReady(self: *WebFace) void {
        // Nothing in flight can be answered by a helper that just came
        // up: drop the requests so their kinds are usable again.
        self.cancelHints();
        self.abandonAutoOps(true);
        self.reader_guards.resetEpoch();
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
        if (self.actions) |a| a.helperGone();
        self.sent_w = 0;
        self.sent_h = 0;
        // An attached view belonged to the OLD helper process; its id
        // means nothing to this one and there is nothing to re-create,
        // since only the source page can ask for an inspector.
        if (self.attached) {
            self.onAttachedLost();
            return;
        }
        self.ensureView();
    }

    pub fn onHelperUnavailable(self: *WebFace, reason: []const u8, retryable: bool) void {
        for (self.downloads.items) |d| {
            // Engine ids can be reused after restart; keep completed rows
            // from capturing a new download's progress.
            d.id = 0;
            if (d.state == .downloading) {
                d.retry_req = 0;
                self.failDownload(d, "The browser connection was lost. Reload the page, then retry the download.");
            }
        }
        self.cancelHints();
        self.abandonAutoOps(true);
        self.reader_guards.resetEpoch();
        self.cert_pending = false;
        self.cert_cancelled = false;
        if (!self.widgets_dead) c.gtk_widget_set_visible(self.cert_box, 0);
        self.clearPermPrompts();
        self.view_live = false;
        self.stopDiscardTimer();
        self.noteRevived();
        self.devtools_pending = false;
        self.dropMap();
        if (self.actions) |a| a.helperGone();
        if (self.attached) {
            self.onAttachedLost();
            return;
        }
        self.setStatus(reason, retryable);
    }

    /// The helper behind an attached view is gone: say which kind.
    fn onAttachedLost(self: *WebFace) void {
        if (self.observed) {
            self.setStatus(OBSERVED_GONE_MSG, false);
            return;
        }
        self.onDevToolsLost();
    }

    pub const seedObserved = wf_obs.seedObserved;
    pub const onObserved = wf_obs.onObserved;
    pub const observeRefused = wf_obs.observeRefused;
    pub const postObserveControl = wf_obs.postObserveControl;
    pub const layoutObserved = wf_obs.layoutObserved;
    /// The helper this attached view lived in is gone. Say so, and
    /// offer no Reload: only the page being inspected can open a new
    /// inspector, and this pane no longer knows which page that was.
    fn onDevToolsLost(self: *WebFace) void {
        self.setStatus(DEVTOOLS_GONE_MSG, false);
    }

    pub fn ensureView(self: *WebFace) void {
        const cl = self.cl;
        // An attached view is created by whoever asked for it (the
        // inspector's source page), never here.
        if (self.attached) return;
        if (cl.state != .ready or self.view_live) return;
        // A container's request context must reach the helper BEFORE a
        // view names it: an unknown context id resolves to the shared
        // default jar rather than failing, so the page would load in the
        // wrong identity silently. The stored registry arrives
        // asynchronously, so a container-bound face waits for it and
        // `markContainersReady` kicks every waiter.
        if (self.container != 0) {
            if (!wf_ctn.g_containers_loaded) return;
            if (findContainer(self.container) == null) {
                self.setStatus("Browser view creation failed: the requested container is unavailable.", false);
                return;
            }
            // Only a helper that REFUSES an unknown context keeps the
            // container's identity apart; an older one resolves a failed
            // context through the shared jar and never says so. That is
            // known from the `hello_ack` alone, whose handler kicks every
            // waiter.
            if (!cl.hello_done) return;
            if (!cl.has(.contexts_fail_closed)) {
                self.setStatus("This browser helper is too old to keep containers apart (no contexts-fail-closed capability). Update it, or open the page outside the container.", false);
                return;
            }
        }
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
        // And it knows no popup policy. It must, BEFORE the first page
        // can call window.open: the decision is synchronous helper-side.
        self.pushPopupPolicy();
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

    pub const noteBufferGeometry = wf_frames.noteBufferGeometry;
    pub const allocationSize = wf_frames.allocationSize;
    pub const adoptBuffer = wf_frames.adoptBuffer;
    pub const presentTexture = wf_frames.presentTexture;
    pub const snapAlignment = wf_frames.snapAlignment;
    pub const onDmabuf = wf_frames.onDmabuf;
    pub const importDmabuf = wf_frames.importDmabuf;
    pub const onInline = wf_frames.onInline;
    pub const onDamage = wf_frames.onDamage;
    pub fn onTitle(self: *WebFace, title: []const u8) void {
        if (self.title) |t| self.allocator.free(t);
        self.title = self.allocator.dupe(u8, title) catch null;
        tabsChanged(); // MV2 onUpdated
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
    pub fn isActivePage(self: *WebFace) bool {
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
        // A routed tab is badged (`[Tor] Example`) so the strip and the
        // tree sidebar say where its traffic leaves without the pane
        // being looked at.
        var bbuf: [512]u8 = undefined;
        const title = self.routeSpec().badgedTitle(&bbuf, webgroup.Group.pageTitle(self));
        @import("termsinks.zig").setTabPageTitleFromUtf8(self.allocator, page, title);
    }

    pub fn onNavState(self: *WebFace, ev: proto.EvNavState) void {
        if (self.widgets_dead) return;
        c.gtk_widget_set_sensitive(self.back_btn, if (ev.can_back != 0) @as(c_int, 1) else 0);
        c.gtk_widget_set_sensitive(self.fwd_btn, if (ev.can_fwd != 0) @as(c_int, 1) else 0);
        if (self.loading != (ev.loading != 0)) tabsChanged(); // MV2 onUpdated (status)
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

    pub fn setUrl(self: *WebFace, url: []const u8) void {
        // The blank document a fresh view holds until the navigation it
        // was created for commits is not the tab's page. Adopting it
        // dropped `pending_url`, so a route move (or any view re-mint)
        // in that window navigated the new view to about:blank.
        if (isPreNavigationBlank(url, self.pending_url)) return;
        // A new document settles the pending navigation, and so does the
        // pending page itself arriving, even when it is the page a moved
        // tab already showed (`setRoute`).
        const unchanged = if (self.url) |u| std.mem.eql(u8, u, url) else false;
        if (self.pending_url) |p| {
            if (!unchanged or std.mem.eql(u8, p, url)) {
                self.allocator.free(p);
                self.pending_url = null;
            }
        }
        if (self.url) |u| {
            if (std.mem.eql(u8, u, url)) return;
            self.allocator.free(u);
        }
        self.url = self.allocator.dupe(u8, url) catch null;
        tabsChanged(); // MV2 onUpdated
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
        if (!focusWithin(self.entry))
            c.gtk_editable_set_text(@ptrCast(self.entry), z.ptr);
    }

    pub const noteNavigation = wf_store.noteNavigation;
    pub const isPreNavigationBlank = wf_store.isPreNavigationBlank;
    pub const preloadPermission = wf_store.preloadPermission;
    pub const answerRememberedPrompts = wf_store.answerRememberedPrompts;
    pub const refreshBookmarkState = wf_store.refreshBookmarkState;
    pub const updateStar = wf_store.updateStar;
    pub const onEntryIconPress = wf_store.onEntryIconPress;
    pub const onStar = wf_store.onStar;
    pub const toggleBookmark = wf_store.toggleBookmark;
    pub fn onLoad(self: *WebFace, ev: proto.EvLoad) void {
        // A document changing state is about to paint.
        if (ev.state == @intFromEnum(proto.LoadState.started)) {
            navfault.loadStarted(self.allocator, &self.cert_rec, &self.load_error_rec, ev.url);
            self.cancelHints();
            self.invalidateReaderGuards();
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
            // A restored page is put back where it was only once the
            // load has settled: scrolling a document that is still
            // growing clamps to its current height and lands short.
            if (self.pending_scroll) |want| {
                self.pending_scroll = null;
                if (self.view_live and self.cl.has(.scroll))
                    self.cl.post(proto.ScrollTo{ .view = self.view, .x = want.x, .y = want.y });
            }
        }
    }

    /// Re-apply a persisted scroll on restore. Held until the page
    /// finishes loading (see `onLoad`).
    pub fn applyRestoredScroll(self: *WebFace, x: i32, y: i32) void {
        if (x == 0 and y == 0) return;
        self.pending_scroll = .{ .x = x, .y = y };
    }

    pub fn onLoadError(self: *WebFace, ev: proto.EvLoadError) void {
        if (self.load_error_rec) |*old| old.free(self.allocator);
        self.load_error_rec = navfault.LoadErrRec.init(self.allocator, ev) catch null;
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

    pub fn onViewCreateFailed(self: *WebFace, ev: proto.EvViewCreateFailed) void {
        self.view_live = false;
        self.stopDiscardTimer();
        self.dropMap();
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Browser view creation failed: {s}.", .{ev.reason}) catch
            "Browser view creation failed.";
        self.setStatus(msg, true);
    }

    pub const onCertError = wf_prompts.onCertError;
    pub const certDecide = wf_prompts.certDecide;
    pub const onCertBack = wf_prompts.onCertBack;
    pub const onCertProceed = wf_prompts.onCertProceed;
    pub const onPermission = wf_prompts.onPermission;
    pub const postPermission = wf_prompts.postPermission;
    pub const rememberedSetting = wf_prompts.rememberedSetting;
    pub const rememberSetting = wf_prompts.rememberSetting;
    pub const showPermPrompt = wf_prompts.showPermPrompt;
    pub const answerPermission = wf_prompts.answerPermission;
    pub const clearPermPrompts = wf_prompts.clearPermPrompts;
    pub const onPermAllow = wf_prompts.onPermAllow;
    pub const onPermBlock = wf_prompts.onPermBlock;
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
    /// The effective popup policy for this face. One home: the helper's
    /// pushed copy, the blocked-popup path and the adopt-or-refuse check
    /// all read it, so they cannot disagree about what the user chose.
    fn popupAllowed(self: *WebFace, user_gesture: bool) bool {
        return switch (self.site_popup) {
            .allow => true,
            .block => false,
            .inherit => switch (g_popup_policy) {
                .allow => true,
                .block_all => false,
                .block_gestureless => user_gesture,
            },
        };
    }

    /// Keep the helper's copy of this view's popup policy current.
    ///
    /// `on_before_popup` must answer synchronously, so the decision
    /// cannot be a round trip; the client instead pushes the answer
    /// ahead of the question. A gestureless-blocking policy pushes
    /// ALLOW, because only the engine knows whether a real gesture is
    /// in progress — the client re-checks the gesture bit when the
    /// popup is announced.
    pub fn pushPopupPolicy(self: *WebFace) void {
        if (!self.cl.has(.popup_open)) return;
        const allow = self.popupAllowed(true);
        self.cl.post(proto.PopupPolicySet{
            .view = self.view,
            .mode = if (allow) proto.popup_mode_allow else proto.popup_mode_block,
        });
    }

    /// A popup the helper REALLY opened, opener intact. Present it;
    /// the page is already loading in it, so it must not be navigated.
    pub fn onPagePopup(self: *WebFace, ev: proto.EvPagePopup) void {
        const win = self.ownerWindow() orelse {
            self.cl.post(proto.ViewDestroy{ .view = ev.popup_view });
            return;
        };
        // Belt: the helper's copy of the policy can be one store round
        // trip stale, and only the engine knew about the gesture.
        if (!self.popupAllowed(ev.user_gesture != 0)) {
            self.cl.post(proto.ViewDestroy{ .view = ev.popup_view });
            self.toastBlockedPopup(ev.url);
            return;
        }
        // The page asked for a popup-SHAPED window (`window.open` with
        // `popup`/width/height features): a real secondary toplevel of
        // the requested size, the way every browser presents a login
        // popup. A featureless open is a tab, as it always was.
        if (ev.chromeless != 0) {
            _ = win.openWebPopupWindow(ev.popup_view, self.cl, ev.w, ev.h) catch {
                self.cl.post(proto.ViewDestroy{ .view = ev.popup_view });
            };
            return;
        }
        if (win.browserPagesInSidebar()) {
            if (self.group()) |g| {
                _ = attachPageExisting(self.allocator, g, ev.popup_view, self) catch {
                    self.cl.post(proto.ViewDestroy{ .view = ev.popup_view });
                };
                return;
            }
        }
        win.newWebTabForView(ev.popup_view, self.cl, self.ownerPage(), .tab) catch {
            self.cl.post(proto.ViewDestroy{ .view = ev.popup_view });
        };
    }

    pub fn onPopup(self: *WebFace, url: []const u8, user_gesture: bool) void {
        const open = self.popupAllowed(user_gesture);
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
        self.abandonAutoOps(false);
        self.invalidateReaderGuards();
        self.exitReader();
        self.dropMap();
        self.setStatus(CRASH_MSG, true);
    }

    /// The Window this face is displayed in, resolved through the
    /// widget root. Public because the omnibox dispatches command rows
    /// through it. Null once the widgets are dead.
    pub fn ownerWindow(self: *WebFace) ?*@import("window.zig").Window {
        if (self.widgets_dead) return null;
        return facehost.windowOf(self.root_box);
    }

    pub fn popupScale(self: *WebFace) u16 {
        return self.currentScale();
    }

    pub fn onWebextActions(self: *WebFace, json: []const u8) void {
        // An empty replace-all is how the helper purges a stale toolbar
        // on an INACTIVE view (`postActionsForActiveViews`); it only
        // clears local state, so it must get past the active-page gate.
        const is_clear = std.mem.eql(u8, std.mem.trim(u8, json, " \t\r\n"), "[]");
        if (!is_clear and !self.isActivePage()) return;
        if (self.actions) |a| {
            a.refresh(json);
            a.setPresented(self.nativeActionActive());
        }
    }

    pub fn openWebextPopup(self: *WebFace, id: []const u8) bool {
        if (!self.nativeActionActive()) return false;
        if (self.actions) |a| return a.openPopup(id);
        return false;
    }

    fn nativeActionActive(self: *WebFace) bool {
        if (!self.isActivePage()) return false;
        const pane = self.pane orelse return false;
        const win = self.ownerWindow() orelse return false;
        const active_pane = win.focusedPane() orelse win.selectedTabPane();
        return active_pane == pane and windowFocused(win);
    }

    pub fn syncNativeActionPresentation(self: *WebFace) void {
        if (self.widgets_dead) return;
        if (self.actions) |a| a.setPresented(self.nativeActionActive());
    }

    pub fn onWebextPopup(self: *WebFace, ev: proto.EvWebextPopup) void {
        if (self.actions) |a| a.onPopup(ev);
    }

    pub fn adoptWebextPopupBuffer(self: *WebFace, fb: proto.FrameBuffer, fd: c_int) bool {
        const a = self.actions orelse return false;
        return a.adoptBuffer(fb, fd);
    }

    pub fn onWebextPopupDamage(self: *WebFace, ev: proto.FrameDamage) bool {
        const a = self.actions orelse return false;
        return a.damage(ev);
    }

    pub fn onWebextPopupInline(self: *WebFace, ev: proto.FrameInline) bool {
        const a = self.actions orelse return false;
        return a.inlineFrame(ev);
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
    }

    pub fn navAction(self: *WebFace, action: proto.NavAct) void {
        if (!self.view_live) return;
        // Same as a navigation: `nav_action` revives helper-side.
        self.noteRevived();
        self.cl.post(proto.NavAction{ .view = self.view, .action = @intFromEnum(action) });
        if (action == .stop) self.invalidateReaderGuards();
    }

    pub const openFind = wf_page.openFind;
    pub const closeFind = wf_page.closeFind;
    pub const findQuery = wf_page.findQuery;
    pub const findStart = wf_page.findStart;
    pub const findStep = wf_page.findStep;
    pub const onFindResult = wf_page.onFindResult;
    pub const toggleReader = wf_page.toggleReader;
    pub const requestReader = wf_page.requestReader;
    pub const onReadReply = wf_page.onReadReply;
    pub const enterReader = wf_page.enterReader;
    pub const exitReader = wf_page.exitReader;
    pub const syncReaderButton = wf_page.syncReaderButton;
    pub const toast = wf_page.toast;
    pub const onReaderToggled = wf_page.onReaderToggled;
    pub const onMenuReader = wf_page.onMenuReader;
    pub const zoom_min_x100 = wf_page.zoom_min_x100;
    pub const zoom_max_x100 = wf_page.zoom_max_x100;
    pub const zoomStep = wf_page.zoomStep;
    pub const zoomReset = wf_page.zoomReset;
    pub const userZoomFactor = wf_page.userZoomFactor;
    pub const setZoomLevel = wf_page.setZoomLevel;
    pub const faceChord = wf_page.faceChord;
    pub const MenuCtx = wf_page.MenuCtx;
    pub const freeMenuCtx = wf_page.freeMenuCtx;
    pub const onContextMenu = wf_page.onContextMenu;
    pub const appendToolRows = wf_page.appendToolRows;
    pub const appendContainerRows = wf_page.appendContainerRows;
    pub const copyText = wf_page.copyText;
    pub const pasteFromClipboard = wf_page.pasteFromClipboard;
    pub const copyToClipboard = wf_page.copyToClipboard;
    pub const buildNavStrip = wf_page.buildNavStrip;
    pub const onBurger = wf_page.onBurger;
    pub const showBurgerMenu = wf_page.showBurgerMenu;
    pub const shellRowLabel = wf_page.shellRowLabel;
    pub const fillPassword = wf_pw.fillPassword;
    pub const fillFrom = wf_pw.fillFrom;
    pub const typeIntoPage = wf_pw.typeIntoPage;
    pub const tapKeyval = wf_pw.tapKeyval;
    pub const devToolsRefusal = wf_print.devToolsRefusal;
    pub const openDevTools = wf_print.openDevTools;
    pub const onDevToolsView = wf_print.onDevToolsView;
    pub const canPrintPdf = wf_print.canPrintPdf;
    pub const printRefusal = wf_print.printRefusal;
    pub const printToPdf = wf_print.printToPdf;
    pub const suggestedPdfName = wf_print.suggestedPdfName;
    pub const onPrintDone = wf_print.onPrintDone;
    pub const deliverStagedPdf = wf_print.deliverStagedPdf;
    pub const openLocalFile = wf_print.openLocalFile;
    pub const webDownloadStart = wf_print.webDownloadStart;
    pub const webDownloadRefusal = wf_print.webDownloadRefusal;
    pub const DownloadInfo = wf_print.DownloadInfo;
    pub const webDownloadList = wf_print.webDownloadList;
    pub const webDownloadCancel = wf_print.webDownloadCancel;
    pub const takeAsked = wf_print.takeAsked;
    pub const expireAsked = wf_print.expireAsked;
    pub const recordFailedRequest = wf_print.recordFailedRequest;
    pub const findDownload = wf_print.findDownload;
    pub const onDownloadOffer = wf_print.onDownloadOffer;
    pub const autoAcceptDownload = wf_print.autoAcceptDownload;
    pub const stagingPath = wf_print.stagingPath;
    pub const rememberDownloadDir = wf_print.rememberDownloadDir;
    pub const startDownload = wf_print.startDownload;
    pub const startDownloadReq = wf_print.startDownloadReq;
    pub const buildDlRow = wf_print.buildDlRow;
    pub const dlButton = wf_print.dlButton;
    pub const updateDlRow = wf_print.updateDlRow;
    pub const onDownloadProgress = wf_print.onDownloadProgress;
    pub const beginHandoff = wf_print.beginHandoff;
    pub const ensureDlTimer = wf_print.ensureDlTimer;
    pub const stopDlTimer = wf_print.stopDlTimer;
    pub const finishHandoff = wf_print.finishHandoff;
    pub const dropStaging = wf_print.dropStaging;
    pub const removeDownload = wf_print.removeDownload;
    pub const rowDownload = wf_print.rowDownload;
    pub const webDownloadDismiss = wf_print.webDownloadDismiss;
    pub const failDownload = wf_print.failDownload;
    pub const actOnRow = wf_print.actOnRow;
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

    /// Flip the pane to its shell; `toggle_web_face` brings the page
    /// back. Reachable from the menu and from remote control.
    pub fn showShell(self: *WebFace) void {
        if (self.pane) |p| p.setWebVisible(false);
    }

    /// Flip content blocking for this view AND remember it for the
    /// site, so the next visit (in any window) starts that way.
    fn onShield(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        const want = !self.net_enabled;
        self.setNetwork(want);
        if (self.storeOrigin()) |origin| {
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
        // An observed page has an address (seeded right after
        // attach); a focused bar would then refuse to show it.
        if (self.observed) return;
        if (self.url != null or self.pending_url != null) return;
        _ = c.gtk_widget_grab_focus(self.entry);
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
        self.syncMaxFps();
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
    pub fn noteFrameGeometry(self: *WebFace) void {
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
    pub fn probeMapping(self: *WebFace, m: *MapRef) void {
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
        std.debug.print(
            "weblat: {s} input->arrival {d:.1} ms, ->pixel {d:.1} ms, {d} frames\n",
            .{
                if (g_lat.expect_hover) "hover" else "clear",
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

    fn onSurfaceMonitor(_: ?*c.GdkSurface, _: ?*c.GdkMonitor, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).syncMaxFps();
    }

    fn onAfterPaint(_: ?*c.GdkFrameClock, _: ?*anyopaque) callconv(.c) void {
        g_stats.presents += 1;
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
        // An observed view is the assistant's size, never this pane's:
        // only the letterbox moves.
        if (self.observed) {
            self.layoutObserved();
            return;
        }
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
    }

    /// `webframe.wireInput` sink. The GDK-to-protocol translation is
    /// shared with the extension popup; what stays here is this face's
    /// policy on top of it — hints mode, Ctrl+wheel zoom, window-level
    /// chords and pacing promotion.
    const InputSink = struct {
        pub fn pointer(
            user: ?*anyopaque,
            kind: proto.PointerKind,
            x: f64,
            y: f64,
            button: u8,
            clicks: u8,
            mods: u32,
        ) void {
            const self = cast.userData(WebFace, user);
            if (kind == .down) {
                // A real click while labels are up means the user went
                // back to the mouse; the click itself still reaches the
                // page.
                if (self.hints_active) self.cancelHints();
                _ = c.gtk_widget_grab_focus(self.view_area);
            }
            self.sendPointer(kind, x, y, button, clicks, mods);
        }

        pub fn scroll(user: ?*anyopaque, dx: f64, dy: f64, mods: u32) c.gboolean {
            const self = cast.userData(WebFace, user);
            // Scrolling moves every hint rect; stale labels would lie.
            if (self.hints_active) self.cancelHints();
            if (!self.view_live) return 0;
            // Ctrl+wheel is zoom, not scroll — the page never sees it.
            if (mods & proto.mod_ctrl != 0) {
                if (dy < 0) {
                    self.zoomStep(1);
                } else if (dy > 0) {
                    self.zoomStep(-1);
                }
                return 1;
            }
            self.cl.post(proto.InputScroll{
                .view = self.view,
                .x = self.last_x,
                .y = self.last_y,
                .dx = webframe.wheelDelta(dx),
                .dy = webframe.wheelDelta(dy),
                .mods = mods,
            });
            return 1;
        }

        /// Window-level chords win over the page (editor-face template):
        /// a browser that swallows every keystroke also swallows
        /// Ctrl+Shift+W and Alt+1..9, which is how a pane becomes a trap.
        pub fn key(
            user: ?*anyopaque,
            kind: proto.KeyKind,
            keyval: c.guint,
            keycode: c.guint,
            state: c.GdkModifierType,
        ) c.gboolean {
            const self = cast.userData(WebFace, user);
            if (kind != .down) {
                // The matching key-down was swallowed by hints mode;
                // releasing it into the page would be an unpaired
                // key-up.
                if (self.hints_active) return 0;
                return self.sendKey(.up, keyval, keycode, state);
            }
            // Hints mode owns the keyboard outright: labels are picked
            // by typing, and neither the page nor the chord table may
            // see a key until Escape or an activation ends the mode.
            if (self.hints_active) return self.hintsKey(keyval, state);
            if (self.pane) |pane| {
                if (pane.input_ctx) |ictx| {
                    if (input.fallbackToPaneBindings(ictx, keyval, state)) |handled| return handled;
                }
            }
            if (self.faceChord(keyval, state)) return 1;
            return self.sendKey(.down, keyval, keycode, state);
        }

        pub fn focus(user: ?*anyopaque, focused: bool) void {
            const self = cast.userData(WebFace, user);
            if (focused) tabsChanged();
            if (!self.view_live) return;
            self.cl.post(proto.InputFocus{ .view = self.view, .focused = @intFromBool(focused) });
        }
    };

    fn sendPointer(self: *WebFace, kind: proto.PointerKind, x: f64, y: f64, button: u8, clicks: u8, mods: u32) void {
        if (!self.view_live) return;
        if (kind != .leave) {
            if (self.observed) {
                // The frame is letterboxed at the owner's size: map
                // through the fit into the owner's logical space.
                const fw = if (self.frame_lw != 0) self.frame_lw else self.obs_w;
                const fh = if (self.frame_lh != 0) self.frame_lh else self.obs_h;
                const pt = self.obs_fit.toFrame(x, y, fw, fh);
                self.last_x = pt.x;
                self.last_y = pt.y;
            } else {
                // Controller coordinates are view-area space; the page is
                // drawn `snap_dx/dy` further in (the pixel-grid nudge), so
                // page space subtracts it.
                self.last_x = @max(0, @as(i32, @intFromFloat(@round(x))) - @as(i32, self.snap_dx));
                self.last_y = @max(0, @as(i32, @intFromFloat(@round(y))) - @as(i32, self.snap_dy));
            }
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
    }

    pub fn sendKey(
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
        const text = webframe.keyText(&text_buf, kind, keyval, mods);
        self.cl.post(proto.InputKey{
            .view = self.view,
            .kind = @intFromEnum(kind),
            .keyval = keyval,
            .keycode = keycode,
            .mods = mods,
            .text = text,
        });
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

/// input.zig `face_paste` sink; same stateless shape as `webHintsSink`.
/// False means the pane is not showing a web page (or the helper cannot
/// take the text), so the terminal path runs unchanged.
fn webPasteSink(pane_ctx: ?*anyopaque) bool {
    const pane: *Pane = @ptrCast(@alignCast(pane_ctx orelse return false));
    if (!pane.webFaceVisible()) return false;
    const face = WebFace.fromPane(pane) orelse return false;
    return face.pasteFromClipboard();
}

/// input.zig `face_copy` sink. Answering true is what keeps
/// `interrupt_or_copy`'s smart-copy branch from sending SIGINT to the
/// shell hidden behind a web page.
fn webCopySink(pane_ctx: ?*anyopaque, cut: bool) bool {
    const pane: *Pane = @ptrCast(@alignCast(pane_ctx orelse return false));
    if (!pane.webFaceVisible()) return false;
    const face = WebFace.fromPane(pane) orelse return false;
    return face.copyToClipboard(cut);
}

const modsFromState = webframe.modsFromState;

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
pub fn permissionLabel(types: u32) []const u8 {
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

/// Pending system-clipboard read, for the same reason as `PopupCtx`:
/// the async read outlives the face, so it carries the client (which is
/// never freed) plus a view id, never a face pointer.
pub const PasteCtx = struct {
    allocator: std.mem.Allocator,
    cl: *Client,
    view: u32,
};

pub fn onWebPasteRead(user: ?*anyopaque, text: ?[]const u8) void {
    const ctx = cast.userData(PasteCtx, user);
    const cl = ctx.cl;
    const view = ctx.view;
    ctx.allocator.destroy(ctx);
    const body = text orelse return;
    if (body.len == 0) return;
    // Resolve AFTER the read: the pane may have closed in between.
    const face = faceByViewOn(cl, view) orelse return;
    if (!face.view_live) return;
    cl.post(proto.InputPaste{ .view = view, .text = .{ .s = body } });
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

test "a private page is an observed or incognito one, and stores nothing per site" {
    const t = std.testing;
    var face: WebFace = undefined;
    face.observed = false;
    face.container = 0;
    var origin = "https://site.example".*;
    face.nav_origin = &origin;
    try t.expect(!face.isPrivate());
    try t.expectEqualStrings("https://site.example", face.storeOrigin().?);
    // An assistant's page this GUI only watches is not this user's.
    face.observed = true;
    try t.expect(face.isPrivate());
    try t.expect(face.storeOrigin() == null);
    // An incognito id the registry no longer knows is still private by
    // its range; a stored id is not.
    face.observed = false;
    face.container = EPHEMERAL_CONTAINER_BASE + 7;
    try t.expect(face.isPrivate());
    try t.expect(face.storeOrigin() == null);
    face.container = 7;
    try t.expect(!face.isPrivate());
}

test "print and DevTools refuse what the tab's own helper cannot do here" {
    const t = std.testing;
    var cl: Client = .{};
    var face: WebFace = undefined;
    face.cl = &cl;
    face.attached = false;
    face.view_live = true;
    try t.expect(face.printRefusal() != null); // no print_pdf capability
    try t.expect(face.devToolsRefusal() != null);
    cl.caps.insert(.print_pdf);
    cl.caps.insert(.devtools);
    try t.expect(face.printRefusal() == null);
    try t.expect(face.devToolsRefusal() == null);
    // A remote helper: the PDF must come HERE, which needs staging, and
    // the inspector would open in a window over there.
    @memcpy(cl.host[0..4], "box1");
    cl.host_len = 4;
    try t.expect(face.printRefusal() != null);
    try t.expect(face.devToolsRefusal() != null);
    cl.caps.insert(.print_pdf_staging);
    try t.expect(face.printRefusal() == null);
    try t.expect(face.devToolsRefusal() != null);
}

test "a fresh view's blank document is not the page it was created for" {
    const t = std.testing;
    const blank = WebFace.isPreNavigationBlank;
    try t.expect(blank("about:blank", "http://site.example/"));
    // A fresh view reports an EMPTY url before about:blank.
    try t.expect(blank("", "http://site.example/"));
    try t.expect(!blank("about:blank", null));
    try t.expect(!blank("about:blank", "about:blank"));
    try t.expect(!blank("http://site.example/", "http://site.example/"));
    try t.expect(!blank("http://other.example/", "http://site.example/"));
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

test "download and PDF file URIs preserve reserved filename characters" {
    const path = "/tmp/report#1? 100%.pdf";
    const file = c.g_file_new_for_path(path) orelse return error.OutOfMemory;
    defer c.g_object_unref(file);
    const uri = c.g_file_get_uri(file) orelse return error.OutOfMemory;
    defer c.g_free(uri);
    try std.testing.expectEqualStrings("file:///tmp/report%231%3F%20100%25.pdf", std.mem.span(uri));
    const reopened = c.g_file_new_for_uri(uri) orelse return error.OutOfMemory;
    defer c.g_object_unref(reopened);
    const decoded = c.g_file_get_path(reopened) orelse return error.OutOfMemory;
    defer c.g_free(decoded);
    try std.testing.expectEqualStrings(path, std.mem.span(decoded));
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

test "one helper instance per route, keyed on the whole spec" {
    const t = std.testing;
    const gpa = t.allocator;
    defer {
        for (g_aux_clients.items) |cl| gpa.destroy(cl);
        g_aux_clients.deinit(gpa);
        g_aux_clients = .empty;
    }

    // Direct is the process's own client, never a spawned instance.
    try t.expect(clientForRoute(gpa, .{}) == &g_client);
    try t.expectEqual(@as(usize, 0), g_aux_clients.items.len);

    const tor = webroute.Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" };
    const a = clientForRoute(gpa, tor).?;
    try t.expect(a != &g_client);
    // Same route resolves to the SAME instance: two Tor tabs share one
    // process and therefore one profile.
    try t.expect(clientForRoute(gpa, tor).? == a);
    try t.expectEqual(@as(usize, 1), g_aux_clients.items.len);

    // A different endpoint is a different route and a different instance.
    const b = clientForRoute(gpa, .{ .kind = .tor, .endpoint = "127.0.0.1:9150" }).?;
    try t.expect(b != a);

    // Mux egress to a host and a remote helper ON that host are distinct.
    const egress = clientForRoute(gpa, .{ .kind = .mux, .host = "box" }).?;
    const remote = clientForRoute(gpa, .{ .kind = .remote_browser, .host = "box" }).?;
    try t.expect(egress != remote);
    // Only the remote-helper placement is "remote"; a mux route is a
    // LOCAL helper whose traffic is proxied.
    try t.expect(!egress.isRemote());
    try t.expect(remote.isRemote());
    // clientForHost is the same registry, so it must not double-spawn.
    try t.expect(clientForHost(gpa, "box").? == remote);

    // The route survives the round trip through the client's buffers.
    try t.expect(a.routeSpec().eql(tor));

    // An invalid route gets NO instance: a Tor spec with no endpoint
    // would configure no proxy and browse direct under a Tor label.
    try t.expect(clientForRoute(gpa, .{ .kind = .tor }) == null);
    try t.expect(clientForRoute(gpa, .{ .kind = .mux }) == null);
}

test "routes that differ get different profile directories" {
    const t = std.testing;
    // Two CEF processes sharing a root_cache_path is measured-fatal, so
    // distinct routes must never derive the same slug.
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const tor = (webroute.Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" }).slug(&a).?;
    const mux = (webroute.Spec{ .kind = .mux, .host = "box" }).slug(&b).?;
    try t.expect(!std.mem.eql(u8, tor, mux));
}

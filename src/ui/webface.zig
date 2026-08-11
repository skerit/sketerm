//! WebFace — a real browser inside a pane, rendered by the optional
//! `sketerm-webengine` helper (src/web/, docs/proposal-browser.md).
//!
//! Two objects live here:
//!
//! - `Client`: ONE helper process per GUI process, its unix socket
//!   watched with `g_unix_fd_add` and never read blocking. It owns the
//!   handshake, view-id allocation and event routing; faces register in
//!   it and are found by view id.
//! - `WebFace`: one pane face = one view id. Chrome (address entry,
//!   back/forward/reload) plus a `GtkPicture` presenting the view's
//!   frames as `GdkTexture`s in GTK's own scene graph.
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
const clipboard = @import("clipboard.zig");
const webreader = @import("webreader.zig");
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
    next_view: u32 = 1,
    faces: std.ArrayList(*WebFace) = .empty,

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
        for (self.faces.items) |f| f.onClientReady();
        return true;
    }

    /// The connection died (helper crash, protocol error). Faces show
    /// the "helper stopped" overlay; a Reload starts a fresh one.
    fn lost(self: *Client) void {
        if (self.state == .unavailable) return;
        self.reap();
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
                if (ack.proto != proto.PROTO_VERSION) self.fail("The browser helper speaks a different protocol version.");
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
                if (self.findFace(ev.view)) |face| face.onPopup(ev.url);
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
            else => {},
        }
    }
};

/// The one helper connection of this GUI process. Module-level and
/// never freed — see the lifetime notes at the top of the file.
var g_client: Client = .{};

pub fn client() *Client {
    return &g_client;
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
pub const AutoKind = enum { snapshot, act, expand, query, read, eval };

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

/// Page background for the view area (what a browser shows where
/// nothing painted; also the gutter during a live resize). Theme's view
/// background rather than white, so a dark theme does not flash: a page
/// that paints its own background covers this anyway.
fn webviewCss(widget: *c.GtkWidget) void {
    c.gtk_widget_add_css_class(widget, "sketerm-webview");
    cssutil.install("webface", widget, ".sketerm-webview { background: @view_bg_color; }");
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

pub const WebFace = struct {
    allocator: std.mem.Allocator,
    pane: ?*Pane = null,
    /// Helper-side view id, allocated once and kept across helper
    /// restarts (a fresh helper knows no ids at all).
    view: u32 = 0,
    /// True once `view_create` was sent on the CURRENT connection.
    view_live: bool = false,

    root_box: *c.GtkWidget = undefined,
    back_btn: *c.GtkWidget = undefined,
    fwd_btn: *c.GtkWidget = undefined,
    reload_btn: *c.GtkWidget = undefined,
    reader_btn: *c.GtkWidget = undefined,
    shell_btn: *c.GtkWidget = undefined,
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
    /// Find-in-page bar (Ctrl+F): hidden until opened. Built by hand —
    /// this tree has no shared findbar helper yet.
    find_bar: *c.GtkWidget = undefined,
    find_entry: *c.GtkWidget = undefined,
    find_count: *c.GtkWidget = undefined,

    /// Objects carrying signals whose user-data is this face. All are
    /// disconnected at the teardown choke point.
    signal_objs: [24]?*c.GObject = .{null} ** 24,
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

    /// Where the pane's tab title comes from while this face lives.
    title: ?[]u8 = null,
    can_back: bool = false,
    can_fwd: bool = false,

    /// USER zoom as the engine's log-scale level x100 (`set_zoom`):
    /// one Ctrl+= / Ctrl+- step is 100 (a 1.2x factor, the conventional
    /// browser step), Ctrl+0 resets to 0. Kept here so a helper restart
    /// re-applies it in `ensureView`.
    zoom_x100: i32 = 0,

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

    // ---- attach / teardown ------------------------------------------

    /// Put a web face on `pane`. A pane already wearing one just gets
    /// `url` opened in it. Never fails on a missing helper: the face
    /// exists and explains itself.
    pub fn attach(allocator: std.mem.Allocator, pane: *Pane, url: ?[]const u8) !*WebFace {
        if (fromPane(pane)) |existing| {
            if (url) |u| existing.navigate(u);
            pane.setWebVisible(true);
            return existing;
        }
        const self = try allocator.create(WebFace);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator };
        self.pane = pane;
        self.pacer.cap_fps = g_max_fps;
        if (url) |u| self.pending_url = allocator.dupe(u8, u) catch null;

        self.buildUi();
        if (!pane.attachWeb(self.root_box, @ptrCast(self), prepareDestroyCb, destroyCb, focusCb)) {
            // The box never reached a parent, so its floating reference
            // is still the only one.
            _ = c.g_object_ref_sink(@ptrCast(self.root_box));
            c.g_object_unref(@ptrCast(self.root_box));
            allocator.destroy(self);
            return error.PaneHasNoWrapper;
        }

        // Link hints dispatch (input.zig `web_hints` / `hints_open`).
        // The fn is stateless — it resolves this face from the Pane on
        // every call — so no teardown path has to clear it.
        if (pane.input_ctx) |ictx| ictx.web_hints = webHintsSink;

        const cl = client();
        cl.ensure(allocator);
        self.view = cl.next_view;
        cl.next_view += 1;
        cl.register(self);
        switch (cl.state) {
            .ready => self.onClientReady(),
            .unavailable => self.onHelperUnavailable(cl.reason, cl.reason_retryable),
            else => self.setStatus("Starting the browser helper…", false),
        }
        return self;
    }

    /// The face on `pane`, if any.
    pub fn fromPane(pane: *Pane) ?*WebFace {
        const ctx = pane.web_ctx orelse return null;
        return @ptrCast(@alignCast(ctx));
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

    fn prepareDestroyCb(ctx: *anyopaque, widgets_dead: bool) void {
        const self: *WebFace = @ptrCast(@alignCast(ctx));
        self.widgets_dead = self.widgets_dead or widgets_dead;
        self.cancelHints();
        // Owned reference: safe from any teardown path, dead widgets
        // included, and the ONLY place the surface watch is severed
        // besides the area's own unrealize.
        self.detachScaleWatch();
        // The reader's own controllers carry the READER as user-data,
        // so the disconnect loop below (which matches on this face)
        // cannot reach them; its `sever` is the same mechanism applied
        // at the same choke point.
        if (self.reader) |r| r.sever(self.widgets_dead);
        // Same mechanism (2: sever at the single choke point) for the
        // two pacing sources, which carry this face as user-data and
        // are not signals, so the disconnect loop below misses them.
        self.stopPacing();
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

    fn destroyCb(ctx: *anyopaque) void {
        const self: *WebFace = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// Raising the face focuses the page — except on a blank tab,
    /// where the address bar is the only useful target (what every
    /// browser does with a new tab).
    fn focusCb(ctx: *anyopaque) void {
        const self: *WebFace = @ptrCast(@alignCast(ctx));
        if (self.widgets_dead) return;
        // Raising the face re-asserts its title on the pane titlebar
        // (the flip cleared whatever the previous face had put there).
        self.applyPaneFaceTitle();
        if (self.reader_active) {
            if (self.reader) |r| r.focus();
            return;
        }
        if (self.url == null and self.pending_url == null) {
            _ = c.gtk_widget_grab_focus(self.entry);
            return;
        }
        _ = c.gtk_widget_grab_focus(self.view_area);
    }

    pub fn deinit(self: *WebFace) void {
        const cl = client();
        if (self.view_live) cl.post(proto.ViewDestroy{ .view = self.view });
        cl.unregister(self);
        self.detachScaleWatch();
        self.stopPacing();
        if (self.reader) |r| {
            r.sever(self.widgets_dead);
            r.destroy();
            self.reader = null;
        }
        self.dropMap();
        self.cancelHints();
        self.hints_items.deinit(self.allocator);
        if (self.pending_url) |u| self.allocator.free(u);
        if (self.url) |u| self.allocator.free(u);
        if (self.title) |t| self.allocator.free(t);
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
        client().post(proto.SemSnapshotReq{
            .view = self.view,
            .mode = mode,
            .detail = detail,
            .scope = scope,
        });
        return token;
    }

    pub fn autoAct(self: *WebFace, id: u32, action: u8, arg: []const u8) ?u32 {
        const token = self.autoBegin(.act, false) orelse return null;
        client().post(proto.SemAction{ .view = self.view, .id = id, .action = action, .arg = arg });
        // The helper synthesizes real input for this; the paints it
        // causes still need somebody asking for frames.
        self.promote();
        return token;
    }

    pub fn autoExpand(self: *WebFace, id: u32, off: u32, len: u32) ?u32 {
        const token = self.autoBegin(.expand, false) orelse return null;
        client().post(proto.SemExpand{ .view = self.view, .id = id, .off = off, .len = len });
        return token;
    }

    pub fn autoQuery(self: *WebFace, kind: u8, arg: []const u8) ?u32 {
        const token = self.autoBegin(.query, false) orelse return null;
        client().post(proto.SemQueryReq{ .view = self.view, .kind = kind, .arg = arg });
        return token;
    }

    pub fn autoRead(self: *WebFace) ?u32 {
        const token = self.autoBegin(.read, false) orelse return null;
        client().post(proto.SemRead{ .view = self.view });
        return token;
    }

    pub fn autoEval(self: *WebFace, code: []const u8, want_await: bool, timeout_ms: u32) ?u32 {
        const token = self.autoBegin(.eval, false) orelse return null;
        client().post(proto.SemEval{
            .view = self.view,
            .flags = if (want_await) proto.eval_flag_await else 0,
            .timeout_ms = timeout_ms,
            .code = .{ .s = code },
        });
        return token;
    }

    /// Wheel scrolling through the ORDINARY input path, at the last
    /// pointer position — the same frame an interactive scroll sends.
    pub fn autoScroll(self: *WebFace, dx: i32, dy: i32) bool {
        if (!self.view_live) return false;
        client().post(proto.InputScroll{
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
        client().post(proto.SemQueryReq{
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
            if (self.ownerWindow()) |win| {
                win.newWebTabAt(url) catch {};
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
        client().post(proto.FrameRequest{ .view = self.view, .flags = 0 });
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
        client().post(proto.ViewMaxFps{ .view = self.view, .fps = want });
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
    /// helper's own watchdog too, so nothing anywhere renders it.
    fn setOnScreen(self: *WebFace, on: bool) void {
        if (self.on_screen == on) return;
        self.on_screen = on;
        if (on) {
            if (paceLogging()) std.debug.print("webface pace: view {d} on screen\n", .{self.view});
            if (self.view_live) client().post(proto.ViewShow{ .view = self.view });
            self.startIdleTimer();
            self.startLatProbe();
            // A tab coming forward must show its current content at
            // once, not at the next idle tick.
            self.promote();
            return;
        }
        if (self.view_live) client().post(proto.ViewHide{ .view = self.view });
        self.cancelHints();
        self.stopPacing();
        if (paceLogging()) std.debug.print("webface pace: view {d} off screen (tick={d})\n", .{ self.view, self.tick_id });
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
        client().post(proto.ViewResize{
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

        // `sketerm-terminal-symbolic` is one of our own bundled icons,
        // but it goes through the fallback like every other name: a
        // theme chain that cannot draw it must not leave the way out
        // of the browser as an invisible button.
        self.shell_btn = toolbtn.barButton(bar, "sketerm-terminal-symbolic", "Shell", "Show this pane's shell", &onShowShell, self);
        self.track(self.shell_btn);

        c.gtk_box_append(@ptrCast(self.root_box), bar);

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

        c.gtk_box_append(@ptrCast(self.root_box), self.overlay);
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
        self.view_live = false;
        self.dropMap();
        self.sent_w = 0;
        self.sent_h = 0;
        self.ensureView();
    }

    pub fn onHelperUnavailable(self: *WebFace, reason: []const u8, retryable: bool) void {
        self.cancelHints();
        self.auto_ops.clearRetainingCapacity();
        self.view_live = false;
        self.dropMap();
        self.setStatus(reason, retryable);
    }

    fn ensureView(self: *WebFace) void {
        const cl = client();
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
            .context = 0,
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
        if (!self.on_screen) cl.post(proto.ViewHide{ .view = self.view });
        // The first load has to paint promptly, and nothing paints
        // unless somebody asks.
        self.promote();
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
        if (old_id != 0) client().post(proto.FrameRelease{ .view = self.view, .buf_id = old_id });
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
        self.applyTabTitle();
        self.applyPaneFaceTitle();
    }

    /// The pane's inner titlebar wears the page title too, but only
    /// while THIS face is the one showing -- a background face must
    /// not overwrite the visible face's title.
    fn applyPaneFaceTitle(self: *WebFace) void {
        const pane = self.pane orelse return;
        if (!pane.webFaceVisible()) return;
        const title = self.title orelse return;
        pane.setFaceTitle(title);
    }

    /// The pane's tab wears the page title while a web face is on it.
    fn applyTabTitle(self: *WebFace) void {
        if (self.widgets_dead) return;
        const pane = self.pane orelse return;
        const win = self.ownerWindow() orelse return;
        const page = @import("window.zig").tabPageForPane(win, pane) orelse return;
        const title = self.title orelse return;
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
        if (self.widgets_dead) return;
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
        } else if (ev.state == @intFromEnum(proto.LoadState.finished) or
            ev.state == @intFromEnum(proto.LoadState.failed))
        {
            self.load_seq +%= 1;
        }
    }

    pub fn onLoadError(self: *WebFace, ev: proto.EvLoadError) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Could not load {s}: {s} ({d})", .{ ev.url, ev.msg, ev.code }) catch "Could not load this page.";
        self.setStatus(msg, true);
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
    pub fn onPopup(self: *WebFace, url: []const u8) void {
        const win = self.ownerWindow() orelse return;
        win.newWebTabAt(url) catch {};
    }

    pub fn onCrashed(self: *WebFace) void {
        self.crashed = true;
        self.cancelHints();
        self.exitReader();
        self.dropMap();
        self.setStatus(CRASH_MSG, true);
    }

    fn ownerWindow(self: *WebFace) ?*@import("window.zig").Window {
        if (self.widgets_dead) return null;
        const root = c.gtk_widget_get_root(self.root_box) orelse return null;
        return @import("remotectl.zig").windowFromGtk(@ptrCast(@alignCast(root)));
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
        const cl = client();
        if (cl.state == .unavailable) {
            cl.restart();
            return;
        }
        cl.ensure(self.allocator);
        if (!self.view_live) {
            self.ensureView();
            return;
        }
        cl.post(proto.Navigate{ .view = self.view, .url = url });
        self.promote();
    }

    pub fn navAction(self: *WebFace, action: proto.NavAct) void {
        if (!self.view_live) return;
        client().post(proto.NavAction{ .view = self.view, .action = @intFromEnum(action) });
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
            client().post(proto.FindStop{ .view = self.view, .clear_selection = 1 });
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
            client().post(proto.FindStop{ .view = self.view, .clear_selection = 1 });
            return;
        }
        client().post(proto.Find{
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
        client().post(proto.Find{
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
        if (!self.view_live) return;
        client().post(proto.SetZoom{ .view = self.view, .level_x100 = level_x100 });
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

        const x: f64 = @floatFromInt(ev.x + @as(i32, self.snap_dx));
        const y: f64 = @floatFromInt(ev.y + @as(i32, self.snap_dy));
        _ = root.popup(self.view_area, x, y);
    }

    fn copyText(self: *WebFace, text: []const u8) void {
        if (self.widgets_dead) return;
        const z = self.allocator.dupeZ(u8, text) catch return;
        defer self.allocator.free(z);
        clipboard.copyToClipboard(self.root_box, z);
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
        const win = ctx.face.ownerWindow() orelse return;
        win.newWebTabAt(link) catch {};
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

    /// The crashed / helper-lost overlay's Reload: restart the helper
    /// when it is gone, else just reload the page.
    fn onRetry(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        const cl = client();
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
        client().post(proto.ViewResize{
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
        client().post(proto.InputScroll{
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
        client().post(proto.InputFocus{ .view = self.view, .focused = 1 });
        self.promote();
    }

    fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (!self.view_live) return;
        client().post(proto.InputFocus{ .view = self.view, .focused = 0 });
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
        client().post(proto.InputPointer{
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
        client().post(proto.InputKey{
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
/// dot and no space is a host, anything else is a web search.
fn normalizeUrl(buf: []u8, spec: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, spec, "://") != null) return spec;
    if (std.mem.startsWith(u8, spec, "about:") or
        std.mem.startsWith(u8, spec, "data:") or
        std.mem.startsWith(u8, spec, "file:") or
        std.mem.startsWith(u8, spec, "chrome:")) return spec;
    const looks_like_host = std.mem.indexOfScalar(u8, spec, ' ') == null and
        std.mem.indexOfScalar(u8, spec, '.') != null;
    if (looks_like_host) return std.fmt.bufPrint(buf, "https://{s}", .{spec}) catch null;
    return std.fmt.bufPrint(buf, "https://duckduckgo.com/?q={s}", .{spec}) catch null;
}

test "normalizeUrl keeps explicit schemes and promotes hosts" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com/", normalizeUrl(&buf, "https://example.com/").?);
    try std.testing.expectEqualStrings("data:text/html,x", normalizeUrl(&buf, "data:text/html,x").?);
    try std.testing.expectEqualStrings("https://example.com", normalizeUrl(&buf, "example.com").?);
    try std.testing.expect(std.mem.startsWith(u8, normalizeUrl(&buf, "two words").?, "https://duckduckgo.com/"));
}

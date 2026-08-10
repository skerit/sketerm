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
//!   back/forward/reload) plus a `GtkPicture` fed from the view's
//!   memfd.
//!
//! ## Rendering
//!
//! `frame_buffer` hands over a memfd; we mmap it read-only and keep the
//! mapping. Every `frame_damage` batch wraps that mapping in a `GBytes`
//! WITHOUT copying it and builds a `GdkMemoryTexture` over the whole
//! buffer — the damage rects are decoded but not yet exploited, because
//! a `GtkPicture` is not a GL area and selective upload needs the
//! ImagePass/GL path. That remains the follow-up: it would cut the
//! per-frame texture UPLOAD (still whole-buffer, done by GTK) down to
//! the damaged rects, which is the only copy left on this path.
//!
//! ## Frame pacing (who decides when the page paints)
//!
//! The helper's browsers run with `external_begin_frame_enabled`, so the
//! engine paints EXACTLY as often as somebody asks it to and never on
//! its own. That is what lifts CEF's 60fps windowless ceiling on a
//! 120/165Hz output, and what makes an untouched page cost nothing.
//!
//! Asking is this file's job, through `src/web/pace.zig`:
//!
//! - IDLE: a 5Hz GLib timeout asks for a frame, so a page that starts
//!   moving on its own is still noticed. NO frame-clock tick exists in
//!   this state — see the `tick_id` docblock in
//!   `src/ui/terminal_surface.zig`: an installed tick keeps GDK's frame
//!   clock cycling at monitor refresh even when nothing is drawn, and
//!   on Wayland each empty cycle leaks a frame-callback object id per
//!   offload subsurface until KWin's id space runs out and the process
//!   dies. `stopTick` is not an optimisation, it is the crash guard.
//! - ACTIVE: a tick on the picture widget paces requests at the CURRENT
//!   output's real refresh (from `gdk_frame_clock_get_refresh_info`),
//!   clamped by `browser_max_fps`. Any input promotes here immediately,
//!   so the first paint after a keystroke has no added latency.
//! - Back to IDLE after ~250ms of requests that produced no paint, at
//!   which point the tick REMOVES ITSELF (`onTick` returning
//!   G_SOURCE_REMOVE and zeroing `tick_id`), exactly like the terminal
//!   surface's animation tick.
//!
//! A background tab's picture is unmapped: the face then sends
//! `view_hide` and stops asking altogether, so an off-screen page paints
//! nothing at all. `SKETERM_WEB_PACE=1` logs every transition (and
//! aborts if a demoted face somehow kept its tick).
//!
//! Set `SKETERM_WEB_STATS=1` for a per-second stderr line with the
//! delivered frame rate and the time spent here. MEASURED on a 60fps
//! animating page: with the old whole-buffer `g_bytes_new` copy this
//! function cost ~143us/frame on a 1.8MiB buffer and ~1950us/frame on a
//! 19MiB one (a 3000x1800 window); zero-copy it is ~40us and ~24us —
//! i.e. the cost stopped scaling with the window at all.
//!
//! Zero-copy has two consequences. The helper rewrites the buffer in
//! place, so a texture GTK still holds can show a half-new frame: the
//! benign tearing the protocol doc already accepts for v1. And the
//! mapping must outlive every texture built over it, which is what
//! `Mapping` refcounts — GTK keeps textures alive past the frame that
//! set them (render nodes, its texture cache), so munmap-on-replace
//! would be a use-after-free.
//!
//! ## Scale (HiDPI)
//!
//! Per docs/proposal-browser-protocol.md "Scale contract": w/h on the
//! wire are LOGICAL, `scale_x1000` is the real fractional device scale,
//! and the buffer that comes back is PHYSICAL. The scale comes from
//! `gdk_surface_get_scale()` — `gtk_widget_get_scale_factor()` rounds
//! 1.5 up to 2 and must not be used. A surface only exists once the
//! picture is realized, so the face starts at 1.0, re-sends on realize,
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
const proto = @import("../web/protocol.zig");
const pace = @import("../web/pace.zig");
const clock = @import("../util/clock.zig");
const Pane = @import("pane.zig").Pane;

/// Helper binary name, looked up next to our own executable (the
/// `sketerm-mux` rule) before falling back to a dev build tree.
const HELPER_NAME = "sketerm-webengine";

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
// Frame mapping
// ---------------------------------------------------------------------

/// A refcounted read-only mmap of one helper frame buffer.
///
/// The face holds one reference; every `GBytes` handed to GDK holds
/// another and drops it from its free-func. Without that, replacing the
/// buffer (a resize, a scale change) would munmap memory a live
/// `GdkMemoryTexture` still points at — GTK keeps textures well past the
/// frame that set them.
const Mapping = struct {
    allocator: std.mem.Allocator,
    ptr: [*]align(std.heap.page_size_min) u8,
    len: usize,
    refs: u32,

    fn create(allocator: std.mem.Allocator, ptr: [*]align(std.heap.page_size_min) u8, len: usize) ?*Mapping {
        const m = allocator.create(Mapping) catch return null;
        m.* = .{ .allocator = allocator, .ptr = ptr, .len = len, .refs = 1 };
        return m;
    }

    fn ref(self: *Mapping) void {
        self.refs += 1;
    }

    fn unref(self: *Mapping) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        _ = c.munmap(self.ptr, self.len);
        self.allocator.destroy(self);
    }
};

fn mappingUnrefCb(user: ?*anyopaque) callconv(.c) void {
    const m: *Mapping = @ptrCast(@alignCast(user orelse return));
    m.unref();
}

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
            "webface stats: {d:.1} fps, onDamage avg {d:.1} us max {d:.1} us, {d:.0} MiB/s\n",
            .{ fps, avg_us, @as(f64, @floatFromInt(self.ns_max)) / 1000.0, mbps },
        );
        self.* = .{ .on = true, .checked = true, .window_start_ns = now };
    }
};

var g_stats: Stats = .{};

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
    for (g_client.faces.items) |f| f.pacer.cap_fps = fps;
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
        const bin = findHelperBinary(&bin_buf) orelse {
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
        const p = std.fmt.bufPrint(&self.sock_path, "{s}/web-{d}.sock", .{ dir, c.getpid() }) catch return null;
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
                    var passed: c_int = undefined;
                    @memcpy(std.mem.asBytes(&passed), cbuf[hdr_size..][0..@sizeOf(c_int)]);
                    self.fds.append(self.gpa, passed) catch {
                        _ = c.close(passed);
                    };
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
                if (self.findFace(ev.view)) |face| face.completeOp(.query, true, ev.payload.s, .{});
            },
            .sem_read_result => {
                const ev = proto.decode(proto.SemReadResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.completeOp(.read, true, ev.markdown.s, .{});
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

/// `sketerm-webengine` next to our own executable (installed layout and
/// `zig build` trees both), then the dev build tree, then $PATH.
/// `$SKETERM_WEB_BIN` pins it outright, which is what test rigs use.
fn findHelperBinary(buf: *[4096:0]u8) ?[*:0]const u8 {
    if (c.getenv("SKETERM_WEB_BIN")) |p| {
        if (c.access(p, c.X_OK) == 0) return p;
    }
    if (platform.exePathZ(buf)) |exe_path| {
        if (std.mem.lastIndexOfScalar(u8, exe_path, '/')) |slash| {
            const dir = exe_path[0 .. slash + 1];
            // Installed / `zig build` layout: a sibling of the GUI.
            if (writeCandidate(buf, dir, HELPER_NAME)) |p| return p;
            // A dev run straight out of a source checkout, where the
            // GUI was started from somewhere else in the tree.
            if (writeCandidate(buf, dir, "../zig-out/bin/" ++ HELPER_NAME)) |p| return p;
        }
    }
    if (c.access("zig-out/bin/" ++ HELPER_NAME, c.X_OK) == 0) return "zig-out/bin/" ++ HELPER_NAME;
    return null;
}

fn writeCandidate(buf: *[4096:0]u8, dir: []const u8, name: []const u8) ?[*:0]const u8 {
    if (dir.len + name.len + 1 >= buf.len) return null;
    // `dir` aliases `buf`; only the tail after it is written.
    @memcpy(buf[dir.len .. dir.len + name.len], name);
    buf[dir.len + name.len] = 0;
    if (c.access(buf, c.X_OK) != 0) return null;
    return @ptrCast(buf);
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
    shell_btn: *c.GtkWidget = undefined,
    entry: *c.GtkWidget = undefined,
    overlay: *c.GtkWidget = undefined,
    picture: *c.GtkWidget = undefined,
    /// Input-transparent GtkDrawingArea filling the overlay: GTK4's
    /// only clean allocation-change hook (wlapp.zig precedent).
    sensor: *c.GtkWidget = undefined,
    status_box: *c.GtkWidget = undefined,
    status_label: *c.GtkWidget = undefined,

    /// Objects carrying signals whose user-data is this face. All are
    /// disconnected at the teardown choke point.
    signal_objs: [14]?*c.GObject = .{null} ** 14,
    signal_count: usize = 0,

    /// Read-only mapping of the helper's frame memfd, refcounted so the
    /// textures built over it can outlive the buffer's replacement.
    mapping: ?*Mapping = null,
    buf_id: u32 = 0,
    /// PHYSICAL geometry of the mapped buffer (the wire announces it).
    buf_w: u16 = 0,
    buf_h: u16 = 0,
    buf_stride: u32 = 0,

    /// Last size handed to the helper, in logical pixels.
    sent_w: u16 = 0,
    sent_h: u16 = 0,
    /// Last device scale handed to the helper, x1000. 1000 until the
    /// picture is realized and a GdkSurface can be asked.
    sent_scale: u16 = 1000,
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
    /// GTK frame-clock tick id on `picture`, 0 when not installed. It
    /// exists ONLY while the page is actively repainting and removes
    /// itself the moment it is not — an idle tick is a KWin crash, not
    /// a waste (see the header and `terminal_surface.zig`'s `tick_id`).
    tick_id: c_uint = 0,
    /// Slow GLib timeout (5Hz): the idle floor that notices a page
    /// starting to move, and the reason no tick is needed to do so.
    /// Armed for the face's whole on-screen life.
    idle_timer: c.guint = 0,
    /// Whether the picture is mapped. A background tab is unmapped: it
    /// gets `view_hide` and is never asked for a frame.
    on_screen: bool = false,

    /// Address to open once the view exists (attach-time URL).
    pending_url: ?[]u8 = null,
    /// Current address, as last reported by the helper. Owned.
    url: ?[]u8 = null,
    loading: bool = false,
    crashed: bool = false,
    widgets_dead: bool = false,

    /// Where the pane's tab title comes from while this face lives.
    title: ?[]u8 = null,
    can_back: bool = false,
    can_fwd: bool = false,

    /// Automation bookkeeping (see AutoKind): in-flight requests, their
    /// finished results, the last snapshot as sent by the helper, and
    /// the last eval result in full (what `web_expand [0]` pages).
    auto_ops: std.ArrayList(AutoOp) = .empty,
    auto_results: std.ArrayList(AutoResult) = .empty,
    auto_next: u32 = 1,
    last_snapshot: ?[]u8 = null,
    last_snapshot_meta: AutoMeta = .{},
    last_eval: ?[]u8 = null,
    /// Deltas that arrived UNSOLICITED (the helper's mutation observer)
    /// while nobody was waiting. Without this they were dropped, and
    /// the caller's next snapshot honestly reported "nothing changed
    /// since then" — having eaten the very change it was asking about.
    pending_delta: std.ArrayList(u8) = .empty,

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

    fn prepareDestroyCb(ctx: *anyopaque, widgets_dead: bool) void {
        const self: *WebFace = @ptrCast(@alignCast(ctx));
        self.widgets_dead = self.widgets_dead or widgets_dead;
        // Owned reference: safe from any teardown path, dead widgets
        // included, and the ONLY place the surface watch is severed
        // besides the picture's own unrealize.
        self.detachScaleWatch();
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
        if (self.url == null and self.pending_url == null) {
            _ = c.gtk_widget_grab_focus(self.entry);
            return;
        }
        _ = c.gtk_widget_grab_focus(self.picture);
    }

    pub fn deinit(self: *WebFace) void {
        const cl = client();
        if (self.view_live) cl.post(proto.ViewDestroy{ .view = self.view });
        cl.unregister(self);
        self.detachScaleWatch();
        self.stopPacing();
        self.dropMap();
        if (self.pending_url) |u| self.allocator.free(u);
        if (self.url) |u| self.allocator.free(u);
        if (self.title) |t| self.allocator.free(t);
        self.autoClear();
        self.pending_delta.deinit(self.allocator);
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
        self.pending_delta.clearAndFree(self.allocator);
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

    /// PNG of the PAGE as the user sees it, for `screenshot_pane` /
    /// `web_screenshot`. The pane's own screenshot path renders the
    /// terminal surface, which on a web pane is the hidden shell
    /// underneath — so the face renders its picture widget instead,
    /// with the same widget-paintable technique.
    pub fn screenshotPng(self: *WebFace) ?*c.GBytes {
        if (self.widgets_dead) return null;
        // Automation looking at the page counts as activity: the shot
        // itself is of whatever was last painted, but going active now
        // keeps a burst of them from each being an idle-floor tick old.
        self.promote();
        const w = self.picture;
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

    /// Deltas buffered for an absent reader before the buffer is
    /// dropped. A page that animates must not grow it without bound.
    const MAX_PENDING_DELTA = 64 * 1024;

    pub fn onSnapshot(self: *WebFace, ev: proto.SemSnapshot) void {
        const meta: AutoMeta = .{ .doc_gen = ev.doc_gen, .rev = ev.rev, .snap_kind = ev.kind };
        if (self.allocator.dupe(u8, ev.payload.s)) |owned| {
            if (self.last_snapshot) |old| self.allocator.free(old);
            self.last_snapshot = owned;
            self.last_snapshot_meta = meta;
        } else |_| {}

        const full = ev.kind == @intFromEnum(proto.SnapKind.full);
        if (!self.snapshotWaiting()) {
            // Nobody asked: keep the change until someone does.
            if (full) self.pending_delta.clearRetainingCapacity();
            if (self.pending_delta.items.len < MAX_PENDING_DELTA) {
                self.pending_delta.appendSlice(self.allocator, ev.payload.s) catch {};
            } else if (!std.mem.endsWith(u8, self.pending_delta.items, DELTA_OVERFLOW)) {
                self.pending_delta.appendSlice(self.allocator, DELTA_OVERFLOW) catch {};
            }
            return;
        }
        if (full or self.pending_delta.items.len == 0) {
            self.pending_delta.clearRetainingCapacity();
            self.completeOp(.snapshot, true, ev.payload.s, meta);
            return;
        }
        // Hand back everything that happened since the caller last
        // looked, oldest first, then this reply.
        self.pending_delta.appendSlice(self.allocator, ev.payload.s) catch {};
        self.completeOp(.snapshot, true, self.pending_delta.items, meta);
        self.pending_delta.clearRetainingCapacity();
    }

    const DELTA_OVERFLOW = "... earlier changes dropped (buffer full); ask for mode=full\n";

    fn snapshotWaiting(self: *WebFace) bool {
        for (self.auto_ops.items) |op| {
            if (op.kind == .snapshot) return true;
        }
        return false;
    }

    pub fn onEvalResult(self: *WebFace, ev: proto.SemEvalResult) void {
        if (self.allocator.dupe(u8, ev.json.s)) |owned| {
            if (self.last_eval) |old| self.allocator.free(old);
            self.last_eval = owned;
        } else |_| {}
        self.completeOp(.eval, ev.ok != 0, ev.json.s, .{});
    }

    /// Drop OUR reference to the frame mapping; textures GDK still holds
    /// keep it alive until their `GBytes` die.
    fn dropMap(self: *WebFace) void {
        if (self.mapping) |m| {
            m.unref();
            self.mapping = null;
        }
        self.buf_id = 0;
        self.buf_w = 0;
        self.buf_h = 0;
    }

    // ---- frame pacing ------------------------------------------------

    /// Ask the helper for one frame, now.
    fn requestFrame(self: *WebFace) void {
        if (!self.view_live or !self.on_screen) return;
        client().post(proto.FrameRequest{ .view = self.view, .flags = 0 });
        self.pacer.noteRequest(c.g_get_monotonic_time());
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
            self.picture,
            @ptrCast(&onTick),
            @ptrCast(self),
            null,
        );
    }

    fn stopTick(self: *WebFace) void {
        if (self.tick_id == 0) return;
        if (!self.widgets_dead) c.gtk_widget_remove_tick_callback(self.picture, self.tick_id);
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
        self.pacer.stop();
    }

    /// A paint landed: keep the view active, and wake it if the page
    /// started moving while nobody was touching it.
    fn notePaint(self: *WebFace) void {
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
            if (self.view_live) client().post(proto.ViewShow{ .view = self.view });
            self.startIdleTimer();
            // A tab coming forward must show its current content at
            // once, not at the next idle tick.
            self.promote();
            return;
        }
        if (self.view_live) client().post(proto.ViewHide{ .view = self.view });
        self.stopPacing();
        if (paceLogging()) std.debug.print("webface pace: view {d} off screen (tick={d})\n", .{ self.view, self.tick_id });
    }

    // ---- device scale ----------------------------------------------

    /// The output's fractional device scale x1000, or the last known one
    /// while the picture has no surface yet.
    fn currentScale(self: *WebFace) u16 {
        if (self.widgets_dead) return self.sent_scale;
        const native = c.gtk_widget_get_native(self.picture) orelse return self.sent_scale;
        const surface = c.gtk_native_get_surface(native) orelse return self.sent_scale;
        const s = c.gdk_surface_get_scale(surface);
        if (!(s > 0.0)) return 1000;
        return @intFromFloat(std.math.clamp(@round(s * 1000.0), 250.0, 8000.0));
    }

    /// Watch the realized surface's scale so a drag to a differently
    /// scaled output re-renders at the new DPR.
    fn attachScaleWatch(self: *WebFace) void {
        if (self.widgets_dead) return;
        const native = c.gtk_widget_get_native(self.picture) orelse return;
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

        const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        c.gtk_widget_add_css_class(bar, "toolbar");
        c.gtk_widget_set_margin_start(bar, 4);
        c.gtk_widget_set_margin_end(bar, 4);
        c.gtk_widget_set_margin_top(bar, 4);
        c.gtk_widget_set_margin_bottom(bar, 4);

        self.back_btn = c.gtk_button_new_from_icon_name("go-previous-symbolic");
        c.gtk_widget_set_tooltip_text(self.back_btn, "Back");
        c.gtk_widget_set_sensitive(self.back_btn, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.back_btn), "clicked", @ptrCast(&onBack), self, null, 0);
        self.track(self.back_btn);
        c.gtk_box_append(@ptrCast(bar), self.back_btn);

        self.fwd_btn = c.gtk_button_new_from_icon_name("go-next-symbolic");
        c.gtk_widget_set_tooltip_text(self.fwd_btn, "Forward");
        c.gtk_widget_set_sensitive(self.fwd_btn, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.fwd_btn), "clicked", @ptrCast(&onForward), self, null, 0);
        self.track(self.fwd_btn);
        c.gtk_box_append(@ptrCast(bar), self.fwd_btn);

        self.reload_btn = c.gtk_button_new_from_icon_name("view-refresh-symbolic");
        c.gtk_widget_set_tooltip_text(self.reload_btn, "Reload");
        _ = c.g_signal_connect_data(@ptrCast(self.reload_btn), "clicked", @ptrCast(&onReload), self, null, 0);
        self.track(self.reload_btn);
        c.gtk_box_append(@ptrCast(bar), self.reload_btn);

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

        self.shell_btn = c.gtk_button_new_from_icon_name("sketerm-terminal-symbolic");
        c.gtk_widget_set_tooltip_text(self.shell_btn, "Show this pane's shell");
        _ = c.g_signal_connect_data(@ptrCast(self.shell_btn), "clicked", @ptrCast(&onShowShell), self, null, 0);
        self.track(self.shell_btn);
        c.gtk_box_append(@ptrCast(bar), self.shell_btn);

        c.gtk_box_append(@ptrCast(self.root_box), bar);

        self.overlay = c.gtk_overlay_new();
        c.gtk_widget_set_hexpand(self.overlay, 1);
        c.gtk_widget_set_vexpand(self.overlay, 1);

        self.picture = c.gtk_picture_new();
        c.gtk_picture_set_content_fit(@ptrCast(self.picture), c.GTK_CONTENT_FIT_FILL);
        c.gtk_picture_set_can_shrink(@ptrCast(self.picture), 1);
        c.gtk_widget_set_hexpand(self.picture, 1);
        c.gtk_widget_set_vexpand(self.picture, 1);
        c.gtk_widget_set_focusable(self.picture, 1);
        // The GdkSurface only exists once realized, and reparenting a
        // pane unrealizes it — so every realize re-attaches the scale
        // watch and re-reads the scale.
        _ = c.g_signal_connect_data(@ptrCast(self.picture), "realize", @ptrCast(&onPictureRealize), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.picture), "unrealize", @ptrCast(&onPictureUnrealize), self, null, 0);
        // Map/unmap IS the on-screen signal: a background tab's pane is
        // unmapped, and a page nobody can see must not be painted.
        _ = c.g_signal_connect_data(@ptrCast(self.picture), "map", @ptrCast(&onPictureMap), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(self.picture), "unmap", @ptrCast(&onPictureUnmap), self, null, 0);
        self.track(self.picture);
        c.gtk_overlay_set_child(@ptrCast(self.overlay), self.picture);
        self.wireInput();

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
        c.gtk_widget_add_controller(self.picture, motion);
        self.track(motion);

        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "pressed", @ptrCast(&onPressed), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(click), "released", @ptrCast(&onReleased), self, null, 0);
        c.gtk_widget_add_controller(self.picture, @ptrCast(click));
        self.track(click);

        const scroll = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
        _ = c.g_signal_connect_data(@ptrCast(scroll), "scroll", @ptrCast(&onScroll), self, null, 0);
        c.gtk_widget_add_controller(self.picture, scroll);
        self.track(scroll);

        const key = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(@ptrCast(key), "key-pressed", @ptrCast(&onKeyPressed), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(key), "key-released", @ptrCast(&onKeyReleased), self, null, 0);
        c.gtk_widget_add_controller(self.picture, key);
        self.track(key);

        const focus = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(@ptrCast(focus), "enter", @ptrCast(&onFocusEnter), self, null, 0);
        _ = c.g_signal_connect_data(@ptrCast(focus), "leave", @ptrCast(&onFocusLeave), self, null, 0);
        c.gtk_widget_add_controller(self.picture, focus);
        self.track(focus);
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
        self.auto_ops.clearRetainingCapacity();
        self.crashed = false;
        self.clearStatus();
        self.view_live = false;
        self.dropMap();
        self.sent_w = 0;
        self.sent_h = 0;
        self.ensureView();
    }

    pub fn onHelperUnavailable(self: *WebFace, reason: []const u8, retryable: bool) void {
        self.auto_ops.clearRetainingCapacity();
        self.view_live = false;
        self.dropMap();
        self.setStatus(reason, retryable);
    }

    fn ensureView(self: *WebFace) void {
        const cl = client();
        if (cl.state != .ready or self.view_live) return;
        const w: u16 = if (self.sent_w != 0) self.sent_w else 800;
        const h: u16 = if (self.sent_h != 0) self.sent_h else 600;
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
        // A view is created visible; tell the helper at once when this
        // face is on a background tab (a helper restart can rebuild a
        // view whose pane nobody is looking at).
        if (!self.on_screen) cl.post(proto.ViewHide{ .view = self.view });
        // The first load has to paint promptly, and nothing paints
        // unless somebody asks.
        self.promote();
        if (self.pending_url) |u| {
            cl.post(proto.Navigate{ .view = self.view, .url = u });
        } else if (self.url) |u| {
            cl.post(proto.Navigate{ .view = self.view, .url = u });
        }
    }

    /// A fresh frame buffer for this view: map it, drop the previous
    /// one, and tell the helper the old buffer is ours no more.
    pub fn adoptBuffer(self: *WebFace, fb: proto.FrameBuffer, fd: c_int) void {
        defer _ = c.close(fd);
        const size: usize = @as(usize, fb.stride) * @as(usize, fb.h);
        if (size == 0) return;
        const addr = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, fd, 0);
        if (addr == c.MAP_FAILED) return;
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
        const mapping = Mapping.create(self.allocator, bytes, size) orelse {
            _ = c.munmap(bytes, size);
            return;
        };
        const old_id = self.buf_id;
        self.dropMap();
        self.mapping = mapping;
        self.buf_id = fb.buf_id;
        self.buf_w = fb.w;
        self.buf_h = fb.h;
        self.buf_stride = fb.stride;
        if (old_id != 0) client().post(proto.FrameRelease{ .view = self.view, .buf_id = old_id });
        // A fresh buffer holds nothing yet: ask for the repaint that
        // fills it rather than waiting for the idle floor.
        self.promote();
    }

    pub fn onDamage(self: *WebFace, dmg: proto.FrameDamage) void {
        if (self.widgets_dead) return;
        // A damage batch for a buffer we already replaced describes
        // pixels we no longer have; the new buffer repaints in full.
        if (dmg.buf_id != self.buf_id) return;
        const mapping = self.mapping orelse return;
        const stats = g_stats.enabled();
        const t0 = if (stats) Stats.nowNs() else 0;
        // The WHOLE buffer is presented per batch; dmg.rects is what a
        // future GL/ImagePass path will upload selectively. The GBytes
        // does NOT copy — it borrows the mapping and holds a reference
        // for as long as GDK keeps the texture.
        mapping.ref();
        const gbytes = c.g_bytes_new_with_free_func(
            mapping.ptr,
            mapping.len,
            mappingUnrefCb,
            mapping,
        ) orelse {
            mapping.unref();
            return;
        };
        defer c.g_bytes_unref(gbytes);
        // Texture geometry is PHYSICAL; the picture draws it into its
        // LOGICAL allocation, so device pixels land 1:1.
        const tex = c.gdk_memory_texture_new(
            @intCast(self.buf_w),
            @intCast(self.buf_h),
            c.GDK_MEMORY_B8G8R8A8,
            gbytes,
            @intCast(self.buf_stride),
        ) orelse return;
        defer c.g_object_unref(tex);
        c.gtk_picture_set_paintable(@ptrCast(self.picture), @ptrCast(tex));
        self.notePaint();
        self.clearStatus();
        if (stats) g_stats.note(Stats.nowNs() - t0, mapping.len);
    }

    pub fn onTitle(self: *WebFace, title: []const u8) void {
        if (self.title) |t| self.allocator.free(t);
        self.title = self.allocator.dupe(u8, title) catch null;
        self.applyTabTitle();
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
            self.crashed = false;
            self.clearStatus();
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
        c.gtk_widget_set_cursor_from_name(self.picture, name);
    }

    /// A popup (target=_blank, window.open) becomes a NEW web tab in
    /// this window — never a navigation of the page that asked.
    pub fn onPopup(self: *WebFace, url: []const u8) void {
        const win = self.ownerWindow() orelse return;
        win.newWebTabAt(url) catch {};
    }

    pub fn onCrashed(self: *WebFace) void {
        self.crashed = true;
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
        _ = c.gtk_widget_grab_focus(self.picture);
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
        self.pacer.display_fps = refreshFps(frame_clock, self.pacer.display_fps);
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

    fn onPictureMap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).setOnScreen(true);
    }

    fn onPictureUnmap(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).setOnScreen(false);
    }

    fn onPictureRealize(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        self.attachScaleWatch();
        self.syncScale();
    }

    fn onPictureUnrealize(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).detachScaleWatch();
    }

    fn onSurfaceScale(_: ?*c.GObject, _: ?*c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        cast.userData(WebFace, user).syncScale();
    }

    fn onResize(_: ?*c.GtkDrawingArea, w: c_int, h: c_int, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
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
        _ = c.gtk_widget_grab_focus(self.picture);
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
        if (!self.view_live) return 0;
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
        if (self.pane) |pane| {
            if (pane.input_ctx) |ictx| {
                const lower = c.gdk_keyval_to_lower(keyval);
                const bindings: []const input.Binding =
                    if (ictx.bindings.len > 0) ictx.bindings else &input.default_bindings;
                if (input.matchBinding(bindings, lower, state) orelse
                    input.matchBinding(bindings, keyval, state)) |action|
                {
                    return input.runAction(ictx, action);
                }
            }
        }
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
            self.last_x = @intFromFloat(@round(x));
            self.last_y = @intFromFloat(@round(y));
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

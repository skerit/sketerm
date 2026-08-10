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
//! ## Rendering (v1)
//!
//! `frame_buffer` hands over a memfd; we mmap it read-only and keep the
//! mapping. Every `frame_damage` batch rebuilds a `GdkMemoryTexture`
//! over the WHOLE buffer and sets it on the picture — the damage rects
//! are decoded but not yet exploited. That is a deliberate v1
//! simplification: the planned upgrade is uploading only the damaged
//! rects into an ImagePass/GL texture, which is why the protocol
//! carries them at all.
//!
//! ## Scale (v1)
//!
//! The view is created at the widget's LOGICAL pixel size with
//! `scale_x1000 = 1000`. The helper hands CEF the same rect as view
//! rect and buffer size, so a device scale factor != 1 would make CEF
//! paint at a size the helper drops. Pointer coordinates are therefore
//! widget-local logical pixels, 1:1 with the view. HiDPI (a 2x buffer
//! with a 1x view rect) is a helper-side change, not a face-side one.
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
    signal_objs: [12]?*c.GObject = .{null} ** 12,
    signal_count: usize = 0,

    /// Read-only mapping of the helper's frame memfd.
    map: []align(std.heap.page_size_min) u8 = &.{},
    buf_id: u32 = 0,
    buf_w: u16 = 0,
    buf_h: u16 = 0,
    buf_stride: u32 = 0,

    /// Last size handed to the helper, in logical pixels.
    sent_w: u16 = 0,
    sent_h: u16 = 0,
    /// Last pointer position in view coordinates — scroll events carry
    /// no coordinates of their own.
    last_x: i32 = 0,
    last_y: i32 = 0,

    /// Address to open once the view exists (attach-time URL).
    pending_url: ?[]u8 = null,
    /// Current address, as last reported by the helper. Owned.
    url: ?[]u8 = null,
    loading: bool = false,
    crashed: bool = false,
    widgets_dead: bool = false,

    /// Where the pane's tab title comes from while this face lives.
    title: ?[]u8 = null,

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
        self.dropMap();
        if (self.pending_url) |u| self.allocator.free(u);
        if (self.url) |u| self.allocator.free(u);
        if (self.title) |t| self.allocator.free(t);
        self.allocator.destroy(self);
    }

    fn dropMap(self: *WebFace) void {
        if (self.map.len != 0) {
            _ = c.munmap(self.map.ptr, self.map.len);
            self.map = &.{};
        }
        self.buf_id = 0;
        self.buf_w = 0;
        self.buf_h = 0;
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
        self.crashed = false;
        self.clearStatus();
        self.view_live = false;
        self.dropMap();
        self.sent_w = 0;
        self.sent_h = 0;
        self.ensureView();
    }

    pub fn onHelperUnavailable(self: *WebFace, reason: []const u8, retryable: bool) void {
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
        cl.post(proto.ViewCreate{
            .view = self.view,
            .w = w,
            .h = h,
            // v1 renders at 1x; see the scale note at the top.
            .scale_x1000 = 1000,
            .context = 0,
        });
        self.view_live = true;
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
        const old_id = self.buf_id;
        self.dropMap();
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
        self.map = bytes[0..size];
        self.buf_id = fb.buf_id;
        self.buf_w = fb.w;
        self.buf_h = fb.h;
        self.buf_stride = fb.stride;
        if (old_id != 0) client().post(proto.FrameRelease{ .view = self.view, .buf_id = old_id });
    }

    pub fn onDamage(self: *WebFace, dmg: proto.FrameDamage) void {
        if (self.widgets_dead) return;
        // A damage batch for a buffer we already replaced describes
        // pixels we no longer have; the new buffer repaints in full.
        if (dmg.buf_id != self.buf_id or self.map.len == 0) return;
        // v1 presents the WHOLE buffer per batch; dmg.rects is what a
        // future GL/ImagePass path will upload selectively.
        const gbytes = c.g_bytes_new(self.map.ptr, self.map.len) orelse return;
        defer c.g_bytes_unref(gbytes);
        const tex = c.gdk_memory_texture_new(
            @intCast(self.buf_w),
            @intCast(self.buf_h),
            c.GDK_MEMORY_B8G8R8A8,
            gbytes,
            @intCast(self.buf_stride),
        ) orelse return;
        defer c.g_object_unref(tex);
        c.gtk_picture_set_paintable(@ptrCast(self.picture), @ptrCast(tex));
        self.clearStatus();
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
    }

    fn navAction(self: *WebFace, action: proto.NavAct) void {
        if (!self.view_live) return;
        client().post(proto.NavAction{ .view = self.view, .action = @intFromEnum(action) });
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

    fn onResize(_: ?*c.GtkDrawingArea, w: c_int, h: c_int, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(WebFace, user);
        if (w <= 0 or h <= 0) return;
        const nw: u16 = @intCast(@min(w, std.math.maxInt(u16)));
        const nh: u16 = @intCast(@min(h, std.math.maxInt(u16)));
        if (nw == self.sent_w and nh == self.sent_h and self.view_live) return;
        self.sent_w = nw;
        self.sent_h = nh;
        if (!self.view_live) {
            self.ensureView();
            return;
        }
        client().post(proto.ViewResize{
            .view = self.view,
            .w = nw,
            .h = nh,
            .scale_x1000 = 1000,
        });
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
        return 1;
    }
};

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

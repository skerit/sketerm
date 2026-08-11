//! Unix-socket server for the browser helper: one listener, one client,
//! one poll loop that also drives CEF.
//!
//! SINGLE-THREADED BY CONSTRUCTION. `cef_do_message_loop_work()` is
//! called from this loop, and CEF is initialized with
//! `multi_threaded_message_loop = 0` / `external_message_pump = 0`, so
//! every CEF callback (paint, title, load, popup) runs INSIDE that call
//! — on this thread, between two poll iterations. Nothing in
//! sketerm-web is therefore locked, atomic, or handed across threads,
//! and introducing a thread would break all of it at once.
//!
//! No CEF type appears here: the loop talks to `cefhost` and moves
//! `protocol` frames.

const std = @import("std");
const c = @import("cbindings");
const proto = @import("protocol.zig");
const cefhost = @import("cefhost.zig");

/// Poll timeout while at least one view exists — CEF wants to be
/// pumped at roughly frame rate. With no view there is nothing to
/// render and the loop idles instead.
const busy_timeout_ms: c_int = 5;
const idle_timeout_ms: c_int = 50;

/// Pumps granted to CEF after the client goes away, so `close_browser`
/// can finish before `cef_shutdown`.
const drain_pumps = 100;

pub const Server = struct {
    gpa: std.mem.Allocator,
    listen_fd: c_int = -1,
    client_fd: c_int = -1,
    path: []const u8,
    in: std.ArrayList(u8) = .empty,
    out: proto.Outbox,
    host: cefhost.Host = undefined,
    /// Set once the client's `hello` is answered.
    greeted: bool = false,

    pub fn init(gpa: std.mem.Allocator, path: []const u8) Server {
        return .{ .gpa = gpa, .path = path, .out = proto.Outbox.init(gpa) };
    }

    pub fn deinit(self: *Server) void {
        self.in.deinit(self.gpa);
        // Undelivered messages may still carry a memfd; nobody else
        // will close them.
        while (self.out.front()) |m| {
            for (m.fdSlice()) |fd| _ = c.close(fd);
            self.out.advance(m.bytes.len);
        }
        self.out.deinit();
        if (self.client_fd >= 0) _ = c.close(self.client_fd);
        if (self.listen_fd >= 0) _ = c.close(self.listen_fd);
    }

    /// Bind and listen. The path must be short: sockaddr_un caps at
    /// ~108 bytes and a deep path fails to bind.
    pub fn listen(self: *Server) !void {
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        if (self.path.len + 1 > @sizeOf(@TypeOf(addr.sun_path))) return error.SocketPathTooLong;
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..self.path.len], self.path);

        var z: [256]u8 = undefined;
        if (self.path.len + 1 > z.len) return error.SocketPathTooLong;
        @memcpy(z[0..self.path.len], self.path);
        z[self.path.len] = 0;
        _ = c.unlink(@ptrCast(&z));

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        self.listen_fd = fd;
        _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
        if (c.listen(fd, 1) != 0) return error.ListenFailed;
    }

    /// Accept the single client, serve it until it disconnects, then
    /// tear every view down. Returns when the client is gone.
    pub fn run(self: *Server) !void {
        self.host = cefhost.Host.init(self.gpa, &self.out);
        defer self.host.deinit();
        self.host.install();
        // Load the seed list + config filters dir before any view
        // exists, so the very first navigation is already filtered.
        cefhost.interceptInit(self.gpa);
        defer cefhost.interceptDeinit(self.gpa);

        try self.accept();
        while (self.client_fd >= 0) {
            self.step();
        }
        // Let CEF finish closing the browsers before the caller shuts
        // it down; close_browser is asynchronous.
        self.host.destroyAll();
        var i: usize = 0;
        while (i < drain_pumps) : (i += 1) cefhost.pump();
    }

    /// Wait for the client, pumping CEF meanwhile (it has nothing to do
    /// yet, but a stalled loop is a habit worth not forming).
    fn accept(self: *Server) !void {
        while (true) {
            var pfd = c.struct_pollfd{ .fd = self.listen_fd, .events = c.POLLIN, .revents = 0 };
            const n = c.poll(@ptrCast(&pfd), 1, idle_timeout_ms);
            cefhost.pump();
            if (n < 0) {
                if (errno() == c.EINTR) continue;
                return error.PollFailed;
            }
            if (n == 0) continue;
            const fd = c.accept(self.listen_fd, null, null);
            if (fd < 0) {
                if (errno() == c.EINTR or errno() == c.EAGAIN) continue;
                return error.AcceptFailed;
            }
            _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
            _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
            self.client_fd = fd;
            return;
        }
    }

    /// One loop iteration: poll, drain the socket, pump CEF, flush.
    fn step(self: *Server) void {
        var pfd = c.struct_pollfd{
            .fd = self.client_fd,
            .events = @as(c_short, c.POLLIN) | (if (self.out.empty()) @as(c_short, 0) else @as(c_short, c.POLLOUT)),
            .revents = 0,
        };
        const timeout: c_int = if (self.host.viewCount() > 0) busy_timeout_ms else idle_timeout_ms;
        const n = c.poll(@ptrCast(&pfd), 1, timeout);
        if (n < 0 and errno() != c.EINTR) {
            self.disconnect();
            return;
        }
        if (n > 0) {
            if (pfd.revents & (c.POLLERR | c.POLLNVAL) != 0) {
                self.disconnect();
                return;
            }
            if (pfd.revents & c.POLLIN != 0 and !self.readIn()) {
                self.disconnect();
                return;
            }
        }
        // Nothing paints without a begin frame: keep a floor under every
        // visible view in case the client stopped asking for them.
        self.host.watchdog(cefhost.nowMs());
        // CEF callbacks queue outbound frames, so pump BEFORE flushing.
        cefhost.pump();
        // Coalesced per-view blocked/total counters: at most one
        // `intercept_status` per view per iteration, however many
        // requests the IO thread logged in between.
        self.host.flushInterceptStatus();
        if (!self.flush()) self.disconnect();
    }

    fn disconnect(self: *Server) void {
        if (self.client_fd >= 0) _ = c.close(self.client_fd);
        self.client_fd = -1;
    }

    /// Read what is available and dispatch complete frames. Returns
    /// false on EOF or a fatal socket/protocol error.
    fn readIn(self: *Server) bool {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(self.client_fd, &buf, buf.len);
            if (n == 0) return false;
            if (n < 0) {
                const e = errno();
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                if (e == c.EINTR) continue;
                return false;
            }
            self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch return false;
            if (@as(usize, @intCast(n)) < buf.len) break;
        }

        var reader = proto.Reader.init(self.in.items);
        while (true) {
            const frame = (reader.next() catch return false) orelse break;
            self.dispatch(frame) catch return false;
        }
        const used = reader.consumed();
        if (used != 0) {
            const rest = self.in.items.len - used;
            std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[used..]);
            self.in.shrinkRetainingCapacity(rest);
        }
        return true;
    }

    fn dispatch(self: *Server, frame: proto.Frame) !void {
        // Nothing but the handshake is served before it: a client that
        // skipped `hello` has not agreed a protocol version, so acting
        // on its frames would be guessing.
        if (!self.greeted and frame.tag != .hello) return;
        switch (frame.tag) {
            .hello => {
                const req = try proto.decode(proto.Hello, frame.payload);
                if (req.proto != proto.PROTO_VERSION) return error.ProtocolMismatch;
                // `frames-shm` is unconditional even in GPU mode: the
                // engine drops back to software compositing on its own
                // when the GPU goes away, and the client must be ready
                // for the memfd frames that follow.
                var caps: [15][]const u8 = .{
                    proto.CAP_FRAMES_SHM,
                    proto.CAP_INPUT,
                    proto.CAP_NAVIGATION,
                    proto.CAP_SEMANTIC,
                    proto.CAP_VIEW_CREATE_URL,
                    proto.CAP_DISCARD,
                    proto.CAP_FIND,
                    proto.CAP_ZOOM,
                    proto.CAP_CONTEXT_MENU,
                    proto.CAP_INTERCEPT,
                    proto.CAP_TLS,
                    proto.CAP_PERMISSIONS,
                    proto.CAP_DEVTOOLS,
                    proto.CAP_PRINT_PDF,
                    undefined,
                };
                var ncaps: usize = 14;
                if (cefhost.isAccelerated()) {
                    caps[ncaps] = proto.CAP_FRAMES_DMABUF;
                    ncaps += 1;
                }
                try self.out.post(proto.HelloAck{
                    .proto = proto.PROTO_VERSION,
                    .engine_name = cefhost.engineName(),
                    .engine_version = cefhost.engineVersion(),
                    .caps = caps[0..ncaps],
                }, null);
                self.greeted = true;
            },
            .view_create => try self.host.createView(try proto.decode(proto.ViewCreate, frame.payload)),
            .view_create_url => try self.host.createViewUrl(try proto.decode(proto.ViewCreateUrl, frame.payload)),
            .view_destroy => self.host.destroyView((try proto.decode(proto.ViewDestroy, frame.payload)).view),
            .view_discard => self.host.discardView((try proto.decode(proto.ViewDiscard, frame.payload)).view),
            .view_resize => try self.host.resizeView(try proto.decode(proto.ViewResize, frame.payload)),
            .view_show => self.host.showView((try proto.decode(proto.ViewShow, frame.payload)).view, true),
            .view_hide => self.host.showView((try proto.decode(proto.ViewHide, frame.payload)).view, false),
            .view_max_fps => self.host.setMaxFps(try proto.decode(proto.ViewMaxFps, frame.payload)),
            .cert_decision => self.host.certDecision(try proto.decode(proto.CertDecision, frame.payload)),
            .permission_decision => self.host.permissionDecision(try proto.decode(proto.PermissionDecision, frame.payload)),
            .navigate => self.host.navigate(try proto.decode(proto.Navigate, frame.payload)),
            .nav_action => self.host.navAction(try proto.decode(proto.NavAction, frame.payload)),
            .find => self.host.findInPage(try proto.decode(proto.Find, frame.payload)),
            .find_stop => self.host.findStop(try proto.decode(proto.FindStop, frame.payload)),
            .set_zoom => self.host.setZoom(try proto.decode(proto.SetZoom, frame.payload)),
            .input_pointer => self.host.pointer(try proto.decode(proto.InputPointer, frame.payload)),
            .input_scroll => self.host.scroll(try proto.decode(proto.InputScroll, frame.payload)),
            .input_key => self.host.key(try proto.decode(proto.InputKey, frame.payload)),
            .input_ime => self.host.ime(try proto.decode(proto.InputIme, frame.payload)),
            .input_focus => self.host.focus(try proto.decode(proto.InputFocus, frame.payload)),
            // v1 accepts the release for symmetry but keeps no per-buffer
            // state: one memfd per view, replaced on resize.
            .frame_release => _ = try proto.decode(proto.FrameRelease, frame.payload),
            .frame_request => self.host.beginFrame(try proto.decode(proto.FrameRequest, frame.payload)),
            .sem_snapshot_req => try self.host.semSnapshot(try proto.decode(proto.SemSnapshotReq, frame.payload)),
            .sem_act => try self.host.semAct(try proto.decode(proto.SemAction, frame.payload)),
            .sem_expand => try self.host.semExpand(try proto.decode(proto.SemExpand, frame.payload)),
            .sem_query => try self.host.semQuery(try proto.decode(proto.SemQueryReq, frame.payload)),
            .sem_read => try self.host.semRead(try proto.decode(proto.SemRead, frame.payload)),
            .sem_eval => try self.host.semEval(try proto.decode(proto.SemEval, frame.payload)),
            .intercept_set => self.host.interceptSet(try proto.decode(proto.InterceptSet, frame.payload)),
            .intercept_lists => {
                const req = try proto.InterceptLists.decodeAlloc(frame.payload, self.gpa);
                defer self.gpa.free(req.paths);
                self.host.interceptLists(req);
            },
            .intercept_status_req => self.host.interceptStatus(try proto.decode(proto.InterceptStatusReq, frame.payload)),
            .intercept_log_req => self.host.interceptLog(try proto.decode(proto.InterceptLogReq, frame.payload)),
            .devtools_show => try self.host.devtoolsShow(try proto.decode(proto.DevToolsShow, frame.payload)),
            .print_pdf => self.host.printPdf(try proto.decode(proto.PrintPdf, frame.payload)),
            // Helper-to-client frames arriving from the client, and any
            // tag this build does not act on, are ignored by design.
            else => {},
        }
    }

    /// Push queued messages. Returns false when the socket died.
    fn flush(self: *Server) bool {
        while (self.out.front()) |m| {
            const n = self.sendMsg(m);
            if (n < 0) {
                const e = errno();
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) return true;
                if (e == c.EINTR) continue;
                return false;
            }
            for (m.fdSlice()) |fd| _ = c.close(fd);
            self.out.advance(@intCast(n));
        }
        return true;
    }

    /// sendmsg with the message's SCM_RIGHTS descriptors attached — one
    /// memfd for a `frame_buffer`, one per plane for a `frame_dmabuf`.
    /// They must travel as ONE control message: several SCM_RIGHTS
    /// headers on one sendmsg is not portable and a receiver reading a
    /// single cmsg would drop the rest on the floor.
    fn sendMsg(self: *Server, m: proto.Message) isize {
        var iov = c.struct_iovec{
            .iov_base = @constCast(m.bytes.ptr),
            .iov_len = m.bytes.len,
        };
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
        const fds = m.fdSlice();
        if (fds.len != 0) {
            const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
            const payload = fds.len * @sizeOf(c_int);
            const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
            cmsg.cmsg_len = @intCast(hdr_size + payload);
            cmsg.cmsg_level = c.SOL_SOCKET;
            cmsg.cmsg_type = c.SCM_RIGHTS;
            @memcpy(cbuf[hdr_size..][0..payload], std.mem.sliceAsBytes(fds));
            mh.msg_control = &cbuf;
            mh.msg_controllen = @intCast(std.mem.alignForward(usize, hdr_size + payload, 8));
        }
        return c.sendmsg(self.client_fd, &mh, 0);
    }
};

fn errno() c_int {
    return std.c._errno().*;
}

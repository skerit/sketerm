//! A loopback listener with an accept loop on its own thread, plus the
//! one HTTP 200 response writer the fixture servers share.
//!
//! Five fixture servers (bench-webreq's HttpServer, smoke-web's
//! HttpProbe, WreqServer, UboServer and the SOCKS5 ProxyProbe) each had
//! their own copy of bind-loopback-ephemeral / getsockname / spawn /
//! poll-accept / join. Only two knobs actually differed between the
//! copies, so both are fields with the value each caller used:
//! `backlog` and `poll_ms`.

const std = @import("std");
const c = @import("../c.zig").c;

/// A bound, listening loopback socket plus the thread draining it.
/// Embed it in the fixture struct and pass that struct as `ctx`.
pub const Listener = struct {
    fd: c_int = -1,
    port: u16 = 0,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),

    /// `listen(2)` backlog. Each caller keeps the value it had.
    backlog: c_int = 16,
    /// Accept-poll timeout in ms; also the worst-case `deinit` latency.
    poll_ms: c_int = 200,

    ctx: ?*anyopaque = null,
    /// Called with each accepted fd. `Listener` closes the fd after it
    /// returns; a handler that hands the fd to a worker thread must
    /// return true to keep it open.
    handler: ?*const fn (?*anyopaque, c_int) bool = null,

    /// Bind an ephemeral loopback port and start serving. False when any
    /// step failed, with nothing left open.
    pub fn start(
        self: *Listener,
        ctx: ?*anyopaque,
        handler: *const fn (?*anyopaque, c_int) bool,
    ) bool {
        const lfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (lfd < 0) return false;
        var one: c_int = 1;
        _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = std.mem.nativeToBig(u16, 0);
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.bind(lfd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or
            c.listen(lfd, self.backlog) != 0)
        {
            _ = c.close(lfd);
            return false;
        }
        var got = std.mem.zeroes(c.struct_sockaddr_in);
        var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(lfd, @ptrCast(&got), &glen) != 0) {
            _ = c.close(lfd);
            return false;
        }
        self.fd = lfd;
        self.port = std.mem.bigToNative(u16, got.sin_port);
        self.ctx = ctx;
        self.handler = handler;
        self.thread = std.Thread.spawn(.{}, serve, .{self}) catch {
            _ = c.close(lfd);
            self.fd = -1;
            return false;
        };
        return true;
    }

    fn serve(self: *Listener) void {
        while (!self.stop.load(.acquire)) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(@ptrCast(&pfd), 1, self.poll_ms) <= 0) continue;
            const afd = c.accept(self.fd, null, null);
            if (afd < 0) continue;
            const keep = self.handler.?(self.ctx, afd);
            if (!keep) _ = c.close(afd);
        }
    }

    /// Stop the loop, join the thread, close the listener. Idempotent.
    ///
    /// The `shutdown(2)` before the join is smoke-web's HttpProbe
    /// teardown, which was the only copy to have it: it wakes a poll
    /// that just armed instead of waiting out `poll_ms`. That copy
    /// CLOSED the fd there too, which races the serve thread against fd
    /// reuse; closing after the join is the same speed without the race.
    pub fn deinit(self: *Listener) void {
        self.stop.store(true, .release);
        if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT_RDWR);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

/// Read whatever the client sent, up to `buf.len`, waiting at most
/// `timeout_ms`. Empty slice when nothing arrived.
pub fn readRequest(afd: c_int, buf: []u8, timeout_ms: c_int) []const u8 {
    var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
    if (c.poll(@ptrCast(&pfd), 1, timeout_ms) <= 0) return "";
    const n = c.read(afd, buf.ptr, buf.len);
    if (n <= 0) return "";
    return buf[0..@intCast(n)];
}

/// A 200 with `body`. `extra` is spliced in ahead of `Connection:
/// close` so each fixture keeps the exact header block it served
/// before: "" for the cookie probe, an
/// `Access-Control-Allow-Origin: *` line for the routers, plus
/// `X-Stage: 34` for the blocking-webRequest one.
pub fn respondOk(afd: c_int, ctype: []const u8, body: []const u8, extra: []const u8) void {
    var head: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(
        &head,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\n{s}Connection: close\r\n\r\n",
        .{ ctype, body.len, extra },
    ) catch return;
    _ = c.write(afd, hdr.ptr, hdr.len);
    _ = c.write(afd, body.ptr, body.len);
}

/// The `extra` header block for a fixture that must be readable
/// cross-origin.
pub const CORS = "Access-Control-Allow-Origin: *\r\n";

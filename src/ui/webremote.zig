//! Remote browser-helper bridge: a socketpair whose GUI end a
//! `webface.Client` adopts as its ordinary helper socket, and whose
//! other end a detached worker pumps to a `sketerm-webengine` spawned
//! on a REMOTE mux host (`web_helper_open` + a web_helper byte channel).
//!
//! The GUI side never learns it is remote: the Client posts and reads
//! the same protocol frames on its fd, and the helper (launched with
//! `--frames-inline`) ships pixels in-band, so nothing on this path
//! ever needs SCM_RIGHTS. Failure reporting is by CONSTRUCTION, not by
//! callback: the worker records a reason and closes its socketpair end,
//! the GUI end HUPs, and `Client.lost()` collects `takeReason()` on the
//! main thread — no idle handback, nothing to fence.
//!
//! GTK-free except for c.zig's libc surface: the worker owns a
//! `mux/client.Conn` and a plain poll loop, the socksbridge shape.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const wire = @import("../mux/wire.zig");
const mux_client = @import("../mux/client.zig");
const mux_cli = @import("../ipc/mux_cli.zig");

/// How long the worker waits for the daemon's `web_helper_reply`.
/// Spawning the helper is immediate (the socketpair exists before the
/// reply), so this bounds only a wedged daemon.
const REPLY_TIMEOUT_MS: i64 = 15_000;

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    host: [256]u8 = undefined,
    host_len: usize = 0,
    /// The end the webface Client adopts. Owned by the CLIENT once
    /// `guiFd` was taken; the bridge never touches it.
    gui_fd: c_int = -1,
    /// The bridge-owned end of the socketpair.
    fd: c_int = -1,
    /// Self-pipe waking the poll loop for `stop`.
    stop_r: c_int = -1,
    stop_w: c_int = -1,
    thread: ?std.Thread = null,
    conn: mux_client.Conn = undefined,
    conn_ok: bool = false,
    /// Why the bridge died, for `Client.lost()` to show. Written by the
    /// worker BEFORE it closes its socketpair end (the release fence is
    /// that close: the main thread only reads this after the HUP).
    reason: [192]u8 = undefined,
    reason_len: usize = 0,

    /// Make the socketpair and record `host`. Call `spawn` to start the
    /// worker; `guiFd` hands out the client end exactly once.
    pub fn create(allocator: std.mem.Allocator, host: []const u8) ?*Bridge {
        const self = allocator.create(Bridge) catch return null;
        self.* = .{ .allocator = allocator };
        self.host_len = @min(host.len, self.host.len);
        @memcpy(self.host[0..self.host_len], host[0..self.host_len]);
        var pair: [2]c_int = .{ -1, -1 };
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair) != 0) {
            allocator.destroy(self);
            return null;
        }
        _ = c.fcntl(pair[0], c.F_SETFD, c.FD_CLOEXEC);
        _ = c.fcntl(pair[1], c.F_SETFD, c.FD_CLOEXEC);
        self.gui_fd = pair[0];
        self.fd = pair[1];
        var pipefds: [2]c_int = .{ -1, -1 };
        if (c.pipe(&pipefds) == 0) {
            self.stop_r = pipefds[0];
            self.stop_w = pipefds[1];
            _ = c.fcntl(self.stop_r, c.F_SETFL, c.O_NONBLOCK);
            _ = c.fcntl(self.stop_r, c.F_SETFD, c.FD_CLOEXEC);
            _ = c.fcntl(self.stop_w, c.F_SETFD, c.FD_CLOEXEC);
        }
        return self;
    }

    /// The GUI end, exactly once (the Client owns and closes it).
    pub fn guiFd(self: *Bridge) c_int {
        const fd = self.gui_fd;
        self.gui_fd = -1;
        return fd;
    }

    pub fn spawn(self: *Bridge) void {
        self.thread = std.Thread.spawn(.{}, Bridge.worker, .{self}) catch null;
        if (self.thread == null)
            self.failWith("could not start the remote-helper bridge worker");
    }

    /// The reason the worker recorded before dying, or "".
    pub fn takeReason(self: *Bridge) []const u8 {
        return self.reason[0..self.reason_len];
    }

    /// Stop the worker and free everything. May block briefly on the
    /// worker's join while a slow ssh connect is still in flight — the
    /// socksbridge Egress accepts the same trade.
    pub fn stop(self: *Bridge) void {
        if (self.stop_w >= 0) {
            const b: [1]u8 = .{0};
            _ = c.write(self.stop_w, &b, 1);
        }
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.gui_fd >= 0) _ = c.close(self.gui_fd);
        self.gui_fd = -1;
        if (self.stop_r >= 0) _ = c.close(self.stop_r);
        if (self.stop_w >= 0) _ = c.close(self.stop_w);
        self.stop_r = -1;
        self.stop_w = -1;
        if (self.conn_ok) {
            self.conn.deinit();
            self.conn_ok = false;
        }
        self.allocator.destroy(self);
    }

    fn failWith(self: *Bridge, reason: []const u8) void {
        const n = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..n], reason[0..n]);
        self.reason_len = n;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn worker(self: *Bridge) void {
        const h = self.host[0..self.host_len];
        const conn = mux_cli.muxConnect(self.allocator, if (h.len == 0) null else h) orelse {
            self.failWith("Could not reach the sketerm-mux daemon on that host.");
            return;
        };
        self.conn = conn;
        self.conn_ok = true;
        if (!self.conn.web_helper) {
            self.failWith("The daemon on that host is too old for remote browsing (no web_helper capability).");
            return;
        }
        self.conn.sendJson(.web_helper_open, .{ .req = @as(u32, 1) }) catch {
            self.failWith("Could not ask the remote daemon for a browser helper.");
            return;
        };
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            chan: u32 = 0,
            @"error": []const u8 = "",
        };
        var chan: u32 = 0;
        const deadline = nowMs() + REPLY_TIMEOUT_MS;
        while (chan == 0) {
            const left = deadline - nowMs();
            if (left <= 0) {
                self.failWith("The remote daemon did not answer the browser-helper request in time.");
                return;
            }
            const f = self.conn.recvFrameFor(left) catch {
                self.failWith("Lost the connection to the remote daemon while opening the browser helper.");
                return;
            };
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .web_helper_reply => {
                    var parsed = std.json.parseFromSlice(Reply, self.allocator, f.payload, .{
                        .ignore_unknown_fields = true,
                    }) catch {
                        self.failWith("The remote daemon answered the helper request with garbage.");
                        return;
                    };
                    defer parsed.deinit();
                    if (!parsed.value.ok or parsed.value.chan == 0) {
                        if (parsed.value.@"error".len != 0) {
                            var buf: [192]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "Remote browser helper failed: {s}", .{parsed.value.@"error"}) catch parsed.value.@"error";
                            self.failWith(msg);
                        } else self.failWith("The remote daemon could not start a browser helper.");
                        return;
                    }
                    chan = parsed.value.chan;
                },
                // An `.err` is what a pre-capability daemon answers; the
                // capability check above already screened those, so any
                // err here is a real failure.
                .err => {
                    self.failWith("The remote daemon refused the browser-helper request.");
                    return;
                },
                // chan_open (kind web_helper) precedes the reply and is
                // confirmation only; anything else on this dedicated
                // connection is skipped.
                else => {},
            }
        }
        self.pump(chan);
        // However the pump ended, the close IS the notification.
        self.failWith(self.takeReasonOr("The connection to the remote browser helper was lost."));
    }

    fn takeReasonOr(self: *Bridge, fallback: []const u8) []const u8 {
        return if (self.reason_len != 0) self.reason[0..self.reason_len] else fallback;
    }

    /// Relay bytes both ways until either side dies or `stop` wakes us.
    fn pump(self: *Bridge, chan: u32) void {
        while (true) {
            var fds: [3]c.struct_pollfd = .{
                .{ .fd = self.conn.fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.fd, .events = c.POLLIN, .revents = 0 },
                .{ .fd = self.stop_r, .events = c.POLLIN, .revents = 0 },
            };
            if (c.poll(&fds, fds.len, -1) < 0) {
                if (std.c._errno().* == c.EINTR) continue;
                return;
            }
            if (fds[2].revents & c.POLLIN != 0) return;
            if (fds[1].revents & (c.POLLIN | c.POLLHUP) != 0) {
                var buf: [32 * 1024]u8 = undefined;
                const n = c.read(self.fd, &buf, buf.len);
                if (n <= 0) return;
                if (!self.sendChanData(chan, buf[0..@intCast(n)])) return;
            }
            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
                if (!self.pumpConn(chan)) return;
            }
        }
    }

    fn sendChanData(self: *Bridge, chan: u32, data: []const u8) bool {
        var hdr: [4]u8 = undefined;
        var msg: [4 + 32 * 1024]u8 = undefined;
        _ = wire.putChanHeader(&hdr, chan);
        var off: usize = 0;
        while (off < data.len) {
            const take = @min(data.len - off, msg.len - 4);
            @memcpy(msg[0..4], &hdr);
            @memcpy(msg[4 .. 4 + take], data[off .. off + take]);
            self.conn.sendFrame(.chan_data, msg[0 .. 4 + take]) catch return false;
            off += take;
        }
        return true;
    }

    fn pumpConn(self: *Bridge, chan: u32) bool {
        const f = self.conn.recvFrame() catch return false;
        defer f.deinit(self.allocator);
        switch (f.ftype) {
            .chan_data => {
                const id = wire.decodeChanId(f.payload) orelse return true;
                if (id != chan) return true;
                var off: usize = 4;
                while (off < f.payload.len) {
                    const n = c.write(self.fd, f.payload.ptr + off, f.payload.len - off);
                    if (n <= 0) {
                        if (std.c._errno().* == c.EINTR) continue;
                        return false;
                    }
                    off += @intCast(n);
                }
            },
            .chan_close => {
                const id = wire.decodeChanId(f.payload) orelse return true;
                if (id == chan) {
                    self.failWith("The remote browser helper exited.");
                    return false;
                }
            },
            .gone => return false,
            else => {},
        }
        return true;
    }
};

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

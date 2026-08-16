//! Remote browser-helper bridge: a socketpair whose GUI end a
//! `webface.Client` adopts as its ordinary helper socket, and whose
//! other end a detached worker pumps to a `sketerm-webengine` spawned
//! on a REMOTE mux host (`web_helper_open` + a web_helper byte channel).
//!
//! The GUI side never learns it is remote: the Client posts and reads
//! the same protocol frames on its fd, and the helper (launched with
//! `--frames-inline`) ships pixels in-band, so nothing on this path
//! ever needs SCM_RIGHTS. Failure reporting is by CONSTRUCTION, not by
//! callback: the worker records a reason and shuts down its socketpair end,
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
const FdCancel = @import("../util/fdcancel.zig").FdCancel;

/// How long the worker waits for the daemon's `web_helper_reply`.
/// Spawning the helper is immediate (the socketpair exists before the
/// reply), so this bounds only a wedged daemon.
const REPLY_TIMEOUT_MS: i64 = 15_000;
const MAX_LOCAL_OUT: usize = 16 << 20;

pub const Bridge = struct {
    allocator: std.mem.Allocator,
    host: [256]u8 = undefined,
    host_len: usize = 0,
    /// The end the webface Client adopts. Owned by the CLIENT once
    /// `guiFd` was taken; the bridge never touches it.
    gui_fd: c_int = -1,
    /// The bridge-owned end of the socketpair.
    fd: c_int = -1,
    /// Required wakeup for every worker poll.
    wakeup: ?platform.Wakeup = null,
    thread: ?std.Thread = null,
    conn: mux_client.Conn = undefined,
    conn_ok: bool = false,
    cancel: FdCancel = .{},
    /// Why the bridge died, for `Client.lost()` to show. The atomic length
    /// publishes the bytes before shutdown makes the GUI observe HUP.
    reason: [192]u8 = undefined,
    reason_len: std.atomic.Value(usize) = .init(0),

    /// Make the socketpair and record `host`. Call `spawn` to start the
    /// worker; `guiFd` hands out the client end exactly once.
    pub fn create(allocator: std.mem.Allocator, host: []const u8) ?*Bridge {
        return createUsing(allocator, host, platform.Wakeup.init);
    }

    fn createUsing(
        allocator: std.mem.Allocator,
        host: []const u8,
        wakeup_init: *const fn () anyerror!platform.Wakeup,
    ) ?*Bridge {
        const self = allocator.create(Bridge) catch return null;
        self.* = .{ .allocator = allocator };
        self.host_len = @min(host.len, self.host.len);
        @memcpy(self.host[0..self.host_len], host[0..self.host_len]);
        var pair: [2]c_int = .{ -1, -1 };
        if (platform.socketpairCloexec(&pair) != 0) {
            allocator.destroy(self);
            return null;
        }
        const wakeup = wakeup_init() catch {
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
            allocator.destroy(self);
            return null;
        };
        setNonBlockingFd(pair[1]) catch {
            wakeup.close();
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
            allocator.destroy(self);
            return null;
        };
        self.gui_fd = pair[0];
        self.fd = pair[1];
        self.wakeup = wakeup;
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
        return self.reason[0..self.reason_len.load(.acquire)];
    }

    /// Stop the worker, interrupt its sockets, and free everything.
    pub fn stop(self: *Bridge) void {
        self.cancel.stop();
        if (self.wakeup) |wake| wake.signal();
        if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT_RDWR);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        if (self.gui_fd >= 0) _ = c.close(self.gui_fd);
        self.gui_fd = -1;
        if (self.wakeup) |wake| {
            wake.close();
            self.wakeup = null;
        }
        if (self.conn_ok) {
            self.conn.deinit();
            self.conn_ok = false;
        }
        self.allocator.destroy(self);
    }

    fn failWith(self: *Bridge, reason: []const u8) void {
        if (self.cancel.isStopped()) return;
        const n = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..n], reason[0..n]);
        self.reason_len.store(n, .release);
        if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT_RDWR);
    }

    fn worker(self: *Bridge) void {
        const h = self.host[0..self.host_len];
        const conn = mux_cli.muxConnect(self.allocator, if (h.len == 0) null else h) orelse {
            self.failWith("Could not reach the sketerm-mux daemon on that host.");
            return;
        };
        self.conn = conn;
        self.conn_ok = true;
        self.conn.setNonBlockingChecked() catch {
            self.failWith("Could not make the remote daemon connection nonblocking.");
            return;
        };
        if (!(self.cancel.publish(self.conn.fd) catch {
            self.failWith("Could not make the remote daemon connection cancellable.");
            return;
        })) return;
        defer self.cancel.release();
        if (!self.conn.web_helper) {
            self.failWith("The daemon on that host is too old for remote browsing (no web_helper capability).");
            return;
        }
        const chan = self.openHelper() orelse return;
        self.pump(chan);
        // However the pump ended, the close IS the notification.
        if (self.reason_len.load(.acquire) == 0)
            self.failWith("The connection to the remote browser helper was lost.");
    }

    const OpenState = union(enum) { pending, opened: u32, failed };

    fn openHelper(self: *Bridge) ?u32 {
        self.conn.queueJson(.web_helper_open, .{ .req = @as(u32, 1) }) catch {
            self.failWith("Could not ask the remote daemon for a browser helper.");
            return null;
        };
        const wakeup = self.wakeup orelse return null;
        const deadline = nowMs() + REPLY_TIMEOUT_MS;
        while (true) {
            switch (self.drainOpenFrames()) {
                .opened => |chan| return chan,
                .failed => return null,
                .pending => {},
            }
            const left = deadline - nowMs();
            if (left <= 0) {
                self.failWith("The remote daemon did not answer the browser-helper request in time.");
                return null;
            }
            var fds: [2]c.struct_pollfd = .{
                .{
                    .fd = self.conn.fd,
                    .events = @intCast(c.POLLIN | if (self.conn.wbuf.items.len != 0) c.POLLOUT else 0),
                    .revents = 0,
                },
                .{ .fd = wakeup.read_fd, .events = c.POLLIN, .revents = 0 },
            };
            const polled = c.poll(&fds, fds.len, @intCast(left));
            if (polled < 0) {
                if (std.posix.errno(polled) == .INTR) continue;
                self.failWith("Lost the connection to the remote daemon while opening the browser helper.");
                return null;
            }
            if (fds[1].revents != 0) return null;
            if (fds[0].revents & c.POLLOUT != 0) {
                self.conn.flushQueued() catch {
                    self.failWith("Could not ask the remote daemon for a browser helper.");
                    return null;
                };
            }
            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
                const connected = self.conn.fillAvailable();
                switch (self.drainOpenFrames()) {
                    .opened => |chan| return chan,
                    .failed => return null,
                    .pending => {},
                }
                if (!connected) {
                    self.failWith("Lost the connection to the remote daemon while opening the browser helper.");
                    return null;
                }
            }
            if (fds[0].revents & (c.POLLERR | c.POLLNVAL) != 0) {
                self.failWith("Lost the connection to the remote daemon while opening the browser helper.");
                return null;
            }
        }
    }

    fn drainOpenFrames(self: *Bridge) OpenState {
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            chan: u32 = 0,
            @"error": []const u8 = "",
        };
        while (true) {
            const f = (self.conn.takeFrame() catch {
                self.failWith("The remote daemon answered the helper request with garbage.");
                return .failed;
            }) orelse return .pending;
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .web_helper_reply => {
                    var parsed = std.json.parseFromSlice(Reply, self.allocator, f.payload, .{
                        .ignore_unknown_fields = true,
                    }) catch {
                        self.failWith("The remote daemon answered the helper request with garbage.");
                        return .failed;
                    };
                    defer parsed.deinit();
                    if (parsed.value.req != 1 or !parsed.value.ok or parsed.value.chan == 0) {
                        if (parsed.value.@"error".len != 0) {
                            var buf: [192]u8 = undefined;
                            const msg = std.fmt.bufPrint(&buf, "Remote browser helper failed: {s}", .{parsed.value.@"error"}) catch parsed.value.@"error";
                            self.failWith(msg);
                        } else self.failWith("The remote daemon could not start a browser helper.");
                        return .failed;
                    }
                    return .{ .opened = parsed.value.chan };
                },
                .err => {
                    self.failWith("The remote daemon refused the browser-helper request.");
                    return .failed;
                },
                .gone => return .failed,
                else => {},
            }
        }
    }

    const Pending = struct {
        bytes: std.ArrayList(u8) = .empty,
        off: usize = 0,

        fn len(self: *const Pending) usize {
            return self.bytes.items.len - self.off;
        }

        fn append(self: *Pending, allocator: std.mem.Allocator, data: []const u8) !void {
            if (self.off != 0) {
                const pending = self.len();
                std.mem.copyForwards(u8, self.bytes.items[0..pending], self.bytes.items[self.off..]);
                self.bytes.shrinkRetainingCapacity(pending);
                self.off = 0;
            }
            if (data.len > MAX_LOCAL_OUT - self.bytes.items.len) return error.Backpressure;
            try self.bytes.appendSlice(allocator, data);
        }

        fn flush(self: *Pending, fd: c_int) bool {
            while (self.len() != 0) {
                const data = self.bytes.items[self.off..];
                const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
                    c.send(fd, data.ptr, data.len, c.MSG_NOSIGNAL)
                else
                    c.write(fd, data.ptr, data.len);
                if (n > 0) {
                    self.off += @intCast(n);
                    continue;
                }
                if (n == 0) return false;
                const e = std.posix.errno(n);
                if (e == .INTR) continue;
                if (e == .AGAIN) return true;
                return false;
            }
            self.bytes.clearRetainingCapacity();
            self.off = 0;
            return true;
        }
    };

    /// Relay bytes both ways until either side dies or `stop` wakes us.
    fn pump(self: *Bridge, chan: u32) void {
        const wakeup = self.wakeup orelse return;
        var local_out = Pending{};
        defer local_out.bytes.deinit(self.allocator);
        while (true) {
            if (local_out.len() == 0 and !self.drainConnFrames(chan, &local_out)) return;
            var fds: [3]c.struct_pollfd = .{
                .{
                    .fd = self.conn.fd,
                    .events = @intCast((if (local_out.len() == 0) c.POLLIN else 0) |
                        (if (self.conn.wbuf.items.len != 0) c.POLLOUT else 0)),
                    .revents = 0,
                },
                .{
                    .fd = self.fd,
                    .events = @intCast((if (self.conn.wbuf.items.len == 0) c.POLLIN else 0) |
                        (if (local_out.len() != 0) c.POLLOUT else 0)),
                    .revents = 0,
                },
                .{ .fd = wakeup.read_fd, .events = c.POLLIN, .revents = 0 },
            };
            const polled = c.poll(&fds, fds.len, -1);
            if (polled < 0) {
                if (std.posix.errno(polled) == .INTR) continue;
                return;
            }
            if (fds[2].revents != 0) return;
            if (fds[0].revents & c.POLLOUT != 0)
                self.conn.flushQueued() catch return;
            if (fds[1].revents & c.POLLOUT != 0 and !local_out.flush(self.fd)) return;
            if (fds[1].revents & (c.POLLIN | c.POLLHUP) != 0 and self.conn.wbuf.items.len == 0)
                if (!self.pumpLocal(chan)) return;
            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0 and local_out.len() == 0)
                if (!self.pumpConn(chan, &local_out)) return;
            if (fds[0].revents & (c.POLLERR | c.POLLNVAL) != 0 or
                fds[1].revents & (c.POLLERR | c.POLLNVAL) != 0) return;
        }
    }

    fn pumpLocal(self: *Bridge, chan: u32) bool {
        var buf: [32 * 1024]u8 = undefined;
        while (true) {
            const n = c.read(self.fd, &buf, buf.len);
            if (n > 0) return self.sendChanData(chan, buf[0..@intCast(n)]);
            if (n == 0) return false;
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .AGAIN) return true;
            return false;
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
            self.conn.queueFrame(.chan_data, msg[0 .. 4 + take]) catch return false;
            off += take;
        }
        return true;
    }

    fn pumpConn(self: *Bridge, chan: u32, local_out: *Pending) bool {
        const connected = self.conn.fillAvailable();
        if (!self.drainConnFrames(chan, local_out)) return false;
        return connected;
    }

    fn drainConnFrames(self: *Bridge, chan: u32, local_out: *Pending) bool {
        while (local_out.len() == 0) {
            const f = (self.conn.takeFrame() catch return false) orelse break;
            defer f.deinit(self.allocator);
            switch (f.ftype) {
                .chan_data => {
                    const id = wire.decodeChanId(f.payload) orelse continue;
                    if (id != chan) continue;
                    local_out.append(self.allocator, f.payload[4..]) catch {
                        self.failWith("The local browser helper stopped accepting forwarded data.");
                        return false;
                    };
                    if (!local_out.flush(self.fd)) return false;
                },
                .chan_close => {
                    const id = wire.decodeChanId(f.payload) orelse continue;
                    if (id == chan) {
                        self.failWith("The remote browser helper exited.");
                        return false;
                    }
                },
                .gone => return false,
                else => {},
            }
        }
        return true;
    }
};

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

fn setNonBlockingFd(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) != 0)
        return error.NonBlockingFailed;
}

fn testWakeupFailure() !platform.Wakeup {
    return error.TestWakeupFailure;
}

const TestBridge = struct {
    bridge: ?*Bridge,
    gui_fd: c_int,
    mux_peer: c_int,

    fn init() !TestBridge {
        const t = std.testing;
        const bridge = Bridge.create(t.allocator, "test") orelse return error.TestUnexpectedResult;
        errdefer bridge.stop();
        const gui_fd = bridge.guiFd();
        errdefer _ = c.close(gui_fd);
        var mux_pair: [2]c_int = undefined;
        try t.expectEqual(@as(c_int, 0), platform.socketpairCloexec(&mux_pair));
        var conn_transferred = false;
        errdefer {
            if (!conn_transferred) _ = c.close(mux_pair[0]);
            _ = c.close(mux_pair[1]);
        }
        bridge.conn = .{
            .allocator = t.allocator,
            .fd = mux_pair[0],
            .proto = wire.PROTO_VERSION,
        };
        bridge.conn_ok = true;
        conn_transferred = true;
        try bridge.conn.setNonBlockingChecked();
        if (!try bridge.cancel.publish(bridge.conn.fd)) return error.TestUnexpectedResult;
        return .{ .bridge = bridge, .gui_fd = gui_fd, .mux_peer = mux_pair[1] };
    }

    fn start(self: *TestBridge) !void {
        const bridge = self.bridge orelse return error.TestUnexpectedResult;
        bridge.thread = try std.Thread.spawn(.{}, Bridge.pump, .{ bridge, @as(u32, 7) });
    }

    fn stop(self: *TestBridge) void {
        const bridge = self.bridge orelse return;
        self.bridge = null;
        bridge.stop();
        _ = c.close(self.gui_fd);
        _ = c.close(self.mux_peer);
        self.gui_fd = -1;
        self.mux_peer = -1;
    }
};

fn testStartAndStop(test_bridge: *TestBridge) !void {
    try test_bridge.start();
    _ = c.usleep(20_000);
    const start = nowMs();
    test_bridge.stop();
    try std.testing.expect(nowMs() - start < 1_000);
}

fn testFillSocket(fd: c_int) !void {
    const t = std.testing;
    const bytes = [_]u8{0xa5} ** (16 * 1024);
    var total: usize = 0;
    while (true) {
        const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
            c.send(fd, &bytes, bytes.len, c.MSG_NOSIGNAL)
        else
            c.write(fd, &bytes, bytes.len);
        if (n > 0) {
            total += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0 and std.posix.errno(n) == .AGAIN) break;
        return error.TestUnexpectedResult;
    }
    try t.expect(total != 0);
}

test "remote bridge setup fails when its required wakeup cannot be created" {
    try std.testing.expect(Bridge.createUsing(std.testing.allocator, "test", testWakeupFailure) == null);
}

test "remote bridge stop wakes an idle poll" {
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    try testStartAndStop(&test_bridge);
}

test "remote bridge stop interrupts a partial mux header" {
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    const bridge = test_bridge.bridge.?;
    try bridge.conn.rbuf.appendSlice(std.testing.allocator, &.{ 5, 0 });
    try testStartAndStop(&test_bridge);
}

test "remote bridge stop interrupts mux-send backpressure" {
    const t = std.testing;
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    const bridge = test_bridge.bridge.?;
    const tiny: c_int = 1024;
    try t.expectEqual(@as(c_int, 0), c.setsockopt(bridge.conn.fd, c.SOL_SOCKET, c.SO_SNDBUF, &tiny, @sizeOf(c_int)));
    const payload = [_]u8{0x5a} ** (32 * 1024);
    var attempts: usize = 0;
    while (bridge.conn.wbuf.items.len == 0 and attempts < 128) : (attempts += 1)
        try bridge.conn.queueFrame(.chan_data, &payload);
    try t.expect(bridge.conn.wbuf.items.len != 0);
    try testStartAndStop(&test_bridge);
}

test "remote bridge stop interrupts helper-write backpressure" {
    const t = std.testing;
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    const bridge = test_bridge.bridge.?;
    const tiny: c_int = 1024;
    try t.expectEqual(@as(c_int, 0), c.setsockopt(bridge.fd, c.SOL_SOCKET, c.SO_SNDBUF, &tiny, @sizeOf(c_int)));
    try testFillSocket(bridge.fd);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(t.allocator);
    var header: [4]u8 = undefined;
    try payload.appendSlice(t.allocator, wire.putChanHeader(&header, 7));
    try payload.appendNTimes(t.allocator, 0x3c, 512 * 1024);
    try wire.appendFrame(&bridge.conn.rbuf, t.allocator, .chan_data, payload.items);
    try testStartAndStop(&test_bridge);
}

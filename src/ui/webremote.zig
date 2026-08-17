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
//! `mux/client.Conn` driven through the shared channel pump.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const wire = @import("../mux/wire.zig");
const mux_client = @import("../mux/client.zig");
const channel_pump = @import("../mux/channel_pump.zig");
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
    /// The bridge-owned end of the socketpair and its bounded output queue.
    local: channel_pump.Local = .{},
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
        self.local.open(pair[1], MAX_LOCAL_OUT) catch {
            wakeup.close();
            _ = c.close(pair[0]);
            _ = c.close(pair[1]);
            allocator.destroy(self);
            return null;
        };
        self.gui_fd = pair[0];
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
        self.local.shutdown();
        if (self.thread) |t| t.join();
        self.thread = null;
        self.local.deinit(self.allocator);
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
        self.recordReason(reason);
        self.local.shutdown();
    }

    fn recordReason(self: *Bridge, reason: []const u8) void {
        const n = @min(reason.len, self.reason.len);
        @memcpy(self.reason[0..n], reason[0..n]);
        self.reason_len.store(n, .release);
    }

    fn worker(self: *Bridge) void {
        const h = self.host[0..self.host_len];
        const conn = mux_cli.muxConnect(self.allocator, if (h.len == 0) null else h) orelse {
            self.failWith("Could not reach the sketerm-mux daemon on that host.");
            return;
        };
        self.conn = conn;
        self.conn_ok = true;
        var pump = channel_pump.Pump.init(self.allocator, &self.conn);
        pump.prepare() catch {
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
        self.relay(chan);
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
        const deadline = channel_pump.nowMs() + REPLY_TIMEOUT_MS;
        var pump = channel_pump.Pump.init(self.allocator, &self.conn);
        while (true) {
            switch (self.drainOpenFrames()) {
                .opened => |chan| return chan,
                .failed => return null,
                .pending => {},
            }
            if (deadline - channel_pump.nowMs() <= 0) {
                self.failWith("The remote daemon did not answer the browser-helper request in time.");
                return null;
            }
            var fds: [2]c.struct_pollfd = .{
                .{
                    .fd = self.conn.fd,
                    .events = pump.muxEvents(true),
                    .revents = 0,
                },
                .{ .fd = wakeup.read_fd, .events = c.POLLIN, .revents = 0 },
            };
            switch (channel_pump.wait(&fds, 1, deadline)) {
                .ready => {},
                .cancelled => return null,
                .timeout => {
                    self.failWith("The remote daemon did not answer the browser-helper request in time.");
                    return null;
                },
                .failed => {
                    self.failWith("Lost the connection to the remote daemon while opening the browser helper.");
                    return null;
                },
            }
            if (fds[0].revents & c.POLLOUT != 0) {
                if (!pump.flushMux()) {
                    self.failWith("Could not ask the remote daemon for a browser helper.");
                    return null;
                }
            }
            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
                switch (self.receiveOpenFrames()) {
                    .opened => |chan| return chan,
                    .failed => return null,
                    .pending => {},
                }
            }
            if (channel_pump.badPoll(fds[0].revents)) {
                self.failWith("Lost the connection to the remote daemon while opening the browser helper.");
                return null;
            }
        }
    }

    fn drainOpenFrames(self: *Bridge) OpenState {
        return self.processOpenFrames(false);
    }

    fn receiveOpenFrames(self: *Bridge) OpenState {
        return self.processOpenFrames(true);
    }

    fn processOpenFrames(self: *Bridge, receive: bool) OpenState {
        var state: OpenState = .pending;
        var context = OpenContext{ .bridge = self, .state = &state };
        var pump = channel_pump.Pump.init(self.allocator, &self.conn);
        const result = if (receive)
            pump.receive(&context, handleOpenFrame)
        else
            pump.drainBuffered(&context, handleOpenFrame);
        return switch (result) {
            .open, .stopped => state,
            .gone, .eof => blk: {
                self.failWith("Lost the connection to the remote daemon while opening the browser helper.");
                break :blk .failed;
            },
            .failed => blk: {
                self.failWith("The remote daemon answered the helper request with garbage.");
                break :blk .failed;
            },
        };
    }

    const OpenContext = struct {
        bridge: *Bridge,
        state: *OpenState,
    };

    fn handleOpenFrame(context: *OpenContext, ftype: wire.FrameType, payload: []const u8) bool {
        const self = context.bridge;
        const Reply = struct {
            req: u32 = 0,
            ok: bool = false,
            chan: u32 = 0,
            @"error": []const u8 = "",
        };
        switch (ftype) {
            .web_helper_reply => {
                var parsed = std.json.parseFromSlice(Reply, self.allocator, payload, .{
                    .ignore_unknown_fields = true,
                }) catch {
                    self.failWith("The remote daemon answered the helper request with garbage.");
                    context.state.* = .failed;
                    return false;
                };
                defer parsed.deinit();
                if (parsed.value.req != 1 or !parsed.value.ok or parsed.value.chan == 0) {
                    if (parsed.value.@"error".len != 0) {
                        var buf: [192]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "Remote browser helper failed: {s}", .{parsed.value.@"error"}) catch parsed.value.@"error";
                        self.failWith(msg);
                    } else self.failWith("The remote daemon could not start a browser helper.");
                    context.state.* = .failed;
                    return false;
                }
                context.state.* = .{ .opened = parsed.value.chan };
                return false;
            },
            .err => {
                self.failWith("The remote daemon refused the browser-helper request.");
                context.state.* = .failed;
                return false;
            },
            else => {},
        }
        return true;
    }

    /// Relay bytes both ways until either side dies or `stop` wakes us.
    fn relay(self: *Bridge, chan: u32) void {
        const wakeup = self.wakeup orelse return;
        self.local.chan = chan;
        var pump = channel_pump.Pump.init(self.allocator, &self.conn);
        while (true) {
            if (!self.handleDrainResult(pump.drainBuffered(self, Bridge.handlePumpFrame))) return;
            if (!self.local.active()) return;
            var fds: [3]c.struct_pollfd = .{
                .{
                    .fd = self.conn.fd,
                    .events = pump.muxEvents(self.local.pending() == 0 and !self.local.close_after_flush),
                    .revents = 0,
                },
                .{
                    .fd = self.local.fd,
                    .events = self.local.events(self.conn.wbuf.items.len == 0),
                    .revents = 0,
                },
                .{ .fd = wakeup.read_fd, .events = c.POLLIN, .revents = 0 },
            };
            if (channel_pump.wait(&fds, 2, null) != .ready) return;
            if (fds[0].revents & c.POLLOUT != 0)
                if (!pump.flushMux()) return;
            if (fds[1].revents & c.POLLOUT != 0 and
                !pump.flushLocalNotify(&self.local, self, Bridge.beforeLocalClose)) return;
            if (!self.local.active()) return;
            if (fds[1].revents & (c.POLLIN | c.POLLHUP) != 0 and self.conn.wbuf.items.len == 0)
                if (!self.pumpLocal(&pump)) return;
            if (fds[0].revents & (c.POLLIN | c.POLLHUP) != 0 and self.local.pending() == 0)
                if (!self.handleDrainResult(pump.receive(self, Bridge.handlePumpFrame))) return;
            if (channel_pump.badPoll(fds[1].revents)) {
                self.beforeLocalClose(&self.local, true);
                pump.closeLocal(&self.local, true);
                return;
            }
            if (channel_pump.badPoll(fds[0].revents)) return;
        }
    }

    fn pumpLocal(self: *Bridge, pump: *channel_pump.Pump) bool {
        var buf: [32 * 1024]u8 = undefined;
        return switch (channel_pump.readLocal(self.local.fd, &buf)) {
            .data => |data| blk: {
                pump.queueData(self.local.chan, data) catch break :blk false;
                break :blk true;
            },
            .would_block => true,
            .eof, .failed => blk: {
                self.beforeLocalClose(&self.local, true);
                pump.closeLocal(&self.local, true);
                break :blk false;
            },
        };
    }

    fn handlePumpFrame(self: *Bridge, ftype: wire.FrameType, payload: []const u8) bool {
        var pump = channel_pump.Pump.init(self.allocator, &self.conn);
        switch (ftype) {
            .chan_data => {
                const id = wire.decodeChanId(payload) orelse return true;
                if (id != self.local.chan) return true;
                _ = pump.queueLocalNotify(
                    &self.local,
                    payload[4..],
                    false,
                    false,
                    self,
                    Bridge.beforeLocalClose,
                ) catch {
                    self.recordReason("The local browser helper stopped accepting forwarded data.");
                    pump.closeLocal(&self.local, true);
                    return false;
                };
                return self.local.active();
            },
            .chan_close => {
                const id = wire.decodeChanId(payload) orelse return true;
                if (id == self.local.chan) {
                    self.recordReason("The remote browser helper exited.");
                    _ = pump.remoteClose(&self.local);
                }
            },
            .err => {
                self.failWith("The remote daemon reported an error while forwarding the browser helper.");
                return false;
            },
            else => {},
        }
        return true;
    }

    fn handleDrainResult(self: *Bridge, result: channel_pump.DrainResult) bool {
        return switch (result) {
            .open => true,
            .stopped, .failed => false,
            .gone, .eof => blk: {
                var pump = channel_pump.Pump.init(self.allocator, &self.conn);
                const wake_fd = if (self.wakeup) |wake| wake.read_fd else -1;
                const refs = [_]*channel_pump.Local{&self.local};
                self.recordReason("The connection to the remote browser helper was lost.");
                pump.finishAfterMuxClose(&refs, wake_fd, channel_pump.nowMs() + 15_000);
                break :blk false;
            },
        };
    }

    fn beforeLocalClose(self: *Bridge, _: *channel_pump.Local, _: bool) void {
        if (self.reason_len.load(.acquire) == 0)
            self.recordReason("The connection to the remote browser helper was lost.");
    }
};

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
        bridge.thread = try std.Thread.spawn(.{}, Bridge.relay, .{ bridge, @as(u32, 7) });
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
    const start = channel_pump.nowMs();
    test_bridge.stop();
    try std.testing.expect(channel_pump.nowMs() - start < 1_000);
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

fn testReadExact(fd: c_int, out: []u8) !void {
    const deadline = channel_pump.nowMs() + 2000;
    var off: usize = 0;
    while (off < out.len) {
        const left = deadline - channel_pump.nowMs();
        if (left <= 0) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const result = c.poll(&pfd, 1, @intCast(left));
        if (result < 0 and std.posix.errno(result) == .INTR) continue;
        if (result <= 0) return error.Timeout;
        const n = c.read(fd, out.ptr + off, out.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return error.UnexpectedEof;
    }
}

fn testExpectEof(fd: c_int) !void {
    const deadline = channel_pump.nowMs() + 2000;
    while (true) {
        const left = deadline - channel_pump.nowMs();
        if (left <= 0) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        const result = c.poll(&pfd, 1, @intCast(left));
        if (result < 0 and std.posix.errno(result) == .INTR) continue;
        if (result <= 0) return error.Timeout;
        var byte: u8 = undefined;
        const n = c.read(fd, &byte, 1);
        if (n == 0) return;
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return error.UnexpectedData;
    }
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
    try t.expectEqual(@as(c_int, 0), c.setsockopt(bridge.local.fd, c.SOL_SOCKET, c.SO_SNDBUF, &tiny, @sizeOf(c_int)));
    try testFillSocket(bridge.local.fd);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(t.allocator);
    var header: [4]u8 = undefined;
    try payload.appendSlice(t.allocator, wire.putChanHeader(&header, 7));
    try payload.appendNTimes(t.allocator, 0x3c, 512 * 1024);
    try wire.appendFrame(&bridge.conn.rbuf, t.allocator, .chan_data, payload.items);
    try testStartAndStop(&test_bridge);
}

test "remote bridge preserves multiple short-written frames before chan_close" {
    const t = std.testing;
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    const bridge = test_bridge.bridge.?;
    const tiny: c_int = 1024;
    try t.expectEqual(@as(c_int, 0), c.setsockopt(bridge.local.fd, c.SOL_SOCKET, c.SO_SNDBUF, &tiny, @sizeOf(c_int)));
    const first = try t.allocator.alloc(u8, 256 * 1024);
    defer t.allocator.free(first);
    const second = try t.allocator.alloc(u8, 256 * 1024);
    defer t.allocator.free(second);
    @memset(first, 0x31);
    @memset(second, 0x72);
    for ([_][]const u8{ first, second }) |body| {
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(t.allocator);
        var header: [4]u8 = undefined;
        try payload.appendSlice(t.allocator, wire.putChanHeader(&header, 7));
        try payload.appendSlice(t.allocator, body);
        try wire.appendFrame(&bridge.conn.rbuf, t.allocator, .chan_data, payload.items);
    }
    var close_header: [4]u8 = undefined;
    try wire.appendFrame(&bridge.conn.rbuf, t.allocator, .chan_close, wire.putChanHeader(&close_header, 7));
    try test_bridge.start();

    const got = try t.allocator.alloc(u8, first.len + second.len);
    defer t.allocator.free(got);
    try testReadExact(test_bridge.gui_fd, got);
    try t.expectEqualSlices(u8, first, got[0..first.len]);
    try t.expectEqualSlices(u8, second, got[first.len..]);
    try testExpectEof(test_bridge.gui_fd);
    try t.expectEqualStrings("The remote browser helper exited.", bridge.takeReason());
}

test "remote bridge local EOF queues chan_close" {
    const t = std.testing;
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    const bridge = test_bridge.bridge.?;
    var peer = mux_client.Conn{
        .allocator = t.allocator,
        .fd = test_bridge.mux_peer,
        .proto = wire.PROTO_VERSION,
    };
    test_bridge.mux_peer = -1;
    defer peer.deinit();
    _ = c.close(test_bridge.gui_fd);
    test_bridge.gui_fd = -1;
    try test_bridge.start();

    const frame = try peer.recvExpectFor(&.{.chan_close}, 1000);
    defer frame.deinit(t.allocator);
    try t.expectEqual(@as(?u32, 7), wire.decodeChanId(frame.payload));
    _ = bridge;
}

test "remote bridge daemon error closes the local endpoint" {
    const t = std.testing;
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    const bridge = test_bridge.bridge.?;
    try wire.appendFrame(&bridge.conn.rbuf, t.allocator, .err, "failure");
    try test_bridge.start();
    try testExpectEof(test_bridge.gui_fd);
    try t.expect(std.mem.indexOf(u8, bridge.takeReason(), "reported an error") != null);
}

test "remote bridge gone closes the local endpoint" {
    const t = std.testing;
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    const bridge = test_bridge.bridge.?;
    try wire.appendFrame(&bridge.conn.rbuf, t.allocator, .gone, "");
    try test_bridge.start();
    try testExpectEof(test_bridge.gui_fd);
}

test "remote bridge mux EOF closes the local endpoint" {
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    _ = c.shutdown(test_bridge.mux_peer, c.SHUT_RDWR);
    _ = c.close(test_bridge.mux_peer);
    test_bridge.mux_peer = -1;
    try test_bridge.start();
    try testExpectEof(test_bridge.gui_fd);
}

test "remote bridge queue limit closes the local endpoint" {
    const t = std.testing;
    var test_bridge = try TestBridge.init();
    defer test_bridge.stop();
    const bridge = test_bridge.bridge.?;
    bridge.local.chan = 7;
    const payload = try t.allocator.alloc(u8, 4 + MAX_LOCAL_OUT + 1);
    defer t.allocator.free(payload);
    @memset(payload, 0);
    std.mem.writeInt(u32, payload[0..4], 7, .little);
    const handled = bridge.handlePumpFrame(.chan_data, payload);
    if (handled) return error.QueueLimitWasAccepted;
    if (std.mem.indexOf(u8, bridge.takeReason(), "stopped accepting") == null)
        return error.QueueLimitReasonMissing;
}

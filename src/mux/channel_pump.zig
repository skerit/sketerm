//! Libc-only nonblocking local-fd <-> mux byte-channel pump primitives.

const std = @import("std");
const c = @import("../c.zig").c;
const client = @import("client.zig");
const wire = @import("wire.zig");

pub const DATA_CHUNK: usize = 32 * 1024;

pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// Make an inherited or accepted fd nonblocking and close-on-exec.
pub fn configureFd(fd: c_int) !void {
    const status = c.fcntl(fd, c.F_GETFL);
    if (status < 0 or c.fcntl(fd, c.F_SETFL, status | c.O_NONBLOCK) != 0)
        return error.NonBlockingFailed;
    const descriptor = c.fcntl(fd, c.F_GETFD);
    if (descriptor < 0 or c.fcntl(fd, c.F_SETFD, descriptor | c.FD_CLOEXEC) != 0)
        return error.CloexecFailed;
}

/// EINTR-safe nonblocking accept whose returned fd is fully configured.
pub fn accept(listener: c_int) !?c_int {
    while (true) {
        const fd = c.accept(listener, null, null);
        if (fd >= 0) {
            errdefer _ = c.close(fd);
            try configureFd(fd);
            return fd;
        }
        return switch (std.posix.errno(fd)) {
            .INTR => continue,
            .AGAIN => null,
            else => error.AcceptFailed,
        };
    }
}

pub fn badPoll(revents: c_short) bool {
    return revents & (c.POLLERR | c.POLLNVAL) != 0;
}

pub const PollResult = enum { ready, timeout, cancelled, failed };

const PollStep = enum { ready, timeout, interrupted, failed };

fn pollOnce(fds: []c.struct_pollfd, timeout_ms: c_int) PollStep {
    const result = c.poll(fds.ptr, @intCast(fds.len), timeout_ms);
    if (result > 0) return .ready;
    if (result == 0) return .timeout;
    return if (std.posix.errno(result) == .INTR) .interrupted else .failed;
}

/// Poll until readiness, cancellation, or one absolute monotonic deadline.
pub fn wait(
    fds: []c.struct_pollfd,
    cancel_index: ?usize,
    deadline_ms: ?i64,
) PollResult {
    return waitWith(fds, cancel_index, deadline_ms, nowMs, pollOnce);
}

fn waitWith(
    fds: []c.struct_pollfd,
    cancel_index: ?usize,
    deadline_ms: ?i64,
    now_fn: anytype,
    poll_fn: anytype,
) PollResult {
    while (true) {
        const timeout: c_int = if (deadline_ms) |deadline| blk: {
            const left = deadline - now_fn();
            if (left <= 0) return .timeout;
            break :blk @intCast(@min(left, std.math.maxInt(c_int)));
        } else -1;
        switch (poll_fn(fds, timeout)) {
            .interrupted => continue,
            .timeout => return .timeout,
            .failed => return .failed,
            .ready => {
                if (cancel_index) |index| {
                    if (index < fds.len and fds[index].revents != 0)
                        return .cancelled;
                }
                return .ready;
            },
        }
    }
}

const IoStep = union(enum) {
    bytes: usize,
    would_block,
    interrupted,
    eof,
    failed,
};

fn readOnce(fd: c_int, buf: []u8) IoStep {
    const n = c.read(fd, buf.ptr, buf.len);
    if (n > 0) return .{ .bytes = @intCast(n) };
    if (n == 0) return .eof;
    return switch (std.posix.errno(n)) {
        .INTR => .interrupted,
        .AGAIN => .would_block,
        else => .failed,
    };
}

fn writeOnce(fd: c_int, data: []const u8) IoStep {
    const n = if (comptime @hasDecl(c, "MSG_NOSIGNAL"))
        c.send(fd, data.ptr, data.len, c.MSG_NOSIGNAL)
    else
        c.write(fd, data.ptr, data.len);
    if (n > 0) return .{ .bytes = @intCast(n) };
    if (n == 0) return .eof;
    return switch (std.posix.errno(n)) {
        .INTR => .interrupted,
        .AGAIN => .would_block,
        else => .failed,
    };
}

pub const ReadResult = union(enum) {
    data: []u8,
    would_block,
    eof,
    failed,
};

pub fn readLocal(fd: c_int, buf: []u8) ReadResult {
    return readLocalWith(fd, buf, readOnce);
}

fn readLocalWith(fd: c_int, buf: []u8, read_fn: anytype) ReadResult {
    while (true) {
        switch (read_fn(fd, buf)) {
            .bytes => |n| return .{ .data = buf[0..n] },
            .interrupted => continue,
            .would_block => return .would_block,
            .eof => return .eof,
            .failed => return .failed,
        }
    }
}

pub const Local = struct {
    fd: c_int = -1,
    chan: u32 = 0,
    out: std.ArrayList(u8) = .empty,
    out_off: usize = 0,
    out_limit: usize = 0,
    close_after_flush: bool = false,
    notify_on_close: bool = false,
    remote_closed: bool = false,

    pub fn open(self: *Local, fd: c_int, out_limit: usize) !void {
        if (self.fd >= 0 or self.out.items.len != 0) return error.AlreadyOpen;
        try configureFd(fd);
        self.fd = fd;
        self.out_limit = out_limit;
    }

    pub fn active(self: *const Local) bool {
        return self.fd >= 0;
    }

    pub fn pending(self: *const Local) usize {
        return self.out.items.len - self.out_off;
    }

    pub fn events(self: *const Local, allow_read: bool) c_short {
        var mask: c_short = if (allow_read and !self.close_after_flush) c.POLLIN else 0;
        if (self.pending() != 0) mask |= c.POLLOUT;
        return mask;
    }

    /// Append one complete payload or leave the logical queue unchanged.
    pub fn enqueue(self: *Local, allocator: std.mem.Allocator, data: []const u8) !void {
        if (self.close_after_flush) return error.EndpointClosing;
        if (self.out_off != 0) {
            const remain = self.pending();
            std.mem.copyForwards(u8, self.out.items[0..remain], self.out.items[self.out_off..]);
            self.out.shrinkRetainingCapacity(remain);
            self.out_off = 0;
        }
        if (self.out.items.len > self.out_limit or data.len > self.out_limit - self.out.items.len)
            return error.QueueLimit;
        try self.out.appendSlice(allocator, data);
    }

    pub fn closeAfterFlush(self: *Local, notify_remote: bool) void {
        self.close_after_flush = true;
        self.notify_on_close = self.notify_on_close or notify_remote;
    }

    pub fn shutdown(self: *Local) void {
        if (self.fd >= 0) _ = c.shutdown(self.fd, c.SHUT_RDWR);
    }

    pub fn deinit(self: *Local, allocator: std.mem.Allocator) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.out.deinit(allocator);
        self.* = .{};
    }
};

const FlushResult = enum { idle, blocked, finished, failed };

fn flushLocalWith(local: *Local, write_fn: anytype) FlushResult {
    while (local.pending() != 0) {
        switch (write_fn(local.fd, local.out.items[local.out_off..])) {
            .bytes => |n| local.out_off += n,
            .interrupted => continue,
            .would_block => return .blocked,
            .eof, .failed => return .failed,
        }
    }
    local.out.clearRetainingCapacity();
    local.out_off = 0;
    return if (local.close_after_flush) .finished else .idle;
}

pub const DrainResult = enum { open, eof, gone, stopped, failed };

pub const Pump = struct {
    allocator: std.mem.Allocator,
    conn: *client.Conn,

    pub fn init(allocator: std.mem.Allocator, conn: *client.Conn) Pump {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn prepare(self: *Pump) !void {
        try configureFd(self.conn.fd);
    }

    pub fn muxEvents(self: *const Pump, allow_read: bool) c_short {
        return @intCast((if (allow_read) c.POLLIN else 0) |
            (if (self.conn.wbuf.items.len != 0) c.POLLOUT else 0));
    }

    pub fn flushMux(self: *Pump) bool {
        self.conn.flushQueued() catch return false;
        return true;
    }

    /// Drain every complete frame already buffered without touching the fd.
    pub fn drainBuffered(self: *Pump, context: anytype, handle_frame: anytype) DrainResult {
        while (true) {
            const frame = (self.conn.takeFrame() catch return .failed) orelse return .open;
            defer frame.deinit(self.allocator);
            if (frame.ftype == .gone) return .gone;
            if (!handle_frame(context, frame.ftype, frame.payload)) return .stopped;
        }
    }

    /// Read available mux bytes and deliver every complete frame before EOF.
    pub fn receive(self: *Pump, context: anytype, handle_frame: anytype) DrainResult {
        const connected = self.conn.fillAvailable();
        const drained = self.drainBuffered(context, handle_frame);
        if (drained != .open) return drained;
        return if (connected) .open else .eof;
    }

    pub fn queueData(self: *Pump, chan: u32, data: []const u8) !void {
        var message: [4 + DATA_CHUNK]u8 = undefined;
        std.mem.writeInt(u32, message[0..4], chan, .little);
        var off: usize = 0;
        while (off < data.len) {
            const take = @min(data.len - off, DATA_CHUNK);
            @memcpy(message[4 .. 4 + take], data[off .. off + take]);
            try self.conn.queueFrame(.chan_data, message[0 .. 4 + take]);
            off += take;
        }
    }

    pub fn queueClose(self: *Pump, chan: u32) !void {
        var header: [4]u8 = undefined;
        try self.conn.queueFrame(.chan_close, wire.putChanHeader(&header, chan));
    }

    /// Close a local endpoint, notifying the mux peer first when appropriate.
    pub fn closeLocal(self: *Pump, local: *Local, notify_remote: bool) void {
        if (!local.active()) return;
        if (notify_remote and local.chan != 0 and !local.remote_closed)
            self.queueClose(local.chan) catch {};
        local.deinit(self.allocator);
    }

    /// Flush queued local output; fatal writes close and notify the channel.
    pub fn flushLocal(self: *Pump, local: *Local) bool {
        return self.flushLocalNotify(local, {}, struct {
            fn before(_: void, _: *Local, _: bool) void {}
        }.before);
    }

    /// Flush local output after invoking a hook immediately before any close.
    pub fn flushLocalNotify(self: *Pump, local: *Local, context: anytype, before_close: anytype) bool {
        return switch (flushLocalWith(local, writeOnce)) {
            .idle, .blocked => true,
            .finished => blk: {
                const notify = local.notify_on_close;
                before_close(context, local, notify);
                self.closeLocal(local, notify);
                break :blk false;
            },
            .failed => blk: {
                before_close(context, local, true);
                self.closeLocal(local, true);
                break :blk false;
            },
        };
    }

    /// Queue local-bound bytes and make one immediate nonblocking flush attempt.
    pub fn queueLocal(
        self: *Pump,
        local: *Local,
        data: []const u8,
        close_after: bool,
        notify_remote: bool,
    ) !bool {
        try local.enqueue(self.allocator, data);
        if (close_after) local.closeAfterFlush(notify_remote);
        return self.flushLocal(local);
    }

    /// Queue local-bound bytes with a pre-close hook for write failures.
    pub fn queueLocalNotify(
        self: *Pump,
        local: *Local,
        data: []const u8,
        close_after: bool,
        notify_remote: bool,
        context: anytype,
        before_close: anytype,
    ) !bool {
        try local.enqueue(self.allocator, data);
        if (close_after) local.closeAfterFlush(notify_remote);
        return self.flushLocalNotify(local, context, before_close);
    }

    /// A remote close is ordered after all accepted local-bound bytes.
    pub fn remoteClose(self: *Pump, local: *Local) bool {
        local.remote_closed = true;
        local.closeAfterFlush(false);
        return self.flushLocal(local);
    }

    /// Drain accepted local-bound bytes after mux loss, bounded by cancellation and a deadline.
    pub fn finishAfterMuxClose(
        self: *Pump,
        locals: []const *Local,
        cancel_fd: c_int,
        deadline_ms: i64,
    ) void {
        var active: usize = 0;
        for (locals) |local| {
            if (!local.active()) continue;
            if (self.remoteClose(local)) active += 1;
        }
        if (active == 0) return;

        const extra: usize = if (cancel_fd >= 0) 1 else 0;
        const fds = self.allocator.alloc(c.struct_pollfd, locals.len + extra) catch {
            for (locals) |local| self.closeLocal(local, false);
            return;
        };
        defer self.allocator.free(fds);
        while (active != 0) {
            for (locals, 0..) |local, index| {
                fds[index] = .{
                    .fd = if (local.active()) local.fd else -1,
                    .events = if (local.active()) c.POLLOUT else 0,
                    .revents = 0,
                };
            }
            const cancel_index: ?usize = if (cancel_fd >= 0) locals.len else null;
            if (cancel_index) |index|
                fds[index] = .{ .fd = cancel_fd, .events = c.POLLIN, .revents = 0 };
            if (wait(fds, cancel_index, deadline_ms) != .ready) break;

            active = 0;
            for (locals, 0..) |local, index| {
                if (!local.active()) continue;
                const revents = fds[index].revents;
                if (revents & c.POLLOUT != 0) _ = self.flushLocal(local);
                if (local.active() and (badPoll(revents) or revents & c.POLLHUP != 0))
                    self.closeLocal(local, false);
                if (local.active()) active += 1;
            }
        }
        for (locals) |local| self.closeLocal(local, false);
    }
};

test "channel pump retries EINTR for local reads and writes" {
    const ReadMock = struct {
        var calls: usize = 0;
        fn call(_: c_int, buf: []u8) IoStep {
            calls += 1;
            if (calls == 1) return .interrupted;
            buf[0] = 0x5a;
            return .{ .bytes = 1 };
        }
    };
    ReadMock.calls = 0;
    var byte: [1]u8 = undefined;
    const read = readLocalWith(1, &byte, ReadMock.call);
    try std.testing.expectEqual(@as(usize, 2), ReadMock.calls);
    try std.testing.expectEqualSlices(u8, &.{0x5a}, read.data);

    const WriteMock = struct {
        var calls: usize = 0;
        fn call(_: c_int, data: []const u8) IoStep {
            calls += 1;
            return switch (calls) {
                1 => .interrupted,
                2 => .{ .bytes = @min(data.len, 2) },
                else => .{ .bytes = data.len },
            };
        }
    };
    WriteMock.calls = 0;
    var local = Local{ .fd = 1, .out_limit = 16 };
    defer {
        local.fd = -1;
        local.out.deinit(std.testing.allocator);
    }
    try local.enqueue(std.testing.allocator, "short");
    try std.testing.expectEqual(FlushResult.idle, flushLocalWith(&local, WriteMock.call));
    try std.testing.expectEqual(@as(usize, 3), WriteMock.calls);
    try std.testing.expectEqual(@as(usize, 0), local.pending());
}

test "channel pump retries an interrupted poll" {
    const Clock = struct {
        fn now() i64 {
            return 100;
        }
    };
    const PollMock = struct {
        var calls: usize = 0;
        fn call(_: []c.struct_pollfd, _: c_int) PollStep {
            calls += 1;
            return if (calls == 1) .interrupted else .ready;
        }
    };
    PollMock.calls = 0;
    var fds = [_]c.struct_pollfd{.{ .fd = -1, .events = 0, .revents = 0 }};
    try std.testing.expectEqual(PollResult.ready, waitWith(&fds, null, 200, Clock.now, PollMock.call));
    try std.testing.expectEqual(@as(usize, 2), PollMock.calls);
    try std.testing.expectEqual(PollResult.timeout, wait(&fds, null, nowMs()));
}

test "channel pump queue limit is atomic" {
    var local = Local{ .fd = 1, .out_limit = 4 };
    defer {
        local.fd = -1;
        local.out.deinit(std.testing.allocator);
    }
    try local.enqueue(std.testing.allocator, "abcd");
    try std.testing.expectError(error.QueueLimit, local.enqueue(std.testing.allocator, "e"));
    try std.testing.expectEqualStrings("abcd", local.out.items);
}

test "channel pump drains multiple frames before reporting mux EOF and gone" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&pair));
    var conn = client.Conn{ .allocator = t.allocator, .fd = pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();
    var pump = Pump.init(t.allocator, &conn);
    try pump.prepare();

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(t.allocator);
    try wire.appendFrame(&bytes, t.allocator, .chan_data, "first");
    try wire.appendFrame(&bytes, t.allocator, .chan_close, "next");
    var off: usize = 0;
    while (off < bytes.items.len) {
        const n = c.write(pair[1], bytes.items.ptr + off, bytes.items.len - off);
        try t.expect(n > 0);
        off += @intCast(n);
    }
    _ = c.shutdown(pair[1], c.SHUT_WR);
    _ = c.close(pair[1]);

    const Seen = struct {
        count: usize = 0,
        fn frame(self: *@This(), _: wire.FrameType, _: []const u8) bool {
            self.count += 1;
            return true;
        }
    };
    var seen = Seen{};
    try t.expectEqual(DrainResult.open, pump.receive(&seen, Seen.frame));
    try t.expectEqual(@as(usize, 2), seen.count);
    try t.expectEqual(DrainResult.eof, pump.receive(&seen, Seen.frame));

    try wire.appendFrame(&conn.rbuf, t.allocator, .gone, "");
    try t.expectEqual(DrainResult.gone, pump.drainBuffered(&seen, Seen.frame));
    try t.expectEqual(@as(usize, 2), seen.count);
}

test "channel pump local EOF and POLLNVAL are explicit" {
    const t = std.testing;
    var pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&pair));
    try configureFd(pair[0]);
    try t.expect(c.fcntl(pair[0], c.F_GETFL) & c.O_NONBLOCK != 0);
    try t.expect(c.fcntl(pair[0], c.F_GETFD) & c.FD_CLOEXEC != 0);
    _ = c.close(pair[1]);
    var buf: [8]u8 = undefined;
    try t.expect(readLocal(pair[0], &buf) == .eof);
    _ = c.close(pair[0]);
    var fds = [_]c.struct_pollfd{.{ .fd = pair[0], .events = c.POLLIN, .revents = 0 }};
    try t.expectEqual(PollResult.ready, wait(&fds, null, nowMs() + 1000));
    try t.expect(badPoll(fds[0].revents));
}

test "channel pump cancellation wakes a blocked poll" {
    const wake = try @import("../util/platform.zig").Wakeup.init();
    defer wake.close();
    wake.signal();
    var fds = [_]c.struct_pollfd{.{ .fd = wake.read_fd, .events = c.POLLIN, .revents = 0 }};
    try std.testing.expectEqual(PollResult.cancelled, wait(&fds, 0, nowMs() + 1000));
}

test "channel pump remote close flushes bytes without echoing chan_close" {
    const t = std.testing;
    var mux_pair: [2]c_int = undefined;
    var local_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&mux_pair));
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&local_pair));
    defer _ = c.close(mux_pair[1]);
    defer _ = c.close(local_pair[1]);
    var conn = client.Conn{ .allocator = t.allocator, .fd = mux_pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();
    var pump = Pump.init(t.allocator, &conn);
    try pump.prepare();
    var local = Local{};
    try local.open(local_pair[0], 64);
    local.chan = 7;
    try t.expect(try pump.queueLocal(&local, "ordered", false, false));
    try t.expect(!pump.remoteClose(&local));
    try t.expect(!local.active());
    var got: [7]u8 = undefined;
    try t.expectEqual(@as(isize, got.len), c.read(local_pair[1], &got, got.len));
    try t.expectEqualStrings("ordered", &got);
    var pfd = c.struct_pollfd{ .fd = mux_pair[1], .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 20));
}

test "channel pump local close queues chan_close before releasing the fd" {
    const t = std.testing;
    var mux_pair: [2]c_int = undefined;
    var local_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&mux_pair));
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&local_pair));
    defer _ = c.close(local_pair[1]);
    var conn = client.Conn{ .allocator = t.allocator, .fd = mux_pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();
    var peer = client.Conn{ .allocator = t.allocator, .fd = mux_pair[1], .proto = wire.PROTO_VERSION };
    defer peer.deinit();
    var pump = Pump.init(t.allocator, &conn);
    try pump.prepare();
    var local = Local{};
    try local.open(local_pair[0], 64);
    local.chan = 19;

    pump.closeLocal(&local, true);
    try t.expect(!local.active());
    const frame = try peer.recvExpectFor(&.{.chan_close}, 1000);
    defer frame.deinit(t.allocator);
    try t.expectEqual(@as(?u32, 19), wire.decodeChanId(frame.payload));
}

test "channel pump drains short-written local output after mux EOF" {
    const t = std.testing;
    var mux_pair: [2]c_int = undefined;
    var local_pair: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&mux_pair));
    try t.expectEqual(@as(c_int, 0), @import("../util/platform.zig").socketpairCloexec(&local_pair));
    defer _ = c.close(mux_pair[1]);
    defer _ = c.close(local_pair[1]);
    const tiny: c_int = 1024;
    try t.expectEqual(@as(c_int, 0), c.setsockopt(local_pair[0], c.SOL_SOCKET, c.SO_SNDBUF, &tiny, @sizeOf(c_int)));
    var conn = client.Conn{ .allocator = t.allocator, .fd = mux_pair[0], .proto = wire.PROTO_VERSION };
    defer conn.deinit();
    var pump = Pump.init(t.allocator, &conn);
    var local = Local{};
    try local.open(local_pair[0], 512 * 1024);
    local.chan = 27;
    const body = try t.allocator.alloc(u8, 256 * 1024);
    defer t.allocator.free(body);
    for (body, 0..) |*byte, index| byte.* = @truncate(index *% 97 +% 13);
    try local.enqueue(t.allocator, body);

    const Context = struct {
        pump: *Pump,
        local: *Local,
        fn run(self: *@This()) void {
            const refs = [_]*Local{self.local};
            self.pump.finishAfterMuxClose(&refs, -1, nowMs() + 2000);
        }
    };
    var context = Context{ .pump = &pump, .local = &local };
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    var received: std.ArrayList(u8) = .empty;
    defer received.deinit(t.allocator);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(local_pair[1], &buf, buf.len);
        if (n > 0) {
            try received.appendSlice(t.allocator, buf[0..@intCast(n)]);
            continue;
        }
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        try t.expectEqual(@as(isize, 0), n);
        break;
    }
    thread.join();
    try t.expect(!local.active());
    try t.expectEqualSlices(u8, body, received.items);
}

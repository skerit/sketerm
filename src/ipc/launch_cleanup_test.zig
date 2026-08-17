//! Socketpair fake-daemon support for post-spawn transaction tests.

const std = @import("std");
const c = @import("../c.zig").c;
const launch_cleanup = @import("launch_cleanup.zig");
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const snapshot = @import("../mux/snapshot.zig");
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

pub const ORIGIN_ID = "10000000000000000000000000000001";
pub const REPLACEMENT_ID = "20000000000000000000000000000002";
pub const SPAWN_REPLY =
    "{\"ok\":true,\"origin_id\":\"" ++ ORIGIN_ID ++
    "\",\"pid\":321,\"output_width\":800,\"output_height\":600}";

pub const Harness = struct {
    allocator: std.mem.Allocator,
    primary_fd: c_int,
    primary_peer: muxclient.Conn,
    fresh_fd: c_int,
    fresh_peer: muxclient.Conn,
    reconnect_calls: usize = 0,
    reconnect_fails: bool = false,
    session_alive: bool = true,
    replacement_alive: bool = true,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        var primary: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &primary));
        errdefer {
            _ = c.close(primary[0]);
            _ = c.close(primary[1]);
        }
        var fresh: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fresh));
        return .{
            .allocator = allocator,
            .primary_fd = primary[0],
            .primary_peer = conn(allocator, primary[1]),
            .fresh_fd = fresh[0],
            .fresh_peer = conn(allocator, fresh[1]),
        };
    }

    pub fn deinit(self: *Harness) void {
        if (self.primary_fd >= 0) _ = c.close(self.primary_fd);
        if (self.fresh_fd >= 0) _ = c.close(self.fresh_fd);
        self.primary_peer.deinit();
        self.fresh_peer.deinit();
    }

    pub fn takePrimary(self: *Harness, allocator: std.mem.Allocator) muxclient.Conn {
        const fd = self.primary_fd;
        self.primary_fd = -1;
        return conn(allocator, fd);
    }

    pub fn localEndpoint(self: *Harness) launch_cleanup.Endpoint {
        return .{
            .target = .{ .local = "/fake/mux.sock" },
            .reconnect = .{ .ctx = self, .connect = reconnect },
        };
    }

    pub fn remoteEndpoint(self: *Harness) launch_cleanup.Endpoint {
        return .{
            .target = .{ .remote = "fake-host" },
            .reconnect = .{ .ctx = self, .connect = reconnect },
        };
    }

    pub fn queueSnapshot(self: *Harness, payload: []const u8) !void {
        try self.primary_peer.sendFrame(.snapshot, payload);
    }

    pub fn queueEvents(self: *Harness, payload: []const u8) !void {
        try self.primary_peer.sendFrame(.events, payload);
    }

    pub fn queuePrimaryAck(self: *Harness) !void {
        try self.primary_peer.sendFrame(.ok, "{\"ok\":true}");
    }

    pub fn queueFreshAck(self: *Harness) !void {
        try self.fresh_peer.sendFrame(.ok, "{\"ok\":true}");
    }

    pub fn closePrimaryPeer(self: *Harness) void {
        self.primary_peer.deinit();
        self.primary_peer = conn(self.allocator, -1);
    }

    pub fn expectAttach(self: *Harness, name: []const u8, control: bool) !void {
        const frame = try self.primary_peer.recvExpectFor(&.{.attach}, 1_000);
        defer frame.deinit(self.allocator);
        var parsed = try std.json.parseFromSlice(wire.AttachReq, self.allocator, frame.payload, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(name, parsed.value.name);
        try std.testing.expectEqualStrings(ORIGIN_ID, parsed.value.origin_id);
        try std.testing.expectEqual(control, parsed.value.control);
    }

    pub fn expectPrimaryKill(self: *Harness, name: []const u8) !void {
        try expectKill(&self.primary_peer, self.allocator, name);
        self.session_alive = false;
    }

    pub fn expectFreshKill(self: *Harness, name: []const u8) !void {
        try expectKill(&self.fresh_peer, self.allocator, name);
        self.session_alive = false;
    }

    pub fn expectSessionGone(self: *const Harness) !void {
        try std.testing.expect(!self.session_alive);
        try std.testing.expect(self.replacement_alive);
    }

    pub fn expectPrimaryQuiet(self: *Harness) !void {
        var pfd = c.struct_pollfd{ .fd = self.primary_peer.fd, .events = c.POLLIN, .revents = 0 };
        try std.testing.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));
    }

    fn reconnect(ctx: *anyopaque, allocator: std.mem.Allocator) !muxclient.Conn {
        const self: *Harness = @ptrCast(@alignCast(ctx));
        self.reconnect_calls += 1;
        if (self.reconnect_fails) return error.ConnectFailed;
        if (self.fresh_fd < 0) return error.NoFreshConnection;
        const fd = self.fresh_fd;
        self.fresh_fd = -1;
        return conn(allocator, fd);
    }
};

fn conn(allocator: std.mem.Allocator, fd: c_int) muxclient.Conn {
    return .{
        .allocator = allocator,
        .fd = fd,
        .proto = wire.PROTO_VERSION,
        .server_proto = wire.PROTO_VERSION,
        .snapshot_version = snapshot.SNAPSHOT_VERSION,
        .kill_origin_fence = true,
    };
}

fn expectKill(peer: *muxclient.Conn, allocator: std.mem.Allocator, name: []const u8) !void {
    const frame = try peer.recvExpectFor(&.{.kill}, 1_000);
    defer frame.deinit(allocator);
    var parsed = try std.json.parseFromSlice(wire.KillReq, allocator, frame.payload, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(name, parsed.value.name);
    try std.testing.expectEqualStrings(ORIGIN_ID, parsed.value.origin_id);
    try std.testing.expect(!std.mem.eql(u8, parsed.value.origin_id, REPLACEMENT_ID));
}

pub fn snapshotPayload(allocator: std.mem.Allocator, app: bool) ![]u8 {
    var pool = try Pool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, 2, 2);
    defer screen.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var header: [9]u8 = undefined;
    std.mem.writeInt(u64, header[0..8], 7, .little);
    header[8] = @intFromBool(app);
    try out.appendSlice(allocator, &header);
    try snapshot.serializeVersion(screen, &out, allocator, snapshot.SNAPSHOT_VERSION);
    return out.toOwnedSlice(allocator);
}

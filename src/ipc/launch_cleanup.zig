//! Transaction guard for mux sessions spawned by headless clients.

const std = @import("std");
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");

pub const Reconnect = struct {
    ctx: *anyopaque,
    connect: *const fn (*anyopaque, std.mem.Allocator) anyerror!muxclient.Conn,
};

pub const Endpoint = struct {
    target: union(enum) {
        local: ?[]const u8,
        remote: []const u8,
    },
    /// Test seam for a fake daemon; production always uses `target`.
    reconnect: ?Reconnect = null,
};

pub const SpawnMeta = struct {
    origin_id: wire.SessionOriginId,
    pid: i32 = 0,
    output_width: u32 = 0,
    output_height: u32 = 0,
};

/// Parse the allocation-independent identity needed before any fallible construction.
pub fn parseSpawnMeta(payload: []const u8) !SpawnMeta {
    const Reply = struct {
        origin_id: []const u8 = "",
        pid: i32 = 0,
        output_width: u32 = 0,
        output_height: u32 = 0,
    };
    var storage: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var parsed = std.json.parseFromSlice(Reply, fixed.allocator(), payload, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedSpawnReply;
    defer parsed.deinit();
    if (!wire.validSessionOriginId(parsed.value.origin_id))
        return error.MalformedSpawnReply;
    var meta = SpawnMeta{
        .origin_id = undefined,
        .pid = parsed.value.pid,
        .output_width = parsed.value.output_width,
        .output_height = parsed.value.output_height,
    };
    @memcpy(&meta.origin_id, parsed.value.origin_id);
    return meta;
}

pub const Guard = struct {
    conn: *muxclient.Conn,
    name: []const u8,
    origin_id: wire.SessionOriginId,
    endpoint: Endpoint,
    timeout_ms: i64,
    armed: bool = true,

    pub fn init(
        conn: *muxclient.Conn,
        name: []const u8,
        origin_id: wire.SessionOriginId,
        endpoint: Endpoint,
        timeout_ms: i64,
    ) Guard {
        return .{
            .conn = conn,
            .name = name,
            .origin_id = origin_id,
            .endpoint = endpoint,
            .timeout_ms = @max(timeout_ms, 1),
        };
    }

    /// Transfer cleanup responsibility to the completed App or Term exactly once.
    pub fn disarm(self: *Guard) void {
        self.armed = false;
    }

    /// Roll back without surfacing cleanup failures over the original launch error.
    pub fn rollback(self: *Guard) void {
        if (!self.armed) return;
        self.armed = false;
        if (self.killOn(self.conn)) return;

        var fresh = self.connectFresh() catch return;
        defer fresh.deinit();
        fresh.setNonBlocking();
        _ = self.killOn(&fresh);
    }

    fn killOn(self: *const Guard, conn: *muxclient.Conn) bool {
        if (!conn.kill_origin_fence) return false;
        conn.write_timeout_ms = @intCast(@min(self.timeout_ms, std.math.maxInt(c_int)));
        conn.sendKill(.{
            .name = self.name,
            .origin_id = &self.origin_id,
        }) catch return false;
        const frame = conn.recvExpectFor(&.{ .ok, .gone }, self.timeout_ms) catch |err| {
            // An error reply means the exact lifetime is already gone or was
            // replaced. Retrying by name cannot improve that safe outcome.
            return err == error.DaemonError;
        };
        frame.deinit(conn.allocator);
        return true;
    }

    fn connectFresh(self: *const Guard) !muxclient.Conn {
        const allocator = std.heap.c_allocator;
        if (self.endpoint.reconnect) |custom|
            return custom.connect(custom.ctx, allocator);
        return switch (self.endpoint.target) {
            .local => |sock| muxclient.Conn.connectLocalAutostartAt(allocator, sock),
            .remote => |host| muxclient.Conn.connectSshOnce(allocator, host),
        };
    }
};

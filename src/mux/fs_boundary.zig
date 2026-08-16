//! Bounded ordering state between streamed file-service snapshots and live deltas.

const std = @import("std");

/// A deferred daemon burst is re-statted by name after the last active snapshot.
pub const Server = struct {
    pub const max_names: usize = 128;

    active: usize = 0,
    names: std.ArrayList([]u8) = .empty,
    resync: bool = false,
    gone: bool = false,

    pub fn begin(self: *Server) void {
        self.active += 1;
    }

    /// @return true when the last overlapping snapshot reached its final chunk.
    pub fn finish(self: *Server) bool {
        if (self.active == 0) return false;
        self.active -= 1;
        return self.active == 0;
    }

    pub fn deferName(self: *Server, allocator: std.mem.Allocator, name: []const u8) void {
        if (self.gone or self.resync) return;
        for (self.names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
        }
        if (self.names.items.len >= max_names) {
            self.markResync(allocator);
            return;
        }
        const owned = allocator.dupe(u8, name) catch {
            self.markResync(allocator);
            return;
        };
        self.names.append(allocator, owned) catch {
            allocator.free(owned);
            self.markResync(allocator);
        };
    }

    pub fn markResync(self: *Server, allocator: std.mem.Allocator) void {
        if (self.gone) return;
        self.clearNames(allocator);
        self.resync = true;
    }

    pub fn markGone(self: *Server, allocator: std.mem.Allocator) void {
        self.clearNames(allocator);
        self.resync = false;
        self.gone = true;
    }

    pub fn clear(self: *Server, allocator: std.mem.Allocator) void {
        self.clearNames(allocator);
        self.resync = false;
        self.gone = false;
    }

    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        self.clearNames(allocator);
        self.names.deinit(allocator);
    }

    fn clearNames(self: *Server, allocator: std.mem.Allocator) void {
        for (self.names.items) |name| allocator.free(name);
        self.names.clearRetainingCapacity();
    }
};

/// Client-side compatibility boundary for daemons that still emit deltas mid-snapshot.
pub const Client = struct {
    pub const max_payloads: usize = 512;
    pub const max_bytes: usize = 1 << 20;

    generation: u64 = 0,
    active: bool = false,
    payloads: std.ArrayList([]u8) = .empty,
    bytes: usize = 0,
    resync: bool = false,

    pub fn begin(self: *Client, allocator: std.mem.Allocator) u64 {
        if (!self.active) self.clear(allocator);
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.active = true;
        return self.generation;
    }

    pub fn isCurrent(self: *const Client, generation: u64) bool {
        return generation != 0 and generation == self.generation;
    }

    /// @return false when no snapshot is active and the delta should apply live.
    pub fn push(self: *Client, allocator: std.mem.Allocator, payload: []const u8) bool {
        if (!self.active) return false;
        if (self.resync) return true;
        if (payload.len > max_bytes -| self.bytes or self.payloads.items.len >= max_payloads) {
            self.markResync(allocator);
            return true;
        }
        const owned = allocator.dupe(u8, payload) catch {
            self.markResync(allocator);
            return true;
        };
        self.payloads.append(allocator, owned) catch {
            allocator.free(owned);
            self.markResync(allocator);
            return true;
        };
        self.bytes += owned.len;
        return true;
    }

    /// @return true only for the current generation's final snapshot chunk.
    pub fn finish(self: *Client, generation: u64) bool {
        if (!self.active or !self.isCurrent(generation)) return false;
        self.active = false;
        return true;
    }

    pub fn cancel(self: *Client, allocator: std.mem.Allocator, generation: u64) void {
        if (!self.active or !self.isCurrent(generation)) return;
        self.active = false;
        self.clear(allocator);
    }

    pub fn take(self: *Client) Deferred {
        const out = Deferred{ .payloads = self.payloads, .resync = self.resync };
        self.payloads = .empty;
        self.bytes = 0;
        self.resync = false;
        return out;
    }

    pub fn deinit(self: *Client, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.payloads.deinit(allocator);
    }

    fn markResync(self: *Client, allocator: std.mem.Allocator) void {
        self.clearPayloads(allocator);
        self.resync = true;
    }

    fn clear(self: *Client, allocator: std.mem.Allocator) void {
        self.clearPayloads(allocator);
        self.resync = false;
    }

    fn clearPayloads(self: *Client, allocator: std.mem.Allocator) void {
        for (self.payloads.items) |payload| allocator.free(payload);
        self.payloads.clearRetainingCapacity();
        self.bytes = 0;
    }
};

pub const Deferred = struct {
    payloads: std.ArrayList([]u8),
    resync: bool,

    pub fn deinit(self: *Deferred, allocator: std.mem.Allocator) void {
        for (self.payloads.items) |payload| allocator.free(payload);
        self.payloads.deinit(allocator);
    }
};

test "daemon boundary coalesces every mutation until overlapping snapshots finish" {
    const t = std.testing;
    var boundary: Server = .{};
    defer boundary.deinit(t.allocator);

    boundary.begin();
    boundary.deferName(t.allocator, "created");
    boundary.deferName(t.allocator, "modified");
    boundary.deferName(t.allocator, "modified");
    boundary.begin();
    boundary.deferName(t.allocator, "rename-old");
    boundary.deferName(t.allocator, "rename-new");
    boundary.deferName(t.allocator, "deleted");

    try t.expect(!boundary.finish());
    try t.expectEqual(@as(usize, 5), boundary.names.items.len);
    try t.expect(boundary.finish());
    try t.expectEqualStrings("created", boundary.names.items[0]);
    try t.expectEqualStrings("deleted", boundary.names.items[4]);
}

test "client boundary buffers all chunk interleavings and rejects stale generations" {
    const t = std.testing;
    var boundary: Client = .{};
    defer boundary.deinit(t.allocator);

    const first = boundary.begin(t.allocator);
    try t.expect(boundary.push(t.allocator, "create-before-first-chunk"));
    try t.expect(boundary.push(t.allocator, "modify-between-chunks"));
    const second = boundary.begin(t.allocator);
    try t.expect(boundary.push(t.allocator, "rename-old-before-final"));
    try t.expect(boundary.push(t.allocator, "rename-new-before-final"));
    try t.expect(!boundary.finish(first));
    try t.expect(boundary.push(t.allocator, "delete-after-stale-final"));
    try t.expect(boundary.finish(second));

    var deferred = boundary.take();
    defer deferred.deinit(t.allocator);
    try t.expect(!deferred.resync);
    try t.expectEqual(@as(usize, 5), deferred.payloads.items.len);
    try t.expectEqualStrings("create-before-first-chunk", deferred.payloads.items[0]);
    try t.expectEqualStrings("delete-after-stale-final", deferred.payloads.items[4]);
    try t.expect(!boundary.push(t.allocator, "live-after-final"));

    const third = boundary.begin(t.allocator);
    const fourth = boundary.begin(t.allocator);
    try t.expect(boundary.finish(fourth));
    try t.expect(!boundary.finish(third));
}

test "snapshot boundaries degrade to bounded resync state" {
    const t = std.testing;
    var server: Server = .{};
    defer server.deinit(t.allocator);
    server.begin();
    var name_buf: [32]u8 = undefined;
    for (0..Server.max_names + 1) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "entry-{d}", .{i});
        server.deferName(t.allocator, name);
    }
    try t.expect(server.resync);
    try t.expectEqual(@as(usize, 0), server.names.items.len);

    var client: Client = .{};
    defer client.deinit(t.allocator);
    _ = client.begin(t.allocator);
    const oversized = try t.allocator.alloc(u8, Client.max_bytes + 1);
    defer t.allocator.free(oversized);
    try t.expect(client.push(t.allocator, oversized));
    try t.expect(client.resync);
    try t.expectEqual(@as(usize, 0), client.payloads.items.len);
}

test "client boundary cancellation frees only the current generation" {
    const t = std.testing;
    var boundary: Client = .{};
    defer boundary.deinit(t.allocator);

    const first = boundary.begin(t.allocator);
    try t.expect(boundary.push(t.allocator, "before-overlap"));
    const second = boundary.begin(t.allocator);
    boundary.cancel(t.allocator, first);
    try t.expect(boundary.active);
    try t.expectEqual(@as(usize, 1), boundary.payloads.items.len);
    boundary.cancel(t.allocator, second);
    try t.expect(!boundary.active);
    try t.expectEqual(@as(usize, 0), boundary.payloads.items.len);
}

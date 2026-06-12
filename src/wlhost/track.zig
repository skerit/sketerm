//! Protocol-stream tracker for the daemon's Wayland endpoint.
//!
//! Pure state machine (no sockets, no mmap — the daemon owns those):
//! fed complete messages from the app↔GUI stream, it maintains the
//! object-id → interface map and reports the SEMANTIC action each
//! client message implies, so the daemon knows which messages carry
//! fds (shm pools) and when committed buffer bytes must be
//! replicated up to the GUI. Everything else relays verbatim.
//!
//! Scope mirrors protocol.zig: shm is the only fd-carrying client
//! request, no server-created objects exist, and object ids die on
//! the compositor's wl_display.delete_id (authoritative — destructor
//! requests alone don't free the id).

const std = @import("std");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");

pub const Error = error{
    UnknownObject,
    UnknownOpcode,
    UnknownInterface,
    IdInUse,
    OutOfMemory,
} || wire.Error;

/// What the daemon must do with one client→compositor message
/// (besides relaying it, which is implied for everything except
/// the fd: a relayed create_pool message has no fd equivalent on
/// the mux wire — the pool bytes travel side-band).
pub const Action = union(enum) {
    relay,
    /// wl_shm.create_pool — message carries one fd (SCM_RIGHTS,
    /// arrival order). Daemon mmaps it and starts mirroring.
    pool_create: struct { id: u32, size: i32 },
    pool_resize: struct { id: u32, size: i32 },
    /// Destructor request seen; the mapping may be dropped once
    /// no buffer references it (daemon's call).
    pool_destroy: struct { id: u32 },
    buffer_create: struct {
        id: u32,
        pool: u32,
        offset: i32,
        width: i32,
        height: i32,
        stride: i32,
        format: u32,
    },
    buffer_destroy: struct { id: u32 },
    /// wl_surface.commit with a live attached buffer: replicate
    /// that buffer's bytes before relaying the commit. Geometry is
    /// resolved from the tracked buffer so the daemon can copy
    /// [offset, offset + stride*height) without its own bookkeeping.
    /// `damage` is the row range the client declared dirty since
    /// its last commit (full height when it declared nothing —
    /// trust-but-clamp, like any compositor).
    commit: struct { surface: u32, buffer: u32, info: BufferInfo, damage: ?RowRange },
};

/// Damaged rows [y0, y1) in buffer coordinates. Width collapses to
/// full rows: rows are contiguous in the pool, so one linear copy
/// covers them; terminals scroll full-width anyway.
pub const RowRange = struct { y0: i32, y1: i32 };

pub const BufferInfo = struct {
    pool: u32,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,
};

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    objects: std.AutoHashMapUnmanaged(u32, *const protocol.Interface) = .empty,
    /// surface id → currently attached buffer id (wl_surface.attach
    /// is double-buffered state, but committed content persists:
    /// a commit without re-attach still implies a content update).
    attached: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// buffer id → geometry, dropped with the object on delete_id.
    buffers: std.AutoHashMapUnmanaged(u32, BufferInfo) = .empty,
    /// surface id → accumulated damage rows since the last commit.
    /// Absent = the client declared no damage (copy everything —
    /// the conservative reading for clients that skip damage).
    damage: std.AutoHashMapUnmanaged(u32, RowRange) = .empty,
    /// Surfaces that have committed at least once WITH damage info;
    /// only these get partial copies (a client that never damages
    /// always full-copies).
    uses_damage: std.AutoHashMapUnmanaged(u32, void) = .empty,

    pub fn init(allocator: std.mem.Allocator) Error!Tracker {
        var self = Tracker{ .allocator = allocator };
        try self.objects.put(allocator, 1, &protocol.wl_display);
        return self;
    }

    pub fn deinit(self: *Tracker) void {
        self.objects.deinit(self.allocator);
        self.attached.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.damage.deinit(self.allocator);
        self.uses_damage.deinit(self.allocator);
    }

    /// One complete client→compositor message (header + body).
    /// Returns the daemon's required action; errors are protocol
    /// violations (kill the app connection).
    pub fn clientMessage(self: *Tracker, hdr: wire.Header, body: []const u8) Error!Action {
        const iface = self.objects.get(hdr.object) orelse return Error.UnknownObject;
        if (hdr.opcode >= iface.requests.len) return Error.UnknownOpcode;
        const msg = &iface.requests[hdr.opcode];

        // Register objects created by this message. wl_registry.bind
        // names its interface inline; everything else has a static
        // new-id interface in the tables.
        var new_id: u32 = 0;
        if (protocol.newIdArg(msg) != null) {
            var bind_iface: ?*const protocol.Interface = msg.new_id_iface;
            var it = wire.ArgIter.init(body, msg.sig);
            while (try it.next()) |arg| switch (arg) {
                .string => |s| {
                    if (iface == &protocol.wl_registry) {
                        const name = s orelse return Error.UnknownInterface;
                        bind_iface = protocol.find(name) orelse return Error.UnknownInterface;
                    }
                },
                .new_id => |id| new_id = id,
                else => {},
            };
            if (new_id == 0) return Error.Malformed;
            const target = bind_iface orelse return Error.UnknownInterface;
            const slot = try self.objects.getOrPut(self.allocator, new_id);
            if (slot.found_existing) return Error.IdInUse;
            slot.value_ptr.* = target;
        }

        if (iface == &protocol.wl_shm and hdr.opcode == 0) { // create_pool
            var it = wire.ArgIter.init(body, msg.sig);
            _ = try it.next(); // n
            _ = try it.next(); // h (no bytes)
            const size = (try it.next()).?.int;
            return .{ .pool_create = .{ .id = new_id, .size = size } };
        }
        if (iface == &protocol.wl_shm_pool) switch (hdr.opcode) {
            0 => { // create_buffer
                var it = wire.ArgIter.init(body, msg.sig);
                _ = try it.next(); // n
                const offset = (try it.next()).?.int;
                const width = (try it.next()).?.int;
                const height = (try it.next()).?.int;
                const stride = (try it.next()).?.int;
                const format = (try it.next()).?.uint;
                try self.buffers.put(self.allocator, new_id, .{
                    .pool = hdr.object,
                    .offset = offset,
                    .width = width,
                    .height = height,
                    .stride = stride,
                    .format = format,
                });
                return .{ .buffer_create = .{
                    .id = new_id,
                    .pool = hdr.object,
                    .offset = offset,
                    .width = width,
                    .height = height,
                    .stride = stride,
                    .format = format,
                } };
            },
            1 => return .{ .pool_destroy = .{ .id = hdr.object } },
            2 => {
                var it = wire.ArgIter.init(body, msg.sig);
                return .{ .pool_resize = .{
                    .id = hdr.object,
                    .size = (try it.next()).?.int,
                } };
            },
            else => unreachable,
        };
        if (iface == &protocol.wl_buffer and hdr.opcode == 0)
            return .{ .buffer_destroy = .{ .id = hdr.object } };
        if (iface == &protocol.wl_surface) switch (hdr.opcode) {
            1 => { // attach
                var it = wire.ArgIter.init(body, msg.sig);
                const buffer = (try it.next()).?.object;
                if (buffer == 0) {
                    _ = self.attached.remove(hdr.object);
                } else {
                    try self.attached.put(self.allocator, hdr.object, buffer);
                }
                return .relay;
            },
            2, 9 => { // damage / damage_buffer (scale 1: same space)
                var it = wire.ArgIter.init(body, msg.sig);
                _ = try it.next(); // x
                const y = (try it.next()).?.int;
                _ = try it.next(); // width
                const h = (try it.next()).?.int;
                if (h > 0) try self.addDamage(hdr.object, y, y +| h);
                return .relay;
            },
            6 => { // commit
                const buffer = self.attached.get(hdr.object) orelse {
                    _ = self.damage.remove(hdr.object);
                    return .relay;
                };
                // Attach named a buffer we never saw created (or one
                // already destroyed): relay, nothing to replicate.
                const info = self.buffers.get(buffer) orelse return .relay;
                // Damage-using clients: absent damage on a commit
                // means "content unchanged" → copy nothing (empty
                // range), not everything.
                const dmg: ?RowRange = if (self.uses_damage.contains(hdr.object))
                    (self.damage.get(hdr.object) orelse RowRange{ .y0 = 0, .y1 = 0 })
                else
                    null;
                _ = self.damage.remove(hdr.object);
                return .{ .commit = .{
                    .surface = hdr.object,
                    .buffer = buffer,
                    .info = info,
                    .damage = dmg,
                } };
            },
            else => return .relay,
        };
        return .relay;
    }

    fn addDamage(self: *Tracker, sid: u32, y0: i32, y1: i32) Error!void {
        try self.uses_damage.put(self.allocator, sid, {});
        const slot = try self.damage.getOrPut(self.allocator, sid);
        if (slot.found_existing) {
            slot.value_ptr.y0 = @min(slot.value_ptr.y0, y0);
            slot.value_ptr.y1 = @max(slot.value_ptr.y1, y1);
        } else {
            slot.value_ptr.* = .{ .y0 = y0, .y1 = y1 };
        }
    }

    /// One complete compositor→client message. Only
    /// wl_display.delete_id mutates tracker state.
    pub fn serverMessage(self: *Tracker, hdr: wire.Header, body: []const u8) Error!void {
        if (hdr.object != 1 or hdr.opcode != 1) return; // not delete_id
        var it = wire.ArgIter.init(body, "u");
        const id = (try it.next()).?.uint;
        _ = self.objects.remove(id);
        _ = self.attached.remove(id);
        _ = self.buffers.remove(id);
        _ = self.damage.remove(id);
        _ = self.uses_damage.remove(id);
    }
};

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

fn enc(buf: []u8, object: u32, opcode: u16, args: anytype) struct { hdr: wire.Header, body: []const u8 } {
    var b = wire.Builder.init(buf, object, opcode);
    inline for (args) |arg| {
        switch (@typeInfo(@TypeOf(arg))) {
            .comptime_int, .int => if (arg < 0) b.putInt(arg) else b.putUint(@intCast(arg)),
            .pointer => b.putString(arg),
            else => @compileError("unsupported test arg"),
        }
    }
    const m = b.finish() catch unreachable;
    const hdr = (wire.parseHeader(m) catch unreachable).?;
    return .{ .hdr = hdr, .body = m[wire.header_size..] };
}

fn bindShm(tr: *Tracker, registry: u32, shm_id: u32) !void {
    var buf: [64]u8 = undefined;
    // get_registry on display first if registry not yet known
    if (tr.objects.get(registry) == null) {
        const gr = enc(&buf, 1, 1, .{registry});
        try t.expectEqual(Action.relay, try tr.clientMessage(gr.hdr, gr.body));
    }
    const bind = enc(&buf, registry, 0, .{ 3, @as([]const u8, "wl_shm"), 1, shm_id });
    try t.expectEqual(Action.relay, try tr.clientMessage(bind.hdr, bind.body));
}

test "registry bind registers typed objects" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    try bindShm(&tr, 2, 3);
    try t.expectEqual(&protocol.wl_shm, tr.objects.get(3).?);
}

test "shm pool and buffer lifecycle" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    try bindShm(&tr, 2, 3);

    var buf: [64]u8 = undefined;
    // wl_shm.create_pool(id=4, fd, size=4096)
    const cp = enc(&buf, 3, 0, .{ 4, 4096 });
    const a1 = try tr.clientMessage(cp.hdr, cp.body);
    try t.expectEqual(@as(u32, 4), a1.pool_create.id);
    try t.expectEqual(@as(i32, 4096), a1.pool_create.size);

    // wl_shm_pool.create_buffer(id=5, offset=0, 32x32, stride=128, format=1)
    const cb = enc(&buf, 4, 0, .{ 5, 0, 32, 32, 128, 1 });
    const a2 = try tr.clientMessage(cb.hdr, cb.body);
    try t.expectEqual(@as(u32, 5), a2.buffer_create.id);
    try t.expectEqual(@as(u32, 4), a2.buffer_create.pool);
    try t.expectEqual(@as(i32, 128), a2.buffer_create.stride);

    // resize then destroy
    const rs = enc(&buf, 4, 2, .{8192});
    try t.expectEqual(@as(i32, 8192), (try tr.clientMessage(rs.hdr, rs.body)).pool_resize.size);
    const pd = enc(&buf, 4, 1, .{});
    try t.expectEqual(@as(u32, 4), (try tr.clientMessage(pd.hdr, pd.body)).pool_destroy.id);
    const bd = enc(&buf, 5, 0, .{});
    try t.expectEqual(@as(u32, 5), (try tr.clientMessage(bd.hdr, bd.body)).buffer_destroy.id);
}

test "attach + commit reports replication, null attach clears" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    var buf: [64]u8 = undefined;

    // bind compositor (id 3), create surface (id 4)
    const gr = enc(&buf, 1, 1, .{2});
    _ = try tr.clientMessage(gr.hdr, gr.body);
    const bind = enc(&buf, 2, 0, .{ 1, @as([]const u8, "wl_compositor"), 6, 3 });
    _ = try tr.clientMessage(bind.hdr, bind.body);
    const cs = enc(&buf, 3, 0, .{4});
    _ = try tr.clientMessage(cs.hdr, cs.body);

    // commit with nothing attached → plain relay
    const c0 = enc(&buf, 4, 6, .{});
    try t.expectEqual(Action.relay, try tr.clientMessage(c0.hdr, c0.body));

    // shm pool (id 8) + buffer (id 9) so commit can resolve geometry
    try bindShm(&tr, 2, 7);
    const cp = enc(&buf, 7, 0, .{ 8, 4096 });
    _ = try tr.clientMessage(cp.hdr, cp.body);
    const cb = enc(&buf, 8, 0, .{ 9, 0, 32, 32, 128, 1 });
    _ = try tr.clientMessage(cb.hdr, cb.body);

    // attach buffer 9, commit → replication with geometry
    const at = enc(&buf, 4, 1, .{ 9, 0, 0 });
    try t.expectEqual(Action.relay, try tr.clientMessage(at.hdr, at.body));
    const c1 = enc(&buf, 4, 6, .{});
    const a = try tr.clientMessage(c1.hdr, c1.body);
    try t.expectEqual(@as(u32, 4), a.commit.surface);
    try t.expectEqual(@as(u32, 9), a.commit.buffer);
    try t.expectEqual(@as(u32, 8), a.commit.info.pool);
    try t.expectEqual(@as(i32, 128), a.commit.info.stride);

    // commit again without re-attach: content may have changed in place
    const c2 = enc(&buf, 4, 6, .{});
    try t.expectEqual(@as(u32, 9), (try tr.clientMessage(c2.hdr, c2.body)).commit.buffer);

    // attaching an unknown buffer id relays instead of committing
    const at_unk = enc(&buf, 4, 1, .{ 99, 0, 0 });
    _ = try tr.clientMessage(at_unk.hdr, at_unk.body);
    const c_unk = enc(&buf, 4, 6, .{});
    try t.expectEqual(Action.relay, try tr.clientMessage(c_unk.hdr, c_unk.body));

    // null attach clears
    const an = enc(&buf, 4, 1, .{ 0, 0, 0 });
    _ = try tr.clientMessage(an.hdr, an.body);
    const c3 = enc(&buf, 4, 6, .{});
    try t.expectEqual(Action.relay, try tr.clientMessage(c3.hdr, c3.body));
}

test "damage rows: accumulate, reset on commit, trust-but-clamp semantics" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    var buf: [64]u8 = undefined;

    // compositor(3) → surface(4); shm(7) → pool(8) → buffer(9)
    const gr = enc(&buf, 1, 1, .{2});
    _ = try tr.clientMessage(gr.hdr, gr.body);
    const bindc = enc(&buf, 2, 0, .{ 1, @as([]const u8, "wl_compositor"), 6, 3 });
    _ = try tr.clientMessage(bindc.hdr, bindc.body);
    const cs = enc(&buf, 3, 0, .{4});
    _ = try tr.clientMessage(cs.hdr, cs.body);
    try bindShm(&tr, 2, 7);
    const cp = enc(&buf, 7, 0, .{ 8, 4096 });
    _ = try tr.clientMessage(cp.hdr, cp.body);
    const cb = enc(&buf, 8, 0, .{ 9, 0, 32, 32, 128, 1 });
    _ = try tr.clientMessage(cb.hdr, cb.body);
    const at = enc(&buf, 4, 1, .{ 9, 0, 0 });
    _ = try tr.clientMessage(at.hdr, at.body);

    // First commit, no damage ever declared → null (full copy).
    const c1 = enc(&buf, 4, 6, .{});
    try t.expectEqual(@as(?RowRange, null), (try tr.clientMessage(c1.hdr, c1.body)).commit.damage);

    // Two damage rects accumulate to one row bbox.
    const d1 = enc(&buf, 4, 2, .{ 0, 4, 32, 4 }); // rows 4..8
    _ = try tr.clientMessage(d1.hdr, d1.body);
    const d2 = enc(&buf, 4, 9, .{ 0, 20, 32, 2 }); // damage_buffer rows 20..22
    _ = try tr.clientMessage(d2.hdr, d2.body);
    const c2 = enc(&buf, 4, 6, .{});
    const dmg = (try tr.clientMessage(c2.hdr, c2.body)).commit.damage.?;
    try t.expectEqual(@as(i32, 4), dmg.y0);
    try t.expectEqual(@as(i32, 22), dmg.y1);

    // Damage-using surface, commit with none declared → empty range.
    const c3 = enc(&buf, 4, 6, .{});
    const dmg3 = (try tr.clientMessage(c3.hdr, c3.body)).commit.damage.?;
    try t.expectEqual(@as(i32, 0), dmg3.y1 - dmg3.y0);
}

test "protocol violations are errors" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    var buf: [64]u8 = undefined;

    const unk = enc(&buf, 99, 0, .{});
    try t.expectError(Error.UnknownObject, tr.clientMessage(unk.hdr, unk.body));

    const bad_op = enc(&buf, 1, 7, .{});
    try t.expectError(Error.UnknownOpcode, tr.clientMessage(bad_op.hdr, bad_op.body));

    const gr = enc(&buf, 1, 1, .{2});
    _ = try tr.clientMessage(gr.hdr, gr.body);
    const bad_bind = enc(&buf, 2, 0, .{ 1, @as([]const u8, "wl_nonsense"), 1, 3 });
    try t.expectError(Error.UnknownInterface, tr.clientMessage(bad_bind.hdr, bad_bind.body));

    const dup = enc(&buf, 1, 1, .{2}); // id 2 again
    try t.expectError(Error.IdInUse, tr.clientMessage(dup.hdr, dup.body));
}

test "server delete_id frees the object" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    var buf: [64]u8 = undefined;

    const gr = enc(&buf, 1, 1, .{2});
    _ = try tr.clientMessage(gr.hdr, gr.body);
    try t.expect(tr.objects.get(2) != null);

    const del = enc(&buf, 1, 1, .{2}); // same shape as delete_id(2)
    try tr.serverMessage(del.hdr, del.body);
    try t.expectEqual(@as(?*const protocol.Interface, null), tr.objects.get(2));

    // and the id is reusable afterwards
    const gr2 = enc(&buf, 1, 1, .{2});
    try t.expectEqual(Action.relay, try tr.clientMessage(gr2.hdr, gr2.body));
}

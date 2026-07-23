//! Protocol-stream tracker for the daemon's Wayland endpoint.
//!
//! Pure state machine (no sockets, no mmap — the daemon owns those):
//! fed complete messages from the app↔GUI stream, it maintains the
//! object-id → interface map and reports the SEMANTIC action each
//! client message implies, so the daemon knows which messages carry
//! fds (shm pools) and when committed buffer bytes must be
//! replicated up to the GUI. Everything else relays verbatim.
//!
//! Scope mirrors protocol.zig: fd-carrying client requests are shm
//! create_pool, dmabuf params.add and the paste receives; no
//! server-created objects exist, and object ids die on the
//! compositor's wl_display.delete_id (authoritative — destructor
//! requests alone don't free the id).

const std = @import("std");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");
const dmabuf = @import("dmabuf.zig");

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
    /// `serial` identifies this pool INCARNATION: wl object ids are
    /// recycled after delete_id, but buffers keep the old storage
    /// alive past the pool object — refcounting by id alone crosses
    /// incarnations (the GTK4/Vulkan probe-pool bug).
    pool_create: struct { id: u32, size: i32, serial: u64 },
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
    /// wl_surface destructor — per-surface daemon state (video
    /// encoders) can be dropped.
    surface_destroy: struct { id: u32 },
    /// wl_data_offer.receive — the app wants to paste: the message
    /// carries one fd the daemon must hold until the GUI ships the
    /// clipboard bytes (clip_data unit, FIFO-paired).
    clip_receive: struct { offer: u32 },
    /// zwp_primary_selection_offer_v1.receive — same fd-holding
    /// dance, but paired with primary_data units (separate FIFO).
    primary_receive: struct { offer: u32 },
    /// zwp_linux_buffer_params_v1.add — the message carries one plane
    /// fd. The daemon must pop it in SCM_RIGHTS arrival order. `ok` is
    /// retained for the legacy single-fd consumer; full importers use
    /// the plane index and metadata.
    dmabuf_add: struct {
        params: u32,
        plane: u32,
        offset: u32,
        stride: u32,
        modifier: u64,
        ok: bool,
    },
    /// create_immed after complete metadata validation. `info`
    /// describes the exported resource; commits use a separate tight
    /// synthetic pool layout so replica updates have no source padding.
    dmabuf_create: struct {
        id: u32,
        params: u32,
        info: dmabuf.BufferInfo,
        // Legacy daemon fields kept until its importer consumes `info`.
        offset: u32,
        stride: u32,
        width: i32,
        height: i32,
    },
    /// Non-immed create — declined (the brain answers `failed`, the
    /// client falls back to shm); the daemon drops the pending fd.
    dmabuf_create_failed: struct { params: u32 },
    /// Params object destroyed — drop a still-pending fd, if any.
    params_destroy: struct { id: u32 },
    /// wl_surface.commit with a live attached buffer: replicate
    /// that buffer's bytes before relaying the commit. Geometry is
    /// resolved from the tracked buffer so the daemon can copy
    /// [offset, offset + stride*height) without its own bookkeeping.
    /// `damage` is the row range the client declared dirty since
    /// its last commit (full height when it declared nothing —
    /// trust-but-clamp, like any compositor).
    commit: struct {
        surface: u32,
        buffer: u32,
        info: BufferInfo,
        damage: ?RowRange,
        /// True only when this commit consumes a new attach request.
        attached_now: bool,
    },
};

/// Damaged rows [y0, y1) in buffer coordinates. Width collapses to
/// full rows: rows are contiguous in the pool, so one linear copy
/// covers them; terminals scroll full-width anyway.
pub const RowRange = struct {
    y0: i32,
    y1: i32,

    /// Bounding union of two optional ranges, where null means "full
    /// buffer" (the conservative no-damage reading) and thus wins.
    pub fn mergeOpt(a: ?RowRange, b: ?RowRange) ?RowRange {
        const ra = a orelse return null;
        const rb = b orelse return null;
        return .{ .y0 = @min(ra.y0, rb.y0), .y1 = @max(ra.y1, rb.y1) };
    }
};

pub const BufferInfo = struct {
    pool: u32,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,
    /// True for a dmabuf-backed buffer: pixels live in the daemon's
    /// DmabufMirror (keyed by buffer id; `pool` is the buffer id).
    dmabuf: bool = false,
    /// Incarnation serial of `pool` at create_buffer time (0 for
    /// dmabuf). Refcount/mirror operations must target this
    /// incarnation, not whatever currently owns the pool id.
    serial: u64 = 0,
};

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    objects: std.AutoHashMapUnmanaged(u32, *const protocol.Interface) = .empty,
    /// surface id → currently attached buffer id (wl_surface.attach
    /// is double-buffered state, but committed content persists:
    /// a commit without re-attach still implies a content update).
    attached: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Surfaces with an attach (including null) pending for the next commit.
    pending_attaches: std.AutoHashMapUnmanaged(u32, void) = .empty,
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
    /// surface id → set_buffer_scale (default 1). wl_surface.damage is
    /// in surface-local (logical) coords, so its rows are multiplied by
    /// this to index the physical buffer; damage_buffer is already
    /// physical. Without this HiDPI buffers copy only the top 1/scale.
    scales: std.AutoHashMapUnmanaged(u32, i32) = .empty,
    /// wp_viewport object id → surface id.
    viewports: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// surface id → viewport destination height (LOGICAL — the
    /// fractional-scale path). Logical damage rows are expanded by
    /// buffer_height/vp_h at commit time, when the ratio is known.
    vp_heights: std.AutoHashMapUnmanaged(u32, i32) = .empty,
    /// zwp_linux_buffer_params_v1 id → validated single-use metadata.
    dmabuf_params: std.AutoHashMapUnmanaged(u32, dmabuf.Params) = .empty,
    /// pool id → incarnation serial of the CURRENT pool under that id.
    pool_serials: std.AutoHashMapUnmanaged(u32, u64) = .empty,
    pool_serial_ctr: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Error!Tracker {
        var self = Tracker{ .allocator = allocator };
        try self.objects.put(allocator, 1, &protocol.wl_display);
        return self;
    }

    pub fn deinit(self: *Tracker) void {
        self.objects.deinit(self.allocator);
        self.attached.deinit(self.allocator);
        self.pending_attaches.deinit(self.allocator);
        self.buffers.deinit(self.allocator);
        self.damage.deinit(self.allocator);
        self.uses_damage.deinit(self.allocator);
        self.scales.deinit(self.allocator);
        self.viewports.deinit(self.allocator);
        self.vp_heights.deinit(self.allocator);
        self.dmabuf_params.deinit(self.allocator);
        self.pool_serials.deinit(self.allocator);
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
            self.pool_serial_ctr += 1;
            try self.pool_serials.put(self.allocator, new_id, self.pool_serial_ctr);
            return .{ .pool_create = .{ .id = new_id, .size = size, .serial = self.pool_serial_ctr } };
        }
        if (iface == &protocol.zwp_linux_dmabuf_v1 and hdr.opcode == 1) { // create_params
            try self.dmabuf_params.put(self.allocator, new_id, .{});
            return .relay;
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
                    .serial = self.pool_serials.get(hdr.object) orelse 0,
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
        if (iface == &protocol.zwp_linux_buffer_params_v1) switch (hdr.opcode) {
            0 => { // destroy
                _ = self.dmabuf_params.remove(hdr.object);
                return .{ .params_destroy = .{ .id = hdr.object } };
            },
            1 => { // add(fd, plane_idx, offset, stride, mod_hi, mod_lo)
                var it = wire.ArgIter.init(body, msg.sig);
                _ = try it.next(); // h (no bytes)
                const plane = (try it.next()).?.uint;
                const offset = (try it.next()).?.uint;
                const stride = (try it.next()).?.uint;
                const mod_hi = (try it.next()).?.uint;
                const mod_lo = (try it.next()).?.uint;
                const modifier = @as(u64, mod_hi) << 32 | mod_lo;
                const params = self.dmabuf_params.getPtr(hdr.object) orelse return Error.Malformed;
                params.add(plane, .{
                    .offset = offset,
                    .stride = stride,
                    .modifier = modifier,
                }) catch return Error.Malformed;
                return .{ .dmabuf_add = .{
                    .params = hdr.object,
                    .plane = plane,
                    .offset = offset,
                    .stride = stride,
                    .modifier = modifier,
                    .ok = plane == 0,
                } };
            },
            2 => { // create(width, height, format, flags)
                var it = wire.ArgIter.init(body, msg.sig);
                const width = (try it.next()).?.int;
                const height = (try it.next()).?.int;
                const format = (try it.next()).?.uint;
                const flags = (try it.next()).?.uint;
                const params = self.dmabuf_params.getPtr(hdr.object) orelse return Error.Malformed;
                _ = params.create(width, height, format, flags) catch return Error.Malformed;
                return .{ .dmabuf_create_failed = .{ .params = hdr.object } };
            },
            3 => { // create_immed(new_id, w, h, format, flags)
                var it = wire.ArgIter.init(body, msg.sig);
                _ = try it.next(); // n
                const width = (try it.next()).?.int;
                const height = (try it.next()).?.int;
                const format = (try it.next()).?.uint;
                const flags = (try it.next()).?.uint;
                const params = self.dmabuf_params.getPtr(hdr.object) orelse return Error.Malformed;
                const info = params.create(width, height, format, flags) catch return Error.Malformed;
                const shm_format = dmabuf.shmFormat(info.format) orelse return Error.Malformed;
                const tight_stride = std.math.mul(u32, info.width, 4) catch return Error.Malformed;
                if (tight_stride > std.math.maxInt(i32)) return Error.Malformed;
                try self.buffers.put(self.allocator, new_id, .{
                    .pool = new_id,
                    .offset = 0,
                    .width = width,
                    .height = height,
                    .stride = @intCast(tight_stride),
                    .format = shm_format,
                    .dmabuf = true,
                });
                return .{ .dmabuf_create = .{
                    .id = new_id,
                    .params = hdr.object,
                    .info = info,
                    .offset = info.plane.offset,
                    .stride = info.plane.stride,
                    .width = width,
                    .height = height,
                } };
            },
            else => unreachable,
        };
        if (iface == &protocol.wl_data_offer and hdr.opcode == 1)
            return .{ .clip_receive = .{ .offer = hdr.object } };
        // wlr-data-control offer.receive (opcode 0) carries the paste
        // fd just like wl_data_offer.receive.
        if (iface == &protocol.zwlr_data_control_offer_v1 and hdr.opcode == 0)
            return .{ .clip_receive = .{ .offer = hdr.object } };
        if (iface == &protocol.zwp_primary_selection_offer_v1 and hdr.opcode == 0)
            return .{ .primary_receive = .{ .offer = hdr.object } };
        if (iface == &protocol.wp_viewporter and hdr.opcode == 1) {
            // get_viewport(id, surface) — remember whose viewport.
            var it = wire.ArgIter.init(body, msg.sig);
            _ = try it.next(); // n
            const sid = (try it.next()).?.object;
            try self.viewports.put(self.allocator, new_id, sid);
            return .relay;
        }
        if (iface == &protocol.wp_viewport) switch (hdr.opcode) {
            0 => { // destroy — logical sizing reverts
                if (self.viewports.fetchRemove(hdr.object)) |kv| {
                    _ = self.vp_heights.remove(kv.value);
                }
                return .relay;
            },
            2 => { // set_destination(w, h) — logical size (-1 unsets)
                var it = wire.ArgIter.init(body, msg.sig);
                _ = try it.next(); // w
                const vh = (try it.next()).?.int;
                if (self.viewports.get(hdr.object)) |sid| {
                    if (vh > 0) {
                        try self.vp_heights.put(self.allocator, sid, vh);
                    } else {
                        _ = self.vp_heights.remove(sid);
                    }
                }
                return .relay;
            },
            else => return .relay,
        };
        if (iface == &protocol.wl_surface) switch (hdr.opcode) {
            0 => return .{ .surface_destroy = .{ .id = hdr.object } },
            1 => { // attach
                var it = wire.ArgIter.init(body, msg.sig);
                const buffer = (try it.next()).?.object;
                if (buffer == 0) {
                    _ = self.attached.remove(hdr.object);
                } else {
                    try self.attached.put(self.allocator, hdr.object, buffer);
                }
                try self.pending_attaches.put(self.allocator, hdr.object, {});
                return .relay;
            },
            2 => { // damage — surface-local (logical) coords
                var it = wire.ArgIter.init(body, msg.sig);
                _ = try it.next(); // x
                const y = (try it.next()).?.int;
                _ = try it.next(); // width
                const h = (try it.next()).?.int;
                // Scale logical rows to physical buffer rows.
                const sc: i32 = self.scales.get(hdr.object) orelse 1;
                if (h > 0) try self.addDamage(hdr.object, y *| sc, (y +| h) *| sc);
                return .relay;
            },
            8 => { // set_buffer_scale
                var it = wire.ArgIter.init(body, msg.sig);
                const sc = (try it.next()).?.int;
                try self.scales.put(self.allocator, hdr.object, if (sc > 0) sc else 1);
                return .relay;
            },
            9 => { // damage_buffer — already in physical buffer coords
                var it = wire.ArgIter.init(body, msg.sig);
                _ = try it.next(); // x
                const y = (try it.next()).?.int;
                _ = try it.next(); // width
                const h = (try it.next()).?.int;
                if (h > 0) try self.addDamage(hdr.object, y, y +| h);
                return .relay;
            },
            6 => { // commit
                const attached_now = self.pending_attaches.remove(hdr.object);
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
                var dmg: ?RowRange = if (self.uses_damage.contains(hdr.object))
                    (self.damage.get(hdr.object) orelse RowRange{ .y0 = 0, .y1 = 0 })
                else
                    null;
                // Fractional-scale surfaces (viewport destination set,
                // buffer_scale 1): logical damage rows under-cover the
                // physical buffer — expand by buffer_h/logical_h now
                // that both are known. Over-covers damage_buffer rows,
                // which only costs copy bytes, never correctness.
                if (dmg) |*d| {
                    if (self.vp_heights.get(hdr.object)) |vh| {
                        if (vh > 0 and info.height > vh) {
                            const bh: i64 = info.height;
                            const lh: i64 = vh;
                            d.y0 = @intCast(@max(0, @divTrunc(@as(i64, d.y0) * bh, lh)));
                            d.y1 = @intCast(@min(bh, @divTrunc(@as(i64, d.y1) * bh + lh - 1, lh)));
                        }
                    }
                }
                _ = self.damage.remove(hdr.object);
                return .{ .commit = .{
                    .surface = hdr.object,
                    .buffer = buffer,
                    .info = info,
                    .damage = dmg,
                    .attached_now = attached_now,
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

    /// One complete compositor→client message. Two cases mutate
    /// tracker state: wl_display.delete_id frees ids, and events
    /// that CREATE objects (wl_data_device.data_offer is the only
    /// one in scope) register them so the client's requests on the
    /// new id dispatch.
    pub fn serverMessage(self: *Tracker, hdr: wire.Header, body: []const u8) Error!void {
        if (hdr.object == 1 and hdr.opcode == 1) { // delete_id
            var it = wire.ArgIter.init(body, "u");
            const id = (try it.next()).?.uint;
            _ = self.objects.remove(id);
            _ = self.attached.remove(id);
            _ = self.pending_attaches.remove(id);
            _ = self.buffers.remove(id);
            _ = self.damage.remove(id);
            _ = self.uses_damage.remove(id);
            _ = self.scales.remove(id);
            _ = self.viewports.remove(id);
            _ = self.vp_heights.remove(id); // id may be a surface
            _ = self.dmabuf_params.remove(id);
            _ = self.pool_serials.remove(id);
            return;
        }
        const iface = self.objects.get(hdr.object) orelse return;
        if (hdr.opcode >= iface.events.len) return;
        const ev = &iface.events[hdr.opcode];
        const target = ev.new_id_iface orelse return;
        var it = wire.ArgIter.init(body, ev.sig);
        while (try it.next()) |arg| switch (arg) {
            .new_id => |id| {
                if (id != 0) try self.objects.put(self.allocator, id, target);
            },
            else => {},
        };
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

test "pool id recycling: buffer serials pin incarnations" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    try bindShm(&tr, 2, 3);
    var buf: [64]u8 = undefined;

    // Probe pool (id 4) + buffer 5, pool destroyed, id freed.
    const cp1 = enc(&buf, 3, 0, .{ 4, 256 });
    const a1 = try tr.clientMessage(cp1.hdr, cp1.body);
    const s1 = a1.pool_create.serial;
    const cb1 = enc(&buf, 4, 0, .{ 5, 0, 1, 1, 64, 0 });
    _ = try tr.clientMessage(cb1.hdr, cb1.body);
    try t.expectEqual(s1, tr.buffers.get(5).?.serial);
    const pd = enc(&buf, 4, 1, .{});
    _ = try tr.clientMessage(pd.hdr, pd.body);
    const del = enc(&buf, 1, 1, .{4});
    try tr.serverMessage(del.hdr, del.body);

    // Client recycles id 4 for a bigger pool (the GTK4/Vulkan
    // swapchain pattern) while buffer 5 still holds the old storage.
    const cp2 = enc(&buf, 3, 0, .{ 4, 4096 });
    const a2 = try tr.clientMessage(cp2.hdr, cp2.body);
    try t.expect(a2.pool_create.serial != s1);
    const cb2 = enc(&buf, 4, 0, .{ 6, 0, 32, 32, 128, 0 });
    _ = try tr.clientMessage(cb2.hdr, cb2.body);
    try t.expectEqual(a2.pool_create.serial, tr.buffers.get(6).?.serial);
    try t.expectEqual(s1, tr.buffers.get(5).?.serial);
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
    try t.expect(a.commit.attached_now);

    // commit again without re-attach: content may have changed in place
    const c2 = enc(&buf, 4, 6, .{});
    const a2 = (try tr.clientMessage(c2.hdr, c2.body)).commit;
    try t.expectEqual(@as(u32, 9), a2.buffer);
    try t.expect(!a2.attached_now);

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

    // Destroy before committing a fresh attach must not retain surface state.
    _ = try tr.clientMessage(at.hdr, at.body);
    try t.expect(tr.pending_attaches.contains(4));
    const destroy = enc(&buf, 4, 0, .{});
    _ = try tr.clientMessage(destroy.hdr, destroy.body);
    const deleted = enc(&buf, 1, 1, .{4});
    try tr.serverMessage(deleted.hdr, deleted.body);
    try t.expect(!tr.pending_attaches.contains(4));
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

test "HiDPI: wl_surface.damage scales by buffer scale, damage_buffer does not" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    var buf: [64]u8 = undefined;

    const gr = enc(&buf, 1, 1, .{2});
    _ = try tr.clientMessage(gr.hdr, gr.body);
    const bindc = enc(&buf, 2, 0, .{ 1, @as([]const u8, "wl_compositor"), 6, 3 });
    _ = try tr.clientMessage(bindc.hdr, bindc.body);
    const cs = enc(&buf, 3, 0, .{4});
    _ = try tr.clientMessage(cs.hdr, cs.body);
    try bindShm(&tr, 2, 7);
    const cp = enc(&buf, 7, 0, .{ 8, 1 << 20 });
    _ = try tr.clientMessage(cp.hdr, cp.body);
    const cb = enc(&buf, 8, 0, .{ 9, 0, 64, 128, 256, 1 });
    _ = try tr.clientMessage(cb.hdr, cb.body);
    const at = enc(&buf, 4, 1, .{ 9, 0, 0 });
    _ = try tr.clientMessage(at.hdr, at.body);

    // set_buffer_scale(2) → wl_surface.damage rows are logical, scale ×2.
    const sbs = enc(&buf, 4, 8, .{2});
    _ = try tr.clientMessage(sbs.hdr, sbs.body);
    const d1 = enc(&buf, 4, 2, .{ 0, 10, 32, 20 }); // logical rows 10..30 → physical 20..60
    _ = try tr.clientMessage(d1.hdr, d1.body);
    const c1 = enc(&buf, 4, 6, .{});
    const dmg = (try tr.clientMessage(c1.hdr, c1.body)).commit.damage.?;
    try t.expectEqual(@as(i32, 20), dmg.y0);
    try t.expectEqual(@as(i32, 60), dmg.y1);

    // damage_buffer is already physical — unscaled even at buffer scale 2.
    const d2 = enc(&buf, 4, 9, .{ 0, 100, 32, 8 }); // physical rows 100..108
    _ = try tr.clientMessage(d2.hdr, d2.body);
    const c2 = enc(&buf, 4, 6, .{});
    const dmg2 = (try tr.clientMessage(c2.hdr, c2.body)).commit.damage.?;
    try t.expectEqual(@as(i32, 100), dmg2.y0);
    try t.expectEqual(@as(i32, 108), dmg2.y1);
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

test "wlr-data-control: objects register, offer.receive yields clip_receive" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    var buf: [96]u8 = undefined;

    // get_registry(2), bind manager(name 12) → 3
    const gr = enc(&buf, 1, 1, .{2});
    _ = try tr.clientMessage(gr.hdr, gr.body);
    const bind = enc(&buf, 2, 0, .{ 12, @as([]const u8, "zwlr_data_control_manager_v1"), 1, 3 });
    try t.expectEqual(Action.relay, try tr.clientMessage(bind.hdr, bind.body));
    try t.expectEqual(&protocol.zwlr_data_control_manager_v1, tr.objects.get(3).?);

    // create_data_source(4) [op 0], get_data_device(5, seat 0) [op 1]
    const cds = enc(&buf, 3, 0, .{4});
    _ = try tr.clientMessage(cds.hdr, cds.body);
    try t.expectEqual(&protocol.zwlr_data_control_source_v1, tr.objects.get(4).?);
    const gdd = enc(&buf, 3, 1, .{ 5, 0 });
    _ = try tr.clientMessage(gdd.hdr, gdd.body);
    try t.expectEqual(&protocol.zwlr_data_control_device_v1, tr.objects.get(5).?);

    // Server emits device.data_offer(op 0) creating offer 0xff000000.
    const off = enc(&buf, 5, 0, .{0xff000000});
    try tr.serverMessage(off.hdr, off.body);
    try t.expectEqual(&protocol.zwlr_data_control_offer_v1, tr.objects.get(0xff000000).?);

    // offer.receive(op 0) carries the paste fd → daemon holds it.
    const rcv = enc(&buf, 0xff000000, 0, .{@as([]const u8, "text/plain;charset=utf-8")});
    const a = try tr.clientMessage(rcv.hdr, rcv.body);
    try t.expectEqual(@as(u32, 0xff000000), a.clip_receive.offer);
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

test "dmabuf: full metadata, tight commits, y-invert, and single-use params" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    var buf: [96]u8 = undefined;

    // registry(2), compositor(3), surface(4)
    const gr = enc(&buf, 1, 1, .{2});
    _ = try tr.clientMessage(gr.hdr, gr.body);
    const bindc = enc(&buf, 2, 0, .{ 1, @as([]const u8, "wl_compositor"), 6, 3 });
    _ = try tr.clientMessage(bindc.hdr, bindc.body);
    const cs = enc(&buf, 3, 0, .{4});
    _ = try tr.clientMessage(cs.hdr, cs.body);

    // bind dmabuf (id 5), create_params (id 6)
    const bindd = enc(&buf, 2, 0, .{ 22, @as([]const u8, "zwp_linux_dmabuf_v1"), 3, 5 });
    try t.expectEqual(Action.relay, try tr.clientMessage(bindd.hdr, bindd.body));
    const cp = enc(&buf, 5, 1, .{6});
    try t.expectEqual(Action.relay, try tr.clientMessage(cp.hdr, cp.body));

    // add(fd, plane 0, offset 0, stride 128, LINEAR) — ok
    const ad = enc(&buf, 6, 1, .{ 0, 0, 128, 0, 0 });
    const a1 = try tr.clientMessage(ad.hdr, ad.body);
    try t.expect(a1.dmabuf_add.ok);
    try t.expectEqual(@as(u32, 0), a1.dmabuf_add.plane);
    try t.expectEqual(@as(u32, 128), a1.dmabuf_add.stride);
    try t.expectEqual(dmabuf.DRM_FORMAT_MOD_LINEAR, a1.dmabuf_add.modifier);

    // create_immed accepts y-invert and carries the source metadata.
    const ci = enc(&buf, 6, 3, .{ 7, 16, 32, protocol.DRM_FORMAT_XRGB8888, dmabuf.FLAG_Y_INVERT });
    const a2 = try tr.clientMessage(ci.hdr, ci.body);
    try t.expectEqual(@as(u32, 7), a2.dmabuf_create.id);
    try t.expectEqual(@as(u32, 128), a2.dmabuf_create.info.plane.stride);
    try t.expectEqual(dmabuf.FLAG_Y_INVERT, a2.dmabuf_create.info.flags);
    const info = tr.buffers.get(7).?;
    try t.expect(info.dmabuf);
    try t.expectEqual(@as(u32, 7), info.pool);
    try t.expectEqual(@as(i32, 0), info.offset);
    try t.expectEqual(@as(i32, 64), info.stride); // tight width * 4
    try t.expectEqual(@as(u32, 1), info.format); // XR24 -> shm xrgb8888

    // A params object is consumed even after successful immediate create.
    const ad_reuse = enc(&buf, 6, 1, .{ 1, 0, 128, 0, 0 });
    try t.expectError(Error.Malformed, tr.clientMessage(ad_reuse.hdr, ad_reuse.body));

    // attach + commit resolve the dmabuf buffer
    const at = enc(&buf, 4, 1, .{ 7, 0, 0 });
    _ = try tr.clientMessage(at.hdr, at.body);
    const cm = enc(&buf, 4, 6, .{});
    const a3 = try tr.clientMessage(cm.hdr, cm.body);
    try t.expect(a3.commit.info.dmabuf);
    try t.expectEqual(@as(u32, 7), a3.commit.buffer);

    // Tracker preserves non-LINEAR metadata for the daemon importer;
    // capability policy belongs to the authoritative compositor.
    const cp2 = enc(&buf, 5, 1, .{8});
    _ = try tr.clientMessage(cp2.hdr, cp2.body);
    const ad2 = enc(&buf, 8, 1, .{ 0, 0, 128, 0, 216 });
    const a4 = try tr.clientMessage(ad2.hdr, ad2.body);
    try t.expect(a4.dmabuf_add.ok);
    try t.expectEqual(@as(u64, 216), a4.dmabuf_add.modifier);
    const ci2 = enc(&buf, 8, 3, .{ 9, 32, 32, protocol.DRM_FORMAT_XRGB8888, 0 });
    try t.expectEqual(@as(u64, 216), (try tr.clientMessage(ci2.hdr, ci2.body)).dmabuf_create.info.plane.modifier);

    // Non-immed create is declined: the daemon drops the pending fd.
    const cp3 = enc(&buf, 5, 1, .{10});
    _ = try tr.clientMessage(cp3.hdr, cp3.body);
    const ad3 = enc(&buf, 10, 1, .{ 0, 0, 128, 0, 0 });
    _ = try tr.clientMessage(ad3.hdr, ad3.body);
    const cr = enc(&buf, 10, 2, .{ 32, 32, protocol.DRM_FORMAT_XRGB8888, 0 });
    try t.expectEqual(@as(u32, 10), (try tr.clientMessage(cr.hdr, cr.body)).dmabuf_create_failed.params);
    try t.expectError(Error.Malformed, tr.clientMessage(cr.hdr, cr.body));
}

test "dmabuf tracker rejects duplicate, mismatched, and out-of-range planes" {
    var tr = try Tracker.init(t.allocator);
    defer tr.deinit();
    var buf: [96]u8 = undefined;

    const gr = enc(&buf, 1, 1, .{2});
    _ = try tr.clientMessage(gr.hdr, gr.body);
    const bindd = enc(&buf, 2, 0, .{ 22, @as([]const u8, "zwp_linux_dmabuf_v1"), 3, 5 });
    _ = try tr.clientMessage(bindd.hdr, bindd.body);

    const cp = enc(&buf, 5, 1, .{6});
    _ = try tr.clientMessage(cp.hdr, cp.body);
    const reverse = enc(&buf, 6, 1, .{ 1, 0, 64, 0, 7 });
    const reverse_action = try tr.clientMessage(reverse.hdr, reverse.body);
    try t.expectEqual(@as(u32, 1), reverse_action.dmabuf_add.plane);
    try t.expect(!reverse_action.dmabuf_add.ok);
    const mismatched = enc(&buf, 6, 1, .{ 0, 0, 64, 0, 8 });
    try t.expectError(Error.Malformed, tr.clientMessage(mismatched.hdr, mismatched.body));

    const cp2 = enc(&buf, 5, 1, .{7});
    _ = try tr.clientMessage(cp2.hdr, cp2.body);
    const first = enc(&buf, 7, 1, .{ 0, 4, 64, 0, 7 });
    _ = try tr.clientMessage(first.hdr, first.body);
    const duplicate = enc(&buf, 7, 1, .{ 0, 8, 64, 0, 7 });
    try t.expectError(Error.Malformed, tr.clientMessage(duplicate.hdr, duplicate.body));

    const cp3 = enc(&buf, 5, 1, .{8});
    _ = try tr.clientMessage(cp3.hdr, cp3.body);
    const p1 = enc(&buf, 8, 1, .{ 1, 0, 64, 0, 7 });
    _ = try tr.clientMessage(p1.hdr, p1.body);
    const p0 = enc(&buf, 8, 1, .{ 0, 0, 64, 0, 7 });
    _ = try tr.clientMessage(p0.hdr, p0.body);
    const create = enc(&buf, 8, 3, .{ 9, 16, 1, protocol.DRM_FORMAT_ARGB8888, 0 });
    const multi = (try tr.clientMessage(create.hdr, create.body)).dmabuf_create;
    try t.expectEqual(@as(u8, 2), multi.info.plane_count);

    const cp4 = enc(&buf, 5, 1, .{10});
    _ = try tr.clientMessage(cp4.hdr, cp4.body);
    const out_of_range = enc(&buf, 10, 1, .{ dmabuf.MAX_PLANES, 0, 64, 0, 7 });
    try t.expectError(Error.Malformed, tr.clientMessage(out_of_range.hdr, out_of_range.body));
}

test "RowRange.mergeOpt: bbox union, null (= full buffer) wins" {
    const m = RowRange.mergeOpt;
    try t.expectEqual(@as(?RowRange, null), m(null, null));
    try t.expectEqual(@as(?RowRange, null), m(null, .{ .y0 = 3, .y1 = 9 }));
    try t.expectEqual(@as(?RowRange, null), m(.{ .y0 = 3, .y1 = 9 }, null));
    const u = m(.{ .y0 = 10, .y1 = 20 }, .{ .y0 = 2, .y1 = 12 }).?;
    try t.expectEqual(@as(i32, 2), u.y0);
    try t.expectEqual(@as(i32, 20), u.y1);
}

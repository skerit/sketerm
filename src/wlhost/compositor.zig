//! The compositor brain of the sketerm-native app pipe: the server
//! side of the Wayland protocol, as a pure state machine (no
//! sockets, no GTK, no GL — the view layer renders).
//!
//! Input: the daemon's pipe-unit stream (wlhost/pipe.zig) — verbatim
//! client requests plus shm-pool side-band keeping local mirrors in
//! sync (pool bytes arrive BEFORE the commit that references them).
//! Output: pipe units of compositor→client events, drained by the
//! caller toward the daemon. The View callbacks surface toplevel
//! lifecycle + committed pixels to whatever renders windows.
//!
//! v1 scope (docs/proposal-macos-remote-apps.md): shm only,
//! toplevels only (popups refused), wl_seat advertised with no
//! capabilities (input is the next milestone), single output,
//! integer scale 1. Frame callbacks fire at commit time.

const std = @import("std");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");
const pipe = @import("pipe.zig");

pub const Error = error{
    Protocol,
    OutOfMemory,
} || wire.Error;

/// Renderer-facing callbacks. Slices are valid only for the call.
pub const View = struct {
    ctx: ?*anyopaque = null,
    /// A surface gained the toplevel role.
    toplevel_new: ?*const fn (ctx: ?*anyopaque, surface: u32) void = null,
    /// New committed content. `pixels` is tightly packed w*4 rows
    /// (stride already applied), wl_shm format (0 argb, 1 xrgb).
    toplevel_frame: ?*const fn (ctx: ?*anyopaque, surface: u32, w: i32, h: i32, format: u32, pixels: []const u8) void = null,
    toplevel_title: ?*const fn (ctx: ?*anyopaque, surface: u32, title: []const u8) void = null,
    /// Toplevel destroyed (or its surface) — drop the window.
    toplevel_gone: ?*const fn (ctx: ?*anyopaque, surface: u32) void = null,
};

const Global = struct {
    name: u32,
    iface: *const protocol.Interface,
    version: u32,
};

/// What we advertise — deliberately low versions: nothing here
/// obliges events we don't implement.
const globals = [_]Global{
    .{ .name = 1, .iface = &protocol.wl_compositor, .version = 4 },
    .{ .name = 2, .iface = &protocol.wl_shm, .version = 1 },
    .{ .name = 3, .iface = &protocol.wl_seat, .version = 1 },
    .{ .name = 4, .iface = &protocol.wl_output, .version = 2 },
    .{ .name = 5, .iface = &protocol.xdg_wm_base, .version = 2 },
};

const Pool = struct {
    bytes: std.ArrayList(u8) = .empty,
};

const Buffer = struct {
    pool: u32,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: u32,
};

const Surface = struct {
    /// Pending (attach happened since last commit). 0 with
    /// has_pending = attach(null) → unmap.
    pending_buffer: u32 = 0,
    has_pending: bool = false,
    /// Latched buffer id (content source after commit).
    committed_buffer: u32 = 0,
    xdg_surface: u32 = 0,
    toplevel: u32 = 0,
    /// wl_callback ids awaiting frame done.
    frame_cbs: std.ArrayList(u32) = .empty,
    /// Initial configure sent (xdg dance).
    configured: bool = false,
};

pub const Compositor = struct {
    allocator: std.mem.Allocator,
    view: View,
    /// Outgoing pipe units (events). Caller drains via takeOut.
    out: std.ArrayList(u8) = .empty,
    /// Incoming unit reassembly (chan_data may split units).
    inbuf: std.ArrayList(u8) = .empty,
    objects: std.AutoHashMapUnmanaged(u32, *const protocol.Interface) = .empty,
    pools: std.AutoHashMapUnmanaged(u32, Pool) = .empty,
    buffers: std.AutoHashMapUnmanaged(u32, Buffer) = .empty,
    surfaces: std.AutoHashMapUnmanaged(u32, Surface) = .empty,
    /// xdg_surface id → wl_surface id; xdg_toplevel id → wl_surface id.
    xdg_map: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// Tight-packed copy handed to toplevel_frame.
    frame_scratch: std.ArrayList(u8) = .empty,
    serial: u32 = 1,
    /// Caller-provided clock for frame-callback timestamps (ms).
    now_ms: u32 = 0,
    /// Set on fatal protocol error after wl_display.error went out;
    /// the caller should close the channel once out is drained.
    dead: bool = false,

    pub fn init(allocator: std.mem.Allocator, view: View) Error!Compositor {
        var self = Compositor{ .allocator = allocator, .view = view };
        try self.objects.put(allocator, 1, &protocol.wl_display);
        return self;
    }

    pub fn deinit(self: *Compositor) void {
        const a = self.allocator;
        self.out.deinit(a);
        self.inbuf.deinit(a);
        self.objects.deinit(a);
        var pit = self.pools.valueIterator();
        while (pit.next()) |p| p.bytes.deinit(a);
        self.pools.deinit(a);
        self.buffers.deinit(a);
        var sit = self.surfaces.valueIterator();
        while (sit.next()) |s| s.frame_cbs.deinit(a);
        self.surfaces.deinit(a);
        self.xdg_map.deinit(a);
        self.frame_scratch.deinit(a);
    }

    /// Feed raw bytes of the pipe-unit stream (e.g. one chan_data
    /// payload). Processes every complete unit; buffers the tail.
    pub fn feed(self: *Compositor, bytes: []const u8) Error!void {
        try self.inbuf.appendSlice(self.allocator, bytes);
        var pos: usize = 0;
        while (!self.dead) {
            const peeled = pipe.peelUnit(self.inbuf.items[pos..]) catch return Error.Protocol;
            const p = peeled orelse break;
            try self.feedUnit(p.unit.tag, p.unit.payload);
            pos += p.consumed;
        }
        if (pos > 0) {
            const rem = self.inbuf.items.len - pos;
            std.mem.copyForwards(u8, self.inbuf.items[0..rem], self.inbuf.items[pos..]);
            self.inbuf.shrinkRetainingCapacity(rem);
        }
    }

    /// View → client: ask the app to close this toplevel (window
    /// close button). The app decides; nothing is destroyed here.
    pub fn requestClose(self: *Compositor, sid: u32) Error!void {
        const surf = self.surfaces.getPtr(sid) orelse return;
        if (surf.toplevel == 0) return;
        var buf: [8]u8 = undefined;
        var b = wire.Builder.init(&buf, surf.toplevel, 1); // close
        try self.send(try b.finish());
    }

    /// The accumulated outgoing unit stream; caller ships it (as
    /// chan_data, or decoded onto a test socket) and then clears.
    pub fn takeOut(self: *Compositor) []const u8 {
        return self.out.items;
    }

    pub fn clearOut(self: *Compositor) void {
        self.out.clearRetainingCapacity();
    }

    fn feedUnit(self: *Compositor, tag: pipe.Tag, payload: []const u8) Error!void {
        switch (tag) {
            .wl_msg => {
                const hdr = (wire.parseHeader(payload) catch return Error.Protocol) orelse return Error.Protocol;
                if (payload.len < hdr.size) return Error.Protocol;
                self.request(hdr, payload[wire.header_size..hdr.size]) catch |err| switch (err) {
                    Error.OutOfMemory => return err,
                    else => try self.fatal(hdr.object, "protocol error"),
                };
            },
            .pool_create, .pool_resize => {
                const meta = pipe.decodePoolMeta(payload) orelse return Error.Protocol;
                const slot = try self.pools.getOrPut(self.allocator, meta.pool);
                if (!slot.found_existing) slot.value_ptr.* = .{};
                try slot.value_ptr.bytes.resize(self.allocator, meta.size);
            },
            .pool_update => {
                const upd = pipe.decodePoolUpdate(payload) orelse return Error.Protocol;
                const pool = self.pools.getPtr(upd.pool) orelse return Error.Protocol;
                const end = @as(usize, upd.offset) + upd.bytes.len;
                if (end > pool.bytes.items.len) return Error.Protocol;
                @memcpy(pool.bytes.items[upd.offset..end], upd.bytes);
            },
            .pool_destroy => {
                if (payload.len >= 4) {
                    const id = std.mem.readInt(u32, payload[0..4], .little);
                    if (self.pools.getPtr(id)) |p| {
                        p.bytes.deinit(self.allocator);
                        _ = self.pools.remove(id);
                    }
                }
            },
            else => {}, // forward compat
        }
    }

    // ── request dispatch ────────────────────────────────────────

    fn request(self: *Compositor, hdr: wire.Header, body: []const u8) Error!void {
        const iface = self.objects.get(hdr.object) orelse return Error.Protocol;
        if (hdr.opcode >= iface.requests.len) return Error.Protocol;
        const msg = &iface.requests[hdr.opcode];
        var it = wire.ArgIter.init(body, msg.sig);

        if (iface == &protocol.wl_display) switch (hdr.opcode) {
            0 => { // sync(callback)
                const cb = (try it.next()).?.new_id;
                var buf: [32]u8 = undefined;
                var b = wire.Builder.init(&buf, cb, 0); // done
                b.putUint(self.nextSerial());
                try self.send(try b.finish());
                try self.deleteId(cb);
            },
            1 => { // get_registry
                const reg = (try it.next()).?.new_id;
                try self.register(reg, &protocol.wl_registry);
                for (globals) |g| {
                    var buf: [64]u8 = undefined;
                    var b = wire.Builder.init(&buf, reg, 0); // global
                    b.putUint(g.name);
                    b.putString(g.iface.name);
                    b.putUint(g.version);
                    try self.send(try b.finish());
                }
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_registry) {
            // bind(name, iface_str, version, id)
            const name = (try it.next()).?.uint;
            const iname = (try it.next()).?.string orelse return Error.Protocol;
            const ver = (try it.next()).?.uint;
            const id = (try it.next()).?.new_id;
            const g = for (globals) |g| {
                if (g.name == name) break g;
            } else return Error.Protocol;
            if (!std.mem.eql(u8, g.iface.name, iname) or ver == 0 or ver > g.version)
                return Error.Protocol;
            try self.register(id, g.iface);
            try self.boundGlobal(id, g.iface);
        } else if (iface == &protocol.wl_compositor) switch (hdr.opcode) {
            0 => { // create_surface
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_surface);
                try self.surfaces.put(self.allocator, id, .{});
            },
            1 => { // create_region — tracked, contents ignored
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.wl_region);
            },
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_region) {
            // destroy/add/subtract — only destroy needs action
            if (hdr.opcode == 0) try self.destroyObject(hdr.object);
        } else if (iface == &protocol.wl_shm) switch (hdr.opcode) {
            0 => { // create_pool(id, fd, size) — bytes via side-band
                const id = (try it.next()).?.new_id;
                _ = (try it.next()).?; // fd placeholder
                const size = (try it.next()).?.int;
                if (size <= 0) return Error.Protocol;
                try self.register(id, &protocol.wl_shm_pool);
                const slot = try self.pools.getOrPut(self.allocator, id);
                if (!slot.found_existing) slot.value_ptr.* = .{};
                try slot.value_ptr.bytes.resize(self.allocator, @intCast(size));
            },
            else => return Error.Protocol, // release is since-2; we advertise 1
        } else if (iface == &protocol.wl_shm_pool) switch (hdr.opcode) {
            0 => { // create_buffer
                const id = (try it.next()).?.new_id;
                const offset = (try it.next()).?.int;
                const width = (try it.next()).?.int;
                const height = (try it.next()).?.int;
                const stride = (try it.next()).?.int;
                const format = (try it.next()).?.uint;
                if (width <= 0 or height <= 0 or stride < width * 4 or offset < 0)
                    return Error.Protocol;
                try self.register(id, &protocol.wl_buffer);
                try self.buffers.put(self.allocator, id, .{
                    .pool = hdr.object,
                    .offset = offset,
                    .width = width,
                    .height = height,
                    .stride = stride,
                    .format = format,
                });
            },
            1 => { // destroy — mirror stays while buffers reference it
                try self.destroyObject(hdr.object);
            },
            2 => {}, // resize — side-band already grew the mirror
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_buffer) {
            // destroy
            _ = self.buffers.remove(hdr.object);
            try self.destroyObject(hdr.object);
        } else if (iface == &protocol.wl_surface) {
            try self.surfaceRequest(hdr, &it);
        } else if (iface == &protocol.wl_seat) switch (hdr.opcode) {
            // Caps are 0 so get_* "shouldn't" arrive, but sloppy
            // toolkits send them anyway: register the device object
            // and stay silent — it simply never emits events.
            0 => try self.register((try it.next()).?.new_id, &protocol.wl_pointer),
            1 => try self.register((try it.next()).?.new_id, &protocol.wl_keyboard),
            2 => try self.register((try it.next()).?.new_id, &protocol.wl_touch),
            else => return Error.Protocol,
        } else if (iface == &protocol.wl_pointer or iface == &protocol.wl_keyboard or iface == &protocol.wl_touch) {
            // Only request on all three is release (a destructor).
            try self.destroyObject(hdr.object);
        } else if (iface == &protocol.wl_output) {
            // release — lenient even though we advertise v2.
            try self.destroyObject(hdr.object);
        } else if (iface == &protocol.xdg_wm_base) switch (hdr.opcode) {
            0 => try self.destroyObject(hdr.object), // destroy
            1 => { // create_positioner
                const id = (try it.next()).?.new_id;
                try self.register(id, &protocol.xdg_positioner);
            },
            2 => { // get_xdg_surface(id, surface)
                const id = (try it.next()).?.new_id;
                const sid = (try it.next()).?.object;
                const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
                if (surf.xdg_surface != 0) return Error.Protocol;
                try self.register(id, &protocol.xdg_surface);
                try self.xdg_map.put(self.allocator, id, sid);
                surf.xdg_surface = id;
            },
            3 => {}, // pong
            else => return Error.Protocol,
        } else if (iface == &protocol.xdg_positioner) {
            // destroy/set_* — geometry unused until popups exist
            if (hdr.opcode == 0) try self.destroyObject(hdr.object);
        } else if (iface == &protocol.xdg_surface) {
            try self.xdgSurfaceRequest(hdr, &it);
        } else if (iface == &protocol.xdg_toplevel) {
            try self.toplevelRequest(hdr, body, &it);
        } else {
            return Error.Protocol;
        }
    }

    fn surfaceRequest(self: *Compositor, hdr: wire.Header, it: *wire.ArgIter) Error!void {
        const surf = self.surfaces.getPtr(hdr.object) orelse return Error.Protocol;
        switch (hdr.opcode) {
            0 => { // destroy
                if (surf.toplevel != 0) self.notifyGone(hdr.object);
                surf.frame_cbs.deinit(self.allocator);
                _ = self.surfaces.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1 => { // attach(buffer, x, y)
                surf.pending_buffer = (try it.next()).?.object;
                surf.has_pending = true;
            },
            3 => { // frame(callback)
                const cb = (try it.next()).?.new_id;
                try surf.frame_cbs.append(self.allocator, cb);
            },
            6 => try self.commit(hdr.object, surf),
            // damage/damage_buffer/regions/transform/scale/offset:
            // accepted, ignored (full-copy pipeline).
            2, 4, 5, 7, 8, 9, 10 => {},
            else => return Error.Protocol,
        }
    }

    fn xdgSurfaceRequest(self: *Compositor, hdr: wire.Header, it: *wire.ArgIter) Error!void {
        const sid = self.xdg_map.get(hdr.object) orelse return Error.Protocol;
        switch (hdr.opcode) {
            0 => { // destroy
                if (self.surfaces.getPtr(sid)) |surf| {
                    surf.xdg_surface = 0;
                    surf.configured = false;
                }
                _ = self.xdg_map.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1 => { // get_toplevel(id)
                const id = (try it.next()).?.new_id;
                const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
                if (surf.toplevel != 0) return Error.Protocol;
                try self.register(id, &protocol.xdg_toplevel);
                try self.xdg_map.put(self.allocator, id, sid);
                surf.toplevel = id;
                if (self.view.toplevel_new) |cb| cb(self.view.ctx, sid);
            },
            2 => return Error.Protocol, // get_popup — v1 refuses
            3 => {}, // set_window_geometry — buffer size rules v1
            4 => {}, // ack_configure
            else => return Error.Protocol,
        }
    }

    fn toplevelRequest(self: *Compositor, hdr: wire.Header, body: []const u8, it: *wire.ArgIter) Error!void {
        _ = body;
        const sid = self.xdg_map.get(hdr.object) orelse return Error.Protocol;
        switch (hdr.opcode) {
            0 => { // destroy
                if (self.surfaces.getPtr(sid)) |surf| surf.toplevel = 0;
                self.notifyGone(sid);
                _ = self.xdg_map.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            2 => { // set_title(s)
                const title = (try it.next()).?.string orelse return;
                if (self.view.toplevel_title) |cb| cb(self.view.ctx, sid, title);
            },
            // set_parent/app_id/min/max/maximize/fullscreen/minimize:
            // accepted, no window management in v1. move/resize/menu
            // need a seat serial the client can't have (caps 0).
            1, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 => {},
            else => return Error.Protocol,
        }
    }

    /// Latch pending state, push pixels to the view, fire frame
    /// callbacks, release the buffer. The xdg dance: the first
    /// commit WITHOUT a buffer triggers the initial configure.
    fn commit(self: *Compositor, sid: u32, surf: *Surface) Error!void {
        if (surf.has_pending) {
            surf.committed_buffer = surf.pending_buffer;
            surf.has_pending = false;
        }

        if (surf.xdg_surface != 0 and !surf.configured) {
            surf.configured = true;
            if (surf.toplevel != 0) {
                var buf: [64]u8 = undefined;
                var b = wire.Builder.init(&buf, surf.toplevel, 0); // configure
                b.putInt(0); // width: client decides
                b.putInt(0);
                var states: [4]u8 = undefined;
                std.mem.writeInt(u32, &states, 4, .little); // activated
                b.putArray(&states);
                try self.send(try b.finish());
            }
            var buf2: [16]u8 = undefined;
            var b2 = wire.Builder.init(&buf2, surf.xdg_surface, 0); // configure
            b2.putUint(self.nextSerial());
            try self.send(try b2.finish());
        }

        if (surf.committed_buffer != 0) {
            if (self.buffers.get(surf.committed_buffer)) |info| {
                try self.pushFrame(sid, info);
                // Released immediately: pixels were copied out.
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, surf.committed_buffer, 0); // release
                try self.send(try b.finish());
            }
        }

        // Frame callbacks: done + delete_id, in request order.
        for (surf.frame_cbs.items) |cb| {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, cb, 0); // done
            b.putUint(self.now_ms);
            try self.send(try b.finish());
            try self.deleteId(cb);
        }
        surf.frame_cbs.clearRetainingCapacity();
    }

    /// Copy the committed rows tightly packed and hand them to the
    /// view. Bounds are clamped against the mirror, not trusted.
    fn pushFrame(self: *Compositor, sid: u32, info: Buffer) Error!void {
        const cb = self.view.toplevel_frame orelse return;
        const pool = self.pools.getPtr(info.pool) orelse return;
        const w: usize = @intCast(info.width);
        const h: usize = @intCast(info.height);
        const stride: usize = @intCast(info.stride);
        const offset: usize = @intCast(info.offset);
        const row_bytes = w * 4;
        try self.frame_scratch.resize(self.allocator, row_bytes * h);
        var y: usize = 0;
        while (y < h) : (y += 1) {
            const src_start = offset + y * stride;
            if (src_start + row_bytes > pool.bytes.items.len) return; // stale mirror
            @memcpy(
                self.frame_scratch.items[y * row_bytes ..][0..row_bytes],
                pool.bytes.items[src_start..][0..row_bytes],
            );
        }
        cb(self.view.ctx, sid, info.width, info.height, info.format, self.frame_scratch.items);
    }

    // ── server plumbing ─────────────────────────────────────────

    fn boundGlobal(self: *Compositor, id: u32, iface: *const protocol.Interface) Error!void {
        if (iface == &protocol.wl_shm) {
            for ([_]u32{ 0, 1 }) |fmt| { // argb8888, xrgb8888
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, id, 0); // format
                b.putUint(fmt);
                try self.send(try b.finish());
            }
        } else if (iface == &protocol.wl_seat) {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, id, 0); // capabilities
            b.putUint(0); // input lands with the next milestone
            try self.send(try b.finish());
        } else if (iface == &protocol.wl_output) {
            var gbuf: [96]u8 = undefined;
            var g = wire.Builder.init(&gbuf, id, 0); // geometry
            g.putInt(0); // x
            g.putInt(0);
            g.putInt(0); // physical size unknown
            g.putInt(0);
            g.putInt(0); // subpixel unknown
            g.putString("sketerm");
            g.putString("remote");
            g.putInt(0); // transform normal
            try self.send(try g.finish());
            var mbuf: [32]u8 = undefined;
            var m = wire.Builder.init(&mbuf, id, 1); // mode
            m.putUint(0x3); // current | preferred
            m.putInt(1920);
            m.putInt(1080);
            m.putInt(60000);
            try self.send(try m.finish());
            var sbuf: [16]u8 = undefined;
            var s = wire.Builder.init(&sbuf, id, 3); // scale
            s.putInt(1);
            try self.send(try s.finish());
            var dbuf: [8]u8 = undefined;
            var d = wire.Builder.init(&dbuf, id, 2); // done
            try self.send(try d.finish());
        }
    }

    fn register(self: *Compositor, id: u32, iface: *const protocol.Interface) Error!void {
        if (id == 0) return Error.Protocol;
        const slot = try self.objects.getOrPut(self.allocator, id);
        if (slot.found_existing) return Error.Protocol;
        slot.value_ptr.* = iface;
    }

    /// Remove a destroyed object and confirm to the client so it
    /// can reuse the id.
    fn destroyObject(self: *Compositor, id: u32) Error!void {
        _ = self.objects.remove(id);
        try self.deleteId(id);
    }

    fn deleteId(self: *Compositor, id: u32) Error!void {
        _ = self.objects.remove(id);
        var buf: [16]u8 = undefined;
        var b = wire.Builder.init(&buf, 1, 1); // wl_display.delete_id
        b.putUint(id);
        try self.send(try b.finish());
    }

    fn notifyGone(self: *Compositor, sid: u32) void {
        if (self.view.toplevel_gone) |cb| cb(self.view.ctx, sid);
    }

    fn nextSerial(self: *Compositor) u32 {
        self.serial +%= 1;
        return self.serial;
    }

    fn send(self: *Compositor, msg: []const u8) Error!void {
        try pipe.appendUnit(&self.out, self.allocator, .wl_msg, msg);
    }

    /// wl_display.error + dead-mark. The object may be anything the
    /// client recognizes; code 1 = invalid_method is close enough
    /// for every v1 refusal.
    fn fatal(self: *Compositor, object: u32, text: []const u8) Error!void {
        var buf: [128]u8 = undefined;
        var b = wire.Builder.init(&buf, 1, 0); // wl_display.error
        b.putObject(object);
        b.putUint(1);
        b.putString(text);
        try self.send(try b.finish());
        self.dead = true;
    }
};

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

const TestView = struct {
    new_count: usize = 0,
    frames: usize = 0,
    last_w: i32 = 0,
    last_h: i32 = 0,
    last_pixels: [64]u8 = undefined,
    last_len: usize = 0,
    title_buf: [64]u8 = undefined,
    title_len: usize = 0,
    gone: usize = 0,

    fn onNew(ctx: ?*anyopaque, surface: u32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.new_count += 1;
    }
    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, format: u32, pixels: []const u8) void {
        _ = surface;
        _ = format;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.frames += 1;
        self.last_w = w;
        self.last_h = h;
        self.last_len = @min(pixels.len, self.last_pixels.len);
        @memcpy(self.last_pixels[0..self.last_len], pixels[0..self.last_len]);
    }
    fn onTitle(ctx: ?*anyopaque, surface: u32, title: []const u8) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.title_len = @min(title.len, self.title_buf.len);
        @memcpy(self.title_buf[0..self.title_len], title[0..self.title_len]);
    }
    fn onGone(ctx: ?*anyopaque, surface: u32) void {
        _ = surface;
        const self: *TestView = @ptrCast(@alignCast(ctx.?));
        self.gone += 1;
    }

    fn view(self: *TestView) View {
        return .{
            .ctx = self,
            .toplevel_new = onNew,
            .toplevel_frame = onFrame,
            .toplevel_title = onTitle,
            .toplevel_gone = onGone,
        };
    }
};

/// Feed one client request as a wl_msg unit.
fn req(comp: *Compositor, msg: []const u8) !void {
    var unit: std.ArrayList(u8) = .empty;
    defer unit.deinit(t.allocator);
    try pipe.appendUnit(&unit, t.allocator, .wl_msg, msg);
    try comp.feed(unit.items);
}

/// Collect every event (object, opcode) pair currently queued.
fn drainEvents(comp: *Compositor, list: *std.ArrayList([2]u32)) !void {
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        if (p.unit.tag == .wl_msg) {
            const hdr = (try wire.parseHeader(p.unit.payload)).?;
            try list.append(t.allocator, .{ hdr.object, hdr.opcode });
        }
        pos += p.consumed;
    }
    comp.clearOut();
}

test "registry dance announces our globals" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();

    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 1, 1); // get_registry(2)
    b.putNewId(2);
    try req(&comp, try b.finish());

    var seen: usize = 0;
    var pos: usize = 0;
    const bytes = comp.takeOut();
    while (try pipe.peelUnit(bytes[pos..])) |p| {
        const hdr = (try wire.parseHeader(p.unit.payload)).?;
        try t.expectEqual(@as(u32, 2), hdr.object); // registry
        try t.expectEqual(@as(u16, 0), hdr.opcode); // global
        seen += 1;
        pos += p.consumed;
    }
    try t.expectEqual(globals.len, seen);
}

test "full client lifecycle: bind, surface, xdg dance, commit, pixels" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [128]u8 = undefined;

    { // get_registry(2)
        var b = wire.Builder.init(&buf, 1, 1);
        b.putNewId(2);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    { // bind compositor(name 1) → id 3
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(1);
        b.putString("wl_compositor");
        b.putUint(4);
        b.putNewId(3);
        try req(&comp, try b.finish());
    }
    { // bind shm(name 2) → id 4
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(2);
        b.putString("wl_shm");
        b.putUint(1);
        b.putNewId(4);
        try req(&comp, try b.finish());
    }
    { // bind xdg_wm_base(name 5) → id 5
        var b = wire.Builder.init(&buf, 2, 0);
        b.putUint(5);
        b.putString("xdg_wm_base");
        b.putUint(2);
        b.putNewId(5);
        try req(&comp, try b.finish());
    }
    var evs: std.ArrayList([2]u32) = .empty;
    defer evs.deinit(t.allocator);
    try drainEvents(&comp, &evs);
    // shm formats announced on bind
    try t.expect(evs.items.len >= 2);
    try t.expectEqual([2]u32{ 4, 0 }, evs.items[0]);

    { // create_surface → 6
        var b = wire.Builder.init(&buf, 3, 0);
        b.putNewId(6);
        try req(&comp, try b.finish());
    }
    { // get_xdg_surface(7, surface 6)
        var b = wire.Builder.init(&buf, 5, 2);
        b.putNewId(7);
        b.putObject(6);
        try req(&comp, try b.finish());
    }
    { // get_toplevel(8)
        var b = wire.Builder.init(&buf, 7, 1);
        b.putNewId(8);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.new_count);
    { // set_title
        var b = wire.Builder.init(&buf, 8, 2);
        b.putString("hello");
        try req(&comp, try b.finish());
    }
    try t.expectEqualStrings("hello", tv.title_buf[0..tv.title_len]);

    // First commit (no buffer) → toplevel.configure + xdg.configure
    comp.clearOut();
    { // commit
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    try t.expectEqual(@as(usize, 2), evs.items.len);
    try t.expectEqual([2]u32{ 8, 0 }, evs.items[0]); // toplevel configure
    try t.expectEqual([2]u32{ 7, 0 }, evs.items[1]); // xdg configure

    // Pool (side-band sized), buffer 2x2, attach, frame cb, commit.
    { // create_pool(9, fd, 16)
        var b = wire.Builder.init(&buf, 4, 0);
        b.putNewId(9);
        b.putInt(16);
        try req(&comp, try b.finish());
    }
    { // pool bytes via side-band update
        var unit: std.ArrayList(u8) = .empty;
        defer unit.deinit(t.allocator);
        var px: [16]u8 = undefined;
        for (&px, 0..) |*p, i| p.* = @intCast(i + 100);
        try pipe.appendPoolUpdate(&unit, t.allocator, 9, 0, &px);
        try comp.feed(unit.items);
    }
    { // create_buffer(10, 0, 2x2, stride 8, xrgb)
        var b = wire.Builder.init(&buf, 9, 0);
        b.putNewId(10);
        b.putInt(0);
        b.putInt(2);
        b.putInt(2);
        b.putInt(8);
        b.putUint(1);
        try req(&comp, try b.finish());
    }
    { // attach(10, 0, 0)
        var b = wire.Builder.init(&buf, 6, 1);
        b.putObject(10);
        b.putInt(0);
        b.putInt(0);
        try req(&comp, try b.finish());
    }
    { // frame(11)
        var b = wire.Builder.init(&buf, 6, 3);
        b.putNewId(11);
        try req(&comp, try b.finish());
    }
    comp.clearOut();
    { // commit
        var b = wire.Builder.init(&buf, 6, 6);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.frames);
    try t.expectEqual(@as(i32, 2), tv.last_w);
    try t.expectEqual(@as(i32, 2), tv.last_h);
    try t.expectEqual(@as(u8, 100), tv.last_pixels[0]);
    try t.expectEqual(@as(u8, 115), tv.last_pixels[15]);

    evs.clearRetainingCapacity();
    try drainEvents(&comp, &evs);
    // buffer release + frame done + delete_id(11)
    try t.expectEqual(@as(usize, 3), evs.items.len);
    try t.expectEqual([2]u32{ 10, 0 }, evs.items[0]); // release
    try t.expectEqual([2]u32{ 11, 0 }, evs.items[1]); // done
    try t.expectEqual([2]u32{ 1, 1 }, evs.items[2]); // delete_id

    // Toplevel destroy → gone callback.
    { // xdg_toplevel.destroy
        var b = wire.Builder.init(&buf, 8, 0);
        try req(&comp, try b.finish());
    }
    try t.expectEqual(@as(usize, 1), tv.gone);
}

test "protocol violation produces wl_display.error and dead" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [64]u8 = undefined;
    // bind on a nonexistent registry object
    var b = wire.Builder.init(&buf, 99, 0);
    b.putUint(1);
    try req(&comp, try b.finish());
    try t.expect(comp.dead);
    const bytes = comp.takeOut();
    const p = (try pipe.peelUnit(bytes)).?;
    const hdr = (try wire.parseHeader(p.unit.payload)).?;
    try t.expectEqual(@as(u32, 1), hdr.object); // wl_display
    try t.expectEqual(@as(u16, 0), hdr.opcode); // error
}

test "stale mirror bounds are never trusted" {
    var tv = TestView{};
    var comp = try Compositor.init(t.allocator, tv.view());
    defer comp.deinit();
    var buf: [128]u8 = undefined;

    // Minimal dance up to a buffer whose extent exceeds the pool.
    var b = wire.Builder.init(&buf, 1, 1);
    b.putNewId(2);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 2, 0);
    b.putUint(1);
    b.putString("wl_compositor");
    b.putUint(1);
    b.putNewId(3);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 2, 0);
    b.putUint(2);
    b.putString("wl_shm");
    b.putUint(1);
    b.putNewId(4);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 3, 0);
    b.putNewId(6);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 4, 0); // pool 16 bytes
    b.putNewId(9);
    b.putInt(16);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 9, 0); // buffer claims 4x4 stride 16
    b.putNewId(10);
    b.putInt(0);
    b.putInt(4);
    b.putInt(4);
    b.putInt(16);
    b.putUint(1);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 6, 1);
    b.putObject(10);
    b.putInt(0);
    b.putInt(0);
    try req(&comp, try b.finish());
    b = wire.Builder.init(&buf, 6, 6); // commit
    try req(&comp, try b.finish());

    // No crash, no frame callback with garbage.
    try t.expectEqual(@as(usize, 0), tv.frames);
    try t.expect(!comp.dead);
}

//! Compositor request dispatch — per-interface Wayland request
//! handling — split out of compositor.zig along its own section
//! banner. Functions take the owning *Compositor and are aliased
//! back into Compositor.

const std = @import("std");
const wire = @import("wire.zig");
const protocol = @import("protocol.zig");
const dmabuf = @import("dmabuf.zig");
const pipe = @import("pipe.zig");
const cmod = @import("compositor.zig");
const Compositor = cmod.Compositor;
const Error = cmod.Error;
const globals = cmod.globals;
const Surface = cmod.Surface;
const Buffer = cmod.Buffer;
const removeId = cmod.removeId;

// ── request dispatch ────────────────────────────────────────

pub fn request(self: *Compositor, hdr: wire.Header, body: []const u8) Error!void {
    const iface = self.objects.get(hdr.object) orelse {
        // Replicas never learn the brain's server-created objects
        // (clipboard data offers): requests on them are skipped,
        // not fatal. The authoritative brain stays strict.
        if (self.lenient) return;
        return Error.Protocol;
    };
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
                // dmabuf is announce-gated (SKETERM_MUX_DMABUF).
                // Replicas re-parse the authoritative request
                // stream but discard their own announcements.
                if (g.iface == &protocol.zwp_linux_dmabuf_v1 and !self.advertise_dmabuf)
                    continue;
                var buf: [64]u8 = undefined;
                var b = wire.Builder.init(&buf, reg, 0); // global
                b.putUint(g.name);
                b.putString(g.iface.name);
                b.putUint(if (g.iface == &protocol.zwp_linux_dmabuf_v1)
                    self.dmabufVersion()
                else
                    g.version);
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
        // Reject clients guessing the stable dmabuf global name
        // when it was not advertised. Replicas still need to parse
        // that authoritative bind from the replayed request stream.
        if (g.iface == &protocol.zwp_linux_dmabuf_v1 and
            !self.advertise_dmabuf and !self.lenient)
            return Error.Protocol;
        // A brain that announced v3 must refuse a v4 bind: the
        // client would then wait for feedback events we have no
        // main device for. Replicas validate against the static
        // table, since the authoritative bind already happened.
        if (g.iface == &protocol.zwp_linux_dmabuf_v1 and
            !self.lenient and ver > self.dmabufVersion())
            return Error.Protocol;
        if (!std.mem.eql(u8, g.iface.name, iname) or ver == 0 or ver > g.version) {
            std.debug.print("wlhost: bad bind {s} v{d} (advertised {s} v{d})\n", .{ iname, ver, g.iface.name, g.version });
            return Error.Protocol;
        }
        try self.register(id, g.iface);
        self.obj_versions.put(self.allocator, id, ver) catch return Error.OutOfMemory;
        // Old replica tables cap these binds lower (seat 8,
        // compositor 6, shm 1, ddm 3, dmabuf 3; no wl_fixes at
        // all) and bindGlobal's version check is not lenient, so
        // the bind ALONE kills them — the viewer gate must latch
        // here, not just on the post-bump requests.
        if (g.iface == &protocol.zwp_linux_dmabuf_v1 and ver >= 4)
            self.used_dmabuf_feedback = true;
        if ((g.iface == &protocol.wl_seat and ver >= 9) or
            (g.iface == &protocol.wl_compositor and ver >= 7) or
            (g.iface == &protocol.wl_shm and ver >= 2) or
            (g.iface == &protocol.wl_data_device_manager and ver >= 4) or
            g.iface == &protocol.wl_fixes)
            self.used_post_v8_request = true;
        if (g.iface == &protocol.wl_seat) self.seat_version = ver;
        if (g.iface == &protocol.wl_compositor) self.compositor_version = ver;
        if (g.iface == &protocol.xdg_wm_base) self.wm_base_version = ver;
        if (g.iface == &protocol.wl_data_device_manager) self.ddm_version = ver;
        if (g.iface == &protocol.wl_output) self.output_id = id;
        if (g.iface == &protocol.zxdg_output_manager_v1) self.xdg_output_ver = ver;
        try self.boundGlobal(id, g.iface, ver);
    } else if (iface == &protocol.wl_compositor) switch (hdr.opcode) {
        0 => { // create_surface
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wl_surface);
            try self.surfaces.put(self.allocator, id, .{});
            if (self.compositor_version >= 6) {
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, id, 2); // preferred_buffer_scale
                b.putInt(self.output_scale);
                try self.send(try b.finish());
                var tbuf: [16]u8 = undefined;
                var tb = wire.Builder.init(&tbuf, id, 3); // preferred_buffer_transform
                tb.putUint(0); // normal
                try self.send(try tb.finish());
            }
        },
        1 => { // create_region — tracked, contents ignored
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wl_region);
        },
        // release (v7): drops the global ONLY. Surfaces and
        // regions it made stay alive and usable, per the spec.
        2 => try self.destroyPostV8(hdr.object),
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_fixes) switch (hdr.opcode) {
        0 => try self.destroyPostV8(hdr.object), // destroy
        1 => { // destroy_registry(registry)
            const reg = (try it.next()).?.object;
            if (self.objects.get(reg)) |ri| {
                if (ri != &protocol.wl_registry) return Error.Protocol;
            } else if (!self.lenient) return Error.Protocol;
            try self.destroyPostV8(reg);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_subcompositor) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object), // destroy
        1 => { // get_subsurface(id, surface, parent)
            const id = (try it.next()).?.new_id;
            const sid = (try it.next()).?.object;
            const parent = (try it.next()).?.object;
            try self.register(id, &protocol.wl_subsurface);
            try self.sub_map.put(self.allocator, id, sid);
            if (self.surfaces.getPtr(sid)) |surf| {
                surf.subparent = parent;
                if (self.view.subsurface_new) |cb| cb(self.view.ctx, sid, parent, 0, 0);
            }
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_subsurface) switch (hdr.opcode) {
        0 => { // destroy
            if (self.sub_map.fetchRemove(hdr.object)) |kv| {
                if (self.surfaces.getPtr(kv.value)) |surf| surf.subparent = 0;
                if (self.view.subsurface_gone) |cb| cb(self.view.ctx, kv.value);
            }
            try self.destroyObject(hdr.object);
        },
        1 => { // set_position(x, y) — parent-relative, applied live
            const x = (try it.next()).?.int;
            const y = (try it.next()).?.int;
            const sid = self.sub_map.get(hdr.object) orelse return;
            if (self.surfaces.getPtr(sid)) |surf| {
                surf.sub_x = x;
                surf.sub_y = y;
            }
            if (self.view.subsurface_pos) |cb| cb(self.view.ctx, sid, x, y);
        },
        2, 3 => { // place_above / place_below(sibling)
            const sibling = (try it.next()).?.object;
            const sid = self.sub_map.get(hdr.object) orelse return;
            if (self.surfaces.getPtr(sid)) |surf| {
                // We only need the parent boundary. Ordering among
                // sibling overlays remains their creation order.
                surf.sub_below = hdr.opcode == 3 and sibling == surf.subparent;
                if (self.view.subsurface_below) |cb| cb(self.view.ctx, sid, surf.sub_below);
            }
        },
        // set_sync / set_desync: pixels are copied at each commit,
        // so synchronized commit grouping is not observable here.
        4, 5 => {},
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_region) switch (hdr.opcode) {
        0 => { // destroy
            if (self.regions.getPtr(hdr.object)) |r| {
                r.deinit(self.allocator);
                _ = self.regions.remove(hdr.object);
            }
            try self.destroyObject(hdr.object);
        },
        1 => { // add(x, y, w, h)
            const slot = try self.regions.getOrPut(self.allocator, hdr.object);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            const x = (try it.next()).?.int;
            const y = (try it.next()).?.int;
            const rw = (try it.next()).?.int;
            const rh = (try it.next()).?.int;
            try slot.value_ptr.append(self.allocator, .{ .x = x, .y = y, .w = rw, .h = rh });
        },
        2 => {}, // subtract — v1 over-approximates (fails safe)
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_shm) switch (hdr.opcode) {
        0 => { // create_pool(id, fd, size) — bytes via side-band
            const id = (try it.next()).?.new_id;
            _ = (try it.next()).?; // fd placeholder
            const size = (try it.next()).?.int;
            if (size <= 0) return Error.Protocol;
            try self.register(id, &protocol.wl_shm_pool);
            // Recycled id: old buffers keep resolving to the
            // displaced incarnation via their serial.
            _ = try self.freshPool(id, @intCast(size));
        },
        // release (v2): drops the global; live pools survive it.
        1 => try self.destroyPostV8(hdr.object),
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_shm_pool) switch (hdr.opcode) {
        0 => { // create_buffer
            const id = (try it.next()).?.new_id;
            const offset = (try it.next()).?.int;
            const width = (try it.next()).?.int;
            const height = (try it.next()).?.int;
            const stride = (try it.next()).?.int;
            const format = (try it.next()).?.uint;
            // width*4 is widened to i64 first: width is client-controlled
            // i32, so the i32 multiply would overflow (UB/wrap in
            // ReleaseFast) for width > ~536M and let the guard pass.
            if (width <= 0 or height <= 0 or @as(i64, stride) < @as(i64, width) * 4 or offset < 0)
                return Error.Protocol;
            try self.register(id, &protocol.wl_buffer);
            var serial: u64 = 0;
            if (self.pools.getPtr(hdr.object)) |p| {
                p.buffers += 1;
                serial = p.serial;
            }
            try self.buffers.put(self.allocator, id, .{
                .pool = hdr.object,
                .offset = offset,
                .width = width,
                .height = height,
                .stride = stride,
                .format = format,
                .pool_serial = serial,
            });
        },
        1 => { // destroy — bytes reclaim once no buffer references them
            if (self.pools.getPtr(hdr.object)) |p| {
                if (p.buffers == 0) {
                    var pool = self.pools.fetchRemove(hdr.object).?.value;
                    pool.deinit(self.allocator);
                } else {
                    p.destroyed = true;
                }
            }
            try self.destroyObject(hdr.object);
        },
        2 => {}, // resize — side-band already grew the mirror
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_buffer) {
        // destroy — a dmabuf buffer also owns its synthetic pool
        // (pool id == buffer id); an shm buffer releases its pool
        // reference and reclaims a destroyed pool's bytes when it
        // was the last one. Both resolve by incarnation serial so
        // a recycled pool id can't cross refcounts.
        if (self.buffers.fetchRemove(hdr.object)) |kv| {
            if (kv.value.pool == hdr.object) {
                if (self.pools.getPtr(hdr.object)) |p| {
                    if (p.serial == kv.value.pool_serial) {
                        var pool = self.pools.fetchRemove(hdr.object).?.value;
                        pool.deinit(self.allocator);
                    } else {
                        self.releaseBufferRef(kv.value);
                    }
                } else {
                    self.releaseBufferRef(kv.value);
                }
            } else {
                self.releaseBufferRef(kv.value);
            }
        }
        try self.destroyObject(hdr.object);
    } else if (iface == &protocol.zwp_linux_dmabuf_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object),
        1 => { // create_params
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.zwp_linux_buffer_params_v1);
            try self.dmabuf_params.put(self.allocator, id, .{});
        },
        2 => { // get_default_feedback(id)
            const id = (try it.next()).?.new_id;
            try self.newDmabufFeedback(id, 0);
        },
        3 => { // get_surface_feedback(id, surface)
            const id = (try it.next()).?.new_id;
            const surface = (try it.next()).?.object;
            try self.newDmabufFeedback(id, surface);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_linux_dmabuf_feedback_v1) switch (hdr.opcode) {
        0 => { // destroy
            _ = self.dmabuf_feedbacks.remove(hdr.object);
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_linux_buffer_params_v1) switch (hdr.opcode) {
        0 => { // destroy
            _ = self.dmabuf_params.remove(hdr.object);
            try self.destroyObject(hdr.object);
        },
        1 => { // add(fd, plane_idx, offset, stride, mod_hi, mod_lo)
            _ = (try it.next()).?; // fd placeholder
            const plane = (try it.next()).?.uint;
            const offset = (try it.next()).?.uint;
            const stride = (try it.next()).?.uint;
            const mod_hi = (try it.next()).?.uint;
            const mod_lo = (try it.next()).?.uint;
            const p = self.dmabuf_params.getPtr(hdr.object) orelse return Error.Protocol;
            p.add(plane, .{
                .offset = offset,
                .stride = stride,
                .modifier = @as(u64, mod_hi) << 32 | mod_lo,
            }) catch return Error.Protocol;
        },
        2 => { // create (non-immed) — declined: failed → shm fallback
            const width = (try it.next()).?.int;
            const height = (try it.next()).?.int;
            const format = (try it.next()).?.uint;
            const flags = (try it.next()).?.uint;
            const p = self.dmabuf_params.getPtr(hdr.object) orelse return Error.Protocol;
            const info = p.create(width, height, format, flags) catch return Error.Protocol;
            if (!self.lenient and !dmabuf.contains(
                self.dmabuf_capabilities,
                info.format,
                info.plane.modifier,
            )) return Error.Protocol;
            _ = self.dmabuf_params.remove(hdr.object);
            var buf: [8]u8 = undefined;
            var b = wire.Builder.init(&buf, hdr.object, 1); // failed
            try self.send(try b.finish());
        },
        3 => { // create_immed(new_id, w, h, format, flags)
            const id = (try it.next()).?.new_id;
            const width = (try it.next()).?.int;
            const height = (try it.next()).?.int;
            const format = (try it.next()).?.uint;
            const flags = (try it.next()).?.uint;
            const p = self.dmabuf_params.getPtr(hdr.object) orelse return Error.Protocol;
            const info = p.create(width, height, format, flags) catch return Error.Protocol;
            if (!self.lenient and !dmabuf.contains(
                self.dmabuf_capabilities,
                info.format,
                info.plane.modifier,
            )) return Error.Protocol;
            const shm_format = dmabuf.shmFormat(info.format) orelse return Error.Protocol;
            const tight_stride_u64 = std.math.mul(u64, info.width, 4) catch return Error.Protocol;
            const pool_size_u64 = std.math.mul(u64, tight_stride_u64, info.height) catch return Error.Protocol;
            if (pool_size_u64 > dmabuf.MAX_BUFFER_BYTES or
                pool_size_u64 > std.math.maxInt(usize) or
                tight_stride_u64 > std.math.maxInt(i32))
                return Error.Protocol;
            _ = self.dmabuf_params.remove(hdr.object);
            try self.register(id, &protocol.wl_buffer);
            // The daemon importer normalizes source offset/stride
            // into a tight synthetic CPU pool for every replica.
            const pool = try self.freshPool(
                id,
                if (self.materialize_dmabuf_pools) @intCast(pool_size_u64) else 0,
            );
            pool.buffers = 1;
            try self.buffers.put(self.allocator, id, .{
                .pool = id,
                .offset = 0,
                .width = width,
                .height = height,
                .stride = @intCast(tight_stride_u64),
                .format = shm_format,
                .pool_serial = pool.serial,
            });
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_surface) {
        try surfaceRequest(self, hdr, &it);
    } else if (iface == &protocol.wl_seat) switch (hdr.opcode) {
        0 => { // get_pointer
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wl_pointer);
            try self.inheritVersion(id, hdr.object);
            try self.pointers.append(self.allocator, id);
        },
        1 => { // get_keyboard
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wl_keyboard);
            try self.inheritVersion(id, hdr.object);
            try self.keyboards.append(self.allocator, id);
            // The daemon materializes the keymap fd and emits
            // wl_keyboard.keymap(id, format, fd, size) itself.
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(self.allocator);
            var meta: [8]u8 = undefined;
            std.mem.writeInt(u32, meta[0..4], id, .little);
            std.mem.writeInt(u32, meta[4..8], 1, .little); // xkb_v1
            try payload.appendSlice(self.allocator, &meta);
            try payload.appendSlice(self.allocator, self.keymap);
            try pipe.appendUnit(&self.out, self.allocator, .keymap, payload.items);
            if (self.objVersion(id) >= 4) {
                var rbuf: [16]u8 = undefined;
                var rb = wire.Builder.init(&rbuf, id, 5); // repeat_info
                rb.putInt(30); // keys/sec
                rb.putInt(400); // delay ms
                try self.send(try rb.finish());
            }
        },
        2 => { // get_touch — registered, never speaks
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wl_touch);
            try self.inheritVersion(id, hdr.object);
        },
        3 => try self.destroyObject(hdr.object), // release (v5)
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_pointer) switch (hdr.opcode) {
        // set_cursor: accepted, ignored — the local pointer
        // keeps its native cursor in v1. The cursor surface
        // (no xdg role) renders nowhere by design.
        0 => {},
        1 => { // release
            removeId(&self.pointers, hdr.object);
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_keyboard or iface == &protocol.wl_touch) {
        // release — the only request on both.
        removeId(&self.keyboards, hdr.object);
        try self.destroyObject(hdr.object);
    } else if (iface == &protocol.wl_output) {
        // release — lenient even though we advertise v2.
        try self.destroyObject(hdr.object);
    } else if (iface == &protocol.zxdg_output_manager_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object),
        1 => { // get_xdg_output(id, output)
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.zxdg_output_v1);
            try self.sendXdgOutputState(id);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zxdg_output_v1) {
        // destroy — the only request.
        try self.destroyObject(hdr.object);
    } else if (iface == &protocol.wp_cursor_shape_manager_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object),
        1, 2 => { // get_pointer / get_tablet_tool_v2
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wp_cursor_shape_device_v1);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wp_cursor_shape_device_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object),
        1 => { // set_shape(serial, shape)
            _ = (try it.next()).?; // serial
            const shape = (try it.next()).?.uint;
            if (self.view.cursor_shape) |cb| cb(self.view.ctx, shape);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wp_viewporter) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object),
        1 => { // get_viewport(id, surface)
            const id = (try it.next()).?.new_id;
            const sid = (try it.next()).?.object;
            try self.register(id, &protocol.wp_viewport);
            try self.viewport_map.put(self.allocator, id, sid);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wp_viewport) switch (hdr.opcode) {
        0 => { // destroy — the surface reverts to buffer-derived size
            if (self.viewport_map.fetchRemove(hdr.object)) |kv| {
                if (self.surfaces.getPtr(kv.value)) |surf| {
                    surf.vp_w = 0;
                    surf.vp_h = 0;
                }
            }
            try self.destroyObject(hdr.object);
        },
        1 => {}, // set_source — full-buffer scope, accepted
        2 => { // set_destination(w, h) — the surface's LOGICAL size
            const vw = (try it.next()).?.int;
            const vh = (try it.next()).?.int;
            const sid = self.viewport_map.get(hdr.object) orelse return Error.Protocol;
            if (self.surfaces.getPtr(sid)) |surf| {
                // -1,-1 unsets per spec.
                surf.vp_w = if (vw > 0) vw else 0;
                surf.vp_h = if (vh > 0) vh else 0;
            }
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wp_fractional_scale_manager_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object),
        1 => { // get_fractional_scale(id, surface)
            const id = (try it.next()).?.new_id;
            const sid = (try it.next()).?.object;
            try self.register(id, &protocol.wp_fractional_scale_v1);
            try self.fs_map.put(self.allocator, id, sid);
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, id, 0); // preferred_scale
            b.putUint(self.effScale120());
            try self.send(try b.finish());
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wp_fractional_scale_v1) switch (hdr.opcode) {
        0 => { // destroy
            _ = self.fs_map.remove(hdr.object);
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zxdg_decoration_manager_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object),
        1 => { // get_toplevel_decoration(id, xdg_toplevel)
            const id = (try it.next()).?.new_id;
            const tl = (try it.next()).?.object;
            const sid = self.xdg_map.get(tl) orelse return Error.Protocol;
            try self.register(id, &protocol.zxdg_toplevel_decoration_v1);
            try self.xdg_map.put(self.allocator, id, sid);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zxdg_toplevel_decoration_v1) switch (hdr.opcode) {
        0 => { // destroy
            _ = self.xdg_map.remove(hdr.object);
            try self.destroyObject(hdr.object);
        },
        1, 2 => { // set_mode(u) / unset_mode
            var mode: u32 = 2; // unset → we prefer server-side
            if (hdr.opcode == 1) mode = (try it.next()).?.uint;
            if (mode != 1) mode = 2;
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, hdr.object, 0); // configure
            b.putUint(mode);
            try self.send(try b.finish());
            if (self.xdg_map.get(hdr.object)) |sid| {
                if (self.surfaces.getPtr(sid)) |surf| surf.deco = @intCast(mode);
                if (self.view.toplevel_decoration) |cb| cb(self.view.ctx, sid, mode == 2);
            }
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_data_device_manager) switch (hdr.opcode) {
        0 => { // create_data_source
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wl_data_source);
            try self.data_sources.put(self.allocator, id, .empty);
        },
        1 => { // get_data_device(id, seat)
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wl_data_device);
            try self.data_devices.append(self.allocator, id);
        },
        // release (v4): drops the global; live sources and
        // devices keep working.
        2 => try self.destroyPostV8(hdr.object),
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_data_source) switch (hdr.opcode) {
        0 => { // offer(mime)
            const mime = (try it.next()).?.string orelse return Error.Protocol;
            const mimes = self.data_sources.getPtr(hdr.object) orelse return Error.Protocol;
            const owned = try self.allocator.dupe(u8, mime);
            errdefer self.allocator.free(owned);
            try mimes.append(self.allocator, owned);
        },
        1 => { // destroy
            if (self.data_sources.getPtr(hdr.object)) |mimes| {
                for (mimes.items) |m| self.allocator.free(m);
                mimes.deinit(self.allocator);
                _ = self.data_sources.remove(hdr.object);
            }
            _ = self.source_actions.remove(hdr.object);
            if (self.drag.source == hdr.object) {
                if (self.drag.active) try self.dragLeave();
                self.drag = .{};
            }
            try self.destroyObject(hdr.object);
        },
        2 => { // set_actions(actions) — stored for dnd negotiation
            const acts = (try it.next()).?.uint;
            try self.source_actions.put(self.allocator, hdr.object, acts);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_data_device) switch (hdr.opcode) {
        0 => { // start_drag(?source, origin, ?icon, serial)
            const source = (try it.next()).?.object;
            const origin = (try it.next()).?.object;
            if (self.drag.active or !self.surfaces.contains(origin)) return;
            // No held button = nothing to release; refuse inert.
            if (self.pressed_button == 0) {
                if (source != 0) {
                    var buf: [8]u8 = undefined;
                    var b = wire.Builder.init(&buf, source, 2); // cancelled
                    try self.send(try b.finish());
                }
                return;
            }
            // The pointer leaves the origin surface for the drag.
            const px = self.last_px;
            const py = self.last_py;
            try self.pointerLeave();
            self.drag = .{ .active = true, .source = source, .origin = origin };
            try self.dragEnter(origin, px, py);
        },
        1 => { // set_selection(?source, serial)
            const source = (try it.next()).?.object;
            if (source != 0) {
                if (self.bestTextMime(source)) |mime| {
                    if (self.view.clipboard_offer) |cb| cb(self.view.ctx, source, mime);
                }
            }
        },
        2 => { // release
            removeId(&self.data_devices, hdr.object);
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.wl_data_offer) switch (hdr.opcode) {
        0 => { // accept(serial, ?mime) — dnd target feedback
            if (hdr.object == self.drag.offer and self.drag.offer != 0) {
                _ = (try it.next()).?; // serial
                const mime = (try it.next()).?.string;
                self.drag.accepted = mime != null;
                if (self.drag.source != 0) {
                    const mime_len = if (mime) |m| m.len else 0;
                    const cap = wire.header_size + 4 + ((mime_len + 1 + 3) & ~@as(usize, 3));
                    if (cap > 0xffff) return Error.Protocol;
                    const buf = try self.allocator.alloc(u8, cap);
                    defer self.allocator.free(buf);
                    var b = wire.Builder.init(buf, self.drag.source, 0); // target
                    b.putString(mime);
                    try self.send(try b.finish());
                }
            }
        },
        1 => { // receive(mime, fd) — host-drop offers answer from
            // the stored payload (drop_data); within-app dnd
            // offers pull from the SOURCE (dnd_send); selection
            // offers paste the HOST clipboard.
            const mime = (try it.next()).?.string orelse return Error.Protocol;
            if (hdr.object == self.host_drag.offer and self.host_drag.offer != 0) {
                var payload: std.ArrayList(u8) = .empty;
                defer payload.deinit(self.allocator);
                var idb: [4]u8 = undefined;
                std.mem.writeInt(u32, &idb, self.host_drag.offer, .little);
                try payload.appendSlice(self.allocator, &idb);
                try payload.appendSlice(self.allocator, self.host_drag.data);
                try pipe.appendUnit(&self.out, self.allocator, .drop_data, payload.items);
            } else if (hdr.object == self.drag.offer and self.drag.source != 0) {
                var payload: std.ArrayList(u8) = .empty;
                defer payload.deinit(self.allocator);
                var idb: [8]u8 = undefined;
                std.mem.writeInt(u32, idb[0..4], self.drag.source, .little);
                std.mem.writeInt(u32, idb[4..8], hdr.object, .little);
                try payload.appendSlice(self.allocator, &idb);
                try payload.appendSlice(self.allocator, mime);
                try pipe.appendUnit(&self.out, self.allocator, .dnd_send, payload.items);
            } else if (self.view.clipboard_read) |cb| cb(self.view.ctx, mime);
        },
        2 => { // destroy
            if (hdr.object == self.host_drag.offer) self.host_drag.free(self.allocator);
            if (hdr.object == self.drag.offer) self.drag.offer = 0;
            if (self.drag.dropped and !self.drag.active) self.drag = .{};
            try self.destroyObject(hdr.object);
        },
        3 => { // finish — dnd transfer complete
            if (hdr.object == self.host_drag.offer) self.host_drag.free(self.allocator);
            if (hdr.object == self.drag.offer and self.drag.source != 0) {
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, self.drag.source, 4); // dnd_finished
                try self.send(try b.finish());
                self.drag = .{};
            }
        },
        4 => { // set_actions(actions, preferred) — negotiate
            if (hdr.object == self.drag.offer and self.drag.offer != 0) {
                const acts = (try it.next()).?.uint;
                const preferred = (try it.next()).?.uint;
                const src = self.source_actions.get(self.drag.source) orelse 0;
                const overlap = acts & src;
                const chosen: u32 = if (preferred & overlap != 0)
                    preferred
                else if (overlap & 1 != 0)
                    1 // copy
                else if (overlap & 2 != 0)
                    2 // move
                else
                    0;
                self.drag.action = chosen;
                var obuf: [16]u8 = undefined;
                var ob = wire.Builder.init(&obuf, hdr.object, 2); // action
                ob.putUint(chosen);
                try self.send(try ob.finish());
                if (self.drag.source != 0) {
                    var sbuf: [16]u8 = undefined;
                    var sb = wire.Builder.init(&sbuf, self.drag.source, 5); // action
                    sb.putUint(chosen);
                    try self.send(try sb.finish());
                }
            }
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwlr_data_control_manager_v1) switch (hdr.opcode) {
        0 => { // create_data_source
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.zwlr_data_control_source_v1);
            try self.data_sources.put(self.allocator, id, .empty);
        },
        1 => { // get_data_device(id, seat)
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.zwlr_data_control_device_v1);
            try self.data_control_devices.append(self.allocator, id);
            // The protocol requires advertising the current
            // selection right after the device is created — a
            // data-control client (wl-paste) has no focus event to
            // trigger offerSelection, so send it now.
            try self.offerToDevice(id, "text/plain;charset=utf-8", true);
        },
        2 => try self.destroyObject(hdr.object), // destroy
        else => return Error.Protocol,
    } else if (iface == &protocol.zwlr_data_control_source_v1) switch (hdr.opcode) {
        0 => { // offer(mime) — same store as wl_data_source
            const mime = (try it.next()).?.string orelse return Error.Protocol;
            const mimes = self.data_sources.getPtr(hdr.object) orelse return Error.Protocol;
            const owned = try self.allocator.dupe(u8, mime);
            errdefer self.allocator.free(owned);
            try mimes.append(self.allocator, owned);
        },
        1 => { // destroy
            if (self.data_sources.getPtr(hdr.object)) |mimes| {
                for (mimes.items) |m| self.allocator.free(m);
                mimes.deinit(self.allocator);
                _ = self.data_sources.remove(hdr.object);
            }
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwlr_data_control_device_v1) switch (hdr.opcode) {
        0 => { // set_selection(?source) — no serial, unlike wl
            const source = (try it.next()).?.object;
            if (source != 0) {
                if (self.bestTextMime(source)) |mime| {
                    if (self.view.clipboard_offer) |cb| cb(self.view.ctx, source, mime);
                }
            }
        },
        1 => { // destroy
            removeId(&self.data_control_devices, hdr.object);
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwlr_data_control_offer_v1) switch (hdr.opcode) {
        0 => { // receive(mime, fd) — same paste path as wl_data_offer
            const mime = (try it.next()).?.string orelse return Error.Protocol;
            if (self.view.clipboard_read) |cb| cb(self.view.ctx, mime);
        },
        1 => try self.destroyObject(hdr.object), // destroy
        else => return Error.Protocol,
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
        const pos = blk: {
            const slot = try self.positioners.getOrPut(self.allocator, hdr.object);
            if (!slot.found_existing) slot.value_ptr.* = .{};
            break :blk slot.value_ptr;
        };
        switch (hdr.opcode) {
            0 => { // destroy
                _ = self.positioners.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1 => { // set_size
                pos.w = (try it.next()).?.int;
                pos.h = (try it.next()).?.int;
            },
            2 => { // set_anchor_rect
                pos.ax = (try it.next()).?.int;
                pos.ay = (try it.next()).?.int;
                pos.aw = (try it.next()).?.int;
                pos.ah = (try it.next()).?.int;
            },
            3 => pos.anchor = (try it.next()).?.uint,
            4 => pos.gravity = (try it.next()).?.uint,
            6 => { // set_offset
                pos.ox = (try it.next()).?.int;
                pos.oy = (try it.next()).?.int;
            },
            // constraint_adjustment / reactive / parent_size /
            // parent_configure: accepted, unused in v1.
            5, 7, 8, 9 => {},
            else => return Error.Protocol,
        }
    } else if (iface == &protocol.xdg_popup) {
        const sid = self.xdg_map.get(hdr.object) orelse return Error.Protocol;
        switch (hdr.opcode) {
            0 => { // destroy
                if (self.grabbed_popup == sid) self.grabbed_popup = 0;
                if (self.surfaces.getPtr(sid)) |surf| {
                    surf.popup = 0;
                    surf.configured = false;
                }
                if (self.view.popup_gone) |cb| cb(self.view.ctx, sid);
                _ = self.xdg_map.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1 => { // grab(seat, serial)
                self.grabbed_popup = sid;
            },
            2 => { // reposition(positioner, token)
                const pos_id = (try it.next()).?.object;
                const token = (try it.next()).?.uint;
                const pos = self.positioners.get(pos_id) orelse return Error.Protocol;
                const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
                const at = pos.place();
                surf.px = at[0];
                surf.py = at[1];
                surf.pw = pos.w;
                surf.ph = pos.h;
                var rbuf: [16]u8 = undefined;
                var rb = wire.Builder.init(&rbuf, hdr.object, 2); // repositioned
                rb.putUint(token);
                try self.send(try rb.finish());
                var cbuf: [32]u8 = undefined;
                var cb = wire.Builder.init(&cbuf, hdr.object, 0); // configure
                cb.putInt(surf.px);
                cb.putInt(surf.py);
                cb.putInt(surf.pw);
                cb.putInt(surf.ph);
                try self.send(try cb.finish());
                var sbuf: [16]u8 = undefined;
                var sb = wire.Builder.init(&sbuf, surf.xdg_surface, 0); // configure
                sb.putUint(self.nextSerial());
                try self.send(try sb.finish());
                if (self.view.popup_moved) |vcb|
                    vcb(self.view.ctx, sid, surf.parent, at[0], at[1]);
            },
            else => return Error.Protocol,
        }
    } else if (iface == &protocol.xdg_surface) {
        try xdgSurfaceRequest(self, hdr, &it);
    } else if (iface == &protocol.xdg_toplevel) {
        try toplevelRequest(self, hdr, body, &it);
    } else if (iface == &protocol.zwp_primary_selection_device_manager_v1) switch (hdr.opcode) {
        0 => { // create_source
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.zwp_primary_selection_source_v1);
            try self.data_sources.put(self.allocator, id, .empty);
        },
        1 => { // get_device(id, seat)
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.zwp_primary_selection_device_v1);
            try self.primary_devices.append(self.allocator, id);
        },
        2 => try self.destroyObject(hdr.object), // destroy
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_primary_selection_source_v1) switch (hdr.opcode) {
        0 => { // offer(mime) — same store as wl_data_source
            const mime = (try it.next()).?.string orelse return Error.Protocol;
            const mimes = self.data_sources.getPtr(hdr.object) orelse return Error.Protocol;
            const owned = try self.allocator.dupe(u8, mime);
            errdefer self.allocator.free(owned);
            try mimes.append(self.allocator, owned);
        },
        1 => { // destroy
            if (self.data_sources.getPtr(hdr.object)) |mimes| {
                for (mimes.items) |m| self.allocator.free(m);
                mimes.deinit(self.allocator);
                _ = self.data_sources.remove(hdr.object);
            }
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_primary_selection_device_v1) switch (hdr.opcode) {
        0 => { // set_selection(?source, serial)
            const source = (try it.next()).?.object;
            if (source != 0) {
                if (self.bestTextMime(source)) |mime| {
                    if (self.view.primary_offer) |cb| cb(self.view.ctx, source, mime);
                }
            }
        },
        1 => { // destroy
            removeId(&self.primary_devices, hdr.object);
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_primary_selection_offer_v1) switch (hdr.opcode) {
        0 => { // receive(mime, fd) — host PRIMARY selection paste
            const mime = (try it.next()).?.string orelse return Error.Protocol;
            if (self.view.primary_read) |cb| cb(self.view.ctx, mime);
        },
        1 => try self.destroyObject(hdr.object), // destroy
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_relative_pointer_manager_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object), // destroy
        1 => { // get_relative_pointer(id, pointer)
            const id = (try it.next()).?.new_id;
            const ptr = (try it.next()).?.object;
            try self.register(id, &protocol.zwp_relative_pointer_v1);
            try self.rel_pointers.append(self.allocator, .{ .id = id, .pointer = ptr });
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_relative_pointer_v1) switch (hdr.opcode) {
        0 => { // destroy
            for (self.rel_pointers.items, 0..) |rp, i| {
                if (rp.id == hdr.object) {
                    _ = self.rel_pointers.swapRemove(i);
                    break;
                }
            }
            try self.destroyObject(hdr.object);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_pointer_constraints_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object), // destroy
        1, 2 => { // lock_pointer / confine_pointer(id, surface, pointer, ?region, lifetime)
            const id = (try it.next()).?.new_id;
            const sid = (try it.next()).?.object;
            _ = (try it.next()).?; // pointer
            _ = (try it.next()).?; // region — whole surface in scope
            const lifetime = (try it.next()).?.uint;
            const kind: u8 = if (hdr.opcode == 1) 0 else 1;
            try self.register(id, if (kind == 0)
                &protocol.zwp_locked_pointer_v1
            else
                &protocol.zwp_confined_pointer_v1);
            try self.constraints.put(self.allocator, id, .{
                .sid = sid,
                .kind = kind,
                .lifetime = lifetime,
            });
            // Already hovering the surface: activate immediately.
            if (self.pointer_focus == sid) try self.activateConstraints(sid);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_locked_pointer_v1 or
        iface == &protocol.zwp_confined_pointer_v1)
    {
        switch (hdr.opcode) {
            0 => { // destroy
                if (self.constraints.getPtr(hdr.object)) |con| {
                    if (con.active and con.kind == 0) {
                        if (self.view.pointer_locked) |cb| cb(self.view.ctx, con.sid, false);
                    }
                    _ = self.constraints.remove(hdr.object);
                }
                try self.destroyObject(hdr.object);
            },
            // set_cursor_position_hint / set_region: accepted,
            // unused (whole-surface constraints, host cursor).
            else => {},
        }
    } else if (iface == &protocol.zwp_text_input_manager_v3) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object), // destroy
        1 => { // get_text_input(id, seat)
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.zwp_text_input_v3);
            try self.text_inputs.put(self.allocator, id, .{});
            if (self.keyboard_focus != 0) {
                var buf: [16]u8 = undefined;
                var b = wire.Builder.init(&buf, id, 0); // enter
                b.putObject(self.keyboard_focus);
                try self.send(try b.finish());
            }
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_text_input_v3) {
        const ti = self.text_inputs.getPtr(hdr.object) orelse return Error.Protocol;
        switch (hdr.opcode) {
            0 => { // destroy
                if (ti.enabled) {
                    if (self.view.text_input_active) |cb| cb(self.view.ctx, false);
                }
                _ = self.text_inputs.remove(hdr.object);
                try self.destroyObject(hdr.object);
            },
            1 => ti.pending_enabled = true, // enable
            2 => ti.pending_enabled = false, // disable
            // surrounding text / change cause / content type /
            // cursor rectangle: accepted (no IM popup to place).
            3, 4, 5, 6 => {},
            7 => { // commit — latch double-buffered state
                ti.serial +%= 1;
                if (ti.enabled != ti.pending_enabled) {
                    ti.enabled = ti.pending_enabled;
                    if (self.view.text_input_active) |cb| cb(self.view.ctx, ti.enabled);
                }
            },
            else => return Error.Protocol,
        }
    } else if (iface == &protocol.xdg_activation_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object), // destroy
        1 => { // get_activation_token
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.xdg_activation_token_v1);
        },
        2 => { // activate(token, surface)
            _ = (try it.next()).?; // token — minted freely, not checked
            const sid = (try it.next()).?.object;
            if (self.surfaces.contains(sid)) {
                if (self.view.toplevel_raise) |cb| cb(self.view.ctx, sid);
            }
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.xdg_activation_token_v1) switch (hdr.opcode) {
        0, 1, 2 => {}, // set_serial / set_app_id / set_surface
        3 => { // commit → done(token)
            var tok: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&tok, "sketerm-{d}", .{self.nextSerial()}) catch
                return Error.Protocol;
            var buf: [64]u8 = undefined;
            var b = wire.Builder.init(&buf, hdr.object, 0); // done
            b.putString(s);
            try self.send(try b.finish());
        },
        4 => try self.destroyObject(hdr.object), // destroy
        else => return Error.Protocol,
    } else if (iface == &protocol.wp_presentation) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object), // destroy
        1 => { // feedback(surface, id)
            const sid = (try it.next()).?.object;
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.wp_presentation_feedback);
            if (self.surfaces.getPtr(sid)) |surf| {
                try surf.feedbacks.append(self.allocator, id);
            } else {
                // Unknown surface: discard immediately.
                var buf: [8]u8 = undefined;
                var b = wire.Builder.init(&buf, id, 2); // discarded
                try self.send(try b.finish());
                try self.deleteId(id);
            }
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_idle_inhibit_manager_v1) switch (hdr.opcode) {
        0 => try self.destroyObject(hdr.object), // destroy
        1 => { // create_inhibitor(id, surface) — tracked, inert
            const id = (try it.next()).?.new_id;
            try self.register(id, &protocol.zwp_idle_inhibitor_v1);
        },
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_idle_inhibitor_v1) {
        try self.destroyObject(hdr.object); // destroy (only request)
    } else if (iface == &protocol.zwp_pointer_gestures_v1) switch (hdr.opcode) {
        0, 1, 3 => { // get_{swipe,pinch,hold}_gesture(id, pointer)
            const id = (try it.next()).?.new_id;
            try self.register(id, switch (hdr.opcode) {
                0 => &protocol.zwp_pointer_gesture_swipe_v1,
                1 => &protocol.zwp_pointer_gesture_pinch_v1,
                else => &protocol.zwp_pointer_gesture_hold_v1,
            });
        },
        2 => try self.destroyObject(hdr.object), // release
        else => return Error.Protocol,
    } else if (iface == &protocol.zwp_pointer_gesture_swipe_v1 or
        iface == &protocol.zwp_pointer_gesture_pinch_v1 or
        iface == &protocol.zwp_pointer_gesture_hold_v1)
    {
        try self.destroyObject(hdr.object); // destroy (only request)
    } else {
        return Error.Protocol;
    }
}

pub fn surfaceRequest(self: *Compositor, hdr: wire.Header, it: *wire.ArgIter) Error!void {
    const surf = self.surfaces.getPtr(hdr.object) orelse return Error.Protocol;
    switch (hdr.opcode) {
        0 => { // destroy
            if (surf.toplevel != 0) self.notifyGone(hdr.object);
            if (surf.popup != 0) {
                if (self.grabbed_popup == hdr.object) self.grabbed_popup = 0;
                if (self.view.popup_gone) |cb| cb(self.view.ctx, hdr.object);
            }
            if (surf.subparent != 0) {
                if (self.view.subsurface_gone) |cb| cb(self.view.ctx, hdr.object);
            }
            if (self.pointer_focus == hdr.object) self.pointer_focus = 0;
            if (self.keyboard_focus == hdr.object) self.keyboard_focus = 0;
            // Constraints on a dead surface are defunct (their
            // objects survive until the client destroys them).
            var cit = self.constraints.valueIterator();
            while (cit.next()) |con| {
                if (con.sid == hdr.object) con.active = false;
            }
            if (self.drag.active and
                (self.drag.focus == hdr.object or self.drag.origin == hdr.object))
            {
                self.drag.focus = 0;
                try self.dragDrop(); // cancels (focus is gone)
            }
            surf.freeOwned(self.allocator);
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
        11 => { // get_release(callback) — v7 buffer-release callback
            const cb = (try it.next()).?.new_id;
            self.used_post_v8_request = true;
            try self.register(cb, &protocol.wl_callback);
            try surf.release_cbs.append(self.allocator, cb);
        },
        5 => { // set_input_region(?region) — staged until commit
            const region = (try it.next()).?.object;
            surf.input_pending = true;
            surf.input_rects.clearRetainingCapacity();
            if (region == 0) {
                surf.input_whole = true;
            } else {
                surf.input_whole = false;
                if (self.regions.get(region)) |rects| {
                    try surf.input_rects.appendSlice(self.allocator, rects.items);
                }
            }
        },
        6 => try commit(self, hdr.object, surf),
        8 => { // set_buffer_scale(scale) — HiDPI buffers
            const sc = (try it.next()).?.int;
            surf.buffer_scale = if (sc > 0) sc else 1;
        },
        // damage/damage_buffer/opaque-region/transform/offset:
        // accepted, ignored (full-copy pipeline).
        2, 4, 7, 9, 10 => {},
        else => return Error.Protocol,
    }
}

pub fn xdgSurfaceRequest(self: *Compositor, hdr: wire.Header, it: *wire.ArgIter) Error!void {
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
            // Tell the surface it's on our output so GTK3 reads the
            // scale (without it GTK3 renders mis-scaled / half-height).
            if (self.output_id != 0) {
                var ebuf: [16]u8 = undefined;
                var eb = wire.Builder.init(&ebuf, sid, 0); // wl_surface.enter
                eb.putObject(self.output_id);
                try self.send(try eb.finish());
            }
            if (self.view.toplevel_new) |cb| cb(self.view.ctx, sid);
        },
        2 => { // get_popup(id, parent, positioner)
            const id = (try it.next()).?.new_id;
            const parent_xdg = (try it.next()).?.object;
            const pos_id = (try it.next()).?.object;
            if (parent_xdg == 0) return Error.Protocol; // v1: explicit parent only
            const parent_sid = self.xdg_map.get(parent_xdg) orelse return Error.Protocol;
            const pos = self.positioners.get(pos_id) orelse return Error.Protocol;
            const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
            if (surf.toplevel != 0 or surf.popup != 0) return Error.Protocol;
            try self.register(id, &protocol.xdg_popup);
            try self.xdg_map.put(self.allocator, id, sid);
            const at = pos.place();
            surf.popup = id;
            surf.parent = parent_sid;
            surf.px = at[0];
            surf.py = at[1];
            surf.pw = pos.w;
            surf.ph = pos.h;
            if (self.view.popup_new) |cb| cb(self.view.ctx, sid, parent_sid, at[0], at[1]);
        },
        3 => { // set_window_geometry(x, y, w, h) — staged
            const surf = self.surfaces.getPtr(sid) orelse return Error.Protocol;
            surf.geo_pending = true;
            surf.geo_next = .{
                .x = (try it.next()).?.int,
                .y = (try it.next()).?.int,
                .w = (try it.next()).?.int,
                .h = (try it.next()).?.int,
            };
        },
        4 => {}, // ack_configure
        else => return Error.Protocol,
    }
}

pub fn toplevelRequest(self: *Compositor, hdr: wire.Header, body: []const u8, it: *wire.ArgIter) Error!void {
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
            if (self.surfaces.getPtr(sid)) |surf| {
                const copy = try self.allocator.dupe(u8, title);
                if (surf.title) |old| self.allocator.free(old);
                surf.title = copy;
            }
            if (self.view.toplevel_title) |cb| cb(self.view.ctx, sid, title);
        },
        3 => { // set_app_id(s)
            const app_id = (try it.next()).?.string orelse return;
            if (self.surfaces.getPtr(sid)) |surf| {
                const copy = try self.allocator.dupe(u8, app_id);
                if (surf.app_id) |old| self.allocator.free(old);
                surf.app_id = copy;
            }
            if (self.view.toplevel_app_id) |cb| cb(self.view.ctx, sid, app_id);
        },
        1 => { // set_parent(?toplevel)
            const ptl = (try it.next()).?.object;
            const psid = if (ptl != 0) (self.xdg_map.get(ptl) orelse 0) else 0;
            if (self.surfaces.getPtr(sid)) |surf| surf.tl_parent = psid;
            if (self.view.toplevel_parent) |cb| cb(self.view.ctx, sid, psid);
        },
        8 => { // set_min_size(w, h)
            const mw = (try it.next()).?.int;
            const mh = (try it.next()).?.int;
            if (self.surfaces.getPtr(sid)) |surf| {
                surf.min_w = mw;
                surf.min_h = mh;
            }
            if (self.view.toplevel_min_size) |cb| cb(self.view.ctx, sid, mw, mh);
        },
        9, 10, 12, 13 => { // maximize / unmaximize / unfullscreen / minimize
            const op: u8 = switch (hdr.opcode) {
                9 => 1,
                10 => 2,
                12 => 4,
                else => 5,
            };
            if (self.view.toplevel_state_request) |cb| cb(self.view.ctx, sid, op);
        },
        11 => { // set_fullscreen(?output)
            if (self.view.toplevel_state_request) |cb| cb(self.view.ctx, sid, 3);
        },
        5 => { // move(seat, serial) — app-initiated window drag
            if (self.view.toplevel_move) |cb| cb(self.view.ctx, sid);
        },
        6 => { // resize(seat, serial, edges)
            _ = (try it.next()).?; // seat
            _ = (try it.next()).?; // serial
            const edges = (try it.next()).?.uint;
            if (self.view.toplevel_resize) |cb| cb(self.view.ctx, sid, edges);
        },
        // show_window_menu needs a real GdkEvent to forward —
        // there is none for synthetic input; set_max_size has
        // no GTK4 window API. Both accepted and dropped.
        4, 7 => {},
        else => return Error.Protocol,
    }
}

/// Latch pending state, push pixels to the view, fire frame
/// callbacks, release the buffer. The xdg dance: the first
/// commit WITHOUT a buffer triggers the initial configure.
pub fn commit(self: *Compositor, sid: u32, surf: *Surface) Error!void {
    // A buffer is copied + released exactly once: on the commit
    // that attaches it. A commit WITHOUT a fresh attach (frame
    // callback / damage-only repaint — common in GTK on cursor
    // and hover redraws) keeps the same content and must NOT
    // re-release. Releasing the same wl_buffer twice underflows
    // the client's cairo surface refcount and aborts the app
    // (cairo_surface_reference assertion).
    const took_buffer = surf.has_pending;
    // get_release is only legal in a content update that attaches
    // a non-null buffer; otherwise nothing would ever release and
    // the callback would dangle forever.
    if (surf.release_cbs.items.len > 0 and
        !(surf.has_pending and surf.pending_buffer != 0))
    {
        try self.fatalCode(sid, 5, "wl_surface.get_release without an attached buffer");
        return;
    }
    if (surf.has_pending) {
        surf.committed_buffer = surf.pending_buffer;
        surf.has_pending = false;
    }
    if (surf.geo_pending) {
        surf.geo_pending = false;
        surf.geo = surf.geo_next;
        if (self.view.toplevel_geometry) |cb|
            cb(self.view.ctx, sid, surf.geo.x, surf.geo.y, surf.geo.w, surf.geo.h);
    }
    if (surf.input_pending) {
        surf.input_pending = false;
        if (self.view.input_region) |cb| {
            cb(self.view.ctx, sid, if (surf.input_whole) null else surf.input_rects.items);
        }
    }

    if (surf.xdg_surface != 0 and !surf.configured) {
        surf.configured = true;
        if (surf.toplevel != 0) {
            if (self.wm_base_version >= 4) {
                const logical = self.logicalOutputSize();
                var bbuf: [24]u8 = undefined;
                var bb = wire.Builder.init(&bbuf, surf.toplevel, 2); // configure_bounds
                bb.putInt(logical[0]);
                bb.putInt(logical[1]);
                try self.send(try bb.finish());
            }
            if (self.wm_base_version >= 5) {
                var cbuf: [32]u8 = undefined;
                var cb = wire.Builder.init(&cbuf, surf.toplevel, 3); // wm_capabilities
                var caps: [12]u8 = undefined;
                std.mem.writeInt(u32, caps[0..4], 2, .little); // maximize
                std.mem.writeInt(u32, caps[4..8], 3, .little); // fullscreen
                std.mem.writeInt(u32, caps[8..12], 4, .little); // minimize
                cb.putArray(&caps);
                try self.send(try cb.finish());
            }
            var buf: [64]u8 = undefined;
            var b = wire.Builder.init(&buf, surf.toplevel, 0); // configure
            b.putInt(0); // width: client decides
            b.putInt(0);
            var states: [4]u8 = undefined;
            std.mem.writeInt(u32, &states, 4, .little); // activated
            b.putArray(&states);
            try self.send(try b.finish());
        } else if (surf.popup != 0) {
            var buf: [32]u8 = undefined;
            var b = wire.Builder.init(&buf, surf.popup, 0); // configure
            b.putInt(surf.px);
            b.putInt(surf.py);
            b.putInt(surf.pw);
            b.putInt(surf.ph);
            try self.send(try b.finish());
        }
        var buf2: [16]u8 = undefined;
        var b2 = wire.Builder.init(&buf2, surf.xdg_surface, 0); // configure
        b2.putUint(self.nextSerial());
        try self.send(try b2.finish());
    }

    if (took_buffer and surf.committed_buffer != 0) {
        if (self.buffers.get(surf.committed_buffer)) |info| {
            // Only mapped surfaces (toplevel/popup/subsurface role)
            // reach the view — cursor surfaces (set_cursor, no role)
            // commit buffers too and must NOT become windows.
            if (surf.toplevel != 0 or surf.popup != 0 or surf.subparent != 0)
                try pushFrame(self, sid, info);
            // Released immediately: pixels were copied out (or
            // ignored — either way we won't read them later).
            var buf: [8]u8 = undefined;
            var b = wire.Builder.init(&buf, surf.committed_buffer, 0); // release
            try self.send(try b.finish());
        }
        // Same instant as the buffer release, by definition.
        for (surf.release_cbs.items) |cb| {
            var buf: [16]u8 = undefined;
            var b = wire.Builder.init(&buf, cb, 0); // done
            b.putUint(0); // callback_data is unused, always zero
            try self.send(try b.finish());
            try self.deleteId(cb);
        }
        surf.release_cbs.clearRetainingCapacity();
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

    // Presentation feedbacks: answered at commit time with the
    // brain clock (frame-callback timing, not real vsync — no
    // flags claimed). One-shot: server-destroyed after the event.
    for (surf.feedbacks.items) |fb| {
        var buf: [48]u8 = undefined;
        var b = wire.Builder.init(&buf, fb, 1); // presented
        b.putUint(0); // tv_sec_hi
        b.putUint(self.now_ms / 1000); // tv_sec_lo
        b.putUint((self.now_ms % 1000) * 1_000_000); // tv_nsec
        b.putUint(16_666_666); // refresh (60 Hz)
        b.putUint(0); // seq_hi
        b.putUint(0); // seq_lo
        b.putUint(0); // flags
        try self.send(try b.finish());
        try self.deleteId(fb);
    }
    surf.feedbacks.clearRetainingCapacity();
}

/// Copy the committed pixels tightly packed and hand them to the
/// view. Bounds are clamped against the mirror, not trusted.
///
/// The FULL buffer is sent — CSD shadow included — so the host
/// shows the app's real drop shadow. The shadow is kept out of the
/// WM's window geometry (snapping/maximize hit the real edge) by
/// the view reporting it as the host toplevel's shadow width; the
/// committed window-geometry rect rides along via toplevel_geometry.
pub fn pushFrame(self: *Compositor, sid: u32, info: Buffer) Error!void {
    const cb = self.view.toplevel_frame orelse return;
    const pool = self.poolFor(info) orelse return;
    var scale: i32 = 1;
    var lw: i32 = info.width;
    var lh: i32 = info.height;
    if (self.surfaces.getPtr(sid)) |s| {
        scale = s.buffer_scale;
        if (s.vp_w > 0 and s.vp_h > 0) {
            // Viewport destination IS the logical size — the
            // fractional-scale path (buffer_scale stays 1).
            lw = s.vp_w;
            lh = s.vp_h;
        } else {
            lw = @divTrunc(info.width, @max(1, scale));
            lh = @divTrunc(info.height, @max(1, scale));
        }
    }
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
    cb(self.view.ctx, sid, @intCast(w), @intCast(h), scale, lw, lh, info.format, self.frame_scratch.items);
}

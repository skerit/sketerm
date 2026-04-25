//! Kitty graphics protocol receive-side accumulator.
//!
//! Handles:
//! - Multi-chunk transmissions (`m=1` until `m=0`)
//! - Format 24 (RGB), 32 (RGBA), 100 (PNG via stb_image)
//! - Action `a=t` (transmit only, store keyed by image_id)
//! - Action `a=T` (transmit + place at cursor)
//! - Action `a=p` (place by image_id)
//! - Transmission medium `t=d` (direct base64) and `t=t`/`t=f` (file path)
//!
//! Not yet:
//! - `o=z` zlib decompression
//! - Animation frames (`a=f`)
//! - Unicode placeholders

const std = @import("std");
const c = @import("../c.zig").c;
const kitty = @import("../parser/kitty_image.zig");

pub const StoredImage = struct {
    rgba: []u8,
    width: u32,
    height: u32,
};

/// In-progress chunked transfer. Cleared on m=0 or first non-chunked.
pub const Accum = struct {
    /// Format and metadata captured from the FIRST chunk. Kitty
    /// allows subsequent chunks to omit metadata.
    format: u32,
    width: u32,
    height: u32,
    medium: u8,
    /// Original action from the first chunk — drives whether
    /// finalize triggers a place.
    action: kitty.Action,
    /// Concatenated base64 payload, awaiting final decode.
    payload: std.ArrayList(u8) = .{},

    pub fn deinit(self: *Accum, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    /// Image store keyed by image_id (a=t / a=p).
    store: std.AutoHashMap(u32, StoredImage),
    /// Pending chunked transfers keyed by image_id.
    accums: std.AutoHashMap(u32, Accum),
    /// image_id of the most recently-started chunked transmit. Kitty
    /// continuation chunks may omit `i=`, so we route their payload to
    /// this id. Cleared when the active transmit finalizes.
    active_transmit_id: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Manager {
        return .{
            .allocator = allocator,
            .store = std.AutoHashMap(u32, StoredImage).init(allocator),
            .accums = std.AutoHashMap(u32, Accum).init(allocator),
        };
    }

    pub fn deinit(self: *Manager) void {
        var it = self.store.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.rgba);
        self.store.deinit();
        var ait = self.accums.iterator();
        while (ait.next()) |e| e.value_ptr.deinit(self.allocator);
        self.accums.deinit();
    }

    /// Ingest a kitty graphics command. Returns:
    ///   - .none: nothing to do (chunk accumulated, query, etc.)
    ///   - .place: caller should place stored image_id at cursor
    pub const Outcome = struct {
        action: enum { none, place },
        image_id: u32,
        placement_id: u32,
        z: i32,
        /// When >0, scale the placed image to this many cells.
        /// 0 = render at native pixel size.
        cells_wide: u32 = 0,
        cells_high: u32 = 0,
        /// Source-rect crop (image-pixel coords). w_or_h == 0 means
        /// "use the whole image".
        src_x: u32 = 0,
        src_y: u32 = 0,
        src_w: u32 = 0,
        src_h: u32 = 0,
    };

    pub fn ingest(self: *Manager, cmd: kitty.Command) Outcome {
        const default = Outcome{
            .action = .none,
            .image_id = cmd.image_id,
            .placement_id = cmd.placement_id,
            .z = cmd.z,
        };

        // Resolve effective image_id: continuation chunks may omit
        // `i=` (per kitty spec) — route to whichever transmission is
        // currently in flight.
        var effective_id = cmd.image_id;
        if (effective_id == 0 and self.active_transmit_id != 0) {
            effective_id = self.active_transmit_id;
        }

        // Continuation chunks omit `a=` too — when an accumulator
        // already exists for this id, treat .unknown as "continue".
        var effective = cmd.action;
        if (effective == .unknown and self.accums.contains(effective_id)) {
            effective = .transmit_and_place; // will be overridden below
        }

        switch (effective) {
            .place => {
                // a=p — place an existing image at the cursor.
                if (self.store.contains(cmd.image_id)) {
                    return .{
                        .action = .place,
                        .image_id = cmd.image_id,
                        .placement_id = cmd.placement_id,
                        .z = cmd.z,
                        .cells_wide = cmd.cells_wide,
                        .cells_high = cmd.cells_high,
                        .src_x = cmd.src_x,
                        .src_y = cmd.src_y,
                        .src_w = cmd.src_w,
                        .src_h = cmd.src_h,
                    };
                }
                return default;
            },
            .transmit, .transmit_and_place => {
                // Chunked transfer: appended into accum until m=0.
                const is_first = !self.accums.contains(effective_id);
                if (is_first) {
                    // Treat the original cmd.action as the source of
                    // truth for what to do on finalize. .unknown can
                    // only happen for continuation chunks (handled
                    // above), so this is the FIRST chunk.
                    self.accums.put(effective_id, .{
                        .format = if (cmd.format == 0) 32 else cmd.format,
                        .width = cmd.width,
                        .height = cmd.height,
                        .medium = cmd.medium,
                        .action = cmd.action,
                    }) catch return default;
                    self.active_transmit_id = effective_id;
                }
                if (self.accums.getPtr(effective_id)) |acc| {
                    acc.payload.appendSlice(self.allocator, cmd.payload) catch {};
                    if (cmd.more == 1) return default; // wait for more
                }
                // Capture the original action BEFORE finalize drops the accum.
                const original_action: kitty.Action = if (self.accums.getPtr(effective_id)) |a| a.action else effective;
                // m=0 (or absent) — finalize.
                const stored_ok = self.finalize(effective_id) catch false;
                if (self.active_transmit_id == effective_id) self.active_transmit_id = 0;
                if (!stored_ok) return default;

                if (original_action == .transmit_and_place) {
                    return .{
                        .action = .place,
                        .image_id = effective_id,
                        .placement_id = cmd.placement_id,
                        .z = cmd.z,
                        .cells_wide = cmd.cells_wide,
                        .cells_high = cmd.cells_high,
                        .src_x = cmd.src_x,
                        .src_y = cmd.src_y,
                        .src_w = cmd.src_w,
                        .src_h = cmd.src_h,
                    };
                }
                return default;
            },
            else => return default,
        }
    }

    /// Drop a stored image (called from delete dispatch).
    pub fn drop(self: *Manager, image_id: u32) void {
        if (self.store.fetchRemove(image_id)) |entry| {
            self.allocator.free(entry.value.rgba);
        }
        if (self.accums.fetchRemove(image_id)) |entry| {
            var v = entry.value;
            v.deinit(self.allocator);
        }
    }

    pub fn dropAll(self: *Manager) void {
        var it = self.store.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.rgba);
        self.store.clearRetainingCapacity();
        var ait = self.accums.iterator();
        while (ait.next()) |e| e.value_ptr.deinit(self.allocator);
        self.accums.clearRetainingCapacity();
    }

    /// Look up a stored image's RGBA + dims.
    pub fn get(self: *Manager, image_id: u32) ?StoredImage {
        return self.store.get(image_id);
    }

    /// Decode the accumulated payload for `image_id`, store it, drop
    /// the accumulator. Returns true if a usable image was stored.
    fn finalize(self: *Manager, image_id: u32) !bool {
        var entry = self.accums.fetchRemove(image_id) orelse return false;
        defer entry.value.deinit(self.allocator);
        const acc = &entry.value;

        // Strip whitespace/newlines from the accumulated base64.
        var stripped: std.ArrayList(u8) = .{};
        defer stripped.deinit(self.allocator);
        try stripped.ensureTotalCapacity(self.allocator, acc.payload.items.len);
        for (acc.payload.items) |b| {
            if (b == ' ' or b == '\n' or b == '\r' or b == '\t') continue;
            try stripped.append(self.allocator, b);
        }
        if (stripped.items.len == 0) return false;

        const decoder = std.base64.standard.Decoder;
        const out_len = decoder.calcSizeForSlice(stripped.items) catch return false;
        const decoded = try self.allocator.alloc(u8, out_len);
        defer self.allocator.free(decoded);
        decoder.decode(decoded, stripped.items) catch return false;

        // For tempfile / file medium: payload (post-base64) is a path.
        var raw_bytes: []const u8 = decoded;
        var owned_file_data: ?[]u8 = null;
        defer if (owned_file_data) |b| self.allocator.free(b);
        if (acc.medium == 't' or acc.medium == 'f') {
            const path = std.mem.trimRight(u8, decoded, "\x00 \r\n\t");
            const data = self.readFile(path) catch return false;
            owned_file_data = data;
            raw_bytes = data;
            if (acc.medium == 't') std.fs.deleteFileAbsolute(path) catch {};
        }

        // Decode according to format.
        const stored: StoredImage = switch (acc.format) {
            32 => blk: {
                if (acc.width == 0 or acc.height == 0) return false;
                const need = acc.width * acc.height * 4;
                if (raw_bytes.len < need) return false;
                const out = try self.allocator.alloc(u8, need);
                @memcpy(out, raw_bytes[0..need]);
                break :blk .{ .rgba = out, .width = acc.width, .height = acc.height };
            },
            24 => blk: {
                if (acc.width == 0 or acc.height == 0) return false;
                const npix = acc.width * acc.height;
                const need_in = npix * 3;
                if (raw_bytes.len < need_in) return false;
                const out = try self.allocator.alloc(u8, npix * 4);
                var i: usize = 0;
                while (i < npix) : (i += 1) {
                    out[i * 4 + 0] = raw_bytes[i * 3 + 0];
                    out[i * 4 + 1] = raw_bytes[i * 3 + 1];
                    out[i * 4 + 2] = raw_bytes[i * 3 + 2];
                    out[i * 4 + 3] = 0xFF;
                }
                break :blk .{ .rgba = out, .width = acc.width, .height = acc.height };
            },
            100 => blk: {
                // PNG via stb_image. Decoder ignores acc.width/height
                // and reads the actual image dimensions from the file.
                var w: c_int = 0;
                var h: c_int = 0;
                var ch: c_int = 0;
                const pix = c.stbi_load_from_memory(
                    raw_bytes.ptr,
                    @intCast(raw_bytes.len),
                    &w,
                    &h,
                    &ch,
                    4,
                );
                if (pix == null or w <= 0 or h <= 0) return false;
                const need: usize = @intCast(w * h * 4);
                const out = try self.allocator.alloc(u8, need);
                @memcpy(out, pix[0..need]);
                c.stbi_image_free(pix);
                break :blk .{
                    .rgba = out,
                    .width = @intCast(w),
                    .height = @intCast(h),
                };
            },
            else => return false,
        };

        // Replace any prior image with this id.
        if (self.store.fetchRemove(image_id)) |old| self.allocator.free(old.value.rgba);
        try self.store.put(image_id, stored);
        return true;
    }

    fn readFile(self: *Manager, path: []const u8) ![]u8 {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();
        const max: u64 = 64 * 1024 * 1024; // sanity cap
        if (stat.size == 0 or stat.size > max) return error.BadFile;
        const buf = try self.allocator.alloc(u8, @intCast(stat.size));
        errdefer self.allocator.free(buf);
        const n = try file.readAll(buf);
        if (n != buf.len) return error.ShortRead;
        return buf;
    }
};

test "manager handles single-chunk RGBA transmit_and_place" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    // Build a 2×2 RGBA payload base64-encoded.
    var rgba: [16]u8 = undefined;
    @memset(&rgba, 0xAA);
    var b64_buf: [32]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const b64 = enc.encode(&b64_buf, &rgba);

    const cmd = kitty.Command{
        .action = .transmit_and_place,
        .image_id = 7,
        .format = 32,
        .width = 2,
        .height = 2,
        .more = 0,
        .payload = b64,
    };
    const out = mgr.ingest(cmd);
    try std.testing.expectEqual(@as(u32, 7), out.image_id);
    const stored = mgr.get(7).?;
    try std.testing.expectEqual(@as(u32, 2), stored.width);
    try std.testing.expectEqual(@as(u32, 2), stored.height);
    try std.testing.expectEqual(@as(usize, 16), stored.rgba.len);
}

test "manager accumulates multi-chunk PNG" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();

    // Tiny 1×1 red PNG (89 50 4E 47 ...). Smallest possible PNG.
    const tiny_png = [_]u8{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
        0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
        0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
        0x00, 0x00, 0x03, 0x00, 0x01, 0x5A, 0xD2, 0x18,
        0xF8, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
        0x44, 0xAE, 0x42, 0x60, 0x82,
    };
    var b64_buf: [256]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    const b64 = enc.encode(&b64_buf, &tiny_png);
    // Split base64 in two roughly even halves.
    const mid = b64.len / 2;

    const c1 = kitty.Command{
        .action = .transmit_and_place,
        .image_id = 9,
        .format = 100,
        .more = 1,
        .payload = b64[0..mid],
    };
    const c2 = kitty.Command{
        .action = .transmit_and_place,
        .image_id = 9,
        .more = 0,
        .payload = b64[mid..],
    };
    const out1 = mgr.ingest(c1);
    try std.testing.expectEqual(@as(@TypeOf(out1.action), .none), out1.action);
    const out2 = mgr.ingest(c2);
    try std.testing.expectEqual(@as(u32, 9), out2.image_id);
    const stored = mgr.get(9) orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expectEqual(@as(u32, 1), stored.width);
    try std.testing.expectEqual(@as(u32, 1), stored.height);
}

test "manager: a=p before any transmit returns none" {
    var mgr = Manager.init(std.testing.allocator);
    defer mgr.deinit();
    const cmd = kitty.Command{ .action = .place, .image_id = 99, .placement_id = 1 };
    const out = mgr.ingest(cmd);
    try std.testing.expectEqual(@as(u32, 99), out.image_id);
    // .none — caller doesn't place when nothing stored.
}

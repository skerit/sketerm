//! Framing of the sketerm-native app pipe: the byte stream INSIDE
//! a chan_data channel of kind `wayland_native` (mux/wire.zig).
//!
//! Both directions carry length-prefixed units (u32 len, u8 tag,
//! payload — same shape as the mux frame itself) so receivers peel
//! units regardless of how chan_data frames split them, and unknown
//! tags skip cleanly. Tags are append-only.
//!
//! Daemon → GUI: wl_msg (verbatim client request, fd args stripped
//! from the byte stream by Wayland's own encoding) + pool_* side
//! band replacing the fds: the GUI compositor treats a pool as plain
//! memory kept in sync by the daemon. A pool update may be CHUNKED —
//! any number of units covering arbitrary [offset, offset+len)
//! ranges — because buffers can exceed the mux MAX_FRAME.
//!
//! GUI → daemon: wl_msg (verbatim compositor event). Events that
//! carry an fd on a real Wayland socket (wl_keyboard.keymap) get a
//! side-band unit the daemon materializes into a memfd.

const std = @import("std");

pub const Tag = enum(u8) {
    /// Raw Wayland message, both directions.
    wl_msg = 1,
    /// u32 pool id, u32 size. Follows the create_pool wl_msg.
    pool_create = 2,
    /// u32 pool id, u32 offset, bytes. Chunked at will.
    pool_update = 3,
    /// u32 pool id, u32 new size.
    pool_resize = 4,
    /// u32 pool id. Mirror may be dropped (all buffers dead).
    pool_destroy = 5,
    /// u32 keymap format, bytes. GUI→daemon; daemon materializes a
    /// memfd and emits the real wl_keyboard.keymap event itself.
    keymap = 6,
    _,
};

pub const header_size = 5;

pub const Unit = struct {
    tag: Tag,
    payload: []const u8,
};

/// Append one unit. Payload must fit u32 minus the tag byte.
pub fn appendUnit(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: Tag, payload: []const u8) !void {
    var hdr: [header_size]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    hdr[4] = @intFromEnum(tag);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, payload);
}

/// Convenience: unit whose payload starts with ids/sizes then bytes.
pub fn appendPoolUpdate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pool: u32, offset: u32, bytes: []const u8) !void {
    var hdr: [header_size + 8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(8 + bytes.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.pool_update);
    std.mem.writeInt(u32, hdr[5..9], pool, .little);
    std.mem.writeInt(u32, hdr[9..13], offset, .little);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, bytes);
}

pub fn appendPoolMeta(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: Tag, pool: u32, size: u32) !void {
    var payload: [8]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], pool, .little);
    std.mem.writeInt(u32, payload[4..8], size, .little);
    try appendUnit(out, allocator, tag, &payload);
}

pub const max_unit = 16 << 20; // matches mux MAX_FRAME; sanity bound

/// Split one unit off `bytes`; null when incomplete. `consumed` is
/// what to drop from the stream.
pub fn peelUnit(bytes: []const u8) error{ Malformed, TooLong }!?struct { unit: Unit, consumed: usize } {
    if (bytes.len < header_size) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0) return error.Malformed;
    if (len > max_unit) return error.TooLong;
    if (bytes.len < 4 + len) return null;
    return .{
        .unit = .{
            .tag = @enumFromInt(bytes[4]),
            .payload = bytes[5 .. 4 + len],
        },
        .consumed = 4 + len,
    };
}

/// Decoded pool_update payload view.
pub fn decodePoolUpdate(payload: []const u8) ?struct { pool: u32, offset: u32, bytes: []const u8 } {
    if (payload.len < 8) return null;
    return .{
        .pool = std.mem.readInt(u32, payload[0..4], .little),
        .offset = std.mem.readInt(u32, payload[4..8], .little),
        .bytes = payload[8..],
    };
}

pub fn decodePoolMeta(payload: []const u8) ?struct { pool: u32, size: u32 } {
    if (payload.len < 8) return null;
    return .{
        .pool = std.mem.readInt(u32, payload[0..4], .little),
        .size = std.mem.readInt(u32, payload[4..8], .little),
    };
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "units peel across arbitrary split points" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try appendUnit(&out, a, .wl_msg, "\x01\x00\x00\x00\x0c\x00\x01\x00\x02\x00\x00\x00");
    try appendPoolMeta(&out, a, .pool_create, 4, 4096);
    try appendPoolUpdate(&out, a, 4, 128, "pixels");

    // No split point yields a unit boundary error; partial = null.
    var pos: usize = 0;
    var units: usize = 0;
    var cut: usize = 0;
    while (cut <= out.items.len) : (cut += 1) {
        pos = 0;
        units = 0;
        while (try peelUnit(out.items[pos..@min(cut, out.items.len)])) |p| {
            pos += p.consumed;
            units += 1;
        }
        if (cut == out.items.len) try t.expectEqual(@as(usize, 3), units);
    }

    pos = 0;
    const first = (try peelUnit(out.items[pos..])).?;
    try t.expectEqual(Tag.wl_msg, first.unit.tag);
    pos += first.consumed;
    const second = (try peelUnit(out.items[pos..])).?;
    const meta = decodePoolMeta(second.unit.payload).?;
    try t.expectEqual(@as(u32, 4), meta.pool);
    try t.expectEqual(@as(u32, 4096), meta.size);
    pos += second.consumed;
    const third = (try peelUnit(out.items[pos..])).?;
    const upd = decodePoolUpdate(third.unit.payload).?;
    try t.expectEqual(@as(u32, 128), upd.offset);
    try t.expectEqualStrings("pixels", upd.bytes);
}

test "unknown tags peel cleanly for forward compat" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendUnit(&out, a, @enumFromInt(200), "future");
    const p = (try peelUnit(out.items)).?;
    try t.expectEqualStrings("future", p.unit.payload);
}

test "zero-length unit is malformed" {
    const zero = [_]u8{ 0, 0, 0, 0, 0 };
    try t.expectError(error.Malformed, peelUnit(&zero));
}

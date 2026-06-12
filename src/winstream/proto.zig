//! Window-stream protocol: the pixel-streaming counterpart of the
//! Wayland pipe, for remotes with NO forwardable display protocol
//! (macOS: apps speak Mach IPC to WindowServer — capture is the
//! only option; see docs/proposal-macos-remote-apps.md addendum).
//!
//! Rides chan_data on a `winstream` channel as tag+len units, same
//! shape as wlhost/pipe.zig: u32 len, u8 tag, payload — receivers
//! reassemble across chan_data boundaries, unknown tags skip.
//!
//! Agent → client: window lifecycle + frames (full-window BGRA,
//! optionally deflated). Client → agent: input + close requests.
//! Key codes are Linux evdev (the agent maps to CGKeyCode etc);
//! coordinates are window-local pixels.

const std = @import("std");

pub const Tag = enum(u8) {
    /// u32 win, i32 w, i32 h, title bytes.
    win_open = 1,
    /// u32 win, i32 w, i32 h, BGRA pixels (w*4 stride, tight).
    win_frame = 2,
    /// u32 win, i32 w, i32 h, u32 raw_len, raw-deflate pixels.
    win_frame_z = 3,
    /// u32 win, title bytes.
    win_title = 4,
    /// u32 win.
    win_close = 5,
    // client → agent
    /// u32 win, u32 evdev key, u8 pressed, u32 mods (X11 order).
    input_key = 16,
    /// u32 win, u8 kind (0 move, 1 down, 2 up, 3 scroll),
    /// f64 x, f64 y, u32 detail (button / scroll axis+sign).
    input_ptr = 17,
    /// u32 win — ask the app to close this window.
    close_req = 18,
    _,
};

pub const header_size = 5;
pub const max_unit = 64 << 20; // 5K BGRA window ≈ 59 MB; bound anyway

pub const Unit = struct {
    tag: Tag,
    payload: []const u8,
};

pub fn appendUnit(out: *std.ArrayList(u8), allocator: std.mem.Allocator, tag: Tag, payload: []const u8) !void {
    var hdr: [header_size]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload.len + 1), .little);
    hdr[4] = @intFromEnum(tag);
    try out.appendSlice(allocator, &hdr);
    try out.appendSlice(allocator, payload);
}

pub fn peelUnit(bytes: []const u8) error{ Malformed, TooLong }!?struct { unit: Unit, consumed: usize } {
    if (bytes.len < header_size) return null;
    const len = std.mem.readInt(u32, bytes[0..4], .little);
    if (len == 0) return error.Malformed;
    if (len > max_unit) return error.TooLong;
    if (bytes.len < 4 + len) return null;
    return .{
        .unit = .{ .tag = @enumFromInt(bytes[4]), .payload = bytes[5 .. 4 + len] },
        .consumed = 4 + len,
    };
}

// ── typed payload helpers ───────────────────────────────────────

pub const WinOpen = struct { win: u32, w: i32, h: i32, title: []const u8 };

pub fn appendWinOpen(out: *std.ArrayList(u8), a: std.mem.Allocator, v: WinOpen) !void {
    var hdr: [header_size + 12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(12 + v.title.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.win_open);
    std.mem.writeInt(u32, hdr[5..9], v.win, .little);
    std.mem.writeInt(i32, hdr[9..13], v.w, .little);
    std.mem.writeInt(i32, hdr[13..17], v.h, .little);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, v.title);
}

pub fn decodeWinOpen(p: []const u8) ?WinOpen {
    if (p.len < 12) return null;
    return .{
        .win = std.mem.readInt(u32, p[0..4], .little),
        .w = std.mem.readInt(i32, p[4..8], .little),
        .h = std.mem.readInt(i32, p[8..12], .little),
        .title = p[12..],
    };
}

pub const Frame = struct { win: u32, w: i32, h: i32, pixels: []const u8 };

pub fn appendFrame(out: *std.ArrayList(u8), a: std.mem.Allocator, v: Frame) !void {
    var hdr: [header_size + 12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(12 + v.pixels.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.win_frame);
    std.mem.writeInt(u32, hdr[5..9], v.win, .little);
    std.mem.writeInt(i32, hdr[9..13], v.w, .little);
    std.mem.writeInt(i32, hdr[13..17], v.h, .little);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, v.pixels);
}

pub fn decodeFrame(p: []const u8) ?Frame {
    if (p.len < 12) return null;
    const w = std.mem.readInt(i32, p[4..8], .little);
    const h = std.mem.readInt(i32, p[8..12], .little);
    if (w <= 0 or h <= 0) return null;
    const need = @as(usize, @intCast(w)) * 4 * @as(usize, @intCast(h));
    if (p.len - 12 != need) return null;
    return .{
        .win = std.mem.readInt(u32, p[0..4], .little),
        .w = w,
        .h = h,
        .pixels = p[12..],
    };
}

pub const FrameZ = struct { win: u32, w: i32, h: i32, raw_len: u32, z: []const u8 };

pub fn appendFrameZ(out: *std.ArrayList(u8), a: std.mem.Allocator, v: FrameZ) !void {
    var hdr: [header_size + 16]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(16 + v.z.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.win_frame_z);
    std.mem.writeInt(u32, hdr[5..9], v.win, .little);
    std.mem.writeInt(i32, hdr[9..13], v.w, .little);
    std.mem.writeInt(i32, hdr[13..17], v.h, .little);
    std.mem.writeInt(u32, hdr[17..21], v.raw_len, .little);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, v.z);
}

pub fn decodeFrameZ(p: []const u8) ?FrameZ {
    if (p.len < 16) return null;
    return .{
        .win = std.mem.readInt(u32, p[0..4], .little),
        .w = std.mem.readInt(i32, p[4..8], .little),
        .h = std.mem.readInt(i32, p[8..12], .little),
        .raw_len = std.mem.readInt(u32, p[12..16], .little),
        .z = p[16..],
    };
}

pub const InputKey = struct { win: u32, key: u32, pressed: bool, mods: u32 };

pub fn appendInputKey(out: *std.ArrayList(u8), a: std.mem.Allocator, v: InputKey) !void {
    var p: [13]u8 = undefined;
    std.mem.writeInt(u32, p[0..4], v.win, .little);
    std.mem.writeInt(u32, p[4..8], v.key, .little);
    p[8] = @intFromBool(v.pressed);
    std.mem.writeInt(u32, p[9..13], v.mods, .little);
    try appendUnit(out, a, .input_key, &p);
}

pub fn decodeInputKey(p: []const u8) ?InputKey {
    if (p.len < 13) return null;
    return .{
        .win = std.mem.readInt(u32, p[0..4], .little),
        .key = std.mem.readInt(u32, p[4..8], .little),
        .pressed = p[8] != 0,
        .mods = std.mem.readInt(u32, p[9..13], .little),
    };
}

pub const InputPtr = struct { win: u32, kind: u8, x: f64, y: f64, detail: u32 };

pub fn appendInputPtr(out: *std.ArrayList(u8), a: std.mem.Allocator, v: InputPtr) !void {
    var p: [25]u8 = undefined;
    std.mem.writeInt(u32, p[0..4], v.win, .little);
    p[4] = v.kind;
    std.mem.writeInt(u64, p[5..13], @bitCast(v.x), .little);
    std.mem.writeInt(u64, p[13..21], @bitCast(v.y), .little);
    std.mem.writeInt(u32, p[21..25], v.detail, .little);
    try appendUnit(out, a, .input_ptr, &p);
}

pub fn decodeInputPtr(p: []const u8) ?InputPtr {
    if (p.len < 25) return null;
    return .{
        .win = std.mem.readInt(u32, p[0..4], .little),
        .kind = p[4],
        .x = @bitCast(std.mem.readInt(u64, p[5..13], .little)),
        .y = @bitCast(std.mem.readInt(u64, p[13..21], .little)),
        .detail = std.mem.readInt(u32, p[21..25], .little),
    };
}

// ── tests ───────────────────────────────────────────────────────

const t = std.testing;

test "winstream units round-trip" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    var px: [16]u8 = undefined;
    for (&px, 0..) |*b, i| b.* = @intCast(i);
    try appendWinOpen(&out, a, .{ .win = 7, .w = 2, .h = 2, .title = "Finder" });
    try appendFrame(&out, a, .{ .win = 7, .w = 2, .h = 2, .pixels = &px });
    try appendInputKey(&out, a, .{ .win = 7, .key = 30, .pressed = true, .mods = 4 });
    try appendInputPtr(&out, a, .{ .win = 7, .kind = 1, .x = 10.5, .y = 20.25, .detail = 0x110 });

    var pos: usize = 0;
    const u1_ = (try peelUnit(out.items[pos..])).?;
    const wo = decodeWinOpen(u1_.unit.payload).?;
    try t.expectEqual(@as(u32, 7), wo.win);
    try t.expectEqualStrings("Finder", wo.title);
    pos += u1_.consumed;

    const u2_ = (try peelUnit(out.items[pos..])).?;
    const fr = decodeFrame(u2_.unit.payload).?;
    try t.expectEqual(@as(i32, 2), fr.w);
    try t.expectEqualSlices(u8, &px, fr.pixels);
    pos += u2_.consumed;

    const u3_ = (try peelUnit(out.items[pos..])).?;
    const ik = decodeInputKey(u3_.unit.payload).?;
    try t.expectEqual(@as(u32, 30), ik.key);
    try t.expect(ik.pressed);
    pos += u3_.consumed;

    const u4_ = (try peelUnit(out.items[pos..])).?;
    const ip = decodeInputPtr(u4_.unit.payload).?;
    try t.expectEqual(@as(f64, 10.5), ip.x);
    try t.expectEqual(@as(u32, 0x110), ip.detail);
    pos += u4_.consumed;
    try t.expectEqual(out.items.len, pos);

    // Frame size mismatch is rejected.
    var bad = u2_.unit.payload[0 .. u2_.unit.payload.len - 1];
    try t.expectEqual(@as(?Frame, null), decodeFrame(bad));
    _ = &bad;
}

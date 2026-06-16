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
const zpool = @import("../wlhost/zpool.zig");
const pixcodec = @import("../wlhost/pixcodec.zig");

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
    /// u32 win, i16 ref_w, i16 ref_h, u16 n, then n × (i16 x,y,w,h):
    /// draggable (title-bar) rects in the window's point space. The
    /// client moves the host window locally for a press inside one
    /// instead of forwarding the click (a forwarded title-bar drag
    /// moves the window on the Mac, not on the client). ref_w/ref_h
    /// are the window dims the rects were measured against — the
    /// client scales them to its current frame size.
    win_drag = 6,
    /// u32 win, i32 w, i32 h, then a pixcodec body (tag + raw_len +
    /// row_stride + bytes). Supersedes win_frame / win_frame_z — one
    /// tag spans raw, deflate, and the predictor codecs, shared with
    /// the Wayland pool path. Receivers still accept the legacy two.
    win_frame_c = 7,
    /// Damaged sub-rect of a window: u32 win, i32 x, i32 y, i32 w,
    /// i32 h, then a pixcodec body for the w×h rect. The receiver blits
    /// it into the window's backing buffer at (x,y) — the bandwidth win
    /// once a source declares damage (Phase 1 / macOS SCK dirty rects).
    win_patch_c = 8,
    /// Video-coded window region (the LOSSY path for hot windows): u32
    /// win, then an opaque wlhost/vcodec.zig tile blob (which carries its
    /// own x/y/w/h). The receiver decodes it and blits into the window's
    /// backing buffer — winstream's counterpart to the Wayland pool_vtile.
    win_vtile = 9,
    // client → agent
    /// u32 win, u32 evdev key, u8 pressed, u32 mods (X11 order).
    input_key = 16,
    /// u32 win, u8 kind (0 move, 1 down, 2 up, 3 scroll),
    /// f64 x, f64 y, u32 detail. Kinds 0-2: x/y are window-local
    /// pixels, detail is the X11 button (1 left, 2 middle,
    /// 3 right). Kind 3: x/y carry the scroll deltas in wheel
    /// lines (positive = content down/right), detail unused.
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

/// Emit a frame, deflating into caller-owned `zbuf` scratch when it
/// shrinks (receivers accept both forms — see decodeFrameAny). Every
/// capture source wants this exact compress-or-fall-back-to-raw
/// dance; keep it in one place. `zbuf` is resized to fit.
pub fn appendFrameMaybeZ(
    out: *std.ArrayList(u8),
    out_a: std.mem.Allocator,
    zbuf: *std.ArrayList(u8),
    zbuf_a: std.mem.Allocator,
    v: Frame,
) !void {
    try zbuf.resize(zbuf_a, v.pixels.len);
    if (zpool.compress(v.pixels, zbuf.items)) |z| {
        try appendFrameZ(out, out_a, .{ .win = v.win, .w = v.w, .h = v.h, .raw_len = @intCast(v.pixels.len), .z = z });
    } else {
        try appendFrame(out, out_a, v);
    }
}

/// Decode a win_frame OR win_frame_z unit to a pixel frame, inflating
/// the _z form into caller-owned `scratch` (resized to fit). Returned
/// pixels alias either the payload or `scratch`. Null on a malformed
/// unit or a raw_len that disagrees with the dimensions.
pub fn decodeFrameAny(
    tag: Tag,
    payload: []const u8,
    scratch: *std.ArrayList(u8),
    scratch_a: std.mem.Allocator,
) !?Frame {
    switch (tag) {
        .win_frame => return decodeFrame(payload),
        .win_frame_z => {
            const fz = decodeFrameZ(payload) orelse return null;
            const need = @as(usize, @intCast(@max(fz.w, 1))) * 4 * @as(usize, @intCast(@max(fz.h, 1)));
            if (fz.raw_len != need) return null;
            try scratch.resize(scratch_a, fz.raw_len);
            _ = zpool.decompress(fz.z, scratch.items) catch return null;
            return .{ .win = fz.win, .w = fz.w, .h = fz.h, .pixels = scratch.items };
        },
        else => return null,
    }
}

// ── codec-tagged frame (shared pixcodec body) ───────────────────

/// Emit a whole-window frame through the shared pixel codec. `enc` is
/// the chosen encoding of `w`×`h` BGRA; raw_len and row_stride follow
/// from the dimensions (tight stride). Phase 1 adds a damaged-rect
/// variant; the body framing is identical.
pub fn appendWinFrameC(out: *std.ArrayList(u8), a: std.mem.Allocator, win: u32, w: i32, h: i32, enc: pixcodec.Encoded) !void {
    const raw_len: u32 = @intCast(@as(i64, w) * @as(i64, h) * 4);
    const row_stride: u32 = @intCast(@as(i64, w) * 4);
    const payload_len = 12 + pixcodec.body_header + enc.bytes.len;
    var hdr: [header_size + 12]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload_len + 1), .little);
    hdr[4] = @intFromEnum(Tag.win_frame_c);
    std.mem.writeInt(u32, hdr[5..9], win, .little);
    std.mem.writeInt(i32, hdr[9..13], w, .little);
    std.mem.writeInt(i32, hdr[13..17], h, .little);
    try out.appendSlice(a, &hdr);
    try pixcodec.appendBody(out, a, enc, raw_len, row_stride);
}

pub const WinFrameC = struct { win: u32, w: i32, h: i32, body: pixcodec.Body };

pub fn decodeWinFrameC(p: []const u8) ?WinFrameC {
    if (p.len < 12) return null;
    const body = pixcodec.peelBody(p[12..]) orelse return null;
    return .{
        .win = std.mem.readInt(u32, p[0..4], .little),
        .w = std.mem.readInt(i32, p[4..8], .little),
        .h = std.mem.readInt(i32, p[8..12], .little),
        .body = body,
    };
}

/// Decode a win_frame_c unit to a pixel frame, reconstructing into
/// caller-owned `scratch` (resized to fit). Mirrors decodeFrameAny so
/// receivers treat legacy and codec frames the same way. Null on a
/// malformed unit or a body that disagrees with the dimensions.
pub fn decodeFrameC(payload: []const u8, scratch: *std.ArrayList(u8), scratch_a: std.mem.Allocator) !?Frame {
    const fc = decodeWinFrameC(payload) orelse return null;
    if (fc.w <= 0 or fc.h <= 0) return null;
    const need = @as(usize, @intCast(fc.w)) * 4 * @as(usize, @intCast(fc.h));
    if (fc.body.raw_len != need) return null;
    try scratch.resize(scratch_a, fc.body.raw_len);
    pixcodec.decodeBody(fc.body, scratch.items) catch return null;
    return .{ .win = fc.win, .w = fc.w, .h = fc.h, .pixels = scratch.items };
}

// ── damaged sub-rect (shared pixcodec body) ─────────────────────

/// Emit a damaged w×h rect at (x,y) of window `win`. `enc` encodes the
/// rect's tight BGRA (row_stride = w*4); the receiver blits it into the
/// window's backing buffer.
pub fn appendWinPatchC(out: *std.ArrayList(u8), a: std.mem.Allocator, win: u32, x: i32, y: i32, w: i32, h: i32, enc: pixcodec.Encoded) !void {
    const payload_len = 20 + pixcodec.body_header + enc.bytes.len;
    var hdr: [header_size + 20]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(payload_len + 1), .little);
    hdr[4] = @intFromEnum(Tag.win_patch_c);
    std.mem.writeInt(u32, hdr[5..9], win, .little);
    std.mem.writeInt(i32, hdr[9..13], x, .little);
    std.mem.writeInt(i32, hdr[13..17], y, .little);
    std.mem.writeInt(i32, hdr[17..21], w, .little);
    std.mem.writeInt(i32, hdr[21..25], h, .little);
    try out.appendSlice(a, &hdr);
    try pixcodec.appendBody(out, a, enc, @intCast(@as(i64, w) * @as(i64, h) * 4), @intCast(@as(i64, w) * 4));
}

pub const WinPatchC = struct { win: u32, x: i32, y: i32, w: i32, h: i32, body: pixcodec.Body };

pub fn decodeWinPatchC(p: []const u8) ?WinPatchC {
    if (p.len < 20) return null;
    const body = pixcodec.peelBody(p[20..]) orelse return null;
    return .{
        .win = std.mem.readInt(u32, p[0..4], .little),
        .x = std.mem.readInt(i32, p[4..8], .little),
        .y = std.mem.readInt(i32, p[8..12], .little),
        .w = std.mem.readInt(i32, p[12..16], .little),
        .h = std.mem.readInt(i32, p[16..20], .little),
        .body = body,
    };
}

pub const Patch = struct { win: u32, x: i32, y: i32, w: i32, h: i32, pixels: []const u8 };

/// Decode a win_patch_c unit, reconstructing the rect pixels into
/// caller-owned `scratch`. Null on a malformed unit or a body whose
/// raw_len disagrees with w×h.
pub fn decodePatchC(payload: []const u8, scratch: *std.ArrayList(u8), scratch_a: std.mem.Allocator) !?Patch {
    const pc = decodeWinPatchC(payload) orelse return null;
    if (pc.w <= 0 or pc.h <= 0) return null;
    const need = @as(usize, @intCast(pc.w)) * 4 * @as(usize, @intCast(pc.h));
    if (pc.body.raw_len != need) return null;
    try scratch.resize(scratch_a, pc.body.raw_len);
    pixcodec.decodeBody(pc.body, scratch.items) catch return null;
    return .{ .win = pc.win, .x = pc.x, .y = pc.y, .w = pc.w, .h = pc.h, .pixels = scratch.items };
}

// ── video-coded window region (opaque vcodec tile) ──────────────

/// Emit a video-coded region of window `win`. `blob` is an opaque
/// wlhost/vcodec.zig tile (appendTile output) carrying the rect + codec.
pub fn appendWinVtile(out: *std.ArrayList(u8), a: std.mem.Allocator, win: u32, blob: []const u8) !void {
    var hdr: [header_size + 4]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(4 + blob.len + 1), .little);
    hdr[4] = @intFromEnum(Tag.win_vtile);
    std.mem.writeInt(u32, hdr[5..9], win, .little);
    try out.appendSlice(a, &hdr);
    try out.appendSlice(a, blob);
}

pub const WinVtile = struct { win: u32, blob: []const u8 };

pub fn decodeWinVtile(p: []const u8) ?WinVtile {
    if (p.len < 4) return null;
    return .{ .win = std.mem.readInt(u32, p[0..4], .little), .blob = p[4..] };
}

// ── draggable-region payload (agent → client) ───────────────────

/// Plenty for a title strip's draggable runs; the daemon caps here too.
pub const max_drag_rects = 64;

/// A draggable rectangle in the window's point space (top-left origin).
pub const DragRect = extern struct { x: i16, y: i16, w: i16, h: i16 };

pub fn appendWinDrag(
    out: *std.ArrayList(u8),
    a: std.mem.Allocator,
    win: u32,
    ref_w: i16,
    ref_h: i16,
    rects: []const DragRect,
) !void {
    const n: u16 = @intCast(@min(rects.len, max_drag_rects));
    const body_len = 10 + @as(usize, n) * 8;
    var hdr: [header_size + 10]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(body_len + 1), .little);
    hdr[4] = @intFromEnum(Tag.win_drag);
    std.mem.writeInt(u32, hdr[5..9], win, .little);
    std.mem.writeInt(i16, hdr[9..11], ref_w, .little);
    std.mem.writeInt(i16, hdr[11..13], ref_h, .little);
    std.mem.writeInt(u16, hdr[13..15], n, .little);
    try out.appendSlice(a, &hdr);
    for (rects[0..n]) |r| {
        var rb: [8]u8 = undefined;
        std.mem.writeInt(i16, rb[0..2], r.x, .little);
        std.mem.writeInt(i16, rb[2..4], r.y, .little);
        std.mem.writeInt(i16, rb[4..6], r.w, .little);
        std.mem.writeInt(i16, rb[6..8], r.h, .little);
        try out.appendSlice(a, &rb);
    }
}

pub const WinDrag = struct { win: u32, ref_w: i16, ref_h: i16, n: u16, body: []const u8 };

pub fn decodeWinDrag(p: []const u8) ?WinDrag {
    if (p.len < 10) return null;
    const n = std.mem.readInt(u16, p[8..10], .little);
    if (p.len < 10 + @as(usize, n) * 8) return null;
    return .{
        .win = std.mem.readInt(u32, p[0..4], .little),
        .ref_w = std.mem.readInt(i16, p[4..6], .little),
        .ref_h = std.mem.readInt(i16, p[6..8], .little),
        .n = n,
        .body = p[10 .. 10 + @as(usize, n) * 8],
    };
}

pub fn dragRectAt(body: []const u8, i: usize) DragRect {
    const o = i * 8;
    return .{
        .x = std.mem.readInt(i16, body[o..][0..2], .little),
        .y = std.mem.readInt(i16, body[o + 2 ..][0..2], .little),
        .w = std.mem.readInt(i16, body[o + 4 ..][0..2], .little),
        .h = std.mem.readInt(i16, body[o + 6 ..][0..2], .little),
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

test "win_frame_c round-trips through the shared codec" {
    const a = t.allocator;
    var sc: pixcodec.Scratch = .{};
    defer sc.deinit(a);

    const w = 12;
    const h = 5;
    var px: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        px[i + 0] = @truncate(x * 9 + y * 3);
        px[i + 1] = @truncate(x * 4);
        px[i + 2] = 0x55;
        px[i + 3] = 0xff;
    };
    const enc = try pixcodec.encodeRegion(&sc, a, &px, w * 4);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendWinFrameC(&out, a, 9, w, h, enc);

    const u = (try peelUnit(out.items)).?;
    try t.expectEqual(Tag.win_frame_c, u.unit.tag);
    try t.expectEqual(out.items.len, u.consumed);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(a);
    const fr = (try decodeFrameC(u.unit.payload, &scratch, a)).?;
    try t.expectEqual(@as(u32, 9), fr.win);
    try t.expectEqual(@as(i32, w), fr.w);
    try t.expectEqualSlices(u8, &px, fr.pixels);

    // A body whose raw_len disagrees with the dims is rejected.
    var bad = u.unit.payload[0 .. u.unit.payload.len - 1];
    try t.expectEqual(@as(?Frame, null), try decodeFrameC(bad, &scratch, a));
    _ = &bad;
}

test "win_vtile carries win id + an opaque video blob" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const blob = "opaque-vcodec-tile";
    try appendWinVtile(&out, a, 7, blob);
    const u = (try peelUnit(out.items)).?;
    try t.expectEqual(Tag.win_vtile, u.unit.tag);
    try t.expectEqual(out.items.len, u.consumed);
    const wv = decodeWinVtile(u.unit.payload).?;
    try t.expectEqual(@as(u32, 7), wv.win);
    try t.expectEqualStrings(blob, wv.blob);
}

test "win_patch_c carries rect coords + a decodable body" {
    const a = t.allocator;
    var sc: pixcodec.Scratch = .{};
    defer sc.deinit(a);

    const w = 10;
    const h = 6;
    var px: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        px[i + 0] = @truncate(x * 13 + y * 5);
        px[i + 1] = @truncate(x * 2);
        px[i + 2] = 0x40;
        px[i + 3] = 0xff;
    };
    const enc = try pixcodec.encodeRegion(&sc, a, &px, w * 4);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendWinPatchC(&out, a, 3, 100, 50, w, h, enc);

    const u = (try peelUnit(out.items)).?;
    try t.expectEqual(Tag.win_patch_c, u.unit.tag);
    try t.expectEqual(out.items.len, u.consumed);

    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(a);
    const p = (try decodePatchC(u.unit.payload, &scratch, a)).?;
    try t.expectEqual(@as(u32, 3), p.win);
    try t.expectEqual(@as(i32, 100), p.x);
    try t.expectEqual(@as(i32, 50), p.y);
    try t.expectEqual(@as(i32, w), p.w);
    try t.expectEqualSlices(u8, &px, p.pixels);
}

test "win_drag round-trips rects + ref dims" {
    const a = t.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    const rects = [_]DragRect{
        .{ .x = 0, .y = 0, .w = 200, .h = 28 },
        .{ .x = 260, .y = 0, .w = 940, .h = 28 },
        .{ .x = -4, .y = 28, .w = 60, .h = 12 },
    };
    try appendWinDrag(&out, a, 7, 1200, 1276, &rects);

    const u = (try peelUnit(out.items)).?;
    try t.expectEqual(Tag.win_drag, u.unit.tag);
    const wd = decodeWinDrag(u.unit.payload).?;
    try t.expectEqual(@as(u32, 7), wd.win);
    try t.expectEqual(@as(i16, 1200), wd.ref_w);
    try t.expectEqual(@as(i16, 1276), wd.ref_h);
    try t.expectEqual(@as(u16, 3), wd.n);
    for (rects, 0..) |want, i| {
        const got = dragRectAt(wd.body, i);
        try t.expectEqual(want.x, got.x);
        try t.expectEqual(want.y, got.y);
        try t.expectEqual(want.w, got.w);
        try t.expectEqual(want.h, got.h);
    }
    try t.expectEqual(out.items.len, u.consumed);

    // Empty list is valid (means "no draggable region").
    out.clearRetainingCapacity();
    try appendWinDrag(&out, a, 9, 800, 600, &.{});
    const ue = (try peelUnit(out.items)).?;
    const wde = decodeWinDrag(ue.unit.payload).?;
    try t.expectEqual(@as(u16, 0), wde.n);
    try t.expectEqual(@as(i16, 800), wde.ref_w);

    // Over-cap input is truncated to max_drag_rects on append.
    out.clearRetainingCapacity();
    const many = [_]DragRect{.{ .x = 1, .y = 1, .w = 1, .h = 1 }} ** (max_drag_rects + 8);
    try appendWinDrag(&out, a, 1, 10, 10, &many);
    const um = (try peelUnit(out.items)).?;
    try t.expectEqual(@as(u16, max_drag_rects), decodeWinDrag(um.unit.payload).?.n);
}

test "appendFrameMaybeZ ↔ decodeFrameAny round-trips both forms" {
    const a = t.allocator;
    var zbuf: std.ArrayList(u8) = .empty;
    defer zbuf.deinit(a);
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(a);

    // Compressible pixels (long runs) take the _z path; random-ish
    // pixels stay raw. Exercise both and confirm a faithful frame.
    inline for (.{ true, false }) |compressible| {
        const w = 8;
        const h = 8;
        var px: [w * h * 4]u8 = undefined;
        for (&px, 0..) |*b, i| b.* = if (compressible) @intCast((i / 32) % 3) else @truncate(i * 131 + 7);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try appendFrameMaybeZ(&out, a, &zbuf, a, .{ .win = 9, .w = w, .h = h, .pixels = &px });

        const u = (try peelUnit(out.items)).?;
        try t.expect(u.unit.tag == .win_frame or u.unit.tag == .win_frame_z);
        if (compressible) try t.expectEqual(Tag.win_frame_z, u.unit.tag);
        const fr = (try decodeFrameAny(u.unit.tag, u.unit.payload, &scratch, a)).?;
        try t.expectEqual(@as(u32, 9), fr.win);
        try t.expectEqual(@as(i32, w), fr.w);
        try t.expectEqualSlices(u8, &px, fr.pixels);
    }

    // A _z unit whose raw_len disagrees with w*h*4 is rejected.
    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(a);
    try appendFrameZ(&bad, a, .{ .win = 1, .w = 4, .h = 4, .raw_len = 999, .z = "\x00\x00" });
    const bu = (try peelUnit(bad.items)).?;
    try t.expectEqual(@as(?Frame, null), try decodeFrameAny(bu.unit.tag, bu.unit.payload, &scratch, a));
}

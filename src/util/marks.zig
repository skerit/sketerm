//! Screenshot annotation: high-contrast click/hover markers
//! (crosshair + ring + optional numeric label) drawn onto straight
//! RGBA pixels before PNG encode. Pure pixel math, no dependencies —
//! usable from the mux/appdrive graph.

const std = @import("std");

pub const Mark = struct {
    /// Position in the coordinate space of the target buffer.
    x: f64,
    y: f64,
    kind: Kind = .click,
    /// Small number drawn next to the marker (step index); 0 = none.
    label: u32 = 0,

    pub const Kind = enum { click, move };
};

const RING_R: f64 = 7.0;
const ARM: i32 = 12;

fn colorOf(kind: Mark.Kind) [3]u8 {
    return switch (kind) {
        .click => .{ 255, 64, 64 },
        .move => .{ 64, 200, 255 },
    };
}

fn setPx(rgba: []u8, w: u32, h: u32, x: i32, y: i32, col: [3]u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(w)) or y >= @as(i32, @intCast(h))) return;
    const i = (@as(usize, @intCast(y)) * w + @as(usize, @intCast(x))) * 4;
    rgba[i + 0] = col[0];
    rgba[i + 1] = col[1];
    rgba[i + 2] = col[2];
    rgba[i + 3] = 255;
}

/// 3x5 digit font, one u15 per glyph (rows top to bottom, MSB left).
const DIGITS = [10]u15{
    0b111_101_101_101_111, // 0
    0b010_110_010_010_111, // 1
    0b111_001_111_100_111, // 2
    0b111_001_111_001_111, // 3
    0b101_101_111_001_001, // 4
    0b111_100_111_001_111, // 5
    0b111_100_111_101_111, // 6
    0b111_001_001_001_001, // 7
    0b111_101_111_101_111, // 8
    0b111_101_111_001_111, // 9
};

const GLYPH_SCALE: i32 = 2; // 3x5 -> 6x10 pixels per digit

fn digitAt(g: u15, row: u4, colbit: u2) bool {
    const shift: u4 = @intCast((4 - row) * 3 + (2 - colbit));
    return (g >> shift) & 1 == 1;
}

/// Draw one digit (black-boxed white glyph) with its top-left at (ox, oy).
fn drawDigit(rgba: []u8, w: u32, h: u32, d: u8, ox: i32, oy: i32) void {
    const g = DIGITS[d];
    var y: i32 = -1;
    while (y <= 5 * GLYPH_SCALE) : (y += 1) {
        var x: i32 = -1;
        while (x <= 3 * GLYPH_SCALE) : (x += 1) {
            const on = blk: {
                if (x < 0 or y < 0 or x >= 3 * GLYPH_SCALE or y >= 5 * GLYPH_SCALE) break :blk false;
                break :blk digitAt(g, @intCast(@divTrunc(y, GLYPH_SCALE)), @intCast(@divTrunc(x, GLYPH_SCALE)));
            };
            setPx(rgba, w, h, ox + x, oy + y, if (on) .{ 255, 255, 255 } else .{ 0, 0, 0 });
        }
    }
}

fn drawLabel(rgba: []u8, w: u32, h: u32, cx: i32, cy: i32, label: u32) void {
    var buf: [10]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{label}) catch return;
    const glyph_w = 3 * GLYPH_SCALE + 2; // incl. spacing
    const total_w: i32 = @as(i32, @intCast(s.len)) * glyph_w;
    // Right of the ring; flip left / clamp when it would fall off.
    var ox = cx + ARM + 3;
    if (ox + total_w > @as(i32, @intCast(w))) ox = cx - ARM - 3 - total_w;
    if (ox < 0) ox = 0;
    var oy = cy - ARM - 3 - 5 * GLYPH_SCALE;
    if (oy < 0) oy = cy + ARM + 3;
    for (s, 0..) |ch, i| {
        drawDigit(rgba, w, h, ch - '0', ox + @as(i32, @intCast(i)) * glyph_w, oy);
    }
}

fn drawOne(rgba: []u8, w: u32, h: u32, m: Mark) void {
    if (!std.math.isFinite(m.x) or !std.math.isFinite(m.y)) return;
    const rx = @round(m.x);
    const ry = @round(m.y);
    if (rx < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        rx > @as(f64, @floatFromInt(std.math.maxInt(i32))) or
        ry < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        ry > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return;
    const cx: i32 = @intFromFloat(rx);
    const cy: i32 = @intFromFloat(ry);
    const col = colorOf(m.kind);

    // Pass 1: black backing (3px-wide crosshair arms + a 3px ring
    // band) so the marker stays visible on any background.
    var dy: i32 = -(ARM + 2);
    while (dy <= ARM + 2) : (dy += 1) {
        var dx: i32 = -(ARM + 2);
        while (dx <= ARM + 2) : (dx += 1) {
            const on_h = @abs(dy) <= 1 and @abs(dx) <= ARM;
            const on_v = @abs(dx) <= 1 and @abs(dy) <= ARM;
            const d = @sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy)));
            const on_ring = @abs(d - RING_R) <= 1.6;
            if (on_h or on_v or on_ring)
                setPx(rgba, w, h, cx + dx, cy + dy, .{ 0, 0, 0 });
        }
    }
    // Pass 2: colored core (1px crosshair + thin ring).
    dy = -ARM;
    while (dy <= ARM) : (dy += 1) {
        var dx: i32 = -ARM;
        while (dx <= ARM) : (dx += 1) {
            const on_h = dy == 0 and @abs(dx) <= ARM;
            const on_v = dx == 0 and @abs(dy) <= ARM;
            const d = @sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy)));
            const on_ring = @abs(d - RING_R) <= 0.7;
            if (on_h or on_v or on_ring)
                setPx(rgba, w, h, cx + dx, cy + dy, col);
        }
    }
    if (m.label != 0) drawLabel(rgba, w, h, cx, cy, m.label);
}

/// Draw every mark onto a tightly-packed RGBA buffer. Marks partially
/// or fully outside the buffer clip safely.
pub fn draw(rgba: []u8, w: u32, h: u32, marks: []const Mark) void {
    std.debug.assert(rgba.len >= @as(usize, w) * h * 4);
    for (marks) |m| drawOne(rgba, w, h, m);
}

// ── tests ────────────────────────────────────────────────────────

const t = std.testing;

fn mkBuf(a: std.mem.Allocator, w: u32, h: u32, fill: u8) ![]u8 {
    const buf = try a.alloc(u8, @as(usize, w) * h * 4);
    @memset(buf, fill);
    return buf;
}

test "click mark paints crosshair core and black backing" {
    const buf = try mkBuf(t.allocator, 64, 64, 128);
    defer t.allocator.free(buf);
    draw(buf, 64, 64, &.{.{ .x = 32, .y = 32 }});
    // Center pixel: colored crosshair core (red for click).
    const ci = (32 * 64 + 32) * 4;
    try t.expectEqual(@as(u8, 255), buf[ci]);
    try t.expectEqual(@as(u8, 64), buf[ci + 1]);
    // One px above the horizontal arm end: black backing.
    const bi = ((32 - 1) * 64 + (32 + 10)) * 4;
    try t.expectEqual(@as(u8, 0), buf[bi]);
    try t.expectEqual(@as(u8, 0), buf[bi + 1]);
    try t.expectEqual(@as(u8, 0), buf[bi + 2]);
}

test "move mark uses the hover color" {
    const buf = try mkBuf(t.allocator, 64, 64, 0);
    defer t.allocator.free(buf);
    draw(buf, 64, 64, &.{.{ .x = 20, .y = 20, .kind = .move }});
    const ci = (20 * 64 + 20) * 4;
    try t.expectEqual(@as(u8, 64), buf[ci]);
    try t.expectEqual(@as(u8, 200), buf[ci + 1]);
    try t.expectEqual(@as(u8, 255), buf[ci + 2]);
}

test "marks at and beyond the edges clip without touching out-of-range memory" {
    const buf = try mkBuf(t.allocator, 32, 32, 7);
    defer t.allocator.free(buf);
    draw(buf, 32, 32, &.{
        .{ .x = 0, .y = 0, .label = 12 },
        .{ .x = 31, .y = 31, .label = 3 },
        .{ .x = -50, .y = 10 },
        .{ .x = 10, .y = 500 },
    });
    // A pixel outside every mark's reach (incl. relocated labels)
    // stays untouched.
    const i = (2 * 32 + 16) * 4;
    try t.expectEqual(@as(u8, 7), buf[i]);
}

test "non-finite and non-i32 coordinates are ignored" {
    const buf = try mkBuf(t.allocator, 8, 8, 19);
    defer t.allocator.free(buf);
    draw(buf, 8, 8, &.{
        .{ .x = 5_000_000_000, .y = 1 },
        .{ .x = std.math.inf(f64), .y = 1 },
        .{ .x = 1, .y = std.math.nan(f64) },
    });
    for (buf) |b| try t.expectEqual(@as(u8, 19), b);
}

test "label digits render as white-on-black" {
    const buf = try mkBuf(t.allocator, 128, 128, 60);
    defer t.allocator.free(buf);
    draw(buf, 128, 128, &.{.{ .x = 64, .y = 64, .label = 8 }});
    // Somewhere in the label area there must be pure white AND pure
    // black pixels (glyph + backing box).
    var saw_white = false;
    var saw_black = false;
    var y: usize = 0;
    while (y < 64) : (y += 1) {
        var x: usize = 64;
        while (x < 128) : (x += 1) {
            const p = buf[(y * 128 + x) * 4 ..][0..4];
            if (p[0] == 255 and p[1] == 255 and p[2] == 255) saw_white = true;
            if (p[0] == 0 and p[1] == 0 and p[2] == 0) saw_black = true;
        }
    }
    try t.expect(saw_white);
    try t.expect(saw_black);
}

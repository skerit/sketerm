//! Procedural box-drawing, block and Powerline glyphs.
//!
//! These characters have to TILE: a vertical line in one cell must
//! meet the one above it with no seam, and a block must fill its cell
//! exactly. Font outlines are hinted and rounded per glyph, so at most
//! cell sizes they do neither — the familiar dashed-looking borders in
//! TUIs. Drawing them from the cell rectangle instead makes the joins
//! exact at every size.
//!
//! Pure: renders into a caller-supplied coverage buffer (one byte of
//! alpha per pixel, row-major, `w * h` bytes). No FreeType, no GL.

const std = @import("std");

/// Does this codepoint have a built-in drawing? Cheap enough to call
/// on the glyph path before anything else.
pub fn covers(cp: u32) bool {
    return switch (cp) {
        0x2500...0x259F => true, // box drawing + block elements
        0xE0B0...0xE0B3 => true, // Powerline separators
        else => false,
    };
}

/// Draw `cp` into `buf` (w*h coverage bytes, zeroed by the caller).
/// Returns false when the codepoint has no built-in drawing, in which
/// case `buf` is untouched.
pub fn draw(cp: u32, buf: []u8, w: u32, h: u32) bool {
    if (buf.len < w * h or w == 0 or h == 0) return false;
    const ctx = Ctx{ .buf = buf, .w = w, .h = h, .t = lineWidth(w, h) };
    return switch (cp) {
        0x2500...0x257F => ctx.boxDrawing(cp),
        0x2580...0x259F => ctx.blockElement(cp),
        0xE0B0...0xE0B3 => ctx.powerline(cp),
        else => false,
    };
}

/// Width of a "light" line. Scales with the cell so it stays visible
/// at 40px and does not become a slab at 12px, and is always odd-safe:
/// centring an even-width line in an odd-width cell is what makes
/// adjacent cells' lines look misaligned.
fn lineWidth(w: u32, h: u32) u32 {
    const base = @min(w, h);
    return @max(1, base / 8);
}

const Ctx = struct {
    buf: []u8,
    w: u32,
    h: u32,
    /// Light line width; heavy is twice this.
    t: u32,

    fn fill(self: Ctx, x0: i64, y0: i64, x1: i64, y1: i64) void {
        const xs: u32 = @intCast(std.math.clamp(x0, 0, @as(i64, self.w)));
        const xe: u32 = @intCast(std.math.clamp(x1, 0, @as(i64, self.w)));
        const ys: u32 = @intCast(std.math.clamp(y0, 0, @as(i64, self.h)));
        const ye: u32 = @intCast(std.math.clamp(y1, 0, @as(i64, self.h)));
        var y = ys;
        while (y < ye) : (y += 1) {
            const row = y * self.w;
            var x = xs;
            while (x < xe) : (x += 1) self.buf[row + x] = 255;
        }
    }

    fn shade(self: Ctx, num: u32, den: u32) void {
        // Ordered 4x4 dither, so a shade block tiles with itself and
        // with its neighbours instead of showing a seam.
        const bayer = [16]u32{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            var x: u32 = 0;
            while (x < self.w) : (x += 1) {
                const cell = bayer[(y % 4) * 4 + (x % 4)];
                if (cell * den < num * 16) self.buf[y * self.w + x] = 255;
            }
        }
    }

    // ── Box drawing ────────────────────────────────────────────────

    fn boxDrawing(self: Ctx, cp: u32) bool {
        switch (cp) {
            // Dashes: the same line as the solid form with gaps cut in.
            0x2504, 0x2505 => return self.dashed(true, cp == 0x2505, 3),
            0x2506, 0x2507 => return self.dashed(false, cp == 0x2507, 3),
            0x2508, 0x2509 => return self.dashed(true, cp == 0x2509, 4),
            0x250A, 0x250B => return self.dashed(false, cp == 0x250B, 4),
            0x254C, 0x254D => return self.dashed(true, cp == 0x254D, 2),
            0x254E, 0x254F => return self.dashed(false, cp == 0x254F, 2),
            // Arcs: quarter circles meeting the cell edges where the
            // straight forms would.
            0x256D => return self.arc(.down, .right),
            0x256E => return self.arc(.down, .left),
            0x256F => return self.arc(.up, .left),
            0x2570 => return self.arc(.up, .right),
            // Diagonals.
            0x2571 => return self.diagonal(false, true),
            0x2572 => return self.diagonal(true, false),
            0x2573 => return self.diagonal(true, true),
            else => {},
        }
        const arms = armsFor(cp) orelse return false;
        self.drawArms(arms);
        return true;
    }

    const Weight = enum(u8) { none, light, heavy, double };
    /// Arm weights in the order up, right, down, left.
    const Arms = [4]Weight;

    fn drawArms(self: Ctx, arms: Arms) void {
        const t: i64 = @intCast(self.t);
        const cw: i64 = @intCast(self.w);
        const ch: i64 = @intCast(self.h);
        // Centre the light line; heavy grows symmetrically around it.
        const cx0 = @divTrunc(cw - t, 2);
        const cy0 = @divTrunc(ch - t, 2);

        for (arms, 0..) |weight, side| {
            if (weight == .none) continue;
            const thick: i64 = if (weight == .heavy) t * 2 else t;
            const x0 = @divTrunc(cw - thick, 2);
            const y0 = @divTrunc(ch - thick, 2);
            switch (weight) {
                .double => {
                    // Two light lines with a light gap between them.
                    const off = t;
                    switch (side) {
                        0 => { // up
                            self.fill(cx0 - off, 0, cx0 - off + t, cy0 + t);
                            self.fill(cx0 + off, 0, cx0 + off + t, cy0 + t);
                        },
                        1 => { // right
                            self.fill(cx0, cy0 - off, cw, cy0 - off + t);
                            self.fill(cx0, cy0 + off, cw, cy0 + off + t);
                        },
                        2 => { // down
                            self.fill(cx0 - off, cy0, cx0 - off + t, ch);
                            self.fill(cx0 + off, cy0, cx0 + off + t, ch);
                        },
                        else => { // left
                            self.fill(0, cy0 - off, cx0 + t, cy0 - off + t);
                            self.fill(0, cy0 + off, cx0 + t, cy0 + off + t);
                        },
                    }
                },
                else => switch (side) {
                    0 => self.fill(x0, 0, x0 + thick, cy0 + t),
                    1 => self.fill(cx0, y0, cw, y0 + thick),
                    2 => self.fill(x0, cy0, x0 + thick, ch),
                    else => self.fill(0, y0, cx0 + t, y0 + thick),
                },
            }
        }
    }

    fn dashed(self: Ctx, horizontal: bool, heavy: bool, dashes: u32) bool {
        const t: i64 = @intCast(if (heavy) self.t * 2 else self.t);
        const cw: i64 = @intCast(self.w);
        const ch: i64 = @intCast(self.h);
        const span: u32 = if (horizontal) self.w else self.h;
        // `dashes` marks with `dashes` gaps: the gap after the last
        // one is what lets the next cell's first dash keep the rhythm.
        const period = @max(2, span / dashes);
        const on = @max(1, (period * 2) / 3);
        var i: u32 = 0;
        while (i < span) : (i += period) {
            const end = @min(span, i + on);
            if (horizontal) {
                self.fill(@intCast(i), @divTrunc(ch - t, 2), @intCast(end), @divTrunc(ch - t, 2) + t);
            } else {
                self.fill(@divTrunc(cw - t, 2), @intCast(i), @divTrunc(cw - t, 2) + t, @intCast(end));
            }
        }
        return true;
    }

    const Dir = enum { up, down, left, right };

    /// A rounded corner: the quarter arc from one cell edge to the
    /// other, drawn as a thick circle segment centred on the corner
    /// the two straight arms would have met at.
    fn arc(self: Ctx, vertical: Dir, horizontal: Dir) bool {
        const t: f64 = @floatFromInt(self.t);
        const cw: f64 = @floatFromInt(self.w);
        const ch: f64 = @floatFromInt(self.h);
        const cx = cw / 2.0;
        const cy = ch / 2.0;
        // Radius: reach from the centre to the nearer edge, so the arc
        // lands exactly where a straight line would leave the cell.
        const r = @min(cx, cy);
        const arc_cx = if (horizontal == .right) cx + r else cx - r;
        const arc_cy = if (vertical == .down) cy + r else cy - r;

        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            var x: u32 = 0;
            while (x < self.w) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                // Only the quadrant facing the two arms.
                const right_side = px >= arc_cx;
                const down_side = py >= arc_cy;
                if ((horizontal == .right) != right_side) continue;
                if ((vertical == .down) != down_side) continue;
                const d = @sqrt((px - arc_cx) * (px - arc_cx) + (py - arc_cy) * (py - arc_cy));
                if (@abs(d - r) <= t / 2.0) self.buf[y * self.w + x] = 255;
            }
        }
        // Join the arc to the cell edges: without these the arc can
        // fall a pixel short at the boundary and reintroduce the seam.
        const ti: i64 = @intCast(self.t);
        const cwi: i64 = @intCast(self.w);
        const chi: i64 = @intCast(self.h);
        const cx0 = @divTrunc(cwi - ti, 2);
        const cy0 = @divTrunc(chi - ti, 2);
        if (vertical == .down) self.fill(cx0, chi - ti, cx0 + ti, chi) else self.fill(cx0, 0, cx0 + ti, ti);
        if (horizontal == .right) self.fill(cwi - ti, cy0, cwi, cy0 + ti) else self.fill(0, cy0, ti, cy0 + ti);
        return true;
    }

    fn diagonal(self: Ctx, top_left_to_bottom_right: bool, bottom_left_to_top_right: bool) bool {
        const t: f64 = @floatFromInt(self.t);
        const cw: f64 = @floatFromInt(self.w);
        const ch: f64 = @floatFromInt(self.h);
        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            var x: u32 = 0;
            while (x < self.w) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                const on_down = @abs(py / ch - px / cw) * @min(cw, ch) <= t / 2.0;
                const on_up = @abs(py / ch - (1.0 - px / cw)) * @min(cw, ch) <= t / 2.0;
                if ((top_left_to_bottom_right and on_down) or (bottom_left_to_top_right and on_up))
                    self.buf[y * self.w + x] = 255;
            }
        }
        return true;
    }

    // ── Block elements ─────────────────────────────────────────────

    fn blockElement(self: Ctx, cp: u32) bool {
        const cw: i64 = @intCast(self.w);
        const ch: i64 = @intCast(self.h);
        switch (cp) {
            0x2580 => self.fill(0, 0, cw, @divTrunc(ch, 2)), // upper half
            // Lower eighths, 1/8 through full.
            0x2581...0x2588 => {
                const eighths: i64 = @intCast(cp - 0x2580);
                self.fill(0, ch - @divTrunc(ch * eighths, 8), cw, ch);
            },
            // Left eighths, 7/8 down to 1/8.
            0x2589...0x258F => {
                const eighths: i64 = @intCast(0x2590 - cp);
                self.fill(0, 0, @divTrunc(cw * eighths, 8), ch);
            },
            0x2590 => self.fill(@divTrunc(cw, 2), 0, cw, ch), // right half
            0x2591 => self.shade(1, 4),
            0x2592 => self.shade(2, 4),
            0x2593 => self.shade(3, 4),
            0x2594 => self.fill(0, 0, cw, @max(1, @divTrunc(ch, 8))), // upper eighth
            0x2595 => self.fill(cw - @max(1, @divTrunc(cw, 8)), 0, cw, ch), // right eighth
            // Quadrants: bit 0 upper-left, 1 upper-right, 2 lower-left,
            // 3 lower-right.
            0x2596...0x259F => {
                const q: u4 = switch (cp) {
                    0x2596 => 0b0100,
                    0x2597 => 0b1000,
                    0x2598 => 0b0001,
                    0x2599 => 0b1101,
                    0x259A => 0b1001,
                    0x259B => 0b0111,
                    0x259C => 0b1011,
                    0x259D => 0b0010,
                    0x259E => 0b0110,
                    else => 0b1110,
                };
                const mx = @divTrunc(cw, 2);
                const my = @divTrunc(ch, 2);
                if (q & 0b0001 != 0) self.fill(0, 0, mx, my);
                if (q & 0b0010 != 0) self.fill(mx, 0, cw, my);
                if (q & 0b0100 != 0) self.fill(0, my, mx, ch);
                if (q & 0b1000 != 0) self.fill(mx, my, cw, ch);
            },
            else => return false,
        }
        return true;
    }

    // ── Powerline ──────────────────────────────────────────────────

    fn powerline(self: Ctx, cp: u32) bool {
        const cw: f64 = @floatFromInt(self.w);
        const ch: f64 = @floatFromInt(self.h);
        const t: f64 = @floatFromInt(@max(1, self.t));
        var y: u32 = 0;
        while (y < self.h) : (y += 1) {
            var x: u32 = 0;
            while (x < self.w) : (x += 1) {
                const px = @as(f64, @floatFromInt(x)) + 0.5;
                const py = @as(f64, @floatFromInt(y)) + 0.5;
                // Distance from the cell's vertical centre, 0 at the
                // middle row and 1 at top and bottom.
                const dy = @abs(py - ch / 2.0) / (ch / 2.0);
                // The edge of the arrow at this row.
                const edge = (1.0 - dy) * cw;
                const on = switch (cp) {
                    0xE0B0 => px <= edge, // filled, pointing right
                    0xE0B2 => px >= cw - edge, // filled, pointing left
                    0xE0B1 => @abs(px - edge) <= t, // outline, right
                    else => @abs(px - (cw - edge)) <= t, // outline, left
                };
                if (on) self.buf[y * self.w + x] = 255;
            }
        }
        return true;
    }
};

/// Per-side line weights for the joining characters. Order is
/// up, right, down, left; the table covers U+2500..U+2503 and
/// U+250C..U+254B plus U+2550..U+256C and U+2574..U+257F. Codepoints
/// handled elsewhere (dashes, arcs, diagonals) return null.
fn armsFor(cp: u32) ?Ctx.Arms {
    const n: Ctx.Weight = .none;
    const l: Ctx.Weight = .light;
    const v: Ctx.Weight = .heavy;
    const d: Ctx.Weight = .double;
    return switch (cp) {
        0x2500 => .{ n, l, n, l },
        0x2501 => .{ n, v, n, v },
        0x2502 => .{ l, n, l, n },
        0x2503 => .{ v, n, v, n },
        0x250C => .{ n, l, l, n },
        0x250D => .{ n, v, l, n },
        0x250E => .{ n, l, v, n },
        0x250F => .{ n, v, v, n },
        0x2510 => .{ n, n, l, l },
        0x2511 => .{ n, n, l, v },
        0x2512 => .{ n, n, v, l },
        0x2513 => .{ n, n, v, v },
        0x2514 => .{ l, l, n, n },
        0x2515 => .{ l, v, n, n },
        0x2516 => .{ v, l, n, n },
        0x2517 => .{ v, v, n, n },
        0x2518 => .{ l, n, n, l },
        0x2519 => .{ l, n, n, v },
        0x251A => .{ v, n, n, l },
        0x251B => .{ v, n, n, v },
        0x251C => .{ l, l, l, n },
        0x251D => .{ l, v, l, n },
        0x251E => .{ v, l, l, n },
        0x251F => .{ l, l, v, n },
        0x2520 => .{ v, l, v, n },
        0x2521 => .{ v, v, l, n },
        0x2522 => .{ l, v, v, n },
        0x2523 => .{ v, v, v, n },
        0x2524 => .{ l, n, l, l },
        0x2525 => .{ l, n, l, v },
        0x2526 => .{ v, n, l, l },
        0x2527 => .{ l, n, v, l },
        0x2528 => .{ v, n, v, l },
        0x2529 => .{ v, n, l, v },
        0x252A => .{ l, n, v, v },
        0x252B => .{ v, n, v, v },
        0x252C => .{ n, l, l, l },
        0x252D => .{ n, l, l, v },
        0x252E => .{ n, v, l, l },
        0x252F => .{ n, v, l, v },
        0x2530 => .{ n, l, v, l },
        0x2531 => .{ n, l, v, v },
        0x2532 => .{ n, v, v, l },
        0x2533 => .{ n, v, v, v },
        0x2534 => .{ l, l, n, l },
        0x2535 => .{ l, l, n, v },
        0x2536 => .{ l, v, n, l },
        0x2537 => .{ l, v, n, v },
        0x2538 => .{ v, l, n, l },
        0x2539 => .{ v, l, n, v },
        0x253A => .{ v, v, n, l },
        0x253B => .{ v, v, n, v },
        0x253C => .{ l, l, l, l },
        0x253D => .{ l, l, l, v },
        0x253E => .{ l, v, l, l },
        0x253F => .{ l, v, l, v },
        0x2540 => .{ v, l, l, l },
        0x2541 => .{ l, l, v, l },
        0x2542 => .{ v, l, v, l },
        0x2543 => .{ v, l, l, v },
        0x2544 => .{ v, v, l, l },
        0x2545 => .{ l, l, v, v },
        0x2546 => .{ l, v, v, l },
        0x2547 => .{ v, v, l, v },
        0x2548 => .{ l, v, v, v },
        0x2549 => .{ v, l, v, v },
        0x254A => .{ v, v, v, l },
        0x254B => .{ v, v, v, v },
        0x2550 => .{ n, d, n, d },
        0x2551 => .{ d, n, d, n },
        0x2552 => .{ n, d, l, n },
        0x2553 => .{ n, l, d, n },
        0x2554 => .{ n, d, d, n },
        0x2555 => .{ n, n, l, d },
        0x2556 => .{ n, n, d, l },
        0x2557 => .{ n, n, d, d },
        0x2558 => .{ l, d, n, n },
        0x2559 => .{ d, l, n, n },
        0x255A => .{ d, d, n, n },
        0x255B => .{ l, n, n, d },
        0x255C => .{ d, n, n, l },
        0x255D => .{ d, n, n, d },
        0x255E => .{ l, d, l, n },
        0x255F => .{ d, l, d, n },
        0x2560 => .{ d, d, d, n },
        0x2561 => .{ l, n, l, d },
        0x2562 => .{ d, n, d, l },
        0x2563 => .{ d, n, d, d },
        0x2564 => .{ n, d, l, d },
        0x2565 => .{ n, l, d, l },
        0x2566 => .{ n, d, d, d },
        0x2567 => .{ l, d, n, d },
        0x2568 => .{ d, l, n, l },
        0x2569 => .{ d, d, n, d },
        0x256A => .{ l, d, l, d },
        0x256B => .{ d, l, d, l },
        0x256C => .{ d, d, d, d },
        0x2574 => .{ n, n, n, l },
        0x2575 => .{ l, n, n, n },
        0x2576 => .{ n, l, n, n },
        0x2577 => .{ n, n, l, n },
        0x2578 => .{ n, n, n, v },
        0x2579 => .{ v, n, n, n },
        0x257A => .{ n, v, n, n },
        0x257B => .{ n, n, v, n },
        0x257C => .{ n, v, n, l },
        0x257D => .{ l, n, v, n },
        0x257E => .{ n, l, n, v },
        0x257F => .{ v, n, l, n },
        else => null,
    };
}

// ── Tests ─────────────────────────────────────────────────────────

const W = 10;
const H = 20;

fn render(cp: u32) [W * H]u8 {
    var buf: [W * H]u8 = @splat(0);
    _ = draw(cp, &buf, W, H);
    return buf;
}

fn columnFilled(buf: []const u8, x: u32) bool {
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        if (buf[y * W + x] == 0) return false;
    }
    return true;
}

fn rowFilled(buf: []const u8, y: u32) bool {
    var x: u32 = 0;
    while (x < W) : (x += 1) {
        if (buf[y * W + x] == 0) return false;
    }
    return true;
}

fn rowHasInk(buf: []const u8, y: u32) bool {
    var x: u32 = 0;
    while (x < W) : (x += 1) {
        if (buf[y * W + x] != 0) return true;
    }
    return false;
}

fn colHasInk(buf: []const u8, x: u32) bool {
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        if (buf[y * W + x] != 0) return true;
    }
    return false;
}

test "a vertical line reaches both cell edges so it tiles" {
    const buf = render(0x2502);
    // Top and bottom rows must both be painted, or the line breaks at
    // every cell boundary — the whole reason this module exists.
    try std.testing.expect(rowHasInk(&buf, 0));
    try std.testing.expect(rowHasInk(&buf, H - 1));
    // ...and nothing at the left or right edge: it is a line, not a fill.
    try std.testing.expect(!colHasInk(&buf, 0));
    try std.testing.expect(!colHasInk(&buf, W - 1));
}

test "a horizontal line spans the full cell width" {
    const buf = render(0x2500);
    var found = false;
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        if (buf[y * W] != 0 and buf[y * W + W - 1] != 0) found = true;
    }
    try std.testing.expect(found);
}

test "a corner paints only its own two arms" {
    // Down and right: the top edge and the left edge stay clear.
    const buf = render(0x250C);
    try std.testing.expect(!rowHasInk(&buf, 0)); // no up arm
    try std.testing.expect(!colHasInk(&buf, 0)); // no left arm
    try std.testing.expect(rowHasInk(&buf, H - 1)); // down arm
    try std.testing.expect(colHasInk(&buf, W - 1)); // right arm
}

test "heavy lines are wider than light ones" {
    const light = render(0x2502);
    const heavy = render(0x2503);
    var light_px: usize = 0;
    var heavy_px: usize = 0;
    for (light) |v| light_px += @intFromBool(v != 0);
    for (heavy) |v| heavy_px += @intFromBool(v != 0);
    try std.testing.expect(heavy_px > light_px);
}

test "a double line paints two separated runs" {
    const buf = render(0x2551);
    // Scan the middle row: two filled runs with a gap between them.
    var runs: usize = 0;
    var prev: bool = false;
    var x: u32 = 0;
    while (x < W) : (x += 1) {
        const on = buf[(H / 2) * W + x] != 0;
        if (on and !prev) runs += 1;
        prev = on;
    }
    try std.testing.expectEqual(@as(usize, 2), runs);
}

test "the full block fills every pixel and the empty ranges fill none" {
    const full = render(0x2588);
    var y: u32 = 0;
    while (y < H) : (y += 1) try std.testing.expect(rowFilled(&full, y));

    // Lower half: bottom filled, top clear.
    const lower = render(0x2584);
    try std.testing.expect(rowFilled(&lower, H - 1));
    try std.testing.expect(!rowFilled(&lower, 0));

    // Left half: left column filled, right column clear.
    const left = render(0x258C);
    try std.testing.expect(columnFilled(&left, 0));
    try std.testing.expect(!columnFilled(&left, W - 1));
}

test "eighth blocks grow monotonically" {
    var prev: usize = 0;
    var cp: u32 = 0x2581;
    while (cp <= 0x2588) : (cp += 1) {
        const buf = render(cp);
        var on: usize = 0;
        for (buf) |v| on += @intFromBool(v != 0);
        try std.testing.expect(on > prev);
        prev = on;
    }
}

test "shades are between empty and full, and ordered" {
    var counts: [3]usize = .{ 0, 0, 0 };
    for ([_]u32{ 0x2591, 0x2592, 0x2593 }, 0..) |cp, i| {
        const buf = render(cp);
        for (buf) |v| counts[i] += @intFromBool(v != 0);
    }
    try std.testing.expect(counts[0] > 0);
    try std.testing.expect(counts[0] < counts[1]);
    try std.testing.expect(counts[1] < counts[2]);
    try std.testing.expect(counts[2] < W * H);
}

test "quadrants land in the right corners" {
    const upper_left = render(0x2598);
    try std.testing.expect(upper_left[0] != 0);
    try std.testing.expect(upper_left[W - 1] == 0);
    try std.testing.expect(upper_left[(H - 1) * W] == 0);

    const lower_right = render(0x2597);
    try std.testing.expect(lower_right[0] == 0);
    try std.testing.expect(lower_right[H * W - 1] != 0);
}

test "a Powerline separator is solid at one edge and pointed at the other" {
    const buf = render(0xE0B0);
    // Left edge filled top to bottom, right edge only near the middle.
    try std.testing.expect(buf[0] != 0);
    try std.testing.expect(buf[(H - 1) * W] != 0);
    try std.testing.expect(buf[W - 1] == 0);
    try std.testing.expect(buf[(H / 2) * W + W - 2] != 0);
}

test "covers() agrees with what draw() actually handles" {
    var buf: [W * H]u8 = @splat(0);
    var cp: u32 = 0x2500;
    while (cp <= 0x259F) : (cp += 1) {
        @memset(&buf, 0);
        try std.testing.expect(covers(cp));
        if (!draw(cp, &buf, W, H)) {
            std.debug.print("no drawing for U+{X}\n", .{cp});
            return error.TestUnexpectedResult;
        }
        // Every one of them must put SOMETHING on screen; a blank
        // glyph here would be a silently missing character.
        var on: usize = 0;
        for (buf) |v| on += @intFromBool(v != 0);
        if (on == 0) {
            std.debug.print("blank drawing for U+{X}\n", .{cp});
            return error.TestUnexpectedResult;
        }
    }
    cp = 0xE0B0;
    while (cp <= 0xE0B3) : (cp += 1) {
        @memset(&buf, 0);
        try std.testing.expect(covers(cp));
        try std.testing.expect(draw(cp, &buf, W, H));
    }
    try std.testing.expect(!covers('a'));
    try std.testing.expect(!draw('a', &buf, W, H));
}

test "a one-pixel cell does not crash the renderer" {
    var tiny: [1]u8 = .{0};
    var cp: u32 = 0x2500;
    while (cp <= 0x259F) : (cp += 1) _ = draw(cp, &tiny, 1, 1);
}

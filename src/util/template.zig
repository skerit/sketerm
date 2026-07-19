//! Template (sprite/region) matching on straight-RGBA buffers: the
//! visual substitute for an accessibility tree when driving custom
//! framebuffer apps (games) through the MCP app tools. Pure pixel
//! math, no dependencies — usable from any dependency set.
//!
//! Scoring is mean absolute RGB difference over the considered
//! pixels, mapped to a 0..1 similarity (1 = identical). Needle
//! pixels with alpha < 128 are ignored, so a template cropped with a
//! transparent background matches a non-rectangular sprite.

const std = @import("std");

pub const Error = error{ OutOfMemory, BadTemplate };

pub const Match = struct {
    /// Top-left of the matched region in haystack pixels.
    x: u32,
    y: u32,
    /// 0..1 similarity (1 = pixel-identical over the mask).
    score: f64,
};

pub const Options = struct {
    /// Matches below this similarity are dropped.
    min_score: f64 = 0.95,
    /// Upper bound on returned matches (best-first).
    max_matches: usize = 8,
};

/// Direct-scan work bound before the coarse pre-pass kicks in.
const DIRECT_COST_LIMIT: u64 = 64 << 20;
/// Candidates carried from the coarse pass into full-res refinement.
const MAX_CANDIDATES: usize = 48;
/// Coarse scores are averaged, so a true match can dip below its
/// full-res score; accept coarse candidates this far under min_score.
const COARSE_SLACK: f64 = 0.12;

const Image = struct {
    px: []const u8,
    w: u32,
    h: u32,

    fn at(self: Image, x: u32, y: u32) []const u8 {
        return self.px[(@as(usize, y) * self.w + x) * 4 ..][0..4];
    }
};

/// Sum of absolute RGB differences with the needle placed at (ox,oy),
/// counting only mask pixels; bails once `budget` is exceeded (the
/// caller's worst acceptable total). Returns null on early abort.
fn sadAt(hay: Image, needle: Image, ox: u32, oy: u32, budget: u64) ?u64 {
    var total: u64 = 0;
    var y: u32 = 0;
    while (y < needle.h) : (y += 1) {
        var x: u32 = 0;
        while (x < needle.w) : (x += 1) {
            const n = needle.at(x, y);
            if (n[3] < 128) continue;
            const hpx = hay.at(ox + x, oy + y);
            total += @abs(@as(i32, n[0]) - hpx[0]);
            total += @abs(@as(i32, n[1]) - hpx[1]);
            total += @abs(@as(i32, n[2]) - hpx[2]);
        }
        if (total > budget) return null;
    }
    return total;
}

/// Count of opaque (considered) needle pixels.
fn maskCount(needle: Image) u64 {
    var n: u64 = 0;
    var i: usize = 3;
    while (i < needle.px.len) : (i += 4) {
        if (needle.px[i] >= 128) n += 1;
    }
    return n;
}

fn scoreOf(sad: u64, mask: u64) f64 {
    if (mask == 0) return 0;
    const mad = @as(f64, @floatFromInt(sad)) / @as(f64, @floatFromInt(mask * 3));
    return 1.0 - mad / 255.0;
}

/// Box-downscale by an integer factor, averaging alpha too (a mostly
/// transparent block stays transparent in the coarse mask).
fn shrink(allocator: std.mem.Allocator, img: Image, f: u32) Error!Image {
    const dw = @max(1, img.w / f);
    const dh = @max(1, img.h / f);
    const out = allocator.alloc(u8, @as(usize, dw) * dh * 4) catch return Error.OutOfMemory;
    var dy: u32 = 0;
    while (dy < dh) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < dw) : (dx += 1) {
            var acc = [4]u64{ 0, 0, 0, 0 };
            var n: u64 = 0;
            var sy = dy * f;
            const sy_end = @min(img.h, (dy + 1) * f);
            while (sy < sy_end) : (sy += 1) {
                var sx = dx * f;
                const sx_end = @min(img.w, (dx + 1) * f);
                while (sx < sx_end) : (sx += 1) {
                    const p = img.at(sx, sy);
                    acc[0] += p[0];
                    acc[1] += p[1];
                    acc[2] += p[2];
                    acc[3] += p[3];
                    n += 1;
                }
            }
            const o = (@as(usize, dy) * dw + dx) * 4;
            out[o] = @intCast(acc[0] / n);
            out[o + 1] = @intCast(acc[1] / n);
            out[o + 2] = @intCast(acc[2] / n);
            out[o + 3] = @intCast(acc[3] / n);
        }
    }
    return .{ .px = out, .w = dw, .h = dh };
}

const Candidate = struct { x: u32, y: u32, score: f64 };

fn scanRange(
    hay: Image,
    needle: Image,
    mask: u64,
    min_score: f64,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    out: *std.ArrayList(Candidate),
    allocator: std.mem.Allocator,
    cap: usize,
) Error!void {
    if (mask == 0) return;
    const budget: u64 = @intFromFloat(@max(0.0, 1.0 - min_score) * 255.0 * @as(f64, @floatFromInt(mask * 3)));
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const sad = sadAt(hay, needle, x, y, budget) orelse continue;
            out.append(allocator, .{ .x = x, .y = y, .score = scoreOf(sad, mask) }) catch
                return Error.OutOfMemory;
            if (out.items.len > cap * 4) prune(out, cap);
        }
    }
}

/// Keep the best `cap` candidates (called when the list balloons on a
/// low threshold over a repetitive image).
fn prune(list: *std.ArrayList(Candidate), cap: usize) void {
    std.mem.sort(Candidate, list.items, {}, struct {
        fn gt(_: void, a: Candidate, b: Candidate) bool {
            return a.score > b.score;
        }
    }.gt);
    if (list.items.len > cap) list.shrinkRetainingCapacity(cap);
}

/// Greedy non-max suppression: best score wins, anything overlapping
/// more than half the needle in both axes is folded into it.
fn suppress(list: *std.ArrayList(Candidate), nw: u32, nh: u32) void {
    std.mem.sort(Candidate, list.items, {}, struct {
        fn gt(_: void, a: Candidate, b: Candidate) bool {
            return a.score > b.score;
        }
    }.gt);
    var kept: usize = 0;
    outer: for (list.items) |cand| {
        for (list.items[0..kept]) |k| {
            const dx = @abs(@as(i64, cand.x) - k.x);
            const dy = @abs(@as(i64, cand.y) - k.y);
            if (dx < nw / 2 + 1 and dy < nh / 2 + 1) continue :outer;
        }
        list.items[kept] = cand;
        kept += 1;
    }
    list.shrinkRetainingCapacity(kept);
}

/// Find `needle` in `hay` (both tightly-packed RGBA). Returns matches
/// best-first, non-overlapping, each scoring >= opts.min_score.
/// Caller frees the returned slice.
pub fn find(
    allocator: std.mem.Allocator,
    hay_px: []const u8,
    hay_w: u32,
    hay_h: u32,
    needle_px: []const u8,
    needle_w: u32,
    needle_h: u32,
    opts: Options,
) Error![]Match {
    if (needle_w == 0 or needle_h == 0) return Error.BadTemplate;
    if (needle_px.len < @as(usize, needle_w) * needle_h * 4) return Error.BadTemplate;
    if (hay_px.len < @as(usize, hay_w) * hay_h * 4) return Error.BadTemplate;
    if (needle_w > hay_w or needle_h > hay_h)
        return allocator.alloc(Match, 0) catch Error.OutOfMemory;

    const hay = Image{ .px = hay_px, .w = hay_w, .h = hay_h };
    const needle = Image{ .px = needle_px, .w = needle_w, .h = needle_h };
    const mask = maskCount(needle);
    if (mask == 0) return Error.BadTemplate;

    const span_x = hay_w - needle_w;
    const span_y = hay_h - needle_h;
    const min_score = std.math.clamp(opts.min_score, 0.5, 1.0);

    var cands: std.ArrayList(Candidate) = .empty;
    defer cands.deinit(allocator);

    const direct_cost = @as(u64, span_x + 1) * (span_y + 1) * needle_w * needle_h;
    if (direct_cost <= DIRECT_COST_LIMIT) {
        try scanRange(hay, needle, mask, min_score, 0, 0, span_x, span_y, &cands, allocator, MAX_CANDIDATES);
    } else {
        // Coarse pre-pass: shrink both by f, scan (cost / f^4), then
        // re-score each surviving cell's neighborhood at full res.
        var f: u32 = 2;
        while (f < @min(needle_w, needle_h) / 4 and
            direct_cost / (@as(u64, f) * f * f * f) > DIRECT_COST_LIMIT) f += 1;
        const small_hay = try shrink(allocator, hay, f);
        defer allocator.free(@constCast(small_hay.px));
        const small_needle = try shrink(allocator, needle, f);
        defer allocator.free(@constCast(small_needle.px));
        if (small_needle.w > small_hay.w or small_needle.h > small_hay.h)
            return allocator.alloc(Match, 0) catch Error.OutOfMemory;
        const small_mask = maskCount(small_needle);
        var coarse: std.ArrayList(Candidate) = .empty;
        defer coarse.deinit(allocator);
        try scanRange(
            small_hay,
            small_needle,
            small_mask,
            @max(0.5, min_score - COARSE_SLACK),
            0,
            0,
            small_hay.w - small_needle.w,
            small_hay.h - small_needle.h,
            &coarse,
            allocator,
            MAX_CANDIDATES,
        );
        prune(&coarse, MAX_CANDIDATES);
        for (coarse.items) |cc| {
            // A coarse hit at (cx,cy) covers full-res offsets around
            // (cx*f, cy*f); rescan that neighborhood exactly.
            const cx = cc.x * f;
            const cy = cc.y * f;
            const x0 = if (cx >= f) cx - f else 0;
            const y0 = if (cy >= f) cy - f else 0;
            const x1 = @min(span_x, cx + f);
            const y1 = @min(span_y, cy + f);
            try scanRange(hay, needle, mask, min_score, x0, y0, x1, y1, &cands, allocator, MAX_CANDIDATES);
        }
    }

    suppress(&cands, needle_w, needle_h);
    const n = @min(cands.items.len, @max(1, opts.max_matches));
    const out = allocator.alloc(Match, n) catch return Error.OutOfMemory;
    for (cands.items[0..n], 0..) |cand, i| {
        out[i] = .{ .x = cand.x, .y = cand.y, .score = cand.score };
    }
    return out;
}

// ─── tests ──────────────────────────────────────────────────────

fn fillRect(px: []u8, w: u32, x0: u32, y0: u32, rw: u32, rh: u32, col: [4]u8) void {
    var y = y0;
    while (y < y0 + rh) : (y += 1) {
        var x = x0;
        while (x < x0 + rw) : (x += 1) {
            const o = (@as(usize, y) * w + x) * 4;
            @memcpy(px[o..][0..4], &col);
        }
    }
}

test "find locates an exact sprite" {
    const a = std.testing.allocator;
    const hay = try a.alloc(u8, 64 * 64 * 4);
    defer a.free(hay);
    @memset(hay, 30);
    fillRect(hay, 64, 20, 12, 8, 6, .{ 200, 50, 50, 255 });
    fillRect(hay, 64, 22, 14, 3, 2, .{ 10, 240, 10, 255 });

    // Needle = exact copy of the 10x8 region at (19,11).
    const needle = try a.alloc(u8, 10 * 8 * 4);
    defer a.free(needle);
    var y: u32 = 0;
    while (y < 8) : (y += 1) {
        const src = ((11 + @as(usize, y)) * 64 + 19) * 4;
        @memcpy(needle[y * 10 * 4 ..][0 .. 10 * 4], hay[src..][0 .. 10 * 4]);
    }

    const matches = try find(a, hay, 64, 64, needle, 10, 8, .{});
    defer a.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(u32, 19), matches[0].x);
    try std.testing.expectEqual(@as(u32, 11), matches[0].y);
    try std.testing.expect(matches[0].score > 0.999);
}

test "alpha-masked needle ignores its transparent background" {
    const a = std.testing.allocator;
    const hay = try a.alloc(u8, 40 * 40 * 4);
    defer a.free(hay);
    // Noisy background the mask must not compare against.
    for (hay, 0..) |*b, i| b.* = @truncate(i * 31);
    fillRect(hay, 40, 10, 10, 4, 4, .{ 255, 255, 0, 255 });

    // 8x8 needle: transparent except a 4x4 yellow core at (2,2).
    const needle = try a.alloc(u8, 8 * 8 * 4);
    defer a.free(needle);
    @memset(needle, 0);
    fillRect(needle, 8, 2, 2, 4, 4, .{ 255, 255, 0, 255 });

    const matches = try find(a, hay, 40, 40, needle, 8, 8, .{ .min_score = 0.99 });
    defer a.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(u32, 8), matches[0].x);
    try std.testing.expectEqual(@as(u32, 8), matches[0].y);
}

test "no match below threshold" {
    const a = std.testing.allocator;
    const hay = try a.alloc(u8, 32 * 32 * 4);
    defer a.free(hay);
    @memset(hay, 0);
    const needle = try a.alloc(u8, 6 * 6 * 4);
    defer a.free(needle);
    @memset(needle, 255);
    const matches = try find(a, hay, 32, 32, needle, 6, 6, .{});
    defer a.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "multiple matches are found and suppressed to distinct spots" {
    const a = std.testing.allocator;
    const hay = try a.alloc(u8, 80 * 30 * 4);
    defer a.free(hay);
    @memset(hay, 15);
    fillRect(hay, 80, 5, 10, 6, 6, .{ 220, 220, 220, 255 });
    fillRect(hay, 80, 50, 12, 6, 6, .{ 220, 220, 220, 255 });
    const needle = try a.alloc(u8, 6 * 6 * 4);
    defer a.free(needle);
    fillRect(needle, 6, 0, 0, 6, 6, .{ 220, 220, 220, 255 });
    const matches = try find(a, hay, 80, 30, needle, 6, 6, .{});
    defer a.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    // Best-first, both exact; order by position not guaranteed.
    var seen_a = false;
    var seen_b = false;
    for (matches) |m| {
        if (m.x == 5 and m.y == 10) seen_a = true;
        if (m.x == 50 and m.y == 12) seen_b = true;
    }
    try std.testing.expect(seen_a and seen_b);
}

test "coarse pre-pass path still finds the sprite exactly" {
    const a = std.testing.allocator;
    // 300x300 with a 40x40 needle: direct cost ~109M > limit.
    const W = 300;
    const hay = try a.alloc(u8, W * W * 4);
    defer a.free(hay);
    @memset(hay, 40);
    fillRect(hay, W, 211, 137, 30, 30, .{ 180, 30, 90, 255 });
    fillRect(hay, W, 217, 143, 12, 12, .{ 30, 180, 200, 255 });

    const needle = try a.alloc(u8, 40 * 40 * 4);
    defer a.free(needle);
    var y: u32 = 0;
    while (y < 40) : (y += 1) {
        const src = ((132 + @as(usize, y)) * W + 206) * 4;
        @memcpy(needle[y * 40 * 4 ..][0 .. 40 * 4], hay[src..][0 .. 40 * 4]);
    }
    const matches = try find(a, hay, W, W, needle, 40, 40, .{});
    defer a.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(u32, 206), matches[0].x);
    try std.testing.expectEqual(@as(u32, 132), matches[0].y);
    try std.testing.expect(matches[0].score > 0.999);
}

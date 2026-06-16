//! Per-tile churn classifier — decides which regions of a surface are
//! "hot" (changing nearly every frame) vs "cold" (static or occasional).
//!
//! This is the routing brain for the pixel pipeline: hot regions are
//! the ones a video codec pays off on (temporal prediction across
//! frames), while cold regions want the lossless predictor+zstd path.
//! Phase 3 builds and tests the classifier in isolation; the daemon /
//! winstream source wire it in when there's a lossy coder to route to
//! (Phase 4) — until then everything still encodes lossless.
//!
//! Pure std, no allocator-of-the-hot-path surprises: one byte of heat
//! per tile, updated O(touched tiles) per frame. Transport-agnostic —
//! Wayland damage rows and macOS SCK dirty rects both feed the same
//! `noteDamage` → `endFrame` cycle. Daemon-safe (no GTK/GL).

const std = @import("std");

pub const Options = struct {
    /// Tile edge in pixels. Coarser = cheaper + steadier classification;
    /// finer = tighter routing. 64 matches a typical codec macro-tile.
    tile: u32 = 64,
    /// Heat at/above which a tile counts as hot.
    hot_threshold: u8 = 4,
    /// Heat ceiling — caps how "sticky" a long-hot tile stays as it
    /// cools (bounds the decay tail).
    cap: u8 = 8,
    /// Heat lost per frame a tile is NOT touched.
    decay: u8 = 1,
    /// A region is hot if at least this fraction of the tiles it covers
    /// are hot (0..100). 50 = majority.
    hot_coverage_pct: u8 = 50,
};

pub const Tracker = struct {
    allocator: std.mem.Allocator,
    opts: Options,
    cols: u32 = 0,
    rows: u32 = 0,
    /// Heat per tile, row-major (cols*rows).
    heat: []u8 = &.{},
    /// Touched-this-frame flag per tile; cleared by endFrame.
    touched: []bool = &.{},

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32, opts: Options) !Tracker {
        var self: Tracker = .{ .allocator = allocator, .opts = opts };
        try self.resize(width, height);
        return self;
    }

    pub fn deinit(self: *Tracker) void {
        self.allocator.free(self.heat);
        self.allocator.free(self.touched);
        self.* = undefined;
    }

    fn tileCount(opts: Options, px: u32) u32 {
        if (px == 0) return 0;
        return (px + opts.tile - 1) / opts.tile;
    }

    /// Resize the grid to a new surface size, resetting all heat (a
    /// resize is a discontinuity — old tile coords no longer line up).
    pub fn resize(self: *Tracker, width: u32, height: u32) !void {
        const cols = tileCount(self.opts, width);
        const rows = tileCount(self.opts, height);
        const n = cols * rows;
        if (n != self.heat.len) {
            self.allocator.free(self.heat);
            self.allocator.free(self.touched);
            self.heat = try self.allocator.alloc(u8, n);
            self.touched = try self.allocator.alloc(bool, n);
        }
        self.cols = cols;
        self.rows = rows;
        @memset(self.heat, 0);
        @memset(self.touched, false);
    }

    /// Inclusive tile range covered by a pixel rect, clamped to the grid.
    /// Returns null when the rect is empty or entirely outside.
    fn tileSpan(self: *const Tracker, x: i32, y: i32, w: i32, h: i32) ?struct { c0: u32, c1: u32, r0: u32, r1: u32 } {
        if (w <= 0 or h <= 0 or self.cols == 0 or self.rows == 0) return null;
        const tile: i64 = self.opts.tile;
        const x0 = @max(x, 0);
        const y0 = @max(y, 0);
        const x1 = x + w - 1;
        const y1 = y + h - 1;
        if (x1 < 0 or y1 < 0) return null;
        const c0: i64 = @divFloor(@as(i64, x0), tile);
        const r0: i64 = @divFloor(@as(i64, y0), tile);
        const c1: i64 = @divFloor(@as(i64, x1), tile);
        const r1: i64 = @divFloor(@as(i64, y1), tile);
        if (c0 >= self.cols or r0 >= self.rows) return null;
        return .{
            .c0 = @intCast(c0),
            .c1 = @intCast(@min(c1, self.cols - 1)),
            .r0 = @intCast(r0),
            .r1 = @intCast(@min(r1, self.rows - 1)),
        };
    }

    /// Mark every tile overlapping `(x,y,w,h)` as touched this frame.
    pub fn noteDamage(self: *Tracker, x: i32, y: i32, w: i32, h: i32) void {
        const span = self.tileSpan(x, y, w, h) orelse return;
        var r = span.r0;
        while (r <= span.r1) : (r += 1) {
            var col = span.c0;
            while (col <= span.c1) : (col += 1) {
                self.touched[r * self.cols + col] = true;
            }
        }
    }

    /// End the frame: touched tiles heat up (capped), untouched cool by
    /// `decay`, and the touched flags reset for the next frame.
    pub fn endFrame(self: *Tracker) void {
        for (self.heat, self.touched) |*hv, *tv| {
            if (tv.*) {
                hv.* = @min(self.opts.cap, hv.* +| 1);
            } else {
                hv.* -|= self.opts.decay;
            }
            tv.* = false;
        }
    }

    fn tileHot(self: *const Tracker, idx: usize) bool {
        return self.heat[idx] >= self.opts.hot_threshold;
    }

    /// Is `(x,y,w,h)` predominantly hot — i.e. should it route to the
    /// lossy/temporal path? False for empty/out-of-grid rects.
    pub fn hot(self: *const Tracker, x: i32, y: i32, w: i32, h: i32) bool {
        const span = self.tileSpan(x, y, w, h) orelse return false;
        var total: u32 = 0;
        var hots: u32 = 0;
        var r = span.r0;
        while (r <= span.r1) : (r += 1) {
            var col = span.c0;
            while (col <= span.c1) : (col += 1) {
                total += 1;
                if (self.tileHot(r * self.cols + col)) hots += 1;
            }
        }
        if (total == 0) return false;
        return hots * 100 >= total * self.opts.hot_coverage_pct;
    }
};

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

fn frames(tr: *Tracker, n: usize, x: i32, y: i32, w: i32, h: i32) void {
    for (0..n) |_| {
        tr.noteDamage(x, y, w, h);
        tr.endFrame();
    }
}

test "a region touched every frame becomes hot after hot_threshold frames" {
    var tr = try Tracker.init(t.allocator, 256, 256, .{ .tile = 64, .hot_threshold = 4 });
    defer tr.deinit();

    // 3 frames: still cold (heat 3 < 4).
    frames(&tr, 3, 0, 0, 64, 64);
    try t.expect(!tr.hot(0, 0, 64, 64));
    // 4th frame crosses the threshold.
    frames(&tr, 1, 0, 0, 64, 64);
    try t.expect(tr.hot(0, 0, 64, 64));
}

test "a one-shot change never goes hot and decays back to cold" {
    var tr = try Tracker.init(t.allocator, 256, 256, .{ .tile = 64, .hot_threshold = 4, .decay = 1, .cap = 8 });
    defer tr.deinit();

    tr.noteDamage(0, 0, 64, 64);
    tr.endFrame();
    try t.expect(!tr.hot(0, 0, 64, 64)); // heat 1
    // Idle frames decay it to 0.
    frames(&tr, 3, 200, 200, 8, 8); // touch elsewhere
    try t.expect(!tr.hot(0, 0, 64, 64));
}

test "a hot region cools to cold once it goes quiet" {
    var tr = try Tracker.init(t.allocator, 128, 128, .{ .tile = 64, .hot_threshold = 4, .cap = 8, .decay = 1 });
    defer tr.deinit();

    frames(&tr, 8, 0, 0, 64, 64); // saturate to cap=8
    try t.expect(tr.hot(0, 0, 64, 64));
    // Go quiet: heat 8 → needs >4 decays to drop below 4.
    frames(&tr, 4, 100, 100, 8, 8); // 8 - 4 = 4, still hot
    try t.expect(tr.hot(0, 0, 64, 64));
    frames(&tr, 1, 100, 100, 8, 8); // 4 - 1 = 3, cold
    try t.expect(!tr.hot(0, 0, 64, 64));
}

test "coverage: a rect spanning hot+cold tiles needs the majority hot" {
    var tr = try Tracker.init(t.allocator, 256, 64, .{ .tile = 64, .hot_threshold = 1, .hot_coverage_pct = 50 });
    defer tr.deinit();
    // 4 tiles across. Heat the left two every frame.
    frames(&tr, 2, 0, 0, 128, 64);
    // Rect over tiles 0..1 (both hot) → hot.
    try t.expect(tr.hot(0, 0, 128, 64));
    // Rect over tiles 1..3: 1 hot of 3 (<50%) → cold.
    try t.expect(!tr.hot(64, 0, 192, 64));
    // Rect over tiles 0..1..2: 2 hot of 3 (>=50%) → hot.
    try t.expect(tr.hot(0, 0, 160, 64));
}

test "out-of-bounds, empty, and degenerate inputs are safe" {
    var tr = try Tracker.init(t.allocator, 100, 100, .{ .tile = 64 });
    defer tr.deinit();
    tr.noteDamage(-50, -50, 10, 10); // fully off top-left
    tr.noteDamage(1000, 1000, 10, 10); // fully off bottom-right
    tr.noteDamage(0, 0, 0, 0); // empty
    tr.endFrame();
    try t.expect(!tr.hot(0, 0, 100, 100));
    try t.expect(!tr.hot(-10, -10, 5, 5));

    // Zero-size surface: no tiles, all queries false, no crash.
    var empty = try Tracker.init(t.allocator, 0, 0, .{});
    defer empty.deinit();
    empty.noteDamage(0, 0, 10, 10);
    empty.endFrame();
    try t.expect(!empty.hot(0, 0, 10, 10));
}

test "resize resets heat (tile coords no longer align)" {
    var tr = try Tracker.init(t.allocator, 128, 128, .{ .tile = 64, .hot_threshold = 4 });
    defer tr.deinit();
    frames(&tr, 6, 0, 0, 64, 64);
    try t.expect(tr.hot(0, 0, 64, 64));
    try tr.resize(256, 256);
    try t.expect(!tr.hot(0, 0, 64, 64)); // wiped
    try t.expectEqual(@as(u32, 4), tr.cols);
    try t.expectEqual(@as(u32, 4), tr.rows);
}

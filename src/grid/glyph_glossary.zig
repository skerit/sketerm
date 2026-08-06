//! Per-Screen glossary of Glyph Protocol registrations.
//!
//! 1024 slots keyed by PUA codepoint. A full glossary evicts the
//! OLDEST entry (FIFO by `insertion`); overwriting an existing
//! codepoint reuses its slot and does NOT refresh its eviction age.
//! Survives RIS and alternate-screen switches (Rio parity) — only
//! `c` (clear) and session teardown empty it.
//!
//! `render_key` is minted from a PROCESS-WIDE counter on EVERY
//! register (including overwrite): the GUI atlas is per-window and
//! shared by all panes while glossaries are per-Screen, so two panes
//! may legally hold different glyphs at the same codepoint — the
//! atlas keys on `render_key`, which makes stale rasterisations
//! unreachable by construction (no explicit invalidation needed).
//!
//! GTK-free; compiles into `sketerm-mux`.

const std = @import("std");

const glyph_protocol = @import("../parser/glyph_protocol.zig");
pub const isPua = glyph_protocol.isPua;
pub const Format = glyph_protocol.Format;

/// Maximum simultaneous registrations per session (spec section 4).
pub const CAPACITY: usize = 1024;

/// Process-wide render-key mint. Starts at 1 so 0 can never collide
/// with a live key.
var next_render_key = std.atomic.Value(u64).init(1);

pub const Entry = struct {
    /// Raw payload (glyf record or colrv0 container), owned by the
    /// glossary's allocator.
    payload: []u8,
    fmt: Format,
    upm: u16,
    /// Render span (1 or 2) — paint hint, never layout.
    width: u8,
    /// FIFO age. Preserved across overwrites.
    insertion: u64,
    /// Atlas cache key; unique per register call, process-wide.
    render_key: u64,
};

pub const Glossary = struct {
    map: std.AutoHashMap(u32, Entry),
    next_insertion: u64 = 0,
    /// Bumped on any mutation. Renderers snapshot it to detect that
    /// visible cells need re-resolving against the glossary.
    generation: u64 = 0,
    /// Total payload bytes held — snapshot budget accounting.
    payload_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Glossary {
        return .{ .map = std.AutoHashMap(u32, Entry).init(allocator) };
    }

    pub fn deinit(self: *Glossary) void {
        var it = self.map.iterator();
        while (it.next()) |kv| self.map.allocator.free(kv.value_ptr.payload);
        self.map.deinit();
    }

    /// Register `cp`, adopting ownership of `payload` (freed by the
    /// glossary on overwrite/clear/evict/deinit — and immediately on
    /// error). Caller has already validated cp is PUA and the payload
    /// is a structurally sound simple glyph.
    pub fn registerAdopt(self: *Glossary, cp: u32, payload: []u8, fmt: Format, upm: u16, width: u8) !void {
        if (!isPua(cp)) {
            // Defence in depth — the parser rejects this earlier.
            self.map.allocator.free(payload);
            return error.OutOfNamespace;
        }
        const rk = next_render_key.fetchAdd(1, .monotonic);
        if (self.map.getPtr(cp)) |e| {
            // Overwrite: slot reused, `insertion` (eviction age) kept.
            self.payload_bytes -= e.payload.len;
            self.map.allocator.free(e.payload);
            e.payload = payload;
            e.fmt = fmt;
            e.upm = upm;
            e.width = width;
            e.render_key = rk;
            self.payload_bytes += payload.len;
            self.generation += 1;
            return;
        }
        if (self.map.count() >= CAPACITY) self.evictOldest();
        self.map.put(cp, .{
            .payload = payload,
            .fmt = fmt,
            .upm = upm,
            .width = width,
            .insertion = self.next_insertion,
            .render_key = rk,
        }) catch |err| {
            self.map.allocator.free(payload);
            return err;
        };
        self.next_insertion += 1;
        self.payload_bytes += payload.len;
        self.generation += 1;
    }

    /// Snapshot-restore path: like `registerAdopt` but with an
    /// explicit insertion stamp so FIFO order survives reattach. The
    /// render_key is still freshly minted — keys from another process
    /// are meaningless here.
    pub fn registerRestored(self: *Glossary, cp: u32, payload: []u8, fmt: Format, upm: u16, width: u8, insertion: u64) !void {
        try self.registerAdopt(cp, payload, fmt, upm, width);
        const e = self.map.getPtr(cp) orelse return;
        e.insertion = insertion;
        if (insertion >= self.next_insertion) self.next_insertion = insertion + 1;
    }

    fn evictOldest(self: *Glossary) void {
        var oldest_cp: ?u32 = null;
        var oldest_ins: u64 = std.math.maxInt(u64);
        var it = self.map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.insertion < oldest_ins) {
                oldest_ins = kv.value_ptr.insertion;
                oldest_cp = kv.key_ptr.*;
            }
        }
        if (oldest_cp) |cp| self.clearOne(cp);
    }

    /// Clear one codepoint. Clearing an empty slot is a success no-op
    /// (and does not bump the generation — nothing visible changed).
    pub fn clearOne(self: *Glossary, cp: u32) void {
        if (self.map.fetchRemove(cp)) |kv| {
            self.payload_bytes -= kv.value.payload.len;
            self.map.allocator.free(kv.value.payload);
            self.generation += 1;
        }
    }

    pub fn clearAll(self: *Glossary) void {
        if (self.map.count() == 0) return;
        var it = self.map.iterator();
        while (it.next()) |kv| self.map.allocator.free(kv.value_ptr.payload);
        self.map.clearRetainingCapacity();
        self.payload_bytes = 0;
        self.generation += 1;
    }

    /// Borrowed view — the payload slice is valid until the next
    /// mutating call on this glossary.
    pub fn get(self: *const Glossary, cp: u32) ?Entry {
        return self.map.get(cp);
    }

    pub fn contains(self: *const Glossary, cp: u32) bool {
        return self.map.contains(cp);
    }

    pub fn count(self: *const Glossary) usize {
        return self.map.count();
    }
};

// ── tests ────────────────────────────────────────────────────────

const testing = std.testing;

fn reg(g: *Glossary, cp: u32, bytes: []const u8, upm: u16, width: u8) !void {
    const owned = try g.map.allocator.dupe(u8, bytes);
    try g.registerAdopt(cp, owned, .glyf, upm, width);
}

test "register and lookup" {
    var g = Glossary.init(testing.allocator);
    defer g.deinit();
    try reg(&g, 0xE0A0, &.{ 1, 2, 3 }, 1000, 1);
    const e = g.get(0xE0A0).?;
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, e.payload);
    try testing.expectEqual(@as(u16, 1000), e.upm);
    try testing.expectEqual(@as(u8, 1), e.width);
    try testing.expect(g.contains(0xE0A0));
    try testing.expectEqual(@as(usize, 1), g.count());
    try testing.expectEqual(@as(usize, 3), g.payload_bytes);
}

test "register rejects non-PUA (defence in depth)" {
    var g = Glossary.init(testing.allocator);
    defer g.deinit();
    const owned = try testing.allocator.dupe(u8, &.{1});
    try testing.expectError(error.OutOfNamespace, g.registerAdopt(0x61, owned, .glyf, 1000, 1));
    try testing.expectEqual(@as(usize, 0), g.count());
}

test "overwrite preserves insertion age, bumps render_key and generation" {
    var g = Glossary.init(testing.allocator);
    defer g.deinit();
    try reg(&g, 0xE0A0, &.{1}, 1000, 1);
    try reg(&g, 0xE0A1, &.{2}, 1000, 1);
    const first = g.get(0xE0A0).?;
    const gen_before = g.generation;
    try reg(&g, 0xE0A0, &.{ 9, 9 }, 2048, 2);
    const after = g.get(0xE0A0).?;
    const other = g.get(0xE0A1).?;
    try testing.expectEqualSlices(u8, &.{ 9, 9 }, after.payload);
    try testing.expectEqual(@as(u16, 2048), after.upm);
    try testing.expectEqual(@as(u8, 2), after.width);
    try testing.expectEqual(first.insertion, after.insertion);
    try testing.expect(after.insertion < other.insertion);
    try testing.expect(after.render_key != first.render_key);
    try testing.expect(g.generation > gen_before);
    try testing.expectEqual(@as(usize, 3), g.payload_bytes);
}

test "clear-then-reregister yields a fresh render_key" {
    var g = Glossary.init(testing.allocator);
    defer g.deinit();
    try reg(&g, 0xE0A0, &.{1}, 1000, 1);
    const rk1 = g.get(0xE0A0).?.render_key;
    g.clearOne(0xE0A0);
    try reg(&g, 0xE0A0, &.{2}, 1000, 1);
    try testing.expect(g.get(0xE0A0).?.render_key != rk1);
}

test "clear semantics: one, unknown no-op, all" {
    var g = Glossary.init(testing.allocator);
    defer g.deinit();
    try reg(&g, 0xE0A0, &.{1}, 1000, 1);
    try reg(&g, 0xE0A1, &.{2}, 1000, 1);
    const gen = g.generation;
    g.clearOne(0xF000); // empty slot — success no-op, no gen bump
    try testing.expectEqual(gen, g.generation);
    g.clearOne(0xE0A0);
    try testing.expect(!g.contains(0xE0A0));
    try testing.expect(g.contains(0xE0A1));
    try testing.expect(g.generation > gen);
    g.clearAll();
    try testing.expectEqual(@as(usize, 0), g.count());
    try testing.expectEqual(@as(usize, 0), g.payload_bytes);
    const gen2 = g.generation;
    g.clearAll(); // already empty — no bump
    try testing.expectEqual(gen2, g.generation);
}

test "FIFO eviction at capacity; overwrite at capacity does not evict" {
    var g = Glossary.init(testing.allocator);
    defer g.deinit();
    var i: u32 = 0;
    while (i < CAPACITY) : (i += 1) {
        try reg(&g, 0xE000 + i, &.{@truncate(i)}, 1000, 1);
    }
    try testing.expectEqual(CAPACITY, g.count());

    // Overwriting an existing codepoint at capacity must not evict.
    try reg(&g, 0xE000, &.{0xAB}, 1000, 1);
    try testing.expectEqual(CAPACITY, g.count());
    try testing.expectEqualSlices(u8, &.{0xAB}, g.get(0xE000).?.payload);

    // The 1025th distinct registration evicts the oldest (U+E000 —
    // its age was preserved by the overwrite above).
    try reg(&g, 0xE500, &.{0xFF}, 1000, 1);
    try testing.expectEqual(CAPACITY, g.count());
    try testing.expect(!g.contains(0xE000));
    try testing.expect(g.contains(0xE500));
    try testing.expect(g.contains(0xE001));
}

test "registerRestored keeps FIFO stamps and advances the mint" {
    var g = Glossary.init(testing.allocator);
    defer g.deinit();
    const p1 = try testing.allocator.dupe(u8, &.{1});
    try g.registerRestored(0xE0A0, p1, .colrv0, 1000, 1, 41);
    const p2 = try testing.allocator.dupe(u8, &.{2});
    try g.registerRestored(0xE0A1, p2, .glyf, 1000, 2, 7);
    try testing.expectEqual(@as(u64, 41), g.get(0xE0A0).?.insertion);
    try testing.expectEqual(Format.colrv0, g.get(0xE0A0).?.fmt);
    try testing.expectEqual(@as(u64, 7), g.get(0xE0A1).?.insertion);
    // New registrations land after the highest restored stamp.
    try reg(&g, 0xE0A2, &.{3}, 1000, 1);
    try testing.expect(g.get(0xE0A2).?.insertion > 41);
}

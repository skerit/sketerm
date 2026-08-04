//! Diagnostics store: the server's `publishDiagnostics` payload
//! converted ONCE into document byte offsets and then maintained like
//! any other anchored position set.
//!
//! Why byte offsets and not the LSP line/character pairs: a diagnostic
//! outlives the revision it was computed for (the user keeps typing
//! while the server thinks), and the editor already has exactly one
//! machinery for carrying positions across edits — `tr.mapOffset`, the
//! same primitive selections and fold anchors use. Keeping LSP
//! coordinates would mean re-deriving offsets against a moved document
//! on every frame, which is both slower and wrong.
//!
//! `revision` records the document revision the offsets are exact for.
//! After `mapThrough` they are approximate-but-anchored: good enough to
//! keep a squiggle under the right identifier while you type, and
//! replaced wholesale by the next publish.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tr = @import("../editor/transaction.zig");

pub const Severity = enum(u8) {
    err = 1,
    warning = 2,
    information = 3,
    hint = 4,

    pub fn fromInt(i: i64) Severity {
        return switch (i) {
            1 => .err,
            2 => .warning,
            3 => .information,
            4 => .hint,
            // LSP says an absent severity is client's choice; an
            // unlabelled diagnostic is almost always an error.
            else => .err,
        };
    }

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .information => "info",
            .hint => "hint",
        };
    }
};

pub const Diagnostic = struct {
    start: usize,
    end: usize,
    severity: Severity,
    /// Owned by the store.
    message: []u8,
    /// Owned; empty when the server did not say ("zls", "clang", …).
    source: []u8,
};

pub const Store = struct {
    alloc: Allocator,
    items: std.ArrayList(Diagnostic) = .empty,
    /// Document revision `items` offsets were exact for.
    revision: u64 = 0,
    /// True once a publish has landed — distinguishes "no problems"
    /// from "the server has not answered yet".
    published: bool = false,

    pub fn init(alloc: Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Store) void {
        self.clear();
        self.items.deinit(self.alloc);
    }

    pub fn clear(self: *Store) void {
        for (self.items.items) |d| {
            self.alloc.free(d.message);
            self.alloc.free(d.source);
        }
        self.items.clearRetainingCapacity();
    }

    /// Replace the whole set (LSP publishes are always complete).
    /// Items are sorted by start offset so navigation and the render
    /// pass can both walk them linearly.
    pub fn replace(self: *Store, revision: u64, incoming: []const Diagnostic) Allocator.Error!void {
        self.clear();
        try self.items.ensureTotalCapacity(self.alloc, incoming.len);
        for (incoming) |d| {
            self.items.appendAssumeCapacity(.{
                .start = d.start,
                .end = d.end,
                .severity = d.severity,
                .message = try self.alloc.dupe(u8, d.message),
                .source = try self.alloc.dupe(u8, d.source),
            });
        }
        std.mem.sort(Diagnostic, self.items.items, {}, lessByStart);
        self.revision = revision;
        self.published = true;
    }

    fn lessByStart(_: void, a: Diagnostic, b: Diagnostic) bool {
        if (a.start != b.start) return a.start < b.start;
        return a.end < b.end;
    }

    /// Carry the anchors across an edit list (pre-transaction
    /// coordinates, exactly what `Document.EditObserver` hands out).
    pub fn mapThrough(self: *Store, edits: []const tr.Edit) void {
        if (self.items.items.len == 0) return;
        for (self.items.items) |*d| {
            const s = tr.mapOffset(edits, d.start, .other);
            const e = tr.mapOffset(edits, d.end, .other);
            d.start = s;
            d.end = @max(e, s);
        }
    }

    /// Innermost diagnostic covering `offset` (the smallest range
    /// wins, so a squiggle inside a statement-wide error still shows
    /// its own message).
    pub fn at(self: *const Store, offset: usize) ?*const Diagnostic {
        var best: ?*const Diagnostic = null;
        for (self.items.items) |*d| {
            const end = if (d.end > d.start) d.end else d.start + 1;
            if (offset < d.start or offset >= end) continue;
            if (best) |b| {
                if ((d.end - d.start) >= (b.end - b.start)) continue;
            }
            best = d;
        }
        return best;
    }

    /// Next diagnostic start strictly after (or before) `offset`,
    /// wrapping around the document — "go to next problem" behaviour.
    pub fn step(self: *const Store, offset: usize, forward: bool) ?usize {
        if (self.items.items.len == 0) return null;
        if (forward) {
            for (self.items.items) |d| {
                if (d.start > offset) return d.start;
            }
            return self.items.items[0].start;
        }
        var i = self.items.items.len;
        while (i > 0) {
            i -= 1;
            if (self.items.items[i].start < offset) return self.items.items[i].start;
        }
        return self.items.items[self.items.items.len - 1].start;
    }

    pub const Counts = struct { errors: usize = 0, warnings: usize = 0, other: usize = 0 };

    pub fn counts(self: *const Store) Counts {
        var out = Counts{};
        for (self.items.items) |d| {
            switch (d.severity) {
                .err => out.errors += 1,
                .warning => out.warnings += 1,
                else => out.other += 1,
            }
        }
        return out;
    }

    /// Highest severity on `line` (for the gutter marker), or null.
    pub fn severityOnLine(self: *const Store, line_start: usize, line_end: usize) ?Severity {
        var best: ?Severity = null;
        for (self.items.items) |d| {
            const end = @max(d.end, d.start);
            if (end < line_start or d.start > line_end) continue;
            if (best == null or @intFromEnum(d.severity) < @intFromEnum(best.?)) best = d.severity;
        }
        return best;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

fn mk(start: usize, end: usize, sev: Severity, msg: []const u8) Diagnostic {
    return .{
        .start = start,
        .end = end,
        .severity = sev,
        .message = @constCast(msg),
        .source = @constCast(@as([]const u8, "")),
    };
}

test "diagnostics: replace sorts and owns its strings" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try testing.expect(!s.published);
    try s.replace(7, &.{
        mk(40, 44, .warning, "later"),
        mk(10, 14, .err, "earlier"),
    });
    try testing.expect(s.published);
    try testing.expectEqual(@as(u64, 7), s.revision);
    try testing.expectEqual(@as(usize, 10), s.items.items[0].start);
    try testing.expectEqualStrings("earlier", s.items.items[0].message);
    // Replacing again frees the previous set (leak-checked by the
    // testing allocator).
    try s.replace(8, &.{mk(1, 2, .hint, "only")});
    try testing.expectEqual(@as(usize, 1), s.items.items.len);
}

test "diagnostics: counts and severityOnLine pick the worst" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.replace(1, &.{
        mk(0, 3, .warning, "w"),
        mk(1, 2, .err, "e"),
        mk(80, 90, .hint, "h"),
    });
    const c = s.counts();
    try testing.expectEqual(@as(usize, 1), c.errors);
    try testing.expectEqual(@as(usize, 1), c.warnings);
    try testing.expectEqual(@as(usize, 1), c.other);
    try testing.expectEqual(Severity.err, s.severityOnLine(0, 10).?);
    try testing.expectEqual(Severity.hint, s.severityOnLine(70, 95).?);
    try testing.expect(s.severityOnLine(20, 30) == null);
}

test "diagnostics: at picks the innermost range" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.replace(1, &.{
        mk(0, 100, .warning, "statement"),
        mk(10, 14, .err, "identifier"),
    });
    try testing.expectEqualStrings("identifier", s.at(12).?.message);
    try testing.expectEqualStrings("statement", s.at(50).?.message);
    try testing.expect(s.at(200) == null);
}

test "diagnostics: a zero-width diagnostic still covers its own offset" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.replace(1, &.{mk(5, 5, .err, "expected ;")});
    try testing.expectEqualStrings("expected ;", s.at(5).?.message);
    try testing.expect(s.at(4) == null);
}

test "diagnostics: step wraps in both directions" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.replace(1, &.{ mk(10, 12, .err, "a"), mk(30, 32, .err, "b") });
    try testing.expectEqual(@as(usize, 10), s.step(0, true).?);
    try testing.expectEqual(@as(usize, 30), s.step(10, true).?);
    try testing.expectEqual(@as(usize, 10), s.step(99, true).?); // wrap
    try testing.expectEqual(@as(usize, 30), s.step(99, false).?);
    try testing.expectEqual(@as(usize, 30), s.step(0, false).?); // wrap
}

test "diagnostics: mapThrough carries anchors across an edit" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.replace(1, &.{ mk(20, 25, .err, "a"), mk(4, 6, .warning, "b") });
    // Insert 3 bytes at offset 10: everything after it shifts.
    const edits = [_]tr.Edit{.{ .offset = 10, .deleted_len = 0, .inserted = "xyz" }};
    s.mapThrough(&edits);
    // Sorted, so index 0 is the one that started at 4.
    try testing.expectEqual(@as(usize, 4), s.items.items[0].start);
    try testing.expectEqual(@as(usize, 23), s.items.items[1].start);
    try testing.expectEqual(@as(usize, 28), s.items.items[1].end);
}

test "diagnostics: a deletion swallowing a range collapses it, never inverts it" {
    var s = Store.init(testing.allocator);
    defer s.deinit();
    try s.replace(1, &.{mk(10, 20, .err, "gone")});
    const edits = [_]tr.Edit{.{ .offset = 5, .deleted_len = 30, .inserted = "" }};
    s.mapThrough(&edits);
    try testing.expectEqual(@as(usize, 5), s.items.items[0].start);
    try testing.expect(s.items.items[0].end >= s.items.items[0].start);
}

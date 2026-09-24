//! Batch rename planning: what a find/replace over the selected
//! basenames WOULD do, computed before anything is sent, so the dialog
//! can preview it and the verb can refuse a plan that collides.
//!
//! Pure data (no GTK, no IO), in both test roots. The GUI's
//! `ops.batchRenameSelected` executes a `Plan`; its preview label and
//! its final count come from the same numbers.
//!
//! The undo record of a finished batch is ONE entry holding every
//! pair that actually landed (`encodePairs`), so a single Ctrl+Z puts
//! the whole batch back, in reverse order: renames ran deepest first,
//! so the reverse restores each parent before the child path under it
//! is used again.

const std = @import("std");

pub const Item = struct {
    /// Full path as selected.
    from: []const u8,
    /// Full path after the rename; owned by the Plan.
    to: []u8,
};

pub const Problem = enum {
    none,
    /// The pattern is empty.
    empty_find,
    /// The replacement would put a '/' (or NUL) in a basename.
    bad_replacement,
    /// Two selected entries would end up with the same path.
    duplicate_target,
    /// A rename produces an empty basename, "." or "..".
    bad_name,
};

pub const Plan = struct {
    /// Entries the pattern changes, in execution order (deepest first).
    items: []Item,
    /// Entries the pattern leaves alone.
    unchanged: usize,
    problem: Problem = .none,
    /// Index into `items` of the first colliding / bad entry.
    problem_at: usize = 0,

    pub fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
        for (self.items) |it| allocator.free(it.to);
        allocator.free(self.items);
        self.* = undefined;
    }

    pub fn ok(self: *const Plan) bool {
        return self.problem == .none and self.items.len > 0;
    }
};

/// Replace every occurrence of `find` in `base`. Null when it does
/// not occur.
pub fn replaceAll(allocator: std.mem.Allocator, base: []const u8, find: []const u8, repl: []const u8) !?[]u8 {
    if (find.len == 0 or std.mem.indexOf(u8, base, find) == null) return null;
    return try std.mem.replaceOwned(u8, allocator, base, find, repl);
}

/// Plan the renames of `paths` (full paths on one host). The order of
/// `items` is deepest first, the order the renames must run in.
pub fn plan(allocator: std.mem.Allocator, paths: []const []const u8, find: []const u8, repl: []const u8) !Plan {
    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |it| allocator.free(it.to);
        items.deinit(allocator);
    }
    var result: Plan = .{ .items = &.{}, .unchanged = 0 };
    if (find.len == 0) result.problem = .empty_find;
    if (std.mem.indexOfAny(u8, repl, "/\x00") != null) result.problem = .bad_replacement;

    // Deepest first (stable): a child's path is strictly longer.
    const order = try allocator.alloc(usize, paths.len);
    defer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    const Ctx = struct {
        paths: []const []const u8,
        fn deeper(self: @This(), a: usize, b: usize) bool {
            return self.paths[a].len > self.paths[b].len;
        }
    };
    std.mem.sort(usize, order, Ctx{ .paths = paths }, Ctx.deeper);

    for (order) |idx| {
        const from = paths[idx];
        const base = std.fs.path.basename(from);
        const parent = std.fs.path.dirname(from) orelse {
            result.unchanged += 1;
            continue;
        };
        const nb = (if (result.problem == .empty_find) null else try replaceAll(allocator, base, find, repl)) orelse {
            result.unchanged += 1;
            continue;
        };
        defer allocator.free(nb);
        if (std.mem.eql(u8, nb, base)) {
            result.unchanged += 1;
            continue;
        }
        const to = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ if (parent.len == 1) "" else parent, nb });
        errdefer allocator.free(to);
        if (result.problem == .none and (nb.len == 0 or std.mem.eql(u8, nb, ".") or std.mem.eql(u8, nb, ".."))) {
            result.problem = .bad_name;
            result.problem_at = items.items.len;
        }
        try items.append(allocator, .{ .from = from, .to = to });
    }
    // Two renames onto one path, or a rename onto a selected entry the
    // pattern leaves where it is: the daemon's no-replace rename would
    // refuse the second one halfway through the batch.
    if (result.problem == .none) {
        outer: for (items.items, 0..) |a, i| {
            for (items.items[i + 1 ..]) |b| {
                if (std.mem.eql(u8, a.to, b.to)) {
                    result.problem = .duplicate_target;
                    result.problem_at = i;
                    break :outer;
                }
            }
            for (paths) |p| {
                if (!std.mem.eql(u8, p, a.to)) continue;
                // Renamed away by the batch itself: not a collision.
                var moves = false;
                for (items.items) |o| {
                    if (std.mem.eql(u8, o.from, p)) moves = true;
                }
                if (!moves) {
                    result.problem = .duplicate_target;
                    result.problem_at = i;
                    break :outer;
                }
            }
        }
    }
    result.items = try items.toOwnedSlice(allocator);
    return result;
}

/// One-line preview for the dialog: how many change, the first change
/// spelled out, and what refuses the plan.
pub fn describe(p: *const Plan, buf: []u8) []const u8 {
    const total = p.items.len + p.unchanged;
    return switch (p.problem) {
        .empty_find => std.fmt.bufPrint(buf, "type the text to find", .{}) catch "",
        .bad_replacement => std.fmt.bufPrint(buf, "a name cannot contain \"/\"", .{}) catch "",
        .duplicate_target => std.fmt.bufPrint(buf, "two entries would be named {s}", .{
            std.fs.path.basename(p.items[p.problem_at].to),
        }) catch "",
        .bad_name => std.fmt.bufPrint(buf, "{s} would get an empty or reserved name", .{
            std.fs.path.basename(p.items[p.problem_at].from),
        }) catch "",
        .none => if (p.items.len == 0)
            std.fmt.bufPrint(buf, "no selected name contains that text ({d} selected)", .{total}) catch ""
        else
            std.fmt.bufPrint(buf, "{d} of {d} will be renamed: {s} \u{2192} {s}{s}", .{
                p.items.len,
                total,
                std.fs.path.basename(p.items[0].from),
                std.fs.path.basename(p.items[0].to),
                if (p.items.len > 1) ", \u{2026}" else "",
            }) catch "",
    };
}

/// Undo encoding: the landed pairs as two NUL-separated lists (a path
/// can hold any byte but NUL). `current` = where each entry is now,
/// `original` = where it was, both in execution order.
pub fn encodePairs(allocator: std.mem.Allocator, pairs: []const [2][]const u8) !struct { current: []u8, original: []u8 } {
    var cur: std.ArrayList(u8) = .empty;
    errdefer cur.deinit(allocator);
    var orig: std.ArrayList(u8) = .empty;
    errdefer orig.deinit(allocator);
    for (pairs, 0..) |pair, i| {
        if (i > 0) {
            try cur.append(allocator, 0);
            try orig.append(allocator, 0);
        }
        try cur.appendSlice(allocator, pair[1]);
        try orig.appendSlice(allocator, pair[0]);
    }
    return .{ .current = try cur.toOwnedSlice(allocator), .original = try orig.toOwnedSlice(allocator) };
}

/// Iterate an encoded list (see `encodePairs`).
pub fn iterate(list: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, list, 0);
}

pub fn count(list: []const u8) usize {
    if (list.len == 0) return 0;
    return std.mem.count(u8, list, "\x00") + 1;
}

/// The n-th element of an encoded list.
pub fn nth(list: []const u8, n: usize) ?[]const u8 {
    var it = iterate(list);
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (i == n) return p;
    }
    return null;
}

const t = std.testing;

test "plan renames every occurrence, deepest first, and counts the rest" {
    const a = t.allocator;
    const paths = [_][]const u8{ "/d/aa-x", "/d/aa-x/aa-y", "/d/zz" };
    var p = try plan(a, &paths, "aa", "b");
    defer p.deinit(a);
    try t.expect(p.ok());
    try t.expectEqual(@as(usize, 2), p.items.len);
    try t.expectEqual(@as(usize, 1), p.unchanged);
    // The child runs before its parent moves.
    try t.expectEqualStrings("/d/aa-x/aa-y", p.items[0].from);
    try t.expectEqualStrings("/d/aa-x/b-y", p.items[0].to);
    try t.expectEqualStrings("/d/b-x", p.items[1].to);
    var buf: [256]u8 = undefined;
    try t.expect(std.mem.startsWith(u8, describe(&p, &buf), "2 of 3 will be renamed"));
}

test "plan refuses collisions, slashes and empty names before anything is sent" {
    const a = t.allocator;
    {
        const paths = [_][]const u8{ "/d/a1", "/d/b1" };
        var p = try plan(a, &paths, "a", "b");
        defer p.deinit(a);
        // a1 -> b1 lands on a selected entry that stays put.
        try t.expectEqual(Problem.duplicate_target, p.problem);
    }
    {
        const paths = [_][]const u8{ "/d/xa", "/d/ya" };
        var p = try plan(a, &paths, "x", "y");
        defer p.deinit(a);
        try t.expectEqual(Problem.duplicate_target, p.problem);
    }
    {
        // A swap-free chain: b1 moves away, so a1 -> b1 is fine.
        const paths = [_][]const u8{ "/d/a1", "/d/a2" };
        var p = try plan(a, &paths, "a", "c");
        defer p.deinit(a);
        try t.expect(p.ok());
    }
    {
        const paths = [_][]const u8{"/d/abc"};
        var p = try plan(a, &paths, "b", "/");
        defer p.deinit(a);
        try t.expectEqual(Problem.bad_replacement, p.problem);
        try t.expect(!p.ok());
    }
    {
        const paths = [_][]const u8{"/d/abc"};
        var p = try plan(a, &paths, "abc", "");
        defer p.deinit(a);
        try t.expectEqual(Problem.bad_name, p.problem);
    }
    {
        const paths = [_][]const u8{"/d/abc"};
        var p = try plan(a, &paths, "", "x");
        defer p.deinit(a);
        try t.expectEqual(Problem.empty_find, p.problem);
        try t.expectEqual(@as(usize, 1), p.unchanged);
    }
}

test "undo pairs round-trip through the NUL-separated encoding" {
    const a = t.allocator;
    const pairs = [_][2][]const u8{ .{ "/d/a", "/d/b" }, .{ "/d/c d", "/d/e" } };
    const enc = try encodePairs(a, &pairs);
    defer a.free(enc.current);
    defer a.free(enc.original);
    try t.expectEqual(@as(usize, 2), count(enc.current));
    try t.expectEqualStrings("/d/b", nth(enc.current, 0).?);
    try t.expectEqualStrings("/d/c d", nth(enc.original, 1).?);
    try t.expectEqual(@as(?[]const u8, null), nth(enc.original, 2));
    try t.expectEqual(@as(usize, 0), count(""));
}

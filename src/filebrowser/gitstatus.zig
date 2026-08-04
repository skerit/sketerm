//! Version-control overlay state for the file browser: porcelain
//! record parsing, directory rollup, the display decision and the
//! per-root refresh cache.
//!
//! GTK-free on purpose — the UI side (`src/ui/browser/gitstat.zig`)
//! only ships records in and reads badges out, so every rule here is
//! unit-testable from both test roots.

const std = @import("std");

/// One entry's version-control state, ordered by PRECEDENCE: a higher
/// tag wins when several records fold onto the same path (a directory
/// rollup, or an index record plus a worktree record).
pub const State = enum(u8) {
    none = 0,
    ignored,
    untracked,
    added,
    typechange,
    modified,
    renamed,
    deleted,
    conflicted,

    pub fn rank(self: State) u8 {
        return @intFromEnum(self);
    }
};

/// Map one porcelain status character to a state.
///
/// `C` (copied) is reported as `added`: for a listing the copy is a
/// new file and the source is untouched.
pub fn fromChar(ch: u8) State {
    return switch (ch) {
        '?' => .untracked,
        '!' => .ignored,
        'A', 'C' => .added,
        'T' => .typechange,
        'M' => .modified,
        'R' => .renamed,
        'D' => .deleted,
        'U' => .conflicted,
        else => .none,
    };
}

pub fn merge(a: State, b: State) State {
    return if (b.rank() > a.rank()) b else a;
}

/// What a child state contributes to its ANCESTOR directories.
///
/// Ignored content never propagates: a directory full of build output
/// would otherwise wear a permanent badge, which is the opposite of
/// what an ignore rule asked for.
pub fn propagates(self: State) State {
    return if (self == .ignored) .none else self;
}

/// How one row is drawn. `letter` is the porcelain character (or `*`
/// for "something inside changed"); `css` is a libadwaita status class
/// so both themes stay readable without hardcoded colours; `dim_name`
/// fades the whole name instead of adding a chip.
pub const Badge = struct {
    letter: u8,
    /// NUL-terminated so the UI can hand it straight to GTK.
    css: [:0]const u8,
    dim_name: bool = false,
};

/// The chip for a state, or null when the row must stay unmarked.
///
/// `rollup` = the state came from something BELOW this row, never
/// from a record naming it: those get one neutral `*` so a directory
/// cannot be mistaken for a changed file.
pub fn badgeFor(state: State, rollup: bool) ?Badge {
    if (state == .none) return null;
    if (state == .ignored) {
        // Ignored is information, not an alarm: no chip at all, just
        // a faded name. Nothing propagates it, so a rollup cannot be
        // ignored in the first place.
        return if (rollup) null else Badge{ .letter = 0, .css = "dim-label", .dim_name = true };
    }
    const css: [:0]const u8 = switch (state) {
        .untracked, .added => "success",
        .modified, .typechange => "warning",
        .renamed => "accent",
        .deleted, .conflicted => "error",
        else => "dim-label",
    };
    const letter: u8 = if (rollup) '*' else switch (state) {
        .untracked => '?',
        .added => 'A',
        .typechange => 'T',
        .modified => 'M',
        .renamed => 'R',
        .deleted => 'D',
        .conflicted => 'U',
        else => ' ',
    };
    return .{ .letter = letter, .css = css };
}

/// Human word for a state, for tooltips and the status summary.
pub fn label(state: State) []const u8 {
    return switch (state) {
        .none => "unchanged",
        .ignored => "ignored",
        .untracked => "untracked",
        .added => "added",
        .typechange => "type changed",
        .modified => "modified",
        .renamed => "renamed",
        .deleted => "deleted",
        .conflicted => "conflicted",
    };
}

/// Folded state of one path in the overlay.
pub const Row = struct {
    state: State = .none,
    /// A record named this exact path (as opposed to something under
    /// it): decides letter-vs-rollup rendering.
    exact: bool = false,
};

/// Hard ceiling on folded entries. The daemon caps its record stream
/// at 4096; times a path depth this is the memory the overlay can
/// ever hold, and a pathological tree stops growing it rather than
/// the browser growing without bound.
pub const MAX_ENTRIES: usize = 20000;

/// Every changed path under one browsed directory, folded so that a
/// row lookup is one hash probe.
///
/// Keys are relative to the BROWSED directory (the daemon already
/// stripped the repo prefix). Each record also folds into every
/// ancestor segment, which is what makes a directory row show that
/// something inside it changed without a second job.
pub const Overlay = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Row) = .empty,
    /// Per-state counts of EXACT records only — rollup entries would
    /// count the same change once per directory level.
    counts: [std.enums.values(State).len]u32 = @splat(0),
    /// The fold hit MAX_ENTRIES and stopped storing.
    truncated: bool = false,

    pub fn init(allocator: std.mem.Allocator) Overlay {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Overlay) void {
        self.clear();
        self.map.deinit(self.allocator);
    }

    pub fn clear(self: *Overlay) void {
        var it = self.map.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.map.clearRetainingCapacity();
        self.counts = @splat(0);
        self.truncated = false;
    }

    pub fn isEmpty(self: *const Overlay) bool {
        return self.map.count() == 0;
    }

    /// Total number of records that named a path (not rollups).
    pub fn changedCount(self: *const Overlay) u32 {
        var n: u32 = 0;
        // Ignored files are not "changes"; counting them would make a
        // clean tree with a build dir look dirty.
        for (self.counts[@intFromEnum(State.untracked)..]) |v| n += v;
        return n;
    }

    /// Fold one porcelain record. `path` is relative to the browsed
    /// directory; a trailing slash (git's collapsed untracked/ignored
    /// directory form) is tolerated.
    pub fn apply(self: *Overlay, path: []const u8, ch: u8) void {
        const st = fromChar(ch);
        if (st == .none) return;
        const rel = std.mem.trim(u8, path, "/");
        if (rel.len == 0) return;
        self.put(rel, st, true);
        const up = propagates(st);
        if (up == .none) return;
        // Every ancestor segment carries the rollup.
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, rel, i, '/')) |slash| {
            self.put(rel[0..slash], up, false);
            i = slash + 1;
        }
    }

    fn put(self: *Overlay, key: []const u8, st: State, exact: bool) void {
        if (exact) self.counts[@intFromEnum(st)] +|= 1;
        if (self.map.getPtr(key)) |row| {
            row.state = merge(row.state, st);
            if (exact) row.exact = true;
            return;
        }
        if (self.map.count() >= MAX_ENTRIES) {
            self.truncated = true;
            return;
        }
        const owned = self.allocator.dupe(u8, key) catch {
            self.truncated = true;
            return;
        };
        self.map.put(self.allocator, owned, .{ .state = st, .exact = exact }) catch {
            self.allocator.free(owned);
            self.truncated = true;
        };
    }

    pub fn get(self: *const Overlay, rel: []const u8) ?Row {
        return self.map.get(rel);
    }

    /// The chip for a row, given its path relative to the browsed dir.
    pub fn badge(self: *const Overlay, rel: []const u8) ?Badge {
        const row = self.map.get(rel) orelse return null;
        return badgeFor(row.state, !row.exact);
    }

    /// A short ", 3 modified, 1 untracked" phrase for the status line,
    /// or an empty slice when there is nothing to say.
    ///
    /// This is deliberately everything the daemon's `git_status` verb
    /// gives us: it reports records, not a branch, so no branch name
    /// is invented here.
    pub fn summary(self: *const Overlay, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        var wrote = false;
        // Loudest first: a conflict is what the user must see.
        const order = [_]State{ .conflicted, .deleted, .renamed, .modified, .typechange, .added, .untracked };
        for (order) |st| {
            const n = self.counts[@intFromEnum(st)];
            if (n == 0) continue;
            w.print(", {d} {s}", .{ n, label(st) }) catch break;
            wrote = true;
        }
        if (!wrote) return buf[0..0];
        if (self.truncated) w.writeAll(", partial") catch {};
        return w.buffered();
    }
};

/// Remembers which (host, root) pairs were asked recently, so that
/// walking back and forth between two folders does not respawn a
/// `git status` per step.
///
/// Deliberately tiny and time-bounded: the entry says only "asked at
/// T", never what the answer was, so a stale hit costs at most
/// `ttl_ms` of staleness and an explicit refresh always bypasses it.
pub const Cache = struct {
    pub const CAPACITY = 16;

    const Slot = struct {
        host: []u8 = &.{},
        path: []u8 = &.{},
        at_ms: i64 = 0,
        used: bool = false,
    };

    allocator: std.mem.Allocator,
    ttl_ms: i64 = 30_000,
    slots: [CAPACITY]Slot = @splat(.{}),
    /// Round-robin eviction cursor.
    next: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cache) void {
        self.clear();
    }

    pub fn clear(self: *Cache) void {
        for (&self.slots) |*s| self.release(s);
    }

    fn release(self: *Cache, s: *Slot) void {
        if (s.host.len > 0) self.allocator.free(s.host);
        if (s.path.len > 0) self.allocator.free(s.path);
        s.* = .{};
    }

    fn find(self: *Cache, host: []const u8, path: []const u8) ?*Slot {
        for (&self.slots) |*s| {
            if (!s.used) continue;
            if (std.mem.eql(u8, s.host, host) and std.mem.eql(u8, s.path, path)) return s;
        }
        return null;
    }

    /// True when this root was asked recently enough to skip.
    pub fn fresh(self: *Cache, host: []const u8, path: []const u8, now_ms: i64) bool {
        const s = self.find(host, path) orelse return false;
        if (now_ms -% s.at_ms > self.ttl_ms) {
            self.release(s);
            return false;
        }
        return true;
    }

    pub fn note(self: *Cache, host: []const u8, path: []const u8, now_ms: i64) void {
        if (self.find(host, path)) |s| {
            s.at_ms = now_ms;
            return;
        }
        const slot = &self.slots[self.next];
        self.next = (self.next + 1) % CAPACITY;
        self.release(slot);
        slot.host = self.allocator.dupe(u8, host) catch return;
        slot.path = self.allocator.dupe(u8, path) catch {
            self.allocator.free(slot.host);
            slot.* = .{};
            return;
        };
        slot.at_ms = now_ms;
        slot.used = true;
    }

    pub fn invalidate(self: *Cache, host: []const u8, path: []const u8) void {
        if (self.find(host, path)) |s| self.release(s);
    }
};

/// The overlay key for an entry: its path relative to the browsed
/// root, or null when the row lives outside that root (a miller
/// ancestor column) and the overlay says nothing about it.
pub fn relativeKey(root: []const u8, dir_path: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    if (std.mem.eql(u8, root, dir_path)) {
        if (name.len > buf.len) return null;
        @memcpy(buf[0..name.len], name);
        return buf[0..name.len];
    }
    const base = if (root.len == 1 and root[0] == '/') root.len - 1 else root.len;
    if (dir_path.len <= base + 1) return null;
    if (!std.mem.startsWith(u8, dir_path, root[0..base])) return null;
    if (dir_path[base] != '/') return null;
    const under = dir_path[base + 1 ..];
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ under, name }) catch null;
}

// ── tests ────────────────────────────────────────────────────────

test "porcelain characters map to states" {
    try std.testing.expectEqual(State.modified, fromChar('M'));
    try std.testing.expectEqual(State.untracked, fromChar('?'));
    try std.testing.expectEqual(State.ignored, fromChar('!'));
    try std.testing.expectEqual(State.deleted, fromChar('D'));
    try std.testing.expectEqual(State.renamed, fromChar('R'));
    try std.testing.expectEqual(State.conflicted, fromChar('U'));
    try std.testing.expectEqual(State.added, fromChar('A'));
    try std.testing.expectEqual(State.added, fromChar('C'));
    try std.testing.expectEqual(State.none, fromChar(' '));
    try std.testing.expectEqual(State.none, fromChar('x'));
}

test "precedence: a real change outranks untracked, which outranks ignored" {
    try std.testing.expectEqual(State.modified, merge(.untracked, .modified));
    try std.testing.expectEqual(State.modified, merge(.modified, .untracked));
    try std.testing.expectEqual(State.untracked, merge(.ignored, .untracked));
    try std.testing.expectEqual(State.conflicted, merge(.deleted, .conflicted));
    try std.testing.expectEqual(State.ignored, merge(.none, .ignored));
}

test "ignored never propagates to a parent directory" {
    try std.testing.expectEqual(State.none, propagates(.ignored));
    try std.testing.expectEqual(State.untracked, propagates(.untracked));
    try std.testing.expectEqual(State.modified, propagates(.modified));
}

test "badges: letters for exact records, a neutral star for rollups" {
    try std.testing.expectEqual(@as(?Badge, null), badgeFor(.none, false));
    const m = badgeFor(.modified, false).?;
    try std.testing.expectEqual(@as(u8, 'M'), m.letter);
    try std.testing.expectEqualStrings("warning", m.css);
    try std.testing.expect(!m.dim_name);

    const roll = badgeFor(.modified, true).?;
    try std.testing.expectEqual(@as(u8, '*'), roll.letter);
    try std.testing.expectEqualStrings("warning", roll.css);

    // Ignored is a faded name, never a chip, and never a rollup.
    const ig = badgeFor(.ignored, false).?;
    try std.testing.expect(ig.dim_name);
    try std.testing.expectEqual(@as(u8, 0), ig.letter);
    try std.testing.expectEqual(@as(?Badge, null), badgeFor(.ignored, true));

    try std.testing.expectEqualStrings("error", badgeFor(.conflicted, false).?.css);
    try std.testing.expectEqualStrings("success", badgeFor(.untracked, false).?.css);
    try std.testing.expectEqualStrings("accent", badgeFor(.renamed, false).?.css);
}

test "overlay folds records into ancestor rollups" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("src/ui/main.zig", 'M');
    ov.apply("README.md", '?');

    const exact = ov.get("src/ui/main.zig").?;
    try std.testing.expectEqual(State.modified, exact.state);
    try std.testing.expect(exact.exact);

    const mid = ov.get("src/ui").?;
    try std.testing.expectEqual(State.modified, mid.state);
    try std.testing.expect(!mid.exact);

    const top = ov.get("src").?;
    try std.testing.expectEqual(State.modified, top.state);
    try std.testing.expect(!top.exact);

    try std.testing.expectEqual(@as(u8, '*'), ov.badge("src").?.letter);
    try std.testing.expectEqual(@as(u8, 'M'), ov.badge("src/ui/main.zig").?.letter);
    try std.testing.expectEqual(@as(u8, '?'), ov.badge("README.md").?.letter);
    try std.testing.expectEqual(@as(?Badge, null), ov.badge("nothing"));
}

test "overlay rollup keeps the strongest state and ignores ignored children" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("a/x", '?');
    ov.apply("a/y", 'M');
    ov.apply("b/build.o", '!');
    ov.apply("c/z", 'U');
    ov.apply("c/w", 'M');

    try std.testing.expectEqual(State.modified, ov.get("a").?.state);
    // The ignored child left no mark on its directory.
    try std.testing.expectEqual(@as(?Row, null), ov.get("b"));
    try std.testing.expectEqual(State.ignored, ov.get("b/build.o").?.state);
    try std.testing.expectEqual(State.conflicted, ov.get("c").?.state);
}

test "overlay tolerates git's collapsed directory form" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("newdir/", '?');
    try std.testing.expectEqual(State.untracked, ov.get("newdir").?.state);
    try std.testing.expect(ov.get("newdir").?.exact);
}

test "summary counts exact records only, ignored excluded" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("src/a.zig", 'M');
    ov.apply("src/b.zig", 'M');
    ov.apply("new.txt", '?');
    ov.apply("target/x.o", '!');
    ov.apply("gone.txt", 'D');

    try std.testing.expectEqual(@as(u32, 4), ov.changedCount());
    var buf: [160]u8 = undefined;
    try std.testing.expectEqualStrings(", 1 deleted, 2 modified, 1 untracked", ov.summary(&buf));

    var empty = Overlay.init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expectEqualStrings("", empty.summary(&buf));

    var only_ignored = Overlay.init(std.testing.allocator);
    defer only_ignored.deinit();
    only_ignored.apply("build/x", '!');
    try std.testing.expectEqual(@as(u32, 0), only_ignored.changedCount());
    try std.testing.expectEqualStrings("", only_ignored.summary(&buf));
}

test "overlay clear frees keys and resets counts" {
    var ov = Overlay.init(std.testing.allocator);
    defer ov.deinit();
    ov.apply("a/b/c", 'M');
    try std.testing.expect(!ov.isEmpty());
    ov.clear();
    try std.testing.expect(ov.isEmpty());
    try std.testing.expectEqual(@as(u32, 0), ov.changedCount());
}

test "refresh cache is per host+path and expires" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    try std.testing.expect(!cache.fresh("", "/repo", 1000));
    cache.note("", "/repo", 1000);
    try std.testing.expect(cache.fresh("", "/repo", 1000));
    try std.testing.expect(cache.fresh("", "/repo", 30_000));
    // Same path on another host is a different repository.
    try std.testing.expect(!cache.fresh("box", "/repo", 1000));
    // Past the TTL it is gone.
    try std.testing.expect(!cache.fresh("", "/repo", 40_000));
    cache.note("", "/repo", 40_000);
    try std.testing.expect(cache.fresh("", "/repo", 40_000));
    cache.invalidate("", "/repo");
    try std.testing.expect(!cache.fresh("", "/repo", 40_000));
}

test "refresh cache evicts without leaking" {
    var cache = Cache.init(std.testing.allocator);
    defer cache.deinit();
    var i: usize = 0;
    while (i < Cache.CAPACITY * 3) : (i += 1) {
        var buf: [32]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "/repo/{d}", .{i});
        cache.note("", p, 1);
    }
    // The most recent one survived; the oldest did not.
    try std.testing.expect(cache.fresh("", "/repo/47", 1));
    try std.testing.expect(!cache.fresh("", "/repo/0", 1));
}

test "relativeKey resolves rows in the root and in expanded subdirs" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("a.txt", relativeKey("/repo", "/repo", "a.txt", &buf).?);
    try std.testing.expectEqualStrings("src/a.txt", relativeKey("/repo", "/repo/src", "a.txt", &buf).?);
    try std.testing.expectEqualStrings("x/y/a.txt", relativeKey("/repo", "/repo/x/y", "a.txt", &buf).?);
    // Root "/" is not doubled.
    try std.testing.expectEqualStrings("etc/hosts", relativeKey("/", "/etc", "hosts", &buf).?);
    try std.testing.expectEqualStrings("hosts", relativeKey("/", "/", "hosts", &buf).?);
    // Outside the root: no answer rather than a wrong one.
    try std.testing.expectEqual(@as(?[]const u8, null), relativeKey("/repo", "/other", "a.txt", &buf));
    try std.testing.expectEqual(@as(?[]const u8, null), relativeKey("/repo/src", "/repo", "a.txt", &buf));
}

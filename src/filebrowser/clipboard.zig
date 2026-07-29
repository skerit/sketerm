//! The file-manager clipboard: ONE store for every browser pane in
//! the process.
//!
//! It used to live on `BrowserView`, which made it PER PANE: a copy in
//! one pane left the other pane's clipboard empty, so Ctrl+V did
//! nothing there and the context menu hid Paste entirely (that menu
//! item is gated on the clipboard being non-empty). The asymmetry read
//! as "remote folders cannot be pasted into", but the host never
//! mattered -- only which pane held the copy.
//!
//! A cut/copy therefore names a `host` (null = local) and the paths on
//! it; where the paste lands is the destination tab's business, and
//! `ops.pasteOne` already routes same-host and cross-host through the
//! daemon identically.

const std = @import("std");

pub const Board = struct {
    allocator: std.mem.Allocator,
    /// Host the sources live on; null = the local daemon.
    host: ?[]u8 = null,
    paths: std.ArrayList([]u8) = .empty,
    /// Paste MOVES and then clears the board.
    cut: bool = false,
    /// Filesystem the sources live on (0 = unknown). Decides whether a
    /// hard link into a given directory could work at all, without a
    /// round trip per menu.
    dev: u64 = 0,

    pub fn deinit(self: *Board) void {
        self.clear();
        self.paths.deinit(self.allocator);
    }

    pub fn clear(self: *Board) void {
        if (self.host) |h| self.allocator.free(h);
        self.host = null;
        for (self.paths.items) |p| self.allocator.free(p);
        self.paths.clearRetainingCapacity();
        self.cut = false;
        self.dev = 0;
    }

    /// Replace the contents. Partial allocation failures drop the
    /// individual path rather than the whole copy.
    pub fn set(self: *Board, host: ?[]const u8, srcs: []const []const u8, cut: bool, dev: u64) void {
        self.clear();
        self.cut = cut;
        self.dev = dev;
        if (host) |h| self.host = self.allocator.dupe(u8, h) catch null;
        for (srcs) |sp| {
            const owned = self.allocator.dupe(u8, sp) catch continue;
            self.paths.append(self.allocator, owned) catch self.allocator.free(owned);
        }
    }

    pub fn items(self: *const Board) []const []u8 {
        return self.paths.items;
    }

    pub fn isEmpty(self: *const Board) bool {
        return self.paths.items.len == 0;
    }

    /// The first source: the single-source verbs (Sync Here, Compare,
    /// paste-as-link) act on it.
    pub fn first(self: *const Board) ?[]const u8 {
        if (self.paths.items.len == 0) return null;
        return self.paths.items[0];
    }

    /// The host as an optional slice, the shape `paths.hostEq` wants.
    pub fn hostOpt(self: *const Board) ?[]const u8 {
        return if (self.host) |h| @as(?[]const u8, h) else null;
    }
};

var g_board: ?Board = null;

/// The process-wide board. Every browser face resolves it through
/// here, so there is exactly one clipboard however many panes, tabs
/// or windows exist.
pub fn shared(allocator: std.mem.Allocator) *Board {
    if (g_board == null) g_board = .{ .allocator = allocator };
    return &g_board.?;
}

/// Release the singleton (process teardown / test isolation).
pub fn resetShared() void {
    if (g_board) |*b| b.deinit();
    g_board = null;
}

test "board holds a multi-path remote copy and clears on demand" {
    const t = std.testing;
    var b = Board{ .allocator = t.allocator };
    defer b.deinit();

    try t.expect(b.isEmpty());
    try t.expect(b.first() == null);

    b.set("user@box", &.{ "/a/one", "/a/two" }, false, 66);
    try t.expect(!b.isEmpty());
    try t.expectEqualStrings("user@box", b.host.?);
    try t.expectEqualStrings("/a/one", b.first().?);
    try t.expectEqual(@as(usize, 2), b.items().len);
    try t.expectEqual(@as(u64, 66), b.dev);
    try t.expect(!b.cut);

    // A second copy replaces, never appends.
    b.set(null, &.{"/local/only"}, true, 0);
    try t.expectEqual(@as(usize, 1), b.items().len);
    try t.expect(b.host == null);
    try t.expect(b.hostOpt() == null);
    try t.expect(b.cut);

    b.clear();
    try t.expect(b.isEmpty());
    try t.expect(!b.cut);
}

test "shared() is one board for every caller" {
    const t = std.testing;
    defer resetShared();
    const a = shared(t.allocator);
    a.set("dalaran", &.{"/home/x/f.mkv"}, false, 1);
    // A different pane asking for the clipboard sees the same copy --
    // this is exactly what per-view state got wrong.
    const b = shared(t.allocator);
    try t.expectEqual(@intFromPtr(a), @intFromPtr(b));
    try t.expectEqualStrings("/home/x/f.mkv", b.first().?);
    try t.expectEqualStrings("dalaran", b.host.?);
}

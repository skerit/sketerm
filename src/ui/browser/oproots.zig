//! Normalize a tree selection before filesystem operations. A selected real
//! directory already carries every selected descendant with it; submitting
//! those descendants separately makes the parent operation invalidate the
//! queued child paths.

const std = @import("std");
const types = @import("types.zig");
const BTab = types.BTab;
const Entry = types.Entry;
const entryForPath = @import("nav.zig").entryForPath;

/// Selected paths, keyed without a trailing slash so a key always matches the
/// parent slices `coveredBySelection` derives from a child path.
const PathSet = std.StringHashMapUnmanaged(void);

/// `/foo/` and `/foo` name the same directory; `/` keeps its slash.
fn canon(path: []const u8) []const u8 {
    if (path.len > 1 and path[path.len - 1] == '/') return canon(path[0 .. path.len - 1]);
    return path;
}

/// A selected REAL directory carries every row beneath it. `tdir` also covers
/// symlinks to directories, but moving that symlink does not carry rows browsed
/// through its target, so only a real dir covers.
fn coversDescendants(tab: *BTab, path: []const u8) bool {
    const entry = entryForPath(tab, path) orelse return false;
    return std.mem.eql(u8, entry.kind, "dir");
}

/// Walk `path`'s ancestors upward and stop at the first one that is both
/// selected and a real directory. O(depth), not O(selection).
fn coveredBySelection(tab: *BTab, set: *const PathSet, path: []const u8) bool {
    var rest = canon(path);
    while (std.mem.lastIndexOfScalar(u8, rest, '/')) |cut| {
        const parent = if (cut == 0) rest[0..1] else rest[0..cut];
        if (set.contains(parent) and coversDescendants(tab, parent)) return true;
        if (cut == 0) return false;
        rest = rest[0..cut];
    }
    return false;
}

/// Borrowed path slices in selection order; the returned slice itself is owned.
pub fn collect(allocator: std.mem.Allocator, tab: *BTab, selected: []const []u8) ![][]u8 {
    var set: PathSet = .empty;
    defer set.deinit(allocator);
    try set.ensureTotalCapacity(allocator, @intCast(selected.len));
    for (selected) |path| set.putAssumeCapacity(canon(path), {});

    var out: std.ArrayList([]u8) = .empty;
    errdefer out.deinit(allocator);
    for (selected) |path| {
        if (!coveredBySelection(tab, &set, path)) try out.append(allocator, path);
    }
    return out.toOwnedSlice(allocator);
}

/// Indices into `paths`, deepest first.
///
/// The companion rule to `collect`, for the verbs where BOTH a parent
/// and its descendant must happen rather than one carrying the other:
/// batch rename must rename the child too, so the answer is order, not
/// omission. A descendant's path is strictly longer than its ancestor's,
/// so a stable sort on length descending puts every child ahead of the
/// operation that would invalidate its path.
pub fn deepestFirst(allocator: std.mem.Allocator, paths: []const []u8) ![]usize {
    const order = try allocator.alloc(usize, paths.len);
    errdefer allocator.free(order);
    for (order, 0..) |*slot, i| slot.* = i;
    const Ctx = struct {
        paths: []const []u8,
        fn deeper(self: @This(), a: usize, b: usize) bool {
            return self.paths[a].len > self.paths[b].len;
        }
    };
    std.mem.sort(usize, order, Ctx{ .paths = paths }, Ctx.deeper);
    return order;
}

// -- tests ----------------------------------------------------------

const TestTree = struct {
    a: std.mem.Allocator,
    root: types.Dir,
    sub: types.Dir,
    tab: BTab,

    /// `/srv` holding `folder` (real dir), `folder2` (real dir), `link`
    /// (symlink to a directory) and `loose.txt`; `/srv/folder` expanded with
    /// `child.txt` and a real `sub` directory.
    fn init(a: std.mem.Allocator) !*TestTree {
        const self = try a.create(TestTree);
        self.* = .{
            .a = a,
            .root = .{ .allocator = a, .path = @constCast("/srv"), .view_id = 1 },
            .sub = .{ .allocator = a, .path = @constCast("/srv/folder"), .view_id = 2 },
            .tab = .{
                .view = undefined,
                .hc = undefined,
                .root = undefined,
                .page = undefined,
                .listing_box = undefined,
                .colview = undefined,
                .tab_label = undefined,
            },
        };
        self.tab.root = &self.root;
        try self.root.entries.append(a, try types.testEntryKind(a, "folder", "dir", null, true));
        try self.root.entries.append(a, try types.testEntryKind(a, "folder2", "dir", null, true));
        try self.root.entries.append(a, try types.testEntryKind(a, "link", "link", "/elsewhere", true));
        try self.root.entries.append(a, try types.testEntryKind(a, "loose.txt", "file", null, false));
        try self.sub.entries.append(a, try types.testEntryKind(a, "child.txt", "file", null, false));
        try self.sub.entries.append(a, try types.testEntryKind(a, "sub", "dir", null, true));
        try self.tab.subdirs.append(a, &self.sub);
        return self;
    }

    fn deinit(self: *TestTree) void {
        for ([_]*types.Dir{ &self.root, &self.sub }) |d| {
            for (d.entries.items) |*e| e.deinit(self.a);
            d.entries.deinit(self.a);
        }
        self.tab.subdirs.deinit(self.a);
        self.tab.ancestors.deinit(self.a);
        self.a.destroy(self);
    }

    fn roots(self: *TestTree, selected: []const []u8) ![][]u8 {
        return collect(self.a, &self.tab, selected);
    }
};

test "a selected real directory subsumes its selected descendants" {
    const t = std.testing;
    const tree = try TestTree.init(t.allocator);
    defer tree.deinit();

    const selected = [_][]u8{
        @constCast("/srv/folder"),
        @constCast("/srv/folder/child.txt"),
        @constCast("/srv/folder2"),
        @constCast("/srv/loose.txt"),
    };
    const roots = try tree.roots(&selected);
    defer t.allocator.free(roots);
    // folder2 is NOT a descendant of folder: the boundary is a path
    // component, not a byte prefix.
    try t.expectEqual(@as(usize, 3), roots.len);
    try t.expectEqualStrings("/srv/folder", roots[0]);
    try t.expectEqualStrings("/srv/folder2", roots[1]);
    try t.expectEqualStrings("/srv/loose.txt", roots[2]);
}

test "operation roots are independent of selection order and of depth" {
    const t = std.testing;
    const tree = try TestTree.init(t.allocator);
    defer tree.deinit();

    const selected = [_][]u8{
        @constCast("/srv/folder/child.txt"),
        @constCast("/srv/folder/sub/deep/grandchild.txt"),
        @constCast("/srv/folder"),
        @constCast("/srv/folder/sub"),
    };
    const roots = try tree.roots(&selected);
    defer t.allocator.free(roots);
    try t.expectEqual(@as(usize, 1), roots.len);
    try t.expectEqualStrings("/srv/folder", roots[0]);
}

test "a symlinked directory never subsumes rows browsed through it" {
    const t = std.testing;
    const tree = try TestTree.init(t.allocator);
    defer tree.deinit();

    // `link` is tdir=true but kind="link": moving the link leaves the
    // target's children where they are, so they are their own roots.
    const selected = [_][]u8{
        @constCast("/srv/link"),
        @constCast("/srv/link/child.txt"),
    };
    const roots = try tree.roots(&selected);
    defer t.allocator.free(roots);
    try t.expectEqual(@as(usize, 2), roots.len);
    try t.expectEqualStrings("/srv/link", roots[0]);
    try t.expectEqualStrings("/srv/link/child.txt", roots[1]);
}

test "a path the tab cannot resolve is passed through untouched" {
    const t = std.testing;
    const tree = try TestTree.init(t.allocator);
    defer tree.deinit();

    // `/srv/ghost` is selected but listed nowhere, so it cannot be proven
    // to be a real directory and must not swallow anything.
    const selected = [_][]u8{
        @constCast("/srv/ghost"),
        @constCast("/srv/ghost/child.txt"),
    };
    const roots = try tree.roots(&selected);
    defer t.allocator.free(roots);
    try t.expectEqual(@as(usize, 2), roots.len);
}

test "a trailing slash names the same directory" {
    const t = std.testing;
    const tree = try TestTree.init(t.allocator);
    defer tree.deinit();

    const selected = [_][]u8{
        @constCast("/srv/folder/"),
        @constCast("/srv/folder/child.txt"),
    };
    const roots = try tree.roots(&selected);
    defer t.allocator.free(roots);
    try t.expectEqual(@as(usize, 1), roots.len);
    try t.expectEqualStrings("/srv/folder/", roots[0]);
}

/// `descendantOf`, spelled out locally so the ordering test proves the
/// invariant rather than reusing the code under test.
fn isBeneath(path: []const u8, dir: []const u8) bool {
    if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir)) return false;
    return (dir.len == 1 and dir[0] == '/') or path[dir.len] == '/';
}

test "deepest-first puts every path ahead of its own ancestors" {
    const t = std.testing;
    const paths = [_][]u8{
        @constCast("/srv/dir"),
        @constCast("/srv/dir/sub/leaf.txt"),
        @constCast("/srv/a.txt"),
        @constCast("/srv/dir/sub"),
    };
    const order = try deepestFirst(t.allocator, &paths);
    defer t.allocator.free(order);
    try t.expectEqual(@as(usize, 4), order.len);
    for (order, 0..) |idx, pos| {
        for (order[pos + 1 ..]) |later| {
            // Nothing scheduled later may be beneath something already
            // renamed: that is exactly the path the earlier op invalidates.
            try t.expect(!isBeneath(paths[later], paths[idx]));
        }
    }
}

test "a selection with no directories keeps every row" {
    const t = std.testing;
    const tree = try TestTree.init(t.allocator);
    defer tree.deinit();

    const selected = [_][]u8{
        @constCast("/srv/loose.txt"),
        @constCast("/srv/folder/child.txt"),
    };
    const roots = try tree.roots(&selected);
    defer t.allocator.free(roots);
    try t.expectEqual(@as(usize, 2), roots.len);
}

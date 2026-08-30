//! Normalize a tree selection before filesystem operations. A selected real
//! directory already carries every selected descendant with it; submitting
//! those descendants separately makes the parent operation invalidate the
//! queued child paths.

const std = @import("std");
const BTab = @import("types.zig").BTab;

fn entryForPath(tab: *BTab, path: []const u8) ?*@import("types.zig").Entry {
    if (tab.root.findPath(path)) |entry| return entry;
    for (tab.subdirs.items) |dir| if (dir.findPath(path)) |entry| return entry;
    for (tab.ancestors.items) |dir| if (dir.findPath(path)) |entry| return entry;
    return null;
}

fn descendantOf(path: []const u8, dir: []const u8) bool {
    if (path.len <= dir.len or !std.mem.startsWith(u8, path, dir)) return false;
    return (dir.len == 1 and dir[0] == '/') or path[dir.len] == '/';
}

fn collapse(
    allocator: std.mem.Allocator,
    selected: []const []u8,
    real_dirs: []const []u8,
) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer out.deinit(allocator);
    for (selected) |path| {
        const covered = for (real_dirs) |dir| {
            if (descendantOf(path, dir)) break true;
        } else false;
        if (!covered) try out.append(allocator, path);
    }
    return out.toOwnedSlice(allocator);
}

/// Borrowed path slices in selection order; the returned slice itself is owned.
pub fn collect(allocator: std.mem.Allocator, tab: *BTab, selected: []const []u8) ![][]u8 {
    var dirs: std.ArrayList([]u8) = .empty;
    defer dirs.deinit(allocator);
    for (selected) |path| {
        const entry = entryForPath(tab, path) orelse continue;
        // `tdir` also covers symlinks to directories. Moving that symlink does
        // not carry rows browsed through its target, so only a real dir covers.
        if (std.mem.eql(u8, entry.kind, "dir")) try dirs.append(allocator, path);
    }
    return collapse(allocator, selected, dirs.items);
}

test "operation roots drop descendants of selected real directories" {
    const t = std.testing;
    const selected = [_][]u8{
        @constCast("/srv/folder"),
        @constCast("/srv/folder/child.txt"),
        @constCast("/srv/folder2"),
        @constCast("/srv/link/child.txt"),
        @constCast("/srv/loose.txt"),
    };
    const roots = try collapse(t.allocator, &selected, &.{@constCast("/srv/folder")});
    defer t.allocator.free(roots);
    try t.expectEqual(@as(usize, 4), roots.len);
    try t.expectEqualStrings("/srv/folder", roots[0]);
    try t.expectEqualStrings("/srv/folder2", roots[1]);
    try t.expectEqualStrings("/srv/link/child.txt", roots[2]);
    try t.expectEqualStrings("/srv/loose.txt", roots[3]);
}

test "operation roots are independent of selection order" {
    const t = std.testing;
    const selected = [_][]u8{
        @constCast("/srv/folder/child.txt"),
        @constCast("/srv/folder"),
        @constCast("/srv/folder/sub/grandchild.txt"),
    };
    const roots = try collapse(t.allocator, &selected, &.{@constCast("/srv/folder")});
    defer t.allocator.free(roots);
    try t.expectEqual(@as(usize, 1), roots.len);
    try t.expectEqualStrings("/srv/folder", roots[0]);
}

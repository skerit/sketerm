//! GTK-free persisted state of an editor pane face (layout.zig's
//! `PaneSpec.editor`). Dirty buffers are deliberately NOT persisted:
//! a restore reopens the files from disk, so unsaved changes do not
//! survive a quit — matching how the layout treats shell contents.

const std = @import("std");

pub const FileState = struct {
    /// Host-qualified location spec ("/path" or "host:/path").
    spec: []const u8 = "",
    /// Primary caret byte offset at save time (clamped on restore).
    cursor: u64 = 0,
    /// First VISIBLE line at save time. A line, not the editor's
    /// (line, wrapped row, px) anchor: the wrapped row depends on the
    /// window width and the soft-wrap flag, so it is meaningless in a
    /// file that is reopened in a different pane.
    top_line: u64 = 0,
    /// Host-qualified root of the project the document belonged to
    /// (`editor/project.zig`), or "" for a loose file.
    ///
    /// The association is RE-DERIVED from the path on restore, which is
    /// the authoritative answer; this is what the face shows until that
    /// round trip lands, so a restored window does not flash "no
    /// project" at every tab.
    project: []const u8 = "",
};

pub const PaneState = struct {
    files: []const FileState = &.{},
    /// Index into `files` of the active tab.
    active: u64 = 0,
};

test "editor PaneState round-trips through JSON" {
    const a = std.testing.allocator;
    const files = [_]FileState{
        .{ .spec = "/tmp/a.txt", .cursor = 42, .top_line = 7, .project = "/tmp" },
        .{ .spec = "box:/etc/hosts", .cursor = 0 },
    };
    const state = PaneState{ .files = &files, .active = 1 };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(state, .{}, &aw.writer);
    const parsed = try std.json.parseFromSlice(PaneState, a, aw.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u64, 1), parsed.value.active);
    try std.testing.expectEqualStrings("/tmp/a.txt", parsed.value.files[0].spec);
    try std.testing.expectEqual(@as(u64, 42), parsed.value.files[0].cursor);
    try std.testing.expectEqual(@as(u64, 7), parsed.value.files[0].top_line);
    try std.testing.expectEqualStrings("/tmp", parsed.value.files[0].project);
    // Absent fields keep their defaults, so an OLD layout file restores.
    try std.testing.expectEqual(@as(u64, 0), parsed.value.files[1].top_line);
    try std.testing.expectEqualStrings("", parsed.value.files[1].project);
}

test "editor PaneState accepts a layout written before the session fields" {
    const a = std.testing.allocator;
    const old = "{\"files\":[{\"spec\":\"/x.txt\",\"cursor\":3}],\"active\":0}";
    const parsed = try std.json.parseFromSlice(PaneState, a, old, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("/x.txt", parsed.value.files[0].spec);
    try std.testing.expectEqual(@as(u64, 0), parsed.value.files[0].top_line);
}

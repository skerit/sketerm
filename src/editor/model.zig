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
};

pub const PaneState = struct {
    files: []const FileState = &.{},
    /// Index into `files` of the active tab.
    active: u64 = 0,
};

test "editor PaneState round-trips through JSON" {
    const a = std.testing.allocator;
    const files = [_]FileState{
        .{ .spec = "/tmp/a.txt", .cursor = 42 },
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
}

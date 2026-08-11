//! GTK-free persisted state of a web pane face (layout.zig's
//! `PaneSpec.web`). Scroll position is absent on purpose: the helper
//! protocol reports no scroll offset, and inventing a frame for it is
//! not this module's call.

const std = @import("std");

pub const PaneState = struct {
    /// Address shown at save time, "" for a blank tab (the face then
    /// restores with an empty, focused address bar).
    url: []const u8 = "",
    /// Page zoom as a CEF zoom LEVEL x100 (log scale, 0 = unzoomed,
    /// one Ctrl+= step = 100), matching WebFace.zoom_x100 — NOT a
    /// percentage. Range the face enforces is -700..800.
    zoom_level_x100: i16 = 0,
};

test "web PaneState round-trips through JSON" {
    const a = std.testing.allocator;
    const state = PaneState{ .url = "https://example.com/x", .zoom_level_x100 = 200 };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(state, .{}, &aw.writer);
    const parsed = try std.json.parseFromSlice(PaneState, a, aw.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://example.com/x", parsed.value.url);
    try std.testing.expectEqual(@as(i16, 200), parsed.value.zoom_level_x100);
}

test "web PaneState defaults fill in for a layout written without them" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(PaneState, a, "{}", .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", parsed.value.url);
    try std.testing.expectEqual(@as(i16, 0), parsed.value.zoom_level_x100);
}

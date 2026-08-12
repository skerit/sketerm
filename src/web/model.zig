//! GTK-free persisted state of a web pane face (layout.zig's
//! `PaneSpec.web`). Scroll position is absent on purpose: the helper
//! protocol reports no scroll offset, and inventing a frame for it is
//! not this module's call.

const std = @import("std");

/// One page of a browser pane. A pane holds several (src/ui/webgroup.zig).
pub const PageState = struct {
    /// Address shown at save time, "" for a blank tab (the page then
    /// restores with an empty, focused address bar).
    url: []const u8 = "",
    /// Page zoom as a CEF zoom LEVEL x100 (log scale, 0 = unzoomed,
    /// one Ctrl+= step = 100), matching WebFace.zoom_x100 — NOT a
    /// percentage. Range the face enforces is -700..800.
    zoom_level_x100: i16 = 0,
    /// Index of this page's parent in the same array (tree-style
    /// nesting), or -1 for a root page.
    parent: i32 = -1,
    /// Identity container this page lives in, 0 = the shared default.
    ///
    /// The id is meaningful ACROSS runs only because the daemon store
    /// persists it (`mux/webstore.zig`); the engine derives the jar
    /// path from it, so a layout naming container 7 lands back in the
    /// same cookie jar. A container the store no longer has resolves to
    /// nothing and the page restores in the default jar — the safe
    /// direction, since the alternative is a stranger's identity.
    container: u32 = 0,
};

pub const PaneState = struct {
    /// The ACTIVE page's address, duplicated out of `pages`. Kept as a
    /// top-level field so a layout written by this version still opens
    /// on the right page in a build that only knows about one.
    url: []const u8 = "",
    zoom_level_x100: i16 = 0,
    /// Every page, in strip order. Empty in a layout written before a
    /// browser pane could hold more than one — the `url` above is then
    /// the whole story, which is why the restore path falls back to it.
    pages: []const PageState = &.{},
    /// Index into `pages` of the page that was showing.
    active_page: u32 = 0,
    /// The ACTIVE page's container, duplicated out of `pages` for the
    /// same reason `url` is: a build that only knows about one page
    /// still restores that page into the right identity.
    container: u32 = 0,
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
    try std.testing.expectEqual(@as(usize, 0), parsed.value.pages.len);
    try std.testing.expectEqual(@as(u32, 0), parsed.value.active_page);
}

test "web PaneState round-trips a nested page list" {
    const a = std.testing.allocator;
    const pages = [_]PageState{
        .{ .url = "https://a.example/", .zoom_level_x100 = 0, .parent = -1 },
        .{ .url = "https://b.example/", .zoom_level_x100 = 100, .parent = 0 },
    };
    const state = PaneState{
        .url = "https://b.example/",
        .zoom_level_x100 = 100,
        .pages = &pages,
        .active_page = 1,
    };
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    try std.json.Stringify.value(state, .{}, &aw.writer);
    const parsed = try std.json.parseFromSlice(PaneState, a, aw.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.pages.len);
    try std.testing.expectEqualStrings("https://a.example/", parsed.value.pages[0].url);
    try std.testing.expectEqual(@as(i32, -1), parsed.value.pages[0].parent);
    try std.testing.expectEqual(@as(i32, 0), parsed.value.pages[1].parent);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.active_page);
}

// A layout written before pages existed must still restore its one
// page — the fallback the GUI's restore path relies on.
test "web PaneState from an older layout keeps its single url" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(
        PaneState,
        a,
        "{\"url\":\"https://old.example/\",\"zoom_level_x100\":200}",
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.pages.len);
    try std.testing.expectEqualStrings("https://old.example/", parsed.value.url);
    try std.testing.expectEqual(@as(i16, 200), parsed.value.zoom_level_x100);
}

test "a page's container survives a layout round trip" {
    const t = std.testing;
    const pages = [_]PageState{
        .{ .url = "https://work.example/", .parent = -1, .container = 7 },
        .{ .url = "https://shop.example/", .parent = 0, .container = 12 },
    };
    const state: PaneState = .{
        .url = "https://shop.example/",
        .pages = &pages,
        .active_page = 1,
        .container = 12,
    };
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try std.json.Stringify.value(state, .{}, &aw.writer);

    const parsed = try std.json.parseFromSlice(PaneState, t.allocator, aw.writer.buffered(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    // A restored tree may MIX identities: the child must keep its own
    // container rather than inherit the parent's.
    try t.expectEqual(@as(u32, 7), parsed.value.pages[0].container);
    try t.expectEqual(@as(u32, 12), parsed.value.pages[1].container);
    try t.expectEqual(@as(i32, 0), parsed.value.pages[1].parent);
    // The pane-level copy tracks the active page, so a build that only
    // understands one page still restores into the right identity.
    try t.expectEqual(@as(u32, 12), parsed.value.container);
}

test "a layout written before containers restores in the default jar" {
    const t = std.testing;
    const old =
        \\{"url":"https://a.example/","zoom_level_x100":0,
        \\ "pages":[{"url":"https://a.example/","zoom_level_x100":0,"parent":-1}],
        \\ "active_page":0}
    ;
    const parsed = try std.json.parseFromSlice(PaneState, t.allocator, old, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    // 0 is the shared default context — the safe direction. Never a
    // stale id that might now name somebody else's identity.
    try t.expectEqual(@as(u32, 0), parsed.value.container);
    try t.expectEqual(@as(u32, 0), parsed.value.pages[0].container);
}

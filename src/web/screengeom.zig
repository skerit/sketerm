//! What a browser view tells the engine about its screen, window and
//! own position (`get_view_rect`, `get_screen_info`,
//! `get_root_screen_rect`), from the real geometry a client reports in
//! `view_screen` (capability "view-screen"). Pure, so the mapping is
//! unit-tested without CEF; the tests below are the contract.
//!
//! A page reads these as `screen.*` (screen and avail rects),
//! `outerWidth`/`outerHeight` and `screenX`/`screenY` (the root rect),
//! and `MouseEvent.screenX - clientX` (the view rect's origin). Without
//! a report everything is the view itself at the origin, which is what
//! a headless helper has always said.

const std = @import("std");
const proto = @import("protocol.zig");
const ScaleLever = @import("ozone.zig").ScaleLever;

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const Engine = struct {
    view: Rect,
    screen: Rect,
    avail: Rect,
    /// Null: not reported, and the engine falls back to the view rect.
    root: ?Rect,
};

/// The engine's geometry in the space `lever` puts the view rect in:
/// logical under `screen_info`, physical (`scale_x1000`) under `zoom`.
/// `w`/`h` are the view's LOGICAL size.
pub fn engine(lever: ScaleLever, w: u16, h: u16, scale_x1000: u16, report: ?proto.ViewScreen) Engine {
    const s: i64 = if (lever == .zoom) @max(scale_x1000, 1) else 1000;
    const sc = struct {
        fn f(v: i64, k: i64) i32 {
            return @intCast(@divTrunc(v * k, 1000));
        }
    }.f;
    const view_size = Rect{ .w = sc(w, s), .h = sc(h, s) };
    const r = report orelse return .{ .view = view_size, .screen = view_size, .avail = view_size, .root = null };
    var view = view_size;
    view.x = sc(@as(i64, r.window_x) + r.view_x, s);
    view.y = sc(@as(i64, r.window_y) + r.view_y, s);
    return .{
        .view = view,
        .screen = .{ .x = sc(r.screen_x, s), .y = sc(r.screen_y, s), .w = sc(r.screen_w, s), .h = sc(r.screen_h, s) },
        .avail = .{ .x = sc(r.avail_x, s), .y = sc(r.avail_y, s), .w = sc(r.avail_w, s), .h = sc(r.avail_h, s) },
        .root = .{ .x = sc(r.window_x, s), .y = sc(r.window_y, s), .w = sc(r.window_w, s), .h = sc(r.window_h, s) },
    };
}

const report_1080p = proto.ViewScreen{
    .view = 1,
    .screen_w = 1920,
    .screen_h = 1080,
    .avail_w = 1920,
    .avail_h = 1080,
    .window_w = 1280,
    .window_h = 900,
    .view_x = 0,
    .view_y = 46,
};

test "no report: the view is the screen and the window, at the origin" {
    const g = engine(.screen_info, 800, 600, 2000, null);
    try std.testing.expectEqual(Rect{ .w = 800, .h = 600 }, g.view);
    try std.testing.expectEqual(g.view, g.screen);
    try std.testing.expectEqual(g.view, g.avail);
    try std.testing.expect(g.root == null);
    // Under the zoom lever the same view is physical.
    try std.testing.expectEqual(Rect{ .w = 1600, .h = 1200 }, engine(.zoom, 800, 600, 2000, null).view);
}

test "a report puts the view inside its window on the real screen" {
    const g = engine(.screen_info, 1280, 854, 1500, report_1080p);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 46, .w = 1280, .h = 854 }, g.view);
    try std.testing.expectEqual(Rect{ .w = 1920, .h = 1080 }, g.screen);
    try std.testing.expectEqual(Rect{ .w = 1920, .h = 1080 }, g.avail);
    try std.testing.expectEqual(Rect{ .w = 1280, .h = 900 }, g.root.?);
    // outer > inner: the window carries the client's own chrome.
    try std.testing.expect(g.root.?.h > g.view.h);
}

test "a second output's origin moves every rect, the window first" {
    var r = report_1080p;
    r.screen_x = 1920;
    r.avail_x = 1920;
    r.window_x = 1920;
    const g = engine(.screen_info, 1280, 854, 1000, r);
    try std.testing.expectEqual(@as(i32, 1920), g.screen.x);
    try std.testing.expectEqual(@as(i32, 1920), g.root.?.x);
    try std.testing.expectEqual(@as(i32, 1920), g.view.x);
    try std.testing.expectEqual(@as(i32, 46), g.view.y);
}

test "under the zoom lever every rect is physical" {
    const g = engine(.zoom, 1280, 854, 2000, report_1080p);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 92, .w = 2560, .h = 1708 }, g.view);
    try std.testing.expectEqual(Rect{ .w = 3840, .h = 2160 }, g.screen);
    try std.testing.expectEqual(Rect{ .w = 2560, .h = 1800 }, g.root.?);
}

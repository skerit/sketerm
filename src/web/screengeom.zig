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
//! a helper says to a client that never sends one. `headless` is the
//! report the MCP lane synthesizes for a view that has no monitor.

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

pub const Point = struct { x: i32, y: i32 };

/// Where the view point `x`,`y` (the view rect's space) lies on the
/// screen, for `get_screen_point`, which is what a mouse event's
/// `screenX`/`screenY` come from: without it CEF uses the view point
/// itself and the view rect's origin never reaches an event. CEF wants
/// device px on Linux, so the `screen_info` lever scales by the reported
/// device scale (unmeasured: no GPU host here); under `zoom` the space
/// already is physical and the reported scale is 1.
/// @return null without a report, keeping CEF's own answer.
pub fn screenPoint(lever: ScaleLever, scale_x1000: u16, g: Engine, x: i32, y: i32) ?Point {
    if (g.root == null) return null;
    const k: i64 = if (lever == .screen_info) @max(scale_x1000, 1) else 1000;
    return .{
        .x = @intCast(@divTrunc((@as(i64, x) + g.view.x) * k, 1000)),
        .y = @intCast(@divTrunc((@as(i64, y) + g.view.y) * k, 1000)),
    };
}

/// A screen size in logical px, spelled `WIDTHxHEIGHT` (`[mcp] web_screen`).
pub const Size = struct {
    w: u16,
    h: u16,

    /// @return null for anything but two non-zero decimal u16s around one `x`.
    pub fn parse(s: []const u8) ?Size {
        const at = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
        const w = parseDim(s[0..at]) orelse return null;
        const h = parseDim(s[at + 1 ..]) orelse return null;
        return .{ .w = w, .h = h };
    }

    fn parseDim(s: []const u8) ?u16 {
        if (s.len == 0) return null;
        for (s) |ch| if (!std.ascii.isDigit(ch)) return null;
        const v = std.fmt.parseInt(u16, s, 10) catch return null;
        return if (v == 0) null else v;
    }

    pub fn format(self: Size, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}x{d}", .{ self.w, self.h });
    }

    fn holds(self: Size, inner: Size) bool {
        return inner.w <= self.w and inner.h <= self.h;
    }
};

/// The screen a headless view reports when nothing configures one.
pub const headless_screen_default = Size{ .w = 1920, .h = 1080 };

/// Common sizes tried in order when the window does not fit the
/// configured screen; past the last, the screen is the window itself.
const headless_screen_ladder = [_]Size{ .{ .w = 2560, .h = 1440 }, .{ .w = 3840, .h = 2160 } };

/// Headful Chromium 152's window around its viewport on a sketerm
/// display (outer 945x1060 around inner 913x931, src/web/CLAUDE.md).
pub const headless_chrome = Size{ .w = 32, .h = 129 };

/// The viewport's top-left in that window: the reference capture's
/// `input.screen_offset` [26,107] minus its window position 10,10, so
/// the bottom border (32) is not the side border (16).
pub const headless_view_offset = struct {
    pub const x: i32 = 16;
    pub const y: i32 = 97;
};

/// Chrome's own default window placement (WindowSizer), per axis.
pub const headless_window_origin: i32 = 10;

/// The `view_screen` a headless view (no monitor, no window) reports:
/// a window `headless_chrome` larger than the `w`x`h` LOGICAL viewport
/// at `headless_window_origin`, pulled back so it stays on the screen,
/// on `configured` or the next ladder size that holds it; avail is the
/// whole screen at 0,0, as on Wayland.
pub fn headless(view: u32, configured: Size, w: u16, h: u16) proto.ViewScreen {
    const win = Size{ .w = w +| headless_chrome.w, .h = h +| headless_chrome.h };
    const screen = pick: {
        if (configured.holds(win)) break :pick configured;
        for (headless_screen_ladder) |s| if (s.holds(win)) break :pick s;
        break :pick win;
    };
    return .{
        .view = view,
        .screen_w = screen.w,
        .screen_h = screen.h,
        .avail_w = screen.w,
        .avail_h = screen.h,
        .window_x = @min(headless_window_origin, @as(i32, screen.w) - win.w),
        .window_y = @min(headless_window_origin, @as(i32, screen.h) - win.h),
        .window_w = win.w,
        .window_h = win.h,
        .view_x = headless_view_offset.x,
        .view_y = headless_view_offset.y,
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

test "web_screen sizes parse strictly and print back" {
    try std.testing.expectEqual(Size{ .w = 1920, .h = 1080 }, Size.parse("1920x1080").?);
    try std.testing.expectEqual(Size{ .w = 65535, .h = 1 }, Size.parse("65535x1").?);
    for ([_][]const u8{ "", "1920", "1920x", "x1080", "0x1080", "1920x0", "1920X1080", "1920 x 1080", "+1920x1080", "65536x10", "19x20x30", "-1x5" }) |bad|
        try std.testing.expect(Size.parse(bad) == null);
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("2560x1440", try std.fmt.bufPrint(&buf, "{f}", .{Size{ .w = 2560, .h = 1440 }}));
}

test "a headless view sits in Chrome's window at 10,10 on the configured screen" {
    const r = headless(9, headless_screen_default, 1280, 800);
    try std.testing.expect(r.valid());
    try std.testing.expectEqual(@as(u32, 9), r.view);
    try std.testing.expectEqual(@as(u16, 1920), r.screen_w);
    try std.testing.expectEqual(@as(u16, 1080), r.screen_h);
    try std.testing.expectEqual(r.screen_w, r.avail_w);
    try std.testing.expectEqual(r.screen_h, r.avail_h);
    try std.testing.expectEqual(@as(i32, 0), r.screen_x);
    try std.testing.expectEqual(@as(i32, 0), r.avail_y);
    try std.testing.expectEqual(@as(u16, 1312), r.window_w);
    try std.testing.expectEqual(@as(u16, 929), r.window_h);
    try std.testing.expectEqual(@as(i32, 10), r.window_x);
    try std.testing.expectEqual(@as(i32, 10), r.window_y);
    // The page's MouseEvent.screenX - clientX: the reference's [26,107].
    const g = engine(.screen_info, 1280, 800, 1000, r);
    try std.testing.expectEqual(Rect{ .x = 26, .y = 107, .w = 1280, .h = 800 }, g.view);
    try std.testing.expectEqual(@as(i32, 129), g.root.?.h - g.view.h);
}

test "a window too big for the configured screen moves up the ladder, then becomes the screen" {
    // 1900+32 is wider than 1920: the next common size holds it.
    const a = headless(1, headless_screen_default, 1900, 800);
    try std.testing.expectEqual(@as(u16, 2560), a.screen_w);
    try std.testing.expectEqual(@as(u16, 1440), a.screen_h);
    // Too tall for 1440 as well.
    const b = headless(1, headless_screen_default, 1280, 1400);
    try std.testing.expectEqual(@as(u16, 3840), b.screen_w);
    try std.testing.expectEqual(@as(u16, 2160), b.screen_h);
    // Too big for every common size: the screen is the window, at 0,0.
    const big = headless(1, headless_screen_default, 4000, 600);
    try std.testing.expectEqual(@as(u16, 4032), big.screen_w);
    try std.testing.expectEqual(@as(u16, 729), big.screen_h);
    try std.testing.expectEqual(@as(i32, 0), big.window_x);
    try std.testing.expectEqual(@as(i32, 0), big.window_y);
    try std.testing.expect(big.valid());
    // A configured screen that holds the window is kept even when small.
    const small = headless(1, .{ .w = 1366, .h = 768 }, 1024, 600);
    try std.testing.expectEqual(@as(u16, 1366), small.screen_w);
    // The largest viewport the wire carries still yields a valid report.
    try std.testing.expect(headless(1, headless_screen_default, 65535, 65535).valid());
}

test "the window is pulled back toward the origin to stay on the screen" {
    // 1330+32 = 1362 leaves 4 px across a 1366 screen; 600+129 leaves 39.
    const r = headless(1, .{ .w = 1366, .h = 768 }, 1330, 600);
    try std.testing.expectEqual(@as(i32, 4), r.window_x);
    try std.testing.expectEqual(@as(i32, 10), r.window_y);
    // An exact fit sits at the origin.
    const exact = headless(1, .{ .w = 1366, .h = 768 }, 1334, 639);
    try std.testing.expectEqual(@as(i32, 0), exact.window_x);
    try std.testing.expectEqual(@as(i32, 0), exact.window_y);
}

test "a mouse point lands on the screen at the view's origin, in device px" {
    const r = headless(1, headless_screen_default, 1280, 800);
    // No report: CEF keeps the view point.
    try std.testing.expect(screenPoint(.zoom, 1000, engine(.zoom, 1280, 800, 1000, null), 300, 200) == null);
    // The reference's click: MouseEvent.screenX - clientX = 26,107.
    try std.testing.expectEqual(Point{ .x = 326, .y = 307 }, screenPoint(.zoom, 1000, engine(.zoom, 1280, 800, 1000, r), 300, 200).?);
    // Under zoom the view space is already physical (origin scaled by engine()).
    try std.testing.expectEqual(Point{ .x = 652, .y = 614 }, screenPoint(.zoom, 2000, engine(.zoom, 1280, 800, 2000, r), 600, 400).?);
    // Under screen_info the logical point is scaled to device px.
    try std.testing.expectEqual(Point{ .x = 652, .y = 614 }, screenPoint(.screen_info, 2000, engine(.screen_info, 1280, 800, 2000, r), 300, 200).?);
}

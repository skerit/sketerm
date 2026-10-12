//! The REAL geometry a web face reports to its helper (`view_screen`,
//! capability "view-screen"): the monitor the window is on, the
//! toplevel's size and where the view sits inside it, all in logical
//! pixels. Split out of `webface.zig`; free functions taking
//! `*WebFace`, re-exported from `WebFace` by name.
//!
//! Wayland tells a client neither where its window is nor a work area,
//! so the window is placed at its monitor's origin and `avail` is the
//! whole monitor. That is what the client actually knows, not a guess
//! dressed up as one; headful Chromium on the same display reports the
//! output size as both `screen` and `avail` too (measured 2026-10-12,
//! `src/web/CLAUDE.md` "Real geometry for GUI views").

const std = @import("std");
const c = @import("../../c.zig").c;
const proto = @import("../../web/protocol.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;

/// Ship the face's geometry when it changed since the last send on this
/// connection. A helper without the capability gets nothing (it would
/// skip the frame anyway, but an old helper must not have to).
pub fn syncScreen(self: *WebFace) void {
    // An observed view is another client's, geometry included.
    if (!self.view_live or self.observed) return;
    if (!self.cl.has(.view_screen)) return;
    const report = screenReport(self) orelse return;
    if (self.sent_screen) |s| if (std.meta.eql(s, report)) return;
    self.sent_screen = report;
    self.cl.post(report);
}

/// The face's geometry, or null while it has no realized window on a
/// monitor (an unrealized tab has nothing true to say yet).
pub fn screenReport(self: *WebFace) ?proto.ViewScreen {
    if (self.widgets_dead) return null;
    const native = c.gtk_widget_get_native(self.view_area) orelse return null;
    const surface = c.gtk_native_get_surface(native) orelse return null;
    const monitor = c.gdk_display_get_monitor_at_surface(c.gdk_surface_get_display(surface), surface) orelse return null;
    var mon: c.GdkRectangle = undefined;
    c.gdk_monitor_get_geometry(monitor, &mon);
    const win: *c.GtkWidget = @ptrCast(@alignCast(native));
    var origin: c.graphene_point_t = .{ .x = 0, .y = 0 };
    var at: c.graphene_point_t = undefined;
    if (c.gtk_widget_compute_point(self.view_area, win, &origin, &at) == 0) return null;
    return build(self.view, mon.x, mon.y, mon.width, mon.height, c.gtk_widget_get_width(win), c.gtk_widget_get_height(win), at.x, at.y);
}

/// The wire report from GTK's numbers; null for a size the wire cannot
/// carry or a window not yet laid out.
pub fn build(view: u32, mon_x: i32, mon_y: i32, mon_w: i32, mon_h: i32, win_w: i32, win_h: i32, view_x: f32, view_y: f32) ?proto.ViewScreen {
    const max = std.math.maxInt(u16);
    if (mon_w <= 0 or mon_h <= 0 or win_w <= 0 or win_h <= 0) return null;
    if (mon_w > max or mon_h > max or win_w > max or win_h > max) return null;
    const r = proto.ViewScreen{
        .view = view,
        .screen_x = mon_x,
        .screen_y = mon_y,
        .screen_w = @intCast(mon_w),
        .screen_h = @intCast(mon_h),
        .avail_x = mon_x,
        .avail_y = mon_y,
        .avail_w = @intCast(mon_w),
        .avail_h = @intCast(mon_h),
        .window_x = mon_x,
        .window_y = mon_y,
        .window_w = @intCast(win_w),
        .window_h = @intCast(win_h),
        .view_x = @intFromFloat(@round(std.math.clamp(view_x, 0, @as(f32, @floatFromInt(win_w))))),
        .view_y = @intFromFloat(@round(std.math.clamp(view_y, 0, @as(f32, @floatFromInt(win_h))))),
    };
    return if (r.valid()) r else null;
}

test "the report is the monitor, the toplevel and the view inside it" {
    const r = build(7, 1920, 0, 2560, 1440, 1400, 900, 0, 46.4).?;
    try std.testing.expectEqual(@as(i32, 1920), r.screen_x);
    try std.testing.expectEqual(@as(u16, 2560), r.screen_w);
    try std.testing.expectEqual(r.screen_w, r.avail_w);
    try std.testing.expectEqual(@as(i32, 1920), r.window_x);
    try std.testing.expectEqual(@as(u16, 900), r.window_h);
    try std.testing.expectEqual(@as(i32, 46), r.view_y);
    try std.testing.expect(build(7, 0, 0, 0, 1080, 800, 600, 0, 0) == null);
    try std.testing.expect(build(7, 0, 0, 1920, 1080, 0, 600, 0, 0) == null);
}

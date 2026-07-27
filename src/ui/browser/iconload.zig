//! Icon loading that survives a corrupt icon-theme cache.
//!
//! A theme whose `icon-theme.cache` disagrees with the files on disk
//! (shipped stale by the theme's installer) makes GTK pick a file
//! that does not exist and silently render the missing-image icon --
//! `gtk_image_set_from_icon_name` has no failure path. Every themed
//! icon the browser shows goes through here instead: the lookup's
//! chosen file is stat'ed, and when the cache lied, other sizes,
//! scales and the non-symbolic name variant are tried until one
//! resolves to a real file.
//!
//! `anchor` supplies the display/theme; it does not have to be
//! rooted (the validation scale comes from the monitors, see
//! `scaleOf`).

const std = @import("std");
const c = @import("../../c.zig").c;

/// Sizes tried (after the requested one) when the cache lies. Covers
/// the directory sizes real themes ship.
const FALLBACK_SIZES = [_]i32{ 64, 48, 32, 24, 22, 16 };

fn themeOf(widget: *c.GtkWidget) ?*c.GtkIconTheme {
    return c.gtk_icon_theme_get_for_display(c.gtk_widget_get_display(widget));
}

/// The scale the lookup must be validated at. An unrooted widget
/// reports 1, so the display's largest monitor scale wins: GTK will
/// re-look the icon up at the real scale once mapped, and THAT lookup
/// is the one the corrupt cache breaks.
fn scaleOf(widget: *c.GtkWidget) i32 {
    var scale = c.gtk_widget_get_scale_factor(widget);
    const display = c.gtk_widget_get_display(widget);
    if (display != null) {
        const mons = c.gdk_display_get_monitors(display);
        const n = c.g_list_model_get_n_items(mons);
        var i: c_uint = 0;
        while (i < n) : (i += 1) {
            const mon = c.g_list_model_get_item(mons, i) orelse continue;
            defer c.g_object_unref(mon);
            const s = c.gdk_monitor_get_scale_factor(@ptrCast(@alignCast(mon)));
            if (s > scale) scale = s;
        }
    }
    return if (scale < 1) 1 else scale;
}

/// Does the paintable's backing file actually exist? Resource-backed
/// and file-less paintables count as fine -- only a real path that
/// fails access(2) is the cache-lie case.
fn paintableOk(p: *c.GtkIconPaintable) bool {
    const f = c.gtk_icon_paintable_get_file(p) orelse return true;
    defer c.g_object_unref(@as(?*anyopaque, @ptrCast(f)));
    const path = c.g_file_get_path(f) orelse return true;
    defer c.g_free(path);
    return c.access(path, c.F_OK) == 0;
}

fn tryLookup(th: *c.GtkIconTheme, name: [*:0]const u8, px: i32, scale: i32) ?*c.GtkIconPaintable {
    const p = c.gtk_icon_theme_lookup_icon(th, name, null, px, scale, c.GTK_TEXT_DIR_NONE, 0) orelse return null;
    if (paintableOk(p)) return p;
    c.g_object_unref(@as(?*anyopaque, @ptrCast(p)));
    return null;
}

/// A working paintable for `name`, or null when the plain icon-name
/// path is already fine (or nothing at all resolves -- either way the
/// caller should just use the name).
fn fallbackPaintable(th: *c.GtkIconTheme, name: [*:0]const u8, px: i32, scale: i32) ?*c.GtkIconPaintable {
    const first = c.gtk_icon_theme_lookup_icon(th, name, null, px, scale, c.GTK_TEXT_DIR_NONE, 0) orelse return null;
    if (paintableOk(first)) {
        c.g_object_unref(@as(?*anyopaque, @ptrCast(first)));
        return null;
    }
    c.g_object_unref(@as(?*anyopaque, @ptrCast(first)));
    // The cache lied. Try the plain name at other sizes/scales, then
    // the non-symbolic variant (a theme that ships user-bookmarks.svg
    // but whose cache claims the -symbolic one exists).
    var plain_buf: [64:0]u8 = undefined;
    const span = std.mem.span(name);
    var plain: ?[*:0]const u8 = null;
    if (std.mem.endsWith(u8, span, "-symbolic") and span.len - 9 < plain_buf.len) {
        @memcpy(plain_buf[0 .. span.len - 9], span[0 .. span.len - 9]);
        plain_buf[span.len - 9] = 0;
        plain = @ptrCast(&plain_buf);
    }
    const names = [_]?[*:0]const u8{ name, plain };
    for (names, 0..) |cand, ni| {
        const nm = cand orelse continue;
        const scales = [_]i32{ scale, 1 };
        for (scales) |s| {
            for (FALLBACK_SIZES) |sz| {
                if (ni == 0 and sz == px and s == scale) continue; // the failed first try
                if (tryLookup(th, nm, sz, s)) |p| return p;
            }
        }
    }
    return null;
}

/// Like fallbackPaintable but for a GIcon (content-type icons).
fn fallbackPaintableGicon(th: *c.GtkIconTheme, gicon: *c.GIcon, px: i32, scale: i32) ?*c.GtkIconPaintable {
    const first = c.gtk_icon_theme_lookup_by_gicon(th, gicon, px, scale, c.GTK_TEXT_DIR_NONE, 0) orelse return null;
    if (paintableOk(first)) {
        c.g_object_unref(@as(?*anyopaque, @ptrCast(first)));
        return null;
    }
    c.g_object_unref(@as(?*anyopaque, @ptrCast(first)));
    const scales = [_]i32{ scale, 1 };
    for (scales) |s| {
        for (FALLBACK_SIZES) |sz| {
            if (sz == px and s == scale) continue;
            const p = c.gtk_icon_theme_lookup_by_gicon(th, gicon, sz, s, c.GTK_TEXT_DIR_NONE, 0) orelse continue;
            if (paintableOk(p)) return p;
            c.g_object_unref(@as(?*anyopaque, @ptrCast(p)));
        }
    }
    return null;
}

/// Set a named icon on a GtkImage, dodging cache lies.
pub fn setImageIcon(img: *c.GtkWidget, anchor: *c.GtkWidget, name: [*:0]const u8, px: i32) void {
    c.gtk_image_set_pixel_size(@ptrCast(@alignCast(img)), px);
    if (themeOf(anchor)) |th| {
        const scale = scaleOf(anchor);
        if (fallbackPaintable(th, name, px, scale)) |p| {
            c.gtk_image_set_from_paintable(@ptrCast(@alignCast(img)), @ptrCast(p));
            c.g_object_unref(@as(?*anyopaque, @ptrCast(p)));
            return;
        }
    }
    c.gtk_image_set_from_icon_name(@ptrCast(@alignCast(img)), name);
}

/// Set a GIcon on a GtkImage, dodging cache lies.
pub fn setImageGicon(img: *c.GtkWidget, anchor: *c.GtkWidget, gicon: *c.GIcon, px: i32) void {
    c.gtk_image_set_pixel_size(@ptrCast(@alignCast(img)), px);
    if (themeOf(anchor)) |th| {
        const scale = scaleOf(anchor);
        if (fallbackPaintableGicon(th, gicon, px, scale)) |p| {
            c.gtk_image_set_from_paintable(@ptrCast(@alignCast(img)), @ptrCast(p));
            c.g_object_unref(@as(?*anyopaque, @ptrCast(p)));
            return;
        }
    }
    c.gtk_image_set_from_gicon(@ptrCast(@alignCast(img)), gicon);
}

/// A fresh GtkImage showing a named icon, dodging cache lies.
pub fn newImageIcon(anchor: *c.GtkWidget, name: [*:0]const u8, px: i32) *c.GtkWidget {
    const img = c.gtk_image_new().?;
    setImageIcon(img, anchor, name, px);
    return img;
}

/// A fresh GtkImage showing a GIcon, dodging cache lies.
pub fn newImageGicon(anchor: *c.GtkWidget, gicon: *c.GIcon, px: i32) *c.GtkWidget {
    const img = c.gtk_image_new().?;
    setImageGicon(img, anchor, gicon, px);
    return img;
}

//! Shared chrome for remote-application windows — the single
//! free-floating dialog BOTH remote-app renderers present: the
//! Wayland app pipe (`wlapp.zig` AppHost) and the macOS window-stream
//! renderer (`winapp.zig` WsHost). One place builds the undecorated,
//! transparent, taskbar-joined GtkWindow + GtkPicture (inside a
//! GtkOverlay so the Wayland side can host popups), so the two
//! backends produce IDENTICAL windows instead of drifting into
//! separate systems. Each backend then attaches its own input
//! controllers and protocol-specific extras (Wayland:
//! popups/geometry/decorations; winstream: none).
//!
//! Everything here is the chrome that was previously inline in
//! wlapp.zig — moved verbatim so behaviour is unchanged.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;

// Backend-specific identity calls; the headers are too heavy for the
// cimport set, so declare the handful of symbols directly. Referenced
// only on Linux (comptime-gated at the call site below).
extern fn gdk_wayland_toplevel_set_application_id(toplevel: ?*c.GdkSurface, application_id: [*:0]const u8) void;
extern fn gdk_x11_display_get_xdisplay(display: ?*c.GdkDisplay) ?*anyopaque;
extern fn gdk_x11_surface_get_xid(surface: ?*c.GdkSurface) c_ulong;
extern fn XChangeProperty(dpy: ?*anyopaque, win: c_ulong, prop: c_ulong, kind: c_ulong, format: c_int, mode: c_int, data: [*]const u8, n: c_int) c_int;

pub const Widgets = struct {
    window: *c.GtkWindow,
    /// GtkOverlay between window and picture — the Wayland side lands
    /// popups here; the winstream side leaves it empty (harmless).
    overlay: *c.GtkWidget,
    picture: *c.GtkWidget,
};

/// Build the free-floating remote-app window: an undecorated (unless
/// `decorated`) transparent GtkWindow holding a GtkPicture inside a
/// GtkOverlay, joined to the GtkApplication so it shows in the
/// taskbar/switcher, content scaled to fill. The caller owns the
/// widgets, attaches input controllers + signals, and presents it.
pub fn create(title: [:0]const u8, w: i32, h: i32, decorated: bool) ?Widgets {
    const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
    const picture = c.gtk_picture_new() orelse return null;
    c.gtk_window_set_title(window, title);
    ensureTransparentCss();
    c.gtk_widget_add_css_class(@ptrCast(window), "sketerm-remote-app");
    // App-less windows are invisible to some taskbars/switchers.
    if (c.g_application_get_default()) |app| {
        c.gtk_application_add_window(@ptrCast(app), window);
    }
    // Undecorated unless the app asked for host decorations — remote
    // apps draw their own chrome (CSD on Wayland; the macOS title bar
    // is in the captured pixels), and a second titlebar looks broken.
    c.gtk_window_set_decorated(window, @intFromBool(decorated));
    c.gtk_window_set_default_size(window, w, h);
    const overlay = c.gtk_overlay_new() orelse return null;
    c.gtk_overlay_set_child(@ptrCast(overlay), picture);
    c.gtk_window_set_child(window, overlay);
    c.gtk_picture_set_content_fit(@ptrCast(picture), c.GTK_CONTENT_FIT_FILL);
    return .{ .window = window, .overlay = overlay.?, .picture = picture.? };
}

/// CSD apps carry alpha (drop shadows, rounded corners) in their
/// buffers; the host window must not paint a background behind it or
/// shadows composite onto theme gray.
pub fn ensureTransparentCss() void {
    const S = struct {
        var done: bool = false;
    };
    if (S.done) return;
    S.done = true;
    const display = c.gdk_display_get_default() orelse return;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, "window.sketerm-remote-app { background: transparent; }");
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    c.g_object_unref(provider);
}

/// Desktop identity: app ids double as icon names by convention
/// (org.gnome.Calculator etc.), and the window itself gets the remote
/// app's identity so taskbars group/iconify it as that app instead of
/// as sketerm.
pub fn applyAppId(window: *c.GtkWindow, app_id: []const u8) void {
    var buf: [256:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{app_id}) catch return;
    c.gtk_window_set_icon_name(window, z.ptr);
    if (comptime !builtin.os.tag.isDarwin()) {
        const display = c.gdk_display_get_default() orelse return;
        const surface = c.gtk_native_get_surface(@ptrCast(window)) orelse return;
        const backend = std.mem.span(c.g_type_name_from_instance(@ptrCast(@alignCast(display))));
        if (std.mem.indexOf(u8, backend, "Wayland") != null) {
            gdk_wayland_toplevel_set_application_id(surface, z.ptr);
        } else if (std.mem.indexOf(u8, backend, "X11") != null) {
            const xdpy = gdk_x11_display_get_xdisplay(display) orelse return;
            const xid = gdk_x11_surface_get_xid(surface);
            if (xid == 0) return;
            // WM_CLASS (atom 67), XA_STRING (31), PropModeReplace:
            // "instance\0class\0".
            var cls: [520]u8 = undefined;
            const n = @min(z.len, 255);
            @memcpy(cls[0..n], z[0..n]);
            cls[n] = 0;
            @memcpy(cls[n + 1 ..][0..n], z[0..n]);
            cls[n + 1 + n] = 0;
            _ = XChangeProperty(xdpy, xid, 67, 31, 8, 0, &cls, @intCast(2 * n + 2));
        }
    }
}

/// Hand the window's drag to the window manager (undecorated windows
/// have no titlebar to grab). `btn`/`x`/`y` = the originating press.
pub fn beginMove(window: *c.GtkWindow, btn: c_uint, x: f64, y: f64) void {
    const display = c.gdk_display_get_default() orelse return;
    const device = c.gdk_seat_get_pointer(c.gdk_display_get_default_seat(display)) orelse return;
    const gdk_surface = c.gtk_native_get_surface(@ptrCast(window)) orelse return;
    c.gdk_toplevel_begin_move(@ptrCast(gdk_surface), device, @intCast(btn), x, y, 0);
}

/// Interactive resize from a window edge. `edges` is the Wayland edge
/// bitmask (1 top, 2 bottom, 4 left, 8 right); unmapped values no-op.
pub fn beginResize(window: *c.GtkWindow, edges: u32, btn: c_uint, x: f64, y: f64) void {
    const display = c.gdk_display_get_default() orelse return;
    const device = c.gdk_seat_get_pointer(c.gdk_display_get_default_seat(display)) orelse return;
    const gdk_surface = c.gtk_native_get_surface(@ptrCast(window)) orelse return;
    const edge: c.GdkSurfaceEdge = switch (edges) {
        1 => c.GDK_SURFACE_EDGE_NORTH,
        2 => c.GDK_SURFACE_EDGE_SOUTH,
        4 => c.GDK_SURFACE_EDGE_WEST,
        5 => c.GDK_SURFACE_EDGE_NORTH_WEST,
        6 => c.GDK_SURFACE_EDGE_SOUTH_WEST,
        8 => c.GDK_SURFACE_EDGE_EAST,
        9 => c.GDK_SURFACE_EDGE_NORTH_EAST,
        10 => c.GDK_SURFACE_EDGE_SOUTH_EAST,
        else => return,
    };
    c.gdk_toplevel_begin_resize(@ptrCast(gdk_surface), edge, device, @intCast(btn), x, y, 0);
}

/// Width of the host-window edge band that initiates an interactive
/// resize. The window is undecorated and (for Wayland apps) cropped to
/// the app's window geometry, so the app's own CSD resize handles —
/// which live in the shadow margin OUTSIDE that geometry — are gone.
/// The host window's edges ARE the app's real edges, so we resize the
/// host directly and let configure feedback redraw the app.
pub const resize_border: f64 = 8;

/// Which window edge a point sits on, as the Wayland edge bitmask
/// (1 top, 2 bottom, 4 left, 8 right; corners combine). 0 = interior.
/// `w`/`h` are the host content size; `x`/`y` are content-local.
pub fn resizeEdgeAt(w: i32, h: i32, x: f64, y: f64) u32 {
    if (w <= 0 or h <= 0) return 0;
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    var edges: u32 = 0;
    if (y < resize_border) edges |= 1; // top
    if (y >= fh - resize_border) edges |= 2; // bottom
    if (x < resize_border) edges |= 4; // left
    if (x >= fw - resize_border) edges |= 8; // right
    // Top+bottom or left+right at once (tiny window): drop the pair.
    if (edges & 3 == 3) edges &= ~@as(u32, 3);
    if (edges & 12 == 12) edges &= ~@as(u32, 12);
    return edges;
}

/// CSS cursor name for a resize edge bitmask, or null for the
/// interior (caller leaves the cursor to the app).
pub fn edgeCursorName(edges: u32) ?[*:0]const u8 {
    return switch (edges) {
        1 => "n-resize",
        2 => "s-resize",
        4 => "w-resize",
        8 => "e-resize",
        5 => "nw-resize",
        9 => "ne-resize",
        6 => "sw-resize",
        10 => "se-resize",
        else => null,
    };
}

/// BGRA-in-memory pixels → GdkMemoryTexture. `format` follows wl_shm:
/// 0 = argb8888 premultiplied (also what winstream sends), 1 =
/// xrgb8888 (opaque). Caller unrefs the returned texture.
pub fn newTexture(w: i32, h: i32, format: u32, pixels: []const u8) ?*c.GdkTexture {
    const gdk_format: c.GdkMemoryFormat = if (format == 1)
        c.GDK_MEMORY_B8G8R8X8
    else
        c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED;
    const gbytes = c.g_bytes_new(pixels.ptr, pixels.len) orelse return null;
    defer c.g_bytes_unref(gbytes);
    return c.gdk_memory_texture_new(w, h, gdk_format, gbytes, @intCast(w * 4));
}

test "resizeEdgeAt: corners, edges, interior" {
    // 200x100 window, 8px band.
    try std.testing.expectEqual(@as(u32, 0), resizeEdgeAt(200, 100, 100, 50)); // interior
    try std.testing.expectEqual(@as(u32, 4), resizeEdgeAt(200, 100, 2, 50)); // left
    try std.testing.expectEqual(@as(u32, 8), resizeEdgeAt(200, 100, 199, 50)); // right
    try std.testing.expectEqual(@as(u32, 1), resizeEdgeAt(200, 100, 100, 2)); // top
    try std.testing.expectEqual(@as(u32, 2), resizeEdgeAt(200, 100, 100, 99)); // bottom
    try std.testing.expectEqual(@as(u32, 10), resizeEdgeAt(200, 100, 199, 99)); // bottom-right
    try std.testing.expectEqual(@as(u32, 5), resizeEdgeAt(200, 100, 1, 1)); // top-left
    // Degenerate size never reports an edge.
    try std.testing.expectEqual(@as(u32, 0), resizeEdgeAt(0, 0, 0, 0));
}

test "edgeCursorName: maps edges, null interior" {
    try std.testing.expect(edgeCursorName(0) == null);
    try std.testing.expectEqualStrings("se-resize", std.mem.span(edgeCursorName(10).?));
    try std.testing.expectEqualStrings("n-resize", std.mem.span(edgeCursorName(1).?));
}

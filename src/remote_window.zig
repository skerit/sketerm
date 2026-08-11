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
const cssutil = @import("ui/cssutil.zig");

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
///
/// macOS exception: a NON-OPAQUE NSWindow only composites the region
/// its backing was last painted into — when the window grows
/// (maximize / large resize) the never-painted area stays clipped to
/// the original size even though GTK reports the full allocation. So
/// on macOS the window is kept OPAQUE. That's safe because the macOS
/// path already crops the CSD shadow out of the displayed buffer
/// (wlapp `onFrame`), so the rectangular app buffer fully covers the
/// window and the opaque background never shows. (Linux keeps the
/// transparent background so CSD shadows/rounded corners blend.)
pub fn ensureTransparentCss() void {
    const css = if (builtin.os.tag == .macos)
        "window.sketerm-remote-app { background: transparent; }\nwindow.sketerm-remote-app.opaque-resize { background: black; }"
    else
        "window.sketerm-remote-app { background: transparent; }";
    cssutil.install("remote_window", null, css);
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

/// Texture of a sub-rectangle (physical pixels) of a `w`×`h` buffer —
/// used on macOS to crop away the app's CSD shadow margin. The
/// sub-region keeps the full buffer stride, so no row repacking.
pub fn newTextureCropped(w: i32, h: i32, format: u32, pixels: []const u8, cx: i32, cy: i32, cw: i32, ch: i32) ?*c.GdkTexture {
    if (cw <= 0 or ch <= 0 or cx < 0 or cy < 0 or cx + cw > w or cy + ch > h) {
        return newTexture(w, h, format, pixels);
    }
    const gdk_format: c.GdkMemoryFormat = if (format == 1)
        c.GDK_MEMORY_B8G8R8X8
    else
        c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED;
    const stride: usize = @intCast(w * 4);
    const start: usize = @as(usize, @intCast(cy)) * stride + @as(usize, @intCast(cx)) * 4;
    const len: usize = @as(usize, @intCast(ch - 1)) * stride + @as(usize, @intCast(cw)) * 4;
    if (start + len > pixels.len) return newTexture(w, h, format, pixels);
    const gbytes = c.g_bytes_new(pixels.ptr + start, len) orelse return null;
    defer c.g_bytes_unref(gbytes);
    return c.gdk_memory_texture_new(cw, ch, gdk_format, gbytes, @intCast(stride));
}

/// Blit a tight `w`×`h` BGRA `src` into `dst` (a `dst_w`×`dst_h` BGRA
/// backing buffer, stride dst_w*4) at top-left (x,y). Rows/cols outside
/// the backing are CLIPPED — a malformed damage rect from the wire can
/// never write past the buffer. The receiver accumulates damaged rects
/// here, then presents the whole backing as one texture.
pub fn blitRect(dst: []u8, dst_w: i32, dst_h: i32, src: []const u8, x: i32, y: i32, w: i32, h: i32) void {
    const bpp = 4;
    if (dst_w <= 0 or dst_h <= 0 or w <= 0 or h <= 0) return;
    const need_src = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * bpp;
    const need_dst = @as(usize, @intCast(dst_w)) * @as(usize, @intCast(dst_h)) * bpp;
    if (src.len < need_src or dst.len < need_dst) return;

    var row: i32 = 0;
    while (row < h) : (row += 1) {
        const dy = y + row;
        if (dy < 0 or dy >= dst_h) continue;
        const x0 = @max(x, 0);
        const x1 = @min(x + w, dst_w);
        if (x1 <= x0) continue;
        const cols: usize = @intCast(x1 - x0);
        const src_skip: usize = @intCast(x0 - x);
        const so = (@as(usize, @intCast(row)) * @as(usize, @intCast(w)) + src_skip) * bpp;
        const do_ = (@as(usize, @intCast(dy)) * @as(usize, @intCast(dst_w)) + @as(usize, @intCast(x0))) * bpp;
        @memcpy(dst[do_..][0 .. cols * bpp], src[so..][0 .. cols * bpp]);
    }
}

test "blitRect places a rect and clips out-of-bounds" {
    // 4x3 BGRA backing, zeroed.
    var dst = [_]u8{0} ** (4 * 3 * 4);
    // 2x2 src of 0xAB bytes.
    const src = [_]u8{0xAB} ** (2 * 2 * 4);

    blitRect(&dst, 4, 3, &src, 1, 1, 2, 2);
    // (1,1) and (2,1) on row 1, (1,2)/(2,2) on row 2 are set; corners 0.
    const px = struct {
        fn at(d: []const u8, w: usize, cx: usize, cy: usize) u8 {
            return d[(cy * w + cx) * 4];
        }
    };
    try std.testing.expectEqual(@as(u8, 0xAB), px.at(&dst, 4, 1, 1));
    try std.testing.expectEqual(@as(u8, 0xAB), px.at(&dst, 4, 2, 2));
    try std.testing.expectEqual(@as(u8, 0), px.at(&dst, 4, 0, 0));
    try std.testing.expectEqual(@as(u8, 0), px.at(&dst, 4, 3, 0));

    // Clipping: a rect straddling the right/bottom edge writes only the
    // in-bounds part and never overflows `dst`.
    @memset(&dst, 0);
    blitRect(&dst, 4, 3, &src, 3, 2, 2, 2); // only (3,2) lands
    try std.testing.expectEqual(@as(u8, 0xAB), px.at(&dst, 4, 3, 2));

    // Fully out of bounds / degenerate: no-op, no crash.
    @memset(&dst, 0);
    blitRect(&dst, 4, 3, &src, -5, -5, 2, 2);
    blitRect(&dst, 4, 3, &src, 0, 0, 0, 0);
    var sum: u32 = 0;
    for (dst) |b| sum += b;
    try std.testing.expectEqual(@as(u32, 0), sum);
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

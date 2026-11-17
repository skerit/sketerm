//! Rendering a live widget subtree to PNG bytes.
//!
//! Its own module rather than a corner of an existing one because the
//! two consumers span unrelated subsystems -- `terminal_surface.zig`
//! (the GL terminal renderer, also used by the cast-playback viewer)
//! and `webface.zig` (the CEF browser face) -- so neither
//! `webframe.zig` (browser-only by its header) nor the surface itself
//! is a home the other may import.
//!
//! The GtkWidgetPaintable round-trip is what captures GL content
//! exactly as shown: the GSK renderer replays the widget's snapshot
//! into an offscreen texture, so a `GtkGLArea`'s framebuffer and a
//! `GdkTexture` in the scene graph come out the same way.

const c = @import("../c.zig").c;

/// Why a widget could not be captured; each says what a caller should
/// tell its user, so the failure is never reported as another one.
pub const Error = error{
    /// Never allocated: not laid out yet.
    NoSize,
    /// Not mapped: in a tab or stack page that is not showing, so GTK
    /// draws nothing for it.
    NotShown,
    /// Not in a native surface, so there is no GSK renderer.
    NotInWindow,
    /// The widget's snapshot is empty: nothing has been drawn into it.
    NothingPainted,
    RenderFailed,
};

/// PNG bytes (owned `GBytes`, caller unrefs) of `w` as currently
/// painted. Null on any failure; `widgetPng` says which.
pub fn widgetToPng(w: *c.GtkWidget) ?*c.GBytes {
    return widgetPng(w) catch null;
}

/// `widgetToPng` with the reason for a failure.
///
/// Every intermediate here is refcounted and this is the only
/// `gsk_renderer_render_texture` call site in the tree; a dropped
/// unref is a per-screenshot leak.
pub fn widgetPng(w: *c.GtkWidget) Error!*c.GBytes {
    const width = c.gtk_widget_get_width(w);
    const height = c.gtk_widget_get_height(w);
    if (width <= 0 or height <= 0) return error.NoSize;
    const native = c.gtk_widget_get_native(w) orelse return error.NotInWindow;
    const renderer = c.gtk_native_get_renderer(native) orelse return error.NotInWindow;
    if (c.gtk_widget_get_mapped(w) == 0) return error.NotShown;

    const paintable = c.gtk_widget_paintable_new(w) orelse return error.RenderFailed;
    defer c.g_object_unref(paintable);
    const snapshot = c.gtk_snapshot_new();
    c.gdk_paintable_snapshot(
        @ptrCast(paintable),
        @ptrCast(snapshot),
        @floatFromInt(width),
        @floatFromInt(height),
    );
    const node = c.gtk_snapshot_free_to_node(snapshot) orelse return error.NothingPainted;
    defer c.gsk_render_node_unref(node);

    var bounds = c.graphene_rect_t{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = @floatFromInt(width), .height = @floatFromInt(height) },
    };
    const texture = c.gsk_renderer_render_texture(renderer, node, &bounds) orelse return error.RenderFailed;
    defer c.g_object_unref(texture);
    return c.gdk_texture_save_to_png_bytes(texture) orelse error.RenderFailed;
}

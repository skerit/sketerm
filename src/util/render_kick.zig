//! Force the on-demand GtkGLArea panes to produce a fresh frame.
//!
//! Panes run with `auto_render = FALSE` (battery; see pane.zig), so they
//! only repaint when content changes. An in-window AdwDialog overlay
//! (Preferences, "Close window?", …) therefore may not get composited on
//! top of an idle terminal until *something* forces a render — which is
//! why such dialogs appear to hide behind the window until a resize. Call
//! `kick(toplevel)` right after presenting / on closing a dialog to queue a
//! render on every GL area in the window, producing that frame.

const c = @import("../c.zig").c;

/// Queue a render on every GtkGLArea descendant of `root` (inclusive).
pub fn kick(root: ?*c.GtkWidget) void {
    const r = root orelse return;
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(r)), c.gtk_gl_area_get_type()) != 0) {
        c.gtk_gl_area_queue_render(@ptrCast(@alignCast(r)));
    }
    var child = c.gtk_widget_get_first_child(r);
    while (child != null) : (child = c.gtk_widget_get_next_sibling(child)) {
        kick(child);
    }
}

/// AdwDialog "closed" handler: `user` is the toplevel GtkWidget to kick so
/// the dialog's dimming layer clears promptly.
pub fn onDialogClosed(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    kick(@ptrCast(@alignCast(user)));
}

//! Keep in-window AdwDialog overlays visible over the GL panes.
//!
//! Two separate failure modes are handled here:
//!
//! 1. Panes run with `auto_render = FALSE` (battery; see pane.zig), so
//!    they only repaint when content changes. An in-window AdwDialog
//!    overlay (Preferences, "Close window?", ...) therefore may not get
//!    composited on top of an idle terminal until *something* forces a
//!    render. `kick(toplevel)` queues a render on every GL area.
//!
//! 2. Panes are wrapped in GtkGraphicsOffload (forced ENABLED), which
//!    puts their content on a Wayland subsurface. Whether GSK demotes
//!    that subsurface below the main surface when a dialog overlaps it
//!    is a per-frame heuristic that observably fails (dialog rendered
//!    *underneath* the pane until a resize forces re-evaluation). So
//!    while any in-window dialog is open we suspend offload outright —
//!    GSK then composites the pane on the main surface where z-order
//!    is always correct. The 5-8 ms implicit-sync cost that offload
//!    avoids is irrelevant under a modal dialog.
//!
//! Call `dialogPresented(toplevel)` right after presenting a dialog and
//! connect `onDialogClosed` (user data = the toplevel) to its "closed"
//! signal. Presents/closes nest via a per-toplevel counter.

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

fn suspendQuark() c.GQuark {
    return c.g_quark_from_static_string("sketerm-offload-suspended");
}

fn dialogCountQuark() c.GQuark {
    return c.g_quark_from_static_string("sketerm-dialog-count");
}

/// True while `dialogPresented` has parked this GtkGraphicsOffload in
/// DISABLED and intends to re-enable it on dialog close.
pub fn offloadSuspended(offload: *c.GtkWidget) bool {
    return c.g_object_get_qdata(@ptrCast(@alignCast(offload)), suspendQuark()) != null;
}

/// Drop the re-enable-on-close mark (config turned offload off for good).
pub fn clearOffloadSuspended(offload: *c.GtkWidget) void {
    c.g_object_set_qdata(@ptrCast(@alignCast(offload)), suspendQuark(), null);
}

/// Whether an ancestor toplevel currently has an in-window dialog open.
pub fn dialogActive(widget: *c.GtkWidget) bool {
    var current: ?*c.GtkWidget = widget;
    while (current) |w| : (current = c.gtk_widget_get_parent(w)) {
        if (dialogCount(w) > 0) return true;
    }
    return false;
}

/// Remember a desired enable while keeping the offload disabled.
pub fn deferOffloadEnable(offload: *c.GtkWidget) void {
    c.gtk_graphics_offload_set_enabled(@ptrCast(offload), c.GTK_GRAPHICS_OFFLOAD_DISABLED);
    c.g_object_set_qdata(@ptrCast(@alignCast(offload)), suspendQuark(), @ptrFromInt(1));
}

fn dialogCount(root: *c.GtkWidget) usize {
    return @intFromPtr(c.g_object_get_qdata(@ptrCast(@alignCast(root)), dialogCountQuark()));
}

fn setDialogCount(root: *c.GtkWidget, count: usize) void {
    c.g_object_set_qdata(@ptrCast(@alignCast(root)), dialogCountQuark(), @ptrFromInt(count));
}

/// Walk `root`, moving every currently-ENABLED GtkGraphicsOffload to
/// DISABLED and marking it for restore.
fn suspendOffloads(root: *c.GtkWidget) void {
    if (c.g_type_check_instance_is_a(@ptrCast(@alignCast(root)), c.gtk_graphics_offload_get_type()) != 0) {
        const o: *c.GtkGraphicsOffload = @ptrCast(@alignCast(root));
        if (c.gtk_graphics_offload_get_enabled(o) == c.GTK_GRAPHICS_OFFLOAD_ENABLED) {
            c.gtk_graphics_offload_set_enabled(o, c.GTK_GRAPHICS_OFFLOAD_DISABLED);
            c.g_object_set_qdata(@ptrCast(@alignCast(root)), suspendQuark(), @ptrFromInt(1));
        }
    }
    var child = c.gtk_widget_get_first_child(root);
    while (child != null) : (child = c.gtk_widget_get_next_sibling(child)) {
        suspendOffloads(child);
    }
}

/// Walk `root`, re-enabling every GtkGraphicsOffload that
/// `suspendOffloads` parked.
fn resumeOffloads(root: *c.GtkWidget) void {
    if (offloadSuspended(root)) {
        clearOffloadSuspended(root);
        c.gtk_graphics_offload_set_enabled(
            @ptrCast(@alignCast(root)),
            c.GTK_GRAPHICS_OFFLOAD_ENABLED,
        );
    }
    var child = c.gtk_widget_get_first_child(root);
    while (child != null) : (child = c.gtk_widget_get_next_sibling(child)) {
        resumeOffloads(child);
    }
}

/// An in-window dialog was just presented on `root`: suspend graphics
/// offload (first dialog only) and force a frame.
pub fn dialogPresented(root: ?*c.GtkWidget) void {
    const r = root orelse return;
    const count = dialogCount(r);
    setDialogCount(r, count + 1);
    if (count == 0) suspendOffloads(r);
    kick(r);
}

/// AdwDialog "closed" handler: `user` is the toplevel GtkWidget. Restores
/// offload once the last dialog is gone and kicks a frame so the dimming
/// layer clears promptly.
pub fn onDialogClosed(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const r: *c.GtkWidget = @ptrCast(@alignCast(user orelse return));
    const count = dialogCount(r);
    if (count <= 1) {
        setDialogCount(r, 0);
        resumeOffloads(r);
    } else {
        setDialogCount(r, count - 1);
    }
    kick(r);
}

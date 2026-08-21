//! Mechanics every pane FACE repeats: resolving the `Window` that
//! hosts the face's widget subtree, and resyncing a tab model list
//! after a TabHost drag-reorder.
//!
//! `tabhost.zig` owns the tab STRIP (widgets, gestures, per-tab menu);
//! this module owns the two things a face does around it that are not
//! the strip's business. Kept separate from `webframe.zig`, which is
//! browser-frame presentation and imports CEF protocol types the
//! editor and file browser have no reason to see.

const std = @import("std");
const c = @import("../c.zig").c;

/// The `Window` whose widget tree hosts `w`, or null when the widget
/// is not (yet, or no longer) in a rooted tree.
///
/// A face's own liveness guard (`widgets_dead`) stays at the call
/// site: whether a dead face may still answer with its Window is a
/// per-face policy, not a property of this lookup.
pub fn windowOf(w: ?*c.GtkWidget) ?*@import("window.zig").Window {
    const widget = w orelse return null;
    const root = c.gtk_widget_get_root(widget) orelse return null;
    return @import("remotectl.zig").windowFromGtk(@ptrCast(@alignCast(root)));
}

/// Move `page`'s entry inside a face's tab list to `new_index`, the
/// model half of a TabHost drag-reorder.
///
/// Every face persists its tabs in list order while treating the
/// notebook index as authoritative for the active tab, so a model
/// that does not follow the drag restores the session in the wrong
/// order. `T` is the face's tab pointer; it only has to expose
/// `page`.
pub fn reorderTabs(
    comptime T: type,
    allocator: std.mem.Allocator,
    tabs: *std.ArrayList(T),
    page: *c.GtkWidget,
    new_index: usize,
) void {
    for (tabs.items, 0..) |t, i| {
        if (t.page != page) continue;
        const moved = tabs.orderedRemove(i);
        // Capacity survives the remove, so the insert cannot fail;
        // the fallback append only exists to satisfy the API.
        tabs.insert(allocator, @min(new_index, tabs.items.len), moved) catch {
            tabs.append(allocator, moved) catch {};
        };
        return;
    }
}

/// The vertical, fully expanding box a face uses as its root widget.
pub fn newRootBox() *c.GtkWidget {
    // GtkBox is a plain g_object_new; it has no failure mode.
    const vbox: *c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(vbox, 1);
    c.gtk_widget_set_vexpand(vbox, 1);
    return vbox;
}

//! Widget pieces of the transient manager-window shape that the
//! userscript, userstyle, container and filter-list managers share: a
//! scrolled list over a footer, rows padded alike.

const c = @import("../c.zig").c;

/// `listbox` in a vertically scrolling, vexpanding scroller, its rows unselectable.
pub fn scrolledList(listbox: *c.GtkWidget) *c.GtkWidget {
    const scroller: *c.GtkWidget = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroller, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_list_box_set_selection_mode(@ptrCast(listbox), c.GTK_SELECTION_NONE);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), listbox);
    return scroller;
}

/// A horizontal box (8px spacing) inset 10px at both ends and by `top`/`bottom` vertically.
pub fn paddedRow(top: c_int, bottom: c_int) *c.GtkWidget {
    const row: *c.GtkWidget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_margin_start(row, 10);
    c.gtk_widget_set_margin_end(row, 10);
    c.gtk_widget_set_margin_top(row, top);
    c.gtk_widget_set_margin_bottom(row, bottom);
    return row;
}

//! Small widget builders shared by more than one window.

const c = @import("../c.zig").c;

/// Flat icon+label action row appended to `box` (hamburger-popover
/// rows). The caller connects "clicked" itself.
pub fn actionButton(box: *c.GtkWidget, label: [*:0]const u8, icon: [*:0]const u8) *c.GtkWidget {
    const button = c.gtk_button_new().?;
    c.gtk_button_set_has_frame(@ptrCast(button), 0);
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8).?;
    c.gtk_box_append(@ptrCast(row), c.gtk_image_new_from_icon_name(icon).?);
    const text = c.gtk_label_new(label).?;
    c.gtk_label_set_xalign(@ptrCast(text), 0);
    c.gtk_widget_set_hexpand(text, 1);
    c.gtk_box_append(@ptrCast(row), text);
    c.gtk_button_set_child(@ptrCast(button), row);
    c.gtk_box_append(@ptrCast(box), button);
    return button;
}

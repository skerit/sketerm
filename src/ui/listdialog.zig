//! The shared shape of the modal list pickers: an AdwDialog holding a
//! 12px-margin column with an optional search entry, an optional header
//! label, and a `boxed-list` GtkListBox in a vertically expanding
//! scroller. The command palette, the saved-panel picker and the
//! cross-session search had each hand-built it; they differ only in
//! title, size, placeholder and what extra chrome they append.
//!
//! Lifetime: `build` deliberately connects NOTHING. A picker's context
//! is owned by the "closed" handler's GDestroyNotify (CLAUDE.md
//! mechanism 1) and that decision stays with the caller, which knows
//! what its context owns and in what order its handlers must run. A
//! builder that connected "closed" itself would be a second owner of
//! one allocation.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Spec = struct {
    title: [*:0]const u8,
    /// AdwDialog content size; the dialog is not resizable by the user.
    width: c_int,
    height: c_int,
    /// Search entry above the list; null for a picker with no filter.
    search_placeholder: ?[*:0]const u8 = null,
    /// Dim caption between the search entry and the list.
    header: ?[*:0]const u8 = null,
};

/// The widgets a caller has to keep hold of. `root` is the column the
/// list sits in, exposed so a picker can append its own chrome (a
/// status row, a button bar) BELOW the list.
pub const ListDialog = struct {
    dialog: *c.AdwDialog,
    root: *c.GtkWidget,
    search: ?*c.GtkWidget,
    listbox: *c.GtkWidget,
};

/// Build the dialog and its column; the caller connects its handlers,
/// fills the list and presents.
pub fn build(spec: Spec) ListDialog {
    // AdwDialog: handles modality, Escape, centring on the parent.
    const dialog = c.adw_dialog_new();
    c.adw_dialog_set_title(dialog, spec.title);
    c.adw_dialog_set_content_width(dialog, spec.width);
    c.adw_dialog_set_content_height(dialog, spec.height);

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_margin_start(root, 12);
    c.gtk_widget_set_margin_end(root, 12);
    c.gtk_widget_set_margin_top(root, 12);
    c.gtk_widget_set_margin_bottom(root, 12);

    var search: ?*c.GtkWidget = null;
    if (spec.search_placeholder) |placeholder| {
        const entry = c.gtk_search_entry_new();
        c.gtk_widget_set_hexpand(entry, 1);
        c.gtk_search_entry_set_placeholder_text(@ptrCast(@alignCast(entry)), placeholder);
        c.gtk_widget_set_margin_bottom(entry, 8);
        c.gtk_box_append(@ptrCast(root), entry);
        search = entry;
    }

    if (spec.header) |text| {
        const label = c.gtk_label_new(text);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_widget_add_css_class(label, "dim-label");
        c.gtk_widget_set_margin_bottom(label, 8);
        c.gtk_box_append(@ptrCast(root), label);
    }

    const scrolled = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scrolled, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(@alignCast(scrolled)), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);

    const listbox = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(@alignCast(listbox)), c.GTK_SELECTION_BROWSE);
    c.gtk_widget_add_css_class(listbox, "boxed-list");
    c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(scrolled)), listbox);
    c.gtk_box_append(@ptrCast(root), scrolled);

    return .{
        .dialog = @ptrCast(@alignCast(dialog)),
        .root = root.?,
        .search = search,
        .listbox = listbox.?,
    };
}

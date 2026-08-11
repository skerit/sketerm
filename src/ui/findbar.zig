//! Shared find-bar CHROME: the search entry, the optional match-count
//! label and the Aa / word / regex toggle trio that the editor's find
//! bar and the project search panel both build, plus the flat icon
//! button their prev/next/close controls share. Chrome only — no
//! search engine, no state: every signal lands in the consumer's own
//! callconv(.c) handler with the ctx it hands us, and the consumer
//! keeps ownership of the row box so it can put its own widgets
//! (titles, Search buttons) wherever it wants around these.

const c = @import("../c.zig").c;

/// Consumer handlers, all optional. `on_changed` is the immediate
/// GtkEditable "changed" (NOT the debounced "search-changed") so a
/// consumer that recomputes per keystroke keeps doing so;
/// `on_stop` is GtkSearchEntry's "stop-search" (Esc inside the
/// entry), a backstop for consumers whose capture-phase Esc handler
/// is the primary close path.
pub const Callbacks = struct {
    ctx: *anyopaque,
    // GCallback is itself optional in the bindings; null = unwired.
    on_changed: c.GCallback = null,
    on_activate: c.GCallback = null,
    on_stop: c.GCallback = null,
    /// One handler for all three option toggles ("toggled").
    on_toggle_changed: c.GCallback = null,
};

pub const Spec = struct {
    placeholder: [*:0]const u8,
    /// > 0 fixes the entry width; 0 leaves the entry natural.
    width_chars: c_int = 0,
    hexpand: bool = false,
    /// > 0 adds the dim match-count label after the entry.
    count_width_chars: c_int = 0,
    /// The editor's find bar draws its toggles frameless; the project
    /// panel keeps frames. Purely visual, preserved per consumer.
    flat_toggles: bool = true,
    /// The regex toggle is the one whose tooltip differs per consumer.
    regex_tooltip: [*:0]const u8,
};

pub const Widgets = struct {
    entry: *c.GtkWidget,
    count: ?*c.GtkLabel,
    case_btn: *c.GtkWidget,
    word_btn: *c.GtkWidget,
    regex_btn: *c.GtkWidget,
};

/// Appends entry [+ count] + toggle trio to the consumer's row box.
pub fn build(row: ?*c.GtkWidget, spec: Spec, cbs: Callbacks) Widgets {
    const entry = c.gtk_search_entry_new();
    c.gtk_search_entry_set_placeholder_text(@ptrCast(@alignCast(entry)), spec.placeholder);
    if (spec.width_chars > 0) c.gtk_editable_set_width_chars(@ptrCast(entry), spec.width_chars);
    if (spec.hexpand) c.gtk_widget_set_hexpand(entry, 1);
    if (cbs.on_changed) |cb|
        _ = c.g_signal_connect_data(entry, "changed", cb, cbs.ctx, null, c.G_CONNECT_DEFAULT);
    if (cbs.on_activate) |cb|
        _ = c.g_signal_connect_data(entry, "activate", cb, cbs.ctx, null, c.G_CONNECT_DEFAULT);
    if (cbs.on_stop) |cb|
        _ = c.g_signal_connect_data(entry, "stop-search", cb, cbs.ctx, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), entry);

    var count: ?*c.GtkLabel = null;
    if (spec.count_width_chars > 0) {
        const label = c.gtk_label_new("");
        c.gtk_widget_add_css_class(label, "dim-label");
        c.gtk_label_set_width_chars(@ptrCast(label), spec.count_width_chars);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_box_append(@ptrCast(row), label);
        count = @ptrCast(@alignCast(label));
    }

    return .{
        .entry = entry.?,
        .count = count,
        .case_btn = toggle(row, "Aa", "Match case", spec.flat_toggles, cbs),
        .word_btn = toggle(row, "\u{2423}W", "Whole word only", spec.flat_toggles, cbs),
        .regex_btn = toggle(row, ".*", spec.regex_tooltip, spec.flat_toggles, cbs),
    };
}

/// Flat icon button for prev/next/close, appended where the consumer
/// wants it.
pub fn navButton(
    row: ?*c.GtkWidget,
    icon: [*:0]const u8,
    tooltip: ?[*:0]const u8,
    cb: c.GCallback,
    ctx: *anyopaque,
) *c.GtkWidget {
    const btn = c.gtk_button_new_from_icon_name(icon);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    if (tooltip) |tip| c.gtk_widget_set_tooltip_text(btn, tip);
    _ = c.g_signal_connect_data(btn, "clicked", cb, ctx, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), btn);
    return btn.?;
}

fn toggle(row: ?*c.GtkWidget, label: [*:0]const u8, tooltip: [*:0]const u8, flat: bool, cbs: Callbacks) *c.GtkWidget {
    const btn = c.gtk_toggle_button_new_with_label(label);
    if (flat) c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    c.gtk_widget_set_tooltip_text(btn, tooltip);
    if (cbs.on_toggle_changed) |cb|
        _ = c.g_signal_connect_data(btn, "toggled", cb, cbs.ctx, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(row), btn);
    return btn.?;
}

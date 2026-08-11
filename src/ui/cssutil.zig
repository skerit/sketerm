//! One place that turns a CSS string into an installed display-wide
//! GtkCssProvider, replacing the `var css_installed = false` + provider
//! dance that every face used to carry its own copy of.

const std = @import("std");
const c = @import("../c.zig").c;

/// Per-tag installed flag. Zig memoizes generic instantiations by the
/// comptime value, so one `Flag(tag)` type — and one `installed` bool —
/// exists per distinct tag across the whole program.
fn Flag(comptime tag: []const u8) type {
    return struct {
        const name = tag;
        var installed: bool = false;
    };
}

/// Load `css` display-wide at APPLICATION priority, once per `tag`.
///
/// `widget` names the display; pass null (or a widget with no display)
/// to use the default one. A face whose CSS must be reloaded when
/// config changes needs its own retained provider, not this.
pub fn install(comptime tag: []const u8, widget: ?*c.GtkWidget, css: [:0]const u8) void {
    const F = Flag(tag);
    if (F.installed) return;
    const display = if (widget) |w| c.gtk_widget_get_display(w) else c.gdk_display_get_default();
    if (display == null) return;
    F.installed = true;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css.ptr);
    c.gtk_style_context_add_provider_for_display(
        display,
        @ptrCast(@alignCast(provider)),
        c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
    );
    c.g_object_unref(provider);
}

test "distinct tags keep distinct install flags" {
    try std.testing.expect(&Flag("a").installed != &Flag("b").installed);
    try std.testing.expect(&Flag("a").installed == &Flag("a").installed);
}

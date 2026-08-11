//! The face toolbars' shared construction helpers.
//!
//! Three faces grow a toolbar of flat icon buttons -- the file
//! manager, the web view and the editor -- and each had hand-built its
//! own, so they drifted apart in margins, spacing and hover feedback,
//! and only one of them survived a theme that cannot draw the icon it
//! asked for. Everything a face toolbar needs is here now: the bar
//! itself, the linked nav pair, the buttons, and the stylesheet that
//! makes flat buttons react to the pointer under Breeze.
//!
//! Icon names go through `iconload` (a corrupt icon-theme cache makes
//! GTK render nothing) AND through `iconAvailable` (a theme that does
//! not ship the name at all falls back to a text label), so the worst
//! case is a labelled button rather than an invisible one.

const c = @import("../c.zig").c;
const iconload = @import("iconload.zig");

/// The css class every face toolbar wears. Named for the file
/// browser, which is where the look was designed; the web and editor
/// toolbars follow it rather than inventing a second style.
pub const TOOLBAR_CLASS = "sketerm-fb-toolbar";

/// Icon pixel size for toolbar buttons.
pub const ICON_PX: i32 = 16;

/// True when the running icon theme can actually draw `name`.
///
/// `gtk_button_new_from_icon_name` with an unresolvable name is
/// SILENT: the button lays out and renders nothing. That is how the
/// "show the shell" button became invisible on a KDE desktop --
/// Adwaita keeps `utilities-terminal-symbolic` only under
/// `symbolic/legacy/`, which a Breeze-based theme chain never
/// reaches. Names sketerm ships itself live in `data/icons` (the
/// hicolor fallback, always searched), so they always resolve.
pub fn iconAvailable(name: [*:0]const u8) bool {
    const display = c.gdk_display_get_default() orelse return true;
    const theme = c.gtk_icon_theme_get_for_display(display) orelse return true;
    return c.gtk_icon_theme_has_icon(theme, name) != 0;
}

/// Nemo's toolbar buttons: flat, icon-only, and out of the focus
/// chain, so Tab walks the content rather than the chrome.
pub fn flatten(btn: *c.GtkWidget) void {
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    c.gtk_widget_add_css_class(btn, "flat");
    c.gtk_widget_set_can_focus(btn, 0);
}

/// Point an existing button at another icon, keeping the text
/// fallback. `anchor` only supplies the display/theme.
pub fn setIcon(btn: *c.GtkWidget, anchor: *c.GtkWidget, icon: [*:0]const u8, text: [*:0]const u8) void {
    if (iconAvailable(icon))
        c.gtk_button_set_child(@ptrCast(btn), iconload.newImageIcon(anchor, icon, ICON_PX))
    else
        c.gtk_button_set_label(@ptrCast(btn), text);
}

/// A framed icon button, wired but NOT appended and NOT flattened --
/// for the bars that are not flat chrome (the disk-usage header).
pub fn button(anchor: *c.GtkWidget, icon: [*:0]const u8, text: [*:0]const u8, tip: [*:0]const u8, cb: anytype, user: ?*anyopaque) *c.GtkWidget {
    const btn = c.gtk_button_new().?;
    setIcon(btn, anchor, icon, text);
    c.gtk_widget_set_tooltip_text(btn, tip);
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(cb), user, null, c.G_CONNECT_DEFAULT);
    return btn;
}

/// One toolbar button: flat, appended to `bar`, labelled when its
/// icon name does not resolve.
pub fn barButton(bar: *c.GtkWidget, icon: [*:0]const u8, text: [*:0]const u8, tip: [*:0]const u8, cb: anytype, user: ?*anyopaque) *c.GtkWidget {
    const btn = button(bar, icon, text, tip, cb, user);
    flatten(btn);
    c.gtk_box_append(@ptrCast(bar), btn);
    return btn;
}

/// `barButton` for a toggle. Same icon guarantee.
pub fn barToggle(bar: *c.GtkWidget, icon: [*:0]const u8, text: [*:0]const u8, tip: [*:0]const u8, cb: anytype, user: ?*anyopaque) *c.GtkWidget {
    const btn = c.gtk_toggle_button_new().?;
    setIcon(btn, bar, icon, text);
    c.gtk_widget_set_tooltip_text(btn, tip);
    flatten(btn);
    _ = c.g_signal_connect_data(btn, "toggled", @ptrCast(cb), user, null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(bar), btn);
    return btn;
}

/// A face toolbar: horizontal, one uniform inset all round, wearing
/// the shared class. The caller still appends it wherever it goes.
pub fn newBar() *c.GtkWidget {
    const bar = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
    c.gtk_widget_add_css_class(bar, TOOLBAR_CLASS);
    c.gtk_widget_set_margin_start(bar, 3);
    c.gtk_widget_set_margin_end(bar, 3);
    c.gtk_widget_set_margin_top(bar, 3);
    c.gtk_widget_set_margin_bottom(bar, 3);
    return bar;
}

/// Back and Forward are ONE control with two halves: they are the
/// same axis, and Nemo's own pathbar reads that way. The caller fills
/// it with `barButton` and appends it.
pub fn newNavPair() *c.GtkWidget {
    const pair = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?;
    c.gtk_widget_add_css_class(pair, "linked");
    c.gtk_widget_add_css_class(pair, "sketerm-fb-navpair");
    return pair;
}

/// The face-toolbar stylesheet: the linked nav pair has to read as a
/// single control, which no stock GTK class does for a box of flat
/// buttons. It also states the hover/active feedback outright, since
/// Breeze draws NOTHING for a `.flat` button and the chrome would
/// otherwise read as dead pixels under the pointer. Installed once
/// per process, at APPLICATION priority, so a user theme still wins.
var css_installed: bool = false;

pub fn installCss(any_widget: *c.GtkWidget) void {
    if (css_installed) return;
    css_installed = true;
    const css =
        \\.sketerm-fb-navpair {
        \\  border: 1px solid rgba(128,128,128,0.35);
        \\  border-radius: 7px;
        \\}
        \\.sketerm-fb-navpair button {
        \\  border-radius: 6px;
        \\  margin: 0;
        \\  min-height: 24px;
        \\}
        \\.sketerm-fb-toolbar button { padding-left: 6px; padding-right: 6px; }
        \\.sketerm-fb-toolbar button:hover {
        \\  background: alpha(currentColor, 0.10);
        \\}
        \\.sketerm-fb-toolbar button:active,
        \\.sketerm-fb-toolbar button:checked {
        \\  background: alpha(currentColor, 0.20);
        \\}
        \\.sketerm-fb-toolbar button:checked:hover {
        \\  background: alpha(currentColor, 0.26);
        \\}
    ;
    const provider = c.gtk_css_provider_new();
    c.gtk_css_provider_load_from_string(provider, css);
    const display = c.gtk_widget_get_display(any_widget);
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(@alignCast(provider)), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

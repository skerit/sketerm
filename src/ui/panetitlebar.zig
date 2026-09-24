//! The per-pane title bar (Terminator-style) as state: the widgets
//! `Pane.init` builds and the visibility / active bookkeeping that
//! used to be eleven `titlebar_*` fields on Pane.
//!
//! The bar sits above the GLArea inside the pane's wrapper box. Its
//! label follows on_title (OSC 0/1/2); active / inactive colouring is
//! the CSS classes "sketerm-titlebar-active" / "-inactive" plus the
//! Window-level provider that supplies the rgba values from
//! Config.title_*_* (`winconfig.refreshTitlebarCss`).

const c = @import("../c.zig").c;

pub const Titlebar = struct {
    box: ?*c.GtkWidget = null,
    label: ?*c.GtkLabel = null,
    /// What is on screen now: `config_visible or auto`.
    visible: bool = false,
    active: bool = false,
    /// Baseline visibility pushed by the Window (config show_titlebar).
    /// The effective state ORs in `auto`, so session activity can
    /// surface the bar on panes that keep it hidden otherwise.
    config_visible: bool = false,
    /// Activity wants the titlebar shown: floating app windows, a
    /// view-only lease, or an attached assistant. Replaces the old
    /// "App window open — click to raise" banner.
    auto: bool = false,
    /// Per-window taskbar buttons for the session's floating app
    /// windows, inside the titlebar.
    apps_box: ?*c.GtkWidget = null,
    /// True while `apps_box` has at least one button.
    apps_shown: bool = false,
    /// Lease/roster chip: "AI attached" / "View only — holder".
    chip: ?*c.GtkWidget = null,
    chip_label: ?*c.GtkLabel = null,
    take_btn: ?*c.GtkWidget = null,

    /// Set the config-driven baseline (see `config_visible`).
    pub fn setConfigVisible(self: *Titlebar, visible: bool) void {
        self.config_visible = visible;
        self.applyVisibility();
    }

    pub fn applyVisibility(self: *Titlebar) void {
        const tb = self.box orelse return;
        const effective = self.config_visible or self.auto;
        if (self.visible == effective) return;
        self.visible = effective;
        c.gtk_widget_set_visible(tb, if (effective) 1 else 0);
    }

    /// Toggle the active / inactive CSS class.
    pub fn setActive(self: *Titlebar, active: bool) void {
        const tb = self.box orelse return;
        if (self.active == active) return;
        self.active = active;
        if (active) {
            c.gtk_widget_remove_css_class(tb, "sketerm-titlebar-inactive");
            c.gtk_widget_add_css_class(tb, "sketerm-titlebar-active");
        } else {
            c.gtk_widget_remove_css_class(tb, "sketerm-titlebar-active");
            c.gtk_widget_add_css_class(tb, "sketerm-titlebar-inactive");
        }
    }
};

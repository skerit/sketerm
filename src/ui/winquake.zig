//! The GDK half of quake mode, split out of window.zig: resolving
//! `quake_*` to a `GdkMonitor` and driving either the wlr-layer-shell
//! surface or the xdg-toplevel fallback. The placement arithmetic is
//! pure and lives in `quake.zig`. Functions keep the owning *Window
//! receiver and are aliased back into Window.

const std = @import("std");
const c = @import("../c.zig").c;
const winmod = @import("window.zig");
const Window = winmod.Window;
const quake = @import("quake.zig");

/// Quake-mode toggle (`sketerm --toggle`): hide when shown and
/// focused, else show and present. Hide rather than minimize: a
/// layer surface has no minimize at all, and Wayland has no
/// unminimize request either, so a reveal from a minimized
/// xdg-toplevel hung on an activation token the `--toggle` process
/// never holds, while a fresh map is honoured everywhere. Hiding
/// keeps the widget tree, the panes and their sessions; only the
/// wl_surface goes, and `TerminalSurface` treats a re-realize as
/// routine.
pub fn toggleQuake(self: *Window) void {
    const window: *c.GtkWindow = @ptrCast(@alignCast(self.app_window));
    // gtk_window_is_active is "has focus AND is visible", so a
    // shown-but-unfocused window is raised, not hidden.
    const mapped = c.gtk_widget_get_mapped(self.app_window) != 0;
    const active = c.gtk_window_is_active(window) != 0;
    if (mapped and active) {
        c.gtk_widget_set_visible(self.app_window, 0);
        return;
    }
    // Re-resolve on every reveal: with `quake_monitor = active`
    // the target follows the user, and monitors come and go.
    self.applyQuakeGeometry();
    c.gtk_widget_set_visible(self.app_window, 1);
    c.gtk_window_present(window);
}

/// Whether this build has gtk4-layer-shell at all (`-Dlayer-shell`,
/// Linux only): the decls exist exactly when the TranslateC step
/// included its header, so every layer call sits behind this.
const quake_layer_shell = @hasDecl(c, "gtk_layer_init_for_window");

/// Place the primary window per the `quake_*` config: through the
/// layer surface when the compositor has wlr-layer-shell, else the
/// xdg-toplevel fallback (size, plus `fullscreen_on_monitor` at
/// full coverage -- the one GTK4 call that names a monitor; the
/// edge cannot be applied there at all, see `ui/quake.zig`). Runs
/// from `init` before the first map, on every reveal, and on a
/// config apply that moved a quake key. With quake switched off
/// the fallback window is unfullscreened; a window that already
/// became a layer surface stays one until the next start, which
/// is said on stderr.
pub fn applyQuakeGeometry(self: *Window) void {
    if (!self.is_primary) return;
    const window: *c.GtkWindow = @ptrCast(@alignCast(self.app_window));
    if (!self.config.quake_enabled) {
        if (quakeIsLayerWindow(window)) {
            std.debug.print("sketerm: quake_enabled = false takes effect at the next start (the window is a layer surface)\n", .{});
            return;
        }
        c.gtk_window_unfullscreen(window);
        return;
    }
    const monitor = quakeMonitor(self);
    var geo: c.GdkRectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    if (monitor) |m| c.gdk_monitor_get_geometry(m, &geo);
    if (geo.width <= 0 or geo.height <= 0) return;
    const placement = quake.place(
        .{ .x = geo.x, .y = geo.y, .w = geo.width, .h = geo.height },
        self.config.quake_width_percent,
        self.config.quake_height_percent,
        self.config.quake_edge,
    );
    if (quakeLayerApply(self, window, monitor, placement)) return;

    if (placement.coversMonitor()) {
        if (monitor) |m| {
            c.gtk_window_fullscreen_on_monitor(window, m);
            return;
        }
        c.gtk_window_fullscreen(window);
        return;
    }
    c.gtk_window_unfullscreen(window);
    c.gtk_window_set_default_size(window, placement.rect.w, placement.rect.h);
}

/// True when the window has been initialised as a layer surface.
fn quakeIsLayerWindow(window: *c.GtkWindow) bool {
    if (comptime !quake_layer_shell) return false;
    return c.gtk_layer_is_layer_window(window) != 0;
}

/// Layer-shell half of `applyQuakeGeometry`: true when the window
/// is (or just became) a layer surface and `placement` went through
/// it. False on a build without gtk4-layer-shell, on X11, and on a
/// compositor without zwlr_layer_shell_v1 (`gtk_layer_is_supported`
/// is the runtime check; it also comes back false when the library
/// was linked behind libwayland-client, which build.zig's link
/// order prevents).
///
/// The role is taken when GTK asks for the surface's xdg role at
/// map time, so a window that is already mapped when quake is
/// switched on (config apply) is hidden around the init and shown
/// again once the placement is set. The reverse has no API: once a
/// layer surface, always one, until the next start.
///
/// Layer OVERLAY, not TOP: a drop-down summoned by a hotkey must
/// show over a fullscreen window too, and it is unmapped when not
/// in use, so it never permanently covers anything. Keyboard mode
/// ON_DEMAND, not EXCLUSIVE: the surface takes focus when it maps
/// and gives it up when the user clicks elsewhere, so a half-height
/// terminal does not lock the keyboard away from the window under
/// it. No exclusive zone: nothing gets pushed aside.
fn quakeLayerApply(self: *Window, window: *c.GtkWindow, monitor: ?*c.GdkMonitor, placement: quake.Placement) bool {
    if (comptime !quake_layer_shell) return false;
    var remap = false;
    if (c.gtk_layer_is_layer_window(window) == 0) {
        if (c.gtk_layer_is_supported() == 0) return false;
        remap = c.gtk_widget_get_mapped(self.app_window) != 0;
        if (remap) c.gtk_widget_set_visible(self.app_window, 0);
        c.gtk_layer_init_for_window(window);
        c.gtk_layer_set_namespace(window, "sketerm-quake");
        c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
        c.gtk_layer_set_keyboard_mode(window, c.GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND);
        c.gtk_layer_set_exclusive_zone(window, 0);
    }
    // `active` is the compositor's choice (null output = the
    // focused output on KWin and wlroots), which is what a
    // drop-down that follows the user means; the pixel size still
    // came from the best-known monitor. Only a CHANGED monitor is
    // set: the library remaps a mapped surface on every set.
    const spec = quake.parseMonitor(self.config.quake_monitor);
    const want: ?*c.GdkMonitor = if (spec == .active) null else monitor;
    const have: ?*c.GdkMonitor = c.gtk_layer_get_monitor(window);
    if (have != want) c.gtk_layer_set_monitor(window, want);
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_LEFT, @intFromBool(placement.anchors.left));
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_RIGHT, @intFromBool(placement.anchors.right));
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_TOP, @intFromBool(placement.anchors.top));
    c.gtk_layer_set_anchor(window, c.GTK_LAYER_SHELL_EDGE_BOTTOM, @intFromBool(placement.anchors.bottom));
    // Centring on the unpinned axis is the protocol's own rule for
    // a single anchored edge, so no margins are needed for it.
    c.gtk_window_set_default_size(window, placement.layer_w, placement.layer_h);
    if (remap) {
        c.gtk_widget_set_visible(self.app_window, 1);
        c.gtk_window_present(window);
    }
    return true;
}

/// The `GdkMonitor` `quake_monitor` names, or null when the
/// display has none. Ownership: `g_list_model_get_item` returns a
/// ref we drop immediately — the display owns its monitors and
/// outlives any use here.
fn quakeMonitor(self: *Window) ?*c.GdkMonitor {
    const display = c.gtk_widget_get_display(self.app_window) orelse return null;
    const spec = quake.parseMonitor(self.config.quake_monitor);
    if (spec == .active) {
        if (c.gtk_native_get_surface(@ptrCast(@alignCast(self.app_window)))) |surface| {
            if (c.gdk_display_get_monitor_at_surface(display, surface)) |m| return m;
        }
    }
    const monitors = c.gdk_display_get_monitors(display) orelse return null;
    const n = c.g_list_model_get_n_items(@ptrCast(@alignCast(monitors)));
    if (n == 0) return null;
    const wanted: u32 = switch (spec) {
        .index => |i| i,
        .connector => |name| blk: {
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                const item = c.g_list_model_get_item(@ptrCast(@alignCast(monitors)), i) orelse continue;
                defer c.g_object_unref(item);
                const conn = c.gdk_monitor_get_connector(@ptrCast(@alignCast(item)));
                if (conn != null and std.mem.eql(u8, std.mem.span(conn), name)) break :blk i;
            }
            break :blk 0;
        },
        // `active` only lands here when the window has no surface
        // yet (first show), where the first monitor is the best
        // guess available.
        .active, .primary => 0,
    };
    const idx = if (wanted < n) wanted else 0;
    const item = c.g_list_model_get_item(@ptrCast(@alignCast(monitors)), idx) orelse return null;
    c.g_object_unref(item);
    return @ptrCast(@alignCast(item));
}

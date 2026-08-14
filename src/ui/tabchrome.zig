//! Tab chrome — context menu, per-tab colours, progress/cmd
//! indicators, taskbar progress, tab-bar gestures and the activity
//! ack — split out of window.zig.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const Window = winmod.Window;
const tab_effects = @import("tab_effects.zig");
const connectManualPopoverClose = winmod.connectManualPopoverClose;

const TabMenuAction = enum { new_tab, rename, duplicate, color, pin, move_new_window, collapse, close_subtree, close };
const TabMenuToggleKind = enum { show_activity, warn_inactive };

const TabMenuActionCtx = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    popover: *c.GtkWidget,
    /// The tab the menu was opened on (the right-click also selected
    /// it; kept for the tree verbs, which act on the page even if the
    /// selection moved before the click landed).
    page: *c.AdwTabPage,
    action: TabMenuAction,
};
const TabMenuToggleCtx = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    page: *c.AdwTabPage,
    kind: TabMenuToggleKind,
};

const TabColorCtx = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    page: *c.AdwTabPage,
};


/// Build and pop the right-click tab menu, anchored on the clicked tab.
/// The standard actions all run on the selected page (the right-click
/// already selected it); the toggles target the clicked page directly.
pub fn onTabContextMenu(ctx: ?*anyopaque, page: *c.AdwTabPage, anchor: *c.GtkWidget, x: f64, y: f64) void {
    const self = cast.userData(Window, ctx);

    const popover = c.gtk_popover_new();
    c.gtk_widget_set_parent(popover, anchor);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);
    const rect = c.GdkRectangle{ .x = @intFromFloat(x), .y = @intFromFloat(y), .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    connectManualPopoverClose(popover);

    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

    addTabMenuAction(self, popover, list, page, "New Tab", "tab-new-symbolic", .new_tab);

    c.gtk_box_append(@ptrCast(list), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));

    addTabMenuAction(self, popover, list, page, "Rename Tab…", "document-edit-symbolic", .rename);
    addTabMenuAction(self, popover, list, page, "Duplicate Tab", "edit-copy-symbolic", .duplicate);
    addTabMenuAction(self, popover, list, page, "Tab Colour…", "color-select-symbolic", .color);
    addTabMenuAction(self, popover, list, page, "Pin / Unpin Tab", "view-pin-symbolic", .pin);
    if (c.adw_tab_view_get_n_pages(self.tab_view) > 1 and c.adw_tab_page_get_pinned(page) == 0)
        addTabMenuAction(self, popover, list, page, "Move to New Window", "window-new-symbolic", .move_new_window);

    c.gtk_box_append(@ptrCast(list), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));

    const s = tab_effects.tabSettings(page);
    addTabMenuToggle(self, list, page, "Show activity", s.show_activity, .show_activity);
    addTabMenuToggle(self, list, page, "Warn inactivity", s.warn_inactive, .warn_inactive);

    // Tree verbs, only where the tab actually heads a subtree.
    if (self.tab_forest.hasChildren(page)) {
        c.gtk_box_append(@ptrCast(list), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));
        const collapse_label: [*:0]const u8 =
            if (self.tab_forest.isCollapsed(page)) "Expand Subtree" else "Collapse Subtree";
        addTabMenuAction(self, popover, list, page, collapse_label, "view-list-symbolic", .collapse);
        addTabMenuAction(self, popover, list, page, "Close Subtree", "edit-delete-symbolic", .close_subtree);
    }

    c.gtk_box_append(@ptrCast(list), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));
    addTabMenuAction(self, popover, list, page, "Close Tab", "window-close-symbolic", .close);

    c.gtk_popover_set_child(@ptrCast(popover), list);
    c.gtk_popover_popup(@ptrCast(popover));
}

/// Icon+label button row that runs a window method on the selected tab.
pub fn addTabMenuAction(self: *Window, popover: *c.GtkWidget, list: *c.GtkWidget, page: *c.AdwTabPage, label: [*:0]const u8, icon: [*:0]const u8, action: TabMenuAction) void {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    const img = c.gtk_image_new_from_icon_name(icon);
    const lbl = c.gtk_label_new(label);
    c.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
    c.gtk_widget_set_hexpand(lbl, 1);
    c.gtk_box_append(@ptrCast(row), img);
    c.gtk_box_append(@ptrCast(row), lbl);

    const btn = c.gtk_button_new();
    c.gtk_button_set_child(@ptrCast(btn), row);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    const actx = self.allocator.create(TabMenuActionCtx) catch return;
    actx.* = .{ .allocator = self.allocator, .window = self, .popover = popover, .page = page, .action = action };
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onTabMenuActionClicked), @ptrCast(actx), @ptrCast(cast.destroyCtx(TabMenuActionCtx)), c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(list), btn);
}

/// Checkbox row bound to one of the clicked page's effect toggles.
pub fn addTabMenuToggle(self: *Window, list: *c.GtkWidget, page: *c.AdwTabPage, label: [*:0]const u8, active: bool, kind: TabMenuToggleKind) void {
    const check = c.gtk_check_button_new_with_label(label);
    c.gtk_check_button_set_active(@ptrCast(check), @intFromBool(active));
    const tctx = self.allocator.create(TabMenuToggleCtx) catch return;
    tctx.* = .{ .allocator = self.allocator, .window = self, .page = page, .kind = kind };
    _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onTabMenuToggled), @ptrCast(tctx), @ptrCast(cast.destroyCtx(TabMenuToggleCtx)), c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(list), check);
}

pub fn onTabMenuActionClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const a = cast.userData(TabMenuActionCtx, user);
    c.gtk_popover_popdown(@ptrCast(a.popover));
    switch (a.action) {
        .new_tab => if (!a.window.newTabInBrowser()) {
            a.window.newShellTab(null) catch {};
        },
        .rename => a.window.renameCurrentTab(),
        .duplicate => a.window.duplicateCurrentTab(),
        .color => chooseTabColor(a.window),
        .pin => a.window.togglePinCurrentTab(),
        .move_new_window => if (pageStillOpen(a.window, a.page))
            a.window.moveTabToNewWindow(a.page),
        .collapse => if (pageStillOpen(a.window, a.page))
            a.window.setTabCollapsed(a.page, !a.window.tab_forest.isCollapsed(a.page)),
        .close_subtree => if (pageStillOpen(a.window, a.page))
            a.window.closeTabSubtree(a.page),
        .close => a.window.closeCurrentTab(),
    }
}

pub fn onTabMenuToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const t = cast.userData(TabMenuToggleCtx, user);
    const on = c.gtk_check_button_get_active(check) != 0;
    var s = tab_effects.tabSettings(t.page);
    switch (t.kind) {
        .show_activity => s.show_activity = on,
        .warn_inactive => s.warn_inactive = on,
    }
    tab_effects.setTabSettings(t.page, s);
    // Repaint the strip and, if an effect just turned on, make sure the
    // animation tick (and the warning's silence timer) are running.
    t.window.tabbar.refresh();
    if (on) {
        t.window.tabbar.ensureTick();
        // Turning on warn_inactive doesn't itself arm anything: the warning
        // is edge-triggered, so it waits for the tab's next activity→
        // silence cycle. (Already-pending activity is picked up by the
        // tab bar's reschedule.)
        if (t.kind == .warn_inactive) t.window.tabbar.armWarn(t.page);
    }
}

/// Arm (or, with a zero delay, immediately run) the delayed acknowledge
/// for the now-selected `page`. Any previous pending acknowledge is
/// cancelled, so flicking through tabs never acknowledges the ones merely
/// passed over — only the tab dwelt on long enough.
pub fn scheduleTabAck(self: *Window, page: *c.AdwTabPage) void {
    if (self.ack_timer_id != 0) {
        _ = c.g_source_remove(self.ack_timer_id);
        self.ack_timer_id = 0;
    }
    const delay = self.config.tab_ack_delay_secs;
    if (delay <= 0) {
        tab_effects.markAck(page);
        self.tabbar.armWarn(page);
        return;
    }
    self.ack_timer_page = page;
    const ms: c.guint = @intFromFloat(delay * 1000.0);
    self.ack_timer_id = c.g_timeout_add(ms, @ptrCast(&onTabAckTimer), self);
}

/// Wrap a 64×64 RGBA buffer in a GdkTexture for tab iconography
/// (colour swatch, progress ring). Caller unrefs.
pub fn iconTexture64(px: *const [64 * 64 * 4]u8) ?*c.GdkTexture {
    const bytes = c.g_bytes_new(px, px.len);
    defer c.g_bytes_unref(bytes);
    return c.gdk_memory_texture_new(64, 64, c.GDK_MEMORY_R8G8B8A8, bytes, 64 * 4);
}

/// Set or clear a tab's colour: a round swatch as the
/// page icon, plus the packed value on the GObject so layout
/// save and `cli list` can read it back. Marker bit 1<<24
/// distinguishes "black" from "unset".
pub fn setTabColor(self: *Window, page: *c.AdwTabPage, rgb: ?[3]u8) void {
    _ = self;
    if (rgb) |col| {
        // 4× supersampled disc with a soft rim, like the progress
        // ring — a raw 16px circle renders visibly jagged.
        const S = 64;
        const ctr = (@as(f32, S) - 1.0) / 2.0;
        var px: [S * S * 4]u8 = undefined;
        for (0..S) |yy| {
            for (0..S) |xx| {
                const dx = @as(f32, @floatFromInt(xx)) - ctr;
                const dy = @as(f32, @floatFromInt(yy)) - ctr;
                const r = @sqrt(dx * dx + dy * dy);
                const cov = std.math.clamp(28.0 - r + 0.5, 0.0, 1.0);
                const o = (yy * S + xx) * 4;
                px[o + 0] = col[0];
                px[o + 1] = col[1];
                px[o + 2] = col[2];
                px[o + 3] = @intFromFloat(255.0 * cov);
            }
        }
        const tex = iconTexture64(&px) orelse return;
        c.adw_tab_page_set_icon(page, @ptrCast(@alignCast(tex)));
        c.g_object_unref(tex);
        const packed_val: usize = (1 << 24) |
            (@as(usize, col[0]) << 16) | (@as(usize, col[1]) << 8) | col[2];
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-color", @ptrFromInt(packed_val));
    } else {
        c.adw_tab_page_set_icon(page, null);
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-color", null);
    }
}

/// Tab progress ring (OSC 9;4), drawn into the page's INDICATOR
/// icon so it coexists with the tab-colour swatch (which owns the
/// regular icon). State 0 clears. The packed value also lands on
/// the GObject (marker 1<<24 | state<<8 | percent) so the taskbar
/// aggregate can walk pages without touching panes.
pub fn setTabProgress(self: *Window, page: ?*c.AdwTabPage, state: u8, percent: u8) void {
    if (state == 0) {
        c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-progress", null);
        // A latched command-status dot (set while the ring was
        // active) takes the indicator back; else clear it.
        drawTabCmdDot(self, page);
        return;
    }
    const color: [3]u8 = switch (state) {
        2 => .{ 0xE0, 0x1B, 0x24 }, // error: red
        4 => .{ 0xF5, 0xC2, 0x11 }, // paused: amber
        else => .{ 0x35, 0x84, 0xE4 }, // normal/indeterminate: blue
    };
    // Indeterminate has no meaningful percent; a 3/4 ring reads
    // as "busy" without pretending to know how far along.
    const turn = if (state == 3)
        0.75 * std.math.tau
    else
        @as(f32, @floatFromInt(percent)) / 100.0 * std.math.tau;
    // Rendered at 4× the display size with soft edges; GTK's
    // downscale does the rest. Drawing at 16px directly gives a
    // visibly lumpy ring.
    const S = 64;
    const ctr = (@as(f32, S) - 1.0) / 2.0;
    const r_out = 30.0;
    const r_in = 18.0;
    var px: [S * S * 4]u8 = undefined;
    for (0..S) |yy| {
        for (0..S) |xx| {
            const dx = @as(f32, @floatFromInt(xx)) - ctr;
            const dy = @as(f32, @floatFromInt(yy)) - ctr;
            const r = @sqrt(dx * dx + dy * dy);
            const o = (yy * S + xx) * 4;
            px[o + 0] = color[0];
            px[o + 1] = color[1];
            px[o + 2] = color[2];
            // Radial coverage: 1 inside the annulus, fading over
            // ~1px at both rims.
            const cov = std.math.clamp(@min(r_out - r, r - r_in) + 0.5, 0.0, 1.0);
            // Angle from 12 o'clock, clockwise. The unfilled
            // remainder stays as a faint track; the arc tip gets
            // a ~1px angular feather (scaled by radius so the
            // feather width is constant in pixels).
            var ang = std.math.atan2(dx, -dy);
            if (ang < 0) ang += std.math.tau;
            const fill = std.math.clamp((turn - ang) * @max(r, 1.0) + 0.5, 0.0, 1.0);
            const a = (56.0 + fill * (255.0 - 56.0)) * cov;
            px[o + 3] = @intFromFloat(a);
        }
    }
    const tex = iconTexture64(&px) orelse return;
    c.adw_tab_page_set_indicator_icon(page, @ptrCast(@alignCast(tex)));
    c.g_object_unref(tex);
    const packed_val: usize = (1 << 24) | (@as(usize, state) << 8) | percent;
    c.g_object_set_data(@ptrCast(@alignCast(page)), "sketerm-tab-progress", @ptrFromInt(packed_val));
}

/// OSC 133 command status for a tab: 0 clear, 1 running, 2 ok,
/// 3 failed. Latched on the GObject ("sketerm-tab-cmd"); the
/// indicator icon only changes when no OSC 9;4 progress ring is
/// active (the ring wins, the dot lands when it clears).
pub fn setTabCmdStatus(self: *Window, page: ?*c.AdwTabPage, status: u8) void {
    if (page == null) return;
    c.g_object_set_data(
        @ptrCast(@alignCast(page)),
        "sketerm-tab-cmd",
        if (status == 0) null else @ptrFromInt((@as(usize, 1) << 8) | status),
    );
    if (c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-progress") != null) return;
    drawTabCmdDot(self, page);
}

/// Render the latched command-status dot into the indicator icon
/// (or clear it when none is latched).
pub fn drawTabCmdDot(self: *Window, page: ?*c.AdwTabPage) void {
    _ = self;
    const raw = c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-cmd");
    const status: u8 = if (raw == null) 0 else @intCast(@intFromPtr(raw) & 0xff);
    if (status == 0) {
        c.adw_tab_page_set_indicator_icon(page, null);
        return;
    }
    const color: [3]u8 = switch (status) {
        2 => .{ 0x2E, 0xC2, 0x7E }, // ok: green
        3 => .{ 0xE0, 0x1B, 0x24 }, // failed: red
        else => .{ 0x35, 0x84, 0xE4 }, // running: blue
    };
    // Same 4×-supersampled canvas as the progress ring; a plain
    // filled dot with a ~1px soft rim.
    const S = 64;
    const ctr = (@as(f32, S) - 1.0) / 2.0;
    const r_dot = 18.0;
    var px: [S * S * 4]u8 = undefined;
    for (0..S) |yy| {
        for (0..S) |xx| {
            const dx = @as(f32, @floatFromInt(xx)) - ctr;
            const dy = @as(f32, @floatFromInt(yy)) - ctr;
            const r = @sqrt(dx * dx + dy * dy);
            const o = (yy * S + xx) * 4;
            px[o + 0] = color[0];
            px[o + 1] = color[1];
            px[o + 2] = color[2];
            const cov = std.math.clamp(r_dot - r + 0.5, 0.0, 1.0);
            px[o + 3] = @intFromFloat(255.0 * cov);
        }
    }
    const tex = iconTexture64(&px) orelse return;
    c.adw_tab_page_set_indicator_icon(page, @ptrCast(@alignCast(tex)));
    c.g_object_unref(tex);
}

/// Aggregate every tab's progress into one window-level value and
/// publish it over the Unity LauncherEntry D-Bus signal — KDE's
/// task manager and most docks fill the taskbar button with it.
/// Mean percent across active tabs (indeterminate counts as 50);
/// any error state raises the urgent flag. Deduplicated so OSC
/// floods don't spam the bus.
pub fn updateTaskbarProgress(self: *Window) void {
    var total: u32 = 0;
    var count: u32 = 0;
    var urgent = false;
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        const page = c.adw_tab_view_get_nth_page(self.tab_view, i);
        if (page == null) continue;
        const v = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-progress"));
        if (v & (1 << 24) == 0) continue;
        const state: u8 = @truncate(v >> 8);
        total += if (state == 3) 50 else @as(u8, @truncate(v));
        count += 1;
        if (state == 2) urgent = true;
    }
    const visible = count != 0;
    const pct: u32 = if (visible) total / count else 0;
    const packed_sig: u32 = (@as(u32, @intFromBool(visible)) << 16) |
        (@as(u32, @intFromBool(urgent)) << 8) | pct;
    if (packed_sig == self.taskbar_sent) return;
    self.taskbar_sent = packed_sig;

    const app = c.gtk_window_get_application(@ptrCast(self.app_window));
    if (app == null) return;
    const conn = c.g_application_get_dbus_connection(@ptrCast(app));
    if (conn == null) return;
    const dict_type = c.g_variant_type_new("a{sv}");
    defer c.g_variant_type_free(dict_type);
    var builder: c.GVariantBuilder = undefined;
    c.g_variant_builder_init(&builder, dict_type);
    c.g_variant_builder_add(&builder, "{sv}", "progress", c.g_variant_new_double(@as(f64, @floatFromInt(pct)) / 100.0));
    c.g_variant_builder_add(&builder, "{sv}", "progress-visible", c.g_variant_new_boolean(@intFromBool(visible)));
    c.g_variant_builder_add(&builder, "{sv}", "urgent", c.g_variant_new_boolean(@intFromBool(urgent)));
    _ = c.g_dbus_connection_emit_signal(
        conn,
        null,
        "/dev/sker/sketerm/launcherentry",
        "com.canonical.Unity.LauncherEntry",
        "Update",
        c.g_variant_new("(sa{sv})", "application://dev.sker.sketerm.desktop", &builder),
        null,
    );
}

pub fn tabColorOf(page: *c.AdwTabPage) ?[3]u8 {
    const v = @intFromPtr(c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-color"));
    if (v & (1 << 24) == 0) return null;
    return .{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
}

pub fn parseHexRGB(s: []const u8) ?[3]u8 {
    const hex = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (hex.len != 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    return .{ r, g, b };
}

/// "Tab Colour…" menu entry: GtkColorDialog on the selected tab.
/// Picking a fully-transparent colour (alpha ≈ 0) clears it.
pub fn chooseTabColor(self: *Window) void {
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
    const ctx = self.allocator.create(TabColorCtx) catch return;
    // Ref the page: the tab may be closed while the dialog is up.
    _ = c.g_object_ref(@as(?*anyopaque, @ptrCast(page)));
    ctx.* = .{ .allocator = self.allocator, .win = self, .page = page };
    const dialog = c.gtk_color_dialog_new();
    c.gtk_color_dialog_set_with_alpha(dialog, 1);
    const initial: c.GdkRGBA = if (tabColorOf(page)) |col| .{
        .red = @as(f32, @floatFromInt(col[0])) / 255.0,
        .green = @as(f32, @floatFromInt(col[1])) / 255.0,
        .blue = @as(f32, @floatFromInt(col[2])) / 255.0,
        .alpha = 1.0,
    } else .{ .red = 0.8, .green = 0.2, .blue = 0.2, .alpha = 1.0 };
    c.gtk_color_dialog_choose_rgba(dialog, @ptrCast(self.app_window), &initial, null, @ptrCast(&onTabColorChosen), @ptrCast(ctx));
}

pub fn onTabColorChosen(source: ?*c.GObject, res: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(TabColorCtx, user);
    const dialog: ?*c.GtkColorDialog = @ptrCast(@alignCast(source));
    const rgba = c.gtk_color_dialog_choose_rgba_finish(dialog, res, null);
    if (rgba != null) {
        // Only apply if the page is still alive in the view.
        if (pageStillOpen(ctx.win, ctx.page)) {
            if (rgba.*.alpha < 0.01) {
                ctx.win.setTabColor(ctx.page, null);
            } else {
                ctx.win.setTabColor(ctx.page, .{
                    @intFromFloat(std.math.clamp(rgba.*.red, 0.0, 1.0) * 255.0),
                    @intFromFloat(std.math.clamp(rgba.*.green, 0.0, 1.0) * 255.0),
                    @intFromFloat(std.math.clamp(rgba.*.blue, 0.0, 1.0) * 255.0),
                });
            }
        }
        c.gdk_rgba_free(rgba);
    }
    c.g_object_unref(dialog);
    c.g_object_unref(@as(?*anyopaque, @ptrCast(ctx.page)));
    ctx.allocator.destroy(ctx);
}

pub fn pageStillOpen(self: *Window, page: *c.AdwTabPage) bool {
    const n = c.adw_tab_view_get_n_pages(self.tab_view);
    var i: c_int = 0;
    while (i < n) : (i += 1) {
        if (c.adw_tab_view_get_nth_page(self.tab_view, i) == page) return true;
    }
    return false;
}

/// Open the rename popover on a double-click on the tab bar. The
/// single-click that AdwTabBar handles internally has already
/// selected the right tab, so renameCurrentTab targets it.
pub fn onTabBarPressed(_: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    if (n_press != 2) return;
    const self = cast.userData(Window, user);
    self.renameCurrentTabAt(.{ .x = x, .y = y });
}

/// Scroll on the tab bar → switch tabs (browser convention).
/// Vertical-scroll dy < 0 = up = previous, dy > 0 = down = next.
/// dx (horizontal scroll, common on touchpads) maps the same way:
/// left = previous, right = next. Touchpad smooth-scroll bursts are
/// summed into `tab_scroll_accum` so each ~1.0 of accumulated delta
/// triggers exactly one tab change.
pub fn onTabBarScroll(
    _: *c.GtkEventControllerScroll,
    dx: f64,
    dy: f64,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);
    const delta = if (dy != 0) dy else dx;
    if (delta == 0) return 0;
    self.tab_scroll_accum += delta;
    while (self.tab_scroll_accum >= 1.0) : (self.tab_scroll_accum -= 1.0) self.nextTab();
    while (self.tab_scroll_accum <= -1.0) : (self.tab_scroll_accum += 1.0) self.prevTab();
    return 1; // handled
}

pub fn onSelectedPageChanged(view: *c.AdwTabView, _: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    @import("webface.zig").tabsChanged();
    const page = c.adw_tab_view_get_selected_page(view);
    if (page == null) return;
    // Leaving a tab is NOT an acknowledgement (only dwelling on it is — see
    // onTabAckTimer). But the tab we just left becomes a background tab, so
    // any pending warning must now light up: reschedule the silence wake-up
    // and run the tick so an already-silent left tab paints immediately.
    const prev = self.selected_page_now;
    self.selected_page_now = page;
    if (prev) |pp| {
        if (pp != page) {
            self.tabbar.armWarn(pp);
            self.tabbar.ensureTick();
        }
    }
    // Clear any needs-attention from the now-active tab.
    c.adw_tab_page_set_needs_attention(page, 0);
    // A finished-command dot is acknowledged by viewing the tab; a
    // still-running dot stays.
    {
        const raw = c.g_object_get_data(@ptrCast(@alignCast(page)), "sketerm-tab-cmd");
        if (raw != null and (@intFromPtr(raw) & 0xff) != 1) self.setTabCmdStatus(page, 0);
    }
    // Viewing the tab also anchors its countdown (so it gets a fresh quiet
    // period after you leave) — but only after a short dwell so a quick
    // scroll across the tabs doesn't reset every tab's clock.
    self.scheduleTabAck(page.?);
    const child = c.adw_tab_page_get_child(page);
    if (child == null) return;

    // Restore the tab's last-focused pane. Validate the stored pointer is
    // still a live pane in THIS tab (guards against a closed pane whose
    // address was reused) before grabbing focus.
    if (Window.tabTreeOf(page.?)) |t| {
        if (t.last_focused) |lf| {
            for (self.panes.items) |p| {
                if (p == lf and winmod.widgetIsAncestor(@ptrCast(child), p.widget())) {
                    _ = c.gtk_widget_grab_focus(@ptrCast(p.surface.area));
                    return;
                }
            }
        }
    }

    // No (valid) last-focused pane — fall back to the first pane.
    for (self.panes.items) |p| {
        if (winmod.widgetIsAncestor(@ptrCast(child), p.widget())) {
            _ = c.gtk_widget_grab_focus(@ptrCast(p.surface.area));
            return;
        }
    }
}

/// The dwell timer elapsed: acknowledge the tab only if it is STILL the
/// selected one (the user stayed on it rather than scrolling past).
pub fn onTabAckTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Window, user);
    self.ack_timer_id = 0;
    const page = self.ack_timer_page orelse return 0;
    self.ack_timer_page = null;
    if (page == c.adw_tab_view_get_selected_page(self.tab_view)) {
        tab_effects.markAck(page);
        // Acknowledged → drop this tab's pending silence wake-up (warnDeadline
        // is now null for it) so the timer retargets the next-soonest tab.
        self.tabbar.armWarn(page);
    }
    return 0; // one-shot
}

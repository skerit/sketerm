//! Right-click context menu — a custom GtkPopover of icon+label
//! buttons. (GTK4's GtkPopoverMenu does NOT render per-item icons, so
//! the model approach can't show them; we build the rows ourselves.)
//!
//! Actions dispatch via a single sink callback. Names use the
//! "term" action prefix; widget gets a GSimpleActionGroup inserted,
//! and each button drives its action via action-name.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");

pub const Action = enum {
    copy,
    copy_screen,
    copy_scrollback,
    copy_output,
    paste,
    new_tab,
    new_tab_as_profile,
    duplicate_tab,
    close_tab,
    rename_tab,
    color_tab,
    pin_tab,
    split_h,
    split_v,
    zoom_pane,
    close_pane,
    set_pane_title,
    shader_pick,
    shader_clear,
    mux_detach,
    mux_rename,
    mux_kill,
    reset_terminal,
    copy_link,
    prefs_open,
};

pub const Sink = *const fn (ctx: ?*anyopaque, action: Action) void;

const ActionSlot = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    sink_ctx: ?*anyopaque,
    action: Action,
};

/// Optional pre-popup callback. Pane uses this to update the
/// "term.copy-link" action's enabled state (and stash the URI for
/// the activate handler) based on what's under the click. Return
/// false to suppress the menu entirely (right-click rebound to
/// paste) — the hook may perform its own action instead.
pub const PrePopupFn = *const fn (ctx: ?*anyopaque, group: *c.GSimpleActionGroup, x: f64, y: f64) bool;

const N_REMOTE_ROWS = blk: {
    var n: usize = 0;
    for (BINDS) |b| {
        if (b.remote_only) n += 1;
    }
    break :blk n;
};

const ClickCtx = struct {
    allocator: std.mem.Allocator,
    popover: *c.GtkWidget,
    group: *c.GSimpleActionGroup,
    pre_popup_fn: ?PrePopupFn = null,
    pre_popup_ctx: ?*anyopaque = null,
    /// Remote-only row buttons + their leading separator; shown only
    /// when the pre-popup hook enabled the mux actions. Children of
    /// the popover, so the pointers never outlive it.
    remote_widgets: [N_REMOTE_ROWS + 1]?*c.GtkWidget = @splat(null),
};

const Bind = struct {
    name: [*:0]const u8,
    label: [*:0]const u8,
    detailed: [*:0]const u8,
    /// Symbolic icon name (stock Adwaita, or a bundled sketerm-* icon).
    icon: [*:0]const u8,
    action: Action,
    /// Section index; a separator is drawn where it changes. BINDS is
    /// ordered for display (it doubles as the row list and the action
    /// source).
    section: u8,
    /// Row only makes sense on a mux-attached (remote) pane. These
    /// rows (and their section separator) are hidden when the
    /// pre-popup hook leaves their action disabled.
    remote_only: bool = false,
};

const BINDS = [_]Bind{
    .{ .name = "copy", .label = "Copy", .detailed = "term.copy", .icon = "edit-copy-symbolic", .action = .copy, .section = 0 },
    .{ .name = "copy-screen", .label = "Copy Screen", .detailed = "term.copy-screen", .icon = "edit-select-all-symbolic", .action = .copy_screen, .section = 0 },
    .{ .name = "copy-scrollback", .label = "Copy Scrollback", .detailed = "term.copy-scrollback", .icon = "edit-select-all-symbolic", .action = .copy_scrollback, .section = 0 },
    .{ .name = "copy-output", .label = "Copy Command Output", .detailed = "term.copy-output", .icon = "utilities-terminal-symbolic", .action = .copy_output, .section = 0 },
    .{ .name = "paste", .label = "Paste", .detailed = "term.paste", .icon = "edit-paste-symbolic", .action = .paste, .section = 0 },
    .{ .name = "copy-link", .label = "Copy Link", .detailed = "term.copy-link", .icon = "insert-link-symbolic", .action = .copy_link, .section = 0 },
    .{ .name = "split-h", .label = "Split Left / Right", .detailed = "term.split-h", .icon = "sketerm-split-left-right-symbolic", .action = .split_h, .section = 1 },
    .{ .name = "split-v", .label = "Split Top / Bottom", .detailed = "term.split-v", .icon = "sketerm-split-top-bottom-symbolic", .action = .split_v, .section = 1 },
    .{ .name = "zoom-pane", .label = "Zoom / Unzoom Pane", .detailed = "term.zoom-pane", .icon = "view-fullscreen-symbolic", .action = .zoom_pane, .section = 1 },
    .{ .name = "set-pane-title", .label = "Set Pane Title…", .detailed = "term.set-pane-title", .icon = "document-edit-symbolic", .action = .set_pane_title, .section = 1 },
    .{ .name = "shader-pick", .label = "Pane Shader…", .detailed = "term.shader-pick", .icon = "sketerm-rendering-symbolic", .action = .shader_pick, .section = 1 },
    .{ .name = "shader-clear", .label = "Clear Pane Shader", .detailed = "term.shader-clear", .icon = "edit-clear-symbolic", .action = .shader_clear, .section = 1 },
    .{ .name = "close-pane", .label = "Close Pane", .detailed = "term.close-pane", .icon = "window-close-symbolic", .action = .close_pane, .section = 1 },
    .{ .name = "mux-detach", .label = "Detach Session", .detailed = "term.mux-detach", .icon = "network-offline-symbolic", .action = .mux_detach, .section = 4, .remote_only = true },
    .{ .name = "mux-rename", .label = "Rename Session…", .detailed = "term.mux-rename", .icon = "document-edit-symbolic", .action = .mux_rename, .section = 4, .remote_only = true },
    .{ .name = "mux-kill", .label = "Kill Session", .detailed = "term.mux-kill", .icon = "process-stop-symbolic", .action = .mux_kill, .section = 4, .remote_only = true },
    .{ .name = "new-tab", .label = "New Tab", .detailed = "term.new-tab", .icon = "tab-new-symbolic", .action = .new_tab, .section = 2 },
    .{ .name = "new-tab-as-profile", .label = "New Tab as Profile…", .detailed = "term.new-tab-as-profile", .icon = "tab-new-symbolic", .action = .new_tab_as_profile, .section = 2 },
    .{ .name = "duplicate-tab", .label = "Duplicate Tab", .detailed = "term.duplicate-tab", .icon = "edit-copy-symbolic", .action = .duplicate_tab, .section = 2 },
    .{ .name = "rename-tab", .label = "Rename Tab…", .detailed = "term.rename-tab", .icon = "document-edit-symbolic", .action = .rename_tab, .section = 2 },
    .{ .name = "color-tab", .label = "Tab Colour…", .detailed = "term.color-tab", .icon = "color-select-symbolic", .action = .color_tab, .section = 2 },
    .{ .name = "pin-tab", .label = "Pin / Unpin Tab", .detailed = "term.pin-tab", .icon = "view-pin-symbolic", .action = .pin_tab, .section = 2 },
    .{ .name = "close-tab", .label = "Close Tab", .detailed = "term.close-tab", .icon = "window-close-symbolic", .action = .close_tab, .section = 2 },
    .{ .name = "reset", .label = "Reset Terminal", .detailed = "term.reset", .icon = "view-refresh-symbolic", .action = .reset_terminal, .section = 3 },
    .{ .name = "prefs", .label = "Preferences…", .detailed = "term.prefs", .icon = "preferences-system-symbolic", .action = .prefs_open, .section = 3 },
};

pub fn attach(
    widget: *c.GtkWidget,
    allocator: std.mem.Allocator,
    sink: Sink,
    sink_ctx: ?*anyopaque,
) !void {
    return attachWithPrePopup(widget, allocator, sink, sink_ctx, null, null);
}

pub fn attachWithPrePopup(
    widget: *c.GtkWidget,
    allocator: std.mem.Allocator,
    sink: Sink,
    sink_ctx: ?*anyopaque,
    pre_popup_fn: ?PrePopupFn,
    pre_popup_ctx: ?*anyopaque,
) !void {
    // Action group: one GSimpleAction per bind. Buttons below trigger
    // these by action-name.
    const group = c.g_simple_action_group_new();
    for (BINDS) |b| {
        const slot = try allocator.create(ActionSlot);
        slot.* = .{ .allocator = allocator, .sink = sink, .sink_ctx = sink_ctx, .action = b.action };
        const act = c.g_simple_action_new(b.name, null);
        _ = c.g_signal_connect_data(
            act,
            "activate",
            @ptrCast(&onActivate),
            @ptrCast(slot),
            @ptrCast(&freeActionSlot),
            c.G_CONNECT_DEFAULT,
        );
        c.g_action_map_add_action(@ptrCast(group), @ptrCast(act));
        c.g_object_unref(act);
    }
    c.gtk_widget_insert_action_group(widget, "term", @ptrCast(group));
    c.g_object_unref(group);

    // Default the copy-link action to disabled so its button stays grey
    // when no link is under the cursor; pre_popup_fn flips it true when
    // there is one. Buttons bound by action-name track this live.
    if (c.g_action_map_lookup_action(@ptrCast(group), "copy-link")) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), 0);
    }
    // Mux rows default hidden; the pane's pre-popup hook enables them
    // when its terminal is a remote (mux) attachment.
    for ([_][*:0]const u8{ "mux-detach", "mux-rename", "mux-kill" }) |name| {
        if (c.g_action_map_lookup_action(@ptrCast(group), name)) |act| {
            c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), 0);
        }
    }

    // Popover: a custom GtkPopover holding a column of icon+label
    // buttons. We build the rows by hand because GtkPopoverMenu won't
    // render per-item icons. Each button activates its "term.*" action
    // (resolved through the group inserted above) and pops down on click.
    const popover = c.gtk_popover_new();
    c.gtk_widget_set_parent(popover, widget);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);

    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    var remote_widgets: [N_REMOTE_ROWS + 1]?*c.GtkWidget = @splat(null);
    var n_remote: usize = 0;
    var first = true;
    var prev_section: u8 = 0;
    for (BINDS) |b| {
        if (!first and b.section != prev_section) {
            const sep = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
            c.gtk_box_append(@ptrCast(list), sep);
            // The separator leading INTO the remote section hides
            // together with its rows.
            if (b.remote_only) {
                remote_widgets[n_remote] = sep;
                n_remote += 1;
            }
        }
        first = false;
        prev_section = b.section;

        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        const img = c.gtk_image_new_from_icon_name(b.icon);
        const lbl = c.gtk_label_new(b.label);
        c.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
        c.gtk_widget_set_hexpand(lbl, 1);
        c.gtk_box_append(@ptrCast(row), img);
        c.gtk_box_append(@ptrCast(row), lbl);

        const btn = c.gtk_button_new();
        c.gtk_button_set_child(@ptrCast(btn), row);
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_actionable_set_action_name(@ptrCast(btn), b.detailed);
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onItemClicked), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(list), btn);
        if (b.remote_only) {
            remote_widgets[n_remote] = btn;
            n_remote += 1;
        }
    }
    c.gtk_popover_set_child(@ptrCast(popover), list);

    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 3);
    const cctx = try allocator.create(ClickCtx);
    cctx.* = .{
        .allocator = allocator,
        .popover = popover,
        .group = @ptrCast(group),
        .pre_popup_fn = pre_popup_fn,
        .pre_popup_ctx = pre_popup_ctx,
        .remote_widgets = remote_widgets,
    };
    _ = c.g_signal_connect_data(
        click,
        "pressed",
        @ptrCast(&onRightClick),
        @ptrCast(cctx),
        @ptrCast(&freeClickCtx),
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(widget, @ptrCast(click));
}

fn onActivate(_: *c.GSimpleAction, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const slot = cast.userData(ActionSlot, user);
    slot.sink(slot.sink_ctx, slot.action);
}

/// Dismiss the popover after a row is clicked. The button's action-name
/// fires the "term.*" action as part of the same click; this just makes
/// the menu close like a menu. `user` is the popover widget (a child of
/// it, so it never outlives it — no destroy-notify needed).
fn onItemClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const pop: *c.GtkWidget = @ptrCast(@alignCast(u));
        c.gtk_popover_popdown(@ptrCast(pop));
    }
}

fn freeActionSlot(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const slot: *ActionSlot = @ptrCast(@alignCast(u));
        slot.allocator.destroy(slot);
    }
}

fn freeClickCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *ClickCtx = @ptrCast(@alignCast(u));
        // Pop popovers added via gtk_widget_set_parent must be
        // explicitly unparented before the host widget finalizes,
        // otherwise GTK warns "Finalizing GtkGLArea, but it still
        // has children left". This destroy-notify fires when the
        // click controller is removed from the widget — i.e. on
        // widget destruction — making it the right hook.
        if (c.gtk_widget_get_parent(ctx.popover) != null) {
            c.gtk_widget_unparent(ctx.popover);
        }
        ctx.allocator.destroy(ctx);
    }
}

fn onRightClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ClickCtx, user);
    if (ctx.pre_popup_fn) |f| {
        if (!f(ctx.pre_popup_ctx, ctx.group, x, y)) return;
    }
    // Remote-only rows: visible iff the pre-popup hook enabled the
    // mux actions (i.e. the pane renders a mux session). All three
    // share one fate, so probing "mux-detach" decides for the lot.
    var show_remote = false;
    if (c.g_action_map_lookup_action(@ptrCast(ctx.group), "mux-detach")) |act| {
        show_remote = c.g_action_get_enabled(@ptrCast(act)) != 0;
    }
    for (ctx.remote_widgets) |maybe_w| {
        if (maybe_w) |w| c.gtk_widget_set_visible(w, @intFromBool(show_remote));
    }
    var rect = c.GdkRectangle{
        .x = @intFromFloat(x),
        .y = @intFromFloat(y),
        .width = 1,
        .height = 1,
    };
    c.gtk_popover_set_pointing_to(@ptrCast(ctx.popover), &rect);
    c.gtk_popover_popup(@ptrCast(ctx.popover));
}

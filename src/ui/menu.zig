//! Right-click context menu — GtkPopoverMenu over GMenu model.
//!
//! Actions dispatch via a single sink callback. Names use the
//! "term" action prefix; widget gets a GSimpleActionGroup inserted.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");

pub const Action = enum {
    copy,
    copy_screen,
    copy_scrollback,
    paste,
    new_tab,
    new_tab_as_profile,
    duplicate_tab,
    close_tab,
    rename_tab,
    pin_tab,
    split_h,
    split_v,
    close_pane,
    set_pane_title,
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
/// the activate handler) based on what's under the click.
pub const PrePopupFn = *const fn (ctx: ?*anyopaque, group: *c.GSimpleActionGroup, x: f64, y: f64) void;

const ClickCtx = struct {
    allocator: std.mem.Allocator,
    popover: *c.GtkWidget,
    group: *c.GSimpleActionGroup,
    pre_popup_fn: ?PrePopupFn = null,
    pre_popup_ctx: ?*anyopaque = null,
};

const Bind = struct {
    name: [*:0]const u8,
    label: [*:0]const u8,
    detailed: [*:0]const u8,
    action: Action,
};

const BINDS = [_]Bind{
    .{ .name = "copy", .label = "Copy", .detailed = "term.copy", .action = .copy },
    .{ .name = "copy-screen", .label = "Copy Screen", .detailed = "term.copy-screen", .action = .copy_screen },
    .{ .name = "copy-scrollback", .label = "Copy Scrollback", .detailed = "term.copy-scrollback", .action = .copy_scrollback },
    .{ .name = "paste", .label = "Paste", .detailed = "term.paste", .action = .paste },
    .{ .name = "copy-link", .label = "Copy Link", .detailed = "term.copy-link", .action = .copy_link },
    .{ .name = "split-h", .label = "Split Horizontal", .detailed = "term.split-h", .action = .split_h },
    .{ .name = "split-v", .label = "Split Vertical", .detailed = "term.split-v", .action = .split_v },
    .{ .name = "close-pane", .label = "Close Pane", .detailed = "term.close-pane", .action = .close_pane },
    .{ .name = "set-pane-title", .label = "Set Pane Title…", .detailed = "term.set-pane-title", .action = .set_pane_title },
    .{ .name = "new-tab", .label = "New Tab", .detailed = "term.new-tab", .action = .new_tab },
    .{ .name = "new-tab-as-profile", .label = "New Tab as Profile…", .detailed = "term.new-tab-as-profile", .action = .new_tab_as_profile },
    .{ .name = "duplicate-tab", .label = "Duplicate Tab", .detailed = "term.duplicate-tab", .action = .duplicate_tab },
    .{ .name = "rename-tab", .label = "Rename Tab…", .detailed = "term.rename-tab", .action = .rename_tab },
    .{ .name = "pin-tab", .label = "Pin / Unpin Tab", .detailed = "term.pin-tab", .action = .pin_tab },
    .{ .name = "close-tab", .label = "Close Tab", .detailed = "term.close-tab", .action = .close_tab },
    .{ .name = "reset", .label = "Reset Terminal", .detailed = "term.reset", .action = .reset_terminal },
    .{ .name = "prefs", .label = "Preferences…", .detailed = "term.prefs", .action = .prefs_open },
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
    // Menu model.
    const menu = c.g_menu_new();
    const sec1 = c.g_menu_new();
    c.g_menu_append(sec1, "Copy", "term.copy");
    c.g_menu_append(sec1, "Copy Screen", "term.copy-screen");
    c.g_menu_append(sec1, "Copy Scrollback", "term.copy-scrollback");
    c.g_menu_append(sec1, "Paste", "term.paste");
    c.g_menu_append(sec1, "Copy Link", "term.copy-link");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(sec1)));
    c.g_object_unref(sec1);

    const sec2 = c.g_menu_new();
    c.g_menu_append(sec2, "Split Horizontal", "term.split-h");
    c.g_menu_append(sec2, "Split Vertical", "term.split-v");
    c.g_menu_append(sec2, "Set Pane Title…", "term.set-pane-title");
    c.g_menu_append(sec2, "Close Pane", "term.close-pane");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(sec2)));
    c.g_object_unref(sec2);

    const sec3 = c.g_menu_new();
    c.g_menu_append(sec3, "New Tab", "term.new-tab");
    c.g_menu_append(sec3, "New Tab as Profile…", "term.new-tab-as-profile");
    c.g_menu_append(sec3, "Duplicate Tab", "term.duplicate-tab");
    c.g_menu_append(sec3, "Rename Tab…", "term.rename-tab");
    c.g_menu_append(sec3, "Pin / Unpin Tab", "term.pin-tab");
    c.g_menu_append(sec3, "Close Tab", "term.close-tab");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(sec3)));
    c.g_object_unref(sec3);

    const sec4 = c.g_menu_new();
    c.g_menu_append(sec4, "Reset Terminal", "term.reset");
    c.g_menu_append(sec4, "Preferences…", "term.prefs");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(sec4)));
    c.g_object_unref(sec4);

    // Action group.
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

    // Popover.
    const popover = c.gtk_popover_menu_new_from_model(@ptrCast(@alignCast(menu)));
    c.gtk_widget_set_parent(popover, widget);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);
    c.g_object_unref(menu);

    // Right-click gesture → popup at cursor. Default the copy-link
    // action to disabled so it stays grey when no link is under the
    // cursor; pre_popup_fn flips it true when there is one.
    if (c.g_action_map_lookup_action(@ptrCast(group), "copy-link")) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), 0);
    }

    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 3);
    const cctx = try allocator.create(ClickCtx);
    cctx.* = .{
        .allocator = allocator,
        .popover = popover,
        .group = @ptrCast(group),
        .pre_popup_fn = pre_popup_fn,
        .pre_popup_ctx = pre_popup_ctx,
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

fn freeActionSlot(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const slot: *ActionSlot = @ptrCast(@alignCast(u));
        slot.allocator.destroy(slot);
    }
}

fn freeClickCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *ClickCtx = @ptrCast(@alignCast(u));
        ctx.allocator.destroy(ctx);
    }
}

fn onRightClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ClickCtx, user);
    if (ctx.pre_popup_fn) |f| f(ctx.pre_popup_ctx, ctx.group, x, y);
    var rect = c.GdkRectangle{
        .x = @intFromFloat(x),
        .y = @intFromFloat(y),
        .width = 1,
        .height = 1,
    };
    c.gtk_popover_set_pointing_to(@ptrCast(ctx.popover), &rect);
    c.gtk_popover_popup(@ptrCast(ctx.popover));
}

//! Right-click context menu — GtkPopoverMenu over GMenu model.
//!
//! Actions dispatch via a single sink callback. Names use the
//! "term" action prefix; widget gets a GSimpleActionGroup inserted.

const std = @import("std");
const c = @import("../c.zig").c;

pub const Action = enum {
    copy,
    paste,
    new_tab,
    close_tab,
    rename_tab,
    split_h,
    split_v,
    close_pane,
    reset_terminal,
};

pub const Sink = *const fn (ctx: ?*anyopaque, action: Action) void;

const ActionSlot = struct {
    sink: Sink,
    sink_ctx: ?*anyopaque,
    action: Action,
};

const ClickCtx = struct {
    popover: *c.GtkWidget,
};

const Bind = struct {
    name: [*:0]const u8,
    label: [*:0]const u8,
    detailed: [*:0]const u8,
    action: Action,
};

const BINDS = [_]Bind{
    .{ .name = "copy", .label = "Copy", .detailed = "term.copy", .action = .copy },
    .{ .name = "paste", .label = "Paste", .detailed = "term.paste", .action = .paste },
    .{ .name = "split-h", .label = "Split Horizontal", .detailed = "term.split-h", .action = .split_h },
    .{ .name = "split-v", .label = "Split Vertical", .detailed = "term.split-v", .action = .split_v },
    .{ .name = "close-pane", .label = "Close Pane", .detailed = "term.close-pane", .action = .close_pane },
    .{ .name = "new-tab", .label = "New Tab", .detailed = "term.new-tab", .action = .new_tab },
    .{ .name = "rename-tab", .label = "Rename Tab…", .detailed = "term.rename-tab", .action = .rename_tab },
    .{ .name = "close-tab", .label = "Close Tab", .detailed = "term.close-tab", .action = .close_tab },
    .{ .name = "reset", .label = "Reset Terminal", .detailed = "term.reset", .action = .reset_terminal },
};

pub fn attach(
    widget: *c.GtkWidget,
    allocator: std.mem.Allocator,
    sink: Sink,
    sink_ctx: ?*anyopaque,
) !void {
    // Menu model.
    const menu = c.g_menu_new();
    const sec1 = c.g_menu_new();
    c.g_menu_append(sec1, "Copy", "term.copy");
    c.g_menu_append(sec1, "Paste", "term.paste");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(sec1)));
    c.g_object_unref(sec1);

    const sec2 = c.g_menu_new();
    c.g_menu_append(sec2, "Split Horizontal", "term.split-h");
    c.g_menu_append(sec2, "Split Vertical", "term.split-v");
    c.g_menu_append(sec2, "Close Pane", "term.close-pane");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(sec2)));
    c.g_object_unref(sec2);

    const sec3 = c.g_menu_new();
    c.g_menu_append(sec3, "New Tab", "term.new-tab");
    c.g_menu_append(sec3, "Rename Tab…", "term.rename-tab");
    c.g_menu_append(sec3, "Close Tab", "term.close-tab");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(sec3)));
    c.g_object_unref(sec3);

    const sec4 = c.g_menu_new();
    c.g_menu_append(sec4, "Reset Terminal", "term.reset");
    c.g_menu_append_section(menu, null, @ptrCast(@alignCast(sec4)));
    c.g_object_unref(sec4);

    // Action group.
    const group = c.g_simple_action_group_new();
    for (BINDS) |b| {
        const slot = try allocator.create(ActionSlot);
        slot.* = .{ .sink = sink, .sink_ctx = sink_ctx, .action = b.action };
        const act = c.g_simple_action_new(b.name, null);
        _ = c.g_signal_connect_data(
            act,
            "activate",
            @ptrCast(&onActivate),
            @ptrCast(slot),
            null,
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

    // Right-click gesture → popup at cursor.
    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 3);
    const cctx = try allocator.create(ClickCtx);
    cctx.* = .{ .popover = popover };
    _ = c.g_signal_connect_data(
        click,
        "pressed",
        @ptrCast(&onRightClick),
        @ptrCast(cctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(widget, @ptrCast(click));
}

fn onActivate(_: *c.GSimpleAction, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const slot: *ActionSlot = @ptrCast(@alignCast(user.?));
    slot.sink(slot.sink_ctx, slot.action);
}

fn onRightClick(_: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx: *ClickCtx = @ptrCast(@alignCast(user.?));
    var rect = c.GdkRectangle{
        .x = @intFromFloat(x),
        .y = @intFromFloat(y),
        .width = 1,
        .height = 1,
    };
    c.gtk_popover_set_pointing_to(@ptrCast(ctx.popover), &rect);
    c.gtk_popover_popup(@ptrCast(ctx.popover));
}

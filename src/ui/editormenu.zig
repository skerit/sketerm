//! Right-click context menu for the editor canvas — the same custom
//! GtkPopover idiom as `ui/menu.zig` (GtkPopoverMenu cannot render
//! per-item icons, so rows are built by hand; every heap signal
//! context carries its allocator and a matching destroy-notify).
//!
//! Behaviour lives in `EditorView.menuAction`; state (which rows can
//! act) is decided per popup by `EditorView.menuPrePopup`, which also
//! moves the caret when the click lands outside every selection. LSP
//! rows hide entirely when no server is attached to the document —
//! present-but-dead menu items are worse than absent ones.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const EditorView = @import("editorview.zig").EditorView;

pub const Action = enum {
    cut,
    copy,
    paste,
    select_all,
    toggle_comment,
    duplicate,
    move_up,
    move_down,
    join,
    sort,
    indent,
    dedent,
    trim_ws,
    case_upper,
    case_lower,
    case_title,
    goto_def,
    references,
    rename,
    format,
    code_actions,
    fold,
    unfold,
    fold_all,
    unfold_all,
    find,
    replace,
    goto_line,
};

const ActionSlot = struct {
    allocator: std.mem.Allocator,
    view: *EditorView,
    action: Action,
};

const Bind = struct {
    name: [*:0]const u8,
    label: [*:0]const u8,
    detailed: [*:0]const u8,
    icon: [*:0]const u8,
    action: Action,
    /// Row only makes sense with a language server attached to the
    /// active document; hidden (with its leading separator) otherwise.
    lsp_only: bool = false,
};

const Submenu = struct {
    label: [*:0]const u8,
    icon: [*:0]const u8,
    items: []const Bind,
};

const Item = union(enum) {
    bind: Bind,
    submenu: Submenu,
    separator,
};

const MENU = [_]Item{
    .{ .bind = .{ .name = "cut", .label = "Cut", .detailed = "edmenu.cut", .icon = "edit-cut-symbolic", .action = .cut } },
    .{ .bind = .{ .name = "copy", .label = "Copy", .detailed = "edmenu.copy", .icon = "edit-copy-symbolic", .action = .copy } },
    .{ .bind = .{ .name = "paste", .label = "Paste", .detailed = "edmenu.paste", .icon = "edit-paste-symbolic", .action = .paste } },
    .{ .bind = .{ .name = "select-all", .label = "Select All", .detailed = "edmenu.select-all", .icon = "edit-select-all-symbolic", .action = .select_all } },
    .separator,
    .{ .bind = .{ .name = "toggle-comment", .label = "Toggle Line Comment", .detailed = "edmenu.toggle-comment", .icon = "format-indent-more-symbolic", .action = .toggle_comment } },
    .{ .submenu = .{ .label = "Line", .icon = "view-list-symbolic", .items = &.{
        .{ .name = "duplicate", .label = "Duplicate Down", .detailed = "edmenu.duplicate", .icon = "edit-copy-symbolic", .action = .duplicate },
        .{ .name = "move-up", .label = "Move Up", .detailed = "edmenu.move-up", .icon = "go-up-symbolic", .action = .move_up },
        .{ .name = "move-down", .label = "Move Down", .detailed = "edmenu.move-down", .icon = "go-down-symbolic", .action = .move_down },
        .{ .name = "join", .label = "Join Lines", .detailed = "edmenu.join", .icon = "format-justify-fill-symbolic", .action = .join },
        .{ .name = "sort", .label = "Sort Lines", .detailed = "edmenu.sort", .icon = "view-sort-ascending-symbolic", .action = .sort },
        .{ .name = "indent", .label = "Indent", .detailed = "edmenu.indent", .icon = "format-indent-more-symbolic", .action = .indent },
        .{ .name = "dedent", .label = "Dedent", .detailed = "edmenu.dedent", .icon = "format-indent-less-symbolic", .action = .dedent },
        .{ .name = "trim-ws", .label = "Trim Trailing Whitespace", .detailed = "edmenu.trim-ws", .icon = "edit-clear-symbolic", .action = .trim_ws },
    } } },
    .{ .submenu = .{ .label = "Change Case", .icon = "format-text-rich-symbolic", .items = &.{
        .{ .name = "case-upper", .label = "UPPERCASE", .detailed = "edmenu.case-upper", .icon = "format-text-rich-symbolic", .action = .case_upper },
        .{ .name = "case-lower", .label = "lowercase", .detailed = "edmenu.case-lower", .icon = "format-text-rich-symbolic", .action = .case_lower },
        .{ .name = "case-title", .label = "Title Case", .detailed = "edmenu.case-title", .icon = "format-text-rich-symbolic", .action = .case_title },
    } } },
    .separator,
    .{ .bind = .{ .name = "goto-def", .label = "Go to Definition", .detailed = "edmenu.goto-def", .icon = "go-jump-symbolic", .action = .goto_def, .lsp_only = true } },
    .{ .bind = .{ .name = "references", .label = "Find References", .detailed = "edmenu.references", .icon = "edit-find-symbolic", .action = .references, .lsp_only = true } },
    .{ .bind = .{ .name = "rename", .label = "Rename Symbol…", .detailed = "edmenu.rename", .icon = "document-edit-symbolic", .action = .rename, .lsp_only = true } },
    .{ .bind = .{ .name = "format", .label = "Format Document", .detailed = "edmenu.format", .icon = "format-justify-left-symbolic", .action = .format, .lsp_only = true } },
    .{ .bind = .{ .name = "code-actions", .label = "Code Actions…", .detailed = "edmenu.code-actions", .icon = "dialog-information-symbolic", .action = .code_actions, .lsp_only = true } },
    .separator,
    .{ .submenu = .{ .label = "Folding", .icon = "view-restore-symbolic", .items = &.{
        .{ .name = "fold", .label = "Fold Region", .detailed = "edmenu.fold", .icon = "list-remove-symbolic", .action = .fold },
        .{ .name = "unfold", .label = "Unfold Region", .detailed = "edmenu.unfold", .icon = "list-add-symbolic", .action = .unfold },
        .{ .name = "fold-all", .label = "Fold All", .detailed = "edmenu.fold-all", .icon = "view-restore-symbolic", .action = .fold_all },
        .{ .name = "unfold-all", .label = "Unfold All", .detailed = "edmenu.unfold-all", .icon = "view-fullscreen-symbolic", .action = .unfold_all },
    } } },
    .separator,
    .{ .bind = .{ .name = "find", .label = "Find…", .detailed = "edmenu.find", .icon = "edit-find-symbolic", .action = .find } },
    .{ .bind = .{ .name = "replace", .label = "Replace…", .detailed = "edmenu.replace", .icon = "edit-find-replace-symbolic", .action = .replace } },
    .{ .bind = .{ .name = "goto-line", .label = "Go to Line…", .detailed = "edmenu.goto-line", .icon = "go-jump-symbolic", .action = .goto_line } },
};

const BINDS = blk: {
    var n: usize = 0;
    for (MENU) |it| switch (it) {
        .bind => n += 1,
        .submenu => |s| n += s.items.len,
        .separator => {},
    };
    var arr: [n]Bind = undefined;
    var i: usize = 0;
    for (MENU) |it| switch (it) {
        .bind => |b| {
            arr[i] = b;
            i += 1;
        },
        .submenu => |s| for (s.items) |b| {
            arr[i] = b;
            i += 1;
        },
        .separator => {},
    };
    break :blk arr;
};

const N_SUBMENUS = blk: {
    var n: usize = 0;
    for (MENU) |it| {
        if (it == .submenu) n += 1;
    }
    break :blk n;
};

/// LSP rows plus the separator that leads into them.
const N_LSP_WIDGETS = blk: {
    var n: usize = 0;
    for (MENU) |it| {
        if (it == .bind and it.bind.lsp_only) n += 1;
    }
    break :blk n + 1;
};

const ClickCtx = struct {
    allocator: std.mem.Allocator,
    view: *EditorView,
    popover: *c.GtkWidget,
    group: *c.GSimpleActionGroup,
    subs: [N_SUBMENUS]?*c.GtkWidget = @splat(null),
    lsp_widgets: [N_LSP_WIDGETS]?*c.GtkWidget = @splat(null),
};

const HoverCtx = struct {
    allocator: std.mem.Allocator,
    cctx: *ClickCtx,
    sub: ?*c.GtkWidget,
};

/// Attach the context menu to the editor canvas. `widget` is the GL
/// area; teardown rides the click gesture's destroy-notify, which
/// unparents the popovers before the area finalizes.
pub fn attach(view: *EditorView, widget: *c.GtkWidget, allocator: std.mem.Allocator) !void {
    const group = c.g_simple_action_group_new();
    for (BINDS) |b| {
        const slot = try allocator.create(ActionSlot);
        slot.* = .{ .allocator = allocator, .view = view, .action = b.action };
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
    c.gtk_widget_insert_action_group(widget, "edmenu", @ptrCast(group));
    c.g_object_unref(group);

    const popover = c.gtk_popover_new();
    c.gtk_widget_set_parent(popover, widget);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);

    const cctx = try allocator.create(ClickCtx);
    cctx.* = .{
        .allocator = allocator,
        .view = view,
        .popover = popover,
        .group = @ptrCast(group),
    };
    errdefer allocator.destroy(cctx);

    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    var n_sub: usize = 0;
    var n_lsp: usize = 0;
    var prev_sep: ?*c.GtkWidget = null;
    var lsp_sep_taken = false;
    for (MENU) |item| {
        switch (item) {
            .separator => {
                const sep = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
                c.gtk_box_append(@ptrCast(list), sep);
                prev_sep = sep;
            },
            .bind => |b| {
                const btn = makeRow(b.icon, b.label, false);
                c.gtk_actionable_set_action_name(@ptrCast(btn), b.detailed);
                _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onItemClicked), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
                c.gtk_box_append(@ptrCast(list), btn);
                if (b.lsp_only) {
                    if (!lsp_sep_taken) {
                        if (prev_sep) |sep| {
                            cctx.lsp_widgets[n_lsp] = sep;
                            n_lsp += 1;
                        }
                        lsp_sep_taken = true;
                    }
                    cctx.lsp_widgets[n_lsp] = btn;
                    n_lsp += 1;
                }
                try addHover(allocator, btn, cctx, null);
                if (!b.lsp_only) prev_sep = null;
            },
            .submenu => |s| {
                const btn = makeRow(s.icon, s.label, true);
                const sub_pop = c.gtk_popover_new();
                c.gtk_widget_set_parent(sub_pop, btn);
                c.gtk_popover_set_has_arrow(@ptrCast(sub_pop), 0);
                c.gtk_popover_set_autohide(@ptrCast(sub_pop), 0);
                c.gtk_popover_set_position(@ptrCast(sub_pop), c.GTK_POS_RIGHT);
                const sub_list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
                for (s.items) |b| {
                    const child = makeRow(b.icon, b.label, false);
                    c.gtk_actionable_set_action_name(@ptrCast(child), b.detailed);
                    _ = c.g_signal_connect_data(child, "clicked", @ptrCast(&onItemClicked), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
                    c.gtk_box_append(@ptrCast(sub_list), child);
                }
                c.gtk_popover_set_child(@ptrCast(sub_pop), sub_list);
                _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onSubParentClicked), @ptrCast(sub_pop), null, c.G_CONNECT_DEFAULT);
                c.gtk_box_append(@ptrCast(list), btn);
                cctx.subs[n_sub] = sub_pop;
                n_sub += 1;
                try addHover(allocator, btn, cctx, sub_pop);
                prev_sep = null;
            },
        }
    }
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onPopoverClosed), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
    // Scroller for the same popover-minimum-size reason ui/menu.zig
    // documents: a bare box's minimum height can exceed what the
    // compositor grants and GTK then popdowns the menu on map.
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), list);
    c.gtk_popover_set_child(@ptrCast(popover), scroller);

    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 3);
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

fn makeRow(icon: [*:0]const u8, label: [*:0]const u8, arrow: bool) *c.GtkWidget {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    const img = c.gtk_image_new_from_icon_name(icon);
    const lbl = c.gtk_label_new(label);
    c.gtk_label_set_xalign(@ptrCast(lbl), 0.0);
    c.gtk_widget_set_hexpand(lbl, 1);
    c.gtk_box_append(@ptrCast(row), img);
    c.gtk_box_append(@ptrCast(row), lbl);
    if (arrow) {
        c.gtk_box_append(@ptrCast(row), c.gtk_image_new_from_icon_name("pan-end-symbolic"));
    }
    const btn = c.gtk_button_new();
    c.gtk_button_set_child(@ptrCast(btn), row);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    return btn.?;
}

fn addHover(allocator: std.mem.Allocator, btn: *c.GtkWidget, cctx: *ClickCtx, sub: ?*c.GtkWidget) !void {
    const hctx = try allocator.create(HoverCtx);
    hctx.* = .{ .allocator = allocator, .cctx = cctx, .sub = sub };
    const motion = c.gtk_event_controller_motion_new();
    _ = c.g_signal_connect_data(
        motion,
        "enter",
        @ptrCast(&onRowEnter),
        @ptrCast(hctx),
        @ptrCast(&freeHoverCtx),
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(btn, motion);
}

fn onRowEnter(_: *c.GtkEventControllerMotion, _: f64, _: f64, user: ?*anyopaque) callconv(.c) void {
    const hctx = cast.userData(HoverCtx, user);
    for (hctx.cctx.subs) |maybe_sub| {
        const sub = maybe_sub orelse continue;
        if (hctx.sub == sub) continue;
        if (c.gtk_widget_get_visible(sub) != 0) c.gtk_popover_popdown(@ptrCast(sub));
    }
    if (hctx.sub) |sub| {
        if (c.gtk_widget_get_visible(sub) == 0) c.gtk_popover_popup(@ptrCast(sub));
    }
}

fn onSubParentClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const sub: *c.GtkWidget = @ptrCast(@alignCast(u));
        if (c.gtk_widget_get_visible(sub) == 0) c.gtk_popover_popup(@ptrCast(sub));
    }
}

fn onPopoverClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ClickCtx, user);
    for (ctx.subs) |maybe_sub| {
        const sub = maybe_sub orelse continue;
        if (c.gtk_widget_get_visible(sub) != 0) c.gtk_popover_popdown(@ptrCast(sub));
    }
}

fn freeHoverCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const hctx: *HoverCtx = @ptrCast(@alignCast(u));
        hctx.allocator.destroy(hctx);
    }
}

fn onActivate(_: *c.GSimpleAction, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const slot = cast.userData(ActionSlot, user);
    slot.view.menuAction(slot.action);
}

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
        // Parented popovers must be unparented before the GL area
        // finalizes (same rule as ui/menu.zig); this notify fires when
        // the click controller is dropped, i.e. at widget destruction.
        for (ctx.subs) |maybe_sub| {
            const sub = maybe_sub orelse continue;
            if (c.gtk_widget_get_parent(sub) != null) {
                c.gtk_widget_unparent(sub);
            }
        }
        if (c.gtk_widget_get_parent(ctx.popover) != null) {
            c.gtk_widget_unparent(ctx.popover);
        }
        ctx.allocator.destroy(ctx);
    }
}

fn setGroupVisible(group: *c.GSimpleActionGroup, action: [*:0]const u8, widgets: []const ?*c.GtkWidget) void {
    var show = false;
    if (c.g_action_map_lookup_action(@ptrCast(group), action)) |act| {
        show = c.g_action_get_enabled(@ptrCast(act)) != 0;
    }
    for (widgets) |maybe_w| {
        if (maybe_w) |w| c.gtk_widget_set_visible(w, @intFromBool(show));
    }
}

fn onRightClick(g: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ClickCtx, user);
    if (!ctx.view.menuPrePopup(ctx.group, x, y)) return;
    // Claim before popup: without it the release event dismisses the
    // popover the frame it maps (ui/menu.zig documents the race).
    _ = c.gtk_gesture_set_state(@ptrCast(@alignCast(g)), c.GTK_EVENT_SEQUENCE_CLAIMED);
    setGroupVisible(ctx.group, "goto-def", &ctx.lsp_widgets);
    for (ctx.subs) |maybe_sub| {
        const sub = maybe_sub orelse continue;
        if (c.gtk_widget_get_visible(sub) != 0) c.gtk_popover_popdown(@ptrCast(sub));
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

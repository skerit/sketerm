//! Right-click context menu — a custom GtkPopover of icon+label
//! buttons. (GTK4's GtkPopoverMenu does NOT render per-item icons, so
//! the model approach can't show them; we build the rows ourselves.)
//!
//! Every row is an `action.zig` verb, dispatched through a single sink
//! callback. The widget gets a "term" GSimpleActionGroup whose action
//! names derive from the verbs' tags, and each button drives its action
//! via action-name.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const menuchrome = @import("menuchrome.zig");

const Action = @import("action.zig").Action;

pub const Sink = *const fn (ctx: ?*anyopaque, action: Action) void;

const ActionSlot = struct {
    allocator: std.mem.Allocator,
    sink: Sink,
    sink_ctx: ?*anyopaque,
    action: Action,
};

/// Optional pre-popup callback. Pane uses this to update the
/// `copy_link` row's enabled state (and stash the URI for the
/// activate handler) based on what's under the click. Return false to
/// suppress the menu entirely (right-click rebound to paste); the
/// hook may perform its own action instead.
pub const PrePopupFn = *const fn (ctx: ?*anyopaque, group: *c.GSimpleActionGroup, x: f64, y: f64) bool;

const Bind = struct {
    label: [*:0]const u8,
    /// Symbolic icon name (stock Adwaita, or a bundled sketerm-* icon).
    icon: [*:0]const u8,
    action: Action,
    /// Row only makes sense when the right-click landed on a
    /// hyperlink / detected URL. These rows (and their section
    /// separator) hide when the pre-popup hook leaves `copy_link`
    /// disabled.
    link_only: bool = false,
    /// Row only makes sense on a session whose PTY lives on another
    /// machine (SSH / UDP host); file transfer to a local session
    /// is pointless. Hidden when the pre-popup hook leaves
    /// `upload_file` disabled.
    host_only: bool = false,
    /// Recording-state pair: 1 = "start recording" row (hidden while
    /// the session records), 2 = "stop" row (shown only while it
    /// does). The pre-popup hook drives the actions' enabled state.
    rec_row: u8 = 0,
    /// Row only makes sense while the pane carries a HIDDEN web face
    /// (the only state with no other way back to the browser). Hidden
    /// (with its trailing separator) when the pre-popup hook leaves
    /// `toggle_web_face` disabled.
    web_only: bool = false,
};

const Submenu = struct {
    label: [*:0]const u8,
    icon: [*:0]const u8,
    items: []const Bind,
    /// Submenu only makes sense on a durable (non-ephemeral) session:
    /// a plain local shell tab is GUI-owned and killed on close, so
    /// detach/rename/kill are meaningless. The parent row (and its
    /// leading separator) hides when the pre-popup hook leaves the
    /// mux actions disabled.
    remote_only: bool = false,
};

const Item = union(enum) {
    bind: Bind,
    submenu: Submenu,
    separator,
};

/// Top-level menu layout. Submenu children open in a nested popover
/// on hover (and on click), classic-menu style.
const MENU = [_]Item{
    .{ .bind = .{ .label = "Return to Browser", .icon = "web-browser-symbolic", .action = .toggle_web_face, .web_only = true } },
    .separator,
    .{ .bind = .{ .label = "Open Link", .icon = "web-browser-symbolic", .action = .open_link, .link_only = true } },
    .{ .bind = .{ .label = "Copy Link", .icon = "insert-link-symbolic", .action = .copy_link, .link_only = true } },
    .separator,
    .{ .bind = .{ .label = "Copy", .icon = "edit-copy-symbolic", .action = .copy_selection } },
    .{ .bind = .{ .label = "Paste", .icon = "edit-paste-symbolic", .action = .paste_clipboard } },
    .{ .bind = .{ .label = "Select All", .icon = "edit-select-all-symbolic", .action = .select_all } },
    .{ .submenu = .{ .label = "Copy More", .icon = "edit-select-all-symbolic", .items = &.{
        .{ .label = "Copy Screen", .icon = "edit-select-all-symbolic", .action = .copy_screen },
        .{ .label = "Copy Scrollback", .icon = "edit-select-all-symbolic", .action = .copy_scrollback },
        .{ .label = "Copy Command Output", .icon = "utilities-terminal-symbolic", .action = .copy_command_output },
        .{ .label = "Select Command Output", .icon = "edit-select-all-symbolic", .action = .select_command_output },
    } } },
    .{ .bind = .{ .label = "Find…", .icon = "edit-find-symbolic", .action = .search_open } },
    .separator,
    .{ .bind = .{ .label = "Split Left / Right", .icon = "sketerm-split-left-right-symbolic", .action = .split_h } },
    .{ .bind = .{ .label = "Split Top / Bottom", .icon = "sketerm-split-top-bottom-symbolic", .action = .split_v } },
    .{ .submenu = .{ .label = "Files", .icon = "folder-symbolic", .items = &.{
        .{ .label = "Browse Here in Pane", .icon = "folder-open-symbolic", .action = .files_browse_here },
        .{ .label = "Browse Here in New Tab", .icon = "folder-new-symbolic", .action = .new_browser_tab },
        .{ .label = "Open in Sketerm Files", .icon = "system-file-manager-symbolic", .action = .files_open_app },
    } } },
    .{ .submenu = .{ .label = "Pane", .icon = "view-grid-symbolic", .items = &.{
        .{ .label = "Zoom / Unzoom Pane", .icon = "view-fullscreen-symbolic", .action = .zoom_pane },
        .{ .label = "Set Pane Title…", .icon = "document-edit-symbolic", .action = .set_pane_title },
        .{ .label = "Apply Profile to Pane…", .icon = "preferences-other-symbolic", .action = .apply_profile },
        .{ .label = "Screenshot Pane…", .icon = "camera-photo-symbolic", .action = .screenshot_pane },
        .{ .label = "Record Session (asciicast)…", .icon = "media-record-symbolic", .action = .record_session, .rec_row = 1 },
        .{ .label = "Stop Session Recording", .icon = "media-playback-stop-symbolic", .action = .record_session_stop, .rec_row = 2 },
        .{ .label = "Close Pane", .icon = "window-close-symbolic", .action = .close_pane },
    } } },
    .{ .submenu = .{ .label = "Shader", .icon = "sketerm-rendering-symbolic", .items = &.{
        .{ .label = "Pane Shader…", .icon = "sketerm-rendering-symbolic", .action = .shader_pick },
        .{ .label = "Shader Preset…", .icon = "sketerm-starred-symbolic", .action = .shader_preset_pick },
        .{ .label = "Configure Shader…", .icon = "preferences-other-symbolic", .action = .configure_shader },
        .{ .label = "Clear Pane Shader", .icon = "edit-clear-symbolic", .action = .shader_clear },
    } } },
    .separator,
    .{ .submenu = .{ .label = "Tab", .icon = "tab-new-symbolic", .items = &.{
        .{ .label = "New Tab", .icon = "tab-new-symbolic", .action = .new_tab },
        .{ .label = "New Tab as Profile…", .icon = "tab-new-symbolic", .action = .new_tab_as_profile },
        .{ .label = "Duplicate Tab", .icon = "edit-copy-symbolic", .action = .duplicate_tab },
        .{ .label = "Rename Tab…", .icon = "document-edit-symbolic", .action = .rename_tab },
        .{ .label = "Tab Colour…", .icon = "color-select-symbolic", .action = .color_tab },
        .{ .label = "Pin / Unpin Tab", .icon = "view-pin-symbolic", .action = .toggle_pin_tab },
        .{ .label = "Tab Tree Sidebar", .icon = "sidebar-show-symbolic", .action = .toggle_tab_sidebar },
        .{ .label = "Collapse Tab Subtree", .icon = "pan-end-symbolic", .action = .tab_collapse },
        .{ .label = "Expand Tab Subtree", .icon = "pan-down-symbolic", .action = .tab_expand },
        .{ .label = "Next Tab (Tree Order)", .icon = "go-down-symbolic", .action = .tab_tree_next },
        .{ .label = "Previous Tab (Tree Order)", .icon = "go-up-symbolic", .action = .tab_tree_prev },
        .{ .label = "Close Tab", .icon = "window-close-symbolic", .action = .close_tab },
    } } },
    .separator,
    .{ .bind = .{ .label = "Launch App…", .icon = "application-x-executable-symbolic", .action = .launch_app } },
    .{ .submenu = .{ .label = "Session", .icon = "network-server-symbolic", .remote_only = true, .items = &.{
        .{ .label = "Upload File…", .icon = "document-send-symbolic", .action = .upload_file, .host_only = true },
        .{ .label = "Download File…", .icon = "folder-download-symbolic", .action = .download_file, .host_only = true },
        .{ .label = "Detach Session", .icon = "network-offline-symbolic", .action = .mux_detach },
        .{ .label = "Rename Session…", .icon = "document-edit-symbolic", .action = .mux_rename },
        .{ .label = "Kill Session", .icon = "process-stop-symbolic", .action = .mux_kill },
    } } },
    .separator,
    .{ .bind = .{ .label = "Clear Scrollback", .icon = "edit-clear-all-symbolic", .action = .clear_scrollback } },
    .{ .bind = .{ .label = "Reset Terminal", .icon = "view-refresh-symbolic", .action = .reset_terminal } },
    .{ .bind = .{ .label = "Preferences…", .icon = "preferences-system-symbolic", .action = .prefs_open } },
    .{ .bind = .{ .label = "Welcome Tour", .icon = "help-about-symbolic", .action = .welcome_open } },
};

/// Flat view of every action row (top-level and submenu children),
/// the action-group registration source.
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

/// The action group every menu-bearing widget carries.
const GROUP = "term";
const GROUP_PREFIX = GROUP ++ ".";

/// The detailed GAction name every action is registered under: the
/// group prefix, then its tag with `_` spelled `-`, since a GAction
/// name may not contain `_`.
const GACTION_DETAILED = blk: {
    @setEvalBranchQuota(20_000);
    const fields = @typeInfo(Action).@"enum".fields;
    var names: [fields.len][:0]const u8 = undefined;
    for (fields, 0..) |f, i| {
        var buf = [_:0]u8{0} ** (GROUP_PREFIX.len + f.name.len);
        @memcpy(buf[0..GROUP_PREFIX.len], GROUP_PREFIX);
        for (f.name, 0..) |ch, j| buf[GROUP_PREFIX.len + j] = if (ch == '_') '-' else ch;
        const final = buf;
        names[i] = &final;
    }
    break :blk names;
};

fn detailedName(action: Action) [:0]const u8 {
    return GACTION_DETAILED[@intFromEnum(action)];
}

fn gactionName(action: Action) [:0]const u8 {
    return detailedName(action)[GROUP_PREFIX.len..];
}

/// Enable or disable one row's action in a menu's group (the pre-popup
/// hook's per-pane state); an action without a row is ignored.
pub fn setEnabled(group: *c.GSimpleActionGroup, action: Action, enabled: bool) void {
    if (c.g_action_map_lookup_action(@ptrCast(group), gactionName(action).ptr)) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), @intFromBool(enabled));
    }
}

const N_SUBMENUS = blk: {
    var n: usize = 0;
    for (MENU) |it| {
        if (it == .submenu) n += 1;
    }
    break :blk n;
};

/// Remote-only conditional widgets: each remote submenu's parent row
/// plus the separator leading into it.
const N_REMOTE_WIDGETS = blk: {
    var n: usize = 0;
    for (MENU) |it| {
        if (it == .submenu and it.submenu.remote_only) n += 2;
    }
    break :blk n;
};

/// Link-only conditional widgets: the link rows plus the separator
/// that trails them.
const N_LINK_WIDGETS = blk: {
    var n: usize = 0;
    for (MENU) |it| {
        if (it == .bind and it.bind.link_only) n += 1;
    }
    break :blk n + 1;
};

/// Web-only conditional widgets: the "Return to Browser" row plus
/// the separator that trails it.
const N_WEB_WIDGETS = blk: {
    var n: usize = 0;
    for (MENU) |it| {
        if (it == .bind and it.bind.web_only) n += 1;
    }
    break :blk n + 1;
};

/// Host-only conditional widgets: submenu child rows that only apply
/// to a session on a remote machine (upload / download).
const N_HOST_WIDGETS = blk: {
    var n: usize = 0;
    for (MENU) |it| {
        if (it == .submenu) for (it.submenu.items) |b| {
            if (b.host_only) n += 1;
        };
    }
    break :blk n;
};

fn bindFor(comptime action: Action) Bind {
    for (BINDS) |b| {
        if (b.action == action) return b;
    }
    @compileError("no pane-menu row for action " ++ @tagName(action));
}

/// This spec's wording for one action, so another surface (the window
/// hamburger, the tab-strip menu) offers the same verb without a
/// second copy of it; a relabelled verb moves in every menu at once.
pub fn labelFor(comptime action: Action) [*:0]const u8 {
    return comptime bindFor(action).label;
}

pub fn iconFor(comptime action: Action) [*:0]const u8 {
    return comptime bindFor(action).icon;
}

/// Widget data key under which a menu-bearing widget publishes its
/// ClickCtx, so `popupAt` can reach it from the keyboard path. The
/// data is NOT owned here (no GDestroyNotify): the click gesture's
/// destroy-notify (`menuchrome.destroyMenuCtx`) is the single owner,
/// and the gesture dies with the widget, so the key can never outlive
/// the pointer it holds.
const CTX_KEY = "sketerm-term-menu";

const ClickCtx = struct {
    allocator: std.mem.Allocator,
    /// The widget the menu is attached to. Focus returns here when
    /// the popover closes with focus still inside it.
    widget: *c.GtkWidget,
    popover: *c.GtkWidget,
    group: *c.GSimpleActionGroup,
    pre_popup_fn: ?PrePopupFn = null,
    pre_popup_ctx: ?*anyopaque = null,
    /// Nested submenu popovers; hover management pops down every
    /// sibling when a top-level row is entered. Parented to row
    /// buttons inside the popover.
    subs: [N_SUBMENUS]?*c.GtkWidget = @splat(null),
    /// Remote-only rows + their leading separator; shown only when
    /// the pre-popup hook enabled the mux actions. Children of the
    /// popover, so the pointers never outlive it.
    remote_widgets: [N_REMOTE_WIDGETS]?*c.GtkWidget = @splat(null),
    /// Recording start/stop rows; visibility mirrors the session's
    /// recording state via the pre-popup hook.
    rec_start_widgets: [1]?*c.GtkWidget = @splat(null),
    rec_stop_widgets: [1]?*c.GtkWidget = @splat(null),
    /// Link rows + their trailing separator; shown only when the
    /// pre-popup hook found a link under the click.
    link_widgets: [N_LINK_WIDGETS]?*c.GtkWidget = @splat(null),
    /// "Return to Browser" + its trailing separator; shown only while
    /// the pane carries a hidden web face.
    web_widgets: [N_WEB_WIDGETS]?*c.GtkWidget = @splat(null),
    /// Submenu child rows (upload / download) shown only when the
    /// pre-popup hook found a remote-host session.
    host_widgets: [N_HOST_WIDGETS]?*c.GtkWidget = @splat(null),
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
        const act = c.g_simple_action_new(gactionName(b.action).ptr, null);
        _ = c.g_signal_connect_data(
            act,
            "activate",
            @ptrCast(&onActivate),
            @ptrCast(slot),
            @ptrCast(cast.destroyCtx(ActionSlot)),
            c.G_CONNECT_DEFAULT,
        );
        c.g_action_map_add_action(@ptrCast(group), @ptrCast(act));
        c.g_object_unref(act);
    }
    c.gtk_widget_insert_action_group(widget, GROUP, @ptrCast(group));
    c.g_object_unref(group);

    // Link + mux + file-transfer actions default disabled; the pane's
    // pre-popup hook enables them per-popup. Their rows show/hide on
    // that state.
    for ([_]Action{ .open_link, .copy_link, .mux_detach, .mux_rename, .mux_kill, .upload_file, .download_file, .record_session_stop }) |a| {
        setEnabled(@ptrCast(group), a, false);
    }

    // Popover: a custom GtkPopover holding a column of icon+label
    // buttons. We build the rows by hand because GtkPopoverMenu won't
    // render per-item icons. Each button activates its "term.*" action
    // (resolved through the group inserted above) and pops down on click.
    const popover = c.gtk_popover_new();
    c.gtk_widget_set_parent(popover, widget);
    // Until `destroyMenuCtx` is installed below, nothing else unparents
    // this: an OOM on the way there would leave `widget` finalizing with
    // a child still attached, the exact case that notify exists for.
    errdefer c.gtk_widget_unparent(popover);
    c.gtk_popover_set_has_arrow(@ptrCast(popover), 0);

    // The shared context is filled while rows are built (submenu /
    // conditional-row pointers), then handed to the click gesture,
    // whose destroy-notify owns it.
    const cctx = try allocator.create(ClickCtx);
    cctx.* = .{
        .allocator = allocator,
        .widget = widget,
        .popover = popover,
        .group = @ptrCast(group),
        .pre_popup_fn = pre_popup_fn,
        .pre_popup_ctx = pre_popup_ctx,
    };
    errdefer allocator.destroy(cctx);

    const list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    var n_sub: usize = 0;
    var n_remote: usize = 0;
    var n_link: usize = 0;
    var n_host: usize = 0;
    var n_web: usize = 0;
    var prev_was_link = false;
    var prev_was_web = false;
    var prev_sep: ?*c.GtkWidget = null;
    for (MENU) |item| {
        switch (item) {
            .separator => {
                const sep = c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL);
                c.gtk_box_append(@ptrCast(list), sep);
                // The separator trailing the link rows hides with them.
                if (prev_was_link) {
                    cctx.link_widgets[n_link] = sep;
                    n_link += 1;
                }
                if (prev_was_web) {
                    cctx.web_widgets[n_web] = sep;
                    n_web += 1;
                }
                prev_was_link = false;
                prev_was_web = false;
                prev_sep = sep;
            },
            .bind => |b| {
                const btn = menuchrome.makeRow(b.icon, b.label, false);
                c.gtk_actionable_set_action_name(@ptrCast(btn), detailedName(b.action).ptr);
                _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&menuchrome.onItemClicked), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
                c.gtk_box_append(@ptrCast(list), btn);
                if (b.link_only) {
                    cctx.link_widgets[n_link] = btn;
                    n_link += 1;
                }
                if (b.web_only) {
                    cctx.web_widgets[n_web] = btn;
                    n_web += 1;
                }
                try Hover.attach(allocator, btn, cctx, null);
                prev_was_link = b.link_only;
                prev_was_web = b.web_only;
            },
            .submenu => |s| {
                const btn = menuchrome.makeRow(s.icon, s.label, true);
                const sub_pop = c.gtk_popover_new();
                c.gtk_widget_set_parent(sub_pop, btn);
                c.gtk_popover_set_has_arrow(@ptrCast(sub_pop), 0);
                c.gtk_popover_set_autohide(@ptrCast(sub_pop), 0);
                c.gtk_popover_set_position(@ptrCast(sub_pop), c.GTK_POS_RIGHT);
                const sub_list = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
                for (s.items) |b| {
                    const child = menuchrome.makeRow(b.icon, b.label, false);
                    c.gtk_actionable_set_action_name(@ptrCast(child), detailedName(b.action).ptr);
                    _ = c.g_signal_connect_data(child, "clicked", @ptrCast(&menuchrome.onItemClicked), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
                    c.gtk_box_append(@ptrCast(sub_list), child);
                    if (b.host_only) {
                        cctx.host_widgets[n_host] = child;
                        n_host += 1;
                    }
                    if (b.rec_row == 1) cctx.rec_start_widgets[0] = child;
                    if (b.rec_row == 2) cctx.rec_stop_widgets[0] = child;
                }
                c.gtk_popover_set_child(@ptrCast(sub_pop), sub_list);
                // Click also opens the submenu (keyboard / touch path).
                _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&menuchrome.onSubParentClicked), @ptrCast(sub_pop), null, c.G_CONNECT_DEFAULT);
                c.gtk_box_append(@ptrCast(list), btn);
                cctx.subs[n_sub] = sub_pop;
                n_sub += 1;
                if (s.remote_only) {
                    // The separator leading INTO the remote section
                    // hides together with its row.
                    if (prev_sep) |sep| {
                        cctx.remote_widgets[n_remote] = sep;
                        n_remote += 1;
                    }
                    cctx.remote_widgets[n_remote] = btn;
                    n_remote += 1;
                }
                try Hover.attach(allocator, btn, cctx, sub_pop);
                prev_was_link = false;
                prev_was_web = false;
            },
        }
        if (item != .separator) prev_sep = null;
    }
    // Any open submenu pops down with the main menu.
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onPopoverClosed), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
    menuchrome.setPopoverList(popover, list);
    menuchrome.attachRightClick(widget, &onRightClick, cctx, menuchrome.destroyMenuCtx(ClickCtx));
    // Published last, once every field is filled: the keyboard path
    // (`popupAt`) resolves the same context through this key.
    c.g_object_set_data(@ptrCast(@alignCast(widget)), CTX_KEY, @ptrCast(cctx));
}

/// Pop the menu at widget-local (x, y) without a pointer event —
/// the Menu-key / Shift+F10 path, where the caller passes the text
/// cursor's rectangle instead of a click position. Runs the identical
/// pre-popup + conditional-row refresh as a right-click, so a
/// keyboard-opened menu reflects exactly the same state.
///
/// @return false when `widget` has no menu attached, or the pre-popup
/// hook suppressed it (right-click rebound to paste).
pub fn popupAt(widget: *c.GtkWidget, x: f64, y: f64) bool {
    const data = c.g_object_get_data(@ptrCast(@alignCast(widget)), CTX_KEY) orelse return false;
    const ctx: *ClickCtx = @ptrCast(@alignCast(data));
    return showAt(ctx, x, y);
}

test "menu: registered and detailed action names agree" {
    // A mismatch produces a row that LOOKS enabled and does nothing when
    // clicked: gtk_actionable_set_action_name silently accepts an action
    // the group does not contain.
    for (BINDS) |b| {
        const detailed = detailedName(b.action);
        try std.testing.expect(std.mem.startsWith(u8, detailed, GROUP_PREFIX));
        try std.testing.expectEqualStrings(gactionName(b.action), detailed[GROUP_PREFIX.len..]);
        try std.testing.expect(std.mem.indexOfScalar(u8, gactionName(b.action), '_') == null);
        try std.testing.expect(c.g_action_name_is_valid(gactionName(b.action).ptr) != 0);
    }
}

test "menu: no action has two rows" {
    // Two rows for one action would register the same GAction twice,
    // and the second registration silently replaces the first.
    for (BINDS, 0..) |a, i| {
        for (BINDS[i + 1 ..]) |b| try std.testing.expect(a.action != b.action);
    }
}

test "menu: conditional-row buckets are sized for the rows that use them" {
    // These counts drive fixed-size arrays in ClickCtx; an off-by-one
    // would silently drop a row from show/hide handling, leaving it
    // visible on a session it cannot act on.
    var link: usize = 0;
    var host: usize = 0;
    var web: usize = 0;
    var rec_start: usize = 0;
    var rec_stop: usize = 0;
    for (BINDS) |b| {
        if (b.link_only) link += 1;
        if (b.host_only) host += 1;
        if (b.web_only) web += 1;
        if (b.rec_row == 1) rec_start += 1;
        if (b.rec_row == 2) rec_stop += 1;
    }
    // Link bucket also holds the separator trailing the link rows.
    try std.testing.expectEqual(link + 1, N_LINK_WIDGETS);
    try std.testing.expectEqual(web + 1, N_WEB_WIDGETS);
    try std.testing.expectEqual(host, N_HOST_WIDGETS);
    try std.testing.expectEqual(@as(usize, 1), rec_start);
    try std.testing.expectEqual(@as(usize, 1), rec_stop);
}

/// Hover behaviour for this menu's rows; see `ui/menuchrome.zig`.
const Hover = menuchrome.Hover(ClickCtx);

fn onPopoverClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ClickCtx, user);
    for (ctx.subs) |maybe_sub| {
        const sub = maybe_sub orelse continue;
        if (c.gtk_widget_get_visible(sub) != 0) c.gtk_popover_popdown(@ptrCast(sub));
    }
    returnFocus(ctx);
}

/// Hand keyboard focus back to the menu's host widget when the
/// popover closes — without this the keyboard path (Menu / Shift+F10)
/// strands focus in a dead popover and the pane stops receiving keys,
/// which also loses the AT-SPI focus target.
///
/// Only fires when focus is still INSIDE the popover. A row that
/// opened a dialog (Set Pane Title…, Apply Profile…) has already
/// moved focus into an AdwDialog living in the same window, and
/// grabbing it back unconditionally would steal focus from that
/// dialog the frame it appeared.
fn returnFocus(ctx: *ClickCtx) void {
    returnFocusTo(ctx.widget, ctx.popover);
}

/// The widget-level half of `returnFocus`, for menus built elsewhere
/// (the shared tab-strip menu in ui/tabhost.zig) that need the same
/// rule without this module's ClickCtx. Same condition, same reason:
/// only take focus back when it is still stranded in the popover.
pub fn returnFocusTo(widget: *c.GtkWidget, popover: *c.GtkWidget) void {
    const root = c.gtk_widget_get_root(widget) orelse return;
    const focus = c.gtk_root_get_focus(@ptrCast(root));
    const inside = focus == null or
        focus == popover or
        c.gtk_widget_is_ancestor(focus, popover) != 0;
    if (!inside) return;
    _ = c.gtk_widget_grab_focus(widget);
}

fn onActivate(_: *c.GSimpleAction, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const slot = cast.userData(ActionSlot, user);
    slot.sink(slot.sink_ctx, slot.action);
}

fn onRightClick(g: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ClickCtx, user);
    if (ctx.pre_popup_fn) |f| {
        if (!f(ctx.pre_popup_ctx, ctx.group, x, y)) return;
    }
    // Claim the event sequence BEFORE popping up. The menu opens on
    // button PRESS; without the claim, the matching RELEASE keeps
    // propagating after the popover has mapped and taken its grab,
    // and the grab logic reads it as a click outside — dismissing
    // the menu the instant it opened. Timing-dependent, so it
    // presented as "right-click often does nothing".
    _ = c.gtk_gesture_set_state(@ptrCast(@alignCast(g)), c.GTK_EVENT_SEQUENCE_CLAIMED);
    _ = showAtPrepared(ctx, x, y);
}

/// Pre-popup hook + row refresh + popup. Split out of `onRightClick`
/// so the keyboard path runs byte-identical state resolution; the
/// only thing it cannot share is the gesture-sequence claim, which
/// has no meaning without a pointer event.
fn showAt(ctx: *ClickCtx, x: f64, y: f64) bool {
    if (ctx.pre_popup_fn) |f| {
        if (!f(ctx.pre_popup_ctx, ctx.group, x, y)) return false;
    }
    return showAtPrepared(ctx, x, y);
}

/// The half of `showAt` that runs AFTER the pre-popup hook.
fn showAtPrepared(ctx: *ClickCtx, x: f64, y: f64) bool {
    // Conditional rows: each group's visibility tracks a representative
    // action's enabled state, which the pre-popup hook set per-pane.
    //   - Session submenu (detach/rename/kill) → durable session.
    //   - Link rows (open/copy) → a link under the click.
    //   - File-transfer rows (upload/download) → a remote-host session.
    menuchrome.setGroupVisible(ctx.group, gactionName(.mux_detach).ptr, &ctx.remote_widgets);
    menuchrome.setGroupVisible(ctx.group, gactionName(.copy_link).ptr, &ctx.link_widgets);
    menuchrome.setGroupVisible(ctx.group, gactionName(.toggle_web_face).ptr, &ctx.web_widgets);
    menuchrome.setGroupVisible(ctx.group, gactionName(.upload_file).ptr, &ctx.host_widgets);
    menuchrome.setGroupVisible(ctx.group, gactionName(.record_session).ptr, &ctx.rec_start_widgets);
    menuchrome.setGroupVisible(ctx.group, gactionName(.record_session_stop).ptr, &ctx.rec_stop_widgets);
    // Fresh popup: no submenu open.
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
    return true;
}

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
    /// Select the whole buffer (scrollback + screen) using the
    /// terminal's own line-select mode.
    select_all,
    /// Line-select the last OSC 133 command output zone.
    select_output,
    /// Open the pane search bar (Ctrl+Shift+F's action).
    search,
    /// Wipe the scrollback ring; the visible screen stays.
    clear_scrollback,
    paste,
    new_tab,
    new_tab_as_profile,
    duplicate_tab,
    close_tab,
    rename_tab,
    color_tab,
    pin_tab,
    /// Tree-style tabs: the sidebar itself, and folding the selected
    /// tab's children away. Bindable from the palette too, but a
    /// feature nobody can find is a feature nobody has.
    toggle_tab_sidebar,
    tab_collapse,
    tab_expand,
    tab_tree_next,
    tab_tree_prev,
    split_h,
    split_v,
    files_browse_here,
    files_browse_tab,
    files_open_app,
    zoom_pane,
    close_pane,
    set_pane_title,
    apply_profile,
    shader_pick,
    shader_preset,
    shader_config,
    shader_clear,
    upload_file,
    download_file,
    mux_detach,
    mux_rename,
    mux_kill,
    reset_terminal,
    screenshot_pane,
    record_session,
    record_session_stop,
    launch_remote_app,
    open_link,
    copy_link,
    /// Bring back a pane's HIDDEN web face ("Show this pane's shell"
    /// swapped it away, and every affordance to return with it lives
    /// on the browser toolbar that is now invisible).
    show_web_face,
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

const Bind = struct {
    name: [*:0]const u8,
    label: [*:0]const u8,
    detailed: [*:0]const u8,
    /// Symbolic icon name (stock Adwaita, or a bundled sketerm-* icon).
    icon: [*:0]const u8,
    action: Action,
    /// Row only makes sense when the right-click landed on a
    /// hyperlink / detected URL. These rows (and their section
    /// separator) hide when the pre-popup hook leaves "copy-link"
    /// disabled.
    link_only: bool = false,
    /// Row only makes sense on a session whose PTY lives on another
    /// machine (SSH / UDP host) — file transfer to a local session
    /// is pointless. Hidden when the pre-popup hook leaves
    /// "upload-file" disabled.
    host_only: bool = false,
    /// Recording-state pair: 1 = "start recording" row (hidden while
    /// the session records), 2 = "stop" row (shown only while it
    /// does). The pre-popup hook drives the actions' enabled state.
    rec_row: u8 = 0,
    /// Row only makes sense while the pane carries a HIDDEN web face
    /// (the only state with no other way back to the browser). Hidden
    /// (with its trailing separator) when the pre-popup hook leaves
    /// "show-web" disabled.
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
    .{ .bind = .{ .name = "show-web", .label = "Return to Browser", .detailed = "term.show-web", .icon = "web-browser-symbolic", .action = .show_web_face, .web_only = true } },
    .separator,
    .{ .bind = .{ .name = "open-link", .label = "Open Link", .detailed = "term.open-link", .icon = "web-browser-symbolic", .action = .open_link, .link_only = true } },
    .{ .bind = .{ .name = "copy-link", .label = "Copy Link", .detailed = "term.copy-link", .icon = "insert-link-symbolic", .action = .copy_link, .link_only = true } },
    .separator,
    .{ .bind = .{ .name = "copy", .label = "Copy", .detailed = "term.copy", .icon = "edit-copy-symbolic", .action = .copy } },
    .{ .bind = .{ .name = "paste", .label = "Paste", .detailed = "term.paste", .icon = "edit-paste-symbolic", .action = .paste } },
    .{ .bind = .{ .name = "select-all", .label = "Select All", .detailed = "term.select-all", .icon = "edit-select-all-symbolic", .action = .select_all } },
    .{ .submenu = .{ .label = "Copy More", .icon = "edit-select-all-symbolic", .items = &.{
        .{ .name = "copy-screen", .label = "Copy Screen", .detailed = "term.copy-screen", .icon = "edit-select-all-symbolic", .action = .copy_screen },
        .{ .name = "copy-scrollback", .label = "Copy Scrollback", .detailed = "term.copy-scrollback", .icon = "edit-select-all-symbolic", .action = .copy_scrollback },
        .{ .name = "copy-output", .label = "Copy Command Output", .detailed = "term.copy-output", .icon = "utilities-terminal-symbolic", .action = .copy_output },
        .{ .name = "select-output", .label = "Select Command Output", .detailed = "term.select-output", .icon = "edit-select-all-symbolic", .action = .select_output },
    } } },
    .{ .bind = .{ .name = "search", .label = "Find…", .detailed = "term.search", .icon = "edit-find-symbolic", .action = .search } },
    .separator,
    .{ .bind = .{ .name = "split-h", .label = "Split Left / Right", .detailed = "term.split-h", .icon = "sketerm-split-left-right-symbolic", .action = .split_h } },
    .{ .bind = .{ .name = "split-v", .label = "Split Top / Bottom", .detailed = "term.split-v", .icon = "sketerm-split-top-bottom-symbolic", .action = .split_v } },
    .{ .submenu = .{ .label = "Files", .icon = "folder-symbolic", .items = &.{
        .{ .name = "files-here", .label = "Browse Here in Pane", .detailed = "term.files-here", .icon = "folder-open-symbolic", .action = .files_browse_here },
        .{ .name = "files-tab", .label = "Browse Here in New Tab", .detailed = "term.files-tab", .icon = "folder-new-symbolic", .action = .files_browse_tab },
        .{ .name = "files-app", .label = "Open in Sketerm Files", .detailed = "term.files-app", .icon = "system-file-manager-symbolic", .action = .files_open_app },
    } } },
    .{ .submenu = .{ .label = "Pane", .icon = "view-grid-symbolic", .items = &.{
        .{ .name = "zoom-pane", .label = "Zoom / Unzoom Pane", .detailed = "term.zoom-pane", .icon = "view-fullscreen-symbolic", .action = .zoom_pane },
        .{ .name = "set-pane-title", .label = "Set Pane Title…", .detailed = "term.set-pane-title", .icon = "document-edit-symbolic", .action = .set_pane_title },
        .{ .name = "apply-profile", .label = "Apply Profile to Pane…", .detailed = "term.apply-profile", .icon = "preferences-other-symbolic", .action = .apply_profile },
        .{ .name = "screenshot-pane", .label = "Screenshot Pane…", .detailed = "term.screenshot-pane", .icon = "camera-photo-symbolic", .action = .screenshot_pane },
        .{ .name = "record-session", .label = "Record Session (asciicast)…", .detailed = "term.record-session", .icon = "media-record-symbolic", .action = .record_session, .rec_row = 1 },
        .{ .name = "record-stop", .label = "Stop Session Recording", .detailed = "term.record-stop", .icon = "media-playback-stop-symbolic", .action = .record_session_stop, .rec_row = 2 },
        .{ .name = "close-pane", .label = "Close Pane", .detailed = "term.close-pane", .icon = "window-close-symbolic", .action = .close_pane },
    } } },
    .{ .submenu = .{ .label = "Shader", .icon = "sketerm-rendering-symbolic", .items = &.{
        .{ .name = "shader-pick", .label = "Pane Shader…", .detailed = "term.shader-pick", .icon = "sketerm-rendering-symbolic", .action = .shader_pick },
        .{ .name = "shader-preset", .label = "Shader Preset…", .detailed = "term.shader-preset", .icon = "sketerm-starred-symbolic", .action = .shader_preset },
        .{ .name = "shader-config", .label = "Configure Shader…", .detailed = "term.shader-config", .icon = "preferences-other-symbolic", .action = .shader_config },
        .{ .name = "shader-clear", .label = "Clear Pane Shader", .detailed = "term.shader-clear", .icon = "edit-clear-symbolic", .action = .shader_clear },
    } } },
    .separator,
    .{ .submenu = .{ .label = "Tab", .icon = "tab-new-symbolic", .items = &.{
        .{ .name = "new-tab", .label = "New Tab", .detailed = "term.new-tab", .icon = "tab-new-symbolic", .action = .new_tab },
        .{ .name = "new-tab-as-profile", .label = "New Tab as Profile…", .detailed = "term.new-tab-as-profile", .icon = "tab-new-symbolic", .action = .new_tab_as_profile },
        .{ .name = "duplicate-tab", .label = "Duplicate Tab", .detailed = "term.duplicate-tab", .icon = "edit-copy-symbolic", .action = .duplicate_tab },
        .{ .name = "rename-tab", .label = "Rename Tab…", .detailed = "term.rename-tab", .icon = "document-edit-symbolic", .action = .rename_tab },
        .{ .name = "color-tab", .label = "Tab Colour…", .detailed = "term.color-tab", .icon = "color-select-symbolic", .action = .color_tab },
        .{ .name = "pin-tab", .label = "Pin / Unpin Tab", .detailed = "term.pin-tab", .icon = "view-pin-symbolic", .action = .pin_tab },
        .{ .name = "toggle-tab-sidebar", .label = "Tab Tree Sidebar", .detailed = "term.toggle-tab-sidebar", .icon = "sidebar-show-symbolic", .action = .toggle_tab_sidebar },
        .{ .name = "tab-collapse", .label = "Collapse Tab Subtree", .detailed = "term.tab-collapse", .icon = "pan-end-symbolic", .action = .tab_collapse },
        .{ .name = "tab-expand", .label = "Expand Tab Subtree", .detailed = "term.tab-expand", .icon = "pan-down-symbolic", .action = .tab_expand },
        .{ .name = "tab-tree-next", .label = "Next Tab (Tree Order)", .detailed = "term.tab-tree-next", .icon = "go-down-symbolic", .action = .tab_tree_next },
        .{ .name = "tab-tree-prev", .label = "Previous Tab (Tree Order)", .detailed = "term.tab-tree-prev", .icon = "go-up-symbolic", .action = .tab_tree_prev },
        .{ .name = "close-tab", .label = "Close Tab", .detailed = "term.close-tab", .icon = "window-close-symbolic", .action = .close_tab },
    } } },
    .separator,
    .{ .bind = .{ .name = "launch-app", .label = "Launch App…", .detailed = "term.launch-app", .icon = "application-x-executable-symbolic", .action = .launch_remote_app } },
    .{ .submenu = .{ .label = "Session", .icon = "network-server-symbolic", .remote_only = true, .items = &.{
        .{ .name = "upload-file", .label = "Upload File…", .detailed = "term.upload-file", .icon = "document-send-symbolic", .action = .upload_file, .host_only = true },
        .{ .name = "download-file", .label = "Download File…", .detailed = "term.download-file", .icon = "folder-download-symbolic", .action = .download_file, .host_only = true },
        .{ .name = "mux-detach", .label = "Detach Session", .detailed = "term.mux-detach", .icon = "network-offline-symbolic", .action = .mux_detach },
        .{ .name = "mux-rename", .label = "Rename Session…", .detailed = "term.mux-rename", .icon = "document-edit-symbolic", .action = .mux_rename },
        .{ .name = "mux-kill", .label = "Kill Session", .detailed = "term.mux-kill", .icon = "process-stop-symbolic", .action = .mux_kill },
    } } },
    .separator,
    .{ .bind = .{ .name = "clear-scrollback", .label = "Clear Scrollback", .detailed = "term.clear-scrollback", .icon = "edit-clear-all-symbolic", .action = .clear_scrollback } },
    .{ .bind = .{ .name = "reset", .label = "Reset Terminal", .detailed = "term.reset", .icon = "view-refresh-symbolic", .action = .reset_terminal } },
    .{ .bind = .{ .name = "prefs", .label = "Preferences…", .detailed = "term.prefs", .icon = "preferences-system-symbolic", .action = .prefs_open } },
};

/// Flat view of every action row (top-level and submenu children) —
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

/// This spec's wording and icon for one action, so another surface
/// can offer the same verb without a second copy of either. The
/// window hamburger is the consumer: its rows are this table's rows,
/// dispatched through the same `Sink`, so a relabelled verb moves in
/// both places at once.
///
/// `Action` has exactly one row (pinned by a test below), which is
/// what makes the lookup total.
pub fn labelFor(action: Action) [*:0]const u8 {
    for (BINDS) |b| {
        if (b.action == action) return b.label;
    }
    unreachable;
}

pub fn iconFor(action: Action) [*:0]const u8 {
    for (BINDS) |b| {
        if (b.action == action) return b.icon;
    }
    unreachable;
}

/// Widget data key under which a menu-bearing widget publishes its
/// ClickCtx, so `popupAt` can reach it from the keyboard path. The
/// data is NOT owned here (no GDestroyNotify): the click gesture's
/// `freeClickCtx` is the single owner, and the gesture dies with the
/// widget, so the key can never outlive the pointer it holds.
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

/// Per-top-level-row hover context: entering any row pops down every
/// submenu except this row's own (if any), which pops up.
const HoverCtx = struct {
    allocator: std.mem.Allocator,
    cctx: *ClickCtx,
    sub: ?*c.GtkWidget,
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
            @ptrCast(cast.destroyCtx(ActionSlot)),
            c.G_CONNECT_DEFAULT,
        );
        c.g_action_map_add_action(@ptrCast(group), @ptrCast(act));
        c.g_object_unref(act);
    }
    c.gtk_widget_insert_action_group(widget, "term", @ptrCast(group));
    c.g_object_unref(group);

    // Link + mux + file-transfer actions default disabled; the pane's
    // pre-popup hook enables them per-popup. Their rows show/hide on
    // that state.
    for ([_][*:0]const u8{ "open-link", "copy-link", "mux-detach", "mux-rename", "mux-kill", "upload-file", "download-file", "record-stop" }) |name| {
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
                const btn = makeRow(b.icon, b.label, false);
                c.gtk_actionable_set_action_name(@ptrCast(btn), b.detailed);
                _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onItemClicked), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
                c.gtk_box_append(@ptrCast(list), btn);
                if (b.link_only) {
                    cctx.link_widgets[n_link] = btn;
                    n_link += 1;
                }
                if (b.web_only) {
                    cctx.web_widgets[n_web] = btn;
                    n_web += 1;
                }
                try addHover(allocator, btn, cctx, null);
                prev_was_link = b.link_only;
                prev_was_web = b.web_only;
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
                    if (b.host_only) {
                        cctx.host_widgets[n_host] = child;
                        n_host += 1;
                    }
                    if (b.rec_row == 1) cctx.rec_start_widgets[0] = child;
                    if (b.rec_row == 2) cctx.rec_stop_widgets[0] = child;
                }
                c.gtk_popover_set_child(@ptrCast(sub_pop), sub_list);
                // Click also opens the submenu (keyboard / touch path).
                _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onSubParentClicked), @ptrCast(sub_pop), null, c.G_CONNECT_DEFAULT);
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
                try addHover(allocator, btn, cctx, sub_pop);
                prev_was_link = false;
                prev_was_web = false;
            },
        }
        if (item != .separator) prev_sep = null;
    }
    // Any open submenu pops down with the main menu.
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onPopoverClosed), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
    // Wrap the list in a scroller with natural-height propagation.
    // Not for scrolling per se: GTK4 silently popdowns an autohide
    // popover whose MINIMUM size doesn't fit the space the compositor
    // grants (gtkpopover.c gtk_popover_native_layout →
    // is_acceptable_size). A bare GtkBox's minimum is the full list,
    // so right-clicking mid-window — where neither half fits ~15
    // rows — made the menu vanish the frame it mapped. The scroller
    // makes the minimum tiny (menu scrolls when constrained) while
    // natural height keeps the usual full-size rendering.
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

test "menu: label/icon lookup answers for every action" {
    // `labelFor`/`iconFor` are `unreachable` on a miss because the
    // one-row-per-Action test below makes a miss impossible; this
    // walks every arm so the pair is proven total, not assumed.
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const a: Action = @enumFromInt(field.value);
        try std.testing.expect(std.mem.span(labelFor(a)).len != 0);
        try std.testing.expect(std.mem.span(iconFor(a)).len != 0);
    }
}

test "menu: every row's detailed action name matches its bare name" {
    // A typo here produces a row that LOOKS enabled and does nothing
    // when clicked: gtk_actionable_set_action_name silently accepts an
    // action that the group does not contain. The action-group
    // registration below uses `name`, the button uses `detailed`, so
    // the two must agree or the row is dead.
    for (BINDS) |b| {
        const bare = std.mem.span(b.name);
        const detailed = std.mem.span(b.detailed);
        try std.testing.expect(std.mem.startsWith(u8, detailed, "term."));
        try std.testing.expectEqualStrings(bare, detailed["term.".len..]);
    }
}

test "menu: row names are unique" {
    // Duplicates would make g_action_map_add_action overwrite the
    // first registration, so one of the two rows would drive the
    // other's Action.
    for (BINDS, 0..) |a, i| {
        for (BINDS[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, std.mem.span(a.name), std.mem.span(b.name)));
        }
    }
}

test "menu: every Action has exactly one row" {
    // Adding an Action without a row (or two rows for one Action)
    // is otherwise invisible until someone hunts for a missing item.
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const want: Action = @enumFromInt(field.value);
        var seen: usize = 0;
        for (BINDS) |b| {
            if (b.action == want) seen += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), seen);
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

/// Build one flat icon+label menu-row button. `arrow` appends the
/// submenu chevron at the trailing edge.
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
    return btn;
}

/// Attach the hover controller that gives top-level rows classic
/// menu behaviour: entering a row closes sibling submenus and opens
/// this row's own (if it has one).
fn addHover(allocator: std.mem.Allocator, btn: *c.GtkWidget, cctx: *ClickCtx, sub: ?*c.GtkWidget) !void {
    const hctx = try allocator.create(HoverCtx);
    hctx.* = .{ .allocator = allocator, .cctx = cctx, .sub = sub };
    const motion = c.gtk_event_controller_motion_new();
    _ = c.g_signal_connect_data(
        motion,
        "enter",
        @ptrCast(&onRowEnter),
        @ptrCast(hctx),
        @ptrCast(cast.destroyCtx(HoverCtx)),
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

fn freeClickCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *ClickCtx = @ptrCast(@alignCast(u));
        // Pop popovers added via gtk_widget_set_parent must be
        // explicitly unparented before the host widget finalizes,
        // otherwise GTK warns "Finalizing GtkGLArea, but it still
        // has children left". This destroy-notify fires when the
        // click controller is removed from the widget — i.e. on
        // widget destruction — making it the right hook. Submenu
        // popovers (parented to row buttons) go first for the same
        // reason.
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

/// Show/hide a group of conditional rows to match `action`'s enabled
/// state (set per-pane by the pre-popup hook).
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
    setGroupVisible(ctx.group, "mux-detach", &ctx.remote_widgets);
    setGroupVisible(ctx.group, "copy-link", &ctx.link_widgets);
    setGroupVisible(ctx.group, "show-web", &ctx.web_widgets);
    setGroupVisible(ctx.group, "upload-file", &ctx.host_widgets);
    setGroupVisible(ctx.group, "record-session", &ctx.rec_start_widgets);
    setGroupVisible(ctx.group, "record-stop", &ctx.rec_stop_widgets);
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

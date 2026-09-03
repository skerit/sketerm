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
const menuchrome = @import("menuchrome.zig");
const editorview = @import("editorview.zig");
const EditorView = editorview.EditorView;
const ETab = editorview.ETab;
const classicmenu = @import("browser/classicmenu.zig");
const tabhost = @import("tabhost.zig");
const clipboard = @import("clipboard.zig");
const siblingapp = @import("siblingapp.zig");
const paths = @import("../filebrowser/paths.zig");

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

/// Hover behaviour for this menu's rows; see `ui/menuchrome.zig`.
const Hover = menuchrome.Hover(ClickCtx);

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
            @ptrCast(cast.destroyCtx(ActionSlot)),
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
                const btn = menuchrome.makeRow(b.icon, b.label, false);
                c.gtk_actionable_set_action_name(@ptrCast(btn), b.detailed);
                _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&menuchrome.onItemClicked), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
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
                try Hover.attach(allocator, btn, cctx, null);
                if (!b.lsp_only) prev_sep = null;
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
                    c.gtk_actionable_set_action_name(@ptrCast(child), b.detailed);
                    _ = c.g_signal_connect_data(child, "clicked", @ptrCast(&menuchrome.onItemClicked), @ptrCast(popover), null, c.G_CONNECT_DEFAULT);
                    c.gtk_box_append(@ptrCast(sub_list), child);
                }
                c.gtk_popover_set_child(@ptrCast(sub_pop), sub_list);
                _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&menuchrome.onSubParentClicked), @ptrCast(sub_pop), null, c.G_CONNECT_DEFAULT);
                c.gtk_box_append(@ptrCast(list), btn);
                cctx.subs[n_sub] = sub_pop;
                n_sub += 1;
                try Hover.attach(allocator, btn, cctx, sub_pop);
                prev_sep = null;
            },
        }
    }
    _ = c.g_signal_connect_data(popover, "closed", @ptrCast(&onPopoverClosed), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
    menuchrome.setPopoverList(popover, list);
    menuchrome.attachRightClick(widget, &onRightClick, cctx, menuchrome.destroyMenuCtx(ClickCtx));
}

fn onPopoverClosed(_: *c.GtkPopover, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ClickCtx, user);
    for (ctx.subs) |maybe_sub| {
        const sub = maybe_sub orelse continue;
        if (c.gtk_widget_get_visible(sub) != 0) c.gtk_popover_popdown(@ptrCast(sub));
    }
}

fn onActivate(_: *c.GSimpleAction, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) void {
    const slot = cast.userData(ActionSlot, user);
    slot.view.menuAction(slot.action);
}

fn onRightClick(g: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ClickCtx, user);
    // The gutter shares this widget with the text but not its menu:
    // a click there is about the LINE under the pointer, so it gets
    // the line-oriented menu instead of the caret-oriented one.
    if (ctx.view.gutterLineAt(x, y)) |line| {
        _ = c.gtk_gesture_set_state(@ptrCast(@alignCast(g)), c.GTK_EVENT_SEQUENCE_CLAIMED);
        showGutterMenu(ctx.view, line, x, y);
        return;
    }
    if (!ctx.view.menuPrePopup(ctx.group, x, y)) return;
    // Claim before popup: without it the release event dismisses the
    // popover the frame it maps (ui/menu.zig documents the race).
    _ = c.gtk_gesture_set_state(@ptrCast(@alignCast(g)), c.GTK_EVENT_SEQUENCE_CLAIMED);
    menuchrome.setGroupVisible(ctx.group, "goto-def", &ctx.lsp_widgets);
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

// ---- the gutter ---------------------------------------------------
//
// The line-number / fold / VCS column. Its menu is line-oriented: it
// acts on the line that was clicked, not on the caret, and it offers
// nothing that needs a selection.
//
// What is deliberately NOT here:
//   * breakpoints — sketerm has no debugger, and a row that toggles a
//     mark nothing reads would be a lie;
//   * stage / revert hunk — the GUI never touches the disk and never
//     runs a process (browser/CLAUDE.md), and the daemon's VCS verbs
//     (`git_status`, `git_diff`) are read-only. There is no write path
//     to put behind such a row.

pub const GutterAction = enum {
    toggle_fold,
    fold_all,
    unfold_all,
    goto_line,
    copy_line_number,
    select_line,
    next_hunk,
    prev_hunk,
};

/// Heap context for one gutter-menu row: the view, the verb and the
/// line the menu was opened on. Owned by the classicmenu Root.
const GutterCtx = struct {
    allocator: std.mem.Allocator,
    view: *EditorView,
    action: GutterAction,
    line: usize,

    fn make(root: *classicmenu.Root, view: *EditorView, action: GutterAction, line: usize) ?*GutterCtx {
        const ctx = view.allocator.create(GutterCtx) catch return null;
        ctx.* = .{ .allocator = view.allocator, .view = view, .action = action, .line = line };
        root.own(cast.destroyCtx(GutterCtx), @ptrCast(ctx));
        return ctx;
    }
};

fn onGutterRow(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(GutterCtx, user);
    ctx.view.gutterAction(ctx.action, ctx.line);
}

/// Add one gutter row, or nothing at all when the context could not be
/// allocated (a row with no handler must never appear).
fn gutterRow(
    m: classicmenu.Menu,
    root: *classicmenu.Root,
    view: *EditorView,
    label: [*:0]const u8,
    icon: [*:0]const u8,
    enabled: bool,
    action: GutterAction,
    line: usize,
) void {
    const ctx = GutterCtx.make(root, view, action, line) orelse return;
    m.itemIconEnabled(label, .{ .name = icon }, enabled, &onGutterRow, @ptrCast(ctx));
}

/// The gutter's context menu, built fresh for each popup so every row's
/// sensitivity is the state at popup time.
pub fn showGutterMenu(view: *EditorView, line: usize, x: f64, y: f64) void {
    const st = view.gutterState(line) orelse return;
    const root = classicmenu.Root.create(view.allocator) orelse return;
    const m = root.top();

    // Folding. One toggle row whose label says what it will do; it is
    // insensitive (not absent) when folding is off or this line heads
    // no region, so the gutter still explains what it can do.
    gutterRow(
        m,
        root,
        view,
        if (st.folded) "Unfold This Region" else "Fold This Region",
        if (st.folded) "list-add-symbolic" else "list-remove-symbolic",
        st.folded or st.foldable,
        .toggle_fold,
        line,
    );
    gutterRow(m, root, view, "Fold All", "view-restore-symbolic", st.folding, .fold_all, line);
    gutterRow(m, root, view, "Unfold All", "view-fullscreen-symbolic", st.any_folded, .unfold_all, line);

    // The line itself. The label carries no line number: the number
    // is in the gutter directly under the pointer, and a row whose
    // text changes per click is harder to find again than one whose
    // text never moves.
    const l = m.section();
    gutterRow(l, root, view, "Copy Line Number", "edit-copy-symbolic", true, .copy_line_number, line);
    gutterRow(l, root, view, "Select This Line", "edit-select-all-symbolic", true, .select_line, line);
    gutterRow(l, root, view, "Go to Line\u{2026}", "go-jump-symbolic", true, .goto_line, line);

    // Change navigation: the gutter is where the diff marks are drawn,
    // so this is where a person looks for them. Insensitive with no
    // marks rather than absent — "this file has no changes" is the
    // answer to the question, and `stepHunk` says which of the two
    // reasons it is on the status line.
    const g = m.section();
    gutterRow(g, root, view, "Next Change", "go-down-symbolic", st.has_hunks, .next_hunk, line);
    gutterRow(g, root, view, "Previous Change", "go-up-symbolic", st.has_hunks, .prev_hunk, line);

    _ = root.popupVia(@ptrCast(view.area), view.root_box, x, y);
}

// ---- the status line ----------------------------------------------
//
// The one-line summary under the canvas. Its menu offers exactly what
// the line REPORTS and nothing else: soft wrap (which it shows as
// "Wrap"), the caret position (Go to Line), the change count, and the
// diagnostic counts. There is no row for the language or the
// line-ending style, because the editor detects the language from the
// filename and shebang and has no override to expose, and has no
// re-encoding path to put behind a line-ending row — a menu that
// exists to not be empty is worse than no menu.

pub const StatusAction = enum {
    toggle_wrap,
    goto_line,
    next_hunk,
    prev_hunk,
    next_diag,
    prev_diag,
};

const StatusCtx = struct {
    allocator: std.mem.Allocator,
    view: *EditorView,
    action: StatusAction,

    fn make(root: *classicmenu.Root, view: *EditorView, action: StatusAction) ?*StatusCtx {
        const ctx = view.allocator.create(StatusCtx) catch return null;
        ctx.* = .{ .allocator = view.allocator, .view = view, .action = action };
        root.own(cast.destroyCtx(StatusCtx), @ptrCast(ctx));
        return ctx;
    }
};

fn onStatusRow(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(StatusCtx, user);
    ctx.view.statusAction(ctx.action);
}

fn statusRow(
    m: classicmenu.Menu,
    root: *classicmenu.Root,
    view: *EditorView,
    label: [*:0]const u8,
    icon: [*:0]const u8,
    enabled: bool,
    action: StatusAction,
) void {
    const ctx = StatusCtx.make(root, view, action) orelse return;
    m.itemIconEnabled(label, .{ .name = icon }, enabled, &onStatusRow, @ptrCast(ctx));
}

/// Right-click on the status label. Nothing pops when there is no
/// document: every row would be inert.
pub fn showStatusMenu(view: *EditorView, x: f64, y: f64) void {
    const st = view.statusState() orelse return;
    const root = classicmenu.Root.create(view.allocator) orelse return;
    const m = root.top();

    if (StatusCtx.make(root, view, .toggle_wrap)) |cx| {
        m.check("Soft Wrap", st.wrap, &onStatusRow, @ptrCast(cx));
    }
    statusRow(m, root, view, "Go to Line\u{2026}", "go-jump-symbolic", true, .goto_line);

    const g = m.section();
    statusRow(g, root, view, "Next Change", "go-down-symbolic", st.has_hunks, .next_hunk);
    statusRow(g, root, view, "Previous Change", "go-up-symbolic", st.has_hunks, .prev_hunk);

    // Diagnostics ride this same line; with no server attached there
    // are none to step through, so the rows are absent rather than
    // permanently dead — exactly the rule the canvas menu's LSP rows
    // already follow.
    if (st.lsp) {
        const d = m.section();
        statusRow(d, root, view, "Next Diagnostic", "dialog-warning-symbolic", true, .next_diag);
        statusRow(d, root, view, "Previous Diagnostic", "dialog-warning-symbolic", true, .prev_diag);
    }

    _ = root.popupVia(@ptrCast(@alignCast(view.status_label)), view.root_box, x, y);
}

/// Attach the status-line menu to the status label. The label is a
/// plain GtkLabel, so the gesture is all it takes.
pub fn attachStatusMenu(view: *EditorView, label: *c.GtkWidget) void {
    const click = c.gtk_gesture_click_new();
    c.gtk_gesture_single_set_button(@ptrCast(click), 3);
    _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onStatusClick), @ptrCast(view), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(label, @ptrCast(click));
}

fn onStatusClick(g: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    _ = c.gtk_gesture_set_state(@ptrCast(@alignCast(g)), c.GTK_EVENT_SEQUENCE_CLAIMED);
    showStatusMenu(view, x, y);
}

// ---- document tab strip -------------------------------------------
//
// The mechanical rows (Close / Close Others / Close to the Right /
// Close Unmodified / Open in New Window) are tabhost.zig's, shared
// with the file browser. Everything below is the editor's DOMAIN
// half: the per-document verbs and the predicates that decide which
// mechanical rows can act.

/// Heap context for one row of a popped tab menu. Identifies the tab
/// by ID, not by pointer: the menu outlives a `closeTabForce` that
/// destroys the ETab, so every handler re-resolves.
const TabCtx = struct {
    allocator: std.mem.Allocator,
    view: *EditorView,
    tab_id: u64,

    fn make(root: *classicmenu.Root, view: *EditorView, tab: *ETab) ?*TabCtx {
        const ctx = view.allocator.create(TabCtx) catch return null;
        ctx.* = .{ .allocator = view.allocator, .view = view, .tab_id = tab.id };
        root.own(cast.destroyCtx(TabCtx), @ptrCast(ctx));
        return ctx;
    }

    fn resolve(user: ?*anyopaque) ?struct { view: *EditorView, tab: *ETab } {
        const self = cast.userData(TabCtx, user);
        const tab = self.view.findTabByIdPublic(self.tab_id) orelse return null;
        return .{ .view = self.view, .tab = tab };
    }
};

/// The editor's half of the shared per-tab menu contract.
pub fn tabMenuSpec() tabhost.TabMenu {
    return .{
        .extra = &menuExtra,
        // No Duplicate: a second tab on the same file is refused by
        // design (openSpec focuses the tab that already has it).
        .new_window = &menuNewWindow,
        .can_new_window = &menuCanNewWindow,
        .modified = &menuModified,
    };
}

fn tabForPage(view: *EditorView, page: *c.GtkWidget) ?*ETab {
    for (view.tabs.items) |t| {
        if (t.page == page) return t;
    }
    return null;
}

/// The document rows. Insensitive rather than absent wherever the
/// verb is merely unavailable RIGHT NOW (nothing to save, no file on
/// disk yet, no project to be relative to) — the menu should still
/// show what a document tab can do.
fn menuExtra(ctx: ?*anyopaque, page: *c.GtkWidget, root: *classicmenu.Root, m: classicmenu.Menu) void {
    const view = cast.userData(EditorView, ctx);
    const tab = tabForPage(view, page) orelse return;
    const saved = tab.spec != null;

    if (TabCtx.make(root, view, tab)) |cx| {
        m.itemIconEnabled("Save", .{ .name = "document-save-symbolic" }, tab.isDirty() and !tab.loading, &onSave, @ptrCast(cx));
        m.itemIcon("Save As…", .{ .name = "document-save-as-symbolic" }, &onSaveAs, @ptrCast(cx));
        m.itemIconEnabled("Revert", .{ .name = "document-revert-symbolic" }, saved and !tab.loading, &onRevert, @ptrCast(cx));

        const p = m.section();
        p.itemIconEnabled("Copy Full Path", .{ .name = "edit-copy-symbolic" }, saved, &onCopyFullPath, @ptrCast(cx));
        // A loose file has NO project (project.zig answers null on a
        // marker miss), and there is then nothing to be relative to.
        p.itemIconEnabled(
            "Copy Relative Path",
            .{ .name = "edit-copy-symbolic" },
            saved and tab.project != null,
            &onCopyRelativePath,
            @ptrCast(cx),
        );
        p.itemIconEnabled("Reveal in File Browser", .{ .name = "folder-open-symbolic" }, saved, &onReveal, @ptrCast(cx));
    }

    // The browser's Reopen Closed Tab precedent: present only when
    // the ring has something to give back.
    if (view.closed_docs.items.len > 0) {
        var label: [96:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&label, "Reopen Closed Tab ({d})", .{
            view.closed_docs.items.len,
        }) catch "Reopen Closed Tab";
        const r = m.section();
        r.itemIcon(text.ptr, .{ .name = "document-open-recent-symbolic" }, &onReopenClosed, ctx);
    }
}

fn onReopenClosed(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const view: *EditorView = @ptrCast(@alignCast(user.?));
    view.reopenClosedDoc();
}

/// "Open in New Window": a standalone Sketerm Editor window on this
/// file — `siblingapp.openInEditor`, the same handoff the viewer and
/// the file browser use. Nothing is moved, so the tab stays.
fn menuNewWindow(ctx: ?*anyopaque, page: *c.GtkWidget) void {
    const view = cast.userData(EditorView, ctx);
    const tab = tabForPage(view, page) orelse return;
    const spec = tab.spec orelse return;
    _ = siblingapp.openInEditor(spec, null, .{ .new_window = true });
}

fn menuCanNewWindow(ctx: ?*anyopaque, page: *c.GtkWidget) bool {
    const view = cast.userData(EditorView, ctx);
    const tab = tabForPage(view, page) orelse return false;
    return tab.spec != null;
}

fn menuModified(ctx: ?*anyopaque, page: *c.GtkWidget) bool {
    const view = cast.userData(EditorView, ctx);
    const tab = tabForPage(view, page) orelse return false;
    return tab.isDirty();
}

fn onSave(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const r = TabCtx.resolve(user) orelse return;
    r.view.saveTab(r.tab);
}

fn onSaveAs(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const r = TabCtx.resolve(user) orelse return;
    r.view.saveTabAs(r.tab);
}

fn onRevert(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const r = TabCtx.resolve(user) orelse return;
    r.view.revertTab(r.tab);
}

fn onCopyFullPath(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const r = TabCtx.resolve(user) orelse return;
    const spec = r.tab.spec orelse return;
    var buf: [4096:0]u8 = undefined;
    // The PATH, not the host-qualified spec: what you paste into a
    // shell or another editor.
    const path = paths.parseSpec(spec).path;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    clipboard.copyToClipboard(@ptrCast(r.view.area), z);
    r.view.setStatusText(z.ptr);
}

fn onCopyRelativePath(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const r = TabCtx.resolve(user) orelse return;
    const spec = r.tab.spec orelse return;
    const project = r.tab.project orelse return;
    const path = paths.parseSpec(spec).path;
    const rel = relativeTo(project.root, path) orelse return;
    var buf: [4096:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{rel}) catch return;
    clipboard.copyToClipboard(@ptrCast(r.view.area), z);
    r.view.setStatusText(z.ptr);
}

/// `path` with `root` (a directory prefix) and its slash removed, or
/// null when the file is not under that root at all.
fn relativeTo(root: []const u8, path: []const u8) ?[]const u8 {
    const trimmed = if (root.len > 1 and root[root.len - 1] == '/') root[0 .. root.len - 1] else root;
    // A root of "/" has no trailing component to strip; everything
    // absolute is under it.
    if (std.mem.eql(u8, trimmed, "/")) {
        return if (path.len > 1 and path[0] == '/') path[1..] else null;
    }
    if (!std.mem.startsWith(u8, path, trimmed)) return null;
    const rest = path[trimmed.len..];
    if (rest.len == 0) return null;
    if (rest[0] != '/') return null;
    return rest[1..];
}

/// Reveal in a file browser: a browser tab in THIS window with the
/// file selected, or — with no window to host one (the standalone
/// editor) — the Sketerm Files identity, exactly what that window's
/// own "Reveal" button does.
fn onReveal(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const r = TabCtx.resolve(user) orelse return;
    const spec = r.tab.spec orelse return;
    if (r.view.ownerWindow()) |win| {
        win.newBrowserTabFromReveal(r.view.pane, spec, spec) catch {};
        return;
    }
    _ = siblingapp.showInFiles(spec);
}

// ---- the strip's empty area ---------------------------------------

/// TabHost strip right-click: the editor's own two ways to get a new
/// document, the browser's New Tab / Reopen precedent.
pub fn showStripMenu(view: *EditorView, x: f64, y: f64) void {
    const root = classicmenu.Root.create(view.allocator) orelse return;
    const m = root.top();
    m.itemIcon("New Document", .{ .name = "tab-new-symbolic" }, &onStripNew, @ptrCast(view));
    m.itemIcon("Open File…", .{ .name = "document-open-symbolic" }, &onStripOpen, @ptrCast(view));
    if (view.closed_docs.items.len > 0) {
        var label: [96:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&label, "Reopen Closed Tab ({d})", .{
            view.closed_docs.items.len,
        }) catch "Reopen Closed Tab";
        m.item(text.ptr, &onReopenClosed, @ptrCast(view));
    }
    _ = root.popupVia(view.tabhost.widget(), view.root_box, x, y);
}

fn onStripNew(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    _ = view.newTab(null);
}

fn onStripOpen(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const view = cast.userData(EditorView, user);
    view.openPicker();
}

test "relativeTo strips the project root and its slash" {
    const t = std.testing;
    try t.expectEqualStrings("src/main.zig", relativeTo("/home/x/proj", "/home/x/proj/src/main.zig").?);
    try t.expectEqualStrings("src/main.zig", relativeTo("/home/x/proj/", "/home/x/proj/src/main.zig").?);
    // A sibling directory that merely shares a prefix is not inside.
    try t.expect(relativeTo("/home/x/proj", "/home/x/projector/a.txt") == null);
    // The root itself is not a relative path.
    try t.expect(relativeTo("/home/x/proj", "/home/x/proj") == null);
    try t.expectEqualStrings("a.txt", relativeTo("/", "/a.txt").?);
}

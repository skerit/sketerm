//! The Open With chooser: a modal AdwDialog listing the host's own
//! applications (remote files), the recommended local ones, every other
//! installed application, and a custom command, with a live search and
//! the "Always use" association switch. The file browser and the image
//! viewer (local-only, `view == null`) share it.
//!
//! Lifetime: the dialog owns its `Ctx` through the "closed" handler's
//! GDestroyNotify (CLAUDE.md mechanism 1), so the ctx dies at the
//! dialog's finalize, after every child widget. The browser's
//! `BrowserView.openwith` slot is the liveness fence for the async host
//! `apps` reply: "closed" clears it, and a view tearing down first
//! severs `Ctx.view` through `sever` (the nullable back-pointer
//! variant), so neither side ever reaches the other after it is gone.

const std = @import("std");
const c = @import("../../c.zig").c;

const BrowserView = @import("view.zig").BrowserView;
const Entry = @import("types.zig").Entry;
const WireApp = @import("types.zig").WireApp;
const buildHostExecCmd = @import("../../filebrowser/desktop.zig").buildHostExecCmd;
const iconload = @import("../iconload.zig");
const open = @import("open.zig");
const render = @import("render.zig");
const render_kick = @import("../../util/render_kick.zig");
const rules = @import("../../filebrowser/openwith.zig");
const cast = @import("../../util/cast.zig");

const APP_ICON_PX = 32;
const FILE_ICON_PX = 48;

pub const Options = struct {
    allocator: std.mem.Allocator,
    /// Any widget in the window the dialog is modal over.
    parent: *c.GtkWidget,
    path: []const u8,
    /// The browser the file lives in; null = local-only chooser.
    view: ?*BrowserView = null,
    /// The file's host; null = a local file.
    host: ?[]const u8 = null,
};

const Choice = union(enum) {
    none,
    local: usize,
    host: usize,
    custom,
};

const Kind = enum { local, host };

/// One application row; arena-allocated, lives as long as the ctx.
const AppRow = struct {
    ctx: *Ctx,
    kind: Kind,
    index: usize,
    row: *c.GtkWidget,
    check: *c.GtkWidget,
    name: []const u8,
    id: []const u8,
    program: []const u8,
    section: *Section,
};

const Section = struct {
    group: *c.GtkWidget,
    list: *c.GtkWidget,
    rows: std.ArrayList(*AppRow) = .empty,
    /// Header suffix showing "N of M" while a search is active.
    count: ?*c.GtkWidget = null,
    /// A non-app row (host loading / not connected / empty).
    status_row: ?*c.GtkWidget = null,
};

const HostApp = struct { name: []const u8, exec: []const u8 };

pub const Ctx = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    view: ?*BrowserView,
    host: ?[]const u8,
    path: []const u8,
    content_type: ?[:0]const u8,
    description: []const u8,
    mime: []const u8,
    dialog: *c.AdwDialog,
    kick_root: ?*c.GtkWidget,
    open_btn: *c.GtkWidget = undefined,
    search: *c.GtkWidget = undefined,
    always: *c.GtkWidget = undefined,
    error_label: *c.GtkWidget = undefined,
    empty_status: *c.GtkWidget = undefined,
    custom_entry: *c.GtkWidget = undefined,
    custom_check: *c.GtkWidget = undefined,
    host_section: ?*Section = null,
    local_section: *Section = undefined,
    all_section: *Section = undefined,
    local_apps: std.ArrayList(*c.GAppInfo) = .empty,
    host_apps: std.ArrayList(HostApp) = .empty,
    choice: Choice = .none,
    /// In-flight host `apps` request (0 = none).
    req: u32 = 0,
    closed: bool = false,

    fn a(self: *Ctx) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn free(user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(Ctx, user);
        self.unlinkView();
        for (self.local_apps.items) |app| c.g_object_unref(app);
        self.local_apps.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn unlinkView(self: *Ctx) void {
        const v = self.view orelse return;
        if (v.openwith == self) v.openwith = null;
        self.view = null;
    }
};

/// Build and present the chooser. @return the dialog, or null when
/// nothing could be shown.
pub fn present(opts: Options) ?*c.AdwDialog {
    if (opts.view) |v| {
        if (v.openwith) |old| sever(old);
    }
    const ctx = opts.allocator.create(Ctx) catch return null;
    const dialog: *c.AdwDialog = @ptrCast(@alignCast(c.adw_dialog_new() orelse {
        opts.allocator.destroy(ctx);
        return null;
    }));
    ctx.* = .{
        .allocator = opts.allocator,
        .arena = std.heap.ArenaAllocator.init(opts.allocator),
        .view = opts.view,
        .host = null,
        .path = "",
        .content_type = null,
        .description = "",
        .mime = "",
        .dialog = dialog,
        .kick_root = @ptrCast(@alignCast(c.gtk_widget_get_root(opts.parent))),
    };
    // From here on the dialog owns ctx: "closed"'s destroy-notify is its
    // one free, even when building below fails part way.
    _ = c.g_signal_connect_data(dialog, "closed", @ptrCast(&onClosed), @ptrCast(ctx), @ptrCast(&Ctx.free), c.G_CONNECT_DEFAULT);
    const ar = ctx.a();
    ctx.path = ar.dupe(u8, opts.path) catch return abandon(dialog);
    ctx.host = if (opts.host) |h| (ar.dupe(u8, h) catch return abandon(dialog)) else null;
    if (opts.view) |v| v.openwith = ctx;
    resolveType(ctx);

    c.adw_dialog_set_title(dialog, "Open With");
    c.adw_dialog_set_content_width(dialog, 480);
    c.adw_dialog_set_content_height(dialog, 640);

    const tv = c.adw_toolbar_view_new();
    const tvv: *c.AdwToolbarView = @ptrCast(@alignCast(tv));
    c.adw_toolbar_view_add_top_bar(tvv, buildHeaderBar(ctx));
    c.adw_toolbar_view_add_top_bar(tvv, buildFileInfo(ctx, opts.parent));
    c.adw_toolbar_view_set_content(tvv, buildBody(ctx, opts.parent) catch return abandon(dialog));
    c.adw_toolbar_view_add_bottom_bar(tvv, buildBottom(ctx));
    c.adw_dialog_set_child(dialog, tv);
    c.adw_dialog_set_default_widget(dialog, ctx.open_btn);
    c.adw_dialog_set_focus(dialog, ctx.search);
    refreshChoice(ctx);
    applyFilter(ctx);

    if (ctx.kick_root) |root|
        _ = c.g_signal_connect_data(dialog, "closed", @ptrCast(&render_kick.onDialogClosed), @ptrCast(root), null, c.G_CONNECT_DEFAULT);
    c.adw_dialog_present(dialog, opts.parent);
    render_kick.dialogPresented(ctx.kick_root);
    requestHostApps(ctx);
    return dialog;
}

/// A half-built dialog is never shown: sinking and dropping it runs
/// "closed"-less finalize, whose destroy-notify frees the ctx.
fn abandon(dialog: *c.AdwDialog) ?*c.AdwDialog {
    _ = c.g_object_ref_sink(dialog);
    c.g_object_unref(dialog);
    return null;
}

/// The view is going away: drop the back-pointer and close the dialog.
pub fn sever(ctx: *Ctx) void {
    ctx.unlinkView();
    ctx.req = 0;
    // A window tearing down disposes the dialog without "closed";
    // an unparented dialog is already on its way out.
    if (!ctx.closed and c.gtk_widget_get_parent(@ptrCast(@alignCast(ctx.dialog))) != null)
        c.adw_dialog_force_close(ctx.dialog);
}

/// Whether a daemon reply with `req` answers this chooser's `apps` query.
pub fn wantsReply(ctx: *Ctx, req: u32) bool {
    return !ctx.closed and ctx.req != 0 and ctx.req == req;
}

fn onClosed(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    ctx.closed = true;
    ctx.req = 0;
    ctx.unlinkView();
}

fn resolveType(ctx: *Ctx) void {
    const ar = ctx.a();
    const ct = open.guessContentType(std.fs.path.basename(ctx.path)) orelse return;
    defer c.g_free(ct);
    ctx.content_type = ar.dupeSentinel(u8, std.mem.span(@as([*:0]const u8, @ptrCast(ct))), 0) catch null;
    if (c.g_content_type_get_description(ct)) |d| {
        defer c.g_free(d);
        ctx.description = ar.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(d)))) catch "";
    }
    if (c.g_content_type_get_mime_type(ct)) |m| {
        defer c.g_free(m);
        ctx.mime = ar.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(m)))) catch "";
    }
}

fn z(ctx: *Ctx, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.allocPrintSentinel(ctx.a(), fmt, args, 0) catch "";
}

// ── chrome ───────────────────────────────────────────────────────

fn buildHeaderBar(ctx: *Ctx) *c.GtkWidget {
    const hb = c.adw_header_bar_new();
    const hbv: *c.AdwHeaderBar = @ptrCast(@alignCast(hb));
    c.adw_header_bar_set_show_start_title_buttons(hbv, 0);
    c.adw_header_bar_set_show_end_title_buttons(hbv, 0);
    const cancel = c.gtk_button_new_with_label("Cancel");
    _ = c.g_signal_connect_data(cancel, "clicked", @ptrCast(&onCancel), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_header_bar_pack_start(hbv, cancel);
    const open_btn = c.gtk_button_new_with_label("Open");
    c.gtk_widget_add_css_class(open_btn, "suggested-action");
    _ = c.g_signal_connect_data(open_btn, "clicked", @ptrCast(&onOpenClicked), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_header_bar_pack_end(hbv, open_btn);
    ctx.open_btn = open_btn;
    return hb;
}

fn buildFileInfo(ctx: *Ctx, anchor: *c.GtkWidget) *c.GtkWidget {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 10);
    c.gtk_widget_set_margin_start(box, 12);
    c.gtk_widget_set_margin_end(box, 12);
    c.gtk_widget_set_margin_top(box, 6);
    c.gtk_widget_set_margin_bottom(box, 8);

    const top = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
    const base = std.fs.path.basename(ctx.path);
    // The same icon the listing shows: the type guessed from the name.
    const entry: Entry = .{ .name = @constCast(base), .kind = @constCast("file"), .size = 0, .mode = 0, .mtime_ms = 0, .target = null, .tdir = false };
    if (render.entryIconImage(anchor, entry, FILE_ICON_PX)) |img| {
        c.gtk_widget_set_valign(img, c.GTK_ALIGN_START);
        c.gtk_box_append(@ptrCast(top), img);
    }
    const text = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    c.gtk_widget_set_hexpand(text, 1);
    const name = c.gtk_label_new(z(ctx, "{s}", .{base}).ptr);
    c.gtk_widget_add_css_class(name, "heading");
    c.gtk_box_append(@ptrCast(text), infoLabel(name));
    const type_line = if (ctx.description.len > 0 and ctx.mime.len > 0)
        z(ctx, "{s} · {s}", .{ ctx.description, ctx.mime })
    else
        z(ctx, "{s}", .{if (ctx.mime.len > 0) ctx.mime else "Unknown type"});
    c.gtk_box_append(@ptrCast(text), dimLabel(type_line));
    var lbuf: [4200]u8 = undefined;
    const home: ?[]const u8 = if (ctx.host == null) (if (c.g_get_home_dir()) |h| std.mem.span(@as([*:0]const u8, @ptrCast(h))) else null) else null;
    const loc = rules.displayLocation(&lbuf, ctx.host, std.fs.path.dirname(ctx.path) orelse "/", home);
    c.gtk_box_append(@ptrCast(text), dimLabel(z(ctx, "{s}", .{loc})));
    c.gtk_box_append(@ptrCast(top), text);
    c.gtk_box_append(@ptrCast(box), top);

    const search = c.gtk_search_entry_new();
    c.gtk_search_entry_set_placeholder_text(@ptrCast(@alignCast(search)), "Search applications");
    _ = c.g_signal_connect_data(search, "search-changed", @ptrCast(&onSearchChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(search, "activate", @ptrCast(&onSearchActivate), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), search);
    ctx.search = search;
    return box;
}

fn infoLabel(label: *c.GtkWidget) *c.GtkWidget {
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_MIDDLE);
    return label;
}

fn dimLabel(text: [:0]const u8) *c.GtkWidget {
    const l = c.gtk_label_new(text.ptr);
    c.gtk_widget_add_css_class(l, "dim-label");
    c.gtk_widget_add_css_class(l, "caption");
    return infoLabel(l);
}

fn buildBody(ctx: *Ctx, anchor: *c.GtkWidget) !*c.GtkWidget {
    const col = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 18);
    c.gtk_widget_set_margin_start(col, 12);
    c.gtk_widget_set_margin_end(col, 12);
    c.gtk_widget_set_margin_top(col, 12);
    c.gtk_widget_set_margin_bottom(col, 12);

    // The custom check leads the radio group; it is never shown (the
    // entry row itself is the custom choice's face).
    ctx.custom_check = c.gtk_check_button_new();

    const remote = ctx.host != null;
    if (remote) {
        const host = ctx.host.?;
        const sec = try newSection(ctx, z(ctx, "On {s}", .{host}), "Edits the file in place on the host. Nothing is copied.");
        ctx.host_section = sec;
        c.gtk_box_append(@ptrCast(col), sec.group);
    }
    ctx.local_section = try newSection(
        ctx,
        if (remote) "On This Computer" else "Recommended",
        if (remote) "Local applications open the file through Sketerm's mount of the host, or a cached copy when the host cannot be mounted." else null,
    );
    c.gtk_box_append(@ptrCast(col), ctx.local_section.group);
    ctx.all_section = try newSection(ctx, "All Applications", null);
    const count = c.gtk_label_new("");
    c.gtk_widget_add_css_class(count, "dim-label");
    c.gtk_widget_add_css_class(count, "caption");
    c.adw_preferences_group_set_header_suffix(@ptrCast(@alignCast(ctx.all_section.group)), count);
    ctx.all_section.count = count;
    c.gtk_box_append(@ptrCast(col), ctx.all_section.group);

    const empty = c.gtk_label_new("No applications match");
    c.gtk_widget_add_css_class(empty, "dim-label");
    c.gtk_widget_set_margin_top(empty, 12);
    c.gtk_widget_set_visible(empty, 0);
    ctx.empty_status = empty;
    c.gtk_box_append(@ptrCast(col), empty);

    c.gtk_box_append(@ptrCast(col), buildCustom(ctx));

    try loadLocalApps(ctx, anchor);
    if (ctx.host_section) |sec| setHostStatus(ctx, sec, rules.hostState(true, hostConnected(ctx), null));

    const scroll = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(@alignCast(scroll)), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_widget_set_vexpand(scroll, 1);
    c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(scroll)), col);
    return scroll;
}

fn newSection(ctx: *Ctx, title: [:0]const u8, description: ?[*:0]const u8) !*Section {
    const group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(group)), title.ptr);
    if (description) |d| c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)), d);
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(@alignCast(list)), c.GTK_SELECTION_NONE);
    c.gtk_widget_add_css_class(list, "boxed-list");
    // Double-click opens at once; a single click (row activation) only
    // selects. Capture phase: the list's own gesture must not hide it.
    const gesture = c.gtk_gesture_click_new();
    c.gtk_event_controller_set_propagation_phase(@ptrCast(gesture), c.GTK_PHASE_CAPTURE);
    _ = c.g_signal_connect_data(gesture, "pressed", @ptrCast(&onListPressed), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_controller(list, @ptrCast(gesture));
    c.adw_preferences_group_add(@ptrCast(@alignCast(group)), list);
    const sec = try ctx.a().create(Section);
    sec.* = .{ .group = group, .list = list };
    return sec;
}

fn buildCustom(ctx: *Ctx) *c.GtkWidget {
    const group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(group)), "Custom Command");
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(@alignCast(list)), c.GTK_SELECTION_NONE);
    c.gtk_widget_add_css_class(list, "boxed-list");
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Command, for example: gimp %f");
    c.adw_preferences_row_set_use_markup(@ptrCast(@alignCast(row)), 0);
    c.adw_entry_row_add_prefix(@ptrCast(@alignCast(row)), c.gtk_image_new_from_icon_name("utilities-terminal-symbolic"));
    c.gtk_widget_set_visible(ctx.custom_check, 0);
    c.adw_entry_row_add_suffix(@ptrCast(@alignCast(row)), ctx.custom_check);
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&onCustomChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(row, "entry-activated", @ptrCast(&onCustomActivated), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_entry_row_set_show_apply_button(@ptrCast(@alignCast(row)), 0);
    _ = c.g_signal_connect_data(ctx.custom_check, "toggled", @ptrCast(&onCustomToggled), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_list_box_append(@ptrCast(@alignCast(list)), row);
    c.adw_preferences_group_add(@ptrCast(@alignCast(group)), list);
    ctx.custom_entry = row;
    return group;
}

fn buildBottom(ctx: *Ctx) *c.GtkWidget {
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_margin_start(box, 12);
    c.gtk_widget_set_margin_end(box, 12);
    c.gtk_widget_set_margin_top(box, 8);
    c.gtk_widget_set_margin_bottom(box, 12);
    const err = c.gtk_label_new("");
    c.gtk_widget_add_css_class(err, "error");
    c.gtk_label_set_wrap(@ptrCast(err), 1);
    c.gtk_label_set_xalign(@ptrCast(err), 0);
    c.gtk_widget_set_visible(err, 0);
    ctx.error_label = err;
    c.gtk_box_append(@ptrCast(box), err);
    const list = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(@alignCast(list)), c.GTK_SELECTION_NONE);
    c.gtk_widget_add_css_class(list, "boxed-list");
    const row = c.adw_switch_row_new();
    c.adw_preferences_row_set_use_markup(@ptrCast(@alignCast(row)), 0);
    const what = if (ctx.description.len > 0) ctx.description else "This File Type";
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), z(ctx, "Always use for {s}", .{what}).ptr);
    c.gtk_list_box_append(@ptrCast(@alignCast(list)), row);
    c.gtk_box_append(@ptrCast(box), list);
    ctx.always = row;
    return box;
}

// ── rows ─────────────────────────────────────────────────────────

fn addAppRow(
    ctx: *Ctx,
    sec: *Section,
    kind: Kind,
    index: usize,
    name: []const u8,
    id: []const u8,
    program: []const u8,
    subtitle: ?[]const u8,
    icon: *c.GtkWidget,
    tag: ?[*:0]const u8,
) !void {
    const ar = ctx.a();
    const row = c.adw_action_row_new();
    const rowv: *c.AdwActionRow = @ptrCast(@alignCast(row));
    c.adw_preferences_row_set_use_markup(@ptrCast(@alignCast(row)), 0);
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), (try ar.dupeSentinel(u8, name, 0)).ptr);
    if (subtitle) |s| {
        if (s.len > 0) {
            c.adw_action_row_set_subtitle(rowv, (try ar.dupeSentinel(u8, s, 0)).ptr);
            c.adw_action_row_set_subtitle_lines(rowv, 1);
        }
    }
    c.adw_action_row_add_prefix(rowv, icon);
    if (tag) |t| {
        const l = c.gtk_label_new(t);
        c.gtk_widget_add_css_class(l, "dim-label");
        c.gtk_widget_add_css_class(l, "caption");
        c.adw_action_row_add_suffix(rowv, l);
    }
    const check = c.gtk_check_button_new();
    c.gtk_check_button_set_group(@ptrCast(@alignCast(check)), @ptrCast(@alignCast(ctx.custom_check)));
    c.gtk_widget_set_valign(check, c.GTK_ALIGN_CENTER);
    c.adw_action_row_add_suffix(rowv, check);
    c.adw_action_row_set_activatable_widget(rowv, check);
    const r = try ar.create(AppRow);
    r.* = .{
        .ctx = ctx,
        .kind = kind,
        .index = index,
        .row = row,
        .check = check,
        .name = try ar.dupe(u8, name),
        .id = try ar.dupe(u8, id),
        .program = try ar.dupe(u8, program),
        .section = sec,
    };
    try sec.rows.append(ar, r);
    c.g_object_set_data(@ptrCast(row), "sketerm-ow-row", @ptrCast(r));
    _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onRowToggled), @ptrCast(r), null, c.G_CONNECT_DEFAULT);
    c.gtk_list_box_append(@ptrCast(@alignCast(sec.list)), row);
}

fn appIcon(anchor: *c.GtkWidget, app: ?*c.GAppInfo) *c.GtkWidget {
    if (app) |ap| {
        if (c.g_app_info_get_icon(ap)) |gi| return iconload.newImageGicon(anchor, gi, APP_ICON_PX);
    }
    return iconload.newImageIcon(anchor, "application-x-executable", APP_ICON_PX);
}

fn infoName(app: *c.GAppInfo) []const u8 {
    const n = c.g_app_info_get_name(app) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(n)));
}

fn infoId(app: *c.GAppInfo) ?[]const u8 {
    const id = c.g_app_info_get_id(app) orelse return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(id)));
}

fn infoProgram(app: *c.GAppInfo) []const u8 {
    const e = c.g_app_info_get_executable(app) orelse return "";
    return rules.execProgram(std.mem.span(@as([*:0]const u8, @ptrCast(e))));
}

fn infoLess(_: void, x: *c.GAppInfo, y: *c.GAppInfo) bool {
    return rules.nameLess({}, infoName(x), infoName(y));
}

/// Keep a ref to `app` as a new row's index. @return null when it has no id or was already listed.
fn adopt(ctx: *Ctx, seen: *rules.IdSet, app: *c.GAppInfo) !?usize {
    const id = infoId(app) orelse return null;
    if (!try seen.add(ctx.allocator, id)) return null;
    try ctx.local_apps.append(ctx.allocator, app);
    _ = c.g_object_ref(app);
    return ctx.local_apps.items.len - 1;
}

fn loadLocalApps(ctx: *Ctx, anchor: *c.GtkWidget) !void {
    var seen: rules.IdSet = .{};
    defer seen.deinit(ctx.allocator);

    if (ctx.content_type) |ct| {
        if (c.g_app_info_get_default_for_type(ct.ptr, 0)) |def| {
            defer c.g_object_unref(def);
            if (try adopt(ctx, &seen, def)) |i| {
                try addLocalRow(ctx, anchor, ctx.local_section, i, "Default");
            }
        }
        const lists = [_][*c]c.GList{
            c.g_app_info_get_recommended_for_type(ct.ptr),
            c.g_app_info_get_fallback_for_type(ct.ptr),
        };
        for (lists) |list| {
            defer if (list != null) c.g_list_free_full(list, @ptrCast(&c.g_object_unref));
            var it = list;
            while (it != null) : (it = it.*.next) {
                const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
                if (c.g_app_info_should_show(app) == 0) continue;
                if (try adopt(ctx, &seen, app)) |i| try addLocalRow(ctx, anchor, ctx.local_section, i, null);
            }
        }
    }
    if (ctx.local_section.rows.items.len == 0)
        setStatusRow(ctx, ctx.local_section, "No application registered for this type");

    const all = c.g_app_info_get_all();
    defer if (all != null) c.g_list_free_full(all, @ptrCast(&c.g_object_unref));
    var rest: std.ArrayList(*c.GAppInfo) = .empty;
    defer rest.deinit(ctx.allocator);
    var it = all;
    while (it != null) : (it = it.*.next) {
        const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
        if (c.g_app_info_should_show(app) == 0) continue;
        const id = infoId(app) orelse continue;
        if (seen.contains(id)) continue;
        try rest.append(ctx.allocator, app);
    }
    std.mem.sort(*c.GAppInfo, rest.items, {}, infoLess);
    for (rest.items) |app| {
        if (try adopt(ctx, &seen, app)) |i| try addLocalRow(ctx, anchor, ctx.all_section, i, null);
    }
}

fn addLocalRow(ctx: *Ctx, anchor: *c.GtkWidget, sec: *Section, i: usize, tag: ?[*:0]const u8) !void {
    const app = ctx.local_apps.items[i];
    const desc: ?[]const u8 = if (c.g_app_info_get_description(app)) |d| std.mem.span(@as([*:0]const u8, @ptrCast(d))) else null;
    try addAppRow(ctx, sec, .local, i, infoName(app), infoId(app) orelse "", infoProgram(app), desc, appIcon(anchor, app), tag);
}

fn setStatusRow(ctx: *Ctx, sec: *Section, text: []const u8) void {
    if (sec.status_row) |old| {
        c.gtk_list_box_remove(@ptrCast(@alignCast(sec.list)), old);
        sec.status_row = null;
    }
    if (text.len == 0) return;
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_use_markup(@ptrCast(@alignCast(row)), 0);
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), z(ctx, "{s}", .{text}).ptr);
    c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 0);
    c.gtk_widget_add_css_class(row, "dim-label");
    sec.status_row = row;
    c.gtk_list_box_append(@ptrCast(@alignCast(sec.list)), row);
}

// ── host section ─────────────────────────────────────────────────

fn hostConnected(ctx: *Ctx) bool {
    const v = ctx.view orelse return false;
    const hc = v.hostConnFor(ctx.host) orelse return false;
    return hc.state == .ready;
}

fn setHostStatus(ctx: *Ctx, sec: *Section, state: rules.HostState) void {
    setStatusRow(ctx, sec, state.message() orelse "");
    if (state == .loading) {
        if (sec.status_row) |row| {
            const sp = c.gtk_spinner_new();
            c.gtk_spinner_start(@ptrCast(@alignCast(sp)));
            c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), sp);
        }
    }
}

fn requestHostApps(ctx: *Ctx) void {
    const sec = ctx.host_section orelse return;
    const v = ctx.view orelse return;
    const hc = v.hostConnFor(ctx.host) orelse return;
    if (hc.state != .ready) return;
    ctx.req = v.nextReq();
    if (!v.sendOpOk(hc, .{ .req = ctx.req, .op = "apps", .path = "/" })) {
        ctx.req = 0;
        setHostStatus(ctx, sec, rules.hostState(true, false, null));
        applyFilter(ctx);
    }
}

/// The host's `apps` reply: rows for the apps declaring the file's MIME
/// type (or every app when none does).
pub fn onHostApps(ctx: *Ctx, ok: bool, apps: []const WireApp) void {
    ctx.req = 0;
    const sec = ctx.host_section orelse return;
    if (ctx.closed) return;
    var picked: std.ArrayList(usize) = .empty;
    defer picked.deinit(ctx.allocator);
    if (ok) rules.pickHostApps(ctx.allocator, apps, ctx.mime, &picked) catch {};
    const ar = ctx.a();
    const host = ctx.host orelse "";
    const sub = std.fmt.allocPrint(ar, "Runs on {s}, its window forwards here", .{host}) catch "";
    const anchor: *c.GtkWidget = @ptrCast(@alignCast(ctx.dialog));
    var shown: usize = 0;
    for (picked.items) |i| {
        const app = apps[i];
        const ha: HostApp = .{
            .name = ar.dupe(u8, app.name) catch continue,
            .exec = ar.dupe(u8, app.exec) catch continue,
        };
        ctx.host_apps.append(ar, ha) catch continue;
        addAppRow(ctx, sec, .host, ctx.host_apps.items.len - 1, ha.name, "", rules.execProgram(ha.exec), sub, appIcon(anchor, null), null) catch continue;
        shown += 1;
    }
    setHostStatus(ctx, sec, rules.hostState(true, true, .{ .ok = ok, .shown = shown }));
    applyFilter(ctx);
}

// ── selection, search, launch ────────────────────────────────────

fn onRowToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const r = cast.userData(AppRow, user);
    if (c.gtk_check_button_get_active(check) == 0) return;
    r.ctx.choice = switch (r.kind) {
        .local => .{ .local = r.index },
        .host => .{ .host = r.index },
    };
    refreshChoice(r.ctx);
}

fn onCustomToggled(check: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    if (c.gtk_check_button_get_active(check) != 0) {
        ctx.choice = .custom;
    } else if (ctx.choice == .custom) {
        ctx.choice = .none;
    }
    refreshChoice(ctx);
}

fn customText(ctx: *Ctx) []const u8 {
    const t = c.gtk_editable_get_text(@ptrCast(@alignCast(ctx.custom_entry))) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(t)));
}

fn onCustomChanged(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const has = rules.customCommand(customText(ctx)) != null;
    c.gtk_check_button_set_active(@ptrCast(@alignCast(ctx.custom_check)), @intFromBool(has));
    refreshChoice(ctx);
}

fn onCustomActivated(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    if (ctx.choice == .custom) launchChoice(ctx);
}

/// Open-button sensitivity and the "Always use" switch, from the choice.
fn refreshChoice(ctx: *Ctx) void {
    const ready = switch (ctx.choice) {
        .none => false,
        .custom => rules.customCommand(customText(ctx)) != null,
        else => true,
    };
    c.gtk_widget_set_sensitive(ctx.open_btn, @intFromBool(ready));
    const row: *c.AdwActionRow = @ptrCast(@alignCast(ctx.always));
    if (ctx.content_type == null) {
        c.gtk_widget_set_sensitive(ctx.always, 0);
        c.adw_action_row_set_subtitle(row, "The file type is unknown, so there is nothing to associate");
    } else if (ctx.choice == .host) {
        c.gtk_widget_set_sensitive(ctx.always, 0);
        c.adw_action_row_set_subtitle(row, "Host applications have no association on this computer");
    } else {
        c.gtk_widget_set_sensitive(ctx.always, 1);
        c.adw_action_row_set_subtitle(row, z(ctx, "Makes the chosen application the default for {s} on this computer", .{ctx.mime}).ptr);
    }
}

fn query(ctx: *Ctx) []const u8 {
    const t = c.gtk_editable_get_text(@ptrCast(@alignCast(ctx.search))) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(t)));
}

fn applyFilter(ctx: *Ctx) void {
    const q = query(ctx);
    const searching = std.mem.trim(u8, q, " \t").len > 0;
    var total: usize = 0;
    const sections = [_]?*Section{ ctx.host_section, ctx.local_section, ctx.all_section };
    for (sections) |maybe| {
        const sec = maybe orelse continue;
        var visible: usize = 0;
        for (sec.rows.items) |r| {
            const show = rules.matches(q, &.{ r.name, r.id, r.program });
            c.gtk_widget_set_visible(r.row, @intFromBool(show));
            if (show) visible += 1;
        }
        total += visible;
        // A status row (loading, not connected) stays meaningful during
        // a search; the local placeholder does not.
        const keep_status = sec.status_row != null and (sec == ctx.host_section or !searching);
        if (sec.status_row) |sr| c.gtk_widget_set_visible(sr, @intFromBool(keep_status));
        c.gtk_widget_set_visible(sec.group, @intFromBool(visible > 0 or keep_status));
        if (sec.count) |cl| {
            c.gtk_label_set_text(@ptrCast(cl), if (searching) z(ctx, "{d} of {d}", .{ visible, sec.rows.items.len }).ptr else "");
        }
    }
    c.gtk_widget_set_visible(ctx.empty_status, @intFromBool(searching and total == 0));
}

fn onSearchChanged(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    applyFilter(cast.userData(Ctx, user));
}

/// Enter in the search: open the choice, else pick the first match.
fn onSearchActivate(_: ?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    if (ctx.choice != .none) return launchChoice(ctx);
    const sections = [_]?*Section{ ctx.host_section, ctx.local_section, ctx.all_section };
    for (sections) |maybe| {
        const sec = maybe orelse continue;
        for (sec.rows.items) |r| {
            if (c.gtk_widget_get_visible(r.row) == 0) continue;
            c.gtk_check_button_set_active(@ptrCast(@alignCast(r.check)), 1);
            return;
        }
    }
}

fn onListPressed(gesture: *c.GtkGestureClick, n_press: c_int, _: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    if (n_press != 2) return;
    const list = c.gtk_event_controller_get_widget(@ptrCast(gesture));
    const row = c.gtk_list_box_get_row_at_y(@ptrCast(@alignCast(list)), @intFromFloat(y)) orelse return;
    const data = c.g_object_get_data(@ptrCast(row), "sketerm-ow-row") orelse return;
    const r = cast.userData(AppRow, data);
    c.gtk_check_button_set_active(@ptrCast(@alignCast(r.check)), 1);
    launchChoice(ctx);
}

fn onCancel(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    _ = c.adw_dialog_close(ctx.dialog);
}

fn onOpenClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    launchChoice(cast.userData(Ctx, user));
}

fn showError(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
    const msg = z(ctx, fmt, args);
    c.gtk_label_set_text(@ptrCast(ctx.error_label), msg.ptr);
    c.gtk_widget_set_visible(ctx.error_label, 1);
    if (ctx.view) |v| v.setStatus(msg);
}

fn status(ctx: *Ctx, comptime fmt: []const u8, args: anytype) void {
    if (ctx.view) |v| v.setStatusFmt(fmt, args);
}

fn launchChoice(ctx: *Ctx) void {
    if (ctx.closed) return;
    const base = std.fs.path.basename(ctx.path);
    switch (ctx.choice) {
        .none => return,
        .host => |i| return launchOnHost(ctx, ctx.host_apps.items[i]),
        else => {},
    }
    // A local launch: a chosen application or a custom command line.
    var err: [*c]c.GError = null;
    defer if (err != null) c.g_error_free(err);
    var ebuf: [512]u8 = undefined;
    var label: []const u8 = "";
    var opener: []const u8 = "";
    const info: *c.GAppInfo = switch (ctx.choice) {
        .local => |i| blk: {
            const app = ctx.local_apps.items[i];
            label = infoName(app);
            opener = infoId(app) orelse "";
            _ = c.g_object_ref(app);
            break :blk app;
        },
        .custom => blk: {
            const cmd = rules.customCommand(customText(ctx)) orelse return;
            label = cmd;
            opener = rules.encodeCommand(ctx.a(), cmd) catch return;
            break :blk open.commandAppInfo(cmd, &err) orelse
                return showError(ctx, "Could not use \"{s}\": {s}", .{ cmd, open.errorText(err, &ebuf) });
        },
        else => unreachable,
    };
    defer c.g_object_unref(info);

    if (c.adw_switch_row_get_active(@ptrCast(@alignCast(ctx.always))) != 0) {
        if (ctx.content_type) |ct| {
            if (c.g_app_info_set_as_default_for_type(info, ct.ptr, &err) == 0)
                return showError(ctx, "Could not make {s} the default: {s}", .{ label, open.errorText(err, &ebuf) });
            // Saving a custom command writes a desktop file; launch by
            // the id it got so a remote open resolves it like any app.
            if (ctx.choice == .custom) {
                if (infoId(info)) |id| opener = ctx.a().dupe(u8, id) catch opener;
            }
        }
    }

    if (ctx.host) |host| {
        const v = ctx.view orelse return showError(ctx, "The file browser closed", .{});
        const hc = v.hostConnFor(host) orelse return showError(ctx, "Not connected to {s}", .{host});
        v.openRemoteFileHc(hc, ctx.path, opener);
        _ = c.adw_dialog_close(ctx.dialog);
        return;
    }
    if (open.launchInfo(info, ctx.path, &ebuf)) |why|
        return showError(ctx, "Could not open {s} with {s}: {s}", .{ base, label, why });
    status(ctx, "opened {s} with {s}", .{ base, label });
    _ = c.adw_dialog_close(ctx.dialog);
}

fn launchOnHost(ctx: *Ctx, app: HostApp) void {
    const v = ctx.view orelse return showError(ctx, "The file browser closed", .{});
    const host = ctx.host orelse return;
    const cb = v.on_host_exec orelse return showError(ctx, "This window cannot run applications on {s}", .{host});
    const hctx = v.hooks_ctx orelse return showError(ctx, "This window cannot run applications on {s}", .{host});
    const cmd = buildHostExecCmd(ctx.allocator, app.exec, ctx.path) orelse
        return showError(ctx, "Could not build the command for {s}", .{app.name});
    defer ctx.allocator.free(cmd);
    const cz = ctx.a().dupeSentinel(u8, cmd, 0) catch return;
    cb(hctx, host, cz);
    v.setStatusFmt("opening {s} with {s} on {s} (its window forwards here)…", .{ std.fs.path.basename(ctx.path), app.name, host });
    _ = c.adw_dialog_close(ctx.dialog);
}

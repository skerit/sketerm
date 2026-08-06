//! "Open Saved Panel…" — the user's own way back to a stored panel
//! document, without asking the assistant that authored it.
//!
//! Panels persist under `(session, name)` (src/ipc/panelstore.zig) and
//! an assistant reopens one over MCP. This dialog is the GUI half of
//! the same retrieval: it lists the SESSION of the focused pane — the
//! same scoping rule the rest of the subsystem uses, so the user sees
//! his own pane's panels and not another assistant's — and hands the
//! chosen name to `panelhost.openSaved`, which mounts it through the
//! one `showDocument` path `panel-show` uses. There is deliberately no
//! second way to mount a panel.
//!
//! A document that no longer parses is LISTED, with the parser's own
//! message as its subtitle, and is not activatable: `panelstore`
//! distinguishes a corrupt file from an invalid one on purpose, and
//! hiding the broken one would read as "my panel is gone".
//!
//! Deleting is a per-row destructive button, confirmed with an
//! AdwAlertDialog (the codebase's confirm pattern), not a palette
//! action of its own: it needs this list to pick from anyway.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const render_kick = @import("../util/render_kick.zig");
const panelstore = @import("../ipc/panelstore.zig");
const panelhost = @import("panelhost.zig");
const Doc = @import("panel/doc.zig");
const Pane = @import("pane.zig").Pane;
const window_mod = @import("window.zig");
const Window = window_mod.Window;

/// Where an activated row lands. A saved panel gets a TAB of its own:
/// the user opened this from some pane, and taking that pane's shell
/// away (target `.pane`) is not what "open" means to him.
const OPEN_TARGET: panelhost.Target = .tab;

const RowCtx = struct {
    ctx: *Ctx,
    /// Arena-owned.
    name: [:0]const u8,
    /// False when the stored document no longer parses.
    ok: bool,
};

const Ctx = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *Window,
    dialog: *c.AdwDialog,
    listbox: *c.GtkWidget,
    /// The pane whose session scoped the listing. Re-validated against
    /// the window's live panes before use — a remote shell can exit
    /// while the dialog is up.
    pane: ?*Pane,
};

/// Heap context for one confirmed delete. Owns copies of everything it
/// needs (and a reference to the two widgets it touches), so it stays
/// valid however the picker behind it ends.
const DeleteCtx = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    /// Owned.
    session: []u8,
    /// Owned.
    name: []u8,
    /// Referenced.
    listbox: *c.GtkWidget,
    /// Referenced.
    row: *c.GtkWidget,

    fn destroy(self: *DeleteCtx) void {
        c.g_object_unref(@ptrCast(self.listbox));
        c.g_object_unref(@ptrCast(self.row));
        self.allocator.free(self.session);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
};

pub fn open(window: *Window) void {
    openFor(window, window.focusedPane());
}

fn openFor(window: *Window, pane: ?*Pane) void {
    const allocator = window.allocator;
    const session = panelhost.sessionForPane(pane);

    const entries = panelstore.list(allocator, session) catch |err| {
        var buf: [160]u8 = undefined;
        window_mod.showToast(window, std.fmt.bufPrint(
            &buf,
            "Could not read saved panels: {s}",
            .{@errorName(err)},
        ) catch "Could not read saved panels");
        return;
    };
    defer panelstore.freeList(allocator, entries);

    const ctx = allocator.create(Ctx) catch return;
    ctx.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .window = window,
        .dialog = undefined,
        .listbox = undefined,
        .pane = pane,
    };
    const arena = ctx.arena.allocator();

    const dialog = c.adw_dialog_new();
    c.adw_dialog_set_title(dialog, "Open Saved Panel");
    c.adw_dialog_set_content_width(dialog, 560);
    c.adw_dialog_set_content_height(dialog, 420);
    ctx.dialog = @ptrCast(@alignCast(dialog));
    _ = c.g_signal_connect_data(
        dialog,
        "closed",
        @ptrCast(&onClosed),
        @ptrCast(ctx),
        @ptrCast(&freeCtx),
        c.G_CONNECT_DEFAULT,
    );

    const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_margin_start(root, 12);
    c.gtk_widget_set_margin_end(root, 12);
    c.gtk_widget_set_margin_top(root, 12);
    c.gtk_widget_set_margin_bottom(root, 12);

    // Which session's panels these are: several assistants share one
    // sketerm, so "these are mine" has to be visible.
    {
        var head_buf: [160]u8 = undefined;
        const text = std.fmt.bufPrintZ(&head_buf, "Panels saved in session {s}", .{session}) catch
            "Panels saved in this session";
        const label = c.gtk_label_new(text.ptr);
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_widget_add_css_class(label, "dim-label");
        c.gtk_widget_set_margin_bottom(label, 8);
        c.gtk_box_append(@ptrCast(root), label);
    }

    const scrolled = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scrolled, 1);
    c.gtk_scrolled_window_set_policy(@ptrCast(@alignCast(scrolled)), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);

    const listbox = c.gtk_list_box_new();
    c.gtk_list_box_set_selection_mode(@ptrCast(@alignCast(listbox)), c.GTK_SELECTION_BROWSE);
    c.gtk_widget_add_css_class(listbox, "boxed-list");
    c.gtk_scrolled_window_set_child(@ptrCast(@alignCast(scrolled)), listbox);
    c.gtk_box_append(@ptrCast(root), scrolled);
    ctx.listbox = listbox;

    if (entries.len == 0) {
        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "No saved panels in this session");
        c.adw_action_row_set_subtitle(
            @ptrCast(@alignCast(row)),
            "An assistant saves one with the ui_save tool; it shows up here.",
        );
        c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 0);
        c.gtk_list_box_append(@ptrCast(@alignCast(listbox)), row);
    }

    for (entries) |e| {
        const name_z = arena.allocSentinel(u8, e.name.len, 0) catch continue;
        @memcpy(name_z, e.name);
        const rctx = arena.create(RowCtx) catch continue;
        rctx.* = .{ .ctx = ctx, .name = name_z, .ok = e.ok };

        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), name_z.ptr);
        c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle(arena, session, e).ptr);
        c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), if (e.ok) 1 else 0);
        // Selectable even when broken: the row IS the report, and it
        // must be reachable by keyboard to be read.
        c.gtk_widget_set_focusable(@ptrCast(row), 1);

        const icon = c.gtk_image_new_from_icon_name(
            if (e.ok) "view-paged-symbolic" else "dialog-warning-symbolic",
        );
        c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), icon);
        if (!e.ok) c.gtk_widget_add_css_class(@ptrCast(row), "error");

        const del = c.gtk_button_new_from_icon_name("user-trash-symbolic");
        c.gtk_widget_add_css_class(del, "flat");
        c.gtk_widget_set_valign(del, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_tooltip_text(del, "Delete this saved panel");
        // User data is the dialog's own Ctx (managed by the dialog's
        // GDestroyNotify); which row was hit rides on the button.
        c.g_object_set_data(@ptrCast(@alignCast(del)), "panel-row", @ptrCast(rctx));
        c.g_object_set_data(@ptrCast(@alignCast(del)), "panel-row-widget", @ptrCast(row));
        _ = c.g_signal_connect_data(
            del,
            "clicked",
            @ptrCast(&onDeleteClicked),
            @ptrCast(ctx),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), del);

        c.g_object_set_data(@ptrCast(@alignCast(row)), "panel-row", @ptrCast(rctx));
        c.gtk_list_box_append(@ptrCast(@alignCast(listbox)), row);
    }

    _ = c.g_signal_connect_data(
        listbox,
        "row-activated",
        @ptrCast(&onRowActivated),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );

    c.adw_dialog_set_child(dialog, root);
    _ = c.g_signal_connect_data(
        dialog,
        "closed",
        @ptrCast(&render_kick.onDialogClosed),
        @ptrCast(window.app_window),
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.adw_dialog_present(dialog, @ptrCast(window.app_window));
    render_kick.dialogPresented(window.app_window);

    // Focus the first row so the whole dialog is keyboard-drivable:
    // Up/Down move, Enter activates (GtkListBox's own key handling).
    const first = c.gtk_list_box_get_row_at_index(@ptrCast(@alignCast(listbox)), 0);
    if (first != null) {
        c.gtk_list_box_select_row(@ptrCast(@alignCast(listbox)), first);
        _ = c.gtk_widget_grab_focus(@ptrCast(first));
    }
}

/// What the row says under the name: the document's own title plus its
/// size and age, or — for a document that no longer parses — the
/// parser's message, which is the only thing that explains why the
/// panel cannot be opened.
fn subtitle(arena: std.mem.Allocator, session: []const u8, e: panelstore.Entry) [:0]const u8 {
    if (!e.ok) {
        var diag = Doc.Diag{};
        // A page-allocator load purely to recover the message; the
        // document itself is thrown away.
        if (panelstore.load(std.heap.page_allocator, session, e.name, &diag)) |parsed| {
            var d = parsed;
            d.deinit();
        } else |_| {}
        const why = if (diag.len > 0) diag.msg() else "the stored document no longer parses";
        return std.fmt.allocPrintSentinel(arena, "Cannot be opened: {s}", .{why}, 0) catch
            "Cannot be opened: the stored document no longer parses";
    }
    const title = if (e.title.len > 0) e.title else "(untitled)";
    return std.fmt.allocPrintSentinel(
        arena,
        "{s} — {d} bytes, saved {s}",
        .{ title, e.bytes, ageText(arena, e.mtime) },
        0,
    ) catch "";
}

/// Relative age, so no timezone has to be guessed at.
fn ageText(arena: std.mem.Allocator, mtime: i64) []const u8 {
    if (mtime <= 0) return "at an unknown time";
    const now: i64 = @intCast(c.time(null));
    const secs = now - mtime;
    if (secs < 90) return "just now";
    const mins = @divTrunc(secs, 60);
    if (mins < 90) return plural(arena, mins, "minute");
    const hours = @divTrunc(mins, 60);
    if (hours < 48) return plural(arena, hours, "hour");
    return plural(arena, @divTrunc(hours, 24), "day");
}

fn plural(arena: std.mem.Allocator, n: i64, unit: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{d} {s}{s} ago", .{
        n,
        unit,
        if (n == 1) "" else "s",
    }) catch "recently";
}

/// Whether `pane` is still one of the window's live panes. The dialog
/// is modal, but a remote shell can exit under it.
fn livePane(window: *Window, pane: ?*Pane) ?*Pane {
    const p = pane orelse return null;
    for (window.panes.items) |other| {
        if (other == p) return p;
    }
    return null;
}

fn onRowActivated(_: *c.GtkListBox, row: *c.GtkListBoxRow, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const data = c.g_object_get_data(@ptrCast(@alignCast(row)), "panel-row") orelse return;
    const rctx: *RowCtx = @ptrCast(@alignCast(data));
    // A broken document's row is not activatable, so this is belt and
    // braces; either way it must never reach the store.
    if (!rctx.ok) return;

    const window = ctx.window;
    const pane = livePane(window, ctx.pane);
    // The name lives in the dialog's arena, which the force-close below
    // frees. Copy it out first.
    var name_buf: [panelstore.MAX_NAME]u8 = undefined;
    if (rctx.name.len > name_buf.len) return;
    @memcpy(name_buf[0..rctx.name.len], rctx.name);
    const name = name_buf[0..rctx.name.len];

    c.adw_dialog_force_close(@ptrCast(@alignCast(ctx.dialog)));

    var diag = Doc.Diag{};
    _ = panelhost.openSaved(window, pane, name, OPEN_TARGET, &diag) catch |err| {
        var buf: [320]u8 = undefined;
        const why = if (diag.len > 0) diag.msg() else @errorName(err);
        window_mod.showToast(window, std.fmt.bufPrint(
            &buf,
            "Could not open panel \"{s}\": {s}",
            .{ name, why },
        ) catch "Could not open the saved panel");
    };
}

fn onDeleteClicked(button: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const data = c.g_object_get_data(@ptrCast(@alignCast(button)), "panel-row") orelse return;
    const rctx: *RowCtx = @ptrCast(@alignCast(data));
    const row_data = c.g_object_get_data(@ptrCast(@alignCast(button)), "panel-row-widget") orelse return;
    const row: *c.GtkWidget = @ptrCast(@alignCast(row_data));

    const allocator = ctx.allocator;
    const session = panelhost.sessionForPane(livePane(ctx.window, ctx.pane));

    const dctx = allocator.create(DeleteCtx) catch return;
    dctx.* = .{
        .allocator = allocator,
        .window = ctx.window,
        .session = allocator.dupe(u8, session) catch {
            allocator.destroy(dctx);
            return;
        },
        .name = allocator.dupe(u8, rctx.name) catch {
            allocator.free(dctx.session);
            allocator.destroy(dctx);
            return;
        },
        .listbox = ctx.listbox,
        .row = row,
    };
    // Both widgets outlive nothing on their own, but this context does
    // survive the picker's teardown in principle — own a reference.
    _ = c.g_object_ref(@ptrCast(dctx.listbox));
    _ = c.g_object_ref(@ptrCast(dctx.row));

    var body_buf: [320]u8 = undefined;
    const body = std.fmt.bufPrintZ(
        &body_buf,
        "\"{s}\" will be removed from this session's saved panels. This cannot be undone.",
        .{rctx.name},
    ) catch "This saved panel will be removed. This cannot be undone.";

    const alert: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new("Delete saved panel?", body.ptr)));
    c.adw_alert_dialog_add_response(alert, "cancel", "Cancel");
    c.adw_alert_dialog_add_response(alert, "delete", "Delete");
    c.adw_alert_dialog_set_response_appearance(alert, "delete", c.ADW_RESPONSE_DESTRUCTIVE);
    c.adw_alert_dialog_set_default_response(alert, "cancel");
    c.adw_alert_dialog_set_close_response(alert, "cancel");
    c.adw_alert_dialog_choose(alert, ctx.window.app_window, null, onDeleteResponse, @ptrCast(dctx));
}

fn onDeleteResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const dctx = cast.userData(DeleteCtx, user);
    defer dctx.destroy();
    const alert: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
    const resp = std.mem.span(@as([*:0]const u8, @ptrCast(c.adw_alert_dialog_choose_finish(alert, result))));
    if (!std.mem.eql(u8, resp, "delete")) return;

    var msg_buf: [320]u8 = undefined;
    panelstore.delete(dctx.allocator, dctx.session, dctx.name, null) catch |err| {
        window_mod.showToast(dctx.window, std.fmt.bufPrint(
            &msg_buf,
            "Could not delete panel \"{s}\": {s}",
            .{ dctx.name, @errorName(err) },
        ) catch "Could not delete the saved panel");
        return;
    };
    c.gtk_list_box_remove(@ptrCast(@alignCast(dctx.listbox)), dctx.row);
    window_mod.showToast(dctx.window, std.fmt.bufPrint(
        &msg_buf,
        "Deleted saved panel \"{s}\"",
        .{dctx.name},
    ) catch "Deleted the saved panel");
}

fn onClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    _ = user;
    // Cleanup runs via the GDestroyNotify (`freeCtx`) attached to the
    // same signal connection.
}

fn freeCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const ctx: *Ctx = @ptrCast(@alignCast(u));
        ctx.arena.deinit();
        ctx.allocator.destroy(ctx);
    }
}

test "panel picker decls type-check" {
    // Lazy analysis: a signature error in a GTK callback no test calls
    // would otherwise slip through `zig build test`.
    std.testing.refAllDecls(@This());
}

test "the open target is a tab of its own" {
    // Opening from the palette must never eat the shell of the pane the
    // user opened it from.
    try std.testing.expectEqual(panelhost.Target.tab, OPEN_TARGET);
}

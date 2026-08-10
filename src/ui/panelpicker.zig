//! "Open Saved Panel…" — the user's own way back to a stored panel
//! document, without asking the assistant that authored it.
//!
//! Panels persist under the pane's exact daemon origin plus lifetime-unique
//! origin ID (src/ipc/panelstore.zig). This dialog is the GUI half of
//! the same retrieval: it lists that ORIGIN of the focused pane, so the
//! user never sees a same-named session from another daemon, and hands the
//! chosen document to `panelhost.openSavedDocument`, which mounts it through the
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
//!
//! Store preparation/migration, listing, file parsing, loading and deletion
//! run on the bounded worker queue below. GTK only renders worker results.

const std = @import("std");
const c = @import("../c.zig").c;
const render_kick = @import("../util/render_kick.zig");
const panelstore = @import("../ipc/panelstore.zig");
const mux_daemon = @import("../mux/daemon.zig");
const panelhost = @import("panelhost.zig");
const Doc = @import("panel/doc.zig");
const canary = @import("panel/canary.zig");
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

/// Main-thread back-pointer that outlives both the dialog and any detached
/// store worker. Workers carry a ref but never read `ctx` or touch GTK.
const PickerHandle = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    /// Main-thread-only; cleared before the dialog context is freed.
    ctx: ?*Ctx = null,

    fn retain(self: *PickerHandle) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *PickerHandle) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};

const Ctx = struct {
    pub const MAGIC: u32 = 0x504B4358; // "PKCX"
    /// Use-after-free DETECTOR, not a lifetime mechanism — see
    /// panel/canary.zig. The dialog owns this context through the
    /// GDestroyNotify on its "closed" connection; every other handler
    /// below borrows the same pointer with no notify of its own, so a
    /// stale borrow is exactly what this catches.
    magic: u32 = MAGIC,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    window: *Window,
    dialog: *c.AdwDialog,
    listbox: *c.GtkWidget,
    status_box: *c.GtkWidget,
    status_spinner: *c.GtkSpinner,
    status_label: *c.GtkLabel,
    store: StoreKey,
    handle: *PickerHandle,
    busy: bool = true,
    row_count: usize = 0,
    /// The pane whose session scoped the listing. Re-validated against
    /// the window's live panes before use — a remote shell can exit
    /// while the dialog is up.
    pane: ?*Pane,
};

/// Widget-owned context for one confirmation. The retained picker handle is
/// the only route back to the dialog after `choose` completes.
const DeleteCtx = struct {
    pub const MAGIC: u32 = 0x504B4443; // "PKDC"
    /// Detector only (panel/canary.zig): this context is owned by the
    /// alert dialog's qdata destroy-notify.
    magic: u32 = MAGIC,
    allocator: std.mem.Allocator,
    handle: *PickerHandle,
    /// Owned.
    name: []u8,
    /// Borrowed only while `handle.ctx` is live.
    row: *c.GtkWidget,

    fn destroy(self: *DeleteCtx) void {
        if (!canary.alive(self)) return;
        self.handle.release();
        self.allocator.free(self.name);
        canary.poison(self);
        self.allocator.destroy(self);
    }
};

const StoreKey = struct {
    allocator: std.mem.Allocator,
    /// Physical canonical Unix listener identity.
    daemon_origin: ?[]u8 = null,
    /// Lifetime-unique persistence key; absent only for a legacy daemon.
    origin_id: ?[]u8 = null,
    /// Session name, shown in the picker. Never part of a store path.
    session: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, pane: ?*Pane) !StoreKey {
        const p = pane orelse return .{ .allocator = allocator };
        const remote = p.terminal.remote orelse return .{ .allocator = allocator };
        // `sock:/path` carries a host string for reconnect/layout purposes but
        // its connected transport is still the exact local Unix daemon.
        if (remote.conn.transport != .local) return error.RemoteStore;
        if (remote.conn.proto == 0) return error.UnvalidatedOriginCapability;
        if (!mux_daemon.validSessionOriginId(remote.origin_id)) return error.InvalidOriginIdentity;
        const daemon_origin = try remote.conn.localDaemonOrigin(allocator);
        errdefer allocator.free(daemon_origin);
        const origin_id = try allocator.dupe(u8, remote.origin_id);
        errdefer allocator.free(origin_id);
        return .{
            .allocator = allocator,
            .daemon_origin = daemon_origin,
            .origin_id = origin_id,
            .session = try allocator.dupe(u8, remote.session),
        };
    }

    fn clone(self: *const StoreKey, allocator: std.mem.Allocator) !StoreKey {
        var out = StoreKey{ .allocator = allocator };
        errdefer out.deinit();
        if (self.daemon_origin) |value| out.daemon_origin = try allocator.dupe(u8, value);
        if (self.origin_id) |value| out.origin_id = try allocator.dupe(u8, value);
        if (self.session) |value| out.session = try allocator.dupe(u8, value);
        return out;
    }

    fn deinit(self: *StoreKey) void {
        if (self.daemon_origin) |value| self.allocator.free(value);
        if (self.origin_id) |value| self.allocator.free(value);
        if (self.session) |value| self.allocator.free(value);
        self.* = undefined;
    }

    fn scope(self: *const StoreKey) panelstore.Scope {
        const daemon_origin = self.daemon_origin orelse return .sessionless;
        return .{ .origin = .{
            .daemon_origin = daemon_origin,
            .origin_id = self.origin_id.?,
            .label = if (self.session) |name| name else "",
        } };
    }
};

const StoreOp = enum { list, load, delete };

const StoreJob = struct {
    handle: *PickerHandle,
    store: StoreKey,
    op: StoreOp,
    name: ?[]u8 = null,
    /// Referenced on GTK before dispatch and unreferenced on GTK at handback.
    row: ?*c.GtkWidget = null,
    entries: []panelstore.Entry = &.{},
    invalid_reasons: []?[]u8 = &.{},
    document: ?[]u8 = null,
    failed: bool = false,
    failure: ?[]u8 = null,
    ready: std.atomic.Value(bool) = .init(false),
    counted_active: bool = false,

    fn setFailure(self: *StoreJob, message: []const u8) void {
        self.failed = true;
        if (self.failure) |old| std.heap.c_allocator.free(old);
        self.failure = std.heap.c_allocator.dupe(u8, message) catch null;
    }

    fn deinit(self: *StoreJob) void {
        const allocator = std.heap.c_allocator;
        if (self.entries.len > 0) panelstore.freeList(allocator, self.entries);
        for (self.invalid_reasons) |reason| if (reason) |text| allocator.free(text);
        if (self.invalid_reasons.len > 0) allocator.free(self.invalid_reasons);
        if (self.document) |document| allocator.free(document);
        if (self.failure) |message| allocator.free(message);
        if (self.name) |name| allocator.free(name);
        if (self.row) |row| c.g_object_unref(@ptrCast(row));
        self.store.deinit();
        self.handle.release();
        allocator.destroy(self);
    }
};

const MAX_STORE_WORKERS: usize = 2;
const MAX_STORE_JOBS: usize = 16;
var store_jobs: std.ArrayListUnmanaged(*StoreJob) = .empty;
var active_store_workers: usize = 0;

pub fn open(window: *Window) void {
    openFor(window, window.focusedPane());
}

fn openFor(window: *Window, pane: ?*Pane) void {
    const allocator = window.allocator;
    const session = panelhost.sessionForPane(pane);
    var store = StoreKey.init(allocator, pane) catch |err| {
        window_mod.showToast(window, switch (err) {
            error.RemoteStore => "Saved panels for a remote session stay on that remote host; open them there with ui_panels/ui_show",
            error.InvalidOriginIdentity => "This identity-capable session has missing or invalid panel origin metadata; saved panels are unavailable rather than falling back to legacy storage",
            error.UnvalidatedOriginCapability => "This session's daemon capabilities could not be validated; saved panels are unavailable rather than assuming legacy storage",
            else => "Could not resolve this panel store",
        });
        return;
    };

    const ctx = allocator.create(Ctx) catch {
        store.deinit();
        return;
    };
    const handle = allocator.create(PickerHandle) catch {
        store.deinit();
        allocator.destroy(ctx);
        return;
    };
    ctx.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .window = window,
        .dialog = undefined,
        .listbox = undefined,
        .status_box = undefined,
        .status_spinner = undefined,
        .status_label = undefined,
        .store = store,
        .handle = handle,
        .pane = pane,
    };
    handle.* = .{ .allocator = allocator, .ctx = ctx };

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
        const text = std.fmt.bufPrintZ(&head_buf, "Panels saved for local session {s}", .{session}) catch
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

    _ = c.g_signal_connect_data(
        listbox,
        "row-activated",
        @ptrCast(&onRowActivated),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );

    const status = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_set_halign(status, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_margin_top(status, 10);
    const spinner = c.gtk_spinner_new();
    const status_label = c.gtk_label_new("Reading saved panels...");
    c.gtk_box_append(@ptrCast(status), spinner);
    c.gtk_box_append(@ptrCast(status), status_label);
    c.gtk_box_append(@ptrCast(root), status);
    ctx.status_box = status;
    ctx.status_spinner = @ptrCast(@alignCast(spinner));
    ctx.status_label = @ptrCast(@alignCast(status_label));
    c.gtk_spinner_start(ctx.status_spinner);
    c.gtk_widget_set_sensitive(listbox, 0);

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

    submitStoreJob(ctx, .list, null, null) catch {
        ctx.busy = false;
        c.gtk_widget_set_sensitive(ctx.listbox, 1);
        setStatus(ctx, "Could not start the saved-panel worker", false, true);
    };
}

/// What the row says under the name: the document's own title plus its
/// size and age, or — for a document that no longer parses — the
/// parser's message, which is the only thing that explains why the
/// panel cannot be opened.
fn subtitle(arena: std.mem.Allocator, e: panelstore.Entry, invalid_reason: ?[]const u8) [:0]const u8 {
    if (!e.ok) {
        const why = invalid_reason orelse "the stored document no longer parses";
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

fn setStatus(ctx: *Ctx, text: []const u8, spinning: bool, is_error: bool) void {
    var buf: [512]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text}) catch "Saved-panel operation failed";
    c.gtk_label_set_text(ctx.status_label, z.ptr);
    c.gtk_widget_set_visible(ctx.status_box, if (text.len > 0) 1 else 0);
    c.gtk_widget_set_visible(@ptrCast(@alignCast(ctx.status_spinner)), if (spinning) 1 else 0);
    if (spinning) c.gtk_spinner_start(ctx.status_spinner) else c.gtk_spinner_stop(ctx.status_spinner);
    if (is_error)
        c.gtk_widget_add_css_class(@ptrCast(@alignCast(ctx.status_label)), "error")
    else
        c.gtk_widget_remove_css_class(@ptrCast(@alignCast(ctx.status_label)), "error");
}

fn clearRows(ctx: *Ctx) void {
    while (c.gtk_widget_get_first_child(ctx.listbox)) |child|
        c.gtk_list_box_remove(@ptrCast(@alignCast(ctx.listbox)), child);
    ctx.row_count = 0;
}

fn appendEmptyRow(ctx: *Ctx) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "No saved panels in this session");
    c.adw_action_row_set_subtitle(
        @ptrCast(@alignCast(row)),
        "An assistant saves one with the ui_save tool; it shows up here.",
    );
    c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), 0);
    c.gtk_list_box_append(@ptrCast(@alignCast(ctx.listbox)), row);
}

fn renderEntries(ctx: *Ctx, job: *const StoreJob) void {
    clearRows(ctx);
    const arena = ctx.arena.allocator();
    if (job.entries.len == 0) appendEmptyRow(ctx);

    for (job.entries, 0..) |entry, i| {
        const name_z = arena.allocSentinel(u8, entry.name.len, 0) catch continue;
        @memcpy(name_z, entry.name);
        const rctx = arena.create(RowCtx) catch continue;
        rctx.* = .{ .ctx = ctx, .name = name_z, .ok = entry.ok };

        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), name_z.ptr);
        const reason = if (i < job.invalid_reasons.len) job.invalid_reasons[i] else null;
        c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle(arena, entry, reason).ptr);
        c.gtk_list_box_row_set_activatable(@ptrCast(@alignCast(row)), if (entry.ok) 1 else 0);
        c.gtk_widget_set_focusable(@ptrCast(row), 1);

        const icon = c.gtk_image_new_from_icon_name(
            if (entry.ok) "view-paged-symbolic" else "dialog-warning-symbolic",
        );
        c.adw_action_row_add_prefix(@ptrCast(@alignCast(row)), icon);
        if (!entry.ok) c.gtk_widget_add_css_class(@ptrCast(row), "error");

        const del = c.gtk_button_new_from_icon_name("user-trash-symbolic");
        c.gtk_widget_add_css_class(del, "flat");
        c.gtk_widget_set_valign(del, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_tooltip_text(del, "Delete this saved panel");
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
        c.gtk_list_box_append(@ptrCast(@alignCast(ctx.listbox)), row);
        ctx.row_count += 1;
    }

    const first = c.gtk_list_box_get_row_at_index(@ptrCast(@alignCast(ctx.listbox)), 0);
    if (first != null) {
        c.gtk_list_box_select_row(@ptrCast(@alignCast(ctx.listbox)), first);
        _ = c.gtk_widget_grab_focus(@ptrCast(first));
    }
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

fn createStoreJob(
    ctx: *Ctx,
    op: StoreOp,
    name: ?[]const u8,
    row: ?*c.GtkWidget,
) !*StoreJob {
    const allocator = std.heap.c_allocator;
    const job = try allocator.create(StoreJob);
    errdefer allocator.destroy(job);
    var store = try ctx.store.clone(allocator);
    errdefer store.deinit();
    const owned_name: ?[]u8 = if (name) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_name) |value| allocator.free(value);
    if (row) |widget| _ = c.g_object_ref(@ptrCast(widget));
    errdefer if (row) |widget| c.g_object_unref(@ptrCast(widget));
    ctx.handle.retain();
    job.* = .{
        .handle = ctx.handle,
        .store = store,
        .op = op,
        .name = owned_name,
        .row = row,
    };
    return job;
}

fn submitStoreJob(ctx: *Ctx, op: StoreOp, name: ?[]const u8, row: ?*c.GtkWidget) !void {
    if (active_store_workers + store_jobs.items.len >= MAX_STORE_JOBS) return error.Busy;
    const job = try createStoreJob(ctx, op, name, row);
    errdefer job.deinit();
    try store_jobs.append(std.heap.c_allocator, job);
    ctx.busy = true;
    c.gtk_widget_set_sensitive(ctx.listbox, 0);
    pumpStoreJobs();
}

fn pumpStoreJobs() void {
    while (active_store_workers < MAX_STORE_WORKERS and store_jobs.items.len > 0) {
        const job = store_jobs.orderedRemove(0);
        const thread = std.Thread.spawn(.{}, storeJobMain, .{job}) catch {
            job.setFailure("Could not start the saved-panel worker");
            job.ready.store(true, .release);
            _ = c.g_idle_add(@ptrCast(&storeJobDone), @ptrCast(job));
            continue;
        };
        job.counted_active = true;
        active_store_workers += 1;
        thread.detach();
    }
}

fn storeJobMain(job: *StoreJob) void {
    runStoreJob(job);
    job.ready.store(true, .release);
    _ = c.g_idle_add(@ptrCast(&storeJobDone), @ptrCast(job));
}

fn runStoreJob(job: *StoreJob) void {
    const allocator = std.heap.c_allocator;
    switch (job.op) {
        .list => {
            job.entries = panelstore.listScoped(allocator, job.store.scope()) catch |err| {
                job.setFailure(@errorName(err));
                return;
            };
            if (job.entries.len == 0) return;
            job.invalid_reasons = allocator.alloc(?[]u8, job.entries.len) catch {
                job.setFailure("OutOfMemory");
                return;
            };
            @memset(job.invalid_reasons, null);
            for (job.entries, 0..) |entry, i| {
                if (entry.ok) continue;
                var diag = Doc.Diag{};
                if (panelstore.loadScoped(allocator, job.store.scope(), entry.name, &diag)) |parsed| {
                    var document = parsed;
                    document.deinit();
                } else |err| {
                    const reason = if (diag.len > 0) diag.msg() else @errorName(err);
                    job.invalid_reasons[i] = allocator.dupe(u8, reason) catch null;
                }
            }
        },
        .load => {
            const name = job.name orelse {
                job.setFailure("MissingName");
                return;
            };
            var diag = Doc.Diag{};
            var document = panelstore.loadScoped(allocator, job.store.scope(), name, &diag) catch |err| {
                job.setFailure(if (diag.len > 0) diag.msg() else @errorName(err));
                return;
            };
            defer document.deinit();
            job.document = document.toJson(allocator) catch |err| {
                job.setFailure(@errorName(err));
                return;
            };
        },
        .delete => {
            const name = job.name orelse {
                job.setFailure("MissingName");
                return;
            };
            var diag = Doc.Diag{};
            panelstore.deleteScoped(allocator, job.store.scope(), name, &diag) catch |err| {
                job.setFailure(if (diag.len > 0) diag.msg() else @errorName(err));
                return;
            };
        },
    }
}

fn storeJobDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job: *StoreJob = @ptrCast(@alignCast(user.?));
    if (!job.ready.load(.acquire)) return 1;
    if (job.counted_active and active_store_workers > 0) active_store_workers -= 1;

    if (job.handle.ctx) |ctx| if (canary.alive(ctx)) {
        ctx.busy = false;
        c.gtk_widget_set_sensitive(ctx.listbox, 1);
        if (job.failed) {
            var buf: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "Saved-panel operation failed: {s}", .{job.failure orelse "out of memory reporting the failure"}) catch
                "Saved-panel operation failed";
            setStatus(ctx, message, false, true);
        } else switch (job.op) {
            .list => {
                renderEntries(ctx, job);
                setStatus(ctx, "", false, false);
            },
            .load => finishLoad(ctx, job),
            .delete => finishDelete(ctx, job),
        }
    };

    job.deinit();
    pumpStoreJobs();
    return 0;
}

fn finishLoad(ctx: *Ctx, job: *StoreJob) void {
    const pane = livePane(ctx.window, ctx.pane) orelse {
        setStatus(ctx, "The panel's originating pane is no longer open", false, true);
        return;
    };
    const name = job.name orelse return;
    const document = job.document orelse return;
    var diag = Doc.Diag{};
    _ = panelhost.openSavedDocument(ctx.window, pane, name, document, OPEN_TARGET, &diag) catch |err| {
        var buf: [512]u8 = undefined;
        const why = if (diag.len > 0) diag.msg() else @errorName(err);
        const message = std.fmt.bufPrint(&buf, "Could not open panel \"{s}\": {s}", .{ name, why }) catch
            "Could not open the saved panel";
        setStatus(ctx, message, false, true);
        return;
    };
    c.adw_dialog_force_close(@ptrCast(@alignCast(ctx.dialog)));
}

fn finishDelete(ctx: *Ctx, job: *StoreJob) void {
    if (job.row) |row| if (c.gtk_widget_get_parent(row) == ctx.listbox) {
        c.gtk_list_box_remove(@ptrCast(@alignCast(ctx.listbox)), row);
        ctx.row_count -|= 1;
    };
    if (ctx.row_count == 0 and c.gtk_widget_get_first_child(ctx.listbox) == null) appendEmptyRow(ctx);
    setStatus(ctx, "", false, false);
    var buf: [320]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Deleted saved panel \"{s}\"", .{job.name orelse ""}) catch
        "Deleted the saved panel";
    window_mod.showToast(ctx.window, message);
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
    const ctx = canary.live(Ctx, user) orelse return;
    if (ctx.busy) return;
    const data = c.g_object_get_data(@ptrCast(@alignCast(row)), "panel-row") orelse return;
    const rctx: *RowCtx = @ptrCast(@alignCast(data));
    // A broken document's row is not activatable, so this is belt and
    // braces; either way it must never reach the store.
    if (!rctx.ok) return;

    if (livePane(ctx.window, ctx.pane) == null) {
        setStatus(ctx, "The panel's originating pane is no longer open", false, true);
        return;
    }
    var buf: [320]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Opening saved panel \"{s}\"...", .{rctx.name}) catch
        "Opening saved panel...";
    setStatus(ctx, message, true, false);
    submitStoreJob(ctx, .load, rctx.name, null) catch {
        setStatus(ctx, "Could not start the saved-panel worker", false, true);
    };
}

fn onDeleteClicked(button: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = canary.live(Ctx, user) orelse return;
    if (ctx.busy) return;
    const data = c.g_object_get_data(@ptrCast(@alignCast(button)), "panel-row") orelse return;
    const rctx: *RowCtx = @ptrCast(@alignCast(data));
    const row_data = c.g_object_get_data(@ptrCast(@alignCast(button)), "panel-row-widget") orelse return;
    const row: *c.GtkWidget = @ptrCast(@alignCast(row_data));

    const allocator = ctx.allocator;
    const dctx = allocator.create(DeleteCtx) catch {
        return;
    };
    ctx.handle.retain();
    dctx.* = .{
        .allocator = allocator,
        .handle = ctx.handle,
        .name = allocator.dupe(u8, rctx.name) catch {
            ctx.handle.release();
            allocator.destroy(dctx);
            return;
        },
        .row = row,
    };

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
    // The alert outlives its async choose operation, so its qdata is the
    // exactly-once owner. The callback only borrows this pointer.
    c.g_object_set_data_full(
        @ptrCast(alert),
        "sketerm-panel-delete-context",
        @ptrCast(dctx),
        @ptrCast(&freeDeleteCtx),
    );
    c.adw_alert_dialog_choose(alert, ctx.window.app_window, null, onDeleteResponse, @ptrCast(dctx));
}

fn onDeleteResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const dctx = canary.live(DeleteCtx, user) orelse return;
    const alert: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
    const resp = std.mem.span(@as([*:0]const u8, @ptrCast(c.adw_alert_dialog_choose_finish(alert, result))));
    if (!std.mem.eql(u8, resp, "delete")) return;
    const ctx = dctx.handle.ctx orelse return;
    if (!canary.alive(ctx) or ctx.busy) return;
    var buf: [320]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "Deleting saved panel \"{s}\"...", .{dctx.name}) catch
        "Deleting saved panel...";
    setStatus(ctx, message, true, false);
    submitStoreJob(ctx, .delete, dctx.name, dctx.row) catch
        setStatus(ctx, "Could not start the saved-panel worker", false, true);
}

fn freeDeleteCtx(user: ?*anyopaque) callconv(.c) void {
    const dctx = canary.live(DeleteCtx, user) orelse return;
    dctx.destroy();
}

fn onClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    const ctx = canary.live(Ctx, user) orelse return;
    // The object may remain referenced after `closed`; fence worker handbacks
    // at the semantic teardown point rather than waiting for finalization.
    ctx.handle.ctx = null;
    // Cleanup runs via the GDestroyNotify (`freeCtx`) attached to the
    // same signal connection.
}

fn freeCtx(user: ?*anyopaque) callconv(.c) void {
    if (canary.live(Ctx, user)) |ctx| {
        ctx.handle.ctx = null;
        ctx.handle.release();
        ctx.store.deinit();
        ctx.arena.deinit();
        canary.poison(ctx);
        ctx.allocator.destroy(ctx);
    }
}

test "a poisoned picker Ctx makes freeCtx bail instead of double-freeing" {
    const a = std.testing.allocator;
    const ctx = try a.create(Ctx);
    ctx.* = .{
        .allocator = a,
        .arena = std.heap.ArenaAllocator.init(a),
        .window = undefined,
        .dialog = undefined,
        .listbox = undefined,
        .status_box = undefined,
        .status_spinner = undefined,
        .status_label = undefined,
        .store = undefined,
        .handle = undefined,
        .pane = null,
    };
    // Stands in for "the dialog's destroy-notify already ran".
    canary.poison(ctx);

    const before = canary.trips;
    freeCtx(@ptrCast(ctx));
    try std.testing.expectEqual(before + 1, canary.trips);

    // Had the guard not fired, freeCtx would have deinited the arena
    // and freed the struct, and these two would be double frees the
    // testing allocator reports.
    ctx.arena.deinit();
    a.destroy(ctx);
}

test "a poisoned DeleteCtx is not destroyed twice" {
    const a = std.testing.allocator;
    var dctx = DeleteCtx{
        .allocator = a,
        .handle = undefined,
        .name = undefined,
        .row = undefined,
    };
    canary.poison(&dctx);
    const before = canary.trips;
    // Every field is undefined: reaching any of them would crash, so
    // returning cleanly IS the proof that the guard came first.
    dctx.destroy();
    try std.testing.expectEqual(before + 1, canary.trips);
}

test "delete dialog context retains no raw Window across choose" {
    try std.testing.expect(!@hasField(DeleteCtx, "window"));
}

test "async delete response after owner teardown touches no GTK state" {
    var dctx = DeleteCtx{
        .allocator = std.testing.allocator,
        .handle = undefined,
        .name = undefined,
        .row = undefined,
    };
    canary.poison(&dctx);
    const before = canary.trips;
    onDeleteResponse(undefined, null, @ptrCast(&dctx));
    try std.testing.expectEqual(before + 1, canary.trips);
}

test "store handback after picker teardown touches no GTK state" {
    const allocator = std.heap.c_allocator;
    const handle = try allocator.create(PickerHandle);
    handle.* = .{ .allocator = allocator, .ctx = null };
    const job = try allocator.create(StoreJob);
    job.* = .{
        .handle = handle,
        .store = .{ .allocator = allocator },
        .op = .list,
    };
    job.ready.store(true, .release);
    try std.testing.expectEqual(@as(c.gboolean, 0), storeJobDone(@ptrCast(job)));
}

test "saved-panel store worker pool is bounded" {
    try std.testing.expect(MAX_STORE_WORKERS > 0);
    try std.testing.expect(MAX_STORE_WORKERS < MAX_STORE_JOBS);
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

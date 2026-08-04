//! Sketerm's native file picker: a transient modal window embedding
//! a paneless BrowserView (composition, not extraction), so remote
//! hosts, places, thumbnails and every view mode come along for
//! free. Policy (modes, filters, name validation) is GTK-free in
//! src/filebrowser/picker.zig.
//!
//! Async result contract: the caller's callback runs EXACTLY once --
//! with a Result on accept, with null on cancel/close/parent
//! teardown -- and the window then destroys itself. Result slices
//! are only valid during the callback.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const fpicker = @import("../filebrowser/picker.zig");
const paths = @import("../filebrowser/paths.zig");
const BrowserView = @import("browser/view.zig").BrowserView;
const PickerHooks = @import("browser/view.zig").PickerHooks;
const nav = @import("browser/nav.zig");

pub const ResultCb = *const fn (ctx: ?*anyopaque, result: ?fpicker.Result) void;

pub const PickerWindow = struct {
    allocator: std.mem.Allocator,
    window: *c.GtkWindow = undefined,
    view: *BrowserView = undefined,
    /// The view's picker hooks point at this field, so the struct
    /// address must be stable (it is: heap-allocated).
    hooks: PickerHooks = undefined,
    mode: fpicker.Mode,
    /// Deep copies of the request's filters (the request may die the
    /// moment open() returns).
    filters: []fpicker.Filter = &.{},
    /// Selected filter index; == filters.len means "All files".
    active_filter: usize = 0,
    suggested_name: ?[]u8 = null,
    /// Primary-button label override (owned copy).
    accept_label: ?[]u8 = null,
    cb: ResultCb,
    cb_ctx: ?*anyopaque,
    delivered: bool = false,
    /// False until the footer widgets exist; the browser fires its
    /// selection hook during attach, before the window is built.
    built: bool = false,
    name_entry: ?*c.GtkEntry = null,
    primary: *c.GtkWidget = undefined,

    /// Open a picker over `parent`. Returns after presenting; the
    /// result arrives through `cb`. All request slices are copied.
    pub fn open(
        allocator: std.mem.Allocator,
        parent: ?*c.GtkWindow,
        req: fpicker.Request,
        cb: ResultCb,
        cb_ctx: ?*anyopaque,
    ) !*PickerWindow {
        const self = try allocator.create(PickerWindow);
        self.* = .{ .allocator = allocator, .mode = req.mode, .cb = cb, .cb_ctx = cb_ctx };
        errdefer {
            self.freeOwned();
            allocator.destroy(self);
        }
        try self.copyFilters(req.filters);
        if (req.suggested_name) |sn| self.suggested_name = try allocator.dupe(u8, sn);
        if (req.accept_label) |al| self.accept_label = try allocator.dupe(u8, al);
        self.hooks = .{
            .ctx = @ptrCast(self),
            .on_activate_file = &onActivateFile,
            .on_selection_changed = &onSelectionChanged,
            .visible = &visibleCb,
            .suppress_ops = true,
        };
        self.view = try BrowserView.attachForPicker(allocator, &self.hooks, req.initial_spec);
        self.buildWindow(parent, req.title);
        self.built = true;
        self.syncFromSelection();
        c.gtk_window_present(self.window);
        if (self.name_entry) |entry| {
            _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(entry)));
        } else {
            self.view.focusListing();
        }
        return self;
    }

    fn copyFilters(self: *PickerWindow, src: []const fpicker.Filter) !void {
        if (src.len == 0) return;
        const out = try self.allocator.alloc(fpicker.Filter, src.len);
        var done: usize = 0;
        errdefer self.freeFilterSlice(out, done);
        for (src, 0..) |f, i| {
            const label = try self.allocator.dupe(u8, f.label);
            errdefer self.allocator.free(label);
            const pats = try self.allocator.alloc([]const u8, f.patterns.len);
            var pdone: usize = 0;
            errdefer {
                for (pats[0..pdone]) |p| self.allocator.free(@constCast(p));
                self.allocator.free(pats);
            }
            for (f.patterns, 0..) |p, j| {
                pats[j] = try self.allocator.dupe(u8, p);
                pdone = j + 1;
            }
            out[i] = .{ .label = label, .patterns = pats };
            done = i + 1;
        }
        self.filters = out;
    }

    fn freeFilterSlice(self: *PickerWindow, fs: []fpicker.Filter, n: usize) void {
        for (fs[0..n]) |f| {
            self.allocator.free(@constCast(f.label));
            for (f.patterns) |p| self.allocator.free(@constCast(p));
            self.allocator.free(f.patterns);
        }
        self.allocator.free(fs);
    }

    fn freeOwned(self: *PickerWindow) void {
        if (self.filters.len > 0) self.freeFilterSlice(self.filters, self.filters.len);
        self.filters = &.{};
        if (self.suggested_name) |sn| self.allocator.free(sn);
        self.suggested_name = null;
        if (self.accept_label) |al| self.allocator.free(al);
        self.accept_label = null;
    }

    // -- window construction -------------------------------------

    fn buildWindow(self: *PickerWindow, parent: ?*c.GtkWindow, title: ?[]const u8) void {
        const window = c.gtk_window_new();
        self.window = @ptrCast(@alignCast(window));
        c.gtk_window_set_modal(self.window, 1);
        var tz: [256:0]u8 = undefined;
        const title_z: [*:0]const u8 = if (title) |t| blk: {
            const n = @min(t.len, tz.len - 1);
            @memcpy(tz[0..n], t[0..n]);
            tz[n] = 0;
            break :blk &tz;
        } else fpicker.defaultTitle(self.mode);
        c.gtk_window_set_title(self.window, title_z);
        // The Quick Look shape: transient over the parent, ~80% of
        // its size, clamped to something sane when unrealized.
        var w: c_int = 1000;
        var h: c_int = 700;
        if (parent) |p| {
            c.gtk_window_set_transient_for(self.window, p);
            const pw = c.gtk_widget_get_width(@ptrCast(@alignCast(p)));
            const ph = c.gtk_widget_get_height(@ptrCast(@alignCast(p)));
            if (pw > 300) w = @divTrunc(pw * 8, 10);
            if (ph > 300) h = @divTrunc(ph * 8, 10);
        }
        c.gtk_window_set_default_size(self.window, w, h);

        const toolbar = c.adw_toolbar_view_new();
        const header = c.adw_header_bar_new();
        c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), header);

        const content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_vexpand(self.view.root_box, 1);
        c.gtk_box_append(@ptrCast(content), self.view.root_box);
        c.gtk_box_append(@ptrCast(content), self.buildFooter());
        c.adw_toolbar_view_set_content(@ptrCast(toolbar), content);
        c.gtk_window_set_child(self.window, toolbar);

        // Escape cancels (bubble phase, so the browser's own Escape
        // uses -- type-ahead reset, entry face -- keep priority).
        const keys = c.gtk_event_controller_key_new();
        _ = c.g_signal_connect_data(keys, "key-pressed", @ptrCast(&onWindowKey), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(window, @ptrCast(keys));

        _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&onCloseRequest), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onWindowDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    }

    fn buildFooter(self: *PickerWindow) *c.GtkWidget {
        const footer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_set_margin_start(footer, 10);
        c.gtk_widget_set_margin_end(footer, 10);
        c.gtk_widget_set_margin_top(footer, 6);
        c.gtk_widget_set_margin_bottom(footer, 8);

        if (fpicker.needsNameEntry(self.mode)) {
            const label = c.gtk_label_new("Name:");
            c.gtk_widget_add_css_class(label, "dim-label");
            c.gtk_box_append(@ptrCast(footer), label);
            const entry = c.gtk_entry_new();
            c.gtk_widget_set_hexpand(entry, 1);
            if (self.suggested_name) |sn| {
                var z: [512:0]u8 = undefined;
                const n = @min(sn.len, z.len - 1);
                @memcpy(z[0..n], sn[0..n]);
                z[n] = 0;
                c.gtk_editable_set_text(@ptrCast(entry), &z);
            }
            _ = c.g_signal_connect_data(entry, "changed", @ptrCast(&onNameChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
            _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onPrimaryClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(footer), entry);
            self.name_entry = @ptrCast(@alignCast(entry));
        } else {
            const spacer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
            c.gtk_widget_set_hexpand(spacer, 1);
            c.gtk_box_append(@ptrCast(footer), spacer);
        }

        if (self.filters.len > 0) self.buildFilterDropdown(footer.?);

        const cancel_btn = c.gtk_button_new_with_label("Cancel");
        _ = c.g_signal_connect_data(cancel_btn, "clicked", @ptrCast(&onCancelClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(footer), cancel_btn);

        // gtk_button_new_with_label copies, so a stack copy is fine.
        var albuf: [128:0]u8 = undefined;
        const primary_label: [*:0]const u8 = if (self.accept_label) |al| blk: {
            const n = @min(al.len, albuf.len - 1);
            @memcpy(albuf[0..n], al[0..n]);
            albuf[n] = 0;
            break :blk &albuf;
        } else fpicker.primaryLabel(self.mode);
        const primary = c.gtk_button_new_with_label(primary_label);
        c.gtk_widget_add_css_class(primary, "suggested-action");
        _ = c.g_signal_connect_data(primary, "clicked", @ptrCast(&onPrimaryClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(footer), primary);
        self.primary = primary.?;
        return footer.?;
    }

    fn buildFilterDropdown(self: *PickerWindow, footer: *c.GtkWidget) void {
        // A GtkStringList copies its strings, so stack copies do.
        const list = c.gtk_string_list_new(null);
        for (self.filters) |f| {
            var z: [128:0]u8 = undefined;
            const n = @min(f.label.len, z.len - 1);
            @memcpy(z[0..n], f.label[0..n]);
            z[n] = 0;
            c.gtk_string_list_append(list, &z);
        }
        c.gtk_string_list_append(list, "All files");
        const dd = c.gtk_drop_down_new(@ptrCast(@alignCast(list)), null);
        c.gtk_drop_down_set_selected(@ptrCast(dd), 0);
        _ = c.g_signal_connect_data(dd, "notify::selected", @ptrCast(&onFilterSelected), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(footer), dd);
    }

    // -- browser hooks -------------------------------------------

    fn visibleCb(ctx: *anyopaque, name: []const u8, is_dir: bool) bool {
        const self: *PickerWindow = @ptrCast(@alignCast(ctx));
        if (is_dir) return true;
        if (!fpicker.showsFiles(self.mode)) return false;
        if (self.active_filter >= self.filters.len) return true;
        return fpicker.filterMatches(self.filters[self.active_filter], name);
    }

    fn onActivateFile(ctx: *anyopaque, host: ?[]const u8, path: []const u8) void {
        const self: *PickerWindow = @ptrCast(@alignCast(ctx));
        if (!self.built) return;
        switch (self.mode) {
            .open_file, .open_files => {
                var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
                const spec = paths.formatSpec(&buf, host, path);
                self.deliver(&.{spec}, null);
            },
            // Save mode: activating an existing file adopts its name.
            .save_file => self.setNameEntry(std.fs.path.basename(path)),
            // Directory modes never show files; defensive no-op.
            .select_dir, .select_destination => {},
        }
    }

    fn onSelectionChanged(ctx: *anyopaque) void {
        const self: *PickerWindow = @ptrCast(@alignCast(ctx));
        // Selection signals also fire while the window tears its
        // widgets down; the footer must not be touched then.
        if (!self.built or self.view.widgets_dead) return;
        self.syncFromSelection();
    }

    // -- selection state -----------------------------------------

    const Selection = struct {
        files: usize = 0,
        dirs: usize = 0,
        first_file: ?[]const u8 = null,
        first_dir: ?[]const u8 = null,
    };

    fn currentSelection(self: *PickerWindow) Selection {
        var out: Selection = .{};
        const tab = self.view.currentTab() orelse return out;
        for (tab.selected.items) |p| {
            const e = nav.entryForPath(tab, p) orelse continue;
            if (e.tdir) {
                out.dirs += 1;
                if (out.first_dir == null) out.first_dir = p;
            } else {
                out.files += 1;
                if (out.first_file == null) out.first_file = p;
            }
        }
        return out;
    }

    /// Selection -> footer: save-name adoption plus primary-button
    /// sensitivity. The single sync point, also run once at build.
    fn syncFromSelection(self: *PickerWindow) void {
        const sel = self.currentSelection();
        if (self.mode == .save_file and sel.files == 1 and sel.dirs == 0) {
            if (sel.first_file) |p| self.setNameEntry(std.fs.path.basename(p));
        }
        self.updatePrimary(sel);
    }

    fn updatePrimary(self: *PickerWindow, sel: Selection) void {
        const on = switch (self.mode) {
            .open_file => sel.files == 1 and sel.dirs == 0,
            .open_files => sel.files >= 1 and sel.dirs == 0,
            .select_dir, .select_destination => true,
            .save_file => fpicker.validSaveName(self.nameText()),
        };
        c.gtk_widget_set_sensitive(self.primary, @intFromBool(on));
    }

    fn nameText(self: *PickerWindow) []const u8 {
        const entry = self.name_entry orelse return "";
        return std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(@alignCast(entry))))));
    }

    fn setNameEntry(self: *PickerWindow, name: []const u8) void {
        const entry = self.name_entry orelse return;
        var z: [512:0]u8 = undefined;
        const n = @min(name.len, z.len - 1);
        @memcpy(z[0..n], name[0..n]);
        z[n] = 0;
        c.gtk_editable_set_text(@ptrCast(@alignCast(entry)), &z);
    }

    // -- signal handlers -----------------------------------------

    fn onNameChanged(_: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(PickerWindow, user);
        if (!self.built) return;
        self.updatePrimary(self.currentSelection());
    }

    fn onFilterSelected(obj: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(PickerWindow, user);
        const idx = c.gtk_drop_down_get_selected(@ptrCast(@alignCast(obj)));
        self.active_filter = if (idx == c.GTK_INVALID_LIST_POSITION) self.filters.len else idx;
        self.view.renderCurrent();
    }

    fn onWindowKey(
        _: *c.GtkEventControllerKey,
        keyval: c_uint,
        _: c_uint,
        _: c.GdkModifierType,
        user: ?*anyopaque,
    ) callconv(.c) c.gboolean {
        const self = cast.userData(PickerWindow, user);
        if (keyval == c.GDK_KEY_Escape) {
            c.gtk_window_close(self.window);
            return 1;
        }
        return 0;
    }

    fn onCancelClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(PickerWindow, user);
        self.deliverNull();
    }

    fn onCloseRequest(_: *c.GtkWindow, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(PickerWindow, user);
        // The widget tree is about to die; fence the browser's
        // destroy-time signal storm (sorter/selection callbacks) the
        // same way Pane.prepareDestroyCb does.
        self.view.widgets_dead = true;
        if (!self.delivered) {
            self.delivered = true;
            self.cb(self.cb_ctx, null);
        }
        return 0; // allow the close
    }

    /// The destroy fence AND the teardown trigger: the parent window
    /// can destroy us without a close-request (transient teardown),
    /// so the null delivery has to be honored here too.
    fn onWindowDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(PickerWindow, user);
        self.view.widgets_dead = true;
        if (!self.delivered) {
            self.delivered = true;
            self.cb(self.cb_ctx, null);
        }
        // The browser's widgets just died with the window; its struct
        // teardown waits for the destroy to fully unwind (same shape
        // as Pane's deferred browser deinit).
        _ = c.g_idle_add(@ptrCast(&teardownIdle), @ptrCast(self));
    }

    fn teardownIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(PickerWindow, user);
        self.view.deinit();
        self.freeOwned();
        self.allocator.destroy(self);
        return 0;
    }

    /// Programmatic cancel (e.g. the portal's Request.Close): fence
    /// the browser BEFORE the widget tree dies -- GtkWindow dispose
    /// destroys children before emitting "destroy", so the destroy
    /// handler's fence is too late for the teardown signal storm --
    /// then destroy; the callback fires with null via the destroy
    /// fence.
    pub fn cancel(self: *PickerWindow) void {
        self.view.widgets_dead = true;
        c.gtk_window_destroy(self.window);
    }

    // -- delivery ------------------------------------------------

    /// Invoke the callback exactly once and self-destruct.
    fn deliver(self: *PickerWindow, specs: []const []const u8, name: ?[]const u8) void {
        if (self.delivered) return;
        self.delivered = true;
        self.cb(self.cb_ctx, .{ .specs = specs, .name = name });
        self.view.widgets_dead = true;
        c.gtk_window_destroy(self.window);
    }

    fn deliverNull(self: *PickerWindow) void {
        if (self.delivered) return;
        self.delivered = true;
        self.cb(self.cb_ctx, null);
        self.view.widgets_dead = true;
        c.gtk_window_destroy(self.window);
    }

    fn onPrimaryClicked(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(PickerWindow, user);
        if (self.delivered) return;
        const tab = self.view.currentTab() orelse return;
        const sel = self.currentSelection();
        switch (self.mode) {
            .open_file => {
                const p = sel.first_file orelse return;
                if (sel.files != 1 or sel.dirs != 0) return;
                var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
                self.deliver(&.{paths.formatSpec(&buf, tab.hc.host, p)}, null);
            },
            .open_files => {
                if (sel.files == 0 or sel.dirs != 0) return;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const a = arena.allocator();
                var specs: std.ArrayList([]const u8) = .empty;
                for (tab.selected.items) |p| {
                    const e = nav.entryForPath(tab, p) orelse continue;
                    if (e.tdir) continue;
                    const spec = paths.formatSpecAlloc(a, tab.hc.host, p) catch return;
                    specs.append(a, spec) catch return;
                }
                if (specs.items.len == 0) return;
                self.deliver(specs.items, null);
            },
            .select_dir, .select_destination => {
                // A selected directory wins; otherwise the one being
                // shown is the choice.
                const p = if (sel.dirs == 1 and sel.files == 0)
                    sel.first_dir.?
                else
                    tab.root.path;
                var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
                self.deliver(&.{paths.formatSpec(&buf, tab.hc.host, p)}, null);
            },
            .save_file => self.primarySave(tab),
        }
    }

    fn primarySave(self: *PickerWindow, tab: *@import("browser/types.zig").BTab) void {
        const name = self.nameText();
        if (!fpicker.validSaveName(name)) return;
        var pbuf: [4096]u8 = undefined;
        const dir = tab.root.path;
        const full = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{
            if (std.mem.eql(u8, dir, "/")) "" else dir,
            name,
        }) catch return;
        if (nav.entryForPath(tab, full) != null) {
            self.confirmOverwrite(full, name);
            return;
        }
        var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
        self.deliver(&.{paths.formatSpec(&buf, tab.hc.host, full)}, name);
    }

    const OverwriteCtx = struct {
        self: *PickerWindow,
        spec: []u8,
        name: []u8,
    };

    fn confirmOverwrite(self: *PickerWindow, full: []const u8, name: []const u8) void {
        const tab = self.view.currentTab() orelse return;
        const ctx = self.allocator.create(OverwriteCtx) catch return;
        const spec = paths.formatSpecAlloc(self.allocator, tab.hc.host, full) catch {
            self.allocator.destroy(ctx);
            return;
        };
        const owned_name = self.allocator.dupe(u8, name) catch {
            self.allocator.free(spec);
            self.allocator.destroy(ctx);
            return;
        };
        ctx.* = .{ .self = self, .spec = spec, .name = owned_name };
        var body: [600:0]u8 = undefined;
        const b = std.fmt.bufPrintZ(&body, "\"{s}\" already exists. Replacing it overwrites its contents.", .{name}) catch blk: {
            break :blk std.fmt.bufPrintZ(&body, "The file already exists. Replacing it overwrites its contents.", .{}) catch unreachable;
        };
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(c.adw_alert_dialog_new("Replace file?", b.ptr)));
        c.adw_alert_dialog_add_response(dialog, "cancel", "Cancel");
        c.adw_alert_dialog_add_response(dialog, "replace", "Replace");
        c.adw_alert_dialog_set_response_appearance(dialog, "replace", c.ADW_RESPONSE_DESTRUCTIVE);
        c.adw_alert_dialog_set_default_response(dialog, "cancel");
        c.adw_alert_dialog_set_close_response(dialog, "cancel");
        c.adw_alert_dialog_choose(dialog, @ptrCast(@alignCast(self.window)), null, onOverwriteResponse, @ptrCast(ctx));
    }

    fn onOverwriteResponse(source: [*c]c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
        const ctx = cast.userData(OverwriteCtx, user);
        const self = ctx.self;
        defer {
            self.allocator.free(ctx.spec);
            self.allocator.free(ctx.name);
            self.allocator.destroy(ctx);
        }
        const dialog: *c.AdwAlertDialog = @ptrCast(@alignCast(source));
        const resp_c = c.adw_alert_dialog_choose_finish(dialog, result);
        const resp = std.mem.span(@as([*:0]const u8, @ptrCast(resp_c)));
        if (!std.mem.eql(u8, resp, "replace")) return;
        self.deliver(&.{ctx.spec}, ctx.name);
    }
};

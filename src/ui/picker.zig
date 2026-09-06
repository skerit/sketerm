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
//!
//! The name/location entry is present in EVERY mode, not just
//! save_file. Non-empty text always wins over the listing selection:
//! it is resolved (bare name, relative path, absolute path, `~`)
//! against the shown directory by fpicker.resolveTyped, its kind is
//! answered by the loaded listing when possible and by a daemon
//! `stat` probe otherwise (the GUI never touches the disk, so remote
//! hosts resolve exactly the same way), and fpicker.typedAction
//! decides between browsing into it, accepting it and refusing it.
//! A refusal is stated in the browser's status line and marks the
//! entry with the "error" style, the same channel the location bar
//! uses for a bad path.
//!
//! Selection -> entry rule: a selection of exactly ONE row writes
//! that row's name into the entry (save_file only adopts files, so
//! browsing does not clobber a typed save name); a MULTI selection
//! clears the entry, because in open_files the whole selection is
//! the answer and an entry naming one of its members would be a
//! lie; an EMPTY selection leaves the entry alone. Browsing to
//! another directory clears the entry (a bare name only meant
//! something where it came from); save_file is exempt, since its
//! name belongs to the document, not to the folder.
//!
//! Two rules are OPT-IN per request, because they belong to a
//! picker opened FOR ANOTHER APPLICATION (the portal backend) and
//! would be wrong for sketerm's own dialogs:
//! `enforce_filter` extends the active name filter from the listing
//! to TYPED names, so an app that asked for *.png cannot be handed
//! notes.txt by someone typing it -- "All files" stays in the
//! dropdown as the escape hatch; and `local_only` refuses a pick on
//! another host in the dialog (alert + status line) instead of
//! letting a consumer that can only open local paths receive a spec
//! it cannot use.
//!
//! A save target that does not exist gets a SECOND daemon stat, on
//! its parent directory: accepting "/nope/out.txt" would otherwise
//! only fail much later, inside the consumer's write. The picker
//! never creates the directory.
//!
//! Focus policy: save_file focuses the entry (the name is the point
//! of the dialog), every other mode focuses the listing so arrow
//! navigation and type-ahead work the moment the picker opens. The
//! entry lives OUTSIDE BrowserView.root_box, so the browser's key
//! controllers never see typing that is meant for it.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const fpicker = @import("../filebrowser/picker.zig");
const paths = @import("../filebrowser/paths.zig");
const BrowserView = @import("browser/view.zig").BrowserView;
const PickerHooks = @import("browser/view.zig").PickerHooks;
const BTab = @import("browser/types.zig").BTab;
const nav = @import("browser/nav.zig");
const confirm = @import("confirm.zig");
const guessMime = @import("browser/open.zig").guessMime;

pub const ResultCb = *const fn (ctx: ?*anyopaque, result: ?fpicker.Result) void;

/// Resolve a picked spec to a path this process can open itself, or
/// explain why it cannot. Consumers that hand the path to a LOCAL
/// reader/writer (FreeType, the layout JSON loader, GIO byte writes)
/// have no way to honour a `host:/path` pick, and silently doing
/// nothing reads as a broken dialog — so say it. `detail` is the
/// second sentence, explaining why this particular action is local.
/// The returned slice borrows from `spec` (callback lifetime only).
pub fn localPathOrRefuse(
    parent: ?*c.GtkWindow,
    spec: []const u8,
    comptime detail: []const u8,
) ?[]const u8 {
    const loc = paths.parseSpec(spec);
    const host = loc.host orelse return loc.path;
    var body: [640:0]u8 = undefined;
    const b = std.fmt.bufPrintZ(
        &body,
        "\"{s}\" lives on {s}. " ++ detail,
        .{ loc.path, host },
    ) catch std.fmt.bufPrintZ(&body, detail, .{}) catch unreachable;
    _ = confirm.present(@ptrCast(@alignCast(parent)), .{
        .heading = "Remote file",
        .body = b.ptr,
        .responses = &.{
            .{ .id = "ok", .label = "OK", .is_default = true, .is_close = true },
        },
    }, null);
    return null;
}

// -- foreign (portal) parent windows ------------------------------
//
// A portal caller hands us an EXPORTED handle for its own window, not
// a GdkSurface we could pass to gtk_window_set_transient_for. GTK4
// exposes exactly one importer, and only for Wayland
// (gdk_wayland_toplevel_set_transient_for_exported); for X11 it
// dropped GTK3's foreign-window support entirely, so the parent has
// to be set with XSetTransientForHint on the raw XIDs.
//
// Every backend symbol below is resolved with dlsym at RUNTIME rather
// than linked: a GTK built without one of the two backends (or a
// session without libX11 installed at all) must degrade to an
// unparented dialog, not to a binary that will not start.

const RTLD_LAZY: c_int = 1;
extern fn dlopen(file: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

fn displayTypeName(display: ?*c.GdkDisplay) []const u8 {
    const d = display orelse return "";
    const n = c.g_type_name_from_instance(@ptrCast(@alignCast(d))) orelse return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(n)));
}

/// Make `window` (already realized) a transient child of the portal
/// caller's window. Best effort by design: a handle we cannot import
/// leaves the dialog free-standing, which is how this backend behaved
/// before parenting existed.
fn applyForeignParent(window: *c.GtkWindow, handle: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const policy = @import("../portal.zig");
    const surface = c.gtk_native_get_surface(@ptrCast(@alignCast(window))) orelse return;
    const display = c.gtk_widget_get_display(@ptrCast(@alignCast(window)));
    const backend = displayTypeName(display);
    switch (policy.parseParentHandle(handle)) {
        .none => {},
        .wayland => |h| {
            if (!std.mem.eql(u8, backend, "GdkWaylandDisplay")) return;
            const sym = dlsym(null, "gdk_wayland_toplevel_set_transient_for_exported") orelse return;
            const fun: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) c.gboolean =
                @ptrCast(@alignCast(sym));
            var hz: [256:0]u8 = undefined;
            if (h.len >= hz.len) return;
            @memcpy(hz[0..h.len], h);
            hz[h.len] = 0;
            _ = fun(@ptrCast(surface), &hz);
        },
        .x11 => |xid| {
            if (!std.mem.eql(u8, backend, "GdkX11Display")) return;
            const get_xid_sym = dlsym(null, "gdk_x11_surface_get_xid") orelse return;
            const get_dpy_sym = dlsym(null, "gdk_x11_display_get_xdisplay") orelse return;
            // libX11 is a transitive dependency of GTK's X11 backend,
            // never one of ours: open it by soname only when an x11
            // handle actually arrives.
            const xlib = dlopen("libX11.so.6", RTLD_LAZY) orelse return;
            const set_hint_sym = dlsym(xlib, "XSetTransientForHint") orelse return;
            const get_xid: *const fn (?*anyopaque) callconv(.c) c_ulong = @ptrCast(@alignCast(get_xid_sym));
            const get_dpy: *const fn (?*anyopaque) callconv(.c) ?*anyopaque = @ptrCast(@alignCast(get_dpy_sym));
            const set_hint: *const fn (?*anyopaque, c_ulong, c_ulong) callconv(.c) c_int =
                @ptrCast(@alignCast(set_hint_sym));
            const dpy = get_dpy(@ptrCast(display)) orelse return;
            const own = get_xid(@ptrCast(surface));
            if (own == 0) return;
            _ = set_hint(dpy, own, @intCast(xid));
        },
    }
}

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
    /// The active filter also governs typed names (portal rule).
    enforce_filter: bool = false,
    /// Refuse picks on other hosts instead of delivering them.
    local_only: bool = false,
    /// Portal parent handle, applied once the window is realized.
    foreign_parent: ?[]u8 = null,
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
    /// The one in-flight typed-name stat probe (a newer submit
    /// replaces it, so a slow host cannot answer for stale text).
    probe: ?*Probe = null,
    /// The directory the entry's text was last valid for: browsing
    /// away invalidates a name that names something here. save_file
    /// is exempt -- its name is the document's, not the folder's.
    last_dir: [4096]u8 = undefined,
    last_dir_len: usize = 0,

    /// A typed path whose kind only the host that owns it can tell.
    /// `stage` says which question is out: what the path IS, or (for
    /// a save target that does not exist yet) whether its parent
    /// directory does.
    const Probe = struct {
        req: u32,
        /// Always the full typed path, never the parent being probed.
        path: []u8,
        trailing_slash: bool,
        stage: Stage = .classify,
    };

    const Stage = enum { classify, parent };

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
        self.active_filter = @min(req.active_filter, self.filters.len);
        self.enforce_filter = req.enforce_filter;
        self.local_only = req.local_only;
        if (req.suggested_name) |sn| self.suggested_name = try allocator.dupe(u8, sn);
        if (req.accept_label) |al| self.accept_label = try allocator.dupe(u8, al);
        if (req.foreign_parent) |fp| self.foreign_parent = try allocator.dupe(u8, fp);
        self.hooks = .{
            .ctx = @ptrCast(self),
            .on_activate_file = &onActivateFile,
            .on_selection_changed = &onSelectionChanged,
            .on_reply = &onProbeReply,
            .visible = &visibleCb,
            .suppress_ops = true,
        };
        self.view = try BrowserView.attachForPicker(allocator, &self.hooks, req.initial_spec);
        self.buildWindow(parent, req.title);
        self.built = true;
        self.syncFromSelection();
        c.gtk_window_present(self.window);
        // Save mode is about the name; every other mode is about
        // browsing, and the listing needs the arrow keys.
        if (self.mode == .save_file and self.name_entry != null) {
            _ = c.gtk_widget_grab_focus(@ptrCast(@alignCast(self.name_entry.?)));
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
            const pats = try self.dupeStrings(f.patterns);
            errdefer self.freeStrings(pats);
            const mimes = try self.dupeStrings(f.mimes);
            out[i] = .{ .label = label, .patterns = pats, .mimes = mimes };
            done = i + 1;
        }
        self.filters = out;
    }

    fn dupeStrings(self: *PickerWindow, src: []const []const u8) ![]const []const u8 {
        const out = try self.allocator.alloc([]const u8, src.len);
        var done: usize = 0;
        errdefer {
            for (out[0..done]) |p| self.allocator.free(@constCast(p));
            self.allocator.free(out);
        }
        for (src, 0..) |p, i| {
            out[i] = try self.allocator.dupe(u8, p);
            done = i + 1;
        }
        return out;
    }

    fn freeStrings(self: *PickerWindow, list: []const []const u8) void {
        for (list) |p| self.allocator.free(@constCast(p));
        self.allocator.free(list);
    }

    fn freeFilterSlice(self: *PickerWindow, fs: []fpicker.Filter, n: usize) void {
        for (fs[0..n]) |f| {
            self.allocator.free(@constCast(f.label));
            self.freeStrings(f.patterns);
            self.freeStrings(f.mimes);
        }
        self.allocator.free(fs);
    }

    fn freeOwned(self: *PickerWindow) void {
        self.clearProbe();
        if (self.filters.len > 0) self.freeFilterSlice(self.filters, self.filters.len);
        self.filters = &.{};
        if (self.suggested_name) |sn| self.allocator.free(sn);
        self.suggested_name = null;
        if (self.accept_label) |al| self.allocator.free(al);
        self.accept_label = null;
        if (self.foreign_parent) |fp| self.allocator.free(fp);
        self.foreign_parent = null;
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
            // Transient alone does NOT make GTK4 destroy us with the
            // parent — it only clears the link. Without this the picker
            // outlives the window that owns `cb_ctx` (the prefs dialog
            // frees its Ctx at finalize, a Pane is torn down), and the
            // next pick delivers a result into freed memory. With it,
            // `onWindowDestroy` fires inside the parent's own destroy
            // and hands every caller the null it already handles.
            c.gtk_window_set_destroy_with_parent(self.window, 1);
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

        // A foreign (portal) parent can only be imported once the
        // toplevel surface exists, i.e. at realize.
        if (self.foreign_parent != null)
            _ = c.g_signal_connect_data(window, "realize", @ptrCast(&onRealize), @ptrCast(self), null, c.G_CONNECT_DEFAULT);

        _ = c.g_signal_connect_data(window, "close-request", @ptrCast(&onCloseRequest), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&onWindowDestroy), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    }

    fn buildFooter(self: *PickerWindow) *c.GtkWidget {
        const footer = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
        c.gtk_widget_set_margin_start(footer, 10);
        c.gtk_widget_set_margin_end(footer, 10);
        c.gtk_widget_set_margin_top(footer, 6);
        c.gtk_widget_set_margin_bottom(footer, 8);

        // Present in every mode: a name to save under, the selected
        // entry's name, or a path typed straight in.
        const label = c.gtk_label_new("Name:");
        c.gtk_widget_add_css_class(label, "dim-label");
        c.gtk_box_append(@ptrCast(footer), label);
        const entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(entry, 1);
        c.gtk_entry_set_placeholder_text(@ptrCast(entry), switch (self.mode) {
            .select_dir, .select_destination => "folder name or path",
            else => "file name or path",
        });
        if (self.suggested_name) |sn| self.setEntryText(@ptrCast(@alignCast(entry)), sn);
        _ = c.g_signal_connect_data(entry, "changed", @ptrCast(&onNameChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onPrimaryClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(footer), entry);
        self.name_entry = @ptrCast(@alignCast(entry));

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
        c.gtk_drop_down_set_selected(@ptrCast(dd), @intCast(self.active_filter));
        _ = c.g_signal_connect_data(dd, "notify::selected", @ptrCast(&onFilterSelected), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(footer), dd);
    }

    // -- browser hooks -------------------------------------------

    fn visibleCb(ctx: *anyopaque, name: []const u8, is_dir: bool) bool {
        const self: *PickerWindow = @ptrCast(@alignCast(ctx));
        if (is_dir) return true;
        if (!fpicker.showsFiles(self.mode)) return false;
        return self.activeFilterAccepts(name);
    }

    /// The active filter's verdict on one basename. Mimetype patterns
    /// are answered by the type GIO guesses from the NAME (never from
    /// content: the file may live on another host, and the GUI does
    /// not touch the disk), with GIO's own subtype relation as a
    /// second chance so a "text/plain" filter still takes text/x-zig.
    fn activeFilterAccepts(self: *PickerWindow, name: []const u8) bool {
        if (self.active_filter >= self.filters.len) return true;
        const f = self.filters[self.active_filter];
        var buf: [256]u8 = undefined;
        const mime = if (f.mimes.len > 0) guessMime(&buf, name) else "";
        return fpicker.filterMatches(f, name, mime) or subtypeAccepts(f, mime);
    }

    /// GIO's mimetype subtype relation, the second chance a plain
    /// string compare cannot give: text/x-zig IS a text/plain.
    /// Wildcard patterns are already handled by the glob match.
    fn subtypeAccepts(f: fpicker.Filter, mime: []const u8) bool {
        if (mime.len == 0) return false;
        for (f.mimes) |m| {
            if (std.mem.indexOfScalar(u8, m, '*') != null) continue;
            if (contentTypeIsA(mime, m)) return true;
        }
        return false;
    }

    fn contentTypeIsA(mime: []const u8, super: []const u8) bool {
        var a: [256:0]u8 = undefined;
        var b: [256:0]u8 = undefined;
        const az = std.fmt.bufPrintZ(&a, "{s}", .{mime}) catch return false;
        const bz = std.fmt.bufPrintZ(&b, "{s}", .{super}) catch return false;
        return c.g_content_type_is_a(az.ptr, bz.ptr) != 0;
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

    /// Selection -> footer: the entry follows a single selected row,
    /// a multi selection empties it (the selection itself is then the
    /// answer), an empty selection leaves typed text alone. Plus
    /// primary-button sensitivity. The single sync point, also run
    /// once at build.
    fn syncFromSelection(self: *PickerWindow) void {
        self.noteDirectory();
        const sel = self.currentSelection();
        if (sel.files + sel.dirs > 1) {
            self.setNameEntry("");
        } else if (sel.files == 1 and sel.dirs == 0) {
            if (sel.first_file) |p| self.setNameEntry(std.fs.path.basename(p));
        } else if (sel.dirs == 1 and sel.files == 0 and self.mode != .save_file) {
            // A save name must survive browsing; every other mode can
            // show the highlighted folder.
            if (sel.first_dir) |p| self.setNameEntry(std.fs.path.basename(p));
        }
        self.updatePrimary(sel);
    }

    /// Browsing elsewhere drops a name that only meant something in
    /// the directory it came from ("sub" after entering sub/ would
    /// otherwise resolve to sub/sub).
    fn noteDirectory(self: *PickerWindow) void {
        const tab = self.view.currentTab() orelse return;
        const p = tab.root.path;
        if (p.len >= self.last_dir.len) return;
        if (std.mem.eql(u8, p, self.last_dir[0..self.last_dir_len])) return;
        @memcpy(self.last_dir[0..p.len], p);
        self.last_dir_len = p.len;
        if (self.mode != .save_file) self.setNameEntry("");
    }

    /// The primary is live whenever SOMETHING would be picked: typed
    /// text always counts (its validity is decided on submit, where
    /// the failure can be explained), otherwise the selection rule of
    /// the mode applies.
    fn updatePrimary(self: *PickerWindow, sel: Selection) void {
        const on = self.nameText().len > 0 or switch (self.mode) {
            .open_file => sel.files == 1 and sel.dirs == 0,
            .open_files => sel.files >= 1 and sel.dirs == 0,
            .select_dir, .select_destination => true,
            .save_file => false,
        };
        c.gtk_widget_set_sensitive(self.primary, @intFromBool(on));
    }

    fn nameText(self: *PickerWindow) []const u8 {
        const entry = self.name_entry orelse return "";
        return std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(@alignCast(entry))))));
    }

    fn setEntryText(_: *PickerWindow, entry: *c.GtkEntry, text: []const u8) void {
        var z: [4096:0]u8 = undefined;
        const n = @min(text.len, z.len - 1);
        @memcpy(z[0..n], text[0..n]);
        z[n] = 0;
        c.gtk_editable_set_text(@ptrCast(@alignCast(entry)), &z);
    }

    fn setNameEntry(self: *PickerWindow, name: []const u8) void {
        const entry = self.name_entry orelse return;
        self.setEntryText(entry, name);
    }

    fn markEntryError(self: *PickerWindow, bad: bool) void {
        const entry = self.name_entry orelse return;
        const w: *c.GtkWidget = @ptrCast(@alignCast(entry));
        if (bad) c.gtk_widget_add_css_class(w, "error") else c.gtk_widget_remove_css_class(w, "error");
    }

    // -- signal handlers -----------------------------------------

    fn onNameChanged(_: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(PickerWindow, user);
        if (!self.built or self.view.widgets_dead) return;
        self.markEntryError(false);
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

    fn onRealize(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
        const self = cast.userData(PickerWindow, user);
        const fp = self.foreign_parent orelse return;
        applyForeignParent(self.window, fp);
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

    /// Invoke the callback exactly once and self-destruct. The single
    /// funnel every accept path goes through, so the local-only rule
    /// is checked in exactly one place.
    fn deliver(self: *PickerWindow, specs: []const []const u8, name: ?[]const u8) void {
        if (self.delivered) return;
        if (self.local_only and self.refuseRemote(specs)) return;
        self.delivered = true;
        self.cb(self.cb_ctx, .{
            .specs = specs,
            .name = name,
            .filter_index = if (self.active_filter < self.filters.len) self.active_filter else null,
        });
        self.view.widgets_dead = true;
        c.gtk_window_destroy(self.window);
    }

    /// A picker opened for another application can only answer with
    /// paths that application can open ITSELF. Rather than dropping
    /// remote picks silently on the way out (which reads as a dialog
    /// that did nothing), say so at the moment of picking and leave
    /// the dialog open on the host the user was browsing.
    /// @return true when the pick was refused.
    fn refuseRemote(self: *PickerWindow, specs: []const []const u8) bool {
        var host: ?[]const u8 = null;
        var leaf: []const u8 = "";
        for (specs) |spec| {
            const loc = paths.parseSpec(spec);
            if (loc.host) |h| {
                host = h;
                leaf = std.fs.path.basename(loc.path);
                break;
            }
        }
        const h = host orelse return false;
        var body: [640:0]u8 = undefined;
        const b = std.fmt.bufPrintZ(
            &body,
            "\"{s}\" lives on {s}. The application that opened this dialog reads " ++
                "and writes files on this machine only, so it cannot use a file on " ++
                "another host. Copy it here first, then pick the local copy.",
            .{ leaf, h },
        ) catch std.fmt.bufPrintZ(&body, "The application that opened this dialog can only use files on this machine.", .{}) catch unreachable;
        _ = confirm.present(@ptrCast(@alignCast(self.window)), .{
            .heading = "File is on another host",
            .body = b.ptr,
            .responses = &.{
                .{ .id = "ok", .label = "OK", .is_default = true, .is_close = true },
            },
        }, null);
        self.view.setStatusFmt("\"{s}\" is on {s}; this dialog can only return local files", .{ leaf, h });
        self.markEntryError(true);
        return true;
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
        if (self.delivered or self.view.widgets_dead) return;
        const tab = self.view.currentTab() orelse return;
        // Typed text always wins: it is what the user last said.
        const typed = self.nameText();
        if (typed.len > 0) return self.submitTyped(tab, typed);
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
            // Nothing typed and nothing to adopt from the listing.
            .save_file => {},
        }
    }

    // -- typed name/location -------------------------------------

    /// Submit the entry's text: resolve it against the shown
    /// directory, then answer its kind from the loaded listing when
    /// we can and from the daemon when we cannot.
    fn submitTyped(self: *PickerWindow, tab: *BTab, text: []const u8) void {
        var buf: [4096]u8 = undefined;
        const typed = fpicker.resolveTyped(&buf, tab.root.path, tab.hc.home_dir, text) orelse {
            self.rejectTyped(text, "cannot be resolved to a path");
            return;
        };
        if (std.mem.eql(u8, typed.path, tab.root.path))
            return self.applyTyped(tab, typed.path, .dir, typed.trailing_slash);
        if (nav.entryForPath(tab, typed.path)) |e|
            return self.applyTyped(tab, typed.path, if (e.tdir) .dir else .file, typed.trailing_slash);
        self.startProbe(tab, typed.path, typed.trailing_slash, .classify);
    }

    /// Ask the host that owns the path what it is (`.classify`), or
    /// whether the parent directory of a new save target exists
    /// (`.parent`). One probe at a time; the reply lands in
    /// onProbeReply.
    fn startProbe(self: *PickerWindow, tab: *BTab, path: []const u8, trailing: bool, stage: Stage) void {
        const target = if (stage == .parent)
            (fpicker.parentDir(path) orelse {
                self.rejectTyped(path, "has no parent folder");
                return;
            })
        else
            path;
        var tbuf: [4096]u8 = undefined;
        if (target.len >= tbuf.len) return;
        @memcpy(tbuf[0..target.len], target);

        self.clearProbe();
        const owned = self.allocator.dupe(u8, path) catch return;
        const p = self.allocator.create(Probe) catch {
            self.allocator.free(owned);
            return;
        };
        p.* = .{
            .req = self.view.nextReq(),
            .path = owned,
            .trailing_slash = trailing,
            .stage = stage,
        };
        self.probe = p;
        self.view.sendOp(tab.hc, .{ .req = p.req, .op = "stat", .path = tbuf[0..target.len] });
    }

    fn clearProbe(self: *PickerWindow) void {
        const p = self.probe orelse return;
        self.probe = null;
        self.allocator.free(p.path);
        self.allocator.destroy(p);
    }

    fn onProbeReply(ctx: *anyopaque, req: u32, ok: bool, is_dir: ?bool) bool {
        const self: *PickerWindow = @ptrCast(@alignCast(ctx));
        const p = self.probe orelse return false;
        if (p.req != req) return false;
        var pbuf: [4096]u8 = undefined;
        if (p.path.len >= pbuf.len) {
            self.clearProbe();
            return true;
        }
        @memcpy(pbuf[0..p.path.len], p.path);
        const path = pbuf[0..p.path.len];
        const trailing = p.trailing_slash;
        const stage = p.stage;
        self.clearProbe();
        if (self.delivered or !self.built or self.view.widgets_dead) return true;
        const tab = self.view.currentTab() orelse return true;
        if (stage == .parent) {
            // Pre-flight for a save target that does not exist yet:
            // the folder it names has to, or the consumer's write
            // fails long after this dialog is gone. Directories are
            // never created implicitly.
            if (ok and is_dir != null and is_dir.?) {
                self.acceptTyped(tab, path, .missing);
            } else {
                const parent = fpicker.parentDir(path) orelse "/";
                self.rejectTyped(parent, if (ok) "is not a folder" else "does not exist, so nothing can be saved there");
            }
            return true;
        }
        const kind: fpicker.TypedKind = if (!ok or is_dir == null)
            .missing
        else if (is_dir.?) .dir else .file;
        self.applyTyped(tab, path, kind, trailing);
        return true;
    }

    /// The verdict, acted on: browse into it, pick it, or say why not.
    fn applyTyped(self: *PickerWindow, tab: *BTab, path: []const u8, kind: fpicker.TypedKind, trailing: bool) void {
        switch (fpicker.typedAction(self.mode, kind, trailing)) {
            .navigate => {
                // navigate() may free storage `path` aliases.
                var pbuf: [4096]u8 = undefined;
                if (path.len >= pbuf.len) return;
                @memcpy(pbuf[0..path.len], path);
                self.setNameEntry("");
                self.markEntryError(false);
                self.view.navigate(tab, tab.hc.host, pbuf[0..path.len]);
            },
            .accept => {
                // The filter governs typed names too when the caller
                // asked for it (portal mode); "All files" is the way
                // out and is always in the dropdown.
                const leaf = std.fs.path.basename(path);
                if (!fpicker.acceptsDirs(self.mode) and !self.typedNamePassesFilter(leaf)) {
                    self.markEntryError(true);
                    self.view.setStatusFmt(
                        "\"{s}\" does not match the \"{s}\" filter -- rename it or choose All files",
                        .{ leaf, self.filters[self.active_filter].label },
                    );
                    return;
                }
                if (fpicker.needsParentProbe(self.mode, kind, trailing))
                    return self.startProbe(tab, path, trailing, .parent);
                self.acceptTyped(tab, path, kind);
            },
            .reject => {
                const name = std.fs.path.basename(path);
                self.rejectTyped(name, switch (kind) {
                    .missing => "does not exist",
                    .file => if (trailing) "is not a folder" else "is a file, and this dialog needs a folder",
                    .dir => "is a folder",
                });
            },
        }
    }

    /// The accepted path, delivered (save_file confirms an overwrite
    /// first). Split out of applyTyped because the save pre-flight
    /// reaches it a daemon round trip later.
    fn acceptTyped(self: *PickerWindow, tab: *BTab, path: []const u8, kind: fpicker.TypedKind) void {
        self.markEntryError(false);
        var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
        if (self.mode == .save_file) {
            const leaf = std.fs.path.basename(path);
            if (kind == .file) return self.confirmOverwrite(path, leaf);
            self.deliver(&.{paths.formatSpec(&buf, tab.hc.host, path)}, leaf);
            return;
        }
        self.deliver(&.{paths.formatSpec(&buf, tab.hc.host, path)}, null);
    }

    fn typedNamePassesFilter(self: *PickerWindow, leaf: []const u8) bool {
        if (!self.enforce_filter or self.active_filter >= self.filters.len) return true;
        const f = self.filters[self.active_filter];
        var buf: [256]u8 = undefined;
        const mime = if (f.mimes.len > 0) guessMime(&buf, leaf) else "";
        return fpicker.typedNameAllowed(self.filters, self.active_filter, leaf, mime, true) or
            subtypeAccepts(f, mime);
    }

    /// State a refusal where the browser states its other path
    /// failures, and mark the entry so the eye lands on it.
    fn rejectTyped(self: *PickerWindow, name: []const u8, why: []const u8) void {
        self.markEntryError(true);
        self.view.setStatusFmt("\"{s}\" {s}", .{ name, why });
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
        if (confirm.present(@ptrCast(@alignCast(self.window)), .{
            .heading = "Replace file?",
            .body = b.ptr,
            .responses = &.{
                .{ .id = "cancel", .label = "Cancel", .is_default = true, .is_close = true },
                .{ .id = "replace", .label = "Replace", .appearance = .destructive },
            },
        }, .{ .allocator = self.allocator, .cb = &onOverwriteResponse, .ctx = @ptrCast(ctx) }) == null) {
            self.allocator.free(ctx.spec);
            self.allocator.free(ctx.name);
            self.allocator.destroy(ctx);
        }
    }

    fn onOverwriteResponse(user: ?*anyopaque, resp: []const u8) void {
        const ctx = cast.userData(OverwriteCtx, user);
        const self = ctx.self;
        defer {
            self.allocator.free(ctx.spec);
            self.allocator.free(ctx.name);
            self.allocator.destroy(ctx);
        }
        if (!std.mem.eql(u8, resp, "replace")) return;
        self.deliver(&.{ctx.spec}, ctx.name);
    }
};

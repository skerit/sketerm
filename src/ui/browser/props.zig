//! The Properties dialog: permissions/ownership editing, extended
//! attributes, and the label probes (folder size, checksum, media
//! info) that fill its fields from daemon jobs.

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");
const colkeys = @import("../../filebrowser/colkeys.zig");
const fsserve = @import("../../mux/fsserve.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const MenuCtx = @import("menu.zig").MenuCtx;
const PendingJob = @import("types.zig").PendingJob;
const WireJobEv = @import("types.zig").WireJobEv;
const copyZ = @import("../../filebrowser/format.zig").copyZ;
const entryForPath = @import("nav.zig").entryForPath;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const fmtTimeZ = @import("../../filebrowser/format.zig").fmtTimeZ;
const isPreviewMediaName = @import("../../filebrowser/paths.zig").isPreviewMediaName;
const menuDone = @import("menu.zig").menuDone;

/// Recursive size probe: a daemon job so the walk happens on the
/// host that owns the tree.
/// One widget fed by a daemon job: recursive size, checksum, or
/// media metadata. The widget is g_object_ref'd, so a dialog closed
/// mid-flight cannot dangle.
///
/// `target` is a GtkLabel for size/hash and the CONTAINER the
/// structured rows go into for `.media` -- one probe mechanism, two
/// shapes of result, rather than a second async path for metadata.
pub const LabelProbe = struct {
    kind: enum { size, hash, media },
    req: u32,
    job: u64 = 0,
    hc: *HostConn,
    label: *c.GtkWidget,
    /// A duration this file's host DERIVED from a bitrate, latched
    /// from the field stream so the row can say so (fields arrive in
    /// one batch, but not in a guaranteed order).
    duration_estimated: bool = false,
};

/// Show a plain message on a probe's target, whatever its shape.
fn setProbeText(probe: LabelProbe, message: [*:0]const u8) void {
    if (probe.kind != .media) return c.gtk_label_set_text(@ptrCast(probe.label), message);
    clearBox(probe.label);
    const lbl = c.gtk_label_new(message);
    c.gtk_label_set_xalign(@ptrCast(lbl), 0);
    c.gtk_label_set_ellipsize(@ptrCast(lbl), c.PANGO_ELLIPSIZE_END);
    c.gtk_widget_add_css_class(lbl, "dim-label");
    c.gtk_box_append(@ptrCast(probe.label), lbl);
}

fn clearBox(box: *c.GtkWidget) void {
    while (c.gtk_widget_get_first_child(box)) |child| c.gtk_box_remove(@ptrCast(box), child);
}

pub fn endProbe(self: *BrowserView, i: usize) void {
    const probe = self.probes.items[i];
    c.g_object_unref(@ptrCast(probe.label));
    _ = self.probes.orderedRemove(i);
}

pub fn endProbesFor(self: *BrowserView, hc: ?*HostConn, message: [*:0]const u8) void {
    // A null host means "every probe of this view", which only the
    // view's own teardown asks for -- and a Properties toplevel must
    // not outlive the view its buttons call into.
    if (hc == null) closePropsWindows(self);
    var i: usize = 0;
    while (i < self.probes.items.len) {
        const probe = self.probes.items[i];
        if (hc == null or probe.hc == hc.?) {
            setProbeText(probe, message);
            self.endProbe(i);
        } else i += 1;
    }
}

pub fn startProbe(self: *BrowserView, kind: @FieldType(LabelProbe, "kind"), hc: *HostConn, label: *c.GtkWidget, op: []const u8, path: []const u8) void {
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    const req = self.nextReq();
    _ = c.g_object_ref(@ptrCast(label));
    self.probes.append(self.allocator, .{ .kind = kind, .req = req, .hc = hc, .label = label }) catch {
        c.g_object_unref(@ptrCast(label));
        return;
    };
    setProbeText(self.probes.items[self.probes.items.len - 1], "reading...");
    // media_meta names its files in `pattern` (it is a batch op);
    // one file is simply a batch of one.
    if (kind == .media)
        self.sendOp(hc, .{ .req = req, .op = op, .path = "/", .pattern = path })
    else
        self.sendOp(hc, .{ .req = req, .op = op, .path = path });
}

pub fn feedProbes(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    if (self.probes.items.len == 0) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    switch (ftype) {
        .fs_reply => {
            const rep = std.json.parseFromSliceLeaky(struct {
                req: u32 = 0,
                ok: bool = false,
                job: u64 = 0,
            }, arena.allocator(), payload, .{ .ignore_unknown_fields = true }) catch return false;
            for (self.probes.items, 0..) |*probe, i| {
                if (probe.hc != hc or probe.req != rep.req) continue;
                if (!rep.ok or rep.job == 0) {
                    setProbeText(probe.*, "unavailable");
                    self.endProbe(i);
                } else probe.job = rep.job;
                return true;
            }
            return false;
        },
        .fs_job => {
            const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return false;
            for (self.probes.items, 0..) |*probe, i| {
                if (probe.hc != hc or probe.job == 0 or probe.job != ev.job) continue;
                const done = std.mem.eql(u8, ev.ev, "done");
                if (probe.kind == .media) {
                    // media_meta streams one `match` per file; the
                    // rows are built from it, and `done` only ends
                    // the probe.
                    if (std.mem.eql(u8, ev.ev, "match")) {
                        renderMediaFields(probe, ev);
                        return true;
                    }
                    if (ev.terminalEv()) {
                        if (!done or c.gtk_widget_get_first_child(probe.label) == null)
                            setProbeText(probe.*, if (done) "no metadata found" else "unavailable");
                        self.endProbe(i);
                    }
                    return true;
                }
                if (!done and !std.mem.eql(u8, ev.ev, "progress")) {
                    if (ev.terminalEv()) {
                        setProbeText(probe.*, "unavailable");
                        self.endProbe(i);
                    }
                    return true;
                }
                var buf: [1024:0]u8 = undefined;
                var human: [48:0]u8 = undefined;
                const text: [*:0]const u8 = switch (probe.kind) {
                    .size => if (std.fmt.bufPrintZ(&buf, "{s} ({d} bytes) in {d} items{s}", .{
                        fmtSize(&human, ev.done), ev.done, ev.total, if (done) "" else " ...",
                    })) |v| v.ptr else |_| "",
                    .hash => if (!done) "hashing..." else copyZ(@ptrCast(&buf), ev.hash),
                    // Handled entirely above; never reached.
                    .media => "",
                };
                c.gtk_label_set_text(@ptrCast(probe.label), text);
                if (done) self.endProbe(i);
                return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Turn one media_meta match into labelled rows.
///
/// The daemon skipped the file when it sends a `text` note instead of
/// fields; that note is shown verbatim rather than as "no metadata",
/// since "not a regular file" and "this file carries none" are
/// different answers.
fn renderMediaFields(probe: *LabelProbe, ev: WireJobEv) void {
    clearBox(probe.label);
    if (ev.meta.len == 0) {
        const note = if (ev.text.len > 0) ev.text else "no metadata found";
        var nz: [256:0]u8 = undefined;
        const lbl = c.gtk_label_new(copyZ(@ptrCast(&nz), note));
        c.gtk_label_set_xalign(@ptrCast(lbl), 0);
        c.gtk_widget_add_css_class(lbl, "dim-label");
        c.gtk_box_append(@ptrCast(probe.label), lbl);
        return;
    }
    for (ev.meta) |f| {
        if (std.mem.eql(u8, f.k, "media.duration_estimated"))
            probe.duration_estimated = std.mem.eql(u8, f.v, "1");
    }
    for (ev.meta) |f| {
        // The estimated flag drives the duration row's wording; a
        // row of its own would just repeat it.
        if (std.mem.eql(u8, f.k, "media.duration_estimated")) continue;
        var disp: [256]u8 = undefined;
        propsRow(
            probe.label,
            colkeys.label(f.k),
            colkeys.display(f.k, f.v, probe.duration_estimated, true, &disp),
        );
    }
    if (ev.cached) {
        const note = c.gtk_label_new("read from the host's metadata cache");
        c.gtk_label_set_xalign(@ptrCast(note), 0);
        c.gtk_widget_add_css_class(note, "dim-label");
        c.gtk_box_append(@ptrCast(probe.label), note);
    }
}

/// Properties: identity + timestamps, an on-demand recursive size
/// for directories, and a full permission/ownership editor with
/// optional recursive apply.
pub const PropsCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    path: []u8,
    is_dir: bool,
    /// u/g/o x r/w/x, then setuid/setgid/sticky.
    perm_bits: [12]*c.GtkWidget = undefined,
    octal: *c.GtkWidget = undefined,
    uid_entry: *c.GtkWidget = undefined,
    gid_entry: *c.GtkWidget = undefined,
    recursive: ?*c.GtkWidget = null,
    size_label: *c.GtkWidget = undefined,
    hash_label: *c.GtkWidget = undefined,
    media_label: ?*c.GtkWidget = null,
    attr_box: *c.GtkWidget = undefined,
    attr_name_entry: *c.GtkWidget = undefined,
    attr_value_entry: *c.GtkWidget = undefined,
    /// The toplevel this context is attached to, so the view can
    /// close its dialogs when it goes away.
    window: *c.GtkWidget = undefined,
    syncing: bool = false,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        forgetPropsWindow(ctx.allocator, ctx.window);
        ctx.allocator.free(ctx.path);
        ctx.allocator.destroy(ctx);
    }

    /// False once the tab this dialog describes has been closed: the
    /// dialog is a toplevel and outlives its tab, so every callback
    /// that dereferences `tab` must ask first.
    fn tabAlive(self: *const PropsCtx) bool {
        for (self.view.tabs.items) |t| {
            if (t == self.tab) return true;
        }
        return false;
    }

    /// The host connection this dialog acts through, or null (with a
    /// status note) once its tab is gone.
    fn liveHost(self: *const PropsCtx) ?*HostConn {
        if (!self.tabAlive()) {
            self.view.setStatus("properties: that tab was closed");
            return null;
        }
        return self.tab.hc;
    }

    /// Bit weight of perm_bits[i]: 0o400 down to 0o1, then the
    /// setuid/setgid/sticky triple.
    fn weight(i: usize) u32 {
        if (i < 9) return @as(u32, 1) << @intCast(8 - i);
        return switch (i) {
            9 => 0o4000,
            10 => 0o2000,
            else => 0o1000,
        };
    }

    fn modeFromChecks(self: *const PropsCtx) u32 {
        var mode: u32 = 0;
        for (self.perm_bits, 0..) |btn, i| {
            if (c.gtk_check_button_get_active(@ptrCast(btn)) != 0) mode |= weight(i);
        }
        return mode;
    }

    fn applyChecks(self: *PropsCtx, mode: u32) void {
        self.syncing = true;
        for (self.perm_bits, 0..) |btn, i|
            c.gtk_check_button_set_active(@ptrCast(btn), @intFromBool(mode & weight(i) != 0));
        self.syncing = false;
    }

    fn setOctal(self: *PropsCtx, mode: u32) void {
        var buf: [16:0]u8 = undefined;
        const txt = std.fmt.bufPrintZ(&buf, "{o:0>4}", .{mode & 0o7777}) catch return;
        self.syncing = true;
        c.gtk_editable_set_text(@ptrCast(self.octal), txt.ptr);
        self.syncing = false;
    }
};

/// Open Properties toplevels, so a dying BrowserView can take its
/// dialogs down with it (they are real windows now, not popovers
/// parented into the tab, so nothing else destroys them).
///
/// Process-wide rather than a BrowserView field only because every
/// entry names its view; lookups are by view pointer, so two views --
/// or two files -- never see each other's dialogs.
const OpenProps = struct { view: *BrowserView, window: *c.GtkWidget };
var open_props: std.ArrayList(OpenProps) = .empty;

fn rememberPropsWindow(alloc: std.mem.Allocator, view: *BrowserView, window: *c.GtkWidget) void {
    open_props.append(alloc, .{ .view = view, .window = window }) catch {};
}

fn forgetPropsWindow(alloc: std.mem.Allocator, window: *c.GtkWidget) void {
    for (open_props.items, 0..) |entry, i| {
        if (entry.window == window) {
            _ = open_props.orderedRemove(i);
            break;
        }
    }
    // The last dialog closing releases the tracking array too, so
    // nothing outlives the run.
    if (open_props.items.len == 0) open_props.clearAndFree(alloc);
}

/// Destroy every Properties window this view opened.
///
/// The entry is dropped BEFORE the destroy, because destroying the
/// window runs `PropsCtx.free`, which would otherwise try to remove
/// it again mid-iteration.
pub fn closePropsWindows(self: *BrowserView) void {
    var i: usize = 0;
    while (i < open_props.items.len) {
        if (open_props.items[i].view != self) {
            i += 1;
            continue;
        }
        const window = open_props.orderedRemove(i).window;
        c.gtk_window_destroy(@ptrCast(window));
    }
}

pub fn propsRow(box: *c.GtkWidget, label: []const u8, value: []const u8) void {
    var buf: [1024:0]u8 = undefined;
    const txt = std.fmt.bufPrintZ(&buf, "{s}: {s}", .{ label, value }) catch return;
    const w = c.gtk_label_new(txt.ptr);
    c.gtk_label_set_xalign(@ptrCast(w), 0);
    c.gtk_label_set_selectable(@ptrCast(w), 1);
    c.gtk_label_set_ellipsize(@ptrCast(w), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_box_append(@ptrCast(box), w);
}

pub fn onMenuProperties(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const old: *MenuCtx = @ptrCast(@alignCast(user.?));
    const old_path = old.path orelse return menuDone(old);
    const self = old.view;
    const tab = old.tab;
    // Pop the context menu down FIRST: a popover built while the
    // menu is still up loses its grab when the menu closes.
    var path_buf: [4096]u8 = undefined;
    const n = @min(old_path.len, path_buf.len);
    @memcpy(path_buf[0..n], old_path[0..n]);
    const path = path_buf[0..n];
    menuDone(old);
    const e = entryForPath(tab, path) orelse {
        self.setStatus("properties: entry is no longer in the listing");
        return;
    };
    // An AdwWindow (not a bare GtkWindow) so the dialog carries its
    // own header bar: the window is a real toplevel, and its title
    // and close button are drawn by the app rather than left to
    // whatever decorations the session provides.
    const window = c.adw_window_new();
    const ctx = self.allocator.create(PropsCtx) catch {
        c.gtk_window_destroy(@ptrCast(window));
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(ctx);
            c.gtk_window_destroy(@ptrCast(window));
            return;
        },
        .is_dir = e.tdir,
        .window = window,
    };
    c.g_object_set_data_full(@ptrCast(window), "sketerm-props", @ptrCast(ctx), @ptrCast(&PropsCtx.free));
    rememberPropsWindow(self.allocator, self, window);

    // A real, non-modal dialog: browsing continues behind it, and
    // several files can have their properties open side by side.
    var title_z: [576:0]u8 = undefined;
    const win_title = std.fmt.bufPrintZ(&title_z, "{s} Properties", .{std.fs.path.basename(path)}) catch "Properties";
    c.gtk_window_set_title(@ptrCast(window), win_title.ptr);
    // Tall enough that a plain file fits without a vertical
    // scrollbar; clamped to 90% of the monitor for small screens.
    var win_h: c.gint = 1120;
    if (c.gtk_widget_get_root(self.root_box)) |root| {
        c.gtk_window_set_transient_for(@ptrCast(window), @ptrCast(@alignCast(root)));
        if (c.gtk_native_get_surface(@ptrCast(@alignCast(root)))) |surface| {
            const display = c.gtk_widget_get_display(self.root_box);
            if (c.gdk_display_get_monitor_at_surface(display, surface)) |monitor| {
                var geo: c.GdkRectangle = undefined;
                c.gdk_monitor_get_geometry(monitor, &geo);
                win_h = @min(win_h, @divTrunc(geo.height * 9, 10));
            }
        }
    }
    c.gtk_window_set_default_size(@ptrCast(window), 440, win_h);
    const esc = c.gtk_shortcut_controller_new();
    c.gtk_shortcut_controller_add_shortcut(
        @ptrCast(esc),
        c.gtk_shortcut_new(
            c.gtk_keyval_trigger_new(c.GDK_KEY_Escape, 0),
            c.gtk_callback_action_new(@ptrCast(&onPropsEscape), @ptrCast(ctx), null),
        ),
    );
    c.gtk_widget_add_controller(window, esc);

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_margin_start(box, 10);
    c.gtk_widget_set_margin_end(box, 10);
    c.gtk_widget_set_margin_top(box, 10);
    c.gtk_widget_set_margin_bottom(box, 10);

    var name_z: [512:0]u8 = undefined;
    const title = c.gtk_label_new(copyZ(@ptrCast(&name_z), std.fs.path.basename(path)));
    c.gtk_widget_add_css_class(title, "heading");
    c.gtk_label_set_xalign(@ptrCast(title), 0);
    c.gtk_label_set_selectable(@ptrCast(title), 1);
    c.gtk_label_set_ellipsize(@ptrCast(title), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_box_append(@ptrCast(box), title);

    var scratch: [1024]u8 = undefined;
    propsRow(box, "Location", std.fs.path.dirname(path) orelse "/");
    propsRow(box, "Host", if (tab.hc.host) |h| h else "local");
    // MIME comes from the NAME only: guessing from content would
    // mean reading the file, which is wrong for a remote entry.
    var content_type: ?[*c]c.gchar = null;
    if (!e.tdir) {
        var basez: [512:0]u8 = undefined;
        content_type = c.g_content_type_guess(copyZ(@ptrCast(&basez), std.fs.path.basename(path)), null, 0, null);
    }
    defer if (content_type) |ct| c.g_free(ct);
    propsRow(box, "Type", if (content_type) |ct|
        std.fmt.bufPrint(&scratch, "{s} ({s})", .{ e.kind, std.mem.span(@as([*:0]const u8, @ptrCast(ct))) }) catch e.kind
    else
        e.kind);
    if (e.target) |t| propsRow(box, "Symlink target", t);
    var human: [48:0]u8 = undefined;
    // st_blocks is 0 on filesystems that do not report allocation
    // (tmpfs directories); saying "0 on disk" would read as a fact.
    propsRow(box, "Size", if (e.blocks > 0)
        std.fmt.bufPrint(&scratch, "{s} ({d} bytes, {d} on disk)", .{
            fmtSize(&human, e.size), e.size, e.blocks * 512,
        }) catch ""
    else
        std.fmt.bufPrint(&scratch, "{s} ({d} bytes)", .{ fmtSize(&human, e.size), e.size }) catch "");
    propsRow(box, "Links", std.fmt.bufPrint(&scratch, "{d}", .{e.nlink}) catch "");
    var tbuf: [40:0]u8 = undefined;
    propsRow(box, "Modified", std.mem.span(fmtTimeZ(&tbuf, e.mtime_ms)));
    propsRow(box, "Accessed", std.mem.span(fmtTimeZ(&tbuf, e.atime_ms)));
    propsRow(box, "Changed", std.mem.span(fmtTimeZ(&tbuf, e.ctime_ms)));

    if (e.tdir) {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        const lbl = c.gtk_label_new("Contents: not calculated");
        c.gtk_label_set_xalign(@ptrCast(lbl), 0);
        c.gtk_widget_set_hexpand(lbl, 1);
        ctx.size_label = lbl;
        c.gtk_box_append(@ptrCast(row), lbl);
        const calc = c.gtk_button_new_with_label("Calculate");
        _ = c.g_signal_connect_data(calc, "clicked", @ptrCast(&onPropsCalcSize), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), calc);
        c.gtk_box_append(@ptrCast(box), row);
    } else {
        // Checksum on demand: hashing runs on the file's host, so
        // a remote checksum never streams the file to us.
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        const lbl = c.gtk_label_new("SHA-256: not calculated");
        c.gtk_label_set_xalign(@ptrCast(lbl), 0);
        c.gtk_label_set_selectable(@ptrCast(lbl), 1);
        c.gtk_label_set_ellipsize(@ptrCast(lbl), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_widget_set_hexpand(lbl, 1);
        ctx.hash_label = lbl;
        c.gtk_box_append(@ptrCast(row), lbl);
        const calc = c.gtk_button_new_with_label("Checksum");
        _ = c.g_signal_connect_data(calc, "clicked", @ptrCast(&onPropsChecksum), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), calc);
        c.gtk_box_append(@ptrCast(box), row);

        // Default application, changeable from here.
        const app_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
        var app_buf: [256:0]u8 = undefined;
        const app_name: [*:0]const u8 = blk: {
            const ct = content_type orelse break :blk "Opens with: (unknown type)";
            const info = c.g_app_info_get_default_for_type(ct, 0) orelse break :blk "Opens with: (no default)";
            defer c.g_object_unref(@as(?*anyopaque, @ptrCast(info)));
            const name = c.g_app_info_get_display_name(info) orelse break :blk "Opens with: (no default)";
            if (std.fmt.bufPrintZ(&app_buf, "Opens with: {s}", .{std.mem.span(@as([*:0]const u8, @ptrCast(name)))})) |v| {
                break :blk v.ptr;
            } else |_| break :blk "Opens with:";
        };
        const app_label = c.gtk_label_new(app_name);
        c.gtk_label_set_xalign(@ptrCast(app_label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(app_label), c.PANGO_ELLIPSIZE_END);
        c.gtk_widget_set_hexpand(app_label, 1);
        c.gtk_box_append(@ptrCast(app_row), app_label);
        const change = c.gtk_button_new_with_label("Change…");
        _ = c.g_signal_connect_data(change, "clicked", @ptrCast(&onPropsOpenWith), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(app_row), change);
        c.gtk_box_append(@ptrCast(box), app_row);

        // Structured metadata for anything the host-side extractor
        // covers, images included: EXIF is the richest of the lot.
        if (isPreviewMediaName(path)) {
            const head_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            const head = c.gtk_label_new("Metadata");
            c.gtk_widget_add_css_class(head, "heading");
            c.gtk_label_set_xalign(@ptrCast(head), 0);
            c.gtk_widget_set_hexpand(head, 1);
            c.gtk_box_append(@ptrCast(head_row), head);
            const read = c.gtk_button_new_with_label("Read");
            _ = c.g_signal_connect_data(read, "clicked", @ptrCast(&onPropsMediaInfo), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(head_row), read);
            c.gtk_box_append(@ptrCast(box), head_row);
            // The probe fills THIS box with one labelled row per
            // field, so the media path is the same probe plumbing as
            // the size and checksum probes, not a second mechanism.
            const media_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
            const placeholder = c.gtk_label_new("not read");
            c.gtk_label_set_xalign(@ptrCast(placeholder), 0);
            c.gtk_widget_add_css_class(placeholder, "dim-label");
            c.gtk_box_append(@ptrCast(media_box), placeholder);
            ctx.media_label = media_box;
            c.gtk_box_append(@ptrCast(box), media_box);
        }
    }

    c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));

    // Extended attributes: metadata that travels WITH the file,
    // including the freedesktop comment and download origin.
    const attr_head = c.gtk_label_new("Attributes");
    c.gtk_widget_add_css_class(attr_head, "heading");
    c.gtk_label_set_xalign(@ptrCast(attr_head), 0);
    c.gtk_box_append(@ptrCast(box), attr_head);
    const attr_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    ctx.attr_box = attr_box;
    const loading = c.gtk_label_new("reading…");
    c.gtk_label_set_xalign(@ptrCast(loading), 0);
    c.gtk_widget_add_css_class(loading, "dim-label");
    c.gtk_box_append(@ptrCast(attr_box), loading);
    c.gtk_box_append(@ptrCast(box), attr_box);

    const add_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
    const add_name = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(add_name), "user.name");
    c.gtk_widget_set_hexpand(add_name, 1);
    const add_value = c.gtk_entry_new();
    c.gtk_entry_set_placeholder_text(@ptrCast(add_value), "value");
    c.gtk_widget_set_hexpand(add_value, 1);
    ctx.attr_name_entry = add_name;
    ctx.attr_value_entry = add_value;
    const add_btn = c.gtk_button_new_with_label("Set");
    _ = c.g_signal_connect_data(add_btn, "clicked", @ptrCast(&onPropsAttrAdd), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(add_row), add_name);
    c.gtk_box_append(@ptrCast(add_row), add_value);
    c.gtk_box_append(@ptrCast(add_row), add_btn);
    c.gtk_box_append(@ptrCast(box), add_row);
    self.requestAttrs(ctx);

    c.gtk_box_append(@ptrCast(box), c.gtk_separator_new(c.GTK_ORIENTATION_HORIZONTAL));

    const grid = c.gtk_grid_new();
    c.gtk_grid_set_row_spacing(@ptrCast(grid), 2);
    c.gtk_grid_set_column_spacing(@ptrCast(grid), 8);
    const who = [_][*:0]const u8{ "Owner", "Group", "Others" };
    const what = [_][*:0]const u8{ "read", "write", "exec" };
    for (who, 0..) |w, r| {
        const wl = c.gtk_label_new(w);
        c.gtk_label_set_xalign(@ptrCast(wl), 0);
        c.gtk_grid_attach(@ptrCast(grid), wl, 0, @intCast(r), 1, 1);
        for (what, 0..) |bit, col| {
            const check = c.gtk_check_button_new_with_label(bit);
            ctx.perm_bits[r * 3 + col] = check;
            _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onPropsBitToggled), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_grid_attach(@ptrCast(grid), check, @intCast(col + 1), @intCast(r), 1, 1);
        }
    }
    const special = [_][*:0]const u8{ "setuid", "setgid", "sticky" };
    const sl = c.gtk_label_new("Special");
    c.gtk_label_set_xalign(@ptrCast(sl), 0);
    c.gtk_grid_attach(@ptrCast(grid), sl, 0, 3, 1, 1);
    for (special, 0..) |bit, col| {
        const check = c.gtk_check_button_new_with_label(bit);
        ctx.perm_bits[9 + col] = check;
        _ = c.g_signal_connect_data(check, "toggled", @ptrCast(&onPropsBitToggled), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_grid_attach(@ptrCast(grid), check, @intCast(col + 1), 3, 1, 1);
    }
    c.gtk_box_append(@ptrCast(box), grid);

    const octal_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_box_append(@ptrCast(octal_row), c.gtk_label_new("Octal"));
    const octal = c.gtk_entry_new();
    c.gtk_entry_set_max_length(@ptrCast(octal), 4);
    ctx.octal = octal;
    _ = c.g_signal_connect_data(octal, "changed", @ptrCast(&onPropsOctalChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(octal_row), octal);
    c.gtk_box_append(@ptrCast(box), octal_row);
    ctx.applyChecks(e.mode);
    ctx.setOctal(e.mode);

    const own_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    c.gtk_box_append(@ptrCast(own_row), c.gtk_label_new("uid"));
    const uid_entry = c.gtk_entry_new();
    c.gtk_widget_set_size_request(uid_entry, 80, -1);
    var idbuf: [16:0]u8 = undefined;
    if (std.fmt.bufPrintZ(&idbuf, "{d}", .{e.uid})) |v| c.gtk_editable_set_text(@ptrCast(uid_entry), v.ptr) else |_| {}
    ctx.uid_entry = uid_entry;
    c.gtk_box_append(@ptrCast(own_row), uid_entry);
    c.gtk_box_append(@ptrCast(own_row), c.gtk_label_new("gid"));
    const gid_entry = c.gtk_entry_new();
    c.gtk_widget_set_size_request(gid_entry, 80, -1);
    if (std.fmt.bufPrintZ(&idbuf, "{d}", .{e.gid})) |v| c.gtk_editable_set_text(@ptrCast(gid_entry), v.ptr) else |_| {}
    ctx.gid_entry = gid_entry;
    c.gtk_box_append(@ptrCast(own_row), gid_entry);
    c.gtk_box_append(@ptrCast(box), own_row);

    if (e.tdir) {
        const rec = c.gtk_check_button_new_with_label("Apply to enclosed files and folders");
        ctx.recursive = rec;
        c.gtk_box_append(@ptrCast(box), rec);
    }

    const apply = c.gtk_button_new_with_label("Apply");
    c.gtk_widget_add_css_class(apply, "suggested-action");
    _ = c.g_signal_connect_data(apply, "clicked", @ptrCast(&onPropsApply), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), apply);

    const scroll = c.gtk_scrolled_window_new();
    c.gtk_widget_set_vexpand(scroll, 1);
    // Long names/values ellipsize instead of widening the window: a
    // horizontal scrollbar on a properties dialog is never right.
    c.gtk_scrolled_window_set_policy(@ptrCast(scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), box);
    const toolbar = c.adw_toolbar_view_new();
    c.adw_toolbar_view_add_top_bar(@ptrCast(toolbar), c.adw_header_bar_new());
    c.adw_toolbar_view_set_content(@ptrCast(toolbar), scroll);
    c.adw_window_set_content(@ptrCast(window), toolbar);
    c.gtk_window_present(@ptrCast(window));
}

/// Escape closes the dialog.
///
/// `close`, not `destroy`: tearing the window down inside its own key
/// dispatch leaves the app without a focused toplevel, and the next
/// context-menu popover then fails to appear.
fn onPropsEscape(_: ?*c.GtkWidget, _: ?*c.GVariant, user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    c.gtk_window_close(@ptrCast(ctx.window));
    return 1;
}

/// In-flight attr_list for an open Properties dialog. The box is
/// g_object_ref'd so a closed dialog cannot dangle; the path is
/// kept because the reply carries no echo of it.
pub const AttrRequest = struct {
    req: u32,
    hc: *HostConn,
    box: *c.GtkWidget,
    path: []u8,
};

pub fn endAttrRequest(self: *BrowserView) void {
    const request = self.attr_request orelse return;
    c.g_object_unref(@ptrCast(request.box));
    self.allocator.free(request.path);
    self.attr_request = null;
}

pub fn requestAttrs(self: *BrowserView, ctx: *PropsCtx) void {
    const hc = ctx.liveHost() orelse return;
    if (hc.state != .ready) return;
    self.endAttrRequest();
    const path = self.allocator.dupe(u8, ctx.path) catch return;
    const req = self.nextReq();
    _ = c.g_object_ref(@ptrCast(ctx.attr_box));
    self.attr_request = .{ .req = req, .hc = hc, .box = ctx.attr_box, .path = path };
    self.sendOp(hc, .{ .req = req, .op = "attr_list", .path = ctx.path });
}

/// Heap context for one attribute row's Set button.
pub const AttrRowCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    hc: *HostConn,
    path: []u8,
    name: []u8,
    entry: *c.GtkWidget,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *AttrRowCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.path);
        ctx.allocator.free(ctx.name);
        ctx.allocator.destroy(ctx);
    }
};

pub fn feedAttrRequest(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    if (ftype != .fs_reply) return false;
    const request = self.attr_request orelse return false;
    if (request.hc != hc) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const rep = std.json.parseFromSliceLeaky(struct {
        req: u32 = 0,
        ok: bool = false,
        attrs: []const fsserve.Attr = &.{},
    }, arena.allocator(), payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return false;
    if (rep.req != request.req) return false;

    while (c.gtk_widget_get_first_child(request.box)) |child|
        c.gtk_box_remove(@ptrCast(request.box), child);
    if (!rep.ok or rep.attrs.len == 0) {
        const none = c.gtk_label_new(if (rep.ok) "(none)" else "(unavailable)");
        c.gtk_label_set_xalign(@ptrCast(none), 0);
        c.gtk_widget_add_css_class(none, "dim-label");
        c.gtk_box_append(@ptrCast(request.box), none);
        self.endAttrRequest();
        return true;
    }
    for (rep.attrs) |attr| {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
        var name_z: [256:0]u8 = undefined;
        const label = c.gtk_label_new(copyZ(@ptrCast(&name_z), colkeys.label(attr.name)));
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_widget_set_size_request(label, 150, -1);
        c.gtk_widget_set_tooltip_text(label, copyZ(@ptrCast(&name_z), attr.name));
        c.gtk_box_append(@ptrCast(row), label);
        const entry = c.gtk_entry_new();
        c.gtk_widget_set_hexpand(entry, 1);
        var value_z: [1024:0]u8 = undefined;
        c.gtk_editable_set_text(@ptrCast(entry), copyZ(@ptrCast(&value_z), attr.value));
        c.gtk_box_append(@ptrCast(row), entry);
        const set = c.gtk_button_new_with_label("Set");
        const rctx = self.allocator.create(AttrRowCtx) catch continue;
        rctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .hc = hc,
            .path = self.allocator.dupe(u8, request.path) catch {
                self.allocator.destroy(rctx);
                continue;
            },
            .name = self.allocator.dupe(u8, attr.name) catch {
                self.allocator.free(rctx.path);
                self.allocator.destroy(rctx);
                continue;
            },
            .entry = entry,
        };
        _ = c.g_signal_connect_data(set, "clicked", @ptrCast(&onAttrRowSet), @ptrCast(rctx), @ptrCast(&AttrRowCtx.free), c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(entry, "activate", @ptrCast(&onAttrRowActivate), @ptrCast(rctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), set);
        c.gtk_box_append(@ptrCast(request.box), row);
    }
    self.endAttrRequest();
    return true;
}

pub fn onAttrRowSet(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *AttrRowCtx = @ptrCast(@alignCast(user.?));
    const value = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.entry)))));
    const self = ctx.view;
    self.sendOp(ctx.hc, .{ .req = self.nextReq(), .op = "attr_set", .path = ctx.path, .pattern = ctx.name, .to = value });
    if (value.len == 0)
        self.setStatusFmt("cleared {s}", .{colkeys.label(ctx.name)})
    else
        self.setStatusFmt("set {s}", .{colkeys.label(ctx.name)});
}

pub fn onAttrRowActivate(_: *c.GtkEntry, user: ?*anyopaque) callconv(.c) void {
    onAttrRowSet(undefined, user);
}

pub fn onPropsAttrAdd(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.attr_name_entry)))));
    const value = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.attr_value_entry)))));
    if (name.len == 0) return self.setStatus("attribute name required");
    if (!std.mem.startsWith(u8, name, "user."))
        return self.setStatus("attribute names must start with user.");
    const hc = ctx.liveHost() orelse return;
    self.sendOp(hc, .{ .req = self.nextReq(), .op = "attr_set", .path = ctx.path, .pattern = name, .to = value });
    self.setStatusFmt("set {s}", .{name});
    // Re-read so the list shows what the host actually stored.
    self.requestAttrs(ctx);
}

pub fn onPropsChecksum(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    const hc = ctx.liveHost() orelse return;
    ctx.view.startProbe(.hash, hc, ctx.hash_label, "hash", ctx.path);
}

pub fn onPropsMediaInfo(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    const box = ctx.media_label orelse return;
    // media_meta takes a batch; one file is a batch of one, and it
    // goes through the SAME daemon-side extractor and host-side
    // cache the listing columns use.
    const hc = ctx.liveHost() orelse return;
    ctx.view.startProbe(.media, hc, box, "media_meta", ctx.path);
}

pub fn onPropsOpenWith(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    if (ctx.liveHost() == null) return;
    ctx.view.openWithDialog(ctx.tab, ctx.path);
}

pub fn onPropsBitToggled(_: *c.GtkCheckButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    if (ctx.syncing) return;
    ctx.setOctal(ctx.modeFromChecks());
}

pub fn onPropsOctalChanged(entry: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    if (ctx.syncing) return;
    const txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    const mode = std.fmt.parseInt(u32, txt, 8) catch return;
    if (mode > 0o7777) return;
    ctx.applyChecks(mode);
}

pub fn onPropsCalcSize(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const hc = ctx.liveHost() orelse return;
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    self.startProbe(.size, hc, ctx.size_label, "dir_size", ctx.path);
}

pub fn onPropsApply(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const hc = ctx.liveHost() orelse return;
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    const mode = ctx.modeFromChecks();
    const uid = parseId(ctx.uid_entry);
    const gid = parseId(ctx.gid_entry);
    const recursive = if (ctx.recursive) |r| c.gtk_check_button_get_active(@ptrCast(r)) != 0 else false;
    if (recursive) {
        var lbl: [128]u8 = undefined;
        const label = std.fmt.bufPrint(&lbl, "permissions {s}", .{std.fs.path.basename(ctx.path)}) catch "permissions";
        const req = self.nextReq();
        const pj = self.allocator.create(PendingJob) catch return;
        pj.* = .{
            .req = req,
            .hc = hc,
            .label = self.allocator.dupe(u8, label) catch {
                self.allocator.destroy(pj);
                return;
            },
        };
        self.pending_jobs.append(self.allocator, pj) catch {
            self.allocator.free(pj.label);
            self.allocator.destroy(pj);
            return;
        };
        self.sendOp(hc, .{
            .req = req,
            .op = "perm_tree",
            .path = ctx.path,
            .mode = mode,
            .uid = uid,
            .gid = gid,
        });
        self.setStatus("applying permissions recursively");
        return;
    }
    self.sendOp(hc, .{ .req = self.nextReq(), .op = "chmod", .path = ctx.path, .mode = mode });
    if (uid != null or gid != null)
        self.sendOp(hc, .{ .req = self.nextReq(), .op = "chown", .path = ctx.path, .uid = uid, .gid = gid });
    self.setStatusFmt("applied {o:0>4} to {s}", .{ mode & 0o7777, std.fs.path.basename(ctx.path) });
}

/// Entry text as a uid/gid, or null when it is empty or invalid
/// (null leaves the current owner alone).
pub fn parseId(entry: *c.GtkWidget) ?u32 {
    const txt = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(entry)))));
    if (txt.len == 0) return null;
    return std.fmt.parseInt(u32, txt, 10) catch null;
}

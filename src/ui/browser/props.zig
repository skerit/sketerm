//! The Properties dialog: permissions/ownership editing, extended
//! attributes, and the label probes (folder size, checksum, media
//! info) that fill its fields from daemon jobs.

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");
const colkeys = @import("../../filebrowser/colkeys.zig");
const snapshots = @import("../../filebrowser/snapshots.zig");
const fsserve = @import("../../mux/fsserve.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Entry = @import("types.zig").Entry;
const HostConn = @import("types.zig").HostConn;
const WireReply = @import("types.zig").WireReply;
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
    showProperties(self, tab, path, e);
}

/// Build and present the non-modal properties dialog for `e`.
/// `e` is only read during the call (the async sections re-fetch by
/// path), so a borrowed entry -- one synthesized from a `stat` reply
/// -- is fine.
pub fn showProperties(self: *BrowserView, tab: *BTab, path: []const u8, e: *const Entry) void {
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

    // Previous versions from btrfs snapshots (Timeshift/snapper),
    // discovered with plain list+stat ops so it works for any host.
    const snap_head = c.gtk_label_new("Previous Versions");
    c.gtk_widget_add_css_class(snap_head, "heading");
    c.gtk_label_set_xalign(@ptrCast(snap_head), 0);
    c.gtk_box_append(@ptrCast(box), snap_head);
    const snap_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    const snap_wait = c.gtk_label_new("Searching snapshots…");
    c.gtk_label_set_xalign(@ptrCast(snap_wait), 0);
    c.gtk_widget_add_css_class(snap_wait, "dim-label");
    c.gtk_box_append(@ptrCast(snap_box), snap_wait);
    c.gtk_box_append(@ptrCast(box), snap_box);
    self.requestSnapshots(ctx, snap_box);

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

// ── Previous Versions (btrfs snapshots) ──────────────────────────

/// The dim one-liner every failure path degrades to.
const SNAP_NONE = "No snapshots found (Timeshift/snapper btrfs snapshots are detected)";

/// The in-flight snapshot discovery for an open Properties dialog:
/// a small client-driven state machine over plain `list`/`stat` ops,
/// so it needs no daemon verb and works for remote hosts unchanged.
/// The box is g_object_ref'd, so a closed dialog cannot dangle; one
/// per view (a newer dialog supersedes an older search), mirroring
/// `AttrRequest`.
pub const SnapRequest = struct {
    allocator: std.mem.Allocator,
    hc: *HostConn,
    box: *c.GtkWidget,
    /// The original file's absolute path (owned).
    path: []u8,
    /// The ONE outstanding fs request (list chunks share it).
    req: u32,
    phase: enum { list_timeshift, probe_localhost, probe_at, list_snapper, stat_versions },
    layout: snapshots.Layout = .timeshift_localhost,
    /// Snapshot names (owned), newest first once sorted.
    names: std.ArrayList([]u8) = .empty,
    /// The candidate currently being stat'ed.
    idx: usize = 0,
    /// Stat hits, in newest-first candidate order.
    hits: std.ArrayList(snapshots.Version) = .empty,

    fn clearNames(self: *SnapRequest) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.clearRetainingCapacity();
    }

    fn destroy(self: *SnapRequest) void {
        c.g_object_unref(@ptrCast(self.box));
        self.clearNames();
        self.names.deinit(self.allocator);
        self.hits.deinit(self.allocator);
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

fn setSnapLine(box: *c.GtkWidget, message: [*:0]const u8) void {
    clearBox(box);
    const lbl = c.gtk_label_new(message);
    c.gtk_label_set_xalign(@ptrCast(lbl), 0);
    c.gtk_widget_add_css_class(lbl, "dim-label");
    c.gtk_box_append(@ptrCast(box), lbl);
}

pub fn endSnapRequest(self: *BrowserView) void {
    const sr = self.snap_request orelse return;
    self.snap_request = null;
    sr.destroy();
}

/// Show the none-line and end the search: every error path lands
/// here (host death included), deliberately silent about the reason.
pub fn snapDegrade(self: *BrowserView) void {
    const sr = self.snap_request orelse return;
    setSnapLine(sr.box, SNAP_NONE);
    self.endSnapRequest();
}

pub fn requestSnapshots(self: *BrowserView, ctx: *PropsCtx, box: *c.GtkWidget) void {
    const hc = ctx.tab.hc;
    if (self.snap_request != null) {
        // A newer dialog supersedes the older search (one in flight
        // per view, like AttrRequest); its section settles as "none".
        setSnapLine(self.snap_request.?.box, SNAP_NONE);
        self.endSnapRequest();
    }
    if (hc.state != .ready) return setSnapLine(box, SNAP_NONE);
    const sr = self.allocator.create(SnapRequest) catch return setSnapLine(box, SNAP_NONE);
    const path = self.allocator.dupe(u8, ctx.path) catch {
        self.allocator.destroy(sr);
        return setSnapLine(box, SNAP_NONE);
    };
    _ = c.g_object_ref(@ptrCast(box));
    sr.* = .{
        .allocator = self.allocator,
        .hc = hc,
        .box = box,
        .path = path,
        .req = self.nextReq(),
        .phase = .list_timeshift,
    };
    self.snap_request = sr;
    self.sendOp(hc, .{ .req = sr.req, .op = "list", .path = snapshots.TIMESHIFT_ROOT });
}

/// Advance to the snapper layout after Timeshift yielded nothing.
fn snapTrySnapper(self: *BrowserView, sr: *SnapRequest) void {
    sr.clearNames();
    sr.phase = .list_snapper;
    sr.req = self.nextReq();
    self.sendOp(sr.hc, .{ .req = sr.req, .op = "list", .path = snapshots.SNAPPER_ROOT });
}

/// Sort newest first, cap the stat work, and begin statting versions.
fn snapStartStats(self: *BrowserView, sr: *SnapRequest) void {
    if (sr.names.items.len == 0) return snapDegrade(self);
    snapshots.sortNewestFirst(sr.names.items, sr.layout == .snapper);
    while (sr.names.items.len > snapshots.MAX_SNAPSHOTS) {
        const n = sr.names.pop() orelse break;
        sr.allocator.free(n);
    }
    sr.idx = 0;
    sr.phase = .stat_versions;
    snapSendNextStat(self, sr);
}

/// Stat the next candidate, skipping ones whose path cannot be
/// built; past the last, finish.
fn snapSendNextStat(self: *BrowserView, sr: *SnapRequest) void {
    var buf: [4600]u8 = undefined;
    while (sr.idx < sr.names.items.len) {
        const vpath = snapshots.versionPath(&buf, sr.layout, sr.names.items[sr.idx], sr.path) orelse {
            sr.idx += 1;
            continue;
        };
        sr.req = self.nextReq();
        self.sendOp(sr.hc, .{ .req = sr.req, .op = "stat", .path = vpath });
        return;
    }
    snapFinish(self, sr);
}

/// Dedupe the hits and render one row per surviving version.
fn snapFinish(self: *BrowserView, sr: *SnapRequest) void {
    const kept = snapshots.dedupeNewestFirst(sr.hits.items);
    if (kept == 0) return snapDegrade(self);
    clearBox(sr.box);
    var buf: [4600]u8 = undefined;
    for (sr.hits.items[0..kept]) |v| {
        const vpath = snapshots.versionPath(&buf, sr.layout, sr.names.items[v.snap], sr.path) orelse continue;
        appendSnapRow(self, sr, vpath, v);
    }
    if (c.gtk_widget_get_first_child(sr.box) == null) setSnapLine(sr.box, SNAP_NONE);
    self.endSnapRequest();
}

fn appendSnapRow(self: *BrowserView, sr: *SnapRequest, vpath: []const u8, v: snapshots.Version) void {
    const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
    var tbuf: [40:0]u8 = undefined;
    var human: [48:0]u8 = undefined;
    var text: [96:0]u8 = undefined;
    const label_txt = std.fmt.bufPrintZ(&text, "{s}  {s}", .{
        std.mem.span(fmtTimeZ(&tbuf, v.mtime_ms)), fmtSize(&human, v.size),
    }) catch return;
    const lbl = c.gtk_label_new(label_txt.ptr);
    c.gtk_label_set_xalign(@ptrCast(lbl), 0);
    c.gtk_widget_set_hexpand(lbl, 1);
    var tipz: [4700:0]u8 = undefined;
    c.gtk_widget_set_tooltip_text(lbl, copyZ(@ptrCast(&tipz), vpath));
    c.gtk_box_append(@ptrCast(row), lbl);

    // One heap ctx per button: each connection frees its own via
    // GDestroyNotify (the AttrRowCtx pattern).
    if (makeSnapRowCtx(self, sr, vpath, v.mtime_ms)) |octx| {
        const open = c.gtk_button_new_with_label("Open");
        _ = c.g_signal_connect_data(open, "clicked", @ptrCast(&onSnapOpen), @ptrCast(octx), @ptrCast(&SnapRowCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), open);
    }
    if (makeSnapRowCtx(self, sr, vpath, v.mtime_ms)) |rctx| {
        const restore = c.gtk_button_new_with_label("Restore a Copy…");
        _ = c.g_signal_connect_data(restore, "clicked", @ptrCast(&onSnapRestore), @ptrCast(rctx), @ptrCast(&SnapRowCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(row), restore);
    }
    c.gtk_box_append(@ptrCast(sr.box), row);
}

/// Heap context for one version row button.
pub const SnapRowCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    hc: *HostConn,
    /// The versioned file inside the snapshot (owned).
    vpath: []u8,
    /// The original file the dialog describes (owned).
    orig: []u8,
    mtime_ms: i64,

    fn free(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
        const ctx: *SnapRowCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.vpath);
        ctx.allocator.free(ctx.orig);
        ctx.allocator.destroy(ctx);
    }
};

fn makeSnapRowCtx(self: *BrowserView, sr: *SnapRequest, vpath: []const u8, mtime_ms: i64) ?*SnapRowCtx {
    const ctx = self.allocator.create(SnapRowCtx) catch return null;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .hc = sr.hc,
        .vpath = self.allocator.dupe(u8, vpath) catch {
            self.allocator.destroy(ctx);
            return null;
        },
        .orig = self.allocator.dupe(u8, sr.path) catch {
            self.allocator.free(ctx.vpath);
            self.allocator.destroy(ctx);
            return null;
        },
        .mtime_ms = mtime_ms,
    };
    return ctx;
}

/// Open the snapshot's copy read-only-in-effect: the snapshot subvol
/// is mounted read-only, so opening the path directly is safe.
pub fn onSnapOpen(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SnapRowCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    if (ctx.hc.host != null and ctx.hc.state != .ready)
        return self.setStatusFmt("not connected to {s}", .{ctx.hc.label()});
    self.openPathOnHost(ctx.hc, ctx.vpath);
}

/// Copy the version NEXT TO the original as "<name> (from
/// YYYY-MM-DD)" through the normal daemon copy job -- the original
/// is never overwritten.
pub fn onSnapRestore(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *SnapRowCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    if (ctx.hc.state != .ready)
        return self.setStatusFmt("not connected to {s}", .{ctx.hc.label()});
    var t: c.time_t = @intCast(@divTrunc(ctx.mtime_ms, 1000));
    var tm: c.struct_tm = undefined;
    if (c.localtime_r(&t, &tm) == null) return;
    var datez: [16:0]u8 = undefined;
    const n = c.strftime(&datez, datez.len - 1, "%Y-%m-%d", &tm);
    var dst_buf: [4700]u8 = undefined;
    const dst = snapshots.restoreCopyPath(&dst_buf, ctx.orig, datez[0..n]) orelse return;
    var lblbuf: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&lblbuf, "restore {s}", .{std.fs.path.basename(ctx.orig)}) catch "restore";
    self.startDaemonJob(ctx.hc, "copy", ctx.vpath, dst, label);
    self.setStatusFmt("restoring a copy of {s}", .{std.fs.path.basename(ctx.orig)});
}

/// Route fs replies belonging to the snapshot search.
/// @return true when the frame was consumed.
pub fn feedSnapRequest(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    if (ftype != .fs_reply) return false;
    const sr = self.snap_request orelse return false;
    if (sr.hc != hc) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
        .ignore_unknown_fields = true,
    }) catch return false;
    if (rep.req == 0 or rep.req != sr.req) return false;

    switch (sr.phase) {
        .list_timeshift, .list_snapper => {
            const snapper = sr.phase == .list_snapper;
            if (!rep.ok) {
                if (snapper) snapDegrade(self) else snapTrySnapper(self, sr);
                return true;
            }
            for (rep.entries) |we| {
                if (!we.tdir) continue;
                if (snapper and !snapshots.isSnapperName(we.name)) continue;
                const name = sr.allocator.dupe(u8, we.name) catch continue;
                sr.names.append(sr.allocator, name) catch sr.allocator.free(name);
            }
            if (rep.more) return true;
            if (sr.names.items.len == 0) {
                if (snapper) snapDegrade(self) else snapTrySnapper(self, sr);
                return true;
            }
            if (snapper) {
                sr.layout = .snapper;
                snapStartStats(self, sr);
                return true;
            }
            // Which Timeshift sub-layout? Probe the newest snapshot.
            snapshots.sortNewestFirst(sr.names.items, false);
            var buf: [4600]u8 = undefined;
            const probe = snapshots.timeshiftProbe(&buf, sr.names.items[0], false) orelse {
                snapTrySnapper(self, sr);
                return true;
            };
            sr.phase = .probe_localhost;
            sr.req = self.nextReq();
            self.sendOp(sr.hc, .{ .req = sr.req, .op = "stat", .path = probe });
            return true;
        },
        .probe_localhost => {
            if (rep.ok and rep.entry != null and rep.entry.?.tdir) {
                sr.layout = .timeshift_localhost;
                snapStartStats(self, sr);
                return true;
            }
            var buf: [4600]u8 = undefined;
            const probe = snapshots.timeshiftProbe(&buf, sr.names.items[0], true) orelse {
                snapTrySnapper(self, sr);
                return true;
            };
            sr.phase = .probe_at;
            sr.req = self.nextReq();
            self.sendOp(sr.hc, .{ .req = sr.req, .op = "stat", .path = probe });
            return true;
        },
        .probe_at => {
            if (rep.ok and rep.entry != null and rep.entry.?.tdir) {
                sr.layout = .timeshift_at;
                snapStartStats(self, sr);
            } else {
                // The Timeshift root exists but maps nothing we
                // recognize; snapper may still cover this path.
                snapTrySnapper(self, sr);
            }
            return true;
        },
        .stat_versions => {
            if (rep.ok) {
                if (rep.entry) |we| {
                    sr.hits.append(sr.allocator, .{
                        .snap = sr.idx,
                        .size = we.size,
                        .mtime_ms = we.mtime_ms,
                    }) catch {};
                }
            }
            sr.idx += 1;
            snapSendNextStat(self, sr);
            return true;
        },
    }
}

// ── background-click (folder) properties ─────────────────────────

/// Properties of the folder a background click landed in: the folder
/// is not in its own listing, so its entry is stat'ed from the
/// daemon first and the dialog opens on the reply.
pub fn folderProperties(self: *BrowserView, tab: *BTab) void {
    if (tab.hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{tab.hc.label()});
        return;
    }
    self.props_stat_req = self.nextReq();
    self.props_stat_tab = tab;
    self.sendOp(tab.hc, .{ .req = self.props_stat_req, .op = "stat", .path = tab.root.path });
}

/// Route the folder-properties stat reply.
/// @return true when the reply was ours.
pub fn feedFolderProps(self: *BrowserView, hc: *HostConn, rep: WireReply) bool {
    if (self.props_stat_req == 0 or rep.req != self.props_stat_req) return false;
    self.props_stat_req = 0;
    const tab = self.props_stat_tab orelse return true;
    self.props_stat_tab = null;
    if (!self.tabAlive(tab) or tab.hc != hc) return true;
    if (!rep.ok or rep.entry == null) {
        self.setStatusFmt("properties: {s}", .{rep.@"error"});
        return true;
    }
    // A borrowed Entry over the reply arena; showProperties only
    // reads it during the call.
    const we = rep.entry.?;
    var e = Entry{
        .name = @constCast(we.name),
        .kind = @constCast(we.kind),
        .size = we.size,
        .mode = we.mode,
        .mtime_ms = we.mtime_ms,
        .atime_ms = we.atime_ms,
        .ctime_ms = we.ctime_ms,
        .uid = we.uid,
        .gid = we.gid,
        .owner = @constCast(we.owner),
        .group = @constCast(we.group),
        .btime_ms = we.btime_ms,
        .nlink = we.nlink,
        .blocks = we.blocks,
        .children = we.children,
        .target = if (we.target) |t| @constCast(t) else null,
        .tdir = we.tdir,
    };
    showProperties(self, tab, tab.root.path, &e);
    return true;
}

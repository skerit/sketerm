//! The Properties dialog: permissions/ownership editing, extended
//! attributes, and the label probes (folder size, checksum, media
//! info) that fill its fields from daemon jobs.

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");
const fsserve = @import("../../mux/fsserve.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const MenuCtx = @import("menu.zig").MenuCtx;
const PendingJob = @import("types.zig").PendingJob;
const WireJobEv = @import("types.zig").WireJobEv;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const copyZ = @import("../../filebrowser/format.zig").copyZ;
const entryForPath = @import("nav.zig").entryForPath;
const fmtSize = @import("../../filebrowser/format.zig").fmtSize;
const fmtTimeZ = @import("../../filebrowser/format.zig").fmtTimeZ;
const isImageName = @import("../../filebrowser/paths.zig").isImageName;
const isPreviewMediaName = @import("../../filebrowser/paths.zig").isPreviewMediaName;
const menuDone = @import("menu.zig").menuDone;

/// Recursive size probe: a daemon job so the walk happens on the
/// host that owns the tree.
/// One label fed by a daemon job: recursive size, checksum, or
/// media metadata. The label is g_object_ref'd, so a dialog closed
/// mid-flight cannot dangle.
pub const LabelProbe = struct {
    kind: enum { size, hash, media },
    req: u32,
    job: u64 = 0,
    hc: *HostConn,
    label: *c.GtkWidget,
};

pub fn endProbe(self: *BrowserView, i: usize) void {
    const probe = self.probes.items[i];
    c.g_object_unref(@ptrCast(probe.label));
    _ = self.probes.orderedRemove(i);
}

pub fn endProbesFor(self: *BrowserView, hc: ?*HostConn, message: [*:0]const u8) void {
    var i: usize = 0;
    while (i < self.probes.items.len) {
        const probe = self.probes.items[i];
        if (hc == null or probe.hc == hc.?) {
            c.gtk_label_set_text(@ptrCast(probe.label), message);
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
    c.gtk_label_set_text(@ptrCast(label), "calculating…");
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
                    c.gtk_label_set_text(@ptrCast(probe.label), "unavailable");
                    self.endProbe(i);
                } else probe.job = rep.job;
                return true;
            }
            return false;
        },
        .fs_job => {
            const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{ .ignore_unknown_fields = true }) catch return false;
            for (self.probes.items, 0..) |probe, i| {
                if (probe.hc != hc or probe.job == 0 or probe.job != ev.job) continue;
                const done = std.mem.eql(u8, ev.ev, "done");
                if (!done and !std.mem.eql(u8, ev.ev, "progress")) {
                    if (ev.terminalEv()) {
                        c.gtk_label_set_text(@ptrCast(probe.label), "unavailable");
                        self.endProbe(i);
                    }
                    return true;
                }
                var buf: [1024:0]u8 = undefined;
                var human: [48:0]u8 = undefined;
                const text: [*:0]const u8 = switch (probe.kind) {
                    .size => if (std.fmt.bufPrintZ(&buf, "{s} ({d} bytes) in {d} items{s}", .{
                        fmtSize(&human, ev.done), ev.done, ev.total, if (done) "" else " …",
                    })) |v| v.ptr else |_| "",
                    .hash => if (!done) "hashing…" else copyZ(@ptrCast(&buf), ev.hash),
                    .media => if (!done) "reading…" else copyZ(@ptrCast(&buf), if (ev.text.len > 0) ev.text else "(no metadata)"),
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
    syncing: bool = false,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.path);
        ctx.allocator.destroy(ctx);
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
    const popover = c.gtk_popover_new();
    const ctx = self.allocator.create(PropsCtx) catch return;
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .is_dir = e.tdir,
    };
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-props", @ptrCast(ctx), @ptrCast(&PropsCtx.free));

    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 6);
    c.gtk_widget_set_margin_start(box, 10);
    c.gtk_widget_set_margin_end(box, 10);
    c.gtk_widget_set_margin_top(box, 10);
    c.gtk_widget_set_margin_bottom(box, 10);

    var name_z: [512:0]u8 = undefined;
    const title = c.gtk_label_new(copyZ(@ptrCast(&name_z), std.fs.path.basename(path)));
    c.gtk_widget_add_css_class(title, "heading");
    c.gtk_label_set_xalign(@ptrCast(title), 0);
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
        c.gtk_widget_set_hexpand(app_label, 1);
        c.gtk_box_append(@ptrCast(app_row), app_label);
        const change = c.gtk_button_new_with_label("Change…");
        _ = c.g_signal_connect_data(change, "clicked", @ptrCast(&onPropsOpenWith), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(app_row), change);
        c.gtk_box_append(@ptrCast(box), app_row);

        if (isPreviewMediaName(path) and !isImageName(path)) {
            const media_row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6);
            const lbl2 = c.gtk_label_new("Media info: not read");
            c.gtk_label_set_xalign(@ptrCast(lbl2), 0);
            c.gtk_label_set_selectable(@ptrCast(lbl2), 1);
            c.gtk_widget_set_hexpand(lbl2, 1);
            ctx.media_label = lbl2;
            c.gtk_box_append(@ptrCast(media_row), lbl2);
            const read = c.gtk_button_new_with_label("Read");
            _ = c.g_signal_connect_data(read, "clicked", @ptrCast(&onPropsMediaInfo), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(media_row), read);
            c.gtk_box_append(@ptrCast(box), media_row);
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
    c.gtk_widget_set_size_request(scroll, 400, 520);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), box);
    c.gtk_popover_set_child(@ptrCast(popover), scroll);
    c.gtk_widget_set_parent(popover, tab.page);
    connectPopoverAutoUnparent(popover);
    const rect = c.GdkRectangle{ .x = 320, .y = 120, .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    c.gtk_popover_popup(@ptrCast(popover));
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
    const hc = ctx.tab.hc;
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
        const label = c.gtk_label_new(copyZ(@ptrCast(&name_z), attrLabel(attr.name)));
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

/// Friendly name for the attributes with agreed meanings; other
/// names show as-is (minus the namespace).
pub fn attrLabel(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "user.xdg.comment")) return "Comment";
    if (std.mem.eql(u8, name, "user.xdg.origin.url")) return "Where from";
    if (std.mem.eql(u8, name, "user.xdg.referrer.url")) return "Referrer";
    if (std.mem.eql(u8, name, fsserve.TAGS_XATTR)) return "Tags";
    if (std.mem.startsWith(u8, name, "user.sketerm.")) return name["user.sketerm.".len..];
    if (std.mem.startsWith(u8, name, "user.")) return name["user.".len..];
    return name;
}

pub fn onAttrRowSet(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *AttrRowCtx = @ptrCast(@alignCast(user.?));
    const value = std.mem.span(@as([*:0]const u8, @ptrCast(c.gtk_editable_get_text(@ptrCast(ctx.entry)))));
    const self = ctx.view;
    self.sendOp(ctx.hc, .{ .req = self.nextReq(), .op = "attr_set", .path = ctx.path, .pattern = ctx.name, .to = value });
    if (value.len == 0)
        self.setStatusFmt("cleared {s}", .{attrLabel(ctx.name)})
    else
        self.setStatusFmt("set {s}", .{attrLabel(ctx.name)});
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
    self.sendOp(ctx.tab.hc, .{ .req = self.nextReq(), .op = "attr_set", .path = ctx.path, .pattern = name, .to = value });
    self.setStatusFmt("set {s}", .{name});
    // Re-read so the list shows what the host actually stored.
    self.requestAttrs(ctx);
}

pub fn onPropsChecksum(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    ctx.view.startProbe(.hash, ctx.tab.hc, ctx.hash_label, "hash", ctx.path);
}

pub fn onPropsMediaInfo(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    const label = ctx.media_label orelse return;
    ctx.view.startProbe(.media, ctx.tab.hc, label, "preview", ctx.path);
}

pub fn onPropsOpenWith(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
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
    const hc = ctx.tab.hc;
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    self.startProbe(.size, hc, ctx.size_label, "dir_size", ctx.path);
}

pub fn onPropsApply(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PropsCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const hc = ctx.tab.hc;
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

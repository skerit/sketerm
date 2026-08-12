//! GUI side of the WebExtensions host: a process-wide registry of
//! installed extensions, their on-disk install/removal, publishing them
//! to the browser helper on connect, and the management surface reached
//! from a web pane's context menu.
//!
//! The helper does the actual loading, background hosting and content
//! scripts; this module owns what the USER sees — which extensions are
//! installed, whether each is enabled, and the Load/Remove actions.
//! Installed extensions live under `$XDG_DATA_HOME/sketerm/webext/`, the
//! same tree the helper reads; a small `registry.json` there records the
//! id/dir/enabled of each so the set survives a GUI restart.
//!
//! Reuses the pure `web/webext/{manifest,zip}` modules for parsing and
//! XPI unpacking, and the shared GTK helpers for chrome.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const webface = @import("webface.zig");
const proto = @import("../web/protocol.zig");
const manifest = @import("../web/webext/manifest.zig");
const zip = @import("../web/webext/zip.zig");

/// One installed extension as the GUI tracks it.
pub const Ext = struct {
    id: []u8,
    /// Absolute unpacked directory the helper loads.
    dir: []u8,
    name: []u8,
    version: []u8,
    enabled: bool,
    /// The helper's last report (`ev_webext_state`): whether it loaded.
    ok: bool = false,
    err: []u8 = &.{},
    /// True when the files live under our data dir (an XPI we unpacked),
    /// so Remove may delete them; a "load unpacked" points in place and
    /// is only unregistered.
    owned_files: bool = false,
};

var g_gpa: ?std.mem.Allocator = null;
var g_exts: std.ArrayList(Ext) = .empty;
var g_loaded = false;

pub fn extensions() []Ext {
    return g_exts.items;
}

fn dupe(s: []const u8) []u8 {
    return (g_gpa orelse unreachable).dupe(u8, s) catch @constCast("");
}

fn freeExt(e: *Ext) void {
    const gpa = g_gpa orelse return;
    gpa.free(e.id);
    gpa.free(e.dir);
    gpa.free(e.name);
    gpa.free(e.version);
    if (e.err.len != 0) gpa.free(e.err);
}

fn find(id: []const u8) ?*Ext {
    for (g_exts.items) |*e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    return null;
}

/// Data dir (`$XDG_DATA_HOME/sketerm/webext`), owned by the caller.
fn dataDir(gpa: std.mem.Allocator) ?[]u8 {
    if (c.getenv("XDG_DATA_HOME")) |xdg| {
        const base = std.mem.span(xdg);
        if (base.len != 0) return std.fmt.allocPrint(gpa, "{s}/sketerm/webext", .{base}) catch null;
    }
    if (c.getenv("HOME")) |home| {
        return std.fmt.allocPrint(gpa, "{s}/.local/share/sketerm/webext", .{std.mem.span(home)}) catch null;
    }
    return null;
}

// -- registry persistence --------------------------------------------

/// Load the persisted registry once. Safe to call repeatedly.
pub fn ensureLoaded(gpa: std.mem.Allocator) void {
    if (g_loaded) return;
    g_loaded = true;
    g_gpa = gpa;
    const dir = dataDir(gpa) orelse return;
    defer gpa.free(dir);
    const path = std.fmt.allocPrint(gpa, "{s}/registry.json", .{dir}) catch return;
    defer gpa.free(path);
    const bytes = readFile(gpa, path) orelse return;
    defer gpa.free(bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .array) return;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const id = strField(o, "id") orelse continue;
        const edir = strField(o, "dir") orelse continue;
        const enabled = if (o.get("enabled")) |v| (v == .bool and v.bool) else false;
        const owned = if (o.get("owned")) |v| (v == .bool and v.bool) else false;
        // Fill name/version from the manifest if it still parses.
        var name: []const u8 = "";
        var version: []const u8 = "";
        var man = readManifest(gpa, edir);
        defer if (man) |*m| m.deinit();
        if (man) |*m| {
            name = m.name;
            version = m.version;
        }
        g_exts.append(gpa, .{
            .id = dupe(id),
            .dir = dupe(edir),
            .name = dupe(name),
            .version = dupe(version),
            .enabled = enabled,
            .owned_files = owned,
        }) catch {};
    }
}

fn strField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn save() void {
    const gpa = g_gpa orelse return;
    const dir = dataDir(gpa) orelse return;
    defer gpa.free(dir);
    mkdirAll(dir);
    const path = std.fmt.allocPrint(gpa, "{s}/registry.json", .{dir}) catch return;
    defer gpa.free(path);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeByte('[') catch return;
    for (g_exts.items, 0..) |e, i| {
        if (i != 0) w.writeByte(',') catch return;
        w.writeAll("{\"id\":") catch return;
        std.json.Stringify.value(e.id, .{}, w) catch return;
        w.writeAll(",\"dir\":") catch return;
        std.json.Stringify.value(e.dir, .{}, w) catch return;
        w.print(",\"enabled\":{s},\"owned\":{s}}}", .{
            if (e.enabled) "true" else "false",
            if (e.owned_files) "true" else "false",
        }) catch return;
    }
    w.writeByte(']') catch return;
    writeFile(path, aw.written());
}

// -- publish / helper state ------------------------------------------

/// Push every installed extension to a (possibly fresh) helper on
/// connect, then ask it to report state back.
pub fn publish(cl: *webface.Client) void {
    if (cl.state != .ready) return;
    for (g_exts.items) |*e| {
        cl.post(proto.WebextSet{ .id = e.id, .dir = e.dir, .enabled = if (e.enabled) 1 else 0 });
    }
    cl.post(proto.WebextListReq{});
}

/// Fold one `ev_webext_state` into the registry (name/version/ok/err).
pub fn onState(st: proto.EvWebextState) void {
    const gpa = g_gpa orelse return;
    const e = find(st.id) orelse return;
    if (st.name.len != 0) {
        gpa.free(e.name);
        e.name = gpa.dupe(u8, st.name) catch e.name;
    }
    if (st.version.len != 0) {
        gpa.free(e.version);
        e.version = gpa.dupe(u8, st.version) catch e.version;
    }
    e.ok = st.ok != 0;
    if (e.err.len != 0) gpa.free(e.err);
    e.err = gpa.dupe(u8, st.err) catch &.{};
    refreshOpenManager();
}

// -- install / remove / toggle ---------------------------------------

pub const InstallError = error{ BadManifest, NoManifest, WriteFailed, BadArchive, OutOfMemory };

/// Install a "load unpacked" directory: the helper loads it in place, so
/// nothing is copied. Returns the id.
pub fn installUnpacked(gpa: std.mem.Allocator, dir: []const u8) InstallError![]const u8 {
    ensureLoaded(gpa);
    var man = readManifest(gpa, dir) orelse return error.NoManifest;
    defer man.deinit();
    return register(gpa, dir, &man, false);
}

/// Install an `.xpi`/`.zip`: unpack it under the data dir and register.
pub fn installArchive(gpa: std.mem.Allocator, xpi_path: []const u8) InstallError![]const u8 {
    ensureLoaded(gpa);
    const bytes = readFile(gpa, xpi_path) orelse return error.NoManifest;
    defer gpa.free(bytes);
    var arc = zip.read(gpa, bytes) catch return error.BadArchive;
    defer arc.deinit();
    const man_entry = arc.find("manifest.json") orelse return error.NoManifest;
    var man = manifest.parse(gpa, man_entry.data) catch return error.BadManifest;
    defer man.deinit();

    var idbuf: [16]u8 = undefined;
    const id = manifest.deriveId(man.name, man.version, &idbuf);
    const base = dataDir(gpa) orelse return error.WriteFailed;
    defer gpa.free(base);
    const dest = std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, id }) catch return error.OutOfMemory;
    defer gpa.free(dest);
    mkdirAll(dest);
    for (arc.entries) |entry| {
        if (entry.is_dir) continue;
        // Reject any path that escapes the destination.
        if (std.mem.indexOf(u8, entry.name, "..") != null) continue;
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dest, entry.name }) catch continue;
        defer gpa.free(full);
        if (std.fs.path.dirname(full)) |d| mkdirAll(d);
        writeFile(full, entry.data);
    }
    return register(gpa, dest, &man, true);
}

fn register(gpa: std.mem.Allocator, dir: []const u8, man: *manifest.Manifest, owned: bool) []const u8 {
    var idbuf: [16]u8 = undefined;
    const id = manifest.deriveId(man.name, man.version, &idbuf);
    if (find(id)) |e| {
        // Re-install: update the dir + metadata, keep enabled state.
        gpa.free(e.dir);
        e.dir = gpa.dupe(u8, dir) catch e.dir;
        gpa.free(e.name);
        e.name = gpa.dupe(u8, man.name) catch e.name;
        gpa.free(e.version);
        e.version = gpa.dupe(u8, man.version) catch e.version;
        e.owned_files = owned;
    } else {
        g_exts.append(gpa, .{
            .id = gpa.dupe(u8, id) catch return "",
            .dir = gpa.dupe(u8, dir) catch return "",
            .name = gpa.dupe(u8, man.name) catch return "",
            .version = gpa.dupe(u8, man.version) catch return "",
            .enabled = true,
            .owned_files = owned,
        }) catch return "";
    }
    save();
    if (find(id)) |e| {
        webface.client().post(proto.WebextSet{ .id = e.id, .dir = e.dir, .enabled = if (e.enabled) 1 else 0 });
    }
    refreshOpenManager();
    return id;
}

pub fn setEnabled(id: []const u8, on: bool) void {
    const e = find(id) orelse return;
    e.enabled = on;
    save();
    webface.client().post(proto.WebextSet{ .id = e.id, .dir = e.dir, .enabled = if (on) 1 else 0 });
    refreshOpenManager();
}

pub fn remove(id: []const u8) void {
    const gpa = g_gpa orelse return;
    for (g_exts.items, 0..) |*e, i| {
        if (!std.mem.eql(u8, e.id, id)) continue;
        webface.client().post(proto.WebextRemove{ .id = e.id });
        // Files under our data dir may be deleted; an in-place unpacked
        // dir is left alone.
        if (e.owned_files) removeTree(gpa, e.dir);
        freeExt(e);
        _ = g_exts.orderedRemove(i);
        save();
        refreshOpenManager();
        return;
    }
}

// -- management window -----------------------------------------------

const Manager = struct {
    gpa: std.mem.Allocator,
    window: *c.GtkWidget,
    group: *c.AdwPreferencesGroup,
    parent: ?*c.GtkWindow,
};

var g_manager: ?*Manager = null;

/// Open (or focus) the extensions manager, parented to `parent_window`.
pub fn openManager(gpa: std.mem.Allocator, parent_window: *c.GtkWindow) void {
    ensureLoaded(gpa);
    if (g_manager) |m| {
        c.gtk_window_present(@ptrCast(m.window));
        return;
    }
    const win = c.adw_preferences_window_new();
    c.gtk_window_set_title(@ptrCast(win), "Browser Extensions");
    c.gtk_window_set_transient_for(@ptrCast(win), parent_window);
    c.gtk_window_set_default_size(@ptrCast(win), 560, 520);

    const page = c.adw_preferences_page_new();

    const add_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(add_group)), "Add");
    addActionRow(add_group, "Load Unpacked…", "Pick an unpacked extension directory (contains manifest.json)", &onLoadUnpacked);
    addActionRow(add_group, "Load Extension File…", "Pick an .xpi or .zip package", &onLoadArchive);
    c.adw_preferences_page_add(@ptrCast(@alignCast(page)), @ptrCast(@alignCast(add_group)));

    const list_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(list_group)), "Installed");
    c.adw_preferences_page_add(@ptrCast(@alignCast(page)), @ptrCast(@alignCast(list_group)));

    c.adw_preferences_window_add(@ptrCast(win), @ptrCast(@alignCast(page)));

    const m = gpa.create(Manager) catch return;
    m.* = .{ .gpa = gpa, .window = @ptrCast(win), .group = @ptrCast(@alignCast(list_group)), .parent = parent_window };
    g_manager = m;
    _ = c.g_signal_connect_data(win, "destroy", @ptrCast(&onManagerDestroy), @ptrCast(m), null, c.G_CONNECT_DEFAULT);

    rebuildList(m);
    c.gtk_window_present(@ptrCast(win));
}

fn onManagerDestroy(_: ?*c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const m = cast.userData(Manager, user);
    if (g_manager == m) g_manager = null;
    m.gpa.destroy(m);
}

fn refreshOpenManager() void {
    if (g_manager) |m| rebuildList(m);
}

/// Rebuild the installed-list group from the registry. A row per
/// extension: name/version + a switch and a Remove button.
fn rebuildList(m: *Manager) void {
    // Clear existing rows.
    while (c.gtk_widget_get_first_child(@ptrCast(@alignCast(m.group)))) |_| {
        // AdwPreferencesGroup wraps its rows; remove via its list box is
        // awkward, so rebuild by removing rows we added (tracked below).
        break;
    }
    // Simpler: remove every child row we track on the group via a
    // GtkListBox lookup is fragile across Adw versions; instead we drop
    // and recreate the whole group's rows by clearing tracked rows.
    clearGroupRows(m.group);

    if (g_exts.items.len == 0) {
        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "No extensions installed");
        c.adw_preferences_group_add(m.group, @ptrCast(@alignCast(row)));
        return;
    }

    for (g_exts.items) |*e| {
        const row = c.adw_action_row_new();
        var tbuf: [160:0]u8 = undefined;
        const title = std.fmt.bufPrintZ(&tbuf, "{s}", .{if (e.name.len != 0) e.name else e.id}) catch "extension";
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title.ptr);
        var sbuf: [256:0]u8 = undefined;
        const sub = if (!e.ok and e.err.len != 0)
            std.fmt.bufPrintZ(&sbuf, "v{s} — error: {s}", .{ e.version, e.err }) catch ""
        else
            std.fmt.bufPrintZ(&sbuf, "v{s}", .{e.version}) catch "";
        if (sub.len != 0) c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), sub.ptr);

        // Enabled switch.
        const sw = c.gtk_switch_new();
        c.gtk_switch_set_active(@ptrCast(sw), if (e.enabled) 1 else 0);
        c.gtk_widget_set_valign(sw, c.GTK_ALIGN_CENTER);
        const rc = rowCtx(m, e.id);
        _ = c.g_signal_connect_data(sw, "state-set", @ptrCast(&onToggle), @ptrCast(rc), @ptrCast(&freeRowCtx), c.G_CONNECT_DEFAULT);
        c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), sw);

        // Remove button.
        const btn = c.gtk_button_new_from_icon_name("user-trash-symbolic");
        c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
        c.gtk_widget_add_css_class(btn, "flat");
        const rc2 = rowCtx(m, e.id);
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onRemoveClicked), @ptrCast(rc2), @ptrCast(&freeRowCtx), c.G_CONNECT_DEFAULT);
        c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);

        c.adw_preferences_group_add(m.group, @ptrCast(@alignCast(row)));
        trackRow(m.group, @ptrCast(@alignCast(row)));
    }
}

// A tiny per-group list of the rows we added, so a rebuild can remove
// exactly them (AdwPreferencesGroup has no "clear").
var g_rows: std.ArrayList(struct { group: *c.AdwPreferencesGroup, row: *c.GtkWidget }) = .empty;

fn trackRow(group: *c.AdwPreferencesGroup, row: *c.GtkWidget) void {
    const gpa = g_gpa orelse return;
    g_rows.append(gpa, .{ .group = group, .row = row }) catch {};
}

fn clearGroupRows(group: *c.AdwPreferencesGroup) void {
    var i: usize = 0;
    while (i < g_rows.items.len) {
        if (g_rows.items[i].group == group) {
            c.adw_preferences_group_remove(group, @ptrCast(@alignCast(g_rows.items[i].row)));
            _ = g_rows.orderedRemove(i);
        } else i += 1;
    }
}

const RowCtx = struct { gpa: std.mem.Allocator, id: [64]u8, id_len: usize };

fn rowCtx(m: *Manager, id: []const u8) *RowCtx {
    const rc = m.gpa.create(RowCtx) catch unreachable;
    rc.* = .{ .gpa = m.gpa, .id = undefined, .id_len = @min(id.len, 64) };
    @memcpy(rc.id[0..rc.id_len], id[0..rc.id_len]);
    return rc;
}

fn freeRowCtx(user: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const rc = cast.userData(RowCtx, user);
    rc.gpa.destroy(rc);
}

fn onToggle(_: ?*c.GtkWidget, state: c.gboolean, user: ?*anyopaque) callconv(.c) c.gboolean {
    const rc = cast.userData(RowCtx, user);
    setEnabled(rc.id[0..rc.id_len], state != 0);
    return 0; // let the switch update its visual state
}

fn onRemoveClicked(_: ?*c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const rc = cast.userData(RowCtx, user);
    remove(rc.id[0..rc.id_len]);
}

fn addActionRow(group: ?*anyopaque, title: [*:0]const u8, subtitle: [*:0]const u8, cb: *const fn (?*c.GtkWidget, ?*anyopaque) callconv(.c) void) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    c.adw_action_row_set_activatable_widget(@ptrCast(@alignCast(row)), row);
    _ = c.g_signal_connect_data(row, "activated", @ptrCast(cb), null, null, c.G_CONNECT_DEFAULT);
    c.gtk_widget_add_css_class(row, "activatable");
    c.adw_preferences_group_add(@ptrCast(@alignCast(group)), @ptrCast(@alignCast(row)));
}

// -- file dialogs ----------------------------------------------------

fn onLoadUnpacked(_: ?*c.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    const m = g_manager orelse return;
    const dialog = c.gtk_file_dialog_new();
    c.gtk_file_dialog_set_title(dialog, "Select an unpacked extension folder");
    c.gtk_file_dialog_select_folder(dialog, @ptrCast(m.window), null, @ptrCast(&onFolderChosen), null);
}

fn onFolderChosen(source: ?*c.GObject, res: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const m = g_manager orelse return;
    const file = c.gtk_file_dialog_select_folder_finish(@ptrCast(source), res, null) orelse return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file) orelse return;
    defer c.g_free(path);
    _ = installUnpacked(m.gpa, std.mem.span(path)) catch {};
}

fn onLoadArchive(_: ?*c.GtkWidget, _: ?*anyopaque) callconv(.c) void {
    const m = g_manager orelse return;
    const dialog = c.gtk_file_dialog_new();
    c.gtk_file_dialog_set_title(dialog, "Select an extension package (.xpi / .zip)");
    c.gtk_file_dialog_open(dialog, @ptrCast(m.window), null, @ptrCast(&onArchiveChosen), null);
}

fn onArchiveChosen(source: ?*c.GObject, res: ?*c.GAsyncResult, _: ?*anyopaque) callconv(.c) void {
    const m = g_manager orelse return;
    const file = c.gtk_file_dialog_open_finish(@ptrCast(source), res, null) orelse return;
    defer c.g_object_unref(file);
    const path = c.g_file_get_path(file) orelse return;
    defer c.g_free(path);
    _ = installArchive(m.gpa, std.mem.span(path)) catch {};
}

// -- filesystem helpers ----------------------------------------------

fn readManifest(gpa: std.mem.Allocator, dir: []const u8) ?manifest.Manifest {
    const path = std.fmt.allocPrint(gpa, "{s}/manifest.json", .{dir}) catch return null;
    defer gpa.free(path);
    const bytes = readFile(gpa, path) orelse return null;
    defer gpa.free(bytes);
    return manifest.parse(gpa, bytes) catch null;
}

fn readFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    var zbuf: [4096]u8 = undefined;
    if (path.len + 1 > zbuf.len) return null;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&zbuf), c.O_RDONLY);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return null;
    const size: usize = @intCast(@max(st.st_size, 0));
    if (size == 0 or size > 64 * 1024 * 1024) return null;
    const buf = gpa.alloc(u8, size) catch return null;
    var got: usize = 0;
    while (got < size) {
        const n = c.read(fd, buf.ptr + got, size - got);
        if (n <= 0) break;
        got += @intCast(n);
    }
    if (got != size) {
        gpa.free(buf);
        return null;
    }
    return buf;
}

fn writeFile(path: []const u8, bytes: []const u8) void {
    var zbuf: [4096]u8 = undefined;
    if (path.len + 1 > zbuf.len) return;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const fd = c.open(@ptrCast(&zbuf), c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
}

fn mkdirAll(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and buf[i] != '/') continue;
        const save_ch = buf[i];
        buf[i] = 0;
        _ = c.mkdir(@ptrCast(&buf), 0o755);
        buf[i] = save_ch;
    }
}

/// Best-effort recursive delete of an owned extension directory.
fn removeTree(gpa: std.mem.Allocator, path: []const u8) void {
    var zbuf: [4096]u8 = undefined;
    if (path.len + 1 > zbuf.len) return;
    @memcpy(zbuf[0..path.len], path);
    zbuf[path.len] = 0;
    const dir = c.opendir(@ptrCast(&zbuf)) orelse {
        _ = c.unlink(@ptrCast(&zbuf));
        return;
    };
    while (c.readdir(dir)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, name }) catch continue;
        defer gpa.free(child);
        var cst: c.struct_stat = undefined;
        var cz: [4096]u8 = undefined;
        if (child.len + 1 > cz.len) continue;
        @memcpy(cz[0..child.len], child);
        cz[child.len] = 0;
        if (c.lstat(@ptrCast(&cz), &cst) == 0 and (cst.st_mode & c.S_IFMT) == c.S_IFDIR) {
            removeTree(gpa, child);
        } else {
            _ = c.unlink(@ptrCast(&cz));
        }
    }
    _ = c.closedir(dir);
    _ = c.rmdir(@ptrCast(&zbuf));
}

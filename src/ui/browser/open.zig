//! Opening files: the default handler, the Open With chooser (local
//! GAppInfo plus the host's own .desktop apps), remote opens through an
//! automatic FUSE mount, and the local-edit sync-back watches that
//! upload a remotely-sourced file again after an editor writes it.

const std = @import("std");
const c = @import("../../c.zig").c;

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const EditWatch = @import("types.zig").EditWatch;
const HostConn = @import("types.zig").HostConn;
const WireApp = @import("types.zig").WireApp;
const buildHostExecCmd = @import("../../filebrowser/desktop.zig").buildHostExecCmd;
const colview = @import("colview.zig");
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const hostmount = @import("../hostmount.zig");
const mimeListContains = @import("../../filebrowser/desktop.zig").mimeListContains;
const paths = @import("../../filebrowser/paths.zig");
const platform = @import("../../util/platform.zig");
const viewer_model = @import("../../viewer.zig");
const views = @import("views.zig");

/// One remote open waiting for its host's FUSE mount to come up.
pub const PendingOpen = struct {
    allocator: std.mem.Allocator,
    view: ?*BrowserView,
    hc: *HostConn,
    host: []u8,
    path: []u8,
    appid: ?[]u8,

    fn destroy(self: *PendingOpen) void {
        self.allocator.free(self.host);
        self.allocator.free(self.path);
        if (self.appid) |a| self.allocator.free(a);
        self.allocator.destroy(self);
    }
};

/// Open a remote file through the host's FUSE mount: the application
/// gets a real path and reads only the bytes it asks for.
///
/// This used to download the whole file into a cache first, which made
/// "open" mean "wait for three gigabytes" and left a copy behind. The
/// mount is the same mux file service, so a video seeks instead of
/// transferring, and edits write straight back with no sync-back watch
/// to reconcile. Downloading survives only as the fallback for hosts
/// where no mount can be made (no fuse3, a mount that will not start).
pub fn openRemoteFile(self: *BrowserView, tab: *BTab, path: []const u8, appid: ?[]const u8) void {
    self.openRemoteFileHc(tab.hc, path, appid);
}

pub fn openRemoteFileHc(self: *BrowserView, hc: *HostConn, path: []const u8, appid: ?[]const u8) void {
    const host = hc.host orelse return;
    switch (hostmount.ensure(self.allocator, host)) {
        .ready => return launchMounted(self, host, path, appid),
        .unavailable => {
            self.setStatusFmt("no FUSE mount for {s} ({s}) -- downloading a copy instead", .{
                host, hostmount.reasonFor(host),
            });
            return downloadAndOpen(self, hc, host, path, appid);
        },
        .starting => {},
    }
    const p = self.allocator.create(PendingOpen) catch
        return downloadAndOpen(self, hc, host, path, appid);
    p.* = .{
        .allocator = self.allocator,
        .view = self,
        .hc = hc,
        .host = self.allocator.dupe(u8, host) catch {
            self.allocator.destroy(p);
            return downloadAndOpen(self, hc, host, path, appid);
        },
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.free(p.host);
            self.allocator.destroy(p);
            return downloadAndOpen(self, hc, host, path, appid);
        },
        .appid = if (appid) |a| (self.allocator.dupe(u8, a) catch null) else null,
    };
    self.pending_opens.append(self.allocator, p) catch {
        p.destroy();
        return downloadAndOpen(self, hc, host, path, appid);
    };
    self.setStatusFmt("mounting {s}…", .{host});
    hostmount.whenReady(self.allocator, host, @ptrCast(p), &onMountReady);
}

fn onMountReady(ctx: ?*anyopaque, mounted: bool) void {
    const p: *PendingOpen = @ptrCast(@alignCast(ctx.?));
    defer p.destroy();
    const self = p.view orelse return;
    for (self.pending_opens.items, 0..) |pending, i| {
        if (pending == p) {
            _ = self.pending_opens.swapRemove(i);
            break;
        }
    }
    if (self.widgets_dead) return;
    if (mounted) return launchMounted(self, p.host, p.path, p.appid);
    self.setStatusFmt("could not mount {s} ({s}) -- downloading a copy instead", .{
        p.host, hostmount.reasonFor(p.host),
    });
    downloadAndOpen(self, p.hc, p.host, p.path, p.appid);
}

fn launchMounted(self: *BrowserView, host: []const u8, path: []const u8, appid: ?[]const u8) void {
    var buf: [8192]u8 = undefined;
    const local = hostmount.localPath(&buf, host, path) orelse {
        self.setStatusFmt("mount of {s} vanished -- downloading a copy instead", .{host});
        const hc = self.hostConnFor(host) orelse return;
        return downloadAndOpen(self, hc, host, path, appid);
    };
    if (appid) |id| launchLocalWithApp(id, local) else launchLocal(local);
    self.setStatusFmt("opening {s} from the {s} mount", .{ std.fs.path.basename(path), host });
}

/// The pre-mount behaviour, kept as the fallback: copy the file into
/// the local open-cache, launch on the copy, and watch it so local
/// edits are uploaded again.
fn downloadAndOpen(self: *BrowserView, hc: *HostConn, host: []const u8, path: []const u8, appid: ?[]const u8) void {
    const cache_root = c.g_get_user_cache_dir();
    var dirbuf: [4096:0]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dirbuf, "{s}/sketerm/fsopen", .{cache_root}) catch return;
    _ = c.g_mkdir_with_parents(dir.ptr, 0o700);
    var h = std.hash.Wyhash.init(0);
    h.update(host);
    h.update(path);
    var dstbuf: [4600]u8 = undefined;
    const dst = std.fmt.bufPrint(&dstbuf, "{s}/{x:0>16}-{s}", .{
        dir, h.final(), std.fs.path.basename(path),
    }) catch return;
    const service = self.transfer_service orelse {
        // The ledger DIRECTORY could not be created (an unwritable
        // state dir is the only remaining cause -- ownership is per
        // record now, so a second process is not one). Degrade to the
        // in-view transfer rather than refusing to open the file at
        // all; it just does not survive a restart.
        const local = self.hostConnFor(null) orelse return;
        if (local.state != .ready) {
            self.setStatus("local daemon unreachable");
            return;
        }
        self.startTransfer(hc, path, local, dst, .{
            .open_when_done = true,
            .open_with_appid = appid,
            .watch_host = host,
            .watch_remote = path,
        });
        self.setStatus("download is not restart-durable (the recovery ledger directory is unwritable)");
        return;
    };
    service.submitDownload(host, path, dst, appid, @ptrCast(self));
    self.setStatusFmt("durable download queued: {s}", .{std.fs.path.basename(path)});
    self.renderJobs();
}

/// Open a path that lives on `hc`'s host: directly for local, through
/// the host's mount for remote.
pub fn openPathOnHost(self: *BrowserView, hc: *HostConn, path: []const u8) void {
    if (hc.host == null) {
        launchLocal(path);
    } else {
        self.openRemoteFileHc(hc, path, null);
    }
}

var viewer_manifest_serial: u64 = 0;

fn sweepViewerManifests(directory: [:0]const u8) void {
    const dir = c.opendir(directory.ptr) orelse return;
    defer _ = c.closedir(dir);
    const now = c.time(null);
    while (c.readdir(dir)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (!std.mem.startsWith(u8, name, viewer_model.MANIFEST_PREFIX)) continue;
        var path_buf: [4096:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ directory, name }) catch continue;
        var st: c.struct_stat = undefined;
        if (c.lstat(path.ptr, &st) != 0 or
            st.st_uid != c.geteuid() or
            (st.st_mode & c.S_IFMT) != c.S_IFREG) continue;
        const modified = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim.tv_sec else st.st_mtimespec.tv_sec;
        if (modified + 300 < now) _ = c.unlink(path.ptr);
    }
}

fn writeViewerManifest(bytes: []const u8, out: *[4096:0]u8) ?[:0]const u8 {
    var dir_buf: [4096:0]u8 = undefined;
    const dir = viewer_model.ensureManifestDirectory(&dir_buf) orelse return null;
    sweepViewerManifests(dir);
    var fd: c_int = -1;
    var path: [:0]u8 = undefined;
    var attempts: u8 = 0;
    while (attempts < 8) : (attempts += 1) {
        viewer_manifest_serial +%= 1;
        path = std.fmt.bufPrintZ(out, "{s}/viewer-batch-{d}-{x}", .{
            dir,
            c.getpid(),
            @as(u64, @bitCast(c.g_get_monotonic_time())) ^ viewer_manifest_serial,
        }) catch return null;
        fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        if (fd >= 0) break;
    }
    if (fd < 0) return null;
    if (c.fchmod(fd, @as(c.mode_t, 0o600)) != 0) {
        _ = c.close(fd);
        _ = c.unlink(path.ptr);
        return null;
    }
    var open = true;
    var installed = false;
    defer {
        if (open) _ = c.close(fd);
        if (!installed) _ = c.unlink(path.ptr);
    }
    var at: usize = 0;
    while (at < bytes.len) {
        const n = c.write(fd, bytes.ptr + at, bytes.len - at);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return null;
        at += @intCast(n);
    }
    if (c.fsync(fd) != 0) return null;
    const close_rc = c.close(fd);
    open = false;
    if (close_rc != 0) return null;
    installed = true;
    return path;
}

const ManifestCleanup = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
};

fn cleanupViewerManifest(user: ?*anyopaque) callconv(.c) c.gboolean {
    const cleanup: *ManifestCleanup = @ptrCast(@alignCast(user.?));
    _ = c.unlink(cleanup.path.ptr);
    cleanup.allocator.free(cleanup.path);
    cleanup.allocator.destroy(cleanup);
    return 0;
}

fn scheduleViewerManifestCleanup(path: []const u8) void {
    const allocator = std.heap.c_allocator;
    const cleanup = allocator.create(ManifestCleanup) catch return;
    cleanup.* = .{
        .allocator = allocator,
        .path = allocator.dupeZ(u8, path) catch {
            allocator.destroy(cleanup);
            return;
        },
    };
    if (c.g_timeout_add_seconds(60, @ptrCast(&cleanupViewerManifest), @ptrCast(cleanup)) == 0)
        _ = cleanupViewerManifest(@ptrCast(cleanup));
}

/// Launch the internal Viewer with this tab's ordered image sequence without FUSE.
pub fn launchViewer(self: *BrowserView, tab: *BTab, current: []const u8) void {
    const allocator = self.allocator;
    var specs: std.ArrayList([]u8) = .empty;
    defer {
        for (specs.items) |spec| allocator.free(spec);
        specs.deinit(allocator);
    }
    var initial: usize = 0;
    var found_current = false;
    const selected_only = tab.selected.items.len > 1 and blk: {
        for (tab.selected.items) |path| if (std.mem.eql(u8, path, current)) break :blk true;
        break :blk false;
    };
    if (selected_only) {
        for (tab.selected.items) |path| {
            if (!paths.isImageName(path)) continue;
            const is_current = std.mem.eql(u8, path, current);
            const owned = paths.formatSpecAlloc(allocator, tab.hc.host, path) catch continue;
            specs.append(allocator, owned) catch {
                allocator.free(owned);
                break;
            };
            if (is_current) {
                initial = specs.items.len - 1;
                found_current = true;
            }
        }
    } else {
        switch (tab.view_mode) {
            .icons => {
                var path_buf: [4096]u8 = undefined;
                for (tab.root.entries.items) |entry| {
                    if (entry.tdir or !views.entryVisible(tab, entry) or !paths.isImageName(entry.name)) continue;
                    const path = tab.root.fullPath(entry, &path_buf) orelse continue;
                    const is_current = std.mem.eql(u8, path, current);
                    const owned = paths.formatSpecAlloc(allocator, tab.hc.host, path) catch continue;
                    specs.append(allocator, owned) catch {
                        allocator.free(owned);
                        break;
                    };
                    if (is_current) {
                        initial = specs.items.len - 1;
                        found_current = true;
                    }
                }
            },
            .details, .compact, .miller => {
                var pos: c.guint = 0;
                while (pos < colview.itemCount(tab)) : (pos += 1) {
                    const item = colview.itemDataAt(tab, pos) orelse continue;
                    if (item.kind != .entry or item.is_dir or !paths.isImageName(item.path)) continue;
                    const is_current = std.mem.eql(u8, item.path, current);
                    const owned = paths.formatSpecAlloc(allocator, tab.hc.host, item.path) catch continue;
                    specs.append(allocator, owned) catch {
                        allocator.free(owned);
                        break;
                    };
                    if (is_current) {
                        initial = specs.items.len - 1;
                        found_current = true;
                    }
                }
            },
        }
    }
    if (!found_current) {
        const owned = paths.formatSpecAlloc(allocator, tab.hc.host, current) catch return;
        initial = specs.items.len;
        specs.append(allocator, owned) catch {
            allocator.free(owned);
            return;
        };
    }

    var exe_buf: [4096:0]u8 = undefined;
    const exe = platform.exePathZ(&exe_buf) orelse return;
    var viewer_buf: [4096:0]u8 = undefined;
    const sibling: ?[*:0]const u8 = blk: {
        const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse break :blk null;
        const candidate = std.fmt.bufPrintZ(&viewer_buf, "{s}/sketerm-viewer", .{exe[0..slash]}) catch break :blk null;
        if (c.access(candidate.ptr, c.X_OK) != 0) break :blk null;
        break :blk candidate.ptr;
    };
    const manifest = viewer_model.encodeManifest(allocator, specs.items, initial) catch {
        self.setStatus("image sequence is too large to open in Sketerm Viewer");
        return;
    };
    defer allocator.free(manifest);
    var manifest_path_buf: [4096:0]u8 = undefined;
    const manifest_path = writeViewerManifest(manifest, &manifest_path_buf) orelse {
        self.setStatus("could not create the Sketerm Viewer handoff");
        return;
    };
    var manifest_arg_buf: [4200:0]u8 = undefined;
    const manifest_arg = std.fmt.bufPrintZ(&manifest_arg_buf, "{s}{s}", .{ viewer_model.MANIFEST_OPTION, manifest_path }) catch {
        _ = c.unlink(manifest_path.ptr);
        return;
    };
    const argc: usize = if (sibling != null) 2 else 3;
    const argv = allocator.alloc([*c]u8, argc + 1) catch {
        _ = c.unlink(manifest_path.ptr);
        return;
    };
    defer allocator.free(argv);
    argv[0] = @constCast(@as([*c]const u8, if (sibling) |bin| bin else exe.ptr));
    var arg_at: usize = 1;
    if (sibling == null) {
        argv[arg_at] = @constCast(@as([*c]const u8, "view"));
        arg_at += 1;
    }
    argv[arg_at] = @constCast(@as([*c]const u8, manifest_arg.ptr));
    arg_at += 1;
    argv[arg_at] = null;
    var gerr: [*c]c.GError = null;
    if (c.g_spawn_async(null, argv.ptr, null, @intCast(c.G_SPAWN_DEFAULT), null, null, null, &gerr) == 0) {
        _ = c.unlink(manifest_path.ptr);
        if (gerr != null) c.g_error_free(gerr);
        self.setStatus("could not launch Sketerm Viewer");
    } else {
        scheduleViewerManifestCleanup(manifest_path);
        self.setStatusFmt("opening {s} in Sketerm Viewer", .{std.fs.path.basename(current)});
    }
}

/// Heap context for one Open With popover; owned by the popover.
pub const OpenWithCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    path: []u8,
    /// In-flight host `apps` request (0 = none).
    req: u32 = 0,
    host_box: *c.GtkWidget,
    host_label: *c.GtkWidget,
    popover: *c.GtkWidget,

    fn free(user: ?*anyopaque) callconv(.c) void {
        const ctx: *OpenWithCtx = @ptrCast(@alignCast(user.?));
        if (ctx.view.openwith == ctx) ctx.view.openwith = null;
        ctx.allocator.free(ctx.path);
        ctx.allocator.destroy(ctx);
    }
};

/// Heap context for one app button (GClosureNotify-freed).
pub const AppBtnCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    path: []u8,
    /// Local application id (GAppInfo) — launch locally.
    appid: ?[]u8 = null,
    /// Host .desktop Exec line — launch on the file's host.
    exec: ?[]u8 = null,
    popover: *c.GtkWidget,

    fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        const a: *AppBtnCtx = @ptrCast(@alignCast(user.?));
        a.allocator.free(a.path);
        if (a.appid) |s| a.allocator.free(s);
        if (a.exec) |s| a.allocator.free(s);
        a.allocator.destroy(a);
    }
};

/// The application chooser: local apps for the guessed type plus,
/// on a remote tab, the apps installed on the file's host.
pub fn openWithDialog(self: *BrowserView, tab: *BTab, path: []const u8) void {
    const is_local = tab.hc.host == null;
    const popover = c.gtk_popover_new();
    const ctx = self.allocator.create(OpenWithCtx) catch return;
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    const host_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2);
    const host_label = c.gtk_label_new("");
    ctx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = tab,
        .path = self.allocator.dupe(u8, path) catch {
            self.allocator.destroy(ctx);
            return;
        },
        .host_box = host_box,
        .host_label = host_label,
        .popover = popover,
    };
    c.g_object_set_data_full(@ptrCast(popover), "sketerm-openwith", @ptrCast(ctx), @ptrCast(&OpenWithCtx.free));

    // Local applications for the file's guessed content type.
    const sec = c.gtk_label_new(if (is_local) "Open with:" else "Open locally (through the host mount):");
    c.gtk_widget_add_css_class(sec, "dim-label");
    c.gtk_label_set_xalign(@ptrCast(sec), 0);
    c.gtk_box_append(@ptrCast(box), sec);

    const owdef = c.gtk_check_button_new_with_label("Always use for this file type");
    c.g_object_set_data(@ptrCast(popover), "sketerm-owdef", @ptrCast(owdef));

    var namez: [512:0]u8 = undefined;
    const base = std.fs.path.basename(path);
    var app_count: usize = 0;
    if (std.fmt.bufPrintZ(&namez, "{s}", .{base})) |bz| {
        var uncertain: c.gboolean = 0;
        const ct = c.g_content_type_guess(bz.ptr, null, 0, &uncertain);
        if (ct != null) {
            const apps = c.g_app_info_get_all_for_type(ct);
            var it = apps;
            while (it != null and app_count < 20) : (it = it.*.next) {
                const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
                const id = c.g_app_info_get_id(app) orelse continue;
                const nm = c.g_app_info_get_name(app) orelse continue;
                self.appChoiceButton(box, ctx, std.mem.span(nm), std.mem.span(id), null);
                app_count += 1;
            }
            if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
            c.g_free(ct);
        }
    } else |_| {}
    if (app_count == 0) {
        const none = c.gtk_label_new("(no known local handler)");
        c.gtk_widget_add_css_class(none, "dim-label");
        c.gtk_box_append(@ptrCast(box), none);
    }
    c.gtk_box_append(@ptrCast(box), owdef);

    // Host applications (remote tabs): one daemon round trip.
    // The widgets always join the tree (hidden locally) so they
    // never dangle as floating refs.
    c.gtk_widget_add_css_class(host_label, "dim-label");
    c.gtk_label_set_xalign(@ptrCast(host_label), 0);
    c.gtk_box_append(@ptrCast(box), host_label);
    c.gtk_box_append(@ptrCast(box), host_box);
    if (!is_local) {
        c.gtk_label_set_text(@ptrCast(host_label), "On host: loading…");
        if (tab.hc.state == .ready) {
            ctx.req = self.nextReq();
            self.openwith = ctx;
            self.sendOp(tab.hc, .{ .req = ctx.req, .op = "apps", .path = "/" });
        } else {
            c.gtk_label_set_text(@ptrCast(host_label), "On host: not connected");
        }
    } else {
        c.gtk_widget_set_visible(host_label, 0);
        c.gtk_widget_set_visible(host_box, 0);
    }

    const scroll = c.gtk_scrolled_window_new();
    c.gtk_widget_set_size_request(scroll, 320, 380);
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), box);
    c.gtk_popover_set_child(@ptrCast(popover), scroll);
    c.gtk_widget_set_parent(popover, tab.page);
    connectPopoverAutoUnparent(popover);
    const rect = c.GdkRectangle{ .x = 320, .y = 200, .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    c.gtk_popover_popup(@ptrCast(popover));
}

pub fn appChoiceButton(
    self: *BrowserView,
    box: *c.GtkWidget,
    ctx: *OpenWithCtx,
    name: []const u8,
    appid: ?[]const u8,
    exec: ?[]const u8,
) void {
    const actx = self.allocator.create(AppBtnCtx) catch return;
    actx.* = .{
        .allocator = self.allocator,
        .view = self,
        .tab = ctx.tab,
        .path = self.allocator.dupe(u8, ctx.path) catch {
            self.allocator.destroy(actx);
            return;
        },
        .appid = if (appid) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .exec = if (exec) |s| (self.allocator.dupe(u8, s) catch null) else null,
        .popover = ctx.popover,
    };
    var lbl: [256:0]u8 = undefined;
    const ltxt = std.fmt.bufPrintZ(&lbl, "{s}", .{name}) catch return;
    const btn = c.gtk_button_new_with_label(ltxt.ptr);
    c.gtk_button_set_has_frame(@ptrCast(btn), 0);
    c.gtk_widget_set_halign(c.gtk_button_get_child(@ptrCast(btn)), c.GTK_ALIGN_START);
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onAppBtnClicked), @ptrCast(actx), @ptrCast(&AppBtnCtx.free), c.G_CONNECT_DEFAULT);
    c.gtk_box_append(@ptrCast(box), btn);
}

pub fn onAppBtnClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const actx: *AppBtnCtx = @ptrCast(@alignCast(user.?));
    const self = actx.view;
    const tab = actx.tab;
    if (actx.exec) |exec| {
        // Host application: substituted Exec runs as an app
        // session on the file's host; its window forwards here.
        if (self.on_host_exec) |cb| {
            if (self.hooks_ctx) |hctx| {
                if (buildHostExecCmd(self.allocator, exec, actx.path)) |cmd| {
                    defer self.allocator.free(cmd);
                    var z: [4600:0]u8 = undefined;
                    if (std.fmt.bufPrintZ(&z, "{s}", .{cmd})) |cz| {
                        cb(hctx, tab.hc.host orelse "", cz);
                        self.setStatus("opening on host (app window forwards here)…");
                    } else |_| {}
                }
            }
        }
    } else if (actx.appid) |appid| {
        // "Always use for this type": register the association
        // before launching.
        if (c.g_object_get_data(@ptrCast(actx.popover), "sketerm-owdef")) |cb| {
            if (c.gtk_check_button_get_active(@ptrCast(@alignCast(cb))) != 0)
                setDefaultAppForPath(appid, actx.path);
        }
        if (tab.hc.host == null) {
            launchLocalWithApp(appid, actx.path);
        } else {
            self.openRemoteFile(tab, actx.path, appid);
        }
    }
    c.gtk_popover_popdown(@ptrCast(actx.popover));
}

/// The MIME type GIO guesses from a file NAME alone (no content
/// sniffing: the file may live on another host).
/// @return "" when nothing could be guessed or `buf` is too small.
pub fn guessMime(buf: []u8, name: []const u8) []const u8 {
    var namez: [512:0]u8 = undefined;
    const bz = std.fmt.bufPrintZ(&namez, "{s}", .{name}) catch return "";
    var uncertain: c.gboolean = 0;
    const ct = c.g_content_type_guess(bz.ptr, null, 0, &uncertain);
    if (ct == null) return "";
    defer c.g_free(ct);
    const m = c.g_content_type_get_mime_type(ct) orelse return "";
    defer c.g_free(m);
    const ms = std.mem.span(@as([*:0]const u8, @ptrCast(m)));
    if (ms.len > buf.len) return "";
    @memcpy(buf[0..ms.len], ms);
    return buf[0..ms.len];
}

/// Fill the chooser's host section from the daemon's app list,
/// filtered by the file's locally-guessed MIME type.
pub fn populateHostApps(self: *BrowserView, ow: *OpenWithCtx, ok: bool, apps: []const WireApp) void {
    ow.req = 0;
    if (!ok) {
        // Any refused app-list query: the section simply has nothing
        // to offer. Local apps are listed regardless.
        c.gtk_label_set_text(@ptrCast(ow.host_label), "On host: unavailable");
        return;
    }
    var hostz: [280:0]u8 = undefined;
    const htxt = std.fmt.bufPrintZ(&hostz, "On {s}:", .{ow.tab.hc.label()}) catch "On host:";
    c.gtk_label_set_text(@ptrCast(ow.host_label), htxt.ptr);

    // Guess the MIME locally from the file name.
    var mime_buf: [256]u8 = undefined;
    const mime = guessMime(&mime_buf, std.fs.path.basename(ow.path));

    var shown: usize = 0;
    if (mime.len > 0) {
        for (apps) |app| {
            if (shown >= 20) break;
            if (!mimeListContains(app.mimes, mime)) continue;
            self.appChoiceButton(ow.host_box, ow, app.name, null, app.exec);
            shown += 1;
        }
    }
    if (shown == 0) {
        // No MIME match: offer everything, bounded.
        for (apps) |app| {
            if (shown >= 30) break;
            self.appChoiceButton(ow.host_box, ow, app.name, null, app.exec);
            shown += 1;
        }
    }
    if (shown == 0)
        c.gtk_label_set_text(@ptrCast(ow.host_label), "On host: no applications found");
}

/// Watch a landed download; local saves upload back to the host.
pub fn registerEditWatch(self: *BrowserView, host: []const u8, remote_path: []const u8, cache_path: []const u8) void {
    for (self.watches.items) |wt| {
        if (std.mem.eql(u8, wt.host, host) and std.mem.eql(u8, wt.remote_path, remote_path)) return;
    }
    const wt = self.allocator.create(EditWatch) catch return;
    wt.* = .{
        .view = self,
        .host = self.allocator.dupe(u8, host) catch {
            self.allocator.destroy(wt);
            return;
        },
        .remote_path = self.allocator.dupe(u8, remote_path) catch {
            self.allocator.free(wt.host);
            self.allocator.destroy(wt);
            return;
        },
        .cache_path = self.allocator.dupe(u8, cache_path) catch {
            self.allocator.free(wt.host);
            self.allocator.free(wt.remote_path);
            self.allocator.destroy(wt);
            return;
        },
    };
    var z: [4600:0]u8 = undefined;
    const pz = std.fmt.bufPrintZ(&z, "{s}", .{cache_path}) catch {
        wt.destroy(self.allocator);
        return;
    };
    const gfile = c.g_file_new_for_path(pz.ptr);
    wt.monitor = c.g_file_monitor_file(gfile, c.G_FILE_MONITOR_NONE, null, null);
    c.g_object_unref(gfile);
    if (wt.monitor == null) {
        wt.destroy(self.allocator);
        return;
    }
    _ = c.g_signal_connect_data(wt.monitor, "changed", @ptrCast(&onEditWatchChanged), @ptrCast(wt), null, c.G_CONNECT_DEFAULT);
    self.watches.append(self.allocator, wt) catch {
        wt.destroy(self.allocator);
        return;
    };
    self.setStatusFmt("local edits to {s} will sync back to {s}", .{
        std.fs.path.basename(remote_path), host,
    });
}

pub fn onEditWatchChanged(
    _: *c.GFileMonitor,
    _: ?*c.GFile,
    _: ?*c.GFile,
    event: c.GFileMonitorEvent,
    user: ?*anyopaque,
) callconv(.c) void {
    if (event != c.G_FILE_MONITOR_EVENT_CHANGES_DONE_HINT) return;
    const wt: *EditWatch = @ptrCast(@alignCast(user.?));
    wt.view.uploadEditWatch(wt);
}

pub fn uploadEditWatch(self: *BrowserView, wt: *EditWatch) void {
    if (wt.uploading) return;
    const local = self.hostConnFor(null) orelse return;
    const remote = self.hostConnFor(wt.host) orelse return;
    if (local.state != .ready or remote.state != .ready) {
        self.setStatusFmt("edit sync-back to {s} deferred (reconnecting) — save again to retry", .{wt.host});
        return;
    }
    wt.uploading = true;
    self.startTransfer(local, wt.cache_path, remote, wt.remote_path, .{ .upload_watch = wt });
    self.renderJobs();
}

pub fn launchLocal(path: []const u8) void {
    const uri = filenameUri(path) orelse return;
    defer c.g_free(uri);
    _ = c.g_app_info_launch_default_for_uri(uri, null, null);
}

/// Launch a specific installed application (by GAppInfo id) on a
/// local path; falls back to the default handler if the id vanished.
pub fn launchLocalWithApp(appid: []const u8, path: []const u8) void {
    const uri = filenameUri(path) orelse return;
    defer c.g_free(uri);
    const apps = c.g_app_info_get_all();
    defer if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
    var it = apps;
    while (it != null) : (it = it.*.next) {
        const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
        const id = c.g_app_info_get_id(app) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(id), appid)) continue;
        var list: ?*c.GList = null;
        list = c.g_list_append(list, @ptrCast(uri));
        _ = c.g_app_info_launch_uris(app, list, null, null);
        c.g_list_free(list);
        return;
    }
    launchLocal(path);
}

pub fn filenameUri(path: []const u8) ?[*c]c.gchar {
    var path_buf: [4096:0]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    const uri = c.g_filename_to_uri(path_z.ptr, null, null);
    return if (uri == null) null else uri;
}

/// Make `appid` the default handler for `path`'s guessed type.
pub fn setDefaultAppForPath(appid: []const u8, path: []const u8) void {
    var namez: [512:0]u8 = undefined;
    const base = std.fs.path.basename(path);
    const bz = std.fmt.bufPrintZ(&namez, "{s}", .{base}) catch return;
    var uncertain: c.gboolean = 0;
    const ct = c.g_content_type_guess(bz.ptr, null, 0, &uncertain);
    if (ct == null) return;
    defer c.g_free(ct);
    const apps = c.g_app_info_get_all();
    defer if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
    var it = apps;
    while (it != null) : (it = it.*.next) {
        const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
        const id = c.g_app_info_get_id(app) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(id), appid)) continue;
        _ = c.g_app_info_set_as_default_for_type(app, ct, null);
        return;
    }
}

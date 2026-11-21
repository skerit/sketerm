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
const colview = @import("colview.zig");
const hostmount = @import("../hostmount.zig");
const openwith = @import("../../filebrowser/openwith.zig");
const openwith_dialog = @import("openwith.zig");
const paths = @import("../../filebrowser/paths.zig");
const platform = @import("../../util/platform.zig");
const dirsweep = @import("../../util/dirsweep.zig");
const viewer_model = @import("../../viewer.zig");
const views = @import("views.zig");
const cast = @import("../../util/cast.zig");
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
    const p = cast.userData(PendingOpen, ctx);
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
    var ebuf: [256]u8 = undefined;
    if (launchLocalOpener(appid, local, &ebuf)) |why| {
        self.setStatusFmt("could not open {s}: {s}", .{ std.fs.path.basename(path), why });
        return;
    }
    self.setStatusFmt("opening {s} from the {s} mount", .{ std.fs.path.basename(path), host });
}

/// The pre-mount behaviour, kept as the fallback: copy the file into
/// the local open-cache, launch on the copy, and watch it so local
/// edits are uploaded again.
fn downloadAndOpen(self: *BrowserView, hc: *HostConn, host: []const u8, path: []const u8, appid: ?[]const u8) void {
    const cache_root = c.g_get_user_cache_dir();
    var dirbuf: [4096:0]u8 = undefined;
    const dir = std.fmt.bufPrintSentinel(&dirbuf, "{s}/sketerm/fsopen", .{cache_root}, 0) catch return;
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

/// A manifest is read by the viewer it was written for within seconds;
/// one older than this outlived a viewer that never started.
const MANIFEST_MAX_AGE_SECS = 300;

fn writeViewerManifest(bytes: []const u8, out: *[4096:0]u8) ?[:0]const u8 {
    var dir_buf: [4096:0]u8 = undefined;
    const dir = viewer_model.ensureManifestDirectory(&dir_buf) orelse return null;
    dirsweep.sweep(dir.ptr, .{ .prefix = viewer_model.MANIFEST_PREFIX, .max_age_secs = MANIFEST_MAX_AGE_SECS });
    var fd: c_int = -1;
    var path: [:0]u8 = undefined;
    var attempts: u8 = 0;
    while (attempts < 8) : (attempts += 1) {
        viewer_manifest_serial +%= 1;
        path = std.fmt.bufPrintSentinel(out, "{s}/viewer-batch-{d}-{x}", .{
            dir,
            c.getpid(),
            @as(u64, @bitCast(c.g_get_monotonic_time())) ^ viewer_manifest_serial,
        }, 0) catch return null;
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
    const cleanup = cast.userData(ManifestCleanup, user);
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
        .path = allocator.dupeSentinel(u8, path, 0) catch {
            allocator.destroy(cleanup);
            return;
        },
    };
    if (c.g_timeout_add_seconds(60, @ptrCast(&cleanupViewerManifest), @ptrCast(cleanup)) == 0)
        _ = cleanupViewerManifest(@ptrCast(cleanup));
}

/// Accumulator for one ordered spec walk over a tab's listing.
pub const SpecWalk = struct {
    specs: std.ArrayList([]u8) = .empty,
    initial: usize = 0,
    found_current: bool = false,

    fn add(self: *SpecWalk, allocator: std.mem.Allocator, host: ?[]const u8, path: []const u8, current: []const u8) bool {
        const is_current = std.mem.eql(u8, path, current);
        const owned = paths.formatSpecAlloc(allocator, host, path) catch return true;
        self.specs.append(allocator, owned) catch {
            allocator.free(owned);
            return false;
        };
        if (is_current) {
            self.initial = self.specs.items.len - 1;
            self.found_current = true;
        }
        return true;
    }

    pub fn deinit(self: *SpecWalk, allocator: std.mem.Allocator) void {
        for (self.specs.items) |spec| allocator.free(spec);
        self.specs.deinit(allocator);
    }
};

/// Walk the tab's RENDERED listing in display order and append a
/// host-qualified spec for every non-directory entry whose name
/// `include` accepts. Shared by launchViewer (images/casts only) and
/// the Quick Look host (every file).
pub fn collectListingSpecs(
    self: *BrowserView,
    tab: *BTab,
    current: []const u8,
    include: *const fn ([]const u8) bool,
    walk: *SpecWalk,
) void {
    const allocator = self.allocator;
    switch (tab.view_mode) {
        .icons => {
            var path_buf: [4096]u8 = undefined;
            for (tab.root.entries.items) |entry| {
                if (entry.tdir or !views.entryVisible(tab, entry) or !include(entry.name)) continue;
                const path = tab.root.fullPath(entry, &path_buf) orelse continue;
                if (!walk.add(allocator, tab.hc.host, path, current)) break;
            }
        },
        .details, .compact, .miller => {
            var pos: c.guint = 0;
            while (pos < colview.itemCount(tab)) : (pos += 1) {
                const item = colview.itemDataAt(tab, pos) orelse continue;
                if (item.kind != .entry or item.is_dir or !include(item.path)) continue;
                if (!walk.add(allocator, tab.hc.host, item.path, current)) break;
            }
        },
    }
}

/// Launch the internal Viewer with this tab's ordered viewable sequence
/// (images, video/audio, and `.cast` recordings, the last two played in
/// place) without FUSE.
pub fn launchViewer(self: *BrowserView, tab: *BTab, current: []const u8) void {
    const allocator = self.allocator;
    var walk: SpecWalk = .{};
    defer walk.deinit(allocator);
    if (tab.selected.actsOnAll(current)) {
        for (tab.selected.items) |path| {
            if (!paths.isViewerName(path)) continue;
            if (!walk.add(allocator, tab.hc.host, path, current)) break;
        }
    } else {
        collectListingSpecs(self, tab, current, &paths.isViewerName, &walk);
    }
    const specs = &walk.specs;
    var initial: usize = walk.initial;
    if (!walk.found_current) {
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
        const candidate = std.fmt.bufPrintSentinel(&viewer_buf, "{s}/sketerm-viewer", .{exe[0..slash]}, 0) catch break :blk null;
        if (c.access(candidate.ptr, c.X_OK) != 0) break :blk null;
        break :blk candidate.ptr;
    };
    const manifest = viewer_model.encodeManifest(allocator, specs.items, initial) catch {
        self.setStatus("this sequence is too large to open in Sketerm Viewer");
        return;
    };
    defer allocator.free(manifest);
    var manifest_path_buf: [4096:0]u8 = undefined;
    const manifest_path = writeViewerManifest(manifest, &manifest_path_buf) orelse {
        self.setStatus("could not create the Sketerm Viewer handoff");
        return;
    };
    var manifest_arg_buf: [4200:0]u8 = undefined;
    const manifest_arg = std.fmt.bufPrintSentinel(&manifest_arg_buf, "{s}{s}", .{ viewer_model.MANIFEST_OPTION, manifest_path }, 0) catch {
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

/// Launch `sketerm play <spec>` for a terminal recording: a separate
/// process, the way the Viewer item spawns one.
///
/// Unlike the Viewer and the Editor, playback has no sibling binary of
/// its own — it is a subcommand of the TERMINAL identity, so argv[0]
/// must be `sketerm`. Spawning our own exe blindly would be wrong in a
/// `sketerm-files` process: that name makes the child parse `play` as a
/// files spec. The sibling `sketerm` next to us is therefore preferred,
/// with our own exe as the fallback (a build tree, or a browser pane
/// living inside a terminal process, where the two are the same file).
///
/// `spec` is host-qualified (`local:/path` or `host:/path`), so a
/// recording on a remote tab plays from that host's daemon.
pub fn launchCastPlayer(self: *BrowserView, spec: []const u8) void {
    var exe_buf: [4096:0]u8 = undefined;
    const exe = platform.exePathZ(&exe_buf) orelse return;
    var sibling_buf: [4096:0]u8 = undefined;
    const binary: [*:0]const u8 = blk: {
        const slash = std.mem.lastIndexOfScalar(u8, exe, '/') orelse break :blk exe.ptr;
        const candidate = std.fmt.bufPrintSentinel(&sibling_buf, "{s}/sketerm", .{exe[0..slash]}, 0) catch break :blk exe.ptr;
        if (c.access(candidate.ptr, c.X_OK) != 0) break :blk exe.ptr;
        break :blk candidate.ptr;
    };
    var spec_buf: [paths.SPEC_BUF_LEN:0]u8 = undefined;
    const spec_z = std.fmt.bufPrintSentinel(&spec_buf, "{s}", .{spec}, 0) catch return;
    var argv: [4]?[*:0]u8 = .{
        @constCast(binary),
        @constCast(@as([*:0]const u8, "play")),
        @constCast(@as([*:0]const u8, spec_z.ptr)),
        null,
    };
    var gerr: [*c]c.GError = null;
    if (c.g_spawn_async(null, @ptrCast(&argv), null, @intCast(c.G_SPAWN_DEFAULT), null, null, null, &gerr) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        self.setStatus("could not launch the Sketerm cast player");
        return;
    }
    self.setStatusFmt("playing {s} in Sketerm", .{std.fs.path.basename(spec)});
}

/// The Open With chooser for a file in `tab`: local applications plus,
/// on a remote tab, the ones installed on the file's host.
pub fn openWithDialog(self: *BrowserView, tab: *BTab, path: []const u8) void {
    if (self.widgets_dead) return;
    if (openwith_dialog.present(.{
        .allocator = self.allocator,
        .parent = self.root_box,
        .path = path,
        .view = self,
        .host = tab.hc.host,
    }) == null) self.setStatus("could not open the application chooser");
}

/// The MIME type GIO guesses from a file NAME alone (no content
/// sniffing: the file may live on another host).
/// @return "" when nothing could be guessed or `buf` is too small.
pub fn guessMime(buf: []u8, name: []const u8) []const u8 {
    const ct = guessContentType(name) orelse return "";
    defer c.g_free(ct);
    const m = c.g_content_type_get_mime_type(ct) orelse return "";
    defer c.g_free(m);
    const ms = std.mem.span(@as([*:0]const u8, @ptrCast(m)));
    if (ms.len > buf.len) return "";
    @memcpy(buf[0..ms.len], ms);
    return buf[0..ms.len];
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
    const pz = std.fmt.bufPrintSentinel(&z, "{s}", .{cache_path}, 0) catch {
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
    launchLocalWithApp(null, path);
}

/// Fire-and-forget launch for paths with no UI to report to; a failure
/// is logged rather than dropped.
pub fn launchLocalWithApp(app_id: ?[]const u8, path: []const u8) void {
    var buf: [512]u8 = undefined;
    if (launchLocalOpener(app_id, path, &buf)) |why|
        std.debug.print("sketerm: could not open {s}: {s}\n", .{ path, why });
}

/// Launch a local path with an opener string (`filebrowser/openwith.zig`
/// `Opener`: desktop id, encoded custom command, or null for the
/// default handler). A desktop id that vanished falls back to the
/// default handler.
/// @return why the launch failed, written into `err_buf`, or null.
pub fn launchLocalOpener(app_id: ?[]const u8, path: []const u8, err_buf: []u8) ?[]const u8 {
    var err: [*c]c.GError = null;
    defer if (err != null) c.g_error_free(err);
    const app: ?*c.GAppInfo = switch (openwith.parseOpener(app_id)) {
        .default => null,
        .desktop_id => |id| appInfoById(id),
        .command => |cmd| commandAppInfo(cmd, &err) orelse return errorText(err, err_buf),
    };
    defer if (app) |a| c.g_object_unref(a);
    return launchInfo(app, path, err_buf);
}

/// Launch a local path with `app`, or the default handler when null.
/// @return why the launch failed, written into `err_buf`, or null.
pub fn launchInfo(app: ?*c.GAppInfo, path: []const u8, err_buf: []u8) ?[]const u8 {
    const uri = filenameUri(path) orelse
        return std.fmt.bufPrint(err_buf, "not a usable local path", .{}) catch "";
    defer c.g_free(uri);
    var err: [*c]c.GError = null;
    defer if (err != null) c.g_error_free(err);
    const ok = if (app) |a| launchUri(a, uri, &err) else c.g_app_info_launch_default_for_uri(uri, null, &err) != 0;
    return if (ok) null else errorText(err, err_buf);
}

/// A GError's message copied into `buf` (the error stays the caller's).
pub fn errorText(err: [*c]c.GError, buf: []u8) []const u8 {
    const why: []const u8 = if (err != null and err.*.message != null)
        std.mem.span(@as([*:0]const u8, @ptrCast(err.*.message)))
    else
        "the application did not start";
    const n = @min(why.len, buf.len);
    @memcpy(buf[0..n], why[0..n]);
    return buf[0..n];
}

fn launchUri(app: *c.GAppInfo, uri: [*c]c.gchar, err: [*c][*c]c.GError) bool {
    var list: ?*c.GList = null;
    list = c.g_list_append(list, @ptrCast(uri));
    defer c.g_list_free(list);
    return c.g_app_info_launch_uris(app, list, null, err) != 0;
}

/// A GAppInfo for a custom command line (G_APP_INFO_CREATE_NONE); the
/// caller owns the ref.
pub fn commandAppInfo(cmdline: []const u8, err: [*c][*c]c.GError) ?*c.GAppInfo {
    var z: [4096:0]u8 = undefined;
    const cz = std.fmt.bufPrintSentinel(&z, "{s}", .{cmdline}, 0) catch return null;
    return c.g_app_info_create_from_commandline(cz.ptr, null, c.G_APP_INFO_CREATE_NONE, err);
}

/// The installed application with desktop id `appid`; the caller owns the ref.
pub fn appInfoById(appid: []const u8) ?*c.GAppInfo {
    const apps = c.g_app_info_get_all();
    defer if (apps != null) c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
    var it = apps;
    while (it != null) : (it = it.*.next) {
        const app: *c.GAppInfo = @ptrCast(@alignCast(it.*.data orelse continue));
        const id = c.g_app_info_get_id(app) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(id), appid)) continue;
        _ = c.g_object_ref(app);
        return app;
    }
    return null;
}

pub fn filenameUri(path: []const u8) ?[*c]c.gchar {
    var path_buf: [4096:0]u8 = undefined;
    const path_z = std.fmt.bufPrintSentinel(&path_buf, "{s}", .{path}, 0) catch return null;
    const uri = c.g_filename_to_uri(path_z.ptr, null, null);
    return if (uri == null) null else uri;
}

/// The content type GIO guesses from a file NAME alone; caller frees with g_free.
pub fn guessContentType(name: []const u8) ?[*c]c.gchar {
    var namez: [512:0]u8 = undefined;
    const bz = std.fmt.bufPrintSentinel(&namez, "{s}", .{name}, 0) catch return null;
    var uncertain: c.gboolean = 0;
    const ct = c.g_content_type_guess(bz.ptr, null, 0, &uncertain);
    return if (ct == null) null else ct;
}

//! Downloads, the face half: the download strip, the save dialog, the
//! automation `web-download` requests, and the helper's offer/progress
//! events. Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const clock = @import("../../util/clock.zig");
const download_policy = @import("../../web/download.zig");
const fpicker = @import("../../filebrowser/picker.zig");
const fsserve = @import("../../mux/fsserve.zig");
const proto = @import("../../web/protocol.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;
const client = host_mod.client;
const findFaceGlobal = host_mod.findFaceGlobal;
const openLocalFile = WebFace.openLocalFile;

/// One download this face is tracking, as its strip row shows it. The
/// string slices are owned by the face's allocator; the widgets belong
/// to the strip and die with the pane.
pub const Download = struct {
    /// The helper's download id (engine-minted, process-unique).
    id: u32,
    /// Automation request id (`web-download`), 0 for a download the
    /// page or the user started. Non-zero rows carry their own target
    /// path from the request and never raise a save dialog.
    req: u32 = 0,
    /// The request failed before any transfer existed (no view, the
    /// engine never offered a download). Reported as a failed row so
    /// the caller waiting on the file gets an answer.
    fail_reason: []const u8 = "",
    failure_buf: [512]u8 = undefined,
    url: []u8 = &.{},
    source_host: []u8 = &.{},
    staged: bool = false,
    downloaded: bool = false,
    retry_req: u32 = 0,
    retry_at_ms: i64 = 0,
    retry_btn: ?*c.GtkWidget = null,
    name: []u8,
    /// LOCAL path being written: the user's pick for a local save, the
    /// staging file for a redirected (host:) save.
    path: []u8,
    /// Remote destination of a redirected save; empty host = local.
    remote_host: []u8,
    remote_path: []u8,
    /// Transfer-service ledger token of the handoff upload.
    upload_token: ?[]u8 = null,
    received: u64 = 0,
    total: u64 = 0,
    state: enum { downloading, uploading, done, failed } = .downloading,
    /// The user pressed Cancel: the terminal event removes the row
    /// instead of showing a failure the user asked for.
    canceled: bool = false,

    row: *c.GtkWidget,
    label: *c.GtkWidget,
    bar: *c.GtkWidget,
    status: *c.GtkWidget,
    cancel_btn: *c.GtkWidget,
    open_btn: *c.GtkWidget,
    reveal_btn: *c.GtkWidget,

    pub fn free(self: *Download, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.path);
        a.free(self.remote_host);
        a.free(self.remote_path);
        a.free(self.url);
        a.free(self.source_host);
        if (self.upload_token) |t| a.free(t);
        a.destroy(self);
    }
};

/// How long a `web-download` request waits for the engine to offer its
/// download before the request is reported failed. The helper answers
/// sooner in the ordinary case; this is the backstop for a helper that
/// answers nothing at all.
pub const ASKED_DOWNLOAD_WAIT_MS: i64 = 30_000;

/// One `web-download` request waiting for its engine offer. The path
/// is the caller's and travels with the request, so the offer is
/// answered straight away — an automation download must not sit behind
/// a save dialog nobody is looking at.
pub const AskedDownload = struct {
    req: u32,
    /// Absolute target path; owned.
    path: []u8,
    url: []u8,
    /// When the request was sent, so one the engine never offers is
    /// answered rather than left pending forever.
    at_ms: i64,
};

/// User-data for a download row's buttons, resolved through the client
/// registry at click time (the PrintCtx liveness fence) and then by
/// MEMBERSHIP of the face's download list — never by engine id, which
/// is 0 for every request that failed before a transfer existed, so
/// two such rows would answer each other's Dismiss.
/// Owned by the button via `cast.destroyCtx` (mechanism 1).
pub const DlBtnCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    dl: *Download,
};

/// User-data for a download's save dialog; the dialog outlives a pane
/// close by construction, so this carries ids, never the face.
pub const DlPickCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    id: u32,
    /// Suggested name (owned), the fallback when a pick has no leaf.
    name: []u8,
    url: []u8,

    pub fn free(self: *DlPickCtx) void {
        self.allocator.free(self.name);
        self.allocator.free(self.url);
        self.allocator.destroy(self);
    }
};

// ---- downloads --------------------------------------------------
//
// The helper HOLDS every download's target decision until the face
// answers (`ev_download_offer` / `download_decide`). A local pick
// downloads straight to it; a `host:` pick (the picker browses
// remote hosts natively) downloads to a LOCAL staging file first
// and then hands off to the daemon's durable transfer path — v1
// deliberately routes origin -> local -> server, never
// fetch-on-server.

/// Ask the helper to download `url` through THIS view's browser
/// (its cookies, its session, its route) into `path`. Returns the
/// request id `webDownloadList` reports on, or null when the
/// helper cannot serve it — never a request that can never answer.
///
/// The row appears in the pane's download strip like any other, so
/// the user can see (and cancel) what an assistant is fetching.
pub fn webDownloadStart(self: *WebFace, url: []const u8, path: []const u8) ?u32 {
    if (self.widgets_dead) return null;
    if (!self.cl.has(.downloads) or !self.cl.has(.download_start)) return null;
    if (self.cl.isRemote() and !self.cl.has(.download_staging)) return null;
    // A watched page is another client's view: the helper drops
    // `download_start` for an alias at its edge (`observerAllows`)
    // with no reply, so the request would sit `pending` until the
    // sweep failed it with a reason naming the wrong cause.
    if (self.cl.observer) return null;
    if (path.len == 0 or path[0] != '/') return null;
    const owned = self.allocator.dupe(u8, path) catch return null;
    const owned_url = self.allocator.dupe(u8, url) catch {
        self.allocator.free(owned);
        return null;
    };
    const req = self.dl_next_req;
    self.dl_next_req +%= 1;
    if (self.dl_next_req == 0) self.dl_next_req = 1;
    self.dl_asked.append(self.allocator, .{
        .req = req,
        .path = owned,
        .url = owned_url,
        .at_ms = clock.nowMs(),
    }) catch {
        self.allocator.free(owned);
        self.allocator.free(owned_url);
        return null;
    };
    self.cl.post(proto.DownloadStart{ .view = self.view, .req = req, .url = url });
    return req;
}

/// Whether a remote-browser container is what refused a download
/// request, so the caller can say WHY rather than "unavailable".
pub fn webDownloadRefusal(self: *WebFace) []const u8 {
    if (self.cl.isRemote() and !self.cl.has(.download_staging)) return "update the remote browser helper to support download delivery";
    if (self.cl.observer) return "this pane watches another client's page; downloads belong to the page's owner";
    if (!self.cl.has(.downloads)) return "this browser helper does not report downloads";
    if (!self.cl.has(.download_start)) return "this browser helper cannot start a download for a url (capability 'download-start')";
    return "the web view cannot take a download request now";
}

/// One tracked download's state, for the control socket.
pub const DownloadInfo = struct {
    req: u32,
    id: u32,
    name: []const u8,
    path: []const u8,
    received: u64,
    total: u64,
    state: []const u8,
    reason: []const u8,
};

/// Every download this face is tracking, plus the requests still
/// waiting for their offer (reported as `pending`, so a caller
/// polling one never sees it vanish between calls).
pub fn webDownloadList(self: *WebFace, arena: std.mem.Allocator) []const DownloadInfo {
    // Polling IS the sweep: a request the engine never offered
    // becomes a failed row here rather than staying `pending`
    // forever for a caller that keeps asking.
    self.expireAsked();
    var out: std.ArrayList(DownloadInfo) = .empty;
    for (self.downloads.items) |d| {
        out.append(arena, .{
            .req = d.req,
            .id = d.id,
            .name = d.name,
            .path = if (d.staged) d.remote_path else d.path,
            .received = d.received,
            .total = d.total,
            .state = switch (d.state) {
                .downloading => "running",
                .uploading => "sending",
                .done => "done",
                .failed => "failed",
            },
            .reason = d.fail_reason,
        }) catch break;
    }
    for (self.dl_asked.items) |a| {
        out.append(arena, .{
            .req = a.req,
            .id = 0,
            .name = "",
            .path = a.path,
            .received = 0,
            .total = 0,
            .state = "pending",
            .reason = "",
        }) catch break;
    }
    return out.items;
}

/// Cancel one tracked download by request id.
pub fn webDownloadCancel(self: *WebFace, req: u32) bool {
    for (self.downloads.items) |d| {
        if (d.req != req or d.req == 0) continue;
        if (d.state == .downloading) {
            d.canceled = true;
            self.cl.post(proto.DownloadCancel{ .view = self.view, .id = d.id });
            return true;
        }
        return false;
    }
    // Not offered yet: keep a failed record, so the offer that may
    // still arrive for this request is DECLINED (`onDownloadOffer`)
    // instead of falling through to a save dialog for a download
    // the caller already gave up on.
    if (self.takeAsked(req)) |asked| {
        defer self.allocator.free(asked.path);
        defer self.allocator.free(asked.url);
        self.recordFailedRequest(req, asked.path, asked.url, "canceled before the browser offered the download");
        return true;
    }
    return false;
}

/// A request already answered as failed (canceled, or expired by
/// the sweep) whose offer arrives late anyway.
pub fn failedRequest(self: *WebFace, req: u32) bool {
    if (req == 0) return false;
    for (self.downloads.items) |d| {
        if (d.req == req and d.id == 0 and d.state == .failed) return true;
    }
    return false;
}

pub fn takeAsked(self: *WebFace, req: u32) ?AskedDownload {
    for (self.dl_asked.items, 0..) |a, i| {
        if (a.req != req) continue;
        return self.dl_asked.orderedRemove(i);
    }
    return null;
}

/// Fail every asked-for download the helper never offered: the
/// engine answers a url it will not download with silence, and a
/// caller must not wait on silence.
pub fn expireAsked(self: *WebFace) void {
    const now = clock.nowMs();
    var i: usize = 0;
    while (i < self.dl_asked.items.len) {
        if (now - self.dl_asked.items[i].at_ms < ASKED_DOWNLOAD_WAIT_MS) {
            i += 1;
            continue;
        }
        const a = self.dl_asked.orderedRemove(i);
        defer self.allocator.free(a.path);
        defer self.allocator.free(a.url);
        self.recordFailedRequest(a.req, a.path, a.url, "the browser did not start a download for that url (it may have navigated to it, or refused the scheme)");
    }
}

/// A download request that produced no transfer at all, kept as a
/// failed row so the answer is a fact rather than a timeout.
pub fn recordFailedRequest(self: *WebFace, req: u32, path: []const u8, url: []const u8, reason: []const u8) void {
    const d = self.allocator.create(Download) catch return;
    d.* = .{
        .id = 0,
        .req = req,
        .fail_reason = reason,
        .url = self.allocator.dupe(u8, url) catch &.{},
        .source_host = self.allocator.dupe(u8, self.cl.hostSlice()) catch &.{},
        .staged = self.cl.isRemote(),
        .name = self.allocator.dupe(u8, std.fs.path.basename(path)) catch &.{},
        .path = self.allocator.dupe(u8, path) catch &.{},
        .remote_host = &.{},
        .remote_path = if (self.cl.isRemote()) self.allocator.dupe(u8, path) catch &.{} else &.{},
        .state = .failed,
        .row = undefined,
        .label = undefined,
        .bar = undefined,
        .status = undefined,
        .cancel_btn = undefined,
        .open_btn = undefined,
        .reveal_btn = undefined,
    };
    if (d.source_host.len != self.cl.hostSlice().len or (d.staged and d.remote_path.len == 0)) {
        d.free(self.allocator);
        return;
    }
    self.downloads.append(self.allocator, d) catch {
        d.free(self.allocator);
        return;
    };
    self.buildDlRow(d);
}

pub fn findDownload(self: *WebFace, id: u32) ?*Download {
    for (self.downloads.items) |d| {
        if (d.id == id) return d;
    }
    return null;
}

/// Static — callable from contexts whose face may be gone; the
/// decision goes to whichever client owns the view (a held decision
/// must always be answered).
pub fn declineDownload(view: u32, id: u32) void {
    const cl = if (findFaceGlobal(view)) |f| f.cl else client();
    cl.post(proto.DownloadDecide{ .view = view, .id = id, .path = "" });
}

pub fn onDownloadOffer(self: *WebFace, ev: proto.EvDownloadOffer) void {
    if (self.widgets_dead) {
        declineDownload(ev.view, ev.id);
        return;
    }
    // A remote helper would write the picked path on ITS host, not
    // here — silently dropping files on the wrong machine. Decline
    // with a visible reason until the remote download path (helper
    // staging dir -> daemon file_get -> local pick) is designed;
    // this branch is the seam it plugs into.
    if (self.cl.isRemote() and !self.cl.has(.download_staging)) {
        declineDownload(ev.view, ev.id);
        self.toast("Update the remote browser helper to save downloads on this or another machine.");
        return;
    }
    for (self.downloads.items) |d| {
        if (ev.req == 0 or d.retry_req != ev.req) continue;
        d.retry_req = 0;
        if (d.canceled or d.state != .downloading) {
            declineDownload(ev.view, ev.id);
            return;
        }
        d.id = ev.id;
        self.cl.post(proto.DownloadDecide{ .view = self.view, .id = d.id, .path = d.path, .stage = @intFromBool(d.source_host.len != 0) });
        return;
    }
    const name = if (ev.name.len != 0) ev.name else "download";
    // An automation request named its own path: answer it with
    // that, dialog policy or not. The caller is waiting on a file
    // at a path it chose, and there is nobody at a save dialog.
    if (ev.req != 0) {
        if (self.takeAsked(ev.req)) |asked| {
            defer self.allocator.free(asked.path);
            defer self.allocator.free(asked.url);
            self.startDownloadReq(ev.id, ev.req, name, asked.path, "", "", ev.url);
            return;
        }
        // The caller was already told this request failed (it
        // canceled, or the offer outlived the wait): a late offer
        // is answered with a decline, never with a dialog nobody
        // asked for.
        declineDownload(ev.view, ev.id);
        return;
    }
    if (!host_mod.g_download_ask) {
        self.autoAcceptDownload(ev.id, name, ev.url);
        return;
    }
    const pickwin = @import("../picker.zig");
    const ctx = self.allocator.create(DlPickCtx) catch {
        declineDownload(ev.view, ev.id);
        return;
    };
    const owned_url = self.allocator.dupe(u8, ev.url) catch {
        self.allocator.destroy(ctx);
        declineDownload(ev.view, ev.id);
        return;
    };
    ctx.* = .{
        .allocator = self.allocator,
        .view = self.view,
        .id = ev.id,
        .url = owned_url,
        .name = self.allocator.dupe(u8, name) catch {
            self.allocator.free(owned_url);
            self.allocator.destroy(ctx);
            declineDownload(ev.view, ev.id);
            return;
        },
    };
    const win = self.ownerWindow();
    const gwin: ?*c.GtkWindow = if (win) |w| @ptrCast(w.app_window) else null;
    _ = pickwin.PickerWindow.open(self.allocator, gwin, .{
        .mode = .save_file,
        .title = "Save Download",
        .suggested_name = name,
        // Per-window memory: start where this window last saved.
        .initial_spec = if (win) |w| w.web_download_dir else null,
    }, &onDlPathPicked, @ptrCast(ctx)) catch {
        ctx.free();
        declineDownload(ev.view, ev.id);
        self.toast("Could not open the save dialog.");
    };
}

/// `web_download_ask = false`: straight into ~/Downloads under the
/// suggested name, uniquified rather than overwritten.
pub fn autoAcceptDownload(self: *WebFace, id: u32, name: []const u8, url: []const u8) void {
    const home_c = c.getenv("HOME") orelse {
        declineDownload(self.view, id);
        return;
    };
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_c)));
    var cfg_buf: [4096]u8 = undefined;
    const config_home: []const u8 = blk: {
        if (c.getenv("XDG_CONFIG_HOME")) |x| {
            const s2 = std.mem.span(@as([*:0]const u8, @ptrCast(x)));
            if (s2.len != 0) break :blk s2;
        }
        break :blk std.fmt.bufPrint(&cfg_buf, "{s}/.config", .{home}) catch {
            declineDownload(self.view, id);
            return;
        };
    };
    // The user's XDG download directory, NOT a hard-coded
    // `$HOME/Downloads`: a machine whose user-dirs.dirs says
    // `$HOME/downloads` had its auto-accepted downloads written to
    // a directory it does not otherwise use, which reads exactly
    // like the download never happening.
    var dir_stack: [4096]u8 = undefined;
    const dir = fsserve.downloadDir(home, config_home, &dir_stack);
    if (dir.len == 0) {
        declineDownload(self.view, id);
        return;
    }
    var dir_z: [4096:0]u8 = undefined;
    if (std.fmt.bufPrintZ(&dir_z, "{s}", .{dir})) |z| {
        _ = c.mkdir(z.ptr, 0o755);
    } else |_| {
        declineDownload(self.view, id);
        return;
    }
    var path_buf: [4608]u8 = undefined;
    // The suggestion is page-controlled: joining it to `dir` with a
    // separator still in it would let a page pick the destination.
    const leaf = download_policy.safeName(name);
    const path = uniquePath(&path_buf, dir, leaf) orelse {
        declineDownload(self.view, id);
        return;
    };
    self.startDownload(id, leaf, path, "", "", url);
}

pub fn onDlPathPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx: *DlPickCtx = @ptrCast(@alignCast(user.?));
    defer ctx.free();
    const res = result orelse {
        declineDownload(ctx.view, ctx.id);
        return;
    };
    if (res.specs.len == 0) {
        declineDownload(ctx.view, ctx.id);
        return;
    }
    // The face may have died while the dialog was up; the held
    // decision still has to be answered (the client is immortal).
    const self = findFaceGlobal(ctx.view) orelse {
        declineDownload(ctx.view, ctx.id);
        return;
    };
    const spec = res.specs[0];
    self.rememberDownloadDir(spec);
    const loc = @import("../../filebrowser/paths.zig").parseSpec(spec);
    const leaf = std.fs.path.basename(loc.path);
    const name = if (leaf.len != 0) leaf else ctx.name;
    if (self.cl.isRemote()) {
        self.startDownload(ctx.id, name, loc.path, loc.host orelse "", loc.path, ctx.url);
        return;
    }
    if (loc.host) |host| {
        // Remote target: stage locally, hand off on completion.
        var stage_buf: [4608]u8 = undefined;
        const staging = self.stagingPath(&stage_buf, ctx.id, name) orelse {
            declineDownload(ctx.view, ctx.id);
            self.toast("No writable cache directory to stage the download in.");
            return;
        };
        self.startDownload(ctx.id, name, staging, host, loc.path, ctx.url);
        return;
    }
    self.startDownload(ctx.id, name, loc.path, "", "", ctx.url);
}

/// A private file in `$XDG_CACHE_HOME/sketerm/webdl`: where a
/// redirected download lands before its daemon handoff. The daemon
/// consumes it only after delivery succeeds, retaining failed sends.
pub fn stagingPath(self: *WebFace, buf: []u8, id: u32, name: []const u8) ?[]const u8 {
    _ = self;
    _ = name;
    var root_buf: [4096]u8 = undefined;
    const cache: []const u8 = blk: {
        if (c.getenv("XDG_CACHE_HOME")) |x| {
            const s = std.mem.span(@as([*:0]const u8, @ptrCast(x)));
            if (s.len != 0) break :blk s;
        }
        const home = c.getenv("HOME") orelse return null;
        break :blk std.fmt.bufPrint(&root_buf, "{s}/.cache", .{std.mem.span(@as([*:0]const u8, @ptrCast(home)))}) catch return null;
    };
    var z: [4096:0]u8 = undefined;
    const d1 = std.fmt.bufPrintZ(&z, "{s}/sketerm", .{cache}) catch return null;
    _ = c.mkdir(d1.ptr, 0o700);
    const d2 = std.fmt.bufPrintZ(&z, "{s}/sketerm/webdl", .{cache}) catch return null;
    _ = c.mkdir(d2.ptr, 0o700);
    const path = std.fmt.bufPrintZ(buf, "{s}/sketerm/webdl/{d}-XXXXXX", .{ cache, id }) catch return null;
    const fd = c.mkstemp(path.ptr);
    if (fd < 0) return null;
    _ = c.close(fd);
    return path;
}

pub fn rememberDownloadDir(self: *WebFace, spec: []const u8) void {
    const win = self.ownerWindow() orelse return;
    const slash = std.mem.lastIndexOfScalar(u8, spec, '/') orelse return;
    if (slash == 0) return;
    const dir = spec[0..slash];
    const owned = win.allocator.dupe(u8, dir) catch return;
    if (win.web_download_dir) |old| win.allocator.free(old);
    win.web_download_dir = owned;
}

/// Create the tracking entry + strip row and answer the held offer
/// with `path`.
pub fn startDownload(self: *WebFace, id: u32, name: []const u8, path: []const u8, remote_host: []const u8, remote_path: []const u8, url: []const u8) void {
    self.startDownloadReq(id, 0, name, path, remote_host, remote_path, url);
}

/// `startDownload`, carrying the automation request id that asked
/// for it (0 = page- or user-initiated).
pub fn startDownloadReq(self: *WebFace, id: u32, req: u32, name: []const u8, path: []const u8, remote_host: []const u8, remote_path: []const u8, url: []const u8) void {
    if (self.findDownload(id) != null) return;
    const d = self.allocator.create(Download) catch {
        declineDownload(self.view, id);
        return;
    };
    d.* = .{
        .id = id,
        .req = req,
        .name = self.allocator.dupe(u8, name) catch &.{},
        .path = self.allocator.dupe(u8, path) catch &.{},
        .remote_host = self.allocator.dupe(u8, remote_host) catch &.{},
        .remote_path = self.allocator.dupe(u8, if (self.cl.isRemote() and remote_host.len == 0) path else remote_path) catch &.{},
        .source_host = self.allocator.dupe(u8, self.cl.hostSlice()) catch &.{},
        .staged = self.cl.isRemote() or remote_host.len != 0,
        .url = self.allocator.dupe(u8, url) catch &.{},
        .row = undefined,
        .label = undefined,
        .bar = undefined,
        .status = undefined,
        .cancel_btn = undefined,
        .open_btn = undefined,
        .reveal_btn = undefined,
    };
    if (d.path.len == 0 or (d.staged and d.remote_path.len == 0) or d.source_host.len != self.cl.hostSlice().len or d.remote_host.len != remote_host.len) {
        d.free(self.allocator);
        declineDownload(self.view, id);
        return;
    }
    self.downloads.append(self.allocator, d) catch {
        d.free(self.allocator);
        declineDownload(self.view, id);
        return;
    };
    self.buildDlRow(d);
    self.cl.post(proto.DownloadDecide{ .view = self.view, .id = id, .path = d.path, .stage = @intFromBool(self.cl.isRemote()) });
}

pub fn buildDlRow(self: *WebFace, d: *Download) void {
    if (self.widgets_dead) return;
    d.row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 8);
    c.gtk_widget_add_css_class(d.row, "sketerm-web-dlrow");

    var name_z: [512:0]u8 = undefined;
    d.label = c.gtk_label_new(std.fmt.bufPrintZ(&name_z, "{s}", .{d.name}) catch "download");
    c.gtk_label_set_ellipsize(@ptrCast(d.label), c.PANGO_ELLIPSIZE_MIDDLE);
    c.gtk_label_set_max_width_chars(@ptrCast(d.label), 28);
    c.gtk_label_set_xalign(@ptrCast(d.label), 0);
    c.gtk_box_append(@ptrCast(d.row), d.label);

    d.bar = c.gtk_progress_bar_new();
    c.gtk_widget_set_hexpand(d.bar, 1);
    c.gtk_widget_set_valign(d.bar, c.GTK_ALIGN_CENTER);
    c.gtk_box_append(@ptrCast(d.row), d.bar);

    d.status = c.gtk_label_new("");
    c.gtk_widget_add_css_class(d.status, "dim-label");
    c.gtk_box_append(@ptrCast(d.row), d.status);

    d.open_btn = self.dlButton(d, "document-open-symbolic", "Open", &onDlOpenClicked);
    c.gtk_widget_set_visible(d.open_btn, 0);
    d.reveal_btn = self.dlButton(d, "folder-open-symbolic", "Show in Files", &onDlRevealClicked);
    c.gtk_widget_set_visible(d.reveal_btn, 0);
    d.cancel_btn = self.dlButton(d, "process-stop-symbolic", "Cancel", &onDlCancelClicked);
    d.retry_btn = self.dlButton(d, "view-refresh-symbolic", "Retry download from the beginning", &onDlRetryClicked);

    c.gtk_box_append(@ptrCast(self.dl_strip), d.row);
    c.gtk_widget_set_visible(self.dl_strip, 1);
    self.updateDlRow(d);
}

/// A flat row button whose user-data is a `DlBtnCtx` OWNED BY THE
/// BUTTON (mechanism 1) — never the face, which the row can
/// outlive a callback dispatch of.
pub fn dlButton(self: *WebFace, d: *Download, icon: [*:0]const u8, tip: [*:0]const u8, cb: *const fn (?*c.GtkButton, ?*anyopaque) callconv(.c) void) *c.GtkWidget {
    const btn = c.gtk_button_new_from_icon_name(icon).?;
    c.gtk_widget_add_css_class(btn, "flat");
    c.gtk_widget_set_tooltip_text(btn, tip);
    if (self.allocator.create(DlBtnCtx) catch null) |ctx| {
        ctx.* = .{ .allocator = self.allocator, .view = self.view, .dl = d };
        _ = c.g_signal_connect_data(
            @ptrCast(btn),
            "clicked",
            @ptrCast(cb),
            @ptrCast(ctx),
            @ptrCast(cast.destroyCtx(DlBtnCtx)),
            0,
        );
    }
    c.gtk_box_append(@ptrCast(d.row), btn);
    return btn;
}

pub fn updateDlRow(self: *WebFace, d: *Download) void {
    if (self.widgets_dead) return;
    if (d.retry_btn) |button| {
        c.gtk_widget_set_visible(button, @intFromBool(d.state == .failed and download_policy.retryAction(d.downloaded, d.url.len != 0, self.cl.has(.download_start)) != .unavailable));
        c.gtk_widget_set_tooltip_text(button, if (d.downloaded) "Retry delivery of the completed download" else "Retry download from the beginning");
    }
    c.gtk_widget_set_visible(d.open_btn, @intFromBool(d.state == .done and d.remote_host.len == 0));
    c.gtk_widget_set_visible(d.reveal_btn, @intFromBool(d.state == .done));
    if (d.state == .downloading or d.state == .uploading) {
        c.gtk_button_set_icon_name(@ptrCast(d.cancel_btn), "process-stop-symbolic");
        c.gtk_widget_set_tooltip_text(d.cancel_btn, "Cancel");
    }
    var destination: [4700:0]u8 = undefined;
    const dest = std.fmt.bufPrintZ(&destination, "Save to {s}:{s}", .{
        if (d.remote_host.len == 0) "This computer" else d.remote_host,
        if (d.staged) d.remote_path else d.path,
    }) catch "Download destination";
    c.gtk_widget_set_tooltip_text(d.label, dest.ptr);
    const format = @import("../../filebrowser/format.zig");
    var size_buf: [48:0]u8 = undefined;
    var text: [128:0]u8 = undefined;
    switch (d.state) {
        .downloading => {
            if (d.total > 0) {
                c.gtk_progress_bar_set_fraction(@ptrCast(d.bar), @as(f64, @floatFromInt(d.received)) / @as(f64, @floatFromInt(d.total)));
            } else {
                c.gtk_progress_bar_pulse(@ptrCast(d.bar));
            }
            const t = std.fmt.bufPrintZ(&text, "{s}", .{format.fmtSize(&size_buf, d.received)}) catch "";
            c.gtk_label_set_text(@ptrCast(d.status), t.ptr);
        },
        .uploading => {
            var host_z: [128:0]u8 = undefined;
            const t = std.fmt.bufPrintZ(&text, "Sending to {s}…", .{
                std.fmt.bufPrintZ(&host_z, "{s}", .{if (d.remote_host.len == 0) "this computer" else d.remote_host}) catch "host",
            }) catch "Sending…";
            c.gtk_label_set_text(@ptrCast(d.status), t.ptr);
            if (d.total > 0) c.gtk_progress_bar_set_fraction(@ptrCast(d.bar), @as(f64, @floatFromInt(d.received)) / @as(f64, @floatFromInt(d.total)));
        },
        .done => {
            c.gtk_progress_bar_set_fraction(@ptrCast(d.bar), 1.0);
            const t = if (d.remote_host.len != 0)
                std.fmt.bufPrintZ(&text, "Sent to {s}", .{d.remote_host}) catch "Sent"
            else
                std.fmt.bufPrintZ(&text, "Saved — {s}", .{format.fmtSize(&size_buf, d.received)}) catch "Saved";
            c.gtk_label_set_text(@ptrCast(d.status), t.ptr);
            // Open only makes sense for a file on THIS machine.
            c.gtk_widget_set_visible(d.open_btn, if (d.remote_host.len == 0) 1 else 0);
            c.gtk_widget_set_visible(d.reveal_btn, 1);
            c.gtk_button_set_icon_name(@ptrCast(d.cancel_btn), "window-close-symbolic");
            c.gtk_widget_set_tooltip_text(d.cancel_btn, "Dismiss");
        },
        .failed => {
            var fail_z: [160:0]u8 = undefined;
            const failed_text: [*:0]const u8 = if (d.fail_reason.len != 0) blk: {
                const t = std.fmt.bufPrintZ(&fail_z, "Failed: {s}", .{
                    d.fail_reason[0..@min(d.fail_reason.len, 140)],
                }) catch break :blk "Failed";
                break :blk t.ptr;
            } else "Download interrupted. Retry to start again.";
            c.gtk_label_set_text(@ptrCast(d.status), failed_text);
            if (self.allocator.dupeZ(u8, d.fail_reason)) |why| {
                defer self.allocator.free(why);
                c.gtk_widget_set_tooltip_text(d.status, why);
            } else |_| {}
            c.gtk_button_set_icon_name(@ptrCast(d.cancel_btn), "window-close-symbolic");
            c.gtk_widget_set_tooltip_text(d.cancel_btn, "Dismiss");
        },
    }
}

pub fn onDownloadProgress(self: *WebFace, ev: proto.EvDownloadProgress) void {
    // id 0 = the helper refused a `download_start` outright: there
    // is no transfer to update, only a request to answer.
    if (ev.id == 0) {
        if (ev.req == 0) return;
        for (self.downloads.items) |d| {
            if (d.retry_req == ev.req) {
                d.retry_req = 0;
                self.failDownload(d, "The browser could not restart this download. Open the page and try its download link again.");
                return;
            }
        }
        const asked = self.takeAsked(ev.req) orelse return;
        defer self.allocator.free(asked.path);
        defer self.allocator.free(asked.url);
        self.recordFailedRequest(ev.req, asked.path, asked.url, "the browser did not start a download for that url (it may have navigated to it, or refused the scheme)");
        return;
    }
    const d = self.findDownload(ev.id) orelse return;
    if (d.source_host.len != 0 and ev.path.len != 0 and !std.mem.eql(u8, d.path, ev.path)) {
        const owned = self.allocator.dupe(u8, ev.path) catch {
            self.cl.post(proto.DownloadCancel{ .view = self.view, .id = d.id });
            self.failDownload(d, "Could not remember the remote download location.");
            return;
        };
        self.allocator.free(d.path);
        d.path = owned;
    }
    d.received = ev.received;
    if (ev.total > 0) d.total = ev.total;
    if (ev.failed != 0) {
        if (d.canceled) {
            self.removeDownload(d);
            return;
        }
        self.failDownload(d, download_policy.failureReason(ev.interrupt_reason));
        return;
    }
    if (ev.done != 0) {
        if (d.canceled) {
            self.dropStaging(d);
            self.removeDownload(d);
            return;
        }
        if (d.source_host.len != 0 and ev.path.len == 0) {
            self.failDownload(d, "The remote helper did not report the saved file's location.");
            return;
        }
        d.downloaded = true;
        if (d.staged) {
            self.beginHandoff(d);
        } else {
            d.state = .done;
            self.updateDlRow(d);
        }
        return;
    }
    self.updateDlRow(d);
}

/// The downloaded staging file becomes a durable daemon transfer to
/// the picked host — the file browser's own machinery, so a GUI
/// crash mid-send resumes like any other transfer.
pub fn beginHandoff(self: *WebFace, d: *Download) void {
    const win = self.ownerWindow() orelse {
        self.failDownload(d, "The download is complete, but its destination window is unavailable.");
        return;
    };
    const svc = win.transferService() orelse {
        self.failDownload(d, "The download is complete. Retry delivery when the transfer service is available.");
        return;
    };
    if (d.upload_token) |token| {
        svc.retryMediated(token);
    } else {
        d.upload_token = svc.submitDelivery(self.allocator, d.source_host, d.path, d.remote_host, d.remote_path, true, null);
    }
    if (d.upload_token == null) {
        self.failDownload(d, "The download is complete, but delivery could not be recorded. Retry will send the saved copy.");
        return;
    }
    // Second phase: the bar restarts for the upload leg.
    d.state = .uploading;
    d.fail_reason = "";
    d.canceled = false;
    d.received = 0;
    self.updateDlRow(d);
    self.ensureDlTimer();
}

pub fn ensureDlTimer(self: *WebFace) void {
    if (self.dl_timer != 0) return;
    self.dl_timer = c.g_timeout_add(500, @ptrCast(&onDlTick), self);
}

pub fn stopDlTimer(self: *WebFace) void {
    if (self.dl_timer == 0) return;
    _ = c.g_source_remove(self.dl_timer);
    self.dl_timer = 0;
}

pub fn onDlTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(WebFace, user);
    const win = self.ownerWindow();
    const svc = if (win) |w| w.transferService() else null;
    var uploading = false;
    var i: usize = 0;
    while (i < self.downloads.items.len) {
        const d = self.downloads.items[i];
        i += 1;
        if (d.retry_req != 0) {
            if (clock.nowMs() - d.retry_at_ms > ASKED_DOWNLOAD_WAIT_MS) {
                d.retry_req = 0;
                self.failDownload(d, "The browser did not restart the download. Try the page's download link again.");
            } else uploading = true;
        }
        if (d.state != .uploading) continue;
        const token = d.upload_token orelse continue;
        const service = svc orelse {
            uploading = true;
            continue;
        };
        const progress = service.intentProgress(token) orelse {
            // Gone from the ledger = finished and acknowledged.
            if (d.canceled) {
                self.dropStaging(d);
                self.removeDownload(d);
                i -|= 1;
            } else self.finishHandoff(d, true);
            continue;
        };
        switch (progress.state) {
            .done => self.finishHandoff(d, true),
            .failed => self.failDownload(d, if (progress.message.len != 0) progress.message else "Delivery failed. Retry sends the completed download again."),
            .canceled => {
                self.dropStaging(d);
                self.removeDownload(d);
                i -|= 1;
            },
            else => {
                d.received = progress.done;
                if (progress.total > 0) d.total = progress.total;
                self.updateDlRow(d);
                uploading = true;
            },
        }
    }
    if (!uploading) {
        self.dl_timer = 0;
        return 0;
    }
    return 1;
}

pub fn finishHandoff(self: *WebFace, d: *Download, ok: bool) void {
    if (ok) self.dropStaging(d);
    d.state = if (ok) .done else .failed;
    if (ok and d.total > 0) d.received = d.total;
    self.updateDlRow(d);
}

/// Unlink the local staging copy of a redirected download.
pub fn dropStaging(self: *WebFace, d: *Download) void {
    _ = self;
    if (!d.staged or d.source_host.len != 0) return;
    var z: [4608:0]u8 = undefined;
    if (d.path.len + 1 > z.len) return;
    @memcpy(z[0..d.path.len], d.path);
    z[d.path.len] = 0;
    _ = c.unlink(&z);
}

pub fn removeDownload(self: *WebFace, d: *Download) void {
    if (!d.downloaded and d.state != .downloading) self.dropStaging(d);
    for (self.downloads.items, 0..) |it, idx| {
        if (it != d) continue;
        _ = self.downloads.orderedRemove(idx);
        break;
    }
    if (!self.widgets_dead) {
        c.gtk_box_remove(@ptrCast(self.dl_strip), d.row);
        if (self.downloads.items.len == 0) c.gtk_widget_set_visible(self.dl_strip, 0);
    }
    d.free(self.allocator);
}

/// The row a button belongs to, if the face still tracks it.
pub fn rowDownload(self: *WebFace, d: *Download) ?*Download {
    for (self.downloads.items) |it| {
        if (it == d) return it;
    }
    return null;
}

/// The row's cancel/dismiss button by request id, for the control
/// socket (`web-download-dismiss`): the same act as the click, so a
/// rig can drive the strip without a pointer.
pub fn webDownloadDismiss(self: *WebFace, req: u32) bool {
    if (req == 0) return false;
    for (self.downloads.items) |d| {
        if (d.req != req) continue;
        self.actOnRow(d);
        return true;
    }
    return false;
}

pub fn onDlCancelClicked(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(DlBtnCtx, user);
    const self = findFaceGlobal(ctx.view) orelse return;
    const d = self.rowDownload(ctx.dl) orelse return;
    self.actOnRow(d);
}

pub fn failDownload(self: *WebFace, d: *Download, reason: []const u8) void {
    var n = @min(reason.len, d.failure_buf.len);
    while (n < reason.len and n > 0 and reason[n] & 0xc0 == 0x80) n -= 1;
    @memcpy(d.failure_buf[0..n], reason[0..n]);
    d.fail_reason = d.failure_buf[0..n];
    d.state = .failed;
    self.updateDlRow(d);
}

pub fn onDlRetryClicked(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(DlBtnCtx, user);
    const self = findFaceGlobal(ctx.view) orelse return;
    const d = self.rowDownload(ctx.dl) orelse return;
    if (d.state != .failed) return;
    if (d.downloaded) {
        self.beginHandoff(d);
        return;
    }
    if (!self.view_live or !self.cl.has(.download_start) or d.url.len == 0) {
        self.toast("Reload the page before retrying this download.");
        return;
    }
    d.retry_req = self.dl_next_req;
    self.dl_next_req +%= 1;
    if (self.dl_next_req == 0) self.dl_next_req = 1;
    d.retry_at_ms = clock.nowMs();
    d.received = 0;
    d.total = 0;
    d.canceled = false;
    d.fail_reason = "";
    d.state = .downloading;
    self.cl.post(proto.DownloadStart{ .view = self.view, .req = d.retry_req, .url = d.url });
    self.updateDlRow(d);
    self.ensureDlTimer();
}

/// What the row's one button does: cancel a running transfer,
/// dismiss a finished one.
pub fn actOnRow(self: *WebFace, d: *Download) void {
    switch (d.state) {
        .downloading => {
            d.canceled = true;
            if (d.retry_req != 0) {
                self.removeDownload(d);
                return;
            }
            self.cl.post(proto.DownloadCancel{ .view = self.view, .id = d.id });
        },
        .uploading => {
            d.canceled = true;
            if (d.upload_token) |token| {
                if (self.ownerWindow()) |w| {
                    if (w.transferService()) |svc| _ = svc.cancel(token);
                }
            }
            // The tick sees the canceled state and removes the row.
            self.ensureDlTimer();
        },
        .done, .failed => self.removeDownload(d),
    }
}

pub fn onDlOpenClicked(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(DlBtnCtx, user);
    const self = findFaceGlobal(ctx.view) orelse return;
    const d = self.rowDownload(ctx.dl) orelse return;
    if (d.remote_host.len != 0) return;
    const path = self.allocator.dupeZ(u8, if (d.staged) d.remote_path else d.path) catch return;
    defer self.allocator.free(path);
    if (!openLocalFile(path)) self.toast("Could not open the downloaded file. Check that it still exists and an application is installed for it.");
}

pub fn onDlRevealClicked(_: ?*c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(DlBtnCtx, user);
    const self = findFaceGlobal(ctx.view) orelse return;
    const d = self.rowDownload(ctx.dl) orelse return;
    var spec: [4700]u8 = undefined;
    const s = if (d.remote_host.len != 0)
        std.fmt.bufPrint(&spec, "{s}:{s}", .{ d.remote_host, d.remote_path }) catch return
    else if (d.staged) d.remote_path else d.path;
    _ = @import("../siblingapp.zig").showInFiles(s);
}

/// Fill `buf` with `<dir>/<name>`, appending " (n)" before the
/// extension while the plain path already exists.
pub fn uniquePath(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    var z: [4608:0]u8 = undefined;
    const dot = blk: {
        const at = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk name.len;
        break :blk if (at == 0) name.len else at;
    };
    var n: u32 = 0;
    while (n < 100) : (n += 1) {
        const candidate = if (n == 0)
            std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch return null
        else
            std.fmt.bufPrint(buf, "{s}/{s} ({d}){s}", .{ dir, name[0..dot], n, name[dot..] }) catch return null;
        if (candidate.len + 1 > z.len) return null;
        @memcpy(z[0..candidate.len], candidate);
        z[candidate.len] = 0;
        if (c.access(&z, c.F_OK) != 0) return candidate;
    }
    return null;
}

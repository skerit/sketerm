//! File choosers, the face half: a page that opens a file chooser gets
//! sketerm's own file picker, and the pick is set on the page's input by
//! the helper (`src/web/cefhost/upload.zig`, capability "upload"). Split
//! out of `webface.zig`; the `WebFace` methods are free functions taking
//! `*WebFace`, re-exported from `WebFace` by name.
//!
//! The engine cannot show a chooser of its own for a windowless view (it
//! stalls the page instead), so this face asks the helper to intercept
//! its view's choosers (`upload_watch`) and answers each report
//! (`ev_upload`, `upload_unanswered`) after the fact with what the person
//! picked. An OBSERVED page (an assistant's) is its owner's to watch;
//! this GUI answers its chooser only while it holds control, since the
//! click that opened it was then the person's.
//!
//! A helper on ANOTHER host reads files on its own machine, so a pick is
//! delivered there first: the helper hands out a private tree
//! (`upload_stage`, capability "upload-staging"), the transfer service
//! copies each file into it (visible and cancellable in the transfers
//! panel like any other), and only then is the chooser answered with the
//! delivered paths. The helper removes the tree with the view.

const std = @import("std");
const c = @import("../../c.zig").c;
const fpicker = @import("../../filebrowser/picker.zig");
const fpaths = @import("../../filebrowser/paths.zig");
const proto = @import("../../web/protocol.zig");
const clock = @import("../../util/clock.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;
const findFaceGlobal = host_mod.findFaceGlobal;

var g_next_req: u32 = 0;

/// The observer bit on every request: an assistant that owns the view mints its own in the space without it.
fn nextReq() u32 {
    g_next_req +%= 1;
    return proto.upload_req_observer | (g_next_req & ~proto.upload_req_observer);
}

/// Owned by the picker's callback; the view id is the liveness fence.
const PickCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    chooser: u32,
};

/// One pick on its way to a helper on another host; owned by the face (`upload_job`).
pub const Job = struct {
    const File = struct {
        src_host: []u8,
        src_path: []u8,
        /// Where it lands on the helper's machine; empty until the tree is known.
        dst: []u8 = &.{},
        token: ?[]u8 = null,
        done: bool = false,
    };

    req: u32,
    chooser: u32,
    files: []File,
    staged: bool = false,
    asked_ms: i64 = 0,

    pub fn destroy(self: *Job, allocator: std.mem.Allocator) void {
        for (self.files) |f| {
            allocator.free(f.src_host);
            allocator.free(f.src_path);
            if (f.dst.len != 0) allocator.free(f.dst);
            if (f.token) |t| allocator.free(t);
        }
        allocator.free(self.files);
        allocator.destroy(self);
    }
};

const POLL_MS = 300;
/// How long the helper has to hand out its tree.
const STAGE_WAIT_MS: i64 = 15_000;

/// Drop the delivery in flight; called from the face's teardown choke points too.
pub fn dropUploadJob(self: *WebFace) void {
    if (self.upload_timer != 0) {
        _ = c.g_source_remove(self.upload_timer);
        self.upload_timer = 0;
    }
    if (self.upload_job) |job| job.destroy(self.allocator);
    self.upload_job = null;
}

fn failJob(self: *WebFace, why: []const u8) void {
    dropUploadJob(self);
    self.toast(why);
}

/// Have the helper intercept and report this view's file choosers. A
/// no-op until the helper's capabilities are known, and for a view this
/// face does not own.
pub fn syncUploadWatch(self: *WebFace) void {
    const cl = self.cl;
    if (self.upload_watched or self.attached or !self.view_live or !cl.hello_done or !cl.has(.upload)) return;
    cl.post(proto.UploadWatch{ .view = self.view, .enabled = 1 });
    self.upload_watched = true;
}

pub fn onUpload(self: *WebFace, ev: proto.EvUpload) void {
    if (ev.req != 0) {
        // Every client of the view sees every outcome; only the answer
        // to this face's own pick is its to report.
        if (ev.req != self.upload_req) return;
        self.upload_req = 0;
        switch (ev.outcome) {
            proto.upload_answered => {},
            proto.upload_too_many => self.toast("This upload field takes one file."),
            proto.upload_folder_input => self.toast("This upload field takes a whole folder, which this browser cannot fill. Use the page's file upload instead."),
            else => self.toast("The page did not take the file. Start the upload again."),
        }
        return;
    }
    if (ev.outcome != proto.upload_unanswered or ev.chooser == 0 or self.widgets_dead) return;
    if (self.observed and !self.obs_control) return;
    // The helper reads the files on ITS machine: a pick is delivered there first.
    const remote = self.cl.isRemote();
    if (remote and !self.cl.has(.upload_staging))
        return self.toast("This page runs in a browser on another machine. Update sketerm there to upload files into it.");
    const pickwin = @import("../picker.zig");
    const ctx = self.allocator.create(PickCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .view = self.view, .chooser = ev.chooser };
    const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
    _ = pickwin.PickerWindow.open(self.allocator, win, .{
        .mode = if (ev.multiple != 0) .open_files else .open_file,
        .title = if (ev.multiple != 0) "Upload Files" else "Upload File",
        .local_only = !remote,
    }, &onPicked, @ptrCast(ctx)) catch {
        self.allocator.destroy(ctx);
        self.toast("Could not open the file picker.");
    };
}

fn onPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx: *PickCtx = @ptrCast(@alignCast(user.?));
    defer ctx.allocator.destroy(ctx);
    const self = findFaceGlobal(ctx.view) orelse return;
    // A cancelled picker leaves the page as the interception left it: without files.
    const res = result orelse return;
    if (res.specs.len == 0) return;
    const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
    if (self.cl.isRemote()) return stagePick(self, ctx.chooser, res.specs);
    var paths: std.ArrayList(u8) = .empty;
    defer paths.deinit(ctx.allocator);
    for (res.specs) |spec| {
        const path = @import("../picker.zig").localPathOrRefuse(
            win,
            spec,
            "The page's browser reads the file on this computer; pick a local file.",
        ) orelse return;
        if (paths.items.len != 0) paths.append(ctx.allocator, 0) catch return;
        paths.appendSlice(ctx.allocator, path) catch return;
    }
    const req = nextReq();
    self.upload_req = req;
    self.cl.post(proto.UploadArm{ .view = self.view, .req = req, .paths = paths.items, .chooser = ctx.chooser });
}

/// Start delivering `specs` to the helper's machine: ask it for a tree to put them in.
fn stagePick(self: *WebFace, chooser: u32, specs: []const []const u8) void {
    // A newer chooser replaces the one an older delivery was for.
    dropUploadJob(self);
    if (specs.len > proto.upload_stage_max) return self.toast("Too many files for one upload.");
    const a = self.allocator;
    const job = a.create(Job) catch return;
    const files = a.alloc(Job.File, specs.len) catch return a.destroy(job);
    // Empty slices free as no-ops, so a half-filled job is destroyed like a full one.
    for (files) |*f| f.* = .{ .src_host = &.{}, .src_path = &.{} };
    job.* = .{ .req = nextReq(), .chooser = chooser, .files = files, .asked_ms = clock.nowMs() };
    for (specs, files) |spec, *f| {
        const loc = fpaths.parseSpec(spec);
        f.src_host = a.dupe(u8, loc.host orelse "") catch return job.destroy(a);
        f.src_path = a.dupe(u8, loc.path) catch return job.destroy(a);
    }
    self.upload_job = job;
    self.cl.post(proto.UploadStage{ .view = self.view, .req = job.req, .count = @intCast(specs.len) });
    self.upload_timer = c.g_timeout_add(POLL_MS, @ptrCast(&onJobTick), self);
}

/// The helper's tree is known: hand every file to the transfer service.
pub fn onUploadStaged(self: *WebFace, ev: proto.EvUploadStaged) void {
    const job = self.upload_job orelse return;
    if (ev.req != job.req or job.staged) return;
    if (ev.dir.len == 0) return failJob(self, "The browser on the other machine could not make room for the upload.");
    const win = self.ownerWindow() orelse return failJob(self, "The upload has no window to run in.");
    const svc = win.transferService() orelse return failJob(self, "The transfer service is unavailable; the file was not uploaded.");
    const a = self.allocator;
    for (job.files, 0..) |*f, i| {
        f.dst = std.fmt.allocPrint(a, "{s}/{d}/{s}", .{ ev.dir, i, std.fs.path.basename(f.src_path) }) catch
            return failJob(self, "Out of memory; the file was not uploaded.");
        f.token = svc.submitDelivery(a, f.src_host, f.src_path, self.cl.hostSlice(), f.dst, false, null) orelse
            return failJob(self, "The upload could not be started.");
    }
    job.staged = true;
    self.toast(if (job.files.len == 1) "Sending the file to the page's browser..." else "Sending the files to the page's browser...");
}

fn onJobTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *WebFace = @ptrCast(@alignCast(user.?));
    const job = self.upload_job orelse {
        self.upload_timer = 0;
        return 0;
    };
    if (!job.staged) {
        if (clock.nowMs() - job.asked_ms < STAGE_WAIT_MS) return 1;
        self.upload_timer = 0;
        failJob(self, "The browser on the other machine did not answer; the file was not uploaded.");
        return 0;
    }
    const svc = (if (self.ownerWindow()) |w| w.transferService() else null) orelse return 1;
    var pending = false;
    for (job.files) |*f| {
        if (f.done) continue;
        // Gone from the ledger = finished and acknowledged.
        const progress = svc.intentProgress(f.token.?) orelse {
            f.done = true;
            continue;
        };
        switch (progress.state) {
            .done => f.done = true,
            .failed, .canceled => {
                self.upload_timer = 0;
                var buf: [400]u8 = undefined;
                const why = if (progress.state == .canceled)
                    "The upload was cancelled; the page got no file."
                else if (progress.message.len != 0)
                    std.fmt.bufPrint(&buf, "The upload failed: {s}", .{progress.message}) catch "The upload failed; the page got no file."
                else
                    "The upload failed; the page got no file.";
                failJob(self, why);
                return 0;
            },
            else => pending = true,
        }
    }
    if (pending) return 1;
    // The source returning 0 removes itself: nothing below may remove it again.
    self.upload_timer = 0;
    var paths: std.ArrayList(u8) = .empty;
    defer paths.deinit(self.allocator);
    for (job.files) |f| {
        if (paths.items.len != 0) paths.append(self.allocator, 0) catch return oom(self);
        paths.appendSlice(self.allocator, f.dst) catch return oom(self);
    }
    self.upload_req = job.req;
    self.cl.post(proto.UploadArm{ .view = self.view, .req = job.req, .paths = paths.items, .chooser = job.chooser });
    dropUploadJob(self);
    return 0;
}

fn oom(self: *WebFace) c.gboolean {
    failJob(self, "Out of memory; the file was not uploaded.");
    return 0;
}

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

const std = @import("std");
const c = @import("../../c.zig").c;
const fpicker = @import("../../filebrowser/picker.zig");
const proto = @import("../../web/protocol.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;
const findFaceGlobal = host_mod.findFaceGlobal;

var g_next_req: u32 = 0;

/// Owned by the picker's callback; the view id is the liveness fence.
const PickCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
    chooser: u32,
};

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
            else => self.toast("The page did not take the file. Start the upload again."),
        }
        return;
    }
    if (ev.outcome != proto.upload_unanswered or ev.chooser == 0 or self.widgets_dead) return;
    if (self.observed and !self.obs_control) return;
    // The helper reads the files on ITS machine.
    if (self.cl.isRemote())
        return self.toast("This page runs in a browser on another machine: uploading a file from this computer into it is not supported yet.");
    const pickwin = @import("../picker.zig");
    const ctx = self.allocator.create(PickCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .view = self.view, .chooser = ev.chooser };
    const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
    _ = pickwin.PickerWindow.open(self.allocator, win, .{
        .mode = if (ev.multiple != 0) .open_files else .open_file,
        .title = if (ev.multiple != 0) "Upload Files" else "Upload File",
        .local_only = true,
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
    g_next_req +%= 1;
    // The observer bit on every request: an assistant that owns the
    // view mints its own in the space without it.
    const req = proto.upload_req_observer | (g_next_req & ~proto.upload_req_observer);
    self.upload_req = req;
    self.cl.post(proto.UploadArm{ .view = self.view, .req = req, .paths = paths.items, .chooser = ctx.chooser });
}

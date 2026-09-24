//! DevTools and print to PDF, the face half (both refuse what the tab's
//! own helper cannot do here). Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const fpicker = @import("../../filebrowser/picker.zig");
const proto = @import("../../web/protocol.zig");
const wf_dl = @import("../webface/downloads.zig");
const host_mod = @import("../webface.zig");
const Download = host_mod.Download;
const WebFace = host_mod.WebFace;
const findFaceGlobal = host_mod.findFaceGlobal;
const freeToastPath = host_mod.freeToastPath;

// ---- DevTools ---------------------------------------------------

/// Ask the helper for this page's inspector. The pane is opened by
/// the REPLY (`ev_devtools_view`), because only then is there a
/// view id to present.
/// Why DevTools cannot open for this page, or null when it can. An
/// inspector cannot inspect itself, and a REMOTE page's inspector
/// would open in a window on the remote host, where nobody sees it.
pub fn devToolsRefusal(self: *const WebFace) ?[]const u8 {
    if (self.attached or !self.view_live) return "";
    if (!self.cl.has(.devtools)) return "This browser helper is too old for DevTools.";
    if (self.cl.isRemote()) return "DevTools is not available for a page running on another host: the engine would open it in a window there.";
    return null;
}

pub fn openDevTools(self: *WebFace) void {
    if (self.devToolsRefusal()) |why| {
        if (why.len != 0) self.toast(why);
        return;
    }
    if (self.devtools_pending) return;
    self.devtools_pending = true;
    self.cl.post(proto.DevToolsShow{ .view = self.view, .x = 0, .y = 0 });
}

/// The helper's answer: split this pane and give the new one a face
/// bound to the inspector view.
pub fn onDevToolsView(self: *WebFace, dev_view: u32, reason: []const u8) void {
    self.devtools_pending = false;
    if (dev_view == 0) {
        // `windowed` is not a failure: the inspector IS open, the
        // engine just insisted on giving it a window of its own
        // (every CEF 151 build does — src/web/cefhost.zig
        // `adoptBrowser`). Saying "could not open" there would be a
        // lie about a window the user is looking at.
        if (std.mem.eql(u8, reason, "windowed")) {
            self.toast("DevTools opened in its own window (this browser engine cannot render it inside a pane).");
            return;
        }
        self.toast("The browser engine did not open DevTools for this page.");
        return;
    }
    const pane = self.pane orelse {
        self.cl.post(proto.ViewDestroy{ .view = dev_view });
        return;
    };
    const win = self.ownerWindow() orelse {
        self.cl.post(proto.ViewDestroy{ .view = dev_view });
        return;
    };
    // A view nobody presents is a browser nobody can close: every
    // failure below hands it straight back.
    win.openDevToolsSplit(pane, dev_view) catch {
        self.cl.post(proto.ViewDestroy{ .view = dev_view });
        self.toast("Could not open a pane for DevTools.");
    };
}

// ---- print to PDF -------------------------------------------------

/// User-data for the save dialog: the VIEW id, never the face
/// pointer. The dialog outlives a pane close by construction, and
/// looking the face back up in the client's registry — which a dead
/// face leaves — is the liveness fence for exactly that.
pub const PrintCtx = struct {
    allocator: std.mem.Allocator,
    view: u32,
};

/// Whether Print to PDF can put a PDF on THIS machine: a local helper
/// writes the picked path itself, a remote one prints into a staged
/// file the daemon's file service then brings here, which needs
/// `print-pdf-staging`. An attached view's page is not this tab's to
/// print (the helper refuses the frame for an observer).
pub fn canPrintPdf(self: *const WebFace) bool {
    return self.printRefusal() == null;
}

pub fn printRefusal(self: *const WebFace) ?[]const u8 {
    if (!self.view_live) return "This page is not loaded.";
    if (self.attached) return "This view presents another page and cannot be printed from here.";
    if (!self.cl.has(.print_pdf)) return "This browser helper is too old to print to PDF.";
    if (self.cl.isRemote() and !self.cl.has(.print_pdf_staging))
        return "The browser helper on the remote host is too old to send a PDF to this computer (no print-pdf-staging capability).";
    return null;
}

/// Save dialog -> `print_pdf`. The pick is always a path on THIS
/// machine: a local helper writes it itself, a remote one prints into
/// a staged file on its host and the PDF is delivered here afterwards
/// (`deliverStagedPdf`).
pub fn printToPdf(self: *WebFace) void {
    if (self.printRefusal()) |why| {
        if (self.view_live) self.toast(why);
        return;
    }
    const pickwin = @import("../picker.zig");
    const ctx = self.allocator.create(PrintCtx) catch return;
    ctx.* = .{ .allocator = self.allocator, .view = self.view };
    var name_buf: [160]u8 = undefined;
    const suggested = self.suggestedPdfName(&name_buf);
    const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
    _ = pickwin.PickerWindow.open(self.allocator, win, .{
        .mode = .save_file,
        .title = "Print to PDF",
        .suggested_name = suggested,
        .local_only = true,
    }, &onPdfPathPicked, @ptrCast(ctx)) catch {
        self.allocator.destroy(ctx);
        self.toast("Could not open the save dialog.");
    };
}

/// `<page title>.pdf`, with everything a filename should not carry
/// flattened to '-'. A page with no title saves as "page.pdf".
pub fn suggestedPdfName(self: *WebFace, buf: []u8) []const u8 {
    const title = self.title orelse return "page.pdf";
    var n: usize = 0;
    const room = @min(buf.len - 5, 80);
    for (title) |ch| {
        if (n >= room) break;
        buf[n] = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ' ', '.' => ch,
            else => '-',
        };
        n += 1;
    }
    while (n > 0 and (buf[n - 1] == ' ' or buf[n - 1] == '.' or buf[n - 1] == '-')) n -= 1;
    if (n == 0) return "page.pdf";
    @memcpy(buf[n..][0..4], ".pdf");
    return buf[0 .. n + 4];
}

pub fn onPdfPathPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx: *PrintCtx = @ptrCast(@alignCast(user.?));
    defer ctx.allocator.destroy(ctx);
    const self = findFaceGlobal(ctx.view) orelse return;
    const res = result orelse return;
    if (res.specs.len == 0) return;
    const win: ?*c.GtkWindow = if (self.ownerWindow()) |w| @ptrCast(w.app_window) else null;
    // The PDF lands on THIS machine whichever host the page lives on,
    // so a `host:/path` pick has nothing that could honour it.
    const path = @import("../picker.zig").localPathOrRefuse(
        win,
        res.specs[0],
        "Print to PDF saves on this computer; pick a local path.",
    ) orelse return;
    if (self.printRefusal()) |why| return self.toast(why);
    const remote = self.cl.isRemote();
    self.cl.post(proto.PrintPdf{
        .view = self.view,
        // Background graphics ON: a page saved without them looks
        // broken, which is not what "print this page" means here.
        .flags = proto.print_flag_background,
        .paper = @intFromEnum(proto.Paper.default),
        .path = path,
        .stage = @intFromBool(remote),
    });
    var msg: [512]u8 = undefined;
    self.toast(if (remote)
        std.fmt.bufPrint(&msg, "Printing on {s}; the PDF will be sent to {s}…", .{ self.cl.hostSlice(), path }) catch "Printing to PDF…"
    else
        std.fmt.bufPrint(&msg, "Printing to {s}…", .{path}) catch "Printing to PDF…");
}

pub fn onPrintDone(self: *WebFace, ev: proto.EvPrintPdfDone) void {
    const path = ev.path;
    var msg: [512]u8 = undefined;
    if (ev.ok == 0) {
        self.toast(std.fmt.bufPrint(&msg, "Could not write {s}", .{path}) catch "Could not write the PDF");
        return;
    }
    if (ev.staged.len != 0) return self.deliverStagedPdf(ev.staged, path);
    const win = self.ownerWindow() orelse return;
    const text = std.fmt.bufPrintZ(&msg, "Saved {s}", .{path}) catch "Saved the PDF";
    const note = c.adw_toast_new(text.ptr);
    c.adw_toast_set_timeout(note, 8);
    // The toast OWNS the path (mechanism 1): GObject frees attached
    // data at finalize, strictly after the button can be clicked,
    // so the Open handler can never read freed memory. c_allocator
    // and not the face's, because the string outlives the face.
    if (std.heap.c_allocator.dupeZ(u8, path)) |owned| {
        c.adw_toast_set_button_label(note, "Open");
        c.g_object_set_data_full(
            @ptrCast(@alignCast(note)),
            "sketerm-pdf-path",
            @ptrCast(owned.ptr),
            @ptrCast(&freeToastPath),
        );
        _ = c.g_signal_connect_data(
            @ptrCast(@alignCast(note)),
            "button-clicked",
            @ptrCast(&onToastOpen),
            @ptrCast(owned.ptr),
            null,
            0,
        );
    } else |_| {}
    c.adw_toast_overlay_add_toast(win.toast_overlay, note);
}

/// A remote helper printed into `staged` on its own host: bring that
/// file to `local_path` through the daemon's durable transfer, as a
/// row of the download strip, so progress, cancel, delivery retry
/// and Open behave exactly as they do for a downloaded file. The
/// transfer consumes the staged file once delivery is verified.
pub fn deliverStagedPdf(self: *WebFace, staged: []const u8, local_path: []const u8) void {
    const a = self.allocator;
    const d = a.create(Download) catch return self.toast("Could not record the PDF delivery.");
    d.* = .{
        .id = 0,
        .name = a.dupe(u8, std.fs.path.basename(local_path)) catch &.{},
        .path = a.dupe(u8, staged) catch &.{},
        .remote_host = &.{},
        .remote_path = a.dupe(u8, local_path) catch &.{},
        .source_host = a.dupe(u8, self.cl.hostSlice()) catch &.{},
        .staged = true,
        .downloaded = true,
        .row = undefined,
        .label = undefined,
        .bar = undefined,
        .status = undefined,
        .cancel_btn = undefined,
        .open_btn = undefined,
        .reveal_btn = undefined,
    };
    if (d.path.len == 0 or d.remote_path.len == 0 or d.source_host.len == 0) {
        d.free(a);
        return self.toast("Could not record the PDF delivery.");
    }
    self.downloads.append(a, d) catch {
        d.free(a);
        return self.toast("Could not record the PDF delivery.");
    };
    self.buildDlRow(d);
    self.beginHandoff(d);
}

/// Hand the finished PDF to whatever the desktop opens PDFs with.
pub fn onToastOpen(_: ?*c.AdwToast, user: ?*anyopaque) callconv(.c) void {
    const path: [*:0]const u8 = @ptrCast(user orelse return);
    _ = openLocalFile(path);
}

pub fn openLocalFile(path: [*:0]const u8) bool {
    const file = c.g_file_new_for_path(path) orelse return false;
    defer c.g_object_unref(file);
    const uri = c.g_file_get_uri(file) orelse return false;
    defer c.g_free(uri);
    return c.g_app_info_launch_default_for_uri(uri, null, null) != 0;
}

pub const webDownloadStart = wf_dl.webDownloadStart;
pub const webDownloadRefusal = wf_dl.webDownloadRefusal;
pub const DownloadInfo = wf_dl.DownloadInfo;
pub const webDownloadList = wf_dl.webDownloadList;
pub const webDownloadCancel = wf_dl.webDownloadCancel;
pub const takeAsked = wf_dl.takeAsked;
pub const expireAsked = wf_dl.expireAsked;
pub const recordFailedRequest = wf_dl.recordFailedRequest;
pub const findDownload = wf_dl.findDownload;
pub const onDownloadOffer = wf_dl.onDownloadOffer;
pub const autoAcceptDownload = wf_dl.autoAcceptDownload;
pub const stagingPath = wf_dl.stagingPath;
pub const rememberDownloadDir = wf_dl.rememberDownloadDir;
pub const startDownload = wf_dl.startDownload;
pub const startDownloadReq = wf_dl.startDownloadReq;
pub const buildDlRow = wf_dl.buildDlRow;
pub const dlButton = wf_dl.dlButton;
pub const updateDlRow = wf_dl.updateDlRow;
pub const onDownloadProgress = wf_dl.onDownloadProgress;
pub const beginHandoff = wf_dl.beginHandoff;
pub const ensureDlTimer = wf_dl.ensureDlTimer;
pub const stopDlTimer = wf_dl.stopDlTimer;
pub const finishHandoff = wf_dl.finishHandoff;
pub const dropStaging = wf_dl.dropStaging;
pub const removeDownload = wf_dl.removeDownload;
pub const rowDownload = wf_dl.rowDownload;
pub const webDownloadDismiss = wf_dl.webDownloadDismiss;
pub const failDownload = wf_dl.failDownload;
pub const actOnRow = wf_dl.actOnRow;

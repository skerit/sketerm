//! The pane-level actions that start with a file picker -- record the
//! session (asciicast), save a pane screenshot, upload a file to a
//! remote session -- split out of window.zig. Each picker context
//! carries its own allocator: the cancel callback can fire during
//! window teardown, and freeing must not go through the window.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;
const picker = @import("picker.zig");
const fpicker = @import("../filebrowser/picker.zig");
const pathZ = @import("../util/pathz.zig").pathZ;

/// A picker callback outlives nothing it can check but the window's
/// pane list: the pane may have closed while the dialog was up.
fn stillListed(win: *Window, pane: *Pane) bool {
    for (win.panes.items) |p| {
        if (p == pane) return true;
    }
    return false;
}

/// Carries its own allocator: the picker's cancel callback can fire
/// during window teardown, and freeing must not go through `win`.
const ScreenshotCtx = struct {
    win: *Window,
    pane: *Pane,
    allocator: std.mem.Allocator,
};

/// "Record Session (asciicast)…" — pick a .cast destination, then ask
/// the daemon to start recording the focused pane's session. The file
/// is written by the daemon: for SSH/UDP sessions the picked path is
/// interpreted on the REMOTE host.
pub fn recordFocusedSession(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    if (pane.terminal.remote == null) return;
    const ctx = self.allocator.create(ScreenshotCtx) catch return;
    ctx.* = .{ .win = self, .pane = pane, .allocator = self.allocator };
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .save_file,
            .title = "Record Session As",
            .suggested_name = "session.cast",
            .filters = &.{.{ .label = "Asciicasts", .patterns = &.{"*.cast"} }},
        },
        &onRecordPicked,
        @ptrCast(ctx),
    ) catch {
        self.allocator.destroy(ctx);
        return;
    };
}

fn onRecordPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx = cast.userData(ScreenshotCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    if (!stillListed(ctx.win, ctx.pane)) return;
    // The wire carries a BARE path the session's own daemon resolves,
    // with no way to say "on host X" — so a pick from some third host
    // has no meaning here and is refused rather than silently written
    // somewhere else. A plain path keeps the pre-picker behaviour.
    const path = picker.localPathOrRefuse(
        @ptrCast(ctx.win.app_window),
        res.specs[0],
        "A recording path is resolved by the session's own host — pick a plain path instead.",
    ) orelse return;
    ctx.pane.terminal.requestRecordStart(path);
}

/// "Screenshot Pane…" — render the focused pane to a PNG the user
/// picks a destination for.
pub fn screenshotFocusedPane(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    const ctx = self.allocator.create(ScreenshotCtx) catch return;
    ctx.* = .{ .win = self, .pane = pane, .allocator = self.allocator };
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .save_file,
            .title = "Save Pane Screenshot",
            .suggested_name = "sketerm.png",
            .filters = &.{.{ .label = "PNG images", .patterns = &.{"*.png"} }},
        },
        &onScreenshotPicked,
        @ptrCast(ctx),
    ) catch {
        self.allocator.destroy(ctx);
        return;
    };
}

fn onScreenshotPicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx = cast.userData(ScreenshotCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    if (!stillListed(ctx.win, ctx.pane)) return;
    // The PNG bytes are written by this process — a remote pick has
    // no local file to write to.
    const path = picker.localPathOrRefuse(
        @ptrCast(ctx.win.app_window),
        res.specs[0],
        "Sketerm writes the screenshot itself — pick a location on this machine.",
    ) orelse return;
    const bytes = ctx.pane.screenshotPng() orelse return;
    defer c.g_bytes_unref(bytes);
    var pz: [4096]u8 = undefined;
    const path_z = pathZ(&pz, path) catch return;
    const file = c.g_file_new_for_path(path_z) orelse return;
    defer c.g_object_unref(file);
    var gerr: [*c]c.GError = null;
    // g_file_replace_contents wants the raw buffer; pull it from GBytes.
    var sz: c.gsize = 0;
    const ptr = c.g_bytes_get_data(bytes, &sz);
    _ = c.g_file_replace_contents(file, @ptrCast(ptr), sz, null, 0, c.G_FILE_CREATE_NONE, null, null, &gerr);
    if (gerr != null) c.g_error_free(gerr);
}

/// Carries its own allocator for the same reason ScreenshotCtx does.
const UploadPickCtx = struct {
    win: *Window,
    pane: *Pane,
    allocator: std.mem.Allocator,
};

/// "Upload File…" — pick a local file, then stream it to the focused
/// remote pane's session (which writes it into the shell's cwd).
pub fn openUploadDialog(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    if (pane.terminal.remote == null) return; // remote panes only
    const ctx = self.allocator.create(UploadPickCtx) catch return;
    ctx.* = .{ .win = self, .pane = pane, .allocator = self.allocator };
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .open_file,
            .title = "Upload File to Remote",
            .accept_label = "Upload",
        },
        &onUploadFilePicked,
        @ptrCast(ctx),
    ) catch {
        self.allocator.destroy(ctx);
        return;
    };
}

fn onUploadFilePicked(user: ?*anyopaque, result: ?fpicker.Result) void {
    const ctx = cast.userData(UploadPickCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    if (!stillListed(ctx.win, ctx.pane)) return;
    // startUpload reads the bytes HERE and streams them to the pane's
    // session; there is no local file behind a remote pick.
    const path = picker.localPathOrRefuse(
        @ptrCast(ctx.win.app_window),
        res.specs[0],
        "The upload reads the file from this machine — pick a local file.",
    ) orelse return;
    ctx.pane.terminal.startUpload(&[_][]const u8{path});
}

//! The pane-level actions that start with a file picker -- record the
//! session (asciicast), save a pane screenshot, upload a file to a
//! remote session -- split out of window.zig. Each picker context
//! carries its own allocator: the cancel callback can fire during
//! window teardown, and freeing must not go through the window.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Window = @import("window.zig").Window;
const picker = @import("picker.zig");
const fpicker = @import("../filebrowser/picker.zig");
const livePaneById = @import("remotectl.zig").livePaneById;
const savebytes = @import("savebytes.zig");

/// Picker cancellation may outlive the pane and its original window.
const PanePickCtx = struct {
    pane_id: u32,
    allocator: std.mem.Allocator,
};

/// "Record Session (asciicast)…" — pick a .cast destination, then ask
/// the daemon to start recording the focused pane's session. The file
/// is written by the daemon: for SSH/UDP sessions the picked path is
/// interpreted on the REMOTE host.
pub fn recordFocusedSession(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    if (pane.terminal.remote == null) return;
    const ctx = self.allocator.create(PanePickCtx) catch return;
    ctx.* = .{ .pane_id = pane.id, .allocator = self.allocator };
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
    const ctx = cast.userData(PanePickCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    const ref = livePaneById(ctx.pane_id) orelse return;
    // The wire carries a BARE path the session's own daemon resolves,
    // with no way to say "on host X" — so a pick from some third host
    // has no meaning here and is refused rather than silently written
    // somewhere else. A plain path keeps the pre-picker behaviour.
    const path = picker.localPathOrRefuse(
        @ptrCast(ref.win.app_window),
        res.specs[0],
        "A recording path is resolved by the session's own host — pick a plain path instead.",
    ) orelse return;
    ref.pane.terminal.requestRecordStart(path);
}

/// "Screenshot Pane…" — render the focused pane to a PNG the user
/// picks a destination for.
pub fn screenshotFocusedPane(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    const ctx = self.allocator.create(PanePickCtx) catch return;
    ctx.* = .{ .pane_id = pane.id, .allocator = self.allocator };
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .save_file,
            .title = "Save Pane Screenshot",
            .local_only = true,
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
    const ctx = cast.userData(PanePickCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    const ref = livePaneById(ctx.pane_id) orelse return;
    // The PNG bytes are written by this process — a remote pick has
    // no local file to write to.
    const path = picker.localPathOrRefuse(
        @ptrCast(ref.win.app_window),
        res.specs[0],
        "Sketerm writes the screenshot itself — pick a location on this machine.",
    ) orelse return;
    const bytes = ref.pane.screenshotPng() orelse return;
    defer c.g_bytes_unref(bytes);
    _ = savebytes.save(@ptrCast(ref.win.app_window), path, bytes, c.G_FILE_CREATE_NONE);
}

/// "Upload File…" — pick a local file, then stream it to the focused
/// remote pane's session (which writes it into the shell's cwd).
pub fn openUploadDialog(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    if (pane.terminal.remote == null) return; // remote panes only
    const ctx = self.allocator.create(PanePickCtx) catch return;
    ctx.* = .{ .pane_id = pane.id, .allocator = self.allocator };
    _ = picker.PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .open_file,
            .title = "Upload File to Remote",
            .local_only = true,
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
    const ctx = cast.userData(PanePickCtx, user);
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up.
    const ref = livePaneById(ctx.pane_id) orelse return;
    // startUpload reads the bytes HERE and streams them to the pane's
    // session; there is no local file behind a remote pick.
    const path = picker.localPathOrRefuse(
        @ptrCast(ref.win.app_window),
        res.specs[0],
        "The upload reads the file from this machine — pick a local file.",
    ) orelse return;
    ref.pane.terminal.startUpload(&[_][]const u8{path});
}

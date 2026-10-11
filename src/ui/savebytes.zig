//! Local capture-file replacement and its shared save-failure dialog.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const confirm = @import("confirm.zig");

/// Save borrowed capture bytes and report a failed replacement to the user.
pub fn save(parent: ?*c.GtkWindow, path: []const u8, bytes: *c.GBytes, flags: c.GFileCreateFlags) bool {
    var gerr: [*c]c.GError = null;
    defer if (gerr != null) c.g_error_free(gerr);
    replace(path, bytes, flags, &gerr) catch |err| {
        const reason = if (gerr != null) std.mem.span(gerr.*.message) else @errorName(err);
        var buf: [4608:0]u8 = undefined;
        const message = std.fmt.bufPrintZ(&buf, "Could not save \"{s}\": {s}", .{ path, reason }) catch
            "The capture could not be written to the selected location.";
        _ = confirm.present(@ptrCast(parent), .{
            .heading = "Could not save file",
            .body = message.ptr,
            .responses = &.{.{ .id = "ok", .label = "OK", .is_default = true, .is_close = true }},
            .kick_root = @ptrCast(parent),
        }, null);
        return false;
    };
    return true;
}

fn replace(path: []const u8, bytes: *c.GBytes, flags: c.GFileCreateFlags, gerr: *[*c]c.GError) !void {
    var buf: [4096]u8 = undefined;
    const file = c.g_file_new_for_path(try pathz.pathZ(&buf, path)) orelse return error.SaveFailed;
    defer c.g_object_unref(file);
    var size: c.gsize = 0;
    const data = c.g_bytes_get_data(bytes, &size);
    if (c.g_file_replace_contents(file, @ptrCast(data), size, null, 0, flags, null, null, gerr) == 0)
        return error.SaveFailed;
}

test "capture save replaces bytes and reports unavailable or invalid destinations" {
    const t = std.testing;
    const td = pathz.TempDir.make("capture-save") orelse return error.SkipZigTest;
    defer td.remove();
    const bytes = c.g_bytes_new("capture".ptr, "capture".len).?;
    defer c.g_bytes_unref(bytes);
    var gerr: [*c]c.GError = null;
    defer if (gerr != null) c.g_error_free(gerr);
    var buf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/capture.png", .{td.path()});
    try replace(path, bytes, c.G_FILE_CREATE_NONE, &gerr);
    const got = try @import("../util/readfile.zig").cappedAlloc(t.allocator, path, 64);
    defer t.allocator.free(got);
    try t.expectEqualStrings("capture", got);
    const newer = c.g_bytes_new("new".ptr, "new".len).?;
    defer c.g_bytes_unref(newer);
    try replace(path, newer, c.G_FILE_CREATE_REPLACE_DESTINATION, &gerr);
    const replaced = try @import("../util/readfile.zig").cappedAlloc(t.allocator, path, 64);
    defer t.allocator.free(replaced);
    try t.expectEqualStrings("new", replaced);

    // A directory cannot be replaced, even when running the suite as root.
    try t.expectError(error.SaveFailed, replace(td.path(), bytes, c.G_FILE_CREATE_REPLACE_DESTINATION, &gerr));
    try t.expect(gerr != null);
    try t.expect(std.mem.span(gerr.*.message).len != 0);
    c.g_error_free(gerr);
    gerr = null;
    const absent = try std.fmt.bufPrint(&buf, "{s}/missing/capture.png", .{td.path()});
    try t.expectError(error.SaveFailed, replace(absent, bytes, c.G_FILE_CREATE_NONE, &gerr));
    try t.expect(gerr != null);
    try t.expectError(error.PathTooLong, replace(&([_]u8{'x'} ** 4096), bytes, c.G_FILE_CREATE_NONE, &gerr));
}

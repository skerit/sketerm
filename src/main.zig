// sketerm — terminal emulator entry point.
//
// M0: bare AdwApplication that opens an empty window and exits cleanly.
// Subsequent milestones add the terminal stack on top of this skeleton.

const std = @import("std");
const c = @import("c.zig").c;

const APP_ID: [*:0]const u8 = "dev.sker.sketerm";

pub fn main() u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // Convert Zig argv to GLib-style C argv.
    const argv = std.process.argsAlloc(allocator) catch return 1;
    defer std.process.argsFree(allocator, argv);

    var c_argv = allocator.alloc(?[*:0]u8, argv.len + 1) catch return 1;
    defer allocator.free(c_argv);
    for (argv, 0..) |arg, i| c_argv[i] = @constCast(arg.ptr);
    c_argv[argv.len] = null;

    const argc: c_int = @intCast(argv.len);
    const argv_ptr: [*c][*c]u8 = @ptrCast(c_argv.ptr);

    const app = c.adw_application_new(APP_ID, c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);

    _ = c.g_signal_connect_data(
        app,
        "activate",
        @ptrCast(&onActivate),
        null,
        null,
        c.G_CONNECT_DEFAULT,
    );

    const status = c.g_application_run(@ptrCast(app), argc, argv_ptr);
    return @intCast(status & 0xff);
}

fn onActivate(app: ?*c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const window = c.adw_application_window_new(app);
    c.gtk_window_set_title(@ptrCast(window), "sketerm");
    c.gtk_window_set_default_size(@ptrCast(window), 1000, 700);
    c.gtk_window_present(@ptrCast(window));
}

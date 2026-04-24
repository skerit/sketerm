// sketerm — terminal emulator entry point.

const std = @import("std");
const c = @import("c.zig").c;
const Window = @import("ui/window.zig").Window;

const APP_ID: [*:0]const u8 = "dev.sker.sketerm";

const App = struct {
    allocator: std.mem.Allocator,
    window: ?*Window = null,
};

var g_app: App = undefined;

pub fn main() u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    g_app = .{ .allocator = allocator };

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
    _ = c.g_signal_connect_data(
        app,
        "shutdown",
        @ptrCast(&onShutdown),
        null,
        null,
        c.G_CONNECT_DEFAULT,
    );

    const status = c.g_application_run(@ptrCast(app), argc, argv_ptr);
    return @intCast(status & 0xff);
}

fn onActivate(app: ?*c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const window = Window.init(g_app.allocator, app) catch |err| {
        std.debug.print("sketerm: window init failed: {s}\n", .{@errorName(err)});
        return;
    };
    g_app.window = window;

    window.newShellTab("shell") catch |err| {
        std.debug.print("sketerm: spawn first tab failed: {s}\n", .{@errorName(err)});
        return;
    };

    window.present();
}

fn onShutdown(_: ?*c.GApplication, _: ?*anyopaque) callconv(.c) void {
    if (g_app.window) |w| {
        w.deinit();
        g_app.window = null;
    }
}

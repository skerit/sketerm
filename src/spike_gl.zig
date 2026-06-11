// M0.5 — GL spike. Verifies the GtkGLArea / OpenGL ES 3.0 path
// before M3 commits to it. Opens a window with one GtkGLArea,
// queries GL strings on realize, auto-exits after 2 seconds.
//
// Run with:  zig build spike-gl
//
// Output to stderr includes:
//   GL_VENDOR / GL_RENDERER / GL_VERSION
//   epoxy_gl_version() result
//   set_use_es result
//   realize / render OK flags
//
// Exit 0 = realize + render fired without GL error.

const std = @import("std");
const c = @import("c.zig").c;

const APP_ID: [*:0]const u8 = "dev.sker.sketerm.spike";

const Results = struct {
    realize_fired: bool = false,
    render_fired: bool = false,
    realize_ok: bool = false,
    epoxy_version: c_int = 0,
    gl_vendor: ?[*:0]const u8 = null,
    gl_renderer: ?[*:0]const u8 = null,
    gl_version: ?[*:0]const u8 = null,
    err: ?[]const u8 = null,
};

var results: Results = .{};

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    _ = allocator;

    const argv = init.args.vector;
    const argc: c_int = @intCast(argv.len);
    const argv_ptr: [*c][*c]u8 = @ptrCast(@constCast(argv.ptr));

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

    // Report.
    std.debug.print("\n=== M0.5 GL spike results ===\n", .{});
    std.debug.print("realize fired:  {}\n", .{results.realize_fired});
    std.debug.print("realize ok:     {}\n", .{results.realize_ok});
    std.debug.print("render fired:   {}\n", .{results.render_fired});
    std.debug.print("epoxy_gl_version: {d}\n", .{results.epoxy_version});
    if (results.gl_vendor) |s| std.debug.print("GL_VENDOR:    {s}\n", .{s});
    if (results.gl_renderer) |s| std.debug.print("GL_RENDERER:  {s}\n", .{s});
    if (results.gl_version) |s| std.debug.print("GL_VERSION:   {s}\n", .{s});
    if (results.err) |e| std.debug.print("ERROR: {s}\n", .{e});

    const pass = results.realize_fired and results.realize_ok and results.render_fired;
    std.debug.print("=== {s} ===\n", .{if (pass) "PASS" else "FAIL"});
    if (status != 0) return @intCast(status & 0xff);
    return if (pass) 0 else 2;
}

fn onActivate(app: ?*c.GtkApplication, _: ?*anyopaque) callconv(.c) void {
    const window = c.adw_application_window_new(app);
    c.gtk_window_set_title(@ptrCast(window), "sketerm M0.5 spike");
    c.gtk_window_set_default_size(@ptrCast(window), 600, 400);

    const area = c.gtk_gl_area_new();
    @import("render/gl.zig").requestArea(@ptrCast(area)); // GLES on Linux, GL on macOS
    c.gtk_widget_set_vexpand(area, 1);
    c.gtk_widget_set_hexpand(area, 1);

    _ = c.g_signal_connect_data(
        area,
        "realize",
        @ptrCast(&onRealize),
        null,
        null,
        c.G_CONNECT_DEFAULT,
    );
    _ = c.g_signal_connect_data(
        area,
        "render",
        @ptrCast(&onRender),
        null,
        null,
        c.G_CONNECT_DEFAULT,
    );

    c.adw_application_window_set_content(@ptrCast(window), area);

    // Auto-close after 2 s.
    _ = c.g_timeout_add_seconds(2, @ptrCast(&onTimeout), @ptrCast(window));

    c.gtk_window_present(@ptrCast(window));
}

fn onRealize(area: *c.GtkGLArea, _: ?*anyopaque) callconv(.c) void {
    results.realize_fired = true;
    c.gtk_gl_area_make_current(area);

    if (c.gtk_gl_area_get_error(area)) |gerr| {
        results.err = std.mem.span(@as([*:0]const u8, @ptrCast(gerr.*.message)));
        return;
    }

    results.epoxy_version = c.epoxy_gl_version();
    results.gl_vendor = @ptrCast(c.glGetString(c.GL_VENDOR));
    results.gl_renderer = @ptrCast(c.glGetString(c.GL_RENDERER));
    results.gl_version = @ptrCast(c.glGetString(c.GL_VERSION));
    results.realize_ok = true;
}

fn onRender(_: *c.GtkGLArea, _: *c.GdkGLContext, _: ?*anyopaque) callconv(.c) c.gboolean {
    results.render_fired = true;
    c.glClearColor(0.1, 0.15, 0.2, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    return 1; // TRUE — propagation stops
}

fn onTimeout(window_ptr: ?*anyopaque) callconv(.c) c.gboolean {
    const window: *c.GtkWindow = @ptrCast(@alignCast(window_ptr));
    c.gtk_window_close(window);
    return 0; // FALSE — remove the timer source
}

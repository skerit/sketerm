//! GUI-side host of the sketerm-native app pipe (GUI-only; GTK).
//!
//! One AppHost per `wayland_native` channel: owns the wlhost
//! Compositor (the protocol brain) and renders each toplevel as a
//! plain GtkWindow holding a GtkPicture fed by GdkMemoryTexture —
//! the v1 full-copy pipeline. terminal.zig pumps chan_data payloads
//! in via feed() and ships flush()'d bytes back to the daemon.
//!
//! No input yet (the compositor advertises a capability-less seat);
//! the window close button sends xdg_toplevel.close, which is the
//! one liberty a render-only view can take.

const std = @import("std");
const c = @import("c.zig").c;
const cast = @import("util/cast.zig");
const Compositor = @import("wlhost/compositor.zig").Compositor;

pub const AppHost = struct {
    allocator: std.mem.Allocator,
    comp: Compositor,
    windows: std.AutoHashMapUnmanaged(u32, *Win) = .empty,
    /// Channel is gone — feed() refuses, windows show stale frames
    /// until the user closes them.
    dead: bool = false,
    /// Hook for shipping requestClose (and other view-initiated
    /// events) immediately rather than on the next feed.
    on_flush: ?*const fn (ctx: ?*anyopaque) void = null,
    flush_ctx: ?*anyopaque = null,

    const Win = struct {
        host: *AppHost,
        surface: u32,
        window: *c.GtkWindow,
        picture: *c.GtkWidget,
    };

    pub fn create(allocator: std.mem.Allocator) !*AppHost {
        const self = try allocator.create(AppHost);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .comp = undefined,
        };
        self.comp = try Compositor.init(allocator, .{
            .ctx = self,
            .toplevel_frame = onFrame,
            .toplevel_title = onTitle,
            .toplevel_gone = onGone,
        });
        return self;
    }

    pub fn destroy(self: *AppHost) void {
        var it = self.windows.valueIterator();
        while (it.next()) |w| {
            // Break the close-request link before gtk teardown.
            _ = c.g_object_set_data(@ptrCast(w.*.window), "sketerm-wlapp", null);
            c.gtk_window_destroy(w.*.window);
            self.allocator.destroy(w.*);
        }
        self.windows.deinit(self.allocator);
        self.comp.deinit();
        self.allocator.destroy(self);
    }

    /// One chan_data payload from the daemon. Errors are protocol
    /// fatal — caller closes the channel.
    pub fn feed(self: *AppHost, bytes: []const u8) !void {
        if (self.dead) return;
        try self.comp.feed(bytes);
        if (self.comp.dead) return error.Protocol;
    }

    /// Pending event bytes toward the daemon. Caller ships them as
    /// chan_data and then calls clearOut.
    pub fn takeOut(self: *AppHost) []const u8 {
        return self.comp.takeOut();
    }

    pub fn clearOut(self: *AppHost) void {
        self.comp.clearOut();
    }

    // ── view callbacks (main thread — GTK is safe) ──────────────

    fn onFrame(ctx: ?*anyopaque, surface: u32, w: i32, h: i32, format: u32, pixels: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.winFor(surface, w, h) orelse return;
        // wl_shm: 0 = argb8888 (premultiplied), 1 = xrgb8888 — both
        // little-endian BGRA in memory.
        const gdk_format: c.GdkMemoryFormat = if (format == 1)
            c.GDK_MEMORY_B8G8R8X8
        else
            c.GDK_MEMORY_B8G8R8A8_PREMULTIPLIED;
        const gbytes = c.g_bytes_new(pixels.ptr, pixels.len) orelse return;
        defer c.g_bytes_unref(gbytes);
        const tex = c.gdk_memory_texture_new(w, h, gdk_format, gbytes, @intCast(w * 4)) orelse return;
        defer c.g_object_unref(tex);
        c.gtk_picture_set_paintable(@ptrCast(win.picture), @ptrCast(tex));
    }

    fn onTitle(ctx: ?*anyopaque, surface: u32, title: []const u8) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        var buf: [256:0]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{title}) catch return;
        c.gtk_window_set_title(win.window, z.ptr);
    }

    fn onGone(ctx: ?*anyopaque, surface: u32) void {
        const self = cast.userData(AppHost, ctx);
        const win = self.windows.get(surface) orelse return;
        _ = self.windows.remove(surface);
        _ = c.g_object_set_data(@ptrCast(win.window), "sketerm-wlapp", null);
        c.gtk_window_destroy(win.window);
        self.allocator.destroy(win);
    }

    /// Window for a surface, created on first frame (when the size
    /// is finally known).
    fn winFor(self: *AppHost, surface: u32, w: i32, h: i32) ?*Win {
        if (self.windows.get(surface)) |win| return win;

        const win = self.allocator.create(Win) catch return null;
        const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
        const picture = c.gtk_picture_new();
        c.gtk_window_set_title(window, "remote app");
        c.gtk_window_set_default_size(window, w, h);
        c.gtk_window_set_child(window, picture);
        win.* = .{ .host = self, .surface = surface, .window = window, .picture = picture.? };
        self.windows.put(self.allocator, surface, win) catch {
            c.gtk_window_destroy(window);
            self.allocator.destroy(win);
            return null;
        };
        _ = c.g_object_set_data(@ptrCast(window), "sketerm-wlapp", win);
        _ = c.g_signal_connect_data(@ptrCast(window), "close-request", @ptrCast(&onCloseRequest), win, null, 0);
        c.gtk_window_present(window);
        return win;
    }

    /// Close button → xdg_toplevel.close toward the app; keep the
    /// window until the app destroys its toplevel (or died already,
    /// in which case let GTK close it).
    fn onCloseRequest(window: ?*c.GtkWindow, user: ?*anyopaque) callconv(.c) c.gboolean {
        _ = window;
        const win = cast.userData(Win, user);
        const self = win.host;
        if (self.dead) return 0; // app is gone — really close
        self.comp.requestClose(win.surface) catch return 0;
        if (self.on_flush) |f| f(self.flush_ctx);
        return 1; // handled; wait for the app
    }
};

//! Pane — wraps a GtkGLArea + Atlas + GridPass + Terminal.
//!
//! On `realize`, GL resources are constructed.
//! On `render`, the screen state is rebuilt into the vertex buffer
//! and drawn.
//!
//! For M3, this is the bare-minimum bridge: one Pane, no splits,
//! no input handling. M4 wires keyboard/mouse.

const std = @import("std");
const c = @import("../c.zig").c;
const Atlas = @import("../render/atlas.zig").Atlas;
const GridPass = @import("../render/grid_pass.zig").GridPass;
const Terminal = @import("../terminal.zig").Terminal;
const input = @import("input.zig");
pub const InputCtx = input.Ctx;

const FONT_PATH: [*:0]const u8 = "/usr/share/fonts/TTF/Hack-Regular.ttf";
const FONT_SIZE: u16 = 14;

pub const Pane = struct {
    area: *c.GtkGLArea,
    terminal: *Terminal,
    atlas: ?*Atlas = null,
    grid_pass: GridPass,
    allocator: std.mem.Allocator,
    input_ctx: ?*input.Ctx = null,

    pub fn init(allocator: std.mem.Allocator, terminal: *Terminal) !*Pane {
        const self = try allocator.create(Pane);
        errdefer allocator.destroy(self);

        const area_widget = c.gtk_gl_area_new();
        c.gtk_gl_area_set_use_es(@ptrCast(area_widget), 1);
        c.gtk_widget_set_vexpand(area_widget, 1);
        c.gtk_widget_set_hexpand(area_widget, 1);

        self.* = .{
            .area = @ptrCast(area_widget),
            .terminal = terminal,
            .grid_pass = GridPass.init(allocator),
            .allocator = allocator,
        };

        _ = c.g_signal_connect_data(
            area_widget,
            "realize",
            @ptrCast(&onRealize),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            area_widget,
            "render",
            @ptrCast(&onRender),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        // Repaint at the frame clock when the screen changes.
        // For M3, we just force redraws via a tick callback.
        _ = c.gtk_widget_add_tick_callback(
            area_widget,
            @ptrCast(&onTick),
            @ptrCast(self),
            null,
        );

        // M4: keyboard input → PTY (also handles shortcuts).
        self.input_ctx = try input.attach(area_widget, terminal, allocator);

        // Resize → TIOCSWINSZ → SIGWINCH child.
        _ = c.g_signal_connect_data(
            area_widget,
            "resize",
            @ptrCast(&onResize),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );

        return self;
    }

    pub fn deinit(self: *Pane) void {
        self.grid_pass.deinit();
        if (self.atlas) |a| a.deinit();
        self.allocator.destroy(self);
    }

    pub fn widget(self: *Pane) *c.GtkWidget {
        return @ptrCast(self.area);
    }
};

fn onRealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    c.gtk_gl_area_make_current(area);
    if (c.gtk_gl_area_get_error(area) != null) {
        std.debug.print("pane realize: GL error\n", .{});
        return;
    }

    self.atlas = Atlas.init(self.allocator, FONT_PATH, FONT_SIZE) catch {
        std.debug.print("pane realize: atlas init failed\n", .{});
        return;
    };
    self.atlas.?.realize();

    self.grid_pass.realize() catch {
        std.debug.print("pane realize: grid_pass realize failed\n", .{});
        return;
    };
}

fn onRender(area: *c.GtkGLArea, _: *c.GdkGLContext, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const atlas = self.atlas orelse return @intFromBool(false);

    const w = c.gtk_widget_get_width(@ptrCast(area));
    const h = c.gtk_widget_get_height(@ptrCast(area));
    const scale = c.gtk_widget_get_scale_factor(@ptrCast(area));
    const phys_w: c_int = w * scale;
    const phys_h: c_int = h * scale;

    c.glViewport(0, 0, phys_w, phys_h);
    c.glClearColor(self.grid_pass.default_bg[0], self.grid_pass.default_bg[1], self.grid_pass.default_bg[2], self.grid_pass.default_bg[3]);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    self.grid_pass.buildVertices(self.terminal.screen, &self.terminal.pool, atlas) catch return @intFromBool(false);
    self.grid_pass.draw(atlas, phys_w, phys_h);

    return @intFromBool(true);
}

fn onTick(area: *c.GtkWidget, _: *c.GdkFrameClock, _: ?*anyopaque) callconv(.c) c.gboolean {
    // Force redraw every frame for now; M3 baseline.
    // M4 will only redraw on dirty.
    c.gtk_widget_queue_draw(area);
    return 1; // G_SOURCE_CONTINUE
}

fn onResize(_: *c.GtkGLArea, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const atlas = self.atlas orelse return;
    if (atlas.cell_w == 0 or atlas.cell_h == 0) return;
    const cols: u16 = @intCast(@max(1, @divFloor(width, @as(c_int, atlas.cell_w))));
    const rows: u16 = @intCast(@max(1, @divFloor(height, @as(c_int, atlas.cell_h))));
    if (cols == self.terminal.screen.cols and rows == self.terminal.screen.rows) return;

    // Recreate the screen with new dimensions. Lossy for v1; M2 reflow
    // would preserve content. Acceptable until M3.5/M7.
    self.terminal.screen.deinit();
    self.terminal.screen = (@import("../grid/screen.zig").Screen.init(
        self.allocator,
        &self.terminal.pool,
        cols,
        rows,
    ) catch return);

    self.terminal.pty.setSize(rows, cols);
}

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
const ImagePass = @import("../render/image_pass.zig").ImagePass;
const ImageStore = @import("../grid/image_store.zig").Store;
const Screen = @import("../grid/screen.zig").Screen;
const Terminal = @import("../terminal.zig").Terminal;
const input = @import("input.zig");
const menu = @import("menu.zig");
const clipboard = @import("clipboard.zig");
pub const InputCtx = input.Ctx;
pub const MenuAction = menu.Action;

const FONT_PATH: [*:0]const u8 = "/usr/share/fonts/TTF/Hack-Regular.ttf";
const FONT_SIZE: u16 = 14;

pub const Pane = struct {
    area: *c.GtkGLArea,
    terminal: *Terminal,
    atlas: ?*Atlas = null,
    grid_pass: GridPass,
    image_pass: ImagePass = ImagePass.init(),
    image_store: ImageStore,
    allocator: std.mem.Allocator,
    input_ctx: ?*input.Ctx = null,
    /// External sink for menu actions (set by Window).
    menu_sink: ?menu.Sink = null,
    menu_sink_ctx: ?*anyopaque = null,
    /// Window-level forwarding for terminal sinks.
    win_title_ctx: ?*anyopaque = null,
    win_on_title: ?*const fn (ctx: ?*anyopaque, title: []const u8) void = null,
    win_clip_ctx: ?*anyopaque = null,
    win_on_clipboard: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// Cursor blink timing.
    last_blink_us: i64 = 0,

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
            .image_store = ImageStore.init(allocator),
            .allocator = allocator,
        };

        // Pane is the Terminal's user_ctx for ALL sink callbacks.
        // Pane dispatches: image → its own store, clipboard/title →
        // forwarded to Window if its sinks are set.
        terminal.user_ctx = @ptrCast(self);
        terminal.on_image = onImageEvent;
        terminal.on_title = onTitleEvent;
        terminal.on_clipboard_set = onClipboardEvent;

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

        // Mouse-wheel scroll → adjust view_offset.
        const scroll_ctrl = c.gtk_event_controller_scroll_new(c.GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
        _ = c.g_signal_connect_data(
            scroll_ctrl,
            "scroll",
            @ptrCast(&onScroll),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_widget_add_controller(area_widget, @ptrCast(scroll_ctrl));

        // Left-button drag → selection.
        const drag = c.gtk_gesture_drag_new();
        c.gtk_gesture_single_set_button(@ptrCast(drag), 1);
        _ = c.g_signal_connect_data(drag, "drag-begin", @ptrCast(&onDragBegin), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-update", @ptrCast(&onDragUpdate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(drag));

        // Right-click → context menu.
        try menu.attach(area_widget, allocator, paneMenuSink, @ptrCast(self));

        // Mouse motion → hover tooltip for OSC 8 hyperlinks.
        const motion = c.gtk_event_controller_motion_new();
        _ = c.g_signal_connect_data(
            motion,
            "motion",
            @ptrCast(&onMotion),
            @ptrCast(self),
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_widget_add_controller(area_widget, @ptrCast(motion));
        c.gtk_widget_set_has_tooltip(area_widget, 1);

        return self;
    }

    fn handleMenuLocal(self: *Pane, action: menu.Action) bool {
        switch (action) {
            .copy => {
                if (!self.terminal.screen.selection.isActive()) return true;
                const text = self.terminal.screen.extractSelection(self.allocator) catch return true;
                defer self.allocator.free(text);
                if (text.len == 0) return true;
                const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return true;
                defer self.allocator.free(cstr);
                @memcpy(cstr, text);
                const display = c.gtk_widget_get_display(@ptrCast(self.area));
                const clip = c.gdk_display_get_clipboard(display);
                c.gdk_clipboard_set_text(clip, cstr.ptr);
                return true;
            },
            .paste => {
                clipboard.pasteFromClipboard(@ptrCast(self.area), self.terminal);
                return true;
            },
            else => return false,
        }
    }

    fn cellAt(self: *Pane, x: f64, y: f64) struct { row: i32, col: i32 } {
        const atlas = self.atlas;
        if (atlas == null or atlas.?.cell_w == 0 or atlas.?.cell_h == 0) return .{ .row = 0, .col = 0 };
        const col_f = x / @as(f64, @floatFromInt(atlas.?.cell_w));
        const row_f = y / @as(f64, @floatFromInt(atlas.?.cell_h));
        return .{
            .col = @intFromFloat(@max(0.0, col_f)),
            .row = @intFromFloat(@max(0.0, row_f)),
        };
    }

    pub fn deinit(self: *Pane) void {
        self.grid_pass.deinit();
        self.image_pass.deinit();
        self.image_store.deinit();
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
    self.image_pass.realize() catch {
        std.debug.print("pane realize: image_pass realize failed\n", .{});
        return;
    };

    // Cell metrics into image store so placements get pixel coords.
    self.image_store.cell_w = @floatFromInt(self.atlas.?.cell_w);
    self.image_store.cell_h = @floatFromInt(self.atlas.?.cell_h);
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

    // Upload pending images, then draw.
    self.image_store.flushUploads();
    self.image_pass.draw(&self.image_store, phys_w, phys_h);

    return @intFromBool(true);
}

fn onImageEvent(ctx: ?*anyopaque, img: Screen.ImageEvent) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    self.image_store.add(img.rgba, img.width, img.height, img.row, img.col) catch {};
    // Force redraw to upload + display.
    self.terminal.screen.dirty = true;
}

fn onTitleEvent(ctx: ?*anyopaque, title: []const u8) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    if (self.win_on_title) |f| f(self.win_title_ctx, title);
}

fn onClipboardEvent(ctx: ?*anyopaque, text: []const u8) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    if (self.win_on_clipboard) |f| f(self.win_clip_ctx, text);
}

fn onTick(area: *c.GtkWidget, _: *c.GdkFrameClock, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Pane = @ptrCast(@alignCast(user.?));

    // Cursor blink — toggle every 500ms for blinking shapes.
    const screen = self.terminal.screen;
    const now = std.time.microTimestamp();
    if (self.last_blink_us == 0) self.last_blink_us = now;
    const elapsed = now - self.last_blink_us;
    const blinking = switch (screen.cursor_shape) {
        .block_blink, .underline_blink, .bar_blink => true,
        else => false,
    };
    if (blinking and elapsed > 500_000) {
        self.last_blink_us = now;
        screen.cursor_blink_on = !screen.cursor_blink_on;
        screen.dirty = true;
    }

    if (screen.dirty) {
        screen.dirty = false;
        c.gtk_widget_queue_draw(area);
    }
    return 1; // G_SOURCE_CONTINUE
}

fn paneMenuSink(ctx: ?*anyopaque, action: menu.Action) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    if (self.handleMenuLocal(action)) return;
    if (self.menu_sink) |f| f(self.menu_sink_ctx, action);
}

fn onMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const cell = self.cellAt(x, y);
    if (cell.row < 0 or cell.col < 0) return;
    const screen = self.terminal.screen;
    if (cell.row >= screen.rows or cell.col >= screen.cols) return;
    const c_row: u16 = @intCast(cell.row);
    const c_col: u16 = @intCast(cell.col);
    const cell_data = screen.cellAt(c_row, c_col);
    if (cell_data.flags & 0b0000_0100 == 0) {
        c.gtk_widget_set_tooltip_text(@ptrCast(self.area), null);
        return;
    }
    if (screen.linkUri(cell_data.reserved)) |uri| {
        // Copy to null-terminated buffer for GTK.
        var buf: [4096]u8 = undefined;
        const n = @min(uri.len, buf.len - 1);
        @memcpy(buf[0..n], uri[0..n]);
        buf[n] = 0;
        c.gtk_widget_set_tooltip_text(@ptrCast(self.area), &buf);
    }
}

fn onDragBegin(_: *c.GtkGestureDrag, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const cell = self.cellAt(x, y);
    self.terminal.screen.selection.start(cell.row, cell.col, .normal);
    c.gtk_widget_queue_draw(@ptrCast(self.area));
}

fn onDragUpdate(g: *c.GtkGestureDrag, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    var sx: f64 = 0;
    var sy: f64 = 0;
    _ = c.gtk_gesture_drag_get_start_point(g, &sx, &sy);
    const cell = self.cellAt(sx + dx, sy + dy);
    self.terminal.screen.selection.extend(cell.row, cell.col);
    c.gtk_widget_queue_draw(@ptrCast(self.area));
}

fn onScroll(_: *c.GtkEventControllerScroll, _: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const screen = self.terminal.screen;
    const sb = screen.scrollbackCount();
    // Scroll up (negative dy) increases view_offset. 3 lines per click.
    if (dy < 0) {
        const want = screen.view_offset + 3;
        screen.view_offset = if (want > sb) sb else want;
    } else if (dy > 0) {
        screen.view_offset = if (screen.view_offset >= 3) screen.view_offset - 3 else 0;
    }
    c.gtk_widget_queue_draw(@ptrCast(self.area));
    return 1;
}

fn onResize(_: *c.GtkGLArea, width: c_int, height: c_int, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const atlas = self.atlas orelse return;
    if (atlas.cell_w == 0 or atlas.cell_h == 0) return;
    const cols: u16 = @intCast(@max(1, @divFloor(width, @as(c_int, atlas.cell_w))));
    const rows: u16 = @intCast(@max(1, @divFloor(height, @as(c_int, atlas.cell_h))));
    if (cols == self.terminal.screen.cols and rows == self.terminal.screen.rows) return;

    self.terminal.screen.resize(cols, rows) catch return;
    self.terminal.pty.setSize(rows, cols);
}

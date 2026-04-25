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

const FONT_CANDIDATES = [_][*:0]const u8{
    "/usr/share/fonts/TTF/Hack-Regular.ttf",
    "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/TTF/VeraMono.ttf",
    "/usr/share/fonts/gnu-free/FreeMono.otf",
    "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
};
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
    /// Arena holding menu's per-pane closure ctxs. Deinit frees all.
    menu_arena: std.heap.ArenaAllocator,
    /// External sink for menu actions (set by Window).
    menu_sink: ?menu.Sink = null,
    menu_sink_ctx: ?*anyopaque = null,
    /// Window-level forwarding for terminal sinks.
    win_title_ctx: ?*anyopaque = null,
    win_on_title: ?*const fn (ctx: ?*anyopaque, title: []const u8) void = null,
    win_clip_ctx: ?*anyopaque = null,
    win_on_clipboard: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// Forward iTerm2 / OSC 777 desktop notifications.
    win_notify_ctx: ?*anyopaque = null,
    win_on_notification: ?*const fn (ctx: ?*anyopaque, title: []const u8, body: []const u8) void = null,
    /// Forward BEL events for tab-bar attention.
    win_bell_ctx: ?*anyopaque = null,
    win_on_bell: ?*const fn (ctx: ?*anyopaque, pane: *Pane) void = null,
    /// Cursor blink timing.
    last_blink_us: i64 = 0,
    /// Last reported mouse-motion cell, to suppress duplicates.
    last_motion_row: i32 = -2,
    last_motion_col: i32 = -2,
    /// xterm button code (0=L,1=M,2=R) currently held, or -1 = none.
    /// Used by DECSET 1002 button-event tracking.
    held_button: i32 = -1,
    /// URI captured at right-click time. menu_pre_popup writes here
    /// when the click landed on an OSC 8 hyperlink cell; the
    /// "copy-link" action reads it on activate.
    menu_link_uri: ?[]u8 = null,
    /// Live font size in points. Initialised from Config.font_size,
    /// adjustable via Ctrl++ / Ctrl+- which rebuilds the atlas.
    font_size: u16 = 14,
    /// Optional explicit font path (overrides FONT_CANDIDATES). Owned
    /// by the Config arena, valid for the lifetime of the Window.
    font_path: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, terminal: *Terminal) !*Pane {
        const self = try allocator.create(Pane);
        errdefer allocator.destroy(self);

        const area_widget = c.gtk_gl_area_new();
        c.gtk_gl_area_set_use_es(@ptrCast(area_widget), 1);
        c.gtk_gl_area_set_auto_render(@ptrCast(area_widget), 1);
        c.gtk_widget_set_vexpand(area_widget, 1);
        c.gtk_widget_set_hexpand(area_widget, 1);
        c.gtk_widget_set_visible(area_widget, 1);

        self.* = .{
            .area = @ptrCast(area_widget),
            .terminal = terminal,
            .grid_pass = GridPass.init(allocator),
            .image_store = ImageStore.init(allocator),
            .menu_arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = allocator,
        };

        // Pane is the Terminal's user_ctx for ALL sink callbacks.
        // Pane dispatches: image → its own store, clipboard/title →
        // forwarded to Window if its sinks are set.
        terminal.user_ctx = @ptrCast(self);
        terminal.on_image = onImageEvent;
        terminal.on_image_delete_full = onImageDeleteFullEvent;
        terminal.on_title = onTitleEvent;
        terminal.on_clipboard_set = onClipboardEvent;
        terminal.on_notification = onNotificationEvent;
        terminal.on_bell = onBellEvent;

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

        // Left-button drag → selection (and ctrl-click on links).
        const drag = c.gtk_gesture_drag_new();
        c.gtk_gesture_single_set_button(@ptrCast(drag), 1);
        _ = c.g_signal_connect_data(drag, "drag-begin", @ptrCast(&onDragBegin), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-update", @ptrCast(&onDragUpdate), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(drag, "drag-end", @ptrCast(&onDragEnd), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(drag));

        // Right-click → context menu. Allocations go into menu_arena
        // so they're freed when the pane is destroyed.
        try menu.attachWithPrePopup(area_widget, self.menu_arena.allocator(), paneMenuSink, @ptrCast(self), paneMenuPrePopup, @ptrCast(self));

        // Mouse reporting (DECSET 1006). Click controller covers
        // press / release for any button; emits the SGR sequence
        // when mouse_mode is enabled by the shell-side app.
        const click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(click), 0); // any button
        _ = c.g_signal_connect_data(click, "pressed", @ptrCast(&onMousePressed), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(click, "released", @ptrCast(&onMouseReleased), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(click));

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

        // Focus reporting (DECSET 1004). Apps that opt in get
        // \x1b[I on enter, \x1b[O on leave.
        const focus = c.gtk_event_controller_focus_new();
        _ = c.g_signal_connect_data(focus, "enter", @ptrCast(&onFocusEnter), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(focus, "leave", @ptrCast(&onFocusLeave), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        c.gtk_widget_add_controller(area_widget, @ptrCast(focus));

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
            .reset_terminal => {
                self.terminal.screen.fullReset();
                return true;
            },
            .copy_link => {
                const uri = self.menu_link_uri orelse return true;
                if (uri.len == 0) return true;
                const cstr = self.allocator.allocSentinel(u8, uri.len, 0) catch return true;
                defer self.allocator.free(cstr);
                @memcpy(cstr, uri);
                const display = c.gtk_widget_get_display(@ptrCast(self.area));
                const clip = c.gdk_display_get_clipboard(display);
                c.gdk_clipboard_set_text(clip, cstr.ptr);
                return true;
            },
            else => return false,
        }
    }

    /// Map widget pixel coords to a Screen selection coordinate.
    /// Negative `row` references scrollback (-1 = bottom-most
    /// scrollback line). Honors `view_offset` so dragging into
    /// scrolled-back area produces scrollback coords.
    fn cellAt(self: *Pane, x: f64, y: f64) struct { row: i32, col: i32 } {
        const atlas = self.atlas;
        if (atlas == null or atlas.?.cell_w == 0 or atlas.?.cell_h == 0) return .{ .row = 0, .col = 0 };
        // Mouse coords are in widget pixels — subtract pane padding so
        // the first cell aligns with the rendered grid origin.
        const pad: f64 = @floatCast(self.grid_pass.pad);
        const col_f = (x - pad) / @as(f64, @floatFromInt(atlas.?.cell_w));
        const row_f = (y - pad) / @as(f64, @floatFromInt(atlas.?.cell_h));
        const visible_row: i32 = @intFromFloat(@max(0.0, row_f));
        const view_off: i32 = @intCast(self.terminal.screen.view_offset);
        return .{
            .col = @intFromFloat(@max(0.0, col_f)),
            .row = visible_row - view_off,
        };
    }

    pub fn deinit(self: *Pane) void {
        self.grid_pass.deinit();
        self.image_pass.deinit();
        self.image_store.deinit();
        if (self.atlas) |a| a.deinit();
        if (self.input_ctx) |ictx| self.allocator.destroy(ictx);
        if (self.menu_link_uri) |uri| self.allocator.free(uri);
        self.menu_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn widget(self: *Pane) *c.GtkWidget {
        return @ptrCast(self.area);
    }

    /// Live font-size change. Tears down the old atlas (and its GL
    /// texture), bumps `font_size`, and rebuilds against the current
    /// GL context. The renderer rebinds the new texture each frame.
    /// Also re-derives the cell size so PTY winsize tracks the
    /// new metrics on the next resize.
    pub fn setFontSize(self: *Pane, new_size: u16) void {
        if (new_size == self.font_size) return;
        self.font_size = new_size;

        // Make our GL context current so the texture deletes hit the
        // right context.
        c.gtk_gl_area_make_current(self.area);
        if (c.gtk_gl_area_get_error(self.area) != null) return;

        if (self.atlas) |old| {
            // Drop the GL texture before destroying the atlas.
            if (old.realized) {
                var tex: c_uint = old.gl_tex;
                c.glDeleteTextures(1, &tex);
            }
            old.deinit();
            self.atlas = null;
        }

        // Same path as onRealize but inline so we don't re-do GL pass
        // setup (those programs / VBOs are still live).
        const size: u16 = self.font_size;
        if (self.font_path) |fp| {
            const z = self.allocator.allocSentinel(u8, fp.len, 0) catch return;
            defer self.allocator.free(z);
            @memcpy(z, fp);
            if (Atlas.init(self.allocator, z.ptr, size)) |a| {
                self.atlas = a;
            } else |_| {}
        }
        if (self.atlas == null) {
            if (std.posix.getenv("SKETERM_FONT")) |env_path| {
                const z = self.allocator.allocSentinel(u8, env_path.len, 0) catch return;
                defer self.allocator.free(z);
                @memcpy(z, env_path);
                if (Atlas.init(self.allocator, z.ptr, size)) |a| {
                    self.atlas = a;
                } else |_| {}
            }
        }
        if (self.atlas == null) {
            for (FONT_CANDIDATES) |path| {
                if (Atlas.init(self.allocator, path, size)) |a| {
                    self.atlas = a;
                    break;
                } else |_| continue;
            }
        }
        if (self.atlas == null) return;
        self.atlas.?.realize();

        self.image_store.cell_w = @floatFromInt(self.atlas.?.cell_w);
        self.image_store.cell_h = @floatFromInt(self.atlas.?.cell_h);

        // Force a SIGWINCH on the child — terminal winsize in cells
        // changes when the cell size changes.
        const w = c.gtk_widget_get_width(@ptrCast(self.area));
        const h = c.gtk_widget_get_height(@ptrCast(self.area));
        const pad: f32 = self.grid_pass.pad;
        const inner_w = @as(f32, @floatFromInt(w)) - 2 * pad;
        const inner_h = @as(f32, @floatFromInt(h)) - 2 * pad;
        const cw: f32 = @floatFromInt(self.atlas.?.cell_w);
        const ch: f32 = @floatFromInt(self.atlas.?.cell_h);
        if (cw > 0 and ch > 0) {
            const cols: u16 = @intCast(@max(@as(i32, 1), @as(i32, @intFromFloat(@floor(inner_w / cw)))));
            const rows: u16 = @intCast(@max(@as(i32, 1), @as(i32, @intFromFloat(@floor(inner_h / ch)))));
            _ = self.terminal.screen.resize(cols, rows) catch {};
            self.terminal.pty.setSize(rows, cols);
        }

        self.terminal.screen.dirty = true;
        c.gtk_widget_queue_draw(@ptrCast(self.area));
    }
};

fn onRealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    c.gtk_gl_area_make_current(area);
    if (c.gtk_gl_area_get_error(area) != null) {
        const err = c.gtk_gl_area_get_error(area);
        const msg: [*:0]const u8 = if (err != null) err.*.message else "<no message>";
        std.debug.print("sketerm: pane realize GL error: {s}\n", .{msg});
        return;
    }

    // gtk_widget_unparent unrealizes a widget. A reparent (split,
    // tab move, layout shuffle) therefore destroys our GL context
    // and gives us a fresh one on the next realize. Drop every
    // cached GL handle so the realize path below actually rebuilds
    // them — without this, grid_pass.realize() returns early on
    // `program != 0` and we'd glUseProgram a dead ID.
    if (self.atlas) |old| {
        old.deinit();
        self.atlas = null;
    }
    self.grid_pass.forgetGL();
    self.image_pass.forgetGL();
    self.image_store.forgetGL();

    // Resolution order: explicit Pane.font_path → $SKETERM_FONT env →
    // built-in candidate list. Size from Pane.font_size (set by
    // Config or the Ctrl+/Ctrl- shortcuts).
    self.atlas = null;
    const size: u16 = self.font_size;
    if (self.font_path) |fp| {
        const z = self.allocator.allocSentinel(u8, fp.len, 0) catch return;
        defer self.allocator.free(z);
        @memcpy(z, fp);
        if (Atlas.init(self.allocator, z.ptr, size)) |a| {
            self.atlas = a;
        } else |_| {}
    }
    if (self.atlas == null) {
        if (std.posix.getenv("SKETERM_FONT")) |env_path| {
            const z = self.allocator.allocSentinel(u8, env_path.len, 0) catch return;
            defer self.allocator.free(z);
            @memcpy(z, env_path);
            if (Atlas.init(self.allocator, z.ptr, size)) |a| {
                self.atlas = a;
            } else |_| {}
        }
    }
    if (self.atlas == null) {
        for (FONT_CANDIDATES) |path| {
            if (Atlas.init(self.allocator, path, size)) |a| {
                self.atlas = a;
                break;
            } else |_| continue;
        }
    }
    if (self.atlas == null) {
        std.debug.print("pane realize: no usable font in {d} candidates\n", .{FONT_CANDIDATES.len});
        return;
    }
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

    self.grid_pass.canvas_w = @floatFromInt(phys_w);
    self.grid_pass.canvas_h = @floatFromInt(phys_h);

    const focused = c.gtk_widget_has_focus(@ptrCast(self.area)) != 0;
    self.grid_pass.buildVertices(self.terminal.screen, &self.terminal.pool, atlas, focused) catch return @intFromBool(false);
    self.grid_pass.draw(atlas, phys_w, phys_h);

    // Upload pending images, then draw.
    self.image_store.flushUploads();
    self.image_pass.draw(&self.image_store, phys_w, phys_h);

    return @intFromBool(true);
}

fn onImageEvent(ctx: ?*anyopaque, img: Screen.ImageEvent) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    self.image_store.addFull(.{
        .rgba = img.rgba,
        .width = img.width,
        .height = img.height,
        .row = img.row,
        .col = img.col,
        .image_id = img.image_id,
        .placement_id = img.placement_id,
        .z_index = img.z_index,
        .cells_wide = img.cells_wide,
        .cells_high = img.cells_high,
        .src_x = img.src_x,
        .src_y = img.src_y,
        .src_w = img.src_w,
        .src_h = img.src_h,
    }) catch {};
    // Force redraw to upload + display. Set dirty so onTick paints AND
    // queue_draw directly so we don't have to wait a frame.
    self.terminal.screen.dirty = true;
    c.gtk_widget_queue_draw(@ptrCast(self.area));
}

fn onImageDeleteFullEvent(ctx: ?*anyopaque, ev: @import("../grid/screen.zig").Screen.ImageDeleteEvent) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    // Kitty `d=` semantics. Lowercase leaves data on disk, uppercase
    // also frees it. We don't distinguish on free behaviour — every
    // delete tears down the GL texture on the next flush.
    switch (ev.what) {
        'a', 'A' => self.image_store.markAllForDelete(),
        'i', 'I' => {
            if (ev.image_id != 0) self.image_store.markByIdForDelete(ev.image_id);
        },
        'p', 'P' => {
            if (ev.image_id != 0) self.image_store.markByPlacementForDelete(ev.image_id, ev.placement_id);
        },
        // 'n','N' (image_number), 'r','R' (z-range), 'x','y','c'
        // (coordinates), 'z','Z' (z-index): not yet implemented.
        // Fallback: if we have an image_id, scope the delete to that
        // image; otherwise leave images alone rather than nuke all.
        else => {
            if (ev.image_id != 0) {
                if (ev.placement_id != 0)
                    self.image_store.markByPlacementForDelete(ev.image_id, ev.placement_id)
                else
                    self.image_store.markByIdForDelete(ev.image_id);
            }
        },
    }
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

fn onNotificationEvent(ctx: ?*anyopaque, title: []const u8, body: []const u8) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    if (self.win_on_notification) |f| f(self.win_notify_ctx, title, body);
}

fn onBellEvent(ctx: ?*anyopaque) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    if (self.win_on_bell) |f| f(self.win_bell_ctx, self);
}

fn onTick(area: *c.GtkWidget, _: *c.GdkFrameClock, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Pane = @ptrCast(@alignCast(user.?));

    // Cursor blink — toggle every 500ms for blinking shapes, but
    // only on the focused pane. Unfocused panes always show a static
    // (hollow) cursor and don't waste redraws toggling phase.
    const screen = self.terminal.screen;
    const now = std.time.microTimestamp();
    if (self.last_blink_us == 0) self.last_blink_us = now;
    const focused = c.gtk_widget_has_focus(@ptrCast(self.area)) != 0;
    const blinking = focused and switch (screen.cursor_shape) {
        .block_blink, .underline_blink, .bar_blink => true,
        else => false,
    };
    const elapsed = now - self.last_blink_us;
    if (blinking and elapsed > 500_000) {
        self.last_blink_us = now;
        screen.cursor_blink_on = !screen.cursor_blink_on;
        screen.dirty = true;
    } else if (!focused and !screen.cursor_blink_on) {
        // Coming back into focus from a mid-blink "off" phase would
        // leave the cursor invisible until the next toggle. Snap on.
        screen.cursor_blink_on = true;
        screen.dirty = true;
    }

    // Keep redrawing while bell flash is fading.
    if (screen.bell_at_us > 0) {
        const since_bell = now - screen.bell_at_us;
        if (since_bell < 200_000) screen.dirty = true;
    }

    if (screen.dirty) {
        // Update IME cursor location so fcitx5 / ibus position
        // their popups at the right cell.
        if (self.input_ctx) |ictx| if (ictx.im_ctx) |im| if (self.atlas) |atlas| {
            var rect = c.GdkRectangle{
                .x = @as(c_int, @intCast(screen.col)) * @as(c_int, atlas.cell_w),
                .y = @as(c_int, @intCast(screen.row)) * @as(c_int, atlas.cell_h),
                .width = atlas.cell_w,
                .height = atlas.cell_h,
            };
            c.gtk_im_context_set_cursor_location(im, &rect);
        };

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

/// Called just before the right-click context menu pops up. We
/// inspect the cell under the click for an OSC 8 link, and toggle
/// the `term.copy-link` action's enabled state accordingly.
fn paneMenuPrePopup(ctx: ?*anyopaque, group: *c.GSimpleActionGroup, x: f64, y: f64) void {
    const self: *Pane = @ptrCast(@alignCast(ctx.?));
    const screen = self.terminal.screen;

    // Free any URI captured from a previous popup.
    if (self.menu_link_uri) |old| {
        self.allocator.free(old);
        self.menu_link_uri = null;
    }

    var has_link = false;
    const cell = self.cellAt(x, y);
    if (cell.col >= 0 and cell.col < screen.cols) {
        // cellAt's row can be negative when the click landed in
        // scrollback. Resolve via lineCellsAt (negative rows index
        // scrollback from the bottom).
        const cells_at = screen.lineCellsAtPub(cell.row);
        if (cells_at) |cells| {
            // Bidi remap: cellAt returns the *visual* column. For
            // mixed/RTL rows, the logical cell at that visual col
            // may be different. Resolve via fribidi when the row
            // contains any non-ASCII codepoint.
            var logical_col: usize = @intCast(cell.col);
            if (self.grid_pass.enable_bidi) {
                var any_non_ascii = false;
                for (cells) |rc| {
                    if (rc.rune > 0x7F) {
                        any_non_ascii = true;
                        break;
                    }
                }
                if (any_non_ascii) {
                    const bidi = @import("../grid/bidi.zig");
                    const cps = self.allocator.alloc(u32, cells.len) catch null;
                    if (cps) |cps_buf| {
                        defer self.allocator.free(cps_buf);
                        const lvls = self.allocator.alloc(u8, cells.len) catch null;
                        if (lvls) |lvls_buf| {
                            defer self.allocator.free(lvls_buf);
                            const idx = self.allocator.alloc(usize, cells.len) catch null;
                            if (idx) |idx_buf| {
                                defer self.allocator.free(idx_buf);
                                for (cells, 0..) |rc, i| {
                                    cps_buf[i] = if (rc.rune == 0) ' ' else rc.rune;
                                    idx_buf[i] = i;
                                }
                                _ = bidi.lineLevels(cps_buf, lvls_buf, .auto);
                                bidi.levelsToVisualOrder(lvls_buf, idx_buf);
                                const v: usize = @intCast(cell.col);
                                if (v < idx_buf.len) logical_col = idx_buf[v];
                            }
                        }
                    }
                }
            }
            if (logical_col < cells.len) {
                const c_cell = cells[logical_col];
                if (c_cell.flags & 0b0000_0100 != 0) {
                    if (screen.linkUri(c_cell.reserved)) |uri| {
                        if (self.allocator.dupe(u8, uri)) |copy| {
                            self.menu_link_uri = copy;
                            has_link = true;
                        } else |_| {}
                    }
                }
            }
        }
    }

    if (c.g_action_map_lookup_action(@ptrCast(group), "copy-link")) |act| {
        c.g_simple_action_set_enabled(@ptrCast(@alignCast(act)), if (has_link) 1 else 0);
    }
}

fn onFocusEnter(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    if (self.terminal.screen.focus_reports) {
        _ = self.terminal.pty.writeAll("\x1b[I");
    }
    // Cursor style + focus border switch on focus change — force a
    // repaint so the swap is immediate.
    self.terminal.screen.cursor_blink_on = true;
    self.terminal.screen.dirty = true;
}

fn onFocusLeave(_: *c.GtkEventControllerFocus, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    if (self.terminal.screen.focus_reports) {
        _ = self.terminal.pty.writeAll("\x1b[O");
    }
    self.terminal.screen.cursor_blink_on = true;
    self.terminal.screen.dirty = true;
}

fn onMotion(_: *c.GtkEventControllerMotion, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const cell = self.cellAt(x, y);
    const screen = self.terminal.screen;

    // Mouse-motion reporting:
    //   DECSET 1003 = any motion
    //   DECSET 1002 = motion only while a button is held
    // Suppress duplicates within the same cell.
    if (cell.row >= 0 and cell.col >= 0) {
        const want_motion =
            (screen.mouse_mode == 1003) or
            (screen.mouse_mode == 1002 and self.held_button >= 0);
        if (want_motion and
            (cell.row != self.last_motion_row or cell.col != self.last_motion_col))
        {
            self.last_motion_row = cell.row;
            self.last_motion_col = cell.col;
            // Button bits: 32=motion, base 0=L,1=M,2=R or 3=no-button.
            const base: u32 = if (self.held_button >= 0)
                @intCast(self.held_button)
            else
                3;
            var buf: [32]u8 = undefined;
            const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}M", .{
                32 + base,
                @as(u32, @intCast(cell.col + 1)),
                @as(u32, @intCast(cell.row + 1)),
            }) catch return;
            _ = self.terminal.pty.writeAll(seq);
        }
    }

    // OSC 8 hover tooltip.
    if (cell.row < 0 or cell.col < 0) return;
    if (cell.row >= screen.rows or cell.col >= screen.cols) return;
    const c_row: u16 = @intCast(cell.row);
    const c_col: u16 = @intCast(cell.col);
    const cell_data = screen.cellAt(c_row, c_col);
    if (cell_data.flags & 0b0000_0100 == 0) {
        c.gtk_widget_set_tooltip_text(@ptrCast(self.area), null);
        return;
    }
    if (screen.linkUri(cell_data.reserved)) |uri| {
        var buf: [4096]u8 = undefined;
        const n = @min(uri.len, buf.len - 1);
        @memcpy(buf[0..n], uri[0..n]);
        buf[n] = 0;
        c.gtk_widget_set_tooltip_text(@ptrCast(self.area), &buf);
    }
}

fn onDragBegin(g: *c.GtkGestureDrag, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    // Always grab focus on click.
    _ = c.gtk_widget_grab_focus(@ptrCast(self.area));
    // If app captures the mouse, don't start a text selection —
    // the click is going through the click controller as a mouse
    // report instead.
    if (self.terminal.screen.mouse_mode != 0) return;

    // Read modifiers before deciding what kind of drag this is.
    var mods: c.GdkModifierType = 0;
    const ev = c.gtk_event_controller_get_current_event(@ptrCast(g));
    if (ev != null) mods = c.gdk_event_get_modifier_state(ev);
    const shift_held = (mods & c.GDK_SHIFT_MASK) != 0;
    const alt_held = (mods & c.GDK_ALT_MASK) != 0;

    // On the alternate screen (TUIs like vim, htop, less), the
    // running app owns the mouse model — host-side selection is
    // usually noise. Require Shift to override (matches xterm /
    // gnome-terminal / kitty conventions). Wipe any leftover
    // selection from the main screen so the user doesn't see a
    // ghost highlight.
    if (self.terminal.screen.use_alt and !shift_held) {
        if (self.terminal.screen.selection.isActive()) {
            self.terminal.screen.selection.clear();
            self.terminal.screen.dirty = true;
            c.gtk_widget_queue_draw(@ptrCast(self.area));
        }
        return;
    }

    const cell = self.cellAt(x, y);
    const mode: @import("../grid/selection.zig").Mode = if (alt_held) .rectangular else .normal;
    self.terminal.screen.selection.start(cell.row, cell.col, mode);
    c.gtk_widget_queue_draw(@ptrCast(self.area));
}

fn onMousePressed(g: *c.GtkGestureClick, n_press: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const button = c.gtk_gesture_single_get_current_button(@ptrCast(g));

    // Middle-click PRIMARY paste when the running app isn't asking
    // for mouse reports. With mouse_mode > 0 the app sees the click.
    if (button == 2 and self.terminal.screen.mouse_mode == 0) {
        clipboard.pastePrimaryFromClipboard(@ptrCast(self.area), self.terminal);
        return;
    }

    // Left double / triple click → word / line selection.
    if (button == 1 and self.terminal.screen.mouse_mode == 0 and n_press >= 2) {
        // On alt screen (TUIs), host-side selection is opt-in via
        // Shift. Same rule as drag selection — keeps the running
        // app's mouse model uncontested.
        var mods_d: c.GdkModifierType = 0;
        const ev_d = c.gtk_event_controller_get_current_event(@ptrCast(g));
        if (ev_d != null) mods_d = c.gdk_event_get_modifier_state(ev_d);
        const shift_d = (mods_d & c.GDK_SHIFT_MASK) != 0;
        if (self.terminal.screen.use_alt and !shift_d) {
            if (self.terminal.screen.selection.isActive()) {
                self.terminal.screen.selection.clear();
                self.terminal.screen.dirty = true;
                c.gtk_widget_queue_draw(@ptrCast(self.area));
            }
            return;
        }

        const cell = self.cellAt(x, y);
        const screen = self.terminal.screen;
        if (n_press == 2) {
            screen.selectWordAt(cell.row, cell.col);
        } else { // 3+
            screen.selectLineAt(cell.row);
        }
        // Push the new selection text to PRIMARY for middle-click paste.
        if (screen.selection.isActive()) {
            const text = screen.extractSelection(self.allocator) catch null;
            if (text) |t| {
                defer self.allocator.free(t);
                if (t.len > 0) {
                    if (self.allocator.allocSentinel(u8, t.len, 0)) |cs| {
                        defer self.allocator.free(cs);
                        @memcpy(cs, t);
                        clipboard.copyToPrimary(@ptrCast(self.area), cs);
                    } else |_| {}
                }
            }
        }
        c.gtk_widget_queue_draw(@ptrCast(self.area));
        return;
    }

    if (self.terminal.screen.mouse_mode == 0) return;
    emitMouseSeq(self, g, x, y, true);
}

fn onMouseReleased(g: *c.GtkGestureClick, _: c_int, x: f64, y: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    if (self.terminal.screen.mouse_mode == 0) return;
    emitMouseSeq(self, g, x, y, false);
}

fn emitMouseSeq(self: *Pane, g: *c.GtkGestureClick, x: f64, y: f64, press: bool) void {
    const button_raw = c.gtk_gesture_single_get_current_button(@ptrCast(g));
    if (button_raw == 0) return;
    // Map GTK button numbers (1=L, 2=M, 3=R) to xterm button bits
    // (0=L, 1=M, 2=R per SGR 1006).
    const xterm_button: i32 = switch (button_raw) {
        1 => 0,
        2 => 1,
        3 => 2,
        else => return,
    };
    if (press) {
        self.held_button = xterm_button;
    } else if (self.held_button == xterm_button) {
        self.held_button = -1;
    }
    const cell = self.cellAt(x, y);
    if (cell.row < 0 or cell.col < 0) return;
    var buf: [32]u8 = undefined;
    const final: u8 = if (press) 'M' else 'm';
    const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
        @as(u32, @intCast(xterm_button)),
        @as(u32, @intCast(cell.col + 1)),
        @as(u32, @intCast(cell.row + 1)),
        final,
    }) catch return;
    _ = self.terminal.pty.writeAll(seq);
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

fn onDragEnd(g: *c.GtkGestureDrag, dx: f64, dy: f64, user: ?*anyopaque) callconv(.c) void {
    const self: *Pane = @ptrCast(@alignCast(user.?));

    // Tiny drags = a click. If Ctrl was held and the click landed on
    // a hyperlinked cell, launch its URI.
    const moved = @abs(dx) > 4 or @abs(dy) > 4;
    if (moved) {
        // Real drag: push the selection text to PRIMARY so middle-click
        // paste works (Linux convention).
        if (self.terminal.screen.selection.isActive()) {
            const text = self.terminal.screen.extractSelection(self.allocator) catch return;
            defer self.allocator.free(text);
            if (text.len == 0) return;
            const cstr = self.allocator.allocSentinel(u8, text.len, 0) catch return;
            defer self.allocator.free(cstr);
            @memcpy(cstr, text);
            clipboard.copyToPrimary(@ptrCast(self.area), cstr);
        }
        return;
    }

    const event = c.gtk_event_controller_get_current_event(@ptrCast(g));
    if (event == null) return;
    const mods = c.gdk_event_get_modifier_state(event);
    if (mods & c.GDK_CONTROL_MASK == 0) return;

    var sx: f64 = 0;
    var sy: f64 = 0;
    _ = c.gtk_gesture_drag_get_start_point(g, &sx, &sy);
    const cell = self.cellAt(sx, sy);
    if (cell.row < 0 or cell.col < 0) return;
    const screen = self.terminal.screen;
    if (cell.row >= screen.rows or cell.col >= screen.cols) return;
    const cell_data = screen.cellAt(@intCast(cell.row), @intCast(cell.col));
    if (cell_data.flags & 0b0000_0100 == 0) return;

    if (screen.linkUri(cell_data.reserved)) |uri| {
        var buf: [4096]u8 = undefined;
        const n = @min(uri.len, buf.len - 1);
        @memcpy(buf[0..n], uri[0..n]);
        buf[n] = 0;
        _ = c.g_app_info_launch_default_for_uri(&buf, null, null);
    }
}

fn onScroll(_: *c.GtkEventControllerScroll, _: f64, dy: f64, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *Pane = @ptrCast(@alignCast(user.?));
    const screen = self.terminal.screen;

    // Apps in alt-screen + mouse mode (htop, vim, less, …) want
    // wheel events as mouse buttons 4 / 5. Send those instead of
    // adjusting the (irrelevant) scrollback view.
    if (screen.mouse_mode > 0 and screen.use_alt) {
        if (dy == 0) return 1;
        const button: u32 = if (dy < 0) 64 else 65; // 64 = btn4, 65 = btn5
        const row: i32 = if (self.last_motion_row >= 0) self.last_motion_row else 0;
        const col: i32 = if (self.last_motion_col >= 0) self.last_motion_col else 0;
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}M", .{
            button,
            @as(u32, @intCast(col + 1)),
            @as(u32, @intCast(row + 1)),
        }) catch return 1;
        _ = self.terminal.pty.writeAll(seq);
        return 1;
    }

    // Scroll up (negative dy) increases view_offset. 3 lines per click.
    const sb = screen.scrollbackCount();
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
    // Subtract pane padding (top+bottom, left+right) before computing
    // cell counts — otherwise we'd allocate cells that overflow the
    // visible content area.
    const pad: c_int = @intFromFloat(self.grid_pass.pad);
    const inner_w: c_int = @max(1, width - 2 * pad);
    const inner_h: c_int = @max(1, height - 2 * pad);
    const cols: u16 = @intCast(@max(1, @divFloor(inner_w, @as(c_int, atlas.cell_w))));
    const rows: u16 = @intCast(@max(1, @divFloor(inner_h, @as(c_int, atlas.cell_h))));
    if (cols == self.terminal.screen.cols and rows == self.terminal.screen.rows) return;

    self.terminal.screen.resize(cols, rows) catch return;
    self.terminal.pty.setSize(rows, cols);
}

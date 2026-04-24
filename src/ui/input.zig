//! Keyboard input → xterm byte encoding → PTY write.
//!
//! Subset implemented in M4. Full xterm spec + modifyOtherKeys=1
//! and CSI u progressive enhancement come later.

const std = @import("std");
const c = @import("../c.zig").c;
const Terminal = @import("../terminal.zig").Terminal;
const clipboard = @import("clipboard.zig");

pub const Ctx = struct {
    widget: *c.GtkWidget,
    terminal: *Terminal,
    /// Optional shortcut sink for tab/split/etc actions. May be null
    /// for top-level shortcuts handled elsewhere.
    shortcut_sink: ?*const fn (ctx: ?*anyopaque, action: Action) void = null,
    shortcut_ctx: ?*anyopaque = null,
};

pub const Action = enum {
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    copy,
    paste, // primary path; input also handles directly
};

pub fn attach(widget: *c.GtkWidget, terminal: *Terminal, allocator: std.mem.Allocator) !*Ctx {
    const ctx = try allocator.create(Ctx);
    ctx.* = .{ .widget = widget, .terminal = terminal };

    const ctrl = c.gtk_event_controller_key_new();
    _ = c.g_signal_connect_data(
        ctrl,
        "key-pressed",
        @ptrCast(&onKeyPressed),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(widget, @ptrCast(ctrl));

    c.gtk_widget_set_focusable(widget, 1);
    _ = c.gtk_widget_grab_focus(widget);
    return ctx;
}

fn onKeyPressed(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const ctrl_pressed = (state & c.GDK_CONTROL_MASK) != 0;
    const shift_pressed = (state & c.GDK_SHIFT_MASK) != 0;

    // Built-in keybindings (before generic encoding).
    if (ctrl_pressed and shift_pressed) {
        switch (keyval) {
            c.GDK_KEY_V, c.GDK_KEY_v => {
                clipboard.pasteFromClipboard(ctx.widget, ctx.terminal);
                return 1;
            },
            c.GDK_KEY_C, c.GDK_KEY_c => {
                copySelection(ctx);
                return 1;
            },
            c.GDK_KEY_T, c.GDK_KEY_t => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .new_tab);
                return 1;
            },
            c.GDK_KEY_W, c.GDK_KEY_w => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .close_tab);
                return 1;
            },
            else => {},
        }
    }
    if (ctrl_pressed and !shift_pressed) {
        if (keyval == c.GDK_KEY_Tab) {
            if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .next_tab);
            return 1;
        }
    }
    if (ctrl_pressed and shift_pressed and keyval == c.GDK_KEY_ISO_Left_Tab) {
        if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .prev_tab);
        return 1;
    }

    var buf: [16]u8 = undefined;
    const n = encode(&buf, keyval, state);
    if (n == 0) return 0;
    _ = ctx.terminal.pty.writeAll(buf[0..n]);
    return 1;
}

fn copySelection(ctx: *Ctx) void {
    const screen = ctx.terminal.screen;
    if (!screen.selection.isActive()) return;
    const text = screen.extractSelection(ctx.terminal.allocator) catch return;
    defer ctx.terminal.allocator.free(text);
    if (text.len == 0) return;

    // Copy to system clipboard.
    const display = c.gtk_widget_get_display(ctx.widget);
    const clip = c.gdk_display_get_clipboard(display);
    const cstr = ctx.terminal.allocator.allocSentinel(u8, text.len, 0) catch return;
    defer ctx.terminal.allocator.free(cstr);
    @memcpy(cstr, text);
    c.gdk_clipboard_set_text(clip, cstr.ptr);
}

fn encode(buf: []u8, keyval: c_uint, mods: c.GdkModifierType) usize {
    const ctrl = (mods & c.GDK_CONTROL_MASK) != 0;
    const alt = (mods & c.GDK_ALT_MASK) != 0;
    const shift = (mods & c.GDK_SHIFT_MASK) != 0;

    // Special keys (return early).
    switch (keyval) {
        c.GDK_KEY_Return => { buf[0] = '\r'; return 1; },
        c.GDK_KEY_BackSpace => { buf[0] = 0x7F; return 1; },
        c.GDK_KEY_Tab => {
            if (shift) { @memcpy(buf[0..3], "\x1b[Z"); return 3; }
            buf[0] = '\t';
            return 1;
        },
        c.GDK_KEY_ISO_Left_Tab => { @memcpy(buf[0..3], "\x1b[Z"); return 3; },
        c.GDK_KEY_Escape => { buf[0] = 0x1B; return 1; },
        c.GDK_KEY_Up => { @memcpy(buf[0..3], "\x1b[A"); return 3; },
        c.GDK_KEY_Down => { @memcpy(buf[0..3], "\x1b[B"); return 3; },
        c.GDK_KEY_Right => { @memcpy(buf[0..3], "\x1b[C"); return 3; },
        c.GDK_KEY_Left => { @memcpy(buf[0..3], "\x1b[D"); return 3; },
        c.GDK_KEY_Home => { @memcpy(buf[0..3], "\x1b[H"); return 3; },
        c.GDK_KEY_End => { @memcpy(buf[0..3], "\x1b[F"); return 3; },
        c.GDK_KEY_Page_Up => { @memcpy(buf[0..4], "\x1b[5~"); return 4; },
        c.GDK_KEY_Page_Down => { @memcpy(buf[0..4], "\x1b[6~"); return 4; },
        c.GDK_KEY_Insert => { @memcpy(buf[0..4], "\x1b[2~"); return 4; },
        c.GDK_KEY_Delete => { @memcpy(buf[0..4], "\x1b[3~"); return 4; },
        c.GDK_KEY_F1 => { @memcpy(buf[0..3], "\x1bOP"); return 3; },
        c.GDK_KEY_F2 => { @memcpy(buf[0..3], "\x1bOQ"); return 3; },
        c.GDK_KEY_F3 => { @memcpy(buf[0..3], "\x1bOR"); return 3; },
        c.GDK_KEY_F4 => { @memcpy(buf[0..3], "\x1bOS"); return 3; },
        c.GDK_KEY_F5 => { @memcpy(buf[0..5], "\x1b[15~"); return 5; },
        c.GDK_KEY_F6 => { @memcpy(buf[0..5], "\x1b[17~"); return 5; },
        c.GDK_KEY_F7 => { @memcpy(buf[0..5], "\x1b[18~"); return 5; },
        c.GDK_KEY_F8 => { @memcpy(buf[0..5], "\x1b[19~"); return 5; },
        c.GDK_KEY_F9 => { @memcpy(buf[0..5], "\x1b[20~"); return 5; },
        c.GDK_KEY_F10 => { @memcpy(buf[0..5], "\x1b[21~"); return 5; },
        c.GDK_KEY_F11 => { @memcpy(buf[0..5], "\x1b[23~"); return 5; },
        c.GDK_KEY_F12 => { @memcpy(buf[0..5], "\x1b[24~"); return 5; },
        else => {},
    }

    // Printable codepoint via gdk's keyval-to-unicode.
    const cp = c.gdk_keyval_to_unicode(keyval);
    if (cp == 0) return 0;

    // Ctrl + 0x40..0x7E → C0 control (Ctrl-A = 0x01, etc).
    if (ctrl and cp >= 0x40 and cp <= 0x7E) {
        const code: u8 = @intCast(cp & 0x1F);
        if (alt) {
            buf[0] = 0x1B;
            buf[1] = code;
            return 2;
        }
        buf[0] = code;
        return 1;
    }

    // Ctrl-Space → NUL.
    if (ctrl and cp == ' ') {
        buf[0] = 0;
        return 1;
    }

    // Alt + ASCII → ESC + char.
    if (alt and cp < 0x80) {
        buf[0] = 0x1B;
        buf[1] = @intCast(cp);
        return 2;
    }

    // Plain UTF-8.
    if (cp < 0x80) {
        buf[0] = @intCast(cp);
        return 1;
    }
    return std.unicode.utf8Encode(@intCast(cp), buf) catch 0;
}

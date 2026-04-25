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
    /// Input method for IME composition (fcitx5 / ibus).
    im_ctx: ?*c.GtkIMContext = null,
};

pub const Action = enum {
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    copy,
    paste,
    split_h,
    split_v,
};

pub fn attach(widget: *c.GtkWidget, terminal: *Terminal, allocator: std.mem.Allocator) !*Ctx {
    const ctx = try allocator.create(Ctx);
    ctx.* = .{ .widget = widget, .terminal = terminal };

    // IME: GtkIMMulticontext routes through fcitx5/ibus on Linux.
    const im = c.gtk_im_multicontext_new();
    c.gtk_im_context_set_client_widget(@ptrCast(im), widget);
    _ = c.g_signal_connect_data(
        im,
        "commit",
        @ptrCast(&onImCommit),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    _ = c.g_signal_connect_data(
        im,
        "preedit-changed",
        @ptrCast(&onImPreeditChanged),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    ctx.im_ctx = @ptrCast(im);

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

fn onImCommit(_: *c.GtkIMContext, text: [*:0]const u8, user: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const len = std.mem.len(text);
    if (len > 0) _ = ctx.terminal.pty.writeAll(text[0..len]);
    // Clear any preedit on commit.
    const screen = ctx.terminal.screen;
    if (screen.preedit_text) |old| {
        screen.allocator.free(old);
        screen.preedit_text = null;
        screen.dirty = true;
    }
}

fn onImPreeditChanged(im: *c.GtkIMContext, user: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    var str: [*c]u8 = null;
    var attrs: ?*c.PangoAttrList = null;
    var cur: c_int = 0;
    c.gtk_im_context_get_preedit_string(im, &str, &attrs, &cur);
    if (attrs) |a| c.pango_attr_list_unref(a);
    defer if (str != null) c.g_free(str);

    const screen = ctx.terminal.screen;
    if (screen.preedit_text) |old| screen.allocator.free(old);
    screen.preedit_text = null;
    if (str != null) {
        const slen = std.mem.len(@as([*:0]const u8, @ptrCast(str)));
        if (slen > 0) {
            screen.preedit_text = screen.allocator.dupe(u8, str[0..slen]) catch null;
        }
    }
    screen.dirty = true;
}

fn onKeyPressed(
    controller: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));

    // Let IME consume the key first (CJK composition).
    if (ctx.im_ctx) |im| {
        const event = c.gtk_event_controller_get_current_event(@ptrCast(controller));
        if (event != null and c.gtk_im_context_filter_keypress(im, @ptrCast(event)) != 0) {
            return 1;
        }
    }

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
            c.GDK_KEY_D, c.GDK_KEY_d => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .split_h);
                return 1;
            },
            c.GDK_KEY_R, c.GDK_KEY_r => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .split_v);
                return 1;
            },
            c.GDK_KEY_K, c.GDK_KEY_k => {
                // Clear screen + scrollback. Direct call — we're on
                // the main thread, the screen lives there too.
                ctx.terminal.screen.clearAndScrollback();
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

    // Shift+PgUp/PgDn = keyboard scrollback (xterm convention).
    if (shift_pressed and !ctrl_pressed) {
        const screen = ctx.terminal.screen;
        const sb: u32 = @intCast(screen.scrollbackCount());
        switch (keyval) {
            c.GDK_KEY_Page_Up => {
                const want = screen.view_offset + screen.rows;
                screen.view_offset = if (want > sb) sb else want;
                screen.dirty = true;
                return 1;
            },
            c.GDK_KEY_Page_Down => {
                screen.view_offset = if (screen.view_offset >= screen.rows)
                    screen.view_offset - screen.rows
                else
                    0;
                screen.dirty = true;
                return 1;
            },
            else => {},
        }
    }

    var buf: [16]u8 = undefined;
    const screen = ctx.terminal.screen;
    const n = encode(&buf, keyval, state, screen.app_cursor_keys);
    if (n == 0) return 0;
    // Snap to bottom on keypress (matches xterm/iterm2/etc behavior).
    if (screen.view_offset != 0) {
        screen.view_offset = 0;
        screen.dirty = true;
    }
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

/// xterm modifier encoding: 1 + shift(1) + alt(2) + ctrl(4).
fn modCode(shift: bool, alt: bool, ctrl: bool) u8 {
    return 1 + (if (shift) @as(u8, 1) else 0) + (if (alt) @as(u8, 2) else 0) + (if (ctrl) @as(u8, 4) else 0);
}

/// Cursor-key emit. Without modifiers: ESC [/O X. With modifiers:
/// always ESC [ 1 ; M X (no DECCKM swap, per xterm).
fn cursorKey(buf: []u8, ck: u8, final: u8, shift: bool, alt: bool, ctrl: bool) usize {
    const m = modCode(shift, alt, ctrl);
    if (m == 1) {
        buf[0] = 0x1B;
        buf[1] = ck;
        buf[2] = final;
        return 3;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ m, final }) catch return 0;
    return out.len;
}

/// "Tilde" key emit (PgUp/PgDn/Ins/Del, F5+). Plain: ESC [ N ~.
/// Modified: ESC [ N ; M ~.
fn tildeKey(buf: []u8, n: u8, shift: bool, alt: bool, ctrl: bool) usize {
    const m = modCode(shift, alt, ctrl);
    if (m == 1) {
        const out = std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch return 0;
        return out.len;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, m }) catch return 0;
    return out.len;
}

/// SS3 key emit (F1-F4). Plain: ESC O X. Modified: ESC [ 1 ; M X.
fn ssoKey(buf: []u8, final: u8, shift: bool, alt: bool, ctrl: bool) usize {
    const m = modCode(shift, alt, ctrl);
    if (m == 1) {
        buf[0] = 0x1B;
        buf[1] = 'O';
        buf[2] = final;
        return 3;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[1;{d}{c}", .{ m, final }) catch return 0;
    return out.len;
}

fn encode(buf: []u8, keyval: c_uint, mods: c.GdkModifierType, app_cursor: bool) usize {
    const ctrl = (mods & c.GDK_CONTROL_MASK) != 0;
    const alt = (mods & c.GDK_ALT_MASK) != 0;
    const shift = (mods & c.GDK_SHIFT_MASK) != 0;
    // DECCKM swap: arrows/home/end use ESC O X instead of ESC [ X.
    const ck: u8 = if (app_cursor) 'O' else '[';

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
        c.GDK_KEY_Up => return cursorKey(buf, ck, 'A', shift, alt, ctrl),
        c.GDK_KEY_Down => return cursorKey(buf, ck, 'B', shift, alt, ctrl),
        c.GDK_KEY_Right => return cursorKey(buf, ck, 'C', shift, alt, ctrl),
        c.GDK_KEY_Left => return cursorKey(buf, ck, 'D', shift, alt, ctrl),
        c.GDK_KEY_Home => return cursorKey(buf, ck, 'H', shift, alt, ctrl),
        c.GDK_KEY_End => return cursorKey(buf, ck, 'F', shift, alt, ctrl),
        c.GDK_KEY_Page_Up => return tildeKey(buf, 5, shift, alt, ctrl),
        c.GDK_KEY_Page_Down => return tildeKey(buf, 6, shift, alt, ctrl),
        c.GDK_KEY_Insert => return tildeKey(buf, 2, shift, alt, ctrl),
        c.GDK_KEY_Delete => return tildeKey(buf, 3, shift, alt, ctrl),
        c.GDK_KEY_F1 => return ssoKey(buf, 'P', shift, alt, ctrl),
        c.GDK_KEY_F2 => return ssoKey(buf, 'Q', shift, alt, ctrl),
        c.GDK_KEY_F3 => return ssoKey(buf, 'R', shift, alt, ctrl),
        c.GDK_KEY_F4 => return ssoKey(buf, 'S', shift, alt, ctrl),
        c.GDK_KEY_F5 => return tildeKey(buf, 15, shift, alt, ctrl),
        c.GDK_KEY_F6 => return tildeKey(buf, 17, shift, alt, ctrl),
        c.GDK_KEY_F7 => return tildeKey(buf, 18, shift, alt, ctrl),
        c.GDK_KEY_F8 => return tildeKey(buf, 19, shift, alt, ctrl),
        c.GDK_KEY_F9 => return tildeKey(buf, 20, shift, alt, ctrl),
        c.GDK_KEY_F10 => return tildeKey(buf, 21, shift, alt, ctrl),
        c.GDK_KEY_F11 => return tildeKey(buf, 23, shift, alt, ctrl),
        c.GDK_KEY_F12 => return tildeKey(buf, 24, shift, alt, ctrl),
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

test "cursorKey plain emits ESC [ X" {
    var buf: [16]u8 = undefined;
    const n = cursorKey(&buf, '[', 'A', false, false, false);
    try std.testing.expectEqualStrings("\x1b[A", buf[0..n]);
}

test "cursorKey app-mode emits ESC O X" {
    var buf: [16]u8 = undefined;
    const n = cursorKey(&buf, 'O', 'A', false, false, false);
    try std.testing.expectEqualStrings("\x1bOA", buf[0..n]);
}

test "cursorKey shift+ctrl modifier code 6" {
    var buf: [16]u8 = undefined;
    const n = cursorKey(&buf, '[', 'D', true, false, true);
    try std.testing.expectEqualStrings("\x1b[1;6D", buf[0..n]);
}

test "tildeKey alt modifier code 3" {
    var buf: [16]u8 = undefined;
    const n = tildeKey(&buf, 5, false, true, false);
    try std.testing.expectEqualStrings("\x1b[5;3~", buf[0..n]);
}

test "ssoKey plain F1 emits ESC O P" {
    var buf: [16]u8 = undefined;
    const n = ssoKey(&buf, 'P', false, false, false);
    try std.testing.expectEqualStrings("\x1bOP", buf[0..n]);
}

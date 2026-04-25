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
    /// Last keyval seen on key-pressed (for repeat detection — kitty
    /// kbd flag 0x02 emits event=2 on repeats vs event=1 on first
    /// press). Cleared on key-released so the next press is "fresh".
    last_press_keyval: c_uint = 0,
    last_press_time_us: i64 = 0,
};

/// Maximum gap between consecutive presses of the same keyval that
/// we still consider a hardware repeat (microseconds). Tuned higher
/// than typical OS auto-repeat (33–50 ms) but well below the time a
/// user takes to deliberately re-press a key. 120 ms.
const REPEAT_WINDOW_US: i64 = 120_000;

pub const Action = enum {
    new_tab,
    close_tab,
    next_tab,
    prev_tab,
    copy,
    paste,
    split_h,
    split_v,
    font_inc,
    font_dec,
    font_reset,
    search_open,
    save_layout,
    save_layout_as,
    prompt_prev,
    prompt_next,
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
    // Key-released — only emits to PTY when kitty kbd report-events
    // (flag 0x02) is enabled. Otherwise it's a no-op.
    _ = c.g_signal_connect_data(
        ctrl,
        "key-released",
        @ptrCast(&onKeyReleased),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(widget, @ptrCast(ctrl));

    c.gtk_widget_set_focusable(widget, 1);
    _ = c.gtk_widget_grab_focus(widget);
    return ctx;
}

/// Key-released handler. No-op unless kitty kbd report-events flag
/// (0x02) is enabled — most apps don't want release noise polluting
/// their PTY. When enabled, emits `CSI <kc>;<mods>:3 u`.
fn onKeyReleased(
    _: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    // Clear the repeat-detection memory so the next press is treated
    // as fresh (event=1). We track this regardless of whether kitty
    // reports are enabled so a later toggle gets clean state.
    if (ctx.last_press_keyval == keyval) {
        ctx.last_press_keyval = 0;
        ctx.last_press_time_us = 0;
    }

    const screen = ctx.terminal.screen;
    if ((screen.kitty_kbd_flags & 0x02) == 0) return;

    const ctrl = (state & c.GDK_CONTROL_MASK) != 0;
    const alt = (state & c.GDK_ALT_MASK) != 0;
    const shift = (state & c.GDK_SHIFT_MASK) != 0;

    // Map to the same canonical lowercase code point we use on press.
    var cp: u32 = 0;
    switch (keyval) {
        c.GDK_KEY_Escape => cp = 27,
        c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => cp = 13,
        c.GDK_KEY_BackSpace => cp = 127,
        c.GDK_KEY_Tab, c.GDK_KEY_ISO_Left_Tab => cp = 9,
        else => {
            const u = c.gdk_keyval_to_unicode(keyval);
            if (u == 0 or u >= 0x110000) return;
            cp = u;
            if (cp >= 'A' and cp <= 'Z') cp += 0x20;
        },
    }
    var buf: [32]u8 = undefined;
    const n = kittyKeyEvent(&buf, cp, shift, alt, ctrl, 3);
    if (n > 0) _ = ctx.terminal.pty.writeAll(buf[0..n]);
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

    // Detect auto-repeat by comparing against the last press of the
    // same keyval within REPEAT_WINDOW_US. Used by the kitty kbd
    // protocol when flag 0x02 (report-events) is enabled.
    const press_now = std.time.microTimestamp();
    const is_repeat = ctx.last_press_keyval == keyval and
        ctx.last_press_time_us != 0 and
        (press_now - ctx.last_press_time_us) < REPEAT_WINDOW_US;
    ctx.last_press_keyval = keyval;
    ctx.last_press_time_us = press_now;

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
            c.GDK_KEY_F, c.GDK_KEY_f => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .search_open);
                return 1;
            },
            c.GDK_KEY_S, c.GDK_KEY_s => {
                const alt_held = (state & c.GDK_ALT_MASK) != 0;
                if (ctx.shortcut_sink) |f| {
                    if (alt_held) f(ctx.shortcut_ctx, .save_layout_as)
                    else f(ctx.shortcut_ctx, .save_layout);
                }
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
        // Ctrl+- / Ctrl+= (typed as Ctrl+plus on US) / Ctrl+0
        switch (keyval) {
            c.GDK_KEY_minus, c.GDK_KEY_KP_Subtract => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .font_dec);
                return 1;
            },
            c.GDK_KEY_equal, c.GDK_KEY_plus, c.GDK_KEY_KP_Add => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .font_inc);
                return 1;
            },
            c.GDK_KEY_0, c.GDK_KEY_KP_0 => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .font_reset);
                return 1;
            },
            else => {},
        }
    }
    // Ctrl+Shift++ as a fallback for keyboards where + is shift+=.
    // Ctrl+Shift+Up/Down = OSC 133 prompt navigation.
    if (ctrl_pressed and shift_pressed) {
        switch (keyval) {
            c.GDK_KEY_plus => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .font_inc);
                return 1;
            },
            c.GDK_KEY_Up, c.GDK_KEY_KP_Up => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .prompt_prev);
                return 1;
            },
            c.GDK_KEY_Down, c.GDK_KEY_KP_Down => {
                if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, .prompt_next);
                return 1;
            },
            else => {},
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
    const n = encode(&buf, keyval, state, screen.app_cursor_keys, screen.modify_other_keys, screen.kitty_kbd_flags, is_repeat, screen.app_keypad);
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
pub fn modCode(shift: bool, alt: bool, ctrl: bool) u8 {
    return 1 + (if (shift) @as(u8, 1) else 0) + (if (alt) @as(u8, 2) else 0) + (if (ctrl) @as(u8, 4) else 0);
}

/// Cursor-key emit. Without modifiers: ESC [/O X. With modifiers:
/// always ESC [ 1 ; M X (no DECCKM swap, per xterm).
pub fn cursorKey(buf: []u8, ck: u8, final: u8, shift: bool, alt: bool, ctrl: bool) usize {
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
pub fn tildeKey(buf: []u8, n: u8, shift: bool, alt: bool, ctrl: bool) usize {
    const m = modCode(shift, alt, ctrl);
    if (m == 1) {
        const out = std.fmt.bufPrint(buf, "\x1b[{d}~", .{n}) catch return 0;
        return out.len;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[{d};{d}~", .{ n, m }) catch return 0;
    return out.len;
}

/// SS3 key emit (F1-F4). Plain: ESC O X. Modified: ESC [ 1 ; M X.
pub fn ssoKey(buf: []u8, final: u8, shift: bool, alt: bool, ctrl: bool) usize {
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

/// Kitty progressive-enhancement keyboard CSI u emit.
/// Format: `CSI <unicode-code-point> [; <mods>] u`. Mods follow the
/// xterm encoding (1 + shift+alt*2+ctrl*4) — same as modCode(). When
/// only Shift is "held", we still emit mods=2 here per kitty spec
/// (callers handle whether Shift suppresses CSI u for printable keys).
pub fn kittyKey(buf: []u8, code_point: u32, shift: bool, alt: bool, ctrl: bool) usize {
    return kittyKeyEvent(buf, code_point, shift, alt, ctrl, 1);
}

/// Variant that also encodes the event type per kitty kbd flag 0x02:
///   1 = press, 2 = repeat, 3 = release.
/// Press emits the same shape as `kittyKey`; repeat/release add the
/// `:<event>` sub-parameter. Apps that haven't enabled flag 0x02
/// should use the default `event = 1` form.
pub fn kittyKeyEvent(buf: []u8, code_point: u32, shift: bool, alt: bool, ctrl: bool, event: u8) usize {
    const m = modCode(shift, alt, ctrl);
    if (event == 1 and m == 1) {
        const out = std.fmt.bufPrint(buf, "\x1b[{d}u", .{code_point}) catch return 0;
        return out.len;
    }
    if (event == 1) {
        const out = std.fmt.bufPrint(buf, "\x1b[{d};{d}u", .{ code_point, m }) catch return 0;
        return out.len;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[{d};{d}:{d}u", .{ code_point, m, event }) catch return 0;
    return out.len;
}

fn encode(buf: []u8, keyval: c_uint, mods: c.GdkModifierType, app_cursor: bool, mok: u8, kitty_flags: u8, is_repeat: bool, app_keypad: bool) usize {
    const ctrl = (mods & c.GDK_CONTROL_MASK) != 0;
    const alt = (mods & c.GDK_ALT_MASK) != 0;
    const shift = (mods & c.GDK_SHIFT_MASK) != 0;

    // Application keypad mode (DECPAM): numpad keys emit `ESC O X`
    // sequences instead of plain digits / operators. xterm uses these
    // VT220 codes, which vim, less, etc. read for navigation.
    if (app_keypad) {
        const final: u8 = switch (keyval) {
            c.GDK_KEY_KP_0 => 'p',
            c.GDK_KEY_KP_1 => 'q',
            c.GDK_KEY_KP_2 => 'r',
            c.GDK_KEY_KP_3 => 's',
            c.GDK_KEY_KP_4 => 't',
            c.GDK_KEY_KP_5 => 'u',
            c.GDK_KEY_KP_6 => 'v',
            c.GDK_KEY_KP_7 => 'w',
            c.GDK_KEY_KP_8 => 'x',
            c.GDK_KEY_KP_9 => 'y',
            c.GDK_KEY_KP_Multiply => 'j',
            c.GDK_KEY_KP_Add => 'k',
            c.GDK_KEY_KP_Separator => 'l',
            c.GDK_KEY_KP_Subtract => 'm',
            c.GDK_KEY_KP_Decimal => 'n',
            c.GDK_KEY_KP_Divide => 'o',
            c.GDK_KEY_KP_Equal => 'X',
            c.GDK_KEY_KP_Enter => 'M',
            else => 0,
        };
        if (final != 0) {
            buf[0] = 0x1B;
            buf[1] = 'O';
            buf[2] = final;
            return 3;
        }
    }
    // DECCKM swap: arrows/home/end use ESC O X instead of ESC [ X.
    const ck: u8 = if (app_cursor) 'O' else '[';

    // Event type for kitty kbd encoder: 1 = press, 2 = repeat.
    // Repeats only emit when flag 0x02 (events) is enabled — outside
    // that flag, repeats look identical to fresh presses.
    const kitty_event: u8 = if ((kitty_flags & 0x02) != 0 and is_repeat) 2 else 1;

    // Kitty progressive-enhancement keyboard — disambiguate flag.
    // Reroute Tab/Enter/Esc/BS and modified keys through CSI u.
    const kitty_disamb = (kitty_flags & 0x01) != 0;
    if (kitty_disamb) {
        switch (keyval) {
            c.GDK_KEY_Escape => return kittyKeyEvent(buf, 27, shift, alt, ctrl, kitty_event),
            c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => return kittyKeyEvent(buf, 13, shift, alt, ctrl, kitty_event),
            c.GDK_KEY_BackSpace => return kittyKeyEvent(buf, 127, shift, alt, ctrl, kitty_event),
            c.GDK_KEY_Tab => return kittyKeyEvent(buf, 9, shift, alt, ctrl, kitty_event),
            c.GDK_KEY_ISO_Left_Tab => return kittyKeyEvent(buf, 9, true, alt, ctrl, kitty_event),
            else => {},
        }
        // Modified printable codepoints — emit CSI u so apps can
        // distinguish Ctrl+I from Tab and so on. Shift alone keeps the
        // literal-character path; the OS already gave us the upper-
        // case codepoint via gdk_keyval_to_unicode.
        if (ctrl or alt) {
            const cp_pre = c.gdk_keyval_to_unicode(keyval);
            if (cp_pre != 0 and cp_pre < 0x110000) {
                // Use the lowercase code point so 'A' and 'a' both
                // map to 'a' = 0x61, with Shift signalled via mods.
                var canon: u32 = cp_pre;
                if (canon >= 'A' and canon <= 'Z') canon += 0x20;
                return kittyKeyEvent(buf, canon, shift, alt, ctrl, kitty_event);
            }
        }
    }

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
        // modifyOtherKeys: emit `CSI 27 ; M ; cp ~` so apps can
        // distinguish e.g. Ctrl+i from TAB. Level 2 = always; level
        // 1 = only ambiguous (i, m, [, h, @).
        const ambiguous = (cp == 'I' or cp == 'i' or
            cp == 'M' or cp == 'm' or
            cp == '[' or
            cp == 'H' or cp == 'h' or
            cp == '@');
        if (mok == 2 or (mok == 1 and ambiguous)) {
            const m = modCode(shift, alt, ctrl);
            const out = std.fmt.bufPrint(buf, "\x1b[27;{d};{d}~", .{ m, cp }) catch return 0;
            return out.len;
        }
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

test "modCode encoding" {
    try std.testing.expectEqual(@as(u8, 1), modCode(false, false, false));
    try std.testing.expectEqual(@as(u8, 2), modCode(true, false, false));
    try std.testing.expectEqual(@as(u8, 3), modCode(false, true, false));
    try std.testing.expectEqual(@as(u8, 5), modCode(false, false, true));
    try std.testing.expectEqual(@as(u8, 8), modCode(true, true, true));
}

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
    /// Opaque back-pointer set by Pane.init right after attach. Used
    /// only by `mouse_autohide` so input can flip Pane's
    /// `cursor_hidden` flag without input.zig importing pane.zig.
    autohide_ctx: ?*anyopaque = null,
    autohide_set: ?*const fn (ctx: ?*anyopaque, hidden: bool) void = null,
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
    /// Smart-copy mode: if true and Ctrl+Shift+C is pressed with no
    /// selection, send Ctrl+C (0x03) to the child instead of being
    /// a no-op. Set from Config.smart_copy at attach time and on
    /// every applyConfigChange.
    smart_copy: bool = true,
    /// Drop the active selection after a Ctrl+Shift+C copy. Mirrors
    /// Config.clear_select_on_copy.
    clear_select_on_copy: bool = false,
    /// Hide the pointer over the widget while typing. Mirrors
    /// Config.mouse_autohide. The Pane's onMotion handler restores it.
    mouse_autohide: bool = true,
    /// Active keybinding table. Empty slice = use `default_bindings`.
    /// Window owns the storage (parsed from Config); Ctx just borrows.
    bindings: []const Binding = &.{},
};

/// Maximum gap between consecutive presses of the same keyval that
/// we still consider a hardware repeat (microseconds). Tuned higher
/// than typical OS auto-repeat (33–50 ms) but well below the time a
/// user takes to deliberately re-press a key. 120 ms.
const REPEAT_WINDOW_US: i64 = 120_000;

pub const Action = enum {
    // Window-level (dispatched via shortcut_sink to Window).
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
    /// Save the current tab/split layout as the user's default,
    /// auto-loaded on every subsequent cold start.
    save_default_layout,
    prompt_prev,
    prompt_next,
    pane_next,
    pane_prev,
    prefs_open,
    /// Cycle broadcast typing mode: off → group → all → off.
    broadcast_cycle,
    /// Re-open the most-recently-closed tab (browser convention).
    restore_closed_tab,
    /// Pin / unpin the current tab — pinned tabs sit in their own
    /// section at the start of the tab bar (AdwTabView native).
    toggle_pin_tab,
    /// Show / hide the entire tab bar — useful when working in
    /// single-tab mode where the bar is wasted vertical space.
    toggle_tab_bar,
    /// Re-load config.conf from disk + apply live (no restart).
    /// Honours XDG search path; --config override paths are not
    /// re-honoured (user would need to restart).
    reload_config,
    /// Spawn a new tab inheriting the focused pane's cwd + profile.
    /// Subtly different from `new_tab` which uses the focused pane's
    /// cwd already but defaults the profile to none.
    duplicate_tab,
    // Per-pane (dispatched locally inside input.zig).
    paste_clipboard,
    copy_selection,
    /// Copy the entire visible screen to the system clipboard.
    /// Useful when an app paints output without leaving it
    /// selectable (TUI dashboards, mosh+tmux mouse-mode, etc.).
    copy_screen,
    /// Copy the full scrollback ring + active screen. Soft-wraps
    /// preserved as logical lines (no extra newlines mid-output).
    copy_scrollback,
    interrupt_or_copy,
    clear_and_scrollback,
    /// Wipe the scrollback ring only — visible screen untouched.
    clear_scrollback,
    scrollback_page_up,
    scrollback_page_down,
    /// Jump to the oldest scrollback line (top of buffer).
    scrollback_top,
    /// Jump to the live screen position (view_offset = 0).
    scrollback_bottom,
};

/// One configured keybind: a (keyval, modifier-mask) → Action mapping.
pub const Binding = struct {
    keyval: c_uint,
    mods: c_uint,
    action: Action,
};

/// Default bindings table. Mirrors the prior hardcoded
/// `dispatchShortcut` switch. Config can override / add to these via
/// `keybind.<action>` entries; missing entries fall through here.
pub const default_bindings = [_]Binding{
    // Ctrl+Shift+...
    .{ .keyval = c.GDK_KEY_t, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .new_tab },
    .{ .keyval = c.GDK_KEY_w, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .close_tab },
    .{ .keyval = c.GDK_KEY_d, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .split_h },
    .{ .keyval = c.GDK_KEY_r, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .split_v },
    .{ .keyval = c.GDK_KEY_f, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .search_open },
    .{ .keyval = c.GDK_KEY_v, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .paste_clipboard },
    .{ .keyval = c.GDK_KEY_c, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .interrupt_or_copy },
    .{ .keyval = c.GDK_KEY_k, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .clear_and_scrollback },
    .{ .keyval = c.GDK_KEY_s, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .save_layout },
    .{ .keyval = c.GDK_KEY_s, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK, .action = .save_layout_as },
    .{ .keyval = c.GDK_KEY_Up, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .prompt_prev },
    .{ .keyval = c.GDK_KEY_Down, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .prompt_next },
    .{ .keyval = c.GDK_KEY_Left, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .pane_prev },
    .{ .keyval = c.GDK_KEY_Right, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .pane_next },
    .{ .keyval = c.GDK_KEY_ISO_Left_Tab, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .prev_tab },
    .{ .keyval = c.GDK_KEY_plus, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .font_inc },
    .{ .keyval = c.GDK_KEY_g, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .broadcast_cycle },
    .{ .keyval = c.GDK_KEY_z, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .restore_closed_tab },
    .{ .keyval = c.GDK_KEY_a, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .copy_screen },
    .{ .keyval = c.GDK_KEY_p, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .toggle_pin_tab },
    // Ctrl+...
    .{ .keyval = c.GDK_KEY_Tab, .mods = c.GDK_CONTROL_MASK, .action = .next_tab },
    .{ .keyval = c.GDK_KEY_minus, .mods = c.GDK_CONTROL_MASK, .action = .font_dec },
    .{ .keyval = c.GDK_KEY_KP_Subtract, .mods = c.GDK_CONTROL_MASK, .action = .font_dec },
    .{ .keyval = c.GDK_KEY_equal, .mods = c.GDK_CONTROL_MASK, .action = .font_inc },
    .{ .keyval = c.GDK_KEY_plus, .mods = c.GDK_CONTROL_MASK, .action = .font_inc },
    .{ .keyval = c.GDK_KEY_KP_Add, .mods = c.GDK_CONTROL_MASK, .action = .font_inc },
    .{ .keyval = c.GDK_KEY_0, .mods = c.GDK_CONTROL_MASK, .action = .font_reset },
    .{ .keyval = c.GDK_KEY_KP_0, .mods = c.GDK_CONTROL_MASK, .action = .font_reset },
    .{ .keyval = c.GDK_KEY_comma, .mods = c.GDK_CONTROL_MASK, .action = .prefs_open },
    // Shift+...
    .{ .keyval = c.GDK_KEY_Page_Up, .mods = c.GDK_SHIFT_MASK, .action = .scrollback_page_up },
    .{ .keyval = c.GDK_KEY_Page_Down, .mods = c.GDK_SHIFT_MASK, .action = .scrollback_page_down },
    .{ .keyval = c.GDK_KEY_Home, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .scrollback_top },
    .{ .keyval = c.GDK_KEY_End, .mods = c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK, .action = .scrollback_bottom },
};

/// Match a (keyval, modifier_state) against the binding table. Returns
/// the first match, or null. The caller pre-masks `state` to only the
/// modifier bits we care about (Ctrl/Shift/Alt/Super) — Lock + group
/// bits are noise and must be filtered.
pub fn matchBinding(bindings: []const Binding, keyval: c_uint, mods: c_uint) ?Action {
    const significant: c_uint =
        c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK | c.GDK_SUPER_MASK;
    const m = mods & significant;
    for (bindings) |b| {
        if (b.keyval == keyval and (b.mods & significant) == m) return b.action;
    }
    return null;
}

/// Modifier mask the binding matcher cares about. Lock and group
/// bits are filtered before comparison.
pub const SIGNIFICANT_MODS: c_uint =
    c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK | c.GDK_ALT_MASK | c.GDK_SUPER_MASK;

/// Convert an Action to its config-key string form. Stable across
/// versions — config files reference these names. Inverse: `actionFromName`.
pub fn actionName(a: Action) []const u8 {
    return switch (a) {
        .new_tab => "new_tab",
        .close_tab => "close_tab",
        .next_tab => "next_tab",
        .prev_tab => "prev_tab",
        .copy => "copy",
        .paste => "paste",
        .split_h => "split_h",
        .split_v => "split_v",
        .font_inc => "font_inc",
        .font_dec => "font_dec",
        .font_reset => "font_reset",
        .search_open => "search_open",
        .save_layout => "save_layout",
        .save_layout_as => "save_layout_as",
        .save_default_layout => "save_default_layout",
        .prompt_prev => "prompt_prev",
        .prompt_next => "prompt_next",
        .pane_next => "pane_next",
        .pane_prev => "pane_prev",
        .prefs_open => "prefs_open",
        .broadcast_cycle => "broadcast_cycle",
        .restore_closed_tab => "restore_closed_tab",
        .toggle_pin_tab => "toggle_pin_tab",
        .toggle_tab_bar => "toggle_tab_bar",
        .reload_config => "reload_config",
        .duplicate_tab => "duplicate_tab",
        .paste_clipboard => "paste_clipboard",
        .copy_selection => "copy_selection",
        .copy_screen => "copy_screen",
        .copy_scrollback => "copy_scrollback",
        .interrupt_or_copy => "interrupt_or_copy",
        .clear_and_scrollback => "clear_and_scrollback",
        .clear_scrollback => "clear_scrollback",
        .scrollback_page_up => "scrollback_page_up",
        .scrollback_page_down => "scrollback_page_down",
        .scrollback_top => "scrollback_top",
        .scrollback_bottom => "scrollback_bottom",
    };
}

pub fn actionFromName(name: []const u8) ?Action {
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

/// Human-friendly label for the prefs UI.
pub fn actionLabel(a: Action) []const u8 {
    return switch (a) {
        .new_tab => "New tab",
        .close_tab => "Close tab",
        .next_tab => "Next tab",
        .prev_tab => "Previous tab",
        .copy => "Copy",
        .paste => "Paste",
        .split_h => "Split horizontal",
        .split_v => "Split vertical",
        .font_inc => "Increase font size",
        .font_dec => "Decrease font size",
        .font_reset => "Reset font size",
        .search_open => "Open search",
        .save_layout => "Save layout",
        .save_layout_as => "Save layout as…",
        .save_default_layout => "Save layout as default",
        .prompt_prev => "Jump to previous prompt",
        .prompt_next => "Jump to next prompt",
        .pane_next => "Next pane",
        .pane_prev => "Previous pane",
        .prefs_open => "Open Preferences",
        .broadcast_cycle => "Broadcast typing (cycle)",
        .restore_closed_tab => "Re-open closed tab",
        .toggle_pin_tab => "Pin / unpin current tab",
        .toggle_tab_bar => "Show / hide tab bar",
        .reload_config => "Reload config from disk",
        .duplicate_tab => "Duplicate tab (cwd + profile)",
        .paste_clipboard => "Paste clipboard",
        .copy_selection => "Copy selection",
        .copy_screen => "Copy whole screen",
        .copy_scrollback => "Copy entire scrollback",
        .interrupt_or_copy => "Copy / interrupt (smart)",
        .clear_and_scrollback => "Clear screen + scrollback",
        .clear_scrollback => "Clear scrollback only",
        .scrollback_page_up => "Scroll back one page",
        .scrollback_page_down => "Scroll forward one page",
        .scrollback_top => "Jump to scrollback top",
        .scrollback_bottom => "Jump to scrollback bottom",
    };
}

/// Format a (keyval, mods) pair as a GTK accelerator string —
/// "<Control><Shift>t" — for prefs display + config persistence.
/// Caller-owned slice via `allocator`. Returns "" when keyval is 0
/// (= unbound).
pub fn accelToString(allocator: std.mem.Allocator, keyval: c_uint, mods: c_uint) ![]u8 {
    if (keyval == 0) return try allocator.dupe(u8, "");
    const ptr = c.gtk_accelerator_name(keyval, mods);
    if (ptr == null) return try allocator.dupe(u8, "");
    defer c.g_free(ptr);
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
    return try allocator.dupe(u8, s);
}

/// Parse a GTK accelerator string. Returns null on failure (e.g. the
/// user typed garbage in their config). Caller filters.
pub fn parseAccel(accel: []const u8) ?struct { keyval: c_uint, mods: c_uint } {
    if (accel.len == 0) return null;
    var z_buf: [256:0]u8 = undefined;
    if (accel.len >= z_buf.len) return null;
    @memcpy(z_buf[0..accel.len], accel);
    z_buf[accel.len] = 0;

    var kv: c_uint = 0;
    var m: c_uint = 0;
    if (c.gtk_accelerator_parse(&z_buf, &kv, &m) == 0) return null;
    if (kv == 0) return null;
    return .{ .keyval = c.gdk_keyval_to_lower(kv), .mods = m };
}

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
    if (n > 0) ctx.terminal.writeUserInput(buf[0..n]);
}

fn onImCommit(_: *c.GtkIMContext, text: [*:0]const u8, user: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const len = std.mem.len(text);
    if (len > 0) ctx.terminal.writeUserInput(text[0..len]);
    // Clear any preedit on commit.
    const screen = ctx.terminal.screen;
    if (screen.preedit_text) |old| {
        screen.allocator.free(old);
        screen.preedit_text = null;
        screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
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
    c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
}

fn onKeyPressed(
    controller: *c.GtkEventControllerKey,
    keyval: c_uint,
    _: c_uint,
    state: c.GdkModifierType,
    user: ?*anyopaque,
) callconv(.c) c.gboolean {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));

    // mouse_autohide: hide the pointer over the widget while typing.
    // The Pane's onMotion handler clears it again on next pointer
    // motion. Pure modifier keys (Shift/Ctrl/Alt/Super alone) are
    // skipped — those don't represent actual typing.
    if (ctx.mouse_autohide) switch (keyval) {
        c.GDK_KEY_Shift_L, c.GDK_KEY_Shift_R,
        c.GDK_KEY_Control_L, c.GDK_KEY_Control_R,
        c.GDK_KEY_Alt_L, c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L, c.GDK_KEY_Super_R,
        c.GDK_KEY_Hyper_L, c.GDK_KEY_Hyper_R,
        c.GDK_KEY_Meta_L, c.GDK_KEY_Meta_R,
        c.GDK_KEY_Caps_Lock, c.GDK_KEY_Num_Lock,
        => {},
        else => {
            c.gtk_widget_set_cursor_from_name(ctx.widget, "none");
            if (ctx.autohide_set) |f| f(ctx.autohide_ctx, true);
        },
    };

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

    // Keybinding match — lowercase the keyval first so 'C' and 'c'
    // (with/without Shift held) both hit the same binding. GTK4 emits
    // uppercase keysyms when Shift is held, but our default table
    // uses lowercase. Match both forms.
    const lower_kv: c_uint = c.gdk_keyval_to_lower(keyval);
    const bindings: []const Binding = if (ctx.bindings.len > 0) ctx.bindings else &default_bindings;
    if (matchBinding(bindings, lower_kv, state) orelse matchBinding(bindings, keyval, state)) |action| {
        return runAction(ctx, action);
    }

    var buf: [16]u8 = undefined;
    const screen = ctx.terminal.screen;
    const n = encode(&buf, keyval, state, screen.app_cursor_keys, screen.modify_other_keys, screen.kitty_kbd_flags, is_repeat, screen.app_keypad);
    if (n == 0) return 0;
    // Snap to bottom on keypress (matches xterm/iterm2/etc behavior).
    if (screen.view_offset != 0) {
        screen.view_offset = 0;
        screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
    }
    ctx.terminal.writeUserInput(buf[0..n]);
    return 1;
}

/// Execute a bound action. Returns 1 if handled (the input event
/// is consumed) so the caller doesn't fall through to byte encoding.
/// Per-pane actions handle themselves; Window-level actions go via
/// `shortcut_sink`.
fn runAction(ctx: *Ctx, action: Action) c.gboolean {
    switch (action) {
        // Per-pane (local).
        .paste_clipboard => {
            clipboard.pasteFromClipboard(ctx.widget, ctx.terminal);
            return 1;
        },
        .copy_selection => {
            copySelection(ctx);
            return 1;
        },
        .copy_screen => {
            copyScreen(ctx);
            return 1;
        },
        .copy_scrollback => {
            copyScrollback(ctx);
            return 1;
        },
        .interrupt_or_copy => {
            // smart_copy: no selection AND smart_copy on → forward
            // Ctrl+C (interrupt). Off → noop. Selection present →
            // copy. Matches the previous Ctrl+Shift+C behaviour.
            if (!ctx.terminal.screen.selection.isActive() and ctx.smart_copy) {
                ctx.terminal.writeUserInput(&[_]u8{0x03});
                return 1;
            }
            copySelection(ctx);
            return 1;
        },
        .clear_and_scrollback => {
            ctx.terminal.screen.clearAndScrollback();
            return 1;
        },
        .clear_scrollback => {
            ctx.terminal.screen.clearScrollbackOnly();
            return 1;
        },
        .scrollback_page_up => {
            const screen = ctx.terminal.screen;
            const sb: u32 = @intCast(screen.scrollbackCount());
            const want = screen.view_offset + screen.rows;
            screen.view_offset = if (want > sb) sb else want;
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        .scrollback_page_down => {
            const screen = ctx.terminal.screen;
            screen.view_offset = if (screen.view_offset >= screen.rows)
                screen.view_offset - screen.rows
            else
                0;
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        .scrollback_top => {
            const screen = ctx.terminal.screen;
            screen.view_offset = @intCast(screen.scrollbackCount());
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        .scrollback_bottom => {
            const screen = ctx.terminal.screen;
            screen.view_offset = 0;
            screen.dirty = true;
            c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
            return 1;
        },
        // Window-level: forward to the sink.
        else => {
            if (ctx.shortcut_sink) |f| f(ctx.shortcut_ctx, action);
            return 1;
        },
    }
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

    if (ctx.clear_select_on_copy) {
        screen.selection.clear();
        screen.dirty = true;
        c.gtk_gl_area_queue_render(@ptrCast(ctx.widget));
    }
}

fn copyScreen(ctx: *Ctx) void {
    const screen = ctx.terminal.screen;
    const text = screen.extractScreen(ctx.terminal.allocator) catch return;
    defer ctx.terminal.allocator.free(text);
    if (text.len == 0) return;

    const display = c.gtk_widget_get_display(ctx.widget);
    const clip = c.gdk_display_get_clipboard(display);
    const cstr = ctx.terminal.allocator.allocSentinel(u8, text.len, 0) catch return;
    defer ctx.terminal.allocator.free(cstr);
    @memcpy(cstr, text);
    c.gdk_clipboard_set_text(clip, cstr.ptr);
}

fn copyScrollback(ctx: *Ctx) void {
    const screen = ctx.terminal.screen;
    const text = screen.extractScrollback(ctx.terminal.allocator) catch return;
    defer ctx.terminal.allocator.free(text);
    if (text.len == 0) return;

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
    return kittyKeyEventFull(buf, code_point, 0, shift, alt, ctrl, event);
}

/// Full kitty CSI u emitter with optional alt-shifted codepoint
/// (kitty flag 0x04). When `alt_shifted == 0` the sub-parameter is
/// omitted and output matches `kittyKeyEvent`. Otherwise format is
/// `CSI <code>:<alt-shifted> [; <mods> [: <event>]] u`.
pub fn kittyKeyEventFull(buf: []u8, code_point: u32, alt_shifted: u32, shift: bool, alt: bool, ctrl: bool, event: u8) usize {
    return kittyKeyEventComplete(buf, code_point, alt_shifted, 0, shift, alt, ctrl, event);
}

/// Most general kitty CSI u emitter with optional associated-text
/// codepoint (kitty flag 0x10). Format:
///   `CSI <code>[:<alt>][;<mods>[:<event>]][;<text>] u`
/// When text is set the mods section is always emitted (possibly
/// empty `;;` when default mods=1), per kitty spec — apps parsing
/// the text section count semicolons.
pub fn kittyKeyEventComplete(
    buf: []u8,
    code_point: u32,
    alt_shifted: u32,
    associated_text: u32,
    shift: bool,
    alt: bool,
    ctrl: bool,
    event: u8,
) usize {
    const m = modCode(shift, alt, ctrl);
    const has_alt = alt_shifted != 0 and alt_shifted != code_point;
    const has_text = associated_text != 0;

    // Build the code section: <code>[:<alt>]
    var code_buf: [32]u8 = undefined;
    const code_part = if (has_alt)
        std.fmt.bufPrint(&code_buf, "{d}:{d}", .{ code_point, alt_shifted }) catch return 0
    else
        std.fmt.bufPrint(&code_buf, "{d}", .{code_point}) catch return 0;

    // Build the mods section: <mods>[:<event>], or empty when both
    // default (m=1, event=1) AND no text follows.
    var mods_buf: [16]u8 = undefined;
    const mods_part: []const u8 = blk: {
        if (m == 1 and event == 1) break :blk if (has_text) "" else "";
        if (event == 1) break :blk std.fmt.bufPrint(&mods_buf, "{d}", .{m}) catch return 0;
        break :blk std.fmt.bufPrint(&mods_buf, "{d}:{d}", .{ m, event }) catch return 0;
    };

    if (has_text) {
        const out = std.fmt.bufPrint(buf, "\x1b[{s};{s};{d}u", .{ code_part, mods_part, associated_text }) catch return 0;
        return out.len;
    }
    if (mods_part.len == 0) {
        const out = std.fmt.bufPrint(buf, "\x1b[{s}u", .{code_part}) catch return 0;
        return out.len;
    }
    const out = std.fmt.bufPrint(buf, "\x1b[{s};{s}u", .{ code_part, mods_part }) catch return 0;
    return out.len;
}

pub fn encode(buf: []u8, keyval: c_uint, mods: c.GdkModifierType, app_cursor: bool, mok: u8, kitty_flags: u8, is_repeat: bool, app_keypad: bool) usize {
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

    // Kitty progressive-enhancement keyboard — disambiguate flag
    // (0x01) reroutes Tab/Enter/Esc/BS and modified keys through
    // CSI u. Report-all-keys (0x08) implies disambiguate AND also
    // routes UNMODIFIED printables through CSI u (per kitty spec).
    const kitty_disamb = (kitty_flags & 0x01) != 0;
    const kitty_report_all = (kitty_flags & 0x08) != 0;
    if (kitty_disamb or kitty_report_all) {
        switch (keyval) {
            c.GDK_KEY_Escape => return kittyKeyEvent(buf, 27, shift, alt, ctrl, kitty_event),
            c.GDK_KEY_Return, c.GDK_KEY_KP_Enter => return kittyKeyEvent(buf, 13, shift, alt, ctrl, kitty_event),
            c.GDK_KEY_BackSpace => return kittyKeyEvent(buf, 127, shift, alt, ctrl, kitty_event),
            c.GDK_KEY_Tab => return kittyKeyEvent(buf, 9, shift, alt, ctrl, kitty_event),
            c.GDK_KEY_ISO_Left_Tab => return kittyKeyEvent(buf, 9, true, alt, ctrl, kitty_event),
            else => {},
        }

        // With report-all (0x08), functional keys switch to the
        // kitty Unicode-private-use codepoint table. Apps opting in
        // get a uniform CSI u stream; apps using only 0x01 keep the
        // legacy CSI A / SS3 P / CSI 5~ shapes.
        if (kitty_report_all) {
            const pua_cp: u32 = switch (keyval) {
                c.GDK_KEY_Up => 57352,
                c.GDK_KEY_Down => 57353,
                c.GDK_KEY_Right => 57351,
                c.GDK_KEY_Left => 57350,
                c.GDK_KEY_Home => 57356,
                c.GDK_KEY_End => 57357,
                c.GDK_KEY_Insert => 57348,
                c.GDK_KEY_Delete => 57349,
                c.GDK_KEY_Page_Up => 57354,
                c.GDK_KEY_Page_Down => 57355,
                c.GDK_KEY_F1 => 57364,
                c.GDK_KEY_F2 => 57365,
                c.GDK_KEY_F3 => 57366,
                c.GDK_KEY_F4 => 57367,
                c.GDK_KEY_F5 => 57368,
                c.GDK_KEY_F6 => 57369,
                c.GDK_KEY_F7 => 57370,
                c.GDK_KEY_F8 => 57371,
                c.GDK_KEY_F9 => 57372,
                c.GDK_KEY_F10 => 57373,
                c.GDK_KEY_F11 => 57374,
                c.GDK_KEY_F12 => 57375,
                else => 0,
            };
            if (pua_cp != 0) return kittyKeyEvent(buf, pua_cp, shift, alt, ctrl, kitty_event);
        }
        // Printable codepoints. Without report-all (0x08), only
        // modified keys get CSI u so plain typing stays as raw
        // bytes. With 0x08, every printable goes through CSI u
        // even unmodified — apps using the report-all level want
        // every keystroke as an escape so they can build full
        // keymap UIs (e.g. neovim with kitty-keyboard support).
        if (ctrl or alt or kitty_report_all) {
            const cp_pre = c.gdk_keyval_to_unicode(keyval);
            if (cp_pre != 0 and cp_pre < 0x110000) {
                // Use the lowercase code point so 'A' and 'a' both
                // map to 'a' = 0x61, with Shift signalled via mods.
                var canon: u32 = cp_pre;
                if (canon >= 'A' and canon <= 'Z') canon += 0x20;
                // Kitty flag 0x04 — alt-shifted as sub-parameter.
                // Conservative: only emit for ASCII letters where
                // shift→uppercase is layout-independent. Digits +
                // punctuation skipped (US-only assumption would
                // mislead non-US-layout users).
                const kitty_alt_keys = (kitty_flags & 0x04) != 0;
                const alt_shifted: u32 = if (kitty_alt_keys and canon >= 'a' and canon <= 'z')
                    canon - 0x20
                else
                    0;
                // Kitty flag 0x10 — associated text. Only emit when
                // the keystroke would produce text in normal mode:
                // unmodified printables (and Shift+letter for the
                // shifted glyph). Ctrl/Alt-modified keys produce
                // control bytes / nothing — emit no text.
                const kitty_assoc = (kitty_flags & 0x10) != 0;
                var assoc_text: u32 = 0;
                if (kitty_assoc and !ctrl and !alt) {
                    assoc_text = if (shift and canon >= 'a' and canon <= 'z')
                        canon - 0x20
                    else
                        cp_pre;
                }
                return kittyKeyEventComplete(buf, canon, alt_shifted, assoc_text, shift, alt, ctrl, kitty_event);
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

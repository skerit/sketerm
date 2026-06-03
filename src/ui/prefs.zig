//! Preferences dialog — AdwPreferencesDialog with one page per
//! configuration category. Built programmatically (no XML / Blueprint)
//! to match sketerm's "own the stack" philosophy.
//!
//! Each row's value-changed signal fires `applyToWindow` which pushes
//! the new value into every live pane, then writes the config back to
//! disk so the change persists across runs.
//!
//! Open via Ctrl+, or the right-click context menu.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Config = @import("../config.zig").Config;
const CursorShape = @import("../config.zig").CursorShape;
const ExitAction = @import("../config.zig").ExitAction;
const TabPosition = @import("../config.zig").TabPosition;

// Forward-declare the Window pointer type. We can't import window.zig
// directly without creating a cycle, so we receive it as anyopaque and
// cast on the apply boundary.
const WindowOpaque = anyopaque;

/// Apply callback: invoked whenever a row mutates. Receives the
/// Window pointer the dialog was opened against and a snapshot of the
/// new Config. The Window is responsible for pushing values into its
/// panes and persisting to disk.
pub const ApplyFn = *const fn (win: *WindowOpaque, new_cfg: *const Config) void;

const Ctx = struct {
    allocator: std.mem.Allocator,
    /// Owned strings duped from user input (font path, shell, word
    /// chars, …). Reaped when the dialog closes — independent of
    /// Window.config.arena which manages the long-lived strings.
    arena: std.heap.ArenaAllocator,
    win: *WindowOpaque,
    apply: ApplyFn,
    /// Working copy. Each row writes here, then we call `apply`.
    cfg: Config,

    fn ev(self: *Ctx) void {
        self.apply(self.win, &self.cfg);
    }

    fn dupe(self: *Ctx, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }
};

/// Open a modal preferences dialog rooted at `parent_window`. Caller
/// (Window) provides the apply callback that lives-updates state and
/// persists to disk. Memory: Ctx is heap-allocated; freed when the
/// dialog emits "closed".
pub fn open(
    allocator: std.mem.Allocator,
    parent_window: *c.GtkWindow,
    win_ptr: *WindowOpaque,
    initial: Config,
    apply: ApplyFn,
) !void {
    const ctx = try allocator.create(Ctx);
    ctx.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .win = win_ptr,
        .apply = apply,
        .cfg = initial,
    };

    const dialog = c.adw_preferences_dialog_new();
    // Free Ctx when the dialog goes away.
    _ = c.g_signal_connect_data(
        dialog,
        "closed",
        @ptrCast(&onClosed),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );

    appendPage(@ptrCast(@alignCast(dialog)), ctx, &appearancePage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &colorsPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &behaviorPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &renderingPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &windowPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &keybindsPage);

    c.adw_dialog_present(@ptrCast(@alignCast(dialog)), @ptrCast(parent_window));
}

fn onClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    ctx.arena.deinit();
    ctx.allocator.destroy(ctx);
}

const PageBuilder = *const fn (page: *c.AdwPreferencesPage, ctx: *Ctx) void;

fn appendPage(dialog: *c.AdwPreferencesDialog, ctx: *Ctx, builder: PageBuilder) void {
    const page = c.adw_preferences_page_new();
    builder(@ptrCast(@alignCast(page)), ctx);
    c.adw_preferences_dialog_add(dialog, @ptrCast(@alignCast(page)));
}

// ── Appearance page ─────────────────────────────────────────────

fn appearancePage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Appearance");
    c.adw_preferences_page_set_icon_name(page, "preferences-desktop-font-symbolic");

    const font_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(font_group)), "Font");
    addFontPathRow(@ptrCast(@alignCast(font_group)), ctx);
    addSpinRowU16(@ptrCast(@alignCast(font_group)), ctx, "Size", "Font size in points", 6, 72, &ctx.cfg.font_size, fontSizeChanged);
    addSpinRowI16(@ptrCast(@alignCast(font_group)), ctx, "Line spacing", "Extra pixels per cell row", -8, 24, &ctx.cfg.line_pad_px, linePadChanged);
    addSpinRowF32(@ptrCast(@alignCast(font_group)), ctx, "Padding", "Inner padding around the cell grid", 0.0, 32.0, &ctx.cfg.padding, paddingChanged);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(font_group)));

    const cursor_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(cursor_group)), "Cursor");
    addCursorShapeRow(@ptrCast(@alignCast(cursor_group)), ctx);
    addSwitchRow(@ptrCast(@alignCast(cursor_group)), ctx, "Blink", "Toggle cursor visibility periodically", &ctx.cfg.cursor_blink, cursorBlinkChanged);
    addSpinRowU32(@ptrCast(@alignCast(cursor_group)), ctx, "Blink interval (ms)", "Half-cycle. 500 = full blink every 1 s.", 100, 2000, &ctx.cfg.cursor_blink_ms, cursorBlinkMsChanged);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(cursor_group)));

    // Per-pane title bar (Terminator-style).
    const tb_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(tb_group)), "Per-pane title bar");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(tb_group)), "Thin label above each pane carrying the OSC 0/1/2 title.");
    addSwitchRow(@ptrCast(@alignCast(tb_group)), ctx, "Show title bar", "Reveal a per-pane title bar.", &ctx.cfg.show_titlebar, applyOnly);
    addColorRow(@ptrCast(@alignCast(tb_group)), ctx, "Active foreground", &ctx.cfg.title_active_fg);
    addColorRow(@ptrCast(@alignCast(tb_group)), ctx, "Active background", &ctx.cfg.title_active_bg);
    addColorRow(@ptrCast(@alignCast(tb_group)), ctx, "Inactive foreground", &ctx.cfg.title_inactive_fg);
    addColorRow(@ptrCast(@alignCast(tb_group)), ctx, "Inactive background", &ctx.cfg.title_inactive_bg);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(tb_group)));

    // Inactive pane dimming.
    const dim_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(dim_group)), "Inactive pane dimming");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(dim_group)), "Multiply unfocused panes' colours. 1.0 = no dim. Defaults match Terminator (fg 0.8, bg 1.0).");
    addSpinRowF32Step(@ptrCast(@alignCast(dim_group)), ctx, "Foreground dim", "Multiplier for text + decorations.", 0.0, 1.0, 0.05, 2, &ctx.cfg.inactive_fg_dim, applyOnly);
    addSpinRowF32Step(@ptrCast(@alignCast(dim_group)), ctx, "Background dim", "Multiplier for cell backgrounds.", 0.0, 1.0, 0.05, 2, &ctx.cfg.inactive_bg_dim, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(dim_group)));

    // Background opacity (Wayland transparency).
    const bg_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(bg_group)), "Background");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(bg_group)), "Window-level transparency. Wayland with compositor support only. Once toggled below 1.0, returning to 1.0 may require a window restart.");
    addSpinRowF32Step(@ptrCast(@alignCast(bg_group)), ctx, "Opacity", "1.0 = opaque; 0.0 = fully transparent.", 0.0, 1.0, 0.05, 2, &ctx.cfg.background_opacity, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(bg_group)));
}

// ── Generic row helpers ─────────────────────────────────────────

const SpinU16Ctx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *u16,
    on_change: *const fn (*Ctx) void,
};
const SpinU32Ctx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *u32,
    on_change: *const fn (*Ctx) void,
};
const SpinI16Ctx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *i16,
    on_change: *const fn (*Ctx) void,
};
const SpinF32Ctx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *f32,
    on_change: *const fn (*Ctx) void,
};
const SwitchCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *bool,
    on_change: *const fn (*Ctx) void,
};
const ComboCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    on_change: *const fn (*Ctx, c_uint) void,
};

fn addSpinRowU16(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    lo: f64,
    hi: f64,
    field: *u16,
    on_change: *const fn (*Ctx) void,
) void {
    const adj = c.gtk_adjustment_new(@floatFromInt(field.*), lo, hi, 1, 1, 0);
    const row = c.adw_spin_row_new(adj, 1, 0);
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    const sctx = ctx.allocator.create(SpinU16Ctx) catch return;
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinU16Changed), @ptrCast(sctx), @ptrCast(&freeSpinU16Ctx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinU16Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SpinU16Ctx, user);
    const v = c.adw_spin_row_get_value(spin);
    sctx.field.* = @intFromFloat(@max(0.0, v));
    sctx.on_change(sctx.parent);
}

fn freeSpinU16Ctx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const sctx: *SpinU16Ctx = @ptrCast(@alignCast(u));
        sctx.allocator.destroy(sctx);
    }
}

fn addSpinRowU32(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    lo: f64,
    hi: f64,
    field: *u32,
    on_change: *const fn (*Ctx) void,
) void {
    const adj = c.gtk_adjustment_new(@floatFromInt(field.*), lo, hi, 1, 10, 0);
    const row = c.adw_spin_row_new(adj, 1, 0);
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    const sctx = ctx.allocator.create(SpinU32Ctx) catch return;
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinU32Changed), @ptrCast(sctx), @ptrCast(&freeSpinU32Ctx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinU32Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SpinU32Ctx, user);
    const v = c.adw_spin_row_get_value(spin);
    sctx.field.* = @intFromFloat(@max(0.0, v));
    sctx.on_change(sctx.parent);
}

fn freeSpinU32Ctx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const sctx: *SpinU32Ctx = @ptrCast(@alignCast(u));
        sctx.allocator.destroy(sctx);
    }
}

fn addSpinRowI16(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    lo: f64,
    hi: f64,
    field: *i16,
    on_change: *const fn (*Ctx) void,
) void {
    const adj = c.gtk_adjustment_new(@floatFromInt(field.*), lo, hi, 1, 1, 0);
    const row = c.adw_spin_row_new(adj, 1, 0);
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    const sctx = ctx.allocator.create(SpinI16Ctx) catch return;
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinI16Changed), @ptrCast(sctx), @ptrCast(&freeSpinI16Ctx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinI16Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SpinI16Ctx, user);
    const v = c.adw_spin_row_get_value(spin);
    sctx.field.* = @intFromFloat(v);
    sctx.on_change(sctx.parent);
}

fn freeSpinI16Ctx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const sctx: *SpinI16Ctx = @ptrCast(@alignCast(u));
        sctx.allocator.destroy(sctx);
    }
}

fn addSpinRowF32(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    lo: f64,
    hi: f64,
    field: *f32,
    on_change: *const fn (*Ctx) void,
) void {
    addSpinRowF32Step(group, ctx, title, subtitle, lo, hi, 0.5, 1, field, on_change);
}

fn addSpinRowF32Step(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    lo: f64,
    hi: f64,
    step: f64,
    digits: c_uint,
    field: *f32,
    on_change: *const fn (*Ctx) void,
) void {
    const adj = c.gtk_adjustment_new(field.*, lo, hi, step, step * 10.0, 0);
    const row = c.adw_spin_row_new(adj, step, digits);
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    const sctx = ctx.allocator.create(SpinF32Ctx) catch return;
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinF32Changed), @ptrCast(sctx), @ptrCast(&freeSpinF32Ctx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinF32Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SpinF32Ctx, user);
    const v: f32 = @floatCast(c.adw_spin_row_get_value(spin));
    sctx.field.* = v;
    sctx.on_change(sctx.parent);
}

fn freeSpinF32Ctx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const sctx: *SpinF32Ctx = @ptrCast(@alignCast(u));
        sctx.allocator.destroy(sctx);
    }
}

fn addSwitchRow(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    field: *bool,
    on_change: *const fn (*Ctx) void,
) void {
    const row = c.adw_switch_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    c.adw_switch_row_set_active(@ptrCast(@alignCast(row)), if (field.*) 1 else 0);
    const sctx = ctx.allocator.create(SwitchCtx) catch return;
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "notify::active", @ptrCast(&switchChanged), @ptrCast(sctx), @ptrCast(&freeSwitchCtx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn switchChanged(row: *c.AdwSwitchRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SwitchCtx, user);
    sctx.field.* = c.adw_switch_row_get_active(row) != 0;
    sctx.on_change(sctx.parent);
}

fn freeSwitchCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const sctx: *SwitchCtx = @ptrCast(@alignCast(u));
        sctx.allocator.destroy(sctx);
    }
}

// ── Cursor shape combo ──────────────────────────────────────────

fn addCursorShapeRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Block", "Underline", "Bar" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Shape");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Block, underline or vertical bar");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    const initial: c_uint = switch (ctx.cfg.cursor_shape) {
        .block => 0,
        .underline => 1,
        .bar => 2,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = cursorShapeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(&freeComboCtx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn comboChanged(row: *c.AdwComboRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const cctx = cast.userData(ComboCtx, user);
    cctx.on_change(cctx.parent, c.adw_combo_row_get_selected(row));
}

fn freeComboCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const cctx: *ComboCtx = @ptrCast(@alignCast(u));
        cctx.allocator.destroy(cctx);
    }
}

fn cursorShapeSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.cursor_shape = switch (idx) {
        0 => .block,
        1 => .underline,
        2 => .bar,
        else => .block,
    };
    ctx.ev();
}

// ── Font path row (file chooser) ────────────────────────────────

fn addFontPathRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Font file");
    const sub = if (ctx.cfg.font_path) |fp| fp else "(default search path)";
    var z: [512:0]u8 = undefined;
    const n = @min(sub.len, z.len);
    @memcpy(z[0..n], sub[0..n]);
    z[n] = 0;
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), &z);
    const btn = c.gtk_button_new_with_label("Choose…");
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onChooseFont), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
    // Stash row + button so we can update the subtitle on selection.
    c.g_object_set_data(@ptrCast(@alignCast(btn)), "sketerm-row", @ptrCast(row));
}

fn onChooseFont(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const dialog = c.gtk_file_dialog_new();
    c.gtk_file_dialog_set_title(dialog, "Select font file (.ttf / .otf)");
    const root = c.gtk_widget_get_root(@ptrCast(btn));
    c.gtk_file_dialog_open(dialog, @ptrCast(@alignCast(root)), null, @ptrCast(&onChooseFontDone), @ptrCast(ctx));
}

fn onChooseFontDone(source: *c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const file = c.gtk_file_dialog_open_finish(@ptrCast(@alignCast(source)), result, null) orelse return;
    defer c.g_object_unref(@ptrCast(@alignCast(file)));
    const path_z = c.g_file_get_path(file) orelse return;
    defer c.g_free(path_z);
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(path_z)));
    // Owned via Config.arena (allocator-independent: dupe into our
    // Ctx allocator since the working cfg in the dialog has no arena
    // — apply path will arena-dupe on persist).
    const dup = ctx.dupe(slice) catch return;
    ctx.cfg.font_path = dup;
    ctx.ev();
}

// ── Per-field apply hooks ───────────────────────────────────────

fn fontSizeChanged(ctx: *Ctx) void {
    ctx.ev();
}
fn linePadChanged(ctx: *Ctx) void {
    ctx.ev();
}
fn paddingChanged(ctx: *Ctx) void {
    ctx.ev();
}
fn cursorBlinkChanged(ctx: *Ctx) void {
    ctx.ev();
}
fn cursorBlinkMsChanged(ctx: *Ctx) void {
    ctx.ev();
}

// ── Colors page ────────────────────────────────────────────────

const schemes = @import("../grid/schemes.zig");
const SCHEMES = schemes.all;

const PaletteRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    index: usize, // 0..15
};

const ColorRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *[4]f32,
};

fn colorsPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Colors");
    c.adw_preferences_page_set_icon_name(page, "preferences-color-symbolic");

    // Scheme picker.
    const scheme_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(scheme_group)), "Scheme");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(scheme_group)), "Picking a scheme overwrites the foreground / background / palette below.");
    addSchemeRow(@ptrCast(@alignCast(scheme_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(scheme_group)));

    // Defaults (fg / bg / cursor + auto-theme + cursor_color_default).
    const defaults_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(defaults_group)), "Defaults");
    addColorRow(@ptrCast(@alignCast(defaults_group)), ctx, "Foreground", &ctx.cfg.default_fg);
    addColorRow(@ptrCast(@alignCast(defaults_group)), ctx, "Background", &ctx.cfg.default_bg);
    addColorRow(@ptrCast(@alignCast(defaults_group)), ctx, "Cursor", &ctx.cfg.cursor_color);
    addSwitchRow(@ptrCast(@alignCast(defaults_group)), ctx, "Cursor uses foreground", "Override the explicit cursor colour with the foreground.", &ctx.cfg.cursor_color_default, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(defaults_group)), ctx, "Auto theme", "Follow Adwaita dark/light at runtime.", &ctx.cfg.auto_theme, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(defaults_group)));

    // 16-colour palette in an expander row.
    const palette_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(palette_group)), "ANSI palette (16 colours)");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(palette_group)), "Per-index colours used by SGR 30-37 / 40-47 (and bright 90-97). Editing here unsets `scheme` so your tweaks stick.");
    var i: usize = 0;
    while (i < 16) : (i += 1) addPaletteRow(@ptrCast(@alignCast(palette_group)), ctx, i);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(palette_group)));
}

fn addColorRow(group: *c.AdwPreferencesGroup, ctx: *Ctx, title: [*:0]const u8, field: *[4]f32) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);

    const dlg = c.gtk_color_dialog_new();
    const btn = c.gtk_color_dialog_button_new(dlg);
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    var rgba: c.GdkRGBA = .{ .red = field[0], .green = field[1], .blue = field[2], .alpha = field[3] };
    c.gtk_color_dialog_button_set_rgba(@ptrCast(@alignCast(btn)), &rgba);

    const cctx = ctx.allocator.create(ColorRowCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field };
    _ = c.g_signal_connect_data(btn, "notify::rgba", @ptrCast(&colorRowChanged), @ptrCast(cctx), @ptrCast(&freeColorRowCtx), c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn colorRowChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const cctx = cast.userData(ColorRowCtx, user);
    const rgba = c.gtk_color_dialog_button_get_rgba(btn);
    cctx.field.* = .{ rgba.*.red, rgba.*.green, rgba.*.blue, rgba.*.alpha };
    cctx.parent.ev();
}

fn freeColorRowCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const cctx: *ColorRowCtx = @ptrCast(@alignCast(u));
        cctx.allocator.destroy(cctx);
    }
}

fn addPaletteRow(group: *c.AdwPreferencesGroup, ctx: *Ctx, idx: usize) void {
    const row = c.adw_action_row_new();
    var title_buf: [32:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "Color {d}", .{idx}) catch "Color";
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title.ptr);

    // Pull current value: prefer cfg.palette override; else scheme;
    // else built-in default 256-table first 16.
    const default_pal = @import("../grid/palette.zig").default_256;
    const cur: [3]u8 = if (ctx.cfg.palette) |p| p[idx] else default_pal[idx];

    const dlg = c.gtk_color_dialog_new();
    const btn = c.gtk_color_dialog_button_new(dlg);
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    var rgba: c.GdkRGBA = .{
        .red = @as(f32, @floatFromInt(cur[0])) / 255.0,
        .green = @as(f32, @floatFromInt(cur[1])) / 255.0,
        .blue = @as(f32, @floatFromInt(cur[2])) / 255.0,
        .alpha = 1.0,
    };
    c.gtk_color_dialog_button_set_rgba(@ptrCast(@alignCast(btn)), &rgba);

    const pctx = ctx.allocator.create(PaletteRowCtx) catch return;
    pctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .index = idx };
    _ = c.g_signal_connect_data(btn, "notify::rgba", @ptrCast(&paletteRowChanged), @ptrCast(pctx), @ptrCast(&freePaletteRowCtx), c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn paletteRowChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const pctx = cast.userData(PaletteRowCtx, user);
    const rgba = c.gtk_color_dialog_button_get_rgba(btn);
    // Promote palette to override mode if needed (copying from
    // current effective palette).
    if (pctx.parent.cfg.palette == null) {
        const default_pal = @import("../grid/palette.zig").default_256;
        var pal: [16][3]u8 = undefined;
        var i: usize = 0;
        while (i < 16) : (i += 1) pal[i] = default_pal[i];
        pctx.parent.cfg.palette = pal;
    }
    var pal = pctx.parent.cfg.palette.?;
    pal[pctx.index] = .{
        @intFromFloat(@round(rgba.*.red * 255.0)),
        @intFromFloat(@round(rgba.*.green * 255.0)),
        @intFromFloat(@round(rgba.*.blue * 255.0)),
    };
    pctx.parent.cfg.palette = pal;
    // Editing the palette unsets `scheme` — the user has overridden.
    pctx.parent.cfg.scheme = "";
    pctx.parent.ev();
}

fn freePaletteRowCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const pctx: *PaletteRowCtx = @ptrCast(@alignCast(u));
        pctx.allocator.destroy(pctx);
    }
}

fn addSchemeRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items_array = blk: {
        // null-terminated [*:0]?[*:0]const u8 list.
        var arr: [SCHEMES.len + 1]?[*:0]const u8 = undefined;
        for (SCHEMES, 0..) |sch, i| arr[i] = sch.label.ptr;
        arr[SCHEMES.len] = null;
        break :blk arr;
    };
    var arr_local = items_array;
    const items = c.gtk_string_list_new(@ptrCast(&arr_local));
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Built-in scheme");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    var sel: c_uint = 0;
    for (SCHEMES, 0..) |sch, i| {
        if (std.mem.eql(u8, sch.key, ctx.cfg.scheme)) {
            sel = @intCast(i);
            break;
        }
    }
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), sel);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = schemeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(&freeComboCtx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn schemeSelected(ctx: *Ctx, idx: c_uint) void {
    if (idx >= SCHEMES.len) return;
    const sch = SCHEMES[idx];
    ctx.cfg.scheme = sch.key;
    ctx.cfg.default_fg = .{
        @as(f32, @floatFromInt(sch.fg[0])) / 255.0,
        @as(f32, @floatFromInt(sch.fg[1])) / 255.0,
        @as(f32, @floatFromInt(sch.fg[2])) / 255.0,
        1.0,
    };
    ctx.cfg.default_bg = .{
        @as(f32, @floatFromInt(sch.bg[0])) / 255.0,
        @as(f32, @floatFromInt(sch.bg[1])) / 255.0,
        @as(f32, @floatFromInt(sch.bg[2])) / 255.0,
        1.0,
    };
    ctx.cfg.palette = sch.palette;
    ctx.ev();
    // Note: the open color buttons in the dialog don't auto-refresh
    // their preview swatches. The next reopen will reflect the new
    // values. Live-applying a re-paint to the preview swatches would
    // require holding pointers to every GtkColorDialogButton — for
    // v1 the user can just close and reopen if they care about the
    // visual swatch in this dialog.
}

fn applyOnly(ctx: *Ctx) void {
    ctx.ev();
}

// ── Behavior page ──────────────────────────────────────────────

fn behaviorPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Behavior");
    c.adw_preferences_page_set_icon_name(page, "preferences-system-symbolic");

    // Shell — note: applies to NEW panes, not running shells.
    const shell_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(shell_group)), "Shell (applies to new panes)");
    addShellPathRow(@ptrCast(@alignCast(shell_group)), ctx);
    addEntryRowOptionalString(@ptrCast(@alignCast(shell_group)), ctx, "TERM", "$TERM env in child", &ctx.cfg.term_env, termEnvChanged);
    addEntryRowOptionalString(@ptrCast(@alignCast(shell_group)), ctx, "COLORTERM", "$COLORTERM env in child", &ctx.cfg.color_term_env, colorTermEnvChanged);
    addSwitchRow(@ptrCast(@alignCast(shell_group)), ctx, "Login shell", "Prepend a `-` to argv[0] so the shell sources login profile.", &ctx.cfg.login_shell, applyOnly);
    addExitActionRow(@ptrCast(@alignCast(shell_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(shell_group)));

    // Input.
    const input_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(input_group)), "Input");
    addSwitchRow(@ptrCast(@alignCast(input_group)), ctx, "Bracketed paste", "Wrap pasted text in DECSET 2004 markers.", &ctx.cfg.bracketed_paste, applyOnly);
    addModifyOtherKeysRow(@ptrCast(@alignCast(input_group)), ctx);
    addEntryRowString(@ptrCast(@alignCast(input_group)), ctx, "Word characters", "Chars considered part of a word for double-click selection.", &ctx.cfg.word_chars, wordCharsChanged);
    addSwitchRow(@ptrCast(@alignCast(input_group)), ctx, "Smart copy", "Ctrl+Shift+C with no selection forwards Ctrl+C.", &ctx.cfg.smart_copy, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(input_group)));

    // Scrollback.
    const sb_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(sb_group)), "Scrollback");
    addSpinRowU32(@ptrCast(@alignCast(sb_group)), ctx, "Lines", "Maximum scrollback lines retained per pane.", 100, 100000, &ctx.cfg.scrollback, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(sb_group)), ctx, "Scroll on output", "Snap view to bottom on any output, not just keystrokes.", &ctx.cfg.scroll_on_output, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(sb_group)));

    // Mouse.
    const mouse_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(mouse_group)), "Mouse");
    addSwitchRow(@ptrCast(@alignCast(mouse_group)), ctx, "Auto-hide cursor", "Hide pointer while typing; reappears on motion.", &ctx.cfg.mouse_autohide, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(mouse_group)), ctx, "Copy on selection", "Copy the selection to the system clipboard automatically.", &ctx.cfg.copy_on_selection, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(mouse_group)), ctx, "Clear selection after copy", "Drop the highlighted selection after Ctrl+Shift+C.", &ctx.cfg.clear_select_on_copy, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(mouse_group)), ctx, "Disable middle-click paste", "Ignore middle-click PRIMARY paste entirely.", &ctx.cfg.disable_mouse_paste, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(mouse_group)), ctx, "Disable Ctrl+wheel zoom", "Ctrl+wheel won't change the font size.", &ctx.cfg.disable_mousewheel_zoom, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(mouse_group)), ctx, "Single-click hyperlinks", "OSC 8 hyperlinks open on plain click instead of Ctrl+click.", &ctx.cfg.link_single_click, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(mouse_group)), ctx, "Auto-detect URLs", "Underline + open plain http(s) URLs in cell content.", &ctx.cfg.auto_url_detect, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(mouse_group)));

    // Search.
    const search_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(search_group)), "Search");
    addSwitchRow(@ptrCast(@alignCast(search_group)), ctx, "Case sensitive default", "Skip smart-case; treat every search as case-sensitive.", &ctx.cfg.search_case_sensitive, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(search_group)));

    // Bold.
    const bold_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(bold_group)), "Bold");
    addSwitchRow(@ptrCast(@alignCast(bold_group)), ctx, "Allow bold", "Honour the bold attribute (font weight + bright color).", &ctx.cfg.allow_bold, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(bold_group)), ctx, "Bold is bright", "Bold text uses bright palette 8..15 instead of normal 0..7.", &ctx.cfg.bold_is_bright, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(bold_group)));
}

const StringFieldCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *[]const u8,
    on_change: *const fn (*Ctx) void,
};

fn addEntryRowString(group: *c.AdwPreferencesGroup, ctx: *Ctx, title: [*:0]const u8, subtitle: [*:0]const u8, field: *[]const u8, on_change: *const fn (*Ctx) void) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    _ = subtitle; // AdwEntryRow doesn't support subtitle; the field's title carries semantics.
    var z: [256:0]u8 = undefined;
    const n = @min(field.*.len, z.len);
    @memcpy(z[0..n], field.*[0..n]);
    z[n] = 0;
    c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    const sctx = ctx.allocator.create(StringFieldCtx) catch return;
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&entryStringChanged), @ptrCast(sctx), @ptrCast(&freeStringFieldCtx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn entryStringChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(StringFieldCtx, user);
    const txt = c.gtk_editable_get_text(row);
    if (txt == null) return;
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
    const dup = sctx.parent.dupe(slice) catch return;
    sctx.field.* = dup;
    sctx.on_change(sctx.parent);
}

fn freeStringFieldCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const sctx: *StringFieldCtx = @ptrCast(@alignCast(u));
        sctx.allocator.destroy(sctx);
    }
}

fn addEntryRowOptionalString(group: *c.AdwPreferencesGroup, ctx: *Ctx, title: [*:0]const u8, subtitle: [*:0]const u8, field: *[]const u8, on_change: *const fn (*Ctx) void) void {
    addEntryRowString(group, ctx, title, subtitle, field, on_change);
}

fn addShellPathRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Shell");
    if (ctx.cfg.shell) |s| {
        var z: [256:0]u8 = undefined;
        const n = @min(s.len, z.len);
        @memcpy(z[0..n], s[0..n]);
        z[n] = 0;
        c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    }
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&shellEntryChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn shellEntryChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const txt = c.gtk_editable_get_text(row);
    if (txt == null) return;
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
    if (slice.len == 0) {
        ctx.cfg.shell = null;
    } else {
        const dup = ctx.dupe(slice) catch return;
        ctx.cfg.shell = dup;
    }
    ctx.ev();
}

fn termEnvChanged(ctx: *Ctx) void {
    ctx.ev();
}
fn colorTermEnvChanged(ctx: *Ctx) void {
    ctx.ev();
}
fn wordCharsChanged(ctx: *Ctx) void {
    ctx.ev();
}

fn addModifyOtherKeysRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Off", "Basic (xterm 1)", "Full (xterm 2)" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "modifyOtherKeys");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Send Ctrl/Alt + alphabetic keys as CSI u sequences.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), ctx.cfg.modify_other_keys);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = modifyOtherKeysSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(&freeComboCtx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn modifyOtherKeysSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.modify_other_keys = @intCast(@min(idx, 2));
    ctx.ev();
}

fn addExitActionRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Close pane", "Restart shell", "Hold (show exit status)" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "On shell exit");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    const initial: c_uint = switch (ctx.cfg.exit_action) {
        .close => 0,
        .restart => 1,
        .hold => 2,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = exitActionSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(&freeComboCtx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn exitActionSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.exit_action = switch (idx) {
        0 => .close,
        1 => .restart,
        2 => .hold,
        else => .close,
    };
    ctx.ev();
}

// ── Rendering page ─────────────────────────────────────────────

fn renderingPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Rendering");
    // Bundled (hicolor) icon: the stock applications-graphics-symbolic
    // isn't delivered by every icon-theme chain (white-square fallback
    // on custom themes inheriting breeze).
    c.adw_preferences_page_set_icon_name(page, "sketerm-rendering-symbolic");

    const text_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(text_group)), "Text");
    addSwitchRow(@ptrCast(@alignCast(text_group)), ctx, "Ligatures", "HarfBuzz shaping for programming-font ligatures (Fira Code, JetBrains Mono, …).", &ctx.cfg.ligatures, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(text_group)), ctx, "Bidi", "Hebrew / Arabic / Indic reorder via fribidi. Pure-ASCII rows skip this for free.", &ctx.cfg.bidi, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(text_group)));

    const bell_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(bell_group)), "Bell");
    addSwitchRow(@ptrCast(@alignCast(bell_group)), ctx, "Audible (system beep)", "Fire gdk_display_beep on BEL. Off by default.", &ctx.cfg.bell_audible, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(bell_group)), ctx, "Visible flash", "Briefly flash the affected pane on BEL.", &ctx.cfg.bell_visible, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(bell_group)), ctx, "Tab needs-attention", "Non-focused tabs get an attention indicator.", &ctx.cfg.bell_urgent, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(bell_group)));
}

// ── Window page ────────────────────────────────────────────────

fn windowPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Window");
    c.adw_preferences_page_set_icon_name(page, "view-grid-symbolic");

    const tabs_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(tabs_group)), "Tabs");
    addTabPositionRow(@ptrCast(@alignCast(tabs_group)), ctx);
    addSwitchRow(@ptrCast(@alignCast(tabs_group)), ctx, "New tab after current", "Insert new tabs immediately after the focused one.", &ctx.cfg.new_tab_after_current, applyOnly);
    // close_button_on_tab is in the schema but not in the UI: AdwTabView
    // doesn't expose a global close-button toggle and per-page tweaks
    // would need to walk every page on every change. Revisit when
    // libadwaita gains a property for it.
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(tabs_group)));

    const stack_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(stack_group)), "Stacking");
    addSwitchRow(@ptrCast(@alignCast(stack_group)), ctx, "Always on top", "Best effort: GTK4 has no native API; use compositor window rules. (See terminal output for hints.)", &ctx.cfg.always_on_top, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(stack_group)));

    // Confirm-on-close.
    const close_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(close_group)), "Closing");
    addConfirmCloseRow(@ptrCast(@alignCast(close_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(close_group)));
}

fn addConfirmCloseRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Never", "If multiple panes", "Always" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Confirm before closing");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Show a dialog before destroying tabs / windows.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    const initial: c_uint = switch (ctx.cfg.confirm_close) {
        .never => 0,
        .multiple => 1,
        .always => 2,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = confirmCloseSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(&freeComboCtx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn confirmCloseSelected(ctx: *Ctx, sel: c_uint) void {
    ctx.cfg.confirm_close = switch (sel) {
        0 => .never,
        1 => .multiple,
        2 => .always,
        else => .multiple,
    };
    ctx.ev();
}

fn addTabPositionRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Top", "Bottom" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Position");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    const initial: c_uint = switch (ctx.cfg.tab_position) {
        .top => 0,
        .bottom => 1,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = tabPositionSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(&freeComboCtx), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn tabPositionSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.tab_position = if (idx == 1) .bottom else .top;
    ctx.ev();
}

// ── Keybinds page ──────────────────────────────────────────────

const input_mod = @import("input.zig");

const KeybindRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    action: input_mod.Action,
    button: *c.GtkButton,
    /// Captures the next keypress when "Press a key…" is active.
    capture_ctrl: ?*c.GtkEventController = null,
    /// True while waiting for a key. Esc cancels; Backspace clears.
    capturing: bool = false,
};

fn keybindsPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Keybindings");
    c.adw_preferences_page_set_icon_name(page, "input-keyboard-symbolic");

    const group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(group)), "Keybindings");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)),
        "Click an action's button to record a new shortcut. Esc cancels; " ++
        "Backspace unbinds. Conflicts log a warning to stderr.");
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(group)));

    inline for (@typeInfo(input_mod.Action).@"enum".fields) |field| {
        const action: input_mod.Action = @enumFromInt(field.value);
        addKeybindRow(@ptrCast(@alignCast(group)), ctx, action);
    }
}

fn addKeybindRow(group: *c.AdwPreferencesGroup, ctx: *Ctx, action: input_mod.Action) void {
    const row = c.adw_action_row_new();
    var label_buf: [64:0]u8 = undefined;
    const lbl = input_mod.actionLabel(action);
    const lbl_len = @min(lbl.len, label_buf.len - 1);
    @memcpy(label_buf[0..lbl_len], lbl[0..lbl_len]);
    label_buf[lbl_len] = 0;
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), &label_buf);

    const button = c.gtk_button_new();
    c.gtk_widget_set_valign(button, c.GTK_ALIGN_CENTER);
    c.gtk_widget_add_css_class(button, "flat");
    c.gtk_widget_set_size_request(button, 180, -1);

    const rctx = ctx.allocator.create(KeybindRowCtx) catch return;
    rctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .action = action, .button = @ptrCast(@alignCast(button)) };

    refreshKeybindButtonLabel(rctx);

    _ = c.g_signal_connect_data(button, "clicked", @ptrCast(&onKeybindClicked), @ptrCast(rctx), @ptrCast(&freeKeybindRowCtx), c.G_CONNECT_DEFAULT);

    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), button);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn refreshKeybindButtonLabel(rctx: *KeybindRowCtx) void {
    // Look up the active accel for this action: config override
    // wins, otherwise default_bindings.
    const action_name = input_mod.actionName(rctx.action);
    var accel: []const u8 = "";
    var found_in_config = false;
    for (rctx.parent.cfg.keybinds.items) |kb| {
        if (std.mem.eql(u8, kb.name, action_name)) {
            accel = kb.accel;
            found_in_config = true;
            break;
        }
    }
    if (!found_in_config) {
        // Fall back to first matching default.
        for (input_mod.default_bindings) |b| {
            if (b.action == rctx.action) {
                const s = input_mod.accelToString(rctx.parent.allocator, b.keyval, b.mods) catch return;
                defer rctx.parent.allocator.free(s);
                setButtonLabel(rctx.button, s);
                return;
            }
        }
        setButtonLabel(rctx.button, "(unbound)");
        return;
    }
    if (accel.len == 0) {
        setButtonLabel(rctx.button, "(unbound)");
        return;
    }
    setButtonLabel(rctx.button, accel);
}

fn setButtonLabel(button: *c.GtkButton, text: []const u8) void {
    var z: [128:0]u8 = undefined;
    const n = @min(text.len, z.len - 1);
    @memcpy(z[0..n], text[0..n]);
    z[n] = 0;
    c.gtk_button_set_label(button, &z);
}

fn freeKeybindRowCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const rctx: *KeybindRowCtx = @ptrCast(@alignCast(u));
        rctx.allocator.destroy(rctx);
    }
}

fn onKeybindClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(KeybindRowCtx, user);
    if (rctx.capturing) return;
    rctx.capturing = true;
    setButtonLabel(rctx.button, "Press a key…");

    const ctrl = c.gtk_event_controller_key_new();
    rctx.capture_ctrl = @ptrCast(@alignCast(ctrl));
    _ = c.g_signal_connect_data(
        ctrl,
        "key-pressed",
        @ptrCast(&onKeybindCapture),
        @ptrCast(rctx),
        null,
        c.G_CONNECT_DEFAULT,
    );
    c.gtk_widget_add_controller(@ptrCast(rctx.button), @ptrCast(ctrl));
    _ = c.gtk_widget_grab_focus(@ptrCast(rctx.button));
}

fn onKeybindCapture(_: *c.GtkEventControllerKey, keyval: c_uint, _: c_uint, state: c.GdkModifierType, user: ?*anyopaque) callconv(.c) c.gboolean {
    const rctx = cast.userData(KeybindRowCtx, user);
    if (!rctx.capturing) return 0;

    // Esc cancels — restore the previous label, no change.
    if (keyval == c.GDK_KEY_Escape) {
        finishCapture(rctx);
        return 1;
    }
    // Backspace unbinds.
    if (keyval == c.GDK_KEY_BackSpace) {
        setKeybind(rctx, "");
        finishCapture(rctx);
        return 1;
    }
    // Modifier-only keys ignored; wait for the actual key.
    switch (keyval) {
        c.GDK_KEY_Shift_L, c.GDK_KEY_Shift_R,
        c.GDK_KEY_Control_L, c.GDK_KEY_Control_R,
        c.GDK_KEY_Alt_L, c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L, c.GDK_KEY_Super_R,
        c.GDK_KEY_Hyper_L, c.GDK_KEY_Hyper_R,
        c.GDK_KEY_Meta_L, c.GDK_KEY_Meta_R,
        => return 1,
        else => {},
    }
    // Build the accelerator string.
    const lower = c.gdk_keyval_to_lower(keyval);
    const sig = input_mod.SIGNIFICANT_MODS;
    const accel = input_mod.accelToString(rctx.parent.allocator, lower, state & sig) catch {
        finishCapture(rctx);
        return 1;
    };
    defer rctx.parent.allocator.free(accel);
    setKeybind(rctx, accel);
    finishCapture(rctx);
    return 1;
}

fn finishCapture(rctx: *KeybindRowCtx) void {
    rctx.capturing = false;
    if (rctx.capture_ctrl) |ctrl| {
        c.gtk_widget_remove_controller(@ptrCast(rctx.button), @ptrCast(ctrl));
        rctx.capture_ctrl = null;
    }
    refreshKeybindButtonLabel(rctx);
}

/// Set or replace the override for this action in ctx.cfg.keybinds.
/// `accel` is borrowed; we dup into the prefs arena.
fn setKeybind(rctx: *KeybindRowCtx, accel: []const u8) void {
    const arena = rctx.parent.arena.allocator();
    const action_name = input_mod.actionName(rctx.action);
    const accel_dup = arena.dupe(u8, accel) catch return;

    // Replace existing entry, or append.
    for (rctx.parent.cfg.keybinds.items) |*entry| {
        if (std.mem.eql(u8, entry.name, action_name)) {
            entry.accel = accel_dup;
            rctx.parent.ev();
            return;
        }
    }
    const name_dup = arena.dupe(u8, action_name) catch return;
    rctx.parent.cfg.keybinds.append(rctx.parent.allocator, .{
        .name = name_dup,
        .accel = accel_dup,
    }) catch return;
    rctx.parent.ev();
}

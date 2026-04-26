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
    win: *WindowOpaque,
    apply: ApplyFn,
    /// Working copy. Each row writes here, then we call `apply`.
    cfg: Config,

    fn ev(self: *Ctx) void {
        self.apply(self.win, &self.cfg);
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

    c.adw_dialog_present(@ptrCast(@alignCast(dialog)), @ptrCast(parent_window));
}

fn onClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
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
}

// ── Generic row helpers ─────────────────────────────────────────

const SpinU16Ctx = struct {
    parent: *Ctx,
    field: *u16,
    on_change: *const fn (*Ctx) void,
};
const SpinU32Ctx = struct {
    parent: *Ctx,
    field: *u32,
    on_change: *const fn (*Ctx) void,
};
const SpinI16Ctx = struct {
    parent: *Ctx,
    field: *i16,
    on_change: *const fn (*Ctx) void,
};
const SpinF32Ctx = struct {
    parent: *Ctx,
    field: *f32,
    on_change: *const fn (*Ctx) void,
};
const SwitchCtx = struct {
    parent: *Ctx,
    field: *bool,
    on_change: *const fn (*Ctx) void,
};
const ComboCtx = struct {
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
    sctx.* = .{ .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinU16Changed), @ptrCast(sctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinU16Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx: *SpinU16Ctx = @ptrCast(@alignCast(user.?));
    const v = c.adw_spin_row_get_value(spin);
    sctx.field.* = @intFromFloat(@max(0.0, v));
    sctx.on_change(sctx.parent);
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
    sctx.* = .{ .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinU32Changed), @ptrCast(sctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinU32Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx: *SpinU32Ctx = @ptrCast(@alignCast(user.?));
    const v = c.adw_spin_row_get_value(spin);
    sctx.field.* = @intFromFloat(@max(0.0, v));
    sctx.on_change(sctx.parent);
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
    sctx.* = .{ .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinI16Changed), @ptrCast(sctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinI16Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx: *SpinI16Ctx = @ptrCast(@alignCast(user.?));
    const v = c.adw_spin_row_get_value(spin);
    sctx.field.* = @intFromFloat(v);
    sctx.on_change(sctx.parent);
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
    const adj = c.gtk_adjustment_new(field.*, lo, hi, 0.5, 1.0, 0);
    const row = c.adw_spin_row_new(adj, 0.5, 1);
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    const sctx = ctx.allocator.create(SpinF32Ctx) catch return;
    sctx.* = .{ .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinF32Changed), @ptrCast(sctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinF32Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx: *SpinF32Ctx = @ptrCast(@alignCast(user.?));
    const v: f32 = @floatCast(c.adw_spin_row_get_value(spin));
    sctx.field.* = v;
    sctx.on_change(sctx.parent);
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
    sctx.* = .{ .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "notify::active", @ptrCast(&switchChanged), @ptrCast(sctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn switchChanged(row: *c.AdwSwitchRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const sctx: *SwitchCtx = @ptrCast(@alignCast(user.?));
    sctx.field.* = c.adw_switch_row_get_active(row) != 0;
    sctx.on_change(sctx.parent);
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
    cctx.* = .{ .parent = ctx, .on_change = cursorShapeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn comboChanged(row: *c.AdwComboRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const cctx: *ComboCtx = @ptrCast(@alignCast(user.?));
    cctx.on_change(cctx.parent, c.adw_combo_row_get_selected(row));
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
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const dialog = c.gtk_file_dialog_new();
    c.gtk_file_dialog_set_title(dialog, "Select font file (.ttf / .otf)");
    const root = c.gtk_widget_get_root(@ptrCast(btn));
    c.gtk_file_dialog_open(dialog, @ptrCast(@alignCast(root)), null, @ptrCast(&onChooseFontDone), @ptrCast(ctx));
}

fn onChooseFontDone(source: *c.GObject, result: *c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    const file = c.gtk_file_dialog_open_finish(@ptrCast(@alignCast(source)), result, null) orelse return;
    defer c.g_object_unref(@ptrCast(@alignCast(file)));
    const path_z = c.g_file_get_path(file) orelse return;
    defer c.g_free(path_z);
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(path_z)));
    // Owned via Config.arena (allocator-independent: dupe into our
    // Ctx allocator since the working cfg in the dialog has no arena
    // — apply path will arena-dupe on persist).
    const dup = ctx.allocator.dupe(u8, slice) catch return;
    if (ctx.cfg.font_path) |old| ctx.allocator.free(@constCast(old));
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

/// Each scheme = (display name, fg, bg, 16 palette entries).
/// Picked to roughly match Terminator's defaults plus a few extras.
const Scheme = struct {
    key: [:0]const u8,
    label: [:0]const u8,
    fg: [3]u8,
    bg: [3]u8,
    palette: [16][3]u8,
};

const SCHEMES = [_]Scheme{
    .{
        .key = "sketerm",
        .label = "sketerm (default)",
        .fg = .{ 0xea, 0xea, 0xea },
        .bg = .{ 0x1a, 0x1a, 0x1a },
        .palette = .{
            .{ 0x00, 0x00, 0x00 }, .{ 0xcc, 0x00, 0x00 }, .{ 0x4e, 0x9a, 0x06 }, .{ 0xc4, 0xa0, 0x00 },
            .{ 0x34, 0x65, 0xa4 }, .{ 0x75, 0x50, 0x7b }, .{ 0x06, 0x98, 0x9a }, .{ 0xd3, 0xd7, 0xcf },
            .{ 0x55, 0x57, 0x53 }, .{ 0xef, 0x29, 0x29 }, .{ 0x8a, 0xe2, 0x34 }, .{ 0xfc, 0xe9, 0x4f },
            .{ 0x72, 0x9f, 0xcf }, .{ 0xad, 0x7f, 0xa8 }, .{ 0x34, 0xe2, 0xe2 }, .{ 0xee, 0xee, 0xec },
        },
    },
    .{
        .key = "tango",
        .label = "Tango",
        .fg = .{ 0xff, 0xff, 0xff },
        .bg = .{ 0x00, 0x00, 0x00 },
        .palette = .{
            .{ 0x00, 0x00, 0x00 }, .{ 0xcc, 0x00, 0x00 }, .{ 0x4e, 0x9a, 0x06 }, .{ 0xc4, 0xa0, 0x00 },
            .{ 0x34, 0x65, 0xa4 }, .{ 0x75, 0x50, 0x7b }, .{ 0x06, 0x98, 0x9a }, .{ 0xd3, 0xd7, 0xcf },
            .{ 0x55, 0x57, 0x53 }, .{ 0xef, 0x29, 0x29 }, .{ 0x8a, 0xe2, 0x34 }, .{ 0xfc, 0xe9, 0x4f },
            .{ 0x72, 0x9f, 0xcf }, .{ 0xad, 0x7f, 0xa8 }, .{ 0x34, 0xe2, 0xe2 }, .{ 0xee, 0xee, 0xec },
        },
    },
    .{
        .key = "solarized_dark",
        .label = "Solarized Dark",
        .fg = .{ 0x83, 0x94, 0x96 },
        .bg = .{ 0x00, 0x2b, 0x36 },
        .palette = .{
            .{ 0x07, 0x36, 0x42 }, .{ 0xdc, 0x32, 0x2f }, .{ 0x85, 0x99, 0x00 }, .{ 0xb5, 0x89, 0x00 },
            .{ 0x26, 0x8b, 0xd2 }, .{ 0xd3, 0x36, 0x82 }, .{ 0x2a, 0xa1, 0x98 }, .{ 0xee, 0xe8, 0xd5 },
            .{ 0x00, 0x2b, 0x36 }, .{ 0xcb, 0x4b, 0x16 }, .{ 0x58, 0x6e, 0x75 }, .{ 0x65, 0x7b, 0x83 },
            .{ 0x83, 0x94, 0x96 }, .{ 0x6c, 0x71, 0xc4 }, .{ 0x93, 0xa1, 0xa1 }, .{ 0xfd, 0xf6, 0xe3 },
        },
    },
    .{
        .key = "solarized_light",
        .label = "Solarized Light",
        .fg = .{ 0x65, 0x7b, 0x83 },
        .bg = .{ 0xfd, 0xf6, 0xe3 },
        .palette = .{
            .{ 0x07, 0x36, 0x42 }, .{ 0xdc, 0x32, 0x2f }, .{ 0x85, 0x99, 0x00 }, .{ 0xb5, 0x89, 0x00 },
            .{ 0x26, 0x8b, 0xd2 }, .{ 0xd3, 0x36, 0x82 }, .{ 0x2a, 0xa1, 0x98 }, .{ 0xee, 0xe8, 0xd5 },
            .{ 0x00, 0x2b, 0x36 }, .{ 0xcb, 0x4b, 0x16 }, .{ 0x58, 0x6e, 0x75 }, .{ 0x65, 0x7b, 0x83 },
            .{ 0x83, 0x94, 0x96 }, .{ 0x6c, 0x71, 0xc4 }, .{ 0x93, 0xa1, 0xa1 }, .{ 0xfd, 0xf6, 0xe3 },
        },
    },
    .{
        .key = "gruvbox_dark",
        .label = "Gruvbox Dark",
        .fg = .{ 0xeb, 0xdb, 0xb2 },
        .bg = .{ 0x28, 0x28, 0x28 },
        .palette = .{
            .{ 0x28, 0x28, 0x28 }, .{ 0xcc, 0x24, 0x1d }, .{ 0x98, 0x97, 0x1a }, .{ 0xd7, 0x99, 0x21 },
            .{ 0x45, 0x85, 0x88 }, .{ 0xb1, 0x62, 0x86 }, .{ 0x68, 0x9d, 0x6a }, .{ 0xa8, 0x99, 0x84 },
            .{ 0x92, 0x83, 0x74 }, .{ 0xfb, 0x49, 0x34 }, .{ 0xb8, 0xbb, 0x26 }, .{ 0xfa, 0xbd, 0x2f },
            .{ 0x83, 0xa5, 0x98 }, .{ 0xd3, 0x86, 0x9b }, .{ 0x8e, 0xc0, 0x7c }, .{ 0xeb, 0xdb, 0xb2 },
        },
    },
    .{
        .key = "gruvbox_light",
        .label = "Gruvbox Light",
        .fg = .{ 0x3c, 0x38, 0x36 },
        .bg = .{ 0xfb, 0xf1, 0xc7 },
        .palette = .{
            .{ 0xfb, 0xf1, 0xc7 }, .{ 0xcc, 0x24, 0x1d }, .{ 0x98, 0x97, 0x1a }, .{ 0xd7, 0x99, 0x21 },
            .{ 0x45, 0x85, 0x88 }, .{ 0xb1, 0x62, 0x86 }, .{ 0x68, 0x9d, 0x6a }, .{ 0x7c, 0x6f, 0x64 },
            .{ 0x92, 0x83, 0x74 }, .{ 0x9d, 0x00, 0x06 }, .{ 0x79, 0x74, 0x0e }, .{ 0xb5, 0x76, 0x14 },
            .{ 0x07, 0x66, 0x78 }, .{ 0x8f, 0x3f, 0x71 }, .{ 0x42, 0x7b, 0x58 }, .{ 0x3c, 0x38, 0x36 },
        },
    },
    .{
        .key = "nord",
        .label = "Nord",
        .fg = .{ 0xd8, 0xde, 0xe9 },
        .bg = .{ 0x2e, 0x34, 0x40 },
        .palette = .{
            .{ 0x3b, 0x42, 0x52 }, .{ 0xbf, 0x61, 0x6a }, .{ 0xa3, 0xbe, 0x8c }, .{ 0xeb, 0xcb, 0x8b },
            .{ 0x81, 0xa1, 0xc1 }, .{ 0xb4, 0x8e, 0xad }, .{ 0x88, 0xc0, 0xd0 }, .{ 0xe5, 0xe9, 0xf0 },
            .{ 0x4c, 0x56, 0x6a }, .{ 0xbf, 0x61, 0x6a }, .{ 0xa3, 0xbe, 0x8c }, .{ 0xeb, 0xcb, 0x8b },
            .{ 0x81, 0xa1, 0xc1 }, .{ 0xb4, 0x8e, 0xad }, .{ 0x8f, 0xbc, 0xbb }, .{ 0xec, 0xef, 0xf4 },
        },
    },
    .{
        .key = "dracula",
        .label = "Dracula",
        .fg = .{ 0xf8, 0xf8, 0xf2 },
        .bg = .{ 0x28, 0x2a, 0x36 },
        .palette = .{
            .{ 0x21, 0x22, 0x2c }, .{ 0xff, 0x55, 0x55 }, .{ 0x50, 0xfa, 0x7b }, .{ 0xf1, 0xfa, 0x8c },
            .{ 0xbd, 0x93, 0xf9 }, .{ 0xff, 0x79, 0xc6 }, .{ 0x8b, 0xe9, 0xfd }, .{ 0xf8, 0xf8, 0xf2 },
            .{ 0x62, 0x72, 0xa4 }, .{ 0xff, 0x6e, 0x6e }, .{ 0x69, 0xff, 0x94 }, .{ 0xff, 0xff, 0xa5 },
            .{ 0xd6, 0xac, 0xff }, .{ 0xff, 0x92, 0xdf }, .{ 0xa4, 0xff, 0xff }, .{ 0xff, 0xff, 0xff },
        },
    },
    .{
        .key = "monokai",
        .label = "Monokai",
        .fg = .{ 0xf8, 0xf8, 0xf2 },
        .bg = .{ 0x27, 0x28, 0x22 },
        .palette = .{
            .{ 0x27, 0x28, 0x22 }, .{ 0xf9, 0x26, 0x72 }, .{ 0xa6, 0xe2, 0x2e }, .{ 0xf4, 0xbf, 0x75 },
            .{ 0x66, 0xd9, 0xef }, .{ 0xae, 0x81, 0xff }, .{ 0xa1, 0xef, 0xe4 }, .{ 0xf8, 0xf8, 0xf2 },
            .{ 0x75, 0x71, 0x5e }, .{ 0xf9, 0x26, 0x72 }, .{ 0xa6, 0xe2, 0x2e }, .{ 0xf4, 0xbf, 0x75 },
            .{ 0x66, 0xd9, 0xef }, .{ 0xae, 0x81, 0xff }, .{ 0xa1, 0xef, 0xe4 }, .{ 0xf9, 0xf8, 0xf5 },
        },
    },
};

const PaletteRowCtx = struct {
    parent: *Ctx,
    index: usize, // 0..15
};

const ColorRowCtx = struct {
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
    cctx.* = .{ .parent = ctx, .field = field };
    _ = c.g_signal_connect_data(btn, "notify::rgba", @ptrCast(&colorRowChanged), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn colorRowChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const cctx: *ColorRowCtx = @ptrCast(@alignCast(user.?));
    const rgba = c.gtk_color_dialog_button_get_rgba(btn);
    cctx.field.* = .{ rgba.*.red, rgba.*.green, rgba.*.blue, rgba.*.alpha };
    cctx.parent.ev();
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
    pctx.* = .{ .parent = ctx, .index = idx };
    _ = c.g_signal_connect_data(btn, "notify::rgba", @ptrCast(&paletteRowChanged), @ptrCast(pctx), null, c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn paletteRowChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const pctx: *PaletteRowCtx = @ptrCast(@alignCast(user.?));
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
    cctx.* = .{ .parent = ctx, .on_change = schemeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), null, c.G_CONNECT_DEFAULT);
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

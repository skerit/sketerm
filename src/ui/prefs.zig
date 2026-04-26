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
    // (Colors / Behavior / Rendering / Window pages — added in
    // subsequent commits.)

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

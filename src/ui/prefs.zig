//! Preferences window with one page per
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
const render_kick = @import("../util/render_kick.zig");
const Config = @import("../config.zig").Config;
const CursorShape = @import("../config.zig").CursorShape;
const ExitAction = @import("../config.zig").ExitAction;
const config_mod = @import("../config.zig");
const TabPosition = @import("../config.zig").TabPosition;
const editor_theme = @import("../editor/theme.zig");
const lsp_proc = @import("../lsp/proc.zig");

// Forward-declare the Window pointer type. We can't import window.zig
// directly without creating a cycle, so we receive it as anyopaque and
// cast on the apply boundary.
const WindowOpaque = anyopaque;

/// Apply callback: invoked whenever a row mutates. Receives the
/// Window pointer the dialog was opened against and a snapshot of the
/// new Config. The Window is responsible for pushing values into its
/// panes and persisting to disk.
pub const ApplyFn = *const fn (win: *WindowOpaque, new_cfg: *const Config) void;

const ProfileSettings = config_mod.ProfileSettings;

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
    /// The settings bundle the pane-level rows edit: the Default
    /// settings, or one profile's. Points INTO `cfg` — invalidated
    /// only by profile create/delete, which immediately reopen the
    /// dialog with a fresh Ctx.
    edit: *ProfileSettings,
    /// Name of the bundle in `edit` ("" = Default). Borrows cfg's
    /// profile-name string.
    edit_name: []const u8,
    /// Needed to reopen the dialog bound to another profile.
    parent_window: *c.GtkWindow,
    /// The AdwPreferencesWindow (a real toplevel, not an attached
    /// sheet).
    dialog: ?*c.GtkWidget = null,

    fn ev(self: *Ctx) void {
        self.apply(self.win, &self.cfg);
    }

    fn dupe(self: *Ctx, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }
};

/// Open a non-modal preferences window associated with `parent_window`. Caller
/// (Window) provides the apply callback that lives-updates state and
/// persists to disk. Memory: Ctx is heap-allocated; freed when the
/// window emits "destroy".
pub fn open(
    allocator: std.mem.Allocator,
    parent_window: *c.GtkWindow,
    win_ptr: *WindowOpaque,
    initial: Config,
    apply: ApplyFn,
) !void {
    return openForProfile(allocator, parent_window, win_ptr, initial, apply, "");
}

/// Open the dialog with the pane-level pages bound to `profile_name`
/// ("" / "default" / unknown = the Default settings). The Profiles
/// page's selector switches bundles by closing + reopening here —
/// rows capture raw field pointers at build time, so rebinding a
/// live dialog isn't possible.
fn openForProfile(
    allocator: std.mem.Allocator,
    parent_window: *c.GtkWindow,
    win_ptr: *WindowOpaque,
    initial: Config,
    apply: ApplyFn,
    profile_name: []const u8,
) !void {
    const ctx = try allocator.create(Ctx);
    errdefer allocator.destroy(ctx);
    ctx.* = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .win = win_ptr,
        .apply = apply,
        .cfg = undefined,
        .edit = undefined,
        .edit_name = "",
        .parent_window = parent_window,
    };
    errdefer ctx.arena.deinit();
    // Deep-copy into the dialog's arena: a plain struct copy would
    // alias the Window's config arena, which applyConfigChange frees
    // on the very first row change — dangling working copy.
    ctx.cfg = try initial.cloneInto(ctx.arena.allocator());

    // Resolve the bundle being edited. Unknown / deleted profile
    // names degrade to the Default settings.
    ctx.edit = &ctx.cfg.settings;
    if (profile_name.len > 0 and !std.mem.eql(u8, profile_name, "default")) {
        for (ctx.cfg.profiles.items) |*p| {
            if (std.mem.eql(u8, p.name, profile_name)) {
                ctx.edit = &p.settings;
                ctx.edit_name = p.name;
                break;
            }
        }
    }

    // A real window, deliberately NOT modal and not an AdwDialog
    // sheet: preferences should not pin themselves over (or inside)
    // the main window.
    const dialog = c.adw_preferences_window_new();
    ctx.dialog = dialog;
    c.gtk_window_set_title(@ptrCast(dialog), "Preferences");
    if (ctx.edit_name.len > 0) {
        var title_buf: [160:0]u8 = undefined;
        const t = std.fmt.bufPrintZ(&title_buf, "Preferences — profile “{s}”", .{ctx.edit_name}) catch "Preferences";
        c.gtk_window_set_title(@ptrCast(dialog), t.ptr);
    }
    c.gtk_window_set_transient_for(@ptrCast(dialog), parent_window);
    // Free Ctx when the window goes away.
    _ = c.g_signal_connect_data(
        dialog,
        "destroy",
        @ptrCast(&onClosed),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );

    appendPage(@ptrCast(@alignCast(dialog)), ctx, &profilesPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &appearancePage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &colorsPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &behaviorPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &filesPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &editorPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &renderingPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &windowPage);
    appendPage(@ptrCast(@alignCast(dialog)), ctx, &keybindsPage);

    // Force the on-demand GL panes to repaint so the overlay composites
    // over an idle terminal (and the dimming clears on close).
    _ = c.g_signal_connect_data(dialog, "destroy", @ptrCast(&render_kick.onDialogClosed), @ptrCast(parent_window), null, c.G_CONNECT_DEFAULT);
    c.gtk_window_present(@ptrCast(dialog));
    render_kick.dialogPresented(@ptrCast(@alignCast(parent_window)));
}

fn onClosed(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    ctx.arena.deinit();
    ctx.allocator.destroy(ctx);
}

const PageBuilder = *const fn (page: *c.AdwPreferencesPage, ctx: *Ctx) void;

fn appendPage(dialog: *c.AdwPreferencesWindow, ctx: *Ctx, builder: PageBuilder) void {
    const page = c.adw_preferences_page_new();
    builder(@ptrCast(@alignCast(page)), ctx);
    c.adw_preferences_window_add(dialog, @ptrCast(@alignCast(page)));
}

// ── Profiles page ───────────────────────────────────────────────

fn profilesPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Profiles");
    c.adw_preferences_page_set_icon_name(page, "system-users-symbolic");

    const sel_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(sel_group)), "Profile being edited");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(sel_group)), "The pane-level pages (fonts, colors, shell, scrollback, shader) edit this profile. Window, input and keybinding settings are always global.");
    addEditingProfileRow(@ptrCast(@alignCast(sel_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(sel_group)));

    const manage_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(manage_group)), "Manage");
    addNewProfileRow(@ptrCast(@alignCast(manage_group)), ctx);
    if (ctx.edit_name.len > 0)
        addDeleteProfileRow(@ptrCast(@alignCast(manage_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(manage_group)));

    const spawn_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(spawn_group)), "New panes");
    addDefaultProfileRow(@ptrCast(@alignCast(spawn_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(spawn_group)));
}

/// "default" + every named profile as a GtkStringList. Name strings
/// are arena-duped (the list copies them anyway, but the pointer
/// array needs a NUL-terminated form).
fn profileNameModel(ctx: *Ctx) ?*c.GtkStringList {
    const arena = ctx.arena.allocator();
    const n = ctx.cfg.profiles.items.len;
    const arr = arena.alloc(?[*:0]const u8, n + 2) catch return null;
    arr[0] = "default";
    for (ctx.cfg.profiles.items, 0..) |p, i| {
        const z = arena.allocSentinel(u8, p.name.len, 0) catch return null;
        @memcpy(z, p.name);
        arr[i + 1] = z.ptr;
    }
    arr[n + 1] = null;
    return c.gtk_string_list_new(@ptrCast(arr.ptr));
}

/// Index of `name` in the profileNameModel ordering (0 = default).
fn profileModelIndex(ctx: *Ctx, name: []const u8) c_uint {
    if (name.len == 0 or std.mem.eql(u8, name, "default")) return 0;
    for (ctx.cfg.profiles.items, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return @intCast(i + 1);
    }
    return 0;
}

/// Model index → profile name ("" = default). Borrows cfg strings.
fn profileModelName(ctx: *Ctx, idx: c_uint) []const u8 {
    if (idx == 0 or idx > ctx.cfg.profiles.items.len) return "";
    return ctx.cfg.profiles.items[idx - 1].name;
}

fn addEditingProfileRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = profileNameModel(ctx) orelse return;
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Profile");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Switching reopens the dialog bound to that profile.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), profileModelIndex(ctx, ctx.edit_name));
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = editingProfileSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn editingProfileSelected(ctx: *Ctx, idx: c_uint) void {
    const name = profileModelName(ctx, idx);
    if (std.mem.eql(u8, name, ctx.edit_name)) return;
    reopenForProfile(ctx, name);
}

/// Close this dialog and reopen it bound to `name`. The Ctx dies
/// with the close — capture everything needed first.
fn reopenForProfile(ctx: *Ctx, name: []const u8) void {
    const allocator = ctx.allocator;
    const win = ctx.win;
    const apply = ctx.apply;
    const parent_window = ctx.parent_window;
    const dialog = ctx.dialog;
    var name_buf: [128]u8 = undefined;
    const n = @min(name.len, name_buf.len);
    @memcpy(name_buf[0..n], name[0..n]);
    var snapshot = ctx.cfg.clone(allocator) catch return;
    defer snapshot.deinit();
    // Destroying the window frees ctx via onClosed — no Ctx access
    // past here.
    if (dialog) |d| c.gtk_window_destroy(@ptrCast(d));
    openForProfile(allocator, parent_window, win, snapshot, apply, name_buf[0..n]) catch {};
}

const NewProfileCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    entry: *c.GtkWidget,
};

fn addNewProfileRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "New profile (copies the profile being edited)");
    const btn = c.gtk_button_new_with_label("Create");
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    c.gtk_widget_add_css_class(btn, "suggested-action");
    const nctx = ctx.allocator.create(NewProfileCtx) catch return;
    nctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .entry = @ptrCast(@alignCast(row)) };
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onCreateProfile), @ptrCast(nctx), @ptrCast(cast.destroyCtx(NewProfileCtx)), c.G_CONNECT_DEFAULT);
    c.adw_entry_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn onCreateProfile(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const nctx = cast.userData(NewProfileCtx, user);
    const ctx = nctx.parent;
    const txt = c.gtk_editable_get_text(@ptrCast(@alignCast(nctx.entry)));
    if (txt == null) return;
    const raw = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
    const name = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (name.len == 0 or name.len > 64) return;
    if (std.mem.eql(u8, name, "default")) return;
    // Section-header syntax can't carry these.
    if (std.mem.indexOfAny(u8, name, "[]=#") != null) return;
    for (ctx.cfg.profiles.items) |p| {
        if (std.mem.eql(u8, p.name, name)) return; // exists
    }
    const arena = ctx.arena.allocator();
    const name_dup = arena.dupe(u8, name) catch return;
    // Full copy of the bundle being edited; its strings live in the
    // same arena, and the apply path deep-copies on its side.
    ctx.cfg.profiles.append(arena, .{
        .name = name_dup,
        .settings = ctx.edit.*,
    }) catch return;
    ctx.ev();
    // The append may have reallocated profiles (ctx.edit dangles) —
    // reopen immediately, bound to the new profile.
    reopenForProfile(ctx, name_dup);
}

fn addDeleteProfileRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_action_row_new();
    var title_buf: [160:0]u8 = undefined;
    const t = std.fmt.bufPrintZ(&title_buf, "Delete profile “{s}”", .{ctx.edit_name}) catch "Delete this profile";
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), t.ptr);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Panes using it fall back to the Default settings.");
    const btn = c.gtk_button_new_with_label("Delete");
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    c.gtk_widget_add_css_class(btn, "destructive-action");
    // User-data is the dialog's main Ctx (managed by onClosed) — no
    // destroy-notify needed.
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onDeleteProfile), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn onDeleteProfile(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    if (ctx.edit_name.len == 0) return;
    for (ctx.cfg.profiles.items, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, ctx.edit_name)) {
            _ = ctx.cfg.profiles.orderedRemove(i);
            break;
        }
    }
    if (std.mem.eql(u8, ctx.cfg.default_profile, ctx.edit_name))
        ctx.cfg.default_profile = "";
    ctx.ev();
    reopenForProfile(ctx, "");
}

fn addDefaultProfileRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = profileNameModel(ctx) orelse return;
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Profile for new panes");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Used by new tabs and splits unless one is picked explicitly.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), profileModelIndex(ctx, ctx.cfg.default_profile));
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = defaultProfileSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn defaultProfileSelected(ctx: *Ctx, idx: c_uint) void {
    const name = profileModelName(ctx, idx);
    ctx.cfg.default_profile = ctx.dupe(name) catch return;
    ctx.ev();
}

// ── Appearance page ─────────────────────────────────────────────

fn appearancePage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Appearance");
    c.adw_preferences_page_set_icon_name(page, "preferences-desktop-font-symbolic");

    const font_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(font_group)), "Font");
    addFontFamilyRow(@ptrCast(@alignCast(font_group)), ctx);
    addFontPathRow(@ptrCast(@alignCast(font_group)), ctx);
    addFontFeaturesRow(@ptrCast(@alignCast(font_group)), ctx);
    addSpinRowU16(@ptrCast(@alignCast(font_group)), ctx, "Size", "Font size in points", 6, 72, &ctx.edit.font_size, applyOnly);
    addSpinRowI16(@ptrCast(@alignCast(font_group)), ctx, "Line spacing", "Extra pixels per cell row", -8, 24, &ctx.edit.line_pad_px, applyOnly);
    addSpinRowF32(@ptrCast(@alignCast(font_group)), ctx, "Padding", "Inner padding around the cell grid", 0.0, 32.0, &ctx.edit.padding, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(font_group)));

    const cursor_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(cursor_group)), "Cursor");
    addCursorShapeRow(@ptrCast(@alignCast(cursor_group)), ctx);
    addSwitchRow(@ptrCast(@alignCast(cursor_group)), ctx, "Blink", "Toggle cursor visibility periodically", &ctx.cfg.cursor_blink, applyOnly);
    addSpinRowU32(@ptrCast(@alignCast(cursor_group)), ctx, "Blink interval (ms)", "Half-cycle. 500 = full blink every 1 s.", 100, 2000, &ctx.cfg.cursor_blink_ms, applyOnly);
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
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(dim_group)), "Uniformly darken (and optionally desaturate) unfocused panes. Applied to the whole pane, so colours stay true \xe2\x80\x94 just dimmer.");
    addSpinRowF32Step(@ptrCast(@alignCast(dim_group)), ctx, "Darken", "How much to darken unfocused panes. 0 = none, 1 = black.", 0.0, 1.0, 0.05, 2, &ctx.cfg.inactive_darken, applyOnly);
    addSpinRowF32Step(@ptrCast(@alignCast(dim_group)), ctx, "Desaturate", "Fade unfocused panes toward gray. 0 = full colour, 1 = grayscale.", 0.0, 1.0, 0.05, 2, &ctx.cfg.inactive_desaturate, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(dim_group)));

    // Tab activity.
    const tabact_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(tabact_group)), "Tab activity");
    addSwitchRow(@ptrCast(@alignCast(tabact_group)), ctx, "Track tab activity", "Master switch for per-tab activity effects (glow, inactivity warning). Right-click a tab to toggle each effect for that tab.", &ctx.cfg.track_tab_activity, applyOnly);
    addSpinRowU32(@ptrCast(@alignCast(tabact_group)), ctx, "Inactive after (seconds)", "Silence before a tab's inactivity warning fires (per-tab toggle in the tab's right-click menu).", 1, 3600, &ctx.cfg.inactive_warn_secs, applyOnly);
    addSpinRowF32Step(@ptrCast(@alignCast(tabact_group)), ctx, "Acknowledge delay (seconds)", "How long a tab must stay open before viewing it clears its inactivity warning. Stops a quick scroll across the tabs from wiping every warning.", 0.0, 6.0, 0.5, 1, &ctx.cfg.tab_ack_delay_secs, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(tabact_group)));

    // Text legibility.
    const contrast_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(contrast_group)), "Legibility");
    addSpinRowF32Step(@ptrCast(@alignCast(contrast_group)), ctx, "Minimum contrast", "WCAG ratio 1..21. Text below it snaps to white/black. 1.0 = off; 3.0 is a sane floor.", 1.0, 21.0, 0.5, 1, &ctx.cfg.minimum_contrast, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(contrast_group)));

    // Background opacity (Wayland transparency).
    const bg_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(bg_group)), "Background");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(bg_group)), "Window-level transparency. Wayland with compositor support only. Once toggled below 1.0, returning to 1.0 may require a window restart.");
    addSpinRowF32Step(@ptrCast(@alignCast(bg_group)), ctx, "Opacity", "1.0 = opaque; 0.0 = fully transparent.", 0.0, 1.0, 0.05, 2, &ctx.cfg.background_opacity, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(bg_group)));

    // Background image / gradient layer.
    const bgi_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(bgi_group)), "Background image / gradient");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(bgi_group)), "Image (cover-cropped) wins over the gradient. Gradient is active once both colours are non-transparent.");
    addEntryRowString(@ptrCast(@alignCast(bgi_group)), ctx, "Image path (PNG/JPEG)", "", &ctx.cfg.background_image, applyOnly);
    addSpinRowF32Step(@ptrCast(@alignCast(bgi_group)), ctx, "Image opacity", "Keep low — text sits on it.", 0.0, 1.0, 0.05, 2, &ctx.cfg.background_image_opacity, applyOnly);
    addColorRow(@ptrCast(@alignCast(bgi_group)), ctx, "Gradient from", &ctx.cfg.background_gradient_from);
    addColorRow(@ptrCast(@alignCast(bgi_group)), ctx, "Gradient to", &ctx.cfg.background_gradient_to);
    addSpinRowF32Step(@ptrCast(@alignCast(bgi_group)), ctx, "Gradient angle", "0 = left to right, 90 = top to bottom.", 0.0, 360.0, 15.0, 1, &ctx.cfg.background_gradient_angle, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(bgi_group)));

    // Custom post-process shader.
    const shader_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(shader_group)), "Custom shader");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(shader_group)), "Shadertoy-style fragment shader applied to the whole frame (CRT, glow, …). Compile errors disable it — the terminal keeps rendering.");
    addEntryRowString(@ptrCast(@alignCast(shader_group)), ctx, "Shader file (GLSL, mainImage)", "", &ctx.edit.custom_shader, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(shader_group)), ctx, "Animate", "Redraw continuously so iTime advances.", &ctx.cfg.custom_shader_animation, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(shader_group)));
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
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinU16Changed), @ptrCast(sctx), @ptrCast(cast.destroyCtx(SpinU16Ctx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinU16Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SpinU16Ctx, user);
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
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinU32Changed), @ptrCast(sctx), @ptrCast(cast.destroyCtx(SpinU32Ctx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinU32Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SpinU32Ctx, user);
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
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinI16Changed), @ptrCast(sctx), @ptrCast(cast.destroyCtx(SpinI16Ctx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinI16Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SpinI16Ctx, user);
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
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&spinF32Changed), @ptrCast(sctx), @ptrCast(cast.destroyCtx(SpinF32Ctx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn spinF32Changed(spin: *c.AdwSpinRow, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SpinF32Ctx, user);
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
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "notify::active", @ptrCast(&switchChanged), @ptrCast(sctx), @ptrCast(cast.destroyCtx(SwitchCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn switchChanged(row: *c.AdwSwitchRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SwitchCtx, user);
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
    c.g_object_unref(items);
    const initial: c_uint = switch (ctx.cfg.cursor_shape) {
        .block => 0,
        .underline => 1,
        .bar => 2,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = cursorShapeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn comboChanged(row: *c.AdwComboRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const cctx = cast.userData(ComboCtx, user);
    cctx.on_change(cctx.parent, c.adw_combo_row_get_selected(row));
}

const MouseActionCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *config_mod.MouseAction,
};

fn addMouseActionRow(group: *c.AdwPreferencesGroup, ctx: *Ctx, title: [*:0]const u8, subtitle: [*:0]const u8, field: *config_mod.MouseAction) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Context menu", "Paste selection (PRIMARY)", "Paste clipboard", "Nothing" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), @intFromEnum(field.*));
    const mctx = ctx.allocator.create(MouseActionCtx) catch return;
    mctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&mouseActionChanged), @ptrCast(mctx), @ptrCast(cast.destroyCtx(MouseActionCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn mouseActionChanged(row: *c.AdwComboRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const mctx = cast.userData(MouseActionCtx, user);
    const idx = c.adw_combo_row_get_selected(row);
    if (idx > @intFromEnum(config_mod.MouseAction.none)) return;
    mctx.field.* = @enumFromInt(idx);
    mctx.parent.ev();
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

fn addFontFamilyRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Font family (fontconfig name; the font file below wins if set)");
    if (ctx.edit.font_family.len > 0) {
        var z = cast.sliceToZ(256, ctx.edit.font_family);
        c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    }
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&fontFamilyChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn fontFamilyChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const slice = cast.editableText(row);
    ctx.edit.font_family = if (slice.len == 0) "" else ctx.dupe(slice) catch return;
    ctx.ev();
}

fn addFontFeaturesRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "OpenType features (e.g. -calt +ss01 zero)");
    if (ctx.edit.font_features.len > 0) {
        var z = cast.sliceToZ(256, ctx.edit.font_features);
        c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    }
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&fontFeaturesChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn fontFeaturesChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const slice = cast.editableText(row);
    ctx.edit.font_features = if (slice.len == 0) "" else ctx.dupe(slice) catch return;
    ctx.ev();
}

fn addFontPathRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Font file");
    const sub = if (ctx.edit.font_path) |fp| fp else "(default search path)";
    var z = cast.sliceToZ(512, sub);
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
    // Sketerm's own picker (src/ui/picker.zig), not the GTK stock
    // dialog: same browser everywhere, remote-capable, ours to keep.
    const root = c.gtk_widget_get_root(@ptrCast(btn));
    const parent: ?*c.GtkWindow = if (root) |r| @ptrCast(@alignCast(r)) else null;
    _ = @import("picker.zig").PickerWindow.open(
        ctx.allocator,
        parent,
        .{
            .mode = .open_file,
            .title = "Select font file (.ttf / .otf)",
            .filters = &.{
                .{ .label = "Font files", .patterns = &.{ "*.ttf", "*.otf", "*.ttc", "*.otb" } },
            },
        },
        &onChooseFontPicked,
        @ptrCast(ctx),
    ) catch return;
}

fn onChooseFontPicked(user: ?*anyopaque, result: ?@import("../filebrowser/picker.zig").Result) void {
    // A null result (cancel/teardown) must not touch ctx: on parent
    // teardown the Ctx may already be gone.
    const res = result orelse return;
    if (res.specs.len == 0) return;
    const ctx = cast.userData(Ctx, user);
    const loc = @import("../filebrowser/paths.zig").parseSpec(res.specs[0]);
    // FreeType loads the file locally; a remote pick cannot apply.
    if (loc.host != null) return;
    // Owned via Config.arena (allocator-independent: dupe into our
    // Ctx allocator since the working cfg in the dialog has no arena
    // — apply path will arena-dupe on persist).
    const dup = ctx.dupe(loc.path) catch return;
    ctx.edit.font_path = dup;
    ctx.ev();
}

// ── Per-field apply hooks ───────────────────────────────────────

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
    addColorRow(@ptrCast(@alignCast(defaults_group)), ctx, "Foreground", &ctx.edit.default_fg);
    addColorRow(@ptrCast(@alignCast(defaults_group)), ctx, "Background", &ctx.edit.default_bg);
    addColorRow(@ptrCast(@alignCast(defaults_group)), ctx, "Cursor", &ctx.edit.cursor_color);
    addSwitchRow(@ptrCast(@alignCast(defaults_group)), ctx, "Cursor uses foreground", "Override the explicit cursor colour with the foreground.", &ctx.edit.cursor_color_default, applyOnly);
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
    _ = c.g_signal_connect_data(btn, "notify::rgba", @ptrCast(&colorRowChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ColorRowCtx)), c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn colorRowChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const cctx = cast.userData(ColorRowCtx, user);
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
    // else built-in default 256-table first 16. Must match the seed in
    // paletteRowChanged or editing preserves colors the dialog never showed.
    const default_pal = @import("../grid/palette.zig").default_256;
    const cur: [3]u8 = if (ctx.edit.palette) |p|
        p[idx]
    else if (@import("../grid/schemes.zig").lookup(ctx.edit.scheme)) |scheme|
        scheme.palette[idx]
    else
        default_pal[idx];

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
    _ = c.g_signal_connect_data(btn, "notify::rgba", @ptrCast(&paletteRowChanged), @ptrCast(pctx), @ptrCast(cast.destroyCtx(PaletteRowCtx)), c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn paletteRowChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const pctx = cast.userData(PaletteRowCtx, user);
    const rgba = c.gtk_color_dialog_button_get_rgba(btn);
    // Promote palette to override mode if needed (copying from
    // current effective palette).
    if (pctx.parent.edit.palette == null) {
        const default_pal = @import("../grid/palette.zig").default_256;
        var pal: [16][3]u8 = undefined;
        if (@import("../grid/schemes.zig").lookup(pctx.parent.edit.scheme)) |scheme| {
            pal = scheme.palette;
        } else {
            var i: usize = 0;
            while (i < 16) : (i += 1) pal[i] = default_pal[i];
        }
        pctx.parent.edit.palette = pal;
    }
    var pal = pctx.parent.edit.palette.?;
    pal[pctx.index] = .{
        @intFromFloat(@round(rgba.*.red * 255.0)),
        @intFromFloat(@round(rgba.*.green * 255.0)),
        @intFromFloat(@round(rgba.*.blue * 255.0)),
    };
    pctx.parent.edit.palette = pal;
    // Editing the palette unsets `scheme` — the user has overridden.
    pctx.parent.edit.scheme = "";
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
    c.g_object_unref(items);
    var sel: c_uint = 0;
    for (SCHEMES, 0..) |sch, i| {
        if (std.mem.eql(u8, sch.key, ctx.edit.scheme)) {
            sel = @intCast(i);
            break;
        }
    }
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), sel);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = schemeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn schemeSelected(ctx: *Ctx, idx: c_uint) void {
    if (idx >= SCHEMES.len) return;
    const sch = SCHEMES[idx];
    ctx.edit.scheme = sch.key;
    ctx.edit.default_fg = .{
        @as(f32, @floatFromInt(sch.fg[0])) / 255.0,
        @as(f32, @floatFromInt(sch.fg[1])) / 255.0,
        @as(f32, @floatFromInt(sch.fg[2])) / 255.0,
        1.0,
    };
    ctx.edit.default_bg = .{
        @as(f32, @floatFromInt(sch.bg[0])) / 255.0,
        @as(f32, @floatFromInt(sch.bg[1])) / 255.0,
        @as(f32, @floatFromInt(sch.bg[2])) / 255.0,
        1.0,
    };
    ctx.edit.palette = sch.palette;
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
    addEntryRowOptionalString(@ptrCast(@alignCast(shell_group)), ctx, "TERM", "$TERM env in child", &ctx.edit.term_env, applyOnly);
    addEntryRowOptionalString(@ptrCast(@alignCast(shell_group)), ctx, "COLORTERM", "$COLORTERM env in child", &ctx.edit.color_term_env, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(shell_group)), ctx, "Login shell", "Prepend a `-` to argv[0] so the shell sources login profile.", &ctx.edit.login_shell, applyOnly);
    addExitActionRow(@ptrCast(@alignCast(shell_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(shell_group)));

    // Forwarded GUI apps.
    const apps_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(apps_group)), "Applications");
    addAppViewRow(@ptrCast(@alignCast(apps_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(apps_group)));

    // Input.
    const input_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(input_group)), "Input");
    addSwitchRow(@ptrCast(@alignCast(input_group)), ctx, "Bracketed paste", "Wrap pasted text in DECSET 2004 markers.", &ctx.cfg.bracketed_paste, applyOnly);
    addModifyOtherKeysRow(@ptrCast(@alignCast(input_group)), ctx);
    addInputMethodRow(@ptrCast(@alignCast(input_group)), ctx);
    addEntryRowString(@ptrCast(@alignCast(input_group)), ctx, "Word characters", "Chars considered part of a word for double-click selection.", &ctx.cfg.word_chars, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(input_group)), ctx, "Smart copy", "Ctrl+Shift+C with no selection forwards Ctrl+C.", &ctx.cfg.smart_copy, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(input_group)));

    // Scrollback.
    const sb_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(sb_group)), "Scrollback");
    addSpinRowU32(@ptrCast(@alignCast(sb_group)), ctx, "Lines", "Maximum scrollback lines retained per pane.", 100, 100000, &ctx.edit.scrollback, applyOnly);
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
    addMouseActionRow(@ptrCast(@alignCast(mouse_group)), ctx, "Middle click", "Action when apps aren't capturing the mouse.", &ctx.cfg.mouse_middle_click);
    addMouseActionRow(@ptrCast(@alignCast(mouse_group)), ctx, "Right click", "Menu is the default; PuTTY refugees pick paste.", &ctx.cfg.mouse_right_click);
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

    // Compositing.
    const comp_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(comp_group)), "Compositing");
    addSwitchRow(@ptrCast(@alignCast(comp_group)), ctx, "Graphics offload", "Wayland subsurface scanout fast path. Turn off if your compositor misbehaves with subsurfaces.", &ctx.cfg.graphics_offload, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(comp_group)));
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
    var z = cast.sliceToZ(256, field.*);
    c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    const sctx = ctx.allocator.create(StringFieldCtx) catch return;
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .on_change = on_change };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&entryStringChanged), @ptrCast(sctx), @ptrCast(cast.destroyCtx(StringFieldCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn entryStringChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(StringFieldCtx, user);
    const slice = cast.editableText(row);
    const dup = sctx.parent.dupe(slice) catch return;
    sctx.field.* = dup;
    sctx.on_change(sctx.parent);
}

fn addEntryRowOptionalString(group: *c.AdwPreferencesGroup, ctx: *Ctx, title: [*:0]const u8, subtitle: [*:0]const u8, field: *[]const u8, on_change: *const fn (*Ctx) void) void {
    addEntryRowString(group, ctx, title, subtitle, field, on_change);
}

fn addShellPathRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Shell");
    if (ctx.edit.shell) |s| {
        var z = cast.sliceToZ(256, s);
        c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    }
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&shellEntryChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn shellEntryChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const slice = cast.editableText(row);
    if (slice.len == 0) {
        ctx.edit.shell = null;
    } else {
        const dup = ctx.dupe(slice) catch return;
        ctx.edit.shell = dup;
    }
    ctx.ev();
}

fn addModifyOtherKeysRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Off", "Basic (xterm 1)", "Full (xterm 2)" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "modifyOtherKeys");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Send Ctrl/Alt + alphabetic keys as CSI u sequences.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), ctx.cfg.modify_other_keys);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = modifyOtherKeysSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn modifyOtherKeysSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.modify_other_keys = @intCast(@min(idx, 2));
    ctx.ev();
}

/// `input_method`: no value gives both dead keys and CJK input
/// methods, so the row says which one it trades away.
fn addInputMethodRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{
        "Automatic",
        "Compose / dead keys (no IME)",
        "System input method (IME; dead keys need compositor support)",
    });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Input method");
    c.adw_action_row_set_subtitle(
        @ptrCast(@alignCast(row)),
        "Automatic: terminal always composes; editor and forwarded apps use your IME when one is configured",
    );
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    const initial: c_uint = switch (ctx.cfg.input_method) {
        .auto => 0,
        .simple => 1,
        .multi => 2,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = inputMethodSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn inputMethodSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.input_method = switch (idx) {
        1 => .simple,
        2 => .multi,
        else => .auto,
    };
    ctx.ev();
}

fn addExitActionRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Close pane", "Restart shell", "Hold (show exit status)" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "On shell exit");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    const initial: c_uint = switch (ctx.cfg.exit_action) {
        .close => 0,
        .restart => 1,
        .hold => 2,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = exitActionSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn addAppViewRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Floating window", "Embedded in tab" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "App windows open as");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), if (ctx.cfg.app_view == .tab) 1 else 0);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = appViewSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn appViewSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.app_view = if (idx == 1) .tab else .window;
    ctx.ev();
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

// ── Files page (the `sketerm files` browser) ───────────────────

fn filesPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Files");
    c.adw_preferences_page_set_icon_name(page, "folder-symbolic");

    const view_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(view_group)), "New tabs");
    addFilesViewRow(@ptrCast(@alignCast(view_group)), ctx);
    addSwitchRow(@ptrCast(@alignCast(view_group)), ctx, "Show hidden files", "New browser tabs start with dotfiles visible.", &ctx.cfg.files_show_hidden, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(view_group)));

    const danger_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(danger_group)), "Deleting");
    addSwitchRow(@ptrCast(@alignCast(danger_group)), ctx, "Confirm permanent delete", "Ask before Shift+Delete / Delete Permanently. Moving to trash never asks (it is undoable).", &ctx.cfg.files_confirm_delete, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(danger_group)), ctx, "Verify copies", "Hash-compare every copied file against its source before it is installed. Slower (each file is read twice), but a bad disk or interrupted write can never install silently.", &ctx.cfg.files_verify_copy, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(danger_group)));
}

fn addFilesViewRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Details list", "Compact list", "Icon grid", "Miller columns" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Default view");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Folders you have adjusted keep their remembered view.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    const initial: c_uint = switch (ctx.cfg.files_default_view) {
        .details => 0,
        .compact => 1,
        .icons => 2,
        .miller => 3,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = filesViewSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn filesViewSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.files_default_view = switch (idx) {
        0 => .details,
        1 => .compact,
        2 => .icons,
        3 => .miller,
        else => .details,
    };
    ctx.ev();
}

// ── Editor page (the text-editor face on a pane) ───────────────

fn editorPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Editor");
    c.adw_preferences_page_set_icon_name(page, "text-editor-symbolic");

    // Indentation and view flags are APP-level: the same person wants
    // the same indentation in every window, and a file opened from the
    // browser must not indent differently because of the pane's
    // profile.
    const indent_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(indent_group)), "Indentation");
    addSpinRowU16(@ptrCast(@alignCast(indent_group)), ctx, "Tab width", "Columns one Tab advances.", 1, 16, &ctx.cfg.editor_tab_width, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(indent_group)), ctx, "Insert spaces", "Tab inserts spaces to the next stop. Off inserts a literal tab character.", &ctx.cfg.editor_insert_spaces, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(indent_group)));

    const view_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(view_group)), "View");
    addSwitchRow(@ptrCast(@alignCast(view_group)), ctx, "Soft wrap by default", "New editor tabs start wrapped. Alt+Z toggles it per tab.", &ctx.cfg.editor_soft_wrap, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(view_group)), ctx, "Line numbers", "Show the line-number gutter.", &ctx.cfg.editor_line_numbers, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(view_group)), ctx, "Crash recovery", "Snapshot unsaved editor buffers while you type, and offer them back after a crash. Off writes nothing.", &ctx.cfg.editor_crash_recovery, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(view_group)), ctx, "Highlight current line", "A subtle band behind the caret's row. Hidden while a selection or several carets are active.", &ctx.cfg.editor_highlight_current_line, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(view_group)));

    const syntax_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(syntax_group)), "Syntax");
    addSwitchRow(@ptrCast(@alignCast(syntax_group)), ctx, "Syntax highlighting", "Colour code by structure (Zig, C, JSON, Markdown). Off renders every document as plain text.", &ctx.cfg.editor_syntax, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(syntax_group)), ctx, "Bracket matching", "Box the bracket pair around the caret. Ctrl+M jumps to the match. Brackets inside strings and comments are ignored when the file has a grammar.", &ctx.cfg.editor_bracket_match, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(syntax_group)), ctx, "Code folding", "Fold column in the gutter plus Ctrl+Shift+[ / ] at the caret and Ctrl+Alt+[ / ] for all.", &ctx.cfg.editor_folding, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(syntax_group)), ctx, "Fold by indentation without a grammar", "Files sketerm has no grammar for still fold, using indentation. Off leaves them unfoldable.", &ctx.cfg.editor_fold_indent_fallback, applyOnly);
    addEditorThemeRow(@ptrCast(@alignCast(syntax_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(syntax_group)));

    const project_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(project_group)), "Project");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(project_group)), "A project is the nearest directory above a file holding a marker (a VCS directory or a build file). A file with no marker above it has no project, and everything here stays switched off for it.");
    addEntryRowString(
        @ptrCast(@alignCast(project_group)),
        ctx,
        "Root markers",
        "Comma-separated filenames that identify a project root. Empty = the built-in list (.git, build.zig, Cargo.toml, package.json, …).",
        &ctx.cfg.editor_project_markers,
        applyOnly,
    );
    addSwitchRow(@ptrCast(@alignCast(project_group)), ctx, "Git change gutter", "Added / modified / deleted markers at the gutter's right edge, against HEAD on the file's own host. F7 and Shift+F7 step between hunks.", &ctx.cfg.editor_git_gutter, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(project_group)), ctx, "Show the outline panel", "Open the symbol outline with every editor face. Ctrl+Shift+O toggles it either way.", &ctx.cfg.editor_outline, applyOnly);
    addSpinRowU32(
        @ptrCast(@alignCast(project_group)),
        ctx,
        "Project search file cap",
        "How many files one Ctrl+Shift+F may read. The daemon's grep narrows the candidates first; this only bounds a pattern it cannot pre-filter.",
        1,
        1_000_000,
        &ctx.cfg.editor_project_search_max_files,
        applyOnly,
    );
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(project_group)));

    buildLspGroup(page, ctx);

    // Font is PER-PROFILE, like the terminal font it falls back to.
    const font_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(font_group)), "Font");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(font_group)), "Part of the profile selected on the Profiles page — the editor is a face on a pane, so its font follows that pane's profile. Left unset, it follows the profile's terminal font.");
    addEditorFontFamilyRow(@ptrCast(@alignCast(font_group)), ctx);
    addSpinRowU16(@ptrCast(@alignCast(font_group)), ctx, "Editor font size", "0 = follow the profile's terminal font size.", 0, 96, &ctx.edit.editor_font_size, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(font_group)));
}

// ── Language servers ────────────────────────────────────────────
//
// App-level, not per-profile: a language server serves a LANGUAGE, and
// which pane profile a document happens to be open under says nothing
// about that (CLAUDE.md's ProfileSettings split).
//
// The per-server rows write through `Config.lspServerMut`, which
// materializes a `[lsp.<name>]` section the first time a server is
// edited. Untouched servers keep no section at all and so keep
// following the built-in table.

const LspField = enum { command, args, languages, root_files };

const LspRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    /// Registry name; lives in the dialog arena.
    name: []const u8,
    field: LspField,
};

const LspEnableCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    name: []const u8,
};

fn buildLspGroup(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    const group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(group)), "Language servers");
    c.adw_preferences_group_set_description(
        @ptrCast(@alignCast(group)),
        "LSP gives the editor diagnostics (Ctrl+Space completion, Ctrl+I hover, F12 go to definition, Shift+F12 references, F8 next problem, Ctrl+Shift+O symbols, F2 rename, Ctrl+Shift+I format, Ctrl+. code actions, Ctrl+Shift+Space signature help). A server that is not installed is skipped silently.",
    );
    addSwitchRow(@ptrCast(@alignCast(group)), ctx, "Enable language servers", "Off never spawns a server.", &ctx.cfg.editor_lsp, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(group)), ctx, "Show diagnostics", "Squiggles in the text and a stripe in the gutter.", &ctx.cfg.editor_lsp_diagnostics, applyOnly);
    addSpinRowU16(
        @ptrCast(@alignCast(group)),
        ctx,
        "Change debounce (ms)",
        "How long after the last keystroke the document is pushed to the server. Asking for a feature always pushes first.",
        10,
        5000,
        &ctx.cfg.editor_lsp_debounce_ms,
        applyOnly,
    );
    addSwitchRow(
        @ptrCast(@alignCast(group)),
        ctx,
        "Inlay hints",
        "Inline type and parameter annotations for the visible lines. They are drawn, never inserted: the file on disk is untouched.",
        &ctx.cfg.editor_lsp_inlay_hints,
        applyOnly,
    );
    addSwitchRow(
        @ptrCast(@alignCast(group)),
        ctx,
        "Semantic highlighting",
        "Let the server refine the syntax colours where it knows better. Off leaves the built-in highlighting alone.",
        &ctx.cfg.editor_lsp_semantic_tokens,
        applyOnly,
    );
    addSwitchRow(
        @ptrCast(@alignCast(group)),
        ctx,
        "Signature help",
        "Show the parameter list while typing a call, and on Ctrl+Shift+Space.",
        &ctx.cfg.editor_lsp_signature_help,
        applyOnly,
    );
    addSpinRowU16(
        @ptrCast(@alignCast(group)),
        ctx,
        "Hover delay (ms)",
        "How long the pointer must rest on a symbol before its documentation pops up. 0 turns mouse hover off; Ctrl+I still works.",
        0,
        5000,
        &ctx.cfg.editor_lsp_hover_delay_ms,
        applyOnly,
    );
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(group)));

    const list = ctx.cfg.lspServerList(ctx.arena.allocator()) catch return;
    for (list) |srv| {
        const name = ctx.dupe(srv.name) catch continue;
        const sub = c.adw_preferences_group_new();
        var title_z = cast.sliceToZ(64, name);
        c.adw_preferences_group_set_title(@ptrCast(@alignCast(sub)), &title_z);
        var desc: [256:0]u8 = undefined;
        const installed = lsp_proc.onPath(ctx.allocator, srv.command);
        const d = std.fmt.bufPrintZ(&desc, "{s}  —  {s}", .{
            if (srv.languages.len > 0) srv.languages else "no languages",
            if (installed) "installed" else "not found on PATH",
        }) catch "";
        c.adw_preferences_group_set_description(@ptrCast(@alignCast(sub)), d.ptr);
        addLspEnableRow(@ptrCast(@alignCast(sub)), ctx, name, srv.enabled);
        addLspEntryRow(@ptrCast(@alignCast(sub)), ctx, name, .command, "Command", srv.command);
        addLspEntryRow(@ptrCast(@alignCast(sub)), ctx, name, .args, "Arguments", srv.args);
        addLspEntryRow(@ptrCast(@alignCast(sub)), ctx, name, .languages, "Languages", srv.languages);
        addLspEntryRow(@ptrCast(@alignCast(sub)), ctx, name, .root_files, "Root markers", srv.root_files);
        c.adw_preferences_page_add(page, @ptrCast(@alignCast(sub)));
    }
}

fn addLspEnableRow(group: *c.AdwPreferencesGroup, ctx: *Ctx, name: []const u8, on: bool) void {
    const row = c.adw_switch_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Enabled");
    c.adw_switch_row_set_active(@ptrCast(@alignCast(row)), if (on) 1 else 0);
    const rctx = ctx.allocator.create(LspEnableCtx) catch return;
    rctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .name = name };
    _ = c.g_signal_connect_data(row, "notify::active", @ptrCast(&lspEnableChanged), @ptrCast(rctx), @ptrCast(cast.destroyCtx(LspEnableCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn lspEnableChanged(row: *c.AdwSwitchRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(LspEnableCtx, user);
    const srv = rctx.parent.cfg.lspServerMut(rctx.parent.arena.allocator(), rctx.name) orelse return;
    srv.enabled = c.adw_switch_row_get_active(row) != 0;
    rctx.parent.ev();
}

fn addLspEntryRow(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    name: []const u8,
    field: LspField,
    title: [*:0]const u8,
    value: []const u8,
) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    var z = cast.sliceToZ(256, value);
    c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    const rctx = ctx.allocator.create(LspRowCtx) catch return;
    rctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .name = name, .field = field };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&lspEntryChanged), @ptrCast(rctx), @ptrCast(cast.destroyCtx(LspRowCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn lspEntryChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(LspRowCtx, user);
    const text = rctx.parent.dupe(cast.editableText(row)) catch return;
    const srv = rctx.parent.cfg.lspServerMut(rctx.parent.arena.allocator(), rctx.name) orelse return;
    switch (rctx.field) {
        .command => srv.command = text,
        .args => srv.args = text,
        .languages => srv.languages = text,
        .root_files => srv.root_files = text,
    }
    rctx.parent.ev();
}

/// Theme picker, built from `editor/theme.zig`'s own list so adding a
/// theme there is the only edit needed.
fn addEditorThemeRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(null);
    var sel: c_uint = 0;
    for (editor_theme.all, 0..) |t, i| {
        var z = cast.sliceToZ(64, t.name);
        c.gtk_string_list_append(items, &z);
        if (std.ascii.eqlIgnoreCase(t.name, ctx.cfg.editor_theme)) sel = @intCast(i);
    }
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Theme");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Colours for syntax, selection, caret and gutter.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), sel);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = editorThemeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn editorThemeSelected(ctx: *Ctx, idx: c_uint) void {
    if (idx >= editor_theme.all.len) return;
    ctx.cfg.editor_theme = ctx.dupe(editor_theme.all[idx].name) catch return;
    ctx.ev();
}

fn addEditorFontFamilyRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Editor font family (empty = the profile's terminal font)");
    if (ctx.edit.editor_font_family.len > 0) {
        var z = cast.sliceToZ(256, ctx.edit.editor_font_family);
        c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    }
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&editorFontFamilyChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn editorFontFamilyChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const slice = cast.editableText(row);
    ctx.edit.editor_font_family = if (slice.len == 0) "" else ctx.dupe(slice) catch return;
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
    addSpinRowU32(@ptrCast(@alignCast(bell_group)), ctx, "Notify finished commands (s)", "Desktop notification when a background command ran at least this long. 0 = off; needs shell integration.", 0, 3600, &ctx.cfg.notify_command_secs, applyOnly);
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
    c.g_object_unref(items);
    const initial: c_uint = switch (ctx.cfg.confirm_close) {
        .never => 0,
        .multiple => 1,
        .always => 2,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = confirmCloseSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
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
    c.g_object_unref(items);
    const initial: c_uint = switch (ctx.cfg.tab_position) {
        .top => 0,
        .bottom => 1,
    };
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), initial);
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = tabPositionSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
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
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)), "Click an action's button to record a new shortcut. Esc cancels; " ++
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

    _ = c.g_signal_connect_data(button, "clicked", @ptrCast(&onKeybindClicked), @ptrCast(rctx), @ptrCast(cast.destroyCtx(KeybindRowCtx)), c.G_CONNECT_DEFAULT);

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
        c.GDK_KEY_Shift_L,
        c.GDK_KEY_Shift_R,
        c.GDK_KEY_Control_L,
        c.GDK_KEY_Control_R,
        c.GDK_KEY_Alt_L,
        c.GDK_KEY_Alt_R,
        c.GDK_KEY_Super_L,
        c.GDK_KEY_Super_R,
        c.GDK_KEY_Hyper_L,
        c.GDK_KEY_Hyper_R,
        c.GDK_KEY_Meta_L,
        c.GDK_KEY_Meta_R,
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
    // The list's backing array lives in the prefs arena (cloneInto);
    // growing it through the GPA would leak the GPA block on close.
    rctx.parent.cfg.keybinds.append(arena, .{
        .name = name_dup,
        .accel = accel_dup,
    }) catch return;
    rctx.parent.ev();
}

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
const TextBlending = @import("../config.zig").TextBlending;
const ExitAction = @import("../config.zig").ExitAction;
const config_mod = @import("../config.zig");
const TabPosition = @import("../config.zig").TabPosition;
const editor_theme = @import("../editor/theme.zig");
const ecmd = @import("../editor/commands.zig");
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
    /// The Colors page, kept so its colour groups can be torn down
    /// and rebuilt in place when `auto_theme` is toggled — the flat
    /// and the light/dark presentations are different widget trees.
    colors_page: ?*c.AdwPreferencesPage = null,
    /// The rebuildable groups on that page (everything below the
    /// "Theme" group). Three is the flat layout's count; the sizing
    /// is asserted in `trackColorGroup`.
    color_groups: [4]?*c.GtkWidget = .{null} ** 4,
    /// The two list-shaped families (`symbol_map.<name>`,
    /// `hint.<name>.*`) each own one group that is destroyed and
    /// rebuilt whenever an entry is added or removed — which is also
    /// what runs the removed rows' GDestroyNotify. Both groups are
    /// built LAST on their page so a rebuild's append lands them back
    /// where they were.
    appearance_page: ?*c.AdwPreferencesPage = null,
    symbol_group: ?*c.GtkWidget = null,
    behavior_page: ?*c.AdwPreferencesPage = null,
    hint_group: ?*c.GtkWidget = null,

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
    open_dialogs += 1;
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
    if (open_dialogs > 0) open_dialogs -= 1;
    ctx.arena.deinit();
    ctx.allocator.destroy(ctx);
}

/// Live preference dialogs in this process. They hold a DEEP COPY of
/// the config taken at open time, so a config reload landing underneath
/// one would be undone by the dialog's next row change; the file
/// watcher checks this and stands down instead.
var open_dialogs: u32 = 0;

pub fn isOpen() bool {
    return open_dialogs > 0;
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
    ctx.appearance_page = page;

    const font_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(font_group)), "Font");
    addFontFamilyRow(@ptrCast(@alignCast(font_group)), ctx);
    addFontPathRow(@ptrCast(@alignCast(font_group)), ctx);
    addEntryRowString(@ptrCast(@alignCast(font_group)), ctx, "Bold family", "", &ctx.edit.font_family_bold, applyOnly);
    addEntryRowString(@ptrCast(@alignCast(font_group)), ctx, "Italic family", "", &ctx.edit.font_family_italic, applyOnly);
    addEntryRowString(@ptrCast(@alignCast(font_group)), ctx, "Bold italic family", "", &ctx.edit.font_family_bold_italic, applyOnly);
    addFontWeightRow(@ptrCast(@alignCast(font_group)), ctx, "Weight", "Weight for the regular face. Also drives a variable font's wght axis.", &ctx.edit.font_weight);
    addFontWeightRow(@ptrCast(@alignCast(font_group)), ctx, "Bold weight", "Weight for the bold face.", &ctx.edit.font_weight_bold);
    addSwitchRow(@ptrCast(@alignCast(font_group)), ctx, "Built-in box drawing", "Draw box, block and Powerline characters from the cell rectangle instead of the font — they tile without seams. Off gives the font's own shapes back.", &ctx.edit.builtin_box_drawing, applyOnly);
    addFontFeaturesRow(@ptrCast(@alignCast(font_group)), ctx);
    addSpinRowU16(@ptrCast(@alignCast(font_group)), ctx, "Size", "Font size in points", 6, 72, &ctx.edit.font_size, applyOnly);
    addSpinRowI16(@ptrCast(@alignCast(font_group)), ctx, "Line spacing", "Extra pixels per cell row", -8, 24, &ctx.edit.line_pad_px, applyOnly);
    addSpinRowF32(@ptrCast(@alignCast(font_group)), ctx, "Padding", "Inner padding around the cell grid", 0.0, 32.0, &ctx.edit.padding, applyOnly);
    addTextBlendingRow(@ptrCast(@alignCast(font_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(font_group)));

    const cursor_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(cursor_group)), "Cursor");
    addCursorShapeRow(@ptrCast(@alignCast(cursor_group)), ctx);
    addSwitchRow(@ptrCast(@alignCast(cursor_group)), ctx, "Blink", "Toggle cursor visibility periodically", &ctx.cfg.cursor_blink, applyOnly);
    addSpinRowU32(@ptrCast(@alignCast(cursor_group)), ctx, "Blink interval (ms)", "Half-cycle. 500 = full blink every 1 s.", 100, 2000, &ctx.cfg.cursor_blink_ms, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(cursor_group)), ctx, "Motion trail", "Stretch a trail from the cursor's old cell to its new one. Redraws at 60 fps while a jump is in flight, and stops completely once it lands.", &ctx.cfg.cursor_trail, applyOnly);
    addSpinRowU32(@ptrCast(@alignCast(cursor_group)), ctx, "Trail duration (ms)", "How long the trail takes to catch up, and a hard cap on how long it can linger.", 30, 2000, &ctx.cfg.cursor_trail_ms, applyOnly);
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

    // Overlay scrollbar. App-level (see the comment on Config.scrollbar):
    // it is chrome, not a per-pane look.
    const sbar_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(sbar_group)), "Overlay scrollbar");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(sbar_group)), "Drawn inside the pane by the renderer, not a widget. Applies to every pane in the window.");
    addScrollbarModeRow(@ptrCast(@alignCast(sbar_group)), ctx);
    addSpinRowF32Step(@ptrCast(@alignCast(sbar_group)), ctx, "Width", "Track/thumb width in pixels. 0 also disables it.", 0.0, 64.0, 1.0, 0, &ctx.cfg.scrollbar_width, applyOnly);
    addColorRow(@ptrCast(@alignCast(sbar_group)), ctx, "Trough", &ctx.cfg.scrollbar_trough_color);
    addColorRow(@ptrCast(@alignCast(sbar_group)), ctx, "Thumb", &ctx.cfg.scrollbar_thumb_color);
    addColorRow(@ptrCast(@alignCast(sbar_group)), ctx, "Thumb while scrolled back", &ctx.cfg.scrollbar_thumb_active_color);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(sbar_group)));

    // LAST on this page: a rebuild re-appends it (see Ctx.symbol_group).
    buildSymbolMapGroup(page, ctx);
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

const ColorScheme = config_mod.ColorScheme;

const PaletteRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    index: usize, // 0..15
    /// Which colour layer the row edits. Null = the flat fields.
    variant: ?ColorScheme,
};

/// A row bound to a plain `[4]f32` config field (title bar, gradient
/// — the app-level colours, which have no light/dark variants).
const ColorRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *[4]f32,
};

const VariantColorCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    variant: ?ColorScheme,
    field: ProfileSettings.VariantColor,
};

const VariantSwitchCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    variant: ?ColorScheme,
};

const SchemeRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    variant: ?ColorScheme,
};

fn colorsPage(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    c.adw_preferences_page_set_title(page, "Colors");
    c.adw_preferences_page_set_icon_name(page, "preferences-color-symbolic");
    ctx.colors_page = page;

    // The theme switch comes first and sits in a group of its own:
    // it decides WHICH colour section is shown below it, and that
    // section is torn down and rebuilt every time it flips.
    const theme_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(theme_group)), "Theme");
    addSwitchRow(
        @ptrCast(@alignCast(theme_group)),
        ctx,
        "Auto theme",
        "Follow Adwaita dark/light at runtime. On: the light and dark sets below are what render. Off: the single flat set is.",
        &ctx.cfg.auto_theme,
        autoThemeChanged,
    );
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(theme_group)));

    buildColorGroups(page, ctx);
}

/// Rebuild the colour section in place. Removing a group drops the
/// last reference to it, which finalizes its rows and runs every
/// row context's GDestroyNotify — so a rebuild frees the old row
/// contexts rather than stacking them up.
fn autoThemeChanged(ctx: *Ctx) void {
    ctx.ev();
    const page = ctx.colors_page orelse return;
    for (&ctx.color_groups) |*slot| {
        if (slot.*) |w| c.adw_preferences_page_remove(page, @ptrCast(@alignCast(w)));
        slot.* = null;
    }
    buildColorGroups(page, ctx);
}

fn trackColorGroup(ctx: *Ctx, group: *c.GtkWidget) void {
    for (&ctx.color_groups) |*slot| {
        if (slot.* == null) {
            slot.* = group;
            return;
        }
    }
    unreachable; // color_groups is sized for the largest layout.
}

/// With `auto_theme` off there is one flat colour set, presented the
/// way sketerm always has. With it on, the flat set is not what
/// renders — `ProfileSettings.forScheme` overlays a variant over it —
/// so we show the two variants instead, one group each. Two stacked
/// groups (rather than a light/dark switcher over one set of rows)
/// mirror the `light.` / `dark.` config sections one-to-one, show
/// both halves at once so they can be compared, and need no
/// remembered "which half am I editing" state.
///
/// Two known limits of the variant layout: the flat fg/bg cannot be
/// reached from the dialog while auto_theme is on (the built-in
/// variants always cover those two, so editing the base would be the
/// inert row this replaced), and a colour meant for both halves has
/// to be set twice. Both are the honest consequence of "the row
/// shows what renders"; a "same in both" affordance would need its
/// own tri-state and is not worth it until asked for.
fn buildColorGroups(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    if (!ctx.cfg.auto_theme) {
        addFlatColorGroups(page, ctx);
        return;
    }
    addVariantGroup(page, ctx, .light);
    addVariantGroup(page, ctx, .dark);
}

fn addFlatColorGroups(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    // Scheme picker.
    const scheme_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(scheme_group)), "Scheme");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(scheme_group)), "Picking a scheme overwrites the foreground / background / palette below.");
    addSchemeRow(@ptrCast(@alignCast(scheme_group)), ctx, null);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(scheme_group)));
    trackColorGroup(ctx, @ptrCast(@alignCast(scheme_group)));

    // Defaults (fg / bg / cursor + cursor_color_default).
    const defaults_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(defaults_group)), "Defaults");
    addColorSetRows(@ptrCast(@alignCast(defaults_group)), ctx, null);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(defaults_group)));
    trackColorGroup(ctx, @ptrCast(@alignCast(defaults_group)));

    // 16-colour palette, one row per index.
    const palette_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(palette_group)), "ANSI palette (16 colours)");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(palette_group)), "Per-index colours used by SGR 30-37 / 40-47 (and bright 90-97). Editing here unsets `scheme` so your tweaks stick.");
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const row = paletteRow(ctx, i, null) orelse continue;
        c.adw_preferences_group_add(@ptrCast(@alignCast(palette_group)), row);
    }
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(palette_group)));
    trackColorGroup(ctx, @ptrCast(@alignCast(palette_group)));
}

/// One variant's complete colour set: scheme, fg/bg/cursor, and the
/// palette folded into an expander so two of these groups still fit
/// on a scannable page.
fn addVariantGroup(page: *c.AdwPreferencesPage, ctx: *Ctx, variant: ColorScheme) void {
    const group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(
        @ptrCast(@alignCast(group)),
        if (variant == .light) "Light" else "Dark",
    );
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)), if (variant == .light)
        "What renders while the system theme is light. These rows write `light.*`; anything you don't set here falls back to the built-in light pair, then to the flat colours in the config file."
    else
        "What renders while the system theme is dark. These rows write `dark.*`; anything you don't set here falls back to the built-in dark pair, then to the flat colours in the config file.");

    addSchemeRow(@ptrCast(@alignCast(group)), ctx, variant);
    addColorSetRows(@ptrCast(@alignCast(group)), ctx, variant);

    const exp = c.adw_expander_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(exp)), "ANSI palette (16 colours)");
    c.adw_expander_row_set_subtitle(@ptrCast(@alignCast(exp)), "SGR 30-37 / 40-47 and bright 90-97. Editing one unsets this variant's scheme.");
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const row = paletteRow(ctx, i, variant) orelse continue;
        c.adw_expander_row_add_row(@ptrCast(@alignCast(exp)), row);
    }
    c.adw_preferences_group_add(@ptrCast(@alignCast(group)), exp);

    c.adw_preferences_page_add(page, @ptrCast(@alignCast(group)));
    trackColorGroup(ctx, @ptrCast(@alignCast(group)));
}

/// fg / bg / cursor / cursor-uses-fg for one layer. `variant` null =
/// the flat fields (auto_theme off).
fn addColorSetRows(group: *c.AdwPreferencesGroup, ctx: *Ctx, variant: ?ColorScheme) void {
    addVariantColorRow(group, ctx, "Foreground", variant, .default_fg);
    addVariantColorRow(group, ctx, "Background", variant, .default_bg);
    addVariantColorRow(group, ctx, "Cursor", variant, .cursor_color);
    addCursorDefaultRow(group, ctx, variant);
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

/// A pane colour bound to a LAYER rather than a struct field: it
/// shows the effective value (variant override → built-in variant →
/// flat base) and writes into the layer it was built for, so the
/// swatch always matches what renders.
fn addVariantColorRow(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    variant: ?ColorScheme,
    field: ProfileSettings.VariantColor,
) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);

    const cur = ctx.edit.variantColor(variant, field);
    const dlg = c.gtk_color_dialog_new();
    const btn = c.gtk_color_dialog_button_new(dlg);
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    var rgba: c.GdkRGBA = .{ .red = cur[0], .green = cur[1], .blue = cur[2], .alpha = cur[3] };
    c.gtk_color_dialog_button_set_rgba(@ptrCast(@alignCast(btn)), &rgba);

    const vctx = ctx.allocator.create(VariantColorCtx) catch return;
    vctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .variant = variant, .field = field };
    _ = c.g_signal_connect_data(btn, "notify::rgba", @ptrCast(&variantColorChanged), @ptrCast(vctx), @ptrCast(cast.destroyCtx(VariantColorCtx)), c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn variantColorChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const vctx = cast.userData(VariantColorCtx, user);
    const rgba = c.gtk_color_dialog_button_get_rgba(btn);
    vctx.parent.edit.setVariantColor(
        vctx.variant,
        vctx.field,
        .{ rgba.*.red, rgba.*.green, rgba.*.blue, rgba.*.alpha },
    );
    vctx.parent.ev();
}

fn addCursorDefaultRow(group: *c.AdwPreferencesGroup, ctx: *Ctx, variant: ?ColorScheme) void {
    const row = c.adw_switch_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Cursor uses foreground");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Override the explicit cursor colour with the foreground.");
    c.adw_switch_row_set_active(@ptrCast(@alignCast(row)), if (ctx.edit.variantCursorDefault(variant)) 1 else 0);
    const vctx = ctx.allocator.create(VariantSwitchCtx) catch return;
    vctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .variant = variant };
    _ = c.g_signal_connect_data(row, "notify::active", @ptrCast(&cursorDefaultChanged), @ptrCast(vctx), @ptrCast(cast.destroyCtx(VariantSwitchCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn cursorDefaultChanged(row: *c.AdwSwitchRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const vctx = cast.userData(VariantSwitchCtx, user);
    vctx.parent.edit.setVariantCursorDefault(vctx.variant, c.adw_switch_row_get_active(row) != 0);
    vctx.parent.ev();
}

/// The 16 palette entries a layer resolves to: its own override,
/// else its scheme preset, else the built-in 256-table's first 16.
/// Both the swatch and the promote-on-write path go through this, so
/// editing one entry cannot silently move the other fifteen.
fn effectivePalette(ctx: *Ctx, variant: ?ColorScheme) [16][3]u8 {
    if (ctx.edit.variantPalette(variant)) |p| return p;
    if (schemes.lookup(ctx.edit.variantSchemeName(variant))) |sch| return sch.palette;
    const default_pal = @import("../grid/palette.zig").default_256;
    var pal: [16][3]u8 = undefined;
    var i: usize = 0;
    while (i < 16) : (i += 1) pal[i] = default_pal[i];
    return pal;
}

/// One palette entry's row. Returns it unparented so the caller can
/// put it in a group (flat layout) or an expander (variant layout).
fn paletteRow(ctx: *Ctx, idx: usize, variant: ?ColorScheme) ?*c.GtkWidget {
    const row = c.adw_action_row_new();
    var title_buf: [32:0]u8 = undefined;
    const title = std.fmt.bufPrintZ(&title_buf, "Color {d}", .{idx}) catch "Color";
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title.ptr);

    const cur = effectivePalette(ctx, variant)[idx];
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

    const pctx = ctx.allocator.create(PaletteRowCtx) catch return null;
    pctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .index = idx, .variant = variant };
    _ = c.g_signal_connect_data(btn, "notify::rgba", @ptrCast(&paletteRowChanged), @ptrCast(pctx), @ptrCast(cast.destroyCtx(PaletteRowCtx)), c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    return row;
}

fn paletteRowChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const pctx = cast.userData(PaletteRowCtx, user);
    const rgba = c.gtk_color_dialog_button_get_rgba(btn);
    var pal = effectivePalette(pctx.parent, pctx.variant);
    pal[pctx.index] = .{
        @intFromFloat(@round(rgba.*.red * 255.0)),
        @intFromFloat(@round(rgba.*.green * 255.0)),
        @intFromFloat(@round(rgba.*.blue * 255.0)),
    };
    // Pins the palette on this layer and unsets its `scheme` — the
    // user has overridden.
    pctx.parent.edit.setVariantPalette(pctx.variant, pal);
    pctx.parent.ev();
}

fn addSchemeRow(group: *c.AdwPreferencesGroup, ctx: *Ctx, variant: ?ColorScheme) void {
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
    const cur_scheme = ctx.edit.variantSchemeName(variant);
    for (SCHEMES, 0..) |sch, i| {
        if (std.mem.eql(u8, sch.key, cur_scheme)) {
            sel = @intCast(i);
            break;
        }
    }
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), sel);
    const sctx = ctx.allocator.create(SchemeRowCtx) catch return;
    sctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .variant = variant };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&schemeSelected), @ptrCast(sctx), @ptrCast(cast.destroyCtx(SchemeRowCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn schemeSelected(row: *c.AdwComboRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const sctx = cast.userData(SchemeRowCtx, user);
    const idx = c.adw_combo_row_get_selected(row);
    if (idx >= SCHEMES.len) return;
    const sch = SCHEMES[idx];
    const to_f = struct {
        fn f(rgb: [3]u8) [4]f32 {
            return .{
                @as(f32, @floatFromInt(rgb[0])) / 255.0,
                @as(f32, @floatFromInt(rgb[1])) / 255.0,
                @as(f32, @floatFromInt(rgb[2])) / 255.0,
                1.0,
            };
        }
    }.f;
    sctx.parent.edit.setVariantScheme(sctx.variant, sch.key, to_f(sch.fg), to_f(sch.bg), sch.palette);
    sctx.parent.ev();
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
    ctx.behavior_page = page;

    // Shell — note: applies to NEW panes, not running shells.
    const shell_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(shell_group)), "Shell (applies to new panes)");
    addShellPathRow(@ptrCast(@alignCast(shell_group)), ctx);
    addEntryRowOptionalString(@ptrCast(@alignCast(shell_group)), ctx, "TERM", "$TERM env in child", &ctx.edit.term_env, applyOnly);
    addEntryRowOptionalString(@ptrCast(@alignCast(shell_group)), ctx, "COLORTERM", "$COLORTERM env in child", &ctx.edit.color_term_env, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(shell_group)), ctx, "Login shell", "Prepend a `-` to argv[0] so the shell sources login profile.", &ctx.edit.login_shell, applyOnly);
    addExitActionRow(@ptrCast(@alignCast(shell_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(shell_group)));

    // Configuration file.
    const cfgfile_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(cfgfile_group)), "Configuration file");
    addSwitchRow(
        @ptrCast(@alignCast(cfgfile_group)),
        ctx,
        "Reload automatically",
        "Apply config.conf as soon as it changes on disk, without the reload_config keybind.",
        &ctx.cfg.config_auto_reload,
        applyOnly,
    );
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(cfgfile_group)));

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

    // LAST on this page: a rebuild re-appends it (see Ctx.hint_group).
    buildHintGroup(page, ctx);
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

/// `text_blending`: the subtitle has to warn about the weight shift,
/// because that is what a user notices first and would otherwise read
/// as "my font broke" rather than as the mode doing its job.
fn addTextBlendingRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{
        "Native (gamma space)",
        "Linear light",
        "Linear, weight-corrected",
    });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Text blending");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Native is what terminals have always done. Linear removes the dark fringe where complementary colours meet, but thins dark text and thickens light text; the corrected variant keeps the fringe fix without the weight shift.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), @intFromEnum(ctx.cfg.text_blending));
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = textBlendingSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn textBlendingSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.text_blending = std.enums.fromInt(TextBlending, @min(idx, 2)) orelse .native;
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

    const typing_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(typing_group)), "Typing");
    addSwitchRow(@ptrCast(@alignCast(typing_group)), ctx, "Auto indent", "Enter copies the line's indentation and goes one level deeper after an opening bracket; a pending closer drops onto its own line.", &ctx.cfg.editor_auto_indent, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(typing_group)), ctx, "Auto-close brackets and quotes", "Typing ( [ { \" ' ` inserts the closing half; typing the closer when it is next just moves past it, and Backspace between an empty pair deletes both. Never fires where the grammar says string or comment.", &ctx.cfg.editor_auto_close_pairs, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(typing_group)), ctx, "Smart backspace", "Backspace in a line's leading spaces retreats one tab stop instead of one space.", &ctx.cfg.editor_smart_backspace, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(typing_group)));

    const view_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(view_group)), "View");
    addSwitchRow(@ptrCast(@alignCast(view_group)), ctx, "Soft wrap by default", "New editor tabs start wrapped. Alt+Z toggles it per tab.", &ctx.cfg.editor_soft_wrap, applyOnly);
    addSwitchRow(@ptrCast(@alignCast(view_group)), ctx, "Wrap at word boundaries", "Soft wrap breaks between words (UAX #14). Off wraps at any character.", &ctx.cfg.editor_wrap_words, applyOnly);
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

    // Title templates. App-level (see Config.tab_title_template): a
    // tab strip mixing two title FORMATS reads as a bug.
    const title_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(title_group)), "Title format");
    c.adw_preferences_group_set_description(
        @ptrCast(@alignCast(title_group)),
        "Placeholders are {{ NAME }}, with || for a fallback: {{ TITLE || PROGRAM }}. " ++
            "Available: " ++ config_mod.titlefmt.field_list ++ ". " ++
            "A placeholder with no value takes its adjacent separator with it, so no template ends in a dangling dash.",
    );
    addTitleTemplateRow(
        @ptrCast(@alignCast(title_group)),
        ctx,
        "Tab label",
        &ctx.cfg.tab_title_template,
    );
    addTitleTemplateRow(
        @ptrCast(@alignCast(title_group)),
        ctx,
        "Window title (empty = just the app name)",
        &ctx.cfg.window_title_template,
    );
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(title_group)));

    const stack_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(stack_group)), "Stacking");
    addSwitchRow(@ptrCast(@alignCast(stack_group)), ctx, "Always on top", "Best effort: GTK4 has no native API; use compositor window rules. (See terminal output for hints.)", &ctx.cfg.always_on_top, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(stack_group)));

    // Confirm-on-close.
    const close_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(close_group)), "Closing");
    addConfirmCloseRow(@ptrCast(@alignCast(close_group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(close_group)));

    // Pane presentation. The borders and the corner radius are
    // pane-level (they belong to the profile being edited); the gap is
    // the space BETWEEN two panes, which no single profile owns, so it
    // is app-level. Both live here because a user thinking about "how
    // my splits look" is thinking about one thing.
    const pres_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(pres_group)), "Pane presentation");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(pres_group)), "Borders and the corner radius follow the profile being edited; the gap and its colour are window-wide.");
    addSpinRowF32Step(@ptrCast(@alignCast(pres_group)), ctx, "Border width", "Border drawn inside a pane's edge. 0 = none.", 0.0, 32.0, 1.0, 0, &ctx.edit.pane_border_width, applyOnly);
    addColorRow(@ptrCast(@alignCast(pres_group)), ctx, "Border (focused pane)", &ctx.edit.pane_border_color_active);
    addColorRow(@ptrCast(@alignCast(pres_group)), ctx, "Border (unfocused pane)", &ctx.edit.pane_border_color);
    addSpinRowF32Step(@ptrCast(@alignCast(pres_group)), ctx, "Corner radius", "Round a pane's corners. 0 = square.", 0.0, 64.0, 1.0, 0, &ctx.edit.pane_corner_radius, applyOnly);
    addSpinRowF32Step(@ptrCast(@alignCast(pres_group)), ctx, "Gap between panes", "Thickness of the split separator. Keep it a multiple of 4 — an odd separator can push a pane off the device-pixel grid at fractional scales and lose graphics offload.", 1.0, 64.0, 1.0, 0, &ctx.cfg.pane_gap, applyOnly);
    addColorRow(@ptrCast(@alignCast(pres_group)), ctx, "Gap colour", &ctx.cfg.pane_gap_color);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(pres_group)));

    // Quake mode.
    const quake_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(quake_group)), "Quake mode");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(quake_group)), "Size the primary window from a monitor instead of the 1000x700 default, for a drop-down terminal toggled with `sketerm --toggle`.");
    addSwitchRow(@ptrCast(@alignCast(quake_group)), ctx, "Enabled", "Apply the geometry below to the primary window.", &ctx.cfg.quake_enabled, applyOnly);
    addEntryRowString(@ptrCast(@alignCast(quake_group)), ctx, "Monitor (active / primary / index / connector)", "", &ctx.cfg.quake_monitor, applyOnly);
    addQuakeEdgeRow(@ptrCast(@alignCast(quake_group)), ctx);
    addSpinRowF32Step(@ptrCast(@alignCast(quake_group)), ctx, "Width (% of monitor)", "", 1.0, 100.0, 5.0, 0, &ctx.cfg.quake_width_percent, applyOnly);
    addSpinRowF32Step(@ptrCast(@alignCast(quake_group)), ctx, "Height (% of monitor)", "", 1.0, 100.0, 5.0, 0, &ctx.cfg.quake_height_percent, applyOnly);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(quake_group)));
}

/// `scrollbar` — never / auto / always, in the enum's own order.
fn addScrollbarModeRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Never", "When there is scrollback", "Always" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Show");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "There is no timed fade-out — the bar is either drawn or it is not.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), @intFromEnum(ctx.cfg.scrollbar));
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = scrollbarModeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn scrollbarModeSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.scrollbar = std.enums.fromInt(config_mod.ScrollbarMode, idx) orelse .auto;
    ctx.ev();
}

/// `quake_edge`. Kept in the dialog even though it moves nothing: the
/// key parses and serialises, so a config that already sets it must
/// survive a dialog round-trip, and a row that says why it is inert is
/// more honest than a key the UI silently cannot see. GTK4 removed
/// toplevel positioning on every backend and Wayland forbids a client
/// placing its own surface, so no code path can act on this.
fn addQuakeEdgeRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{ "Top", "Bottom", "Left", "Right" });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Edge (no effect on this backend)");
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Recorded only. Wayland forbids a client from positioning its own window and GTK4 dropped window moving everywhere, so nothing sketerm can call honours this — use a compositor window rule to place the window.");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), @intFromEnum(ctx.cfg.quake_edge));
    const cctx = ctx.allocator.create(ComboCtx) catch return;
    cctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .on_change = quakeEdgeSelected };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&comboChanged), @ptrCast(cctx), @ptrCast(cast.destroyCtx(ComboCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn quakeEdgeSelected(ctx: *Ctx, idx: c_uint) void {
    ctx.cfg.quake_edge = std.enums.fromInt(config_mod.QuakeEdge, idx) orelse .top;
    ctx.ev();
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
    /// Which binding this row edits: a window/pane action
    /// (`keybind.*`) or an editor-face command (`editor_keybind.*`).
    which: union(enum) {
        act: input_mod.Action,
        ed: ecmd.Command,
    },
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
        addKeybindRow(@ptrCast(@alignCast(group)), ctx, .{ .act = action });
    }

    const ed_group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(ed_group)), "Editor Commands");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(ed_group)), "Chords active only while the editor canvas has focus. " ++
        "Stored as editor_keybind.<command> lines; they never shadow a terminal key.");
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(ed_group)));

    inline for (@typeInfo(ecmd.Command).@"enum".fields) |field| {
        const cmd: ecmd.Command = @enumFromInt(field.value);
        addKeybindRow(@ptrCast(@alignCast(ed_group)), ctx, .{ .ed = cmd });
    }
}

fn addKeybindRow(group: *c.AdwPreferencesGroup, ctx: *Ctx, which: @FieldType(KeybindRowCtx, "which")) void {
    const row = c.adw_action_row_new();
    var label_buf: [80:0]u8 = undefined;
    const lbl = switch (which) {
        .act => |a| input_mod.actionLabel(a),
        .ed => |cmd| ecmd.label(cmd),
    };
    const lbl_len = @min(lbl.len, label_buf.len - 1);
    @memcpy(label_buf[0..lbl_len], lbl[0..lbl_len]);
    label_buf[lbl_len] = 0;
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), &label_buf);

    const button = c.gtk_button_new();
    c.gtk_widget_set_valign(button, c.GTK_ALIGN_CENTER);
    c.gtk_widget_add_css_class(button, "flat");
    c.gtk_widget_set_size_request(button, 180, -1);

    const rctx = ctx.allocator.create(KeybindRowCtx) catch return;
    rctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .which = which, .button = @ptrCast(@alignCast(button)) };

    refreshKeybindButtonLabel(rctx);

    _ = c.g_signal_connect_data(button, "clicked", @ptrCast(&onKeybindClicked), @ptrCast(rctx), @ptrCast(cast.destroyCtx(KeybindRowCtx)), c.G_CONNECT_DEFAULT);

    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), button);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn refreshKeybindButtonLabel(rctx: *KeybindRowCtx) void {
    // Look up the active accel: config override wins, otherwise the
    // default table for this row's kind.
    const action_name: []const u8 = switch (rctx.which) {
        .act => |a| input_mod.actionName(a),
        .ed => |cmd| ecmd.name(cmd),
    };
    const list = switch (rctx.which) {
        .act => rctx.parent.cfg.keybinds.items,
        .ed => rctx.parent.cfg.editor_keybinds.items,
    };
    var accel: []const u8 = "";
    var found_in_config = false;
    for (list) |kb| {
        if (std.mem.eql(u8, kb.name, action_name)) {
            accel = kb.accel;
            found_in_config = true;
            break;
        }
    }
    if (!found_in_config) {
        switch (rctx.which) {
            .act => |action| {
                // Fall back to first matching default.
                for (input_mod.default_bindings) |b| {
                    if (b.action == action) {
                        const s = input_mod.accelToString(rctx.parent.allocator, b.keyval, b.mods) catch return;
                        defer rctx.parent.allocator.free(s);
                        setButtonLabel(rctx.button, s);
                        return;
                    }
                }
            },
            .ed => |cmd| {
                setButtonLabel(rctx.button, ecmd.defaultAccel(cmd));
                return;
            },
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

/// Set or replace the override for this row in its config list
/// (`keybinds` or `editor_keybinds`). `accel` is borrowed; we dup
/// into the prefs arena.
fn setKeybind(rctx: *KeybindRowCtx, accel: []const u8) void {
    const arena = rctx.parent.arena.allocator();
    const action_name: []const u8 = switch (rctx.which) {
        .act => |a| input_mod.actionName(a),
        .ed => |cmd| ecmd.name(cmd),
    };
    const list = switch (rctx.which) {
        .act => &rctx.parent.cfg.keybinds,
        .ed => &rctx.parent.cfg.editor_keybinds,
    };
    const accel_dup = arena.dupe(u8, accel) catch return;

    // Replace existing entry, or append.
    for (list.items) |*entry| {
        if (std.mem.eql(u8, entry.name, action_name)) {
            entry.accel = accel_dup;
            rctx.parent.ev();
            return;
        }
    }
    const name_dup = arena.dupe(u8, action_name) catch return;
    // The list's backing array lives in the prefs arena (cloneInto);
    // growing it through the GPA would leak the GPA block on close.
    list.append(arena, .{
        .name = name_dup,
        .accel = accel_dup,
    }) catch return;
    rctx.parent.ev();
}

// ── Font weight ────────────────────────────────────────────────
//
// `font_weight` / `font_weight_bold` are 0 (the font's own default)
// or a CSS weight 100..900 — anything else is a config ERROR, not a
// clamp (see config.parseWeight). A spin row cannot express that
// without letting the user stop on a value the parser would reject
// and lose on the next load, so this is a combo: every item it can
// select is a value the parser accepts.

const WeightCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *u16,
    /// A weight already in the config that is not a multiple of 100
    /// (the parser accepts e.g. 350). Offered as an extra last item so
    /// opening the dialog cannot silently round it. 0 = none.
    extra: u16,
};

fn addFontWeightRow(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    subtitle: [*:0]const u8,
    field: *u16,
) void {
    const cur = field.*;
    const extra: u16 = if (cur != 0 and cur % 100 != 0) cur else 0;

    var labels: [12]?[*:0]const u8 = undefined;
    var bufs: [12][16:0]u8 = undefined;
    labels[0] = "Font default";
    var i: usize = 1;
    while (i <= 9) : (i += 1) {
        const w: u16 = @intCast(i * 100);
        _ = std.fmt.bufPrintZ(&bufs[i], "{d}", .{w}) catch continue;
        labels[i] = &bufs[i];
    }
    var count: usize = 10;
    if (extra != 0) {
        _ = std.fmt.bufPrintZ(&bufs[10], "{d}", .{extra}) catch {};
        labels[10] = &bufs[10];
        count = 11;
    }
    labels[count] = null;

    const items = c.gtk_string_list_new(@ptrCast(&labels));
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), subtitle);
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    const sel: c_uint = if (cur == 0) 0 else if (extra != 0) 10 else @intCast(cur / 100);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), sel);

    const wctx = ctx.allocator.create(WeightCtx) catch return;
    wctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field, .extra = extra };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&weightSelected), @ptrCast(wctx), @ptrCast(cast.destroyCtx(WeightCtx)), c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn weightSelected(row: *c.AdwComboRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const wctx = cast.userData(WeightCtx, user);
    const idx = c.adw_combo_row_get_selected(row);
    wctx.field.* = if (idx == 0)
        0
    else if (idx <= 9)
        @intCast(idx * 100)
    else
        wctx.extra;
    wctx.parent.ev();
}

// ── Inline validation ──────────────────────────────────────────
//
// A rejected value stays out of the working config and the row says
// why, rather than being written and then silently dropped by the
// parser on the next load.

fn markRowError(row: anytype, msg: [*:0]const u8) void {
    const w: *c.GtkWidget = @ptrCast(@alignCast(row));
    c.gtk_widget_add_css_class(w, "error");
    c.gtk_widget_set_tooltip_text(w, msg);
}

fn clearRowError(row: anytype) void {
    const w: *c.GtkWidget = @ptrCast(@alignCast(row));
    c.gtk_widget_remove_css_class(w, "error");
    c.gtk_widget_set_tooltip_text(w, null);
}

/// `markRowError` with a runtime string (validator messages are Zig
/// slices, GTK wants NUL-terminated).
fn markRowErrorSlice(row: anytype, msg: []const u8) void {
    var z = cast.sliceToZ(192, msg);
    markRowError(row, &z);
}

// ── Title templates ────────────────────────────────────────────

const TitleTemplateCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    field: *[]const u8,
};

/// Describe why a template was rejected, in the row's tooltip.
fn titleTemplateError(tmpl: []const u8, buf: []u8) ?[]const u8 {
    var diag: config_mod.titlefmt.Diag = .{};
    config_mod.titlefmt.validate(tmpl, &diag) catch |err| {
        return switch (err) {
            error.UnknownPlaceholder => std.fmt.bufPrint(
                buf,
                "Unknown placeholder '{s}'. Available: {s}",
                .{ diag.name, config_mod.titlefmt.field_list },
            ) catch "Unknown placeholder.",
            error.UnterminatedPlaceholder => "Unterminated '{{' - every placeholder needs a closing '}}'.",
        };
    };
    return null;
}

/// An entry row whose value must pass `titlefmt.validate`. The parser
/// REJECTS a bad template (it falls back to the default), so this
/// rejects too rather than writing a value the next load would drop.
fn addTitleTemplateRow(
    group: *c.AdwPreferencesGroup,
    ctx: *Ctx,
    title: [*:0]const u8,
    field: *[]const u8,
) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    var z = cast.sliceToZ(256, field.*);
    c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    var err_buf: [256]u8 = undefined;
    if (titleTemplateError(field.*, &err_buf)) |msg| markRowErrorSlice(row, msg);
    const tctx = ctx.allocator.create(TitleTemplateCtx) catch return;
    tctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .field = field };
    _ = c.g_signal_connect_data(
        row,
        "changed",
        @ptrCast(&titleTemplateChanged),
        @ptrCast(tctx),
        @ptrCast(cast.destroyCtx(TitleTemplateCtx)),
        c.G_CONNECT_DEFAULT,
    );
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn titleTemplateChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const tctx = cast.userData(TitleTemplateCtx, user);
    const text = cast.editableText(row);
    var err_buf: [256]u8 = undefined;
    if (titleTemplateError(text, &err_buf)) |msg| {
        // Half-typed input is invalid on the way to being valid, so
        // flag it and leave the working config on its last good value.
        markRowErrorSlice(row, msg);
        return;
    }
    clearRowError(row);
    const dup = tctx.parent.dupe(text) catch return;
    tctx.field.* = dup;
    tctx.parent.ev();
}

// ── Symbol maps (symbol_map.<name>) ────────────────────────────
//
// App-level: this is about glyph COVERAGE, which does not sensibly
// differ between two panes of the same session.
//
// An entry's name is its config key and is fixed at creation — a
// live-renaming entry row would rewrite a key on every keystroke and
// could collide mid-word. Delete and re-add to rename.

const SymbolField = enum { range, family };

const SymbolRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    /// Entry name; lives in the dialog arena, which outlives the row.
    name: []const u8,
    field: SymbolField,
};

/// Which list an add/remove button acts on.
const ListKind = enum { symbol_map, hint_rule };

const ListRemoveCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    name: []const u8,
    kind: ListKind,
};

const AddEntryCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    kind: ListKind,
    /// The rows the Add button reads. For a hint rule only `name` is
    /// used; a rule with no pattern is inert but round-trips, whereas a
    /// symbol map with no family or range does not.
    name_row: *c.GtkWidget,
    range_row: ?*c.GtkWidget = null,
    family_row: ?*c.GtkWidget = null,
};

fn buildSymbolMapGroup(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    const group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(group)), "Symbol maps");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)), "Route a Unicode range to a specific font family \xe2\x80\x94 Powerline glyphs from a Nerd Font, say. Consulted before the primary face, so the mapped font wins even where the main font has glyphs of its own. Applies to every pane.");

    for (ctx.cfg.symbol_maps.items) |sm| {
        const name = ctx.dupe(sm.name) catch continue;
        const exp = c.adw_expander_row_new();
        var title_z = cast.sliceToZ(96, name);
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(exp)), &title_z);
        var range_buf: [32]u8 = undefined;
        const range = config_mod.formatCodepointRange(&range_buf, sm.lo, sm.hi);
        var sub_buf: [192:0]u8 = undefined;
        const sub = std.fmt.bufPrintZ(&sub_buf, "{s}  \xe2\x86\x92  {s}", .{
            range,
            if (sm.family.len > 0) sm.family else "(no family \xe2\x80\x94 not saved)",
        }) catch "";
        c.adw_expander_row_set_subtitle(@ptrCast(@alignCast(exp)), sub.ptr);

        addSymbolFieldRow(@ptrCast(@alignCast(exp)), ctx, name, .range, "Range", range);
        addSymbolFieldRow(@ptrCast(@alignCast(exp)), ctx, name, .family, "Font family", sm.family);
        addRemoveRow(@ptrCast(@alignCast(exp)), ctx, name, .symbol_map, "Remove this symbol map");
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), @ptrCast(@alignCast(exp)));
    }

    addSymbolMapAddRow(@ptrCast(@alignCast(group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(group)));
    ctx.symbol_group = @ptrCast(@alignCast(group));
}

fn addSymbolFieldRow(
    exp: *c.AdwExpanderRow,
    ctx: *Ctx,
    name: []const u8,
    field: SymbolField,
    title: [*:0]const u8,
    value: []const u8,
) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    var z = cast.sliceToZ(256, value);
    c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    if (field == .family and value.len == 0)
        markRowError(row, "A symbol map with no family does nothing and is not written to the config file.");
    const rctx = ctx.allocator.create(SymbolRowCtx) catch return;
    rctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .name = name, .field = field };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&symbolFieldChanged), @ptrCast(rctx), @ptrCast(cast.destroyCtx(SymbolRowCtx)), c.G_CONNECT_DEFAULT);
    c.adw_expander_row_add_row(exp, @ptrCast(@alignCast(row)));
}

fn symbolFieldChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(SymbolRowCtx, user);
    const text = cast.editableText(row);
    const sm = rctx.parent.cfg.findSymbolMap(rctx.name) orelse return;
    switch (rctx.field) {
        .range => {
            const r = config_mod.parseCodepointRange(text) catch {
                markRowError(row, "Expected a hex codepoint or range: U+E0A0 or U+E0A0-U+E0A3 (the high end may not be below the low one, and neither may exceed U+10FFFF).");
                return;
            };
            clearRowError(row);
            sm.lo = r.lo;
            sm.hi = r.hi;
        },
        .family => {
            if (text.len == 0) {
                markRowError(row, "A symbol map with no family does nothing and is not written to the config file.");
            } else {
                clearRowError(row);
            }
            sm.family = rctx.parent.dupe(text) catch return;
        },
    }
    rctx.parent.ev();
}

/// Name + range + family, validated together: a half-filled symbol map
/// is not representable in the config file, so the entry is only
/// created once all three are good.
fn addSymbolMapAddRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const exp = c.adw_expander_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(exp)), "Add a symbol map");

    const name_row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(name_row)), "Name (the config key)");
    c.adw_expander_row_add_row(@ptrCast(@alignCast(exp)), @ptrCast(@alignCast(name_row)));

    const range_row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(range_row)), "Range (U+E0A0-U+E0A3)");
    c.adw_expander_row_add_row(@ptrCast(@alignCast(exp)), @ptrCast(@alignCast(range_row)));

    const family_row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(family_row)), "Font family");
    c.adw_expander_row_add_row(@ptrCast(@alignCast(exp)), @ptrCast(@alignCast(family_row)));

    const btn_row = c.adw_action_row_new();
    const btn = c.gtk_button_new_with_label("Add");
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    c.gtk_widget_add_css_class(btn, "suggested-action");
    const actx = ctx.allocator.create(AddEntryCtx) catch return;
    actx.* = .{
        .allocator = ctx.allocator,
        .parent = ctx,
        .kind = .symbol_map,
        .name_row = @ptrCast(@alignCast(name_row)),
        .range_row = @ptrCast(@alignCast(range_row)),
        .family_row = @ptrCast(@alignCast(family_row)),
    };
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onAddListEntry), @ptrCast(actx), @ptrCast(cast.destroyCtx(AddEntryCtx)), c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(btn_row)), btn);
    c.adw_expander_row_add_row(@ptrCast(@alignCast(exp)), @ptrCast(@alignCast(btn_row)));

    c.adw_preferences_group_add(group, @ptrCast(@alignCast(exp)));
}

// ── Hint rules (hint.<name>.{regex,action,command}) ────────────

const HintField = enum { regex, command };

const HintRowCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    name: []const u8,
    field: HintField,
};

const HintActionCtx = struct {
    allocator: std.mem.Allocator,
    parent: *Ctx,
    name: []const u8,
};

fn buildHintGroup(page: *c.AdwPreferencesPage, ctx: *Ctx) void {
    const group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(group)), "Hints");
    c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)), "Hint mode labels every match on screen so it can be picked from the keyboard. Your rules are scanned BEFORE the built-in URL / path / hash scanners, so a rule can claim text those would have taken.");

    addHintAlphabetRow(@ptrCast(@alignCast(group)), ctx);
    addSwitchRow(@ptrCast(@alignCast(group)), ctx, "Start in multi-select", "Each label appends its match instead of activating and closing. Tab toggles it in-mode either way.", &ctx.cfg.hint_multiple, applyOnly);

    for (ctx.cfg.hint_rules.items) |hr| {
        const name = ctx.dupe(hr.name) catch continue;
        const exp = c.adw_expander_row_new();
        var title_z = cast.sliceToZ(96, name);
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(exp)), &title_z);
        var sub_buf: [256:0]u8 = undefined;
        const sub = std.fmt.bufPrintZ(&sub_buf, "{s}  \xe2\x86\x92  {s}", .{
            if (hr.pattern.len > 0) hr.pattern else "(no pattern \xe2\x80\x94 matches nothing)",
            @tagName(hr.action),
        }) catch "";
        c.adw_expander_row_set_subtitle(@ptrCast(@alignCast(exp)), sub.ptr);

        addHintFieldRow(@ptrCast(@alignCast(exp)), ctx, name, .regex, "Pattern (POSIX extended regex)", hr.pattern);
        addHintActionRow(@ptrCast(@alignCast(exp)), ctx, name, hr.action);
        addHintFieldRow(@ptrCast(@alignCast(exp)), ctx, name, .command, "Command ({match} is substituted)", hr.command);
        addRemoveRow(@ptrCast(@alignCast(exp)), ctx, name, .hint_rule, "Remove this rule");
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), @ptrCast(@alignCast(exp)));
    }

    addHintRuleAddRow(@ptrCast(@alignCast(group)), ctx);
    c.adw_preferences_page_add(page, @ptrCast(@alignCast(group)));
    ctx.hint_group = @ptrCast(@alignCast(group));
}

fn addHintAlphabetRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Label alphabet (empty = built-in home-row set)");
    var z = cast.sliceToZ(128, ctx.cfg.hint_alphabet);
    c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    // User-data is the dialog's main Ctx (freed by onClosed) — no
    // destroy-notify, same as the shell row.
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&hintAlphabetChanged), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

fn hintAlphabetChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    const text = cast.editableText(row);
    if (text.len > 0) {
        config_mod.checkHintAlphabet(text) catch |err| {
            markRowErrorSlice(row, config_mod.alphabetErrorText(err));
            return;
        };
    }
    clearRowError(row);
    ctx.cfg.hint_alphabet = ctx.dupe(text) catch return;
    ctx.ev();
}

fn addHintFieldRow(
    exp: *c.AdwExpanderRow,
    ctx: *Ctx,
    name: []const u8,
    field: HintField,
    title: [*:0]const u8,
    value: []const u8,
) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    var z = cast.sliceToZ(512, value);
    c.gtk_editable_set_text(@ptrCast(@alignCast(row)), &z);
    if (field == .regex and value.len > 0 and !config_mod.hintPatternCompiles(value))
        markRowError(row, "This is not a valid POSIX extended regex \xe2\x80\x94 the rule is skipped while it does not compile.");
    const rctx = ctx.allocator.create(HintRowCtx) catch return;
    rctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .name = name, .field = field };
    _ = c.g_signal_connect_data(row, "changed", @ptrCast(&hintFieldChanged), @ptrCast(rctx), @ptrCast(cast.destroyCtx(HintRowCtx)), c.G_CONNECT_DEFAULT);
    c.adw_expander_row_add_row(exp, @ptrCast(@alignCast(row)));
}

fn hintFieldChanged(row: *c.GtkEditable, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(HintRowCtx, user);
    const text = cast.editableText(row);
    const dup = rctx.parent.dupe(text) catch return;
    const rule = rctx.parent.cfg.findHintRule(rctx.name) orelse return;
    switch (rctx.field) {
        // The parser stores any pattern and hint mode drops the rule if
        // it fails to compile, so an uncompilable regex is FLAGGED, not
        // rejected — refusing it here would be stricter than the file.
        .regex => {
            if (text.len > 0 and !config_mod.hintPatternCompiles(text)) {
                markRowError(row, "This is not a valid POSIX extended regex \xe2\x80\x94 the rule is skipped while it does not compile.");
            } else {
                clearRowError(row);
            }
            rule.pattern = dup;
        },
        .command => rule.command = dup,
    }
    rctx.parent.ev();
}

fn addHintActionRow(exp: *c.AdwExpanderRow, ctx: *Ctx, name: []const u8, action: config_mod.HintAction) void {
    const items = c.gtk_string_list_new(&[_:null]?[*:0]const u8{
        "Open (URL to the desktop, file to the editor)",
        "Copy to clipboard",
        "Paste into the pane",
        "Select",
        "Run the command below",
    });
    const row = c.adw_combo_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "Action");
    c.adw_combo_row_set_model(@ptrCast(@alignCast(row)), @ptrCast(@alignCast(items)));
    c.g_object_unref(items);
    c.adw_combo_row_set_selected(@ptrCast(@alignCast(row)), @intFromEnum(action));
    const actx = ctx.allocator.create(HintActionCtx) catch return;
    actx.* = .{ .allocator = ctx.allocator, .parent = ctx, .name = name };
    _ = c.g_signal_connect_data(row, "notify::selected", @ptrCast(&hintActionSelected), @ptrCast(actx), @ptrCast(cast.destroyCtx(HintActionCtx)), c.G_CONNECT_DEFAULT);
    c.adw_expander_row_add_row(exp, @ptrCast(@alignCast(row)));
}

fn hintActionSelected(row: *c.AdwComboRow, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const actx = cast.userData(HintActionCtx, user);
    const rule = actx.parent.cfg.findHintRule(actx.name) orelse return;
    rule.action = std.enums.fromInt(config_mod.HintAction, c.adw_combo_row_get_selected(row)) orelse return;
    actx.parent.ev();
}

fn addHintRuleAddRow(group: *c.AdwPreferencesGroup, ctx: *Ctx) void {
    const row = c.adw_entry_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "New rule (name)");
    const btn = c.gtk_button_new_with_label("Add");
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    c.gtk_widget_add_css_class(btn, "suggested-action");
    const actx = ctx.allocator.create(AddEntryCtx) catch return;
    actx.* = .{
        .allocator = ctx.allocator,
        .parent = ctx,
        .kind = .hint_rule,
        .name_row = @ptrCast(@alignCast(row)),
    };
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onAddListEntry), @ptrCast(actx), @ptrCast(cast.destroyCtx(AddEntryCtx)), c.G_CONNECT_DEFAULT);
    c.adw_entry_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_preferences_group_add(group, @ptrCast(@alignCast(row)));
}

// ── Shared add / remove plumbing ───────────────────────────────

fn addRemoveRow(exp: *c.AdwExpanderRow, ctx: *Ctx, name: []const u8, kind: ListKind, title: [*:0]const u8) void {
    const row = c.adw_action_row_new();
    c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), title);
    const btn = c.gtk_button_new_with_label("Remove");
    c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
    c.gtk_widget_add_css_class(btn, "destructive-action");
    const rctx = ctx.allocator.create(ListRemoveCtx) catch return;
    rctx.* = .{ .allocator = ctx.allocator, .parent = ctx, .name = name, .kind = kind };
    _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onRemoveListEntry), @ptrCast(rctx), @ptrCast(cast.destroyCtx(ListRemoveCtx)), c.G_CONNECT_DEFAULT);
    c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
    c.adw_expander_row_add_row(exp, @ptrCast(@alignCast(row)));
}

fn onRemoveListEntry(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(ListRemoveCtx, user);
    // Read everything BEFORE the rebuild: it destroys this button,
    // which runs this context's GDestroyNotify.
    const ctx = rctx.parent;
    const kind = rctx.kind;
    switch (kind) {
        .symbol_map => _ = ctx.cfg.removeSymbolMap(rctx.name),
        .hint_rule => _ = ctx.cfg.removeHintRule(rctx.name),
    }
    ctx.ev();
    rebuildListGroup(ctx, kind);
}

fn onAddListEntry(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const actx = cast.userData(AddEntryCtx, user);
    const ctx = actx.parent;
    const kind = actx.kind;
    const arena = ctx.arena.allocator();
    const name = std.mem.trim(u8, cast.editableText(actx.name_row), &std.ascii.whitespace);

    config_mod.checkEntryName(name) catch |err| {
        markRowErrorSlice(actx.name_row, config_mod.nameErrorText(err));
        return;
    };
    switch (kind) {
        .symbol_map => {
            if (ctx.cfg.findSymbolMap(name) != null) {
                markRowErrorSlice(actx.name_row, config_mod.nameErrorText(error.DuplicateName));
                return;
            }
            const range_row = actx.range_row orelse return;
            const family_row = actx.family_row orelse return;
            const range = cast.editableText(range_row);
            const family = std.mem.trim(u8, cast.editableText(family_row), &std.ascii.whitespace);
            _ = config_mod.parseCodepointRange(range) catch {
                markRowError(range_row, "Expected a hex codepoint or range: U+E0A0 or U+E0A0-U+E0A3.");
                return;
            };
            if (family.len == 0) {
                markRowError(family_row, "A symbol map needs a font family \xe2\x80\x94 without one it is not written to the config file.");
                return;
            }
            clearRowError(actx.name_row);
            clearRowError(range_row);
            clearRowError(family_row);
            _ = ctx.cfg.addSymbolMap(arena, name, range, family) catch return;
        },
        .hint_rule => {
            if (ctx.cfg.findHintRule(name) != null) {
                markRowErrorSlice(actx.name_row, config_mod.nameErrorText(error.DuplicateName));
                return;
            }
            clearRowError(actx.name_row);
            _ = ctx.cfg.addHintRule(arena, name) catch return;
        },
    }
    ctx.ev();
    rebuildListGroup(ctx, kind);
}

/// Tear the list's group down and build it again. Dropping the group
/// finalizes its rows, which runs every row context's GDestroyNotify —
/// so add/remove cycles free their contexts instead of stacking them.
/// Both groups are the LAST on their page, so re-adding restores the
/// original order.
fn rebuildListGroup(ctx: *Ctx, kind: ListKind) void {
    switch (kind) {
        .symbol_map => {
            const page = ctx.appearance_page orelse return;
            if (ctx.symbol_group) |g| c.adw_preferences_page_remove(page, @ptrCast(@alignCast(g)));
            ctx.symbol_group = null;
            buildSymbolMapGroup(page, ctx);
        },
        .hint_rule => {
            const page = ctx.behavior_page orelse return;
            if (ctx.hint_group) |g| c.adw_preferences_page_remove(page, @ptrCast(@alignCast(g)));
            ctx.hint_group = null;
            buildHintGroup(page, ctx);
        },
    }
}

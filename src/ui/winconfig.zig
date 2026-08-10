//! Config, profile and shader application — live config reload, pane
//! config pushes, profile/shader pickers, CSS/keybind refresh — split
//! out of window.zig. Functions keep the owning *Window receiver and
//! are aliased back into Window.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Config = @import("../config.zig").Config;
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const Window = winmod.Window;
const shader_preset_mod = @import("../shader_preset.zig");
const logActionError = winmod.logActionError;
const connectManualPopoverClose = winmod.connectManualPopoverClose;
const isDarkBg = winmod.isDarkBg;
const ProfileSettings = @import("../config.zig").ProfileSettings;
const ColorScheme = @import("../config.zig").ColorScheme;

const ProfileButtonCtx = struct {
    window: *Window,
    profile_name: [:0]u8, // owned, freed by GDestroyNotify
    popover: *c.GtkWidget,
    allocator: std.mem.Allocator,
    /// Target pane, captured at popover build time. Resolving the
    /// focused pane at CLICK time silently fails: the popover's
    /// button holds the window focus by then, so focusedPane()
    /// returns null. Null for the new-tab flow (no target pane).
    pane: ?*Pane = null,
};

const ColorPair = struct { fg: [4]f32, bg: [4]f32 };

/// `config.TextBlending` -> the render layer's mirror of it. The two
/// enums are separate because `render/blend.zig` must not import
/// config (which compiles into the libc-only `sketerm-mux`), and this
/// switch is what keeps them from silently diverging.
fn textBlendMode(v: @import("../config.zig").TextBlending) @import("../render/blend.zig").Mode {
    return switch (v) {
        .native => .native,
        .linear => .linear,
        .linear_corrected => .linear_corrected,
    };
}

const PresetButtonCtx = struct {
    window: *Window,
    preset_name: [:0]u8, // owned, freed by GDestroyNotify
    popover: *c.GtkWidget,
    allocator: std.mem.Allocator,
    /// Target pane, captured at popover build time (the popover
    /// button holds the window focus at click time, so resolving
    /// focusedPane() then returns null). Null = delete-only ctx.
    pane: ?*Pane = null,
};
/// Carries its own allocator: the picker's cancel callback can fire
/// while the parent window is being torn down, and freeing the ctx
/// must not dereference `win` then.
const ShaderPickCtx = struct {
    win: *Window,
    pane: *Pane,
    allocator: std.mem.Allocator,
};


/// Look up a named profile in the active Config, or null if no
/// such profile exists. Caller-borrowed slice (Config arena).
pub fn findProfile(self: *const Window, name: []const u8) ?*const @import("../config.zig").Profile {
    if (name.len == 0) return null;
    for (self.config.profiles.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// "Pane Shader…": pick a GLSL file for the focused pane only.
/// The pick is sticky across config reloads (custom_shader_user).
pub fn pickPaneShader(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    // Start where the user will actually find shaders: the folder of
    // the pane's current pick, else the shipped presets directory.
    const start: ?[]const u8 = if (pane.surface.custom_shader_path) |cur|
        std.fs.path.dirname(cur)
    else if (shaderPresetDirZ()) |dir|
        std.mem.span(dir)
    else
        null;
    const ctx = self.allocator.create(ShaderPickCtx) catch return;
    ctx.* = .{ .win = self, .pane = pane, .allocator = self.allocator };
    _ = @import("picker.zig").PickerWindow.open(
        self.allocator,
        @ptrCast(self.app_window),
        .{
            .mode = .open_file,
            .title = "Choose Pane Shader (GLSL, shadertoy mainImage)",
            .initial_spec = start,
            .filters = &.{
                .{ .label = "Shaders", .patterns = &.{ "*.glsl", "*.frag", "*.fs", "*.shader" } },
            },
        },
        &onShaderPicked,
        @ptrCast(ctx),
    ) catch {
        self.allocator.destroy(ctx);
        return;
    };
}

/// Directory holding the shipped CRT shader presets, or null.
/// Same resolution order as the shell-integration scripts:
/// installed share dir next to the exe → repo data/ (dev tree)
/// → /usr/share. Resolved once, cached for the process.
pub fn shaderPresetDirZ() ?[*:0]const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
        var resolved: ?[*:0]const u8 = null;
        var done: bool = false;
    };
    if (S.done) return S.resolved;
    S.done = true;
    var exe_buf: [4096]u8 = undefined;
    if (@import("../util/platform.zig").exePath(&exe_buf)) |exe_path| {
        const exe_dir = std.fs.path.dirname(exe_path) orelse "/usr/bin";
        const candidates = [_][]const u8{
            "/../share/sketerm/shaders",
            "/../../data/shaders",
        };
        for (candidates) |suffix| {
            const cand = std.fmt.bufPrintZ(&S.buf, "{s}{s}", .{ exe_dir, suffix }) catch continue;
            if (c.access(cand.ptr, c.R_OK) == 0) {
                S.resolved = cand.ptr;
                return S.resolved;
            }
        }
    }
    const sys = std.fmt.bufPrintZ(&S.buf, "/usr/share/sketerm/shaders", .{}) catch return null;
    if (c.access(sys.ptr, c.R_OK) == 0) S.resolved = sys.ptr;
    return S.resolved;
}

/// The shader_params items slice may have been reallocated (or
/// the config arena swapped) — re-point every Source at it.
pub fn repointShaderOverrides(self: *Window) void {
    self.shader_source.overrides = self.config.shader_params.items;
    for (self.panes.items) |p| {
        // A preset pane owns its override slice — leave it alone.
        if (!p.hasOwnShaderParams())
            p.surface.shader_own.overrides = self.config.shader_params.items;
    }
}

/// Route a shader-param edit: a preset pane edits its own per-
/// pane set (saved via the preset, not the config); a plain pane
/// edits the global config entry.
pub fn setPaneShaderParam(self: *Window, pane: *Pane, name: []const u8, value: f32, color: ?[3]f32) void {
    if (pane.hasOwnShaderParams()) {
        pane.setPresetParam(name, value, color);
    } else {
        self.setShaderParam(name, value, color);
    }
}

/// Load + apply a named shader preset to `pane`. False when the
/// preset (or its shader file) can't be read.
pub fn applyShaderPresetByName(self: *Window, pane: *Pane, name: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const preset = shader_preset_mod.load(arena_state.allocator(), name) catch return false;
    if (preset.shader_path.len == 0) return false;
    if (!pane.setCustomShader(preset.shader_path, preset.animate, true)) return false;
    pane.applyShaderPresetParams(name, preset.params);
    return true;
}

/// Set (or update) one shader_param override, live + persisted.
/// Called per slider tick from the shader config dialog — values
/// upload each frame, so the very next render shows it.
pub fn setShaderParam(self: *Window, name: []const u8, value: f32, color: ?[3]f32) void {
    if (self.config.arena == null) {
        // Defaults-only config (no file yet) has no arena to own
        // the entry name; give it one.
        self.config.arena = std.heap.ArenaAllocator.init(self.allocator);
    }
    const arena = self.config.arena.?.allocator();
    var found = false;
    for (self.config.shader_params.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.value = value;
            entry.color = color;
            found = true;
            break;
        }
    }
    if (!found) {
        const name_dup = arena.dupe(u8, name) catch return;
        self.config.shader_params.append(arena, .{
            .name = name_dup,
            .value = value,
            .color = color,
        }) catch return;
    }
    repointShaderOverrides(self);
    for (self.panes.items) |p| c.gtk_gl_area_queue_render(@ptrCast(p.surface.area));
    persistConfig(self);
}

pub fn clearPaneShader(self: *Window) void {
    const pane = self.focusedPane() orelse return;
    // Strictly per-pane: explicit, sticky "no shader" — overrides
    // profile/global and survives config reloads (Pane.shader_cleared).
    pane.dropShaderPreset(self.config.shader_params.items);
    pane.clearShader();
}

/// applyPaneConfig with the pane's stored profile re-resolved by
/// name — for paths that need a config re-push outside the
/// spawn/restore flows.
pub fn applyPaneConfigByName(self: *Window, pane: *Pane) void {
    var profile: ?*const @import("../config.zig").Profile = null;
    if (pane.active_profile) |name| {
        for (self.config.profiles.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) {
                profile = p;
                break;
            }
        }
    }
    self.applyPaneConfig(pane, .{ .profile = profile });
}

/// Push the pane's effective settings bundle (its profile, or
/// the Default settings) + app-level config onto a fresh pane +
/// its terminal. The single source of truth for ALL
/// pane-creation paths (new tab/split, layout restore,
/// addTabInternal) — restored panes used to skip the color push
/// entirely and kept the built-in gray background.
/// Translate the config's symbol maps into the atlas's own type once
/// per config generation. Panes borrow this slice for the lifetime of
/// the config, so it must not be rebuilt while one is mid-atlas —
/// which is why it is rebuilt exactly where the config is replaced.
pub fn rebuildSymbolSpecs(self: *Window) void {
    self.symbol_specs.clearRetainingCapacity();
    for (self.config.symbol_maps.items) |sm| {
        if (sm.family.len == 0) continue;
        self.symbol_specs.append(self.allocator, .{
            .lo = sm.lo,
            .hi = sm.hi,
            .family = sm.family,
        }) catch return;
    }
}

/// The atlas options a settings bundle resolves to. Every string in
/// here is borrowed from the config arena and `symbol_maps` from
/// `Window.symbol_specs`, so a pane's copy MUST be rebuilt through
/// this on every config change — see the call in applyConfigChange.
pub fn fontOptsFor(
    self: *const Window,
    s: *const @import("../config.zig").ProfileSettings,
) @import("../render/atlas.zig").Atlas.Options {
    return .{
        .line_pad_px = s.line_pad_px,
        .bold_family = s.font_family_bold,
        .italic_family = s.font_family_italic,
        .bold_italic_family = s.font_family_bold_italic,
        .weight = s.font_weight,
        .bold_weight = s.font_weight_bold,
        .symbol_maps = self.symbol_specs.items,
        .builtin_box = s.builtin_box_drawing,
    };
}

/// True when two atlas option sets differ in anything that requires
/// rebuilding the pane's font (families, weights, box drawing, symbol
/// maps). `line_pad_px` is compared separately by the callers, which
/// keep their own copy of it.
fn fontOptsDiffer(
    a: @import("../render/atlas.zig").Atlas.Options,
    b: @import("../render/atlas.zig").Atlas.Options,
) bool {
    if (a.weight != b.weight or a.bold_weight != b.bold_weight) return true;
    if (a.builtin_box != b.builtin_box) return true;
    if (!std.mem.eql(u8, a.bold_family, b.bold_family)) return true;
    if (!std.mem.eql(u8, a.italic_family, b.italic_family)) return true;
    if (!std.mem.eql(u8, a.bold_italic_family, b.bold_italic_family)) return true;
    if (a.symbol_maps.len != b.symbol_maps.len) return true;
    for (a.symbol_maps, b.symbol_maps) |x, y| {
        if (x.lo != y.lo or x.hi != y.hi) return true;
        if (!std.mem.eql(u8, x.family, y.family)) return true;
    }
    return false;
}

pub fn applyPaneConfig(self: *Window, pane: *Pane, opts: Window.PaneConfigOpts) void {
    const s: *const @import("../config.zig").ProfileSettings =
        if (opts.profile) |p| &p.settings else &self.config.settings;
    const term = pane.terminal;

    pane.surface.font_size = opts.font_size_override orelse s.font_size;
    pane.surface.font_path = s.font_path;
    pane.surface.font_family = if (s.font_family.len > 0) s.font_family else null;
    pane.surface.font_features = if (s.font_features.len > 0) s.font_features else null;
    pane.surface.font_opts = fontOptsFor(self, s);
    pane.surface.cursor_blink_us = @as(i64, @intCast(self.config.cursor_blink_ms)) * 1000;
    pane.restartBlinkTimer();
    pane.applyTrailConfig(self.config.cursor_trail, self.config.cursor_trail_ms);
    pane.setGraphicsOffload(self.config.graphics_offload);
    pane.app_view_tab = self.config.app_view == .tab;
    pane.surface.line_pad_px = s.line_pad_px;
    pane.surface.grid_pass.pad = s.padding;
    pane.surface.cell_pass.pad = s.padding;
    pane.surface.bg_pass.source = &self.bg_source;
    // Push config-driven defaults onto the screen so OSC 4/10/11
    // queries reply with the configured values until apps override,
    // and so DSR ?996 / mode 2031 start from the effective bg's
    // luminance — that's what apps actually want to know (vim
    // background=dark/light).
    pushPaneColors(self, pane, s);
    pane.surface.grid_pass.enable_ligatures = self.config.ligatures;
    pane.surface.grid_pass.enable_bidi = self.config.bidi;
    pane.surface.text_blending = textBlendMode(self.config.text_blending);
    applyPanePresentation(self, pane, s);
    term.screen.scrollback_capacity = s.scrollback;
    pane.surface.image_store.budget_bytes = @as(usize, self.config.image_memory_mb) * 1024 * 1024;
    term.screen.kitty_images.budget_bytes = @as(usize, self.config.image_memory_mb) * 1024 * 1024;
    term.screen.bracketed_paste = self.config.bracketed_paste;
    term.screen.scroll_on_output = self.config.scroll_on_output;
    // Master switch for the drain's visible-change detection; the
    // per-tab effect toggles only control what's drawn from it.
    term.screen.track_activity = self.config.track_tab_activity;
    term.screen.allow_clipboard_read = self.config.clipboard_read;
    term.screen.word_chars = self.config.word_chars;

    // Shader resolution: explicit user pick / clear > profile
    // settings. Both the pick and an explicit clear are sticky —
    // config reloads / profile pushes leave them alone.
    pane.surface.shader_default_source = &self.shader_source;
    if (!pane.hasOwnShaderParams())
        pane.surface.shader_own.overrides = self.config.shader_params.items;
    if (!pane.surface.custom_shader_user and !pane.surface.shader_cleared) {
        _ = pane.setCustomShader(
            if (s.custom_shader.len > 0) s.custom_shader else null,
            self.config.custom_shader_animation,
            false,
        );
    }
    pane.refreshShaderBinding();
    pane.updateShaderTick();
}

/// Push the pane-presentation settings (border, corner radius, and
/// the window-level overlay scrollbar) into the render passes. Split
/// out of `applyPaneConfig` because the live-reload path needs the
/// same six assignments. All plain values — nothing here borrows the
/// config arena, so a config swap cannot dangle them.
pub fn applyPanePresentation(
    self: *Window,
    pane: *Pane,
    s: *const @import("../config.zig").ProfileSettings,
) void {
    pane.surface.grid_pass.border_width = s.pane_border_width;
    pane.surface.grid_pass.border_color_active = s.pane_border_color_active;
    pane.surface.grid_pass.border_color = s.pane_border_color;
    pane.surface.shader_pass.corner_radius = s.pane_corner_radius;
    pane.surface.grid_pass.scrollbar_mode = self.config.scrollbar;
    pane.surface.grid_pass.scrollbar_width = self.config.scrollbar_width;
    pane.surface.grid_pass.scrollbar_trough_color = self.config.scrollbar_trough_color;
    pane.surface.grid_pass.scrollbar_thumb_color = self.config.scrollbar_thumb_color;
    pane.surface.grid_pass.scrollbar_thumb_active_color = self.config.scrollbar_thumb_active_color;
}

/// Effective 16-colour palette for a settings bundle: explicit
/// `palette` wins; `scheme` alone resolves through the built-in
/// table; null = keep the built-in 256-table values.
pub fn resolvePalette(s: *const @import("../config.zig").ProfileSettings) ?[16][3]u8 {
    if (s.palette) |p| return p;
    if (s.scheme.len > 0) {
        if (@import("../grid/schemes.zig").lookup(s.scheme)) |sch| return sch.palette;
    }
    return null;
}

/// Right-click → "New Tab as Profile…" picker. Opens a popover
/// anchored on the focused pane with a button per defined profile.
/// When no profiles exist, shows a single disabled placeholder so
/// the user learns where to define them. Clicking a button spawns
/// a tab via newShellTabWithProfile and closes the popover.
pub fn openProfilePicker(self: *Window) void {
    const pane = self.focusedPane() orelse return;

    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_widget_set_margin_top(box, 6);
    c.gtk_widget_set_margin_bottom(box, 6);
    c.gtk_widget_set_margin_start(box, 6);
    c.gtk_widget_set_margin_end(box, 6);

    if (self.config.profiles.items.len == 0) {
        const lbl = c.gtk_label_new("No profiles defined.\nAdd `[profile.<name>]` to config.conf.");
        c.gtk_label_set_xalign(@ptrCast(lbl), 0);
        c.gtk_box_append(@ptrCast(box), lbl);
    } else {
        for (self.config.profiles.items) |p| {
            const name_z = self.allocator.allocSentinel(u8, p.name.len, 0) catch continue;
            @memcpy(name_z, p.name);

            const btn = c.gtk_button_new_with_label(name_z.ptr);
            c.gtk_widget_set_halign(btn, c.GTK_ALIGN_FILL);
            c.gtk_widget_add_css_class(btn, "flat");

            const ctx = self.allocator.create(ProfileButtonCtx) catch {
                self.allocator.free(name_z);
                continue;
            };
            ctx.* = .{
                .window = self,
                .profile_name = name_z,
                .popover = popover,
                .allocator = self.allocator,
            };

            _ = c.g_signal_connect_data(
                btn,
                "clicked",
                @ptrCast(&onProfilePicked),
                @ptrCast(ctx),
                @ptrCast(&freeProfileButtonCtx),
                c.G_CONNECT_DEFAULT,
            );

            c.gtk_box_append(@ptrCast(box), btn);
        }
    }

    presentPanePopover(pane, popover, box);
}

/// Right-click → "Apply Profile to Pane…" picker. Same popover
/// shape as openProfilePicker, but the pick re-applies the
/// chosen profile's settings to the focused LIVE pane instead of
/// spawning a tab. "default" is always listed first.
pub fn openApplyProfilePicker(self: *Window) void {
    const pane = self.focusedPane() orelse return;

    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_widget_set_margin_top(box, 6);
    c.gtk_widget_set_margin_bottom(box, 6);
    c.gtk_widget_set_margin_start(box, 6);
    c.gtk_widget_set_margin_end(box, 6);

    var names_buf: [1][]const u8 = .{"default"};
    addApplyProfileButtons(self, pane, @ptrCast(box), popover, &names_buf);
    var prof_names = std.ArrayList([]const u8).empty;
    defer prof_names.deinit(self.allocator);
    for (self.config.profiles.items) |p| {
        prof_names.append(self.allocator, p.name) catch break;
    }
    addApplyProfileButtons(self, pane, @ptrCast(box), popover, prof_names.items);

    presentPanePopover(pane, popover, box);
}

/// Show a picker popover over a pane. Wraps the content in a
/// natural-size scroller and anchors at the pane's center:
/// GTK4 silently popdowns an autohide popover whose MINIMUM size
/// doesn't fit the space the compositor grants (same quirk the
/// context menu works around in menu.zig) — anchored at the
/// pane's bottom edge, any popover taller than the strip below
/// the window vanished the frame it mapped.
pub fn presentPanePopover(pane: *Pane, popover: *c.GtkWidget, content: ?*c.GtkWidget) void {
    const scroller = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scroller), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_scrolled_window_set_propagate_natural_height(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_propagate_natural_width(@ptrCast(scroller), 1);
    c.gtk_scrolled_window_set_child(@ptrCast(scroller), content);
    c.gtk_popover_set_child(@ptrCast(popover), scroller);
    c.gtk_widget_set_parent(popover, @ptrCast(pane.surface.area));
    connectManualPopoverClose(popover);
    var rect = c.GdkRectangle{
        .x = @divTrunc(c.gtk_widget_get_width(@ptrCast(pane.surface.area)), 2),
        .y = @divTrunc(c.gtk_widget_get_height(@ptrCast(pane.surface.area)), 2),
        .width = 1,
        .height = 1,
    };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    c.gtk_popover_popup(@ptrCast(popover));
}

pub fn addApplyProfileButtons(self: *Window, pane: *Pane, box: *c.GtkBox, popover: *c.GtkWidget, names: []const []const u8) void {
    for (names) |name| {
        const name_z = self.allocator.allocSentinel(u8, name.len, 0) catch continue;
        @memcpy(name_z, name);

        const btn = c.gtk_button_new_with_label(name_z.ptr);
        c.gtk_widget_set_halign(btn, c.GTK_ALIGN_FILL);
        c.gtk_widget_add_css_class(btn, "flat");

        const ctx = self.allocator.create(ProfileButtonCtx) catch {
            self.allocator.free(name_z);
            continue;
        };
        ctx.* = .{
            .window = self,
            .profile_name = name_z,
            .popover = popover,
            .allocator = self.allocator,
            .pane = pane,
        };
        _ = c.g_signal_connect_data(
            btn,
            "clicked",
            @ptrCast(&onApplyProfilePicked),
            @ptrCast(ctx),
            @ptrCast(&freeProfileButtonCtx),
            c.G_CONNECT_DEFAULT,
        );
        c.gtk_box_append(box, btn);
    }
}

/// Re-apply a profile's settings bundle to a LIVE pane: records
/// the pane's profile, pushes settings, and runs the font
/// rebuild that applyPaneConfig (a spawn-path helper) leaves to
/// the realize path. The shell/$TERM fields only affect future
/// respawns — the running child keeps its environment.
pub fn applyProfileToPane(self: *Window, pane: *Pane, profile_name: []const u8) void {
    const profile = self.findProfile(profile_name);
    pane.active_profile = if (profile) |p| p.name else null;

    const old_size = pane.surface.font_size;
    const old_path = pane.surface.font_path;
    const old_family = pane.surface.font_family;
    const old_features = pane.surface.font_features;
    const old_line_pad = pane.surface.line_pad_px;
    const old_opts = pane.surface.font_opts;

    self.applyPaneConfig(pane, .{ .profile = profile });

    const font_changed = pane.surface.font_size != old_size or
        !eqOptStr(old_path, pane.surface.font_path) or
        !eqOptStr(old_family, pane.surface.font_family) or
        !eqOptStr(old_features, pane.surface.font_features) or
        pane.surface.line_pad_px != old_line_pad or
        fontOptsDiffer(old_opts, pane.surface.font_opts);
    if (font_changed) pane.refreshFont();
    c.gtk_widget_queue_resize(pane.widget());
    pane.terminal.screen.dirty = true;
    pane.surface.markAllCellsDirty();
    c.gtk_gl_area_queue_render(@ptrCast(pane.surface.area));
}

/// Right-click → "Shader Preset…" picker. A popover anchored on
/// the focused pane: a button per saved preset (applies it to
/// that pane) plus a trash button to delete the preset file.
/// With no presets, a placeholder explains where they come from.
pub fn openShaderPresetPicker(self: *Window) void {
    const pane = self.focusedPane() orelse return;

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const names = shader_preset_mod.list(arena_state.allocator()) catch return;

    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_widget_set_margin_top(box, 6);
    c.gtk_widget_set_margin_bottom(box, 6);
    c.gtk_widget_set_margin_start(box, 6);
    c.gtk_widget_set_margin_end(box, 6);

    if (names.len == 0) {
        const lbl = c.gtk_label_new("No shader presets saved yet.\nConfigure Shader… has a \"Save as Preset\" button.");
        c.gtk_label_set_xalign(@ptrCast(lbl), 0);
        c.gtk_box_append(@ptrCast(box), lbl);
    } else {
        for (names) |name| {
            const name_z = self.allocator.allocSentinel(u8, name.len, 0) catch continue;
            @memcpy(name_z, name);

            const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 4);
            const btn = c.gtk_button_new_with_label(name_z.ptr);
            c.gtk_widget_set_hexpand(btn, 1);
            c.gtk_widget_set_halign(btn, c.GTK_ALIGN_FILL);
            c.gtk_widget_add_css_class(btn, "flat");

            const apply_ctx = self.allocator.create(PresetButtonCtx) catch {
                self.allocator.free(name_z);
                continue;
            };
            apply_ctx.* = .{
                .window = self,
                .preset_name = name_z,
                .popover = popover,
                .allocator = self.allocator,
                .pane = pane,
            };
            _ = c.g_signal_connect_data(
                btn,
                "clicked",
                @ptrCast(&onPresetPicked),
                @ptrCast(apply_ctx),
                @ptrCast(&freePresetButtonCtx),
                c.G_CONNECT_DEFAULT,
            );
            c.gtk_box_append(@ptrCast(row), btn);

            const del = c.gtk_button_new_from_icon_name("user-trash-symbolic");
            c.gtk_widget_add_css_class(del, "flat");
            c.gtk_widget_set_tooltip_text(del, "Delete preset");
            const del_name = self.allocator.allocSentinel(u8, name.len, 0) catch {
                c.gtk_box_append(@ptrCast(box), row);
                continue;
            };
            @memcpy(del_name, name);
            const del_ctx = self.allocator.create(PresetButtonCtx) catch {
                self.allocator.free(del_name);
                c.gtk_box_append(@ptrCast(box), row);
                continue;
            };
            del_ctx.* = .{
                .window = self,
                .preset_name = del_name,
                .popover = popover,
                .allocator = self.allocator,
            };
            _ = c.g_signal_connect_data(
                del,
                "clicked",
                @ptrCast(&onPresetDeleted),
                @ptrCast(del_ctx),
                @ptrCast(&freePresetButtonCtx),
                c.G_CONNECT_DEFAULT,
            );
            c.gtk_box_append(@ptrCast(row), del);

            c.gtk_box_append(@ptrCast(box), row);
        }
    }

    presentPanePopover(pane, popover, box);
}

/// Derive the effective default fg/bg for the Default settings.
pub fn resolveDefaultColors(self: *const Window) ColorPair {
    return resolveColorsFor(self, &self.config.settings);
}

/// Which light/dark variant is in force, or null when `auto_theme`
/// is off and the flat (manually configured) colours stand.
pub fn activeScheme(self: *const Window) ?ColorScheme {
    if (!self.config.auto_theme) return null;
    const sm = c.adw_style_manager_get_default();
    return if (c.adw_style_manager_get_dark(sm) != 0) .dark else .light;
}

/// A settings bundle with its colour fields resolved for the system's
/// current light/dark state. Every colour reader goes through this so
/// none of them has to know variants exist.
pub fn resolveSettings(self: *const Window, s: *const ProfileSettings) ProfileSettings {
    return s.forScheme(activeScheme(self));
}

/// Derive the effective default fg/bg for a settings bundle.
/// When auto_theme is on we follow AdwStyleManager's dark/light
/// state so sketerm matches the system appearance. Otherwise
/// honour the bundle's explicit colors. `background_opacity` is
/// applied to bg.a after theme resolution so transparency works
/// under both auto and manual themes.
pub fn resolveColorsFor(self: *const Window, s: *const ProfileSettings) ColorPair {
    const eff = resolveSettings(self, s);
    return colorPairOf(self, &eff);
}

/// fg/bg of an ALREADY scheme-resolved bundle, with the window's
/// background opacity folded into bg.a.
fn colorPairOf(self: *const Window, eff: *const ProfileSettings) ColorPair {
    var pair: ColorPair = .{ .fg = eff.default_fg, .bg = eff.default_bg };
    pair.bg[3] *= self.config.background_opacity;
    return pair;
}

/// Push a bundle's colours onto one pane: default fg/bg on the
/// screen and both render passes, the DSR ?996 / mode 2031 scheme
/// notification, the cursor colour and the 16-entry palette.
/// `s` is the pane's RAW settings; scheme resolution happens here.
pub fn pushPaneColors(self: *Window, pane: *Pane, s: *const ProfileSettings) void {
    const eff = resolveSettings(self, s);
    const fg_bg = colorPairOf(self, &eff);
    const screen = pane.terminal.screen;
    screen.default_fg = fg_bg.fg;
    screen.default_bg = fg_bg.bg;
    screen.configured_fg = fg_bg.fg;
    screen.configured_bg = fg_bg.bg;
    screen.notifyColorScheme(isDarkBg(fg_bg.bg));
    // Renderer convention: alpha=0 means "use fg colour". We map
    // cursor_color_default → that sentinel.
    screen.cursor_color = if (eff.cursor_color_default)
        .{ 0, 0, 0, 0 }
    else
        eff.cursor_color;
    pane.surface.grid_pass.default_fg = fg_bg.fg;
    pane.surface.grid_pass.default_bg = fg_bg.bg;
    pane.surface.cell_pass.default_fg = fg_bg.fg;
    pane.surface.cell_pass.default_bg = fg_bg.bg;
    // Palette (16 ANSI colours). Entries 16..255 keep their built-in
    // 256-table values.
    if (resolvePalette(&eff)) |pal| {
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            screen.palette[i] = pal[i];
            pane.surface.grid_pass.palette[i] = pal[i];
        }
    }
}

/// Open the preferences dialog. Live-applies changes via
/// applyConfigChange + persists to ~/.config/sketerm/config.conf
/// on every mutation.
pub fn openPrefs(self: *Window) void {
    const prefs = @import("prefs.zig");
    prefs.open(self.allocator, @ptrCast(self.app_window), @ptrCast(self), self.config, prefsApplyCallback) catch |err| {
        std.debug.print("sketerm: prefs dialog: {s}\n", .{@errorName(err)});
    };
}

/// How an apply treats the file on disk.
pub const ApplyOpts = struct {
    /// Write the resulting config back to config.conf. True for edits
    /// made IN the app (prefs, shader sliders) — they have nowhere
    /// else to live. False for a config that just came FROM the file:
    /// re-serialising it would rewrite the user's hand-written file
    /// (the writer emits non-default keys only, so comments, ordering
    /// and every default-valued line are lost) and, under the file
    /// watcher, feed our own write straight back in.
    persist: bool = true,
};

/// Push a (possibly-mutated) Config into all live state. Called
/// by the prefs dialog whenever the user changes anything; also
/// persists the new values to disk so they survive restart.
pub fn applyConfigChange(self: *Window, new_cfg: *const Config) void {
    applyConfigChangeOpts(self, new_cfg, .{});
}

pub fn applyConfigChangeOpts(self: *Window, new_cfg: *const Config, opts: ApplyOpts) void {
    // Compute diffs we need to react to BEFORE swapping config.
    const old_blink_ms = self.config.cursor_blink_ms;
    const old_tab_pos = self.config.tab_position;
    // Replace config wholesale via a deep copy into a fresh
    // window-owned arena, then free the previous one. Never adopt
    // `new_cfg.arena` or alias its strings: the prefs dialog's
    // working copy and reload-from-disk configs have their own
    // lifetimes (dialog close / caller deinit).
    const cloned = new_cfg.clone(self.allocator) catch |err| {
        std.debug.print("sketerm: config apply failed: {s}\n", .{@errorName(err)});
        return;
    };
    // Defer freeing the old arena to the end of this function —
    // panes still hold slices into it (screen.word_chars et al.)
    // until the push-loop below reassigns them.
    var old_cfg = self.config;
    defer old_cfg.deinit();
    self.config = cloned;
    rebuildSymbolSpecs(self);
    @import("webface.zig").setMaxFps(self.config.browser_max_fps);
    // IM strategy is app-level; faces read it at construction time.
    @import("imhost.zig").setPreference(switch (self.config.input_method) {
        .auto => .auto,
        .simple => .simple,
        .multi => .multi,
    });

    // Background layer: only re-decode when one of its keys
    // actually moved (image decode is not keystroke-cheap).
    if (!std.mem.eql(u8, old_cfg.background_image, self.config.background_image) or
        old_cfg.background_image_opacity != self.config.background_image_opacity or
        !std.mem.eql(f32, &old_cfg.background_gradient_from, &self.config.background_gradient_from) or
        !std.mem.eql(f32, &old_cfg.background_gradient_to, &self.config.background_gradient_to) or
        old_cfg.background_gradient_angle != self.config.background_gradient_angle)
    {
        refreshBgSource(self);
    }

    // Window-level custom shader source follows the Default
    // settings. Re-read the file only when its keys moved — but
    // ALWAYS re-point the param overrides, which live in the
    // config arena that gets freed when this function returns.
    if (!std.mem.eql(u8, old_cfg.settings.custom_shader, self.config.settings.custom_shader) or
        old_cfg.custom_shader_animation != self.config.custom_shader_animation)
    {
        refreshShaderSource(self);
    }
    self.shader_source.overrides = self.config.shader_params.items;

    // Push into every pane, resolving each pane's profile to its
    // settings bundle in the NEW config (deleted profiles degrade
    // to the Default settings).
    for (self.panes.items) |p| {
        const screen = p.terminal.screen;
        // The pane's old effective settings — old name slice and
        // old config arena both stay alive until function end.
        const old_s = old_cfg.profileSettings(p.active_profile orelse "");
        // Re-point active_profile at the new arena's copy (or
        // drop it if the profile no longer exists).
        if (p.active_profile) |pn| {
            p.active_profile = null;
            for (self.config.profiles.items) |*pr| {
                if (std.mem.eql(u8, pr.name, pn)) {
                    p.active_profile = pr.name;
                    break;
                }
            }
        }
        const s = self.config.profileSettings(p.active_profile orelse "");

        // Colors. pushPaneColors applies the light/dark variant +
        // background_opacity so panes get the actual rendering
        // values, not the raw settings struct.
        pushPaneColors(self, p, s);
        screen.allow_clipboard_read = self.config.clipboard_read;
        screen.track_activity = self.config.track_tab_activity;
        // Cursor. Shape or interval changes re-arm (or drop) the
        // blink timer — it only runs while the shape blinks.
        screen.cursor_shape = mapCursorShape(self.config.cursor_shape, self.config.cursor_blink);
        if (self.config.cursor_blink_ms != old_blink_ms) {
            p.surface.cursor_blink_us = @as(i64, @intCast(self.config.cursor_blink_ms)) * 1000;
        }
        p.restartBlinkTimer();
        p.applyTrailConfig(self.config.cursor_trail, self.config.cursor_trail_ms);
        // Padding.
        if (s.padding != old_s.padding) {
            p.surface.grid_pass.pad = s.padding;
            p.surface.cell_pass.pad = s.padding;
            c.gtk_widget_queue_resize(p.widget());
        }
        // Rendering.
        p.setGraphicsOffload(self.config.graphics_offload);
        // Affects the next app launch; live views keep their mode
        // (pop in/out via the window's host menu).
        p.app_view_tab = self.config.app_view == .tab;
        p.surface.grid_pass.enable_ligatures = self.config.ligatures;
        p.surface.grid_pass.enable_bidi = self.config.bidi;
        p.surface.grid_pass.enable_url_underline = self.config.auto_url_detect;
        p.surface.grid_pass.allow_bold = self.config.allow_bold;
        p.surface.grid_pass.bold_is_bright = self.config.bold_is_bright;
        p.surface.cell_pass.allow_bold = self.config.allow_bold;
        p.surface.cell_pass.bold_is_bright = self.config.bold_is_bright;
        p.surface.grid_pass.min_contrast = self.config.minimum_contrast;
        p.surface.cell_pass.min_contrast = self.config.minimum_contrast;
        p.surface.text_blending = textBlendMode(self.config.text_blending);
        // Behavior.
        screen.bracketed_paste = self.config.bracketed_paste;
        screen.modify_other_keys = self.config.modify_other_keys;
        screen.scrollback_capacity = s.scrollback;
        screen.scroll_on_output = self.config.scroll_on_output;
        screen.word_chars = self.config.word_chars;
        if (p.input_ctx) |ictx| {
            ictx.smart_copy = self.config.smart_copy;
            ictx.clear_select_on_copy = self.config.clear_select_on_copy;
            ictx.mouse_autohide = self.config.mouse_autohide;
        }
        // These slices pointed into the old config arena (freed
        // when this function returns) — re-point them at the new
        // config's copies.
        p.surface.font_path = s.font_path;
        p.surface.font_family = if (s.font_family.len > 0) s.font_family else null;
        p.surface.font_features = if (s.font_features.len > 0) s.font_features else null;
        p.surface.line_pad_px = s.line_pad_px;
        // font_opts holds FIVE more borrowed slices (the three styled
        // families and the symbol-map list, whose backing array
        // rebuildSymbolSpecs just reallocated). Rebuilding it here is
        // what keeps them out of the arena that is freed on return.
        const old_font_opts = p.surface.font_opts;
        p.surface.font_opts = fontOptsFor(self, s);
        // Shader state: the overrides slice points into the
        // config arena (about to be freed) — re-point it
        // UNCONDITIONALLY (preset panes own their slice and skip
        // this), then re-resolve the settings shader for panes
        // without a sticky user pick.
        p.surface.shader_default_source = &self.shader_source;
        if (!p.hasOwnShaderParams())
            p.surface.shader_own.overrides = self.config.shader_params.items;
        if (!p.surface.custom_shader_user and !p.surface.shader_cleared) {
            _ = p.setCustomShader(
                if (s.custom_shader.len > 0) s.custom_shader else null,
                self.config.custom_shader_animation,
                false,
            );
        } else if (p.surface.custom_shader_user) {
            p.surface.shader_own.animate = self.config.custom_shader_animation;
        }
        p.refreshShaderBinding();
        // Mouse / link / autohide flags on the Pane itself.
        p.copy_on_selection = self.config.copy_on_selection;
        p.clear_select_on_copy = self.config.clear_select_on_copy;
        p.disable_mouse_paste = self.config.disable_mouse_paste;
        p.disable_mousewheel_zoom = self.config.disable_mousewheel_zoom;
        p.link_single_click = self.config.link_single_click;
        p.mouse_autohide = self.config.mouse_autohide;
        p.middle_click_action = self.config.mouse_middle_click;
        p.right_click_action = self.config.mouse_right_click;
        // Per-pane titlebar visibility (never in files identity).
        p.setTitlebarVisible(self.config.show_titlebar and !Window.filesIdentity());
        // Inactive-pane dimming.
        p.surface.inactive_darken = self.config.inactive_darken;
        p.surface.inactive_desaturate = self.config.inactive_desaturate;
        p.applyDim();
        // Pane border / corner radius / overlay scrollbar.
        applyPanePresentation(self, p, s);
        // Font rebuilds, per pane against ITS settings bundle. A
        // size change takes the heavy atlas-rebuild path (and
        // resets any Ctrl± zoom, like before); same size with a
        // different file/family/features rebuilds explicitly
        // since setFontSize would early-return.
        if (s.font_size != old_s.font_size) {
            p.setFontSize(s.font_size);
        } else {
            const path_changed = !eqOptStr(old_s.font_path, s.font_path);
            const family_changed = !std.mem.eql(u8, old_s.font_family, s.font_family);
            const features_changed = !std.mem.eql(u8, old_s.font_features, s.font_features);
            const line_pad_changed = old_s.line_pad_px != s.line_pad_px;
            const opts_changed = fontOptsDiffer(old_font_opts, p.surface.font_opts);
            if (path_changed or family_changed or features_changed or line_pad_changed or opts_changed) {
                p.refreshFont();
            }
        }
        // Repaint.
        screen.dirty = true;
        p.surface.markAllCellsDirty();
        c.gtk_gl_area_queue_render(@ptrCast(p.surface.area));
    }

    // Refresh CSS provider so any title_*_* color changes take
    // effect immediately on the active/inactive classes.
    refreshTitlebarCss(self);

    // Title templates: re-render every tab label and the window title
    // against the NEW template. Unconditional rather than diffed —
    // it is a bounded walk over the open panes with no allocation,
    // and the config path is not hot.
    @import("termsinks.zig").refreshAllTitles(self);

    // Tab position swap.
    if (self.config.tab_position != old_tab_pos) {
        self.setTabPosition(self.config.tab_position);
    }

    // Window-level flags.
    self.search_force_cs = self.config.search_case_sensitive;
    self.setAlwaysOnTop(self.config.always_on_top);
    self.refreshOpaqueRegion();
    self.refreshBindings();
    c.gtk_widget_set_visible(self.tab_bar, if (self.config.show_tab_bar) 1 else 0);
    // Quake geometry: primary only, and a no-op while quake is off —
    // so a reload never resizes an ordinary window under the user.
    if (self.is_primary) self.applyQuakeGeometry();

    // Start / stop the watcher: this config may have flipped
    // `config_auto_reload`. Before the write below, so the write is
    // stamped on a watcher that exists.
    @import("configwatch.zig").afterApply(self);

    if (opts.persist) persistConfig(self);
}

/// Write the live config back to the file the process reads — the
/// `--config` override when there is one, so an in-app edit does not
/// silently land in the XDG file the user isn't using.
pub fn persistConfig(self: *Window) void {
    const path = resolveActiveConfigPath(self.allocator) orelse return;
    defer self.allocator.free(path);
    self.config.save(path) catch |err| {
        std.debug.print("sketerm: prefs persist failed: {s}\n", .{@errorName(err)});
        return;
    };
    // Our own write must not come back through the file watcher as a
    // user edit — every in-app save lands here, sliders included.
    @import("configwatch.zig").noteSelfWrite(self);
}

/// Rebuild bg_source from config: decode the image (if any) or
/// arm the gradient. Frees the previous stbi allocation. Call on
/// startup and whenever a background_* key may have changed.
pub fn refreshBgSource(self: *Window) void {
    if (self.bg_source.pixels) |px| {
        c.stbi_image_free(px);
        self.bg_source.pixels = null;
    }
    self.bg_source.mode = .none;

    const cfg = &self.config;
    if (cfg.background_image.len > 0) blk: {
        var path_z_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{cfg.background_image}) catch break :blk;
        var w: c_int = 0;
        var h: c_int = 0;
        var n: c_int = 0;
        const px = c.stbi_load(path_z.ptr, &w, &h, &n, 4);
        if (px == null) {
            std.debug.print("sketerm: background_image load failed: {s}\n", .{cfg.background_image});
            break :blk;
        }
        self.bg_source.pixels = px;
        self.bg_source.w = w;
        self.bg_source.h = h;
        self.bg_source.opacity = cfg.background_image_opacity;
        self.bg_source.mode = .image;
    }
    if (self.bg_source.mode == .none and
        cfg.background_gradient_from[3] > 0 and cfg.background_gradient_to[3] > 0)
    {
        self.bg_source.color0 = cfg.background_gradient_from;
        self.bg_source.color1 = cfg.background_gradient_to;
        self.bg_source.angle_deg = cfg.background_gradient_angle;
        self.bg_source.opacity = 1.0;
        self.bg_source.mode = .gradient;
    }
    self.bg_source.generation +%= 1;
}

/// (Re-)read the custom_shader file into shader_source. Call on
/// startup and whenever a custom_shader* key may have changed.
pub fn refreshShaderSource(self: *Window) void {
    if (self.shader_source.src) |s| {
        self.allocator.free(s);
        self.shader_source.src = null;
    }
    if (self.shader_source.dir) |d| {
        self.allocator.free(d);
        self.shader_source.dir = null;
    }
    self.shader_source.animate = self.config.custom_shader_animation;
    self.shader_source.overrides = self.config.shader_params.items;

    const path = self.config.settings.custom_shader;
    if (path.len > 0) {
        // Shader-relative //@texture paths resolve against this.
        if (std.fs.path.dirname(path)) |d| {
            self.shader_source.dir = self.allocator.dupe(u8, d) catch null;
        }
    }
    if (path.len > 0) blk: {
        var path_z: [4096]u8 = undefined;
        if (path.len >= path_z.len) break :blk;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        const fp = c.fopen(@ptrCast(&path_z), "rb") orelse {
            std.debug.print("sketerm: custom_shader not readable: {s}\n", .{path});
            break :blk;
        };
        defer _ = c.fclose(fp);
        const max_bytes: usize = 256 * 1024;
        const buf = self.allocator.alloc(u8, max_bytes) catch break :blk;
        const n = c.fread(buf.ptr, 1, buf.len, fp);
        if (n == 0) {
            self.allocator.free(buf);
            break :blk;
        }
        self.shader_source.src = self.allocator.realloc(buf, n) catch buf[0..n];
    }
    self.shader_source.generation +%= 1;
}

/// Build the active keybinding table from default_bindings overlaid
/// with Config.keybinds. Each (action, accel) override either
/// replaces a default's accel for that action OR (if the action's
/// default is unbound and the user-supplied accel matches an
/// existing default's accel) does nothing — the user can't "free
/// up" a default chord without an explicit unbind.
/// Empty accel means "unbind that action" (remove all entries).
/// Logs duplicate-accel collisions to stderr but doesn't error.
pub fn refreshBindings(self: *Window) void {
    const input = @import("input.zig");
    const ally = self.allocator;
    // Reset.
    self.bindings.clearRetainingCapacity();
    // Start with defaults.
    for (input.default_bindings) |b| self.bindings.append(ally, b) catch return;
    // Apply overrides.
    for (self.config.keybinds.items) |kb| {
        const action = input.actionFromName(kb.name) orelse {
            std.debug.print("sketerm: keybind: unknown action '{s}'\n", .{kb.name});
            continue;
        };
        // Drop every existing binding for this action (multiple
        // defaults may map to the same action — e.g. font_inc has
        // 4 entries; an override clears all of them).
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            if (self.bindings.items[i].action == action) {
                _ = self.bindings.orderedRemove(i);
            } else i += 1;
        }
        if (kb.accel.len == 0) continue; // unbound
        const parsed = input.parseAccel(kb.accel) orelse {
            std.debug.print("sketerm: keybind: bad accelerator '{s}' for '{s}'\n", .{ kb.accel, kb.name });
            continue;
        };
        // Conflict warn if another action already uses this combo.
        for (self.bindings.items) |existing| {
            if (existing.keyval == parsed.keyval and (existing.mods & input.SIGNIFICANT_MODS) == (parsed.mods & input.SIGNIFICANT_MODS)) {
                std.debug.print(
                    "sketerm: keybind: '{s}' shadows '{s}' (same accelerator)\n",
                    .{ input.actionName(action), input.actionName(existing.action) },
                );
                break;
            }
        }
        self.bindings.append(ally, .{
            .keyval = parsed.keyval,
            .mods = parsed.mods,
            .action = action,
        }) catch {};
    }
    // Push pointer into every existing pane's Ctx.
    for (self.panes.items) |p| {
        if (p.input_ctx) |ictx| ictx.bindings = self.bindings.items;
    }
}

/// (Re)build the per-pane titlebar CSS so the four colour classes
/// resolve to the user-configured rgba values. Called at startup
/// and on every applyConfigChange.
pub fn refreshTitlebarCss(self: *Window) void {
    if (self.titlebar_css == null) {
        const provider = c.gtk_css_provider_new();
        const display = c.gtk_widget_get_display(self.app_window);
        // STYLE_PROVIDER_PRIORITY_APPLICATION beats theme defaults
        // but loses to user CSS — the right level for "we own this
        // widget class".
        c.gtk_style_context_add_provider_for_display(
            display,
            @ptrCast(@alignCast(provider)),
            c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION,
        );
        self.titlebar_css = provider;
    }
    const af = self.config.title_active_fg;
    const ab = self.config.title_active_bg;
    const inf = self.config.title_inactive_fg;
    const ib = self.config.title_inactive_bg;
    const gap = self.config.pane_gap_color;
    // Format rgba(r, g, b, a) with values 0..255 + 0..1 alpha.
    // Generous buffer: a bufPrintZ overflow here would silently drop
    // EVERY rule in this provider, not just the one that grew it.
    var buf: [8192]u8 = undefined;
    const css = std.fmt.bufPrintZ(&buf,
        \\.sketerm-titlebar {{ padding: 1px 2px; min-height: 18px; }}
        \\.sketerm-titlebar-active {{ background-color: rgba({d}, {d}, {d}, {d:.3}); color: rgba({d}, {d}, {d}, {d:.3}); }}
        \\.sketerm-titlebar-inactive {{ background-color: rgba({d}, {d}, {d}, {d:.3}); color: rgba({d}, {d}, {d}, {d:.3}); }}
        \\.sketerm-titlebar-label {{ font-weight: bold; }}
        \\.sketerm-titlebar.sketerm-broadcast {{ box-shadow: inset 0 0 0 2px rgba(255, 200, 60, 0.95); }}
        \\
        \\/* Assistant-is-driving indicator: accent border on the
        \\   pane whose session has a headless MCP client attached,
        \\   and the corner badge on forwarded app windows. */
        \\.sketerm-driven {{ box-shadow: inset 0 0 0 2px rgba(255, 120, 40, 0.9); }}
        \\.sketerm-ai-badge {{
        \\    background-color: rgba(255, 120, 40, 0.92);
        \\    color: white;
        \\    font-weight: bold;
        \\    font-size: 10px;
        \\    padding: 1px 7px;
        \\    border-radius: 0 0 0 8px;
        \\}}
        \\
        \\/* "App window open — click to raise" strip above an app
        \\   session's log while its windows float. */
        \\.sketerm-app-banner {{
        \\    background-color: rgba(53, 132, 228, 0.25);
        \\    font-size: 11px;
        \\    min-height: 20px;
        \\    padding: 1px 6px;
        \\    border-radius: 0;
        \\}}
        \\
        \\/* Active-tab indicator — accent line under the selected
        \\   tab plus a stronger background tint, à la Terminator.
        \\   Inactive tabs dim to ~55% so the active one stands
        \\   out. libadwaita uses `tab:selected` (pseudo-class),
        \\   not `.selected` / `:checked`. We give the selected
        \\   rule higher specificity (`tabbar tabbox tab`) so it
        \\   wins over libadwaita's own `tabbar tab:selected`
        \\   block at the same priority level.
        \\
        \\   Unselected tabs also need a background of their own:
        \\   with none, they show the AdwToolbarView top-bar colour
        \\   and are indistinguishable from the files-mode menubar
        \\   sitting right above the tab strip. A semi-transparent
        \\   black overlay darkens whatever the theme's chrome is
        \\   without naming a colour. `color-mix()`/`shade()` over
        \\   `@headerbar_bg_color` parse fine on GTK 4.22 too, but
        \\   the overlay needs no colour function at all, so it is
        \\   the version- and theme-independent form. It sits
        \\   UNDER the tab's own snapshot (GTK paints the CSS box
        \\   before the snapshot vfunc), so the washes drawn in
        \\   tab_effects.zig still composite on top. The alpha is
        \\   multiplied by the 0.55 tab opacity, hence 0.22 for a
        \\   ~0.12 effective wash. The hover rule is ours too:
        \\   our APPLICATION-priority rule would otherwise outrank
        \\   the theme's hover background and hover feedback would
        \\   vanish. */
        \\tabbar tab {{ opacity: 0.55; background-color: rgba(0, 0, 0, 0.22); }}
        \\tabbar tab:hover {{ background-color: rgba(0, 0, 0, 0.08); }}
        \\tabbar tabbox tab:selected {{
        \\    opacity: 1.0;
        \\    box-shadow: inset 0 -3px 0 0 #3584e4;
        \\    background-color: rgba(53, 132, 228, 0.18);
        \\}}
        \\
        \\/* Split-pane separator — solid 4-px #353535 line.
        \\   `gtk_paned_set_wide_handle(paned, TRUE)` adds the
        \\   `.wide` style class to the separator. libadwaita's
        \\   `paned.horizontal > separator.wide` rule has higher
        \\   specificity than `paned > separator` and paints
        \\   1-px box-shadow lines on both edges; we have to
        \\   match that selector to override.
        \\
        \\   Width defaults to 4 logical px (not 2) so it stays a
        \\   multiple of 4 — every fractional surface scale we care
        \\   about (1.25, 1.5, 1.75) maps that to integer device
        \\   pixels, keeping the pane rectangles on the
        \\   GtkGraphicsOffload-compatible grid. With an odd-width
        \\   separator at scale 1.5 one pane always falls off-grid
        \\   and offload silently rejects every frame. `pane_gap`
        \\   and `pane_gap_color` override both. */
        \\paned.horizontal > separator,
        \\paned.vertical > separator,
        \\paned.horizontal > separator.wide,
        \\paned.vertical > separator.wide {{
        \\    background-color: rgba({d}, {d}, {d}, {d:.3});
        \\    background-image: none;
        \\    box-shadow: none;
        \\    border: none;
        \\    margin: 0;
        \\    padding: 0;
        \\    min-width: {d:.0}px;
        \\    min-height: {d:.0}px;
        \\}}
        \\paned.horizontal > separator:hover,
        \\paned.vertical > separator:hover,
        \\paned.horizontal > separator.wide:hover,
        \\paned.vertical > separator.wide:hover,
        \\paned.horizontal > separator:active,
        \\paned.vertical > separator:active,
        \\paned.horizontal > separator.wide:active,
        \\paned.vertical > separator.wide:active {{
        \\    background-color: #5a5a5a;
        \\    box-shadow: none;
        \\}}
    , .{
        @as(u8, @intFromFloat(@round(ab[0] * 255))),
        @as(u8, @intFromFloat(@round(ab[1] * 255))),
        @as(u8, @intFromFloat(@round(ab[2] * 255))),
        ab[3],
        @as(u8, @intFromFloat(@round(af[0] * 255))),
        @as(u8, @intFromFloat(@round(af[1] * 255))),
        @as(u8, @intFromFloat(@round(af[2] * 255))),
        af[3],
        @as(u8, @intFromFloat(@round(ib[0] * 255))),
        @as(u8, @intFromFloat(@round(ib[1] * 255))),
        @as(u8, @intFromFloat(@round(ib[2] * 255))),
        ib[3],
        @as(u8, @intFromFloat(@round(inf[0] * 255))),
        @as(u8, @intFromFloat(@round(inf[1] * 255))),
        @as(u8, @intFromFloat(@round(inf[2] * 255))),
        inf[3],
        @as(u8, @intFromFloat(@round(gap[0] * 255))),
        @as(u8, @intFromFloat(@round(gap[1] * 255))),
        @as(u8, @intFromFloat(@round(gap[2] * 255))),
        gap[3],
        self.config.pane_gap,
        self.config.pane_gap,
    }) catch return;
    c.gtk_css_provider_load_from_string(self.titlebar_css.?, css.ptr);
}

/// Reload the active config file from disk and live-apply. Honours a
/// `--config <path>` override (it used to ignore one and silently
/// reload the XDG file instead, i.e. a different file from the one the
/// process was started with) and does NOT write the result back — see
/// `ApplyOpts.persist`.
pub fn reloadConfigFromDisk(self: *Window) void {
    var new_cfg = Config.loadWithOverride(self.allocator, configPathOverride());
    // applyConfigChange deep-copies; the loaded config (and its
    // arena) is ours to free.
    defer new_cfg.deinit();
    self.applyConfigChangeOpts(&new_cfg, .{ .persist = false });
    std.debug.print("sketerm: config reloaded\n", .{});
}

/// `--config <path>`, or null for the XDG search path. Process-wide:
/// it is an invocation flag, and every window in the process was
/// started from the same command line.
var config_override_path: ?[]const u8 = null;

/// Record the `--config` path. Borrowed for the process lifetime —
/// main.zig owns the string and never frees it while windows live.
pub fn setConfigPathOverride(path: ?[]const u8) void {
    config_override_path = path;
}

pub fn configPathOverride() ?[]const u8 {
    return config_override_path;
}

/// The file the running process loaded its config from: the
/// `--config` override, else the XDG path. Caller frees. Null when
/// neither HOME nor XDG_CONFIG_HOME is set (nothing to watch).
pub fn resolveActiveConfigPath(allocator: std.mem.Allocator) ?[]u8 {
    if (config_override_path) |p| return allocator.dupe(u8, p) catch null;
    return resolveConfigSavePath(allocator) catch null;
}

pub fn onShaderPicked(user: ?*anyopaque, result: ?@import("../filebrowser/picker.zig").Result) void {
    const ctx = cast.userData(ShaderPickCtx, user);
    // Fires exactly once, cancel included — so the ctx is freed here
    // on every path, through its OWN allocator (win may be gone).
    defer ctx.allocator.destroy(ctx);
    const res = result orelse return;
    if (res.specs.len == 0) return;

    // The pane may have closed while the dialog was up — only act if
    // it's still listed (the pointer would be dangling otherwise).
    var alive = false;
    for (ctx.win.panes.items) |p| {
        if (p == ctx.pane) {
            alive = true;
            break;
        }
    }
    if (!alive) return;
    // The GL shader compiler reads the file with local libc; a remote
    // pick has no local path, so refuse it out loud.
    const path = @import("picker.zig").localPathOrRefuse(
        @ptrCast(ctx.win.app_window),
        res.specs[0],
        "The GL shader compiler reads the file locally — pick a shader on this machine.",
    ) orelse return;
    // Strictly per-pane: the pick lands on the clicked pane only. A
    // manual file pick replaces any bound preset.
    ctx.pane.dropShaderPreset(ctx.win.config.shader_params.items);
    _ = ctx.pane.setCustomShader(path, ctx.win.config.custom_shader_animation, true);
}

/// The system flipped light/dark: re-resolve every pane against its
/// OWN profile, since each profile carries its own light/dark colour
/// variants (and a variant can move the palette and cursor colour,
/// not just fg/bg).
pub fn onThemeChanged(_: *c.GObject, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Window, user);
    // A window in destroy still has its panes listed until the deferred
    // teardown idles run; their widgets are already dead.
    if (self.destroying) return;
    if (!self.config.auto_theme) return;
    for (self.panes.items) |p| {
        pushPaneColors(self, p, self.config.profileSettings(p.active_profile orelse ""));
        p.terminal.screen.dirty = true;
        p.surface.markAllCellsDirty();
        c.gtk_gl_area_queue_render(@ptrCast(p.surface.area));
    }
}

pub fn onApplyProfilePicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ProfileButtonCtx, user);
    if (ctx.pane) |pane| {
        ctx.window.applyProfileToPane(pane, ctx.profile_name);
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
}

pub fn onProfilePicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ProfileButtonCtx, user);
    // Spawn the tab first, then dismiss the popover so the user
    // sees the action take effect.
    ctx.window.newShellTabWithProfile(null, ctx.profile_name) catch |err| logActionError("new_tab_as_profile", err);
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
}

pub fn freeProfileButtonCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(ProfileButtonCtx, user);
    ctx.allocator.free(ctx.profile_name);
    ctx.allocator.destroy(ctx);
}

pub fn onPresetPicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(PresetButtonCtx, user);
    if (ctx.pane) |pane| {
        if (!ctx.window.applyShaderPresetByName(pane, ctx.preset_name)) {
            std.debug.print("sketerm: shader preset '{s}' failed to apply\n", .{ctx.preset_name});
        }
    }
    c.gtk_popover_popdown(@ptrCast(ctx.popover));
}

pub fn onPresetDeleted(btn: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(PresetButtonCtx, user);
    shader_preset_mod.delete(ctx.allocator, ctx.preset_name) catch {
        std.debug.print("sketerm: shader preset '{s}' delete failed\n", .{ctx.preset_name});
        return;
    };
    // Hide the row (button + delete button) — the popover rebuilds
    // fresh on next open.
    if (c.gtk_widget_get_parent(@ptrCast(btn))) |row| c.gtk_widget_set_visible(row, 0);
}

pub fn freePresetButtonCtx(user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(PresetButtonCtx, user);
    ctx.allocator.free(ctx.preset_name);
    ctx.allocator.destroy(ctx);
}

pub fn eqOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

pub fn prefsApplyCallback(win_ptr: *anyopaque, new_cfg: *const Config) void {
    const win: *Window = @ptrCast(@alignCast(win_ptr));
    win.applyConfigChange(new_cfg);
}

/// Map config (cursor_shape + cursor_blink) into the screen's
/// blink/steady cursor variant.
pub fn mapCursorShape(shape: @import("../config.zig").CursorShape, blink: bool) @import("../grid/screen.zig").Screen.CursorShape {
    return switch (shape) {
        .block => if (blink) .block_blink else .block_steady,
        .underline => if (blink) .underline_blink else .underline_steady,
        .bar => if (blink) .bar_blink else .bar_steady,
    };
}

/// Path the prefs dialog persists to. Honours XDG; falls back to
/// ~/.config/sketerm/config.conf. Caller frees.
pub fn resolveConfigSavePath(allocator: std.mem.Allocator) ![]u8 {
    if (@import("../util/profile.zig").getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/config.conf", .{x});
    }
    if (@import("../util/profile.zig").getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/sketerm/config.conf", .{home});
    }
    return error.NoConfigPath;
}

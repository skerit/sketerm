//! User-facing configuration loaded from ~/.config/sketerm/config.conf.
//!
//! Format: `key = value` per line. `#` starts a comment. Strings are
//! unquoted; values are parsed by type (int/float/bool/string/color).
//! Missing keys fall back to defaults. Unknown keys are ignored
//! (with a stderr warning) so newer configs work on older binaries.
//!
//! Loaded once at app start via `Config.load`. Mutations require a
//! restart (no live reload v1).

const std = @import("std");

pub const CursorShape = enum { block, underline, bar };

/// What happens when a pane's shell exits. `close` removes the
/// pane (current behaviour). `restart` respawns the configured
/// shell. `hold` keeps the pane open with an exit-status banner
/// so users can see why a command died.
pub const ExitAction = enum { close, restart, hold };

/// AdwTabBar position relative to the window.
pub const TabPosition = enum { top, bottom };

/// Custom keybinding entry: action name + accelerator string. Action
/// names are stable across versions (defined in `ui/input.zig`). The
/// accelerator is a GTK accelerator string (e.g. `<Control><Shift>t`)
/// — empty string unbinds.
pub const KeybindEntry = struct {
    name: []const u8,
    accel: []const u8,
};

/// A named profile — a Config subset applied per-pane. Defined via
/// `[profile.<name>]` sections in config.conf. Fields default to
/// "inherit from global config" (sentinels: empty string for string
/// fields, 0 for numerics where 0 means "no override"). Empty name
/// is reserved for the global config.
pub const Profile = struct {
    name: []const u8,
    /// Override for shell binary path. Empty → inherit `Config.shell`.
    shell: []const u8 = "",
    /// Override for font file path. Empty → inherit `Config.font_path`.
    font_path: []const u8 = "",
    /// Override for font size. 0 → inherit.
    font_size: u16 = 0,
    /// Override for the colour scheme name. Empty → inherit.
    scheme: []const u8 = "",
    /// Override for the 16-colour ANSI palette. null → inherit.
    palette: ?[16][3]u8 = null,
    /// Override for $TERM. Empty → inherit.
    term_env: []const u8 = "",
    /// Override for $COLORTERM. Empty → inherit.
    color_term_env: []const u8 = "",
    /// Override for scrollback line cap. 0 → inherit.
    scrollback: u32 = 0,
    /// Override for login_shell. null → inherit.
    login_shell: ?bool = null,
};

/// When to ask "are you sure?" before destroying panes / tabs.
/// Matches Terminator's `ask_before_closing` semantics:
///   never    — close immediately, no dialog
///   multiple — only ask when there's >1 pane in the closing target
///   always   — ask on every close
pub const ConfirmClose = enum { never, multiple, always };

pub const Config = struct {
    // Font
    font_path: ?[]const u8 = null,
    font_size: u16 = 14,
    /// Extra pixels added to each cell's height for visual line
    /// spacing. 0 = font's natural metric; positive = looser; small
    /// negative = tighter (clamped so the glyph still fits).
    line_pad_px: i16 = 0,

    // Colors (premultiplied RGBA, 0..1).
    default_fg: [4]f32 = .{ 0.92, 0.92, 0.92, 1.0 },
    default_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 },
    cursor_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    /// When true, the cursor uses the foreground color and ignores
    /// `cursor_color`. Matches xterm/Terminator default.
    cursor_color_default: bool = true,
    /// User-overridden ANSI 16 palette entries. null = "use the
    /// built-in palette (or scheme presets)". Stored as RGB (no
    /// alpha — palette colours are always opaque).
    palette: ?[16][3]u8 = null,
    /// Built-in scheme name (tango / linux / xterm / solarized_dark /
    /// solarized_light / gruvbox_dark / gruvbox_light / nord /
    /// dracula / monokai). Empty string = "no scheme; use defaults
    /// or `palette` overrides".
    scheme: []const u8 = "",

    // Cursor
    cursor_shape: CursorShape = .block,
    cursor_blink: bool = true,
    /// Cursor blink interval in milliseconds. Each interval is one
    /// half-cycle (on→off OR off→on). 500 = full blink every 1000ms.
    cursor_blink_ms: u32 = 500,

    // Layout
    padding: f32 = 6.0,
    scrollback: u32 = 10000,
    /// Snap view back to the bottom on any output, not just on
    /// keystroke. Off by default — matches xterm; users who want
    /// the gnome-terminal "auto-tail" behaviour flip this.
    scroll_on_output: bool = false,

    // Shell + child env
    shell: ?[]const u8 = null,
    term_env: []const u8 = "xterm-256color",
    color_term_env: []const u8 = "truecolor",
    /// Prepend `-` to argv[0] so the shell behaves as a login
    /// shell (sources /etc/profile etc.). Off by default.
    login_shell: bool = false,
    /// What to do when a pane's shell exits.
    exit_action: ExitAction = .close,

    // Behavior
    bracketed_paste: bool = true,
    modify_other_keys: u8 = 0, // 0=off, 1=basic, 2=full
    /// Characters that count as part of a "word" for double-click
    /// selection. Defaults to alphanumerics + a few common URL/path
    /// punctuation characters. Anything OUTSIDE this set is treated
    /// as a word boundary.
    word_chars: []const u8 = "-_.,/?:@&=+%~",
    /// Smart copy: when no selection is active, Ctrl+Shift+C
    /// forwards as Ctrl+C (interrupt) instead of being a no-op.
    smart_copy: bool = true,

    // Rendering
    ligatures: bool = true,
    /// Bidirectional text reorder via fribidi. Only affects lines
    /// containing non-ASCII codepoints; pure-ASCII lines skip it.
    bidi: bool = true,
    /// If true, fg/bg follow AdwStyleManager dark/light. Set to
    /// false to honour `default_fg` / `default_bg` exactly.
    auto_theme: bool = true,
    /// Bell behaviour: visual flash, system beep, and / or marking
    /// the AdwTabPage as needs-attention. Independent toggles.
    bell_audible: bool = false,
    bell_visible: bool = true,
    bell_urgent: bool = true,

    // Window
    /// Position of the AdwTabBar relative to the window content.
    tab_position: TabPosition = .top,
    /// Whether each AdwTabPage shows an X close button.
    close_button_on_tab: bool = true,
    /// Keep the window above other windows (gtk_window_set_keep_above).
    always_on_top: bool = false,
    /// Insert new tabs immediately after the focused one instead of
    /// appending at the end of the tab bar.
    new_tab_after_current: bool = false,
    /// Confirm-on-close policy. Default: ask only if there's more
    /// than one pane being lost (matches Terminator's default).
    confirm_close: ConfirmClose = .multiple,

    // Mouse
    /// Hide the mouse cursor while typing; reappear on motion.
    mouse_autohide: bool = true,
    /// Copy the current selection to the PRIMARY clipboard
    /// automatically on selection-end (Linux convention; Terminator
    /// has it off by default but it's a popular toggle).
    copy_on_selection: bool = false,
    /// Drop the active selection after a Ctrl+Shift+C copy.
    clear_select_on_copy: bool = false,
    /// Disable middle-click PRIMARY paste entirely.
    disable_mouse_paste: bool = false,
    /// Disable Ctrl+wheel font-size zoom.
    disable_mousewheel_zoom: bool = false,
    /// Open OSC 8 hyperlinks on a plain click instead of Ctrl+click.
    /// (Off by default — matches xterm/gnome-terminal/kitty.)
    link_single_click: bool = false,

    // Search
    /// Default state for the search box's case sensitivity. The
    /// actual default is smart-case unless overridden by Ctrl+I or
    /// this setting.
    search_case_sensitive: bool = false,

    // Bold
    /// Whether bold attribute affects rendering at all (font weight
    /// + bright-color promotion). Off renders bold cells the same as
    /// normal — matches gnome-terminal's "Allow bold text" toggle.
    allow_bold: bool = true,
    /// When bold + allow_bold, also lift palette indices 0..7 to
    /// their bright variants 8..15 (xterm convention). Off keeps
    /// the original colour and only changes weight.
    bold_is_bright: bool = true,

    // URL detection
    /// Auto-detect plain http(s) URLs in cell content and underline
    /// them. OSC 8 hyperlinks (when present) win — auto-detected
    /// matches in OSC 8 ranges are skipped. Click / Ctrl+click to
    /// open via the system handler.
    auto_url_detect: bool = true,

    // Background opacity (Wayland with compositor support).
    /// Window background opacity. 1.0 = fully opaque (default).
    /// 0.0 = fully transparent. Multiplied into default_bg.a so the
    /// glClearColor + cell_pass bg quads emit non-opaque alpha. The
    /// compositor must support per-window alpha (KWin / Mutter do).
    /// Blur (KWin's org_kde_kwin_blur protocol) is NOT reachable from
    /// GTK4 — set blur via your compositor's window rules.
    background_opacity: f32 = 1.0,

    // Inactive pane dimming (Terminator-style: multiply RGB channels)
    /// Multiplier applied to foreground colours of unfocused panes.
    /// 1.0 = no dim; 0.0 = fully black. Terminator default is 0.8 —
    /// the unfocused text becomes visibly dimmer without hurting
    /// readability. Cursor, selection, overlay, and decorations
    /// stay at full brightness.
    inactive_fg_dim: f32 = 0.8,
    /// Same for background. Default 1.0 means "no dim on bg" — most
    /// users prefer the unfocused pane to keep its dark theme. Set
    /// closer to 0.85 for a subtle "sleeping" effect.
    inactive_bg_dim: f32 = 1.0,

    /// Custom keybindings. List of (action_name, accelerator) pairs
    /// parsed from `keybind.<action> = <accel>` lines. An entry with
    /// an empty accel unbinds that action; a missing entry inherits
    /// the default. Round-trip-stable.
    keybinds: std.ArrayList(KeybindEntry) = .{},

    /// Named profiles. Defined via `[profile.<name>]` sections —
    /// each section's keys override the corresponding global Config
    /// field for panes that select this profile. Order preserved
    /// for round-trip serialisation + UI listing.
    profiles: std.ArrayList(Profile) = .{},
    /// Profile name used when no explicit profile is selected. Empty
    /// = "no default profile; use the global Config directly".
    default_profile: []const u8 = "",

    // Per-pane titlebar (Terminator-style)
    /// Show a thin per-pane title bar above the cell grid carrying
    /// the OSC 0/1/2 terminal title. Off by default — many users
    /// prefer minimal chrome.
    show_titlebar: bool = false,
    /// Show the AdwTabBar at startup. On by default; users running
    /// a single tab can set this to false (or rebind toggle_tab_bar)
    /// to reclaim ~32 px of vertical space.
    show_tab_bar: bool = true,
    /// Active pane title bar foreground / background. Default
    /// matches Terminator (red bg / white fg) so users coming from
    /// Terminator see the familiar "this pane has focus" cue.
    title_active_fg: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    title_active_bg: [4]f32 = .{ 200.0/255.0, 0.0/255.0, 3.0/255.0, 1.0 },
    /// Inactive pane title bar foreground / background. Defaults to
    /// Terminator's mid-grey so unfocused panes are visibly dimmer.
    title_inactive_fg: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 },
    title_inactive_bg: [4]f32 = .{ 192.0/255.0, 190.0/255.0, 191.0/255.0, 1.0 },

    // Owned strings allocated from the parser arena. Not freed
    // individually — `arena.deinit()` reaps everything.
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
    }

    /// Try `~/.config/sketerm/config.conf`. Missing file → defaults.
    /// Parse errors print to stderr and fall back to defaults.
    /// Env overrides (SKETERM_FONT, SKETERM_SCROLLBACK) win over the
    /// file values — explicit invocation beats persistent config.
    pub fn load(allocator: std.mem.Allocator) Config {
        return loadWithOverride(allocator, null);
    }

    /// Load with an optional explicit path that overrides the default
    /// XDG / ~/.config search. Used by --config <path>.
    pub fn loadWithOverride(allocator: std.mem.Allocator, override_path: ?[]const u8) Config {
        var cfg = Config{};
        const resolved: ?[]u8 = if (override_path) |p|
            allocator.dupe(u8, p) catch null
        else
            resolveConfigPath(allocator);
        if (resolved) |path| {
            defer allocator.free(path);
            if (std.fs.openFileAbsolute(path, .{})) |file| {
                defer file.close();
                const max_bytes: usize = 64 * 1024;
                var buf: [max_bytes]u8 = undefined;
                if (file.read(&buf)) |n| {
                    cfg.arena = std.heap.ArenaAllocator.init(allocator);
                    parseInto(&cfg, buf[0..n]) catch {
                        std.debug.print("sketerm: config parse error in {s}, using defaults\n", .{path});
                        cfg.deinit();
                        cfg = Config{};
                    };
                } else |_| {}
            } else |_| {
                if (override_path != null) {
                    std.debug.print("sketerm: --config path {s} not readable, using defaults\n", .{path});
                }
            }
        }

        // Env overrides — highest priority.
        if (std.posix.getenv("SKETERM_SCROLLBACK")) |env| {
            if (std.fmt.parseInt(u32, env, 10)) |n| cfg.scrollback = n else |_| {}
        }
        if (std.posix.getenv("SKETERM_FONT")) |env_path| {
            if (cfg.arena == null) cfg.arena = std.heap.ArenaAllocator.init(allocator);
            const arena = cfg.arena.?.allocator();
            cfg.font_path = arena.dupe(u8, env_path) catch cfg.font_path;
        }
        return cfg;
    }

    pub fn loadFromBytes(allocator: std.mem.Allocator, body: []const u8) !Config {
        var cfg = Config{ .arena = std.heap.ArenaAllocator.init(allocator) };
        try parseInto(&cfg, body);
        return cfg;
    }

    /// Atomic write to `path`: serialise every key whose value differs
    /// from the schema default (so the file stays minimal). On disk
    /// the format round-trips through `loadFromBytes` exactly.
    pub fn save(self: *const Config, path: []const u8) !void {
        var dir = try ensureParentDir(path);
        defer dir.close();
        const basename = std.fs.path.basename(path);

        var tmp_buf: [256]u8 = undefined;
        const tmp_name = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{basename});
        var tmp = try dir.createFile(tmp_name, .{ .truncate = true });
        defer tmp.close();

        var write_buf: [4096]u8 = undefined;
        var fw = tmp.writer(&write_buf);
        try self.serialise(&fw.interface);
        try fw.interface.flush();

        try dir.rename(tmp_name, basename);
    }

    /// Same content as save() but directly into a Writer — used by
    /// tests + the prefs dialog's preview path.
    pub fn serialise(self: *const Config, w: *std.io.Writer) !void {
        try w.writeAll("# sketerm config (auto-saved by Preferences dialog)\n");

        // Font.
        if (self.font_path) |fp| try w.print("font = {s}\n", .{fp});
        if (self.font_size != 14) try w.print("font_size = {d}\n", .{self.font_size});
        if (self.line_pad_px != 0) try w.print("line_pad_px = {d}\n", .{self.line_pad_px});

        // Colors.
        if (!eqColor(self.default_fg, .{ 0.92, 0.92, 0.92, 1.0 }))
            try writeColor(w, "default_fg", self.default_fg);
        if (!eqColor(self.default_bg, .{ 0.10, 0.10, 0.10, 1.0 }))
            try writeColor(w, "default_bg", self.default_bg);
        if (!eqColor(self.cursor_color, .{ 1.0, 1.0, 1.0, 1.0 }))
            try writeColor(w, "cursor_color", self.cursor_color);

        // Cursor.
        if (self.cursor_shape != .block) try w.print("cursor_shape = {s}\n", .{@tagName(self.cursor_shape)});
        if (!self.cursor_blink) try w.writeAll("cursor_blink = false\n");
        if (self.cursor_blink_ms != 500) try w.print("cursor_blink_ms = {d}\n", .{self.cursor_blink_ms});

        // Layout.
        if (self.padding != 6.0) try w.print("padding = {d:.2}\n", .{self.padding});
        if (self.scrollback != 10000) try w.print("scrollback = {d}\n", .{self.scrollback});

        // Shell + env.
        if (self.shell) |s| try w.print("shell = {s}\n", .{s});
        if (!std.mem.eql(u8, self.term_env, "xterm-256color"))
            try w.print("term = {s}\n", .{self.term_env});
        if (!std.mem.eql(u8, self.color_term_env, "truecolor"))
            try w.print("color_term = {s}\n", .{self.color_term_env});

        // Behaviour.
        if (!self.bracketed_paste) try w.writeAll("bracketed_paste = false\n");
        if (self.modify_other_keys != 0) try w.print("modify_other_keys = {d}\n", .{self.modify_other_keys});

        // Rendering.
        if (!self.ligatures) try w.writeAll("ligatures = false\n");
        if (!self.bidi) try w.writeAll("bidi = false\n");
        if (!self.auto_theme) try w.writeAll("auto_theme = false\n");

        // Bell.
        if (self.bell_audible) try w.writeAll("bell_audible = true\n");
        if (!self.bell_visible) try w.writeAll("bell_visible = false\n");
        if (!self.bell_urgent) try w.writeAll("bell_urgent = false\n");

        // Behavioural extras.
        if (self.scroll_on_output) try w.writeAll("scroll_on_output = true\n");
        if (!self.smart_copy) try w.writeAll("smart_copy = false\n");
        if (self.login_shell) try w.writeAll("login_shell = true\n");
        if (!self.cursor_color_default) try w.writeAll("cursor_color_default = false\n");
        if (!std.mem.eql(u8, self.word_chars, "-_.,/?:@&=+%~"))
            try w.print("word_chars = {s}\n", .{self.word_chars});

        // Window.
        if (self.tab_position != .top) try w.print("tab_position = {s}\n", .{@tagName(self.tab_position)});
        if (!self.close_button_on_tab) try w.writeAll("close_button_on_tab = false\n");
        if (self.always_on_top) try w.writeAll("always_on_top = true\n");
        if (self.new_tab_after_current) try w.writeAll("new_tab_after_current = true\n");
        if (self.confirm_close != .multiple)
            try w.print("confirm_close = {s}\n", .{@tagName(self.confirm_close)});

        // Mouse.
        if (!self.mouse_autohide) try w.writeAll("mouse_autohide = false\n");
        if (self.copy_on_selection) try w.writeAll("copy_on_selection = true\n");
        if (self.clear_select_on_copy) try w.writeAll("clear_select_on_copy = true\n");
        if (self.disable_mouse_paste) try w.writeAll("disable_mouse_paste = true\n");
        if (self.disable_mousewheel_zoom) try w.writeAll("disable_mousewheel_zoom = true\n");
        if (self.link_single_click) try w.writeAll("link_single_click = true\n");

        // Search.
        if (self.search_case_sensitive) try w.writeAll("search_case_sensitive = true\n");

        // Bold.
        if (!self.allow_bold) try w.writeAll("allow_bold = false\n");
        if (!self.bold_is_bright) try w.writeAll("bold_is_bright = false\n");

        // URL detection.
        if (!self.auto_url_detect) try w.writeAll("auto_url_detect = false\n");

        // Custom keybindings — emit one line per non-default override.
        for (self.keybinds.items) |kb| {
            try w.print("keybind.{s} = {s}\n", .{ kb.name, kb.accel });
        }

        // Background opacity.
        if (self.background_opacity != 1.0)
            try w.print("background_opacity = {d:.2}\n", .{self.background_opacity});

        // Inactive pane dimming.
        if (self.inactive_fg_dim != 0.8)
            try w.print("inactive_fg_dim = {d:.2}\n", .{self.inactive_fg_dim});
        if (self.inactive_bg_dim != 1.0)
            try w.print("inactive_bg_dim = {d:.2}\n", .{self.inactive_bg_dim});

        // Per-pane titlebar.
        if (self.show_titlebar) try w.writeAll("show_titlebar = true\n");
        if (!self.show_tab_bar) try w.writeAll("show_tab_bar = false\n");
        const default_taf: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };
        const default_tab: [4]f32 = .{ 200.0/255.0, 0.0/255.0, 3.0/255.0, 1.0 };
        const default_tif: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
        const default_tib: [4]f32 = .{ 192.0/255.0, 190.0/255.0, 191.0/255.0, 1.0 };
        if (!eqColor(self.title_active_fg, default_taf))
            try writeColor(w, "title_active_fg", self.title_active_fg);
        if (!eqColor(self.title_active_bg, default_tab))
            try writeColor(w, "title_active_bg", self.title_active_bg);
        if (!eqColor(self.title_inactive_fg, default_tif))
            try writeColor(w, "title_inactive_fg", self.title_inactive_fg);
        if (!eqColor(self.title_inactive_bg, default_tib))
            try writeColor(w, "title_inactive_bg", self.title_inactive_bg);

        // Shell exit.
        if (self.exit_action != .close) try w.print("exit_action = {s}\n", .{@tagName(self.exit_action)});

        // Color scheme + palette.
        if (self.scheme.len > 0) try w.print("scheme = {s}\n", .{self.scheme});
        if (self.palette) |pal| {
            try w.writeAll("palette = ");
            for (pal, 0..) |rgb, i| {
                if (i != 0) try w.writeAll(":");
                try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] });
            }
            try w.writeAll("\n");
        }

        // Default profile, then each [profile.name] section.
        if (self.default_profile.len > 0)
            try w.print("default_profile = {s}\n", .{self.default_profile});
        for (self.profiles.items) |prof| {
            try w.print("\n[profile.{s}]\n", .{prof.name});
            if (prof.shell.len > 0) try w.print("shell = {s}\n", .{prof.shell});
            if (prof.font_path.len > 0) try w.print("font = {s}\n", .{prof.font_path});
            if (prof.font_size != 0) try w.print("font_size = {d}\n", .{prof.font_size});
            if (prof.scheme.len > 0) try w.print("scheme = {s}\n", .{prof.scheme});
            if (prof.term_env.len > 0) try w.print("term = {s}\n", .{prof.term_env});
            if (prof.color_term_env.len > 0) try w.print("color_term = {s}\n", .{prof.color_term_env});
            if (prof.scrollback != 0) try w.print("scrollback = {d}\n", .{prof.scrollback});
            if (prof.login_shell) |b| try w.print("login_shell = {s}\n", .{if (b) "true" else "false"});
            if (prof.palette) |pal| {
                try w.writeAll("palette = ");
                for (pal, 0..) |rgb, i| {
                    if (i != 0) try w.writeAll(":");
                    try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] });
                }
                try w.writeAll("\n");
            }
        }
    }
};

fn eqColor(a: [4]f32, b: [4]f32) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn writeColor(w: *std.io.Writer, key: []const u8, c: [4]f32) !void {
    const r: u8 = @intFromFloat(@round(c[0] * 255.0));
    const g: u8 = @intFromFloat(@round(c[1] * 255.0));
    const b: u8 = @intFromFloat(@round(c[2] * 255.0));
    try w.print("{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{ key, r, g, b });
}

fn ensureParentDir(path: []const u8) !std.fs.Dir {
    const dirname = std.fs.path.dirname(path) orelse ".";
    return std.fs.cwd().makeOpenPath(dirname, .{});
}

/// Allocates the path; caller frees.
fn resolveConfigPath(allocator: std.mem.Allocator) ?[]u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/config.conf", .{x}) catch null;
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/sketerm/config.conf", .{home}) catch null;
    }
    return null;
}

fn parseInto(cfg: *Config, body: []const u8) !void {
    const arena = cfg.arena.?.allocator();
    var lines = std.mem.splitScalar(u8, body, '\n');
    var lineno: usize = 0;
    // Section state. `null` = global; non-null = profile being filled.
    var current_profile: ?*Profile = null;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = trim(stripComment(raw));
        if (line.len == 0) continue;

        // Section header: [profile.<name>] only for now. Unknown
        // sections log a warning and behave as no-section pass-through
        // — that way unknown future sections don't strip user data.
        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            const inside = trim(line[1 .. line.len - 1]);
            if (std.mem.startsWith(u8, inside, "profile.")) {
                const name = inside["profile.".len..];
                if (name.len == 0) {
                    std.debug.print("sketerm: config:{d}: empty profile name\n", .{lineno});
                    current_profile = null;
                    continue;
                }
                current_profile = findOrCreateProfile(cfg, arena, name) catch {
                    std.debug.print("sketerm: config:{d}: out of memory creating profile\n", .{lineno});
                    current_profile = null;
                    continue;
                };
                continue;
            }
            std.debug.print("sketerm: config:{d}: unknown section '{s}'\n", .{ lineno, inside });
            current_profile = null;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.debug.print("sketerm: config:{d}: expected key = value\n", .{lineno});
            continue;
        };
        const key = trim(line[0..eq]);
        const value = trim(line[eq + 1 ..]);
        if (current_profile) |prof| {
            applyProfileKv(prof, arena, key, value) catch |err| {
                std.debug.print("sketerm: config:{d}: profile '{s}': bad value for '{s}' ({s})\n", .{ lineno, prof.name, key, @errorName(err) });
            };
        } else {
            applyKv(cfg, arena, key, value) catch |err| {
                std.debug.print("sketerm: config:{d}: bad value for '{s}' ({s})\n", .{ lineno, key, @errorName(err) });
            };
        }
    }
}

fn findOrCreateProfile(cfg: *Config, arena: std.mem.Allocator, name: []const u8) !*Profile {
    for (cfg.profiles.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    const dup = try arena.dupe(u8, name);
    try cfg.profiles.append(arena, .{ .name = dup });
    return &cfg.profiles.items[cfg.profiles.items.len - 1];
}

/// Apply one (key, value) line to a profile. Mirrors a subset of
/// applyKv — only the per-pane fields the Profile struct holds.
fn applyProfileKv(prof: *Profile, arena: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "shell")) {
        prof.shell = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font") or std.mem.eql(u8, key, "font_path")) {
        prof.font_path = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font_size")) {
        prof.font_size = try parseU16(value);
    } else if (std.mem.eql(u8, key, "scheme")) {
        prof.scheme = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "palette")) {
        prof.palette = try parsePalette16(value);
    } else if (std.mem.eql(u8, key, "term") or std.mem.eql(u8, key, "term_env")) {
        prof.term_env = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "color_term") or std.mem.eql(u8, key, "color_term_env")) {
        prof.color_term_env = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "scrollback")) {
        prof.scrollback = try parseU32(value);
    } else if (std.mem.eql(u8, key, "login_shell")) {
        prof.login_shell = try parseBool(value);
    } else {
        std.debug.print("sketerm: config: unknown profile key '{s}' (ignoring)\n", .{key});
    }
}

fn applyKv(cfg: *Config, arena: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    // `keybind.<action> = <accel>` is a prefix-keyed family that's
    // handled separately from the flat one-key-per-field set below.
    // We dup name+value into the config arena and append; consumers
    // (Window) translate to `[]Binding` at apply time.
    if (std.mem.startsWith(u8, key, "keybind.")) {
        const name = key["keybind.".len..];
        if (name.len == 0) return error.BadKeybindName;
        const name_dup = try arena.dupe(u8, name);
        const accel_dup = try arena.dupe(u8, value);
        // Replace existing entry for the same name so a later override
        // wins over an earlier line.
        for (cfg.keybinds.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.accel = accel_dup;
                return;
            }
        }
        try cfg.keybinds.append(arena, .{ .name = name_dup, .accel = accel_dup });
        return;
    }
    if (std.mem.eql(u8, key, "font")) {
        cfg.font_path = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font_size")) {
        cfg.font_size = try parseU16(value);
    } else if (std.mem.eql(u8, key, "line_pad_px") or std.mem.eql(u8, key, "line_spacing")) {
        cfg.line_pad_px = try parseI16(value);
    } else if (std.mem.eql(u8, key, "default_fg")) {
        cfg.default_fg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "default_bg")) {
        cfg.default_bg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor_color")) {
        cfg.cursor_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor_shape")) {
        if (std.mem.eql(u8, value, "block")) cfg.cursor_shape = .block
        else if (std.mem.eql(u8, value, "underline")) cfg.cursor_shape = .underline
        else if (std.mem.eql(u8, value, "bar")) cfg.cursor_shape = .bar
        else return error.BadCursorShape;
    } else if (std.mem.eql(u8, key, "cursor_blink")) {
        cfg.cursor_blink = try parseBool(value);
    } else if (std.mem.eql(u8, key, "cursor_blink_ms")) {
        cfg.cursor_blink_ms = try parseU32(value);
    } else if (std.mem.eql(u8, key, "padding")) {
        cfg.padding = try parseFloat(value);
    } else if (std.mem.eql(u8, key, "scrollback")) {
        cfg.scrollback = try parseU32(value);
    } else if (std.mem.eql(u8, key, "shell")) {
        cfg.shell = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "term") or std.mem.eql(u8, key, "term_env")) {
        cfg.term_env = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "color_term") or std.mem.eql(u8, key, "color_term_env")) {
        cfg.color_term_env = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "bracketed_paste")) {
        cfg.bracketed_paste = try parseBool(value);
    } else if (std.mem.eql(u8, key, "modify_other_keys")) {
        const n = try parseU16(value);
        if (n > 2) return error.BadModifyOtherKeys;
        cfg.modify_other_keys = @intCast(n);
    } else if (std.mem.eql(u8, key, "ligatures")) {
        cfg.ligatures = try parseBool(value);
    } else if (std.mem.eql(u8, key, "bidi")) {
        cfg.bidi = try parseBool(value);
    } else if (std.mem.eql(u8, key, "auto_theme")) {
        cfg.auto_theme = try parseBool(value);
    } else if (std.mem.eql(u8, key, "bell_audible")) {
        cfg.bell_audible = try parseBool(value);
    } else if (std.mem.eql(u8, key, "bell_visible")) {
        cfg.bell_visible = try parseBool(value);
    } else if (std.mem.eql(u8, key, "bell_urgent")) {
        cfg.bell_urgent = try parseBool(value);
    } else if (std.mem.eql(u8, key, "scroll_on_output")) {
        cfg.scroll_on_output = try parseBool(value);
    } else if (std.mem.eql(u8, key, "smart_copy")) {
        cfg.smart_copy = try parseBool(value);
    } else if (std.mem.eql(u8, key, "login_shell")) {
        cfg.login_shell = try parseBool(value);
    } else if (std.mem.eql(u8, key, "cursor_color_default")) {
        cfg.cursor_color_default = try parseBool(value);
    } else if (std.mem.eql(u8, key, "close_button_on_tab")) {
        cfg.close_button_on_tab = try parseBool(value);
    } else if (std.mem.eql(u8, key, "word_chars")) {
        cfg.word_chars = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "scheme")) {
        cfg.scheme = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "exit_action")) {
        if (std.mem.eql(u8, value, "close")) cfg.exit_action = .close
        else if (std.mem.eql(u8, value, "restart")) cfg.exit_action = .restart
        else if (std.mem.eql(u8, value, "hold")) cfg.exit_action = .hold
        else return error.BadExitAction;
    } else if (std.mem.eql(u8, key, "tab_position")) {
        if (std.mem.eql(u8, value, "top")) cfg.tab_position = .top
        else if (std.mem.eql(u8, value, "bottom")) cfg.tab_position = .bottom
        else return error.BadTabPosition;
    } else if (std.mem.eql(u8, key, "palette")) {
        cfg.palette = try parsePalette16(value);
    } else if (std.mem.eql(u8, key, "always_on_top")) {
        cfg.always_on_top = try parseBool(value);
    } else if (std.mem.eql(u8, key, "new_tab_after_current")) {
        cfg.new_tab_after_current = try parseBool(value);
    } else if (std.mem.eql(u8, key, "confirm_close")) {
        if (std.mem.eql(u8, value, "never")) cfg.confirm_close = .never
        else if (std.mem.eql(u8, value, "multiple")) cfg.confirm_close = .multiple
        else if (std.mem.eql(u8, value, "always")) cfg.confirm_close = .always
        else return error.BadConfirmClose;
    } else if (std.mem.eql(u8, key, "mouse_autohide")) {
        cfg.mouse_autohide = try parseBool(value);
    } else if (std.mem.eql(u8, key, "copy_on_selection")) {
        cfg.copy_on_selection = try parseBool(value);
    } else if (std.mem.eql(u8, key, "clear_select_on_copy")) {
        cfg.clear_select_on_copy = try parseBool(value);
    } else if (std.mem.eql(u8, key, "disable_mouse_paste")) {
        cfg.disable_mouse_paste = try parseBool(value);
    } else if (std.mem.eql(u8, key, "disable_mousewheel_zoom")) {
        cfg.disable_mousewheel_zoom = try parseBool(value);
    } else if (std.mem.eql(u8, key, "link_single_click")) {
        cfg.link_single_click = try parseBool(value);
    } else if (std.mem.eql(u8, key, "search_case_sensitive")) {
        cfg.search_case_sensitive = try parseBool(value);
    } else if (std.mem.eql(u8, key, "allow_bold")) {
        cfg.allow_bold = try parseBool(value);
    } else if (std.mem.eql(u8, key, "bold_is_bright")) {
        cfg.bold_is_bright = try parseBool(value);
    } else if (std.mem.eql(u8, key, "auto_url_detect")) {
        cfg.auto_url_detect = try parseBool(value);
    } else if (std.mem.eql(u8, key, "default_profile")) {
        cfg.default_profile = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "background_opacity")) {
        cfg.background_opacity = std.math.clamp(try parseFloat(value), 0.0, 1.0);
    } else if (std.mem.eql(u8, key, "inactive_fg_dim")) {
        cfg.inactive_fg_dim = std.math.clamp(try parseFloat(value), 0.0, 1.0);
    } else if (std.mem.eql(u8, key, "inactive_bg_dim")) {
        cfg.inactive_bg_dim = std.math.clamp(try parseFloat(value), 0.0, 1.0);
    } else if (std.mem.eql(u8, key, "show_titlebar")) {
        cfg.show_titlebar = try parseBool(value);
    } else if (std.mem.eql(u8, key, "show_tab_bar")) {
        cfg.show_tab_bar = try parseBool(value);
    } else if (std.mem.eql(u8, key, "title_active_fg")) {
        cfg.title_active_fg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "title_active_bg")) {
        cfg.title_active_bg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "title_inactive_fg")) {
        cfg.title_inactive_fg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "title_inactive_bg")) {
        cfg.title_inactive_bg = try parseColor(value);
    } else {
        // Unknown key — warn but don't abort.
        std.debug.print("sketerm: config: unknown key '{s}' (ignoring)\n", .{key});
    }
}

/// Parse `#RRGGBB:#RRGGBB:…:#RRGGBB` (16 entries, colon-separated).
/// Matches Terminator's palette format.
fn parsePalette16(s: []const u8) ![16][3]u8 {
    var out: [16][3]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, ':');
    var i: usize = 0;
    while (it.next()) |tok| : (i += 1) {
        if (i >= 16) return error.PaletteTooLong;
        const t = std.mem.trim(u8, tok, &std.ascii.whitespace);
        if (t.len != 7 or t[0] != '#') return error.BadPaletteEntry;
        out[i][0] = try std.fmt.parseInt(u8, t[1..3], 16);
        out[i][1] = try std.fmt.parseInt(u8, t[3..5], 16);
        out[i][2] = try std.fmt.parseInt(u8, t[5..7], 16);
    }
    if (i != 16) return error.PaletteTooShort;
    return out;
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

fn stripComment(line: []const u8) []const u8 {
    // `#` is a comment only at the very start of the (whitespace-
    // stripped) line. This keeps `#abcdef` hex colors usable as
    // values. Inline trailing comments are not supported v1.
    const t = trim(line);
    if (t.len > 0 and t[0] == '#') return "";
    return line;
}

fn parseU16(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, s, 10);
}

fn parseI16(s: []const u8) !i16 {
    return std.fmt.parseInt(i16, s, 10);
}

fn parseU32(s: []const u8) !u32 {
    return std.fmt.parseInt(u32, s, 10);
}

fn parseFloat(s: []const u8) !f32 {
    return std.fmt.parseFloat(f32, s);
}

fn parseBool(s: []const u8) !bool {
    if (std.ascii.eqlIgnoreCase(s, "true") or std.mem.eql(u8, s, "1") or std.ascii.eqlIgnoreCase(s, "yes") or std.ascii.eqlIgnoreCase(s, "on"))
        return true;
    if (std.ascii.eqlIgnoreCase(s, "false") or std.mem.eql(u8, s, "0") or std.ascii.eqlIgnoreCase(s, "no") or std.ascii.eqlIgnoreCase(s, "off"))
        return false;
    return error.BadBool;
}

/// Accepts `#RRGGBB`, `#RRGGBBAA`, or comma-separated `R,G,B[,A]`
/// in 0..255.
fn parseColor(s: []const u8) ![4]f32 {
    if (s.len > 0 and s[0] == '#') {
        const hex = s[1..];
        if (hex.len == 6 or hex.len == 8) {
            const r = try std.fmt.parseInt(u8, hex[0..2], 16);
            const g = try std.fmt.parseInt(u8, hex[2..4], 16);
            const b = try std.fmt.parseInt(u8, hex[4..6], 16);
            const a: u8 = if (hex.len == 8) try std.fmt.parseInt(u8, hex[6..8], 16) else 0xFF;
            return .{
                @as(f32, @floatFromInt(r)) / 255.0,
                @as(f32, @floatFromInt(g)) / 255.0,
                @as(f32, @floatFromInt(b)) / 255.0,
                @as(f32, @floatFromInt(a)) / 255.0,
            };
        }
        return error.BadColorHex;
    }
    // Comma-separated RGB(A) form.
    var parts: [4]u16 = .{ 0, 0, 0, 255 };
    var idx: usize = 0;
    var iter = std.mem.splitScalar(u8, s, ',');
    while (iter.next()) |raw| : (idx += 1) {
        if (idx >= 4) return error.BadColorRgb;
        const t = trim(raw);
        parts[idx] = try parseU16(t);
        if (parts[idx] > 255) return error.BadColorRgb;
    }
    if (idx < 3) return error.BadColorRgb;
    return .{
        @as(f32, @floatFromInt(parts[0])) / 255.0,
        @as(f32, @floatFromInt(parts[1])) / 255.0,
        @as(f32, @floatFromInt(parts[2])) / 255.0,
        @as(f32, @floatFromInt(parts[3])) / 255.0,
    };
}

// ---------------- tests ----------------

test "config: defaults when body is empty" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 14), cfg.font_size);
    try std.testing.expectEqual(@as(u32, 10000), cfg.scrollback);
    try std.testing.expectEqualStrings("xterm-256color", cfg.term_env);
}

test "config: parses key=value lines" {
    const body =
        \\# comment
        \\font_size = 16
        \\scrollback = 50000
        \\cursor_shape = bar
        \\cursor_blink = false
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 16), cfg.font_size);
    try std.testing.expectEqual(@as(u32, 50000), cfg.scrollback);
    try std.testing.expectEqual(CursorShape.bar, cfg.cursor_shape);
    try std.testing.expectEqual(false, cfg.cursor_blink);
}

test "config: parses #RRGGBB and RGB triplets" {
    const body =
        \\default_fg = #abcdef
        \\default_bg = 16, 32, 48
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectApproxEqAbs(@as(f32, 0xab) / 255.0, cfg.default_fg[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 16) / 255.0, cfg.default_bg[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 48) / 255.0, cfg.default_bg[2], 0.001);
}

test "config: bools accept multiple forms" {
    const body =
        \\bracketed_paste = on
        \\cursor_blink = no
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(true, cfg.bracketed_paste);
    try std.testing.expectEqual(false, cfg.cursor_blink);
}

test "config: stores font path" {
    const body = "font = /usr/share/fonts/Hack/Hack-Regular.ttf";
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("/usr/share/fonts/Hack/Hack-Regular.ttf", cfg.font_path.?);
}

test "config: line_pad_px parses int (positive and negative)" {
    const body =
        \\font_size = 12
        \\line_pad_px = -2
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(i16, -2), cfg.line_pad_px);

    const body2 =
        \\line_spacing = 4
    ;
    var cfg2 = try Config.loadFromBytes(std.testing.allocator, body2);
    defer cfg2.deinit();
    try std.testing.expectEqual(@as(i16, 4), cfg2.line_pad_px);
}

test "config: serialise omits defaults" {
    var cfg = Config{};
    var buf: [1024]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    // Empty config should serialise to just the header comment —
    // no key=value lines for default values.
    try std.testing.expect(std.mem.startsWith(u8, out, "# sketerm config"));
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ligatures") == null);
}

test "config: palette + scheme + new keys round-trip" {
    var cfg = Config{};
    cfg.scheme = "solarized_dark";
    cfg.palette = .{
        .{ 0x07, 0x36, 0x42 }, .{ 0xdc, 0x32, 0x2f }, .{ 0x85, 0x99, 0x00 }, .{ 0xb5, 0x89, 0x00 },
        .{ 0x26, 0x8b, 0xd2 }, .{ 0xd3, 0x36, 0x82 }, .{ 0x2a, 0xa1, 0x98 }, .{ 0xee, 0xe8, 0xd5 },
        .{ 0x00, 0x2b, 0x36 }, .{ 0xcb, 0x4b, 0x16 }, .{ 0x58, 0x6e, 0x75 }, .{ 0x65, 0x7b, 0x83 },
        .{ 0x83, 0x94, 0x96 }, .{ 0x6c, 0x71, 0xc4 }, .{ 0x93, 0xa1, 0xa1 }, .{ 0xfd, 0xf6, 0xe3 },
    };
    cfg.scroll_on_output = true;
    cfg.smart_copy = false;
    cfg.login_shell = true;
    cfg.cursor_color_default = false;
    cfg.tab_position = .bottom;
    cfg.close_button_on_tab = false;
    cfg.exit_action = .hold;
    cfg.bell_visible = false;
    cfg.bell_urgent = false;
    cfg.word_chars = "abc";

    var buf: [2048]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    try cfg.serialise(&w);

    var parsed = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer parsed.deinit();

    try std.testing.expectEqualStrings("solarized_dark", parsed.scheme);
    try std.testing.expect(parsed.palette != null);
    try std.testing.expectEqual(@as(u8, 0xdc), parsed.palette.?[1][0]);
    try std.testing.expectEqual(@as(u8, 0xfd), parsed.palette.?[15][0]);
    try std.testing.expectEqual(true, parsed.scroll_on_output);
    try std.testing.expectEqual(false, parsed.smart_copy);
    try std.testing.expectEqual(true, parsed.login_shell);
    try std.testing.expectEqual(false, parsed.cursor_color_default);
    try std.testing.expectEqual(TabPosition.bottom, parsed.tab_position);
    try std.testing.expectEqual(false, parsed.close_button_on_tab);
    try std.testing.expectEqual(ExitAction.hold, parsed.exit_action);
    try std.testing.expectEqual(false, parsed.bell_visible);
    try std.testing.expectEqual(false, parsed.bell_urgent);
    try std.testing.expectEqualStrings("abc", parsed.word_chars);
}

test "config: serialise round-trips through loadFromBytes" {
    // Set a few non-default values; serialise; re-parse; check.
    var cfg = Config{};
    cfg.font_size = 18;
    cfg.cursor_shape = .underline;
    cfg.scrollback = 50000;
    cfg.padding = 8.0;
    cfg.bracketed_paste = false;
    cfg.modify_other_keys = 2;
    cfg.line_pad_px = -1;
    cfg.default_fg = .{ 1.0, 0.5, 0.0, 1.0 };
    cfg.default_bg = .{ 0.0, 0.0, 0.0, 1.0 };
    cfg.cursor_color = .{ 0.5, 1.0, 0.5, 1.0 };
    cfg.bell_audible = true;
    cfg.ligatures = false;

    var buf: [2048]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();

    var parsed = try Config.loadFromBytes(std.testing.allocator, out);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u16, 18), parsed.font_size);
    try std.testing.expectEqual(CursorShape.underline, parsed.cursor_shape);
    try std.testing.expectEqual(@as(u32, 50000), parsed.scrollback);
    try std.testing.expectEqual(@as(f32, 8.0), parsed.padding);
    try std.testing.expectEqual(false, parsed.bracketed_paste);
    try std.testing.expectEqual(@as(u8, 2), parsed.modify_other_keys);
    try std.testing.expectEqual(@as(i16, -1), parsed.line_pad_px);
    try std.testing.expectEqual(true, parsed.bell_audible);
    try std.testing.expectEqual(false, parsed.ligatures);
    // Colors round-trip through #RRGGBB so they may lose the lowest
    // byte of float precision but the high bits should match.
    try std.testing.expect(@abs(parsed.default_fg[0] - 1.0) < 0.01);
    try std.testing.expect(@abs(parsed.default_fg[1] - 0.5) < 0.01);
    try std.testing.expect(@abs(parsed.default_fg[2] - 0.0) < 0.01);
    try std.testing.expect(@abs(parsed.cursor_color[1] - 1.0) < 0.01);
}

test "config: keybind.<action> entries round-trip" {
    const body =
        \\keybind.new_tab = <Control><Shift>t
        \\keybind.split_h = <Control><Alt>d
        \\keybind.search_open =
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 3), cfg.keybinds.items.len);
    try std.testing.expectEqualStrings("new_tab", cfg.keybinds.items[0].name);
    try std.testing.expectEqualStrings("<Control><Shift>t", cfg.keybinds.items[0].accel);
    try std.testing.expectEqualStrings("split_h", cfg.keybinds.items[1].name);
    try std.testing.expectEqualStrings("search_open", cfg.keybinds.items[2].name);
    try std.testing.expectEqualStrings("", cfg.keybinds.items[2].accel);

    // Round-trip via serialise → re-parse.
    var buf: [512]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    var parsed = try Config.loadFromBytes(std.testing.allocator, out);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.keybinds.items.len);
    try std.testing.expectEqualStrings("<Control><Alt>d", parsed.keybinds.items[1].accel);
}

test "config: later keybind for same action overrides earlier" {
    const body =
        \\keybind.new_tab = <Control><Shift>t
        \\keybind.new_tab = <Alt>n
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.keybinds.items.len);
    try std.testing.expectEqualStrings("<Alt>n", cfg.keybinds.items[0].accel);
}

test "config: [profile.name] sections round-trip" {
    const body =
        \\font_size = 14
        \\default_profile = dev
        \\
        \\[profile.dev]
        \\shell = /usr/bin/fish
        \\scheme = solarized_dark
        \\font_size = 16
        \\
        \\[profile.prod]
        \\shell = /usr/bin/bash
        \\login_shell = true
        \\scrollback = 50000
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(u16, 14), cfg.font_size); // global
    try std.testing.expectEqualStrings("dev", cfg.default_profile);
    try std.testing.expectEqual(@as(usize, 2), cfg.profiles.items.len);

    const dev = cfg.profiles.items[0];
    try std.testing.expectEqualStrings("dev", dev.name);
    try std.testing.expectEqualStrings("/usr/bin/fish", dev.shell);
    try std.testing.expectEqualStrings("solarized_dark", dev.scheme);
    try std.testing.expectEqual(@as(u16, 16), dev.font_size);

    const prod = cfg.profiles.items[1];
    try std.testing.expectEqualStrings("prod", prod.name);
    try std.testing.expectEqualStrings("/usr/bin/bash", prod.shell);
    try std.testing.expectEqual(@as(?bool, true), prod.login_shell);
    try std.testing.expectEqual(@as(u32, 50000), prod.scrollback);

    // Round-trip via serialise.
    var buf: [2048]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var parsed = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.profiles.items.len);
    try std.testing.expectEqualStrings("solarized_dark", parsed.profiles.items[0].scheme);
    try std.testing.expectEqual(@as(?bool, true), parsed.profiles.items[1].login_shell);
}

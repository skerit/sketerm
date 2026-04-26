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
    while (lines.next()) |raw| {
        lineno += 1;
        const line = trim(stripComment(raw));
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.debug.print("sketerm: config:{d}: expected key = value\n", .{lineno});
            continue;
        };
        const key = trim(line[0..eq]);
        const value = trim(line[eq + 1 ..]);
        applyKv(cfg, arena, key, value) catch |err| {
            std.debug.print("sketerm: config:{d}: bad value for '{s}' ({s})\n", .{ lineno, key, @errorName(err) });
        };
    }
}

fn applyKv(cfg: *Config, arena: std.mem.Allocator, key: []const u8, value: []const u8) !void {
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

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

    // Cursor
    cursor_shape: CursorShape = .block,
    cursor_blink: bool = true,
    /// Cursor blink interval in milliseconds. Each interval is one
    /// half-cycle (on→off OR off→on). 500 = full blink every 1000ms.
    cursor_blink_ms: u32 = 500,

    // Layout
    padding: f32 = 6.0,
    scrollback: u32 = 10000,

    // Shell + child env
    shell: ?[]const u8 = null,
    term_env: []const u8 = "xterm-256color",
    color_term_env: []const u8 = "truecolor",

    // Behavior
    bracketed_paste: bool = true,
    modify_other_keys: u8 = 0, // 0=off, 1=basic, 2=full

    // Rendering
    ligatures: bool = true,
    /// Bidirectional text reorder via fribidi. Only affects lines
    /// containing non-ASCII codepoints; pure-ASCII lines skip it.
    bidi: bool = true,
    /// If true, fg/bg follow AdwStyleManager dark/light. Set to
    /// false to honour `default_fg` / `default_bg` exactly.
    auto_theme: bool = true,
    /// Bell behaviour: visual flash always; audible toggles the
    /// system bell via gdk_display_beep.
    bell_audible: bool = false,

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
};

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
    } else {
        // Unknown key — warn but don't abort.
        std.debug.print("sketerm: config: unknown key '{s}' (ignoring)\n", .{key});
    }
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

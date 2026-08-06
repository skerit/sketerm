//! User-facing configuration loaded from ~/.config/sketerm/config.conf.
//!
//! Format: `key = value` per line. `#` starts a comment. Strings are
//! unquoted; values are parsed by type (int/float/bool/string/color).
//! Missing keys fall back to defaults. Unknown keys are ignored
//! (with a stderr warning) so newer configs work on older binaries.
//!
//! Loaded at app start via `Config.load` and re-loaded live — on the
//! `reload_config` action, on SIGUSR1, and (unless `config_auto_reload`
//! is off) whenever the file changes on disk (`ui/configwatch.zig`).

const std = @import("std");
const builtin = @import("builtin");
const lsp_servers = @import("lsp/servers.zig");
pub const titlefmt = @import("util/titlefmt.zig");

/// Historical tab-label behaviour: the OSC 0/2 title, verbatim.
pub const default_tab_title = "{{ TITLE }}";

/// One `[lsp.<name>]` section. The record lives in src/lsp/servers.zig
/// (with the built-in table and the matching rules) so the LSP client
/// does not have to import the config layer to know what a server is.
pub const LspServer = lsp_servers.Server;

/// Single-line config-load warning to stderr. Centralised so the
/// "sketerm: config: ..." prefix stays consistent across the parser.
fn warnConfig(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("sketerm: config: " ++ fmt ++ "\n", args);
}

/// Same as warnConfig but tags the source line number — used for
/// per-line parse errors (`sketerm: config:NN: ...`). We pre-format
/// the prefix so the user's `args` stays a separate tuple (Zig's
/// `++` on tuples is comptime-only).
fn warnConfigAt(lineno: usize, comptime fmt: []const u8, args: anytype) void {
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "sketerm: config:{d}: ", .{lineno}) catch "sketerm: config: ";
    std.debug.print("{s}", .{prefix});
    std.debug.print(fmt ++ "\n", args);
}

pub const CursorShape = enum { block, underline, bar };

/// What happens when a pane's shell exits. `close` removes the
/// pane (current behaviour). `restart` respawns the configured
/// shell. `hold` keeps the pane open with an exit-status banner
/// so users can see why a command died.
pub const ExitAction = enum { close, restart, hold };

/// Where a forwarded app's primary window renders: free-floating
/// window (the tab keeps the app log + a raise banner), or embedded
/// interactively inside the tab (pop-out available either way).
pub const AppView = enum { window, tab };

/// Which GtkIMContext implementation the keyboard faces use.
///
/// There is no value that gives both compose/dead keys and real input
/// methods (see src/ui/imhost.zig for the mechanism):
///
/// - `simple` — GTK's in-process Compose tables. Dead keys (`^`+`e` ->
///   `ê`, AltGr sequences, Compose) always work; no CJK/IME support.
/// - `multi` — GTK's per-display IM module, i.e. real input methods
///   (ibus/fcitx, candidate windows). On Wayland the module GTK picks
///   has no compose engine, so dead keys survive only if the
///   compositor's own IME composes them (GNOME/ibus yes; bare
///   KWin/sway no).
/// - `auto` — `multi` where the user has visibly configured an input
///   method (`$GTK_IM_MODULE` or the `gtk-im-module` GtkSettings
///   property naming something other than none/simple), `simple`
///   otherwise. GNOME/ibus sessions often set NEITHER, so IME users
///   there may have to say `input_method = multi` explicitly.
///
/// Deliberate asymmetry under `auto`: the TERMINAL always resolves to
/// `simple` (its dead-key behaviour is what users type shells with and
/// `auto` must not be able to take it away), while the editor and the
/// forwarded-app host IM follow the heuristic. An explicit `simple` or
/// `multi` overrides every face.
pub const InputMethod = enum { auto, simple, multi };

/// Colour space antialiased glyph coverage (and image alpha) is
/// blended in. Ghostty's `alpha-blending` key, which it shipped as
/// `text-blending` first; the value names are kept identical so its
/// documentation transfers.
///
/// - `native` — blend in the framebuffer's own (sRGB-encoded) space.
///   Physically wrong (sRGB values are not proportional to light) but
///   it is what every terminal did for decades, so it is the default.
/// - `linear` — blend in linear light. Removes the dark fringe that
///   complementary colours (red on green) produce at glyph edges, at
///   the cost of dark text reading thinner and light text thicker.
/// - `linear_corrected` — `linear` plus a per-fragment coverage
///   correction that restores `native`'s apparent stem weight, so the
///   fringe goes without the weight shift.
///
/// `linear-corrected` (ghostty's spelling) parses too.
pub const TextBlending = enum(u8) {
    native = 0,
    linear = 1,
    linear_corrected = 2,

    /// Whether the render path has to detour through the linear-light
    /// offscreen target. `native` renders straight to the GtkGLArea
    /// framebuffer and costs nothing.
    pub fn needsLinearTarget(self: TextBlending) bool {
        return self != .native;
    }
};

/// AdwTabBar position relative to the window.
pub const TabPosition = enum { top, bottom };

/// What a middle / right click does when the running app isn't in
/// mouse-report mode. `menu` only makes sense for right-click.
pub const MouseAction = enum { menu, paste_primary, paste_clipboard, none };

/// Custom keybinding entry: action name + accelerator string. Action
/// names are stable across versions (defined in `ui/input.zig`). The
/// accelerator is a GTK accelerator string (e.g. `<Control><Shift>t`)
/// — empty string unbinds.
pub const KeybindEntry = struct {
    name: []const u8,
    accel: []const u8,
};

/// A codepoint range routed to a specific font family, from a
/// `symbol_map.<name> = U+E0A0-U+E0A3 <family>` line. Consulted
/// before the primary face, so the mapped font wins even when the
/// main font has glyphs of its own in that range.
pub const SymbolMap = struct {
    name: []const u8,
    lo: u32 = 0,
    hi: u32 = 0,
    family: []const u8 = "",
};

/// `U+E0A0-U+E0A3 Some Family` or `U+E0A0 Some Family` (a single
/// codepoint). The `U+` prefix is optional on either end.
pub fn parseSymbolMap(name: []const u8, value: []const u8) !SymbolMap {
    const trimmed = std.mem.trim(u8, value, " \t");
    const sp = std.mem.indexOfAny(u8, trimmed, " \t") orelse return error.BadSymbolMap;
    const range = trimmed[0..sp];
    const family = std.mem.trim(u8, trimmed[sp + 1 ..], " \t");
    if (family.len == 0) return error.BadSymbolMap;

    const r = try parseCodepointRange(range);
    return .{ .name = name, .lo = r.lo, .hi = r.hi, .family = family };
}

pub const CodepointRange = struct { lo: u32, hi: u32 };

/// The range half of a `symbol_map` value: `U+E0A0-U+E0A3`, `E0A0-E0A3`
/// or a single codepoint. Split out from `parseSymbolMap` so the
/// Preferences dialog can validate the range field on its own with
/// exactly the parser's rules.
pub fn parseCodepointRange(range: []const u8) !CodepointRange {
    const t = std.mem.trim(u8, range, " \t");
    var lo_s = t;
    var hi_s = t;
    if (std.mem.indexOfScalar(u8, t, '-')) |dash| {
        lo_s = t[0..dash];
        hi_s = t[dash + 1 ..];
    }
    const lo = try parseCodepoint(lo_s);
    const hi = try parseCodepoint(hi_s);
    if (hi < lo) return error.BadSymbolMap;
    return .{ .lo = lo, .hi = hi };
}

/// Render a range back in the form the serialiser writes, so a UI can
/// show what will land in the file. Needs 32 bytes.
pub fn formatCodepointRange(buf: []u8, lo: u32, hi: u32) []const u8 {
    if (lo == hi) return std.fmt.bufPrint(buf, "U+{X}", .{lo}) catch "";
    return std.fmt.bufPrint(buf, "U+{X}-U+{X}", .{ lo, hi }) catch "";
}

fn parseCodepoint(text: []const u8) !u32 {
    var s = std.mem.trim(u8, text, " \t");
    if (s.len > 2 and (std.mem.startsWith(u8, s, "U+") or std.mem.startsWith(u8, s, "u+"))) s = s[2..];
    if (s.len > 2 and (std.mem.startsWith(u8, s, "0x") or std.mem.startsWith(u8, s, "0X"))) s = s[2..];
    if (s.len == 0) return error.BadSymbolMap;
    const v = std.fmt.parseInt(u32, s, 16) catch return error.BadSymbolMap;
    if (v > 0x10FFFF) return error.BadSymbolMap;
    return v;
}

/// CSS-style font weight, 100..900. Anything outside that is a config
/// error rather than a silent clamp: a weight of 12 is a typo, and
/// pretending it means 100 hides it.
fn parseWeight(value: []const u8) !u16 {
    const v = try parseU32(value);
    if (v < 100 or v > 900) return error.BadFontWeight;
    return @intCast(v);
}

/// What activating a hint does. `open` hands URLs to the desktop and
/// existing files to the editor; `command` runs `HintRule.command`
/// with {match} substituted.
pub const HintAction = enum { open, copy, paste, select, command };

/// One user-defined hint rule, from `hint.<name>.*` lines. The
/// pattern is a POSIX extended regular expression matched against
/// each visible row's text; an invalid one disables just that rule.
pub const HintRule = struct {
    name: []const u8,
    pattern: []const u8 = "",
    action: HintAction = .copy,
    /// Shell command for `action = command`. `{match}` is replaced
    /// with the matched text, shell-quoted.
    command: []const u8 = "",
};

/// Why a `symbol_map.<name>` / `hint.<name>` entry name was rejected.
pub const NameError = error{ EmptyName, NameTooLong, NameBadChar, DuplicateName };

/// A name usable as the `<name>` of a prefix-keyed family. The parser
/// splits a line at the first `=` and trims, so a name may not carry
/// `=`, whitespace or a control byte; `#`, `[` and `]` are refused
/// because they start a comment or a section header; `.` because
/// `hint.<name>.<field>` splits on the LAST dot and a name ending in
/// a field name would be unreadable. Non-ASCII is allowed — a family
/// nickname is the user's business.
pub fn checkEntryName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyName;
    if (name.len > 64) return error.NameTooLong;
    for (name) |ch| {
        if (ch < 0x21 or ch == 0x7f) return error.NameBadChar;
        switch (ch) {
            '=', '#', '[', ']', '.' => return error.NameBadChar,
            else => {},
        }
    }
}

/// One-line reason for a `NameError`, for a dialog to show verbatim.
pub fn nameErrorText(err: NameError) []const u8 {
    return switch (err) {
        error.EmptyName => "Name cannot be empty.",
        error.NameTooLong => "Name is longer than 64 characters.",
        error.NameBadChar => "Name may not contain spaces or any of = # [ ] .",
        error.DuplicateName => "An entry with that name already exists.",
    };
}

/// Why a `hint_alphabet` was rejected. Mirrors the runtime rule in
/// `ui/hints.zig`: an alphabet that cannot label things is ignored.
pub const AlphabetError = error{ AlphabetTooShort, AlphabetTooLong, AlphabetNotPrintable, AlphabetDuplicate };

pub fn checkHintAlphabet(alphabet: []const u8) AlphabetError!void {
    if (alphabet.len < 2) return error.AlphabetTooShort;
    if (alphabet.len > 64) return error.AlphabetTooLong;
    for (alphabet, 0..) |ch, i| {
        if (ch <= ' ' or ch > '~') return error.AlphabetNotPrintable;
        for (alphabet[i + 1 ..]) |other| {
            if (other == ch) return error.AlphabetDuplicate;
        }
    }
}

/// The alphabet if it can label matches, else null (caller falls back
/// to the built-in set). The single implementation behind both the
/// hint-mode runtime and the Preferences validation.
pub fn validHintAlphabet(alphabet: []const u8) ?[]const u8 {
    checkHintAlphabet(alphabet) catch return null;
    return alphabet;
}

pub fn alphabetErrorText(err: AlphabetError) []const u8 {
    return switch (err) {
        error.AlphabetTooShort => "Needs at least two characters.",
        error.AlphabetTooLong => "At most 64 characters.",
        error.AlphabetNotPrintable => "Printable ASCII only, no spaces.",
        error.AlphabetDuplicate => "A character is repeated — two matches would get the same label.",
    };
}

/// Whether a hint rule's pattern compiles as a POSIX extended regex.
/// NOT a parse rule: the config parser stores any pattern and
/// `ui/hints.zig` silently drops the rule if it fails to compile, so
/// this exists only so a dialog can warn instead of the rule dying
/// invisibly. An over-long pattern is reported as fine rather than
/// broken — refusing to check is not evidence of a fault.
pub fn hintPatternCompiles(pattern: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern.len >= 1024) return true;
    const c = @import("c.zig").c;
    var pat_z: [1024]u8 = undefined;
    @memcpy(pat_z[0..pattern.len], pattern);
    pat_z[pattern.len] = 0;
    // glibc's regex_t carries bitfields translate-c cannot model, so
    // it is opaque to Zig and cannot be a stack local (same dance as
    // ui/hints.zig).
    const buf = std.c.malloc(256) orelse return true;
    defer std.c.free(buf);
    const re: *c.regex_t = @ptrCast(@alignCast(buf));
    if (c.regcomp(re, @ptrCast(&pat_z), c.REG_EXTENDED) != 0) return false;
    c.regfree(re);
    return true;
}

/// Which half of a light/dark pair is in force.
pub const ColorScheme = enum { light, dark };

/// A partial override of a `ProfileSettings` colour set, parsed from
/// the `light.<key>` / `dark.<key>` families. Null means "inherit the
/// profile's flat value", which is what makes a config written before
/// variants existed behave exactly as it did.
pub const ColorSet = struct {
    default_fg: ?[4]f32 = null,
    default_bg: ?[4]f32 = null,
    cursor_color: ?[4]f32 = null,
    cursor_color_default: ?bool = null,
    palette: ?[16][3]u8 = null,
    /// Null = inherit; `""` = "no scheme" (cancels an inherited one).
    scheme: ?[]const u8 = null,

    pub fn isEmpty(self: ColorSet) bool {
        return std.meta.eql(self, ColorSet{});
    }

    /// Field-wise override: every non-null field of `over` wins.
    pub fn overlay(self: ColorSet, over: ColorSet) ColorSet {
        var out = self;
        if (over.default_fg) |v| out.default_fg = v;
        if (over.default_bg) |v| out.default_bg = v;
        if (over.cursor_color) |v| out.cursor_color = v;
        if (over.cursor_color_default) |v| out.cursor_color_default = v;
        if (over.palette) |v| out.palette = v;
        if (over.scheme) |v| out.scheme = v;
        return out;
    }

    /// Deep-copy the one heap-backed field into `arena`.
    pub fn cloneInto(self: *const ColorSet, arena: std.mem.Allocator) error{OutOfMemory}!ColorSet {
        var out = self.*;
        if (self.scheme) |s| out.scheme = try arena.dupe(u8, s);
        return out;
    }
};

/// The fg/bg sketerm has always substituted under `auto_theme`, now
/// expressed as the lowest layer of the light variant. A user
/// `light.*` key overrides it; anything it leaves null (palette,
/// cursor, scheme) keeps falling through to the flat values, which
/// is how auto_theme behaved before variants existed.
pub const builtin_light: ColorSet = .{
    .default_fg = .{ 0.10, 0.10, 0.10, 1.0 },
    .default_bg = .{ 0.97, 0.97, 0.97, 1.0 },
};

/// Dark counterpart of `builtin_light`.
pub const builtin_dark: ColorSet = .{
    .default_fg = .{ 0.92, 0.92, 0.92, 1.0 },
    .default_bg = .{ 0.10, 0.10, 0.10, 1.0 },
};

/// The pane-level settings bundle — everything that can sensibly
/// differ between two panes. The Default profile is the embedded
/// `Config.settings`; named profiles ([profile.<name>] sections) are
/// COMPLETE copies of this struct, not patches: there is no inherit
/// sentinel and no fallback chain at apply time. A new profile is
/// seeded from the Default settings at parse/create time.
pub const ProfileSettings = struct {
    // Font.
    font_path: ?[]const u8 = null,
    /// Font family name resolved via fontconfig ("JetBrains Mono").
    /// `font_path` wins when both are set. Empty = unset.
    font_family: []const u8 = "",
    /// Families for the styled faces. Empty = derive the style from
    /// `font_family` the way fontconfig would, which is right for a
    /// family that ships all four and wrong for the common pairing of
    /// one family's regular with another's italic.
    font_family_bold: []const u8 = "",
    font_family_italic: []const u8 = "",
    font_family_bold_italic: []const u8 = "",
    /// CSS weight (100..900) for the regular and bold faces. 0 = the
    /// font's own default (400 / 700). Selects the weight when
    /// resolving the family AND sets the `wght` axis on a variable
    /// font, which is the only way to reach the weights in between.
    font_weight: u16 = 0,
    font_weight_bold: u16 = 0,
    /// Draw box-drawing, block and Powerline characters from the cell
    /// rectangle instead of taking them from the font. On by default:
    /// a font's outlines are hinted per glyph and rarely tile without
    /// visible seams. Turn off to get the font's own shapes back.
    builtin_box_drawing: bool = true,
    /// OpenType features for HarfBuzz shaping, whitespace/comma
    /// separated, CSS/kitty syntax: "-calt +ss01 zero cv05=3".
    /// Empty = font defaults.
    font_features: []const u8 = "",
    font_size: u16 = 14,
    /// Extra pixels added to each cell's height for visual line
    /// spacing. 0 = font's natural metric; positive = looser; small
    /// negative = tighter (clamped so the glyph still fits).
    line_pad_px: i16 = 0,
    /// Inner padding around the cell grid, in pixels.
    padding: f32 = 6.0,

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
    /// …). Empty string = "no scheme; use defaults or `palette`".
    scheme: []const u8 = "",
    /// Colours to swap in while the system is in light mode
    /// (`light.<key> = …`). Only meaningful with `auto_theme`.
    light: ColorSet = .{},
    /// Colours to swap in while the system is in dark mode
    /// (`dark.<key> = …`). Only meaningful with `auto_theme`.
    dark: ColorSet = .{},

    // Shell + child env.
    shell: ?[]const u8 = null,
    term_env: []const u8 = "xterm-256color",
    color_term_env: []const u8 = "truecolor",
    /// Prepend `-` to argv[0] so the shell behaves as a login shell.
    login_shell: bool = false,

    scrollback: u32 = 10000,

    /// Custom post-process fragment shader (shadertoy-style file
    /// defining mainImage; iChannel0 = the rendered frame). Empty =
    /// off. Compile errors disable the pass, never blank the pane.
    custom_shader: []const u8 = "",

    // Text editor (the editor face rides a pane, so its FONT is a
    // pane-level choice like the terminal font — and its fallback,
    // `font_family`/`font_size`, is itself per-profile, so a fallback
    // could not cross the profile boundary even if we wanted it to).
    /// Proportional font family for the editor face, via fontconfig.
    /// Empty = fall back to this profile's terminal `font_family`
    /// (and from there to the built-in candidates).
    editor_font_family: []const u8 = "",
    /// Editor point size. 0 = follow this profile's `font_size`.
    editor_font_size: u16 = 0,

    // Pane presentation. Per-profile (not window-level) so a profile
    // can mark its panes visually — a red border on the `root` or
    // `prod` profile is the point. All lengths are framebuffer
    // pixels, the same unit as `padding`.
    /// Border drawn just inside the pane's own rectangle. 0 = none.
    pane_border_width: f32 = 2.0,
    /// Border colour while the pane has focus.
    pane_border_color_active: [4]f32 = .{ 0.40, 0.55, 0.85, 0.75 },
    /// Border colour while it does not. Alpha 0 (the default) draws
    /// nothing, which is what sketerm has always done.
    pane_border_color: [4]f32 = .{ 0, 0, 0, 0 },
    /// Corner rounding, applied as an alpha cut on the composited
    /// pane, so it reveals whatever is behind the GL area. Forces the
    /// post-process pass on when non-zero. 0 = square corners.
    pane_corner_radius: f32 = 0,

    /// The colour set that is in force for `scheme`, as a copy of
    /// these settings with the flat colour fields swapped out. Null
    /// scheme (= `auto_theme` off) returns the settings untouched, so
    /// a manual theme always renders exactly what the user wrote.
    ///
    /// Pure by design: the flat fields stay the configured base, so
    /// the serialiser and the prefs dialog keep reading and writing
    /// what the user actually put in the file rather than whatever
    /// half of the pair happened to be showing.
    pub fn forScheme(self: *const ProfileSettings, scheme: ?ColorScheme) ProfileSettings {
        const which = scheme orelse return self.*;
        const set = switch (which) {
            .light => builtin_light.overlay(self.light),
            .dark => builtin_dark.overlay(self.dark),
        };
        var out = self.*;
        if (set.default_fg) |v| out.default_fg = v;
        if (set.default_bg) |v| out.default_bg = v;
        if (set.cursor_color) |v| out.cursor_color = v;
        if (set.cursor_color_default) |v| out.cursor_color_default = v;
        if (set.palette) |v| out.palette = v;
        if (set.scheme) |v| out.scheme = v;
        return out;
    }

    /// The variant a `light.`/`dark.` write lands in.
    pub fn variantSet(self: *ProfileSettings, scheme: ColorScheme) *ColorSet {
        return switch (scheme) {
            .light => &self.light,
            .dark => &self.dark,
        };
    }

    /// The flat colour fields an editor (the prefs dialog) can bind a
    /// row to. Every one of them has a `ColorSet` counterpart.
    pub const VariantColor = enum { default_fg, default_bg, cursor_color };

    /// What a colour editor must DISPLAY for `field` under `scheme`:
    /// the variant's own override, else the built-in variant, else
    /// the flat base. Defined through `forScheme`, so the swatch can
    /// never show something other than what renders.
    pub fn variantColor(self: *const ProfileSettings, scheme: ?ColorScheme, field: VariantColor) [4]f32 {
        const eff = self.forScheme(scheme);
        return switch (field) {
            .default_fg => eff.default_fg,
            .default_bg => eff.default_bg,
            .cursor_color => eff.cursor_color,
        };
    }

    /// Where a colour editor WRITES: the variant under `scheme`, or
    /// the flat base when `scheme` is null (`auto_theme` off). Never
    /// the base while a variant is in force — the base is what the
    /// serialiser emits as the plain `default_bg`-style keys.
    pub fn setVariantColor(self: *ProfileSettings, scheme: ?ColorScheme, field: VariantColor, v: [4]f32) void {
        if (scheme) |sc| {
            const set = self.variantSet(sc);
            switch (field) {
                .default_fg => set.default_fg = v,
                .default_bg => set.default_bg = v,
                .cursor_color => set.cursor_color = v,
            }
            return;
        }
        switch (field) {
            .default_fg => self.default_fg = v,
            .default_bg => self.default_bg = v,
            .cursor_color => self.cursor_color = v,
        }
    }

    /// Effective `cursor_color_default` under `scheme`.
    pub fn variantCursorDefault(self: *const ProfileSettings, scheme: ?ColorScheme) bool {
        return self.forScheme(scheme).cursor_color_default;
    }

    pub fn setVariantCursorDefault(self: *ProfileSettings, scheme: ?ColorScheme, v: bool) void {
        if (scheme) |sc| {
            self.variantSet(sc).cursor_color_default = v;
        } else {
            self.cursor_color_default = v;
        }
    }

    /// Effective built-in scheme name under `scheme` ("" = none).
    pub fn variantSchemeName(self: *const ProfileSettings, scheme: ?ColorScheme) []const u8 {
        return self.forScheme(scheme).scheme;
    }

    /// Effective palette override under `scheme`. Null means no layer
    /// pins one, so the reader falls back to the scheme preset or the
    /// built-in 256-table.
    pub fn variantPalette(self: *const ProfileSettings, scheme: ?ColorScheme) ?[16][3]u8 {
        return self.forScheme(scheme).palette;
    }

    /// Pin an explicit palette in the `scheme` layer, cancelling that
    /// layer's built-in scheme so the hand-picked colours stick (the
    /// palette wins over `scheme` when both are set, but leaving a
    /// stale name behind would misreport what is in force).
    pub fn setVariantPalette(self: *ProfileSettings, scheme: ?ColorScheme, pal: [16][3]u8) void {
        if (scheme) |sc| {
            const set = self.variantSet(sc);
            set.palette = pal;
            set.scheme = "";
            return;
        }
        self.palette = pal;
        self.scheme = "";
    }

    /// Point the `scheme` layer at built-in scheme `key`, whose fg /
    /// bg / palette the caller has already looked up (the scheme
    /// table lives in `grid/schemes.zig`, which the daemon-side
    /// config must not depend on).
    pub fn setVariantScheme(
        self: *ProfileSettings,
        scheme: ?ColorScheme,
        key: []const u8,
        fg: [4]f32,
        bg: [4]f32,
        pal: [16][3]u8,
    ) void {
        if (scheme) |sc| {
            const set = self.variantSet(sc);
            set.scheme = key;
            set.default_fg = fg;
            set.default_bg = bg;
            set.palette = pal;
            return;
        }
        self.scheme = key;
        self.default_fg = fg;
        self.default_bg = bg;
        self.palette = pal;
    }

    /// Deep-copy every heap-backed field into `arena`.
    pub fn cloneInto(self: *const ProfileSettings, arena: std.mem.Allocator) error{OutOfMemory}!ProfileSettings {
        var out = self.*;
        if (self.font_path) |s| out.font_path = try arena.dupe(u8, s);
        out.font_family = try arena.dupe(u8, self.font_family);
        out.font_family_bold = try arena.dupe(u8, self.font_family_bold);
        out.font_family_italic = try arena.dupe(u8, self.font_family_italic);
        out.font_family_bold_italic = try arena.dupe(u8, self.font_family_bold_italic);
        out.editor_font_family = try arena.dupe(u8, self.editor_font_family);
        out.font_features = try arena.dupe(u8, self.font_features);
        out.scheme = try arena.dupe(u8, self.scheme);
        out.light = try self.light.cloneInto(arena);
        out.dark = try self.dark.cloneInto(arena);
        if (self.shell) |s| out.shell = try arena.dupe(u8, s);
        out.term_env = try arena.dupe(u8, self.term_env);
        out.color_term_env = try arena.dupe(u8, self.color_term_env);
        out.custom_shader = try arena.dupe(u8, self.custom_shader);
        return out;
    }
};

/// A named profile: a complete `ProfileSettings`. The Default
/// profile is NOT in `Config.profiles` — it is `Config.settings`;
/// the name "default" is reserved for it.
pub const Profile = struct {
    name: []const u8,
    settings: ProfileSettings = .{},
};

/// `[domain.<name>]` sections — named remote mux endpoints, so the
/// palette / `sketerm mux <name>` can offer "new tab on devbox"
/// without retyping hosts.
pub const DomainTransport = enum { auto, ssh, udp };

pub const Domain = struct {
    name: []const u8,
    /// SSH endpoint, "host" or "user@host". Empty = section ignored.
    host: []const u8 = "",
    /// Auto probes roaming UDP first and falls back to SSH.
    transport: DomainTransport = .auto,

    /// Allocate the transport-prefixed host string the durable-tab
    /// plumbing speaks (bare = auto, "udp:"/"ssh:" = forced).
    pub fn hostSpec(self: *const Domain, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return switch (self.transport) {
            .auto => allocator.dupe(u8, self.host),
            .ssh => std.fmt.allocPrint(allocator, "ssh:{s}", .{self.host}),
            .udp => std.fmt.allocPrint(allocator, "udp:{s}", .{self.host}),
        };
    }
};

/// `[mcp.<name>]` sections — named MCP tool-exposure policies, so the
/// same spec can be reused by several assistants via
/// `sketerm mcp --profile <name>`.
///
/// The section namespace is `mcp.`, NOT `profile.`: `[profile.<name>]`
/// already means a pane ProfileSettings bundle, and the two have
/// nothing in common beyond the word.
pub const McpProfile = struct {
    name: []const u8,
    /// Tool exposure spec — the grammar lives in src/ipc/mcpfilter.zig.
    /// Empty = every tool (this module never validates it: config.zig
    /// is compiled into sketerm-mux and must not depend on the MCP
    /// tool table; `sketerm mcp` validates at startup).
    tools: []const u8 = "",
};

/// The operating systems a `[platform.<name>]` section can name.
/// Comptime only: the current platform is decided from
/// `builtin.os.tag` the same way `src/util/platform.zig` does it, so
/// the non-matching branches are dead code rather than a runtime
/// probe (and `sketerm-mux` cross-compiled for macOS reads a config
/// as macOS even when the file was written on Linux).
pub const Platform = enum {
    linux,
    macos,

    /// Null on a target that is neither — every platform section is
    /// then validated and retained, and none of them applies.
    pub const current: ?Platform = switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        else => null,
    };

    pub fn matchesCurrent(name: []const u8) bool {
        const cur = current orelse return false;
        return std.mem.eql(u8, name, @tagName(cur));
    }
};

/// One `key = value` line of a `[platform.<name>]` section, kept
/// verbatim so the serialiser can write the section back byte for
/// byte — including sections for a platform this build is not.
pub const RawKv = struct {
    key: []const u8,
    value: []const u8,
};

/// One `[platform.<name>]` section. Its lines are applied inline, in
/// file order, when `name` is this build's platform; the record is
/// retained either way so a save never drops another machine's
/// settings.
pub const PlatformSection = struct {
    name: []const u8,
    lines: std.ArrayList(RawKv) = .empty,
};

/// When to ask "are you sure?" before destroying panes / tabs.
/// Matches Terminator's `ask_before_closing` semantics:
///   never    — close immediately, no dialog
///   multiple — only ask when there's >1 pane in the closing target
///   always   — ask on every close
pub const ConfirmClose = enum { never, multiple, always };

/// Overlay-scrollbar visibility. `auto` is "only when there is
/// scrollback to reach"; there is no timed fade.
pub const ScrollbarMode = enum { never, auto, always };

/// Monitor edge a quake window is meant to drop from.
pub const QuakeEdge = enum { top, bottom, left, right };

/// File-browser listing view modes (mirrors filebrowser/model.zig's
/// ViewMode; config keeps its own enum so the parser has no UI dep).
pub const FilesView = enum { details, compact, icons, miller };

/// One `shader_param.<name>` override. Defined here (not in the
/// render graph) so the mux side can import config.zig; the shader
/// passes import it FROM config.
pub const ParamKV = struct {
    name: []const u8,
    value: f32 = 0,
    color: ?[3]f32 = null,
};

pub const Config = struct {
    /// The Default profile — every pane-level setting (font, colors,
    /// shell, scrollback, shader). Named profiles in `profiles` are
    /// complete alternatives to this bundle, selected per pane.
    settings: ProfileSettings = .{},

    // Cursor
    cursor_shape: CursorShape = .block,
    cursor_blink: bool = true,
    /// Cursor blink interval in milliseconds. Each interval is one
    /// half-cycle (on→off OR off→on). 500 = full blink every 1000ms.
    cursor_blink_ms: u32 = 500,
    /// Animated trail that stretches from the cursor's old cell to
    /// its new one. App-level, like shape and blink, because the
    /// cost is a property of the machine (a 60 Hz redraw runs for
    /// the length of each jump) rather than of a colour scheme; the
    /// trail is drawn in whatever the active profile's cursor colour
    /// is. Off by default — nothing should silently start animating
    /// on a laptop.
    cursor_trail: bool = false,
    /// How long one trail takes to catch up, in milliseconds. This
    /// is a hard deadline, not just a time constant: the trail is
    /// always gone this long after the cursor last moved.
    cursor_trail_ms: u32 = 300,

    // Layout
    /// Snap view back to the bottom on any output, not just on
    /// keystroke. Off by default — matches xterm; users who want
    /// the gnome-terminal "auto-tail" behaviour flip this.
    scroll_on_output: bool = false,

    /// Show a per-tab activity indicator when a background tab's visible
    /// output actually changes. The signal is computed in the event
    /// drain (so it works for unfocused tabs); off skips that work.
    track_tab_activity: bool = true,

    /// Seconds of silence (no visible change in any pane) after the last
    /// activity before a tab's per-tab inactivity warning fires. The toggle
    /// itself is per-tab (right-click a tab); this is the shared threshold.
    inactive_warn_secs: u32 = 60,
    /// Seconds a tab must stay selected before viewing it acknowledges (and
    /// clears) its inactivity warning. Guards against a quick scroll across
    /// the tab bar wiping every warning. 0 = acknowledge immediately.
    tab_ack_delay_secs: f32 = 1.0,

    /// Per-pane cap on retained decoded-image memory (MiB). A program that
    /// emits a stream of graphics (sixel/iTerm/kitty redraw loops) would
    /// otherwise grow the image store without bound and the kernel OOM-kills
    /// the whole session. Past the cap the oldest images are evicted FIFO.
    /// 0 = unlimited (the old, unsafe behaviour).
    image_memory_mb: u32 = 320,

    /// Name of a GTK theme to load (its `gtk-4.0/gtk.css` from
    /// `~/.themes`, `~/.local/share/themes`, or the system theme dirs),
    /// applied over libadwaita's stylesheet. Empty = honor the session's
    /// GTK_THEME / active theme. Lets you style sketerm (e.g. its tabs)
    /// with your desktop theme even though libadwaita ships its own.
    gtk_theme: []const u8 = "",

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
    /// xkb layout for forwarded-app session keyboards (us, gb, fr,
    /// be, de — wlhost/keymaps.zig). Set this to YOUR physical
    /// layout: your keystrokes pass through as raw keycodes, and the
    /// app decodes them with this keymap. Empty = us.
    app_keyboard_layout: []const u8 = "",
    /// Default view for forwarded-app sessions (see AppView).
    app_view: AppView = .window,
    /// GtkIMContext strategy for every keyboard face (see InputMethod).
    /// Applies to faces created after the change.
    input_method: InputMethod = .auto,
    /// Comma-separated app names the launcher always starts with GPU
    /// rendering (linux-dmabuf instead of software GL) — matched
    /// case-insensitively against the .desktop Name or the Exec
    /// binary's basename, e.g. "Blender, mpv". Empty = none.
    gpu_apps: []const u8 = "",
    /// UDP port range "lo:hi" passed to the remote `--udp-listen`
    /// bootstrap (mosh-style; firewalls usually need a pinned range
    /// like "60000:61000"). Empty = ephemeral port.
    mux_udp_port_range: []const u8 = "",
    /// Smart copy: when no selection is active, Ctrl+Shift+C
    /// forwards as Ctrl+C (interrupt) instead of being a no-op.
    smart_copy: bool = true,
    /// Watch config.conf and apply it the moment it changes on disk,
    /// without the `reload_config` keybind. Off falls back to the
    /// keybind and SIGUSR1. An auto reload never writes the file back,
    /// so hand-written comments and ordering survive.
    config_auto_reload: bool = true,

    // Rendering
    ligatures: bool = true,
    /// GtkGraphicsOffload for pane GL content (Wayland subsurface +
    /// dmabuf scanout fast path). Disable to force GSK compositing —
    /// escape hatch for compositor/GTK subsurface bugs (a KWin/GTK
    /// frame-callback object-id leak crashed long sessions).
    graphics_offload: bool = true,
    /// Bidirectional text reorder via fribidi. Only affects lines
    /// containing non-ASCII codepoints; pure-ASCII lines skip it.
    bidi: bool = true,
    /// If true, fg/bg follow AdwStyleManager dark/light. Set to
    /// false to honour `default_fg` / `default_bg` exactly.
    auto_theme: bool = true,
    /// Bell behaviour: visual flash, system beep, and / or marking
    /// the AdwTabPage as needs-attention. Independent toggles.
    /// Auto shell-integration: inject the OSC 7/133 scripts into
    /// zsh/fish/bash at spawn (ZDOTDIR / XDG_DATA_DIRS shims; bash
    /// via --rcfile, bare interactive spawns only) — command blocks,
    /// cwd inheritance and prompt nav work without rc edits.
    shell_integration: bool = true,
    bell_audible: bool = false,
    bell_visible: bool = true,
    bell_urgent: bool = true,
    /// Desktop-notify when a command in a non-visible pane finishes
    /// after at least this many seconds (0 = off). Needs OSC 133
    /// shell integration.
    notify_command_secs: u32 = 15,

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

    // File browser
    /// Default view mode for new browser tabs (per-folder view memory
    /// still wins for folders the user has adjusted).
    files_default_view: FilesView = .details,
    /// New browser tabs start with hidden files shown.
    files_show_hidden: bool = false,
    /// Ask before a permanent delete (Shift+Delete / the menu verb).
    files_confirm_delete: bool = true,
    /// Hash-compare every copied file against its source before the
    /// copy installs (same-host daemon copy jobs).
    files_verify_copy: bool = false,

    // Text editor. These are EDITING BEHAVIOUR, not pane appearance:
    // the same person wants the same indentation and the same wrap
    // default in every window, and a document opened from the browser
    // must not indent differently because the pane it landed in wears
    // another profile. (The editor FONT is per-profile — see
    // ProfileSettings.editor_font_*.)
    /// Columns one Tab advances (and one Backspace-over-indent
    /// retreats).
    editor_tab_width: u16 = 4,
    /// Tab inserts spaces to the next stop. False inserts a real \t.
    editor_insert_spaces: bool = true,
    /// New editor tabs start with soft wrap on (per-tab from there).
    editor_soft_wrap: bool = false,
    /// Soft wrap prefers UAX #14 word/line-break opportunities; false
    /// wraps at any grapheme (denser, useful for logs/minified text).
    /// An unbreakable token wider than the view wraps mid-token either
    /// way.
    editor_wrap_words: bool = true,
    /// Show the line-number gutter.
    editor_line_numbers: bool = true,
    /// Subtle band behind the caret's visual row (single caret only).
    editor_highlight_current_line: bool = true,
    /// Tree-sitter syntax highlighting (src/editor/syntax.zig). Off
    /// renders every document as plain text in the theme's foreground.
    editor_syntax: bool = true,
    /// Box the bracket pair around the caret. App level, like every
    /// other editor view flag.
    editor_bracket_match: bool = true,
    /// Code folding: gutter fold column, chevrons and the fold actions.
    editor_folding: bool = true,
    /// Derive fold regions from INDENTATION for files with no grammar.
    /// Off means such files simply have no folds.
    editor_fold_indent_fallback: bool = true,
    /// Colour theme name — see `editor/theme.zig`'s `byName`, which
    /// falls back to "dark" for anything it does not know.
    editor_theme: []const u8 = "dark",
    /// Snapshot unsaved editor buffers to
    /// `$XDG_STATE_HOME/sketerm/editor-recovery.d` so a crash can offer
    /// them back (`editor/journal.zig`). Off writes nothing and offers
    /// nothing; records already on disk are left alone.
    editor_crash_recovery: bool = true,
    /// Master switch for the editor's language-server client
    /// (src/lsp/). Off means no server is ever spawned; every LSP
    /// feature reports "no language server" when asked for explicitly
    /// and is otherwise invisible.
    ///
    /// App level rather than per-profile: a language server serves a
    /// LANGUAGE, and which pane profile the document happens to be open
    /// under says nothing about that.
    editor_lsp: bool = true,
    /// Squiggles + gutter markers for server diagnostics. Off keeps
    /// the rest of LSP (completion, hover, navigation) working.
    editor_lsp_diagnostics: bool = true,
    /// How long the editor waits after the last keystroke before
    /// flushing `textDocument/didChange`. A feature request (completion,
    /// hover, go-to-definition) always flushes FIRST regardless, so this
    /// only trades server CPU against how fresh diagnostics feel.
    editor_lsp_debounce_ms: u16 = 250,
    /// Inline type / parameter-name annotations from the server
    /// (`textDocument/inlayHint`), requested for the visible viewport
    /// only. Display-only: they never enter the document and never move
    /// a byte offset.
    editor_lsp_inlay_hints: bool = true,
    /// Server-computed token colours (`textDocument/semanticTokens`)
    /// layered ON TOP of the Tree-sitter highlighting — the server wins
    /// where it speaks, the grammar keeps everything else.
    editor_lsp_semantic_tokens: bool = true,
    /// Signature help while typing a call, on the server's trigger
    /// characters and on Ctrl+Shift+Space.
    editor_lsp_signature_help: bool = true,
    /// How long the pointer has to sit still over a symbol before a
    /// hover is requested for it. 0 disables mouse-dwell hover
    /// entirely; Ctrl+I is unaffected either way.
    editor_lsp_hover_delay_ms: u16 = 500,
    /// Comma-separated marker filenames that identify a PROJECT root
    /// (`editor/project.zig`). Empty = the built-in list (every VCS
    /// directory plus the usual language markers). A file with no
    /// marker above it has no project, and the project-scoped features
    /// (project search, the git gutter, the project label) stay off for
    /// it.
    ///
    /// App level, like `editor_lsp`: a project is a property of the
    /// filesystem, not of the pane profile the file happens to be open
    /// under.
    editor_project_markers: []const u8 = "",
    /// Per-line added/modified/deleted markers in the gutter, computed
    /// against HEAD on the file's own host. Off costs nothing at all —
    /// no daemon job is started.
    editor_git_gutter: bool = true,
    /// Open the symbol outline panel with every editor face. Off (the
    /// default) still lets Ctrl+Shift+O open it per face.
    editor_outline: bool = false,
    /// Cap on files a project-wide search will READ. The daemon's grep
    /// narrows the candidates first; this bounds the pathological case
    /// (a regex with no literal part, which cannot be pre-filtered).
    editor_project_search_max_files: u32 = 4000,
    /// Enter deepens the indent after an opening bracket (and drops a
    /// pending closer onto its own line). Off copies the previous
    /// line's leading whitespace only.
    editor_auto_indent: bool = true,
    /// Typing an opening bracket/quote inserts its closer (typing the
    /// closer when it is next just moves past it; Backspace between an
    /// empty pair deletes both). Wrapping a selection surrounds it.
    editor_auto_close_pairs: bool = true,
    /// Backspace in a line's leading spaces retreats one tab stop.
    editor_smart_backspace: bool = true,
    /// Editor-face keybind overrides, parsed from
    /// `editor_keybind.<command> = <accel>` lines. Command names are
    /// `editor/commands.zig`'s `Command` tags; empty accel unbinds.
    /// Kept apart from `keybinds` so an editor chord can never shadow
    /// (or be consumed by) the terminal's binding table.
    editor_keybinds: std.ArrayList(KeybindEntry) = .empty,

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
    /// Middle-click action (mouse-report mode off). `menu` is not
    /// meaningful here and acts like `none`. `disable_mouse_paste`
    /// is the legacy kill-switch and still wins when set.
    mouse_middle_click: MouseAction = .paste_primary,
    /// Right-click action. `menu` = context menu (default, PuTTY
    /// users want paste_clipboard here).
    mouse_right_click: MouseAction = .menu,
    /// Allow apps to READ the clipboard via OSC 52 query. Off by
    /// default — any program on the PTY (incl. remote ones over ssh)
    /// could exfiltrate clipboard contents. Accepts allow/deny.
    clipboard_read: bool = false,
    /// Editor command for activating a path hint whose file exists:
    /// either a template with {file}/{line}/{col} placeholders
    /// ("code -g {file}:{line}") or a bare command that takes
    /// `+line file` ("nvim"). Empty = $EDITOR/$VISUAL, falling back
    /// to copy-to-clipboard when neither is set.
    hint_editor: []const u8 = "",
    /// Label alphabet for hint mode, in the order labels are handed
    /// out. Empty = the built-in home-row-first set. Duplicate or
    /// non-printable characters make the setting be ignored.
    hint_alphabet: []const u8 = "",
    /// Start hint mode in multi-select: each label appends its match
    /// instead of activating and closing. Toggleable in-mode with Tab
    /// either way.
    hint_multiple: bool = false,
    /// User-defined hint rules from `hint.<name>.*` lines, in file
    /// order. They are scanned BEFORE the built-in URL/path/hash
    /// scanners, so a rule can claim text those would have taken.
    hint_rules: std.ArrayList(HintRule) = .empty,
    /// Codepoint ranges routed to specific font families, from
    /// `symbol_map.<name>` lines. App-level rather than per-profile:
    /// this is about glyph coverage, which does not sensibly differ
    /// between two panes of the same session.
    symbol_maps: std.ArrayList(SymbolMap) = .empty,

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
    /// Uniform darken applied to the FINAL composited image of an
    /// unfocused pane (post-process, so every fg/bg colour relation is
    /// preserved — just dimmer). 0 = no dim; 1 = black. Default 0.2.
    inactive_darken: f32 = 0.2,
    /// Optional desaturation of an unfocused pane, blending toward
    /// luma. 0 = full colour (default); 1 = grayscale. Combines with
    /// `inactive_darken`.
    inactive_desaturate: f32 = 0.0,

    // Overlay scrollbar (drawn by GridPass inside the pane, not a
    // widget). Window-level: it is chrome, and a pane whose scrollbar
    // came and went with its profile would be a usability trap.
    /// never = not drawn and not interactive; auto = drawn once the
    /// pane has scrollback; always = drawn even with none (the thumb
    /// then fills the track). There is no timed fade-out.
    scrollbar: ScrollbarMode = .auto,
    /// Track/thumb width in framebuffer pixels. 0 also disables it.
    scrollbar_width: f32 = 4.0,
    scrollbar_trough_color: [4]f32 = .{ 0.5, 0.5, 0.5, 0.18 },
    /// Thumb while the view sits at the live bottom.
    scrollbar_thumb_color: [4]f32 = .{ 0.5, 0.5, 0.5, 0.30 },
    /// Thumb while scrolled back.
    scrollbar_thumb_active_color: [4]f32 = .{ 0.40, 0.55, 0.85, 0.70 },

    // Split separators. Window-level: one CSS provider styles every
    // GtkPaned in the window, and a gap is a property of the space
    // BETWEEN two panes, which no single profile owns.
    /// Thickness of the GtkPaned separator in logical pixels — the
    /// visible gap between two panes. Keep it a multiple of 4: at
    /// fractional surface scales an odd separator pushes one pane off
    /// the device-pixel grid and GtkGraphicsOffload rejects every
    /// frame. Clamped to 1..64 (0 would make the divider undraggable).
    pane_gap: f32 = 4.0,
    /// Separator colour — what shows through the gap.
    pane_gap_color: [4]f32 = .{ 0x35.0 / 255.0, 0x35.0 / 255.0, 0x35.0 / 255.0, 1.0 },

    // Quake mode (`sketerm --toggle`). Off by default: with it on,
    // the primary window is sized from the monitor instead of the
    // 1000x700 default.
    /// Apply the quake geometry below to the primary window.
    quake_enabled: bool = false,
    /// Which monitor to drop onto: "active" (the one the window is
    /// on), "primary", a 0-based index, or a connector name ("DP-1").
    /// Empty = "active". GTK4 has no primary-monitor concept, so
    /// "primary" resolves to the display's first monitor.
    quake_monitor: []const u8 = "",
    /// Which edge the window drops from. ADVISORY ONLY: GTK4 removed
    /// toplevel positioning on every backend and Wayland forbids it
    /// outright, so nothing sketerm can call moves the window to an
    /// edge. Recorded so a compositor window rule (or a future
    /// layer-shell backend) can consume it; it moves nothing itself.
    quake_edge: QuakeEdge = .top,
    /// Coverage of the target monitor, in percent (1..100).
    quake_width_percent: f32 = 100.0,
    quake_height_percent: f32 = 50.0,

    /// Minimum WCAG contrast ratio between text and its cell
    /// background, 1.0 (off) .. 21.0. Text falling below the
    /// threshold snaps to white or black, whichever reads better.
    /// Kitty calls this text_fg_override_threshold; ghostty
    /// minimum-contrast.
    minimum_contrast: f32 = 1.0,

    /// Colour space glyph coverage is blended in (see TextBlending).
    /// App-level, like every other rendering flag: it changes the GL
    /// target every pane in the window draws into, and a per-profile
    /// value would mean two framebuffer formats in one share group.
    ///
    /// DEFAULT DELIBERATELY `native`: anything else changes how every
    /// glyph looks on upgrade. Flipping this one line to
    /// `.linear_corrected` is the intended way to change that.
    text_blending: TextBlending = .native,

    /// Background image (absolute path, PNG/JPEG via stb). Empty =
    /// off. Drawn cover-cropped behind the cell grid; wins over the
    /// gradient when both are set.
    background_image: []const u8 = "",
    /// Layer alpha for the background image. Keep low — text on
    /// default bg sits directly on the image.
    background_image_opacity: f32 = 0.3,
    /// Two-colour background gradient; active when BOTH colours have
    /// alpha > 0 (the zeroed default means off).
    background_gradient_from: [4]f32 = .{ 0, 0, 0, 0 },
    background_gradient_to: [4]f32 = .{ 0, 0, 0, 0 },
    /// Gradient direction in degrees: 0 = left→right, 90 = top→bottom.
    background_gradient_angle: f32 = 90,

    /// Redraw continuously so iTime advances (CRT flicker, glow…).
    /// Off = the shader still runs but only on normal damage.
    /// Applies to whichever custom shader a pane resolves to.
    custom_shader_animation: bool = false,

    /// Custom keybindings. List of (action_name, accelerator) pairs
    /// parsed from `keybind.<action> = <accel>` lines. An entry with
    /// an empty accel unbinds that action; a missing entry inherits
    /// the default. Round-trip-stable.
    keybinds: std.ArrayList(KeybindEntry) = .empty,

    /// `shader_param.<name> = <float>` overrides for the tunable
    /// uniforms custom shaders declare via `//@param` lines (glow,
    /// vignette, curvature, …). Uploaded every frame — a reload
    /// re-tunes live without recompiling.
    shader_params: std.ArrayList(ParamKV) = .empty,

    /// Named profiles. Defined via `[profile.<name>]` sections —
    /// each is a COMPLETE ProfileSettings (seeded from the Default
    /// settings parsed so far, then overridden by the section's
    /// keys). Order preserved for round-trip serialisation + UI
    /// listing. "default" is reserved: that section edits
    /// `Config.settings` directly and never lands in this list.
    profiles: std.ArrayList(Profile) = .empty,
    /// Profile name new panes spawn with when none is requested.
    /// Empty (or "default") = the Default settings.
    default_profile: []const u8 = "",

    /// Named mux domains from `[domain.<name>]` sections. Order
    /// preserved for round-trip serialisation + UI listing.
    domains: std.ArrayList(Domain) = .empty,

    /// Language servers from `[lsp.<name>]` sections. A section whose
    /// name matches a built-in (src/lsp/servers.zig) REPLACES it
    /// wholesale — it is seeded from the built-in at parse time, so a
    /// section carrying only `enabled = false` still knows the command
    /// it is switching off, and one carrying only `args` keeps the
    /// built-in's languages and root markers.
    lsp_servers: std.ArrayList(LspServer) = .empty,

    /// Named MCP tool-exposure policies from `[mcp.<name>]` sections,
    /// selected with `sketerm mcp --profile <name>`. Order preserved
    /// for round-trip serialisation.
    mcp_profiles: std.ArrayList(McpProfile) = .empty,

    /// `[platform.<name>]` sections, in file order, with their lines
    /// verbatim. The section for THIS platform has already been
    /// applied (inline, where it appeared) — the record is kept only
    /// so the serialiser can write every section back, including the
    /// ones belonging to another machine. Read `platformOverridesKey`
    /// before assuming a base key survived a save unchanged.
    platform_sections: std.ArrayList(PlatformSection) = .empty,

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

    // Title templates (src/util/titlefmt.zig). App-level, not
    // per-profile: a tab strip mixing two title FORMATS reads as a
    // bug, and the window title has no profile to belong to.
    /// Tab label format. The default is the historical behaviour —
    /// the OSC 0/2 title verbatim — so upgrading changes nothing.
    tab_title_template: []const u8 = default_tab_title,
    /// Window title format. Empty (the default) keeps the window
    /// title fixed at the application name, which is what sketerm has
    /// always done; set it to make the window follow its focused pane.
    window_title_template: []const u8 = "",

    // Owned strings allocated from the parser arena. Not freed
    // individually — `arena.deinit()` reaps everything.
    arena: ?std.heap.ArenaAllocator = null,

    pub fn deinit(self: *Config) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
    }

    /// `mux_udp_port_range` in the optional-slice form the transport
    /// connectors take (null = no pinned range).
    pub fn udpRange(self: *const Config) ?[]const u8 {
        return if (self.mux_udp_port_range.len > 0) self.mux_udp_port_range else null;
    }

    /// Deep-copy every heap-backed field (strings, keybinds, profiles)
    /// into `arena`. The returned copy carries NO arena of its own —
    /// the caller's arena owns the memory. Use this to decouple a
    /// Config copy from the source's lifetime; a plain struct copy
    /// aliases the source arena and dangles when it is freed.
    pub fn cloneInto(self: *const Config, arena: std.mem.Allocator) error{OutOfMemory}!Config {
        var out = self.*;
        out.arena = null;
        out.settings = try self.settings.cloneInto(arena);
        out.hint_editor = try arena.dupe(u8, self.hint_editor);
        out.quake_monitor = try arena.dupe(u8, self.quake_monitor);
        out.hint_alphabet = try arena.dupe(u8, self.hint_alphabet);
        out.hint_rules = .empty;
        try out.hint_rules.ensureTotalCapacity(arena, self.hint_rules.items.len);
        for (self.hint_rules.items) |hr| {
            out.hint_rules.appendAssumeCapacity(.{
                .name = try arena.dupe(u8, hr.name),
                .pattern = try arena.dupe(u8, hr.pattern),
                .action = hr.action,
                .command = try arena.dupe(u8, hr.command),
            });
        }
        out.symbol_maps = .empty;
        try out.symbol_maps.ensureTotalCapacity(arena, self.symbol_maps.items.len);
        for (self.symbol_maps.items) |sm| {
            out.symbol_maps.appendAssumeCapacity(.{
                .name = try arena.dupe(u8, sm.name),
                .lo = sm.lo,
                .hi = sm.hi,
                .family = try arena.dupe(u8, sm.family),
            });
        }
        out.background_image = try arena.dupe(u8, self.background_image);
        out.word_chars = try arena.dupe(u8, self.word_chars);
        out.gtk_theme = try arena.dupe(u8, self.gtk_theme);
        out.app_keyboard_layout = try arena.dupe(u8, self.app_keyboard_layout);
        out.gpu_apps = try arena.dupe(u8, self.gpu_apps);
        out.mux_udp_port_range = try arena.dupe(u8, self.mux_udp_port_range);
        out.default_profile = try arena.dupe(u8, self.default_profile);
        out.editor_theme = try arena.dupe(u8, self.editor_theme);
        out.editor_project_markers = try arena.dupe(u8, self.editor_project_markers);
        out.tab_title_template = try arena.dupe(u8, self.tab_title_template);
        out.window_title_template = try arena.dupe(u8, self.window_title_template);
        out.keybinds = .empty;
        try out.keybinds.ensureTotalCapacity(arena, self.keybinds.items.len);
        for (self.keybinds.items) |kb| {
            out.keybinds.appendAssumeCapacity(.{
                .name = try arena.dupe(u8, kb.name),
                .accel = try arena.dupe(u8, kb.accel),
            });
        }
        out.editor_keybinds = .empty;
        try out.editor_keybinds.ensureTotalCapacity(arena, self.editor_keybinds.items.len);
        for (self.editor_keybinds.items) |kb| {
            out.editor_keybinds.appendAssumeCapacity(.{
                .name = try arena.dupe(u8, kb.name),
                .accel = try arena.dupe(u8, kb.accel),
            });
        }
        out.shader_params = .empty;
        try out.shader_params.ensureTotalCapacity(arena, self.shader_params.items.len);
        for (self.shader_params.items) |sp| {
            out.shader_params.appendAssumeCapacity(.{
                .name = try arena.dupe(u8, sp.name),
                .value = sp.value,
                .color = sp.color,
            });
        }
        out.profiles = .empty;
        try out.profiles.ensureTotalCapacity(arena, self.profiles.items.len);
        for (self.profiles.items) |p| {
            out.profiles.appendAssumeCapacity(.{
                .name = try arena.dupe(u8, p.name),
                .settings = try p.settings.cloneInto(arena),
            });
        }
        out.domains = .empty;
        try out.domains.ensureTotalCapacity(arena, self.domains.items.len);
        for (self.domains.items) |d| {
            var cd = d;
            cd.name = try arena.dupe(u8, d.name);
            cd.host = try arena.dupe(u8, d.host);
            out.domains.appendAssumeCapacity(cd);
        }
        out.lsp_servers = .empty;
        try out.lsp_servers.ensureTotalCapacity(arena, self.lsp_servers.items.len);
        for (self.lsp_servers.items) |s| {
            out.lsp_servers.appendAssumeCapacity(.{
                .name = try arena.dupe(u8, s.name),
                .languages = try arena.dupe(u8, s.languages),
                .command = try arena.dupe(u8, s.command),
                .args = try arena.dupe(u8, s.args),
                .root_files = try arena.dupe(u8, s.root_files),
                .init_options = try arena.dupe(u8, s.init_options),
                .enabled = s.enabled,
            });
        }
        out.platform_sections = .empty;
        try out.platform_sections.ensureTotalCapacity(arena, self.platform_sections.items.len);
        for (self.platform_sections.items) |sec| {
            var copy = PlatformSection{ .name = try arena.dupe(u8, sec.name) };
            try copy.lines.ensureTotalCapacity(arena, sec.lines.items.len);
            for (sec.lines.items) |kv| {
                copy.lines.appendAssumeCapacity(.{
                    .key = try arena.dupe(u8, kv.key),
                    .value = try arena.dupe(u8, kv.value),
                });
            }
            out.platform_sections.appendAssumeCapacity(copy);
        }
        return out;
    }

    /// Deep-copy into a fresh self-owned arena backed by `allocator`.
    pub fn clone(self: *const Config, allocator: std.mem.Allocator) error{OutOfMemory}!Config {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var out = try self.cloneInto(arena.allocator());
        out.arena = arena;
        return out;
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
        const resolved: ?[]u8 = if (override_path) |p|
            allocator.dupe(u8, p) catch null
        else
            resolveConfigPath(allocator);
        if (resolved) |path| {
            defer allocator.free(path);
            if (loadFromPath(allocator, path)) |cfg| {
                return cfg;
            } else |err| switch (err) {
                error.PathTooLong => warnConfig("config path too long: {s}", .{path}),
                error.NotReadable => if (override_path != null) {
                    warnConfig("--config path {s} not readable, using defaults", .{path});
                },
            }
        }
        var cfg = Config{};
        applyEnvOverrides(&cfg, allocator);
        return cfg;
    }

    /// Read and parse one config file, env overrides included.
    ///
    /// Unlike `loadWithOverride` an unreadable file is an ERROR, not
    /// "use defaults": a LIVE reload (the `reload_config` action, the
    /// file watcher) that raced an editor's rename would otherwise
    /// silently reset every setting the user has.
    pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !Config {
        // Zig 0.16's `std.fs` requires an `Io` instance we don't
        // thread through here. Just use libc — we link it anyway.
        const c = @import("c.zig").c;
        // path is caller-owned and not necessarily NUL-terminated;
        // copy onto a stack buffer with a trailing 0.
        var path_z: [4096]u8 = undefined;
        if (path.len >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        const fp = c.fopen(@ptrCast(&path_z), "rb") orelse return error.NotReadable;
        defer _ = c.fclose(fp);
        const max_bytes: usize = 64 * 1024;
        var buf: [max_bytes]u8 = undefined;
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == buf.len and c.feof(fp) == 0) {
            warnConfig("{s} larger than 64 KiB; trailing settings ignored", .{path});
        }
        var cfg = try loadFromBytes(allocator, buf[0..n]);
        applyEnvOverrides(&cfg, allocator);
        return cfg;
    }

    /// Env overrides — highest priority, beating the file. Applied to
    /// the Default settings only; named profiles keep their own values.
    fn applyEnvOverrides(cfg: *Config, allocator: std.mem.Allocator) void {
        if (@import("util/profile.zig").getenv("SKETERM_SCROLLBACK")) |env| {
            if (std.fmt.parseInt(u32, env, 10)) |n| cfg.settings.scrollback = n else |_| {}
        }
        if (@import("util/profile.zig").getenv("SKETERM_FONT")) |env_path| {
            if (cfg.arena == null) cfg.arena = std.heap.ArenaAllocator.init(allocator);
            const arena = cfg.arena.?.allocator();
            cfg.settings.font_path = arena.dupe(u8, env_path) catch cfg.settings.font_path;
        }
    }

    pub fn loadFromBytes(allocator: std.mem.Allocator, body: []const u8) !Config {
        var cfg = Config{ .arena = std.heap.ArenaAllocator.init(allocator) };
        errdefer cfg.deinit();
        try parseInto(&cfg, body);
        return cfg;
    }

    /// Atomic write to `path`: serialise every key whose value differs
    /// from the schema default (so the file stays minimal). On disk
    /// the format round-trips through `loadFromBytes` exactly. Uses
    /// libc since Zig 0.16's `std.fs` now needs an `Io` instance we
    /// don't thread through here.
    /// Whether the `[platform.<this platform>]` section sets `key`.
    ///
    /// This is the one place the platform feature is lossy, and it is
    /// worth knowing about: the section is applied INLINE at parse
    /// time, so by the time anything reads a Config there is no
    /// difference between "the user wrote `font_size = 16` at top
    /// level" and "`[platform.macos]` set it". A save therefore writes
    /// the effective value at top level as well, and the other
    /// platform's default for that key becomes this platform's value
    /// unless its own section says otherwise. Undoing that would mean
    /// per-key provenance through all ~150 serialiser branches; the
    /// sections themselves survive verbatim, which is the part that
    /// would actually be data loss.
    pub fn platformOverridesKey(self: *const Config, key: []const u8) bool {
        for (self.platform_sections.items) |sec| {
            if (!Platform.matchesCurrent(sec.name)) continue;
            for (sec.lines.items) |kv| {
                if (std.mem.eql(u8, kv.key, key)) return true;
            }
        }
        return false;
    }

    /// Whether this config carries any `[platform.<name>]` section —
    /// what a UI checks before warning that a save flattens the
    /// current platform's overrides into the top level.
    pub fn hasPlatformSections(self: *const Config) bool {
        return self.platform_sections.items.len > 0;
    }

    pub fn save(self: *const Config, path: []const u8) !void {
        const c = @import("c.zig").c;
        try makeParentDirs(path);
        if (self.hasPlatformSections()) {
            warnConfig(
                "saving a config with [platform.*] sections: the sections are kept verbatim, but this platform's overrides are also written at top level (see docs/config.md)",
                .{},
            );
        }

        var path_z: [4096]u8 = undefined;
        if (path.len + 4 >= path_z.len) return error.PathTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        var tmp_z: [4096]u8 = undefined;
        @memcpy(tmp_z[0..path.len], path);
        @memcpy(tmp_z[path.len .. path.len + 4], ".tmp");
        tmp_z[path.len + 4] = 0;

        const fp = c.fopen(@ptrCast(&tmp_z), "wb") orelse return error.WriteFailed;
        var write_buf: [16384]u8 = undefined;
        var w = std.Io.Writer.fixed(&write_buf);
        self.serialise(&w) catch |err| {
            _ = c.fclose(fp);
            return err;
        };
        const bytes = w.buffered();
        if (c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len) {
            _ = c.fclose(fp);
            return error.WriteFailed;
        }
        if (c.fclose(fp) != 0) return error.WriteFailed;
        if (c.rename(@ptrCast(&tmp_z), @ptrCast(&path_z)) != 0) {
            _ = c.unlink(@ptrCast(&tmp_z));
            return error.WriteFailed;
        }
    }

    /// Same content as save() but directly into a Writer — used by
    /// tests + the prefs dialog's preview path.
    /// Emit every pane-level key of `s` that differs from `base`.
    /// Top-level (Default) settings diff against the schema defaults;
    /// profile sections diff against the Default settings — so a
    /// profile section only carries what makes it different.
    fn serialiseSettings(s: *const ProfileSettings, base: *const ProfileSettings, w: *std.Io.Writer) !void {
        // Font.
        if (!eqOptStr(s.font_path, base.font_path)) {
            if (s.font_path) |fp| try w.print("font = {s}\n", .{fp});
        }
        if (!std.mem.eql(u8, s.font_family, base.font_family))
            try w.print("font_family = {s}\n", .{s.font_family});
        if (!std.mem.eql(u8, s.font_family_bold, base.font_family_bold))
            try w.print("font_family_bold = {s}\n", .{s.font_family_bold});
        if (!std.mem.eql(u8, s.font_family_italic, base.font_family_italic))
            try w.print("font_family_italic = {s}\n", .{s.font_family_italic});
        if (!std.mem.eql(u8, s.font_family_bold_italic, base.font_family_bold_italic))
            try w.print("font_family_bold_italic = {s}\n", .{s.font_family_bold_italic});
        if (s.builtin_box_drawing != base.builtin_box_drawing)
            try w.print("builtin_box_drawing = {s}\n", .{if (s.builtin_box_drawing) "true" else "false"});
        if (s.font_weight != base.font_weight) try w.print("font_weight = {d}\n", .{s.font_weight});
        if (s.font_weight_bold != base.font_weight_bold)
            try w.print("font_weight_bold = {d}\n", .{s.font_weight_bold});
        if (!std.mem.eql(u8, s.font_features, base.font_features))
            try w.print("font_features = {s}\n", .{s.font_features});
        if (s.font_size != base.font_size) try w.print("font_size = {d}\n", .{s.font_size});
        if (!std.mem.eql(u8, s.editor_font_family, base.editor_font_family))
            try w.print("editor_font_family = {s}\n", .{s.editor_font_family});
        if (s.editor_font_size != base.editor_font_size)
            try w.print("editor_font_size = {d}\n", .{s.editor_font_size});
        if (s.line_pad_px != base.line_pad_px) try w.print("line_pad_px = {d}\n", .{s.line_pad_px});
        if (s.padding != base.padding) try w.print("padding = {d:.2}\n", .{s.padding});

        // Pane presentation.
        if (s.pane_border_width != base.pane_border_width)
            try w.print("pane_border_width = {d:.2}\n", .{s.pane_border_width});
        if (!eqColor(s.pane_border_color_active, base.pane_border_color_active))
            try writeColorA(w, "pane_border_color_active", s.pane_border_color_active);
        if (!eqColor(s.pane_border_color, base.pane_border_color))
            try writeColorA(w, "pane_border_color", s.pane_border_color);
        if (s.pane_corner_radius != base.pane_corner_radius)
            try w.print("pane_corner_radius = {d:.2}\n", .{s.pane_corner_radius});

        // Colors.
        if (!eqColor(s.default_fg, base.default_fg)) try writeColor(w, "default_fg", s.default_fg);
        if (!eqColor(s.default_bg, base.default_bg)) try writeColor(w, "default_bg", s.default_bg);
        if (!eqColor(s.cursor_color, base.cursor_color)) try writeColor(w, "cursor_color", s.cursor_color);
        if (s.cursor_color_default != base.cursor_color_default)
            try w.print("cursor_color_default = {s}\n", .{if (s.cursor_color_default) "true" else "false"});
        if (!std.mem.eql(u8, s.scheme, base.scheme)) try w.print("scheme = {s}\n", .{s.scheme});
        const pal_differs = blk: {
            if (s.palette == null and base.palette == null) break :blk false;
            if (s.palette == null or base.palette == null) break :blk true;
            break :blk !std.meta.eql(s.palette.?, base.palette.?);
        };
        if (pal_differs) {
            if (s.palette) |pal| try writePalette16(w, "palette", pal);
            // null-while-base-set isn't expressible in the format;
            // the parse-time seed keeps base's palette in that case.
        }
        try serialiseColorSet(&s.light, &base.light, "light", w);
        try serialiseColorSet(&s.dark, &base.dark, "dark", w);

        // Shell + env.
        if (!eqOptStr(s.shell, base.shell)) {
            if (s.shell) |sh| try w.print("shell = {s}\n", .{sh});
        }
        if (!std.mem.eql(u8, s.term_env, base.term_env))
            try w.print("term = {s}\n", .{s.term_env});
        if (!std.mem.eql(u8, s.color_term_env, base.color_term_env))
            try w.print("color_term = {s}\n", .{s.color_term_env});
        if (s.login_shell != base.login_shell)
            try w.print("login_shell = {s}\n", .{if (s.login_shell) "true" else "false"});

        if (s.scrollback != base.scrollback) try w.print("scrollback = {d}\n", .{s.scrollback});

        if (!std.mem.eql(u8, s.custom_shader, base.custom_shader))
            try w.print("custom_shader = {s}\n", .{s.custom_shader});
    }

    /// Emit the `<prefix>.<key>` lines of a light/dark variant whose
    /// value differs from `base`'s same-prefix variant. Clearing a
    /// field back to null is not expressible, same as `palette`.
    fn serialiseColorSet(set: *const ColorSet, base: *const ColorSet, prefix: []const u8, w: *std.Io.Writer) !void {
        var key_buf: [64]u8 = undefined;
        const K = struct {
            fn f(buf: []u8, pfx: []const u8, name: []const u8) []const u8 {
                return std.fmt.bufPrint(buf, "{s}.{s}", .{ pfx, name }) catch unreachable;
            }
        };
        if (set.default_fg) |v| {
            if (!eqOptColor(base.default_fg, v)) try writeColor(w, K.f(&key_buf, prefix, "default_fg"), v);
        }
        if (set.default_bg) |v| {
            if (!eqOptColor(base.default_bg, v)) try writeColor(w, K.f(&key_buf, prefix, "default_bg"), v);
        }
        if (set.cursor_color) |v| {
            if (!eqOptColor(base.cursor_color, v)) try writeColor(w, K.f(&key_buf, prefix, "cursor_color"), v);
        }
        if (set.cursor_color_default) |v| {
            if (base.cursor_color_default == null or base.cursor_color_default.? != v)
                try w.print("{s} = {s}\n", .{ K.f(&key_buf, prefix, "cursor_color_default"), if (v) "true" else "false" });
        }
        if (set.scheme) |v| {
            if (base.scheme == null or !std.mem.eql(u8, base.scheme.?, v))
                try w.print("{s} = {s}\n", .{ K.f(&key_buf, prefix, "scheme"), v });
        }
        if (set.palette) |v| {
            if (base.palette == null or !std.meta.eql(base.palette.?, v))
                try writePalette16(w, K.f(&key_buf, prefix, "palette"), v);
        }
    }

    fn eqOptColor(a: ?[4]f32, b: [4]f32) bool {
        return a != null and eqColor(a.?, b);
    }

    fn eqOptStr(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }

    pub fn serialise(self: *const Config, w: *std.Io.Writer) !void {
        try w.writeAll("# sketerm config (auto-saved by Preferences dialog)\n");

        // Default profile settings, at top level (key compat with
        // pre-profile configs).
        const schema_defaults = ProfileSettings{};
        try serialiseSettings(&self.settings, &schema_defaults, w);

        // Cursor.
        if (self.cursor_shape != .block) try w.print("cursor_shape = {s}\n", .{@tagName(self.cursor_shape)});
        if (!self.cursor_blink) try w.writeAll("cursor_blink = false\n");
        if (self.cursor_blink_ms != 500) try w.print("cursor_blink_ms = {d}\n", .{self.cursor_blink_ms});
        if (self.cursor_trail) try w.writeAll("cursor_trail = true\n");
        if (self.cursor_trail_ms != 300) try w.print("cursor_trail_ms = {d}\n", .{self.cursor_trail_ms});

        // Behaviour.
        if (!self.bracketed_paste) try w.writeAll("bracketed_paste = false\n");
        if (self.modify_other_keys != 0) try w.print("modify_other_keys = {d}\n", .{self.modify_other_keys});

        // Rendering.
        if (!self.ligatures) try w.writeAll("ligatures = false\n");
        if (!self.bidi) try w.writeAll("bidi = false\n");
        if (!self.auto_theme) try w.writeAll("auto_theme = false\n");
        if (!self.graphics_offload) try w.writeAll("graphics_offload = false\n");

        // Bell.
        if (!self.shell_integration) try w.writeAll("shell_integration = off\n");
        if (self.bell_audible) try w.writeAll("bell_audible = true\n");
        if (!self.bell_visible) try w.writeAll("bell_visible = false\n");
        if (!self.bell_urgent) try w.writeAll("bell_urgent = false\n");
        if (self.notify_command_secs != 15) try w.print("notify_command_secs = {d}\n", .{self.notify_command_secs});

        // Behavioural extras.
        if (self.scroll_on_output) try w.writeAll("scroll_on_output = true\n");
        if (!self.track_tab_activity) try w.writeAll("track_tab_activity = false\n");
        if (self.inactive_warn_secs != 60) try w.print("inactive_warn_secs = {d}\n", .{self.inactive_warn_secs});
        if (self.tab_ack_delay_secs != 1.0) try w.print("tab_ack_delay_secs = {d:.2}\n", .{self.tab_ack_delay_secs});
        if (self.image_memory_mb != 320) try w.print("image_memory_mb = {d}\n", .{self.image_memory_mb});
        if (!self.smart_copy) try w.writeAll("smart_copy = false\n");
        if (!self.config_auto_reload) try w.writeAll("config_auto_reload = false\n");
        if (!std.mem.eql(u8, self.word_chars, "-_.,/?:@&=+%~"))
            try w.print("word_chars = {s}\n", .{self.word_chars});
        if (self.gtk_theme.len > 0) try w.print("gtk_theme = {s}\n", .{self.gtk_theme});
        if (self.app_keyboard_layout.len > 0)
            try w.print("app_keyboard_layout = {s}\n", .{self.app_keyboard_layout});
        if (self.app_view != .window) try w.print("app_view = {s}\n", .{@tagName(self.app_view)});
        if (self.input_method != .auto)
            try w.print("input_method = {s}\n", .{@tagName(self.input_method)});
        if (self.gpu_apps.len > 0) try w.print("gpu_apps = {s}\n", .{self.gpu_apps});
        if (self.mux_udp_port_range.len > 0)
            try w.print("mux_udp_port_range = {s}\n", .{self.mux_udp_port_range});

        // File browser.
        if (self.files_default_view != .details)
            try w.print("files_default_view = {s}\n", .{@tagName(self.files_default_view)});
        if (self.files_show_hidden) try w.writeAll("files_show_hidden = true\n");
        if (!self.files_confirm_delete) try w.writeAll("files_confirm_delete = false\n");
        if (self.files_verify_copy) try w.writeAll("files_verify_copy = true\n");

        // Text editor.
        if (self.editor_tab_width != 4) try w.print("editor_tab_width = {d}\n", .{self.editor_tab_width});
        if (!self.editor_insert_spaces) try w.writeAll("editor_insert_spaces = false\n");
        if (self.editor_soft_wrap) try w.writeAll("editor_soft_wrap = true\n");
        if (!self.editor_wrap_words) try w.writeAll("editor_wrap_words = false\n");
        if (!self.editor_line_numbers) try w.writeAll("editor_line_numbers = false\n");
        if (!self.editor_highlight_current_line)
            try w.writeAll("editor_highlight_current_line = false\n");
        if (!self.editor_syntax) try w.writeAll("editor_syntax = false\n");
        if (!self.editor_bracket_match) try w.writeAll("editor_bracket_match = false\n");
        if (!self.editor_folding) try w.writeAll("editor_folding = false\n");
        if (!self.editor_fold_indent_fallback)
            try w.writeAll("editor_fold_indent_fallback = false\n");
        if (!self.editor_crash_recovery) try w.writeAll("editor_crash_recovery = false\n");
        if (!self.editor_lsp) try w.writeAll("editor_lsp = false\n");
        if (!self.editor_lsp_diagnostics) try w.writeAll("editor_lsp_diagnostics = false\n");
        if (self.editor_lsp_debounce_ms != 250)
            try w.print("editor_lsp_debounce_ms = {d}\n", .{self.editor_lsp_debounce_ms});
        if (!self.editor_lsp_inlay_hints) try w.writeAll("editor_lsp_inlay_hints = false\n");
        if (!self.editor_lsp_semantic_tokens) try w.writeAll("editor_lsp_semantic_tokens = false\n");
        if (!self.editor_lsp_signature_help) try w.writeAll("editor_lsp_signature_help = false\n");
        if (self.editor_lsp_hover_delay_ms != 500)
            try w.print("editor_lsp_hover_delay_ms = {d}\n", .{self.editor_lsp_hover_delay_ms});
        if (!std.mem.eql(u8, self.editor_theme, "dark"))
            try w.print("editor_theme = {s}\n", .{self.editor_theme});
        if (self.editor_project_markers.len > 0)
            try w.print("editor_project_markers = {s}\n", .{self.editor_project_markers});
        if (!self.editor_git_gutter) try w.writeAll("editor_git_gutter = false\n");
        if (self.editor_outline) try w.writeAll("editor_outline = true\n");
        if (self.editor_project_search_max_files != 4000)
            try w.print("editor_project_search_max_files = {d}\n", .{self.editor_project_search_max_files});
        if (!self.editor_auto_indent) try w.writeAll("editor_auto_indent = false\n");
        if (!self.editor_auto_close_pairs) try w.writeAll("editor_auto_close_pairs = false\n");
        if (!self.editor_smart_backspace) try w.writeAll("editor_smart_backspace = false\n");

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
        if (self.clipboard_read) try w.writeAll("clipboard_read = allow\n");
        if (self.hint_editor.len > 0) try w.print("hint_editor = {s}\n", .{self.hint_editor});
        if (self.hint_alphabet.len > 0) try w.print("hint_alphabet = {s}\n", .{self.hint_alphabet});
        if (self.hint_multiple) try w.writeAll("hint_multiple = true\n");
        for (self.symbol_maps.items) |sm| {
            // A map with no family routes nothing (the atlas skips it)
            // and would serialise as a trailing-space line the parser
            // then rejects on the next load. Skipping it keeps the file
            // reloadable; the Preferences dialog flags such an entry.
            if (sm.family.len == 0) continue;
            if (sm.lo == sm.hi) {
                try w.print("symbol_map.{s} = U+{X} {s}\n", .{ sm.name, sm.lo, sm.family });
            } else {
                try w.print("symbol_map.{s} = U+{X}-U+{X} {s}\n", .{ sm.name, sm.lo, sm.hi, sm.family });
            }
        }
        for (self.hint_rules.items) |hr| {
            if (hr.pattern.len > 0) try w.print("hint.{s}.regex = {s}\n", .{ hr.name, hr.pattern });
            try w.print("hint.{s}.action = {s}\n", .{ hr.name, @tagName(hr.action) });
            if (hr.command.len > 0) try w.print("hint.{s}.command = {s}\n", .{ hr.name, hr.command });
        }
        if (self.mouse_middle_click != .paste_primary)
            try w.print("mouse_middle_click = {s}\n", .{@tagName(self.mouse_middle_click)});
        if (self.mouse_right_click != .menu)
            try w.print("mouse_right_click = {s}\n", .{@tagName(self.mouse_right_click)});
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
        for (self.editor_keybinds.items) |kb| {
            try w.print("editor_keybind.{s} = {s}\n", .{ kb.name, kb.accel });
        }

        // Shader param overrides.
        for (self.shader_params.items) |sp| {
            if (sp.color) |col| {
                try w.print("shader_param.{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{
                    sp.name,
                    @as(u8, @intFromFloat(std.math.clamp(col[0], 0.0, 1.0) * 255.0)),
                    @as(u8, @intFromFloat(std.math.clamp(col[1], 0.0, 1.0) * 255.0)),
                    @as(u8, @intFromFloat(std.math.clamp(col[2], 0.0, 1.0) * 255.0)),
                });
            } else {
                try w.print("shader_param.{s} = {d}\n", .{ sp.name, sp.value });
            }
        }

        // Background opacity.
        if (self.background_opacity != 1.0)
            try w.print("background_opacity = {d:.2}\n", .{self.background_opacity});

        // Overlay scrollbar.
        if (self.scrollbar != .auto) try w.print("scrollbar = {s}\n", .{@tagName(self.scrollbar)});
        if (self.scrollbar_width != 4.0)
            try w.print("scrollbar_width = {d:.2}\n", .{self.scrollbar_width});
        if (!eqColor(self.scrollbar_trough_color, .{ 0.5, 0.5, 0.5, 0.18 }))
            try writeColorA(w, "scrollbar_trough_color", self.scrollbar_trough_color);
        if (!eqColor(self.scrollbar_thumb_color, .{ 0.5, 0.5, 0.5, 0.30 }))
            try writeColorA(w, "scrollbar_thumb_color", self.scrollbar_thumb_color);
        if (!eqColor(self.scrollbar_thumb_active_color, .{ 0.40, 0.55, 0.85, 0.70 }))
            try writeColorA(w, "scrollbar_thumb_active_color", self.scrollbar_thumb_active_color);

        // Split separators.
        if (self.pane_gap != 4.0) try w.print("pane_gap = {d:.2}\n", .{self.pane_gap});
        if (!eqColor(self.pane_gap_color, .{ 0x35.0 / 255.0, 0x35.0 / 255.0, 0x35.0 / 255.0, 1.0 }))
            try writeColorA(w, "pane_gap_color", self.pane_gap_color);

        // Quake mode.
        if (self.quake_enabled) try w.writeAll("quake_enabled = true\n");
        if (self.quake_monitor.len > 0)
            try w.print("quake_monitor = {s}\n", .{self.quake_monitor});
        if (self.quake_edge != .top) try w.print("quake_edge = {s}\n", .{@tagName(self.quake_edge)});
        if (self.quake_width_percent != 100.0)
            try w.print("quake_width_percent = {d:.2}\n", .{self.quake_width_percent});
        if (self.quake_height_percent != 50.0)
            try w.print("quake_height_percent = {d:.2}\n", .{self.quake_height_percent});

        // Inactive pane dimming.
        if (self.inactive_darken != 0.2)
            try w.print("inactive_darken = {d:.2}\n", .{self.inactive_darken});
        if (self.inactive_desaturate != 0.0)
            try w.print("inactive_desaturate = {d:.2}\n", .{self.inactive_desaturate});
        if (self.minimum_contrast != 1.0)
            try w.print("minimum_contrast = {d:.2}\n", .{self.minimum_contrast});
        if (self.text_blending != .native)
            try w.print("text_blending = {s}\n", .{@tagName(self.text_blending)});

        // Background layer.
        if (self.background_image.len > 0)
            try w.print("background_image = {s}\n", .{self.background_image});
        if (self.background_image_opacity != 0.3)
            try w.print("background_image_opacity = {d:.2}\n", .{self.background_image_opacity});
        if (self.custom_shader_animation)
            try w.print("custom_shader_animation = true\n", .{});
        if (!eqColor(self.background_gradient_from, .{ 0, 0, 0, 0 }))
            try writeColor(w, "background_gradient_from", self.background_gradient_from);
        if (!eqColor(self.background_gradient_to, .{ 0, 0, 0, 0 }))
            try writeColor(w, "background_gradient_to", self.background_gradient_to);
        if (self.background_gradient_angle != 90)
            try w.print("background_gradient_angle = {d:.1}\n", .{self.background_gradient_angle});

        // Per-pane titlebar.
        if (self.show_titlebar) try w.writeAll("show_titlebar = true\n");
        if (!std.mem.eql(u8, self.tab_title_template, default_tab_title))
            try w.print("tab_title_template = {s}\n", .{self.tab_title_template});
        if (self.window_title_template.len > 0)
            try w.print("window_title_template = {s}\n", .{self.window_title_template});
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

        // Default profile name, then each [profile.name] section.
        // Profile keys diff against the Default settings, matching
        // the parse-time seed — so the round-trip is exact.
        if (self.default_profile.len > 0)
            try w.print("default_profile = {s}\n", .{self.default_profile});

        // Platform sections go BEFORE the profile sections, because a
        // profile is seeded from the Default settings as parsed so far
        // — writing them after would drop their values out of every
        // profile on the next load and quietly change the file's
        // meaning.
        for (self.platform_sections.items) |sec| {
            try w.print("\n[platform.{s}]\n", .{sec.name});
            for (sec.lines.items) |kv| try w.print("{s} = {s}\n", .{ kv.key, kv.value });
        }

        for (self.profiles.items) |prof| {
            try w.print("\n[profile.{s}]\n", .{prof.name});
            try serialiseSettings(&prof.settings, &self.settings, w);
        }

        for (self.domains.items) |dom| {
            try w.print("\n[domain.{s}]\n", .{dom.name});
            if (dom.host.len > 0) try w.print("host = {s}\n", .{dom.host});
            if (dom.transport != .auto) try w.print("transport = {s}\n", .{@tagName(dom.transport)});
        }

        // Every key is written for an LSP section rather than diffed
        // against the built-in: a section that silently inherited half
        // its fields from a built-in that later CHANGES would quietly
        // change behaviour on upgrade, which is exactly what a written
        // config is meant to prevent.
        for (self.lsp_servers.items) |srv| {
            try w.print("\n[lsp.{s}]\n", .{srv.name});
            if (srv.command.len > 0) try w.print("command = {s}\n", .{srv.command});
            if (srv.args.len > 0) try w.print("args = {s}\n", .{srv.args});
            if (srv.languages.len > 0) try w.print("languages = {s}\n", .{srv.languages});
            if (srv.root_files.len > 0) try w.print("root_files = {s}\n", .{srv.root_files});
            if (srv.init_options.len > 0) try w.print("init_options = {s}\n", .{srv.init_options});
            if (!srv.enabled) try w.writeAll("enabled = false\n");
        }

        for (self.mcp_profiles.items) |prof| {
            try w.print("\n[mcp.{s}]\n", .{prof.name});
            if (prof.tools.len > 0) try w.print("tools = {s}\n", .{prof.tools});
        }
    }

    /// The `[mcp.<name>]` policy record, or null when no such section
    /// exists (`sketerm mcp --profile` treats that as a hard error —
    /// silently running unrestricted would be the worst outcome).
    pub fn mcpProfile(self: *const Config, name: []const u8) ?*const McpProfile {
        for (self.mcp_profiles.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }

    /// The server that should handle `language_id`: a `[lsp.<name>]`
    /// section first (it replaces a built-in of the same name at parse
    /// time, so the list is already merged), then the built-in table.
    /// Null when nothing claims the language.
    pub fn lspServerFor(self: *const Config, language_id: []const u8) ?*const LspServer {
        return self.lspServerForInstalled(language_id, null, null);
    }

    /// Same, but skipping servers whose command is not actually present
    /// — so configuring `zls` AND a fallback for Zig does the obvious
    /// thing on a machine that only has one of them. `installed` is a
    /// callback so this module stays free of any filesystem or PATH
    /// dependency (it is compiled into `sketerm-mux`); null means "do
    /// not check", which is what the config tests want.
    pub fn lspServerForInstalled(
        self: *const Config,
        language_id: []const u8,
        ctx: ?*anyopaque,
        installed: ?*const fn (ctx: ?*anyopaque, command: []const u8) bool,
    ) ?*const LspServer {
        if (!self.editor_lsp) return null;
        for (self.lsp_servers.items) |*s| {
            if (!s.handles(language_id)) continue;
            if (installed) |f| {
                if (!f(ctx, s.command)) continue;
            }
            return s;
        }
        for (&lsp_servers.builtins) |*b| {
            // A user section with this name has already been consulted
            // above; consulting the built-in too would resurrect a
            // server the user switched off.
            if (self.hasLspSection(b.name)) continue;
            if (!b.handles(language_id)) continue;
            if (installed) |f| {
                if (!f(ctx, b.command)) continue;
            }
            return b;
        }
        return null;
    }

    /// Every enabled server claiming `language_id`, in resolution
    /// order (user sections, then non-overridden built-ins), WITHOUT
    /// an installed check — for the remote-document path, where
    /// "installed" can only be answered by the host that will run the
    /// server (the daemon walks this list and picks the first present
    /// on ITS PATH). Caller owns the slice; records borrow the config
    /// arena, so use them before the next config swap.
    pub fn lspServerCandidates(
        self: *const Config,
        language_id: []const u8,
        alloc: std.mem.Allocator,
    ) error{OutOfMemory}![]const LspServer {
        var out: std.ArrayList(LspServer) = .empty;
        errdefer out.deinit(alloc);
        if (!self.editor_lsp) return out.toOwnedSlice(alloc);
        for (self.lsp_servers.items) |*s| {
            if (s.handles(language_id)) try out.append(alloc, s.*);
        }
        for (&lsp_servers.builtins) |*b| {
            if (self.hasLspSection(b.name)) continue;
            if (b.handles(language_id)) try out.append(alloc, b.*);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Editable record for `name`, materializing a `[lsp.<name>]`
    /// section (seeded from the built-in) the first time the UI writes
    /// to it. `arena` must be the one backing this Config.
    ///
    /// Materializing on WRITE rather than on read is deliberate: a user
    /// who never touches a server keeps a config file with no section
    /// for it, and so keeps following the built-in as it evolves.
    pub fn lspServerMut(self: *Config, arena: std.mem.Allocator, name: []const u8) ?*LspServer {
        return findOrCreateLspServer(self, arena, name) catch null;
    }

    // ── symbol_map.<name> / hint.<name> list editing ─────────────
    //
    // The two prefix-keyed families the Preferences dialog can add to
    // and remove from. Both live on the config arena: a removed entry's
    // strings are not freed (the arena outlives the edit and is thrown
    // away whole), and a name is fixed at creation — renaming would
    // mean rewriting a config key on every keystroke.

    pub fn findSymbolMap(self: *Config, name: []const u8) ?*SymbolMap {
        for (self.symbol_maps.items) |*sm| {
            if (std.mem.eql(u8, sm.name, name)) return sm;
        }
        return null;
    }

    /// Append a symbol map. `range` uses the config syntax
    /// (`U+E0A0-U+E0A3`); an empty family is allowed here and simply
    /// skipped by the renderer, matching a config line the user has
    /// half-filled.
    pub fn addSymbolMap(
        self: *Config,
        arena: std.mem.Allocator,
        name: []const u8,
        range: []const u8,
        family: []const u8,
    ) !*SymbolMap {
        try checkEntryName(name);
        if (self.findSymbolMap(name) != null) return error.DuplicateName;
        const r = try parseCodepointRange(range);
        try self.symbol_maps.append(arena, .{
            .name = try arena.dupe(u8, name),
            .lo = r.lo,
            .hi = r.hi,
            .family = try arena.dupe(u8, family),
        });
        return &self.symbol_maps.items[self.symbol_maps.items.len - 1];
    }

    pub fn removeSymbolMap(self: *Config, name: []const u8) bool {
        for (self.symbol_maps.items, 0..) |sm, i| {
            if (std.mem.eql(u8, sm.name, name)) {
                _ = self.symbol_maps.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn findHintRule(self: *Config, name: []const u8) ?*HintRule {
        for (self.hint_rules.items) |*hr| {
            if (std.mem.eql(u8, hr.name, name)) return hr;
        }
        return null;
    }

    /// Append a hint rule with the parser's own defaults (empty
    /// pattern, `copy`). A rule with no pattern matches nothing, so a
    /// freshly added one is inert until its regex is filled in.
    pub fn addHintRule(self: *Config, arena: std.mem.Allocator, name: []const u8) !*HintRule {
        try checkEntryName(name);
        if (self.findHintRule(name) != null) return error.DuplicateName;
        try self.hint_rules.append(arena, .{ .name = try arena.dupe(u8, name) });
        return &self.hint_rules.items[self.hint_rules.items.len - 1];
    }

    pub fn removeHintRule(self: *Config, name: []const u8) bool {
        for (self.hint_rules.items, 0..) |hr, i| {
            if (std.mem.eql(u8, hr.name, name)) {
                _ = self.hint_rules.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn hasLspSection(self: *const Config, name: []const u8) bool {
        for (self.lsp_servers.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return true;
        }
        return false;
    }

    /// Every server the UI should list: user sections, then the
    /// built-ins they did not override. The slice is caller-owned.
    pub fn lspServerList(self: *const Config, alloc: std.mem.Allocator) error{OutOfMemory}![]const LspServer {
        var out: std.ArrayList(LspServer) = .empty;
        errdefer out.deinit(alloc);
        for (self.lsp_servers.items) |s| try out.append(alloc, s);
        for (lsp_servers.builtins) |b| {
            if (self.hasLspSection(b.name)) continue;
            try out.append(alloc, b);
        }
        return out.toOwnedSlice(alloc);
    }

    /// Resolve a profile name to its settings. Empty name, the
    /// reserved "default", and unknown names all yield the Default
    /// settings — a pane whose profile was deleted degrades to
    /// Default instead of dangling.
    pub fn profileSettings(self: *const Config, name: []const u8) *const ProfileSettings {
        if (name.len == 0 or std.mem.eql(u8, name, "default")) return &self.settings;
        for (self.profiles.items) |*p| {
            if (std.mem.eql(u8, p.name, name)) return &p.settings;
        }
        return &self.settings;
    }

    /// Whether the launcher should start this app with GPU rendering:
    /// a `gpu_apps` entry matches the .desktop Name or the Exec
    /// binary's basename (both case-insensitive).
    pub fn appWantsGpu(self: *const Config, name: []const u8, exec: []const u8) bool {
        return gpuAppsMatch(self.gpu_apps, name, exec);
    }

    /// Look up a domain by name and allocate its transport-prefixed
    /// host spec ("udp:host" / "host"). Null when no such domain or
    /// the section never set a host.
    pub fn resolveDomain(self: *const Config, name: []const u8, allocator: std.mem.Allocator) ?[]u8 {
        for (self.domains.items) |*d| {
            if (!std.mem.eql(u8, d.name, name)) continue;
            if (d.host.len == 0) return null;
            return d.hostSpec(allocator) catch null;
        }
        return null;
    }
};

/// Pure matcher behind Config.appWantsGpu (testable without a Config).
fn gpuAppsMatch(gpu_apps: []const u8, name: []const u8, exec: []const u8) bool {
    if (gpu_apps.len == 0) return false;
    // Exec's binary basename: first whitespace-delimited token, after
    // the last '/' (Exec lines carry args; env wrappers are rare
    // enough to ignore).
    const first_end = std.mem.indexOfAny(u8, exec, " \t") orelse exec.len;
    const first = exec[0..first_end];
    const base = if (std.mem.lastIndexOfScalar(u8, first, '/')) |i| first[i + 1 ..] else first;
    var it = std.mem.splitScalar(u8, gpu_apps, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(entry, name) or std.ascii.eqlIgnoreCase(entry, base))
            return true;
    }
    return false;
}

fn eqColor(a: [4]f32, b: [4]f32) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn writeColor(w: *std.Io.Writer, key: []const u8, c: [4]f32) !void {
    const r: u8 = @intFromFloat(@round(c[0] * 255.0));
    const g: u8 = @intFromFloat(@round(c[1] * 255.0));
    const b: u8 = @intFromFloat(@round(c[2] * 255.0));
    try w.print("{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{ key, r, g, b });
}

/// Like `writeColor` but keeps the alpha channel (`#rrggbbaa`). Used
/// by the keys whose colour is meaningfully translucent — plain
/// `writeColor` drops alpha, which would silently turn an overlay
/// solid on the next save.
fn writeColorA(w: *std.Io.Writer, key: []const u8, c: [4]f32) !void {
    const q = struct {
        fn f(v: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(v, 0.0, 1.0) * 255.0));
        }
    }.f;
    try w.print("{s} = #{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n", .{ key, q(c[0]), q(c[1]), q(c[2]), q(c[3]) });
}

fn writePalette16(w: *std.Io.Writer, key: []const u8, pal: [16][3]u8) !void {
    try w.print("{s} = ", .{key});
    for (pal, 0..) |rgb, i| {
        if (i != 0) try w.writeAll(":");
        try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] });
    }
    try w.writeAll("\n");
}

const makeParentDirs = @import("util/pathz.zig").makeParentDirs;

/// Allocates the path; caller frees.
fn resolveConfigPath(allocator: std.mem.Allocator) ?[]u8 {
    if (@import("util/profile.zig").getenv("XDG_CONFIG_HOME")) |x| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/config.conf", .{x}) catch null;
    }
    if (@import("util/profile.zig").getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.config/sketerm/config.conf", .{home}) catch null;
    }
    return null;
}

fn parseInto(cfg: *Config, body: []const u8) !void {
    const arena = cfg.arena.?.allocator();
    var lines = std.mem.splitScalar(u8, body, '\n');
    var lineno: usize = 0;
    // Section state. `null`/`null` = global; at most one non-null.
    // `[profile.default]` points at cfg.settings so a section-style
    // Default round-trips; new profiles seed from the Default
    // settings parsed SO FAR — global keys must precede profile
    // sections (the serializer always writes them that way).
    var current_settings: ?*ProfileSettings = null;
    var current_profile_name: []const u8 = "";
    var current_domain: ?*Domain = null;
    var current_lsp: ?*LspServer = null;
    var current_mcp: ?*McpProfile = null;
    // `[platform.<name>]` for a platform that is NOT ours: the lines
    // are still parsed, against a throwaway Config, so a typo in the
    // macOS section is reported on Linux instead of waiting until the
    // user changes machines. One scratch config for the whole parse —
    // it is written to and never read.
    var current_platform: ?*PlatformSection = null;
    var current_platform_applies = false;
    var scratch: ?Config = null;
    defer if (scratch) |*s| s.deinit();
    while (lines.next()) |raw| {
        lineno += 1;
        const line = trim(stripComment(raw));
        if (line.len == 0) continue;

        // Section header: [profile.<name>] only for now. Unknown
        // sections log a warning and behave as no-section pass-through
        // — that way unknown future sections don't strip user data.
        if (line.len >= 2 and line[0] == '[' and line[line.len - 1] == ']') {
            const inside = trim(line[1 .. line.len - 1]);
            current_settings = null;
            current_profile_name = "";
            current_domain = null;
            current_lsp = null;
            current_mcp = null;
            current_platform = null;
            current_platform_applies = false;
            if (std.mem.startsWith(u8, inside, "platform.")) {
                const name = inside["platform.".len..];
                if (name.len == 0) {
                    warnConfigAt(lineno, "empty platform name", .{});
                    continue;
                }
                // An unrecognised platform name warns and is ignored,
                // exactly like an unknown key or section — but the
                // section is still retained and its keys are still
                // checked, so a build that does not know `windows`
                // neither drops the user's lines on save nor pretends
                // they are correct.
                if (std.meta.stringToEnum(Platform, name) == null)
                    warnConfigAt(lineno, "unknown platform '{s}' (keys checked, never applied)", .{name});
                current_platform = findOrCreatePlatformSection(cfg, arena, name) catch {
                    warnConfigAt(lineno, "out of memory creating platform section", .{});
                    continue;
                };
                current_platform_applies = Platform.matchesCurrent(name);
                continue;
            }
            if (std.mem.startsWith(u8, inside, "profile.")) {
                const name = inside["profile.".len..];
                if (name.len == 0) {
                    warnConfigAt(lineno, "empty profile name", .{});
                    continue;
                }
                if (std.mem.eql(u8, name, "default")) {
                    current_settings = &cfg.settings;
                    current_profile_name = "default";
                    continue;
                }
                const prof = findOrCreateProfile(cfg, arena, name) catch {
                    warnConfigAt(lineno, "out of memory creating profile", .{});
                    continue;
                };
                current_settings = &prof.settings;
                current_profile_name = prof.name;
                continue;
            }
            if (std.mem.startsWith(u8, inside, "lsp.")) {
                const name = inside["lsp.".len..];
                if (name.len == 0) {
                    warnConfigAt(lineno, "empty lsp server name", .{});
                    continue;
                }
                current_lsp = findOrCreateLspServer(cfg, arena, name) catch {
                    warnConfigAt(lineno, "out of memory creating lsp server", .{});
                    continue;
                };
                continue;
            }
            if (std.mem.startsWith(u8, inside, "mcp.")) {
                const name = inside["mcp.".len..];
                if (name.len == 0) {
                    warnConfigAt(lineno, "empty mcp profile name", .{});
                    continue;
                }
                current_mcp = findOrCreateMcpProfile(cfg, arena, name) catch {
                    warnConfigAt(lineno, "out of memory creating mcp profile", .{});
                    continue;
                };
                continue;
            }
            if (std.mem.startsWith(u8, inside, "domain.")) {
                const name = inside["domain.".len..];
                if (name.len == 0) {
                    warnConfigAt(lineno, "empty domain name", .{});
                    continue;
                }
                current_domain = findOrCreateDomain(cfg, arena, name) catch {
                    warnConfigAt(lineno, "out of memory creating domain", .{});
                    continue;
                };
                continue;
            }
            warnConfigAt(lineno, "unknown section '{s}'", .{inside});
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            warnConfigAt(lineno, "expected key = value", .{});
            continue;
        };
        const key = trim(line[0..eq]);
        const value = trim(line[eq + 1 ..]);
        if (current_platform) |sec| {
            const stored: ?RawKv = blk: {
                const k = arena.dupe(u8, key) catch break :blk null;
                const v = arena.dupe(u8, value) catch break :blk null;
                sec.lines.append(arena, .{ .key = k, .value = v }) catch break :blk null;
                break :blk .{ .key = k, .value = v };
            };
            if (stored == null) {
                warnConfigAt(lineno, "out of memory storing platform key '{s}'", .{key});
                continue;
            }
            if (current_platform_applies) {
                // Applied inline, in file order, into the top-level
                // scope — a platform section is a conditional splice
                // of the global scope, nothing more.
                applyKvReporting(cfg, arena, key, value, lineno);
            } else {
                if (scratch == null) scratch = Config{ .arena = std.heap.ArenaAllocator.init(cfg.arena.?.child_allocator) };
                applyKvReporting(&scratch.?, scratch.?.arena.?.allocator(), key, value, lineno);
            }
            continue;
        }
        if (current_lsp) |srv| {
            applyLspKv(srv, arena, key, value) catch |err| {
                warnConfigAt(lineno, "lsp '{s}': bad value for '{s}' ({s})", .{ srv.name, key, @errorName(err) });
            };
        } else if (current_mcp) |prof| {
            applyMcpKv(prof, arena, key, value) catch |err| {
                warnConfigAt(lineno, "mcp '{s}': bad value for '{s}' ({s})", .{ prof.name, key, @errorName(err) });
            };
        } else if (current_domain) |dom| {
            applyDomainKv(dom, arena, key, value) catch |err| {
                warnConfigAt(lineno, "domain '{s}': bad value for '{s}' ({s})", .{ dom.name, key, @errorName(err) });
            };
        } else if (current_settings) |s| {
            const handled = applySettingsKv(s, arena, key, value) catch |err| {
                warnConfigAt(lineno, "profile '{s}': bad value for '{s}' ({s})", .{ current_profile_name, key, @errorName(err) });
                continue;
            };
            if (!handled)
                warnConfig("unknown profile key '{s}' (ignoring)", .{key});
        } else {
            applyKvReporting(cfg, arena, key, value, lineno);
        }
    }
}

/// `applyKv` plus the parser's warning policy: an unknown key warns
/// without a line number (it is not a syntax error, just a key this
/// build does not have), a bad value warns with one. Shared by the
/// top-level scope and by `[platform.<name>]` sections, so a line
/// inside a platform section is reported exactly as it would be at
/// top level.
fn applyKvReporting(cfg: *Config, arena: std.mem.Allocator, key: []const u8, value: []const u8, lineno: usize) void {
    applyKv(cfg, arena, key, value) catch |err| switch (err) {
        error.UnknownKey => warnConfig("unknown key '{s}' (ignoring)", .{key}),
        else => warnConfigAt(lineno, "bad value for '{s}' ({s})", .{ key, @errorName(err) }),
    };
}

/// Check one top-level `key = value` as the parser would, without a
/// live Config: what a `[platform.<name>]` section for another
/// platform gets, so its keys are validated instead of skipped.
/// `error.UnknownKey` for a key this build does not have.
pub fn validateTopLevelKv(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    var scratch = Config{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer scratch.deinit();
    try applyKv(&scratch, scratch.arena.?.allocator(), key, value);
}

fn findOrCreatePlatformSection(cfg: *Config, arena: std.mem.Allocator, name: []const u8) !*PlatformSection {
    for (cfg.platform_sections.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    try cfg.platform_sections.append(arena, .{ .name = try arena.dupe(u8, name) });
    return &cfg.platform_sections.items[cfg.platform_sections.items.len - 1];
}

fn findOrCreateDomain(cfg: *Config, arena: std.mem.Allocator, name: []const u8) !*Domain {
    for (cfg.domains.items) |*d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    const dup = try arena.dupe(u8, name);
    try cfg.domains.append(arena, .{ .name = dup });
    return &cfg.domains.items[cfg.domains.items.len - 1];
}

/// Find (or create) an `[lsp.<name>]` record. A new record is SEEDED
/// from the built-in of the same name, so a section only has to carry
/// what it changes.
fn findOrCreateLspServer(cfg: *Config, arena: std.mem.Allocator, name: []const u8) !*LspServer {
    for (cfg.lsp_servers.items) |*s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    var seed = LspServer{ .name = try arena.dupe(u8, name) };
    for (lsp_servers.builtins) |b| {
        if (!std.mem.eql(u8, b.name, name)) continue;
        seed = b;
        seed.name = try arena.dupe(u8, name);
        break;
    }
    try cfg.lsp_servers.append(arena, seed);
    return &cfg.lsp_servers.items[cfg.lsp_servers.items.len - 1];
}

fn applyLspKv(srv: *LspServer, arena: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "command")) {
        srv.command = try expandTilde(arena, value);
    } else if (std.mem.eql(u8, key, "args")) {
        srv.args = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "languages")) {
        srv.languages = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "root_files")) {
        srv.root_files = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "init_options")) {
        srv.init_options = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "enabled")) {
        srv.enabled = try parseBool(value);
    } else return error.UnknownKey;
}

fn findOrCreateMcpProfile(cfg: *Config, arena: std.mem.Allocator, name: []const u8) !*McpProfile {
    for (cfg.mcp_profiles.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    const dup = try arena.dupe(u8, name);
    try cfg.mcp_profiles.append(arena, .{ .name = dup });
    return &cfg.mcp_profiles.items[cfg.mcp_profiles.items.len - 1];
}

fn applyMcpKv(prof: *McpProfile, arena: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "tools")) {
        prof.tools = try arena.dupe(u8, value);
    } else return error.UnknownKey;
}

fn applyDomainKv(dom: *Domain, arena: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "host")) {
        dom.host = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "transport")) {
        if (std.mem.eql(u8, value, "auto")) {
            dom.transport = .auto;
        } else if (std.mem.eql(u8, value, "ssh")) {
            dom.transport = .ssh;
        } else if (std.mem.eql(u8, value, "udp")) {
            dom.transport = .udp;
        } else return error.BadTransport;
    } else return error.UnknownKey;
}

fn findOrCreateProfile(cfg: *Config, arena: std.mem.Allocator, name: []const u8) !*Profile {
    for (cfg.profiles.items) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    const dup = try arena.dupe(u8, name);
    // Seed from the Default settings parsed so far: profiles are
    // complete copies, and the section's keys override from there.
    // (No need to deep-copy the strings — they live in the same
    // arena and are never mutated in place.)
    try cfg.profiles.append(arena, .{ .name = dup, .settings = cfg.settings });
    return &cfg.profiles.items[cfg.profiles.items.len - 1];
}

/// Expand `~` / `~/...` to `$HOME` / `$HOME/...` for path-valued
/// config keys. Returns an arena-duped slice (either the original
/// or the expanded form). `~user` (other-user expansion) is
/// intentionally NOT supported — shell-only, would need pwent.
/// Title templates are validated where they are parsed, because the
/// placeholder set is CLOSED: `{{ TITEL }}` can only ever be a typo,
/// and a title that silently renders blank forever is the worst way to
/// learn that. A rejected template warns (naming the bad placeholder
/// and listing the valid ones) and falls back to `fallback`, so one
/// bad line never costs the user the rest of their config.
fn parseTitleTemplate(
    arena: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
    fallback: []const u8,
) ![]const u8 {
    var diag: titlefmt.Diag = .{};
    titlefmt.validate(value, &diag) catch |err| {
        switch (err) {
            error.UnknownPlaceholder => warnConfig(
                "{s}: unknown placeholder '{s}' (valid: {s}) - using the default",
                .{ key, diag.name, titlefmt.field_list },
            ),
            error.UnterminatedPlaceholder => warnConfig(
                "{s}: unterminated '{{{{' at offset {d} - using the default",
                .{ key, diag.offset },
            ),
        }
        return fallback;
    };
    return arena.dupe(u8, value);
}

fn expandTilde(arena: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0 or value[0] != '~') return arena.dupe(u8, value);
    if (value.len > 1 and value[1] != '/') return arena.dupe(u8, value);
    const home = @import("util/profile.zig").getenv("HOME") orelse return arena.dupe(u8, value);
    if (value.len == 1) return arena.dupe(u8, home);
    return std.fmt.allocPrint(arena, "{s}{s}", .{ home, value[1..] });
}

/// Apply one (key, value) line to a settings bundle — the shared
/// pane-level key set used both at top level (Default settings) and
/// inside [profile.<name>] sections. Returns false when the key is
/// not a pane-level key (the caller decides whether that's an
/// app-level key or an unknown one).
fn applySettingsKv(s: *ProfileSettings, arena: std.mem.Allocator, key: []const u8, value: []const u8) !bool {
    // `light.<key>` / `dark.<key>` are prefix-keyed families like
    // `keybind.<action>`, and work identically at top level and
    // inside a [profile.<name>] section.
    if (std.mem.startsWith(u8, key, "light."))
        return applyColorSetKv(&s.light, arena, key["light.".len..], value);
    if (std.mem.startsWith(u8, key, "dark."))
        return applyColorSetKv(&s.dark, arena, key["dark.".len..], value);
    if (std.mem.eql(u8, key, "shell")) {
        s.shell = try expandTilde(arena, value);
    } else if (std.mem.eql(u8, key, "font") or std.mem.eql(u8, key, "font_path")) {
        s.font_path = try expandTilde(arena, value);
    } else if (std.mem.eql(u8, key, "font_family")) {
        s.font_family = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font_family_bold")) {
        s.font_family_bold = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font_family_italic")) {
        s.font_family_italic = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font_family_bold_italic")) {
        s.font_family_bold_italic = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font_weight")) {
        s.font_weight = try parseWeight(value);
    } else if (std.mem.eql(u8, key, "font_weight_bold")) {
        s.font_weight_bold = try parseWeight(value);
    } else if (std.mem.eql(u8, key, "builtin_box_drawing")) {
        s.builtin_box_drawing = try parseBool(value);
    } else if (std.mem.eql(u8, key, "font_features")) {
        s.font_features = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font_size")) {
        s.font_size = try parseU16(value);
    } else if (std.mem.eql(u8, key, "editor_font_family")) {
        s.editor_font_family = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "editor_font_size")) {
        s.editor_font_size = try parseU16(value);
    } else if (std.mem.eql(u8, key, "line_pad_px") or std.mem.eql(u8, key, "line_spacing")) {
        s.line_pad_px = try parseI16(value);
    } else if (std.mem.eql(u8, key, "padding")) {
        s.padding = try parseFloat(value);
    } else if (std.mem.eql(u8, key, "pane_border_width")) {
        s.pane_border_width = std.math.clamp(try parseFloat(value), 0.0, 32.0);
    } else if (std.mem.eql(u8, key, "pane_border_color_active")) {
        s.pane_border_color_active = try parseColor(value);
    } else if (std.mem.eql(u8, key, "pane_border_color")) {
        s.pane_border_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "pane_corner_radius")) {
        s.pane_corner_radius = std.math.clamp(try parseFloat(value), 0.0, 64.0);
    } else if (std.mem.eql(u8, key, "default_fg")) {
        s.default_fg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "default_bg")) {
        s.default_bg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor_color")) {
        s.cursor_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor_color_default")) {
        s.cursor_color_default = try parseBool(value);
    } else if (std.mem.eql(u8, key, "scheme")) {
        s.scheme = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "palette")) {
        s.palette = try parsePalette16(value);
    } else if (std.mem.eql(u8, key, "term") or std.mem.eql(u8, key, "term_env")) {
        s.term_env = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "color_term") or std.mem.eql(u8, key, "color_term_env")) {
        s.color_term_env = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "scrollback")) {
        s.scrollback = try parseU32(value);
    } else if (std.mem.eql(u8, key, "login_shell")) {
        s.login_shell = try parseBool(value);
    } else if (std.mem.eql(u8, key, "custom_shader")) {
        s.custom_shader = try expandTilde(arena, value);
    } else {
        return false;
    }
    return true;
}

/// Apply one `light.`/`dark.`-stripped key to a variant. Returns
/// false for a sub-key that is not a colour key, which the caller
/// reports as unknown.
fn applyColorSetKv(set: *ColorSet, arena: std.mem.Allocator, key: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, key, "default_fg")) {
        set.default_fg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "default_bg")) {
        set.default_bg = try parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor_color")) {
        set.cursor_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "cursor_color_default")) {
        set.cursor_color_default = try parseBool(value);
    } else if (std.mem.eql(u8, key, "scheme")) {
        set.scheme = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "palette")) {
        set.palette = try parsePalette16(value);
    } else {
        return false;
    }
    return true;
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
    // `editor_keybind.<command> = <accel>` — the editor face's own
    // binding namespace (never consulted by the terminal).
    if (std.mem.startsWith(u8, key, "editor_keybind.")) {
        const name = key["editor_keybind.".len..];
        if (name.len == 0) return error.BadKeybindName;
        const name_dup = try arena.dupe(u8, name);
        const accel_dup = try arena.dupe(u8, value);
        for (cfg.editor_keybinds.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.accel = accel_dup;
                return;
            }
        }
        try cfg.editor_keybinds.append(arena, .{ .name = name_dup, .accel = accel_dup });
        return;
    }
    // `hint.<name>.<field> = <value>` — user-defined hint rules. The
    // fields of one rule can appear in any order and on any line; the
    // rule is created by whichever mentions it first, which is also
    // the order rules are scanned in.
    if (std.mem.startsWith(u8, key, "hint.")) {
        const rest = key["hint.".len..];
        const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return error.BadHintRule;
        const name = rest[0..dot];
        const field = rest[dot + 1 ..];
        if (name.len == 0 or field.len == 0) return error.BadHintRule;

        var rule: *HintRule = blk: {
            for (cfg.hint_rules.items) |*entry| {
                if (std.mem.eql(u8, entry.name, name)) break :blk entry;
            }
            try cfg.hint_rules.append(arena, .{ .name = try arena.dupe(u8, name) });
            break :blk &cfg.hint_rules.items[cfg.hint_rules.items.len - 1];
        };
        if (std.mem.eql(u8, field, "regex") or std.mem.eql(u8, field, "pattern")) {
            rule.pattern = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, field, "action")) {
            rule.action = std.meta.stringToEnum(HintAction, value) orelse return error.BadHintAction;
        } else if (std.mem.eql(u8, field, "command")) {
            rule.command = try arena.dupe(u8, value);
        } else {
            return error.BadHintRule;
        }
        return;
    }
    // `symbol_map.<name> = U+E0A0-U+E0A3 <family>` — route a
    // codepoint range to a specific font.
    if (std.mem.startsWith(u8, key, "symbol_map.")) {
        const name = key["symbol_map.".len..];
        if (name.len == 0) return error.BadSymbolMap;
        const parsed = try parseSymbolMap(try arena.dupe(u8, name), value);
        var entry = parsed;
        entry.family = try arena.dupe(u8, parsed.family);
        for (cfg.symbol_maps.items) |*existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                existing.* = entry;
                return;
            }
        }
        try cfg.symbol_maps.append(arena, entry);
        return;
    }
    // `shader_param.<name> = <float | #rrggbb>` — tunable shader
    // uniforms (floats and vec3 colors).
    if (std.mem.startsWith(u8, key, "shader_param.")) {
        const name = key["shader_param.".len..];
        if (name.len == 0 or name.len > 31) return error.BadShaderParam;
        var val: f32 = 0;
        var col: ?[3]f32 = null;
        if (value.len > 0 and value[0] == '#') {
            const rgba = try parseColor(value);
            col = .{ rgba[0], rgba[1], rgba[2] };
        } else {
            val = try parseFloat(value);
        }
        for (cfg.shader_params.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                entry.value = val;
                entry.color = col;
                return;
            }
        }
        try cfg.shader_params.append(arena, .{
            .name = try arena.dupe(u8, name),
            .value = val,
            .color = col,
        });
        return;
    }
    // Pane-level keys at top level edit the Default settings.
    if (try applySettingsKv(&cfg.settings, arena, key, value)) return;
    if (std.mem.eql(u8, key, "cursor_shape")) {
        if (std.mem.eql(u8, value, "block")) cfg.cursor_shape = .block
        else if (std.mem.eql(u8, value, "underline")) cfg.cursor_shape = .underline
        else if (std.mem.eql(u8, value, "bar")) cfg.cursor_shape = .bar
        else return error.BadCursorShape;
    } else if (std.mem.eql(u8, key, "cursor_blink")) {
        cfg.cursor_blink = try parseBool(value);
    } else if (std.mem.eql(u8, key, "cursor_blink_ms")) {
        cfg.cursor_blink_ms = try parseU32(value);
    } else if (std.mem.eql(u8, key, "cursor_trail")) {
        cfg.cursor_trail = try parseBool(value);
    } else if (std.mem.eql(u8, key, "cursor_trail_ms")) {
        const ms = try parseU32(value);
        if (ms < 30 or ms > 2000) return error.BadCursorTrailMs;
        cfg.cursor_trail_ms = ms;
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
    } else if (std.mem.eql(u8, key, "graphics_offload")) {
        cfg.graphics_offload = try parseBool(value);
    } else if (std.mem.eql(u8, key, "shell_integration")) {
        cfg.shell_integration = if (std.mem.eql(u8, value, "auto"))
            true
        else if (std.mem.eql(u8, value, "off"))
            false
        else
            try parseBool(value);
    } else if (std.mem.eql(u8, key, "bell_audible")) {
        cfg.bell_audible = try parseBool(value);
    } else if (std.mem.eql(u8, key, "bell_visible")) {
        cfg.bell_visible = try parseBool(value);
    } else if (std.mem.eql(u8, key, "bell_urgent")) {
        cfg.bell_urgent = try parseBool(value);
    } else if (std.mem.eql(u8, key, "notify_command_secs")) {
        cfg.notify_command_secs = try parseU32(value);
    } else if (std.mem.eql(u8, key, "scroll_on_output")) {
        cfg.scroll_on_output = try parseBool(value);
    } else if (std.mem.eql(u8, key, "track_tab_activity")) {
        cfg.track_tab_activity = try parseBool(value);
    } else if (std.mem.eql(u8, key, "inactive_warn_secs")) {
        cfg.inactive_warn_secs = try parseU32(value);
    } else if (std.mem.eql(u8, key, "tab_ack_delay_secs")) {
        cfg.tab_ack_delay_secs = std.math.clamp(try parseFloat(value), 0.0, 6.0);
    } else if (std.mem.eql(u8, key, "image_memory_mb")) {
        cfg.image_memory_mb = try parseU32(value);
    } else if (std.mem.eql(u8, key, "smart_copy")) {
        cfg.smart_copy = try parseBool(value);
    } else if (std.mem.eql(u8, key, "config_auto_reload")) {
        cfg.config_auto_reload = try parseBool(value);
    } else if (std.mem.eql(u8, key, "close_button_on_tab")) {
        cfg.close_button_on_tab = try parseBool(value);
    } else if (std.mem.eql(u8, key, "word_chars")) {
        cfg.word_chars = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "gtk_theme")) {
        cfg.gtk_theme = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "app_keyboard_layout")) {
        cfg.app_keyboard_layout = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "app_view")) {
        if (std.mem.eql(u8, value, "window")) cfg.app_view = .window
        else if (std.mem.eql(u8, value, "tab")) cfg.app_view = .tab
        else return error.BadAppView;
    } else if (std.mem.eql(u8, key, "input_method")) {
        if (std.mem.eql(u8, value, "auto")) cfg.input_method = .auto
        else if (std.mem.eql(u8, value, "simple")) cfg.input_method = .simple
        else if (std.mem.eql(u8, value, "multi")) cfg.input_method = .multi
        else return error.BadInputMethod;
    } else if (std.mem.eql(u8, key, "gpu_apps")) {
        cfg.gpu_apps = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "mux_udp_port_range")) {
        // Validate lo:hi here so a typo warns at load, not mid-ssh.
        const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.BadPortRange;
        const lo = try std.fmt.parseInt(u16, value[0..colon], 10);
        const hi = try std.fmt.parseInt(u16, value[colon + 1 ..], 10);
        if (lo == 0 or hi < lo) return error.BadPortRange;
        cfg.mux_udp_port_range = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "exit_action")) {
        if (std.mem.eql(u8, value, "close")) cfg.exit_action = .close
        else if (std.mem.eql(u8, value, "restart")) cfg.exit_action = .restart
        else if (std.mem.eql(u8, value, "hold")) cfg.exit_action = .hold
        else return error.BadExitAction;
    } else if (std.mem.eql(u8, key, "tab_position")) {
        if (std.mem.eql(u8, value, "top")) cfg.tab_position = .top
        else if (std.mem.eql(u8, value, "bottom")) cfg.tab_position = .bottom
        else return error.BadTabPosition;
    } else if (std.mem.eql(u8, key, "always_on_top")) {
        cfg.always_on_top = try parseBool(value);
    } else if (std.mem.eql(u8, key, "new_tab_after_current")) {
        cfg.new_tab_after_current = try parseBool(value);
    } else if (std.mem.eql(u8, key, "confirm_close")) {
        if (std.mem.eql(u8, value, "never")) cfg.confirm_close = .never
        else if (std.mem.eql(u8, value, "multiple")) cfg.confirm_close = .multiple
        else if (std.mem.eql(u8, value, "always")) cfg.confirm_close = .always
        else return error.BadConfirmClose;
    } else if (std.mem.eql(u8, key, "files_default_view")) {
        cfg.files_default_view = std.meta.stringToEnum(FilesView, value) orelse return error.BadFilesView;
    } else if (std.mem.eql(u8, key, "files_show_hidden")) {
        cfg.files_show_hidden = try parseBool(value);
    } else if (std.mem.eql(u8, key, "files_confirm_delete")) {
        cfg.files_confirm_delete = try parseBool(value);
    } else if (std.mem.eql(u8, key, "files_verify_copy")) {
        cfg.files_verify_copy = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_tab_width")) {
        const w = try parseU16(value);
        if (w == 0 or w > 16) return error.BadEditorTabWidth;
        cfg.editor_tab_width = w;
    } else if (std.mem.eql(u8, key, "editor_insert_spaces")) {
        cfg.editor_insert_spaces = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_soft_wrap")) {
        cfg.editor_soft_wrap = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_wrap_words")) {
        cfg.editor_wrap_words = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_line_numbers")) {
        cfg.editor_line_numbers = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_highlight_current_line")) {
        cfg.editor_highlight_current_line = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_syntax")) {
        cfg.editor_syntax = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_bracket_match")) {
        cfg.editor_bracket_match = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_folding")) {
        cfg.editor_folding = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_crash_recovery")) {
        cfg.editor_crash_recovery = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_fold_indent_fallback")) {
        cfg.editor_fold_indent_fallback = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_lsp")) {
        cfg.editor_lsp = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_lsp_diagnostics")) {
        cfg.editor_lsp_diagnostics = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_lsp_debounce_ms")) {
        cfg.editor_lsp_debounce_ms = try parseU16(value);
    } else if (std.mem.eql(u8, key, "editor_lsp_inlay_hints")) {
        cfg.editor_lsp_inlay_hints = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_lsp_semantic_tokens")) {
        cfg.editor_lsp_semantic_tokens = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_lsp_signature_help")) {
        cfg.editor_lsp_signature_help = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_lsp_hover_delay_ms")) {
        cfg.editor_lsp_hover_delay_ms = try parseU16(value);
    } else if (std.mem.eql(u8, key, "editor_theme")) {
        cfg.editor_theme = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "editor_project_markers")) {
        cfg.editor_project_markers = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "editor_git_gutter")) {
        cfg.editor_git_gutter = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_outline")) {
        cfg.editor_outline = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_project_search_max_files")) {
        cfg.editor_project_search_max_files = try parseU32(value);
    } else if (std.mem.eql(u8, key, "editor_auto_indent")) {
        cfg.editor_auto_indent = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_auto_close_pairs")) {
        cfg.editor_auto_close_pairs = try parseBool(value);
    } else if (std.mem.eql(u8, key, "editor_smart_backspace")) {
        cfg.editor_smart_backspace = try parseBool(value);
    } else if (std.mem.eql(u8, key, "mouse_autohide")) {
        cfg.mouse_autohide = try parseBool(value);
    } else if (std.mem.eql(u8, key, "copy_on_selection")) {
        cfg.copy_on_selection = try parseBool(value);
    } else if (std.mem.eql(u8, key, "clear_select_on_copy")) {
        cfg.clear_select_on_copy = try parseBool(value);
    } else if (std.mem.eql(u8, key, "disable_mouse_paste")) {
        cfg.disable_mouse_paste = try parseBool(value);
    } else if (std.mem.eql(u8, key, "mouse_middle_click")) {
        cfg.mouse_middle_click = std.meta.stringToEnum(MouseAction, value) orelse return error.BadMouseAction;
    } else if (std.mem.eql(u8, key, "mouse_right_click")) {
        cfg.mouse_right_click = std.meta.stringToEnum(MouseAction, value) orelse return error.BadMouseAction;
    } else if (std.mem.eql(u8, key, "hint_editor")) {
        cfg.hint_editor = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "hint_alphabet")) {
        cfg.hint_alphabet = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "hint_multiple")) {
        cfg.hint_multiple = try parseBool(value);
    } else if (std.mem.eql(u8, key, "clipboard_read")) {
        if (std.mem.eql(u8, value, "allow")) {
            cfg.clipboard_read = true;
        } else if (std.mem.eql(u8, value, "deny")) {
            cfg.clipboard_read = false;
        } else {
            cfg.clipboard_read = try parseBool(value);
        }
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
    } else if (std.mem.eql(u8, key, "minimum_contrast")) {
        cfg.minimum_contrast = std.math.clamp(try parseFloat(value), 1.0, 21.0);
    } else if (std.mem.eql(u8, key, "text_blending")) {
        // Ghostty spells the third value `linear-corrected`; accept
        // both so a config copied from its docs just works.
        if (std.mem.eql(u8, value, "native")) cfg.text_blending = .native
        else if (std.mem.eql(u8, value, "linear")) cfg.text_blending = .linear
        else if (std.mem.eql(u8, value, "linear_corrected") or
            std.mem.eql(u8, value, "linear-corrected")) cfg.text_blending = .linear_corrected
        else return error.BadTextBlending;
    } else if (std.mem.eql(u8, key, "tab_title_template")) {
        cfg.tab_title_template = try parseTitleTemplate(arena, key, value, default_tab_title);
    } else if (std.mem.eql(u8, key, "window_title_template")) {
        cfg.window_title_template = try parseTitleTemplate(arena, key, value, "");
    } else if (std.mem.eql(u8, key, "background_image")) {
        cfg.background_image = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "background_image_opacity")) {
        cfg.background_image_opacity = std.math.clamp(try parseFloat(value), 0.0, 1.0);
    } else if (std.mem.eql(u8, key, "custom_shader_animation")) {
        cfg.custom_shader_animation = try parseBool(value);
    } else if (std.mem.eql(u8, key, "background_gradient_from")) {
        cfg.background_gradient_from = try parseColor(value);
    } else if (std.mem.eql(u8, key, "background_gradient_to")) {
        cfg.background_gradient_to = try parseColor(value);
    } else if (std.mem.eql(u8, key, "background_gradient_angle")) {
        cfg.background_gradient_angle = try parseFloat(value);
    } else if (std.mem.eql(u8, key, "scrollbar")) {
        cfg.scrollbar = std.meta.stringToEnum(ScrollbarMode, value) orelse return error.BadScrollbarMode;
    } else if (std.mem.eql(u8, key, "scrollbar_width")) {
        cfg.scrollbar_width = std.math.clamp(try parseFloat(value), 0.0, 64.0);
    } else if (std.mem.eql(u8, key, "scrollbar_trough_color")) {
        cfg.scrollbar_trough_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "scrollbar_thumb_color")) {
        cfg.scrollbar_thumb_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "scrollbar_thumb_active_color")) {
        cfg.scrollbar_thumb_active_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "pane_gap")) {
        cfg.pane_gap = std.math.clamp(try parseFloat(value), 1.0, 64.0);
    } else if (std.mem.eql(u8, key, "pane_gap_color")) {
        cfg.pane_gap_color = try parseColor(value);
    } else if (std.mem.eql(u8, key, "quake_enabled")) {
        cfg.quake_enabled = try parseBool(value);
    } else if (std.mem.eql(u8, key, "quake_monitor")) {
        cfg.quake_monitor = try arena.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "quake_edge")) {
        cfg.quake_edge = std.meta.stringToEnum(QuakeEdge, value) orelse return error.BadQuakeEdge;
    } else if (std.mem.eql(u8, key, "quake_width_percent")) {
        cfg.quake_width_percent = std.math.clamp(try parseFloat(value), 1.0, 100.0);
    } else if (std.mem.eql(u8, key, "quake_height_percent")) {
        cfg.quake_height_percent = std.math.clamp(try parseFloat(value), 1.0, 100.0);
    } else if (std.mem.eql(u8, key, "inactive_darken")) {
        cfg.inactive_darken = std.math.clamp(try parseFloat(value), 0.0, 1.0);
    } else if (std.mem.eql(u8, key, "inactive_desaturate")) {
        cfg.inactive_desaturate = std.math.clamp(try parseFloat(value), 0.0, 1.0);
    } else if (std.mem.eql(u8, key, "inactive_fg_dim") or std.mem.eql(u8, key, "inactive_bg_dim")) {
        // Retired per-cell dim keys — accepted (and ignored) so old
        // config files don't error. Use inactive_darken instead.
        _ = parseFloat(value) catch {};
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
        // Unknown key. Reported (never fatal) by the caller, which
        // also gets to say WHERE — the same line may be a platform
        // section's, checked against a throwaway config.
        return error.UnknownKey;
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
    try std.testing.expectEqual(@as(u16, 14), cfg.settings.font_size);
    try std.testing.expectEqual(@as(u32, 10000), cfg.settings.scrollback);
    try std.testing.expectEqualStrings("xterm-256color", cfg.settings.term_env);
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
    try std.testing.expectEqual(@as(u16, 16), cfg.settings.font_size);
    try std.testing.expectEqual(@as(u32, 50000), cfg.settings.scrollback);
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
    try std.testing.expectApproxEqAbs(@as(f32, 0xab) / 255.0, cfg.settings.default_fg[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 16) / 255.0, cfg.settings.default_bg[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 48) / 255.0, cfg.settings.default_bg[2], 0.001);
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
    try std.testing.expectEqualStrings("/usr/share/fonts/Hack/Hack-Regular.ttf", cfg.settings.font_path.?);
}

test "config: line_pad_px parses int (positive and negative)" {
    const body =
        \\font_size = 12
        \\line_pad_px = -2
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(i16, -2), cfg.settings.line_pad_px);

    const body2 =
        \\line_spacing = 4
    ;
    var cfg2 = try Config.loadFromBytes(std.testing.allocator, body2);
    defer cfg2.deinit();
    try std.testing.expectEqual(@as(i16, 4), cfg2.settings.line_pad_px);
}

test "config: serialise omits defaults" {
    var cfg = Config{};
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    // Empty config should serialise to just the header comment —
    // no key=value lines for default values.
    try std.testing.expect(std.mem.startsWith(u8, out, "# sketerm config"));
    try std.testing.expect(std.mem.indexOf(u8, out, "font_size") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "ligatures") == null);
}

test "config: light/dark variants parse and fall back to flat values" {
    const body =
        \\default_fg = #cccccc
        \\default_bg = #111111
        \\cursor_color = #ff0000
        \\scheme = tango
        \\light.default_fg = #202020
        \\light.default_bg = #fafafa
        \\light.scheme = solarized_light
        \\dark.default_bg = #000000
        \\dark.cursor_color_default = false
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    const s = &cfg.settings;

    // Flat values are untouched by the variants: they stay the base
    // AND the "auto_theme off" answer.
    try std.testing.expectApproxEqAbs(@as(f32, 0xcc) / 255.0, s.default_fg[0], 0.005);
    try std.testing.expectEqualStrings("tango", s.scheme);
    try std.testing.expect(std.meta.eql(s.*, s.forScheme(null)));

    // Light: fully specified fg/bg/scheme; cursor falls back to flat.
    const lt = s.forScheme(.light);
    try std.testing.expectApproxEqAbs(@as(f32, 0x20) / 255.0, lt.default_fg[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 0xfa) / 255.0, lt.default_bg[0], 0.005);
    try std.testing.expectEqualStrings("solarized_light", lt.scheme);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), lt.cursor_color[0], 0.005);
    try std.testing.expectEqual(true, lt.cursor_color_default);

    // Dark: only bg + cursor_color_default set. fg falls through to
    // the BUILT-IN dark fg (what auto_theme has always substituted),
    // and scheme falls back to the flat one.
    const dk = s.forScheme(.dark);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), dk.default_bg[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.92), dk.default_fg[0], 0.005);
    try std.testing.expectEqualStrings("tango", dk.scheme);
    try std.testing.expectEqual(false, dk.cursor_color_default);
}

test "config: no variants keeps the pre-variant auto_theme behaviour" {
    const body =
        \\default_fg = #cccccc
        \\default_bg = #111111
        \\scheme = tango
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    const s = &cfg.settings;
    // The built-in pair is exactly what resolveColorsFor hardcoded
    // before variants existed; palette/scheme/cursor still come from
    // the flat fields under both halves.
    inline for (.{ .{ ColorScheme.light, builtin_light }, .{ ColorScheme.dark, builtin_dark } }) |pair| {
        const eff = s.forScheme(pair[0]);
        try std.testing.expect(eqColor(eff.default_fg, pair[1].default_fg.?));
        try std.testing.expect(eqColor(eff.default_bg, pair[1].default_bg.?));
        try std.testing.expectEqualStrings("tango", eff.scheme);
        try std.testing.expectEqual(true, eff.cursor_color_default);
        try std.testing.expect(eff.palette == null);
    }
}

test "config: light/dark variants round-trip through serialise + clone" {
    var cfg = Config{};
    cfg.settings.light = .{
        .default_fg = .{ 0.0, 0.0, 0.0, 1.0 },
        .default_bg = .{ 1.0, 1.0, 1.0, 1.0 },
        .scheme = "solarized_light",
    };
    cfg.settings.dark = .{
        .cursor_color = .{ 1.0, 0.0, 0.0, 1.0 },
        .cursor_color_default = false,
        .palette = .{
            .{ 0x07, 0x36, 0x42 }, .{ 0xdc, 0x32, 0x2f }, .{ 0x85, 0x99, 0x00 }, .{ 0xb5, 0x89, 0x00 },
            .{ 0x26, 0x8b, 0xd2 }, .{ 0xd3, 0x36, 0x82 }, .{ 0x2a, 0xa1, 0x98 }, .{ 0xee, 0xe8, 0xd5 },
            .{ 0x00, 0x2b, 0x36 }, .{ 0xcb, 0x4b, 0x16 }, .{ 0x58, 0x6e, 0x75 }, .{ 0x65, 0x7b, 0x83 },
            .{ 0x83, 0x94, 0x96 }, .{ 0x6c, 0x71, 0xc4 }, .{ 0x93, 0xa1, 0xa1 }, .{ 0xfd, 0xf6, 0xe3 },
        },
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "light.scheme = solarized_light") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "dark.cursor_color_default = false") != null);

    var parsed = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer parsed.deinit();
    try std.testing.expectEqualStrings("solarized_light", parsed.settings.light.scheme.?);
    try std.testing.expect(parsed.settings.light.default_bg != null);
    try std.testing.expect(parsed.settings.light.cursor_color == null);
    try std.testing.expectEqual(false, parsed.settings.dark.cursor_color_default.?);
    try std.testing.expectEqual(@as(u8, 0xfd), parsed.settings.dark.palette.?[15][0]);
    try std.testing.expect(parsed.settings.dark.default_fg == null);

    // Clone into a fresh arena, then free the source: the variant
    // scheme string must be a copy, not a slice into the dead arena.
    var cloned = try parsed.clone(std.testing.allocator);
    defer cloned.deinit();
    parsed.deinit();
    try std.testing.expectEqualStrings("solarized_light", cloned.settings.light.scheme.?);
    try std.testing.expectEqual(@as(u8, 0xfd), cloned.settings.dark.palette.?[15][0]);
}

test "config: profile sections carry their own light/dark variants" {
    const body =
        \\dark.default_bg = #101010
        \\
        \\[profile.paper]
        \\light.default_bg = #fffff0
        \\dark.default_bg = #202020
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();

    // Default profile: only the top-level dark override.
    try std.testing.expect(cfg.settings.light.default_bg == null);
    try std.testing.expectApproxEqAbs(@as(f32, 0x10) / 255.0, cfg.settings.dark.default_bg.?[0], 0.005);

    // The named profile was seeded from Default, then overrode both.
    const paper = cfg.profileSettings("paper");
    try std.testing.expectApproxEqAbs(@as(f32, 0xff) / 255.0, paper.light.default_bg.?[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 0x20) / 255.0, paper.dark.default_bg.?[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 0x20) / 255.0, paper.forScheme(.dark).default_bg[0], 0.005);

    // A profile-only override serialises inside its section, and the
    // Default's dark bg it inherited unchanged does not repeat.
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const sec = std.mem.indexOf(u8, w.buffered(), "[profile.paper]").?;
    try std.testing.expect(std.mem.indexOf(u8, w.buffered()[sec..], "light.default_bg") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered()[sec..], "dark.default_bg") != null);
}

test "config: variant colour rows show the effective value" {
    var s = ProfileSettings{};
    s.default_fg = .{ 0.5, 0.5, 0.5, 1.0 };
    s.cursor_color = .{ 1.0, 0.0, 0.0, 1.0 };
    s.light.default_bg = .{ 0.9, 0.8, 0.7, 1.0 };

    // auto_theme off: the row shows the flat base, unchanged.
    try std.testing.expect(eqColor(s.variantColor(null, .default_fg), s.default_fg));
    try std.testing.expect(eqColor(s.variantColor(null, .cursor_color), s.cursor_color));

    // Variant field set -> the variant wins.
    try std.testing.expect(eqColor(s.variantColor(.light, .default_bg), .{ 0.9, 0.8, 0.7, 1.0 }));
    // Unset but covered by the built-in variant -> the built-in.
    try std.testing.expect(eqColor(s.variantColor(.light, .default_fg), builtin_light.default_fg.?));
    try std.testing.expect(eqColor(s.variantColor(.dark, .default_bg), builtin_dark.default_bg.?));
    // Unset and not covered by the built-in -> the flat base.
    try std.testing.expect(eqColor(s.variantColor(.dark, .cursor_color), s.cursor_color));

    // Whatever a row shows is what forScheme renders.
    inline for (.{ ColorScheme.light, ColorScheme.dark }) |sc| {
        const eff = s.forScheme(sc);
        try std.testing.expect(eqColor(s.variantColor(sc, .default_fg), eff.default_fg));
        try std.testing.expect(eqColor(s.variantColor(sc, .default_bg), eff.default_bg));
        try std.testing.expect(eqColor(s.variantColor(sc, .cursor_color), eff.cursor_color));
    }

    // cursor_color_default / scheme / palette resolve the same way.
    s.cursor_color_default = false;
    s.scheme = "tango";
    s.dark.cursor_color_default = true;
    s.dark.scheme = "";
    try std.testing.expectEqual(false, s.variantCursorDefault(null));
    try std.testing.expectEqual(false, s.variantCursorDefault(.light));
    try std.testing.expectEqual(true, s.variantCursorDefault(.dark));
    try std.testing.expectEqualStrings("tango", s.variantSchemeName(.light));
    try std.testing.expectEqualStrings("", s.variantSchemeName(.dark));
    try std.testing.expect(s.variantPalette(.light) == null);
}

test "config: variant colour writes land in the variant, never the base" {
    var s = ProfileSettings{};
    const base_fg = s.default_fg;
    const base_bg = s.default_bg;

    s.setVariantColor(.dark, .default_bg, .{ 0.1, 0.2, 0.3, 1.0 });
    try std.testing.expect(eqColor(s.default_bg, base_bg));
    try std.testing.expect(eqColor(s.dark.default_bg.?, .{ 0.1, 0.2, 0.3, 1.0 }));
    try std.testing.expect(s.light.default_bg == null);

    s.setVariantCursorDefault(.light, false);
    try std.testing.expectEqual(true, s.cursor_color_default);
    try std.testing.expectEqual(false, s.light.cursor_color_default.?);

    // Null scheme (auto_theme off) writes the base and nothing else.
    s.setVariantColor(null, .default_fg, .{ 0.4, 0.4, 0.4, 1.0 });
    try std.testing.expect(eqColor(s.default_fg, .{ 0.4, 0.4, 0.4, 1.0 }));
    try std.testing.expect(!eqColor(s.default_fg, base_fg));
    try std.testing.expect(s.light.default_fg == null and s.dark.default_fg == null);

    // A palette write pins the layer's palette and cancels its scheme.
    s.scheme = "tango";
    var pal: [16][3]u8 = undefined;
    for (&pal, 0..) |*e, i| e.* = .{ @intCast(i), 0, 0 };
    s.setVariantPalette(.light, pal);
    try std.testing.expect(s.palette == null);
    try std.testing.expectEqualStrings("tango", s.scheme);
    try std.testing.expectEqualStrings("", s.light.scheme.?);
    try std.testing.expectEqual(@as(u8, 15), s.variantPalette(.light).?[15][0]);
    // The other half is untouched and still sees the flat scheme.
    try std.testing.expectEqualStrings("tango", s.variantSchemeName(.dark));

    // Picking a built-in scheme fills the whole layer.
    s.setVariantScheme(.dark, "solarized_dark", .{ 0.5, 0, 0, 1 }, .{ 0, 0.5, 0, 1 }, pal);
    try std.testing.expectEqualStrings("solarized_dark", s.variantSchemeName(.dark));
    try std.testing.expect(eqColor(s.variantColor(.dark, .default_fg), .{ 0.5, 0, 0, 1 }));
    try std.testing.expect(eqColor(s.default_fg, .{ 0.4, 0.4, 0.4, 1.0 }));
    try std.testing.expectEqualStrings("tango", s.scheme);
}

test "config: variants written by the prefs helpers survive a save/load round-trip" {
    var cfg = Config{};
    cfg.settings.setVariantColor(.light, .default_bg, .{ 1.0, 1.0, 1.0, 1.0 });
    cfg.settings.setVariantColor(.dark, .default_bg, .{ 0.0, 0.0, 0.0, 1.0 });
    cfg.settings.setVariantCursorDefault(.dark, false);
    cfg.settings.setVariantColor(.dark, .cursor_color, .{ 1.0, 0.0, 0.0, 1.0 });
    // The flat base the user configured must come back untouched.
    cfg.settings.default_bg = .{
        @as(f32, 0x11) / 255.0,
        @as(f32, 0x22) / 255.0,
        @as(f32, 0x33) / 255.0,
        1.0,
    };

    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);

    var parsed = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer parsed.deinit();
    const s = &parsed.settings;
    try std.testing.expectApproxEqAbs(@as(f32, 0x11) / 255.0, s.default_bg[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.variantColor(.light, .default_bg)[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.variantColor(.dark, .default_bg)[0], 0.005);
    try std.testing.expectEqual(false, s.variantCursorDefault(.dark));
    try std.testing.expectEqual(true, s.variantCursorDefault(.light));
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.variantColor(.dark, .cursor_color)[0], 0.005);
}

test "config: palette + scheme + new keys round-trip" {
    var cfg = Config{};
    cfg.settings.scheme = "solarized_dark";
    cfg.settings.palette = .{
        .{ 0x07, 0x36, 0x42 }, .{ 0xdc, 0x32, 0x2f }, .{ 0x85, 0x99, 0x00 }, .{ 0xb5, 0x89, 0x00 },
        .{ 0x26, 0x8b, 0xd2 }, .{ 0xd3, 0x36, 0x82 }, .{ 0x2a, 0xa1, 0x98 }, .{ 0xee, 0xe8, 0xd5 },
        .{ 0x00, 0x2b, 0x36 }, .{ 0xcb, 0x4b, 0x16 }, .{ 0x58, 0x6e, 0x75 }, .{ 0x65, 0x7b, 0x83 },
        .{ 0x83, 0x94, 0x96 }, .{ 0x6c, 0x71, 0xc4 }, .{ 0x93, 0xa1, 0xa1 }, .{ 0xfd, 0xf6, 0xe3 },
    };
    cfg.scroll_on_output = true;
    cfg.track_tab_activity = false;
    cfg.smart_copy = false;
    cfg.settings.login_shell = true;
    cfg.settings.cursor_color_default = false;
    cfg.tab_position = .bottom;
    cfg.close_button_on_tab = false;
    cfg.exit_action = .hold;
    cfg.app_view = .tab;
    cfg.input_method = .multi;
    cfg.bell_visible = false;
    cfg.bell_urgent = false;
    cfg.word_chars = "abc";
    cfg.minimum_contrast = 3.5;

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);

    var parsed = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer parsed.deinit();

    try std.testing.expectEqualStrings("solarized_dark", parsed.settings.scheme);
    try std.testing.expect(parsed.settings.palette != null);
    try std.testing.expectEqual(@as(u8, 0xdc), parsed.settings.palette.?[1][0]);
    try std.testing.expectEqual(@as(u8, 0xfd), parsed.settings.palette.?[15][0]);
    try std.testing.expectEqual(true, parsed.scroll_on_output);
    try std.testing.expectEqual(false, parsed.track_tab_activity);
    try std.testing.expectEqual(false, parsed.smart_copy);
    try std.testing.expectEqual(true, parsed.settings.login_shell);
    try std.testing.expectEqual(false, parsed.settings.cursor_color_default);
    try std.testing.expectEqual(TabPosition.bottom, parsed.tab_position);
    try std.testing.expectEqual(false, parsed.close_button_on_tab);
    try std.testing.expectEqual(ExitAction.hold, parsed.exit_action);
    try std.testing.expectEqual(AppView.tab, parsed.app_view);
    try std.testing.expectEqual(InputMethod.multi, parsed.input_method);
    try std.testing.expectEqual(false, parsed.bell_visible);
    try std.testing.expectEqual(false, parsed.bell_urgent);
    try std.testing.expectEqualStrings("abc", parsed.word_chars);
    try std.testing.expectApproxEqAbs(@as(f32, 3.5), parsed.minimum_contrast, 1e-6);
}

test "config: loadFromPath refuses an unreadable file instead of returning defaults" {
    // The whole point of the separate entry point: a live reload that
    // raced an editor's rename must not silently reset every setting.
    try std.testing.expectError(
        error.NotReadable,
        Config.loadFromPath(std.testing.allocator, "/nonexistent/sketerm-test/config.conf"),
    );

    const c = @import("c.zig").c;
    var tmpl = "/tmp/sketerm-cfgpath-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/config.conf", .{base});
    defer _ = c.unlink(path.ptr);
    defer _ = c.rmdir(dir);
    {
        const fp = c.fopen(path.ptr, "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(fp);
        const body = "# hand written\nfont_size = 21\nconfig_auto_reload = false\n";
        _ = c.fwrite(body.ptr, 1, body.len, fp);
    }
    var cfg = try Config.loadFromPath(std.testing.allocator, path);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 21), cfg.settings.font_size);
    try std.testing.expectEqual(false, cfg.config_auto_reload);
}

test "config: config_auto_reload defaults on, round-trips and clones" {
    try std.testing.expectEqual(true, (Config{}).config_auto_reload);

    // Default value writes no line (the serialiser is minimal).
    {
        var cfg = Config{};
        var buf: [2048]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try cfg.serialise(&w);
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "config_auto_reload") == null);
    }

    var cfg = Config{};
    cfg.config_auto_reload = false;
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "config_auto_reload = false") != null);

    var parsed = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.config_auto_reload);

    // The clone every apply path goes through must carry it.
    var cloned = try parsed.clone(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqual(false, cloned.config_auto_reload);

    // The other spellings parseBool accepts.
    var off = try Config.loadFromBytes(std.testing.allocator, "config_auto_reload = off\n");
    defer off.deinit();
    try std.testing.expectEqual(false, off.config_auto_reload);
}

test "config: serialise round-trips through loadFromBytes" {
    // Set a few non-default values; serialise; re-parse; check.
    var cfg = Config{};
    cfg.settings.font_size = 18;
    cfg.cursor_shape = .underline;
    cfg.settings.scrollback = 50000;
    cfg.settings.padding = 8.0;
    cfg.bracketed_paste = false;
    cfg.modify_other_keys = 2;
    cfg.settings.line_pad_px = -1;
    cfg.settings.default_fg = .{ 1.0, 0.5, 0.0, 1.0 };
    cfg.settings.default_bg = .{ 0.0, 0.0, 0.0, 1.0 };
    cfg.settings.cursor_color = .{ 0.5, 1.0, 0.5, 1.0 };
    cfg.bell_audible = true;
    cfg.ligatures = false;
    cfg.graphics_offload = false;

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();

    var parsed = try Config.loadFromBytes(std.testing.allocator, out);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u16, 18), parsed.settings.font_size);
    try std.testing.expectEqual(CursorShape.underline, parsed.cursor_shape);
    try std.testing.expectEqual(@as(u32, 50000), parsed.settings.scrollback);
    try std.testing.expectEqual(@as(f32, 8.0), parsed.settings.padding);
    try std.testing.expectEqual(false, parsed.bracketed_paste);
    try std.testing.expectEqual(@as(u8, 2), parsed.modify_other_keys);
    try std.testing.expectEqual(@as(i16, -1), parsed.settings.line_pad_px);
    try std.testing.expectEqual(true, parsed.bell_audible);
    try std.testing.expectEqual(false, parsed.ligatures);
    try std.testing.expectEqual(false, parsed.graphics_offload);
    // Colors round-trip through #RRGGBB so they may lose the lowest
    // byte of float precision but the high bits should match.
    try std.testing.expect(@abs(parsed.settings.default_fg[0] - 1.0) < 0.01);
    try std.testing.expect(@abs(parsed.settings.default_fg[1] - 0.5) < 0.01);
    try std.testing.expect(@abs(parsed.settings.default_fg[2] - 0.0) < 0.01);
    try std.testing.expect(@abs(parsed.settings.cursor_color[1] - 1.0) < 0.01);
}

test "config: profile custom_shader parses and round-trips" {
    const src =
        "custom_shader = /tmp/global.glsl\n" ++
        "[profile.retro]\n" ++
        "scheme = monokai\n" ++
        "custom_shader = /tmp/crt.glsl\n";
    var cfg = try Config.loadFromBytes(std.testing.allocator, src);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("/tmp/global.glsl", cfg.settings.custom_shader);
    try std.testing.expectEqual(@as(usize, 1), cfg.profiles.items.len);
    try std.testing.expectEqualStrings("/tmp/crt.glsl", cfg.profiles.items[0].settings.custom_shader);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    var re = try Config.loadFromBytes(std.testing.allocator, out);
    defer re.deinit();
    try std.testing.expectEqualStrings("/tmp/crt.glsl", re.profiles.items[0].settings.custom_shader);

    // Clone keeps the profile shader (config-reload path).
    var cl = try cfg.clone(std.testing.allocator);
    defer cl.deinit();
    try std.testing.expectEqualStrings("/tmp/crt.glsl", cl.profiles.items[0].settings.custom_shader);
}

test "config: shader_param.<name> entries parse, dedupe, round-trip, clone" {
    const src =
        "shader_param.glow = 1.25\n" ++
        "shader_param.curvature = 0\n" ++
        "shader_param.glow = 0.8\n"; // later line wins
    var cfg = try Config.loadFromBytes(std.testing.allocator, src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.shader_params.items.len);
    try std.testing.expectEqualStrings("glow", cfg.shader_params.items[0].name);
    try std.testing.expectEqual(@as(f32, 0.8), cfg.shader_params.items[0].value);
    try std.testing.expectEqual(@as(f32, 0.0), cfg.shader_params.items[1].value);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 2), re.shader_params.items.len);
    try std.testing.expectEqual(@as(f32, 0.8), re.shader_params.items[0].value);

    var cl = try cfg.clone(std.testing.allocator);
    defer cl.deinit();
    try std.testing.expectEqualStrings("curvature", cl.shader_params.items[1].name);
}

test "config: title templates parse, round-trip and clone" {
    const src =
        "tab_title_template = {{ INDEX }}: {{ PROGRAM || TITLE }}\n" ++
        "window_title_template = {{ TITLE }} - {{ RELATIVE_PATH }}\n";
    var cfg = try Config.loadFromBytes(std.testing.allocator, src);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("{{ INDEX }}: {{ PROGRAM || TITLE }}", cfg.tab_title_template);
    try std.testing.expectEqualStrings("{{ TITLE }} - {{ RELATIVE_PATH }}", cfg.window_title_template);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer re.deinit();
    try std.testing.expectEqualStrings(cfg.tab_title_template, re.tab_title_template);
    try std.testing.expectEqualStrings(cfg.window_title_template, re.window_title_template);

    var cl = try cfg.clone(std.testing.allocator);
    defer cl.deinit();
    try std.testing.expectEqualStrings(cfg.tab_title_template, cl.tab_title_template);
    try std.testing.expectEqualStrings(cfg.window_title_template, cl.window_title_template);
}

test "config: defaults keep the historical title behaviour and stay unserialised" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("{{ TITLE }}", cfg.tab_title_template);
    try std.testing.expectEqualStrings("", cfg.window_title_template);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "tab_title_template") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "window_title_template") == null);
}

test "config: a bad title template falls back to the default" {
    // Unknown placeholder and unterminated braces both warn and keep
    // the default rather than failing the whole config.
    var cfg = try Config.loadFromBytes(std.testing.allocator, "tab_title_template = {{ TITEL }}\n");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("{{ TITLE }}", cfg.tab_title_template);

    var cfg2 = try Config.loadFromBytes(std.testing.allocator, "window_title_template = {{ TITLE\n");
    defer cfg2.deinit();
    try std.testing.expectEqualStrings("", cfg2.window_title_template);

    // A valid key on a later line still parses — one bad template
    // must not poison the rest of the file.
    var cfg3 = try Config.loadFromBytes(std.testing.allocator,
        "tab_title_template = {{ nope }}\nwindow_title_template = {{ SESSION }}\n");
    defer cfg3.deinit();
    try std.testing.expectEqualStrings("{{ TITLE }}", cfg3.tab_title_template);
    try std.testing.expectEqualStrings("{{ SESSION }}", cfg3.window_title_template);
}

test "config: shader_param color values (#rrggbb) round-trip" {
    const src = "shader_param.phosphor = #ffb333\n";
    var cfg = try Config.loadFromBytes(std.testing.allocator, src);
    defer cfg.deinit();
    const col = cfg.shader_params.items[0].color.?;
    try std.testing.expect(@abs(col[0] - 1.0) < 0.01);
    try std.testing.expect(@abs(col[1] - 0.7) < 0.01);
    try std.testing.expect(@abs(col[2] - 0.2) < 0.01);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "shader_param.phosphor = #ffb333") != null);
    var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer re.deinit();
    try std.testing.expect(re.shader_params.items[0].color != null);
}

test "config: show_titlebar / show_tab_bar round-trip" {
    // Both bools default to non-default values to exercise the
    // serializer's "skip default" path for one and "emit non-default"
    // for the other in a single test.
    var cfg = Config{};
    cfg.show_titlebar = true; // default false → must be emitted
    cfg.show_tab_bar = false; // default true  → must be emitted
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "show_titlebar = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "show_tab_bar = false") != null);

    var parsed = try Config.loadFromBytes(std.testing.allocator, out);
    defer parsed.deinit();
    try std.testing.expectEqual(true, parsed.show_titlebar);
    try std.testing.expectEqual(false, parsed.show_tab_bar);
}

test "config: ~ expansion in path-valued keys" {
    // Use the test runner's actual HOME — avoids needing setenv.
    const home = @import("util/profile.zig").getenv("HOME") orelse return error.SkipZigTest;

    const body =
        \\font = ~/fonts/Hack.ttf
        \\shell = ~/bin/myshell
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expect(cfg.settings.font_path != null);

    // Build expected string from the test runner's HOME.
    var expected_font_buf: [512]u8 = undefined;
    const expected_font = try std.fmt.bufPrint(&expected_font_buf, "{s}/fonts/Hack.ttf", .{home});
    try std.testing.expectEqualStrings(expected_font, cfg.settings.font_path.?);

    var expected_shell_buf: [512]u8 = undefined;
    const expected_shell = try std.fmt.bufPrint(&expected_shell_buf, "{s}/bin/myshell", .{home});
    try std.testing.expect(cfg.settings.shell != null);
    try std.testing.expectEqualStrings(expected_shell, cfg.settings.shell.?);
}

test "config: ~user (no slash after ~) is NOT expanded" {
    // Whether HOME is set or not, ~root should pass through verbatim
    // — we don't support shell-style other-user expansion.
    const body = "shell = ~root/bin/sh\n";
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expect(cfg.settings.shell != null);
    try std.testing.expectEqualStrings("~root/bin/sh", cfg.settings.shell.?);
}

test "config: visibility defaults are NOT emitted (terse output)" {
    // Verify the serializer's "skip default" gates work — defaults
    // (show_titlebar=false, show_tab_bar=true) shouldn't appear in
    // the output, otherwise minimal user configs accumulate cruft.
    const cfg = Config{};
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "show_titlebar") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "show_tab_bar") == null);
}

test "config: symbol maps and per-style font families round-trip" {
    const src =
        \\font_family = JetBrains Mono
        \\font_family_italic = Cascadia Code
        \\font_weight = 300
        \\font_weight_bold = 600
        \\symbol_map.powerline = U+E0A0-U+E0A3 Symbols Nerd Font
        \\symbol_map.one = 2603 DejaVu Sans
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, src);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("Cascadia Code", cfg.settings.font_family_italic);
    // An unset style family stays empty rather than echoing the
    // regular one: empty means "derive it", which is not the same.
    try std.testing.expectEqualStrings("", cfg.settings.font_family_bold);
    try std.testing.expectEqual(@as(u16, 300), cfg.settings.font_weight);
    try std.testing.expectEqual(@as(u16, 600), cfg.settings.font_weight_bold);

    try std.testing.expectEqual(@as(usize, 2), cfg.symbol_maps.items.len);
    try std.testing.expectEqual(@as(u32, 0xE0A0), cfg.symbol_maps.items[0].lo);
    try std.testing.expectEqual(@as(u32, 0xE0A3), cfg.symbol_maps.items[0].hi);
    try std.testing.expectEqualStrings("Symbols Nerd Font", cfg.symbol_maps.items[0].family);
    // A bare codepoint is a one-element range, and the U+ is optional.
    try std.testing.expectEqual(@as(u32, 0x2603), cfg.symbol_maps.items[1].lo);
    try std.testing.expectEqual(@as(u32, 0x2603), cfg.symbol_maps.items[1].hi);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "symbol_map.powerline = U+E0A0-U+E0A3 Symbols Nerd Font") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "font_weight = 300") != null);
    var re = try Config.loadFromBytes(std.testing.allocator, out);
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 2), re.symbol_maps.items.len);
    try std.testing.expectEqualStrings("Cascadia Code", re.settings.font_family_italic);
}

test "config: malformed symbol maps and weights are rejected" {
    try std.testing.expectError(error.BadSymbolMap, parseSymbolMap("x", "U+E0A0"));
    try std.testing.expectError(error.BadSymbolMap, parseSymbolMap("x", "U+E0A3-U+E0A0 Fam"));
    try std.testing.expectError(error.BadSymbolMap, parseSymbolMap("x", "notahex Fam"));
    try std.testing.expectError(error.BadFontWeight, parseWeight("12"));
    try std.testing.expectError(error.BadFontWeight, parseWeight("1000"));
    try std.testing.expectEqual(@as(u16, 350), try parseWeight("350"));
}

test "config: hint rules parse, keep file order and round-trip" {
    const src =
        \\hint_alphabet = qwerty
        \\hint_multiple = true
        \\hint.ticket.regex = [A-Z]+-[0-9]+
        \\hint.ticket.action = command
        \\hint.ticket.command = xdg-open https://tracker/{match}
        \\hint.ip.regex = [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+
        \\hint.ip.action = paste
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, src);
    defer cfg.deinit();

    try std.testing.expectEqualStrings("qwerty", cfg.hint_alphabet);
    try std.testing.expect(cfg.hint_multiple);
    try std.testing.expectEqual(@as(usize, 2), cfg.hint_rules.items.len);
    // Order matters: rules are scanned in the order they appear.
    try std.testing.expectEqualStrings("ticket", cfg.hint_rules.items[0].name);
    try std.testing.expectEqual(HintAction.command, cfg.hint_rules.items[0].action);
    try std.testing.expectEqualStrings("xdg-open https://tracker/{match}", cfg.hint_rules.items[0].command);
    try std.testing.expectEqualStrings("ip", cfg.hint_rules.items[1].name);
    try std.testing.expectEqual(HintAction.paste, cfg.hint_rules.items[1].action);
    try std.testing.expectEqualStrings("[A-Z]+-[0-9]+", cfg.hint_rules.items[0].pattern);
}

test "config: an unknown hint action leaves the rule on its safe default" {
    const src =
        \\hint.x.regex = foo
        \\hint.x.action = rm -rf
        \\
    ;
    // A bad line is warned about and skipped, like every other config
    // error — the rule must not end up doing something else instead.
    var cfg = try Config.loadFromBytes(std.testing.allocator, src);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 1), cfg.hint_rules.items.len);
    try std.testing.expectEqual(HintAction.copy, cfg.hint_rules.items[0].action);
    try std.testing.expectEqualStrings("foo", cfg.hint_rules.items[0].pattern);
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
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    var parsed = try Config.loadFromBytes(std.testing.allocator, out);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.keybinds.items.len);
    try std.testing.expectEqualStrings("<Control><Alt>d", parsed.keybinds.items[1].accel);
}

test "config: editor_keybind entries and typing toggles round-trip" {
    const body =
        \\editor_keybind.toggle_comment = <Control>k
        \\editor_keybind.sort_lines =
        \\editor_auto_indent = false
        \\editor_auto_close_pairs = false
        \\editor_smart_backspace = false
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.editor_keybinds.items.len);
    try std.testing.expectEqualStrings("toggle_comment", cfg.editor_keybinds.items[0].name);
    try std.testing.expectEqualStrings("<Control>k", cfg.editor_keybinds.items[0].accel);
    try std.testing.expectEqualStrings("", cfg.editor_keybinds.items[1].accel);
    try std.testing.expect(!cfg.editor_auto_indent);
    try std.testing.expect(!cfg.editor_auto_close_pairs);
    try std.testing.expect(!cfg.editor_smart_backspace);
    // They live in their own list, not the terminal's.
    try std.testing.expectEqual(@as(usize, 0), cfg.keybinds.items.len);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var parsed = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.editor_keybinds.items.len);
    try std.testing.expectEqualStrings("<Control>k", parsed.editor_keybinds.items[0].accel);
    try std.testing.expect(!parsed.editor_auto_indent);
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

test "config: [domain.name] sections parse, resolve, round-trip" {
    const body =
        \\[domain.devbox]
        \\host = skerit@192.168.1.2
        \\transport = udp
        \\
        \\[domain.work]
        \\host = build.example.com
        \\
        \\[domain.legacy]
        \\host = old.example.com
        \\transport = ssh
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 3), cfg.domains.items.len);
    try std.testing.expectEqualStrings("skerit@192.168.1.2", cfg.domains.items[0].host);
    try std.testing.expectEqual(.udp, cfg.domains.items[0].transport);
    try std.testing.expectEqual(.auto, cfg.domains.items[1].transport);
    try std.testing.expectEqual(.ssh, cfg.domains.items[2].transport);

    const spec = cfg.resolveDomain("devbox", std.testing.allocator).?;
    defer std.testing.allocator.free(spec);
    try std.testing.expectEqualStrings("udp:skerit@192.168.1.2", spec);
    const spec2 = cfg.resolveDomain("work", std.testing.allocator).?;
    defer std.testing.allocator.free(spec2);
    try std.testing.expectEqualStrings("build.example.com", spec2);
    const spec3 = cfg.resolveDomain("legacy", std.testing.allocator).?;
    defer std.testing.allocator.free(spec3);
    try std.testing.expectEqualStrings("ssh:old.example.com", spec3);
    try std.testing.expect(cfg.resolveDomain("nope", std.testing.allocator) == null);

    // Round-trip via serialise.
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var cfg2 = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer cfg2.deinit();
    try std.testing.expectEqual(@as(usize, 3), cfg2.domains.items.len);
    try std.testing.expectEqual(.udp, cfg2.domains.items[0].transport);
    try std.testing.expectEqual(.auto, cfg2.domains.items[1].transport);
    try std.testing.expectEqual(.ssh, cfg2.domains.items[2].transport);
    try std.testing.expectEqualStrings("build.example.com", cfg2.domains.items[1].host);
}

test "config: [mcp.name] sections parse and round-trip" {
    const body =
        \\[mcp.wayland]
        \\tools = app, files:ro
        \\
        \\[mcp.readonly]
        \\tools = -run_command
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();

    try std.testing.expectEqual(@as(usize, 2), cfg.mcp_profiles.items.len);
    try std.testing.expectEqualStrings("app, files:ro", cfg.mcpProfile("wayland").?.tools);
    try std.testing.expectEqualStrings("-run_command", cfg.mcpProfile("readonly").?.tools);
    try std.testing.expect(cfg.mcpProfile("nope") == null);
    // A different namespace from the pane profiles of the same name.
    try std.testing.expectEqual(@as(usize, 0), cfg.profiles.items.len);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var cfg2 = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer cfg2.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg2.mcp_profiles.items.len);
    try std.testing.expectEqualStrings("app, files:ro", cfg2.mcpProfile("wayland").?.tools);
}

test "config: [lsp.name] sections parse, seed from builtins and round-trip" {
    const body =
        \\editor_lsp_debounce_ms = 400
        \\
        \\[lsp.zls]
        \\args = --enable-debug-log
        \\
        \\[lsp.clangd]
        \\enabled = false
        \\
        \\[lsp.pylsp]
        \\command = pylsp
        \\languages = python
        \\root_files = pyproject.toml,setup.py
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 400), cfg.editor_lsp_debounce_ms);
    try std.testing.expectEqual(@as(usize, 3), cfg.lsp_servers.items.len);

    // Seeded from the built-in: the section only set `args`, but the
    // command and languages came along.
    const zls = cfg.lspServerFor("zig").?;
    try std.testing.expectEqualStrings("zls", zls.command);
    try std.testing.expectEqualStrings("--enable-debug-log", zls.args);
    try std.testing.expectEqualStrings("build.zig,build.zig.zon,.git", zls.root_files);

    // A disabled section must not fall through to the built-in.
    try std.testing.expect(cfg.lspServerFor("c") == null);
    // A wholly new server works with no built-in behind it.
    try std.testing.expectEqualStrings("pylsp", cfg.lspServerFor("python").?.command);
    // Untouched built-ins still resolve.
    try std.testing.expectEqualStrings("rust-analyzer", cfg.lspServerFor("rust").?.command);
    try std.testing.expect(cfg.lspServerFor("cobol") == null);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var cfg2 = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer cfg2.deinit();
    try std.testing.expectEqual(@as(u16, 400), cfg2.editor_lsp_debounce_ms);
    try std.testing.expectEqualStrings("--enable-debug-log", cfg2.lspServerFor("zig").?.args);
    try std.testing.expect(cfg2.lspServerFor("c") == null);
    try std.testing.expectEqualStrings("pylsp", cfg2.lspServerFor("python").?.command);
}

test "config: editor_lsp = false disables every server" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "editor_lsp = false\n");
    defer cfg.deinit();
    try std.testing.expect(cfg.lspServerFor("zig") == null);
}

test "config: lspServerList merges user sections over builtins" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "[lsp.zls]\ncommand = /opt/zls\n");
    defer cfg.deinit();
    const list = try cfg.lspServerList(std.testing.allocator);
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("zls", list[0].name);
    try std.testing.expectEqualStrings("/opt/zls", list[0].command);
    try std.testing.expectEqualStrings("clangd", list[1].name);
}

test "config: lspServerCandidates keeps resolution order and skips disabled" {
    const body =
        \\[lsp.clangd]
        \\enabled = false
        \\
        \\[lsp.fallback-zls]
        \\command = /opt/other-zls
        \\languages = zig
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    // User section first, then the untouched built-in — the order the
    // daemon walks looking for an installed one.
    const zig_list = try cfg.lspServerCandidates("zig", std.testing.allocator);
    defer std.testing.allocator.free(zig_list);
    try std.testing.expectEqual(@as(usize, 2), zig_list.len);
    try std.testing.expectEqualStrings("/opt/other-zls", zig_list[0].command);
    try std.testing.expectEqualStrings("zls", zig_list[1].command);
    // The disabled clangd section suppresses its built-in wholesale.
    const c_list = try cfg.lspServerCandidates("c", std.testing.allocator);
    defer std.testing.allocator.free(c_list);
    try std.testing.expectEqual(@as(usize, 0), c_list.len);
    // Master switch off = no candidates at all.
    var off = try Config.loadFromBytes(std.testing.allocator, "editor_lsp = false\n");
    defer off.deinit();
    const none = try off.lspServerCandidates("zig", std.testing.allocator);
    defer std.testing.allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "config: [profile.name] sections round-trip" {
    const body =
        \\font_size = 14
        \\scrollback = 20000
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

    try std.testing.expectEqual(@as(u16, 14), cfg.settings.font_size); // Default
    try std.testing.expectEqualStrings("dev", cfg.default_profile);
    try std.testing.expectEqual(@as(usize, 2), cfg.profiles.items.len);

    const dev = cfg.profiles.items[0];
    try std.testing.expectEqualStrings("dev", dev.name);
    try std.testing.expectEqualStrings("/usr/bin/fish", dev.settings.shell.?);
    try std.testing.expectEqualStrings("solarized_dark", dev.settings.scheme);
    try std.testing.expectEqual(@as(u16, 16), dev.settings.font_size);
    // Unset profile keys were seeded from the Default settings.
    try std.testing.expectEqual(@as(u32, 20000), dev.settings.scrollback);

    const prod = cfg.profiles.items[1];
    try std.testing.expectEqualStrings("prod", prod.name);
    try std.testing.expectEqualStrings("/usr/bin/bash", prod.settings.shell.?);
    try std.testing.expectEqual(true, prod.settings.login_shell);
    try std.testing.expectEqual(@as(u32, 50000), prod.settings.scrollback);
    try std.testing.expectEqual(@as(u16, 14), prod.settings.font_size); // seeded

    // Round-trip via serialise.
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var parsed = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.profiles.items.len);
    try std.testing.expectEqualStrings("solarized_dark", parsed.profiles.items[0].settings.scheme);
    try std.testing.expectEqual(@as(u16, 16), parsed.profiles.items[0].settings.font_size);
    try std.testing.expectEqual(true, parsed.profiles.items[1].settings.login_shell);
    try std.testing.expectEqual(@as(u32, 20000), parsed.profiles.items[0].settings.scrollback);
}

test "config: [profile.default] section edits the Default settings" {
    const body =
        \\font_size = 15
        \\
        \\[profile.default]
        \\font_size = 18
        \\scheme = nord
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 18), cfg.settings.font_size);
    try std.testing.expectEqualStrings("nord", cfg.settings.scheme);
    // "default" never lands in the named-profile list.
    try std.testing.expectEqual(@as(usize, 0), cfg.profiles.items.len);
    // profileSettings resolves "", "default" and unknown names to it.
    try std.testing.expectEqual(@as(u16, 18), cfg.profileSettings("").font_size);
    try std.testing.expectEqual(@as(u16, 18), cfg.profileSettings("default").font_size);
    try std.testing.expectEqual(@as(u16, 18), cfg.profileSettings("nope").font_size);
}

test "config: gpu_apps parses and appWantsGpu matches name or exec basename" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "gpu_apps = Blender, mpv\n");
    defer cfg.deinit();
    try std.testing.expectEqualStrings("Blender, mpv", cfg.gpu_apps);
    // .desktop Name, case-insensitive.
    try std.testing.expect(cfg.appWantsGpu("blender", "/usr/bin/blender-launcher %f"));
    // Exec basename (with args and path stripped).
    try std.testing.expect(cfg.appWantsGpu("Media Player", "/usr/bin/mpv --player-operation-mode=pseudo-gui %U"));
    try std.testing.expect(!cfg.appWantsGpu("Files", "/usr/bin/nautilus %U"));
    // Args never match; empty list never matches.
    try std.testing.expect(!cfg.appWantsGpu("X", "foo mpv"));
    try std.testing.expect(!gpuAppsMatch("", "Blender", "blender"));
}

test "config: overlay scrollbar keys parse and round-trip" {
    const body =
        \\scrollbar = always
        \\scrollbar_width = 10
        \\scrollbar_trough_color = #10203040
        \\scrollbar_thumb_color = #405060
        \\scrollbar_thumb_active_color = #a0b0c0d0
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(ScrollbarMode.always, cfg.scrollbar);
    try std.testing.expectEqual(@as(f32, 10), cfg.scrollbar_width);
    try std.testing.expectApproxEqAbs(@as(f32, 0x40) / 255.0, cfg.scrollbar_trough_color[3], 0.001);
    // A 6-digit colour is opaque; the alpha-preserving serialiser
    // must not turn that into a translucent value on the way back.
    try std.testing.expectEqual(@as(f32, 1.0), cfg.scrollbar_thumb_color[3]);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "scrollbar = always") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "scrollbar_trough_color = #10203040") != null);

    var again = try Config.loadFromBytes(std.testing.allocator, out);
    defer again.deinit();
    try std.testing.expectEqual(cfg.scrollbar, again.scrollbar);
    try std.testing.expectEqual(cfg.scrollbar_width, again.scrollbar_width);
    try std.testing.expectEqual(cfg.scrollbar_trough_color, again.scrollbar_trough_color);
    try std.testing.expectEqual(cfg.scrollbar_thumb_color, again.scrollbar_thumb_color);
    try std.testing.expectEqual(cfg.scrollbar_thumb_active_color, again.scrollbar_thumb_active_color);
}

test "config: scrollbar_width clamps and a bad mode is rejected" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "scrollbar_width = 999\n");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 64), cfg.scrollbar_width);
    // A bad value warns on the line and leaves the default standing,
    // like every other key — a typo must not cost the whole file.
    var bad = try Config.loadFromBytes(std.testing.allocator, "scrollbar = sometimes\n");
    defer bad.deinit();
    try std.testing.expectEqual(ScrollbarMode.auto, bad.scrollbar);
}

test "config: pane presentation keys round-trip, per profile" {
    const body =
        \\pane_border_width = 3
        \\pane_corner_radius = 8
        \\pane_gap = 8
        \\pane_gap_color = #112233
        \\
        \\[profile.prod]
        \\pane_border_color_active = #ff000080
        \\pane_border_color = #ff0000ff
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(f32, 3), cfg.settings.pane_border_width);
    try std.testing.expectEqual(@as(f32, 8), cfg.settings.pane_corner_radius);
    try std.testing.expectEqual(@as(f32, 8), cfg.pane_gap);
    // The profile section is seeded from Default, so it keeps the
    // width set above and overrides only the two colours.
    const prod = cfg.profileSettings("prod").*;
    try std.testing.expectEqual(@as(f32, 3), prod.pane_border_width);
    try std.testing.expectEqual(@as(f32, 1.0), prod.pane_border_color[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0x80) / 255.0, prod.pane_border_color_active[3], 0.001);
    // The Default profile keeps the schema default (invisible).
    try std.testing.expectEqual(@as(f32, 0), cfg.settings.pane_border_color[3]);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    var again = try Config.loadFromBytes(std.testing.allocator, out);
    defer again.deinit();
    try std.testing.expectEqual(cfg.settings.pane_border_width, again.settings.pane_border_width);
    try std.testing.expectEqual(cfg.settings.pane_corner_radius, again.settings.pane_corner_radius);
    try std.testing.expectEqual(cfg.pane_gap, again.pane_gap);
    try std.testing.expectEqual(cfg.pane_gap_color, again.pane_gap_color);
    try std.testing.expectEqual(prod.pane_border_color, again.profileSettings("prod").pane_border_color);
    try std.testing.expectEqual(prod.pane_border_color_active, again.profileSettings("prod").pane_border_color_active);
}

test "config: quake keys parse, clamp and round-trip" {
    const body =
        \\quake_enabled = true
        \\quake_monitor = DP-1
        \\quake_edge = bottom
        \\quake_width_percent = 80
        \\quake_height_percent = 400
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expect(cfg.quake_enabled);
    try std.testing.expectEqualStrings("DP-1", cfg.quake_monitor);
    try std.testing.expectEqual(QuakeEdge.bottom, cfg.quake_edge);
    try std.testing.expectEqual(@as(f32, 80), cfg.quake_width_percent);
    try std.testing.expectEqual(@as(f32, 100), cfg.quake_height_percent);

    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    var again = try Config.loadFromBytes(std.testing.allocator, out);
    defer again.deinit();
    try std.testing.expectEqual(cfg.quake_enabled, again.quake_enabled);
    try std.testing.expectEqualStrings(cfg.quake_monitor, again.quake_monitor);
    try std.testing.expectEqual(cfg.quake_edge, again.quake_edge);
    try std.testing.expectEqual(cfg.quake_width_percent, again.quake_width_percent);
    try std.testing.expectEqual(cfg.quake_height_percent, again.quake_height_percent);

    // The string field is arena-backed: cloneInto must deep-copy it.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const clone = try cfg.cloneInto(arena.allocator());
    try std.testing.expectEqualStrings("DP-1", clone.quake_monitor);
    try std.testing.expect(clone.quake_monitor.ptr != cfg.quake_monitor.ptr);
}

test "config: the new defaults stay out of the serialised file" {
    var cfg = Config{};
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "quake_") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "scrollbar") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pane_gap") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pane_border") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pane_corner") == null);
}

// ── Preferences-side validation + list editing ─────────────────

test "config: entry names for the prefix-keyed families" {
    try checkEntryName("powerline");
    try checkEntryName("nerd-font_2");
    try checkEntryName("caf\xc3\xa9"); // non-ASCII is the user's business
    try std.testing.expectError(error.EmptyName, checkEntryName(""));
    try std.testing.expectError(error.NameBadChar, checkEntryName("two words"));
    try std.testing.expectError(error.NameBadChar, checkEntryName("a=b"));
    try std.testing.expectError(error.NameBadChar, checkEntryName("a.b"));
    try std.testing.expectError(error.NameBadChar, checkEntryName("[sec]"));
    try std.testing.expectError(error.NameBadChar, checkEntryName("a#b"));
    try std.testing.expectError(error.NameTooLong, checkEntryName("x" ** 65));
}

test "config: hint alphabet validation matches the hint-mode rule" {
    try checkHintAlphabet("asdf");
    try std.testing.expectError(error.AlphabetTooShort, checkHintAlphabet("a"));
    try std.testing.expectError(error.AlphabetTooLong, checkHintAlphabet("x" ** 65));
    try std.testing.expectError(error.AlphabetNotPrintable, checkHintAlphabet("a b"));
    try std.testing.expectError(error.AlphabetDuplicate, checkHintAlphabet("aba"));
    try std.testing.expectEqual(@as(?[]const u8, null), validHintAlphabet("a"));
    try std.testing.expect(validHintAlphabet("qwerty") != null);
    // Every error has a message; none is empty.
    for ([_]AlphabetError{
        error.AlphabetTooShort,
        error.AlphabetTooLong,
        error.AlphabetNotPrintable,
        error.AlphabetDuplicate,
    }) |e| try std.testing.expect(alphabetErrorText(e).len > 0);
    for ([_]NameError{
        error.EmptyName,
        error.NameTooLong,
        error.NameBadChar,
        error.DuplicateName,
    }) |e| try std.testing.expect(nameErrorText(e).len > 0);
}

test "config: codepoint ranges parse and format back" {
    const one = try parseCodepointRange("U+2603");
    try std.testing.expectEqual(@as(u32, 0x2603), one.lo);
    try std.testing.expectEqual(@as(u32, 0x2603), one.hi);
    const many = try parseCodepointRange("e0a0-U+E0A3");
    try std.testing.expectEqual(@as(u32, 0xE0A0), many.lo);
    try std.testing.expectEqual(@as(u32, 0xE0A3), many.hi);
    try std.testing.expectError(error.BadSymbolMap, parseCodepointRange("U+E0A3-U+E0A0"));
    try std.testing.expectError(error.BadSymbolMap, parseCodepointRange("zz"));
    try std.testing.expectError(error.BadSymbolMap, parseCodepointRange("U+110000"));

    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("U+2603", formatCodepointRange(&buf, 0x2603, 0x2603));
    try std.testing.expectEqualStrings("U+E0A0-U+E0A3", formatCodepointRange(&buf, 0xE0A0, 0xE0A3));
    // What the dialog shows is what parses back.
    const again = try parseCodepointRange(formatCodepointRange(&buf, 0xE0A0, 0xE0A3));
    try std.testing.expectEqual(@as(u32, 0xE0A0), again.lo);
    try std.testing.expectEqual(@as(u32, 0xE0A3), again.hi);
}

test "config: hint patterns are checked for compilability" {
    try std.testing.expect(hintPatternCompiles("[A-Z]+-[0-9]+"));
    try std.testing.expect(!hintPatternCompiles("[unterminated"));
    try std.testing.expect(!hintPatternCompiles("*bad"));
    // An empty pattern matches nothing; the rule is inert, not broken.
    try std.testing.expect(!hintPatternCompiles(""));
}

test "config: symbol maps add and remove, and round-trip through the file" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "symbol_map.powerline = U+E0A0-U+E0A3 Symbols Nerd Font\n");
    defer cfg.deinit();
    const arena = cfg.arena.?.allocator();

    try std.testing.expectError(error.DuplicateName, cfg.addSymbolMap(arena, "powerline", "U+1", "X"));
    try std.testing.expectError(error.NameBadChar, cfg.addSymbolMap(arena, "bad name", "U+1", "X"));
    try std.testing.expectError(error.BadSymbolMap, cfg.addSymbolMap(arena, "snow", "U+ZZ", "X"));
    try std.testing.expectEqual(@as(usize, 1), cfg.symbol_maps.items.len);

    _ = try cfg.addSymbolMap(arena, "snow", "U+2603", "DejaVu Sans");
    try std.testing.expectEqual(@as(usize, 2), cfg.symbol_maps.items.len);
    try std.testing.expect(cfg.findSymbolMap("snow") != null);

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "symbol_map.snow = U+2603 DejaVu Sans") != null);

    var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 2), re.symbol_maps.items.len);
    try std.testing.expectEqualStrings("DejaVu Sans", re.findSymbolMap("snow").?.family);

    // Remove one, then the last — an empty list IS expressible (unlike
    // clearing `palette`), so both survive a save/load.
    try std.testing.expect(cfg.removeSymbolMap("snow"));
    try std.testing.expect(!cfg.removeSymbolMap("snow"));
    try std.testing.expect(cfg.removeSymbolMap("powerline"));
    try std.testing.expectEqual(@as(usize, 0), cfg.symbol_maps.items.len);

    var w2 = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w2);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "symbol_map.") == null);
    var empty = try Config.loadFromBytes(std.testing.allocator, w2.buffered());
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.symbol_maps.items.len);
}

test "config: a symbol map with no family is not serialised" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "symbol_map.a = U+2603 DejaVu Sans\n");
    defer cfg.deinit();
    cfg.findSymbolMap("a").?.family = "";
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    // Written with an empty family it would be `= U+2603 `, which the
    // parser rejects on the next load.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "symbol_map.a") == null);
    var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 0), re.symbol_maps.items.len);
}

test "config: hint rules add and remove, and round-trip through the file" {
    var cfg = try Config.loadFromBytes(std.testing.allocator,
        \\hint.ticket.regex = [A-Z]+-[0-9]+
        \\hint.ticket.action = command
        \\hint.ticket.command = xdg-open https://tracker/{match}
        \\
    );
    defer cfg.deinit();
    const arena = cfg.arena.?.allocator();

    try std.testing.expectError(error.DuplicateName, cfg.addHintRule(arena, "ticket"));
    try std.testing.expectError(error.NameBadChar, cfg.addHintRule(arena, "a.b"));

    const rule = try cfg.addHintRule(arena, "ip");
    // A fresh rule carries the parser's own defaults.
    try std.testing.expectEqual(HintAction.copy, rule.action);
    try std.testing.expectEqualStrings("", rule.pattern);
    rule.pattern = "[0-9]+\\.[0-9]+";
    rule.action = .paste;

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer re.deinit();
    try std.testing.expectEqual(@as(usize, 2), re.hint_rules.items.len);
    try std.testing.expectEqual(HintAction.command, re.findHintRule("ticket").?.action);
    try std.testing.expectEqualStrings("xdg-open https://tracker/{match}", re.findHintRule("ticket").?.command);
    try std.testing.expectEqual(HintAction.paste, re.findHintRule("ip").?.action);
    try std.testing.expectEqualStrings("[0-9]+\\.[0-9]+", re.findHintRule("ip").?.pattern);

    // A rule with no pattern still round-trips: the action line names it.
    const inert = try cfg.addHintRule(arena, "inert");
    _ = inert;
    var w2 = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w2);
    var re2 = try Config.loadFromBytes(std.testing.allocator, w2.buffered());
    defer re2.deinit();
    try std.testing.expect(re2.findHintRule("inert") != null);

    // Removing the last rule is expressible too.
    try std.testing.expect(cfg.removeHintRule("inert"));
    try std.testing.expect(cfg.removeHintRule("ip"));
    try std.testing.expect(cfg.removeHintRule("ticket"));
    try std.testing.expect(!cfg.removeHintRule("ticket"));
    var w3 = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w3);
    try std.testing.expect(std.mem.indexOf(u8, w3.buffered(), "hint.") == null);
    var empty = try Config.loadFromBytes(std.testing.allocator, w3.buffered());
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.hint_rules.items.len);
}

test "config: the hint alphabet and multi-select round-trip" {
    var cfg = try Config.loadFromBytes(std.testing.allocator, "hint_alphabet = qwerty\nhint_multiple = true\n");
    defer cfg.deinit();
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer re.deinit();
    try std.testing.expectEqualStrings("qwerty", re.hint_alphabet);
    try std.testing.expect(re.hint_multiple);
    try std.testing.expect(validHintAlphabet(re.hint_alphabet) != null);
}

test "config: every font weight the dialog can select round-trips" {
    // The Preferences combo offers 0 (font default) and 100..900; a
    // weight already in the file that is not a multiple of 100 is
    // offered back unchanged. All of them must survive a save/load.
    for ([_]u16{ 0, 100, 350, 400, 900 }) |wt| {
        var cfg = Config{};
        cfg.settings.font_weight = wt;
        cfg.settings.font_weight_bold = wt;
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try cfg.serialise(&w);
        if (wt == 0) try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "font_weight") == null);
        var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
        defer re.deinit();
        try std.testing.expectEqual(wt, re.settings.font_weight);
        try std.testing.expectEqual(wt, re.settings.font_weight_bold);
    }
}

test "config: the styled font families and box drawing round-trip" {
    var cfg = try Config.loadFromBytes(std.testing.allocator,
        \\font_family_bold = Iosevka Bold
        \\font_family_italic = Cascadia Italic
        \\font_family_bold_italic = Cascadia Bold Italic
        \\builtin_box_drawing = false
        \\
    );
    defer cfg.deinit();
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try cfg.serialise(&w);
    var re = try Config.loadFromBytes(std.testing.allocator, w.buffered());
    defer re.deinit();
    try std.testing.expectEqualStrings("Iosevka Bold", re.settings.font_family_bold);
    try std.testing.expectEqualStrings("Cascadia Italic", re.settings.font_family_italic);
    try std.testing.expectEqualStrings("Cascadia Bold Italic", re.settings.font_family_bold_italic);
    try std.testing.expect(!re.settings.builtin_box_drawing);
}

// -- [platform.<name>] sections ------------------------------------
//
// Every test below asserts RELATIVE behaviour (this platform vs the
// other one) rather than "linux applies", so the same assertions hold
// on the macOS build.

const PlatformNames = struct { mine: []const u8, other: []const u8 };

fn platformNames() !PlatformNames {
    return switch (Platform.current orelse return error.SkipZigTest) {
        .linux => .{ .mine = "linux", .other = "macos" },
        .macos => .{ .mine = "macos", .other = "linux" },
    };
}

test "config: this platform's section applies, another platform's does not" {
    const p = try platformNames();
    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        \\font_size = 10
        \\scrollback = 100
        \\
        \\[platform.{s}]
        \\font_size = 20
        \\
        \\[platform.{s}]
        \\font_size = 30
        \\scrollback = 300
        \\
    , .{ p.mine, p.other });

    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    // Ours wins over the base; theirs never lands.
    try std.testing.expectEqual(@as(u16, 20), cfg.settings.font_size);
    try std.testing.expectEqual(@as(u32, 100), cfg.settings.scrollback);
    // Both sections are retained so a save cannot drop the other
    // machine's settings.
    try std.testing.expectEqual(@as(usize, 2), cfg.platform_sections.items.len);
    try std.testing.expectEqualStrings(p.mine, cfg.platform_sections.items[0].name);
    try std.testing.expectEqualStrings(p.other, cfg.platform_sections.items[1].name);
    try std.testing.expect(cfg.platformOverridesKey("font_size"));
    try std.testing.expect(!cfg.platformOverridesKey("scrollback"));
}

test "config: app-level keys work inside a platform section" {
    // A platform section is a conditional splice of the TOP LEVEL, not
    // of a profile - so app-level keys are legal in it, unlike inside
    // [profile.<name>].
    const p = try platformNames();
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        \\[platform.{s}]
        \\cursor_shape = bar
        \\pane_gap = 8
        \\
    , .{p.mine});
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(CursorShape.bar, cfg.cursor_shape);
    try std.testing.expectEqual(@as(f32, 8), cfg.pane_gap);
}

test "config: keys of a non-matching platform are validated, not skipped" {
    // Directly: the check the parser runs for a section that is not
    // ours. An unknown key is error.UnknownKey, a bad value is the
    // value's own error - the same reports the top level gives.
    const alloc = std.testing.allocator;
    try validateTopLevelKv(alloc, "font_size", "20");
    try std.testing.expectError(error.UnknownKey, validateTopLevelKv(alloc, "font_sizee", "20"));
    try std.testing.expectError(error.BadCursorShape, validateTopLevelKv(alloc, "cursor_shape", "wedge"));
    try std.testing.expectError(error.UnknownKey, validateTopLevelKv(alloc, "host", "devbox"));

    // And through the parser: a broken line in the other platform's
    // section is reported (to stderr) yet changes nothing here, and
    // the section is still stored verbatim for the save path.
    const p = try platformNames();
    var body_buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        \\[platform.{s}]
        \\font_sizee = 20
        \\cursor_shape = wedge
        \\
    , .{p.other});
    var cfg = try Config.loadFromBytes(alloc, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 14), cfg.settings.font_size);
    try std.testing.expectEqual(CursorShape.block, cfg.cursor_shape);
    try std.testing.expectEqual(@as(usize, 2), cfg.platform_sections.items[0].lines.items.len);
}

test "config: platform sections and [profile.<name>] seeding are order-sensitive" {
    const p = try platformNames();
    var buf: [512]u8 = undefined;

    // Section BEFORE the profile: the profile is seeded from the
    // Default settings as parsed so far, which already carry the
    // platform value.
    const before = try std.fmt.bufPrint(&buf,
        \\font_size = 10
        \\
        \\[platform.{s}]
        \\font_size = 20
        \\
        \\[profile.dev]
        \\padding = 2
        \\
    , .{p.mine});
    {
        var cfg = try Config.loadFromBytes(std.testing.allocator, before);
        defer cfg.deinit();
        try std.testing.expectEqual(@as(u16, 20), cfg.profileSettings("dev").font_size);
    }

    // Section AFTER it: the profile was already seeded from 10, and
    // nothing re-seeds it. Same rule as a plain global key written
    // after a profile section.
    const after = try std.fmt.bufPrint(&buf,
        \\font_size = 10
        \\
        \\[profile.dev]
        \\padding = 2
        \\
        \\[platform.{s}]
        \\font_size = 20
        \\
    , .{p.mine});
    {
        var cfg = try Config.loadFromBytes(std.testing.allocator, after);
        defer cfg.deinit();
        try std.testing.expectEqual(@as(u16, 20), cfg.settings.font_size);
        try std.testing.expectEqual(@as(u16, 10), cfg.profileSettings("dev").font_size);
    }
}

test "config: prefix-keyed families inside a platform section" {
    const p = try platformNames();
    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        \\keybind.new_tab = <Control>t
        \\symbol_map.powerline = U+E0A0-U+E0A3 Base Font
        \\
        \\[platform.{s}]
        \\keybind.copy = <Super>c
        \\keybind.new_tab = <Super>t
        \\symbol_map.powerline = U+E0A0-U+E0A3 Mine Font
        \\
        \\[platform.{s}]
        \\keybind.copy = <Control><Shift>c
        \\symbol_map.powerline = U+E0A0-U+E0A3 Theirs Font
        \\
    , .{ p.mine, p.other });
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();

    // The list-accumulating family: a new action APPENDS, an action
    // already bound is REPLACED - exactly as at top level.
    try std.testing.expectEqual(@as(usize, 2), cfg.keybinds.items.len);
    try std.testing.expectEqualStrings("new_tab", cfg.keybinds.items[0].name);
    try std.testing.expectEqualStrings("<Super>t", cfg.keybinds.items[0].accel);
    try std.testing.expectEqualStrings("copy", cfg.keybinds.items[1].name);
    try std.testing.expectEqualStrings("<Super>c", cfg.keybinds.items[1].accel);

    // The assigning family: one entry, ours.
    try std.testing.expectEqual(@as(usize, 1), cfg.symbol_maps.items.len);
    try std.testing.expectEqualStrings("Mine Font", cfg.symbol_maps.items[0].family);
}

test "config: an unknown platform name warns, applies nothing, and is kept" {
    const body =
        \\font_size = 10
        \\
        \\[platform.plan9]
        \\font_size = 20
        \\
    ;
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u16, 10), cfg.settings.font_size);
    try std.testing.expectEqual(@as(usize, 1), cfg.platform_sections.items.len);
    try std.testing.expectEqualStrings("plan9", cfg.platform_sections.items[0].name);
    try std.testing.expect(!cfg.platformOverridesKey("font_size"));
}

test "config: platform sections round-trip through serialise and clone" {
    const p = try platformNames();
    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        \\font_size = 10
        \\
        \\[platform.{s}]
        \\font_size = 20
        \\keybind.copy = <Super>c
        \\
        \\[platform.{s}]
        \\font_size = 30
        \\
        \\[profile.dev]
        \\padding = 2
        \\
    , .{ p.mine, p.other });
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();

    var out: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&out);
    try cfg.serialise(&w);
    const text = w.buffered();

    // Sections come out verbatim, and BEFORE the profile sections so
    // the seeding they feed survives the round-trip.
    var mine_hdr_buf: [32]u8 = undefined;
    const mine_hdr = try std.fmt.bufPrint(&mine_hdr_buf, "[platform.{s}]", .{p.mine});
    var other_hdr_buf: [32]u8 = undefined;
    const other_hdr = try std.fmt.bufPrint(&other_hdr_buf, "[platform.{s}]", .{p.other});
    const mine_at = std.mem.indexOf(u8, text, mine_hdr) orelse return error.TestUnexpectedResult;
    const other_at = std.mem.indexOf(u8, text, other_hdr) orelse return error.TestUnexpectedResult;
    const prof_at = std.mem.indexOf(u8, text, "[profile.dev]") orelse return error.TestUnexpectedResult;
    try std.testing.expect(mine_at < other_at);
    try std.testing.expect(other_at < prof_at);
    try std.testing.expect(std.mem.indexOf(u8, text, "font_size = 30") != null);

    var re = try Config.loadFromBytes(std.testing.allocator, text);
    defer re.deinit();
    try std.testing.expectEqual(@as(u16, 20), re.settings.font_size);
    try std.testing.expectEqual(@as(u16, 20), re.profileSettings("dev").font_size);
    try std.testing.expectEqual(@as(usize, 2), re.platform_sections.items.len);
    try std.testing.expectEqualStrings(p.other, re.platform_sections.items[1].name);
    try std.testing.expectEqualStrings("font_size", re.platform_sections.items[1].lines.items[0].key);
    try std.testing.expectEqualStrings("30", re.platform_sections.items[1].lines.items[0].value);
    try std.testing.expectEqual(@as(usize, 1), re.keybinds.items.len);

    // A second pass is byte-identical: the serialiser is a fixed point.
    var out2: [4096]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&out2);
    try re.serialise(&w2);
    try std.testing.expectEqualStrings(text, w2.buffered());

    // clone deep-copies the sections rather than aliasing the arena.
    var cloned = try cfg.clone(std.testing.allocator);
    defer cloned.deinit();
    try std.testing.expectEqual(@as(usize, 2), cloned.platform_sections.items.len);
    try std.testing.expectEqualStrings("keybind.copy", cloned.platform_sections.items[0].lines.items[1].key);
    try std.testing.expectEqualStrings("<Super>c", cloned.platform_sections.items[0].lines.items[1].value);
}

test "config: the prefs save path keeps platform sections and flattens this platform's values" {
    const p = try platformNames();
    const c = @import("c.zig").c;
    var tmpl = "/tmp/sketerm-cfgplat-XXXXXX".*;
    const dir = c.mkdtemp(&tmpl) orelse return error.SkipZigTest;
    const base = std.mem.span(@as([*:0]u8, @ptrCast(dir)));
    var path_buf: [512:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/config.conf", .{base});
    defer _ = c.unlink(path.ptr);
    defer _ = c.rmdir(dir);

    var body_buf: [512]u8 = undefined;
    const body = try std.fmt.bufPrint(&body_buf,
        \\font_size = 10
        \\
        \\[platform.{s}]
        \\font_size = 20
        \\
        \\[platform.{s}]
        \\scrollback = 300
        \\
    , .{ p.mine, p.other });
    var cfg = try Config.loadFromBytes(std.testing.allocator, body);
    defer cfg.deinit();
    try cfg.save(path);

    var re = try Config.loadFromPath(std.testing.allocator, path);
    defer re.deinit();
    // Both sections survived the write.
    try std.testing.expectEqual(@as(usize, 2), re.platform_sections.items.len);
    try std.testing.expectEqualStrings("scrollback", re.platform_sections.items[1].lines.items[0].key);
    // Behaviour on THIS platform is unchanged by the save.
    try std.testing.expectEqual(@as(u16, 20), re.settings.font_size);

    // The documented lossy part, pinned so a change to it is
    // deliberate: `font_size = 10` is gone from the top level - the
    // saved file carries the effective (platform) value there, so the
    // OTHER platform would now start from 20 rather than 10.
    var saved: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&saved);
    try cfg.serialise(&w);
    const text = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, "font_size = 10") == null);
    const hdr_at = std.mem.indexOf(u8, text, "[platform.") orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, text[0..hdr_at], "font_size = 20") != null);
}

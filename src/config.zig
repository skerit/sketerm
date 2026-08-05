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
const lsp_servers = @import("lsp/servers.zig");

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

    /// Deep-copy every heap-backed field into `arena`.
    pub fn cloneInto(self: *const ProfileSettings, arena: std.mem.Allocator) error{OutOfMemory}!ProfileSettings {
        var out = self.*;
        if (self.font_path) |s| out.font_path = try arena.dupe(u8, s);
        out.font_family = try arena.dupe(u8, self.font_family);
        out.editor_font_family = try arena.dupe(u8, self.editor_font_family);
        out.font_features = try arena.dupe(u8, self.font_features);
        out.scheme = try arena.dupe(u8, self.scheme);
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

/// When to ask "are you sure?" before destroying panes / tabs.
/// Matches Terminator's `ask_before_closing` semantics:
///   never    — close immediately, no dialog
///   multiple — only ask when there's >1 pane in the closing target
///   always   — ask on every close
pub const ConfirmClose = enum { never, multiple, always };

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

    /// Minimum WCAG contrast ratio between text and its cell
    /// background, 1.0 (off) .. 21.0. Text falling below the
    /// threshold snaps to white or black, whichever reads better.
    /// Kitty calls this text_fg_override_threshold; ghostty
    /// minimum-contrast.
    minimum_contrast: f32 = 1.0,

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
        out.background_image = try arena.dupe(u8, self.background_image);
        out.word_chars = try arena.dupe(u8, self.word_chars);
        out.gtk_theme = try arena.dupe(u8, self.gtk_theme);
        out.app_keyboard_layout = try arena.dupe(u8, self.app_keyboard_layout);
        out.gpu_apps = try arena.dupe(u8, self.gpu_apps);
        out.mux_udp_port_range = try arena.dupe(u8, self.mux_udp_port_range);
        out.default_profile = try arena.dupe(u8, self.default_profile);
        out.editor_theme = try arena.dupe(u8, self.editor_theme);
        out.editor_project_markers = try arena.dupe(u8, self.editor_project_markers);
        out.keybinds = .empty;
        try out.keybinds.ensureTotalCapacity(arena, self.keybinds.items.len);
        for (self.keybinds.items) |kb| {
            out.keybinds.appendAssumeCapacity(.{
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
        var cfg = Config{};
        const resolved: ?[]u8 = if (override_path) |p|
            allocator.dupe(u8, p) catch null
        else
            resolveConfigPath(allocator);
        if (resolved) |path| {
            defer allocator.free(path);
            // Zig 0.16's `std.fs` requires an `Io` instance we don't
            // thread through here. Just use libc — we link it anyway.
            const c = @import("c.zig").c;
            // path is allocator-owned and not necessarily NUL-terminated;
            // copy onto a stack buffer with a trailing 0.
            var path_z: [4096]u8 = undefined;
            if (path.len >= path_z.len) {
                warnConfig("config path too long: {s}", .{path});
            } else {
                @memcpy(path_z[0..path.len], path);
                path_z[path.len] = 0;
                const fp = c.fopen(@ptrCast(&path_z), "rb");
                if (fp == null) {
                    if (override_path != null) {
                        warnConfig("--config path {s} not readable, using defaults", .{path});
                    }
                } else {
                    defer _ = c.fclose(fp);
                    const max_bytes: usize = 64 * 1024;
                    var buf: [max_bytes]u8 = undefined;
                    const n = c.fread(&buf, 1, buf.len, fp);
                    if (n == buf.len and c.feof(fp) == 0) {
                        warnConfig("{s} larger than 64 KiB; trailing settings ignored", .{path});
                    }
                    cfg.arena = std.heap.ArenaAllocator.init(allocator);
                    parseInto(&cfg, buf[0..n]) catch {
                        warnConfig("parse error in {s}, using defaults", .{path});
                        cfg.deinit();
                        cfg = Config{};
                    };
                }
            }
        }

        // Env overrides — highest priority. Applied to the Default
        // settings only; named profiles keep their own values.
        if (@import("util/profile.zig").getenv("SKETERM_SCROLLBACK")) |env| {
            if (std.fmt.parseInt(u32, env, 10)) |n| cfg.settings.scrollback = n else |_| {}
        }
        if (@import("util/profile.zig").getenv("SKETERM_FONT")) |env_path| {
            if (cfg.arena == null) cfg.arena = std.heap.ArenaAllocator.init(allocator);
            const arena = cfg.arena.?.allocator();
            cfg.settings.font_path = arena.dupe(u8, env_path) catch cfg.settings.font_path;
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
    /// the format round-trips through `loadFromBytes` exactly. Uses
    /// libc since Zig 0.16's `std.fs` now needs an `Io` instance we
    /// don't thread through here.
    pub fn save(self: *const Config, path: []const u8) !void {
        const c = @import("c.zig").c;
        try makeParentDirs(path);

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
        if (!std.mem.eql(u8, s.font_features, base.font_features))
            try w.print("font_features = {s}\n", .{s.font_features});
        if (s.font_size != base.font_size) try w.print("font_size = {d}\n", .{s.font_size});
        if (!std.mem.eql(u8, s.editor_font_family, base.editor_font_family))
            try w.print("editor_font_family = {s}\n", .{s.editor_font_family});
        if (s.editor_font_size != base.editor_font_size)
            try w.print("editor_font_size = {d}\n", .{s.editor_font_size});
        if (s.line_pad_px != base.line_pad_px) try w.print("line_pad_px = {d}\n", .{s.line_pad_px});
        if (s.padding != base.padding) try w.print("padding = {d:.2}\n", .{s.padding});

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
            if (s.palette) |pal| {
                try w.writeAll("palette = ");
                for (pal, 0..) |rgb, i| {
                    if (i != 0) try w.writeAll(":");
                    try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] });
                }
                try w.writeAll("\n");
            }
            // null-while-base-set isn't expressible in the format;
            // the parse-time seed keeps base's palette in that case.
        }

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

        // Inactive pane dimming.
        if (self.inactive_darken != 0.2)
            try w.print("inactive_darken = {d:.2}\n", .{self.inactive_darken});
        if (self.inactive_desaturate != 0.0)
            try w.print("inactive_desaturate = {d:.2}\n", .{self.inactive_desaturate});
        if (self.minimum_contrast != 1.0)
            try w.print("minimum_contrast = {d:.2}\n", .{self.minimum_contrast});

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
        if (current_lsp) |srv| {
            applyLspKv(srv, arena, key, value) catch |err| {
                warnConfigAt(lineno, "lsp '{s}': bad value for '{s}' ({s})", .{ srv.name, key, @errorName(err) });
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
            applyKv(cfg, arena, key, value) catch |err| {
                warnConfigAt(lineno, "bad value for '{s}' ({s})", .{ key, @errorName(err) });
            };
        }
    }
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
    if (std.mem.eql(u8, key, "shell")) {
        s.shell = try expandTilde(arena, value);
    } else if (std.mem.eql(u8, key, "font") or std.mem.eql(u8, key, "font_path")) {
        s.font_path = try expandTilde(arena, value);
    } else if (std.mem.eql(u8, key, "font_family")) {
        s.font_family = try arena.dupe(u8, value);
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
        // Unknown key — warn but don't abort.
        warnConfig("unknown key '{s}' (ignoring)", .{key});
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

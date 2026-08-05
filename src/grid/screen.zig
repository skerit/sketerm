//! Screen — active + alternate screen buffers, scrollback, cursor,
//! and the apply functions that consume parser events.
//!
//! v1 cuts:
//!   - Single (active) buffer for first cut; alternate buffer added
//!     when DECSET 1049 is wired.
//!   - Scrollback stub (in-place capacity, no eviction yet).

const std = @import("std");
const Cell = @import("cell.zig").Cell;
const Flags = @import("cell.zig").Flags;
const flagsToU8 = @import("cell.zig").flagsToU8;
const flagsFromU8 = @import("cell.zig").flagsFromU8;
const Line = @import("line.zig").Line;
const style_pool = @import("style_pool.zig");
const Pool = style_pool.Pool;
const Entry = style_pool.Entry;
const Attrs = style_pool.Attrs;
const Color = style_pool.Color;
const Event = @import("../parser/event.zig").Event;
const utf8 = @import("../util/utf8.zig");
const palette_default_256 = @import("palette.zig").default_256;
const kitty_ph = @import("kitty_placeholder.zig");

pub const CMD_ZONE_CAP = 64;

/// A completed OSC 133 C/D command-output zone. Stored as stable
/// line IDs; 0/0 = empty slot.
pub const CmdZone = extern struct {
    start_id: u64 = 0,
    end_id: u64 = 0,
    exit: i32 = 0,
    _pad: i32 = 0,
};

/// A command zone resolved to display-buffer rows (negative =
/// scrollback). Output rows are [start_row, end_row).
pub const CmdZoneRows = struct {
    start_row: i32,
    end_row: i32,
    exit: i32,
};

/// Upper bound on distinct `OSC 1337 ; SetUserVar` names; keeps a
/// runaway app from growing the store without limit.
pub const USER_VAR_CAP = 64;

/// One iTerm2 user variable. Both slices are GPA-owned.
pub const UserVar = struct {
    name: []u8,
    value: []u8,
};

/// Built-in selection highlight color (RGBA) used when no OSC 17 /
/// OSC 21 override is set. Must match the grid_pass selection quad.
pub const default_selection_bg: [4]f32 = .{ 0.4, 0.55, 0.85, 0.45 };

/// A kitty Unicode-placeholder virtual placement: the image is laid
/// out across `rows` × `cols` cells. 0 = "derive from the image's
/// native pixel size and the cell size".
pub const VirtualPlacement = struct {
    rows: u32 = 0,
    cols: u32 = 0,
    placement_id: u32 = 0,
};

/// A placeholder cell mid-assembly: base char printed at (screen_row,
/// screen_col); up to three diacritics decode the image-cell row,
/// column, and id high-byte.
pub const PendingPlaceholder = struct {
    screen_row: u16,
    screen_col: u16,
    /// Image id from the cell foreground (low 24 bits); the 3rd
    /// diacritic may OR in the high byte at flush time.
    image_id: u32,
    diac: [3]u32 = .{ 0, 0, 0 },
    n_diac: u8 = 0,
};

/// Coordinates of the most recently emitted placeholder tile, for the
/// auto-increment of a following diacritic-less cell.
pub const LastPlaceholder = struct {
    screen_row: u16,
    screen_col: u16,
    image_id: u32,
    img_row: u32,
    img_col: u32,
};

pub const Screen = struct {
    cols: u16,
    rows: u16,

    /// Active screen rows (cols cells each).
    active: []Line,
    /// Alternate screen (lazily allocated).
    alt: ?[]Line = null,
    use_alt: bool = false,

    /// Scrollback ring — receives lines scrolled off the top of the
    /// main screen. Capped at `scrollback_capacity`. Once at cap, new
    /// pushes overwrite the oldest slot in place (O(1) eviction)
    /// rather than shifting the whole ArrayList — that cost was
    /// 50µs per evict on a 10k cap, dominating the parser bench.
    /// `scrollback_head` is the index of the oldest entry; once
    /// `items.len == capacity` the buffer behaves as a ring.
    scrollback: std.ArrayList(Line) = .empty,
    scrollback_head: usize = 0,
    scrollback_capacity: usize = 10_000,
    /// Rendering offset (0 = bottom, > 0 = scrolled up by N lines).
    view_offset: u32 = 0,
    /// When true, any output (printCp / scrollUp / lineFeed) snaps
    /// view_offset back to 0. Off by default — matches xterm.
    /// Mirrors gnome-terminal's "scroll on output" toggle.
    scroll_on_output: bool = false,
    /// Gate for the tab-activity signal (config `track_tab_activity`).
    /// When false, the drain skips the visible-change check entirely.
    track_activity: bool = true,
    /// Punctuation chars considered "part of a word" for double-click
    /// selection. Default is sensible for paths + URLs. Set from
    /// Config.word_chars at pane spawn / applyConfigChange.
    word_chars: []const u8 = "-_.,/?:@&=+%~",
    /// Set by onChildEof when the PTY child has exited. Pane.onTick
    /// reads this on the next frame and acts per Window.exit_action,
    /// then clears the flag (so we don't re-fire). Stays false on
    /// alt-screen swaps.
    child_exited: bool = false,
    child_exit_status: i32 = 0,

    /// Cursor position, 0-indexed.
    row: u16 = 0,
    col: u16 = 0,

    /// Saved cursor (DECSC / DECRC).
    saved_row: u16 = 0,
    saved_col: u16 = 0,
    saved_style: u16 = 0,
    saved_origin: bool = false,
    saved_autowrap: bool = true,
    saved_charset_g0: Charset = .ascii,
    saved_charset_g1: Charset = .ascii,
    saved_active_charset: ActiveCharset = .g0,
    /// Saved OSC 8 link state. Apps that nest OSC 8 across DECSC/DECRC
    /// boundaries get the right link reapplied on restore.
    saved_link_id: u8 = 0,

    /// Current SGR-derived style index.
    cur_style: u16 = 0,

    /// Scroll region (DECSTBM). Inclusive bounds.
    scroll_top: u16 = 0,
    scroll_bot: u16,

    /// Modes.
    autowrap: bool = true,
    origin_mode: bool = false,
    insert_mode: bool = false,
    /// DECSET 2004 — bracketed paste.
    bracketed_paste: bool = false,
    /// OSC 52 read queries allowed (config `clipboard_read = allow`).
    /// Off by default: any app on the PTY could exfiltrate the
    /// clipboard. Denied queries get an empty reply.
    allow_clipboard_read: bool = false,
    /// Mode 2031 — push a `CSI ? 997 ; 1|2 n` report when the color
    /// scheme flips dark/light (notifyColorScheme).
    mode_2031: bool = false,
    /// Mode 2048 — in-band resize reports: `CSI 48;rows;cols;hpx;wpx t`
    /// immediately on set and after every resize.
    in_band_resize: bool = false,
    /// Current scheme as the GUI last pushed it (bg luminance).
    /// Answers `CSI ? 996 n`; true until the GUI says otherwise.
    color_scheme_dark: bool = true,
    /// Mux mirror screens: the daemon's authoritative Screen answers
    /// every protocol query — a mirror replying too would double
    /// every response the app sees. respond() no-ops when set;
    /// GUI-owned replies (clipboard read, color-scheme) use
    /// respondForce instead.
    mute_responses: bool = false,
    /// Mux daemon screens: skip the queries only the GUI can answer
    /// (OSC 52 read, DSR ?996) so the attached mirror replies alone.
    defer_gui_queries: bool = false,
    /// LNM (mode 20) — when set, LF / VT / FF also perform CR (move
    /// cursor to column 0 in addition to advancing a row). Mostly a
    /// historical mode but a few apps set it explicitly.
    line_feed_mode: bool = false,

    /// xterm window-title stack (CSI 22/23 t). tmux + screen use it
    /// to swap titles when nested. Cap of 8 entries; older pushes
    /// drop. Each entry is an owned UTF-8 byte slice.
    title_stack: [8]?[]u8 = [_]?[]u8{null} ** 8,
    title_stack_depth: u8 = 0,
    /// Most recently set title (via OSC 0/2). Owned. Used by the
    /// title-stack save/restore.
    last_title: ?[]u8 = null,
    /// Display name of the active font, surfaced via OSC 50 ; ?
    /// queries. Set externally (Pane.attachFont). Empty string means
    /// "we'll respond with a generic Monospace string".
    font_name: []const u8 = "",
    /// Cell pixel size — set by Pane.onResize. CSI 14t reports
    /// `rows*cell_pixel_h` and `cols*cell_pixel_w`. Zero falls back
    /// to the legacy 8/16 approximation.
    cell_pixel_w: u16 = 0,
    cell_pixel_h: u16 = 0,
    /// DECSET 1004 — focus reporting.
    focus_reports: bool = false,
    /// DECCKM (mode 1) — application cursor keys (arrows emit
    /// `ESC O X` instead of `ESC [ X`).
    app_cursor_keys: bool = false,
    /// DECPAM / DECPNM (ESC = / ESC >) — application keypad mode.
    /// Numpad keys emit `ESC O p..y` instead of digits when set.
    app_keypad: bool = false,
    /// DECSET 25 — cursor visibility.
    cursor_visible: bool = true,
    /// DECSCUSR cursor shape.
    cursor_shape: CursorShape = .block_blink,
    /// Blink phase — true=visible, false=hidden. Toggled by the
    /// rendering layer when the shape is a blinking variant.
    cursor_blink_on: bool = true,
    /// Mouse mode (1000/1002/1003) — last-set value.
    mouse_mode: u16 = 0,
    /// Mouse encoding (1006/1015 etc).
    mouse_sgr: bool = false,
    /// Mouse-encoding flavour: legacy X10 default; promoted by
    /// DECSET 1005 (UTF-8), 1006 (SGR — kept in sync with mouse_sgr
    /// for back-compat), 1015 (urxvt), 1016 (SGR pixel).
    mouse_enc: MouseEnc = .legacy,
    /// Pending SS2 / SS3 single-shift consumed by the next printCp.
    pending_single_shift: PendingSingleShift = .none,
    /// DECSET 2026 — synchronized output. While on, the renderer
    /// suppresses redraws so the app can stage a multi-step update
    /// and have it appear atomically. Reset triggers an immediate
    /// redraw via the dirty flag.
    sync_output: bool = false,

    /// Pending wrap: cursor "logically" past col cols-1, awaiting
    /// next print to actually wrap. Matches xterm semantics.
    pending_wrap: bool = false,

    /// UTF-8 reassembly for `print_byte` events.
    decoder: utf8.Decoder = .{},

    /// Set on any state change; cleared by the renderer after using.
    dirty: bool = true,

    /// Selection (mouse drag).
    selection: @import("selection.zig").Selection = .{},

    /// Copy-mode cursor (keyboard-driven selection). Display-buffer
    /// coordinates: row 0..rows-1 = active screen, negative =
    /// scrollback (-1 = bottom-most line). Window owns the mode and
    /// drives this; null = copy mode inactive. Renderer draws a
    /// hollow amber block at this cell.
    copy_cursor: ?CopyCursor = null,

    /// Scrollback search results — when non-empty, the renderer
    /// overlays a translucent highlight on every match. The Window
    /// owns the SearchMatch buffer separately for navigation; this
    /// view is just for rendering. `search_active_idx` is the index
    /// of the currently-selected match (rendered brighter).
    search_highlights: []const SearchMatch = &.{},
    search_active_idx: i32 = -1,

    /// Keyboard-hints overlays (quick-select mode). When non-empty,
    /// the renderer draws a label badge at each match start plus a
    /// translucent highlight over its range. The Window owns the
    /// buffer; rows are DISPLAY rows captured at collect time.
    hints_overlay: []const HintOverlay = &.{},

    /// Image-placement retention for mux snapshots. The GUI keeps
    /// placements in the per-pane ImageStore; the headless daemon
    /// has no panes, so when `retain_images` is set every on_image
    /// emission is also copied here (capped, oldest evicted) and the
    /// snapshot carries the list so reattach restores images.
    retain_images: bool = false,
    retained_images: std.ArrayList(RetainedImage) = .empty,
    retained_image_bytes: usize = 0,

    /// Predictive-echo overlay (remote panes). Speculative glyphs
    /// drawn underlined at active-screen cells until the real echo
    /// arrives; the Terminal's Predictor owns the buffer and keeps
    /// it empty unless display is warranted.
    predictions_overlay: []const @import("../mux/predict.zig").Cell = &.{},

    pool: *Pool,
    allocator: std.mem.Allocator,

    /// OSC 8 hyperlinks. `current_link_id` is the id stamped on
    /// cells written while a link is active; 0 means no link.
    /// `links` stores id → URI. Cap of 255 distinct active ids
    /// (Cell.reserved is u8); on overflow, ids wrap and replace.
    current_link_id: u8 = 0,
    next_link_id: u8 = 1,
    links: std.AutoHashMap(u8, []u8),

    /// IME preedit (composition-in-progress). UTF-8, owned. Empty
    /// when no composition active. Renderer overlays at cursor.
    preedit_text: ?[]u8 = null,

    /// Microsecond timestamp when BEL was last received. Renderer
    /// flashes a translucent white overlay for ~200ms after.
    bell_at_us: i64 = 0,

    /// Last printed codepoint (for REP, CSI Pn b). 0 = none.
    last_print_cp: u32 = 0,
    /// Position of the cell that received `last_print_cp`. Used by
    /// the cluster store to attach extending codepoints (combining
    /// marks, ZWJ continuations, skin-tone modifiers) to the right
    /// cell. row-encoded as (u32(row) << 16) | u32(col).
    last_print_key: u32 = 0,
    /// Cluster store: `(row << 16) | col` → list of extending
    /// codepoints stamped onto that cell. Persists until the cell
    /// is overwritten, the line is cleared, or content scrolls off.
    /// Selection extraction reads from here to emit full grapheme
    /// clusters; the renderer ignores them and draws the base only.
    clusters: std.AutoHashMap(u32, std.ArrayList(u32)),

    /// Kitty graphics receive-side state (chunked transmissions,
    /// stored images for separate place actions, PNG decode).
    kitty_images: @import("kitty_images.zig").Manager,

    /// Kitty Unicode-placeholder virtual placements, keyed by image_id.
    /// A `U=1` placement registers here instead of drawing at the
    /// cursor; U+10EEEE cells later tile the image across the grid.
    virtual_placements: std.AutoHashMap(u32, VirtualPlacement),
    /// The placeholder cell currently being assembled (base printed,
    /// diacritics still arriving). Finalized into an image tile by
    /// `flushPlaceholder` when the next base char or non-print event
    /// lands. Null when not mid-placeholder.
    ph_pending: ?PendingPlaceholder = null,
    /// The last finalized placeholder tile — drives auto-increment for
    /// the next cell when it omits row/column diacritics.
    ph_last: ?LastPlaceholder = null,

    /// Default fg / bg / cursor color overrides, RGBA in 0..1.
    /// Set via OSC 10 / 11 / 12, reset via OSC 110 / 111 / 112.
    /// Renderer syncs from these. cursor_color all-zero = use fg.
    default_fg: [4]f32 = .{ 0.92, 0.92, 0.92, 1.0 },
    default_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 },
    cursor_color: [4]f32 = .{ 0, 0, 0, 0 },
    /// What OSC 110/111 reset to — the CONFIGURED defaults, kept
    /// separate because OSC 10/11 mutate default_fg/bg directly.
    /// The Window sets these alongside default_fg/bg.
    configured_fg: [4]f32 = .{ 0.92, 0.92, 0.92, 1.0 },
    configured_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 },

    /// Selection (highlight) colors. Set via OSC 17 (bg) / 19 (fg),
    /// reset via OSC 117 / 119. Sentinel alpha=0 = "unset": the
    /// renderer falls back to its built-in translucent highlight and
    /// leaves selected-cell foreground untouched.
    selection_bg: [4]f32 = .{ 0, 0, 0, 0 },
    selection_fg: [4]f32 = .{ 0, 0, 0, 0 },

    /// iTerm2 `OSC 1337 ; SetUserVar=name=<b64value>` store. A small
    /// app→terminal key/value channel (status bars, IPC). Names cap at
    /// USER_VAR_CAP entries; setting an existing name overwrites it,
    /// an empty value clears it. Owned by the GPA, freed in deinit.
    user_vars: std.ArrayList(UserVar) = .empty,

    /// Runtime 256-color palette (overrides the comptime defaults).
    /// Set via OSC 4 ; n ; rgb:... ; reset via OSC 104.
    palette: [256][3]u8 = palette_default_256,

    /// Prompt-mark scrollback rows reported by OSC 133 ; A. Ring
    /// of the last 256 prompt rows for future "jump to previous
    /// prompt" navigation.
    /// Stable line IDs. Incremented at every new-line birth (init,
    /// scroll, scrollback push, alt-screen swap, reflow). prompt_marks
    /// stores IDs (not display rows) so they survive scrolling.
    next_line_id: u64 = 1,
    prompt_marks: [256]u64 = [_]u64{0} ** 256,
    prompt_marks_len: u16 = 0,
    prompt_marks_head: u16 = 0,

    /// OSC 133 command-output zones. C captures the line where the
    /// command's output begins; D closes the zone (output rows are
    /// [C-row, D-row), the D row holds the next prompt). Stored as
    /// stable line IDs so the zone survives scrolling into scrollback.
    /// `last_*` describe the most recently COMPLETED command.
    pending_output_start_id: u64 = 0,
    /// C arrived mid-line (bash's DEBUG trap fires before the shell's
    /// accept-line newline is echoed): the zone start is the NEXT
    /// line, captured at the following linefeed so the echoed command
    /// row stays out of the extracted output.
    pending_output_awaits_nl: bool = false,
    last_output_start_id: u64 = 0,
    last_output_end_id: u64 = 0,
    /// Exit status from `OSC 133 ; D ; <code>` (0 when not reported).
    last_cmd_exit: i32 = 0,
    /// Monotonic completed-command identity for mux clients waiting
    /// across snapshots without mistaking output quiescence for exit.
    cmd_completion_seq: u64 = 0,

    /// Ring of completed command zones (command-block UX: gutter
    /// marks, click-to-select, failed-command minimap). extern so the
    /// renderer can hash the raw bytes without padding UB. Zone rows
    /// have line IDs in [start_id, end_id) — IDs are birth-ordered,
    /// so display-row membership is an ID range check.
    cmd_zones: [CMD_ZONE_CAP]CmdZone = [_]CmdZone{.{}} ** CMD_ZONE_CAP,
    cmd_zones_len: u16 = 0,
    cmd_zones_head: u16 = 0,

    /// OSC 99 (kitty desktop notifications) accumulator. Chunks with
    /// the same identifier append payload parts until `d` signals
    /// done; a different identifier discards the unfinished one.
    /// Transient — not snapshotted.
    notify_id: [64]u8 = undefined,
    notify_id_len: u8 = 0,
    notify_title: std.ArrayList(u8) = .empty,
    notify_body: std.ArrayList(u8) = .empty,
    /// U+2028-separated button labels (p=buttons payload).
    notify_buttons: std.ArrayList(u8) = .empty,
    /// Raw image bytes for the notification icon (p=icon payload).
    notify_icon_data: std.ArrayList(u8) = .empty,
    /// Decoded themed-icon name (metadata key n, first one kept).
    notify_icon_name: std.ArrayList(u8) = .empty,
    notify_urgency: ?u8 = null,
    notify_report: bool = false,
    notify_focus: bool = true,
    notify_occasion: NotificationEvent.Occasion = .always,

    /// modifyOtherKeys level (CSI > 4 ; Pp m). 0=off, 1=ambiguous
    /// only, 2=all printable. Input encoder hasn't wired this yet.
    modify_other_keys: u8 = 0,

    /// DECSCNM — reverse-video mode. Renderer swaps default fg ↔ bg
    /// (and inverts cells with .default colors) when set. Off resets
    /// to normal.
    reverse_screen: bool = false,

    /// DECSET 40 = "allow 80↔132 column switching". When set,
    /// DECSET/DECRST 3 (DECCOLM) actually resizes the screen to
    /// 132 / 80 columns. xterm-compat default is OFF.
    allow_decolm: bool = false,

    /// Kitty progressive-enhancement keyboard flags. Bitmask:
    /// 0x01 disambiguate, 0x02 events, 0x04 alt-keys, 0x08 all-keys,
    /// 0x10 associated-text. `CSI > N u` pushes, `CSI < N u` pops,
    /// `CSI = N ; M u` sets/ors/clears without touching the stack.
    /// Stack depth 9.
    kitty_kbd_flags: u8 = 0,
    kitty_kbd_stack: [9]u8 = [_]u8{0} ** 9,
    kitty_kbd_depth: u8 = 0,
    /// The same three values for the buffer that is NOT active: the
    /// protocol keeps separate stacks per screen, so a full-screen app
    /// cannot leak its flags to the shell it returns to. Swapped by
    /// `toggleAltScreen`.
    kitty_kbd_other_flags: u8 = 0,
    kitty_kbd_other_stack: [9]u8 = [_]u8{0} ** 9,
    kitty_kbd_other_depth: u8 = 0,

    /// Custom tab stops. One bool per column, true = stop set.
    /// Default: every 8th column starting at 0.
    tab_stops: std.ArrayList(bool) = .empty,

    /// G0/G1 character-set designations. ASCII or DEC special graphics.
    charset_g0: Charset = .ascii,
    charset_g1: Charset = .ascii,
    /// Which slot is locked-shift active. SO/SI swap this.
    active_charset: ActiveCharset = .g0,

    /// Side-effect sink — optional callbacks invoked by apply.
    sink: Sink = .{},

    pub const CursorShape = enum {
        block_blink,
        block_steady,
        underline_blink,
        underline_steady,
        bar_blink,
        bar_steady,
    };

    pub const Charset = enum { ascii, dec_graphics };
    pub const ActiveCharset = enum { g0, g1 };

    /// SS2 (ESC N) and SS3 (ESC O) single-shift the next printable
    /// codepoint into G2 / G3 respectively. We don't model G2/G3
    /// charsets, so the shift is consumed without effect — but the
    /// flag has to exist so the parser-level escape doesn't leak.
    pub const PendingSingleShift = enum { none, ss2, ss3 };

    /// Mouse-event encoding format. Apps select one via DECSET
    /// 1005/1006/1015/1016 (mutually exclusive in practice — last
    /// set wins). `legacy` is the X10 byte-tuple format.
    pub const MouseEnc = enum {
        legacy, // ESC [ M Cb Cx Cy (3 bytes after M; +32 each)
        utf8, // 1005 — same shape but Cx/Cy UTF-8 to allow >223
        sgr, // 1006 — ESC [ < b ; col ; row M/m (M=press, m=release)
        urxvt, // 1015 — ESC [ b+32 ; col ; row M
        sgr_pixel, // 1016 — like SGR but col/row in pixels
    };

    /// DEC special graphics translation. Only applies to bytes
    /// 0x60..0x7E in the ASCII range; outside that range the byte
    /// passes through unchanged.
    fn decGraphicsCp(b: u8) u32 {
        return switch (b) {
            0x5F => ' ',
            0x60 => 0x25C6, // ◆
            0x61 => 0x2592, // ▒
            0x66 => 0x00B0, // °
            0x67 => 0x00B1, // ±
            0x68 => 0x2424, // ␤
            0x69 => 0x240B, // ␋
            0x6A => 0x2518, // ┘
            0x6B => 0x2510, // ┐
            0x6C => 0x250C, // ┌
            0x6D => 0x2514, // └
            0x6E => 0x253C, // ┼
            0x6F => 0x23BA, // ⎺
            0x70 => 0x23BB, // ⎻
            0x71 => 0x2500, // ─
            0x72 => 0x23BC, // ⎼
            0x73 => 0x23BD, // ⎽
            0x74 => 0x251C, // ├
            0x75 => 0x2524, // ┤
            0x76 => 0x2534, // ┴
            0x77 => 0x252C, // ┬
            0x78 => 0x2502, // │
            0x79 => 0x2264, // ≤
            0x7A => 0x2265, // ≥
            0x7B => 0x03C0, // π
            0x7C => 0x2260, // ≠
            0x7D => 0x00A3, // £
            0x7E => 0x00B7, // ·
            else => b,
        };
    }

    pub const Sink = struct {
        ctx: ?*anyopaque = null,
        on_title: ?*const fn (ctx: ?*anyopaque, title: []const u8) void = null,
        on_bell: ?*const fn (ctx: ?*anyopaque) void = null,
        on_write_pty: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void = null,
        on_clipboard_set: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
        on_cwd: ?*const fn (ctx: ?*anyopaque, cwd: []const u8) void = null,
        on_image: ?*const fn (ctx: ?*anyopaque, img: ImageEvent) void = null,
        on_notification: ?*const fn (ctx: ?*anyopaque, ev: NotificationEvent) void = null,
        /// ConEmu progress report `OSC 9 ; 4 ; st ; pr` (emitted by
        /// zig build, systemd, PowerShell, ...). st: 0 clear,
        /// 1 normal, 2 error, 3 indeterminate, 4 paused; pr 0-100.
        on_progress: ?*const fn (ctx: ?*anyopaque, state: u8, percent: u8) void = null,
        /// Kitty delete dispatch with full delete-action context.
        on_image_delete_full: ?*const fn (ctx: ?*anyopaque, ev: ImageDeleteEvent) void = null,
        /// OSC 22 ; <name> — set X11 / GTK mouse-cursor shape. Names
        /// follow the X cursor font ("hand2", "watch", "crosshair",
        /// "text", "default", etc.); GTK accepts the same set via
        /// `gtk_widget_set_cursor_from_name`.
        on_pointer_shape: ?*const fn (ctx: ?*anyopaque, name: []const u8) void = null,
        /// DECANM toggle (DECSET/DECRST 2). When `set == false`,
        /// the parser switches into VT52 mode; when true, returns to
        /// ANSI/VT100. Terminal wires this to its Parser.vt52_mode.
        on_decanm: ?*const fn (ctx: ?*anyopaque, ansi: bool) void = null,
        /// OSC 52 read query (`OSC 52 ; Pc ; ?`). Only fired when
        /// `allow_clipboard_read` is set; the sink must answer
        /// asynchronously with `OSC 52 ; <sel> ; <base64>` via
        /// write-pty. `selection` is 'c' (clipboard) or 'p' (primary).
        on_clipboard_get: ?*const fn (ctx: ?*anyopaque, selection: u8) void = null,
        /// OSC 1337 ; SetProfile=<name> — app requests this pane adopt
        /// a configured profile. Untrusted: the GUI maps an unknown
        /// name to the Default profile.
        on_set_profile: ?*const fn (ctx: ?*anyopaque, name: []const u8) void = null,
        /// OSC 133/633 `C` — a command's output began (running).
        on_cmd_start: ?*const fn (ctx: ?*anyopaque) void = null,
        /// OSC 133/633 `D` — the command-output zone closed. Only
        /// fires when a matching `C` opened a zone (a bare `D` after
        /// attach mid-command is dropped, like the zone itself).
        on_cmd_end: ?*const fn (ctx: ?*anyopaque, exit: i32) void = null,
    };

    /// Desktop-notification request flowing out of the screen. All
    /// slices are borrowed — valid only for the duration of the sink
    /// call. Simple producers (OSC 9 / 777 / 1337) fill title/body
    /// and leave the rest defaulted; OSC 99 fills everything.
    pub const NotificationEvent = struct {
        pub const Occasion = enum { always, unfocused, invisible };

        /// Sanitized identifier ([A-Za-z0-9_+.-], ≤64) — used to
        /// replace/withdraw and echoed in activation reports.
        id: []const u8 = "",
        title: []const u8 = "",
        body: []const u8 = "",
        /// Themed icon name (OSC 99 metadata key n, decoded).
        icon_name: []const u8 = "",
        /// Raw image bytes (PNG/JPEG/GIF) for the icon (p=icon).
        icon_data: []const u8 = "",
        /// Button labels separated by U+2028 (0xE2 0x80 0xA8).
        buttons_raw: []const u8 = "",
        /// 0 = low, 1 = normal, 2 = critical. Null = unspecified.
        urgency: ?u8 = null,
        /// App asked for an activation report (`a=report`): clicking
        /// the notification (or button N) must echo
        /// `OSC 99 ; i=<id> ; [N]` back to the PTY.
        want_report: bool = false,
        /// Focus the originating pane on activation (default on).
        want_focus: bool = true,
        /// When to actually show (o= key).
        occasion: Occasion = .always,
        /// p=close — withdraw the notification with this id instead
        /// of showing anything.
        close: bool = false,
    };

    /// Keep only the characters the OSC 99 spec allows in
    /// identifiers, so a hostile id can't inject escape data when
    /// echoed in reports. Returns the (possibly shorter) sanitized
    /// prefix written into `out`.
    pub fn sanitizeNotifyId(id: []const u8, out: []u8) []const u8 {
        var n: usize = 0;
        for (id) |ch| {
            if (n >= out.len) break;
            const ok = (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
                (ch >= '0' and ch <= '9') or ch == '_' or ch == '-' or ch == '+' or ch == '.';
            if (ok) {
                out[n] = ch;
                n += 1;
            }
        }
        return out[0..n];
    }

    /// One `a=d` request, with everything the protocol's selectors
    /// can key on. `what` is the `d=` letter; its case decides only
    /// whether the source data is freed as well, so both cases select
    /// the same placements.
    ///
    /// The selectors are: a/A all, i/I by image id, n/N by image
    /// number, c/C intersecting the cursor, p/P intersecting a cell,
    /// q/Q that cell at one z, x/X a column, y/Y a row, z/Z a
    /// z-index, r/R an id range, f/F animation frames.
    pub const ImageDeleteEvent = struct {
        /// 0 = delete-all-images. Otherwise the specific image.
        image_id: u32 = 0,
        /// 0 = any placement of the image. Otherwise specific.
        placement_id: u32 = 0,
        what: u8 = 'a',
        /// Image number for n/N.
        image_number: u32 = 0,
        /// Cell coordinates for c/C, p/P, q/Q, x/X, y/Y — already
        /// resolved to 0-based screen coordinates (the protocol's are
        /// 1-based, and c/C uses the cursor's).
        x: u32 = 0,
        y: u32 = 0,
        /// z-index for q/Q and z/Z.
        z: i32 = 0,
        /// Inclusive image-id range for r/R.
        id_lo: u32 = 0,
        id_hi: u32 = 0,

        /// Does this request select a placement of `image_id` at the
        /// given cell rectangle? The rectangle is in screen cells;
        /// callers that do not track one pass a zero-size rect and get
        /// the id-based selectors only.
        pub fn selects(
            self: ImageDeleteEvent,
            img_id: u32,
            place_id: u32,
            img_number: u32,
            z_index: i32,
            col: i32,
            row: i32,
            cols: i32,
            rows: i32,
        ) bool {
            const covers_cell = struct {
                fn f(cx: i64, cy: i64, c0: i32, r0: i32, cw: i32, rh: i32) bool {
                    if (cw <= 0 or rh <= 0) return false;
                    return cx >= c0 and cx < @as(i64, c0) + cw and
                        cy >= r0 and cy < @as(i64, r0) + rh;
                }
            }.f;
            const matches_placement = self.placement_id == 0 or place_id == self.placement_id;
            return switch (self.what) {
                'a', 'A' => true,
                'i', 'I' => img_id == self.image_id and matches_placement,
                'n', 'N' => img_number != 0 and img_number == self.image_number and matches_placement,
                'c', 'C', 'p', 'P' => covers_cell(self.x, self.y, col, row, cols, rows),
                'q', 'Q' => z_index == self.z and covers_cell(self.x, self.y, col, row, cols, rows),
                'x', 'X' => cols > 0 and @as(i64, self.x) >= col and @as(i64, self.x) < @as(i64, col) + cols,
                'y', 'Y' => rows > 0 and @as(i64, self.y) >= row and @as(i64, self.y) < @as(i64, row) + rows,
                'z', 'Z' => z_index == self.z,
                'r', 'R' => img_id >= self.id_lo and img_id <= self.id_hi,
                // f/F deletes animation frames, not placements.
                else => false,
            };
        }
    };

    pub const ImageEvent = struct {
        width: u32,
        height: u32,
        /// Borrowed slice — valid only for the duration of the call.
        /// Sink must copy if it needs the data later.
        rgba: []const u8,
        row: u16,
        col: u16,
        /// Kitty graphics image_id (0 = sixel/iterm2/anonymous).
        image_id: u32 = 0,
        /// Kitty graphics placement_id.
        placement_id: u32 = 0,
        /// Z-index for stacking.
        z_index: i32 = 0,
        /// Destination size in cells (Kitty `c=`/`r=`). 0 = render at
        /// native pixel size.
        cells_wide: u32 = 0,
        cells_high: u32 = 0,
        /// Source-rect crop in image-pixel coords (Kitty `x=`,`y=`,
        /// `w=`,`h=`). w==0 or h==0 means "use the whole image".
        src_x: u32 = 0,
        src_y: u32 = 0,
        src_w: u32 = 0,
        src_h: u32 = 0,
        /// Pixel offset inside the starting cell (Kitty `X=`, `Y=`),
        /// so an image can sit off the cell grid. Clamped to the cell
        /// by the sender; the renderer just adds them.
        cell_x_offset: u32 = 0,
        cell_y_offset: u32 = 0,
        /// Stable line id of the placement's top row. The renderer
        /// resolves this to a live display row every frame so the image
        /// scrolls with its content (and into scrollback). 0 = no
        /// anchor: the image stays pinned to `row` (legacy behavior).
        anchor_id: u64 = 0,
    };

    /// An ImageEvent with owned pixels — what `retain_images` keeps
    /// for the mux snapshot.
    pub const RetainedImage = struct {
        ev: ImageEvent,
        /// `ev.rgba` aliases this owned buffer.
        owned: []u8,
    };

    /// Total pixel bytes retained for snapshots; beyond this the
    /// oldest placements are dropped (they reappear when the app
    /// redraws). Must leave room under the 16 MB wire frame cap.
    pub const RETAIN_IMAGE_BUDGET: usize = 12 * 1024 * 1024;

    /// Emit an image to the sink, retaining a copy when configured.
    fn emitImage(self: *Screen, ev_in: ImageEvent) void {
        var ev = ev_in;
        // Anchor to the stable line id of the placement's top row so the
        // renderer can track it through scroll + scrollback. Guard the
        // row against the buffer bounds; 0 leaves it pinned.
        if (ev.anchor_id == 0) {
            const b = self.buf();
            if (ev.row < b.len) ev.anchor_id = b[ev.row].id;
        }
        if (self.sink.on_image) |f| f(self.sink.ctx, ev);
        if (!self.retain_images) return;
        if (ev.rgba.len > RETAIN_IMAGE_BUDGET) return;
        const owned = self.allocator.dupe(u8, ev.rgba) catch return;
        var copy = ev;
        copy.rgba = owned;
        self.retained_images.append(self.allocator, .{ .ev = copy, .owned = owned }) catch {
            self.allocator.free(owned);
            return;
        };
        self.retained_image_bytes += owned.len;
        while (self.retained_image_bytes > RETAIN_IMAGE_BUDGET and self.retained_images.items.len > 0) {
            const old = self.retained_images.orderedRemove(0);
            self.retained_image_bytes -= old.owned.len;
            self.allocator.free(old.owned);
        }
    }

    /// Prune retained placements to mirror a delete command.
    fn pruneRetainedImages(self: *Screen, ev: ImageDeleteEvent) void {
        if (!self.retain_images or self.retained_images.items.len == 0) return;
        var i: usize = 0;
        while (i < self.retained_images.items.len) {
            const ri = self.retained_images.items[i].ev;
            // Retained images know where they were placed, so every
            // positional selector can be answered here. Cell extent is
            // whatever the placement asked for; a native-size image
            // (cells 0) still occupies its top-left cell.
            const cols: i32 = if (ri.cells_wide > 0) @intCast(ri.cells_wide) else 1;
            const rows: i32 = if (ri.cells_high > 0) @intCast(ri.cells_high) else 1;
            const hit = if (ev.what == 'a' or ev.what == 'A')
                (ev.image_id == 0 or ri.image_id == ev.image_id)
            else
                ev.selects(
                    ri.image_id,
                    ri.placement_id,
                    self.kitty_images.numberOf(ri.image_id),
                    ri.z_index,
                    @intCast(ri.col),
                    @intCast(ri.row),
                    cols,
                    rows,
                );
            if (hit) {
                const old = self.retained_images.orderedRemove(i);
                self.retained_image_bytes -= old.owned.len;
                self.allocator.free(old.owned);
            } else i += 1;
        }
    }

    pub fn clearRetainedImages(self: *Screen) void {
        for (self.retained_images.items) |ri| self.allocator.free(ri.owned);
        self.retained_images.clearRetainingCapacity();
        self.retained_image_bytes = 0;
    }

    /// Hash of the currently-VISIBLE grid: every cell (rune + style +
    /// flags) of the active/alt buffer, plus the cursor position. Used
    /// to tell "the screen actually changed" from "bytes merely arrived"
    /// — identical output (an app repainting the same frame, keep-alive
    /// traffic, a cursor-position query) yields the same hash and so does
    /// NOT count as activity. Cursor blink and selection are excluded
    /// (not app-driven content).
    pub fn contentHash(self: *Screen) u64 {
        var h = std.hash.Wyhash.init(0);
        for (self.buf()) |ln| {
            h.update(std.mem.sliceAsBytes(ln.cells));
        }
        h.update(std.mem.asBytes(&self.row));
        h.update(std.mem.asBytes(&self.col));
        return h.final();
    }

    /// Where an anchored image should draw right now.
    pub const ImageRow = union(enum) {
        /// Display row (0 = top); may fall outside [0, rows) when the
        /// image straddles an edge — GL clipping handles the overflow.
        visible: i32,
        /// The anchor line still exists but isn't in the current
        /// viewport (scrolled away). Keep the image; don't draw it.
        offscreen,
        /// The anchor line has fallen out of the scrollback ring. The
        /// image can never be shown again — free it.
        evicted,
    };

    /// Resolve an image's stable anchor line id to its live display row,
    /// mirroring grid_pass's row→line mapping (scrollback rows first
    /// under `view_offset`, then the active/alt buffer). Costs at most
    /// one buffer scan plus a bounded scrollback-window scan per call.
    pub fn imageRowForAnchor(self: *Screen, anchor_id: u64) ImageRow {
        if (anchor_id == 0) return .offscreen;
        const b = self.buf();
        const sb_count = self.scrollback.items.len;
        const view_off: usize = @min(self.view_offset, sb_count);

        // Current buffer: display row = buffer index + view_off.
        for (b, 0..) |ln, i| {
            if (ln.id == anchor_id) return .{ .visible = @as(i32, @intCast(i)) + @as(i32, @intCast(view_off)) };
        }

        // Visible scrollback window (top `view_off` display rows) plus a
        // margin of one screen height above it, so a tall image whose
        // anchor scrolled just past the top edge still draws its lower
        // rows (GL clips the part above). Bounded by `rows`, so the scan
        // stays cheap regardless of ring size.
        if (sb_count > 0) {
            const win_lo: usize = (sb_count -| view_off) -| self.rows;
            var i: usize = win_lo;
            while (i < sb_count) : (i += 1) {
                if (self.scrollback.items[i].id == anchor_id) {
                    return .{ .visible = @as(i32, @intCast(i)) - @as(i32, @intCast(sb_count)) + @as(i32, @intCast(view_off)) };
                }
            }
        }

        // Not in the buffer or the scanned window. Line ids are assigned
        // in birth order, so anything older than the oldest surviving
        // line has been evicted; otherwise it's simply scrolled away.
        const oldest: u64 = if (sb_count > 0)
            self.scrollback.items[0].id
        else if (b.len > 0)
            b[0].id
        else
            0;
        if (anchor_id < oldest) return .evicted;
        return .offscreen;
    }

    pub fn init(allocator: std.mem.Allocator, pool: *Pool, cols: u16, rows: u16) !*Screen {
        const self = try allocator.create(Screen);
        errdefer allocator.destroy(self);

        const active = try allocator.alloc(Line, rows);
        errdefer allocator.free(active);
        var initialized: u16 = 0;
        errdefer for (active[0..initialized]) |*l| l.deinit(allocator);
        // Initial line IDs start at 1 and increment as we fill rows.
        var id_counter: u64 = 1;
        for (active) |*l| {
            l.* = try Line.init(allocator, cols);
            l.id = id_counter;
            id_counter += 1;
            initialized += 1;
        }

        self.* = .{
            .cols = cols,
            .rows = rows,
            .active = active,
            .scroll_bot = if (rows > 0) rows - 1 else 0,
            .pool = pool,
            .allocator = allocator,
            .links = std.AutoHashMap(u8, []u8).init(allocator),
            .clusters = std.AutoHashMap(u32, std.ArrayList(u32)).init(allocator),
            .kitty_images = @import("kitty_images.zig").Manager.init(allocator),
            .virtual_placements = std.AutoHashMap(u32, VirtualPlacement).init(allocator),
            .next_line_id = id_counter,
        };
        try self.resetTabStops();
        return self;
    }

    pub fn deinit(self: *Screen) void {
        self.clearRetainedImages();
        self.retained_images.deinit(self.allocator);
        self.notify_title.deinit(self.allocator);
        self.notify_body.deinit(self.allocator);
        self.notify_buttons.deinit(self.allocator);
        self.notify_icon_data.deinit(self.allocator);
        self.notify_icon_name.deinit(self.allocator);
        for (self.active) |*l| l.deinit(self.allocator);
        self.allocator.free(self.active);
        if (self.alt) |alt| {
            for (alt) |*l| {
                var mut = l.*;
                mut.deinit(self.allocator);
            }
            self.allocator.free(alt);
        }
        for (self.scrollback.items) |*l| l.deinit(self.allocator);
        self.scrollback.deinit(self.allocator);
        self.tab_stops.deinit(self.allocator);
        // Free OSC 8 link URIs.
        var link_it = self.links.iterator();
        while (link_it.next()) |entry| self.allocator.free(entry.value_ptr.*);
        self.links.deinit();
        // Free grapheme clusters.
        var cl_it = self.clusters.iterator();
        while (cl_it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.clusters.deinit();
        self.kitty_images.deinit();
        self.virtual_placements.deinit();
        for (self.user_vars.items) |uv| {
            self.allocator.free(uv.name);
            self.allocator.free(uv.value);
        }
        self.user_vars.deinit(self.allocator);
        if (self.preedit_text) |t| self.allocator.free(t);
        if (self.last_title) |t| self.allocator.free(t);
        for (&self.title_stack) |*entry| {
            if (entry.*) |t| self.allocator.free(t);
            entry.* = null;
        }
        self.allocator.destroy(self);
    }

    fn cellKey(row: u32, col: u32) u32 {
        return (row << 16) | (col & 0xFFFF);
    }

    /// Drop any cluster attached to (row, col). Called on cell
    /// overwrite + erase + line clear so stale clusters don't
    /// linger.
    fn clearClusterAt(self: *Screen, row: u16, col: u16) void {
        const key = cellKey(row, col);
        if (self.clusters.fetchRemove(key)) |entry| {
            var v = entry.value;
            v.deinit(self.allocator);
        }
    }

    /// Append an extending codepoint to the cluster at (row, col).
    /// Caller has already verified it's an extending codepoint and
    /// that a base glyph exists at that cell.
    fn appendCluster(self: *Screen, row: u16, col: u16, cp: u32) void {
        const key = cellKey(row, col);
        const gop = self.clusters.getOrPut(key) catch |err| {
            std.debug.print("sketerm: appendCluster getOrPut OOM: {s}\n", .{@errorName(err)});
            return;
        };
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(self.allocator, cp) catch |err| {
            std.debug.print("sketerm: appendCluster append OOM: {s}\n", .{@errorName(err)});
        };
    }

    /// Look up the cluster (if any) at (row, col). Returns slice of
    /// extending codepoints; empty if none.
    pub fn clusterAt(self: *const Screen, row: u16, col: u16) []const u32 {
        const key = cellKey(row, col);
        if (self.clusters.get(key)) |list| return list.items;
        return &.{};
    }

    /// Drop every cluster — called from coarse operations (scroll,
    /// reset, resize, clearAndScrollback) where tracking shifts of
    /// individual cells would be expensive.
    pub fn clearAllClusters(self: *Screen) void {
        // Fast path: empty cluster store is the common case (nobody
        // typed combining marks). Called on every scrollUp; iterator
        // setup adds nontrivial cost in the bench when called 60k×.
        if (self.clusters.count() == 0) return;
        var it = self.clusters.iterator();
        while (it.next()) |entry| {
            var v = entry.value_ptr.*;
            v.deinit(self.allocator);
        }
        self.clusters.clearRetainingCapacity();
    }

    /// Drop clusters for cells at (row, lo..hi).
    pub fn clearClustersRange(self: *Screen, row: u16, lo: u16, hi: u16) void {
        var c = lo;
        while (c < hi) : (c += 1) self.clearClusterAt(row, c);
    }

    /// Public wrapper for the wide-char predicate used by the
    /// renderer when laying out preedit text.
    pub fn isWide(cp: u32) bool {
        return isWideCp(cp);
    }

    /// Blank both halves of any wide-char pair overlapping `col`.
    /// Overwriting or erasing one half of a pair must not leave the
    /// other half behind: an orphaned wide-left keeps drawing the old
    /// glyph, an orphaned continuation renders as a permanently blank
    /// cell (ghost cells after CJK is overwritten by narrow text).
    pub fn splitWidePair(self: *Screen, ln: *Line, col: u16) void {
        if (col >= self.cols) return;
        const f = ln.cells[col].flags;
        if (f & 0b0000_0001 != 0) { // wide-left
            ln.cells[col] = .{};
            if (col + 1 < self.cols and (ln.cells[col + 1].flags & 0b0000_0010) != 0)
                ln.cells[col + 1] = .{};
        } else if (f & 0b0000_0010 != 0) { // wide continuation
            ln.cells[col] = .{};
            if (col > 0 and (ln.cells[col - 1].flags & 0b0000_0001) != 0)
                ln.cells[col - 1] = .{};
        }
    }

    /// Word-class membership for double-click word selection.
    /// Shared with copy mode's w/b motions via word_motion.zig.
    fn isWordChar(self: *const Screen, cp: u32) bool {
        return @import("word_motion.zig").isWordChar(self.word_chars, cp);
    }

    /// Set selection to the word containing (row, col). Used by
    /// double-click in the UI layer.
    pub fn selectWordAt(self: *Screen, row: i32, col: i32) void {
        const cells = self.lineCellsAt(row) orelse return;
        if (col < 0 or @as(usize, @intCast(col)) >= cells.len) return;
        const cidx: usize = @intCast(col);
        const here = cells[cidx];
        if (!self.isWordChar(here.rune)) {
            // Non-word cell → select just this column.
            self.selection.start(row, col, .normal);
            self.selection.extend(row, col + 1);
            self.dirty = true;
            return;
        }
        // Walk left.
        var lo: usize = cidx;
        while (lo > 0 and self.isWordChar(cells[lo - 1].rune)) lo -= 1;
        // Walk right.
        var hi: usize = cidx;
        while (hi + 1 < cells.len and self.isWordChar(cells[hi + 1].rune)) hi += 1;
        self.selection.start(row, @intCast(lo), .normal);
        self.selection.extend(row, @intCast(hi + 1));
        self.dirty = true;
    }

    /// Set selection to an entire row.
    pub fn selectLineAt(self: *Screen, row: i32) void {
        const cells = self.lineCellsAt(row) orelse return;
        self.selection.start(row, 0, .normal);
        self.selection.extend(row, @intCast(cells.len));
        self.dirty = true;
    }

    /// Record a prompt-mark at the current row (called from OSC 133).
    fn recordPromptMark(self: *Screen) void {
        const cap: u16 = self.prompt_marks.len;
        const idx = self.prompt_marks_head;
        // Record the current row's *line ID*, not the row number.
        // Display rows scroll, IDs don't.
        const buf_const = if (self.use_alt) self.alt.? else self.active;
        if (self.row >= self.rows) return;
        self.prompt_marks[idx] = buf_const[self.row].id;
        self.prompt_marks_head = (idx + 1) % cap;
        if (self.prompt_marks_len < cap) self.prompt_marks_len += 1;
    }

    /// Allocate a fresh, monotonically-increasing line ID. u64 — won't
    /// wrap in any plausible session (1 ID/ns × 580 years).
    pub fn nextLineId(self: *Screen) u64 {
        const id = self.next_line_id;
        self.next_line_id += 1;
        return id;
    }

    /// Push a completed command zone onto the ring (OSC 133 D).
    fn recordCmdZone(self: *Screen, start_id: u64, end_id: u64, exit: i32) void {
        const cap: u16 = CMD_ZONE_CAP;
        self.cmd_zones[self.cmd_zones_head] = .{ .start_id = start_id, .end_id = end_id, .exit = exit };
        self.cmd_zones_head = (self.cmd_zones_head + 1) % cap;
        if (self.cmd_zones_len < cap) self.cmd_zones_len += 1;
    }

    /// Iterate the zone ring, newest first. idx 0 = most recent.
    pub fn cmdZone(self: *const Screen, idx: u16) ?CmdZone {
        if (idx >= self.cmd_zones_len) return null;
        const cap: u32 = CMD_ZONE_CAP;
        const slot: u16 = @intCast((@as(u32, self.cmd_zones_head) + cap - 1 - @as(u32, idx)) % cap);
        return self.cmd_zones[slot];
    }

    /// Find the zone containing `display_row` (negative = scrollback)
    /// via the line-ID range check: zone rows were born between the
    /// C row and the D row, so their IDs fall in [start_id, end_id).
    pub fn cmdZoneContainingDisplayRow(self: *const Screen, display_row: i32) ?CmdZoneRows {
        if (self.use_alt) return null;
        const ln = self.lineAt(display_row) orelse return null;
        if (ln.id == 0) return null;
        var i: u16 = 0;
        while (i < self.cmd_zones_len) : (i += 1) {
            const z = self.cmdZone(i).?;
            if (ln.id >= z.start_id and ln.id < z.end_id) {
                const start = self.rowForLineIdFast(z.start_id) orelse return null;
                const end = self.rowForLineIdFast(z.end_id) orelse return null;
                if (end <= start) return null;
                return .{ .start_row = start, .end_row = end, .exit = z.exit };
            }
        }
        return null;
    }

    /// Line-wise select a command zone's output rows. Returns true
    /// when a zone covered `display_row` and the selection was set.
    pub fn selectCmdZoneAt(self: *Screen, display_row: i32) bool {
        const z = self.cmdZoneContainingDisplayRow(display_row) orelse return false;
        self.selection.start(z.start_row, 0, .line_select);
        self.selection.extend(z.end_row - 1, @intCast(self.cols));
        self.dirty = true;
        return true;
    }

    /// `rowForLineId` with a binary search over scrollback (lines
    /// land there in birth order, so IDs are sorted). Falls back to
    /// the linear walk if the sorted assumption ever fails (reflow
    /// edge cases) — correctness over speed.
    pub fn rowForLineIdFast(self: *const Screen, line_id: u64) ?i32 {
        if (line_id == 0 or self.use_alt) return self.rowForLineId(line_id);
        for (self.active, 0..) |l, i| {
            if (l.id == line_id) return @intCast(i);
        }
        const sb_count = self.scrollbackCount();
        if (sb_count > 0) {
            var lo: u32 = 0;
            var hi: u32 = sb_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const mid_id = self.scrollbackLine(mid).id;
                if (mid_id == line_id) {
                    const from_bottom: i32 = @intCast(sb_count - mid);
                    return -from_bottom;
                }
                if (mid_id < line_id) lo = mid + 1 else hi = mid;
            }
        }
        return self.rowForLineId(line_id);
    }

    /// Locate the display row containing `line_id`, including
    /// scrollback (negative result). Returns null if the ID isn't
    /// in either the active buffer or scrollback.
    pub fn rowForLineId(self: *const Screen, line_id: u64) ?i32 {
        if (line_id == 0) return null;
        const buf_const = if (self.use_alt) self.alt.? else self.active;
        for (buf_const, 0..) |l, i| {
            if (l.id == line_id) return @intCast(i);
        }
        if (!self.use_alt) {
            // Walk scrollback in oldest→newest logical order via the ring.
            const sb_count = self.scrollbackCount();
            var i: u32 = 0;
            while (i < sb_count) : (i += 1) {
                if (self.scrollbackLine(i).id == line_id) {
                    // Scrollback: -1 = bottom-most, -sb_count = oldest.
                    const from_bottom: i32 = @intCast(sb_count - i);
                    return -from_bottom;
                }
            }
        }
        return null;
    }

    /// Step to the previous (older) prompt mark visible in the buffer.
    /// Returns the new view_offset after the move, or null if there is
    /// no earlier mark.
    pub fn jumpPrevPrompt(self: *Screen) ?u32 {
        if (self.prompt_marks_len == 0) return null;
        // Iterate marks from most-recent to oldest; pick the first
        // whose row is *strictly above* the current top-of-view.
        const view_top: i32 = -@as(i32, @intCast(self.view_offset));
        var i: u16 = self.prompt_marks_len;
        while (i > 0) {
            i -= 1;
            const slot: u16 = @intCast((@as(u32, self.prompt_marks_head) + @as(u32, self.prompt_marks.len) - 1 - @as(u32, i)) % self.prompt_marks.len);
            const id = self.prompt_marks[slot];
            const row = self.rowForLineId(id) orelse continue;
            if (row < view_top) {
                const dist: u32 = @intCast(-row);
                const sb: u32 = @intCast(self.scrollback.items.len);
                self.view_offset = @min(sb, dist);
                self.dirty = true;
                return self.view_offset;
            }
        }
        return null;
    }

    pub fn jumpNextPrompt(self: *Screen) ?u32 {
        if (self.prompt_marks_len == 0) return null;
        const view_top: i32 = -@as(i32, @intCast(self.view_offset));
        var i: u16 = 0;
        while (i < self.prompt_marks_len) : (i += 1) {
            const slot: u16 = @intCast((@as(u32, self.prompt_marks_head) + @as(u32, self.prompt_marks.len) - @as(u32, self.prompt_marks_len) + @as(u32, i)) % self.prompt_marks.len);
            const id = self.prompt_marks[slot];
            const row = self.rowForLineId(id) orelse continue;
            if (row > view_top) {
                if (row >= 0) {
                    self.view_offset = 0;
                } else {
                    const dist: u32 = @intCast(-row);
                    self.view_offset = dist;
                }
                self.dirty = true;
                return self.view_offset;
            }
        }
        return null;
    }

    /// Clear the visible screen + the scrollback ring + send cursor
    /// home. Used by Ctrl+Shift+K (GNOME convention).
    pub fn clearAndScrollback(self: *Screen) void {
        for (self.buf()) |*l| l.clear();
        for (self.scrollback.items) |*l| l.deinit(self.allocator);
        self.scrollback.clearRetainingCapacity();
        self.scrollback_head = 0;
        self.clearAllClusters();
        self.row = 0;
        self.col = 0;
        self.view_offset = 0;
        self.pending_wrap = false;
        self.dirty = true;
    }

    /// Wipe only the scrollback ring — visible screen + cursor stay
    /// where they are. Useful when scrollback gets noisy but you
    /// don't want to lose the current screen contents.
    pub fn clearScrollbackOnly(self: *Screen) void {
        for (self.scrollback.items) |*l| l.deinit(self.allocator);
        self.scrollback.clearRetainingCapacity();
        self.scrollback_head = 0;
        // Snap view back to the live screen — the scrollback we were
        // looking at is gone.
        self.view_offset = 0;
        self.dirty = true;
    }

    /// Resize the screen to new dimensions while preserving as much
    /// content as possible. When columns change on the main buffer
    /// we run a full soft-wrap reflow (scrollback + active joined,
    /// re-chunked at new_cols, redistributed). The alt buffer always
    /// truncates/pads — apps that use it (vim, less, htop) handle
    /// their own resize. Cursor is re-placed at its logical position.
    pub fn resize(self: *Screen, new_cols: u16, new_rows: u16) !void {
        if (new_cols == self.cols and new_rows == self.rows) return;

        const cols_changed = new_cols != self.cols;
        if (cols_changed and !self.use_alt) {
            // reflowMain clears the (row, col)-keyed cluster map itself.
            try self.reflowMain(new_cols, new_rows);
        } else {
            // resizeBuffer truncates/pads each line and shifts cells to
            // new (row, col) positions (column resize, and row-count
            // changes move cells to new row indices). The cluster map is
            // keyed by (row, col), so drop it wholesale — same coarse
            // approach reflowMain takes. Covers the main-buffer
            // truncate/pad path and the alt buffer below.
            self.clearAllClusters();
            try resizeBuffer(self.allocator, &self.active, self.rows, new_cols, new_rows, !self.use_alt, self);
            // resizeBuffer's shrink branch drops rows from the TOP and
            // shifts surviving content up — move the cursor with its
            // line, or it ends up pointing rows below the content it
            // was on (the clamp below alone is not enough).
            if (new_rows < self.rows) {
                const drop = self.rows - new_rows;
                self.row -|= drop;
                self.saved_row -|= drop;
            }
        }
        if (self.alt) |alt_buf| {
            var alt_mut = alt_buf;
            // Alt buffer always truncates/pads via resizeBuffer; if the
            // reflowMain branch ran above, the cluster map is already
            // cleared, so this is at worst a no-op fast-path return.
            self.clearAllClusters();
            try resizeBuffer(self.allocator, &alt_mut, self.rows, new_cols, new_rows, false, self);
            self.alt = alt_mut;
        }
        // While the alternate screen is active, the main buffer is resized
        // without reflow. Its scrollback must follow the new width too:
        // evicted scrollback cell slices are reused as active rows by the
        // scroll hot path after returning to the main screen.
        if (cols_changed and self.use_alt) {
            for (self.scrollback.items) |*ln| {
                try resizeLineCells(self.allocator, ln, new_cols);
            }
        }

        self.resizeTabStops(new_cols);
        self.cols = new_cols;
        self.rows = new_rows;
        self.scroll_top = 0;
        self.scroll_bot = if (new_rows > 0) new_rows - 1 else 0;
        if (self.row >= new_rows) self.row = if (new_rows == 0) 0 else new_rows - 1;
        if (self.col >= new_cols) self.col = if (new_cols == 0) 0 else new_cols - 1;
        self.pending_wrap = false;
        self.dirty = true;
        if (self.in_band_resize) self.sendResizeReport();
    }

    /// Soft-wrap reflow of scrollback + active. Assumes self.use_alt
    /// is false. Updates self.scrollback / self.active / self.row /
    /// self.col to match the rebuilt layout.
    fn reflowMain(self: *Screen, new_cols: u16, new_rows: u16) !void {
        const reflow = @import("reflow.zig");
        // Reflow shifts every cell to a new (row, col); the cluster
        // map keyed by (row, col) becomes meaningless. Drop it.
        self.clearAllClusters();

        // Build a single logical-line stream from scrollback, then active.
        // Capture cursor's logical position before consuming. Walk the
        // scrollback ring in oldest→newest order via scrollbackLine.
        var combined: std.ArrayList(Line) = .empty;
        defer combined.deinit(self.allocator);
        const sb_count = self.scrollbackCount();
        try combined.ensureTotalCapacity(self.allocator, sb_count + self.active.len);
        var sb_i: u32 = 0;
        while (sb_i < sb_count) : (sb_i += 1) {
            combined.appendAssumeCapacity(self.scrollbackLine(sb_i).*);
        }
        try combined.appendSlice(self.allocator, self.active);

        const cursor_pos = reflow.positionInLogicals(
            combined.items,
            @intCast(sb_count + self.row),
            self.col,
        );

        var logicals = try reflow.build(self.allocator, combined.items, false);
        defer {
            for (logicals.items) |*ll| ll.cells.deinit(self.allocator);
            logicals.deinit(self.allocator);
        }
        reflow.trim(&logicals, self.allocator);

        const all_rows = try reflow.rechunk(self.allocator, logicals.items, new_cols);
        // Stamp fresh IDs on every reflowed row. Pre-reflow IDs are
        // irretrievable since cells got redistributed; better to give
        // each post-reflow row a clean ID than leave it 0 (collides
        // with "unset"). prompt_marks become stale across a width
        // change — accepted v1 limitation.
        for (all_rows) |*ln| ln.id = self.nextLineId();
        // `all_rows` is owned and we need to redistribute it into
        // active + scrollback. Free the old buffers first.
        for (self.active) |*ln| ln.deinit(self.allocator);
        self.allocator.free(self.active);
        for (self.scrollback.items) |*ln| ln.deinit(self.allocator);
        self.scrollback.clearRetainingCapacity();
        self.scrollback_head = 0;

        // Compute cursor's new (row, col) within all_rows.
        const new_pos = reflow.positionAfterRechunk(all_rows, cursor_pos.idx, cursor_pos.col, new_cols);

        // The active screen is the bottom new_rows of all_rows; pad
        // with blank rows if there are fewer logical rows than fit.
        var sb_rows: usize = 0;
        var active_first: usize = 0;
        if (all_rows.len > new_rows) {
            sb_rows = all_rows.len - new_rows;
            active_first = sb_rows;
        }

        // Fill scrollback via the ring-aware push helper.
        if (sb_rows > 0) {
            const sb_slice = all_rows[0..sb_rows];
            for (sb_slice) |row| {
                self.pushScrollback(row.cells, row.id, row.continues_above);
            }
        }

        // Fill active with the rest, padding if needed.
        const taken = all_rows.len - sb_rows;
        const new_active = try self.allocator.alloc(Line, new_rows);
        errdefer self.allocator.free(new_active);
        var i: usize = 0;
        while (i < taken and i < new_rows) : (i += 1) {
            new_active[i] = all_rows[active_first + i];
        }
        // Pad if we have fewer logical rows than fit. Each new line
        // gets a fresh ID.
        while (i < new_rows) : (i += 1) {
            new_active[i] = try Line.init(self.allocator, new_cols);
            new_active[i].id = self.nextLineId();
        }
        // Free the slice carrier (the rows themselves were moved out).
        self.allocator.free(all_rows);
        self.active = new_active;

        // Re-place cursor.
        if (new_pos.row >= sb_rows) {
            const new_row = new_pos.row - sb_rows;
            self.row = if (new_row >= new_rows) new_rows - 1 else @intCast(new_row);
            self.col = @min(new_pos.col, new_cols - 1);
        } else {
            // Cursor's logical position landed in scrollback (rare —
            // happens if narrowing pushes content above visible area).
            // Place at top-left of active.
            self.row = 0;
            self.col = 0;
        }
    }

    fn resizeBuffer(
        allocator: std.mem.Allocator,
        slot: *[]Line,
        old_rows: u16,
        new_cols: u16,
        new_rows: u16,
        push_to_sb: bool,
        screen: *Screen,
    ) !void {
        // First, resize each line's cells to new width.
        for (slot.*) |*ln| {
            try resizeLineCells(allocator, ln, new_cols);
        }

        // Then adjust row count.
        if (new_rows > old_rows) {
            const new_buf = try allocator.realloc(slot.*, new_rows);
            var i: u16 = old_rows;
            while (i < new_rows) : (i += 1) {
                new_buf[i] = try Line.init(allocator, new_cols);
                new_buf[i].id = screen.nextLineId();
            }
            slot.* = new_buf;
        } else if (new_rows < old_rows) {
            const drop = old_rows - new_rows;
            var i: u16 = 0;
            while (i < drop) : (i += 1) {
                if (push_to_sb) {
                    const copy = allocator.dupe(Cell, slot.*[i].cells) catch null;
                    if (copy) |cells| screen.pushScrollback(cells, slot.*[i].id, slot.*[i].continues_above);
                }
                slot.*[i].deinit(allocator);
            }
            std.mem.copyForwards(Line, slot.*[0..new_rows], slot.*[drop..]);
            const new_buf = try allocator.realloc(slot.*, new_rows);
            slot.* = new_buf;
        }
    }

    fn resizeLineCells(allocator: std.mem.Allocator, ln: *Line, new_cols: u16) !void {
        if (ln.cells.len == new_cols) return;
        const new_cells = try allocator.alloc(Cell, new_cols);
        @memset(new_cells, .{});
        const n = @min(ln.cells.len, @as(usize, new_cols));
        @memcpy(new_cells[0..n], ln.cells[0..n]);
        if (ln.cells.len > 0) allocator.free(ln.cells);
        ln.cells = new_cells;
        ln.dirty = true;
    }

    /// Push a line into scrollback. Caller transfers ownership of
    /// the cells slice. When at capacity, the evicted oldest cells
    /// buffer is RETURNED rather than freed — caller can reuse it as
    /// the new bottom-row cells (one alloc + one free saved per
    /// scroll on the hot path). Returns null when no eviction
    /// happened (pre-cap fill).
    pub fn pushScrollbackTakeOld(self: *Screen, cells: []Cell, line_id: u64, continues_above: bool) ?[]Cell {
        const cap = self.scrollback_capacity;
        if (self.scrollback.items.len < cap) {
            // Pre-allocate the full ring on first push to avoid the
            // growth-realloc chain (~14 grows from empty to 10k).
            if (self.scrollback.capacity == 0 and cap > 0) {
                self.scrollback.ensureTotalCapacity(self.allocator, cap) catch {
                    // Fall back to incremental growth.
                };
            }
            self.scrollback.append(self.allocator, .{ .cells = cells, .id = line_id, .continues_above = continues_above }) catch {
                self.allocator.free(cells);
            };
            return null;
        }
        const head = self.scrollback_head;
        const old_cells = self.scrollback.items[head].cells;
        self.scrollback.items[head] = .{ .cells = cells, .id = line_id, .continues_above = continues_above };
        self.scrollback_head = (head + 1) % cap;
        return old_cells;
    }

    /// Push helper that frees the evicted cells. Used when the caller
    /// can't reuse the buffer (e.g. width changed during reflow).
    fn pushScrollback(self: *Screen, cells: []Cell, line_id: u64, continues_above: bool) void {
        if (self.pushScrollbackTakeOld(cells, line_id, continues_above)) |old_cells| {
            self.allocator.free(old_cells);
        }
    }

    /// Number of scrollback lines currently held.
    pub fn scrollbackCount(self: *const Screen) u32 {
        return @intCast(self.scrollback.items.len);
    }

    /// Get a scrollback line by offset-from-top. 0 = oldest.
    pub fn scrollbackLine(self: *const Screen, idx: u32) *const Line {
        const len = self.scrollback.items.len;
        std.debug.assert(len > 0);
        std.debug.assert(idx < len);
        return &self.scrollback.items[(self.scrollback_head + idx) % len];
    }

    /// Extract selection text (UTF-8). Coordinates are *display*
    /// rows: 0..rows-1 reference active screen, negative values
    /// reference scrollback (-1 = bottom-most scrollback line).
    /// Caller frees the returned slice. OSC 8 link spans are emitted
    /// as `[linked-text](uri)` markdown so URIs survive copy/paste.
    pub fn extractSelection(self: *const Screen, allocator: std.mem.Allocator) ![]u8 {
        const sel = self.selection;
        const r = sel.rect() orelse return try allocator.alloc(u8, 0);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        const is_rect = sel.mode == .rectangular;
        const rect_lo: i32 = @min(r.top_col, r.bot_col);
        const rect_hi: i32 = @max(r.top_col, r.bot_col);

        var open_link_id: u8 = 0; // currently open OSC 8 link, 0 = none

        var row = r.top_row;
        while (row <= r.bot_row) : (row += 1) {
            const line_cells = self.lineCellsAt(row) orelse continue;
            const start_col: i32 = if (is_rect) rect_lo else if (row == r.top_row) r.top_col else 0;
            const end_col: i32 = if (is_rect) rect_hi else if (row == r.bot_row) r.bot_col else @intCast(line_cells.len);
            const lo: usize = @intCast(@max(@as(i32, 0), start_col));
            const hi: usize = @intCast(@max(@as(i32, 0), end_col));
            const hi_clamped = @min(hi, line_cells.len);
            if (lo >= hi_clamped) continue;

            // Trim trailing blank cells on this line span — but not
            // in rectangular mode where each row must keep its full
            // width so columns stay aligned in the output.
            var actual_hi = hi_clamped;
            if (!is_rect) {
                while (actual_hi > lo and line_cells[actual_hi - 1].rune == 0) actual_hi -= 1;
            }

            var col: usize = lo;
            while (col < actual_hi) : (col += 1) {
                const cell = line_cells[col];
                // Skip wide-char continuation cells (right half of a
                // 2-column glyph). Their rune is 0 by design.
                if (cell.flags & 0b0000_0010 != 0) continue;

                // OSC 8 link state machine: emit `[` on open, `](uri)`
                // on close. Run boundaries are link_id changes.
                const has_link = (cell.flags & 0b0000_0100) != 0;
                const cell_link_id: u8 = if (has_link) cell.reserved else 0;
                if (cell_link_id != open_link_id) {
                    if (open_link_id != 0) {
                        if (self.linkUri(open_link_id)) |uri| {
                            try out.append(allocator, ']');
                            try out.append(allocator, '(');
                            // Markdown angle-bracket form for URIs that
                            // would break the plain (uri) form. Closing
                            // paren is the only unsafe char here.
                            const need_angle = std.mem.indexOfScalar(u8, uri, ')') != null;
                            if (need_angle) try out.append(allocator, '<');
                            try out.appendSlice(allocator, uri);
                            if (need_angle) try out.append(allocator, '>');
                            try out.append(allocator, ')');
                        } else {
                            try out.append(allocator, ']');
                        }
                    }
                    if (cell_link_id != 0) try out.append(allocator, '[');
                    open_link_id = cell_link_id;
                }

                const cp = cell.rune;
                if (cp == 0) {
                    try out.append(allocator, ' ');
                } else if (cp < 0x80) {
                    try out.append(allocator, @intCast(cp));
                } else {
                    var ub: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &ub) catch continue;
                    try out.appendSlice(allocator, ub[0..n]);
                }
                // Append any extending codepoints attached to this
                // cell (combining marks, ZWJ continuations, skin-
                // tone modifiers — stored at print time).
                if (row >= 0 and row < @as(i32, @intCast(self.rows))) {
                    const cluster = self.clusterAt(@intCast(row), @intCast(col));
                    for (cluster) |ext_cp| {
                        var eb: [4]u8 = undefined;
                        const en = std.unicode.utf8Encode(@intCast(ext_cp), &eb) catch continue;
                        try out.appendSlice(allocator, eb[0..en]);
                    }
                }
            }
            if (row != r.bot_row) {
                if (is_rect) {
                    // Rectangular: each row is independent.
                    try out.append(allocator, '\n');
                } else {
                    // Suppress the newline if the next row is a
                    // soft-wrap continuation — we want one logical line.
                    const next_continues = if (self.lineAt(row + 1)) |l| l.continues_above else false;
                    if (!next_continues) try out.append(allocator, '\n');
                }
            }
        }
        // Close any link still open at end of selection.
        if (open_link_id != 0) {
            if (self.linkUri(open_link_id)) |uri| {
                try out.append(allocator, ']');
                try out.append(allocator, '(');
                try out.appendSlice(allocator, uri);
                try out.append(allocator, ')');
            } else {
                try out.append(allocator, ']');
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Extract the entire visible screen as UTF-8 text. Honours
    /// `view_offset` so a scrolled-back view dumps what the user
    /// currently sees. Trailing blank cells per row are trimmed; rows
    /// that are entirely blank still emit a `\n` so paragraph shape
    /// survives. Caller frees the returned slice.
    pub fn extractScreen(self: *const Screen, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        const view_off: i32 = @intCast(@min(self.view_offset, self.scrollbackCount()));
        var open_link_id: u8 = 0;

        var r: i32 = 0;
        while (r < @as(i32, @intCast(self.rows))) : (r += 1) {
            const logical_row: i32 = r - view_off;
            const line_cells = self.lineCellsAt(logical_row) orelse {
                try out.append(allocator, '\n');
                continue;
            };
            // Trim trailing blanks (rune == 0) so we don't pad with spaces.
            var hi: usize = line_cells.len;
            while (hi > 0 and line_cells[hi - 1].rune == 0) hi -= 1;

            var col: usize = 0;
            while (col < hi) : (col += 1) {
                const cell = line_cells[col];
                if (cell.flags & 0b0000_0010 != 0) continue; // wide-char tail

                const has_link = (cell.flags & 0b0000_0100) != 0;
                const cell_link_id: u8 = if (has_link) cell.reserved else 0;
                if (cell_link_id != open_link_id) {
                    if (open_link_id != 0) {
                        if (self.linkUri(open_link_id)) |uri| {
                            try out.append(allocator, ']');
                            try out.append(allocator, '(');
                            const need_angle = std.mem.indexOfScalar(u8, uri, ')') != null;
                            if (need_angle) try out.append(allocator, '<');
                            try out.appendSlice(allocator, uri);
                            if (need_angle) try out.append(allocator, '>');
                            try out.append(allocator, ')');
                        } else {
                            try out.append(allocator, ']');
                        }
                    }
                    if (cell_link_id != 0) try out.append(allocator, '[');
                    open_link_id = cell_link_id;
                }

                const cp = cell.rune;
                if (cp == 0) {
                    try out.append(allocator, ' ');
                } else if (cp < 0x80) {
                    try out.append(allocator, @intCast(cp));
                } else {
                    var ub: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &ub) catch continue;
                    try out.appendSlice(allocator, ub[0..n]);
                }
                if (logical_row >= 0 and logical_row < @as(i32, @intCast(self.rows))) {
                    const cluster = self.clusterAt(@intCast(logical_row), @intCast(col));
                    for (cluster) |ext_cp| {
                        var eb: [4]u8 = undefined;
                        const en = std.unicode.utf8Encode(@intCast(ext_cp), &eb) catch continue;
                        try out.appendSlice(allocator, eb[0..en]);
                    }
                }
            }
            try out.append(allocator, '\n');
        }
        if (open_link_id != 0) {
            if (self.linkUri(open_link_id)) |uri| {
                try out.append(allocator, ']');
                try out.append(allocator, '(');
                try out.appendSlice(allocator, uri);
                try out.append(allocator, ')');
            } else {
                try out.append(allocator, ']');
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Whether a completed OSC 133 command-output zone is currently
    /// reachable (both boundary rows still in scrollback/screen and
    /// non-empty). Cheap enough for menu-popup enablement.
    pub fn lastCommandOutputAvailable(self: *const Screen) bool {
        if (self.last_output_start_id == 0 or self.last_output_end_id == 0) return false;
        const start = self.rowForLineId(self.last_output_start_id) orelse return false;
        const end = self.rowForLineId(self.last_output_end_id) orelse return false;
        return end > start;
    }

    /// Extract the output of the last completed command (OSC 133 C/D
    /// zone) as plain UTF-8 text, or null when no zone is reachable.
    /// Caller frees.
    pub fn extractLastCommandOutput(self: *const Screen, allocator: std.mem.Allocator) !?[]u8 {
        if (self.last_output_start_id == 0 or self.last_output_end_id == 0) return null;
        const start = self.rowForLineId(self.last_output_start_id) orelse return null;
        const end = self.rowForLineId(self.last_output_end_id) orelse return null;
        if (end < start) return null;
        // An empty range is a real, completed zone: the command just
        // produced no output (its exit code is still meaningful).
        if (end == start) return try allocator.dupe(u8, "");
        return try self.extractRowRange(allocator, start, end);
    }

    /// Extract display rows [start, end) as plain text (no link
    /// markup). Negative rows index scrollback. Trailing blanks are
    /// trimmed per row; soft-wrapped rows join into one logical line.
    pub fn extractRowRange(self: *const Screen, allocator: std.mem.Allocator, start: i32, end_excl: i32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        var r: i32 = start;
        while (r < end_excl) : (r += 1) {
            const joins_next = blk: {
                if (r + 1 >= end_excl) break :blk false;
                break :blk if (self.lineAt(r + 1)) |l| l.continues_above else false;
            };
            const line_cells = self.lineCellsAt(r) orelse {
                if (!joins_next) try out.append(allocator, '\n');
                continue;
            };
            var hi: usize = line_cells.len;
            while (hi > 0 and line_cells[hi - 1].rune == 0) hi -= 1;

            var col: usize = 0;
            while (col < hi) : (col += 1) {
                const cell = line_cells[col];
                if (cell.flags & 0b0000_0010 != 0) continue; // wide tail
                const cp = cell.rune;
                if (cp == 0) {
                    try out.append(allocator, ' ');
                } else if (cp < 0x80) {
                    try out.append(allocator, @intCast(cp));
                } else {
                    var ub: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &ub) catch continue;
                    try out.appendSlice(allocator, ub[0..n]);
                }
                if (r >= 0 and r < @as(i32, @intCast(self.rows))) {
                    const cluster = self.clusterAt(@intCast(r), @intCast(col));
                    for (cluster) |ext_cp| {
                        var eb: [4]u8 = undefined;
                        const en = std.unicode.utf8Encode(@intCast(ext_cp), &eb) catch continue;
                        try out.appendSlice(allocator, eb[0..en]);
                    }
                }
            }
            if (!joins_next) try out.append(allocator, '\n');
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Extract the FULL scrollback ring + active screen as UTF-8 text.
    /// Honours soft-wrap continuation: rows whose next neighbour has
    /// `continues_above` set don't get a trailing newline, so a long
    /// shell line that wrapped across multiple rows pastes as one
    /// logical line. Useful for "share my whole terminal session"
    /// flows (Ctrl+Shift+End-style copy-all). Caller frees.
    pub fn extractScrollback(self: *const Screen, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);

        const sb_count: i32 = @intCast(self.scrollbackCount());
        const rows_i: i32 = @intCast(self.rows);
        var open_link_id: u8 = 0;

        var r: i32 = -sb_count;
        while (r < rows_i) : (r += 1) {
            const line_cells = self.lineCellsAt(r) orelse {
                // Soft-wrap-aware: blank rows still emit '\n' unless
                // the NEXT row is a continuation (rare for missing
                // rows but match the trimming convention).
                const next_continues = if (self.lineAt(r + 1)) |l| l.continues_above else false;
                if (!next_continues) try out.append(allocator, '\n');
                continue;
            };
            var hi: usize = line_cells.len;
            while (hi > 0 and line_cells[hi - 1].rune == 0) hi -= 1;

            var col: usize = 0;
            while (col < hi) : (col += 1) {
                const cell = line_cells[col];
                if (cell.flags & 0b0000_0010 != 0) continue;

                const has_link = (cell.flags & 0b0000_0100) != 0;
                const cell_link_id: u8 = if (has_link) cell.reserved else 0;
                if (cell_link_id != open_link_id) {
                    if (open_link_id != 0) {
                        if (self.linkUri(open_link_id)) |uri| {
                            try out.append(allocator, ']');
                            try out.append(allocator, '(');
                            const need_angle = std.mem.indexOfScalar(u8, uri, ')') != null;
                            if (need_angle) try out.append(allocator, '<');
                            try out.appendSlice(allocator, uri);
                            if (need_angle) try out.append(allocator, '>');
                            try out.append(allocator, ')');
                        } else {
                            try out.append(allocator, ']');
                        }
                    }
                    if (cell_link_id != 0) try out.append(allocator, '[');
                    open_link_id = cell_link_id;
                }

                const cp = cell.rune;
                if (cp == 0) {
                    try out.append(allocator, ' ');
                } else if (cp < 0x80) {
                    try out.append(allocator, @intCast(cp));
                } else {
                    var ub: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &ub) catch continue;
                    try out.appendSlice(allocator, ub[0..n]);
                }
                if (r >= 0 and r < rows_i) {
                    const cluster = self.clusterAt(@intCast(r), @intCast(col));
                    for (cluster) |ext_cp| {
                        var eb: [4]u8 = undefined;
                        const en = std.unicode.utf8Encode(@intCast(ext_cp), &eb) catch continue;
                        try out.appendSlice(allocator, eb[0..en]);
                    }
                }
            }
            // Suppress newline when next row is a soft-wrap continuation.
            const next_continues = if (self.lineAt(r + 1)) |l| l.continues_above else false;
            if (!next_continues) try out.append(allocator, '\n');
        }
        if (open_link_id != 0) {
            if (self.linkUri(open_link_id)) |uri| {
                try out.append(allocator, ']');
                try out.append(allocator, '(');
                try out.appendSlice(allocator, uri);
                try out.append(allocator, ')');
            } else {
                try out.append(allocator, ']');
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Returns the cells slice for a display row, including scrollback
    /// (negative rows). Returns null on out-of-range.
    fn lineCellsAt(self: *const Screen, row: i32) ?[]Cell {
        return if (self.lineAt(row)) |l| l.cells else null;
    }

    /// Public alias of lineCellsAt for UI lookups (e.g. mouse-cell
    /// resolution that needs to peek at scrollback).
    pub fn lineCellsAtPub(self: *const Screen, row: i32) ?[]Cell {
        return self.lineCellsAt(row);
    }

    /// True iff the row contains a codepoint that needs fribidi
    /// reorder (RTL scripts) or HarfBuzz complex-script shaping
    /// (Indic, Thai, Khmer, Tibetan, Myanmar). Pure ASCII / Latin
    /// extended / Greek / Cyrillic / CJK / emoji / box-drawing /
    /// math symbols all return false — they render correctly in
    /// the fast cell-instance pipeline.
    pub fn rowNeedsBidiOrComplexShape(cells: []const Cell) bool {
        for (cells) |cl| {
            const cp = cl.rune;
            if (cp <= 0x7F) continue;
            if (cp >= 0x0590 and cp <= 0x08FF) return true; // Hebrew/Arabic/Syriac/Thaana/NKo/Samaritan
            if (cp >= 0xFB50 and cp <= 0xFDFF) return true; // Arabic Pres-Forms-A
            if (cp >= 0xFE70 and cp <= 0xFEFF) return true; // Arabic Pres-Forms-B
            if (cp >= 0x0900 and cp <= 0x0DFF) return true; // Indic / Sinhala
            if (cp >= 0x0E00 and cp <= 0x0EFF) return true; // Thai / Lao
            if (cp >= 0x0F00 and cp <= 0x0FFF) return true; // Tibetan
            if (cp >= 0x1000 and cp <= 0x109F) return true; // Myanmar
            if (cp >= 0xAA60 and cp <= 0xAA7F) return true; // Myanmar Extended-A
            if (cp >= 0x1780 and cp <= 0x17FF) return true; // Khmer
        }
        return false;
    }

    /// Map a visual column (what the user clicked at, in left-to-right
    /// pixel order) to a logical column (how the cells live in the
    /// row buffer). For pure-LTR rows the two are identical; bidi
    /// rows differ.
    ///
    /// `allocator` is borrowed for fribidi's transient buffers; on
    /// allocation failure the function returns the input unchanged.
    pub fn visualToLogicalCol(self: *const Screen, allocator: std.mem.Allocator, row: i32, visual_col: u16) u16 {
        const cells = self.lineCellsAt(row) orelse return visual_col;
        if (!rowNeedsBidiOrComplexShape(cells)) return visual_col;
        const bidi = @import("bidi.zig");
        const cps = allocator.alloc(u32, cells.len) catch return visual_col;
        defer allocator.free(cps);
        const lvls = allocator.alloc(u8, cells.len) catch return visual_col;
        defer allocator.free(lvls);
        const idx = allocator.alloc(usize, cells.len) catch return visual_col;
        defer allocator.free(idx);
        for (cells, 0..) |cl, i| {
            cps[i] = if (cl.rune == 0) ' ' else cl.rune;
            idx[i] = i;
        }
        _ = bidi.lineLevels(cps, lvls, .auto);
        bidi.levelsToVisualOrder(lvls, idx);
        const v: usize = visual_col;
        if (v >= idx.len) return visual_col;
        return @intCast(idx[v]);
    }

    /// Inverse of `visualToLogicalCol`. Returns the visual column at
    /// which a logical column will appear after bidi reorder.
    pub fn logicalToVisualCol(self: *const Screen, allocator: std.mem.Allocator, row: i32, logical_col: u16) u16 {
        const cells = self.lineCellsAt(row) orelse return logical_col;
        if (!rowNeedsBidiOrComplexShape(cells)) return logical_col;
        const bidi = @import("bidi.zig");
        const cps = allocator.alloc(u32, cells.len) catch return logical_col;
        defer allocator.free(cps);
        const lvls = allocator.alloc(u8, cells.len) catch return logical_col;
        defer allocator.free(lvls);
        const idx = allocator.alloc(usize, cells.len) catch return logical_col;
        defer allocator.free(idx);
        for (cells, 0..) |cl, i| {
            cps[i] = if (cl.rune == 0) ' ' else cl.rune;
            idx[i] = i;
        }
        _ = bidi.lineLevels(cps, lvls, .auto);
        bidi.levelsToVisualOrder(lvls, idx);
        for (idx, 0..) |logical, visual| if (logical == logical_col) return @intCast(visual);
        return logical_col;
    }

    pub const SearchMatch = struct {
        /// Display-row coordinate. Negative = scrollback (-1 = bottom).
        row: i32,
        col: u32,
        len: u32,
    };

    pub const HintOverlay = struct {
        /// Display row (0..rows-1).
        row: u16,
        col_start: u16,
        col_end: u16,
        /// Label text + how many of its chars were already typed.
        label: [2]u8,
        label_len: u8,
        typed: u8,
    };

    pub const CopyCursor = struct {
        /// Display-row coordinate. Negative = scrollback (-1 = bottom).
        row: i32,
        col: u16,
    };

    /// Linear scan over scrollback + active (visible) buffer for
    /// `needle`. Case-sensitive, single-line only (no wrap join).
    /// Caller frees the returned slice.
    pub fn search(self: *const Screen, allocator: std.mem.Allocator, needle: []const u8) ![]SearchMatch {
        return self.searchOpts(allocator, needle, false);
    }

    /// Regex variant — uses POSIX Extended Regular Expressions
    /// (regcomp + REG_EXTENDED). Invalid patterns return an empty
    /// match list silently; the caller surface assumes regex-search
    /// can fail without disrupting the UI. `case_insensitive` adds
    /// REG_ICASE to the compile flags.
    pub fn searchOptsRegex(
        self: *const Screen,
        allocator: std.mem.Allocator,
        pattern: []const u8,
        case_insensitive: bool,
    ) ![]SearchMatch {
        var out: std.ArrayList(SearchMatch) = .empty;
        defer out.deinit(allocator);
        if (pattern.len == 0) return try out.toOwnedSlice(allocator);

        // regcomp wants a NUL-terminated pattern.
        const pat_z = try allocator.allocSentinel(u8, pattern.len, 0);
        defer allocator.free(pat_z);
        @memcpy(pat_z, pattern);

        // glibc declares `struct re_pattern_buffer` with bitfields
        // that translate-c can't model — Zig sees regex_t as opaque,
        // so we can't stack-allocate. Heap-alloc with a generous
        // fixed buffer; on x86_64 glibc the real size is ~64 bytes.
        const cre = @import("../c.zig").c;
        const re_buf = std.c.malloc(256) orelse return error.OutOfMemory;
        defer std.c.free(re_buf);
        const re: *cre.regex_t = @ptrCast(@alignCast(re_buf));
        const ci_flag: c_int = if (case_insensitive) cre.REG_ICASE else 0;
        const flags: c_int = cre.REG_EXTENDED | ci_flag;
        if (cre.regcomp(re, pat_z.ptr, flags) != 0) {
            return try out.toOwnedSlice(allocator);
        }
        defer cre.regfree(re);

        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(allocator);
        var col_map: std.ArrayList(u32) = .empty;
        defer col_map.deinit(allocator);
        var width_map: std.ArrayList(u8) = .empty;
        defer width_map.deinit(allocator);

        const sb_count = self.scrollbackCount();
        var i: u32 = 0;
        while (i < sb_count) : (i += 1) {
            const row: i32 = @as(i32, @intCast(i)) - @as(i32, @intCast(sb_count));
            try renderLineForSearch(allocator, self, row, &line_buf, &col_map, &width_map);
            try findRegexMatches(allocator, re, line_buf.items, col_map.items, width_map.items, row, &out);
        }
        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            try renderLineForSearch(allocator, self, @intCast(r), &line_buf, &col_map, &width_map);
            try findRegexMatches(allocator, re, line_buf.items, col_map.items, width_map.items, @intCast(r), &out);
        }
        return try out.toOwnedSlice(allocator);
    }

    pub fn searchOpts(
        self: *const Screen,
        allocator: std.mem.Allocator,
        needle: []const u8,
        case_insensitive: bool,
    ) ![]SearchMatch {
        var out: std.ArrayList(SearchMatch) = .empty;
        defer out.deinit(allocator);
        if (needle.len == 0) return try out.toOwnedSlice(allocator);

        // Lowercase the needle once (ASCII-only fold for v1; UTF-8
        // case-folding would need the unicode case table).
        var folded_needle: []u8 = &.{};
        defer if (folded_needle.len > 0) allocator.free(folded_needle);
        const search_needle: []const u8 = if (case_insensitive) blk: {
            const lc = try allocator.alloc(u8, needle.len);
            for (needle, 0..) |b, i| lc[i] = std.ascii.toLower(b);
            folded_needle = lc;
            break :blk lc;
        } else needle;

        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(allocator);
        var col_map: std.ArrayList(u32) = .empty;
        defer col_map.deinit(allocator);
        // Parallel array: width of the cell at col_map[i] (1 or 2).
        // Used to compute visual end column on matches whose last cell
        // is wide (CJK / emoji).
        var width_map: std.ArrayList(u8) = .empty;
        defer width_map.deinit(allocator);

        // Scrollback: rows -1, -2, … walked from oldest (-sb_count) up.
        const sb_count = self.scrollbackCount();
        var i: u32 = 0;
        while (i < sb_count) : (i += 1) {
            const row: i32 = @as(i32, @intCast(i)) - @as(i32, @intCast(sb_count));
            try renderLineForSearch(allocator, self, row, &line_buf, &col_map, &width_map);
            try findMatches(allocator, line_buf.items, col_map.items, width_map.items, search_needle, row, &out, case_insensitive);
        }
        // Active screen.
        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            try renderLineForSearch(allocator, self, @intCast(r), &line_buf, &col_map, &width_map);
            try findMatches(allocator, line_buf.items, col_map.items, width_map.items, search_needle, @intCast(r), &out, case_insensitive);
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Returns a *const Line at a display row, or null on OOB.
    fn lineAt(self: *const Screen, row: i32) ?*const Line {
        if (row >= 0 and row < @as(i32, @intCast(self.rows))) {
            const buf_const = if (self.use_alt) self.alt.? else self.active;
            return &buf_const[@intCast(row)];
        }
        if (row < 0) {
            const idx_from_end: u32 = @intCast(-row - 1);
            const sb_count = self.scrollbackCount();
            if (idx_from_end >= sb_count) return null;
            // Ring-aware: scrollbackLine(0) = oldest, sb_count-1 = newest.
            return self.scrollbackLine(sb_count - 1 - idx_from_end);
        }
        return null;
    }

    pub fn buf(self: *Screen) []Line {
        return if (self.use_alt) self.alt.? else self.active;
    }

    pub fn line(self: *Screen, r: u16) *Line {
        return &self.buf()[r];
    }

    pub fn cellAt(self: *Screen, r: u16, c: u16) *Cell {
        return &self.line(r).cells[c];
    }

    // ── Apply parser events ──────────────────────────────────────

    pub fn apply(self: *Screen, ev: Event) void {
        self.dirty = true;
        // A pending Unicode placeholder is complete once anything other
        // than more printable text arrives (cursor move, newline, CSI,
        // …). Print events finalize it themselves as the next base char
        // lands, so leave those alone.
        switch (ev) {
            .print, .print_byte, .print_run => {},
            else => if (self.ph_pending != null) self.flushPlaceholder(),
        }
        switch (ev) {
            .print => |cp| self.printCp(cp),
            .print_byte => |b| self.printByte(b),
            .print_run => |run| {
                // Single SIMD scan for ascii-ness, dispatched to the
                // tightest tier the screen state supports:
                //   Tier 1 — fastAsciiSlice path (full run, cell-array
                //            direct write; preconditions cleanest).
                //   Tier 2 — ASCII run but state forbids Tier 1 (e.g.
                //            insert_mode, pending_wrap, charset != ascii)
                //            → printCp per byte.
                //   Tier 2.5 — mixed UTF-8 with lookahead decoding.
                const slice = run.bytes[0..run.len];
                const decoder_idle = self.decoder.expected == 0;
                const ascii_run = decoder_idle and runIsAscii(slice);
                if (ascii_run and self.fastAsciiEligible()) {
                    self.fastAsciiSlice(slice);
                } else if (ascii_run) {
                    // Tier 2: skip UTF-8 decoder; per-byte printCp.
                    var i: usize = 0;
                    while (i < run.len) : (i += 1) self.printCp(run.bytes[i]);
                } else {
                    // Tier 2.5: mixed run. Lookahead-based UTF-8
                    // decoding instead of per-byte Decoder.feed:
                    //   - ASCII bytes via printCp (direct, no decoder).
                    //   - Multi-byte: classify leading byte, read all
                    //     continuation bytes in one shot, decode + print.
                    //   - Falls back to Decoder.feed only when the run
                    //     ends mid-codepoint (decoder retains state for
                    //     the next run).
                    var i: usize = 0;
                    while (i < run.len) {
                        const b0 = run.bytes[i];
                        if (self.decoder.expected == 0) {
                            if (b0 < 0x80) {
                                // ASCII subrange. print_run only carries
                                // bytes the parser already classified as
                                // printable (>=0x20 && !=0x7F), so we
                                // can skip the runIsAscii double-check.
                                const start = i;
                                while (i < run.len and run.bytes[i] < 0x80) : (i += 1) {}
                                if (self.fastAsciiEligible()) {
                                    self.fastAsciiSlice(run.bytes[start..i]);
                                } else {
                                    for (run.bytes[start..i]) |b| self.printCp(b);
                                }
                                continue;
                            }
                            const cp_len: usize = if ((b0 & 0xE0) == 0xC0) 2 else if ((b0 & 0xF0) == 0xE0) 3 else if ((b0 & 0xF8) == 0xF0) 4 else 0;
                            if (cp_len == 0) {
                                // Invalid leading byte — drop.
                                i += 1;
                                continue;
                            }
                            if (i + cp_len <= run.len) {
                                // All bytes present — validate and
                                // decode in one shot, no decoder state.
                                const cp = decodeUtf8Lookahead(run.bytes[i .. i + cp_len], cp_len);
                                if (cp) |c| self.printCp(c);
                                i += cp_len;
                            } else {
                                // Incomplete at run end — let the
                                // stateful decoder hold the partial
                                // bytes for the next run.
                                while (i < run.len) : (i += 1) self.printByte(run.bytes[i]);
                                break;
                            }
                        } else {
                            // Decoder is mid-codepoint from a previous
                            // run — feed continuation bytes until done.
                            self.printByte(b0);
                            i += 1;
                        }
                    }
                }
            },
            .execute => |b| self.execute(b),
            .csi => |c_csi| self.csi(c_csi),
            .esc_final => |ef| self.escFinal(ef),
            .osc => |osc| self.onOsc(osc.bytes),
            .apc => |apc| self.onApc(apc.bytes),
            .dcs => |d| self.onDcs(d),
            .dcs_start, .dcs_data, .dcs_end => {}, // legacy stubs
            .child_eof => |status| self.onChildEof(status),
            .parse_error => |pe| onParseError(pe),
        }
    }

    /// A recoverable parser error reached the main thread (the payload was
    /// still applied best-effort). Logged here rather than on the worker so
    /// it travels through the normal event pipeline, including over mux.
    fn onParseError(pe: Event.ParseError) void {
        const what = switch (pe.kind) {
            .dcs_truncated => "DCS",
            .osc_truncated => "OSC",
            .apc_truncated => "APC",
        };
        std.debug.print("sketerm: {s} payload truncated (too long)\n", .{what});
    }

    /// Reply current fg/bg/cursor color in xterm `rgb:RRRR/GGGG/BBBB` form.
    fn respondColor(self: *Screen, osc_num: u32) void {
        const rgba = switch (osc_num) {
            10 => self.default_fg,
            11 => self.default_bg,
            12 => if (self.cursor_color[3] > 0) self.cursor_color else self.default_fg,
            else => return,
        };
        const r16: u16 = @intFromFloat(@round(rgba[0] * 65535.0));
        const g16: u16 = @intFromFloat(@round(rgba[1] * 65535.0));
        const b16: u16 = @intFromFloat(@round(rgba[2] * 65535.0));
        var resp_buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&resp_buf, "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{
            osc_num, r16, g16, b16,
        }) catch return;
        self.respond(s);
    }

    /// Parse an xterm color spec: `rgb:RRRR/GGGG/BBBB` (or 2-hex
    /// per-component form) or `#RRGGBB`. Returns null on bad input.
    fn parseColor(s: []const u8) ?[4]f32 {
        if (std.mem.startsWith(u8, s, "rgb:")) {
            const rest = s[4..];
            var it = std.mem.splitScalar(u8, rest, '/');
            const r = it.next() orelse return null;
            const g = it.next() orelse return null;
            const b = it.next() orelse return null;
            return .{
                hexToFloat(r),
                hexToFloat(g),
                hexToFloat(b),
                1.0,
            };
        }
        if (s.len >= 7 and s[0] == '#') {
            const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
            const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
            const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
            return .{
                @as(f32, @floatFromInt(r)) / 255.0,
                @as(f32, @floatFromInt(g)) / 255.0,
                @as(f32, @floatFromInt(b)) / 255.0,
                1.0,
            };
        }
        return null;
    }

    /// Convert a 1..4-hex component string into a 0..1 float.
    fn hexToFloat(s: []const u8) f32 {
        if (s.len == 0 or s.len > 4) return 0;
        const v = std.fmt.parseInt(u32, s, 16) catch return 0;
        const max: u32 = (@as(u32, 1) << @intCast(s.len * 4)) - 1;
        return @as(f32, @floatFromInt(v)) / @as(f32, @floatFromInt(max));
    }

    /// OSC 4 — palette query/set. `OSC 4 ; n ; ?` queries; any
    /// other payload after the index is parsed as a color spec.
    /// Parse a ConEmu progress payload: the part after `OSC 9 ;`.
    /// Accepts `4`, `4;st` and `4;st;pr` with digit-only fields and
    /// st 0-4; pr clamps to 100. Anything else returns null so the
    /// caller can fall back to the notification meaning of OSC 9.
    pub fn parseProgress(rest: []const u8) ?struct { state: u8, percent: u8 } {
        if (rest.len == 0 or rest[0] != '4') return null;
        if (rest.len == 1) return .{ .state = 0, .percent = 0 };
        if (rest[1] != ';') return null;
        var it = std.mem.splitScalar(u8, rest[2..], ';');
        const state = std.fmt.parseInt(u8, it.next() orelse return null, 10) catch return null;
        if (state > 4) return null;
        const percent: u8 = if (it.next()) |p|
            @intCast(@min(std.fmt.parseInt(u32, p, 10) catch return null, 100))
        else
            0;
        if (it.next() != null) return null;
        return .{ .state = state, .percent = percent };
    }

    fn handleOsc4(self: *Screen, rest: []const u8) void {
        // xterm form allows MULTIPLE `idx;spec` pairs in one OSC 4
        // (pywal & friends set all 16 ANSI colors in one sequence).
        var it = std.mem.splitScalar(u8, rest, ';');
        while (it.next()) |idx_str| {
            const data = it.next() orelse return;
            const idx = std.fmt.parseInt(u8, idx_str, 10) catch return;
            if (data.len == 1 and data[0] == '?') {
                const rgb = self.palette[idx];
                var resp_buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&resp_buf, "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                    idx, rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2],
                }) catch return;
                self.respond(s);
                continue;
            }
            // Set form.
            if (Screen.parseColor(data)) |rgba| {
                self.palette[idx] = .{
                    @intFromFloat(@round(rgba[0] * 255.0)),
                    @intFromFloat(@round(rgba[1] * 255.0)),
                    @intFromFloat(@round(rgba[2] * 255.0)),
                };
                self.dirty = true;
            }
        }
    }

    fn clearNotifyAccum(self: *Screen) void {
        self.notify_title.clearRetainingCapacity();
        self.notify_body.clearRetainingCapacity();
        self.notify_buttons.clearRetainingCapacity();
        self.notify_icon_data.clearRetainingCapacity();
        self.notify_icon_name.clearRetainingCapacity();
        self.notify_urgency = null;
        self.notify_report = false;
        self.notify_focus = true;
        self.notify_occasion = .always;
        self.notify_id_len = 0;
    }

    /// OSC 99 — kitty desktop-notification protocol.
    /// `metadata ; payload`, metadata COLON-separated k=v. Supported:
    /// `i` id, `d` done, `e=1` base64, `p` title/body/buttons/icon/
    /// close/?, `a` report/focus (− negates), `o` occasion, `u`
    /// urgency, `n` themed-icon name (base64). Not supported (and
    /// omitted from the `p=?` capability reply): `c` close events and
    /// `p=alive` — GNotification gives no closure feedback. `s`
    /// sounds and `w` timeouts likewise.
    fn handleOsc99(self: *Screen, rest: []const u8) void {
        const MAX_TITLE = 512;
        const MAX_BODY = 4096;
        const MAX_BUTTONS = 2048;
        const MAX_ICON = 256 * 1024;
        const Kind = enum { title, body, buttons, icon, close, query, unsupported };

        const semi = std.mem.indexOfScalar(u8, rest, ';');
        const meta = if (semi) |s| rest[0..s] else rest;
        const payload_raw = if (semi) |s| rest[s + 1 ..] else "";

        var id: []const u8 = "0";
        var done = true;
        var kind: Kind = .title;
        var is_b64 = false;
        var urgency: ?u8 = null;
        var report: ?bool = null;
        var focus: ?bool = null;
        var occasion: ?NotificationEvent.Occasion = null;
        var icon_name_b64: []const u8 = "";
        var it = std.mem.splitScalar(u8, meta, ':');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            const k = kv[0..eq];
            const v = kv[eq + 1 ..];
            if (std.mem.eql(u8, k, "i")) {
                id = v;
            } else if (std.mem.eql(u8, k, "d")) {
                done = !std.mem.eql(u8, v, "0");
            } else if (std.mem.eql(u8, k, "p")) {
                kind = blk: {
                    if (std.mem.eql(u8, v, "title")) break :blk .title;
                    if (std.mem.eql(u8, v, "body")) break :blk .body;
                    if (std.mem.eql(u8, v, "buttons")) break :blk .buttons;
                    if (std.mem.eql(u8, v, "icon")) break :blk .icon;
                    if (std.mem.eql(u8, v, "close")) break :blk .close;
                    if (std.mem.eql(u8, v, "?")) break :blk .query;
                    break :blk .unsupported; // alive, future kinds
                };
            } else if (std.mem.eql(u8, k, "e")) {
                is_b64 = std.mem.eql(u8, v, "1");
            } else if (std.mem.eql(u8, k, "u")) {
                const u = std.fmt.parseInt(u8, v, 10) catch continue;
                if (u <= 2) urgency = u;
            } else if (std.mem.eql(u8, k, "a")) {
                var ait = std.mem.splitScalar(u8, v, ',');
                while (ait.next()) |act| {
                    if (std.mem.eql(u8, act, "report")) report = true;
                    if (std.mem.eql(u8, act, "-report")) report = false;
                    if (std.mem.eql(u8, act, "focus")) focus = true;
                    if (std.mem.eql(u8, act, "-focus")) focus = false;
                }
            } else if (std.mem.eql(u8, k, "o")) {
                occasion = std.meta.stringToEnum(NotificationEvent.Occasion, v);
            } else if (std.mem.eql(u8, k, "n")) {
                if (icon_name_b64.len == 0) icon_name_b64 = v;
            }
            // Unknown keys (g, c, s, t, w, f, …): ignore, per spec.
        }

        var id_buf: [64]u8 = undefined;
        const safe_id = sanitizeNotifyId(id, &id_buf);

        if (kind == .query) {
            // Capability reply — advertise only what we honour.
            var resp_buf: [192]u8 = undefined;
            const out = std.fmt.bufPrint(
                &resp_buf,
                "\x1b]99;i={s}:p=?;a=report,focus:o=always,unfocused,invisible:p=title,body,buttons,icon,close:u=0,1,2\x1b\\",
                .{safe_id},
            ) catch return;
            self.respond(out);
            return;
        }
        if (kind == .close) {
            if (self.sink.on_notification) |f| f(self.sink.ctx, .{ .id = safe_id, .close = true });
            return;
        }
        if (kind == .unsupported) return;

        // New identifier discards any unfinished accumulation.
        const cur_id = self.notify_id[0..self.notify_id_len];
        if (!std.mem.eql(u8, cur_id, id)) {
            self.clearNotifyAccum();
            const n: u8 = @intCast(@min(id.len, self.notify_id.len));
            @memcpy(self.notify_id[0..n], id[0..n]);
            self.notify_id_len = n;
        }

        // Metadata flags persist across the chunks of one id.
        if (urgency) |u| self.notify_urgency = u;
        if (report) |r| self.notify_report = r;
        if (focus) |fo| self.notify_focus = fo;
        if (occasion) |o| self.notify_occasion = o;
        if (icon_name_b64.len > 0 and self.notify_icon_name.items.len == 0) {
            var name_buf: [128]u8 = undefined;
            const decoder = std.base64.standard.Decoder;
            const n_len = decoder.calcSizeForSlice(icon_name_b64) catch 0;
            if (n_len > 0 and n_len <= name_buf.len) {
                if (decoder.decode(name_buf[0..n_len], icon_name_b64)) {
                    self.notify_icon_name.appendSlice(self.allocator, name_buf[0..n_len]) catch {};
                } else |_| {}
            }
        }

        // Decode payload (base64 or raw) and append to its part.
        var decode_buf: [4096]u8 = undefined;
        var payload: []const u8 = payload_raw;
        if (is_b64) {
            payload = "";
            const decoder = std.base64.standard.Decoder;
            const out_len = decoder.calcSizeForSlice(payload_raw) catch 0;
            if (out_len > 0 and out_len <= decode_buf.len) {
                if (decoder.decode(decode_buf[0..out_len], payload_raw)) {
                    payload = decode_buf[0..out_len];
                } else |_| {}
            }
        }
        const dst = switch (kind) {
            .title => &self.notify_title,
            .body => &self.notify_body,
            .buttons => &self.notify_buttons,
            .icon => &self.notify_icon_data,
            else => unreachable,
        };
        const cap: usize = switch (kind) {
            .title => MAX_TITLE,
            .body => MAX_BODY,
            .buttons => MAX_BUTTONS,
            .icon => MAX_ICON,
            else => unreachable,
        };
        const take = @min(payload.len, cap -| dst.items.len);
        dst.appendSlice(self.allocator, payload[0..take]) catch {};

        if (!done) return;
        const title: []const u8 = if (self.notify_title.items.len > 0)
            self.notify_title.items
        else
            "sketerm";
        if (self.sink.on_notification) |f| f(self.sink.ctx, .{
            .id = safe_id,
            .title = title,
            .body = self.notify_body.items,
            .icon_name = self.notify_icon_name.items,
            .icon_data = self.notify_icon_data.items,
            .buttons_raw = self.notify_buttons.items,
            .urgency = self.notify_urgency,
            .want_report = self.notify_report,
            .want_focus = self.notify_focus,
            .occasion = self.notify_occasion,
        });
        self.clearNotifyAccum();
    }

    fn handleOsc8(self: *Screen, params: []const u8) void {
        // Format: `id=foo;URI` or just `URI` (params optional).
        // Empty URI = end of link.
        const semi = std.mem.indexOfScalar(u8, params, ';');
        const uri = if (semi) |s| params[s + 1 ..] else params;
        if (uri.len == 0) {
            self.current_link_id = 0;
            return;
        }
        const owned = self.allocator.dupe(u8, uri) catch return;
        if (self.next_link_id == 0) self.next_link_id = 1;
        const id = self.next_link_id;
        // Replace any existing entry at this id (free old).
        if (self.links.fetchRemove(id)) |old| self.allocator.free(old.value);
        self.links.put(id, owned) catch {
            self.allocator.free(owned);
            return;
        };
        self.next_link_id +%= 1; // wraps from 255 → 1 (we set 0 → 1 above)
        if (self.next_link_id == 0) self.next_link_id = 1;
        self.current_link_id = id;
    }

    /// Look up the URI for a cell's link_id (from Cell.reserved).
    pub fn linkUri(self: *const Screen, link_id: u8) ?[]const u8 {
        if (link_id == 0) return null;
        return if (self.links.get(link_id)) |u| u else null;
    }

    /// Auto-URL detector lookup at a visible (row, col). Considers
    /// scrollback if `view_offset > 0`. Returns the URL text owned
    /// by the caller via the provided allocator. null = no URL.
    pub fn urlAtVisible(self: *Screen, allocator: std.mem.Allocator, vrow: i32, vcol: i32) !?[]u8 {
        if (vrow < 0 or vrow >= @as(i32, @intCast(self.rows))) return null;
        if (vcol < 0 or vcol >= @as(i32, @intCast(self.cols))) return null;

        const url_scan = @import("url_scan.zig");
        const cells = self.lineCellsAtPub(vrow) orelse return null;
        var matches: [16]url_scan.Match = undefined;
        const n = url_scan.scanRow(cells, &matches);
        if (n == 0) return null;
        const col_u: u16 = @intCast(vcol);
        for (matches[0..n]) |m| {
            if (col_u >= m.col_start and col_u < m.col_end) {
                // Extract ASCII URL text. URLs are ASCII-only (RFC),
                // so a flat copy of `cell.rune` low byte works.
                var url_buf = try allocator.alloc(u8, m.col_end - m.col_start);
                errdefer allocator.free(url_buf);
                for (m.col_start..m.col_end, 0..) |src, dst| {
                    url_buf[dst] = @intCast(cells[src].rune & 0xFF);
                }
                return url_buf;
            }
        }
        return null;
    }

    /// OSC 1337 — iTerm2 multi-purpose protocol. Two formats:
    ///   File=<attrs>:<base64>  → inline image (existing path)
    ///   <Key>=<Value>          → directive (CursorShape, ClearScrollback,
    ///                            RequestAttention, SetMark,
    ///                            CopyToClipboard, ...)
    ///   <Key>                  → bare directive (ClearScrollback,
    ///                            StealFocus)
    fn handleOsc1337(self: *Screen, rest: []const u8) void {
        // File=...:<b64> still goes to the inline-image decoder.
        if (rest.len >= 5 and std.mem.eql(u8, rest[0..5], "File=")) {
            const iterm = @import("../parser/iterm_image.zig");
            const decoded = iterm.decodePayload(self.allocator, rest) catch return;
            defer self.allocator.free(decoded.rgba);
            if (decoded.format != .png or decoded.rgba.len == 0) return;
            // `inline=0` (the protocol's default) means "transfer this
            // file, don't show it". We have no download side, so those
            // are dropped rather than drawn where the app expects
            // nothing.
            if (!decoded.inline_display) return;
            // The requested box is in cells, pixels, percent or auto;
            // resolve it against this pane's real metrics. Zero cell
            // pixels means Pane.onResize hasn't reported yet — use the
            // CSI 14t fallback, same as ReportCellSize.
            const cw: u32 = if (self.cell_pixel_w > 0) self.cell_pixel_w else 8;
            const ch: u32 = if (self.cell_pixel_h > 0) self.cell_pixel_h else 16;
            const cells = iterm.resolveCells(decoded, cw, ch, self.cols, self.rows);
            self.emitImage(.{
                .width = decoded.width,
                .height = decoded.height,
                .rgba = decoded.rgba,
                .row = self.row,
                .col = self.col,
                .placement_id = 0,
                .z_index = 0,
                .cells_wide = cells[0],
                .cells_high = cells[1],
            });
            return;
        }

        // Directive: split at first '='. If no '=', treat the whole
        // payload as a bare key.
        const eq = std.mem.indexOfScalar(u8, rest, '=');
        const key = if (eq) |e| rest[0..e] else rest;
        const val = if (eq) |e| rest[e + 1 ..] else "";

        if (std.mem.eql(u8, key, "CursorShape")) {
            // 0=block, 1=vertical bar, 2=underline. Map to the
            // closest DECSCUSR variant (steady, not blinking).
            const n = std.fmt.parseInt(u8, val, 10) catch return;
            self.cursor_shape = switch (n) {
                0 => .block_steady,
                1 => .bar_steady,
                2 => .underline_steady,
                else => self.cursor_shape,
            };
            self.dirty = true;
            return;
        }
        if (std.mem.eql(u8, key, "ClearScrollback")) {
            self.clearAndScrollback();
            return;
        }
        if (std.mem.eql(u8, key, "SetMark")) {
            self.recordPromptMark();
            return;
        }
        if (std.mem.eql(u8, key, "RequestAttention")) {
            // Values: yes / fireworks / once / no. We surface as a
            // notification so the WM/desktop applies its needs-attention
            // hint via AdwTabPage / GtkApplication user-attention.
            if (self.sink.on_notification) |f| f(self.sink.ctx, .{ .title = "sketerm", .body = "attention" });
            return;
        }
        if (std.mem.eql(u8, key, "StealFocus")) {
            // Untrusted apps shouldn't steal focus. Drop silently.
            return;
        }
        if (std.mem.eql(u8, key, "CopyToClipboard")) {
            // Empty value = begin capture; non-empty = legacy
            // single-payload form. iTerm2 also pairs this with
            // EndCopy. We treat the inline form as immediate copy.
            if (val.len > 0 and self.sink.on_clipboard_set != null) {
                if (self.sink.on_clipboard_set) |f| f(self.sink.ctx, val);
            }
            return;
        }
        if (std.mem.eql(u8, key, "EndCopy")) {
            // No-op: we don't accumulate streamed copy content.
            return;
        }
        if (std.mem.eql(u8, key, "ReportCellSize")) {
            // Reply `1337 ; ReportCellSize=<height>;<width>;<scale>`.
            // Pixel dims come from Pane.onResize; 0 falls back to the
            // CSI 14t defaults (8x16). Scale is always 1.0 — we report
            // device pixels, not points.
            const cw: u32 = if (self.cell_pixel_w > 0) self.cell_pixel_w else 8;
            const ch: u32 = if (self.cell_pixel_h > 0) self.cell_pixel_h else 16;
            var resp_buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&resp_buf, "\x1b]1337;ReportCellSize={d};{d};1.0\x1b\\", .{ ch, cw }) catch return;
            self.respond(s);
            return;
        }
        if (std.mem.eql(u8, key, "SetUserVar")) {
            // `SetUserVar=<name>=<base64-value>`. Empty value clears.
            const veq = std.mem.indexOfScalar(u8, val, '=') orelse return;
            const name = val[0..veq];
            const b64 = val[veq + 1 ..];
            if (name.len == 0) return;
            if (b64.len == 0) {
                self.setUserVar(name, "");
                return;
            }
            const decoder = std.base64.standard.Decoder;
            const out_len = decoder.calcSizeForSlice(b64) catch return;
            if (out_len > 4096) return; // sanity cap per value
            var dec_buf: [4096]u8 = undefined;
            decoder.decode(dec_buf[0..out_len], b64) catch return;
            self.setUserVar(name, dec_buf[0..out_len]);
            return;
        }
        if (std.mem.eql(u8, key, "SetColors")) {
            // `SetColors=<name>=<spec>[ , <name>=<spec> ...]`. Maps the
            // iTerm names we render onto our color state.
            var it = std.mem.splitScalar(u8, val, ',');
            while (it.next()) |pair| {
                const peq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                self.applyNamedColor(pair[0..peq], pair[peq + 1 ..]);
            }
            self.dirty = true;
            return;
        }
        if (std.mem.eql(u8, key, "SetProfile")) {
            // Request the GUI switch this pane's profile. Untrusted, so
            // the sink decides whether to honor it (unknown name = Default).
            if (self.sink.on_set_profile) |f| f(self.sink.ctx, val);
            return;
        }
        // Unknown key — silently drop (SetBadgeFormat, etc.).
    }

    /// OSC 133 / 633 `C` — mark where the running command's output
    /// begins. No-op on the alt screen. Mid-line C (cursor not at
    /// column 0) means the command-echo line is still current — defer
    /// the capture to the next linefeed so the zone holds only output.
    fn cmdOutputStart(self: *Screen) void {
        if (self.use_alt or self.row >= self.rows) return;
        if (self.col == 0) {
            self.pending_output_start_id = self.active[self.row].id;
            self.pending_output_awaits_nl = false;
        } else {
            self.pending_output_start_id = 0;
            self.pending_output_awaits_nl = true;
        }
        if (self.sink.on_cmd_start) |f| f(self.sink.ctx);
    }

    /// OSC 133 / 633 `D` — close the command-output zone opened by
    /// `cmdOutputStart`. `exit_str` is the optional exit-code field
    /// (empty = unknown → 0).
    fn cmdOutputEnd(self: *Screen, exit_str: []const u8) void {
        if (self.use_alt or self.row >= self.rows) {
            // A dead TUI can leave the alt screen active while the
            // shell prints its next prompt (and this D) into it. No
            // zone to record there, but with an open C the completion
            // signal must still fire or command-mode waiters and the
            // busy check wedge until the whole shell exits.
            if (self.pending_output_start_id != 0 or self.pending_output_awaits_nl) {
                self.pending_output_start_id = 0;
                self.pending_output_awaits_nl = false;
                self.last_cmd_exit = if (exit_str.len > 0) (std.fmt.parseInt(i32, exit_str, 10) catch 0) else 0;
                self.cmd_completion_seq +%= 1;
                if (self.sink.on_cmd_end) |f| f(self.sink.ctx, self.last_cmd_exit);
            }
            return;
        }
        // C deferred to a newline that never came (command printed
        // nothing, D reached first): an empty zone at the current row
        // still carries the exit code.
        if (self.pending_output_awaits_nl) {
            self.pending_output_awaits_nl = false;
            self.pending_output_start_id = self.active[self.row].id;
        }
        const start_id = self.pending_output_start_id;
        if (start_id == 0) return;
        self.pending_output_start_id = 0;
        self.last_output_start_id = start_id;
        self.last_output_end_id = self.active[self.row].id;
        self.last_cmd_exit = if (exit_str.len > 0) (std.fmt.parseInt(i32, exit_str, 10) catch 0) else 0;
        self.cmd_completion_seq +%= 1;
        self.recordCmdZone(start_id, self.last_output_end_id, self.last_cmd_exit);
        if (self.sink.on_cmd_end) |f| f(self.sink.ctx, self.last_cmd_exit);
    }

    /// VS Code shell integration (`OSC 633`). A superset of OSC 133:
    /// the A/B/C/D prompt marks behave identically, plus `E` (command
    /// line text) and `P;key=value` properties (notably `Cwd`).
    fn handleOsc633(self: *Screen, rest: []const u8) void {
        if (rest.len == 0) return;
        switch (rest[0]) {
            'A' => self.recordPromptMark(),
            'C' => self.cmdOutputStart(),
            'D' => self.cmdOutputEnd(if (rest.len > 2 and rest[1] == ';') rest[2..] else ""),
            // `E ; <command-line> [; <nonce>]` — informational; we have
            // no command-history surface yet, so accept and drop.
            'E' => {},
            // `P ; key=value [; key=value …]` — properties. Only Cwd is
            // actionable today.
            'P' => {
                if (rest.len < 2 or rest[1] != ';') return;
                var it = std.mem.splitScalar(u8, rest[2..], ';');
                while (it.next()) |prop| {
                    const eq = std.mem.indexOfScalar(u8, prop, '=') orelse continue;
                    if (std.mem.eql(u8, prop[0..eq], "Cwd")) {
                        if (self.sink.on_cwd) |f| f(self.sink.ctx, prop[eq + 1 ..]);
                    }
                }
            },
            else => {},
        }
    }

    /// Set / overwrite / clear an iTerm2 user variable. Empty value
    /// removes the entry. Caps the store at USER_VAR_CAP names.
    fn setUserVar(self: *Screen, name: []const u8, value: []const u8) void {
        for (self.user_vars.items, 0..) |uv, i| {
            if (!std.mem.eql(u8, uv.name, name)) continue;
            if (value.len == 0) {
                self.allocator.free(uv.name);
                self.allocator.free(uv.value);
                _ = self.user_vars.swapRemove(i);
                return;
            }
            const newval = self.allocator.dupe(u8, value) catch return;
            self.allocator.free(self.user_vars.items[i].value);
            self.user_vars.items[i].value = newval;
            return;
        }
        if (value.len == 0 or self.user_vars.items.len >= USER_VAR_CAP) return;
        const n = self.allocator.dupe(u8, name) catch return;
        const v = self.allocator.dupe(u8, value) catch {
            self.allocator.free(n);
            return;
        };
        self.user_vars.append(self.allocator, .{ .name = n, .value = v }) catch {
            self.allocator.free(n);
            self.allocator.free(v);
        };
    }

    /// Look up a user variable's value (borrowed). Null if unset.
    pub fn userVar(self: *const Screen, name: []const u8) ?[]const u8 {
        for (self.user_vars.items) |uv| {
            if (std.mem.eql(u8, uv.name, name)) return uv.value;
        }
        return null;
    }

    /// Reply to an OSC 17 / 19 selection-color query. Unset (alpha 0)
    /// falls back to the renderer's built-in highlight (bg) or the
    /// default background read as the selected-text color (fg).
    fn respondSelectionColor(self: *Screen, osc_num: u32) void {
        const stored = if (osc_num == 17) self.selection_bg else self.selection_fg;
        const rgba: [4]f32 = if (stored[3] > 0)
            stored
        else if (osc_num == 17)
            default_selection_bg
        else
            self.default_bg;
        const r16: u16 = @intFromFloat(@round(rgba[0] * 65535.0));
        const g16: u16 = @intFromFloat(@round(rgba[1] * 65535.0));
        const b16: u16 = @intFromFloat(@round(rgba[2] * 65535.0));
        var resp_buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&resp_buf, "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ osc_num, r16, g16, b16 }) catch return;
        self.respond(s);
    }

    /// Apply one iTerm2/kitty color name to our color state. Shared by
    /// OSC 1337 SetColors and OSC 21.
    fn applyNamedColor(self: *Screen, name: []const u8, spec: []const u8) void {
        const rgba = Screen.parseColor(spec) orelse return;
        if (std.mem.eql(u8, name, "fg") or std.mem.eql(u8, name, "foreground")) {
            self.default_fg = rgba;
        } else if (std.mem.eql(u8, name, "bg") or std.mem.eql(u8, name, "background")) {
            self.default_bg = rgba;
        } else if (std.mem.eql(u8, name, "cursor") or std.mem.eql(u8, name, "cursor_color")) {
            self.cursor_color = rgba;
        } else if (std.mem.eql(u8, name, "selection_foreground") or std.mem.eql(u8, name, "selection_text")) {
            self.selection_fg = rgba;
        } else if (std.mem.eql(u8, name, "selection_background") or std.mem.eql(u8, name, "selection")) {
            self.selection_bg = rgba;
        } else if (std.fmt.parseInt(u8, name, 10)) |idx| {
            self.palette[idx] = .{
                @intFromFloat(@round(rgba[0] * 255.0)),
                @intFromFloat(@round(rgba[1] * 255.0)),
                @intFromFloat(@round(rgba[2] * 255.0)),
            };
        } else |_| {}
    }

    /// OSC 21 — kitty's unified color query/set. Payload is a
    /// `;`-separated list of `key=spec` (set) or `key=?` (query)
    /// items. Queries are answered in a single `OSC 21 ; … ST` reply
    /// echoing each queried key with its current rgb value.
    fn handleOsc21(self: *Screen, rest: []const u8) void {
        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(self.allocator);
        var it = std.mem.splitScalar(u8, rest, ';');
        var dirty_set = false;
        while (it.next()) |item| {
            const eq = std.mem.indexOfScalar(u8, item, '=') orelse continue;
            const name = item[0..eq];
            const spec = item[eq + 1 ..];
            if (spec.len == 1 and spec[0] == '?') {
                const rgba = self.namedColorValue(name) orelse continue;
                const r16: u16 = @intFromFloat(@round(rgba[0] * 65535.0));
                const g16: u16 = @intFromFloat(@round(rgba[1] * 65535.0));
                const b16: u16 = @intFromFloat(@round(rgba[2] * 65535.0));
                if (resp.items.len > 0) resp.append(self.allocator, ';') catch {};
                var item_buf: [96]u8 = undefined;
                const piece = std.fmt.bufPrint(&item_buf, "{s}=rgb:{x:0>4}/{x:0>4}/{x:0>4}", .{
                    name, r16, g16, b16,
                }) catch continue;
                resp.appendSlice(self.allocator, piece) catch {};
            } else {
                self.applyNamedColor(name, spec);
                dirty_set = true;
            }
        }
        if (dirty_set) self.dirty = true;
        if (resp.items.len > 0) {
            var hdr: [8]u8 = undefined;
            const h = std.fmt.bufPrint(&hdr, "\x1b]21;", .{}) catch return;
            self.respond(h);
            self.respond(resp.items);
            self.respond("\x1b\\");
        }
    }

    /// Resolve a color name to its current RGBA, for OSC 21 queries.
    fn namedColorValue(self: *const Screen, name: []const u8) ?[4]f32 {
        if (std.mem.eql(u8, name, "fg") or std.mem.eql(u8, name, "foreground")) return self.default_fg;
        if (std.mem.eql(u8, name, "bg") or std.mem.eql(u8, name, "background")) return self.default_bg;
        if (std.mem.eql(u8, name, "cursor") or std.mem.eql(u8, name, "cursor_color"))
            return if (self.cursor_color[3] > 0) self.cursor_color else self.default_fg;
        if (std.mem.eql(u8, name, "selection_foreground") or std.mem.eql(u8, name, "selection_text"))
            return if (self.selection_fg[3] > 0) self.selection_fg else self.default_bg;
        if (std.mem.eql(u8, name, "selection_background") or std.mem.eql(u8, name, "selection"))
            return if (self.selection_bg[3] > 0) self.selection_bg else default_selection_bg;
        if (std.fmt.parseInt(u8, name, 10)) |idx| {
            const p = self.palette[idx];
            return .{
                @as(f32, @floatFromInt(p[0])) / 255.0,
                @as(f32, @floatFromInt(p[1])) / 255.0,
                @as(f32, @floatFromInt(p[2])) / 255.0,
                1.0,
            };
        } else |_| {}
        return null;
    }

    pub fn onApc(self: *Screen, body: []const u8) void {
        // Kitty graphics protocol: APC G=...
        if (body.len < 1 or body[0] != 'G') return;
        const kitty = @import("../parser/kitty_image.zig");
        const cmd = kitty.parse(body) catch return;

        // q=action — capability probe. Reply OK so apps know we
        // accept kitty graphics; no actual transfer happens.
        // Honour Kitty's `q=` (quiet) flag: q=0 reply normally,
        // q=1 suppress success reply (still reply on error — but
        // a=q can't fail), q=2 suppress all replies.
        if (cmd.action == .query) {
            if (cmd.quiet >= 1) return;
            var resp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&resp, "\x1b_Gi={d};OK\x1b\\", .{cmd.image_id}) catch return;
            self.respond(s);
            return;
        }

        // Delete action. Per kitty spec, the case of `d=` matters:
        // lowercase deletes only placements (visible images on screen)
        // and KEEPS the source image data so subsequent `a=p` calls
        // can re-place the same image_id without re-transmitting.
        // Uppercase ALSO drops source data. Apps like emberglyph
        // (and kitty's own `kitten icat --hold`) clear placements
        // every frame via `d=a` and rely on the source data sticking
        // around — so dropping it here was the cause of the
        // "images don't render in real apps" report.
        if (cmd.action == .delete) {
            const del_ev = ImageDeleteEvent{
                .image_id = cmd.image_id,
                .placement_id = cmd.placement_id,
                .what = cmd.delete_what,
                .image_number = cmd.image_number,
                // The protocol's cell coordinates are 1-based, and
                // `c/C` means "wherever the cursor is" instead.
                .x = switch (cmd.delete_what) {
                    'c', 'C' => self.col,
                    else => if (cmd.src_x > 0) cmd.src_x - 1 else 0,
                },
                .y = switch (cmd.delete_what) {
                    'c', 'C' => self.row,
                    else => if (cmd.src_y > 0) cmd.src_y - 1 else 0,
                },
                .z = cmd.z,
                // r/R reuses x and y as an inclusive id range.
                .id_lo = cmd.src_x,
                .id_hi = if (cmd.src_y == 0) std.math.maxInt(u32) else cmd.src_y,
            };
            // Placements first, source data second: the `n/N`
            // selector resolves an image's NUMBER through
            // `kitty_images`, so dropping the source first would make
            // every retained placement look like number 0 and survive.
            self.pruneRetainedImages(del_ev);
            if (self.sink.on_image_delete_full) |f| f(self.sink.ctx, del_ev);
            // Uppercase also frees the source data. Which images that
            // covers depends on the selector: only the ones whose
            // placements this request could possibly name.
            if (cmd.delete_what >= 'A' and cmd.delete_what <= 'Z') {
                switch (cmd.delete_what) {
                    'A' => self.kitty_images.dropAll(),
                    'I', 'P', 'Q' => if (cmd.image_id != 0) self.kitty_images.drop(cmd.image_id),
                    'N' => if (cmd.image_number != 0) self.kitty_images.dropByNumber(cmd.image_number),
                    'R' => self.kitty_images.dropRange(del_ev.id_lo, del_ev.id_hi),
                    // C/X/Y/Z select by position, which the image
                    // store does not track — the placements go, the
                    // source data stays. Freeing everything instead
                    // would be worse than keeping too much.
                    else => {},
                }
            }
            self.dirty = true;
            return;
        }

        // Unicode-placeholder (virtual) placement: register the grid
        // size and DON'T draw at the cursor — U+10EEEE cells will tile
        // the image later. The transmit half still has to run so the
        // pixels get stored.
        if (cmd.unicode_placement == 1) {
            _ = self.kitty_images.ingest(cmd);
            if (cmd.image_id != 0) {
                self.virtual_placements.put(cmd.image_id, .{
                    .rows = cmd.cells_high, // r=
                    .cols = cmd.cells_wide, // c=
                    .placement_id = cmd.placement_id,
                }) catch {};
            }
            self.dirty = true;
            return;
        }

        // Ingest into the Manager — handles chunking, base64, PNG/RGB/
        // RGBA decode, transmit-only vs transmit-and-place, place-by-id.
        const outcome = self.kitty_images.ingest(cmd);
        if (outcome.action != .place) return;

        const stored = self.kitty_images.get(outcome.image_id) orelse return;
        self.emitImage(.{
            .width = stored.width,
            .height = stored.height,
            .rgba = stored.rgba,
            .row = self.row,
            .col = self.col,
            .image_id = outcome.image_id,
            .placement_id = outcome.placement_id,
            .z_index = outcome.z,
            .cells_wide = outcome.cells_wide,
            .cells_high = outcome.cells_high,
            .src_x = outcome.src_x,
            .src_y = outcome.src_y,
            .src_w = outcome.src_w,
            .src_h = outcome.src_h,
            .cell_x_offset = cmd.cell_x_offset,
            .cell_y_offset = cmd.cell_y_offset,
        });
        self.dirty = true;
    }

    fn onDcs(self: *Screen, d: Event.DcsFull) void {
        // DECRQSS: `DCS $ q <selector> ST` — request status string.
        if (d.proto.final == 'q' and d.proto.n_intermediates == 1 and d.proto.intermediates[0] == '$') {
            self.handleDecrqss(d.body);
            return;
        }
        // XTGETTCAP: `DCS + q <hex-cap>[;<hex-cap>...] ST` — terminfo
        // query. Used by neovim / tmux / kakoune to probe capabilities.
        if (d.proto.final == 'q' and d.proto.n_intermediates == 1 and d.proto.intermediates[0] == '+') {
            self.handleXtgettcap(d.body);
            return;
        }
        // Sixel: `DCS Pn ; Pn ; Pn q <body> ST`.
        if (d.proto.final == 'q' and d.proto.n_intermediates == 0) {
            const sixel = @import("../parser/sixel.zig");
            const decoded = sixel.decode(self.allocator, d.body) catch return;
            defer self.allocator.free(decoded.rgba);
            self.emitImage(.{
                .width = decoded.width,
                .height = decoded.height,
                .rgba = decoded.rgba,
                .row = self.row,
                .col = self.col,
            });
        }
    }

    /// XTGETTCAP — answer terminfo capability queries. The body is a
    /// `;`-separated list of hex-encoded capability names. We reply
    /// per-cap: `DCS 1 + r <hex_cap>=<hex_value> ST` for known caps,
    /// `DCS 0 + r <hex_cap> ST` for unknown.
    fn handleXtgettcap(self: *Screen, body: []const u8) void {
        var it = std.mem.splitScalar(u8, body, ';');
        while (it.next()) |hex_cap| {
            self.handleXtgettcapOne(hex_cap);
        }
    }

    fn handleXtgettcapOne(self: *Screen, hex_cap: []const u8) void {
        // Decode hex cap name (max 32 bytes — terminfo names are short).
        var name_buf: [32]u8 = undefined;
        const name_len = hexDecode(hex_cap, &name_buf) orelse {
            self.respondXtgettcapMiss(hex_cap);
            return;
        };
        const name = name_buf[0..name_len];

        // Match against known caps. Names are case-sensitive per
        // terminfo convention. We support termcap (2-char) AND
        // terminfo (longer) forms for the common ones.
        const value: ?[]const u8 = blk: {
            // Terminal name.
            if (std.mem.eql(u8, name, "TN") or std.mem.eql(u8, name, "name")) break :blk "sketerm-256color";
            // Number of colors.
            if (std.mem.eql(u8, name, "Co") or std.mem.eql(u8, name, "colors")) break :blk "256";
            // RGB / truecolor support.
            if (std.mem.eql(u8, name, "RGB")) break :blk "8/8/8";
            if (std.mem.eql(u8, name, "Tc")) break :blk ""; // boolean: present
            // Back-color erase.
            if (std.mem.eql(u8, name, "bce")) break :blk "";
            // UTF-8 capable (ncurses query).
            if (std.mem.eql(u8, name, "U8")) break :blk "1";
            // Cursor visibility caps.
            if (std.mem.eql(u8, name, "civis") or std.mem.eql(u8, name, "vi")) break :blk "\\E[?25l";
            if (std.mem.eql(u8, name, "cnorm") or std.mem.eql(u8, name, "ve")) break :blk "\\E[?25h";
            // Scroll region (csr).
            if (std.mem.eql(u8, name, "csr") or std.mem.eql(u8, name, "cs")) break :blk "\\E[%i%p1%d;%p2%dr";
            // Hyperlinks (ext_hyperlinks per VTE). We do support them.
            if (std.mem.eql(u8, name, "Su")) break :blk "";
            break :blk null;
        };

        if (value) |v| {
            self.respondXtgettcapHit(hex_cap, v);
        } else {
            self.respondXtgettcapMiss(hex_cap);
        }
    }

    fn respondXtgettcapHit(self: *Screen, hex_cap: []const u8, value: []const u8) void {
        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(self.allocator);
        resp.appendSlice(self.allocator, "\x1bP1+r") catch return;
        resp.appendSlice(self.allocator, hex_cap) catch return;
        resp.append(self.allocator, '=') catch return;
        // Hex-encode value.
        for (value) |b| {
            const hex = "0123456789ABCDEF";
            resp.append(self.allocator, hex[b >> 4]) catch return;
            resp.append(self.allocator, hex[b & 0x0F]) catch return;
        }
        resp.appendSlice(self.allocator, "\x1b\\") catch return;
        self.respond(resp.items);
    }

    fn respondXtgettcapMiss(self: *Screen, hex_cap: []const u8) void {
        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(self.allocator);
        resp.appendSlice(self.allocator, "\x1bP0+r") catch return;
        resp.appendSlice(self.allocator, hex_cap) catch return;
        resp.appendSlice(self.allocator, "\x1b\\") catch return;
        self.respond(resp.items);
    }

    /// Decode a hex string into the destination buffer. Returns the
    /// number of bytes written, or null on bad input. Tolerates upper
    /// + lower case hex; rejects an odd-length input.
    fn hexDecode(src: []const u8, dst: []u8) ?usize {
        if (src.len % 2 != 0) return null;
        const out_len = src.len / 2;
        if (out_len > dst.len) return null;
        var i: usize = 0;
        while (i < out_len) : (i += 1) {
            const hi = hexNibble(src[i * 2]) orelse return null;
            const lo = hexNibble(src[i * 2 + 1]) orelse return null;
            dst[i] = (hi << 4) | lo;
        }
        return out_len;
    }

    fn hexNibble(b: u8) ?u8 {
        return switch (b) {
            '0'...'9' => b - '0',
            'a'...'f' => b - 'a' + 10,
            'A'...'F' => b - 'A' + 10,
            else => null,
        };
    }

    /// DECRQSS reply format: `DCS Ps $ r <answer> ST` where Ps=1 if
    /// recognized, 0 if not.
    fn handleDecrqss(self: *Screen, sel: []const u8) void {
        var resp_buf: [64]u8 = undefined;
        if (sel.len == 1 and sel[0] == 'm') {
            // SGR query — report current style. v1: just SGR 0 reset.
            const s = std.fmt.bufPrint(&resp_buf, "\x1bP1$r0m\x1b\\", .{}) catch return;
            self.respond(s);
            return;
        }
        if (sel.len == 1 and sel[0] == 'r') {
            const s = std.fmt.bufPrint(&resp_buf, "\x1bP1$r{d};{d}r\x1b\\", .{
                self.scroll_top + 1, self.scroll_bot + 1,
            }) catch return;
            self.respond(s);
            return;
        }
        if (sel.len == 2 and sel[0] == ' ' and sel[1] == 'q') {
            // DECSCUSR query.
            const code: u8 = switch (self.cursor_shape) {
                .block_blink => 1,
                .block_steady => 2,
                .underline_blink => 3,
                .underline_steady => 4,
                .bar_blink => 5,
                .bar_steady => 6,
            };
            const s = std.fmt.bufPrint(&resp_buf, "\x1bP1$r{d} q\x1b\\", .{code}) catch return;
            self.respond(s);
            return;
        }
        // Unrecognized.
        self.respond("\x1bP0$r\x1b\\");
    }

    fn onChildEof(self: *Screen, status: i32) void {
        // Always print the status banner. Pane.onTick reads
        // `child_exited` next frame and acts per Window.exit_action
        // (close / restart / hold). Doing it on the next frame
        // avoids tearing down `self` from inside its own apply().
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "[process exited with status {d}]", .{status}) catch return;
        self.execute('\r');
        self.execute('\n');
        for (msg) |b| self.printByte(b);
        self.execute('\r');
        self.execute('\n');
        self.cursor_visible = false;
        self.child_exited = true;
        self.child_exit_status = status;
    }

    fn onOsc(self: *Screen, bytes: []const u8) void {
        // Format: "<num>;<rest>" — or just "<num>": OSC 104/110/111/
        // 112 are sent without any payload in their reset-all form.
        const semi = std.mem.indexOfScalar(u8, bytes, ';');
        const num_str = if (semi) |s| bytes[0..s] else bytes;
        const rest = if (semi) |s| bytes[s + 1 ..] else "";
        const num = std.fmt.parseInt(u32, num_str, 10) catch return;

        switch (num) {
            0, 2 => {
                if (self.last_title) |old| self.allocator.free(old);
                self.last_title = self.allocator.dupe(u8, rest) catch null;
                if (self.sink.on_title) |f| f(self.sink.ctx, rest);
            },
            // OSC 1 — set icon name only. We have no separate icon-name
            // surface (GTK uses the window title), so accept and ignore
            // rather than clobbering the title set by OSC 0/2.
            1 => {},
            7 => {
                if (self.sink.on_cwd) |f| f(self.sink.ctx, rest);
            },
            22 => {
                // OSC 22 ; <name> — change mouse pointer shape. Empty
                // payload restores default. Unknown shape name is the
                // sink's responsibility.
                if (self.sink.on_pointer_shape) |f| f(self.sink.ctx, rest);
            },
            4 => self.handleOsc4(rest),
            8 => self.handleOsc8(rest),
            99 => self.handleOsc99(rest),
            9 => {
                // OSC 9 is two colliding extensions: ConEmu progress
                // (`9 ; 4 ; st ; pr`) and the iTerm2/urxvt desktop
                // notification (`9 ; <message>`). A strict parse of
                // the `4;` form routes to progress; anything else —
                // including a malformed `4;...` — stays a notification.
                if (parseProgress(rest)) |p| {
                    if (self.sink.on_progress) |f| f(self.sink.ctx, p.state, p.percent);
                    return;
                }
                // ConEmu/Cmder `OSC 9 ; 9 ; <path>` reports the cwd
                // (Windows convention). Some emitters quote the path.
                if (std.mem.startsWith(u8, rest, "9;")) {
                    const path = std.mem.trim(u8, rest[2..], "\"");
                    if (self.sink.on_cwd) |f| f(self.sink.ctx, path);
                    return;
                }
                if (self.sink.on_notification) |f| f(self.sink.ctx, .{ .title = "sketerm", .body = rest });
            },
            10, 11, 12 => {
                // OSC 10/11/12 fg/bg/cursor color query/set.
                if (rest.len == 1 and rest[0] == '?') {
                    self.respondColor(num);
                } else if (Screen.parseColor(rest)) |rgba| {
                    switch (num) {
                        10 => self.default_fg = rgba,
                        11 => self.default_bg = rgba,
                        12 => self.cursor_color = rgba,
                        else => {},
                    }
                    self.dirty = true;
                }
            },
            // OSC 17 / 19 — selection (highlight) bg / fg color. Query
            // form (`?`) replies with the active value; set parses a
            // color spec. Resets are OSC 117 / 119.
            17, 19 => {
                if (rest.len == 1 and rest[0] == '?') {
                    self.respondSelectionColor(num);
                } else if (Screen.parseColor(rest)) |rgba| {
                    if (num == 17) self.selection_bg = rgba else self.selection_fg = rgba;
                    self.dirty = true;
                }
            },
            117 => {
                self.selection_bg = .{ 0, 0, 0, 0 };
                self.dirty = true;
            },
            119 => {
                self.selection_fg = .{ 0, 0, 0, 0 };
                self.dirty = true;
            },
            // OSC 21 — kitty's unified color query/set protocol.
            21 => self.handleOsc21(rest),
            // OSC 633 — VS Code shell integration (superset of 133).
            633 => self.handleOsc633(rest),
            // OSC 133 — FinalTerm shell-integration prompt marks.
            // A=prompt-start (navigable), B=prompt-end (input starts;
            // nothing to record), C=command-output-start, D=command
            // finished (optional `;exit-code`). C/D bound the
            // command-output zone used by "Copy Command Output".
            133 => {
                if (rest.len == 0) return;
                switch (rest[0]) {
                    'A' => self.recordPromptMark(),
                    'C' => self.cmdOutputStart(),
                    // `D` or `D;<exit-code>`.
                    'D' => self.cmdOutputEnd(if (rest.len > 2 and rest[1] == ';') rest[2..] else ""),
                    else => {},
                }
            },
            // OSC 104 — palette reset. With no args, reset all
            // entries; with `; n [; n …]` reset only those indices.
            104 => {
                if (rest.len == 0) {
                    self.palette = palette_default_256;
                } else {
                    var it = std.mem.splitScalar(u8, rest, ';');
                    while (it.next()) |idx_str| {
                        if (std.fmt.parseInt(u8, idx_str, 10)) |idx| {
                            self.palette[idx] = palette_default_256[idx];
                        } else |_| {}
                    }
                }
                self.dirty = true;
            },
            // OSC 110 / 111 — fg / bg color reset to the configured
            // defaults (not the compiled-in fallbacks).
            110 => {
                self.default_fg = self.configured_fg;
                self.dirty = true;
            },
            111 => {
                self.default_bg = self.configured_bg;
                self.dirty = true;
            },
            // OSC 112 — cursor color reset (sentinel: alpha=0 → use fg).
            112 => {
                self.cursor_color = .{ 0, 0, 0, 0 };
                self.dirty = true;
            },
            1337 => self.handleOsc1337(rest),
            // OSC 50 — xterm font set / query. We don't dynamically
            // resize fonts via OSC, so set is silently accepted; query
            // (`OSC 50 ; ?`) replies with the configured font name so
            // probes don't conclude unsupported.
            50 => {
                if (rest.len == 0) return;
                if (rest[0] == '?') {
                    var resp_buf: [128]u8 = undefined;
                    const fname = if (self.font_name.len > 0) self.font_name else "Monospace";
                    const out = std.fmt.bufPrint(&resp_buf, "\x1b]50;{s}\x1b\\", .{fname}) catch return;
                    self.respond(out);
                }
                // No-op for set — accepted but ignored.
            },
            777 => {
                // GNOME notify: `OSC 777 ; notify ; <title> ; <body>`.
                const semi2 = std.mem.indexOfScalar(u8, rest, ';') orelse return;
                if (!std.mem.eql(u8, rest[0..semi2], "notify")) return;
                const after = rest[semi2 + 1 ..];
                const semi3 = std.mem.indexOfScalar(u8, after, ';') orelse {
                    if (self.sink.on_notification) |f| f(self.sink.ctx, .{ .title = after });
                    return;
                };
                const title = after[0..semi3];
                const body = after[semi3 + 1 ..];
                if (self.sink.on_notification) |f| f(self.sink.ctx, .{ .title = title, .body = body });
            },
            52 => {
                // OSC 52 — `Pc;Pd` where Pc is selection (c=clipboard,
                // p=primary, etc) and Pd is base64-encoded text or '?'.
                const semi2 = std.mem.indexOfScalar(u8, rest, ';') orelse return;
                const data = rest[semi2 + 1 ..];
                if (data.len == 0) return;
                if (data[0] == '?') {
                    // Read query. Gated behind `clipboard_read = allow`
                    // — clipboard contents are sensitive and any app on
                    // the PTY (including remote ones) can ask. When
                    // denied, reply with an empty payload immediately
                    // so the querying app isn't stuck in its timeout.
                    // GUI-owned: daemon screens defer to the attached
                    // mirror (only the GUI has a clipboard).
                    if (self.defer_gui_queries) return;
                    const sel: u8 = if (rest.len > 0 and rest[0] == 'p') 'p' else 'c';
                    if (!self.allow_clipboard_read or self.sink.on_clipboard_get == null) {
                        var resp_buf: [16]u8 = undefined;
                        const out = std.fmt.bufPrint(&resp_buf, "\x1b]52;{c};\x1b\\", .{sel}) catch return;
                        self.respondForce(out);
                        return;
                    }
                    self.sink.on_clipboard_get.?(self.sink.ctx, sel);
                    return;
                }
                if (data.len > 1_500_000) return; // 1 MB cap (after base64 expansion)
                const decoder = std.base64.standard.Decoder;
                const out_len = decoder.calcSizeForSlice(data) catch return;
                const out = self.allocator.alloc(u8, out_len) catch return;
                defer self.allocator.free(out);
                decoder.decode(out, data) catch return;
                if (self.sink.on_clipboard_set) |f| f(self.sink.ctx, out);
            },
            else => {},
        }
    }

    fn printByte(self: *Screen, b: u8) void {
        if (self.decoder.feed(b)) |cp| self.printCp(cp);
    }

    /// Fast-write a contiguous ASCII byte slice as cells. Caller is
    /// responsible for verifying preconditions (decoder idle, no
    /// insert mode / wrap / cluster, charset = ascii). The slice
    /// itself doesn't need range-checking bytes — caller has done
    /// that. Handles autowrap mid-slice.
    fn fastAsciiSlice(self: *Screen, bytes: []const u8) void {
        // ASCII can't be a placeholder diacritic, so any pending
        // placeholder is finalized before this run overwrites cells.
        if (self.ph_pending != null) self.flushPlaceholder();
        const total: u16 = @intCast(bytes.len);
        const link_id = self.current_link_id;
        const flags: u8 = if (link_id != 0) 0b0000_0100 else 0;
        const style = self.cur_style;
        var i: u16 = 0;
        while (i < total) {
            const remaining: u16 = if (self.col >= self.cols) 0 else self.cols - self.col;
            if (remaining == 0) {
                if (!self.autowrap) break;
                self.lineFeed();
                self.col = 0;
                self.line(self.row).continues_above = true;
                continue;
            }
            const can_write: u16 = @min(total - i, remaining);
            var ln = self.line(self.row);
            // The written range overwrites pairs fully inside it; only
            // pairs straddling the boundaries need an explicit split.
            self.splitWidePair(ln, self.col);
            self.splitWidePair(ln, self.col + can_write - 1);
            var k: u16 = 0;
            while (k < can_write) : (k += 1) {
                ln.cells[self.col + k] = .{
                    .rune = bytes[i + k],
                    .style_ref = style,
                    .flags = flags,
                    .reserved = link_id,
                };
            }
            ln.dirty = true;
            self.last_print_cp = bytes[i + can_write - 1];
            self.last_print_key = cellKey(self.row, self.col + can_write - 1);
            self.col += can_write;
            i += can_write;
        }
        if (self.col >= self.cols) {
            if (self.autowrap) {
                self.col = self.cols - 1;
                self.pending_wrap = true;
            } else {
                self.col = self.cols - 1;
            }
        }
    }

    /// Whether the active state allows the ASCII fast-write path.
    /// Used by Tier 2.5 to decide whether an ASCII subrange in a
    /// mixed run can take the cell-array fast path.
    fn fastAsciiEligible(self: *const Screen) bool {
        if (self.insert_mode) return false;
        if (self.pending_wrap) return false;
        if (self.clusters.count() != 0) return false;
        const active = if (self.active_charset == .g0) self.charset_g0 else self.charset_g1;
        if (active != .ascii) return false;
        return true;
    }

    pub fn printCp(self: *Screen, cp_in: u32) void {
        // SS2 / SS3 — single-shift consumed by this print; G2/G3
        // unmodelled, so the codepoint passes through as if printed
        // through ASCII.
        const single_shifted = self.pending_single_shift != .none;
        if (single_shifted) self.pending_single_shift = .none;
        // Translate ASCII through the active charset designation —
        // unless the single-shift bypassed it.
        const active = if (single_shifted) Charset.ascii else if (self.active_charset == .g0) self.charset_g0 else self.charset_g1;
        const cp: u32 = if (active == .dec_graphics and cp_in <= 0x7E and cp_in >= 0x5F)
            decGraphicsCp(@intCast(cp_in))
        else
            cp_in;

        // Combining / extending codepoint: don't advance the cursor,
        // don't write a new cell. The user perceives them as glued
        // to the previous glyph (ZWJ sequences, variation selectors,
        // skin-tone modifiers, combining marks). We attach the cp
        // to the previously-printed cell's cluster so selection
        // extraction can emit the full cluster. Renderer continues
        // to draw only the base.
        // Kitty Unicode-placeholder diacritics decode the image-cell
        // row/column/id-high for a pending placeholder. Routed here
        // explicitly (not via isExtendingCp) so every entry in the
        // 297-char table attaches, even ones outside the common
        // combining blocks. Still stored as a cluster so copy/paste
        // round-trips the bytes.
        if (self.ph_pending) |*pp| {
            if (kitty_ph.rowColIndex(cp)) |idx| {
                if (pp.n_diac < 3) {
                    pp.diac[pp.n_diac] = idx;
                    pp.n_diac += 1;
                }
                const row: u16 = @intCast(self.last_print_key >> 16);
                const col: u16 = @intCast(self.last_print_key & 0xFFFF);
                self.appendCluster(row, col, cp);
                return;
            }
        }

        if (self.last_print_cp != 0 and isExtendingCp(cp)) {
            const row: u16 = @intCast(self.last_print_key >> 16);
            const col: u16 = @intCast(self.last_print_key & 0xFFFF);
            self.appendCluster(row, col, cp);
            return;
        }

        // A new base char finalizes any placeholder cell still waiting
        // for diacritics.
        if (self.ph_pending != null) self.flushPlaceholder();

        const width: u8 = if (isWideCp(cp)) 2 else 1;

        // Wide char near right edge wraps before placing.
        if (self.pending_wrap or (width == 2 and self.col + 1 >= self.cols)) {
            self.lineFeed();
            self.col = 0;
            self.pending_wrap = false;
            // Mark the new line as a soft-wrap continuation; future
            // reflow can join wrapped paragraphs.
            self.line(self.row).continues_above = true;
        }
        if (self.col >= self.cols) return;

        var ln = self.line(self.row);

        // IRM (insert mode) — shift cells right by `width` before placing.
        if (self.insert_mode and self.col < self.cols) {
            // Shifted cells change column; clusters are keyed by (row, col)
            // and would point at the wrong cells afterwards (matches the
            // ICH/DCH clear-range approach).
            if (self.clusters.count() > 0) self.clearClustersRange(self.row, self.col, self.cols);
            var k: u16 = self.cols;
            while (k > self.col + width) : (k -= 1) {
                ln.cells[k - 1] = ln.cells[k - 1 - width];
            }
        }

        // Drop any cluster previously attached to this cell — the new
        // base codepoint replaces it. Cluster store is nearly always
        // empty in steady-state ASCII workloads, so the early-out
        // saves two hashmap lookups per printable byte.
        if (self.clusters.count() > 0) {
            self.clearClusterAt(self.row, self.col);
            if (width == 2 and self.col + 1 < self.cols) self.clearClusterAt(self.row, self.col + 1);
        }

        // Writing into either half of an existing wide pair must blank
        // the other half, or the renderer keeps the orphan around.
        self.splitWidePair(ln, self.col);
        if (width == 2) self.splitWidePair(ln, self.col + 1);

        var flags: u8 = if (self.current_link_id != 0) 0b0000_0100 else 0;
        if (width == 2) flags |= 0b0000_0001; // is_wide_left
        ln.cells[self.col] = .{
            .rune = cp,
            .style_ref = self.cur_style,
            .flags = flags,
            .reserved = self.current_link_id,
        };
        if (width == 2 and self.col + 1 < self.cols) {
            // Continuation cell: empty rune, is_wide_cont flag.
            ln.cells[self.col + 1] = .{
                .rune = 0,
                .style_ref = self.cur_style,
                .flags = 0b0000_0010,
                .reserved = self.current_link_id,
            };
        }
        ln.dirty = true;

        // Remember where we placed the base for cluster attachment.
        self.last_print_key = cellKey(self.row, self.col);

        // A placeholder base opens a pending tile; its image id comes
        // from the current foreground, diacritics (if any) follow.
        if (cp == kitty_ph.PLACEHOLDER) {
            self.ph_pending = .{
                .screen_row = self.row,
                .screen_col = self.col,
                .image_id = self.fgImageId(),
            };
        }

        self.col += width;
        if (self.col >= self.cols) {
            if (self.autowrap) {
                self.col = self.cols - 1;
                self.pending_wrap = true;
            } else {
                self.col = self.cols - 1;
            }
        }
        self.last_print_cp = cp;
    }

    /// The current foreground rendered as a kitty image id: palette
    /// index, or packed 24-bit truecolor. `.default` → 0 (no image).
    fn fgImageId(self: *Screen) u32 {
        return switch (self.pool.get(self.cur_style).fg) {
            .default => 0,
            .palette => |p| p,
            .rgb => |c| (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b,
        };
    }

    /// Finalize the pending placeholder cell into an image tile. Decodes
    /// the image-cell row/column from its diacritics, applying the
    /// auto-increment rule (a diacritic-less cell continues the previous
    /// tile to its right), then emits a one-cell crop of the image.
    fn flushPlaceholder(self: *Screen) void {
        const pp = self.ph_pending orelse return;
        self.ph_pending = null;

        var image_id = pp.image_id;
        // 3rd diacritic carries the most-significant byte of the id.
        if (pp.n_diac >= 3) image_id |= pp.diac[2] << 24;
        if (image_id == 0) {
            self.ph_last = null;
            return;
        }

        var img_row: u32 = if (pp.n_diac >= 1) pp.diac[0] else 0;
        var img_col: u32 = if (pp.n_diac >= 2) pp.diac[1] else 0;
        // Missing row and/or column: continue the previous tile when
        // this cell sits immediately to its right, same row & image.
        if (pp.n_diac < 2) {
            if (self.ph_last) |last| {
                if (last.image_id == image_id and
                    last.screen_row == pp.screen_row and
                    last.screen_col +% 1 == pp.screen_col)
                {
                    if (pp.n_diac == 0) img_row = last.img_row;
                    img_col = last.img_col + 1;
                }
            }
        }

        self.emitPlaceholderTile(pp.screen_row, pp.screen_col, image_id, img_row, img_col);
        self.ph_last = .{
            .screen_row = pp.screen_row,
            .screen_col = pp.screen_col,
            .image_id = image_id,
            .img_row = img_row,
            .img_col = img_col,
        };
    }

    /// Emit a single placeholder tile: the (img_row, img_col) cell of
    /// the image's r×c grid, cropped to its own small pixel buffer and
    /// placed at one terminal cell. The synthetic per-cell placement id
    /// lets distinct tiles coexist while a re-print at the same cell
    /// replaces cleanly.
    fn emitPlaceholderTile(self: *Screen, srow: u16, scol: u16, image_id: u32, img_row: u32, img_col: u32) void {
        const stored = self.kitty_images.get(image_id) orelse return;
        if (stored.width == 0 or stored.height == 0) return;

        var cols: u32 = 0;
        var rows: u32 = 0;
        if (self.virtual_placements.get(image_id)) |vp| {
            cols = vp.cols;
            rows = vp.rows;
        }
        // Grid size unspecified: derive from native pixel size / cell.
        if (cols == 0) {
            const cw: u32 = if (self.cell_pixel_w > 0) self.cell_pixel_w else 8;
            cols = @max(1, (stored.width + cw - 1) / cw);
        }
        if (rows == 0) {
            const ch: u32 = if (self.cell_pixel_h > 0) self.cell_pixel_h else 16;
            rows = @max(1, (stored.height + ch - 1) / ch);
        }
        if (img_row >= rows or img_col >= cols) return;

        const tile_w = stored.width / cols;
        const tile_h = stored.height / rows;
        if (tile_w == 0 or tile_h == 0) return;

        const sx = img_col * tile_w;
        const sy = img_row * tile_h;
        const row_bytes = tile_w * 4;

        const tile = self.allocator.alloc(u8, tile_w * tile_h * 4) catch return;
        defer self.allocator.free(tile);
        var ty: u32 = 0;
        while (ty < tile_h) : (ty += 1) {
            const src_off = ((sy + ty) * stored.width + sx) * 4;
            const dst_off = ty * row_bytes;
            @memcpy(tile[dst_off .. dst_off + row_bytes], stored.rgba[src_off .. src_off + row_bytes]);
        }

        // High bit tags it as placeholder-synthetic so it never clashes
        // with an app-chosen placement id; position keeps tiles distinct.
        const synth_pid: u32 = 0x4000_0000 | (@as(u32, srow) << 12) | scol;
        self.emitImage(.{
            .width = tile_w,
            .height = tile_h,
            .rgba = tile,
            .row = srow,
            .col = scol,
            .image_id = image_id,
            .placement_id = synth_pid,
            .cells_wide = 1,
            .cells_high = 1,
        });
    }

    /// Returns true if the codepoint is a "combining" or "extending"
    /// character that should attach to the preceding cell instead of
    /// occupying its own. Covers the most common modern grapheme-
    /// cluster pieces:
    ///   - ZWJ / ZWNJ (zero-width [non-]joiner)
    ///   - Variation selectors (VS1..VS16, supplement)
    ///   - Combining diacritical marks (basic + supplement + extended)
    ///   - Skin-tone modifiers (Fitzpatrick types 1-6)
    /// We do NOT mark regional indicators here — they're full-width
    /// codepoints, not "extending"; the cluster behavior of "two RIs
    /// = one flag" needs a different treatment we don't yet model.
    /// True iff every byte in the slice is plain ASCII (≤ 0x7E and
    /// excluding control bytes 0x00..0x1F). Used to skip the UTF-8
    /// decoder on pure-ASCII print runs.
    /// Decode a 2/3/4-byte UTF-8 sequence given the leading-byte's
    /// classified length. Returns null if any continuation byte is
    /// malformed (top bits != 0b10). Caller has already verified
    /// `bytes.len == cp_len`.
    fn decodeUtf8Lookahead(bytes: []const u8, cp_len: usize) ?u32 {
        switch (cp_len) {
            2 => {
                if ((bytes[1] & 0xC0) != 0x80) return null;
                return (@as(u32, bytes[0] & 0x1F) << 6) | (bytes[1] & 0x3F);
            },
            3 => {
                if ((bytes[1] & 0xC0) != 0x80) return null;
                if ((bytes[2] & 0xC0) != 0x80) return null;
                return (@as(u32, bytes[0] & 0x0F) << 12) |
                    (@as(u32, bytes[1] & 0x3F) << 6) |
                    (bytes[2] & 0x3F);
            },
            4 => {
                if ((bytes[1] & 0xC0) != 0x80) return null;
                if ((bytes[2] & 0xC0) != 0x80) return null;
                if ((bytes[3] & 0xC0) != 0x80) return null;
                return (@as(u32, bytes[0] & 0x07) << 18) |
                    (@as(u32, bytes[1] & 0x3F) << 12) |
                    (@as(u32, bytes[2] & 0x3F) << 6) |
                    (bytes[3] & 0x3F);
            },
            else => return null,
        }
    }

    fn runIsAscii(bytes: []const u8) bool {
        var i: usize = 0;
        const V = @Vector(16, u8);
        const v_min: V = @splat(0x20);
        const v_max: V = @splat(0x7E);
        while (i + 16 <= bytes.len) : (i += 16) {
            const chunk: V = bytes[i..][0..16].*;
            const ge_min = chunk >= v_min;
            const le_max = chunk <= v_max;
            const ok: @Vector(16, bool) = @select(bool, ge_min, le_max, @as(@Vector(16, bool), @splat(false)));
            if (!@reduce(.And, ok)) return false;
        }
        while (i < bytes.len) : (i += 1) {
            const b = bytes[i];
            if (b < 0x20 or b > 0x7E) return false;
        }
        return true;
    }

    pub fn isExtendingCp(cp: u32) bool {
        return switch (cp) {
            0x200C, 0x200D => true, // ZWNJ, ZWJ
            0x0300...0x036F => true, // Combining diacritical marks
            0x1AB0...0x1AFF => true, // Combining ext
            0x1DC0...0x1DFF => true, // Combining supplement
            0x20D0...0x20FF => true, // Combining for symbols
            0xFE00...0xFE0F => true, // Variation selectors
            0xFE20...0xFE2F => true, // Combining half marks
            0xE0100...0xE01EF => true, // Variation selectors supplement
            0x1F3FB...0x1F3FF => true, // Emoji skin-tone modifiers
            else => false,
        };
    }

    /// Coarse wide-character check: CJK Unified, Hangul, fullwidth
    /// forms, kana, and most pictographs/emoji. Conservative.
    fn isWideCp(cp: u32) bool {
        return switch (cp) {
            0x1100...0x115F, // Hangul Jamo
            0x2E80...0x303E, // CJK Radicals + Kangxi
            0x3041...0x33FF, // Hiragana / Katakana / Bopomofo
            0x3400...0x4DBF, // CJK Ext A
            0x4E00...0x9FFF, // CJK Unified
            0xA000...0xA4CF, // Yi Syllables
            0xAC00...0xD7A3, // Hangul Syllables
            0xF900...0xFAFF, // CJK Compatibility Ideographs
            0xFE30...0xFE4F, // CJK Compatibility Forms
            0xFF00...0xFF60, // Fullwidth Forms (most)
            0xFFE0...0xFFE6, // Fullwidth Signs
            0x231A...0x231B, // Watch / hourglass
            0x23E9...0x23EC, // Media buttons
            0x23F0,
            0x23F3, // Alarm clock, hourglass
            0x25FD...0x25FE, // Medium small white/black squares
            0x2614...0x2615, // Umbrella, hot beverage
            0x2648...0x2653, // Zodiac
            0x267F, // Wheelchair
            0x2693, // Anchor
            0x26A1, // High voltage
            0x26AA...0x26AB, // White / black circle
            0x26BD...0x26BE, // Soccer / baseball
            0x26C4...0x26C5, // Snowman / sun behind cloud
            0x26CE,
            0x26D4,
            0x26EA, // Ophiuchus, no entry, church
            0x26F2...0x26F3, // Fountain, flag in hole
            0x26F5,
            0x26FA,
            0x26FD, // Sailboat, tent, fuel pump
            0x2705,
            0x270A...0x270B,
            0x2728, // Check mark, raised hand, sparkles
            0x274C,
            0x274E, // Cross mark
            0x2753...0x2755,
            0x2757, // Question / exclamation
            0x2795...0x2797, // Plus / minus / division signs
            0x27B0,
            0x27BF, // Curly loop / double curly
            0x2B1B...0x2B1C, // Black / white large square
            0x2B50,
            0x2B55, // Star / circle
            0x1F000...0x1F02F, // Mahjong tiles
            0x1F0A0...0x1F0FF, // Playing cards
            0x1F300...0x1F64F, // Misc Symbols / Emoji
            0x1F680...0x1F9FF, // Transport / Supplemental Symbols
            0x1FA00...0x1FAFF, // Symbols and Pictographs Extended-A
            0x20000...0x2FFFD, // CJK Ext B-F
            0x30000...0x3FFFD, // CJK Ext G+
            => true,
            else => false,
        };
    }

    fn execute(self: *Screen, b: u8) void {
        switch (b) {
            0x05 => self.respond(""), // ENQ — answerback (we send empty)
            0x07 => {
                // BEL: visual flash + optional sink notification.
                self.bell_at_us = @import("../util/profile.zig").microTimestamp();
                if (self.sink.on_bell) |f| f(self.sink.ctx);
            },
            0x08 => self.backspace(),
            0x09 => self.tab(),
            0x0A, 0x0B, 0x0C => {
                self.lineFeed();
                // LNM: LF/VT/FF also implicitly carry a CR.
                if (self.line_feed_mode) self.carriageReturn();
            },
            0x0D => self.carriageReturn(),
            0x0E => self.active_charset = .g1, // SO — locking shift to G1
            0x0F => self.active_charset = .g0, // SI — locking shift to G0
            else => {},
        }
    }

    fn carriageReturn(self: *Screen) void {
        self.col = 0;
        self.pending_wrap = false;
    }

    fn backspace(self: *Screen) void {
        if (self.col > 0) self.col -= 1;
        self.pending_wrap = false;
    }

    fn tab(self: *Screen) void {
        self.col = self.nextTabStop(self.col);
        self.pending_wrap = false;
    }

    /// Reset tab_stops to default every-8 columns. Sized to current cols.
    pub fn resetTabStops(self: *Screen) !void {
        try self.tab_stops.resize(self.allocator, self.cols);
        for (self.tab_stops.items, 0..) |*s, i| s.* = (i % 8 == 0 and i != 0);
    }

    /// Resize tab_stops, preserving existing values and adding default
    /// every-8 stops in the new range.
    fn resizeTabStops(self: *Screen, new_cols: u16) void {
        const old_len = self.tab_stops.items.len;
        self.tab_stops.resize(self.allocator, new_cols) catch return;
        if (new_cols > old_len) {
            for (self.tab_stops.items[old_len..], old_len..) |*s, i|
                s.* = (i % 8 == 0 and i != 0);
        }
    }

    /// First tab stop strictly to the right of `from`, or cols-1.
    pub fn nextTabStop(self: *Screen, from: u16) u16 {
        if (self.cols == 0) return 0;
        var c: u16 = from + 1;
        while (c < self.cols) : (c += 1) {
            if (c < self.tab_stops.items.len and self.tab_stops.items[c]) return c;
        }
        return self.cols - 1;
    }

    /// First tab stop strictly to the left of `from`, or 0.
    pub fn prevTabStop(self: *Screen, from: u16) u16 {
        if (from == 0) return 0;
        var c: u16 = from - 1;
        while (c > 0) : (c -= 1) {
            if (c < self.tab_stops.items.len and self.tab_stops.items[c]) return c;
        }
        return 0;
    }

    pub fn lineFeed(self: *Screen) void {
        if (self.row == self.scroll_bot) {
            self.scrollUp(1);
        } else if (self.row + 1 < self.rows) {
            self.row += 1;
        }
        // Deferred OSC 133 C capture: the first newline after a
        // mid-line C lands on the command output's first row.
        if (self.pending_output_awaits_nl and !self.use_alt and self.row < self.rows) {
            self.pending_output_awaits_nl = false;
            self.pending_output_start_id = self.active[self.row].id;
        }
        self.pending_wrap = false;
        if (self.scroll_on_output) self.view_offset = 0;
    }

    // ── CSI dispatch / cursor / erase / scroll / modes / SGR: split out to screen_ops.zig ──
    const screen_ops = @import("screen_ops.zig");
    const csi = screen_ops.csi;
    const csiPrivate = screen_ops.csiPrivate;
    const csiAux = screen_ops.csiAux;
    const csiKittyKbd = screen_ops.csiKittyKbd;
    const csiPublic = screen_ops.csiPublic;
    const publicModeSet = screen_ops.publicModeSet;
    const decrqm = screen_ops.decrqm;
    const rep = screen_ops.rep;
    const dsr = screen_ops.dsr;
    const respondDa = screen_ops.respondDa;
    const decscusr = screen_ops.decscusr;
    const windowOps = screen_ops.windowOps;
    const titleStackPush = screen_ops.titleStackPush;
    const titleStackPop = screen_ops.titleStackPop;
    const respond = screen_ops.respond;
    const respondForce = screen_ops.respondForce;
    const escFinal = screen_ops.escFinal;
    const decstr = screen_ops.decstr;
    pub const fullReset = screen_ops.fullReset;
    const cursorUp = screen_ops.cursorUp;
    const cursorDown = screen_ops.cursorDown;
    const cursorRight = screen_ops.cursorRight;
    const cursorLeft = screen_ops.cursorLeft;
    const cursorPos = screen_ops.cursorPos;
    const saveCursor = screen_ops.saveCursor;
    const restoreCursor = screen_ops.restoreCursor;
    const reverseLineFeed = screen_ops.reverseLineFeed;
    const eraseDisplay = screen_ops.eraseDisplay;
    const eraseLine = screen_ops.eraseLine;
    const scrollUp = screen_ops.scrollUp;
    const scrollDown = screen_ops.scrollDown;
    const insertChars = screen_ops.insertChars;
    const deleteChars = screen_ops.deleteChars;
    const insertLines = screen_ops.insertLines;
    const deleteLines = screen_ops.deleteLines;
    const setScrollRegion = screen_ops.setScrollRegion;
    const modeSet = screen_ops.modeSet;
    const sendResizeReport = screen_ops.sendResizeReport;
    pub const notifyColorScheme = screen_ops.notifyColorScheme;
    const toggleAltScreen = screen_ops.toggleAltScreen;
    const sgrReadRgb = screen_ops.sgrReadRgb;
    const sgrReadExtColor = screen_ops.sgrReadExtColor;
    const sgr = screen_ops.sgr;
    const compactStylePool = screen_ops.compactStylePool;


    // ── Debug ────────────────────────────────────────────────────

    /// Dump the active screen to a writer for tests / debugging.
    /// Each row terminated by `\n`. Cells with rune 0 render as space.
    pub fn dump(self: *Screen, w: *std.Io.Writer) !void {
        for (self.buf()) |ln| {
            for (ln.cells) |cell| {
                // Skip wide-char continuation cells.
                if (cell.flags & 0b0000_0010 != 0) continue;
                if (cell.rune == 0) {
                    try w.writeByte(' ');
                } else if (cell.rune < 128) {
                    try w.writeByte(@intCast(cell.rune));
                } else {
                    var utf8_buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cell.rune), &utf8_buf) catch 0;
                    try w.writeAll(utf8_buf[0..n]);
                }
            }
            try w.writeByte('\n');
        }
    }
};

/// Render a single display row into UTF-8, recording the originating
/// column for each emitted byte. Used by Screen.search.
fn renderLineForSearch(
    allocator: std.mem.Allocator,
    self: *const Screen,
    row: i32,
    line_buf: *std.ArrayList(u8),
    col_map: *std.ArrayList(u32),
    width_map: *std.ArrayList(u8),
) !void {
    line_buf.clearRetainingCapacity();
    col_map.clearRetainingCapacity();
    width_map.clearRetainingCapacity();

    const cells = self.lineCellsAt(row) orelse return;
    var col: u32 = 0;
    while (col < cells.len) : (col += 1) {
        const cell = cells[col];
        if (cell.flags & 0b0000_0010 != 0) continue; // wide-cont
        const is_wide = (cell.flags & 0b0000_0001) != 0;
        const w: u8 = if (is_wide) 2 else 1;
        const cp: u32 = if (cell.rune == 0) ' ' else cell.rune;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch 0;
        var k: usize = 0;
        while (k < n) : (k += 1) {
            try line_buf.append(allocator, enc[k]);
            try col_map.append(allocator, col);
            try width_map.append(allocator, w);
        }
    }
}

fn findMatches(
    allocator: std.mem.Allocator,
    haystack: []const u8,
    col_map: []const u32,
    width_map: []const u8,
    needle: []const u8,
    row: i32,
    out: *std.ArrayList(Screen.SearchMatch),
    case_insensitive: bool,
) !void {
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        const matched = if (case_insensitive)
            asciiCaseEq(haystack[pos .. pos + needle.len], needle)
        else
            std.mem.eql(u8, haystack[pos .. pos + needle.len], needle);
        if (matched) {
            const start_col = col_map[pos];
            const end_byte = pos + needle.len - 1;
            const end_col_left = col_map[end_byte];
            const end_w: u32 = width_map[end_byte];
            // Visual width: from start_col to (end_col_left +
            // last_cell_width - 1) inclusive. Wide cells contribute
            // 2 columns each.
            const len: u32 = (end_col_left + end_w) - start_col;
            try out.append(allocator, .{
                .row = row,
                .col = start_col,
                .len = len,
            });
            pos += needle.len;
        } else {
            pos += 1;
        }
    }
}

/// Walk `haystack` with regexec, emitting a SearchMatch per non-empty
/// hit. Empty matches (e.g. `a*` against "x") are skipped via a +1
/// advance to break out of pathological zero-width loops. Caller
/// owns + reuses the line_buf; we sentinel-terminate via a temporary
/// allocation so regexec sees a real C string.
fn findRegexMatches(
    allocator: std.mem.Allocator,
    re: *@import("../c.zig").c.regex_t,
    haystack: []const u8,
    col_map: []const u32,
    width_map: []const u8,
    row: i32,
    out: *std.ArrayList(Screen.SearchMatch),
) !void {
    if (haystack.len == 0) return;

    const cre = @import("../c.zig").c;
    const z = try allocator.allocSentinel(u8, haystack.len, 0);
    defer allocator.free(z);
    @memcpy(z, haystack);

    var search_pos: usize = 0;
    while (search_pos < haystack.len) {
        var m: cre.regmatch_t = undefined;
        const rc = cre.regexec(re, z.ptr + search_pos, 1, &m, 0);
        if (rc != 0) break;
        const so: usize = @intCast(m.rm_so);
        const eo: usize = @intCast(m.rm_eo);
        if (eo == so) {
            search_pos += so + 1;
            continue;
        }
        const start = so + search_pos;
        const end = eo + search_pos;
        const start_col = col_map[start];
        const end_byte = end - 1;
        const end_col_left = col_map[end_byte];
        const end_w: u32 = width_map[end_byte];
        const len: u32 = (end_col_left + end_w) - start_col;
        try out.append(allocator, .{
            .row = row,
            .col = start_col,
            .len = len,
        });
        search_pos = end;
    }
}

/// Compare two byte slices with ASCII letter-case folding on the
/// haystack side only. `needle` is assumed already-lowercased.
fn asciiCaseEq(haystack: []const u8, needle_lower: []const u8) bool {
    if (haystack.len != needle_lower.len) return false;
    for (haystack, needle_lower) |h, n| {
        if (std.ascii.toLower(h) != n) return false;
    }
    return true;
}

// ── Tests ────────────────────────────────────────────────────────

test "init / blank cells" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u16, 0), s.row);
    try std.testing.expectEqual(@as(u16, 0), s.col);
}

test "print and lf/cr" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp('H');
    s.printCp('i');
    s.execute('\r');
    s.execute('\n');
    s.printCp('!');
    try std.testing.expectEqual(@as(u32, 'H'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'i'), s.cellAt(0, 1).rune);
    try std.testing.expectEqual(@as(u32, '!'), s.cellAt(1, 0).rune);
}

test "autowrap" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    inline for ("abcdefg") |ch| s.printCp(ch);
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'e'), s.cellAt(0, 4).rune);
    try std.testing.expectEqual(@as(u32, 'f'), s.cellAt(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 'g'), s.cellAt(1, 1).rune);
}

test "cursor up" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 5);
    defer s.deinit();
    s.row = 3;
    s.cursorUp(2);
    try std.testing.expectEqual(@as(u16, 1), s.row);
    s.cursorUp(10); // clamps
    try std.testing.expectEqual(@as(u16, 0), s.row);
}

test "csi cup" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 5);
    defer s.deinit();
    var csi = Event.Csi{};
    csi.params[0] = 3;
    csi.params[1] = 5;
    csi.n_params = 2;
    csi.final = 'H';
    s.csi(csi);
    try std.testing.expectEqual(@as(u16, 2), s.row);
    try std.testing.expectEqual(@as(u16, 4), s.col);
}

test "csi sgr bold" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    var csi = Event.Csi{};
    csi.params[0] = 1;
    csi.n_params = 1;
    csi.final = 'm';
    s.csi(csi);
    try std.testing.expect(pool.get(s.cur_style).attrs.bold);
}

test "csi sgr truecolor" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    var csi = Event.Csi{};
    csi.params = .{ 38, 2, 255, 128, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    csi.n_params = 5;
    csi.final = 'm';
    s.csi(csi);
    const e = pool.get(s.cur_style);
    try std.testing.expect(Color.equal(e.fg, .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } }));
}

test "csi ed clears all" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.printCp('a');
    s.printCp('b');
    s.execute('\n');
    s.printCp('c');
    var csi = Event.Csi{};
    csi.params[0] = 2;
    csi.n_params = 1;
    csi.final = 'J';
    s.csi(csi);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(1, 0).rune);
}

test "alt screen toggle" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.printCp('M'); // main screen
    var csi = Event.Csi{};
    csi.private = '?';
    csi.params[0] = 1049;
    csi.n_params = 1;
    csi.final = 'h';
    s.csi(csi);
    try std.testing.expect(s.use_alt);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 0).rune); // alt is blank
    csi.final = 'l';
    s.csi(csi);
    try std.testing.expect(!s.use_alt);
    try std.testing.expectEqual(@as(u32, 'M'), s.cellAt(0, 0).rune); // main preserved
}

test "column resize in alt screen normalizes main scrollback width" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.scrollback_capacity = 2;
    // Fill the ring so its buffers will be recycled on the next scroll.
    s.printCp('a');
    s.execute('\r');
    s.execute('\n');
    s.printCp('b');
    s.execute('\r');
    s.execute('\n');
    s.printCp('c');
    s.execute('\r');
    s.execute('\n');
    s.printCp('d');
    s.execute('\r');
    s.execute('\n');
    try std.testing.expectEqual(@as(usize, 2), s.scrollback.items.len);

    s.toggleAltScreen(true);
    try s.resize(9, 3);
    for (s.scrollback.items) |ln| try std.testing.expectEqual(@as(usize, 9), ln.cells.len);
    s.toggleAltScreen(false);
    s.scrollUp(1);
    for (s.active) |ln| try std.testing.expectEqual(@as(usize, 9), ln.cells.len);
}

test "scroll up moves content" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 3, 3);
    defer s.deinit();
    s.printCp('a');
    s.execute('\r');
    s.execute('\n');
    s.printCp('b');
    s.execute('\r');
    s.execute('\n');
    s.printCp('c');
    s.scrollUp(1);
    try std.testing.expectEqual(@as(u32, 'b'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'c'), s.cellAt(1, 0).rune);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(2, 0).rune);
}

test "decstbm scroll region" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 3, 5);
    defer s.deinit();
    var csi = Event.Csi{};
    csi.params = .{ 2, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    csi.n_params = 2;
    csi.final = 'r';
    s.csi(csi);
    try std.testing.expectEqual(@as(u16, 1), s.scroll_top);
    try std.testing.expectEqual(@as(u16, 3), s.scroll_bot);
}

test "esc 7 / 8 save+restore cursor" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.row = 1;
    s.col = 3;
    s.escFinal(.{ .final = '7' });
    s.row = 0;
    s.col = 0;
    s.escFinal(.{ .final = '8' });
    try std.testing.expectEqual(@as(u16, 1), s.row);
    try std.testing.expectEqual(@as(u16, 3), s.col);
}

test "wide CJK takes 2 columns and marks continuation" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 6, 2);
    defer s.deinit();
    // U+4E2D '中' is a wide CJK ideograph.
    s.printCp(0x4E2D);
    try std.testing.expectEqual(@as(u32, 0x4E2D), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 1).rune);
    // Continuation flag bit 1 (is_wide_cont) set.
    try std.testing.expect(s.cellAt(0, 1).flags & 0b10 != 0);
    try std.testing.expectEqual(@as(u16, 2), s.col);
}

test "wide-char wraps at right edge" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 3, 3);
    defer s.deinit();
    s.printCp('a');
    s.printCp('b'); // col=2
    // Now at col=2; '中' would need 2 cols → wraps to next line.
    s.printCp(0x4E2D);
    try std.testing.expectEqual(@as(u32, 0x4E2D), s.cellAt(1, 0).rune);
    try std.testing.expect(s.cellAt(1, 1).flags & 0b10 != 0);
}

test "resize preserves active rows" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 4);
    defer s.deinit();
    s.printCp('a');
    s.printCp('b');
    s.printCp('c');
    try s.resize(3, 4);
    try std.testing.expectEqual(@as(u16, 3), s.cols);
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'b'), s.cellAt(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'c'), s.cellAt(0, 2).rune);
}

test "rows-only shrink keeps cursor on its content line" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 4, 6);
    defer s.deinit();
    var i: usize = 0;
    while (i < 4) : (i += 1) s.execute('\n');
    s.printCp('$');
    s.saved_row = 4;
    try std.testing.expectEqual(@as(u16, 4), s.row);
    // Height-only shrink: the top 2 rows drop into scrollback and the
    // '$' line shifts from row 4 to row 2 — the cursor must follow.
    try s.resize(4, 4);
    try std.testing.expectEqual(@as(u16, 2), s.row);
    try std.testing.expectEqual(@as(u16, 1), s.col);
    try std.testing.expectEqual(@as(u16, 2), s.saved_row);
    try std.testing.expectEqual(@as(u32, '$'), s.cellAt(2, 0).rune);
}

test "alt-screen rows shrink keeps cursor on its content line" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 4, 6);
    defer s.deinit();
    var csi = Event.Csi{};
    csi.private = '?';
    csi.params[0] = 1049;
    csi.n_params = 1;
    csi.final = 'h';
    s.csi(csi);
    var i: usize = 0;
    while (i < 4) : (i += 1) s.execute('\n');
    s.printCp('x');
    try std.testing.expectEqual(@as(u16, 4), s.row);
    try s.resize(4, 4);
    try std.testing.expectEqual(@as(u16, 2), s.row);
    try std.testing.expectEqual(@as(u32, 'x'), s.cellAt(2, 0).rune);
}

test "SGR colon-separated parses (NF spec)" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    // Parser flushes on both ; and : the same way for our purposes.
    var csi = Event.Csi{};
    csi.params = .{ 38, 5, 196, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    csi.n_params = 3;
    csi.final = 'm';
    s.csi(csi);
    const e = pool.get(s.cur_style);
    try std.testing.expect(Color.equal(e.fg, .{ .palette = 196 }));
}

test "SGR 0 resets style" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    var csi = Event.Csi{};
    csi.params[0] = 1;
    csi.n_params = 1;
    csi.final = 'm';
    s.csi(csi);
    try std.testing.expect(pool.get(s.cur_style).attrs.bold);
    csi.params[0] = 0;
    csi.n_params = 1;
    csi.final = 'm';
    s.csi(csi);
    try std.testing.expect(!pool.get(s.cur_style).attrs.bold);
}

test "DECSTR clears mode flags" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.bracketed_paste = true;
    s.mouse_mode = 1006;
    s.cursor_visible = false;
    var csi = Event.Csi{};
    csi.intermediates[0] = '!';
    csi.n_intermediates = 1;
    csi.final = 'p';
    s.csi(csi);
    try std.testing.expect(!s.bracketed_paste);
    try std.testing.expectEqual(@as(u16, 0), s.mouse_mode);
    try std.testing.expect(s.cursor_visible);
}

test "ICH inserts blanks shifting right" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 6, 1);
    defer s.deinit();
    s.printCp('a');
    s.printCp('b');
    s.printCp('c');
    s.col = 1;
    var csi = Event.Csi{};
    csi.params[0] = 2;
    csi.n_params = 1;
    csi.final = '@';
    s.csi(csi);
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 2).rune);
    try std.testing.expectEqual(@as(u32, 'b'), s.cellAt(0, 3).rune);
    try std.testing.expectEqual(@as(u32, 'c'), s.cellAt(0, 4).rune);
}

test "DCH deletes chars shifting left" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 6, 1);
    defer s.deinit();
    s.printCp('a');
    s.printCp('b');
    s.printCp('c');
    s.printCp('d');
    s.col = 1;
    var csi = Event.Csi{};
    csi.params[0] = 2;
    csi.n_params = 1;
    csi.final = 'P';
    s.csi(csi);
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'd'), s.cellAt(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 2).rune);
}

test "ED 3 clears scrollback" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 3, 2);
    defer s.deinit();
    // Fill enough lines to push some into scrollback.
    s.printCp('a');
    s.execute('\r');
    s.execute('\n');
    s.printCp('b');
    s.execute('\r');
    s.execute('\n');
    s.printCp('c');
    s.execute('\r');
    s.execute('\n');
    s.printCp('d');
    try std.testing.expect(s.scrollbackCount() > 0);
    var csi = Event.Csi{};
    csi.params[0] = 3;
    csi.n_params = 1;
    csi.final = 'J';
    s.csi(csi);
    try std.testing.expectEqual(@as(u32, 0), s.scrollbackCount());
}

test "ED 3 resets scrollback_head so eviction order survives a clear" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 3, 2);
    defer s.deinit();
    s.scrollback_capacity = 3; // tiny ring so we wrap quickly
    // Fill the ring + wrap a few times to advance scrollback_head.
    inline for (0..6) |_| {
        s.printCp('x');
        s.execute('\r');
        s.execute('\n');
    }
    try std.testing.expect(s.scrollback_head > 0);

    // Clear via ED 3.
    var csi = Event.Csi{};
    csi.params[0] = 3;
    csi.n_params = 1;
    csi.final = 'J';
    s.csi(csi);
    try std.testing.expectEqual(@as(usize, 0), s.scrollback_head);
    try std.testing.expectEqual(@as(u32, 0), s.scrollbackCount());

    // Now refill — scrollbackLine indexing must produce sane output.
    inline for ("abc") |ch| {
        s.printCp(ch);
        s.execute('\r');
        s.execute('\n');
    }
    // Walking scrollbackLine 0..N from oldest should return entries
    // in the order they were pushed.
    try std.testing.expect(s.scrollbackCount() > 0);
}

test "extract selection skips wide-cont" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 6, 1);
    defer s.deinit();
    s.printCp('a');
    s.printCp(0x4E2D); // '中'
    s.printCp('b');
    s.selection.start(0, 0, .normal);
    s.selection.extend(0, 5);
    const out = try s.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // Expect "a中b" with no extra space for the cont cell, then trailing blanks trimmed.
    try std.testing.expectEqualStrings("a\xe4\xb8\xadb", out);
}

test "REP repeats last printed glyph" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();
    s.printCp('x');
    var csi = Event.Csi{};
    csi.params[0] = 4;
    csi.n_params = 1;
    csi.final = 'b';
    s.csi(csi);
    try std.testing.expectEqual(@as(u32, 'x'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'x'), s.cellAt(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'x'), s.cellAt(0, 4).rune);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 5).rune);
}

test "HTS sets and tab honors custom stop" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 1);
    defer s.deinit();
    // Clear all stops, then set one at col 5.
    var csi = Event.Csi{};
    csi.params[0] = 3;
    csi.n_params = 1;
    csi.final = 'g';
    s.csi(csi);
    s.col = 5;
    s.escFinal(.{ .final = 'H' });
    s.col = 0;
    s.execute(0x09);
    try std.testing.expectEqual(@as(u16, 5), s.col);
}

test "CBT walks backward" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 30, 1);
    defer s.deinit();
    s.col = 17;
    var csi = Event.Csi{};
    csi.params[0] = 2;
    csi.n_params = 1;
    csi.final = 'Z';
    s.csi(csi);
    // Default 8-col stops: from 17, prev=16, prev=8.
    try std.testing.expectEqual(@as(u16, 8), s.col);
}

test "SCS DEC graphics translates 'q' to ─" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();
    // ESC ( 0 — designate G0 to DEC graphics.
    s.escFinal(.{
        .intermediates = .{ '(', 0, 0, 0 },
        .n_intermediates = 1,
        .final = '0',
    });
    s.printCp('q');
    try std.testing.expectEqual(@as(u32, 0x2500), s.cellAt(0, 0).rune);
    // SI returns to G0=ASCII when we redesignate.
    s.escFinal(.{
        .intermediates = .{ '(', 0, 0, 0 },
        .n_intermediates = 1,
        .final = 'B',
    });
    s.printCp('q');
    try std.testing.expectEqual(@as(u32, 'q'), s.cellAt(0, 1).rune);
}

test "DECRQM reports mode state" {
    const TestSink = struct {
        var captured: [64]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };

    // Set autowrap (default already true) and query 7.
    var csi = Event.Csi{};
    csi.private = '?';
    csi.intermediates[0] = '$';
    csi.n_intermediates = 1;
    csi.params[0] = 7;
    csi.n_params = 1;
    csi.final = 'p';
    s.csi(csi);
    const got = TestSink.captured[0..TestSink.captured_len];
    // Autowrap is on by default → set → reply Ps=1.
    try std.testing.expectEqualStrings("\x1b[?7;1$y", got);
}

test "mouse encoding modes are mutually-exclusive last-set" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    try std.testing.expectEqual(Screen.MouseEnc.legacy, s.mouse_enc);

    // DECSET 1006 (SGR)
    var csi = Event.Csi{};
    csi.private = '?';
    csi.params[0] = 1006;
    csi.n_params = 1;
    csi.final = 'h';
    s.csi(csi);
    try std.testing.expectEqual(Screen.MouseEnc.sgr, s.mouse_enc);

    // DECSET 1015 (urxvt) — supersedes
    csi.params[0] = 1015;
    s.csi(csi);
    try std.testing.expectEqual(Screen.MouseEnc.urxvt, s.mouse_enc);

    // DECSET 1016 (SGR-pixel)
    csi.params[0] = 1016;
    s.csi(csi);
    try std.testing.expectEqual(Screen.MouseEnc.sgr_pixel, s.mouse_enc);

    // DECRST 1016 → back to legacy
    csi.final = 'l';
    s.csi(csi);
    try std.testing.expectEqual(Screen.MouseEnc.legacy, s.mouse_enc);
}

test "DECSET 2026 toggles sync_output and DECRST flushes" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    try std.testing.expect(!s.sync_output);

    var csi = Event.Csi{};
    csi.private = '?';
    csi.params[0] = 2026;
    csi.n_params = 1;
    csi.final = 'h'; // DECSET
    s.csi(csi);
    try std.testing.expect(s.sync_output);
    try std.testing.expect(s.dirty);

    s.dirty = false;
    csi.final = 'l'; // DECRST
    s.csi(csi);
    try std.testing.expect(!s.sync_output);
    try std.testing.expect(s.dirty); // reset triggers immediate flush
}

test "CSI 20t / 21t report icon / window title" {
    const TestSink = struct {
        var captured: [128]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 24);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };
    s.onOsc("0;hello world"); // sets last_title

    TestSink.captured_len = 0;
    var csi = Event.Csi{};
    csi.params[0] = 21;
    csi.n_params = 1;
    csi.final = 't';
    s.csi(csi);
    try std.testing.expectEqualStrings("\x1b]lhello world\x1b\\", TestSink.captured[0..TestSink.captured_len]);

    TestSink.captured_len = 0;
    csi.params[0] = 20;
    s.csi(csi);
    try std.testing.expectEqualStrings("\x1b]Lhello world\x1b\\", TestSink.captured[0..TestSink.captured_len]);
}

test "CSI 14t reports rows*cell_h × cols*cell_w when set" {
    const TestSink = struct {
        var captured: [64]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 24);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };
    s.cell_pixel_w = 9;
    s.cell_pixel_h = 18;

    TestSink.captured_len = 0;
    var csi = Event.Csi{};
    csi.params[0] = 14;
    csi.n_params = 1;
    csi.final = 't';
    s.csi(csi);
    try std.testing.expectEqualStrings("\x1b[4;432;720t", TestSink.captured[0..TestSink.captured_len]);

    TestSink.captured_len = 0;
    csi.params[0] = 16;
    s.csi(csi);
    try std.testing.expectEqualStrings("\x1b[6;18;9t", TestSink.captured[0..TestSink.captured_len]);
}

test "OSC 50 query responds with current font name" {
    const TestSink = struct {
        var captured: [128]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };
    s.font_name = "/usr/share/fonts/Hack/Hack-Regular.ttf";
    s.onOsc("50;?");
    try std.testing.expectEqualStrings(
        "\x1b]50;/usr/share/fonts/Hack/Hack-Regular.ttf\x1b\\",
        TestSink.captured[0..TestSink.captured_len],
    );
}

test "OSC 1337 CursorShape and ClearScrollback directives" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();

    // CursorShape=2 (underline)
    s.onOsc("1337;CursorShape=2");
    try std.testing.expectEqual(Screen.CursorShape.underline_steady, s.cursor_shape);

    // ClearScrollback should clear the active grid (and scrollback).
    inline for ("hello") |ch| s.printCp(ch);
    s.execute('\n');
    inline for ("world") |ch| s.printCp(ch);
    s.onOsc("1337;ClearScrollback");
    // After ClearScrollback, all rows are blank.
    var any_nonzero = false;
    for (s.buf()) |ln| {
        for (ln.cells) |cell| if (cell.rune != 0) {
            any_nonzero = true;
            break;
        };
        if (any_nonzero) break;
    }
    try std.testing.expect(!any_nonzero);
}

test "SS2/SS3 single-shift bypass G0 charset for one cp" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();

    // Designate G0 to DEC graphics so 'a' would normally translate.
    s.charset_g0 = .dec_graphics;

    // SS2 escape: ESC N → pending_single_shift = ss2.
    s.escFinal(.{ .final = 'N' });
    try std.testing.expectEqual(Screen.PendingSingleShift.ss2, s.pending_single_shift);

    // Print 'a' — bypasses G0 (would be 0x2592 ▒ in DEC graphics).
    s.printCp('a');
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(Screen.PendingSingleShift.none, s.pending_single_shift);

    // Next char goes through G0 again.
    s.printCp('a');
    // 'a' in DEC graphics maps to U+2592 (▒).
    try std.testing.expectEqual(@as(u32, 0x2592), s.cellAt(0, 1).rune);
}

test "DECRQM reports 1005/1015/1016" {
    const TestSink = struct {
        var captured: [64]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };
    s.mouse_enc = .urxvt;

    // Query 1015 — should be set.
    TestSink.captured_len = 0;
    var csi = Event.Csi{};
    csi.private = '?';
    csi.intermediates[0] = '$';
    csi.n_intermediates = 1;
    csi.params[0] = 1015;
    csi.n_params = 1;
    csi.final = 'p';
    s.csi(csi);
    try std.testing.expectEqualStrings("\x1b[?1015;1$y", TestSink.captured[0..TestSink.captured_len]);

    // Query 1006 — should be reset.
    TestSink.captured_len = 0;
    csi.params[0] = 1006;
    s.csi(csi);
    try std.testing.expectEqualStrings("\x1b[?1006;2$y", TestSink.captured[0..TestSink.captured_len]);
}

test "soft-wrap selection joins without newline" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 2);
    defer s.deinit();
    inline for ("hellowor") |ch| s.printCp(ch);
    s.selection.start(0, 0, .normal);
    // Selection end is exclusive — col 4 covers row 1 [w o r].
    s.selection.extend(1, 4);
    const out = try s.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(out);
    // Without soft-wrap awareness this would be "hello\nwor".
    try std.testing.expectEqualStrings("hellowor", out);
}

test "DECALN fills screen with E" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 4, 2);
    defer s.deinit();
    s.escFinal(.{
        .intermediates = .{ '#', 0, 0, 0 },
        .n_intermediates = 1,
        .final = '8',
    });
    var r: u16 = 0;
    while (r < 2) : (r += 1) {
        var col: u16 = 0;
        while (col < 4) : (col += 1) {
            try std.testing.expectEqual(@as(u32, 'E'), s.cellAt(r, col).rune);
        }
    }
}

test "1049 saves and restores cursor" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 5);
    defer s.deinit();
    s.row = 2;
    s.col = 3;
    var csi = Event.Csi{};
    csi.private = '?';
    csi.params[0] = 1049;
    csi.n_params = 1;
    csi.final = 'h';
    s.csi(csi);
    try std.testing.expect(s.use_alt);
    try std.testing.expectEqual(@as(u16, 0), s.row);
    try std.testing.expectEqual(@as(u16, 0), s.col);
    csi.final = 'l';
    s.csi(csi);
    try std.testing.expect(!s.use_alt);
    try std.testing.expectEqual(@as(u16, 2), s.row);
    try std.testing.expectEqual(@as(u16, 3), s.col);
}

test "legacy mode 47 toggles alt screen without cursor moves" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 5);
    defer s.deinit();
    s.row = 2;
    s.col = 3;
    var csi = Event.Csi{};
    csi.private = '?';
    csi.params[0] = 47;
    csi.n_params = 1;
    csi.final = 'h';
    s.csi(csi);
    try std.testing.expect(s.use_alt);
    // 47 is the plain switch: no clear, no cursor save/home.
    try std.testing.expectEqual(@as(u16, 2), s.row);
    try std.testing.expectEqual(@as(u16, 3), s.col);
    csi.final = 'l';
    s.csi(csi);
    try std.testing.expect(!s.use_alt);
    try std.testing.expectEqual(@as(u16, 2), s.row);
    try std.testing.expectEqual(@as(u16, 3), s.col);
}

test "kitty graphics query replies OK" {
    const TestSink = struct {
        var captured: [64]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };
    s.onApc("Gi=42,a=q");
    const got = TestSink.captured[0..TestSink.captured_len];
    try std.testing.expectEqualStrings("\x1b_Gi=42;OK\x1b\\", got);
}

test "kitty graphics query honours q=1 quiet — no reply" {
    const TestSink = struct {
        var captured: [64]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };
    s.onApc("Gi=42,a=q,q=1");
    try std.testing.expectEqual(@as(usize, 0), TestSink.captured_len);
}

test "RIS resets charset state" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    // ESC ( 0 — G0 to dec_graphics.
    s.escFinal(.{
        .intermediates = .{ '(', 0, 0, 0 },
        .n_intermediates = 1,
        .final = '0',
    });
    try std.testing.expectEqual(Screen.Charset.dec_graphics, s.charset_g0);
    s.fullReset();
    try std.testing.expectEqual(Screen.Charset.ascii, s.charset_g0);
}

test "tab_stops resize keeps existing on shrink, pads on grow" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    // Default: stop at 8.
    try std.testing.expect(s.tab_stops.items[8]);
    // Add a custom stop at col 3.
    s.tab_stops.items[3] = true;
    // Shrink to 5 — col 3 stop preserved, col 8 dropped.
    try s.resize(5, 2);
    try std.testing.expect(s.tab_stops.items[3]);
    try std.testing.expectEqual(@as(usize, 5), s.tab_stops.items.len);
    // Grow to 17 — old stops kept, default stops at 8 and 16 added.
    try s.resize(17, 2);
    try std.testing.expect(s.tab_stops.items[3]);
    try std.testing.expect(s.tab_stops.items[8]);
    try std.testing.expect(s.tab_stops.items[16]);
}

test "clearAndScrollback wipes screen + ring + cursor home" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 2);
    defer s.deinit();
    inline for ("hello") |ch| s.printCp(ch);
    s.execute('\r');
    s.execute('\n');
    inline for ("world") |ch| s.printCp(ch);
    s.execute('\r');
    s.execute('\n');
    inline for ("x") |ch| s.printCp(ch);
    try std.testing.expect(s.scrollbackCount() > 0);
    s.clearAndScrollback();
    try std.testing.expectEqual(@as(u32, 0), s.scrollbackCount());
    try std.testing.expectEqual(@as(u16, 0), s.row);
    try std.testing.expectEqual(@as(u16, 0), s.col);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 0).rune);
}

test "SGR 4:3 sets curly underline" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    // `\e[4:3m` — curly underline via colon-separated SGR.
    var csi = Event.Csi{};
    csi.params[0] = 4;
    csi.params[1] = 3;
    csi.setSub(1, true);
    csi.n_params = 2;
    csi.final = 'm';
    s.csi(csi);
    s.printCp('x');
    const e = pool.get(s.cellAt(0, 0).style_ref);
    try std.testing.expect(e.attrs.curly_underline);
    try std.testing.expect(!e.attrs.underline);
}

test "SGR 4;3 sets underline AND italic (semicolon — separate params)" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    // `\e[4;3m` — two independent SGR params: 4 (underline) + 3 (italic).
    var csi = Event.Csi{};
    csi.params[0] = 4;
    csi.params[1] = 3;
    // is_sub[] all false — params separated by ';' in input.
    csi.n_params = 2;
    csi.final = 'm';
    s.csi(csi);
    s.printCp('x');
    const e = pool.get(s.cellAt(0, 0).style_ref);
    try std.testing.expect(e.attrs.underline);
    try std.testing.expect(e.attrs.italic);
    try std.testing.expect(!e.attrs.curly_underline);
}

test "OSC 22: pointer shape sink fires" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();

    const Spy = struct {
        var got: [32]u8 = undefined;
        var got_len: usize = 0;
        fn cb(_: ?*anyopaque, name: []const u8) void {
            const n = @min(name.len, got.len);
            @memcpy(got[0..n], name[0..n]);
            got_len = n;
        }
    };
    Spy.got_len = 0;
    s.sink.on_pointer_shape = Spy.cb;
    s.onOsc("22;hand2");
    try std.testing.expectEqualStrings("hand2", Spy.got[0..Spy.got_len]);
}

test "title stack (CSI 22/23 t) push + pop" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();

    const Spy = struct {
        var got: [64]u8 = undefined;
        var got_len: usize = 0;
        fn cb(_: ?*anyopaque, t: []const u8) void {
            const n = @min(t.len, got.len);
            @memcpy(got[0..n], t[0..n]);
            got_len = n;
        }
    };
    s.sink.on_title = Spy.cb;

    // OSC 0 ; first
    s.onOsc("0;first");
    try std.testing.expectEqualStrings("first", Spy.got[0..Spy.got_len]);
    // Push.
    var push = Event.Csi{};
    push.params[0] = 22;
    push.n_params = 1;
    push.final = 't';
    s.csi(push);
    // OSC 0 ; second
    s.onOsc("0;second");
    try std.testing.expectEqualStrings("second", Spy.got[0..Spy.got_len]);
    // Pop — should restore "first".
    Spy.got_len = 0;
    var pop = Event.Csi{};
    pop.params[0] = 23;
    pop.n_params = 1;
    pop.final = 't';
    s.csi(pop);
    try std.testing.expectEqualStrings("first", Spy.got[0..Spy.got_len]);
}

test "LNM (CSI 20 h): LF carries an implicit CR" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp('a');
    s.printCp('b');
    // Default mode (LNM off): bare LF moves down but col stays.
    s.execute(0x0A);
    try std.testing.expectEqual(@as(u16, 1), s.row);
    try std.testing.expectEqual(@as(u16, 2), s.col);

    // Reset, enable LNM (CSI 20 h).
    s.fullReset();
    s.printCp('a');
    s.printCp('b');
    var csi = Event.Csi{};
    csi.params[0] = 20;
    csi.n_params = 1;
    csi.final = 'h';
    s.csi(csi);
    s.execute(0x0A);
    try std.testing.expectEqual(@as(u16, 1), s.row);
    try std.testing.expectEqual(@as(u16, 0), s.col); // CR happened too
}

test "IRM shifts cells right" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    inline for ("abcd") |ch| s.printCp(ch);
    s.col = 1;
    // CSI 4 h — insert mode on.
    var csi = Event.Csi{};
    csi.params[0] = 4;
    csi.n_params = 1;
    csi.final = 'h';
    s.csi(csi);
    s.printCp('X');
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 'X'), s.cellAt(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'b'), s.cellAt(0, 2).rune);
    try std.testing.expectEqual(@as(u32, 'c'), s.cellAt(0, 3).rune);
    // 'd' shifted off the right edge.
}

test "parseColor handles rgb: and #RRGGBB" {
    const r1 = Screen.parseColor("rgb:ff/00/80").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r1[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), r1[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r1[2], 0.01);
    const r2 = Screen.parseColor("#ff0080").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r2[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), r2[2], 0.01);
    // 4-hex form.
    const r3 = Screen.parseColor("rgb:ffff/0000/8080").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r3[0], 0.001);
    // Bad input.
    try std.testing.expect(Screen.parseColor("not a color") == null);
}

test "OSC 133 ; A records prompt mark with line ID" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.row = 1;
    const id1 = s.active[1].id;
    s.onOsc("133;A");
    try std.testing.expectEqual(@as(u16, 1), s.prompt_marks_len);
    try std.testing.expectEqual(id1, s.prompt_marks[0]);
    s.row = 2;
    const id2 = s.active[2].id;
    s.onOsc("133;A");
    try std.testing.expectEqual(@as(u16, 2), s.prompt_marks_len);
    try std.testing.expectEqual(id2, s.prompt_marks[1]);

    // Mark survives scrolling: scroll once, the row at id2 is now at
    // row 1 (or in scrollback), but rowForLineId resolves both.
    s.scrollUp(1);
    const r1 = s.rowForLineId(id1);
    const r2 = s.rowForLineId(id2);
    try std.testing.expect(r1 != null);
    try std.testing.expect(r2 != null);
}

fn testCsiPrivate(s: *Screen, comptime n_params: usize, params: [n_params]u16, final: u8) void {
    var csi = Event.Csi{};
    inline for (params, 0..) |p, i| csi.params[i] = p;
    csi.n_params = n_params;
    csi.private = '?';
    csi.final = final;
    s.apply(.{ .csi = csi });
}

test "mode 2048: report on set and on every resize" {
    const Cap = struct {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, buf.len - len);
            @memcpy(buf[len .. len + n], bytes[0..n]);
            len += n;
        }
    };
    Cap.len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_write_pty = Cap.write };

    // Enable → immediate report. Pixel fields 0 (no cell metrics).
    testCsiPrivate(s, 1, .{2048}, 'h');
    try std.testing.expectEqualStrings("\x1b[48;3;10;0;0t", Cap.buf[0..Cap.len]);

    // Resize with known cell metrics → report includes pixels.
    Cap.len = 0;
    s.cell_pixel_w = 8;
    s.cell_pixel_h = 16;
    try s.resize(8, 2);
    try std.testing.expectEqualStrings("\x1b[48;2;8;32;64t", Cap.buf[0..Cap.len]);

    // DECRQM sees it set; reset stops the reports.
    Cap.len = 0;
    var rqm = Event.Csi{};
    rqm.params[0] = 2048;
    rqm.n_params = 1;
    rqm.private = '?';
    rqm.intermediates[0] = '$';
    rqm.n_intermediates = 1;
    rqm.final = 'p';
    s.apply(.{ .csi = rqm });
    try std.testing.expectEqualStrings("\x1b[?2048;1$y", Cap.buf[0..Cap.len]);
    Cap.len = 0;
    testCsiPrivate(s, 1, .{2048}, 'l');
    try s.resize(10, 3);
    try std.testing.expectEqual(@as(usize, 0), Cap.len);
}

test "mode 2027 reports permanently set; 996/997/2031 color scheme" {
    const Cap = struct {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, buf.len - len);
            @memcpy(buf[len .. len + n], bytes[0..n]);
            len += n;
        }
    };
    Cap.len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_write_pty = Cap.write };

    // 2027 — always-on clustering, DECRPM 3.
    var rqm = Event.Csi{};
    rqm.params[0] = 2027;
    rqm.n_params = 1;
    rqm.private = '?';
    rqm.intermediates[0] = '$';
    rqm.n_intermediates = 1;
    rqm.final = 'p';
    s.apply(.{ .csi = rqm });
    try std.testing.expectEqualStrings("\x1b[?2027;3$y", Cap.buf[0..Cap.len]);

    // DSR ?996 — dark by default, light after the GUI pushes.
    Cap.len = 0;
    testCsiPrivate(s, 1, .{996}, 'n');
    try std.testing.expectEqualStrings("\x1b[?997;1n", Cap.buf[0..Cap.len]);
    Cap.len = 0;
    s.color_scheme_dark = false;
    testCsiPrivate(s, 1, .{996}, 'n');
    try std.testing.expectEqualStrings("\x1b[?997;2n", Cap.buf[0..Cap.len]);

    // Mode 2031: unsolicited report only when subscribed AND flipped.
    Cap.len = 0;
    s.notifyColorScheme(true); // flip, but mode off → silent
    try std.testing.expectEqual(@as(usize, 0), Cap.len);
    testCsiPrivate(s, 1, .{2031}, 'h');
    s.notifyColorScheme(true); // no flip → silent
    try std.testing.expectEqual(@as(usize, 0), Cap.len);
    s.notifyColorScheme(false); // flip → report
    try std.testing.expectEqualStrings("\x1b[?997;2n", Cap.buf[0..Cap.len]);
}

test "mux mirror: mute_responses silences queries, GUI-owned paths still answer" {
    const Cap = struct {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, buf.len - len);
            @memcpy(buf[len .. len + n], bytes[0..n]);
            len += n;
        }
    };
    Cap.len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_write_pty = Cap.write };
    s.mute_responses = true;

    // DSR 6 (cursor) and DA are answered by the daemon — the mirror
    // must stay silent or the app sees every reply twice.
    var dsr6 = Event.Csi{};
    dsr6.params[0] = 6;
    dsr6.n_params = 1;
    dsr6.final = 'n';
    s.apply(.{ .csi = dsr6 });
    var da = Event.Csi{};
    da.final = 'c';
    s.apply(.{ .csi = da });
    try std.testing.expectEqual(@as(usize, 0), Cap.len);

    // GUI-owned replies bypass the mute: ?996 and the OSC 52 deny.
    testCsiPrivate(s, 1, .{996}, 'n');
    try std.testing.expectEqualStrings("\x1b[?997;1n", Cap.buf[0..Cap.len]);
    Cap.len = 0;
    s.onOsc("52;c;?");
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", Cap.buf[0..Cap.len]);

    // Daemon side: defer_gui_queries leaves both unanswered there.
    Cap.len = 0;
    s.mute_responses = false;
    s.defer_gui_queries = true;
    testCsiPrivate(s, 1, .{996}, 'n');
    s.onOsc("52;c;?");
    try std.testing.expectEqual(@as(usize, 0), Cap.len);
}

test "OSC 99 kitty notifications: chunked title+body, base64, id switch" {
    const TestSink = struct {
        var last: Screen.NotificationEvent = .{};
        var title_buf: [128]u8 = undefined;
        var body_buf: [128]u8 = undefined;
        var buttons_buf: [128]u8 = undefined;
        var icon_buf: [128]u8 = undefined;
        var fired: u32 = 0;
        fn notify(_: ?*anyopaque, ev: Screen.NotificationEvent) void {
            // Slices are borrowed; copy what assertions need.
            last = ev;
            @memcpy(title_buf[0..ev.title.len], ev.title);
            last.title = title_buf[0..ev.title.len];
            @memcpy(body_buf[0..ev.body.len], ev.body);
            last.body = body_buf[0..ev.body.len];
            @memcpy(buttons_buf[0..ev.buttons_raw.len], ev.buttons_raw);
            last.buttons_raw = buttons_buf[0..ev.buttons_raw.len];
            @memcpy(icon_buf[0..ev.icon_name.len], ev.icon_name);
            last.icon_name = icon_buf[0..ev.icon_name.len];
            fired += 1;
        }
    };
    TestSink.fired = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_notification = TestSink.notify };

    // Simple single-chunk: payload is the title.
    s.onOsc("99;;hello");
    try std.testing.expectEqual(@as(u32, 1), TestSink.fired);
    try std.testing.expectEqualStrings("hello", TestSink.last.title);
    try std.testing.expect(!TestSink.last.want_report);
    try std.testing.expect(TestSink.last.want_focus);

    // Chunked: title, then body across two chunks, then done.
    s.onOsc("99;i=x:d=0;Build");
    try std.testing.expectEqual(@as(u32, 1), TestSink.fired); // not yet
    s.onOsc("99;i=x:d=0:p=body;part1 ");
    s.onOsc("99;i=x:p=body;part2");
    try std.testing.expectEqual(@as(u32, 2), TestSink.fired);
    try std.testing.expectEqualStrings("Build", TestSink.last.title);
    try std.testing.expectEqualStrings("part1 part2", TestSink.last.body);
    try std.testing.expectEqualStrings("x", TestSink.last.id);

    // base64 payload (e=1): "aGk=" → "hi".
    s.onOsc("99;e=1;aGk=");
    try std.testing.expectEqualStrings("hi", TestSink.last.title);

    // A new identifier discards an unfinished accumulation.
    s.onOsc("99;i=a:d=0;stale");
    s.onOsc("99;i=b;fresh");
    try std.testing.expectEqualStrings("fresh", TestSink.last.title);
}

test "OSC 99: buttons, icon, urgency, actions, occasion, close, query" {
    const TestSink = struct {
        var last: Screen.NotificationEvent = .{};
        var buttons_buf: [128]u8 = undefined;
        var icon_name_buf: [128]u8 = undefined;
        var icon_data_buf: [128]u8 = undefined;
        var id_buf: [64]u8 = undefined;
        var fired: u32 = 0;
        fn notify(_: ?*anyopaque, ev: Screen.NotificationEvent) void {
            last = ev;
            @memcpy(buttons_buf[0..ev.buttons_raw.len], ev.buttons_raw);
            last.buttons_raw = buttons_buf[0..ev.buttons_raw.len];
            @memcpy(icon_name_buf[0..ev.icon_name.len], ev.icon_name);
            last.icon_name = icon_name_buf[0..ev.icon_name.len];
            @memcpy(icon_data_buf[0..ev.icon_data.len], ev.icon_data);
            last.icon_data = icon_data_buf[0..ev.icon_data.len];
            @memcpy(id_buf[0..ev.id.len], ev.id);
            last.id = id_buf[0..ev.id.len];
            fired += 1;
        }
        var resp: [256]u8 = undefined;
        var resp_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, resp.len - resp_len);
            @memcpy(resp[resp_len .. resp_len + n], bytes[0..n]);
            resp_len += n;
        }
    };
    TestSink.fired = 0;
    TestSink.resp_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_notification = TestSink.notify, .on_write_pty = TestSink.write };

    // Buttons (U+2028 separated), urgency, report action, occasion,
    // icon name (n= is base64: "ZGlhbG9nLXdhcm5pbmc=" = dialog-warning).
    s.onOsc("99;i=n1:d=0:u=2:a=report:o=unfocused:n=ZGlhbG9nLXdhcm5pbmc=;Disk alert");
    s.onOsc("99;i=n1:p=buttons;Retry\xe2\x80\xa8Ignore");
    try std.testing.expectEqual(@as(u32, 1), TestSink.fired);
    try std.testing.expectEqualStrings("Retry\xe2\x80\xa8Ignore", TestSink.last.buttons_raw);
    try std.testing.expectEqualStrings("dialog-warning", TestSink.last.icon_name);
    try std.testing.expectEqual(@as(?u8, 2), TestSink.last.urgency);
    try std.testing.expect(TestSink.last.want_report);
    try std.testing.expectEqual(Screen.NotificationEvent.Occasion.unfocused, TestSink.last.occasion);

    // Icon image payload (p=icon, base64).
    s.onOsc("99;i=n2:d=0:p=icon:e=1;UE5HIQ==");
    s.onOsc("99;i=n2;t");
    try std.testing.expectEqualStrings("PNG!", TestSink.last.icon_data);

    // -focus negation.
    s.onOsc("99;a=-focus;nofocus");
    try std.testing.expect(!TestSink.last.want_focus);

    // p=close fires a close event with the sanitized id.
    s.onOsc("99;i=ab\x07cd:p=close;");
    try std.testing.expect(TestSink.last.close);
    try std.testing.expectEqualStrings("abcd", TestSink.last.id);

    // p=? capability query gets a reply that omits c= (no close
    // feedback through GNotification) and echoes the id.
    s.onOsc("99;i=q1:p=?;");
    const resp = TestSink.resp[0..TestSink.resp_len];
    try std.testing.expect(std.mem.startsWith(u8, resp, "\x1b]99;i=q1:p=?;"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "p=title,body,buttons,icon,close") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "c=") == null);

    // p=alive is unsupported — ignored without a crash.
    s.onOsc("99;i=q2:p=alive;");
}

test "OSC 4 multi-pair set + bare OSC 104/111 reset" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();

    // pywal-style: two pairs in one OSC 4.
    s.onOsc("4;1;#102030;2;#405060");
    try std.testing.expectEqual([3]u8{ 0x10, 0x20, 0x30 }, s.palette[1]);
    try std.testing.expectEqual([3]u8{ 0x40, 0x50, 0x60 }, s.palette[2]);

    // Multi-index 104 resets only the named entries.
    s.onOsc("104;1;2");
    try std.testing.expectEqual(palette_default_256[1], s.palette[1]);
    try std.testing.expectEqual(palette_default_256[2], s.palette[2]);

    // Bare "104" (no semicolon at all) resets everything.
    s.onOsc("4;3;#0a0b0c");
    s.onOsc("104");
    try std.testing.expectEqual(palette_default_256[3], s.palette[3]);

    // Bare "111" restores the configured bg.
    s.configured_bg = .{ 0.5, 0.5, 0.5, 1.0 };
    s.default_bg = .{ 0.0, 0.0, 0.0, 1.0 };
    s.onOsc("111");
    try std.testing.expectEqual(@as(f32, 0.5), s.default_bg[0]);
}

test "OSC 52 read: denied by default with empty reply, sink fired when allowed" {
    const TestSink = struct {
        var captured: [64]u8 = undefined;
        var captured_len: usize = 0;
        var get_fired: ?u8 = null;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
        fn get(_: ?*anyopaque, selection: u8) void {
            get_fired = selection;
        }
    };
    TestSink.captured_len = 0;
    TestSink.get_fired = null;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write, .on_clipboard_get = TestSink.get };

    // Default: denied → immediate empty reply, no sink call.
    s.onOsc("52;c;?");
    try std.testing.expectEqualStrings("\x1b]52;c;\x1b\\", TestSink.captured[0..TestSink.captured_len]);
    try std.testing.expectEqual(@as(?u8, null), TestSink.get_fired);

    // Allowed: sink fires with the selection, no synchronous reply.
    TestSink.captured_len = 0;
    s.allow_clipboard_read = true;
    s.onOsc("52;p;?");
    try std.testing.expectEqual(@as(usize, 0), TestSink.captured_len);
    try std.testing.expectEqual(@as(?u8, 'p'), TestSink.get_fired);

    // Write path is unaffected by the gate (handled by clipboard_set).
    s.onOsc("52;c;aGVsbG8=");
}

test "OSC 133 C/D bounds the last-command-output zone" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 4);
    defer s.deinit();

    const nl = struct {
        fn go(scr: *Screen) void {
            scr.apply(.{ .execute = '\n' });
            scr.apply(.{ .execute = '\r' });
        }
    }.go;

    // Prompt + command echo on row 0; output starts row 1.
    s.onOsc("133;A");
    for ("$ ls") |b| s.printCp(b);
    nl(s);
    s.onOsc("133;C");
    for ("file1") |b| s.printCp(b);
    nl(s);
    for ("file2") |b| s.printCp(b);
    nl(s);
    s.onOsc("133;D;3");

    try std.testing.expect(s.lastCommandOutputAvailable());
    try std.testing.expectEqual(@as(i32, 3), s.last_cmd_exit);
    const out = (try s.extractLastCommandOutput(std.testing.allocator)).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("file1\nfile2\n", out);

    // Zone survives scrolling into scrollback.
    var k: u32 = 0;
    while (k < 6) : (k += 1) s.scrollUp(1);
    const out2 = (try s.extractLastCommandOutput(std.testing.allocator)).?;
    defer std.testing.allocator.free(out2);
    try std.testing.expectEqualStrings("file1\nfile2\n", out2);

    // D without a preceding C records nothing new.
    s.onOsc("133;D;0");
    try std.testing.expectEqual(@as(i32, 3), s.last_cmd_exit);

    // Empty zone (C immediately followed by D on the same row) is
    // not "available".
    s.onOsc("133;C");
    s.onOsc("133;D;0");
    try std.testing.expect(!s.lastCommandOutputAvailable());
}

test "OSC 133 D on the alt screen still signals command completion" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 4);
    defer s.deinit();

    // Command starts on the main screen, TUI enters the alt screen and
    // dies without leaving it; the shell prompt (with D) lands on alt.
    s.onOsc("133;A");
    s.onOsc("133;C");
    const seq_before = s.cmd_completion_seq;
    s.toggleAltScreen(true);
    s.onOsc("133;D;137");
    try std.testing.expectEqual(seq_before + 1, s.cmd_completion_seq);
    try std.testing.expectEqual(@as(i32, 137), s.last_cmd_exit);
    try std.testing.expectEqual(@as(u64, 0), s.pending_output_start_id);
    try std.testing.expect(!s.pending_output_awaits_nl);

    // A stray alt-screen D with no open C does NOT fabricate one.
    s.onOsc("133;D;0");
    try std.testing.expectEqual(seq_before + 1, s.cmd_completion_seq);
    try std.testing.expectEqual(@as(i32, 137), s.last_cmd_exit);
}

test "OSC 133 mid-line C (bash DEBUG trap) excludes the command echo" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 4);
    defer s.deinit();

    const nl = struct {
        fn go(scr: *Screen) void {
            scr.apply(.{ .execute = '\n' });
            scr.apply(.{ .execute = '\r' });
        }
    }.go;

    // bash: C fires from the DEBUG trap BEFORE the accept-line
    // newline reaches the terminal — cursor still at the end of the
    // echoed command. The zone must start on the NEXT line.
    s.onOsc("133;A");
    for ("$ echo hi") |b| s.printCp(b);
    s.onOsc("133;C");
    nl(s);
    for ("hi") |b| s.printCp(b);
    nl(s);
    s.onOsc("133;D;0");

    const out = (try s.extractLastCommandOutput(std.testing.allocator)).?;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hi\n", out);

    // Mid-line C, no output at all: empty zone, exit code preserved.
    for ("$ false") |b| s.printCp(b);
    s.onOsc("133;C");
    nl(s);
    s.onOsc("133;D;1");
    try std.testing.expectEqual(@as(i32, 1), s.last_cmd_exit);
    const empty = (try s.extractLastCommandOutput(std.testing.allocator)).?;
    defer std.testing.allocator.free(empty);
    try std.testing.expectEqualStrings("", empty);
}

test "command-zone ring: membership, selection, fast row lookup" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 4);
    defer s.deinit();

    const nl = struct {
        fn go(scr: *Screen) void {
            scr.apply(.{ .execute = '\n' });
            scr.apply(.{ .execute = '\r' });
        }
    }.go;

    // Two commands: first fails (exit 1), second succeeds.
    s.onOsc("133;A");
    for ("$ a") |b| s.printCp(b);
    nl(s);
    s.onOsc("133;C");
    for ("boom") |b| s.printCp(b);
    nl(s);
    s.onOsc("133;D;1");
    s.onOsc("133;A");
    for ("$ b") |b| s.printCp(b);
    nl(s);
    s.onOsc("133;C");
    for ("ok") |b| s.printCp(b);
    nl(s);
    s.onOsc("133;D;0");

    try std.testing.expectEqual(@as(u16, 2), s.cmd_zones_len);
    // Newest-first iteration.
    try std.testing.expectEqual(@as(i32, 0), s.cmdZone(0).?.exit);
    try std.testing.expectEqual(@as(i32, 1), s.cmdZone(1).?.exit);
    try std.testing.expect(s.cmdZone(2) == null);

    // The screen scrolled once while printing, so "boom" sits at
    // display row 0; it belongs to the failed zone.
    const z = s.cmdZoneContainingDisplayRow(0).?;
    try std.testing.expectEqual(@as(i32, 1), z.exit);
    try std.testing.expectEqual(@as(i32, 0), z.start_row);
    try std.testing.expectEqual(@as(i32, 1), z.end_row);

    // Click-select primes a line-wise selection over the zone.
    try std.testing.expect(s.selectCmdZoneAt(0));
    try std.testing.expectEqual(@import("selection.zig").Mode.line_select, s.selection.mode);
    const text = try s.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "boom") != null);

    // The "$ b" prompt row between the two zones resolves to null.
    try std.testing.expect(s.cmdZoneContainingDisplayRow(1) == null);

    // Fast lookup agrees with the linear walk after scrolling the
    // zones into scrollback.
    var k: u32 = 0;
    while (k < 6) : (k += 1) s.scrollUp(1);
    const fail_z = s.cmdZone(1).?;
    try std.testing.expectEqual(
        s.rowForLineId(fail_z.start_id),
        s.rowForLineIdFast(fail_z.start_id),
    );
}

test "jumpPrevPrompt scrolls into scrollback" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    // Record a mark at row 0, then scroll lots so it's in scrollback.
    s.row = 0;
    s.onOsc("133;A");
    var k: u32 = 0;
    while (k < 10) : (k += 1) s.scrollUp(1);
    try std.testing.expectEqual(@as(u32, 0), s.view_offset);
    const off = s.jumpPrevPrompt();
    try std.testing.expect(off != null);
    try std.testing.expect(s.view_offset > 0);
}

test "XTMODKEYS sets modify_other_keys level" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    var csi = Event.Csi{};
    csi.private = '>';
    csi.params[0] = 4;
    csi.params[1] = 1;
    csi.n_params = 2;
    csi.final = 'm';
    s.csi(csi);
    try std.testing.expectEqual(@as(u8, 1), s.modify_other_keys);
    csi.params[1] = 2;
    s.csi(csi);
    try std.testing.expectEqual(@as(u8, 2), s.modify_other_keys);
}

test "DA1 advertises sixel + color" {
    const TestSink = struct {
        var captured: [64]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };
    var csi = Event.Csi{};
    csi.final = 'c';
    s.csi(csi);
    try std.testing.expectEqualStrings("\x1b[?62;4;22c", TestSink.captured[0..TestSink.captured_len]);
}

test "clearScrollbackOnly wipes ring without disturbing visible screen" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 2);
    defer s.deinit();

    // Push enough content to populate scrollback + leave content
    // visible: rows=2, so 4 lines of input → 2 in scrollback, 2 visible.
    for ("aaa") |b| s.printCp(b);
    s.apply(.{ .execute = '\n' });
    s.apply(.{ .execute = '\r' });
    for ("bbb") |b| s.printCp(b);
    s.apply(.{ .execute = '\n' });
    s.apply(.{ .execute = '\r' });
    for ("ccc") |b| s.printCp(b);
    s.apply(.{ .execute = '\n' });
    s.apply(.{ .execute = '\r' });
    for ("ddd") |b| s.printCp(b);

    try std.testing.expect(s.scrollbackCount() > 0);
    s.clearScrollbackOnly();
    try std.testing.expectEqual(@as(u32, 0), s.scrollbackCount());

    // Visible content + cursor should be intact — extractScreen
    // should still see "ccc" and "ddd".
    const text = try s.extractScreen(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("ccc\nddd\n", text);
}

test "OSC 4 sets palette index, OSC 104 resets it" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.onOsc("4;1;rgb:ff/00/00");
    try std.testing.expectEqual([3]u8{ 255, 0, 0 }, s.palette[1]);
    s.onOsc("104;1");
    try std.testing.expectEqual(palette_default_256[1], s.palette[1]);
}

test "OSC 4 query returns palette entry as rgb spec" {
    const TestSink = struct {
        var captured: [128]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };

    // Set palette[1] = #ff8000, then query it back.
    s.onOsc("4;1;rgb:ff/80/00");
    s.onOsc("4;1;?");
    const got = TestSink.captured[0..TestSink.captured_len];
    // Format: ESC ]4;1;rgb:ffff/8080/0000 ST  (each byte duplicated → 16-bit).
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:ffff/8080/0000\x1b\\", got);
}

test "OSC 10 query returns default_fg as 16-bit rgb" {
    const TestSink = struct {
        var captured: [128]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };

    // Set default_fg to a known value, then query.
    s.onOsc("10;rgb:ff/00/80");
    s.onOsc("10;?");
    const got = TestSink.captured[0..TestSink.captured_len];
    // 0xff → 65535, 0x00 → 0, 0x80 → 32896 = 0x8080.
    try std.testing.expectEqualStrings("\x1b]10;rgb:ffff/0000/8080\x1b\\", got);
}

test "OSC 11 query returns default_bg" {
    const TestSink = struct {
        var captured: [128]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };

    s.onOsc("11;rgb:00/00/00");
    s.onOsc("11;?");
    const got = TestSink.captured[0..TestSink.captured_len];
    try std.testing.expectEqualStrings("\x1b]11;rgb:0000/0000/0000\x1b\\", got);
}

test "OSC 12 query falls back to default_fg when cursor sentinel set" {
    const TestSink = struct {
        var captured: [128]u8 = undefined;
        var captured_len: usize = 0;
        fn write(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, captured.len - captured_len);
            @memcpy(captured[captured_len .. captured_len + n], bytes[0..n]);
            captured_len += n;
        }
    };
    TestSink.captured_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.sink = .{ .on_write_pty = TestSink.write };

    // Lock fg to a known value; cursor stays at sentinel (alpha=0
    // means "use fg"), so OSC 12 query should report fg.
    s.onOsc("10;rgb:80/40/20");
    s.onOsc("112"); // reset cursor to sentinel
    s.onOsc("12;?");
    const got = TestSink.captured[0..TestSink.captured_len];
    try std.testing.expectEqualStrings("\x1b]12;rgb:8080/4040/2020\x1b\\", got);
}

test "OSC 11 sets default_bg, OSC 111 resets" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.onOsc("11;rgb:ff/00/80");
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s.default_bg[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s.default_bg[1], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), s.default_bg[2], 0.01);
    s.onOsc("111;");
    try std.testing.expectApproxEqAbs(@as(f32, 0.10), s.default_bg[0], 0.01);
}

test "OSC 777 notify dispatches title+body" {
    const Spy = struct {
        var got_title: [64]u8 = undefined;
        var got_body: [64]u8 = undefined;
        var got_title_len: usize = 0;
        var got_body_len: usize = 0;
        fn cb(_: ?*anyopaque, ev: Screen.NotificationEvent) void {
            const tn = @min(ev.title.len, got_title.len);
            @memcpy(got_title[0..tn], ev.title[0..tn]);
            got_title_len = tn;
            const bn = @min(ev.body.len, got_body.len);
            @memcpy(got_body[0..bn], ev.body[0..bn]);
            got_body_len = bn;
        }
    };
    Spy.got_title_len = 0;
    Spy.got_body_len = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();
    s.sink = .{ .on_notification = Spy.cb };
    s.onOsc("777;notify;Hello;World");
    try std.testing.expectEqualStrings("Hello", Spy.got_title[0..Spy.got_title_len]);
    try std.testing.expectEqualStrings("World", Spy.got_body[0..Spy.got_body_len]);
}

test "OSC 9;4 routes to progress, plain OSC 9 stays a notification" {
    const Spy = struct {
        var progress: ?struct { state: u8, percent: u8 } = null;
        var notified: usize = 0;
        fn onProgress(_: ?*anyopaque, state: u8, percent: u8) void {
            progress = .{ .state = state, .percent = percent };
        }
        fn onNotify(_: ?*anyopaque, _: Screen.NotificationEvent) void {
            notified += 1;
        }
    };
    Spy.progress = null;
    Spy.notified = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();
    s.sink = .{ .on_progress = Spy.onProgress, .on_notification = Spy.onNotify };

    s.onOsc("9;4;1;7");
    try std.testing.expectEqual(@as(u8, 1), Spy.progress.?.state);
    try std.testing.expectEqual(@as(u8, 7), Spy.progress.?.percent);
    try std.testing.expectEqual(@as(usize, 0), Spy.notified);

    s.onOsc("9;4;2;29"); // error state
    try std.testing.expectEqual(@as(u8, 2), Spy.progress.?.state);

    s.onOsc("9;4;0"); // clear
    try std.testing.expectEqual(@as(u8, 0), Spy.progress.?.state);

    s.onOsc("9;4;1;250"); // out-of-range percent clamps
    try std.testing.expectEqual(@as(u8, 100), Spy.progress.?.percent);

    s.onOsc("9;build done"); // plain message → notification
    try std.testing.expectEqual(@as(usize, 1), Spy.notified);

    s.onOsc("9;4;banana"); // malformed 4; → notification fallback
    try std.testing.expectEqual(@as(usize, 2), Spy.notified);

    s.onOsc("9;4;9;50"); // unknown state → notification fallback
    try std.testing.expectEqual(@as(usize, 3), Spy.notified);
}

test "XTGETTCAP: TN (Terminal Name) returns sketerm-256color" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();

    // Capture writePty output.
    const Spy = struct {
        var got: [256]u8 = undefined;
        var got_len: usize = 0;
        fn cb(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, got.len - got_len);
            @memcpy(got[got_len .. got_len + n], bytes[0..n]);
            got_len += n;
        }
    };
    Spy.got_len = 0;
    s.sink.on_write_pty = Spy.cb;

    // Hex of "TN" = 544E. Send DCS + q 544E ST.
    var body1 = "544E".*;
    s.onDcs(.{
        .proto = .{
            .params = [_]u16{0} ** 4,
            .n_params = 0,
            .intermediates = [_]u8{'+'} ++ [_]u8{0} ** 3,
            .n_intermediates = 1,
            .final = 'q',
        },
        .body = &body1,
    });
    // Should reply with `DCS 1 + r 544E=<hex of "sketerm-256color"> ST`.
    const resp = Spy.got[0..Spy.got_len];
    try std.testing.expect(std.mem.startsWith(u8, resp, "\x1bP1+r544E="));
    try std.testing.expect(std.mem.endsWith(u8, resp, "\x1b\\"));
    // Decoded value (between '=' and ST) must be hex of "sketerm-256color".
    const eq_idx = std.mem.indexOfScalar(u8, resp, '=').?;
    const hex_val = resp[eq_idx + 1 .. resp.len - 2];
    var decoded_buf: [64]u8 = undefined;
    const dn = Screen.hexDecode(hex_val, &decoded_buf).?;
    try std.testing.expectEqualStrings("sketerm-256color", decoded_buf[0..dn]);
}

test "XTGETTCAP: unknown cap replies with 0+r" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();
    const Spy = struct {
        var got: [256]u8 = undefined;
        var got_len: usize = 0;
        fn cb(_: ?*anyopaque, bytes: []const u8) void {
            const n = @min(bytes.len, got.len - got_len);
            @memcpy(got[got_len .. got_len + n], bytes[0..n]);
            got_len += n;
        }
    };
    Spy.got_len = 0;
    s.sink.on_write_pty = Spy.cb;

    // Hex of "ZZZ" = 5A5A5A. Unknown cap.
    var body2 = "5A5A5A".*;
    s.onDcs(.{
        .proto = .{
            .params = [_]u16{0} ** 4,
            .n_params = 0,
            .intermediates = [_]u8{'+'} ++ [_]u8{0} ** 3,
            .n_intermediates = 1,
            .final = 'q',
        },
        .body = &body2,
    });
    const resp = Spy.got[0..Spy.got_len];
    try std.testing.expectEqualStrings("\x1bP0+r5A5A5A\x1b\\", resp);
}

test "visualToLogicalCol on pure-ASCII line is identity" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();
    for ("hello") |b| s.printCp(b);
    try std.testing.expectEqual(@as(u16, 3), s.visualToLogicalCol(std.testing.allocator, 0, 3));
    try std.testing.expectEqual(@as(u16, 0), s.visualToLogicalCol(std.testing.allocator, 0, 0));
}

test "visualToLogicalCol/logicalToVisualCol round-trip on a packed-RTL row" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    // Row sized exactly to the 3 Hebrew characters — no trailing blanks
    // that would otherwise be swept into the RTL run by UAX #9.
    var s = try Screen.init(std.testing.allocator, &pool, 3, 1);
    defer s.deinit();
    s.printCp(0x05D0); // aleph at logical 0
    s.printCp(0x05D1); // bet
    s.printCp(0x05D2); // gimel
    // Round-trip every column.
    for (0..3) |lc| {
        const v = s.logicalToVisualCol(std.testing.allocator, 0, @intCast(lc));
        const back = s.visualToLogicalCol(std.testing.allocator, 0, v);
        try std.testing.expectEqual(@as(u16, @intCast(lc)), back);
    }
    // Aleph (logical 0) lands at visual 2 (rightmost).
    try std.testing.expectEqual(@as(u16, 2), s.logicalToVisualCol(std.testing.allocator, 0, 0));
}

test "REP after RIS does not replay stale" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();
    s.printCp('x');
    s.fullReset();
    var csi = Event.Csi{};
    csi.params[0] = 3;
    csi.n_params = 1;
    csi.final = 'b';
    s.csi(csi);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 0).rune);
}

test "search finds matches in active screen" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 3);
    defer s.deinit();
    for ("hello world hello") |b| s.printCp(b);

    const matches = try s.search(std.testing.allocator, "hello");
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(i32, 0), matches[0].row);
    try std.testing.expectEqual(@as(u32, 0), matches[0].col);
    try std.testing.expectEqual(@as(u32, 5), matches[0].len);
    try std.testing.expectEqual(@as(u32, 12), matches[1].col);
}

test "search case-insensitive matches across cases" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 30, 3);
    defer s.deinit();
    for ("Hello WORLD hello world") |b| s.printCp(b);

    // CS — only one match
    const cs = try s.searchOpts(std.testing.allocator, "hello", false);
    defer std.testing.allocator.free(cs);
    try std.testing.expectEqual(@as(usize, 1), cs.len);

    // CI — both Hello and hello
    const ci = try s.searchOpts(std.testing.allocator, "hello", true);
    defer std.testing.allocator.free(ci);
    try std.testing.expectEqual(@as(usize, 2), ci.len);
}

test "search returns empty for empty needle" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 3);
    defer s.deinit();
    for ("hello") |b| s.printCp(b);

    const matches = try s.search(std.testing.allocator, "");
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "search finds multibyte runes" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 3);
    defer s.deinit();
    s.printCp('é'); // U+00E9 → 2-byte UTF-8
    s.printCp('é');
    s.printCp('a');

    const matches = try s.search(std.testing.allocator, "é");
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(u32, 0), matches[0].col);
    try std.testing.expectEqual(@as(u32, 1), matches[1].col);
}

test "search wide CJK match: visual width spans both cells" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 1);
    defer s.deinit();
    // 中 = U+4E2D, wide. 文 = U+6587, wide. Each takes 2 columns.
    s.printCp(0x4E2D);
    s.printCp(0x6587);

    // "中" alone — len should be 2 (wide).
    const m1 = try s.search(std.testing.allocator, "\xE4\xB8\xAD");
    defer std.testing.allocator.free(m1);
    try std.testing.expectEqual(@as(usize, 1), m1.len);
    try std.testing.expectEqual(@as(u32, 0), m1[0].col);
    try std.testing.expectEqual(@as(u32, 2), m1[0].len);

    // "中文" — len should be 4 (two wide chars side-by-side).
    const m2 = try s.search(std.testing.allocator, "\xE4\xB8\xAD\xE6\x96\x87");
    defer std.testing.allocator.free(m2);
    try std.testing.expectEqual(@as(usize, 1), m2.len);
    try std.testing.expectEqual(@as(u32, 0), m2[0].col);
    try std.testing.expectEqual(@as(u32, 4), m2[0].len);
}

test "selectWordAt grabs full word" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 30, 1);
    defer s.deinit();
    for ("hello world.txt") |b| s.printCp(b);

    s.selectWordAt(0, 7); // mid 'world'
    const r = s.selection.rect().?;
    try std.testing.expectEqual(@as(i32, 0), r.top_row);
    try std.testing.expectEqual(@as(i32, 6), r.top_col);
    try std.testing.expectEqual(@as(i32, 15), r.bot_col); // 'world.txt' is 9 chars from 6, 6+9=15
}

test "selectWordAt on space selects single col" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 1);
    defer s.deinit();
    for ("a b c") |b| s.printCp(b);

    s.selectWordAt(0, 1); // the space
    const r = s.selection.rect().?;
    try std.testing.expectEqual(@as(i32, 1), r.top_col);
    try std.testing.expectEqual(@as(i32, 2), r.bot_col);
}

test "selectLineAt covers row" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 3);
    defer s.deinit();

    s.selectLineAt(1);
    const r = s.selection.rect().?;
    try std.testing.expectEqual(@as(i32, 1), r.top_row);
    try std.testing.expectEqual(@as(i32, 0), r.top_col);
    try std.testing.expectEqual(@as(i32, 1), r.bot_row);
    try std.testing.expectEqual(@as(i32, 20), r.bot_col);
}

test "rectangular selection extracts column block" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 3);
    defer s.deinit();
    for ("foo bar") |b| s.printCp(b);
    s.printCp('\n');
    s.col = 0;
    s.row = 1;
    for ("baz qux") |b| s.printCp(b);
    s.printCp('\n');
    s.col = 0;
    s.row = 2;
    for ("hi  yo") |b| s.printCp(b);

    // Cols 4..7 across rows 0..2 should yield "bar\nqux\nyo "
    s.selection.start(0, 4, .rectangular);
    s.selection.extend(2, 7);
    const text = try s.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("bar\nqux\nyo ", text);
}

test "searchOptsRegex finds POSIX ERE matches" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 30, 2);
    defer s.deinit();

    for ("abc 123 xyz") |b| s.printCp(b);
    s.apply(.{ .execute = '\n' });
    s.apply(.{ .execute = '\r' });
    for ("foo 456 bar") |b| s.printCp(b);

    const matches = try s.searchOptsRegex(std.testing.allocator, "[0-9]+", false);
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(u32, 4), matches[0].col);
    try std.testing.expectEqual(@as(u32, 3), matches[0].len);
    try std.testing.expectEqual(@as(u32, 4), matches[1].col);
    try std.testing.expectEqual(@as(u32, 3), matches[1].len);
}

test "searchOptsRegex invalid pattern returns empty silently" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 1);
    defer s.deinit();
    for ("hello") |b| s.printCp(b);

    const matches = try s.searchOptsRegex(std.testing.allocator, "[unclosed", false);
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "extractScrollback walks scrollback + active, joins soft-wraps" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 2);
    defer s.deinit();

    // Print enough to push content into scrollback. Width=5 so
    // "abcdefg" wraps: "abcde" then "fg".
    for ("abcdefg") |b| s.printCp(b);
    s.apply(.{ .execute = '\n' });
    s.apply(.{ .execute = '\r' });
    for ("hello") |b| s.printCp(b);
    s.apply(.{ .execute = '\n' });
    s.apply(.{ .execute = '\r' });
    for ("world") |b| s.printCp(b);

    const text = try s.extractScrollback(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // "abcde" soft-wrapped to "fg" → joined "abcdefg\n", then
    // "hello\n" + "world\n".
    try std.testing.expectEqualStrings("abcdefg\nhello\nworld\n", text);
}

test "extractScreen captures all visible rows + trims trailing blanks" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();

    for ("hello") |b| s.printCp(b);
    s.apply(.{ .execute = '\n' });
    s.apply(.{ .execute = '\r' });
    for ("world") |b| s.printCp(b);

    const text = try s.extractScreen(std.testing.allocator);
    defer std.testing.allocator.free(text);
    // Row 0: "hello" + newline. Row 1: "world" + newline. Row 2: blank
    // line still emits a newline so paragraph shape is preserved.
    try std.testing.expectEqualStrings("hello\nworld\n\n", text);
}

test "extractSelection emits OSC 8 as markdown link" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 30, 1);
    defer s.deinit();

    // OSC 8 ; ; https://example.com BEL <link text> OSC 8 ; ; BEL
    s.onOsc("8;;https://example.com");
    for ("link") |b| s.printCp(b);
    s.onOsc("8;;");
    for (" tail") |b| s.printCp(b);

    s.selection.start(0, 0, .normal);
    s.selection.extend(0, 9); // "link tail"
    const text = try s.extractSelection(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[link](https://example.com) tail", text);
}

/// `CSI > flags u`, the sequence every kitty-protocol application
/// uses to turn the protocol on.
fn kittyKbdPushCsi(s: *Screen, flags: u16) void {
    var csi = Event.Csi{};
    csi.private = '>';
    csi.params[0] = flags;
    csi.n_params = 1;
    csi.final = 'u';
    s.csi(csi);
}

fn kittyKbdPopCsi(s: *Screen, n: u16) void {
    var csi = Event.Csi{};
    csi.private = '<';
    csi.params[0] = n;
    csi.n_params = 1;
    csi.final = 'u';
    s.csi(csi);
}

fn kittyKbdSetCsi(s: *Screen, flags: u16, mode: u16) void {
    var csi = Event.Csi{};
    csi.private = '=';
    csi.params[0] = flags;
    csi.params[1] = mode;
    csi.n_params = 2;
    csi.final = 'u';
    s.csi(csi);
}

test "kitty kbd: CSI > N u pushes so CSI < N u restores the caller's flags" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    // A shell has the protocol on; a program it launches turns on
    // more, then puts things back the way it found them.
    kittyKbdPushCsi(s, 0x01);
    try std.testing.expectEqual(@as(u8, 0x01), s.kitty_kbd_flags);
    kittyKbdPushCsi(s, 0x0F);
    try std.testing.expectEqual(@as(u8, 0x0F), s.kitty_kbd_flags);
    kittyKbdPopCsi(s, 1);
    try std.testing.expectEqual(@as(u8, 0x01), s.kitty_kbd_flags);
}

test "kitty kbd: CSI = N ; M u sets, ors and clears without touching the stack" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    kittyKbdPushCsi(s, 0x01);
    kittyKbdSetCsi(s, 0x0A, 2); // set these bits, leave the rest
    try std.testing.expectEqual(@as(u8, 0x0B), s.kitty_kbd_flags);
    kittyKbdSetCsi(s, 0x02, 3); // clear these bits
    try std.testing.expectEqual(@as(u8, 0x09), s.kitty_kbd_flags);
    kittyKbdSetCsi(s, 0x04, 1); // assign
    try std.testing.expectEqual(@as(u8, 0x04), s.kitty_kbd_flags);
    try std.testing.expectEqual(@as(u8, 1), s.kitty_kbd_depth);
    kittyKbdPopCsi(s, 1);
    try std.testing.expectEqual(@as(u8, 0), s.kitty_kbd_flags);
}

test "kitty kbd: popping an empty stack disables the protocol" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    kittyKbdSetCsi(s, 0x0F, 1);
    kittyKbdPopCsi(s, 3);
    try std.testing.expectEqual(@as(u8, 0), s.kitty_kbd_flags);
    try std.testing.expectEqual(@as(u8, 0), s.kitty_kbd_depth);
}

test "kitty kbd: a full stack drops its oldest entry" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    // Ten pushes into a nine-deep stack: the first is forgotten, the
    // rest still unwind in order.
    var i: u16 = 1;
    while (i <= 10) : (i += 1) kittyKbdPushCsi(s, i);
    try std.testing.expectEqual(@as(u8, 9), s.kitty_kbd_depth);
    try std.testing.expectEqual(@as(u8, 10), s.kitty_kbd_flags);
    kittyKbdPopCsi(s, 1);
    try std.testing.expectEqual(@as(u8, 9), s.kitty_kbd_flags);
}

test "kitty kbd: the alternate screen keeps its own flags" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    kittyKbdPushCsi(s, 0x01); // the shell's flags
    var alt = Event.Csi{};
    alt.private = '?';
    alt.params[0] = 1049;
    alt.n_params = 1;
    alt.final = 'h';
    s.csi(alt);
    try std.testing.expectEqual(@as(u8, 0), s.kitty_kbd_flags);
    kittyKbdPushCsi(s, 0x1F); // a full-screen application's
    alt.final = 'l';
    s.csi(alt);
    // Back on the main screen the shell's flags are exactly as it
    // left them, whether or not the application cleaned up.
    try std.testing.expectEqual(@as(u8, 0x01), s.kitty_kbd_flags);
}

test "kitty kbd: CSI ? u query replies" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.kitty_kbd_flags = 0x05;
    const Recv = struct {
        var got: [32]u8 = undefined;
        var got_len: usize = 0;
        fn cb(_: ?*anyopaque, b: []const u8) void {
            const n = @min(b.len, got.len);
            @memcpy(got[0..n], b[0..n]);
            got_len = n;
        }
    };
    Recv.got_len = 0;
    s.sink = .{ .on_write_pty = Recv.cb };
    var q = Event.Csi{};
    q.private = '?';
    q.final = 'u';
    s.csi(q);
    try std.testing.expectEqualStrings("\x1b[?5u", Recv.got[0..Recv.got_len]);
}

test "DECDWL ESC #6 sets line scaling to dwl" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.row = 1;
    var ef = Event.EscFinal{};
    ef.intermediates[0] = '#';
    ef.n_intermediates = 1;
    ef.final = '6';
    s.escFinal(ef);
    try std.testing.expectEqual(@import("line.zig").Scaling.dwl, s.active[1].scaling);
}

test "DECDHL top + bottom on consecutive lines" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.row = 0;
    var top = Event.EscFinal{};
    top.intermediates[0] = '#';
    top.n_intermediates = 1;
    top.final = '3';
    s.escFinal(top);
    s.row = 1;
    var bot = Event.EscFinal{};
    bot.intermediates[0] = '#';
    bot.n_intermediates = 1;
    bot.final = '4';
    s.escFinal(bot);
    try std.testing.expectEqual(@import("line.zig").Scaling.dhl_top, s.active[0].scaling);
    try std.testing.expectEqual(@import("line.zig").Scaling.dhl_bot, s.active[1].scaling);
}

test "DECSWL ESC #5 resets scaling" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.active[0].scaling = .dwl;
    s.row = 0;
    var ef = Event.EscFinal{};
    ef.intermediates[0] = '#';
    ef.n_intermediates = 1;
    ef.final = '5';
    s.escFinal(ef);
    try std.testing.expectEqual(@import("line.zig").Scaling.single, s.active[0].scaling);
}

test "DECSCNM (CSI ?5 h/l) toggles reverse_screen" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    var on = Event.Csi{};
    on.private = '?';
    on.params[0] = 5;
    on.n_params = 1;
    on.final = 'h';
    s.csi(on);
    try std.testing.expect(s.reverse_screen);
    var off = Event.Csi{};
    off.private = '?';
    off.params[0] = 5;
    off.n_params = 1;
    off.final = 'l';
    s.csi(off);
    try std.testing.expect(!s.reverse_screen);
}

test "DECSET 40 + DECSET 3 widens to 132 columns" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 80, 24);
    defer s.deinit();
    // Without DECSET 40, DECSET 3 is a no-op.
    var col_set = Event.Csi{};
    col_set.private = '?';
    col_set.params[0] = 3;
    col_set.n_params = 1;
    col_set.final = 'h';
    s.csi(col_set);
    try std.testing.expectEqual(@as(u16, 80), s.cols);
    // Enable + retry.
    var allow = Event.Csi{};
    allow.private = '?';
    allow.params[0] = 40;
    allow.n_params = 1;
    allow.final = 'h';
    s.csi(allow);
    s.csi(col_set);
    try std.testing.expectEqual(@as(u16, 132), s.cols);
    // Reset returns to 80.
    var col_rst = Event.Csi{};
    col_rst.private = '?';
    col_rst.params[0] = 3;
    col_rst.n_params = 1;
    col_rst.final = 'l';
    s.csi(col_rst);
    try std.testing.expectEqual(@as(u16, 80), s.cols);
}

test "DECRST 2 fires on_decanm with ansi=false" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    const Spy = struct {
        var got_calls: u8 = 0;
        var last_ansi: bool = true;
        fn cb(_: ?*anyopaque, ansi: bool) void {
            got_calls += 1;
            last_ansi = ansi;
        }
    };
    Spy.got_calls = 0;
    s.sink = .{ .on_decanm = Spy.cb };
    var off = Event.Csi{};
    off.private = '?';
    off.params[0] = 2;
    off.n_params = 1;
    off.final = 'l';
    s.csi(off);
    try std.testing.expectEqual(@as(u8, 1), Spy.got_calls);
    try std.testing.expectEqual(false, Spy.last_ansi);
}

test "style pool compaction recovers from exhaustion (ghost-text dim bug)" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 4, 1);
    defer s.deinit();

    // A live cell on a non-default bold style — must survive compaction
    // with its appearance intact.
    var bold = Event.Csi{};
    bold.params[0] = 1;
    bold.n_params = 1;
    bold.final = 'm';
    s.csi(bold);
    s.printCp('A');
    const a_style_before = s.cellAt(0, 0).style_ref;
    try std.testing.expect(pool.get(a_style_before).attrs.bold);

    // Exhaust the 64K index space with distinct truecolor entries so
    // the next intern would overflow (the real-world trigger: a long
    // truecolor TUI session).
    var n: u32 = 0;
    while (n < 0x10000) : (n += 1) {
        _ = pool.intern(.{ .fg = .{ .rgb = .{
            .r = @intCast(n & 0xFF),
            .g = @intCast((n >> 8) & 0xFF),
            .b = @intCast(n >> 16 & 0xFF),
        } } }) catch break;
    }
    try std.testing.expect(pool.entries.items.len >= 0xFFFF);

    // The bug: without compaction, this `\e[2m` (dim) silently keeps
    // the previous cur_style, so ghost text renders bright + stale.
    var dim = Event.Csi{};
    dim.params[0] = 2;
    dim.n_params = 1;
    dim.final = 'm';
    s.csi(dim);

    // cur_style must now genuinely be a dim style, and the pool must
    // have shrunk (dead truecolor entries reclaimed).
    try std.testing.expect(pool.get(s.cur_style).attrs.dim);
    try std.testing.expect(pool.entries.items.len < 0xFFFF);

    // The pre-existing 'A' cell still renders bold after the
    // style_ref remap.
    try std.testing.expectEqual(@as(u32, 'A'), s.cellAt(0, 0).rune);
    try std.testing.expect(pool.get(s.cellAt(0, 0).style_ref).attrs.bold);

    // Newly printed dim text actually carries dim.
    s.printCp('B');
    try std.testing.expect(pool.get(s.cellAt(0, 1).style_ref).attrs.dim);
}

test "ED 2 clears the cluster side-table" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp('e');
    s.printCp(0x0301); // combining acute -> cluster at (0,0)
    try std.testing.expectEqual(@as(usize, 1), s.clusterAt(0, 0).len);
    s.eraseDisplay(2);
    try std.testing.expectEqual(@as(usize, 0), s.clusterAt(0, 0).len);
    try std.testing.expectEqual(@as(usize, 0), s.clusters.count());
}

test "EL 0 clears clusters from cursor to end of line" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp('a');
    s.printCp(0x0301);
    s.printCp('b');
    s.printCp(0x0301);
    try std.testing.expectEqual(@as(usize, 2), s.clusters.count());
    s.col = 1;
    s.eraseLine(0);
    try std.testing.expectEqual(@as(usize, 1), s.clusterAt(0, 0).len);
    try std.testing.expectEqual(@as(usize, 0), s.clusterAt(0, 1).len);
}

test "alt-screen toggle drops clusters keyed to the old buffer" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp('e');
    s.printCp(0x0301);
    s.toggleAltScreen(true);
    try std.testing.expectEqual(@as(usize, 0), s.clusters.count());
    s.toggleAltScreen(false);
    try std.testing.expectEqual(@as(usize, 0), s.clusters.count());
}

test "narrow overwrite of wide-left blanks the continuation cell" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp(0x4E2D); // CJK, occupies cols 0-1
    try std.testing.expect(s.cellAt(0, 0).flags & 0b0000_0001 != 0);
    try std.testing.expect(s.cellAt(0, 1).flags & 0b0000_0010 != 0);
    s.row = 0;
    s.col = 0;
    s.printCp('a');
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 0).rune);
    // The orphaned continuation must be a plain blank, not is_wide_cont.
    try std.testing.expectEqual(@as(u8, 0), s.cellAt(0, 1).flags);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 1).rune);
}

test "narrow overwrite of wide continuation blanks the orphan wide-left" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp(0x4E2D); // cols 0-1
    s.row = 0;
    s.col = 1;
    s.printCp('a');
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 1).rune);
    try std.testing.expectEqual(@as(u8, 0), s.cellAt(0, 0).flags);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 0).rune);
}

test "fast ASCII path splits a straddled wide pair" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp(0x4E2D); // cols 0-1
    s.printCp(0x56FD); // cols 2-3
    s.row = 0;
    s.col = 1;
    s.fastAsciiSlice("xy"); // overwrites cols 1-2
    try std.testing.expectEqual(@as(u8, 0), s.cellAt(0, 0).flags); // old wide-left blanked
    try std.testing.expectEqual(@as(u32, 'x'), s.cellAt(0, 1).rune);
    try std.testing.expectEqual(@as(u32, 'y'), s.cellAt(0, 2).rune);
    try std.testing.expectEqual(@as(u8, 0), s.cellAt(0, 3).flags); // old continuation blanked
}

test "ECH with huge parameter does not overflow column math" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp('a');
    s.printCp('b');
    s.col = 1;
    var ech = Event.Csi{};
    ech.params[0] = 65535; // col + n would wrap u16
    ech.n_params = 1;
    ech.final = 'X';
    s.csi(ech);
    try std.testing.expectEqual(@as(u32, 'a'), s.cellAt(0, 0).rune);
    try std.testing.expectEqual(@as(u32, 0), s.cellAt(0, 1).rune);
}

test "scroll within region preserves DECDWL scaling of shifted lines" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 4);
    defer s.deinit();
    s.active[2].scaling = .dwl;
    s.scrollUp(1);
    try std.testing.expectEqual(@import("line.zig").Scaling.dwl, s.active[1].scaling);
    // The recycled bottom row must come back as single-width.
    try std.testing.expectEqual(@import("line.zig").Scaling.single, s.active[3].scaling);
}

test "DCH clears clusters on the shifted row" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.printCp('a');
    s.printCp('e');
    s.printCp(0x0301); // cluster at (0,1)
    try std.testing.expectEqual(@as(usize, 1), s.clusters.count());
    s.col = 0;
    s.deleteChars(1); // 'e' shifts to col 0; old cluster key is stale
    try std.testing.expectEqual(@as(usize, 0), s.clusters.count());
}

test "SGR 58 semicolon truecolor sets underline color; 59 resets" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    var sgr_ev = Event.Csi{};
    sgr_ev.final = 'm';
    sgr_ev.n_params = 6;
    sgr_ev.params[0] = 4; // underline on
    sgr_ev.params[1] = 58;
    sgr_ev.params[2] = 2;
    sgr_ev.params[3] = 255;
    sgr_ev.params[4] = 0;
    sgr_ev.params[5] = 128;
    s.csi(sgr_ev);
    const e = pool.get(s.cur_style);
    try std.testing.expect(e.attrs.underline);
    try std.testing.expectEqual(@as(u8, 255), e.underline_color.rgb.r);
    try std.testing.expectEqual(@as(u8, 0), e.underline_color.rgb.g);
    try std.testing.expectEqual(@as(u8, 128), e.underline_color.rgb.b);

    var off = Event.Csi{};
    off.final = 'm';
    off.n_params = 1;
    off.params[0] = 59;
    s.csi(off);
    try std.testing.expect(pool.get(s.cur_style).underline_color == .default);
}

test "SGR 58 colon form with colorspace slot (58:2::r:g:b)" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    var ev = Event.Csi{};
    ev.final = 'm';
    ev.n_params = 7;
    ev.params[0] = 58;
    ev.params[1] = 2; // sub
    ev.params[2] = 0; // empty colorspace, sub
    ev.params[3] = 10; // r, sub
    ev.params[4] = 20; // g, sub
    ev.params[5] = 30; // b, sub
    ev.params[6] = 1; // separate SGR: bold
    var k: usize = 1;
    while (k <= 5) : (k += 1) ev.setSub(k, true);
    s.csi(ev);
    const e = pool.get(s.cur_style);
    try std.testing.expectEqual(@as(u8, 10), e.underline_color.rgb.r);
    try std.testing.expectEqual(@as(u8, 20), e.underline_color.rgb.g);
    try std.testing.expectEqual(@as(u8, 30), e.underline_color.rgb.b);
    try std.testing.expect(e.attrs.bold);
}

test "SGR 58 palette form (58:5:n)" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    var ev = Event.Csi{};
    ev.final = 'm';
    ev.n_params = 3;
    ev.params[0] = 58;
    ev.params[1] = 5;
    ev.params[2] = 196;
    ev.setSub(1, true);
    ev.setSub(2, true);
    s.csi(ev);
    try std.testing.expectEqual(@as(u8, 196), pool.get(s.cur_style).underline_color.palette);
}

const OscCapture = struct {
    var buf: [256]u8 = undefined;
    var len: usize = 0;
    fn write(_: ?*anyopaque, bytes: []const u8) void {
        const n = @min(bytes.len, buf.len - len);
        @memcpy(buf[len .. len + n], bytes[0..n]);
        len += n;
    }
    fn reset() void {
        len = 0;
    }
    fn got() []const u8 {
        return buf[0..len];
    }
};

test "OSC 17/19 set + 117/119 reset selection colors" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();

    s.onOsc("17;rgb:ffff/0000/0000"); // selection bg = red
    try std.testing.expectEqual(@as(f32, 1.0), s.selection_bg[0]);
    try std.testing.expectEqual(@as(f32, 1.0), s.selection_bg[3]); // opaque sentinel set

    s.onOsc("19;#00ff00"); // selection fg = green
    try std.testing.expectEqual(@as(f32, 1.0), s.selection_fg[1]);

    s.onOsc("117"); // reset bg → unset sentinel
    try std.testing.expectEqual(@as(f32, 0.0), s.selection_bg[3]);
    s.onOsc("119");
    try std.testing.expectEqual(@as(f32, 0.0), s.selection_fg[3]);
}

test "OSC 17 query replies with current selection bg" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    s.sink = .{ .on_write_pty = OscCapture.write };

    s.onOsc("17;rgb:ffff/0000/0000");
    OscCapture.reset();
    s.onOsc("17;?");
    try std.testing.expectEqualStrings("\x1b]17;rgb:ffff/0000/0000\x1b\\", OscCapture.got());
}

test "OSC 1337 SetUserVar stores, overwrites and clears" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();

    // base64("hello") = aGVsbG8=
    s.onOsc("1337;SetUserVar=greeting=aGVsbG8=");
    try std.testing.expectEqualStrings("hello", s.userVar("greeting").?);

    // base64("bye") = Ynll
    s.onOsc("1337;SetUserVar=greeting=Ynll");
    try std.testing.expectEqualStrings("bye", s.userVar("greeting").?);

    // Empty value clears.
    s.onOsc("1337;SetUserVar=greeting=");
    try std.testing.expect(s.userVar("greeting") == null);
}

test "OSC 1337 ReportCellSize replies with pixel dims" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    s.sink = .{ .on_write_pty = OscCapture.write };
    s.cell_pixel_w = 9;
    s.cell_pixel_h = 18;

    OscCapture.reset();
    s.onOsc("1337;ReportCellSize");
    try std.testing.expectEqualStrings("\x1b]1337;ReportCellSize=18;9;1.0\x1b\\", OscCapture.got());
}

test "OSC 9;9 reports cwd" {
    const Sink = struct {
        var seen: [256]u8 = undefined;
        var seen_len: usize = 0;
        fn cwd(_: ?*anyopaque, path: []const u8) void {
            @memcpy(seen[0..path.len], path);
            seen_len = path.len;
        }
    };
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    s.sink = .{ .on_cwd = Sink.cwd };

    Sink.seen_len = 0;
    s.onOsc("9;9;/home/user/project");
    try std.testing.expectEqualStrings("/home/user/project", Sink.seen[0..Sink.seen_len]);
}

test "OSC 633 D records a command zone like 133" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 4);
    defer s.deinit();

    s.onOsc("633;C"); // output start
    try std.testing.expect(s.pending_output_start_id != 0);
    const start = s.pending_output_start_id;
    s.onOsc("633;D;0"); // command finished, exit 0
    try std.testing.expectEqual(start, s.last_output_start_id);
    try std.testing.expectEqual(@as(i32, 0), s.last_cmd_exit);
}

test "OSC 21 query + set" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    s.sink = .{ .on_write_pty = OscCapture.write };

    // Set background to black, then query it back.
    s.onOsc("21;background=#000000");
    try std.testing.expectEqual(@as(f32, 0.0), s.default_bg[0]);

    OscCapture.reset();
    s.onOsc("21;background=?");
    try std.testing.expectEqualStrings("\x1b]21;background=rgb:0000/0000/0000\x1b\\", OscCapture.got());
}

test "imageRowForAnchor tracks a line through scroll, scrollback and eviction" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 8, 5);
    defer s.deinit();
    s.scrollback_capacity = 50;

    // Anchor to the line currently at row 2 (id assigned at init).
    const id = s.buf()[2].id;
    try std.testing.expect(id != 0);

    const Row = struct {
        fn expectVisible(scr: *Screen, anchor: u64, want: i32) !void {
            switch (scr.imageRowForAnchor(anchor)) {
                .visible => |r| try std.testing.expectEqual(want, r),
                else => return error.NotVisible,
            }
        }
    };

    // While the line stays in the active buffer it tracks up row by row.
    // (scrollUp(n) caps n at the region height, so scroll one line at a
    // time — exactly how lineFeed drives it.)
    try Row.expectVisible(s, id, 2);
    s.scrollUp(1);
    try Row.expectVisible(s, id, 1);
    s.scrollUp(1);
    try Row.expectVisible(s, id, 0);

    // Scroll it deep into scrollback (well past one screen height). It
    // landed at scrollback index 2 (pushed 3rd). With no view offset it
    // is off-screen but still alive.
    for (0..15) |_| s.scrollUp(1);
    try std.testing.expectEqual(Screen.ImageRow.offscreen, s.imageRowForAnchor(id));

    // Offsetting the view to bring index 2 to the top row shows it again.
    const sb_count: u32 = @intCast(s.scrollback.items.len);
    s.view_offset = sb_count - 2;
    try Row.expectVisible(s, id, 0);
    s.view_offset = 0;

    // Push past the 50-line ring so the anchor line is evicted entirely.
    for (0..60) |_| s.scrollUp(1);
    try std.testing.expectEqual(Screen.ImageRow.evicted, s.imageRowForAnchor(id));
}

test "emitImage stamps an anchor id from the placement row" {
    const Sink = struct {
        var anchor: u64 = 0;
        var fired: bool = false;
        fn img(_: ?*anyopaque, ev: Screen.ImageEvent) void {
            anchor = ev.anchor_id;
            fired = true;
        }
    };
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 8, 5);
    defer s.deinit();
    s.sink = .{ .on_image = Sink.img };
    s.row = 3;

    Sink.fired = false;
    const px = [_]u8{ 0, 0, 0, 0 };
    s.emitImage(.{ .width = 1, .height = 1, .rgba = &px, .row = 3, .col = 0 });
    try std.testing.expect(Sink.fired);
    try std.testing.expectEqual(s.buf()[3].id, Sink.anchor);
}

test "contentHash detects visible change, ignores identical repaint" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 20, 4);
    defer s.deinit();

    const h0 = s.contentHash();

    // Print "hi" — visible change → hash differs.
    s.apply(.{ .print = 'h' });
    s.apply(.{ .print = 'i' });
    const h1 = s.contentHash();
    try std.testing.expect(h1 != h0);

    // Repaint the exact same thing at the same spot: home the cursor and
    // print "hi" again. No visible change → hash returns to h1.
    s.apply(.{
        .csi = blk: {
            var ev = Event.Csi{};
            ev.final = 'H'; // CUP → row1,col1
            break :blk ev;
        },
    });
    s.apply(.{ .print = 'h' });
    s.apply(.{ .print = 'i' });
    try std.testing.expectEqual(h1, s.contentHash());

    // Change one cell → hash differs again.
    s.apply(.{ .csi = blk: {
        var ev = Event.Csi{};
        ev.final = 'H';
        break :blk ev;
    } });
    s.apply(.{ .print = 'H' }); // 'H' instead of 'h'
    try std.testing.expect(s.contentHash() != h1);
}

test "next_line_id advances on scroll, not on in-place print" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();

    // Printing into an existing (blank) row births no new line — the
    // activity drain would fall through to the content hash.
    const before_print = s.next_line_id;
    s.apply(.{ .print = 'x' });
    try std.testing.expectEqual(before_print, s.next_line_id);

    // Scrolling births new lines — the activity drain can short-circuit
    // (definite visible change) without hashing.
    const before_scroll = s.next_line_id;
    s.scrollUp(1);
    try std.testing.expect(s.next_line_id > before_scroll);
}

test "OSC 1337 SetProfile fires sink" {
    const Sink = struct {
        var name: [64]u8 = undefined;
        var name_len: usize = 0;
        fn setProfile(_: ?*anyopaque, n: []const u8) void {
            @memcpy(name[0..n.len], n);
            name_len = n.len;
        }
    };
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    s.sink = .{ .on_set_profile = Sink.setProfile };

    Sink.name_len = 0;
    s.onOsc("1337;SetProfile=Solarized");
    try std.testing.expectEqualStrings("Solarized", Sink.name[0..Sink.name_len]);
}

test "SGR 38 colon form with colorspace slot still parses fg" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 2);
    defer s.deinit();
    var ev = Event.Csi{};
    ev.final = 'm';
    ev.n_params = 6;
    ev.params[0] = 38;
    ev.params[1] = 2;
    ev.params[2] = 0; // colorspace
    ev.params[3] = 1;
    ev.params[4] = 2;
    ev.params[5] = 3;
    var k: usize = 1;
    while (k <= 5) : (k += 1) ev.setSub(k, true);
    s.csi(ev);
    const e = pool.get(s.cur_style);
    try std.testing.expectEqual(@as(u8, 1), e.fg.rgb.r);
    try std.testing.expectEqual(@as(u8, 2), e.fg.rgb.g);
    try std.testing.expectEqual(@as(u8, 3), e.fg.rgb.b);
}

test "OSC 133 C/D fire cmd start/end sinks with exit code" {
    const TestSink = struct {
        var starts: u32 = 0;
        var ends: u32 = 0;
        var last_exit: i32 = -1;
        fn cmdStart(_: ?*anyopaque) void {
            starts += 1;
        }
        fn cmdEnd(_: ?*anyopaque, exit: i32) void {
            ends += 1;
            last_exit = exit;
        }
    };
    TestSink.starts = 0;
    TestSink.ends = 0;

    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 10, 3);
    defer s.deinit();
    s.sink = .{ .on_cmd_start = TestSink.cmdStart, .on_cmd_end = TestSink.cmdEnd };

    // D with no open zone (attach mid-command): dropped, no callback.
    s.onOsc("133;D;9");
    try std.testing.expectEqual(@as(u32, 0), TestSink.ends);

    s.onOsc("133;C");
    try std.testing.expectEqual(@as(u32, 1), TestSink.starts);
    s.onOsc("133;D;3");
    try std.testing.expectEqual(@as(u32, 1), TestSink.ends);
    try std.testing.expectEqual(@as(i32, 3), TestSink.last_exit);

    // Bare D (no exit field) reports 0; OSC 633 dialect works too.
    s.onOsc("633;C");
    s.onOsc("633;D");
    try std.testing.expectEqual(@as(u32, 2), TestSink.ends);
    try std.testing.expectEqual(@as(i32, 0), TestSink.last_exit);
}

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
    scrollback: std.ArrayList(Line) = .{},
    scrollback_head: usize = 0,
    scrollback_capacity: usize = 10_000,
    /// Rendering offset (0 = bottom, > 0 = scrolled up by N lines).
    view_offset: u32 = 0,
    /// When true, any output (printCp / scrollUp / lineFeed) snaps
    /// view_offset back to 0. Off by default — matches xterm.
    /// Mirrors gnome-terminal's "scroll on output" toggle.
    scroll_on_output: bool = false,
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

    /// Scrollback search results — when non-empty, the renderer
    /// overlays a translucent highlight on every match. The Window
    /// owns the SearchMatch buffer separately for navigation; this
    /// view is just for rendering. `search_active_idx` is the index
    /// of the currently-selected match (rendered brighter).
    search_highlights: []const SearchMatch = &.{},
    search_active_idx: i32 = -1,

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

    /// Default fg / bg / cursor color overrides, RGBA in 0..1.
    /// Set via OSC 10 / 11 / 12, reset via OSC 110 / 111 / 112.
    /// Renderer syncs from these. cursor_color all-zero = use fg.
    default_fg: [4]f32 = .{ 0.92, 0.92, 0.92, 1.0 },
    default_bg: [4]f32 = .{ 0.10, 0.10, 0.10, 1.0 },
    cursor_color: [4]f32 = .{ 0, 0, 0, 0 },

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
    /// 0x10 associated-text. Toggled via CSI > N u (set), CSI = N;M u
    /// (set/push/pop), CSI < N u (pop). Stack depth 9.
    kitty_kbd_flags: u8 = 0,
    kitty_kbd_stack: [9]u8 = [_]u8{0} ** 9,
    kitty_kbd_depth: u8 = 0,

    /// Custom tab stops. One bool per column, true = stop set.
    /// Default: every 8th column starting at 0.
    tab_stops: std.ArrayList(bool) = .{},

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
        on_notification: ?*const fn (ctx: ?*anyopaque, title: []const u8, body: []const u8) void = null,
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
    };

    pub const ImageDeleteEvent = struct {
        /// 0 = delete-all-images. Otherwise the specific image.
        image_id: u32 = 0,
        /// 0 = any placement of the image. Otherwise specific.
        placement_id: u32 = 0,
        /// 'a'=all, 'i'=intersect cursor, 'p'=specific placement,
        /// 'r'=z-range. Lowercase = leave data on disk; uppercase
        /// = also free data. We don't distinguish on free behaviour.
        what: u8 = 'a',
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
    };

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
            .next_line_id = id_counter,
        };
        try self.resetTabStops();
        return self;
    }

    pub fn deinit(self: *Screen) void {
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
        const gop = self.clusters.getOrPut(key) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.append(self.allocator, cp) catch {};
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
    fn clearAllClusters(self: *Screen) void {
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
    fn clearClustersRange(self: *Screen, row: u16, lo: u16, hi: u16) void {
        var c = lo;
        while (c < hi) : (c += 1) self.clearClusterAt(row, c);
    }

    /// Public wrapper for the wide-char predicate used by the
    /// renderer when laying out preedit text.
    pub fn isWide(cp: u32) bool {
        return isWideCp(cp);
    }

    /// Word-class membership for double-click word selection.
    /// Mirrors xterm's default: ASCII alnum, underscore, plus a small
    /// "extra" set commonly considered part of paths/URIs.
    fn isWordChar(self: *const Screen, cp: u32) bool {
        if (cp == ' ' or cp == 0) return false;
        if (cp >= 'a' and cp <= 'z') return true;
        if (cp >= 'A' and cp <= 'Z') return true;
        if (cp >= '0' and cp <= '9') return true;
        if (cp >= 0x80) return true; // any non-ASCII codepoint
        // ASCII punctuation: consult the per-screen word_chars set.
        for (self.word_chars) |b| if (b == cp) return true;
        return false;
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
    fn nextLineId(self: *Screen) u64 {
        const id = self.next_line_id;
        self.next_line_id += 1;
        return id;
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
            try self.reflowMain(new_cols, new_rows);
        } else {
            try resizeBuffer(self.allocator, &self.active, self.rows, new_cols, new_rows, !self.use_alt, self);
        }
        if (self.alt) |alt_buf| {
            var alt_mut = alt_buf;
            try resizeBuffer(self.allocator, &alt_mut, self.rows, new_cols, new_rows, false, self);
            self.alt = alt_mut;
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
        var combined: std.ArrayList(Line) = .{};
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
                self.pushScrollback(row.cells, row.id);
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
            if (ln.cells.len == new_cols) continue;
            const new_cells = try allocator.alloc(Cell, new_cols);
            @memset(new_cells, .{});
            const n = @min(ln.cells.len, @as(usize, new_cols));
            @memcpy(new_cells[0..n], ln.cells[0..n]);
            if (ln.cells.len > 0) allocator.free(ln.cells);
            ln.cells = new_cells;
            ln.dirty = true;
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
                    if (copy) |cells| screen.pushScrollback(cells, slot.*[i].id);
                }
                slot.*[i].deinit(allocator);
            }
            std.mem.copyForwards(Line, slot.*[0..new_rows], slot.*[drop..]);
            const new_buf = try allocator.realloc(slot.*, new_rows);
            slot.* = new_buf;
        }
    }

    /// Push a line into scrollback. Caller transfers ownership of
    /// the cells slice. When at capacity, the evicted oldest cells
    /// buffer is RETURNED rather than freed — caller can reuse it as
    /// the new bottom-row cells (one alloc + one free saved per
    /// scroll on the hot path). Returns null when no eviction
    /// happened (pre-cap fill).
    fn pushScrollbackTakeOld(self: *Screen, cells: []Cell, line_id: u64) ?[]Cell {
        const cap = self.scrollback_capacity;
        if (self.scrollback.items.len < cap) {
            // Pre-allocate the full ring on first push to avoid the
            // growth-realloc chain (~14 grows from empty to 10k).
            if (self.scrollback.capacity == 0 and cap > 0) {
                self.scrollback.ensureTotalCapacity(self.allocator, cap) catch {
                    // Fall back to incremental growth.
                };
            }
            self.scrollback.append(self.allocator, .{ .cells = cells, .id = line_id }) catch {
                self.allocator.free(cells);
            };
            return null;
        }
        const head = self.scrollback_head;
        const old_cells = self.scrollback.items[head].cells;
        self.scrollback.items[head] = .{ .cells = cells, .id = line_id };
        self.scrollback_head = (head + 1) % cap;
        return old_cells;
    }

    /// Push helper that frees the evicted cells. Used when the caller
    /// can't reuse the buffer (e.g. width changed during reflow).
    fn pushScrollback(self: *Screen, cells: []Cell, line_id: u64) void {
        if (self.pushScrollbackTakeOld(cells, line_id)) |old_cells| {
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
        if (len == 0) unreachable;
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

        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);

        const is_rect = sel.mode == .rectangular;
        const rect_lo: i32 = @min(r.top_col, r.bot_col);
        const rect_hi: i32 = @max(r.top_col, r.bot_col);

        var open_link_id: u8 = 0; // currently open OSC 8 link, 0 = none

        var row = r.top_row;
        while (row <= r.bot_row) : (row += 1) {
            const line_cells = self.lineCellsAt(row) orelse continue;
            const start_col: i32 = if (is_rect) rect_lo
                else if (row == r.top_row) r.top_col else 0;
            const end_col: i32 = if (is_rect) rect_hi
                else if (row == r.bot_row) r.bot_col else @intCast(line_cells.len);
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
        var out: std.ArrayList(u8) = .{};
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
        var out: std.ArrayList(SearchMatch) = .{};
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

        var line_buf: std.ArrayList(u8) = .{};
        defer line_buf.deinit(allocator);
        var col_map: std.ArrayList(u32) = .{};
        defer col_map.deinit(allocator);
        var width_map: std.ArrayList(u8) = .{};
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
        var out: std.ArrayList(SearchMatch) = .{};
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

        var line_buf: std.ArrayList(u8) = .{};
        defer line_buf.deinit(allocator);
        var col_map: std.ArrayList(u32) = .{};
        defer col_map.deinit(allocator);
        // Parallel array: width of the cell at col_map[i] (1 or 2).
        // Used to compute visual end column on matches whose last cell
        // is wide (CJK / emoji).
        var width_map: std.ArrayList(u8) = .{};
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

    fn buf(self: *Screen) []Line {
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
                            const cp_len: usize = if ((b0 & 0xE0) == 0xC0) 2
                                else if ((b0 & 0xF0) == 0xE0) 3
                                else if ((b0 & 0xF8) == 0xF0) 4
                                else 0;
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
        }
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
    fn handleOsc4(self: *Screen, rest: []const u8) void {
        const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return;
        const idx = std.fmt.parseInt(u8, rest[0..semi], 10) catch return;
        const data = rest[semi + 1 ..];
        if (data.len == 1 and data[0] == '?') {
            const rgb = self.palette[idx];
            var resp_buf: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&resp_buf, "\x1b]4;{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{
                idx, rgb[0], rgb[0], rgb[1], rgb[1], rgb[2], rgb[2],
            }) catch return;
            self.respond(s);
            return;
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
            if (self.sink.on_image) |f| f(self.sink.ctx, .{
                .width = decoded.width,
                .height = decoded.height,
                .rgba = decoded.rgba,
                .row = self.row,
                .col = self.col,
                .placement_id = 0,
                .z_index = 0,
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
            if (self.sink.on_notification) |f| f(self.sink.ctx, "sketerm", "attention");
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
        // Unknown key — silently drop. Includes SetUserVar,
        // SetBadgeFormat, etc. (no internal state to attach to).
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
            switch (cmd.delete_what) {
                // Uppercase: free source image data too.
                'A' => self.kitty_images.dropAll(),
                'I' => if (cmd.image_id != 0) self.kitty_images.drop(cmd.image_id),
                'P' => if (cmd.image_id != 0) self.kitty_images.drop(cmd.image_id),
                // Lowercase: leave source data alone — placements only.
                else => {},
            }
            if (self.sink.on_image_delete_full) |f| f(self.sink.ctx, .{
                .image_id = cmd.image_id,
                .placement_id = cmd.placement_id,
                .what = cmd.delete_what,
            });
            self.dirty = true;
            return;
        }

        // Ingest into the Manager — handles chunking, base64, PNG/RGB/
        // RGBA decode, transmit-only vs transmit-and-place, place-by-id.
        const outcome = self.kitty_images.ingest(cmd);
        if (outcome.action != .place) return;

        const stored = self.kitty_images.get(outcome.image_id) orelse return;
        if (self.sink.on_image) |f| f(self.sink.ctx, .{
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
            if (self.sink.on_image) |f| f(self.sink.ctx, .{
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
        var resp: std.ArrayList(u8) = .{};
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
        var resp: std.ArrayList(u8) = .{};
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
        // Format: "<num>;<rest>".
        const semi = std.mem.indexOfScalar(u8, bytes, ';') orelse return;
        const num_str = bytes[0..semi];
        const rest = bytes[semi + 1 ..];
        const num = std.fmt.parseInt(u32, num_str, 10) catch return;

        switch (num) {
            0, 2 => {
                if (self.last_title) |old| self.allocator.free(old);
                self.last_title = self.allocator.dupe(u8, rest) catch null;
                if (self.sink.on_title) |f| f(self.sink.ctx, rest);
            },
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
            9 => {
                // iTerm2 desktop notification: OSC 9 ; <message>.
                if (self.sink.on_notification) |f| f(self.sink.ctx, "sketerm", rest);
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
            // OSC 133 — FinalTerm shell-integration prompt marks.
            // A=prompt-start, B=prompt-end, C=command-start,
            // D=command-end. We record A as a navigable prompt row.
            133 => {
                if (rest.len > 0 and rest[0] == 'A') self.recordPromptMark();
            },
            // OSC 104 — palette reset. With no args, reset all
            // entries; with `; n` reset only that index.
            104 => {
                if (rest.len == 0) {
                    self.palette = palette_default_256;
                } else if (std.fmt.parseInt(u8, rest, 10)) |idx| {
                    self.palette[idx] = palette_default_256[idx];
                } else |_| {}
                self.dirty = true;
            },
            // OSC 110 / 111 — fg / bg color reset to default.
            110 => {
                self.default_fg = .{ 0.92, 0.92, 0.92, 1.0 };
                self.dirty = true;
            },
            111 => {
                self.default_bg = .{ 0.10, 0.10, 0.10, 1.0 };
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
                    if (self.sink.on_notification) |f| f(self.sink.ctx, after, "");
                    return;
                };
                const title = after[0..semi3];
                const body = after[semi3 + 1 ..];
                if (self.sink.on_notification) |f| f(self.sink.ctx, title, body);
            },
            52 => {
                // OSC 52 — `Pc;Pd` where Pc is selection (c=clipboard,
                // p=primary, etc) and Pd is base64-encoded text or '?'.
                const semi2 = std.mem.indexOfScalar(u8, rest, ';') orelse return;
                const data = rest[semi2 + 1 ..];
                if (data.len == 0) return;
                if (data[0] == '?') return; // read query — gated, post-v1
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

    fn printCp(self: *Screen, cp_in: u32) void {
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
        if (self.last_print_cp != 0 and isExtendingCp(cp)) {
            const row: u16 = @intCast(self.last_print_key >> 16);
            const col: u16 = @intCast(self.last_print_key & 0xFFFF);
            self.appendCluster(row, col, cp);
            return;
        }

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
            0x23F0, 0x23F3, // Alarm clock, hourglass
            0x25FD...0x25FE, // Medium small white/black squares
            0x2614...0x2615, // Umbrella, hot beverage
            0x2648...0x2653, // Zodiac
            0x267F, // Wheelchair
            0x2693, // Anchor
            0x26A1, // High voltage
            0x26AA...0x26AB, // White / black circle
            0x26BD...0x26BE, // Soccer / baseball
            0x26C4...0x26C5, // Snowman / sun behind cloud
            0x26CE, 0x26D4, 0x26EA, // Ophiuchus, no entry, church
            0x26F2...0x26F3, // Fountain, flag in hole
            0x26F5, 0x26FA, 0x26FD, // Sailboat, tent, fuel pump
            0x2705, 0x270A...0x270B, 0x2728, // Check mark, raised hand, sparkles
            0x274C, 0x274E, // Cross mark
            0x2753...0x2755, 0x2757, // Question / exclamation
            0x2795...0x2797, // Plus / minus / division signs
            0x27B0, 0x27BF, // Curly loop / double curly
            0x2B1B...0x2B1C, // Black / white large square
            0x2B50, 0x2B55, // Star / circle
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
                self.bell_at_us = std.time.microTimestamp();
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
    fn resetTabStops(self: *Screen) !void {
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
    fn nextTabStop(self: *Screen, from: u16) u16 {
        if (self.cols == 0) return 0;
        var c: u16 = from + 1;
        while (c < self.cols) : (c += 1) {
            if (c < self.tab_stops.items.len and self.tab_stops.items[c]) return c;
        }
        return self.cols - 1;
    }

    /// First tab stop strictly to the left of `from`, or 0.
    fn prevTabStop(self: *Screen, from: u16) u16 {
        if (from == 0) return 0;
        var c: u16 = from - 1;
        while (c > 0) : (c -= 1) {
            if (c < self.tab_stops.items.len and self.tab_stops.items[c]) return c;
        }
        return 0;
    }

    fn lineFeed(self: *Screen) void {
        if (self.row == self.scroll_bot) {
            self.scrollUp(1);
        } else if (self.row + 1 < self.rows) {
            self.row += 1;
        }
        self.pending_wrap = false;
        if (self.scroll_on_output) self.view_offset = 0;
    }

    // ── CSI dispatch ─────────────────────────────────────────────

    fn csi(self: *Screen, params: Event.Csi) void {
        // Private-prefix dispatch first.
        if (params.private == '?') {
            // DECRQM — `CSI ? Pa $ p`, query a DEC private mode.
            if (params.n_intermediates == 1 and params.intermediates[0] == '$' and params.final == 'p') {
                self.decrqm(params.paramOrDefault(0, 0));
                return;
            }
            switch (params.final) {
                'h' => self.modeSet(params, true),
                'l' => self.modeSet(params, false),
                // DECSED/DECSEL — selective erase. We don't model the
                // protection bit, so treat as plain ED/EL.
                'J' => self.eraseDisplay(params.paramOrDefault(0, 0)),
                'K' => self.eraseLine(params.paramOrDefault(0, 0)),
                'u' => {
                    // Kitty kbd: CSI ? u — query flags.
                    var kbuf: [16]u8 = undefined;
                    const out = std.fmt.bufPrint(&kbuf, "\x1b[?{d}u", .{self.kitty_kbd_flags}) catch return;
                    self.respond(out);
                },
                else => {},
            }
            return;
        }
        if (params.private == '>') {
            switch (params.final) {
                'c' => self.respond("\x1b[>42;1;0c"), // DA2: vendor 42 (sketerm), version 1
                'q' => self.respond("\x1bP>|sketerm 0.1.0\x1b\\"), // XTVERSION
                'm' => {
                    // XTMODKEYS — `CSI > Pn ; Pp m`. Pn=4 sets
                    // modifyOtherKeys level. We accept the level but
                    // don't yet apply it to key encoding.
                    if (params.n_params >= 1 and params.params[0] == 4) {
                        self.modify_other_keys = if (params.n_params >= 2)
                            @intCast(@min(params.params[1], 2))
                        else
                            0;
                    }
                },
                'u' => {
                    // Kitty kbd: CSI > flags u — set flags directly.
                    self.kitty_kbd_flags = @intCast(@min(params.paramOrDefault(0, 0), 0xFF));
                },
                else => {},
            }
            return;
        }
        if (params.private == '=') {
            // Kitty kbd: CSI = flags ; mode u
            //   mode 1 = set, 2 = push+set, 3 = pop
            if (params.final == 'u') {
                const flags: u8 = @intCast(@min(params.paramOrDefault(0, 0), 0xFF));
                const mode: u32 = params.paramOrDefault(1, 1);
                switch (mode) {
                    1 => self.kitty_kbd_flags = flags,
                    2 => {
                        if (self.kitty_kbd_depth < self.kitty_kbd_stack.len) {
                            self.kitty_kbd_stack[self.kitty_kbd_depth] = self.kitty_kbd_flags;
                            self.kitty_kbd_depth += 1;
                        }
                        self.kitty_kbd_flags = flags;
                    },
                    3 => {
                        if (self.kitty_kbd_depth > 0) {
                            self.kitty_kbd_depth -= 1;
                            self.kitty_kbd_flags = self.kitty_kbd_stack[self.kitty_kbd_depth];
                        } else {
                            self.kitty_kbd_flags = 0;
                        }
                    },
                    else => {},
                }
            }
            return;
        }
        if (params.private == '<') {
            // Kitty kbd: CSI < N u — pop N levels.
            if (params.final == 'u') {
                const n = params.paramOrDefault(0, 1);
                var k: u32 = 0;
                while (k < n and self.kitty_kbd_depth > 0) : (k += 1) {
                    self.kitty_kbd_depth -= 1;
                    self.kitty_kbd_flags = self.kitty_kbd_stack[self.kitty_kbd_depth];
                }
                if (self.kitty_kbd_depth == 0 and k < n) self.kitty_kbd_flags = 0;
            }
            return;
        }

        // Intermediate-distinguished: e.g. `CSI Ps SP q` = DECSCUSR.
        if (params.n_intermediates == 1 and params.intermediates[0] == ' ') {
            switch (params.final) {
                'q' => self.decscusr(params.paramOrDefault(0, 0)),
                else => {},
            }
            return;
        }
        if (params.n_intermediates == 1 and params.intermediates[0] == '!') {
            switch (params.final) {
                'p' => self.decstr(),
                else => {},
            }
            return;
        }
        if (params.n_intermediates == 1 and params.intermediates[0] == '"') {
            // DECSCA (`CSI Ps " q`) — selective character protection.
            // We don't model protection; accept silently to keep the
            // parser quiet for terminfo entries that send it.
            return;
        }
        // Public DECRQM — `CSI Pa $ p`. Reports state of an ANSI mode
        // (IRM=4, LNM=20). xterm spec: reply `CSI Pa ; Ps $ y`.
        if (params.n_intermediates == 1 and params.intermediates[0] == '$' and params.final == 'p') {
            const mode = params.paramOrDefault(0, 0);
            const known: ?bool = switch (mode) {
                4 => self.insert_mode,
                20 => self.line_feed_mode,
                else => null,
            };
            const ps: u8 = if (known) |on| (if (on) 1 else 2) else 0;
            var out: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&out, "\x1b[{d};{d}$y", .{ mode, ps }) catch return;
            self.respond(s);
            return;
        }

        switch (params.final) {
            // Cursor movement.
            'A' => self.cursorUp(params.paramOrDefault(0, 1)),
            'B', 'e' => self.cursorDown(params.paramOrDefault(0, 1)),
            'C', 'a' => self.cursorRight(params.paramOrDefault(0, 1)),
            'D' => self.cursorLeft(params.paramOrDefault(0, 1)),
            'E' => {
                self.cursorDown(params.paramOrDefault(0, 1));
                self.col = 0;
                self.pending_wrap = false;
            },
            'F' => {
                self.cursorUp(params.paramOrDefault(0, 1));
                self.col = 0;
                self.pending_wrap = false;
            },
            'G', '`' => {
                const c = params.paramOrDefault(0, 1);
                self.col = if (c == 0) 0 else @min(@as(u16, @intCast(@min(c, 0xFFFF))) - 1, self.cols - 1);
                self.pending_wrap = false;
            },
            'H', 'f' => self.cursorPos(params.paramOrDefault(0, 1), params.paramOrDefault(1, 1)),
            'd' => {
                const r = params.paramOrDefault(0, 1);
                self.row = if (r == 0) 0 else @min(@as(u16, @intCast(@min(r, 0xFFFF))) - 1, self.rows - 1);
                self.pending_wrap = false;
            },
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),

            // Erase.
            'J' => self.eraseDisplay(params.paramOrDefault(0, 0)),
            'K' => self.eraseLine(params.paramOrDefault(0, 0)),
            'X' => {
                const n = params.paramOrDefault(0, 1);
                self.line(self.row).eraseRange(self.col, self.col + @as(u16, @intCast(@min(n, 0xFFFF))));
            },
            '@' => self.insertChars(params.paramOrDefault(0, 1)),
            'P' => self.deleteChars(params.paramOrDefault(0, 1)),

            // Scroll.
            'S' => self.scrollUp(params.paramOrDefault(0, 1)),
            'T' => self.scrollDown(params.paramOrDefault(0, 1)),
            'L' => self.insertLines(params.paramOrDefault(0, 1)),
            'M' => self.deleteLines(params.paramOrDefault(0, 1)),

            // Scroll region (DECSTBM).
            'r' => self.setScrollRegion(params),

            // SGR.
            'm' => self.sgr(params),

            // REP — repeat preceding char Pn times.
            'b' => self.rep(params.paramOrDefault(0, 1)),

            // CHT / CBT — forward / backward tab Pn times.
            'I' => {
                var n = params.paramOrDefault(0, 1);
                if (n == 0) n = 1;
                var i: u32 = 0;
                while (i < n) : (i += 1) self.col = self.nextTabStop(self.col);
                self.pending_wrap = false;
            },
            'Z' => {
                var n = params.paramOrDefault(0, 1);
                if (n == 0) n = 1;
                var i: u32 = 0;
                while (i < n) : (i += 1) self.col = self.prevTabStop(self.col);
                self.pending_wrap = false;
            },

            // TBC — clear tab stop(s).
            'g' => {
                const arg = params.paramOrDefault(0, 0);
                switch (arg) {
                    0 => if (self.col < self.tab_stops.items.len) {
                        self.tab_stops.items[self.col] = false;
                    },
                    3 => for (self.tab_stops.items) |*s| {
                        s.* = false;
                    },
                    else => {},
                }
            },

            // Device status report.
            'n' => self.dsr(params),
            // Primary device attributes.
            'c' => self.respondDa(),
            // Window manipulation reports.
            't' => self.windowOps(params),

            // Public-mode SM / RM. Common one is IRM (4) = insert.
            'h' => self.publicModeSet(params, true),
            'l' => self.publicModeSet(params, false),

            else => {},
        }
    }

    fn publicModeSet(self: *Screen, params: Event.Csi, set: bool) void {
        var i: usize = 0;
        while (i < params.n_params) : (i += 1) {
            switch (params.params[i]) {
                4 => self.insert_mode = set, // IRM
                20 => self.line_feed_mode = set, // LNM
                else => {},
            }
        }
    }

    /// DECRQM — reply to a private-mode query.
    /// Reply: CSI ? Pa ; Ps $ y where Ps =
    ///   0 not recognized, 1 set, 2 reset, 3 permanently set, 4 permanently reset.
    fn decrqm(self: *Screen, mode: u32) void {
        const known: ?bool = switch (mode) {
            1 => self.app_cursor_keys,
            // DECANM — VT52 vs ANSI. We have on_decanm but don't
            // mirror the parser's vt52 flag here; report ANSI (set)
            // since it's the steady-state for any sane app.
            2 => true,
            3 => false, // DECCOLM is rarely set; default reset
            5 => self.reverse_screen, // DECSCNM
            6 => self.origin_mode,
            7 => self.autowrap,
            // 8 (DECARM auto-repeat): always on (controlled by OS).
            8 => true,
            // 12 (cursor blink): track via cursor_shape
            12 => switch (self.cursor_shape) {
                .block_blink, .underline_blink, .bar_blink => true,
                else => false,
            },
            25 => self.cursor_visible,
            40 => self.allow_decolm,
            // DECTCEM-bound mouse modes
            1000 => self.mouse_mode == 1000,
            1002 => self.mouse_mode == 1002,
            1003 => self.mouse_mode == 1003,
            1004 => self.focus_reports,
            1005 => self.mouse_enc == .utf8,
            1006 => self.mouse_enc == .sgr,
            1015 => self.mouse_enc == .urxvt,
            1016 => self.mouse_enc == .sgr_pixel,
            2026 => self.sync_output,
            // 1007 (alt-screen scroll): we don't, treat as off.
            1007 => false,
            1047, 1049 => self.use_alt,
            2004 => self.bracketed_paste,
            else => null,
        };
        const ps: u8 = if (known) |on| (if (on) 1 else 2) else 0;
        var out: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&out, "\x1b[?{d};{d}$y", .{ mode, ps }) catch return;
        self.respond(s);
    }

    fn rep(self: *Screen, n: u32) void {
        if (self.last_print_cp == 0) return;
        const cp = self.last_print_cp;
        const limit = @min(n, @as(u32, self.cols) * @as(u32, self.rows));
        var i: u32 = 0;
        while (i < limit) : (i += 1) self.printCp(cp);
    }

    fn dsr(self: *Screen, params: Event.Csi) void {
        const arg = params.paramOrDefault(0, 0);
        switch (arg) {
            5 => self.respond("\x1b[0n"), // OK
            6 => {
                var resp_buf: [32]u8 = undefined;
                const s = std.fmt.bufPrint(&resp_buf, "\x1b[{d};{d}R", .{ self.row + 1, self.col + 1 }) catch return;
                self.respond(s);
            },
            else => {},
        }
    }

    fn respondDa(self: *Screen) void {
        // VT220 + sixel + ANSI color (62=VT220, 4=sixel, 22=color).
        self.respond("\x1b[?62;4;22c");
    }

    fn decscusr(self: *Screen, ps: u32) void {
        self.cursor_shape = switch (ps) {
            0, 1 => .block_blink,
            2 => .block_steady,
            3 => .underline_blink,
            4 => .underline_steady,
            5 => .bar_blink,
            6 => .bar_steady,
            else => self.cursor_shape,
        };
    }

    fn windowOps(self: *Screen, params: Event.Csi) void {
        const arg = params.paramOrDefault(0, 0);
        var resp_buf: [32]u8 = undefined;
        switch (arg) {
            11 => self.respond("\x1b[1t"), // window state: not iconified
            13 => self.respond("\x1b[3;0;0t"), // window position: 0,0 (we don't know)
            14 => {
                // Pixels — accurate when Pane has reported cell
                // metrics; falls back to the legacy 8x16 approximation
                // when uninitialised (e.g. tests).
                const cw: u32 = if (self.cell_pixel_w > 0) self.cell_pixel_w else 8;
                const ch: u32 = if (self.cell_pixel_h > 0) self.cell_pixel_h else 16;
                const w: u32 = @as(u32, self.cols) * cw;
                const h: u32 = @as(u32, self.rows) * ch;
                const s = std.fmt.bufPrint(&resp_buf, "\x1b[4;{d};{d}t", .{ h, w }) catch return;
                self.respond(s);
            },
            16 => {
                // CSI 16 t — report cell pixel size as `\x1b[6;<h>;<w>t`.
                const cw: u32 = if (self.cell_pixel_w > 0) self.cell_pixel_w else 8;
                const ch: u32 = if (self.cell_pixel_h > 0) self.cell_pixel_h else 16;
                const s = std.fmt.bufPrint(&resp_buf, "\x1b[6;{d};{d}t", .{ ch, cw }) catch return;
                self.respond(s);
            },
            18 => {
                const s = std.fmt.bufPrint(&resp_buf, "\x1b[8;{d};{d}t", .{ self.rows, self.cols }) catch return;
                self.respond(s);
            },
            19 => {
                const s = std.fmt.bufPrint(&resp_buf, "\x1b[9;{d};{d}t", .{ self.rows, self.cols }) catch return;
                self.respond(s);
            },
            20, 21 => {
                // 20 = report icon label, 21 = report window title.
                // We don't model an icon label distinct from the title.
                // Format per xterm: ESC ] <L|l> <title> ESC \.
                const title = self.last_title orelse "";
                const code: u8 = if (arg == 20) 'L' else 'l';
                var out_buf: [512]u8 = undefined;
                const max_t = @min(title.len, out_buf.len - 5);
                var off: usize = 0;
                out_buf[off] = 0x1B;
                off += 1;
                out_buf[off] = ']';
                off += 1;
                out_buf[off] = code;
                off += 1;
                @memcpy(out_buf[off .. off + max_t], title[0..max_t]);
                off += max_t;
                out_buf[off] = 0x1B;
                off += 1;
                out_buf[off] = '\\';
                off += 1;
                self.respond(out_buf[0..off]);
            },
            // 22 — save title onto stack. Param 0/2 = window title;
            // we treat both identically (no separate icon name).
            22 => self.titleStackPush(),
            // 23 — restore title from stack.
            23 => self.titleStackPop(),
            else => {},
        }
    }

    fn titleStackPush(self: *Screen) void {
        const cur = self.last_title orelse return;
        // Drop oldest if full.
        if (self.title_stack_depth == self.title_stack.len) {
            if (self.title_stack[0]) |old| self.allocator.free(old);
            // Shift left.
            var i: usize = 1;
            while (i < self.title_stack.len) : (i += 1) {
                self.title_stack[i - 1] = self.title_stack[i];
            }
            self.title_stack_depth -= 1;
        }
        const dup = self.allocator.dupe(u8, cur) catch return;
        self.title_stack[self.title_stack_depth] = dup;
        self.title_stack_depth += 1;
    }

    fn titleStackPop(self: *Screen) void {
        if (self.title_stack_depth == 0) return;
        self.title_stack_depth -= 1;
        const restored = self.title_stack[self.title_stack_depth] orelse return;
        self.title_stack[self.title_stack_depth] = null;
        // Replace last_title.
        if (self.last_title) |old| self.allocator.free(old);
        self.last_title = restored;
        // Push down to UI.
        if (self.sink.on_title) |f| f(self.sink.ctx, restored);
    }

    fn respond(self: *Screen, bytes: []const u8) void {
        if (self.sink.on_write_pty) |f| f(self.sink.ctx, bytes);
    }

    fn escFinal(self: *Screen, ef: Event.EscFinal) void {
        // SCS — character-set designation. `ESC ( X` for G0, `ESC ) X`
        // for G1, where X selects ASCII (B) or DEC graphics (0).
        if (ef.n_intermediates == 1 and (ef.intermediates[0] == '(' or ef.intermediates[0] == ')')) {
            const slot: *Charset = if (ef.intermediates[0] == '(') &self.charset_g0 else &self.charset_g1;
            slot.* = switch (ef.final) {
                '0' => .dec_graphics,
                'B' => .ascii,
                else => slot.*,
            };
            return;
        }
        // DECALN — `ESC # 8` fills the screen with 'E' for an
        // alignment pattern. Used by `vttest`.
        if (ef.n_intermediates == 1 and ef.intermediates[0] == '#' and ef.final == '8') {
            for (self.buf()) |*ln| {
                for (ln.cells) |*cell| cell.* = .{ .rune = 'E', .style_ref = 0, .flags = 0, .reserved = 0 };
                ln.dirty = true;
            }
            self.row = 0;
            self.col = 0;
            self.pending_wrap = false;
            return;
        }
        // DECDHL / DECDWL / DECSWL — per-line scaling.
        //   #3 = double-height top half
        //   #4 = double-height bottom half
        //   #5 = single width / single height (default)
        //   #6 = double-width single height
        if (ef.n_intermediates == 1 and ef.intermediates[0] == '#') {
            const ln = self.line(self.row);
            switch (ef.final) {
                '3' => ln.scaling = .dhl_top,
                '4' => ln.scaling = .dhl_bot,
                '5' => ln.scaling = .single,
                '6' => ln.scaling = .dwl,
                else => {},
            }
            ln.dirty = true;
            return;
        }
        switch (ef.final) {
            '7' => self.saveCursor(),
            '8' => self.restoreCursor(),
            'D' => self.lineFeed(),
            'E' => {
                self.lineFeed();
                self.col = 0;
            },
            'H' => {
                // HTS — set tab stop at cursor column.
                if (self.col < self.tab_stops.items.len) self.tab_stops.items[self.col] = true;
            },
            'M' => self.reverseLineFeed(),
            // SS2 (ESC N) / SS3 (ESC O) — single-shift designate G2/G3
            // for the next printed character. We don't model G2/G3
            // charsets, so the next codepoint passes through as ASCII.
            // Recognising the escape prevents the parser from leaking
            // it into the screen as a print, and `pending_single_shift`
            // is consumed (no-op'd) by the next printCp.
            'N' => self.pending_single_shift = .ss2,
            'O' => self.pending_single_shift = .ss3,
            'Z' => self.respondDa(), // DECID — identify, same payload as DA1
            'c' => self.fullReset(),
            '=' => self.app_keypad = true, // DECPAM — application keypad on
            '>' => self.app_keypad = false, // DECPNM — application keypad off
            else => {},
        }
    }

    fn decstr(self: *Screen) void {
        // Soft reset (CSI ! p) — reset modes / scroll region /
        // attributes but keep screen contents.
        self.row = 0;
        self.col = 0;
        self.cur_style = 0;
        self.scroll_top = 0;
        self.scroll_bot = if (self.rows > 0) self.rows - 1 else 0;
        self.autowrap = true;
        self.origin_mode = false;
        self.insert_mode = false;
        self.line_feed_mode = false;
        self.cursor_visible = true;
        self.cursor_shape = .block_blink;
        self.bracketed_paste = false;
        self.focus_reports = false;
        self.app_cursor_keys = false;
        self.app_keypad = false;
        self.mouse_mode = 0;
        self.mouse_sgr = false;
        self.mouse_enc = .legacy;
        self.pending_wrap = false;
        self.pending_single_shift = .none;
        self.charset_g0 = .ascii;
        self.charset_g1 = .ascii;
        self.active_charset = .g0;
        // Per VT520 Programmer Reference, DECSTR resets DECSCNM too.
        // DECCOLM stays as-is (the "allow" flag is sticky per xterm).
        self.reverse_screen = false;
        // Kitty kbd flag stack — clear the active flags but leave the
        // saved stack alone (apps that DECSTR mid-session still expect
        // their previous push state on subsequent CSI <N u).
        self.kitty_kbd_flags = 0;
        if (self.use_alt) self.toggleAltScreen(false);
    }

    pub fn fullReset(self: *Screen) void {
        for (self.buf()) |*l| l.clear();
        self.row = 0;
        self.col = 0;
        self.cur_style = 0;
        self.scroll_top = 0;
        self.scroll_bot = if (self.rows > 0) self.rows - 1 else 0;
        self.autowrap = true;
        self.origin_mode = false;
        self.pending_wrap = false;
        self.pending_single_shift = .none;
        self.charset_g0 = .ascii;
        self.charset_g1 = .ascii;
        self.active_charset = .g0;
        self.app_cursor_keys = false;
        self.app_keypad = false;
        self.mouse_mode = 0;
        self.mouse_sgr = false;
        self.mouse_enc = .legacy;
        self.bracketed_paste = false;
        self.focus_reports = false;
        self.cursor_visible = true;
        self.cursor_shape = .block_blink;
        self.reverse_screen = false;
        self.kitty_kbd_flags = 0;
        self.kitty_kbd_depth = 0;
        self.last_print_cp = 0;
        self.clearAllClusters();
        self.resetTabStops() catch {};
        // Bring the parser back to ANSI mode if it's in VT52.
        if (self.sink.on_decanm) |f| f(self.sink.ctx, true);
    }

    // ── Cursor primitives ────────────────────────────────────────

    fn cursorUp(self: *Screen, n: u32) void {
        // If cursor is inside the scroll region, clamp to scroll_top.
        // Otherwise to absolute row 0 (per xterm/DEC behavior).
        const inside = self.row >= self.scroll_top and self.row <= self.scroll_bot;
        const limit: u16 = if (inside) self.scroll_top else 0;
        const max_dec: u32 = self.row - limit;
        const dec: u16 = @intCast(@min(n, max_dec));
        self.row -= dec;
        self.pending_wrap = false;
    }

    fn cursorDown(self: *Screen, n: u32) void {
        const inside = self.row >= self.scroll_top and self.row <= self.scroll_bot;
        const limit: u16 = if (inside) self.scroll_bot else self.rows - 1;
        const max_dec: u32 = limit - self.row;
        const dec: u16 = @intCast(@min(n, max_dec));
        self.row += dec;
        self.pending_wrap = false;
    }

    fn cursorRight(self: *Screen, n: u32) void {
        const max_dec: u32 = @intCast(self.cols - 1 - self.col);
        const dec: u16 = @intCast(@min(n, max_dec));
        self.col += dec;
        self.pending_wrap = false;
    }

    fn cursorLeft(self: *Screen, n: u32) void {
        const dec: u16 = @intCast(@min(n, @as(u32, self.col)));
        self.col -= dec;
        self.pending_wrap = false;
    }

    fn cursorPos(self: *Screen, r: u32, c: u32) void {
        const r_idx: u16 = if (r == 0) 0 else @intCast(@min(r - 1, @as(u32, self.rows - 1)));
        const c_idx: u16 = if (c == 0) 0 else @intCast(@min(c - 1, @as(u32, self.cols - 1)));
        // Origin-mode constrains within scroll region.
        if (self.origin_mode) {
            self.row = self.scroll_top + r_idx;
            if (self.row > self.scroll_bot) self.row = self.scroll_bot;
        } else {
            self.row = r_idx;
        }
        self.col = c_idx;
        self.pending_wrap = false;
    }

    fn saveCursor(self: *Screen) void {
        self.saved_row = self.row;
        self.saved_col = self.col;
        self.saved_style = self.cur_style;
        self.saved_origin = self.origin_mode;
        self.saved_autowrap = self.autowrap;
        self.saved_charset_g0 = self.charset_g0;
        self.saved_charset_g1 = self.charset_g1;
        self.saved_active_charset = self.active_charset;
        self.saved_link_id = self.current_link_id;
    }

    fn restoreCursor(self: *Screen) void {
        self.row = @min(self.saved_row, if (self.rows > 0) self.rows - 1 else 0);
        self.col = @min(self.saved_col, if (self.cols > 0) self.cols - 1 else 0);
        self.cur_style = self.saved_style;
        self.origin_mode = self.saved_origin;
        self.autowrap = self.saved_autowrap;
        self.charset_g0 = self.saved_charset_g0;
        self.charset_g1 = self.saved_charset_g1;
        self.active_charset = self.saved_active_charset;
        self.current_link_id = self.saved_link_id;
        self.pending_wrap = false;
    }

    fn reverseLineFeed(self: *Screen) void {
        if (self.row == self.scroll_top) {
            self.scrollDown(1);
        } else if (self.row > 0) {
            self.row -= 1;
        }
        self.pending_wrap = false;
    }

    // ── Erase ────────────────────────────────────────────────────

    fn eraseDisplay(self: *Screen, mode: u32) void {
        const lines = self.buf();
        switch (mode) {
            0 => {
                self.line(self.row).eraseRange(self.col, self.cols);
                var i: u16 = self.row + 1;
                while (i < self.rows) : (i += 1) lines[i].clear();
            },
            1 => {
                var i: u16 = 0;
                while (i < self.row) : (i += 1) lines[i].clear();
                self.line(self.row).eraseRange(0, self.col + 1);
            },
            2 => {
                for (lines) |*l| l.clear();
            },
            3 => {
                // Mode 3 (xterm extension): clear screen + scrollback.
                for (lines) |*l| l.clear();
                for (self.scrollback.items) |*l| l.deinit(self.allocator);
                self.scrollback.clearRetainingCapacity();
                // Reset ring head — without this, post-clear pushes
                // wrap from a stale offset and eviction order goes
                // wrong once the ring fills again.
                self.scrollback_head = 0;
                self.view_offset = 0;
            },
            else => {},
        }
    }

    fn eraseLine(self: *Screen, mode: u32) void {
        var ln = self.line(self.row);
        switch (mode) {
            0 => ln.eraseRange(self.col, self.cols),
            1 => ln.eraseRange(0, self.col + 1),
            2 => ln.clear(),
            else => {},
        }
    }

    // ── Scroll ───────────────────────────────────────────────────

    pub fn scrollUp(self: *Screen, n: u32) void {
        self.clearAllClusters();
        if (self.scroll_top >= self.scroll_bot) return;
        const region: u16 = self.scroll_bot - self.scroll_top + 1;
        const move: u16 = @intCast(@min(n, @as(u32, region)));
        const lines = self.buf();

        const push_to_sb = !self.use_alt and self.scroll_top == 0;

        if (move < region) {
            // Stash both the cells AND the ids of the rows we're
            // about to scroll out — they belong to the content, not
            // the array slot. Common case is move=1; use stack
            // scratch up to 8 to avoid the steady-state allocator hit.
            var stash_stack: [8][]Cell = undefined;
            var ids_stack: [8]u64 = undefined;
            var stash_heap: ?[][]Cell = null;
            var ids_heap: ?[]u64 = null;
            defer if (stash_heap) |h| self.allocator.free(h);
            defer if (ids_heap) |h| self.allocator.free(h);
            const stash: [][]Cell = if (move <= stash_stack.len) stash_stack[0..move] else blk: {
                const h = self.allocator.alloc([]Cell, move) catch return;
                stash_heap = h;
                break :blk h;
            };
            const stash_ids: []u64 = if (move <= ids_stack.len) ids_stack[0..move] else blk: {
                const h = self.allocator.alloc(u64, move) catch return;
                ids_heap = h;
                break :blk h;
            };
            var i: u16 = 0;
            while (i < move) : (i += 1) {
                stash[i] = lines[self.scroll_top + i].cells;
                stash_ids[i] = lines[self.scroll_top + i].id;
            }

            if (push_to_sb) {
                // Hand the top-row cells DIRECTLY to scrollback (no
                // dupe). When the ring is full, the evicted oldest
                // cells come back — reuse them as the new bottom-row
                // buffer. Net 0 allocations per scroll in steady state.
                var k: u16 = 0;
                while (k < move) : (k += 1) {
                    const top_cells = stash[k];
                    if (self.pushScrollbackTakeOld(top_cells, stash_ids[k])) |reused| {
                        stash[k] = reused;
                    } else {
                        // Pre-cap: scrollback took ownership, alloc
                        // fresh for the new bottom row.
                        const new_buf = self.allocator.alloc(Cell, self.cols) catch break;
                        stash[k] = new_buf;
                    }
                }
            }

            // Shift cells + ids up by `move`.
            i = 0;
            while (i + move <= self.scroll_bot - self.scroll_top) : (i += 1) {
                lines[self.scroll_top + i].cells = lines[self.scroll_top + i + move].cells;
                lines[self.scroll_top + i].continues_above = lines[self.scroll_top + i + move].continues_above;
                lines[self.scroll_top + i].id = lines[self.scroll_top + i + move].id;
            }
            // The newly-bottom rows get fresh IDs (new content arriving).
            i = 0;
            while (i < move) : (i += 1) {
                const dst = self.scroll_bot - move + 1 + i;
                lines[dst].cells = stash[i];
                @memset(lines[dst].cells, .{});
                lines[dst].continues_above = false;
                lines[dst].id = self.nextLineId();
            }
        } else {
            // Whole region scrolled; everything goes to scrollback (or
            // is dropped, on alt screen).
            if (push_to_sb) {
                // Same swap-buffer trick: hand cells to scrollback,
                // reuse evicted (or alloc fresh) for the now-blank row.
                var k: u16 = 0;
                while (k < region) : (k += 1) {
                    const idx = self.scroll_top + k;
                    const old_cells = lines[idx].cells;
                    const old_id = lines[idx].id;
                    if (self.pushScrollbackTakeOld(old_cells, old_id)) |reused| {
                        lines[idx].cells = reused;
                    } else {
                        const new_buf = self.allocator.alloc(Cell, self.cols) catch break;
                        lines[idx].cells = new_buf;
                    }
                }
            }
            var i: u16 = self.scroll_top;
            while (i <= self.scroll_bot) : (i += 1) {
                @memset(lines[i].cells, .{});
                lines[i].continues_above = false;
                lines[i].id = self.nextLineId();
            }
        }
        var i: u16 = self.scroll_top;
        while (i <= self.scroll_bot) : (i += 1) lines[i].dirty = true;
    }

    pub fn scrollDown(self: *Screen, n: u32) void {
        self.clearAllClusters();
        if (self.scroll_top >= self.scroll_bot) return;
        const region: u16 = self.scroll_bot - self.scroll_top + 1;
        const move: u16 = @intCast(@min(n, @as(u32, region)));
        const lines = self.buf();

        if (move < region) {
            // move=1 is the steady-state RI path; stack scratch up to
            // 8 covers ~all real moves. Heap fallback for larger.
            var stash_stack: [8][]Cell = undefined;
            var stash_heap: ?[][]Cell = null;
            defer if (stash_heap) |h| self.allocator.free(h);
            const stash: [][]Cell = if (move <= stash_stack.len) stash_stack[0..move] else blk: {
                const h = self.allocator.alloc([]Cell, move) catch return;
                stash_heap = h;
                break :blk h;
            };
            var i: u16 = 0;
            while (i < move) : (i += 1) stash[i] = lines[self.scroll_bot - move + 1 + i].cells;
            // Shift cells + ids down (iterate top-to-bottom in reverse
            // to avoid overwriting before reading).
            var j: u16 = 0;
            const inner_count: u16 = self.scroll_bot - self.scroll_top + 1 - move;
            while (j < inner_count) : (j += 1) {
                const src = self.scroll_bot - move - j;
                const dst = self.scroll_bot - j;
                lines[dst].cells = lines[src].cells;
                lines[dst].continues_above = lines[src].continues_above;
                lines[dst].id = lines[src].id;
            }
            i = 0;
            while (i < move) : (i += 1) {
                lines[self.scroll_top + i].cells = stash[i];
                @memset(lines[self.scroll_top + i].cells, .{});
                lines[self.scroll_top + i].continues_above = false;
                lines[self.scroll_top + i].id = self.nextLineId();
            }
        } else {
            var i: u16 = self.scroll_top;
            while (i <= self.scroll_bot) : (i += 1) {
                @memset(lines[i].cells, .{});
                lines[i].continues_above = false;
                lines[i].id = self.nextLineId();
            }
        }
        var i: u16 = self.scroll_top;
        while (i <= self.scroll_bot) : (i += 1) lines[i].dirty = true;
    }

    fn insertChars(self: *Screen, n: u32) void {
        var ln = self.line(self.row);
        const cells = ln.cells;
        const col = self.col;
        if (col >= cells.len) return;
        const max_n: u32 = @intCast(cells.len - col);
        const move: u16 = @intCast(@min(n, max_n));
        if (move == 0) return;
        // Shift cells right from col by `move`. Last cells fall off.
        var i: usize = cells.len;
        while (i > col + move) : (i -= 1) {
            cells[i - 1] = cells[i - 1 - move];
        }
        // Clear the inserted cells.
        var k: u16 = 0;
        while (k < move) : (k += 1) cells[col + k] = .{};
        ln.dirty = true;
    }

    fn deleteChars(self: *Screen, n: u32) void {
        var ln = self.line(self.row);
        const cells = ln.cells;
        const col = self.col;
        if (col >= cells.len) return;
        const max_n: u32 = @intCast(cells.len - col);
        const move: u16 = @intCast(@min(n, max_n));
        if (move == 0) return;
        // Shift cells left from col+move into col. Last cells become blank.
        var i: usize = col;
        while (i + move < cells.len) : (i += 1) {
            cells[i] = cells[i + move];
        }
        while (i < cells.len) : (i += 1) cells[i] = .{};
        ln.dirty = true;
    }

    fn insertLines(self: *Screen, n: u32) void {
        if (self.row < self.scroll_top or self.row > self.scroll_bot) return;
        const old_top = self.scroll_top;
        self.scroll_top = self.row;
        defer self.scroll_top = old_top;
        self.scrollDown(n);
    }

    fn deleteLines(self: *Screen, n: u32) void {
        if (self.row < self.scroll_top or self.row > self.scroll_bot) return;
        const old_top = self.scroll_top;
        self.scroll_top = self.row;
        defer self.scroll_top = old_top;
        self.scrollUp(n);
    }

    fn setScrollRegion(self: *Screen, params: Event.Csi) void {
        const top = params.paramOrDefault(0, 1);
        const bot = params.paramOrDefault(1, self.rows);
        const t: u16 = if (top == 0) 0 else @intCast(@min(top - 1, @as(u32, self.rows - 1)));
        const b: u16 = if (bot == 0) self.rows - 1 else @intCast(@min(bot - 1, @as(u32, self.rows - 1)));
        if (t < b) {
            self.scroll_top = t;
            self.scroll_bot = b;
            // After DECSTBM, cursor goes to top-left (or origin if set).
            if (self.origin_mode) {
                self.row = self.scroll_top;
            } else {
                self.row = 0;
            }
            self.col = 0;
            self.pending_wrap = false;
        }
    }

    // ── Modes ────────────────────────────────────────────────────

    fn modeSet(self: *Screen, params: Event.Csi, set: bool) void {
        var i: usize = 0;
        while (i < params.n_params) : (i += 1) {
            switch (params.params[i]) {
                1 => self.app_cursor_keys = set,
                2 => {
                    // DECANM — set=ANSI/VT100, reset=VT52. Forward
                    // to the parser via the sink so the byte stream
                    // following this sequence is parsed correctly.
                    if (self.sink.on_decanm) |f| f(self.sink.ctx, set);
                },
                3 => {
                    // DECCOLM — switch column count when explicitly
                    // enabled via DECSET 40. Side effects per spec:
                    // clear screen, home cursor, reset margins.
                    if (self.allow_decolm) {
                        const new_cols: u16 = if (set) 132 else 80;
                        if (new_cols != self.cols) {
                            self.resize(new_cols, self.rows) catch {};
                        }
                        self.scroll_top = 0;
                        self.scroll_bot = if (self.rows > 0) self.rows - 1 else 0;
                        self.row = 0;
                        self.col = 0;
                        self.pending_wrap = false;
                        for (self.buf()) |*l| l.clear();
                        self.dirty = true;
                    }
                },
                5 => {
                    // DECSCNM — reverse video mode (whole screen).
                    self.reverse_screen = set;
                    self.dirty = true;
                },
                6 => {
                    self.origin_mode = set;
                    self.row = if (set and self.origin_mode) self.scroll_top else 0;
                    self.col = 0;
                    self.pending_wrap = false;
                },
                7 => self.autowrap = set,
                40 => self.allow_decolm = set,
                25 => self.cursor_visible = set,
                1000 => self.mouse_mode = if (set) 1000 else 0,
                1002 => self.mouse_mode = if (set) 1002 else 0,
                1003 => self.mouse_mode = if (set) 1003 else 0,
                1004 => self.focus_reports = set,
                2026 => {
                    // Synchronized output mode (kitty/wezterm/iTerm2).
                    // Setting on: app begins a multi-step update that
                    // shouldn't be displayed mid-state. Reset: flush.
                    self.sync_output = set;
                    if (!set) self.dirty = true;
                },
                1005 => self.mouse_enc = if (set) .utf8 else .legacy,
                1006 => {
                    self.mouse_sgr = set;
                    self.mouse_enc = if (set) .sgr else .legacy;
                },
                1015 => self.mouse_enc = if (set) .urxvt else .legacy,
                1016 => self.mouse_enc = if (set) .sgr_pixel else .legacy,
                1047 => self.toggleAltScreen(set),
                1049 => {
                    // 1049 = save cursor + switch alt + clear alt on
                    // set; restore cursor + switch main on reset.
                    if (set and !self.use_alt) self.saveCursor();
                    self.toggleAltScreen(set);
                    if (set) {
                        self.row = 0;
                        self.col = 0;
                        self.pending_wrap = false;
                    } else {
                        self.restoreCursor();
                    }
                },
                2004 => self.bracketed_paste = set,
                else => {},
            }
        }
    }

    fn toggleAltScreen(self: *Screen, on: bool) void {
        if (on == self.use_alt) return;
        if (on and self.alt == null) {
            const alt = self.allocator.alloc(Line, self.rows) catch return;
            var i: u16 = 0;
            errdefer {
                for (alt[0..i]) |*l| l.deinit(self.allocator);
                self.allocator.free(alt);
            }
            while (i < self.rows) : (i += 1) {
                alt[i] = Line.init(self.allocator, self.cols) catch return;
                alt[i].id = self.nextLineId();
            }
            self.alt = alt;
        }
        if (on) {
            self.use_alt = true;
            for (self.alt.?) |*l| {
                l.clear();
                l.id = self.nextLineId();
            }
        } else {
            self.use_alt = false;
        }
        // Selection coordinates reference the previous buffer — they
        // make no sense after the swap, so wipe them.
        self.selection.clear();
        // Always mark all lines dirty when switching.
        for (self.buf()) |*l| l.dirty = true;
        self.dirty = true;
    }

    // ── SGR ──────────────────────────────────────────────────────

    fn sgr(self: *Screen, params: Event.Csi) void {
        var entry = self.pool.get(self.cur_style);
        var i: usize = 0;
        while (i < params.n_params or (params.n_params == 0 and i == 0)) : (i += 1) {
            const p = if (params.n_params == 0) 0 else params.params[i];
            switch (p) {
                0 => entry = .{},
                1 => entry.attrs.bold = true,
                2 => entry.attrs.dim = true,
                3 => entry.attrs.italic = true,
                4 => {
                    // `4` alone or `4;N` → plain underline.
                    // `4:0` → no underline; `4:1` → straight; `4:2`
                    // → double; `4:3` → curly; `4:4` → dotted; `4:5`
                    // → dashed. Sub-param-aware, kitty/iTerm2 spec.
                    if (i + 1 < params.n_params and params.isSub(i + 1)) {
                        const style = params.params[i + 1];
                        switch (style) {
                            0 => {
                                entry.attrs.underline = false;
                                entry.attrs.double_underline = false;
                                entry.attrs.curly_underline = false;
                            },
                            1 => entry.attrs.underline = true,
                            2 => entry.attrs.double_underline = true,
                            3 => entry.attrs.curly_underline = true,
                            // 4/5 (dotted/dashed) — fold into curly for now;
                            // we have no separate flag.
                            4, 5 => entry.attrs.curly_underline = true,
                            else => entry.attrs.underline = true,
                        }
                        i += 1;
                    } else {
                        entry.attrs.underline = true;
                    }
                },
                5 => entry.attrs.blink = true,
                6 => entry.attrs.fast_blink = true,
                7 => entry.attrs.reverse = true,
                8 => entry.attrs.invisible = true,
                9 => entry.attrs.strikethrough = true,
                21 => entry.attrs.double_underline = true,
                22 => { entry.attrs.bold = false; entry.attrs.dim = false; },
                23 => entry.attrs.italic = false,
                24 => { entry.attrs.underline = false; entry.attrs.double_underline = false; entry.attrs.curly_underline = false; },
                25 => { entry.attrs.blink = false; entry.attrs.fast_blink = false; },
                27 => entry.attrs.reverse = false,
                28 => entry.attrs.invisible = false,
                29 => entry.attrs.strikethrough = false,
                30...37 => entry.fg = .{ .palette = @intCast(p - 30) },
                38 => {
                    if (i + 2 < params.n_params and params.params[i + 1] == 5) {
                        entry.fg = .{ .palette = @intCast(@min(params.params[i + 2], 255)) };
                        i += 2;
                    } else if (i + 4 < params.n_params and params.params[i + 1] == 2) {
                        entry.fg = .{ .rgb = .{
                            .r = @intCast(@min(params.params[i + 2], 255)),
                            .g = @intCast(@min(params.params[i + 3], 255)),
                            .b = @intCast(@min(params.params[i + 4], 255)),
                        } };
                        i += 4;
                    }
                },
                39 => entry.fg = .default,
                40...47 => entry.bg = .{ .palette = @intCast(p - 40) },
                48 => {
                    if (i + 2 < params.n_params and params.params[i + 1] == 5) {
                        entry.bg = .{ .palette = @intCast(@min(params.params[i + 2], 255)) };
                        i += 2;
                    } else if (i + 4 < params.n_params and params.params[i + 1] == 2) {
                        entry.bg = .{ .rgb = .{
                            .r = @intCast(@min(params.params[i + 2], 255)),
                            .g = @intCast(@min(params.params[i + 3], 255)),
                            .b = @intCast(@min(params.params[i + 4], 255)),
                        } };
                        i += 4;
                    }
                },
                49 => entry.bg = .default,
                53 => entry.attrs.overline = true,
                55 => entry.attrs.overline = false,
                90...97 => entry.fg = .{ .palette = @intCast(p - 90 + 8) },
                100...107 => entry.bg = .{ .palette = @intCast(p - 100 + 8) },
                else => {},
            }
            if (params.n_params == 0) break; // CSI m alone = reset
        }
        self.cur_style = self.pool.intern(entry) catch self.cur_style;
    }

    // ── Debug ────────────────────────────────────────────────────

    /// Dump the active screen to a writer for tests / debugging.
    /// Each row terminated by `\n`. Cells with rune 0 render as space.
    pub fn dump(self: *Screen, w: *std.io.Writer) !void {
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

test "scroll up moves content" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 3, 3);
    defer s.deinit();
    s.printCp('a'); s.execute('\r'); s.execute('\n');
    s.printCp('b'); s.execute('\r'); s.execute('\n');
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
    csi.params[0] = 1; csi.n_params = 1; csi.final = 'm'; s.csi(csi);
    try std.testing.expect(pool.get(s.cur_style).attrs.bold);
    csi.params[0] = 0; csi.n_params = 1; csi.final = 'm'; s.csi(csi);
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
    s.printCp('a'); s.execute('\r'); s.execute('\n');
    s.printCp('b'); s.execute('\r'); s.execute('\n');
    s.printCp('c'); s.execute('\r'); s.execute('\n');
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
        s.printCp('x'); s.execute('\r'); s.execute('\n');
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
        s.printCp(ch); s.execute('\r'); s.execute('\n');
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
        fn cb(_: ?*anyopaque, t: []const u8, b: []const u8) void {
            const tn = @min(t.len, got_title.len);
            @memcpy(got_title[0..tn], t[0..tn]);
            got_title_len = tn;
            const bn = @min(b.len, got_body.len);
            @memcpy(got_body[0..bn], b[0..bn]);
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

test "kitty kbd: CSI > N u sets flags" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    var csi = Event.Csi{};
    csi.private = '>';
    csi.params[0] = 5; // disambiguate + report-events
    csi.n_params = 1;
    csi.final = 'u';
    s.csi(csi);
    try std.testing.expectEqual(@as(u8, 5), s.kitty_kbd_flags);
}

test "kitty kbd: CSI = N ; 2 u pushes, < pops" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 1);
    defer s.deinit();
    s.kitty_kbd_flags = 0x01;
    var push = Event.Csi{};
    push.private = '=';
    push.params[0] = 0x0F;
    push.params[1] = 2;
    push.n_params = 2;
    push.final = 'u';
    s.csi(push);
    try std.testing.expectEqual(@as(u8, 0x0F), s.kitty_kbd_flags);
    try std.testing.expectEqual(@as(u8, 1), s.kitty_kbd_depth);
    var pop = Event.Csi{};
    pop.private = '<';
    pop.params[0] = 1;
    pop.n_params = 1;
    pop.final = 'u';
    s.csi(pop);
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

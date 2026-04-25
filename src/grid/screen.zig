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
    /// main screen. Capped at `scrollback_capacity`. Older entries
    /// are evicted when full.
    scrollback: std.ArrayList(Line) = .{},
    scrollback_capacity: usize = 10_000,
    /// Rendering offset (0 = bottom, > 0 = scrolled up by N lines).
    view_offset: u32 = 0,

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
    /// DECSET 1004 — focus reporting.
    focus_reports: bool = false,
    /// DECCKM (mode 1) — application cursor keys (arrows emit
    /// `ESC O X` instead of `ESC [ X`).
    app_cursor_keys: bool = false,
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

    /// Pending wrap: cursor "logically" past col cols-1, awaiting
    /// next print to actually wrap. Matches xterm semantics.
    pending_wrap: bool = false,

    /// UTF-8 reassembly for `print_byte` events.
    decoder: utf8.Decoder = .{},

    /// Set on any state change; cleared by the renderer after using.
    dirty: bool = true,

    /// Selection (mouse drag).
    selection: @import("selection.zig").Selection = .{},

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
    prompt_marks: [256]i32 = [_]i32{0} ** 256,
    prompt_marks_len: u16 = 0,
    prompt_marks_head: u16 = 0,

    /// modifyOtherKeys level (CSI > 4 ; Pp m). 0=off, 1=ambiguous
    /// only, 2=all printable. Input encoder hasn't wired this yet.
    modify_other_keys: u8 = 0,

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
    };

    pub fn init(allocator: std.mem.Allocator, pool: *Pool, cols: u16, rows: u16) !*Screen {
        const self = try allocator.create(Screen);
        errdefer allocator.destroy(self);

        const active = try allocator.alloc(Line, rows);
        errdefer allocator.free(active);
        var initialized: u16 = 0;
        errdefer for (active[0..initialized]) |*l| l.deinit(allocator);
        for (active) |*l| {
            l.* = try Line.init(allocator, cols);
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
        };
        // SKETERM_SCROLLBACK env override (lines, 0 = disable scrollback).
        if (std.posix.getenv("SKETERM_SCROLLBACK")) |env| {
            if (std.fmt.parseInt(usize, env, 10)) |n| {
                self.scrollback_capacity = n;
            } else |_| {}
        }
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
        if (self.preedit_text) |t| self.allocator.free(t);
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

    /// Record a prompt-mark at the current row (called from OSC 133).
    fn recordPromptMark(self: *Screen) void {
        const cap: u16 = self.prompt_marks.len;
        const idx = self.prompt_marks_head;
        self.prompt_marks[idx] = @intCast(self.row);
        self.prompt_marks_head = (idx + 1) % cap;
        if (self.prompt_marks_len < cap) self.prompt_marks_len += 1;
    }

    /// Clear the visible screen + the scrollback ring + send cursor
    /// home. Used by Ctrl+Shift+K (GNOME convention).
    pub fn clearAndScrollback(self: *Screen) void {
        for (self.buf()) |*l| l.clear();
        for (self.scrollback.items) |*l| l.deinit(self.allocator);
        self.scrollback.clearRetainingCapacity();
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
        // Capture cursor's logical position before consuming.
        var combined: std.ArrayList(Line) = .{};
        defer combined.deinit(self.allocator);
        try combined.appendSlice(self.allocator, self.scrollback.items);
        const sb_count = self.scrollback.items.len;
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
        // `all_rows` is owned and we need to redistribute it into
        // active + scrollback. Free the old buffers first.
        for (self.active) |*ln| ln.deinit(self.allocator);
        self.allocator.free(self.active);
        for (self.scrollback.items) |*ln| ln.deinit(self.allocator);
        self.scrollback.clearRetainingCapacity();

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

        // Fill scrollback (older first, capped at scrollback_capacity).
        if (sb_rows > 0) {
            const sb_slice = all_rows[0..sb_rows];
            for (sb_slice) |row| {
                if (self.scrollback.items.len >= self.scrollback_capacity) {
                    var oldest = self.scrollback.orderedRemove(0);
                    oldest.deinit(self.allocator);
                }
                try self.scrollback.append(self.allocator, row);
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
        // Pad if we have fewer logical rows than fit.
        while (i < new_rows) : (i += 1) {
            new_active[i] = try Line.init(self.allocator, new_cols);
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
            while (i < new_rows) : (i += 1) new_buf[i] = try Line.init(allocator, new_cols);
            slot.* = new_buf;
        } else if (new_rows < old_rows) {
            const drop = old_rows - new_rows;
            var i: u16 = 0;
            while (i < drop) : (i += 1) {
                if (push_to_sb) {
                    const copy = allocator.dupe(Cell, slot.*[i].cells) catch null;
                    if (copy) |cells| screen.pushScrollback(cells);
                }
                slot.*[i].deinit(allocator);
            }
            std.mem.copyForwards(Line, slot.*[0..new_rows], slot.*[drop..]);
            const new_buf = try allocator.realloc(slot.*, new_rows);
            slot.* = new_buf;
        }
    }

    /// Push a line into scrollback. Caller transfers ownership of
    /// the cells slice. Evicts oldest if cap exceeded.
    fn pushScrollback(self: *Screen, cells: []Cell) void {
        if (self.scrollback.items.len >= self.scrollback_capacity) {
            // Evict oldest.
            var old = self.scrollback.orderedRemove(0);
            old.deinit(self.allocator);
        }
        self.scrollback.append(self.allocator, .{ .cells = cells }) catch {
            // On OOM, just drop the line (free it).
            self.allocator.free(cells);
        };
    }

    /// Number of scrollback lines currently held.
    pub fn scrollbackCount(self: *const Screen) u32 {
        return @intCast(self.scrollback.items.len);
    }

    /// Get a scrollback line by offset-from-top. 0 = oldest.
    pub fn scrollbackLine(self: *const Screen, idx: u32) *const Line {
        return &self.scrollback.items[idx];
    }

    /// Extract selection text (UTF-8). Coordinates are *display*
    /// rows: 0..rows-1 reference active screen, negative values
    /// reference scrollback (-1 = bottom-most scrollback line).
    /// Caller frees the returned slice.
    pub fn extractSelection(self: *const Screen, allocator: std.mem.Allocator) ![]u8 {
        const sel = self.selection;
        const r = sel.rect() orelse return try allocator.alloc(u8, 0);

        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);

        var row = r.top_row;
        while (row <= r.bot_row) : (row += 1) {
            const line_cells = self.lineCellsAt(row) orelse continue;
            const start_col: i32 = if (row == r.top_row) r.top_col else 0;
            const end_col: i32 = if (row == r.bot_row) r.bot_col else @intCast(line_cells.len);
            const lo: usize = @intCast(@max(@as(i32, 0), start_col));
            const hi: usize = @intCast(@max(@as(i32, 0), end_col));
            const hi_clamped = @min(hi, line_cells.len);
            if (lo >= hi_clamped) continue;

            // Trim trailing blank cells on this line span.
            var actual_hi = hi_clamped;
            while (actual_hi > lo and line_cells[actual_hi - 1].rune == 0) actual_hi -= 1;

            var col: usize = lo;
            while (col < actual_hi) : (col += 1) {
                const cell = line_cells[col];
                // Skip wide-char continuation cells (right half of a
                // 2-column glyph). Their rune is 0 by design.
                if (cell.flags & 0b0000_0010 != 0) continue;
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
                // Suppress the newline if the next row is a soft-wrap
                // continuation — we want one logical line.
                const next_continues = if (self.lineAt(row + 1)) |l| l.continues_above else false;
                if (!next_continues) try out.append(allocator, '\n');
            }
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Returns the cells slice for a display row, including scrollback
    /// (negative rows). Returns null on out-of-range.
    fn lineCellsAt(self: *const Screen, row: i32) ?[]Cell {
        return if (self.lineAt(row)) |l| l.cells else null;
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
            const idx = sb_count - 1 - idx_from_end;
            return &self.scrollback.items[idx];
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

    pub fn onApc(self: *Screen, body: []const u8) void {
        // Kitty graphics protocol: APC G=...
        if (body.len < 1 or body[0] != 'G') return;
        const kitty = @import("../parser/kitty_image.zig");
        const cmd = kitty.parse(body) catch return;

        // q=action — capability probe. Reply OK so apps know we
        // accept kitty graphics; no actual transfer happens.
        if (cmd.action == .query) {
            var resp: [64]u8 = undefined;
            const s = std.fmt.bufPrint(&resp, "\x1b_Gi={d};OK\x1b\\", .{cmd.image_id}) catch return;
            self.respond(s);
            return;
        }

        // Delete action — fire the sink so the Pane's ImageStore
        // marks matching textures for GL-side cleanup.
        if (cmd.action == .delete) {
            if (self.sink.on_image_delete_full) |f| f(self.sink.ctx, .{
                .image_id = cmd.image_id,
                .placement_id = cmd.placement_id,
                .what = cmd.delete_what,
            });
            self.dirty = true;
            return;
        }

        // v1: just notify the sink with raw cmd via the existing image
        // event when we have RGBA. For format=32 (RGBA), payload IS
        // the raw pixels (after base64+optional zlib).
        if (cmd.action == .transmit_and_place and cmd.format == 32 and
            cmd.compression == 0 and cmd.width > 0 and cmd.height > 0)
        {
            // Decode base64 payload.
            const decoder = std.base64.standard.Decoder;
            const out_len = decoder.calcSizeForSlice(cmd.payload) catch return;
            const expected = cmd.width * cmd.height * 4;
            if (out_len < expected) return;
            const decode_buf = self.allocator.alloc(u8, out_len) catch return;
            defer self.allocator.free(decode_buf);
            decoder.decode(decode_buf, cmd.payload) catch return;
            if (self.sink.on_image) |f| f(self.sink.ctx, .{
                .width = cmd.width,
                .height = cmd.height,
                .rgba = decode_buf[0..expected],
                .row = self.row,
                .col = self.col,
                .image_id = cmd.image_id,
                .placement_id = cmd.placement_id,
                .z_index = cmd.z,
            });
        }
    }

    fn onDcs(self: *Screen, d: Event.DcsFull) void {
        // DECRQSS: `DCS $ q <selector> ST` — request status string.
        if (d.proto.final == 'q' and d.proto.n_intermediates == 1 and d.proto.intermediates[0] == '$') {
            self.handleDecrqss(d.body);
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
        // Write a status message at the cursor position. Hold-on-exit
        // = true (per plan) — pane stays open until user closes it.
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "[process exited with status {d}]", .{status}) catch return;
        // CR + LF first to start a new line.
        self.execute('\r');
        self.execute('\n');
        for (msg) |b| self.printByte(b);
        self.execute('\r');
        self.execute('\n');
        self.cursor_visible = false;
    }

    fn onOsc(self: *Screen, bytes: []const u8) void {
        // Format: "<num>;<rest>".
        const semi = std.mem.indexOfScalar(u8, bytes, ';') orelse return;
        const num_str = bytes[0..semi];
        const rest = bytes[semi + 1 ..];
        const num = std.fmt.parseInt(u32, num_str, 10) catch return;

        switch (num) {
            0, 2 => {
                if (self.sink.on_title) |f| f(self.sink.ctx, rest);
            },
            7 => {
                if (self.sink.on_cwd) |f| f(self.sink.ctx, rest);
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
            1337 => {
                // iTerm2 inline image: OSC 1337 ; File=...:<base64> ST
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
                });
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

    fn printCp(self: *Screen, cp_in: u32) void {
        // Translate ASCII through the active charset designation.
        const active = if (self.active_charset == .g0) self.charset_g0 else self.charset_g1;
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
        // base codepoint replaces it.
        self.clearClusterAt(self.row, self.col);
        if (width == 2 and self.col + 1 < self.cols) self.clearClusterAt(self.row, self.col + 1);

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
            0x0A, 0x0B, 0x0C => self.lineFeed(),
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
                else => {},
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
            6 => self.origin_mode,
            7 => self.autowrap,
            25 => self.cursor_visible,
            1000 => self.mouse_mode == 1000,
            1002 => self.mouse_mode == 1002,
            1003 => self.mouse_mode == 1003,
            1004 => self.focus_reports,
            1006 => self.mouse_sgr,
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
                // Pixels — we don't know exact pixel size, approximate
                // via cell metrics * cols/rows. v1: report grid * 8/16.
                const w: u32 = @as(u32, self.cols) * 8;
                const h: u32 = @as(u32, self.rows) * 16;
                const s = std.fmt.bufPrint(&resp_buf, "\x1b[4;{d};{d}t", .{ h, w }) catch return;
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
            else => {},
        }
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
            'Z' => self.respondDa(), // DECID — identify, same payload as DA1
            'c' => self.fullReset(),
            '=' => {}, // DECPAM — application keypad on (numpad encoding shift)
            '>' => {}, // DECPNM — application keypad off
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
        self.cursor_visible = true;
        self.cursor_shape = .block_blink;
        self.bracketed_paste = false;
        self.focus_reports = false;
        self.app_cursor_keys = false;
        self.mouse_mode = 0;
        self.mouse_sgr = false;
        self.pending_wrap = false;
        self.charset_g0 = .ascii;
        self.charset_g1 = .ascii;
        self.active_charset = .g0;
        if (self.use_alt) self.toggleAltScreen(false);
    }

    fn fullReset(self: *Screen) void {
        for (self.buf()) |*l| l.clear();
        self.row = 0;
        self.col = 0;
        self.cur_style = 0;
        self.scroll_top = 0;
        self.scroll_bot = if (self.rows > 0) self.rows - 1 else 0;
        self.autowrap = true;
        self.origin_mode = false;
        self.pending_wrap = false;
        self.charset_g0 = .ascii;
        self.charset_g1 = .ascii;
        self.active_charset = .g0;
        self.app_cursor_keys = false;
        self.mouse_mode = 0;
        self.mouse_sgr = false;
        self.bracketed_paste = false;
        self.focus_reports = false;
        self.cursor_visible = true;
        self.cursor_shape = .block_blink;
        self.last_print_cp = 0;
        self.clearAllClusters();
        self.resetTabStops() catch {};
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

        // Push scrolled-out lines into scrollback (only when on main
        // screen and scrolling at the actual top).
        const push_to_sb = !self.use_alt and self.scroll_top == 0;

        if (move < region) {
            // Rotate cell-pointers: top `move` go to bottom (cleared
            // or pushed to scrollback first).
            var stash = self.allocator.alloc([]Cell, move) catch return;
            defer self.allocator.free(stash);
            var i: u16 = 0;
            while (i < move) : (i += 1) stash[i] = lines[self.scroll_top + i].cells;

            if (push_to_sb) {
                // Push a *copy* of each scrolled line to scrollback so
                // the original cell buffer can stay in the rotation.
                var k: u16 = 0;
                while (k < move) : (k += 1) {
                    const copy = self.allocator.dupe(Cell, stash[k]) catch break;
                    self.pushScrollback(copy);
                }
            }

            i = 0;
            while (i + move <= self.scroll_bot - self.scroll_top) : (i += 1) {
                lines[self.scroll_top + i].cells = lines[self.scroll_top + i + move].cells;
                lines[self.scroll_top + i].continues_above = lines[self.scroll_top + i + move].continues_above;
            }
            i = 0;
            while (i < move) : (i += 1) {
                const dst = self.scroll_bot - move + 1 + i;
                lines[dst].cells = stash[i];
                @memset(lines[dst].cells, .{});
                lines[dst].continues_above = false;
            }
        } else {
            // Entire region scrolled.
            if (push_to_sb) {
                var i: u16 = 0;
                while (i < region) : (i += 1) {
                    const copy = self.allocator.dupe(Cell, lines[self.scroll_top + i].cells) catch break;
                    self.pushScrollback(copy);
                }
            }
            var i: u16 = self.scroll_top;
            while (i <= self.scroll_bot) : (i += 1) {
                @memset(lines[i].cells, .{});
                lines[i].continues_above = false;
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
            var stash = self.allocator.alloc([]Cell, move) catch return;
            defer self.allocator.free(stash);
            var i: u16 = 0;
            while (i < move) : (i += 1) stash[i] = lines[self.scroll_bot - move + 1 + i].cells;
            // Shift cells down (iterate top-to-bottom in reverse to avoid
            // overwriting before reading).
            var j: u16 = 0;
            const inner_count: u16 = self.scroll_bot - self.scroll_top + 1 - move;
            while (j < inner_count) : (j += 1) {
                const src = self.scroll_bot - move - j;
                const dst = self.scroll_bot - j;
                lines[dst].cells = lines[src].cells;
                lines[dst].continues_above = lines[src].continues_above;
            }
            i = 0;
            while (i < move) : (i += 1) {
                lines[self.scroll_top + i].cells = stash[i];
                @memset(lines[self.scroll_top + i].cells, .{});
                lines[self.scroll_top + i].continues_above = false;
            }
        } else {
            var i: u16 = self.scroll_top;
            while (i <= self.scroll_bot) : (i += 1) {
                @memset(lines[i].cells, .{});
                lines[i].continues_above = false;
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
                6 => {
                    self.origin_mode = set;
                    self.row = if (set and self.origin_mode) self.scroll_top else 0;
                    self.col = 0;
                    self.pending_wrap = false;
                },
                7 => self.autowrap = set,
                25 => self.cursor_visible = set,
                1000 => self.mouse_mode = if (set) 1000 else 0,
                1002 => self.mouse_mode = if (set) 1002 else 0,
                1003 => self.mouse_mode = if (set) 1003 else 0,
                1004 => self.focus_reports = set,
                1006 => self.mouse_sgr = set,
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
            }
            self.alt = alt;
        }
        if (on) {
            self.use_alt = true;
            for (self.alt.?) |*l| l.clear();
        } else {
            self.use_alt = false;
        }
        // Always mark all lines dirty when switching.
        for (self.buf()) |*l| l.dirty = true;
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
                4 => entry.attrs.underline = true,
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

test "OSC 133 ; A records prompt mark" {
    var pool = try Pool.init(std.testing.allocator);
    defer pool.deinit();
    var s = try Screen.init(std.testing.allocator, &pool, 5, 3);
    defer s.deinit();
    s.row = 1;
    s.onOsc("133;A");
    try std.testing.expectEqual(@as(u16, 1), s.prompt_marks_len);
    try std.testing.expectEqual(@as(i32, 1), s.prompt_marks[0]);
    s.row = 2;
    s.onOsc("133;A");
    try std.testing.expectEqual(@as(u16, 2), s.prompt_marks_len);
    try std.testing.expectEqual(@as(i32, 2), s.prompt_marks[1]);
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

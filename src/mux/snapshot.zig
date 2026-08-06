//! Screen snapshot (de)serialization for mux attach.
//!
//! Lossless binary dump of the terminal state a reattaching client
//! needs: grid (active + alt + scrollback), style pool, hyperlinks,
//! grapheme clusters, cursor, modes, palette, title. Versioned and
//! little-endian like wire.zig.
//!
//! v2: image placements retained by the daemon's Screen
//! (`retain_images`) ride along, so reattach restores images.
//! v4: OSC 133 command state (open C marker, last zone, exit code,
//! completion sequence), so command waits survive resyncs.
//! v6: a format byte per glossary entry (glyf vs colrv0). A v5 peer
//! gets glyf entries only — its tail has no format field, so colrv0
//! payloads would be misread as glyf records.
//! v7: no field changes — it marks colrv1 support. A v6 peer's
//! `Format` enum has no tag 2, so its restore would reject the whole
//! snapshot; colrv1 entries are withheld from v6 bodies instead.

const std = @import("std");
const Screen = @import("../grid/screen.zig").Screen;
const Line = @import("../grid/line.zig").Line;
const Cell = @import("../grid/cell.zig").Cell;
const style_pool = @import("../grid/style_pool.zig");
const Pool = style_pool.Pool;

pub const SNAPSHOT_VERSION = 7;
pub const LEGACY_SNAPSHOT_VERSION = 3;

/// v5: byte budget for the Glyph Protocol glossary tail. Newest
/// registrations win when the lot would overflow (same policy as
/// `RETAIN_IMAGE_BUDGET` for image payloads). Worst case is 1024
/// slots x 64 KiB = 64 MiB, which no attach frame should carry.
pub const GLYPH_SNAPSHOT_BUDGET: usize = 8 * 1024 * 1024;

/// Select a snapshot body for a negotiated or historical core profile.
pub fn negotiateVersion(proto: u32, advertised_max: u8, negotiated: bool) u8 {
    if (proto == 0) return 0;
    if (negotiated) return @min(advertised_max, SNAPSHOT_VERSION);
    return if (proto >= 6) SNAPSHOT_VERSION else LEGACY_SNAPSHOT_VERSION;
}

/// Fixed-size OSC 133 state appended to every v4 snapshot.
const V4_COMMAND_TAIL_LEN: usize = 8 + 1 + 8 + 8 + 4 + 8;

const Sink = struct {
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn int(self: Sink, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try self.out.appendSlice(self.allocator, &tmp);
    }

    fn byte(self: Sink, b: u8) !void {
        try self.out.append(self.allocator, b);
    }

    fn boolean(self: Sink, b: bool) !void {
        try self.byte(if (b) 1 else 0);
    }

    fn bytes(self: Sink, b: []const u8) !void {
        try self.int(u32, @intCast(b.len));
        try self.out.appendSlice(self.allocator, b);
    }

    fn color(self: Sink, col: style_pool.Color) !void {
        switch (col) {
            .default => try self.byte(0),
            .palette => |p| {
                try self.byte(1);
                try self.byte(p);
            },
            .rgb => |r| {
                try self.byte(2);
                try self.byte(r.r);
                try self.byte(r.g);
                try self.byte(r.b);
            },
        }
    }

    fn f32x4(self: Sink, v: [4]f32) !void {
        for (v) |x| try self.int(u32, @bitCast(x));
    }

    fn line(self: Sink, ln: *const Line) !void {
        try self.int(u64, ln.id);
        try self.boolean(ln.continues_above);
        try self.byte(@intFromEnum(ln.scaling));
        try self.int(u16, @intCast(ln.cells.len));
        try self.out.appendSlice(self.allocator, std.mem.sliceAsBytes(ln.cells));
    }
};

/// Serialize `screen` (+ its pool) into `out`.
pub fn serialize(screen: *const Screen, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    return serializeVersion(screen, out, allocator, SNAPSHOT_VERSION);
}

/// Serialize a retained historical snapshot body for an older peer.
pub fn serializeVersion(screen: *const Screen, out: *std.ArrayList(u8), allocator: std.mem.Allocator, version: u32) !void {
    if (version < 1 or version > SNAPSHOT_VERSION)
        return error.UnsupportedSnapshotVersion;
    const s = Sink{ .out = out, .allocator = allocator };

    try s.int(u32, version);
    try s.int(u16, screen.cols);
    try s.int(u16, screen.rows);

    // Style pool. Cell.style_ref indexes this; must come first.
    const pool = screen.pool;
    try s.int(u16, @intCast(pool.entries.items.len));
    for (pool.entries.items) |e| {
        try s.color(e.fg);
        try s.color(e.bg);
        try s.color(e.underline_color);
        try s.int(u16, @bitCast(e.attrs));
    }

    // Grid: active, alt (optional), scrollback in logical order.
    for (screen.active) |*ln| try s.line(ln);
    try s.boolean(screen.alt != null);
    if (screen.alt) |alt| for (alt) |*ln| try s.line(ln);
    try s.boolean(screen.use_alt);
    const sb_count = screen.scrollbackCount();
    try s.int(u32, sb_count);
    var i: u32 = 0;
    while (i < sb_count) : (i += 1) try s.line(screen.scrollbackLine(i));

    // Cursor + per-screen state.
    try s.int(u16, screen.row);
    try s.int(u16, screen.col);
    try s.int(u16, screen.cur_style);
    try s.int(u16, screen.scroll_top);
    try s.int(u16, screen.scroll_bot);
    try s.boolean(screen.pending_wrap);
    try s.int(u64, screen.next_line_id);

    // Modes a client must agree on to interpret input correctly.
    try s.boolean(screen.autowrap);
    try s.boolean(screen.origin_mode);
    try s.boolean(screen.insert_mode);
    try s.boolean(screen.bracketed_paste);
    try s.boolean(screen.line_feed_mode);
    try s.boolean(screen.app_cursor_keys);
    try s.boolean(screen.app_keypad);
    try s.boolean(screen.cursor_visible);
    try s.byte(@intFromEnum(screen.cursor_shape));
    try s.int(u16, screen.mouse_mode);
    try s.boolean(screen.mouse_sgr);
    try s.byte(@intFromEnum(screen.mouse_enc));
    try s.boolean(screen.focus_reports);
    try s.boolean(screen.sync_output);
    // v3: a reattaching mirror must know these to emit the GUI-owned
    // reports (mode 2031 color-scheme) and agree on mode state.
    if (version >= 3) {
        try s.boolean(screen.mode_2031);
        try s.boolean(screen.in_band_resize);
    }

    // Colors + title.
    try s.f32x4(screen.default_fg);
    try s.f32x4(screen.default_bg);
    try s.f32x4(screen.cursor_color);
    try s.out.appendSlice(allocator, std.mem.sliceAsBytes(&screen.palette));
    try s.bytes(if (screen.last_title) |t| t else "");

    // Hyperlinks (OSC 8 side table).
    try s.int(u16, @intCast(screen.links.count()));
    var link_it = screen.links.iterator();
    while (link_it.next()) |kv| {
        try s.byte(kv.key_ptr.*);
        try s.bytes(kv.value_ptr.*);
    }
    try s.byte(screen.current_link_id);
    try s.byte(screen.next_link_id);

    // Grapheme clusters (combining marks on active rows).
    try s.int(u32, @intCast(screen.clusters.count()));
    var cl_it = screen.clusters.iterator();
    while (cl_it.next()) |kv| {
        try s.int(u32, kv.key_ptr.*);
        try s.int(u16, @intCast(kv.value_ptr.items.len));
        for (kv.value_ptr.items) |cp| try s.int(u32, cp);
    }

    // Prompt marks (OSC 133 navigation).
    try s.int(u16, screen.prompt_marks_len);
    for (screen.prompt_marks[0..screen.prompt_marks_len]) |m| try s.int(u64, m);

    // Image placements retained by the daemon (`retain_images`).
    // Newest-first budget pass keeps the freshest placements when
    // the lot would overflow the wire frame; emitted in original
    // order so z-equal stacking stays stable.
    if (version >= 2) {
        const items = screen.retained_images.items;
        var budget: usize = Screen.RETAIN_IMAGE_BUDGET;
        var first_kept: usize = items.len;
        while (first_kept > 0) {
            const need = items[first_kept - 1].owned.len;
            if (need > budget) break;
            budget -= need;
            first_kept -= 1;
        }
        try s.int(u32, @intCast(items.len - first_kept));
        for (items[first_kept..]) |ri| {
            const ev = ri.ev;
            try s.int(u32, ev.width);
            try s.int(u32, ev.height);
            try s.int(u16, ev.row);
            try s.int(u16, ev.col);
            try s.int(u32, ev.image_id);
            try s.int(u32, ev.placement_id);
            try s.int(i32, ev.z_index);
            try s.int(u32, ev.cells_wide);
            try s.int(u32, ev.cells_high);
            try s.int(u32, ev.src_x);
            try s.int(u32, ev.src_y);
            try s.int(u32, ev.src_w);
            try s.int(u32, ev.src_h);
            try s.bytes(ri.owned);
        }
    }

    // v4: OSC 133 command state, LAST in the stream so a v3 payload is
    // exactly a v4 one without this tail. Keeping an open C marker and
    // the completion sequence makes command waits survive mux resyncs.
    if (version >= 4) {
        try s.int(u64, screen.pending_output_start_id);
        try s.boolean(screen.pending_output_awaits_nl);
        try s.int(u64, screen.last_output_start_id);
        try s.int(u64, screen.last_output_end_id);
        try s.int(i32, screen.last_cmd_exit);
        try s.int(u64, screen.cmd_completion_seq);
    }

    // v5 tail: the Glyph Protocol glossary, so a client attaching
    // LATER still renders glyphs registered before it connected. An
    // empty glossary costs 4 bytes. Entries are budgeted newest-first
    // by insertion stamp; the stamps ride along so FIFO eviction
    // order survives the round-trip.
    if (version >= 5) {
        const GlyphEntry = struct { cp: u32, e: @import("../grid/glyph_glossary.zig").Entry };
        var entries: std.ArrayList(GlyphEntry) = .empty;
        defer entries.deinit(allocator);
        var git = screen.glyphs.map.iterator();
        while (git.next()) |kv| {
            // A v5 tail has no format field; a colrv0 payload written
            // there would restore as a glyf record and misrender. A
            // v6 peer knows format tags 0/1 only and rejects a body
            // carrying tag 2 outright — withhold colrv1 entries.
            if (version < 6 and kv.value_ptr.fmt != .glyf) continue;
            if (version < 7 and kv.value_ptr.fmt == .colrv1) continue;
            try entries.append(allocator, .{ .cp = kv.key_ptr.*, .e = kv.value_ptr.* });
        }
        std.mem.sort(GlyphEntry, entries.items, {}, struct {
            fn lt(_: void, a: GlyphEntry, b: GlyphEntry) bool {
                return a.e.insertion < b.e.insertion;
            }
        }.lt);
        var budget: usize = GLYPH_SNAPSHOT_BUDGET;
        var first_kept: usize = entries.items.len;
        while (first_kept > 0) {
            const need = entries.items[first_kept - 1].e.payload.len;
            if (need > budget) break;
            budget -= need;
            first_kept -= 1;
        }
        try s.int(u32, @intCast(entries.items.len - first_kept));
        for (entries.items[first_kept..]) |ge| {
            try s.int(u32, ge.cp);
            try s.int(u16, ge.e.upm);
            try s.byte(ge.e.width);
            if (version >= 6) try s.byte(@intFromEnum(ge.e.fmt));
            try s.int(u64, ge.e.insertion);
            try s.bytes(ge.e.payload);
        }
    }
}

pub const Envelope = struct {
    seq: u64,
    app: bool,
    body: []const u8,
};

/// Decode both the protocol 1-3 and protocol 4+ snapshot envelopes.
pub fn peelEnvelope(payload: []const u8) !Envelope {
    if (payload.len < 12) return error.Truncated;
    const seq = std.mem.readInt(u64, payload[0..8], .little);
    if (payload.len >= 13) {
        const version = std.mem.readInt(u32, payload[9..13], .little);
        if (version >= 1 and version <= SNAPSHOT_VERSION and payload[8] <= 1) {
            return .{ .seq = seq, .app = payload[8] != 0, .body = payload[9..] };
        }
    }
    const version = std.mem.readInt(u32, payload[8..12], .little);
    if (version < 1 or version > SNAPSHOT_VERSION) return error.SnapshotVersionMismatch;
    return .{ .seq = seq, .app = false, .body = payload[8..] };
}

const Src = struct {
    bytes: []const u8,
    pos: usize = 0,

    const Error = error{ Truncated, BadSnapshot, OutOfMemory };

    fn take(self: *Src, n: usize) Error![]const u8 {
        if (self.pos + n > self.bytes.len) return error.Truncated;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn int(self: *Src, comptime T: type) Error!T {
        const s = try self.take(@sizeOf(T));
        return std.mem.readInt(T, s[0..@sizeOf(T)], .little);
    }

    fn byte(self: *Src) Error!u8 {
        return (try self.take(1))[0];
    }

    fn boolean(self: *Src) Error!bool {
        return (try self.byte()) != 0;
    }

    fn color(self: *Src) Error!style_pool.Color {
        return switch (try self.byte()) {
            0 => .default,
            1 => .{ .palette = try self.byte() },
            2 => .{ .rgb = .{ .r = try self.byte(), .g = try self.byte(), .b = try self.byte() } },
            else => error.BadSnapshot,
        };
    }

    fn f32x4(self: *Src) Error![4]f32 {
        var v: [4]f32 = undefined;
        for (&v) |*x| x.* = @bitCast(try self.int(u32));
        return v;
    }

    /// Read a line into a fresh allocation owned by `allocator`, padded or
    /// truncated to exactly `cols` cells. Width normalization (rather than
    /// rejection) keeps snapshots from pre-normalization daemons — whose
    /// scrollback widths legitimately diverge after an alt-screen resize —
    /// attachable, while preserving the every-line-has-cols-cells invariant
    /// the scroll hot path relies on when recycling scrollback buffers.
    fn line(self: *Src, allocator: std.mem.Allocator, cols: u16, n_styles: u16) Error!Line {
        const id = try self.int(u64);
        const cont = try self.boolean();
        const scaling_raw = try self.byte();
        if (scaling_raw > 3) return error.BadSnapshot;
        const n_cells = try self.int(u16);
        const raw = try self.take(@as(usize, n_cells) * @sizeOf(Cell));
        const cells = allocator.alloc(Cell, cols) catch return error.OutOfMemory;
        errdefer allocator.free(cells);
        @memset(cells, .{});
        const keep = @min(n_cells, cols);
        @memcpy(std.mem.sliceAsBytes(cells[0..keep]), raw[0 .. @as(usize, keep) * @sizeOf(Cell)]);
        for (cells) |cell| {
            if (cell.style_ref >= n_styles) return error.BadSnapshot;
        }
        return .{
            .cells = cells,
            .dirty = true,
            .continues_above = cont,
            .id = id,
            .scaling = @enumFromInt(scaling_raw),
        };
    }
};

/// Restore a snapshot into a NEW Screen built on `pool` (whose
/// contents are replaced). Returns the Screen; caller owns it.
pub fn restore(allocator: std.mem.Allocator, pool: *Pool, bytes: []const u8) !*Screen {
    var src = Src{ .bytes = bytes };

    const version = try src.int(u32);
    // Historical bodies stay readable so a newer client can attach without
    // replacing the daemon that owns its durable sessions.
    if (version < 1 or version > SNAPSHOT_VERSION) return error.SnapshotVersionMismatch;
    const cols = try src.int(u16);
    const rows = try src.int(u16);
    if (cols == 0 or rows == 0 or cols > 4096 or rows > 4096) return error.BadSnapshot;

    // Pool: replace contents wholesale via replaceEntries, which also
    // rebuilds the dedup `index` map in lockstep. The grid reuses an
    // existing pool across resize/reattach snapshots, so just swapping
    // `entries` (and leaving `index` stale) would make the next interned
    // colour resolve to a slot it no longer occupies -- green renders as
    // red after a resize. replaceEntries is the same path compactStylePool
    // uses, so the index stays correct.
    const n_styles = try src.int(u16);
    if (n_styles == 0) return error.BadSnapshot; // index 0 = default always exists
    {
        var new_entries: std.ArrayList(style_pool.Entry) = .empty;
        errdefer new_entries.deinit(pool.allocator);
        try new_entries.ensureTotalCapacity(pool.allocator, n_styles);
        for (0..n_styles) |_| {
            const fg = try src.color();
            const bg = try src.color();
            const ul = try src.color();
            const attrs_raw = try src.int(u16);
            new_entries.appendAssumeCapacity(.{
                .fg = fg,
                .bg = bg,
                .underline_color = ul,
                .attrs = @bitCast(attrs_raw),
            });
        }
        pool.replaceEntries(new_entries); // adopts new_entries + rebuilds index
    }

    const screen = try Screen.init(allocator, pool, cols, rows);
    errdefer screen.deinit();

    // Active rows: swap each freshly-built line for the snapshot one.
    for (screen.active) |*ln| {
        const loaded = try src.line(allocator, cols, n_styles);
        ln.deinit(allocator);
        ln.* = loaded;
    }
    if (try src.boolean()) {
        const alt = try allocator.alloc(Line, rows);
        var done: usize = 0;
        errdefer {
            for (alt[0..done]) |*l| l.deinit(allocator);
            allocator.free(alt);
        }
        for (alt) |*ln| {
            ln.* = try src.line(allocator, cols, n_styles);
            done += 1;
        }
        screen.alt = alt;
    }
    screen.use_alt = try src.boolean();
    // The whole grid was just replaced under the cursor; anything
    // interpolating from its old position (the cursor trail) must
    // teleport rather than smear across content it never saw.
    screen.viewport_epoch +%= 1;

    const sb_count = try src.int(u32);
    try screen.scrollback.ensureTotalCapacity(allocator, sb_count);
    for (0..sb_count) |_| {
        const ln = try src.line(allocator, cols, n_styles);
        screen.scrollback.appendAssumeCapacity(ln);
    }
    screen.scrollback_head = 0;

    screen.row = @min(try src.int(u16), rows - 1);
    screen.col = @min(try src.int(u16), cols - 1);
    screen.cur_style = try src.int(u16);
    if (screen.cur_style >= n_styles) return error.BadSnapshot;
    screen.scroll_top = @min(try src.int(u16), rows - 1);
    screen.scroll_bot = @min(try src.int(u16), rows - 1);
    screen.pending_wrap = try src.boolean();
    screen.next_line_id = try src.int(u64);

    screen.autowrap = try src.boolean();
    screen.origin_mode = try src.boolean();
    screen.insert_mode = try src.boolean();
    screen.bracketed_paste = try src.boolean();
    screen.line_feed_mode = try src.boolean();
    screen.app_cursor_keys = try src.boolean();
    screen.app_keypad = try src.boolean();
    screen.cursor_visible = try src.boolean();
    screen.cursor_shape = std.enums.fromInt(@TypeOf(screen.cursor_shape), try src.byte()) orelse return error.BadSnapshot;
    screen.mouse_mode = try src.int(u16);
    screen.mouse_sgr = try src.boolean();
    screen.mouse_enc = std.enums.fromInt(@TypeOf(screen.mouse_enc), try src.byte()) orelse return error.BadSnapshot;
    screen.focus_reports = try src.boolean();
    screen.sync_output = try src.boolean();
    if (version >= 3) {
        screen.mode_2031 = try src.boolean();
        screen.in_band_resize = try src.boolean();
    }

    screen.default_fg = try src.f32x4();
    screen.default_bg = try src.f32x4();
    screen.cursor_color = try src.f32x4();
    const pal_raw = try src.take(@sizeOf(@TypeOf(screen.palette)));
    @memcpy(std.mem.asBytes(&screen.palette), pal_raw);
    const title_len = try src.int(u32);
    if (title_len > 0) {
        const t = try src.take(title_len);
        screen.last_title = try allocator.dupe(u8, t);
    }

    const n_links = try src.int(u16);
    for (0..n_links) |_| {
        const key = try src.byte();
        const uri_len = try src.int(u32);
        const uri = try src.take(uri_len);
        const copy = try allocator.dupe(u8, uri);
        errdefer allocator.free(copy);
        try screen.links.put(key, copy);
    }
    screen.current_link_id = try src.byte();
    screen.next_link_id = try src.byte();

    const n_clusters = try src.int(u32);
    for (0..n_clusters) |_| {
        const key = try src.int(u32);
        const n_cps = try src.int(u16);
        var list: std.ArrayList(u32) = .empty;
        errdefer list.deinit(allocator);
        try list.ensureTotalCapacity(allocator, n_cps);
        for (0..n_cps) |_| list.appendAssumeCapacity(try src.int(u32));
        try screen.clusters.put(key, list);
    }

    screen.prompt_marks_len = @min(try src.int(u16), screen.prompt_marks.len);
    for (0..screen.prompt_marks_len) |idx| screen.prompt_marks[idx] = try src.int(u64);

    // Retained image placements — parked on the screen; the client
    // replays them into its image sink once a pane is wired
    // (Terminal.replayRetainedImages) and then frees them.
    var n_images: u32 = if (version >= 2) try src.int(u32) else 0;
    // A transitional v4 writer shipped before the command-state format was
    // finalized. Its legacy u32 occupies the slot now used by n_images and is
    // followed immediately by the fixed 37-byte command tail. When non-zero,
    // current readers mistake it for an image count and run off the end of the
    // snapshot with Truncated. The shape is unambiguous: even one legitimate
    // image needs metadata beyond the tail, so a non-zero count with exactly
    // the tail remaining can only be that legacy v4 form. A zero legacy value
    // already decodes normally as zero images.
    if (version == 4 and n_images != 0 and src.bytes.len - src.pos == V4_COMMAND_TAIL_LEN)
        n_images = 0;
    for (0..n_images) |_| {
        var ev = Screen.ImageEvent{
            .width = try src.int(u32),
            .height = try src.int(u32),
            .rgba = &.{},
            .row = try src.int(u16),
            .col = try src.int(u16),
            .image_id = try src.int(u32),
            .placement_id = try src.int(u32),
            .z_index = try src.int(i32),
            .cells_wide = try src.int(u32),
            .cells_high = try src.int(u32),
            .src_x = try src.int(u32),
            .src_y = try src.int(u32),
            .src_w = try src.int(u32),
            .src_h = try src.int(u32),
        };
        const data_len = try src.int(u32);
        const data = try src.take(data_len);
        const owned = try allocator.dupe(u8, data);
        errdefer allocator.free(owned);
        ev.rgba = owned;
        try screen.retained_images.append(allocator, .{ .ev = ev, .owned = owned });
        screen.retained_image_bytes += owned.len;
    }

    // v4 tail: OSC 133 command state. A v3 payload simply ends here;
    // the fields keep their zero defaults (no completed zone known).
    if (version >= 4) {
        screen.pending_output_start_id = try src.int(u64);
        screen.pending_output_awaits_nl = try src.boolean();
        screen.last_output_start_id = try src.int(u64);
        screen.last_output_end_id = try src.int(u64);
        screen.last_cmd_exit = try src.int(i32);
        screen.cmd_completion_seq = try src.int(u64);
    }

    // v5 tail: Glyph Protocol glossary. `registerRestored` re-mints
    // render keys locally (foreign keys are meaningless in this
    // process) while keeping the FIFO insertion stamps. v6 adds the
    // per-entry format byte; a v5 body is glyf-only by construction.
    if (version >= 5) {
        const gp = @import("../parser/glyph_protocol.zig");
        const n_glyphs = try src.int(u32);
        for (0..n_glyphs) |_| {
            const cp = try src.int(u32);
            const upm = try src.int(u16);
            const width = try src.byte();
            const fmt: gp.Format = if (version >= 6)
                std.enums.fromInt(gp.Format, try src.byte()) orelse return error.BadSnapshot
            else
                .glyf;
            const insertion = try src.int(u64);
            const plen = try src.int(u32);
            const pdata = try src.take(plen);
            if (upm == 0 or (width != 1 and width != 2) or plen == 0) return error.BadSnapshot;
            const owned = allocator.dupe(u8, pdata) catch return error.OutOfMemory;
            screen.glyphs.registerRestored(cp, owned, fmt, upm, width, insertion) catch return error.BadSnapshot;
        }
    }

    screen.dirty = true;
    return screen;
}

// ── tests ───────────────────────────────────────────────────────

const testing = std.testing;
const Harness = @import("../parser/test_harness.zig").Harness;

test "restore rebuilds the pool index: colours don't swap after a resize" {
    const a = testing.allocator;
    const Entry = style_pool.Entry;

    // Source screen: green THEN red, so its pool orders green at a lower
    // slot than red. The snapshot serializes that order.
    var h = try Harness.init(a, 10, 2);
    defer h.deinit();
    h.feed("\x1b[32mG\x1b[0m\x1b[31mR\x1b[0m");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(h.screen, &buf, a);

    const green = h.pool.get(h.screen.active[0].cells[0].style_ref);
    const red = h.pool.get(h.screen.active[0].cells[1].style_ref);
    try testing.expect(!Entry.equal(green, red));

    // Target pool pre-populated in the OPPOSITE order (red before green),
    // exactly like a GUI pool reused across a resize: its dedup index now
    // disagrees with the snapshot's slot ordering.
    var p = try Pool.init(a);
    defer p.deinit();
    _ = try p.intern(red);
    _ = try p.intern(green);

    const back = try restore(a, &p, buf.items);
    defer back.deinit();

    // The bug: a stale index made the next intern of a colour return the
    // wrong slot (green -> red). After restore, interning a colour must
    // land on a slot that actually holds it, with no duplicate appended.
    try testing.expect(Entry.equal(p.get(try p.intern(green)), green));
    try testing.expect(Entry.equal(p.get(try p.intern(red)), red));
    try testing.expectEqual(h.pool.entries.items.len, p.entries.items.len);
}

test "snapshot: populated screen round-trips" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();
    const screen = h.screen;

    // Content with styles, a title, scrollback spill, and modes.
    h.feed("\x1b[31mred\x1b[0m plain\r\n");
    h.feed("\x1b[1;4:3;58:2::10:20:30mfancy\x1b[0m\r\n");
    var i: usize = 0;
    while (i < 10) : (i += 1) h.feed("scroll line\r\n");
    h.feed("\x1b]0;snap title\x07");
    h.feed("\x1b[?2004h");
    h.feed("\x1b]8;;https://sker.dev\x07link\x1b]8;;\x07");
    h.feed("\r\x1b]133;A\x07\x1b]133;C\x07command output\r\n\x1b]133;D;7\x07");
    h.feed("\x1b]133;C\x07");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(screen, &buf, a);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expectEqual(screen.cols, back.cols);
    try testing.expectEqual(screen.rows, back.rows);
    try testing.expectEqual(screen.row, back.row);
    try testing.expectEqual(screen.col, back.col);
    try testing.expectEqual(screen.scrollbackCount(), back.scrollbackCount());
    try testing.expectEqual(screen.bracketed_paste, back.bracketed_paste);
    try testing.expectEqual(screen.pending_output_start_id, back.pending_output_start_id);
    try testing.expectEqual(screen.pending_output_awaits_nl, back.pending_output_awaits_nl);
    try testing.expectEqual(screen.last_output_start_id, back.last_output_start_id);
    try testing.expectEqual(screen.last_output_end_id, back.last_output_end_id);
    try testing.expectEqual(screen.last_cmd_exit, back.last_cmd_exit);
    try testing.expectEqual(screen.cmd_completion_seq, back.cmd_completion_seq);
    try testing.expectEqualStrings("snap title", back.last_title.?);
    try testing.expectEqual(h.pool.entries.items.len, pool2.entries.items.len);

    // Cell-exact grid equality, active + scrollback.
    for (screen.active, back.active) |*orig, *got| {
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(orig.cells), std.mem.sliceAsBytes(got.cells));
        try testing.expectEqual(orig.id, got.id);
        try testing.expectEqual(orig.continues_above, got.continues_above);
    }
    var sb: u32 = 0;
    while (sb < screen.scrollbackCount()) : (sb += 1) {
        const orig = screen.scrollbackLine(sb);
        const got = back.scrollbackLine(sb);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(orig.cells), std.mem.sliceAsBytes(got.cells));
    }

    // Link table survived.
    try testing.expectEqual(screen.links.count(), back.links.count());

    // Extracted text identical (belt + suspenders over the cell dump).
    const txt_a = try screen.extractScreen(a);
    defer a.free(txt_a);
    const txt_b = try back.extractScreen(a);
    defer a.free(txt_b);
    try testing.expectEqualStrings(txt_a, txt_b);
}

test "snapshot: v3 payload (no command tail) restores with defaults" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();
    h.feed("\x1b]133;A\x07\x1b]133;C\x07out\r\n\x1b]133;D;7\x07");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, 4);

    // A v3 payload is exactly a v4 one without the 37-byte command
    // tail — chop it off and stamp version 3.
    const tail = V4_COMMAND_TAIL_LEN;
    const legacy = try a.dupe(u8, buf.items[0 .. buf.items.len - tail]);
    defer a.free(legacy);
    std.mem.writeInt(u32, legacy[0..4], 3, .little);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, legacy);
    defer back.deinit();
    try testing.expectEqual(@as(u64, 0), back.cmd_completion_seq);
    try testing.expectEqual(@as(i32, 0), back.last_cmd_exit);
    try testing.expectEqual(@as(u64, 0), back.last_output_start_id);

    // And a v4 payload with the tail MISSING is corrupt, not v3.
    var pool3 = try Pool.init(a);
    defer pool3.deinit();
    try testing.expectError(error.Truncated, restore(a, &pool3, buf.items[0 .. buf.items.len - tail]));
}

test "snapshot: serializer targets v3 for legacy peers" {
    const a = testing.allocator;
    var h = try Harness.init(a, 8, 2);
    defer h.deinit();
    h.feed("legacy");
    h.screen.cmd_completion_seq = 42;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, LEGACY_SNAPSHOT_VERSION);
    try testing.expectEqual(LEGACY_SNAPSHOT_VERSION, std.mem.readInt(u32, buf.items[0..4], .little));

    var pool = try Pool.init(a);
    defer pool.deinit();
    const restored = try restore(a, &pool, buf.items);
    defer restored.deinit();
    try testing.expectEqual(@as(u64, 0), restored.cmd_completion_seq);
}

test "snapshot: v1 and v2 bodies remain readable" {
    const a = testing.allocator;
    var h = try Harness.init(a, 8, 2);
    defer h.deinit();
    h.feed("old");
    h.screen.mode_2031 = true;

    for ([_]u32{ 1, 2 }) |version| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try serializeVersion(h.screen, &buf, a, version);
        var pool = try Pool.init(a);
        defer pool.deinit();
        const restored = try restore(a, &pool, buf.items);
        defer restored.deinit();
        try testing.expect(!restored.mode_2031);
    }
}

test "snapshot: envelope detects pre-v4 and current headers" {
    var legacy: [12]u8 = @splat(0);
    std.mem.writeInt(u64, legacy[0..8], 17, .little);
    std.mem.writeInt(u32, legacy[8..12], LEGACY_SNAPSHOT_VERSION, .little);
    const old = try peelEnvelope(&legacy);
    try testing.expectEqual(@as(u64, 17), old.seq);
    try testing.expect(!old.app);
    try testing.expectEqualSlices(u8, legacy[8..], old.body);

    var current: [13]u8 = @splat(0);
    std.mem.writeInt(u64, current[0..8], 23, .little);
    current[8] = 1;
    std.mem.writeInt(u32, current[9..13], SNAPSHOT_VERSION, .little);
    const modern = try peelEnvelope(&current);
    try testing.expectEqual(@as(u64, 23), modern.seq);
    try testing.expect(modern.app);
    try testing.expectEqualSlices(u8, current[9..], modern.body);
}

test "snapshot: negotiation honors the peer maximum" {
    try testing.expectEqual(@as(u8, 3), negotiateVersion(6, 3, true));
    try testing.expectEqual(@as(u8, 4), negotiateVersion(6, 4, true));
    try testing.expectEqual(@as(u8, 3), negotiateVersion(5, 0, false));
    try testing.expectEqual(@as(u8, 0), negotiateVersion(0, 4, true));
}

test "snapshot: transitional v4 legacy field is not an image count" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();
    h.feed("legacy v4 screen\r\n");
    h.screen.pending_output_start_id = 111;
    h.screen.pending_output_awaits_nl = true;
    h.screen.last_output_start_id = 222;
    h.screen.last_output_end_id = 333;
    h.screen.last_cmd_exit = 7;
    h.screen.cmd_completion_seq = 444;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, 4);
    try testing.expectEqual(@as(usize, 0), h.screen.retained_images.items.len);

    // The transitional writer put a legacy non-zero u32 immediately before
    // the same 37-byte command tail. Reproduce a value observed in a live,
    // still-running daemon; the finalized writer has zero here (n_images).
    const legacy_field_pos = buf.items.len - V4_COMMAND_TAIL_LEN - @sizeOf(u32);
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf.items[legacy_field_pos..][0..4], .little));
    std.mem.writeInt(u32, buf.items[legacy_field_pos..][0..4], 208, .little);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 0), back.retained_images.items.len);
    try testing.expectEqual(@as(u64, 111), back.pending_output_start_id);
    try testing.expect(back.pending_output_awaits_nl);
    try testing.expectEqual(@as(u64, 222), back.last_output_start_id);
    try testing.expectEqual(@as(u64, 333), back.last_output_end_id);
    try testing.expectEqual(@as(i32, 7), back.last_cmd_exit);
    try testing.expectEqual(@as(u64, 444), back.cmd_completion_seq);
}

test "snapshot: retained image placements round-trip" {
    const a = testing.allocator;
    var h = try Harness.init(a, 20, 6);
    defer h.deinit();
    h.screen.retain_images = true;

    // 1x1 RGBA kitty transmit+place (t=d, base64 of 4 bytes).
    h.feed("\x1b[3;4H"); // place at row 2, col 3 (0-based)
    h.feed("\x1b_Gf=32,s=1,v=1,t=d,a=T,i=9,p=2,z=5;/wAA/w==\x1b\\");
    try testing.expectEqual(@as(usize, 1), h.screen.retained_images.items.len);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(h.screen, &buf, a);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 1), back.retained_images.items.len);
    const ri = back.retained_images.items[0];
    try testing.expectEqual(@as(u32, 9), ri.ev.image_id);
    try testing.expectEqual(@as(u32, 2), ri.ev.placement_id);
    try testing.expectEqual(@as(i32, 5), ri.ev.z_index);
    try testing.expectEqual(@as(u16, 2), ri.ev.row);
    try testing.expectEqual(@as(u16, 3), ri.ev.col);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0, 0, 0xff }, ri.owned);

    // Delete prunes the retained copy too.
    h.feed("\x1b_Ga=d,d=I,i=9\x1b\\");
    try testing.expectEqual(@as(usize, 0), h.screen.retained_images.items.len);
}

test "snapshot: alt screen state survives" {
    const a = testing.allocator;
    var h = try Harness.init(a, 10, 4);
    defer h.deinit();
    const screen = h.screen;

    h.feed("main\r\n");
    h.feed("\x1b[?1049h"); // enter alt
    h.feed("altscreen");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(screen, &buf, a);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expect(back.use_alt);
    try testing.expect(back.alt != null);
    const txt = try back.extractScreen(a);
    defer a.free(txt);
    try testing.expect(std.mem.indexOf(u8, txt, "altscreen") != null);
}

test "snapshot: corrupt input errors cleanly" {
    const a = testing.allocator;
    var pool = try Pool.init(a);
    defer pool.deinit();
    // Empty.
    try testing.expectError(error.Truncated, restore(a, &pool, &.{}));
    // Bad version.
    var bad: [8]u8 = .{ 9, 9, 9, 9, 1, 0, 1, 0 };
    try testing.expectError(error.SnapshotVersionMismatch, restore(a, &pool, &bad));
    // Truncated mid-grid: serialize real state then chop it.
    var h = try Harness.init(a, 8, 3);
    defer h.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(h.screen, &buf, a);
    var pool3 = try Pool.init(a);
    defer pool3.deinit();
    try testing.expectError(error.Truncated, restore(a, &pool3, buf.items[0 .. buf.items.len / 2]));

    // Locate the first serialized cell and give it a style reference beyond
    // the advertised pool. Restore must reject it before render-side Pool.get.
    var src = Src{ .bytes = buf.items };
    _ = try src.int(u32); // version
    _ = try src.int(u16); // cols
    _ = try src.int(u16); // rows
    const n_styles = try src.int(u16);
    for (0..n_styles) |_| {
        _ = try src.color();
        _ = try src.color();
        _ = try src.color();
        _ = try src.int(u16);
    }
    _ = try src.int(u64);
    _ = try src.boolean();
    _ = try src.byte();
    _ = try src.int(u16);
    const style_off = src.pos + @offsetOf(Cell, "style_ref");
    std.mem.writeInt(u16, buf.items[style_off..][0..2], n_styles, .little);
    var pool4 = try Pool.init(a);
    defer pool4.deinit();
    try testing.expectError(error.BadSnapshot, restore(a, &pool4, buf.items));
}

test "restore normalizes lines whose serialized width diverges from cols" {
    const a = testing.allocator;
    var wide: Cell = .{};
    wide.rune = 'W';
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try w.writer.writeInt(u64, 7, .little); // id
    try w.writer.writeByte(0); // continues_above
    try w.writer.writeByte(0); // scaling
    try w.writer.writeInt(u16, 5, .little); // n_cells: wider than cols
    for (0..5) |_| try w.writer.writeAll(std.mem.asBytes(&wide));
    var src = Src{ .bytes = w.writer.buffered() };
    var narrow = try src.line(a, 3, 1);
    defer narrow.deinit(a);
    try testing.expectEqual(@as(usize, 3), narrow.cells.len);
    try testing.expectEqual(@as(u32, 'W'), narrow.cells[0].rune);

    var src2 = Src{ .bytes = w.writer.buffered() };
    var padded = try src2.line(a, 8, 1);
    defer padded.deinit(a);
    try testing.expectEqual(@as(usize, 8), padded.cells.len);
    try testing.expectEqual(@as(u32, 'W'), padded.cells[4].rune);
    try testing.expectEqual(@as(u32, 0), padded.cells[5].rune);
}

test "snapshot: glyph glossary round-trips with FIFO stamps" {
    const a = testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();

    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    const p1 = try a.dupe(u8, tri);
    try h.screen.glyphs.registerAdopt(0xE100, p1, .glyf, 1000, 1);
    const container = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = gp.PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(container);
    const p2 = try a.dupe(u8, container);
    try h.screen.glyphs.registerAdopt(0xF0100, p2, .colrv0, 2048, 2);
    const solid = gp.V1Node{ .solid = .{ .palette = gp.PALETTE_FOREGROUND } };
    const v1_container = try gp.colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &solid },
    }, &.{}, null);
    defer a.free(v1_container);
    const p3 = try a.dupe(u8, v1_container);
    try h.screen.glyphs.registerAdopt(0x100100, p3, .colrv1, 1024, 1);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serialize(h.screen, &buf, a);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();

    try testing.expectEqual(@as(usize, 3), back.glyphs.count());
    const e3 = back.glyphs.get(0x100100).?;
    try testing.expectEqual(gp.Format.colrv1, e3.fmt);
    try testing.expectEqual(@as(u16, 1024), e3.upm);
    try testing.expectEqualSlices(u8, v1_container, e3.payload);
    const e1 = back.glyphs.get(0xE100).?;
    try testing.expectEqualSlices(u8, tri, e1.payload);
    try testing.expectEqual(@as(u16, 1000), e1.upm);
    try testing.expectEqual(@as(u8, 1), e1.width);
    try testing.expectEqual(gp.Format.glyf, e1.fmt);
    const e2 = back.glyphs.get(0xF0100).?;
    try testing.expectEqual(@as(u16, 2048), e2.upm);
    try testing.expectEqual(@as(u8, 2), e2.width);
    try testing.expectEqual(gp.Format.colrv0, e2.fmt);
    try testing.expectEqualSlices(u8, container, e2.payload);
    // FIFO order preserved across the round-trip.
    try testing.expect(e1.insertion < e2.insertion);
    // Render keys are freshly minted locally, never zero.
    try testing.expect(e1.render_key != 0 and e2.render_key != 0);
    try testing.expect(e1.render_key != e2.render_key);
}

test "snapshot: a v5 body carries only glyf entries (no format field to ride)" {
    const a = testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();

    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    const p1 = try a.dupe(u8, tri);
    try h.screen.glyphs.registerAdopt(0xE100, p1, .glyf, 1000, 1);
    const container = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = gp.PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(container);
    const p2 = try a.dupe(u8, container);
    try h.screen.glyphs.registerAdopt(0xF0100, p2, .colrv0, 1000, 1);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, 5);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 1), back.glyphs.count());
    try testing.expect(back.glyphs.contains(0xE100));
    try testing.expect(!back.glyphs.contains(0xF0100));
}

test "snapshot: a v6 body withholds colrv1 entries (v6 peers reject tag 2)" {
    const a = testing.allocator;
    const gp = @import("../parser/glyph_protocol.zig");
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();

    const tri = try gp.triangleBytes(a);
    defer a.free(tri);
    const p1 = try a.dupe(u8, tri);
    try h.screen.glyphs.registerAdopt(0xE100, p1, .glyf, 1000, 1);
    const container = try gp.colrContainerBytes(a, &.{tri}, &.{
        .{ .glyph = 0, .palette = gp.PALETTE_FOREGROUND },
    }, &.{});
    defer a.free(container);
    const p2 = try a.dupe(u8, container);
    try h.screen.glyphs.registerAdopt(0xF0100, p2, .colrv0, 1000, 1);
    const solid = gp.V1Node{ .solid = .{ .palette = gp.PALETTE_FOREGROUND } };
    const v1_container = try gp.colr1ContainerBytes(a, &.{tri}, .{
        .glyph = .{ .glyph_id = 0, .child = &solid },
    }, &.{}, null);
    defer a.free(v1_container);
    const p3 = try a.dupe(u8, v1_container);
    try h.screen.glyphs.registerAdopt(0x100100, p3, .colrv1, 1000, 1);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try serializeVersion(h.screen, &buf, a, 6);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, buf.items);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 2), back.glyphs.count());
    try testing.expect(back.glyphs.contains(0xE100));
    try testing.expect(back.glyphs.contains(0xF0100));
    try testing.expect(!back.glyphs.contains(0x100100));
}

test "snapshot: empty glossary costs 4 bytes; v4 bodies restore empty" {
    const a = testing.allocator;
    var h = try Harness.init(a, 10, 3);
    defer h.deinit();

    var v4buf: std.ArrayList(u8) = .empty;
    defer v4buf.deinit(a);
    try serializeVersion(h.screen, &v4buf, a, 4);
    var v5buf: std.ArrayList(u8) = .empty;
    defer v5buf.deinit(a);
    try serialize(h.screen, &v5buf, a);
    // Only the u32 count separates an empty-glossary v5+/v6 from a v4.
    try testing.expectEqual(v4buf.items.len + 4, v5buf.items.len);

    var pool2 = try Pool.init(a);
    defer pool2.deinit();
    const back = try restore(a, &pool2, v4buf.items);
    defer back.deinit();
    try testing.expectEqual(@as(usize, 0), back.glyphs.count());
}

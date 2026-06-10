//! Screen snapshot (de)serialization for mux attach.
//!
//! Lossless binary dump of the terminal state a reattaching client
//! needs: grid (active + alt + scrollback), style pool, hyperlinks,
//! grapheme clusters, cursor, modes, palette, title. Versioned and
//! little-endian like wire.zig.
//!
//! v2: image placements retained by the daemon's Screen
//! (`retain_images`) ride along, so reattach restores images.

const std = @import("std");
const Screen = @import("../grid/screen.zig").Screen;
const Line = @import("../grid/line.zig").Line;
const Cell = @import("../grid/cell.zig").Cell;
const style_pool = @import("../grid/style_pool.zig");
const Pool = style_pool.Pool;

pub const SNAPSHOT_VERSION: u32 = 2;

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
    const s = Sink{ .out = out, .allocator = allocator };

    try s.int(u32, SNAPSHOT_VERSION);
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

    /// Read a line into a fresh allocation owned by `allocator`.
    fn line(self: *Src, allocator: std.mem.Allocator) Error!Line {
        const id = try self.int(u64);
        const cont = try self.boolean();
        const scaling_raw = try self.byte();
        if (scaling_raw > 3) return error.BadSnapshot;
        const n_cells = try self.int(u16);
        const cells = allocator.alloc(Cell, n_cells) catch return error.OutOfMemory;
        errdefer allocator.free(cells);
        const raw = try self.take(@as(usize, n_cells) * @sizeOf(Cell));
        @memcpy(std.mem.sliceAsBytes(cells), raw);
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
    if (version != SNAPSHOT_VERSION) return error.SnapshotVersionMismatch;
    const cols = try src.int(u16);
    const rows = try src.int(u16);
    if (cols == 0 or rows == 0 or cols > 4096 or rows > 4096) return error.BadSnapshot;

    // Pool: replace contents wholesale.
    const n_styles = try src.int(u16);
    if (n_styles == 0) return error.BadSnapshot; // index 0 = default always exists
    pool.entries.clearRetainingCapacity();
    for (0..n_styles) |_| {
        const fg = try src.color();
        const bg = try src.color();
        const ul = try src.color();
        const attrs_raw = try src.int(u16);
        try pool.entries.append(pool.allocator, .{
            .fg = fg,
            .bg = bg,
            .underline_color = ul,
            .attrs = @bitCast(attrs_raw),
        });
    }
    pool.last_idx = 0;

    const screen = try Screen.init(allocator, pool, cols, rows);
    errdefer screen.deinit();

    // Active rows: swap each freshly-built line for the snapshot one.
    for (screen.active) |*ln| {
        var loaded = try src.line(allocator);
        if (loaded.cells.len != cols) {
            loaded.deinit(allocator);
            return error.BadSnapshot;
        }
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
            ln.* = try src.line(allocator);
            done += 1;
            if (ln.cells.len != cols) return error.BadSnapshot;
        }
        screen.alt = alt;
    }
    screen.use_alt = try src.boolean();

    const sb_count = try src.int(u32);
    try screen.scrollback.ensureTotalCapacity(allocator, sb_count);
    for (0..sb_count) |_| {
        const ln = try src.line(allocator);
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
    const n_images = try src.int(u32);
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

    screen.dirty = true;
    return screen;
}

// ── tests ───────────────────────────────────────────────────────

const testing = std.testing;
const Harness = @import("../parser/test_harness.zig").Harness;

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
}

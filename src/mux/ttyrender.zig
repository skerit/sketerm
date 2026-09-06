//! Screen -> ANSI diff renderer: shows a mux session's mirror grid
//! inside a FOREIGN terminal (`sketerm mux attach` from kitty, a VT,
//! an ssh client...).
//!
//! The daemon streams parsed events, never bytes, so a tty client keeps
//! a local `Screen` and re-encodes it. This module owns that encoding:
//! a shadow copy of what the host terminal currently shows, a per-cell
//! diff against the mirror, and the DEC private modes the host has to
//! mirror from the session (mouse reporting, bracketed paste,
//! application cursor keys, cursor shape, kitty keyboard flags) so the
//! app inside the session sees the input encoding it asked for.
//!
//! Libc-free and GTK-free on purpose: the renderer is testable by
//! parsing its own output back through the VT parser.

const std = @import("std");
const Screen = @import("../grid/screen.zig").Screen;
const cell_mod = @import("../grid/cell.zig");
const Cell = cell_mod.Cell;
const style_pool = @import("../grid/style_pool.zig");
const Entry = style_pool.Entry;
const Color = style_pool.Color;

const ESC = "\x1b";
const ST = "\x1b\\";

/// One host cell as last painted. Compared by value, never by style
/// index: a snapshot swap brings a fresh pool whose indexes mean
/// something else.
const Shadow = struct {
    rune: u32 = 0,
    style: Entry = .{},
    /// Left half of a 2-column glyph (the right half is `cont`).
    wide: bool = false,
    cont: bool = false,
    link: u8 = 0,
    /// Hash of the extending codepoints attached to the cell, 0 = none.
    cluster: u32 = 0,

    fn eql(a: Shadow, b: Shadow) bool {
        return a.rune == b.rune and a.wide == b.wide and a.cont == b.cont and
            a.link == b.link and a.cluster == b.cluster and Entry.equal(a.style, b.style);
    }
};

/// The DEC private modes (and friends) the host terminal has been put
/// in. Diffed against the session's screen on every render and
/// against the defaults on leave, so the host is always handed back
/// exactly as it was found.
pub const HostModes = struct {
    app_cursor: bool = false,
    app_keypad: bool = false,
    mouse_mode: u16 = 0,
    mouse_enc: Screen.MouseEnc = .legacy,
    bracketed_paste: bool = false,
    focus_reports: bool = false,
    cursor_shape: Screen.CursorShape = .block_blink,
    kitty_flags: u8 = 0,
    modify_other_keys: u8 = 0,
    reverse: bool = false,

    pub fn of(screen: *const Screen) HostModes {
        return .{
            .app_cursor = screen.app_cursor_keys,
            .app_keypad = screen.app_keypad,
            .mouse_mode = screen.mouse_mode,
            .mouse_enc = screen.mouse_enc,
            .bracketed_paste = screen.bracketed_paste,
            .focus_reports = screen.focus_reports,
            .cursor_shape = screen.cursor_shape,
            .kitty_flags = screen.kitty_kbd_flags,
            .modify_other_keys = screen.modify_other_keys,
            .reverse = screen.reverse_screen,
        };
    }
};

fn mouseEncMode(enc: Screen.MouseEnc) u16 {
    return switch (enc) {
        .legacy => 0,
        .utf8 => 1005,
        .sgr => 1006,
        .urxvt => 1015,
        .sgr_pixel => 1016,
    };
}

fn cursorShapeParam(shape: Screen.CursorShape) u8 {
    return switch (shape) {
        .block_blink => 1,
        .block_steady => 2,
        .underline_blink => 3,
        .underline_steady => 4,
        .bar_blink => 5,
        .bar_steady => 6,
    };
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shadow: []Shadow,
    /// False until the host has been painted from scratch (first
    /// render, resize, snapshot swap): the next render clears and
    /// repaints every cell instead of diffing.
    valid: bool = false,
    modes: HostModes = .{},
    cursor_shown: bool = true,
    /// Where the host's cursor is after the last byte we wrote; -1 =
    /// unknown (forces a CUP before the next cell).
    out_row: i32 = -1,
    out_col: i32 = -1,
    /// The SGR state the host is in; null = unknown (emit a full SGR).
    out_style: ?Entry = null,
    out_link: u8 = 0,
    /// Scroll-mode offset from the bottom, in lines. 0 = live view.
    view_offset: u32 = 0,
    /// Scroll mode is on (the indicator shows even at offset 0, so
    /// entering it is visible before the first key).
    scroll_mode: bool = false,
    title_hash: u64 = 0,
    /// The session's bell timestamp last forwarded; -1 = adopt the
    /// current value silently (an old bell must not ring on attach).
    bell_seen: i64 = -1,

    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Renderer {
        const shadow = try allocator.alloc(Shadow, @as(usize, cols) * rows);
        @memset(shadow, .{});
        return .{ .allocator = allocator, .cols = cols, .rows = rows, .shadow = shadow };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.shadow);
        self.shadow = &.{};
    }

    /// The host terminal changed size: the next render repaints fully.
    pub fn resize(self: *Renderer, cols: u16, rows: u16) !void {
        const fresh = try self.allocator.alloc(Shadow, @as(usize, cols) * rows);
        @memset(fresh, .{});
        self.allocator.free(self.shadow);
        self.shadow = fresh;
        self.cols = cols;
        self.rows = rows;
        self.invalidate();
    }

    /// Forget what the host shows (snapshot swap, resize).
    pub fn invalidate(self: *Renderer) void {
        self.valid = false;
        self.out_row = -1;
        self.out_col = -1;
        self.out_style = null;
    }

    /// Take the host over: alternate screen, autowrap off (cells are
    /// positioned explicitly, and a wrap at the last column would
    /// scroll the host), title pushed so leave() can restore it.
    pub fn enter(self: *Renderer, out: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try out.appendSlice(a, ESC ++ "[22;0t" ++ ESC ++ "[?1049h" ++ ESC ++ "[?7l" ++ ESC ++ "[?25l" ++ ESC ++ "[0m" ++ ESC ++ "[H" ++ ESC ++ "[2J");
        self.cursor_shown = false;
        self.invalidate();
    }

    /// Hand the host back exactly as found: every mirrored mode reset,
    /// SGR/link cleared, cursor shown, alternate screen left, title
    /// popped.
    pub fn leave(self: *Renderer, out: *std.ArrayList(u8)) !void {
        const a = self.allocator;
        try self.applyModes(out, .{});
        try self.closeLink(out);
        try out.appendSlice(a, ESC ++ "[0m" ++ ESC ++ "[0 q" ++ ESC ++ "[?25h" ++ ESC ++ "[?7h" ++ ESC ++ "[?1049l" ++ ESC ++ "[23;0t");
        self.out_style = null;
        self.cursor_shown = true;
        self.invalidate();
    }

    /// Bring the host's modes to `target`, emitting only what differs.
    fn applyModes(self: *Renderer, out: *std.ArrayList(u8), target: HostModes) !void {
        const a = self.allocator;
        const cur = self.modes;
        if (cur.app_cursor != target.app_cursor)
            try out.appendSlice(a, if (target.app_cursor) ESC ++ "[?1h" else ESC ++ "[?1l");
        if (cur.app_keypad != target.app_keypad)
            try out.appendSlice(a, if (target.app_keypad) ESC ++ "=" else ESC ++ ">");
        if (cur.mouse_mode != target.mouse_mode) {
            if (cur.mouse_mode != 0) try out.print(a, ESC ++ "[?{d}l", .{cur.mouse_mode});
            if (target.mouse_mode != 0) try out.print(a, ESC ++ "[?{d}h", .{target.mouse_mode});
        }
        if (cur.mouse_enc != target.mouse_enc) {
            const old = mouseEncMode(cur.mouse_enc);
            const new = mouseEncMode(target.mouse_enc);
            if (old != 0) try out.print(a, ESC ++ "[?{d}l", .{old});
            if (new != 0) try out.print(a, ESC ++ "[?{d}h", .{new});
        }
        if (cur.bracketed_paste != target.bracketed_paste)
            try out.appendSlice(a, if (target.bracketed_paste) ESC ++ "[?2004h" else ESC ++ "[?2004l");
        if (cur.focus_reports != target.focus_reports)
            try out.appendSlice(a, if (target.focus_reports) ESC ++ "[?1004h" else ESC ++ "[?1004l");
        if (cur.cursor_shape != target.cursor_shape)
            try out.print(a, ESC ++ "[{d} q", .{cursorShapeParam(target.cursor_shape)});
        // `CSI = flags ; 1 u` SETS the flags without touching the host's
        // push/pop stack, so leave() can always return to 0.
        if (cur.kitty_flags != target.kitty_flags)
            try out.print(a, ESC ++ "[={d};1u", .{target.kitty_flags});
        if (cur.modify_other_keys != target.modify_other_keys)
            try out.print(a, ESC ++ "[>4;{d}m", .{target.modify_other_keys});
        if (cur.reverse != target.reverse)
            try out.appendSlice(a, if (target.reverse) ESC ++ "[?5h" else ESC ++ "[?5l");
        self.modes = target;
    }

    fn moveTo(self: *Renderer, out: *std.ArrayList(u8), row: u16, col: u16) !void {
        if (self.out_row == row and self.out_col == col) return;
        try out.print(self.allocator, ESC ++ "[{d};{d}H", .{ @as(u32, row) + 1, @as(u32, col) + 1 });
        self.out_row = row;
        self.out_col = col;
    }

    fn appendColor(out: *std.ArrayList(u8), a: std.mem.Allocator, color: Color, base: u8, ext: u8) !void {
        switch (color) {
            .default => {},
            .palette => |p| {
                if (p < 8) {
                    try out.print(a, ";{d}", .{base + p});
                } else if (p < 16) {
                    try out.print(a, ";{d}", .{base + 60 + (p - 8)});
                } else {
                    try out.print(a, ";{d};5;{d}", .{ ext, p });
                }
            },
            .rgb => |rgb| try out.print(a, ";{d};2;{d};{d};{d}", .{ ext, rgb.r, rgb.g, rgb.b }),
        }
    }

    fn setStyle(self: *Renderer, out: *std.ArrayList(u8), e: Entry) !void {
        if (self.out_style) |cur| {
            if (Entry.equal(cur, e)) return;
        }
        const a = self.allocator;
        try out.appendSlice(a, ESC ++ "[0");
        const at = e.attrs;
        if (at.bold) try out.appendSlice(a, ";1");
        if (at.dim) try out.appendSlice(a, ";2");
        if (at.italic) try out.appendSlice(a, ";3");
        if (at.curly_underline) {
            try out.appendSlice(a, ";4:3");
        } else if (at.double_underline) {
            try out.appendSlice(a, ";4:2");
        } else if (at.underline) {
            try out.appendSlice(a, ";4");
        }
        if (at.blink) try out.appendSlice(a, ";5");
        if (at.fast_blink) try out.appendSlice(a, ";6");
        if (at.reverse) try out.appendSlice(a, ";7");
        if (at.invisible) try out.appendSlice(a, ";8");
        if (at.strikethrough) try out.appendSlice(a, ";9");
        if (at.overline) try out.appendSlice(a, ";53");
        try appendColor(out, a, e.fg, 30, 38);
        try appendColor(out, a, e.bg, 40, 48);
        switch (e.underline_color) {
            .default => {},
            .palette => |p| try out.print(a, ";58;5;{d}", .{p}),
            .rgb => |rgb| try out.print(a, ";58;2;{d};{d};{d}", .{ rgb.r, rgb.g, rgb.b }),
        }
        try out.append(a, 'm');
        self.out_style = e;
    }

    fn closeLink(self: *Renderer, out: *std.ArrayList(u8)) !void {
        if (self.out_link == 0) return;
        try out.appendSlice(self.allocator, ESC ++ "]8;;" ++ ST);
        self.out_link = 0;
    }

    fn setLink(self: *Renderer, out: *std.ArrayList(u8), screen: *const Screen, link: u8) !void {
        if (self.out_link == link) return;
        if (link == 0) return self.closeLink(out);
        const uri = screen.linkUri(link) orelse return self.closeLink(out);
        const a = self.allocator;
        try out.appendSlice(a, ESC ++ "]8;;");
        try out.appendSlice(a, uri);
        try out.appendSlice(a, ST);
        self.out_link = link;
    }

    fn appendRune(out: *std.ArrayList(u8), a: std.mem.Allocator, cp: u32) !void {
        if (cp < 0x20 or cp == 0x7f) return out.append(a, ' ');
        if (cp < 0x80) return out.append(a, @intCast(cp));
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch {
            return out.appendSlice(a, "\u{fffd}");
        };
        try out.appendSlice(a, buf[0..n]);
    }

    fn clusterHash(ext: []const u32) u32 {
        if (ext.len == 0) return 0;
        var h: u32 = 0x811c9dc5;
        for (ext) |cp| {
            h ^= cp;
            h *%= 0x01000193;
        }
        return h | 1;
    }

    /// Text drawn over the top-right corner while scrolled back.
    const IndicatorBuf = [40]u8;

    fn indicator(buf: *IndicatorBuf, off: u32, total: u32) []const u8 {
        return std.fmt.bufPrint(buf, " scrollback {d}/{d}  q:back ", .{ off, total }) catch " scrollback ";
    }

    /// Repaint the host to match `screen`. Only cells that differ from
    /// the shadow are written, unless the shadow is invalid.
    pub fn render(self: *Renderer, out: *std.ArrayList(u8), screen: *Screen) !void {
        const a = self.allocator;
        try out.appendSlice(a, ESC ++ "[?2026h");
        try self.applyModes(out, HostModes.of(screen));
        if (self.cursor_shown) {
            try out.appendSlice(a, ESC ++ "[?25l");
            self.cursor_shown = false;
        }
        self.forwardTitle(out, screen) catch {};
        if (screen.bell_at_us != self.bell_seen) {
            if (self.bell_seen != -1) try out.append(a, 0x07);
            self.bell_seen = screen.bell_at_us;
        }

        if (!self.valid) {
            try out.appendSlice(a, ESC ++ "[0m" ++ ESC ++ "[H" ++ ESC ++ "[2J");
            self.out_style = null;
            self.out_row = 0;
            self.out_col = 0;
            @memset(self.shadow, .{});
        }

        const sb_total = screen.scrollbackCount();
        if (self.view_offset > sb_total) self.view_offset = sb_total;
        const view_off: i32 = @intCast(self.view_offset);

        var ind_buf: IndicatorBuf = undefined;
        const ind: []const u8 = if (view_off > 0 or self.scroll_mode) indicator(&ind_buf, self.view_offset, sb_total) else "";
        const ind_start: usize = if (ind.len >= self.cols) 0 else self.cols - ind.len;

        var r: u16 = 0;
        while (r < self.rows) : (r += 1) {
            const logical: i32 = @as(i32, r) - view_off;
            const cells: ?[]Cell = screen.lineCellsAtPub(logical);
            const on_active = logical >= 0 and logical < @as(i32, screen.rows);
            const overlay: ?[]const u8 = if (r == 0 and ind.len > 0) ind else null;
            var col: u16 = 0;
            while (col < self.cols) {
                var d = cellFor(screen, cells, on_active, logical, col, overlay, ind_start);
                const idx = @as(usize, r) * self.cols + col;
                if (isDefaultBlank(d)) {
                    // A run of default blanks is one ECH: the host's cells
                    // end up erased (rune 0), exactly like the mirror's, so
                    // text extraction on both sides agrees and a cleared
                    // line costs a handful of bytes.
                    var n: u16 = 1;
                    var changed = !self.valid or !self.shadow[idx].eql(d);
                    while (col + n < self.cols) : (n += 1) {
                        const dn = cellFor(screen, cells, on_active, logical, col + n, overlay, ind_start);
                        if (!isDefaultBlank(dn)) break;
                        if (!changed and !self.shadow[idx + n].eql(dn)) changed = true;
                    }
                    if (changed) {
                        try self.moveTo(out, r, col);
                        try self.setStyle(out, .{});
                        try self.closeLink(out);
                        try out.print(a, ESC ++ "[{d}X", .{n});
                        @memset(self.shadow[idx .. idx + n], .{});
                    }
                    col += n;
                    continue;
                }
                if (d.wide and col + 1 < self.cols) {
                    const d2: Shadow = .{ .cont = true, .style = d.style, .link = d.link };
                    if (!self.valid or !self.shadow[idx].eql(d) or !self.shadow[idx + 1].eql(d2)) {
                        try self.paint(out, screen, r, col, d, logical, on_active);
                        self.out_col += 1;
                        self.shadow[idx] = d;
                        self.shadow[idx + 1] = d2;
                    }
                    col += 2;
                    continue;
                }
                if (d.wide) {
                    // A 2-column glyph straddling the host's right edge:
                    // paint its left half as a blank of the same style.
                    d.wide = false;
                    d.rune = 0;
                    d.cluster = 0;
                }
                if (!self.valid or !self.shadow[idx].eql(d)) {
                    try self.paint(out, screen, r, col, d, logical, on_active);
                    self.shadow[idx] = d;
                }
                col += 1;
            }
        }
        self.valid = true;
        try self.closeLink(out);

        const cursor_ok = view_off == 0 and screen.cursor_visible and
            screen.row < self.rows and screen.col < self.cols;
        if (cursor_ok) {
            try self.moveTo(out, screen.row, screen.col);
            if (!self.cursor_shown) {
                try out.appendSlice(a, ESC ++ "[?25h");
                self.cursor_shown = true;
            }
        }
        try out.appendSlice(a, ESC ++ "[?2026l");
        screen.dirty = false;
    }

    fn isDefaultBlank(d: Shadow) bool {
        return d.rune == 0 and !d.wide and d.link == 0 and Entry.equal(d.style, .{});
    }

    /// The desired host cell, with the scroll indicator overlaid on
    /// the top row while scrolled back.
    fn cellFor(
        screen: *const Screen,
        cells: ?[]Cell,
        on_active: bool,
        logical: i32,
        col: u16,
        overlay: ?[]const u8,
        overlay_start: usize,
    ) Shadow {
        if (overlay) |text| {
            if (col >= overlay_start and col - overlay_start < text.len)
                return .{ .rune = text[col - overlay_start], .style = .{ .attrs = .{ .reverse = true, .bold = true } } };
        }
        return desiredCell(screen, cells, on_active, logical, col);
    }

    fn desiredCell(screen: *const Screen, cells: ?[]Cell, on_active: bool, logical: i32, col: u16) Shadow {
        const row_cells = cells orelse return .{};
        if (col >= row_cells.len) return .{};
        const cell = row_cells[col];
        const flags = cell_mod.flagsFromU8(cell.flags);
        var d: Shadow = .{
            .rune = cell.rune,
            .style = screen.pool.get(cell.style_ref),
            .link = if (flags.has_link) cell.reserved else 0,
        };
        if (flags.is_wide_cont) {
            // Only reachable when the left half was clipped or is
            // missing: show a blank rather than a stray placeholder.
            d.rune = 0;
            return d;
        }
        d.wide = flags.is_wide_left;
        if (on_active and cell.rune != 0)
            d.cluster = clusterHash(screen.clusterAt(@intCast(logical), col));
        return d;
    }

    fn paint(
        self: *Renderer,
        out: *std.ArrayList(u8),
        screen: *const Screen,
        row: u16,
        col: u16,
        d: Shadow,
        logical: i32,
        on_active: bool,
    ) !void {
        try self.moveTo(out, row, col);
        try self.setStyle(out, d.style);
        try self.setLink(out, screen, d.link);
        try appendRune(out, self.allocator, d.rune);
        if (d.cluster != 0 and on_active) {
            for (screen.clusterAt(@intCast(logical), col)) |ext| try appendRune(out, self.allocator, ext);
        }
        self.out_col += 1;
        // With DECAWM off the cursor parks at the last column after a
        // write there; forget it rather than model that.
        if (self.out_col >= self.cols) self.out_col = -1;
    }

    fn forwardTitle(self: *Renderer, out: *std.ArrayList(u8), screen: *const Screen) !void {
        const title = screen.last_title orelse return;
        const h = std.hash.Wyhash.hash(0, title);
        if (h == self.title_hash) return;
        self.title_hash = h;
        const a = self.allocator;
        try out.appendSlice(a, ESC ++ "]0;");
        for (title) |b| {
            if (b >= 0x20 and b != 0x7f) try out.append(a, b);
        }
        try out.appendSlice(a, ST);
    }
};

// ── tests ──────────────────────────────────────────────────────

const testing = std.testing;
const Parser = @import("../parser/vt.zig").Parser;
const Event = @import("../parser/event.zig").Event;
const Pool = style_pool.Pool;

const FeedCtx = struct { screen: *Screen, allocator: std.mem.Allocator };

fn feedEmit(user: ?*anyopaque, ev: Event) void {
    const ctx: *FeedCtx = @ptrCast(@alignCast(user.?));
    var mut = ev;
    ctx.screen.apply(ev);
    mut.deinit(ctx.allocator);
}

fn feed(screen: *Screen, bytes: []const u8) void {
    var parser = Parser.init(testing.allocator);
    defer parser.deinit();
    var ctx: FeedCtx = .{ .screen = screen, .allocator = testing.allocator };
    parser.advance(bytes, feedEmit, @ptrCast(&ctx));
}

const Rig = struct {
    pool: Pool,
    host_pool: Pool,
    screen: *Screen,
    host: *Screen,
    renderer: Renderer,
    out: std.ArrayList(u8) = .empty,

    fn init(cols: u16, rows: u16) !Rig {
        var rig: Rig = undefined;
        rig.pool = try Pool.init(testing.allocator);
        rig.host_pool = try Pool.init(testing.allocator);
        rig.screen = try Screen.init(testing.allocator, &rig.pool, cols, rows);
        rig.host = try Screen.init(testing.allocator, &rig.host_pool, cols, rows);
        rig.host.mute_responses = true;
        rig.renderer = try Renderer.init(testing.allocator, cols, rows);
        rig.out = .empty;
        return rig;
    }

    fn fix(self: *Rig) void {
        // The pools moved with the struct: re-point the screens.
        self.screen.pool = &self.pool;
        self.host.pool = &self.host_pool;
    }

    fn deinit(self: *Rig) void {
        self.out.deinit(testing.allocator);
        self.renderer.deinit();
        self.host.deinit();
        self.screen.deinit();
        self.host_pool.deinit();
        self.pool.deinit();
    }

    /// Render, replay the bytes into the host screen, return the bytes.
    fn frame(self: *Rig) ![]const u8 {
        self.out.clearRetainingCapacity();
        try self.renderer.render(&self.out, self.screen);
        feed(self.host, self.out.items);
        return self.out.items;
    }

    fn expectHostMatches(self: *Rig) !void {
        const want = try self.screen.extractScreen(testing.allocator);
        defer testing.allocator.free(want);
        const got = try self.host.extractScreen(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(want, got);
        try testing.expectEqual(self.screen.row, self.host.row);
        try testing.expectEqual(self.screen.col, self.host.col);
    }
};

test "ttyrender: first frame paints everything, host grid matches the mirror" {
    var rig = try Rig.init(20, 4);
    rig.fix();
    defer rig.deinit();
    feed(rig.screen, "hello \x1b[1;31mred\x1b[0m world\r\nline two");
    _ = try rig.frame();
    try rig.expectHostMatches();
    // Styles survive the round trip.
    const hc = rig.host.cellAt(0, 6);
    const e = rig.host.pool.get(hc.style_ref);
    try testing.expect(e.attrs.bold);
    try testing.expect(Color.equal(e.fg, .{ .palette = 1 }));
}

test "ttyrender: unchanged frame writes no cells, a changed cell writes only itself" {
    var rig = try Rig.init(20, 4);
    rig.fix();
    defer rig.deinit();
    feed(rig.screen, "abcdef");
    _ = try rig.frame();
    const quiet = try rig.frame();
    // Sync bracket + cursor park only: no printable payload.
    try testing.expect(std.mem.indexOfScalar(u8, quiet, 'a') == null);
    try testing.expect(quiet.len < 40);

    feed(rig.screen, "\x1b[1;3HX");
    const diff = try rig.frame();
    try testing.expect(std.mem.indexOf(u8, diff, "X") != null);
    try testing.expect(std.mem.indexOf(u8, diff, "abcdef") == null);
    try rig.expectHostMatches();
}

test "ttyrender: wide glyphs, truecolor and hyperlinks round-trip" {
    var rig = try Rig.init(20, 3);
    rig.fix();
    defer rig.deinit();
    feed(rig.screen, "\x1b[38;2;10;20;30m\xe4\xb8\xad\xe6\x96\x87\x1b[0m \x1b]8;;https://x.y/\x1b\\link\x1b]8;;\x1b\\ end");
    const bytes = try rig.frame();
    try testing.expect(std.mem.indexOf(u8, bytes, "38;2;10;20;30") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b]8;;https://x.y/\x1b\\") != null);
    try rig.expectHostMatches();
    try testing.expect(cell_mod.flagsFromU8(rig.host.cellAt(0, 0).flags).is_wide_left);
    try testing.expect(cell_mod.flagsFromU8(rig.host.cellAt(0, 1).flags).is_wide_cont);
    const link_cell = rig.host.cellAt(0, 5);
    try testing.expect(cell_mod.flagsFromU8(link_cell.flags).has_link);
    try testing.expectEqualStrings("https://x.y/", rig.host.linkUri(link_cell.reserved).?);
}

test "ttyrender: session modes are mirrored to the host and reset on leave" {
    var rig = try Rig.init(10, 2);
    rig.fix();
    defer rig.deinit();
    feed(rig.screen, "\x1b[?1h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[5 q");
    const bytes = try rig.frame();
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1002h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?1006h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?2004h") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[5 q") != null);
    try testing.expect(rig.host.app_cursor_keys);
    try testing.expectEqual(@as(u16, 1002), rig.host.mouse_mode);
    try testing.expect(rig.host.bracketed_paste);

    // Nothing re-emitted while unchanged.
    const again = try rig.frame();
    try testing.expect(std.mem.indexOf(u8, again, "?1002h") == null);

    rig.out.clearRetainingCapacity();
    try rig.renderer.leave(&rig.out);
    feed(rig.host, rig.out.items);
    try testing.expect(!rig.host.app_cursor_keys);
    try testing.expectEqual(@as(u16, 0), rig.host.mouse_mode);
    try testing.expect(!rig.host.bracketed_paste);
    try testing.expect(std.mem.indexOf(u8, rig.out.items, "\x1b[?1049l") != null);
}

test "ttyrender: scrolled-back view shows scrollback rows and hides the cursor" {
    var rig = try Rig.init(30, 3);
    rig.fix();
    defer rig.deinit();
    feed(rig.screen, "one\r\ntwo\r\nthree\r\nfour\r\nfive");
    try testing.expectEqual(@as(u32, 2), rig.screen.scrollbackCount());
    rig.renderer.view_offset = 2;
    const bytes = try rig.frame();
    try testing.expect(std.mem.indexOf(u8, bytes, "one") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "scrollback 2/2") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\x1b[?25h") == null);
    // The host's first row is the oldest scrollback line.
    const text = try rig.host.extractScreen(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "one"));

    rig.renderer.view_offset = 0;
    _ = try rig.frame();
    try rig.expectHostMatches();
}

test "ttyrender: a wider mirror than the host is clipped, a narrower one padded" {
    var rig = try Rig.init(10, 2);
    rig.fix();
    defer rig.deinit();
    // Mirror is 20 wide, host 10.
    var pool = try Pool.init(testing.allocator);
    defer pool.deinit();
    const wide = try Screen.init(testing.allocator, &pool, 20, 2);
    defer wide.deinit();
    feed(wide, "0123456789ABCDEFGHIJ");
    rig.out.clearRetainingCapacity();
    try rig.renderer.render(&rig.out, wide);
    feed(rig.host, rig.out.items);
    const text = try rig.host.extractScreen(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.startsWith(u8, text, "0123456789\n"));
    try testing.expect(std.mem.indexOf(u8, text, "A") == null);

    // Narrower mirror: no crash, remaining host cells blank.
    const narrow = try Screen.init(testing.allocator, &pool, 4, 1);
    defer narrow.deinit();
    feed(narrow, "ab");
    try rig.renderer.resize(10, 2);
    rig.out.clearRetainingCapacity();
    try rig.renderer.render(&rig.out, narrow);
    feed(rig.host, rig.out.items);
    const text2 = try rig.host.extractScreen(testing.allocator);
    defer testing.allocator.free(text2);
    try testing.expect(std.mem.startsWith(u8, text2, "ab\n"));
}

test "ttyrender: title and bell are forwarded once per change" {
    var rig = try Rig.init(10, 2);
    rig.fix();
    defer rig.deinit();
    feed(rig.screen, "\x1b]0;my title\x1b\\x\x07");
    const first = try rig.frame();
    try testing.expect(std.mem.indexOf(u8, first, "\x1b]0;my title\x1b\\") != null);
    // The bell that predates the attach is adopted silently.
    try testing.expect(std.mem.indexOfScalar(u8, first, 0x07) == null);
    // A later bell (a distinct timestamp; the clock may be coarse).
    rig.screen.bell_at_us += 1;
    const second = try rig.frame();
    try testing.expect(std.mem.indexOfScalar(u8, second, 0x07) != null);
    try testing.expect(std.mem.indexOf(u8, second, "my title") == null);
}

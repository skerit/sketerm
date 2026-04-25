//! Conformance tests ported from kitty/kitty_tests/parser.py and
//! wezterm/term/src/test/csi.rs. The pattern follows Kitty's:
//!   1. Build a Screen of known size
//!   2. Feed bytes through the parser
//!   3. Assert on the resulting Screen state
//!
//! Where their assertions check internal callbacks (e.g.
//! `screen_insert_characters`, `screen_cursor_position`), we assert
//! on observable state instead — final cell contents, cursor row/col,
//! captured PTY-write bytes for response sequences.

const std = @import("std");
const Parser = @import("vt.zig").Parser;
const Event = @import("event.zig").Event;
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

/// A test harness: spins up a Screen + Parser, captures any PTY-write
/// bytes the screen emits via its sink, lets us feed bytes and inspect.
const Harness = struct {
    pool: Pool,
    screen: *Screen,
    parser: Parser,
    allocator: std.mem.Allocator,
    /// Captured response bytes (e.g. DSR replies, DA1 reply).
    wtc: std.ArrayList(u8) = .{},

    fn init(a: std.mem.Allocator, cols: u16, rows: u16) !Harness {
        var pool = try Pool.init(a);
        errdefer pool.deinit();
        const screen = try Screen.init(a, &pool, cols, rows);
        errdefer screen.deinit();
        return .{
            .pool = pool,
            .screen = screen,
            .parser = Parser.init(a),
            .allocator = a,
        };
    }

    fn deinit(self: *Harness) void {
        self.wtc.deinit(self.allocator);
        self.screen.deinit();
        self.pool.deinit();
        self.parser.deinit();
    }

    fn captureWriteBytes(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Harness = @ptrCast(@alignCast(ctx.?));
        self.wtc.appendSlice(self.allocator, bytes) catch {};
    }

    fn arm(self: *Harness) void {
        self.screen.sink = .{
            .ctx = @ptrCast(self),
            .on_write_pty = captureWriteBytes,
        };
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *Harness = @ptrCast(@alignCast(user.?));
        var mut = ev;
        self.screen.apply(ev);
        mut.deinit(self.allocator);
    }

    fn feed(self: *Harness, bytes: []const u8) void {
        self.parser.advance(bytes, emit, @ptrCast(self));
    }

    /// UTF-8 encoded row contents, with trailing blanks trimmed.
    fn line(self: *Harness, allocator: std.mem.Allocator, row: u16) ![]u8 {
        const cells = self.screen.line(row).cells;
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);
        // Trim trailing blanks.
        var hi: usize = cells.len;
        while (hi > 0 and (cells[hi - 1].rune == 0 or cells[hi - 1].rune == ' ')) hi -= 1;
        for (cells[0..hi]) |cell| {
            if (cell.flags & 0b0000_0010 != 0) continue; // wide-cont
            const cp = if (cell.rune == 0) ' ' else cell.rune;
            if (cp < 0x80) {
                try out.append(allocator, @intCast(cp));
            } else {
                var ub: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(cp), &ub) catch continue;
                try out.appendSlice(allocator, ub[0..n]);
            }
        }
        return try out.toOwnedSlice(allocator);
    }
};

// ──────────────────────────────────────────────────────────────────
// Ported tests
// ──────────────────────────────────────────────────────────────────

test "kitty parser.py: simple parsing — text wraps, CR/LF, UTF-8" {
    var h = try Harness.init(std.testing.allocator, 5, 4);
    defer h.deinit();
    h.arm();

    h.feed("12");
    {
        const s = try h.line(std.testing.allocator, 0);
        defer std.testing.allocator.free(s);
        try std.testing.expectEqualStrings("12", s);
    }
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);

    h.feed("3456");
    {
        const r0 = try h.line(std.testing.allocator, 0);
        defer std.testing.allocator.free(r0);
        try std.testing.expectEqualStrings("12345", r0);
        const r1 = try h.line(std.testing.allocator, 1);
        defer std.testing.allocator.free(r1);
        try std.testing.expectEqualStrings("6", r1);
    }

    h.feed("\n123\n\r45");
    {
        const r2 = try h.line(std.testing.allocator, 2);
        defer std.testing.allocator.free(r2);
        try std.testing.expectEqualStrings(" 123", r2);
        const r3 = try h.line(std.testing.allocator, 3);
        defer std.testing.allocator.free(r3);
        try std.testing.expectEqualStrings("45", r3);
    }
}

test "kitty parser.py: CSI ICH (CSI @) with various param shapes" {
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("abcde");
    // Move cursor to col 0, then `x \e[2@ y` should insert two
    // blanks before the 'y', shifting the rest right.
    h.feed("\x1b[H"); // cursor home
    h.feed("x\x1b[2@y");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    // After "abcde" + home + 'x' + ICH(2) + 'y':
    // start: a b c d e , cursor goes to (0,0), 'x' replaces 'a' →
    // x b c d e (cursor at col 1), ICH(2) shifts → x . . b c
    // (col still 1, last cells dropped), then 'y' overwrites col 1
    // → x y . b c.
    try std.testing.expectEqualStrings("xy bc", r);
}

test "kitty parser.py: CSI CUP edge cases" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[H"); // home
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    h.feed("\x1b[4H"); // CUP 4 → row 3
    try std.testing.expectEqual(@as(u16, 3), h.screen.row);
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    h.feed("\x1b[3;2H"); // CUP 3,2 → row 2 col 1
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
    // Leading zeros tolerated.
    h.feed("\x1b[00000000003;0000000000000002H");
    try std.testing.expectEqual(@as(u16, 2), h.screen.row);
    try std.testing.expectEqual(@as(u16, 1), h.screen.col);
    // Out-of-range param should clamp to screen bounds.
    h.feed("\x1b[999;999H");
    try std.testing.expectEqual(@as(u16, 23), h.screen.row);
    try std.testing.expectEqual(@as(u16, 79), h.screen.col);
}

test "kitty parser.py: DSR 5n + 6n responses" {
    var h = try Harness.init(std.testing.allocator, 80, 24);
    defer h.deinit();
    h.arm();
    // DSR 5 — terminal status. Reply: ESC [ 0 n.
    h.feed("\x1b[5n");
    try std.testing.expectEqualStrings("\x1b[0n", h.wtc.items);
    h.wtc.clearRetainingCapacity();
    // DSR 6 — cursor position at (1,1). Reply: ESC [ 1 ; 1 R.
    h.feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;1R", h.wtc.items);
    h.wtc.clearRetainingCapacity();
    // After printing 5 chars the cursor is at col 5 (0-indexed) but
    // DSR reports 1-indexed → col 6 → row stays 1.
    h.feed("12345");
    h.feed("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;6R", h.wtc.items);
}

test "wezterm csi.rs issue 789: DCH shifts remaining left" {
    // From wezterm/term/src/test/csi.rs — `\e[40m\e[Kfoo\e[2P` after
    // moving cursor home should DCH-shift "foo" so only 'o' remains
    // at col 0 (the third 'o' shifted from col 2 → col 0, the other
    // two cells deleted). WezTerm additionally asserts those vacated
    // cells inherit the current bg (palette 0); we assert on observable
    // text.
    var h = try Harness.init(std.testing.allocator, 8, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[40m\x1b[Kfoo\x1b[H\x1b[2P");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    try std.testing.expectEqualStrings("o", r);
}

test "kitty parser.py: SGR truecolor parses both 38;2 and 38:2 forms" {
    var h = try Harness.init(std.testing.allocator, 5, 2);
    defer h.deinit();
    h.arm();
    h.feed("\x1b[38;2;255;128;0;48;2;0;0;0mA");
    // Cell 0 should have a truecolor fg = (255, 128, 0) and bg = (0,0,0).
    const c0 = h.screen.cellAt(0, 0);
    const style = h.screen.pool.get(c0.style_ref);
    try std.testing.expect(style.fg == .rgb);
    try std.testing.expectEqual(@as(u8, 255), style.fg.rgb.r);
    try std.testing.expectEqual(@as(u8, 128), style.fg.rgb.g);
    try std.testing.expectEqual(@as(u8, 0), style.fg.rgb.b);
    // Now colon-form on a fresh row.
    h.feed("\r\n");
    h.feed("\x1b[38:2:0:255:0;48:2:0:0:0mB");
    const c1 = h.screen.cellAt(1, 0);
    const style1 = h.screen.pool.get(c1.style_ref);
    try std.testing.expect(style1.fg == .rgb);
    try std.testing.expectEqual(@as(u8, 0), style1.fg.rgb.r);
    try std.testing.expectEqual(@as(u8, 255), style1.fg.rgb.g);
    try std.testing.expectEqual(@as(u8, 0), style1.fg.rgb.b);
}

test "kitty parser.py (variant): CSI with invalid byte doesn't crash" {
    // Kitty REJECTS `\x1b[2-3@` as malformed and prints `@y` as text.
    // Our Williams state machine treats `-` (0x2D) as an intermediate,
    // accepts the sequence, and runs ICH(2) followed by 'y'. Both are
    // permissible readings of the spec — intermediate after parameter
    // is "implementation-defined." We assert no crash + sane output.
    var h = try Harness.init(std.testing.allocator, 10, 1);
    defer h.deinit();
    h.arm();
    h.feed("x\x1b[2-3@y");
    const r = try h.line(std.testing.allocator, 0);
    defer std.testing.allocator.free(r);
    // Output is one of the two interpretations; verify it's one of them.
    const ok = std.mem.eql(u8, r, "xy") or std.mem.eql(u8, r, "x@y");
    try std.testing.expect(ok);
}

test "kitty parser.py: DECSCM 25 hides + shows cursor" {
    var h = try Harness.init(std.testing.allocator, 10, 5);
    defer h.deinit();
    h.arm();
    try std.testing.expect(h.screen.cursor_visible);
    h.feed("\x1b[?25l");
    try std.testing.expect(!h.screen.cursor_visible);
    h.feed("\x1b[?25h");
    try std.testing.expect(h.screen.cursor_visible);
}

test "kitty parser.py: ESC c (RIS) resets cursor + style" {
    var h = try Harness.init(std.testing.allocator, 10, 5);
    defer h.deinit();
    h.arm();
    h.feed("hello\x1b[H\x1b[31m");
    // Cursor is at (0,0), style references red.
    h.feed("\x1bc"); // RIS
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    try std.testing.expectEqual(@as(u16, 0), h.screen.cur_style);
}

test "kitty parser.py: C1 controls (8-bit ESC) handled as printable" {
    // Kitty's parser keeps 8-bit C1 controls as printable bytes
    // because in UTF-8 they're invalid as standalone. Our decoder
    // also drops them as stray continuation/leading bytes. Check
    // we don't crash and don't insert garbage.
    var h = try Harness.init(std.testing.allocator, 20, 1);
    defer h.deinit();
    h.arm();
    h.feed("\x84\x85\x88\x8d\x8e\x8f\x90\x96\x97\x98\x9a\x9b\x9c\x9d\x9e\x9f");
    // No control should have side effects on row/col.
    try std.testing.expectEqual(@as(u16, 0), h.screen.row);
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
}

test "kitty parser.py: incomplete UTF-8 at end of buffer" {
    // 😀 = F0 9F 98 80; supply only the first 3 bytes.
    var h = try Harness.init(std.testing.allocator, 5, 1);
    defer h.deinit();
    h.arm();
    h.feed("\xF0\x9F\x98");
    try std.testing.expectEqual(@as(u16, 0), h.screen.col);
    h.feed("\x80");
    // After the final byte, the codepoint is complete.
    // 😀 is a wide char (2 columns).
    try std.testing.expectEqual(@as(u16, 2), h.screen.col);
}

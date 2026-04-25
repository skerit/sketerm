//! Shared test harness for conformance tests ported from
//! kitty/kitty_tests/*.py and wezterm/term/src/test/*.rs. Wraps a
//! Screen + Parser, captures any PTY-write bytes the screen emits
//! via its sink, exposes feed/line/wtc accessors.
//!
//! Assertion style: build a screen of known size, feed bytes, assert
//! on observable Screen state (cell rune, cursor row/col, captured
//! response sequences). Mirrors Kitty's `parse_bytes_dump` pattern.

const std = @import("std");
const Parser = @import("vt.zig").Parser;
const Event = @import("event.zig").Event;
pub const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

pub const Harness = struct {
    /// Heap-allocated. Screen.pool is a borrowed pointer; storing
    /// Pool by value here would have its address change when Harness
    /// is moved out of init() into the caller's frame, leaving
    /// `screen.pool` dangling. Manifested as a SIGSEGV on
    /// `Pool.get` in ReleaseFast (where the previous stack frame's
    /// memory got reused with different content). Heap pointer
    /// keeps it stable.
    pool: *Pool,
    screen: *Screen,
    parser: Parser,
    allocator: std.mem.Allocator,
    /// Captured response bytes (e.g. DSR replies, DA1 reply).
    wtc: std.ArrayList(u8) = .{},
    /// Captured OSC titles (set by OSC 0/2).
    titles: std.ArrayList([]u8) = .{},

    pub fn init(a: std.mem.Allocator, cols: u16, rows: u16) !Harness {
        const pool_ptr = try a.create(Pool);
        errdefer a.destroy(pool_ptr);
        pool_ptr.* = try Pool.init(a);
        errdefer pool_ptr.deinit();
        const screen = try Screen.init(a, pool_ptr, cols, rows);
        errdefer screen.deinit();
        return .{
            .pool = pool_ptr,
            .screen = screen,
            .parser = Parser.init(a),
            .allocator = a,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.wtc.deinit(self.allocator);
        for (self.titles.items) |t| self.allocator.free(t);
        self.titles.deinit(self.allocator);
        self.screen.deinit();
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        self.parser.deinit();
    }

    fn captureWriteBytes(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Harness = @ptrCast(@alignCast(ctx.?));
        self.wtc.appendSlice(self.allocator, bytes) catch {};
    }

    fn captureTitle(ctx: ?*anyopaque, title: []const u8) void {
        const self: *Harness = @ptrCast(@alignCast(ctx.?));
        const dup = self.allocator.dupe(u8, title) catch return;
        self.titles.append(self.allocator, dup) catch self.allocator.free(dup);
    }

    pub fn arm(self: *Harness) void {
        self.screen.sink = .{
            .ctx = @ptrCast(self),
            .on_write_pty = captureWriteBytes,
            .on_title = captureTitle,
        };
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *Harness = @ptrCast(@alignCast(user.?));
        var mut = ev;
        self.screen.apply(ev);
        mut.deinit(self.allocator);
    }

    pub fn feed(self: *Harness, bytes: []const u8) void {
        self.parser.advance(bytes, emit, @ptrCast(self));
    }

    /// UTF-8 encoded row contents, with trailing blanks trimmed.
    /// Caller frees.
    pub fn line(self: *Harness, allocator: std.mem.Allocator, row: u16) ![]u8 {
        const cells = self.screen.line(row).cells;
        var out: std.ArrayList(u8) = .{};
        defer out.deinit(allocator);
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

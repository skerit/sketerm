//! Shared test harness for conformance tests ported from
//! kitty/kitty_tests/*.py and wezterm/term/src/test/*.rs. Wraps a
//! Screen + Parser, captures any PTY-write bytes the screen emits
//! via its sink, exposes feed/line/wtc accessors.
//!
//! Assertion style: build a screen of known size, feed bytes, assert
//! on observable Screen state (cell rune, cursor row/col, captured
//! response sequences). Mirrors Kitty's `parse_bytes_dump` pattern.

const std = @import("std");
const cell_mod = @import("../grid/cell.zig");
const Parser = @import("vt.zig").Parser;
const Event = @import("event.zig").Event;
pub const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

/// The last image event the screen emitted, plus the animation ticks.
/// Filled in by `arm`, for the image-pipeline tests.
pub const ImageCapture = struct {
    fired: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    /// Owned by the Harness.
    rgba: ?[]u8 = null,
    image_id: u32 = 0,
    placement_id: u32 = 0,
    z_index: i32 = 0,
    cells_wide: u32 = 0,
    cells_high: u32 = 0,
    animation_changes: usize = 0,
};

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
    wtc: std.ArrayList(u8) = .empty,
    /// Captured OSC titles (set by OSC 0/2).
    titles: std.ArrayList([]u8) = .empty,
    /// Captured OSC 52 clipboard writes.
    clipboard: std.ArrayList(u8) = .empty,
    /// Most recent image event.
    image: ImageCapture = .{},

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
        self.clipboard.deinit(self.allocator);
        if (self.image.rgba) |b| self.allocator.free(b);
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

    fn captureClipboard(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Harness = @ptrCast(@alignCast(ctx.?));
        self.clipboard.appendSlice(self.allocator, text) catch {};
    }

    fn captureImage(ctx: ?*anyopaque, ev: Screen.ImageEvent) void {
        const self: *Harness = @ptrCast(@alignCast(ctx.?));
        self.image.fired = true;
        self.image.width = ev.width;
        self.image.height = ev.height;
        self.image.image_id = ev.image_id;
        self.image.placement_id = ev.placement_id;
        self.image.z_index = ev.z_index;
        self.image.cells_wide = ev.cells_wide;
        self.image.cells_high = ev.cells_high;
        if (self.image.rgba) |b| self.allocator.free(b);
        self.image.rgba = self.allocator.dupe(u8, ev.rgba) catch null;
    }

    fn captureImageAnimation(ctx: ?*anyopaque) void {
        const self: *Harness = @ptrCast(@alignCast(ctx.?));
        self.image.animation_changes += 1;
    }

    pub fn arm(self: *Harness) void {
        self.screen.sink = .{
            .ctx = @ptrCast(self),
            .on_write_pty = captureWriteBytes,
            .on_title = captureTitle,
            .on_clipboard_set = captureClipboard,
            .on_image = captureImage,
            .on_image_animation = captureImageAnimation,
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

    /// Assert a row's trimmed UTF-8 contents.
    ///
    /// The three-line allocate/free/compare dance this replaces was
    /// written out ~50 times across the conformance suites, often
    /// inside a block that existed only to scope the `defer`.
    pub fn expectLine(self: *Harness, row: u16, expected: []const u8) !void {
        const got = try self.line(self.allocator, row);
        defer self.allocator.free(got);
        try std.testing.expectEqualStrings(expected, got);
    }

    /// Feed an OSC 52 clipboard write carrying `raw`, base64-encoded here.
    pub fn feedOsc52(self: *Harness, raw: []const u8) !void {
        const enc = std.base64.standard.Encoder;
        const buf = try self.allocator.alloc(u8, enc.calcSize(raw.len));
        defer self.allocator.free(buf);
        const seq = try std.fmt.allocPrint(self.allocator, "\x1b]52;c;{s}\x07", .{enc.encode(buf, raw)});
        defer self.allocator.free(seq);
        self.feed(seq);
    }

    /// Start a normal selection at one cell and extend it to another.
    pub fn select(self: *Harness, from_row: u16, from_col: u16, to_row: u16, to_col: u16) void {
        self.screen.selection.start(from_row, from_col, .normal);
        self.screen.selection.extend(to_row, to_col);
    }

    /// Assert the text the current selection extracts to.
    pub fn expectSelection(self: *Harness, expected: []const u8) !void {
        const out = try self.screen.extractSelection(self.allocator);
        defer self.allocator.free(out);
        try std.testing.expectEqualStrings(expected, out);
    }

    /// Assert the cursor's row and column together.
    pub fn expectCursor(self: *Harness, row: u16, col: u16) !void {
        try std.testing.expectEqual(row, self.screen.row);
        try std.testing.expectEqual(col, self.screen.col);
    }

    /// UTF-8 encoded row contents, with trailing blanks trimmed.
    /// Caller frees.
    pub fn line(self: *Harness, allocator: std.mem.Allocator, row: u16) ![]u8 {
        const cells = self.screen.line(row).cells;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var hi: usize = cells.len;
        while (hi > 0 and (cells[hi - 1].rune == 0 or cells[hi - 1].rune == ' ')) hi -= 1;
        for (cells[0..hi]) |cell| {
            if (cell.flags & cell_mod.FLAG_WIDE_CONT != 0) continue; // wide-cont
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

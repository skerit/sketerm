//! OSC 52 clipboard conformance tests. Inspired by
//! kitty/kitty_tests/clipboard.py — Kitty has a streaming base64
//! decoder (StreamingBase64Decoder) for very large clipboard
//! payloads; we use std.base64 in one shot and cap the payload at
//! 1 MB. These tests exercise the OSC 52 round-trip end-to-end:
//! raw text → base64 → OSC 52 sequence → captured `on_clipboard_set`.

const std = @import("std");
const Parser = @import("vt.zig").Parser;
const Event = @import("event.zig").Event;
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;

const Bench = struct {
    /// Heap-allocated; Screen.pool borrows it. Storing Pool by value
    /// here would dangle when the Bench struct is moved out of init().
    pool: *Pool,
    screen: *Screen,
    parser: Parser,
    allocator: std.mem.Allocator,
    captured: std.ArrayList(u8) = .{},

    fn init(a: std.mem.Allocator) !Bench {
        const pool_ptr = try a.create(Pool);
        errdefer a.destroy(pool_ptr);
        pool_ptr.* = try Pool.init(a);
        errdefer pool_ptr.deinit();
        const screen = try Screen.init(a, pool_ptr, 5, 1);
        errdefer screen.deinit();
        return .{
            .pool = pool_ptr,
            .screen = screen,
            .parser = Parser.init(a),
            .allocator = a,
        };
    }

    fn deinit(self: *Bench) void {
        self.captured.deinit(self.allocator);
        self.screen.deinit();
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        self.parser.deinit();
    }

    fn captureClip(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Bench = @ptrCast(@alignCast(ctx.?));
        self.captured.appendSlice(self.allocator, text) catch {};
    }

    fn arm(self: *Bench) void {
        self.screen.sink = .{
            .ctx = @ptrCast(self),
            .on_clipboard_set = captureClip,
        };
    }

    fn emit(user: ?*anyopaque, ev: Event) void {
        const self: *Bench = @ptrCast(@alignCast(user.?));
        var mut = ev;
        self.screen.apply(ev);
        mut.deinit(self.allocator);
    }

    fn osc52(self: *Bench, raw: []const u8) !void {
        const enc = std.base64.standard.Encoder;
        const sz = enc.calcSize(raw.len);
        const buf = try self.allocator.alloc(u8, sz);
        defer self.allocator.free(buf);
        const b64 = enc.encode(buf, raw);
        const seq = try std.fmt.allocPrint(self.allocator, "\x1b]52;c;{s}\x07", .{b64});
        defer self.allocator.free(seq);
        self.parser.advance(seq, emit, @ptrCast(self));
    }
};

test "OSC 52: small base64 round-trip ('title')" {
    var b = try Bench.init(std.testing.allocator);
    defer b.deinit();
    b.arm();
    try b.osc52("title");
    try std.testing.expectEqualStrings("title", b.captured.items);
}

test "OSC 52: 'light work'" {
    var b = try Bench.init(std.testing.allocator);
    defer b.deinit();
    b.arm();
    try b.osc52("light work");
    try std.testing.expectEqualStrings("light work", b.captured.items);
}

test "OSC 52: 'light work.' (period forces full padding)" {
    var b = try Bench.init(std.testing.allocator);
    defer b.deinit();
    b.arm();
    try b.osc52("light work.");
    try std.testing.expectEqualStrings("light work.", b.captured.items);
}

test "OSC 52: roundtrip with binary bytes" {
    var b = try Bench.init(std.testing.allocator);
    defer b.deinit();
    b.arm();
    const raw: []const u8 = &.{ 0x00, 0x01, 0x02, 0xFE, 0xFF };
    try b.osc52(raw);
    try std.testing.expectEqualSlices(u8, raw, b.captured.items);
}

test "OSC 52: read query (data='?') is gated, no clipboard set" {
    var b = try Bench.init(std.testing.allocator);
    defer b.deinit();
    b.arm();
    b.parser.advance("\x1b]52;c;?\x07", Bench.emit, @ptrCast(&b));
    try std.testing.expectEqual(@as(usize, 0), b.captured.items.len);
}

test "OSC 52: empty data is a no-op" {
    var b = try Bench.init(std.testing.allocator);
    defer b.deinit();
    b.arm();
    b.parser.advance("\x1b]52;c;\x07", Bench.emit, @ptrCast(&b));
    try std.testing.expectEqual(@as(usize, 0), b.captured.items.len);
}

test "OSC 52: invalid base64 silently dropped" {
    var b = try Bench.init(std.testing.allocator);
    defer b.deinit();
    b.arm();
    b.parser.advance("\x1b]52;c;@@@@@\x07", Bench.emit, @ptrCast(&b));
    try std.testing.expectEqual(@as(usize, 0), b.captured.items.len);
}

test "OSC 52: payload split across two feed() calls assembles" {
    var b = try Bench.init(std.testing.allocator);
    defer b.deinit();
    b.arm();
    // 'hello' = aGVsbG8=
    b.parser.advance("\x1b]52;c;aGVs", Bench.emit, @ptrCast(&b));
    b.parser.advance("bG8=\x07", Bench.emit, @ptrCast(&b));
    try std.testing.expectEqualStrings("hello", b.captured.items);
}

//! Replay a captured PTY byte stream through the parser + Screen and
//! dump the resulting grid as text. Debugging tool for "terminal X
//! renders wrong" reports: capture the raw bytes (script(1), or a
//! pty.fork harness), then `zig build replay -- capture.bin [cols rows]`.
//!
//! Rows render between `|` gutters so trailing whitespace is visible.
//! Cells with a non-default style print their rune normally; wide-char
//! continuations print `_`, truly empty cells ` `.
//!
//! Images (sixel / kitty / iTerm2) leave no cells behind, so each one
//! prints an `image` line as it arrives — dimensions, placement and the
//! first pixel, which is what a sixel background-select or aspect-ratio
//! regression shows up in.
//!
//! `replay --cast rec.cast [cols rows]` replays an asciicast v2 recording
//! (what every MCP headless terminal writes) and prints one JSON line per
//! frame on stdout instead: the screen text exactly as `term_read` returns
//! it, plus the lines that scrolled into history since the previous frame.
//! A frame is every run of events sharing one timestamp, skipped while the
//! app holds a synchronized-output (DEC 2026) update open.

const std = @import("std");
const cell_mod = @import("grid/cell.zig");
const Parser = @import("parser/vt.zig").Parser;
const Event = @import("parser/event.zig").Event;
const Screen = @import("grid/screen.zig").Screen;
const StylePool = @import("grid/style_pool.zig").Pool;
const cast_play = @import("mux/cast_play.zig");

const Ctx = struct {
    screen: *Screen,
    allocator: std.mem.Allocator,
};

fn emit(user: ?*anyopaque, ev: Event) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    var mut_ev = ev;
    ctx.screen.apply(ev);
    mut_ev.deinit(ctx.allocator);
}

fn onImage(_: ?*anyopaque, ev: Screen.ImageEvent) void {
    const px = if (ev.rgba.len >= 4) ev.rgba[0..4] else &[_]u8{ 0, 0, 0, 0 };
    std.debug.print("image {d}x{d} at ({d},{d}) id={d} bytes={d} px0=({d},{d},{d},{d})\n", .{
        ev.width, ev.height, ev.row, ev.col, ev.image_id, ev.rgba.len,
        px[0],    px[1],     px[2],  px[3],
    });
}

// libc file IO — the Zig 0.16 std.fs/Io API churns; the project
// reads files through libc everywhere (see config.zig).
const cstd = @cImport({
    @cInclude("stdio.h");
});

/// Whole-file read; null (after printing why) when it cannot be read.
fn readFile(allocator: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    const fp = cstd.fopen(path.ptr, "rb") orelse {
        std.debug.print("replay: cannot open {s}\n", .{path});
        return null;
    };
    defer _ = cstd.fclose(fp);
    _ = cstd.fseek(fp, 0, cstd.SEEK_END);
    const fsize: usize = @intCast(cstd.ftell(fp));
    _ = cstd.fseek(fp, 0, cstd.SEEK_SET);
    const bytes = try allocator.alloc(u8, fsize);
    if (cstd.fread(bytes.ptr, 1, fsize, fp) != fsize) {
        allocator.free(bytes);
        std.debug.print("replay: short read\n", .{});
        return null;
    }
    return bytes;
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: replay <capture.bin> [cols rows]\n       replay --cast <rec.cast> [cols rows]\n", .{});
        return 1;
    }
    if (std.mem.eql(u8, std.mem.span(argv[1]), "--cast")) {
        if (argv.len < 3) {
            std.debug.print("usage: replay --cast <rec.cast> [cols rows]\n", .{});
            return 1;
        }
        const size: ?[2]u16 = if (argv.len > 4) .{
            try std.fmt.parseInt(u16, std.mem.span(argv[3]), 10),
            try std.fmt.parseInt(u16, std.mem.span(argv[4]), 10),
        } else null;
        return replayCast(allocator, std.mem.span(argv[2]), size);
    }
    const path = std.mem.span(argv[1]);
    var cols: u16 = 120;
    var rows: u16 = 30;
    if (argv.len > 2) cols = try std.fmt.parseInt(u16, std.mem.span(argv[2]), 10);
    if (argv.len > 3) rows = try std.fmt.parseInt(u16, std.mem.span(argv[3]), 10);

    const bytes = (try readFile(allocator, path)) orelse return 1;
    defer allocator.free(bytes);

    var pool = try StylePool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, cols, rows);
    defer screen.deinit();
    // The one local byte-stream consumer: a capture replayed here names
    // files on THIS host on purpose, so file-medium kitty APCs are allowed.
    screen.kitty_images.file_media = true;

    screen.sink = .{ .ctx = null, .on_image = onImage };

    var parser = Parser.init(allocator);
    defer parser.deinit();
    var ctx = Ctx{ .screen = screen, .allocator = allocator };
    parser.advance(bytes, emit, @ptrCast(&ctx));

    std.debug.print("screen {d}x{d} alt={} cursor=({d},{d}) sync={}\n", .{
        cols, rows, screen.use_alt, screen.row, screen.col, screen.sync_output,
    });
    var r: u16 = 0;
    while (r < rows) : (r += 1) {
        var line_buf: [4096]u8 = undefined;
        var len: usize = 0;
        var col: u16 = 0;
        while (col < cols) : (col += 1) {
            const cell = screen.cellAt(r, col);
            if (cell.flags & cell_mod.FLAG_WIDE_CONT != 0) {
                line_buf[len] = '_';
                len += 1;
            } else if (cell.rune == 0) {
                line_buf[len] = ' ';
                len += 1;
            } else {
                const n = std.unicode.utf8Encode(@intCast(cell.rune), line_buf[len..][0..4]) catch blk: {
                    line_buf[len] = '?';
                    break :blk 1;
                };
                len += n;
            }
        }
        std.debug.print("{d:3}|{s}|\n", .{ r, line_buf[0..len] });
    }
    return 0;
}

/// One settled frame as `--cast` prints it.
const Frame = struct {
    /// Seconds since the recording started.
    t: f64,
    alt: bool,
    cursor: [2]u16,
    title: []const u8,
    /// Lines that entered scrollback since the previous frame.
    history_added: []const u8,
    /// Scrollback was cleared since the previous frame (ED 3), even when a
    /// reprint refilled it within the same frame.
    history_reset: bool,
    history_len: u32,
    /// `Screen.viewport_epoch`: moves on every full erase, resize or alt swap.
    epoch: u32,
    screen: []const u8,
    /// Per screen row, the style of its first non-blank cell ("" for a blank
    /// row): what tells apart blocks whose text looks the same.
    styles: []const []const u8,
};

fn replayCast(allocator: std.mem.Allocator, path: [:0]const u8, size: ?[2]u16) !u8 {
    const bytes = (try readFile(allocator, path)) orelse return 1;
    defer allocator.free(bytes);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    castFrames(allocator, bytes, size, &aw.writer) catch |err| {
        std.debug.print("replay: {s}: {s}\n", .{ path, @errorName(err) });
        return 1;
    };
    const out = aw.written();
    _ = cstd.fwrite(out.ptr, 1, out.len, cstd.stdout);
    return 0;
}

/// Replay a whole cast, writing one `Frame` JSON line per distinct event time.
fn castFrames(allocator: std.mem.Allocator, bytes: []const u8, size: ?[2]u16, out: *std.Io.Writer) !void {
    var player = cast_play.Player.init(allocator);
    defer player.deinit();
    try player.feed(bytes);
    player.feedEof();
    // The header is parsed by the first `next`, so the Screen is sized after it.
    var next_ev = try player.next();
    const header = player.header orelse return error.BadHeader;

    var pool = try StylePool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, if (size) |s| s[0] else header.cols, if (size) |s| s[1] else header.rows);
    defer screen.deinit();
    var parser = Parser.init(allocator);
    defer parser.deinit();
    var ctx = Ctx{ .screen = screen, .allocator = allocator };

    var prev_newest: u64 = 0;
    var pending_ms: ?u64 = null;
    while (next_ev) |te| : (next_ev = try player.next()) {
        if (pending_ms) |ms| {
            if (te.time_ms != ms) try writeFrame(allocator, screen, ms, &prev_newest, out);
        }
        switch (te.event) {
            .output => |data| parser.advance(data, emit, @ptrCast(&ctx)),
            .resize => |r| try screen.resize(r.cols, r.rows),
            .marker, .exit, .input => {},
        }
        pending_ms = te.time_ms;
    }
    if (pending_ms) |ms| try writeFrame(allocator, screen, ms, &prev_newest, out);
}

/// A frame inside an open synchronized-output update is skipped: no reader
/// is meant to see it, and the app has not finished drawing it. New history
/// is counted by line id, not length: a clear plus a reprint in one frame
/// can leave the length unchanged while every line is new.
fn writeFrame(allocator: std.mem.Allocator, screen: *Screen, ms: u64, prev_newest: *u64, out: *std.Io.Writer) !void {
    if (screen.sync_output) return;
    const history = screen.scrollbackCount();
    var added_n: u32 = 0;
    while (added_n < history) : (added_n += 1) {
        const id = screen.lineIdAt(-@as(i32, @intCast(added_n + 1))) orelse break;
        if (id <= prev_newest.*) break;
    }
    const added: []u8 = if (added_n > 0)
        try screen.extractRowRange(allocator, -@as(i32, @intCast(added_n)), 0)
    else
        try allocator.dupe(u8, "");
    defer allocator.free(added);
    const text = try screen.extractScreen(allocator);
    defer allocator.free(text);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const styles = try rowStyles(arena_state.allocator(), screen);
    try std.json.Stringify.value(Frame{
        .t = @as(f64, @floatFromInt(ms)) / 1000.0,
        .alt = screen.use_alt,
        .cursor = .{ screen.row, screen.col },
        .title = screen.last_title orelse "",
        .history_added = added,
        // Every line is newer than the previous newest one: the old ones are gone.
        .history_reset = prev_newest.* != 0 and added_n == history,
        .history_len = history,
        .epoch = screen.viewport_epoch,
        .screen = text,
        .styles = styles,
    }, .{}, out);
    try out.writeByte('\n');
    if (history > 0) prev_newest.* = screen.lineIdAt(-1) orelse prev_newest.*;
}

fn rowStyles(arena: std.mem.Allocator, screen: *Screen) ![]const []const u8 {
    const out = try arena.alloc([]const u8, screen.rows);
    for (out, 0..) |*slot, r| {
        slot.* = "";
        var c: u16 = 0;
        while (c < screen.cols) : (c += 1) {
            const cell = screen.cellAt(@intCast(r), c);
            if (cell.rune == 0 or cell.rune == ' ') continue;
            const e = screen.pool.get(cell.style_ref);
            var buf: std.Io.Writer.Allocating = .init(arena);
            try buf.writer.writeAll("fg=");
            try writeColor(&buf.writer, e.fg);
            try buf.writer.writeAll(" bg=");
            try writeColor(&buf.writer, e.bg);
            if (e.attrs.bold) try buf.writer.writeAll(" bold");
            if (e.attrs.dim) try buf.writer.writeAll(" dim");
            slot.* = buf.written();
            break;
        }
    }
    return out;
}

fn writeColor(w: *std.Io.Writer, color: @import("grid/style_pool.zig").Color) !void {
    switch (color) {
        .default => try w.writeAll("-"),
        .palette => |p| try w.print("p{d}", .{p}),
        .rgb => |c| try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }),
    }
}

test "cast replay: a frame per event time, open sync updates skipped, scrolled lines reported" {
    const cast =
        \\{"version": 2, "width": 10, "height": 2}
        \\[0.1, "o", "one\r\n"]
        \\[0.1, "o", "two\r\n"]
        \\[0.2, "o", "\u001b[?2026hthree"]
        \\[0.3, "o", "\u001b[?2026l"]
        \\
    ;
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try castFrames(gpa, cast, null, &aw.writer);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.written(), "\n"), '\n');
    const Seen = struct { t: f64, screen: []const u8, history_added: []const u8 };
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

    const first = try std.json.parseFromSliceLeaky(Seen, arena.allocator(), lines.next().?, opts);
    try std.testing.expectApproxEqAbs(0.1, first.t, 1e-9);
    try std.testing.expectEqualStrings("two\n\n", first.screen);
    try std.testing.expectEqualStrings("one\n", first.history_added);

    // t=0.2 ended inside the open 2026 update, so the next frame is t=0.3.
    const second = try std.json.parseFromSliceLeaky(Seen, arena.allocator(), lines.next().?, opts);
    try std.testing.expectApproxEqAbs(0.3, second.t, 1e-9);
    try std.testing.expectEqualStrings("two\nthree\n", second.screen);
    try std.testing.expectEqualStrings("", second.history_added);
    try std.testing.expect(lines.next() == null);
}

test "cast replay: a clear and a reprint in one frame is a reset with every reprinted line new" {
    const cast =
        \\{"version": 2, "width": 10, "height": 2}
        \\[0.1, "o", "one\r\ntwo\r\n"]
        \\[0.2, "o", "\u001b[3J\u001b[H\u001b[2Jx\r\ny\r\nz\r\n"]
        \\
    ;
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try castFrames(gpa, cast, null, &aw.writer);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, aw.written(), "\n"), '\n');
    const Seen = struct { history_added: []const u8, history_reset: bool };
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

    const first = try std.json.parseFromSliceLeaky(Seen, arena.allocator(), lines.next().?, opts);
    try std.testing.expect(!first.history_reset);
    try std.testing.expectEqualStrings("one\n", first.history_added);
    const second = try std.json.parseFromSliceLeaky(Seen, arena.allocator(), lines.next().?, opts);
    try std.testing.expect(second.history_reset);
    try std.testing.expectEqualStrings("x\ny\n", second.history_added);
}

test "cast replay: styles name the first non-blank cell of each row" {
    const cast =
        \\{"version": 2, "width": 12, "height": 3}
        \\[0.1, "o", "  \u001b[1;31mred\u001b[0m\r\n\u001b[38;2;1;2;3;48;5;7mtrue\u001b[0m\r\nplain"]
        \\
    ;
    const gpa = std.testing.allocator;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try castFrames(gpa, cast, null, &aw.writer);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const Seen = struct { styles: []const []const u8 };
    const frame = try std.json.parseFromSliceLeaky(Seen, arena.allocator(), std.mem.trimEnd(u8, aw.written(), "\n"), .{
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqual(@as(usize, 3), frame.styles.len);
    try std.testing.expectEqualStrings("fg=p1 bg=- bold", frame.styles[0]);
    try std.testing.expectEqualStrings("fg=#010203 bg=p7", frame.styles[1]);
    try std.testing.expectEqualStrings("fg=- bg=-", frame.styles[2]);
}

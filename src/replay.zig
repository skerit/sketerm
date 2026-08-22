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

const std = @import("std");
const cell_mod = @import("grid/cell.zig");
const Parser = @import("parser/vt.zig").Parser;
const Event = @import("parser/event.zig").Event;
const Screen = @import("grid/screen.zig").Screen;
const StylePool = @import("grid/style_pool.zig").Pool;

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

pub fn main(init: std.process.Init.Minimal) !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print("usage: replay <capture.bin> [cols rows]\n", .{});
        return 1;
    }
    const path = std.mem.span(argv[1]);
    var cols: u16 = 120;
    var rows: u16 = 30;
    if (argv.len > 2) cols = try std.fmt.parseInt(u16, std.mem.span(argv[2]), 10);
    if (argv.len > 3) rows = try std.fmt.parseInt(u16, std.mem.span(argv[3]), 10);

    // libc file IO — the Zig 0.16 std.fs/Io API churns; the project
    // reads files through libc everywhere (see config.zig).
    const cstd = @cImport({
        @cInclude("stdio.h");
    });
    const fp = cstd.fopen(path.ptr, "rb") orelse {
        std.debug.print("replay: cannot open {s}\n", .{path});
        return 1;
    };
    defer _ = cstd.fclose(fp);
    _ = cstd.fseek(fp, 0, cstd.SEEK_END);
    const fsize: usize = @intCast(cstd.ftell(fp));
    _ = cstd.fseek(fp, 0, cstd.SEEK_SET);
    const bytes = try allocator.alloc(u8, fsize);
    defer allocator.free(bytes);
    if (cstd.fread(bytes.ptr, 1, fsize, fp) != fsize) {
        std.debug.print("replay: short read\n", .{});
        return 1;
    }

    var pool = try StylePool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, cols, rows);
    defer screen.deinit();

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

//! Parser microbenchmark — measures bytes/sec through the VT500
//! state machine into the Screen. No GL, no PTY, no I/O cost.
//!
//! Run with:  zig build bench-parser
//!
//! Output is "throughput: NNN MB/s" + breakdown per workload.

const std = @import("std");
const Parser = @import("parser/vt.zig").Parser;
const Event = @import("parser/event.zig").Event;
const Screen = @import("grid/screen.zig").Screen;
const Pool = @import("grid/style_pool.zig").Pool;
const profile_mod = @import("util/profile.zig");

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

const Workload = struct {
    name: []const u8,
    sample: []const u8,
    repeats: usize,
};

fn runOne(allocator: std.mem.Allocator, w: Workload) !void {
    var pool = try Pool.init(allocator);
    defer pool.deinit();
    const screen = try Screen.init(allocator, &pool, 80, 24);
    defer screen.deinit();
    var ctx = Ctx{ .screen = screen, .allocator = allocator };
    var parser = Parser.init(allocator);
    defer parser.deinit();

    const total_bytes: usize = w.sample.len * w.repeats;
    const start = profile_mod.nanoTimestamp();
    var i: usize = 0;
    while (i < w.repeats) : (i += 1) {
        parser.advance(w.sample, emit, @ptrCast(&ctx));
    }
    const elapsed_ns: i128 = profile_mod.nanoTimestamp() - start;
    const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const mb: f64 = @as(f64, @floatFromInt(total_bytes)) / (1024.0 * 1024.0);
    const mbps: f64 = mb / elapsed_s;
    std.debug.print(
        "{s:<28} {d:>10.2} MB in {d:>6.3}s = {d:>7.1} MB/s\n",
        .{ w.name, mb, elapsed_s, mbps },
    );
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Pre-compose a few workloads. Each `sample` represents one
    // "burst" the parser sees; `repeats` controls total bytes.

    // 1. Plain ASCII text + newlines (fast path, no escape sequences).
    const plain =
        "The quick brown fox jumps over the lazy dog. " ++
        "Pack my box with five dozen liquor jugs.\n" ++
        "Sphinx of black quartz, judge my vow.\n";

    // 2. Heavy SGR usage — every char wrapped in a colour change.
    var sgr_buf: [1024]u8 = undefined;
    var sgr_writer = std.Io.Writer.fixed(&sgr_buf);
    var k: u8 = 30;
    while (k <= 37) : (k += 1) {
        try sgr_writer.print("\x1b[{d}m{c}{c}", .{ k, 'A' + k - 30, 'a' + k - 30 });
    }
    try sgr_writer.writeAll("\x1b[0m\n");
    const sgr = sgr_writer.buffered();

    // 3. Truecolor SGR (most expensive parameter parsing path).
    const truecolor =
        "\x1b[38;2;255;128;0;48;2;0;0;0mhello\x1b[0m\n" ++
        "\x1b[38;2;0;255;128;48;2;32;32;32mworld\x1b[0m\n";

    // 4. CSI cursor moves — typical TUI traffic.
    const csi_moves =
        "\x1b[2J\x1b[H\x1b[5;10HX\x1b[1;1H\x1b[K" ++
        "\x1b[10;20HY\x1b[5A\x1b[3B\x1b[2C\x1b[1D\x1b[10;1H";

    // 4b. Truecolor gradient — every cell a UNIQUE color, the style
    // pool's worst case (image-as-halfblocks, gradient prompts).
    const grad_buf = try allocator.alloc(u8, 256 * 1024);
    defer allocator.free(grad_buf);
    var grad_writer = std.Io.Writer.fixed(grad_buf);
    var gi: u32 = 0;
    while (gi < 4096) : (gi += 1) {
        try grad_writer.print("\x1b[38;2;{d};{d};{d}m█", .{ gi & 0xFF, (gi >> 4) & 0xFF, (gi * 7) & 0xFF });
        if (gi % 64 == 63) try grad_writer.writeAll("\n");
    }
    try grad_writer.writeAll("\x1b[0m\n");
    const gradient = grad_writer.buffered();

    // 5. UTF-8 mixed (CJK + emoji).
    const utf8_mix =
        "Hello 中国 こんにちは 한국 🚀🎉🔥\n";

    const workloads = [_]Workload{
        .{ .name = "plain ASCII",        .sample = plain,     .repeats = 50_000 },
        .{ .name = "SGR colour churn",   .sample = sgr,       .repeats = 50_000 },
        .{ .name = "truecolor SGR",      .sample = truecolor, .repeats = 50_000 },
        .{ .name = "CSI cursor moves",   .sample = csi_moves, .repeats = 100_000 },
        .{ .name = "truecolor gradient", .sample = gradient,  .repeats = 2_000 },
        .{ .name = "UTF-8 mix (CJK+emoji)", .sample = utf8_mix, .repeats = 50_000 },
    };

    std.debug.print("=== sketerm parser microbench ===\n", .{});
    std.debug.print("{s:<28} {s:>10}    {s:>6}   {s:>7}\n", .{ "workload", "bytes", "time", "MB/s" });
    std.debug.print("---------------------------------------------------------------\n", .{});
    for (workloads) |wkld| {
        try runOne(allocator, wkld);
    }
}

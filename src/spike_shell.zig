// Headless smoke runner: spawn bash with a script, feed PTY output
// through the parser into the Screen, dump the final grid to stdout.
//
// Run with:  zig build spike-shell
//
// Verifies the PTY → parser → screen pipeline end-to-end without GTK.

const std = @import("std");
const c = @import("c.zig").c;
const Pty = @import("pty.zig").Pty;
const Parser = @import("parser/vt.zig").Parser;
const Event = @import("parser/event.zig").Event;
const Screen = @import("grid/screen.zig").Screen;
const StylePool = @import("grid/style_pool.zig").Pool;

const Ctx = struct {
    screen: *Screen,
    allocator: std.mem.Allocator,
    image_count: u32 = 0,
};

fn onImage(ctx: ?*anyopaque, img: Screen.ImageEvent) void {
    const c_ctx: *Ctx = @ptrCast(@alignCast(ctx.?));
    c_ctx.image_count += 1;
    std.debug.print("got image {}: {d}x{d} at row={d} col={d}\n", .{ c_ctx.image_count, img.width, img.height, img.row, img.col });
}

fn emit(user: ?*anyopaque, ev: Event) void {
    const ctx: *Ctx = @ptrCast(@alignCast(user.?));
    var mut_ev = ev;
    ctx.screen.apply(ev);
    mut_ev.deinit(ctx.allocator);
}

pub fn main() u8 {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const argv = [_][*:0]const u8{
        "/bin/bash",
        "-c",
        // Plain + colors + scroll + a hand-rolled sixel.
        "printf '\\033]0;sketerm smoke\\007'; " ++
        "echo Hello, $USER; " ++
        "for i in $(seq 1 50); do echo \"line $i\"; done; " ++
        // 6x6 red square sixel: define color 1 = R 100/0/0, select, ~ × 6, terminate.
        "printf '\\033Pq#1;2;100;0;0#1!6~\\033\\\\'; " ++
        "echo done",
    };
    const pty = Pty.spawn(.{ .argv = &argv, .rows = 24, .cols = 80 }) catch return 1;
    defer pty.closeAndReap();

    var pool = StylePool.init(allocator) catch return 1;
    defer pool.deinit();
    const screen = Screen.init(allocator, &pool, 80, 24) catch return 1;
    defer screen.deinit();

    var ctx = Ctx{ .screen = screen, .allocator = allocator };
    screen.sink.ctx = @ptrCast(&ctx);
    screen.sink.on_image = onImage;

    var parser = Parser.init(allocator);
    defer parser.deinit();

    // Read for up to 1 second.
    const start = std.time.milliTimestamp();
    var buf: [4096]u8 = undefined;
    while (std.time.milliTimestamp() - start < 1000) {
        var pfd = c.struct_pollfd{
            .fd = pty.master_fd,
            .events = c.POLLIN,
            .revents = 0,
        };
        const ready = c.poll(&pfd, 1, 200);
        if (ready < 0) break;
        if (ready == 0) continue;
        if (pfd.revents & (c.POLLHUP | c.POLLERR) != 0) {
            // Drain remaining.
            const n = c.read(pty.master_fd, &buf, buf.len);
            if (n > 0) parser.advance(buf[0..@intCast(n)], emit, @ptrCast(&ctx));
            break;
        }
        if (pfd.revents & c.POLLIN != 0) {
            const n = c.read(pty.master_fd, &buf, buf.len);
            if (n <= 0) break;
            parser.advance(buf[0..@intCast(n)], emit, @ptrCast(&ctx));
        }
    }

    // Dump the screen to stdout.
    var stdout_buf: [16384]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    stdout.interface.print("=== sketerm smoke run ===\n", .{}) catch return 2;
    stdout.interface.print("cursor: row={d} col={d}\n", .{ screen.row, screen.col }) catch {};
    stdout.interface.print("scrollback: {d} lines\n", .{screen.scrollbackCount()}) catch {};
    stdout.interface.print("--- grid (active) ---\n", .{}) catch {};
    screen.dump(&stdout.interface) catch return 2;
    stdout.interface.print("=== end ===\n", .{}) catch {};
    stdout.interface.flush() catch return 2;
    return 0;
}

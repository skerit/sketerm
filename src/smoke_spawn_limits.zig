//! Spawn-dimension validation shared by the monolith and broker smoke rigs.

const std = @import("std");
const c = @import("c.zig").c;
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");

const ACCEPTED_ROWS: u16 = 512;
const ACCEPTED_COLS: u16 = @intCast(wire.MAX_TERMINAL_CELLS / ACCEPTED_ROWS);

comptime {
    if (@as(u32, ACCEPTED_ROWS) * ACCEPTED_COLS != wire.MAX_TERMINAL_CELLS)
        @compileError("spawn-limit smoke boundary must equal MAX_TERMINAL_CELLS");
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("smoke-spawn-limits: FAIL: {s}\n", .{msg});
    std.process.exit(1);
}

fn hello(allocator: std.mem.Allocator, conn: *client_mod.Conn) void {
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("hello send");
    (conn.recvExpect(&.{.welcome}) catch fail("welcome")).deinit(allocator);
}

const ListReply = struct {
    sessions: []const struct {
        name: []const u8 = "",
        rows: u16 = 0,
        cols: u16 = 0,
    } = &.{},
};

fn sessionState(allocator: std.mem.Allocator, conn: *client_mod.Conn, name: []const u8) enum { absent, wrong_geometry, expected_geometry } {
    conn.sendFrame(.list, "") catch fail("list send");
    const frame = conn.recvExpect(&.{.welcome}) catch fail("list reply");
    defer frame.deinit(allocator);
    var parsed = std.json.parseFromSlice(ListReply, allocator, frame.payload, .{
        .ignore_unknown_fields = true,
    }) catch fail("list parse");
    defer parsed.deinit();
    for (parsed.value.sessions) |session| {
        if (!std.mem.eql(u8, session.name, name)) continue;
        return if (session.rows == ACCEPTED_ROWS and session.cols == ACCEPTED_COLS)
            .expected_geometry
        else
            .wrong_geometry;
    }
    return .absent;
}

/// Reject every invalid boundary before a session or child can appear.
pub fn runRejected(allocator: std.mem.Allocator, sock_path: []const u8) void {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("connect");
    defer conn.deinit();
    hello(allocator, &conn);

    var marker_buf: [128]u8 = undefined;
    const marker = std.fmt.bufPrintZ(&marker_buf, "/tmp/sketerm-spawn-limit-{d}", .{c.getpid()}) catch unreachable;
    _ = c.unlink(marker.ptr);
    defer _ = c.unlink(marker.ptr);
    var command_buf: [256]u8 = undefined;
    const command = std.fmt.bufPrint(&command_buf, "touch {s}; sleep 30", .{marker}) catch unreachable;

    const Case = struct { label: []const u8, rows: u16, cols: u16 };
    const cases = [_]Case{
        .{ .label = "zero-rows", .rows = 0, .cols = 80 },
        .{ .label = "zero-cols", .rows = 24, .cols = 0 },
        .{ .label = "1001-rows", .rows = wire.MAX_TERMINAL_AXIS + 1, .cols = 1 },
        .{ .label = "1001-cols", .rows = 1, .cols = wire.MAX_TERMINAL_AXIS + 1 },
        .{ .label = "65535-rows", .rows = std.math.maxInt(u16), .cols = 1 },
        .{ .label = "65535-cols", .rows = 1, .cols = std.math.maxInt(u16) },
        .{ .label = "cell-boundary", .rows = ACCEPTED_ROWS + 1, .cols = ACCEPTED_COLS },
    };
    for (cases) |case| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "spawn-limit-{s}", .{case.label}) catch unreachable;
        conn.sendJson(.spawn, .{
            .name = name,
            .argv = [_][]const u8{ "/bin/sh", "-c", command },
            .rows = case.rows,
            .cols = case.cols,
            .local = true,
        }) catch fail("rejected spawn send");
        const reply = conn.recvExpect(&.{.err}) catch fail("invalid dimensions were not rejected");
        defer reply.deinit(allocator);
        const ErrorReply = struct { @"error": []const u8 = "" };
        var parsed = std.json.parseFromSlice(ErrorReply, allocator, reply.payload, .{}) catch
            fail("spawn error parse");
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.@"error", wire.TERMINAL_SIZE_PROTOCOL_ERROR))
            fail("spawn returned an unstable dimension error");
    }

    _ = c.usleep(100_000);
    if (c.access(marker.ptr, c.F_OK) == 0) fail("a rejected request started its child");
    if (sessionState(allocator, &conn, "spawn-limit-max") != .absent)
        fail("unexpected accepted-boundary session before its spawn");

    conn.sendFrame(.list, "") catch fail("rejection list send");
    const list_frame = conn.recvExpect(&.{.welcome}) catch fail("rejection list reply");
    defer list_frame.deinit(allocator);
    var list = std.json.parseFromSlice(ListReply, allocator, list_frame.payload, .{
        .ignore_unknown_fields = true,
    }) catch fail("rejection list parse");
    defer list.deinit();
    if (list.value.sessions.len != 0) fail("a rejected request created a session");
}

/// Accept the exact total-cell maximum and clean up its process and session.
pub fn runAcceptedMaximum(allocator: std.mem.Allocator, sock_path: []const u8) void {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("max connect");
    defer conn.deinit();
    hello(allocator, &conn);

    conn.sendJson(.spawn, .{
        .name = "spawn-limit-max",
        .argv = [_][]const u8{ "/bin/sleep", "30" },
        .rows = ACCEPTED_ROWS,
        .cols = ACCEPTED_COLS,
        .local = true,
    }) catch fail("max spawn send");
    const ok = conn.recvExpect(&.{.ok}) catch fail("maximum dimensions were rejected");
    const OkReply = struct { pid: c.pid_t = 0 };
    var parsed = std.json.parseFromSlice(OkReply, allocator, ok.payload, .{
        .ignore_unknown_fields = true,
    }) catch fail("max spawn reply parse");
    const child_pid = parsed.value.pid;
    parsed.deinit();
    ok.deinit(allocator);
    if (child_pid <= 0) fail("max spawn returned no child pid");

    var listed = false;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        switch (sessionState(allocator, &conn, "spawn-limit-max")) {
            .expected_geometry => {
                listed = true;
                break;
            },
            .absent, .wrong_geometry => _ = c.usleep(20_000),
        }
    }
    if (!listed) fail("maximum dimensions were not listed with their geometry");

    conn.sendJson(.kill, .{ .name = "spawn-limit-max" }) catch fail("max kill send");
    (conn.recvExpect(&.{.ok}) catch fail("max kill reply")).deinit(allocator);
    tries = 0;
    while (tries < 100 and c.kill(child_pid, 0) == 0) : (tries += 1)
        _ = c.usleep(20_000);
    if (c.kill(child_pid, 0) == 0) fail("maximum-dimension child survived cleanup");
    if (sessionState(allocator, &conn, "spawn-limit-max") != .absent)
        fail("maximum-dimension session survived cleanup");
}

//! `sketerm-mcp`: the MCP server as its own GTK-free binary, for hosts whose
//! GTK is too old (or absent) for the GUI. Same server as `sketerm mcp`;
//! argv after the program name is what `sketerm mcp` receives after "mcp".

const std = @import("std");
const selfexec = @import("mux/selfexec.zig");

pub fn main(init: std.process.Init.Minimal) u8 {
    const argv = init.args.vector;
    // The tor SSH route names our own executable as its ProxyCommand
    // (`mux/sshroute.zig`), so this binary must answer that mode too.
    if (argv.len == 5 and selfexec.Mode.socks5_connect.is(std.mem.span(argv[1]))) {
        return @import("mux/socks5_client.zig").serve(
            std.mem.span(argv[2]),
            std.mem.span(argv[3]),
            std.mem.span(argv[4]),
        );
    }

    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    @import("util/crashlog.zig").install();

    const mcp_args = allocator.alloc([]const u8, argv.len - 1) catch return 1;
    defer allocator.free(mcp_args);
    for (argv[1..], 0..) |a, n| mcp_args[n] = std.mem.span(a);
    return @import("ipc/mcp.zig").run(allocator, mcp_args);
}

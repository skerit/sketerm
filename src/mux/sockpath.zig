//! Mux socket-path policy + sockaddr_un fill, shared by daemon and
//! client so the client graph needs no daemon import. libc only.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");

/// Fill a sockaddr_un for bind/connect.
pub fn fillSockaddrUn(addr: *c.struct_sockaddr_un, path: []const u8) error{BadPath}!void {
    addr.* = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path.len >= addr.sun_path.len) return error.BadPath;
    @memcpy(addr.sun_path[0..path.len], path);
}

/// The per-user daemon's default socket path.
pub fn defaultSocketPath(allocator: std.mem.Allocator) ![]u8 {
    const rt = platform.runtimeDir();
    return std.fmt.allocPrint(allocator, "{s}/sketerm/mux.sock", .{rt});
}

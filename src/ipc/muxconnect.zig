//! Config-aware SSH connection helpers for headless IPC clients.

const std = @import("std");
const Config = @import("../config.zig").Config;
const muxclient = @import("../mux/client.zig");

pub fn connectSsh(allocator: std.mem.Allocator, host: []const u8) !muxclient.Conn {
    var cfg = Config.load(allocator);
    defer cfg.deinit();
    return muxclient.Conn.connectSshWithEndpoint(allocator, host, cfg.mux_tor_socks_endpoint);
}

pub fn connectSshOnce(allocator: std.mem.Allocator, host: []const u8) !muxclient.Conn {
    var cfg = Config.load(allocator);
    defer cfg.deinit();
    return muxclient.Conn.connectSshOnceWithEndpoint(allocator, host, cfg.mux_tor_socks_endpoint);
}

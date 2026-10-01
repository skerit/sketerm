//! Config-aware SSH connection helpers for headless IPC clients.

const std = @import("std");
const Config = @import("../config.zig").Config;
const muxclient = @import("../mux/client.zig");

pub fn connectSsh(allocator: std.mem.Allocator, host: []const u8) !muxclient.Conn {
    var cfg = Config.load(allocator);
    defer cfg.deinit();
    return muxclient.Conn.connectSshWith(allocator, host, cfg.muxConnectOptions());
}

pub fn connectSshOnce(allocator: std.mem.Allocator, host: []const u8) !muxclient.Conn {
    var cfg = Config.load(allocator);
    defer cfg.deinit();
    return muxclient.Conn.connectSshOnceWith(allocator, host, cfg.muxConnectOptions());
}

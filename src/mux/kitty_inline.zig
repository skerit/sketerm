//! Daemon-side kitty-graphics file fetch.
//!
//! Over a mux transport the file-based kitty transmission media
//! (`t=f` path, `t=t` tempfile, `t=s` POSIX shm) reference files on
//! the REMOTE host — the attached GUI could never read them. The
//! daemon runs on that host, so it reads the data itself and
//! rewrites the APC to an inline `t=d` transmission before
//! broadcasting. Apps that "don't work over SSH" just work.
//!
//! Tempfile/shm deletion is honored daemon-side, exactly as a
//! terminal would: `t=t` paths are unlinked after reading, `t=s`
//! objects are removed via their /dev/shm path.

const std = @import("std");
const c = @import("../c.zig").c;
const kitty = @import("../parser/kitty_image.zig");
const pathZ = @import("../util/pathz.zig").pathZ;

/// Raw-bytes cap. The whole rewritten APC must fit a wire EVENTS
/// frame (16 MB cap) alongside the rest of the drain batch; base64
/// expands 4/3, so 6 MB raw ≈ 8 MB encoded leaves ample headroom.
/// Larger files pass through unchanged (and fail on the client,
/// same as plain ssh).
pub const MAX_RAW_BYTES: usize = 6 * 1024 * 1024;

/// If `apc_bytes` is a kitty file/tempfile/shm transmission, fetch
/// the data locally and return a replacement APC with `t=d` and the
/// base64 payload inlined. Null = not applicable / fetch failed
/// (caller forwards the original event untouched).
pub fn rewrite(allocator: std.mem.Allocator, apc_bytes: []const u8) ?[]u8 {
    const cmd = kitty.parse(apc_bytes) catch return null;
    switch (cmd.medium) {
        'f', 't', 's' => {},
        else => return null,
    }
    if (cmd.payload.len == 0) return null;
    // File transmissions carry the whole path in one APC; a chunked
    // (m=1) file transmission is malformed — leave it alone.
    if (cmd.more != 0) return null;

    // Payload is the base64-encoded path.
    var path_buf: [4096]u8 = undefined;
    const decoder = std.base64.standard.Decoder;
    const plen = decoder.calcSizeForSlice(cmd.payload) catch return null;
    if (plen >= path_buf.len) return null;
    decoder.decode(path_buf[0..plen], cmd.payload) catch return null;
    const path_raw = std.mem.trimEnd(u8, path_buf[0..plen], "\x00 \r\n\t");

    // POSIX shm objects live under /dev/shm on Linux.
    var shm_buf: [4096]u8 = undefined;
    const path = if (cmd.medium == 's') blk: {
        const name = std.mem.trimStart(u8, path_raw, "/");
        break :blk std.fmt.bufPrint(&shm_buf, "/dev/shm/{s}", .{name}) catch return null;
    } else path_raw;

    const data = readFileCapped(allocator, path) orelse return null;
    defer allocator.free(data);

    // The spec makes the terminal responsible for cleanup of
    // tempfiles and shm objects; the daemon is the terminal here.
    if (cmd.medium == 't' or cmd.medium == 's') {
        var del_buf: [4096]u8 = undefined;
        if (pathZ(&del_buf, path)) |p| {
            _ = c.unlink(p);
        } else |_| {}
    }

    return buildInlineApc(allocator, apc_bytes, data) catch null;
}

fn readFileCapped(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var z_buf: [4096]u8 = undefined;
    const p = pathZ(&z_buf, path) catch return null;
    const fp = c.fopen(p, "rb") orelse return null;
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return null;
    const size_long = c.ftell(fp);
    if (size_long <= 0 or size_long > MAX_RAW_BYTES) return null;
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) return null;
    const size: usize = @intCast(size_long);
    const out = allocator.alloc(u8, size) catch return null;
    if (c.fread(out.ptr, 1, size, fp) != size) {
        allocator.free(out);
        return null;
    }
    return out;
}

/// New APC: original control keys minus `t=`, plus `t=d`, payload
/// replaced with base64(data). Textual filtering (not a re-emit of
/// the parsed struct) so keys we don't model survive unchanged.
fn buildInlineApc(allocator: std.mem.Allocator, original: []const u8, data: []const u8) ![]u8 {
    const semi = std.mem.indexOfScalar(u8, original, ';') orelse original.len;
    const control = original[1..semi]; // skip leading 'G'

    const encoder = std.base64.standard.Encoder;
    const b64_len = encoder.calcSize(data.len);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, control.len + b64_len + 16);
    try out.append(allocator, 'G');

    var it = std.mem.splitScalar(u8, control, ',');
    while (it.next()) |tok| {
        if (tok.len == 0 or std.mem.startsWith(u8, tok, "t=")) continue;
        try out.appendSlice(allocator, tok);
        try out.append(allocator, ',');
    }
    try out.appendSlice(allocator, "t=d;");

    const start = out.items.len;
    try out.resize(allocator, start + b64_len);
    _ = encoder.encode(out.items[start..], data);
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn b64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, enc.calcSize(bytes.len));
    _ = enc.encode(out, bytes);
    return out;
}

fn mkTempWith(contents: []const u8) ![]u8 {
    var tmpl = "/tmp/sketerm-kitty-XXXXXX".*;
    const fd = c.mkstemp(&tmpl);
    if (fd < 0) return error.TempFailed;
    defer _ = c.close(fd);
    if (c.write(fd, contents.ptr, contents.len) != @as(isize, @intCast(contents.len))) return error.TempFailed;
    return testing.allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(&tmpl))));
}

test "rewrite: t=f becomes inline t=d, file kept" {
    const a = testing.allocator;
    const path = try mkTempWith("PNGDATA");
    defer {
        var z: [4096]u8 = undefined;
        _ = c.unlink(pathZ(&z, path) catch unreachable);
        a.free(path);
    }
    const path_b64 = try b64Alloc(a, path);
    defer a.free(path_b64);
    const apc = try std.fmt.allocPrint(a, "Gf=100,t=f,a=T,i=7;{s}", .{path_b64});
    defer a.free(apc);

    const out = rewrite(a, apc) orelse return error.RewriteFailed;
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "t=d;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "t=f") == null);
    try testing.expect(std.mem.indexOf(u8, out, "i=7") != null);
    const data_b64 = try b64Alloc(a, "PNGDATA");
    defer a.free(data_b64);
    try testing.expect(std.mem.endsWith(u8, out, data_b64));
    // t=f: the file must survive.
    var z2: [4096]u8 = undefined;
    try testing.expect(c.access(try pathZ(&z2, path), c.F_OK) == 0);
}

test "rewrite: t=t deletes the tempfile after reading" {
    const a = testing.allocator;
    const path = try mkTempWith("TMPDATA");
    defer a.free(path);
    const path_b64 = try b64Alloc(a, path);
    defer a.free(path_b64);
    const apc = try std.fmt.allocPrint(a, "Gf=32,s=1,v=1,t=t,a=T;{s}", .{path_b64});
    defer a.free(apc);

    const out = rewrite(a, apc) orelse return error.RewriteFailed;
    defer a.free(out);
    var z: [4096]u8 = undefined;
    try testing.expect(c.access(try pathZ(&z, path), c.F_OK) != 0);
}

test "rewrite: direct and non-kitty APCs pass through untouched" {
    const a = testing.allocator;
    try testing.expect(rewrite(a, "Gf=100,t=d,a=T;QUJD") == null);
    try testing.expect(rewrite(a, "not-kitty") == null);
    // Missing file: leave unchanged (client fails the same as ssh).
    const gone_b64 = try b64Alloc(a, "/nonexistent/sketerm-test");
    defer a.free(gone_b64);
    const apc = try std.fmt.allocPrint(a, "Gt=f,a=T;{s}", .{gone_b64});
    defer a.free(apc);
    try testing.expect(rewrite(a, apc) == null);
}

//! Streaming file hashes shared by deployment and daemon diagnostics.

const std = @import("std");
const c = @import("../c.zig").c;
const pathZ = @import("pathz.zig").pathZ;

pub const Sha256 = struct {
    hex: [64]u8,
    size: u64,
};

/// Hash a regular file without loading it into memory.
pub fn sha256File(path: []const u8) ?Sha256 {
    var path_buf: [4096]u8 = undefined;
    const fd = c.open(pathZ(&path_buf, path) catch return null, c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFREG) return null;

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var size: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n > 0) {
            hash.update(buf[0..@intCast(n)]);
            size +|= @intCast(n);
            continue;
        }
        if (n == 0) break;
        if (std.posix.errno(n) == .INTR) continue;
        return null;
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    var hex: [64]u8 = undefined;
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = digits[byte >> 4];
        hex[i * 2 + 1] = digits[byte & 0x0f];
    }
    return .{ .hex = hex, .size = size };
}

test "sha256File hashes bytes and reports size" {
    var name = "/tmp/sketerm-filehash-XXXXXX".*;
    const fd = c.mkstemp(&name);
    if (fd < 0) return error.SkipZigTest;
    defer {
        _ = c.close(fd);
        _ = c.unlink(&name);
    }
    const bytes = "portable mux\n";
    try std.testing.expectEqual(@as(isize, bytes.len), c.write(fd, bytes.ptr, bytes.len));
    const result = sha256File(std.mem.span(@as([*:0]const u8, @ptrCast(&name)))).?;
    try std.testing.expectEqual(@as(u64, bytes.len), result.size);
    try std.testing.expectEqualStrings(
        "aa01138087672177e199f5dd371bead0f60fafdf89597e6af0c33b6c68d732f3",
        &result.hex,
    );
}

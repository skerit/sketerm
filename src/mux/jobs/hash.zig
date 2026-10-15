//! The hash job, plus the prefix hash a resumed copy verifies against.

const std = @import("std");
const c = @import("../../c.zig").c;
const pathz = @import("../../util/pathz.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;
const Progress = fsjob.Progress;
const CHUNK = fsjob.CHUNK;

// ── hash ────────────────────────────────────────────────────────

pub fn hashPrefix(path: []const u8, limit: u64, progress: ?*Progress) ?[Sha256.digest_length]u8 {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return null;
    const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var h = Sha256.init(.{});
    var buf: [CHUNK]u8 = undefined;
    var left = limit;
    while (left > 0) {
        const want: usize = @intCast(@min(left, buf.len));
        const n = c.read(fd, &buf, want);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        h.update(buf[0..@intCast(n)]);
        left -= @intCast(n);
        if (progress) |pr| if (!pr.add(@intCast(n))) return null;
    }
    if (left != 0) return null; // short file
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn runHash(job: *const Job) u8 {
    const spec = job.spec;
    var st: c.struct_stat = undefined;
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, spec.src) catch return job.emitError("path too long");
    if (c.stat(p, &st) != 0) return job.emitErrno("stat");
    const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;
    var progress = Progress{ .total = size };
    const digest = hashPrefix(spec.src, size, &progress) orelse return job.emitErrno("read");
    var hex: [Sha256.digest_length * 2]u8 = undefined;
    for (digest, 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    }
    job.emit(.{ .ev = "done", .done = size, .total = size, .hash = hex[0..] });
    return 0;
}

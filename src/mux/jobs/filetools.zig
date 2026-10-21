//! Single-file tools: diff, split, combine and secure delete.

const std = @import("std");
const c = @import("../../c.zig").c;
const pathz = @import("../../util/pathz.zig");
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;

/// `diff -u src dst` on this host, streamed as one `line` event per
/// diff line (bounded). Identical files complete with zero lines;
/// binary files get diff's own one-line verdict.
pub fn runDiff(job: *const Job) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    if (spec.dst.len == 0) return job.emitError("diff needs two paths");
    var cmd: [8600:0]u8 = undefined;
    var w = std.Io.Writer.fixed(cmd[0 .. cmd.len - 1]);
    w.writeAll("diff -u -- '") catch return job.emitError("path too long");
    for (spec.src) |ch| {
        if (ch == '\'') w.writeAll("'\\''") catch return job.emitError("path too long") else w.writeByte(ch) catch return job.emitError("path too long");
    }
    w.writeAll("' '") catch return job.emitError("path too long");
    for (spec.dst) |ch| {
        if (ch == '\'') w.writeAll("'\\''") catch return job.emitError("path too long") else w.writeByte(ch) catch return job.emitError("path too long");
    }
    w.writeAll("' 2>&1 | head -c 262144") catch return job.emitError("path too long");
    cmd[w.buffered().len] = 0;
    const fp = c.popen(&cmd, "r") orelse return job.emitError("cannot run diff");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        out.appendSlice(allocator, buf[0..n]) catch break;
        if (out.items.len > 300 * 1024) break;
    }
    _ = c.pclose(fp);
    var emitted: u64 = 0;
    var it = std.mem.splitScalar(u8, out.items, '\n');
    while (it.next()) |line| {
        if (emitted >= 4000) {
            job.emit(.{ .ev = "line", .line = emitted, .text = "[diff truncated]" });
            emitted += 1;
            break;
        }
        if (line.len == 0 and it.peek() == null) break;
        job.emit(.{ .ev = "line", .line = emitted, .text = line[0..@min(line.len, 2048)] });
        emitted += 1;
    }
    job.emit(.{ .ev = "done", .done = emitted, .total = emitted });
    return 0;
}

/// "10M"/"1G"/plain bytes → bytes; null on junk or zero.
fn parsePartSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var digits = s;
    var mult: u64 = 1;
    switch (s[s.len - 1]) {
        'k', 'K' => {
            mult = 1 << 10;
            digits = s[0 .. s.len - 1];
        },
        'm', 'M' => {
            mult = 1 << 20;
            digits = s[0 .. s.len - 1];
        },
        'g', 'G' => {
            mult = 1 << 30;
            digits = s[0 .. s.len - 1];
        },
        else => {},
    }
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    if (n == 0) return null;
    return std.math.mul(u64, n, mult) catch null;
}

/// Split `src` into `<src>.001`, `.002`, … of `pattern` bytes each
/// (TC convention). Existing part files refuse the whole job rather
/// than silently overwriting a previous split.
pub fn runSplit(job: *const Job) u8 {
    const spec = job.spec;
    const part_size = parsePartSize(spec.pattern) orelse return job.emitError("bad part size");
    var sz: [4096:0]u8 = undefined;
    const src = pathz.pathZ(&sz, spec.src) catch return job.emitError("path too long");
    var st: c.struct_stat = undefined;
    if (c.lstat(src, &st) != 0) return job.emitErrno("split stat");
    if (st.st_mode & c.S_IFMT != c.S_IFREG) return job.emitError("split needs a regular file");
    const total: u64 = @intCast(st.st_size);
    const parts = if (total == 0) 1 else (total + part_size - 1) / part_size;
    if (parts > 999) return job.emitError("more than 999 parts; pick a larger part size");
    const in = c.open(src, c.O_RDONLY | c.O_CLOEXEC);
    if (in < 0) return job.emitErrno("split open");
    defer _ = c.close(in);
    var done: u64 = 0;
    var part: u32 = 1;
    while (part <= parts) : (part += 1) {
        var pz: [4200:0]u8 = undefined;
        const pp = std.fmt.bufPrintSentinel(&pz, "{s}.{d:0>3}", .{ spec.src, part }, 0) catch return job.emitError("path too long");
        const out = c.open(pp.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, st.st_mode & 0o777);
        if (out < 0) return job.emitErrno("split part exists or unwritable");
        defer _ = c.close(out);
        var remain: u64 = @min(part_size, total - done);
        var buf: [1 << 16]u8 = undefined;
        while (remain > 0) {
            const want: usize = @intCast(@min(remain, buf.len));
            const n = c.read(in, &buf, want);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n <= 0) return job.emitError("split read failed");
            var off: usize = 0;
            while (off < @as(usize, @intCast(n))) {
                const w = c.write(out, buf[off..].ptr, @as(usize, @intCast(n)) - off);
                if (w < 0 and std.posix.errno(w) == .INTR) continue;
                if (w <= 0) return job.emitError("split write failed");
                off += @intCast(w);
            }
            remain -= @intCast(n);
            done += @intCast(n);
            job.emit(.{ .ev = "progress", .done = done, .total = total });
        }
        if (c.fsync(out) != 0) return job.emitErrno("split fsync");
    }
    job.emit(.{ .ev = "done", .done = total, .total = total });
    return 0;
}

/// Rebuild `<base>` from `<base>.001`… (any first-part path may be
/// given). The destination must not exist yet.
pub fn runCombine(job: *const Job) u8 {
    const spec = job.spec;
    // Strip a trailing ".NNN" to find the base name.
    const dot = std.mem.lastIndexOfScalar(u8, spec.src, '.') orelse return job.emitError("not a split part");
    const ext = spec.src[dot + 1 ..];
    if (ext.len != 3) return job.emitError("not a .NNN split part");
    _ = std.fmt.parseInt(u16, ext, 10) catch return job.emitError("not a .NNN split part");
    const base = spec.src[0..dot];
    var dz: [4096:0]u8 = undefined;
    const dst = pathz.pathZ(&dz, base) catch return job.emitError("path too long");
    const out = c.open(dst, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o644));
    if (out < 0) return job.emitErrno("combine destination exists or unwritable");
    var ok = false;
    defer {
        _ = c.close(out);
        if (!ok) _ = c.unlink(dst);
    }
    var part: u32 = 1;
    var done: u64 = 0;
    while (part <= 999) : (part += 1) {
        var pz: [4200:0]u8 = undefined;
        const pp = std.fmt.bufPrintSentinel(&pz, "{s}.{d:0>3}", .{ base, part }, 0) catch return job.emitError("path too long");
        const in = c.open(pp.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (in < 0) {
            if (part == 1) return job.emitError("no .001 part beside the file");
            break;
        }
        defer _ = c.close(in);
        var buf: [1 << 16]u8 = undefined;
        while (true) {
            const n = c.read(in, &buf, buf.len);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n < 0) return job.emitError("combine read failed");
            if (n == 0) break;
            var off: usize = 0;
            while (off < @as(usize, @intCast(n))) {
                const w = c.write(out, buf[off..].ptr, @as(usize, @intCast(n)) - off);
                if (w < 0 and std.posix.errno(w) == .INTR) continue;
                if (w <= 0) return job.emitError("combine write failed");
                off += @intCast(w);
            }
            done += @intCast(n);
        }
        job.emit(.{ .ev = "progress", .done = done, .total = @as(u64, 0) });
    }
    if (c.fsync(out) != 0) return job.emitErrno("combine fsync");
    ok = true;
    job.emit(.{ .ev = "done", .done = done, .total = done, .path = base });
    return 0;
}

/// One random overwrite pass + fsync + unlink. Regular files only —
/// and honesty demands saying so: on CoW/journaled filesystems the
/// old extents may survive; this is best-effort, like every GUI
/// shredder.
pub fn runSecureDelete(job: *const Job) u8 {
    const spec = job.spec;
    var sz: [4096:0]u8 = undefined;
    const src = pathz.pathZ(&sz, spec.src) catch return job.emitError("path too long");
    var st: c.struct_stat = undefined;
    if (c.lstat(src, &st) != 0) return job.emitErrno("stat");
    if (st.st_mode & c.S_IFMT != c.S_IFREG) return job.emitError("secure delete works on regular files only");
    const total: u64 = @intCast(st.st_size);
    const fd = c.open(src, c.O_WRONLY | c.O_CLOEXEC);
    if (fd < 0) return job.emitErrno("open");
    var closed = false;
    defer if (!closed) {
        _ = c.close(fd);
    };
    // Cheap PRNG stream seeded from real entropy: getentropy per
    // block would cap throughput far below the disk.
    var seed: [8]u8 = undefined;
    if (c.getentropy(&seed, seed.len) != 0) std.mem.writeInt(u64, &seed, @as(u64, @intCast(c.getpid())) ^ total, .little);
    var state = std.mem.readInt(u64, &seed, .little) | 1;
    var buf: [1 << 16]u8 = undefined;
    var done: u64 = 0;
    while (done < total) {
        var i: usize = 0;
        while (i + 8 <= buf.len) : (i += 8) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            std.mem.writeInt(u64, buf[i..][0..8], state, .little);
        }
        const want: usize = @intCast(@min(total - done, buf.len));
        var off: usize = 0;
        while (off < want) {
            const w = c.write(fd, buf[off..].ptr, want - off);
            if (w < 0 and std.posix.errno(w) == .INTR) continue;
            if (w <= 0) return job.emitError("overwrite failed");
            off += @intCast(w);
        }
        done += want;
        job.emit(.{ .ev = "progress", .done = done, .total = total });
    }
    if (c.fsync(fd) != 0) return job.emitErrno("fsync");
    _ = c.close(fd);
    closed = true;
    if (c.unlink(src) != 0) return job.emitErrno("unlink");
    job.emit(.{ .ev = "done", .done = total, .total = total });
    return 0;
}

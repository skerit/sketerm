//! Archive jobs: extract, create, list and single-member extract, all through bsdtar.

const std = @import("std");
const c = @import("../../c.zig").c;
const pathz = @import("../../util/pathz.zig");
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;
const common = @import("common.zig");
const MAX_MATCHES = common.MAX_MATCHES;
const statOf = common.statOf;
const runArgv = common.runArgv;

// ── archives ─────────────────────────────────────────────────────

fn unsafeArchiveMember(name_in: []const u8) bool {
    var name = name_in;
    while (std.mem.startsWith(u8, name, "./")) name = name[2..];
    if (name.len == 0 or name[0] == '/') return true;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

/// List through bsdtar without a shell and reject archive members that
/// could escape the selected extraction directory.
fn archiveMembersSafe(archive: []const u8) bool {
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{archive}) catch return false;
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return false;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        return false;
    }
    if (pid == 0) {
        _ = c.dup2(pipefd[1], 1);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        const argv = [_:null]?[*:0]const u8{ "bsdtar", "-tf", ap.ptr, null };
        _ = c.execvp("bsdtar", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var line: [4096]u8 = undefined;
    var len: usize = 0;
    var safe = true;
    var buf: [8192]u8 = undefined;
    read_loop: while (true) {
        const n = c.read(pipefd[0], &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |ch| {
            if (ch == '\n') {
                if (unsafeArchiveMember(line[0..len])) {
                    safe = false;
                    break :read_loop;
                }
                len = 0;
            } else if (len < line.len) {
                line[len] = ch;
                len += 1;
            } else {
                safe = false;
                break :read_loop;
            }
        }
    }
    if (safe and len > 0) safe = !unsafeArchiveMember(line[0..len]);
    _ = c.close(pipefd[0]);
    if (!safe) _ = c.kill(pid, c.SIGKILL);
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    return safe and c.WIFEXITED(st) and c.WEXITSTATUS(st) == 0;
}

pub fn runExtract(job: *const Job) u8 {
    const spec = job.spec;
    if (spec.dst.len == 0) return job.emitError("extract needs destination directory");
    if (!archiveMembersSafe(spec.src)) return job.emitError("archive is unreadable or contains unsafe paths");
    var dz: [4096]u8 = undefined;
    const dp = pathz.pathZ(&dz, spec.dst) catch return job.emitError("destination path too long");
    if (c.mkdir(dp, 0o755) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST)
        return job.emitErrno("mkdir destination");
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{spec.src}) catch return job.emitError("archive path too long");
    job.emit(.{ .ev = "progress", .done = @as(u64, 0), .total = @as(u64, 0) });
    const argv = [_:null]?[*:0]const u8{
        "bsdtar", "-xf", ap.ptr, "-C", dp, "--no-same-owner", "--safe-writes", null,
    };
    if (!runArgv(&argv)) return job.emitError("archive extraction failed (bsdtar required)");
    job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

/// Stream an archive's member list as match events (bsdtar handles
/// tar/tar.*/zip/7z alike). Only the member table crosses the wire.
pub fn runArchiveList(job: *const Job) u8 {
    const spec = job.spec;
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{spec.src}) catch return job.emitError("archive path too long");
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return job.emitErrno("pipe");
    const pid = c.fork();
    if (pid < 0) return job.emitErrno("fork");
    if (pid == 0) {
        _ = c.dup2(pipefd[1], 1);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        const argv = [_:null]?[*:0]const u8{ "bsdtar", "-tf", ap.ptr, null };
        _ = c.execvp("bsdtar", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var line: [4096]u8 = undefined;
    var len: usize = 0;
    var matches: u64 = 0;
    var truncated = false;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(pipefd[0], &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |ch| {
            if (ch == '\n') {
                if (len > 0 and matches < MAX_MATCHES) {
                    const member = line[0..len];
                    const is_dir = member[member.len - 1] == '/';
                    job.emit(.{
                        .ev = "match",
                        .path = if (is_dir) member[0 .. member.len - 1] else member,
                        .kind = if (is_dir) "dir" else "file",
                        .size = @as(u64, 0),
                    });
                    matches += 1;
                } else if (len > 0) {
                    truncated = true;
                }
                len = 0;
            } else if (len < line.len) {
                line[len] = ch;
                len += 1;
            }
        }
    }
    _ = c.close(pipefd[0]);
    var wstatus: c_int = 0;
    _ = c.waitpid(pid, &wstatus, 0);
    if (matches == 0 and (wstatus != 0)) return job.emitError("cannot list archive (bsdtar required)");
    job.emit(.{ .ev = "done", .done = matches, .total = matches, .matches = matches, .truncated = truncated });
    return 0;
}

/// Extract ONE member host-side (into `dst`, or a fresh private tmp
/// dir) and report the extracted path in the done event.
pub fn runArchiveExtractMember(job: *const Job) u8 {
    const spec = job.spec;
    const member = spec.pattern;
    if (member.len == 0) return job.emitError("archive_extract needs a member");
    if (unsafeArchiveMember(member)) return job.emitError("unsafe archive member path");
    var dir_buf: [4096]u8 = undefined;
    var dir: []const u8 = undefined;
    if (spec.dst.len > 0) {
        dir = spec.dst;
        var dz: [4096]u8 = undefined;
        const dp = pathz.pathZ(&dz, dir) catch return job.emitError("destination too long");
        if (c.mkdir(dp, 0o755) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST)
            return job.emitErrno("mkdir destination");
    } else {
        const tmpl = "/tmp/sketerm-arx-XXXXXX";
        @memcpy(dir_buf[0..tmpl.len], tmpl);
        dir_buf[tmpl.len] = 0;
        const made = c.mkdtemp(@ptrCast(&dir_buf)) orelse return job.emitErrno("mkdtemp");
        dir = std.mem.span(@as([*:0]u8, @ptrCast(made)));
    }
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{spec.src}) catch return job.emitError("archive path too long");
    var dz2: [4096:0]u8 = undefined;
    const dp2 = std.fmt.bufPrintZ(&dz2, "{s}", .{dir}) catch return job.emitError("destination too long");
    var mz: [4096:0]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&mz, "{s}", .{member}) catch return job.emitError("member too long");
    const argv = [_:null]?[*:0]const u8{
        "bsdtar", "-xf", ap.ptr, "-C", dp2.ptr, "--no-same-owner", "--safe-writes", mp.ptr, null,
    };
    if (!runArgv(&argv)) return job.emitError("member extraction failed (bsdtar required)");
    var out_buf: [4096]u8 = undefined;
    const out = std.fmt.bufPrint(&out_buf, "{s}/{s}", .{ dir, member }) catch return job.emitError("path too long");
    var st: c.struct_stat = undefined;
    if (!statOf(out, &st, false)) return job.emitError("member not found after extraction");
    job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = out });
    return 0;
}

pub fn runArchiveCreate(job: *const Job) u8 {
    const spec = job.spec;
    if (spec.dst.len == 0) return job.emitError("archive_create needs destination archive");
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return job.emitErrno("stat source");
    const parent = std.fs.path.dirname(spec.src) orelse "/";
    const base = std.fs.path.basename(spec.src);
    var pz: [4096:0]u8 = undefined;
    var bz: [4096:0]u8 = undefined;
    var dz: [4096:0]u8 = undefined;
    const pp = std.fmt.bufPrintZ(&pz, "{s}", .{parent}) catch return job.emitError("source path too long");
    const bp = std.fmt.bufPrintZ(&bz, "{s}", .{base}) catch return job.emitError("source path too long");
    const dp = std.fmt.bufPrintZ(&dz, "{s}", .{spec.dst}) catch return job.emitError("archive path too long");
    job.emit(.{ .ev = "progress", .done = @as(u64, 0), .total = @as(u64, 0) });
    const argv = [_:null]?[*:0]const u8{ "bsdtar", "-caf", dp.ptr, "-C", pp.ptr, bp.ptr, null };
    if (!runArgv(&argv)) return job.emitError("archive creation failed (bsdtar required or format unsupported)");
    job.emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

test "archive member validation rejects traversal and absolute paths" {
    try std.testing.expect(!unsafeArchiveMember("dir/file.txt"));
    try std.testing.expect(!unsafeArchiveMember("./dir/file.txt"));
    try std.testing.expect(unsafeArchiveMember("../escape"));
    try std.testing.expect(unsafeArchiveMember("dir/../../escape"));
    try std.testing.expect(unsafeArchiveMember("/absolute"));
}

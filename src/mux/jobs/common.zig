//! Helpers more than one job family shares.

const std = @import("std");
const c = @import("../../c.zig").c;
const pathz = @import("../../util/pathz.zig");

/// Default match cap of a listing job (search, archive listing): a
/// runaway query costs a bounded stream, never a flooded daemon pipe.
pub const MAX_MATCHES: usize = 2000;

pub fn runArgv(argv: []const ?[*:0]const u8) bool {
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(argv.ptr)));
        c._exit(127);
    }
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    return c.WIFEXITED(st) and c.WEXITSTATUS(st) == 0;
}

pub fn extIs(path: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    return false;
}

fn captureArgv(argv: []const ?[*:0]const u8, out: []u8) usize {
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return 0;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        return 0;
    }
    if (pid == 0) {
        _ = c.dup2(pipefd[1], 1);
        _ = c.dup2(pipefd[1], 2);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(argv.ptr)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var used: usize = 0;
    while (used < out.len) {
        const n = c.read(pipefd[0], out[used..].ptr, out.len - used);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        used += @intCast(n);
    }
    _ = c.close(pipefd[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return if (c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0) used else 0;
}

// ── external probe fallbacks (ffprobe / pdfinfo) ─────────────────
//
// One path for both consumers: the preview job's media-info panel and
// the media_meta extractor's fallback for containers the pure-Zig
// parsers do not demux.

/// PATH lookup with an execute check. Both probes are optional on the
/// host, so a missing binary must degrade silently, never error.
pub const binaryExists = pathz.executableOnPath;

pub fn ffprobeEntries(source: [*:0]const u8, entries: [*:0]const u8, out: []u8) usize {
    if (!binaryExists("ffprobe")) return 0;
    const argv = [_:null]?[*:0]const u8{
        "ffprobe", "-v",                         "error", "-show_entries", entries,
        "-of",     "default=noprint_wrappers=1", source,  null,
    };
    return captureArgv(&argv, out);
}

pub fn pdfinfoText(source: [*:0]const u8, out: []u8) usize {
    if (!binaryExists("pdfinfo")) return 0;
    const argv = [_:null]?[*:0]const u8{ "pdfinfo", source, null };
    return captureArgv(&argv, out);
}

pub fn statOf(path: []const u8, st: *c.struct_stat, follow: bool) bool {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return false;
    return (if (follow) c.stat(p, st) else c.lstat(p, st)) == 0;
}

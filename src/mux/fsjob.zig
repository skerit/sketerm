//! Subprocess file-job runner (`sketerm-mux --job`).
//!
//! Heavy fs verbs (copy, delete_tree, hash) run here — one process
//! per OPERATION, spawned by the daemon (docs/filebrowser-roadmap.md
//! phase 2): kill = cancel, SIGSTOP/SIGCONT = pause/resume, a crash
//! costs one job and never a session. Spec arrives as one JSON line
//! on stdin; progress leaves as JSON lines on stdout; the exit code
//! is redundant with the final done/error line (the daemon trusts
//! the line, and maps a lineless death to "helper died").
//!
//! Resume needs no journal: the staged partial (`<dst>.skpart`) IS
//! the journal — resume hashes it against the same-length source
//! prefix and continues only on a match, else restarts. Content
//! verification, never size trust.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const fsserve = @import("fsserve.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const CHUNK: usize = 256 * 1024;
/// Emit a progress line at least every this many bytes.
const PROGRESS_BYTES: u64 = 4 << 20;

pub const Spec = struct {
    op: []const u8 = "",
    src: []const u8 = "",
    dst: []const u8 = "",
    pattern: []const u8 = "",
    @"resume": bool = false,
};

/// Search caps: a runaway query costs a bounded stream, never a
/// flooded daemon pipe.
const MAX_MATCHES: usize = 2000;
const MAX_MATCHES_PER_FILE: usize = 200;
const MAX_GREP_FILE: u64 = 8 << 20;
const MAX_MATCH_LINE: usize = 300;

// ── progress emission ───────────────────────────────────────────

fn emitRaw(line: []const u8) void {
    var off: usize = 0;
    while (off < line.len) {
        const n = c.write(1, line.ptr + off, line.len - off);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            // Daemon gone: the job has no one to report to. Keep
            // running (durability) — copies finish even reporterless.
            return;
        }
        off += @intCast(n);
    }
}

fn emit(value: anytype) void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    std.json.Stringify.value(value, .{}, &w) catch return;
    w.writeByte('\n') catch return;
    emitRaw(w.buffered());
}

fn emitError(msg: []const u8) u8 {
    emit(.{ .ev = "error", .message = msg });
    return 1;
}

fn emitErrno(what: []const u8) u8 {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{s}: {s}", .{ what, fsserve.errnoName(@as(c_int, -1)) }) catch return emitError(what);
    return emitError(w.buffered());
}

const Progress = struct {
    done: u64 = 0,
    total: u64 = 0,
    since_emit: u64 = 0,

    fn add(self: *Progress, n: u64) void {
        self.done += n;
        self.since_emit += n;
        if (self.since_emit >= PROGRESS_BYTES) {
            self.since_emit = 0;
            emit(.{ .ev = "progress", .done = self.done, .total = self.total });
        }
    }
};

// ── entry point (`--job`) ───────────────────────────────────────

/// Read the one-line JSON spec from stdin and run the job. The
/// process exists for exactly this operation.
pub fn serve(allocator: std.mem.Allocator) u8 {
    var spec_buf: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < spec_buf.len) {
        const n = c.read(0, spec_buf[len..].ptr, spec_buf.len - len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        len += @intCast(n);
        if (std.mem.indexOfScalar(u8, spec_buf[0..len], '\n') != null) break;
    }
    const line_end = std.mem.indexOfScalar(u8, spec_buf[0..len], '\n') orelse len;
    const parsed = std.json.parseFromSlice(Spec, allocator, spec_buf[0..line_end], .{
        .ignore_unknown_fields = true,
    }) catch return emitError("bad job spec");
    defer parsed.deinit();
    const spec = parsed.value;

    if (std.mem.eql(u8, spec.op, "copy")) return runCopy(allocator, spec);
    if (std.mem.eql(u8, spec.op, "delete_tree")) return runDeleteTree(spec);
    if (std.mem.eql(u8, spec.op, "hash")) return runHash(spec);
    if (std.mem.eql(u8, spec.op, "find")) return runSearch(allocator, spec, false);
    if (std.mem.eql(u8, spec.op, "grep")) return runSearch(allocator, spec, true);
    return emitError("unknown job op");
}

// ── find / grep ─────────────────────────────────────────────────

/// Case-insensitive glob: `*` and `?` wildcards; a pattern without
/// wildcards matches as a SUBSTRING (what a search box means).
pub fn nameMatches(pattern: []const u8, name: []const u8) bool {
    if (std.mem.indexOfAny(u8, pattern, "*?") == null)
        return std.ascii.indexOfIgnoreCase(name, pattern) != null;
    return globMatch(pattern, name);
}

fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Iterative *-backtracking matcher, ASCII case-folded.
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or
            std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n])))
        {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_n = n;
            p += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const SearchState = struct {
    matches: usize = 0,
    scanned: u64 = 0,
    truncated: bool = false,
    lower_pat: []u8,
};

fn runSearch(allocator: std.mem.Allocator, spec: Spec, content: bool) u8 {
    if (spec.pattern.len == 0) return emitError("empty pattern");
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, true)) return emitErrno("stat root");
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return emitError("search root is not a directory");
    const lower = allocator.dupe(u8, spec.pattern) catch return emitError("out of memory");
    defer allocator.free(lower);
    for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
    var state = SearchState{ .lower_pat = lower };
    searchDir(allocator, spec.src, spec.pattern, content, &state);
    emit(.{
        .ev = "done",
        .done = state.scanned,
        .total = state.scanned,
        .matches = state.matches,
        .truncated = state.truncated,
    });
    return 0;
}

fn searchDir(allocator: std.mem.Allocator, dir_path: []const u8, pattern: []const u8, content: bool, state: *SearchState) void {
    if (state.matches >= MAX_MATCHES) {
        state.truncated = true;
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES) catch return;
    for (l.entries) |e| {
        if (state.matches >= MAX_MATCHES) {
            state.truncated = true;
            return;
        }
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{s}/{s}", .{ if (dir_path.len == 1) "" else dir_path, e.name }) catch continue;
        const full = w.buffered();
        if (!content) {
            if (nameMatches(pattern, e.name)) {
                state.matches += 1;
                emit(.{ .ev = "match", .path = full, .kind = e.kind, .size = e.size });
            }
        } else if (std.mem.eql(u8, e.kind, "file") and e.size <= MAX_GREP_FILE) {
            grepFile(full, state);
        }
        state.scanned += 1;
        if (state.scanned % 512 == 0)
            emit(.{ .ev = "progress", .done = state.scanned, .total = @as(u64, 0) });
        if (std.mem.eql(u8, e.kind, "dir"))
            searchDir(allocator, full, pattern, content, state);
    }
}

/// Line-based case-insensitive content scan; binary files (NUL in
/// the first 4KB) are skipped.
fn grepFile(path: []const u8, state: *SearchState) void {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return;
    const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return;
    defer _ = c.close(fd);

    var buf: [64 * 1024]u8 = undefined;
    var carry: [MAX_MATCH_LINE]u8 = undefined;
    var carry_len: usize = 0;
    var line_no: u64 = 1;
    var file_matches: usize = 0;
    var first = true;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        const chunk = buf[0..@intCast(n)];
        if (first) {
            first = false;
            const probe = chunk[0..@min(chunk.len, 4096)];
            if (std.mem.indexOfScalar(u8, probe, 0) != null) return; // binary
        }
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, chunk, start, '\n')) |nl| {
            const tail = chunk[start..nl];
            if (matchLine(state, path, line_no, carry[0..carry_len], tail)) {
                file_matches += 1;
                if (file_matches >= MAX_MATCHES_PER_FILE or state.matches >= MAX_MATCHES) return;
            }
            carry_len = 0;
            line_no += 1;
            start = nl + 1;
        }
        const rest = chunk[start..];
        const room = carry.len - carry_len;
        const take = @min(rest.len, room);
        @memcpy(carry[carry_len .. carry_len + take], rest[0..take]);
        carry_len += take;
        // A line longer than the carry buffer: the head is enough for
        // matching/preview; the overflow is dropped by design.
    }
    if (carry_len > 0)
        _ = matchLine(state, path, line_no, carry[0..carry_len], "");
}

fn matchLine(state: *SearchState, path: []const u8, line_no: u64, head: []const u8, tail: []const u8) bool {
    var line_buf: [MAX_MATCH_LINE]u8 = undefined;
    const hn = @min(head.len, line_buf.len);
    @memcpy(line_buf[0..hn], head[0..hn]);
    const tn = @min(tail.len, line_buf.len - hn);
    @memcpy(line_buf[hn .. hn + tn], tail[0..tn]);
    const line = line_buf[0 .. hn + tn];
    for (line) |*ch| {
        if (ch.* == '\r' or ch.* == '\t') ch.* = ' ';
    }
    var lower_buf: [MAX_MATCH_LINE]u8 = undefined;
    for (line, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    if (std.mem.indexOf(u8, lower_buf[0..line.len], state.lower_pat) == null) return false;
    // Strip non-printable control bytes for the preview.
    for (line) |*ch| {
        if (ch.* < 0x20) ch.* = ' ';
    }
    state.matches += 1;
    emit(.{ .ev = "match", .path = path, .line = line_no, .text = line });
    return true;
}

// ── hash ────────────────────────────────────────────────────────

fn hashPrefix(path: []const u8, limit: u64, progress: ?*Progress) ?[Sha256.digest_length]u8 {
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
        if (progress) |pr| pr.add(@intCast(n));
    }
    if (left != 0) return null; // short file
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return out;
}

fn runHash(spec: Spec) u8 {
    var st: c.struct_stat = undefined;
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, spec.src) catch return emitError("path too long");
    if (c.stat(p, &st) != 0) return emitErrno("stat");
    const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;
    var progress = Progress{ .total = size };
    const digest = hashPrefix(spec.src, size, &progress) orelse return emitErrno("read");
    var hex: [Sha256.digest_length * 2]u8 = undefined;
    for (digest, 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    }
    emit(.{ .ev = "done", .done = size, .total = size, .hash = hex[0..] });
    return 0;
}

// ── copy ────────────────────────────────────────────────────────

fn statOf(path: []const u8, st: *c.struct_stat, follow: bool) bool {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return false;
    return (if (follow) c.stat(p, st) else c.lstat(p, st)) == 0;
}

fn runCopy(allocator: std.mem.Allocator, spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("copy needs dst");
    // dst inside src would recurse into its own output.
    if (spec.dst.len > spec.src.len and
        std.mem.startsWith(u8, spec.dst, spec.src) and spec.dst[spec.src.len] == '/')
        return emitError("dst is inside src");

    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return emitErrno("stat src");

    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) return runCopyTree(allocator, spec);

    var progress = Progress{ .total = if (st.st_size > 0) @intCast(st.st_size) else 0 };
    var resumed_from: u64 = 0;
    switch (copyOneFile(spec.src, spec.dst, st, spec.@"resume", &progress, &resumed_from)) {
        .ok => {},
        .err => |m| return emitError(m),
        .errno => |what| return emitErrno(what),
    }
    emit(.{ .ev = "done", .done = progress.done, .total = progress.total, .resumed_from = resumed_from });
    return 0;
}

const CopyResult = union(enum) { ok, err: []const u8, errno: []const u8 };

/// Single-file copy via a staged `.skpart` with hash-verified resume,
/// fsync, mode preservation, and atomic rename.
fn copyOneFile(src: []const u8, dst: []const u8, src_st: c.struct_stat, allow_resume: bool, progress: *Progress, resumed_from: *u64) CopyResult {
    var part_buf: [4096]u8 = undefined;
    var wpart = std.Io.Writer.fixed(&part_buf);
    wpart.print("{s}.skpart", .{dst}) catch return .{ .err = "path too long" };
    const part = wpart.buffered();

    const src_size: u64 = if (src_st.st_size > 0) @intCast(src_st.st_size) else 0;

    // Resume decision: an existing partial continues only when its
    // FULL content hashes equal to the same-length source prefix.
    var start: u64 = 0;
    if (allow_resume) {
        var pst: c.struct_stat = undefined;
        if (statOf(part, &pst, true) and pst.st_size > 0 and @as(u64, @intCast(pst.st_size)) <= src_size) {
            const plen: u64 = @intCast(pst.st_size);
            const part_h = hashPrefix(part, plen, null);
            const src_h = hashPrefix(src, plen, null);
            if (part_h != null and src_h != null and
                std.mem.eql(u8, &part_h.?, &src_h.?)) start = plen;
        }
    }
    resumed_from.* = start;
    progress.done = start;
    emit(.{ .ev = "progress", .done = start, .total = progress.total });

    var zs: [4096]u8 = undefined;
    const sp = pathz.pathZ(&zs, src) catch return .{ .err = "path too long" };
    const sfd = c.open(sp, c.O_RDONLY | c.O_CLOEXEC);
    if (sfd < 0) return .{ .errno = "open src" };
    defer _ = c.close(sfd);

    var zd: [4096]u8 = undefined;
    const pp = pathz.pathZ(&zd, part) catch return .{ .err = "path too long" };
    const dflags: c_int = if (start > 0) c.O_WRONLY | c.O_CLOEXEC else c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC;
    const dfd = c.open(pp, dflags, @as(c.mode_t, 0o600));
    if (dfd < 0) return .{ .errno = "open dst" };
    defer _ = c.close(dfd);
    if (start > 0) {
        if (c.lseek(dfd, @intCast(start), c.SEEK_SET) < 0) return .{ .errno = "seek dst" };
        if (c.lseek(sfd, @intCast(start), c.SEEK_SET) < 0) return .{ .errno = "seek src" };
    }

    var buf: [CHUNK]u8 = undefined;
    while (true) {
        const n = c.read(sfd, &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0) return .{ .errno = "read src" };
        if (n == 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const w = c.write(dfd, buf[off..].ptr, @as(usize, @intCast(n)) - off);
            if (w < 0 and std.posix.errno(w) == .INTR) continue;
            if (w <= 0) return .{ .errno = "write dst" };
            off += @intCast(w);
        }
        progress.add(@intCast(n));
    }

    if (c.fsync(dfd) != 0) return .{ .errno = "fsync" };
    _ = c.fchmod(dfd, src_st.st_mode & 0o7777);
    var zr: [4096]u8 = undefined;
    const dp = pathz.pathZ(&zr, dst) catch return .{ .err = "path too long" };
    if (c.rename(pp, dp) != 0) return .{ .errno = "rename" };
    return .ok;
}

/// Recursive tree copy. Pass 1 sizes the job (progress totals);
/// pass 2 copies: dirs mkdir'ed, symlinks recreated as symlinks,
/// regular files staged like the single-file path. On resume,
/// completed files (equal size at dst) are skipped WITHOUT hashing —
/// only the in-flight partial gets the hash check; a paranoid full
/// verify is what the hash verb is for.
fn runCopyTree(allocator: std.mem.Allocator, spec: Spec) u8 {
    var progress = Progress{};
    sizeTree(allocator, spec.src, &progress.total);

    var resumed_bytes: u64 = 0;
    switch (copyTreeDir(allocator, spec.src, spec.dst, spec.@"resume", &progress, &resumed_bytes)) {
        .ok => {},
        .err => |m| return emitError(m),
        .errno => |what| return emitErrno(what),
    }
    emit(.{ .ev = "done", .done = progress.done, .total = progress.total, .resumed_from = resumed_bytes });
    return 0;
}

fn sizeTree(allocator: std.mem.Allocator, dir_path: []const u8, total: *u64) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES) catch return;
    for (l.entries) |e| {
        if (std.mem.eql(u8, e.kind, "dir")) {
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("{s}/{s}", .{ dir_path, e.name }) catch continue;
            sizeTree(allocator, w.buffered(), total);
        } else if (std.mem.eql(u8, e.kind, "file")) {
            total.* += e.size;
        }
    }
}

fn copyTreeDir(allocator: std.mem.Allocator, src_dir: []const u8, dst_dir: []const u8, allow_resume: bool, progress: *Progress, resumed_bytes: *u64) CopyResult {
    var src_st: c.struct_stat = undefined;
    if (!statOf(src_dir, &src_st, true)) return .{ .errno = "stat dir" };
    {
        var z: [4096]u8 = undefined;
        const dp = pathz.pathZ(&z, dst_dir) catch return .{ .err = "path too long" };
        if (c.mkdir(dp, src_st.st_mode & 0o7777) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) {
            var st2: c.struct_stat = undefined;
            if (c.stat(dp, &st2) != 0) return .{ .errno = "mkdir" };
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), src_dir, fsserve.MAX_ENTRIES) catch
        return .{ .err = "cannot list source dir" };

    for (l.entries) |e| {
        var sbuf: [4096]u8 = undefined;
        var sw = std.Io.Writer.fixed(&sbuf);
        sw.print("{s}/{s}", .{ src_dir, e.name }) catch return .{ .err = "path too long" };
        const spath = sw.buffered();
        var dbuf: [4096]u8 = undefined;
        var dw = std.Io.Writer.fixed(&dbuf);
        dw.print("{s}/{s}", .{ dst_dir, e.name }) catch return .{ .err = "path too long" };
        const dpath = dw.buffered();

        if (std.mem.eql(u8, e.kind, "dir")) {
            switch (copyTreeDir(allocator, spath, dpath, allow_resume, progress, resumed_bytes)) {
                .ok => {},
                else => |r| return r,
            }
        } else if (std.mem.eql(u8, e.kind, "link")) {
            var zt: [4096]u8 = undefined;
            var zl: [4096]u8 = undefined;
            const tgt = pathz.pathZ(&zt, e.target orelse continue) catch continue;
            const lp = pathz.pathZ(&zl, dpath) catch continue;
            _ = c.unlink(lp);
            _ = c.symlink(tgt, lp);
        } else if (std.mem.eql(u8, e.kind, "file")) {
            if (allow_resume) {
                var dst_st: c.struct_stat = undefined;
                if (statOf(dpath, &dst_st, false) and (dst_st.st_mode & c.S_IFMT) == c.S_IFREG and
                    @as(u64, @intCast(dst_st.st_size)) == e.size)
                {
                    progress.add(e.size);
                    resumed_bytes.* += e.size;
                    continue;
                }
            }
            var fst: c.struct_stat = undefined;
            if (!statOf(spath, &fst, true)) continue; // vanished mid-copy
            var file_resumed: u64 = 0;
            switch (copyOneFile(spath, dpath, fst, allow_resume, progress, &file_resumed)) {
                .ok => resumed_bytes.* += file_resumed,
                else => |r| return r,
            }
        }
        // "other" (sockets, fifos): skipped by design.
    }
    return .ok;
}

// ── delete_tree ─────────────────────────────────────────────────

fn runDeleteTree(spec: Spec) u8 {
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return emitErrno("stat");
    var progress = Progress{};
    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
        if (!deleteTreeDir(spec.src, &progress)) return emitErrno("delete");
    } else {
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, spec.src) catch return emitError("path too long");
        if (c.unlink(p) != 0) return emitErrno("unlink");
        progress.done += 1;
    }
    emit(.{ .ev = "done", .done = progress.done, .total = progress.done, .resumed_from = @as(u64, 0) });
    return 0;
}

/// Post-order removal. Progress counts ENTRIES (files + dirs), since
/// byte totals mean nothing for deletion. Stack-recursive over path
/// depth (bounded by PATH_MAX/2 components).
fn deleteTreeDir(dir_path: []const u8, progress: *Progress) bool {
    var z: [4096]u8 = undefined;
    const dz = pathz.pathZ(&z, dir_path) catch return false;
    const dir = c.opendir(dz) orelse return false;
    // Collect names first: unlink-during-readdir is UB on some libcs.
    var names_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&names_buf);
    var names: std.ArrayList([]u8) = .empty;
    var overflow = false;
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const owned = fba.allocator().dupe(u8, name) catch {
            overflow = true;
            break;
        };
        names.append(fba.allocator(), owned) catch {
            overflow = true;
            break;
        };
    }
    _ = c.closedir(dir);

    for (names.items) |name| {
        var fbuf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&fbuf);
        w.print("{s}/{s}", .{ dir_path, name }) catch return false;
        const full = w.buffered();
        var zf: [4096]u8 = undefined;
        const fz = pathz.pathZ(&zf, full) catch return false;
        var st: c.struct_stat = undefined;
        if (c.lstat(fz, &st) != 0) continue;
        if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
            if (!deleteTreeDir(full, progress)) return false;
        } else {
            if (c.unlink(fz) != 0) return false;
            progress.done += 1;
        }
    }
    // A directory too wide for the name buffer: re-run this level
    // until it drains (batches of ~what fits).
    if (overflow) return deleteTreeDir(dir_path, progress);
    if (c.rmdir(dz) != 0) return false;
    progress.done += 1;
    return true;
}

// ── tests ───────────────────────────────────────────────────────

test "nameMatches: substring default, glob with wildcards, ci" {
    const t = std.testing;
    try t.expect(nameMatches("read", "README.md"));
    try t.expect(nameMatches("ME.md", "README.md"));
    try t.expect(!nameMatches("xyz", "README.md"));
    try t.expect(nameMatches("*.md", "README.md"));
    try t.expect(nameMatches("re*me.??", "README.md"));
    try t.expect(!nameMatches("*.txt", "README.md"));
    try t.expect(nameMatches("*", "anything"));
    try t.expect(nameMatches("a?c", "AbC"));
    try t.expect(!nameMatches("a?c", "abbc"));
    try t.expect(nameMatches("*b*b*", "abxbx"));
    try t.expect(!nameMatches("*b*b*", "abxx"));
}

test "copyOneFile resumes only on matching prefix hash" {
    const t = std.testing;
    var dbuf: [64]u8 = undefined;
    const tmpl = "/tmp/sketerm-fsjob-XXXXXX";
    @memcpy(dbuf[0..tmpl.len], tmpl);
    dbuf[tmpl.len] = 0;
    const dirp = c.mkdtemp(@ptrCast(&dbuf)) orelse return error.SkipZigTest;
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(dirp)));

    var src_buf: [4096]u8 = undefined;
    var sw = std.Io.Writer.fixed(&src_buf);
    try sw.print("{s}/src.bin", .{dir});
    const src = sw.buffered();
    var dst_buf: [4096]u8 = undefined;
    var dw2 = std.Io.Writer.fixed(&dst_buf);
    try dw2.print("{s}/dst.bin", .{dir});
    const dst = dw2.buffered();
    var part_buf: [4096]u8 = undefined;
    var pw = std.Io.Writer.fixed(&part_buf);
    try pw.print("{s}/dst.bin.skpart", .{dir});
    const part = pw.buffered();

    // 1MB deterministic source.
    const data = try t.allocator.alloc(u8, 1 << 20);
    defer t.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 13 +% 5);
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, src), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        try t.expect(c.fwrite(data.ptr, 1, data.len, f) == data.len);
    }
    // Seed a VALID partial: first 256KB.
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, part), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        try t.expect(c.fwrite(data.ptr, 1, 256 * 1024, f) == 256 * 1024);
    }
    var st: c.struct_stat = undefined;
    try t.expect(statOf(src, &st, true));
    var progress = Progress{ .total = data.len };
    var resumed: u64 = 0;
    switch (copyOneFile(src, dst, st, true, &progress, &resumed)) {
        .ok => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(u64, 256 * 1024), resumed);
    const out_h = hashPrefix(dst, data.len, null).?;
    var expect_h: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &expect_h, .{});
    try t.expectEqualSlices(u8, &expect_h, &out_h);

    // Seed a CORRUPT partial → restart from 0.
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, part), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        var junk: [1024]u8 = @splat(0xAA);
        try t.expect(c.fwrite(&junk, 1, junk.len, f) == junk.len);
    }
    var progress2 = Progress{ .total = data.len };
    var resumed2: u64 = 99;
    switch (copyOneFile(src, dst, st, true, &progress2, &resumed2)) {
        .ok => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(u64, 0), resumed2);
    const out_h2 = hashPrefix(dst, data.len, null).?;
    try t.expectEqualSlices(u8, &expect_h, &out_h2);
}

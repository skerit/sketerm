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
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const fsserve = @import("fsserve.zig");
const fsjournal = @import("fsjournal.zig");
const muxclient = @import("client.zig");
const fsdrive = @import("../ipc/fsdrive.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

fn sigNoop(_: c_int) callconv(.c) void {}

pub const CHUNK: usize = 256 * 1024;
/// Emit a progress line at least every this many bytes.
const PROGRESS_BYTES: u64 = 4 << 20;

pub const Spec = struct {
    op: []const u8 = "",
    src: []const u8 = "",
    dst: []const u8 = "",
    pattern: []const u8 = "",
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    @"resume": bool = false,
    job_id: u64 = 0,
    journal_dir: []const u8 = "",
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
    // A daemon restart closes the progress pipe. The operation must
    // continue rather than dying from SIGPIPE while reporting progress.
    _ = c.signal(c.SIGPIPE, &sigNoop);
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

    const rc: u8 = if (std.mem.eql(u8, spec.op, "copy"))
        runCopy(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "delete_tree"))
        runDeleteTree(spec)
    else if (std.mem.eql(u8, spec.op, "hash"))
        runHash(spec)
    else if (std.mem.eql(u8, spec.op, "find"))
        runSearch(allocator, spec, false)
    else if (std.mem.eql(u8, spec.op, "grep"))
        runSearch(allocator, spec, true)
    else if (std.mem.eql(u8, spec.op, "extract"))
        runExtract(spec)
    else if (std.mem.eql(u8, spec.op, "archive_create"))
        runArchiveCreate(spec)
    else if (std.mem.eql(u8, spec.op, "trash"))
        runTrash(spec)
    else if (std.mem.eql(u8, spec.op, "trash_restore"))
        runTrashRestore(spec)
    else if (std.mem.eql(u8, spec.op, "cross_copy"))
        runCrossCopy(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "panelize"))
        runPanelize(spec)
    else if (std.mem.eql(u8, spec.op, "live_find"))
        runLiveFind(allocator, spec)
    else
        emitError("unknown job op");
    if (spec.job_id != 0 and spec.journal_dir.len > 0) {
        fsjournal.save(spec.journal_dir, .{
            .id = spec.job_id,
            .op = spec.op,
            .state = if (rc == 0) "done" else "failed",
            .src = spec.src,
            .dst = spec.dst,
            .pattern = spec.pattern,
            .src_host = spec.src_host,
            .dst_host = spec.dst_host,
            .@"resume" = spec.@"resume",
            .pid = c.getpid(),
        }) catch {};
    }
    return rc;
}

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

fn runArgv(argv: []const ?[*:0]const u8) bool {
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

fn runExtract(spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("extract needs destination directory");
    if (!archiveMembersSafe(spec.src)) return emitError("archive is unreadable or contains unsafe paths");
    var dz: [4096]u8 = undefined;
    const dp = pathz.pathZ(&dz, spec.dst) catch return emitError("destination path too long");
    if (c.mkdir(dp, 0o755) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST)
        return emitErrno("mkdir destination");
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{spec.src}) catch return emitError("archive path too long");
    emit(.{ .ev = "progress", .done = @as(u64, 0), .total = @as(u64, 0) });
    const argv = [_:null]?[*:0]const u8{
        "bsdtar", "-xf", ap.ptr, "-C", dp, "--no-same-owner", "--safe-writes", null,
    };
    if (!runArgv(&argv)) return emitError("archive extraction failed (bsdtar required)");
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

fn runArchiveCreate(spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("archive_create needs destination archive");
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return emitErrno("stat source");
    const parent = std.fs.path.dirname(spec.src) orelse "/";
    const base = std.fs.path.basename(spec.src);
    var pz: [4096:0]u8 = undefined;
    var bz: [4096:0]u8 = undefined;
    var dz: [4096:0]u8 = undefined;
    const pp = std.fmt.bufPrintZ(&pz, "{s}", .{parent}) catch return emitError("source path too long");
    const bp = std.fmt.bufPrintZ(&bz, "{s}", .{base}) catch return emitError("source path too long");
    const dp = std.fmt.bufPrintZ(&dz, "{s}", .{spec.dst}) catch return emitError("archive path too long");
    emit(.{ .ev = "progress", .done = @as(u64, 0), .total = @as(u64, 0) });
    const argv = [_:null]?[*:0]const u8{ "bsdtar", "-caf", dp.ptr, "-C", pp.ptr, bp.ptr, null };
    if (!runArgv(&argv)) return emitError("archive creation failed (bsdtar required or format unsupported)");
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

// ── freedesktop trash ────────────────────────────────────────────

fn trashRoot(buf: []u8) ?[]const u8 {
    if (c.getenv("XDG_DATA_HOME")) |p| {
        const base = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        return std.fmt.bufPrint(buf, "{s}/Trash", .{base}) catch null;
    }
    const homep = c.getenv("HOME") orelse return null;
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(homep)));
    return std.fmt.bufPrint(buf, "{s}/.local/share/Trash", .{home}) catch null;
}

fn ensureTrashDirs(root: []const u8) bool {
    var files: [4096]u8 = undefined;
    var info: [4096]u8 = undefined;
    const fp = std.fmt.bufPrint(&files, "{s}/files", .{root}) catch return false;
    const ip = std.fmt.bufPrint(&info, "{s}/info", .{root}) catch return false;
    pathz.makeParentDirs(fp) catch return false;
    var z: [4096]u8 = undefined;
    const rz = pathz.pathZ(&z, root) catch return false;
    if (c.mkdir(rz, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return false;
    const fz = pathz.pathZ(&z, fp) catch return false;
    if (c.mkdir(fz, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return false;
    const iz = pathz.pathZ(&z, ip) catch return false;
    return c.mkdir(iz, 0o700) == 0 or std.posix.errno(@as(c_int, -1)) == .EXIST;
}

fn appendUrlEscaped(w: *std.Io.Writer, path: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else {
            try w.writeByte('%');
            try w.writeByte(hex[ch >> 4]);
            try w.writeByte(hex[ch & 15]);
        }
    }
}

fn deletionStamp(buf: *[32]u8) []const u8 {
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec,
    }) catch "1970-01-01T00:00:00";
}

fn runTrash(spec: Spec) u8 {
    if (spec.src.len <= 1) return emitError("refusing to trash root");
    var root_buf: [4096]u8 = undefined;
    const root = trashRoot(&root_buf) orelse return emitError("cannot locate trash directory");
    if (!ensureTrashDirs(root)) return emitErrno("create trash directory");
    const base = std.fs.path.basename(spec.src);
    var name_buf: [512]u8 = undefined;
    var files_buf: [4096]u8 = undefined;
    var info_buf: [4096]u8 = undefined;
    var attempt: u32 = 0;
    var trashed: []const u8 = undefined;
    var info_path: []const u8 = undefined;
    while (attempt < 10000) : (attempt += 1) {
        const name = if (attempt == 0)
            std.fmt.bufPrint(&name_buf, "{s}", .{base}) catch return emitError("name too long")
        else
            std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ base, attempt }) catch return emitError("name too long");
        trashed = std.fmt.bufPrint(&files_buf, "{s}/files/{s}", .{ root, name }) catch return emitError("path too long");
        info_path = std.fmt.bufPrint(&info_buf, "{s}/info/{s}.trashinfo", .{ root, name }) catch return emitError("path too long");
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.lstat(pathz.pathZ(&z, trashed) catch return emitError("path too long"), &st) != 0 and
            std.posix.errno(@as(c_int, -1)) == .NOENT) break;
    }
    if (attempt == 10000) return emitError("cannot allocate unique trash name");

    var text: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    w.writeAll("[Trash Info]\nPath=") catch return emitError("trash metadata too large");
    appendUrlEscaped(&w, spec.src) catch return emitError("trash metadata too large");
    var stamp_buf: [32]u8 = undefined;
    w.print("\nDeletionDate={s}\n", .{deletionStamp(&stamp_buf)}) catch return emitError("trash metadata too large");
    var iz: [4096]u8 = undefined;
    const ip = pathz.pathZ(&iz, info_path) catch return emitError("path too long");
    const info = c.fopen(ip, "wx") orelse return emitErrno("create trash metadata");
    if (c.fwrite(w.buffered().ptr, 1, w.buffered().len, info) != w.buffered().len or c.fclose(info) != 0) {
        _ = c.unlink(ip);
        return emitError("write trash metadata failed");
    }
    var sz: [4096]u8 = undefined;
    var tz: [4096]u8 = undefined;
    if (c.rename(pathz.pathZ(&sz, spec.src) catch return emitError("path too long"),
        pathz.pathZ(&tz, trashed) catch return emitError("path too long")) != 0)
    {
        _ = c.unlink(ip);
        return emitErrno("move to trash");
    }
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = trashed, .text = info_path });
    return 0;
}

fn runTrashRestore(spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("trash_restore needs original destination");
    pathz.makeParentDirs(spec.dst) catch return emitError("cannot create restore parent");
    var sz: [4096]u8 = undefined;
    var dz: [4096]u8 = undefined;
    if (c.rename(pathz.pathZ(&sz, spec.src) catch return emitError("path too long"),
        pathz.pathZ(&dz, spec.dst) catch return emitError("path too long")) != 0)
        return emitErrno("restore from trash");
    if (spec.pattern.len > 0) {
        var iz: [4096]u8 = undefined;
        _ = c.unlink(pathz.pathZ(&iz, spec.pattern) catch return emitError("trash info path too long"));
    }
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

// ── durable cross-host copy coordinator ──────────────────────────

fn connectHostFs(allocator: std.mem.Allocator, host: []const u8) !fsdrive.Fs {
    const conn = if (host.len == 0)
        try muxclient.Conn.connectLocalAutostart(allocator)
    else if (std.mem.startsWith(u8, host, "udp:"))
        try muxclient.Conn.connectUdp(allocator, host[4..], null)
    else
        try muxclient.Conn.connectSsh(allocator, host);
    return fsdrive.Fs.initConn(allocator, conn);
}

const CrossCopy = struct {
    allocator: std.mem.Allocator,
    src: *fsdrive.Fs,
    dst: *fsdrive.Fs,
    progress: Progress = .{},
    resumed: u64 = 0,

    fn hash(self: *CrossCopy, fs: *fsdrive.Fs, path: []const u8) ?[64]u8 {
        _ = self;
        const job = fs.startHash(path) catch return null;
        const end = fs.waitJobEnd(job, 120_000) catch return null;
        if (!end.ok or !end.has_hash) return null;
        return end.hash;
    }

    fn copyFile(self: *CrossCopy, src_path: []const u8, dst_path: []const u8, size: u64, allow_resume: bool) bool {
        if (allow_resume) {
            var arena_final = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_final.deinit();
            if (self.dst.statPath(arena_final.allocator(), dst_path)) |e| {
                if (std.mem.eql(u8, e.kind, "file") and e.size == size) {
                    const sh = self.hash(self.src, src_path);
                    const dh = self.hash(self.dst, dst_path);
                    if (sh != null and dh != null and std.mem.eql(u8, &sh.?, &dh.?)) {
                        self.progress.add(size);
                        self.resumed += size;
                        return true;
                    }
                }
            } else |_| {}
        }
        var part_buf: [4096]u8 = undefined;
        const part = std.fmt.bufPrint(&part_buf, "{s}.skpart", .{dst_path}) catch return false;
        var off: u64 = 0;
        if (allow_resume) {
            var arena_part = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_part.deinit();
            if (self.dst.statPath(arena_part.allocator(), part)) |e| {
                if (std.mem.eql(u8, e.kind, "file") and e.size <= size) off = e.size;
            } else |_| {}
        }
        const resumed_from = off;
        self.progress.done += off;
        self.resumed += off;
        emit(.{ .ev = "progress", .done = self.progress.done, .total = self.progress.total, .resumed_from = self.resumed });
        var chunk: std.ArrayList(u8) = .empty;
        defer chunk.deinit(self.allocator);
        while (off < size) {
            chunk.clearRetainingCapacity();
            const want: u32 = @intCast(@min(@as(u64, fsserve.MAX_READ), size - off));
            _ = self.src.read(src_path, off, want, &chunk) catch return false;
            if (chunk.items.len == 0) return false;
            const written = self.dst.write(part, off, chunk.items, .{
                .create = true,
                .truncate = off == 0 and resumed_from == 0,
            }) catch return false;
            if (written != chunk.items.len) return false;
            off += written;
            self.progress.add(written);
        }
        if (size == 0) {
            _ = self.dst.write(part, 0, &.{}, .{ .create = true, .truncate = true }) catch return false;
        }
        self.dst.fsync(part) catch return false;
        self.dst.rename(part, dst_path) catch return false;
        const sh = self.hash(self.src, src_path) orelse return false;
        const dh = self.hash(self.dst, dst_path) orelse return false;
        if (!std.mem.eql(u8, &sh, &dh)) {
            self.dst.deletePath(dst_path) catch {};
            if (resumed_from > 0) {
                self.progress.done -|= off;
                self.resumed -|= resumed_from;
                return self.copyFile(src_path, dst_path, size, false);
            }
            return false;
        }
        var arena_meta = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_meta.deinit();
        if (self.src.statPath(arena_meta.allocator(), src_path)) |e| {
            self.dst.chmod(dst_path, e.mode) catch {};
            self.dst.utimens(dst_path, e.atime_ms, e.mtime_ms) catch {};
        } else |_| {}
        return true;
    }

    fn copyTree(self: *CrossCopy, src_dir: []const u8, dst_dir: []const u8, allow_resume: bool) bool {
        self.dst.mkdir(dst_dir) catch |err| {
            if (err != fsdrive.Error.FsOpFailed or std.mem.indexOf(u8, self.dst.lastErr(), "EXIST") == null)
                return false;
        };
        var listing = self.src.list(src_dir) catch return false;
        defer listing.deinit();
        if (listing.truncated) return false;
        for (listing.entries) |e| {
            var sbuf: [4096]u8 = undefined;
            var dbuf: [4096]u8 = undefined;
            const sp = std.fmt.bufPrint(&sbuf, "{s}/{s}", .{ if (src_dir.len == 1) "" else src_dir, e.name }) catch return false;
            const dp = std.fmt.bufPrint(&dbuf, "{s}/{s}", .{ if (dst_dir.len == 1) "" else dst_dir, e.name }) catch return false;
            if (std.mem.eql(u8, e.kind, "dir")) {
                if (!self.copyTree(sp, dp, allow_resume)) return false;
            } else if (std.mem.eql(u8, e.kind, "file")) {
                self.progress.total += e.size;
                if (!self.copyFile(sp, dp, e.size, allow_resume)) return false;
            } else if (std.mem.eql(u8, e.kind, "link")) {
                self.dst.deletePath(dp) catch {};
                self.dst.symlink(e.target orelse return false, dp) catch return false;
            }
        }
        var arena_meta = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_meta.deinit();
        if (self.src.statPath(arena_meta.allocator(), src_dir)) |e| {
            self.dst.chmod(dst_dir, e.mode) catch {};
            self.dst.utimens(dst_dir, e.atime_ms, e.mtime_ms) catch {};
        } else |_| {}
        return true;
    }
};

fn runCrossCopy(allocator: std.mem.Allocator, spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("cross_copy needs destination");
    var src = connectHostFs(allocator, spec.src_host) catch return emitError("cannot connect source host");
    defer src.deinit();
    var dst = connectHostFs(allocator, spec.dst_host) catch return emitError("cannot connect destination host");
    defer dst.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const root = src.statPath(arena.allocator(), spec.src) catch return emitError("cannot stat source");
    var cc = CrossCopy{ .allocator = allocator, .src = &src, .dst = &dst };
    const ok = if (std.mem.eql(u8, root.kind, "file")) blk: {
        cc.progress.total = root.size;
        break :blk cc.copyFile(spec.src, spec.dst, root.size, spec.@"resume");
    } else if (root.tdir)
        cc.copyTree(spec.src, spec.dst, spec.@"resume")
    else
        false;
    if (!ok) return emitError("cross-host copy failed");
    emit(.{
        .ev = "done",
        .done = cc.progress.done,
        .total = cc.progress.total,
        .resumed_from = cc.resumed,
    });
    return 0;
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

/// Run an arbitrary host-side command and turn each LF- or NUL-delimited
/// output path into an operable result entry. Relative paths use `src` as cwd.
fn runPanelize(spec: Spec) u8 {
    if (spec.pattern.len == 0) return emitError("panelize needs command");
    var cwdz: [4096]u8 = undefined;
    const cwd = pathz.pathZ(&cwdz, spec.src) catch return emitError("cwd too long");
    var cmdz: [16 * 1024:0]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmdz, "{s}", .{spec.pattern}) catch return emitError("command too long");
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return emitErrno("pipe");
    const pid = c.fork();
    if (pid < 0) return emitErrno("fork");
    if (pid == 0) {
        _ = c.chdir(cwd);
        _ = c.dup2(pipefd[1], 1);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-lc", cmd.ptr, null };
        _ = c.execv("/bin/sh", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var item: [4096]u8 = undefined;
    var item_len: usize = 0;
    var matches: usize = 0;
    var truncated = false;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(pipefd[0], &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |ch| {
            if (ch == '\n' or ch == 0) {
                if (item_len > 0) {
                    if (matches >= MAX_MATCHES) {
                        truncated = true;
                    } else {
                        panelizeOne(spec.src, item[0..item_len]);
                        matches += 1;
                    }
                }
                item_len = 0;
            } else if (item_len < item.len) {
                item[item_len] = ch;
                item_len += 1;
            }
        }
    }
    if (item_len > 0 and matches < MAX_MATCHES) {
        panelizeOne(spec.src, item[0..item_len]);
        matches += 1;
    }
    _ = c.close(pipefd[0]);
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    if (!c.WIFEXITED(st) or c.WEXITSTATUS(st) != 0) return emitError("panel command failed");
    emit(.{ .ev = "done", .done = matches, .total = matches, .matches = matches, .truncated = truncated });
    return 0;
}

fn panelizeOne(root: []const u8, value_raw: []const u8) void {
    const value = std.mem.trim(u8, value_raw, " \t\r");
    if (value.len == 0) return;
    var full_buf: [4096]u8 = undefined;
    const full = if (value[0] == '/')
        value
    else
        std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (root.len == 1) "" else root, value }) catch return;
    var st: c.struct_stat = undefined;
    if (!statOf(full, &st, false)) return;
    emit(.{
        .ev = "match",
        .path = full,
        .kind = fsserve.kindOf(st.st_mode),
        .size = if (st.st_size > 0) @as(u64, @intCast(st.st_size)) else 0,
    });
}

const LiveWatch = struct { wd: c_int, path: []u8 };

fn addLiveDir(allocator: std.mem.Allocator, watcher: *fsserve.Watcher, watches: *std.ArrayList(LiveWatch), path: []const u8, pattern: []const u8, initial: bool) void {
    if (watches.items.len >= 8192) return;
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return;
    const wd = watcher.add(pz);
    if (wd < 0) return;
    for (watches.items) |w| if (w.wd == wd) return;
    const owned = allocator.dupe(u8, path) catch return;
    watches.append(allocator, .{ .wd = wd, .path = owned }) catch {
        allocator.free(owned);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const listing = fsserve.listDir(arena.allocator(), path, fsserve.MAX_ENTRIES) catch return;
    for (listing.entries) |e| {
        var full_buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (path.len == 1) "" else path, e.name }) catch continue;
        if (initial and nameMatches(pattern, e.name))
            emit(.{ .ev = "match", .path = full, .kind = e.kind, .size = e.size });
        if (std.mem.eql(u8, e.kind, "dir")) addLiveDir(allocator, watcher, watches, full, pattern, initial);
    }
}

/// Durable Haiku-style live filename query. Linux uses recursive inotify;
/// other hosts report the missing watcher honestly instead of polling.
fn runLiveFind(allocator: std.mem.Allocator, spec: Spec) u8 {
    if (spec.pattern.len == 0) return emitError("live_find needs pattern");
    if (comptime builtin.os.tag != .linux) return emitError("live queries need the platform watcher backend");
    var watcher: fsserve.Watcher = .{};
    defer watcher.deinit();
    if (!watcher.ensure()) return emitError("cannot create filesystem watcher");
    var watches: std.ArrayList(LiveWatch) = .empty;
    defer {
        for (watches.items) |w| allocator.free(w.path);
        watches.deinit(allocator);
    }
    addLiveDir(allocator, &watcher, &watches, spec.src, spec.pattern, true);
    emit(.{ .ev = "ready", .done = watches.items.len, .total = watches.items.len });
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        var pfd = c.struct_pollfd{ .fd = watcher.fd, .events = c.POLLIN, .revents = 0 };
        const pr = c.poll(&pfd, 1, -1);
        if (pr < 0 and std.posix.errno(pr) == .INTR) continue;
        if (pr <= 0) return emitError("watcher stopped");
        const n = c.read(watcher.fd, &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return emitError("watcher read failed");
        var it = fsserve.EventIter{ .buf = buf[0..@intCast(n)] };
        while (it.next()) |ev| {
            if (ev.isOverflow()) {
                emit(.{ .ev = "resync" });
                continue;
            }
            const parent = for (watches.items) |w| {
                if (w.wd == ev.wd) break w.path;
            } else continue;
            if (ev.name.len == 0) continue;
            var full_buf: [4096]u8 = undefined;
            const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (parent.len == 1) "" else parent, ev.name }) catch continue;
            var z: [4096]u8 = undefined;
            var st: c.struct_stat = undefined;
            if (c.lstat(pathz.pathZ(&z, full) catch continue, &st) != 0) {
                emit(.{ .ev = "unmatch", .path = full });
                continue;
            }
            const kind = fsserve.kindOf(st.st_mode);
            if (nameMatches(spec.pattern, ev.name)) {
                emit(.{ .ev = "match", .path = full, .kind = kind, .size = if (st.st_size > 0) @as(u64, @intCast(st.st_size)) else 0 });
            } else {
                emit(.{ .ev = "unmatch", .path = full });
            }
            if (std.mem.eql(u8, kind, "dir")) addLiveDir(allocator, &watcher, &watches, full, spec.pattern, true);
        }
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
    if (!sizeTree(allocator, spec.src, &progress.total))
        return emitError("cannot size source tree (listing failed or truncated)");

    var resumed_bytes: u64 = 0;
    switch (copyTreeDir(allocator, spec.src, spec.dst, spec.@"resume", &progress, &resumed_bytes)) {
        .ok => {},
        .err => |m| return emitError(m),
        .errno => |what| return emitErrno(what),
    }
    emit(.{ .ev = "done", .done = progress.done, .total = progress.total, .resumed_from = resumed_bytes });
    return 0;
}

fn sizeTree(allocator: std.mem.Allocator, dir_path: []const u8, total: *u64) bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES) catch return false;
    if (l.truncated) return false;
    for (l.entries) |e| {
        if (std.mem.eql(u8, e.kind, "dir")) {
            var buf: [4096]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("{s}/{s}", .{ dir_path, e.name }) catch return false;
            if (!sizeTree(allocator, w.buffered(), total)) return false;
        } else if (std.mem.eql(u8, e.kind, "file")) {
            total.* += e.size;
        }
    }
    return true;
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
    if (l.truncated) return .{ .err = "source directory listing truncated" };

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
            const tgt = pathz.pathZ(&zt, e.target orelse return .{ .err = "symlink target missing" }) catch
                return .{ .err = "path too long" };
            const lp = pathz.pathZ(&zl, dpath) catch return .{ .err = "path too long" };
            if (c.unlink(lp) != 0 and std.posix.errno(@as(c_int, -1)) != .NOENT)
                return .{ .errno = "unlink old symlink" };
            if (c.symlink(tgt, lp) != 0) return .{ .errno = "create symlink" };
        } else if (std.mem.eql(u8, e.kind, "file")) {
            if (allow_resume) {
                var dst_st: c.struct_stat = undefined;
                if (statOf(dpath, &dst_st, false) and (dst_st.st_mode & c.S_IFMT) == c.S_IFREG and
                    @as(u64, @intCast(dst_st.st_size)) == e.size)
                {
                    const src_h = hashPrefix(spath, e.size, null);
                    const dst_h = hashPrefix(dpath, e.size, null);
                    if (src_h != null and dst_h != null and std.mem.eql(u8, &src_h.?, &dst_h.?)) {
                        progress.add(e.size);
                        resumed_bytes.* += e.size;
                        continue;
                    }
                }
            }
            var fst: c.struct_stat = undefined;
            if (!statOf(spath, &fst, true)) return .{ .errno = "stat source file" };
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

test "archive member validation rejects traversal and absolute paths" {
    try std.testing.expect(!unsafeArchiveMember("dir/file.txt"));
    try std.testing.expect(!unsafeArchiveMember("./dir/file.txt"));
    try std.testing.expect(unsafeArchiveMember("../escape"));
    try std.testing.expect(unsafeArchiveMember("dir/../../escape"));
    try std.testing.expect(unsafeArchiveMember("/absolute"));
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

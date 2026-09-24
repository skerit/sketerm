//! MCP file tools (file_*): daemon-side file operations over fsdrive,
//! on the same daemon as the app tools.

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const fsdrive = @import("fsdrive.zig");
const muxclient = @import("../mux/client.zig");
const mcp_tools = @import("mcp_tools.zig");
const mcp = @import("mcp.zig");
const eql = std.mem.eql;
const mcp_term = @import("mcp_term.zig");
const mcp_app = @import("mcp_app.zig");
const ErrCode = mcp.ErrCode;
const Res = mcp.Res;
const Watchdog = mcp.Watchdog;
const argBool = mcp.argBool;
const argInt = mcp.argInt;
const argStr = mcp.argStr;
const errRes = mcp.errRes;
const run = mcp.run;

/// Lazy fsdrive connection for the file_* tools — same daemon as the
/// app tools (private in isolated mode, per-user with --shared). One
/// connection serves every call; a lost daemon drops it so the next
/// call reconnects.
const FsState = struct {
    allocator: std.mem.Allocator,
    fs: ?fsdrive.Fs = null,

    pub fn get(self: *FsState) ?*fsdrive.Fs {
        if (self.fs == null) {
            const conn = muxclient.Conn.connectLocalAutostartAt(self.allocator, mcp_app.app_state.mux_sock) catch return null;
            if (!self.adoptConn(conn)) return null;
        }
        return &self.fs.?;
    }

    pub fn adoptConn(self: *FsState, conn_in: muxclient.Conn) bool {
        var conn = conn_in;
        // The hello is already complete. Switch before any fs request or
        // potentially large fs_write so Conn's deadline polls can work.
        conn.setNonBlockingChecked() catch {
            conn.deinit();
            return false;
        };
        const armed = Watchdog.fs_fd.publish(conn.fd) catch false;
        if (!armed) {
            // Either the dup failed or the watchdog already fired: an
            // uncancellable connection must not become the live one.
            conn.deinit();
            return false;
        }
        self.fs = fsdrive.Fs.initConn(self.allocator, conn);
        return true;
    }

    pub fn drop(self: *FsState) void {
        Watchdog.fs_fd.release();
        if (self.fs) |*f| f.deinit();
        self.fs = null;
    }
};

pub var fs_state: FsState = .{ .allocator = undefined };

test "watchdog fs cancellation follows a replacement connection during one call" {
    const t = std.testing;
    Watchdog.fs_fd.release();
    Watchdog.fs_fd.arm();
    Watchdog.initLock();
    Watchdog.begin();
    defer Watchdog.end();

    var state = FsState{ .allocator = t.allocator };
    defer state.drop();
    var first: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &first));
    defer _ = c.close(first[1]);
    const first_fd = first[0];
    try t.expect(state.adoptConn(.{ .allocator = t.allocator, .fd = first[0] }));
    const flags = c.fcntl(state.fs.?.pollFd(), c.F_GETFL);
    try t.expect(flags >= 0 and flags & c.O_NONBLOCK != 0);
    try t.expect(Watchdog.fs_fd.fd.load(.acquire) >= 0);

    state.drop();
    try t.expectEqual(@as(c_int, -1), Watchdog.fs_fd.fd.load(.acquire));
    var replacement: [2]c_int = undefined;
    try t.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &replacement));
    defer _ = c.close(replacement[1]);
    try t.expectEqual(first_fd, replacement[0]);
    try t.expect(state.adoptConn(.{ .allocator = t.allocator, .fd = replacement[0] }));

    const Cancel = struct {
        fn run() void {
            _ = c.usleep(50_000);
            Watchdog.cancelDynamicFds();
        }
    };
    const canceler = try std.Thread.spawn(.{}, Cancel.run, .{});
    defer canceler.join();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const start = clock.nowMs();
    try t.expectError(
        fsdrive.Error.NotConnected,
        state.fs.?.statPath(arena_state.allocator(), "/tmp/watchdog-no-reply"),
    );
    try t.expect(clock.nowMs() - start < 500);
    try t.expectEqual(@as(c_int, -1), Watchdog.fs_fd.fd.load(.acquire));

    state.drop();
    try t.expect(!state.adoptConn(.{ .allocator = t.allocator, .fd = -1 }));
    try t.expectEqual(@as(c_int, -1), Watchdog.fs_fd.fd.load(.acquire));
}

/// An entry's mtime for a listing line: "?" when it has no local
/// representation, since a blank would misalign the columns.
fn fsFmtTime(buf: []u8, ms: i64) []const u8 {
    return clock.localStamp(buf, ms) orelse "?";
}

fn fsEntryLine(w: *std.Io.Writer, e: fsdrive.Entry) !void {
    var tb: [32]u8 = undefined;
    try w.print("{s: <5} {d: >12}  {s}  {o:0>4}  {s}", .{
        e.kind, e.size, fsFmtTime(&tb, e.mtime_ms), e.mode, e.name,
    });
    if (e.target) |t| try w.print(" -> {s}", .{t});
    try w.writeAll("\n");
}

/// An fsdrive error as one of the shared codes. The daemon's own
/// message is the only place a missing path is visible, so a refused
/// op is classified from it.
///
/// `NOENT` is the spelling that actually arrives: the daemon reports
/// failures as bare errno TAGS (`fsserve.errnoName` -> "NOENT",
/// "ACCES"), not as strerror prose. Matching only "ENOENT" therefore
/// typed every missing file as `io_failed`, which is RETRYABLE — so a
/// client retried a path that will never exist.
pub fn fsErrCode(err: fsdrive.Error, detail: []const u8) ErrCode {
    return switch (err) {
        fsdrive.Error.NotConnected => .unavailable,
        fsdrive.Error.Timeout => .timeout,
        fsdrive.Error.BadRequest => .invalid_args,
        fsdrive.Error.Conflict => .conflict,
        fsdrive.Error.OutOfMemory, fsdrive.Error.BadReply => .io_failed,
        // "NOENT" also matches the "ENOENT" spelling, which contains it.
        fsdrive.Error.FsOpFailed => if (std.mem.indexOf(u8, detail, "No such file") != null or
            std.mem.indexOf(u8, detail, "not found") != null or
            std.mem.indexOf(u8, detail, "NOENT") != null) .not_found else if (destinationExists(detail)) .conflict else .io_failed,
    };
}

/// The daemon's "the destination already exists": EEXIST, the no-clobber
/// rename's own EXIST, or a no-clobber copy job's "destination exists".
fn destinationExists(detail: []const u8) bool {
    return std.mem.indexOf(u8, detail, "EXIST") != null or
        std.mem.indexOf(u8, detail, "File exists") != null or
        std.mem.indexOf(u8, detail, "destination exists") != null;
}

/// Whether `path` exists, for a daemon too old to refuse a clobber
/// itself. Null when that cannot be told: the caller then refuses
/// rather than risk overwriting.
fn pathExists(fs: *fsdrive.Fs, path: []const u8) ?bool {
    var scratch = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch.deinit();
    _ = fs.statPath(scratch.allocator(), path) catch |err| {
        if (err == fsdrive.Error.FsOpFailed and fsErrCode(err, fs.lastErr()) == .not_found) return false;
        return null;
    };
    return true;
}

/// The refusal for a destination that exists while `overwrite` is off.
fn existsRes(arena: std.mem.Allocator, what: []const u8, path: []const u8) ![]const u8 {
    return errRes(arena, .conflict, try std.fmt.allocPrint(
        arena,
        "{s} refused: {s} already exists and overwrite is off (pass overwrite:true to replace it)",
        .{ what, path },
    ));
}

/// How a no-clobber operation is guarded: atomically by the daemon, or,
/// against a daemon too old for that, by a check made just before.
const Guard = enum { overwrite, atomic, checked };

/// Decide the guard for writing `dst`, refusing up front when a checked
/// destination already exists (or cannot be checked).
fn guardFor(fs: *fsdrive.Fs, args: std.json.Value, dst: []const u8) union(enum) { guard: Guard, exists, unknown } {
    if (argBool(args, "overwrite")) return .{ .guard = .overwrite };
    if (fs.conn.copy_no_replace) return .{ .guard = .atomic };
    return switch (pathExists(fs, dst) orelse return .unknown) {
        true => .exists,
        false => .{ .guard = .checked },
    };
}

fn guardNote(g: Guard) []const u8 {
    return switch (g) {
        .overwrite => "",
        .atomic => "",
        .checked => " (this daemon cannot refuse a clobber atomically; the destination was checked just before)",
    };
}

/// Describe an fsdrive failure. Captures the daemon's error string
/// BEFORE dropping a dead connection (the Fs would dangle after).
fn fsFail(arena: std.mem.Allocator, fs: *fsdrive.Fs, what: []const u8, err: fsdrive.Error) ![]const u8 {
    if (err == fsdrive.Error.NotConnected) {
        fs_state.drop();
        return errRes(arena, .unavailable, "daemon connection lost (reconnects on the next file_* call)");
    }
    const detail = fs.lastErr();
    const msg = std.fmt.allocPrint(arena, "{s} failed: {s} ({s})", .{
        what, detail, @errorName(err),
    }) catch return error.OutOfMemory;
    const code = fsErrCode(err, detail);
    // A send timeout may have left half a frame on the stream. Preserve the
    // timeout verdict, but retire that connection before the next request.
    if (!fs.usable()) fs_state.drop();
    return errRes(arena, code, msg);
}

/// Wait for a job's terminal event and render the outcome. A timeout
/// is HONEST: the job keeps running daemon-side, and that is a FACT
/// (`status: running`, `timed_out`), never a tool error.
fn fsAwaitJob(arena: std.mem.Allocator, fs: *fsdrive.Fs, job: u64, opname: []const u8, timeout_ms: i64) ![]const u8 {
    const end = fs.waitJobEnd(job, timeout_ms) catch |err| switch (err) {
        fsdrive.Error.Timeout => {
            var res = Res.init(arena);
            try res.fact("op", opname);
            try res.fact("job", job);
            try res.field("status", @as([]const u8, "running"));
            try res.fact("timed_out", true);
            try res.textf("{s} job {d} is still running after {d}ms — it continues in the background (file_jobs to check, file_job to cancel)", .{ opname, job, timeout_ms });
            return res.finish();
        },
        else => return fsFail(arena, fs, opname, err),
    };
    if (!end.ok) {
        const msg = std.fmt.allocPrint(arena, "{s} job {d} {s}: {s}", .{
            opname, job, if (end.canceled) "canceled" else "FAILED", end.messageText(),
        }) catch return error.OutOfMemory;
        const code: ErrCode = if (end.canceled or destinationExists(end.messageText())) .conflict else .io_failed;
        return errRes(arena, code, msg);
    }
    var res = Res.init(arena);
    try res.fact("op", opname);
    try res.fact("job", job);
    try res.field("status", @as([]const u8, "done"));
    try res.fact("timed_out", false);
    try res.fact("bytes", end.bytes_done);
    if (end.resumed_from > 0) try res.fact("resumed_from", end.resumed_from);
    if (end.has_hash) try res.fact("sha256", end.hash[0..]);
    try res.textf("{s} job {d} done: {d} bytes", .{ opname, job, end.bytes_done });
    if (end.resumed_from > 0) try res.textf("resumed from {d} (partial verified by hash)", .{end.resumed_from});
    if (end.has_hash) try res.textf("sha256 {s}", .{end.hash[0..]});
    return res.finish();
}

/// One directory entry as machine facts. Same vocabulary as the text
/// table `fsEntryLine` writes, so a listing cannot say two things.
fn fsEntryJson(w: *std.Io.Writer, e: fsdrive.Entry) !void {
    try w.writeAll("{\"name\":");
    try std.json.Stringify.value(e.name, .{}, w);
    try w.print(",\"kind\":\"{s}\",\"size\":{d},\"mode\":{d},\"mtime_ms\":{d},\"uid\":{d},\"gid\":{d}", .{
        e.kind, e.size, e.mode, e.mtime_ms, e.uid, e.gid,
    });
    if (e.target) |t| {
        try w.writeAll(",\"target\":");
        try std.json.Stringify.value(t, .{}, w);
        try w.print(",\"target_is_dir\":{}", .{e.tdir});
    }
    try w.writeAll("}");
}

pub const Tool = mcp_tools.GroupTool(.files);

pub fn filesTool(arena: std.mem.Allocator, tool: Tool, args: std.json.Value) ![]const u8 {
    return switch (tool) {
        .scp_put => mcp_term.scpTool(arena, true, args),
        .scp_get => mcp_term.scpTool(arena, false, args),

        .file_list => withFs(arena, args, fileList),
        .file_stat => withFs(arena, args, fileStat),
        .file_read => withFs(arena, args, fileRead),
        .file_write => withFs(arena, args, fileWrite),
        .file_mkdir => withFs(arena, args, fileMkdir),
        .file_rename => withFs(arena, args, fileRename),
        .file_delete => withFs(arena, args, fileDelete),
        .file_chmod => withFs(arena, args, fileChmod),
        .file_truncate => withFs(arena, args, fileTruncate),
        .file_media_info => withFs(arena, args, fileMediaInfo),
        .file_jobs => withFs(arena, args, fileJobs),
        .file_job => withFs(arena, args, fileJob),
        .file_copy => withFs(arena, args, jobTool("copy", startCopy)),
        .file_delete_tree => withFs(arena, args, jobTool("delete_tree", startDeleteTree)),
        .file_extract => withFs(arena, args, jobTool("extract", startExtract)),
        .file_archive_create => withFs(arena, args, jobTool("archive_create", startArchiveCreate)),
        .file_trash => withFs(arena, args, jobTool("trash", startTrash)),
        .file_hash => withFs(arena, args, jobTool("hash", startHash)),
    };
}

fn fileList(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
    var l = fs.list(path) catch |err| return fsFail(arena, fs, "list", err);
    defer l.deinit();
    var entries: std.Io.Writer.Allocating = .init(arena);
    var table: std.Io.Writer.Allocating = .init(arena);
    try entries.writer.writeAll("[");
    for (l.entries, 0..) |e, i| {
        if (i > 0) try entries.writer.writeAll(",");
        try fsEntryJson(&entries.writer, e);
        try fsEntryLine(&table.writer, e);
    }
    try entries.writer.writeAll("]");
    var res = Res.init(arena);
    try res.fact("path", l.path);
    try res.fact("count", l.entries.len);
    try res.fact("truncated", l.truncated);
    try res.raw("entries", entries.written());
    try res.textf("{s}: {d} entries{s}", .{
        l.path, l.entries.len, if (l.truncated) " (TRUNCATED at the listing cap)" else "",
    });
    if (l.entries.len > 0) try res.textf("--- entries ---\n{s}", .{table.written()});
    return res.finish();
}

fn fileStat(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
    const e = fs.statPath(arena, path) catch |err| return fsFail(arena, fs, "stat", err);
    var res = Res.init(arena);
    try res.fact("path", path);
    try res.fact("kind", e.kind);
    try res.fact("size", e.size);
    try res.fact("mode", e.mode);
    try res.fact("uid", e.uid);
    try res.fact("gid", e.gid);
    try res.fact("mtime_ms", e.mtime_ms);
    if (e.target) |t| {
        try res.fact("target", t);
        try res.fact("target_is_dir", e.tdir);
    }
    var tb: [32]u8 = undefined;
    try res.textf("{s}: {s}, {d} bytes, mode {o:0>4}, uid {d} gid {d}, mtime {s}", .{
        path, e.kind, e.size, e.mode, e.uid, e.gid, fsFmtTime(&tb, e.mtime_ms),
    });
    if (e.target) |t| try res.textf("-> {s}{s}", .{ t, if (e.tdir) " (dir)" else "" });
    return res.finish();
}

fn fileRead(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
    const off: u64 = @intCast(@max(0, argInt(args, "offset") orelse 0));
    const want: u32 = @intCast(std.math.clamp(argInt(args, "length") orelse 262_144, 1, 2_097_152));
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(arena);
    const info = fs.read(path, off, want, &data) catch |err| return fsFail(arena, fs, "read", err);
    const textual = std.unicode.utf8ValidateSlice(data.items) and
        std.mem.indexOfScalar(u8, data.items, 0) == null;
    var res = Res.init(arena);
    try res.fact("path", path);
    try res.fact("size", info.size);
    try res.fact("offset", off);
    try res.fact("bytes", data.items.len);
    try res.fact("eof", info.eof);
    try res.fact("more", !info.eof);
    try res.fact("binary", !textual);
    try res.textf("{s}: read {d} of {d} bytes at offset {d}, {s}", .{
        path, data.items.len, info.size, off, if (info.eof) "eof" else "MORE remains",
    });
    if (textual) {
        // Text content is the payload the text lane exists for;
        // duplicating it into structuredContent would double a
        // multi-megabyte read for no reader.
        try res.textf("--- content ---\n{s}", .{data.items});
    } else {
        // Bytes are machine data, not prose: the base64 belongs in
        // the structured lane, and the text lane just says so.
        const enc = std.base64.standard.Encoder;
        const b64 = arena.alloc(u8, enc.calcSize(data.items.len)) catch return error.OutOfMemory;
        try res.fact("base64", enc.encode(b64, data.items));
        try res.text("binary content: the bytes are base64 in structuredContent.base64");
    }
    return res.finish();
}

fn fileWrite(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
    const content = argStr(args, "content") orelse return errRes(arena, .invalid_args, "missing content");
    const append = argBool(args, "append");
    const n = fs.write(path, 0, content, .{
        .create = true,
        .truncate = !append,
        .append = append,
    }) catch |err| return fsFail(arena, fs, "write", err);
    var res = Res.init(arena);
    try res.fact("path", path);
    try res.fact("bytes", n);
    try res.fact("append", append);
    try res.textf("{s}: {d} bytes {s}", .{ path, n, if (append) "appended" else "written" });
    return res.finish();
}

fn fileMkdir(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
    fs.mkdir(path) catch |err| return fsFail(arena, fs, "mkdir", err);
    var res = Res.init(arena);
    try res.fact("path", path);
    try res.fact("created", true);
    try res.textf("{s}: created", .{path});
    return res.finish();
}

fn fileRename(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const from = argStr(args, "from") orelse return errRes(arena, .invalid_args, "missing from");
    const to = argStr(args, "to") orelse return errRes(arena, .invalid_args, "missing to");
    const guard = switch (guardFor(fs, args, to)) {
        .guard => |g| g,
        .exists => return existsRes(arena, "rename", to),
        .unknown => return fsFail(arena, fs, "rename (checking the destination)", fsdrive.Error.FsOpFailed),
    };
    const done = if (guard == .atomic) fs.renameNoReplace(from, to) else fs.rename(from, to);
    done catch |err| {
        if (guard != .overwrite and destinationExists(fs.lastErr())) return existsRes(arena, "rename", to);
        return fsFail(arena, fs, "rename", err);
    };
    var res = Res.init(arena);
    try res.fact("from", from);
    try res.fact("to", to);
    try res.fact("renamed", true);
    try res.fact("overwrite", guard == .overwrite);
    try res.textf("renamed {s} to {s}{s}", .{ from, to, guardNote(guard) });
    return res.finish();
}

fn fileDelete(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
    fs.deletePath(path) catch |err| return fsFail(arena, fs, "delete", err);
    var res = Res.init(arena);
    try res.fact("path", path);
    try res.fact("deleted", true);
    try res.textf("{s}: deleted", .{path});
    return res.finish();
}

fn fileChmod(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
    const mode: u32 = @intCast(std.math.clamp(argInt(args, "mode") orelse -1, 0, 0o7777));
    fs.chmod(path, mode) catch |err| return fsFail(arena, fs, "chmod", err);
    var res = Res.init(arena);
    try res.fact("path", path);
    try res.fact("mode", mode);
    try res.textf("{s}: mode {o:0>4}", .{ path, mode });
    return res.finish();
}

fn fileTruncate(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const path = argStr(args, "path") orelse return errRes(arena, .invalid_args, "missing path");
    const size: u64 = @intCast(@max(0, argInt(args, "size") orelse 0));
    fs.truncate(path, size) catch |err| return fsFail(arena, fs, "truncate", err);
    var res = Res.init(arena);
    try res.fact("path", path);
    try res.fact("size", size);
    try res.textf("{s}: size now {d}", .{ path, size });
    return res.finish();
}

fn fileMediaInfo(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const list_v = if (args == .object) args.object.get("paths") else null;
    if (list_v == null or list_v.? != .array) return errRes(arena, .invalid_args, "file_media_info needs a 'paths' array");
    const items = list_v.?.array.items;
    if (items.len == 0) return errRes(arena, .invalid_args, "file_media_info needs at least one path");
    if (items.len > fsdrive.MEDIA_BATCH_MAX) {
        const msg = std.fmt.allocPrint(arena, "file_media_info takes at most {d} paths per call", .{fsdrive.MEDIA_BATCH_MAX}) catch return error.OutOfMemory;
        return errRes(arena, .invalid_args, msg);
    }
    var paths: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        if (item != .string or item.string.len == 0 or item.string[0] != '/')
            return errRes(arena, .invalid_args, "every file_media_info path must be absolute");
        paths.append(arena, item.string) catch return error.OutOfMemory;
    }
    // "/" plus absolute names: the daemon resolves absolute entries
    // as-is, so one call can span directories.
    const rows = fs.mediaMeta(arena, "/", paths.items, 30_000) catch |err|
        return fsFail(arena, fs, "media_info", err);
    var files: std.Io.Writer.Allocating = .init(arena);
    var table: std.Io.Writer.Allocating = .init(arena);
    const jw = &files.writer;
    const tw = &table.writer;
    try jw.writeAll("[");
    for (rows, 0..) |r, i| {
        if (i > 0) try jw.writeAll(",");
        try jw.writeAll("{\"path\":");
        try std.json.Stringify.value(r.path, .{}, jw);
        try jw.print(",\"kind\":\"{s}\",\"cached\":{}", .{ r.kind, r.cached });
        if (r.note.len > 0) {
            try jw.writeAll(",\"note\":");
            try std.json.Stringify.value(r.note, .{}, jw);
        }
        try jw.writeAll(",\"fields\":{");
        for (r.fields, 0..) |f, fi| {
            if (fi > 0) try jw.writeAll(",");
            try std.json.Stringify.value(f.k, .{}, jw);
            try jw.writeAll(":");
            try std.json.Stringify.value(f.v, .{}, jw);
        }
        try jw.writeAll("}}");

        try tw.print("{s} [{s}]{s}\n", .{ r.path, r.kind, if (r.cached) " (cached)" else "" });
        if (r.note.len > 0) try tw.print("  skipped: {s}\n", .{r.note});
        for (r.fields) |f| try tw.print("  {s}={s}\n", .{ f.k, f.v });
    }
    try jw.writeAll("]");
    var res = Res.init(arena);
    try res.fact("count", rows.len);
    try res.raw("files", files.written());
    try res.textf("{d} file(s)", .{rows.len});
    if (rows.len > 0) try res.textf("--- media ---\n{s}", .{table.written()});
    return res.finish();
}

fn fileJobs(arena: std.mem.Allocator, fs: *fsdrive.Fs, _: std.json.Value) ![]const u8 {
    const rows = fs.jobList(arena) catch |err| return fsFail(arena, fs, "job_list", err);
    var jobs: std.Io.Writer.Allocating = .init(arena);
    var table: std.Io.Writer.Allocating = .init(arena);
    const jw = &jobs.writer;
    const tw = &table.writer;
    try jw.writeAll("[");
    for (rows, 0..) |row, i| {
        if (i > 0) try jw.writeAll(",");
        try jw.print("{{\"job\":{d},\"op\":", .{row.job});
        try std.json.Stringify.value(row.op, .{}, jw);
        try jw.writeAll(",\"state\":");
        try std.json.Stringify.value(row.state, .{}, jw);
        try jw.print(",\"done\":{d},\"total\":{d},\"src\":", .{ row.done, row.total });
        try std.json.Stringify.value(row.src, .{}, jw);
        try jw.writeAll(",\"dst\":");
        try std.json.Stringify.value(row.dst, .{}, jw);
        try jw.writeAll(",\"message\":");
        try std.json.Stringify.value(row.message, .{}, jw);
        try jw.writeAll("}");
        if (i > 0) try tw.writeAll("\n");
        try tw.print("job {d}: {s} {s} {d}/{d} bytes", .{ row.job, row.op, row.state, row.done, row.total });
    }
    try jw.writeAll("]");
    var res = Res.init(arena);
    try res.fact("count", rows.len);
    try res.raw("jobs", jobs.written());
    if (rows.len == 0)
        try res.text("no file jobs")
    else
        try res.textf("{d} file job(s)\n--- jobs ---\n{s}", .{ rows.len, table.written() });
    return res.finish();
}

fn fileJob(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) ![]const u8 {
    const job: u64 = @intCast(@max(0, argInt(args, "job") orelse 0));
    const action = argStr(args, "action") orelse return errRes(arena, .invalid_args, "missing action");
    if (eql(u8, action, "cancel")) {
        fs.jobCancel(job) catch |err| return fsFail(arena, fs, "job_cancel", err);
    } else if (eql(u8, action, "pause")) {
        fs.jobPause(job) catch |err| return fsFail(arena, fs, "job_pause", err);
    } else if (eql(u8, action, "resume")) {
        fs.jobResume(job) catch |err| return fsFail(arena, fs, "job_resume", err);
    } else return errRes(arena, .invalid_args, "action must be cancel|pause|resume");
    var res = Res.init(arena);
    try res.fact("job", job);
    try res.fact("action", action);
    try res.fact("sent", true);
    try res.textf("job {d}: {s} sent", .{ job, action });
    return res.finish();
}

/// How starting one file job went: a job id, a missing required argument,
/// or the daemon's refusal.
const JobStart = union(enum) {
    job: u64,
    missing: []const u8,
    failed: fsdrive.Error,
    /// The destination exists and the call did not ask to overwrite it.
    exists: []const u8,

    fn of(r: fsdrive.Error!u64) JobStart {
        return if (r) |job| .{ .job = job } else |err| .{ .failed = err };
    }
};

/// One file tool body: runs with the daemon connection already reached.
const FsBody = fn (std.mem.Allocator, *fsdrive.Fs, std.json.Value) anyerror![]const u8;

/// Reach the daemon's file service, then run one file tool on it.
fn withFs(arena: std.mem.Allocator, args: std.json.Value, comptime body: FsBody) ![]const u8 {
    const fs = fs_state.get() orelse
        return errRes(arena, .unavailable, "cannot reach the mux daemon for file tools");
    return body(arena, fs, args);
}

/// A long file operation's tool body: started daemon-side as a job, then
/// awaited (bounded) unless `wait:false`.
fn jobTool(comptime opname: []const u8, comptime start: fn (*fsdrive.Fs, std.json.Value) JobStart) FsBody {
    return struct {
        fn run(arena: std.mem.Allocator, fs: *fsdrive.Fs, args: std.json.Value) anyerror![]const u8 {
            const timeout: i64 = std.math.clamp(argInt(args, "timeout_ms") orelse 60_000, 1_000, 120_000);
            const job = switch (start(fs, args)) {
                .job => |id| id,
                .missing => |what| return errRes(arena, .invalid_args, try std.fmt.allocPrint(arena, "missing {s}", .{what})),
                .failed => |err| return fsFail(arena, fs, opname, err),
                .exists => |path| return existsRes(arena, opname, path),
            };
            const wait = if (args == .object and args.object.get("wait") != null) argBool(args, "wait") else true;
            if (!wait) {
                var res = Res.init(arena);
                try res.fact("op", opname);
                try res.field("job", job);
                try res.field("status", @as([]const u8, "started"));
                try res.textf("{s} job {d} started (file_jobs to check)", .{ opname, job });
                return res.finish();
            }
            return fsAwaitJob(arena, fs, job, opname, timeout);
        }
    }.run;
}

fn startCopy(fs: *fsdrive.Fs, args: std.json.Value) JobStart {
    const src = argStr(args, "src") orelse return .{ .missing = "src" };
    const dst = argStr(args, "dst") orelse return .{ .missing = "dst" };
    const resumable = argBool(args, "resume");
    // The daemon's no-clobber copy never resumes a partial, so a resumed
    // copy is guarded by the check instead: its destination does not
    // exist yet (only the staged partial does).
    const guard: Guard = if (resumable and !argBool(args, "overwrite")) switch (pathExists(fs, dst) orelse
        return .{ .failed = fsdrive.Error.FsOpFailed }) {
        true => return .{ .exists = dst },
        false => .checked,
    } else switch (guardFor(fs, args, dst)) {
        .guard => |g| g,
        .exists => return .{ .exists = dst },
        .unknown => return .{ .failed = fsdrive.Error.FsOpFailed },
    };
    if (guard == .atomic) return .of(fs.startCopyMode(src, dst, .{ .no_replace = true }));
    return .of(fs.startCopy(src, dst, resumable));
}

fn startDeleteTree(fs: *fsdrive.Fs, args: std.json.Value) JobStart {
    const path = argStr(args, "path") orelse return .{ .missing = "path" };
    return .of(fs.startDeleteTree(path));
}

fn startExtract(fs: *fsdrive.Fs, args: std.json.Value) JobStart {
    const archive = argStr(args, "archive") orelse return .{ .missing = "archive" };
    const destination = argStr(args, "destination") orelse return .{ .missing = "destination" };
    return .of(fs.startExtract(archive, destination));
}

fn startArchiveCreate(fs: *fsdrive.Fs, args: std.json.Value) JobStart {
    const source = argStr(args, "source") orelse return .{ .missing = "source" };
    const archive = argStr(args, "archive") orelse return .{ .missing = "archive" };
    return .of(fs.startArchiveCreate(source, archive));
}

fn startTrash(fs: *fsdrive.Fs, args: std.json.Value) JobStart {
    const path = argStr(args, "path") orelse return .{ .missing = "path" };
    return .of(fs.startTrash(path));
}

fn startHash(fs: *fsdrive.Fs, args: std.json.Value) JobStart {
    const path = argStr(args, "path") orelse return .{ .missing = "path" };
    return .of(fs.startHash(path));
}

test "an existing destination is a conflict in every spelling the daemon uses" {
    const t = std.testing;
    try t.expectEqual(ErrCode.conflict, fsErrCode(fsdrive.Error.FsOpFailed, "EXIST"));
    try t.expectEqual(ErrCode.conflict, fsErrCode(fsdrive.Error.FsOpFailed, "EEXIST"));
    try t.expect(destinationExists("copy job 3 FAILED: destination exists"));
    try t.expect(!destinationExists("does not exist"));
}

test "fs failures carry the code their cause deserves" {
    const t = std.testing;
    try t.expectEqual(ErrCode.unavailable, fsErrCode(fsdrive.Error.NotConnected, ""));
    try t.expectEqual(ErrCode.timeout, fsErrCode(fsdrive.Error.Timeout, ""));
    try t.expectEqual(ErrCode.invalid_args, fsErrCode(fsdrive.Error.BadRequest, ""));
    try t.expectEqual(ErrCode.conflict, fsErrCode(fsdrive.Error.Conflict, ""));
    // Only the daemon's own message distinguishes a missing path from
    // any other refusal.
    try t.expectEqual(ErrCode.not_found, fsErrCode(fsdrive.Error.FsOpFailed, "open: No such file or directory"));
    // The spelling the daemon actually sends: a bare errno tag.
    try t.expectEqual(ErrCode.not_found, fsErrCode(fsdrive.Error.FsOpFailed, "NOENT"));
    try t.expectEqual(ErrCode.not_found, fsErrCode(fsdrive.Error.FsOpFailed, "ENOENT"));
    try t.expectEqual(ErrCode.io_failed, fsErrCode(fsdrive.Error.FsOpFailed, "ACCES"));
    try t.expectEqual(ErrCode.io_failed, fsErrCode(fsdrive.Error.FsOpFailed, "permission denied"));
    try t.expect(!ErrCode.not_found.retryable());
    try t.expect(ErrCode.timeout.retryable());
}

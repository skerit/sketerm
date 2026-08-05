//! File-service end-to-end smoke (headless): daemon thread + fsdrive
//! client over a temp socket. Exercises rich listings (incl. chunk
//! runs), live directory views (inotify deltas for external create /
//! write / rename / delete), the mutation verbs, ranged read/write,
//! stat, view teardown (close, dir-gone, client death), error paths,
//! and a broker-mode pass (fs frames are served by the process owning
//! the client connection — the broker-handoff lesson says: never
//! trust a monolith-only green). `zig build smoke-fs`.

const std = @import("std");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const fsdrive = @import("ipc/fsdrive.zig");
const fstransfer = @import("ipc/fstransfer.zig");
const fsserve = @import("mux/fsserve.zig");
const fsjob = @import("mux/fsjob.zig");
const fsjournal = @import("mux/fsjournal.zig");
const imagecodec = @import("util/imagecodec.zig");
const pathz = @import("util/pathz.zig");
const reload = @import("editor/reload.zig");
const thumbs_mod = @import("filebrowser/thumbs.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Modification time of a stat buffer. glibc/musl spell the field
/// `st_mtim`, Darwin `st_mtimespec` — the whole difference, in one
/// place rather than at every comparison below.
fn mtime(st: c.struct_stat) c.struct_timespec {
    return if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
}

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-fs: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

fn failErr(comptime msg: []const u8, e: []const u8) noreturn {
    std.debug.print("smoke-fs: FAIL: " ++ msg ++ " ({s})\n", .{e});
    std.process.exit(1);
}

fn daemonMain(d: *daemon_mod.Daemon) void {
    d.run() catch |err| {
        std.debug.print("smoke-fs: daemon error: {s}\n", .{@errorName(err)});
    };
}

fn mkTmpDir(buf: *[64]u8, comptime tag: []const u8) []const u8 {
    const tmpl = "/tmp/sketerm-smoke-fs-" ++ tag ++ "-XXXXXX";
    @memcpy(buf[0..tmpl.len], tmpl);
    buf[tmpl.len] = 0;
    const p = c.mkdtemp(@ptrCast(buf)) orelse fail("mkdtemp");
    // Canonicalise. On macOS /tmp is a SYMLINK to /private/tmp, and the
    // daemon answers with resolved paths — so every "the listing echoed
    // back the path I asked for" assertion below would compare
    // /tmp/... against /private/tmp/... and fail. Harmless on Linux,
    // where realpath returns the same string.
    var real: [4096]u8 = undefined;
    const rp = c.realpath(@ptrCast(p), &real) orelse fail("tmp dir realpath");
    const span = std.mem.span(@as([*:0]u8, @ptrCast(rp)));
    if (span.len >= buf.len) fail("tmp dir path too long once canonical");
    @memcpy(buf[0..span.len], span);
    buf[span.len] = 0;
    return buf[0..span.len];
}

fn touch(dir: []const u8, name: []const u8, content: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = fsserve.joinZ(&z, dir, name) catch fail("touch path");
    const f = c.fopen(p, "wb") orelse fail("touch open");
    defer _ = c.fclose(f);
    if (content.len > 0 and c.fwrite(content.ptr, 1, content.len, f) != content.len)
        fail("touch write");
}

fn findEntry(l: *const fsdrive.Listing, name: []const u8) ?fsdrive.Entry {
    for (l.entries) |e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// Everything the client has learned from fs_delta pushes. One frame
/// can carry several changes (a rename = del + upsert in ONE delta),
/// so matching must journal every change it drains, never discard the
/// remainder of a matched frame.
const DeltaLog = struct {
    const Rec = struct {
        view: u32,
        gone: bool = false,
        resync: bool = false,
        op: []u8 = &.{},
        name: []u8 = &.{},
        size: u64 = 0,
        tdir: bool = false,
        children: i64 = -1,
    };

    allocator: std.mem.Allocator,
    recs: std.ArrayList(Rec) = .empty,

    fn deinit(self: *DeltaLog) void {
        for (self.recs.items) |r| {
            self.allocator.free(r.op);
            self.allocator.free(r.name);
        }
        self.recs.deinit(self.allocator);
    }

    fn pump(self: *DeltaLog, fs: *fsdrive.Fs) void {
        while (fs.takeDelta()) |d0| {
            var d = d0;
            defer d.deinit();
            if (d.gone or d.resync) {
                self.recs.append(self.allocator, .{
                    .view = d.view,
                    .gone = d.gone,
                    .resync = d.resync,
                }) catch fail("log oom");
                continue;
            }
            for (d.changes) |ch| {
                self.recs.append(self.allocator, .{
                    .view = d.view,
                    .op = self.allocator.dupe(u8, ch.op) catch fail("log oom"),
                    .name = self.allocator.dupe(u8, ch.name) catch fail("log oom"),
                    .size = if (ch.entry) |e| e.size else 0,
                    .tdir = if (ch.entry) |e| e.tdir else false,
                    .children = if (ch.entry) |e| e.children else -1,
                }) catch fail("log oom");
            }
        }
    }

    fn find(self: *DeltaLog, view: u32, op: []const u8, name: []const u8) ?Rec {
        for (self.recs.items) |r| {
            if (r.view == view and std.mem.eql(u8, r.op, op) and std.mem.eql(u8, r.name, name))
                return r;
        }
        return null;
    }

    /// Bounded await: pump + scan until the change shows up.
    fn expect(self: *DeltaLog, fs: *fsdrive.Fs, view: u32, op: []const u8, name: []const u8) ?Rec {
        var rounds: usize = 0;
        while (rounds < 100) : (rounds += 1) {
            self.pump(fs);
            if (self.find(view, op, name)) |r| return r;
            _ = fs.waitDelta(100);
        }
        return null;
    }

    /// Await an upsert that has reached `size`. A create is TWO
    /// deltas by design (IN_CREATE at open time — size 0 — then
    /// IN_CLOSE_WRITE with content); the final state is what counts.
    fn expectSized(self: *DeltaLog, fs: *fsdrive.Fs, view: u32, name: []const u8, size: u64) bool {
        var rounds: usize = 0;
        while (rounds < 100) : (rounds += 1) {
            self.pump(fs);
            for (self.recs.items) |r| {
                if (r.view == view and std.mem.eql(u8, r.op, "upsert") and
                    std.mem.eql(u8, r.name, name) and r.size == size) return true;
            }
            _ = fs.waitDelta(100);
        }
        return false;
    }

    /// Await the async child-count upsert for a directory entry.
    fn expectChildren(self: *DeltaLog, fs: *fsdrive.Fs, view: u32, name: []const u8, children: i64) bool {
        var rounds: usize = 0;
        while (rounds < 100) : (rounds += 1) {
            self.pump(fs);
            for (self.recs.items) |r| {
                if (r.view == view and std.mem.eql(u8, r.op, "upsert") and
                    std.mem.eql(u8, r.name, name) and r.children == children) return true;
            }
            _ = fs.waitDelta(100);
        }
        return false;
    }

    fn expectGone(self: *DeltaLog, fs: *fsdrive.Fs, view: u32) bool {
        var rounds: usize = 0;
        while (rounds < 100) : (rounds += 1) {
            self.pump(fs);
            for (self.recs.items) |r| {
                if (r.view == view and r.gone) return true;
            }
            _ = fs.waitDelta(100);
        }
        return false;
    }
};

fn fsStage(allocator: std.mem.Allocator, sock_path: []const u8, comptime tag: []const u8) void {
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf, tag);
    touch(dir, "a.txt", "hello fs");
    var z: [4096]u8 = undefined;
    _ = c.mkdir(fsserve.joinZ(&z, dir, "sub") catch fail("mk sub"), 0o755);
    touch(dir, "sub/inner.txt", "y");

    var fs = fsdrive.Fs.connect(allocator, sock_path) catch fail("fs connect");
    defer fs.deinit();
    var dlog = DeltaLog{ .allocator = allocator };
    defer dlog.deinit();

    // ── open_view: rich one-round-trip listing ─────────────────
    var l = fs.openView(1, dir) catch fail("open_view");
    if (l.entries.len != 2) fail("initial listing entry count");
    if (!std.mem.eql(u8, l.path, dir)) fail("listing path not canonical");
    const sub = findEntry(&l, "sub") orelse fail("sub missing");
    if (!std.mem.eql(u8, sub.kind, "dir") or !sub.tdir) fail("sub not a dir");
    const atxt = findEntry(&l, "a.txt") orelse fail("a.txt missing");
    if (!std.mem.eql(u8, atxt.kind, "file")) fail("a.txt kind");
    if (atxt.size != 8) fail("a.txt size");
    if (atxt.mtime_ms <= 0) fail("a.txt mtime");
    // Child counts never ride the listing (they cost a readdir per
    // subdirectory); they follow asynchronously as an upsert delta
    // on the view, with the count filled in.
    if (sub.children != -1) fail("listing carried a child count");
    l.deinit();
    if (!dlog.expectChildren(&fs, 1, "sub", 1)) fail("async child-count delta never arrived");

    // ── live deltas: external create / write / delete ──────────
    touch(dir, "c.txt", "x");
    if (!dlog.expectSized(&fs, 1, "c.txt", 1)) fail("create delta never reached final size");

    {
        var z2: [4096]u8 = undefined;
        const p = fsserve.joinZ(&z2, dir, "a.txt") catch fail("append path");
        const f = c.fopen(p, "ab") orelse fail("append open");
        _ = c.fwrite("more!", 1, 5, f);
        _ = c.fclose(f);
    }
    // Appending to an EXISTING file is the one event a kqueue directory
    // watch cannot see (fsserve.watch_sees_child_writes) — the write
    // never touches the directory. Everything else in this stage is
    // exact on both backends.
    if (fsserve.watch_sees_child_writes and !dlog.expectSized(&fs, 1, "a.txt", 13))
        fail("write delta never reached final size");

    {
        var z2: [4096]u8 = undefined;
        _ = c.unlink(fsserve.joinZ(&z2, dir, "c.txt") catch fail("del path"));
    }
    _ = dlog.expect(&fs, 1, "del", "c.txt") orelse fail("delete delta never arrived");

    // ── mutation verbs, observed through the same view ─────────
    var pbuf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&pbuf);
    w.print("{s}/made", .{dir}) catch fail("fmt");
    const made_path = w.buffered();
    fs.mkdir(made_path) catch failErr("mkdir", fs.lastErr());
    const made = dlog.expect(&fs, 1, "upsert", "made") orelse fail("mkdir delta");
    if (!made.tdir) fail("mkdir delta not dir");

    var p2buf: [4096]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&p2buf);
    w2.print("{s}/renamed.txt", .{dir}) catch fail("fmt2");
    const renamed_path = w2.buffered();
    var p3buf: [4096]u8 = undefined;
    var w3 = std.Io.Writer.fixed(&p3buf);
    w3.print("{s}/a.txt", .{dir}) catch fail("fmt3");
    fs.rename(w3.buffered(), renamed_path) catch failErr("rename", fs.lastErr());
    _ = dlog.expect(&fs, 1, "del", "a.txt") orelse fail("rename del delta");
    if (!dlog.expectSized(&fs, 1, "renamed.txt", 13)) fail("rename upsert delta");

    fs.deletePath(renamed_path) catch failErr("delete", fs.lastErr());
    _ = dlog.expect(&fs, 1, "del", "renamed.txt") orelse fail("verb delete delta");

    // ── ranged write + read + stat + symlink ───────────────────
    var wbin: [4096]u8 = undefined;
    var w4 = std.Io.Writer.fixed(&wbin);
    w4.print("{s}/w.bin", .{dir}) catch fail("fmt4");
    const wpath = w4.buffered();
    const payload = allocator.alloc(u8, 300_000) catch fail("oom");
    defer allocator.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31 +% 7);
    const written = fs.write(wpath, 0, payload, .{ .create = true, .truncate = true }) catch
        failErr("write", fs.lastErr());
    if (written != payload.len) fail("short write");

    var back: std.ArrayList(u8) = .empty;
    defer back.deinit(allocator);
    const ri = fs.read(wpath, 1234, 4096, &back) catch failErr("read", fs.lastErr());
    if (ri.size != payload.len or ri.eof) fail("read info");
    if (back.items.len != 4096) fail("read length");
    if (!std.mem.eql(u8, back.items, payload[1234 .. 1234 + 4096])) fail("read bytes mismatch");

    back.clearRetainingCapacity();
    const tail = fs.read(wpath, payload.len - 10, 100, &back) catch failErr("read tail", fs.lastErr());
    if (!tail.eof or back.items.len != 10) fail("tail read eof/len");

    var stat_arena = std.heap.ArenaAllocator.init(allocator);
    defer stat_arena.deinit();
    const st = fs.statPath(stat_arena.allocator(), wpath) catch failErr("stat", fs.lastErr());
    if (!std.mem.eql(u8, st.kind, "file") or st.size != payload.len) fail("stat entry");

    var lbuf: [4096]u8 = undefined;
    var w5 = std.Io.Writer.fixed(&lbuf);
    w5.print("{s}/lnk", .{dir}) catch fail("fmt5");
    const lpath = w5.buffered();
    fs.symlink("w.bin", lpath) catch failErr("symlink", fs.lastErr());
    const lst = fs.statPath(stat_arena.allocator(), lpath) catch failErr("stat link", fs.lastErr());
    if (!std.mem.eql(u8, lst.kind, "link")) fail("link kind");
    if (!std.mem.eql(u8, lst.target orelse "", "w.bin")) fail("link target");
    if (lst.tdir) fail("link tdir");

    // ── chunked one-shot listing ───────────────────────────────
    var cbuf: [64]u8 = undefined;
    const chunk_dir = mkTmpDir(&cbuf, tag ++ "-big");
    {
        var i: usize = 0;
        var nb: [32]u8 = undefined;
        while (i < 1300) : (i += 1) {
            var wn = std.Io.Writer.fixed(&nb);
            wn.print("f{d:0>4}", .{i}) catch fail("fmt name");
            touch(chunk_dir, wn.buffered(), "");
        }
    }
    var big = fs.list(chunk_dir) catch failErr("big list", fs.lastErr());
    if (big.entries.len != 1300) fail("chunked listing count");
    if (big.truncated) fail("chunked listing truncated");
    big.deinit();

    // ── dir-gone view ──────────────────────────────────────────
    var gbuf: [64]u8 = undefined;
    const gone_dir = mkTmpDir(&gbuf, tag ++ "-gone");
    var gl = fs.openView(2, gone_dir) catch failErr("open gone view", fs.lastErr());
    gl.deinit();
    {
        var z2: [4096]u8 = undefined;
        _ = c.rmdir(pathz.pathZ(&z2, gone_dir) catch fail("gone path"));
    }
    if (!dlog.expectGone(&fs, 2)) fail("gone delta never arrived");
    fs.closeView(2) catch failErr("close gone view", fs.lastErr());

    // ── close_view stops the stream ────────────────────────────
    fs.closeView(1) catch failErr("close_view", fs.lastErr());
    touch(dir, "after-close", "x");
    _ = fs.waitDelta(400);
    dlog.pump(&fs);
    if (dlog.find(1, "upsert", "after-close") != null) fail("delta after close_view");

    // ── error paths ────────────────────────────────────────────
    if (fs.statPath(stat_arena.allocator(), "/definitely/not/here")) |_| {
        fail("stat of missing path succeeded");
    } else |err| if (err != fsdrive.Error.FsOpFailed) fail("stat error kind");
    if (fs.mkdir("relative/path")) |_| {
        fail("relative mkdir succeeded");
    } else |err| if (err != fsdrive.Error.FsOpFailed) fail("relative mkdir error kind");
    if (fs.openView(3, wpath)) |_| {
        fail("open_view on a file succeeded");
    } else |err| if (err != fsdrive.Error.FsOpFailed) fail("file open_view error kind");
    // Ops still work after the error runs (connection healthy).
    var okbuf: [4096]u8 = undefined;
    var w6 = std.Io.Writer.fixed(&okbuf);
    w6.print("{s}/post-err", .{dir}) catch fail("fmt6");
    fs.mkdir(w6.buffered()) catch failErr("post-error mkdir", fs.lastErr());

    // ── abrupt client death with an open view ──────────────────
    {
        var fs2 = fsdrive.Fs.connect(allocator, sock_path) catch fail("fs2 connect");
        var l2 = fs2.openView(9, dir) catch failErr("fs2 open_view", fs2.lastErr());
        l2.deinit();
        fs2.deinit(); // no close_view: daemon must reap silently
    }
    // Daemon still healthy afterwards.
    var w7buf: [4096]u8 = undefined;
    var w7 = std.Io.Writer.fixed(&w7buf);
    w7.print("{s}/post-death", .{dir}) catch fail("fmt7");
    fs.mkdir(w7.buffered()) catch failErr("post-death mkdir", fs.lastErr());

    // ── close_view aborts an in-flight listing ─────────────────
    // open_view + close_view sent back to back: the daemon must cut
    // the chunk run short with an `aborted` terminator instead of
    // statting all 1300 entries for a view nobody watches (that
    // backlog is what delayed the NEXT navigation on slow links).
    {
        fs.conn.sendJson(.fs_op, .{ .req = @as(u32, 9001), .op = "open_view", .path = chunk_dir, .view = @as(u32, 7) }) catch fail("abort open send");
        fs.conn.sendJson(.fs_op, .{ .req = @as(u32, 9002), .op = "close_view", .view = @as(u32, 7) }) catch fail("abort close send");
        const AbortReply = struct {
            req: u32 = 0,
            ok: bool = false,
            more: bool = false,
            aborted: bool = false,
            entries: []struct { name: []const u8 = "" } = &.{},
        };
        var total: usize = 0;
        var aborted = false;
        var close_ok = false;
        var rounds: usize = 0;
        while (rounds < 200 and !(aborted and close_ok)) : (rounds += 1) {
            const f = fs.conn.recvFrameFor(3000) catch fail("abort recv");
            defer f.deinit(allocator);
            if (f.ftype != .fs_reply) continue;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const rep = std.json.parseFromSliceLeaky(AbortReply, arena.allocator(), f.payload, .{
                .ignore_unknown_fields = true,
            }) catch fail("abort parse");
            if (rep.req == 9001) {
                total += rep.entries.len;
                if (rep.aborted) aborted = true;
                if (!rep.more and !rep.aborted) fail("listing ran to completion instead of aborting");
            } else if (rep.req == 9002 and rep.ok) close_ok = true;
        }
        if (!aborted) fail("no aborted listing terminator");
        if (!close_ok) fail("close_view reply missing");
        if (total >= 1300) fail("abort did not stop the stat stream");
    }

    // ── wire-cache thumbnails (remote-serving mode) ────────────
    wireThumbStage(allocator, &fs, dir, tag);

    std.debug.print("smoke-fs: {s} stage ok\n", .{tag});
}

/// An 8x8 RGB gradient PNG (stb-decodable) for the thumbnail stages.
const TINY_PNG = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x08, 0x02, 0x00, 0x00, 0x00, 0x4b, 0x6d, 0x29,
    0xdc, 0x00, 0x00, 0x00, 0x6c, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x0d, 0xc9, 0x41, 0x01, 0x00,
    0x30, 0x08, 0x03, 0x31, 0x94, 0xa0, 0xa4, 0x4a, 0xaa, 0x84, 0xe7, 0xa9, 0x40, 0x09, 0x4a, 0xaa,
    0x68, 0xcb, 0x37, 0x55, 0x45, 0x17, 0x2a, 0x5c, 0x4c, 0xb1, 0xc5, 0x15, 0x29, 0xaa, 0x9a, 0x6e,
    0xd4, 0xb8, 0x99, 0x66, 0x9b, 0x6b, 0xd2, 0x3f, 0x44, 0x0b, 0x09, 0x8b, 0x11, 0x2b, 0x4e, 0x44,
    0x3f, 0x4c, 0x1b, 0x19, 0x9b, 0x31, 0x6b, 0xce, 0xc4, 0x3f, 0x86, 0x1e, 0x34, 0x78, 0x98, 0x61,
    0x87, 0x1b, 0x32, 0x3f, 0x96, 0x5e, 0xb4, 0x78, 0x99, 0x65, 0x97, 0x5b, 0xb2, 0x3f, 0x8e, 0x3e,
    0x74, 0xf8, 0x98, 0x63, 0x8f, 0x3b, 0x72, 0x3f, 0x42, 0x07, 0x05, 0x87, 0x09, 0x1b, 0x2e, 0x24,
    0x3c, 0xb0, 0x2c, 0x54, 0x81, 0x31, 0xc8, 0xe3, 0xff, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
    0x44, 0xae, 0x42, 0x60, 0x82,
};

const WireThumbRes = struct {
    ok: bool = false,
    keep: bool = false,
    path: [4096]u8 = undefined,
    path_len: usize = 0,
    err: [256]u8 = undefined,
    err_len: usize = 0,

    fn assetPath(self: *const WireThumbRes) []const u8 {
        return self.path[0..self.path_len];
    }
    fn errMsg(self: *const WireThumbRes) []const u8 {
        return self.err[0..self.err_len];
    }
};

/// Run one wire-cache thumbnail/preview job to completion over the raw conn.
fn wireThumbRequest(allocator: std.mem.Allocator, fs: *fsdrive.Fs, op: []const u8, src: []const u8, req: u32) WireThumbRes {
    fs.conn.sendJson(.fs_op, .{
        .req = req,
        .op = op,
        .path = src,
        .image_codecs = "jxl,webp",
        .wire_cache = true,
    }) catch fail("wire thumb send");
    var res = WireThumbRes{};
    var job: u64 = 0;
    const Ev = struct {
        job: u64 = 0,
        ev: []const u8 = "",
        path: []const u8 = "",
        message: []const u8 = "",
        keep: bool = false,
    };
    const Rep = struct { req: u32 = 0, ok: bool = false, job: u64 = 0, @"error": []const u8 = "" };
    var rounds: usize = 0;
    while (rounds < 300) : (rounds += 1) {
        const f = fs.conn.recvFrameFor(3000) catch fail("wire thumb recv");
        defer f.deinit(allocator);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (f.ftype == .fs_reply) {
            const rep = std.json.parseFromSliceLeaky(Rep, arena.allocator(), f.payload, .{
                .ignore_unknown_fields = true,
            }) catch fail("wire thumb reply parse");
            if (rep.req != req) continue;
            if (!rep.ok or rep.job == 0) fail("wire thumb job start refused");
            job = rep.job;
        } else if (f.ftype == .fs_job) {
            const ev = std.json.parseFromSliceLeaky(Ev, arena.allocator(), f.payload, .{
                .ignore_unknown_fields = true,
            }) catch fail("wire thumb event parse");
            if (job == 0 or ev.job != job) continue;
            if (std.mem.eql(u8, ev.ev, "done")) {
                res.ok = true;
                res.keep = ev.keep;
                res.path_len = @min(ev.path.len, res.path.len);
                @memcpy(res.path[0..res.path_len], ev.path[0..res.path_len]);
                return res;
            }
            if (std.mem.eql(u8, ev.ev, "error")) {
                res.err_len = @min(ev.message.len, res.err.len);
                @memcpy(res.err[0..res.err_len], ev.message[0..res.err_len]);
                return res;
            }
        }
    }
    fail("wire thumb never finished");
}

/// The remote-serving thumbnail cache: codec bytes cached host-side,
/// served in place (keep), no freedesktop PNG installed, hits are
/// stat-validated, and a changed source misses.
fn wireThumbStage(allocator: std.mem.Allocator, fs: *fsdrive.Fs, dir: []const u8, comptime tag: []const u8) void {
    touch(dir, "wire-photo.png", &TINY_PNG);
    var src_buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&src_buf);
    w.print("{s}/wire-photo.png", .{dir}) catch fail("wire fmt");
    const src = w.buffered();

    const first = wireThumbRequest(allocator, fs, "thumbnail", src, 9100);
    if (!first.ok) {
        // No libjxl/libwebp on this host: the fallback (spec PNG +
        // per-fetch transcode) also cannot encode, so there is
        // nothing more to prove here.
        std.debug.print("smoke-fs: {s} wire-thumb stage skipped ({s})\n", .{ tag, first.errMsg() });
        return;
    }
    if (!first.keep) fail("wire thumb asset not marked keep");
    if (std.mem.indexOf(u8, first.assetPath(), "/sketerm/thumbs/") == null)
        fail("wire thumb asset outside the wire cache");

    var z: [4096:0]u8 = undefined;
    var st: c.struct_stat = undefined;
    if (c.stat(pathz.pathZ(&z, first.assetPath()) catch fail("wire path"), &st) != 0)
        fail("wire thumb cache file missing");
    if (st.st_size <= 0) fail("wire thumb cache file empty");
    const first_ino = st.st_ino;
    var src_st: c.struct_stat = undefined;
    if (c.stat(pathz.pathZ(&z, src) catch fail("wire src path"), &src_st) != 0) fail("wire src stat");
    if (mtime(st).tv_sec != mtime(src_st).tv_sec) fail("wire thumb freshness stamp wrong");

    // No freedesktop PNG may have been installed for this source.
    const cache_root = std.mem.span(@as([*:0]const u8, @ptrCast(c.getenv("XDG_CACHE_HOME") orelse fail("no cache home"))));
    var fd_buf: [4096]u8 = undefined;
    const fd_png = thumbs_mod.thumbPath(cache_root, src, &fd_buf) orelse fail("fd path");
    if (c.stat(pathz.pathZ(&z, fd_png) catch fail("fd pathz"), &st) == 0)
        fail("wire mode installed a freedesktop PNG");

    // Second request: served from the cache file, not rebuilt.
    const second = wireThumbRequest(allocator, fs, "thumbnail", src, 9101);
    if (!second.ok or !second.keep) fail("wire thumb re-request failed");
    if (!std.mem.eql(u8, first.assetPath(), second.assetPath())) fail("wire thumb hit path differs");
    if (c.stat(pathz.pathZ(&z, second.assetPath()) catch fail("wire path"), &st) != 0)
        fail("wire thumb cache vanished");
    if (st.st_ino != first_ino) fail("wire thumb hit rebuilt the cache file");

    // A changed source misses and reinstalls (new inode, new stamp).
    {
        var ts = [2]c.struct_timespec{
            .{ .tv_sec = mtime(src_st).tv_sec + 5, .tv_nsec = 0 },
            .{ .tv_sec = mtime(src_st).tv_sec + 5, .tv_nsec = 0 },
        };
        if (c.utimensat(c.AT_FDCWD, pathz.pathZ(&z, src) catch fail("wire src path"), &ts, 0) != 0)
            fail("wire src touch");
    }
    const third = wireThumbRequest(allocator, fs, "thumbnail", src, 9102);
    if (!third.ok or !third.keep) fail("wire thumb refresh failed");
    if (c.stat(pathz.pathZ(&z, third.assetPath()) catch fail("wire path"), &st) != 0)
        fail("wire thumb refresh missing");
    if (st.st_ino == first_ino) fail("stale wire thumb served after source change");
    if (mtime(st).tv_sec != mtime(src_st).tv_sec + 5) fail("wire thumb refresh stamp wrong");

    // The 512px preview tier: same regime, its own xl/ cache dir, no
    // x-large freedesktop PNG, and it never collides with the 128px
    // entry of the same source.
    const pv = wireThumbRequest(allocator, fs, "preview", src, 9103);
    if (!pv.ok or !pv.keep) fail("wire preview failed");
    if (std.mem.indexOf(u8, pv.assetPath(), "/sketerm/thumbs/xl/") == null)
        fail("wire preview asset outside the xl wire cache");
    if (std.mem.eql(u8, pv.assetPath(), third.assetPath())) fail("preview collided with thumbnail entry");
    if (c.stat(pathz.pathZ(&z, pv.assetPath()) catch fail("wire path"), &st) != 0)
        fail("wire preview cache file missing");
    if (mtime(st).tv_sec != mtime(src_st).tv_sec + 5) fail("wire preview freshness stamp wrong");
    const pv_ino = st.st_ino;
    var xl_buf: [4096]u8 = undefined;
    const fd_xl = thumbs_mod.thumbPathTier(cache_root, src, .x_large, &xl_buf) orelse fail("fd xl path");
    if (c.stat(pathz.pathZ(&z, fd_xl) catch fail("fd xl pathz"), &st) == 0)
        fail("wire preview installed an x-large freedesktop PNG");
    const pv2 = wireThumbRequest(allocator, fs, "preview", src, 9104);
    if (!pv2.ok or !pv2.keep) fail("wire preview re-request failed");
    if (c.stat(pathz.pathZ(&z, pv2.assetPath()) catch fail("wire path"), &st) != 0)
        fail("wire preview cache vanished");
    if (st.st_ino != pv_ino) fail("wire preview hit rebuilt the cache file");

    std.debug.print("smoke-fs: {s} wire-thumb stage ok\n", .{tag});
}

/// Stream-hash a local file (verification oracle for copy jobs).
fn fileSha(path: []const u8) ?[64]u8 {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return null;
    const f = c.fopen(p, "rb") orelse return null;
    defer _ = c.fclose(f);
    var h = Sha256.init(.{});
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    var hex: [64]u8 = undefined;
    for (digest, 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    }
    return hex;
}

fn writePattern(path: []const u8, len: usize, seed: u8) void {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch fail("pattern path");
    const f = c.fopen(p, "wb") orelse fail("pattern open");
    defer _ = c.fclose(f);
    var buf: [65536]u8 = undefined;
    var off: usize = 0;
    while (off < len) {
        const n = @min(buf.len, len - off);
        for (buf[0..n], 0..) |*b, i| b.* = @truncate((off + i) *% 31 +% seed);
        if (c.fwrite(&buf, 1, n, f) != n) fail("pattern write");
        off += n;
    }
}

const MoveMutation = struct {
    part: []const u8,
    source_dir: []const u8,
    mutated: bool = false,
};

fn mutateMoveAfterCopyStarts(ctx: *MoveMutation) void {
    var waited: usize = 0;
    while (waited < 20_000) : (waited += 2) {
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.stat(pathz.pathZ(&z, ctx.part) catch return, &st) == 0 and st.st_size >= (1 << 20)) {
            touch(ctx.source_dir, "a-copied.txt", "changed after copy");
            touch(ctx.source_dir, "unexpected.txt", "late arrival");
            ctx.mutated = true;
            return;
        }
        _ = c.usleep(2_000);
    }
}

const MoveReplacement = struct {
    source: []const u8,
    replaced: bool = false,
};

fn replaceMoveSourceAfterQuarantine(ctx: *MoveReplacement) void {
    var waited: usize = 0;
    while (waited < 20_000) : (waited += 1) {
        if (!exists(ctx.source)) {
            writePattern(ctx.source, 4096, 0xa7);
            ctx.replaced = true;
            return;
        }
        _ = c.usleep(1_000);
    }
}

const CopyHelperKill = struct {
    journal: []const u8,
    part: []const u8,
    min_bytes: u64 = 2 << 20,
    killed: bool = false,
};

/// SIGKILL the copy helper once its staged partial has real bytes —
/// the deterministic "attempt died mid-transfer" a retry must resume.
fn killCopyHelperMidTransfer(ctx: *CopyHelperKill) void {
    var waited: usize = 0;
    while (waited < 20_000) : (waited += 1) {
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.stat(pathz.pathZ(&z, ctx.part) catch return, &st) == 0 and
            st.st_size >= @as(c.off_t, @intCast(ctx.min_bytes)))
        {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            if (fsjournal.load(arena.allocator(), ctx.journal)) |parsed_value| {
                var parsed = parsed_value;
                defer parsed.deinit();
                if (parsed.value.pid > 0 and
                    c.kill(-@as(c.pid_t, @intCast(parsed.value.pid)), c.SIGKILL) == 0)
                {
                    ctx.killed = true;
                    return;
                }
            } else |_| {}
        }
        _ = c.usleep(1_000);
    }
}

const QuarantineBlock = struct {
    journal: []const u8,
    parent: []const u8,
    blocked: bool = false,
};

/// Make the move's source parent read-only as soon as staged bytes
/// exist: the copy and install succeed, then the quarantine rename
/// fails deterministically — the "copy complete, source retained"
/// failure class.
fn blockQuarantineDuringCopy(ctx: *QuarantineBlock) void {
    var waited: usize = 0;
    while (waited < 20_000) : (waited += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (fsjournal.load(arena.allocator(), ctx.journal)) |parsed_value| {
            var parsed = parsed_value;
            defer parsed.deinit();
            if (parsed.value.destination_stage.len > 0) {
                var part_buf: [4096]u8 = undefined;
                const part = std.fmt.bufPrint(&part_buf, "{s}.skpart", .{parsed.value.destination_stage}) catch return;
                if (exists(part) or exists(parsed.value.destination_stage)) {
                    var z: [4096]u8 = undefined;
                    if (c.chmod(pathz.pathZ(&z, ctx.parent) catch return, 0o555) == 0)
                        ctx.blocked = true;
                    return;
                }
            }
        } else |_| {}
        _ = c.usleep(1_000);
    }
}

const MoveHelperKill = struct {
    journal: []const u8,
    remove_after_kill: []const u8 = "",
    stage_child: []const u8 = "",
    killed: bool = false,
};

fn killMoveHelperAfterCopy(ctx: *MoveHelperKill) void {
    var waited: usize = 0;
    while (waited < 20_000) : (waited += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (fsjournal.load(arena.allocator(), ctx.journal)) |parsed_value| {
            var parsed = parsed_value;
            defer parsed.deinit();
            if (std.mem.eql(u8, parsed.value.phase, "copied") and
                parsed.value.source_quarantine.len > 0 and exists(parsed.value.source_quarantine) and
                parsed.value.pid > 0)
            {
                if (c.kill(-@as(c.pid_t, @intCast(parsed.value.pid)), c.SIGKILL) == 0) {
                    ctx.killed = true;
                    if (ctx.remove_after_kill.len > 0) {
                        var z: [4096]u8 = undefined;
                        _ = c.unlink(pathz.pathZ(&z, ctx.remove_after_kill) catch return);
                    }
                }
                return;
            }
        } else |_| {}
        _ = c.usleep(1_000);
    }
}

fn killMoveHelperInDestinationStage(ctx: *MoveHelperKill) void {
    var waited: usize = 0;
    while (waited < 20_000) : (waited += 1) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (fsjournal.load(arena.allocator(), ctx.journal)) |parsed_value| {
            var parsed = parsed_value;
            defer parsed.deinit();
            var child_ready = true;
            if (ctx.stage_child.len > 0 and parsed.value.destination_stage.len > 0) {
                var child_buf: [4096]u8 = undefined;
                const child = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{
                    parsed.value.destination_stage,
                    ctx.stage_child,
                }) catch return;
                child_ready = exists(child);
            } else if (parsed.value.destination_stage.len > 0) {
                // Single-file stage: the bare staged file's lifetime is
                // a handful of stats now that verified digests are
                // cached, so the reliable kill window is the transfer
                // itself — the growing `.skpart` under the stage name.
                var part_buf: [4096]u8 = undefined;
                const part = std.fmt.bufPrint(&part_buf, "{s}.skpart", .{parsed.value.destination_stage}) catch return;
                var z: [4096]u8 = undefined;
                var st: c.struct_stat = undefined;
                child_ready = c.stat(pathz.pathZ(&z, part) catch return, &st) == 0 and
                    st.st_size >= (1 << 20);
            }
            if (std.mem.eql(u8, parsed.value.phase, "rename_planned") and
                parsed.value.destination_stage.len > 0 and
                child_ready and
                parsed.value.pid > 0)
            {
                if (c.kill(-@as(c.pid_t, @intCast(parsed.value.pid)), c.SIGKILL) == 0) {
                    ctx.killed = true;
                    if (ctx.remove_after_kill.len > 0) {
                        var z: [4096]u8 = undefined;
                        _ = c.unlink(pathz.pathZ(&z, ctx.remove_after_kill) catch return);
                    }
                }
                return;
            }
        } else |_| {}
        _ = c.usleep(1_000);
    }
}

/// Consume this job's event stream until terminal, counting progress
/// frames. Fails the smoke on timeout.
const JobOutcome = struct {
    ev: [12]u8 = undefined,
    ev_len: usize = 0,
    done: u64 = 0,
    resumed_from: u64 = 0,
    hash: [64]u8 = undefined,
    has_hash: bool = false,
    progress_events: usize = 0,
    /// Distinct in-flight paths named by progress lines, and whether
    /// the byte counter ever moved BACKWARDS (a tree copy used to
    /// restart `done` at zero on every file).
    files_named: usize = 0,
    last_file: [512]u8 = undefined,
    last_file_len: usize = 0,
    regressed: bool = false,
    max_done: u64 = 0,
    /// Highest entry counters any event carried.
    files_done: u64 = 0,
    files_total: u64 = 0,
    first_files_total: u64 = 0,
    files_total_changed: bool = false,
    /// Was `resumed_from` ever non-zero on a RUNNING (progress) line?
    resumed_while_running: bool = false,
    /// The terminal event's message: for a failed job this IS the
    /// reason, and a generic one is a bug worth failing on.
    message: [320]u8 = undefined,
    message_len: usize = 0,
    /// Did a RUNNING line ever explain a stall? A cross-host copy
    /// riding out a dropped link must say so rather than look frozen.
    said_reconnecting: bool = false,
    /// Bytes already transferred when the link came back. Non-zero is
    /// the whole point: a resume continues, it does not restart.
    resumed_at: u64 = 0,
    /// The terminal event's structural cause ("unreachable" on a
    /// failed dial), which drives the browser's coordinator fallback.
    kind: [32]u8 = undefined,
    kind_len: usize = 0,

    fn kindText(self: *const JobOutcome) []const u8 {
        return self.kind[0..self.kind_len];
    }

    fn is(self: *const JobOutcome, ev: []const u8) bool {
        return std.mem.eql(u8, self.ev[0..self.ev_len], ev);
    }

    fn messageText(self: *const JobOutcome) []const u8 {
        return self.message[0..self.message_len];
    }

    fn namedFile(self: *const JobOutcome) []const u8 {
        return self.last_file[0..self.last_file_len];
    }
};

fn collectJob(fs: *fsdrive.Fs, job: u64, timeout_ms: i64) JobOutcome {
    var out = JobOutcome{};
    var waited: i64 = 0;
    while (waited < timeout_ms) {
        while (fs.takeJobEvent()) |e0| {
            var e = e0;
            defer e.deinit();
            if (e.job != job) continue;
            if (e.files_done > out.files_done) out.files_done = e.files_done;
            if (e.files_total > 0) {
                if (out.first_files_total == 0)
                    out.first_files_total = e.files_total
                else if (e.files_total != out.first_files_total)
                    out.files_total_changed = true;
            }
            if (e.files_total > out.files_total) out.files_total = e.files_total;
            if (std.mem.eql(u8, e.ev, "progress")) {
                out.progress_events += 1;
                if (std.mem.indexOf(u8, e.message, "reconnect") != null) out.said_reconnecting = true;
                if (std.mem.indexOf(u8, e.message, "reconnected") != null and e.done > out.resumed_at)
                    out.resumed_at = e.done;
                if (e.done < out.max_done) out.regressed = true;
                if (e.done > out.max_done) out.max_done = e.done;
                if (e.resumed_from > 0) out.resumed_while_running = true;
                if (e.file.len > 0 and !std.mem.eql(u8, e.file, out.namedFile())) {
                    out.files_named += 1;
                    out.last_file_len = @min(e.file.len, out.last_file.len);
                    @memcpy(out.last_file[0..out.last_file_len], e.file[0..out.last_file_len]);
                }
                continue;
            }
            if (e.terminal()) {
                const n = @min(e.ev.len, out.ev.len);
                @memcpy(out.ev[0..n], e.ev[0..n]);
                out.ev_len = n;
                out.done = e.done;
                out.resumed_from = e.resumed_from;
                out.message_len = @min(e.message.len, out.message.len);
                @memcpy(out.message[0..out.message_len], e.message[0..out.message_len]);
                out.kind_len = @min(e.kind.len, out.kind.len);
                @memcpy(out.kind[0..out.kind_len], e.kind[0..out.kind_len]);
                if (e.hash.len == 64) {
                    @memcpy(&out.hash, e.hash[0..64]);
                    out.has_hash = true;
                }
                return out;
            }
        }
        _ = c.usleep(5_000);
        waited += 5;
    }
    fail("job never reached a terminal event");
}

fn jobStage(allocator: std.mem.Allocator, sock_path: []const u8, comptime tag: []const u8) void {
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf, tag ++ "-job");
    var fs = fsdrive.Fs.connect(allocator, sock_path) catch fail("job fs connect");
    defer fs.deinit();

    var pb: [8][4096]u8 = undefined;
    const src = (std.fmt.bufPrint(&pb[0], "{s}/big.bin", .{dir}) catch unreachable);
    const dst = (std.fmt.bufPrint(&pb[1], "{s}/big.copy", .{dir}) catch unreachable);
    writePattern(src, 6 << 20, 7);
    const src_hash = fileSha(src) orelse fail("src hash");

    // ── hash job matches a local oracle ────────────────────────
    const hjob = fs.startHash(src) catch failErr("start hash", fs.lastErr());
    const hout = collectJob(&fs, hjob, 20_000);
    if (!hout.is("done") or !hout.has_hash) fail("hash job outcome");
    if (!std.mem.eql(u8, &hout.hash, &src_hash)) fail("hash job digest mismatch");

    // ── plain copy: progress + identical content ───────────────
    const cjob = fs.startCopy(src, dst, false) catch failErr("start copy", fs.lastErr());
    const cout = collectJob(&fs, cjob, 20_000);
    if (!cout.is("done") or cout.resumed_from != 0) fail("copy outcome");
    if (cout.progress_events < 1) fail("copy produced no progress events");
    const dst_hash = fileSha(dst) orelse fail("dst hash");
    if (!std.mem.eql(u8, &dst_hash, &src_hash)) fail("copy content mismatch");

    // Stable tokens make submission idempotent across a lost reply.
    var token_dst_buf: [4096]u8 = undefined;
    const token_dst = std.fmt.bufPrint(&token_dst_buf, "{s}/token.copy", .{dir}) catch unreachable;
    const token_job = fs.startCopyToken(src, token_dst, true, "smoke-stable-token") catch failErr("start token copy", fs.lastErr());
    const same_job = fs.startCopyToken(src, token_dst, true, "smoke-stable-token") catch failErr("repeat token copy", fs.lastErr());
    if (same_job != token_job) fail("stable token started a duplicate job");
    const token_out = collectJob(&fs, token_job, 20_000);
    if (!token_out.is("done")) fail("token copy outcome");
    // A reconnect after completion must get both the same identity and
    // a replayed terminal event; otherwise waitJobEnd hangs forever.
    {
        var recovered = fsdrive.Fs.connect(allocator, sock_path) catch fail("token recovery connect");
        defer recovered.deinit();
        const recovered_job = recovered.startCopyToken(src, token_dst, true, "smoke-stable-token") catch failErr("recover completed token copy", recovered.lastErr());
        if (recovered_job != token_job) fail("completed token started a duplicate job");
        const recovered_out = collectJob(&recovered, recovered_job, 2_000);
        if (!recovered_out.is("done")) fail("completed token outcome was not replayed");
    }
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const rows = fs.jobList(arena.allocator()) catch failErr("token job_list", fs.lastErr());
        var found = false;
        for (rows) |row| {
            if (row.job == token_job and std.mem.eql(u8, row.client_token, "smoke-stable-token")) found = true;
        }
        if (!found) fail("job_list omitted stable token metadata");
    }

    // ── hash-verified resume: valid partial continues ──────────
    const rdst = (std.fmt.bufPrint(&pb[2], "{s}/resumed.bin", .{dir}) catch unreachable);
    {
        var part: [4096]u8 = undefined;
        const partp = std.fmt.bufPrint(&part, "{s}.skpart", .{rdst}) catch unreachable;
        // Seed the partial with the true first 2MB.
        var zs: [4096]u8 = undefined;
        var zd: [4096]u8 = undefined;
        const sf = c.fopen(pathz.pathZ(&zs, src) catch unreachable, "rb") orelse fail("seed open src");
        const df = c.fopen(pathz.pathZ(&zd, partp) catch unreachable, "wb") orelse fail("seed open part");
        var buf: [65536]u8 = undefined;
        var left: usize = 2 << 20;
        while (left > 0) {
            const n = c.fread(&buf, 1, @min(buf.len, left), sf);
            if (n == 0) break;
            _ = c.fwrite(&buf, 1, n, df);
            left -= n;
        }
        _ = c.fclose(sf);
        _ = c.fclose(df);
    }
    const rjob = fs.startCopy(src, rdst, true) catch failErr("start resume copy", fs.lastErr());
    const rout = collectJob(&fs, rjob, 20_000);
    if (!rout.is("done")) fail("resume copy outcome");
    if (rout.resumed_from != (2 << 20)) fail("resume did not continue from the partial");
    if (!std.mem.eql(u8, &(fileSha(rdst) orelse fail("rdst hash")), &src_hash)) fail("resumed content mismatch");

    // ── corrupt partial restarts from zero ─────────────────────
    const xdst = (std.fmt.bufPrint(&pb[3], "{s}/restart.bin", .{dir}) catch unreachable);
    {
        var part: [4096]u8 = undefined;
        const partp = std.fmt.bufPrint(&part, "{s}.skpart", .{xdst}) catch unreachable;
        writePattern(partp, 1 << 20, 99); // wrong bytes
    }
    const xjob = fs.startCopy(src, xdst, true) catch failErr("start restart copy", fs.lastErr());
    const xout = collectJob(&fs, xjob, 20_000);
    if (!xout.is("done") or xout.resumed_from != 0) fail("corrupt partial was resumed");
    if (!std.mem.eql(u8, &(fileSha(xdst) orelse fail("xdst hash")), &src_hash)) fail("restart content mismatch");

    // ── pause / resume / cancel on a BLOCKED job (fifo src: the
    // helper sits in open(2) forever — the stuck-IO case subprocess
    // jobs exist for; only SIGKILL can end it) ─────────────────
    const fifo = (std.fmt.bufPrint(&pb[4], "{s}/pipe.src", .{dir}) catch unreachable);
    {
        var z: [4096]u8 = undefined;
        if (c.mkfifo(pathz.pathZ(&z, fifo) catch unreachable, 0o600) != 0) fail("mkfifo");
    }
    const fdst = (std.fmt.bufPrint(&pb[5], "{s}/pipe.copy", .{dir}) catch unreachable);
    const pjob = fs.startCopy(fifo, fdst, false) catch failErr("start blocked copy", fs.lastErr());
    fs.jobPause(pjob) catch failErr("job_pause", fs.lastErr());
    fs.jobResume(pjob) catch failErr("job_resume", fs.lastErr());
    fs.jobCancel(pjob) catch failErr("job_cancel", fs.lastErr());
    const pout = collectJob(&fs, pjob, 20_000);
    if (!pout.is("canceled")) fail("blocked job not canceled");

    // ── tree copy + delete_tree ────────────────────────────────
    const tsrc = (std.fmt.bufPrint(&pb[6], "{s}/tree", .{dir}) catch unreachable);
    const tdst = (std.fmt.bufPrint(&pb[7], "{s}/tree.copy", .{dir}) catch unreachable);
    {
        var z: [4096]u8 = undefined;
        _ = c.mkdir(pathz.pathZ(&z, tsrc) catch unreachable, 0o755);
        var sub: [4096]u8 = undefined;
        const subp = std.fmt.bufPrint(&sub, "{s}/sub", .{tsrc}) catch unreachable;
        _ = c.mkdir(pathz.pathZ(&z, subp) catch unreachable, 0o755);
        var fp: [4096]u8 = undefined;
        writePattern(std.fmt.bufPrint(&fp, "{s}/top.dat", .{tsrc}) catch unreachable, 10_000, 3);
        writePattern(std.fmt.bufPrint(&fp, "{s}/sub/leaf.dat", .{tsrc}) catch unreachable, 20_000, 4);
        var lz: [4096]u8 = undefined;
        const lp = std.fmt.bufPrint(&fp, "{s}/ln", .{tsrc}) catch unreachable;
        _ = c.symlink("top.dat", pathz.pathZ(&lz, lp) catch unreachable);
    }
    const tjob = fs.startCopy(tsrc, tdst, false) catch failErr("start tree copy", fs.lastErr());
    const tout = collectJob(&fs, tjob, 20_000);
    if (!tout.is("done")) fail("tree copy outcome");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var fp: [4096]u8 = undefined;
        const leaf = std.fmt.bufPrint(&fp, "{s}/sub/leaf.dat", .{tdst}) catch unreachable;
        const lst = fs.statPath(arena.allocator(), leaf) catch failErr("tree leaf stat", fs.lastErr());
        if (lst.size != 20_000) fail("tree leaf size");
        const lnp = std.fmt.bufPrint(&fp, "{s}/ln", .{tdst}) catch unreachable;
        const lnst = fs.statPath(arena.allocator(), lnp) catch failErr("tree link stat", fs.lastErr());
        if (!std.mem.eql(u8, lnst.kind, "link")) fail("tree link kind");
        if (!std.mem.eql(u8, lnst.target orelse "", "top.dat")) fail("tree link target");
    }

    // A root symlink is the object being copied, even when its target
    // is a regular file or directory. It must never turn into a copy of
    // the target tree/content.
    {
        var root_paths: [4][4096]u8 = undefined;
        const file_link = std.fmt.bufPrint(&root_paths[0], "{s}/root-file-link", .{dir}) catch unreachable;
        const dir_link = std.fmt.bufPrint(&root_paths[1], "{s}/root-dir-link", .{dir}) catch unreachable;
        const file_copy = std.fmt.bufPrint(&root_paths[2], "{s}/root-file-link.copy", .{dir}) catch unreachable;
        const dir_copy = std.fmt.bufPrint(&root_paths[3], "{s}/root-dir-link.copy", .{dir}) catch unreachable;
        var z: [4096]u8 = undefined;
        if (c.symlink("tree/top.dat", pathz.pathZ(&z, file_link) catch unreachable) != 0) fail("root file symlink");
        if (c.symlink("tree", pathz.pathZ(&z, dir_link) catch unreachable) != 0) fail("root dir symlink");
        const file_job = fs.startCopy(file_link, file_copy, false) catch failErr("copy root file symlink", fs.lastErr());
        if (!collectJob(&fs, file_job, 20_000).is("done")) fail("root file symlink copy failed");
        const dir_job = fs.startCopy(dir_link, dir_copy, false) catch failErr("copy root dir symlink", fs.lastErr());
        if (!collectJob(&fs, dir_job, 20_000).is("done")) fail("root dir symlink copy failed");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const file_st = fs.statPath(arena.allocator(), file_copy) catch failErr("stat root file symlink copy", fs.lastErr());
        const dir_st = fs.statPath(arena.allocator(), dir_copy) catch failErr("stat root dir symlink copy", fs.lastErr());
        if (!std.mem.eql(u8, file_st.kind, "link") or !std.mem.eql(u8, file_st.target orelse "", "tree/top.dat"))
            fail("root file symlink was dereferenced");
        if (!std.mem.eql(u8, dir_st.kind, "link") or !dir_st.tdir or !std.mem.eql(u8, dir_st.target orelse "", "tree"))
            fail("root directory symlink was dereferenced");
    }
    const djob = fs.startDeleteTree(tdst) catch failErr("start delete_tree", fs.lastErr());
    const dout = collectJob(&fs, djob, 20_000);
    if (!dout.is("done")) fail("delete_tree outcome");
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        if (fs.statPath(arena.allocator(), tdst)) |_| {
            fail("delete_tree left the tree");
        } else |_| {}
    }

    // ── find / grep search jobs ────────────────────────────────
    {
        var z: [4096]u8 = undefined;
        var fp: [4096]u8 = undefined;
        const sdir = std.fmt.bufPrint(&fp, "{s}/searchme", .{dir}) catch unreachable;
        _ = c.mkdir(pathz.pathZ(&z, sdir) catch unreachable, 0o755);
        var fp2: [4096]u8 = undefined;
        const sub2 = std.fmt.bufPrint(&fp2, "{s}/searchme/deep", .{dir}) catch unreachable;
        _ = c.mkdir(pathz.pathZ(&z, sub2) catch unreachable, 0o755);
        var fp3: [4096]u8 = undefined;
        touch(sdir, "needle-alpha.txt", "nothing here\nthe MAGIC-TOKEN line\ntail\n");
        touch(sub2, "other.log", "MAGIC-TOKEN again\n");
        touch(sdir, "binary.bin", "\x00\x01MAGIC-TOKEN");
        _ = std.fmt.bufPrint(&fp3, "x", .{}) catch unreachable;

        // find by ci substring
        const fjob = fs.startFind(sdir, "NEEDLE") catch failErr("start find", fs.lastErr());
        var found_path = false;
        var fdone = false;
        var waited: i64 = 0;
        while (!fdone and waited < 20_000) {
            while (fs.takeJobEvent()) |e0| {
                var e = e0;
                defer e.deinit();
                if (e.job != fjob) continue;
                if (std.mem.eql(u8, e.ev, "match")) {
                    if (std.mem.endsWith(u8, e.path, "needle-alpha.txt")) found_path = true;
                } else if (e.terminal()) {
                    if (!std.mem.eql(u8, e.ev, "done")) fail("find job failed");
                    if (e.matches != 1) fail("find match count");
                    fdone = true;
                }
            }
            _ = c.usleep(5_000);
            waited += 5;
        }
        if (!fdone or !found_path) fail("find never matched");

        // find by glob
        const gjob = fs.startFind(sdir, "*.log") catch failErr("start find glob", fs.lastErr());
        var glob_hit = false;
        var gdone = false;
        waited = 0;
        while (!gdone and waited < 20_000) {
            while (fs.takeJobEvent()) |e0| {
                var e = e0;
                defer e.deinit();
                if (e.job != gjob) continue;
                if (std.mem.eql(u8, e.ev, "match")) {
                    if (std.mem.endsWith(u8, e.path, "deep/other.log")) glob_hit = true;
                } else if (e.terminal()) gdone = true;
            }
            _ = c.usleep(5_000);
            waited += 5;
        }
        if (!gdone or !glob_hit) fail("glob find never matched");

        // grep: ci content matches with line numbers; binary skipped
        const cjob2 = fs.startGrep(sdir, "magic-token") catch failErr("start grep", fs.lastErr());
        var hits: usize = 0;
        var line2_seen = false;
        var bin_hit = false;
        var cdone = false;
        waited = 0;
        while (!cdone and waited < 20_000) {
            while (fs.takeJobEvent()) |e0| {
                var e = e0;
                defer e.deinit();
                if (e.job != cjob2) continue;
                if (std.mem.eql(u8, e.ev, "match")) {
                    hits += 1;
                    if (std.mem.endsWith(u8, e.path, "needle-alpha.txt") and e.line == 2) line2_seen = true;
                    if (std.mem.endsWith(u8, e.path, "binary.bin")) bin_hit = true;
                    if (std.mem.indexOf(u8, e.text, "MAGIC-TOKEN") == null) fail("grep match text");
                } else if (e.terminal()) {
                    if (!std.mem.eql(u8, e.ev, "done")) fail("grep job failed");
                    cdone = true;
                }
            }
            _ = c.usleep(5_000);
            waited += 5;
        }
        if (!cdone or hits != 2 or !line2_seen) fail("grep matches wrong");
        if (bin_hit) fail("grep matched a binary file");

        // Preview text runs in an ephemeral helper and returns bounded
        // content without blocking the daemon poll loop.
        const preview_job = fs.startPreview(std.fmt.bufPrint(&fp3, "{s}/needle-alpha.txt", .{sdir}) catch unreachable) catch failErr("start preview", fs.lastErr());
        var preview_done = false;
        waited = 0;
        while (!preview_done and waited < 20_000) {
            while (fs.takeJobEvent()) |e0| {
                var e = e0;
                defer e.deinit();
                if (e.job != preview_job) continue;
                if (std.mem.eql(u8, e.ev, "done")) {
                    if (std.mem.indexOf(u8, e.text, "MAGIC-TOKEN") == null) fail("preview text missing");
                    preview_done = true;
                } else if (e.terminal()) fail("preview job failed");
            }
            if (!preview_done) _ = c.usleep(5_000);
            waited += 5;
        }
        if (!preview_done) fail("preview never completed");

        // Image preview transport: the helper answers with a bounded
        // sidecar (plain PNG for a png-advertising receiver, JXL/WebP
        // when the host codecs allow), which the receiver reads and
        // then unlinks through the ownership-aware unlink op.
        {
            var fpi: [4096]u8 = undefined;
            var pic_z: [4096:0]u8 = undefined;
            const pic = std.fmt.bufPrint(&fpi, "{s}/pic.png", .{sdir}) catch unreachable;
            _ = std.fmt.bufPrintZ(&pic_z, "{s}", .{pic}) catch unreachable;
            var rgba: [64 * 48 * 4]u8 = undefined;
            for (0..64 * 48) |i| {
                rgba[i * 4] = @truncate(i * 3);
                rgba[i * 4 + 1] = @truncate(i * 7);
                rgba[i * 4 + 2] = @truncate(i * 11);
                rgba[i * 4 + 3] = 255;
            }
            if (c.stbi_write_png(&pic_z, 64, 48, 4, &rgba, 64 * 4) == 0) fail("write pic.png");

            const codec_specs = [_][]const u8{ "png", imagecodec.capabilities() };
            for (codec_specs) |codecs| {
                if (codecs.len == 0) continue;
                const pj = fs.startPreviewCodecs(pic, codecs) catch failErr("start image preview", fs.lastErr());
                var sidecar_buf: [4096]u8 = undefined;
                var sidecar_len: usize = 0;
                var pdone = false;
                var pwaited: usize = 0;
                while (!pdone and pwaited < 20_000) {
                    while (fs.takeJobEvent()) |e0| {
                        var e = e0;
                        defer e.deinit();
                        if (e.job != pj) continue;
                        if (std.mem.eql(u8, e.ev, "done")) {
                            if (e.path.len == 0 or std.mem.eql(u8, e.path, pic)) fail("image preview did not produce a sidecar");
                            sidecar_len = e.path.len;
                            @memcpy(sidecar_buf[0..sidecar_len], e.path);
                            pdone = true;
                        } else if (e.terminal()) fail("image preview job failed");
                    }
                    if (!pdone) _ = c.usleep(5_000);
                    pwaited += 5;
                }
                if (!pdone) fail("image preview never completed");
                const sidecar = sidecar_buf[0..sidecar_len];
                const want_png = std.mem.eql(u8, codecs, "png");
                if (want_png and !std.mem.endsWith(u8, sidecar, ".png")) fail("png receiver got a transcoded sidecar");
                if (!want_png and std.mem.endsWith(u8, sidecar, ".png")) fail("codec receiver got a PNG sidecar");
                var bytes: std.ArrayList(u8) = .empty;
                defer bytes.deinit(allocator);
                const info = fs.read(sidecar, 0, 2 << 20, &bytes) catch failErr("read sidecar", fs.lastErr());
                if (!info.eof or bytes.items.len == 0) fail("sidecar read incomplete");
                if (!want_png) {
                    const dec = imagecodec.decode(allocator, bytes.items, 512 * 512) catch fail("sidecar not decodable");
                    allocator.free(dec.rgba);
                    if (dec.width != 64 or dec.height != 48) fail("sidecar dimensions wrong");
                }
                fs.unlink(sidecar) catch failErr("unlink sidecar", fs.lastErr());
                var side_z: [4096:0]u8 = undefined;
                _ = std.fmt.bufPrintZ(&side_z, "{s}", .{sidecar}) catch unreachable;
                if (c.access(&side_z, c.F_OK) == 0) fail("sidecar survived its release");
            }
        }

        // dir_size walks host-side: bytes in `done`, entries in `total`.
        const size_job = fs.startDirSize(sdir) catch failErr("start dir_size", fs.lastErr());
        var size_done = false;
        var size_bytes: u64 = 0;
        var size_entries: u64 = 0;
        waited = 0;
        while (!size_done and waited < 20_000) {
            while (fs.takeJobEvent()) |e0| {
                var e = e0;
                defer e.deinit();
                if (e.job != size_job) continue;
                if (std.mem.eql(u8, e.ev, "done")) {
                    size_bytes = e.done;
                    size_entries = e.total;
                    size_done = true;
                } else if (e.terminal()) fail("dir_size job failed");
            }
            if (!size_done) _ = c.usleep(5_000);
            waited += 5;
        }
        if (!size_done) fail("dir_size never completed");
        if (size_bytes == 0 or size_entries < 3) fail("dir_size totals wrong");

        // perm_tree applies recursively and never follows symlinks.
        const perm_job = fs.startPermTree(sdir, 0o700, null, null) catch failErr("start perm_tree", fs.lastErr());
        var perm_done = false;
        waited = 0;
        while (!perm_done and waited < 20_000) {
            while (fs.takeJobEvent()) |e0| {
                var e = e0;
                defer e.deinit();
                if (e.job != perm_job) continue;
                if (std.mem.eql(u8, e.ev, "done")) perm_done = true else if (e.terminal()) fail("perm_tree job failed");
            }
            if (!perm_done) _ = c.usleep(5_000);
            waited += 5;
        }
        if (!perm_done) fail("perm_tree never completed");
        var pst: c.struct_stat = undefined;
        var pz: [4096]u8 = undefined;
        const deep = std.fmt.bufPrint(&fp3, "{s}/deep", .{sdir}) catch unreachable;
        if (c.stat(pathz.pathZ(&pz, deep) catch unreachable, &pst) != 0) fail("perm_tree stat");
        if (pst.st_mode & 0o7777 != 0o700) fail("perm_tree did not reach the subdirectory");
    }

    // ── extended attributes: set, list, and per-entry columns ──
    {
        touch(dir, "attrs.txt", "attributed\n");
        const target = std.fmt.bufPrint(&pb[3], "{s}/attrs.txt", .{dir}) catch unreachable;
        fs.attrSet(target, "user.sketerm.comment", "hello metadata") catch
            failErr("attr_set", fs.lastErr());
        fs.attrSet(target, "user.xdg.origin.url", "https://example.invalid/x") catch
            failErr("attr_set origin", fs.lastErr());
        // Namespaces outside user.* are refused: the browser must not
        // become a path to editing security attributes.
        if (fs.attrSet(target, "security.selinux", "x")) |_| {
            fail("attr_set accepted a non-user namespace");
        } else |_| {}

        var listing = fs.listAttrs(dir, "user.sketerm.comment,user.xdg.origin.url") catch
            failErr("list with attrs", fs.lastErr());
        defer listing.deinit();
        var seen = false;
        for (listing.entries) |e| {
            if (!std.mem.eql(u8, e.name, "attrs.txt")) continue;
            seen = true;
            if (e.attrs.len != 2) fail("entry attrs count");
            if (!std.mem.eql(u8, e.attrs[0], "hello metadata")) fail("comment attr value");
            if (!std.mem.eql(u8, e.attrs[1], "https://example.invalid/x")) fail("origin attr value");
        }
        if (!seen) fail("attributed entry missing from listing");

        // Clearing removes the attribute rather than storing "".
        fs.attrSet(target, "user.sketerm.comment", "") catch failErr("attr clear", fs.lastErr());
        var after = fs.listAttrs(dir, "user.sketerm.comment") catch failErr("list after clear", fs.lastErr());
        defer after.deinit();
        for (after.entries) |e| {
            if (!std.mem.eql(u8, e.name, "attrs.txt")) continue;
            if (e.attrs.len != 1 or e.attrs[0].len != 0) fail("cleared attribute still present");
        }
    }

    // ── jobs survive their client (durability) ─────────────────
    var orphan_job: u64 = 0;
    {
        const fifo2 = std.fmt.bufPrint(pb[4][2048..], "{s}/pipe2.src", .{dir}) catch unreachable;
        var z: [4096]u8 = undefined;
        if (c.mkfifo(pathz.pathZ(&z, fifo2) catch unreachable, 0o600) != 0) fail("mkfifo2");
        const fdst2 = std.fmt.bufPrint(pb[5][2048..], "{s}/pipe2.copy", .{dir}) catch unreachable;
        var fs2 = fsdrive.Fs.connect(allocator, sock_path) catch fail("fs2 job connect");
        orphan_job = fs2.startCopy(fifo2, fdst2, false) catch failErr("orphan start", fs2.lastErr());
        fs2.deinit(); // owner dies; the job must keep running
    }
    {
        // Another client sees it running, cancels it, sees canceled.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var found_running = false;
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            const rows = fs.jobList(arena.allocator()) catch failErr("job_list", fs.lastErr());
            for (rows) |row| {
                if (row.job == orphan_job and std.mem.eql(u8, row.state, "running")) found_running = true;
            }
            if (found_running) break;
            _ = c.usleep(10_000);
        }
        if (!found_running) fail("orphaned job not listed as running");
        fs.jobCancel(orphan_job) catch failErr("orphan cancel", fs.lastErr());
        var canceled = false;
        tries = 0;
        while (tries < 100 and !canceled) : (tries += 1) {
            const rows = fs.jobList(arena.allocator()) catch failErr("job_list 2", fs.lastErr());
            for (rows) |row| {
                if (row.job == orphan_job and std.mem.eql(u8, row.state, "canceled")) canceled = true;
            }
            if (!canceled) _ = c.usleep(10_000);
        }
        if (!canceled) fail("orphaned job never canceled");
    }

    std.debug.print("smoke-fs: {s} job stage ok\n", .{tag});
}

// ── copy policy, link verbs and progress detail ─────────────────

fn readSmall(path: []const u8, buf: []u8) []const u8 {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch fail("read path");
    const f = c.fopen(p, "rb") orelse return "";
    defer _ = c.fclose(f);
    return buf[0..c.fread(buf.ptr, 1, buf.len, f)];
}

fn exists(path: []const u8) bool {
    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    return c.lstat(pathz.pathZ(&z, path) catch return false, &st) == 0;
}

fn inodeOf(path: []const u8) u64 {
    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    if (c.lstat(pathz.pathZ(&z, path) catch fail("inode path"), &st) != 0) fail("inode stat");
    return @intCast(st.st_ino);
}

fn mkdirAt(path: []const u8) void {
    var z: [4096]u8 = undefined;
    _ = c.mkdir(pathz.pathZ(&z, path) catch fail("mkdir path"), 0o755);
}

fn expectText(path: []const u8, want: []const u8, comptime what: []const u8) void {
    var buf: [256]u8 = undefined;
    const got = readSmall(path, &buf);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("smoke-fs: {s}: {s} = \"{s}\", expected \"{s}\"\n", .{ what, path, got, want });
        fail(what);
    }
}

/// Build `<root>/tree` (source) and `<root>/dest/tree` (a destination
/// that already holds a colliding file plus one of its own).
fn seedMergeCase(root: []const u8, pb: *[6][4096]u8) void {
    const src = std.fmt.bufPrint(&pb[0], "{s}/tree", .{root}) catch unreachable;
    const dest_parent = std.fmt.bufPrint(&pb[1], "{s}/dest", .{root}) catch unreachable;
    const dst = std.fmt.bufPrint(&pb[2], "{s}/dest/tree", .{root}) catch unreachable;
    var scratch: [4096]u8 = undefined;
    mkdirAt(src);
    mkdirAt(std.fmt.bufPrint(&scratch, "{s}/sub", .{src}) catch unreachable);
    touch(src, "shared.txt", "NEW");
    var subdir: [4096]u8 = undefined;
    const sub = std.fmt.bufPrint(&subdir, "{s}/sub", .{src}) catch unreachable;
    touch(sub, "leaf.txt", "LEAF");
    mkdirAt(dest_parent);
    mkdirAt(dst);
    touch(dst, "shared.txt", "OLD");
    touch(dst, "only-here.txt", "KEEP");
}

/// Drop and rebuild the destination side of the merge case.
fn resetMergeDest(fs: *fsdrive.Fs, root: []const u8) void {
    var pb: [2][4096]u8 = undefined;
    const dst = std.fmt.bufPrint(&pb[0], "{s}/dest/tree", .{root}) catch unreachable;
    if (exists(dst)) {
        const job = fs.startDeleteTree(dst) catch failErr("reset delete", fs.lastErr());
        if (!collectJob(fs, job, 20_000).is("done")) fail("reset delete failed");
    }
    mkdirAt(dst);
    touch(dst, "shared.txt", "OLD");
    touch(dst, "only-here.txt", "KEEP");
}

fn policyStage(allocator: std.mem.Allocator, sock_path: []const u8, comptime tag: []const u8) void {
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf, tag ++ "-pol");
    var fs = fsdrive.Fs.connect(allocator, sock_path) catch fail("policy fs connect");
    defer fs.deinit();

    var pb: [6][4096]u8 = undefined;
    seedMergeCase(dir, &pb);
    const src = std.fmt.bufPrint(&pb[0], "{s}/tree", .{dir}) catch unreachable;
    const dst = std.fmt.bufPrint(&pb[1], "{s}/dest/tree", .{dir}) catch unreachable;
    var scratch: [4][4096]u8 = undefined;
    const dst_shared = std.fmt.bufPrint(&scratch[0], "{s}/shared.txt", .{dst}) catch unreachable;
    const dst_only = std.fmt.bufPrint(&scratch[1], "{s}/only-here.txt", .{dst}) catch unreachable;
    const dst_leaf = std.fmt.bufPrint(&scratch[2], "{s}/sub/leaf.txt", .{dst}) catch unreachable;
    const dst_kept = std.fmt.bufPrint(&scratch[3], "{s}/shared.txt-copy", .{dst}) catch unreachable;

    // A destination observed absent must still be absent at the actual
    // install. Files, links, and directory roots all fail closed.
    {
        var nr: [6][4096]u8 = undefined;
        const file_src = std.fmt.bufPrint(&nr[0], "{s}/nr-file-src", .{dir}) catch unreachable;
        const file_dst = std.fmt.bufPrint(&nr[1], "{s}/nr-file-dst", .{dir}) catch unreachable;
        touch(dir, "nr-file-src", "NEW");
        touch(dir, "nr-file-dst", "OLD");
        const file_job = fs.startCopyMode(file_src, file_dst, .{ .no_replace = true }) catch failErr("no-replace file start", fs.lastErr());
        if (!collectJob(&fs, file_job, 20_000).is("error")) fail("no-replace file collision succeeded");
        expectText(file_dst, "OLD", "no-replace file collision overwrote destination");

        const link_src = std.fmt.bufPrint(&nr[2], "{s}/nr-link-src", .{dir}) catch unreachable;
        const link_dst = std.fmt.bufPrint(&nr[3], "{s}/nr-link-dst", .{dir}) catch unreachable;
        var z: [4096]u8 = undefined;
        if (c.symlink("nr-file-src", pathz.pathZ(&z, link_src) catch unreachable) != 0) fail("no-replace link source");
        touch(dir, "nr-link-dst", "OLD-LINK-DST");
        const link_job = fs.startCopyMode(link_src, link_dst, .{ .no_replace = true }) catch failErr("no-replace link start", fs.lastErr());
        if (!collectJob(&fs, link_job, 20_000).is("error")) fail("no-replace link collision succeeded");
        expectText(link_dst, "OLD-LINK-DST", "no-replace link collision overwrote destination");

        const dir_src = std.fmt.bufPrint(&nr[4], "{s}/nr-dir-src", .{dir}) catch unreachable;
        const dir_dst = std.fmt.bufPrint(&nr[5], "{s}/nr-dir-dst", .{dir}) catch unreachable;
        mkdirAt(dir_src);
        mkdirAt(dir_dst);
        touch(dir_src, "new.txt", "NEW-DIR");
        touch(dir_dst, "old.txt", "OLD-DIR");
        const dir_job = fs.startCopyMode(dir_src, dir_dst, .{ .no_replace = true }) catch failErr("no-replace dir start", fs.lastErr());
        if (!collectJob(&fs, dir_job, 20_000).is("error")) fail("no-replace directory collision succeeded");
        var old_buf: [4096]u8 = undefined;
        expectText(std.fmt.bufPrint(&old_buf, "{s}/old.txt", .{dir_dst}) catch unreachable, "OLD-DIR", "no-replace directory damaged destination");
        if (fs.startCopyMode(dir_src, dir_dst, .{ .dir_mode = "replace", .no_replace = true })) |_| {
            fail("no-replace accepted replace mode");
        } else |_| {}
    }

    // ── merge (default): recurse, overwrite collisions, keep the
    // destination's own entries ────────────────────────────────
    {
        const job = fs.startCopyMode(src, dst, .{}) catch failErr("merge copy", fs.lastErr());
        const out = collectJob(&fs, job, 20_000);
        if (!out.is("done")) fail("merge copy outcome");
        expectText(dst_shared, "NEW", "merge did not overwrite the collision");
        expectText(dst_only, "KEEP", "merge removed a destination-only file");
        expectText(dst_leaf, "LEAF", "merge did not recurse");
        // Two source files, both reported.
        if (out.files_total != 2 or out.files_done != 2) {
            std.debug.print("smoke-fs: merge files {d}/{d}\n", .{ out.files_done, out.files_total });
            fail("merge entry counters");
        }
    }

    // ── progress detail on a tree big enough to stream: distinct
    // in-flight paths, and a byte counter that only ever grows
    // (it used to restart at zero on every file) ────────────────
    {
        var bb: [2][4096]u8 = undefined;
        const bsrc = std.fmt.bufPrint(&bb[0], "{s}/bigtree", .{dir}) catch unreachable;
        const bdst = std.fmt.bufPrint(&bb[1], "{s}/bigtree.copy", .{dir}) catch unreachable;
        mkdirAt(bsrc);
        var fp: [4096]u8 = undefined;
        writePattern(std.fmt.bufPrint(&fp, "{s}/one.bin", .{bsrc}) catch unreachable, 6 << 20, 9);
        writePattern(std.fmt.bufPrint(&fp, "{s}/two.bin", .{bsrc}) catch unreachable, 6 << 20, 13);
        const job = fs.startCopy(bsrc, bdst, false) catch failErr("bigtree copy", fs.lastErr());
        const out = collectJob(&fs, job, 60_000);
        if (!out.is("done")) fail("bigtree copy outcome");
        if (out.files_named < 2) {
            std.debug.print("smoke-fs: progress named {d} distinct files\n", .{out.files_named});
            fail("tree copy never named a second file");
        }
        if (out.regressed) fail("tree copy progress went backwards");
        if (out.files_done != 2 or out.files_total != 2) fail("bigtree entry counters");
    }

    // ── skip: the colliding file keeps its old content ─────────
    resetMergeDest(&fs, dir);
    {
        const job = fs.startCopyMode(src, dst, .{ .conflict = "skip" }) catch failErr("skip copy", fs.lastErr());
        if (!collectJob(&fs, job, 20_000).is("done")) fail("skip copy outcome");
        expectText(dst_shared, "OLD", "skip overwrote the collision");
        expectText(dst_leaf, "LEAF", "skip did not copy the non-colliding file");
    }

    // ── keep_both: both survive, the new one renamed ───────────
    resetMergeDest(&fs, dir);
    {
        const job = fs.startCopyMode(src, dst, .{ .conflict = "keep_both" }) catch failErr("keep_both copy", fs.lastErr());
        if (!collectJob(&fs, job, 20_000).is("done")) fail("keep_both copy outcome");
        expectText(dst_shared, "OLD", "keep_both overwrote the collision");
        expectText(dst_kept, "NEW", "keep_both did not write the renamed copy");
    }

    // ── replace: the destination tree is gone first, so entries
    // that existed only there do NOT survive ───────────────────
    resetMergeDest(&fs, dir);
    {
        const job = fs.startCopyMode(src, dst, .{ .dir_mode = "replace" }) catch failErr("replace copy", fs.lastErr());
        if (!collectJob(&fs, job, 20_000).is("done")) fail("replace copy outcome");
        expectText(dst_shared, "NEW", "replace did not write the source file");
        if (exists(dst_only)) fail("replace kept a destination-only file");
        expectText(dst_leaf, "LEAF", "replace did not recurse");
    }

    // ── delete_tree: pre-counted entries and named files ────────
    {
        var vb: [4096]u8 = undefined;
        const victim = std.fmt.bufPrint(&vb, "{s}/victim", .{dir}) catch unreachable;
        mkdirAt(victim);
        var sb: [4096]u8 = undefined;
        const vsub = std.fmt.bufPrint(&sb, "{s}/sub", .{victim}) catch unreachable;
        mkdirAt(vsub);
        touch(victim, "one.txt", "1");
        touch(vsub, "two.txt", "2");
        const job = fs.startDeleteTree(victim) catch failErr("delete progress", fs.lastErr());
        const out = collectJob(&fs, job, 20_000);
        if (!out.is("done")) fail("delete_tree outcome");
        // 2 files + 2 directories.
        if (out.files_done != 4) {
            std.debug.print("smoke-fs: delete counted {d} entries\n", .{out.files_done});
            fail("delete_tree entry count");
        }
        if (exists(victim)) fail("delete_tree left the tree");
    }

    // ── resume reports its offset while STILL RUNNING ──────────
    {
        var rb: [2][4096]u8 = undefined;
        const big = std.fmt.bufPrint(&rb[0], "{s}/big.bin", .{dir}) catch unreachable;
        const rdst = std.fmt.bufPrint(&rb[1], "{s}/big.resumed", .{dir}) catch unreachable;
        writePattern(big, 6 << 20, 5);
        var partb: [4096]u8 = undefined;
        const part = std.fmt.bufPrint(&partb, "{s}.skpart", .{rdst}) catch unreachable;
        {
            var zs: [4096]u8 = undefined;
            var zd: [4096]u8 = undefined;
            const sf = c.fopen(pathz.pathZ(&zs, big) catch unreachable, "rb") orelse fail("resume src");
            const df = c.fopen(pathz.pathZ(&zd, part) catch unreachable, "wb") orelse fail("resume part");
            var buf: [65536]u8 = undefined;
            var left: usize = 2 << 20;
            while (left > 0) {
                const n = c.fread(&buf, 1, @min(buf.len, left), sf);
                if (n == 0) break;
                _ = c.fwrite(&buf, 1, n, df);
                left -= n;
            }
            _ = c.fclose(sf);
            _ = c.fclose(df);
        }
        const job = fs.startCopy(big, rdst, true) catch failErr("resume copy", fs.lastErr());
        const out = collectJob(&fs, job, 20_000);
        if (!out.is("done")) fail("resume copy outcome");
        if (out.resumed_from != (2 << 20)) fail("resume offset wrong");
        if (!out.resumed_while_running) fail("resumed_from never appeared on a running progress line");
        if (out.namedFile().len == 0) fail("single-file copy never named its file");
    }

    // ── hardlink: same inode, refused across kinds it cannot serve
    {
        var hb: [3][4096]u8 = undefined;
        const target = std.fmt.bufPrint(&hb[0], "{s}/link-target.txt", .{dir}) catch unreachable;
        const link = std.fmt.bufPrint(&hb[1], "{s}/dest/link-here.txt", .{dir}) catch unreachable;
        const bad = std.fmt.bufPrint(&hb[2], "{s}/dest/dir-link", .{dir}) catch unreachable;
        touch(dir, "link-target.txt", "shared bytes");
        fs.hardlink(target, link) catch failErr("hardlink", fs.lastErr());
        if (inodeOf(target) != inodeOf(link)) fail("hard link is not the same inode");
        expectText(link, "shared bytes", "hard link content");
        // A directory can never be hard linked: refused by name, not
        // by a bare errno leaking through.
        if (fs.hardlink(src, bad)) |_| {
            fail("hard link of a directory succeeded");
        } else |err| {
            if (err != fsdrive.Error.FsOpFailed) fail("directory hardlink error kind");
            if (std.mem.indexOf(u8, fs.lastErr(), "directory") == null)
                failErr("directory hardlink message", fs.lastErr());
        }
    }

    // ── listings carry the directory's device id (the hard-link
    // pre-check the browser needs) ─────────────────────────────
    {
        var listing = fs.list(dir) catch failErr("dev listing", fs.lastErr());
        defer listing.deinit();
        if (listing.dev == 0) fail("listing carried no device id");
        var dest_listing = fs.list(std.fmt.bufPrint(&scratch[0], "{s}/dest", .{dir}) catch unreachable) catch
            failErr("dev listing 2", fs.lastErr());
        defer dest_listing.deinit();
        if (dest_listing.dev != listing.dev) fail("sibling directories reported different devices");
    }

    // ── the host resolves its own template directory ───────────
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const dirs = fs.hostDirs(arena.allocator()) catch failErr("hostDirs", fs.lastErr());
        if (dirs.home.len == 0) fail("homedir reply had no home");
        if (dirs.templates.len == 0) fail("homedir reply had no templates directory");
        if (!std.mem.startsWith(u8, dirs.templates, "/")) fail("templates path not absolute");
    }

    std.debug.print("smoke-fs: {s} policy stage ok\n", .{tag});
}

// ── cross-daemon (client-mediated) transfer stage ──────────────

// ── batched media metadata ──────────────────────────────────────

/// A 33-byte PNG header: everything mediameta reads for dimensions.
fn writePng(path: []const u8, w: u32, h: u32) void {
    var buf: [33]u8 = undefined;
    @memcpy(buf[0..8], "\x89PNG\r\n\x1a\x0a");
    std.mem.writeInt(u32, buf[8..12], 13, .big);
    @memcpy(buf[12..16], "IHDR");
    std.mem.writeInt(u32, buf[16..20], w, .big);
    std.mem.writeInt(u32, buf[20..24], h, .big);
    buf[24] = 8; // bit depth
    buf[25] = 6; // colour type
    buf[26] = 0;
    buf[27] = 0;
    buf[28] = 0;
    std.mem.writeInt(u32, buf[29..33], 0, .big); // crc (never validated)
    writeFile(path, &buf);
}

/// 8-bit mono PCM at 8 kHz: `data_bytes` of payload is exactly
/// data_bytes/8 milliseconds.
fn writeWav(path: []const u8, data_bytes: u32) void {
    var buf: [44]u8 = undefined;
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_bytes, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buf[22..24], 1, .little); // mono
    std.mem.writeInt(u32, buf[24..28], 8000, .little); // sample rate
    std.mem.writeInt(u32, buf[28..32], 8000, .little); // byte rate
    std.mem.writeInt(u16, buf[32..34], 1, .little); // block align
    std.mem.writeInt(u16, buf[34..36], 8, .little); // bits
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_bytes, .little);
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch fail("media wav path");
    const f = c.fopen(p, "wb") orelse fail("media wav open");
    defer _ = c.fclose(f);
    if (c.fwrite(&buf, 1, buf.len, f) != buf.len) fail("media wav header");
    var silence: [1024]u8 = @splat(0x80);
    var left: usize = data_bytes;
    while (left > 0) {
        const n = @min(left, silence.len);
        if (c.fwrite(&silence, 1, n, f) != n) fail("media wav data");
        left -= n;
    }
}

/// 20 constant-bitrate MPEG1 Layer III frames plus an ID3v1 trailer.
fn writeMp3(path: []const u8) void {
    const FRAME_LEN = 417; // 128 kbps, 44.1 kHz, no padding
    var body: [20 * FRAME_LEN + 128]u8 = @splat(0);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        @memcpy(body[i * FRAME_LEN ..][0..4], &[_]u8{ 0xFF, 0xFB, 0x90, 0x00 });
    }
    const tag = body[20 * FRAME_LEN ..];
    @memcpy(tag[0..3], "TAG");
    @memcpy(tag[3..][0.."Smoke Title".len], "Smoke Title");
    @memcpy(tag[33..][0.."Smoke Artist".len], "Smoke Artist");
    @memcpy(tag[93..97], "1998");
    tag[127] = 17; // Rock
    writeFile(path, &body);
}

fn writeFile(path: []const u8, bytes: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch fail("media path");
    const f = c.fopen(p, "wb") orelse fail("media open");
    defer _ = c.fclose(f);
    if (c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) fail("media write");
}

/// Pin a file's mtime so cache invalidation is tested deterministically
/// rather than at the mercy of timestamp granularity.
fn setMtime(path: []const u8, secs: i64) void {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch fail("media mtime path");
    const times = [2]c.struct_timespec{
        .{ .tv_sec = @intCast(secs), .tv_nsec = 0 },
        .{ .tv_sec = @intCast(secs), .tv_nsec = 0 },
    };
    if (c.utimensat(c.AT_FDCWD, p, &times, 0) != 0) fail("media utimensat");
}

fn mediaField(r: fsdrive.MediaResult, key: []const u8) []const u8 {
    return r.get(key) orelse {
        std.debug.print("smoke-fs: media result {s} has no {s}\n", .{ r.path, key });
        fail("media field missing");
    };
}

fn mediaFind(rows: []fsdrive.MediaResult, name: []const u8) fsdrive.MediaResult {
    for (rows) |r| {
        if (std.mem.endsWith(u8, r.path, name)) return r;
    }
    std.debug.print("smoke-fs: no media result for {s}\n", .{name});
    fail("media result missing");
}

fn expectMedia(r: fsdrive.MediaResult, key: []const u8, want: []const u8) void {
    const got = mediaField(r, key);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("smoke-fs: {s} {s} = \"{s}\", expected \"{s}\"\n", .{ r.path, key, got, want });
        fail("media value mismatch");
    }
}

/// Batched, cached, host-side media metadata: one request covers many
/// files, the second request is served from the daemon-host cache, and
/// a modified file invalidates only its own entry.
fn mediaStage(allocator: std.mem.Allocator, sock_path: []const u8, comptime tag: []const u8) void {
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf, tag ++ "-media");
    var fs = fsdrive.Fs.connect(allocator, sock_path) catch fail("media fs connect");
    defer fs.deinit();

    var pb: [4][4096]u8 = undefined;
    const png = std.fmt.bufPrint(&pb[0], "{s}/shot.png", .{dir}) catch unreachable;
    const wav = std.fmt.bufPrint(&pb[1], "{s}/tone.wav", .{dir}) catch unreachable;
    const mp3 = std.fmt.bufPrint(&pb[2], "{s}/song.mp3", .{dir}) catch unreachable;
    const txt = std.fmt.bufPrint(&pb[3], "{s}/notes.txt", .{dir}) catch unreachable;
    writePng(png, 300, 150);
    writeWav(wav, 4000); // 500 ms
    writeMp3(mp3);
    touch(dir, "notes.txt", "plain text, not media\n");
    setMtime(png, 1_700_000_000);
    _ = txt;

    const names = [_][]const u8{ "shot.png", "tone.wav", "song.mp3", "notes.txt", "missing.jpg" };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const first = fs.mediaMeta(arena.allocator(), dir, &names, 20_000) catch
        failErr("media batch", fs.lastErr());
    // One reply covers every requested row, never one round trip per row.
    if (first.len != names.len) fail("media batch dropped rows");
    for (first) |r| {
        if (r.cached) fail("first media batch was served from cache");
    }

    const png_row = mediaFind(first, "shot.png");
    expectMedia(png_row, "media.kind", "image");
    expectMedia(png_row, "media.format", "png");
    expectMedia(png_row, "media.width", "300");
    expectMedia(png_row, "media.height", "150");
    expectMedia(png_row, "media.bit_depth", "8");

    const wav_row = mediaFind(first, "tone.wav");
    expectMedia(wav_row, "media.kind", "audio");
    expectMedia(wav_row, "media.sample_rate", "8000");
    expectMedia(wav_row, "media.channels", "1");
    expectMedia(wav_row, "media.duration_ms", "500");

    const mp3_row = mediaFind(first, "song.mp3");
    expectMedia(mp3_row, "media.kind", "audio");
    expectMedia(mp3_row, "tag.title", "Smoke Title");
    expectMedia(mp3_row, "tag.artist", "Smoke Artist");
    expectMedia(mp3_row, "tag.year", "1998");
    expectMedia(mp3_row, "tag.genre", "Rock");
    expectMedia(mp3_row, "media.bitrate_kbps", "128");
    // Derived from the bitrate, and labelled as derived.
    expectMedia(mp3_row, "media.duration_estimated", "1");

    // A non-media file is answered, not skipped silently: the caller
    // learns the row was examined and has nothing to show.
    const txt_row = mediaFind(first, "notes.txt");
    if (!std.mem.eql(u8, txt_row.kind, "unknown") or txt_row.fields.len != 0)
        fail("non-media file reported metadata");
    const gone_row = mediaFind(first, "missing.jpg");
    if (gone_row.note.len == 0) fail("missing file carried no note");

    // ── second request: same values, served from the cache ─────
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const second = fs.mediaMeta(arena2.allocator(), dir, &names, 20_000) catch
        failErr("media batch (cached)", fs.lastErr());
    if (second.len != names.len) fail("cached media batch dropped rows");
    for ([_][]const u8{ "shot.png", "tone.wav", "song.mp3" }) |name| {
        const row = mediaFind(second, name);
        if (!row.cached) {
            std.debug.print("smoke-fs: {s} was re-extracted instead of cached\n", .{name});
            fail("media cache miss on repeat");
        }
        const before = mediaFind(first, name);
        if (row.fields.len != before.fields.len) fail("cached media differs from extracted");
        for (before.fields) |f| expectMedia(row, f.k, f.v);
    }

    // ── modification invalidates only that file's entry ────────
    writePng(png, 640, 400);
    setMtime(png, 1_700_000_099);
    var arena3 = std.heap.ArenaAllocator.init(allocator);
    defer arena3.deinit();
    const third = fs.mediaMeta(arena3.allocator(), dir, &names, 20_000) catch
        failErr("media batch (invalidated)", fs.lastErr());
    const png_again = mediaFind(third, "shot.png");
    if (png_again.cached) fail("modified file was served from a stale cache entry");
    expectMedia(png_again, "media.width", "640");
    expectMedia(png_again, "media.height", "400");
    if (!mediaFind(third, "song.mp3").cached) fail("untouched file lost its cache entry");

    // The batch cap is enforced daemon-side rather than truncating
    // silently at some layer in between.
    var big: [fsdrive.MEDIA_BATCH_MAX + 1][]const u8 = undefined;
    for (&big) |*slot| slot.* = "shot.png";
    if (fs.startMediaMeta(dir, &big)) |_| {
        fail("oversized media batch was accepted");
    } else |err| {
        if (err != fsdrive.Error.BadRequest) fail("oversized media batch gave the wrong error");
    }
    std.debug.print("smoke-fs: {s} media stage ok\n", .{tag});
}

/// The row set a live query is currently streaming, rebuilt from its
/// match/unmatch events exactly the way the browser rebuilds its flat
/// listing -- so what this asserts is what a user would see.
const LiveRows = struct {
    allocator: std.mem.Allocator,
    job: u64,
    paths: std.ArrayList([]u8) = .empty,
    /// Latest `ready` status event.
    ready: bool = false,
    watches: u64 = 0,
    matches: u64 = 0,
    truncated: bool = false,
    watch_limit: bool = false,

    fn deinit(self: *LiveRows) void {
        for (self.paths.items) |p| self.allocator.free(p);
        self.paths.deinit(self.allocator);
    }

    fn has(self: *const LiveRows, path: []const u8) bool {
        for (self.paths.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    fn apply(self: *LiveRows, e: fsdrive.JobEvent) void {
        if (std.mem.eql(u8, e.ev, "match")) {
            if (self.has(e.path)) return;
            const owned = self.allocator.dupe(u8, e.path) catch return;
            self.paths.append(self.allocator, owned) catch self.allocator.free(owned);
            return;
        }
        if (std.mem.eql(u8, e.ev, "unmatch")) {
            var i: usize = 0;
            while (i < self.paths.items.len) {
                if (std.mem.eql(u8, self.paths.items[i], e.path)) {
                    self.allocator.free(self.paths.items[i]);
                    _ = self.paths.orderedRemove(i);
                } else i += 1;
            }
            return;
        }
        if (std.mem.eql(u8, e.ev, "ready")) {
            self.ready = true;
            self.watches = e.watches;
            self.matches = e.matches;
            self.truncated = e.truncated;
            self.watch_limit = e.watch_limit;
        }
    }

    /// Drain events until `want` holds or the deadline passes.
    /// @return whether it held.
    fn until(self: *LiveRows, fs: *fsdrive.Fs, timeout_ms: i64, want: *const fn (*const LiveRows) bool) bool {
        var waited: i64 = 0;
        while (true) {
            while (fs.takeJobEvent()) |e0| {
                var e = e0;
                defer e.deinit();
                if (e.job != self.job) continue;
                self.apply(e);
            }
            if (want(self)) return true;
            if (waited >= timeout_ms) return false;
            _ = c.usleep(10_000);
            waited += 10;
        }
    }
};

fn expectLive(rows: *LiveRows, fs: *fsdrive.Fs, want: *const fn (*const LiveRows) bool, comptime what: []const u8) void {
    if (!rows.until(fs, 8_000, want)) {
        std.debug.print("smoke-fs: live query never reached: {s} (rows now:", .{what});
        for (rows.paths.items) |p| std.debug.print(" {s}", .{p});
        std.debug.print(")\n", .{});
        fail("live query state never reached: " ++ what);
    }
}

/// Live queries and panels: the streamed contract the browser's query
/// tabs are built on. Everything here is host-side behaviour, so it is
/// asserted with no GUI at all.
fn queryStage(allocator: std.mem.Allocator, sock_path: []const u8, comptime tag: []const u8) void {
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf, tag ++ "-query");
    var fs = fsdrive.Fs.connect(allocator, sock_path) catch fail("query fs connect");
    defer fs.deinit();

    var pb: [8][4096]u8 = undefined;
    const sub = std.fmt.bufPrint(&pb[0], "{s}/sub", .{dir}) catch unreachable;
    mkdirAt(sub);
    touch(dir, "alpha.txt", "a\n");
    touch(sub, "beta.txt", "b\n");
    touch(dir, "ignore.log", "l\n");
    const alpha = std.fmt.bufPrint(&pb[1], "{s}/alpha.txt", .{dir}) catch unreachable;
    const beta = std.fmt.bufPrint(&pb[2], "{s}/sub/beta.txt", .{dir}) catch unreachable;
    const gamma = std.fmt.bufPrint(&pb[3], "{s}/gamma.txt", .{dir}) catch unreachable;
    const moved = std.fmt.bufPrint(&pb[4], "{s}/moved-away", .{dir}) catch unreachable;

    // ── live filename query ────────────────────────────────────
    const job = fs.startLiveFind(dir, "*.txt") catch failErr("start live_find", fs.lastErr());
    var rows = LiveRows{ .allocator = allocator, .job = job };
    defer rows.deinit();

    const Want = struct {
        var path: []const u8 = "";
        fn ready(r: *const LiveRows) bool {
            return r.ready;
        }
        fn present(r: *const LiveRows) bool {
            return r.has(path);
        }
        fn absent(r: *const LiveRows) bool {
            return !r.has(path);
        }
        fn empty(r: *const LiveRows) bool {
            return r.paths.items.len == 0;
        }
    };

    expectLive(&rows, &fs, Want.ready, "initial scan complete");
    // The status event reports its own bounds: two directories watched
    // (the root and sub), two rows, neither cap hit.
    if (rows.watches != 2) fail("live query reported the wrong watch count");
    if (rows.truncated or rows.watch_limit) fail("live query claimed a bound it never hit");
    if (!rows.has(alpha) or !rows.has(beta)) fail("live query missed an initial match");
    if (rows.has(std.fmt.bufPrint(&pb[5], "{s}/ignore.log", .{dir}) catch unreachable))
        fail("live query matched a non-matching name");

    // A file created externally appears with no request from anyone.
    touch(dir, "gamma.txt", "g\n");
    Want.path = gamma;
    expectLive(&rows, &fs, Want.present, "externally created file appears");

    // ...and a deleted one leaves.
    var z: [4096]u8 = undefined;
    _ = c.unlink(pathz.pathZ(&z, alpha) catch unreachable);
    Want.path = alpha;
    expectLive(&rows, &fs, Want.absent, "deleted file disappears");

    // A whole directory MOVED out of the tree delivers no per-child
    // event; its rows have to go anyway (this regressed once).
    if (c.rename(
        pathz.pathZ(&z, sub) catch unreachable,
        pathz.pathZ(&pb[6], moved) catch unreachable,
    ) != 0) fail("rename subdir");
    Want.path = beta;
    expectLive(&rows, &fs, Want.absent, "rows under a moved-away directory disappear");

    fs.jobCancel(job) catch failErr("cancel live_find", fs.lastErr());

    // ── relative-time predicate that keeps being re-evaluated ──
    var tdir_buf: [64]u8 = undefined;
    const tdir = mkTmpDir(&tdir_buf, tag ++ "-age");
    const fresh = std.fmt.bufPrint(&pb[0], "{s}/fresh.txt", .{tdir}) catch unreachable;
    const old = std.fmt.bufPrint(&pb[1], "{s}/old.txt", .{tdir}) catch unreachable;
    const later = std.fmt.bufPrint(&pb[2], "{s}/later.txt", .{tdir}) catch unreachable;
    touch(tdir, "fresh.txt", "f\n");
    touch(tdir, "old.txt", "o\n");
    // Aged with a backdated mtime rather than by waiting: the daemon
    // compares mtimes, so this is the same code path as real ageing.
    setMtime(old, @as(i64, c.time(null)) - 7200);

    const tjob = fs.startLiveFindOpts(tdir, "*.txt", .{ .within_ms = 3000 }) catch
        failErr("start timed live_find", fs.lastErr());
    var trows = LiveRows{ .allocator = allocator, .job = tjob };
    defer trows.deinit();
    expectLive(&trows, &fs, Want.ready, "timed query initial scan");
    if (!trows.has(fresh)) fail("timed query dropped a file inside its window");
    if (trows.has(old)) fail("timed query matched a file outside its window");

    // A file created inside the window matches...
    touch(tdir, "later.txt", "l\n");
    Want.path = later;
    expectLive(&trows, &fs, Want.present, "new file inside the time window matches");
    // ...and stops matching the moment its mtime is pushed out of it.
    setMtime(later, @as(i64, c.time(null)) - 3600);
    expectLive(&trows, &fs, Want.absent, "backdated file leaves the time window");
    // ...and everything left ages out on its own deadline, with no
    // filesystem event and nothing asked of the client.
    expectLive(&trows, &fs, Want.empty, "matches age out on their own deadline");
    fs.jobCancel(tjob) catch failErr("cancel timed live_find", fs.lastErr());

    // ── panelize: rows, rejects and the command's exit status ──
    var cmd_buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrint(
        &cmd_buf,
        "echo gamma.txt; echo 'fatal: not a git repository'; echo {s}; echo nope.txt; exit 3",
        .{gamma},
    ) catch unreachable;
    const pjob = fs.startPanelize(dir, cmd) catch failErr("start panelize", fs.lastErr());
    var reject_texts: usize = 0;
    var pdone = false;
    var prows: usize = 0;
    var prejected: u64 = 0;
    var pexit: i64 = 0;
    var waited: i64 = 0;
    while (!pdone and waited < 10_000) {
        while (fs.takeJobEvent()) |e0| {
            var e = e0;
            defer e.deinit();
            if (e.job != pjob) continue;
            if (std.mem.eql(u8, e.ev, "match")) prows += 1;
            if (std.mem.eql(u8, e.ev, "reject")) {
                reject_texts += 1;
                if (e.text.len == 0) fail("panelize reject carried no text");
            }
            if (e.terminal()) {
                if (!std.mem.eql(u8, e.ev, "done")) fail("panelize did not finish");
                prejected = e.rejected;
                pexit = e.exit_status;
                pdone = true;
            }
        }
        if (pdone) break;
        _ = c.usleep(10_000);
        waited += 10;
    }
    if (!pdone) fail("panelize never finished");
    // Relative and absolute paths both resolve; the diagnostic line
    // and the name of a file that does not exist do not.
    if (prows != 2) fail("panelize resolved the wrong number of rows");
    if (prejected != 2) fail("panelize miscounted unusable output lines");
    if (reject_texts != 2) fail("panelize did not quote back its unusable lines");
    // A nonzero exit is reported, not turned into a failed job: the
    // rows that did arrive are still the listing.
    if (pexit != 3) fail("panelize lost the command's exit status");

    std.debug.print("smoke-fs: {s} query stage ok\n", .{tag});
}

const XferConns = struct {
    src: client_mod.Conn,
    dst: client_mod.Conn,

    fn open(allocator: std.mem.Allocator, src_sock: []const u8, dst_sock: []const u8) XferConns {
        var s = client_mod.Conn.connectProbed(allocator, src_sock) catch fail("xfer src connect");
        s.setNonBlocking();
        var d = client_mod.Conn.connectProbed(allocator, dst_sock) catch fail("xfer dst connect");
        d.setNonBlocking();
        return .{ .src = s, .dst = d };
    }

    fn close(self: *XferConns) void {
        self.src.deinit();
        self.dst.deinit();
    }
};

/// Pump both connections into the Xfer until it terminates, a
/// deadline passes, or `stop_after` bytes of progress accumulate
/// (0 = run to completion). Returns true when the Xfer terminated.
fn pumpXfer(allocator: std.mem.Allocator, x: *fstransfer.Xfer, conns: *XferConns, timeout_ms: i64, stop_after: u64) bool {
    var waited: i64 = 0;
    while (waited < timeout_ms) {
        var pfds = [_]c.struct_pollfd{
            .{ .fd = conns.src.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = conns.dst.fd, .events = c.POLLIN, .revents = 0 },
        };
        _ = c.poll(&pfds, 2, 20);
        waited += 20;
        inline for (.{ .src, .dst }) |side| {
            const conn = if (side == .src) &conns.src else &conns.dst;
            // fstransfer sends only queue; the pump owns the flush.
            conn.flushQueued() catch fail("xfer conn write failed");
            if (!conn.fillAvailable()) fail("xfer conn hangup");
            while (conn.takeFrame() catch null) |f| {
                defer f.deinit(allocator);
                _ = x.feed(side, f.ftype, f.payload);
            }
            conn.flushQueued() catch fail("xfer conn write failed");
        }
        if (x.isTerminal()) return true;
        if (stop_after > 0 and x.progress().done >= stop_after) return false;
    }
    fail("xfer pump timed out");
}

/// Pump for a fixed window without any expectation of progress: what a
/// paused transfer must survive.
fn pumpFor(allocator: std.mem.Allocator, x: *fstransfer.Xfer, conns: *XferConns, ms: i64) void {
    var waited: i64 = 0;
    while (waited < ms) {
        var pfds = [_]c.struct_pollfd{
            .{ .fd = conns.src.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = conns.dst.fd, .events = c.POLLIN, .revents = 0 },
        };
        _ = c.poll(&pfds, 2, 20);
        waited += 20;
        inline for (.{ .src, .dst }) |side| {
            const conn = if (side == .src) &conns.src else &conns.dst;
            // fstransfer sends only queue; the pump owns the flush.
            conn.flushQueued() catch fail("xfer conn write failed");
            if (!conn.fillAvailable()) fail("xfer conn hangup");
            while (conn.takeFrame() catch null) |f| {
                defer f.deinit(allocator);
                _ = x.feed(side, f.ftype, f.payload);
            }
            conn.flushQueued() catch fail("xfer conn write failed");
        }
    }
}

fn stagedSize(fs: *fsdrive.Fs, allocator: std.mem.Allocator, path: []const u8) u64 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const st = fs.statPath(arena.allocator(), path) catch return 0;
    return st.size;
}

fn statExists(fs: *fsdrive.Fs, allocator: std.mem.Allocator, path: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = fs.statPath(arena.allocator(), path) catch return false;
    return true;
}

fn xferStage(allocator: std.mem.Allocator, sock_a: []const u8, sock_b: []const u8) void {
    var dbuf_a: [64]u8 = undefined;
    var dbuf_b: [64]u8 = undefined;
    const dir_a = mkTmpDir(&dbuf_a, "xa");
    const dir_b = mkTmpDir(&dbuf_b, "xb");
    var req: u32 = 1;
    var pb: [8][4096]u8 = undefined;

    // Oracle client on the destination daemon (existence checks).
    var fsb = fsdrive.Fs.connect(allocator, sock_b) catch fail("xfer oracle connect");
    defer fsb.deinit();

    // ── single file A → B, hash-verified end to end ────────────
    const src1 = std.fmt.bufPrint(&pb[0], "{s}/one.bin", .{dir_a}) catch unreachable;
    const dst1 = std.fmt.bufPrint(&pb[1], "{s}/one.copy", .{dir_b}) catch unreachable;
    writePattern(src1, 5 << 20, 11);
    {
        var conns = XferConns.open(allocator, sock_a, sock_b);
        defer conns.close();
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, src1, dst1, false) catch fail("xfer init");
        defer x.deinit();
        x.start();
        if (!pumpXfer(allocator, x, &conns, 30_000, 0)) fail("single xfer never finished");
        if (!x.ok()) failErr("single xfer failed", x.errMsg());
        if (!std.mem.eql(u8, &(fileSha(dst1) orelse fail("dst1 sha")), &(fileSha(src1) orelse fail("src1 sha"))))
            fail("single xfer content mismatch");
        var partp: [4096]u8 = undefined;
        const staged = std.fmt.bufPrint(&partp, "{s}.skpart", .{dst1}) catch unreachable;
        if (statExists(&fsb, allocator, staged)) fail("single xfer left staged partial");
    }

    // The client-mediated fallback applies the same atomic root fence
    // as daemon jobs; a late file or directory must survive unchanged.
    {
        var paths: [5][4096]u8 = undefined;
        const src = std.fmt.bufPrint(&paths[0], "{s}/nr-file", .{dir_a}) catch unreachable;
        const dst = std.fmt.bufPrint(&paths[1], "{s}/nr-file", .{dir_b}) catch unreachable;
        touch(dir_a, "nr-file", "NEW");
        touch(dir_b, "nr-file", "OLD");
        var conns = XferConns.open(allocator, sock_a, sock_b);
        defer conns.close();
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, src, dst, true) catch fail("no-replace xfer init");
        defer x.deinit();
        x.no_replace = true;
        x.start();
        if (!pumpXfer(allocator, x, &conns, 30_000, 0)) fail("no-replace xfer never finished");
        if (x.ok()) fail("no-replace xfer overwrote a late destination");
        expectText(dst, "OLD", "no-replace xfer damaged destination");

        const tree_src = std.fmt.bufPrint(&paths[2], "{s}/nr-tree", .{dir_a}) catch unreachable;
        const tree_dst = std.fmt.bufPrint(&paths[3], "{s}/nr-tree", .{dir_b}) catch unreachable;
        mkdirAt(tree_src);
        mkdirAt(tree_dst);
        touch(tree_src, "new.txt", "NEW-TREE");
        touch(tree_dst, "old.txt", "OLD-TREE");
        const y = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, tree_src, tree_dst, true) catch fail("no-replace tree xfer init");
        defer y.deinit();
        y.no_replace = true;
        y.start();
        if (!pumpXfer(allocator, y, &conns, 30_000, 0)) fail("no-replace tree xfer never finished");
        if (y.ok()) fail("no-replace tree xfer merged a late destination");
        const old = std.fmt.bufPrint(&paths[4], "{s}/old.txt", .{tree_dst}) catch unreachable;
        expectText(old, "OLD-TREE", "no-replace tree xfer damaged destination");
    }

    // A root symlink stays a symlink in the mediated path, including
    // when its target happens to be a directory or file on the source.
    {
        var paths: [2][4096]u8 = undefined;
        const src = std.fmt.bufPrint(&paths[0], "{s}/root-link", .{dir_a}) catch unreachable;
        const dst = std.fmt.bufPrint(&paths[1], "{s}/root-link", .{dir_b}) catch unreachable;
        var z: [4096]u8 = undefined;
        if (c.symlink("one.bin", pathz.pathZ(&z, src) catch unreachable) != 0) fail("root-link xfer source");
        var conns = XferConns.open(allocator, sock_a, sock_b);
        defer conns.close();
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, src, dst, false) catch fail("root-link xfer init");
        defer x.deinit();
        x.no_replace = true;
        x.start();
        if (!pumpXfer(allocator, x, &conns, 30_000, 0) or !x.ok()) failErr("root-link xfer failed", x.errMsg());
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const st = fsb.statPath(arena.allocator(), dst) catch failErr("root-link xfer stat", fsb.lastErr());
        if (!std.mem.eql(u8, st.kind, "link") or !std.mem.eql(u8, st.target orelse "", "one.bin"))
            fail("root-link xfer dereferenced source link");
    }

    // ── induced disconnect mid-transfer, then resume ───────────
    const src2 = std.fmt.bufPrint(&pb[2], "{s}/big.bin", .{dir_a}) catch unreachable;
    const dst2 = std.fmt.bufPrint(&pb[3], "{s}/big.copy", .{dir_b}) catch unreachable;
    writePattern(src2, 12 << 20, 23);
    {
        // First attempt: kill both connections after ~3MB.
        var conns = XferConns.open(allocator, sock_a, sock_b);
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, src2, dst2, true) catch fail("xfer2 init");
        x.start();
        if (pumpXfer(allocator, x, &conns, 30_000, 3 << 20)) fail("xfer2 finished before the induced disconnect");
        x.deinit();
        conns.close(); // abrupt client death; staged partial stays on B
    }
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var partp: [4096]u8 = undefined;
        const staged = std.fmt.bufPrint(&partp, "{s}.skpart", .{dst2}) catch unreachable;
        const st = fsb.statPath(arena.allocator(), staged) catch failErr("no staged partial after disconnect", fsb.lastErr());
        if (st.size == 0) fail("staged partial is empty");
    }
    {
        // Second attempt resumes from the partial (proof: resumed_bytes).
        var conns = XferConns.open(allocator, sock_a, sock_b);
        defer conns.close();
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, src2, dst2, true) catch fail("xfer3 init");
        defer x.deinit();
        x.start();
        if (!pumpXfer(allocator, x, &conns, 60_000, 0)) fail("resume xfer never finished");
        if (!x.ok()) failErr("resume xfer failed", x.errMsg());
        if (x.resumed_bytes == 0) fail("resume xfer did not resume");
        if (!std.mem.eql(u8, &(fileSha(dst2) orelse fail("dst2 sha")), &(fileSha(src2) orelse fail("src2 sha"))))
            fail("resumed xfer content mismatch");
    }

    // ── pause holds the transfer at a chunk boundary; resume in
    // this session, and resume in a FRESH Xfer (what a GUI restart
    // does), both land byte-identical content ──────────────────
    {
        var sb: [4096]u8 = undefined;
        var db: [4096]u8 = undefined;
        var partp: [4096]u8 = undefined;
        const psrc = std.fmt.bufPrint(&sb, "{s}/pause.bin", .{dir_a}) catch unreachable;
        const pdst = std.fmt.bufPrint(&db, "{s}/pause.copy", .{dir_b}) catch unreachable;
        writePattern(psrc, 24 << 20, 53);
        const staged = std.fmt.bufPrint(&partp, "{s}.skpart", .{pdst}) catch unreachable;

        var conns = XferConns.open(allocator, sock_a, sock_b);
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, psrc, pdst, true) catch fail("pause xfer init");
        x.start();
        if (pumpXfer(allocator, x, &conns, 30_000, 2 << 20)) fail("pause xfer finished before the pause");
        x.pause();
        if (!x.isPaused()) fail("pause did not take");
        // One already-requested chunk may still land; after that the
        // transfer must be completely still.
        pumpFor(allocator, x, &conns, 600);
        const held_done = x.progress().done;
        const held_size = stagedSize(&fsb, allocator, staged);
        if (held_size == 0) fail("paused xfer has no staged partial");
        pumpFor(allocator, x, &conns, 1500);
        if (x.progress().done != held_done) fail("paused xfer kept moving bytes");
        if (stagedSize(&fsb, allocator, staged) != held_size) fail("paused xfer kept growing the staged partial");
        if (x.isTerminal()) fail("paused xfer went terminal");

        // A fresh Xfer over fresh connections: the GUI-restart path.
        x.deinit();
        conns.close();
        var conns2 = XferConns.open(allocator, sock_a, sock_b);
        defer conns2.close();
        const y = fstransfer.Xfer.init(allocator, &conns2.src, &conns2.dst, &req, psrc, pdst, true) catch fail("pause resume init");
        defer y.deinit();
        // Restored paused, then released -- the state a restart reads
        // from the ledger record.
        y.pause();
        y.start();
        pumpFor(allocator, y, &conns2, 300);
        if (stagedSize(&fsb, allocator, staged) != held_size) fail("a restored paused xfer moved bytes");
        y.unpause();
        if (!pumpXfer(allocator, y, &conns2, 120_000, 0)) fail("resumed xfer never finished");
        if (!y.ok()) failErr("resumed xfer failed", y.errMsg());
        if (y.resumed_bytes == 0) fail("resumed xfer did not continue from the staged partial");
        if (!std.mem.eql(u8, &(fileSha(pdst) orelse fail("pdst sha")), &(fileSha(psrc) orelse fail("psrc sha"))))
            fail("resumed-after-pause content mismatch");
        if (statExists(&fsb, allocator, staged)) fail("resumed xfer left staged partial");
    }

    // ── corrupted partial: the verify must CATCH the mismatch,
    // delete the corrupt destination, and retry once from zero —
    // the transfer ends CORRECT, never silently corrupt ─────────
    const src3 = std.fmt.bufPrint(&pb[4], "{s}/ver.bin", .{dir_a}) catch unreachable;
    const dst3 = std.fmt.bufPrint(&pb[5], "{s}/ver.copy", .{dir_b}) catch unreachable;
    writePattern(src3, 3 << 20, 31);
    {
        var partp: [4096]u8 = undefined;
        const staged = std.fmt.bufPrint(&partp, "{s}.skpart", .{dst3}) catch unreachable;
        writePattern(staged, 1 << 20, 77); // wrong bytes
        var conns = XferConns.open(allocator, sock_a, sock_b);
        defer conns.close();
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, src3, dst3, true) catch fail("xfer4 init");
        defer x.deinit();
        x.start();
        if (!pumpXfer(allocator, x, &conns, 60_000, 0)) fail("verify xfer never finished");
        if (!x.ok()) failErr("corrupt-resume retry did not recover", x.errMsg());
        if (!std.mem.eql(u8, &(fileSha(dst3) orelse fail("dst3 sha")), &(fileSha(src3) orelse fail("src3 sha"))))
            fail("corrupt resume produced wrong content");
        const staged_left = std.fmt.bufPrint(&partp, "{s}.skpart", .{dst3}) catch unreachable;
        if (statExists(&fsb, allocator, staged_left)) fail("corrupt-resume retry left staged partial");
    }

    // ── tree A → B (dirs, files, symlink), then a resumable rerun
    // that skips completed files ───────────────────────────────
    const tsrc = std.fmt.bufPrint(&pb[6], "{s}/tree", .{dir_a}) catch unreachable;
    const tdst = std.fmt.bufPrint(&pb[7], "{s}/tree.copy", .{dir_b}) catch unreachable;
    {
        var z: [4096]u8 = undefined;
        _ = c.mkdir(pathz.pathZ(&z, tsrc) catch unreachable, 0o755);
        var fp: [4096]u8 = undefined;
        const subp = std.fmt.bufPrint(&fp, "{s}/sub", .{tsrc}) catch unreachable;
        _ = c.mkdir(pathz.pathZ(&z, subp) catch unreachable, 0o755);
        var fp2: [4096]u8 = undefined;
        writePattern(std.fmt.bufPrint(&fp2, "{s}/top.dat", .{tsrc}) catch unreachable, 100_000, 3);
        writePattern(std.fmt.bufPrint(&fp2, "{s}/sub/leaf.dat", .{tsrc}) catch unreachable, 200_000, 4);
        var lz: [4096]u8 = undefined;
        const lp = std.fmt.bufPrint(&fp2, "{s}/ln", .{tsrc}) catch unreachable;
        _ = c.symlink("top.dat", pathz.pathZ(&lz, lp) catch unreachable);
    }
    {
        var conns = XferConns.open(allocator, sock_a, sock_b);
        defer conns.close();
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, tsrc, tdst, false) catch fail("tree xfer init");
        defer x.deinit();
        x.start();
        if (!pumpXfer(allocator, x, &conns, 60_000, 0)) fail("tree xfer never finished");
        if (!x.ok()) failErr("tree xfer failed", x.errMsg());
        if (x.files_done != 2) fail("tree xfer file count");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var fp: [4096]u8 = undefined;
        const leaf = std.fmt.bufPrint(&fp, "{s}/sub/leaf.dat", .{tdst}) catch unreachable;
        const lst = fsb.statPath(arena.allocator(), leaf) catch failErr("tree leaf stat", fsb.lastErr());
        if (lst.size != 200_000) fail("tree leaf size");
        const lnp = std.fmt.bufPrint(&fp, "{s}/ln", .{tdst}) catch unreachable;
        const lnst = fsb.statPath(arena.allocator(), lnp) catch failErr("tree link stat", fsb.lastErr());
        if (!std.mem.eql(u8, lnst.kind, "link")) fail("tree link kind");
        if (!std.mem.eql(u8, lnst.target orelse "", "top.dat")) fail("tree link target");
    }
    {
        var conns = XferConns.open(allocator, sock_a, sock_b);
        defer conns.close();
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, tsrc, tdst, true) catch fail("tree rerun init");
        defer x.deinit();
        x.start();
        if (!pumpXfer(allocator, x, &conns, 60_000, 0)) fail("tree rerun never finished");
        if (!x.ok()) failErr("tree rerun failed", x.errMsg());
        if (x.files_skipped != 2) fail("tree rerun did not skip completed files");
    }

    // ── cancel drops the (non-resumable) staged partial ────────
    {
        var sb: [4096]u8 = undefined;
        var db: [4096]u8 = undefined;
        const csrc = std.fmt.bufPrint(&sb, "{s}/cx.bin", .{dir_a}) catch unreachable;
        const cdst = std.fmt.bufPrint(&db, "{s}/cx.copy", .{dir_b}) catch unreachable;
        writePattern(csrc, 8 << 20, 41);
        var conns = XferConns.open(allocator, sock_a, sock_b);
        defer conns.close();
        const x = fstransfer.Xfer.init(allocator, &conns.src, &conns.dst, &req, csrc, cdst, false) catch fail("cancel xfer init");
        defer x.deinit();
        x.start();
        if (pumpXfer(allocator, x, &conns, 30_000, 1 << 20)) fail("cancel xfer finished early");
        x.cancel();
        if (!x.isTerminal()) fail("cancel not terminal");
        // Give the delete a moment, then confirm neither name exists.
        _ = c.usleep(200_000);
        var partp: [4096]u8 = undefined;
        const staged = std.fmt.bufPrint(&partp, "{s}.skpart", .{cdst}) catch unreachable;
        if (statExists(&fsb, allocator, staged)) fail("cancel left staged partial");
        if (statExists(&fsb, allocator, cdst)) fail("cancel left destination");
    }

    std.debug.print("smoke-fs: xfer stage ok\n", .{});
}

// ── cross-host copy: reconnect and resume ────────────────────────
//
// A `cross_copy` job talks to two daemons through fsdrive. The source
// side is reached the way a real remote is -- `connectRemote` spawns
// $SKETERM_SSH and speaks the protocol over its stdio -- so a fake ssh
// that DIES mid-transfer is exactly the failure a user hits when their
// link drops on a multi-gigabyte copy. The job must reconnect and
// continue from the staged partial rather than report a bare failure.

/// Exit status of a bridge that severed a live transfer, so the fake
/// ssh can tell a real drop apart from an ordinary close (the UDP
/// bootstrap probe also runs the script and closes immediately).
const BRIDGE_SEVERED: u8 = 42;

/// `--bridge <sock> [die_after_bytes]`: pump stdin<->unix socket, the
/// job of the real `sketerm-mux --proxy`. A non-zero byte budget makes
/// the bridge exit once that many bytes have travelled toward the
/// client, which is a dropped link in the middle of a transfer.
fn bridgeMain(sock_path: []const u8, die_after: u64) u8 {
    const fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (fd < 0) return 1;
    defer _ = c.close(fd);
    var addr: c.struct_sockaddr_un = undefined;
    daemon_mod.fillSockaddrUn(&addr, sock_path) catch return 1;
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return 1;
    var forwarded: u64 = 0;
    var buf: [65536]u8 = undefined;
    while (true) {
        var pfds = [_]c.struct_pollfd{
            .{ .fd = 0, .events = c.POLLIN, .revents = 0 },
            .{ .fd = fd, .events = c.POLLIN, .revents = 0 },
        };
        if (c.poll(&pfds, 2, 5000) < 0) return 0;
        if (pfds[0].revents != 0) {
            const n = c.read(0, &buf, buf.len);
            if (n <= 0) return 0;
            if (!writeAll(fd, buf[0..@intCast(n)])) return 0;
        }
        if (pfds[1].revents != 0) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) return 0;
            if (!writeAll(1, buf[0..@intCast(n)])) return 0;
            forwarded += @intCast(n);
            if (die_after > 0 and forwarded >= die_after) return BRIDGE_SEVERED;
        }
    }
}

fn writeAll(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            return false;
        }
        off += @intCast(n);
    }
    return true;
}

/// The daemon-side journal record path for one job — computed by the
/// same rule the daemon uses (state dir keyed by socket hash), so the
/// smoke's helper-kill probes watch the file the helper writes.
fn journalPathOf(allocator: std.mem.Allocator, buf: []u8, sock_path: []const u8, job: u64) []const u8 {
    const dir = daemon_mod.Daemon.fsJobsDirAlloc(allocator, sock_path) catch fail("smoke: journal dir");
    defer allocator.free(dir);
    return std.fmt.bufPrint(buf, "{s}/{d}.json", .{ dir, job }) catch fail("smoke: journal path");
}

fn writeScript(path: [:0]const u8, body: []const u8) void {
    const f = c.fopen(path.ptr, "wb") orelse fail("write fake-ssh");
    if (c.fwrite(body.ptr, 1, body.len, f) != body.len) fail("write fake-ssh body");
    _ = c.fclose(f);
    if (c.chmod(path.ptr, 0o755) != 0) fail("chmod fake-ssh");
}

/// Both stages of the cross-host copy: a clean one, then one whose
/// source link dies partway. `sock_src` is the source host's daemon;
/// `dst_runtime` is the runtime dir whose mux.sock is the destination
/// (a cross_copy with an empty dst_host resolves it there).
fn crossStage(
    allocator: std.mem.Allocator,
    exe: []const u8,
    sock_src: []const u8,
    dst_runtime: []const u8,
    sock_dst: []const u8,
) void {
    var dir_buf: [64]u8 = undefined;
    const dir = mkTmpDir(&dir_buf, "cross");
    var src_dir_buf: [128]u8 = undefined;
    const src_dir = std.fmt.bufPrint(&src_dir_buf, "{s}/from", .{dir}) catch unreachable;
    var dst_dir_buf: [128]u8 = undefined;
    const dst_dir = std.fmt.bufPrint(&dst_dir_buf, "{s}/to", .{dir}) catch unreachable;
    mkdirAt(src_dir);
    mkdirAt(dst_dir);

    // Big enough that the failing bridge dies with the transfer well
    // under way, so the resume has something staged to continue from.
    var big_buf: [256]u8 = undefined;
    const big = std.fmt.bufPrint(&big_buf, "{s}/payload.bin", .{src_dir}) catch unreachable;
    writePattern(big, 6 << 20, 0x5a);
    const want = fileSha(big) orelse fail("cross: source hash");

    // Fake ssh #1: a clean bridge to the source daemon.
    var ssh_ok_buf: [160:0]u8 = undefined;
    const ssh_ok = std.fmt.bufPrintZ(&ssh_ok_buf, "{s}/fake-ssh", .{dir}) catch unreachable;
    var body_buf: [1024]u8 = undefined;
    writeScript(ssh_ok, std.fmt.bufPrint(&body_buf,
        \\#!/bin/sh
        \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
        \\exec "{s}" --bridge "{s}"
        \\
    , .{ exe, sock_src }) catch unreachable);

    // Fake ssh #2: the FIRST connection dies after 2 MB; every later
    // one is clean. The counter is bumped only when the bridge really
    // severed a transfer (exit 42), so the count IS the number of
    // dropped links.
    var count_buf: [160]u8 = undefined;
    const count = std.fmt.bufPrint(&count_buf, "{s}/attempts", .{dir}) catch unreachable;
    var ssh_flaky_buf: [160:0]u8 = undefined;
    const ssh_flaky = std.fmt.bufPrintZ(&ssh_flaky_buf, "{s}/fake-ssh-flaky", .{dir}) catch unreachable;
    var body2_buf: [1024]u8 = undefined;
    writeScript(ssh_flaky, std.fmt.bufPrint(&body2_buf,
        \\#!/bin/sh
        \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
        \\n=$(cat "{s}" 2>/dev/null || echo 0)
        \\if [ "$n" = "0" ]; then
        \\  "{s}" --bridge "{s}" 5000000
        \\  rc=$?
        \\  if [ "$rc" = "42" ]; then echo 1 > "{s}"; fi
        \\  exit $rc
        \\fi
        \\exec "{s}" --bridge "{s}"
        \\
    , .{ count, exe, sock_src, count, exe, sock_src }) catch unreachable);

    // The destination side of a cross_copy with an empty dst_host is
    // "the local daemon", which resolves under $XDG_RUNTIME_DIR. The
    // job helper inherits it from the daemon that spawns it.
    var rt_buf: [160:0]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "{s}", .{dst_runtime}) catch unreachable;
    const prev_rt = c.getenv("XDG_RUNTIME_DIR");
    var prev_rt_buf: [256:0]u8 = undefined;
    const had_rt = prev_rt != null;
    if (had_rt) _ = std.fmt.bufPrintZ(&prev_rt_buf, "{s}", .{std.mem.span(prev_rt.?)}) catch unreachable;
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    defer if (had_rt) {
        _ = c.setenv("XDG_RUNTIME_DIR", &prev_rt_buf, 1);
    } else {
        _ = c.unsetenv("XDG_RUNTIME_DIR");
    };

    var fs = fsdrive.Fs.connect(allocator, sock_dst) catch fail("cross: connect coordinator");
    defer fs.deinit();

    // Same-filesystem MOVE keeps rename's fast path, but journals the
    // source inode first so a lost reply can be resolved without a
    // blind retry against a replacement source.
    {
        var paths: [2][256]u8 = undefined;
        const src = std.fmt.bufPrint(&paths[0], "{s}/rename-source.bin", .{src_dir}) catch unreachable;
        const dst = std.fmt.bufPrint(&paths[1], "{s}/rename-destination.bin", .{dst_dir}) catch unreachable;
        writePattern(src, 1 << 20, 0x2a);
        const want_rename = fileSha(src) orelse fail("cross: rename source hash");
        const job = fs.startCrossCopyOpts("", src, "", dst, true, .{ .delete_src = true, .no_replace = true }) catch
            failErr("cross: start same-filesystem move", fs.lastErr());
        const res = collectJob(&fs, job, 120_000);
        if (!res.is("done")) failErr("cross: same-filesystem move failed", res.messageText());
        if (exists(src)) fail("cross: same-filesystem move left its source");
        const got = fileSha(dst) orelse fail("cross: same-filesystem move destination hash");
        if (!std.mem.eql(u8, &got, &want_rename)) fail("cross: same-filesystem move content mismatch");
    }

    // Same-host move across mount points: rename returns XDEV, but the
    // one durable job must fall back to verified copy/delete rather
    // than expose that implementation detail to the file manager.
    {
        var tmp_st: c.struct_stat = undefined;
        var shm_st: c.struct_stat = undefined;
        var tz: [4096]u8 = undefined;
        if (c.stat(pathz.pathZ(&tz, dir) catch unreachable, &tmp_st) == 0 and
            c.stat("/dev/shm", &shm_st) == 0 and tmp_st.st_dev != shm_st.st_dev)
        {
            var xs_buf: [256]u8 = undefined;
            const xsrc = std.fmt.bufPrint(&xs_buf, "{s}/xdev-source.bin", .{src_dir}) catch unreachable;
            writePattern(xsrc, 16 << 20, 0x3c);
            const xwant = fileSha(xsrc) orelse fail("cross: xdev source hash");
            var xd_buf: [256]u8 = undefined;
            const xdst = std.fmt.bufPrint(&xd_buf, "/dev/shm/sketerm-smoke-fs-xdev-{d}.bin", .{c.getpid()}) catch unreachable;
            var xz: [4096]u8 = undefined;
            _ = c.unlink(pathz.pathZ(&xz, xdst) catch unreachable);
            defer _ = c.unlink(pathz.pathZ(&xz, xdst) catch unreachable);
            const job = fs.startCrossCopyOpts("", xsrc, "", xdst, true, .{ .delete_src = true, .no_replace = true }) catch
                failErr("cross: start xdev move", fs.lastErr());
            var xjournal_buf: [4096]u8 = undefined;
            const xjournal = journalPathOf(allocator, &xjournal_buf, sock_dst, job);
            var xkiller_ctx = MoveHelperKill{ .journal = xjournal };
            const xkiller = std.Thread.spawn(.{}, killMoveHelperInDestinationStage, .{&xkiller_ctx}) catch
                fail("cross: XDEV file helper killer");
            const res = collectJob(&fs, job, 120_000);
            xkiller.join();
            if (!xkiller_ctx.killed) fail("cross: XDEV file helper was not killed after staging");
            if (!res.is("done")) failErr("cross: XDEV move did not fall back to copy/delete", res.messageText());
            const xgot = fileSha(xdst) orelse fail("cross: xdev destination hash");
            if (!std.mem.eql(u8, &xgot, &xwant)) fail("cross: xdev move content mismatch");
            var gone: c.struct_stat = undefined;
            if (c.lstat(pathz.pathZ(&xz, xsrc) catch unreachable, &gone) == 0)
                fail("cross: xdev move left its source behind");

            var tree_paths: [3][256]u8 = undefined;
            const tree_src = std.fmt.bufPrint(&tree_paths[0], "{s}/xdev-tree", .{src_dir}) catch unreachable;
            mkdirAt(tree_src);
            const tree_file = std.fmt.bufPrint(&tree_paths[1], "{s}/payload.bin", .{tree_src}) catch unreachable;
            writePattern(tree_file, 16 << 20, 0x6e);
            // A file sorting AFTER the watched one keeps "payload.bin
            // installed bare, tree not yet done" open for a whole
            // file's transfer — the watcher's kill window.
            var tree_tail_buf: [256]u8 = undefined;
            const tree_tail = std.fmt.bufPrint(&tree_tail_buf, "{s}/zz-tail.bin", .{tree_src}) catch unreachable;
            writePattern(tree_tail, 16 << 20, 0x6f);
            const tree_dst = std.fmt.bufPrint(&tree_paths[2], "/dev/shm/sketerm-smoke-fs-xdev-tree-{d}", .{c.getpid()}) catch unreachable;
            daemon_mod.removeTreeBestEffort(tree_dst);
            defer daemon_mod.removeTreeBestEffort(tree_dst);
            const tree_job = fs.startCrossCopyOpts("", tree_src, "", tree_dst, true, .{
                .delete_src = true,
                .no_replace = true,
            }) catch failErr("cross: start resumable XDEV tree move", fs.lastErr());
            var journal_buf: [4096]u8 = undefined;
            const journal = journalPathOf(allocator, &journal_buf, sock_dst, tree_job);
            var killer_ctx = MoveHelperKill{ .journal = journal, .stage_child = "payload.bin" };
            const killer = std.Thread.spawn(.{}, killMoveHelperInDestinationStage, .{&killer_ctx}) catch
                fail("cross: XDEV tree helper killer");
            const tree_res = collectJob(&fs, tree_job, 180_000);
            killer.join();
            if (!killer_ctx.killed) fail("cross: XDEV tree helper was not killed in its destination stage");
            if (!tree_res.is("done")) failErr("cross: XDEV tree move did not recover", tree_res.messageText());
            if (exists(tree_src)) fail("cross: recovered XDEV tree left its source");
            var moved_file_buf: [256]u8 = undefined;
            const moved_file = std.fmt.bufPrint(&moved_file_buf, "{s}/payload.bin", .{tree_dst}) catch unreachable;
            if (!exists(moved_file)) fail("cross: recovered XDEV tree lost its payload");

            var stale_paths: [3][256]u8 = undefined;
            const stale_src = std.fmt.bufPrint(&stale_paths[0], "{s}/xdev-stale-tree", .{src_dir}) catch unreachable;
            mkdirAt(stale_src);
            const stale_file = std.fmt.bufPrint(&stale_paths[1], "{s}/removed.bin", .{stale_src}) catch unreachable;
            writePattern(stale_file, 8 << 20, 0x71);
            // Same trailing-file trick: keeps the bare removed.bin
            // observable while the tree copy is still running.
            var stale_tail_buf: [256]u8 = undefined;
            const stale_tail = std.fmt.bufPrint(&stale_tail_buf, "{s}/zz-tail.bin", .{stale_src}) catch unreachable;
            writePattern(stale_tail, 8 << 20, 0x72);
            const stale_dst = std.fmt.bufPrint(&stale_paths[2], "/dev/shm/sketerm-smoke-fs-xdev-stale-{d}", .{c.getpid()}) catch unreachable;
            daemon_mod.removeTreeBestEffort(stale_dst);
            defer daemon_mod.removeTreeBestEffort(stale_dst);
            const stale_job = fs.startCrossCopyOpts("", stale_src, "", stale_dst, true, .{
                .delete_src = true,
                .no_replace = true,
            }) catch failErr("cross: start stale-stage XDEV move", fs.lastErr());
            var stale_journal_buf: [4096]u8 = undefined;
            const stale_journal = journalPathOf(allocator, &stale_journal_buf, sock_dst, stale_job);
            var stale_killer_ctx = MoveHelperKill{
                .journal = stale_journal,
                .remove_after_kill = stale_file,
                .stage_child = "removed.bin",
            };
            const stale_killer = std.Thread.spawn(.{}, killMoveHelperInDestinationStage, .{&stale_killer_ctx}) catch
                fail("cross: stale-stage helper killer");
            const stale_res = collectJob(&fs, stale_job, 180_000);
            stale_killer.join();
            if (!stale_killer_ctx.killed) fail("cross: stale-stage helper was not killed after copying its entry");
            if (!stale_res.is("error")) fail("cross: stale staged entry was silently installed");
            if (!exists(stale_src)) fail("cross: stale-stage refusal deleted the current source root");
            if (exists(stale_dst)) fail("cross: stale-stage refusal installed the destination root");
            var stale_arena = std.heap.ArenaAllocator.init(allocator);
            defer stale_arena.deinit();
            if (fsjournal.load(stale_arena.allocator(), stale_journal)) |parsed_value| {
                var parsed = parsed_value;
                defer parsed.deinit();
                if (parsed.value.destination_stage.len > 0)
                    daemon_mod.removeTreeBestEffort(parsed.value.destination_stage);
            } else |_| {}
        }
    }

    // ── clean cross-host copy ──────────────────────────────────
    _ = c.setenv("SKETERM_SSH", ssh_ok.ptr, 1);
    var out_buf: [256]u8 = undefined;
    const out_clean = std.fmt.bufPrint(&out_buf, "{s}/clean.bin", .{dst_dir}) catch unreachable;
    {
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", big, "", out_clean, true, .{ .no_replace = true }) catch
            failErr("cross: start clean", fs.lastErr());
        const res = collectJob(&fs, job, 120_000);
        if (!res.is("done")) failErr("cross: clean copy did not finish", res.messageText());
        const got = fileSha(out_clean) orelse fail("cross: clean hash");
        if (!std.mem.eql(u8, &got, &want)) fail("cross: clean copy content mismatch");
    }

    // A matching final file is not proof that this no-replace job
    // installed it. Even identical bytes must leave a move source alone.
    {
        var paths: [3][256]u8 = undefined;
        const src = std.fmt.bufPrint(&paths[0], "{s}/collision-source.bin", .{src_dir}) catch unreachable;
        const dst = std.fmt.bufPrint(&paths[1], "{s}/collision-destination.bin", .{dst_dir}) catch unreachable;
        writePattern(src, 1 << 20, 0x4d);
        writePattern(dst, 1 << 20, 0x4d);
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", src, "", dst, true, .{
            .delete_src = true,
            .no_replace = true,
        }) catch failErr("cross: start no-replace collision", fs.lastErr());
        const res = collectJob(&fs, job, 120_000);
        if (!res.is("error")) fail("cross: no-replace collision reported success");
        if (!exists(src)) fail("cross: no-replace collision deleted its source");
        const got = fileSha(dst) orelse fail("cross: collision destination hash");
        const expected = fileSha(src) orelse fail("cross: collision source hash");
        if (!std.mem.eql(u8, &got, &expected)) fail("cross: collision damaged destination");
    }

    // Root links keep link identity across hosts, including a link
    // whose target happens to be a directory.
    {
        var link_paths: [7][256]u8 = undefined;
        const target_dir = std.fmt.bufPrint(&link_paths[0], "{s}/link-target", .{src_dir}) catch unreachable;
        mkdirAt(target_dir);
        const file_link = std.fmt.bufPrint(&link_paths[1], "{s}/file-link", .{src_dir}) catch unreachable;
        const dir_link = std.fmt.bufPrint(&link_paths[2], "{s}/dir-link", .{src_dir}) catch unreachable;
        const file_dst = std.fmt.bufPrint(&link_paths[3], "{s}/file-link", .{dst_dir}) catch unreachable;
        const dir_dst = std.fmt.bufPrint(&link_paths[4], "{s}/dir-link", .{dst_dir}) catch unreachable;
        const move_link = std.fmt.bufPrint(&link_paths[5], "{s}/move-link", .{src_dir}) catch unreachable;
        const move_dst = std.fmt.bufPrint(&link_paths[6], "{s}/move-link", .{dst_dir}) catch unreachable;
        var z: [4096]u8 = undefined;
        if (c.symlink("payload.bin", pathz.pathZ(&z, file_link) catch unreachable) != 0) fail("cross: make file link");
        if (c.symlink("link-target", pathz.pathZ(&z, dir_link) catch unreachable) != 0) fail("cross: make dir link");
        if (c.symlink("payload.bin", pathz.pathZ(&z, move_link) catch unreachable) != 0) fail("cross: make move link");
        const fj = fs.startCrossCopy("ssh:127.0.0.1", file_link, "", file_dst, true) catch
            failErr("cross: copy root file link", fs.lastErr());
        if (!collectJob(&fs, fj, 120_000).is("done")) fail("cross: root file link failed");
        const dj = fs.startCrossCopy("ssh:127.0.0.1", dir_link, "", dir_dst, true) catch
            failErr("cross: copy root dir link", fs.lastErr());
        if (!collectJob(&fs, dj, 120_000).is("done")) fail("cross: root dir link failed");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const fst = fs.statPath(arena.allocator(), file_dst) catch failErr("cross: stat file link", fs.lastErr());
        const dst = fs.statPath(arena.allocator(), dir_dst) catch failErr("cross: stat dir link", fs.lastErr());
        if (!std.mem.eql(u8, fst.kind, "link") or !std.mem.eql(u8, fst.target orelse "", "payload.bin"))
            fail("cross: root file link was dereferenced");
        if (!std.mem.eql(u8, dst.kind, "link") or !std.mem.eql(u8, dst.target orelse "", "link-target"))
            fail("cross: root directory link was dereferenced");
        const mj = fs.startCrossCopyOpts("ssh:127.0.0.1", move_link, "", move_dst, true, .{ .delete_src = true }) catch
            failErr("cross: move root link", fs.lastErr());
        if (!collectJob(&fs, mj, 120_000).is("done")) fail("cross: root link move failed");
        arena.deinit();
        arena = std.heap.ArenaAllocator.init(allocator);
        const moved = fs.statPath(arena.allocator(), move_dst) catch failErr("cross: stat moved link", fs.lastErr());
        if (!std.mem.eql(u8, moved.kind, "link") or !std.mem.eql(u8, moved.target orelse "", "payload.bin"))
            fail("cross: moved root link was dereferenced");
        if (exists(move_link)) fail("cross: moved root link source survived");
    }

    // ── link dies mid-transfer: reconnect, resume, same bytes ──
    _ = c.setenv("SKETERM_SSH", ssh_flaky.ptr, 1);
    const out_flaky = std.fmt.bufPrint(&out_buf, "{s}/flaky.bin", .{dst_dir}) catch unreachable;
    {
        const job = fs.startCrossCopy("ssh:127.0.0.1", big, "", out_flaky, true) catch
            failErr("cross: start flaky", fs.lastErr());
        const res = collectJob(&fs, job, 180_000);
        if (!res.is("done"))
            failErr("cross: a dropped source link killed the copy instead of resuming it", res.messageText());
        const got = fileSha(out_flaky) orelse fail("cross: flaky hash");
        if (!std.mem.eql(u8, &got, &want)) fail("cross: resumed copy content mismatch");
        // The bridge really did die and get re-dialled.
        var cbuf: [32]u8 = undefined;
        const severed = readSmall(count, &cbuf);
        if (severed.len == 0 or severed[0] != '1')
            fail("cross: the source link never actually dropped mid-transfer");
        // Continuing, not restarting: the byte counter only ever moved
        // forward across the drop, so the megabytes already staged were
        // not thrown away.
        if (res.regressed)
            fail("cross: the reconnect restarted the file from zero instead of continuing");
        // ...and the stall explained itself while it happened, instead
        // of the row simply freezing.
        if (!res.said_reconnecting)
            fail("cross: the dropped link was never reported to the client");
        // The megabytes moved before the drop survived it. This is the
        // property that makes a dead link cost a reconnect rather than
        // the whole transfer.
        if (res.resumed_at == 0)
            fail("cross: the copy resumed from byte zero, losing everything already transferred");
    }
    _ = c.unsetenv("SKETERM_SSH");

    // ── cross-host MOVE: verified copy, then the source is gone ──
    // delete_src runs strictly after the rename, on the SOURCE
    // daemon, so the move is one daemon-owned job end to end.
    _ = c.setenv("SKETERM_SSH", ssh_ok.ptr, 1);
    {
        var mv_buf: [256]u8 = undefined;
        const mv_src = std.fmt.bufPrint(&mv_buf, "{s}/move-me.bin", .{src_dir}) catch unreachable;
        writePattern(mv_src, 1 << 20, 0x77);
        const mv_want = fileSha(mv_src) orelse fail("cross: move source hash");
        var mvd_buf: [256]u8 = undefined;
        const mv_dst = std.fmt.bufPrint(&mvd_buf, "{s}/moved.bin", .{dst_dir}) catch unreachable;
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", mv_src, "", mv_dst, true, .{ .delete_src = true }) catch
            failErr("cross: start move", fs.lastErr());
        const res = collectJob(&fs, job, 120_000);
        if (!res.is("done")) failErr("cross: move did not finish", res.messageText());
        const got = fileSha(mv_dst) orelse fail("cross: move dst hash");
        if (!std.mem.eql(u8, &got, &mv_want)) fail("cross: moved content mismatch");
        var z2: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.lstat(pathz.pathZ(&z2, mv_src) catch unreachable, &st) == 0)
            fail("cross: move left the source file behind");
    }
    {
        // Once the copied source is atomically quarantined, the original
        // pathname belongs to the outside world again. A replacement
        // created there must survive the remainder of source cleanup.
        var src_buf: [256]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/replace-after-quarantine.bin", .{src_dir}) catch unreachable;
        writePattern(src, 8 << 20, 0x61);
        var dst_buf: [256]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/replace-after-quarantine.bin", .{dst_dir}) catch unreachable;
        var replacement = MoveReplacement{ .source = src };
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", src, "", dst, true, .{ .delete_src = true }) catch
            failErr("cross: start replacement-safe move", fs.lastErr());
        const replacer = std.Thread.spawn(.{}, replaceMoveSourceAfterQuarantine, .{&replacement}) catch
            fail("cross: replacement thread");
        const res = collectJob(&fs, job, 120_000);
        replacer.join();
        if (!res.is("done")) failErr("cross: replacement-safe move did not finish", res.messageText());
        if (!replacement.replaced) fail("cross: source replacement did not overlap quarantine cleanup");
        const got = fileSha(src) orelse fail("cross: replacement source was deleted");
        var expected_path_buf: [256]u8 = undefined;
        const expected_path = std.fmt.bufPrint(&expected_path_buf, "{s}/replacement-expected.bin", .{src_dir}) catch unreachable;
        writePattern(expected_path, 4096, 0xa7);
        defer {
            var z: [4096]u8 = undefined;
            _ = c.unlink(pathz.pathZ(&z, expected_path) catch unreachable);
        }
        const expected = fileSha(expected_path) orelse fail("cross: replacement oracle hash");
        if (!std.mem.eql(u8, &got, &expected)) fail("cross: move cleanup altered replacement source");
    }
    {
        // The copy boundary and quarantine identity are helper-owned
        // journal state. Killing that exact helper must respawn cleanup
        // without falling back to deleting the original pathname.
        // A tree source keeps the post-quarantine window wide enough to
        // land the kill: verified digests are cached per run, so a
        // single file's cleanup tail became nearly instant.
        var src_buf: [256]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/crash-recovery", .{src_dir}) catch unreachable;
        mkdirAt(src);
        var big_crash_buf: [256]u8 = undefined;
        const big_crash = std.fmt.bufPrint(&big_crash_buf, "{s}/payload.bin", .{src}) catch unreachable;
        writePattern(big_crash, 32 << 20, 0x39);
        {
            var i: usize = 0;
            var name_buf: [64]u8 = undefined;
            while (i < 64) : (i += 1) {
                const name = std.fmt.bufPrint(&name_buf, "small-{d}.txt", .{i}) catch unreachable;
                touch(src, name, "crash recovery payload");
            }
        }
        const want_crash = fileSha(big_crash) orelse fail("cross: crash recovery source hash");
        var dst_buf: [256]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/crash-recovery", .{dst_dir}) catch unreachable;
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", src, "", dst, true, .{ .delete_src = true }) catch
            failErr("cross: start crash-recovery move", fs.lastErr());
        var journal_buf: [4096]u8 = undefined;
        const journal = journalPathOf(allocator, &journal_buf, sock_dst, job);
        var killer_ctx = MoveHelperKill{ .journal = journal };
        const killer = std.Thread.spawn(.{}, killMoveHelperAfterCopy, .{&killer_ctx}) catch
            fail("cross: helper killer thread");
        const res = collectJob(&fs, job, 180_000);
        killer.join();
        if (!killer_ctx.killed) fail("cross: move helper was not killed after its copy boundary");
        if (!res.is("done")) failErr("cross: killed move helper did not recover", res.messageText());
        if (exists(src)) fail("cross: recovered move left its source behind");
        var moved_crash_buf: [256]u8 = undefined;
        const moved_crash = std.fmt.bufPrint(&moved_crash_buf, "{s}/payload.bin", .{dst}) catch unreachable;
        const got = fileSha(moved_crash) orelse fail("cross: recovered move destination hash");
        if (!std.mem.eql(u8, &got, &want_crash)) fail("cross: recovered move content mismatch");
    }
    {
        // A directory move: the source side needs a delete_tree job.
        var td_buf: [256]u8 = undefined;
        const tree_src = std.fmt.bufPrint(&td_buf, "{s}/movetree", .{src_dir}) catch unreachable;
        mkdirAt(tree_src);
        touch(tree_src, "a.txt", "alpha");
        var sub_buf: [256]u8 = undefined;
        const sub = std.fmt.bufPrint(&sub_buf, "{s}/sub", .{tree_src}) catch unreachable;
        mkdirAt(sub);
        touch(sub, "b.txt", "beta");
        var tdd_buf: [256]u8 = undefined;
        const tree_dst = std.fmt.bufPrint(&tdd_buf, "{s}/movetree", .{dst_dir}) catch unreachable;
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", tree_src, "", tree_dst, true, .{ .delete_src = true, .no_replace = true }) catch
            failErr("cross: start tree move", fs.lastErr());
        const res = collectJob(&fs, job, 120_000);
        if (!res.is("done")) failErr("cross: tree move did not finish", res.messageText());
        if (res.files_done != 2 or res.files_total != 2)
            fail("cross: tree move did not report a stable full-file total");
        if (res.files_total_changed)
            fail("cross: tree move file total grew while the copy was already running");
        var chk_buf: [256]u8 = undefined;
        var z2: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        const moved_b = std.fmt.bufPrint(&chk_buf, "{s}/sub/b.txt", .{tree_dst}) catch unreachable;
        if (c.lstat(pathz.pathZ(&z2, moved_b) catch unreachable, &st) != 0)
            fail("cross: tree move lost a nested file");
        if (c.lstat(pathz.pathZ(&z2, tree_src) catch unreachable, &st) == 0)
            fail("cross: tree move left the source tree behind");
    }

    {
        // A destination directory alone is not recovery proof. This is
        // the exact dangerous shape left by an interrupted tree copy.
        var missing_buf: [256]u8 = undefined;
        const missing = std.fmt.bufPrint(&missing_buf, "{s}/never-existed", .{src_dir}) catch unreachable;
        var partial_buf: [256]u8 = undefined;
        const partial = std.fmt.bufPrint(&partial_buf, "{s}/partial-tree", .{dst_dir}) catch unreachable;
        mkdirAt(partial);
        touch(partial, "one.partial", "not a completed tree");
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", missing, "", partial, true, .{ .delete_src = true }) catch
            failErr("cross: start missing-source recovery", fs.lastErr());
        const res = collectJob(&fs, job, 120_000);
        if (!res.is("error")) fail("cross: partial directory was accepted as completed recovery");
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.lstat(fsserve.joinZ(&z, partial, "one.partial") catch unreachable, &st) != 0)
            fail("cross: failed recovery damaged the partial destination");
    }
    {
        // Mutate a file that has already been copied and add a new
        // source entry while a later large file is still transferring.
        // The move must fail before deleting ANY source manifest entry.
        var mut_src_buf: [256]u8 = undefined;
        const mut_src = std.fmt.bufPrint(&mut_src_buf, "{s}/mutating-tree", .{src_dir}) catch unreachable;
        mkdirAt(mut_src);
        touch(mut_src, "a-copied.txt", "original");
        var large_buf: [256]u8 = undefined;
        const large = std.fmt.bufPrint(&large_buf, "{s}/b-large.bin", .{mut_src}) catch unreachable;
        writePattern(large, 64 << 20, 0x2d);
        var mut_dst_buf: [256]u8 = undefined;
        const mut_dst = std.fmt.bufPrint(&mut_dst_buf, "{s}/mutating-tree", .{dst_dir}) catch unreachable;
        var part_buf: [256]u8 = undefined;
        const part = std.fmt.bufPrint(&part_buf, "{s}/b-large.bin.skpart", .{mut_dst}) catch unreachable;
        var mutation = MoveMutation{ .part = part, .source_dir = mut_src };
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", mut_src, "", mut_dst, true, .{ .delete_src = true }) catch
            failErr("cross: start concurrently-mutated move", fs.lastErr());
        const mutator = std.Thread.spawn(.{}, mutateMoveAfterCopyStarts, .{&mutation}) catch fail("cross: mutation thread");
        const res = collectJob(&fs, job, 180_000);
        mutator.join();
        if (!mutation.mutated) fail("cross: mutation did not overlap the copy");
        if (!res.is("error")) fail("cross: concurrently-mutated move reported success");
        if (std.mem.indexOf(u8, res.messageText(), "changed") == null)
            failErr("cross: mutation failure did not explain source drift", res.messageText());
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        inline for (.{ "a-copied.txt", "b-large.bin", "unexpected.txt" }) |name| {
            if (c.lstat(fsserve.joinZ(&z, mut_src, name) catch unreachable, &st) != 0)
                fail("cross: mutated move deleted source content");
        }
        var copied_a_buf: [256]u8 = undefined;
        const copied_a = std.fmt.bufPrint(&copied_a_buf, "{s}/a-copied.txt", .{mut_dst}) catch unreachable;
        var bytes: [32]u8 = undefined;
        const copied = readSmall(copied_a, &bytes);
        if (!std.mem.eql(u8, copied, "original")) fail("cross: changed source overwrote its proven destination copy");
    }

    // ── retry with a rotated client_token adopts the failed job ──
    // The browser mints a fresh idempotency token per attempt but keeps
    // the transfer_token; the daemon must RESTART the failed job under
    // its own id so the staged partial is resumed, never orphaned
    // (the `.sketerm-copy-47` vs `-50` bug class).
    {
        var rs_buf: [256]u8 = undefined;
        const rs_src = std.fmt.bufPrint(&rs_buf, "{s}/retry-resume.bin", .{src_dir}) catch unreachable;
        writePattern(rs_src, 24 << 20, 0x53);
        const want_rs = fileSha(rs_src) orelse fail("cross: retry-resume source hash");
        var rd_buf: [256]u8 = undefined;
        const rs_dst = std.fmt.bufPrint(&rd_buf, "{s}/retry-resume.bin", .{dst_dir}) catch unreachable;
        const job = fs.startCrossCopyTokenOpts("ssh:127.0.0.1", rs_src, "", rs_dst, true, "attempt-1", .{
            .transfer_token = "xfer-retry-resume",
        }) catch failErr("cross: start retry-resume", fs.lastErr());
        var journal_buf: [4096]u8 = undefined;
        const journal = journalPathOf(allocator, &journal_buf, sock_dst, job);
        var part_buf: [256]u8 = undefined;
        const part = std.fmt.bufPrint(&part_buf, "{s}.skpart", .{rs_dst}) catch unreachable;
        var killer_ctx = CopyHelperKill{ .journal = journal, .part = part };
        const killer = std.Thread.spawn(.{}, killCopyHelperMidTransfer, .{&killer_ctx}) catch
            fail("cross: retry-resume killer thread");
        const first = collectJob(&fs, job, 120_000);
        killer.join();
        if (!killer_ctx.killed) fail("cross: retry-resume helper was not killed mid-transfer");
        if (!first.is("error")) fail("cross: killed copy attempt did not report failure");
        if (!exists(part)) fail("cross: killed copy attempt left no staged partial");
        // The retry: NEW client_token, SAME transfer_token.
        const retry_job = fs.startCrossCopyTokenOpts("ssh:127.0.0.1", rs_src, "", rs_dst, true, "attempt-2", .{
            .transfer_token = "xfer-retry-resume",
        }) catch failErr("cross: start retry-resume attempt 2", fs.lastErr());
        if (retry_job != job)
            fail("cross: the retry minted a fresh job instead of restarting the failed one");
        const second = collectJob(&fs, retry_job, 120_000);
        if (!second.is("done")) failErr("cross: retried copy did not finish", second.messageText());
        if (second.resumed_from == 0)
            fail("cross: the retry restarted from byte zero instead of resuming the staged partial");
        const got_rs = fileSha(rs_dst) orelse fail("cross: retry-resume destination hash");
        if (!std.mem.eql(u8, &got_rs, &want_rs)) fail("cross: retried copy content mismatch");
    }

    // ── move failing AFTER install: destination stays, retry only
    // finishes cleanup ──
    // Once the copy is verified and installed, a cleanup failure must
    // (a) say the copy is intact, (b) leave it under its final name,
    // and (c) let a retry redo ONLY the source cleanup.
    {
        var qdir_buf: [256]u8 = undefined;
        const qdir = std.fmt.bufPrint(&qdir_buf, "{s}/quarantine-blocked", .{src_dir}) catch unreachable;
        mkdirAt(qdir);
        var qs_buf: [256]u8 = undefined;
        const q_src = std.fmt.bufPrint(&qs_buf, "{s}/move-me.bin", .{qdir}) catch unreachable;
        writePattern(q_src, 16 << 20, 0x47);
        const want_q = fileSha(q_src) orelse fail("cross: blocked-move source hash");
        var qd_buf: [256]u8 = undefined;
        const q_dst = std.fmt.bufPrint(&qd_buf, "{s}/quarantine-blocked.bin", .{dst_dir}) catch unreachable;
        const job = fs.startCrossCopyTokenOpts("ssh:127.0.0.1", q_src, "", q_dst, true, "qmove-1", .{
            .delete_src = true,
            .no_replace = true,
            .transfer_token = "xfer-quarantine-blocked",
        }) catch failErr("cross: start blocked move", fs.lastErr());
        var journal_buf: [4096]u8 = undefined;
        const journal = journalPathOf(allocator, &journal_buf, sock_dst, job);
        var blocker_ctx = QuarantineBlock{ .journal = journal, .parent = qdir };
        const blocker = std.Thread.spawn(.{}, blockQuarantineDuringCopy, .{&blocker_ctx}) catch
            fail("cross: quarantine blocker thread");
        const first = collectJob(&fs, job, 120_000);
        blocker.join();
        var qz: [4096]u8 = undefined;
        const restore_ok = c.chmod(pathz.pathZ(&qz, qdir) catch unreachable, 0o755) == 0;
        if (!blocker_ctx.blocked) fail("cross: quarantine block did not land during the copy");
        if (!restore_ok) fail("cross: could not restore blocked source parent");
        if (!first.is("error")) fail("cross: blocked move reported success");
        if (std.mem.indexOf(u8, first.messageText(), "complete and installed") == null)
            failErr("cross: post-install failure did not say the copy is intact", first.messageText());
        if (!exists(q_src)) fail("cross: blocked move lost its source");
        const got_installed = fileSha(q_dst) orelse fail("cross: blocked move destination missing");
        if (!std.mem.eql(u8, &got_installed, &want_q))
            fail("cross: blocked move destination content mismatch");
        const installed_ino = inodeOf(q_dst);
        // The retry: cleanup only — same job, same installed inode.
        const retry_job = fs.startCrossCopyTokenOpts("ssh:127.0.0.1", q_src, "", q_dst, true, "qmove-2", .{
            .delete_src = true,
            .no_replace = true,
            .transfer_token = "xfer-quarantine-blocked",
        }) catch failErr("cross: start blocked-move retry", fs.lastErr());
        if (retry_job != job)
            fail("cross: the cleanup retry minted a fresh job instead of restarting the failed one");
        const second = collectJob(&fs, retry_job, 120_000);
        if (!second.is("done")) failErr("cross: cleanup retry did not finish the move", second.messageText());
        if (exists(q_src)) fail("cross: cleanup retry left the source behind");
        if (inodeOf(q_dst) != installed_ino)
            fail("cross: cleanup retry recopied the already-installed destination");
        const got_final = fileSha(q_dst) orelse fail("cross: cleanup-retry destination hash");
        if (!std.mem.eql(u8, &got_final, &want_q)) fail("cross: cleanup retry damaged the destination");
    }
    _ = c.unsetenv("SKETERM_SSH");

    // ── an unreachable source names itself in the failure ──────
    var ssh_dead_buf: [160:0]u8 = undefined;
    const ssh_dead = std.fmt.bufPrintZ(&ssh_dead_buf, "{s}/fake-ssh-dead", .{dir}) catch unreachable;
    writeScript(ssh_dead,
        \\#!/bin/sh
        \\if [ "$1" = "-G" ]; then printf 'hostname 127.0.0.1\n'; exit 0; fi
        \\exit 1
        \\
    );
    _ = c.setenv("SKETERM_SSH", ssh_dead.ptr, 1);
    {
        const out_dead = std.fmt.bufPrint(&out_buf, "{s}/dead.bin", .{dst_dir}) catch unreachable;
        // dial_tries caps the dial backoff (the browser's DIRECT
        // remote-to-remote attempt), so the failure lands in seconds.
        const job = fs.startCrossCopyOpts("ssh:127.0.0.1", big, "", out_dead, true, .{ .dial_tries = 2 }) catch
            failErr("cross: start dead", fs.lastErr());
        const res = collectJob(&fs, job, 180_000);
        if (!res.is("error")) fail("cross: an unreachable source reported success");
        // "cross-host copy failed" told a user nothing; the reason has
        // to say which side and which host.
        if (std.mem.indexOf(u8, res.messageText(), "source") == null or
            std.mem.indexOf(u8, res.messageText(), "127.0.0.1") == null)
            failErr("cross: failure reason names neither the side nor the host", res.messageText());
        // The structural cause that drives the browser's fallback to
        // relaying: a failed dial must be told apart from a failed copy.
        if (!std.mem.eql(u8, res.kindText(), "unreachable"))
            failErr("cross: dial failure not stamped kind=unreachable", res.kindText());
    }
    _ = c.unsetenv("SKETERM_SSH");
    std.debug.print("smoke-fs: cross-host copy reconnect/resume OK\n", .{});
}

/// Push a path's mtime two seconds forward: an "external edit" whose
/// mtime is guaranteed to differ, without sleeping for a filesystem's
/// timestamp granularity.
fn bumpMtime(path: []const u8) void {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch fail("bump path");
    var st: c.struct_stat = undefined;
    if (c.lstat(p, &st) != 0) fail("bump lstat");
    const mts = mtime(st);
    var times = [_]c.struct_timespec{
        .{ .tv_sec = mts.tv_sec, .tv_nsec = 0 },
        .{ .tv_sec = mts.tv_sec + 2, .tv_nsec = 0 },
    };
    if (c.utimensat(c.AT_FDCWD, p, &times, 0) != 0) fail("bump utimensat");
}

fn modeOf(path: []const u8) u32 {
    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    if (c.lstat(pathz.pathZ(&z, path) catch fail("mode path"), &st) != 0) fail("mode lstat");
    return @intCast(st.st_mode & 0o7777);
}

fn mtimeNsOf(path: []const u8) i64 {
    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    if (c.lstat(pathz.pathZ(&z, path) catch fail("mtime path"), &st) != 0) fail("mtime lstat");
    return fsserve.mtimeNs(&st);
}

/// True when the directory still holds a `.sketerm-save.` staging
/// file — the litter a failed atomic save must never leave behind.
fn hasStagedTemp(dir: []const u8) bool {
    var z: [4096]u8 = undefined;
    const d = c.opendir(pathz.pathZ(&z, dir) catch fail("temp scan path")) orelse fail("temp scan opendir");
    defer _ = c.closedir(d);
    while (c.readdir(d)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (std.mem.indexOf(u8, name, ".sketerm-save.") != null) return true;
    }
    return false;
}

/// Observe one path exactly the way the editor's disk probe does.
fn probeState(fs: *fsdrive.Fs, allocator: std.mem.Allocator, path: []const u8) reload.DiskState {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const e = fs.statFollow(arena.allocator(), path) catch |err| {
        if (err == fsdrive.Error.FsOpFailed) return .{ .known = true, .present = false };
        failErr("probe: stat transport", fs.lastErr());
    };
    return .{
        .known = true,
        .present = true,
        .mtime_ns = e.mtime_ns,
        .mtime_ms = e.mtime_ms,
        .size = e.size,
        .ino = e.ino,
        .mode = e.mode,
    };
}

/// The editor's external-modification detector, end to end against a
/// real daemon: the identity a stat reports, and the verdict the pure
/// predicate draws from it, for every way a file can change under an
/// open document.
fn probeStage(allocator: std.mem.Allocator, sock_path: []const u8, comptime tag: []const u8) void {
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf, tag ++ "-probe");
    var fs = fsdrive.Fs.connect(allocator, sock_path) catch fail("probe: fs connect");
    defer fs.deinit();

    var doc_buf: [4096]u8 = undefined;
    const doc = std.fmt.bufPrint(&doc_buf, "{s}/doc.txt", .{dir}) catch unreachable;
    touch(dir, "doc.txt", "one\n");

    // Baseline, as an editor takes it at load time.
    const base = probeState(&fs, allocator, doc);
    if (!base.present or base.ino == 0) fail("probe: baseline has no identity");
    if (reload.compare(base, probeState(&fs, allocator, doc)) != .unchanged)
        fail("probe: an untouched file reported a change");

    // ── the atomic writer: temp + rename, NEW inode ────────────
    const installed = fs.writeFileAtomic(doc, "two\n", base.mtime_ns) catch
        failErr("probe: atomic rewrite", fs.lastErr());
    if (installed.ino == base.ino) fail("probe: atomic save did not change the inode");
    const after_install = probeState(&fs, allocator, doc);
    if (after_install.ino != installed.ino) fail("probe: stat disagrees with the install reply");
    if (reload.compare(base, after_install) != .replaced)
        fail("probe: an atomic rewrite was not seen as a replacement");
    // Same verdict when the new file's mtime is OLDER than ours: the
    // inode is what carries the truth (a staged temp can predate us).
    {
        var older = after_install;
        older.mtime_ns = base.mtime_ns - 1_000_000;
        older.mtime_ms = base.mtime_ms - 1;
        older.size = base.size;
        if (reload.compare(base, older) != .replaced)
            fail("probe: a backdated replacement escaped detection");
    }

    // ── an in-place rewrite: same inode, new mtime/size ────────
    {
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, doc) catch fail("probe: path");
        const f = c.fopen(p, "wb") orelse fail("probe: reopen");
        _ = c.fwrite("three\n", 1, 6, f);
        _ = c.fclose(f);
    }
    bumpMtime(doc);
    const after_edit = probeState(&fs, allocator, doc);
    if (after_edit.ino != after_install.ino) fail("probe: in-place write moved the inode");
    if (reload.compare(after_install, after_edit) != .modified)
        fail("probe: an in-place rewrite was not seen as a modification");

    // ── permission-only change ─────────────────────────────────
    {
        var z: [4096]u8 = undefined;
        _ = c.chmod(pathz.pathZ(&z, doc) catch fail("probe: chmod path"), 0o600);
    }
    const after_chmod = probeState(&fs, allocator, doc);
    if (reload.compare(after_edit, after_chmod) != .permissions)
        fail("probe: a mode change was not seen as a permission change");

    // ── symlinked document: the LINK's lstat must not be what a
    // document is compared against ─────────────────────────────
    var link_buf: [4096]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buf, "{s}/link.txt", .{dir}) catch unreachable;
    {
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        if (c.symlink(
            pathz.pathZ(&z1, doc) catch fail("probe: link target"),
            pathz.pathZ(&z2, link) catch fail("probe: link path"),
        ) != 0) fail("probe: symlink");
    }
    const via_link = probeState(&fs, allocator, link);
    if (via_link.ino != after_chmod.ino) fail("probe: statFollow did not resolve the symlink");
    {
        // The raw (lstat) stat sees the link itself — the identity that
        // would silently never change when the target is rewritten.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const raw = fs.statPath(arena.allocator(), link) catch failErr("probe: lstat link", fs.lastErr());
        if (!std.mem.eql(u8, raw.kind, "link")) fail("probe: symlink did not stat as a link");
        if (raw.ino == via_link.ino) fail("probe: link and target share an inode?");
    }
    // A rewrite of the target is visible THROUGH the link.
    const link_base = via_link;
    _ = fs.writeFileAtomic(doc, "four\n", null) catch failErr("probe: target rewrite", fs.lastErr());
    if (reload.compare(link_base, probeState(&fs, allocator, link)) != .replaced)
        fail("probe: a rewrite behind a symlink was invisible");

    // ── deletion, and the reappearance after it ────────────────
    const before_delete = probeState(&fs, allocator, doc);
    fs.unlink(doc) catch failErr("probe: unlink", fs.lastErr());
    const gone = probeState(&fs, allocator, doc);
    if (gone.present) fail("probe: a deleted file still reported present");
    if (reload.compare(before_delete, gone) != .deleted)
        fail("probe: a deleted file was not seen as deleted");
    // Save-as-recreate: with the file gone the editor drops its guard.
    _ = fs.writeFileAtomic(doc, "five\n", null) catch failErr("probe: recreate", fs.lastErr());
    expectText(doc, "five\n", "probe: recreated content");
    if (reload.compare(gone, probeState(&fs, allocator, doc)) != .reappeared)
        fail("probe: a recreated file was not seen as reappearing");

    std.debug.print("smoke-fs: external-change probe (" ++ tag ++ ") OK\n", .{});
}

/// The atomic-save primitive an editor saves through: staged temp →
/// mode/owner inheritance → fsync → rename → parent fsync, with the
/// destination's mtime_ns as the external-modification guard.
fn saveStage(allocator: std.mem.Allocator, sock_path: []const u8, comptime tag: []const u8) void {
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf, tag ++ "-save");
    var fs = fsdrive.Fs.connect(allocator, sock_path) catch fail("save: fs connect");
    defer fs.deinit();

    // Each path gets its OWN buffer: a shared one silently re-points
    // every earlier slice the moment the next path is formatted.
    var script_buf: [4096]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf, "{s}/run.sh", .{dir}) catch unreachable;

    // ── replace an existing executable file ────────────────────
    touch(dir, "run.sh", "#!/bin/sh\nold\n");
    {
        var z: [4096]u8 = undefined;
        _ = c.chmod(pathz.pathZ(&z, script) catch fail("chmod path"), 0o755);
    }
    const first_ino = inodeOf(script);
    const baseline = mtimeNsOf(script);

    const saved = fs.writeFileAtomic(script, "#!/bin/sh\nnew\n", baseline) catch
        failErr("save: writeFileAtomic", fs.lastErr());
    expectText(script, "#!/bin/sh\nnew\n", "save: content replaced");
    // A save must not silently disarm a script: the destination's
    // permission bits are inherited by the staged file.
    if (modeOf(script) != 0o755) fail("save: destination mode not preserved");
    if (saved.mtime_ns != mtimeNsOf(script)) fail("save: reply mtime_ns is not the file's");
    if (saved.mode != 0o755 or saved.size != 14) fail("save: reply entry fields");
    if (saved.ino == 0) fail("save: reply carries no inode");
    // Atomic means a NEW inode swapped in, never a truncate in place.
    if (saved.ino == first_ino) fail("save: destination was written in place");
    if (hasStagedTemp(dir)) fail("save: staging temp survived a successful save");

    // ── the external-modification guard ────────────────────────
    {
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, script) catch fail("ext path");
        const f = c.fopen(p, "wb") orelse fail("ext open");
        _ = c.fwrite("edited elsewhere\n", 1, 17, f);
        _ = c.fclose(f);
    }
    bumpMtime(script);
    const external_ns = mtimeNsOf(script);
    if (external_ns == saved.mtime_ns) fail("save: external edit did not move mtime");

    if (fs.writeFileAtomic(script, "clobber\n", saved.mtime_ns)) |_| {
        fail("save: a stale save was accepted");
    } else |err| {
        if (err != fsdrive.Error.Conflict) fail("save: stale save failed as the wrong error");
    }
    const conflict = fs.lastConflict() orelse fail("save: conflict carried no entry");
    // The fresh entry is what lets an editor say WHAT it would have
    // overwritten without a second round trip.
    if (conflict.mtime_ns != external_ns) fail("save: conflict entry mtime is not the file's");
    if (conflict.size != 17) fail("save: conflict entry size");
    expectText(script, "edited elsewhere\n", "save: refused save left the file alone");
    if (hasStagedTemp(dir)) fail("save: refused save left its staging temp behind");

    // Re-saving against the FRESH baseline (an editor reloading and
    // trying again) goes through.
    _ = fs.writeFileAtomic(script, "reconciled\n", conflict.mtime_ns) catch
        failErr("save: reconciled save", fs.lastErr());
    expectText(script, "reconciled\n", "save: reconciled content");

    // ── brand-new file: no destination, no baseline ────────────
    var fresh_buf: [4096]u8 = undefined;
    const fresh = std.fmt.bufPrint(&fresh_buf, "{s}/fresh.txt", .{dir}) catch unreachable;
    const created = fs.writeFileAtomic(fresh, "hello editor\n", null) catch
        failErr("save: create", fs.lastErr());
    expectText(fresh, "hello editor\n", "save: created content");
    if (created.size != 13) fail("save: created size");
    if (modeOf(fresh) != 0o644) fail("save: created mode");
    if (hasStagedTemp(dir)) fail("save: create left a staging temp");

    // A guarded save of a file that does NOT exist installs: there is
    // nothing to conflict with.
    var guarded_buf: [4096]u8 = undefined;
    const guarded = std.fmt.bufPrint(&guarded_buf, "{s}/guarded.txt", .{dir}) catch unreachable;
    _ = fs.writeFileAtomic(guarded, "x\n", 12345) catch
        failErr("save: guarded create", fs.lastErr());
    expectText(guarded, "x\n", "save: guarded create content");

    // ── multi-chunk payload (the staged write loops) ───────────
    var big_buf: [4096]u8 = undefined;
    const big_path = std.fmt.bufPrint(&big_buf, "{s}/big.bin", .{dir}) catch unreachable;
    const big = allocator.alloc(u8, fsdrive.SAVE_CHUNK + 4096) catch fail("save: oom");
    defer allocator.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i *% 17 +% 3);
    const big_saved = fs.writeFileAtomic(big_path, big, null) catch
        failErr("save: chunked", fs.lastErr());
    if (big_saved.size != big.len) fail("save: chunked size");
    {
        var back: std.ArrayList(u8) = .empty;
        defer back.deinit(allocator);
        var off: u64 = 0;
        while (true) {
            const info = fs.read(big_path, off, 1 << 20, &back) catch failErr("save: chunk read", fs.lastErr());
            off = back.items.len;
            if (info.eof) break;
        }
        if (!std.mem.eql(u8, back.items, big)) fail("save: chunked bytes mismatch");
    }

    // ── read carries the identity a save is guarded on ─────────
    {
        var back: std.ArrayList(u8) = .empty;
        defer back.deinit(allocator);
        const info = fs.read(script, 0, 1 << 20, &back) catch failErr("save: read", fs.lastErr());
        if (!info.eof) fail("save: read not eof");
        if (info.mtime_ns != mtimeNsOf(script)) fail("save: read reply mtime_ns wrong");
        if (info.ino != inodeOf(script)) fail("save: read reply ino wrong");
        // The whole point: what read handed back can be saved against.
        _ = fs.writeFileAtomic(script, "round trip\n", info.mtime_ns) catch
            failErr("save: save against read baseline", fs.lastErr());
    }

    // ── install's own contract: a refused install leaves the
    // staged file alone (the caller owns it) ───────────────────
    {
        var staged_buf: [4096]u8 = undefined;
        const staged = std.fmt.bufPrint(&staged_buf, "{s}/staged.tmp", .{dir}) catch unreachable;
        _ = fs.write(staged, 0, "staged bytes\n", .{ .create = true, .truncate = true }) catch
            failErr("save: stage write", fs.lastErr());
        const dest = fresh;
        if (fs.install(staged, dest, 1)) |_| {
            fail("save: install ignored a stale baseline");
        } else |err| {
            if (err != fsdrive.Error.Conflict) fail("save: install conflict is the wrong error");
        }
        if (!exists(staged)) fail("save: install consumed the staged file on refusal");
        expectText(dest, "hello editor\n", "save: refused install left the destination alone");
        fs.unlink(staged) catch failErr("save: unlink staged", fs.lastErr());

        // A directory is not something to install.
        if (fs.install(dir, dest, null)) |_| {
            fail("save: installed a directory");
        } else |err| {
            if (err != fsdrive.Error.FsOpFailed) fail("save: directory install wrong error");
        }
    }

    std.debug.print("smoke-fs: atomic save (" ++ tag ++ ") OK\n", .{});
}

/// Outcome of a job whose payload is a stream of non-progress events
/// (git_status "match", diff "line"), which JobOutcome ignores.
const StreamOutcome = struct {
    outcome: JobOutcome,
    matches: usize = 0,
    lines: usize = 0,
    /// Whether any "match" event named this path (git_status) — set by
    /// collectStream's caller-supplied name.
    saw_name: bool = false,
    /// First diff line whose text starts with '+' (content, not the
    /// +++ header) — proof diff actually ran rather than silently
    /// producing nothing.
    saw_added_line: bool = false,
    /// git_status: every match, keyed by path, plus the one repo
    /// event. Bounded so a runaway stream cannot grow the rig.
    records: [64]GitRecord = undefined,
    record_count: usize = 0,
    saw_repo_ev: bool = false,
    repo: GitRepo = .{},

    /// The two porcelain columns reported for `path`, or null.
    fn xyOf(self: *const StreamOutcome, path: []const u8) ?[]const u8 {
        for (self.records[0..self.record_count]) |r| {
            if (std.mem.eql(u8, r.pathText(), path)) return r.xyText();
        }
        return null;
    }

    fn origOf(self: *const StreamOutcome, path: []const u8) ?[]const u8 {
        for (self.records[0..self.record_count]) |r| {
            if (std.mem.eql(u8, r.pathText(), path)) return r.origText();
        }
        return null;
    }
};

/// One git_status match, copied out of its arena-backed event.
const GitRecord = struct {
    path: [512]u8 = undefined,
    path_len: usize = 0,
    xy: [2]u8 = .{ 0, 0 },
    xy_len: usize = 0,
    orig: [512]u8 = undefined,
    orig_len: usize = 0,

    fn pathText(self: *const GitRecord) []const u8 {
        return self.path[0..self.path_len];
    }
    fn xyText(self: *const GitRecord) []const u8 {
        return self.xy[0..self.xy_len];
    }
    fn origText(self: *const GitRecord) []const u8 {
        return self.orig[0..self.orig_len];
    }
};

/// The git_status `repo` event, copied the same way.
const GitRepo = struct {
    is_repo: bool = false,
    detached: bool = false,
    initial: bool = false,
    at_root: bool = false,
    have_ab: bool = false,
    ahead: i64 = 0,
    behind: i64 = 0,
    branch: [128]u8 = undefined,
    branch_len: usize = 0,
    upstream: [128]u8 = undefined,
    upstream_len: usize = 0,

    fn branchText(self: *const GitRepo) []const u8 {
        return self.branch[0..self.branch_len];
    }
    fn upstreamText(self: *const GitRepo) []const u8 {
        return self.upstream[0..self.upstream_len];
    }
};

fn copyInto(dst: []u8, len: *usize, src: []const u8) void {
    len.* = @min(src.len, dst.len);
    @memcpy(dst[0..len.*], src[0..len.*]);
}

fn collectStream(fs: *fsdrive.Fs, job: u64, want_name: []const u8, timeout_ms: i64) StreamOutcome {
    var out = StreamOutcome{ .outcome = .{} };
    var waited: i64 = 0;
    while (waited < timeout_ms) {
        while (fs.takeJobEvent()) |e0| {
            var e = e0;
            defer e.deinit();
            if (e.job != job) continue;
            if (std.mem.eql(u8, e.ev, "repo")) {
                out.saw_repo_ev = true;
                out.repo.is_repo = e.repo;
                out.repo.detached = e.detached;
                out.repo.initial = e.initial;
                out.repo.at_root = e.root;
                out.repo.have_ab = e.have_ab;
                out.repo.ahead = e.ahead;
                out.repo.behind = e.behind;
                copyInto(&out.repo.branch, &out.repo.branch_len, e.branch);
                copyInto(&out.repo.upstream, &out.repo.upstream_len, e.upstream);
                continue;
            }
            if (std.mem.eql(u8, e.ev, "match")) {
                out.matches += 1;
                if (want_name.len > 0 and std.mem.eql(u8, e.path, want_name)) out.saw_name = true;
                if (out.record_count < out.records.len) {
                    var r = GitRecord{};
                    copyInto(&r.path, &r.path_len, e.path);
                    copyInto(&r.xy, &r.xy_len, e.xy);
                    copyInto(&r.orig, &r.orig_len, e.orig);
                    out.records[out.record_count] = r;
                    out.record_count += 1;
                }
                continue;
            }
            if (std.mem.eql(u8, e.ev, "line")) {
                out.lines += 1;
                if (e.text.len > 1 and e.text[0] == '+' and e.text[1] != '+') out.saw_added_line = true;
                continue;
            }
            if (e.terminal()) {
                const n = @min(e.ev.len, out.outcome.ev.len);
                @memcpy(out.outcome.ev[0..n], e.ev[0..n]);
                out.outcome.ev_len = n;
                out.outcome.done = e.done;
                out.outcome.message_len = @min(e.message.len, out.outcome.message.len);
                @memcpy(out.outcome.message[0..out.outcome.message_len], e.message[0..out.outcome.message_len]);
                return out;
            }
        }
        _ = c.usleep(5_000);
        waited += 5;
    }
    fail("streamed job never reached a terminal event");
}

/// Is `name` runnable on this host? The two shell-out jobs below
/// (git_status, diff) legitimately produce nothing without their
/// binary, so their CONTENT assertions are conditional — the routing
/// assertion never is.
fn haveTool(name: []const u8) bool {
    var cmd: [128:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&cmd, "command -v {s} >/dev/null 2>&1", .{name}) catch return false;
    const fp = c.popen(z.ptr, "r") orelse return false;
    return c.pclose(fp) == 0;
}

fn runIn(dir: []const u8, command: []const u8) void {
    var cmd: [1024:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&cmd, "cd '{s}' && {s} >/dev/null 2>&1", .{ dir, command }) catch fail("shell cmd too long");
    const fp = c.popen(z.ptr, "r") orelse fail("popen");
    _ = c.pclose(fp);
}

fn fileSize(path: []const u8) u64 {
    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    if (c.lstat(pathz.pathZ(&z, path) catch return 0, &st) != 0) return 0;
    return @intCast(st.st_size);
}

/// The job verbs the GUI sends that the daemon's routing used to drop
/// into "unknown fs op": git_status, diff, split, combine,
/// secure_delete. `startX` failing at all IS the regression — the
/// routing gap made every one of these an error reply.
fn jobVerbStage(allocator: std.mem.Allocator, sock_path: []const u8, comptime tag: []const u8) void {
    var dbuf: [64]u8 = undefined;
    const dir = mkTmpDir(&dbuf, tag ++ "-verbs");
    var fs = fsdrive.Fs.connect(allocator, sock_path) catch fail("verbs fs connect");
    defer fs.deinit();
    var pb: [6][4096]u8 = undefined;

    // ── git_status ────────────────────────────────────────────
    {
        const repo = std.fmt.bufPrint(&pb[0], "{s}/repo", .{dir}) catch unreachable;
        mkdirAt(repo);
        const have_git = haveTool("git");
        if (have_git) {
            // `git init -b` needs git 2.28; the symbolic-ref does not.
            runIn(repo, "git init -q . && git symbolic-ref HEAD refs/heads/main");
            touch(repo, "tracked.txt", "one\n");
            touch(repo, "moved.txt", "content that is long enough to survive rename detection\n");
            touch(repo, "staged.txt", "one\n");
            touch(repo, ".gitignore", "ignored/\n");
            mkdirAt(std.fmt.bufPrint(&pb[1], "{s}/ignored", .{repo}) catch unreachable);
            touch(std.fmt.bufPrint(&pb[1], "{s}/ignored", .{repo}) catch unreachable, "junk.o", "x\n");
            runIn(repo, "git add -A && git -c user.email=s@x -c user.name=s commit -qm init");
            // One of every state the browser now claims to render.
            touch(repo, "untracked.txt", "new\n");
            runIn(repo, "git mv moved.txt renamed.txt");
            // Parenthesised: runIn appends its own `>/dev/null`, which
            // would otherwise win over a trailing append redirection.
            runIn(repo, "( printf 'two\\n' >> staged.txt && git add staged.txt && printf 'three\\n' >> staged.txt )");
            runIn(repo, "( printf 'edit\\n' >> tracked.txt )");
        }
        const job = fs.startGitStatus(repo) catch failErr("git_status refused", fs.lastErr());
        const out = collectStream(&fs, job, "untracked.txt", 20_000);
        if (!out.outcome.is("done")) fail("git_status outcome");
        if (have_git) {
            if (out.matches == 0) fail("git_status reported no changes in a dirty repo");
            if (!out.saw_name) fail("git_status did not name the untracked file");
            if (!out.saw_repo_ev) fail("git_status sent no repo event");
            if (!out.repo.is_repo) fail("git_status called a repository a non-repo");
            if (!out.repo.at_root) fail("git_status did not report the browsed dir as the repo root");
            if (!std.mem.eql(u8, out.repo.branchText(), "main")) fail("git_status branch name");
            if (out.repo.detached or out.repo.initial) fail("git_status branch flags");
            // Both porcelain columns, kept apart.
            const unstaged = out.xyOf("tracked.txt") orelse fail("no record for the modified file");
            if (!std.mem.eql(u8, unstaged, ".M")) fail("unstaged modification lost its column");
            const both = out.xyOf("staged.txt") orelse fail("no record for the staged file");
            if (!std.mem.eql(u8, both, "MM")) fail("staged-then-modified collapsed to one side");
            if (!std.mem.eql(u8, out.xyOf("untracked.txt") orelse "", "??")) fail("untracked columns");
            // The rename, with its source.
            const ren = out.xyOf("renamed.txt") orelse fail("no rename record");
            if (ren[0] != 'R') fail("rename not reported as a rename");
            if (!std.mem.eql(u8, out.origOf("renamed.txt") orelse "", "moved.txt")) fail("rename lost its source path");
            // The ignored directory, collapsed to one record.
            if (out.xyOf("ignored/") == null) fail("no ignored record");
        }

        // A detached HEAD, and a directory that is not a repository at
        // all -- which must be distinguishable from a clean one.
        if (have_git) {
            runIn(repo, "git checkout -q --detach HEAD");
            const djob = fs.startGitStatus(repo) catch failErr("git_status (detached) refused", fs.lastErr());
            const dout = collectStream(&fs, djob, "", 20_000);
            if (!dout.outcome.is("done")) fail("git_status (detached) outcome");
            if (!dout.repo.is_repo or !dout.repo.detached) fail("detached HEAD not reported");
            if (dout.repo.branch_len != 0) fail("detached HEAD reported a branch name");
        }
        {
            const plain = std.fmt.bufPrint(&pb[1], "{s}/plain", .{dir}) catch unreachable;
            mkdirAt(plain);
            const pjob = fs.startGitStatus(plain) catch failErr("git_status (non-repo) refused", fs.lastErr());
            const pout = collectStream(&fs, pjob, "", 20_000);
            if (!pout.outcome.is("done")) fail("git_status (non-repo) outcome");
            if (pout.matches != 0) fail("git_status found changes outside a repository");
            if (have_git) {
                if (!pout.saw_repo_ev) fail("git_status sent no repo event outside a repository");
                if (pout.repo.is_repo) fail("git_status called a plain directory a repository");
            }
        }
    }

    // ── git_diff (the editor gutter's verb) ───────────────────
    {
        const repo = std.fmt.bufPrint(&pb[0], "{s}/gutter", .{dir}) catch unreachable;
        mkdirAt(repo);
        const have_git = haveTool("git");
        const tracked = std.fmt.bufPrint(&pb[1], "{s}/src/main.txt", .{repo}) catch unreachable;
        const sub = std.fmt.bufPrint(&pb[2], "{s}/src", .{repo}) catch unreachable;
        const untracked = std.fmt.bufPrint(&pb[3], "{s}/src/new.txt", .{repo}) catch unreachable;
        const clean = std.fmt.bufPrint(&pb[4], "{s}/src/clean.txt", .{repo}) catch unreachable;
        mkdirAt(sub);
        if (have_git) {
            runIn(repo, "git init -q . && git symbolic-ref HEAD refs/heads/main");
            touch(sub, "main.txt", "a\nb\nc\nd\n");
            touch(sub, "clean.txt", "untouched\n");
            runIn(repo, "git add -A && git -c user.email=s@x -c user.name=s commit -qm init");
            // One replaced line and two appended ones: the shape a
            // gutter must tell apart, and the reason the daemon
            // parses rather than counts.
            touch(sub, "main.txt", "a\nB\nc\nd\ne\nf\n");
            touch(sub, "new.txt", "brand\nnew\n");
        }

        // Routing first: the verb must be reachable at all.
        const job = fs.startGitDiff(tracked) catch failErr("git_diff refused", fs.lastErr());
        const out = collectStream(&fs, job, "", 20_000);
        if (!out.outcome.is("done")) fail("git_diff outcome");

        if (have_git) {
            const res = fs.gitDiff(allocator, tracked, 20_000) catch failErr("git_diff (collect) failed", fs.lastErr());
            defer allocator.free(res.runs);
            if (!res.repo) fail("git_diff called a repository file untracked by a repo");
            if (!res.tracked) fail("git_diff called a committed file untracked");
            if (res.initial) fail("git_diff called a repo with a commit initial");
            if (res.runs.len != 2) fail("git_diff did not fold the change into two runs");
            if (res.runs[0].line != 1 or res.runs[0].count != 1 or res.runs[0].kind != .modified)
                fail("git_diff lost the replaced line");
            if (res.runs[1].line != 4 or res.runs[1].count != 2 or res.runs[1].kind != .added)
                fail("git_diff did not collapse the two appended lines into one run");

            // An untracked file inside the repo: known repo, no diff.
            const ur = fs.gitDiff(allocator, untracked, 20_000) catch failErr("git_diff (untracked) failed", fs.lastErr());
            defer allocator.free(ur.runs);
            if (!ur.repo) fail("git_diff lost the repo for an untracked file");
            if (ur.tracked) fail("git_diff called an untracked file tracked");
            if (ur.runs.len != 0) fail("git_diff invented runs for an untracked file");

            // A committed file nobody touched: tracked, clean, and
            // that is an ANSWER — not the same as "unknown".
            const cr = fs.gitDiff(allocator, clean, 20_000) catch failErr("git_diff (clean) failed", fs.lastErr());
            defer allocator.free(cr.runs);
            if (!cr.repo or !cr.tracked) fail("git_diff clean-file flags");
            if (cr.runs.len != 0) fail("git_diff found changes in an untouched file");

            // A repository whose HEAD has no commit: there is nothing
            // to diff against, which the gutter renders as all-added.
            const fresh = std.fmt.bufPrint(&pb[5], "{s}/fresh", .{dir}) catch unreachable;
            mkdirAt(fresh);
            runIn(fresh, "git init -q .");
            touch(fresh, "first.txt", "hello\n");
            runIn(fresh, "git add first.txt");
            var fpath_buf: [4096]u8 = undefined;
            const fpath = std.fmt.bufPrint(&fpath_buf, "{s}/first.txt", .{fresh}) catch unreachable;
            const fr = fs.gitDiff(allocator, fpath, 20_000) catch failErr("git_diff (initial) failed", fs.lastErr());
            defer allocator.free(fr.runs);
            if (!fr.repo or !fr.tracked) fail("git_diff initial-repo flags");
            if (!fr.initial) fail("git_diff did not report a commit-less repository as initial");
        }

        // Outside a repository: repo=false, which the caller must read
        // as UNKNOWN rather than clean.
        {
            const loose = std.fmt.bufPrint(&pb[1], "{s}/loose.txt", .{dir}) catch unreachable;
            touch(dir, "loose.txt", "no repo here\n");
            const lr = fs.gitDiff(allocator, loose, 20_000) catch failErr("git_diff (non-repo) failed", fs.lastErr());
            defer allocator.free(lr.runs);
            if (have_git and lr.repo) fail("git_diff called a plain directory a repository");
            if (lr.runs.len != 0) fail("git_diff produced runs outside a repository");
        }
    }

    // ── diff ──────────────────────────────────────────────────
    {
        const a = std.fmt.bufPrint(&pb[0], "{s}/a.txt", .{dir}) catch unreachable;
        const b = std.fmt.bufPrint(&pb[1], "{s}/b.txt", .{dir}) catch unreachable;
        const same = std.fmt.bufPrint(&pb[2], "{s}/same.txt", .{dir}) catch unreachable;
        touch(dir, "a.txt", "alpha\nbeta\n");
        touch(dir, "b.txt", "alpha\ngamma\n");
        touch(dir, "same.txt", "alpha\nbeta\n");
        const have_diff = haveTool("diff");
        const job = fs.startDiff(a, b) catch failErr("diff refused", fs.lastErr());
        const out = collectStream(&fs, job, "", 20_000);
        if (!out.outcome.is("done")) fail("diff outcome");
        if (have_diff) {
            if (out.lines == 0) fail("diff of differing files produced no lines");
            if (!out.saw_added_line) fail("diff never emitted an added line");
            // Identical files: a clean, EMPTY diff (not an error).
            const same_job = fs.startDiff(a, same) catch failErr("diff (identical) refused", fs.lastErr());
            const same_out = collectStream(&fs, same_job, "", 20_000);
            if (!same_out.outcome.is("done")) fail("identical diff outcome");
            if (same_out.lines != 0) fail("identical files produced diff lines");
        }
    }

    // ── split + combine round-trip ────────────────────────────
    {
        const src = std.fmt.bufPrint(&pb[0], "{s}/blob.bin", .{dir}) catch unreachable;
        writePattern(src, 1000, 11);
        const src_hash = fileSha(src) orelse fail("split src hash");
        const job = fs.startSplit(src, "400") catch failErr("split refused", fs.lastErr());
        const out = collectJob(&fs, job, 20_000);
        if (!out.is("done")) failErr("split outcome", out.messageText());
        if (out.done != 1000) fail("split done bytes");
        const p1 = std.fmt.bufPrint(&pb[1], "{s}.001", .{src}) catch unreachable;
        const p2 = std.fmt.bufPrint(&pb[2], "{s}.002", .{src}) catch unreachable;
        const p3 = std.fmt.bufPrint(&pb[3], "{s}.003", .{src}) catch unreachable;
        const p4 = std.fmt.bufPrint(&pb[4], "{s}.004", .{src}) catch unreachable;
        if (fileSize(p1) != 400 or fileSize(p2) != 400 or fileSize(p3) != 200) fail("split part sizes");
        if (exists(p4)) fail("split made a spurious fourth part");

        // Combine needs its destination free — the parts rebuild it.
        {
            var z: [4096]u8 = undefined;
            _ = c.unlink(pathz.pathZ(&z, src) catch unreachable);
        }
        const cjob = fs.startCombine(p1) catch failErr("combine refused", fs.lastErr());
        const cout = collectJob(&fs, cjob, 20_000);
        if (!cout.is("done")) failErr("combine outcome", cout.messageText());
        if (cout.done != 1000) fail("combine done bytes");
        const back = fileSha(src) orelse fail("combined file missing");
        if (!std.mem.eql(u8, &back, &src_hash)) fail("combine content mismatch");
    }

    // ── secure_delete ─────────────────────────────────────────
    {
        const victim = std.fmt.bufPrint(&pb[0], "{s}/secret.bin", .{dir}) catch unreachable;
        writePattern(victim, 4096, 23);
        const job = fs.startSecureDelete(victim) catch failErr("secure_delete refused", fs.lastErr());
        const out = collectJob(&fs, job, 20_000);
        if (!out.is("done")) failErr("secure_delete outcome", out.messageText());
        if (out.done != 4096) fail("secure_delete done bytes");
        if (exists(victim)) fail("secure_delete left the file behind");

        // A directory is not shreddable — an honest error, not a hang.
        const subdir = std.fmt.bufPrint(&pb[1], "{s}/adir", .{dir}) catch unreachable;
        mkdirAt(subdir);
        const djob = fs.startSecureDelete(subdir) catch failErr("secure_delete (dir) refused", fs.lastErr());
        const dout = collectJob(&fs, djob, 20_000);
        if (!dout.is("error")) fail("secure_delete accepted a directory");
        if (!exists(subdir)) fail("secure_delete removed a directory it refused");
    }

    std.debug.print("smoke-fs: job verbs (" ++ tag ++ ") OK\n", .{});
}

fn sigNoop(_: c_int) callconv(.c) void {}

pub fn main(init: std.process.Init.Minimal) u8 {
    // The daemon spawns job helpers by re-exec'ing ITSELF with --job;
    // in this smoke "itself" is the smoke binary, so serve the mode.
    const argv = init.args.vector;
    if (argv.len > 1 and std.mem.eql(u8, std.mem.span(argv[1]), "--job")) {
        var helper_gpa: std.heap.DebugAllocator(.{}) = .{};
        defer _ = helper_gpa.deinit();
        return fsjob.serve(helper_gpa.allocator());
    }
    // The cross-host stage's fake ssh: stdio <-> a daemon socket, the
    // job `sketerm-mux --proxy` does on a real remote.
    if (argv.len > 2 and std.mem.eql(u8, std.mem.span(argv[1]), "--bridge")) {
        const die_after: u64 = if (argv.len > 3)
            std.fmt.parseInt(u64, std.mem.span(argv[3]), 10) catch 0
        else
            0;
        return bridgeMain(std.mem.span(argv[2]), die_after);
    }

    // A daemon-thread write racing a closed client socket (the abrupt-
    // death stage does this on purpose) must surface as EPIPE, not
    // kill the process.
    _ = c.signal(c.SIGPIPE, &sigNoop);
    // Media extraction caches under the daemon host's state dir; point
    // it at a private directory so a smoke run never touches (or is
    // confused by) the real user cache. Job helpers inherit this.
    var media_cache_buf: [128:0]u8 = undefined;
    const media_cache = std.fmt.bufPrintZ(&media_cache_buf, "/tmp/sketerm-smoke-fs-media-{d}", .{c.getpid()}) catch unreachable;
    _ = c.setenv("SKETERM_MEDIA_CACHE_DIR", media_cache.ptr, 1);
    // Image previews install freedesktop thumbnail-cache entries under
    // XDG_CACHE_HOME; keep those out of the real user cache too.
    var thumb_cache_buf: [128:0]u8 = undefined;
    const thumb_cache = std.fmt.bufPrintZ(&thumb_cache_buf, "/tmp/sketerm-smoke-fs-cache-{d}", .{c.getpid()}) catch unreachable;
    _ = c.setenv("XDG_CACHE_HOME", thumb_cache.ptr, 1);
    // Fs-job journals live under the STATE dir now (reboot-durable
    // resume); isolate it or smoke daemons would journal into the real
    // ~/.local/state and adopt each other's records across runs.
    var state_buf: [128:0]u8 = undefined;
    const state_dir = std.fmt.bufPrintZ(&state_buf, "/tmp/sketerm-smoke-fs-state-{d}", .{c.getpid()}) catch unreachable;
    _ = c.setenv("XDG_STATE_HOME", state_dir.ptr, 1);
    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("smoke-fs: FAIL — leaked memory (see GPA report above)\n", .{});
        std.process.exit(1);
    };
    const allocator = gpa_state.allocator();

    // ── monolith pass ──────────────────────────────────────────
    var path_buf: [128]u8 = undefined;
    const sock_path = std.fmt.bufPrint(&path_buf, "/tmp/sketerm-smoke-fs-{d}/mux.sock", .{c.getpid()}) catch unreachable;
    const d = daemon_mod.Daemon.init(allocator, sock_path) catch fail("daemon init");
    const th = std.Thread.spawn(.{}, daemonMain, .{d}) catch fail("thread spawn");
    fsStage(allocator, sock_path, "mono");
    jobStage(allocator, sock_path, "mono");
    policyStage(allocator, sock_path, "mono");
    mediaStage(allocator, sock_path, "mono");
    queryStage(allocator, sock_path, "mono");
    saveStage(allocator, sock_path, "mono");
    probeStage(allocator, sock_path, "mono");
    jobVerbStage(allocator, sock_path, "mono");
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("shutdown connect");
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch fail("shutdown send");
    }
    th.join();
    d.deinit();

    // ── cross-daemon transfer pass (two daemons at once: A is the
    // source host, B the destination; the client mediates) ─────
    var xa_buf: [128]u8 = undefined;
    var xb_buf: [128]u8 = undefined;
    const sock_xa = std.fmt.bufPrint(&xa_buf, "/tmp/sketerm-smoke-fs-xa{d}/mux.sock", .{c.getpid()}) catch unreachable;
    // B sits at the DEFAULT local-daemon path under its runtime dir:
    // the cross stage's "local destination" resolves it exactly the way
    // a real client does ($XDG_RUNTIME_DIR/sketerm/mux.sock). Anywhere
    // else and connectLocalAutostart silently spawns whatever
    // `sketerm-mux` is INSTALLED, and the stage tests the wrong binary.
    const sock_xb = std.fmt.bufPrint(&xb_buf, "/tmp/sketerm-smoke-fs-xb{d}/sketerm/mux.sock", .{c.getpid()}) catch unreachable;
    // Daemon.init mkdirs only the socket's immediate parent.
    var xb_base_buf: [128]u8 = undefined;
    mkdirAt(std.fmt.bufPrint(&xb_base_buf, "/tmp/sketerm-smoke-fs-xb{d}", .{c.getpid()}) catch unreachable);
    const da = daemon_mod.Daemon.init(allocator, sock_xa) catch fail("daemon A init");
    const tha = std.Thread.spawn(.{}, daemonMain, .{da}) catch fail("thread A spawn");
    const db = daemon_mod.Daemon.init(allocator, sock_xb) catch fail("daemon B init");
    const thb = std.Thread.spawn(.{}, daemonMain, .{db}) catch fail("thread B spawn");
    xferStage(allocator, sock_xa, sock_xb);
    // Daemon-coordinated cross-host copy: B coordinates and is the
    // destination ("local"), A is the source reached through a fake
    // ssh bridge that can be made to die mid-transfer.
    {
        var exe_buf: [4096]u8 = undefined;
        const exe = @import("util/platform.zig").exePath(&exe_buf) orelse fail("own exe path");
        const sk_dir = std.fs.path.dirname(sock_xb) orelse fail("dst sketerm dir");
        const dst_runtime = std.fs.path.dirname(sk_dir) orelse fail("dst runtime dir");
        crossStage(allocator, exe, sock_xa, dst_runtime, sock_xb);
    }
    inline for (.{ sock_xa, sock_xb }) |sp| {
        var conn = client_mod.Conn.connect(allocator, sp) catch fail("xfer shutdown connect");
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch fail("xfer shutdown send");
    }
    tha.join();
    da.deinit();
    thb.join();
    db.deinit();

    // ── broker pass (same fs surface served by a broker-mode
    // daemon: fs clients never attach, so the broker itself must
    // answer — a monolith-only green would hide a handoff bug) ──
    var bpath_buf: [128]u8 = undefined;
    const bsock = std.fmt.bufPrint(&bpath_buf, "/tmp/sketerm-smoke-fs-b{d}/mux.sock", .{c.getpid()}) catch unreachable;
    const bd = daemon_mod.Daemon.init(allocator, bsock) catch fail("broker init");
    bd.is_broker = true;
    const bth = std.Thread.spawn(.{}, daemonMain, .{bd}) catch fail("broker thread");
    fsStage(allocator, bsock, "broker");
    jobStage(allocator, bsock, "broker");
    policyStage(allocator, bsock, "broker");
    mediaStage(allocator, bsock, "broker");
    queryStage(allocator, bsock, "broker");
    saveStage(allocator, bsock, "broker");
    probeStage(allocator, bsock, "broker");
    jobVerbStage(allocator, bsock, "broker");
    {
        var conn = client_mod.Conn.connect(allocator, bsock) catch fail("broker shutdown connect");
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch fail("broker shutdown send");
    }
    bth.join();
    bd.deinit();

    std.debug.print("smoke-fs: OK\n", .{});
    return 0;
}

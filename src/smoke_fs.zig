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
const fsserve = @import("mux/fsserve.zig");
const pathz = @import("util/pathz.zig");

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
    return std.mem.span(@as([*:0]u8, @ptrCast(p)));
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
    l.deinit();

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
    if (!dlog.expectSized(&fs, 1, "a.txt", 13)) fail("write delta never reached final size");

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

    std.debug.print("smoke-fs: {s} stage ok\n", .{tag});
}

fn sigNoop(_: c_int) callconv(.c) void {}

pub fn main() u8 {
    // A daemon-thread write racing a closed client socket (the abrupt-
    // death stage does this on purpose) must surface as EPIPE, not
    // kill the process.
    _ = c.signal(c.SIGPIPE, &sigNoop);
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
    {
        var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("shutdown connect");
        defer conn.deinit();
        conn.sendFrame(.shutdown, "") catch fail("shutdown send");
    }
    th.join();
    d.deinit();

    // ── broker pass (same fs surface served by a broker-mode
    // daemon: fs clients never attach, so the broker itself must
    // answer — a monolith-only green would hide a handoff bug) ──
    var bpath_buf: [128]u8 = undefined;
    const bsock = std.fmt.bufPrint(&bpath_buf, "/tmp/sketerm-smoke-fs-b{d}/mux.sock", .{c.getpid()}) catch unreachable;
    const bd = daemon_mod.Daemon.init(allocator, bsock) catch fail("broker init");
    bd.is_broker = true;
    const bth = std.Thread.spawn(.{}, daemonMain, .{bd}) catch fail("broker thread");
    fsStage(allocator, bsock, "broker");
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

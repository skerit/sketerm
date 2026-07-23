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
const pathz = @import("util/pathz.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

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

    fn is(self: *const JobOutcome, ev: []const u8) bool {
        return std.mem.eql(u8, self.ev[0..self.ev_len], ev);
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
            if (std.mem.eql(u8, e.ev, "progress")) {
                out.progress_events += 1;
                continue;
            }
            if (e.terminal()) {
                const n = @min(e.ev.len, out.ev.len);
                @memcpy(out.ev[0..n], e.ev[0..n]);
                out.ev_len = n;
                out.done = e.done;
                out.resumed_from = e.resumed_from;
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

// ── cross-daemon (client-mediated) transfer stage ──────────────

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
            if (!conn.fillAvailable()) fail("xfer conn hangup");
            while (conn.takeFrame() catch null) |f| {
                defer f.deinit(allocator);
                _ = x.feed(side, f.ftype, f.payload);
            }
        }
        if (x.isTerminal()) return true;
        if (stop_after > 0 and x.progress().done >= stop_after) return false;
    }
    fail("xfer pump timed out");
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

    // ── corrupted partial: resume must FAIL the verify and delete
    // the corrupt destination (honesty over silence) ───────────
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
        if (x.ok()) fail("corrupt resume passed verification");
        if (statExists(&fsb, allocator, dst3)) fail("corrupt destination not deleted");
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
    jobStage(allocator, sock_path, "mono");
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
    const sock_xb = std.fmt.bufPrint(&xb_buf, "/tmp/sketerm-smoke-fs-xb{d}/mux.sock", .{c.getpid()}) catch unreachable;
    const da = daemon_mod.Daemon.init(allocator, sock_xa) catch fail("daemon A init");
    const tha = std.Thread.spawn(.{}, daemonMain, .{da}) catch fail("thread A spawn");
    const db = daemon_mod.Daemon.init(allocator, sock_xb) catch fail("daemon B init");
    const thb = std.Thread.spawn(.{}, daemonMain, .{db}) catch fail("thread B spawn");
    xferStage(allocator, sock_xa, sock_xb);
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

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
const imagecodec = @import("util/imagecodec.zig");
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
            if (!conn.fillAvailable()) fail("xfer conn hangup");
            while (conn.takeFrame() catch null) |f| {
                defer f.deinit(allocator);
                _ = x.feed(side, f.ftype, f.payload);
            }
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

    // ── clean cross-host copy ──────────────────────────────────
    _ = c.setenv("SKETERM_SSH", ssh_ok.ptr, 1);
    var out_buf: [256]u8 = undefined;
    const out_clean = std.fmt.bufPrint(&out_buf, "{s}/clean.bin", .{dst_dir}) catch unreachable;
    {
        const job = fs.startCrossCopy("ssh:127.0.0.1", big, "", out_clean, true) catch
            failErr("cross: start clean", fs.lastErr());
        const res = collectJob(&fs, job, 120_000);
        if (!res.is("done")) failErr("cross: clean copy did not finish", res.messageText());
        const got = fileSha(out_clean) orelse fail("cross: clean hash");
        if (!std.mem.eql(u8, &got, &want)) fail("cross: clean copy content mismatch");
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
        const job = fs.startCrossCopy("ssh:127.0.0.1", big, "", out_dead, true) catch
            failErr("cross: start dead", fs.lastErr());
        const res = collectJob(&fs, job, 180_000);
        if (!res.is("error")) fail("cross: an unreachable source reported success");
        // "cross-host copy failed" told a user nothing; the reason has
        // to say which side and which host.
        if (std.mem.indexOf(u8, res.messageText(), "source") == null or
            std.mem.indexOf(u8, res.messageText(), "127.0.0.1") == null)
            failErr("cross: failure reason names neither the side nor the host", res.messageText());
    }
    _ = c.unsetenv("SKETERM_SSH");
    std.debug.print("smoke-fs: cross-host copy reconnect/resume OK\n", .{});
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

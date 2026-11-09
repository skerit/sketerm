//! Files dropped from another application (a GdkFileList), opened by a
//! face only once each is known not to be a folder, without blocking
//! the main loop.
//!
//! The editor and viewer used to ask `g_file_query_file_type` inside
//! their drop handlers: a synchronous stat on the GTK main thread, which
//! froze the window on a hung network mount or a slow FUSE path. A drop
//! now starts one `Job` that asks GIO for each path's `standard::type`
//! asynchronously (GIO's worker pool does the stat), one path at a time
//! in drop order, and hands each non-folder to the face as soon as its
//! answer lands, so files still open in the order they were dropped. A
//! failed query opens the path anyway, exactly as the synchronous call's
//! UNKNOWN answer did: the load then reports why it cannot be read.
//!
//! GIO rather than the daemon: the paths are the GUI host's own, named
//! by GTK, and the daemon serves `stat` inline in its single poll loop,
//! so a hung mount there would freeze every session, and a path on a
//! sketerm FUSE mount this process serves could deadlock against it.
//!
//! Lifetime: a liveness fence (CLAUDE.md mechanism 3). The face owns an
//! `Owner`; every job holds a reference, and each GIO callback resolves
//! the face through `Owner.ctx`, which `sever` clears at the face's
//! teardown while cancelling the in-flight query. GIO always delivers
//! the callback, cancelled or not, and the job frees itself there.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");

/// `.first` opens only the first non-folder, and a newer drop
/// supersedes an unfinished one (the viewer shows one file); `.all`
/// opens every non-folder and lets drops run side by side (the editor).
pub const Mode = enum { all, first };

/// What the type query said about one path.
pub const Kind = enum { directory, other, unknown };

/// Which dropped path to query next and whether its answer opens it.
pub const Plan = struct {
    len: usize,
    mode: Mode,
    cursor: usize = 0,
    opened: usize = 0,

    pub fn next(self: *const Plan) ?usize {
        if (self.mode == .first and self.opened > 0) return null;
        if (self.cursor >= self.len) return null;
        return self.cursor;
    }

    /// Record the answer for `next()`'s path; true when it opens.
    pub fn record(self: *Plan, kind: Kind) bool {
        self.cursor += 1;
        if (kind == .directory) return false;
        self.opened += 1;
        return true;
    }
};

/// Called for each path that opens; `nth` counts this job's opens from 0.
pub const OnFile = *const fn (ctx: *anyopaque, path: [:0]const u8, nth: usize) void;

pub const Owner = struct {
    allocator: std.mem.Allocator,
    refs: u32 = 1,
    /// The face; null once severed.
    ctx: ?*anyopaque,
    on_file: OnFile,
    mode: Mode,
    /// Cancelled by `sever`, and in `.first` mode replaced by every drop.
    cancellable: *c.GCancellable,

    pub fn create(allocator: std.mem.Allocator, ctx: *anyopaque, on_file: OnFile, mode: Mode) !*Owner {
        const self = try allocator.create(Owner);
        const cancellable = c.g_cancellable_new() orelse {
            allocator.destroy(self);
            return error.OutOfMemory;
        };
        self.* = .{ .allocator = allocator, .ctx = ctx, .on_file = on_file, .mode = mode, .cancellable = cancellable };
        return self;
    }

    /// The face's teardown; idempotent. Pending jobs deliver nothing.
    pub fn sever(self: *Owner) void {
        if (self.ctx == null) return;
        self.ctx = null;
        c.g_cancellable_cancel(self.cancellable);
        self.unref();
    }

    /// Retire every pending job: nothing it has not opened yet will be.
    /// False (and nothing retired) only when GIO cannot allocate.
    pub fn cancelPending(self: *Owner) bool {
        const fresh = c.g_cancellable_new() orelse return false;
        c.g_cancellable_cancel(self.cancellable);
        c.g_object_unref(self.cancellable);
        self.cancellable = fresh;
        return true;
    }

    fn unref(self: *Owner) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        c.g_object_unref(self.cancellable);
        self.allocator.destroy(self);
    }
};

/// Live jobs in this process; tests use it to prove every job freed itself.
var live_jobs: usize = 0;

const Job = struct {
    owner: *Owner,
    /// The owner's cancellable when this job started (a `.first` drop
    /// replaces the owner's, cancelling this one).
    cancellable: *c.GCancellable,
    paths: [][:0]u8,
    plan: Plan,

    fn live(self: *const Job) bool {
        return self.owner.ctx != null and c.g_cancellable_is_cancelled(self.cancellable) == 0;
    }

    fn destroy(self: *Job) void {
        const a = self.owner.allocator;
        for (self.paths) |p| a.free(p);
        a.free(self.paths);
        c.g_object_unref(self.cancellable);
        self.owner.unref();
        a.destroy(self);
        live_jobs -= 1;
    }
};

/// Start resolving `flist`'s local paths for `owner`'s face. Returns
/// whether there was anything to resolve (non-local URIs have no path
/// and are skipped); nothing opens before this returns.
pub fn start(owner: *Owner, flist: ?*c.GdkFileList) bool {
    if (owner.ctx == null) return false;
    // get_files is transfer-container: free the list, not the GFiles.
    const files = c.gdk_file_list_get_files(flist);
    defer c.g_slist_free(files);
    var list: std.ArrayList([:0]u8) = .empty;
    var node = files;
    while (node != null) : (node = node.*.next) {
        const path_c = c.g_file_get_path(@ptrCast(node.*.data)) orelse continue;
        defer c.g_free(path_c);
        const path = std.mem.span(@as([*:0]const u8, @ptrCast(path_c)));
        if (path.len == 0) continue;
        const owned = owner.allocator.dupeSentinel(u8, path, 0) catch continue;
        list.append(owner.allocator, owned) catch owner.allocator.free(owned);
    }
    return startPaths(owner, &list);
}

/// `start` over already-collected paths; takes ownership of `list`.
fn startPaths(owner: *Owner, list: *std.ArrayList([:0]u8)) bool {
    const a = owner.allocator;
    const paths = list.toOwnedSlice(a) catch {
        for (list.items) |p| a.free(p);
        list.deinit(a);
        return false;
    };
    if (paths.len == 0) {
        a.free(paths);
        return false;
    }
    const job = a.create(Job) catch {
        for (paths) |p| a.free(p);
        a.free(paths);
        return false;
    };
    // In `.first` mode the newest drop wins.
    if (owner.mode == .first and !owner.cancelPending()) {
        for (paths) |p| a.free(p);
        a.free(paths);
        a.destroy(job);
        return false;
    }
    owner.refs += 1;
    live_jobs += 1;
    job.* = .{
        .owner = owner,
        .cancellable = @ptrCast(@alignCast(c.g_object_ref(owner.cancellable))),
        .paths = paths,
        .plan = .{ .len = paths.len, .mode = owner.mode },
    };
    queryNext(job);
    return true;
}

fn queryNext(job: *Job) void {
    if (!job.live()) return job.destroy();
    const i = job.plan.next() orelse return job.destroy();
    const file = c.g_file_new_for_path(job.paths[i].ptr);
    // The task holds its own reference to the file.
    defer c.g_object_unref(file);
    c.g_file_query_info_async(
        file,
        c.G_FILE_ATTRIBUTE_STANDARD_TYPE,
        c.G_FILE_QUERY_INFO_NONE,
        c.G_PRIORITY_DEFAULT,
        job.cancellable,
        @ptrCast(&onInfo),
        job,
    );
}

fn onInfo(source: ?*c.GObject, result: ?*c.GAsyncResult, user: ?*anyopaque) callconv(.c) void {
    const job = cast.userData(Job, user);
    var err: ?*c.GError = null;
    const info = c.g_file_query_info_finish(@ptrCast(source), result, @ptrCast(&err));
    var kind: Kind = .unknown;
    if (info) |i| {
        kind = if (c.g_file_info_get_file_type(i) == c.G_FILE_TYPE_DIRECTORY) .directory else .other;
        c.g_object_unref(i);
    }
    if (err) |e| c.g_error_free(e);
    if (!job.live()) return job.destroy();
    const i = job.plan.cursor;
    if (job.plan.record(kind)) job.owner.on_file(job.owner.ctx.?, job.paths[i], job.plan.opened - 1);
    queryNext(job);
}

// ======================================================================
// Tests
// ======================================================================

test "Plan: drop order, folders skipped, failed queries still open" {
    var plan: Plan = .{ .len = 4, .mode = .all };
    var opened: [4]usize = undefined;
    var n: usize = 0;
    const answers = [_]Kind{ .other, .directory, .unknown, .other };
    while (plan.next()) |i| {
        if (plan.record(answers[i])) {
            opened[n] = i;
            n += 1;
        }
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 3 }, opened[0..n]);
}

test "Plan: first mode stops querying at the first file" {
    var plan: Plan = .{ .len = 4, .mode = .first };
    var queried: usize = 0;
    const answers = [_]Kind{ .directory, .other, .other, .other };
    var first: ?usize = null;
    while (plan.next()) |i| {
        queried += 1;
        if (plan.record(answers[i])) first = i;
    }
    try std.testing.expectEqual(@as(?usize, 1), first);
    try std.testing.expectEqual(@as(usize, 2), queried);
}

test "Plan: nothing but folders opens nothing" {
    var plan: Plan = .{ .len = 2, .mode = .first };
    while (plan.next()) |_| try std.testing.expect(!plan.record(.directory));
    try std.testing.expectEqual(@as(usize, 0), plan.opened);
}

const TestSink = struct {
    got: std.ArrayList([]u8) = .empty,
    bad_nth: bool = false,

    fn onFile(ctx: *anyopaque, path: [:0]const u8, nth: usize) void {
        const self = cast.userData(TestSink, ctx);
        if (nth != self.got.items.len) self.bad_nth = true;
        const base = std.fs.path.basename(path);
        self.got.append(std.testing.allocator, std.testing.allocator.dupe(u8, base) catch return) catch {};
    }

    fn deinit(self: *TestSink) void {
        for (self.got.items) |s| std.testing.allocator.free(s);
        self.got.deinit(std.testing.allocator);
    }
};

/// A scratch dir holding `b.txt`, `folder/` and `a.txt`; returns its path.
fn makeTree(buf: *[64:0]u8) ![:0]const u8 {
    const tmpl = "/tmp/sk-filedrop-XXXXXX";
    @memcpy(buf[0..tmpl.len], tmpl);
    buf[tmpl.len] = 0;
    if (c.mkdtemp(buf[0..].ptr) == null) return error.SkipZigTest;
    const dir = buf[0..tmpl.len :0];
    var p: [128:0]u8 = undefined;
    for ([_][]const u8{ "b.txt", "a.txt" }) |name| {
        const z = try std.fmt.bufPrintSentinel(&p, "{s}/{s}", .{ dir, name }, 0);
        const f = c.fopen(z.ptr, "wb") orelse return error.SkipZigTest;
        _ = c.fclose(f);
    }
    const sub = try std.fmt.bufPrintSentinel(&p, "{s}/folder", .{dir}, 0);
    if (c.mkdir(sub.ptr, 0o700) != 0) return error.SkipZigTest;
    return dir;
}

fn removeTree(dir: [:0]const u8) void {
    var p: [128:0]u8 = undefined;
    for ([_][]const u8{ "b.txt", "a.txt" }) |name| {
        const z = std.fmt.bufPrintSentinel(&p, "{s}/{s}", .{ dir, name }, 0) catch continue;
        _ = c.unlink(z.ptr);
    }
    if (std.fmt.bufPrintSentinel(&p, "{s}/folder", .{dir}, 0)) |z| {
        _ = c.rmdir(z.ptr);
    } else |_| {}
    _ = c.rmdir(dir.ptr);
}

fn listOf(dir: []const u8, names: []const []const u8) !std.ArrayList([:0]u8) {
    var list: std.ArrayList([:0]u8) = .empty;
    for (names) |name| {
        const p = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/{s}", .{ dir, name }, 0);
        try list.append(std.testing.allocator, p);
    }
    return list;
}

/// Run the default main context until every job freed itself.
fn settle() !void {
    var spins: usize = 0;
    while (live_jobs > 0) : (spins += 1) {
        if (spins > 20_000) return error.Timeout;
        if (c.g_main_context_iteration(null, 0) == 0) _ = c.usleep(500);
    }
}

test "start: opens files in drop order off the main loop, folders skipped" {
    var dbuf: [64:0]u8 = undefined;
    const dir = try makeTree(&dbuf);
    defer removeTree(dir);
    var sink: TestSink = .{};
    defer sink.deinit();
    const owner = try Owner.create(std.testing.allocator, @ptrCast(&sink), TestSink.onFile, .all);
    defer owner.sever();
    var list = try listOf(dir, &.{ "b.txt", "folder", "a.txt", "missing.txt" });
    try std.testing.expect(startPaths(owner, &list));
    // The drop handler returned without one type known: no stat ran on
    // the calling (main) thread.
    try std.testing.expectEqual(@as(usize, 0), sink.got.items.len);
    try settle();
    try std.testing.expectEqual(@as(usize, 3), sink.got.items.len);
    try std.testing.expectEqualStrings("b.txt", sink.got.items[0]);
    try std.testing.expectEqualStrings("a.txt", sink.got.items[1]);
    // A path whose query fails opens anyway; its load reports why.
    try std.testing.expectEqualStrings("missing.txt", sink.got.items[2]);
    try std.testing.expect(!sink.bad_nth);
}

test "start: a severed face gets nothing and every job frees itself" {
    var dbuf: [64:0]u8 = undefined;
    const dir = try makeTree(&dbuf);
    defer removeTree(dir);
    var sink: TestSink = .{};
    defer sink.deinit();
    const owner = try Owner.create(std.testing.allocator, @ptrCast(&sink), TestSink.onFile, .all);
    var list = try listOf(dir, &.{ "b.txt", "a.txt" });
    try std.testing.expect(startPaths(owner, &list));
    owner.sever();
    owner.sever();
    try settle();
    try std.testing.expectEqual(@as(usize, 0), sink.got.items.len);
}

test "start: first mode opens one file and a newer drop supersedes" {
    var dbuf: [64:0]u8 = undefined;
    const dir = try makeTree(&dbuf);
    defer removeTree(dir);
    var sink: TestSink = .{};
    defer sink.deinit();
    const owner = try Owner.create(std.testing.allocator, @ptrCast(&sink), TestSink.onFile, .first);
    defer owner.sever();
    var older = try listOf(dir, &.{ "b.txt", "a.txt" });
    try std.testing.expect(startPaths(owner, &older));
    var newer = try listOf(dir, &.{ "folder", "a.txt", "b.txt" });
    try std.testing.expect(startPaths(owner, &newer));
    try settle();
    try std.testing.expectEqual(@as(usize, 1), sink.got.items.len);
    try std.testing.expectEqualStrings("a.txt", sink.got.items[0]);
}

test "cancelPending: a batch replaced meanwhile wins over a pending drop" {
    var dbuf: [64:0]u8 = undefined;
    const dir = try makeTree(&dbuf);
    defer removeTree(dir);
    var sink: TestSink = .{};
    defer sink.deinit();
    const owner = try Owner.create(std.testing.allocator, @ptrCast(&sink), TestSink.onFile, .first);
    defer owner.sever();
    var list = try listOf(dir, &.{"a.txt"});
    try std.testing.expect(startPaths(owner, &list));
    try std.testing.expect(owner.cancelPending());
    try settle();
    try std.testing.expectEqual(@as(usize, 0), sink.got.items.len);
    // The owner still serves the next drop.
    var next = try listOf(dir, &.{"b.txt"});
    try std.testing.expect(startPaths(owner, &next));
    try settle();
    try std.testing.expectEqual(@as(usize, 1), sink.got.items.len);
}

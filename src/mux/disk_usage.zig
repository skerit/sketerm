//! Iterative disk-usage scanning and hard-link-aware accounting.

const std = @import("std");
const c = @import("../c.zig").c;
const fsserve = @import("fsserve.zig");
const nowMs = @import("../util/clock.zig").nowMs;
const platform = @import("../util/platform.zig");

/// Paths stay below the helper's 32 KiB JSON-line buffer even under
/// worst-case JSON escaping.
const MAX_PATH_BYTES: usize = 4095;
const PROGRESS_MIN_MS: i64 = 500;
const PROGRESS_IDLE_MS: i64 = 1_000;
const PROGRESS_ITEMS: u64 = 256;
/// Exact totals are unbounded, but retained detail must not turn the
/// helper pipe and GUI model into a second filesystem.
const MAX_DETAIL_EVENTS: usize = 50_000;
const MAX_DIR_EVENTS: usize = MAX_DETAIL_EVENTS / 2;
/// JSON escaping can expand one byte sixfold; two heaps at this limit
/// remain comfortably below the daemon's client-backlog ceiling.
const DETAIL_PATH_BYTES: usize = 4 * 1024 * 1024;

pub const Kind = enum { file, dir, mount };

pub const Totals = struct {
    size: u64 = 0,
    allocated: u64 = 0,
    items: u64 = 0,
    errors: u64 = 0,
    skipped: u64 = 0,

    pub fn add(self: *Totals, other: Totals) void {
        self.size +|= other.size;
        self.allocated +|= other.allocated;
        self.items +|= other.items;
        self.errors +|= other.errors;
        self.skipped +|= other.skipped;
    }

    pub fn failedEntry() Totals {
        return .{ .items = 1, .errors = 1 };
    }
};

pub const Observation = struct {
    kind: enum { file, dir, other, mount },
    size: u64 = 0,
    allocated: u64 = 0,
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u64 = 1,
};

const FileId = struct { dev: u64, ino: u64 };

/// Produces one entry's direct contribution; callers aggregate it into
/// ancestors after the entry is complete.
pub const Accountant = struct {
    allocator: std.mem.Allocator,
    hard_links: std.AutoHashMapUnmanaged(FileId, void) = .empty,
    directories: std.AutoHashMapUnmanaged(FileId, void) = .empty,

    pub fn init(allocator: std.mem.Allocator) Accountant {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Accountant) void {
        self.hard_links.deinit(self.allocator);
        self.directories.deinit(self.allocator);
    }

    /// Returns false when this directory identity was already traversed.
    pub fn visitDirectory(self: *Accountant, dev: u64, ino: u64) !bool {
        const slot = try self.directories.getOrPut(self.allocator, .{ .dev = dev, .ino = ino });
        return !slot.found_existing;
    }

    pub fn account(self: *Accountant, observation: Observation) !Totals {
        switch (observation.kind) {
            .file => {
                if (observation.nlink <= 1) return .{
                    .size = observation.size,
                    .allocated = observation.allocated,
                    .items = 1,
                };
                const slot = try self.hard_links.getOrPut(self.allocator, .{
                    .dev = observation.dev,
                    .ino = observation.ino,
                });
                if (slot.found_existing) return .{ .items = 1 };
                return .{
                    .size = observation.size,
                    .allocated = observation.allocated,
                    .items = 1,
                };
            },
            .dir => return .{
                .size = observation.size,
                .allocated = observation.allocated,
                .items = 1,
            },
            .other => return .{ .items = 1 },
            .mount => return .{ .items = 1, .skipped = 1 },
        }
    }
};

pub const Usage = struct {
    path: []const u8,
    kind: Kind,
    size: u64,
    allocated: u64,
    items: u64,
    errors: u64,
    skipped: u64,
    mtime_ms: i64,
};

pub const Progress = struct {
    done: u64,
    total: u64,
    files_done: u64,
    file: []const u8,
};

pub const Event = union(enum) {
    usage: Usage,
    progress: Progress,
};

pub const Sink = struct {
    context: ?*anyopaque = null,
    on_event: ?*const fn (?*anyopaque, Event) void = null,

    fn emit(self: Sink, event: Event) void {
        if (self.on_event) |callback| callback(self.context, event);
    }
};

pub const Result = struct {
    totals: Totals,
    mtime_ms: i64,
    truncated: bool = false,
};

pub const ScanError = error{
    InvalidRoot,
    RootStatFailed,
    RootOpenFailed,
    RootNotDirectory,
    OutOfMemory,
};

pub fn shouldSkipDevice(root_dev: u64, child_dev: u64, all_filesystems: bool) bool {
    return !all_filesystems and child_dev != root_dev;
}

pub fn apparentOfStat(st: *const c.struct_stat) u64 {
    return if (st.st_size > 0) @intCast(st.st_size) else 0;
}

pub fn allocatedOfStat(st: *const c.struct_stat) u64 {
    const blocks: u64 = if (st.st_blocks > 0) @intCast(st.st_blocks) else 0;
    return std.math.mul(u64, blocks, 512) catch std.math.maxInt(u64);
}

fn observationOf(st: *const c.struct_stat, kind: @FieldType(Observation, "kind")) Observation {
    return .{
        .kind = kind,
        .size = apparentOfStat(st),
        .allocated = allocatedOfStat(st),
        .dev = @intCast(st.st_dev),
        .ino = @intCast(st.st_ino),
        .nlink = @intCast(st.st_nlink),
    };
}

fn usageOf(path: []const u8, kind: Kind, totals: Totals, mtime_ms: i64) Usage {
    return .{
        .path = path,
        .kind = kind,
        .size = totals.size,
        .allocated = totals.allocated,
        .items = totals.items,
        .errors = totals.errors,
        .skipped = totals.skipped,
        .mtime_ms = mtime_ms,
    };
}

const OpenedDir = struct {
    dir: *c.DIR,
    stat: c.struct_stat,
};

fn openDirectory(path: [:0]const u8, follow_final_symlink: bool) ?OpenedDir {
    const nofollow: c_int = if (follow_final_symlink) 0 else c.O_NOFOLLOW;
    const fd = c.open(path.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC | nofollow);
    if (fd < 0) return null;
    var owned_fd = true;
    defer {
        if (owned_fd) _ = c.close(fd);
    }

    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFDIR) return null;
    const dir = c.fdopendir(fd) orelse return null;
    owned_fd = false;
    return .{ .dir = dir, .stat = st };
}

const JoinError = error{ NameTooLong, OutOfMemory };

fn joinPath(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) JoinError![:0]u8 {
    const separator: usize = @intFromBool(parent.len == 0 or parent[parent.len - 1] != '/');
    const len = std.math.add(usize, parent.len, separator) catch return error.NameTooLong;
    const total = std.math.add(usize, len, name.len) catch return error.NameTooLong;
    if (total > MAX_PATH_BYTES) return error.NameTooLong;
    const out = try allocator.allocSentinel(u8, total, 0);
    @memcpy(out[0..parent.len], parent);
    if (separator != 0) out[parent.len] = '/';
    @memcpy(out[len..total], name);
    return out;
}

const Frame = struct {
    path: [:0]u8,
    dir: *c.DIR,
    totals: Totals,
    mtime_ms: i64,
};

const ScanProgress = struct {
    totals: Totals = .{},
    last_items: u64 = 0,
    last_emit_ms: i64,

    fn note(self: *ScanProgress, contribution: Totals, path: []const u8, sink: Sink) void {
        self.totals.add(contribution);
        const now = nowMs();
        const elapsed = now - self.last_emit_ms;
        const new_items = self.totals.items -| self.last_items;
        if (elapsed < PROGRESS_MIN_MS) return;
        if (new_items < PROGRESS_ITEMS and elapsed < PROGRESS_IDLE_MS) return;
        sink.emit(.{ .progress = .{
            .done = self.totals.size,
            .total = self.totals.allocated,
            .files_done = self.totals.items,
            .file = path,
        } });
        self.last_items = self.totals.items;
        self.last_emit_ms = now;
    }
};

const DetailRecord = struct {
    path: [:0]u8,
    kind: Kind,
    totals: Totals,
    mtime_ms: i64,

    fn score(self: DetailRecord) u64 {
        return @max(self.totals.size, self.totals.allocated);
    }
};

const TopDetails = struct {
    allocator: std.mem.Allocator,
    limit: usize,
    byte_limit: usize,
    path_bytes: usize = 0,
    heap: std.ArrayList(DetailRecord) = .empty,
    dropped: bool = false,

    fn init(allocator: std.mem.Allocator, limit: usize, byte_limit: usize) TopDetails {
        return .{ .allocator = allocator, .limit = limit, .byte_limit = byte_limit };
    }

    fn deinit(self: *TopDetails) void {
        for (self.heap.items) |record| self.allocator.free(record.path);
        self.heap.deinit(self.allocator);
    }

    /// Takes ownership of `record.path`, retaining only the globally
    /// largest details while accounting remains exact.
    fn take(self: *TopDetails, record: DetailRecord) !void {
        errdefer self.allocator.free(record.path);
        if (self.limit == 0 or record.path.len > self.byte_limit) {
            self.dropped = true;
            self.allocator.free(record.path);
            return;
        }
        while (self.heap.items.len >= self.limit or self.path_bytes + record.path.len > self.byte_limit) {
            if (self.heap.items.len == 0 or !lessValuable(self.heap.items[0], record)) {
                self.dropped = true;
                self.allocator.free(record.path);
                return;
            }
            self.dropLeast();
            self.dropped = true;
        }
        try self.heap.append(self.allocator, record);
        self.path_bytes += record.path.len;
        self.siftUp(self.heap.items.len - 1);
    }

    fn lessValuable(a: DetailRecord, b: DetailRecord) bool {
        if (a.score() != b.score()) return a.score() < b.score();
        if (a.path.len != b.path.len) return a.path.len > b.path.len;
        return std.ascii.lessThanIgnoreCase(b.path, a.path);
    }

    fn dropLeast(self: *TopDetails) void {
        const least = self.heap.items[0];
        const last = self.heap.pop().?;
        if (self.heap.items.len > 0) {
            self.heap.items[0] = last;
            self.siftDown(0);
        }
        self.path_bytes -= least.path.len;
        self.allocator.free(least.path);
    }

    fn siftUp(self: *TopDetails, start: usize) void {
        var child = start;
        while (child > 0) {
            const parent = (child - 1) / 2;
            if (!lessValuable(self.heap.items[child], self.heap.items[parent])) break;
            std.mem.swap(DetailRecord, &self.heap.items[parent], &self.heap.items[child]);
            child = parent;
        }
    }

    fn siftDown(self: *TopDetails, start: usize) void {
        var parent = start;
        while (true) {
            const left = parent * 2 + 1;
            if (left >= self.heap.items.len) return;
            const right = left + 1;
            const child = if (right < self.heap.items.len and lessValuable(self.heap.items[right], self.heap.items[left])) right else left;
            if (!lessValuable(self.heap.items[child], self.heap.items[parent])) return;
            std.mem.swap(DetailRecord, &self.heap.items[parent], &self.heap.items[child]);
            parent = child;
        }
    }

    fn sortLargestFirst(self: *TopDetails) void {
        std.mem.sort(DetailRecord, self.heap.items, {}, struct {
            fn less(_: void, a: DetailRecord, b: DetailRecord) bool {
                if (a.score() == b.score() and a.path.len != b.path.len) return a.path.len < b.path.len;
                return a.score() > b.score();
            }
        }.less);
    }
};

/// Emits a connected, size-prioritized detail tree under a fixed event cap.
fn emitDetails(
    allocator: std.mem.Allocator,
    root: []const u8,
    dirs: *TopDetails,
    files: *TopDetails,
    max_events: usize,
    sink: Sink,
) error{OutOfMemory}!bool {
    dirs.sortLargestFirst();
    files.sortLargestFirst();
    var connected: std.StringHashMapUnmanaged(void) = .empty;
    defer connected.deinit(allocator);
    try connected.put(allocator, root, {});

    var emitted: usize = 0;
    var truncated = dirs.dropped or files.dropped;
    for (dirs.heap.items) |record| {
        if (emitted >= max_events) {
            truncated = true;
            break;
        }
        const parent = std.fs.path.dirname(record.path) orelse {
            truncated = true;
            continue;
        };
        if (!connected.contains(parent)) {
            truncated = true;
            continue;
        }
        sink.emit(.{ .usage = usageOf(record.path, record.kind, record.totals, record.mtime_ms) });
        if (record.kind == .dir) try connected.put(allocator, record.path, {});
        emitted += 1;
    }
    for (files.heap.items) |record| {
        if (emitted >= max_events) {
            truncated = true;
            break;
        }
        const parent = std.fs.path.dirname(record.path) orelse {
            truncated = true;
            continue;
        };
        if (!connected.contains(parent)) {
            truncated = true;
            continue;
        }
        sink.emit(.{ .usage = usageOf(record.path, .file, record.totals, record.mtime_ms) });
        emitted += 1;
    }
    return truncated;
}

/// Scans one absolute directory, following only a symlink used as the root.
pub fn scan(allocator: std.mem.Allocator, root: []const u8, all_filesystems: bool, sink: Sink) ScanError!Result {
    if (root.len == 0 or root[0] != '/' or root.len > MAX_PATH_BYTES) return error.InvalidRoot;

    const root_path = allocator.dupeZ(u8, root) catch return error.OutOfMemory;
    var root_owned = true;
    defer if (root_owned) allocator.free(root_path);

    var lst: c.struct_stat = undefined;
    if (c.stat(root_path.ptr, &lst) != 0) return error.RootStatFailed;
    if ((lst.st_mode & c.S_IFMT) != c.S_IFDIR) return error.RootNotDirectory;
    const opened_root = openDirectory(root_path, true) orelse return error.RootOpenFailed;
    var root_dir_owned = true;
    defer {
        if (root_dir_owned) _ = c.closedir(opened_root.dir);
    }

    var accountant = Accountant.init(allocator);
    defer accountant.deinit();
    var top_dirs = TopDetails.init(allocator, MAX_DIR_EVENTS, DETAIL_PATH_BYTES);
    defer top_dirs.deinit();
    var top_files = TopDetails.init(allocator, MAX_DETAIL_EVENTS, DETAIL_PATH_BYTES);
    defer top_files.deinit();
    const root_direct = accountant.account(observationOf(&opened_root.stat, .dir)) catch return error.OutOfMemory;
    const root_dev: u64 = @intCast(opened_root.stat.st_dev);
    _ = accountant.visitDirectory(root_dev, @intCast(opened_root.stat.st_ino)) catch return error.OutOfMemory;

    var progress = ScanProgress{ .last_emit_ms = nowMs() };
    progress.totals.add(root_direct);

    var stack: std.ArrayList(Frame) = .empty;
    defer {
        for (stack.items) |frame| {
            _ = c.closedir(frame.dir);
            allocator.free(frame.path);
        }
        stack.deinit(allocator);
    }
    stack.append(allocator, .{
        .path = root_path,
        .dir = opened_root.dir,
        .totals = root_direct,
        .mtime_ms = fsserve.mtimeMs(&opened_root.stat),
    }) catch return error.OutOfMemory;
    root_owned = false;
    root_dir_owned = false;

    while (stack.items.len > 0) {
        const parent_index = stack.items.len - 1;
        platform.clearErrno();
        const entry = c.readdir(stack.items[parent_index].dir);
        if (entry == null) {
            if (platform.currentErrno() != 0) {
                stack.items[parent_index].totals.errors +|= 1;
                progress.totals.errors +|= 1;
            }
            const completed = stack.pop().?;
            _ = c.closedir(completed.dir);
            const is_root = stack.items.len == 0;
            if (is_root) {
                const truncated = emitDetails(allocator, root, &top_dirs, &top_files, MAX_DETAIL_EVENTS, sink) catch return error.OutOfMemory;
                sink.emit(.{ .usage = usageOf(completed.path, .dir, completed.totals, completed.mtime_ms) });
                const result = Result{ .totals = completed.totals, .mtime_ms = completed.mtime_ms, .truncated = truncated };
                allocator.free(completed.path);
                return result;
            }
            stack.items[stack.items.len - 1].totals.add(completed.totals);
            top_dirs.take(.{
                .path = completed.path,
                .kind = .dir,
                .totals = completed.totals,
                .mtime_ms = completed.mtime_ms,
            }) catch return error.OutOfMemory;
            continue;
        }

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const child_path = joinPath(allocator, stack.items[parent_index].path, name) catch |err| switch (err) {
            error.NameTooLong => {
                const failed = Totals.failedEntry();
                stack.items[parent_index].totals.add(failed);
                progress.note(failed, stack.items[parent_index].path, sink);
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        var child_owned = true;
        defer if (child_owned) allocator.free(child_path);

        var st: c.struct_stat = undefined;
        if (c.lstat(child_path.ptr, &st) != 0) {
            const failed = Totals.failedEntry();
            stack.items[parent_index].totals.add(failed);
            progress.note(failed, child_path, sink);
            continue;
        }

        const child_dev: u64 = @intCast(st.st_dev);
        if (shouldSkipDevice(root_dev, child_dev, all_filesystems)) {
            const skipped = accountant.account(.{ .kind = .mount }) catch return error.OutOfMemory;
            stack.items[parent_index].totals.add(skipped);
            progress.note(skipped, child_path, sink);
            child_owned = false;
            top_dirs.take(.{ .path = child_path, .kind = .mount, .totals = skipped, .mtime_ms = fsserve.mtimeMs(&st) }) catch return error.OutOfMemory;
            continue;
        }

        switch (st.st_mode & c.S_IFMT) {
            c.S_IFREG => {
                const direct = accountant.account(observationOf(&st, .file)) catch return error.OutOfMemory;
                stack.items[parent_index].totals.add(direct);
                progress.note(direct, child_path, sink);
                child_owned = false;
                top_files.take(.{ .path = child_path, .kind = .file, .totals = direct, .mtime_ms = fsserve.mtimeMs(&st) }) catch return error.OutOfMemory;
            },
            c.S_IFDIR => {
                const opened = openDirectory(child_path, false) orelse {
                    var failed_dir = accountant.account(observationOf(&st, .dir)) catch return error.OutOfMemory;
                    failed_dir.errors = 1;
                    stack.items[parent_index].totals.add(failed_dir);
                    progress.note(failed_dir, child_path, sink);
                    child_owned = false;
                    top_dirs.take(.{ .path = child_path, .kind = .dir, .totals = failed_dir, .mtime_ms = fsserve.mtimeMs(&st) }) catch return error.OutOfMemory;
                    continue;
                };
                if (shouldSkipDevice(root_dev, @intCast(opened.stat.st_dev), all_filesystems)) {
                    _ = c.closedir(opened.dir);
                    const skipped = accountant.account(.{ .kind = .mount }) catch return error.OutOfMemory;
                    stack.items[parent_index].totals.add(skipped);
                    progress.note(skipped, child_path, sink);
                    child_owned = false;
                    top_dirs.take(.{ .path = child_path, .kind = .mount, .totals = skipped, .mtime_ms = fsserve.mtimeMs(&opened.stat) }) catch return error.OutOfMemory;
                    continue;
                }
                const fresh = accountant.visitDirectory(@intCast(opened.stat.st_dev), @intCast(opened.stat.st_ino)) catch {
                    _ = c.closedir(opened.dir);
                    return error.OutOfMemory;
                };
                if (!fresh) {
                    _ = c.closedir(opened.dir);
                    const skipped = accountant.account(.{ .kind = .mount }) catch return error.OutOfMemory;
                    stack.items[parent_index].totals.add(skipped);
                    progress.note(skipped, child_path, sink);
                    child_owned = false;
                    top_dirs.take(.{ .path = child_path, .kind = .mount, .totals = skipped, .mtime_ms = fsserve.mtimeMs(&opened.stat) }) catch return error.OutOfMemory;
                    continue;
                }
                const direct = accountant.account(observationOf(&opened.stat, .dir)) catch {
                    _ = c.closedir(opened.dir);
                    return error.OutOfMemory;
                };
                progress.note(direct, child_path, sink);
                stack.append(allocator, .{
                    .path = child_path,
                    .dir = opened.dir,
                    .totals = direct,
                    .mtime_ms = fsserve.mtimeMs(&opened.stat),
                }) catch {
                    _ = c.closedir(opened.dir);
                    return error.OutOfMemory;
                };
                child_owned = false;
            },
            else => {
                const ignored = accountant.account(.{ .kind = .other }) catch return error.OutOfMemory;
                stack.items[parent_index].totals.add(ignored);
                progress.note(ignored, child_path, sink);
            },
        }
    }
    unreachable;
}

test "accounting includes directory metadata and globally deduplicates hard links" {
    const t = std.testing;
    var accountant = Accountant.init(t.allocator);
    defer accountant.deinit();
    var total = try accountant.account(.{ .kind = .dir, .size = 128, .allocated = 512 });
    const first = try accountant.account(.{
        .kind = .file,
        .size = 100,
        .allocated = 512,
        .dev = 3,
        .ino = 9,
        .nlink = 2,
    });
    const second = try accountant.account(.{
        .kind = .file,
        .size = 100,
        .allocated = 512,
        .dev = 3,
        .ino = 9,
        .nlink = 2,
    });
    total.add(first);
    total.add(second);
    total.add(try accountant.account(.{ .kind = .other }));
    try t.expectEqual(@as(u64, 228), total.size);
    try t.expectEqual(@as(u64, 1024), total.allocated);
    try t.expectEqual(@as(u64, 4), total.items);
    try t.expectEqual(@as(u64, 0), second.size);
    try t.expectEqual(@as(u64, 1), second.items);
}

test "directory identities are traversed only once" {
    const t = std.testing;
    var accountant = Accountant.init(t.allocator);
    defer accountant.deinit();
    try t.expect(try accountant.visitDirectory(4, 9));
    try t.expect(!try accountant.visitDirectory(4, 9));
    try t.expect(try accountant.visitDirectory(4, 10));
    try t.expect(try accountant.visitDirectory(5, 9));
}

test "retained details keep only the largest bounded records" {
    const t = std.testing;
    var details = TopDetails.init(t.allocator, 2, 64);
    defer details.deinit();
    try details.take(.{ .path = try t.allocator.dupeZ(u8, "/low"), .kind = .file, .totals = .{ .size = 10 }, .mtime_ms = 0 });
    try details.take(.{ .path = try t.allocator.dupeZ(u8, "/high"), .kind = .file, .totals = .{ .size = 30 }, .mtime_ms = 0 });
    try details.take(.{ .path = try t.allocator.dupeZ(u8, "/mid"), .kind = .file, .totals = .{ .size = 20 }, .mtime_ms = 0 });
    try t.expect(details.dropped);
    try t.expectEqual(@as(usize, 2), details.heap.items.len);
    var total: u64 = 0;
    for (details.heap.items) |record| total += record.totals.size;
    try t.expectEqual(@as(u64, 50), total);
}

test "retained detail byte bounds prefer value and ancestor paths on ties" {
    const t = std.testing;
    var details = TopDetails.init(t.allocator, 4, 5);
    defer details.deinit();
    try details.take(.{ .path = try t.allocator.dupeZ(u8, "/a/b"), .kind = .dir, .totals = .{ .size = 20 }, .mtime_ms = 0 });
    try details.take(.{ .path = try t.allocator.dupeZ(u8, "/a"), .kind = .dir, .totals = .{ .size = 20 }, .mtime_ms = 0 });
    try t.expect(details.dropped);
    try t.expectEqual(@as(usize, 1), details.heap.items.len);
    try t.expectEqualStrings("/a", details.heap.items[0].path);
    try t.expectEqual(@as(usize, 2), details.path_bytes);
}

test "default device boundary produces a counted mount placeholder" {
    const t = std.testing;
    try t.expect(shouldSkipDevice(10, 11, false));
    try t.expect(!shouldSkipDevice(10, 11, true));
    try t.expect(!shouldSkipDevice(10, 10, false));
    var accountant = Accountant.init(t.allocator);
    defer accountant.deinit();
    const mount = try accountant.account(.{ .kind = .mount, .size = 999, .allocated = 1024 });
    try t.expectEqual(@as(u64, 0), mount.size);
    try t.expectEqual(@as(u64, 0), mount.allocated);
    try t.expectEqual(@as(u64, 1), mount.items);
    try t.expectEqual(@as(u64, 1), mount.skipped);
}

const TestCollector = struct {
    root: []const u8,
    usage_count: usize = 0,
    file_count: usize = 0,
    dir_count: usize = 0,
    file_size: u64 = 0,
    file_allocated: u64 = 0,
    zero_file_count: usize = 0,
    last_is_root: bool = false,
    root_usage: ?Usage = null,
    sub_usage: ?Usage = null,
    sub_index: usize = 0,
    last_file_index: usize = 0,

    fn onEvent(raw: ?*anyopaque, event: Event) void {
        const self: *TestCollector = @ptrCast(@alignCast(raw.?));
        switch (event) {
            .progress => {},
            .usage => |usage| {
                self.usage_count += 1;
                self.last_is_root = std.mem.eql(u8, usage.path, self.root);
                switch (usage.kind) {
                    .file => {
                        self.file_count += 1;
                        self.file_size +|= usage.size;
                        self.file_allocated +|= usage.allocated;
                        if (usage.size == 0) self.zero_file_count += 1;
                        self.last_file_index = self.usage_count;
                    },
                    .dir => {
                        self.dir_count += 1;
                        if (std.mem.eql(u8, usage.path, self.root)) self.root_usage = usage;
                        if (std.mem.endsWith(u8, usage.path, "/sub")) {
                            self.sub_usage = usage;
                            self.sub_index = self.usage_count;
                        }
                    },
                    .mount => {},
                }
            },
        }
    }
};

fn testPath(buf: []u8, dir: []const u8, name: []const u8) ![:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ dir, name });
}

test "scanner is postorder, counts nested metadata, deduplicates links, and ignores symlinks" {
    const t = std.testing;
    var root_buf: [64]u8 = undefined;
    const template = "/tmp/sketerm-disk-usage-XXXXXX";
    @memcpy(root_buf[0..template.len], template);
    root_buf[template.len] = 0;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(c.mkdtemp(@ptrCast(&root_buf)) orelse return error.SkipZigTest)));

    var sub_buf: [128]u8 = undefined;
    var data_buf: [128]u8 = undefined;
    var hard_buf: [128]u8 = undefined;
    var link_buf: [128]u8 = undefined;
    const sub = try testPath(&sub_buf, root, "sub");
    const data = try testPath(&data_buf, root, "sub/data");
    const hard = try testPath(&hard_buf, root, "sub/hard");
    const link = try testPath(&link_buf, root, "link-to-sub");
    defer {
        _ = c.unlink(link.ptr);
        _ = c.unlink(hard.ptr);
        _ = c.unlink(data.ptr);
        _ = c.rmdir(sub.ptr);
        _ = c.rmdir(@ptrCast(&root_buf));
    }
    try t.expect(c.mkdir(sub.ptr, 0o755) == 0);
    const fd = c.open(data.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.SkipZigTest;
    const payload = "hard-link-payload";
    try t.expect(c.write(fd, payload.ptr, payload.len) == payload.len);
    _ = c.close(fd);
    try t.expect(c.link(data.ptr, hard.ptr) == 0);
    try t.expect(c.symlink("sub", link.ptr) == 0);

    var root_z: [64:0]u8 = undefined;
    const root_path = try std.fmt.bufPrintZ(&root_z, "{s}", .{root});
    var root_st: c.struct_stat = undefined;
    var sub_st: c.struct_stat = undefined;
    var data_st: c.struct_stat = undefined;
    try t.expect(c.lstat(root_path.ptr, &root_st) == 0);
    try t.expect(c.lstat(sub.ptr, &sub_st) == 0);
    try t.expect(c.lstat(data.ptr, &data_st) == 0);

    var collector = TestCollector{ .root = root };
    const result = try scan(t.allocator, root, false, .{
        .context = &collector,
        .on_event = TestCollector.onEvent,
    });
    const expected_size = apparentOfStat(&root_st) + apparentOfStat(&sub_st) + apparentOfStat(&data_st);
    const expected_allocated = allocatedOfStat(&root_st) + allocatedOfStat(&sub_st) + allocatedOfStat(&data_st);
    try t.expectEqual(expected_size, result.totals.size);
    try t.expectEqual(expected_allocated, result.totals.allocated);
    try t.expectEqual(@as(u64, 5), result.totals.items);
    try t.expectEqual(@as(u64, 0), result.totals.errors);
    try t.expectEqual(@as(u64, 0), result.totals.skipped);
    try t.expectEqual(@as(usize, 4), collector.usage_count);
    try t.expectEqual(@as(usize, 2), collector.file_count);
    try t.expectEqual(@as(usize, 2), collector.dir_count);
    try t.expectEqual(apparentOfStat(&data_st), collector.file_size);
    try t.expectEqual(allocatedOfStat(&data_st), collector.file_allocated);
    try t.expectEqual(@as(usize, 1), collector.zero_file_count);
    try t.expect(collector.sub_index < collector.last_file_index);
    try t.expect(collector.last_is_root);
    try t.expectEqual(@as(u64, 3), collector.sub_usage.?.items);
    try t.expectEqual(expected_size, collector.root_usage.?.size);

    var linked = TestCollector{ .root = link };
    const linked_result = try scan(t.allocator, link, false, .{
        .context = &linked,
        .on_event = TestCollector.onEvent,
    });
    try t.expectEqual(@as(u64, 3), linked_result.totals.items);
    try t.expectEqual(@as(u64, 0), linked_result.totals.errors);
    try t.expect(linked.last_is_root);
}

test "scanner keeps sparse apparent and allocated byte totals independent" {
    const t = std.testing;
    var root_buf: [64]u8 = undefined;
    const template = "/tmp/sketerm-disk-sparse-XXXXXX";
    @memcpy(root_buf[0..template.len], template);
    root_buf[template.len] = 0;
    const root = std.mem.span(@as([*:0]u8, @ptrCast(c.mkdtemp(@ptrCast(&root_buf)) orelse return error.SkipZigTest)));
    var sparse_buf: [128]u8 = undefined;
    const sparse = try testPath(&sparse_buf, root, "sparse");
    defer {
        _ = c.unlink(sparse.ptr);
        _ = c.rmdir(@ptrCast(&root_buf));
    }
    const fd = c.open(sparse.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.SkipZigTest;
    defer _ = c.close(fd);
    const sparse_size: u64 = 8 << 20;
    if (c.ftruncate(fd, @intCast(sparse_size)) != 0) return error.SkipZigTest;
    var st: c.struct_stat = undefined;
    try t.expect(c.lstat(sparse.ptr, &st) == 0);

    var collector = TestCollector{ .root = root };
    _ = try scan(t.allocator, root, false, .{
        .context = &collector,
        .on_event = TestCollector.onEvent,
    });
    try t.expectEqual(apparentOfStat(&st), collector.file_size);
    try t.expectEqual(allocatedOfStat(&st), collector.file_allocated);
    try t.expectEqual(sparse_size, collector.file_size);
    if (allocatedOfStat(&st) < apparentOfStat(&st))
        try t.expect(collector.file_allocated < collector.file_size);
}

//! Persistent intent ledger for browser downloads and edit sync-back.
//!
//! One FILE PER RECORD in a ledger directory, each owned through its
//! own `flock`ed sidecar. The old model was a single JSON document
//! under one exclusive lock, which made durable transfers the property
//! of whichever process opened a browser face first; with the file
//! manager running as its own application identity, two GUI processes
//! at once is the normal case, so ownership had to become per record.
//!
//! Ownership rules, in one place because everything else depends on
//! them:
//!   * `<base>.lock` is created and locked BEFORE `<base>.json` exists,
//!     and the lock is held for as long as the process runs the record.
//!     A lock that can be taken therefore means "no live owner".
//!   * `<base>.json` is replaced atomically (temp + rename), so a
//!     reader never sees a half-written record and the lock file's
//!     identity survives every rewrite.
//!   * A lock with no record file is the debris of a process that died
//!     between the two steps; the adopter removes it.
//!   * `flock` (not `fcntl`) because fcntl locks are per PROCESS and
//!     are dropped by closing ANY descriptor to the file — a second
//!     open of a record we already own would silently release it.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const platform = @import("../util/platform.zig");
const profile = @import("../util/profile.zig");

pub const VERSION: u32 = 5;
pub const MIN_READ_VERSION: u32 = 2;
pub const MAX_RECORD_BYTES: usize = 32 * 1024 * 1024;

pub fn readableVersion(version: u32) bool {
    return version >= MIN_READ_VERSION and version <= VERSION;
}

pub const Kind = enum { download, upload };
pub const State = enum { queued, submitting, running, waiting_retry, done, failed, canceled };
pub const RType = enum { intent, watch, batch };

pub const FileRef = struct {
    host: []const u8 = "",
    path: []const u8 = "",
};

pub const Intent = struct {
    /// Record identity: the ledger file name and the panel row key.
    /// Stable for the life of the transfer.
    token: []const u8 = "",
    /// Idempotency key handed to the daemon's cross_copy. A terminal
    /// daemon job cannot be restarted under the same key, so a retry
    /// mints a fresh one -- which is why this is NOT the record
    /// identity (a row that changed identity on every retry lost its
    /// measured rate and its buttons).
    client_token: []const u8 = "",
    kind: Kind = .download,
    src: FileRef = .{},
    dst: FileRef = .{},
    app_id: []const u8 = "",
    state: State = .queued,
    job: u64 = 0,
    order: u64 = 0,
    watch_token: []const u8 = "",
    submitted_generation: u64 = 0,
    message: []const u8 = "",
    attempts: u8 = 0,
    cancel_requested: bool = false,
    submitted_size: u64 = 0,
    submitted_mtime_ns: i64 = 0,
    /// User-held transfer. A plain defaulted field, not a new State
    /// value: an older build parses the ledger with unknown fields
    /// ignored, so a paused entry still loads there.
    paused: bool = false,
    /// Terminal daemon job still owed a `job_ack`. The record outlives
    /// the transfer until the acknowledgment lands, so a crash in
    /// between cannot leave the daemon holding the job forever.
    ack_job: u64 = 0,
    /// The transfer is finished and the record exists only to carry
    /// `ack_job`; it is not shown and never resubmitted.
    retired: bool = false,
    /// Client-mediated (fstransfer) rather than a daemon copy job:
    /// only a process with a browser face and both host connections
    /// can run it, so it is adopted only while a driver is registered.
    mediated: bool = false,
    /// A normal browser copy/move whose daemon submission is driven by
    /// a browser face. Its intent is still ledger-owned, so queued and
    /// running work can be adopted after that face or process exits.
    user_copy: bool = false,
    /// Presentation identity shared by every item admitted by one
    /// paste/drop command. Zero is an ungrouped transfer.
    batch_id: u64 = 0,
    batch_total: u64 = 0,
    /// Durable parent identity for a manifest child. Unlike batch_id,
    /// this is nonzero/nonempty even for a one-item command and lets an
    /// adopter retain tombstones while another process owns the parent.
    batch_token: []const u8 = "",
    /// Daemon that owns the current idempotent attempt. Empty is local;
    /// coordinator_set distinguishes that from an unsubmitted record.
    coordinator_host: []const u8 = "",
    coordinator_set: bool = false,
    /// Daemon that still needs ack_job acknowledged. It is separate
    /// from coordinator_host because a retry may use another daemon.
    ack_host: []const u8 = "",
    /// Mediated extras, meaningless for daemon transfers.
    open_when_done: bool = false,
    delete_src_after: bool = false,
    no_replace: bool = false,
    watch_after: bool = false,
};

pub const Watch = struct {
    token: []const u8 = "",
    host: []const u8 = "",
    remote_path: []const u8 = "",
    cache_path: []const u8 = "",
    dirty_generation: u64 = 0,
    synced_generation: u64 = 0,
    synced_size: u64 = 0,
    synced_mtime_ns: i64 = 0,
};

pub const BatchItem = struct {
    token: []const u8 = "",
    src_path: []const u8 = "",
    dst_path: []const u8 = "",
    /// A known collision waits for the interactive conflict flow.
    /// Null is safe to admit with no-replace, including a drop whose
    /// destination probe had not answered before recovery.
    conflict_is_dir: ?bool = null,
};

/// Durable admission plan for one multi-item browser command. Every
/// child token is fixed before the manifest lands, so recovery can
/// materialize missing per-item records without duplicating any that
/// were already created before a crash.
pub const Batch = struct {
    token: []const u8 = "",
    batch_id: u64 = 0,
    batch_total: u64 = 0,
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    move: bool = false,
    no_replace: bool = true,
    items: []const BatchItem = &.{},
};

/// One ledger file. The unused arm keeps its defaults, so the record
/// is one flat, forward-compatible JSON object.
pub const Record = struct {
    version: u32 = VERSION,
    rtype: RType = .intent,
    intent: Intent = .{},
    watch: Watch = .{},
    batch: Batch = .{},
};

/// `$XDG_STATE_HOME/sketerm/file-transfers.d`.
pub fn dirPath(allocator: std.mem.Allocator) ![]u8 {
    if (profile.getenv("XDG_STATE_HOME")) |xs|
        return std.fmt.allocPrint(allocator, "{s}/sketerm/file-transfers.d", .{xs});
    if (profile.getenv("HOME")) |home|
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/file-transfers.d", .{home});
    return allocator.dupe(u8, "/tmp/sketerm-file-transfers.d");
}

/// The single-document ledger this store replaced.
pub fn legacyPath(allocator: std.mem.Allocator) ![]u8 {
    if (profile.getenv("XDG_STATE_HOME")) |xs|
        return std.fmt.allocPrint(allocator, "{s}/sketerm/file-transfers.json", .{xs});
    if (profile.getenv("HOME")) |home|
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/file-transfers.json", .{home});
    return allocator.dupe(u8, "/tmp/sketerm-file-transfers.json");
}

fn prefixOf(rtype: RType) []const u8 {
    return switch (rtype) {
        .intent => "i",
        .watch => "w",
        .batch => "b",
    };
}

/// An owned record: the held lock plus the paths it governs.
pub const Handle = struct {
    allocator: std.mem.Allocator,
    rtype: RType,
    token: []u8,
    json_path: []u8,
    lock_path: []u8,
    lock_fd: c_int,
    /// Hash of the last bytes written, so an unchanged record costs no
    /// write and no fsync.
    written_hash: u64 = 0,

    /// Drop ownership, leaving the files for another process.
    pub fn release(self: *Handle) void {
        if (self.lock_fd >= 0) _ = c.close(self.lock_fd);
        self.lock_fd = -1;
        self.allocator.free(self.token);
        self.allocator.free(self.json_path);
        self.allocator.free(self.lock_path);
    }

    /// Delete the record, then drop ownership.
    pub fn destroyRecord(self: *Handle) bool {
        return self.destroyRecordImpl(true);
    }

    /// Delete without a directory fsync after a parent manifest's
    /// durable deletion already made resurrection harmless.
    pub fn destroyRecordUnsynced(self: *Handle) bool {
        return self.destroyRecordImpl(false);
    }

    fn destroyRecordImpl(self: *Handle, sync_parent: bool) bool {
        var removed = true;
        var z: [4096]u8 = undefined;
        if (pathz.pathZ(&z, self.json_path)) |p| {
            if (c.unlink(p) != 0 and std.posix.errno(-1) != .NOENT) removed = false;
        } else |_| removed = false;
        if (pathz.pathZ(&z, self.lock_path)) |p| {
            if (c.unlink(p) != 0 and std.posix.errno(-1) != .NOENT) removed = false;
        } else |_| removed = false;
        if (sync_parent and !syncParentDir(self.json_path)) removed = false;
        self.release();
        return removed;
    }

    /// Atomically replace the record. A byte-identical record is a
    /// no-op.
    pub fn write(self: *Handle, record: Record) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(record, .{}, &out.writer);
        const bytes = out.written();
        if (bytes.len > MAX_RECORD_BYTES) return error.RecordTooLarge;
        const h = std.hash.Wyhash.hash(0x51ed, bytes);
        if (h == self.written_hash) return;
        try writeFileAtomic(self.allocator, self.json_path, bytes);
        self.written_hash = h;
    }
};

fn syncParentDir(path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return true;
    var z: [4096]u8 = undefined;
    const fd = c.open(pathz.pathZ(&z, parent) catch return false, c.O_RDONLY | c.O_DIRECTORY);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.fsync(fd) == 0;
}

fn writeFileAtomic(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const temp = try std.fmt.allocPrint(allocator, "{s}.tmp-{d}", .{ path, c.getpid() });
    defer allocator.free(temp);
    var pz: [4096]u8 = undefined;
    var tz: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&tz, temp), "wb") orelse return error.WriteFailed;
    if (c.fwrite(bytes.ptr, 1, bytes.len, fp) != bytes.len or c.fflush(fp) != 0) {
        _ = c.fclose(fp);
        _ = c.unlink(try pathz.pathZ(&tz, temp));
        return error.WriteFailed;
    }
    const fd = c.fileno(fp);
    if (fd < 0 or c.fsync(fd) != 0) {
        _ = c.fclose(fp);
        _ = c.unlink(try pathz.pathZ(&tz, temp));
        return error.WriteFailed;
    }
    if (c.fclose(fp) != 0) return error.WriteFailed;
    if (c.rename(try pathz.pathZ(&tz, temp), try pathz.pathZ(&pz, path)) != 0) {
        _ = c.unlink(try pathz.pathZ(&tz, temp));
        return error.WriteFailed;
    }
    const parent = std.fs.path.dirname(path) orelse return;
    var dz: [4096]u8 = undefined;
    const dfd = c.open(try pathz.pathZ(&dz, parent), c.O_RDONLY | c.O_DIRECTORY);
    if (dfd < 0) {
        poisonRecord(path);
        return error.WriteFailed;
    }
    defer _ = c.close(dfd);
    if (c.fsync(dfd) != 0) {
        // The rename may or may not survive a crash. Make the renamed
        // inode unreadable to every ledger version, so either outcome
        // is safe rather than an uncertain command becoming runnable.
        poisonRecord(path);
        return error.WriteFailed;
    }
}

fn poisonRecord(path: []const u8) void {
    var z: [4096]u8 = undefined;
    const fp = c.fopen(pathz.pathZ(&z, path) catch return, "wb") orelse return;
    const bytes = "{\"version\":0}";
    const written = c.fwrite(bytes.ptr, 1, bytes.len, fp);
    if (written == bytes.len and c.fflush(fp) == 0) {
        const fd = c.fileno(fp);
        if (fd >= 0) _ = c.fsync(fd);
    }
    _ = c.fclose(fp);
}

/// Take ownership of `token`'s record, creating the lock when it does
/// not exist yet.
/// @return null when another live process owns it.
pub fn open(allocator: std.mem.Allocator, rtype: RType, token: []const u8) !?Handle {
    const dir = try dirPath(allocator);
    defer allocator.free(dir);
    var dz: [4096]u8 = undefined;
    // makeParentDirs walks the ancestors of its argument, so it is
    // pointed at a name INSIDE the ledger directory.
    var probe_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&probe_buf, "{s}/x", .{dir})) |probe| {
        pathz.makeParentDirs(probe) catch {};
    } else |_| {}
    _ = c.mkdir(try pathz.pathZ(&dz, dir), 0o700);

    const json_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.json", .{ dir, prefixOf(rtype), token });
    errdefer allocator.free(json_path);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.lock", .{ dir, prefixOf(rtype), token });
    errdefer allocator.free(lock_path);
    var z: [4096]u8 = undefined;
    const fd = c.open(try pathz.pathZ(&z, lock_path), c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.LedgerLockFailed;
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        _ = c.close(fd);
        allocator.free(json_path);
        allocator.free(lock_path);
        return null;
    }
    const owned_token = try allocator.dupe(u8, token);
    return .{
        .allocator = allocator,
        .rtype = rtype,
        .token = owned_token,
        .json_path = json_path,
        .lock_path = lock_path,
        .lock_fd = fd,
    };
}

/// Read one record file. `null` = no such file.
pub fn readFile(allocator: std.mem.Allocator, path: []const u8) !?std.json.Parsed(Record) {
    var z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&z, path), "rb") orelse {
        if (std.posix.errno(-1) == .NOENT) return null;
        return error.ReadFailed;
    };
    defer _ = c.fclose(fp);
    if (c.fseek(fp, 0, c.SEEK_END) != 0) return error.BadRecord;
    const raw_len = c.ftell(fp);
    if (raw_len <= 0 or raw_len > MAX_RECORD_BYTES) return error.BadRecord;
    if (c.fseek(fp, 0, c.SEEK_SET) != 0) return error.BadRecord;
    const bytes = try allocator.alloc(u8, @intCast(raw_len));
    defer allocator.free(bytes);
    const n = c.fread(bytes.ptr, 1, bytes.len, fp);
    if (n != bytes.len) return error.BadRecord;
    return std.json.parseFromSlice(Record, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.BadRecord;
}

/// Read a record by identity without taking ownership. Used for
/// cross-process duplicate detection: another process's in-flight
/// download must not be started a second time here, or both would
/// write the same staged `.skpart`.
pub fn readToken(allocator: std.mem.Allocator, rtype: RType, token: []const u8) !?std.json.Parsed(Record) {
    const dir = try dirPath(allocator);
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}.json", .{ dir, prefixOf(rtype), token });
    defer allocator.free(path);
    return readFile(allocator, path);
}

pub const Entry = struct { rtype: RType, token: []u8 };

/// Every record identity in the ledger directory, owned or not.
pub fn list(allocator: std.mem.Allocator) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |e| allocator.free(e.token);
        out.deinit(allocator);
    }
    const dir = try dirPath(allocator);
    defer allocator.free(dir);
    var z: [4096]u8 = undefined;
    const dp = c.opendir(try pathz.pathZ(&z, dir)) orelse return out.toOwnedSlice(allocator);
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |ent| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (name.len < "i-x.json".len or name[1] != '-') continue;
        const rtype: RType = switch (name[0]) {
            'i' => .intent,
            'w' => .watch,
            'b' => .batch,
            else => continue,
        };
        const token = name[2 .. name.len - ".json".len];
        try out.append(allocator, .{ .rtype = rtype, .token = try allocator.dupe(u8, token) });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeList(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.token);
    allocator.free(entries);
}

// ── legacy single-document ledger ───────────────────────────────

pub const LegacyLedger = struct {
    version: u32 = 1,
    next_order: u64 = 1,
    intents: []const Intent = &.{},
    watches: []const Watch = &.{},
    acknowledgments: []const u64 = &.{},
};

/// Read the pre-v2 ledger, if one is still there.
pub fn loadLegacy(allocator: std.mem.Allocator) !?std.json.Parsed(LegacyLedger) {
    const path = try legacyPath(allocator);
    defer allocator.free(path);
    var z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&z, path), "rb") orelse return null;
    defer _ = c.fclose(fp);
    var bytes: [2 * 1024 * 1024]u8 = undefined;
    const n = c.fread(&bytes, 1, bytes.len, fp);
    if (n == 0 or n == bytes.len) return error.BadLedger;
    return std.json.parseFromSlice(LegacyLedger, allocator, bytes[0..n], .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch error.BadLedger;
}

/// Hold the legacy ledger's exclusive lock for the duration of a
/// migration. A pre-upgrade binary keeps this lock for its whole life,
/// so failing to take it means an old process is still running its
/// transfers from that file: migrating then would run them twice.
pub const LegacyLock = struct {
    fd: c_int,

    pub fn release(self: LegacyLock) void {
        if (self.fd >= 0) _ = c.close(self.fd);
    }
};

pub fn lockLegacy(allocator: std.mem.Allocator) !?LegacyLock {
    const path = try legacyPath(allocator);
    defer allocator.free(path);
    const lock_path = try std.fmt.allocPrint(allocator, "{s}.lock", .{path});
    defer allocator.free(lock_path);
    try pathz.makeParentDirs(lock_path);
    var z: [4096]u8 = undefined;
    const fd = c.open(try pathz.pathZ(&z, lock_path), c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return error.LedgerLockFailed;
    // Hold both lock kinds for the whole migration. Merely probing the
    // old fcntl lock leaves a race in which an old binary can acquire
    // it before this process takes its independent flock.
    var probe = c.struct_flock{ .l_type = c.F_WRLCK, .l_whence = c.SEEK_SET, .l_start = 0, .l_len = 0, .l_pid = 0 };
    if (c.fcntl(fd, c.F_SETLK, &probe) != 0) {
        _ = c.close(fd);
        return null;
    }
    // Linux keeps fcntl and flock in independent lock spaces, so the
    // flock has to be taken as well to exclude a NEW binary (which locks
    // records with flock) while the fcntl above excludes an OLD one.
    //
    // Darwin runs both kinds through ONE advisory-lock list per vnode,
    // as distinct owners: they conflict across processes — verified both
    // directions — which is exactly the exclusion this wants, and they
    // therefore also conflict with each other inside this process, so
    // the call below would fail EWOULDBLOCK against the lock just taken
    // and abandon every migration. One fcntl lock already covers both
    // sides there.
    if (comptime platform.is_linux) {
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
            _ = c.close(fd);
            return null;
        }
    }
    return .{ .fd = fd };
}

/// Move the migrated document aside. Kept (not deleted) so a failed
/// upgrade can still be inspected by hand.
pub fn retireLegacy(allocator: std.mem.Allocator) bool {
    const path = legacyPath(allocator) catch return false;
    defer allocator.free(path);
    const dest = std.fmt.allocPrint(allocator, "{s}.migrated", .{path}) catch return false;
    defer allocator.free(dest);
    var az: [4096]u8 = undefined;
    var bz: [4096]u8 = undefined;
    const from = pathz.pathZ(&az, path) catch return false;
    const to = pathz.pathZ(&bz, dest) catch return false;
    return c.rename(from, to) == 0;
}

// ── tests ───────────────────────────────────────────────────────

const TmpState = struct {
    dir: std.testing.TmpDir,
    old: ?[]u8,

    fn init(allocator: std.mem.Allocator) !TmpState {
        const old = if (profile.getenv("XDG_STATE_HOME")) |v| try allocator.dupe(u8, v) else null;
        var tmp = std.testing.tmpDir(.{});
        var state_buf: [4096:0]u8 = undefined;
        const state = try std.fmt.bufPrintZ(&state_buf, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
        _ = c.setenv("XDG_STATE_HOME", state.ptr, 1);
        return .{ .dir = tmp, .old = old };
    }

    fn deinit(self: *TmpState, allocator: std.mem.Allocator) void {
        if (self.old) |v| {
            var z: [4096:0]u8 = undefined;
            if (std.fmt.bufPrintZ(&z, "{s}", .{v})) |s| {
                _ = c.setenv("XDG_STATE_HOME", s.ptr, 1);
            } else |_| {}
            allocator.free(v);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
        self.dir.cleanup();
    }
};

test "a record round trips through its own file" {
    const t = std.testing;
    var tmp = try TmpState.init(t.allocator);
    defer tmp.deinit(t.allocator);

    var h = (try open(t.allocator, .intent, "abc")) orelse return error.LockBusy;
    defer _ = h.destroyRecord();
    try h.write(.{ .rtype = .intent, .intent = .{
        .token = "abc",
        .src = .{ .host = "box", .path = "/remote/a" },
        .dst = .{ .path = "/cache/a" },
        .state = .running,
        .job = 42,
        .paused = true,
        .ack_job = 7,
    } });
    const parsed = (try readToken(t.allocator, .intent, "abc")) orelse return error.Missing;
    defer parsed.deinit();
    try t.expectEqual(VERSION, parsed.value.version);
    try t.expectEqual(RType.intent, parsed.value.rtype);
    try t.expectEqualStrings("abc", parsed.value.intent.token);
    try t.expectEqualStrings("box", parsed.value.intent.src.host);
    try t.expectEqual(State.running, parsed.value.intent.state);
    try t.expectEqual(true, parsed.value.intent.paused);
    try t.expectEqual(@as(u64, 7), parsed.value.intent.ack_job);
}

test "an owned record cannot be taken by a second owner" {
    const t = std.testing;
    var tmp = try TmpState.init(t.allocator);
    defer tmp.deinit(t.allocator);

    var h = (try open(t.allocator, .intent, "held")) orelse return error.LockBusy;
    try h.write(.{ .intent = .{ .token = "held" } });
    // Same process, second descriptor: flock is per open file
    // description, so this must fail exactly as another process would.
    try t.expectEqual(@as(?Handle, null), try open(t.allocator, .intent, "held"));
    h.release();
    // Released: adoptable again, record intact.
    var again = (try open(t.allocator, .intent, "held")) orelse return error.LockBusy;
    defer _ = again.destroyRecord();
    const parsed = (try readToken(t.allocator, .intent, "held")) orelse return error.Missing;
    defer parsed.deinit();
    try t.expectEqualStrings("held", parsed.value.intent.token);
}

test "a client-mediated record carries what its driver needs to resume" {
    const t = std.testing;
    var tmp = try TmpState.init(t.allocator);
    defer tmp.deinit(t.allocator);

    var h = (try open(t.allocator, .intent, "med")) orelse return error.LockBusy;
    defer _ = h.destroyRecord();
    try h.write(.{ .intent = .{
        .token = "med",
        .src = .{ .host = "box", .path = "/r/f" },
        .dst = .{ .path = "/local/f" },
        .mediated = true,
        .paused = true,
        .delete_src_after = true,
        .no_replace = true,
        .open_when_done = true,
        .watch_after = true,
        .app_id = "org.x.Editor",
    } });
    const parsed = (try readToken(t.allocator, .intent, "med")) orelse return error.Missing;
    defer parsed.deinit();
    const v = parsed.value.intent;
    try t.expect(v.mediated and v.paused and v.delete_src_after and v.no_replace and v.open_when_done and v.watch_after);
    try t.expect(!v.user_copy);
    try t.expectEqualStrings("org.x.Editor", v.app_id);
    try t.expectEqualStrings("box", v.src.host);
    try t.expectEqualStrings("/local/f", v.dst.path);
}

test "a batch manifest round trips deterministic child identities" {
    const t = std.testing;
    var tmp = try TmpState.init(t.allocator);
    defer tmp.deinit(t.allocator);

    var h = (try open(t.allocator, .batch, "batch-one")) orelse return error.LockBusy;
    defer _ = h.destroyRecord();
    const items = [_]BatchItem{
        .{ .token = "child-a", .src_path = "/src/a", .dst_path = "/dst/a" },
        .{ .token = "child-b", .src_path = "/src/b", .dst_path = "/dst/b", .conflict_is_dir = true },
    };
    try h.write(.{ .rtype = .batch, .batch = .{
        .token = "batch-one",
        .batch_id = 99,
        .batch_total = 2,
        .src_host = "",
        .dst_host = "box",
        .move = true,
        .items = &items,
    } });
    const parsed = (try readToken(t.allocator, .batch, "batch-one")) orelse return error.Missing;
    defer parsed.deinit();
    try t.expectEqual(RType.batch, parsed.value.rtype);
    try t.expectEqual(@as(u64, 99), parsed.value.batch.batch_id);
    try t.expect(parsed.value.batch.move);
    try t.expectEqual(@as(usize, 2), parsed.value.batch.items.len);
    try t.expectEqualStrings("child-b", parsed.value.batch.items[1].token);
    try t.expectEqualStrings("/dst/b", parsed.value.batch.items[1].dst_path);
    try t.expectEqual(@as(?bool, true), parsed.value.batch.items[1].conflict_is_dir);
}

test "a queued browser move persists its recovery identity" {
    const t = std.testing;
    var tmp = try TmpState.init(t.allocator);
    defer tmp.deinit(t.allocator);

    var h = (try open(t.allocator, .intent, "move-record")) orelse return error.LockBusy;
    defer _ = h.destroyRecord();
    try h.write(.{ .intent = .{
        .token = "move-record",
        .client_token = "attempt-1",
        .src = .{ .host = "", .path = "/mnt/source/movie.mkv" },
        .dst = .{ .host = "box", .path = "/srv/video/movie.mkv" },
        .mediated = true,
        .user_copy = true,
        .delete_src_after = true,
        .no_replace = true,
        .coordinator_host = "relay",
        .coordinator_set = true,
        .ack_host = "relay",
        .batch_id = 0x1234,
        .batch_total = 400,
        .batch_token = "batch-1",
    } });
    const parsed = (try readToken(t.allocator, .intent, "move-record")) orelse return error.Missing;
    defer parsed.deinit();
    const v = parsed.value.intent;
    try t.expect(v.mediated and v.user_copy and v.delete_src_after and v.no_replace);
    try t.expectEqualStrings("attempt-1", v.client_token);
    try t.expectEqualStrings("/mnt/source/movie.mkv", v.src.path);
    try t.expectEqualStrings("box", v.dst.host);
    try t.expect(v.coordinator_set);
    try t.expectEqualStrings("relay", v.coordinator_host);
    try t.expectEqualStrings("relay", v.ack_host);
    try t.expectEqual(@as(u64, 0x1234), v.batch_id);
    try t.expectEqual(@as(u64, 400), v.batch_total);
    try t.expectEqualStrings("batch-1", v.batch_token);
}

test "ledger v5 excludes older writers while retaining v2 recovery" {
    try std.testing.expect(!readableVersion(1));
    try std.testing.expect(readableVersion(2));
    try std.testing.expect(readableVersion(3));
    try std.testing.expect(readableVersion(4));
    try std.testing.expect(readableVersion(5));
    try std.testing.expect(!readableVersion(6));
}

test "list reports every record identity in the ledger directory" {
    const t = std.testing;
    var tmp = try TmpState.init(t.allocator);
    defer tmp.deinit(t.allocator);

    var a = (try open(t.allocator, .intent, "one")) orelse return error.LockBusy;
    defer _ = a.destroyRecord();
    try a.write(.{ .intent = .{ .token = "one" } });
    var b = (try open(t.allocator, .watch, "two")) orelse return error.LockBusy;
    defer _ = b.destroyRecord();
    try b.write(.{ .rtype = .watch, .watch = .{ .token = "two" } });

    const entries = try list(t.allocator);
    defer freeList(t.allocator, entries);
    try t.expectEqual(@as(usize, 2), entries.len);
    var seen_intent = false;
    var seen_watch = false;
    for (entries) |e| {
        if (e.rtype == .intent and std.mem.eql(u8, e.token, "one")) seen_intent = true;
        if (e.rtype == .watch and std.mem.eql(u8, e.token, "two")) seen_watch = true;
    }
    try t.expect(seen_intent and seen_watch);
}

test "a record write is skipped when nothing changed" {
    const t = std.testing;
    var tmp = try TmpState.init(t.allocator);
    defer tmp.deinit(t.allocator);

    var h = (try open(t.allocator, .intent, "same")) orelse return error.LockBusy;
    defer _ = h.destroyRecord();
    try h.write(.{ .intent = .{ .token = "same" } });
    const first = h.written_hash;
    try h.write(.{ .intent = .{ .token = "same" } });
    try t.expectEqual(first, h.written_hash);
    try h.write(.{ .intent = .{ .token = "same", .state = .failed } });
    try t.expect(h.written_hash != first);
}

test "the legacy ledger is readable and retirable" {
    const t = std.testing;
    var tmp = try TmpState.init(t.allocator);
    defer tmp.deinit(t.allocator);

    const path = try legacyPath(t.allocator);
    defer t.allocator.free(path);
    try pathz.makeParentDirs(path);
    const doc =
        \\{"version":1,"next_order":9,"intents":[{"token":"old","state":"running","job":42,
        \\"src":{"host":"box","path":"/r/a"},"dst":{"path":"/c/a"}}],
        \\"watches":[{"token":"w1","host":"box","remote_path":"/r/a","cache_path":"/c/a"}],
        \\"acknowledgments":[7]}
    ;
    try writeFileAtomic(t.allocator, path, doc);

    const lock = (try lockLegacy(t.allocator)) orelse return error.LockBusy;
    defer lock.release();
    const parsed = (try loadLegacy(t.allocator)) orelse return error.Missing;
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 1), parsed.value.intents.len);
    try t.expectEqualStrings("old", parsed.value.intents[0].token);
    try t.expectEqual(@as(u64, 42), parsed.value.intents[0].job);
    try t.expectEqualStrings("w1", parsed.value.watches[0].token);
    try t.expectEqualSlices(u64, &.{7}, parsed.value.acknowledgments);

    try t.expect(retireLegacy(t.allocator));
    try t.expectEqual(@as(?std.json.Parsed(LegacyLedger), null), try loadLegacy(t.allocator));
}

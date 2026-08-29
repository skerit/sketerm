//! Live MCP server registry under the per-user runtime directory.
//!
//! A held flock is the liveness predicate; recorded PIDs are labels, not
//! proof. Process exit releases the lock even after SIGKILL, so doctor can
//! remove stale records without scanning process names or signalling anyone.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");
const pathZ = pathz.pathZ;
const unlinkPath = pathz.unlinkPath;

pub const Mode = enum {
    isolated,
    durable,
    shared,

    pub fn text(self: Mode) []const u8 {
        return @tagName(self);
    }
};

pub const Registration = struct {
    mode: Mode,
    name: []const u8 = "",
    profile: []const u8 = "",
    log_dir: []const u8 = "",
    mux_socket: []const u8,
};

const Record = struct {
    version: u8 = 1,
    pid: c.pid_t,
    mode: Mode,
    name: []const u8 = "",
    profile: []const u8 = "",
    log_dir: []const u8 = "",
    mux_socket: []const u8,
};

pub const Entry = struct {
    pid: c.pid_t,
    mode: Mode,
    name: []u8,
    profile: []u8,
    log_dir: []u8,
    mux_socket: []u8,
    legacy: bool = false,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.profile);
        allocator.free(self.log_dir);
        allocator.free(self.mux_socket);
    }

    /// Short operator-facing identity, preferring explicit configuration.
    pub fn displayName(self: Entry) []const u8 {
        if (self.name.len > 0) return self.name;
        if (self.profile.len > 0) return self.profile;
        if (self.log_dir.len == 0) return "";
        const trimmed = std.mem.trimEnd(u8, self.log_dir, "/");
        if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| return trimmed[slash + 1 ..];
        return trimmed;
    }
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*entry| entry.deinit(allocator);
    allocator.free(entries);
}

pub const Lease = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    record_path: []u8,
    lock_path: []u8,

    /// Publish this MCP server and hold its ownership lock until deinit/process exit.
    pub fn acquire(allocator: std.mem.Allocator, registration: Registration) !Lease {
        const dir = try ensureDir();
        const pid = c.getpid();
        const record_path = try std.fmt.allocPrint(allocator, "{s}/{d}.json", .{ dir, pid });
        errdefer allocator.free(record_path);
        const lock_path = try std.fmt.allocPrint(allocator, "{s}/{d}.lock", .{ dir, pid });
        errdefer allocator.free(lock_path);

        var z: [4096]u8 = undefined;
        const lock_z = try pathZ(&z, lock_path);
        const fd = c.open(lock_z, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        if (fd < 0) return error.LockOpenFailed;
        errdefer _ = c.close(fd);
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return error.LockHeld;

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try std.json.Stringify.value(Record{
            .pid = pid,
            .mode = registration.mode,
            .name = registration.name,
            .profile = registration.profile,
            .log_dir = registration.log_dir,
            .mux_socket = registration.mux_socket,
        }, .{}, &aw.writer);

        // Runtime-only publication: the held flock is authoritative and the
        // record is deleted at process exit, so `writeCacheFile` — the shared
        // writer's no-fsync policy, which exists for exactly this case.
        atomicwrite.writeCacheFile(record_path, aw.written(), 0o600) catch
            return error.RecordWriteFailed;

        return .{
            .allocator = allocator,
            .fd = fd,
            .record_path = record_path,
            .lock_path = lock_path,
        };
    }

    pub fn deinit(self: *Lease) void {
        unlinkPath(self.record_path);
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        unlinkPath(self.lock_path);
        self.allocator.free(self.record_path);
        self.allocator.free(self.lock_path);
    }

    /// Simulate process death in a unit test: release the flock, leave debris.
    fn abandon(self: *Lease) void {
        _ = c.close(self.fd);
        self.fd = -1;
        self.allocator.free(self.record_path);
        self.allocator.free(self.lock_path);
    }
};

/// Active registered servers, plus pre-registry mcp-tmp-PID servers when requested.
pub fn list(allocator: std.mem.Allocator, include_legacy: bool) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |*entry| entry.deinit(allocator);
        out.deinit(allocator);
    }

    try scanRegistered(allocator, &out);
    if (include_legacy) try scanLegacy(allocator, &out);
    std.mem.sort(Entry, out.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.pid < b.pid;
        }
    }.less);
    return out.toOwnedSlice(allocator);
}

/// The registry directory, created on first use so a GUI can watch it
/// before any server has registered. Process-lifetime storage.
pub fn ensureDir() ![]const u8 {
    const rt = platform.runtimeDir();
    var z: [4096]u8 = undefined;
    const base = std.fmt.bufPrintZ(&z, "{s}/sketerm", .{rt}) catch return error.PathTooLong;
    if (c.mkdir(base.ptr, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return error.MkdirFailed;
    const dir = std.fmt.bufPrintZ(&z, "{s}/sketerm/mcp-servers", .{rt}) catch return error.PathTooLong;
    if (c.mkdir(dir.ptr, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return error.MkdirFailed;
    // The returned span uses process-lifetime storage, not this stack buffer.
    return registryDirStatic();
}

fn registryDirStatic() []const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    return std.fmt.bufPrint(&S.buf, "{s}/sketerm/mcp-servers", .{platform.runtimeDir()}) catch "";
}

fn scanRegistered(allocator: std.mem.Allocator, out: *std.ArrayList(Entry)) !void {
    const dir = registryDirStatic();
    if (dir.len == 0) return;
    var z: [4096]u8 = undefined;
    const dp = c.opendir(try pathZ(&z, dir)) orelse return;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const key = name[0 .. name.len - ".json".len];
        const pid = std.fmt.parseInt(c.pid_t, key, 10) catch continue;
        const record_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
        defer allocator.free(record_path);
        const lock_path = try std.fmt.allocPrint(allocator, "{s}/{s}.lock", .{ dir, key });
        defer allocator.free(lock_path);
        switch (lockState(lock_path)) {
            .active => {},
            .stale => {
                unlinkPath(record_path);
                unlinkPath(lock_path);
                continue;
            },
            .unknown => continue,
        }
        const entry = readEntry(allocator, record_path) orelse continue;
        if (entry.pid != pid) {
            var bad = entry;
            bad.deinit(allocator);
            continue;
        }
        out.append(allocator, entry) catch |err| {
            var pending = entry;
            pending.deinit(allocator);
            return err;
        };
    }
}

fn scanLegacy(allocator: std.mem.Allocator, out: *std.ArrayList(Entry)) !void {
    var z: [4096]u8 = undefined;
    const base = std.fmt.bufPrintZ(&z, "{s}/sketerm", .{platform.runtimeDir()}) catch return;
    const dp = c.opendir(base.ptr) orelse return;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (!std.mem.startsWith(u8, name, "mcp-tmp-")) continue;
        const pid = std.fmt.parseInt(c.pid_t, name["mcp-tmp-".len..], 10) catch continue;
        if (containsPid(out.items, pid)) continue;
        const rc = c.kill(pid, 0);
        if (rc != 0 and std.posix.errno(rc) == .SRCH) continue;
        const mux_socket = try std.fmt.allocPrint(allocator, "{s}/{s}/mux.sock", .{ base, name });
        const entry = ownedEntry(allocator, .{
            .pid = pid,
            .mode = .isolated,
            .mux_socket = mux_socket,
        }, true) catch |err| {
            allocator.free(mux_socket);
            return err;
        };
        allocator.free(mux_socket);
        out.append(allocator, entry) catch |err| {
            var pending = entry;
            pending.deinit(allocator);
            return err;
        };
    }
}

const LockState = enum { active, stale, unknown };

fn lockState(lock_path: []const u8) LockState {
    var z: [4096]u8 = undefined;
    const path = pathZ(&z, lock_path) catch return .unknown;
    const fd = c.open(path, c.O_RDWR | c.O_CLOEXEC);
    if (fd < 0) return .stale;
    defer _ = c.close(fd);
    const rc = c.flock(fd, c.LOCK_EX | c.LOCK_NB);
    if (rc == 0) {
        _ = c.flock(fd, c.LOCK_UN);
        return .stale;
    }
    return switch (std.posix.errno(rc)) {
        .AGAIN, .ACCES => .active,
        else => .unknown,
    };
}

fn readEntry(allocator: std.mem.Allocator, record_path: []const u8) ?Entry {
    var z: [4096]u8 = undefined;
    const fp = c.fopen(pathZ(&z, record_path) catch return null, "rb") orelse return null;
    defer _ = c.fclose(fp);
    var buf: [16 * 1024]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, fp);
    if (n == 0 or n == buf.len) return null;
    const parsed = std.json.parseFromSlice(Record, allocator, buf[0..n], .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value.version != 1 or parsed.value.pid <= 0) return null;
    return ownedEntry(allocator, parsed.value, false) catch null;
}

fn ownedEntry(allocator: std.mem.Allocator, record: Record, legacy: bool) !Entry {
    const name = try allocator.dupe(u8, record.name);
    errdefer allocator.free(name);
    const profile = try allocator.dupe(u8, record.profile);
    errdefer allocator.free(profile);
    const log_dir = try allocator.dupe(u8, record.log_dir);
    errdefer allocator.free(log_dir);
    const mux_socket = try allocator.dupe(u8, record.mux_socket);
    return .{
        .pid = record.pid,
        .mode = record.mode,
        .name = name,
        .profile = profile,
        .log_dir = log_dir,
        .mux_socket = mux_socket,
        .legacy = legacy,
    };
}

fn containsPid(entries: []const Entry, pid: c.pid_t) bool {
    for (entries) |entry| if (entry.pid == pid) return true;
    return false;
}

const ScopedRuntime = struct {
    allocator: std.mem.Allocator,
    saved: ?[]u8,
    path: []u8,

    fn init(allocator: std.mem.Allocator, suffix: []const u8) !ScopedRuntime {
        const saved = if (c.getenv("XDG_RUNTIME_DIR")) |value|
            try allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(value))))
        else
            null;
        const path = try std.fmt.allocPrint(allocator, "/tmp/sketerm-mcp-registry-{d}-{s}", .{ c.getpid(), suffix });
        var z: [4096]u8 = undefined;
        _ = c.mkdir(try pathZ(&z, path), 0o700);
        _ = c.setenv("XDG_RUNTIME_DIR", try pathZ(&z, path), 1);
        return .{ .allocator = allocator, .saved = saved, .path = path };
    }

    fn deinit(self: *ScopedRuntime) void {
        var z: [4096]u8 = undefined;
        if (self.saved) |saved| {
            if (pathZ(&z, saved)) |saved_z| {
                _ = c.setenv("XDG_RUNTIME_DIR", saved_z, 1);
            } else |_| {}
            self.allocator.free(saved);
        } else {
            _ = c.unsetenv("XDG_RUNTIME_DIR");
        }
        pathz.removeTree(self.path);
        self.allocator.free(self.path);
    }
};

test "mcp registry lists a live lease and cleans an abandoned record" {
    const allocator = std.testing.allocator;
    var scope = try ScopedRuntime.init(allocator, "live");
    defer scope.deinit();

    var lease = try Lease.acquire(allocator, .{
        .mode = .isolated,
        .profile = "project-a",
        .log_dir = "/tmp/logs/project-a/",
        .mux_socket = "/tmp/private/mux.sock",
    });
    const entries = try list(allocator, false);
    defer freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(c.getpid(), entries[0].pid);
    try std.testing.expectEqual(Mode.isolated, entries[0].mode);
    try std.testing.expectEqualStrings("project-a", entries[0].displayName());
    try std.testing.expectEqualStrings("/tmp/private/mux.sock", entries[0].mux_socket);
    try std.testing.expect(!entries[0].legacy);

    lease.abandon();
    const after = try list(allocator, false);
    defer freeEntries(allocator, after);
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "mcp registry includes a live pre-registry ephemeral instance" {
    const allocator = std.testing.allocator;
    var scope = try ScopedRuntime.init(allocator, "legacy");
    defer scope.deinit();
    var z: [4096]u8 = undefined;
    const base = try std.fmt.bufPrintZ(&z, "{s}/sketerm", .{scope.path});
    _ = c.mkdir(base.ptr, 0o700);
    const legacy_dir = try std.fmt.bufPrintZ(&z, "{s}/sketerm/mcp-tmp-{d}", .{ scope.path, c.getpid() });
    _ = c.mkdir(legacy_dir.ptr, 0o700);

    const entries = try list(allocator, true);
    defer freeEntries(allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expect(entries[0].legacy);
    try std.testing.expectEqual(c.getpid(), entries[0].pid);
    try std.testing.expect(std.mem.endsWith(u8, entries[0].mux_socket, "/mux.sock"));
}

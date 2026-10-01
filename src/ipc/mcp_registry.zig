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
const readfile = @import("../util/readfile.zig");
const sockpath = @import("../mux/sockpath.zig");
const webpresence = @import("../web/webpresence.zig");
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

/// One sub-agent as the record publishes it, so a viewer on any host can
/// derive where to watch it (`sshroute.watchSpec`).
pub const Agent = struct {
    id: []const u8,
    app: []const u8,
    /// Every session the agent runs (opencode's `-server` included).
    sessions: []const []const u8 = &.{},
    /// `sshroute.Location` text: `instance` or `host:<destination>`.
    location: []const u8,
};

/// More agents than this are not published: an oversized record would
/// read as no server at all (`MAX_RECORD_BYTES`), which is worse.
pub const MAX_PUBLISHED_AGENTS = 64;
const MAX_RECORD_BYTES = 64 * 1024;

/// Still version 1: `agents` is additive, and a reader predating it
/// refuses any other version, so a bump would hide every new server from
/// an older GUI or doctor on the same host. Absent `agents` = a server
/// that predates publishing them (unknown), never "none".
const Record = struct {
    version: u8 = 1,
    pid: c.pid_t,
    mode: Mode,
    name: []const u8 = "",
    profile: []const u8 = "",
    log_dir: []const u8 = "",
    mux_socket: []const u8,
    agents: ?[]const Agent = null,
};

pub const Entry = struct {
    pid: c.pid_t,
    mode: Mode,
    name: []u8,
    profile: []u8,
    log_dir: []u8,
    mux_socket: []u8,
    legacy: bool = false,
    /// Null = the server does not publish its agents (older build).
    agents: ?[]Agent = null,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.profile);
        allocator.free(self.log_dir);
        allocator.free(self.mux_socket);
        if (self.agents) |owned| freeAgents(allocator, owned);
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

fn freeAgents(allocator: std.mem.Allocator, agents: []Agent) void {
    for (agents) |agent| {
        allocator.free(agent.id);
        allocator.free(agent.app);
        for (agent.sessions) |s| allocator.free(s);
        allocator.free(agent.sessions);
        allocator.free(agent.location);
    }
    allocator.free(agents);
}

fn dupeAgents(allocator: std.mem.Allocator, src: []const Agent) ![]Agent {
    const out = try allocator.alloc(Agent, src.len);
    var done: usize = 0;
    errdefer freeAgents(allocator, out[0..done]);
    for (src, out) |agent, *slot| {
        const id = try allocator.dupe(u8, agent.id);
        errdefer allocator.free(id);
        const app = try allocator.dupe(u8, agent.app);
        errdefer allocator.free(app);
        const location = try allocator.dupe(u8, agent.location);
        errdefer allocator.free(location);
        const sessions = try allocator.alloc([]const u8, agent.sessions.len);
        var n: usize = 0;
        errdefer {
            for (sessions[0..n]) |s| allocator.free(s);
            allocator.free(sessions);
        }
        for (agent.sessions) |s| {
            sessions[n] = try allocator.dupe(u8, s);
            n += 1;
        }
        slot.* = .{ .id = id, .app = app, .sessions = sessions, .location = location };
        done += 1;
    }
    return out;
}

pub const Lease = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    record_path: []u8,
    lock_path: []u8,
    pid: c.pid_t = 0,
    /// Owned copy of what was registered: `publishAgents` rewrites the
    /// whole record from it.
    registration: Registration = .{ .mode = .isolated, .mux_socket = "" },

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

        var lease: Lease = .{
            .allocator = allocator,
            .fd = fd,
            .record_path = record_path,
            .lock_path = lock_path,
            .pid = pid,
        };
        lease.registration = .{
            .mode = registration.mode,
            .name = try allocator.dupe(u8, registration.name),
            .profile = &.{},
            .log_dir = &.{},
            .mux_socket = &.{},
        };
        errdefer lease.freeRegistration();
        lease.registration.profile = try allocator.dupe(u8, registration.profile);
        lease.registration.log_dir = try allocator.dupe(u8, registration.log_dir);
        lease.registration.mux_socket = try allocator.dupe(u8, registration.mux_socket);
        try lease.write(null);
        return lease;
    }

    /// Rewrite the record (atomically, like the first publication) with
    /// the current agents; past `MAX_PUBLISHED_AGENTS` the tail is dropped.
    pub fn publishAgents(self: *Lease, agents: []const Agent) !void {
        try self.write(agents[0..@min(agents.len, MAX_PUBLISHED_AGENTS)]);
    }

    fn write(self: *Lease, agents: ?[]const Agent) !void {
        var aw: std.Io.Writer.Allocating = .init(self.allocator);
        defer aw.deinit();
        try std.json.Stringify.value(Record{
            .pid = self.pid,
            .mode = self.registration.mode,
            .name = self.registration.name,
            .profile = self.registration.profile,
            .log_dir = self.registration.log_dir,
            .mux_socket = self.registration.mux_socket,
            .agents = agents,
        }, .{ .emit_null_optional_fields = false }, &aw.writer);
        // Runtime-only publication: the held flock is authoritative and the
        // record is deleted at process exit, so `writeCacheFile` — the shared
        // writer's no-fsync policy, which exists for exactly this case.
        atomicwrite.writeCacheFile(self.record_path, aw.written(), 0o600) catch
            return error.RecordWriteFailed;
    }

    fn freeRegistration(self: *Lease) void {
        const a = self.allocator;
        a.free(self.registration.name);
        a.free(self.registration.profile);
        a.free(self.registration.log_dir);
        a.free(self.registration.mux_socket);
        self.registration = .{ .mode = .isolated, .mux_socket = "" };
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
        self.freeRegistration();
    }

    /// Simulate process death in a unit test: release the flock, leave debris.
    fn abandon(self: *Lease) void {
        _ = c.close(self.fd);
        self.fd = -1;
        self.allocator.free(self.record_path);
        self.allocator.free(self.lock_path);
        self.freeRegistration();
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
    const parsed = readfile.json(Record, allocator, record_path, MAX_RECORD_BYTES) orelse return null;
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
    errdefer allocator.free(mux_socket);
    const agents = if (record.agents) |src| try dupeAgents(allocator, src) else null;
    return .{
        .pid = record.pid,
        .mode = record.mode,
        .name = name,
        .profile = profile,
        .log_dir = log_dir,
        .mux_socket = mux_socket,
        .legacy = legacy,
        .agents = agents,
    };
}

/// What `sketerm-mux --proxy --instance <key>` may bridge to.
pub const Lookup = union(enum) {
    /// A live server's private daemon socket (owned).
    live: []u8,
    /// The instance directory exists but no live server holds it.
    dead,
    unknown,
    invalid,
};

/// Resolve an instance key against THIS host's live registry only: a
/// caller names a key, never a path, and a key no live server holds is
/// never mapped to a socket (its daemon must not be reached, let alone
/// autostarted). The key-to-path mapping is `webpresence.instanceMuxSocket`.
pub fn lookupInstance(allocator: std.mem.Allocator, key: []const u8) !Lookup {
    if (!webpresence.validInstance(key)) return .invalid;
    const anchor = try sockpath.defaultSocketPath(allocator);
    defer allocator.free(anchor);
    var buf: [webpresence.MAX_PATH]u8 = undefined;
    const want = webpresence.instanceMuxSocket(&buf, anchor, key) orelse return .invalid;
    const entries = try list(allocator, false);
    defer freeEntries(allocator, entries);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.mux_socket, want)) return .{ .live = try allocator.dupe(u8, want) };
    }
    const dir = std.fs.path.dirname(want) orelse return .unknown;
    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    if (c.stat(try pathZ(&z, dir), &st) == 0) return .dead;
    return .unknown;
}

/// One live MCP server as a daemon's session list reports it (`assistants`).
pub const Report = struct {
    /// The key `--proxy --instance` and `route:...#<key>` take.
    instance: []const u8,
    /// The server's name, else its other configured identity, else its pid.
    label: []const u8,
    mode: []const u8,
    pid: c.pid_t,
    /// Null = the server predates publishing agents: list its daemon.
    agents: ?[]const Agent = null,
};

/// Reports for `entries`, which must outlive them. A server without a
/// private instance beside `anchor` (`--shared`) is skipped: it has no
/// sessions of its own to watch.
pub fn reports(arena: std.mem.Allocator, entries: []const Entry, anchor: []const u8) ![]Report {
    var out: std.ArrayList(Report) = .empty;
    for (entries) |entry| {
        const key = webpresence.instanceKeyOf(anchor, entry.mux_socket) orelse continue;
        const shown = entry.displayName();
        try out.append(arena, .{
            .instance = key,
            .label = if (shown.len > 0) shown else try std.fmt.allocPrint(arena, "{d}", .{entry.pid}),
            .mode = entry.mode.text(),
            .pid = entry.pid,
            .agents = entry.agents,
        });
    }
    return out.toOwnedSlice(arena);
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

test "mcp registry publishes agents and still reads a record that predates them" {
    const allocator = std.testing.allocator;
    var scope = try ScopedRuntime.init(allocator, "agents");
    defer scope.deinit();
    var sock_buf: [256]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, "{s}/sketerm/mcp-tmp-{d}/mux.sock", .{ scope.path, c.getpid() });
    var lease = try Lease.acquire(allocator, .{ .mode = .isolated, .mux_socket = sock });
    defer lease.deinit();

    // Freshly acquired: no agents field at all, i.e. exactly a v1 record.
    {
        const bytes = try readfile.cappedAlloc(allocator, lease.record_path, MAX_RECORD_BYTES);
        defer allocator.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"version\":1") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"agents\"") == null);
        const entries = try list(allocator, false);
        defer freeEntries(allocator, entries);
        try std.testing.expect(entries[0].agents == null);
    }

    try lease.publishAgents(&.{
        .{ .id = "claude-1", .app = "claude", .sessions = &.{"agent-claude-1"}, .location = "instance" },
        .{ .id = "opencode-1", .app = "opencode", .sessions = &.{ "agent-opencode-1", "agent-opencode-1-server" }, .location = "host:me@b" },
    });
    const entries = try list(allocator, false);
    defer freeEntries(allocator, entries);
    const agents = entries[0].agents.?;
    try std.testing.expectEqual(@as(usize, 2), agents.len);
    try std.testing.expectEqualStrings("agent-opencode-1-server", agents[1].sessions[1]);
    try std.testing.expectEqualStrings("host:me@b", agents[1].location);

    // What a daemon reports for it.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var anchor_buf: [256]u8 = undefined;
    const anchor = try std.fmt.bufPrint(&anchor_buf, "{s}/sketerm/mux.sock", .{scope.path});
    const got = try reports(arena_state.allocator(), entries, anchor);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    var key_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key_buf, "tmp-{d}", .{c.getpid()}), got[0].instance);
    try std.testing.expectEqualStrings(try std.fmt.bufPrint(&key_buf, "{d}", .{c.getpid()}), got[0].label);
    try std.testing.expectEqualStrings("isolated", got[0].mode);
    try std.testing.expectEqual(@as(usize, 2), got[0].agents.?.len);

    // A record an older server wrote (no agents) reads as unknown agents.
    var old_buf: [512]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&old_buf, "{s}/sketerm/mcp-servers/1.json", .{scope.path});
    const old_record = "{\"version\":1,\"pid\":1,\"mode\":\"durable\",\"name\":\"old\",\"mux_socket\":\"/x/mcp-old/mux.sock\"}";
    try atomicwrite.writeCacheFile(old_path, old_record, 0o600);
    const old = readEntry(allocator, old_path).?;
    var old_mut = old;
    defer old_mut.deinit(allocator);
    try std.testing.expect(old.agents == null);
    try std.testing.expectEqualStrings("old", old.name);
}

test "an instance key resolves only to a live server's daemon" {
    const allocator = std.testing.allocator;
    var scope = try ScopedRuntime.init(allocator, "lookup");
    defer scope.deinit();
    var z: [512]u8 = undefined;
    const sock = try std.fmt.bufPrint(&z, "{s}/sketerm/mcp-live/mux.sock", .{scope.path});
    var lease = try Lease.acquire(allocator, .{ .mode = .durable, .name = "live", .mux_socket = sock });
    defer lease.deinit();

    switch (try lookupInstance(allocator, "live")) {
        .live => |path| {
            defer allocator.free(path);
            try std.testing.expectEqualStrings(sock, path);
        },
        else => return error.TestUnexpectedResult,
    }
    // A durable instance whose server exited leaves its directory behind.
    var dir_buf: [512]u8 = undefined;
    _ = c.mkdir(try std.fmt.bufPrintZ(&dir_buf, "{s}/sketerm/mcp-gone", .{scope.path}), 0o700);
    try std.testing.expectEqual(Lookup.dead, try lookupInstance(allocator, "gone"));
    try std.testing.expectEqual(Lookup.unknown, try lookupInstance(allocator, "never"));
    try std.testing.expectEqual(Lookup.invalid, try lookupInstance(allocator, "../live"));
    try std.testing.expectEqual(Lookup.invalid, try lookupInstance(allocator, ""));
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

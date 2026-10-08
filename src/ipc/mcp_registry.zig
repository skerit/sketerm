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
const vocab = @import("../agent/vocab.zig");
const pathZ = pathz.pathZ;
const unlinkPath = pathz.unlinkPath;

pub const Mode = enum {
    isolated,
    durable,
    shared,

    pub fn text(self: Mode) []const u8 {
        return @tagName(self);
    }

    /// What a bare `sketerm mcp` runs, so a surface need not name it.
    pub fn isDefault(self: Mode) bool {
        return self == .isolated;
    }
};

pub const Registration = struct {
    mode: Mode,
    name: []const u8 = "",
    profile: []const u8 = "",
    log_dir: []const u8 = "",
    /// The server's working directory (its MCP client's project).
    cwd: []const u8 = "",
    mux_socket: []const u8,
    /// The pane session the server was started from (`SKETERM_SESSION`)
    /// and its daemon (`SKETERM_MUX_SOCKET`); empty = not started from one.
    session: []const u8 = "",
    session_socket: []const u8 = "",
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
    /// `vocab.Attention` and `vocab.State` names, kept as text so a member
    /// a newer server adds reads as unknown instead of failing the whole
    /// record. Null = unknown (a server that predates them).
    attention: ?[]const u8 = null,
    state: ?[]const u8 = null,

    /// Null when unknown or a name this build does not know.
    pub fn attentionFact(self: Agent) ?vocab.Attention {
        return std.meta.stringToEnum(vocab.Attention, self.attention orelse return null);
    }

    /// Null when unknown or a name this build does not know.
    pub fn stateFact(self: Agent) ?vocab.State {
        return std.meta.stringToEnum(vocab.State, self.state orelse return null);
    }

    /// The attention to show: the published one, else (a newer server's
    /// name this build does not know) its state's; null = unknown.
    pub fn attentionOrState(self: Agent) ?vocab.Attention {
        return self.attentionFact() orelse if (self.stateFact()) |st| st.attention() else null;
    }
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
    /// Absent = an older server (unknown).
    cwd: []const u8 = "",
    mux_socket: []const u8,
    agents: ?[]const Agent = null,
    /// The process that started the server (an MCP client): how a client's
    /// in-process plugin finds the server it runs (`agent-wait --parent`).
    ppid: ?c.pid_t = null,
    /// The agent waiter socket (`agentwait.zig`); absent without one.
    agent_socket: ?[]const u8 = null,
    /// `Registration.session`/`session_socket`; absent when unset or
    /// written by an older server (unknown, never "no session").
    session: ?[]const u8 = null,
    session_socket: ?[]const u8 = null,
};

pub const Entry = struct {
    pid: c.pid_t,
    mode: Mode,
    name: []u8,
    profile: []u8,
    log_dir: []u8,
    /// Empty = unknown (an older server, or a legacy entry).
    cwd: []u8 = &.{},
    mux_socket: []u8,
    legacy: bool = false,
    /// Null = the server does not publish its agents (older build).
    agents: ?[]Agent = null,
    /// 0 = not recorded (older build).
    ppid: c.pid_t = 0,
    /// Empty = no waiter socket, or an older build.
    agent_socket: []u8 = &.{},
    /// Null = not started from a pane session, or an older build.
    session: ?[]u8 = null,
    session_socket: ?[]u8 = null,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.profile);
        allocator.free(self.log_dir);
        allocator.free(self.cwd);
        allocator.free(self.mux_socket);
        allocator.free(self.agent_socket);
        if (self.session) |v| allocator.free(v);
        if (self.session_socket) |v| allocator.free(v);
        if (self.agents) |owned| freeAgents(allocator, owned);
    }

    /// Short operator-facing identity: explicit configuration, else the
    /// working directory's name, else the log directory's; empty if none.
    pub fn displayName(self: Entry) []const u8 {
        if (self.name.len > 0) return self.name;
        if (self.profile.len > 0) return self.profile;
        const cwd = lastComponent(self.cwd);
        if (cwd.len > 0) return cwd;
        return lastComponent(self.log_dir);
    }
};

/// A path's last component, trailing slashes ignored; "/" and "" give "".
fn lastComponent(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |slash| return trimmed[slash + 1 ..];
    return trimmed;
}

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
        if (agent.attention) |v| allocator.free(v);
        if (agent.state) |v| allocator.free(v);
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
        const attention = try dupeOpt(allocator, agent.attention);
        errdefer if (attention) |v| allocator.free(v);
        const st = try dupeOpt(allocator, agent.state);
        errdefer if (st) |v| allocator.free(v);
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
        slot.* = .{ .id = id, .app = app, .sessions = sessions, .location = location, .attention = attention, .state = st };
        done += 1;
    }
    return out;
}

fn dupeOpt(allocator: std.mem.Allocator, v: ?[]const u8) !?[]u8 {
    return if (v) |s| try allocator.dupe(u8, s) else null;
}

pub const Lease = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    record_path: []u8,
    lock_path: []u8,
    pid: c.pid_t = 0,
    ppid: c.pid_t = 0,
    /// Owned copy of what was registered: `publishAgents` rewrites the
    /// whole record from it.
    registration: Registration = .{ .mode = .isolated, .mux_socket = "" },
    /// Owned; empty until `setAgentSocket`.
    agent_socket: []u8 = &.{},

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
            .ppid = c.getppid(),
        };
        lease.registration = .{
            .mode = registration.mode,
            .name = try allocator.dupe(u8, registration.name),
            .profile = &.{},
            .log_dir = &.{},
            .cwd = &.{},
            .mux_socket = &.{},
            .session = &.{},
            .session_socket = &.{},
        };
        errdefer lease.freeRegistration();
        lease.registration.profile = try allocator.dupe(u8, registration.profile);
        lease.registration.log_dir = try allocator.dupe(u8, registration.log_dir);
        lease.registration.cwd = try allocator.dupe(u8, registration.cwd);
        lease.registration.mux_socket = try allocator.dupe(u8, registration.mux_socket);
        lease.registration.session = try allocator.dupe(u8, registration.session);
        lease.registration.session_socket = try allocator.dupe(u8, registration.session_socket);
        try lease.write(null);
        return lease;
    }

    /// Rewrite the record (atomically, like the first publication) with
    /// the current agents; past `MAX_PUBLISHED_AGENTS` the tail is dropped.
    pub fn publishAgents(self: *Lease, agents: []const Agent) !void {
        try self.write(agents[0..@min(agents.len, MAX_PUBLISHED_AGENTS)]);
    }

    /// Record the agent waiter socket; the next write publishes it.
    pub fn setAgentSocket(self: *Lease, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        self.allocator.free(self.agent_socket);
        self.agent_socket = owned;
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
            .cwd = self.registration.cwd,
            .mux_socket = self.registration.mux_socket,
            .agents = agents,
            .ppid = self.ppid,
            .agent_socket = if (self.agent_socket.len > 0) self.agent_socket else null,
            .session = if (self.registration.session.len > 0) self.registration.session else null,
            .session_socket = if (self.registration.session_socket.len > 0) self.registration.session_socket else null,
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
        a.free(self.registration.cwd);
        a.free(self.registration.mux_socket);
        a.free(self.registration.session);
        a.free(self.registration.session_socket);
        self.registration = .{ .mode = .isolated, .mux_socket = "" };
        a.free(self.agent_socket);
        self.agent_socket = &.{};
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

/// The agent waiter socket of the one live server `parent` started (owned).
/// @throws error.NotFound when none has one, error.Ambiguous when several do.
pub fn agentSocketOf(allocator: std.mem.Allocator, parent: c.pid_t) ![]u8 {
    const entries = try list(allocator, false);
    defer freeEntries(allocator, entries);
    var hit: ?[]const u8 = null;
    for (entries) |e| {
        if (e.ppid != parent or e.agent_socket.len == 0) continue;
        if (hit != null) return error.Ambiguous;
        hit = e.agent_socket;
    }
    return allocator.dupe(u8, hit orelse return error.NotFound);
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
    const cwd = try allocator.dupe(u8, record.cwd);
    errdefer allocator.free(cwd);
    const mux_socket = try allocator.dupe(u8, record.mux_socket);
    errdefer allocator.free(mux_socket);
    const agents = if (record.agents) |src| try dupeAgents(allocator, src) else null;
    errdefer if (agents) |owned| freeAgents(allocator, owned);
    const agent_socket = try allocator.dupe(u8, record.agent_socket orelse "");
    errdefer allocator.free(agent_socket);
    const session = try dupeOpt(allocator, record.session);
    errdefer if (session) |v| allocator.free(v);
    const session_socket = try dupeOpt(allocator, record.session_socket);
    return .{
        .pid = record.pid,
        .mode = record.mode,
        .name = name,
        .profile = profile,
        .log_dir = log_dir,
        .cwd = cwd,
        .mux_socket = mux_socket,
        .legacy = legacy,
        .agents = agents,
        .ppid = record.ppid orelse 0,
        .agent_socket = agent_socket,
        .session = session,
        .session_socket = session_socket,
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
    /// The pane session the server runs in and its daemon; null = none,
    /// or a server (or daemon) that predates reporting them.
    session: ?[]const u8 = null,
    session_socket: ?[]const u8 = null,
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
            .session = entry.session,
            .session_socket = entry.session_socket,
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

    try lease.setAgentSocket("/x/mcp-tmp-1/agents.sock");
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
    // Who started it and where its waiter listens: a client plugin's link.
    try std.testing.expectEqual(c.getppid(), entries[0].ppid);
    try std.testing.expectEqualStrings("/x/mcp-tmp-1/agents.sock", entries[0].agent_socket);
    const by_parent = try agentSocketOf(allocator, c.getppid());
    defer allocator.free(by_parent);
    try std.testing.expectEqualStrings("/x/mcp-tmp-1/agents.sock", by_parent);
    try std.testing.expectError(error.NotFound, agentSocketOf(allocator, 1));

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
    try std.testing.expectEqual(@as(c.pid_t, 0), old.ppid);
    try std.testing.expectEqual(@as(usize, 0), old.agent_socket.len);
}

test "mcp registry round-trips attention, state and the pane session; old records read as unknown" {
    const allocator = std.testing.allocator;
    var scope = try ScopedRuntime.init(allocator, "attention");
    defer scope.deinit();
    var lease = try Lease.acquire(allocator, .{
        .mode = .isolated,
        .mux_socket = "/x/mcp-tmp-1/mux.sock",
        .session = "Cruiser",
        .session_socket = "/run/user/1/sketerm/mux.sock",
    });
    defer lease.deinit();
    try lease.publishAgents(&.{
        .{ .id = "claude-1", .app = "claude", .location = "instance", .attention = "needs_input", .state = "waiting_user" },
        // A member a newer build added: unknown here, the record still reads.
        .{ .id = "claude-2", .app = "claude", .location = "host:dalaran", .attention = "pondering", .state = "dreaming" },
        .{ .id = "opencode-1", .app = "opencode", .location = "user" },
    });
    {
        const bytes = try readfile.cappedAlloc(allocator, lease.record_path, MAX_RECORD_BYTES);
        defer allocator.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"session\":\"Cruiser\"") != null);
        // Unknown stays absent, never a null or a default that reads as a fact.
        try std.testing.expect(std.mem.indexOf(u8, bytes, "null") == null);
    }
    const entries = try list(allocator, false);
    defer freeEntries(allocator, entries);
    try std.testing.expectEqualStrings("Cruiser", entries[0].session.?);
    try std.testing.expectEqualStrings("/run/user/1/sketerm/mux.sock", entries[0].session_socket.?);
    const agents = entries[0].agents.?;
    try std.testing.expectEqual(@as(?vocab.Attention, .needs_input), agents[0].attentionFact());
    try std.testing.expectEqual(@as(?vocab.State, .waiting_user), agents[0].stateFact());
    try std.testing.expectEqual(@as(?vocab.Attention, null), agents[1].attentionFact());
    try std.testing.expectEqualStrings("pondering", agents[1].attention.?);
    try std.testing.expectEqual(@as(?vocab.Attention, null), agents[2].attentionFact());
    try std.testing.expect(agents[2].state == null);

    // A record from before these fields: no session, agents of unknown attention.
    var old_buf: [512]u8 = undefined;
    const old_path = try std.fmt.bufPrint(&old_buf, "{s}/sketerm/mcp-servers/1.json", .{scope.path});
    try atomicwrite.writeCacheFile(old_path, "{\"version\":1,\"pid\":1,\"mode\":\"isolated\",\"mux_socket\":\"/x/m.sock\",\"ppid\":7," ++
        "\"agents\":[{\"id\":\"claude-9\",\"app\":\"claude\",\"sessions\":[\"agent-claude-9\"],\"location\":\"instance\"}]}", 0o600);
    var old = readEntry(allocator, old_path).?;
    defer old.deinit(allocator);
    try std.testing.expect(old.session == null and old.session_socket == null);
    try std.testing.expect(old.agents.?[0].attention == null and old.agents.?[0].state == null);

    // What an older reader sees: the new fields are ignored, not refused.
    const OldAgent = struct { id: []const u8, app: []const u8, sessions: []const []const u8 = &.{}, location: []const u8 };
    const OldRecord = struct { version: u8 = 1, pid: c.pid_t, mode: Mode, mux_socket: []const u8, agents: ?[]const OldAgent = null };
    const bytes = try readfile.cappedAlloc(allocator, lease.record_path, MAX_RECORD_BYTES);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(OldRecord, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.agents.?.len);
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

test "display name: configuration, then the working directory, then the log directory" {
    var entry: Entry = .{
        .pid = 9,
        .mode = .isolated,
        .name = @constCast("named"),
        .profile = @constCast("prof"),
        .log_dir = @constCast("/logs/claudehere/"),
        .cwd = @constCast("/home/u/project-x/"),
        .mux_socket = @constCast("/x/mux.sock"),
    };
    try std.testing.expectEqualStrings("named", entry.displayName());
    entry.name = @constCast("");
    try std.testing.expectEqualStrings("prof", entry.displayName());
    entry.profile = @constCast("");
    try std.testing.expectEqualStrings("project-x", entry.displayName());
    entry.cwd = @constCast("/");
    try std.testing.expectEqualStrings("claudehere", entry.displayName());
    entry.log_dir = @constCast("");
    try std.testing.expectEqualStrings("", entry.displayName());
    try std.testing.expect(Mode.isolated.isDefault());
    try std.testing.expect(!Mode.durable.isDefault());
}

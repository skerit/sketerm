//! The per-user index of live MCP sub-agents: one 0600 descriptor per
//! agent in `$XDG_STATE_HOME/sketerm/agents/`, holding everything any MCP
//! server on this machine needs to pick the agent up again
//! (`agent_attach`), plus its opencode password file and the ownership
//! lock of the server driving it.
//!
//! Ownership is a held flock on `<id>.lock`, never a pid: a server's exit
//! (SIGKILL included) releases it. A takeover replaces the lock FILE, so
//! the displaced server still holds a lock, on an unlinked inode, and
//! learns it lost the agent from `Claim.stillOwned`.
//!
//! The index holds live agents, and ended ones that can be started again
//! (`agent_attach relaunch`): a descriptor is removed when its agent is
//! closed, or ends or is found gone without a way to relaunch it; a
//! relaunchable one is stamped `gone_ms` and swept after the idle TTL.

const std = @import("std");
const c = @import("../c.zig").c;
const launch = @import("../agent/launch.zig");
const retry = @import("../agent/retry.zig");
const xdg = @import("../util/xdg.zig");
const pathz = @import("../util/pathz.zig");
const readfile = @import("../util/readfile.zig");
const atomicwrite = @import("../util/atomicwrite.zig");

/// The directory under the state dir.
pub const DIR_NAME = "agents";
/// Room for `launch.MAX_EXTRA` args and env values of the longest kind,
/// JSON-escaped.
pub const DESCRIPTOR_MAX_BYTES = 4 * 1024 * 1024;
/// A name (alias) is at most this long.
pub const MAX_NAME = 64;
/// Random characters after `<app>-` in an id.
pub const ID_CHARS = 4;
/// Lowercase Crockford base32: no i, l, o or u to misread.
const ID_ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";

/// Everything needed to pick a running agent up again. Fields added
/// later default so an older descriptor still reads.
pub const Descriptor = struct {
    id: []const u8,
    app: []const u8,
    /// The caller's alias (`agent_open name`), usable wherever the id is.
    name: ?[]const u8 = null,
    session: []const u8,
    origin: []const u8,
    /// The local daemon socket the sessions run on (absent: the writing
    /// instance's private daemon, as instance descriptors were written).
    socket: ?[]const u8 = null,
    /// The durable instance that opened it; its startup reattaches it.
    instance: ?[]const u8 = null,
    server_session: ?[]const u8 = null,
    server_origin: ?[]const u8 = null,
    port: u16 = 0,
    password_file: ?[]const u8 = null,
    api_session: ?[]const u8 = null,
    binary: []const u8 = "",
    cwd: []const u8 = "",
    /// Remote agents: the host, and how the sessions reach it (a
    /// `Transport` name; absent = local).
    host: ?[]const u8 = null,
    transport: ?[]const u8 = null,
    remote_port: u16 = 0,
    forward_session: ?[]const u8 = null,
    forward_origin: ?[]const u8 = null,
    conversation: ?[]const u8 = null,
    conversed: bool = false,
    launch_model: ?[]const u8 = null,
    launch_effort: ?[]const u8 = null,
    picked_model: ?[]const u8 = null,
    relaunches: u32 = 0,
    cols: u16 = 120,
    rows: u16 = 40,
    args: []const []const u8 = &.{},
    server_args: []const []const u8 = &.{},
    tui_args: []const []const u8 = &.{},
    env: []const launch.EnvVar = &.{},
    path_prepend: []const []const u8 = &.{},
    login_shell: bool = true,
    permissions: []const launch.Permission = &.{},
    retry_on_overload: ?retry.Policy = null,
    started_ms: i64 = 0,
    /// When its sessions were found gone (Unix ms); 0 while it runs. Such a
    /// descriptor stays for `agent_attach relaunch` until the idle TTL.
    gone_ms: i64 = 0,
};

/// `<state dir>/agents`, allocated; null without a state dir.
pub fn dir(allocator: std.mem.Allocator) ?[]u8 {
    var buf: [4096]u8 = undefined;
    const base = xdg.stateDir(&buf) orelse return null;
    return std.fmt.allocPrint(allocator, "{s}/" ++ DIR_NAME, .{base}) catch null;
}

pub fn path(allocator: std.mem.Allocator, index_dir: []const u8, id: []const u8, ext: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ index_dir, id, ext });
}

/// An id or name may name a file in the index: plain characters only.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    return true;
}

/// Write `d` (atomically, 0600) and, when given, the password beside it.
pub fn write(allocator: std.mem.Allocator, index_dir: []const u8, d: Descriptor) !void {
    const p = try path(allocator, index_dir, d.id, "json");
    defer allocator.free(p);
    try pathz.makeDirs(index_dir, 0o700);
    try atomicwrite.writeJsonExact(allocator, p, d, 0o600);
}

pub fn writePassword(allocator: std.mem.Allocator, index_dir: []const u8, id: []const u8, password: []const u8) ![]u8 {
    const p = try path(allocator, index_dir, id, "pw");
    errdefer allocator.free(p);
    try pathz.makeDirs(index_dir, 0o700);
    try atomicwrite.writeFileExact(p, password, 0o600);
    return p;
}

/// Remove the agent's descriptor and password (its lock is its claim's).
pub fn remove(allocator: std.mem.Allocator, index_dir: []const u8, id: []const u8) void {
    for ([_][]const u8{ "json", "pw" }) |ext| {
        const p = path(allocator, index_dir, id, ext) catch continue;
        defer allocator.free(p);
        pathz.unlinkPath(p);
    }
}

pub fn read(allocator: std.mem.Allocator, index_dir: []const u8, id: []const u8) ?std.json.Parsed(Descriptor) {
    if (!validName(id)) return null;
    const p = path(allocator, index_dir, id, "json") catch return null;
    defer allocator.free(p);
    return readfile.json(Descriptor, allocator, p, DESCRIPTOR_MAX_BYTES);
}

/// The ids in the index, allocated from `arena`.
pub fn ids(arena: std.mem.Allocator, index_dir: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const z = try std.fmt.allocPrintSentinel(arena, "{s}", .{index_dir}, 0);
    const d = c.opendir(z.ptr) orelse return out.items;
    defer _ = c.closedir(d);
    while (c.readdir(d)) |de| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&de.*.d_name)), 0);
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        const id = name[0 .. name.len - ".json".len];
        if (!validName(id)) continue;
        try out.append(arena, try arena.dupe(u8, id));
    }
    return out.items;
}

/// The descriptor whose id, else whose name, is `key`; owned by `arena`.
pub fn resolve(arena: std.mem.Allocator, index_dir: []const u8, key: []const u8) !?Descriptor {
    if (!validName(key)) return null;
    if (read(arena, index_dir, key)) |p| return p.value;
    for (try ids(arena, index_dir)) |id| {
        const p = read(arena, index_dir, id) orelse continue;
        if (p.value.name) |n| if (std.mem.eql(u8, n, key)) return p.value;
    }
    return null;
}

/// Whether `key` is an id or a name of an agent in the index.
pub fn taken(arena: std.mem.Allocator, index_dir: []const u8, key: []const u8) !bool {
    return (try resolve(arena, index_dir, key)) != null;
}

/// A fresh `<app>-xxxx` id: no descriptor has it as id or name, and
/// `inUse` (the caller's live agents) does not know it either.
pub fn mint(arena: std.mem.Allocator, index_dir: ?[]const u8, app: []const u8, inUse: *const fn ([]const u8) bool) ![]const u8 {
    var tries: usize = 0;
    while (tries < 64) : (tries += 1) {
        var raw: [ID_CHARS]u8 = undefined;
        if (c.getentropy(&raw, raw.len) != 0) return error.NoEntropy;
        var tail: [ID_CHARS]u8 = undefined;
        for (raw, &tail) |b, *o| o.* = ID_ALPHABET[b % ID_ALPHABET.len];
        const id = try std.fmt.allocPrint(arena, "{s}-{s}", .{ app, &tail });
        if (inUse(id)) continue;
        if (index_dir) |d| if (try taken(arena, d, id)) continue;
        return id;
    }
    return error.NoFreeId;
}

/// The lock a live MCP server holds on an agent it drives.
pub const Claim = struct {
    fd: c_int,
    dev: u64,
    ino: u64,

    /// Whether the lock file is still the one this claim locked: false once
    /// another server took the agent over.
    pub fn stillOwned(self: *const Claim, lock_path: []const u8) bool {
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, lock_path) catch return false;
        var st: c.struct_stat = undefined;
        if (c.stat(p, &st) != 0) return false;
        return @as(u64, @intCast(st.st_dev)) == self.dev and @as(u64, @intCast(st.st_ino)) == self.ino;
    }

    /// Let go of the agent; `forget` also removes the lock file (the agent
    /// is gone), but only while it is still ours.
    pub fn release(self: *Claim, lock_path: []const u8, forget: bool) void {
        if (self.fd < 0) return;
        if (forget and self.stillOwned(lock_path)) pathz.unlinkPath(lock_path);
        _ = c.close(self.fd);
        self.fd = -1;
    }
};

pub const ClaimError = error{ Held, LockFailed };

/// Lock `lock_path` for this process. `takeover` replaces a lock another
/// live server holds (it notices through `stillOwned`).
/// @throws Held when a live server holds it and `takeover` is false.
pub fn claim(lock_path: []const u8, takeover: bool) ClaimError!Claim {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, lock_path) catch return error.LockFailed;
    if (takeover) _ = c.unlink(p);
    var tries: usize = 0;
    while (tries < 4) : (tries += 1) {
        const fd = c.open(p, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        if (fd < 0) return error.LockFailed;
        if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
            _ = c.close(fd);
            if (!takeover) return error.Held;
            // Someone locked the fresh file between our unlink and open.
            _ = c.unlink(p);
            continue;
        }
        var fst: c.struct_stat = undefined;
        var pst: c.struct_stat = undefined;
        if (c.fstat(fd, &fst) == 0 and c.stat(p, &pst) == 0 and fst.st_dev == pst.st_dev and fst.st_ino == pst.st_ino)
            return .{ .fd = fd, .dev = @intCast(fst.st_dev), .ino = @intCast(fst.st_ino) };
        // The file was replaced while we locked it: try the new one.
        _ = c.close(fd);
    }
    return error.LockFailed;
}

const t = std.testing;

test "descriptors round-trip, resolve by id or name, and mint fresh ids" {
    const tmp = pathz.TempDir.make("agentindex") orelse return error.SkipZigTest;
    defer tmp.remove();
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const d = try std.fmt.allocPrint(a, "{s}/agents", .{tmp.path()});
    try write(t.allocator, d, .{ .id = "claude-k3f9", .app = "claude", .name = "probe", .session = "agent-claude-k3f9", .origin = "o", .args = &.{"--x"} });
    try t.expectEqualStrings("claude-k3f9", (try resolve(a, d, "claude-k3f9")).?.id);
    try t.expectEqualStrings("claude-k3f9", (try resolve(a, d, "probe")).?.id);
    try t.expect((try resolve(a, d, "nope")) == null);
    // Nothing that is no plain name reaches the filesystem.
    try t.expect((try resolve(a, d, "../x")) == null);
    try t.expect(try taken(a, d, "probe"));
    const none = struct {
        fn f(_: []const u8) bool {
            return false;
        }
    }.f;
    const id = try mint(a, d, "claude", &none);
    try t.expect(std.mem.startsWith(u8, id, "claude-"));
    try t.expectEqual(@as(usize, "claude-".len + ID_CHARS), id.len);
    for (id["claude-".len..]) |ch| try t.expect(std.mem.indexOfScalar(u8, ID_ALPHABET, ch) != null);
    try t.expectEqual(@as(usize, 1), (try ids(a, d)).len);
    remove(t.allocator, d, "claude-k3f9");
    try t.expect((try resolve(a, d, "probe")) == null);
    // An older descriptor without the new fields still reads.
    const old = try std.json.parseFromSlice(Descriptor, t.allocator, "{\"id\":\"claude-1\",\"app\":\"claude\",\"session\":\"s\",\"origin\":\"o\"}", .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    defer old.deinit();
    try t.expect(old.value.name == null and old.value.socket == null);
}

test "ownership is a held lock: refused while held, taken over on request, noticed by the loser" {
    const tmp = pathz.TempDir.make("agentlock") orelse return error.SkipZigTest;
    defer tmp.remove();
    var buf: [256]u8 = undefined;
    const lock = try std.fmt.bufPrint(&buf, "{s}/claude-k3f9.lock", .{tmp.path()});
    var first = try claim(lock, false);
    // flock is per open file description: a second open in this process
    // conflicts exactly as another process would.
    try t.expectError(error.Held, claim(lock, false));
    var second = try claim(lock, true);
    try t.expect(!first.stillOwned(lock));
    try t.expect(second.stillOwned(lock));
    first.release(lock, true);
    // The loser's release never removes the winner's lock file.
    try t.expect(second.stillOwned(lock));
    second.release(lock, false);
    // Released: free for anyone.
    var third = try claim(lock, false);
    third.release(lock, true);
    try t.expect(!third.stillOwned(lock));
}

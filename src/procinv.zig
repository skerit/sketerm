//! The current user's running sketerm processes, as `sketerm doctor` lists them.
//!
//! Ownership is by name: an executable called `sketerm` or `sketerm-*`, or, for an image
//! re-exec'd from `/proc/self/exe` or hosted by a test rig, an argv[0] of that shape. That
//! covers the GUI under every identity hardlink, the mux daemon with its portable and
//! deployed copies, and the CEF browser helper, with no list to keep in step with them.
//! `build` is pure, so classification and tree shape are tested without live processes.

const std = @import("std");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const invocation = @import("util/invocation.zig");
const selfexec = @import("mux/selfexec.zig");
const sockpath = @import("mux/sockpath.zig");
const findbin = @import("web/findbin.zig");

pub const Role = enum {
    /// A listening mux daemon: the broker that forks a worker per session, or a daemon
    /// from a build that still held every session itself (recognised the same way, so
    /// `sketerm doctor` lists it and its sessions resolve to it as their holder).
    daemon,
    /// A daemon's fork holding exactly one session.
    worker,
    /// Any other sketerm-mux invocation; `Proc.mode` says which.
    mux_helper,
    webengine,
    /// A Chromium subprocess of the browser helper, folded into the helper's row.
    cef_subprocess,
    /// The sketerm executable under any identity or subcommand.
    sketerm,
};

pub const Proc = struct {
    pid: c.pid_t,
    ppid: c.pid_t,
    /// Milliseconds since start; negative when unknown.
    age_ms: i64,
    /// argv, NUL-separated.
    argv: []const u8,
    /// File name the process is recognised under, without directory or deleted suffix.
    name: []const u8,
    /// The executable was replaced or removed on disk after this process started.
    replaced: bool,
    role: Role,
    /// Invocation mode of a mux role; `.daemon` for every other role.
    mode: selfexec.Mode,
    /// Nesting below the nearest listed ancestor; 0 for a root.
    depth: u16 = 0,
    /// Browser subprocesses folded into this row.
    folded: u32 = 0,

    /// The `index`th argument, argv[0] included.
    pub fn arg(self: *const Proc, index: usize) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.argv, 0);
        var i: usize = 0;
        while (it.next()) |a| : (i += 1) {
            if (i == index) return a;
        }
        return null;
    }

    /// The value following option `name`, if present.
    pub fn option(self: *const Proc, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.argv, 0);
        _ = it.next();
        while (it.next()) |a| {
            if (std.mem.eql(u8, a, name)) return it.next();
        }
        return null;
    }

    /// Operator-facing role; a sketerm process is named by its binary and subcommand word.
    pub fn label(self: *const Proc, buf: []u8) []const u8 {
        return switch (self.role) {
            .daemon => "daemon",
            .worker => "session worker",
            .mux_helper => self.mode.label(),
            .webengine => "browser helper",
            .cef_subprocess => "browser subprocess",
            .sketerm => blk: {
                const word = self.arg(1) orelse break :blk self.name;
                if (word.len == 0 or word[0] == '-') break :blk self.name;
                break :blk std.fmt.bufPrint(buf, "{s} {s}", .{ self.name, word }) catch self.name;
            },
        };
    }

    /// True for the role that listens on a mux socket.
    pub fn isDaemon(self: *const Proc) bool {
        return self.role == .daemon;
    }
};

/// One process as the OS reports it; `exe` and `argv` are empty when unreadable or unneeded.
pub const Raw = struct {
    pid: c.pid_t,
    ppid: c.pid_t,
    age_ms: i64 = -1,
    exe: []const u8 = "",
    argv: []const u8 = "",
};

pub const Identity = struct {
    name: []const u8,
    replaced: bool,
    role: Role,
    mode: selfexec.Mode,
};

fn isSketermName(base: []const u8) bool {
    return std.mem.eql(u8, base, "sketerm") or std.mem.startsWith(u8, base, "sketerm-");
}

/// Classify one process, or null when it is not sketerm's. A worker reads as a daemon here:
/// it is a fork of one, argv included, and only `build` sees the parent that tells them apart.
pub fn identify(exe: []const u8, argv: []const u8) ?Identity {
    const replaced = std.mem.endsWith(u8, exe, platform.deleted_exe_suffix);
    const exe_path = if (replaced) exe[0 .. exe.len - platform.deleted_exe_suffix.len] else exe;
    const exe_name = invocation.baseName(exe_path);
    const argv0_name = invocation.baseName(std.mem.sliceTo(argv, 0));
    const name = if (isSketermName(exe_name))
        exe_name
    else if (isSketermName(argv0_name))
        argv0_name
    else
        return null;

    var args_buf: [32][]const u8 = undefined;
    const args = splitArgs(argv, &args_buf);
    if (selfexec.isBinaryName(name) or selfexec.isBinaryName(argv0_name)) {
        const mode = selfexec.modeOf(args);
        return .{ .name = name, .replaced = replaced, .role = if (mode != .daemon) .mux_helper else .daemon, .mode = mode };
    }
    if (std.mem.eql(u8, name, findbin.HELPER_NAME)) {
        const subprocess = for (args) |a| {
            if (std.mem.startsWith(u8, a, findbin.SUBPROCESS_SWITCH)) break true;
        } else false;
        return .{ .name = name, .replaced = replaced, .role = if (subprocess) .cef_subprocess else .webengine, .mode = .daemon };
    }
    return .{ .name = name, .replaced = replaced, .role = .sketerm, .mode = .daemon };
}

fn splitArgs(argv: []const u8, buf: [][]const u8) []const []const u8 {
    if (argv.len == 0) return buf[0..0];
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, argv, 0);
    while (it.next()) |a| {
        if (n == buf.len) break;
        buf[n] = a;
        n += 1;
    }
    return buf[0..n];
}

pub const Inventory = struct {
    arena: std.heap.ArenaAllocator,
    /// sketerm processes in display order: each directly after its nearest listed ancestor.
    procs: []Proc,
    /// Parent of every process the scan saw, sketerm's or not.
    parents: std.AutoHashMapUnmanaged(c.pid_t, c.pid_t),

    pub fn deinit(self: *Inventory) void {
        self.arena.deinit();
    }

    pub fn find(self: *const Inventory, pid: c.pid_t) ?*const Proc {
        for (self.procs) |*p| {
            if (p.pid == pid) return p;
        }
        return null;
    }

    /// The listed process holding the session whose child is `child_pid`: the child's parent,
    /// which is the worker under a current daemon and the daemon itself for an old build.
    pub fn sessionHolder(self: *const Inventory, child_pid: c.pid_t) ?*const Proc {
        if (child_pid <= 0) return null;
        return self.find(self.parents.get(child_pid) orelse return null);
    }
};

/// Upper bound on parent-link hops, so a corrupt or racing table cannot loop forever.
const max_hops = 256;

const Builder = struct {
    procs: []Proc,
    index: *const std.AutoHashMapUnmanaged(c.pid_t, usize),
    parents: *const std.AutoHashMapUnmanaged(c.pid_t, c.pid_t),

    /// Index of the nearest listed strict ancestor of `pid`.
    fn listedAncestor(self: Builder, pid: c.pid_t) ?usize {
        var cur = pid;
        var hops: usize = 0;
        while (hops < max_hops) : (hops += 1) {
            const parent = self.parents.get(cur) orelse return null;
            if (parent <= 0 or parent == cur) return null;
            if (self.index.get(parent)) |i| return i;
            cur = parent;
        }
        return null;
    }

    /// Index of the nearest listed ancestor of `procs[i]` for which `accept` holds.
    fn ancestorWhere(self: Builder, i: usize, ctx: anytype, comptime accept: fn (@TypeOf(ctx), usize) bool) ?usize {
        var cur = self.procs[i].pid;
        var hops: usize = 0;
        while (self.listedAncestor(cur)) |anc| : (hops += 1) {
            if (hops >= max_hops) return null;
            if (accept(ctx, anc)) return anc;
            cur = self.procs[anc].pid;
        }
        return null;
    }
};

fn notSubprocess(procs: []const Proc, i: usize) bool {
    return procs[i].role != .cef_subprocess;
}

fn isKept(keep: []const bool, i: usize) bool {
    return keep[i];
}

fn lessByPid(procs: []const Proc, lhs: usize, rhs: usize) bool {
    return procs[lhs].pid < procs[rhs].pid;
}

/// Classify `raws` and order sketerm's processes as a tree; everything kept is copied.
pub fn build(allocator: std.mem.Allocator, raws: []const Raw) !Inventory {
    var inv = Inventory{ .arena = .init(allocator), .procs = &.{}, .parents = .empty };
    errdefer inv.arena.deinit();
    const a = inv.arena.allocator();

    try inv.parents.ensureTotalCapacity(a, @intCast(raws.len));
    for (raws) |r| inv.parents.putAssumeCapacity(r.pid, r.ppid);

    var found: std.ArrayList(Proc) = .empty;
    var index: std.AutoHashMapUnmanaged(c.pid_t, usize) = .empty;
    for (raws) |r| {
        const id = identify(r.exe, r.argv) orelse continue;
        if (index.contains(r.pid)) continue;
        try index.put(a, r.pid, found.items.len);
        try found.append(a, .{
            .pid = r.pid,
            .ppid = r.ppid,
            .age_ms = r.age_ms,
            .argv = try a.dupe(u8, r.argv),
            .name = try a.dupe(u8, id.name),
            .replaced = id.replaced,
            .role = id.role,
            .mode = id.mode,
        });
    }
    const procs = found.items;
    const b = Builder{ .procs = procs, .index = &index, .parents = &inv.parents };

    // A daemon-mode process forked by a daemon-mode process is a session
    // worker: a daemon's other children are shells, apps and helpers.
    for (procs) |*p| {
        if (p.role != .daemon) continue;
        const parent = index.get(p.ppid) orelse continue;
        if (procs[parent].role == .daemon) p.role = .worker;
    }

    const keep = try a.alloc(bool, procs.len);
    @memset(keep, true);
    for (procs, 0..) |p, i| {
        if (p.role != .cef_subprocess) continue;
        const helper = b.ancestorWhere(i, @as([]const Proc, procs), notSubprocess) orelse continue;
        procs[helper].folded += 1;
        keep[i] = false;
    }

    const display_parent = try a.alloc(?usize, procs.len);
    for (display_parent, 0..) |*dp, i| {
        dp.* = if (keep[i]) b.ancestorWhere(i, @as([]const bool, keep), isKept) else null;
    }

    const sorted = try a.alloc(usize, procs.len);
    for (sorted, 0..) |*s, i| s.* = i;
    std.mem.sort(usize, sorted, @as([]const Proc, procs), lessByPid);

    var walk = Walk{
        .procs = procs,
        .keep = keep,
        .display_parent = display_parent,
        .sorted = sorted,
        .visited = try a.alloc(bool, procs.len),
        .order = try .initCapacity(a, procs.len),
    };
    @memset(walk.visited, false);
    for (sorted) |i| {
        if (keep[i] and display_parent[i] == null) walk.visit(i, 0);
    }
    // A parent cycle leaves members no root reaches; list them rather than lose them.
    for (sorted) |i| {
        if (keep[i]) walk.visit(i, 0);
    }
    inv.procs = walk.order.items;
    return inv;
}

const Walk = struct {
    procs: []const Proc,
    keep: []const bool,
    display_parent: []const ?usize,
    sorted: []const usize,
    visited: []bool,
    order: std.ArrayList(Proc),

    fn visit(self: *Walk, i: usize, depth: usize) void {
        if (self.visited[i]) return;
        self.visited[i] = true;
        var p = self.procs[i];
        p.depth = @intCast(@min(depth, std.math.maxInt(u16)));
        self.order.appendAssumeCapacity(p);
        for (self.sorted) |j| {
            if (self.keep[j] and self.display_parent[j] == i) self.visit(j, depth + 1);
        }
    }
};

pub const ScanError = error{ Unsupported, OutOfMemory };

/// Inventory of the calling user's processes, leaving out `exclude` (the caller itself).
pub fn scan(allocator: std.mem.Allocator, exclude: c.pid_t) ScanError!Inventory {
    if (!platform.can_inspect_processes) return error.Unsupported;
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const s = scratch.allocator();

    const pids = platform.listPids(try s.alloc(c.pid_t, 1 << 17));
    const argv_buf = try s.alloc(u8, 1 << 16);
    var exe_buf: [4096]u8 = undefined;
    const uid = c.getuid();
    var raws: std.ArrayList(Raw) = .empty;
    for (pids) |pid| {
        if (pid == exclude) continue;
        const info = platform.infoOfPid(pid) orelse continue;
        if (info.uid != uid) continue;
        var raw = Raw{ .pid = pid, .ppid = info.ppid, .age_ms = info.age_ms };
        const exe = platform.exeOfPid(pid, &exe_buf) orelse "";
        const argv = platform.argvOfPid(pid, argv_buf) orelse "";
        // Only sketerm's own processes need their strings; the rest serve as parent links.
        if (identify(exe, argv) != null) {
            raw.exe = try s.dupe(u8, exe);
            raw.argv = try s.dupe(u8, argv);
        }
        try raws.append(s, raw);
    }
    return build(allocator, raws.items);
}

/// Socket a daemon listens on: its `--socket` option, else the default under the runtime
/// directory its OWN environment block resolves to. Null when neither is available.
pub fn daemonSocket(allocator: std.mem.Allocator, p: *const Proc, environ: ?[]const u8) !?[]u8 {
    if (p.option(selfexec.SOCKET_FLAG)) |path| return try allocator.dupe(u8, path);
    const block = environ orelse return null;
    const rt = platform.runtimeDirFrom(
        platform.environBlockValue(block, "XDG_RUNTIME_DIR"),
        platform.environBlockValue(block, "TMPDIR"),
    );
    return try sockpath.socketPathIn(allocator, rt);
}

const t = std.testing;

test "daemonSocket prefers the socket option, then the process's own runtime dir" {
    var p = Proc{ .pid = 1, .ppid = 0, .age_ms = 0, .argv = "sketerm-mux\x00--socket\x00/tmp/a/mux.sock", .name = "sketerm-mux", .replaced = false, .role = .daemon, .mode = .daemon };
    const explicit = (try daemonSocket(t.allocator, &p, "XDG_RUNTIME_DIR=/run/user/7")).?;
    defer t.allocator.free(explicit);
    try t.expectEqualStrings("/tmp/a/mux.sock", explicit);

    p.argv = "sketerm-mux\x00--broker";
    try t.expect((try daemonSocket(t.allocator, &p, null)) == null);
    const derived = (try daemonSocket(t.allocator, &p, "HOME=/h\x00XDG_RUNTIME_DIR=/run/user/7")).?;
    defer t.allocator.free(derived);
    try t.expectEqualStrings("/run/user/7/sketerm/mux.sock", derived);
}

test "identify recognises every sketerm process shape and nothing else" {
    try t.expect(identify("/usr/bin/bash", "bash") == null);
    try t.expect(identify("", "") == null);
    try t.expect(identify("/opt/sketerm-web/bin/foo", "foo") == null);

    const gui = identify("/usr/bin/sketerm", "sketerm\x00mcp").?;
    try t.expectEqual(Role.sketerm, gui.role);
    try t.expectEqualStrings("sketerm", gui.name);
    try t.expectEqualStrings("sketerm-files", identify("/usr/bin/sketerm-files", "sketerm-files").?.name);

    const deployed = identify("/home/u/.cache/sketerm/mux/sketerm-mux-ab12 (deleted)", "sketerm-mux\x00--broker").?;
    try t.expectEqual(Role.daemon, deployed.role);
    try t.expect(deployed.replaced);
    try t.expectEqualStrings("sketerm-mux-ab12", deployed.name);

    // A daemon started before argv[0] was named still classifies by its executable.
    try t.expectEqual(Role.daemon, identify("/usr/bin/sketerm-mux", "/proc/self/exe").?.role);

    // A keeper forked by a test rig's in-process daemon: only argv[0] says what it is.
    const keeper = identify("/tmp/zig-cache/o/1/smoke-broker", "sketerm-mux\x00--keep").?;
    try t.expectEqual(Role.mux_helper, keeper.role);
    try t.expectEqual(selfexec.Mode.keep, keeper.mode);

    try t.expectEqual(Role.webengine, identify("/usr/bin/sketerm-webengine", "/usr/bin/sketerm-webengine\x00--socket\x00/x").?.role);
    try t.expectEqual(Role.cef_subprocess, identify("/usr/bin/sketerm-webengine", "/usr/bin/sketerm-webengine\x00--type=renderer").?.role);
}

test "build nests, folds browser subprocesses and tells workers from daemons" {
    const raws = [_]Raw{
        .{ .pid = 1, .ppid = 0, .exe = "/usr/lib/systemd/systemd", .argv = "systemd" },
        .{ .pid = 100, .ppid = 1, .age_ms = 5_000, .exe = "/usr/bin/sketerm-mux", .argv = "sketerm-mux\x00--broker" },
        .{ .pid = 104, .ppid = 100, .exe = "/usr/bin/sketerm-mux", .argv = "sketerm-mux\x00--broker" },
        .{ .pid = 101, .ppid = 100, .exe = "/usr/bin/sketerm-mux", .argv = "sketerm-mux\x00--broker" },
        .{ .pid = 102, .ppid = 101, .exe = "/usr/bin/bash", .argv = "-bash" },
        .{ .pid = 103, .ppid = 102, .exe = "/usr/bin/sketerm", .argv = "sketerm\x00mcp" },
        .{ .pid = 105, .ppid = 101, .exe = "/usr/bin/sketerm-mux", .argv = "sketerm-mux\x00--job" },
        .{ .pid = 50, .ppid = 1, .exe = "/usr/bin/plasmashell", .argv = "plasmashell" },
        .{ .pid = 200, .ppid = 50, .exe = "/usr/bin/sketerm", .argv = "sketerm\x00--restore" },
        .{ .pid = 201, .ppid = 200, .exe = "/usr/bin/sketerm-webengine", .argv = "sketerm-webengine\x00--socket\x00/s" },
        .{ .pid = 202, .ppid = 201, .exe = "/usr/bin/sketerm-webengine", .argv = "sketerm-webengine\x00--type=zygote" },
        .{ .pid = 203, .ppid = 202, .exe = "/usr/bin/sketerm-webengine", .argv = "sketerm-webengine\x00--type=renderer" },
    };
    var inv = try build(t.allocator, &raws);
    defer inv.deinit();

    const Want = struct { pid: c.pid_t, depth: u16, role: Role };
    const want = [_]Want{
        .{ .pid = 100, .depth = 0, .role = .daemon },
        .{ .pid = 101, .depth = 1, .role = .worker },
        .{ .pid = 103, .depth = 2, .role = .sketerm },
        .{ .pid = 105, .depth = 2, .role = .mux_helper },
        .{ .pid = 104, .depth = 1, .role = .worker },
        .{ .pid = 200, .depth = 0, .role = .sketerm },
        .{ .pid = 201, .depth = 1, .role = .webengine },
    };
    try t.expectEqual(want.len, inv.procs.len);
    for (want, inv.procs) |w, p| {
        try t.expectEqual(w.pid, p.pid);
        try t.expectEqual(w.depth, p.depth);
        try t.expectEqual(w.role, p.role);
    }
    try t.expectEqual(@as(u32, 2), inv.find(201).?.folded);
    try t.expectEqual(@as(i64, 5_000), inv.find(100).?.age_ms);

    // Session children resolve to the process holding them.
    try t.expectEqual(@as(c.pid_t, 101), inv.sessionHolder(102).?.pid);
    try t.expect(inv.sessionHolder(-1) == null);
    try t.expect(inv.sessionHolder(9999) == null);

    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("sketerm mcp", inv.find(103).?.label(&buf));
    try t.expectEqualStrings("sketerm", inv.find(200).?.label(&buf));
    try t.expectEqualStrings("file job", inv.find(105).?.label(&buf));
    try t.expectEqualStrings("session worker", inv.find(104).?.label(&buf));
}

test "an old single-process daemon still lists as a daemon holding its sessions" {
    // Builds before broker-everywhere ran without `--broker` and held
    // every shell themselves; such a daemon may still be running.
    const raws = [_]Raw{
        .{ .pid = 1, .ppid = 0, .exe = "/usr/lib/systemd/systemd", .argv = "systemd" },
        .{ .pid = 300, .ppid = 1, .exe = "/usr/bin/sketerm-mux", .argv = "sketerm-mux\x00--socket\x00/run/user/1/sketerm/mux.sock" },
        .{ .pid = 301, .ppid = 300, .exe = "/usr/bin/bash", .argv = "-bash" },
        .{ .pid = 302, .ppid = 300, .exe = "/usr/bin/sketerm-mux", .argv = "sketerm-mux\x00--keep" },
    };
    var inv = try build(t.allocator, &raws);
    defer inv.deinit();
    try t.expectEqual(Role.daemon, inv.find(300).?.role);
    try t.expect(inv.find(300).?.isDaemon());
    try t.expectEqual(Role.mux_helper, inv.find(302).?.role);
    try t.expectEqual(@as(c.pid_t, 300), inv.sessionHolder(301).?.pid);
}

test "build survives a parent cycle and duplicate pids" {
    const raws = [_]Raw{
        .{ .pid = 10, .ppid = 11, .exe = "/usr/bin/sketerm", .argv = "sketerm" },
        .{ .pid = 11, .ppid = 10, .exe = "/usr/bin/sketerm", .argv = "sketerm" },
        .{ .pid = 11, .ppid = 10, .exe = "/usr/bin/sketerm", .argv = "sketerm" },
    };
    var inv = try build(t.allocator, &raws);
    defer inv.deinit();
    try t.expectEqual(@as(usize, 2), inv.procs.len);
}

test "option reads the value after a flag" {
    const p = Proc{ .pid = 1, .ppid = 0, .age_ms = 0, .argv = "sketerm-mux\x00--broker\x00--socket\x00/tmp/a/mux.sock", .name = "sketerm-mux", .replaced = false, .role = .daemon, .mode = .daemon };
    try t.expectEqualStrings("/tmp/a/mux.sock", p.option(selfexec.SOCKET_FLAG).?);
    try t.expect(p.option("--idle-exit") == null);
}

test "scan lists nothing that is not sketerm's and never the caller" {
    if (!platform.can_inspect_processes) return error.SkipZigTest;
    var inv = try scan(t.allocator, c.getpid());
    defer inv.deinit();
    for (inv.procs) |p| {
        try t.expect(p.pid != c.getpid());
        try t.expect(p.role != .cef_subprocess or p.depth == 0);
    }
    try t.expect(inv.parents.count() > 0);
}

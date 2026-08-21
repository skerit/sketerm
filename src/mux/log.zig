//! Daemon diagnostics log: warnings always reach stderr AND a shared
//! append-only file, so a daemon whose stderr goes nowhere (GUI
//! autostart, ssh bootstrap) still leaves a post-mortem trail.
//!
//! `SKETERM_MUX_LOG` controls it:
//!   unset          info+warn to $XDG_STATE_HOME/sketerm/mux.log
//!   "off" / "0"    no file (warnings still print to stderr)
//!   "debug" / "1"  default file, plus debug-level wlhost tracing
//!   <path>         that file, debug level (an explicit path means
//!                  you asked for the firehose)
//!
//! libc only (musl-clean); no allocator, so it can't interact with
//! the smoke suites' leak-tracking DebugAllocator. Workers inherit
//! the open fd across fork(); O_APPEND keeps interleaved lines
//! whole and the [pid] prefix attributes them.

const std = @import("std");
const c = @import("../c.zig").c;
const diag = @import("../util/diag.zig");

/// One-generation rotation: at open, a file past this moves to
/// <path>.old so the log can't grow unbounded across months.
const rotate_bytes: c.off_t = 2 << 20;

const State = struct {
    fd: c_int = -1,
    debug_on: bool = false,
    inited: bool = false,
};
var g: State = .{};

pub const Cfg = struct {
    file: union(enum) { default, none, path: []const u8 },
    debug_on: bool,
};

/// Pure classification of the env value (null = unset).
pub fn parseEnv(v: ?[]const u8) Cfg {
    const s = v orelse return .{ .file = .default, .debug_on = false };
    if (s.len == 0 or std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "0"))
        return .{ .file = .none, .debug_on = false };
    if (std.mem.eql(u8, s, "debug") or std.mem.eql(u8, s, "1"))
        return .{ .file = .default, .debug_on = true };
    return .{ .file = .{ .path = s }, .debug_on = true };
}

/// Idempotent; safe to call from every embedding (mux_main, the
/// smoke suites' in-process daemon). Never fails — a log that can't
/// open its file degrades to stderr-only.
pub fn init() void {
    if (g.inited) return;
    g.inited = true;
    const env = std.c.getenv("SKETERM_MUX_LOG");
    const cfg = parseEnv(if (env) |e| std.mem.span(e) else null);
    g.debug_on = cfg.debug_on;
    var buf: [4096]u8 = undefined;
    const path: ?[]const u8 = switch (cfg.file) {
        .none => null,
        .path => |p| p,
        .default => defaultPath(&buf),
    };
    if (path) |p| g.fd = openLog(p);
}

pub fn debugOn() bool {
    return g.debug_on;
}

/// Return the append-only descriptor workers intentionally inherit.
pub fn inheritedFd() c_int {
    return g.fd;
}

/// Anomalies: stderr + file.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    diag.print("sketerm-mux: " ++ fmt ++ "\n", args);
    emit('W', fmt, args);
}

/// Lifecycle (session/client/channel churn): file only.
pub fn info(comptime fmt: []const u8, args: anytype) void {
    emit('I', fmt, args);
}

/// wlhost tracing: file only, and only under debug.
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (!g.debug_on) return;
    emit('D', fmt, args);
}

fn emit(level: u8, comptime fmt: []const u8, args: anytype) void {
    if (g.fd < 0) return;
    var line: [1024]u8 = undefined;
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_REALTIME, &ts);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&ts.tv_sec, &tm);
    const head = std.fmt.bufPrint(
        &line,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3} [{d}] {c} ",
        .{
            @as(u32, @intCast(tm.tm_year + 1900)),
            @as(u32, @intCast(tm.tm_mon + 1)),
            @as(u32, @intCast(tm.tm_mday)),
            @as(u32, @intCast(tm.tm_hour)),
            @as(u32, @intCast(tm.tm_min)),
            @as(u32, @intCast(tm.tm_sec)),
            @as(u32, @intCast(@divTrunc(ts.tv_nsec, 1_000_000))),
            c.getpid(),
            level,
        },
    ) catch return;
    const rest = line[head.len .. line.len - 1];
    const msg = std.fmt.bufPrint(rest, fmt, args) catch
        std.fmt.bufPrint(rest, "<oversized log line: {s}>", .{fmt}) catch return;
    const total = head.len + msg.len;
    line[total] = '\n';
    _ = c.write(g.fd, &line, total + 1);
}

/// $XDG_STATE_HOME/sketerm/mux.log (fallback ~/.local/state/...).
fn defaultPath(buf: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |sh| {
        const s = std.mem.span(sh);
        if (s.len > 0)
            return std.fmt.bufPrint(buf, "{s}/sketerm/mux.log", .{s}) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/sketerm/mux.log", .{std.mem.span(home)}) catch null;
}

fn openLog(path: []const u8) c_int {
    var z_buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&z_buf, "{s}", .{path}) catch return -1;
    mkdirParents(z);
    // Rotate a grown log before appending (one .old generation).
    var st: c.struct_stat = undefined;
    if (c.stat(z, &st) == 0 and st.st_size > rotate_bytes) {
        var old_buf: [4096]u8 = undefined;
        if (std.fmt.bufPrintZ(&old_buf, "{s}.old", .{path})) |old| {
            _ = c.rename(z, old);
        } else |_| {}
    }
    return c.open(z, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c.mode_t, 0o600));
}

/// mkdir -p for the file's parent directories (EEXIST is fine).
fn mkdirParents(z: [*:0]u8) void {
    const s = std.mem.span(z);
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] != '/') continue;
        s[i] = 0;
        _ = c.mkdir(z, 0o700);
        s[i] = '/';
    }
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "parseEnv: unset, off, debug, path" {
    try t.expectEqual(Cfg{ .file = .default, .debug_on = false }, parseEnv(null));
    try t.expectEqual(Cfg{ .file = .none, .debug_on = false }, parseEnv("off"));
    try t.expectEqual(Cfg{ .file = .none, .debug_on = false }, parseEnv("0"));
    try t.expectEqual(Cfg{ .file = .none, .debug_on = false }, parseEnv(""));
    try t.expectEqual(Cfg{ .file = .default, .debug_on = true }, parseEnv("debug"));
    try t.expectEqual(Cfg{ .file = .default, .debug_on = true }, parseEnv("1"));
    const p = parseEnv("/tmp/x/mux.log");
    try t.expect(p.debug_on);
    try t.expectEqualStrings("/tmp/x/mux.log", p.file.path);
}

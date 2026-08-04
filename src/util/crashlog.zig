//! GUI post-mortem: a fatal-signal handler that records WHAT the process
//! was doing when it died, plus SIGPIPE neutering.
//!
//! A GUI death is worse than a daemon death here: every attached durable
//! session loses its viewer at once, and a bare SIGSEGV/SIGPIPE in a
//! stripped ReleaseFast build leaves no trace anywhere - the only evidence
//! is the daemon's "client gone" lines on the far side, which cannot say
//! what the GUI was doing. So every risky operation drops a breadcrumb
//! (`set`/`clear`) and the handler appends it to
//! `$XDG_STATE_HOME/sketerm/crash.log` next to the daemon's mux.log.
//!
//! Async-signal-safe by construction: the log fd is opened at install
//! time, the record is formatted into a fixed buffer (no allocator, no
//! printf) and written with one `write`. The handler then re-raises the
//! signal with the default disposition, so core dumps still happen.
//!
//! libc only, no allocator - same constraints as mux/log.zig.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const platform = @import("platform.zig");

/// Longest breadcrumb kept. Truncation is fine; the leading words carry
/// the operation ("ipc attach-session 'X' @ host").
pub const CRUMB_MAX: usize = 240;

const State = struct {
    fd: c_int = -1,
    installed: bool = false,
    crumb: [CRUMB_MAX]u8 = undefined,
    crumb_len: usize = 0,
    /// Monotonic ms at install, so the record can state process uptime
    /// without touching localtime in the handler.
    start_ms: i64 = 0,
};
var g: State = .{};

/// Install the fatal-signal post-mortem handler and neuter SIGPIPE.
/// Idempotent; never fails (a log file it cannot open degrades to
/// stderr-only). Call as early as possible in main.
pub fn install() void {
    if (g.installed) return;
    g.installed = true;
    g.start_ms = nowMs();

    var buf: [4096]u8 = undefined;
    if (defaultPath(&buf)) |p| g.fd = openLog(p);

    var sa = std.mem.zeroes(c.struct_sigaction);
    platform.setSigAction(&sa, &onFatal);
    // RESETHAND: entering the handler restores the default disposition, so
    // the re-raise below dumps core and a fault INSIDE the handler cannot
    // loop forever. SA_RESETHAND does not fit a positive c_int, so the
    // flags are assembled unsigned.
    const flags: u32 = @as(u32, @intCast(c.SA_SIGINFO)) |
        @as(u32, @intCast(c.SA_NODEFER)) |
        @as(u32, @intCast(c.SA_RESETHAND));
    sa.sa_flags = @bitCast(flags);
    for (fatal_signals) |sig| _ = c.sigaction(sig, &sa, null);

    // SIGPIPE: a no-op handler rather than SIG_IGN (the SIG_IGN macro
    // translates to a bogus fn pointer - see mux_main.zig). Without this,
    // any write to a socket/pipe whose peer just exited kills the whole
    // GUI silently, taking every attached session's viewer with it. The
    // daemon, mcp server and fs jobs have always done this; the GUI never
    // did.
    _ = c.signal(c.SIGPIPE, sig_ign);
}

const fatal_signals = [_]c_int{ c.SIGSEGV, c.SIGBUS, c.SIGILL, c.SIGFPE, c.SIGABRT, c.SIGTRAP };

fn sigNoop(_: c_int) callconv(.c) void {}
const sig_ign = &sigNoop;

/// Record the operation in flight. Overwrites the previous breadcrumb.
/// Oversized text is TRUNCATED rather than dropped - the leading words are
/// the ones that identify the operation.
pub fn set(comptime fmt: []const u8, args: anytype) void {
    var w = std.Io.Writer.fixed(&g.crumb);
    w.print(fmt, args) catch {};
    g.crumb_len = w.end;
}

/// Operation finished cleanly - a later crash must not blame it.
pub fn clear() void {
    g.crumb_len = 0;
}

pub fn breadcrumb() []const u8 {
    return g.crumb[0..g.crumb_len];
}

fn onFatal(sig: c_int, info: [*c]c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    var buf: [512]u8 = undefined;
    const addr: usize = faultAddr(info);
    const code: c_int = if (info != null) info.*.si_code else 0;
    const rec = formatRecord(&buf, .{
        .sig = sig,
        .code = code,
        .addr = addr,
        .pid = c.getpid(),
        .uptime_ms = nowMs() - g.start_ms,
        .crumb = g.crumb[0..g.crumb_len],
    });
    if (g.fd >= 0) _ = c.write(g.fd, rec.ptr, rec.len);
    _ = c.write(2, rec.ptr, rec.len);
    // SA_RESETHAND already restored the default action.
    _ = c.raise(sig);
}

/// si_addr for the fault signals. `_sifields` is an unnamed union in the
/// translated header, and si_addr is its first member on Linux - read it
/// positionally rather than not reporting the address at all.
fn faultAddr(info: [*c]c.siginfo_t) usize {
    if (comptime builtin.os.tag != .linux) return 0;
    if (info == null) return 0;
    const p: *const usize = @ptrCast(@alignCast(&info.*._sifields));
    return p.*;
}

pub const Record = struct {
    sig: c_int,
    code: c_int,
    addr: usize,
    pid: c_int,
    uptime_ms: i64,
    crumb: []const u8,
};

/// Format one crash line. Pure (no fd, no clock) so it is unit-testable
/// and provably allocation-free. Always ends in a newline.
pub fn formatRecord(buf: []u8, r: Record) []const u8 {
    const line = std.fmt.bufPrint(
        buf,
        "sketerm: FATAL {s} (signal {d} code {d}) at 0x{x} pid {d} after {d}ms while: {s}\n",
        .{
            signalName(r.sig),
            r.sig,
            r.code,
            r.addr,
            r.pid,
            r.uptime_ms,
            if (r.crumb.len > 0) r.crumb else "(idle: no operation in flight)",
        },
    ) catch {
        // Truncating fallback: the signal name alone still beats silence.
        // The number's width is platform-dependent (SIGBUS is 7 on Linux
        // but 10 on Darwin), so a buffer that holds the short form on one
        // OS can overflow it on the other — degrade to a numberless
        // notice, clipped to whatever room there is, rather than to the
        // empty string this used to return.
        const short = std.fmt.bufPrint(buf, "sketerm: FATAL signal {d}\n", .{r.sig}) catch {
            const notice = "sketerm: FATAL signal\n";
            const n = @min(buf.len, notice.len);
            @memcpy(buf[0..n], notice[0..n]);
            return buf[0..n];
        };
        return short;
    };
    return line;
}

pub fn signalName(sig: c_int) []const u8 {
    return switch (sig) {
        c.SIGSEGV => "SIGSEGV",
        c.SIGBUS => "SIGBUS",
        c.SIGILL => "SIGILL",
        c.SIGFPE => "SIGFPE",
        c.SIGABRT => "SIGABRT",
        c.SIGTRAP => "SIGTRAP",
        c.SIGPIPE => "SIGPIPE",
        else => "signal",
    };
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// $XDG_STATE_HOME/sketerm/crash.log (fallback ~/.local/state/...) -
/// deliberately beside the daemon's mux.log so a post-mortem has both
/// halves of the story in one directory.
fn defaultPath(buf: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |sh| {
        const s = std.mem.span(sh);
        if (s.len > 0)
            return std.fmt.bufPrint(buf, "{s}/sketerm/crash.log", .{s}) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.local/state/sketerm/crash.log", .{std.mem.span(home)}) catch null;
}

fn openLog(path: []const u8) c_int {
    var z_buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&z_buf, "{s}", .{path}) catch return -1;
    mkdirParents(z);
    return c.open(z, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c.mode_t, 0o600));
}

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

// --- tests ------------------------------------------------------

const t = std.testing;

test "crashlog: record names the signal and the breadcrumb" {
    var buf: [512]u8 = undefined;
    const rec = formatRecord(&buf, .{
        .sig = c.SIGSEGV,
        .code = 1,
        .addr = 0xdeadbeef,
        .pid = 4242,
        .uptime_ms = 1234,
        .crumb = "ipc attach-session 'ST:AFU' @ archdev: connecting transport",
    });
    try t.expect(std.mem.indexOf(u8, rec, "SIGSEGV") != null);
    try t.expect(std.mem.indexOf(u8, rec, "0xdeadbeef") != null);
    try t.expect(std.mem.indexOf(u8, rec, "pid 4242") != null);
    try t.expect(std.mem.indexOf(u8, rec, "attach-session 'ST:AFU' @ archdev") != null);
    try t.expectEqual(@as(u8, '\n'), rec[rec.len - 1]);
}

test "crashlog: an empty breadcrumb says so instead of trailing nothing" {
    var buf: [512]u8 = undefined;
    const rec = formatRecord(&buf, .{ .sig = c.SIGABRT, .code = 0, .addr = 0, .pid = 1, .uptime_ms = 0, .crumb = "" });
    try t.expect(std.mem.indexOf(u8, rec, "no operation in flight") != null);
}

test "crashlog: a too-small buffer still reports the signal" {
    var buf: [24]u8 = undefined;
    const rec = formatRecord(&buf, .{ .sig = c.SIGBUS, .code = 0, .addr = 0, .pid = 1, .uptime_ms = 0, .crumb = "x" });
    try t.expect(std.mem.indexOf(u8, rec, "FATAL signal") != null);
}

test "crashlog: the log path resolves under XDG_STATE_HOME and opens" {
    // Restore the ambient value: later tests in this binary read it too.
    var saved_buf: [4096]u8 = undefined;
    const saved: ?[]const u8 = if (std.c.getenv("XDG_STATE_HOME")) |v|
        std.fmt.bufPrint(&saved_buf, "{s}", .{std.mem.span(v)}) catch null
    else
        null;
    defer {
        if (saved) |s| {
            var z: [4096]u8 = undefined;
            if (std.fmt.bufPrintZ(&z, "{s}", .{s})) |zz| {
                _ = c.setenv("XDG_STATE_HOME", zz.ptr, 1);
            } else |_| {}
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
    }

    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/sketerm-crashlog-test-{d}", .{c.getpid()});
    _ = c.mkdir(dir.ptr, 0o700);
    _ = c.setenv("XDG_STATE_HOME", dir.ptr, 1);
    var buf: [4096]u8 = undefined;
    const path = defaultPath(&buf) orelse return error.NoPath;
    try t.expect(std.mem.endsWith(u8, path, "/sketerm/crash.log"));
    const fd = openLog(path);
    try t.expect(fd >= 0);
    _ = c.close(fd);
    var z: [4096]u8 = undefined;
    const pz = try std.fmt.bufPrintZ(&z, "{s}", .{path});
    _ = c.unlink(pz.ptr);
}

test "crashlog: set truncates an oversized breadcrumb instead of overflowing" {
    defer clear();
    const long = "z" ** (CRUMB_MAX * 2);
    set("{s}", .{long});
    try t.expectEqual(CRUMB_MAX, breadcrumb().len);
    set("ipc {s}", .{"list"});
    try t.expectEqualStrings("ipc list", breadcrumb());
    clear();
    try t.expectEqual(@as(usize, 0), breadcrumb().len);
}

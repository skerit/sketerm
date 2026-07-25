//! FUSE-mount end-to-end smoke (headless): daemon thread + fsmount
//! serve thread + libc file ops through the kernel on the mountpoint.
//! `zig build smoke-fuse`. SKIPs (exit 0) when fusermount3 or
//! /dev/fuse is unavailable (containers, CI).

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
const client_mod = @import("mux/client.zig");
const fsdrive = @import("ipc/fsdrive.zig");
const fsmount = @import("fsmount.zig");
const pathz = @import("util/pathz.zig");

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke-fuse: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

fn daemonMain(d: *daemon_mod.Daemon) void {
    d.run() catch |err| {
        std.debug.print("smoke-fuse: daemon error: {s}\n", .{@errorName(err)});
    };
}

fn serveMain(allocator: std.mem.Allocator, fs: *fsdrive.Fs, root: []const u8, fuse_fd: c_int) void {
    fsmount.serve(allocator, fs, root, fuse_fd) catch |err| {
        std.debug.print("smoke-fuse: serve error: {s}\n", .{@errorName(err)});
    };
}

fn mkTmp(buf: *[64]u8, comptime tag: []const u8) []const u8 {
    const tmpl = "/tmp/sketerm-smoke-fuse-" ++ tag ++ "-XXXXXX";
    @memcpy(buf[0..tmpl.len], tmpl);
    buf[tmpl.len] = 0;
    const p = c.mkdtemp(@ptrCast(buf)) orelse fail("mkdtemp");
    return std.mem.span(@as([*:0]u8, @ptrCast(p)));
}

fn writeFile(dir: []const u8, name: []const u8, content: []const u8) void {
    var z: [4096]u8 = undefined;
    var pb: [4096]u8 = undefined;
    const p = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name }) catch fail("path");
    const f = c.fopen(pathz.pathZ(&z, p) catch fail("pathz"), "wb") orelse fail("fopen w");
    defer _ = c.fclose(f);
    if (content.len > 0 and c.fwrite(content.ptr, 1, content.len, f) != content.len) fail("fwrite");
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var z: [4096]u8 = undefined;
    const f = c.fopen(pathz.pathZ(&z, path) catch return null, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        out.appendSlice(allocator, buf[0..n]) catch {
            out.deinit(allocator);
            return null;
        };
    }
    return out.toOwnedSlice(allocator) catch {
        out.deinit(allocator);
        return null;
    };
}

fn haveFuse() bool {
    if (comptime builtin.os.tag != .linux) return false;
    if (c.access("/dev/fuse", c.F_OK) != 0) return false;
    // fusermount3 findable?
    const pid = c.fork();
    if (pid == 0) {
        _ = c.close(1);
        _ = c.close(2);
        const argv = [_:null]?[*:0]const u8{ "fusermount3", "--version", null };
        _ = c.execvp("fusermount3", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    var st: c_int = 0;
    _ = c.waitpid(pid, &st, 0);
    return c.WIFEXITED(st) and c.WEXITSTATUS(st) == 0;
}

fn sigNoop(_: c_int) callconv(.c) void {}

pub fn main() u8 {
    // Teardown races (daemon gone before the last conn writes) must
    // surface as EPIPE, not kill the smoke. Same idiom as mux_main.
    _ = c.signal(c.SIGPIPE, &sigNoop);
    if (!haveFuse()) {
        std.debug.print("smoke-fuse: SKIP (no fusermount3 / /dev/fuse)\n", .{});
        return 0;
    }
    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    defer if (gpa_state.deinit() == .leak) {
        std.debug.print("smoke-fuse: FAIL — leaked memory\n", .{});
        std.process.exit(1);
    };
    const allocator = gpa_state.allocator();

    // Daemon + source tree.
    var path_buf: [128]u8 = undefined;
    const sock = std.fmt.bufPrint(&path_buf, "/tmp/sketerm-smoke-fuse-{d}/mux.sock", .{c.getpid()}) catch unreachable;
    const d = daemon_mod.Daemon.init(allocator, sock) catch fail("daemon init");
    const th = std.Thread.spawn(.{}, daemonMain, .{d}) catch fail("daemon thread");

    var sbuf: [64]u8 = undefined;
    const src = mkTmp(&sbuf, "src");
    var mbuf: [64]u8 = undefined;
    const mnt = mkTmp(&mbuf, "mnt");
    writeFile(src, "hello.txt", "content over fuse\n");
    {
        var z: [4096]u8 = undefined;
        var pb: [4096]u8 = undefined;
        const sub = std.fmt.bufPrint(&pb, "{s}/subdir", .{src}) catch unreachable;
        _ = c.mkdir(pathz.pathZ(&z, sub) catch unreachable, 0o755);
        writeFile(sub, "nested.txt", "deep\n");
    }
    // A file bigger than one FUSE read for the ranged-read path.
    {
        var big: [256 * 1024]u8 = undefined;
        for (&big, 0..) |*b, i| b.* = @truncate(i *% 7 +% 3);
        writeFile(src, "big.bin", &big);
    }

    var conn = client_mod.Conn.connectProbed(allocator, sock) catch fail("connect");
    _ = &conn;
    var fs = fsdrive.Fs.initConn(allocator, conn);
    defer fs.deinit();

    var mnt_z: [4096:0]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&mnt_z, "{s}", .{mnt}) catch unreachable;
    const fuse_fd = fsmount.openFuseFd(mp.ptr) catch {
        // Sandboxes may deny the mount syscall even with the binary
        // present — that is an environment SKIP, not a code failure.
        std.debug.print("smoke-fuse: SKIP (fusermount3 present but mount denied)\n", .{});
        return 0;
    };
    const sth = std.Thread.spawn(.{}, serveMain, .{ allocator, &fs, src, fuse_fd }) catch fail("serve thread");

    // ── readdir sees the source tree ───────────────────────────
    std.debug.print("smoke-fuse: stage readdir\n", .{});
    {
        var found_hello = false;
        var found_sub = false;
        var z: [4096]u8 = undefined;
        const dir = c.opendir(pathz.pathZ(&z, mnt) catch unreachable) orelse fail("opendir mnt");
        while (c.readdir(dir)) |de| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (std.mem.eql(u8, name, "hello.txt")) found_hello = true;
            if (std.mem.eql(u8, name, "subdir")) found_sub = true;
        }
        _ = c.closedir(dir);
        if (!found_hello or !found_sub) fail("readdir missing entries");
    }

    // ── read content (small + multi-chunk) ─────────────────────
    std.debug.print("smoke-fuse: stage read\n", .{});
    {
        var pb: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/hello.txt", .{mnt}) catch unreachable;
        const got = readFileAlloc(allocator, p) orelse fail("read hello");
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, "content over fuse\n")) fail("hello content");

        const pb2 = std.fmt.bufPrint(&pb, "{s}/big.bin", .{mnt}) catch unreachable;
        const big = readFileAlloc(allocator, pb2) orelse fail("read big");
        defer allocator.free(big);
        if (big.len != 256 * 1024) fail("big size");
        for (big, 0..) |b, i| {
            if (b != @as(u8, @truncate(i *% 7 +% 3))) fail("big content");
        }
    }

    // ── nested lookup ──────────────────────────────────────────
    std.debug.print("smoke-fuse: stage nested\n", .{});
    {
        var pb: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/subdir/nested.txt", .{mnt}) catch unreachable;
        const got = readFileAlloc(allocator, p) orelse fail("read nested");
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, "deep\n")) fail("nested content");
    }

    // ── write through the mount → appears in the source dir ───
    std.debug.print("smoke-fuse: stage write\n", .{});
    {
        writeFile(mnt, "written.txt", "written through fuse\n");
        var pb: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/written.txt", .{src}) catch unreachable;
        const got = readFileAlloc(allocator, p) orelse fail("written missing in src");
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, "written through fuse\n")) fail("written content");
    }

    // ── mkdir / rename / unlink / symlink+readlink ─────────────
    std.debug.print("smoke-fuse: stage verbs\n", .{});
    {
        var z: [4096]u8 = undefined;
        var pb: [4096]u8 = undefined;
        const nd = std.fmt.bufPrint(&pb, "{s}/newdir", .{mnt}) catch unreachable;
        if (c.mkdir(pathz.pathZ(&z, nd) catch unreachable, 0o755) != 0) fail("mkdir via fuse");
        var pb2: [4096]u8 = undefined;
        const rd = std.fmt.bufPrint(&pb2, "{s}/renamed", .{mnt}) catch unreachable;
        var z2: [4096]u8 = undefined;
        if (c.rename(pathz.pathZ(&z, nd) catch unreachable, pathz.pathZ(&z2, rd) catch unreachable) != 0)
            fail("rename via fuse");
        var pb3: [4096]u8 = undefined;
        const srcrd = std.fmt.bufPrint(&pb3, "{s}/renamed", .{src}) catch unreachable;
        var st: c.struct_stat = undefined;
        if (c.stat(pathz.pathZ(&z, srcrd) catch unreachable, &st) != 0) fail("renamed dir missing in src");

        const ln = std.fmt.bufPrint(&pb3, "{s}/lnk", .{mnt}) catch unreachable;
        if (c.symlink("hello.txt", pathz.pathZ(&z, ln) catch unreachable) != 0) fail("symlink via fuse");
        var tgt: [256]u8 = undefined;
        const tn = c.readlink(pathz.pathZ(&z, ln) catch unreachable, &tgt, tgt.len);
        if (tn <= 0 or !std.mem.eql(u8, tgt[0..@intCast(tn)], "hello.txt")) fail("readlink via fuse");
        if (c.unlink(pathz.pathZ(&z, ln) catch unreachable) != 0) fail("unlink via fuse");
        if (c.rmdir(pathz.pathZ(&z2, rd) catch unreachable) != 0) fail("rmdir via fuse");
    }

    // ── O_TRUNC rewrite keeps content coherent ─────────────────
    std.debug.print("smoke-fuse: stage trunc\n", .{});
    {
        writeFile(mnt, "hello.txt", "replaced\n");
        var pb: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "{s}/hello.txt", .{src}) catch unreachable;
        const got = readFileAlloc(allocator, p) orelse fail("replaced missing");
        defer allocator.free(got);
        if (!std.mem.eql(u8, got, "replaced\n")) fail("replaced content");
    }

    // ── unmount ends the serve loop ────────────────────────────
    std.debug.print("smoke-fuse: stage unmount\n", .{});
    fsmount.unmount(mp.ptr);
    sth.join();

    {
        var sconn = client_mod.Conn.connect(allocator, sock) catch fail("shutdown connect");
        defer sconn.deinit();
        sconn.sendFrame(.shutdown, "") catch fail("shutdown send");
    }
    th.join();
    d.deinit();

    std.debug.print("smoke-fuse: OK\n", .{});
    return 0;
}

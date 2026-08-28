//! A loopback HTTPS server with a throwaway self-signed certificate,
//! for the smoke rigs (smoke-web's certificate stages, smoke-mcp's
//! refused open). Needs `openssl`; when it is missing or the port never
//! comes up, `start` answers null and the caller SKIPS rather than
//! fails. Libc only, so both dependency sets can import it.

const std = @import("std");
const c = @import("c.zig").c;
const clock = @import("util/clock.zig");

pub const Server = struct {
    pid: c.pid_t,
    port: u16,

    pub fn stop(self: Server) void {
        _ = c.kill(self.pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(self.pid, &status, 0);
    }
};

/// Run `openssl` to completion with `args` (argv[0] included). True on
/// a clean exit.
fn runOpenssl(args: []const ?[*:0]const u8) bool {
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        // stdin from /dev/null: an `openssl req` missing a switch
        // PROMPTS, and a prompting child would hang the whole rig.
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
        }
        var vec: [20:null]?[*:0]const u8 = @splat(null);
        if (args.len >= vec.len) c._exit(127);
        for (args, 0..) |a, i| vec[i] = a;
        _ = c.execvp("openssl", @ptrCast(@constCast(&vec)));
        c._exit(127);
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, 0) != pid) return false;
    return status == 0;
}

pub fn writeFile(dir: []const u8, name: []const u8, body: []const u8) bool {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir, name }) catch return false;
    const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o644));
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.write(fd, body.ptr, body.len) == @as(isize, @intCast(body.len));
}

/// Mint a self-signed certificate in `dir` and serve `dir`'s files on
/// a loopback port (`openssl s_server -WWW`: a request for `/x.html`
/// answers `dir/x.html`). Write the pages before calling.
pub fn start(dir: []const u8) ?Server {
    var key_buf: [512]u8 = undefined;
    const key = std.fmt.bufPrintZ(&key_buf, "{s}/k.pem", .{dir}) catch return null;
    var crt_buf: [512]u8 = undefined;
    const crt = std.fmt.bufPrintZ(&crt_buf, "{s}/c.pem", .{dir}) catch return null;
    // `-subj` is not optional: without it `req` prompts for a subject.
    if (!runOpenssl(&[_]?[*:0]const u8{
        "openssl", "req",    "-x509", "-newkey",       "rsa:2048",
        "-keyout", key.ptr,  "-out",  crt.ptr,         "-days",
        "1",       "-nodes", "-subj", "/CN=localhost",
    })) return null;

    // A port derived from the pid keeps two concurrent rigs apart
    // without a discovery protocol; a busy one simply fails to serve
    // and the stage skips.
    const port: u16 = @intCast(20000 + @mod(c.getpid(), 20000));
    var port_buf: [16]u8 = undefined;
    const port_z = std.fmt.bufPrintZ(&port_buf, "{d}", .{port}) catch return null;

    const pid = c.fork();
    if (pid < 0) return null;
    if (pid == 0) {
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
        }
        // `-WWW` serves files relative to the CWD.
        var dir_z: [512:0]u8 = @splat(0);
        if (dir.len >= dir_z.len) c._exit(127);
        @memcpy(dir_z[0..dir.len], dir);
        if (c.chdir(&dir_z) != 0) c._exit(127);
        var vec: [12:null]?[*:0]const u8 = @splat(null);
        vec[0] = "openssl";
        vec[1] = "s_server";
        vec[2] = "-key";
        vec[3] = key.ptr;
        vec[4] = "-cert";
        vec[5] = crt.ptr;
        vec[6] = "-accept";
        vec[7] = port_z.ptr;
        vec[8] = "-WWW";
        vec[9] = "-quiet";
        _ = c.execvp("openssl", @ptrCast(@constCast(&vec)));
        c._exit(127);
    }
    // Wait for the port to accept, which is also how a dead openssl
    // (missing binary, busy port) is noticed.
    const deadline = clock.nowMs() + 5000;
    while (clock.nowMs() < deadline) {
        var status: c_int = 0;
        if (c.waitpid(pid, &status, c.WNOHANG) == pid) return null;
        if (probePort(port)) return .{ .pid = pid, .port = port };
        _ = c.usleep(100_000);
    }
    _ = c.kill(pid, c.SIGKILL);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return null;
}

pub fn probePort(port: u16) bool {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var addr = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_port = std.mem.nativeToBig(u16, port);
    addr.sin_addr.s_addr = std.mem.nativeToBig(u32, 0x7f000001);
    return c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) == 0;
}

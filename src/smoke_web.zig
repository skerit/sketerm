//! `zig build smoke-web` — end-to-end smoke for `sketerm-web`, the CEF
//! browser helper, and for `src/web/protocol.zig` as a CLIENT (the rig
//! encodes/decodes with the same module the helper speaks). Spawns the
//! helper on a short private socket with an isolated cache dir and
//! drives it through: handshake, painting into a memfd, a trusted
//! click, keyboard text entry, resize (new buffer), popup requests,
//! back/forward navigation state, and a clean shutdown on disconnect.
//!
//! Headless by construction: the helper runs CEF with
//! `--ozone-platform=headless`, so no display is needed. No network is
//! touched — every page is a data: URL and the one popup target is
//! `example.invalid`, which the helper cancels before any load.

const std = @import("std");
const c = @import("c.zig").c;
const proto = @import("web/protocol.zig");

const view_id: u32 = 1;

/// Pages under test. `#` MUST be percent-encoded inside a data: URL —
/// a raw one starts the fragment and truncates the document.
const red_page = "data:text/html,<body%20style=%22margin:0;background:%23ff0000%22></body>";
const blue_page = "data:text/html,<body%20style=%22margin:0;background:%230000ff%22></body>";
const click_page =
    "data:text/html,<html><body style=\"margin:0\">" ++
    "<button style=\"position:fixed;left:0;top:0;width:100vw;height:100vh;" ++
    "background:%230000ff;border:0\" " ++
    "onclick=\"document.title='result:trusted='+event.isTrusted+" ++
    "'%20x='+event.clientX+'%20y='+event.clientY+'%20detail='+event.detail\">" ++
    "</button></body></html>";
const input_page =
    "data:text/html,<body><input%20id=i%20autofocus%20" ++
    "oninput=%22document.title='typed:'+this.value%22></body>";
const popup_page =
    "data:text/html,<body%20style=%22margin:0%22>" ++
    "<div%20style=%22width:100vw;height:100vh%22%20" ++
    "onclick=%22window.open('https://example.invalid/x')%22></div></body>";

// Cleanup state: `fail` may fire from anywhere, and the helper must
// never be left running nor the temp dir behind. Killed by EXACT pid.
var g_pid: c.pid_t = -1;
var g_dir: [64]u8 = @splat(0);

fn say(msg: []const u8) void {
    _ = c.write(2, msg.ptr, msg.len);
    _ = c.write(2, "\n", 1);
}

fn cleanup() void {
    if (g_pid > 0) {
        _ = c.kill(g_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(g_pid, &status, 0);
        g_pid = -1;
    }
    if (g_dir[0] != 0) {
        removeTree(@ptrCast(&g_dir));
        g_dir[0] = 0;
    }
}

fn fail(comptime msg: []const u8) noreturn {
    say("smoke-web: FAIL " ++ msg);
    cleanup();
    std.process.exit(1);
}

fn pass(comptime msg: []const u8) void {
    say("smoke-web: PASS " ++ msg);
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// `rm -rf` by subprocess: the cache dir is a Chromium profile, and a
/// hand-rolled recursive unlink buys nothing in a test rig.
fn removeTree(path: [*:0]const u8) void {
    const pid = c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        var argv: [4:null]?[*:0]const u8 = @splat(null);
        argv[0] = "rm";
        argv[1] = "-rf";
        argv[2] = path;
        _ = c.execv("/bin/rm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

/// The client half of the v1 protocol: framing over a unix socket plus
/// the last-seen value of every event the stages assert on.
const Client = struct {
    gpa: std.mem.Allocator,
    fd: c_int,
    in: std.ArrayList(u8) = .empty,

    /// Descriptors harvested from SCM_RIGHTS, consumed in order by the
    /// `frame_buffer` frames they accompany.
    fds: [8]c_int = @splat(-1),
    nfds: usize = 0,

    ack_proto: u32 = 0,
    ack_shm: bool = false,

    fb: ?proto.FrameBuffer = null,
    fb_fd: c_int = -1,
    fb_seq: u32 = 0,
    map: []align(std.heap.page_size_min) u8 = &.{},

    dmg_buf: u32 = 0,
    dmg_seq: u32 = 0,

    title: [1024]u8 = @splat(0),
    title_len: usize = 0,

    popup_view: u32 = 0,
    popup_url: [1024]u8 = @splat(0),
    popup_len: usize = 0,

    nav_back: u8 = 0,
    nav_fwd: u8 = 0,
    nav_seq: u32 = 0,

    fn deinit(self: *Client) void {
        self.unmap();
        if (self.fb_fd >= 0) _ = c.close(self.fb_fd);
        for (self.fds[0..self.nfds]) |fd| _ = c.close(fd);
        self.in.deinit(self.gpa);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }

    fn unmap(self: *Client) void {
        if (self.map.len == 0) return;
        _ = c.munmap(self.map.ptr, self.map.len);
        self.map = &.{};
    }

    fn send(self: *Client, value: anytype) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        proto.encode(self.gpa, &buf, value) catch fail("encode");
        var off: usize = 0;
        while (off < buf.items.len) {
            const n = c.write(self.fd, buf.items.ptr + off, buf.items.len - off);
            if (n <= 0) fail("write to helper");
            off += @intCast(n);
        }
    }

    /// Read whatever is available (up to `timeout_ms`) and fold it into
    /// the observed state.
    fn pump(self: *Client, timeout_ms: c_int) void {
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, timeout_ms) <= 0) return;

        var buf: [64 * 1024]u8 = undefined;
        var iov = c.struct_iovec{ .iov_base = &buf, .iov_len = buf.len };
        var mh = std.mem.zeroes(c.struct_msghdr);
        mh.msg_iov = @ptrCast(&iov);
        mh.msg_iovlen = 1;
        var cbuf: [256]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([256]u8);
        mh.msg_control = &cbuf;
        mh.msg_controllen = cbuf.len;

        const n = c.recvmsg(self.fd, &mh, 0);
        if (n == 0) fail("helper closed the socket");
        if (n < 0) {
            const e = std.c._errno().*;
            if (e == c.EINTR or e == c.EAGAIN) return;
            fail("recvmsg");
        }
        self.harvestFds(&cbuf, @intCast(mh.msg_controllen));
        self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch fail("oom");

        var reader = proto.Reader.init(self.in.items);
        while (reader.next() catch fail("malformed frame")) |frame| self.handle(frame);
        const used = reader.consumed();
        if (used != 0) {
            const rest = self.in.items.len - used;
            std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[used..]);
            self.in.shrinkRetainingCapacity(rest);
        }
    }

    /// Walk the control buffer by hand — CMSG_* are macros translate-c
    /// does not export.
    fn harvestFds(self: *Client, cbuf: []align(@alignOf(c.struct_cmsghdr)) u8, len: usize) void {
        const hdr_size = @sizeOf(c.struct_cmsghdr);
        var off: usize = 0;
        while (off + hdr_size <= len) {
            const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(&cbuf[off]));
            const clen: usize = @intCast(hdr.cmsg_len);
            if (clen < hdr_size or off + clen > len) break;
            if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS) {
                var i: usize = 0;
                while (i + @sizeOf(c_int) <= clen - hdr_size) : (i += @sizeOf(c_int)) {
                    var fd: c_int = undefined;
                    @memcpy(std.mem.asBytes(&fd), cbuf[off + hdr_size + i ..][0..@sizeOf(c_int)]);
                    if (self.nfds == self.fds.len) fail("too many descriptors queued");
                    self.fds[self.nfds] = fd;
                    self.nfds += 1;
                }
            }
            off += std.mem.alignForward(usize, clen, @alignOf(c.struct_cmsghdr));
        }
    }

    fn takeFd(self: *Client) c_int {
        if (self.nfds == 0) fail("frame_buffer without an SCM_RIGHTS descriptor");
        const fd = self.fds[0];
        var i: usize = 1;
        while (i < self.nfds) : (i += 1) self.fds[i - 1] = self.fds[i];
        self.nfds -= 1;
        return fd;
    }

    fn handle(self: *Client, frame: proto.Frame) void {
        switch (frame.tag) {
            .hello_ack => {
                const ack = proto.HelloAck.decodeAlloc(frame.payload, self.gpa) catch fail("hello_ack decode");
                defer self.gpa.free(ack.caps);
                self.ack_proto = ack.proto;
                for (ack.caps) |cap| {
                    if (std.mem.eql(u8, cap, proto.CAP_FRAMES_SHM)) self.ack_shm = true;
                }
            },
            .frame_buffer => {
                const fb = proto.decode(proto.FrameBuffer, frame.payload) catch fail("frame_buffer decode");
                const fd = self.takeFd();
                self.unmap();
                if (self.fb_fd >= 0) _ = c.close(self.fb_fd);
                self.fb_fd = fd;
                self.fb = fb;
                self.fb_seq += 1;
            },
            .frame_damage => {
                const d = proto.FrameDamage.decodeAlloc(frame.payload, self.gpa) catch fail("frame_damage decode");
                defer self.gpa.free(d.rects);
                self.dmg_buf = d.buf_id;
                self.dmg_seq += 1;
            },
            .ev_title => {
                const t = proto.decode(proto.EvTitle, frame.payload) catch fail("ev_title decode");
                self.title_len = @min(t.title.len, self.title.len);
                @memcpy(self.title[0..self.title_len], t.title[0..self.title_len]);
            },
            .ev_popup_request => {
                const p = proto.decode(proto.EvPopupRequest, frame.payload) catch fail("ev_popup_request decode");
                self.popup_view = p.view;
                self.popup_len = @min(p.url.len, self.popup_url.len);
                @memcpy(self.popup_url[0..self.popup_len], p.url[0..self.popup_len]);
            },
            .ev_nav_state => {
                const s = proto.decode(proto.EvNavState, frame.payload) catch fail("ev_nav_state decode");
                self.nav_back = s.can_back;
                self.nav_fwd = s.can_fwd;
                self.nav_seq += 1;
            },
            else => {},
        }
    }

    /// Map the currently announced buffer read-only.
    fn mapBuffer(self: *Client) void {
        const fb = self.fb orelse fail("no frame_buffer announced");
        self.unmap();
        const size: usize = @as(usize, fb.stride) * @as(usize, fb.h);
        const addr = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, self.fb_fd, 0);
        if (addr == c.MAP_FAILED) fail("mmap of the frame memfd");
        const bytes: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(addr));
        self.map = bytes[0..size];
    }

    /// BGRA pixel at logical (x, y) in the mapped buffer.
    fn pixel(self: *Client, x: u32, y: u32) [4]u8 {
        const fb = self.fb orelse fail("no frame_buffer announced");
        const off = @as(usize, y) * @as(usize, fb.stride) + @as(usize, x) * 4;
        if (off + 4 > self.map.len) fail("pixel outside the mapped buffer");
        return .{ self.map[off], self.map[off + 1], self.map[off + 2], self.map[off + 3] };
    }

    fn resetTitle(self: *Client) void {
        self.title_len = 0;
    }

    fn titleSlice(self: *Client) []const u8 {
        return self.title[0..self.title_len];
    }

    fn waitTitle(self: *Client, prefix: []const u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (std.mem.startsWith(u8, self.titleSlice(), prefix)) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn waitDamageAfter(self: *Client, seq: u32, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.dmg_seq > seq) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn waitBufferAfter(self: *Client, seq: u32, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.fb_seq > seq) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn waitPopup(self: *Client, needle: []const u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (std.mem.indexOf(u8, self.popup_url[0..self.popup_len], needle) != null) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn waitCanForward(self: *Client, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            if (self.nav_fwd == 1) return true;
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    /// Wait until the centre pixel matches `want` (BGR, alpha ignored),
    /// remapping on every announced buffer so a resize is picked up.
    fn waitCenterColor(self: *Client, want: [3]u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var mapped_seq: u32 = 0;
        while (true) {
            if (self.fb != null and self.fb_seq != mapped_seq) {
                self.mapBuffer();
                mapped_seq = self.fb_seq;
            }
            if (self.map.len != 0) {
                const fb = self.fb.?;
                const px = self.pixel(fb.w / 2, fb.h / 2);
                var ok = true;
                for (0..3) |i| {
                    const diff = @as(i32, px[i]) - @as(i32, want[i]);
                    if (@abs(diff) > 24) ok = false;
                }
                if (ok) return true;
            }
            if (nowMs() > deadline) return false;
            self.pump(50);
        }
    }

    fn clickCenter(self: *Client) void {
        const fb = self.fb orelse fail("no frame_buffer announced");
        const x: i32 = @intCast(fb.w / 2);
        const y: i32 = @intCast(fb.h / 2);
        self.send(proto.InputPointer{ .view = view_id, .kind = @intFromEnum(proto.PointerKind.move), .x = x, .y = y, .button = 0, .clicks = 0, .mods = 0 });
        self.send(proto.InputPointer{ .view = view_id, .kind = @intFromEnum(proto.PointerKind.down), .x = x, .y = y, .button = 0, .clicks = 1, .mods = 0 });
        self.send(proto.InputPointer{ .view = view_id, .kind = @intFromEnum(proto.PointerKind.up), .x = x, .y = y, .button = 0, .clicks = 1, .mods = 0 });
    }

    fn typeKey(self: *Client, keysym: u32, text: []const u8) void {
        self.send(proto.InputKey{ .view = view_id, .kind = @intFromEnum(proto.KeyKind.down), .keyval = keysym, .keycode = 0, .mods = 0, .text = text });
        self.send(proto.InputKey{ .view = view_id, .kind = @intFromEnum(proto.KeyKind.up), .keyval = keysym, .keycode = 0, .mods = 0, .text = "" });
    }

    /// Navigate and wait for the paint that follows.
    fn navigate(self: *Client, url: []const u8) void {
        const seq = self.dmg_seq;
        self.resetTitle();
        self.send(proto.Navigate{ .view = view_id, .url = url });
        if (!self.waitDamageAfter(seq, 20_000)) fail("no paint after navigate");
    }
};

/// Connect to the helper's socket, retrying while it starts CEF up.
fn connectWithRetry(path: [*:0]const u8, path_len: usize) c_int {
    var addr = std.mem.zeroes(c.struct_sockaddr_un);
    addr.sun_family = c.AF_UNIX;
    if (path_len + 1 > @sizeOf(@TypeOf(addr.sun_path))) fail("socket path too long");
    @memcpy(addr.sun_path[0..path_len], path[0..path_len]);

    const deadline = nowMs() + 60_000;
    while (nowMs() < deadline) {
        var status: c_int = 0;
        if (c.waitpid(g_pid, &status, c.WNOHANG) == g_pid) fail("helper exited before it listened");
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) fail("socket");
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) == 0) return fd;
        _ = c.close(fd);
        _ = c.usleep(100_000);
    }
    fail("timed out connecting to the helper");
}

pub fn main(init: std.process.Init.Minimal) u8 {
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);
    const argv = init.args.vector;
    if (argv.len < 2) {
        std.debug.print("smoke-web: usage: smoke-web <path-to-sketerm-web>\n", .{});
        return 2;
    }
    const exe = argv[1];
    if (c.access(exe, c.X_OK) != 0) fail("sketerm-web binary is not executable");

    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    const gpa = gpa_state.allocator();

    // Short private paths: sockaddr_un caps at ~108 bytes, so the
    // socket cannot live under a deep scratch directory.
    const tmpl = "/tmp/skweb-XXXXXX";
    @memcpy(g_dir[0..tmpl.len], tmpl);
    if (c.mkdtemp(@ptrCast(&g_dir)) == null) fail("mkdtemp");
    const dir = std.mem.span(@as([*:0]const u8, @ptrCast(&g_dir)));

    var sock_buf: [96]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/w.sock", .{dir}) catch fail("socket path");
    var cache_buf: [96]u8 = undefined;
    const cache = std.fmt.bufPrintZ(&cache_buf, "{s}/cache", .{dir}) catch fail("cache path");

    // ── Spawn the helper ──────────────────────────────────────────
    const pid = c.fork();
    if (pid < 0) fail("fork");
    if (pid == 0) {
        var vec: [6:null]?[*:0]const u8 = @splat(null);
        vec[0] = exe;
        vec[1] = "--socket";
        vec[2] = sock.ptr;
        vec[3] = "--cache-dir";
        vec[4] = cache.ptr;
        _ = c.execv(exe, @ptrCast(@constCast(&vec)));
        c._exit(127);
    }
    g_pid = pid;

    var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };

    // ── Stage 1: handshake ────────────────────────────────────────
    cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "smoke-web" });
    {
        const deadline = nowMs() + 15_000;
        while (cl.ack_proto == 0 and nowMs() < deadline) cl.pump(100);
    }
    if (cl.ack_proto != proto.PROTO_VERSION) fail("stage 1 handshake: no hello_ack with proto 1");
    if (!cl.ack_shm) fail("stage 1 handshake: hello_ack lacks the frames-shm capability");
    pass("stage 1 handshake");

    // ── Stage 2: paint into the shared memfd ──────────────────────
    cl.send(proto.ViewCreate{ .view = view_id, .w = 800, .h = 600, .scale_x1000 = 1000, .context = 0 });
    if (!cl.waitBufferAfter(0, 20_000)) fail("stage 2 paint: no frame_buffer for the new view");
    if (cl.fb.?.w != 800 or cl.fb.?.h != 600) fail("stage 2 paint: frame_buffer geometry is not 800x600");
    cl.navigate(red_page);
    if (!cl.waitCenterColor(.{ 0, 0, 255 }, 20_000)) fail("stage 2 paint: centre pixel never turned red");
    pass("stage 2 paint (memfd frame, centre pixel red)");

    // ── Stage 3: trusted click ────────────────────────────────────
    cl.navigate(click_page);
    if (!cl.waitCenterColor(.{ 255, 0, 0 }, 20_000)) fail("stage 3 click: button page never painted blue");
    cl.send(proto.InputFocus{ .view = view_id, .focused = 1 });
    cl.clickCenter();
    if (!cl.waitTitle("result:trusted=true", 15_000)) {
        std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
        fail("stage 3 click: no trusted click reported by the page");
    }
    pass("stage 3 trusted click");

    // ── Stage 4: keyboard text entry ──────────────────────────────
    cl.navigate(input_page);
    cl.send(proto.InputFocus{ .view = view_id, .focused = 1 });
    cl.typeKey(0x68, "h");
    cl.typeKey(0x69, "i");
    if (!cl.waitTitle("typed:hi", 15_000)) {
        std.debug.print("smoke-web: title was \"{s}\"\n", .{cl.titleSlice()});
        fail("stage 4 typing: the page did not receive \"hi\"");
    }
    pass("stage 4 typing");

    // ── Stage 5: resize announces a new buffer ────────────────────
    {
        const old_buf = cl.fb.?.buf_id;
        const seq = cl.fb_seq;
        const dmg = cl.dmg_seq;
        cl.send(proto.ViewResize{ .view = view_id, .w = 640, .h = 480, .scale_x1000 = 1000 });
        if (!cl.waitBufferAfter(seq, 20_000)) fail("stage 5 resize: no new frame_buffer");
        const fb = cl.fb.?;
        if (fb.buf_id == old_buf) fail("stage 5 resize: buf_id was not replaced");
        if (fb.w != 640 or fb.h != 480) fail("stage 5 resize: new buffer is not 640x480");
        if (!cl.waitDamageAfter(dmg, 20_000)) fail("stage 5 resize: no damage for the new buffer");
        cl.mapBuffer();
        _ = cl.pixel(fb.w / 2, fb.h / 2);
        cl.send(proto.FrameRelease{ .view = view_id, .buf_id = old_buf });
        pass("stage 5 resize (new buffer mapped at 640x480)");
    }

    // ── Stage 6: popup request is reported, never opened ───────────
    cl.navigate(popup_page);
    cl.send(proto.InputFocus{ .view = view_id, .focused = 1 });
    cl.clickCenter();
    if (!cl.waitPopup("example.invalid", 15_000)) fail("stage 6 popup: no ev_popup_request for the opened url");
    if (cl.popup_view != view_id) fail("stage 6 popup: ev_popup_request carried the wrong opener view");
    pass("stage 6 popup request");

    // ── Stage 7: history navigation ───────────────────────────────
    cl.navigate(red_page);
    cl.navigate(blue_page);
    cl.send(proto.NavAction{ .view = view_id, .action = @intFromEnum(proto.NavAct.back) });
    if (!cl.waitCanForward(20_000)) fail("stage 7 nav_action: no ev_nav_state with can_fwd=1 after going back");
    pass("stage 7 nav_action back");

    // ── Stage 8: teardown ─────────────────────────────────────────
    cl.send(proto.ViewDestroy{ .view = view_id });
    cl.deinit();
    {
        const deadline = nowMs() + 10_000;
        var status: c_int = 0;
        var gone = false;
        while (nowMs() < deadline) {
            if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
                gone = true;
                break;
            }
            _ = c.usleep(50_000);
        }
        if (!gone) fail("stage 8 teardown: helper did not exit within 10s of the disconnect");
        g_pid = -1;
        if (status & 0x7f != 0) fail("stage 8 teardown: helper died on a signal");
        if ((status >> 8) & 0xff != 0) fail("stage 8 teardown: helper exited nonzero");
        pass("stage 8 teardown (helper exited 0 on disconnect)");
    }

    cleanup();
    if (gpa_state.deinit() == .leak) {
        say("smoke-web: FAIL leaked memory (see GPA report above)");
        return 1;
    }
    say("smoke-web: PASS");
    return 0;
}

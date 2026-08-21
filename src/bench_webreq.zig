//! `zig build bench-webreq` — blocking-webRequest latency.
//!
//! The browser proposal calls cross-boundary blocking-webRequest latency
//! "the hard part", so this measures it instead of asserting about it.
//! It is an END-TO-END rig against a real `sketerm-webengine` and a real
//! loopback HTTP server: a page issues N SEQUENTIAL `fetch()`es (serial
//! on purpose — parallel requests would hide exactly the serialization
//! a hold introduces) and times each one with `performance.now()`.
//!
//! Four scenarios, each a fresh helper so no state carries over:
//!
//!   A  no extension at all               — the floor
//!   B  a NON-blocking onBeforeRequest    — must be indistinguishable
//!                                          from A on the request path
//!   C  a blocking listener returning {}  — one full round trip:
//!                                          browser process -> the
//!                                          background page's renderer
//!                                          -> back
//!   D  a blocking listener doing uBO-SHAPED work — tokenize the url,
//!      probe a hostname map built from ~4000 generated rules, run a
//!      handful of regexes, cancel a known subset
//!
//! Reported per scenario: p50/p95/p99 of per-request wall time, and the
//! delta against A. For C and D the helper's OWN hold->answer p50/p95
//! (`ev_webext_wreq_stats`, microseconds) is printed too, which isolates
//! the in-helper round trip from the network and the page.
//!
//! Numbers move with the machine. The COMMITTED numbers, the config
//! they were taken on and the date live in `src/web/CLAUDE.md`; treat
//! anything here as a measurement, never a target to tune toward.

const std = @import("std");
const c = @import("cbindings");
const proto = @import("web/protocol.zig");

const view_id: u32 = 1;
/// Requests per scenario. Enough for a stable p95 without making the
/// run take minutes.
const NREQ: usize = 400;

var g_pid: c.pid_t = -1;
var g_dir: [256]u8 = @splat(0);

fn say(msg: []const u8) void {
    std.debug.print("bench-webreq: {s}\n", .{msg});
}

fn fail(comptime msg: []const u8) noreturn {
    say("FAIL " ++ msg);
    cleanup();
    std.process.exit(1);
}

fn cleanup() void {
    if (g_pid > 0) {
        _ = c.kill(g_pid, c.SIGKILL);
        var st: c_int = 0;
        _ = c.waitpid(g_pid, &st, 0);
        g_pid = -1;
    }
}

const nowMs = @import("util/clock.zig").nowMs;

// ---------------------------------------------------------------------
// A loopback HTTP server: one page, and N tiny subresources
// ---------------------------------------------------------------------

const HttpServer = struct {
    fd: c_int = -1,
    port: u16 = 0,
    page: []const u8 = "",
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    served: std.atomic.Value(u32) = .init(0),

    fn start(self: *HttpServer) bool {
        const lfd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (lfd < 0) return false;
        var one: c_int = 1;
        _ = c.setsockopt(lfd, c.SOL_SOCKET, c.SO_REUSEADDR, &one, @sizeOf(c_int));
        var sa = std.mem.zeroes(c.struct_sockaddr_in);
        sa.sin_family = c.AF_INET;
        sa.sin_port = std.mem.nativeToBig(u16, 0);
        sa.sin_addr.s_addr = std.mem.nativeToBig(u32, c.INADDR_LOOPBACK);
        if (c.bind(lfd, @ptrCast(&sa), @sizeOf(c.struct_sockaddr_in)) != 0 or c.listen(lfd, 128) != 0) {
            _ = c.close(lfd);
            return false;
        }
        var got = std.mem.zeroes(c.struct_sockaddr_in);
        var glen: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(lfd, @ptrCast(&got), &glen) != 0) {
            _ = c.close(lfd);
            return false;
        }
        self.fd = lfd;
        self.port = std.mem.bigToNative(u16, got.sin_port);
        self.thread = std.Thread.spawn(.{}, HttpServer.serve, .{self}) catch {
            _ = c.close(lfd);
            self.fd = -1;
            return false;
        };
        return true;
    }

    fn serve(self: *HttpServer) void {
        while (!self.stop.load(.acquire)) {
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
            if (c.poll(@ptrCast(&pfd), 1, 100) <= 0) continue;
            const afd = c.accept(self.fd, null, null);
            if (afd < 0) continue;
            self.handle(afd);
            _ = c.close(afd);
        }
    }

    fn handle(self: *HttpServer, afd: c_int) void {
        var req: [4096]u8 = undefined;
        var pfd = c.struct_pollfd{ .fd = afd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, 2000) <= 0) return;
        const n = c.read(afd, &req, req.len);
        if (n <= 0) return;
        const line = req[0..@intCast(n)];
        // `/r/<i>` is a subresource; anything else is the page.
        const is_sub = std.mem.indexOf(u8, line, "GET /r/") != null;
        const body: []const u8 = if (is_sub) "x" else self.page;
        const ctype: []const u8 = if (is_sub) "text/plain" else "text/html";
        var head: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(
            &head,
            "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{ ctype, body.len },
        ) catch return;
        _ = c.write(afd, hdr.ptr, hdr.len);
        _ = c.write(afd, body.ptr, body.len);
        _ = self.served.fetchAdd(1, .release);
    }

    fn deinit(self: *HttpServer) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
    }
};

// ---------------------------------------------------------------------
// A minimal protocol client: only what the bench asserts on
// ---------------------------------------------------------------------

const Stats = struct {
    id: [64]u8 = @splat(0),
    id_len: usize = 0,
    matched: u32 = 0,
    held: u32 = 0,
    cancelled: u32 = 0,
    timed_out: u32 = 0,
    failed_open: u32 = 0,
    us_p50: u32 = 0,
    us_p95: u32 = 0,
    us_max: u32 = 0,
    samples: u32 = 0,
    seen: bool = false,
};

const Client = struct {
    gpa: std.mem.Allocator,
    fd: c_int,
    in: std.ArrayList(u8) = .empty,
    ack_proto: u32 = 0,
    ack_webext: bool = false,
    we_ok: u8 = 0xff,
    title: [4096]u8 = @splat(0),
    title_len: usize = 0,
    stats: Stats = .{},

    /// Idempotent: `runScenario` closes the socket explicitly before
    /// reaping the helper, and the scope's `defer` runs anyway.
    fn deinit(self: *Client) void {
        self.in.deinit(self.gpa);
        self.in = .empty;
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
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

    fn titleSlice(self: *const Client) []const u8 {
        return self.title[0..self.title_len];
    }

    fn pump(self: *Client, timeout_ms: c_int) void {
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        if (c.poll(@ptrCast(&pfd), 1, timeout_ms) <= 0) return;
        var buf: [64 * 1024]u8 = undefined;
        const n = c.read(self.fd, &buf, buf.len);
        if (n <= 0) return;
        self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch fail("oom");
        var r = proto.Reader.init(self.in.items);
        while (true) {
            const f = (r.next() catch break) orelse break;
            self.onFrame(f);
        }
        const used = r.consumed();
        if (used != 0) {
            const rest = self.in.items.len - used;
            std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[used..]);
            self.in.shrinkRetainingCapacity(rest);
        }
    }

    fn onFrame(self: *Client, f: proto.Frame) void {
        switch (f.tag) {
            .hello_ack => {
                const a = proto.HelloAck.decodeAlloc(f.payload, self.gpa) catch return;
                defer self.gpa.free(a.caps);
                self.ack_proto = a.proto;
                for (a.caps) |cap| {
                    if (std.mem.eql(u8, cap, proto.CAP_WEBEXT)) self.ack_webext = true;
                }
            },
            .ev_title => {
                const t = proto.decode(proto.EvTitle, f.payload) catch return;
                self.title_len = @min(t.title.len, self.title.len);
                @memcpy(self.title[0..self.title_len], t.title[0..self.title_len]);
            },
            .ev_webext_state => {
                const s = proto.decode(proto.EvWebextState, f.payload) catch return;
                self.we_ok = s.ok;
                if (s.ok == 0) std.debug.print("bench-webreq: extension load error: {s}\n", .{s.err});
            },
            .ev_webext_wreq_stats => {
                const s = proto.decode(proto.EvWebextWreqStats, f.payload) catch return;
                self.stats.id_len = @min(s.id.len, self.stats.id.len);
                @memcpy(self.stats.id[0..self.stats.id_len], s.id[0..self.stats.id_len]);
                self.stats.matched = s.matched;
                self.stats.held = s.held;
                self.stats.cancelled = s.cancelled;
                self.stats.timed_out = s.timed_out;
                self.stats.failed_open = s.failed_open;
                self.stats.us_p50 = s.us_p50;
                self.stats.us_p95 = s.us_p95;
                self.stats.us_max = s.us_max;
                self.stats.samples = s.samples;
                self.stats.seen = true;
            },
            else => {},
        }
    }

    fn waitTitlePrefix(self: *Client, prefix: []const u8, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (nowMs() < deadline) {
            if (std.mem.startsWith(u8, self.titleSlice(), prefix)) return true;
            self.pump(25);
        }
        return false;
    }
};

// ---------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------

const manifest_nonblocking =
    \\{"manifest_version":2,"name":"bench nonblocking","version":"1",
    \\ "permissions":["webRequest","<all_urls>"],
    \\ "background":{"scripts":["bg.js"],"persistent":true}}
;

const manifest_blocking =
    \\{"manifest_version":2,"name":"bench blocking","version":"1",
    \\ "permissions":["webRequest","webRequestBlocking","<all_urls>"],
    \\ "background":{"scripts":["bg.js"],"persistent":true}}
;

/// B: observational only. Registered WITHOUT "blocking", so the helper
/// must continue the request inline and merely post a notification.
const bg_nonblocking =
    \\browser.webRequest.onBeforeRequest.addListener(
    \\  function (d) { self.__seen = (self.__seen || 0) + 1; },
    \\  { urls: ["<all_urls>"] },
    \\  []
    \\);
;

/// B0: a BLOCKING listener whose RequestFilter matches a host the page
/// never touches. Proves the short-circuit: a request no filter matches
/// must never reach JS, so this must be indistinguishable from A even
/// though a blocking listener is registered.
const bg_blocking_nomatch =
    \\browser.webRequest.onBeforeRequest.addListener(
    \\  function (d) { return { cancel: true }; },
    \\  { urls: ["*://never.matches.invalid/*"] },
    \\  ["blocking"]
    \\);
;

/// C: blocking, decides instantly. Isolates the round trip itself.
const bg_blocking_noop =
    \\browser.webRequest.onBeforeRequest.addListener(
    \\  function (d) { return {}; },
    \\  { urls: ["<all_urls>"] },
    \\  ["blocking"]
    \\);
;

/// D: blocking, uBO-shaped. Not uBO's code, but its SHAPE: a hostname
/// map probed from most-specific label down, a token scan against a
/// substring set, and a small regex battery — built from ~4000
/// generated rules so the work is real rather than a sleep.
const bg_blocking_ubo =
    \\var hostRules = Object.create(null);
    \\var tokenRules = Object.create(null);
    \\var regexes = [];
    \\for (var i = 0; i < 2000; i++) {
    \\  hostRules["ads" + i + ".example.invalid"] = 1;
    \\  tokenRules["/track" + i + "/"] = 1;
    \\}
    \\for (var j = 0; j < 12; j++) {
    \\  regexes.push(new RegExp("[?&](utm_" + j + "|ref" + j + ")=", "i"));
    \\}
    \\function hostOf(u) {
    \\  var s = u.indexOf("://");
    \\  if (s < 0) return "";
    \\  var rest = u.slice(s + 3);
    \\  var e = rest.indexOf("/");
    \\  var h = e < 0 ? rest : rest.slice(0, e);
    \\  var colon = h.indexOf(":");
    \\  return colon < 0 ? h : h.slice(0, colon);
    \\}
    \\function blocked(u) {
    \\  var h = hostOf(u);
    \\  var labels = h.split(".");
    \\  for (var k = 0; k < labels.length - 1; k++) {
    \\    if (hostRules[labels.slice(k).join(".")]) return true;
    \\  }
    \\  var toks = u.toLowerCase().split(/[^a-z0-9]+/);
    \\  for (var t = 0; t < toks.length; t++) {
    \\    if (tokenRules["/" + toks[t] + "/"]) return true;
    \\  }
    \\  for (var r = 0; r < regexes.length; r++) {
    \\    if (regexes[r].test(u)) return true;
    \\  }
    \\  return false;
    \\}
    \\browser.webRequest.onBeforeRequest.addListener(
    \\  function (d) { return blocked(d.url) ? { cancel: true } : {}; },
    \\  { urls: ["<all_urls>"] },
    \\  ["blocking"]
    \\);
;

fn mkdirZ(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (path.len + 1 > buf.len) return;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    _ = c.mkdir(@ptrCast(&buf), 0o755);
}

fn writeFile(dir: []const u8, name: []const u8, body: []const u8) bool {
    var buf: [4300]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    const f = c.fopen(path.ptr, "wb") orelse return false;
    defer _ = c.fclose(f);
    return c.fwrite(body.ptr, 1, body.len, f) == body.len;
}

fn writeExt(dir: []const u8, man: []const u8, bg: []const u8) bool {
    mkdirZ(dir);
    if (!writeFile(dir, "manifest.json", man)) return false;
    return writeFile(dir, "bg.js", bg);
}

// ---------------------------------------------------------------------
// The measured page
// ---------------------------------------------------------------------

/// N sequential fetches, timed individually, result reported through
/// the document title (the one channel this rig already watches).
/// Deliberately serial and cache-busted: a parallel burst would measure
/// the connection pool, not the hold.
fn buildPage(buf: []u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf,
        \\<!doctype html><html><head><title>bench-start</title></head><body>
        \\<script>
        \\(async function () {{
        \\  const N = {d};
        \\  const base = "http://127.0.0.1:{d}/r/";
        \\  const t = [];
        \\  // Warm the connection path so the first sample is not an
        \\  // outlier about DNS/socket setup rather than about us.
        \\  for (let w = 0; w < 10; w++) {{ try {{ await fetch(base + "warm" + w); }} catch (e) {{}} }}
        \\  for (let i = 0; i < N; i++) {{
        \\    const t0 = performance.now();
        \\    try {{ await fetch(base + i); }} catch (e) {{}}
        \\    t.push((performance.now() - t0) * 1000);
        \\  }}
        \\  t.sort((a, b) => a - b);
        \\  const q = (p) => Math.round(t[Math.min(t.length - 1, Math.floor(t.length * p / 100))]);
        \\  document.title = "bench-done:" + q(50) + ":" + q(95) + ":" + q(99) + ":" + t.length;
        \\}})();
        \\</script></body></html>
    , .{ NREQ, port }) catch fail("page too long");
}

// ---------------------------------------------------------------------

const Result = struct {
    p50: u64 = 0,
    p95: u64 = 0,
    p99: u64 = 0,
    n: u64 = 0,
    stats: Stats = .{},
};

fn parseTitle(title: []const u8) ?Result {
    if (!std.mem.startsWith(u8, title, "bench-done:")) return null;
    var it = std.mem.splitScalar(u8, title["bench-done:".len..], ':');
    var r = Result{};
    r.p50 = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    r.p95 = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    r.p99 = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    r.n = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    return r;
}

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

fn spawnHelper(exe: [*:0]const u8, sock: [*:0]const u8, cache: [*:0]const u8) c.pid_t {
    const pid = c.fork();
    if (pid < 0) fail("fork");
    if (pid != 0) {
        g_pid = pid;
        return pid;
    }
    var vec: [7:null]?[*:0]const u8 = @splat(null);
    vec[0] = exe;
    vec[1] = "--socket";
    vec[2] = sock;
    vec[3] = "--cache-dir";
    vec[4] = cache;
    vec[5] = "--ozone-platform=headless";
    _ = c.execv(exe, @ptrCast(@constCast(&vec)));
    c._exit(127);
    unreachable;
}

fn reap(pid: c.pid_t) void {
    const deadline = nowMs() + 20_000;
    var st: c_int = 0;
    while (nowMs() < deadline) {
        if (c.waitpid(pid, &st, c.WNOHANG) == pid) {
            g_pid = -1;
            return;
        }
        _ = c.usleep(50_000);
    }
    _ = c.kill(pid, c.SIGKILL);
    _ = c.waitpid(pid, &st, 0);
    g_pid = -1;
}

/// One scenario, one helper, one page load.
fn runScenario(
    gpa: std.mem.Allocator,
    exe: [*:0]const u8,
    dir: []const u8,
    tag: []const u8,
    ext_dir: ?[]const u8,
    page_url: []const u8,
    spin: bool,
) Result {
    var sock_buf: [110]u8 = undefined;
    const sock = std.fmt.bufPrintZ(&sock_buf, "{s}/{s}.sock", .{ dir, tag }) catch fail("sock path");
    var cache_buf: [4096]u8 = undefined;
    const cache = std.fmt.bufPrintZ(&cache_buf, "{s}/cache-{s}", .{ dir, tag }) catch fail("cache path");
    mkdirZ(cache);

    _ = c.setenv("SKETERM_WEB_WREQ_SPIN", if (spin) "1" else "0", 1);
    const pid = spawnHelper(exe, sock.ptr, cache.ptr);
    var cl = Client{ .gpa = gpa, .fd = connectWithRetry(sock.ptr, sock.len) };
    defer cl.deinit();
    cl.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "bench-webreq" });
    {
        const d = nowMs() + 20_000;
        while (cl.ack_proto == 0 and nowMs() < d) cl.pump(50);
    }
    if (cl.ack_proto == 0) fail("helper never answered the handshake");
    if (!cl.ack_webext) fail("helper lacks the webext capability");

    if (ext_dir) |ed| {
        cl.send(proto.WebextSet{ .id = "benchwreq01", .dir = ed, .enabled = 1 });
        const d = nowMs() + 10_000;
        while (cl.we_ok == 0xff and nowMs() < d) cl.pump(50);
        if (cl.we_ok != 1) fail("the bench extension failed to load");
        // The background page must be UP and its listeners registered
        // before the page runs, or the first requests would be measured
        // against a helper that has nothing to ask.
        const settle = nowMs() + 3000;
        while (nowMs() < settle) cl.pump(50);
    }

    cl.send(proto.ViewCreate{ .view = view_id, .w = 800, .h = 600, .scale_x1000 = 1000, .context = 0 });
    cl.send(proto.Navigate{ .view = view_id, .url = page_url });
    if (!cl.waitTitlePrefix("bench-done:", 180_000)) {
        std.debug.print("bench-webreq: title was \"{s}\"\n", .{cl.titleSlice()});
        fail("the page never finished its request run");
    }
    var res = parseTitle(cl.titleSlice()) orelse fail("unparsable result title");

    if (ext_dir != null) {
        cl.send(proto.WebextWreqStatsReq{});
        const d = nowMs() + 3000;
        while (!cl.stats.seen and nowMs() < d) cl.pump(50);
        res.stats = cl.stats;
        cl.send(proto.WebextRemove{ .id = "benchwreq01" });
    }
    cl.send(proto.ViewDestroy{ .view = view_id });
    {
        const d = nowMs() + 1500;
        while (nowMs() < d) cl.pump(50);
    }
    cl.deinit();
    reap(pid);
    return res;
}

fn report(name: []const u8, r: Result, base: ?Result) void {
    var delta_buf: [64]u8 = undefined;
    const delta: []const u8 = if (base) |b| std.fmt.bufPrint(
        &delta_buf,
        "  (+{d}us p50, +{d}us p95)",
        .{ r.p50 -| b.p50, r.p95 -| b.p95 },
    ) catch "" else "";
    std.debug.print(
        "  {s: <34} p50 {d: >7}us  p95 {d: >7}us  p99 {d: >7}us  n={d}{s}\n",
        .{ name, r.p50, r.p95, r.p99, r.n, delta },
    );
    if (r.stats.seen) {
        std.debug.print(
            "  {s: <34}   helper-side hold->answer: p50 {d}us p95 {d}us max {d}us over {d} holds; matched={d} held={d} cancelled={d} timed_out={d} failed_open={d}\n",
            .{
                "",
                r.stats.us_p50,
                r.stats.us_p95,
                r.stats.us_max,
                r.stats.samples,
                r.stats.matched,
                r.stats.held,
                r.stats.cancelled,
                r.stats.timed_out,
                r.stats.failed_open,
            },
        );
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    var gpa_state: std.heap.DebugAllocator(.{ .safety = true }) = .{};
    const gpa = gpa_state.allocator();

    // argv[1] is the helper binary, handed over by `build.zig`'s
    // `addArtifactArg` exactly as the smoke rig receives it.
    if (init.args.vector.len < 2) fail("usage: bench-webreq <path-to-sketerm-webengine>");
    const exe: [*:0]const u8 = init.args.vector[1];

    // Short path: `sockaddr_un` caps at ~108 bytes and a deep scratch
    // dir silently fails to bind.
    const dir = "/tmp/skbwq";
    mkdirZ(dir);
    @memcpy(g_dir[0..dir.len], dir);

    // Isolated data dir so a bench run never touches the real
    // per-extension storage.
    var data_buf: [256]u8 = undefined;
    const data = std.fmt.bufPrintZ(&data_buf, "{s}/data", .{dir}) catch fail("data path");
    mkdirZ(data);
    _ = c.setenv("XDG_DATA_HOME", data.ptr, 1);

    var ext_nb_buf: [256]u8 = undefined;
    const ext_nb = std.fmt.bufPrint(&ext_nb_buf, "{s}/ext-nb", .{dir}) catch fail("p");
    var ext_bl_buf: [256]u8 = undefined;
    const ext_bl = std.fmt.bufPrint(&ext_bl_buf, "{s}/ext-bl", .{dir}) catch fail("p");
    var ext_nm_buf: [256]u8 = undefined;
    const ext_nm = std.fmt.bufPrint(&ext_nm_buf, "{s}/ext-nm", .{dir}) catch fail("p");
    var ext_ubo_buf: [256]u8 = undefined;
    const ext_ubo = std.fmt.bufPrint(&ext_ubo_buf, "{s}/ext-ubo", .{dir}) catch fail("p");
    if (!writeExt(ext_nm, manifest_blocking, bg_blocking_nomatch)) fail("write no-match fixture");
    if (!writeExt(ext_nb, manifest_nonblocking, bg_nonblocking)) fail("write nonblocking fixture");
    if (!writeExt(ext_bl, manifest_blocking, bg_blocking_noop)) fail("write blocking fixture");
    if (!writeExt(ext_ubo, manifest_blocking, bg_blocking_ubo)) fail("write ubo-shaped fixture");

    var srv = HttpServer{};
    var page_buf: [4096]u8 = undefined;
    if (!srv.start()) fail("loopback HTTP server would not start");
    defer srv.deinit();
    srv.page = buildPage(&page_buf, srv.port);
    var url_buf: [96]u8 = undefined;
    const page_url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/page", .{srv.port}) catch fail("url");

    std.debug.print(
        "bench-webreq: {d} sequential same-origin fetches per scenario, fresh helper each time\n",
        .{NREQ},
    );

    const a = runScenario(gpa, exe, dir, "a", null, page_url, false);
    report("A no extension", a, null);
    const b0 = runScenario(gpa, exe, dir, "b0", ext_nm, page_url, false);
    report("B0 blocking, filter matches none", b0, a);
    const b = runScenario(gpa, exe, dir, "b", ext_nb, page_url, false);
    report("B non-blocking listener", b, a);
    const cc = runScenario(gpa, exe, dir, "c", ext_bl, page_url, false);
    report("C blocking, immediate {}", cc, a);
    const d = runScenario(gpa, exe, dir, "d", ext_ubo, page_url, false);
    report("D blocking, uBO-shaped work", d, a);
    const e = runScenario(gpa, exe, dir, "e", ext_bl, page_url, true);
    report("E = C with WREQ_SPIN=1 (burns a core)", e, a);

    std.debug.print("bench-webreq: done\n", .{});
    cleanup();
}

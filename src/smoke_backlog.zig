//! Shared smoke stage: MCP-client backlog gap + live-mirror resync.
//!
//! Regression for the stale-screenshot bug (SDL2 apps under MCP): an
//! "mcp"-kind client that stops draining while the app keeps
//! committing must (a) stop being streamed to once its queue crosses
//! the backlog cap — marked by a `native_gap` frame — instead of
//! accumulating a mile of stale frames, and (b) on draining, receive
//! a replay of the LIVE pool mirror terminated by `native_sync`, so
//! its next capture shows "now", not a whole-screens-old frame.
//!
//! Run by BOTH smoke-mux (monolith daemon) AND smoke-broker (real
//! broker process): the original fix tested clean in monolith while
//! broker mode — the mode `sketerm mcp` isolation actually uses —
//! dropped the client's attach kind in the worker handoff, so the
//! whole mcp-gated policy silently never engaged.

const std = @import("std");
const c = @import("c.zig").c;
const daemon_mod = @import("mux/daemon.zig");
const client_mod = @import("mux/client.zig");
const wire = @import("mux/wire.zig");
const wlwire = @import("wlhost/wire.zig");
const wlpipe = @import("wlhost/pipe.zig");
const wlpixcodec = @import("wlhost/pixcodec.zig");

fn fail(comptime msg: []const u8) noreturn {
    std.debug.print("smoke backlog stage: FAIL: " ++ msg ++ "\n", .{});
    std.process.exit(1);
}

/// wl_surface(7).commit — the needle marking "our commit was relayed".
fn commitNeedle() [8]u8 {
    var buf: [8]u8 = undefined;
    var b = wlwire.Builder.init(&buf, 7, 6);
    _ = b.finish() catch unreachable;
    return buf;
}

/// sendmsg with one SCM_RIGHTS fd attached (64-bit glibc/musl layout).
fn sendWithFd(sock: c_int, bytes: []const u8, fd: c_int) !void {
    var iov = c.struct_iovec{ .iov_base = @constCast(bytes.ptr), .iov_len = bytes.len };
    var cbuf: [32]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([32]u8);
    const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
    const cmsg: *c.struct_cmsghdr = @ptrCast(&cbuf);
    cmsg.cmsg_len = @intCast(hdr_size + @sizeOf(c_int));
    cmsg.cmsg_level = c.SOL_SOCKET;
    cmsg.cmsg_type = c.SCM_RIGHTS;
    @memcpy(cbuf[hdr_size..][0..@sizeOf(c_int)], std.mem.asBytes(&fd));
    var mh = std.mem.zeroes(c.struct_msghdr);
    mh.msg_iov = @ptrCast(&iov);
    mh.msg_iovlen = 1;
    mh.msg_control = &cbuf;
    const cmsg_align: usize = if (@import("builtin").os.tag == .macos) 4 else 8;
    mh.msg_controllen = @intCast(std.mem.alignForward(usize, hdr_size + @sizeOf(c_int), cmsg_align));
    if (c.sendmsg(sock, &mh, 0) != @as(isize, @intCast(bytes.len))) return error.SendFailed;
}

/// App-side processing barrier: send wl_display.get_registry(new_id)
/// and wait for an event ADDRESSED TO that registry (its globals) —
/// the brain answers it only after every preceding request, so its
/// reply proves the daemon processed everything sent before. Earlier
/// brain events (buffer releases, shm formats) also sit on this
/// socket and must not satisfy the wait.
fn registryBarrier(allocator: std.mem.Allocator, app_fd: c_int, new_id: u32) void {
    var mbuf: [64]u8 = undefined;
    var b = wlwire.Builder.init(&mbuf, 1, 1);
    b.putNewId(new_id);
    const m = b.finish() catch unreachable;
    if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("barrier write");
    var evbuf: std.ArrayList(u8) = .empty;
    defer evbuf.deinit(allocator);
    var rounds: usize = 0;
    while (rounds < 4000) : (rounds += 1) {
        var pos: usize = 0;
        while (true) {
            const h = (wlwire.parseHeader(evbuf.items[pos..]) catch fail("barrier hdr")) orelse break;
            if (evbuf.items[pos..].len < h.size) break;
            if (h.object == new_id) return;
            pos += h.size;
        }
        if (pos > 0) {
            const rem = evbuf.items.len - pos;
            std.mem.copyForwards(u8, evbuf.items[0..rem], evbuf.items[pos..]);
            evbuf.shrinkRetainingCapacity(rem);
        }
        var got: [4096]u8 = undefined;
        const r = c.read(app_fd, &got, got.len);
        if (r <= 0) fail("barrier read (daemon stalled)");
        evbuf.appendSlice(allocator, got[0..@intCast(r)]) catch fail("oom");
    }
    fail("barrier: registry reply never arrived");
}

/// The newest wl-* display socket in the daemon's runtime dir: works
/// for monolith (wl-N) AND broker (wl-w<pid>) session naming, as long
/// as the caller's session is the most recently spawned.
fn newestWlDisplay(sock_path: []const u8, out: *[256]u8) []const u8 {
    const dir_end = std.mem.lastIndexOfScalar(u8, sock_path, '/').?;
    var dbuf: [192]u8 = undefined;
    if (sock_path[0..dir_end].len >= dbuf.len) fail("socket dir path too long");
    @memcpy(dbuf[0..dir_end], sock_path[0..dir_end]);
    dbuf[dir_end] = 0;
    const dirp = c.opendir(dbuf[0..dir_end :0].ptr) orelse fail("opendir runtime dir");
    defer _ = c.closedir(dirp);
    var best_mtime: i64 = -1;
    var best_len: usize = 0;
    while (c.readdir(dirp)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.*.d_name)), 0);
        if (!std.mem.startsWith(u8, name, "wl-")) continue;
        if (std.mem.endsWith(u8, name, ".lock")) continue;
        var pbuf: [256]u8 = undefined;
        const full = std.fmt.bufPrintZ(&pbuf, "{s}/{s}", .{ sock_path[0..dir_end], name }) catch continue;
        var st: c.struct_stat = undefined;
        if (c.stat(full.ptr, &st) != 0) continue;
        if (st.st_mtim.tv_sec > best_mtime) {
            best_mtime = st.st_mtim.tv_sec;
            const w = std.fmt.bufPrint(out, "{s}/{s}", .{ sock_path[0..dir_end], name }) catch continue;
            best_len = w.len;
        }
    }
    if (best_len == 0) fail("no wl-* display socket found after app spawn");
    return out[0..best_len];
}

pub fn run(allocator: std.mem.Allocator, sock_path: []const u8) void {
    var conn = client_mod.Conn.connect(allocator, sock_path) catch fail("connect");
    defer conn.deinit();
    const tv = c.struct_timeval{ .tv_sec = 30, .tv_usec = 0 };
    _ = c.setsockopt(conn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
    conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("hello");
    (conn.recvExpect(&.{.welcome}) catch fail("welcome")).deinit(allocator);
    conn.sendJson(.spawn, .{
        .name = "bkapp",
        .argv = [_][]const u8{ "/bin/sleep", "60" },
        .rows = @as(u16, 10),
        .cols = @as(u16, 40),
        .app = true,
    }) catch fail("spawn");
    (conn.recvExpect(&.{.ok}) catch fail("spawn ok")).deinit(allocator);
    // The attach KIND is the load-bearing bit: only "mcp" clients get
    // the gap/resync policy, and broker mode must carry it through
    // the worker handoff.
    conn.sendJson(.attach, .{ .name = "bkapp", .kind = "mcp" }) catch fail("attach");
    (conn.recvExpect(&.{.snapshot}) catch fail("snapshot")).deinit(allocator);

    // Fake Wayland app on the session's display socket.
    var disp_buf: [256]u8 = undefined;
    const disp = newestWlDisplay(sock_path, &disp_buf);
    const app_fd = @import("util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (app_fd < 0) fail("app socket");
    var addr: c.struct_sockaddr_un = undefined;
    daemon_mod.fillSockaddrUn(&addr, disp) catch fail("sockaddr");
    if (c.connect(app_fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) fail("app connect");
    defer _ = c.close(app_fd);
    _ = c.setsockopt(app_fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));

    // 128x128 XRGB buffer = 64KB per full-copy commit; the pool file
    // stays open so content can be rewritten between commits.
    const POOL_SIZE: usize = 64 * 1024;
    var tmp_buf: [128]u8 = undefined;
    const tmp_path = std.fmt.bufPrintZ(&tmp_buf, "/tmp/sketerm-bk-smoke-{d}-pool", .{c.getpid()}) catch unreachable;
    const pool_fd = c.open(tmp_path.ptr, c.O_RDWR | c.O_CREAT | c.O_TRUNC, @as(c.mode_t, 0o600));
    if (pool_fd < 0) fail("pool open");
    defer _ = c.close(pool_fd);
    _ = c.unlink(tmp_path.ptr);
    // Incompressible content: the flood must defeat the pixel codec,
    // or 250 commits of constant pixels would deflate under the cap.
    const pool_random = allocator.alloc(u8, POOL_SIZE) catch fail("oom");
    defer allocator.free(pool_random);
    var rng: u64 = 0x9e3779b97f4a7c15;
    for (pool_random) |*b| {
        rng ^= rng << 13;
        rng ^= rng >> 7;
        rng ^= rng << 17;
        b.* = @truncate(rng);
    }
    if (c.pwrite(pool_fd, pool_random.ptr, POOL_SIZE, 0) != POOL_SIZE) fail("pool fill");

    var mbuf: [256]u8 = undefined;
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    { // get_registry(2), bind shm(3) + compositor(6)
        var b = wlwire.Builder.init(&mbuf, 1, 1);
        b.putNewId(2);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
        var b2 = wlwire.Builder.init(mbuf[32..], 2, 0);
        b2.putUint(2);
        b2.putString("wl_shm");
        b2.putUint(1);
        b2.putNewId(3);
        stream.appendSlice(allocator, b2.finish() catch unreachable) catch fail("oom");
        var b3 = wlwire.Builder.init(mbuf[96..], 2, 0);
        b3.putUint(1);
        b3.putString("wl_compositor");
        b3.putUint(4);
        b3.putNewId(6);
        stream.appendSlice(allocator, b3.finish() catch unreachable) catch fail("oom");
        if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len))) fail("write binds");
    }
    { // wl_shm.create_pool(4, fd, POOL_SIZE)
        var b = wlwire.Builder.init(&mbuf, 3, 0);
        b.putNewId(4);
        b.putInt(POOL_SIZE);
        sendWithFd(app_fd, b.finish() catch unreachable, pool_fd) catch fail("create_pool");
    }
    stream.clearRetainingCapacity();
    { // create_buffer(5, 0, 128x128, stride 512, fmt 1) + surface(7) + attach + commit
        var b = wlwire.Builder.init(&mbuf, 4, 0);
        b.putNewId(5);
        b.putInt(0);
        b.putInt(128);
        b.putInt(128);
        b.putInt(512);
        b.putUint(1);
        stream.appendSlice(allocator, b.finish() catch unreachable) catch fail("oom");
        var b2 = wlwire.Builder.init(mbuf[64..], 6, 0);
        b2.putNewId(7);
        stream.appendSlice(allocator, b2.finish() catch unreachable) catch fail("oom");
        var b3 = wlwire.Builder.init(mbuf[96..], 7, 1);
        b3.putObject(5);
        b3.putInt(0);
        b3.putInt(0);
        stream.appendSlice(allocator, b3.finish() catch unreachable) catch fail("oom");
        stream.appendSlice(allocator, &commitNeedle()) catch fail("oom");
        if (c.write(app_fd, stream.items.ptr, stream.items.len) != @as(isize, @intCast(stream.items.len))) fail("write setup");
    }

    // Streaming sanity: the first commit reaches the mcp client.
    {
        var seen_commit = false;
        var rounds: usize = 0;
        while (!seen_commit and rounds < 400) : (rounds += 1) {
            const f = conn.recvFrame() catch fail("first-commit read");
            defer f.deinit(allocator);
            if (f.ftype == .chan_data and std.mem.indexOf(u8, f.payload[4..], &commitNeedle()) != null)
                seen_commit = true;
        }
        if (!seen_commit) fail("first commit never streamed");
    }

    // FLOOD while the client stalls: 250 x 64KB incompressible full
    // copies ≈ 16MB — far past the mcp backlog cap.
    {
        var flood: std.ArrayList(u8) = .empty;
        defer flood.deinit(allocator);
        for (0..250) |_| flood.appendSlice(allocator, &commitNeedle()) catch fail("oom");
        var off: usize = 0;
        while (off < flood.items.len) {
            const n = c.write(app_fd, flood.items.ptr + off, flood.items.len - off);
            if (n <= 0) fail("flood write");
            off += @intCast(n);
        }
    }
    // Barrier BEFORE swapping content: the daemon must have processed
    // (and encoded) the flood against the random bytes, or the pool
    // would already hold the final pattern when it reads the commits
    // and every "flood" copy would deflate under the cap.
    registryBarrier(allocator, app_fd, 99);

    // The FINAL content ("what the app shows now") — also
    // incompressible, but a DIFFERENT deterministic sequence — then
    // one more commit and a second barrier.
    const final_pat = allocator.alloc(u8, POOL_SIZE) catch fail("oom");
    defer allocator.free(final_pat);
    var rng2: u64 = 0x2545f4914f6cdd1d;
    for (final_pat) |*b| {
        rng2 ^= rng2 << 13;
        rng2 ^= rng2 >> 7;
        rng2 ^= rng2 << 17;
        b.* = @truncate(rng2);
    }
    if (c.pwrite(pool_fd, final_pat.ptr, POOL_SIZE, 0) != POOL_SIZE) fail("final fill");
    {
        var b = wlwire.Builder.init(&mbuf, 7, 6); // commit
        const m = b.finish() catch unreachable;
        if (c.write(app_fd, m.ptr, m.len) != @as(isize, @intCast(m.len))) fail("final commit");
    }
    registryBarrier(allocator, app_fd, 100);

    // Drain. Expect: (stale frames…) native_gap, then NOTHING more of
    // the flood; once we've caught up, the replay: chan_open again,
    // pool bytes == FINAL pattern, a state_sync unit, native_sync.
    var saw_gap = false;
    var saw_sync = false;
    var saw_reopen = false;
    var saw_state_sync = false;
    var replay_units: std.ArrayList(u8) = .empty;
    defer replay_units.deinit(allocator);
    var shadow = allocator.alloc(u8, POOL_SIZE) catch fail("oom");
    defer allocator.free(shadow);
    @memset(shadow, 0);
    var rounds: usize = 0;
    while (!saw_sync and rounds < 20_000) : (rounds += 1) {
        const f = conn.recvFrame() catch fail("drain read (native_sync never arrived)");
        defer f.deinit(allocator);
        switch (f.ftype) {
            .native_gap => saw_gap = true,
            .native_sync => saw_sync = true,
            .chan_open => {
                if (saw_gap) {
                    const open = wire.decodeChanOpen(f.payload) orelse fail("reopen decode");
                    if (open.kind == .wayland_native) saw_reopen = true;
                }
            },
            .chan_data => {
                if (!saw_reopen) continue; // pre-gap stale frames
                replay_units.appendSlice(allocator, f.payload[4..]) catch fail("oom");
                var pos: usize = 0;
                while ((wlpipe.peelUnit(replay_units.items[pos..]) catch fail("replay unit")) != null) {
                    const p = (wlpipe.peelUnit(replay_units.items[pos..]) catch unreachable).?;
                    switch (p.unit.tag) {
                        .pool_update_c => {
                            const upd = wlpipe.decodePoolUpdateC(p.unit.payload) orelse fail("replay update");
                            if (upd.pool == 4 and upd.offset + upd.body.raw_len <= POOL_SIZE) {
                                const dst = shadow[upd.offset..][0..upd.body.raw_len];
                                wlpixcodec.decodeBody(upd.body, dst) catch fail("replay decode");
                            }
                        },
                        .state_sync => saw_state_sync = true,
                        else => {},
                    }
                    pos += p.consumed;
                }
                if (pos > 0) {
                    const rem = replay_units.items.len - pos;
                    std.mem.copyForwards(u8, replay_units.items[0..rem], replay_units.items[pos..]);
                    replay_units.shrinkRetainingCapacity(rem);
                }
            },
            else => {},
        }
    }
    if (!saw_gap) fail("native_gap never sent (backlog cap not enforced for mcp client — kind lost?)");
    if (!saw_reopen) fail("replay chan_open missing after drain");
    if (!saw_state_sync) fail("replay state_sync missing");
    if (!saw_sync) fail("native_sync never arrived");
    if (!std.mem.eql(u8, shadow, final_pat)) fail("replay pool bytes are not the LIVE mirror (stale screenshot regression)");
    std.debug.print("smoke backlog stage: mcp gap + live-mirror resync ok\n", .{});

    // Tear the session down over a FRESH connection (in broker mode
    // the attached conn is served by the worker, which owns no
    // routing); the attached client still gets `gone`.
    {
        var kconn = client_mod.Conn.connect(allocator, sock_path) catch fail("kill connect");
        defer kconn.deinit();
        _ = c.setsockopt(kconn.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.struct_timeval));
        kconn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch fail("kill hello");
        (kconn.recvExpect(&.{.welcome}) catch fail("kill welcome")).deinit(allocator);
        kconn.sendJson(.kill, .{ .name = "bkapp" }) catch fail("kill send");
        (kconn.recvExpect(&.{.ok}) catch fail("kill ok")).deinit(allocator);
    }
    var kr: usize = 0;
    var got_gone = false;
    while (!got_gone and kr < 400) : (kr += 1) {
        const f = conn.recvFrame() catch fail("kill read");
        defer f.deinit(allocator);
        if (f.ftype == .gone) got_gone = true;
    }
    if (!got_gone) fail("gone never arrived after kill");
}

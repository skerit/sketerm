//! End-to-end smoke: launch the real app, drive it over the
//! remote-control socket, assert on what the terminal actually
//! rendered. `zig build smoke-e2e`.
//!
//! Needs a display (GTK window) — exits 0 with "SKIP" when neither
//! WAYLAND_DISPLAY nor DISPLAY is set, so CI without a compositor
//! still passes the step.

const std = @import("std");
const c = @import("c.zig").c;
const platform = @import("util/platform.zig");
const protocol = @import("ipc/protocol.zig");

const MARKER = "sketerm-e2e-marker-7423";

var child_pid: c.pid_t = 0;
var daemon_pid: c.pid_t = 0;

fn fail(comptime msg: []const u8) u8 {
    _ = c.fprintf(platform.stderr(), "smoke-e2e: FAIL: " ++ msg ++ "\n");
    if (child_pid > 0) {
        _ = c.kill(child_pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(child_pid, &status, 0);
        child_pid = 0;
    }
    if (daemon_pid > 0) {
        // Let the broker terminate and reap its exact worker children.
        _ = c.kill(daemon_pid, c.SIGTERM);
        var status: c_int = 0;
        _ = c.waitpid(daemon_pid, &status, 0);
        daemon_pid = 0;
    }
    return 1;
}

pub fn main() u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    // macOS always has a display (the GDK macOS backend talks to the
    // WindowServer directly; no env var advertises it).
    if (!platform.is_macos and
        c.getenv("WAYLAND_DISPLAY") == null and c.getenv("DISPLAY") == null)
    {
        _ = c.fputs("smoke-e2e: SKIP (no display)\n", platform.stdout());
        return 0;
    }

    // Every mutable path and the daemon itself are private to this smoke.
    // A protocol bump must never classify the user's live daemon as stale
    // and shut it down.
    var rt_buf: [256]u8 = undefined;
    const rt = std.fmt.bufPrintZ(&rt_buf, "/tmp/sketerm-smoke-e2e-{d}", .{c.getpid()}) catch return fail("runtime path");
    _ = c.mkdir(rt.ptr, 0o700);
    _ = c.setenv("XDG_RUNTIME_DIR", rt.ptr, 1);
    _ = c.setenv("XDG_CONFIG_HOME", rt.ptr, 1);
    _ = c.setenv("XDG_STATE_HOME", rt.ptr, 1);
    _ = c.unsetenv("SKETERM_SOCKET");
    defer @import("mux/daemon.zig").removeTreeBestEffort(rt);

    const mux_pid = c.fork();
    if (mux_pid < 0) return fail("mux fork");
    if (mux_pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm-mux", "--broker", null };
        _ = c.execv("zig-out/bin/sketerm-mux", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    daemon_pid = mux_pid;
    var mux_sock_buf: [512]u8 = undefined;
    const mux_sock = std.fmt.bufPrintZ(&mux_sock_buf, "{s}/sketerm/mux.sock", .{rt}) catch return fail("mux socket path");
    var waited: u32 = 0;
    while (c.access(mux_sock.ptr, c.F_OK) != 0) {
        _ = c.usleep(50_000);
        waited += 1;
        if (waited > 100) return fail("private mux socket never appeared (5s)");
    }

    // Spawn the freshly-built binary with its own app id so it
    // doesn't join a running user instance via GApplication.
    const pid = c.fork();
    if (pid < 0) return fail("fork");
    if (pid == 0) {
        _ = c.setenv("SKETERM_APP_ID", "dev.sker.sketerm.e2e", 1);
        // xvfb-run adds DISPLAY but preserves an inherited WAYLAND_DISPLAY.
        // Prefer the explicit test X server instead of opening a window on a
        // live forwarded Wayland compositor.
        if (c.getenv("DISPLAY") != null) {
            _ = c.setenv("GDK_BACKEND", "x11", 1);
            _ = c.unsetenv("WAYLAND_DISPLAY");
        }
        // Cross-check the pane-tree model against the widget tree
        // after every split/close — divergence aborts the app, which
        // fails this harness.
        _ = c.setenv("SKETERM_VERIFY_TREE", "1", 1);
        const argv = [_:null]?[*:0]const u8{ "zig-out/bin/sketerm", "--no-save", null };
        _ = c.execv("zig-out/bin/sketerm", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    child_pid = pid;

    // Wait for the socket to appear (app startup + bind).
    const sock_path = std.fmt.allocPrintSentinel(allocator, "{s}/sketerm/{d}.sock", .{ rt, pid }, 0) catch return fail("alloc");
    defer allocator.free(sock_path);
    waited = 0;
    while (c.access(sock_path.ptr, c.F_OK) != 0) {
        _ = c.usleep(100_000);
        waited += 1;
        if (waited > 100) return fail("socket never appeared (10s)");
    }
    // Give the first pane's shell a moment to start.
    _ = c.usleep(700_000);

    // 1. list — exactly one tab with at least one pane.
    const list_resp = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return fail("list roundtrip");
    defer allocator.free(list_resp);
    if (std.mem.indexOf(u8, list_resp, "\"ok\":true") == null) return fail("list not ok");
    if (std.mem.indexOf(u8, list_resp, "\"panes\":[{") == null) return fail("list has no panes");

    // 2. send-text an echo with a unique marker...
    var req_buf: [256]u8 = undefined;
    const send_req = std.fmt.bufPrint(&req_buf, "{{\"cmd\":\"send-text\",\"pane\":1,\"data\":\"echo {s}\\n\"}}\n", .{MARKER}) catch return fail("fmt");
    const send_resp = roundtrip(allocator, sock_path, send_req) orelse return fail("send-text roundtrip");
    defer allocator.free(send_resp);
    if (std.mem.indexOf(u8, send_resp, "\"ok\":true") == null) return fail("send-text not ok");

    // 3. ...and poll get-text until the marker shows up as command
    // OUTPUT (echoed line + result = at least 2 occurrences; a shell
    // that hasn't run it yet shows at most the typed line).
    var tries: u32 = 0;
    var seen = false;
    while (tries < 50) : (tries += 1) {
        _ = c.usleep(200_000);
        const text_resp = roundtrip(allocator, sock_path, "{\"cmd\":\"get-text\",\"pane\":1}\n") orelse return fail("get-text roundtrip");
        defer allocator.free(text_resp);
        // De-wrap before counting: on a narrow window (xvfb-run's
        // 640x480 default) the TYPED echo line wraps mid-marker, so
        // count on a copy with the JSON "\n" escapes removed.
        const flat = allocator.alloc(u8, text_resp.len) catch return fail("alloc");
        defer allocator.free(flat);
        var w: usize = 0;
        var r: usize = 0;
        while (r < text_resp.len) {
            if (r + 1 < text_resp.len and text_resp[r] == '\\' and text_resp[r + 1] == 'n') {
                r += 2;
                continue;
            }
            flat[w] = text_resp[r];
            w += 1;
            r += 1;
        }
        if (std.mem.count(u8, flat[0..w], MARKER) >= 2) {
            seen = true;
            break;
        }
        if (tries == 49) {
            // Diagnosability: show what the screen actually held.
            _ = c.fprintf(platform.stderr(), "smoke-e2e: last get-text: %.*s\n", @as(c_int, @intCast(@min(text_resp.len, 2000))), text_resp.ptr);
        }
    }
    if (!seen) return fail("marker output never appeared in get-text");

    // 4. split, then list must show two panes.
    const split_resp = roundtrip(allocator, sock_path, "{\"cmd\":\"split\",\"pane\":1,\"direction\":\"h\"}\n") orelse return fail("split roundtrip");
    defer allocator.free(split_resp);
    if (std.mem.indexOf(u8, split_resp, "\"ok\":true") == null) return fail("split not ok");
    _ = c.usleep(500_000);
    const list2 = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return fail("list2 roundtrip");
    defer allocator.free(list2);
    if (std.mem.count(u8, list2, "\"id\":") < 3) return fail("split did not add a pane"); // 1 tab id + 2 pane ids

    // 5. nested split (vertical on the new pane), then close it —
    // exercises the tree model's deep split + collapse paths under
    // SKETERM_VERIFY_TREE.
    const split2 = roundtrip(allocator, sock_path, "{\"cmd\":\"split\",\"pane\":2,\"direction\":\"v\"}\n") orelse return fail("split2 roundtrip");
    defer allocator.free(split2);
    if (std.mem.indexOf(u8, split2, "\"ok\":true") == null) return fail("split2 not ok");
    _ = c.usleep(500_000);
    const close2 = roundtrip(allocator, sock_path, "{\"cmd\":\"close-pane\",\"pane\":2}\n") orelse return fail("close-pane roundtrip");
    defer allocator.free(close2);
    if (std.mem.indexOf(u8, close2, "\"ok\":true") == null) return fail("close-pane not ok");
    _ = c.usleep(500_000);
    const list3 = roundtrip(allocator, sock_path, "{\"cmd\":\"list\"}\n") orelse return fail("list3 roundtrip");
    defer allocator.free(list3);
    // Relative invariant (the instance may have restored a saved
    // default layout, so absolute counts are unknowable): split2
    // added one pane, close-pane removed one — net equal to list2.
    if (std.mem.count(u8, list3, "\"id\":") != std.mem.count(u8, list2, "\"id\":"))
        return fail("close-pane wrong pane count");

    // 6. A stale SKETERM_PANE_ID (the GUI restarted since the pane's
    // shell was spawned, so its baked-in id no longer matches a live
    // pane) must NOT fail an attach with "no such pane" — the takeover
    // falls back to the current pane. Using a bogus session name keeps
    // this non-destructive: attachMux fails at the snapshot step (after
    // the pane resolution we're testing), for a reason that ISN'T
    // "no such pane".
    const stale = roundtrip(allocator, sock_path, "{\"cmd\":\"attach-session\",\"pane\":99999,\"data\":\"no-such-sess-e2e\"}\n") orelse return fail("stale-pane roundtrip");
    defer allocator.free(stale);
    if (std.mem.indexOf(u8, stale, "no such pane") != null) return fail("stale SKETERM_PANE_ID regressed to 'no such pane'");

    // 7. unknown command must error.
    const bad = roundtrip(allocator, sock_path, "{\"cmd\":\"nope\"}\n") orelse return fail("bad-cmd roundtrip");
    defer allocator.free(bad);
    if (std.mem.indexOf(u8, bad, "\"ok\":false") == null) return fail("unknown cmd not rejected");

    // Shut down via SIGTERM (graceful path) and check socket cleanup.
    _ = c.kill(pid, c.SIGTERM);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    child_pid = 0;
    if (c.access(sock_path.ptr, c.F_OK) == 0) return fail("socket not unlinked on shutdown");

    _ = c.kill(daemon_pid, c.SIGTERM);
    _ = c.waitpid(daemon_pid, &status, 0);
    daemon_pid = 0;

    _ = c.fputs("smoke-e2e: PASS\n", platform.stdout());
    return 0;
}

/// One connect → one request line → one response line. Caller frees.
fn roundtrip(allocator: std.mem.Allocator, sock_path: [:0]const u8, line: []const u8) ?[]u8 {
    const client = c.g_socket_client_new();
    defer c.g_object_unref(client);
    const addr = c.g_unix_socket_address_new(sock_path.ptr);
    defer c.g_object_unref(addr);
    var gerr: [*c]c.GError = null;
    const conn = c.g_socket_client_connect(client, @ptrCast(@alignCast(addr)), null, &gerr);
    if (conn == null) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    defer c.g_object_unref(conn);
    const out_stream = c.g_io_stream_get_output_stream(@ptrCast(conn));
    var written: c.gsize = 0;
    if (c.g_output_stream_write_all(out_stream, line.ptr, line.len, &written, null, &gerr) == 0) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    const din = c.g_data_input_stream_new(c.g_io_stream_get_input_stream(@ptrCast(conn)));
    defer c.g_object_unref(din);
    var rlen: c.gsize = 0;
    const resp = c.g_data_input_stream_read_line(din, &rlen, null, &gerr);
    if (resp == null) {
        if (gerr != null) c.g_error_free(gerr);
        return null;
    }
    defer c.g_free(resp);
    return allocator.dupe(u8, resp[0..rlen]) catch null;
}

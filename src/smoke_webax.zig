//! Web-page AT-SPI projection smoke — `zig build smoke-webax` (Linux).
//!
//! Proves the a11y pipeline's CLIENT half end to end, headless and
//! with no CEF and no GUI: wire frames (the exact bytes an
//! `ev_a11y_tree` carries) feed the mirrored tree (`web/axtree.zig`),
//! `a11y/webproj.zig` registers that tree on a REAL private
//! accessibility bus (dbus-daemon + at-spi2-registryd via
//! `mux/a11yhub.zig`) through `org.a11y.atspi.Socket.Embed`, and the
//! daemon's own pure-Zig AT-SPI client (`Hub.treeJson`) then walks the
//! registry desktop and must find:
//!
//!   1. an application named after the page, listed by the REGISTRY
//!      (i.e. Embed actually registered us — nothing is asserted from
//!      our own connection);
//!   2. under it a DOCUMENT_WEB root, a HEADING named "Axheading", a
//!      PUSH_BUTTON named "Axgo" (role numbers, not strings: the same
//!      values Orca switches on);
//!   3. extents resolved through the offset-container chain;
//!   4. an incremental update (button renamed) visible on a re-walk.
//!
//! SKIPs (exit 0) when dbus-daemon or at-spi2-registryd is missing.

const std = @import("std");
const c = @import("c.zig").c;
const proto = @import("web/protocol.zig");
const axtree = @import("web/axtree.zig");
const webproj = @import("a11y/webproj.zig");
const A11yHub = @import("mux/a11yhub.zig").Hub;

var g_dir: [64]u8 = @splat(0);

fn say(msg: []const u8) void {
    std.debug.print("smoke-webax: {s}\n", .{msg});
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("smoke-webax: FAIL {s}\n", .{msg});
    std.process.exit(1);
}

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// Encode specs -> one ev_a11y_tree frame -> decode -> apply: the
/// mirror is fed through the REAL wire bytes, not through its own API.
fn applyWire(
    gpa: std.mem.Allocator,
    tree: *axtree.Tree,
    root_id: u32,
    clear: u32,
    focus: u32,
    specs: []const proto.A11yNodeSpec,
) void {
    var nodes: std.ArrayList(u8) = .empty;
    defer nodes.deinit(gpa);
    var w = proto.A11yNodeWriter{ .gpa = gpa, .buf = &nodes };
    for (specs) |s| w.put(s) catch fail("node encode");

    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(gpa);
    proto.encode(gpa, &frame, proto.EvA11yTree{
        .view = 1,
        .root_id = root_id,
        .node_id_to_clear = clear,
        .focus_id = focus,
        .nodes = .{ .s = nodes.items },
    }) catch fail("frame encode");

    var rd = proto.Reader.init(frame.items);
    const f = (rd.next() catch fail("frame decode")) orelse fail("no frame");
    if (f.tag != .ev_a11y_tree) fail("wrong tag");
    const ev = proto.decode(proto.EvA11yTree, f.payload) catch fail("payload decode");
    tree.applyTree(ev) catch fail("applyTree");
}

const ServeCtx = struct {
    proj: *webproj.Proj,
    stop: std.atomic.Value(bool) = .init(false),
};

fn serveThread(ctx: *ServeCtx) void {
    while (!ctx.stop.load(.acquire)) {
        if (!ctx.proj.serveSlice(50)) return;
    }
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .{};
    const gpa = gpa_state.allocator();

    // Short private dir (sockaddr_un caps at ~108 bytes).
    const dir = std.fmt.bufPrint(&g_dir, "/tmp/skwax-{d}", .{c.getpid()}) catch unreachable;
    var dir_z: [64:0]u8 = undefined;
    @memcpy(dir_z[0..dir.len], dir);
    dir_z[dir.len] = 0;
    _ = c.mkdir(&dir_z, 0o700);
    defer _ = c.rmdir(&dir_z);

    var hub = A11yHub.setup(gpa, dir, "wax") orelse {
        say("SKIP: no dbus-daemon / at-spi2-registryd");
        return;
    };
    defer hub.deinit();
    say("private a11y bus + registry up");

    // ── the page tree, via wire bytes ─────────────────────────────
    var tree = axtree.Tree.init(gpa);
    defer tree.deinit();
    applyWire(gpa, &tree, 1, 0, 4, &.{
        .{ .id = 1, .role = "document", .name = "Ax page", .x = 0, .y = 0, .w = 800, .h = 600, .children = &.{ 2, 3 } },
        .{ .id = 2, .role = "heading", .name = "Axheading", .x = 8, .y = 8, .w = 300, .h = 40, .offset_container = 1, .attributes = &.{.{ .key = "level", .value = "1" }} },
        .{ .id = 3, .role = "generic", .x = 8, .y = 60, .w = 400, .h = 100, .offset_container = 1, .children = &.{4} },
        .{ .id = 4, .role = "button", .name = "Axgo", .state = proto.ax_focusable, .x = 4, .y = 4, .w = 90, .h = 30, .offset_container = 3 },
    });

    // ── project it onto the bus ───────────────────────────────────
    var proj = webproj.Proj.init(gpa, &tree, "sketerm web: Ax page") catch fail("proj init");
    defer proj.deinit();
    proj.connect(hub.bus_path) catch fail("could not connect+embed on the a11y bus");
    say("embedded on the registry");

    var ctx = ServeCtx{ .proj = &proj };
    const th = std.Thread.spawn(.{}, serveThread, .{&ctx}) catch fail("serve thread");

    // ── walk the desktop with the daemon's own AT-SPI client ──────
    const json = hub.treeJson(gpa) orelse fail("registry walk produced no tree");
    defer gpa.free(json);

    if (std.mem.indexOf(u8, json, "sketerm web: Ax page") == null) {
        std.debug.print("smoke-webax: registry tree was:\n{s}\n", .{json});
        fail("the embedded application is not listed by the registry");
    }
    say("registry lists the page application (Embed worked)");

    // Role numbers as the walker records them: application 75,
    // document web 95, heading 83, push button 43.
    if (std.mem.indexOf(u8, json, "\"name\":\"Ax page\",\"role\":95") == null and
        std.mem.indexOf(u8, json, "\"role\":95,\"name\":\"Ax page\"") == null)
    {
        std.debug.print("smoke-webax: registry tree was:\n{s}\n", .{json});
        fail("no DOCUMENT_WEB root named after the page");
    }
    if (std.mem.indexOf(u8, json, "\"name\":\"Axheading\",\"role\":83") == null and
        std.mem.indexOf(u8, json, "\"role\":83,\"name\":\"Axheading\"") == null)
    {
        std.debug.print("smoke-webax: registry tree was:\n{s}\n", .{json});
        fail("no HEADING named Axheading");
    }
    if (std.mem.indexOf(u8, json, "\"name\":\"Axgo\",\"role\":43") == null and
        std.mem.indexOf(u8, json, "\"role\":43,\"name\":\"Axgo\"") == null)
    {
        std.debug.print("smoke-webax: registry tree was:\n{s}\n", .{json});
        fail("no PUSH_BUTTON named Axgo");
    }
    // The button's absolute rect resolves through the container chain:
    // 4+8 (container) + 4 (button) = 12,64 sized 90x30.
    if (std.mem.indexOf(u8, json, "\"rect\":[12,64,90,30]") == null) {
        std.debug.print("smoke-webax: registry tree was:\n{s}\n", .{json});
        fail("button extents did not resolve through the offset-container chain");
    }
    say("roles, names and extents all answer correctly over the bus");

    // ── an incremental update is visible on a re-walk ─────────────
    // Let any straggling request from the first walk drain before the
    // main thread mutates the tree the serve thread reads.
    _ = c.usleep(200_000);
    applyWire(gpa, &tree, 1, 0, 4, &.{
        .{ .id = 4, .role = "button", .name = "Axrenamed", .state = proto.ax_focusable, .x = 4, .y = 4, .w = 90, .h = 30, .offset_container = 3 },
    });
    const json2 = hub.treeJson(gpa) orelse fail("second registry walk failed");
    defer gpa.free(json2);
    if (std.mem.indexOf(u8, json2, "\"name\":\"Axrenamed\",\"role\":43") == null and
        std.mem.indexOf(u8, json2, "\"role\":43,\"name\":\"Axrenamed\"") == null)
    {
        std.debug.print("smoke-webax: second tree was:\n{s}\n", .{json2});
        fail("the incremental rename is not visible on a re-walk");
    }
    if (std.mem.indexOf(u8, json2, "Axheading") == null)
        fail("untouched nodes vanished after the incremental update");
    say("incremental update visible on a re-walk");

    // ── teardown ──────────────────────────────────────────────────
    ctx.stop.store(true, .release);
    _ = c.shutdown(proj.fd, c.SHUT_RDWR);
    th.join();
    std.debug.print("smoke-webax: PASS\n", .{});
}

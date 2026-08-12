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
//! Then the three things that make it usable rather than merely
//! present, each asserted through the BUS and not through our own
//! objects:
//!
//!   5. a focus move is EMITTED as `object:state-changed:focused` —
//!      both the 1 on the new node and the 0 on the old one, received
//!      on a separate connection with a match rule. This is the whole
//!      difference between a reader being told and a reader having to
//!      re-walk;
//!   6. `Action.DoAction(0)` on the button reaches the owner's
//!      trusted-input hook, aimed at the node's resolved CENTRE (the
//!      projection cannot reach the engine, so this hook is the seam
//!      that keeps `webproj` engine-free);
//!   7. `Text` answers the field's CONTENT (not its label), the caret
//!      offset, and a real selection range — what a braille display
//!      follows.
//!   8. screen-reader DETECTION answers correctly against this same
//!      real bus, fails safe when no session bus is reachable, and is
//!      overridden by SKETERM_WEB_A11Y in both directions.
//!
//! SKIPs (exit 0) when dbus-daemon or at-spi2-registryd is missing.

const std = @import("std");
const c = @import("c.zig").c;
const proto = @import("web/protocol.zig");
const axtree = @import("web/axtree.zig");
const webproj = @import("a11y/webproj.zig");
const A11yHub = @import("mux/a11yhub.zig").Hub;
const a11ydetect = @import("a11y/detect.zig");

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

/// The projection is single-threaded by design (in the GUI, `publish`
/// and `step` both run on the main loop). This rig needs a serve
/// thread so blocking client calls can be made from `main`, so
/// publishing is handed to that SAME thread through a ticket
/// handshake — two threads writing D-Bus messages onto one socket
/// would interleave them into garbage.
const ServeCtx = struct {
    proj: *webproj.Proj,
    stop: std.atomic.Value(bool) = .init(false),
    publish_req: std.atomic.Value(u32) = .init(0),
    publish_done: std.atomic.Value(u32) = .init(0),
};

fn serveThread(ctx: *ServeCtx) void {
    while (!ctx.stop.load(.acquire)) {
        const want = ctx.publish_req.load(.acquire);
        if (want != ctx.publish_done.load(.acquire)) {
            ctx.proj.publish();
            ctx.publish_done.store(want, .release);
        }
        if (!ctx.proj.serveSlice(20)) return;
    }
}

/// Ask the serve thread to publish and wait for it. Returns false if
/// it never did (the thread died).
fn publishAndWait(ctx: *ServeCtx) bool {
    const ticket = ctx.publish_req.load(.acquire) + 1;
    ctx.publish_req.store(ticket, .release);
    const deadline = nowMs() + 5_000;
    while (nowMs() < deadline) {
        if (ctx.publish_done.load(.acquire) == ticket) return true;
        _ = c.usleep(2_000);
    }
    return false;
}

/// What a projected `DoAction` asked the owner to do. In the GUI this
/// hook posts `input_pointer` frames; here it just records, which is
/// exactly the seam that keeps `webproj` engine-free.
const ActionLog = struct {
    calls: u32 = 0,
    node_id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
};
var g_action: ActionLog = .{};

fn onAction(ctx: ?*anyopaque, req: webproj.ActionReq) bool {
    _ = ctx;
    g_action.calls += 1;
    g_action.node_id = req.node_id;
    g_action.x = req.x;
    g_action.y = req.y;
    return true;
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
        .{ .id = 1, .role = "document", .name = "Ax page", .x = 0, .y = 0, .w = 800, .h = 600, .children = &.{ 2, 3, 5 } },
        .{ .id = 2, .role = "heading", .name = "Axheading", .x = 8, .y = 8, .w = 300, .h = 40, .offset_container = 1, .attributes = &.{.{ .key = "level", .value = "1" }} },
        .{ .id = 3, .role = "generic", .x = 8, .y = 60, .w = 400, .h = 100, .offset_container = 1, .children = &.{4} },
        .{ .id = 4, .role = "button", .name = "Axgo", .state = proto.ax_focusable, .x = 4, .y = 4, .w = 90, .h = 30, .offset_container = 3 },
        // A field whose LABEL and CONTENT differ: the caret must be
        // reported against "Axtext here", never against "Axlabel".
        .{
            .id = 5,
            .role = "textbox",
            .name = "Axlabel",
            .value = "Axtext here",
            .state = proto.ax_focusable | proto.ax_editable,
            .x = 8,
            .y = 200,
            .w = 200,
            .h = 24,
            .offset_container = 1,
        },
    });

    // ── project it onto the bus ───────────────────────────────────
    var proj = webproj.Proj.init(gpa, &tree, "sketerm web: Ax page") catch fail("proj init");
    defer proj.deinit();
    proj.connect(hub.bus_path) catch fail("could not connect+embed on the a11y bus");
    say("embedded on the registry");

    proj.setActionHook(null, onAction);
    var ctx = ServeCtx{ .proj = &proj };
    const th = std.Thread.spawn(.{}, serveThread, .{&ctx}) catch fail("serve thread");
    // Prime the shadow: the first publish is deliberately silent, so
    // everything asserted below is a real emitted change.
    if (!publishAndWait(&ctx)) fail("initial publish never ran");

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

    // ── a focus move is EMITTED, not just answerable ──────────────
    // The difference this stage exists for: a reader must be told,
    // rather than having to re-walk the tree to notice.
    {
        var watch = hub.watchEvents(gpa) orelse fail("could not watch a11y bus events");
        defer watch.deinit();

        _ = c.usleep(200_000); // let the walk's stragglers drain
        // Focus moves from the button (4) to the text field (5).
        applyWire(gpa, &tree, 1, 0, 5, &.{
            .{ .id = 5, .role = "textbox", .name = "Axlabel", .value = "Axtext here", .state = proto.ax_focusable | proto.ax_editable, .x = 8, .y = 200, .w = 200, .h = 24, .offset_container = 1 },
        });
        if (!publishAndWait(&ctx)) fail("publish never ran for the focus move");

        var saw_focus_on = false;
        var saw_focus_off = false;
        var path_buf: [64]u8 = undefined;
        const want_on = std.fmt.bufPrint(&path_buf, "/org/a11y/atspi/accessible/{d}", .{5}) catch unreachable;
        const deadline = nowMs() + 10_000;
        while (nowMs() < deadline and !saw_focus_on) {
            const ev = watch.next(1_000) orelse continue;
            if (!std.mem.eql(u8, ev.member(), "StateChanged")) continue;
            if (!std.mem.eql(u8, ev.detail(), "focused")) continue;
            if (ev.detail1 == 1 and std.mem.eql(u8, ev.path(), want_on)) saw_focus_on = true;
            if (ev.detail1 == 0 and std.mem.endsWith(u8, ev.path(), "/4")) saw_focus_off = true;
        }
        if (!saw_focus_on)
            fail("no object:state-changed:focused(1) signal reached the bus for the newly focused node");
        if (!saw_focus_off)
            fail("the previously focused node was never un-focused (a reader would announce both)");
        say("focus change emitted as a real AT-SPI signal (both edges)");
    }

    // ── an Action press reaches the trusted-input route ───────────
    {
        var id_buf: [128]u8 = undefined;
        const btn_id = std.fmt.bufPrint(&id_buf, "{s}#{d}", .{ proj.uniqueName(), 4 }) catch unreachable;
        g_action = .{};
        if (!hub.doAction(gpa, btn_id, 0))
            fail("Action.DoAction(0) on the button was refused");
        if (g_action.calls != 1)
            fail("DoAction did not reach the owner's trusted-input hook exactly once");
        if (g_action.node_id != 4)
            fail("the press was routed for the wrong node");
        // The button resolves to 12,64 90x30 through the container
        // chain, so its centre is 57,79 in view coordinates. A press
        // aimed anywhere else would click the wrong element.
        if (g_action.x != 57 or g_action.y != 79) {
            std.debug.print("smoke-webax: press point was {d},{d}\n", .{ g_action.x, g_action.y });
            fail("the press was not aimed at the node's centre");
        }
        say("Action press routed to the trusted-input hook at the node's centre");
    }

    // ── Text: caret offset and selection for a braille display ────
    {
        var id_buf: [128]u8 = undefined;
        const field_id = std.fmt.bufPrint(&id_buf, "{s}#{d}", .{ proj.uniqueName(), 5 }) catch unreachable;

        // Caret after "Axtext" (UTF-16 unit 6 -> character 6).
        tree.applyCaret(.{ .view = 1, .anchor_id = 5, .anchor_offset = 6, .focus_id = 5, .focus_offset = 6 });
        if (!publishAndWait(&ctx)) fail("publish never ran for the caret");

        const st = hub.textState(gpa, field_id) orelse
            fail("the field answered no org.a11y.atspi.Text state");
        defer gpa.free(st.text);
        if (!std.mem.eql(u8, st.text, "Axtext here")) {
            std.debug.print("smoke-webax: Text.GetText returned '{s}'\n", .{st.text});
            fail("Text.GetText returned the label instead of the field's content");
        }
        if (st.caret != 6) {
            std.debug.print("smoke-webax: caret offset was {d}\n", .{st.caret});
            fail("Text.CaretOffset did not report where the caret is");
        }
        if (hub.textNSelections(gpa, field_id) orelse -1 != 0)
            fail("a collapsed caret was reported as a selection");

        // Now select "text" (characters 2..6).
        tree.applyCaret(.{ .view = 1, .anchor_id = 5, .anchor_offset = 2, .focus_id = 5, .focus_offset = 6 });
        if (!publishAndWait(&ctx)) fail("publish never ran for the selection");
        if (hub.textNSelections(gpa, field_id) orelse -1 != 1)
            fail("a real selection was not reported by GetNSelections");
        const sel = hub.textSelection(gpa, field_id) orelse
            fail("GetSelection(0) answered nothing");
        if (sel[0] != 2 or sel[1] != 6) {
            std.debug.print("smoke-webax: selection was {d}..{d}\n", .{ sel[0], sel[1] });
            fail("GetSelection did not report the selected range");
        }
        say("Text reports content, caret offset and selection over the bus");
    }

    // ── screen-reader detection, against a REAL bus ───────────────
    // The hub sets org.a11y.Status IsEnabled + ScreenReaderEnabled on
    // its private bus, which is exactly the desktop this projection is
    // supposed to switch itself on for.
    {
        // The override wins over any desktop signal, both ways: assert
        // that first, then clear it so the probe is the thing tested.
        _ = c.setenv("SKETERM_WEB_A11Y", "0", 1);
        if (a11ydetect.detect(gpa) != .forced_off)
            fail("SKETERM_WEB_A11Y=0 did not force accessibility off");
        _ = c.setenv("SKETERM_WEB_A11Y", "1", 1);
        if (!a11ydetect.detect(gpa).enabled())
            fail("SKETERM_WEB_A11Y=1 did not force accessibility on");
        _ = c.unsetenv("SKETERM_WEB_A11Y");

        // Point the probe at a session bus that has no accessibility
        // stack at all: it must fail SAFE, and must not activate one.
        _ = c.setenv("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent/sketerm-webax", 1);
        const dead = a11ydetect.detect(gpa);
        if (dead.enabled()) {
            std.debug.print("smoke-webax: detection said {s}\n", .{dead.token()});
            fail("detection enabled accessibility with no reachable session bus");
        }

        // Now the private bus, where the hub advertises a reader.
        var addr_buf: [256]u8 = undefined;
        const addr = std.fmt.bufPrintZ(&addr_buf, "unix:path={s}", .{hub.bus_path}) catch unreachable;
        _ = c.setenv("DBUS_SESSION_BUS_ADDRESS", addr.ptr, 1);
        const live = a11ydetect.detect(gpa);
        if (!live.enabled()) {
            std.debug.print("smoke-webax: detection said {s}\n", .{live.token()});
            fail("detection did not notice the reader this bus advertises");
        }
        std.debug.print("smoke-webax: detection on a reader bus = {s}\n", .{live.token()});
        say("screen-reader detection answers correctly on a real bus (and fails safe without one)");
    }

    // ── teardown ──────────────────────────────────────────────────
    ctx.stop.store(true, .release);
    _ = c.shutdown(proj.fd, c.SHUT_RDWR);
    th.join();
    std.debug.print("smoke-webax: PASS\n", .{});
}

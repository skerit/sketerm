//! App-session queries and recording: `app_list`, the `app_a11y`
//! tree/op relay against the session's private AT-SPI bus, and
//! `rec_start` for asciicast recording. Split out of daemon_serve.zig.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const platform = @import("../util/platform.zig");
const selfexec = @import("selfexec.zig");
const fsserve = @import("fsserve.zig");
const fsjob = @import("fsjob.zig");
const daemon_fsjobs = @import("daemon_fsjobs.zig");
const pulse = @import("pulse.zig");
const snapshot = @import("snapshot.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Worker = dmod.Worker;
const Session = dmod.Session;
const Channel = dmod.Channel;
const Upload = dmod.Upload;
const Download = dmod.Download;
const FsView = dmod.FsView;
const SpawnReq = dmod.SpawnReq;
const AttachReq = dmod.AttachReq;
const WorkerReady = dmod.WorkerReady;
const WorkerMeta = dmod.WorkerMeta;
const WorkerPush = dmod.WorkerPush;
const nowMs = @import("../util/clock.zig").nowMs;
const cwdOfPid = dmod.cwdOfPid;
const pathZ = @import("../util/pathz.zig").pathZ;
const version = @import("../version.zig");
const cast_rec = @import("cast.zig");
const opuscodec = @import("opuscodec.zig");
const build_options = @import("build_options");
const wsproto = @import("../winstream/proto.zig");
const wallMs = @import("../util/clock.zig").wallMs;
const webstore = @import("webstore.zig");
const webprofiles = @import("../ipc/webprofiles.zig");
const webfindbin = @import("../web/findbin.zig");
const capabilities = @import("capabilities.zig");

/// Installed-app discovery: scan the daemon host's .desktop
/// entries and answer app_listing. On an SSH/UDP daemon this is
/// the REMOTE's app list — the whole point of the remote launcher.
pub fn handleAppList(self: *Daemon, cl: *Client) void {
    const AppOut = struct { name: []const u8, exec: []const u8, icon: []const u8 };
    const desktop = @import("desktop.zig");
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const entries = desktop.scan(arena, 2048) catch {
        cl.queueJson(.app_listing, .{ .apps = &[_]AppOut{}, .@"error" = "scan failed" });
        return;
    };
    var out = arena.alloc(AppOut, entries.len) catch {
        cl.queueJson(.app_listing, .{ .apps = &[_]AppOut{}, .@"error" = "oom" });
        return;
    };
    for (entries, 0..) |e, i| out[i] = .{ .name = e.name, .exec = e.exec, .icon = e.icon };
    cl.queueJson(.app_listing, .{ .apps = out });
}

/// Serialize the attached app session's AT-SPI tree. The tree
/// JSON is already a bare node object; wrap it as {"tree":...}.
pub fn handleAppA11y(self: *Daemon, cl: *Client, payload: []const u8) void {
    const s = cl.attached orelse {
        cl.queueJson(.app_a11y_tree, .{ .@"error" = "not attached" });
        return;
    };
    var hub = &(s.a11y orelse {
        cl.queueJson(.app_a11y_tree, .{ .@"error" = "no accessibility bus for this session (not an app session, or dbus-daemon unavailable)" });
        return;
    });

    // Optional op payload: {op:"action"|"set_text"|"set_value",
    // id, index?, text?, value?}. Empty / op:"tree" = tree walk.
    if (payload.len > 0) {
        const Op = struct {
            op: []const u8 = "tree",
            id: []const u8 = "",
            index: i32 = 0,
            text: []const u8 = "",
            value: f64 = 0,
        };
        var parsed = std.json.parseFromSlice(Op, self.allocator, payload, .{
            .ignore_unknown_fields = true,
        }) catch {
            cl.queueJson(.app_a11y_tree, .{ .@"error" = "bad a11y op request" });
            return;
        };
        defer parsed.deinit();
        const op = parsed.value;
        if (!std.mem.eql(u8, op.op, "tree")) {
            if (op.id.len == 0) {
                cl.queueJson(.app_a11y_tree, .{ .@"error" = "a11y op requires 'id' (from the tree)" });
                return;
            }
            const done = if (std.mem.eql(u8, op.op, "action"))
                hub.doAction(self.allocator, op.id, op.index)
            else if (std.mem.eql(u8, op.op, "set_text"))
                hub.setTextContents(self.allocator, op.id, op.text)
            else if (std.mem.eql(u8, op.op, "set_value"))
                hub.setCurrentValue(self.allocator, op.id, op.value)
            else {
                cl.queueJson(.app_a11y_tree, .{ .@"error" = "unknown a11y op" });
                return;
            };
            if (done)
                cl.queueJson(.app_a11y_tree, .{ .ok = true })
            else
                cl.queueJson(.app_a11y_tree, .{ .@"error" = "a11y op failed (node gone, interface unsupported, or bus error)" });
            return;
        }
    }

    const tree = hub.treeJson(self.allocator) orelse {
        cl.queueJson(.app_a11y_tree, .{ .@"error" = "no accessibility tree (the app has not published one; GTK/Qt apps only)" });
        return;
    };
    defer self.allocator.free(tree);
    queueA11yTree(self, cl, tree);
}

/// Wrap a bare a11y tree object as `{"tree":...}` and queue it.
///
/// Every exit answers on `.app_a11y_tree`, allocation failure included:
/// the client waits for THAT frame type and ignores `.err`, so a
/// dropped reply is a hang until its timeout.
fn queueA11yTree(self: *Daemon, cl: *Client, tree: []const u8) void {
    var reply: std.ArrayList(u8) = .empty;
    defer reply.deinit(self.allocator);
    reply.ensureTotalCapacity(self.allocator, tree.len + 9) catch {
        cl.queueJson(.app_a11y_tree, .{ .@"error" = "out of memory serializing the accessibility tree" });
        return;
    };
    reply.appendSliceAssumeCapacity("{\"tree\":");
    reply.appendSliceAssumeCapacity(tree);
    reply.appendSliceAssumeCapacity("}");
    cl.queueFrame(.app_a11y_tree, reply.items);
}

test "an a11y tree reply that cannot be built is still an app_a11y_tree frame" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var d = Daemon{ .allocator = failing.allocator(), .listen_fd = -1, .sock_path = empty[0..] };
    var cl = Client{ .allocator = a, .fd = -1 };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);

    queueA11yTree(&d, &cl, "{\"role\":\"application\"}");
    try t.expect(failing.has_induced_failure);
    const failed = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.app_a11y_tree, failed.frame.ftype);
    try t.expect(std.mem.indexOf(u8, failed.frame.payload, "out of memory") != null);
    try t.expect(!cl.dead);

    cl.wbuf.clearRetainingCapacity();
    d.allocator = a;
    queueA11yTree(&d, &cl, "{\"role\":\"application\"}");
    const ok = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.app_a11y_tree, ok.frame.ftype);
    try t.expectEqualStrings("{\"tree\":{\"role\":\"application\"}}", ok.frame.payload);
}

/// Start an asciicast v2 recording of the attached session. The
/// file lands on the DAEMON's host (that's where the bytes are) —
/// for SSH/UDP sessions the path is remote.
pub fn handleRecStart(self: *Daemon, cl: *Client, payload: []const u8) void {
    const s = cl.attached orelse {
        cl.queueErr("not attached");
        return;
    };
    if (s.isCast()) {
        cl.queueErr("cannot record a cast playback session");
        return;
    }
    const Req = struct { path: []const u8 };
    var parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad rec_start request");
        return;
    };
    defer parsed.deinit();
    if (parsed.value.path.len == 0 or parsed.value.path[0] != '/') {
        cl.queueErr("rec_start path must be absolute");
        return;
    }
    if (s.cast_recorder) |*old| {
        old.finish();
        s.cast_recorder = null;
    }
    s.cast_recorder = cast_rec.Rec.start(
        self.allocator,
        parsed.value.path,
        s.screen.cols,
        s.screen.rows,
        s.name,
        nowMs(),
    ) catch {
        cl.queueErr("cannot open recording file");
        return;
    };
    cl.queueJson(.ok, .{ .ok = true });
}

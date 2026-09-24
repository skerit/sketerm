//! Accessibility (capability "a11y"), the face half: the AT-SPI
//! projection of the helper's AX tree. Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const a11ydetect = @import("../../a11y/detect.zig");
const axtree = @import("../../web/axtree.zig");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const clock = @import("../../util/clock.zig");
const proto = @import("../../web/protocol.zig");
const webproj = @import("../../a11y/webproj.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;
const findFaceGlobal = host_mod.findFaceGlobal;

// ---- accessibility (capability "a11y") --------------------------
//
// The helper streams the page's AX tree only after `a11y_enable`
// (engine-side accessibility costs real CPU), a mirrored tree
// (web/axtree.zig) lives on this face, and a11y/webproj.zig
// registers it on the session's accessibility bus as its own
// accessible application, emitting focus/caret/object events and
// serving Action and Text.
//
// WHETHER TO RUN AT ALL is decided by a11y/detect.zig, which asks
// the desktop (org.a11y.Status) whether a screen reader is there;
// SKETERM_WEB_A11Y overrides it in both directions. Never infer it
// from "an a11y bus exists" — letting the ENGINE make that call is
// exactly what made every page serialize its tree (669f208), which
// is why the helper sets the CEF state explicitly on both edges.
//
// The detection probe AND the bus connect (SASL auth + GetAddress
// + Socket.Embed) are blocking IO, so both run on a short-lived
// DETACHED worker that touches no GTK/face state and hands back
// through g_idle_add; only the handback frees the job, and it
// resolves the face through the client's faces list (pointer
// identity, deref only after match) so a face that died
// mid-connect just costs the worker its work.
//
// A "no reader" answer is remembered for `ax_reprobe_ms` so that
// minting views does not spawn a probe thread each time, but it is
// NOT cached forever: a user who starts Orca while sketerm is
// running gets the projection at the next view mint after that
// window, with no restart.

/// Main-thread only (written from the g_idle handback, read from
/// `ensureA11y`), so no atomics are needed.
pub var g_ax_off_until_ms: i64 = 0;
pub const ax_reprobe_ms: i64 = 30_000;

pub const AxJob = struct {
    gpa: std.mem.Allocator,
    /// Identity token; dereferenced only after it matches a live
    /// registered face.
    face: *WebFace,
    view: u32,
    tree: *axtree.Tree,
    proj: *webproj.Proj,
    ok: bool = false,
    reason: a11ydetect.Reason = .unavailable,

    pub fn discard(self: *AxJob) void {
        self.proj.deinit();
        self.gpa.destroy(self.proj);
        self.tree.deinit();
        self.gpa.destroy(self.tree);
    }
};

/// Bring the projection up (idempotent) and (re)tell the helper to
/// stream. Safe against an old helper: an unknown `a11y_enable`
/// frame is skipped by the reader, so nothing ever answers.
pub fn ensureA11y(self: *WebFace) void {
    if (self.attached or self.widgets_dead) return;
    // A forced-off override needs no probe and no worker at all.
    if (a11ydetect.override()) |o| {
        if (!o.enabled()) return;
    } else if (clock.nowMs() < g_ax_off_until_ms) return;
    if (self.ax_proj != null) {
        // A fresh helper connection knows nothing of the earlier
        // enable; the projection itself survives helper restarts.
        self.cl.post(proto.A11yEnable{ .view = self.view, .enabled = 1 });
        return;
    }
    if (self.ax_connecting) return;
    const gpa = self.allocator;
    const tree = gpa.create(axtree.Tree) catch return;
    tree.* = axtree.Tree.init(gpa);
    const proj = gpa.create(webproj.Proj) catch {
        gpa.destroy(tree);
        return;
    };
    proj.* = webproj.Proj.init(gpa, tree, "sketerm web page") catch {
        gpa.destroy(proj);
        tree.deinit();
        gpa.destroy(tree);
        return;
    };
    const job = gpa.create(AxJob) catch {
        proj.deinit();
        gpa.destroy(proj);
        tree.deinit();
        gpa.destroy(tree);
        return;
    };
    job.* = .{ .gpa = gpa, .face = self, .view = self.view, .tree = tree, .proj = proj };
    self.ax_connecting = true;
    const th = std.Thread.spawn(.{}, axConnectWorker, .{job}) catch {
        self.ax_connecting = false;
        job.discard();
        gpa.destroy(job);
        return;
    };
    th.detach();
}

/// WORKER THREAD: blocking bus IO only; no GTK, no face state.
/// Detection runs HERE rather than in `ensureA11y` because it is a
/// D-Bus round trip, and the main loop must never wait on one.
pub fn axConnectWorker(job: *AxJob) void {
    job.reason = a11ydetect.detect(job.gpa);
    job.ok = job.reason.enabled() and
        if (job.proj.connect(null)) |_| true else |_| false;
    _ = c.g_idle_add(@ptrCast(&axConnectDone), job);
}

pub fn axConnectDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(AxJob, user);
    const gpa = job.gpa;
    defer gpa.destroy(job);
    // Resolve GLOBALLY. A face on a non-direct ROUTE lives on that
    // route's Client, not on `g_client`,
    // so scanning only the local client never found it: the
    // connected projection was discarded and `ax_connecting` stayed
    // true forever, permanently disabling accessibility for that
    // view and re-spawning a discarded bus probe on every later
    // mint (job.ok was true, so the backoff never armed either).
    var adopt: ?*WebFace = null;
    if (findFaceGlobal(job.view)) |f| {
        if (f == job.face) {
            // The attempt is over however it ends, so the flag comes
            // off here rather than only on the adopted path.
            f.ax_connecting = false;
            if (!f.widgets_dead) adopt = f;
        }
    }
    const face = adopt orelse {
        job.discard();
        return 0;
    };
    if (!job.ok) {
        // No reader (or the bus refused us): back off so minting
        // views does not spawn a probe thread apiece, but let the
        // window expire so a reader started later is still found.
        if (!job.reason.enabled()) g_ax_off_until_ms = clock.nowMs() + ax_reprobe_ms;
        job.discard();
        return 0;
    }
    face.ax_tree = job.tree;
    face.ax_proj = job.proj;
    face.ax_watch = c.g_unix_fd_add(
        job.proj.fd,
        c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
        @ptrCast(&onAxBusReadable),
        face,
    );
    if (face.title) |t| job.proj.setAppName(t);
    // The projection cannot reach the engine; this is its route.
    job.proj.setActionHook(face, axDoAction);
    face.cl.post(proto.A11yEnable{ .view = face.view, .enabled = 1 });
    return 0;
}

/// A screen reader pressed a projected node. Runs on the MAIN
/// thread (from `proj.step` under the fd watch), so `ctx` is the
/// live face that owns the watch.
///
/// The press becomes a real pointer event at the node's centre —
/// the same `input_pointer` frames a human click posts, landing on
/// the same `send_mouse_click_event` in the helper. It is
/// deliberately NOT a DOM `click()`: a synthetic DOM event is not
/// user-activated, so it cannot open a popup, start media, or
/// enter fullscreen, and pages routinely reject it.
pub fn axDoAction(ctx: ?*anyopaque, req: webproj.ActionReq) bool {
    const self = cast.userData(WebFace, ctx);
    if (!self.view_live or self.widgets_dead) return false;
    // Page-space CSS pixels already; `sendPointer` would subtract
    // the pixel-grid nudge a second time, so post directly.
    for ([_]proto.PointerKind{ .move, .down, .up }) |kind| {
        self.cl.post(proto.InputPointer{
            .view = self.view,
            .kind = @intFromEnum(kind),
            .x = req.x,
            .y = req.y,
            .button = 0,
            .clicks = 1,
            .mods = 0,
        });
    }
    return true;
}

pub fn onAxBusReadable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(WebFace, user);
    const proj = self.ax_proj orelse {
        self.ax_watch = 0;
        return 0;
    };
    if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0 or !proj.step()) {
        self.ax_watch = 0;
        self.axTeardown();
        return 0;
    }
    return 1;
}

/// Drop the projection AND stop the helper-side stream: a mirror
/// without a bus registration has no consumer. Idempotent; called
/// from the teardown choke point, `deinit`, and a dead bus.
pub fn axTeardown(self: *WebFace) void {
    if (self.ax_watch != 0) {
        _ = c.g_source_remove(self.ax_watch);
        self.ax_watch = 0;
    }
    if (self.ax_proj) |p| {
        self.cl.post(proto.A11yEnable{ .view = self.view, .enabled = 0 });
        p.deinit();
        self.allocator.destroy(p);
        self.ax_proj = null;
    }
    if (self.ax_tree) |t| {
        t.deinit();
        self.allocator.destroy(t);
        self.ax_tree = null;
    }
}

// Every apply is followed by `publish`, which diffs against what
// the bus was last told and emits only real changes — that is what
// turns the projection from "re-walk to notice" into "the reader
// is told".

pub fn onAxTree(self: *WebFace, ev: proto.EvA11yTree) void {
    const t = self.ax_tree orelse return;
    t.applyTree(ev) catch {};
    if (self.ax_proj) |p| p.publish();
}

pub fn onAxLoc(self: *WebFace, ev: proto.EvA11yLoc) void {
    const t = self.ax_tree orelse return;
    t.applyLoc(ev) catch {};
    // Geometry only: no structural or focus change to announce, and
    // scrolling produces these at frame rate.
}

pub fn onAxCaret(self: *WebFace, ev: proto.EvA11yCaret) void {
    const t = self.ax_tree orelse return;
    t.applyCaret(ev);
    if (self.ax_proj) |p| p.publish();
}

/// A discrete engine event. The tree frame that accompanies a focus
/// move already carries `focus_id`, so this is the path that
/// catches a focus change the engine reports WITHOUT a tree
/// update; `publish` deduplicates either way.
pub fn onAxEvent(self: *WebFace, ev: proto.EvA11yEvent) void {
    const t = self.ax_tree orelse return;
    if (std.mem.eql(u8, ev.event, "focus") and ev.id != 0) t.focus_id = ev.id;
    if (self.ax_proj) |p| p.publish();
}
